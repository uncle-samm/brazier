//// The runtime sends stream ops in the `streams` array of the frame of
//// their update (docs/design/STREAMS.md 6.1, 7.1): on the patch when the
//// model changed, on an empty patch at the current revision when it did
//// not, the items filled before the first join as resets in its
//// model_sync (7.2), relative to each connection's own window (a later
//// connection starts empty), and every refused op as an `error` frame
//// with a `[brazier, stream, refused]` event (7.4, 7.5, 11).
////
//// The stream_session unit tests cover every refusal and log line; these
//// cover the runtime's wiring of them.
////
//// Synchronisation: a `ClientSyncRequested` is answered only after every
//// earlier message was handled, so "nothing else was sent" is checked by
//// the barrier's model_sync arriving next. Telemetry handlers run in the
//// runtime's process, so every event of an update is in the mailbox
//// before the barrier's answer.

import brazier/effect
import brazier/error
import brazier/internal/stream_window
import brazier/monitored
import brazier/runtime
import brazier/stream
import brazier/telemetry.{type Event}
import brazier/test_ctx
import brazier/transport
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string

// --- The app ------------------------------------------------------------------

pub type Line {
  Line(id: String, text: String)
}

/// `log` is the name of the app's one declared stream, unique per test so
/// that the telemetry of one test is never counted by another.
pub type Model {
  Model(count: Int, log: String)
}

pub type Msg {
  /// Changes the model and inserts a line.
  Add(id: String)
  /// Changes the model only.
  Inc
  /// Inserts a line; the model is unchanged.
  Log(id: String)
  /// Deletes a line; the model is unchanged.
  Drop(id: String)
  /// Inserts a line larger than `stream_item_max_bytes`.
  Big
  /// Inserts into a stream the app did not declare.
  Typo
}

fn log_stream(name: String) -> stream.Stream(Line) {
  stream.new(
    name,
    key: fn(line: Line) { line.id },
    encode: encode_line,
    decoder: line_decoder(),
    limit: stream.KeepLast(3),
  )
}

fn encode_line(line: Line) -> json.Json {
  json.object([#("id", json.string(line.id)), #("text", json.string(line.text))])
}

fn line_decoder() -> decode.Decoder(Line) {
  use id <- decode.field("id", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(Line(id:, text:))
}

fn model_json(m: Model) -> String {
  "{\"count\":" <> int.to_string(m.count) <> "}"
}

fn decode_event(
  _name: String,
  handler_id: String,
  data: String,
  _path: String,
) -> Result(Msg, error.BrazierError) {
  case handler_id {
    "add" -> Ok(Add(data))
    "inc" -> Ok(Inc)
    "log" -> Ok(Log(data))
    "drop" -> Ok(Drop(data))
    "big" -> Ok(Big)
    "typo" -> Ok(Typo)
    _ -> Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
  }
}

fn update(m: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  let log = log_stream(m.log)
  case msg {
    Add(id) -> #(
      Model(..m, count: m.count + 1),
      stream.insert(log, Line(id:, text: "added"), at: stream.Append),
    )
    Inc -> #(Model(..m, count: m.count + 1), effect.none())
    Log(id) -> #(
      m,
      stream.insert(log, Line(id:, text: "logged"), at: stream.Append),
    )
    Drop(id) -> #(m, stream.delete_key(log, id))
    Big -> #(
      m,
      stream.insert(
        log,
        Line(id: "big", text: string.repeat("x", big_text_bytes)),
        at: stream.Append,
      ),
    )
    Typo -> #(
      m,
      stream.insert(
        log_stream("undeclared"),
        Line(id: "t", text: "typo"),
        at: stream.Append,
      ),
    )
  }
}

/// Over the default `stream_item_max_bytes` (65536) by a margin.
const big_text_bytes = 70_000

/// The app with stream `name` declared, whose `init` inserts `initial`.
fn config(
  name: String,
  initial: List(String),
) -> runtime.RuntimeConfig(Model, Msg) {
  config_dispatching(name, initial, [])
}

/// As `config`, with an `init` that also dispatches `messages`. They are
/// dispatched from the runtime's initialiser, so they are in its mailbox
/// before any message a test sends after the start.
fn config_dispatching(
  name: String,
  initial: List(String),
  messages: List(Msg),
) -> runtime.RuntimeConfig(Model, Msg) {
  let inserted = case initial {
    [] -> effect.none()
    ids ->
      stream.insert_many(
        log_stream(name),
        list.map(ids, fn(id) { Line(id:, text: "initial") }),
        at: stream.Append,
      )
  }
  let dispatched = case messages {
    [] -> effect.none()
    _ -> effect.from(fn(dispatch) { list.each(messages, dispatch) })
  }
  let init_effect = effect.batch([inserted, dispatched])
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(count: 0, log: name), init_effect)) },
    update: update,
    decode_event: decode_event,
    encode_model: model_json,
    route: None,
    restore_model: None,
    dynamic_subscriptions: None,
    on_notify: None,
    on_notification: None,
    secret_key: "runtime-stream-test-secret-0123456789",
    presence: None,
    title: None,
    streams: runtime.StreamConfig(
      names: [name],
      limits: stream_window.default_limits(),
    ),
  )
}

// --- Helpers ------------------------------------------------------------------

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn unique(label: String) -> String {
  label
  <> "_"
  <> int.to_string(int.absolute_value(unique_integer() % 1_000_000))
}

fn start(config: runtime.RuntimeConfig(Model, Msg)) {
  let assert Ok(rt) = runtime.start(config, test_ctx.root())
  rt
}

fn connect(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
) -> Subject(transport.InternalMessage) {
  let subject = process.new_subject()
  process.send(rt, runtime.ClientConnected(conn_id: conn_id, subject: subject))
  subject
}

/// Join `conn_id` and return the `streams` array of its join model_sync.
fn join(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  subject: Subject(transport.InternalMessage),
) -> String {
  process.send(rt, runtime.ClientJoined(conn_id: conn_id, token: "", path: "/"))
  let assert transport.SendModelSync(streams_json:, ..) = next(subject)
  streams_json
}

fn next(
  subject: Subject(transport.InternalMessage),
) -> transport.InternalMessage {
  let assert Ok(message) = process.receive(subject, 2000)
  message
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

/// The runtime answers with a model_sync only after every earlier message,
/// and that model_sync carries no stream entry.
fn assert_barrier_next(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  subject: Subject(transport.InternalMessage),
) -> Nil {
  process.send(rt, runtime.ClientSyncRequested(conn_id: conn_id))
  let assert transport.SendModelSync(streams_json: "[]", ..) = next(subject)
  let assert Error(Nil) = process.receive(subject, 0)
  Nil
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
  entries
}

const stream_events = [
  ["brazier", "stream", "delta"],
  ["brazier", "stream", "refused"],
  ["brazier", "runtime", "render", "stop"],
]

/// The events in the mailbox of `events`, in order, that are about stream
/// `name` or connection `conn_id`.
fn drain(
  events: Subject(Event),
  name: String,
  conn_id: String,
  acc: List(Event),
) -> List(Event) {
  case process.receive(events, 0) {
    Ok(event) ->
      case
        telemetry.string(event, "stream") == Ok(name)
        || telemetry.string(event, "connection_id") == Ok(conn_id)
      {
        True -> drain(events, name, conn_id, [event, ..acc])
        False -> drain(events, name, conn_id, acc)
      }
    Error(Nil) -> list.reverse(acc)
  }
}

fn named(events: List(Event), name: List(String)) -> List(Event) {
  list.filter(events, fn(event) { event.name == name })
}

// --- Ops ride the frame of their update (7.1) ---------------------------------

pub fn ops_ride_the_patch_of_a_model_change_test() {
  let name = unique("log")
  let c1 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let assert "[]" = join(rt, c1, s1)
  use events <- monitored.listening(stream_events)
  event(rt, c1, "add", "a", 1)
  let assert transport.SendPatch(ops_json:, ack_clock: 1, streams_json:, ..) =
    next(s1)
  let assert True = ops_json != "[]"
  let assert [#(got, False, [], [#("a", 0)])] = entries(streams_json)
  assert got == name
  let assert True =
    string.contains(streams_json, "\"item\":{\"id\":\"a\",\"text\":\"added\"}")
  assert_barrier_next(rt, c1, s1)
  let events = drain(events, name, c1, [])
  // The render span reports the size of the streams array it sent.
  let assert [render] = named(events, ["brazier", "runtime", "render", "stop"])
  let assert Ok(stream_bytes) = telemetry.int(render, "stream_bytes")
  assert stream_bytes == string.byte_size(streams_json)
  let assert [delta] = named(events, ["brazier", "stream", "delta"])
  let assert Ok(1) = telemetry.int(delta, "inserts")
  let assert Ok(0) = telemetry.int(delta, "updates")
  let assert Ok(0) = telemetry.int(delta, "deletes")
  let assert Ok(0) = telemetry.int(delta, "trimmed")
  let assert Ok(bytes) = telemetry.int(delta, "bytes")
  assert bytes == string.byte_size(streams_json) - 2
  Nil
}

pub fn a_model_change_without_stream_op_sends_an_empty_array_test() {
  let name = unique("log")
  let c1 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let assert "[]" = join(rt, c1, s1)
  use events <- monitored.listening(stream_events)
  event(rt, c1, "inc", "", 1)
  let assert transport.SendPatch(ack_clock: 1, streams_json: "[]", ..) =
    next(s1)
  assert_barrier_next(rt, c1, s1)
  let events = drain(events, name, c1, [])
  let assert [render] = named(events, ["brazier", "runtime", "render", "stop"])
  let assert Ok(0) = telemetry.int(render, "stream_bytes")
  let assert [] = named(events, ["brazier", "stream", "delta"])
  Nil
}

pub fn stream_ops_without_model_change_go_on_an_empty_patch_to_every_connection_test() {
  let name = unique("log")
  let c1 = unique("c")
  let c2 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let s2 = connect(rt, c2)
  let assert "[]" = join(rt, c1, s1)
  let assert "[]" = join(rt, c2, s2)
  event(rt, c1, "inc", "", 1)
  let assert transport.SendPatch(version:, ack_clock: 1, ..) = next(s1)
  let assert transport.SendPatch(version: v2, ack_clock: 0, ..) = next(s2)
  assert v2 == version
  event(rt, c1, "log", "a", 2)
  // Each connection is acknowledged once, at the revision it already has.
  let assert transport.SendPatch(
    ops_json: "[]",
    version: v1,
    ack_clock: 2,
    streams_json: f1,
  ) = next(s1)
  let assert transport.SendPatch(
    ops_json: "[]",
    version: v2,
    ack_clock: 0,
    streams_json: f2,
  ) = next(s2)
  assert v1 == version
  assert v2 == version
  let assert [#(_, False, [], [#("a", 0)])] = entries(f1)
  let assert [#(_, False, [], [#("a", 0)])] = entries(f2)
  assert_barrier_next(rt, c1, s1)
  assert_barrier_next(rt, c2, s2)
}

pub fn a_batch_sends_the_ops_of_every_event_in_order_in_one_patch_test() {
  let name = unique("log")
  let c1 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let assert "[]" = join(rt, c1, s1)
  process.send(
    rt,
    runtime.ClientEventBatchReceived(conn_id: c1, events: [
      #("click", "log", "a", "0", 1, []),
      #("click", "add", "b", "0", 2, []),
      #("click", "log", "c", "0", 3, []),
      #("click", "drop", "a", "0", 4, []),
    ]),
  )
  let assert transport.SendPatch(ack_clock: 4, streams_json:, ..) = next(s1)
  // "a" was inserted and deleted within the batch: the client is never
  // sent it.
  let assert [#(_, False, [], [#("b", 0), #("c", 1)])] = entries(streams_json)
  assert_barrier_next(rt, c1, s1)
}

// --- Items filled before the first join (7.2) ---------------------------------

pub fn init_items_arrive_as_a_reset_in_the_first_join_model_sync_test() {
  let name = unique("log")
  let c1 = unique("c")
  let rt = start(config(name, ["a", "b"]))
  let s1 = connect(rt, c1)
  let frame = join(rt, c1, s1)
  let assert [#(got, True, [], [#("a", 0), #("b", 1)])] = entries(frame)
  assert got == name
  let assert True =
    string.contains(frame, "\"item\":{\"id\":\"a\",\"text\":\"initial\"}")
  assert_barrier_next(rt, c1, s1)
}

pub fn a_later_connection_starts_empty_and_gets_its_own_indices_test() {
  let name = unique("log")
  let c1 = unique("c")
  let c2 = unique("c")
  let rt = start(config(name, ["a", "b"]))
  let s1 = connect(rt, c1)
  let s2 = connect(rt, c2)
  let assert [#(_, True, [], [#("a", 0), #("b", 1)])] =
    entries(join(rt, c1, s1))
  // No replay: the second connection holds nothing.
  let assert "[]" = join(rt, c2, s2)
  use events <- monitored.listening(stream_events)
  event(rt, c1, "log", "c", 1)
  let assert transport.SendPatch(streams_json: f1, ..) = next(s1)
  let assert transport.SendPatch(streams_json: f2, ..) = next(s2)
  let assert [#(_, False, [], [#("c", 2)])] = entries(f1)
  let assert [#(_, False, [], [#("c", 0)])] = entries(f2)
  // The limit (3) trims "a" from the first connection only.
  event(rt, c1, "log", "d", 2)
  let assert transport.SendPatch(streams_json: f1, ..) = next(s1)
  let assert transport.SendPatch(streams_json: f2, ..) = next(s2)
  let assert [#(_, False, ["a"], [#("d", 2)])] = entries(f1)
  let assert [#(_, False, [], [#("d", 1)])] = entries(f2)
  // A delete of a key the second connection was never sent is sent to the
  // first one only.
  event(rt, c1, "drop", "b", 3)
  let assert transport.SendPatch(streams_json: f1, ..) = next(s1)
  let assert transport.SendPatch(streams_json: "[]", ..) = next(s2)
  let assert [#(_, False, ["b"], [])] = entries(f1)
  assert_barrier_next(rt, c1, s1)
  assert_barrier_next(rt, c2, s2)
  // One delta per connection per update that changed its window.
  // `deletes` counts the keys of the entry's `deletes` array, so the key
  // the limit trimmed is in both counts.
  let deltas =
    drain(events, name, "", [])
    |> named(["brazier", "stream", "delta"])
    |> list.map(fn(delta) {
      let assert Ok(conn) = telemetry.string(delta, "connection_id")
      let assert Ok(trimmed) = telemetry.int(delta, "trimmed")
      let assert Ok(deletes) = telemetry.int(delta, "deletes")
      #(conn == c1, trimmed, deletes)
    })
  let assert [
    #(True, 0, 0),
    #(False, 0, 0),
    #(True, 1, 1),
    #(False, 0, 0),
    #(True, 0, 1),
  ] = deltas
  Nil
}

pub fn a_rejoin_is_sent_no_stream_entry_test() {
  let name = unique("log")
  let c1 = unique("c")
  let rt = start(config(name, ["a"]))
  let s1 = connect(rt, c1)
  let assert [#(_, True, [], [#("a", 0)])] = entries(join(rt, c1, s1))
  let assert "[]" = join(rt, c1, s1)
  // The rejoined connection keeps its window: the next insert lands after
  // the key it holds.
  event(rt, c1, "log", "b", 1)
  let assert transport.SendPatch(streams_json:, ..) = next(s1)
  let assert [#(_, False, [], [#("b", 1)])] = entries(streams_json)
  assert_barrier_next(rt, c1, s1)
}

pub fn a_disconnected_connection_is_sent_nothing_test() {
  let name = unique("log")
  let c1 = unique("c")
  let c2 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let s2 = connect(rt, c2)
  let assert "[]" = join(rt, c1, s1)
  let assert "[]" = join(rt, c2, s2)
  process.send(rt, runtime.ClientDisconnected(conn_id: c2))
  event(rt, c1, "log", "a", 1)
  let assert transport.SendPatch(streams_json:, ..) = next(s1)
  let assert [#(_, False, [], [#("a", 0)])] = entries(streams_json)
  assert_barrier_next(rt, c1, s1)
  let assert Error(Nil) = process.receive(s2, 0)
  Nil
}

// --- Refusals (7.4, 7.5) ------------------------------------------------------

pub fn an_oversized_item_is_refused_with_an_error_frame_to_every_connection_test() {
  let name = unique("log")
  let c1 = unique("c")
  let c2 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let s2 = connect(rt, c2)
  let assert "[]" = join(rt, c1, s1)
  let assert "[]" = join(rt, c2, s2)
  use events <- monitored.listening(stream_events)
  event(rt, c1, "big", "", 1)
  let assert transport.SendError(reason: r1) = next(s1)
  let assert transport.SendError(reason: r2) = next(s2)
  assert r1 == r2
  let assert True =
    string.starts_with(r1, "Stream " <> name <> ": refused 1 op(s): ")
  // Nothing else was sent: the sender is acknowledged with no entry.
  let assert transport.SendPatch(
    ops_json: "[]",
    ack_clock: 1,
    streams_json: "[]",
    ..,
  ) = next(s1)
  assert_barrier_next(rt, c1, s1)
  assert_barrier_next(rt, c2, s2)
  let events = drain(events, name, c1, [])
  let assert [refused] = named(events, ["brazier", "stream", "refused"])
  let assert Ok("item_too_large") = telemetry.string(refused, "reason")
  let assert Ok(1) = telemetry.int(refused, "count")
  let assert Ok(bytes) = telemetry.int(refused, "bytes")
  let item_bytes =
    string.byte_size(
      json.to_string(
        encode_line(Line(id: "big", text: string.repeat("x", big_text_bytes))),
      ),
    )
  assert bytes == item_bytes
  let assert [] = named(events, ["brazier", "stream", "delta"])
  // The stream still works.
  event(rt, c1, "log", "a", 2)
  let assert transport.SendPatch(streams_json: f1, ..) = next(s1)
  let assert transport.SendPatch(streams_json: f2, ..) = next(s2)
  let assert [#(_, False, [], [#("a", 0)])] = entries(f1)
  let assert [#(_, False, [], [#("a", 0)])] = entries(f2)
  assert_barrier_next(rt, c1, s1)
  assert_barrier_next(rt, c2, s2)
}

pub fn an_undeclared_stream_is_refused_with_an_error_frame_test() {
  let name = unique("log")
  let c1 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let assert "[]" = join(rt, c1, s1)
  use events <- monitored.listening(stream_events)
  event(rt, c1, "typo", "", 1)
  let assert transport.SendError(
    reason: "Stream undeclared: refused 1 op(s): the build declared no stream with this name",
  ) = next(s1)
  let assert transport.SendPatch(
    ops_json: "[]",
    ack_clock: 1,
    streams_json: "[]",
    ..,
  ) = next(s1)
  assert_barrier_next(rt, c1, s1)
  let refused =
    drain(events, "undeclared", c1, [])
    |> named(["brazier", "stream", "refused"])
  let assert [refused] = refused
  let assert Ok("unknown_stream") = telemetry.string(refused, "reason")
  let assert Ok(1) = telemetry.int(refused, "count")
  let assert Ok(0) = telemetry.int(refused, "bytes")
  Nil
}

pub fn a_delete_of_a_key_no_window_holds_sends_no_entry_test() {
  let name = unique("log")
  let c1 = unique("c")
  let rt = start(config(name, []))
  let s1 = connect(rt, c1)
  let assert "[]" = join(rt, c1, s1)
  event(rt, c1, "drop", "missing", 1)
  // Logged at warning, not refused: no error frame, only the acknowledgement.
  let assert transport.SendPatch(
    ops_json: "[]",
    ack_clock: 1,
    streams_json: "[]",
    ..,
  ) = next(s1)
  assert_barrier_next(rt, c1, s1)
}

pub fn ops_with_no_connection_joined_are_kept_for_the_first_join_test() {
  let name = unique("log")
  let c1 = unique("c")
  // Messages handled before any join apply to the session's windows: the
  // limit (3) trims "a", and the first join is sent what is left.
  let rt = start(config_dispatching(name, ["a", "b"], [Log("c"), Log("d")]))
  let s1 = connect(rt, c1)
  let frame = join(rt, c1, s1)
  let assert [#(_, True, [], [#("b", 0), #("c", 1), #("d", 2)])] =
    entries(frame)
  assert_barrier_next(rt, c1, s1)
}
