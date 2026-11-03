//// Run the benchmark suite once and print every metric.
////
//// Run with: `make bench` (or `gleam run -m beacon_bench`). Writes the
//// report to build/bench/latest.json. Exits 1 if any scenario fails.
//// See docs/PERFORMANCE.md. Not a test: gleam test never runs it.

import beacon/bench/cli
import beacon/bench/report
import gleam/io
import gleam/result

pub fn main() -> Nil {
  cli.finish({
    use runs <- result.try(cli.run_suite(1))
    use run <- result.try(report.combine(runs))
    io.println("-- machine")
    cli.print_machine(run.machine)
    use Nil <- result.try(cli.write(cli.latest_path, report.encode_report(run)))
    io.println("-- report written to " <> cli.latest_path)
    Ok(Nil)
  })
}
