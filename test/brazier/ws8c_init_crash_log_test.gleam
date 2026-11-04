//// A WebSocket whose `init` crashes is logged once, where it crashed, with
//// the connection id, the page, the crash and its stacktrace. The layers
//// between (the runtime start, the transport) do not log it again: the
//// transport's close line is info.
////
//// The test synchronizes on the close frame; nothing sleeps.

import brazier/app_config_fixture
import brazier/application
import brazier/cluster/log_capture
import brazier/effect
import brazier/error
import brazier/html
import brazier/internal/context.{type Context}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Inc
}

type RawSocket

const host = "127.0.0.1"

fn crashing(
  _ctx: Context,
) -> Result(#(Model, effect.Effect(Msg)), error.InitError) {
  panic as "ws8c init crashes on purpose"
}

fn start() -> application.App {
  let config =
    app_config_fixture.new(
      port: 0,
      init: crashing,
      update: fn(model: Model, _msg) {
        #(Model(count: model.count + 1), effect.none())
      },
      view: fn(model: Model) {
        html.div([], [html.text(int.to_string(model.count))])
      },
      encode_model: fn(model: Model) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      },
      decode_event: fn(_name, _handler_id, _data, _path) {
        Error(error.RuntimeError(reason: "no events"))
      },
    )
  let assert Ok(app) = application.start(config)
  app
}

fn upgrade_and_await_close(app: application.App) -> Int {
  let authority = host <> ":" <> int.to_string(app.port)
  let assert Ok(socket) = raw_connect(host, app.port)
    as "test client must connect to the listener"
  let assert Ok(Nil) =
    raw_send(
      socket,
      raw_upgrade_request("/ws?path=%2F", authority, [
        #("Upgrade", "websocket"),
        #("Connection", "Upgrade"),
        #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
        #("Sec-WebSocket-Version", "13"),
        #("Origin", "http://" <> authority),
      ]),
    )
    as "test client must send the upgrade request"
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
    as "server must answer the upgrade request"
  let assert Ok(head) = bit_array.to_string(head)
  let assert "101" = string.slice(head, 9, 3)
  let assert Ok(#(8, <<code:16, _reason:bits>>)) = raw_recv_frame(socket, 3000)
    as "server must send a close frame"
  raw_close(socket)
  code
}

pub fn init_crash_is_logged_once_with_its_context_test() {
  let app = start()
  let #(code, logs) = log_capture.capture(fn() { upgrade_and_await_close(app) })
  let assert 1011 = code

  // The capture is node-wide, so only lines about this crash count.
  let errors =
    list.filter(logs, fn(line) {
      line.level == "error" && string.contains(line.message, "on purpose")
    })
  // Exactly one error line: the crash, logged where it happened.
  let assert [line] = errors
  let assert True =
    string.contains(
      line.message,
      "init or the initial route crashed for \"/\" (connection conn_",
    )
  let assert True =
    string.contains(line.message, "ws8c init crashes on purpose")
  // The class and the stacktrace, so the crash can be found from the line.
  let assert True = string.contains(line.message, "error:")
  let assert True = string.contains(line.message, "ws8c_init_crash_log_test")

  // No warning repeats it either.
  let assert False =
    list.any(logs, fn(line) {
      line.level == "warning" && string.contains(line.message, "on purpose")
    })
  // The transport's close is info.
  let assert True = log_capture.contains(logs, "info", "1011")
  let assert Ok(Nil) = application.stop(app)
  Nil
}

@external(erlang, "brazier_ws_test_ffi", "raw_connect")
fn raw_connect(host: String, port: Int) -> Result(RawSocket, String)

@external(erlang, "brazier_ws_test_ffi", "raw_send")
fn raw_send(socket: RawSocket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_ws_test_ffi", "raw_recv_frame")
fn raw_recv_frame(
  socket: RawSocket,
  timeout: Int,
) -> Result(#(Int, BitArray), String)

@external(erlang, "brazier_ws_test_ffi", "raw_close")
fn raw_close(socket: RawSocket) -> Nil

@external(erlang, "brazier_ws_test_ffi", "raw_upgrade_request")
fn raw_upgrade_request(
  path: String,
  host: String,
  headers: List(#(String, String)),
) -> BitArray
