//// Re-baseline the benchmark suite on this machine.
////
//// Run with: `make bench-baseline` (or `gleam run -m brazier_bench_baseline`).
//// Runs the suite BRAZIER_BENCH_RUNS times (default 5) back to back and
//// writes bench/baselines.json: per metric the median, min and max of the
//// runs and its tolerance, max(floor, 2 x spread), or "not gated" when
//// that would exceed the ceiling (see brazier/bench/report). Run it on an
//// otherwise idle machine. See docs/PERFORMANCE.md. Not a test.

import brazier/bench/cli
import brazier/bench/report
import gleam/float
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result

const default_runs = 5

/// No metric is gated tighter than 25%. Back-to-back runs do not see the
/// drift between sessions (thermal state, other load, power management).
/// The old brazier_runtime_bench, on source unchanged since the commit that
/// recorded it (efc9412), measured changed events at 45-47 us/event in
/// that session and 58-61 us/event in this one (+28%). A tighter floor
/// fails unchanged code. The cost: a regression under 25% (the ~10% of the
/// WS8b telemetry spans, say) passes bench-check, and must be measured
/// head to head, base commit next to branch, in one session.
const floor = 0.25

/// A metric whose runs spread so widely that its tolerance would exceed
/// 100% (a 2x slowdown passes) cannot catch a regression; it is recorded
/// and reported, not gated.
const ceiling = 1.0

pub fn main() -> Nil {
  cli.finish({
    use runs <- result.try(cli.runs_from_env("BRAZIER_BENCH_RUNS", default_runs))
    use reports <- result.try(cli.run_suite(runs))
    use baseline <- result.try(report.baseline(reports, floor, ceiling))
    use Nil <- result.try(cli.write(
      cli.baseline_path,
      report.encode_baseline(baseline),
    ))
    io.println("-- machine")
    cli.print_machine(baseline.machine)
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
          None -> "not gated"
        },
      )
    })
    io.println("-- baseline written to " <> cli.baseline_path)
    Ok(Nil)
  })
}

fn percent(fraction: Float) -> String {
  float.to_string(float.to_precision(fraction *. 100.0, 1)) <> "%"
}
