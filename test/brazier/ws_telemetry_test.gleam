/// Telemetry emitted by the WebSocket transport, observed over real
/// sockets: the `[brazier, ws, upgrade]` span, the per-connection
/// `[brazier, ws, close]` summary, `[brazier, ws, rate_limited]` and
/// `[brazier, ws, backpressure]`.
///
/// Handlers run in the emitting process (the connection's handler), so
/// each test forwards events to its own subject and synchronizes on them;
/// nothing sleeps.
import brazier/monitored
import brazier/telemetry.{type Event}
import brazier/transport
import brazier/transport/server
import gleam/bit_array
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- Harness ----------------------------------------------------------------

type RawSocket

type Server {
  Server(listener: server.Listener, port: Int, connected: Subject(Connected))
}

/// What the runtime factory saw for a new connection.
type Connected {
  Connected(
    conn_id: String,
    runtime: Subject(transport.InternalMessage),
    handler: Pid,
  )
}

type Probe {
  Probe(
    socket: RawSocket,
    conn_id: String,
    runtime: Subject(transport.InternalMessage),
    handler: Pid,
  )
}

const host = "127.0.0.1"

fn limits() -> transport.SecurityLimits {
  transport.SecurityLimits(
    ..transport.default_security_limits(),
    max_ws_connections_per_ip: 10_000,
  )
}

fn start_server(limits: transport.SecurityLimits) -> Server {
  let assert Ok(Nil) = telemetry.start()
  let connected = process.new_subject()
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
        process.send(connected, Connected(conn_id, runtime, process.self()))
        Ok(#(fn(_cid, _msg) { Nil }, fn(_cid) { Nil }))
      }),
      ws_auth: None,
      ssr_factory: None,
      security_limits: limits,
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "test listener must bind an OS-assigned port"
  Server(
    listener: listener,
    port: server.get_port(listener),
    connected: connected,
  )
}

fn origin(port: Int) -> String {
  "http://" <> host <> ":" <> int.to_string(port)
}

fn upgrade_headers(port: Int) -> List(#(String, String)) {
  [
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    #("Sec-WebSocket-Version", "13"),
    #("Origin", origin(port)),
  ]
}

/// Send an upgrade request; the status code of the response head.
fn upgrade(
  port: Int,
  headers: List(#(String, String)),
) -> #(RawSocket, String) {
  let assert Ok(socket) = raw_connect(host, port)
    as "test client must connect to the listener"
  let assert Ok(Nil) =
    raw_send(
      socket,
      raw_upgrade_request(
        "/ws?path=%2F",
        host <> ":" <> int.to_string(port),
        headers,
      ),
    )
    as "test client must send the upgrade request"
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
    as "server must answer the upgrade request"
  let assert Ok(head) = bit_array.to_string(head) as "the response head is text"
  #(socket, string.slice(head, 9, 3))
}

fn open(app: Server) -> Probe {
  let #(socket, status) = upgrade(app.port, upgrade_headers(app.port))
  let assert "101" = status
  let assert Ok(Connected(conn_id, runtime, handler)) =
    process.receive(app.connected, 3000)
    as "runtime factory must be called for an upgraded connection"
  Probe(socket: socket, conn_id: conn_id, runtime: runtime, handler: handler)
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

const heartbeat = "{\"type\":\"heartbeat\"}"

// --- Event helpers ----------------------------------------------------------

const ws_events = [
  ["brazier", "ws", "upgrade", "start"],
  ["brazier", "ws", "upgrade", "stop"],
  ["brazier", "ws", "upgrade", "exception"],
  ["brazier", "ws", "close"],
  ["brazier", "ws", "rate_limited"],
  ["brazier", "ws", "backpressure"],
]

/// Run `run` with every WebSocket event forwarded to it; the handler is
/// detached afterwards even if `run` crashes.
fn listen(run: fn(Subject(Event)) -> a) -> a {
  monitored.listening(ws_events, run)
}

/// The first event matching `matches`; others (from earlier steps of the
/// test) are skipped, never asserted on.
fn expect(events: Subject(Event), matches: fn(Event) -> Bool) -> Event {
  let assert Ok(event) = process.receive(events, 3000)
    as "expected telemetry event did not arrive within 3s"
  case matches(event) {
    True -> event
    False -> expect(events, matches)
  }
}

fn named(event: Event, suffix: List(String)) -> Bool {
  event.name == list.append(["brazier", "ws"], suffix)
}

fn for_connection(probe: Probe, suffix: List(String)) -> fn(Event) -> Bool {
  fn(event) {
    named(event, suffix)
    && telemetry.string(event, "connection_id") == Ok(probe.conn_id)
  }
}

fn upgrade_stop(event: Event) -> Bool {
  named(event, ["upgrade", "stop"])
}

fn int_of(event: Event, key: String) -> Int {
  let assert Ok(value) = telemetry.int(event, key)
    as "event must carry the integer key"
  value
}

fn finish(app: Server) -> Nil {
  server.stop(app.listener)
}

// --- [brazier, ws, upgrade] --------------------------------------------------

pub fn accepted_upgrade_span_reports_ok_test() {
  let app = start_server(limits())
  use events <- listen()
  let probe = open(app)
  let start = expect(events, named(_, ["upgrade", "start"]))
  let assert Ok("/ws") = telemetry.string(start, "route")
  let assert Error(Nil) = dict.get(start.metadata, "result")
  let stop = expect(events, upgrade_stop)
  let assert Ok("ok") = telemetry.string(stop, "result")
  let assert Ok("/ws") = telemetry.string(stop, "route")
  let assert True = int_of(stop, "duration") >= 0
  raw_close(probe.socket)
  finish(app)
}

pub fn refused_upgrade_span_reports_the_refusal_test() {
  let app = start_server(limits())
  use events <- listen()
  let headers =
    list.filter(upgrade_headers(app.port), fn(h) { h.0 != "Origin" })
  let #(socket, status) = upgrade(app.port, headers)
  let assert "403" = status
  // The server half-closes after the refusal and lingers, draining the peer,
  // until the peer closes (or 1 s passes); the span stops after that. Close
  // first so the span ends on the peer's close, not on the linger timeout.
  raw_close(socket)
  let stop = expect(events, upgrade_stop)
  let assert Ok("rejected_origin") = telemetry.string(stop, "result")
  // A refused upgrade never reached the runtime factory. The stop event is
  // emitted after the refusal returns, so the factory has had its chance.
  let assert Error(Nil) = process.receive(app.connected, 0)

  let unsupported =
    list.map(upgrade_headers(app.port), fn(h) {
      case h.0 {
        "Sec-WebSocket-Version" -> #(h.0, "8")
        _ -> h
      }
    })
  let #(socket, status) = upgrade(app.port, unsupported)
  let assert "426" = status
  raw_close(socket)
  let stop = expect(events, upgrade_stop)
  let assert Ok("rejected_version") = telemetry.string(stop, "result")
  let assert Error(Nil) = process.receive(app.connected, 0)
  finish(app)
}

// --- [brazier, ws, close] ----------------------------------------------------

pub fn peer_close_reports_its_code_and_the_traffic_test() {
  let app = start_server(limits())
  use events <- listen()
  let probe = open(app)
  send_text(probe.socket, heartbeat)
  let assert "{\"type\":\"heartbeat_ack\"" <> _ = recv_text(probe.socket)
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(1, 8, <<4000:16, "bye":utf8>>))
    as "test client close must be sent"
  let close = expect(events, for_connection(probe, ["close"]))
  let assert Ok(4000) = telemetry.int(close, "close_code")
  let assert Ok("peer_close") = telemetry.string(close, "reason")
  // In: the heartbeat and the close. Out: the ack and the echoed close.
  let assert 2 = int_of(close, "frames_in")
  let assert True = int_of(close, "frames_out") >= 2
  let assert True = int_of(close, "bytes_in") > string.byte_size(heartbeat)
  let assert True = int_of(close, "bytes_out") > 0
  let assert True = int_of(close, "duration") > 0
  raw_close(probe.socket)
  finish(app)
}

pub fn empty_peer_close_reports_1005_test() {
  let app = start_server(limits())
  use events <- listen()
  let probe = open(app)
  let assert Ok(Nil) = raw_send(probe.socket, masked_frame(1, 8, <<>>))
    as "test client close must be sent"
  let close = expect(events, for_connection(probe, ["close"]))
  let assert Ok(1005) = telemetry.int(close, "close_code")
  let assert Ok("peer_close") = telemetry.string(close, "reason")
  raw_close(probe.socket)
  finish(app)
}

pub fn protocol_error_reports_the_close_sent_test() {
  let app = start_server(limits())
  use events <- listen()
  let probe = open(app)
  // An unmasked client frame is a protocol error (RFC 6455 5.1).
  let assert Ok(Nil) =
    raw_send(probe.socket, unmasked_frame(1, 1, <<heartbeat:utf8>>))
    as "test client send must succeed"
  let close = expect(events, for_connection(probe, ["close"]))
  let assert Ok(1002) = telemetry.int(close, "close_code")
  let assert Ok("protocol_error") = telemetry.string(close, "reason")
  raw_close(probe.socket)
  finish(app)
}

pub fn invalid_utf8_reports_a_snake_case_label_test() {
  let app = start_server(limits())
  use events <- listen()
  let probe = open(app)
  let assert Ok(Nil) =
    raw_send(probe.socket, masked_frame(1, 1, <<0xFF, 0xFE>>))
    as "test client send must succeed"
  let close = expect(events, for_connection(probe, ["close"]))
  let assert Ok(1007) = telemetry.int(close, "close_code")
  let assert Ok("invalid_utf8") = telemetry.string(close, "reason")
  raw_close(probe.socket)
  finish(app)
}

pub fn dropped_tcp_connection_reports_1006_test() {
  let app = start_server(limits())
  use events <- listen()
  let probe = open(app)
  raw_close(probe.socket)
  let close = expect(events, for_connection(probe, ["close"]))
  let assert Ok(1006) = telemetry.int(close, "close_code")
  let assert Ok("tcp_closed") = telemetry.string(close, "reason")
  let assert 0 = int_of(close, "frames_in")
  finish(app)
}

// --- [brazier, ws, rate_limited] ---------------------------------------------

pub fn event_over_the_rate_is_reported_test() {
  let app =
    start_server(transport.SecurityLimits(..limits(), max_events_per_second: 1))
  use events <- listen()
  let probe = open(app)
  send_text(probe.socket, event_json("a"))
  send_text(probe.socket, event_json("b"))
  let assert "{\"type\":\"error\",\"reason\":\"Rate limited\"}" =
    recv_text(probe.socket)
  let limited = expect(events, for_connection(probe, ["rate_limited"]))
  let assert Ok("event_rate") = telemetry.string(limited, "kind")
  let assert 1 = int_of(limited, "count")
  let assert 1 = int_of(limited, "violations")
  // The running count grows with every violation.
  send_text(probe.socket, event_json("c"))
  let assert "{\"type\":\"error\",\"reason\":\"Rate limited\"}" =
    recv_text(probe.socket)
  let again = expect(events, for_connection(probe, ["rate_limited"]))
  let assert 2 = int_of(again, "violations")
  raw_close(probe.socket)
  finish(app)
}

pub fn oversized_batch_is_reported_test() {
  let app =
    start_server(
      transport.SecurityLimits(..limits(), max_events_per_second: 1000),
    )
  use events <- listen()
  let probe = open(app)
  send_text(probe.socket, batch_json(101))
  let assert "{\"type\":\"error\",\"reason\":\"Batch too large\"}" =
    recv_text(probe.socket)
  let limited = expect(events, for_connection(probe, ["rate_limited"]))
  let assert Ok("batch_size") = telemetry.string(limited, "kind")
  raw_close(probe.socket)
  finish(app)
}

pub fn heartbeat_flood_is_reported_test() {
  let app = start_server(limits())
  use events <- listen()
  let probe = open(app)
  // Two heartbeats per second are acknowledged; the third is a violation.
  list.each([1, 2, 3], fn(_) { send_text(probe.socket, heartbeat) })
  let limited = expect(events, for_connection(probe, ["rate_limited"]))
  let assert Ok("heartbeat_rate") = telemetry.string(limited, "kind")
  let assert 1 = int_of(limited, "violations")
  raw_close(probe.socket)
  finish(app)
}

// --- [brazier, ws, backpressure] ---------------------------------------------

pub fn runtime_backpressure_is_reported_test() {
  let app = start_server(limits())
  use events <- listen()
  let probe = open(app)
  process.send(
    probe.runtime,
    transport.CloseForBackpressure("runtime overloaded"),
  )
  let pressure = expect(events, for_connection(probe, ["backpressure"]))
  let assert Ok("runtime") = telemetry.string(pressure, "reason")
  let assert True = int_of(pressure, "queue_len") >= 0
  let close = expect(events, for_connection(probe, ["close"]))
  let assert Ok(1013) = telemetry.int(close, "close_code")
  let assert Ok("backpressure") = telemetry.string(close, "reason")
  raw_close(probe.socket)
  finish(app)
}

pub fn outbound_queue_overflow_is_reported_test() {
  let app =
    start_server(transport.SecurityLimits(..limits(), ws_max_outbound_queue: 5))
  use events <- listen()
  let probe = open(app)
  // Suspend the handler so its mailbox fills deterministically.
  let assert Ok(Nil) = suspend(probe.handler)
    as "the connection handler must be suspendable"
  list.each(list.repeat(Nil, 50), fn(_) {
    process.send(probe.runtime, transport.SendError("queued"))
  })
  let assert Ok(Nil) = resume(probe.handler)
    as "the connection handler must be resumable"
  let pressure = expect(events, for_connection(probe, ["backpressure"]))
  let assert Ok("outbound_queue") = telemetry.string(pressure, "reason")
  let assert True = int_of(pressure, "queue_len") > 5
  let close = expect(events, for_connection(probe, ["close"]))
  let assert Ok(1013) = telemetry.int(close, "close_code")
  raw_close(probe.socket)
  finish(app)
}

// --- FFI --------------------------------------------------------------------

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

@external(erlang, "brazier_ws_test_ffi", "unmasked_frame")
fn unmasked_frame(fin: Int, opcode: Int, payload: BitArray) -> BitArray

@external(erlang, "brazier_ws_test_ffi", "suspend")
fn suspend(pid: Pid) -> Result(Nil, Nil)

@external(erlang, "brazier_ws_test_ffi", "resume")
fn resume(pid: Pid) -> Result(Nil, Nil)
