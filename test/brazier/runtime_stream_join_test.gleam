//// Stream entries and refusals at a join (docs/design/STREAMS.md 7.2 to
//// 7.4, 12).
////
//// - A join after the runtime's first one (or a rejoin) whose path changes
////   the route: the route's update applies its stream ops to the joiner's
////   windows, and the joiner's join model_sync carries the entries it made
////   for them; its refusals reach the joiner as `error` frames before that
////   model_sync. Before, the ops reached the joined connections only, so
////   the joiner was sent `[]` and its windows missed the route's keys.
//// - Refusals made before the runtime's first join (`init`, messages
////   handled before it, the first join's own route) are held, at most
////   `runtime.held_stream_errors_max`, and sent to the first join before
////   its model_sync. Once a connection has joined, a refusal made while
////   none is joined is in the error log only: nothing is replayed (7.3).
//// - An update the session accepts but one connection's windows refuse
////   (its entries over `frame_max_bytes`, the connection-level
////   `FrameTooLarge`) is refused for every connection.
////
//// Synchronisation: `await.settle` (a barrier on the runtime, then the
//// connection's mailbox). Telemetry handlers and log handlers run in the
//// emitting process, so every event and line of an update is recorded
//// before the barrier's answer.

import brazier/await
import brazier/cluster/log_capture as node_log
import brazier/effect
import brazier/error
import brazier/internal/stream_window
import brazier/monitored
import brazier/runtime
import brazier/stream
import brazier/telemetry
import brazier/test_ctx
import brazier/transport.{type InternalMessage}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/uri

// --- A later join or a rejoin that changes the route (D1) --------------------

pub fn a_later_join_that_changes_the_route_is_sent_the_routes_entries_test() {
  let name = unique("log")
  let c1 = unique("c")
  let c2 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let assert [transport.SendModelSync(streams_json: "[]", ..)] =
    join(rt, c1, s1, "/")
  let s2 = connect(rt, c2)
  let received2 = join(rt, c2, s2, "/feed")
  // The joined connection is sent the route's change on a patch.
  let received1 = await.settle(rt, s1)
  let assert [transport.SendPatch(version: 1, streams_json: f1, ..)] = received1
    as string.inspect(received1)
  let assert [#(_, True, [], [#("f1", 0), #("f2", 1)])] = entries(f1)
  // The joiner's model_sync carries the same entries, for its own windows.
  let assert [
    transport.SendModelSync(version: 1, model_json:, streams_json: f2, ..),
  ] = received2
    as string.inspect(received2)
  assert string.contains(model_json, "\"page\":\"feed\"")
  let assert [#(got, True, [], [#("f1", 0), #("f2", 1)])] = entries(f2)
  assert got == name
  // Both windows hold the route's keys: the next insert lands after them.
  event(rt, c1, "log", "x", 1)
  let #(f1, f2) = both_frames(rt, s1, s2)
  let assert [#(_, False, [], [#("x", 2)])] = entries(f1)
  let assert [#(_, False, [], [#("x", 2)])] = entries(f2)
}

pub fn a_rejoin_that_changes_the_route_is_sent_the_routes_entries_test() {
  let name = unique("log")
  let c1 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let assert [transport.SendModelSync(streams_json: "[]", ..)] =
    join(rt, c1, s1, "/")
  event(rt, c1, "log", "a", 1)
  let received = await.settle(rt, s1)
  let assert [transport.SendPatch(streams_json: frame, ..)] = received
    as string.inspect(received)
  let assert [#(_, False, [], [#("a", 0)])] = entries(frame)
  // The rejoin keeps its windows ("a"); its route's reset replaces them.
  let received = join(rt, c1, s1, "/feed")
  let assert [transport.SendModelSync(model_json:, streams_json: frame, ..)] =
    received
    as string.inspect(received)
  assert string.contains(model_json, "\"page\":\"feed\"")
  let assert [#(_, True, [], [#("f1", 0), #("f2", 1)])] = entries(frame)
  event(rt, c1, "log", "x", 2)
  let received = await.settle(rt, s1)
  let assert [transport.SendPatch(ack_clock: 2, streams_json: frame, ..)] =
    received
    as string.inspect(received)
  let assert [#(_, False, [], [#("x", 2)])] = entries(frame)
}

pub fn a_later_joins_route_refusal_is_sent_to_the_joiner_too_test() {
  let name = unique("log")
  let c1 = unique("c")
  let c2 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let assert [transport.SendModelSync(..)] = join(rt, c1, s1, "/")
  let s2 = connect(rt, c2)
  let received2 = join(rt, c2, s2, "/bad")
  let received1 = await.settle(rt, s1)
  let assert [
    transport.SendError(reason: r1),
    transport.SendPatch(version: 1, streams_json: "[]", ..),
  ] = received1
    as string.inspect(received1)
  assert r1 == typo_reason
  // The joiner is sent the refusal before its model_sync.
  let assert [
    transport.SendError(reason: r2),
    transport.SendModelSync(version: 1, streams_json: "[]", ..),
  ] = received2
    as string.inspect(received2)
  assert r2 == typo_reason
}

// --- Refusals before the first join (D2) -------------------------------------

/// The refusals of `init`, of a message handled before the first join and
/// of the first join's own route reach the first join, in order, before
/// its model_sync.
pub fn refusals_before_the_first_join_are_sent_to_it_test() {
  let name = unique("log")
  let c1 = unique("c")
  let #(received, logs) =
    node_log.capture(fn() {
      let rt = start(config_init(name, typo_in_init: True, dispatched: [Typo]))
      let s1 = connect(rt, c1)
      join(rt, c1, s1, "/bad")
    })
  let assert [
    transport.SendError(reason: r1),
    transport.SendError(reason: r2),
    transport.SendError(reason: r3),
    transport.SendModelSync(streams_json: "[]", ..),
  ] = received
    as string.inspect(received)
  assert [r1, r2, r3] == [typo_reason, typo_reason, typo_reason]
  assert lines(logs, "info", "First join " <> c1)
    == [
      "[brazier.runtime] First join "
      <> c1
      <> ": sending 3 error frame(s) for the stream refusals made before it",
    ]
}

/// Past `held_stream_errors_max`, the refusals are counted, and the first
/// join is sent their count after the ones held.
pub fn refusals_before_the_first_join_past_the_bound_are_counted_test() {
  let name = unique("log")
  let c1 = unique("c")
  let past = 8
  let dispatched = list.repeat(Typo, runtime.held_stream_errors_max + past)
  let #(received, logs) =
    node_log.capture(fn() {
      let rt =
        start(config_init(name, typo_in_init: False, dispatched: dispatched))
      let s1 = connect(rt, c1)
      join(rt, c1, s1, "/")
    })
  let #(errors, rest) = list.split(received, runtime.held_stream_errors_max + 1)
  let reasons =
    list.map(errors, fn(message) {
      let assert transport.SendError(reason:) = message
        as string.inspect(message)
      reason
    })
  let #(held, count) = list.split(reasons, runtime.held_stream_errors_max)
  assert list.unique(held) == [typo_reason]
  assert count
    == [
      int.to_string(past)
      <> " more stream refusal(s) before the join; see the server log",
    ]
  let assert [transport.SendModelSync(..)] = rest as string.inspect(rest)
  // Each refusal past the bound is a warning; the join names the count.
  assert list.length(lines(logs, "warning", "is counted only")) == past
  assert lines(logs, "warning", "First join " <> c1)
    == [
      "[brazier.runtime] First join "
      <> c1
      <> ": "
      <> int.to_string(past)
      <> " stream refusal(s) made before it were past the bound of "
      <> int.to_string(runtime.held_stream_errors_max)
      <> "; it is sent their count only",
    ]
}

/// Once a connection has joined, a refusal made while none is joined is in
/// the error log only: a later joiner is not sent it (7.3).
pub fn a_refusal_with_no_connection_joined_after_the_first_join_is_not_held_test() {
  let name = unique("log")
  let c1 = unique("c")
  let c2 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let assert [transport.SendModelSync(..)] = join(rt, c1, s1, "/")
  process.send(rt, runtime.ClientDisconnected(conn_id: c1))
  let #(received, logs) =
    node_log.capture(fn() {
      process.send(rt, runtime.EffectDispatched(message: Typo))
      let s2 = connect(rt, c2)
      join(rt, c2, s2, "/")
    })
  let assert [transport.SendModelSync(streams_json: "[]", ..)] = received
    as string.inspect(received)
  let assert [_] = lines(logs, "error", "undeclared")
  let assert [] = lines(logs, "info", "error frame(s) for the stream refusals")
}

// --- The connection-level frame bound (D3) -----------------------------------

/// The session's window of the `KeepLast(1)` tail is full, so a prepend is
/// trimmed at once and the session's entries are empty; a later joiner's
/// window is empty, so it keeps the prepended item, and its entries are
/// over the frame bound. The whole update is refused, for every connection.
pub fn an_update_over_the_frame_bound_for_one_connection_is_refused_for_all_test() {
  let name = unique("log")
  let c1 = unique("c")
  let c2 = unique("c")
  let limits =
    stream_window.Limits(
      ..stream_window.default_limits(),
      frame_max_bytes: frame_bound,
    )
  let rt = start(config_with(name, False, [], limits))
  let s1 = connect(rt, c1)
  let assert [transport.SendModelSync(..)] = join(rt, c1, s1, "/")
  event(rt, c1, "tail", "a", 1)
  let received = await.settle(rt, s1)
  let assert [transport.SendPatch(streams_json: frame, ..)] = received
    as string.inspect(received)
  let assert [#(_, False, [], [#("a", 0)])] = entries(frame)
  let s2 = connect(rt, c2)
  let assert [transport.SendModelSync(streams_json: "[]", ..)] =
    join(rt, c2, s2, "/")
  use events <- monitored.listening([["brazier", "stream", "refused"]])
  let #(#(received1, received2), logs) =
    node_log.capture(fn() {
      event(rt, c1, "tail_front", "b", 2)
      let received1 = await.settle(rt, s1)
      #(received1, await.drain(s2))
    })
  let assert [
    transport.SendError(reason:),
    transport.SendPatch(ops_json: "[]", ack_clock: 2, streams_json: "[]", ..),
  ] = received1
    as string.inspect(received1)
  let assert [transport.SendError(reason: reason2)] = received2
    as string.inspect(received2)
  assert reason2 == reason
  assert string.starts_with(
    reason,
    "Refused every stream op of the update: the update's stream entries are ",
  )
  assert string.ends_with(
    reason,
    " bytes, over the frame limit of " <> int.to_string(frame_bound),
  )
  let assert [line] = lines(logs, "error", "Refused every stream op")
  assert string.contains(line, "frame_too_large, for connection " <> c2 <> ",")
  let refused =
    await.drain(events)
    |> list.filter(fn(event) {
      telemetry.string(event, "stream") == Ok(tail_name(name))
    })
  let assert [refused] = refused
  let assert Ok("frame_too_large") = telemetry.string(refused, "reason")
  let assert Ok(1) = telemetry.int(refused, "count")
  let assert Ok(bytes) = telemetry.int(refused, "bytes")
  assert bytes > frame_bound
  // No window took the refused update: the second connection still holds
  // nothing, the first still holds "a".
  event(rt, c1, "tail", "c", 3)
  let #(f1, f2) = both_frames(rt, s1, s2)
  let assert [#(_, False, ["a"], [#("c", 0)])] = entries(f1)
  let assert [#(_, False, [], [#("c", 0)])] = entries(f2)
}

/// A one-key tail entry fits; the tail entry of `big_text_bytes` does not.
const frame_bound = 250

const big_text_bytes = 300

// --- The app -----------------------------------------------------------------

pub type Model {
  Model(page: String, log: String)
}

pub type Msg {
  Routed(page: String)
  /// Appends a line to the `KeepLast(3)` log.
  Log(id: String)
  /// Inserts into a stream the build did not declare.
  Typo
  /// Appends a short line to the `KeepLast(1)` tail.
  Tail(id: String)
  /// Prepends a line of `big_text_bytes` to the `KeepLast(1)` tail.
  TailFront(id: String)
}

pub type Line {
  Line(id: String, text: String)
}

const typo_reason =
  "Stream undeclared: refused 1 op(s): the build declared no stream with this name"

fn line_stream(name: String, keep: Int) -> stream.Stream(Line) {
  stream.new(
    name,
    key: fn(line: Line) { line.id },
    encode: fn(line: Line) {
      json.object([
        #("id", json.string(line.id)),
        #("text", json.string(line.text)),
      ])
    },
    decoder: {
      use id <- decode.field("id", decode.string)
      use text <- decode.field("text", decode.string)
      decode.success(Line(id:, text:))
    },
    limit: stream.KeepLast(keep),
  )
}

fn tail_name(name: String) -> String {
  name <> "_tail"
}

fn typo() -> effect.Effect(Msg) {
  stream.insert(
    line_stream("undeclared", 3),
    Line(id: "t", text: "typo"),
    at: stream.Append,
  )
}

fn parse(page_uri: uri.Uri) -> Result(Msg, Nil) {
  case uri.path_segments(page_uri.path) {
    [] -> Ok(Routed("home"))
    ["feed"] -> Ok(Routed("feed"))
    ["bad"] -> Ok(Routed("bad"))
    _ -> Error(Nil)
  }
}

fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  let log = line_stream(model.log, 3)
  let tail = line_stream(tail_name(model.log), 1)
  case msg {
    Routed("feed") -> #(
      Model(..model, page: "feed"),
      stream.reset(log, [
        Line(id: "f1", text: "feed"),
        Line(id: "f2", text: "feed"),
      ]),
    )
    Routed("bad") -> #(Model(..model, page: "bad"), typo())
    Routed(page) -> #(Model(..model, page:), effect.none())
    Log(id) -> #(
      model,
      stream.insert(log, Line(id:, text: "l"), at: stream.Append),
    )
    Typo -> #(model, typo())
    Tail(id) -> #(
      model,
      stream.insert(tail, Line(id:, text: "s"), at: stream.Append),
    )
    TailFront(id) -> #(
      model,
      stream.insert(
        tail,
        Line(id:, text: string.repeat("x", big_text_bytes)),
        at: stream.Prepend,
      ),
    )
  }
}

fn config(
  name: String,
  dispatched: List(Msg),
) -> runtime.RuntimeConfig(Model, Msg) {
  config_with(name, False, dispatched, stream_window.default_limits())
}

fn config_init(
  name: String,
  typo_in_init typo_in_init: Bool,
  dispatched dispatched: List(Msg),
) -> runtime.RuntimeConfig(Model, Msg) {
  config_with(name, typo_in_init, dispatched, stream_window.default_limits())
}

/// The app with streams `name` and its tail declared. `init` inserts into
/// an undeclared stream when `typo_in_init`, and dispatches `dispatched`
/// from the runtime's initialiser, so they are handled before any join.
fn config_with(
  name: String,
  typo_in_init: Bool,
  dispatched: List(Msg),
  limits: stream_window.Limits,
) -> runtime.RuntimeConfig(Model, Msg) {
  let init_typo = case typo_in_init {
    True -> typo()
    False -> effect.none()
  }
  let init_dispatch = case dispatched {
    [] -> effect.none()
    _ -> effect.from(fn(dispatch) { list.each(dispatched, dispatch) })
  }
  let init_effect = effect.batch([init_typo, init_dispatch])
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(page: "", log: name), init_effect)) },
    update: update,
    encode_model: fn(model: Model) { "{\"page\":\"" <> model.page <> "\"}" },
    decode_event: fn(_name, handler_id, data, _path) {
      case handler_id {
        "log" -> Ok(Log(data))
        "tail" -> Ok(Tail(data))
        "tail_front" -> Ok(TailFront(data))
        _ -> Error(error.RuntimeError(reason: "unknown handler " <> handler_id))
      }
    },
    restore_model: None,
    route: option.Some(parse),
    dynamic_subscriptions: None,
    on_notify: None,
    on_notification: None,
    secret_key: "",
    presence: None,
    title: None,
    streams: runtime.StreamConfig(names: [name, tail_name(name)], limits:),
  )
}

// --- Harness -----------------------------------------------------------------

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn unique(label: String) -> String {
  label
  <> "_"
  <> int.to_string(int.absolute_value(unique_integer() % 1_000_000))
}

fn start(
  config: runtime.RuntimeConfig(Model, Msg),
) -> Subject(runtime.RuntimeMessage(Msg)) {
  let assert Ok(rt) = runtime.start(config, test_ctx.root())
  rt
}

fn connect(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
) -> Subject(InternalMessage) {
  let subject = process.new_subject()
  process.send(rt, runtime.ClientConnected(conn_id: conn_id, subject: subject))
  subject
}

/// Join `conn_id` at `path`; returns what the joiner was sent.
fn join(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  subject: Subject(InternalMessage),
  path: String,
) -> List(InternalMessage) {
  process.send(rt, runtime.ClientJoined(conn_id: conn_id, token: "", path:))
  await.settle(rt, subject)
}

fn event(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  handler_id: String,
  data: String,
  clock: Int,
) -> Nil {
  process.send(
    rt,
    runtime.ClientEventReceived(
      conn_id: conn_id,
      event_name: "click",
      handler_id: handler_id,
      event_data: data,
      target_path: "0",
      clock: clock,
      ops: [],
    ),
  )
}

/// The `streams` arrays of the one patch each connection was sent.
fn both_frames(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  s1: Subject(InternalMessage),
  s2: Subject(InternalMessage),
) -> #(String, String) {
  let received1 = await.settle(rt, s1)
  let received2 = await.drain(s2)
  let assert [transport.SendPatch(streams_json: f1, ..)] = received1
    as string.inspect(received1)
  let assert [transport.SendPatch(streams_json: f2, ..)] = received2
    as string.inspect(received2)
  #(f1, f2)
}

/// One frame's entries as `#(name, reset, deletes, inserts as #(key, at))`.
fn entries(
  frame: String,
) -> List(#(String, Bool, List(String), List(#(String, Int)))) {
  let insert_decoder = {
    use key <- decode.field("key", decode.string)
    use at <- decode.field("at", decode.int)
    decode.success(#(key, at))
  }
  let entry_decoder = {
    use name <- decode.field("name", decode.string)
    use reset <- decode.field("reset", decode.bool)
    use deletes <- decode.field("deletes", decode.list(decode.string))
    use inserts <- decode.field("inserts", decode.list(insert_decoder))
    decode.success(#(name, reset, deletes, inserts))
  }
  let assert Ok(entries) = json.parse(frame, decode.list(entry_decoder))
    as frame
  entries
}

/// The messages of the lines at `level` that contain `fragment`.
fn lines(
  logs: List(node_log.Line),
  level: String,
  fragment: String,
) -> List(String) {
  list.filter_map(logs, fn(line) {
    case line.level == level && string.contains(line.message, fragment) {
      True -> Ok(line.message)
      False -> Error(Nil)
    }
  })
}
