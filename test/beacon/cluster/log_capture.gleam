//// Capture log lines produced while a function runs.

import gleam/list
import gleam/string

/// A captured log line: its level (`"error"`, `"warning"`, ...) and text.
pub type Line {
  Line(level: String, message: String)
}

/// Run `run` and return its result with every log line emitted meanwhile
/// by any process on this node.
pub fn capture(run: fn() -> a) -> #(a, List(Line)) {
  let #(result, lines) = ffi_capture(run)
  #(result, list.map(lines, fn(line) { Line(level: line.0, message: line.1) }))
}

/// Whether a line at `level` contains `fragment`.
pub fn contains(lines: List(Line), level: String, fragment: String) -> Bool {
  list.any(lines, fn(line) {
    line.level == level && string.contains(line.message, fragment)
  })
}

@external(erlang, "beacon_log_capture_ffi", "capture")
fn ffi_capture(run: fn() -> a) -> #(a, List(#(String, String)))
