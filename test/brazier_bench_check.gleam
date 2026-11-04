//// Check the benchmark suite against the committed baseline.
////
//// Run with: `make bench-check` (or `gleam run -m brazier_bench_check`).
//// Runs the suite BRAZIER_BENCH_RUNS times (default 3), takes each metric's
//// median across the runs, and compares it with bench/baselines.json
//// (see brazier/bench/report for the rule). Exits 1 when a metric
//// regressed beyond its tolerance, a metric would be ungated (too noisy
//// in the baseline, missing from the run, new, or redefined), or the run
//// is on a different machine than the baseline, whose numbers do not
//// apply here. Prints the load average the baseline was taken under and
//// the current one. See docs/PERFORMANCE.md. Not a test.

import brazier/bench/cli
import brazier/bench/report
import gleam/io
import gleam/result

const default_runs = 3

pub fn main() -> Nil {
  cli.finish({
    use baseline <- result.try(cli.load_baseline(cli.baseline_path))
    use runs <- result.try(cli.runs_from_env("BRAZIER_BENCH_RUNS", default_runs))
    io.println("-- baseline conditions")
    cli.print_machine(baseline.conditions)
    use load_before <- result.try(cli.load_average())
    io.println("-- load average (1, 5, 15 min) before: " <> load_before)
    use reports <- result.try(cli.run_suite(runs))
    use load_after <- result.try(cli.load_average())
    io.println("-- load average (1, 5, 15 min) after: " <> load_after)
    use run <- result.try(report.combine(reports))
    use Nil <- result.try(cli.write(cli.latest_path, report.encode_report(run)))
    let comparison = report.compare(baseline, run)
    io.println("-- check against " <> cli.baseline_path)
    io.println(report.describe(comparison))
    case report.passed(comparison), comparison.machine_mismatches {
      True, _ -> {
        io.println("-- bench-check passed")
        Ok(Nil)
      }
      False, [] ->
        Error(
          "bench-check failed: a metric regressed or is not gated (see "
          <> "the FAIL lines)",
        )
      False, _ ->
        Error(
          "bench-check failed: this machine is not the baseline's. Its "
          <> "numbers do not apply here; re-baseline on this machine with "
          <> "`make bench-baseline` (and commit it only if this machine is "
          <> "the new reference).",
        )
    }
  })
}
