import brazier/bench/report.{
  type Report, Entry, HigherIsBetter, LowerIsBetter, Metric, Missing, Redefined,
  Regressed, TooNoisy, Unexpected, Within,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const machine = [#("cpu", "test-cpu"), #("otp_release", "28")]

const conditions = [#("load_average_before", "1.00 2.00 3.00")]

/// The floor and max_spread the fixtures are built with. 0.15 is below
/// the suite's 0.25, so a test can tell the floor from the spread.
const floor = 0.15

const max_spread = 0.5

fn build(runs: List(Report)) -> Result(report.Baseline, String) {
  report.baseline(runs, conditions, floor, max_spread)
}

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
  let assert Ok(baseline) = build(three_runs())
    as "three steady runs make a baseline"
  assert baseline.runs == 3
  assert baseline.machine == machine
  assert baseline.conditions == conditions
  let assert [latency, rate] = baseline.entries
    as "the baseline has the latency and rate entries"
  assert latency.name == "latency"
  assert latency.median == 100.0
  assert latency.min == 98.0
  assert latency.max == 102.0
  // spread 4% is below the floor.
  assert latency.tolerance == Some(0.15)
  assert rate.median == 1000.0
  assert rate.tolerance == Some(0.15)
}

pub fn baseline_tolerance_is_the_spread_above_the_floor_test() {
  let runs = [run(100.0, 1000.0), run(120.0, 1000.0), run(80.0, 1000.0)]
  let assert Ok(baseline) = build(runs) as "runs of spread 0.4 make a baseline"
  let assert [latency, _] = baseline.entries
    as "the baseline has the latency entry first"
  assert latency.spread == 0.4
  assert latency.tolerance == Some(0.4)
}

pub fn baseline_leaves_a_too_noisy_metric_ungated_test() {
  let runs = [run(100.0, 1000.0), run(200.0, 1000.0), run(50.0, 1000.0)]
  let assert Ok(baseline) = build(runs) as "a noisy run still makes a baseline"
  let assert [latency, rate] = baseline.entries
    as "the baseline has the latency and rate entries"
  // spread 150%, over the 50% bound.
  assert latency.tolerance == None
  assert rate.tolerance == Some(0.15)
  assert report.ungated(baseline) == [latency]
}

pub fn baseline_refuses_to_gate_a_spread_of_exactly_max_spread_test() {
  // (125 - 75) / 100 = 0.5 exactly: the bound is strict.
  let runs = [run(100.0, 1000.0), run(125.0, 1000.0), run(75.0, 1000.0)]
  let assert Ok(baseline) = build(runs)
    as "runs of spread exactly 0.5 make a baseline"
  let assert [latency, _] = baseline.entries
    as "the baseline has the latency entry first"
  assert latency.spread == 0.5
  assert latency.tolerance == None
  assert list.map(report.ungated(baseline), fn(e) { e.name }) == ["latency"]
}

pub fn baseline_gates_a_spread_just_below_max_spread_test() {
  let runs = [run(100.0, 1000.0), run(124.0, 1000.0), run(75.0, 1000.0)]
  let assert Ok(baseline) = build(runs) as "runs of spread 0.49 make a baseline"
  let assert [latency, _] = baseline.entries
    as "the baseline has the latency entry first"
  assert latency.spread == 0.49
  assert latency.tolerance == Some(0.49)
  assert report.ungated(baseline) == []
}

pub fn baseline_of_steady_runs_has_nothing_ungated_test() {
  let assert Ok(baseline) = build(three_runs())
    as "three steady runs make a baseline"
  assert report.ungated(baseline) == []
}

pub fn baseline_needs_at_least_three_runs_test() {
  let assert Error(reason) = build([run(100.0, 1000.0), run(100.0, 1000.0)])
    as "two runs are too few for a baseline"
  assert string.contains(reason, "at least 3 runs")
  let assert Error(_) = build([]) as "no runs are too few for a baseline"
}

pub fn baseline_refuses_runs_from_different_machines_test() {
  let other = report.new_report([#("cpu", "other")], run(1.0, 1.0).metrics)
  let assert Error(reason) =
    build([run(100.0, 1000.0), run(100.0, 1000.0), other])
    as "runs from different machines make no baseline"
  assert string.contains(reason, "different machines")
}

pub fn baseline_refuses_runs_with_different_metrics_test() {
  let fewer =
    report.new_report(machine, [Metric("latency", "us", LowerIsBetter, 1.0)])
  let assert Error(reason) =
    build([run(100.0, 1000.0), run(100.0, 1000.0), fewer])
    as "runs with different metrics make no baseline"
  assert string.contains(reason, "different metrics")
}

pub fn baseline_refuses_a_duplicated_metric_name_test() {
  let twice =
    report.new_report(machine, [
      Metric("latency", "us", LowerIsBetter, 1.0),
      Metric("latency", "us", LowerIsBetter, 1.0),
    ])
  let assert Error(reason) = build([twice, twice, twice])
    as "a duplicated metric name makes no baseline"
  assert string.contains(reason, "appears twice")
}

pub fn baseline_refuses_a_zero_median_test() {
  let zero = run(0.0, 1000.0)
  let assert Error(reason) = build([zero, zero, zero])
    as "a zero median makes no baseline"
  assert string.contains(reason, "latency: median is not positive")
}

pub fn baseline_refuses_floor_not_below_max_spread_test() {
  let assert Error(reason) = report.baseline(three_runs(), [], 0.5, 0.5)
    as "a floor equal to max_spread is refused"
  assert string.contains(reason, "below max_spread")
  let assert Error(_) = report.baseline(three_runs(), [], 0.0, 0.5)
    as "a zero floor is refused"
  let assert Error(_) = report.baseline(three_runs(), [], -0.1, 0.5)
    as "a negative floor is refused"
}

// --- combine ---

pub fn combine_takes_each_metric_median_across_runs_test() {
  let assert Ok(combined) = report.combine(three_runs()) as "three runs combine"
  assert combined.metrics
    == [
      Metric("latency", "us", LowerIsBetter, 100.0),
      Metric("rate", "req/s", HigherIsBetter, 1000.0),
    ]
}

pub fn combine_of_no_runs_is_an_error_test() {
  let assert Error(_) = report.combine([]) as "no runs do not combine"
}

// --- compare ---

fn reference() -> report.Baseline {
  let assert Ok(baseline) = build(three_runs())
    as "three steady runs make the reference baseline"
  baseline
}

pub fn compare_passes_a_run_within_tolerance_test() {
  let comparison = report.compare(reference(), run(110.0, 900.0))
  assert report.passed(comparison)
  let assert [Within(entry: latency, ratio: lr, ..), Within(ratio: rr, ..)] =
    comparison.verdicts
    as "both metrics are within tolerance"
  assert latency.name == "latency"
  assert lr == 1.1
  // 1000 / 900: throughput worse by 11%.
  assert rr >. 1.11 && rr <. 1.12
}

pub fn compare_fails_a_slower_latency_test() {
  let comparison = report.compare(reference(), run(116.0, 1000.0))
  assert !report.passed(comparison)
  let assert [Regressed(value: 116.0, ..), Within(..)] = comparison.verdicts
    as "the latency regressed and the rate is within tolerance"
  assert string.contains(report.describe(comparison), "FAIL latency = 116.0 us")
}

pub fn compare_passes_a_value_exactly_at_the_limit_test() {
  // Floor 0.25, exact in binary: 125 us is x1.25, 800 req/s is
  // 1000 / 800 = x1.25. The limit itself passes.
  let assert Ok(baseline) =
    report.baseline(three_runs(), conditions, 0.25, max_spread)
    as "three steady runs make a baseline at floor 0.25"
  let comparison = report.compare(baseline, run(125.0, 800.0))
  assert report.passed(comparison)
  let assert [Within(ratio: 1.25, ..), Within(ratio: 1.25, ..)] =
    comparison.verdicts
    as "both metrics sit exactly at the x1.25 limit"
}

pub fn compare_fails_a_value_just_past_the_limit_test() {
  let assert Ok(baseline) =
    report.baseline(three_runs(), conditions, 0.25, max_spread)
    as "three steady runs make a baseline at floor 0.25"
  let comparison = report.compare(baseline, run(125.01, 799.9))
  assert !report.passed(comparison)
  let assert [Regressed(..), Regressed(..)] = comparison.verdicts
    as "both metrics are just past the limit"
}

pub fn compare_fails_a_one_and_a_half_times_slowdown_of_the_noisiest_gated_metric_test() {
  // Spread 49%, the widest a gated metric may have: tolerance 0.49.
  let runs = [run(100.0, 1000.0), run(124.0, 1000.0), run(75.0, 1000.0)]
  let assert Ok(baseline) = build(runs) as "runs of spread 0.49 make a baseline"
  let comparison = report.compare(baseline, run(150.0, 1000.0 /. 1.5))
  assert !report.passed(comparison)
  let assert [Regressed(ratio: 1.5, ..), Regressed(..)] = comparison.verdicts
    as "a x1.5 slowdown regresses both metrics"
}

pub fn compare_fails_a_lower_throughput_test() {
  // 1000 / 1.15 = 869.6: 860 req/s is past the limit.
  let comparison = report.compare(reference(), run(100.0, 860.0))
  assert !report.passed(comparison)
  let assert [Within(..), Regressed(value: 860.0, ..)] = comparison.verdicts
    as "the rate regressed and the latency is within tolerance"
}

pub fn compare_never_fails_on_an_improvement_test() {
  let comparison = report.compare(reference(), run(10.0, 100_000.0))
  assert report.passed(comparison)
}

pub fn compare_fails_a_throughput_of_zero_test() {
  let comparison = report.compare(reference(), run(100.0, 0.0))
  assert !report.passed(comparison)
  let assert [_, Regressed(..)] = comparison.verdicts
    as "a throughput of zero regressed"
}

pub fn number_prints_large_values_without_an_exponent_test() {
  assert report.number(1900.0) == "1900"
  assert report.number(61_934.4) == "61934"
  assert report.number(-2500.0) == "-2500"
  assert report.number(184.04) == "184.0"
  assert report.number(2.674) == "2.67"
}

pub fn compare_fails_a_metric_too_noisy_to_gate_test() {
  let noisy = [run(100.0, 1000.0), run(200.0, 1000.0), run(50.0, 1000.0)]
  let assert Ok(baseline) = build(noisy) as "a noisy run still makes a baseline"
  // Even at the baseline median: an ungated metric would pass anything.
  let comparison = report.compare(baseline, run(100.0, 1000.0))
  assert !report.passed(comparison)
  let assert [TooNoisy(ratio: 1.0, ..), Within(..)] = comparison.verdicts
    as "the noisy latency is too noisy and the rate is within tolerance"
  let text = report.describe(comparison)
  assert string.contains(text, "FAIL latency = 100.0 us")
  assert string.contains(text, "is not gated: its baseline spread 150.0% is")
  assert string.contains(text, "not below 50.0%")
  assert string.contains(text, "raise its samples")
}

pub fn compare_fails_a_missing_metric_test() {
  let partial =
    report.new_report(machine, [Metric("latency", "us", LowerIsBetter, 100.0)])
  let comparison = report.compare(reference(), partial)
  assert !report.passed(comparison)
  assert list.contains(comparison.verdicts, Missing("rate"))
  assert string.contains(
    report.describe(comparison),
    "FAIL rate: in the baseline but not measured by this run, so it is not "
      <> "gated",
  )
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
  assert string.contains(
    report.describe(comparison),
    "FAIL new: measured but not in the baseline, so it is not gated",
  )
}

pub fn compare_fails_every_metric_against_an_empty_baseline_test() {
  let assert Ok(baseline) = build(three_runs())
    as "three steady runs make a baseline"
  let empty = report.Baseline(..baseline, entries: [])
  let comparison = report.compare(empty, run(100.0, 1000.0))
  assert !report.passed(comparison)
  assert comparison.verdicts == [Unexpected("latency"), Unexpected("rate")]
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
  let assert Ok(original) = build(noisy) as "a noisy run still makes a baseline"
  let assert Ok(decoded) =
    report.decode_baseline(report.encode_baseline(original))
    as "an encoded baseline decodes"
  assert decoded == original
  assert decoded.conditions == conditions
}

pub fn baseline_json_rejects_a_tolerance_off_the_rule_test() {
  // spread 0.2 above floor 0.15 must have tolerance 0.2, not a looser 0.9.
  let text =
    "{\"machine\":{},\"conditions\":{},\"runs\":3,\"floor\":0.15,"
    <> "\"max_spread\":0.5,\"entries\":[{\"name\":\"x\",\"unit\":\"us\","
    <> "\"better\":\"lower\",\"median\":100,\"min\":90,\"max\":110,"
    <> "\"spread\":0.2,\"tolerance\":0.9}]}"
  let assert Error(reason) = report.decode_baseline(text)
    as "a tolerance off the rule is refused"
  assert string.contains(reason, "does not follow")
}

pub fn baseline_json_rejects_a_missing_tolerance_for_a_gateable_spread_test() {
  let text =
    "{\"machine\":{},\"conditions\":{},\"runs\":3,\"floor\":0.15,"
    <> "\"max_spread\":0.5,\"entries\":[{\"name\":\"x\",\"unit\":\"us\","
    <> "\"better\":\"lower\",\"median\":100,\"min\":90,\"max\":110,"
    <> "\"spread\":0.2,\"tolerance\":null}]}"
  let assert Error(reason) = report.decode_baseline(text)
    as "a missing tolerance for a gateable spread is refused"
  assert string.contains(reason, "does not follow")
}

pub fn baseline_json_rejects_the_old_ceiling_format_test() {
  // Before max_spread: no conditions, a ceiling. Refused, not reinterpreted.
  let text =
    "{\"machine\":{},\"runs\":3,\"floor\":0.25,\"ceiling\":1.0,"
    <> "\"entries\":[]}"
  let assert Error(reason) = report.decode_baseline(text)
    as "the old ceiling format is refused"
  assert string.contains(reason, "invalid baseline")
}

pub fn baseline_json_accepts_integer_numbers_test() {
  // A hand-edited baseline may write 100 for 100.0.
  let text =
    "{\"machine\":{},\"runs\":3,\"floor\":0.15,\"max_spread\":1,"
    <> "\"conditions\":{},\"entries\":[{\"name\":\"x\",\"unit\":\"us\","
    <> "\"better\":\"lower\",\"median\":100,\"min\":90,\"max\":110,"
    <> "\"spread\":0.2,\"tolerance\":0.2}]}"
  let assert Ok(baseline) = report.decode_baseline(text)
    as "integer numbers decode"
  assert baseline.max_spread == 1.0
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
        tolerance: Some(0.2),
      ),
    ]
}

pub fn baseline_json_rejects_an_unknown_direction_test() {
  let text =
    "{\"machine\":{},\"runs\":3,\"floor\":0.15,\"max_spread\":0.5,\"conditions\":{},\"entries\":"
    <> "[{\"name\":\"x\",\"unit\":\"us\",\"better\":\"sideways\",\"median\":1.0,"
    <> "\"min\":1.0,\"max\":1.0,\"spread\":0.0,\"tolerance\":0.15}]}"
  let assert Error(reason) = report.decode_baseline(text)
    as "an unknown direction is refused"
  assert string.contains(reason, "invalid baseline")
}

pub fn baseline_json_rejects_a_duplicated_metric_test() {
  let entry =
    "{\"name\":\"x\",\"unit\":\"us\",\"better\":\"lower\",\"median\":1.0,"
    <> "\"min\":1.0,\"max\":1.0,\"spread\":0.0,\"tolerance\":0.15}"
  let text =
    "{\"machine\":{},\"runs\":3,\"floor\":0.15,\"max_spread\":0.5,\"conditions\":{},\"entries\":["
    <> entry
    <> ","
    <> entry
    <> "]}"
  let assert Error(reason) = report.decode_baseline(text)
    as "a duplicated metric is refused"
  assert string.contains(reason, "appears twice")
}

pub fn baseline_json_rejects_a_zero_median_test() {
  let text =
    "{\"machine\":{},\"runs\":3,\"floor\":0.15,\"max_spread\":0.5,\"conditions\":{},\"entries\":"
    <> "[{\"name\":\"x\",\"unit\":\"us\",\"better\":\"lower\",\"median\":0,"
    <> "\"min\":0,\"max\":0,\"spread\":0,\"tolerance\":0.15}]}"
  let assert Error(reason) = report.decode_baseline(text)
    as "a zero median is refused"
  assert string.contains(reason, "median is not positive")
}

pub fn baseline_json_rejects_garbage_test() {
  let assert Error(_) = report.decode_baseline("not json")
    as "text that is not JSON is refused"
  let assert Error(_) = report.decode_baseline("{\"machine\":{}}")
    as "a baseline without its fields is refused"
  let assert Error(_) = report.decode_report("[]")
    as "a report that is not an object is refused"
}
