//// Re-baseline the benchmark suite on this machine.
////
//// Run with: `make bench-baseline` (or `gleam run -m brazier_bench_baseline`).
//// Runs the suite BRAZIER_BENCH_RUNS times (default 5) back to back and
//// writes bench/baselines.json: per metric the median, min and max of the
//// runs and its tolerance, max(floor, spread) (see brazier/bench/report),
//// plus the load average before and after the runs. Refuses, writing
//// nothing to bench/, when any metric's spread is max_spread or more: such
//// a metric cannot be gated, and the fix is more samples for it. The
//// refused baseline goes to build/bench/refused_baseline.json for a look.
//// Run it on an otherwise idle machine. See docs/PERFORMANCE.md. Not a test.

import brazier/bench/cli
import brazier/bench/report
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

const default_runs = 5

/// Where a refused baseline is written (not committed).
const refused_path = "build/bench/refused_baseline.json"

/// No metric is gated tighter than 25%. Back-to-back runs do not see the
/// drift between sessions (thermal state, other load, power management).
/// The old brazier_runtime_bench, on source unchanged since the commit that
/// recorded it (efc9412), measured changed events at 45-47 us/event in
/// that session and 58-61 us/event in this one (+28%). A tighter floor
/// fails unchanged code. The cost: a regression under 25% (the ~10% of the
/// WS8b telemetry spans, say) passes bench-check, and must be measured
/// head to head, base commit next to branch, in one session.
const floor = 0.25

/// A metric is gated only when its runs spread by less than 50%. Its
/// tolerance is then below 50%, so a 1.5x slowdown of any gated metric
/// fails bench-check. A wider spread is not a looser gate but a metric
/// that needs more samples.
const max_spread = 0.5

pub fn main() -> Nil {
  cli.finish({
    use runs <- result.try(cli.runs_from_env("BRAZIER_BENCH_RUNS", default_runs))
    use load_before <- result.try(cli.load_average())
    io.println("-- load average (1, 5, 15 min) before: " <> load_before)
    use reports <- result.try(cli.run_suite(runs))
    use load_after <- result.try(cli.load_average())
    io.println("-- load average (1, 5, 15 min) after: " <> load_after)
    let conditions = [
      #("load_average_before", load_before),
      #("load_average_after", load_after),
      #("recorded_at", cli.utc_now()),
    ]
    use baseline <- result.try(report.baseline(
      reports,
      conditions,
      floor,
      max_spread,
    ))
    io.println("-- machine")
    cli.print_machine(baseline.machine)
    io.println("-- conditions")
    cli.print_machine(baseline.conditions)
    io.println("-- baseline (median [min..max], spread, tolerance)")
    list.each(baseline.entries, fn(e) {
      io.println(
        "   "
        <> e.name
        <> " = "
        <> report.number(e.median)
        <> " "
        <> e.unit
        <> " ["
        <> report.number(e.min)
        <> ".."
        <> report.number(e.max)
        <> "], spread "
        <> percent(e.spread)
        <> ", "
        <> case e.tolerance {
          Some(t) -> "tolerance " <> percent(t)
          None -> "NOT GATED"
        },
      )
    })
    case report.ungated(baseline) {
      [] -> {
        use Nil <- result.try(cli.write(
          cli.baseline_path,
          report.encode_baseline(baseline),
        ))
        io.println("-- baseline written to " <> cli.baseline_path)
        Ok(Nil)
      }
      noisy -> {
        use Nil <- result.try(cli.write(
          refused_path,
          report.encode_baseline(baseline),
        ))
        Error(
          int.to_string(list.length(noisy))
          <> " metric(s) spread by "
          <> percent(max_spread)
          <> " or more across the runs and cannot be gated: "
          <> string.join(
            list.map(noisy, fn(e) {
              e.name <> " (spread " <> percent(e.spread) <> ")"
            }),
            ", ",
          )
          <> ". Raise their samples in brazier/bench/suite, or re-run on an "
          <> "idle machine. "
          <> cli.baseline_path
          <> " is unchanged; the refused baseline is in "
          <> refused_path,
        )
      }
    }
  })
}

fn percent(fraction: Float) -> String {
  float.to_string(float.to_precision(fraction *. 100.0, 1)) <> "%"
}
