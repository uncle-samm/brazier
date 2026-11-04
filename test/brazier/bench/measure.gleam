//// What every bench scenario shares: the clock, the bound on every wait,
//// repetition, checks, and turning samples into metrics.

import brazier/bench/report.{type Metric, HigherIsBetter, LowerIsBetter, Metric}
import brazier/bench/stats
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Every wait inside a round is bounded by this; a round that misses it
/// fails the run.
pub const timeout_ms = 30_000

/// Measured rounds per throughput scenario.
pub const rounds = 5

@external(erlang, "brazier_bench_ffi", "now_ns")
pub fn now_ns() -> Int

/// Collect garbage in the calling process, so one scenario's heap does not
/// charge the next one's first round.
@external(erlang, "brazier_bench_ffi", "gc")
pub fn gc() -> Nil

/// Ok when the calling process's mailbox is empty, else an Error naming
/// `scenario` and the stray messages.
@external(erlang, "brazier_bench_ffi", "expect_empty_mailbox")
pub fn expect_empty_mailbox(scenario: String) -> Result(Nil, String)

/// Run `scenario` in a fresh process and return its result, so it is not
/// timed through the bench process's heap, which grows run over run. Its
/// mailbox must be empty when it finishes, and so must the caller's after.
@external(erlang, "brazier_bench_ffi", "isolated")
pub fn isolated(
  name: String,
  scenario: fn() -> Result(a, String),
) -> Result(a, String)

/// Run `step` `times` times, stopping at the first error.
pub fn repeat(
  times: Int,
  step: fn() -> Result(a, String),
) -> Result(List(a), String) {
  int.range(from: 0, to: times, with: Ok([]), run: fn(acc, _) {
    use done <- result.try(acc)
    use value <- result.try(step())
    Ok([value, ..done])
  })
  |> result.map(list.reverse)
}

/// `repeat` for steps that thread a clock: each step gets the clock the
/// previous one returned. Returns the last clock and every step's value.
pub fn repeat_from(
  times: Int,
  clock: Int,
  step: fn(Int) -> Result(#(Int, a), String),
) -> Result(#(Int, List(a)), String) {
  int.range(from: 0, to: times, with: Ok(#(clock, [])), run: fn(acc, _) {
    use #(clock, done) <- result.try(acc)
    use #(next, value) <- result.try(step(clock))
    Ok(#(next, [value, ..done]))
  })
  |> result.map(fn(acc) { #(acc.0, list.reverse(acc.1)) })
}

/// `next()` when `condition` holds, else `Error(message)`.
pub fn check(
  condition: Bool,
  message: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(message)
  }
}

pub fn string_of(value: a) -> String {
  string.inspect(value)
}

/// From rounds of #(elapsed_us, latencies_us): the median round's
/// throughput, and the median over rounds of each round's latency p50 and
/// p99. Each round must hold `per_round` latencies.
///
/// The latency percentiles are taken per round, like the throughput, and
/// not over the samples of every round pooled: on a shared machine a burst
/// of outside load that slows part of one round would put all its slow
/// samples into a pooled p99, and decide it. A slowdown in the code shows
/// in every round's p99 and so moves their median; a burst in fewer than
/// half the rounds does not.
pub fn throughput_and_latency(
  name: String,
  unit: String,
  per_round: Int,
  samples: List(#(Int, List(Int))),
) -> Result(List(Metric), String) {
  use <- check(samples != [], name <> ": no rounds")
  use per_round_latency <- result.try(
    list.try_map(samples, fn(sample) {
      let count = list.length(sample.1)
      use <- check(
        count == per_round,
        name
          <> ": expected "
          <> int.to_string(per_round)
          <> " latencies in a round, got "
          <> int.to_string(count),
      )
      use <- check(sample.0 > 0, name <> ": a round took no time")
      stats.summarize_ints(sample.1)
      |> result.replace_error(name <> ": a round has no latencies")
    }),
  )
  let rates =
    list.map(samples, fn(sample) {
      int.to_float(per_round) /. { int.to_float(sample.0) /. 1_000_000.0 }
    })
  let median_of = fn(values) {
    stats.median(values) |> result.replace_error(name <> ": no rounds")
  }
  use rate <- result.try(median_of(rates))
  use p50 <- result.try(
    median_of(list.map(per_round_latency, fn(s) { s.median })),
  )
  use p99 <- result.try(median_of(list.map(per_round_latency, fn(s) { s.p99 })))
  Ok([
    Metric(name <> ".throughput", unit, HigherIsBetter, rate),
    Metric(name <> ".latency_p50", "us", LowerIsBetter, p50),
    Metric(name <> ".latency_p99", "us", LowerIsBetter, p99),
  ])
}

/// `percentiles_by_round` of `samples` as `name.median` and `name.p99`.
pub fn median_and_p99(
  name: String,
  unit: String,
  samples: List(Float),
) -> Result(List(Metric), String) {
  use #(median, p99) <- result.try(percentiles_by_round(name, samples))
  Ok([
    Metric(name <> ".median", unit, LowerIsBetter, median),
    Metric(name <> ".p99", unit, LowerIsBetter, p99),
  ])
}

/// The #(median, p99) of `samples`, which must be in the order they were
/// taken: `samples` is cut into `rounds` consecutive rounds of equal size,
/// and each is the median over rounds of that round's median or p99. Their
/// count must split into `rounds`.
///
/// This is `throughput_and_latency`'s rule for scenarios that time one
/// long sequence. A burst of outside load covers consecutive samples, so
/// it lands in one or two rounds and does not set the result. A pooled p99
/// of 50 block timings is the slowest block, and one preempted block set it.
/// A slowdown in the code is in every round and moves the median.
pub fn percentiles_by_round(
  name: String,
  samples: List(Float),
) -> Result(#(Float, Float), String) {
  let count = list.length(samples)
  use <- check(
    count >= rounds && count % rounds == 0,
    name
      <> ": "
      <> int.to_string(count)
      <> " samples do not split into "
      <> int.to_string(rounds)
      <> " equal rounds",
  )
  use summaries <- result.try(
    list.sized_chunk(samples, count / rounds)
    |> list.try_map(stats.summarize)
    |> result.replace_error(name <> ": a round has no samples"),
  )
  let median_of = fn(values) {
    stats.median(values) |> result.replace_error(name <> ": no rounds")
  }
  use median <- result.try(median_of(list.map(summaries, fn(s) { s.median })))
  use p99 <- result.try(median_of(list.map(summaries, fn(s) { s.p99 })))
  Ok(#(median, p99))
}
