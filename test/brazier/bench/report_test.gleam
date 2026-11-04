import brazier/bench/report.{
  type Report, Entry, HigherIsBetter, LowerIsBetter, Metric, Missing, NotGated,
  Redefined, Regressed, Unexpected, Within,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const machine = [#("cpu", "test-cpu"), #("otp_release", "28")]

fn run(latency: Float, rate: Float) -> Report {
  report.new_report(machine, [
    Metric("latency", "us", LowerIsBetter, latency),
    Metric("rate", "req/s", HigherIsBetter, rate),
  ])
}

fn three_runs() -> List(Report) {
  [run(100.0, 1000.0), run(102.0, 990.0), run(98.0, 1010.0)]
}

// --- baseline ---

pub fn baseline_records_median_range_and_floored_tolerance_test() {
  let assert Ok(baseline) = report.baseline(three_runs(), 0.15, 1.0)
  assert baseline.runs == 3
  assert baseline.machine == machine
  let assert [latency, rate] = baseline.entries
  assert latency.name == "latency"
  assert latency.median == 100.0
  assert latency.min == 98.0
  assert latency.max == 102.0
  // spread 4% doubled is 8%, below the floor.
  assert latency.tolerance == Some(0.15)
  assert rate.median == 1000.0
  assert rate.tolerance == Some(0.15)
}

pub fn baseline_tolerance_is_twice_the_spread_above_the_floor_test() {
  let runs = [run(100.0, 1000.0), run(120.0, 1000.0), run(80.0, 1000.0)]
  let assert Ok(baseline) = report.baseline(runs, 0.15, 1.0)
  let assert [latency, _] = baseline.entries
  assert latency.spread == 0.4
  assert latency.tolerance == Some(0.8)
}

pub fn baseline_leaves_a_too_noisy_metric_ungated_test() {
  let runs = [run(100.0, 1000.0), run(200.0, 1000.0), run(50.0, 1000.0)]
  let assert Ok(baseline) = report.baseline(runs, 0.15, 1.0)
  let assert [latency, rate] = baseline.entries
  // spread 150% doubled is 300%, over the 100% ceiling.
  assert latency.tolerance == None
  assert rate.tolerance == Some(0.15)
}

pub fn baseline_needs_at_least_three_runs_test() {
  let assert Error(reason) =
    report.baseline([run(100.0, 1000.0), run(100.0, 1000.0)], 0.15, 1.0)
  assert string.contains(reason, "at least 3 runs")
  let assert Error(_) = report.baseline([], 0.15, 1.0)
}

pub fn baseline_refuses_runs_from_different_machines_test() {
  let other = report.new_report([#("cpu", "other")], run(1.0, 1.0).metrics)
  let assert Error(reason) =
    report.baseline([run(100.0, 1000.0), run(100.0, 1000.0), other], 0.15, 1.0)
  assert string.contains(reason, "different machines")
}

pub fn baseline_refuses_runs_with_different_metrics_test() {
  let fewer =
    report.new_report(machine, [Metric("latency", "us", LowerIsBetter, 1.0)])
  let assert Error(reason) =
    report.baseline([run(100.0, 1000.0), run(100.0, 1000.0), fewer], 0.15, 1.0)
  assert string.contains(reason, "different metrics")
}

pub fn baseline_refuses_a_duplicated_metric_name_test() {
  let twice =
    report.new_report(machine, [
      Metric("latency", "us", LowerIsBetter, 1.0),
      Metric("latency", "us", LowerIsBetter, 1.0),
    ])
  let assert Error(reason) = report.baseline([twice, twice, twice], 0.15, 1.0)
  assert string.contains(reason, "appears twice")
}

pub fn baseline_refuses_a_zero_median_test() {
  let zero = run(0.0, 1000.0)
  let assert Error(reason) = report.baseline([zero, zero, zero], 0.15, 1.0)
  assert string.contains(reason, "latency: median is not positive")
}

pub fn baseline_refuses_floor_not_below_ceiling_test() {
  let assert Error(_) = report.baseline(three_runs(), 1.0, 1.0)
  let assert Error(_) = report.baseline(three_runs(), 0.0, 1.0)
}

// --- combine ---

pub fn combine_takes_each_metric_median_across_runs_test() {
  let assert Ok(combined) = report.combine(three_runs())
  assert combined.metrics
    == [
      Metric("latency", "us", LowerIsBetter, 100.0),
      Metric("rate", "req/s", HigherIsBetter, 1000.0),
    ]
}

pub fn combine_of_no_runs_is_an_error_test() {
  let assert Error(_) = report.combine([])
}

// --- compare ---

fn reference() -> report.Baseline {
  let assert Ok(baseline) = report.baseline(three_runs(), 0.15, 1.0)
  baseline
}

pub fn compare_passes_a_run_within_tolerance_test() {
  let comparison = report.compare(reference(), run(110.0, 900.0))
  assert report.passed(comparison)
  let assert [Within(entry: latency, ratio: lr, ..), Within(ratio: rr, ..)] =
    comparison.verdicts
  assert latency.name == "latency"
  assert lr == 1.1
  // 1000 / 900: throughput worse by 11%.
  assert rr >. 1.11 && rr <. 1.12
}

pub fn compare_fails_a_slower_latency_test() {
  let comparison = report.compare(reference(), run(116.0, 1000.0))
  assert !report.passed(comparison)
  let assert [Regressed(value: 116.0, ..), Within(..)] = comparison.verdicts
  assert string.contains(report.describe(comparison), "FAIL latency = 116.0 us")
}

pub fn compare_fails_a_lower_throughput_test() {
  // 1000 / 1.15 = 869.6: 860 req/s is past the limit.
  let comparison = report.compare(reference(), run(100.0, 860.0))
  assert !report.passed(comparison)
  let assert [Within(..), Regressed(value: 860.0, ..)] = comparison.verdicts
}

pub fn compare_never_fails_on_an_improvement_test() {
  let comparison = report.compare(reference(), run(10.0, 100_000.0))
  assert report.passed(comparison)
}

pub fn compare_fails_a_throughput_of_zero_test() {
  let comparison = report.compare(reference(), run(100.0, 0.0))
  assert !report.passed(comparison)
  let assert [_, Regressed(..)] = comparison.verdicts
}

pub fn number_prints_large_values_without_an_exponent_test() {
  assert report.number(1900.0) == "1900"
  assert report.number(61_934.4) == "61934"
  assert report.number(-2500.0) == "-2500"
  assert report.number(184.04) == "184.0"
  assert report.number(2.674) == "2.67"
}

pub fn compare_reports_but_never_fails_an_ungated_metric_test() {
  let noisy = [run(100.0, 1000.0), run(200.0, 1000.0), run(50.0, 1000.0)]
  let assert Ok(baseline) = report.baseline(noisy, 0.15, 1.0)
  let comparison = report.compare(baseline, run(1000.0, 1000.0))
  assert report.passed(comparison)
  let assert [NotGated(ratio: 10.0, ..), Within(..)] = comparison.verdicts
  assert string.contains(report.describe(comparison), "not gated")
}

pub fn compare_fails_a_missing_metric_test() {
  let partial =
    report.new_report(machine, [Metric("latency", "us", LowerIsBetter, 100.0)])
  let comparison = report.compare(reference(), partial)
  assert !report.passed(comparison)
  assert list.contains(comparison.verdicts, Missing("rate"))
}

pub fn compare_fails_a_metric_the_baseline_lacks_test() {
  let extra =
    report.new_report(
      machine,
      list.append(run(100.0, 1000.0).metrics, [
        Metric("new", "us", LowerIsBetter, 1.0),
      ]),
    )
  let comparison = report.compare(reference(), extra)
  assert !report.passed(comparison)
  assert list.contains(comparison.verdicts, Unexpected("new"))
}

pub fn compare_fails_a_metric_whose_unit_changed_test() {
  let renamed =
    report.new_report(machine, [
      Metric("latency", "ms", LowerIsBetter, 0.1),
      Metric("rate", "req/s", HigherIsBetter, 1000.0),
    ])
  let comparison = report.compare(reference(), renamed)
  assert !report.passed(comparison)
  assert list.contains(comparison.verdicts, Redefined("latency"))
}

pub fn compare_fails_on_another_machine_even_when_faster_test() {
  let elsewhere =
    report.new_report(
      [#("cpu", "faster-cpu"), #("otp_release", "28")],
      run(50.0, 2000.0).metrics,
    )
  let comparison = report.compare(reference(), elsewhere)
  assert !report.passed(comparison)
  assert comparison.machine_mismatches == [#("cpu", "test-cpu", "faster-cpu")]
}

pub fn compare_names_a_machine_key_absent_on_one_side_test() {
  let extra_key =
    report.new_report(
      [#("cpu", "test-cpu"), #("kernel", "x"), #("otp_release", "28")],
      run(100.0, 1000.0).metrics,
    )
  let comparison = report.compare(reference(), extra_key)
  assert comparison.machine_mismatches == [#("kernel", "<absent>", "x")]
}

// --- JSON ---

pub fn report_json_round_trips_test() {
  let original = run(100.5, 1234.0)
  assert report.decode_report(report.encode_report(original)) == Ok(original)
}

pub fn baseline_json_round_trips_test() {
  let noisy = [run(100.0, 1000.0), run(200.0, 1000.0), run(50.0, 1000.0)]
  let assert Ok(original) = report.baseline(noisy, 0.15, 1.0)
  assert report.decode_baseline(report.encode_baseline(original))
    == Ok(original)
}

pub fn baseline_json_accepts_integer_numbers_test() {
  // A hand-edited baseline may write 100 for 100.0.
  let text =
    "{\"machine\":{},\"runs\":3,\"floor\":0.15,\"ceiling\":1,\"entries\":"
    <> "[{\"name\":\"x\",\"unit\":\"us\",\"better\":\"lower\",\"median\":100,"
    <> "\"min\":90,\"max\":110,\"spread\":0.2,\"tolerance\":null}]}"
  let assert Ok(baseline) = report.decode_baseline(text)
  assert baseline.ceiling == 1.0
  assert baseline.entries
    == [
      Entry(
        name: "x",
        unit: "us",
        better: LowerIsBetter,
        median: 100.0,
        min: 90.0,
        max: 110.0,
        spread: 0.2,
        tolerance: None,
      ),
    ]
}

pub fn baseline_json_rejects_an_unknown_direction_test() {
  let text =
    "{\"machine\":{},\"runs\":3,\"floor\":0.15,\"ceiling\":1.0,\"entries\":"
    <> "[{\"name\":\"x\",\"unit\":\"us\",\"better\":\"sideways\",\"median\":1.0,"
    <> "\"min\":1.0,\"max\":1.0,\"spread\":0.0,\"tolerance\":0.15}]}"
  let assert Error(reason) = report.decode_baseline(text)
  assert string.contains(reason, "invalid baseline")
}

pub fn baseline_json_rejects_a_duplicated_metric_test() {
  let entry =
    "{\"name\":\"x\",\"unit\":\"us\",\"better\":\"lower\",\"median\":1.0,"
    <> "\"min\":1.0,\"max\":1.0,\"spread\":0.0,\"tolerance\":0.15}"
  let text =
    "{\"machine\":{},\"runs\":3,\"floor\":0.15,\"ceiling\":1.0,\"entries\":["
    <> entry
    <> ","
    <> entry
    <> "]}"
  let assert Error(reason) = report.decode_baseline(text)
  assert string.contains(reason, "appears twice")
}

pub fn baseline_json_rejects_a_zero_median_test() {
  let text =
    "{\"machine\":{},\"runs\":3,\"floor\":0.15,\"ceiling\":1.0,\"entries\":"
    <> "[{\"name\":\"x\",\"unit\":\"us\",\"better\":\"lower\",\"median\":0,"
    <> "\"min\":0,\"max\":0,\"spread\":0,\"tolerance\":0.15}]}"
  let assert Error(reason) = report.decode_baseline(text)
  assert string.contains(reason, "median is not positive")
}

pub fn baseline_json_rejects_garbage_test() {
  let assert Error(_) = report.decode_baseline("not json")
  let assert Error(_) = report.decode_baseline("{\"machine\":{}}")
  let assert Error(_) = report.decode_report("[]")
}
