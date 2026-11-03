/// An app's `init` refusing or crashing, observed over a real server: the
/// server render answers with the refusal's status (500 for a crash), and
/// the WebSocket closes with `error.init_close_code` (1011 for a crash).
/// Each test asserts the status or close code, the log and, for the
/// socket, the `[beacon, ws, close]` summary.
///
/// The test synchronizes on the HTTP response, the close frame and the
/// telemetry event; nothing sleeps.
import beacon/app_config_fixture
import beacon/application
import beacon/cluster/log_capture
import beacon/effect
import beacon/error
import beacon/html
import beacon/internal/context.{type Context}
import beacon/telemetry.{type Event}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
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

fn start(
  init: fn(Context) -> Result(#(Model, effect.Effect(Msg)), error.InitError),
) -> application.App {
  let config =
    app_config_fixture.new(
      port: 0,
      init: init,
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

fn stop(app: application.App) -> Nil {
  let assert Ok(Nil) = application.stop(app)
  Nil
}

/// Refuse the request on both mounts.
fn refusing(refusal: error.InitError) {
  fn(_ctx: Context) { Error(refusal) }
}

/// Crash on both mounts.
fn crashing(
  _ctx: Context,
) -> Result(#(Model, effect.Effect(Msg)), error.InitError) {
  panic as "test init crashes on purpose"
}

fn get(app: application.App) -> #(Int, String) {
  let url = "http://localhost:" <> int.to_string(app.port) <> "/"
  let assert Ok(#(status, _headers, body)) = http_request("GET", url, [], "")
    as "the server must answer the page request"
  #(status, body)
}

/// Upgrade to a WebSocket and return the close frame the server sends.
fn upgrade_and_await_close(app: application.App) -> #(Int, String) {
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
  // init runs after the upgrade (the connected mount), so the refusal is a
  // close frame, not an HTTP status.
  let assert "101" = string.slice(head, 9, 3)
  let assert Ok(#(8, <<code:16, reason:bits>>)) = raw_recv_frame(socket, 3000)
    as "server must send a close frame"
  let assert Ok(reason) = bit_array.to_string(reason)
  raw_close(socket)
  #(code, reason)
}

fn listen() -> #(String, Subject(Event)) {
  let assert Ok(Nil) = telemetry.start()
  let id = "init_error_server_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let assert Ok(Nil) =
    telemetry.attach(id, [["beacon", "ws", "close"]], fn(event) {
      process.send(events, event)
    })
  #(id, events)
}

/// The close summary carrying `label`; summaries of other connections are
/// skipped.
fn expect_close(events: Subject(Event), label: String) -> Event {
  let assert Ok(event) = process.receive(events, 3000)
    as "the ws close summary must arrive within 3s"
  case telemetry.string(event, "reason") == Ok(label) {
    True -> event
    False -> expect_close(events, label)
  }
}

// --- server render ----------------------------------------------------------

pub fn page_refused_as_unavailable_is_a_503_test() {
  let app = start(refusing(error.unavailable("orders-db.internal down")))
  let #(#(status, body), logs) = log_capture.capture(fn() { get(app) })
  let assert 503 = status
  let assert True = string.contains(body, "Service Unavailable")
  let assert False = string.contains(body, "orders-db")
  let assert False = string.contains(body, "<script")
  let assert True =
    log_capture.contains(logs, "error", "503: orders-db.internal down")
  stop(app)
}

pub fn page_refused_with_a_client_status_carries_it_test() {
  let app = start(refusing(error.refuse(403, "not a member of board 7")))
  let #(#(status, body), logs) = log_capture.capture(fn() { get(app) })
  let assert 403 = status
  let assert True = string.contains(body, "Forbidden")
  let assert False = string.contains(body, "board 7")
  let assert True =
    log_capture.contains(logs, "warning", "403: not a member of board 7")
  stop(app)
}

pub fn page_whose_init_crashes_is_a_500_test() {
  let app = start(crashing)
  let #(#(status, body), logs) = log_capture.capture(fn() { get(app) })
  let assert 500 = status
  let assert False = string.contains(body, "on purpose")
  let assert True =
    log_capture.contains(logs, "error", "request handler crashed")
  // The listener survived the crash.
  let #(status, _body) = get(app)
  let assert 500 = status
  stop(app)
}

// --- WebSocket --------------------------------------------------------------

pub fn socket_refused_as_unavailable_closes_with_4503_test() {
  let app = start(refusing(error.unavailable("orders-db.internal down")))
  let #(id, events) = listen()
  let #(#(code, reason), logs) =
    log_capture.capture(fn() { upgrade_and_await_close(app) })
  let assert 4503 = code
  // A fixed reason: the app's reason stays in the server log.
  let assert "init refused" = reason
  let close = expect_close(events, "init_refused")
  let assert Ok(4503) = telemetry.int(close, "close_code")
  let assert True =
    log_capture.contains(logs, "error", "503: orders-db.internal down")
  let assert True = log_capture.contains(logs, "error", "4503")
  let assert Ok(Nil) = telemetry.detach(id)
  stop(app)
}

pub fn socket_refused_with_401_closes_with_4401_test() {
  // 4401 is the code the client answers by reloading the page, so the
  // server render can answer the refusal with its own status.
  let app = start(refusing(error.refuse(401, "signed out")))
  let #(id, events) = listen()
  let #(#(code, reason), logs) =
    log_capture.capture(fn() { upgrade_and_await_close(app) })
  let assert 4401 = code
  let assert "init refused" = reason
  let close = expect_close(events, "init_refused")
  let assert Ok(4401) = telemetry.int(close, "close_code")
  let assert True = log_capture.contains(logs, "warning", "401: signed out")
  let assert False =
    list.any(logs, fn(line) {
      line.level == "error" && string.contains(line.message, "signed out")
    })
  let assert Ok(Nil) = telemetry.detach(id)
  stop(app)
}

pub fn socket_whose_init_crashes_closes_with_1011_test() {
  let app = start(crashing)
  let #(id, events) = listen()
  let #(#(code, reason), logs) =
    log_capture.capture(fn() { upgrade_and_await_close(app) })
  let assert 1011 = code
  let assert "startup failure" = reason
  let close = expect_close(events, "startup_failure")
  let assert Ok(1011) = telemetry.int(close, "close_code")
  let assert True =
    log_capture.contains(logs, "error", "init or the initial route crashed")
  // The handler closed the socket itself: the listener still upgrades.
  let #(code, _reason) = upgrade_and_await_close(app)
  let assert 1011 = code
  let assert Ok(Nil) = telemetry.detach(id)
  stop(app)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "beacon_http_client_ffi", "http_request")
fn http_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, List(#(String, String)), String), String)

@external(erlang, "beacon_ws_test_ffi", "raw_connect")
fn raw_connect(host: String, port: Int) -> Result(RawSocket, String)

@external(erlang, "beacon_ws_test_ffi", "raw_send")
fn raw_send(socket: RawSocket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "beacon_ws_test_ffi", "raw_recv_frame")
fn raw_recv_frame(
  socket: RawSocket,
  timeout: Int,
) -> Result(#(Int, BitArray), String)

@external(erlang, "beacon_ws_test_ffi", "raw_close")
fn raw_close(socket: RawSocket) -> Nil

@external(erlang, "beacon_ws_test_ffi", "raw_upgrade_request")
fn raw_upgrade_request(
  path: String,
  host: String,
  headers: List(#(String, String)),
) -> BitArray
