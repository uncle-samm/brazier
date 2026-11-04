//// Test helper: run a function and collect the log lines it emits.

import gleam/list
import gleam/string

/// A captured log event: the level name (e.g. "warning") and its text.
pub type Captured {
  Captured(level: String, message: String)
}

/// Run `fun` and return its result with every log event the calling process
/// emitted while it ran, in order.
pub fn capture(fun: fn() -> a) -> #(a, List(Captured)) {
  let #(result, events) = do_capture(fun)
  #(result, list.map(events, fn(event) { Captured(event.0, event.1) }))
}

/// Whether some captured event has `level` and contains every fragment.
pub fn has(
  logs: List(Captured),
  level level: String,
  containing fragments: List(String),
) -> Bool {
  list.any(logs, fn(event) {
    event.level == level
    && list.all(fragments, fn(fragment) {
      string.contains(event.message, fragment)
    })
  })
}

@external(erlang, "brazier_own_log_capture_ffi", "capture")
fn do_capture(fun: fn() -> a) -> #(a, List(#(String, String)))
