/// Brazier's structured logging module.
/// Wraps the `logging` package with consistent formatting and context.
/// All log messages include the module/function context for traceability.
///
/// Each level function asks the logger whether the level is enabled
/// (`logger:allow/2`, the check OTP's `?LOG_DEBUG` macros make) before it
/// builds the line, so a disabled debug call costs one ETS lookup instead
/// of a string concatenation and a logger call. What is logged is the same.
import logging

/// Initialize the logging system. Must be called once at application startup.
pub fn configure() -> Nil {
  logging.configure()
}

/// Set the minimum log level. Messages below this level are filtered out.
pub fn set_level(level: logging.LogLevel) -> Nil {
  logging.set_level(level)
}

/// Log an info-level message with module context.
/// Use for: state transitions, successful operations, lifecycle events.
pub fn info(module: String, message: String) -> Nil {
  emit(logging.Info, module, message)
}

/// Log a debug-level message with module context.
/// Use for: detailed tracing, variable values, internal state.
pub fn debug(module: String, message: String) -> Nil {
  emit(logging.Debug, module, message)
}

/// Log a warning-level message with module context.
/// Use for: unexpected but handled conditions, deprecations.
pub fn warning(module: String, message: String) -> Nil {
  emit(logging.Warning, module, message)
}

/// Log an error-level message with module context.
/// Use for: failures, unrecoverable errors, assertion violations.
pub fn error(module: String, message: String) -> Nil {
  emit(logging.Error, module, message)
}

fn emit(level: logging.LogLevel, module: String, message: String) -> Nil {
  case allowed(level) {
    True -> logging.log(level, "[" <> module <> "] " <> message)
    False -> Nil
  }
}

/// Whether the logger would pass an event at `level` (`logger:allow/2`).
@external(erlang, "brazier_log_ffi", "allowed")
fn allowed(level: logging.LogLevel) -> Bool
