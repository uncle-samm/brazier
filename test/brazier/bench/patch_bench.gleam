//// The patch scenario of the benchmark suite: the server diff of a
//// sliding window, the "last N events" timeline that drops its oldest
//// event and appends a new one on every update.
////
//// - patch.window_N.ops / patch.window_N.bytes: how many ops the diff of
////   one slide emits and how many bytes of JSON they encode to. Both are
////   exact; they move only when the diff changes.
//// - patch.window_N.diff: `patch.diff_snapshots` of one slide, the
////   runtime's per-event diff on cached snapshots, in blocks of diffs.
////
//// Every diff is checked to be the one verified before timing: its ops
//// applied to the old document give the new one.

import brazier/bench/measure.{check}
import brazier/bench/report.{type Metric, LowerIsBetter, Metric}
import brazier/patch
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// #(window length, diffs per timed block, timed blocks). The blocks split
/// into `measure.rounds` rounds; a larger window takes longer per diff, so
/// it times fewer per block.
const windows = [#(200, 50, 200), #(2000, 5, 200)]

const warmup_blocks = 10

/// The first event of the old window; the new one starts one later.
const window_start = 1000

pub fn run() -> Result(List(Metric), String) {
  list.try_map(windows, fn(window) {
    let #(length, per_block, blocks) = window
    let name = "patch.window_" <> int.to_string(length)
    window_scenario(name, length, per_block, blocks)
    |> result.map_error(fn(reason) { name <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

fn window_scenario(
  name: String,
  length: Int,
  per_block: Int,
  blocks: Int,
) -> Result(List(Metric), String) {
  let old_json = window_json(window_start, length)
  let new_json = window_json(window_start + 1, length)
  use old <- result.try(patch.snapshot(old_json))
  use new <- result.try(patch.snapshot(new_json))
  use ops_json <- result.try(case patch.diff_snapshots(old, new) {
    patch.Ops(json) -> Ok(json)
    patch.Unchanged -> Error("a slide diffed as unchanged")
  })
  use Nil <- result.try(expect_applies(old_json, ops_json, new_json))
  use ops <- result.try(patch.count_ops(ops_json))
  let expected = patch.Ops(ops_json)
  let block = fn() { diff_block(old, new, expected, per_block) }
  use _ <- result.try(measure.repeat(warmup_blocks, block))
  measure.gc()
  use per_diff <- result.try(measure.repeat(blocks, block))
  use timing <- result.try(measure.median_and_p99(
    name <> ".diff",
    "us",
    per_diff,
  ))
  Ok([
    Metric(name <> ".ops", "ops", LowerIsBetter, int.to_float(ops)),
    Metric(
      name <> ".bytes",
      "bytes",
      LowerIsBetter,
      int.to_float(string.byte_size(ops_json)),
    ),
    ..timing
  ])
}

/// Diff the slide `per_block` times; microseconds per diff, after checking
/// every diff gave the verified ops.
fn diff_block(
  old: patch.Snapshot,
  new: patch.Snapshot,
  expected: patch.Diff,
  per_block: Int,
) -> Result(Float, String) {
  let t0 = measure.now_ns()
  let wrong =
    int.range(from: 0, to: per_block, with: 0, run: fn(wrong, _) {
      case patch.diff_snapshots(old, new) == expected {
        True -> wrong
        False -> wrong + 1
      }
    })
  let t1 = measure.now_ns()
  use <- check(
    wrong == 0,
    int.to_string(wrong) <> " diffs differ from the verified ops",
  )
  Ok(int.to_float(t1 - t0) /. 1000.0 /. int.to_float(per_block))
}

/// The ops applied to `old_json` must give `new_json` (both re-encoded by
/// the patch engine, so key order does not matter).
fn expect_applies(
  old_json: String,
  ops_json: String,
  new_json: String,
) -> Result(Nil, String) {
  use applied <- result.try(patch.apply_ops(old_json, ops_json))
  use canonical_new <- result.try(patch.apply_ops(new_json, "[]"))
  check(applied == canonical_new, "the ops do not give the new window", fn() {
    Ok(Nil)
  })
}

/// A timeline model holding events `first` .. `first + length - 1`.
fn window_json(first: Int, length: Int) -> String {
  let events =
    int.range(
      from: first + length - 1,
      to: first - 1,
      with: [],
      run: fn(acc, id) { [event(id), ..acc] },
    )
  json.object([
    #("count", json.int(first + length)),
    #("events", json.preprocessed_array(events)),
  ])
  |> json.to_string
}

fn event(id: Int) -> json.Json {
  json.object([
    #("id", json.int(id)),
    #("kind", json.string("click")),
    #("at", json.int(1_700_000_000_000 + id * 1000)),
    #("label", json.string("event number " <> int.to_string(id))),
  ])
}
