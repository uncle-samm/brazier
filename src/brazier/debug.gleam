/// Debug and introspection tools for Brazier applications.
/// Provides runtime statistics and monitoring capabilities.
///
/// Reference: Phoenix.Telemetry, Erlang observer.
import brazier/log
import gleam/erlang/process
import gleam/int

/// Runtime statistics.
pub type Stats {
  Stats(
    /// Number of BEAM processes running.
    process_count: Int,
    /// Total memory used by the BEAM VM in bytes.
    memory_bytes: Int,
    /// Uptime in seconds.
    uptime_seconds: Int,
  )
}

/// Get current runtime statistics.
pub fn stats() -> Stats {
  Stats(
    process_count: erlang_process_count(),
    memory_bytes: erlang_memory_total(),
    uptime_seconds: erlang_uptime_seconds(),
  )
}

/// Log current runtime statistics.
pub fn log_stats() -> Nil {
  let s = stats()
  log.info(
    "brazier.debug",
    "Processes: "
      <> int.to_string(s.process_count)
      <> " | Memory: "
      <> int.to_string(s.memory_bytes / 1024 / 1024)
      <> "MB | Uptime: "
      <> int.to_string(s.uptime_seconds)
      <> "s",
  )
}

/// Check if a PID is alive.
pub fn is_alive(pid: process.Pid) -> Bool {
  erlang_is_alive(pid)
}

// --- Erlang FFI ---

@external(erlang, "brazier_debug_ffi", "process_count")
fn erlang_process_count() -> Int

@external(erlang, "brazier_debug_ffi", "memory_total")
fn erlang_memory_total() -> Int

@external(erlang, "brazier_debug_ffi", "uptime_seconds")
fn erlang_uptime_seconds() -> Int

@external(erlang, "erlang", "is_process_alive")
fn erlang_is_alive(pid: process.Pid) -> Bool
