/// beacon/stress against a real counter app. A run proves its claims from
/// the server's answers (every event acknowledged by its patch, every close
/// echoed) and from process identity, not node-wide counts or sleeps.
import beacon/application
import beacon/await
import beacon/sim/test_app
import beacon/stress
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/string

fn config(port: Int, connections: Int, events: Int) -> stress.StressConfig {
  stress.StressConfig(
    connections: connections,
    host: "localhost",
    port: port,
    hold_duration_ms: 0,
    events_per_connection: events,
  )
}

pub fn stress_holds_every_connection_open_at_once_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let result = stress.run(config(app.port, 40, 0))
  let assert [] = result.failures
  let assert 40 = result.attempted
  let assert 40 = result.succeeded
  let assert 0 = result.failed
  // Every client reported held before any was released: 40 joined
  // connections were open at the same moment.
  let assert 40 = result.held
  let assert 0 = result.events_acknowledged
  let assert Ok(Nil) = application.stop(app)
}

pub fn stress_events_are_each_acknowledged_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let result = stress.run(config(app.port, 12, 8))
  let assert [] = result.failures
  let assert 12 = result.succeeded
  let assert 12 = result.held
  // 12 x 8 patches, each carrying the clock of the event it answers.
  let assert 96 = result.events_acknowledged
  let assert Ok(Nil) = application.stop(app)
}

pub fn stress_run_leaves_no_processes_behind_test() {
  let assert Ok(app) = test_app.start_counter_app()
  // One connection first starts anything created lazily on first use (the
  // node-wide per-IP slot scope), so the snapshot holds every process that
  // legitimately outlives a connection.
  let warm_up = stress.run(config(app.port, 1, 1))
  let assert [] = warm_up.failures
  let before = all_processes()
  let result = stress.run(config(app.port, 25, 2))
  let assert [] = result.failures
  let assert 25 = result.held
  let assert 50 = result.events_acknowledged
  // Handlers, runtimes and the stress clients all exit once the close
  // handshakes are done: every process started during the run goes down.
  list.each(all_processes(), fn(pid) {
    case list.contains(before, pid) {
      True -> Nil
      False -> await.expect_down(pid, "process started during the stress run")
    }
  })
  let assert Ok(Nil) = application.stop(app)
}

pub fn stress_reports_every_refused_connection_test() {
  // A port that was bound a moment ago and is now closed.
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  let assert Ok(Nil) = application.stop(app)
  let result = stress.run(config(port, 3, 1))
  let assert 3 = result.failed
  let assert 0 = result.succeeded
  let assert 0 = result.held
  let assert 0 = result.events_acknowledged
  let assert 3 = list.length(result.failures)
  let assert True =
    list.all(result.failures, fn(reason) {
      string.contains(reason, "connect: econnrefused")
    })
}

@external(erlang, "erlang", "processes")
fn all_processes() -> List(Pid)
