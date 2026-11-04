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
import brazier/transport/server
import gleam/erlang/process.{type Pid}
import gleam/int

pub type Watch

@external(erlang, "brazier_sim_ffi", "watch_teardown")
fn watch_ffi(conns: Pid) -> Watch

@external(erlang, "brazier_sim_ffi", "await_teardown")
fn await_teardown_ffi(
  watch: Watch,
  connections: Int,
  timeout_ms: Int,
) -> Result(Nil, String)

/// Start watching `app`'s connections. Attach before the pool runs: a
/// close that happens before the watch exists is never reported.
pub fn watch(app: application.App) -> Watch {
  case server.get_connection_owner(app.listener) {
    Ok(conns) -> watch_ffi(conns)
    Error(Nil) ->
      panic as "teardown.watch: the app's listener has no connection owner"
  }
}

/// Wait until `connections` server connections have closed and every
/// process they reported has exited. Crashes with what is still missing
/// if that does not happen within the deadline. Detaches the watch.
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
