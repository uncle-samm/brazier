//// A WebSocket mount that route middleware refuses completes the handshake
//// and closes with 4600, `middleware refused <status>`: a browser cannot
//// read the HTTP status of a refused upgrade, so a plain 403 would look
//// like a network failure and the client would retry it forever. The
//// client answers 4600 with a page load, which shows the middleware's own
//// answer (Phoenix LiveView: `view.ts` `onJoinError` navigates to the
//// page's URL when a join is refused as unauthorized).
////
//// The checks before the middleware (origin, ws_auth, handshake) still
//// answer with an HTTP status and never consult the middleware, so a
//// cross-origin page learns nothing about the app's routes.

import brazier/cluster/log_capture
import brazier/middleware
import brazier/raw_ws
import brazier/telemetry.{type Event}
import brazier/transport
import brazier/transport/server
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

type Observed {
  Connected(conn_id: String)
  Gated(path: String)
}

/// `/admin` needs `role=admin`; `/old` redirects; `/boom` crashes. Every
/// call is reported, so a test can see whether the middleware ran.
fn gate(observer: Subject(Observed)) -> middleware.Middleware {
  fn(req: request.Request(server.Connection), next) {
    process.send(observer, Gated(req.path))
    case req.path, request.get_header(req, "cookie") {
      "/admin", Ok("role=admin") -> next(req)
      "/admin", _ ->
        response.new(403)
        |> response.set_body(server.Bytes(bytes_tree.from_string("forbidden")))
      "/old", _ ->
        response.new(302)
        |> response.set_header("location", "/new")
        |> response.set_body(server.Bytes(bytes_tree.new()))
      "/boom", _ -> panic as "the middleware crashed"
      _, _ -> next(req)
    }
  }
}

fn start_server(
  limits: transport.SecurityLimits,
) -> #(server.Listener, Int, Subject(Observed)) {
  let observer = process.new_subject()
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [gate(observer)],
      static_config: None,
      runtime_factory: Some(fn(conn_id, _runtime, _req) {
        process.send(observer, Connected(conn_id))
        Ok(#(fn(_, _) { Nil }, fn(_) { Nil }))
      }),
      ws_auth: None,
      ssr_factory: None,
      security_limits: limits,
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "the test listener must start"
  #(listener, server.get_port(listener), observer)
}

fn listen() -> #(String, Subject(Event)) {
  let assert Ok(Nil) = telemetry.start()
  let id = "ws_middleware_refusal_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let assert Ok(Nil) =
    telemetry.attach(
      id,
      [["brazier", "ws", "upgrade", "stop"], ["brazier", "ws", "close"]],
      fn(event) { process.send(events, event) },
    )
  #(id, events)
}

fn next_event(events: Subject(Event), name: List(String)) -> Event {
  let assert Ok(event) = process.receive(events, 3000)
    as "expected telemetry event did not arrive within 3s"
  case event.name == name {
    True -> event
    False -> next_event(events, name)
  }
}

/// Mount `page` and require the 101, then the 4600 close with `status`,
/// then the end of the TCP connection.
fn expect_refused(port: Int, page: String, status: Int) -> Nil {
  let #(socket, head_status) =
    raw_ws.request(port, "/ws?path=" <> page, raw_ws.upgrade_headers(port, []))
  let assert "101" = head_status as "the handshake completes"
  let expected_reason = "middleware refused " <> int.to_string(status)
  let assert raw_ws.Close(code: 4600, reason: reason) = raw_ws.recv(socket)
    as "the socket closes with 4600"
  let assert True = reason == expected_reason as reason
  // -1: no frame follows the close before the server ends the connection.
  let assert Ok(-1) = raw_ws.expect_closed(socket, 3000)
    as "the server ends the connection after the close, sending nothing more"
  raw_ws.close(socket)
}

pub fn refused_mount_upgrades_then_closes_with_4600_test() {
  let #(listener, port, observer) =
    start_server(transport.default_security_limits())
  let #(id, events) = listen()
  let #(Nil, lines) =
    log_capture.capture(fn() { expect_refused(port, "%2Fadmin", 403) })
  let assert Ok(Gated("/admin")) = process.receive(observer, 0)
    as "the middleware ran on the page's path"

  // The connection's close is emitted inside the upgrade span, so before
  // the span's stop.
  let close = next_event(events, ["brazier", "ws", "close"])
  let upgrade = next_event(events, ["brazier", "ws", "upgrade", "stop"])
  let assert Ok("rejected_middleware") = telemetry.string(upgrade, "result")
  let assert Ok(4600) = telemetry.int(close, "close_code")
  let assert Ok("middleware_refused") = telemetry.string(close, "reason")
  let assert Ok(1) = telemetry.int(close, "frames_out")
  let assert Ok(conn_id) = telemetry.string(close, "connection_id")
    as "the close names its connection"

  // One warning with the connection, the status and the page.
  let assert [line] =
    list.filter(lines, fn(line) {
      line.level == "warning" && string.contains(line.message, conn_id)
    })
    as "exactly one warning names the refused connection"
  let assert True =
    string.contains(line.message, "with 4600: the middleware answered 403")
    && string.contains(line.message, "/admin")
    as line.message

  // No runtime was started.
  let assert Error(Nil) = process.receive(observer, 0)
  let assert Ok(Nil) = telemetry.detach(id)
  server.stop(listener)
}

pub fn refusal_carries_the_middleware_status_test() {
  let #(listener, port, observer) =
    start_server(transport.default_security_limits())
  // A redirect and a crashing middleware (500) are refusals too.
  expect_refused(port, "%2Fold", 302)
  let assert Ok(Gated("/old")) = process.receive(observer, 0)
  expect_refused(port, "%2Fboom", 500)
  let assert Ok(Gated("/boom")) = process.receive(observer, 0)
  let assert Error(Nil) = process.receive(observer, 0)
  server.stop(listener)
}

pub fn refusals_release_their_slots_test() {
  // One WebSocket per address: a refusal that kept its slot would turn
  // the admitted mount below into a 429.
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      max_ws_connections_per_ip: 1,
    )
  let #(listener, port, observer) = start_server(limits)
  expect_refused(port, "%2Fadmin", 403)
  expect_refused(port, "%2Fadmin", 403)
  let assert Ok(Gated("/admin")) = process.receive(observer, 0)
  let assert Ok(Gated("/admin")) = process.receive(observer, 0)
  let socket = raw_ws.open(port, "%2Fadmin", [#("Cookie", "role=admin")])
  let assert Ok(Gated("/admin")) = process.receive(observer, 3000)
  let assert Ok(Connected(_)) = process.receive(observer, 3000)
    as "the admitted mount starts its runtime"
  raw_ws.close(socket)
  server.stop(listener)
}

pub fn a_cross_origin_upgrade_never_reaches_the_middleware_test() {
  let #(listener, port, observer) =
    start_server(transport.default_security_limits())
  let headers = [
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    #("Sec-WebSocket-Version", "13"),
    #("Origin", "http://evil.example"),
  ]
  let #(socket, status) = raw_ws.request(port, "/ws?path=%2Fadmin", headers)
  let assert "403" = status as "the origin check answers over HTTP"
  raw_ws.close(socket)
  // A handshake the server cannot complete is a 400, not a 4600 close.
  let #(socket, status) =
    raw_ws.request(port, "/ws?path=%2Fadmin", [
      #("Upgrade", "websocket"),
      #("Connection", "Upgrade"),
      #("Sec-WebSocket-Version", "13"),
      #("Origin", "http://" <> raw_ws.authority(port)),
    ])
  let assert "400" = status as "a handshake without a key is refused"
  raw_ws.close(socket)
  // Neither request ran the middleware or started a runtime.
  let assert Error(Nil) = process.receive(observer, 0)
  server.stop(listener)
}
