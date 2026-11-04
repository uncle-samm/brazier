import brazier/bench/cli
import gleam/list
import gleam/string
import simplifile

const scratch = "build/test_bench_cli"

pub fn load_baseline_of_a_missing_file_says_nothing_is_gated_test() {
  let assert Error(reason) =
    cli.load_baseline(scratch <> "/no_such_baseline.json")
    as "a missing baseline must be an error"
  assert string.contains(reason, "no_such_baseline.json")
  assert string.contains(reason, "no baseline, so no metric is gated")
  assert string.contains(reason, "make bench-baseline")
}

pub fn load_baseline_of_an_old_format_file_is_an_error_test() {
  let path = scratch <> "/old_format.json"
  let assert Ok(Nil) = simplifile.create_directory_all(scratch)
    as "the scratch directory is creatable under build/"
  let assert Ok(Nil) =
    simplifile.write(
      path,
      "{\"machine\":{},\"runs\":5,\"floor\":0.25,\"ceiling\":1.0,\"entries\":[]}",
    )
    as "the scratch file is writable"
  let assert Error(reason) = cli.load_baseline(path)
    as "a baseline without max_spread must be refused"
  assert string.contains(reason, "invalid baseline")
  assert string.contains(reason, "make bench-baseline")
}

pub fn load_average_reads_three_numbers_test() {
  let assert Ok(load) = cli.load_average()
    as "the bench machines (macOS, Linux) report a load average"
  assert list.length(string.split(load, " ")) == 3
}
