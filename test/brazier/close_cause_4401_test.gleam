//// Close code 4401 is shared by three causes, told apart on the server.
////
//// The client answers every 4401 the same way (it reloads the page, see
//// WIRE_PROTOCOL.md), so the code stays shared. The server log line and the
//// `[brazier, ws, close]` event carry the cause as one label:
////
//// - `init_refused`: the app's `init` refused with 401;
//// - `session_revoked`: the session bound to the socket was revoked;
//// - `authentication_expired`: the periodic `ws_auth` re-check failed.
////
//// Each test asserts the close frame, the telemetry label and the log line
//// for one cause, so the log and the event cannot drift apart. Ordering,
//// not timing: the handler process logs the close and then emits the
//// event, both to this process, so once the event arrives the log line is
//// in the mailbox too.

import brazier/auth
import brazier/cluster/log_capture as node_log
import brazier/error
import brazier/monitored
import brazier/session
import brazier/telemetry.{type Event}
import brazier/transport
import brazier/transport/server.{type Connection}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub fn init_refused_with_401_is_labelled_init_refused_test() {
  let started = process.new_subject()
  let server =
    start_server(None, fn(conn_id) {
      process.send(started, conn_id)
      Error(transport.InitRefused(error.refuse(401, "signed out")))
    })
  let #(conn_id, logs) =
    node_log.capture(fn() {
      use events <- monitored.listening([["brazier", "ws", "close"]])
      let socket = upgrade(server, [])
      let assert Ok(conn_id) = process.receive(started, 3000)
        as "the runtime factory must be called"
      assert await_close_frame(socket) == #(4401, "init refused")
      assert_close_event(events, conn_id, "init_refused")
      raw_close(socket)
      conn_id
    })
  assert_close_line(logs, conn_id, "init_refused")
  server.stop(server.listener)
}

pub fn revoked_session_is_labelled_session_revoked_test() {
  // ws_session_auth binds the handler to the session (a pg join), so a
  // logout reaches the socket directly.
  session.ensure_registry()
  let store = session.new_store("close_cause_revoked")
  let assert Ok(sess) = auth.login(store, "user-1")
  let started = process.new_subject()
  let server =
    start_server(
      Some(auth.ws_session_auth(store, auth.dev_session_config())),
      fn(conn_id) {
        process.send(started, conn_id)
        Ok(#(fn(_, _) { Nil }, fn(_) { Nil }))
      },
    )
  let #(conn_id, logs) =
    node_log.capture(fn() {
      use events <- monitored.listening([["brazier", "ws", "close"]])
      let socket = upgrade(server, [cookie(sess.id)])
      let assert Ok(conn_id) = process.receive(started, 3000)
        as "the runtime factory must be called"
      let assert 1 = session.bound_process_count(store, sess.id)
      let assert Ok(Nil) = auth.logout(store, sess.id)
      assert await_close_frame(socket) == #(4401, "session revoked")
      assert_close_event(events, conn_id, "session_revoked")
      raw_close(socket)
      conn_id
    })
  assert_close_line(logs, conn_id, "session_revoked")
  server.stop(server.listener)
}

pub fn failed_recheck_is_labelled_authentication_expired_test() {
  // A ws_auth that does not bind the process: only the periodic re-check
  // sees the session go. Every run reports its result, so the test waits
  // for a passing re-check instead of sleeping past the interval.
  let store = session.new_store("close_cause_recheck")
  let assert Ok(sess) = auth.login(store, "user-1")
  let checks = process.new_subject()
  let check = fn(req: Request(Connection)) {
    let result = case
      session.id_from_request(req, auth.default_session_cookie_name)
    {
      Ok(id) ->
        case session.get(store, id) {
          Some(_) -> Ok(Nil)
          None -> Error("session gone")
        }
      Error(Nil) -> Error("no cookie")
    }
    process.send(checks, result)
    result
  }
  let started = process.new_subject()
  let server =
    start_server(Some(check), fn(conn_id) {
      process.send(started, conn_id)
      Ok(#(fn(_, _) { Nil }, fn(_) { Nil }))
    })
  let #(conn_id, logs) =
    node_log.capture(fn() {
      use events <- monitored.listening([["brazier", "ws", "close"]])
      let socket = upgrade(server, [cookie(sess.id)])
      let assert Ok(conn_id) = process.receive(started, 3000)
        as "the runtime factory must be called"
      // The upgrade's check, then one periodic re-check that passes.
      let assert Ok(Ok(Nil)) = process.receive(checks, 3000)
      let assert Ok(Ok(Nil)) = process.receive(checks, 3000)
      session.delete(store, sess.id)
      let assert Ok(Error("session gone")) = process.receive(checks, 3000)
      assert await_close_frame(socket) == #(4401, "authentication expired")
      assert_close_event(events, conn_id, "authentication_expired")
      raw_close(socket)
      conn_id
    })
  assert_close_line(logs, conn_id, "authentication_expired")
  server.stop(server.listener)
}

// --- Harness -----------------------------------------------------------------

type RawSocket

type Server {
  Server(port: Int, listener: server.Listener)
}

const host = "127.0.0.1"

fn start_server(
  ws_auth: Option(fn(Request(Connection)) -> Result(Nil, String)),
  factory: fn(String) ->
    Result(
      #(fn(String, transport.ClientMessage) -> Nil, fn(String) -> Nil),
      transport.StartupError,
    ),
) -> Server {
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: Some(fn(conn_id, _runtime, _req) { factory(conn_id) }),
      ws_auth: ws_auth,
      ssr_factory: None,
      security_limits: transport.SecurityLimits(
        ..transport.default_security_limits(),
        ws_auth_recheck_interval_ms: 100,
      ),
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "the test listener must start"
  Server(port: server.get_port(listener), listener: listener)
}

fn cookie(session_id: String) -> #(String, String) {
  #("Cookie", "brazier_session=" <> session_id)
}

/// Upgrade on `/` and expect the 101.
fn upgrade(server: Server, extra: List(#(String, String))) -> RawSocket {
  let authority = host <> ":" <> int.to_string(server.port)
  let headers = [
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    #("Sec-WebSocket-Version", "13"),
    #("Origin", "http://" <> authority),
    ..extra
  ]
  let assert Ok(socket) = raw_connect(host, server.port)
    as "test client must connect to the listener"
  let assert Ok(Nil) =
    raw_send(socket, raw_upgrade_request("/ws?path=%2F", authority, headers))
    as "test client send must succeed"
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
    as "the server must answer the upgrade"
  let assert Ok(head) = bit_array.to_string(head) as "the response head is text"
  assert string.slice(head, 9, 3) == "101"
  socket
}

/// The close frame's code and reason; a ping before it is skipped.
fn await_close_frame(socket: RawSocket) -> #(Int, String) {
  case raw_recv_frame(socket, 3000) {
    Ok(#(8, <<code:16, reason:bits>>)) -> {
      let assert Ok(reason) = bit_array.to_string(reason)
        as "a close reason is text"
      #(code, reason)
    }
    Ok(#(9, _ping)) -> await_close_frame(socket)
    Ok(#(opcode, _)) ->
      panic as { "expected a close frame, got opcode " <> int.to_string(opcode) }
    Error(reason) -> panic as { "expected a close frame: " <> reason }
  }
}

/// The close event of `conn_id` carries code 4401 and `label`.
fn assert_close_event(
  events: Subject(Event),
  conn_id: String,
  label: String,
) -> Nil {
  let assert Ok(event) = process.receive(events, 3000)
    as "the ws close summary must arrive"
  case telemetry.string(event, "connection_id") == Ok(conn_id) {
    // Another test's connection; the next one is checked.
    False -> assert_close_event(events, conn_id, label)
    True -> {
      assert telemetry.int(event, "close_code") == Ok(4401)
      assert telemetry.string(event, "reason") == Ok(label)
      Nil
    }
  }
}

/// Exactly one close line for `conn_id`, naming the code and the label.
fn assert_close_line(
  logs: List(node_log.Line),
  conn_id: String,
  label: String,
) -> Nil {
  let expected =
    "Closing WebSocket "
    <> conn_id
    <> " (peer 127.0.0.1) with 4401 (reason "
    <> label
    <> ")"
  let closes =
    list.filter(logs, fn(line) {
      string.contains(line.message, "Closing WebSocket " <> conn_id)
    })
  case closes {
    [node_log.Line(level: "info", message:)] -> {
      assert string.contains(message, expected)
        as { "the close line must contain: " <> expected }
      Nil
    }
    _ ->
      panic as {
        "expected one info close line for "
        <> conn_id
        <> ", got "
        <> string.inspect(closes)
      }
  }
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
