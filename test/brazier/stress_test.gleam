/// brazier/stress against a real counter app. A run proves its claims from
/// the server's answers (every event acknowledged by its patch, every close
/// echoed) and from process identity, not node-wide counts or sleeps.
import brazier/application
import brazier/await
import brazier/cluster/peer.{Timeout}
import brazier/log_capture
import brazier/sim/test_app
import brazier/ssr
import brazier/stress
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/string

fn config(port: Int, connections: Int, events: Int) -> stress.StressConfig {
  let assert Ok(build) = stress.page_build()
    as "the started app's listener loaded a client bundle"
  stress.StressConfig(
    connections: connections,
    host: "localhost",
    port: port,
    hold_duration_ms: 0,
    events_per_connection: events,
    build: build,
  )
}

pub fn stress_joins_with_the_build_its_pages_load_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let assert Ok(loaded) = ssr.client_bundle()
  let assert Ok(build) = stress.page_build()
  assert loaded == "brazier_client_" <> build <> ".js"
  // The page the server serves loads the same bundle a browser would.
  let assert Ok(served) = stress.served_build("localhost", app.port)
  assert served == build
  // Every join carries the build and the server checks it: none of them
  // warns that its page loaded no versioned client.
  let #(result, logs) =
    log_capture.capture(fn() { stress.run(config(app.port, 5, 1)) })
  let assert [] = result.failures
  let assert 5 = result.succeeded
  let assert False =
    log_capture.has(logs, level: "warning", containing: ["carries no build id"])
  let assert Ok(Nil) = application.stop(app)
}

pub fn a_join_from_another_build_is_refused_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let stale = stress.StressConfig(..config(app.port, 3, 1), build: "0123abcd")
  let result = stress.run(stale)
  let assert 3 = result.failed
  let assert 0 = result.held
  let assert True =
    list.all(result.failures, fn(reason) {
      string.contains(reason, "server closed with code 4499 stale build")
    })
    as { "stale-build failures: " <> string.inspect(result.failures) }
  let assert Ok(Nil) = application.stop(app)
}

pub fn no_page_build_without_a_loaded_bundle_test_() -> peer.Timeout {
  use <- Timeout(60)
  // A fresh node: no server started there, so no bundle was loaded.
  use peers <- peer.with_cluster(1, "brazier_stress_no_bundle")
  let assert [node] = peers
  let assert Error(reason) = peer.on(node, stress.page_build)
  assert string.contains(reason, "brazier/stress: no page build: ")
  assert string.contains(reason, "no client bundle was loaded")
}

pub fn served_build_names_why_there_is_none_test() {
  let assert Ok(app) = test_app.start_counter_app()
  let port = app.port
  let assert Ok(Nil) = application.stop(app)
  let assert Error(reason) = stress.served_build("localhost", port)
  assert string.contains(reason, "no page build from localhost:")
  assert string.contains(reason, "GET / failed: connect: econnrefused")
}

pub fn page_build_in_refuses_a_page_without_one_bundle_test() {
  let script = fn(name) { "<script src=\"/" <> name <> "\"></script>" }
  let ok = "HTTP/1.1 200 OK"
  let assert Ok("83ad8ea161fedfc0") =
    stress.page_build_in(ok, script("brazier_client_83ad8ea161fedfc0.js"))
  let assert Error(reason) =
    stress.page_build_in(
      "HTTP/1.1 404 Not Found",
      script("brazier_client_83ad8ea161fedfc0.js"),
    )
  assert reason == "GET / answered \"HTTP/1.1 404 Not Found\""
  let assert Error("the page loads no brazier_client_<hash>.js") =
    stress.page_build_in(ok, "<html><body>static error page</body></html>")
  let assert Error("the page loads more than one brazier_client_<hash>.js") =
    stress.page_build_in(
      ok,
      script("brazier_client_83ad8ea161fedfc0.js")
        <> script("brazier_client_0123abcd.js"),
    )
  let assert Error("the page's client script tag is not closed") =
    stress.page_build_in(ok, "<script src=\"/brazier_client_83ad8ea161fedfc0")
  let assert Error(reason) =
    stress.page_build_in(ok, script("brazier_client_not-hex.js"))
  assert reason
    == "bundle \"brazier_client_not-hex.js\" is not a brazier_client_<hash>.js name"
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
