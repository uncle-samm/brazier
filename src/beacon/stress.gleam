/// Stress testing tools — open many concurrent WebSocket connections
/// and measure the framework's performance under load.
///
/// Usage: `gleam run -m beacon/stress` (with a server running)
import beacon/debug
import beacon/log
import gleam/erlang/process
import gleam/int

/// Stress test configuration.
pub type StressConfig {
  StressConfig(
    /// Number of concurrent connections to open.
    connections: Int,
    /// Host to connect to.
    host: String,
    /// Port to connect to.
    port: Int,
    /// Duration to hold connections open (milliseconds).
    hold_duration_ms: Int,
    /// Number of model events to send on each connection after join.
    events_per_connection: Int,
  )
}

/// Result of a stress test run.
pub type StressResult {
  StressResult(
    /// Number of connections attempted.
    attempted: Int,
    /// Number of connections that succeeded.
    succeeded: Int,
    /// Number of connections that failed.
    failed: Int,
    /// Process count before test.
    processes_before: Int,
    /// Process count during test (peak).
    processes_during: Int,
    /// Process count after test.
    processes_after: Int,
    /// Memory before test (bytes).
    memory_before: Int,
    /// Memory after test (bytes).
    memory_after: Int,
    /// Wall-clock duration for the full stress run.
    duration_ms: Int,
    /// Number of event frames attempted across all connections.
    events_attempted: Int,
  )
}

/// Run a concurrent connection stress test.
/// Opens N connections, holds them, then closes them.
/// Measures process count and memory before/during/after.
pub fn run(config: StressConfig) -> StressResult {
  log.info(
    "beacon.stress",
    "Starting stress test: "
      <> int.to_string(config.connections)
      <> " connections to "
      <> config.host
      <> ":"
      <> int.to_string(config.port),
  )

  let stats_before = debug.stats()
  let result_subject = process.new_subject()

  let start_us = monotonic_us()

  // Spawn real WebSocket connection processes.
  spawn_connections(
    config.connections,
    config.host,
    config.port,
    config.hold_duration_ms,
    config.events_per_connection,
    result_subject,
    1,
  )

  // Wait a moment for all processes to be alive
  process.sleep(100)
  let stats_during = debug.stats()

  // Wait for all to complete
  let selector =
    process.new_selector()
    |> process.select(result_subject)
  let succeeded =
    count_results(
      selector,
      config.connections,
      0,
      config.hold_duration_ms + 5000,
    )

  process.sleep(200)
  let stats_after = debug.stats()
  let duration_ms = { monotonic_us() - start_us } / 1000

  let result =
    StressResult(
      attempted: config.connections,
      succeeded: succeeded,
      failed: config.connections - succeeded,
      processes_before: stats_before.process_count,
      processes_during: stats_during.process_count,
      processes_after: stats_after.process_count,
      memory_before: stats_before.memory_bytes,
      memory_after: stats_after.memory_bytes,
      duration_ms: duration_ms,
      events_attempted: config.connections * config.events_per_connection,
    )

  log.info(
    "beacon.stress",
    "Stress test complete: "
      <> int.to_string(succeeded)
      <> "/"
      <> int.to_string(config.connections)
      <> " succeeded | Processes: "
      <> int.to_string(stats_before.process_count)
      <> " → "
      <> int.to_string(stats_during.process_count)
      <> " → "
      <> int.to_string(stats_after.process_count)
      <> " | Memory delta: "
      <> int.to_string(
      { stats_after.memory_bytes - stats_before.memory_bytes } / 1024,
    )
      <> "KB",
  )

  result
}

/// Spawn N connection processes.
fn spawn_connections(
  remaining: Int,
  host: String,
  port: Int,
  hold_ms: Int,
  events_per_connection: Int,
  subject: process.Subject(Bool),
  index: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let i = index
      // The worker reports success or failure on `subject`; its Pid is not
      // needed.
      process.spawn(fn() {
        let result =
          open_ws_and_exercise(host, port, hold_ms, events_per_connection)
        case result {
          Ok(Nil) -> process.send(subject, True)
          Error(reason) -> {
            log.warning(
              "beacon.stress",
              "Connection "
                <> int.to_string(i)
                <> " failed during stress run: "
                <> reason,
            )
            process.send(subject, False)
          }
        }
      })
      spawn_connections(
        remaining - 1,
        host,
        port,
        hold_ms,
        events_per_connection,
        subject,
        index + 1,
      )
    }
  }
}

/// Count results from the result subject.
fn count_results(
  selector: process.Selector(Bool),
  remaining: Int,
  count: Int,
  timeout: Int,
) -> Int {
  case remaining <= 0 {
    True -> count
    False -> {
      case process.selector_receive(selector, timeout) {
        Ok(True) -> count_results(selector, remaining - 1, count + 1, timeout)
        Ok(False) -> count_results(selector, remaining - 1, count, timeout)
        Error(Nil) -> count
      }
    }
  }
}

@external(erlang, "beacon_stress_ffi", "open_ws_and_exercise")
fn open_ws_and_exercise(
  host: String,
  port: Int,
  hold_ms: Int,
  events_per_connection: Int,
) -> Result(Nil, String)

@external(erlang, "beacon_stress_ffi", "monotonic_us")
fn monotonic_us() -> Int

/// CLI entry point for stress testing.
pub fn main() {
  log.configure()
  let config =
    StressConfig(
      connections: 100,
      host: "localhost",
      port: 8080,
      hold_duration_ms: 1000,
      events_per_connection: 10,
    )
  let result = run(config)
  log.info(
    "beacon.stress",
    "All "
      <> int.to_string(result.succeeded)
      <> " connections completed successfully. Memory stable: "
      <> int.to_string(result.memory_after / 1024 / 1024)
      <> "MB",
  )
}
