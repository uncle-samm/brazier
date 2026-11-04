//// What the bench entry points share: running the suite several times,
//// the files they read and write, and the exit status.

import brazier/bench/report
import brazier/bench/suite
import brazier/config
import brazier/error
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// The committed baseline `make bench-check` compares against.
pub const baseline_path = "bench/baselines.json"

/// The last run's report (not committed).
pub const latest_path = "build/bench/latest.json"

@external(erlang, "brazier_bench_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

/// What the VM holds after a run (processes, ports, ETS tables, memory).
@external(erlang, "brazier_bench_ffi", "vm_census")
fn vm_census() -> List(#(String, Int))

@external(erlang, "brazier_bench_ffi", "halt")
pub fn halt(code: Int) -> Nil

/// The 1, 5 and 15 minute load averages, as "3.66 6.15 6.81".
@external(erlang, "brazier_bench_ffi", "load_average")
pub fn load_average() -> Result(String, String)

/// The current UTC time, RFC 3339.
@external(erlang, "brazier_bench_ffi", "utc_now")
pub fn utc_now() -> String

/// Read and decode the baseline at `path`. A missing or unreadable file
/// is an error that says how to make one: without a baseline no metric is
/// gated.
pub fn load_baseline(path: String) -> Result(report.Baseline, String) {
  use text <- result.try(
    read(path)
    |> result.map_error(fn(reason) {
      reason
      <> ": no baseline, so no metric is gated (create one with `make "
      <> "bench-baseline`)"
    }),
  )
  report.decode_baseline(text)
  |> result.map_error(fn(reason) {
    path <> ": " <> reason <> " (re-create it with `make bench-baseline`)"
  })
}

/// A positive run count from the environment variable `name`, or
/// `default` when it is unset. A set but invalid value is an error, never
/// silently replaced.
pub fn runs_from_env(name: String, default: Int) -> Result(Int, String) {
  use Nil <- result.try(
    config.refuse_renamed_env([name])
    |> result.map_error(error.to_string),
  )
  case getenv(name) {
    Error(Nil) -> Ok(default)
    Ok(text) ->
      case int.parse(string.trim(text)) {
        Ok(runs) if runs > 0 -> Ok(runs)
        _ -> Error(name <> " must be a positive integer, got " <> text)
      }
  }
}

/// Prepare the suite once (fixtures, files), then run it `runs` times,
/// printing each run's metrics.
pub fn run_suite(runs: Int) -> Result(List(report.Report), String) {
  io.println("-- preparing the bench fixtures")
  use prepared <- result.try(suite.prepare())
  io.println("-- vm before the runs: " <> census())
  int.range(from: 1, to: runs + 1, with: Ok([]), run: fn(acc, index) {
    use done <- result.try(acc)
    io.println(
      "-- run " <> int.to_string(index) <> " of " <> int.to_string(runs),
    )
    use run <- result.try(suite.run(prepared))
    list.each(run.metrics, fn(m) { io.println("   " <> suite.describe(m)) })
    io.println("-- vm after run " <> int.to_string(index) <> ": " <> census())
    Ok([run, ..done])
  })
  |> result.map(list.reverse)
}

fn census() -> String {
  vm_census()
  |> list.map(fn(kv) { kv.0 <> "=" <> int.to_string(kv.1) })
  |> string.join(" ")
}

pub fn print_machine(machine: List(#(String, String))) -> Nil {
  list.each(machine, fn(kv) { io.println("   " <> kv.0 <> ": " <> kv.1) })
}

/// Write `text` to `path`, creating its directory.
pub fn write(path: String, text: String) -> Result(Nil, String) {
  let directory =
    string.split(path, "/")
    |> list.reverse
    |> list.drop(1)
    |> list.reverse
    |> string.join("/")
  use Nil <- result.try(case directory {
    "" -> Ok(Nil)
    _ ->
      simplifile.create_directory_all(directory)
      |> result.map_error(fn(e) {
        "create " <> directory <> ": " <> simplifile.describe_error(e)
      })
  })
  simplifile.write(path, text <> "\n")
  |> result.map_error(fn(e) {
    "write " <> path <> ": " <> simplifile.describe_error(e)
  })
}

pub fn read(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(e) {
    "read " <> path <> ": " <> simplifile.describe_error(e)
  })
}

/// Print the outcome and exit: 0 on Ok, 1 with the reason on Error.
pub fn finish(outcome: Result(Nil, String)) -> Nil {
  case outcome {
    Ok(Nil) -> halt(0)
    Error(reason) -> {
      io.println_error("bench: " <> reason)
      halt(1)
    }
  }
}
