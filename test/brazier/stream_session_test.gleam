//// Unit tests for `brazier/internal/stream_session`: the items kept until
//// the first join, per-connection windows, every refusal with its log line,
//// telemetry event and error frame, rejoins and dropped join frames
//// (docs/design/STREAMS.md 7.1 to 7.5, 11).

import brazier/internal/stream_op.{type Limit, type Op, Back, Front, Op}
import brazier/internal/stream_session.{type Streams}
import brazier/internal/stream_window
import brazier/log_capture
import brazier/monitored
import brazier/telemetry.{type Event}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/string

// --- Helpers ----------------------------------------------------------------

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

/// A stream name no other test emits telemetry for, at most 10 bytes for
/// `"log"` so that the frame sizes below hold.
fn unique_name(label: String) -> String {
  label
  <> "_"
  <> int.to_string(int.absolute_value(unique_integer() % 1_000_000))
}

/// One or two one-key inserts fit in a frame; three do not.
const frame_bound = 170

fn last(count: Int) -> Limit {
  stream_op.Limit(keep: stream_op.Last, count: count)
}

fn item(key: String) -> String {
  "{\"k\":\"" <> key <> "\"}"
}

fn insert(name: String, key: String) -> Op {
  Op(name: name, limit: last(3), action: stream_op.Insert(key, item(key), Back))
}

fn insert_json(name: String, key: String, json: String) -> Op {
  Op(name: name, limit: last(3), action: stream_op.Insert(key, json, Back))
}

fn delete(name: String, key: String) -> Op {
  Op(name: name, limit: last(3), action: stream_op.Delete(key))
}

fn small_limits() -> stream_window.Limits {
  stream_window.Limits(
    max_limit: 10,
    item_max_bytes: 20,
    ops_max_per_update: 5,
    frame_max_bytes: 400,
    key_max_bytes: 4,
  )
}

fn new(names: List(String)) -> Streams {
  stream_session.new(names, small_limits())
}

fn connection_keys(streams: Streams, conn_id: String, name: String) {
  let assert Ok(keys) = stream_session.connection_keys(streams, conn_id, name)
  keys
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

/// Run `run` with a handler for the stream events of `name`, and return
/// its result with those events, in order. The handler runs in the
/// emitting process, so every event is in the mailbox when `run` returns.
fn with_stream_events(name: String, run: fn() -> a) -> #(a, List(Event)) {
  let events: Subject(Event) = process.new_subject()
  let handler = fn(event: Event) {
    case telemetry.string(event, "stream") == Ok(name) {
      True -> process.send(events, event)
      False -> Nil
    }
  }
  let result =
    monitored.with_handler(
      unique_name("stream_session_test"),
      [["brazier", "stream", "delta"], ["brazier", "stream", "refused"]],
      handler,
      run,
    )
  #(result, drain(events, []))
}

fn drain(events: Subject(Event), acc: List(Event)) -> List(Event) {
  case process.receive(events, 0) {
    Ok(event) -> drain(events, [event, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn refused(events: List(Event)) -> List(#(String, Int, Int)) {
  list.filter_map(events, fn(event) {
    case event.name {
      ["brazier", "stream", "refused"] -> {
        let assert Ok(reason) = telemetry.string(event, "reason")
        let assert Ok(count) = telemetry.int(event, "count")
        let assert Ok(bytes) = telemetry.int(event, "bytes")
        Ok(#(reason, count, bytes))
      }
      _ -> Error(Nil)
    }
  })
}

fn deltas(events: List(Event)) -> List(Event) {
  list.filter(events, fn(event) { event.name == ["brazier", "stream", "delta"] })
}

// --- Items kept until the first join (7.2) ----------------------------------

pub fn first_join_sends_the_items_filled_before_it_test() {
  let name = unique_name("log")
  let streams = new([name])
  let update =
    stream_session.apply(
      streams,
      [insert(name, "a"), insert(name, "b")],
      [],
      "init",
    )
  let assert [] = update.errors
  // No connection is joined: nothing is sent.
  let assert False = stream_session.has_entries(update)
  let #(#(streams, frame, errors), events) =
    with_stream_events(name, fn() { stream_session.join(update.streams, "c1") })
  let assert [] = errors
  let assert [#(got_name, True, [], [#("a", 0), #("b", 1)])] = entries(frame)
  assert got_name == name
  // The items were sent once; the session keeps keys only from now on.
  let assert ["a", "b"] = connection_keys(streams, "c1", name)
  let assert Ok(["a", "b"]) = stream_session.session_keys(streams, name)
  let assert [delta] = deltas(events)
  let assert Ok(2) = telemetry.int(delta, "inserts")
  let assert Ok("c1") = telemetry.string(delta, "connection_id")
  let assert Ok(bytes) = telemetry.int(delta, "bytes")
  assert bytes == string.byte_size(frame) - 2
}

pub fn first_join_with_no_item_sends_an_empty_array_test() {
  let name = unique_name("log")
  let #(_streams, frame, errors) = stream_session.join(new([name]), "c1")
  let assert "[]" = frame
  let assert [] = errors
}

pub fn a_later_connection_starts_empty_test() {
  let name = unique_name("log")
  let update =
    stream_session.apply(new([name]), [insert(name, "a")], [], "init")
  let #(streams, _, _) = stream_session.join(update.streams, "c1")
  let #(streams, frame, errors) = stream_session.join(streams, "c2")
  let assert "[]" = frame
  let assert [] = errors
  let assert Error(Nil) = stream_session.connection_keys(streams, "c2", name)
  // An insert lands at c2's own index; a delete of a key c2 was never sent
  // is not sent to it.
  let update =
    stream_session.apply(
      streams,
      [delete(name, "a"), insert(name, "b")],
      ["c1", "c2"],
      "Add",
    )
  let assert [#(_, False, ["a"], [#("b", 0)])] =
    entries(stream_session.frame(update, "c1"))
  let assert [#(_, False, [], [#("b", 0)])] =
    entries(stream_session.frame(update, "c2"))
  let assert ["b"] = connection_keys(update.streams, "c2", name)
}

pub fn a_connection_with_no_change_is_sent_an_empty_array_test() {
  let name = unique_name("log")
  let update =
    stream_session.apply(new([name]), [insert(name, "a")], [], "init")
  let #(streams, _, _) = stream_session.join(update.streams, "c1")
  let #(streams, _, _) = stream_session.join(streams, "c2")
  let update =
    stream_session.apply(streams, [delete(name, "a")], ["c1", "c2"], "Remove")
  let assert True = stream_session.has_entries(update)
  let assert [#(_, False, ["a"], [])] =
    entries(stream_session.frame(update, "c1"))
  let assert "[]" = stream_session.frame(update, "c2")
}

pub fn an_update_with_no_op_changes_nothing_test() {
  let name = unique_name("log")
  let #(streams, _, _) = stream_session.join(new([name]), "c1")
  let update = stream_session.apply(streams, [], ["c1"], "Tick")
  let assert False = stream_session.has_entries(update)
  let assert [] = update.errors
  let assert "[]" = stream_session.frame(update, "c1")
}

// --- Per-op refusals (7.4, 7.5) ---------------------------------------------

pub fn ops_on_an_unknown_stream_are_refused_as_one_group_test() {
  let name = unique_name("log")
  let unknown = unique_name("typo")
  let #(streams, _, _) = stream_session.join(new([name]), "c1")
  let #(#(update, events), logs) =
    log_capture.capture(fn() {
      with_stream_events(unknown, fn() {
        stream_session.apply(
          streams,
          [insert(unknown, "a"), insert(name, "b"), insert(unknown, "c")],
          ["c1"],
          "Add",
        )
      })
    })
  let assert [reason] = update.errors
  assert reason
    == "Stream "
    <> unknown
    <> ": refused 2 op(s): the build declared no stream with this name"
  let assert [#("unknown_stream", 2, 0)] = refused(events)
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "Refused 2 op(s) on stream " <> unknown,
      "unknown_stream",
      "update for Add",
    ])
  // The op on the declared stream still goes out.
  let assert [#(_, False, [], [#("b", 0)])] =
    entries(stream_session.frame(update, "c1"))
}

pub fn oversized_items_are_refused_and_the_rest_applied_test() {
  let name = unique_name("log")
  let #(streams, _, _) = stream_session.join(new([name]), "c1")
  let big = "{\"k\":\"" <> string.repeat("x", 30) <> "\"}"
  let #(#(update, events), logs) =
    log_capture.capture(fn() {
      with_stream_events(name, fn() {
        stream_session.apply(
          streams,
          [
            insert_json(name, "a", big),
            insert(name, "b"),
            insert_json(name, "c", big),
          ],
          ["c1"],
          "Add",
        )
      })
    })
  let assert [reason] = update.errors
  assert reason
    == "Stream "
    <> name
    <> ": refused 2 op(s): the item is 38 bytes, over the limit of 20"
  // One event for the group; its bytes are the refused items' sizes.
  let assert [#("item_too_large", 2, 76)] = refused(events)
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "Refused 2 op(s) on stream " <> name,
      "item_too_large",
    ])
  let assert [#(_, False, [], [#("b", 0)])] =
    entries(stream_session.frame(update, "c1"))
  let assert ["b"] = connection_keys(update.streams, "c1", name)
}

pub fn empty_and_oversized_keys_are_refused_test() {
  let name = unique_name("log")
  let #(streams, _, _) = stream_session.join(new([name]), "c1")
  let #(update, events) =
    with_stream_events(name, fn() {
      stream_session.apply(
        streams,
        [insert(name, ""), insert(name, "toolong")],
        ["c1"],
        "Add",
      )
    })
  let assert [empty_reason, long_reason] = update.errors
  assert empty_reason
    == "Stream " <> name <> ": refused 1 op(s): the key is empty"
  assert long_reason
    == "Stream "
    <> name
    <> ": refused 1 op(s): the key is 7 bytes, over the limit of 4"
  let assert [#("key_empty", 1, 0), #("key_too_large", 1, 7)] = refused(events)
  let assert False = stream_session.has_entries(update)
}

pub fn a_limit_out_of_range_is_refused_test() {
  let name = unique_name("log")
  let #(streams, _, _) = stream_session.join(new([name]), "c1")
  let op =
    Op(
      name: name,
      limit: last(11),
      action: stream_op.Insert("a", item("a"), Front),
    )
  let #(update, events) =
    with_stream_events(name, fn() {
      stream_session.apply(streams, [op], ["c1"], "Add")
    })
  let assert [_] = update.errors
  let assert [#("limit_out_of_range", 1, 0)] = refused(events)
  let assert Error(Nil) = stream_session.session_keys(update.streams, name)
}

// --- Whole-update refusals (7.4) --------------------------------------------

pub fn too_many_ops_refuse_the_whole_update_test() {
  let name = unique_name("log")
  let #(streams, _, _) = stream_session.join(new([name]), "c1")
  let ops = list.map(["a", "b", "c", "d", "e", "f"], insert(name, _))
  let #(#(update, events), logs) =
    log_capture.capture(fn() {
      with_stream_events(name, fn() {
        stream_session.apply(streams, ops, ["c1"], "Fill")
      })
    })
  let assert [
    "Refused every stream op of the update: the update carries 6 stream ops, over the limit of 5",
  ] = update.errors
  let assert [#("too_many_ops", 6, 0)] = refused(events)
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "Refused every stream op of the update for Fill",
      "too_many_ops",
      "for the session",
    ])
  let assert False = stream_session.has_entries(update)
  let assert Error(Nil) =
    stream_session.connection_keys(update.streams, "c1", name)
}

pub fn a_frame_over_the_bound_refuses_the_whole_update_test() {
  let name = unique_name("log")
  let limits =
    stream_window.Limits(..small_limits(), frame_max_bytes: frame_bound)
  let #(streams, _, _) =
    stream_session.join(stream_session.new([name], limits), "c1")
  let #(update, events) =
    with_stream_events(name, fn() {
      stream_session.apply(
        streams,
        [insert(name, "a"), insert(name, "b"), insert(name, "c")],
        ["c1"],
        "Fill",
      )
    })
  let assert [reason] = update.errors
  let assert True =
    string.starts_with(reason, "Refused every stream op of the update: ")
  let assert [#("frame_too_large", 3, bytes)] = refused(events)
  let assert True = bytes > frame_bound
  let assert False = stream_session.has_entries(update)
  let assert Error(Nil) = stream_session.session_keys(update.streams, name)
}

pub fn a_first_join_over_the_frame_bound_starts_empty_test() {
  let name = unique_name("log")
  let limits =
    stream_window.Limits(..small_limits(), frame_max_bytes: frame_bound)
  let streams = stream_session.new([name], limits)
  // Two updates, each under the bound; together over it.
  let update =
    stream_session.apply(
      streams,
      [insert(name, "a"), insert(name, "b")],
      [],
      "init",
    )
  let update =
    stream_session.apply(update.streams, [insert(name, "c")], [], "Add")
  let #(#(#(streams, frame, errors), events), logs) =
    log_capture.capture(fn() {
      with_stream_events(name, fn() {
        stream_session.join(update.streams, "c1")
      })
    })
  let assert "[]" = frame
  let assert [reason] = errors
  let assert True =
    string.starts_with(
      reason,
      "Refused the stream items filled before the join: ",
    )
  let assert [#("frame_too_large", 3, _)] = refused(events)
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "the first join of c1",
      "the streams start empty",
    ])
  // The client holds nothing, so the windows hold nothing: the next insert
  // is at 0, and a delete of a dropped key is not sent.
  let assert [] = connection_keys(streams, "c1", name)
  let update =
    stream_session.apply(
      streams,
      [delete(name, "a"), insert(name, "d")],
      ["c1"],
      "Add",
    )
  let assert [#(_, False, [], [#("d", 0)])] =
    entries(stream_session.frame(update, "c1"))
}

// --- Unknown deletes, rejoins, dropped join frames --------------------------

pub fn a_delete_of_a_key_never_inserted_is_a_warning_test() {
  let name = unique_name("log")
  let #(streams, _, _) = stream_session.join(new([name]), "c1")
  let #(update, logs) =
    log_capture.capture(fn() {
      stream_session.apply(streams, [delete(name, "gh")], ["c1"], "Remove")
    })
  let assert [] = update.errors
  let assert False = stream_session.has_entries(update)
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "Stream " <> name <> ": 1 delete(s) of keys it does not hold",
      "update for Remove",
    ])
  // Keys can identify a user: they are not logged.
  let assert False =
    list.any(logs, fn(event) { string.contains(event.message, "gh") })
}

pub fn a_rejoin_keeps_its_windows_and_is_sent_nothing_test() {
  let name = unique_name("log")
  let #(streams, _, _) = stream_session.join(new([name]), "c1")
  let update = stream_session.apply(streams, [insert(name, "a")], ["c1"], "Add")
  let #(#(streams, frame, errors), logs) =
    log_capture.capture(fn() { stream_session.join(update.streams, "c1") })
  let assert "[]" = frame
  let assert [] = errors
  let assert ["a"] = connection_keys(streams, "c1", name)
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "Rejoin from c1 while its streams hold 1 key(s)",
    ])
}

pub fn a_join_frame_not_sent_empties_the_connection_test() {
  let name = unique_name("log")
  let update =
    stream_session.apply(new([name]), [insert(name, "a")], [], "init")
  let #(streams, _, _) = stream_session.join(update.streams, "c1")
  let #(streams, logs) =
    log_capture.capture(fn() {
      stream_session.client_holds_nothing(streams, "c1")
    })
  let assert [] = connection_keys(streams, "c1", name)
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "The join frame of c1 was not sent; its 1 stream key(s) are dropped",
    ])
  let update = stream_session.apply(streams, [insert(name, "b")], ["c1"], "Add")
  let assert [#(_, False, [], [#("b", 0)])] =
    entries(stream_session.frame(update, "c1"))
}

pub fn a_forgotten_connection_has_no_windows_test() {
  let name = unique_name("log")
  let #(streams, _, _) = stream_session.join(new([name]), "c1")
  let streams = stream_session.forget(streams, "c1")
  let assert Error(Nil) = stream_session.connection_keys(streams, "c1", name)
}

// --- Telemetry (11) ---------------------------------------------------------

pub fn each_entry_sent_is_one_delta_event_per_connection_test() {
  let name = unique_name("log")
  let update =
    stream_session.apply(
      new([name]),
      [insert(name, "a"), insert(name, "b")],
      [],
      "init",
    )
  let #(streams, _, _) = stream_session.join(update.streams, "c1")
  let #(streams, _, _) = stream_session.join(streams, "c2")
  let #(update, events) =
    with_stream_events(name, fn() {
      stream_session.apply(
        streams,
        [
          insert(name, "a"),
          delete(name, "b"),
          insert(name, "c"),
          insert(name, "d"),
          insert(name, "e"),
        ],
        ["c1", "c2"],
        "Fill",
      )
    })
  let assert [] = update.errors
  let by_connection =
    list.map(deltas(events), fn(event) {
      let assert Ok(conn_id) = telemetry.string(event, "connection_id")
      let assert Ok(inserts) = telemetry.int(event, "inserts")
      let assert Ok(updates) = telemetry.int(event, "updates")
      let assert Ok(deletes) = telemetry.int(event, "deletes")
      let assert Ok(trimmed) = telemetry.int(event, "trimmed")
      #(conn_id, inserts, updates, deletes, trimmed)
    })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  // c1 held a and b: a is updated in place, b deleted, c, d and e
  // appended, and the limit of 3 trims a, so a is a delete and not an
  // update. c2 held nothing: a is inserted and trimmed in the same update,
  // so it is neither an insert nor a delete, and the delete of b is not
  // sent. Each connection's event counts the trim.
  let assert [#("c1", 3, 0, 2, 1), #("c2", 3, 0, 0, 1)] = by_connection
}
