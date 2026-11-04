//// Benchmark reports, baselines and regression checks.
////
//// A `Report` is one run of the suite: the machine it ran on and one value
//// per metric. A `Baseline` is built from several runs on one machine and
//// records, per metric, the median of the runs, their range, and the
//// tolerance a later run is checked against:
////
////     spread    = (max - min) / median
////     tolerance = max(floor, spread)    when spread < max_spread
////
//// For a lower-is-better metric min <= median, so median * (1 + spread)
//// is at least the slowest baseline run: a check fails only on a value
//// worse than every run the baseline saw. `floor` covers the drift between
//// sessions that back-to-back runs do not see.
////
//// A metric whose spread is `max_spread` or more has no tolerance. Such a
//// metric cannot be gated (with max_spread 0.5, a tolerance that wide
//// would let a 1.5x slowdown through), and the gate never lets a metric
//// through ungated: it fails the check with `TooNoisy`, and the baseline
//// entry point refuses to write such a baseline (`ungated`). The fix is
//// more samples for that metric, not a looser gate.
////
//// A check passes when it ran on the baseline's machine, produced exactly
//// the baseline's metrics, every metric is gated, and none is worse than
//// its baseline median by more than its tolerance. Worse means slower:
//// the ratio is value / median for lower-is-better metrics and
//// median / value for higher-is-better ones, so a tolerance of 0.25 fails
//// a latency more than 25% above its median and a throughput below
//// median / 1.25. A value exactly at the limit passes.

import brazier/bench/stats
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Which way a metric improves.
pub type Direction {
  LowerIsBetter
  HigherIsBetter
}

/// One measured value.
pub type Metric {
  Metric(name: String, unit: String, better: Direction, value: Float)
}

/// One run of the suite. `machine` is sorted by key.
pub type Report {
  Report(machine: List(#(String, String)), metrics: List(Metric))
}

/// One metric's baseline. `tolerance` is None when the metric is too noisy
/// to gate (its spread is at least the baseline's `max_spread`).
pub type Entry {
  Entry(
    name: String,
    unit: String,
    better: Direction,
    median: Float,
    min: Float,
    max: Float,
    spread: Float,
    tolerance: Option(Float),
  )
}

/// Several runs on one machine, reduced to one entry per metric.
/// `conditions` records what the machine was doing while the baseline was
/// measured (the load average, say); unlike `machine` it is never
/// compared, only reported, so a reader can judge a baseline taken on a
/// busy machine.
pub type Baseline {
  Baseline(
    machine: List(#(String, String)),
    conditions: List(#(String, String)),
    runs: Int,
    floor: Float,
    max_spread: Float,
    entries: List(Entry),
  )
}

/// How one metric of a check compares with its baseline. `ratio` is how
/// many times worse than the baseline median the value is (below 1.0 is
/// better).
pub type Verdict {
  Within(entry: Entry, value: Float, ratio: Float)
  Regressed(entry: Entry, value: Float, ratio: Float)
  /// In both, but the baseline's spread is too wide to gate it. Fails:
  /// an ungated metric would let any slowdown through.
  TooNoisy(entry: Entry, value: Float, ratio: Float)
  /// In the baseline but not in the run.
  Missing(name: String)
  /// In the run but not in the baseline.
  Unexpected(name: String)
  /// In both, with a different unit or direction.
  Redefined(name: String)
}

/// A whole check: machine differences (key, baseline, current), one
/// verdict per metric, and the baseline's `max_spread` (for the message
/// of a `TooNoisy` verdict).
pub type Comparison {
  Comparison(
    machine_mismatches: List(#(String, String, String)),
    verdicts: List(Verdict),
    max_spread: Float,
  )
}

/// The fewest runs a baseline may be built from: the spread of two runs
/// is a single difference, too little to set a tolerance on.
pub const min_baseline_runs = 3

/// A report with its machine sorted by key, as every Report is held.
pub fn new_report(
  machine: List(#(String, String)),
  metrics: List(Metric),
) -> Report {
  Report(machine: sort_machine(machine), metrics: metrics)
}

/// Build a baseline from runs on one machine (see the module docs).
/// Error when there are fewer than `min_baseline_runs` runs, the runs
/// disagree on the machine or the metrics, a median is not positive, or
/// `floor` is not positive and below `max_spread`. A metric too noisy to
/// gate is kept, with no tolerance (see `ungated`).
pub fn baseline(
  runs: List(Report),
  conditions: List(#(String, String)),
  floor: Float,
  max_spread: Float,
) -> Result(Baseline, String) {
  use <- guard(
    floor >. 0.0 && max_spread >. floor,
    "floor must be positive and below max_spread",
  )
  use <- guard(
    list.length(runs) >= min_baseline_runs,
    "a baseline needs at least "
      <> int.to_string(min_baseline_runs)
      <> " runs, got "
      <> int.to_string(list.length(runs)),
  )
  use #(machine, series) <- result.try(group(runs))
  use entries <- result.try(
    list.try_map(series, fn(item) {
      let #(template, values) = item
      use summary <- result.try(
        stats.summarize(values)
        |> result.replace_error(template.name <> ": no values"),
      )
      use <- guard(
        summary.median >. 0.0,
        template.name <> ": median is not positive",
      )
      let spread = { summary.max -. summary.min } /. summary.median
      Ok(Entry(
        name: template.name,
        unit: template.unit,
        better: template.better,
        median: summary.median,
        min: summary.min,
        max: summary.max,
        spread: spread,
        tolerance: tolerance(spread, floor, max_spread),
      ))
    }),
  )
  Ok(Baseline(
    machine: machine,
    conditions: conditions,
    runs: list.length(runs),
    floor: floor,
    max_spread: max_spread,
    entries: entries,
  ))
}

/// max(floor, spread), or None when spread is max_spread or more: the
/// bound is strict, so the loosest tolerance is below max_spread.
fn tolerance(spread: Float, floor: Float, max_spread: Float) -> Option(Float) {
  case spread <. max_spread {
    True -> Some(float.max(floor, spread))
    False -> None
  }
}

/// The entries too noisy to gate. A baseline with any cannot gate the
/// suite; `make bench-baseline` refuses to write it.
pub fn ungated(baseline: Baseline) -> List(Entry) {
  list.filter(baseline.entries, fn(e) { e.tolerance == None })
}

/// Reduce several runs on one machine to one report holding each metric's
/// median. Error when there are no runs or they disagree on the machine or
/// the metrics.
pub fn combine(runs: List(Report)) -> Result(Report, String) {
  use #(machine, series) <- result.try(group(runs))
  use metrics <- result.try(
    list.try_map(series, fn(item) {
      let #(template, values) = item
      stats.median(values)
      |> result.map(fn(median) { Metric(..template, value: median) })
      |> result.replace_error(template.name <> ": no values")
    }),
  )
  Ok(Report(machine: machine, metrics: metrics))
}

/// Every run's values for each metric, in the first run's metric order.
fn group(
  runs: List(Report),
) -> Result(#(List(#(String, String)), List(#(Metric, List(Float)))), String) {
  case runs {
    [] -> Error("no runs")
    [first, ..rest] -> {
      use Nil <- result.try(
        list.try_each(rest, fn(run) {
          use <- guard(
            run.machine == first.machine,
            "the runs were measured on different machines",
          )
          use <- guard(
            list.map(run.metrics, definition)
              == list.map(first.metrics, definition),
            "the runs measured different metrics",
          )
          Ok(Nil)
        }),
      )
      use <- guard(
        unique(list.map(first.metrics, fn(m) { m.name })),
        "a metric name appears twice",
      )
      let series =
        list.index_map(first.metrics, fn(template, index) {
          #(
            template,
            list.filter_map(runs, fn(run) {
              list.drop(run.metrics, index)
              |> list.first
              |> result.map(fn(m) { m.value })
            }),
          )
        })
      Ok(#(first.machine, series))
    }
  }
}

fn definition(metric: Metric) -> #(String, String, Direction) {
  #(metric.name, metric.unit, metric.better)
}

/// Check a run against a baseline (see the module docs).
pub fn compare(baseline: Baseline, run: Report) -> Comparison {
  let current = dict.from_list(run.machine)
  let recorded = dict.from_list(baseline.machine)
  let keys =
    list.append(dict.keys(recorded), dict.keys(current))
    |> list.unique
    |> list.sort(string.compare)
  let machine_mismatches =
    list.filter_map(keys, fn(key) {
      let was = dict.get(recorded, key) |> result.unwrap("<absent>")
      let now = dict.get(current, key) |> result.unwrap("<absent>")
      case was == now {
        True -> Error(Nil)
        False -> Ok(#(key, was, now))
      }
    })
  let measured = dict.from_list(list.map(run.metrics, fn(m) { #(m.name, m) }))
  let known = list.map(baseline.entries, fn(e) { e.name })
  let checked =
    list.map(baseline.entries, fn(entry) {
      case dict.get(measured, entry.name) {
        Error(Nil) -> Missing(entry.name)
        Ok(metric)
          if metric.unit != entry.unit || metric.better != entry.better
        -> Redefined(entry.name)
        Ok(metric) -> verdict(entry, metric.value)
      }
    })
  let unexpected =
    list.filter_map(run.metrics, fn(metric) {
      case list.contains(known, metric.name) {
        True -> Error(Nil)
        False -> Ok(Unexpected(metric.name))
      }
    })
  Comparison(
    machine_mismatches: machine_mismatches,
    verdicts: list.append(checked, unexpected),
    max_spread: baseline.max_spread,
  )
}

fn verdict(entry: Entry, value: Float) -> Verdict {
  let ratio = worse_ratio(entry.better, entry.median, value)
  case entry.tolerance {
    None -> TooNoisy(entry, value, ratio)
    Some(tolerance) ->
      case ratio >. 1.0 +. tolerance {
        True -> Regressed(entry, value, ratio)
        False -> Within(entry, value, ratio)
      }
  }
}

/// How many times worse than `median` the value is. A non-positive value
/// of a higher-is-better metric (nothing got done) is infinitely worse,
/// stood in for by a ratio no tolerance admits.
fn worse_ratio(better: Direction, median: Float, value: Float) -> Float {
  case better {
    LowerIsBetter -> value /. median
    HigherIsBetter if value >. 0.0 -> median /. value
    HigherIsBetter -> 1.0e9
  }
}

/// True when the run is on the baseline's machine and every verdict is
/// `Within`: a metric that is not gated (too noisy, missing, new or
/// redefined) fails the check like a regression does.
pub fn passed(comparison: Comparison) -> Bool {
  comparison.machine_mismatches == []
  && list.all(comparison.verdicts, fn(v) {
    case v {
      Within(..) -> True
      Regressed(..)
      | TooNoisy(..)
      | Missing(_)
      | Unexpected(_)
      | Redefined(_) -> False
    }
  })
}

/// One line per machine mismatch and per verdict.
pub fn describe(comparison: Comparison) -> String {
  let machine =
    list.map(comparison.machine_mismatches, fn(m) {
      let #(key, was, now) = m
      "FAIL machine " <> key <> ": baseline " <> was <> ", this run " <> now
    })
  let metrics =
    list.map(comparison.verdicts, fn(v) {
      case v {
        Within(entry, value, ratio) ->
          "ok   " <> measured(entry, value, ratio) <> limit(entry)
        Regressed(entry, value, ratio) ->
          "FAIL " <> measured(entry, value, ratio) <> limit(entry)
        TooNoisy(entry, value, ratio) ->
          "FAIL "
          <> measured(entry, value, ratio)
          <> ") is not gated: its baseline spread "
          <> percent(entry.spread)
          <> " is not below "
          <> percent(comparison.max_spread)
          <> "; raise its samples and re-baseline (make bench-baseline)"
        Missing(name) ->
          "FAIL "
          <> name
          <> ": in the baseline but not measured by this run, so it is "
          <> "not gated; re-baseline (make bench-baseline) if it was "
          <> "removed on purpose"
        Unexpected(name) ->
          "FAIL "
          <> name
          <> ": measured but not in the baseline, so it is not gated; "
          <> "re-baseline (make bench-baseline)"
        Redefined(name) ->
          "FAIL "
          <> name
          <> ": unit or direction differs from the baseline; re-baseline "
          <> "(make bench-baseline)"
      }
    })
  string.join(list.append(machine, metrics), "\n")
}

fn measured(entry: Entry, value: Float, ratio: Float) -> String {
  entry.name
  <> " = "
  <> number(value)
  <> " "
  <> entry.unit
  <> " (baseline "
  <> number(entry.median)
  <> ", x"
  <> float.to_string(float.to_precision(ratio, 2))
  <> " worse"
}

fn limit(entry: Entry) -> String {
  case entry.tolerance {
    Some(tolerance) ->
      ", limit x"
      <> float.to_string(float.to_precision(1.0 +. tolerance, 2))
      <> ")"
    None -> ")"
  }
}

/// A value at a precision that suits its size.
/// Whole numbers from 1000 up print as integers: `float.to_string` would
/// print 1900.0 as "1.9e3".
pub fn number(value: Float) -> String {
  case float.absolute_value(value) {
    v if v >=. 1000.0 -> int.to_string(float.round(value))
    v if v >=. 10.0 -> float.to_string(float.to_precision(value, 1))
    _ -> float.to_string(float.to_precision(value, 2))
  }
}

fn percent(fraction: Float) -> String {
  float.to_string(float.to_precision(fraction *. 100.0, 0)) <> "%"
}

// --- JSON ---

pub fn encode_report(report: Report) -> String {
  json.object([
    #("machine", encode_machine(report.machine)),
    #(
      "metrics",
      json.array(report.metrics, fn(m) {
        json.object([
          #("name", json.string(m.name)),
          #("unit", json.string(m.unit)),
          #("better", encode_direction(m.better)),
          #("value", json.float(m.value)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

pub fn decode_report(text: String) -> Result(Report, String) {
  let metric = {
    use name <- decode.field("name", decode.string)
    use unit <- decode.field("unit", decode.string)
    use better <- decode.field("better", direction_decoder())
    use value <- decode.field("value", number_decoder())
    decode.success(Metric(name:, unit:, better:, value:))
  }
  let decoder = {
    use machine <- decode.field("machine", machine_decoder())
    use metrics <- decode.field("metrics", decode.list(metric))
    decode.success(Report(machine:, metrics:))
  }
  json.parse(text, decoder)
  |> result.map_error(fn(e) { "invalid report: " <> string.inspect(e) })
}

pub fn encode_baseline(baseline: Baseline) -> String {
  json.object([
    #("machine", encode_machine(baseline.machine)),
    #("conditions", encode_machine(baseline.conditions)),
    #("runs", json.int(baseline.runs)),
    #("floor", json.float(baseline.floor)),
    #("max_spread", json.float(baseline.max_spread)),
    #(
      "entries",
      json.array(baseline.entries, fn(e) {
        json.object([
          #("name", json.string(e.name)),
          #("unit", json.string(e.unit)),
          #("better", encode_direction(e.better)),
          #("median", json.float(e.median)),
          #("min", json.float(e.min)),
          #("max", json.float(e.max)),
          #("spread", json.float(e.spread)),
          #("tolerance", json.nullable(e.tolerance, json.float)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

pub fn decode_baseline(text: String) -> Result(Baseline, String) {
  let entry = {
    use name <- decode.field("name", decode.string)
    use unit <- decode.field("unit", decode.string)
    use better <- decode.field("better", direction_decoder())
    use median <- decode.field("median", number_decoder())
    use min <- decode.field("min", number_decoder())
    use max <- decode.field("max", number_decoder())
    use spread <- decode.field("spread", number_decoder())
    use tolerance <- decode.field(
      "tolerance",
      decode.optional(number_decoder()),
    )
    decode.success(Entry(
      name:,
      unit:,
      better:,
      median:,
      min:,
      max:,
      spread:,
      tolerance:,
    ))
  }
  let decoder = {
    use machine <- decode.field("machine", machine_decoder())
    use conditions <- decode.field("conditions", machine_decoder())
    use runs <- decode.field("runs", decode.int)
    use floor <- decode.field("floor", number_decoder())
    use max_spread <- decode.field("max_spread", number_decoder())
    use entries <- decode.field("entries", decode.list(entry))
    decode.success(Baseline(
      machine:,
      conditions:,
      runs:,
      floor:,
      max_spread:,
      entries:,
    ))
  }
  use baseline <- result.try(
    json.parse(text, decoder)
    |> result.map_error(fn(e) { "invalid baseline: " <> string.inspect(e) }),
  )
  use <- guard(
    unique(list.map(baseline.entries, fn(e) { e.name })),
    "invalid baseline: a metric name appears twice",
  )
  use <- guard(
    list.all(baseline.entries, fn(e) { e.median >. 0.0 }),
    "invalid baseline: a median is not positive",
  )
  // A hand-edited tolerance must still follow the rule, or the file
  // would gate looser than `baseline` ever would.
  use <- guard(
    list.all(baseline.entries, fn(e) {
      e.tolerance == tolerance(e.spread, baseline.floor, baseline.max_spread)
    }),
    "invalid baseline: a tolerance does not follow max(floor, spread) "
      <> "below max_spread",
  )
  Ok(baseline)
}

fn encode_machine(machine: List(#(String, String))) -> json.Json {
  json.object(list.map(machine, fn(kv) { #(kv.0, json.string(kv.1)) }))
}

fn machine_decoder() -> decode.Decoder(List(#(String, String))) {
  decode.dict(decode.string, decode.string)
  |> decode.map(fn(d) { sort_machine(dict.to_list(d)) })
}

fn sort_machine(machine: List(#(String, String))) -> List(#(String, String)) {
  list.sort(machine, fn(a, b) { string.compare(a.0, b.0) })
}

fn encode_direction(direction: Direction) -> json.Json {
  json.string(case direction {
    LowerIsBetter -> "lower"
    HigherIsBetter -> "higher"
  })
}

fn direction_decoder() -> decode.Decoder(Direction) {
  use text <- decode.then(decode.string)
  case text {
    "lower" -> decode.success(LowerIsBetter)
    "higher" -> decode.success(HigherIsBetter)
    _ -> decode.failure(LowerIsBetter, "\"lower\" or \"higher\"")
  }
}

/// A JSON number: Erlang decodes `12` as an int, never as a float.
fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn unique(names: List(String)) -> Bool {
  list.length(list.unique(names)) == list.length(names)
}

fn guard(
  condition: Bool,
  message: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(message)
  }
}
