//// Tests for `brazier/stream`: the declaration, the op values and the test
//// helpers.

import brazier/effect.{type Effect}
import brazier/internal/stream_op
import brazier/internal/stream_window
import brazier/log_capture
import brazier/stream.{
  type Stream, Append, Deleted, Inserted, KeepFirst, KeepLast, Prepend,
}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string

pub type Line {
  Line(id: Int, text: String)
}

fn encode_line(line: Line) -> json.Json {
  json.object([#("id", json.int(line.id)), #("text", json.string(line.text))])
}

fn line_decoder() -> decode.Decoder(Line) {
  use id <- decode.field("id", decode.int)
  use text <- decode.field("text", decode.string)
  decode.success(Line(id:, text:))
}

fn line_key(line: Line) -> String {
  "line-" <> int.to_string(line.id)
}

fn log() -> Stream(Line) {
  stream.new(
    "log",
    key: line_key,
    encode: encode_line,
    decoder: line_decoder(),
    limit: KeepLast(3),
  )
}

fn text(line: Line) -> String {
  json.to_string(encode_line(line))
}

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))

fn declare(name: String, limit: stream.Limit) -> Stream(Line) {
  stream.new(
    name,
    key: line_key,
    encode: encode_line,
    decoder: line_decoder(),
    limit: limit,
  )
}

// --- Declaration ------------------------------------------------------------

pub fn new_keeps_name_and_limit_test() {
  let s = declare("chat_log2", KeepFirst(1000))
  let assert "chat_log2" = stream.name(s)
  let assert KeepFirst(1000) = stream.limit(s)
  let assert "line-4" = stream.key(s, Line(4, "x"))
}

pub fn new_accepts_names_at_the_bounds_test() {
  let assert "a" = stream.name(declare("a", KeepLast(1)))
  let long = "a" <> string.repeat("_", 63)
  let assert 64 = string.length(stream.name(declare(long, KeepLast(1))))
}

pub fn new_crashes_on_a_bad_name_test() {
  let bad = [
    "",
    "1log",
    "_log",
    "Log",
    "log-1",
    "log.x",
    "lög",
    "log ",
    "a" <> string.repeat("b", 64),
  ]
  list.each(bad, fn(name) {
    let assert Error(#("error", _)) =
      rescue(fn() { declare(name, KeepLast(3)) })
  })
}

pub fn new_crashes_on_a_limit_below_one_test() {
  let assert Error(#("error", _)) = rescue(fn() { declare("log", KeepLast(0)) })
  let assert Error(#("error", _)) =
    rescue(fn() { declare("log", KeepFirst(-1)) })
}

pub fn limit_over_the_maximum_is_declared_and_refused_by_the_window_test() {
  let s = declare("big", KeepLast(1001))
  let assert Ok(applied) =
    stream_window.apply_update(
      stream_window.new(keep_items: False),
      ops_of(stream.insert(s, Line(1, "a"), at: Append)),
      stream_window.default_limits(),
    )
  let assert [
    stream_window.OpRefusal(
      stream: "big",
      reason: stream_window.LimitOutOfRange(count: 1001, max: 1000),
      ..,
    ),
  ] = applied.refused
}

pub fn to_op_limit_test() {
  let assert True =
    stream.to_op_limit(KeepFirst(5))
    == stream_op.Limit(keep: stream_op.First, count: 5)
  let assert True =
    stream.to_op_limit(KeepLast(7))
    == stream_op.Limit(keep: stream_op.Last, count: 7)
}

// --- Ops --------------------------------------------------------------------

pub fn insert_holds_key_and_json_test() {
  let line = Line(1, "hello")
  let assert True =
    stream.emitted(stream.insert(log(), line, at: Append))
    == [Inserted(stream: "log", key: "line-1", json: text(line), at: Append)]
  let assert True =
    stream.emitted(stream.insert(log(), line, at: Prepend))
    == [Inserted(stream: "log", key: "line-1", json: text(line), at: Prepend)]
}

pub fn ops_carry_the_stream_limit_test() {
  let assert [stream_op.Op(name: "log", limit:, action: stream_op.Delete("k"))] =
    ops_of(stream.delete_key(log(), "k"))
  let assert True = limit == stream_op.Limit(keep: stream_op.Last, count: 3)
}

pub fn insert_many_append_keeps_the_order_test() {
  let lines = [Line(1, "a"), Line(2, "b"), Line(3, "c")]
  let keys =
    stream.emitted(stream.insert_many(log(), lines, at: Append))
    |> list.map(emitted_key)
  let assert ["line-1", "line-2", "line-3"] = keys
}

pub fn insert_many_prepend_puts_the_first_item_first_test() {
  let lines = [Line(1, "a"), Line(2, "b"), Line(3, "c")]
  let ops = stream.insert_many(log(), lines, at: Prepend)
  // Applied from the last, so the first ends up first.
  let assert ["line-3", "line-2", "line-1"] =
    list.map(stream.emitted(ops), emitted_key)
  let windows = apply(stream_window.new(keep_items: False), ops)
  let assert Ok(["line-1", "line-2", "line-3"]) =
    stream_window.keys(windows, "log")
}

pub fn insert_many_prepend_onto_existing_items_test() {
  let windows =
    apply(
      stream_window.new(keep_items: False),
      stream.insert(declare("log", KeepLast(5)), Line(9, "old"), at: Append),
    )
  let windows =
    apply(
      windows,
      stream.insert_many(
        declare("log", KeepLast(5)),
        [Line(1, "a"), Line(2, "b")],
        at: Prepend,
      ),
    )
  let assert Ok(["line-1", "line-2", "line-9"]) =
    stream_window.keys(windows, "log")
}

pub fn insert_many_with_duplicates_is_one_insert_per_key_test() {
  let lines = [Line(1, "a"), Line(2, "b"), Line(1, "c"), Line(3, "d")]
  let assert True =
    stream.emitted(stream.insert_many(log(), lines, at: Append))
    == [
      Inserted("log", "line-1", text(Line(1, "c")), Append),
      Inserted("log", "line-2", text(Line(2, "b")), Append),
      Inserted("log", "line-3", text(Line(3, "d")), Append),
    ]
  // Prepend: the key keeps its first place in the list, so line-1 ends
  // first, with its last item.
  let ops = stream.insert_many(log(), lines, at: Prepend)
  let windows = apply(stream_window.new(keep_items: True), ops)
  let assert Ok(#([stream_window.Delta(inserts:, ..)], _)) =
    stream_window.snapshot(windows)
  let assert True =
    inserts
    == [
      stream_window.DeltaInsert("line-1", 0, text(Line(1, "c"))),
      stream_window.DeltaInsert("line-2", 1, text(Line(2, "b"))),
      stream_window.DeltaInsert("line-3", 2, text(Line(3, "d"))),
    ]
}

pub fn insert_many_of_nothing_is_no_op_test() {
  let assert [] = stream.emitted(stream.insert_many(log(), [], at: Append))
  let assert [] = stream.emitted(stream.insert_many(log(), [], at: Prepend))
}

pub fn delete_uses_the_item_key_test() {
  let assert [Deleted(stream: "log", key: "line-5")] =
    stream.emitted(stream.delete(log(), Line(5, "ignored")))
  let assert [Deleted(stream: "log", key: "any key")] =
    stream.emitted(stream.delete_key(log(), "any key"))
}

pub fn reset_holds_unique_items_in_order_test() {
  let assert [stream.Reset(stream: "log", items: [])] =
    stream.emitted(stream.reset(log(), []))
  let lines = [Line(2, "a"), Line(1, "b"), Line(2, "c")]
  let assert True =
    stream.emitted(stream.reset(log(), lines))
    == [
      stream.Reset(stream: "log", items: [
        #("line-2", text(Line(2, "c"))),
        #("line-1", text(Line(1, "b"))),
      ]),
    ]
}

pub fn emitted_key_bound_is_checked_by_the_window_test() {
  let s =
    stream.new(
      "log",
      key: fn(line: Line) { line.text },
      encode: encode_line,
      decoder: line_decoder(),
      limit: KeepLast(3),
    )
  let assert Ok(applied) =
    stream_window.apply_update(
      stream_window.new(keep_items: False),
      ops_of(stream.insert(s, Line(1, ""), at: Append)),
      stream_window.default_limits(),
    )
  let assert [stream_window.OpRefusal(reason: stream_window.KeyEmpty, ..)] =
    applied.refused
}

// --- Ops are effects --------------------------------------------------------

pub fn an_op_is_not_a_none_effect_test() {
  let assert False = effect.is_none(stream.delete_key(log(), "k"))
  let assert True = effect.is_none(stream.insert_many(log(), [], at: Append))
}

pub fn batch_keeps_ops_in_order_with_other_callbacks_test() {
  let eff =
    effect.batch([
      stream.insert(log(), Line(1, "a"), at: Append),
      effect.from(fn(_dispatch) { Nil }),
      stream.delete_key(log(), "line-9"),
      effect.batch([
        stream.insert(log(), Line(2, "b"), at: Prepend),
        effect.none(),
      ]),
    ])
  let assert True =
    stream.emitted(eff)
    == [
      Inserted("log", "line-1", text(Line(1, "a")), Append),
      Deleted("log", "line-9"),
      Inserted("log", "line-2", text(Line(2, "b")), Prepend),
    ]
  // The rest keeps the one callback and no op.
  let #(ops, rest) = effect.take_stream_ops(eff)
  let assert 3 = list.length(ops)
  let assert False = effect.is_none(rest)
  let assert #([], again) = effect.take_stream_ops(rest)
  let assert False = effect.is_none(again)
}

pub fn map_passes_ops_through_test() {
  let eff: Effect(Int) =
    effect.batch([
      stream.insert(log(), Line(1, "a"), at: Append),
      stream.reset(log(), [Line(2, "b")]),
    ])
  let mapped: Effect(String) = effect.map(eff, int.to_string)
  let assert True = stream.emitted(mapped) == stream.emitted(eff)
  let assert 2 = list.length(stream.emitted(mapped))
}

pub fn keyed_and_cancellable_leave_ops_unkeyed_test() {
  let eff =
    effect.batch([
      stream.insert(log(), Line(1, "a"), at: Append),
      stream.delete_key(log(), "line-1"),
    ])
  let assert True =
    stream.emitted(effect.keyed("feed", eff)) == stream.emitted(eff)
  let #(cancellable, _token) = effect.cancellable(eff)
  let assert True = stream.emitted(cancellable) == stream.emitted(eff)
  let #(ops, rest) = effect.take_stream_ops(effect.keyed("feed", eff))
  let assert 2 = list.length(ops)
  let assert True = effect.is_none(rest)
}

pub fn emitted_ignores_other_callbacks_test() {
  let assert [] = stream.emitted(effect.from(fn(_dispatch) { Nil }))
  let assert [] = stream.emitted(effect.none())
}

pub fn perform_crashes_on_a_stream_op_test() {
  let #(result, logs) =
    log_capture.capture(fn() {
      rescue(fn() {
        effect.perform(
          stream.insert(log(), Line(1, "a"), at: Append),
          fn(_msg) { Nil },
          fn(_key, _generation, _msg) { Nil },
        )
      })
    })
  let assert Error(#("error", _)) = result
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "1 stream op(s), the first for stream log",
      "take_stream_ops",
    ])
}

// --- round_trip -------------------------------------------------------------

pub fn round_trip_of_a_matching_codec_test() {
  let line = Line(3, "quote \" and unicode é")
  let assert Ok(decoded) = stream.round_trip(log(), line)
  let assert True = decoded == line
}

pub fn round_trip_names_a_decoder_mismatch_test() {
  let s =
    stream.new(
      "log",
      key: line_key,
      encode: fn(line: Line) { json.object([#("id", json.int(line.id))]) },
      decoder: line_decoder(),
      limit: KeepLast(3),
    )
  let assert Error(message) = stream.round_trip(s, Line(1, "a"))
  let assert True = string.contains(message, "text")
  let assert True = string.starts_with(message, "the decoder refused")
}

pub fn round_trip_names_a_wrong_type_test() {
  let s =
    stream.new(
      "log",
      key: line_key,
      encode: fn(line: Line) {
        json.object([
          #("id", json.string(int.to_string(line.id))),
          #("text", json.string(line.text)),
        ])
      },
      decoder: line_decoder(),
      limit: KeepLast(3),
    )
  let assert Error(message) = stream.round_trip(s, Line(1, "a"))
  let assert True = string.contains(message, "expected Int at id")
}

// --- Helpers ----------------------------------------------------------------

fn emitted_key(emitted: stream.Emitted) -> String {
  case emitted {
    Inserted(key:, ..) -> key
    Deleted(key:, ..) -> key
    stream.Reset(..) -> panic as "stream_test: a reset has no single key"
  }
}

fn ops_of(eff: Effect(msg)) -> List(stream_op.Op) {
  let #(ops, rest) = effect.take_stream_ops(eff)
  let assert True = effect.is_none(rest)
  ops
}

fn apply(windows: stream_window.Windows, ops: Effect(msg)) {
  let assert Ok(applied) =
    stream_window.apply_update(
      windows,
      ops_of(ops),
      stream_window.default_limits(),
    )
  applied.windows
}
