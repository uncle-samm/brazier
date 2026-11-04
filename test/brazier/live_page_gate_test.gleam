//// SEC-2: route-scoped middleware gates a live page, not only its dead
//// render. `middleware.only("/admin", auth)` refuses `GET /admin`, and the
//// same middleware refuses the WebSocket that mounts `/admin`
//// (`/ws?path=%2Fadmin`, closed with 4600 after the handshake), a `navigate` to `/admin` on a connection that
//// mounted another page, and a `join` that names `/admin`. A refused
//// navigation or join is answered with a hard navigation, so the browser's
//// page load gets the middleware's own answer, and it never reaches the
//// runtime. Everything runs over a real listener and a raw TCP client.
////
//// Ordering, not timing: a refused message is followed by an admitted one,
//// and the runtime's first message must be the admitted one.

import brazier/middleware
import brazier/telemetry.{type Event}
import brazier/transport
import brazier/transport/server
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- Harness ---

type RawSocket

type Observed {
  Connected(conn_id: String)
  GotEvent(conn_id: String, msg: transport.ClientMessage)
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

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

const host = "127.0.0.1"

const admin_cookie = #("Cookie", "role=admin")

/// The app's admin guard: 403 unless the request carries `role=admin`.
fn require_admin() -> middleware.Middleware {
  fn(req: request.Request(server.Connection), next) {
    case request.get_header(req, "cookie") {
      Ok("role=admin") -> next(req)
      _ ->
        response.new(403)
        |> response.set_body(server.Bytes(bytes_tree.from_string("forbidden")))
    }
  }
}

fn start_server() -> #(server.Listener, Int, Subject(Observed)) {
  let observer = process.new_subject()
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [middleware.only("/admin", require_admin())],
      static_config: None,
      runtime_factory: Some(fn(conn_id, _runtime, _req) {
        process.send(observer, Connected(conn_id))
        Ok(
          #(fn(cid, msg) { process.send(observer, GotEvent(cid, msg)) }, fn(_) {
            Nil
          }),
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

fn host_header(port: Int) -> String {
  host <> ":" <> int.to_string(port)
}

/// Send one request head and return the response's status code.
fn request_status(
  port: Int,
  target: String,
  headers: List(#(String, String)),
) -> #(RawSocket, String) {
  let assert Ok(socket) = raw_connect(host, port)
  let assert Ok(Nil) =
    raw_send(socket, raw_upgrade_request(target, host_header(port), headers))
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
    as "the server must answer the request"
  let assert Ok(head) = bit_array.to_string(head)
  #(socket, string.slice(head, 9, 3))
}

fn upgrade_headers(
  port: Int,
  extra: List(#(String, String)),
) -> List(#(String, String)) {
  [
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    #("Sec-WebSocket-Version", "13"),
    #("Origin", "http://" <> host_header(port)),
    ..extra
  ]
}

/// Upgrade on `page` (already percent-encoded) and wait for the runtime.
fn open(
  port: Int,
  observer: Subject(Observed),
  page: String,
  extra: List(#(String, String)),
) -> #(RawSocket, String) {
  let #(socket, status) =
    request_status(port, "/ws?path=" <> page, upgrade_headers(port, extra))
  let assert "101" = status
  let assert Ok(Connected(conn_id)) = process.receive(observer, 3000)
    as "the runtime factory must be called"
  #(socket, conn_id)
}

fn send_text(socket: RawSocket, text: String) -> Nil {
  let assert Ok(Nil) = raw_send(socket, masked_frame(1, 1, <<text:utf8>>))
    as "test client send must succeed"
  Nil
}

/// The next text frame (pings are skipped).
fn recv_text(socket: RawSocket) -> String {
  case raw_recv_frame(socket, 3000) {
    Ok(#(1, payload)) -> {
      let assert Ok(text) = bit_array.to_string(payload)
        as "text frames carry UTF-8"
      text
    }
    Ok(#(9, _ping)) -> recv_text(socket)
    Ok(#(opcode, _)) ->
      panic as { "expected a text frame, got opcode " <> int.to_string(opcode) }
    Error(reason) -> panic as { "expected a text frame: " <> reason }
  }
}

fn navigate_json(path: String) -> String {
  "{\"type\":\"navigate\",\"path\":" <> json_string(path) <> "}"
}

fn join_json(path: String) -> String {
  "{\"type\":\"join\",\"token\":\"\",\"path\":" <> json_string(path) <> "}"
}

fn hard_navigate_json(path: String) -> String {
  "{\"type\":\"hard_navigate\",\"path\":" <> json_string(path) <> "}"
}

fn json_string(text: String) -> String {
  "\"" <> text <> "\""
}

const navigation_refused = ["brazier", "ws", "navigation_refused"]

fn listen() -> #(String, Subject(Event)) {
  let assert Ok(Nil) = telemetry.start()
  let id = "live_page_gate_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let assert Ok(Nil) =
    telemetry.attach(
      id,
      [navigation_refused, ["brazier", "ws", "upgrade", "stop"]],
      fn(event) { process.send(events, event) },
    )
  #(id, events)
}

/// The first event named `name` for which `matches` holds; others are
/// skipped.
fn expect(
  events: Subject(Event),
  name: List(String),
  matches: fn(Event) -> Bool,
) -> Event {
  let assert Ok(event) = process.receive(events, 3000)
    as "expected telemetry event did not arrive within 3s"
  case event.name == name && matches(event) {
    True -> event
    False -> expect(events, name, matches)
  }
}

// --- The dead render ---

pub fn get_of_the_admin_page_is_refused_by_its_middleware_test() {
  let #(listener, port, _observer) = start_server()
  let #(socket, status) = request_status(port, "/admin", [])
  let assert "403" = status
  raw_close(socket)
  let #(socket, status) = request_status(port, "/admin/users", [])
  let assert "403" = status
  raw_close(socket)
  let #(socket, status) = request_status(port, "/admin", [admin_cookie])
  let assert False = status == "403"
  raw_close(socket)
  server.stop(listener)
}

// --- The live mount ---

pub fn websocket_mounting_the_admin_page_is_refused_test() {
  let #(listener, port, observer) = start_server()
  let #(id, events) = listen()
  // `/admin`, and readings of it the router also resolves to `/admin`.
  list.each(
    ["%2Fadmin", "%2Fadmin%2Fusers", "%2F%2561dmin", "%2Fx%2F..%2Fadmin"],
    fn(page) {
      let #(socket, status) =
        request_status(port, "/ws?path=" <> page, upgrade_headers(port, []))
      // The handshake completes, then the socket closes with 4600 and the
      // middleware's status: a browser cannot read a refused upgrade's.
      let assert True = status == "101" as { "upgrade on " <> page }
      let assert Ok(#(8, <<4600:16, reason:bits>>)) =
        raw_recv_frame(socket, 3000)
        as "a refused mount closes with 4600"
      let assert <<"middleware refused 403">> = reason
      let stop =
        expect(events, ["brazier", "ws", "upgrade", "stop"], fn(_) { True })
      let assert Ok("rejected_middleware") = telemetry.string(stop, "result")
      raw_close(socket)
    },
  )
  // No runtime was started for any of them.
  let assert Error(Nil) = process.receive(observer, 0)
  // The admin, and any other page, still mount.
  let #(socket, _conn_id) = open(port, observer, "%2Fadmin", [admin_cookie])
  raw_close(socket)
  let #(socket, _conn_id) = open(port, observer, "%2F", [])
  raw_close(socket)
  let assert Ok(Nil) = telemetry.detach(id)
  server.stop(listener)
}

pub fn websocket_without_a_page_or_with_a_foreign_one_is_400_test() {
  let #(listener, port, observer) = start_server()
  list.each(
    ["/ws", "/ws?other=1", "/ws?path=%2F%2Fevil.example", "/ws?path=admin"],
    fn(target) {
      let #(socket, status) =
        request_status(port, target, upgrade_headers(port, []))
      let assert True = status == "400" as { "upgrade on " <> target }
      raw_close(socket)
    },
  )
  let assert Error(Nil) = process.receive(observer, 0)
  server.stop(listener)
}

// --- Navigation on a live connection ---

pub fn navigation_to_the_admin_page_is_answered_with_a_hard_navigation_test() {
  let #(listener, port, observer) = start_server()
  let #(id, events) = listen()
  let #(socket, conn_id) = open(port, observer, "%2F", [])
  list.each(["/admin", "/admin/users?tab=1", "/%61dmin", "//admin"], fn(path) {
    case path {
      // Not a same-origin path at all: an error, never a page load.
      "//" <> _ -> {
        send_text(socket, navigate_json(path))
        let assert "{\"type\":\"error\",\"reason\":\"Invalid page path\"}" =
          recv_text(socket)
        let refused =
          expect(events, navigation_refused, fn(event) {
            telemetry.string(event, "connection_id") == Ok(conn_id)
          })
        let assert Ok(400) = telemetry.int(refused, "status")
      }
      _ -> {
        send_text(socket, navigate_json(path))
        let assert True = recv_text(socket) == hard_navigate_json(path)
        let refused =
          expect(events, navigation_refused, fn(event) {
            telemetry.string(event, "connection_id") == Ok(conn_id)
          })
        let assert Ok("navigate") = telemetry.string(refused, "kind")
        let assert Ok(403) = telemetry.int(refused, "status")
      }
    }
  })
  // None of them reached the runtime: its first message is this one.
  send_text(socket, navigate_json("/about"))
  let assert Ok(GotEvent(cid, transport.ClientNavigate(path: "/about", ..))) =
    process.receive(observer, 3000)
  let assert True = cid == conn_id
  raw_close(socket)
  let assert Ok(Nil) = telemetry.detach(id)
  server.stop(listener)
}

pub fn navigation_to_the_admin_page_with_the_cookie_is_admitted_test() {
  let #(listener, port, observer) = start_server()
  let #(socket, conn_id) = open(port, observer, "%2F", [admin_cookie])
  send_text(socket, navigate_json("/admin"))
  let assert Ok(GotEvent(cid, transport.ClientNavigate(path: "/admin", ..))) =
    process.receive(observer, 3000)
  let assert True = cid == conn_id
  raw_close(socket)
  server.stop(listener)
}

// --- Joins (the first join and every rejoin) ---

pub fn join_naming_the_admin_page_is_answered_with_a_hard_navigation_test() {
  let #(listener, port, observer) = start_server()
  let #(id, events) = listen()
  let #(socket, conn_id) = open(port, observer, "%2F", [])
  send_text(socket, join_json("/admin"))
  let assert True = recv_text(socket) == hard_navigate_json("/admin")
  let refused =
    expect(events, navigation_refused, fn(event) {
      telemetry.string(event, "connection_id") == Ok(conn_id)
    })
  let assert Ok("join") = telemetry.string(refused, "kind")
  let assert Ok(403) = telemetry.int(refused, "status")
  // A join for the page the upgrade passed is dispatched, and it is the
  // runtime's first message.
  send_text(socket, join_json("/"))
  let assert Ok(GotEvent(cid, transport.ClientJoin(token: "", path: "/"))) =
    process.receive(observer, 3000)
  let assert True = cid == conn_id
  raw_close(socket)
  let assert Ok(Nil) = telemetry.detach(id)
  server.stop(listener)
}

pub fn rejoin_after_a_refused_navigation_is_still_refused_test() {
  // The page a connection passed the gate for moves only on an admitted
  // navigation: a refused navigation followed by a join for the same page
  // is refused again.
  let #(listener, port, observer) = start_server()
  let #(socket, _conn_id) = open(port, observer, "%2F", [])
  send_text(socket, navigate_json("/admin"))
  let assert True = recv_text(socket) == hard_navigate_json("/admin")
  send_text(socket, join_json("/admin"))
  let assert True = recv_text(socket) == hard_navigate_json("/admin")
  let assert Error(Nil) = process.receive(observer, 0)
  raw_close(socket)
  server.stop(listener)
}
