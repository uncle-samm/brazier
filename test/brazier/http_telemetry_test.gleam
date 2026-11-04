/// Telemetry emitted by the HTTP transport, observed over real sockets:
/// the `[brazier, http, request]` span around request handling and the
/// `[brazier, http, connection, *]` lifecycle events.
///
/// Handlers run in the emitting process (a connection process, an acceptor
/// or the connection owner), so each test forwards events to its own
/// subject and synchronizes on them; nothing sleeps.
import brazier/api
import brazier/middleware
import brazier/ssr
import brazier/static
import brazier/telemetry.{type Event}
import brazier/transport
import brazier/transport/http as transport_http
import brazier/transport/server.{type Connection, type Socket, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

// --- Test server ------------------------------------------------------------

fn handler(
  req: Request(Connection),
) -> option.Option(response.Response(server.ResponseBody)) {
  case req.path {
    "/items/" <> _id -> {
      transport_http.tag_route("/items/:id")
      case transport_http.read_body(req, 1000) {
        Ok(body) -> Some(text(201, "got " <> bits_to_string(body)))
        Error(reason) -> Some(text(400, reason))
      }
    }
    "/explode/" <> _ -> {
      transport_http.tag_route("/explode/:x")
      crash()
    }
    _ -> Some(text(203, "untagged"))
  }
}

fn text(status: Int, body: String) {
  response.new(status)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

fn bits_to_string(bits: BitArray) -> String {
  case bit_array.to_string(bits) {
    Ok(value) -> value
    Error(Nil) -> "<binary>"
  }
}

fn start_server(limits: transport.SecurityLimits) -> server.Listener {
  let assert Ok(Nil) = telemetry.start()
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_id, _subject) { Nil },
      on_event: fn(_id, _msg) { Nil },
      on_disconnect: fn(_id) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: None,
      ws_auth: None,
      ssr_factory: None,
      security_limits: limits,
      api_handler: Some(handler),
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "test listener must bind an OS-assigned port"
  listener
}

fn limits() -> transport.SecurityLimits {
  transport.SecurityLimits(
    ..transport.default_security_limits(),
    keepalive_idle_timeout_ms: 2000,
    request_timeout_ms: 2000,
  )
}

fn open(listener: server.Listener) -> Socket {
  let assert Ok(socket) = raw_connect(server.get_port(listener))
    as "test client must connect to the listener"
  socket
}

fn request(socket: Socket, data: String) -> RawResponse {
  let assert Ok(Nil) = raw_send(socket, <<data:utf8>>)
    as "test client send must succeed"
  let assert Ok(resp) = raw_recv_response(socket, 2000, True)
    as "server must answer the request"
  resp
}

fn get(path: String) -> String {
  "GET " <> path <> " HTTP/1.1\r\nHost: test\r\n\r\n"
}

fn post(path: String, body: String) -> String {
  "POST "
  <> path
  <> " HTTP/1.1\r\nHost: test\r\ncontent-length: "
  <> int.to_string(string.byte_size(body))
  <> "\r\n\r\n"
  <> body
}

// --- Event helpers ----------------------------------------------------------

const request_events = [
  ["brazier", "http", "request", "start"],
  ["brazier", "http", "request", "stop"],
  ["brazier", "http", "request", "exception"],
]

const connection_events = [
  ["brazier", "http", "connection", "accepted"],
  ["brazier", "http", "connection", "rejected"],
  ["brazier", "http", "connection", "closed"],
]

fn unique(label: String) -> String {
  label <> "_" <> int.to_string(unique_integer())
}

/// Attach a handler forwarding `names` to a fresh subject owned by the
/// calling test process.
fn listen(names: List(List(String))) -> #(String, Subject(Event)) {
  let assert Ok(Nil) = telemetry.start()
  let id = unique("http_telemetry")
  let events = process.new_subject()
  let assert Ok(Nil) =
    telemetry.attach(id, names, fn(event) { process.send(events, event) })
  #(id, events)
}

/// Wait for the first event matching `matches`, returning it together with
/// the events received before it (oldest first). Events from other
/// listeners that happen to be live are skipped, never asserted on.
fn await(
  events: Subject(Event),
  matches: fn(Event) -> Bool,
) -> #(Event, List(Event)) {
  await_loop(events, matches, [])
}

fn await_loop(
  events: Subject(Event),
  matches: fn(Event) -> Bool,
  seen: List(Event),
) -> #(Event, List(Event)) {
  let assert Ok(event) = process.receive(events, 2000)
    as "expected telemetry event did not arrive within 2s"
  case matches(event) {
    True -> #(event, list.reverse(seen))
    False -> await_loop(events, matches, [event, ..seen])
  }
}

/// `await` for when only the arrival matters.
fn expect(events: Subject(Event), matches: fn(Event) -> Bool) -> Event {
  let #(event, _) = await(events, matches)
  event
}

fn named(event: Event, suffix: List(String)) -> Bool {
  event.name == list.append(["brazier", "http"], suffix)
}

fn has_string(event: Event, key: String, value: String) -> Bool {
  telemetry.string(event, key) == Ok(value)
}

fn accepted(event: Event) -> Bool {
  named(event, ["connection", "accepted"])
}

fn closed_with(reason: String) -> fn(Event) -> Bool {
  fn(event) {
    named(event, ["connection", "closed"])
    && has_string(event, "reason", reason)
  }
}

fn stop_for_route(route: String) -> fn(Event) -> Bool {
  fn(event) {
    named(event, ["request", "stop"]) && has_string(event, "route", route)
  }
}

/// True when `needle` appears in any metadata value of `event`.
fn metadata_mentions(event: Event, needle: String) -> Bool {
  list.any(dict.values(event.metadata), fn(value) {
    string.contains(string.inspect(value), needle)
  })
}

// --- [brazier, http, request] ------------------------------------------------

pub fn request_span_reports_route_status_and_body_sizes_test() {
  let listener = start_server(limits())
  let #(id, events) = listen(request_events)
  let socket = open(listener)
  let assert #(201, _, "got hello") =
    request(socket, post("/items/42", "hello"))

  let #(stop, before) = await(events, stop_for_route("/items/:id"))
  let assert Ok(201) = telemetry.int(stop, "status")
  let assert Ok(5) = telemetry.int(stop, "req_body_bytes")
  let assert Ok(9) = telemetry.int(stop, "resp_body_bytes")
  let assert Ok(duration) = telemetry.int(stop, "duration")
  let assert True = duration >= 0
  let assert Ok("POST") = telemetry.string(stop, "method")
  let assert Ok(connection_id) = telemetry.string(stop, "connection_id")
  let assert True = string.starts_with(connection_id, "<")

  // The matching start event came first, from the same connection, and
  // carries no route or status: neither is known before routing.
  let assert Ok(start) =
    list.find(before, fn(event) {
      named(event, ["request", "start"])
      && has_string(event, "connection_id", connection_id)
    })
  let assert Ok("POST") = telemetry.string(start, "method")
  let assert Error(Nil) = dict.get(start.metadata, "route")
  let assert Error(Nil) = dict.get(start.metadata, "status")

  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(socket)
  server.stop(listener)
}

pub fn keep_alive_requests_share_a_connection_id_test() {
  let listener = start_server(limits())
  let #(id, events) = listen(request_events)
  let socket = open(listener)
  let assert #(201, _, _) = request(socket, post("/items/1", "x"))
  let assert #(201, _, _) = request(socket, post("/items/2", "y"))
  let first = expect(events, stop_for_route("/items/:id"))
  let second = expect(events, stop_for_route("/items/:id"))
  let assert Ok(first_id) = telemetry.string(first, "connection_id")
  let assert Ok(second_id) = telemetry.string(second, "connection_id")
  let assert True = first_id == second_id
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(socket)
  server.stop(listener)
}

pub fn untagged_request_reports_unknown_never_the_raw_path_test() {
  let listener = start_server(limits())
  let #(id, events) = listen(request_events)
  let socket = open(listener)
  let path = "/private/" <> unique("user")
  let assert #(203, _, _) = request(socket, get(path))
  let stop =
    expect(events, fn(event) {
      named(event, ["request", "stop"])
      && telemetry.int(event, "status") == Ok(203)
    })
  let assert Ok("unknown") = telemetry.string(stop, "route")
  let assert Ok("GET") = telemetry.string(stop, "method")
  let assert Ok(0) = telemetry.int(stop, "req_body_bytes")
  let assert False = metadata_mentions(stop, path)
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(socket)
  server.stop(listener)
}

pub fn route_tag_does_not_leak_into_the_next_request_test() {
  let listener = start_server(limits())
  let #(id, events) = listen(request_events)
  let socket = open(listener)
  // Same connection process: the tag from the first request must be gone
  // when the second, untagged one is reported.
  let assert #(201, _, _) = request(socket, post("/items/3", "z"))
  let assert #(203, _, _) = request(socket, get("/plain"))
  let tagged = expect(events, stop_for_route("/items/:id"))
  let untagged =
    expect(events, fn(event) {
      named(event, ["request", "stop"])
      && telemetry.int(event, "status") == Ok(203)
    })
  let assert True =
    telemetry.string(tagged, "connection_id")
    == telemetry.string(untagged, "connection_id")
  let assert Ok("unknown") = telemetry.string(untagged, "route")
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(socket)
  server.stop(listener)
}

pub fn crashing_request_handler_reports_500_test() {
  let listener = start_server(limits())
  let #(id, events) = listen(request_events)
  let socket = open(listener)
  let assert #(500, _, _) = request(socket, get("/explode/now"))
  let #(stop, before) = await(events, stop_for_route("/explode/:x"))
  // The crash is caught inside the span: a stop with status 500, not an
  // exception event (that is reserved for a crash in Brazier itself).
  let assert Ok(500) = telemetry.int(stop, "status")
  let assert Ok(0) = telemetry.int(stop, "resp_body_bytes")
  let assert False =
    list.any(before, fn(event) { named(event, ["request", "exception"]) })
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(socket)
  server.stop(listener)
}

pub fn crashing_telemetry_handler_does_not_break_the_request_test() {
  let listener = start_server(limits())
  let crashing = unique("crashing_http_handler")
  let assert Ok(Nil) = telemetry.start()
  let assert Ok(Nil) =
    telemetry.attach(crashing, [["brazier", "http", "request", "stop"]], fn(_) {
      panic as "telemetry handler crashed on purpose"
    })
  let #(watcher, failures) = listen([["telemetry", "handler", "failure"]])
  let socket = open(listener)
  // The request that ran the crashing handler is answered normally, on a
  // connection that stays usable.
  let assert #(201, _, "got ok") = request(socket, post("/items/7", "ok"))
  let failure =
    expect(failures, fn(event) { has_string(event, "handler_id", crashing) })
  let assert Ok("error") = telemetry.string(failure, "kind")
  let assert #(201, _, "got ok") = request(socket, post("/items/8", "ok"))
  // telemetry detached the crashing handler.
  let assert Error(telemetry.NotAttached(_)) = telemetry.detach(crashing)
  let assert Ok(Nil) = telemetry.detach(watcher)
  raw_close(socket)
  server.stop(listener)
}

pub fn tag_route_rejects_empty_and_oversized_patterns_test() {
  let assert Error(_) = rescue(fn() { transport_http.tag_route("") })
  let assert Error(_) =
    rescue(fn() {
      transport_http.tag_route(string.repeat(
        "a",
        transport_http.max_route_tag_bytes + 1,
      ))
    })
  let assert Ok(Nil) =
    rescue(fn() {
      transport_http.tag_route(string.repeat(
        "a",
        transport_http.max_route_tag_bytes,
      ))
    })
}

// --- Route tags of the built-in routes --------------------------------------

/// A server with every built-in route: API routes, static files, pages and
/// (with `middlewares`) the WebSocket middleware pass.
fn start_app_server(
  static_dir: String,
  middlewares: List(middleware.Middleware),
) -> server.Listener {
  let assert Ok(Nil) = telemetry.start()
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_id, _subject) { Nil },
      on_event: fn(_id, _msg) { Nil },
      on_disconnect: fn(_id) { Nil },
      page_html: Some(ssr.RenderedPage(
        html: "<html><body>page</body></html>",
        sign_join_token: fn(_fingerprint) { Ok("") },
        join_cookie: True,
        cookie_secure: False,
        status: 200,
      )),
      middlewares: middlewares,
      static_config: Some(static.StaticConfig(
        directory: static_dir,
        prefix: "/assets",
        max_age: 0,
      )),
      runtime_factory: None,
      ws_auth: None,
      ssr_factory: None,
      security_limits: limits(),
      api_handler: Some(
        api.routes([api.get("/api/items/", fn(_req) { api.text(200, "items") })]),
      ),
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "test listener must bind an OS-assigned port"
  listener
}

/// A fresh static directory. `unique` cannot name it: unique_integer
/// restarts in every VM, so two concurrent `gleam test` runs would share the
/// directory and one would delete it under the other. `create_directory`
/// (not `_all`) fails on a name that already exists.
fn static_dir() -> String {
  let dir = "/tmp/brazier_http_telemetry_static_" <> test_ffi_unique_ref()
  let assert Ok(Nil) = simplifile.create_directory(dir)
    as "test static directory must not exist yet"
  let assert Ok(Nil) = simplifile.write(dir <> "/app.css", "body{}")
    as "test static file must be writable"
  dir
}

/// The route of the next request stop whose status is `status`.
fn route_of_next(events: Subject(Event), status: Int) -> String {
  let stop =
    expect(events, fn(event) {
      named(event, ["request", "stop"])
      && telemetry.int(event, "status") == Ok(status)
    })
  let assert Ok(route) = telemetry.string(stop, "route")
  route
}

pub fn built_in_routes_report_their_pattern_never_the_path_test() {
  let dir = static_dir()
  let listener = start_app_server(dir, [])
  let #(id, events) = listen(request_events)
  let socket = open(listener)

  // An API route reports its declared, normalised path.
  let assert #(200, _, "items") = request(socket, get("/api/items"))
  let assert "/api/items" = route_of_next(events, 200)

  let assert #(200, _, _) = request(socket, get("/health"))
  let assert "/health" = route_of_next(events, 200)

  // A served static file reports the prefix pattern, not the file.
  let assert #(200, _, "body{}") = request(socket, get("/assets/app.css"))
  let assert "/assets/*" = route_of_next(events, 200)

  // A page reports the shared page pattern, whatever its path.
  let page = "/users/" <> unique("u")
  let assert #(200, _, _) = request(socket, get(page))
  let stop =
    expect(events, fn(event) {
      named(event, ["request", "stop"])
      && telemetry.int(event, "status") == Ok(200)
    })
  let assert Ok("/*") = telemetry.string(stop, "route")
  let assert False = metadata_mentions(stop, page)

  // A static method the files do not answer is a 405 on the static route.
  let assert #(405, _, _) =
    request(
      socket,
      "POST /assets/app.css HTTP/1.1\r\nHost: test\r\ncontent-length: 0\r\n\r\n",
    )
  let assert "/assets/*" = route_of_next(events, 405)

  let #(_, _, _) = request(socket, "OPTIONS * HTTP/1.1\r\nHost: test\r\n\r\n")
  let options =
    expect(events, fn(event) {
      named(event, ["request", "stop"])
      && has_string(event, "method", "OPTIONS")
    })
  let assert Ok("*") = telemetry.string(options, "route")

  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(socket)
  server.stop(listener)
  let assert Ok(Nil) = simplifile.delete(dir) as "test directory cleanup"
}

pub fn client_script_routes_are_tagged_test() {
  let dir = static_dir()
  let listener = start_app_server(dir, [])
  let #(id, events) = listen(request_events)
  let socket = open(listener)
  // The client script may or may not be built in this checkout: only the
  // tag is asserted, never the status.
  let #(_, _, _) = request(socket, get("/brazier_client.js"))
  let first = expect(events, fn(event) { named(event, ["request", "stop"]) })
  let assert Ok("/brazier_client.js") = telemetry.string(first, "route")
  let #(_, _, _) = request(socket, get("/brazier_client_0123456789abcdef.js"))
  let second = expect(events, fn(event) { named(event, ["request", "stop"]) })
  let assert Ok("/brazier_client_:hash") = telemetry.string(second, "route")
  // A name that is not a bundle name is an ordinary page path.
  let #(_, _, _) = request(socket, get("/brazier_client_nothex.js"))
  let third = expect(events, fn(event) { named(event, ["request", "stop"]) })
  let assert Ok("/*") = telemetry.string(third, "route")
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(socket)
  server.stop(listener)
  let assert Ok(Nil) = simplifile.delete(dir) as "test directory cleanup"
}

pub fn websocket_middleware_pass_reports_the_ws_route_test() {
  let dir = static_dir()
  let passthrough: middleware.Middleware = fn(req, next) { next(req) }
  let listener = start_app_server(dir, [passthrough])
  let #(id, events) = listen(request_events)
  let socket = open(listener)
  let upgrade =
    "GET /ws?path=%2F HTTP/1.1\r\nHost: test\r\nUpgrade: websocket\r\n"
    <> "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
    <> "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
  let assert Ok(Nil) = raw_send(socket, <<upgrade:utf8>>)
    as "test client send must succeed"
  let stop = expect(events, fn(event) { named(event, ["request", "stop"]) })
  let assert Ok("/ws") = telemetry.string(stop, "route")
  let assert Ok("GET") = telemetry.string(stop, "method")
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(socket)
  server.stop(listener)
  let assert Ok(Nil) = simplifile.delete(dir) as "test directory cleanup"
}

// --- [brazier, http, connection, *] ------------------------------------------

pub fn connection_accepted_and_closed_normally_test() {
  let listener = start_server(limits())
  let #(id, events) = listen(connection_events)
  let socket = open(listener)
  let event = expect(events, accepted)
  let assert Ok("ok") = telemetry.string(event, "reason")
  let assert Ok(1) = telemetry.int(event, "count")
  let assert Ok(handoff) = telemetry.int(event, "duration")
  let assert True = handoff >= 0
  let assert #(203, _, _) = request(socket, get("/"))
  raw_close(socket)
  let closed = expect(events, closed_with("normal"))
  let assert Ok(1) = telemetry.int(closed, "count")
  let assert Ok(lifetime) = telemetry.int(closed, "duration")
  let assert True = lifetime > 0
  let assert Ok(Nil) = telemetry.detach(id)
  server.stop(listener)
}

pub fn connection_over_global_cap_is_rejected_test() {
  let listener =
    start_server(transport.SecurityLimits(..limits(), max_connections: 1))
  let #(id, events) = listen(connection_events)
  let a = open(listener)
  let first = expect(events, accepted)
  let assert Ok("ok") = telemetry.string(first, "reason")
  let b = open(listener)
  let assert Ok(#(503, _, _)) = raw_recv_response(b, 2000, True)
    as "connection over the global cap must get 503"
  let rejected =
    expect(events, fn(event) { named(event, ["connection", "rejected"]) })
  let assert Ok("max_connections") = telemetry.string(rejected, "reason")
  let assert Ok(1) = telemetry.int(rejected, "count")
  let assert Ok(decision) = telemetry.int(rejected, "duration")
  let assert True = decision >= 0
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(b)
  raw_close(a)
  server.stop(listener)
}

pub fn connection_over_per_ip_cap_is_rejected_test() {
  let listener =
    start_server(
      transport.SecurityLimits(..limits(), max_connections_per_ip: 1),
    )
  let #(id, events) = listen(connection_events)
  let a = open(listener)
  let first = expect(events, accepted)
  let assert Ok("ok") = telemetry.string(first, "reason")
  let b = open(listener)
  let assert Ok(#(503, _, _)) = raw_recv_response(b, 2000, True)
    as "connection over the per-IP cap must get 503"
  let rejected =
    expect(events, fn(event) { named(event, ["connection", "rejected"]) })
  let assert Ok("max_connections_per_ip") = telemetry.string(rejected, "reason")
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(b)
  raw_close(a)
  server.stop(listener)
}

pub fn killed_and_crashed_connections_report_their_reason_test() {
  let listener = start_server(limits())
  let #(id, events) = listen(connection_events)
  let a = open(listener)
  let first = expect(events, accepted)
  let assert Ok("ok") = telemetry.string(first, "reason")
  let assert [pid_a] = server.get_connection_pids(listener)
  raw_kill(pid_a)
  let killed = expect(events, closed_with("killed"))
  let assert Ok(1) = telemetry.int(killed, "count")

  let b = open(listener)
  let second = expect(events, accepted)
  let assert Ok("ok") = telemetry.string(second, "reason")
  let assert [pid_b] = server.get_connection_pids(listener)
  exit_abnormally(pid_b)
  let crashed = expect(events, closed_with("crash"))
  // The crash reason itself is logged, never put in metadata.
  let assert False = metadata_mentions(crashed, "abnormal_exit")
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(a)
  raw_close(b)
  server.stop(listener)
}

pub fn stopping_the_listener_reports_shutdown_test() {
  let listener = start_server(limits())
  let #(id, events) = listen(connection_events)
  let socket = open(listener)
  let event = expect(events, accepted)
  let assert Ok("ok") = telemetry.string(event, "reason")
  server.stop(listener)
  let closed = expect(events, closed_with("shutdown"))
  let assert Ok(1) = telemetry.int(closed, "count")
  let assert Ok(Nil) = telemetry.detach(id)
  raw_close(socket)
}

// --- FFI --------------------------------------------------------------------

type RawResponse =
  #(Int, List(#(String, String)), String)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "brazier_test_ffi", "unique_ref")
fn test_ffi_unique_ref() -> String

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, dynamic.Dynamic))

@external(erlang, "brazier_http_raw_ffi", "connect")
fn raw_connect(port: Int) -> Result(Socket, String)

@external(erlang, "brazier_http_raw_ffi", "send")
fn raw_send(socket: Socket, data: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_http_raw_ffi", "recv_response")
fn raw_recv_response(
  socket: Socket,
  timeout_ms: Int,
  expect_body: Bool,
) -> Result(RawResponse, String)

@external(erlang, "brazier_http_raw_ffi", "close")
fn raw_close(socket: Socket) -> Nil

@external(erlang, "brazier_http_raw_ffi", "kill")
fn raw_kill(pid: process.Pid) -> Nil

@external(erlang, "brazier_http_raw_ffi", "crash")
fn crash() -> a

@external(erlang, "brazier_telemetry_test_ffi", "exit_abnormally")
fn exit_abnormally(pid: process.Pid) -> Nil
