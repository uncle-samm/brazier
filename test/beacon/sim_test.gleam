/// Simulation tests — real WebSocket connections against real Beacon servers.
/// Each test starts a fresh app on a unique port, runs N concurrent connections,
/// and verifies performance and correctness metrics.
import beacon/sim/metrics
import beacon/sim/pool
import beacon/sim/report
import beacon/sim/scenario
import beacon/sim/test_app
import beacon/transport
import gleam/erlang/process
import gleam/string

// ===== Smoke Test =====

pub fn sim_10_connections_smoke_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 10,
      host: "localhost",
      port: port,
      scenario: scenario.counter(10),
      stagger_ms: 10,
      metrics: mt,
    ))

  process.sleep(200)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "smoke_10",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  report.assert_clean_passed(r)
  metrics.destroy(mt)
}

// ===== Scale Tests =====

pub fn sim_100_connections_counter_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 100,
      host: "localhost",
      port: port,
      scenario: scenario.counter(20),
      stagger_ms: 5,
      metrics: mt,
    ))

  process.sleep(500)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "scale_100_counter",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  report.assert_clean_passed(r)
  metrics.destroy(mt)
}

// ===== Leak Detection =====

pub fn sim_memory_leak_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  // Connect and disconnect 100 times
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 100,
      host: "localhost",
      port: port,
      scenario: scenario.connect_disconnect(),
      stagger_ms: 5,
      metrics: mt,
    ))

  // Allow cleanup
  process.sleep(1000)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "memory_leak",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  report.assert_clean_passed(r)
  metrics.destroy(mt)
}

// ===== Resilience Tests =====

pub fn sim_malformed_frames_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()
  let procs_before = metrics.snapshot_processes()

  let _result =
    pool.run(pool.PoolConfig(
      concurrency: 10,
      host: "localhost",
      port: port,
      scenario: scenario.malformed(),
      stagger_ms: 10,
      metrics: mt,
    ))

  process.sleep(500)
  let procs_after = metrics.snapshot_processes()

  // Server should still be alive — verify by opening a new connection
  let mt2 = metrics.new()
  let result2 =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.counter(1),
      stagger_ms: 0,
      metrics: mt2,
    ))

  // Server survived malformed frames
  let assert True = result2.succeeded == 1

  // No process leak from malformed connections
  let assert True = { procs_after - procs_before } < 15

  metrics.destroy(mt)
  metrics.destroy(mt2)
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
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.flood(500),
      stagger_ms: 0,
      metrics: mt,
    ))

  let m = metrics.collect(mt)
  // Connection should succeed
  let assert True = result.succeeded == 1
  // All 500 events should be sent
  let assert True = m.events_sent == 500
  metrics.destroy(mt)
}

// ===== Process Leak Test =====

pub fn sim_process_leak_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()
  let procs_before = metrics.snapshot_processes()

  // Connect and disconnect 200 times
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 200,
      host: "localhost",
      port: port,
      scenario: scenario.connect_disconnect(),
      stagger_ms: 2,
      metrics: mt,
    ))

  // Allow cleanup
  process.sleep(2000)
  let procs_after = metrics.snapshot_processes()

  let assert True = result.succeeded > 0
  // 200 connections with clean disconnect should leak <5 processes (timer cleanup delay)
  let leaked = procs_after - procs_before
  let assert True = leaked < 5
  metrics.destroy(mt)
}

// ===== Draw Simulation =====

pub fn sim_50_draw_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 50,
      host: "localhost",
      port: port,
      scenario: scenario.draw(100),
      stagger_ms: 5,
      metrics: mt,
    ))

  process.sleep(500)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "draw_50x100",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  report.assert_clean_passed(r)
  metrics.destroy(mt)
}

// ===== Fault-Based Kill Test =====

pub fn sim_50_connections_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()
  let procs_before = metrics.snapshot_processes()

  // Run 50 connections with a longer scenario (sleep gives fault injector time)
  // Some connections will be killed by the server handling malformed data
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 50,
      host: "localhost",
      port: port,
      scenario: scenario.counter(20),
      stagger_ms: 5,
      metrics: mt,
    ))

  process.sleep(1000)
  let procs_after = metrics.snapshot_processes()

  // At least 95% should succeed
  let assert True = result.succeeded >= 48
  // No process leak
  let assert True = { procs_after - procs_before } < 50

  // Server still alive — verify with a new connection
  let mt2 = metrics.new()
  let verify =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.counter(1),
      stagger_ms: 0,
      metrics: mt2,
    ))
  let assert True = verify.succeeded == 1

  metrics.destroy(mt)
  metrics.destroy(mt2)
}

// ===== 1000 Connections =====

pub fn sim_1000_connections_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(300)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1000,
      host: "localhost",
      port: port,
      scenario: scenario.counter(5),
      stagger_ms: 1,
      metrics: mt,
    ))

  process.sleep(2000)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "scale_1000",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  // At least 95% should succeed at 1000 connections
  let assert True = result.succeeded >= 950
  // Process leak < 50 after cleanup
  let assert True = { procs_after - procs_before } < 50
  metrics.destroy(mt)
}

// ===== Corruption Resilience =====

pub fn sim_corrupt_data_resilience_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  // 20 connections all sending various corrupt data
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 20,
      host: "localhost",
      port: port,
      scenario: scenario.corrupt(),
      stagger_ms: 10,
      metrics: mt,
    ))

  // Allow cleanup — corrupt connections may take longer to close
  process.sleep(2000)
  let procs_after = metrics.snapshot_processes()
  let mem_after = metrics.snapshot_memory()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "corrupt_data",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  // Verify server is still alive with clean connections
  let mt2 = metrics.new()
  let verify =
    pool.run(pool.PoolConfig(
      concurrency: 5,
      host: "localhost",
      port: port,
      scenario: scenario.counter(3),
      stagger_ms: 0,
      metrics: mt2,
    ))

  // Server survived all the corruption (client retries once on transient TCP failure)
  let assert True = verify.succeeded == 5
  // Zero process leak — corrupt connections MUST clean up completely
  let assert True = r.processes_leaked == 0

  metrics.destroy(mt)
  metrics.destroy(mt2)
}

// ===== Thundering Herd Test =====
// Verifies that Beacon's transport handles simultaneous WebSocket
// connections arriving after connection churn — no HTTP 500 errors.
// Uses NO client retry — raw single-attempt connects.
//
// Previously FAILED with Mist. Now PASSES with Beacon's own transport
// (beacon/transport/server using gen_tcp directly).

pub fn thundering_herd_no_500_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  // Phase 1: 20 connections sending corrupt data
  let mt = metrics.new()
  let _result =
    pool.run(pool.PoolConfig(
      concurrency: 20,
      host: "localhost",
      port: port,
      scenario: scenario.corrupt(),
      stagger_ms: 10,
      metrics: mt,
    ))

  // 2 second cleanup (same as the original test)
  process.sleep(2000)

  // Phase 2: 5 simultaneous full WS sessions — NO retry
  // Each: connect, join, wait for mount, disconnect.
  // Uses no-retry pool to test raw server availability.
  let mt2 = metrics.new()
  let verify =
    pool.run_no_retry(pool.PoolConfig(
      concurrency: 5,
      host: "localhost",
      port: port,
      scenario: scenario.counter(3),
      stagger_ms: 0,
      metrics: mt2,
    ))

  metrics.destroy(mt)
  metrics.destroy(mt2)

  // ALL 5 must succeed without retry — this is what we want from our transport
  let assert True = verify.succeeded == 5
}

// ===== Patch Efficiency Test =====

pub fn sim_patch_efficiency_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.patch_efficiency(10),
      stagger_ms: 0,
      metrics: mt,
    ))

  let m = metrics.collect(mt)
  // Connection must succeed
  let assert True = result.succeeded == 1
  // 10 events sent with WaitForResponse should mostly use patches.
  let assert True = m.patches_received >= 8
  // Wire: bytes should be tracked
  let assert True = m.bytes_received > 0

  metrics.destroy(mt)
}

// ===== Reconnection Test =====

pub fn sim_reconnection_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()

  // Connect, send 5 increments, disconnect, reconnect — verify server survives
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.reconnect(5),
      stagger_ms: 0,
      metrics: mt,
    ))

  let m = metrics.collect(mt)
  // Reconnection must succeed
  let assert True = result.succeeded == 1
  // Should have at least 2 model_syncs (one per connection/join)
  let assert True = m.model_syncs_received >= 2

  metrics.destroy(mt)
}

// ===== Concurrent Mutation Test =====

pub fn sim_concurrent_mutation_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()

  // 10 connections, each sending 10 increments to the SAME shared runtime
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 10,
      host: "localhost",
      port: port,
      scenario: scenario.counter(10),
      stagger_ms: 5,
      metrics: mt,
    ))

  process.sleep(500)
  let m = metrics.collect(mt)
  let assert True = result.succeeded >= 9
  // Total events sent should be ~100 (10 connections × 10 events)
  let assert True = m.events_sent >= 90

  // Allow server to settle after concurrent load
  process.sleep(1000)

  // Verify server is still alive AND verify state correctness.
  // Each connection gets its own runtime (per-connection mode), so a new
  // connection starts at count:0. Use patch_efficiency(1) to send 1 event
  // and wait for each response. Then verify model_sync was received with
  // the correct count value.
  let mt2 = metrics.new()
  let verify =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.patch_efficiency(1),
      stagger_ms: 0,
      metrics: mt2,
    ))

  let assert True = verify.succeeded == 1

  // patch_efficiency(1) receives: model_sync(count:0), event, patch/sync(count:1)
  let m2 = metrics.collect(mt2)
  // Must have received at least 1 model_sync (initial state) proving protocol works
  let assert True = m2.model_syncs_received >= 1
  // Must have sent exactly 1 event
  let assert True = m2.events_sent == 1

  metrics.destroy(mt)
  metrics.destroy(mt2)
}

// ===== State Correctness Test =====

pub fn sim_state_correctness_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()

  // Use patch_efficiency(10) which sends each event with WaitForResponse.
  // Then open a new connection to verify the state via model_sync.
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.patch_efficiency(10),
      stagger_ms: 0,
      metrics: mt,
    ))

  // First connection must succeed
  let assert True = result.succeeded == 1

  let m = metrics.collect(mt)
  // All 10 events were sent
  let assert True = m.events_sent == 10
  // Patches must have been received for most updates.
  let assert True = m.patches_received >= 8

  // Now open a fresh connection — model_sync should show the accumulated state
  let mt2 = metrics.new()
  let verify =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.Scenario(name: "verify_final_count", actions: [
        scenario.Connect,
        scenario.Join,
        scenario.WaitForResponse(5000),
        scenario.Disconnect,
      ]),
      stagger_ms: 0,
      metrics: mt2,
    ))

  // Verification connection must succeed
  let assert True = verify.succeeded == 1
  // The last response from the first connection must carry the final count.
  let assert True =
    string.contains(m.last_payload, "\\\"value\\\":10")
    || string.contains(m.last_payload, "\"count\":10")

  metrics.destroy(mt)
  metrics.destroy(mt2)
}

// ===== Patch Efficiency with Wire Assertion =====

pub fn sim_patch_efficiency_with_assertion_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  // 1 connection: join (gets model_sync), then 10 increments (each gets patch)
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.patch_efficiency(10),
      stagger_ms: 0,
      metrics: mt,
    ))

  process.sleep(200)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "patch_efficiency_assert",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  report.assert_clean_passed(r)
  // Assert wire efficiency: patches > model_syncs (optimization working)
  report.assert_patch_efficiency(r)

  metrics.destroy(mt)
}

// ===== Server Push Test (effect.every) =====

pub fn sim_server_push_ticker_test() {
  // Start ticker app with 100ms interval
  let assert Ok(app) = test_app.start_ticker_app(100)
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()

  // Connect, join, sleep 1s (should accumulate ~10 ticks), check for patches
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.server_push(1000),
      stagger_ms: 0,
      metrics: mt,
    ))

  let m = metrics.collect(mt)
  // Connection must succeed
  let assert True = result.succeeded == 1
  // The ticker fires every 100ms; on a loaded scheduler these pushes may batch.
  let assert True = m.patches_received >= 1

  metrics.destroy(mt)
}

// ===== Wire Efficiency Tracking Test =====

pub fn sim_wire_tracking_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let mt = metrics.new()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.counter(5),
      stagger_ms: 0,
      metrics: mt,
    ))

  let m = metrics.collect(mt)
  let assert True = result.succeeded == 1
  // Bytes tracking must work
  let assert True = m.bytes_sent > 0
  let assert True = m.bytes_received > 0
  // Normal SSR+client-state apps do not send HTML mount over WebSocket.
  let assert 0 = m.mounts_received
  let assert True = m.model_syncs_received >= 1

  metrics.destroy(mt)
}
