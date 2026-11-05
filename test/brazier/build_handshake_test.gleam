/// The build-id handshake: a `join` carries the build id of the client
/// bundle its page loaded, and the server refuses a join from another build
/// with close 4499 so the page reloads (see `transport.check_join_build`).
/// Unhappy paths first: the check against a given loaded bundle, then joins
/// over a real listener and a raw TCP client, checked against the
/// repository's `priv/static` bundle.
import brazier/await
import brazier/log_capture
import brazier/ssr
import brazier/transport
import brazier/transport/server
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

// --- Harness ---

type RawSocket

type Observed {
  Connected(conn_id: String, handler: Pid)
  GotEvent(conn_id: String, msg: transport.ClientMessage)
  ClosedConn(conn_id: String)
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

@external(erlang, "brazier_ws_test_ffi", "masked_frame")
fn masked_frame(fin: Int, opcode: Int, payload: BitArray) -> BitArray

const host = "127.0.0.1"

fn start_server() -> #(server.Listener, Int, Subject(Observed)) {
  let observer = process.new_subject()
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: Some(fn(conn_id, _runtime, _req) {
        process.send(observer, Connected(conn_id, process.self()))
        Ok(
          #(
            fn(cid, msg) { process.send(observer, GotEvent(cid, msg)) },
            fn(cid) { process.send(observer, ClosedConn(cid)) },
          ),
        )
      }),
      ws_auth: None,
      ssr_factory: None,
      security_limits: transport.default_security_limits(),
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "the test listener must start"
  #(listener, server.get_port(listener), observer)
}

/// Upgrade a raw TCP connection and wait for the runtime factory.
fn open(port: Int, observer: Subject(Observed)) -> #(RawSocket, String, Pid) {
  let host_header = host <> ":" <> int.to_string(port)
  let assert Ok(socket) = raw_connect(host, port)
  let assert Ok(Nil) =
    raw_send(
      socket,
      raw_upgrade_request("/ws?path=%2F", host_header, [
        #("Upgrade", "websocket"),
        #("Connection", "Upgrade"),
        #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
        #("Sec-WebSocket-Version", "13"),
        #("Origin", "http://" <> host_header),
      ]),
    )
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
  let assert Ok(head) = bit_array.to_string(head)
  let assert "101" = string.slice(head, 9, 3)
  let assert Ok(Connected(conn_id, handler)) = process.receive(observer, 3000)
    as "the runtime factory must be called"
  #(socket, conn_id, handler)
}

/// Close the socket and wait until the server has run `on_close` for this
/// connection, so the notice is received here and not left for the next
/// test.
fn close(
  socket: RawSocket,
  observer: Subject(Observed),
  conn_id: String,
) -> Nil {
  raw_close(socket)
  let assert Ok(ClosedConn(closed)) = process.receive(observer, 5000)
    as "on_close must run"
  let assert True = closed == conn_id
  Nil
}

fn send_join(socket: RawSocket, build: Option(String)) -> Nil {
  let build_field = case build {
    Some(id) -> ",\"build\":\"" <> id <> "\""
    None -> ""
  }
  let text =
    "{\"type\":\"join\",\"token\":\"\",\"path\":\"/\"" <> build_field <> "}"
  let assert Ok(Nil) = raw_send(socket, masked_frame(1, 1, <<text:utf8>>))
  Nil
}

/// The code and reason of the server's close frame, skipping pings.
fn expect_close_frame(socket: RawSocket) -> #(Int, String) {
  case raw_recv_frame(socket, 5000) {
    Ok(#(8, <<code:16, reason:bits>>)) -> {
      let assert Ok(reason) = bit_array.to_string(reason)
      #(code, reason)
    }
    Ok(#(9, _ping)) -> expect_close_frame(socket)
    Ok(#(opcode, _)) ->
      panic as { "expected a close frame, got opcode " <> int.to_string(opcode) }
    Error(reason) -> panic as { "expected a close frame: " <> reason }
  }
}

/// The repository's current bundle build id, from its manifest.
fn current_build() -> String {
  let assert Ok(bundle) = ssr.client_bundle_name(ssr.client_assets_dir())
    as "the repository's priv/static must hold a built runtime bundle"
  let assert "brazier_client_" <> rest = bundle
  string.drop_end(rest, 3)
}

const loaded = Ok("brazier_client_0123456789abcdef.js")

// --- check_join_build against a given loaded bundle ---

pub fn no_loaded_bundle_refuses_with_1011_and_logs_an_error_test() {
  // The server could not load its bundle (a dev rebuild whose manifest is
  // broken): a join is not let through unchecked.
  let #(verdict, logs) =
    log_capture.capture(fn() {
      transport.check_join_build(
        Error("Cannot read priv/static/brazier_client.manifest"),
        "conn-a",
        "0123456789abcdef",
      )
    })
  let assert Error(#(1011, "internal error")) = verdict
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "conn-a", "brazier_client.manifest", "1011",
    ])
}

pub fn another_build_refuses_with_4499_test() {
  let #(verdict, logs) =
    log_capture.capture(fn() {
      transport.check_join_build(loaded, "conn-d", "fedcba9876543210")
    })
  let assert Error(#(4499, "stale build")) = verdict
  let assert True =
    log_capture.has(logs, level: "info", containing: [
      "conn-d", "\"fedcba9876543210\"", "brazier_client_0123456789abcdef.js",
      "4499",
    ])
  // A build id is matched exactly: no prefix, case or extension tricks.
  let assert Error(#(4499, "stale build")) =
    transport.check_join_build(loaded, "conn-d", "0123456789ABCDEF")
  let assert Error(#(4499, "stale build")) =
    transport.check_join_build(loaded, "conn-d", "01234567")
  let assert Error(#(4499, "stale build")) =
    transport.check_join_build(loaded, "conn-d", "")
  let assert Error(#(4499, "stale build")) =
    transport.check_join_build(loaded, "conn-d", "0123456789abcdef.js")
}

pub fn an_overlong_build_id_is_logged_truncated_test() {
  let long = string.repeat("a", 10_000)
  let #(verdict, logs) =
    log_capture.capture(fn() {
      transport.check_join_build(loaded, "conn-e", long)
    })
  let assert Error(#(4499, "stale build")) = verdict
  let assert True =
    log_capture.has(logs, level: "info", containing: [
      "\"" <> string.repeat("a", 64) <> "\"",
    ])
  let assert False =
    log_capture.has(logs, level: "info", containing: [string.repeat("a", 65)])
}

pub fn the_current_build_is_accepted_test() {
  let assert Ok(Nil) =
    transport.check_join_build(loaded, "conn-g", "0123456789abcdef")
}

// --- Joins over a real listener ---

pub fn a_join_from_another_build_closes_4499_and_reaches_no_runtime_test() {
  let #(listener, port, observer) = start_server()
  let #(socket, conn_id, handler) = open(port, observer)
  send_join(socket, Some("00000000deadbeef"))
  let assert #(4499, "stale build") = expect_close_frame(socket)
  let assert Ok(ClosedConn(closed)) = process.receive(observer, 5000)
    as "the join must not be dispatched, and on_close must run"
  let assert True = closed == conn_id
  await.expect_down(handler, "WebSocket handler " <> conn_id)
  raw_close(socket)
  server.stop(listener)
}

pub fn a_join_from_the_current_build_is_dispatched_test() {
  let build = current_build()
  let #(listener, port, observer) = start_server()
  let #(socket, conn_id, _handler) = open(port, observer)
  send_join(socket, Some(build))
  let assert Ok(GotEvent(cid, transport.ClientJoin(token: "", path: "/"))) =
    process.receive(observer, 3000)
    as "the join must be dispatched"
  let assert True = cid == conn_id
  close(socket, observer, conn_id)
  server.stop(listener)
}

pub fn a_join_without_a_build_is_dispatched_test() {
  let #(listener, port, observer) = start_server()
  let #(socket, conn_id, _handler) = open(port, observer)
  send_join(socket, None)
  let assert Ok(GotEvent(_, transport.ClientJoin(token: "", path: "/"))) =
    process.receive(observer, 3000)
    as "the join must be dispatched"
  close(socket, observer, conn_id)
  server.stop(listener)
}

pub fn a_build_that_is_not_a_string_is_a_decode_error_test() {
  // A wrong-typed build is a malformed join, counted like any decode error;
  // it is never dispatched.
  let #(listener, port, observer) = start_server()
  let #(socket, conn_id, _handler) = open(port, observer)
  let text = "{\"type\":\"join\",\"token\":\"\",\"path\":\"/\",\"build\":7}"
  let assert Ok(Nil) = raw_send(socket, masked_frame(1, 1, <<text:utf8>>))
  send_join(socket, None)
  let assert Ok(GotEvent(_, transport.ClientJoin(token: "", path: "/"))) =
    process.receive(observer, 3000)
    as "only the well-formed join is dispatched"
  close(socket, observer, conn_id)
  server.stop(listener)
}
