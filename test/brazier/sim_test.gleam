/// Simulation tests — real WebSocket connections against real Brazier servers.
/// Each test starts a fresh app on an OS-assigned port, runs N concurrent
/// connections, and verifies performance and correctness metrics.
///
/// Nothing here sleeps to "let the server settle". A run ends when every
/// pool worker has exited (`pool.run`) and, for runs that measure leaks,
/// when every server connection handler and its runtime have exited
/// (`teardown.await_closed`). Process and memory snapshots taken after that
/// measure what the server kept, not what it had not finished freeing.
/// Every test stops its app, so listeners do not accumulate across tests.
import brazier/application
import brazier/log
import brazier/sim/metrics
import brazier/sim/pool
import brazier/sim/report
import brazier/sim/scenario
import brazier/sim/teardown
import brazier/sim/test_app
import brazier/transport
import gleam/int
import gleam/string

/// One pool run against `app`, with leak snapshots taken after the server
/// has torn down every connection the run opened.
type Run {
  Run(
    result: pool.PoolResult,
    metrics: metrics.SimMetrics,
    report: report.SimReport,
  )
}

fn run_measured(
  app: application.App,
  name: String,
  concurrency: Int,
  run_scenario: scenario.Scenario,
  stagger_ms: Int,
) -> Run {
  warm_up(app)
  let mt = metrics.new()
  let #(result, mem_before, procs_before, pids_before) = {
    use watch <- teardown.watching(app)
    let mem_before = metrics.snapshot_memory()
    let procs_before = metrics.snapshot_processes()
    let pids_before = metrics.snapshot_pids()
    let result =
      pool.run(pool.PoolConfig(
        concurrency: concurrency,
        host: "localhost",
        port: app.port,
        scenario: run_scenario,
        stagger_ms: stagger_ms,
        metrics: mt,
      ))
    teardown.await_closed(watch, result.upgraded)
    #(result, mem_before, procs_before, pids_before)
  }

  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()
  let procs_survived = metrics.count_new_processes(pids_before)
  let m = metrics.collect(mt)
  metrics.destroy(mt)
  let r =
    report.generate(
      name,
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
      procs_survived,
    )
  report.log_report(r)
  case r.processes_leaked {
    0 -> Nil
    _ ->
      log.warning(
        "brazier.sim_test",
        name
          <> ": processes alive after teardown that were not before: "
          <> metrics.describe_new_processes(pids_before),
      )
  }
  Run(result: result, metrics: m, report: r)
}

/// Serve one connection before the leak baseline is taken. The first
/// connection in a VM starts a singleton that lives for the rest of it: the
/// native resolver for "localhost" (inet_gethost_native). It is not per
/// connection state, so it belongs in the baseline; anything a measured
/// connection leaves behind still shows up, once per connection.
fn warm_up(app: application.App) -> Nil {
  let mt = metrics.new()
  let result = {
    use watch <- teardown.watching(app)
    let result =
      pool.run(pool.PoolConfig(
        concurrency: 1,
        host: "localhost",
        port: app.port,
        scenario: scenario.connect_disconnect(),
        stagger_ms: 0,
        metrics: mt,
      ))
    teardown.await_closed(watch, result.upgraded)
    result
  }
  metrics.destroy(mt)
  let assert [] = result.failures
  let assert 1 = result.upgraded
  Nil
}

/// Fail with both strings, so a mismatch shows what was received.
fn assert_contains(haystack: String, needle: String) -> Nil {
  case string.contains(haystack, needle) {
    True -> Nil
    False -> {
      // eunit truncates the panic message; the log keeps all of it.
      let message = "expected " <> needle <> " in " <> haystack
      log.error("brazier.sim_test", message)
      panic as message
    }
  }
}

/// Every worker completed its scenario and the server kept no process.
fn assert_all_clean(run: Run) -> Nil {
  let assert [] = run.result.failures
  let assert True = run.result.succeeded == run.result.total
  let assert 0 = run.report.processes_leaked
  Nil
}

fn stop(app: application.App) -> Nil {
  let assert Ok(Nil) = application.stop(app)
  Nil
}

// ===== Smoke Test =====

pub fn sim_10_connections_smoke_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let run = run_measured(app, "smoke_10", 10, scenario.counter(10), 10)
  assert_all_clean(run)
  // One join response and ten event responses per connection.
  let assert 100 = run.metrics.events_sent
  let assert 100 = run.metrics.events_acked
  stop(app)
}

// ===== Scale Tests =====

pub fn sim_100_connections_counter_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let run = run_measured(app, "scale_100_counter", 100, scenario.counter(20), 5)
  assert_all_clean(run)
  let assert 2000 = run.metrics.events_sent
  let assert 2000 = run.metrics.events_acked
  stop(app)
}

// ===== Leak Detection =====

/// 100 connect/disconnect cycles leave nothing behind: no process
/// (`assert_all_clean`), no ETS table or object, and no atom.
///
/// The first round pays the one-time costs of serving connections (atoms
/// and tables made on first use), so the second round is the one measured,
/// and it must keep exactly nothing. Memory in bytes is logged but not
/// asserted: a heap's size depends on the process's GC history and an ETS
/// table's on its peak load, not only on what they hold, so an exact or
/// tight bound on bytes would be a flaky test, and a loose one would catch
/// nothing.
pub fn sim_memory_leak_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let first =
    run_measured(
      app,
      "memory_leak_first",
      100,
      scenario.connect_disconnect(),
      5,
    )
  assert_all_clean(first)
  let before = kept_state()
  let second =
    run_measured(
      app,
      "memory_leak_second",
      100,
      scenario.connect_disconnect(),
      5,
    )
  let change = describe_change(before, kept_state())
  assert_all_clean(second)
  let assert 100 = second.result.upgraded
  log.info(
    "brazier.sim_test",
    "memory_leak: second round of 100 changed VM memory by "
      <> int.to_string(second.report.memory_delta_kb)
      <> " KiB; ETS and atoms: "
      <> case change {
      "" -> "unchanged"
      _ -> change
    },
  )
  assert change == "" as "a round of connections left ETS state or atoms"
  stop(app)
}

/// The leak test's check sees each kind of kept state it claims to.
pub fn kept_state_sees_a_new_table_object_and_atom_test() {
  let start = kept_state()
  let name = binary_to_atom("brazier_sim_kept_state_" <> unique_suffix())
  let with_atom = kept_state()
  assert_contains(describe_change(start, with_atom), "atom count changed by 1")

  let table = ets_new(name, [])
  let with_table = kept_state()
  assert_contains(describe_change(with_atom, with_table), "new table")

  let assert True = ets_insert(table, #(1))
  assert_contains(describe_change(with_table, kept_state()), "0 -> 1 objects")

  let assert True = ets_delete(table)
  assert_contains(describe_change(with_table, kept_state()), "deleted")
}

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> EtsName

@external(erlang, "ets", "new")
fn ets_new(name: EtsName, options: List(Nil)) -> EtsTable

@external(erlang, "ets", "insert")
fn ets_insert(table: EtsTable, object: #(Int)) -> Bool

@external(erlang, "ets", "delete")
fn ets_delete(table: EtsTable) -> Bool

fn unique_suffix() -> String {
  int.to_string(unique_integer())
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

type EtsName

type EtsTable

/// Every ETS table (id, name, objects, words) and the atom count.
type KeptState

@external(erlang, "brazier_sim_memory_ffi", "kept_state")
fn kept_state() -> KeptState

/// What changed between two `kept_state` readings, or "" if nothing did.
@external(erlang, "brazier_sim_memory_ffi", "describe_change")
fn describe_change(before: KeptState, after: KeptState) -> String

// ===== Resilience Tests =====

pub fn sim_malformed_frames_test() {
  let assert Ok(app) = test_app.start_counter_app()
  // Each connection gets one "Invalid message" error per malformed frame
  // and stays open: the scenario asserts all three errors, then closes.
  let run = run_measured(app, "malformed", 10, scenario.malformed(), 10)
  assert_all_clean(run)

  // The server still serves a well-behaved client afterwards.
  let verify = run_measured(app, "malformed_verify", 1, scenario.counter(1), 0)
  assert_all_clean(verify)
  stop(app)
}

// ===== Flood Test =====

pub fn sim_flood_single_connection_test() {
  // A flood well past max_events_per_second must be rate limited without
  // crashing the connection. Under the default limits a sustained flood is
  // treated as abuse and closed with 1008 (covered in ws_protocol_test), so
  // this test tolerates every violation to exercise the limiter itself.
  let limits =
    transport.SecurityLimits(
      ..test_app.sim_security_limits(),
      ws_max_rate_violations: 1_000_000,
    )
  let assert Ok(app) = test_app.start_counter_app_with_limits(limits)
  let run = run_measured(app, "flood_500", 1, scenario.flood(500), 0)
  assert_all_clean(run)
  let assert 500 = run.metrics.events_sent
  stop(app)
}

// ===== Process Leak Test =====

pub fn sim_process_leak_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let run =
    run_measured(app, "process_leak", 200, scenario.connect_disconnect(), 2)
  assert_all_clean(run)
  let assert 200 = run.result.upgraded
  stop(app)
}

// ===== Draw Simulation =====

pub fn sim_50_draw_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let run = run_measured(app, "draw_50x100", 50, scenario.draw(100), 5)
  assert_all_clean(run)
  // Mousedown, 100 moves and mouseup per connection.
  let assert 5100 = run.metrics.events_sent
  stop(app)
}

// ===== 50 Connections, Then A Fresh Client =====

pub fn sim_50_connections_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let run = run_measured(app, "counter_50x20", 50, scenario.counter(20), 5)
  assert_all_clean(run)

  let verify = run_measured(app, "counter_50_verify", 1, scenario.counter(1), 0)
  assert_all_clean(verify)
  stop(app)
}

// ===== 1000 Connections =====

pub fn sim_1000_connections_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let run = run_measured(app, "scale_1000", 1000, scenario.counter(5), 1)
  assert_all_clean(run)
  let assert 5000 = run.metrics.events_sent
  let assert 5000 = run.metrics.events_acked
  stop(app)
}

// ===== Corruption Resilience =====

pub fn sim_corrupt_data_resilience_test() {
  let assert Ok(app) = test_app.start_counter_app()
  // Every connection survives the corrupt frames: the scenario only
  // succeeds once the server acknowledges a valid event sent after them.
  let run = run_measured(app, "corrupt_data", 20, scenario.corrupt(), 10)
  assert_all_clean(run)

  let verify = run_measured(app, "corrupt_verify", 5, scenario.counter(3), 0)
  assert_all_clean(verify)
  stop(app)
}

// ===== Thundering Herd Test =====
// Five simultaneous WebSocket sessions arriving right after a burst of
// corrupt connections must all be served on their first attempt (the pool
// never retries a connect), with no HTTP 500 during the upgrade.
//
// Previously FAILED with Mist. Passes with Brazier's own transport
// (brazier/transport/server using gen_tcp directly).

pub fn thundering_herd_no_500_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let churn = run_measured(app, "herd_corrupt", 20, scenario.corrupt(), 10)
  assert_all_clean(churn)

  let herd = run_measured(app, "herd_verify", 5, scenario.counter(3), 0)
  assert_all_clean(herd)
  stop(app)
}

// ===== Patch Efficiency Test =====

pub fn sim_patch_efficiency_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let run =
    run_measured(app, "patch_efficiency", 1, scenario.patch_efficiency(10), 0)
  assert_all_clean(run)
  // The join gets the one model_sync; every event response is a patch.
  let assert 1 = run.metrics.model_syncs_received
  let assert 10 = run.metrics.patches_received
  let assert True = run.metrics.bytes_received > 0
  stop(app)
}

// ===== Reconnection Test =====

pub fn sim_reconnection_test() {
  let assert Ok(app) = test_app.start_counter_app()
  // Connect, send 5 increments, disconnect, reconnect.
  let run = run_measured(app, "reconnect", 1, scenario.reconnect(5), 0)
  assert_all_clean(run)
  let assert 2 = run.result.upgraded
  // One model_sync per join.
  let assert 2 = run.metrics.model_syncs_received
  stop(app)
}

// ===== Concurrent Mutation Test =====

pub fn sim_concurrent_mutation_test() {
  let assert Ok(app) = test_app.start_counter_app()
  // 10 connections, each sending 10 increments.
  let run =
    run_measured(app, "concurrent_mutation", 10, scenario.counter(10), 5)
  assert_all_clean(run)
  let assert 100 = run.metrics.events_sent
  let assert 100 = run.metrics.events_acked

  // Each connection gets its own runtime, so a new connection starts from
  // the initial model whatever earlier connections did.
  let verify =
    run_measured(
      app,
      "concurrent_mutation_verify",
      1,
      fresh_connection_sees(initial_count_sync),
      0,
    )
  assert_all_clean(verify)
  stop(app)
}

// ===== State Correctness Test =====

/// The model a fresh counter connection syncs: `encode_model` output,
/// embedded raw as the model_sync message's `model` value.
const initial_count_sync = "\"model\":{\"count\":0}"

fn fresh_connection_sees(expected: String) -> scenario.Scenario {
  scenario.Scenario(name: "fresh_connection", actions: [
    scenario.Connect,
    scenario.Join,
    scenario.AssertResponseContains(5000, expected),
    scenario.Disconnect,
  ])
}

pub fn sim_state_correctness_test() {
  let assert Ok(app) = test_app.start_counter_app()
  // Ten increments, each awaited before the next is sent.
  let run =
    run_measured(app, "state_correctness", 1, scenario.patch_efficiency(10), 0)
  assert_all_clean(run)
  let assert 10 = run.metrics.events_sent
  let assert 10 = run.metrics.patches_received
  // The last patch moves the model to the tenth increment. Its ops are a
  // JSON array embedded raw in the frame.
  assert_contains(
    run.metrics.last_payload,
    "\"ops\":[{\"op\":\"replace\",\"path\":\"/count\",\"value\":10}]",
  )

  // A fresh connection has its own runtime and starts from zero.
  let verify =
    run_measured(
      app,
      "state_correctness_verify",
      1,
      fresh_connection_sees(initial_count_sync),
      0,
    )
  assert_all_clean(verify)
  stop(app)
}

// ===== Patch Efficiency with Wire Assertion =====

pub fn sim_patch_efficiency_with_assertion_test() {
  let assert Ok(app) = test_app.start_counter_app()
  // 1 connection: join (gets model_sync), then 10 increments (each a patch)
  let run =
    run_measured(
      app,
      "patch_efficiency_assert",
      1,
      scenario.patch_efficiency(10),
      0,
    )
  assert_all_clean(run)
  // Wire efficiency: patches > model_syncs (the diff path is in use)
  report.assert_patch_efficiency(run.report)
  stop(app)
}

// ===== Server Push Test (effect.every) =====

pub fn sim_server_push_ticker_test() {
  let assert Ok(app) = test_app.start_ticker_app(100)
  // Join, then receive three patches the client never asked for: each
  // can only come from a timer tick.
  let run = run_measured(app, "server_push", 1, scenario.server_push(3), 0)
  assert_all_clean(run)
  let assert 0 = run.metrics.events_sent
  let assert 3 = run.metrics.patches_received
  stop(app)
}

// ===== Wire Efficiency Tracking Test =====

pub fn sim_wire_tracking_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let run = run_measured(app, "wire_tracking", 1, scenario.counter(5), 0)
  assert_all_clean(run)
  let assert True = run.metrics.bytes_sent > 0
  let assert True = run.metrics.bytes_received > 0
  // Normal SSR+client-state apps do not send HTML mount over WebSocket.
  let assert 0 = run.metrics.mounts_received
  let assert 1 = run.metrics.model_syncs_received
  stop(app)
}
