/// WebSocket protocol, liveness, backpressure, abuse and session-revocation
/// tests against a real listener, driven by a raw TCP client
/// (`brazier_ws_test_ffi`). Unhappy paths first.
///
/// Every test starts its own transport on a fresh port with a recording
/// runtime factory, so the handler pid, the runtime subject, every decoded
/// event and the `on_close` callback are observable.
import brazier/auth
import brazier/await
import brazier/error
import brazier/ip
import brazier/session
import brazier/sim/test_app
import brazier/transport
import brazier/transport/server.{type Connection}
import gleam/bit_array
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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
  Server(port: Int, observer: Subject(Observed), listener: server.Listener)
}

type Probe {
  Probe(
    socket: RawSocket,
    conn_id: String,
    runtime: Subject(transport.InternalMessage),
    handler: Pid,
  )
}

@external(erlang, "brazier_ws_test_ffi", "raw_connect")
fn raw_connect(host: String, port: Int) -> Result(RawSocket, String)

@external(erlang, "brazier_ws_test_ffi", "recv_buffer_small_connect")
fn recv_buffer_small_connect(
  host: String,
  port: Int,
) -> Result(RawSocket, String)

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

@external(erlang, "brazier_ws_test_ffi", "raw_frame")
fn raw_frame(
  fin: Int,
  rsv: Int,
  opcode: Int,
  masked: Bool,
  payload: BitArray,
) -> BitArray

@external(erlang, "brazier_ws_test_ffi", "masked_frame")
fn masked_frame(fin: Int, opcode: Int, payload: BitArray) -> BitArray

@external(erlang, "brazier_ws_test_ffi", "unmasked_frame")
fn unmasked_frame(fin: Int, opcode: Int, payload: BitArray) -> BitArray

@external(erlang, "brazier_ws_test_ffi", "expect_closed")
fn expect_closed(socket: RawSocket, timeout: Int) -> Result(Int, String)

@external(erlang, "brazier_ws_test_ffi", "all_processes")
fn all_processes() -> List(Pid)

@external(erlang, "brazier_ws_test_ffi", "run_parallel")
fn run_parallel(n: Int, work: fn(Int) -> a) -> List(a)

@external(erlang, "brazier_ws_test_ffi", "monotonic_us")
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
    Ok(listener) ->
      Server(
        port: server.get_port(listener),
        observer: observer,
        listener: listener,
      )
    Error(err) ->
      panic as { "could not start transport: " <> string.inspect(err) }
  }
}

/// Live WebSockets the listener counts against `ip`'s per-IP cap.
fn ws_slots(test_server: Server, ip: String) -> Int {
  server.get_ws_connection_count_for_ip(test_server.listener, ip)
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
    raw_send(
      socket,
      raw_upgrade_request("/ws?path=%2F", host_header(port), headers),
    )
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

/// Wait for `on_close` of every connection in `conn_ids`, in any order.
fn await_all_closed(
  observer: Subject(Observed),
  conn_ids: List(String),
) -> Nil {
  case conn_ids {
    [] -> Nil
    _ -> {
      let assert ClosedConn(closed) =
        await.expect(
          observer,
          "on_close for " <> string.join(conn_ids, ", "),
          matching: fn(observed) {
            case observed {
              ClosedConn(cid) -> list.contains(conn_ids, cid)
              _ -> False
            }
          },
        )
      await_all_closed(observer, list.filter(conn_ids, fn(c) { c != closed }))
    }
  }
}

/// The next event the handler dispatched. The handler sends every
/// observation from its own process, so events arrive in dispatch order:
/// the first event after a rejection proves the rejection dispatched none.
fn next_event(observer: Subject(Observed)) -> transport.ClientMessage {
  let assert GotEvent(_, msg) =
    await.expect(observer, "a dispatched event", matching: fn(observed) {
      case observed {
        GotEvent(..) -> True
        _ -> False
      }
    })
  msg
}

/// Every event already in this process's mailbox, without waiting. Use it
/// once the handler is down: a dead process has no sends in flight.
fn events_in_mailbox(
  observer: Subject(Observed),
) -> List(transport.ClientMessage) {
  list.filter_map(await.drain(observer), fn(observed) {
    case observed {
      GotEvent(_, msg) -> Ok(msg)
      _ -> Error(Nil)
    }
  })
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
  await.expect_down(probe.handler, "WebSocket handler " <> probe.conn_id)
  raw_close(probe.socket)
}

/// Close the client side and wait until the server has run `on_close` for
/// this connection, so the notice is received here and not left for the
/// next test. The handler dispatches its events and then runs `on_close`
/// from the same process, so once a test has received every event it
/// caused, the notice is the next observation.
fn close(server: Server, probe: Probe) -> Nil {
  raw_close(probe.socket)
  let assert Ok(ClosedConn(closed)) = process.receive(server.observer, 5000)
    as "on_close must run"
  let assert True = closed == probe.conn_id
  Nil
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
  close(server, probe)
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
  close(server, probe)
}

pub fn state_frames_embed_model_and_ops_raw_on_the_socket_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  // Above 65_535 bytes, so the frame uses the 64-bit length header.
  let model_json =
    "{\"rows\":["
    <> string.join(list.repeat("\"row \\\"q\\\"\"", 8000), ",")
    <> "]}"
  let assert True = string.byte_size(model_json) > 65_535
  process.send(
    probe.runtime,
    transport.SendModelSync(
      model_json:,
      version: 4,
      ack_clock: 3,
      streams_json: "[]",
    ),
  )
  let assert True =
    recv_text(probe.socket)
    == "{\"type\":\"model_sync\",\"model\":"
    <> model_json
    <> ",\"version\":4,\"ack_clock\":3,\"streams\":[]}"
  let ops_json = "[{\"op\":\"replace\",\"path\":\"/rows/0\",\"value\":\"x\"}]"
  process.send(
    probe.runtime,
    transport.SendPatch(ops_json:, version: 5, ack_clock: 3, streams_json: "[]"),
  )
  let assert True =
    recv_text(probe.socket)
    == "{\"type\":\"patch\",\"ops\":"
    <> ops_json
    <> ",\"version\":5,\"ack_clock\":3,\"streams\":[]}"
  close(server, probe)
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
  let ids =
    list.map([1, 2, 3], fn(_) {
      let assert transport.ClientEvent(handler_id: id, ..) =
        next_event(server.observer)
      id
    })
  let assert ["one", "two", "three"] = ids
  close(server, probe)
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
/// act as a reverse proxy that sets X-Forwarded-For.
fn behind_proxy_limits() -> transport.SecurityLimits {
  transport.SecurityLimits(
    ..test_limits(),
    trusted_proxies: ["127.0.0.1"],
    forwarding_header: ip.XForwardedFor,
  )
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
  close(server, probe)
}

/// Behind a proxy that sets `Forwarded`, its `proto=` is the scheme, and an
/// `X-Forwarded-Proto` the client slipped through is not.
pub fn forwarded_proto_from_trusted_proxy_decides_the_origin_scheme_test() {
  let limits =
    transport.SecurityLimits(
      ..behind_proxy_limits(),
      forwarding_header: ip.Forwarded,
    )
  let server = start_server(limits, None)
  let https_origin = "https://" <> host_header(server.port)
  let headers =
    upgrade_headers(server.port)
    |> with_header("Forwarded", "for=203.0.113.7;proto=https")
    |> with_header("Origin", https_origin)
  let probe = open_with(server, headers)
  close(server, probe)
  let spoofed =
    upgrade_headers(server.port)
    |> with_header("Forwarded", "for=203.0.113.7;proto=http")
    |> with_header("X-Forwarded-Proto", "https")
    |> with_header("Origin", https_origin)
  let #(socket, head) = raw_upgrade(server.port, spoofed)
  let assert "403" = status_of(head)
  raw_close(socket)
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
  close(server, probe)
}

/// Behind a trusted proxy the per-IP cap counts the forwarded client, not
/// the proxy, so one proxy does not share a single slot bucket.
pub fn per_ip_slot_uses_forwarded_client_behind_trusted_proxy_test() {
  let server = start_server(behind_proxy_limits(), None)
  let headers =
    with_header(upgrade_headers(server.port), "X-Forwarded-For", "203.0.113.7")
  let probe = open_with(server, headers)
  let assert 1 = ws_slots(server, "203.0.113.7")
  let assert 0 = ws_slots(server, host)
  // cleanup_connection releases the slot (a synchronous ETS update) before
  // it calls on_close, so once on_close has run the count is final.
  close(server, probe)
  let assert 0 = ws_slots(server, "203.0.113.7")
}

/// Regression: a direct client could pick its own per-IP bucket by sending
/// X-Forwarded-For. Without trusted proxies the header is ignored.
pub fn per_ip_slot_ignores_spoofed_forwarded_for_test() {
  let server = start_server(test_limits(), None)
  let headers =
    with_header(upgrade_headers(server.port), "X-Forwarded-For", "198.51.100.9")
  let probe = open_with(server, headers)
  let assert 1 = ws_slots(server, host)
  let assert 0 = ws_slots(server, "198.51.100.9")
  close(server, probe)
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
  close(server, probe)
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
  let first = open(server)
  let second = open(server)
  let assert 2 = ws_slots(server, host)
  let #(third, head) = raw_upgrade(server.port, upgrade_headers(server.port))
  let assert "429" = status_of(head)
  raw_close(third)
  // A rejection must not leak a slot.
  let assert 2 = ws_slots(server, host)
  // Closing one connection frees its slot for a new one.
  // The slot is released before on_close runs, so the count is final.
  close(server, first)
  let assert 1 = ws_slots(server, host)
  let fourth = open(server)
  let assert 2 = ws_slots(server, host)
  raw_close(second.socket)
  raw_close(fourth.socket)
  await_all_closed(server.observer, [second.conn_id, fourth.conn_id])
  let assert 0 = ws_slots(server, host)
}

/// A handler killed while it holds a slot never runs its cleanup; the
/// listener's connection owner releases the slot on the handler's exit.
pub fn killed_handler_releases_its_slot_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), max_ws_connections_per_ip: 1)
  let test_server = start_server(limits, None)
  let probe = open(test_server)
  let assert 1 = ws_slots(test_server, host)
  let assert Ok(owner) = server.get_connection_owner(test_server.listener)
  {
    use watch <- await.with_watch_exit(owner, probe.handler)
    process.kill(probe.handler)
    await.expect_info(watch, owner, "the connection owner handling the kill")
  }
  let assert 0 = ws_slots(test_server, host)
  // The freed slot admits a new connection under the cap of one.
  let next = open(test_server)
  let assert 1 = ws_slots(test_server, host)
  // The killed handler ran no cleanup, so only `next` reports on_close.
  raw_close(probe.socket)
  close(test_server, next)
}

/// Each listener counts its own WebSockets: a cap reached on one does not
/// refuse an upgrade on another in the same VM.
pub fn listeners_count_slots_apart_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), max_ws_connections_per_ip: 1)
  let first = start_server(limits, None)
  let second = start_server(limits, None)
  let a = open(first)
  let b = open(second)
  let assert 1 = ws_slots(first, host)
  let assert 1 = ws_slots(second, host)
  close(first, a)
  close(second, b)
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
  close(server, probe)
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
  // The handler arms its ping timer only after the runtime factory has
  // returned, so the first ping proves the runtime and whatever it starts
  // up front are running.
  let assert Ok(#(9, _ping)) = raw_recv_frame(socket, await.deadline_ms)
  let spawned =
    list.filter(all_processes(), fn(p) { !list.contains(before, p) })
  let assert True = spawned != []
  let assert Ok(1000) = expect_closed(socket, await.deadline_ms)
  raw_close(socket)
  // Handler, runtime and every helper the connection started are gone. The
  // acceptor pool is started with the listener (before the snapshot) and
  // keeps accepting, so nothing spawned for this connection survives.
  list.each(spawned, fn(p) {
    await.expect_down(p, "process spawned for the timed-out connection")
  })
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
  // well past the idle timeout. The sleep is the thing under test: wall
  // clock time must pass the idle timeout while only heartbeats arrive.
  list.each(list.repeat(Nil, 4), fn(_) {
    send_text(probe.socket, "{\"type\":\"heartbeat\"}")
    let assert "{\"type\":\"heartbeat_ack\"}" = recv_text(probe.socket)
    process.sleep(550)
  })
  let assert True = process.is_alive(probe.handler)
  close(server, probe)
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
        "/ws?path=%2F",
        host_header(server.port),
        upgrade_headers(server.port),
      ),
    )
  let #(conn_id, runtime, handler) = await_connected(server.observer)
  // The client never reads. 64 MB of model syncs cannot fit in socket
  // buffers, so a send blocks and the send timeout fires.
  let big = string.repeat("x", 65_536)
  list.each(list.repeat(Nil, 1000), fn(_) {
    process.send(
      runtime,
      transport.SendModelSync(big, 1, 0, streams_json: "[]"),
    )
  })
  let assert True = await_closed(server.observer, conn_id)
  await.expect_down(handler, "slow reader's WebSocket handler")
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

@external(erlang, "brazier_ws_test_ffi", "suspend")
fn erlang_suspend(pid: Pid) -> Result(Nil, Nil)

@external(erlang, "brazier_ws_test_ffi", "resume")
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
  // The rejected batch consumed no budget: one event still fits, and it is
  // the first event dispatched, so the batch dispatched nothing.
  send_text(probe.socket, event_json("after"))
  let assert transport.ClientEvent(handler_id: "after", ..) =
    next_event(server.observer)
  close(server, probe)
}

pub fn batches_share_the_per_second_budget_test() {
  let server = start_server(test_limits(), None)
  let probe = open(server)
  send_text(probe.socket, batch_json(30))
  send_text(probe.socket, batch_json(30))
  // 30 + 30 > 50: the first batch is dispatched, the second is rejected.
  let assert "{\"type\":\"error\",\"reason\":\"Rate limited\"}" =
    recv_text(probe.socket)
  let assert transport.ClientEventBatch(events) = next_event(server.observer)
  let assert 30 = list.length(events)
  // 20 of the 50 remain: a single event is dispatched next, so the rejected
  // second batch dispatched nothing.
  send_text(probe.socket, event_json("after"))
  let assert transport.ClientEvent(handler_id: "after", ..) =
    next_event(server.observer)
  close(server, probe)
}

pub fn oversized_batch_is_rejected_test() {
  let limits =
    transport.SecurityLimits(..test_limits(), max_events_per_second: 1000)
  let server = start_server(limits, None)
  let probe = open(server)
  send_text(probe.socket, batch_json(101))
  let assert "{\"type\":\"error\",\"reason\":\"Batch too large\"}" =
    recv_text(probe.socket)
  // The next event is the first dispatched: the oversized batch sent none.
  send_text(probe.socket, event_json("after"))
  let assert transport.ClientEvent(handler_id: "after", ..) =
    next_event(server.observer)
  close(server, probe)
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
  close(server, probe)
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
  // The handler dispatches events and then runs on_close from the same
  // process, so all 5 accepted events arrive before the close notification.
  let #(before_close, closed) =
    events_until_closed(server.observer, probe.conn_id, [])
  let assert True = closed
  let assert 5 = list.length(before_close)
  // Once the handler is down it has nothing in flight: no event follows.
  await.expect_down(probe.handler, "rate-violating WebSocket handler")
  let assert [] = events_in_mailbox(server.observer)
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
  // The listener runs without an application: start the node-wide session
  // scope that ws_session_auth binds connections in.
  session.ensure_registry()
  start_server(
    transport.SecurityLimits(..test_limits(), ws_auth_recheck_interval_ms: 100),
    Some(auth.ws_session_auth(store, auth.dev_session_config())),
  )
}

fn cookie_headers(port: Int, session_id: String) -> List(#(String, String)) {
  with_header(upgrade_headers(port), "Cookie", "brazier_session=" <> session_id)
}

pub fn missing_session_cookie_gets_401_test() {
  let store = session.new_store("ws2_ws_no_cookie")
  let server = session_auth_server(store)
  let #(socket, head) = raw_upgrade(server.port, upgrade_headers(server.port))
  let assert "401" = status_of(head)
  raw_close(socket)
}

pub fn expired_session_gets_401_test() {
  // The store reads a manual clock, so the session expires when the test
  // says, without sleeping.
  let clock = new_clock(1_000_000)
  let assert Ok(store) =
    session.start_store_with_clock(
      session.LocalEts("ws2_ws_expired"),
      session.StoreConfig(
        absolute_ttl_ms: 60_000,
        idle_ttl_ms: 40,
        sweep_interval_ms: 60_000,
      ),
      fn() { clock_now(clock) },
    )
  let assert Ok(sess) = auth.login(store, "user-1")
  advance_clock(clock, 40)
  let server = session_auth_server(store)
  let #(socket, head) =
    raw_upgrade(server.port, cookie_headers(server.port, sess.id))
  let assert "401" = status_of(head)
  raw_close(socket)
}

pub fn logout_closes_live_socket_4401_test() {
  let store = session.new_store("ws2_ws_logout")
  let assert Ok(sess) = auth.login(store, "user-1")
  let server = session_auth_server(store)
  let probe = open_with(server, cookie_headers(server.port, sess.id))
  // ws_auth binds the handler (a synchronous pg join) before the 101.
  let assert 1 = session.bound_process_count(store, sess.id)
  let assert Ok(Nil) = auth.logout(store, sess.id)
  assert_closed_with(probe, server, 4401)
}

pub fn old_session_id_is_unusable_after_login_rotation_test() {
  let store = session.new_store("ws2_ws_rotation")
  let assert Ok(anonymous) = auth.login(store, "guest")
  let server = session_auth_server(store)
  let probe = open_with(server, cookie_headers(server.port, anonymous.id))
  // ws_auth binds the handler (a synchronous pg join) before the 101.
  let assert 1 = session.bound_process_count(store, anonymous.id)
  let assert Ok(fresh) =
    auth.login_rotating(store, Some(anonymous.id), "user-1")
  // The socket bound to the old id is closed...
  assert_closed_with(probe, server, 4401)
  // ...the old id cannot open a new one...
  let #(socket, head) =
    raw_upgrade(server.port, cookie_headers(server.port, anonymous.id))
  let assert "401" = status_of(head)
  raw_close(socket)
  // ...and the new id can.
  let renewed = open_with(server, cookie_headers(server.port, fresh.id))
  close(server, renewed)
}

pub fn failed_auth_recheck_closes_4401_test() {
  // ws_auth that does not bind the process: only the periodic re-check can
  // notice the session is gone.
  let store = session.new_store("ws2_ws_recheck")
  let assert Ok(sess) = auth.login(store, "user-1")
  // Every run of the check is reported, so the test waits for a re-check
  // instead of sleeping past the interval and hoping one ran.
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
  let server =
    start_server(
      transport.SecurityLimits(
        ..test_limits(),
        ws_auth_recheck_interval_ms: 100,
      ),
      Some(check),
    )
  let probe = open_with(server, cookie_headers(server.port, sess.id))
  // The upgrade ran the check once; the next run is the periodic re-check,
  // and the connection survives it.
  let assert Ok(Ok(Nil)) = process.receive(checks, await.deadline_ms)
  let assert Ok(Ok(Nil)) = process.receive(checks, await.deadline_ms)
  let assert True = process.is_alive(probe.handler)
  session.delete(store, sess.id)
  assert_closed_with(probe, server, 4401)
  // The handler is down, so every re-check it ran has reported: any that
  // passed before the delete, then the failure that closed the socket.
  let assert [Error("session gone"), ..passed] =
    list.reverse(await.drain(checks))
  let assert True = list.all(passed, fn(check) { check == Ok(Nil) })
}

pub fn allow_guests_ws_recheck_closes_a_signed_out_socket_4401_test() {
  // Removing the user sends no revocation: only the periodic re-check can
  // see that the bound socket is no longer signed in.
  let store = session.new_store("ws2_ws_guests_recheck")
  let assert Ok(sess) = auth.login(store, "user-1")
  let guests_ws = auth.allow_guests_ws(store, auth.dev_session_config())
  // Every run of the check is reported with the process it ran in, so the
  // test waits for a re-check instead of sleeping past the interval.
  let checks = process.new_subject()
  let check = fn(req: Request(Connection)) {
    let result = guests_ws(req)
    process.send(checks, #(process.self(), result))
    result
  }
  session.ensure_registry()
  let server =
    start_server(
      transport.SecurityLimits(
        ..test_limits(),
        ws_auth_recheck_interval_ms: 100,
      ),
      Some(check),
    )
  let signed_in = open_with(server, cookie_headers(server.port, sess.id))
  let guest = open_with(server, upgrade_headers(server.port))
  let assert 1 = session.bound_process_count(store, sess.id)
  let _ =
    await.expect(checks, "a signed-in re-check that passes", matching: fn(c) {
      c == #(signed_in.handler, Ok(Nil))
    })
  let assert Ok(_) = session.update(store, sess.id, dict.delete(_, "user_id"))
  let _ =
    await.expect(checks, "a signed-in re-check that fails", matching: fn(c) {
      c.0 == signed_in.handler && result.is_error(c.1)
    })
  assert_closed_with(signed_in, server, 4401)
  // The signed-in handler is down, so what is left are guest re-checks,
  // and each one passed.
  let assert True =
    list.all(await.drain(checks), fn(c) { c == #(guest.handler, Ok(Nil)) })
  // The guest socket stays open through a re-check that ran after the close.
  let _ =
    await.expect(checks, "a guest re-check that passes", matching: fn(c) {
      c == #(guest.handler, Ok(Nil))
    })
  let assert True = process.is_alive(guest.handler)
  close(server, guest)
  // Once the guest handler is down every re-check it ran has reported, and
  // each one passed.
  await.expect_down(guest.handler, "guest WebSocket handler")
  let assert True =
    list.all(await.drain(checks), fn(c) { c == #(guest.handler, Ok(Nil)) })
}

// --- Pure helpers ---

/// No extra allowed origins: only the request's own origin passes.
fn no_origins() -> transport.AllowedOrigins {
  let assert Ok(none) = transport.parse_allowed_origins([])
    as "an empty origin list always parses"
  none
}

pub fn origin_allowed_compares_scheme_host_and_port_test() {
  let assert Ok(Nil) =
    transport.origin_allowed(
      "http://example.com",
      "http",
      "example.com",
      no_origins(),
    )
  let assert Ok(Nil) =
    transport.origin_allowed(
      "https://example.com",
      "https",
      "example.com:443",
      no_origins(),
    )
  let assert Ok(Nil) =
    transport.origin_allowed(
      "HTTP://Example.COM:80",
      "http",
      "example.com",
      no_origins(),
    )
  let assert Error(_) =
    transport.origin_allowed(
      "https://example.com",
      "http",
      "example.com",
      no_origins(),
    )
  let assert Error(_) =
    transport.origin_allowed(
      "http://example.com:8080",
      "http",
      "example.com",
      no_origins(),
    )
  let assert Error(_) =
    transport.origin_allowed(
      "http://evil.com",
      "http",
      "example.com",
      no_origins(),
    )
  let assert Error(_) =
    transport.origin_allowed(
      "http://example.com.evil.com",
      "http",
      "example.com",
      no_origins(),
    )
  let assert Error(_) =
    transport.origin_allowed(
      "http://user@example.com",
      "http",
      "example.com",
      no_origins(),
    )
  let assert Error(_) =
    transport.origin_allowed("null", "http", "example.com", no_origins())
  let assert Error(_) =
    transport.origin_allowed(
      "ws://example.com",
      "http",
      "example.com",
      no_origins(),
    )
}

pub fn origin_allowed_honours_allow_list_test() {
  let assert Ok(allowed) =
    transport.parse_allowed_origins([
      "https://app.example.com",
      "http://localhost:3000",
    ])
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
    transport.origin_allowed(
      "http://[::1]:4000",
      "http",
      "[::1]:4000",
      no_origins(),
    )
  let assert Error(_) =
    transport.origin_allowed(
      "http://[::1]:4001",
      "http",
      "[::1]:4000",
      no_origins(),
    )
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
  // One connection before the snapshot starts anything created lazily on
  // first use (the node-wide per-IP slot scope), so the snapshot holds every
  // process that legitimately outlives a connection.
  let _warm_up = load_client(port, 1)
  let before = all_processes()
  let started = monotonic_us()
  let latencies =
    run_parallel(sockets, fn(_i) { load_client(port, events) })
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
  // Handlers, runtimes, listeners and the client workers all exit: every
  // process started during the run must go down. Counting pids, not a
  // node-wide total, so an unrelated process exiting cannot hide a leak.
  let started_during_run =
    list.filter(all_processes(), fn(p) { !list.contains(before, p) })
  list.each(started_during_run, fn(p) {
    await.expect_down(p, "process started during the WebSocket load run")
  })
}

/// One client: upgrade, join, `events` round-trips, clean close. Returns
/// each round-trip's latency in microseconds.
fn load_client(port: Int, events: Int) -> List(Int) {
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
  let assert Ok(1000) = expect_closed(socket, await.deadline_ms)
  raw_close(socket)
  samples
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

/// A manual wall clock for session stores (brazier_session_clock_test_ffi).
type ManualClock

@external(erlang, "brazier_session_clock_test_ffi", "new")
fn new_clock(start_ms: Int) -> ManualClock

@external(erlang, "brazier_session_clock_test_ffi", "now")
fn clock_now(clock: ManualClock) -> Int

@external(erlang, "brazier_session_clock_test_ffi", "advance")
fn advance_clock(clock: ManualClock, ms: Int) -> Nil
