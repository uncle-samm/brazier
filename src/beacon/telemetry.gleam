//// Telemetry for Beacon, built on the Erlang `telemetry` library.
////
//// Handlers attach to event names and receive an `Event` for every
//// matching emit. Beacon's own events all start with `prefix` and are
//// listed by `catalogue`; see docs/TELEMETRY.md for their measurements and
//// metadata.
////
//// - A handler that crashes is detached by `telemetry`, which then emits
////   `[telemetry, handler, failure]`. Beacon logs that event at error
////   level. The process that emitted the event is never affected.
//// - With no handler attached, an emit costs one `persistent_term` read
////   and one ETS lookup.
//// - Metadata never carries session ids, tokens, cookies, event payloads,
////   models, query strings or remote IPs.
////
//// ```gleam
//// let assert Ok(Nil) =
////   telemetry.attach("http-logger", [["beacon", "http", "request", "stop"]], fn(event) {
////     let assert Ok(duration) = telemetry.int(event, "duration")
////     io.println("request took " <> int.to_string(duration))
////   })
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/list

/// The first segment of every event Beacon emits.
pub const prefix = "beacon"

/// One emitted event, as a handler receives it. Measurement and metadata
/// keys are strings; values keep the type they were emitted with.
pub type Event {
  Event(
    name: List(String),
    measurements: Dict(String, Dynamic),
    metadata: Dict(String, Dynamic),
  )
}

pub type TelemetryError {
  /// A handler with this id is already attached.
  AlreadyAttached(id: String)
  /// No handler with this id is attached.
  NotAttached(id: String)
  /// The event name is empty or has an empty or over-long segment.
  InvalidEventName(String)
  /// Handler ids must be 1 to 255 bytes.
  InvalidHandlerId(String)
  /// The `telemetry` application could not be started.
  StartFailed(reason: String)
}

/// Start the `telemetry` application and attach the logger for crashed
/// handlers. Idempotent. Beacon's subsystems call it when they start.
pub fn start() -> Result(Nil, TelemetryError) {
  ffi_start()
}

/// Attach `handler` to every event in `events`. Each event name is a list
/// of segments, for example `["beacon", "pubsub", "broadcast"]`.
pub fn attach(
  id: String,
  events: List(List(String)),
  handler: fn(Event) -> Nil,
) -> Result(Nil, TelemetryError) {
  ffi_attach(id, events, handler)
}

/// Detach the handler with this id.
pub fn detach(id: String) -> Result(Nil, TelemetryError) {
  ffi_detach(id)
}

/// Emit an event from application code. Keys stay strings, so this never
/// creates atoms. When no handler has ever been attached to `name`, there
/// is nothing to deliver and this returns `Ok(Nil)` without emitting.
pub fn execute(
  name: List(String),
  measurements: Dict(String, Int),
  metadata: Dict(String, String),
) -> Result(Nil, TelemetryError) {
  ffi_execute(name, measurements, metadata)
}

/// Run `run` inside a span: `name ++ ["start"]` is emitted before it and
/// `name ++ ["stop"]` after it, with `duration` in native time units. If
/// `run` crashes, `name ++ ["exception"]` is emitted with `kind`, `reason`
/// and `stacktrace`, and the crash is re-raised unchanged.
///
/// Crashes if `name` is empty or has an empty segment: span names come
/// from code, so an invalid one is a programming error.
pub fn span(
  name: List(String),
  metadata: Dict(String, String),
  run: fn() -> a,
) -> a {
  ffi_span(name, metadata, run)
}

/// An integer measurement, or an integer metadata value when no
/// measurement has that key.
pub fn int(event: Event, key: String) -> Result(Int, Nil) {
  case lookup_int(event.measurements, key) {
    Ok(value) -> Ok(value)
    Error(Nil) -> lookup_int(event.metadata, key)
  }
}

/// A string metadata value (atoms such as a span's `kind` are converted),
/// or a string measurement when no metadata value has that key.
pub fn string(event: Event, key: String) -> Result(String, Nil) {
  case lookup_string(event.metadata, key) {
    Ok(value) -> Ok(value)
    Error(Nil) -> lookup_string(event.measurements, key)
  }
}

/// Every event name Beacon emits. Spans are listed as their `start`,
/// `stop` and `exception` events.
pub fn catalogue() -> List(List(String)) {
  let spans = [
    ["http", "request"],
    ["ws", "upgrade"],
    ["runtime", "mount"],
    ["runtime", "handle_event"],
    ["runtime", "navigate"],
    ["runtime", "render"],
    ["effect", "run"],
    ["store", "sync"],
    ["presence", "transfer"],
  ]
  let events = [
    ["http", "connection", "accepted"],
    ["http", "connection", "rejected"],
    ["http", "connection", "closed"],
    ["ws", "close"],
    ["ws", "rate_limited"],
    ["ws", "backpressure"],
    ["runtime", "stop"],
    ["effect", "timer", "rejected"],
    ["store", "write"],
    ["session", "created"],
    ["session", "revoked"],
    ["session", "expired"],
    ["session", "contention"],
    ["pubsub", "broadcast"],
    ["pubsub", "forward", "overloaded"],
    ["cluster", "node", "up"],
    ["cluster", "node", "down"],
    ["cluster", "peer", "rejected"],
    ["cluster", "connect", "failed"],
    ["presence", "track"],
    ["presence", "untrack"],
    ["presence", "limit_exceeded"],
    ["presence", "replica", "up"],
    ["presence", "replica", "down"],
    ["presence", "replica", "permdown"],
  ]
  let span_events =
    list.flat_map(spans, fn(span) {
      list.map(["start", "stop", "exception"], fn(suffix) {
        list.append(span, [suffix])
      })
    })
  list.map(list.append(span_events, events), fn(name) { [prefix, ..name] })
}

// --- Catalogue emitters -----------------------------------------------------
//
// Beacon's subsystems emit through these functions. Each one has fixed
// measurement and metadata keys, so callers cannot leak private data by
// passing extra fields.

pub type ConnectionOutcome {
  Accepted
  Rejected
  Closed
}

pub type RuntimeSpan {
  Mount
  HandleEvent
  Navigate
}

pub type SessionEvent {
  Created
  Revoked
  Expired
  Contention
}

pub type NodeDirection {
  NodeUp
  NodeDown
}

pub type PresenceEvent {
  Track
  Untrack
  LimitExceeded
}

pub type ReplicaState {
  ReplicaUp
  ReplicaDown
  ReplicaPermdown
}

/// `[beacon, http, request]` span. `run` returns the result with the
/// matched route, the response status and the request and response body
/// sizes in bytes. The route is only known after routing, so it is on the
/// stop event (with `status`), not on start or exception. `route` is the
/// matched pattern, never the raw path.
@external(erlang, "beacon_telemetry_ffi", "http_request_span")
@internal
pub fn http_request_span(
  method: String,
  connection_id: String,
  run: fn() -> #(a, String, Int, Int, Int),
) -> a

/// `[beacon, http, connection, accepted | rejected | closed]`.
@external(erlang, "beacon_telemetry_ffi", "http_connection")
@internal
pub fn http_connection(
  outcome: ConnectionOutcome,
  duration: Int,
  reason: String,
) -> Nil

/// `[beacon, ws, upgrade]` span. `run` returns the result and a result
/// label such as `"ok"` or `"rejected_origin"`.
@external(erlang, "beacon_telemetry_ffi", "ws_upgrade_span")
@internal
pub fn ws_upgrade_span(route: String, run: fn() -> #(a, String)) -> a

/// `[beacon, ws, close]`: one summary per connection. `duration` is in
/// native time units; `close_code` is the code sent or echoed, 1005 when
/// the peer's close had no code, 1006 when no close frame was exchanged.
/// `reason` is a fixed snake_case label.
@external(erlang, "beacon_telemetry_ffi", "ws_close")
@internal
pub fn ws_close(
  duration: Int,
  frames_in: Int,
  frames_out: Int,
  bytes_in: Int,
  bytes_out: Int,
  close_code: Int,
  reason: String,
  connection_id: String,
) -> Nil

/// `[beacon, ws, rate_limited]`: a refused event, batch or heartbeat.
/// `violations` is the connection's running count; `kind` is
/// `"event_rate"`, `"batch_size"` or `"heartbeat_rate"`.
@external(erlang, "beacon_telemetry_ffi", "ws_rate_limited")
@internal
pub fn ws_rate_limited(
  violations: Int,
  kind: String,
  connection_id: String,
) -> Nil

/// `[beacon, ws, backpressure]`: the connection is closed because a
/// queue is full. `reason` is `"outbound_queue"` (the connection's
/// mailbox) or `"runtime"` (the runtime's view of the connection).
@external(erlang, "beacon_telemetry_ffi", "ws_backpressure")
@internal
pub fn ws_backpressure(
  queue_len: Int,
  reason: String,
  connection_id: String,
) -> Nil

/// `[beacon, runtime, mount | handle_event | navigate]` span. `event` is
/// the message's constructor name in snake_case, as the BEAM names it
/// (`SetCount(9)` is `"set_count"`; `"mount"` for a mount), or `"unknown"`
/// when the event did not decode to a message of the app.
@external(erlang, "beacon_telemetry_ffi", "runtime_span")
@internal
pub fn runtime_span(
  kind: RuntimeSpan,
  route: String,
  event: String,
  connection_id: String,
  run: fn() -> a,
) -> a

/// `[beacon, runtime, render]` span. `run` returns the result and the
/// size of the patch in bytes.
@external(erlang, "beacon_telemetry_ffi", "runtime_render_span")
@internal
pub fn runtime_render_span(
  route: String,
  event: String,
  connection_id: String,
  run: fn() -> #(a, Int),
) -> a

/// `[beacon, runtime, stop]` for a `Shutdown`.
@external(erlang, "beacon_telemetry_ffi", "runtime_stop")
@internal
pub fn runtime_stop(uptime: Int, reason: String) -> Nil

/// `[beacon, runtime, stop]` for a runtime that crashed (`reason` is
/// `crash`) or was stopped by an exit signal (`exit`), with the exception
/// class as `kind` and the bounded description of the reason as `error`.
@external(erlang, "beacon_telemetry_ffi", "runtime_stop_failed")
@internal
pub fn runtime_stop_failed(
  uptime: Int,
  reason: String,
  kind: String,
  error: String,
) -> Nil

/// `[beacon, effect, run]` span.
@external(erlang, "beacon_telemetry_ffi", "effect_run_span")
@internal
pub fn effect_run_span(effect: String, run: fn() -> a) -> a

/// `[beacon, effect, timer, rejected]`.
@external(erlang, "beacon_telemetry_ffi", "effect_timer_rejected")
@internal
pub fn effect_timer_rejected(limit: Int) -> Nil

/// `[beacon, store, write]`.
@external(erlang, "beacon_telemetry_ffi", "store_write")
@internal
pub fn store_write(count: Int, store: String, op: String, mode: String) -> Nil

/// `[beacon, store, sync]` span. `run` returns the result with the number
/// of entries and bytes synced.
@external(erlang, "beacon_telemetry_ffi", "store_sync_span")
@internal
pub fn store_sync_span(
  store: String,
  peer: String,
  run: fn() -> #(a, Int, Int),
) -> a

/// `[beacon, session, created | revoked | expired | contention]`.
@external(erlang, "beacon_telemetry_ffi", "session_event")
@internal
pub fn session_event(kind: SessionEvent, reason: String) -> Nil

/// `[beacon, pubsub, broadcast]`.
@external(erlang, "beacon_telemetry_ffi", "pubsub_broadcast")
@internal
pub fn pubsub_broadcast(
  local_subscribers: Int,
  remote_nodes: Int,
  scope: String,
) -> Nil

/// `[beacon, pubsub, forward, overloaded]`.
@external(erlang, "beacon_telemetry_ffi", "pubsub_forward_overloaded")
@internal
pub fn pubsub_forward_overloaded(queue_len: Int, shard: Int) -> Nil

/// `[beacon, cluster, node, up | down]`.
@external(erlang, "beacon_telemetry_ffi", "cluster_node")
@internal
pub fn cluster_node(
  direction: NodeDirection,
  node: String,
  reason: String,
) -> Nil

/// `[beacon, cluster, peer, rejected]`.
@external(erlang, "beacon_telemetry_ffi", "cluster_peer_rejected")
@internal
pub fn cluster_peer_rejected(node: String, reason: String) -> Nil

/// `[beacon, cluster, connect, failed]`.
@external(erlang, "beacon_telemetry_ffi", "cluster_connect_failed")
@internal
pub fn cluster_connect_failed(node: String, reason: String) -> Nil

/// `[beacon, presence, track | untrack | limit_exceeded]`.
@external(erlang, "beacon_telemetry_ffi", "presence_event")
@internal
pub fn presence_event(
  kind: PresenceEvent,
  count: Int,
  tracker: String,
  shard: Int,
) -> Nil

/// `[beacon, presence, replica, up | down | permdown]`.
@external(erlang, "beacon_telemetry_ffi", "presence_replica")
@internal
pub fn presence_replica(
  state: ReplicaState,
  replica: String,
  tracker: String,
) -> Nil

/// `[beacon, presence, transfer]` span. `run` returns the result with the
/// number of entries and bytes transferred.
@external(erlang, "beacon_telemetry_ffi", "presence_transfer_span")
@internal
pub fn presence_transfer_span(
  tracker: String,
  peer: String,
  run: fn() -> #(a, Int, Int),
) -> a

/// The prefix compiled into the Erlang emitters, so a test can check it
/// matches `prefix`.
@external(erlang, "beacon_telemetry_ffi", "prefix")
@internal
pub fn compiled_prefix() -> String

// --- FFI --------------------------------------------------------------------

@external(erlang, "beacon_telemetry_ffi", "start")
fn ffi_start() -> Result(Nil, TelemetryError)

@external(erlang, "beacon_telemetry_ffi", "attach")
fn ffi_attach(
  id: String,
  events: List(List(String)),
  handler: fn(Event) -> Nil,
) -> Result(Nil, TelemetryError)

@external(erlang, "beacon_telemetry_ffi", "detach")
fn ffi_detach(id: String) -> Result(Nil, TelemetryError)

@external(erlang, "beacon_telemetry_ffi", "execute")
fn ffi_execute(
  name: List(String),
  measurements: Dict(String, Int),
  metadata: Dict(String, String),
) -> Result(Nil, TelemetryError)

@external(erlang, "beacon_telemetry_ffi", "span")
fn ffi_span(
  name: List(String),
  metadata: Dict(String, String),
  run: fn() -> a,
) -> a

@external(erlang, "beacon_telemetry_ffi", "lookup_int")
fn lookup_int(map: Dict(String, Dynamic), key: String) -> Result(Int, Nil)

@external(erlang, "beacon_telemetry_ffi", "lookup_string")
fn lookup_string(map: Dict(String, Dynamic), key: String) -> Result(String, Nil)
