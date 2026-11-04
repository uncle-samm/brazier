/// Brazier's WebSocket transport layer.
/// Manages WebSocket connections with one BEAM process per connection.
/// Follows LiveView's connection lifecycle: connect → init → handle messages → close.
///
/// Uses Brazier's own minimal HTTP/WebSocket server (brazier/transport/server)
/// instead of Mist. Direct gen_tcp for zero unnecessary abstraction layers.
///
/// Reference: LiveView channel protocol, RFC 6455.
import brazier/config as app_env
import brazier/cookie
import brazier/error
import brazier/internal/local_path
import brazier/internal/log_path
import brazier/ip
import brazier/log
import brazier/middleware
import brazier/pubsub
import brazier/ssr
import brazier/static
import brazier/telemetry
import brazier/transport/client
import brazier/transport/http as transport_http
import brazier/transport/server.{
  type Connection, type ResponseBody, type Socket, Bytes,
}
import brazier/transport/ws
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
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/uri
import simplifile

/// Unique identifier for a WebSocket connection.
/// Used for logging and session tracking.
pub type ConnectionId =
  String

/// Messages sent from the client (browser) to the server.
/// This is Brazier's wire protocol — not Lustre's internal format.
pub type ClientMessage {
  /// A DOM event was fired (click, input, submit, etc).
  ClientEvent(
    /// The event name (e.g. "click", "input").
    name: String,
    /// The handler identifier from the data-brazier-event-* attribute value.
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
  /// Server-initiated navigation that replaces the current history entry
  /// (`replaceState`). Encoded as `navigate` with `"replace": true`.
  ServerReplaceNavigate(path: String)
  /// Server-initiated hard navigation (full page reload via window.location.href).
  /// Use when the browser needs to make a real HTTP request (e.g., to receive Set-Cookie).
  ServerHardNavigate(path: String)
  /// Dev mode: tell browser to reload.
  ServerReload
  /// The document title for the session's state: sent on every join and
  /// whenever an update changes it. The client sets `document.title`.
  ServerTitle(title: String)
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
  /// Send navigation to the client that replaces the history entry.
  SendReplaceNavigate(path: String)
  /// Send hard navigation to the client (full page reload).
  SendHardNavigate(path: String)
  /// Send the document title to the client.
  SendTitle(title: String)
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
/// `validate_security_limits` rejects nonsensical values; the listener
/// refuses to start with invalid limits.
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
    /// How long a stopping listener waits for its open connections to
    /// finish, in milliseconds. When the listener stops, an idle keep-alive
    /// connection closes at once, a request in progress is answered with
    /// `connection: close`, and a WebSocket is closed with 1001. A
    /// connection still open after this long is killed (and logged as an
    /// error). `0` kills every connection at once. The environment variable
    /// `BRAZIER_SHUTDOWN_TIMEOUT` overrides it for an application. Default:
    /// 5000.
    drain_timeout_ms: Int,
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
    /// Host names this server answers to; every HTTP request and WebSocket
    /// upgrade whose Host header names another host gets 400 (DNS
    /// rebinding protection, Django's `ALLOWED_HOSTS`). The port is not
    /// compared. An entry is a host (`"example.com"`, `"127.0.0.1"`,
    /// `"[::1]"`), a domain and all its subdomains (`".example.com"`), or
    /// `"*"` for every host (which turns the check off, and is logged as a
    /// warning). Empty means `[".localhost", "127.0.0.1", "[::1]"]` in
    /// development; in production (`BRAZIER_ENV=production`) the listener
    /// refuses to start with an empty list. Default: [].
    allowed_hosts: List(String),
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
    drain_timeout_ms: 5000,
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
    allowed_hosts: [],
  )
}

/// Largest delay `erlang:send_after/3` accepts (2^32 - 1 ms).
const max_timer_ms = 4_294_967_295

/// A drain timeout is a receive timeout: 0 (kill at once) up to the largest
/// timer.
pub fn validate_drain_timeout(ms: Int) -> Result(Nil, String) {
  case ms >= 0 && ms <= max_timer_ms {
    True -> Ok(Nil)
    False -> {
      let reason =
        "drain_timeout_ms must be in 0.."
        <> int.to_string(max_timer_ms)
        <> "ms, got "
        <> int.to_string(ms)
      log.warning("brazier.transport", "Refusing drain timeout: " <> reason)
      Error(reason)
    }
  }
}

/// Validate security limits. Every count, size and interval must be
/// positive (the two abuse thresholds may be 0, meaning "first offence
/// closes", `max_body_bytes` may be 0, meaning "no request bodies", and
/// `drain_timeout_ms` may be 0, meaning "kill connections at once"),
/// timer intervals must fit `erlang:send_after/3`, every allowed origin
/// must be a bare `scheme://host[:port]` origin, every allowed host a host
/// name, `.domain` or `*`, and in production (`BRAZIER_ENV=production`)
/// `allowed_hosts` must not be empty. The listener runs the same checks
/// when it starts.
pub fn validate_security_limits(limits: SecurityLimits) -> Result(Nil, String) {
  log.debug("brazier.transport", "Validating security limits")
  check_security_limits(limits, production: app_env.is_production())
  |> result.map(fn(_guards) { Nil })
}

/// What a listener parsed from its limits once, when it started, for every
/// connection it serves (TS-9: nothing is re-parsed per request).
type Guards {
  Guards(origins: AllowedOrigins, hosts: AllowedHosts)
}

fn check_security_limits(
  limits: SecurityLimits,
  production production: Bool,
) -> Result(Guards, String) {
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
    use _ <- result.try(validate_drain_timeout(limits.drain_timeout_ms))
    // HTTP limits: a typo in the proxy list must never silently change who
    // is trusted.
    use _ <- result.try(
      ip.parse_trusted_proxies(limits.trusted_proxies)
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(reason) { "trusted_proxies: " <> reason }),
    )
    use origins <- result.try(parse_allowed_origins(limits.ws_allowed_origins))
    use hosts <- result.try(parse_allowed_hosts(
      limits.allowed_hosts,
      production: production,
    ))
    Ok(Guards(origins: origins, hosts: hosts))
  }
  case outcome {
    Ok(guards) -> {
      log.debug("brazier.transport", "Security limits valid")
      Ok(guards)
    }
    Error(reason) -> {
      log.error("brazier.transport", "Invalid security limits: " <> reason)
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
        "brazier.transport",
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
    /// The original upgrade request (for periodic `ws_auth` re-checks).
    request: Request(Connection),
    /// The configured `ws_auth`, re-run every `ws_auth_recheck_interval_ms`.
    ws_auth: Option(fn(Request(Connection)) -> Result(Nil, String)),
    /// The listener's middleware pipeline: the gate every navigation and
    /// join of this connection must pass (`gate_live_page`).
    middlewares: List(middleware.Middleware),
    /// The page this connection last passed the middleware gate for: the
    /// upgrade's page, then each admitted navigation.
    page: LivePage,
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
    /// Native monotonic time the connection started (after the 101).
    opened_at: Int,
    /// WebSocket frames decoded from the client.
    frames_in: Int,
    /// WebSocket frames written to the client (including the close frame).
    frames_out: Int,
    /// TCP bytes received from the client after the upgrade.
    bytes_in: Int,
    /// Bytes written to the client after the upgrade.
    bytes_out: Int,
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
    /// Middleware runs before routing (SSR, static files). A WebSocket is
    /// gated on the page it mounts instead: the upgrade, every navigation
    /// and every join run the pipeline on a GET of that page with the
    /// upgrade's headers (`gate_live_page`), never on `/ws` itself.
    middlewares: List(middleware.Middleware),
    /// Optional: static file serving configuration.
    static_config: Option(static.StaticConfig),
    /// Optional: factory that creates a per-connection runtime.
    /// If set, each WebSocket connection gets its OWN runtime (like LiveView).
    /// The factory returns callbacks for this specific connection's runtime.
    /// If None, uses the shared on_connect/on_event/on_disconnect callbacks.
    /// The factory receives the upgrade request, from which the runtime
    /// builds the connected mount's Context (cookies, page URL).
    runtime_factory: Option(
      fn(ConnectionId, process.Subject(InternalMessage), Request(Connection)) ->
        Result(
          #(fn(ConnectionId, ClientMessage) -> Nil, fn(ConnectionId) -> Nil),
          StartupError,
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

/// Why a per-connection runtime did not start. Either way the socket is
/// closed right after the upgrade, before any other frame. The factory
/// logs the cause where it happens (Brazier's runtime does, with the
/// connection id); the transport logs the close at info.
pub type StartupError {
  /// The app's `init` refused the session. The socket closes with
  /// `error.init_close_code` (4000 + the status) and the reason
  /// `"init refused"`; the app's own reason is only logged.
  InitRefused(error: error.InitError)
  /// Anything else: an invalid page URL, a crash in `init`, a refused
  /// presence track. The socket closes with 1011 `"startup failure"`.
  StartupFailed(reason: String)
}

pub fn startup_error_to_string(err: StartupError) -> String {
  let text = case err {
    InitRefused(init_error) ->
      "init refused (" <> error.init_error_to_string(init_error) <> ")"
    StartupFailed(reason) -> reason
  }
  log.debug("brazier.transport", "Runtime startup error: " <> text)
  text
}

/// The close frame for a runtime that did not start: code, reason sent to
/// the client, and the telemetry reason label.
fn startup_close(err: StartupError) -> #(Int, String, String) {
  case err {
    InitRefused(init_error) -> #(
      error.init_close_code(init_error),
      "init refused",
      "init_refused",
    )
    StartupFailed(_) -> #(
      ws.close_internal_error,
      "startup failure",
      "startup_failure",
    )
  }
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

@external(erlang, "brazier_connection_tracker_ffi", "init")
pub fn connection_tracker_init() -> Nil

@external(erlang, "brazier_connection_tracker_ffi", "decrement")
fn connection_tracker_decrement() -> Int

@external(erlang, "brazier_connection_tracker_ffi", "count")
fn connection_tracker_count() -> Int

/// Release the calling handler's connection slot early and log what is left.
fn release_connection_slot(context: String) -> Nil {
  let remaining = connection_tracker_decrement()
  log.debug(
    "brazier.transport",
    "Released connection slot ("
      <> context
      <> "); live connections: "
      <> int.to_string(remaining),
  )
}

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
    ServerReplaceNavigate(path) ->
      json.object([
        #("type", json.string("navigate")),
        #("path", json.string(path)),
        #("replace", json.bool(True)),
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
    ServerTitle(title) ->
      json.object([
        #("type", json.string("title")),
        #("title", json.string(title)),
      ])
      |> json.to_string
  }
}

/// A decoded client message and, for a `join`, the build id it carries:
/// the hash of the client bundle its page loaded (`brazier_client_<hash>.js`),
/// `None` when the join names none. Only the transport reads the build id,
/// so it is not part of `ClientJoin`.
type ClientFrame =
  #(ClientMessage, Option(String))

/// Build a decoder for client message JSON.
/// Uses the "type" field to determine which variant to decode.
/// Follows Lustre's transport.server_message_decoder() pattern.
fn client_frame_decoder() -> decode.Decoder(ClientFrame) {
  use msg_type <- decode.field("type", decode.string)
  case msg_type {
    "event" -> {
      use name <- decode.field("name", decode.string)
      use handler_id <- decode.optional_field("handler_id", "", decode.string)
      use data <- decode.field("data", decode.string)
      use target_path <- decode.field("target_path", decode.string)
      use clock <- decode.optional_field("clock", 0, decode.int)
      use ops <- decode.optional_field("ops", "", decode.string)
      decode.success(#(
        ClientEvent(
          name: name,
          handler_id: handler_id,
          data: data,
          target_path: target_path,
          clock: clock,
          ops: ops,
        ),
        None,
      ))
    }
    "heartbeat" -> decode.success(#(ClientHeartbeat, None))
    "join" -> {
      use token <- decode.optional_field("token", "", decode.string)
      use path <- decode.optional_field("path", "/", decode.string)
      use build <- decode.optional_field(
        "build",
        None,
        decode.map(decode.string, Some),
      )
      decode.success(#(ClientJoin(token: token, path: path), build))
    }
    "navigate" -> {
      use path <- decode.field("path", decode.string)
      decode.success(#(ClientNavigate(path: path), None))
    }
    "request_sync" -> decode.success(#(ClientRequestSync, None))
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
      decode.success(#(ClientEventBatch(events: events), None))
    }
    _unknown -> decode.failure(#(ClientHeartbeat, None), "ClientMessage type")
  }
}

/// Decode a JSON string from the client into a ClientMessage.
pub fn decode_client_message(
  raw: String,
) -> Result(ClientMessage, error.BrazierError) {
  decode_client_frame(raw) |> result.map(fn(frame) { frame.0 })
}

/// Decode a JSON string from the client into a message and its build id.
fn decode_client_frame(raw: String) -> Result(ClientFrame, error.BrazierError) {
  case json.parse(raw, client_frame_decoder()) {
    Ok(frame) -> {
      log.debug("brazier.transport", "Decoded client message")
      Ok(frame)
    }
    Error(_json_err) -> {
      log.warning("brazier.transport", "Failed to decode client message")
      Error(error.CodecError(
        reason: "Failed to decode client message",
        raw: raw,
      ))
    }
  }
}

/// Return the type name of a client message for safe logging.
/// Does not include payload data which may be sensitive. The event name and
/// the navigation path are client text, so they are quoted (`string.inspect`)
/// and the path loses its query (`log_path.describe`): a client cannot add
/// control characters or forge a log line.
@internal
pub fn get_client_message_type(msg: ClientMessage) -> String {
  case msg {
    ClientEvent(name: name, ..) -> "event:" <> string.inspect(name)
    ClientHeartbeat -> "heartbeat"
    ClientJoin(..) -> "join"
    ClientNavigate(path: path) -> "navigate:" <> log_path.describe(path)
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
) -> Result(ConnectionState, String) {
  let encoded = encode_server_message(msg)
  case send_counted(state, ws.encode_text(encoded)) {
    Ok(sent_state) -> {
      log.debug("brazier.transport", "Sent message to " <> state.id)
      Ok(sent_state)
    }
    Error(reason) -> {
      log.warning(
        "brazier.transport",
        "Failed to send message to " <> ctx(state) <> ": " <> reason,
      )
      Error(reason)
    }
  }
}

/// Write one encoded frame and count it in the connection's totals.
fn send_counted(
  state: ConnectionState,
  frame: BitArray,
) -> Result(ConnectionState, String) {
  case server.send_bytes(state.socket, frame) {
    Ok(Nil) ->
      Ok(
        ConnectionState(
          ..state,
          frames_out: state.frames_out + 1,
          bytes_out: state.bytes_out + bit_array.byte_size(frame),
        ),
      )
    Error(reason) -> Error(reason)
  }
}

/// Send a message; a failed send stops the connection.
fn send_or_stop(state: ConnectionState, msg: ServerMessage) -> Next {
  case send_ws_message(state, msg) {
    Ok(sent_state) -> Continue(sent_state)
    Error(reason) ->
      Stop(state, NoCloseFrame("send_failed"), "send failed: " <> reason)
  }
}

/// Send a pre-encoded frame (ping, pong); a failed send stops the connection.
fn send_frame_or_stop(
  state: ConnectionState,
  frame: BitArray,
  what: String,
) -> Next {
  case send_counted(state, frame) {
    Ok(sent_state) -> {
      log.debug("brazier.transport", "Sent " <> what <> " to " <> state.id)
      Continue(sent_state)
    }
    Error(reason) -> {
      log.warning(
        "brazier.transport",
        "Failed to send " <> what <> " to " <> ctx(state) <> ": " <> reason,
      )
      Stop(
        state,
        NoCloseFrame("send_failed"),
        what <> " send failed: " <> reason,
      )
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
  // Invariant: every caller passes a literal 1 or `int.max(batch_len, 1)`,
  // so a cost below one is a bug in this module, not client input.
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

/// What a rate limit violation refused, the `kind` of the
/// `[brazier, ws, rate_limited]` event.
type RateViolation {
  /// Events (or a batch) beyond `max_events_per_second`.
  EventRate
  /// A batch longer than `max_batch_size`.
  BatchSize
  /// Heartbeats beyond `max_heartbeats_per_second`.
  HeartbeatRate
}

fn rate_violation_label(kind: RateViolation) -> String {
  case kind {
    EventRate -> "event_rate"
    BatchSize -> "batch_size"
    HeartbeatRate -> "heartbeat_rate"
  }
}

/// Record one rate limit violation. Too many within a window closes the
/// connection with 1008; otherwise `reply` (if any) is sent as an error.
/// Every violation, including the closing one, emits
/// `[brazier, ws, rate_limited]`.
fn record_rate_violation(
  state: ConnectionState,
  kind: RateViolation,
  description: String,
  reply: Option(String),
) -> Next {
  // Roll the window here too, so violations that are not events (heartbeat
  // floods, oversized batches) are also forgiven once a window passes.
  let state = roll_rate_window(state)
  let violations = state.rate_violations + 1
  let state = ConnectionState(..state, rate_violations: violations)
  telemetry.ws_rate_limited(violations, rate_violation_label(kind), state.id)
  let max = state.security_limits.ws_max_rate_violations
  case violations > max {
    True -> {
      log.warning(
        "brazier.transport",
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
        "brazier.transport",
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
    "brazier.transport",
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
        "brazier.transport",
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
  case decode_client_frame(text) {
    Ok(#(ClientHeartbeat, _)) -> {
      let #(new_state, hb_limited) = check_heartbeat_rate(state)
      case hb_limited {
        True ->
          record_rate_violation(
            new_state,
            HeartbeatRate,
            "heartbeat flood",
            None,
          )
        False -> {
          log.debug("brazier.transport", "Heartbeat from " <> state.id)
          send_or_stop(new_state, ServerHeartbeatAck)
        }
      }
    }
    Ok(#(ClientEventBatch(events) as msg, _)) -> {
      let batch_len = list.length(events)
      case batch_len > max_batch_size {
        True ->
          record_rate_violation(
            state,
            BatchSize,
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
    Ok(#(ClientJoin(path:, ..) as msg, build)) -> {
      use new_state <- admit_rate_limited(state, msg, 1)
      case check_build(new_state, build) {
        Ok(Nil) -> {
          use gated_state <- gate_live_page(new_state, JoinGate, path)
          deliver(gated_state, msg)
        }
        Error(stop) -> stop
      }
    }
    Ok(#(ClientNavigate(path:) as msg, _)) -> {
      use new_state <- admit_rate_limited(state, msg, 1)
      use gated_state <- gate_live_page(new_state, NavigateGate, path)
      deliver(gated_state, msg)
    }
    Ok(#(msg, _)) -> dispatch_rate_limited(state, msg, 1)
    Error(_codec_error) -> record_decode_error(state, string.byte_size(text))
  }
}

/// What asked the middleware gate for a page: the `kind` of
/// `[brazier, ws, navigation_refused]`.
type GateKind {
  /// A `join`: the page the client says it shows.
  JoinGate
  /// A `navigate`: a link click, back/forward, `router.push`/`replace`.
  NavigateGate
}

fn gate_kind_label(kind: GateKind) -> String {
  case kind {
    JoinGate -> "join"
    NavigateGate -> "navigate"
  }
}

/// The middleware gate on a live page (SEC-2): a join or navigation to
/// `path` reaches the runtime (`admitted`) only when the GET of that page,
/// with this connection's upgrade headers, passes the middleware pipeline,
/// exactly as its dead render would. Otherwise the client is sent a hard
/// navigation to `path`: the browser loads it over HTTP, and the
/// middleware's own response (a 403, a redirect to a login page) answers it.
/// The message is not forwarded, so no `on_change` runs for the page.
///
/// A path that is not a same-origin path (`internal/local_path`) is never
/// loaded: it is answered with an error and not forwarded. A same-origin
/// path that does not parse is loaded, so the dead render answers it (400).
/// A join for the page this connection already passed the gate for (its
/// upgrade's page) is not gated again.
///
/// Reference: Phoenix LiveView runs a live_session's `on_mount` hooks at
/// every mount, including the connected mount and each `push_navigate`
/// within the session, and answers a navigation it does not authorize with
/// a full page load through the router's plugs.
fn gate_live_page(
  state: ConnectionState,
  kind: GateKind,
  path: String,
  admitted: fn(ConnectionState) -> Next,
) -> Next {
  let label = gate_kind_label(kind)
  case local_path.check(path) {
    Error(reason) -> {
      log.warning(
        "brazier.transport",
        "Refusing "
          <> label
          <> " from "
          <> ctx(state)
          <> " to "
          <> string.inspect(path)
          <> ": not a same-origin path, "
          <> reason,
      )
      telemetry.ws_navigation_refused(label, 400, state.id)
      send_or_stop(state, ServerError(reason: "Invalid page path"))
    }
    Ok(Nil) ->
      case to_live_page(path) {
        Error(reason) -> {
          log.warning(
            "brazier.transport",
            "Loading the page of a "
              <> label
              <> " from "
              <> ctx(state)
              <> " instead: "
              <> reason,
          )
          telemetry.ws_navigation_refused(label, 400, state.id)
          send_or_stop(state, ServerHardNavigate(path: path))
        }
        Ok(page) ->
          case kind == JoinGate && page == state.page {
            True -> {
              log.debug(
                "brazier.transport",
                "Join from "
                  <> state.id
                  <> " is for the page its upgrade passed the middleware for",
              )
              admitted(state)
            }
            False ->
              case
                check_middleware(
                  page_request(state.request, page),
                  state.middlewares,
                )
              {
                Ok(Nil) -> {
                  log.debug(
                    "brazier.transport",
                    "Middleware admitted "
                      <> label
                      <> " from "
                      <> state.id
                      <> " to "
                      <> log_path.describe(path),
                  )
                  admitted(ConnectionState(..state, page: page))
                }
                Error(resp) -> {
                  log.warning(
                    "brazier.transport",
                    "Refusing "
                      <> label
                      <> " from "
                      <> ctx(state)
                      <> " to "
                      <> log_path.describe(path)
                      <> ": the middleware answered "
                      <> int.to_string(resp.status)
                      <> "; sending a hard navigation so the page load gets that answer",
                  )
                  telemetry.ws_navigation_refused(label, resp.status, state.id)
                  send_or_stop(state, ServerHardNavigate(path: path))
                }
              }
          }
      }
  }
}

/// Refuse a join whose page runs an older client build; see
/// `check_join_build`.
fn check_build(
  state: ConnectionState,
  build: Option(String),
) -> Result(Nil, Next) {
  case check_join_build(ssr.client_assets_dir(), ctx(state), build) {
    Ok(Nil) -> Ok(Nil)
    Error(#(code, reason)) ->
      Error(Stop(state, SendClose(code, reason), reason))
  }
}

/// Check the build id a `join` carries against the client bundle the
/// server serves now: the one `brazier_client.manifest` in `assets_dir`
/// names, as the server-rendered page does. The manifest is read on every
/// join, never cached, because `brazier/dev` rebuilds the bundle into a
/// running server.
///
/// - The page's bundle is the current one: `Ok(Nil)`.
/// - It is another one (the app was rebuilt since the page loaded):
///   `Error(#(4409, "stale build"))`. The client reloads behind its reload
///   guard and gets the new bundle, so it never decodes a model with a
///   codec of another build.
/// - The manifest cannot be read, or names no bundle that exists:
///   `Error(#(1011, "internal error"))`, logged as an error. This is a
///   broken deployment, so the join is not let through unchecked.
/// - The join has no build id (its page loaded the client from the
///   unversioned `/brazier_client.js`, or by some other URL): it cannot be
///   checked. `Ok(Nil)`, logged as a warning on every such join.
///
/// `conn` names the connection in the log lines.
/// Reference: Phoenix LiveView's `phx-track-static`. The client sends the
/// URLs of the tracked assets its page loaded with the join, the server
/// compares them with its current digests, and an outdated page is told to
/// reload, with a counter in the client that stops a reload loop.
pub fn check_join_build(
  assets_dir: String,
  conn: String,
  build: Option(String),
) -> Result(Nil, #(Int, String)) {
  case build {
    None -> {
      log.warning(
        "brazier.transport",
        "Join from "
          <> conn
          <> " carries no build id: its page did not load the client from "
          <> "/brazier_client_<hash>.js, so a page from an older build is not detected",
      )
      Ok(Nil)
    }
    Some(page_build) ->
      case ssr.client_bundle_name(assets_dir) {
        Error(reason) -> {
          log.error(
            "brazier.transport",
            "Cannot check the build of the join from "
              <> conn
              <> ", closing with 1011: "
              <> reason,
          )
          Error(#(ws.close_internal_error, "internal error"))
        }
        Ok(bundle) ->
          case bundle == "brazier_client_" <> page_build <> ".js" {
            True -> {
              log.debug(
                "brazier.transport",
                "Join from " <> conn <> " is on the current build " <> bundle,
              )
              Ok(Nil)
            }
            False -> {
              log.info(
                "brazier.transport",
                "Join from "
                  <> conn
                  <> " is from build "
                  <> string.inspect(string.slice(page_build, 0, 64))
                  <> ", the server serves "
                  <> bundle
                  <> ": closing with 4409 so the page reloads",
              )
              Error(#(ws.close_stale_build, "stale build"))
            }
          }
      }
  }
}

/// Dispatch a decoded message if the rate limit allows `cost` more events.
fn dispatch_rate_limited(
  state: ConnectionState,
  msg: ClientMessage,
  cost: Int,
) -> Next {
  use new_state <- admit_rate_limited(state, msg, cost)
  deliver(new_state, msg)
}

/// Hand a message that passed every check to the runtime.
fn deliver(state: ConnectionState, msg: ClientMessage) -> Next {
  log.debug(
    "brazier.transport",
    "Event from " <> state.id <> ": " <> get_client_message_type(msg),
  )
  state.on_event(state.id, msg)
  Continue(state)
}

/// Charge `cost` events against the rate limit: a message over it is a rate
/// violation, one within it continues with `next`.
fn admit_rate_limited(
  state: ConnectionState,
  msg: ClientMessage,
  cost: Int,
  next: fn(ConnectionState) -> Next,
) -> Next {
  let #(new_state, rate_limited) = check_rate_limit(state, cost)
  case rate_limited {
    True ->
      record_rate_violation(
        new_state,
        EventRate,
        "rate limited "
          <> get_client_message_type(msg)
          <> " ("
          <> int.to_string(cost)
          <> " events, "
          <> int.to_string(new_state.event_count)
          <> " already this second)",
        Some("Rate limited"),
      )
    False -> next(new_state)
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
  /// `label` is the fixed snake_case reason reported to telemetry.
  NoCloseFrame(label: String)
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
        "brazier.transport",
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
      process_frames(
        ConnectionState(
          ..state,
          reassembly: reassembly,
          frames_in: state.frames_in + 1,
        ),
        rest,
      )
    Ok(ws.Complete(message: message, rest: rest, reassembly: reassembly)) ->
      case
        handle_ws_message(
          ConnectionState(
            ..state,
            reassembly: reassembly,
            frames_in: state.frames_in + 1,
          ),
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
        "brazier.transport",
        "Binary message from "
          <> ctx(state)
          <> " ("
          <> int.to_string(bit_array.byte_size(data))
          <> " bytes) — Brazier only accepts text",
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
        "brazier.transport",
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
          log.debug("brazier.transport", "Pong from " <> state.id)
          Continue(
            ConnectionState(..state, pending_ping: None, pong_timer: None),
          )
        }
        False -> {
          log.debug(
            "brazier.transport",
            "Pong with stale payload from " <> state.id,
          )
          Continue(state)
        }
      }
    None -> {
      log.debug("brazier.transport", "Unsolicited pong from " <> state.id)
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
            "brazier.transport",
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
        "brazier.transport",
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
        "brazier.transport",
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
          log.debug(
            "brazier.transport",
            "Auth re-check passed for " <> state.id,
          )
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
            "brazier.transport",
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
      let state =
        ConnectionState(
          ..state,
          buffer: <<>>,
          bytes_in: state.bytes_in + bit_array.byte_size(data),
        )
      case process_frames(state, buffer) {
        Continue(new_state) -> {
          server.set_active_once(new_state.socket)
          Continue(new_state)
        }
        stop -> stop
      }
    }
    ws.SocketClosed ->
      Stop(state, NoCloseFrame("tcp_closed"), "peer closed TCP connection")
    ws.SocketError(reason) -> {
      log.warning(
        "brazier.transport",
        "TCP error for " <> ctx(state) <> ": " <> reason,
      )
      Stop(state, NoCloseFrame("tcp_error"), "TCP error: " <> reason)
    }
    ws.SessionRevoked(session_id: _, reason: reason) -> {
      log.warning(
        "brazier.transport",
        "Session behind " <> ctx(state) <> " was " <> reason,
      )
      Stop(
        state,
        SendClose(ws.close_auth_revoked, "session revoked"),
        "session " <> reason,
      )
    }
    ws.ServerDraining -> {
      log.info(
        "brazier.transport",
        "Listener is stopping, closing " <> ctx(state) <> " with 1001",
      )
      Stop(
        state,
        SendClose(ws.close_going_away, "server shutting down"),
        "server draining",
      )
    }
    ws.DevReload -> {
      log.info(
        "brazier.transport",
        "Dev rebuild: telling the page of " <> ctx(state) <> " to reload",
      )
      send_or_stop(state, ServerReload)
    }
    ws.UnexpectedMessage(description) -> {
      log.error(
        "brazier.transport",
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
        "brazier.transport",
        "Outbound queue for "
          <> ctx(state)
          <> " has "
          <> int.to_string(queued)
          <> " messages (max "
          <> int.to_string(max)
          <> ")",
      )
      telemetry.ws_backpressure(queued, "outbound_queue", state.id)
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
        SendReplaceNavigate(path) ->
          send_or_stop(state, ServerReplaceNavigate(path: path))
        SendHardNavigate(path) ->
          send_or_stop(state, ServerHardNavigate(path: path))
        SendTitle(title) -> send_or_stop(state, ServerTitle(title: title))
        CloseForBackpressure(reason) -> {
          log.warning(
            "brazier.transport",
            "Closing slow connection " <> ctx(state) <> ": " <> reason,
          )
          telemetry.ws_backpressure(queued, "runtime", state.id)
          case send_ws_message(state, ServerError(reason: reason)) {
            Ok(sent_state) ->
              Stop(
                sent_state,
                SendClose(ws.close_try_again_later, "backpressure"),
                "backpressure: " <> reason,
              )
            Error(send_reason) ->
              Stop(
                state,
                NoCloseFrame("send_failed"),
                "send failed: " <> send_reason,
              )
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
  log.info("brazier.transport", "Connection closed (cleanup): " <> ctx(state))
  cancel_timer(state.ping_timer)
  cancel_timer(state.pong_timer)
  cancel_timer(state.idle_timer)
  cancel_timer(state.auth_timer)
  ws.release_ip_slot()
  let conn_count = connection_tracker_decrement()
  log.debug(
    "brazier.transport",
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
    "brazier.transport",
    "Closing WebSocket " <> ctx(state) <> ": " <> reason,
  )
  let frame = case action {
    SendClose(code: code, reason: close_reason) ->
      Some(ws.encode_close(code, close_reason))
    EchoClose(code: Some(code)) -> Some(ws.encode_close(code, ""))
    EchoClose(code: None) -> Some(ws.encode_empty_close())
    NoCloseFrame(label: _) -> None
  }
  let state = case frame {
    Some(bytes) ->
      case send_counted(state, bytes) {
        Ok(sent_state) -> sent_state
        Error(send_reason) -> {
          log.warning(
            "brazier.transport",
            "Failed to send close frame to "
              <> ctx(state)
              <> ": "
              <> send_reason,
          )
          state
        }
      }
    None -> state
  }
  server.close(state.socket)
  let #(close_code, close_label) = close_summary(action)
  telemetry.ws_close(
    erlang_monotonic_time() - state.opened_at,
    state.frames_in,
    state.frames_out,
    state.bytes_in,
    state.bytes_out,
    close_code,
    close_label,
    state.id,
  )
  cleanup_connection(state)
}

/// The close code and fixed reason label `[brazier, ws, close]` reports.
/// A sent close reports its code and its (constant) reason in snake_case;
/// a peer close reports the peer's code, or 1005 (no status received,
/// RFC 6455 7.1.5) when it had none; a connection that ended without a
/// close frame reports 1006 (abnormal closure) and its cause.
fn close_summary(action: CloseAction) -> #(Int, String) {
  case action {
    // Every close reason is a literal, so this is a fixed label set:
    // "invalid utf-8" becomes "invalid_utf8".
    SendClose(code: code, reason: reason) -> #(
      code,
      reason |> string.replace(" ", "_") |> string.replace("-", ""),
    )
    EchoClose(code: Some(code)) -> #(code, "peer_close")
    EchoClose(code: None) -> #(close_no_status, "peer_close")
    NoCloseFrame(label: label) -> #(close_abnormal, label)
  }
}

/// RFC 6455 7.4.1: no status code was present (never sent on the wire).
const close_no_status = 1005

/// RFC 6455 7.4.1: the connection closed without a close frame (never sent
/// on the wire).
const close_abnormal = 1006

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

/// Under `brazier/dev`, subscribe this handler to the dev reload topic, so a
/// rebuild reaches the page as a `reload` message (`ws.DevReload`). Outside
/// dev mode nothing subscribes. The subscription ends when the handler
/// process exits: PubSub is linked to its subscribers.
///
/// A subscription that fails means PubSub is down or refused it, and the
/// page would silently miss every reload, so the connection closes with
/// 1011 instead and the client reconnects with backoff.
fn subscribe_dev_reload(state: ConnectionState) -> Next {
  case dev_live_reload_enabled() {
    False -> Continue(state)
    True -> {
      let topic = dev_live_reload_topic()
      case pubsub.try_subscribe(topic) {
        Ok(Nil) -> {
          log.debug(
            "brazier.transport",
            ctx(state) <> " listens for dev reloads on " <> topic,
          )
          Continue(state)
        }
        Error(reason) -> {
          log.error(
            "brazier.transport",
            "Cannot subscribe "
              <> ctx(state)
              <> " to dev reloads on "
              <> topic
              <> ", closing with 1011: "
              <> string.inspect(reason),
          )
          Stop(
            state,
            SendClose(ws.close_internal_error, "internal error"),
            "dev reload subscription failed",
          )
        }
      }
    }
  }
}

/// True only in a VM where `brazier/dev` started the app.
@external(erlang, "brazier_dev_ffi", "live_reload_enabled")
fn dev_live_reload_enabled() -> Bool

@external(erlang, "brazier_dev_ffi", "live_reload_topic")
fn dev_live_reload_topic() -> String

/// Identity of an admitted connection, carried from admission to startup.
type Admission {
  /// `page` is the page the upgrade mounts (`get_upgrade_page`), which passed
  /// the middleware gate.
  Admission(conn_id: ConnectionId, peer_ip: String, page: LivePage)
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
  let opened_at = erlang_monotonic_time()
  log.info(
    "brazier.transport",
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
          request: req,
          ws_auth: config.ws_auth,
          middlewares: config.middlewares,
          page: admission.page,
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
          opened_at: opened_at,
          frames_in: 0,
          frames_out: 0,
          bytes_in: 0,
          bytes_out: 0,
        )

      case subscribe_dev_reload(state) {
        Continue(state) -> {
          // Start receiving TCP data
          server.set_active_once(socket)
          // Enter the receive loop — returns after close and cleanup
          ws_loop(state, subject)
        }
        Stop(state: final_state, action: action, reason: reason) ->
          stop_connection(final_state, action, reason)
      }
    }
    Error(startup_error) -> {
      let #(close_code, close_reason, close_label) =
        startup_close(startup_error)
      let message =
        "Closing WebSocket "
        <> conn_id
        <> " (peer "
        <> admission.peer_ip
        <> ") with "
        <> int.to_string(close_code)
        <> " after the runtime did not start: "
        <> startup_error_to_string(startup_error)
      // The cause (a crash with its stacktrace, a refusal at the level its
      // status calls for) was logged once where it happened, with this
      // connection's id; this line records the close that answers it.
      log.info("brazier.transport", message)
      let close_frame = ws.encode_close(close_code, close_reason)
      let #(frames_out, bytes_out) = case
        server.send_bytes(socket, close_frame)
      {
        Ok(Nil) -> #(1, bit_array.byte_size(close_frame))
        Error(send_reason) -> {
          log.warning(
            "brazier.transport",
            "Failed to send close frame after startup failure for "
              <> conn_id
              <> ": "
              <> send_reason,
          )
          #(0, 0)
        }
      }
      server.close(socket)
      telemetry.ws_close(
        erlang_monotonic_time() - opened_at,
        0,
        frames_out,
        0,
        bytes_out,
        close_code,
        close_label,
        conn_id,
      )
      ws.release_ip_slot()
      let conn_count = connection_tracker_decrement()
      log.debug(
        "brazier.transport",
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
    other -> Error("unsupported scheme " <> string.inspect(other))
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

/// The errors of `parse_origin`, `parse_authority` and `parse_port` end up
/// in log lines and quote any client text they repeat (SEC-11).
fn parse_port(text: String) -> Result(Int, String) {
  case int.parse(text) {
    Ok(port) if port >= 1 && port <= 65_535 -> Ok(port)
    _ -> Error("invalid port " <> string.inspect(text))
  }
}

/// The scheme the client used to reach us. X-Forwarded-Proto is honoured
/// only from a trusted proxy (`brazier/transport/client`); otherwise plain
/// http (Brazier itself does not terminate TLS).
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

/// The `ws_allowed_origins` of a listener, parsed once when it starts.
pub opaque type AllowedOrigins {
  AllowedOrigins(origins: List(Origin))
}

/// Parse `ws_allowed_origins` entries; each must be a bare
/// `scheme://host[:port]` origin (http or https, no path).
pub fn parse_allowed_origins(
  entries: List(String),
) -> Result(AllowedOrigins, String) {
  let parsed =
    list.try_map(entries, fn(entry) {
      case parse_origin(entry) {
        Ok(Origin(has_path: False, ..) as origin) -> Ok(origin)
        Ok(Origin(has_path: True, ..)) ->
          Error(
            "ws_allowed_origins entry must not contain a path: "
            <> string.inspect(entry),
          )
        Error(reason) ->
          Error(
            "invalid ws_allowed_origins entry "
            <> string.inspect(entry)
            <> ": "
            <> reason,
          )
      }
    })
  case parsed {
    Ok(origins) -> {
      log.debug(
        "brazier.transport",
        "Allowed origins parsed: "
          <> int.to_string(list.length(origins))
          <> " extra origin(s)",
      )
      Ok(AllowedOrigins(origins: origins))
    }
    Error(reason) -> {
      log.warning(
        "brazier.transport",
        "Refusing ws_allowed_origins: " <> reason,
      )
      Error(reason)
    }
  }
}

/// The `allowed_hosts` of a listener, parsed once when it starts
/// (Django's `ALLOWED_HOSTS`, SEC-16).
pub opaque type AllowedHosts {
  AllowedHosts(patterns: List(HostPattern))
}

type HostPattern {
  /// `*`: every host.
  AnyHost
  /// `example.com`: that host only.
  ExactHost(host: String)
  /// `.example.com`: the domain and every subdomain.
  HostAndSubdomains(domain: String)
}

/// The hosts a development server answers to when `allowed_hosts` is
/// empty: Django's development default.
pub const development_allowed_hosts = [".localhost", "127.0.0.1", "[::1]"]

/// Parse `allowed_hosts`. An empty list is refused in production (the
/// error names the setting) and means `development_allowed_hosts`
/// otherwise.
@internal
pub fn parse_allowed_hosts(
  entries: List(String),
  production production: Bool,
) -> Result(AllowedHosts, String) {
  let parsed = case entries, production {
    [], True ->
      Error(
        "allowed_hosts is empty: in production (BRAZIER_ENV=production) set "
        <> "SecurityLimits.allowed_hosts to the host names this server "
        <> "answers to, such as [\"example.com\", \".example.com\"]",
      )
    [], False -> {
      log.info(
        "brazier.transport",
        "allowed_hosts is empty: answering only to "
          <> string.join(development_allowed_hosts, ", ")
          <> " (development default; set allowed_hosts to serve other names)",
      )
      list.try_map(development_allowed_hosts, parse_host_pattern)
    }
    _, _ -> list.try_map(entries, parse_host_pattern)
  }
  case parsed {
    Ok(patterns) -> {
      case list.contains(patterns, AnyHost) {
        True ->
          log.warning(
            "brazier.transport",
            "allowed_hosts contains \"*\": the Host header is not checked, "
              <> "so DNS rebinding is not prevented",
          )
        False ->
          log.debug(
            "brazier.transport",
            "Allowed hosts parsed: "
              <> int.to_string(list.length(patterns))
              <> " pattern(s)",
          )
      }
      Ok(AllowedHosts(patterns: patterns))
    }
    Error(reason) -> {
      log.warning("brazier.transport", "Refusing allowed_hosts: " <> reason)
      Error(reason)
    }
  }
}

fn parse_host_pattern(entry: String) -> Result(HostPattern, String) {
  let refuse = fn(why) {
    Error(
      "invalid allowed_hosts entry " <> string.inspect(entry) <> ": " <> why,
    )
  }
  case entry {
    "*" -> Ok(AnyHost)
    "." <> domain ->
      case check_host_name(domain) {
        Ok(name) -> Ok(HostAndSubdomains(domain: name))
        Error(why) -> refuse(why)
      }
    _ ->
      case check_host_name(entry) {
        Ok(name) -> Ok(ExactHost(host: name))
        Error(why) -> refuse(why)
      }
  }
}

/// A bare host name for `allowed_hosts`, lowercased: no scheme, path, port,
/// wildcard or trailing dot.
fn check_host_name(name: String) -> Result(String, String) {
  case string.contains(name, "/"), string.contains(name, "*") {
    True, _ -> Error("a host name has no scheme or path")
    _, True ->
      Error(
        "\"*\" is allowed only on its own; use \".example.com\" for a domain "
        <> "and its subdomains",
      )
    False, False -> {
      use #(host, _port) <- result.try(parse_authority(name, 0))
      case host == string.lowercase(name), string.ends_with(host, ".") {
        False, _ -> Error("a host name has no port")
        True, True -> Error("drop the trailing dot")
        True, False -> Ok(host)
      }
    }
  }
}

fn host_matches(pattern: HostPattern, host: String) -> Bool {
  case pattern {
    AnyHost -> True
    ExactHost(host: name) -> name == host
    HostAndSubdomains(domain: domain) ->
      host == domain || string.ends_with(host, "." <> domain)
  }
}

/// Check a Host header value against `allowed_hosts`. The port is not
/// compared, and one trailing dot (`example.com.`) is dropped, as Django
/// does.
@internal
pub fn host_allowed(
  host: String,
  allowed: AllowedHosts,
) -> Result(Nil, String) {
  let decision = {
    use #(name, _port) <- result.try(
      parse_authority(host, 0)
      |> result.map_error(fn(reason) { "invalid Host: " <> reason }),
    )
    let name = case string.ends_with(name, ".") {
      True -> string.drop_end(name, 1)
      False -> name
    }
    case list.any(allowed.patterns, host_matches(_, name)) {
      True -> Ok(Nil)
      False -> Error("Host is not in allowed_hosts")
    }
  }
  case decision {
    Ok(Nil) -> Ok(Nil)
    Error(reason) -> {
      log.warning(
        "brazier.transport",
        "Host rejected (" <> reason <> "): host=" <> string.inspect(host),
      )
      Error(reason)
    }
  }
}

/// The Host check for one request. A request without a Host header got
/// this far only as HTTP/1.0 (`check_framing` refuses HTTP/1.1 without
/// one); it names no host, so there is nothing to refuse, as with
/// Django, which then uses the server's own name (`SERVER_NAME`). Browsers
/// always send Host, so a rebound page cannot use this.
fn check_host(
  req: Request(Connection),
  allowed: AllowedHosts,
) -> Result(Nil, String) {
  case request.get_header(req, "host") {
    Ok(host) -> host_allowed(host, allowed)
    Error(Nil) -> Ok(Nil)
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
  allowed_origins: AllowedOrigins,
) -> Result(Nil, String) {
  case request.get_header(req, "origin") {
    Error(Nil) -> {
      log.warning(
        "brazier.transport",
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
          log.warning("brazier.transport", "Origin check failed: " <> reason)
          Error(reason)
        }
        Ok(scheme) ->
          origin_allowed(origin, scheme, request_host, allowed_origins)
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
  allowed_origins: AllowedOrigins,
) -> Result(Nil, String) {
  let decision = {
    use parsed <- result.try(
      parse_origin(origin)
      |> result.map_error(fn(reason) { "invalid Origin: " <> reason }),
    )
    let same = Origin(..parsed, has_path: False)
    case list.contains(allowed_origins.origins, same) {
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
      log.debug(
        "brazier.transport",
        "Origin allowed: " <> string.inspect(origin),
      )
      Ok(Nil)
    }
    Error(reason) -> {
      // The origin and host are client text: quoted, so a newline or a
      // control character cannot forge a log line (SEC-11).
      log.warning(
        "brazier.transport",
        "Origin rejected ("
          <> reason
          <> "): origin="
          <> string.inspect(origin)
          <> " scheme="
          <> request_scheme
          <> " host="
          <> string.inspect(request_host),
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
  log.debug(
    "brazier.transport",
    "Checking origin against host " <> string.inspect(request_host),
  )
  origin_allowed(origin, "http", request_host, AllowedOrigins(origins: []))
}

/// How a WebSocket upgrade request ended: upgraded (the 101 was written
/// and the connection starts) or refused with a fixed snake_case label,
/// the `result` of the `[brazier, ws, upgrade]` span.
type UpgradeOutcome {
  Upgraded(admission: Admission)
  Refused(label: String)
}

fn upgrade_outcome_label(outcome: UpgradeOutcome) -> String {
  case outcome {
    Upgraded(admission: _) -> "ok"
    Refused(label: label) -> label
  }
}

/// Handle a WebSocket upgrade request on a raw socket.
/// Admission order: global cap, per-IP cap, origin, auth, then RFC 6455
/// handshake validation. Every rejection is logged with the connection id
/// and peer address and releases what was acquired.
fn handle_ws_request(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
  guards: Guards,
  page: LivePage,
) -> UpgradeOutcome {
  let conn_id = generate_connection_id()
  // The limits were validated once, when the listener started
  // (`prepare_listener` refuses to build a handler otherwise), and this
  // function is reachable only through that handler.
  case ws_client_ip(socket, req, config.security_limits) {
    Error(reason) -> {
      // The peer is already gone: nobody to answer.
      log.warning(
        "brazier.transport",
        "WebSocket upgrade " <> conn_id <> " dropped: " <> reason,
      )
      server.close(socket)
      release_connection_slot("peer gone before upgrade")
      Refused("peer_gone")
    }
    Ok(peer_ip) ->
      admit_ws_request(
        socket,
        req,
        config,
        guards,
        Admission(conn_id:, peer_ip:, page:),
      )
  }
}

fn admit_ws_request(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
  guards: Guards,
  admission: Admission,
) -> UpgradeOutcome {
  let Admission(conn_id:, peer_ip:, page: _) = admission
  let limits = config.security_limits
  let current_count = connection_tracker_count()
  case current_count > limits.max_connections {
    True ->
      reject_ws_request(
        "rejected_connection_limit",
        socket,
        conn_id,
        peer_ip,
        False,
        503,
        "Too many connections",
        "global connection limit reached ("
          <> int.to_string(current_count)
          <> "/"
          <> int.to_string(limits.max_connections)
          <> ")",
      )
    // The slots belong to this listener's connection owner, so two
    // listeners in one VM never share per-IP counts.
    False -> acquire_ws_slot(socket, req, config, guards, admission)
  }
}

fn acquire_ws_slot(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
  guards: Guards,
  admission: Admission,
) -> UpgradeOutcome {
  let Admission(conn_id:, peer_ip:, page: _) = admission
  let limits = config.security_limits
  case ws.acquire_ip_slot(peer_ip, limits.max_ws_connections_per_ip) {
    Error(count) ->
      reject_ws_request(
        "rejected_ip_limit",
        socket,
        conn_id,
        peer_ip,
        False,
        429,
        "Too many connections from this address",
        "per-IP WebSocket limit reached (" <> int.to_string(count) <> ")",
      )
    Ok(_count) -> authorize_ws_request(socket, req, config, guards, admission)
  }
}

fn authorize_ws_request(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
  guards: Guards,
  admission: Admission,
) -> UpgradeOutcome {
  let reject = fn(label, status, body, reason) {
    reject_ws_request(
      label,
      socket,
      admission.conn_id,
      admission.peer_ip,
      True,
      status,
      body,
      reason,
    )
  }
  case check_origin(req, config.security_limits, guards.origins) {
    Error(reason) ->
      reject(
        "rejected_origin",
        403,
        "Forbidden: " <> reason,
        "origin: " <> reason,
      )
    Ok(Nil) -> {
      let auth_ok = case config.ws_auth {
        Some(auth_fn) -> auth_fn(req)
        None -> Ok(Nil)
      }
      case auth_ok {
        Error(reason) ->
          reject(
            "rejected_auth",
            401,
            "Unauthorized: " <> reason,
            "ws_auth: " <> reason,
          )
        Ok(Nil) ->
          case ws.validate_upgrade(req) {
            Error(error) -> {
              let description = ws.get_upgrade_error_reason(error)
              case ws.get_upgrade_error_status(error) {
                426 ->
                  reject_unsupported_version(socket, admission, description)
                status ->
                  reject(
                    "rejected_handshake",
                    status,
                    description,
                    "handshake: " <> description,
                  )
              }
            }
            Ok(client_key) ->
              upgrade_ws_request(socket, config, admission, client_key)
          }
      }
    }
  }
}

fn upgrade_ws_request(
  socket: Socket,
  config: TransportConfig,
  admission: Admission,
  client_key: String,
) -> UpgradeOutcome {
  let upgraded = {
    use _ <- result.try(ws.set_send_timeout(
      socket,
      config.security_limits.ws_send_timeout_ms,
    ))
    ws.send_upgrade_response(socket, client_key)
  }
  case upgraded {
    Ok(Nil) -> Upgraded(admission)
    Error(reason) -> {
      log.warning(
        "brazier.transport",
        "WebSocket upgrade failed for "
          <> admission.conn_id
          <> " (peer "
          <> admission.peer_ip
          <> "): "
          <> reason,
      )
      server.close(socket)
      ws.release_ip_slot()
      release_connection_slot("upgrade write failed")
      Refused("upgrade_write_failed")
    }
  }
}

/// 426 Upgrade Required must advertise the supported version (§4.4).
fn reject_unsupported_version(
  socket: Socket,
  admission: Admission,
  description: String,
) -> UpgradeOutcome {
  log.warning(
    "brazier.transport",
    "WebSocket upgrade rejected for "
      <> admission.conn_id
      <> " (peer "
      <> admission.peer_ip
      <> ") status 426: "
      <> description,
  )
  ws.release_ip_slot()
  release_connection_slot("unsupported WebSocket version")
  let resp =
    response.new(426)
    |> response.set_header("sec-websocket-version", "13")
    |> response.set_body(Bytes(bytes_tree.from_string(description)))
  case transport_http.write_response(socket, resp) {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.warning(
        "brazier.transport",
        "Failed to write 426 response for "
          <> admission.conn_id
          <> ": "
          <> reason,
      )
  }
  server.close(socket)
  Refused("rejected_version")
}

/// Reject an upgrade: log with context, release the per-IP slot (if one
/// was taken) and the global count, answer with an HTTP error and close.
/// `label` is the upgrade span's `result`.
fn reject_ws_request(
  label: String,
  socket: Socket,
  conn_id: ConnectionId,
  peer_ip: String,
  holds_slot: Bool,
  status: Int,
  body: String,
  reason: String,
) -> UpgradeOutcome {
  log.warning(
    "brazier.transport",
    "WebSocket upgrade rejected for "
      <> conn_id
      <> " (peer "
      <> peer_ip
      <> ") status "
      <> int.to_string(status)
      <> ": "
      <> reason,
  )
  case holds_slot {
    True -> ws.release_ip_slot()
    False -> Nil
  }
  release_connection_slot("WebSocket request rejected")
  transport_http.write_error(socket, status, body)
  Refused(label)
}

// --- HTTP Handler ---

/// Create the HTTP handler for non-WebSocket requests.
/// Handles: API routes, static files, client JS, health check, SSR pages.
/// API handler runs first — if it returns Some(response), that's used.
/// Otherwise falls through to static files, brazier_client.js, health, SSR.
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

/// Route a request through framework handlers: brazier_client.js, health, static, SSR.
/// Paths are matched exactly (no segment normalisation), and framework
/// assets answer only GET and HEAD.
fn route_framework_request(
  config: TransportConfig,
  req: Request(Connection),
) -> response.Response(ResponseBody) {
  case req.path {
    "/health" -> {
      transport_http.tag_route("/health")
      when_readable_method(req, fn() {
        response.new(200)
        |> response.set_header("content-type", "application/json")
        |> response.set_header("cache-control", "no-store")
        |> response.set_body(
          Bytes(bytes_tree.from_string("{\"status\":\"ok\"}")),
        )
      })
    }
    "/brazier_client.js" -> {
      transport_http.tag_route("/brazier_client.js")
      when_readable_method(req, fn() { serve_client_js(req) })
    }
    "/brazier_client_" <> _ -> {
      let name = string.drop_start(req.path, 1)
      // Only exact build output names are read from the assets directory;
      // anything else is an ordinary path.
      case static.is_client_bundle_name(name) {
        True -> {
          transport_http.tag_route(client_bundle_route)
          when_readable_method(req, fn() { serve_hashed_client_js(name, req) })
        }
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
    transport_http.tag_route(page_route)
    serve_page_or_ssr(config.page_html, config.ssr_factory, req)
  }
  case config.static_config {
    None -> page()
    Some(static_cfg) ->
      case static.matches_prefix(static_cfg, req.path) {
        False -> page()
        True -> {
          // Tagged before the method check, so a 405 is reported on the
          // static route too. A path under the prefix names a file or
          // nothing: a miss is 404, never a page, so a missing script or
          // stylesheet is not answered with HTML.
          transport_http.tag_route(static.route_pattern(static_cfg))
          when_readable_method(req, fn() {
            case
              static.serve_with_etag_check(
                static_cfg,
                req.path,
                header_or_empty(req, "if-none-match"),
              )
            {
              Ok(resp) -> resp
              Error(Nil) -> {
                log.debug(
                  "brazier.transport",
                  "404 for missing static file " <> log_path.describe(req.path),
                )
                transport_http.create_error_response(404, "Not Found")
              }
            }
          })
        }
      }
  }
}

/// Telemetry route of the hashed client bundle (`/brazier_client_<hash>.js`).
const client_bundle_route = "/brazier_client_:hash"

/// Telemetry route of every page request. Pages are routed by the app's
/// typed router, which has no patterns, so all pages share one label.
pub const page_route = "/*"

/// Telemetry route of the WebSocket endpoint.
pub const ws_route = "/ws"

/// Run `serve` for GET and HEAD; any other method gets 405 (RFC 9110 §15.5.6).
fn when_readable_method(
  req: Request(Connection),
  serve: fn() -> response.Response(ResponseBody),
) -> response.Response(ResponseBody) {
  case req.method {
    http.Get | http.Head -> serve()
    method -> {
      log.debug(
        "brazier.transport",
        "405 for "
          <> http.method_to_string(method)
          <> " on framework asset "
          <> log_path.describe(req.path),
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
/// Middleware runs on every HTTP request before routing; a `/ws` upgrade
/// runs it on a GET of the page it mounts (`decide_ws_upgrade`).
///
/// The connection slot is owned by the listener's connection owner, which
/// releases it when this process exits, so there is no manual bookkeeping
/// on the HTTP path.
fn per_connection_handler(
  socket: Socket,
  config: TransportConfig,
  guards: Guards,
  handler: fn(Request(Connection)) -> response.Response(ResponseBody),
) -> Nil {
  log.debug("brazier.transport", "Connection handler started")
  serve_requests(socket, config, guards, handler, 0)
}

fn serve_requests(
  socket: Socket,
  config: TransportConfig,
  guards: Guards,
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
            "brazier.transport",
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
            ["ws"] -> serve_ws_request(socket, req, framing, config, guards)
            _ ->
              case check_host(req, guards.hosts) {
                // DNS rebinding: a page served under another name would be
                // same-origin with the attacker's site (SEC-16).
                Error(reason) ->
                  transport_http.write_error(
                    socket,
                    400,
                    "Bad Request: " <> reason,
                  )
                Ok(Nil) ->
                  serve_http_request(
                    socket,
                    req,
                    version,
                    framing,
                    config,
                    guards,
                    handler,
                    served,
                  )
              }
          }
      }
  }
}

/// Route a /ws request: middleware, then the WebSocket upgrade. The
/// connection never returns to the HTTP loop afterwards.
///
/// The `[brazier, ws, upgrade]` span covers the decision, from the request
/// head to the 101 or the refusal; the connection itself runs after the
/// span has ended.
fn serve_ws_request(
  socket: Socket,
  req: Request(Connection),
  framing: transport_http.BodyFraming,
  config: TransportConfig,
  guards: Guards,
) -> Nil {
  let outcome =
    telemetry.ws_upgrade_span(ws_route, fn() {
      let outcome = decide_ws_upgrade(socket, req, framing, config, guards)
      #(outcome, upgrade_outcome_label(outcome))
    })
  case outcome {
    Upgraded(admission) -> start_ws_connection(socket, config, req, admission)
    Refused(label) ->
      log.debug("brazier.transport", "WebSocket upgrade refused: " <> label)
  }
}

fn decide_ws_upgrade(
  socket: Socket,
  req: Request(Connection),
  framing: transport_http.BodyFraming,
  config: TransportConfig,
  guards: Guards,
) -> UpgradeOutcome {
  case check_host(req, guards.hosts) {
    // DNS rebinding: an attacker's name resolving to this server sends a
    // matching Origin and Host, which the origin check alone accepts
    // (SEC-16).
    Error(reason) -> {
      transport_http.write_error(socket, 400, "Bad Request: " <> reason)
      Refused("rejected_host")
    }
    Ok(Nil) -> decide_ws_framing(socket, req, framing, config, guards)
  }
}

fn decide_ws_framing(
  socket: Socket,
  req: Request(Connection),
  framing: transport_http.BodyFraming,
  config: TransportConfig,
  guards: Guards,
) -> UpgradeOutcome {
  case framing.content_length, transport_http.get_buffered_byte_count(socket) {
    0, 0 ->
      case get_upgrade_page(req) {
        Error(reason) -> {
          log.warning(
            "brazier.transport",
            "Rejecting WebSocket upgrade with 400: " <> reason,
          )
          transport_http.write_error(
            socket,
            400,
            "The WebSocket URL must name its page: /ws?path=<page path>",
          )
          Refused("rejected_path")
        }
        // The middleware gate the dead render of that page passed: the
        // pipeline runs on the page's GET, not on the /ws request (SEC-2).
        Ok(page) ->
          case check_middleware(page_request(req, page), config.middlewares) {
            Ok(Nil) -> handle_ws_request(socket, req, config, guards, page)
            Error(resp) -> {
              log.warning(
                "brazier.transport",
                "Refusing WebSocket upgrade for page "
                  <> log_path.describe(page.path)
                  <> ": the middleware answered "
                  <> int.to_string(resp.status),
              )
              case transport_http.write_response(socket, resp) {
                Ok(Nil) -> Nil
                Error(reason) ->
                  log.error(
                    "brazier.transport",
                    "Failed to write middleware rejection: " <> reason,
                  )
              }
              transport_http.close_gracefully(socket)
              Refused("rejected_middleware")
            }
          }
      }
    0, buffered -> {
      // RFC 6455 4.1: the client must wait for the handshake response
      // before sending frames. The frame reader starts from the socket, so
      // bytes already buffered here would be silently lost.
      log.warning(
        "brazier.transport",
        "Rejecting WebSocket upgrade: client sent "
          <> int.to_string(buffered)
          <> " bytes before the handshake completed",
      )
      transport_http.write_error(
        socket,
        400,
        "Data received before the WebSocket handshake completed",
      )
      Refused("rejected_early_data")
    }
    length, _ -> {
      // Body bytes after an upgrade request would be parsed as WebSocket
      // frames; refuse instead.
      log.warning(
        "brazier.transport",
        "Rejecting WebSocket upgrade request with a "
          <> int.to_string(length)
          <> " byte body",
      )
      transport_http.write_error(
        socket,
        400,
        "WebSocket upgrade requests must not have a body",
      )
      Refused("rejected_body")
    }
  }
}

fn serve_http_request(
  socket: Socket,
  req: Request(Connection),
  version: transport_http.HttpVersion,
  framing: transport_http.BodyFraming,
  config: TransportConfig,
  guards: Guards,
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
  // Classified without reading: the response goes out first, and a small
  // leftover body is discarded only after it (see `check_body`).
  let body = transport_http.check_body(socket, discard_limit)
  case result {
    Error(_) -> {
      // run_handler already logged the crash with its stacktrace.
      let resp =
        transport_http.create_error_response(500, "Internal Server Error")
      case write_response_for(socket, req, version, resp, False) {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.warning(
            "brazier.transport",
            "Failed to write 500 after handler crash: " <> reason,
          )
      }
      close_after_response(socket, body)
    }
    Ok(resp) -> {
      let served = served + 1
      let keep_alive =
        decide_keep_alive(req, version, resp, body, served, limits)
      case write_response_for(socket, req, version, resp, keep_alive) {
        Error(reason) -> {
          log.error(
            "brazier.transport",
            "Failed to write response, closing connection: " <> reason,
          )
          server.close(socket)
        }
        Ok(Nil) ->
          case keep_alive {
            True ->
              case transport_http.finish_body(socket, body) {
                transport_http.BodyConsumed ->
                  serve_requests(socket, config, guards, handler, served)
                // finish_body logged why the leftover could not be read.
                transport_http.BodyDiscardable(_)
                | transport_http.BodyUnread(_)
                | transport_http.BodyFailed ->
                  transport_http.close_gracefully(socket)
              }
            False -> close_after_response(socket, body)
          }
      }
    }
  }
}

/// End a connection whose response has been written: the body context is
/// closed without reading the leftover, which `close_gracefully` drains
/// until the peer closes or its linger bound is reached.
fn close_after_response(
  socket: Socket,
  body: transport_http.BodyOutcome,
) -> Nil {
  transport_http.abandon_body(socket, body)
  transport_http.close_gracefully(socket)
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
        "brazier.transport",
        "Closing connection: handler left "
          <> int.to_string(remaining)
          <> " request body bytes unread",
      )
      False
    }
    _, _, transport_http.BodyFailed, _ -> {
      log.info(
        "brazier.transport",
        "Closing connection after a failed request body read",
      )
      False
    }
    // A discardable leftover is read after the response (`finish_body`); it
    // does not stop reuse unless that read fails.
    _, _, transport_http.BodyConsumed, True
    | _, _, transport_http.BodyDiscardable(_), True
    -> {
      log.info(
        "brazier.transport",
        "Closing connection after "
          <> int.to_string(served)
          <> " requests (max_keepalive_requests)",
      )
      False
    }
    True, False, transport_http.BodyConsumed, False
    | True, False, transport_http.BodyDiscardable(_), False
    ->
      case drain_requested() {
        True -> {
          log.info(
            "brazier.transport",
            "Closing connection after this response: the listener is stopping",
          )
          False
        }
        False -> True
      }
  }
}

/// Whether the listener asked this connection to drain (see
/// `brazier_http_conns`). Runs only in a connection handler, as
/// `serve_requests` does.
@external(erlang, "brazier_http_conns", "drain_requested")
fn drain_requested() -> Bool

/// `OPTIONS *` (RFC 9110 9.3.7) asks about the server as a whole.
fn asterisk_options_response(
  _req: Request(Connection),
) -> response.Response(ResponseBody) {
  transport_http.tag_route("*")
  log.debug("brazier.transport", "Answering OPTIONS *")
  response.new(204)
  |> response.set_header("allow", allowed_methods_header)
  |> response.set_body(Bytes(bytes_tree.new()))
}

/// The page a live connection mounts or navigates to: a same-origin path
/// and its query.
pub type LivePage {
  LivePage(path: String, query: Option(String))
}

/// The page a WebSocket upgrade request mounts: the path and query in its
/// `path` query parameter (`/ws?path=%2Fusers%2F7%3Ftab%3Dposts`), which the
/// client sets to its own `location.pathname + location.search`. The first
/// `path` parameter counts. It is refused when it is missing, is not a
/// same-origin path (`internal/local_path`, the rule `router.push` uses) or
/// does not parse.
///
/// The transport gates the upgrade on this page and the runtime mounts it,
/// so both read the same page.
pub fn get_upgrade_page(req: Request(Connection)) -> Result(LivePage, String) {
  use pairs <- result.try(
    request.get_query(req)
    |> result.replace_error("the WebSocket URL's query string does not parse"),
  )
  use page_path <- result.try(
    list.key_find(pairs, "path")
    |> result.replace_error(
      "the WebSocket URL has no path parameter (expected /ws?path=<page path>)",
    ),
  )
  to_live_page(page_path)
}

/// The page a client-supplied same-origin path names (a join, a
/// navigation, the `path` of an upgrade). Its fragment is dropped.
fn to_live_page(page_path: String) -> Result(LivePage, String) {
  case local_path.check(page_path) {
    Error(reason) ->
      Error(
        "the page path "
        <> log_path.describe(page_path)
        <> " is not a same-origin path: "
        <> reason,
      )
    Ok(Nil) ->
      case uri.parse(page_path) {
        Ok(parsed) -> Ok(LivePage(path: parsed.path, query: parsed.query))
        Error(Nil) ->
          Error(
            "the page path "
            <> log_path.describe(page_path)
            <> " does not parse",
          )
      }
  }
}

/// The GET the dead render of `page` would have served, as the middleware
/// gate sees it: `req` (the upgrade request) with the page's path and query
/// and the method GET. Its headers stay, so the cookies, `Authorization`
/// and forwarding headers a middleware reads are the connection's own; so
/// do `Upgrade: websocket` and the `Sec-WebSocket-*` headers.
fn page_request(
  req: Request(Connection),
  page: LivePage,
) -> Request(Connection) {
  request.Request(..req, method: http.Get, path: page.path, query: page.query)
}

/// Run middleware on a request and check if it short-circuits.
/// Returns Ok(Nil) if middleware passes through, Error(resp) if it rejects.
/// A crashing middleware rejects the request with 500.
///
/// This is the gate on live mounts and navigations (SEC-2): it runs on the
/// page's GET (`page_request`), never on the `/ws` request itself, inside a
/// `[brazier, http, request]` span tagged with the `/ws` route.
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
      // Tag before the middleware runs, so a middleware that answers the
      // upgrade itself is still reported on the /ws route.
      let tagged = fn(req) {
        transport_http.tag_route(ws_route)
        piped(req)
      }
      case transport_http.run_handler(tagged, req) {
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
        <> "<html><head><meta charset=\"utf-8\"><title>Brazier</title>"
        <> "</head><body>"
        <> "<div id=\"brazier-app\"></div>"
        <> "<script src=\"/"
        <> filename
        <> "\"></script>"
        <> "</body></html>",
      )
  }
}

/// The bundle file named by `brazier_client.manifest` in `assets_dir`. The
/// name must be exact build output (`static.is_client_bundle_name`), so a
/// damaged manifest can never point the server at another file.
fn get_client_js_filename(assets_dir: String) -> Result(String, String) {
  let manifest_path = assets_dir <> "/brazier_client.manifest"
  case simplifile.read(manifest_path) {
    Ok(contents) -> {
      let name = string.trim(contents)
      case static.is_client_bundle_name(name) {
        True -> Ok(name)
        False -> {
          let reason =
            "brazier_client.manifest at "
            <> manifest_path
            <> " names an invalid bundle "
            <> string.inspect(name)
            <> " — rebuild with `gleam run -m brazier/build`"
          log.error("brazier.transport", reason)
          Error(reason)
        }
      }
    }
    Error(err) -> {
      let reason =
        "No brazier_client.manifest at "
        <> manifest_path
        <> ": "
        <> string.inspect(err)
        <> " — the client JS was not built. Run `gleam run -m brazier/build` first."
      log.error("brazier.transport", reason)
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
        "brazier.transport",
        "Cannot set the SSR join cookie for "
          <> log_path.describe(req.path)
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
  log.error("brazier.transport", "Client JS unavailable: " <> reason)
  response.new(500)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(
    Bytes(bytes_tree.from_string(
      "Client JS not built. Run `gleam run -m brazier/build` first.",
    )),
  )
}

/// `/brazier_client.js`: the current bundle under a stable URL, so it must be
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
            "brazier_client.manifest names " <> name <> " but it does not exist",
          )
      }
    Error(reason) -> client_js_unavailable(reason)
  }
}

/// `/brazier_client_<hash>.js`: content-addressed, cached forever. A name that
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
        "brazier.transport",
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
          log.debug("brazier.transport", "304 for client JS " <> path)
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
    drain_timeout_ms: limits.drain_timeout_ms,
  )
}

/// Start the transport layer — binds to the given port and begins
/// accepting connections. Returns the listener supervisor's Pid.
/// Use `start_listener` to also learn the bound port (for port 0).
pub fn start(
  config: TransportConfig,
) -> Result(process.Pid, error.BrazierError) {
  case start_listener(config) {
    Ok(listener) -> {
      log.debug(
        "brazier.transport",
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
) -> Result(server.Listener, error.BrazierError) {
  use handler_fn <- result.try(prepare_listener(config))
  case server.start(to_listener_options(config), handler_fn) {
    Ok(listener) -> {
      log.info(
        "brazier.transport",
        "Listening on port " <> int.to_string(server.get_port(listener)),
      )
      Ok(listener)
    }
    Error(reason) -> Error(bind_failed(config, reason))
  }
}

/// A child specification that starts the listener under a supervisor (the
/// application's root supervision tree). The configuration is checked when
/// the specification is built, so a bad config fails before any process
/// starts. A restarted listener binds the port of its first start again
/// (with port 0, the port the OS assigned then).
pub fn supervised(
  config: TransportConfig,
) -> Result(supervision.ChildSpecification(server.Listener), error.BrazierError) {
  use handler_fn <- result.try(prepare_listener(config))
  case server.supervised(to_listener_options(config), handler_fn) {
    Ok(spec) -> {
      log.debug(
        "brazier.transport",
        "Listener child specification built for port "
          <> int.to_string(config.port),
      )
      Ok(spec)
    }
    Error(reason) -> Error(bind_failed(config, reason))
  }
}

/// The event rate the Brazier client paces itself for: it sends at most
/// `CLIENT_SEND_BUDGET` (40) events per second so jitter cannot push a
/// server window over this (`SERVER_MAX_EVENTS_PER_SECOND` in
/// `brazier_client/patch.mjs`). The server does not advertise its
/// `max_events_per_second`: the limit is there for clients that do not
/// pace themselves, which an advertisement would not slow down, and
/// LiveView and Phoenix channels advertise no rate limit either. A lower
/// limit is allowed (a deployment may want it) and logged at start.
const client_paced_events_per_second = 50

/// Validate the configuration and build the per-connection handler.
fn prepare_listener(
  config: TransportConfig,
) -> Result(fn(Socket) -> Nil, error.BrazierError) {
  log.info(
    "brazier.transport",
    "Starting on port " <> int.to_string(config.port),
  )
  // Warn if no WebSocket authentication is configured
  case config.ws_auth {
    None ->
      log.warning(
        "brazier.transport",
        "No ws_auth configured — WebSocket connections are unauthenticated. "
          <> "Set ws_auth in TransportConfig to require authentication on upgrade.",
      )
    Some(_) -> Nil
  }
  case
    config.security_limits.max_events_per_second
    < client_paced_events_per_second
  {
    True ->
      log.warning(
        "brazier.transport",
        "max_events_per_second is "
          <> int.to_string(config.security_limits.max_events_per_second)
          <> ", below the "
          <> int.to_string(client_paced_events_per_second)
          <> " the Brazier client paces itself for: a burst of events from an "
          <> "honest client will be rate limited, and repeated bursts close "
          <> "the socket with 1008",
      )
    False -> Nil
  }
  let static_check = case config.static_config {
    Some(static_cfg) -> static.validate_config(static_cfg)
    None -> Ok(Nil)
  }
  let checked =
    check_security_limits(
      config.security_limits,
      production: app_env.is_production(),
    )
  case checked, static_check {
    Error(reason), _ -> {
      log.error("brazier.transport", "Invalid security limits: " <> reason)
      Error(error.ConfigError(reason: "Invalid security limits: " <> reason))
    }
    _, Error(reason) -> {
      log.error("brazier.transport", "Invalid static config: " <> reason)
      Error(error.ConfigError(reason: "Invalid static config: " <> reason))
    }
    Ok(guards), Ok(Nil) -> {
      // Built once: middleware and routing closures, and the parsed hosts
      // and origins, are shared by every connection instead of being
      // rebuilt per request.
      let handler = create_handler(config)
      Ok(fn(socket: Socket) {
        per_connection_handler(socket, config, guards, handler)
      })
    }
  }
}

fn bind_failed(config: TransportConfig, reason: String) -> error.BrazierError {
  log.error(
    "brazier.transport",
    "Failed to start on port " <> int.to_string(config.port) <> ": " <> reason,
  )
  error.TransportError(
    reason: "Failed to bind to port "
    <> int.to_string(config.port)
    <> ": "
    <> reason,
  )
}
