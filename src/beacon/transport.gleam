/// Beacon's WebSocket transport layer.
/// Manages WebSocket connections with one BEAM process per connection.
/// Follows LiveView's connection lifecycle: connect → init → handle messages → close.
///
/// Uses Beacon's own minimal HTTP/WebSocket server (beacon/transport/server)
/// instead of Mist. Direct gen_tcp for zero unnecessary abstraction layers.
///
/// Reference: LiveView channel protocol, RFC 6455.
import beacon/cookie
import beacon/error
import beacon/ip
import beacon/log
import beacon/middleware
import beacon/ssr
import beacon/static
import beacon/transport/client
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
import gleam/http
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
    // HTTP limits
    /// Maximum concurrent connections from one peer IP. Peers listed in
    /// `trusted_proxies` are exempt (they multiplex many clients). Default: 256.
    max_connections_per_ip: Int,
    /// Maximum request-line length in bytes; longer lines get 414. Default: 8192.
    max_request_line_bytes: Int,
    /// Maximum declared request body size in bytes; larger Content-Length
    /// gets 413 before the handler runs. Default: 8388608 (8MB).
    max_body_bytes: Int,
    /// Maximum wait for each chunk of request body, in milliseconds. Default: 30000.
    body_read_timeout_ms: Int,
    /// Absolute deadline for reading a request body, in milliseconds from
    /// the moment its head was parsed (the head itself is bounded by
    /// `pre_upgrade_timeout_ms`). Default: 60000.
    request_timeout_ms: Int,
    /// How long an idle keep-alive connection waits for the next request,
    /// in milliseconds. Default: 15000.
    keepalive_idle_timeout_ms: Int,
    /// Maximum requests served on one keep-alive connection. Default: 1000.
    max_keepalive_requests: Int,
    /// Maximum time a blocked socket send may take before the connection
    /// is closed, in milliseconds. Default: 30000.
    send_timeout_ms: Int,
    /// Reverse proxies (IP addresses or CIDRs) whose X-Forwarded-For and
    /// Forwarded headers are believed. Empty means the socket peer address
    /// is always the client address. Default: [].
    trusted_proxies: List(String),
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
    // HTTP limits
    max_connections_per_ip: 256,
    max_request_line_bytes: 8192,
    max_body_bytes: 8_388_608,
    body_read_timeout_ms: 30_000,
    request_timeout_ms: 60_000,
    keepalive_idle_timeout_ms: 15_000,
    max_keepalive_requests: 1000,
    send_timeout_ms: 30_000,
    trusted_proxies: [],
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
/// closes", and `max_body_bytes` may be 0, meaning "no request bodies"),
/// timer intervals must fit `erlang:send_after/3`, and every allowed origin
/// must be a bare `scheme://host[:port]` origin.
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
    // HTTP limits
    #("max_connections_per_ip", limits.max_connections_per_ip),
    #("max_request_line_bytes", limits.max_request_line_bytes),
    #("body_read_timeout_ms", limits.body_read_timeout_ms),
    #("request_timeout_ms", limits.request_timeout_ms),
    #("keepalive_idle_timeout_ms", limits.keepalive_idle_timeout_ms),
    #("max_keepalive_requests", limits.max_keepalive_requests),
    #("send_timeout_ms", limits.send_timeout_ms),
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
    // HTTP limits: 0 means "no request body accepted".
    #("max_body_bytes", limits.max_body_bytes),
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
    // HTTP limits: a typo in the proxy list must never silently change who
    // is trusted.
    use _ <- result.try(
      ip.parse_trusted_proxies(limits.trusted_proxies)
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(reason) { "trusted_proxies: " <> reason }),
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

/// The parsed `trusted_proxies` of validated limits.
/// `validate_security_limits` (run when the listener starts) has already
/// rejected any unparsable entry, so an error here means the limits were
/// built without validation; it is logged and the caller must refuse.
pub fn trusted_proxies(
  limits: SecurityLimits,
) -> Result(ip.TrustedProxies, String) {
  case ip.parse_trusted_proxies(limits.trusted_proxies) {
    Ok(parsed) -> Ok(parsed)
    Error(reason) -> {
      log.error(
        "beacon.transport",
        "trusted_proxies is invalid (limits were not validated): " <> reason,
      )
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

/// The scheme the client used to reach us. X-Forwarded-Proto is honoured
/// only from a trusted proxy (`beacon/transport/client`); otherwise plain
/// http (Beacon itself does not terminate TLS).
fn request_scheme(
  req: Request(Connection),
  limits: SecurityLimits,
) -> Result(String, String) {
  use trusted <- result.try(trusted_proxies(limits))
  client.scheme(req, trusted)
}

/// The client address for an upgrade: the socket peer, or the forwarded
/// client when the peer is a trusted proxy (same rule as the HTTP side).
fn ws_client_ip(
  socket: Socket,
  req: Request(Connection),
  limits: SecurityLimits,
) -> Result(String, String) {
  use trusted <- result.try(trusted_proxies(limits))
  client.ip_for_socket(socket, req.headers, trusted)
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
      case request_scheme(req, limits) {
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
  case validate_security_limits(limits), ws_client_ip(socket, req, limits) {
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
    False ->
      // Slots are scoped by the port the socket was accepted on (not the
      // configured port, which is 0 for OS-assigned listeners) so two
      // listeners in one VM never share per-IP counts.
      case server.get_local_port(socket) {
        Error(reason) ->
          reject_ws_request(
            socket,
            conn_id,
            peer_ip,
            None,
            500,
            "Server error",
            "could not read local port: " <> reason,
          )
        Ok(local_port) ->
          acquire_ws_slot(
            socket,
            req,
            config,
            conn_id,
            peer_ip,
            int.to_string(local_port) <> "|" <> peer_ip,
          )
      }
  }
}

fn acquire_ws_slot(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
  conn_id: ConnectionId,
  peer_ip: String,
  slot_key: String,
) -> Nil {
  let limits = config.security_limits
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
/// Paths are matched exactly (no segment normalisation), and framework
/// assets answer only GET and HEAD.
fn route_framework_request(
  config: TransportConfig,
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  case req.path {
    "/health" ->
      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(Bytes(bytes_tree.from_string("{\"status\":\"ok\"}")))
    "/beacon_client.js" ->
      when_readable_method(req, fn() { serve_client_js(req) })
    "/beacon_client_" <> _ -> {
      let name = string.drop_start(req.path, 1)
      // Only exact build output names are read from the assets directory;
      // anything else is an ordinary path.
      case static.is_client_bundle_name(name) {
        True ->
          when_readable_method(req, fn() { serve_hashed_client_js(name, req) })
        False -> route_static_or_page(config, req)
      }
    }
    _ -> route_static_or_page(config, req)
  }
}

/// Serve a static file when the path is under the static prefix, else the page.
fn route_static_or_page(
  config: TransportConfig,
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  let page = fn() {
    serve_page_or_ssr(config.page_html, config.ssr_factory, req)
  }
  case config.static_config {
    None -> page()
    Some(static_cfg) ->
      case static.matches_prefix(static_cfg, req.path) {
        False -> page()
        True ->
          when_readable_method(req, fn() {
            case
              static.serve_with_etag_check(
                static_cfg,
                req.path,
                header_or_empty(req, "if-none-match"),
              )
            {
              Ok(resp) -> resp
              Error(Nil) -> page()
            }
          })
      }
  }
}

/// Run `serve` for GET and HEAD; any other method gets 405 (RFC 9110 §15.5.6).
fn when_readable_method(
  req: Request(Connection),
  serve: fn() -> response.Response(ResponseBody),
) -> response.Response(ResponseBody) {
  case req.method {
    http.Get | http.Head -> serve()
    method -> {
      log.debug(
        "beacon.transport",
        "405 for "
          <> http.method_to_string(method)
          <> " on framework asset "
          <> req.path,
      )
      response.new(405)
      |> response.set_header("allow", "GET, HEAD")
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(Bytes(bytes_tree.from_string("Method Not Allowed")))
    }
  }
}

/// A request header value, or "" when absent.
fn header_or_empty(req: Request(Connection), name: String) -> String {
  case request.get_header(req, name) {
    Ok(value) -> value
    Error(Nil) -> ""
  }
}

// --- Per-Connection Handler ---

/// Unread request body bytes the server discards itself so a keep-alive
/// connection can be reused (cowboy uses the same idea). A larger unread
/// body closes the connection instead.
const max_discard_body_bytes = 65_536

/// Methods answered for `OPTIONS *`.
const allowed_methods_header = "GET, HEAD, POST, PUT, DELETE, OPTIONS, PATCH"

/// Serve one TCP connection: HTTP/1.1 requests in a keep-alive loop until
/// the connection closes or is upgraded to a WebSocket.
/// Middleware runs on ALL requests, including /ws, before routing.
///
/// The connection slot is owned by the listener's connection owner, which
/// releases it when this process exits, so there is no manual bookkeeping
/// on the HTTP path.
fn per_connection_handler(
  socket: Socket,
  config: TransportConfig,
  handler: fn(Request(Connection)) -> response.Response(ResponseBody),
) -> Nil {
  log.debug("beacon.transport", "Connection handler started")
  serve_requests(socket, config, handler, 0)
}

fn serve_requests(
  socket: Socket,
  config: TransportConfig,
  handler: fn(Request(Connection)) -> response.Response(ResponseBody),
  served: Int,
) -> Nil {
  let limits = config.security_limits
  let head_limits =
    transport_http.HeadLimits(
      max_headers: limits.max_http_headers,
      max_header_bytes: limits.max_http_header_bytes,
      max_request_line_bytes: limits.max_request_line_bytes,
    )
  // The first request must arrive promptly after accept (slowloris guard);
  // later ones may wait for the keep-alive idle timeout, but once a request
  // line arrived its headers must follow within the pre-upgrade timeout.
  let timing = case served {
    0 ->
      transport_http.HeadTiming(
        request_line_timeout_ms: limits.pre_upgrade_timeout_ms,
        header_deadline: transport_http.SharedWithRequestLine,
      )
    _ ->
      transport_http.HeadTiming(
        request_line_timeout_ms: limits.keepalive_idle_timeout_ms,
        header_deadline: transport_http.AfterRequestLine(
          limits.pre_upgrade_timeout_ms,
        ),
      )
  }
  case transport_http.read_request_head(socket, head_limits, timing) {
    Error(err) ->
      case transport_http.get_head_error_status(err) {
        None -> {
          log.debug(
            "beacon.transport",
            "Closing connection after "
              <> int.to_string(served)
              <> " requests: "
              <> transport_http.get_head_error_message(err),
          )
          server.close(socket)
        }
        Some(status) ->
          transport_http.write_error(
            socket,
            status,
            transport_http.get_head_error_message(err),
          )
      }
    Ok(#(req, version)) ->
      case transport_http.check_framing(req, version, limits.max_body_bytes) {
        Error(transport_http.FramingError(status: status, reason: reason)) ->
          transport_http.write_error(socket, status, reason)
        Ok(framing) ->
          case request.path_segments(req) {
            ["ws"] -> serve_ws_request(socket, req, framing, config)
            _ ->
              serve_http_request(
                socket,
                req,
                version,
                framing,
                config,
                handler,
                served,
              )
          }
      }
  }
}

/// Route a /ws request: middleware, then the WebSocket upgrade. The
/// connection never returns to the HTTP loop afterwards.
fn serve_ws_request(
  socket: Socket,
  req: Request(Connection),
  framing: transport_http.BodyFraming,
  config: TransportConfig,
) -> Nil {
  case framing.content_length, transport_http.get_buffered_byte_count(socket) {
    0, 0 ->
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
          transport_http.close_gracefully(socket)
        }
      }
    0, buffered -> {
      // RFC 6455 4.1: the client must wait for the handshake response
      // before sending frames. The frame reader starts from the socket, so
      // bytes already buffered here would be silently lost.
      log.warning(
        "beacon.transport",
        "Rejecting WebSocket upgrade: client sent "
          <> int.to_string(buffered)
          <> " bytes before the handshake completed",
      )
      transport_http.write_error(
        socket,
        400,
        "Data received before the WebSocket handshake completed",
      )
    }
    length, _ -> {
      // Body bytes after an upgrade request would be parsed as WebSocket
      // frames; refuse instead.
      log.warning(
        "beacon.transport",
        "Rejecting WebSocket upgrade request with a "
          <> int.to_string(length)
          <> " byte body",
      )
      transport_http.write_error(
        socket,
        400,
        "WebSocket upgrade requests must not have a body",
      )
    }
  }
}

fn serve_http_request(
  socket: Socket,
  req: Request(Connection),
  version: transport_http.HttpVersion,
  framing: transport_http.BodyFraming,
  config: TransportConfig,
  handler: fn(Request(Connection)) -> response.Response(ResponseBody),
  served: Int,
) -> Nil {
  let limits = config.security_limits
  let deadline = transport_http.get_monotonic_ms() + limits.request_timeout_ms
  transport_http.begin_body(
    socket,
    framing,
    limits.body_read_timeout_ms,
    deadline,
  )
  let request_handler = case req.method, req.path {
    http.Options, "*" -> asterisk_options_response
    _, _ -> handler
  }
  let result = transport_http.run_handler(request_handler, req)
  // A 100-continue client is still waiting for permission to send an unread
  // body; reading it ourselves would invite it, so close instead.
  let discard_limit = case framing.expect_continue {
    True -> 0
    False -> max_discard_body_bytes
  }
  let body = transport_http.finish_body(socket, discard_limit)
  case result {
    Error(_) -> {
      // run_handler already logged the crash with its stacktrace.
      let resp =
        transport_http.create_error_response(500, "Internal Server Error")
      case write_response_for(socket, req, version, resp, False) {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.warning(
            "beacon.transport",
            "Failed to write 500 after handler crash: " <> reason,
          )
      }
      transport_http.close_gracefully(socket)
    }
    Ok(resp) -> {
      let served = served + 1
      let keep_alive =
        decide_keep_alive(req, version, resp, body, served, limits)
      case write_response_for(socket, req, version, resp, keep_alive) {
        Error(reason) -> {
          log.error(
            "beacon.transport",
            "Failed to write response, closing connection: " <> reason,
          )
          server.close(socket)
        }
        Ok(Nil) ->
          case keep_alive {
            True -> serve_requests(socket, config, handler, served)
            False -> transport_http.close_gracefully(socket)
          }
      }
    }
  }
}

fn write_response_for(
  socket: Socket,
  req: Request(Connection),
  version: transport_http.HttpVersion,
  resp: response.Response(ResponseBody),
  keep_alive: Bool,
) -> Result(Nil, String) {
  transport_http.write_framed_response(
    socket,
    resp,
    transport_http.ResponseFraming(
      version: version,
      head_request: req.method == http.Head,
      keep_alive: keep_alive,
    ),
  )
}

/// Whether the connection can serve another request after this one.
fn decide_keep_alive(
  req: Request(Connection),
  version: transport_http.HttpVersion,
  resp: response.Response(ResponseBody),
  body: transport_http.BodyOutcome,
  served: Int,
  limits: SecurityLimits,
) -> Bool {
  case
    transport_http.is_keep_alive_requested(req, version),
    transport_http.is_close_requested_by_response(resp),
    body,
    served >= limits.max_keepalive_requests
  {
    False, _, _, _ -> False
    _, True, _, _ -> False
    _, _, transport_http.BodyUnread(remaining), _ -> {
      log.info(
        "beacon.transport",
        "Closing connection: handler left "
          <> int.to_string(remaining)
          <> " request body bytes unread",
      )
      False
    }
    _, _, transport_http.BodyFailed, _ -> {
      log.info(
        "beacon.transport",
        "Closing connection after a failed request body read",
      )
      False
    }
    _, _, transport_http.BodyConsumed, True -> {
      log.info(
        "beacon.transport",
        "Closing connection after "
          <> int.to_string(served)
          <> " requests (max_keepalive_requests)",
      )
      False
    }
    True, False, transport_http.BodyConsumed, False -> True
  }
}

/// `OPTIONS *` (RFC 9110 9.3.7) asks about the server as a whole.
fn asterisk_options_response(
  _req: Request(Connection),
) -> response.Response(ResponseBody) {
  log.debug("beacon.transport", "Answering OPTIONS *")
  response.new(204)
  |> response.set_header("allow", allowed_methods_header)
  |> response.set_body(Bytes(bytes_tree.new()))
}

/// Run middleware on a request and check if it short-circuits.
/// Returns Ok(Nil) if middleware passes through, Error(resp) if it rejects.
/// A crashing middleware rejects the request with 500.
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
      case transport_http.run_handler(piped, req) {
        Ok(result) ->
          case result.status {
            101 -> Ok(Nil)
            _ -> Error(result)
          }
        Error(_) ->
          Error(transport_http.create_error_response(
            500,
            "Internal Server Error",
          ))
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
    option.Some(factory) -> page_response(factory(req, req.path), req)
    option.None ->
      case page_html {
        option.Some(rendered) -> page_response(rendered, req)
        option.None ->
          case default_page_html() {
            Ok(html) ->
              response.new(200)
              |> response.set_header("content-type", "text/html; charset=utf-8")
              |> response.set_body(Bytes(bytes_tree.from_string(html)))
            Error(reason) -> client_js_unavailable(reason)
          }
      }
  }
}

/// Default page when no SSR is configured. Fails when the client bundle
/// has not been built: a page whose script cannot load is not served.
fn default_page_html() -> Result(String, String) {
  case get_client_js_filename(ssr.client_assets_dir()) {
    Error(reason) -> Error(reason)
    Ok(filename) ->
      Ok(
        "<!DOCTYPE html>"
        <> "<html><head><meta charset=\"utf-8\"><title>Beacon</title>"
        <> "</head><body>"
        <> "<div id=\"beacon-app\"></div>"
        <> "<script src=\"/"
        <> filename
        <> "\" data-beacon-auto></script>"
        <> "</body></html>",
      )
  }
}

/// The bundle file named by `beacon_client.manifest` in `assets_dir`. The
/// name must be exact build output (`static.is_client_bundle_name`), so a
/// damaged manifest can never point the server at another file.
fn get_client_js_filename(assets_dir: String) -> Result(String, String) {
  let manifest_path = assets_dir <> "/beacon_client.manifest"
  case simplifile.read(manifest_path) {
    Ok(contents) -> {
      let name = string.trim(contents)
      case static.is_client_bundle_name(name) {
        True -> Ok(name)
        False -> {
          let reason =
            "beacon_client.manifest at "
            <> manifest_path
            <> " names an invalid bundle "
            <> string.inspect(name)
            <> " — rebuild with `gleam run -m beacon/build`"
          log.error("beacon.transport", reason)
          Error(reason)
        }
      }
    }
    Error(err) -> {
      let reason =
        "No beacon_client.manifest at "
        <> manifest_path
        <> ": "
        <> string.inspect(err)
        <> " — the client JS was not built. Run `gleam run -m beacon/build` first."
      log.error("beacon.transport", reason)
      Error(reason)
    }
  }
}

/// The SSR page response. Its join token is bound to the request's
/// session cookie (`ssr.to_response_for_request`), so a token lifted from
/// one browser session does not join under another. A join cookie that
/// cannot be set is a server bug: answer 500 rather than a page without it.
fn page_response(
  page: ssr.RenderedPage,
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  case ssr.to_response_for_request(page, req) {
    Ok(resp) -> resp
    Error(error) -> {
      log.error(
        "beacon.transport",
        "Cannot set the SSR join cookie for "
          <> req.path
          <> ": "
          <> cookie.error_to_string(error),
      )
      response.new(500)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(
        Bytes(bytes_tree.from_string("Internal Server Error")),
      )
    }
  }
}

/// 500 for a missing or invalid client bundle (a deployment error).
fn client_js_unavailable(reason: String) -> response.Response(ResponseBody) {
  log.error("beacon.transport", "Client JS unavailable: " <> reason)
  response.new(500)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(
    Bytes(bytes_tree.from_string(
      "Client JS not built. Run `gleam run -m beacon/build` first.",
    )),
  )
}

/// `/beacon_client.js`: the current bundle under a stable URL, so it must be
/// revalidated on every use (`no-cache` plus an ETag).
fn serve_client_js(
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  let assets_dir = ssr.client_assets_dir()
  case get_client_js_filename(assets_dir) {
    Ok(name) ->
      case serve_js_file(assets_dir <> "/" <> name, "no-cache", req) {
        Ok(resp) -> resp
        // The manifest names a bundle that does not exist: broken build.
        Error(Nil) ->
          client_js_unavailable(
            "beacon_client.manifest names " <> name <> " but it does not exist",
          )
      }
    Error(reason) -> client_js_unavailable(reason)
  }
}

/// `/beacon_client_<hash>.js`: content-addressed, cached forever. A name that
/// no longer exists (a page from before a deploy) is a 404.
fn serve_hashed_client_js(
  name: String,
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  case
    serve_js_file(
      ssr.client_assets_dir() <> "/" <> name,
      static.immutable_cache_control(),
      req,
    )
  {
    Ok(resp) -> resp
    Error(Nil) -> {
      log.warning(
        "beacon.transport",
        "Unknown client bundle requested: " <> name,
      )
      response.new(404)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_header("cache-control", "no-store")
      |> response.set_body(Bytes(bytes_tree.from_string("Not Found")))
    }
  }
}

/// Serve a client bundle from the asset cache (raw and gzip bodies are built
/// once per file version). Content negotiation picks gzip when the client
/// accepts it; each encoding has its own strong ETag. Error(Nil) when the
/// file does not exist.
fn serve_js_file(
  path: String,
  cache_control: String,
  req: Request(Connection),
) -> Result(response.Response(ResponseBody), Nil) {
  case static.load_client_asset(path) {
    Ok(asset) -> {
      let use_gzip =
        static.accepts_gzip(header_or_empty(req, "accept-encoding"))
      let #(body, etag) = case use_gzip {
        True -> #(asset.gzip, gzip_etag(asset.etag))
        False -> #(asset.raw, asset.etag)
      }
      let base =
        response.new(200)
        |> response.set_header("cache-control", cache_control)
        |> response.set_header("etag", etag)
        |> response.set_header("vary", "accept-encoding")
        |> response.set_header("x-content-type-options", "nosniff")
      case static.etag_matches(header_or_empty(req, "if-none-match"), etag) {
        True -> {
          log.debug("beacon.transport", "304 for client JS " <> path)
          Ok(
            response.Response(..base, status: 304)
            |> response.set_body(Bytes(bytes_tree.new())),
          )
        }
        False -> {
          let base =
            base
            |> response.set_header(
              "content-type",
              "application/javascript; charset=utf-8",
            )
          let base = case use_gzip {
            True -> response.set_header(base, "content-encoding", "gzip")
            False -> base
          }
          Ok(response.set_body(base, Bytes(bytes_tree.from_bit_array(body))))
        }
      }
    }
    Error(static.AssetNotFound) -> Error(Nil)
    Error(static.AssetReadFailed(reason)) ->
      Ok(client_js_unavailable("cannot read " <> path <> ": " <> reason))
  }
}

/// The ETag of the gzip representation: the identity ETag with a `-gzip`
/// suffix inside the quotes (strong validators must differ per encoding).
fn gzip_etag(etag: String) -> String {
  string.drop_end(etag, 1) <> "-gzip\""
}

// --- Server Start ---

/// Default number of acceptor processes.
const default_acceptor_count = 10

/// Default listen backlog.
const default_backlog = 1024

/// The listener options implied by a transport configuration.
pub fn to_listener_options(config: TransportConfig) -> server.ListenerOptions {
  let limits = config.security_limits
  server.ListenerOptions(
    port: config.port,
    acceptors: default_acceptor_count,
    backlog: default_backlog,
    max_connections: limits.max_connections,
    max_connections_per_ip: limits.max_connections_per_ip,
    trusted_proxies: limits.trusted_proxies,
    send_timeout_ms: limits.send_timeout_ms,
  )
}

/// Start the transport layer — binds to the given port and begins
/// accepting connections. Returns the listener supervisor's Pid.
/// Use `start_listener` to also learn the bound port (for port 0).
pub fn start(
  config: TransportConfig,
) -> Result(process.Pid, error.BeaconError) {
  case start_listener(config) {
    Ok(listener) -> {
      log.debug(
        "beacon.transport",
        "Transport started on port " <> int.to_string(server.get_port(listener)),
      )
      Ok(server.get_supervisor(listener))
    }
    Error(err) -> Error(err)
  }
}

/// Start the transport layer and return the running listener, which
/// reports the bound port (`server.get_port`) and live connection counts.
/// The listener supervisor is linked to the caller.
pub fn start_listener(
  config: TransportConfig,
) -> Result(server.Listener, error.BeaconError) {
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
  let static_check = case config.static_config {
    Some(static_cfg) -> static.validate_config(static_cfg)
    None -> Ok(Nil)
  }
  case validate_security_limits(config.security_limits), static_check {
    Error(reason), _ ->
      Error(error.ConfigError(reason: "Invalid security limits: " <> reason))
    _, Error(reason) ->
      Error(error.ConfigError(reason: "Invalid static config: " <> reason))
    Ok(Nil), Ok(Nil) -> {
      // Built once: middleware and routing closures are shared by every
      // connection instead of being rebuilt per request.
      let handler = create_handler(config)
      let handler_fn = fn(socket: Socket) {
        per_connection_handler(socket, config, handler)
      }
      case server.start(to_listener_options(config), handler_fn) {
        Ok(listener) -> {
          log.info(
            "beacon.transport",
            "Listening on port " <> int.to_string(server.get_port(listener)),
          )
          Ok(listener)
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
            reason: "Failed to bind to port "
            <> int.to_string(config.port)
            <> ": "
            <> reason,
          ))
        }
      }
    }
  }
}
