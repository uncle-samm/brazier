import brazier/bench/measure
import brazier/bench/report.{HigherIsBetter, LowerIsBetter, Metric}
import gleam/int
import gleam/list
import gleam/string

/// A round of 100 latencies, 1..100 us times `scale`, in 1 s.
fn round(scale: Int) -> #(Int, List(Int)) {
  #(
    1_000_000,
    int.range(from: 100, to: 0, with: [], run: fn(acc, i) { [i * scale, ..acc] }),
  )
}

pub fn throughput_and_latency_takes_the_median_round_test() {
  let assert Ok(metrics) =
    measure.throughput_and_latency("x", "req/s", 100, [
      round(1),
      round(1),
      round(1),
    ])
    as "three full rounds make metrics"
  assert metrics
    == [
      Metric("x.throughput", "req/s", HigherIsBetter, 100.0),
      Metric("x.latency_p50", "us", LowerIsBetter, 50.5),
      Metric("x.latency_p99", "us", LowerIsBetter, 99.0),
    ]
}

pub fn throughput_and_latency_ignores_a_burst_in_one_round_test() {
  // One round slowed tenfold, as outside load does to part of a run.
  // Pooled, its samples would be the slowest 25% and decide the p99.
  let assert Ok(metrics) =
    measure.throughput_and_latency("x", "req/s", 100, [
      round(1),
      round(10),
      round(1),
    ])
    as "three full rounds make metrics"
  let assert [_, _, p99] = metrics as "three metrics"
  assert p99.value == 99.0
}

pub fn throughput_and_latency_sees_a_slowdown_in_every_round_test() {
  let assert Ok(metrics) =
    measure.throughput_and_latency("x", "req/s", 100, [
      round(2),
      round(2),
      round(2),
    ])
    as "three full rounds make metrics"
  let assert [_, p50, p99] = metrics as "three metrics"
  assert p50.value == 101.0
  assert p99.value == 198.0
}

pub fn throughput_and_latency_refuses_a_short_round_test() {
  let #(elapsed, latencies) = round(1)
  let short = #(elapsed, list.drop(latencies, 1))
  let assert Error(reason) =
    measure.throughput_and_latency("x", "req/s", 100, [round(1), short])
    as "a round missing a latency is an error"
  assert string.contains(reason, "expected 100 latencies in a round, got 99")
}

/// `measure.rounds` rounds of 1..100 in time order, with the rounds at
/// the given indexes times `scale`.
fn sequence(slow: List(Int), scale: Float) -> List(Float) {
  int.range(from: 0, to: measure.rounds, with: [], run: fn(acc, r) {
    let factor = case list.contains(slow, r) {
      True -> scale
      False -> 1.0
    }
    let values =
      int.range(from: 1, to: 101, with: [], run: fn(acc, i) {
        [int.to_float(i) *. factor, ..acc]
      })
      |> list.reverse
    list.append(acc, values)
  })
}

pub fn percentiles_by_round_ignores_a_burst_in_two_rounds_test() {
  // Pooled, 200 samples at 10× would be the slowest 40% and set both.
  let assert Ok(#(median, p99)) =
    measure.percentiles_by_round("x", sequence([1, 3], 10.0))
    as "500 samples split into 5 rounds"
  assert median == 50.5
  assert p99 == 99.0
}

pub fn percentiles_by_round_sees_a_slowdown_in_every_round_test() {
  let assert Ok(#(median, p99)) =
    measure.percentiles_by_round("x", sequence([0, 1, 2, 3, 4], 1.5))
    as "500 samples split into 5 rounds"
  assert median == 75.75
  assert p99 == 148.5
}

pub fn percentiles_by_round_sees_a_slowdown_in_three_rounds_test() {
  let assert Ok(#(_, p99)) =
    measure.percentiles_by_round("x", sequence([0, 2, 4], 1.5))
    as "500 samples split into 5 rounds"
  assert p99 == 148.5
}

pub fn percentiles_by_round_refuses_a_count_that_does_not_split_test() {
  let assert Error(reason) =
    measure.percentiles_by_round("x", list.drop(sequence([], 1.0), 1))
    as "499 samples do not split into 5 rounds"
  assert string.contains(reason, "499 samples do not split into 5")
  let assert Error(_) = measure.percentiles_by_round("x", [1.0, 2.0])
    as "fewer samples than rounds is an error"
  let assert Error(_) = measure.percentiles_by_round("x", [])
    as "no samples is an error"
}

pub fn throughput_and_latency_refuses_no_rounds_and_a_zero_time_test() {
  let assert Error(_) = measure.throughput_and_latency("x", "req/s", 100, [])
    as "no rounds is an error"
  let #(_, latencies) = round(1)
  let assert Error(reason) =
    measure.throughput_and_latency("x", "req/s", 100, [#(0, latencies)])
    as "a round of no time is an error"
  assert string.contains(reason, "took no time")
}
