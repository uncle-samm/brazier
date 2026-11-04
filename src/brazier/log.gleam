/// Brazier's structured logging module.
/// Wraps the `logging` package with consistent formatting and context.
/// All log messages include the module/function context for traceability.
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
  logging.log(logging.Info, "[" <> module <> "] " <> message)
}

/// Log a debug-level message with module context.
/// Use for: detailed tracing, variable values, internal state.
pub fn debug(module: String, message: String) -> Nil {
  logging.log(logging.Debug, "[" <> module <> "] " <> message)
}

/// Log a warning-level message with module context.
/// Use for: unexpected but handled conditions, deprecations.
pub fn warning(module: String, message: String) -> Nil {
  logging.log(logging.Warning, "[" <> module <> "] " <> message)
}

/// Log an error-level message with module context.
/// Use for: failures, unrecoverable errors, assertion violations.
pub fn error(module: String, message: String) -> Nil {
  logging.log(logging.Error, "[" <> module <> "] " <> message)
}
