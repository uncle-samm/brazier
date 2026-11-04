/// Wait for a sim app's server to tear down the connections a pool opened,
/// so a leak snapshot is taken after cleanup has finished instead of after
/// a sleep that is long enough on a quiet machine.
///
/// Every upgraded WebSocket connection emits `[brazier, ws, close]` once,
/// from its handler process, before it shuts down its per-connection
/// runtime. A `Watch` attached before the pool runs collects those
/// reports; `await_closed` then waits on monitors until every handler and
/// the processes linked to it (the runtime) have exited.
import brazier/application
import brazier/await
import brazier/log
import brazier/monitored
import brazier/transport/server
import gleam/erlang/process.{type Pid}
import gleam/int

pub type Watch

@external(erlang, "brazier_sim_ffi", "watch_teardown")
fn watch_ffi(conns: Pid) -> Watch

@external(erlang, "brazier_sim_ffi", "unwatch_teardown")
fn unwatch_ffi(watch: Watch) -> Nil

@external(erlang, "brazier_sim_ffi", "await_teardown")
fn await_teardown_ffi(
  watch: Watch,
  connections: Int,
  timeout_ms: Int,
) -> Result(Nil, String)

/// Run `run` with a watch on `app`'s connections. Start it before the pool
/// runs: a close that happens before the watch exists is never reported.
///
/// The watch is a node-wide telemetry handler. It is detached however
/// `run` ends, and no report of it is left in the caller's mailbox, so a
/// failing run does not leave a handler sending to eunit's shared test
/// process (ExUnit's `on_exit/1`).
pub fn watching(app: application.App, run: fn(Watch) -> a) -> a {
  case server.get_connection_owner(app.listener) {
    Ok(conns) -> watching_connections(conns, run)
    Error(Nil) ->
      panic as "teardown.watching: the app's listener has no connection owner"
  }
}

/// `watching` for the connections whose handlers `conns` started: the
/// listener's connection owner (or, in teardown_test, the test process).
pub fn watching_connections(conns: Pid, run: fn(Watch) -> a) -> a {
  let watch = watch_ffi(conns)
  use <- monitored.with_cleanup(fn() { unwatch_ffi(watch) })
  run(watch)
}

/// Wait until `connections` server connections have closed and every
/// process they reported has exited. Crashes with what is still missing
/// if that does not happen within the deadline.
pub fn await_closed(watch: Watch, connections: Int) -> Nil {
  // A 1000-connection pool under the stress gate closes in well under a
  // second; the deadline only bounds a broken teardown.
  let deadline_ms = await.deadline_ms * 4
  case await_teardown_ffi(watch, connections, deadline_ms) {
    Ok(Nil) ->
      log.debug(
        "brazier.sim.teardown",
        int.to_string(connections) <> " connections torn down",
      )
    Error(reason) -> {
      log.error("brazier.sim.teardown", reason)
      panic as { "server teardown did not finish: " <> reason }
    }
  }
}
