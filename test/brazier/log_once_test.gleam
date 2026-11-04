/// One problem, one log line.
///
/// A WebSocket upgrade needs the client address (for the per-IP cap) and
/// the scheme (for the Origin check). Both come from the forwarding header,
/// which used to be parsed once per question, so a malformed hop in it was
/// logged twice per upgrade. `start_listener` logged its "Invalid security
/// limits" and "Invalid static config" refusals once in the check and again
/// in `prepare_listener`. Each test counts the lines carrying a value unique
/// to it, so a line from another test cannot be counted.
import brazier/cluster/log_capture as node_log
import brazier/error
import brazier/ip
import brazier/log_capture
import brazier/static
import brazier/transport
import brazier/transport/server.{type Socket}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- ip.client ---------------------------------------------------------------

pub fn client_logs_a_malformed_forwarded_hop_once_test() {
  let hop = unique("bogus-hop")
  let trusted = trusted(["10.0.0.1"], ip.Forwarded)
  let #(client, logs) =
    log_capture.capture(fn() {
      ip.client(
        "10.0.0.1",
        [#("forwarded", "for=" <> hop <> ";proto=https")],
        trusted,
      )
    })
  // The walk stops at the malformed hop: the proxy that appended it is the
  // client, and its element's proto= is the scheme.
  assert client == ip.Client(address: "10.0.0.1", scheme: Ok("https"))
  assert count(logs, "warning", ["Malformed forwarding hop", hop]) == 1
}

pub fn client_logs_a_malformed_x_forwarded_for_hop_once_test() {
  let hop = unique("bogus-hop")
  let trusted = trusted(["10.0.0.1"], ip.XForwardedFor)
  let #(client, logs) =
    log_capture.capture(fn() {
      ip.client(
        "10.0.0.1",
        [#("x-forwarded-for", hop), #("x-forwarded-proto", "https")],
        trusted,
      )
    })
  assert client == ip.Client(address: "10.0.0.1", scheme: Ok("https"))
  assert count(logs, "warning", ["Malformed forwarding hop", hop]) == 1
}

pub fn client_resolves_the_address_and_scheme_of_one_element_test() {
  let trusted = trusted(["10.0.0.1"], ip.Forwarded)
  let client =
    ip.client(
      "10.0.0.1",
      [#("forwarded", "for=198.51.100.7;proto=https, for=10.0.0.9;proto=http")],
      trusted,
    )
  // 10.0.0.9 is not trusted: it is the client, and its proto= wins.
  assert client == ip.Client(address: "10.0.0.9", scheme: Ok("http"))
}

pub fn client_warns_once_about_each_unconfigured_header_test() {
  let spoofed = unique("203.0.113.1, spoof")
  let trusted = trusted(["10.0.0.1"], ip.Forwarded)
  let #(client, logs) =
    log_capture.capture(fn() {
      ip.client(
        "10.0.0.1",
        [
          #("forwarded", "for=198.51.100.7"),
          #("x-forwarded-for", spoofed),
          #("x-forwarded-proto", "https"),
        ],
        trusted,
      )
    })
  // Neither X- header is read: the Forwarded element has no proto=.
  assert client == ip.Client(address: "198.51.100.7", scheme: Ok("http"))
  assert count(logs, "warning", ["Ignoring X-Forwarded-For", spoofed]) == 1
  assert count(logs, "warning", ["Ignoring X-Forwarded-Proto", "10.0.0.1"]) == 1
}

pub fn client_reports_an_unusable_scheme_test() {
  let trusted = trusted(["10.0.0.1"], ip.XForwardedFor)
  let #(client, logs) =
    log_capture.capture(fn() {
      ip.client(
        "10.0.0.1",
        [#("x-forwarded-for", "198.51.100.7"), #("x-forwarded-proto", "gopher")],
        trusted,
      )
    })
  assert client.address == "198.51.100.7"
  let assert Error(reason) = client.scheme
    as "an X-Forwarded-Proto other than http or https is refused"
  assert string.contains(reason, "\"gopher\"")
  assert count(logs, "warning", ["invalid X-Forwarded-Proto", "gopher"]) == 1
}

pub fn client_ignores_forwarding_headers_from_an_untrusted_peer_test() {
  let hop = unique("bogus-hop")
  let trusted = trusted(["10.0.0.1"], ip.Forwarded)
  let #(client, logs) =
    log_capture.capture(fn() {
      ip.client(
        "198.51.100.7",
        [#("forwarded", "for=" <> hop <> ";proto=https")],
        trusted,
      )
    })
  assert client == ip.Client(address: "198.51.100.7", scheme: Ok("http"))
  assert count(logs, "warning", [hop]) == 0
}

// --- The WebSocket upgrade ---------------------------------------------------

pub fn ws_upgrade_logs_a_malformed_forwarded_hop_once_test() {
  let hop = unique("bogus-hop")
  let listener = start(proxied_limits(ip.Forwarded))
  let #(status, logs) =
    node_log.capture(fn() {
      upgrade(listener, [
        "Forwarded: for=" <> hop <> ";proto=http",
        // A cross-site Origin: the upgrade is refused after both the per-IP
        // cap (the address) and the Origin check (the scheme) ran.
        "Origin: http://evil.example",
      ])
    })
  assert status == 403
  assert node_count(logs, "warning", ["Malformed forwarding hop", hop]) == 1
  server.stop(listener)
}

pub fn ws_upgrade_logs_each_unconfigured_header_once_test() {
  let spoofed = unique("203.0.113.1, spoof")
  let listener = start(proxied_limits(ip.Forwarded))
  let #(status, logs) =
    node_log.capture(fn() {
      upgrade(listener, [
        "Forwarded: for=198.51.100.7;proto=http",
        "X-Forwarded-For: " <> spoofed,
        "Origin: http://evil.example",
      ])
    })
  assert status == 403
  assert node_count(logs, "warning", ["Ignoring X-Forwarded-For", spoofed]) == 1
  server.stop(listener)
}

pub fn ws_upgrade_with_an_unusable_scheme_is_refused_and_logged_once_test() {
  let listener = start(proxied_limits(ip.XForwardedFor))
  let #(status, logs) =
    node_log.capture(fn() {
      upgrade(listener, [
        "X-Forwarded-For: 198.51.100.7",
        "X-Forwarded-Proto: gopher",
        "Origin: http://test",
      ])
    })
  assert status == 403
  assert node_count(logs, "warning", ["Origin check failed", "\"gopher\""]) == 1
  assert node_count(logs, "warning", ["Trusted proxy sent an invalid", "gopher"])
    == 1
  server.stop(listener)
}

// --- start_listener ----------------------------------------------------------

pub fn invalid_security_limits_are_logged_once_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      max_connections: 0,
    )
  let #(result, logs) =
    log_capture.capture(fn() { transport.start_listener(config(limits, None)) })
  let assert Error(error.ConfigError(reason:)) = result
    as "a listener with max_connections 0 must not start"
  assert reason == "Invalid security limits: max_connections must be > 0"
  assert count(logs, "error", ["Invalid security limits"]) == 1
}

pub fn invalid_static_config_is_logged_once_test() {
  let static_config =
    static.StaticConfig(directory: "priv/static", prefix: "/", max_age: 60)
  let #(result, logs) =
    log_capture.capture(fn() {
      transport.start_listener(config(
        transport.default_security_limits(),
        Some(static_config),
      ))
    })
  let assert Error(error.ConfigError(reason:)) = result
    as "a listener whose static prefix is / must not start"
  assert string.starts_with(reason, "Invalid static config: ")
  assert count(logs, "error", ["Invalid static config"]) == 1
}

pub fn invalid_limits_stop_before_the_static_check_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      max_connections: 0,
    )
  let static_config =
    static.StaticConfig(directory: "priv/static", prefix: "/", max_age: 60)
  let #(result, logs) =
    log_capture.capture(fn() {
      transport.start_listener(config(limits, Some(static_config)))
    })
  let assert Error(error.ConfigError(reason:)) = result
    as "a listener with invalid limits must not start"
  assert string.starts_with(reason, "Invalid security limits: ")
  // The first refusal is the one reported, and the only error logged.
  assert count(logs, "error", []) == 1
}

// --- Helpers -----------------------------------------------------------------

fn trusted(
  entries: List(String),
  header: ip.ForwardingHeader,
) -> ip.TrustedProxies {
  let assert Ok(trusted) = ip.parse_trusted_proxies(entries, header)
    as "the test's proxy list is valid"
  trusted
}

/// The raw test client connects from 127.0.0.1, which these limits trust.
fn proxied_limits(header: ip.ForwardingHeader) -> transport.SecurityLimits {
  transport.SecurityLimits(
    ..transport.default_security_limits(),
    request_timeout_ms: 2000,
    keepalive_idle_timeout_ms: 2000,
    // The raw requests below name the host "test".
    allowed_hosts: ["test"],
    trusted_proxies: ["127.0.0.1"],
    forwarding_header: header,
  )
}

fn config(
  limits: transport.SecurityLimits,
  static_config: option.Option(static.StaticConfig),
) -> transport.TransportConfig {
  transport.TransportConfig(
    port: 0,
    on_connect: fn(_id, _subject) { Nil },
    on_event: fn(_id, _msg) { Nil },
    on_disconnect: fn(_id) { Nil },
    page_html: None,
    middlewares: [],
    static_config: static_config,
    runtime_factory: None,
    ws_auth: None,
    ssr_factory: None,
    security_limits: limits,
    api_handler: None,
  )
}

fn start(limits: transport.SecurityLimits) -> server.Listener {
  let assert Ok(listener) = transport.start_listener(config(limits, None))
    as "test listener must bind an OS-assigned port"
  listener
}

/// Send a WebSocket upgrade for `/` with the extra header lines and return
/// the status of the answer. The answer is written after every check ran,
/// and each check logs before it answers, so the lines are all in.
fn upgrade(listener: server.Listener, headers: List(String)) -> Int {
  let assert Ok(socket) = raw_connect(server.get_port(listener))
    as "test client must connect to the listener"
  let request =
    "GET /ws?path=%2F HTTP/1.1\r\nHost: test\r\n"
    <> "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    <> "Sec-WebSocket-Version: 13\r\n"
    <> "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    <> string.join(list.map(headers, fn(line) { line <> "\r\n" }), "")
    <> "\r\n"
  let assert Ok(Nil) = raw_send(socket, <<request:utf8>>)
    as "test client send must succeed"
  let assert Ok(#(status, _headers, _body)) =
    raw_recv_response(socket, 2000, True)
    as "the server must answer the upgrade"
  raw_close(socket)
  status
}

fn count(
  logs: List(log_capture.Captured),
  level: String,
  fragments: List(String),
) -> Int {
  list.count(logs, fn(line) {
    line.level == level
    && list.all(fragments, fn(fragment) {
      string.contains(line.message, fragment)
    })
  })
}

fn node_count(
  logs: List(node_log.Line),
  level: String,
  fragments: List(String),
) -> Int {
  list.count(logs, fn(line) {
    line.level == level
    && list.all(fragments, fn(fragment) {
      string.contains(line.message, fragment)
    })
  })
}

fn unique(label: String) -> String {
  label <> "-" <> int.to_string(unique_integer())
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "brazier_http_raw_ffi", "connect")
fn raw_connect(port: Int) -> Result(Socket, String)

@external(erlang, "brazier_http_raw_ffi", "send")
fn raw_send(socket: Socket, data: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_http_raw_ffi", "recv_response")
fn raw_recv_response(
  socket: Socket,
  timeout_ms: Int,
  expect_body: Bool,
) -> Result(#(Int, List(#(String, String)), String), String)

@external(erlang, "brazier_http_raw_ffi", "close")
fn raw_close(socket: Socket) -> Nil
