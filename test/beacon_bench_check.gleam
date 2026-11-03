//// Check the benchmark suite against the committed baseline.
////
//// Run with: `make bench-check` (or `gleam run -m beacon_bench_check`).
//// Runs the suite BEACON_BENCH_RUNS times (default 3), takes each metric's
//// median across the runs, and compares it with bench/baselines.json
//// (see beacon/bench/report for the rule). Exits 1 when a gated metric
//// regressed beyond its tolerance, a metric is missing or new, or the run
//// is on a different machine than the baseline, whose numbers do not
//// apply here. See docs/PERFORMANCE.md. Not a test.

import beacon/bench/cli
import beacon/bench/report
import gleam/io
import gleam/result

const default_runs = 3

pub fn main() -> Nil {
  cli.finish({
    use text <- result.try(
      cli.read(cli.baseline_path)
      |> result.map_error(fn(reason) {
        reason <> " (create one with `make bench-baseline`)"
      }),
    )
    use baseline <- result.try(report.decode_baseline(text))
    use runs <- result.try(cli.runs_from_env("BEACON_BENCH_RUNS", default_runs))
    use reports <- result.try(cli.run_suite(runs))
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
      False, [] -> Error("bench-check failed: a metric regressed or changed")
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
