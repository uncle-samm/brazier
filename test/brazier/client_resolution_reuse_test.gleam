//// One client resolution per WebSocket connection (L608).
////
//// A WebSocket upgrade resolves its client once, for the per-IP cap and the
//// Origin check, and keeps the result on the request
//// (`server.Connection.resolved`). The route middleware runs on that
//// request at the upgrade and again on every navigation, so
//// `middleware.rate_limit_behind_proxies` used to parse the forwarding
//// header again each time, and log a malformed hop in it each time.
//// `client.ip` now reuses the resolution made against the same trusted
//// proxies, and resolves afresh against any other.
////
//// The connection tests run over a real listener and a raw TCP client from
//// 127.0.0.1, which the listener trusts as a proxy. Ordering, not timing:
//// each step waits for the runtime to receive the message it sent, which
//// happens after that message's gate ran and logged.

import brazier/cluster/log_capture as node_log
import brazier/ip
import brazier/log_capture
import brazier/middleware
import brazier/rate_limit
import brazier/transport
import brazier/transport/client
import brazier/transport/server
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- client.ip ---------------------------------------------------------------

pub fn client_ip_reuses_a_resolution_against_the_same_proxies_test() {
  let trusted = trusted(["127.0.0.1"])
  // A dead socket: resolving again would fail to read the peer address, so
  // an answer proves the resolution was reused.
  let req =
    resolved_request(
      dead_socket(),
      ip.Resolved(
        trusted: trusted,
        client: ip.Client(address: "198.51.100.7", scheme: Ok("https")),
      ),
    )
  let #(address, logs) = log_capture.capture(fn() { client.ip(req, trusted) })
  assert address == Ok("198.51.100.7")
  assert log_capture.has(logs, level: "debug", containing: [
    "Reusing the resolved client 198.51.100.7",
  ])
  assert !log_capture.has(logs, level: "warning", containing: [
    "Cannot read peer address",
  ])
}

pub fn client_ip_resolves_again_against_other_proxies_test() {
  let req =
    resolved_request(
      loopback_socket(),
      ip.Resolved(
        trusted: trusted(["127.0.0.1"]),
        client: ip.Client(address: "198.51.100.7", scheme: Ok("http")),
      ),
    )
  // Against proxies that do not include the peer, the peer is the client.
  assert client.ip(req, trusted(["10.0.0.0/8"])) == Ok("127.0.0.1")
  assert client.ip(req, ip.no_trusted_proxies()) == Ok("127.0.0.1")
}

pub fn client_ip_resolves_a_request_nothing_resolved_test() {
  let req =
    request.new()
    |> request.set_body(server.Connection(
      socket: loopback_socket(),
      resolved: None,
    ))
  assert client.ip(req, trusted(["127.0.0.1"])) == Ok("127.0.0.1")
}

// --- A WebSocket connection --------------------------------------------------

pub fn one_malformed_hop_is_logged_once_per_connection_test() {
  let hop = unique("bogus-hop")
  let assert Ok(limiter) =
    rate_limit.new(
      "client_reuse_" <> unique(""),
      rate_limit.RateLimitConfig(max_requests: 100, window_seconds: 60),
    )
  let #(listener, port, observer) = start_server(limiter)
  let #(Nil, logs) =
    node_log.capture(fn() {
      // The upgrade runs the gate on "/" (one check).
      let socket = open(port, observer, ["Forwarded: for=" <> hop])
      // A join for the page the upgrade passed is not gated again (no
      // check); each navigation is (one check each).
      send_text(socket, "{\"type\":\"join\",\"token\":\"\",\"path\":\"/\"}")
      let assert Ok(GotEvent(transport.ClientJoin(path: "/", ..))) =
        process.receive(observer, 3000)
        as "the join must reach the runtime"
      list.each(["/first", "/second"], fn(path) {
        send_text(socket, "{\"type\":\"navigate\",\"path\":\"" <> path <> "\"}")
        let assert Ok(GotEvent(transport.ClientNavigate(path: got, ..))) =
          process.receive(observer, 3000)
          as "the navigation must reach the runtime"
        assert got == path
      })
      raw_close(socket)
    })
  assert list.count(logs, fn(line) {
      line.level == "warning"
      && string.contains(line.message, "Malformed forwarding hop")
      && string.contains(line.message, hop)
    })
    == 1
  // The walk stops at the malformed hop: the proxy that appended it, the
  // peer, is the client, and the limiter counted it three times. This
  // check is the fourth.
  assert rate_limit.check(limiter, "127.0.0.1")
    == rate_limit.Allowed(remaining: 100 - 4)
  server.stop(listener)
}

// --- Harness -----------------------------------------------------------------

type RawSocket

type Observed {
  Connected
  GotEvent(msg: transport.ClientMessage)
}

const host = "127.0.0.1"

fn limits() -> transport.SecurityLimits {
  transport.SecurityLimits(
    ..transport.default_security_limits(),
    trusted_proxies: ["127.0.0.1"],
    forwarding_header: ip.Forwarded,
  )
}

fn start_server(
  limiter: rate_limit.RateLimiter,
) -> #(server.Listener, Int, Subject(Observed)) {
  let observer = process.new_subject()
  // The middleware's proxies are parsed from the listener's own limits, as
  // an application would: equal to the ones the upgrade resolved against.
  let assert Ok(trusted) = transport.trusted_proxies(limits())
    as "the test limits are valid"
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [middleware.rate_limit_behind_proxies(limiter, trusted)],
      static_config: None,
      runtime_factory: Some(fn(_conn_id, _runtime, _req) {
        process.send(observer, Connected)
        Ok(
          #(fn(_cid, msg) { process.send(observer, GotEvent(msg)) }, fn(_) {
            Nil
          }),
        )
      }),
      ws_auth: None,
      ssr_factory: None,
      security_limits: limits(),
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "the test listener must start"
  #(listener, server.get_port(listener), observer)
}

/// Upgrade on `/` with the extra header lines and wait for the runtime.
fn open(
  port: Int,
  observer: Subject(Observed),
  extra: List(String),
) -> RawSocket {
  let authority = host <> ":" <> int.to_string(port)
  let headers = [
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    #("Sec-WebSocket-Version", "13"),
    #("Origin", "http://" <> authority),
    ..list.map(extra, fn(line) {
      let assert Ok(#(name, value)) = string.split_once(line, ": ")
        as "extra header lines are `Name: value`"
      #(name, value)
    })
  ]
  let assert Ok(socket) = raw_connect(host, port)
    as "test client must connect to the listener"
  let assert Ok(Nil) =
    raw_send(socket, raw_upgrade_request("/ws?path=%2F", authority, headers))
    as "test client send must succeed"
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
    as "the server must answer the upgrade"
  let assert Ok(head) = bit_array.to_string(head) as "the response head is text"
  assert string.slice(head, 9, 3) == "101"
  let assert Ok(Connected) = process.receive(observer, 3000)
    as "the runtime factory must be called"
  socket
}

fn send_text(socket: RawSocket, text: String) -> Nil {
  let assert Ok(Nil) = raw_send(socket, masked_frame(1, 1, <<text:utf8>>))
    as "test client send must succeed"
  Nil
}

fn trusted(entries: List(String)) -> ip.TrustedProxies {
  let assert Ok(trusted) = ip.parse_trusted_proxies(entries, ip.Forwarded)
    as "the test's proxy list is valid"
  trusted
}

fn resolved_request(
  socket: server.Socket,
  resolved: ip.Resolved,
) -> request.Request(server.Connection) {
  request.new()
  |> request.set_body(server.Connection(
    socket: socket,
    resolved: Some(resolved),
  ))
}

fn unique(label: String) -> String {
  label <> "-" <> int.to_string(unique_integer())
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "brazier_client_ip_test_ffi", "loopback_socket")
fn loopback_socket() -> server.Socket

@external(erlang, "brazier_client_ip_test_ffi", "dead_socket")
fn dead_socket() -> server.Socket

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
