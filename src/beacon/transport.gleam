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
import beacon/pubsub
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
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
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
pub type SecurityLimits {
  SecurityLimits(
    /// Maximum WebSocket message size in bytes. Default: 65536 (64KB).
    max_message_bytes: Int,
    /// Maximum events per second per connection. Default: 50.
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
  )
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
    /// Rate limiting: start of current window (monotonic native time units).
    rate_window_start: Int,
    /// Security limits for this connection (copied from TransportConfig at init).
    security_limits: SecurityLimits,
    /// Heartbeat rate limiting: count in current 1-second window.
    heartbeat_count: Int,
    /// Heartbeat rate limiting: start of current window (monotonic native time units).
    heartbeat_window_start: Int,
    /// WebSocket frame buffer for partial frame reassembly.
    buffer: BitArray,
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

/// Send a ServerMessage over a WebSocket connection.
/// Logs errors but does not crash — the connection may have closed.
fn send_ws_message(state: ConnectionState, msg: ServerMessage) -> Nil {
  let encoded = encode_server_message(msg)
  case server.send_text_frame(state.socket, encoded) {
    Ok(Nil) -> {
      log.debug("beacon.transport", "Sent message to " <> state.id)
      Nil
    }
    Error(_reason) -> {
      log.error(
        "beacon.transport",
        "Failed to send message to " <> state.id <> ": send_text_frame failed",
      )
      Nil
    }
  }
}

/// One second in native time units (nanoseconds on most BEAM VMs).
/// Used for rate limiting window calculations.
const one_second_native = 1_000_000_000

/// Maximum heartbeats per second. Heartbeats beyond this are rejected and logged
/// (no ack sent) to prevent heartbeat flooding.
const max_heartbeats_per_second = 2

/// Maximum number of events in a single batch message.
/// Prevents clients from sending unbounded arrays that consume server memory.
const max_batch_size = 100

/// Check per-connection rate limit: max 50 events per 1-second window.
/// Returns the updated state and whether the event was rate limited.
fn check_rate_limit(state: ConnectionState) -> #(ConnectionState, Bool) {
  let now = erlang_monotonic_time()
  // If more than 1 second has passed, reset the window
  let #(count, window_start) = case
    now - state.rate_window_start > one_second_native
  {
    True -> #(0, now)
    False -> #(state.event_count, state.rate_window_start)
  }
  let new_count = count + 1
  let new_state =
    ConnectionState(
      ..state,
      event_count: new_count,
      rate_window_start: window_start,
    )
  case new_count > state.security_limits.max_events_per_second {
    True -> #(new_state, True)
    False -> #(new_state, False)
  }
}

/// Check heartbeat rate limit: max 2 per second.
/// Returns the updated state and whether the heartbeat was rate limited.
fn check_heartbeat_rate(state: ConnectionState) -> #(ConnectionState, Bool) {
  let now = erlang_monotonic_time()
  let #(count, window_start) = case
    now - state.heartbeat_window_start > one_second_native
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
  case new_count > max_heartbeats_per_second {
    True -> #(new_state, True)
    False -> #(new_state, False)
  }
}

/// Handle an incoming WebSocket text frame.
/// Rejects oversized messages, then decodes and dispatches.
/// Returns the updated connection state.
fn handle_ws_text(state: ConnectionState, text: String) -> ConnectionState {
  let size = string.byte_size(text)
  case size > state.security_limits.max_message_bytes {
    True -> {
      log.warning(
        "beacon.transport",
        "Oversized message from "
          <> state.id
          <> " ("
          <> int.to_string(size)
          <> " bytes) — rejected",
      )
      send_ws_message(state, ServerError(reason: "Message too large"))
      state
    }
    False -> handle_ws_text_decode(state, text)
  }
}

/// Decode and dispatch a validated text message.
/// Applies per-connection rate limiting to non-heartbeat messages.
fn handle_ws_text_decode(
  state: ConnectionState,
  text: String,
) -> ConnectionState {
  case decode_client_message(text) {
    Ok(ClientHeartbeat) -> {
      // Rate-limit heartbeats: max 2 per second to prevent flooding
      let #(new_state, hb_limited) = check_heartbeat_rate(state)
      case hb_limited {
        True -> {
          log.debug(
            "beacon.transport",
            "Heartbeat rate limited for " <> state.id,
          )
          new_state
        }
        False -> {
          log.debug("beacon.transport", "Heartbeat from " <> state.id)
          send_ws_message(new_state, ServerHeartbeatAck)
          new_state
        }
      }
    }
    Ok(ClientEventBatch(events) as msg) -> {
      // Reject oversized batches before any further processing
      let batch_len = list.length(events)
      case batch_len > max_batch_size {
        True -> {
          log.warning(
            "beacon.transport",
            "Batch too large from "
              <> state.id
              <> " ("
              <> int.to_string(batch_len)
              <> " events, max "
              <> int.to_string(max_batch_size)
              <> ")",
          )
          send_ws_message(state, ServerError(reason: "Batch too large"))
          state
        }
        False -> {
          // Check rate limit before dispatching
          let #(new_state, rate_limited) = check_rate_limit(state)
          case rate_limited {
            True -> {
              log.warning(
                "beacon.transport",
                "Rate limited connection "
                  <> state.id
                  <> " ("
                  <> int.to_string(new_state.event_count)
                  <> " events/sec)",
              )
              send_ws_message(new_state, ServerError(reason: "Rate limited"))
              new_state
            }
            False -> {
              log.debug(
                "beacon.transport",
                "Event from "
                  <> new_state.id
                  <> ": "
                  <> client_message_type(msg),
              )
              new_state.on_event(new_state.id, msg)
              new_state
            }
          }
        }
      }
    }
    Ok(msg) -> {
      // Check rate limit before dispatching
      let #(new_state, rate_limited) = check_rate_limit(state)
      case rate_limited {
        True -> {
          log.warning(
            "beacon.transport",
            "Rate limited connection "
              <> state.id
              <> " ("
              <> int.to_string(new_state.event_count)
              <> " events/sec)",
          )
          send_ws_message(new_state, ServerError(reason: "Rate limited"))
          new_state
        }
        False -> {
          log.debug(
            "beacon.transport",
            "Event from " <> new_state.id <> ": " <> client_message_type(msg),
          )
          new_state.on_event(new_state.id, msg)
          new_state
        }
      }
    }
    Error(err) -> {
      let err_str = error.to_string(err)
      log.warning(
        "beacon.transport",
        "Decode error from " <> state.id <> ": " <> err_str,
      )
      send_ws_message(
        state,
        ServerError(reason: "Invalid message: " <> err_str),
      )
      state
    }
  }
}

// --- Frame Processing ---

/// Result of processing buffered WebSocket frames.
type FrameResult {
  /// Continue — state updated, remaining buffer returned.
  FrameContinue(ConnectionState, BitArray)
  /// Close frame received — connection should be closed.
  FrameClose(ConnectionState)
  /// Protocol violation — close immediately instead of buffering forever.
  FrameProtocolError(ConnectionState, String)
}

/// Process all complete frames in the buffer.
/// Loops until no more complete frames can be decoded.
fn process_frames(state: ConnectionState, buffer: BitArray) -> FrameResult {
  case ws.decode_frame(buffer) {
    Ok(#(ws.TextFrame(text), rest)) -> {
      let new_state = handle_ws_text(state, text)
      process_frames(new_state, rest)
    }
    Ok(#(ws.BinaryFrame(_), rest)) -> {
      log.warning(
        "beacon.transport",
        "Unexpected binary frame from " <> state.id,
      )
      process_frames(state, rest)
    }
    Ok(#(ws.CloseFrame, _rest)) -> {
      log.info("beacon.transport", "Close frame from " <> state.id)
      FrameClose(state)
    }
    Ok(#(ws.PingFrame(_data), rest)) -> {
      // Pong is same as ping payload — but for simplicity, skip pong response
      // WebSocket keepalive is handled by our heartbeat protocol instead
      process_frames(state, rest)
    }
    Ok(#(ws.PongFrame(_), rest)) -> {
      // Ignore pong frames
      process_frames(state, rest)
    }
    Error("incomplete") -> {
      // Incomplete frame — keep buffer for next read
      FrameContinue(state, buffer)
    }
    Error(reason) -> {
      log.warning(
        "beacon.transport",
        "WebSocket protocol error from " <> state.id <> ": " <> reason,
      )
      FrameProtocolError(state, reason)
    }
  }
}

// --- WebSocket Connection Lifecycle ---

/// Cleanup a WebSocket connection: decrement tracker, unsub PubSub, call on_close.
fn cleanup_connection(state: ConnectionState) -> Nil {
  log.info("beacon.transport", "Connection closed (cleanup): " <> state.id)
  let conn_count = connection_tracker_decrement()
  log.debug(
    "beacon.transport",
    "Global connections after close: " <> int.to_string(conn_count),
  )
  pubsub.unsubscribe("beacon:patches:" <> state.id)
  state.on_close(state.id)
}

/// WebSocket receive loop — runs in the handler process.
/// Receives TCP data and internal messages via a selector.
/// This function never returns normally — it exits when the connection closes.
fn ws_loop(
  state: ConnectionState,
  subject: process.Subject(InternalMessage),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_other(fn(raw: Dynamic) -> InternalMessage {
      case server.classify_tcp_message(raw) {
        Ok(server.TcpData(data)) -> ReceivedTcpData(data)
        Ok(server.TcpClosed) -> TcpConnectionClosed
        Ok(server.TcpError(reason)) -> TcpConnectionError(reason)
        Error(Nil) -> TcpConnectionError("Unknown message received")
      }
    })
  ws_loop_inner(state, selector)
}

/// Inner loop with cached selector.
fn ws_loop_inner(
  state: ConnectionState,
  selector: process.Selector(InternalMessage),
) -> Nil {
  let msg = process.selector_receive_forever(selector)
  case msg {
    ReceivedTcpData(data) -> {
      let buffer = bit_array.append(state.buffer, data)
      case
        bit_array.byte_size(buffer) > state.security_limits.max_message_bytes
      {
        True -> {
          log.warning(
            "beacon.transport",
            "Buffered WebSocket data exceeded limit for "
              <> state.id
              <> " ("
              <> int.to_string(bit_array.byte_size(buffer))
              <> " bytes)",
          )
          send_ws_message(state, ServerError(reason: "Message too large"))
          server.close(state.socket)
          cleanup_connection(state)
        }
        False -> {
          case process_frames(state, buffer) {
            FrameContinue(new_state, new_buffer) -> {
              server.set_active_once(new_state.socket)
              ws_loop_inner(
                ConnectionState(..new_state, buffer: new_buffer),
                selector,
              )
            }
            FrameClose(close_state) -> {
              case server.send_close_frame(close_state.socket) {
                Ok(Nil) -> Nil
                Error(reason) ->
                  log.warning(
                    "beacon.transport",
                    "Failed to send close frame to "
                      <> close_state.id
                      <> ": "
                      <> reason,
                  )
              }
              server.close(close_state.socket)
              cleanup_connection(close_state)
            }
            FrameProtocolError(error_state, reason) -> {
              case server.send_close_frame(error_state.socket) {
                Ok(Nil) -> Nil
                Error(send_reason) ->
                  log.warning(
                    "beacon.transport",
                    "Failed to send close frame after protocol error for "
                      <> error_state.id
                      <> ": "
                      <> send_reason,
                  )
              }
              log.warning(
                "beacon.transport",
                "Closing connection "
                  <> error_state.id
                  <> " after WebSocket protocol error: "
                  <> reason,
              )
              server.close(error_state.socket)
              cleanup_connection(error_state)
            }
          }
        }
      }
    }
    TcpConnectionClosed -> {
      cleanup_connection(state)
    }
    TcpConnectionError(reason) -> {
      log.error(
        "beacon.transport",
        "TCP error for " <> state.id <> ": " <> reason,
      )
      server.close(state.socket)
      cleanup_connection(state)
    }
    SendMount(payload) -> {
      send_ws_message(state, ServerMount(payload: payload))
      ws_loop_inner(state, selector)
    }
    SendError(reason) -> {
      send_ws_message(state, ServerError(reason: reason))
      ws_loop_inner(state, selector)
    }
    SendModelSync(model_json, version, ack_clock) -> {
      send_ws_message(
        state,
        ServerModelSync(
          model_json: model_json,
          version: version,
          ack_clock: ack_clock,
        ),
      )
      ws_loop_inner(state, selector)
    }
    SendPatch(ops_json, version, ack_clock) -> {
      send_ws_message(
        state,
        ServerPatch(ops_json: ops_json, version: version, ack_clock: ack_clock),
      )
      ws_loop_inner(state, selector)
    }
    SendNavigate(path) -> {
      send_ws_message(state, ServerNavigate(path: path))
      ws_loop_inner(state, selector)
    }
    SendHardNavigate(path) -> {
      send_ws_message(state, ServerHardNavigate(path: path))
      ws_loop_inner(state, selector)
    }
    CloseForBackpressure(reason) -> {
      log.warning(
        "beacon.transport",
        "Closing slow connection " <> state.id <> ": " <> reason,
      )
      send_ws_message(state, ServerError(reason: reason))
      case server.send_close_frame(state.socket) {
        Ok(Nil) -> Nil
        Error(send_reason) ->
          log.warning(
            "beacon.transport",
            "Failed to send close frame to slow connection "
              <> state.id
              <> ": "
              <> send_reason,
          )
      }
      server.close(state.socket)
      cleanup_connection(state)
    }
  }
}

/// Start a WebSocket connection on an already-upgraded socket.
/// Creates the connection state, sets up runtime, and enters the frame loop.
/// This function runs in the handler process and never returns.
/// The HTTP request is passed through so ws_init can read cookies/headers.
fn start_ws_connection(
  socket: Socket,
  config: TransportConfig,
  req: Request(Connection),
) -> Nil {
  let conn_id = generate_connection_id()
  log.info("beacon.transport", "New connection: " <> conn_id)

  let subject = process.new_subject()

  // Use runtime_factory if available (per-connection runtimes)
  // Otherwise use shared callbacks
  let handlers = case config.runtime_factory {
    Some(factory) -> {
      factory(conn_id, subject, req)
    }
    None -> {
      config.on_connect(conn_id, subject)
      Ok(#(config.on_event, config.on_disconnect))
    }
  }

  case handlers {
    Ok(#(conn_on_event, conn_on_close)) -> {
      let state =
        ConnectionState(
          id: conn_id,
          socket: socket,
          on_event: conn_on_event,
          on_close: conn_on_close,
          event_count: 0,
          rate_window_start: 0,
          security_limits: config.security_limits,
          heartbeat_count: 0,
          heartbeat_window_start: 0,
          buffer: <<>>,
        )

      pubsub.subscribe("beacon:patches:" <> conn_id)

      // Start receiving TCP data
      server.set_active_once(socket)

      // Enter the receive loop — never returns
      ws_loop(state, subject)
    }
    Error(reason) -> {
      log.error(
        "beacon.transport",
        "Closing WebSocket after runtime startup failure for "
          <> conn_id
          <> ": "
          <> reason,
      )
      case server.send_close_frame(socket) {
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

/// Check that the Origin header matches the server's host.
/// This prevents cross-site WebSocket hijacking (CSWSH).
///
/// SECURITY: Origin validation is the primary CSRF defense for WebSocket connections.
fn check_origin(req: Request(Connection)) -> Result(Nil, String) {
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
        Error(Nil) -> {
          log.warning(
            "beacon.transport",
            "Missing Host header for origin check",
          )
          ""
        }
      }
      origin_allowed_for_host(origin, request_host)
    }
  }
}

/// Validate that an Origin header value belongs to the request Host.
/// Empty origins, empty hosts, protocol-relative URLs, and mismatches reject.
pub fn origin_allowed_for_host(
  origin: String,
  request_host: String,
) -> Result(Nil, String) {
  let origin_host = extract_host_from_origin(origin)
  case origin_host != "" && request_host != "" && origin_host == request_host {
    True -> Ok(Nil)
    False -> {
      log.warning(
        "beacon.transport",
        "Origin mismatch: origin=" <> origin <> " host=" <> request_host,
      )
      Error("Origin mismatch")
    }
  }
}

/// Extract the host portion from an origin URL.
fn extract_host_from_origin(origin: String) -> String {
  let without_protocol = case string.split(origin, "://") {
    [_, rest] -> rest
    _ -> origin
  }
  case string.split(without_protocol, "/") {
    [host, ..] -> host
    _ -> without_protocol
  }
}

/// Handle a WebSocket upgrade request on a raw socket.
/// Validates connection limit, origin, auth, then performs the upgrade handshake.
fn handle_ws_request(
  socket: Socket,
  req: Request(Connection),
  config: TransportConfig,
) -> Nil {
  // Check global connection limit
  let current_count = connection_tracker_count()
  case current_count > config.security_limits.max_connections {
    True -> {
      log.warning(
        "beacon.transport",
        "Global connection limit reached ("
          <> int.to_string(current_count)
          <> "/"
          <> int.to_string(config.security_limits.max_connections)
          <> ") — rejecting new connection",
      )
      let _ = connection_tracker_decrement()
      transport_http.write_error(socket, 503, "Too many connections")
    }
    False -> {
      // Check origin — prevents cross-site WebSocket hijacking
      case check_origin(req) {
        Error(reason) -> {
          reject_ws_request(socket, 403, "Forbidden: " <> reason)
        }
        Ok(Nil) -> {
          // Check WebSocket auth if configured
          let auth_ok = case config.ws_auth {
            Some(auth_fn) -> auth_fn(req)
            None -> Ok(Nil)
          }
          case auth_ok {
            Error(reason) -> {
              log.warning("beacon.transport", "WS auth rejected: " <> reason)
              reject_ws_request(socket, 401, "Unauthorized: " <> reason)
            }
            Ok(Nil) -> {
              // Perform the WebSocket upgrade handshake
              case ws.upgrade(socket, req) {
                Ok(Nil) -> {
                  // Upgrade succeeded — enter the WS frame loop
                  start_ws_connection(socket, config, req)
                }
                Error(reason) -> {
                  log.error(
                    "beacon.transport",
                    "WebSocket upgrade failed: " <> reason,
                  )
                  let _ = connection_tracker_decrement()
                  server.close(socket)
                }
              }
            }
          }
        }
      }
    }
  }
}

fn reject_ws_request(socket: Socket, status: Int, body: String) -> Nil {
  let _ = connection_tracker_decrement()
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
  case validate_security_limits(config.security_limits) {
    Error(reason) ->
      Error(error.ConfigError(reason: "Invalid security limits: " <> reason))
    Ok(Nil) -> {
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

/// Reject limits that would disable a protection or make the server
/// unusable (zero or negative sizes, counts and timeouts).
pub fn validate_security_limits(limits: SecurityLimits) -> Result(Nil, String) {
  let positive = [
    #("max_message_bytes", limits.max_message_bytes),
    #("max_events_per_second", limits.max_events_per_second),
    #("max_connections", limits.max_connections),
    #("max_http_headers", limits.max_http_headers),
    #("max_http_header_bytes", limits.max_http_header_bytes),
    #("pre_upgrade_timeout_ms", limits.pre_upgrade_timeout_ms),
    #("max_connections_per_ip", limits.max_connections_per_ip),
    #("max_request_line_bytes", limits.max_request_line_bytes),
    #("body_read_timeout_ms", limits.body_read_timeout_ms),
    #("request_timeout_ms", limits.request_timeout_ms),
    #("keepalive_idle_timeout_ms", limits.keepalive_idle_timeout_ms),
    #("max_keepalive_requests", limits.max_keepalive_requests),
    #("send_timeout_ms", limits.send_timeout_ms),
  ]
  let invalid =
    positive
    |> list.filter(fn(check) { check.1 < 1 })
    |> list.map(fn(check) { check.0 <> "=" <> int.to_string(check.1) })
  let invalid = case limits.max_body_bytes < 0 {
    True -> [
      "max_body_bytes=" <> int.to_string(limits.max_body_bytes),
      ..invalid
    ]
    False -> invalid
  }
  case invalid {
    [] -> {
      log.debug("beacon.transport", "Security limits validated")
      Ok(Nil)
    }
    _ -> {
      let reason = "must be positive: " <> string.join(invalid, ", ")
      log.error("beacon.transport", "Invalid security limits, " <> reason)
      Error(reason)
    }
  }
}
