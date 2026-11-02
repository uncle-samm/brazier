/// WebSocket protocol, liveness, backpressure, abuse and session-revocation
/// tests against a real listener, driven by a raw TCP client
/// (`beacon_ws_test_ffi`). Unhappy paths first.
///
/// Every test starts its own transport on a fresh port with a recording
/// runtime factory, so the handler pid, the runtime subject, every decoded
/// event and the `on_close` callback are observable.
import beacon/auth
import beacon/error
import beacon/session
import beacon/sim/test_app
import beacon/transport
import beacon/transport/server.{type Connection}
import beacon/transport/ws
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// --- Harness ---

type RawSocket

type Observed {
  Connected(
    conn_id: String,
    runtime: Subject(transport.InternalMessage),
    handler: Pid,
  )
  GotEvent(conn_id: String, msg: transport.ClientMessage)
  ClosedConn(conn_id: String)
}

type Server {
  Server(port: Int, observer: Subject(Observed))
}

type Probe {
  Probe(
    socket: RawSocket,
    conn_id: String,
    runtime: Subject(transport.InternalMessage),
    handler: Pid,
  )
}

@external(erlang, "beacon_ws_test_ffi", "raw_connect")
fn raw_connect(host: String, port: Int) -> Result(RawSocket, String)

@external(erlang, "beacon_ws_test_ffi", "recv_buffer_small_connect")
fn recv_buffer_small_connect(
  host: String,
  port: Int,
) -> Result(RawSocket, String)

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

@external(erlang, "beacon_ws_test_ffi", "raw_frame")
fn raw_frame(
  fin: Int,
  rsv: Int,
  opcode: Int,
  masked: Bool,
  payload: BitArray,
) -> BitArray

@external(erlang, "beacon_ws_test_ffi", "masked_frame")
fn masked_frame(fin: Int, opcode: Int, payload: BitArray) -> BitArray

@external(erlang, "beacon_ws_test_ffi", "unmasked_frame")
fn unmasked_frame(fin: Int, opcode: Int, payload: BitArray) -> BitArray

@external(erlang, "beacon_ws_test_ffi", "expect_closed")
fn expect_closed(socket: RawSocket, timeout: Int) -> Result(Int, String)

@external(erlang, "beacon_ws_test_ffi", "process_count")
fn process_count() -> Int

@external(erlang, "beacon_ws_test_ffi", "all_processes")
fn all_processes() -> List(Pid)

@external(erlang, "beacon_ws_test_ffi", "run_parallel")
fn run_parallel(n: Int, work: fn(Int) -> a) -> List(a)

@external(erlang, "beacon_ws_test_ffi", "monotonic_us")
fn monotonic_us() -> Int

const host = "127.0.0.1"

const client_key = "dGhlIHNhbXBsZSBub25jZQ=="

fn test_limits() -> transport.SecurityLimits {
  transport.SecurityLimits(
    ..transport.default_security_limits(),
    max_ws_connections_per_ip: 10_000,
  )
}

/// Start a transport with a recording runtime factory on an OS-assigned
/// port (port 0), so concurrent test runs never collide.
fn start_server(
  limits: transport.SecurityLimits,
  ws_auth: Option(fn(Request(Connection)) -> Result(Nil, String)),
) -> Server {
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
      runtime_factory: Some(fn(conn_id, runtime, _req) {
        process.send(observer, Connected(conn_id, runtime, process.self()))
        Ok(
          #(
            fn(cid, msg) { process.send(observer, GotEvent(cid, msg)) },
            fn(cid) { process.send(observer, ClosedConn(cid)) },
          ),
        )
      }),
      ws_auth: ws_auth,
      ssr_factory: None,
      security_limits: limits,
      api_handler: None,
    )
  case transport.start_listener(config) {
    Ok(listener) -> Server(port: server.get_port(listener), observer: observer)
    Error(err) ->
      panic as { "could not start transport: " <> string.inspect(err) }
  }
}

fn host_header(port: Int) -> String {
  host <> ":" <> int.to_string(port)
}

fn same_origin(port: Int) -> String {
  "http://" <> host_header(port)
}

fn upgrade_headers(port: Int) -> List(#(String, String)) {
  [
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", client_key),
    #("Sec-WebSocket-Version", "13"),
    #("Origin", same_origin(port)),
  ]
}

/// Replace (or add) a header in an upgrade header list.
fn with_header(
  headers: List(#(String, String)),
  name: String,
  value: String,
) -> List(#(String, String)) {
  list.append(list.filter(headers, fn(h) { h.0 != name }), [#(name, value)])
}

fn without_header(
  headers: List(#(String, String)),
  name: String,
) -> List(#(String, String)) {
  list.filter(headers, fn(h) { h.0 != name })
}

/// Send an upgrade request and return the socket and the response head.
fn raw_upgrade(
  port: Int,
  headers: List(#(String, String)),
) -> #(RawSocket, String) {
  let assert Ok(socket) = raw_connect(host, port)
  let assert Ok(Nil) =
    raw_send(socket, raw_upgrade_request("/ws", host_header(port), headers))
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
  let assert Ok(head) = bit_array.to_string(head)
  #(socket, head)
}

fn status_of(head: String) -> String {
  string.slice(head, 9, 3)
}

/// Upgrade with explicit headers and wait for the runtime factory.
fn open_with(server: Server, headers: List(#(String, String))) -> Probe {
  let #(socket, head) = raw_upgrade(server.port, headers)
  let assert "101" = status_of(head)
  let #(conn_id, runtime, handler) = await_connected(server.observer)
  Probe(socket: socket, conn_id: conn_id, runtime: runtime, handler: handler)
}

fn open(server: Server) -> Probe {
  open_with(server, upgrade_headers(server.port))
}

fn await_connected(
  observer: Subject(Observed),
) -> #(String, Subject(transport.InternalMessage), Pid) {
  case process.receive(observer, 3000) {
    Ok(Connected(conn_id, runtime, handler)) -> #(conn_id, runtime, handler)
    Ok(_other) -> await_connected(observer)
    Error(Nil) -> panic as "runtime factory was not called"
  }
}

/// Wait for `on_close` of a specific connection.
fn await_closed(observer: Subject(Observed), conn_id: String) -> Bool {
  case process.receive(observer, 5000) {
    Ok(ClosedConn(cid)) if cid == conn_id -> True
    Ok(_other) -> await_closed(observer, conn_id)
    Error(Nil) -> False
  }
}

/// Collect the events received within `ms`.
fn drain_events(
  observer: Subject(Observed),
  ms: Int,
  acc: List(transport.ClientMessage),
) -> List(transport.ClientMessage) {
  case process.receive(observer, ms) {
    Ok(GotEvent(_, msg)) -> drain_events(observer, ms, [msg, ..acc])
    Ok(_other) -> drain_events(observer, ms, acc)
    Error(Nil) -> list.reverse(acc)
  }
}

fn send_text(socket: RawSocket, text: String) -> Nil {
  let assert Ok(Nil) = raw_send(socket, masked_frame(1, 1, <<text:utf8>>))
  Nil
}

/// Read frames until a text frame arrives (answering nothing).
fn recv_text(socket: RawSocket) -> String {
  case raw_recv_frame(socket, 3000) {
    Ok(#(1, payload)) -> {
      let assert Ok(text) = bit_array.to_string(payload)
      text
    }
    Ok(#(9, _ping)) -> recv_text(socket)
    Ok(#(opcode, _)) ->
      panic as { "expected text frame, got opcode " <> int.to_string(opcode) }
    Error(reason) -> panic as { "expected text frame: " <> reason }
  }
}

fn wait_until(check: fn() -> Bool, timeout_ms: Int) -> Bool {
  case check() {
    True -> True
    False ->
      case timeout_ms <= 0 {
        True -> False
        False -> {
          process.sleep(10)
          wait_until(check, timeout_ms - 10)
        }
      }
  }
}

fn assert_closed_with(probe: Probe, server: Server, code: Int) -> Nil {
  let assert Ok(got) = expect_closed(probe.socket, 5000)
  case got == code {
    True -> Nil
    False ->
      panic as {
        "expected close code "
        <> int.to_string(code)
        <> ", got "
        <> int.to_string(got)
      }
  }
  // Teardown: handler process gone, runtime told to stop.
  let assert True = await_closed(server.observer, probe.conn_id)
  let assert True = wait_until(fn() { !process.is_alive(probe.handler) }, 2000)
  raw_close(probe.socket)
}

fn event_json(handler_id: String) -> String {
  "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\""
  <> handler_id
  <> "\",\"data\":\"{}\",\"target_path\":\"0\"}"
}

fn batch_json(n: Int) -> String {
  let events =
    list.repeat(
      "{\"name\":\"click\",\"handler_id\":\"b\",\"data\":\"{}\",\"target_path\":\"0\"}",
      n,
    )
  "{\"type\":\"event_batch\",\"events\":[" <> string.join(events, ",") <> "]}"
}

// --- Frame layer: protocol errors close with the right code ---

pub fn unmasked_client_frame_closes_1002_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) =
    raw_send(
      probe.socket,
      unmasked_frame(1, 1, <<"{\"type\":\"heartbeat\"}":utf8>>),
    )
  assert_closed_with(probe, server, 1002)
}

pub fn reserved_bits_close_1002_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  // RSV1 set without a negotiated extension.
  let assert Ok(Nil) =
    raw_send(probe.socket, raw_frame(1, 4, 1, True, <<"{}":utf8>>))
  assert_closed_with(probe, server, 1002)
}

pub fn unknown_opcode_closes_1002_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 3, <<"x":utf8>>))
  assert_closed_with(probe, server, 1002)
}

pub fn fragmented_control_frame_closes_1002_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(0, 9, <<"p":utf8>>))
  assert_closed_with(probe, server, 1002)
}

pub fn oversized_control_frame_closes_1002_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let payload = bit_array.from_string(string.repeat("p", 126))
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 9, payload))
  assert_closed_with(probe, server, 1002)
}

pub fn continuation_without_start_closes_1002_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 0, <<"x":utf8>>))
  assert_closed_with(probe, server, 1002)
}

pub fn new_data_frame_inside_fragmented_message_closes_1002_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(0, 1, <<"{":utf8>>))
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 1, <<"}":utf8>>))
  assert_closed_with(probe, server, 1002)
}

pub fn oversized_fragmented_message_closes_1009_test() {
  let limits = transport.SecurityLimits(..test_limits(), max_message_bytes: 100)
  let server = start_server(limits, None)
  let probe = open(server)
  // Each fragment is within the limit; the reassembled message is not.
  let part = bit_array.from_string(string.repeat("a", 60))
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(0, 1, part))
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 0, part))
  assert_closed_with(probe, server, 1009)
}

pub fn oversized_single_frame_closes_1009_from_header_test() {
  let limits = transport.SecurityLimits(..test_limits(), max_message_bytes: 100)
  let server = start_server(limits, None)
  let probe = open(server)
  // Only the header and a few payload bytes are sent: the limit is enforced
  // from the declared length, before the payload is buffered.
  let frame =
    masked_frame(1, 1, bit_array.from_string(string.repeat("a", 5000)))
  let assert Ok(Nil) =
    raw_send(probe.socket, bit_array.slice(frame, 0, 20) |> unwrap_slice)
  assert_closed_with(probe, server, 1009)
}

fn unwrap_slice(slice: Result(BitArray, Nil)) -> BitArray {
  let assert Ok(bytes) = slice
  bytes
}

pub fn invalid_utf8_text_closes_1007_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(1, 1, <<255, 254, 253>>))
  assert_closed_with(probe, server, 1007)
}

pub fn invalid_utf8_split_across_fragments_closes_1007_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  // "é" is C3 A9; a fragment boundary inside it is fine, a bad tail is not.
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(0, 1, <<"a":utf8, 0xC3>>))
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 0, <<0x28>>))
  assert_closed_with(probe, server, 1007)
}

pub fn binary_frame_closes_1003_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 2, <<1, 2, 3>>))
  assert_closed_with(probe, server, 1003)
}

pub fn close_with_reserved_code_closes_1002_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  // 1005 must never appear on the wire.
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 8, <<1005:16>>))
  assert_closed_with(probe, server, 1002)
}

pub fn close_with_one_byte_payload_closes_1002_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 8, <<3>>))
  assert_closed_with(probe, server, 1002)
}

// --- Frame layer: happy paths ---

pub fn close_handshake_echoes_peer_code_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(1, 8, <<4000:16, "bye":utf8>>))
  assert_closed_with(probe, server, 4000)
}

pub fn empty_close_is_answered_with_empty_close_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 8, <<>>))
  // expect_closed reports an empty close frame as 1005.
  assert_closed_with(probe, server, 1005)
}

pub fn ping_is_answered_with_matching_pong_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(1, 9, <<"abc":utf8>>))
  let assert Ok(#(10, <<"abc":utf8>>)) = raw_recv_frame(probe.socket, 3000)
  raw_close(probe.socket)
}

pub fn fragmented_message_with_interleaved_ping_is_reassembled_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(0, 1, <<"{\"type\":\"hea":utf8>>))
  // A control frame may be injected between fragments.
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(1, 9, <<"mid":utf8>>))
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(0, 0, <<"rtb":utf8>>))
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(1, 0, <<"eat\"}":utf8>>))
  let assert Ok(#(10, <<"mid":utf8>>)) = raw_recv_frame(probe.socket, 3000)
  let assert "{\"type\":\"heartbeat_ack\"}" = recv_text(probe.socket)
  raw_close(probe.socket)
}

pub fn many_frames_in_one_tcp_segment_are_all_processed_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  let frames =
    bit_array.concat([
      masked_frame(1, 1, <<event_json("one"):utf8>>),
      masked_frame(1, 1, <<event_json("two"):utf8>>),
      masked_frame(1, 1, <<event_json("three"):utf8>>),
    ])
  let assert Ok(Nil) = raw_send(probe.socket, frames)
  let events = drain_events(server.observer, 300, [])
  let ids =
    list.map(events, fn(e) {
      let assert transport.ClientEvent(handler_id: id, ..) = e
      id
    })
  let assert ["one", "two", "three"] = ids
  raw_close(probe.socket)
}

// --- Handshake validation ---

pub fn unsupported_version_gets_426_with_version_header_test() {
  let server = start_server(test_limits(), None)
  let headers =
    with_header(upgrade_headers(server.port), "Sec-WebSocket-Version", "8")
  let #(socket, head) = raw_upgrade(server.port, headers)
  let assert "426" = status_of(head)
  let assert True =
    string.contains(string.lowercase(head), "sec-websocket-version: 13")
  raw_close(socket)
}

pub fn malformed_key_gets_400_test() {
  let server = start_server(test_limits(), None)
  let headers =
    with_header(upgrade_headers(server.port), "Sec-WebSocket-Key", "not-a-key")
  let #(socket, head) = raw_upgrade(server.port, headers)
  let assert "400" = status_of(head)
  raw_close(socket)
}

pub fn missing_upgrade_token_gets_400_test() {
  let server = start_server(test_limits(), None)
  let headers =
    with_header(upgrade_headers(server.port), "Connection", "keep-alive")
  let #(socket, head) = raw_upgrade(server.port, headers)
  let assert "400" = status_of(head)
  raw_close(socket)
}

pub fn missing_origin_gets_403_test() {
  let server = start_server(test_limits(), None)
  let headers = without_header(upgrade_headers(server.port), "Origin")
  let #(socket, head) = raw_upgrade(server.port, headers)
  let assert "403" = status_of(head)
  raw_close(socket)
}

pub fn cross_scheme_origin_gets_403_test() {
  let server = start_server(test_limits(), None)
  // Same host and port, but https while the request is plain http.
  let headers =
    with_header(
      upgrade_headers(server.port),
      "Origin",
      "https://" <> host_header(server.port),
    )
  let #(socket, head) = raw_upgrade(server.port, headers)
  let assert "403" = status_of(head)
  raw_close(socket)
}

pub fn cross_port_origin_gets_403_test() {
  let server = start_server(test_limits(), None)
  let headers =
    with_header(
      upgrade_headers(server.port),
      "Origin",
      "http://" <> host <> ":" <> int.to_string(server.port + 1),
    )
  let #(socket, head) = raw_upgrade(server.port, headers)
  let assert "403" = status_of(head)
  raw_close(socket)
}

/// The test client connects from 127.0.0.1; trusting that address makes it
/// act as a reverse proxy.
fn behind_proxy_limits() -> transport.SecurityLimits {
  transport.SecurityLimits(..test_limits(), trusted_proxies: ["127.0.0.1"])
}

pub fn invalid_forwarded_proto_from_trusted_proxy_gets_403_test() {
  let server = start_server(behind_proxy_limits(), None)
  let headers =
    with_header(upgrade_headers(server.port), "X-Forwarded-Proto", "gopher")
  let #(socket, head) = raw_upgrade(server.port, headers)
  let assert "403" = status_of(head)
  raw_close(socket)
}

pub fn forwarded_https_from_trusted_proxy_matches_https_origin_test() {
  let server = start_server(behind_proxy_limits(), None)
  let headers =
    upgrade_headers(server.port)
    |> with_header("X-Forwarded-Proto", "https")
    |> with_header("Origin", "https://" <> host_header(server.port))
  let probe = open_with(server, headers)
  raw_close(probe.socket)
}

/// Regression: X-Forwarded-Proto was believed from any client, so a direct
/// attacker could claim https and pass an https Origin check.
pub fn forwarded_https_from_untrusted_peer_is_ignored_test() {
  let server = start_server(test_limits(), None)
  let headers =
    upgrade_headers(server.port)
    |> with_header("X-Forwarded-Proto", "https")
    |> with_header("Origin", "https://" <> host_header(server.port))
  let #(socket, head) = raw_upgrade(server.port, headers)
  let assert "403" = status_of(head)
  raw_close(socket)
}

/// An untrusted client's X-Forwarded-Proto is not read at all, so even a
/// malformed one does not affect the (plain http) upgrade.
pub fn invalid_forwarded_proto_from_untrusted_peer_is_ignored_test() {
  let server = start_server(test_limits(), None)
  let headers =
    with_header(upgrade_headers(server.port), "X-Forwarded-Proto", "gopher")
  let probe = open_with(server, headers)
  raw_close(probe.socket)
}

/// Behind a trusted proxy the per-IP cap counts the forwarded client, not
/// the proxy, so one proxy does not share a single slot bucket.
pub fn per_ip_slot_uses_forwarded_client_behind_trusted_proxy_test() {
  let server = start_server(behind_proxy_limits(), None)
  let headers =
    with_header(upgrade_headers(server.port), "X-Forwarded-For", "203.0.113.7")
  let probe = open_with(server, headers)
  let port = int.to_string(server.port)
  let assert 1 = ws.get_ip_slot_count(port <> "|203.0.113.7")
  let assert 0 = ws.get_ip_slot_count(port <> "|" <> host)
  raw_close(probe.socket)
  let assert True =
    wait_until(fn() { ws.get_ip_slot_count(port <> "|203.0.113.7") == 0 }, 2000)
}

/// Regression: a direct client could pick its own per-IP bucket by sending
/// X-Forwarded-For. Without trusted proxies the header is ignored.
pub fn per_ip_slot_ignores_spoofed_forwarded_for_test() {
  let server = start_server(test_limits(), None)
  let headers =
    with_header(upgrade_headers(server.port), "X-Forwarded-For", "198.51.100.9")
  let probe = open_with(server, headers)
  let port = int.to_string(server.port)
  let assert 1 = ws.get_ip_slot_count(port <> "|" <> host)
  let assert 0 = ws.get_ip_slot_count(port <> "|198.51.100.9")
  raw_close(probe.socket)
}

pub fn allow_listed_origin_is_accepted_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), ws_allowed_origins: [
      "https://app.example.com",
    ])
  let server = start_server(limits, None)
  let headers =
    with_header(
      upgrade_headers(server.port),
      "Origin",
      "https://app.example.com",
    )
  let probe = open_with(server, headers)
  raw_close(probe.socket)
}

/// Invalid limits are refused when the listener starts, so a misconfigured
/// server never accepts a single upgrade.
pub fn invalid_security_limits_refuse_to_start_test() {
  let limits = transport.SecurityLimits(..test_limits(), ws_ping_interval_ms: 0)
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: None,
      ws_auth: None,
      ssr_factory: None,
      security_limits: limits,
      api_handler: None,
    )
  let assert Error(error.ConfigError(reason)) = transport.start_listener(config)
  let assert True = string.contains(reason, "ws_ping_interval_ms")
}

// --- Per-IP cap ---

pub fn per_ip_cap_rejects_with_429_and_releases_slots_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), max_ws_connections_per_ip: 2)
  let server = start_server(limits, None)
  let slot = int.to_string(server.port) <> "|" <> host
  let first = open(server)
  let second = open(server)
  let assert 2 = ws.get_ip_slot_count(slot)
  let #(third, head) = raw_upgrade(server.port, upgrade_headers(server.port))
  let assert "429" = status_of(head)
  raw_close(third)
  // A rejection must not leak a slot.
  let assert 2 = ws.get_ip_slot_count(slot)
  // Closing one connection frees its slot for a new one.
  raw_close(first.socket)
  let assert True = await_closed(server.observer, first.conn_id)
  let assert True = wait_until(fn() { ws.get_ip_slot_count(slot) == 1 }, 2000)
  let fourth = open(server)
  raw_close(second.socket)
  raw_close(fourth.socket)
  let assert True = wait_until(fn() { ws.get_ip_slot_count(slot) == 0 }, 2000)
}

// --- Liveness ---

pub fn missing_pong_closes_connection_and_tears_down_test() {
  let limits =
    transport.SecurityLimits(
      ..test_limits(),
      ws_ping_interval_ms: 100,
      ws_pong_timeout_ms: 150,
    )
  let server = start_server(limits, None)
  let probe = open(server)
  // The client never answers: the server pings, then gives up.
  let assert Ok(#(9, _ping)) = raw_recv_frame(probe.socket, 2000)
  assert_closed_with(probe, server, 1000)
}

pub fn answered_pings_keep_connection_alive_test() {
  let limits =
    transport.SecurityLimits(
      ..test_limits(),
      ws_ping_interval_ms: 50,
      ws_pong_timeout_ms: 100,
    )
  let server = start_server(limits, None)
  let probe = open(server)
  answer_pings(probe.socket, 6)
  let assert True = process.is_alive(probe.handler)
  raw_close(probe.socket)
}

fn answer_pings(socket: RawSocket, remaining: Int) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let assert Ok(#(9, payload)) = raw_recv_frame(socket, 2000)
      let assert Ok(Nil) = raw_send(socket, masked_frame(1, 10, payload))
      answer_pings(socket, remaining - 1)
    }
  }
}

pub fn missing_pong_tears_down_real_runtime_test() {
  let limits =
    transport.SecurityLimits(
      ..test_app.sim_security_limits(),
      ws_ping_interval_ms: 100,
      ws_pong_timeout_ms: 150,
    )
  let port = start_counter_app(limits)
  let before = all_processes()
  let #(socket, head) = raw_upgrade(port, upgrade_headers(port))
  let assert "101" = status_of(head)
  // Let the per-connection runtime (and its listener) start.
  process.sleep(100)
  let spawned =
    list.filter(all_processes(), fn(p) { !list.contains(before, p) })
  let assert True = spawned != []
  let assert Ok(1000) = expect_closed(socket, 5000)
  raw_close(socket)
  // Handler, runtime and every helper the connection started are gone. The
  // acceptor pool is started with the listener (before the snapshot) and
  // keeps accepting, so nothing spawned for this connection survives.
  let assert True =
    wait_until(fn() { list.all(spawned, fn(p) { !process.is_alive(p) }) }, 3000)
}

fn start_counter_app(limits: transport.SecurityLimits) -> Int {
  case test_app.start_counter_app_with_limits(limits) {
    Ok(app) -> app.port
    Error(err) -> panic as { "could not start app: " <> string.inspect(err) }
  }
}

pub fn idle_connection_is_closed_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), ws_idle_timeout_ms: 200)
  let server = start_server(limits, None)
  let probe = open(server)
  assert_closed_with(probe, server, 1000)
}

pub fn heartbeats_count_as_activity_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), ws_idle_timeout_ms: 800)
  let server = start_server(limits, None)
  let probe = open(server)
  // 4 heartbeats 550ms apart (under the 2/s heartbeat rate limit) span
  // well past the idle timeout.
  list.each(list.repeat(Nil, 4), fn(_) {
    send_text(probe.socket, "{\"type\":\"heartbeat\"}")
    let assert "{\"type\":\"heartbeat_ack\"}" = recv_text(probe.socket)
    process.sleep(550)
  })
  let assert True = process.is_alive(probe.handler)
  raw_close(probe.socket)
}

// --- Backpressure ---

pub fn slow_reader_is_closed_by_send_timeout_test() {
  let limits =
    transport.SecurityLimits(
      ..test_limits(),
      ws_send_timeout_ms: 200,
      ws_max_outbound_queue: 1_000_000,
    )
  let server = start_server(limits, None)
  let assert Ok(socket) = recv_buffer_small_connect(host, server.port)
  let assert Ok(Nil) =
    raw_send(
      socket,
      raw_upgrade_request(
        "/ws",
        host_header(server.port),
        upgrade_headers(server.port),
      ),
    )
  let #(conn_id, runtime, handler) = await_connected(server.observer)
  // The client never reads. 64 MB of model syncs cannot fit in socket
  // buffers, so a send blocks and the send timeout fires.
  let big = string.repeat("x", 65_536)
  list.each(list.repeat(Nil, 1000), fn(_) {
    process.send(runtime, transport.SendModelSync(big, 1, 0))
  })
  let assert True = await_closed(server.observer, conn_id)
  let assert True = wait_until(fn() { !process.is_alive(handler) }, 2000)
  raw_close(socket)
}

pub fn outbound_queue_overflow_closes_1013_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), ws_max_outbound_queue: 5)
  let server = start_server(limits, None)
  let probe = open(server)
  // Suspend the handler so the queue builds up deterministically.
  process.send(probe.runtime, transport.SendError("first"))
  let assert Ok(_) = erlang_suspend(probe.handler)
  list.each(list.repeat(Nil, 50), fn(_) {
    process.send(probe.runtime, transport.SendError("queued"))
  })
  let assert Ok(_) = erlang_resume(probe.handler)
  assert_closed_with(probe, server, 1013)
}

@external(erlang, "beacon_ws_test_ffi", "suspend")
fn erlang_suspend(pid: Pid) -> Result(Nil, Nil)

@external(erlang, "beacon_ws_test_ffi", "resume")
fn erlang_resume(pid: Pid) -> Result(Nil, Nil)

pub fn backpressure_request_closes_1013_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  process.send(
    probe.runtime,
    transport.CloseForBackpressure("runtime overloaded"),
  )
  let assert "{\"type\":\"error\",\"reason\":" <> _ = recv_text(probe.socket)
  assert_closed_with(probe, server, 1013)
}

// --- Rate limiting and abuse ---

pub fn batch_of_100_events_counts_as_100_test() {
  // 50 events per second: a single 100-event batch must be rejected whole,
  // not counted as one message.
  let server = start_server(test_limits(), None)
  let probe = open(server)
  send_text(probe.socket, batch_json(100))
  let assert "{\"type\":\"error\",\"reason\":\"Rate limited\"}" =
    recv_text(probe.socket)
  let assert [] = drain_events(server.observer, 200, [])
  // The rejected batch consumed no budget: one event still fits.
  send_text(probe.socket, event_json("after"))
  let assert [transport.ClientEvent(handler_id: "after", ..)] =
    drain_events(server.observer, 200, [])
  raw_close(probe.socket)
}

pub fn batches_share_the_per_second_budget_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  send_text(probe.socket, batch_json(30))
  send_text(probe.socket, batch_json(30))
  // 30 + 30 > 50: the first batch is dispatched, the second is rejected.
  let assert "{\"type\":\"error\",\"reason\":\"Rate limited\"}" =
    recv_text(probe.socket)
  let assert [transport.ClientEventBatch(events)] =
    drain_events(server.observer, 200, [])
  let assert 30 = list.length(events)
  raw_close(probe.socket)
}

pub fn oversized_batch_is_rejected_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), max_events_per_second: 1000)
  let server = start_server(limits, None)
  let probe = open(server)
  send_text(probe.socket, batch_json(101))
  let assert "{\"type\":\"error\",\"reason\":\"Batch too large\"}" =
    recv_text(probe.socket)
  let assert [] = drain_events(server.observer, 200, [])
  raw_close(probe.socket)
}

pub fn decode_error_flood_closes_1008_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), ws_max_decode_errors: 3)
  let server = start_server(limits, None)
  let probe = open(server)
  list.each(list.repeat(Nil, 4), fn(_) { send_text(probe.socket, "not json") })
  assert_closed_with(probe, server, 1008)
}

pub fn decode_errors_below_threshold_keep_connection_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), ws_max_decode_errors: 3)
  let server = start_server(limits, None)
  let probe = open(server)
  list.each(list.repeat(Nil, 3), fn(_) {
    send_text(probe.socket, "{\"type\":\"nope\"}")
    let assert "{\"type\":\"error\",\"reason\":\"Invalid message\"}" =
      recv_text(probe.socket)
  })
  let assert True = process.is_alive(probe.handler)
  raw_close(probe.socket)
}

pub fn rate_violation_flood_closes_1008_test() {
  let limits =
    transport.SecurityLimits(
      ..test_limits(),
      max_events_per_second: 5,
      ws_max_rate_violations: 3,
    )
  let server = start_server(limits, None)
  let probe = open(server)
  // 5 accepted, then violations 1..4: the 4th exceeds the threshold.
  list.each(list.repeat(Nil, 9), fn(_) {
    send_text(probe.socket, event_json("e"))
  })
  let assert Ok(1008) = expect_closed(probe.socket, 5000)
  // Collect the accepted events while waiting for the close notification,
  // then any stragglers delivered after it.
  let #(before_close, closed) =
    events_until_closed(server.observer, probe.conn_id, [])
  let assert True = closed
  let after_close = drain_events(server.observer, 100, [])
  let assert 5 = list.length(before_close) + list.length(after_close)
  let assert True = wait_until(fn() { !process.is_alive(probe.handler) }, 2000)
  raw_close(probe.socket)
}

/// Collect events until the close notification for `conn_id` arrives.
fn events_until_closed(
  observer: Subject(Observed),
  conn_id: String,
  acc: List(transport.ClientMessage),
) -> #(List(transport.ClientMessage), Bool) {
  case process.receive(observer, 5000) {
    Ok(GotEvent(_, msg)) -> events_until_closed(observer, conn_id, [msg, ..acc])
    Ok(ClosedConn(cid)) if cid == conn_id -> #(list.reverse(acc), True)
    Ok(_other) -> events_until_closed(observer, conn_id, acc)
    Error(Nil) -> #(list.reverse(acc), False)
  }
}

pub fn heartbeat_flood_closes_1008_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), ws_max_rate_violations: 2)
  let server = start_server(limits, None)
  let probe = open(server)
  // 2 heartbeats per second are acked; the next 3 are violations.
  list.each(list.repeat(Nil, 5), fn(_) {
    send_text(probe.socket, "{\"type\":\"heartbeat\"}")
  })
  assert_closed_with(probe, server, 1008)
}

// --- Sessions over live sockets ---

fn session_auth_server(store: session.SessionStore) -> Server {
  start_server(
    transport.SecurityLimits(..test_limits(), ws_auth_recheck_interval_ms: 100),
    Some(auth.ws_session_auth(store, auth.dev_session_config())),
  )
}

fn cookie_headers(port: Int, session_id: String) -> List(#(String, String)) {
  with_header(upgrade_headers(port), "Cookie", "beacon_session=" <> session_id)
}

pub fn missing_session_cookie_gets_401_test() {
  let store = session.new_store("ws2_ws_no_cookie")
  let server = session_auth_server(store)
  let #(socket, head) = raw_upgrade(server.port, upgrade_headers(server.port))
  let assert "401" = status_of(head)
  raw_close(socket)
}

pub fn expired_session_gets_401_test() {
  let store =
    session.new_store_with_config(
      "ws2_ws_expired",
      session.StoreConfig(
        absolute_ttl_ms: 60_000,
        idle_ttl_ms: 40,
        sweep_interval_ms: 60_000,
      ),
    )
  let sess = auth.login(store, "user-1")
  process.sleep(80)
  let server = session_auth_server(store)
  let #(socket, head) =
    raw_upgrade(server.port, cookie_headers(server.port, sess.id))
  let assert "401" = status_of(head)
  raw_close(socket)
}

pub fn logout_closes_live_socket_4401_test() {
  let store = session.new_store("ws2_ws_logout")
  let sess = auth.login(store, "user-1")
  let server = session_auth_server(store)
  let probe = open_with(server, cookie_headers(server.port, sess.id))
  let assert True =
    wait_until(fn() { session.bound_process_count(store, sess.id) == 1 }, 1000)
  auth.logout(store, sess.id)
  assert_closed_with(probe, server, 4401)
}

pub fn old_session_id_is_unusable_after_login_rotation_test() {
  let store = session.new_store("ws2_ws_rotation")
  let anonymous = auth.login(store, "guest")
  let server = session_auth_server(store)
  let probe = open_with(server, cookie_headers(server.port, anonymous.id))
  let assert True =
    wait_until(
      fn() { session.bound_process_count(store, anonymous.id) == 1 },
      1000,
    )
  let fresh = auth.login_rotating(store, Some(anonymous.id), "user-1")
  // The socket bound to the old id is closed...
  assert_closed_with(probe, server, 4401)
  // ...the old id cannot open a new one...
  let #(socket, head) =
    raw_upgrade(server.port, cookie_headers(server.port, anonymous.id))
  let assert "401" = status_of(head)
  raw_close(socket)
  // ...and the new id can.
  let renewed = open_with(server, cookie_headers(server.port, fresh.id))
  raw_close(renewed.socket)
}

pub fn failed_auth_recheck_closes_4401_test() {
  // ws_auth that does not bind the process: only the periodic re-check can
  // notice the session is gone.
  let store = session.new_store("ws2_ws_recheck")
  let sess = auth.login(store, "user-1")
  let check = fn(req: Request(Connection)) {
    case session.id_from_request(req, auth.default_session_cookie_name) {
      Ok(id) ->
        case session.get(store, id) {
          Some(_) -> Ok(Nil)
          None -> Error("session gone")
        }
      Error(Nil) -> Error("no cookie")
    }
  }
  let server =
    start_server(
      transport.SecurityLimits(
        ..test_limits(),
        ws_auth_recheck_interval_ms: 100,
      ),
      Some(check),
    )
  let probe = open_with(server, cookie_headers(server.port, sess.id))
  // Still valid across a re-check.
  process.sleep(150)
  let assert True = process.is_alive(probe.handler)
  session.delete(store, sess.id)
  assert_closed_with(probe, server, 4401)
}

// --- Pure helpers ---

pub fn origin_allowed_compares_scheme_host_and_port_test() {
  let assert Ok(Nil) =
    transport.origin_allowed("http://example.com", "http", "example.com", [])
  let assert Ok(Nil) =
    transport.origin_allowed(
      "https://example.com",
      "https",
      "example.com:443",
      [],
    )
  let assert Ok(Nil) =
    transport.origin_allowed("HTTP://Example.COM:80", "http", "example.com", [])
  let assert Error(_) =
    transport.origin_allowed("https://example.com", "http", "example.com", [])
  let assert Error(_) =
    transport.origin_allowed(
      "http://example.com:8080",
      "http",
      "example.com",
      [],
    )
  let assert Error(_) =
    transport.origin_allowed("http://evil.com", "http", "example.com", [])
  let assert Error(_) =
    transport.origin_allowed(
      "http://example.com.evil.com",
      "http",
      "example.com",
      [],
    )
  let assert Error(_) =
    transport.origin_allowed(
      "http://user@example.com",
      "http",
      "example.com",
      [],
    )
  let assert Error(_) =
    transport.origin_allowed("null", "http", "example.com", [])
  let assert Error(_) =
    transport.origin_allowed("ws://example.com", "http", "example.com", [])
}

pub fn origin_allowed_honours_allow_list_test() {
  let allowed = ["https://app.example.com", "http://localhost:3000"]
  let assert Ok(Nil) =
    transport.origin_allowed(
      "https://app.example.com",
      "http",
      "api.local",
      allowed,
    )
  let assert Ok(Nil) =
    transport.origin_allowed(
      "http://localhost:3000",
      "http",
      "api.local",
      allowed,
    )
  let assert Error(_) =
    transport.origin_allowed(
      "http://app.example.com",
      "http",
      "api.local",
      allowed,
    )
  let assert Error(_) =
    transport.origin_allowed(
      "http://localhost:3001",
      "http",
      "api.local",
      allowed,
    )
}

pub fn ipv6_origins_are_compared_exactly_test() {
  let assert Ok(Nil) =
    transport.origin_allowed("http://[::1]:4000", "http", "[::1]:4000", [])
  let assert Error(_) =
    transport.origin_allowed("http://[::1]:4001", "http", "[::1]:4000", [])
}

pub fn validate_security_limits_rejects_nonsense_test() {
  let base = transport.default_security_limits()
  let assert Ok(Nil) = transport.validate_security_limits(base)
  let assert Error(_) =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, max_ws_connections_per_ip: 0),
    )
  let assert Error(_) =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, ws_pong_timeout_ms: -1),
    )
  let assert Error(_) =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, ws_idle_timeout_ms: 4_294_967_296),
    )
  let assert Error(_) =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, ws_max_decode_errors: -1),
    )
  let assert Error(_) =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, ws_allowed_origins: [
        "https://a.com/path",
      ]),
    )
  let assert Error(_) =
    transport.validate_security_limits(
      transport.SecurityLimits(..base, ws_allowed_origins: ["not an origin"]),
    )
  let assert Ok(Nil) =
    transport.validate_security_limits(
      transport.SecurityLimits(
        ..base,
        ws_max_decode_errors: 0,
        ws_allowed_origins: [
          "https://a.com:8443",
        ],
      ),
    )
}

// --- Load ---

/// N sockets x M events against a real per-connection runtime. Every event
/// must be answered, and every process the connections spawned must be gone
/// afterwards. Throughput and latency are logged.
pub fn ws_load_no_process_leak_test() {
  let sockets = 50
  let events = 40
  let port = start_counter_app(test_app.sim_security_limits())
  process.sleep(100)
  let baseline = process_count()
  let started = monotonic_us()
  let latencies =
    run_parallel(sockets, fn(_i) {
      let #(socket, head) = raw_upgrade(port, upgrade_headers(port))
      let assert "101" = status_of(head)
      send_text(socket, "{\"type\":\"join\",\"token\":\"\",\"path\":\"/\"}")
      let _mount = recv_text(socket)
      let samples =
        list.map(list.repeat(Nil, events), fn(_) {
          let t0 = monotonic_us()
          send_text(socket, event_json("inc"))
          let _reply = recv_text(socket)
          monotonic_us() - t0
        })
      let assert Ok(Nil) = raw_send(socket, masked_frame(1, 8, <<1000:16>>))
      let assert Ok(1000) = expect_closed(socket, 5000)
      raw_close(socket)
      samples
    })
    |> list.flatten
  let elapsed_us = int.max(monotonic_us() - started, 1)
  let total = sockets * events
  let assert True = list.length(latencies) == total
  let sorted = list.sort(latencies, int.compare)
  let p50 = percentile(sorted, total, 50)
  let p99 = percentile(sorted, total, 99)
  let throughput = total * 1_000_000 / elapsed_us
  io_println(
    "ws_load: "
    <> int.to_string(sockets)
    <> " sockets x "
    <> int.to_string(events)
    <> " events, "
    <> int.to_string(throughput)
    <> " events/s, p50 "
    <> int.to_string(p50)
    <> "us, p99 "
    <> int.to_string(p99)
    <> "us",
  )
  // Handlers, runtimes and listeners have all exited.
  let assert True = wait_until(fn() { process_count() <= baseline }, 5000)
}

fn percentile(sorted: List(Int), total: Int, pct: Int) -> Int {
  let index = int.min(total - 1, total * pct / 100)
  let assert Ok(value) = list.first(list.drop(sorted, index))
  value
}

@external(erlang, "io", "format")
fn erlang_format(format: String, args: List(String)) -> Nil

fn io_println(line: String) -> Nil {
  erlang_format("~ts~n", [line])
}
