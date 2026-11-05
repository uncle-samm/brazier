//// The presence scenario of the benchmark suite: one tracker
//// (brazier/presence) per room size, the room filled by holder processes
//// before anything is timed, so the timed work runs against a room of
//// that many entries.
////
//// - presence.track.N / presence.untrack.N: the bench process tracks a
////   fresh key and waits for the diff that joins it, then untracks it and
////   waits for the diff that removes it (brazier_bench_ffi:presence_round).
////   Each wait is the full trip a subscriber sees: the shard call, the ETS
////   write and the PubSub delivery. Every diff is checked to name exactly
////   that key of this process.
//// - presence.list.N: `presence.list` of the room, the ETS read of every
////   entry (the shard stored each meta decoded), checked to return all N
////   entries. Each list runs in a fresh process whose heap holds all it
////   allocates, after one untimed list in that process, proven free of
////   garbage collection (list_samples).

import brazier/bench/measure.{check}
import brazier/bench/report.{type Metric}
import brazier/presence
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/json
import gleam/list
import gleam/result

const tracker_name = "brazier_bench_presence"

const topic = "bench:room"

/// Room sizes, and the holders that fill each: a tracker accepts at most
/// `max_topics_per_pid` (100 by default) tracks per process, so a room of
/// 10000 entries takes 100 holders of 100 keys.
/// #(entries, holders, keys per holder, timed lists): a list of 10
/// entries takes microseconds, so it is timed many more times for its p99.
fn rooms() -> List(#(Int, Int, Int, Int)) {
  [#(10, 1, 10, 2000), #(10_000, 100, 100, 50)]
}

const warmup_ops = 200

const ops = 10_000

const list_warmup = 5

@external(erlang, "brazier_bench_ffi", "presence_fill")
fn presence_fill(
  presence: presence.Presence(String),
  topic: String,
  holders: Int,
  keys_per_holder: Int,
  timeout_ms: Int,
) -> Result(List(#(Pid, process.Monitor)), String)

@external(erlang, "brazier_bench_ffi", "presence_release")
fn presence_release(
  holders: List(#(Pid, process.Monitor)),
  timeout_ms: Int,
) -> Result(Nil, String)

@external(erlang, "brazier_bench_ffi", "presence_list_sample")
fn presence_list_sample(
  presence: presence.Presence(String),
  topic: String,
  entries: Int,
  timeout_ms: Int,
) -> Result(Int, String)

@external(erlang, "brazier_bench_ffi", "presence_round")
fn presence_round(
  presence: presence.Presence(String),
  topic: String,
  diff_topic: String,
  ops: Int,
  timeout_ms: Int,
) -> Result(#(List(Int), List(Int)), String)

pub fn run() -> Result(List(Metric), String) {
  list.try_map(rooms(), fn(room) {
    let #(entries, holders, keys, lists) = room
    let suffix = "." <> int.to_string(entries)
    room_scenario(entries, holders, keys, lists, suffix)
    |> result.map_error(fn(reason) { "presence" <> suffix <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

fn room_scenario(
  entries: Int,
  holders: Int,
  keys: Int,
  lists: Int,
  suffix: String,
) -> Result(List(Metric), String) {
  // INVARIANT: rooms() lists holders x keys == entries.
  let assert True = holders * keys == entries
    as "every presence room is holders x keys entries"
  use tracker <- result.try(
    presence.new(tracker_name, json.string, decode.string)
    |> presence.start
    |> result.map_error(fn(e) { "start: " <> presence.describe(e) }),
  )
  let outcome = {
    use filled <- result.try(presence_fill(
      tracker,
      topic,
      holders,
      keys,
      measure.timeout_ms,
    ))
    let measured = measure_room(tracker, entries, lists, suffix)
    use Nil <- result.try(presence_release(filled, measure.timeout_ms))
    measured
  }
  let stopped =
    presence.stop(tracker)
    |> result.map_error(fn(e) { "stop: " <> presence.describe(e) })
  case outcome, stopped {
    Ok(metrics), Ok(Nil) -> Ok(metrics)
    Error(reason), _ -> Error(reason)
    Ok(_), Error(reason) -> Error(reason)
  }
}

fn measure_room(
  tracker: presence.Presence(String),
  entries: Int,
  lists: Int,
  suffix: String,
) -> Result(List(Metric), String) {
  use Nil <- result.try(expect_listed(tracker, entries))
  use Nil <- result.try(
    presence.subscribe(tracker, topic)
    |> result.map_error(fn(e) { "subscribe: " <> presence.describe(e) }),
  )
  let diff_topic = presence.diff_topic(tracker, topic)
  let rounds = {
    use _ <- result.try(presence_round(
      tracker,
      topic,
      diff_topic,
      warmup_ops,
      measure.timeout_ms,
    ))
    measure.gc()
    presence_round(tracker, topic, diff_topic, ops, measure.timeout_ms)
  }
  let unsubscribed =
    presence.unsubscribe(tracker, topic)
    |> result.map_error(fn(e) { "unsubscribe: " <> presence.describe(e) })
  use #(tracks, untracks) <- result.try(rounds)
  use Nil <- result.try(unsubscribed)
  use Nil <- result.try(measure.expect_empty_mailbox("presence" <> suffix))
  use <- check(
    list.length(tracks) == ops && list.length(untracks) == ops,
    "expected " <> int.to_string(ops) <> " tracks and untracks",
  )
  use listed <- result.try(list_samples(tracker, entries, lists))
  use track <- result.try(measure.median_and_p99(
    "presence.track" <> suffix,
    "us",
    list.map(tracks, ns_to_us),
  ))
  use untrack <- result.try(measure.median_and_p99(
    "presence.untrack" <> suffix,
    "us",
    list.map(untracks, ns_to_us),
  ))
  use listing <- result.try(measure.median_and_p99(
    "presence.list" <> suffix,
    "us",
    listed,
  ))
  Ok(list.flatten([track, untrack, listing]))
}

/// Time `presence.list` of the room `lists` times (after `list_warmup`),
/// in microseconds, each checked to return all `entries` entries. Each
/// list runs in a fresh process whose heap holds all it allocates, after
/// one untimed list there that warms its caches, and a sample in which a
/// garbage collection ran fails the run
/// (brazier_bench_ffi:presence_list_sample), so the samples time the list,
/// not the collection of whatever heap the caller had.
fn list_samples(
  tracker: presence.Presence(String),
  entries: Int,
  lists: Int,
) -> Result(List(Float), String) {
  let once = fn() {
    presence_list_sample(tracker, topic, entries, measure.timeout_ms)
    |> result.map(ns_to_us)
  }
  use _ <- result.try(measure.repeat(list_warmup, once))
  measure.repeat(lists, once)
}

fn expect_listed(
  tracker: presence.Presence(String),
  entries: Int,
) -> Result(Nil, String) {
  use found <- result.try(
    presence.list(tracker, topic)
    |> result.map_error(fn(e) { "list: " <> presence.describe(e) }),
  )
  let count = list.length(found)
  check(
    count == entries,
    "the filled room lists " <> int.to_string(count) <> " entries",
    fn() { Ok(Nil) },
  )
}

fn ns_to_us(ns: Int) -> Float {
  int.to_float(ns) /. 1000.0
}
