/// Stress tool: hold many concurrent, joined WebSocket connections open and
/// measure the node while they are all open.
///
/// Each client upgrades, joins and sends its events one at a time, waiting
/// for the patch that acknowledges each one (brazier_stress_ffi checks every
/// answer against the wire protocol). It then reports that it is held and
/// stays open until `run` has seen every client held, so the "held"
/// measurement is taken with all of them open at once. Then every client
/// runs the close handshake. Nothing sleeps to let the server settle.
///
/// Usage: `gleam run -m brazier/stress` (with a server running on 8080).
import brazier/await
import brazier/debug
import brazier/log
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string

/// Stress test configuration.
pub type StressConfig {
  StressConfig(
    /// Number of concurrent connections to open.
    connections: Int,
    /// Host to connect to.
    host: String,
    /// Port to connect to.
    port: Int,
    /// How long to keep every connection open once all of them are held,
    /// before closing them. 0 closes them as soon as they are all held.
    /// Holding is the load being measured, so this one wait is deliberate.
    hold_duration_ms: Int,
    /// Number of events to send on each connection after join; each one
    /// must be acknowledged by a patch.
    events_per_connection: Int,
  )
}

/// Result of a stress run.
pub type StressResult {
  StressResult(
    /// Number of connections attempted.
    attempted: Int,
    /// Connections that joined, had every event acknowledged and closed
    /// with a 1000 close handshake.
    succeeded: Int,
    /// Connections that failed at any step.
    failed: Int,
    /// Why each failed connection failed.
    failures: List(String),
    /// Connections that were open and joined at the same time.
    held: Int,
    /// Events acknowledged by a patch carrying their clock.
    events_acknowledged: Int,
    /// Node process count before the run.
    processes_before: Int,
    /// Node process count while every held connection was open.
    processes_held: Int,
    /// Node memory before the run (bytes).
    memory_before: Int,
    /// Node memory while every held connection was open (bytes).
    memory_held: Int,
    /// Wall-clock duration of the whole run.
    duration_ms: Int,
  )
}

type ClientReport {
  /// Joined, every event acknowledged; waiting on `release` to close.
  Held(index: Int, acknowledged: Int, release: Subject(Nil))
  /// Finished: Ok after a clean close handshake, Error naming the failure.
  Finished(index: Int, result: Result(Nil, String))
}

/// The client's opaque socket state (owned by the client process).
type Conn

/// Run a concurrent connection stress test. Every wait is bounded by
/// `await.deadline_ms` (plus the hold) and a client that misses it is
/// reported as failed, never waited on forever.
pub fn run(config: StressConfig) -> StressResult {
  let assert True = config.connections > 0
  let assert True = config.events_per_connection >= 0
  let assert True = config.hold_duration_ms >= 0
  log.info(
    "brazier.stress",
    "Starting stress run: "
      <> int.to_string(config.connections)
      <> " connections x "
      <> int.to_string(config.events_per_connection)
      <> " events to "
      <> config.host
      <> ":"
      <> int.to_string(config.port),
  )
  let stats_before = debug.stats()
  let started_us = monotonic_us()
  let reports = process.new_subject()
  list.repeat(Nil, config.connections)
  |> list.index_map(fn(_, i) {
    process.spawn(fn() { client(config, i + 1, reports) })
  })

  // Phase 1: every client is either held open or has failed.
  let #(held, early_failures) =
    collect_phase1(reports, config.connections, [], [])
  let stats_held = debug.stats()
  case config.hold_duration_ms {
    0 -> Nil
    hold -> process.sleep(hold)
  }

  // Phase 2: release the held clients and collect their close results.
  list.each(held, fn(report) {
    let assert Held(release: release, ..) = report
    process.send(release, Nil)
  })
  let close_results = collect_phase2(reports, list.length(held), [])
  let close_failures =
    list.filter_map(close_results, fn(result) {
      case result {
        #(_, Ok(Nil)) -> Error(Nil)
        #(index, Error(reason)) -> Ok(describe(index, reason))
      }
    })
  let failures = list.append(early_failures, close_failures)
  let acknowledged =
    list.fold(held, 0, fn(total, report) {
      let assert Held(acknowledged: acknowledged, ..) = report
      total + acknowledged
    })
  let failed = list.length(failures)
  let result =
    StressResult(
      attempted: config.connections,
      succeeded: config.connections - failed,
      failed: failed,
      failures: failures,
      held: list.length(held),
      events_acknowledged: acknowledged,
      processes_before: stats_before.process_count,
      processes_held: stats_held.process_count,
      memory_before: stats_before.memory_bytes,
      memory_held: stats_held.memory_bytes,
      duration_ms: { monotonic_us() - started_us } / 1000,
    )
  log_result(result)
  result
}

fn client(config: StressConfig, index: Int, reports: Subject(ClientReport)) {
  case
    connect_and_join(
      config.host,
      config.port,
      config.events_per_connection,
      await.deadline_ms,
    )
  {
    Error(reason) -> process.send(reports, Finished(index, Error(reason)))
    Ok(#(conn, acknowledged)) -> {
      let release = process.new_subject()
      process.send(reports, Held(index, acknowledged, release))
      let result = case
        process.receive(release, config.hold_duration_ms + await.deadline_ms)
      {
        Ok(Nil) -> close_handshake(conn, await.deadline_ms)
        Error(Nil) -> {
          let closed = case close_handshake(conn, await.deadline_ms) {
            Ok(Nil) -> "closed cleanly"
            Error(reason) -> "close failed: " <> reason
          }
          Error("never released by the coordinator (" <> closed <> ")")
        }
      }
      process.send(reports, Finished(index, result))
    }
  }
}

/// Wait until each of `remaining` clients is held or finished (failed).
fn collect_phase1(
  reports: Subject(ClientReport),
  remaining: Int,
  held: List(ClientReport),
  failures: List(String),
) -> #(List(ClientReport), List(String)) {
  case remaining {
    0 -> #(list.reverse(held), list.reverse(failures))
    _ ->
      case process.receive(reports, await.deadline_ms) {
        Ok(Held(..) as report) ->
          collect_phase1(reports, remaining - 1, [report, ..held], failures)
        Ok(Finished(index, Error(reason))) ->
          collect_phase1(reports, remaining - 1, held, [
            describe(index, reason),
            ..failures
          ])
        Ok(Finished(index, Ok(Nil))) ->
          panic as {
            "stress client "
            <> int.to_string(index)
            <> " finished before it was held"
          }
        Error(Nil) -> {
          let missing =
            "no report from "
            <> int.to_string(remaining)
            <> " clients within "
            <> int.to_string(await.deadline_ms)
            <> " ms"
          #(list.reverse(held), list.reverse([missing, ..failures]))
        }
      }
  }
}

/// Collect the close results of `remaining` released clients.
fn collect_phase2(
  reports: Subject(ClientReport),
  remaining: Int,
  results: List(#(Int, Result(Nil, String))),
) -> List(#(Int, Result(Nil, String))) {
  case remaining {
    0 -> list.reverse(results)
    _ ->
      case process.receive(reports, 2 * await.deadline_ms) {
        Ok(Finished(index, result)) ->
          collect_phase2(reports, remaining - 1, [#(index, result), ..results])
        Ok(Held(index: index, ..)) ->
          panic as {
            "stress client " <> int.to_string(index) <> " reported held twice"
          }
        Error(Nil) ->
          list.reverse([
            #(
              0,
              Error(
                int.to_string(remaining) <> " released clients never finished",
              ),
            ),
            ..results
          ])
      }
  }
}

fn describe(index: Int, reason: String) -> String {
  "connection " <> int.to_string(index) <> ": " <> reason
}

fn log_result(result: StressResult) -> Nil {
  let summary =
    int.to_string(result.succeeded)
    <> "/"
    <> int.to_string(result.attempted)
    <> " succeeded, "
    <> int.to_string(result.held)
    <> " held at once, "
    <> int.to_string(result.events_acknowledged)
    <> " events acknowledged in "
    <> int.to_string(result.duration_ms)
    <> " ms | processes "
    <> int.to_string(result.processes_before)
    <> " -> "
    <> int.to_string(result.processes_held)
    <> " | memory delta while held "
    <> int.to_string({ result.memory_held - result.memory_before } / 1024)
    <> " KB"
  case result.failures {
    [] -> log.info("brazier.stress", "Stress run complete: " <> summary)
    failures ->
      log.error(
        "brazier.stress",
        "Stress run had failures: "
          <> summary
          <> " | "
          <> string.join(failures, "; "),
      )
  }
}

@external(erlang, "brazier_stress_ffi", "connect_and_join")
fn connect_and_join(
  host: String,
  port: Int,
  events: Int,
  timeout_ms: Int,
) -> Result(#(Conn, Int), String)

@external(erlang, "brazier_stress_ffi", "close_handshake")
fn close_handshake(conn: Conn, timeout_ms: Int) -> Result(Nil, String)

@external(erlang, "brazier_stress_ffi", "monotonic_us")
fn monotonic_us() -> Int

/// CLI entry point. Exits non-zero when any connection failed.
pub fn main() {
  log.configure()
  let result =
    run(StressConfig(
      connections: 100,
      host: "localhost",
      port: 8080,
      hold_duration_ms: 1000,
      events_per_connection: 10,
    ))
  case result.failed {
    0 -> Nil
    failed -> {
      log.error(
        "brazier.stress",
        int.to_string(failed) <> " connections failed; exiting 1",
      )
      halt(1)
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil
