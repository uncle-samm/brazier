//// Stopping a listener drains its connections: a WebSocket is closed with
//// 1001, a request in flight completes with `connection: close`, an idle
//// keep-alive connection closes at once, and a handler still busy at the
//// drain deadline is killed. `wait_forever` stops its applications on
//// SIGTERM and returns at once when the application was stopped elsewhere;
//// `BEACON_SHUTDOWN_TIMEOUT` is validated at start.
////
//// Drains run with a 60s timeout where the connection must finish on its
//// own: a connection that ignored the drain would hold `stop` past the
//// test's timeout. Tests synchronize on traces, monitors, frames and socket
//// closes; nothing sleeps. SIGTERM and environment tests run on a peer node,
//// so the test VM's own signal handling and environment are untouched.

import beacon/app_config_fixture
import beacon/application.{type App}
import beacon/cluster/log_capture
import beacon/cluster/peer.{Timeout}
import beacon/effect
import beacon/error
import beacon/html
import beacon/transport
import beacon/transport/server
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Inc
}

type RawSocket

/// A request handler that is busy: its pid, and the subject that lets it
/// answer.
type Busy {
  Busy(handler: Pid, release: Subject(Nil))
}

const host = "127.0.0.1"

/// An app whose `/slow` handler reports itself on `busy` and answers only
/// once released; every other API path answers at once.
fn config(
  drain_timeout_ms: Int,
  busy: Subject(Busy),
) -> application.AppConfig(Model, Msg) {
  let base =
    app_config_fixture.new(
      port: 0,
      init: fn(_ctx) { Ok(#(Model(count: 0), effect.none())) },
      update: fn(model: Model, _msg) {
        #(Model(count: model.count + 1), effect.none())
      },
      view: fn(model: Model) {
        html.div([], [html.text(int.to_string(model.count))])
      },
      encode_model: fn(model: Model) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      },
      decode_event: fn(_name, _handler, _data, _path) { Ok(Inc) },
    )
  application.AppConfig(
    ..base,
    security_limits: transport.SecurityLimits(
      ..transport.default_security_limits(),
      drain_timeout_ms: drain_timeout_ms,
    ),
    api_handler: Some(fn(req: request.Request(server.Connection)) {
      case req.path {
        "/slow" -> {
          let release = process.new_subject()
          process.send(busy, Busy(handler: process.self(), release: release))
          let assert Ok(Nil) = process.receive(release, 60_000)
            as "the test releases the busy handler"
          Some(text_response("slow done"))
        }
        "/fast" -> Some(text_response("fast"))
        _ -> None
      }
    }),
  )
}

fn text_response(body: String) -> response.Response(server.ResponseBody) {
  response.new(200)
  |> response.set_body(server.Bytes(bytes_tree.from_string(body)))
}

fn start(drain_timeout_ms: Int) -> #(App, Subject(Busy)) {
  let busy = process.new_subject()
  let assert Ok(app) = application.start(config(drain_timeout_ms, busy))
  #(app, busy)
}

fn get(path: String, port: Int) -> BitArray {
  bit_array.from_string(
    "GET "
    <> path
    <> " HTTP/1.1\r\nHost: "
    <> host
    <> ":"
    <> int.to_string(port)
    <> "\r\n\r\n",
  )
}

/// Stop the app from another process; the result arrives on the subject.
fn stop_in_background(app: App) -> Subject(Result(Nil, error.BeaconError)) {
  let stopped = process.new_subject()
  process.spawn_unlinked(fn() { process.send(stopped, application.stop(app)) })
  stopped
}

pub fn websocket_is_closed_with_1001_when_the_listener_stops_test() {
  let #(app, _busy) = start(60_000)
  let socket = open_websocket(app.port)
  let assert Ok(Nil) = application.stop(app)
  let assert 1001 = await_close_code(socket)
  raw_close(socket)
  Nil
}

pub fn request_in_flight_completes_with_connection_close_test() {
  let #(app, busy) = start(60_000)
  let assert Ok(socket) = connect(app.port)
  let assert Ok(Nil) = send(socket, get("/slow", app.port))
  let assert Ok(Busy(handler:, release:)) = process.receive(busy, 5000)
    as "the slow handler must start"
  trace_receive(handler)
  let stopped = stop_in_background(app)
  // The handler is told to drain while its request is still running...
  let assert Ok(Nil) = await_drain_received(handler, 5000)
  process.send(release, Nil)
  // ...so it finishes the request and announces the close.
  let assert Ok(#(200, headers, <<"slow done">>)) = read_response(socket, 5000)
  let assert Ok("close") = list.key_find(headers, "connection")
  let assert Ok(Nil) = await_closed(socket, 5000)
  let assert Ok(Ok(Nil)) = process.receive(stopped, 10_000)
  Nil
}

pub fn idle_keep_alive_connection_closes_at_once_test() {
  let #(app, _busy) = start(60_000)
  let assert Ok(socket) = connect(app.port)
  let assert Ok(Nil) = send(socket, get("/fast", app.port))
  let assert Ok(#(200, headers, <<"fast">>)) = read_response(socket, 5000)
  // Kept alive: the connection now waits for its next request.
  let assert Error(Nil) = list.key_find(headers, "connection")
  let #(stopped, logs) = log_capture.capture(fn() { application.stop(app) })
  let assert Ok(Nil) = stopped
  let assert Ok(Nil) = await_closed(socket, 5000)
  let assert True = log_capture.contains(logs, "info", "drained 1 connections")
  Nil
}

pub fn connection_busy_past_the_deadline_is_killed_test() {
  let #(app, busy) = start(100)
  let assert Ok(socket) = connect(app.port)
  let assert Ok(Nil) = send(socket, get("/slow", app.port))
  let assert Ok(Busy(handler:, release: _)) = process.receive(busy, 5000)
    as "the slow handler must start"
  let monitor = process.monitor(handler)
  // Never released: the handler outlives the 100ms drain and is killed.
  let #(stopped, logs) = log_capture.capture(fn() { application.stop(app) })
  let assert Ok(Nil) = stopped
  let assert Ok(process.ProcessDown(reason: process.Killed, ..)) =
    process.selector_receive(
      process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down }),
      5000,
    )
  let assert Ok(Nil) = await_closed(socket, 5000)
  let assert True =
    log_capture.contains(
      logs,
      "error",
      "1 of 1 connections did not finish within the 100ms drain timeout, killing",
    )
  Nil
}

/// Start an app in a new process that then blocks in `wait_forever`, as
/// `main` does. Returns once its SIGTERM handler is installed, with the
/// subject told when `wait_forever` returns.
fn start_waiting() -> #(App, Subject(Nil)) {
  let ready = process.new_subject()
  let started = process.new_subject()
  let returned = process.new_subject()
  let waiter =
    process.spawn_unlinked(fn() {
      let go = process.new_subject()
      process.send(ready, go)
      let assert Ok(Nil) = process.receive(go, 5000)
      let assert Ok(app) =
        application.start_supervised(config(60_000, process.new_subject()))
      process.send(started, app)
      application.wait_forever()
      process.send(returned, Nil)
    })
  let assert Ok(go) = process.receive(ready, 5000)
  trace_install(waiter)
  process.send(go, Nil)
  let assert Ok(app) = process.receive(started, 5000)
    as "the application must start"
  let assert Ok(Nil) = await_install(waiter, 5000)
  #(app, returned)
}

pub fn sigterm_drains_and_wait_forever_returns_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "ws8c_drain_sigterm")
  let assert [p] = peers
  let outcome =
    peer.on(p, fn() {
      let #(app, returned) = start_waiting()
      let during = signal_handlers()
      let socket = open_websocket(app.port)
      sigterm_self()
      // The open WebSocket is drained, then wait_forever returns and the
      // node keeps running.
      let code = await_close_code(socket)
      raw_close(socket)
      let assert Ok(Nil) = process.receive(returned, 5000)
        as "wait_forever must return after SIGTERM"
      #(during, code, process.is_alive(app.supervisor_pid), signal_handlers())
    })
  let assert #(["beacon_signal_handler"], 1001, False, ["erl_signal_handler"]) =
    outcome
  Nil
}

pub fn wait_forever_returns_when_the_application_is_stopped_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "ws8c_drain_stopped")
  let assert [p] = peers
  let handlers =
    peer.on(p, fn() {
      let #(app, returned) = start_waiting()
      let assert Ok(Nil) = application.stop(app)
      // No drain wait of its own: the stop already drained.
      let assert Ok(Nil) = process.receive(returned, 5000)
        as "wait_forever must return once the application stopped"
      signal_handlers()
    })
  let assert ["erl_signal_handler"] = handlers
  Nil
}

pub fn shutdown_timeout_environment_is_validated_at_start_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "ws8c_drain_env")
  let assert [p] = peers
  let #(word, negative, valid) =
    peer.on(p, fn() {
      let attempt = fn(value: String) {
        putenv("BEACON_SHUTDOWN_TIMEOUT", value)
        let result = application.start(config(5000, process.new_subject()))
        unsetenv("BEACON_SHUTDOWN_TIMEOUT")
        case result {
          Ok(app) -> {
            let assert Ok(Nil) = application.stop(app)
            Ok(app.drain_timeout_ms)
          }
          Error(err) -> Error(error.to_string(err))
        }
      }
      #(attempt("soon"), attempt("-1"), attempt("250"))
    })
  let assert Error(word) = word
  let assert True = string.contains(word, "BEACON_SHUTDOWN_TIMEOUT")
  let assert Error(negative) = negative
  let assert True = string.contains(negative, "drain_timeout_ms must be in 0..")
  let assert Ok(250) = valid
  Nil
}

pub fn invalid_drain_timeout_is_refused_test() {
  let assert Error(_) = transport.validate_drain_timeout(-1)
  let assert Error(_) = transport.validate_drain_timeout(4_294_967_296)
  let assert Ok(Nil) = transport.validate_drain_timeout(0)
  let options =
    server.ListenerOptions(
      ..server.default_listener_options(0),
      drain_timeout_ms: -1,
    )
  let assert Error(reason) = server.start(options, fn(_socket) { Nil })
  let assert True = string.contains(reason, "drain_timeout_ms")
  Nil
}

// --- WebSocket helpers ---

fn open_websocket(port: Int) -> WsSocket {
  let authority = host <> ":" <> int.to_string(port)
  let assert Ok(socket) = raw_connect(host, port)
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
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 5000)
    as "server must answer the upgrade request"
  let assert Ok(head) = bit_array.to_string(head)
  let assert "101" = string.slice(head, 9, 3)
  socket
}

/// Skip data frames until the close frame; return its code.
fn await_close_code(socket: WsSocket) -> Int {
  case raw_recv_frame(socket, 5000) {
    Ok(#(8, <<code:16, _reason:bits>>)) -> code
    Ok(#(_opcode, _payload)) -> await_close_code(socket)
    Error(reason) -> panic as { "no close frame: " <> reason }
  }
}

type WsSocket

@external(erlang, "beacon_ws_test_ffi", "raw_connect")
fn raw_connect(host: String, port: Int) -> Result(WsSocket, String)

@external(erlang, "beacon_ws_test_ffi", "raw_send")
fn raw_send(socket: WsSocket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "beacon_ws_test_ffi", "raw_recv_frame")
fn raw_recv_frame(
  socket: WsSocket,
  timeout: Int,
) -> Result(#(Int, BitArray), String)

@external(erlang, "beacon_ws_test_ffi", "raw_close")
fn raw_close(socket: WsSocket) -> Nil

@external(erlang, "beacon_ws_test_ffi", "raw_upgrade_request")
fn raw_upgrade_request(
  path: String,
  host: String,
  headers: List(#(String, String)),
) -> BitArray

// --- HTTP, trace, signal and environment helpers ---

@external(erlang, "beacon_ws8c_drain_ffi", "connect")
fn connect(port: Int) -> Result(RawSocket, String)

@external(erlang, "beacon_ws8c_drain_ffi", "send")
fn send(socket: RawSocket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "beacon_ws8c_drain_ffi", "read_response")
fn read_response(
  socket: RawSocket,
  timeout: Int,
) -> Result(#(Int, List(#(String, String)), BitArray), String)

@external(erlang, "beacon_ws8c_drain_ffi", "await_closed")
fn await_closed(socket: RawSocket, timeout: Int) -> Result(Nil, String)

@external(erlang, "beacon_ws8c_drain_ffi", "trace_receive")
fn trace_receive(pid: Pid) -> Nil

@external(erlang, "beacon_ws8c_drain_ffi", "await_drain_received")
fn await_drain_received(pid: Pid, timeout: Int) -> Result(Nil, String)

@external(erlang, "beacon_ws8c_drain_ffi", "trace_install")
fn trace_install(pid: Pid) -> Nil

@external(erlang, "beacon_ws8c_drain_ffi", "await_install")
fn await_install(pid: Pid, timeout: Int) -> Result(Nil, String)

@external(erlang, "beacon_ws8c_drain_ffi", "sigterm_self")
fn sigterm_self() -> Nil

@external(erlang, "beacon_ws8c_drain_ffi", "signal_handlers")
fn signal_handlers() -> List(String)

@external(erlang, "beacon_ws8c_drain_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

@external(erlang, "beacon_ws8c_drain_ffi", "unsetenv")
fn unsetenv(name: String) -> Nil
