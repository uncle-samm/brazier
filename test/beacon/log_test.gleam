import beacon/log
import beacon/log_capture.{Captured}

// Each level reaches the logger at that level, with the module prefixed
// in brackets: the format every `[module]` grep in the docs relies on.
// `log.configure` is not called here: it resets the primary level the test
// runner lowered to keep output quiet, for every test that runs after.

pub fn info_logs_at_info_with_the_module_test() {
  let #(Nil, logs) =
    log_capture.capture(fn() { log.info("log_test", "info message") })
  assert logs == [Captured(level: "info", message: "[log_test] info message")]
}

pub fn debug_logs_at_debug_with_the_module_test() {
  let #(Nil, logs) =
    log_capture.capture(fn() { log.debug("log_test", "debug message") })
  assert logs == [Captured(level: "debug", message: "[log_test] debug message")]
}

pub fn warning_logs_at_warning_with_the_module_test() {
  let #(Nil, logs) =
    log_capture.capture(fn() { log.warning("log_test", "warning message") })
  assert logs
    == [Captured(level: "warning", message: "[log_test] warning message")]
}

pub fn error_logs_at_error_with_the_module_test() {
  let #(Nil, logs) =
    log_capture.capture(fn() { log.error("log_test", "error message") })
  assert logs == [Captured(level: "error", message: "[log_test] error message")]
}
