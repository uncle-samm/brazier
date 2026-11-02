/// Beacon's WebSocket transport layer.
/// Manages WebSocket connections with one BEAM process per connection.
/// Follows LiveView's connection lifecycle: connect → init → handle messages → close.
///
/// Uses Beacon's own minimal HTTP/WebSocket server (beacon/transport/server)
/// instead of Mist. Direct gen_tcp for zero unnecessary abstraction layers.
///
/// Reference: LiveView channel protocol, RFC 6455.
import beacon/error
import beacon/log
import beacon/middleware
import beacon/ssr
import beacon/static
import beacon/transport/http as transport_http
import beacon/transport/server.{
  type Connection, type ResponseBody, type Socket, Bytes,
}
import beacon/transport/ws
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// Unique identifier for a WebSocket connection.
/// Used for logging and session tracking.
pub type ConnectionId =
  String

/// Messages sent from the client (browser) to the server.
/// This is Beacon's wire protocol — not Lustre's internal format.
pub type ClientMessage {
  /// A DOM event was fired (click, input, submit, etc).
  ClientEvent(
    /// The event name (e.g. "click", "input").
    name: String,
    /// The handler identifier from the data-beacon-event-* attribute value.
    /// This is the semantic identifier set by the view (e.g. "increment", "decrement").
    handler_id: String,
    /// JSON-encoded event data.
    data: String,
    /// Path to the element in the VDOM tree that fired the event.
    target_path: String,
    /// Monotonic event clock value for ordering and acknowledgment.
    /// Reference: LiveView 1.1 event clocking.
    clock: Int,
    /// JSON-encoded patch operations from client-side model diff.
    /// The server treats these as optimization hints only and never uses them
    /// as authoritative state. Empty string "" means no client hint.
    /// Size is bounded by max_message_bytes in SecurityLimits (default 64KB).
    ops: String,
  )
  /// Client sends a heartbeat to keep the connection alive.
  ClientHeartbeat
  /// Client is requesting initial state after connecting.
  /// Includes an optional session token for state recovery
  /// and the current URL path for route-aware apps.
  ClientJoin(token: String, path: String)
  /// Client navigated to a new URL path (SPA navigation).
  ClientNavigate(path: String)
  /// Client requests a full authoritative model sync without remounting HTML.
  ClientRequestSync
  /// Batch of events: LOCAL events replayed + MODEL event at the end.
  /// Sent when a MODEL event fires after LOCAL events accumulated state.
  ClientEventBatch(events: List(ClientMessage))
}

/// Messages sent from the server to the client (browser).
pub type ServerMessage {
  /// Initial mount: SSR HTML for first paint.
  ServerMount(payload: String)
  /// Server acknowledges a heartbeat.
  ServerHeartbeatAck
  /// Server-initiated error message.
  ServerError(reason: String)
  /// Authoritative Model state from server.
  /// Client renders the view locally from this state.
  ServerModelSync(model_json: String, version: Int, ack_clock: Int)
  /// Incremental model patch — only changed fields.
  /// Client applies ops to its cached model JSON instead of replacing entirely.
  ServerPatch(ops_json: String, version: Int, ack_clock: Int)
  /// Server-initiated navigation (redirect via pushState).
  ServerNavigate(path: String)
  /// Server-initiated hard navigation (full page reload via window.location.href).
  /// Use when the browser needs to make a real HTTP request (e.g., to receive Set-Cookie).
  ServerHardNavigate(path: String)
  /// Dev mode: tell browser to reload.
  ServerReload
}

/// Internal messages that the connection process can receive.
/// These come from the runtime (pushing patches) or from TCP events.
pub type InternalMessage {
  /// A mount payload needs to be sent to the client.
  SendMount(payload: String)
  /// An error needs to be sent to the client.
  SendError(reason: String)
  /// Send authoritative Model state to the client.
  SendModelSync(model_json: String, version: Int, ack_clock: Int)
  /// Send incremental model patch to the client.
  SendPatch(ops_json: String, version: Int, ack_clock: Int)
  /// Send navigation redirect to the client (pushState).
  SendNavigate(path: String)
  /// Send hard navigation to the client (full page reload).
  SendHardNavigate(path: String)
  /// Close the connection because the server has detected sustained pressure.
  CloseForBackpressure(reason: String)
  // --- TCP/WebSocket events (internal to transport layer) ---
  /// Raw TCP data received — needs WebSocket frame decoding.
  ReceivedTcpData(data: BitArray)
  /// TCP connection closed by peer.
  TcpConnectionClosed
  /// TCP error occurred.
  TcpConnectionError(reason: String)
}

/// Configurable security limits for the transport layer.
/// All fields have sensible defaults via `default_security_limits()`.
/// `validate_security_limits` rejects nonsensical values; the WebSocket
/// upgrade path refuses to run with invalid limits.
pub type SecurityLimits {
  SecurityLimits(
    /// Maximum WebSocket message size in bytes. Default: 65536 (64KB).
    /// Bounds both a single frame (checked from the frame header, before the
    /// payload is buffered) and a reassembled fragmented message. Exceeding
    /// it closes the connection with 1009.
    max_message_bytes: Int,
    /// Maximum events per second per connection. Default: 50.
    /// Every event inside an `event_batch` counts individually.
    max_events_per_second: Int,
    /// Maximum concurrent HTTP/WebSocket connections globally. Default: 10000.
    max_connections: Int,
    /// Maximum number of HTTP headers accepted before upgrade. Default: 100.
    max_http_headers: Int,
    /// Maximum total HTTP header bytes accepted before upgrade. Default: 65536.
    max_http_header_bytes: Int,
    /// Timeout for request line/header reads before upgrade, in milliseconds. Default: 5000.
    pre_upgrade_timeout_ms: Int,
    // WebSocket limits
    /// Maximum concurrent WebSocket connections per peer IP (per listener).
    /// Upgrades beyond it get 429. Default: 100. Behind a reverse proxy every
    /// client shares the proxy's address — raise this or enforce it upstream.
    max_ws_connections_per_ip: Int,
    /// Interval between server pings, in milliseconds. Default: 30000.
    ws_ping_interval_ms: Int,
    /// Time a client has to answer a ping before the connection is closed
    /// (1000, "pong timeout"), in milliseconds. Default: 20000.
    ws_pong_timeout_ms: Int,
    /// Close the connection (1000, "idle timeout") when no application
    /// message — including the client heartbeat, sent every 30s — arrives for
    /// this long, in milliseconds. Default: 90000.
    ws_idle_timeout_ms: Int,
    /// A socket send that cannot complete within this many milliseconds
    /// fails and the socket is closed (slow reader protection). Default: 15000.
    ws_send_timeout_ms: Int,
    /// Maximum messages queued for the connection process. When the runtime
    /// produces faster than the client reads, the connection closes with 1013.
    /// Default: 1000.
    ws_max_outbound_queue: Int,
    /// Interval for re-running `ws_auth` on a live connection, in
    /// milliseconds. A failed re-check closes with 4401. Default: 60000.
    ws_auth_recheck_interval_ms: Int,
    /// Undecodable messages tolerated per connection before it is closed
    /// with 1008. Default: 10.
    ws_max_decode_errors: Int,
    /// Rate limit violations tolerated within one rate window before the
    /// connection is closed with 1008. Each rejected message is one
    /// violation, so the default tolerates a burst of roughly three times
    /// `max_events_per_second` in one window. Default: 100.
    ws_max_rate_violations: Int,
    /// Extra origins (e.g. "https://app.example.com") allowed to open
    /// WebSockets in addition to the request's own scheme/host/port.
    /// Default: [].
    ws_allowed_origins: List(String),
  )
}

/// Sensible default security limits.
pub fn default_security_limits() -> SecurityLimits {
  SecurityLimits(
    max_message_bytes: 65_536,
    max_events_per_second: 50,
    max_connections: 10_000,
    max_http_headers: 100,
    max_http_header_bytes: 65_536,
    pre_upgrade_timeout_ms: 5000,
    max_ws_connections_per_ip: 100,
    ws_ping_interval_ms: 30_000,
    ws_pong_timeout_ms: 20_000,
    ws_idle_timeout_ms: 90_000,
    ws_send_timeout_ms: 15_000,
    ws_max_outbound_queue: 1000,
    ws_auth_recheck_interval_ms: 60_000,
    ws_max_decode_errors: 10,
    ws_max_rate_violations: 100,
    ws_allowed_origins: [],
  )
}

/// Largest delay `erlang:send_after/3` accepts (2^32 - 1 ms).
const max_timer_ms = 4_294_967_295

/// Validate security limits. Every count, size and interval must be
/// positive (the two abuse thresholds may be 0, meaning "first offence
/// closes"), timer intervals must fit `erlang:send_after/3`, and every
/// allowed origin must be a bare `scheme://host[:port]` origin.
pub fn validate_security_limits(limits: SecurityLimits) -> Result(Nil, String) {
  let positive = [
    #("max_message_bytes", limits.max_message_bytes),
    #("max_events_per_second", limits.max_events_per_second),
    #("max_connections", limits.max_connections),
    #("max_http_headers", limits.max_http_headers),
    #("max_http_header_bytes", limits.max_http_header_bytes),
    #("pre_upgrade_timeout_ms", limits.pre_upgrade_timeout_ms),
    #("max_ws_connections_per_ip", limits.max_ws_connections_per_ip),
    #("ws_send_timeout_ms", limits.ws_send_timeout_ms),
    #("ws_max_outbound_queue", limits.ws_max_outbound_queue),
  ]
  let timers = [
    #("ws_ping_interval_ms", limits.ws_ping_interval_ms),
    #("ws_pong_timeout_ms", limits.ws_pong_timeout_ms),
    #("ws_idle_timeout_ms", limits.ws_idle_timeout_ms),
    #("ws_auth_recheck_interval_ms", limits.ws_auth_recheck_interval_ms),
  ]
  let non_negative = [
    #("ws_max_decode_errors", limits.ws_max_decode_errors),
    #("ws_max_rate_violations", limits.ws_max_rate_violations),
  ]
  let outcome = {
    use _ <- result.try(
      list.try_each(positive, fn(field) {
        case field.1 > 0 {
          True -> Ok(Nil)
          False -> Error(field.0 <> " must be > 0")
        }
      }),
    )
    use _ <- result.try(
      list.try_each(timers, fn(field) {
        case field.1 > 0 && field.1 <= max_timer_ms {
          True -> Ok(Nil)
          False ->
            Error(
              field.0
              <> " must be in 1.."
              <> int.to_string(max_timer_ms)
              <> "ms",
            )
        }
      }),
    )
    use _ <- result.try(
      list.try_each(non_negative, fn(field) {
        case field.1 >= 0 {
          True -> Ok(Nil)
          False -> Error(field.0 <> " must be >= 0")
        }
      }),
    )
    list.try_each(limits.ws_allowed_origins, fn(origin) {
      case parse_origin(origin) {
        Ok(Origin(has_path: False, ..)) -> Ok(Nil)
        Ok(Origin(has_path: True, ..)) ->
          Error(
            "ws_allowed_origins entry must not contain a path: \""
            <> origin
            <> "\"",
          )
        Error(reason) ->
          Error(
            "invalid ws_allowed_origins entry \"" <> origin <> "\": " <> reason,
          )
      }
    })
  }
  case outcome {
    Ok(Nil) -> {
      log.debug("beacon.transport", "Security limits valid")
      Ok(Nil)
    }
    Error(reason) -> {
      log.error("beacon.transport", "Invalid security limits: " <> reason)
      Error(reason)
    }
  }
}

/// Timer events a WebSocket connection process schedules for itself.
pub type WsTimer {
  /// Send the next server ping.
  PingTick
  /// Deadline for the pong answering ping `seq`.
  PongDeadline(seq: Int)
  /// Check whether the connection has been idle too long.
  IdleCheck
  /// Re-run `ws_auth` against the original upgrade request.
  AuthRecheck
}

/// State held by each WebSocket connection process.
pub type ConnectionState {
  ConnectionState(
    /// Unique ID for this connection, used in logging.
    id: ConnectionId,
    /// The gen_tcp socket for this connection.
    socket: Socket,
    /// Callback invoked when a client event is received (per-connection).
    on_event: fn(ConnectionId, ClientMessage) -> Nil,
    /// Callback invoked when this connection closes (per-connection).
    on_close: fn(ConnectionId) -> Nil,
    /// Rate limiting: count of events in current 1-second window.
    event_count: Int,
    /// Rate limiting: start of current window (monotonic milliseconds).
    rate_window_start: Int,
    /// Security limits for this connection (copied from TransportConfig at init).
    security_limits: SecurityLimits,
    /// Heartbeat rate limiting: count in current 1-second window.
    heartbeat_count: Int,
    /// Heartbeat rate limiting: start of current window (monotonic milliseconds).
    heartbeat_window_start: Int,
    /// Receive buffer holding at most one partial frame between reads.
    buffer: BitArray,
    /// Fragmented message reassembly state.
    reassembly: ws.Reassembly,
    /// Peer IP address, for logs.
    peer_ip: String,
    /// Per-IP slot this connection holds (released on cleanup).
    slot_key: String,
    /// The original upgrade request (for periodic `ws_auth` re-checks).
    request: Request(Connection),
    /// The configured `ws_auth`, re-run every `ws_auth_recheck_interval_ms`.
    ws_auth: Option(fn(Request(Connection)) -> Result(Nil, String)),
    /// Monotonic ms of the last application message from the client.
    last_activity_ms: Int,
    /// Sequence number of the last ping sent.
    ping_seq: Int,
    /// Sequence number of the ping awaiting a pong, if any.
    pending_ping: Option(Int),
    /// Undecodable messages received so far.
    decode_errors: Int,
    /// Rate limit violations in the current rate window.
    rate_violations: Int,
    /// Subject the connection's own timers deliver to.
    timer_subject: process.Subject(WsTimer),
    /// Next server ping.
    ping_timer: Option(process.Timer),
    /// Deadline for the outstanding pong.
    pong_timer: Option(process.Timer),
    /// Next idle check.
    idle_timer: Option(process.Timer),
    /// Next `ws_auth` re-check (only when `ws_auth` is configured).
    auth_timer: Option(process.Timer),
  )
}

/// Configuration for the transport layer.
pub type TransportConfig {
  TransportConfig(
    /// Port to listen on.
    port: Int,
    /// Callback invoked when a new WebSocket connection is established.
    on_connect: fn(ConnectionId, process.Subject(InternalMessage)) -> Nil,
    /// Callback invoked when a client sends an event.
    on_event: fn(ConnectionId, ClientMessage) -> Nil,
    /// Callback invoked when a WebSocket connection closes.
    on_disconnect: fn(ConnectionId) -> Nil,
    /// Optional: pre-rendered page for SSR.
    /// If provided, HTTP requests get this instead of the default page.
    page_html: Option(ssr.RenderedPage),
    /// Optional: middleware pipeline applied to all HTTP requests.
    /// Middleware runs before routing (SSR, static files, WebSocket upgrade).
    middlewares: List(middleware.Middleware),
    /// Optional: static file serving configuration.
    static_config: Option(static.StaticConfig),
    /// Optional: factory that creates a per-connection runtime.
    /// If set, each WebSocket connection gets its OWN runtime (like LiveView).
    /// The factory returns callbacks for this specific connection's runtime.
    /// If None, uses the shared on_connect/on_event/on_disconnect callbacks.
    /// The factory receives the HTTP request so ws_init can read cookies/headers.
    runtime_factory: Option(
      fn(ConnectionId, process.Subject(InternalMessage), Request(Connection)) ->
        Result(
          #(fn(ConnectionId, ClientMessage) -> Nil, fn(ConnectionId) -> Nil),
          String,
        ),
    ),
    /// Optional: WebSocket authentication function.
    /// If set, runs before upgrade — returns Ok to allow, Error to reject with 401.
    ws_auth: Option(fn(Request(Connection)) -> Result(Nil, String)),
    /// Optional: SSR factory for route-aware server-side rendering.
    /// Given the HTTP request and path, returns the rendered page for that route.
    /// The request is available for reading cookies, headers, etc.
    /// When set, HTTP requests use this instead of page_html.
    ssr_factory: Option(fn(Request(Connection), String) -> ssr.RenderedPage),
    /// Configurable security limits (message size, rate limiting, max connections).
    /// Defaults to `default_security_limits()`.
    security_limits: SecurityLimits,
    /// Optional: API route handler — runs BEFORE SSR/static file routing.
    /// If it returns Some(response), that response is sent immediately.
    /// If it returns None, the request falls through to normal routing.
    api_handler: Option(
      fn(Request(Connection)) -> Option(response.Response(ResponseBody)),
    ),
  )
}

/// Generate a unique connection ID.
/// Uses a combination of the current monotonic time and a unique integer.
fn generate_connection_id() -> ConnectionId {
  let time = erlang_monotonic_time()
  let unique = erlang_unique_integer()
  "conn_" <> int.to_string(time) <> "_" <> int.to_string(unique)
}

@external(erlang, "erlang", "monotonic_time")
fn erlang_monotonic_time() -> Int

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

// --- Connection tracker FFI (global connection count via ETS) ---

@external(erlang, "beacon_connection_tracker_ffi", "init")
pub fn connection_tracker_init() -> Nil

@external(erlang, "beacon_connection_tracker_ffi", "increment")
fn connection_tracker_increment() -> Int

@external(erlang, "beacon_connection_tracker_ffi", "decrement")
fn connection_tracker_decrement() -> Int

@external(erlang, "beacon_connection_tracker_ffi", "count")
fn connection_tracker_count() -> Int

/// Encode a ServerMessage to JSON string for sending over the wire.
pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    ServerMount(payload) ->
      json.object([
        #("type", json.string("mount")),
        #("payload", json.string(payload)),
      ])
      |> json.to_string
    ServerHeartbeatAck ->
      json.object([#("type", json.string("heartbeat_ack"))])
      |> json.to_string
    ServerError(reason) ->
      json.object([
        #("type", json.string("error")),
        #("reason", json.string(reason)),
      ])
      |> json.to_string
    ServerModelSync(model_json, version, ack_clock) ->
      json.object([
        #("type", json.string("model_sync")),
        #("model", json.string(model_json)),
        #("version", json.int(version)),
        #("ack_clock", json.int(ack_clock)),
      ])
      |> json.to_string
    ServerPatch(ops_json, version, ack_clock) ->
      // ops_json is already a JSON-encoded array string — embed it raw
      json.object([
        #("type", json.string("patch")),
        #("ops", json.string(ops_json)),
        #("version", json.int(version)),
        #("ack_clock", json.int(ack_clock)),
      ])
      |> json.to_string
    ServerNavigate(path) ->
      json.object([
        #("type", json.string("navigate")),
        #("path", json.string(path)),
      ])
      |> json.to_string
    ServerHardNavigate(path) ->
      json.object([
        #("type", json.string("hard_navigate")),
        #("path", json.string(path)),
      ])
      |> json.to_string
    ServerReload ->
      json.object([#("type", json.string("reload"))])
      |> json.to_string
  }
}

/// Build a decoder for ClientMessage JSON.
/// Uses the "type" field to determine which variant to decode.
/// Follows Lustre's transport.server_message_decoder() pattern.
fn client_message_decoder() -> decode.Decoder(ClientMessage) {
  use msg_type <- decode.field("type", decode.string)
  case msg_type {
    "event" -> {
      use name <- decode.field("name", decode.string)
      use handler_id <- decode.optional_field("handler_id", "", decode.string)
      use data <- decode.field("data", decode.string)
      use target_path <- decode.field("target_path", decode.string)
      use clock <- decode.optional_field("clock", 0, decode.int)
      use ops <- decode.optional_field("ops", "", decode.string)
      decode.success(ClientEvent(
        name: name,
        handler_id: handler_id,
        data: data,
        target_path: target_path,
        clock: clock,
        ops: ops,
      ))
    }
    "heartbeat" -> decode.success(ClientHeartbeat)
    "join" -> {
      use token <- decode.optional_field("token", "", decode.string)
      use path <- decode.optional_field("path", "/", decode.string)
      decode.success(ClientJoin(token: token, path: path))
    }
    "navigate" -> {
      use path <- decode.field("path", decode.string)
      decode.success(ClientNavigate(path: path))
    }
    "request_sync" -> decode.success(ClientRequestSync)
    "event_batch" -> {
      // Decode array of events — each follows the "event" format
      let event_decoder = {
        use name <- decode.field("name", decode.string)
        use handler_id <- decode.optional_field("handler_id", "", decode.string)
        use data <- decode.field("data", decode.string)
        use target_path <- decode.optional_field(
          "target_path",
          "",
          decode.string,
        )
        use clock <- decode.optional_field("clock", 0, decode.int)
        use ops <- decode.optional_field("ops", "", decode.string)
        decode.success(ClientEvent(
          name: name,
          handler_id: handler_id,
          data: data,
          target_path: target_path,
          clock: clock,
          ops: ops,
        ))
      }
      use events <- decode.field("events", decode.list(event_decoder))
      decode.success(ClientEventBatch(events: events))
    }
    _unknown -> decode.failure(ClientHeartbeat, "ClientMessage type")
  }
}

/// Decode a JSON string from the client into a ClientMessage.
pub fn decode_client_message(
  raw: String,
) -> Result(ClientMessage, error.BeaconError) {
  case json.parse(raw, client_message_decoder()) {
    Ok(msg) -> {
      log.debug("beacon.transport", "Decoded client message")
      Ok(msg)
    }
    Error(_json_err) -> {
      log.warning("beacon.transport", "Failed to decode client message")
      Error(error.CodecError(
        reason: "Failed to decode client message",
        raw: raw,
      ))
    }
  }
}

/// Return the type name of a client message for safe logging.
/// Does not include payload data which may be sensitive.
fn client_message_type(msg: ClientMessage) -> String {
  case msg {
    ClientEvent(name: name, ..) -> "event:" <> name
    ClientHeartbeat -> "heartbeat"
    ClientJoin(..) -> "join"
    ClientNavigate(path: path) -> "navigate:" <> path
    ClientRequestSync -> "request_sync"
    ClientEventBatch(..) -> "event_batch"
  }
}

/// Connection context for log lines: connection id and peer address.
fn ctx(state: ConnectionState) -> String {
  state.id <> " (peer " <> state.peer_ip <> ")"
}

/// Send a ServerMessage over a WebSocket connection.
/// A failed send means the connection is dead (the socket is closed by the
/// VM on send timeout); callers must stop the connection on Error.
fn send_ws_message(
  state: ConnectionState,
  msg: ServerMessage,
) -> Result(Nil, String) {
  let encoded = encode_server_message(msg)
  case server.send_bytes(state.socket, ws.encode_text(encoded)) {
    Ok(Nil) -> {
      log.debug("beacon.transport", "Sent message to " <> state.id)
      Ok(Nil)
    }
    Error(reason) -> {
      log.warning(
        "beacon.transport",
        "Failed to send message to " <> ctx(state) <> ": " <> reason,
      )
      Error(reason)
    }
  }
}

/// Send a message; a failed send stops the connection.
fn send_or_stop(state: ConnectionState, msg: ServerMessage) -> Next {
  case send_ws_message(state, msg) {
    Ok(Nil) -> Continue(state)
    Error(reason) -> Stop(state, NoCloseFrame, "send failed: " <> reason)
  }
}

/// Send a pre-encoded frame (ping, pong); a failed send stops the connection.
fn send_frame_or_stop(
  state: ConnectionState,
  frame: BitArray,
  what: String,
) -> Next {
  case server.send_bytes(state.socket, frame) {
    Ok(Nil) -> {
      log.debug("beacon.transport", "Sent " <> what <> " to " <> state.id)
      Continue(state)
    }
    Error(reason) -> {
      log.warning(
        "beacon.transport",
        "Failed to send " <> what <> " to " <> ctx(state) <> ": " <> reason,
      )
      Stop(state, NoCloseFrame, what <> " send failed: " <> reason)
    }
  }
}

/// Length of one rate limiting window, in milliseconds.
const rate_window_ms = 1000

/// Maximum heartbeats per second. Heartbeats beyond this are not acked and
/// count as a rate limit violation.
const max_heartbeats_per_second = 2

/// Maximum number of events in a single batch message.
/// Prevents clients from sending unbounded arrays that consume server memory.
const max_batch_size = 100

/// Check the per-connection event rate limit for `cost` events (a batch
/// costs one per event). Returns the updated state and whether the events
/// were rejected. Rejected events do not consume budget. Starting a new
/// window also forgives earlier rate violations.
fn check_rate_limit(
  state: ConnectionState,
  cost: Int,
) -> #(ConnectionState, Bool) {
  let assert True = cost >= 1 as "every message costs at least one event"
  let state = roll_rate_window(state)
  let new_count = state.event_count + cost
  case new_count > state.security_limits.max_events_per_second {
    True -> #(state, True)
    False -> #(ConnectionState(..state, event_count: new_count), False)
  }
}

/// Start a new rate window if the current one has elapsed, resetting the
/// event budget and forgiving earlier violations.
fn roll_rate_window(state: ConnectionState) -> ConnectionState {
  let now = ws.get_now_ms()
  case now - state.rate_window_start >= rate_window_ms {
    True ->
      ConnectionState(
        ..state,
        event_count: 0,
        rate_window_start: now,
        rate_violations: 0,
      )
    False -> state
  }
}

/// Check heartbeat rate limit: max 2 per second.
/// Returns the updated state and whether the heartbeat was rate limited.
fn check_heartbeat_rate(state: ConnectionState) -> #(ConnectionState, Bool) {
  let now = ws.get_now_ms()
  let #(count, window_start) = case
    now - state.heartbeat_window_start >= rate_window_ms
  {
    True -> #(0, now)
    False -> #(state.heartbeat_count, state.heartbeat_window_start)
  }
  let new_count = count + 1
  let new_state =
    ConnectionState(
      ..state,
      heartbeat_count: new_count,
      heartbeat_window_start: window_start,
    )
  #(new_state, new_count > max_heartbeats_per_second)
}

/// Record one rate limit violation. Too many within a window closes the
/// connection with 1008; otherwise `reply` (if any) is sent as an error.
fn record_rate_violation(
  state: ConnectionState,
  description: String,
  reply: Option(String),
) -> Next {
  // Roll the window here too, so violations that are not events (heartbeat
  // floods, oversized batches) are also forgiven once a window passes.
  let state = roll_rate_window(state)
  let violations = state.rate_violations + 1
  let state = ConnectionState(..state, rate_violations: violations)
  let max = state.security_limits.ws_max_rate_violations
  case violations > max {
    True -> {
      log.warning(
        "beacon.transport",
        "Closing abusive connection "
          <> ctx(state)
          <> ": "
          <> int.to_string(violations)
          <> " rate limit violations (max "
          <> int.to_string(max)
          <> "), last: "
          <> description,
      )
      Stop(
        state,
        SendClose(ws.close_policy_violation, "rate limit exceeded"),
        "rate limit violations exceeded",
      )
    }
    False -> {
      log.warning(
        "beacon.transport",
        "Rate limit violation from "
          <> ctx(state)
          <> " ("
          <> int.to_string(violations)
          <> "/"
          <> int.to_string(max)
          <> "): "
          <> description,
      )
      case reply {
        Some(reason) -> send_or_stop(state, ServerError(reason: reason))
        None -> Continue(state)
      }
    }
  }
}

/// Record one undecodable message. The raw text is never logged or echoed
/// (it may carry user data); only its size is.
fn record_decode_error(state: ConnectionState, size: Int) -> Next {
  let errors = state.decode_errors + 1
  let state = ConnectionState(..state, decode_errors: errors)
  let max = state.security_limits.ws_max_decode_errors
  log.warning(
    "beacon.transport",
    "Undecodable message from "
      <> ctx(state)
      <> " ("
      <> int.to_string(size)
      <> " bytes, "
      <> int.to_string(errors)
      <> "/"
      <> int.to_string(max)
      <> ")",
  )
  case errors > max {
    True -> {
      log.warning(
        "beacon.transport",
        "Closing connection "
          <> ctx(state)
          <> " after repeated invalid messages",
      )
      Stop(
        state,
        SendClose(ws.close_policy_violation, "too many invalid messages"),
        "decode errors exceeded",
      )
    }
    False -> send_or_stop(state, ServerError(reason: "Invalid message"))
  }
}

/// Handle a complete text message. Size is already bounded by the frame
/// layer (`max_message_bytes`). Any text message counts as activity.
fn handle_ws_text(state: ConnectionState, text: String) -> Next {
  let state = ConnectionState(..state, last_activity_ms: ws.get_now_ms())
  handle_ws_text_decode(state, text)
}

/// Decode and dispatch a text message, applying heartbeat and event rate
/// limits (each event of a batch counts) and decode error accounting.
fn handle_ws_text_decode(state: ConnectionState, text: String) -> Next {
  case decode_client_message(text) {
    Ok(ClientHeartbeat) -> {
      let #(new_state, hb_limited) = check_heartbeat_rate(state)
      case hb_limited {
        True -> record_rate_violation(new_state, "heartbeat flood", None)
        False -> {
          log.debug("beacon.transport", "Heartbeat from " <> state.id)
          send_or_stop(new_state, ServerHeartbeatAck)
        }
      }
    }
    Ok(ClientEventBatch(events) as msg) -> {
      let batch_len = list.length(events)
      case batch_len > max_batch_size {
        True ->
          record_rate_violation(
            state,
            "batch of "
              <> int.to_string(batch_len)
              <> " events (max "
              <> int.to_string(max_batch_size)
              <> ")",
            Some("Batch too large"),
          )
        False -> dispatch_rate_limited(state, msg, int.max(batch_len, 1))
      }
    }
    Ok(msg) -> dispatch_rate_limited(state, msg, 1)
    Error(_codec_error) -> record_decode_error(state, string.byte_size(text))
  }
}

/// Dispatch a decoded message if the rate limit allows `cost` more events.
fn dispatch_rate_limited(
  state: ConnectionState,
  msg: ClientMessage,
  cost: Int,
) -> Next {
  let #(new_state, rate_limited) = check_rate_limit(state, cost)
  case rate_limited {
    True ->
      record_rate_violation(
        new_state,
        "rate limited "
          <> client_message_type(msg)
          <> " ("
          <> int.to_string(cost)
          <> " events, "
          <> int.to_string(new_state.event_count)
          <> " already this second)",
        Some("Rate limited"),
      )
    False -> {
      log.debug(
        "beacon.transport",
        "Event from " <> new_state.id <> ": " <> client_message_type(msg),
      )
      new_state.on_event(new_state.id, msg)
      Continue(new_state)
    }
  }
}

// --- Connection loop ---

/// Everything the connection process can receive.
type LoopEvent {
  FromRuntime(InternalMessage)
  FromTimer(WsTimer)
  FromSocket(ws.SocketEvent)
}

/// Outcome of handling one event.
type Next {
  Continue(ConnectionState)
  /// Stop the connection: send `action`, close the socket, clean up.
  /// `reason` is for the log.
  Stop(state: ConnectionState, action: CloseAction, reason: String)
}

/// What to put on the wire before closing the socket.
type CloseAction {
  /// Send a close frame with this code and short reason.
  SendClose(code: Int, reason: String)
  /// Answer a peer close by echoing its code (empty close when it had none).
  EchoClose(code: Option(Int))
  /// The socket is already dead (peer closed, send failed): send nothing.
  NoCloseFrame
}

/// Short, constant close reason for a protocol error (sent to the peer).
fn protocol_close_reason(error: ws.ProtocolError) -> String {
  case ws.get_protocol_close_code(error) {
    1009 -> "message too big"
    1007 -> "invalid utf-8"
    _ -> "protocol error"
  }
}

/// Decode and handle every complete frame in `buffer`.
fn process_frames(state: ConnectionState, buffer: BitArray) -> Next {
  case
    ws.decode_next(
      buffer,
      state.reassembly,
      state.security_limits.max_message_bytes,
    )
  {
    Error(error) -> {
      log.warning(
        "beacon.transport",
        "WebSocket protocol error from "
          <> ctx(state)
          <> ": "
          <> ws.get_protocol_error_reason(error),
      )
      Stop(
        state,
        SendClose(
          ws.get_protocol_close_code(error),
          protocol_close_reason(error),
        ),
        "protocol error: " <> ws.get_protocol_error_reason(error),
      )
    }
    Ok(ws.Incomplete) -> Continue(ConnectionState(..state, buffer: buffer))
    Ok(ws.Fragment(rest: rest, reassembly: reassembly)) ->
      process_frames(ConnectionState(..state, reassembly: reassembly), rest)
    Ok(ws.Complete(message: message, rest: rest, reassembly: reassembly)) ->
      case
        handle_ws_message(
          ConnectionState(..state, reassembly: reassembly),
          message,
        )
      {
        Continue(new_state) -> process_frames(new_state, rest)
        stop -> stop
      }
  }
}

/// Handle one complete, validated WebSocket message.
fn handle_ws_message(state: ConnectionState, message: ws.Message) -> Next {
  case message {
    ws.TextMessage(text) -> handle_ws_text(state, text)
    ws.BinaryMessage(data) -> {
      log.warning(
        "beacon.transport",
        "Binary message from "
          <> ctx(state)
          <> " ("
          <> int.to_string(bit_array.byte_size(data))
          <> " bytes) — Beacon only accepts text",
      )
      Stop(
        state,
        SendClose(ws.close_unsupported_data, "binary messages not supported"),
        "binary message",
      )
    }
    ws.CloseMessage(code: code, reason: _) -> {
      let code_text = case code {
        Some(c) -> int.to_string(c)
        None -> "none"
      }
      log.info(
        "beacon.transport",
        "Close frame from " <> ctx(state) <> " (code " <> code_text <> ")",
      )
      Stop(state, EchoClose(code), "peer sent close")
    }
    ws.PingMessage(payload) ->
      send_frame_or_stop(state, ws.encode_pong(payload), "pong")
    ws.PongMessage(payload) -> handle_pong(state, payload)
  }
}

fn ping_payload(seq: Int) -> BitArray {
  <<int.to_string(seq):utf8>>
}

/// A pong carrying the outstanding ping's payload clears the deadline.
/// Unsolicited pongs are allowed (RFC 6455 §5.5.3) and ignored.
fn handle_pong(state: ConnectionState, payload: BitArray) -> Next {
  case state.pending_ping {
    Some(seq) ->
      case payload == ping_payload(seq) {
        True -> {
          cancel_timer(state.pong_timer)
          log.debug("beacon.transport", "Pong from " <> state.id)
          Continue(
            ConnectionState(..state, pending_ping: None, pong_timer: None),
          )
        }
        False -> {
          log.debug(
            "beacon.transport",
            "Pong with stale payload from " <> state.id,
          )
          Continue(state)
        }
      }
    None -> {
      log.debug("beacon.transport", "Unsolicited pong from " <> state.id)
      Continue(state)
    }
  }
}

fn cancel_timer(timer: Option(process.Timer)) -> Nil {
  case timer {
    Some(t) ->
      case process.cancel_timer(t) {
        process.Cancelled(_) -> Nil
        // Already fired; the message (if still queued) is discarded with
        // the process, or ignored by its sequence/state guard.
        process.TimerNotFound -> Nil
      }
    None -> Nil
  }
}

/// Handle a timer the connection scheduled for itself.
fn handle_timer(state: ConnectionState, timer: WsTimer) -> Next {
  case timer {
    PingTick -> send_ping(state)
    PongDeadline(seq) ->
      case state.pending_ping == Some(seq) {
        True -> {
          log.warning(
            "beacon.transport",
            "No pong from "
              <> ctx(state)
              <> " within "
              <> int.to_string(state.security_limits.ws_pong_timeout_ms)
              <> "ms",
          )
          Stop(
            state,
            SendClose(ws.close_normal, "pong timeout"),
            "pong timeout",
          )
        }
        False -> Continue(state)
      }
    IdleCheck -> check_idle(state)
    AuthRecheck -> recheck_auth(state)
  }
}

/// Send the next ping unless one is still outstanding (its deadline is
/// already armed), and reschedule.
fn send_ping(state: ConnectionState) -> Next {
  let limits = state.security_limits
  let ping_timer =
    Some(process.send_after(
      state.timer_subject,
      limits.ws_ping_interval_ms,
      PingTick,
    ))
  let state = ConnectionState(..state, ping_timer: ping_timer)
  case state.pending_ping {
    Some(_) -> Continue(state)
    None -> {
      let seq = state.ping_seq + 1
      case
        send_frame_or_stop(state, ws.encode_ping(ping_payload(seq)), "ping")
      {
        Continue(sent_state) ->
          Continue(
            ConnectionState(
              ..sent_state,
              ping_seq: seq,
              pending_ping: Some(seq),
              pong_timer: Some(process.send_after(
                state.timer_subject,
                limits.ws_pong_timeout_ms,
                PongDeadline(seq),
              )),
            ),
          )
        stop -> stop
      }
    }
  }
}

/// Close the connection when no application message arrived within the
/// idle timeout; otherwise re-arm for the remaining time.
fn check_idle(state: ConnectionState) -> Next {
  let timeout = state.security_limits.ws_idle_timeout_ms
  let idle_for = ws.get_now_ms() - state.last_activity_ms
  case idle_for >= timeout {
    True -> {
      log.info(
        "beacon.transport",
        "Connection "
          <> ctx(state)
          <> " idle for "
          <> int.to_string(idle_for)
          <> "ms",
      )
      Stop(state, SendClose(ws.close_normal, "idle timeout"), "idle timeout")
    }
    False ->
      Continue(
        ConnectionState(
          ..state,
          idle_timer: Some(process.send_after(
            state.timer_subject,
            timeout - idle_for,
            IdleCheck,
          )),
        ),
      )
  }
}

/// Re-run `ws_auth` against the original upgrade request. A session that
/// was logged out, rotated or expired since the upgrade closes with 4401.
fn recheck_auth(state: ConnectionState) -> Next {
  case state.ws_auth {
    None -> {
      log.error(
        "beacon.transport",
        "Auth re-check fired without ws_auth for " <> ctx(state),
      )
      Stop(
        state,
        SendClose(ws.close_internal_error, "internal error"),
        "auth re-check without ws_auth",
      )
    }
    Some(auth_fn) ->
      case auth_fn(state.request) {
        Ok(Nil) -> {
          log.debug("beacon.transport", "Auth re-check passed for " <> state.id)
          Continue(
            ConnectionState(
              ..state,
              auth_timer: Some(process.send_after(
                state.timer_subject,
                state.security_limits.ws_auth_recheck_interval_ms,
                AuthRecheck,
              )),
            ),
          )
        }
        Error(reason) -> {
          log.warning(
            "beacon.transport",
            "Auth re-check failed for " <> ctx(state) <> ": " <> reason,
          )
          Stop(
            state,
            SendClose(ws.close_auth_revoked, "authentication expired"),
            "auth re-check failed",
          )
        }
      }
  }
}

/// Handle a raw socket-level (or session revocation) event.
fn handle_socket_event(state: ConnectionState, event: ws.SocketEvent) -> Next {
  case event {
    ws.SocketData(data) -> {
      let buffer = bit_array.append(state.buffer, data)
      case process_frames(ConnectionState(..state, buffer: <<>>), buffer) {
        Continue(new_state) -> {
          server.set_active_once(new_state.socket)
          Continue(new_state)
        }
        stop -> stop
      }
    }
    ws.SocketClosed -> Stop(state, NoCloseFrame, "peer closed TCP connection")
    ws.SocketError(reason) -> {
      log.warning(
        "beacon.transport",
        "TCP error for " <> ctx(state) <> ": " <> reason,
      )
      Stop(state, NoCloseFrame, "TCP error: " <> reason)
    }
    ws.SessionRevoked(session_id: _, reason: reason) -> {
      log.warning(
        "beacon.transport",
        "Session behind " <> ctx(state) <> " was " <> reason,
      )
      Stop(
        state,
        SendClose(ws.close_auth_revoked, "session revoked"),
        "session " <> reason,
      )
    }
    ws.UnexpectedMessage(description) -> {
      log.error(
        "beacon.transport",
        "Unexpected message in connection "
          <> ctx(state)
          <> ": "
          <> string.slice(description, 0, 200),
      )
      Stop(
        state,
        SendClose(ws.close_internal_error, "internal error"),
        "unexpected process message",
      )
    }
  }
}

/// Handle a message from the runtime. A mailbox deeper than
/// `ws_max_outbound_queue` means the client cannot keep up: close with 1013
/// rather than buffer without bound.
fn handle_runtime_message(
  state: ConnectionState,
  message: InternalMessage,
) -> Next {
  let queued = ws.get_mailbox_len()
  let max = state.security_limits.ws_max_outbound_queue
  case queued > max {
    True -> {
      log.warning(
        "beacon.transport",
        "Outbound queue for "
          <> ctx(state)
          <> " has "
          <> int.to_string(queued)
          <> " messages (max "
          <> int.to_string(max)
          <> ")",
      )
      Stop(
        state,
        SendClose(ws.close_try_again_later, "server overloaded"),
        "outbound queue full",
      )
    }
    False ->
      case message {
        SendMount(payload) -> send_or_stop(state, ServerMount(payload: payload))
        SendError(reason) -> send_or_stop(state, ServerError(reason: reason))
        SendModelSync(model_json, version, ack_clock) ->
          send_or_stop(
            state,
            ServerModelSync(
              model_json: model_json,
              version: version,
              ack_clock: ack_clock,
            ),
          )
        SendPatch(ops_json, version, ack_clock) ->
          send_or_stop(
            state,
            ServerPatch(
              ops_json: ops_json,
              version: version,
              ack_clock: ack_clock,
            ),
          )
        SendNavigate(path) -> send_or_stop(state, ServerNavigate(path: path))
        SendHardNavigate(path) ->
          send_or_stop(state, ServerHardNavigate(path: path))
        CloseForBackpressure(reason) -> {
          log.warning(
            "beacon.transport",
            "Closing slow connection " <> ctx(state) <> ": " <> reason,
          )
          case send_ws_message(state, ServerError(reason: reason)) {
            Ok(Nil) ->
              Stop(
                state,
                SendClose(ws.close_try_again_later, "backpressure"),
                "backpressure: " <> reason,
              )
            Error(send_reason) ->
              Stop(state, NoCloseFrame, "send failed: " <> send_reason)
          }
        }
        ReceivedTcpData(data) -> handle_socket_event(state, ws.SocketData(data))
        TcpConnectionClosed -> handle_socket_event(state, ws.SocketClosed)
        TcpConnectionError(reason) ->
          handle_socket_event(state, ws.SocketError(reason))
      }
  }
}

// --- WebSocket Connection Lifecycle ---

/// Release everything the connection holds: timers, the per-IP slot, the
/// global connection count, and the runtime (via `on_close`).
fn cleanup_connection(state: ConnectionState) -> Nil {
  log.info("beacon.transport", "Connection closed (cleanup): " <> ctx(state))
  cancel_timer(state.ping_timer)
  cancel_timer(state.pong_timer)
  cancel_timer(state.idle_timer)
  cancel_timer(state.auth_timer)
  ws.release_ip_slot(state.slot_key)
  let conn_count = connection_tracker_decrement()
  log.debug(
    "beacon.transport",
    "Global connections after close: " <> int.to_string(conn_count),
  )
  state.on_close(state.id)
}

/// Put the close action on the wire, close the socket, clean up.
fn stop_connection(
  state: ConnectionState,
  action: CloseAction,
  reason: String,
) -> Nil {
  log.info(
    "beacon.transport",
    "Closing WebSocket " <> ctx(state) <> ": " <> reason,
  )
  let frame = case action {
    SendClose(code: code, reason: close_reason) ->
      Some(ws.encode_close(code, close_reason))
    EchoClose(code: Some(code)) -> Some(ws.encode_close(code, ""))
    EchoClose(code: None) -> Some(ws.encode_empty_close())
    NoCloseFrame -> None
  }
  case frame {
    Some(bytes) ->
      case server.send_bytes(state.socket, bytes) {
        Ok(Nil) -> Nil
        Error(send_reason) ->
          log.warning(
            "beacon.transport",
            "Failed to send close frame to "
              <> ctx(state)
              <> ": "
              <> send_reason,
          )
      }
    None -> Nil
  }
  server.close(state.socket)
  cleanup_connection(state)
}

/// WebSocket receive loop — runs in the handler process.
/// Receives runtime messages, its own timers and socket events.
/// Returns only after the connection has been closed and cleaned up.
fn ws_loop(
  state: ConnectionState,
  subject: process.Subject(InternalMessage),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(subject, FromRuntime)
    |> process.select_map(state.timer_subject, FromTimer)
    |> process.select_other(fn(raw: Dynamic) {
      FromSocket(ws.decode_socket_event(raw))
    })
  ws_loop_inner(state, selector)
}

/// Inner loop with cached selector.
fn ws_loop_inner(
  state: ConnectionState,
  selector: process.Selector(LoopEvent),
) -> Nil {
  let next = case process.selector_receive_forever(selector) {
    FromSocket(event) -> handle_socket_event(state, event)
    FromTimer(timer) -> handle_timer(state, timer)
    FromRuntime(message) -> handle_runtime_message(state, message)
  }
  case next {
    Continue(new_state) -> ws_loop_inner(new_state, selector)
    Stop(state: final_state, action: action, reason: reason) ->
      stop_connection(final_state, action, reason)
  }
}

/// Identity of an admitted connection, carried from admission to startup.
type Admission {
  Admission(conn_id: ConnectionId, peer_ip: String, slot_key: String)
}

/// Start a WebSocket connection on an already-upgraded socket.
/// Starts the runtime, arms liveness timers, and enters the frame loop.
/// Runs in the handler process and returns when the connection ends.
fn start_ws_connection(
  socket: Socket,
  config: TransportConfig,
  req: Request(Connection),
  admission: Admission,
) -> Nil {
  let conn_id = admission.conn_id
  log.info(
    "beacon.transport",
    "New connection: " <> conn_id <> " (peer " <> admission.peer_ip <> ")",
  )

  let subject = process.new_subject()

  // Use runtime_factory if available (per-connection runtimes)
  // Otherwise use shared callbacks
  let handlers = case config.runtime_factory {
    Some(factory) -> factory(conn_id, subject, req)
    None -> {
      config.on_connect(conn_id, subject)
      Ok(#(config.on_event, config.on_disconnect))
    }
  }

  case handlers {
    Ok(#(conn_on_event, conn_on_close)) -> {
      let limits = config.security_limits
      let timer_subject = process.new_subject()
      let now = ws.get_now_ms()
      let auth_timer = case config.ws_auth {
        Some(_) ->
          Some(process.send_after(
            timer_subject,
            limits.ws_auth_recheck_interval_ms,
            AuthRecheck,
          ))
        None -> None
      }
      let state =
        ConnectionState(
          id: conn_id,
          socket: socket,
          on_event: conn_on_event,
          on_close: conn_on_close,
          event_count: 0,
          rate_window_start: now,
          security_limits: limits,
          heartbeat_count: 0,
          heartbeat_window_start: now,
          buffer: <<>>,
          reassembly: ws.create_reassembly(),
          peer_ip: admission.peer_ip,
          slot_key: admission.slot_key,
          request: req,
          ws_auth: config.ws_auth,
          last_activity_ms: now,
          ping_seq: 0,
          pending_ping: None,
          decode_errors: 0,
          rate_violations: 0,
          timer_subject: timer_subject,
          ping_timer: Some(process.send_after(
            timer_subject,
            limits.ws_ping_interval_ms,
            PingTick,
          )),
          pong_timer: None,
          idle_timer: Some(process.send_after(
            timer_subject,
            limits.ws_idle_timeout_ms,
            IdleCheck,
          )),
          auth_timer: auth_timer,
        )

      // Start receiving TCP data
      server.set_active_once(socket)

      // Enter the receive loop — returns after close and cleanup
      ws_loop(state, subject)
    }
    Error(reason) -> {
      log.error(
        "beacon.transport",
        "Closing WebSocket after runtime startup failure for "
          <> conn_id
          <> " (peer "
          <> admission.peer_ip
          <> "): "
          <> reason,
      )
      case
        server.send_bytes(
          socket,
          ws.encode_close(ws.close_internal_error, "startup failure"),
        )
      {
        Ok(Nil) -> Nil
        Error(send_reason) ->
          log.warning(
            "beacon.transport",
            "Failed to send close frame after startup failure for "
              <> conn_id
              <> ": "
              <> send_reason,
          )
      }
      server.close(socket)
      ws.release_ip_slot(admission.slot_key)
      let conn_count = connection_tracker_decrement()
      log.debug(
        "beacon.transport",
        "Global connections after failed startup close: "
          <> int.to_string(conn_count),
      )
    }
  }
}

// --- WebSocket Upgrade Validation ---

/// A parsed web origin (RFC 6454): scheme, host and effective port.
type Origin {
  Origin(scheme: String, host: String, port: Int, has_path: Bool)
}

fn default_port(scheme: String) -> Result(Int, String) {
  case scheme {
    "http" -> Ok(80)
    "https" -> Ok(443)
    other -> Error("unsupported scheme \"" <> other <> "\"")
  }
}

/// Parse an Origin header value: `scheme://host[:port]`. A trailing path is
/// tolerated (some legacy clients send one) but recorded. `null`, userinfo
/// and anything outside http/https are rejected.
fn parse_origin(value: String) -> Result(Origin, String) {
  case string.split_once(string.trim(value), "://") {
    Error(Nil) -> Error("origin has no scheme")
    Ok(#(raw_scheme, rest)) -> {
      let scheme = string.lowercase(raw_scheme)
      use port <- result.try(default_port(scheme))
      let #(authority, has_path) = case string.split_once(rest, "/") {
        Ok(#(authority, _path)) -> #(authority, True)
        Error(Nil) -> #(rest, False)
      }
      use #(host, port) <- result.try(parse_authority(authority, port))
      Ok(Origin(scheme: scheme, host: host, port: port, has_path: has_path))
    }
  }
}

/// Parse `host[:port]` (IPv6 hosts in brackets). Host is lowercased.
fn parse_authority(
  authority: String,
  default: Int,
) -> Result(#(String, Int), String) {
  let forbidden = ["@", "?", "#", " ", "\\", "\t"]
  case list.any(forbidden, fn(c) { string.contains(authority, c) }) {
    True -> Error("invalid characters in host")
    False ->
      case authority {
        "" -> Error("empty host")
        "[" <> ipv6_rest ->
          case string.split_once(ipv6_rest, "]") {
            Ok(#("", _)) -> Error("empty IPv6 host")
            Ok(#(address, "")) ->
              Ok(#("[" <> string.lowercase(address) <> "]", default))
            Ok(#(address, ":" <> port_text)) -> {
              use port <- result.try(parse_port(port_text))
              Ok(#("[" <> string.lowercase(address) <> "]", port))
            }
            _ -> Error("malformed IPv6 host")
          }
        _ ->
          case string.split(authority, ":") {
            [""] | ["", _] -> Error("empty host")
            [host] -> Ok(#(string.lowercase(host), default))
            [host, port_text] -> {
              use port <- result.try(parse_port(port_text))
              Ok(#(string.lowercase(host), port))
            }
            _ -> Error("malformed host")
          }
      }
  }
}

fn parse_port(text: String) -> Result(Int, String) {
  case int.parse(text) {
    Ok(port) if port >= 1 && port <= 65_535 -> Ok(port)
    _ -> Error("invalid port \"" <> text <> "\"")
  }
}

/// The scheme the client used to reach us: the first X-Forwarded-Proto
/// token when a proxy set one, otherwise plain http (Beacon itself does not
/// terminate TLS).
fn request_scheme(req: Request(Connection)) -> Result(String, String) {
  case request.get_header(req, "x-forwarded-proto") {
    Error(Nil) -> Ok("http")
    Ok(value) -> {
      let first = case string.split(value, ",") {
        [token, ..] -> string.lowercase(string.trim(token))
        [] -> ""
      }
      case first {
        "http" | "https" -> Ok(first)
        _ -> Error("invalid X-Forwarded-Proto \"" <> value <> "\"")
      }
    }
  }
}

/// Check that the Origin header matches the server's own origin (scheme,
/// host and port) or an entry of `ws_allowed_origins`.
/// This prevents cross-site WebSocket hijacking (CSWSH).
///
/// SECURITY: Origin validation is the primary CSRF defense for WebSocket connections.
fn check_origin(
  req: Request(Connection),
  limits: SecurityLimits,
) -> Result(Nil, String) {
  case request.get_header(req, "origin") {
    Error(Nil) -> {
      log.warning(
        "beacon.transport",
        "Missing Origin header on WebSocket upgrade",
      )
      Error("Missing Origin header")
    }
    Ok(origin) -> {
      let request_host = case request.get_header(req, "host") {
        Ok(h) -> h
        Error(Nil) -> ""
      }
      case request_scheme(req) {
        Error(reason) -> {
          log.warning("beacon.transport", "Origin check failed: " <> reason)
          Error(reason)
        }
        Ok(scheme) ->
          origin_allowed(
            origin,
            scheme,
            request_host,
            limits.ws_allowed_origins,
          )
      }
    }
  }
}

/// Validate an Origin header against the request's own origin
/// (`request_scheme` + Host header, default ports applied) and an explicit
/// allow-list of origins. Scheme, host and port must all match.
pub fn origin_allowed(
  origin: String,
  request_scheme: String,
  request_host: String,
  allowed_origins: List(String),
) -> Result(Nil, String) {
  let decision = {
    use parsed <- result.try(
      parse_origin(origin)
      |> result.map_error(fn(reason) { "invalid Origin: " <> reason }),
    )
    let same = Origin(..parsed, has_path: False)
    let allow_listed =
      list.any(allowed_origins, fn(allowed) {
        case parse_origin(allowed) {
          Ok(entry) -> Origin(..entry, has_path: False) == same
          Error(_) -> False
        }
      })
    case allow_listed {
      True -> Ok(Nil)
      False -> {
        use port <- result.try(default_port(string.lowercase(request_scheme)))
        use #(host, port) <- result.try(
          parse_authority(string.trim(request_host), port)
          |> result.map_error(fn(reason) { "invalid Host: " <> reason }),
        )
        let own =
          Origin(
            scheme: string.lowercase(request_scheme),
            host: host,
            port: port,
            has_path: False,
          )
        case own == same {
          True -> Ok(Nil)
          False -> Error("Origin mismatch")
        }
      }
    }
  }
  case decision {
    Ok(Nil) -> {
      log.debug("beacon.transport", "Origin allowed: " <> origin)
      Ok(Nil)
    }
    Error(reason) -> {
      log.warning(
        "beacon.transport",
        "Origin rejected ("
          <> reason
          <> "): origin="
          <> origin
          <> " scheme="
          <> request_scheme
          <> " host="
          <> request_host,
      )
      Error(reason)
    }
  }
}

/// Validate that an Origin header value belongs to the request Host over
/// plain http. Empty origins, empty hosts, scheme-less values and
/// scheme/host/port mismatches reject.
pub fn origin_allowed_for_host(
  origin: String,
  request_host: String,
) -> Result(Nil, String) {
  log.debug("beacon.transport", "Checking origin against host " <> request_host)
  origin_allowed(origin, "http", request_host, [])
}

/// Handle a WebSocket upgrade request on a raw socket.
/// Admission order: limits sanity, global cap, per-IP cap, origin, auth,
/// then RFC 6455 handshake validation. Every rejection is logged with the
/// connection id and peer address and releases what was acquired.
fn handle_ws_request(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
) -> Nil {
  let conn_id = generate_connection_id()
  let limits = config.security_limits
  case validate_security_limits(limits), ws.peer_ip(socket) {
    Error(reason), _ ->
      reject_ws_request(
        socket,
        conn_id,
        "unknown",
        None,
        500,
        "Server misconfigured",
        "invalid security limits: " <> reason,
      )
    Ok(Nil), Error(reason) -> {
      // The peer is already gone: nobody to answer.
      log.warning(
        "beacon.transport",
        "WebSocket upgrade " <> conn_id <> " dropped: " <> reason,
      )
      server.close(socket)
      let _count = connection_tracker_decrement()
      Nil
    }
    Ok(Nil), Ok(peer_ip) ->
      admit_ws_request(socket, req, config, conn_id, peer_ip)
  }
}

fn admit_ws_request(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
  conn_id: ConnectionId,
  peer_ip: String,
) -> Nil {
  let limits = config.security_limits
  let current_count = connection_tracker_count()
  case current_count > limits.max_connections {
    True ->
      reject_ws_request(
        socket,
        conn_id,
        peer_ip,
        None,
        503,
        "Too many connections",
        "global connection limit reached ("
          <> int.to_string(current_count)
          <> "/"
          <> int.to_string(limits.max_connections)
          <> ")",
      )
    False -> {
      let slot_key = int.to_string(config.port) <> "|" <> peer_ip
      case ws.acquire_ip_slot(slot_key, limits.max_ws_connections_per_ip) {
        Error(count) ->
          reject_ws_request(
            socket,
            conn_id,
            peer_ip,
            None,
            429,
            "Too many connections from this address",
            "per-IP WebSocket limit reached (" <> int.to_string(count) <> ")",
          )
        Ok(_count) ->
          authorize_ws_request(
            socket,
            req,
            config,
            Admission(conn_id: conn_id, peer_ip: peer_ip, slot_key: slot_key),
          )
      }
    }
  }
}

fn authorize_ws_request(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
  admission: Admission,
) -> Nil {
  let reject = fn(status, body, reason) {
    reject_ws_request(
      socket,
      admission.conn_id,
      admission.peer_ip,
      Some(admission.slot_key),
      status,
      body,
      reason,
    )
  }
  case check_origin(req, config.security_limits) {
    Error(reason) -> reject(403, "Forbidden: " <> reason, "origin: " <> reason)
    Ok(Nil) -> {
      let auth_ok = case config.ws_auth {
        Some(auth_fn) -> auth_fn(req)
        None -> Ok(Nil)
      }
      case auth_ok {
        Error(reason) ->
          reject(401, "Unauthorized: " <> reason, "ws_auth: " <> reason)
        Ok(Nil) ->
          case ws.validate_upgrade(req) {
            Error(error) -> {
              let description = ws.get_upgrade_error_reason(error)
              case ws.get_upgrade_error_status(error) {
                426 ->
                  reject_unsupported_version(socket, admission, description)
                status ->
                  reject(status, description, "handshake: " <> description)
              }
            }
            Ok(client_key) ->
              upgrade_ws_request(socket, req, config, admission, client_key)
          }
      }
    }
  }
}

fn upgrade_ws_request(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
  admission: Admission,
  client_key: String,
) -> Nil {
  let upgraded = {
    use _ <- result.try(ws.set_send_timeout(
      socket,
      config.security_limits.ws_send_timeout_ms,
    ))
    ws.send_upgrade_response(socket, client_key)
  }
  case upgraded {
    Ok(Nil) -> start_ws_connection(socket, config, req, admission)
    Error(reason) -> {
      log.warning(
        "beacon.transport",
        "WebSocket upgrade failed for "
          <> admission.conn_id
          <> " (peer "
          <> admission.peer_ip
          <> "): "
          <> reason,
      )
      server.close(socket)
      ws.release_ip_slot(admission.slot_key)
      let _count = connection_tracker_decrement()
      Nil
    }
  }
}

/// 426 Upgrade Required must advertise the supported version (§4.4).
fn reject_unsupported_version(
  socket: Socket,
  admission: Admission,
  description: String,
) -> Nil {
  log.warning(
    "beacon.transport",
    "WebSocket upgrade rejected for "
      <> admission.conn_id
      <> " (peer "
      <> admission.peer_ip
      <> ") status 426: "
      <> description,
  )
  ws.release_ip_slot(admission.slot_key)
  let _count = connection_tracker_decrement()
  let resp =
    response.new(426)
    |> response.set_header("sec-websocket-version", "13")
    |> response.set_body(Bytes(bytes_tree.from_string(description)))
  case transport_http.write_response(socket, resp) {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.warning(
        "beacon.transport",
        "Failed to write 426 response for "
          <> admission.conn_id
          <> ": "
          <> reason,
      )
  }
  server.close(socket)
}

/// Reject an upgrade: log with context, release the per-IP slot (if one
/// was taken) and the global count, answer with an HTTP error and close.
fn reject_ws_request(
  socket: Socket,
  conn_id: ConnectionId,
  peer_ip: String,
  slot_key: Option(String),
  status: Int,
  body: String,
  reason: String,
) -> Nil {
  log.warning(
    "beacon.transport",
    "WebSocket upgrade rejected for "
      <> conn_id
      <> " (peer "
      <> peer_ip
      <> ") status "
      <> int.to_string(status)
      <> ": "
      <> reason,
  )
  case slot_key {
    Some(key) -> ws.release_ip_slot(key)
    None -> Nil
  }
  let _count = connection_tracker_decrement()
  transport_http.write_error(socket, status, body)
}

// --- HTTP Handler ---

/// Create the HTTP handler for non-WebSocket requests.
/// Handles: API routes, static files, client JS, health check, SSR pages.
/// API handler runs first — if it returns Some(response), that's used.
/// Otherwise falls through to static files, beacon_client.js, health, SSR.
pub fn create_handler(
  config: TransportConfig,
) -> fn(Request(Connection)) -> response.Response(ResponseBody) {
  let core_handler = fn(req: Request(Connection)) {
    // Try API handler first — user-defined routes take priority
    case try_api_handler(config.api_handler, req) {
      Some(resp) -> resp
      None -> route_framework_request(config, req)
    }
  }
  case config.middlewares {
    [] -> core_handler
    mws -> middleware.pipeline(mws, core_handler)
  }
}

/// Try the API handler if configured. Returns Some(response) if handled, None to fall through.
fn try_api_handler(
  api_handler: Option(
    fn(Request(Connection)) -> Option(response.Response(ResponseBody)),
  ),
  req: Request(Connection),
) -> Option(response.Response(ResponseBody)) {
  case api_handler {
    Some(handler) -> handler(req)
    None -> None
  }
}

/// Route a request through framework handlers: beacon_client.js, health, static, SSR.
fn route_framework_request(
  config: TransportConfig,
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  case request.path_segments(req) {
    ["beacon_client.js"] -> serve_client_js(req)
    ["health"] -> {
      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(Bytes(bytes_tree.from_string("{\"status\":\"ok\"}")))
    }
    _ -> {
      let path = req.path
      case
        string.starts_with(path, "/beacon_client_")
        && string.ends_with(path, ".js")
      {
        True -> {
          let name = string.drop_start(path, 1)
          serve_hashed_client_js(name, req)
        }
        False -> {
          case config.static_config {
            Some(static_cfg) -> {
              let if_none_match = case
                request.get_header(req, "if-none-match")
              {
                Ok(val) -> val
                Error(Nil) -> ""
              }
              case
                static.serve_with_etag_check(
                  static_cfg,
                  req.path,
                  if_none_match,
                )
              {
                Ok(resp) -> resp
                Error(Nil) ->
                  serve_page_or_ssr(config.page_html, config.ssr_factory, req)
              }
            }
            None -> serve_page_or_ssr(config.page_html, config.ssr_factory, req)
          }
        }
      }
    }
  }
}

// --- Per-Connection Handler ---

/// Handle a single TCP connection: read HTTP request, route to WS or HTTP handler.
/// Middleware runs on ALL requests, including /ws, before routing.
fn per_connection_handler(socket: Socket, config: TransportConfig) -> Nil {
  let conn_count = connection_tracker_increment()
  case conn_count > config.security_limits.max_connections {
    True -> {
      log.warning(
        "beacon.transport",
        "Global connection limit reached ("
          <> int.to_string(conn_count)
          <> "/"
          <> int.to_string(config.security_limits.max_connections)
          <> ") — rejecting pre-upgrade connection",
      )
      let _ = connection_tracker_decrement()
      transport_http.write_error(socket, 503, "Too many connections")
    }
    False -> {
      log.debug(
        "beacon.transport",
        "Global connections after accept: " <> int.to_string(conn_count),
      )
      case
        transport_http.read_request_with_limits(
          socket,
          config.security_limits.max_http_headers,
          config.security_limits.max_http_header_bytes,
          config.security_limits.pre_upgrade_timeout_ms,
        )
      {
        Ok(req) -> {
          case request.path_segments(req) {
            ["ws"] -> {
              case check_middleware(req, config.middlewares) {
                Ok(Nil) -> handle_ws_request(socket, req, config)
                Error(resp) -> {
                  case transport_http.write_response(socket, resp) {
                    Ok(Nil) -> Nil
                    Error(reason) ->
                      log.error(
                        "beacon.transport",
                        "Failed to write middleware rejection: " <> reason,
                      )
                  }
                  server.close(socket)
                  let _ = connection_tracker_decrement()
                  Nil
                }
              }
            }
            _ -> {
              let handler = create_handler(config)
              let resp = handler(req)
              case transport_http.write_response(socket, resp) {
                Ok(Nil) -> Nil
                Error(reason) ->
                  log.error(
                    "beacon.transport",
                    "Failed to write response: " <> reason,
                  )
              }
              server.close(socket)
              let _ = connection_tracker_decrement()
              Nil
            }
          }
        }
        Error(reason) -> {
          log.error(
            "beacon.transport",
            "Failed to read HTTP request: " <> reason,
          )
          server.close(socket)
          let _ = connection_tracker_decrement()
          Nil
        }
      }
    }
  }
}

/// Run middleware on a request and check if it short-circuits.
/// Returns Ok(Nil) if middleware passes through, Error(resp) if it rejects.
fn check_middleware(
  req: Request(Connection),
  middlewares: List(middleware.Middleware),
) -> Result(Nil, response.Response(ResponseBody)) {
  case middlewares {
    [] -> Ok(Nil)
    mws -> {
      // Use a marker handler — if middleware calls next(), we get status 101
      let marker = fn(_req: Request(Connection)) {
        response.new(101)
        |> response.set_body(Bytes(bytes_tree.new()))
      }
      let piped = middleware.pipeline(mws, marker)
      let result = piped(req)
      case result.status {
        101 -> Ok(Nil)
        _ -> Error(result)
      }
    }
  }
}

// --- HTML/JS Serving ---

/// Serve the HTML page. Checks: ssr_factory (route-aware), page_html (static SSR),
/// then default page. The request is passed to the SSR factory for cookie/header access.
fn serve_page_or_ssr(
  page_html: option.Option(ssr.RenderedPage),
  ssr_factory: option.Option(
    fn(Request(Connection), String) -> ssr.RenderedPage,
  ),
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  case ssr_factory {
    option.Some(factory) -> ssr.to_response(factory(req, req.path))
    option.None ->
      case page_html {
        option.Some(rendered) -> ssr.to_response(rendered)
        option.None ->
          response.new(200)
          |> response.set_header("content-type", "text/html; charset=utf-8")
          |> response.set_body(
            Bytes(bytes_tree.from_string(default_page_html())),
          )
      }
  }
}

/// Default page when no SSR is configured.
fn default_page_html() -> String {
  "<!DOCTYPE html>"
  <> "<html><head><meta charset=\"utf-8\"><title>Beacon</title>"
  <> "</head><body>"
  <> "<div id=\"beacon-app\"></div>"
  <> "<script src=\"/"
  <> get_client_js_filename()
  <> "\" data-beacon-auto></script>"
  <> "</body></html>"
}

fn get_client_js_filename() -> String {
  let manifest_path = ssr.client_assets_dir() <> "/beacon_client.manifest"
  case simplifile.read(manifest_path) {
    Ok(name) -> string.trim(name)
    Error(err) -> {
      log.error(
        "beacon.transport",
        "FATAL: No beacon_client.manifest found at "
          <> manifest_path
          <> ": "
          <> string.inspect(err)
          <> " — the client JS was not built. Run `gleam run -m beacon/build` first.",
      )
      "MISSING_CLIENT_JS_RUN_BEACON_BUILD"
    }
  }
}

fn serve_client_js(
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  let assets_dir = ssr.client_assets_dir()
  let manifest_path = assets_dir <> "/beacon_client.manifest"
  case simplifile.read(manifest_path) {
    Ok(name) -> serve_js_file(assets_dir <> "/" <> string.trim(name), req)
    Error(err) -> {
      log.error(
        "beacon.transport",
        "FATAL: No beacon_client.manifest: "
          <> string.inspect(err)
          <> " — client JS not built. Run `gleam run -m beacon/build`.",
      )
      response.new(500)
      |> response.set_body(
        Bytes(bytes_tree.from_string(
          "Client JS not built. Run `gleam run -m beacon/build` first.",
        )),
      )
    }
  }
}

fn serve_hashed_client_js(
  name: String,
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  serve_js_file(ssr.client_assets_dir() <> "/" <> name, req)
}

fn serve_js_file(
  path: String,
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  case simplifile.read(path) {
    Ok(contents) -> {
      let base_response =
        response.new(200)
        |> response.set_header(
          "content-type",
          "application/javascript; charset=utf-8",
        )
        |> response.set_header(
          "cache-control",
          "public, max-age=31536000, immutable",
        )
        |> response.set_header("vary", "accept-encoding")
      let accepts_gzip = case request.get_header(req, "accept-encoding") {
        Ok(header) -> string.contains(string.lowercase(header), "gzip")
        Error(Nil) -> False
      }
      case accepts_gzip {
        True ->
          base_response
          |> response.set_header("content-encoding", "gzip")
          |> response.set_body(
            Bytes(
              bytes_tree.from_bit_array(
                gzip_compress(bit_array.from_string(contents)),
              ),
            ),
          )
        False ->
          base_response
          |> response.set_body(Bytes(bytes_tree.from_string(contents)))
      }
    }
    Error(err) -> {
      log.error(
        "beacon.transport",
        "Client JS not found: "
          <> string.inspect(err)
          <> " — run `gleam run -m beacon/build` to compile client JS",
      )
      response.new(500)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(
        Bytes(bytes_tree.from_string(
          "// beacon.js not found. Run: gleam run -m beacon/build\n",
        )),
      )
    }
  }
}

@external(erlang, "zlib", "gzip")
fn gzip_compress(data: BitArray) -> BitArray

// --- Server Start ---

/// Default number of acceptor processes.
const default_acceptor_count = 10

/// Start the transport layer — binds to the given port and begins
/// accepting connections. Returns the server process Pid for monitoring.
pub fn start(
  config: TransportConfig,
) -> Result(process.Pid, error.BeaconError) {
  log.info(
    "beacon.transport",
    "Starting on port " <> int.to_string(config.port),
  )
  // Warn if no WebSocket authentication is configured
  case config.ws_auth {
    None ->
      log.warning(
        "beacon.transport",
        "No ws_auth configured — WebSocket connections are unauthenticated. "
          <> "Set ws_auth in TransportConfig to require authentication on upgrade.",
      )
    Some(_) -> Nil
  }

  let handler_fn = fn(socket: Socket) { per_connection_handler(socket, config) }

  case server.start(config.port, handler_fn, default_acceptor_count) {
    Ok(pid) -> {
      log.info(
        "beacon.transport",
        "Listening on port " <> int.to_string(config.port),
      )
      Ok(pid)
    }
    Error(reason) -> {
      log.error(
        "beacon.transport",
        "Failed to start on port "
          <> int.to_string(config.port)
          <> ": "
          <> reason,
      )
      Error(error.TransportError(
        reason: "Failed to bind to port " <> int.to_string(config.port),
      ))
    }
  }
}
