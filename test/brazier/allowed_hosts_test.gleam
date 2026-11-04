//// SEC-16: the Host header must name a host in `allowed_hosts` (Django's
//// `ALLOWED_HOSTS`), on HTTP requests and on WebSocket upgrades.
////
//// DNS rebinding: a page on `evil.example` whose name the attacker then
//// points at 127.0.0.1 is same-origin with itself, so its requests carry
//// a matching `Origin: http://evil.example:PORT` and `Host:
//// evil.example:PORT`, and the origin check alone accepts them. Only the
//// host name tells them apart.

import brazier/cluster/peer.{Timeout}
import brazier/error
import brazier/log_capture
import brazier/monitored
import brazier/telemetry.{type Event}
import brazier/transport
import brazier/transport/server
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- Parsing allowed_hosts ---

fn parse(entries: List(String)) -> transport.AllowedHosts {
  let assert Ok(allowed) =
    transport.parse_allowed_hosts(entries, production: False)
    as "the test's allowed_hosts must parse"
  allowed
}

pub fn production_refuses_an_empty_allowed_hosts_test() {
  let assert Error(reason) = transport.parse_allowed_hosts([], production: True)
  assert string.contains(reason, "allowed_hosts")
  assert string.contains(reason, "production")
  // Set, it is accepted in production too.
  let assert Ok(_) =
    transport.parse_allowed_hosts(["example.com"], production: True)
}

pub fn development_default_is_the_local_names_test() {
  let allowed = parse([])
  list.each(
    [
      "localhost", "localhost:8080", "LOCALHOST:8080", "app.localhost:3000",
      "127.0.0.1:4000", "[::1]:4000", "localhost.",
    ],
    fn(host) {
      let assert Ok(Nil) = transport.host_allowed(host, allowed)
        as { "allowed: " <> host }
    },
  )
  list.each(
    [
      "evil.example", "evil.example:4000", "localhost.evil.example",
      "evillocalhost", "127.0.0.2", "[::2]", "", "a b",
    ],
    fn(host) {
      let assert Error(_) = transport.host_allowed(host, allowed)
        as { "refused: " <> host }
    },
  )
}

pub fn exact_domain_and_wildcard_entries_test() {
  let allowed = parse(["Example.COM", ".shop.example"])
  let assert Ok(Nil) = transport.host_allowed("example.com", allowed)
  let assert Ok(Nil) = transport.host_allowed("EXAMPLE.com:443", allowed)
  let assert Error(_) = transport.host_allowed("www.example.com", allowed)
  let assert Ok(Nil) = transport.host_allowed("shop.example", allowed)
  let assert Ok(Nil) = transport.host_allowed("eu.shop.example", allowed)
  let assert Error(_) = transport.host_allowed("myshop.example", allowed)
  // Setting a host list replaces the development default.
  let assert Error(_) = transport.host_allowed("localhost", allowed)

  let any = parse(["*"])
  let assert Ok(Nil) = transport.host_allowed("evil.example", any)
}

pub fn malformed_entries_are_refused_test() {
  list.each(
    [
      "", "example.com:80", "http://example.com", "example.com/",
      "*.example.com", "example.com.", "ex ample.com", "user@example.com", ".",
      "[::1]:80",
    ],
    fn(entry) {
      let assert Error(reason) =
        transport.parse_allowed_hosts([entry], production: False)
        as { "refused entry: " <> entry }
      assert string.contains(reason, "allowed_hosts entry")
      assert string.contains(reason, string.inspect(entry))
    },
  )
  // validate_security_limits refuses them too, before a listener starts.
  let assert Error(reason) =
    transport.validate_security_limits(
      transport.SecurityLimits(
        ..transport.default_security_limits(),
        allowed_hosts: ["example.com:80"],
      ),
    )
  assert string.contains(reason, "allowed_hosts")
}

pub fn a_refused_host_is_logged_quoted_test() {
  let allowed = parse([])
  let #(_, logs) =
    log_capture.capture(fn() {
      transport.host_allowed("evil.example\nINFO forged", allowed)
    })
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "Host rejected", "\"evil.example\\nINFO forged\"",
    ])
  let assert False =
    list.any(logs, fn(event) { string.contains(event.message, "\n") })
}

// --- The listener ---

type RawSocket

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

@external(erlang, "brazier_cluster_test_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

fn config(
  limits: transport.SecurityLimits,
  connected: Subject(String),
) -> transport.TransportConfig {
  transport.TransportConfig(
    port: 0,
    on_connect: fn(_, _) { Nil },
    on_event: fn(_, _) { Nil },
    on_disconnect: fn(_) { Nil },
    page_html: None,
    middlewares: [],
    static_config: None,
    runtime_factory: Some(fn(conn_id, _runtime, _req) {
      process.send(connected, conn_id)
      Ok(#(fn(_, _) { Nil }, fn(_) { Nil }))
    }),
    ws_auth: None,
    ssr_factory: None,
    security_limits: limits,
    api_handler: None,
  )
}

/// A listener on 127.0.0.1 with the development default `allowed_hosts`.
fn start_server() -> #(server.Listener, Int, Subject(String)) {
  let connected = process.new_subject()
  let assert Ok(listener) =
    transport.start_listener(config(
      transport.default_security_limits(),
      connected,
    ))
    as "the test listener must start"
  #(listener, server.get_port(listener), connected)
}

/// Send one request head to 127.0.0.1 naming `host_name` and return the
/// response's status code.
fn status_for(
  port: Int,
  target: String,
  host_name: String,
  headers: List(#(String, String)),
) -> String {
  let assert Ok(socket) = raw_connect("127.0.0.1", port)
  let host = host_name <> ":" <> int.to_string(port)
  let assert Ok(Nil) =
    raw_send(socket, raw_upgrade_request(target, host, headers))
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
    as "the server must answer the request"
  raw_close(socket)
  let assert Ok(head) = bit_array.to_string(head)
  string.slice(head, 9, 3)
}

/// A WebSocket upgrade whose Origin names the same host as its Host
/// header, as a rebound page's would.
fn upgrade_headers(host_name: String, port: Int) -> List(#(String, String)) {
  [
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    #("Sec-WebSocket-Version", "13"),
    #("Origin", "http://" <> host_name <> ":" <> int.to_string(port)),
  ]
}

/// Run `run` with the `[brazier, ws, upgrade, stop]` events sent to a subject it receives. The handler is
/// detached however `run` ends: telemetry handlers are node-wide, and one
/// left by a failing test would send every later event to eunit's shared
/// test process.
fn listen(run: fn(Subject(Event)) -> a) -> a {
  monitored.listening([["brazier", "ws", "upgrade", "stop"]], run)
}

pub fn rebound_http_request_is_refused_test() {
  let #(listener, port, _connected) = start_server()
  let assert "400" = status_for(port, "/", "evil.example", [])
  let assert "400" = status_for(port, "/", "localhost.evil.example", [])
  // The server's own names are served.
  let assert "200" = status_for(port, "/", "localhost", [])
  let assert "200" = status_for(port, "/", "127.0.0.1", [])
  server.stop(listener)
}

pub fn rebound_websocket_upgrade_is_refused_test() {
  let #(listener, port, connected) = start_server()
  use events <- listen()
  // Origin and Host agree, so only the host check refuses it.
  let status =
    status_for(
      port,
      "/ws?path=%2F",
      "evil.example",
      upgrade_headers("evil.example", port),
    )
  let assert "400" = status
  let assert Ok(stop) = process.receive(events, 3000)
    as "the upgrade span must end"
  let assert Ok("rejected_host") = telemetry.string(stop, "result")
  let assert Error(Nil) = process.receive(connected, 0)
    as "no runtime may start for a rebound upgrade"

  // The same upgrade under the server's own name is accepted.
  let assert "101" =
    status_for(
      port,
      "/ws?path=%2F",
      "localhost",
      upgrade_headers("localhost", port),
    )
  let assert Ok(_conn_id) = process.receive(connected, 3000)
    as "the runtime factory must be called"
  server.stop(listener)
}

pub fn listed_hosts_replace_the_development_default_test() {
  let connected = process.new_subject()
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      allowed_hosts: [".example.com"],
    )
  let assert Ok(listener) = transport.start_listener(config(limits, connected))
    as "the test listener must start"
  let port = server.get_port(listener)
  let assert "200" = status_for(port, "/", "app.example.com", [])
  let assert "400" = status_for(port, "/", "localhost", [])
  server.stop(listener)
}

/// The production rule runs where the listener starts: with
/// `BRAZIER_ENV=production` and no `allowed_hosts` it refuses to start,
/// naming the setting. It runs on a peer node, so the variable never leaks
/// into the other tests.
pub fn production_listener_without_allowed_hosts_refuses_to_start_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_allowed_hosts")
  let assert [node] = peers
  let outcome =
    peer.on(node, fn() {
      putenv("BRAZIER_ENV", "production")
      let unset =
        transport.start_listener(config(
          transport.default_security_limits(),
          process.new_subject(),
        ))
      let set =
        transport.start_listener(config(
          transport.SecurityLimits(
            ..transport.default_security_limits(),
            allowed_hosts: ["example.com"],
          ),
          process.new_subject(),
        ))
      let set = case set {
        Ok(listener) -> {
          server.stop(listener)
          Ok(Nil)
        }
        Error(err) -> Error(err)
      }
      #(unset, set)
    })
  let assert #(Error(error.ConfigError(reason)), Ok(Nil)) = outcome
  assert string.contains(reason, "allowed_hosts")
  assert string.contains(reason, "BRAZIER_ENV=production")
}
