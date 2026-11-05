//// Unit tests for `brazier/internal/stream_window`: every op and position,
//// trims at both ends, in-place updates, deletes, resets, every bound, the
//// item snapshot and the wire text of a delta.

import brazier/internal/stream_op.{type Limit, type Op, Back, Front, Op}
import brazier/internal/stream_window.{
  type Applied, type Windows, Applied, Change, Delta, DeltaInsert,
}
import gleam/list
import gleam/string

// --- Helpers ----------------------------------------------------------------

fn last(count: Int) -> Limit {
  stream_op.Limit(keep: stream_op.Last, count: count)
}

fn first(count: Int) -> Limit {
  stream_op.Limit(keep: stream_op.First, count: count)
}

fn item(key: String) -> String {
  "{\"k\":\"" <> key <> "\"}"
}

fn insert(limit: Limit, key: String, at: stream_op.End) -> Op {
  Op(name: "s", limit: limit, action: stream_op.Insert(key, item(key), at))
}

fn insert_json(limit: Limit, key: String, json: String) -> Op {
  Op(name: "s", limit: limit, action: stream_op.Insert(key, json, Back))
}

fn delete(limit: Limit, key: String) -> Op {
  Op(name: "s", limit: limit, action: stream_op.Delete(key))
}

fn reset(limit: Limit, keys: List(String)) -> Op {
  Op(
    name: "s",
    limit: limit,
    action: stream_op.Reset(list.map(keys, fn(key) { #(key, item(key)) })),
  )
}

fn apply(windows: Windows, ops: List(Op)) -> Applied {
  let assert Ok(applied) =
    stream_window.apply_update(windows, ops, stream_window.default_limits())
  applied
}

/// Windows whose stream "s" holds `keys`, sent already.
fn seeded(limit: Limit, keys: List(String)) -> Windows {
  apply(stream_window.new(keep_items: False), [reset(limit, keys)]).windows
}

fn keys_of(windows: Windows) -> List(String) {
  let assert Ok(keys) = stream_window.keys(windows, "s")
  keys
}

fn one_delta(applied: Applied) -> stream_window.Delta {
  let assert [Change(delta:, ..)] = applied.changes
  delta
}

fn at(key: String, index: Int) -> stream_window.DeltaInsert {
  DeltaInsert(key: key, at: index, json: item(key))
}

// --- Inserts ----------------------------------------------------------------

pub fn append_to_empty_stream_test() {
  let applied =
    apply(stream_window.new(keep_items: False), [
      insert(last(3), "a", Back),
      insert(last(3), "b", Back),
    ])
  let assert ["a", "b"] = keys_of(applied.windows)
  let assert Delta(
    name: "s",
    reset: False,
    deletes: [],
    inserts: [DeltaInsert("a", 0, _), DeltaInsert("b", 1, _)],
    ..,
  ) = one_delta(applied)
  let assert [Change(updated: 0, trimmed: 0, ..)] = applied.changes
}

pub fn prepend_puts_new_key_first_test() {
  let applied =
    apply(seeded(last(5), ["a", "b"]), [insert(last(5), "z", Front)])
  let assert ["z", "a", "b"] = keys_of(applied.windows)
  let assert Delta(deletes: [], inserts: [DeltaInsert("z", 0, _)], ..) =
    one_delta(applied)
}

pub fn append_into_full_keep_last_trims_the_front_test() {
  let applied =
    apply(seeded(last(3), ["a", "b", "c"]), [insert(last(3), "d", Back)])
  let assert ["b", "c", "d"] = keys_of(applied.windows)
  let delta = one_delta(applied)
  let assert True = delta.deletes == ["a"]
  let assert True = delta.inserts == [at("d", 2)]
  let assert [Change(trimmed: 1, updated: 0, ..)] = applied.changes
}

pub fn prepend_into_full_keep_first_trims_the_back_test() {
  let applied =
    apply(seeded(first(3), ["a", "b", "c"]), [insert(first(3), "z", Front)])
  let assert ["z", "a", "b"] = keys_of(applied.windows)
  let delta = one_delta(applied)
  let assert True = delta.deletes == ["c"]
  let assert True = delta.inserts == [at("z", 0)]
  let assert [Change(trimmed: 1, ..)] = applied.changes
}

pub fn prepend_into_full_keep_last_trims_the_new_item_test() {
  let windows = seeded(last(2), ["a", "b"])
  let applied = apply(windows, [insert(last(2), "z", Front)])
  let assert ["a", "b"] = keys_of(applied.windows)
  let assert [] = applied.changes
  let assert "[]" = applied.streams_json
}

pub fn append_into_full_keep_first_trims_the_new_item_test() {
  let applied =
    apply(seeded(first(2), ["a", "b"]), [insert(first(2), "c", Back)])
  let assert ["a", "b"] = keys_of(applied.windows)
  let assert [] = applied.changes
}

pub fn append_into_not_full_keep_first_lands_at_the_end_test() {
  let applied = apply(seeded(first(3), ["a"]), [insert(first(3), "b", Back)])
  let assert ["a", "b"] = keys_of(applied.windows)
  let assert True = one_delta(applied).inserts == [at("b", 1)]
}

pub fn prepend_into_not_full_keep_last_lands_at_the_front_test() {
  let applied = apply(seeded(last(3), ["a"]), [insert(last(3), "z", Front)])
  let assert ["z", "a"] = keys_of(applied.windows)
  let assert True = one_delta(applied).inserts == [at("z", 0)]
}

pub fn insert_of_existing_key_updates_in_place_test() {
  let windows = seeded(last(3), ["a", "b", "c"])
  let applied =
    apply(windows, [
      Op(
        name: "s",
        limit: last(3),
        action: stream_op.Insert("b", "{\"v\":2}", Front),
      ),
    ])
  let assert ["a", "b", "c"] = keys_of(applied.windows)
  let delta = one_delta(applied)
  let assert True = delta.deletes == []
  let assert True = delta.inserts == [DeltaInsert("b", 1, "{\"v\":2}")]
  let assert [Change(updated: 1, trimmed: 0, ..)] = applied.changes
}

pub fn update_in_place_of_full_window_trims_nothing_test() {
  let applied =
    apply(seeded(last(2), ["a", "b"]), [insert_json(last(2), "a", "1")])
  let assert ["a", "b"] = keys_of(applied.windows)
  let assert True = one_delta(applied).inserts == [DeltaInsert("a", 0, "1")]
  let assert [Change(trimmed: 0, updated: 1, ..)] = applied.changes
}

pub fn repeated_inserts_of_one_key_send_the_latest_item_test() {
  let applied =
    apply(stream_window.new(keep_items: False), [
      insert_json(last(3), "a", "1"),
      insert_json(last(3), "a", "2"),
      insert_json(last(3), "a", "3"),
    ])
  let assert ["a"] = keys_of(applied.windows)
  let assert True = one_delta(applied).inserts == [DeltaInsert("a", 0, "3")]
}

pub fn new_item_trimmed_in_the_same_update_is_never_sent_test() {
  let applied =
    apply(stream_window.new(keep_items: False), [
      insert(last(2), "x", Back),
      insert(last(2), "y", Back),
      insert(last(2), "z", Back),
    ])
  let assert ["y", "z"] = keys_of(applied.windows)
  let delta = one_delta(applied)
  let assert True = delta.deletes == []
  let assert True = delta.inserts == [at("y", 0), at("z", 1)]
  let assert [Change(trimmed: 1, ..)] = applied.changes
}

pub fn stable_keys_are_not_resent_test() {
  let applied =
    apply(seeded(last(5), ["a", "b", "c"]), [insert(last(5), "d", Back)])
  let assert True = one_delta(applied).inserts == [at("d", 3)]
}

// --- Deletes ----------------------------------------------------------------

pub fn delete_removes_the_key_test() {
  let applied = apply(seeded(last(3), ["a", "b", "c"]), [delete(last(3), "b")])
  let assert ["a", "c"] = keys_of(applied.windows)
  let delta = one_delta(applied)
  let assert True = delta.deletes == ["b"]
  let assert True = delta.inserts == []
}

pub fn delete_of_missing_key_changes_nothing_and_is_reported_test() {
  let applied =
    apply(seeded(last(3), ["a"]), [
      insert(last(3), "b", Back),
      delete(last(3), "zz"),
    ])
  let assert ["a", "b"] = keys_of(applied.windows)
  let assert True =
    applied.unknown_deletes
    == [stream_window.UnknownDelete(index: 1, stream: "s", key: "zz")]
  // The delete is not on the wire: only the insert is.
  let delta = one_delta(applied)
  let assert True = delta.deletes == []
  let assert True = delta.inserts == [at("b", 1)]
}

pub fn delete_of_missing_key_alone_sends_nothing_test() {
  let applied = apply(seeded(last(3), ["a"]), [delete(last(3), "zz")])
  let assert [] = applied.changes
  let assert [stream_window.UnknownDelete(index: 0, stream: "s", key: "zz")] =
    applied.unknown_deletes
}

pub fn delete_of_unused_stream_is_reported_test() {
  let applied =
    apply(stream_window.new(keep_items: False), [delete(last(3), "a")])
  let assert [] = applied.changes
  let assert [_] = applied.unknown_deletes
  let assert Ok([]) = stream_window.keys(applied.windows, "s")
}

pub fn delete_twice_reports_the_second_test() {
  let applied =
    apply(seeded(last(3), ["a", "b"]), [
      delete(last(3), "a"),
      delete(last(3), "a"),
    ])
  let assert ["b"] = keys_of(applied.windows)
  let assert True = one_delta(applied).deletes == ["a"]
  let assert [stream_window.UnknownDelete(index: 1, ..)] =
    applied.unknown_deletes
}

pub fn delete_then_insert_moves_the_key_test() {
  let applied =
    apply(seeded(last(3), ["a", "b", "c"]), [
      delete(last(3), "a"),
      insert(last(3), "a", Back),
    ])
  let assert ["b", "c", "a"] = keys_of(applied.windows)
  let delta = one_delta(applied)
  let assert True = delta.deletes == ["a"]
  let assert True = delta.inserts == [at("a", 2)]
}

pub fn trimmed_then_inserted_again_is_a_move_test() {
  let applied =
    apply(seeded(last(2), ["a", "b"]), [
      insert(last(2), "c", Back),
      insert(last(2), "a", Front),
    ])
  // "c" trims "a"; "a" prepended into the full KeepLast window is trimmed
  // at once, so the window ends ["b", "c"].
  let assert ["b", "c"] = keys_of(applied.windows)
  let delta = one_delta(applied)
  let assert True = delta.deletes == ["a"]
  let assert True = delta.inserts == [at("c", 1)]
  let assert [Change(trimmed: 2, ..)] = applied.changes
}

pub fn insert_then_delete_of_new_key_sends_nothing_test() {
  let applied =
    apply(seeded(last(3), ["a"]), [
      insert(last(3), "b", Back),
      delete(last(3), "b"),
    ])
  let assert ["a"] = keys_of(applied.windows)
  let assert [] = applied.changes
  let assert [] = applied.unknown_deletes
}

// --- Resets -----------------------------------------------------------------

pub fn reset_replaces_the_window_test() {
  let applied = apply(seeded(last(3), ["a", "b"]), [reset(last(3), ["c", "d"])])
  let assert ["c", "d"] = keys_of(applied.windows)
  let assert Delta(reset: True, deletes: [], inserts:, ..) = one_delta(applied)
  let assert True = inserts == [at("c", 0), at("d", 1)]
}

pub fn reset_to_empty_is_sent_test() {
  let applied = apply(seeded(last(3), ["a", "b"]), [reset(last(3), [])])
  let assert [] = keys_of(applied.windows)
  let assert Delta(reset: True, deletes: [], inserts: [], ..) =
    one_delta(applied)
}

pub fn reset_over_the_limit_trims_test() {
  let applied =
    apply(stream_window.new(keep_items: False), [
      reset(last(2), ["a", "b", "c"]),
      reset(first(2), ["a", "b", "c"])
        |> fn(op) { Op(..op, name: "t") },
    ])
  let assert Ok(["b", "c"]) = stream_window.keys(applied.windows, "s")
  let assert Ok(["a", "b"]) = stream_window.keys(applied.windows, "t")
  let assert [Change(trimmed: 1, ..), Change(trimmed: 1, ..)] = applied.changes
}

pub fn ops_after_a_reset_are_part_of_it_test() {
  let applied =
    apply(seeded(last(3), ["x"]), [
      insert(last(3), "y", Back),
      reset(last(3), ["a"]),
      insert(last(3), "b", Front),
      delete(last(3), "x"),
    ])
  let assert ["b", "a"] = keys_of(applied.windows)
  let assert Delta(reset: True, deletes: [], inserts:, ..) = one_delta(applied)
  let assert True = inserts == [at("b", 0), at("a", 1)]
  // "x" was emptied by the reset, so deleting it afterwards is unknown.
  let assert [stream_window.UnknownDelete(index: 3, ..)] =
    applied.unknown_deletes
}

pub fn reset_with_a_repeated_key_keeps_one_test() {
  let applied =
    apply(stream_window.new(keep_items: False), [
      Op(
        name: "s",
        limit: last(3),
        action: stream_op.Reset([#("a", "1"), #("b", "2"), #("a", "3")]),
      ),
    ])
  let assert ["a", "b"] = keys_of(applied.windows)
  let assert True =
    one_delta(applied).inserts
    == [DeltaInsert("a", 0, "3"), DeltaInsert("b", 1, "2")]
}

// --- Several streams --------------------------------------------------------

pub fn changes_follow_the_order_streams_are_first_used_test() {
  let on = fn(op: Op, name: String) { Op(..op, name: name) }
  let applied =
    apply(stream_window.new(keep_items: False), [
      insert(last(3), "a", Back) |> on("zeta"),
      insert(last(3), "b", Back) |> on("alpha"),
      insert(last(3), "c", Back) |> on("zeta"),
    ])
  let names = list.map(applied.changes, fn(change) { change.delta.name })
  let assert ["zeta", "alpha"] = names
  let assert Ok(["a", "c"]) = stream_window.keys(applied.windows, "zeta")
}

pub fn unused_stream_has_no_window_test() {
  let windows = stream_window.new(keep_items: False)
  let assert Error(Nil) = stream_window.keys(windows, "s")
  let assert Error(Nil) = stream_window.limit(windows, "s")
  let assert Ok(limit) = stream_window.limit(seeded(first(4), []), "s")
  let assert True = limit == first(4)
}

// --- Bounds -----------------------------------------------------------------

fn limits() -> stream_window.Limits {
  stream_window.default_limits()
}

pub fn default_limits_are_the_decided_ones_test() {
  let assert stream_window.Limits(
    max_limit: 1000,
    item_max_bytes: 65_536,
    ops_max_per_update: 1000,
    frame_max_bytes: 1_048_576,
    key_max_bytes: 256,
  ) = limits()
}

pub fn too_many_ops_refuses_the_whole_update_test() {
  let bounds = stream_window.Limits(..limits(), ops_max_per_update: 2)
  let windows = seeded(last(5), ["a"])
  let assert Error(stream_window.TooManyOps(count: 3, max: 2)) =
    stream_window.apply_update(
      windows,
      [
        insert(last(5), "b", Back),
        insert(last(5), "c", Back),
        delete(last(5), "a"),
      ],
      bounds,
    )
  let assert Ok(_) =
    stream_window.apply_update(
      windows,
      [insert(last(5), "b", Back), delete(last(5), "a")],
      bounds,
    )
}

pub fn reset_counts_one_op_per_item_test() {
  let bounds = stream_window.Limits(..limits(), ops_max_per_update: 2)
  let windows = stream_window.new(keep_items: False)
  let assert Error(stream_window.TooManyOps(count: 3, max: 2)) =
    stream_window.apply_update(
      windows,
      [reset(last(5), ["a", "b", "c"])],
      bounds,
    )
  let assert 1 = stream_window.op_count([reset(last(5), [])])
  let assert 4 =
    stream_window.op_count([
      reset(last(5), ["a", "b"]),
      insert(last(5), "c", Back),
      delete(last(5), "a"),
    ])
}

pub fn frame_over_the_bound_refuses_the_whole_update_test() {
  let windows = seeded(last(5), ["a"])
  let ops = [insert(last(5), "b", Back)]
  let assert Ok(applied) = stream_window.apply_update(windows, ops, limits())
  let bytes = string.byte_size(applied.streams_json)
  let at_bound = stream_window.Limits(..limits(), frame_max_bytes: bytes)
  let assert Ok(_) = stream_window.apply_update(windows, ops, at_bound)
  let over = stream_window.Limits(..limits(), frame_max_bytes: bytes - 1)
  let assert Error(stream_window.FrameTooLarge(bytes: refused, max: max)) =
    stream_window.apply_update(windows, ops, over)
  let assert True = refused == bytes && max == bytes - 1
}

pub fn item_over_the_bound_is_refused_and_the_rest_applied_test() {
  let bounds = stream_window.Limits(..limits(), item_max_bytes: 5)
  let windows = seeded(last(5), ["a"])
  let assert Ok(applied) =
    stream_window.apply_update(
      windows,
      [
        insert_json(last(5), "big", "\"12345\""),
        insert_json(last(5), "ok", "12345"),
      ],
      bounds,
    )
  let assert ["a", "ok"] = keys_of(applied.windows)
  let assert True =
    applied.refused
    == [
      stream_window.OpRefusal(
        index: 0,
        stream: "s",
        reason: stream_window.ItemTooLarge(bytes: 7, max: 5),
      ),
    ]
  let assert True =
    one_delta(applied).inserts == [DeltaInsert("ok", 1, "12345")]
}

pub fn key_over_the_bound_is_refused_test() {
  let bounds = stream_window.Limits(..limits(), key_max_bytes: 3)
  let windows = seeded(last(5), ["a"])
  let assert Ok(applied) =
    stream_window.apply_update(
      windows,
      [
        insert(last(5), "abcd", Back),
        insert(last(5), "abc", Back),
        delete(last(5), "wxyz"),
      ],
      bounds,
    )
  let assert ["a", "abc"] = keys_of(applied.windows)
  let assert [
    stream_window.OpRefusal(
      index: 0,
      reason: stream_window.KeyTooLarge(bytes: 4, max: 3),
      ..,
    ),
    stream_window.OpRefusal(
      index: 2,
      reason: stream_window.KeyTooLarge(bytes: 4, max: 3),
      ..,
    ),
  ] = applied.refused
  // A refused delete is not an unknown delete: it never ran.
  let assert [] = applied.unknown_deletes
}

pub fn key_bytes_count_utf8_bytes_test() {
  let bounds = stream_window.Limits(..limits(), key_max_bytes: 3)
  let assert Ok(applied) =
    stream_window.apply_update(
      stream_window.new(keep_items: False),
      [insert(last(5), "éé", Back)],
      bounds,
    )
  let assert [
    stream_window.OpRefusal(
      reason: stream_window.KeyTooLarge(bytes: 4, max: 3),
      ..,
    ),
  ] = applied.refused
}

pub fn empty_key_is_refused_for_every_op_test() {
  let windows = seeded(last(5), ["a"])
  let applied =
    apply(windows, [
      insert(last(5), "", Back),
      delete(last(5), ""),
      reset(last(5), ["b", ""]),
    ])
  let assert ["a"] = keys_of(applied.windows)
  let assert [] = applied.changes
  let reasons = list.map(applied.refused, fn(refusal) { refusal.reason })
  let assert [
    stream_window.KeyEmpty,
    stream_window.KeyEmpty,
    stream_window.KeyEmpty,
  ] = reasons
  let assert ["key_empty", ..] = list.map(reasons, stream_window.op_reason_name)
}

pub fn reset_with_one_bad_item_is_refused_whole_test() {
  let bounds = stream_window.Limits(..limits(), item_max_bytes: 3)
  let windows = seeded(last(5), ["a"])
  let assert Ok(applied) =
    stream_window.apply_update(
      windows,
      [
        Op(
          name: "s",
          limit: last(5),
          action: stream_op.Reset([#("b", "1"), #("c", "1234")]),
        ),
      ],
      bounds,
    )
  let assert ["a"] = keys_of(applied.windows)
  let assert [] = applied.changes
  let assert [
    stream_window.OpRefusal(
      reason: stream_window.ItemTooLarge(bytes: 4, max: 3),
      ..,
    ),
  ] = applied.refused
}

pub fn limit_over_the_maximum_is_refused_test() {
  let windows = stream_window.new(keep_items: False)
  let applied =
    apply(windows, [
      insert(last(1001), "a", Back),
      insert(first(0), "b", Back) |> fn(op) { Op(..op, name: "t") },
      insert(last(1000), "c", Back) |> fn(op) { Op(..op, name: "u") },
    ])
  let assert [
    stream_window.OpRefusal(
      index: 0,
      stream: "s",
      reason: stream_window.LimitOutOfRange(count: 1001, max: 1000),
    ),
    stream_window.OpRefusal(
      index: 1,
      stream: "t",
      reason: stream_window.LimitOutOfRange(count: 0, max: 1000),
    ),
  ] = applied.refused
  // No window is made for a refused limit; the limit at the bound is fine.
  let assert Error(Nil) = stream_window.keys(applied.windows, "s")
  let assert Error(Nil) = stream_window.keys(applied.windows, "t")
  let assert Ok(["c"]) = stream_window.keys(applied.windows, "u")
}

pub fn limit_mismatch_is_refused_test() {
  let windows = seeded(last(3), ["a"])
  let applied =
    apply(windows, [insert(first(3), "b", Back), insert(last(4), "c", Back)])
  let assert ["a"] = keys_of(applied.windows)
  let assert [
    stream_window.OpRefusal(
      index: 0,
      reason: stream_window.LimitMismatch(window: w0, op: o0),
      ..,
    ),
    stream_window.OpRefusal(
      index: 1,
      reason: stream_window.LimitMismatch(window: w1, op: o1),
      ..,
    ),
  ] = applied.refused
  let assert True = w0 == last(3) && o0 == first(3)
  let assert True = w1 == last(3) && o1 == last(4)
}

pub fn limit_mismatch_inside_one_update_is_refused_test() {
  let applied =
    apply(stream_window.new(keep_items: False), [
      insert(last(3), "a", Back),
      insert(last(2), "b", Back),
    ])
  let assert ["a"] = keys_of(applied.windows)
  let assert [
    stream_window.OpRefusal(
      index: 1,
      reason: stream_window.LimitMismatch(..),
      ..,
    ),
  ] = applied.refused
  let assert "limit_mismatch" =
    stream_window.op_reason_name(stream_window.LimitMismatch(last(3), last(2)))
}

pub fn first_op_fixes_the_limit_even_when_refused_test() {
  let bounds = stream_window.Limits(..limits(), item_max_bytes: 1)
  let assert Ok(applied) =
    stream_window.apply_update(
      stream_window.new(keep_items: False),
      [insert_json(last(3), "a", "12"), insert_json(last(4), "b", "1")],
      bounds,
    )
  let assert Ok([]) = stream_window.keys(applied.windows, "s")
  let reasons = list.map(applied.refused, fn(refusal) { refusal.reason })
  let assert [stream_window.ItemTooLarge(..), stream_window.LimitMismatch(..)] =
    reasons
}

pub fn update_refusal_names_test() {
  let assert "too_many_ops" =
    stream_window.update_refusal_name(stream_window.TooManyOps(2, 1))
  let assert "frame_too_large" =
    stream_window.update_refusal_name(stream_window.FrameTooLarge(2, 1))
  let assert ["limit_out_of_range", "key_too_large", "item_too_large"] =
    list.map(
      [
        stream_window.LimitOutOfRange(0, 1000),
        stream_window.KeyTooLarge(300, 256),
        stream_window.ItemTooLarge(70_000, 65_536),
      ],
      stream_window.op_reason_name,
    )
}

// --- Items before the first join --------------------------------------------

pub fn snapshot_sends_kept_items_once_test() {
  let on = fn(op: Op, name: String) { Op(..op, name: name) }
  let windows = stream_window.new(keep_items: True)
  let windows =
    apply(windows, [
      insert(last(2), "a", Back) |> on("log"),
      insert(last(2), "b", Back) |> on("log"),
      insert_json(last(2), "a", "9") |> on("log"),
      insert(last(2), "c", Back) |> on("log"),
      insert(first(3), "x", Back) |> on("feed"),
      insert(first(3), "y", Back) |> on("empty"),
    ]).windows
  let windows = apply(windows, [delete(first(3), "y") |> on("empty")]).windows
  let assert Ok(#(deltas, windows)) = stream_window.snapshot(windows)
  // Name order; the empty window is not sent; the trimmed "a" is gone.
  let assert True =
    deltas
    == [
      Delta(name: "feed", limit: first(3), reset: True, deletes: [], inserts: [
        at("x", 0),
      ]),
      Delta(name: "log", limit: last(2), reset: True, deletes: [], inserts: [
        at("b", 0),
        at("c", 1),
      ]),
    ]
  let assert Error(stream_window.ItemsNotKept) = stream_window.snapshot(windows)
  // The keys stay, so later deltas are computed against them.
  let assert Ok(["b", "c"]) = stream_window.keys(windows, "log")
  let applied = apply(windows, [insert(last(2), "d", Back) |> on("log")])
  let assert True = one_delta(applied).deletes == ["b"]
}

pub fn snapshot_keeps_the_latest_item_of_an_update_test() {
  let windows =
    apply(stream_window.new(keep_items: True), [
      insert_json(last(3), "a", "1"),
      insert_json(last(3), "b", "2"),
    ]).windows
  let windows = apply(windows, [insert_json(last(3), "a", "3")]).windows
  let assert Ok(#([Delta(inserts:, ..)], _)) = stream_window.snapshot(windows)
  let assert True =
    inserts == [DeltaInsert("a", 0, "3"), DeltaInsert("b", 1, "2")]
}

pub fn snapshot_of_windows_without_items_is_an_error_test() {
  let assert Error(stream_window.ItemsNotKept) =
    stream_window.snapshot(seeded(last(3), ["a"]))
}

// --- Key count and emptied windows ------------------------------------------

pub fn key_count_sums_every_window_test() {
  let assert 0 = stream_window.key_count(stream_window.new(keep_items: False))
  let windows =
    apply(seeded(last(3), ["a", "b"]), [
      Op(
        name: "t",
        limit: first(5),
        action: stream_op.Insert("x", item("x"), Back),
      ),
    ]).windows
  let assert 3 = stream_window.key_count(windows)
}

pub fn emptied_windows_keep_each_limit_and_no_item_test() {
  let windows =
    apply(stream_window.new(keep_items: True), [
      insert(last(3), "a", Back),
      insert(last(3), "b", Back),
    ]).windows
  let emptied = stream_window.emptied(windows)
  let assert 0 = stream_window.key_count(emptied)
  let assert Ok([]) = stream_window.keys(emptied, "s")
  let assert Ok(limit) = stream_window.limit(emptied, "s")
  let assert True = limit == last(3)
  // No item is kept once emptied: nothing is sent again.
  let assert Error(stream_window.ItemsNotKept) = stream_window.snapshot(emptied)
  // The limit the stream was first used with still holds (design 7.5).
  let assert Ok(stream_window.Applied(refused: [refusal], ..)) =
    stream_window.apply_update(
      emptied,
      [insert(first(3), "c", Back)],
      stream_window.default_limits(),
    )
  let assert stream_window.LimitMismatch(..) = refusal.reason
  // An insert into the emptied window is placed as in a fresh one.
  let applied = apply(emptied, [insert(last(3), "c", Back)])
  let assert ["c"] = keys_of(applied.windows)
  let assert [at_c] = one_delta(applied).inserts
  let assert True = at_c == at("c", 0)
}

// --- Wire text --------------------------------------------------------------

pub fn delta_wire_text_test() {
  let delta =
    Delta(
      name: "log",
      limit: last(300),
      reset: False,
      deletes: ["a\"1"],
      inserts: [DeltaInsert("b", 299, "{\"text\":\"hi\"}")],
    )
  let assert "{\"name\":\"log\",\"keep\":\"last\",\"limit\":300,\"reset\":false,\"deletes\":[\"a\\\"1\"],\"inserts\":[{\"key\":\"b\",\"at\":299,\"item\":{\"text\":\"hi\"}}]}" =
    stream_window.encode_delta(delta)
  let assert "[]" = stream_window.encode_deltas([])
  let reset =
    Delta(name: "f", limit: first(1), reset: True, deletes: [], inserts: [])
  let assert "[{\"name\":\"f\",\"keep\":\"first\",\"limit\":1,\"reset\":true,\"deletes\":[],\"inserts\":[]},{\"name\":\"f\",\"keep\":\"first\",\"limit\":1,\"reset\":true,\"deletes\":[],\"inserts\":[]}]" =
    stream_window.encode_deltas([reset, reset])
}

pub fn applied_streams_json_is_the_encoded_changes_test() {
  let applied =
    apply(seeded(last(3), ["a", "b", "c"]), [insert(last(3), "d", Back)])
  let assert Applied(streams_json:, changes: [Change(delta:, ..)], ..) = applied
  let assert True = streams_json == stream_window.encode_deltas([delta])
}

// --- Descriptions -----------------------------------------------------------

pub fn describe_limit_uses_the_app_spelling_test() {
  let assert "KeepLast(300)" = stream_window.describe_limit(last(300))
  let assert "KeepFirst(1)" = stream_window.describe_limit(first(1))
}

pub fn describe_op_reason_names_the_sizes_test() {
  let assert "the limit 2000 is outside 1 to 1000" =
    stream_window.describe_op_reason(stream_window.LimitOutOfRange(2000, 1000))
  let assert "the stream was first used with KeepLast(3), this op uses KeepFirst(3)" =
    stream_window.describe_op_reason(stream_window.LimitMismatch(
      last(3),
      first(3),
    ))
  let assert "the key is empty" =
    stream_window.describe_op_reason(stream_window.KeyEmpty)
  let assert "the key is 300 bytes, over the limit of 256" =
    stream_window.describe_op_reason(stream_window.KeyTooLarge(300, 256))
  let assert "the item is 70000 bytes, over the limit of 65536" =
    stream_window.describe_op_reason(stream_window.ItemTooLarge(70_000, 65_536))
}

pub fn describe_update_refusal_names_the_sizes_test() {
  let assert "the update carries 1001 stream ops, over the limit of 1000" =
    stream_window.describe_update_refusal(stream_window.TooManyOps(1001, 1000))
  let assert "the update's stream entries are 2000000 bytes, over the frame limit of 1048576" =
    stream_window.describe_update_refusal(stream_window.FrameTooLarge(
      2_000_000,
      1_048_576,
    ))
}
