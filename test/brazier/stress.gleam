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
/// Every join carries the page build (`StressConfig.build`), as a page
/// that loaded the server's `brazier_client_<hash>.js` sends it, so the
/// server checks each join's build as it does a browser's.
///
/// Usage: `gleam run -m brazier/stress` (with a server running on 8080).
import brazier/await
import brazier/debug
import brazier/log
import brazier/ssr
import brazier/static
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
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
    /// The page build every join carries: the hash in the
    /// `brazier_client_<hash>.js` the server's pages load (`page_build`
    /// for a server in this VM, `served_build` for one in another).
    build: String,
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
  let assert True =
    static.is_client_bundle_name("brazier_client_" <> config.build <> ".js")
    as "brazier/stress: the build is a bundle hash (page_build, served_build)"
  log.info(
    "brazier.stress",
    "Starting stress run: "
      <> int.to_string(config.connections)
      <> " connections x "
      <> int.to_string(config.events_per_connection)
      <> " events to "
      <> config.host
      <> ":"
      <> int.to_string(config.port)
      <> " on build "
      <> config.build,
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
      Some(config.build),
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

/// The page build of a server in this VM: the hash in the
/// `brazier_client_<hash>.js` its listener loaded (`ssr.client_bundle`),
/// which every page it renders loads and sends back with its join. An
/// `Error` naming the cause when no bundle is loaded (no server started in
/// this VM, or its last load failed).
pub fn page_build() -> Result(String, String) {
  use bundle <- result.try(
    ssr.client_bundle()
    |> result.map_error(fn(reason) {
      "brazier/stress: no page build: " <> reason
    }),
  )
  bundle_build(bundle)
}

/// The page build of the server at `host:port`, which may run in another
/// VM: the client bundle named by the `<script>` of the page it serves at
/// `/`, as a browser loads it. An `Error` naming the cause when the page
/// cannot be fetched, is not a 200, or loads no client bundle.
pub fn served_build(host: String, port: Int) -> Result(String, String) {
  use #(status_line, body) <- result.try(
    fetch_page(host, port, await.deadline_ms)
    |> result.map_error(fn(reason) {
      "brazier/stress: no page build from "
      <> host
      <> ":"
      <> int.to_string(port)
      <> ": GET / failed: "
      <> reason
    }),
  )
  page_build_in(status_line, body)
  |> result.map_error(fn(reason) {
    "brazier/stress: no page build from "
    <> host
    <> ":"
    <> int.to_string(port)
    <> ": "
    <> reason
  })
}

/// The build in a `GET /` answer: its status line must be a 200, and its
/// body must load one client bundle, `<script src="/brazier_client_<hash>.js">`
/// (the tag `ssr` renders for a live page).
@internal
pub fn page_build_in(
  status_line: String,
  body: String,
) -> Result(String, String) {
  use Nil <- result.try(case string.starts_with(status_line, "HTTP/1.1 200 ") {
    True -> Ok(Nil)
    False -> Error("GET / answered " <> string.inspect(status_line))
  })
  case string.split(body, "<script src=\"/brazier_client_") {
    [_, rest] ->
      case string.split_once(rest, "\"") {
        Ok(#(name, _)) -> bundle_build("brazier_client_" <> name)
        Error(Nil) -> Error("the page's client script tag is not closed")
      }
    [_] -> Error("the page loads no brazier_client_<hash>.js")
    _ -> Error("the page loads more than one brazier_client_<hash>.js")
  }
}

/// The hash in a bundle name, which must be exact build output
/// (`static.is_client_bundle_name`).
fn bundle_build(bundle: String) -> Result(String, String) {
  case static.is_client_bundle_name(bundle), bundle {
    True, "brazier_client_" <> rest -> Ok(string.drop_end(rest, 3))
    _, _ ->
      Error(
        "bundle "
        <> string.inspect(bundle)
        <> " is not a brazier_client_<hash>.js name",
      )
  }
}

@external(erlang, "brazier_stress_ffi", "connect_and_join")
fn connect_and_join(
  host: String,
  port: Int,
  events: Int,
  build: Option(String),
  timeout_ms: Int,
) -> Result(#(Conn, Int), String)

/// `GET /` with `Connection: close`: the status line and the body, which
/// must have a Content-Length (the listener sends one for every page).
@external(erlang, "brazier_stress_ffi", "fetch_page")
fn fetch_page(
  host: String,
  port: Int,
  timeout_ms: Int,
) -> Result(#(String, String), String)

@external(erlang, "brazier_stress_ffi", "close_handshake")
fn close_handshake(conn: Conn, timeout_ms: Int) -> Result(Nil, String)

@external(erlang, "brazier_stress_ffi", "monotonic_us")
fn monotonic_us() -> Int

/// CLI entry point. The server runs in another VM, so the build comes from
/// the page it serves. Exits non-zero when there is no build or any
/// connection failed.
pub fn main() {
  log.configure()
  let host = "localhost"
  let port = 8080
  case served_build(host, port) {
    Error(reason) -> {
      log.error("brazier.stress", reason <> "; exiting 1")
      halt(1)
    }
    Ok(build) -> {
      let result =
        run(StressConfig(
          connections: 100,
          host: host,
          port: port,
          hold_duration_ms: 1000,
          events_per_connection: 10,
          build: build,
        ))
      exit_on_failures(result)
    }
  }
}

fn exit_on_failures(result: StressResult) -> Nil {
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
