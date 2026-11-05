//// `log_path.describe` keeps at most `log_path.max_bytes` of a path, cuts
//// on a code point boundary, and says how many bytes it left out, after
//// the closing quote where client text cannot reach.

import brazier/internal/log_path
import gleam/int
import gleam/list
import gleam/string

fn path_of(bytes: Int) -> String {
  "/" <> string.repeat("a", bytes - 1)
}

pub fn a_path_of_max_bytes_is_kept_whole_test() {
  let path = path_of(log_path.max_bytes)
  assert log_path.describe(path) == string.inspect(path)
}

pub fn a_path_one_byte_over_is_cut_and_says_so_test() {
  let path = path_of(log_path.max_bytes + 1)
  assert log_path.describe(path)
    == string.inspect(path_of(log_path.max_bytes)) <> " (1 more byte left out)"
}

pub fn a_long_path_says_how_many_bytes_it_left_out_test() {
  let path = path_of(log_path.max_bytes + 1000)
  assert log_path.describe(path)
    == string.inspect(path_of(log_path.max_bytes))
    <> " (1000 more bytes left out)"
}

/// `é` is 2 bytes and starts at the last kept byte: it is left out whole.
pub fn a_two_byte_code_point_across_the_cut_is_left_out_whole_test() {
  let kept = path_of(log_path.max_bytes - 1)
  let path = kept <> "é" <> "tail"
  assert log_path.describe(path)
    == string.inspect(kept) <> " (6 more bytes left out)"
}

/// The 4-byte code point ends 1, 2 and 3 bytes past the cut: each time the
/// cut drops back to the boundary before it, never splitting it.
pub fn a_four_byte_code_point_across_the_cut_is_left_out_whole_test() {
  let emoji = "😀"
  assert string.byte_size(emoji) == 4
  [1, 2, 3]
  |> list.each(fn(past) {
    let kept = path_of(log_path.max_bytes + past - 4)
    let path = kept <> emoji <> "z"
    let left_out = 4 + 1
    assert log_path.describe(path)
      == string.inspect(kept)
      <> " ("
      <> int.to_string(left_out)
      <> " more bytes left out)"
  })
}

pub fn the_query_is_dropped_before_the_path_is_measured_test() {
  let query = string.repeat("x", log_path.max_bytes * 4)
  assert log_path.describe("/settings?token=" <> query) == "\"/settings\""
}

/// A newline in the kept part is still quoted, and the marker follows the
/// closing quote, so the cut line cannot be forged into two.
pub fn a_cut_path_stays_one_quoted_line_test() {
  let path = "/a\nINFO forged" <> string.repeat("b", log_path.max_bytes)
  let described = log_path.describe(path)
  assert !string.contains(described, "\n")
  assert string.starts_with(described, "\"/a\\nINFO forged")
  assert string.ends_with(described, "\" (14 more bytes left out)")
}
