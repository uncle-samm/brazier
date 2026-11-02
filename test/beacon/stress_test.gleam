import beacon/sim/test_app
import beacon/stress
import gleam/erlang/process

pub fn stress_real_websocket_connections_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let config =
    stress.StressConfig(
      connections: 40,
      host: "localhost",
      port: port,
      hold_duration_ms: 150,
      events_per_connection: 0,
    )
  let result = stress.run(config)
  let assert 40 = result.attempted
  let assert 40 = result.succeeded
  let assert 0 = result.failed
  let assert True = result.duration_ms > 0
  let assert True = result.processes_during > result.processes_before
}

pub fn stress_real_websocket_processes_cleaned_up_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let config =
    stress.StressConfig(
      connections: 25,
      host: "localhost",
      port: port,
      hold_duration_ms: 100,
      events_per_connection: 0,
    )
  let result = stress.run(config)
  let assert 25 = result.succeeded
  let assert 0 = result.failed
  // After cleanup, process count should not have leaked the connection workers.
  // Allow variance for runtime and transport processes still closing.
  let assert True = result.processes_after < result.processes_before + 30
}

pub fn stress_concurrent_websocket_events_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  process.sleep(200)

  let config =
    stress.StressConfig(
      connections: 12,
      host: "localhost",
      port: port,
      hold_duration_ms: 150,
      events_per_connection: 8,
    )
  let result = stress.run(config)
  let assert 12 = result.succeeded
  let assert 0 = result.failed
  let assert 96 = result.events_attempted
  let assert True = result.duration_ms > 0
}
