//// Multi-node test harness over OTP's `peer` module.
////
//// The test runner stays non-distributed. `with_cluster` starts peer nodes
//// over a standard_io control connection, connects them to each other,
//// runs the test body and always stops the peers afterwards, including
//// when the body fails or the test process is killed.
////
//// Code runs on a peer through `rpc` with a closure; peers load the same
//// compiled modules as the runner.
////
//// Waiting for a condition on a peer is `until`: one rpc on the peer
//// subscribes to whatever announces a change (a `Wake`: node up and down
//// messages, a process or pg monitor, a telemetry event, a sys hook on a
//// timer tick, a traced delivery), checks, and checks again after each
//// announcement. The
//// subscription comes first, so a change is either seen by the first check
//// or followed by a message that triggers another; this is ExUnit's
//// `assert_receive` rather than a sleep. `eventually` polls, and is only
//// for state that announces nothing. Each call site says why it polls.
////
//// PubSub, replicated stores, presence and session revocation exchange
//// messages only with verified cluster members, so a test of traffic
//// between nodes uses `with_members`: every peer runs a cluster manager
//// with one test secret, and `connect` (and `heal`) return once both
//// managers have verified the connection. `with_cluster` peers run no
//// manager, for tests of the manager itself and of unverified nodes.

import brazier/await
import brazier/monitored
import brazier/telemetry
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list

/// One peer node.
pub type Peer {
  Peer(control: Pid, node: Node, keeper: Pid)
}

/// An eunit test with a timeout in seconds: `{timeout, Seconds, Fun}`.
/// Starting nodes takes longer than eunit's default of 5 seconds.
pub type Timeout {
  Timeout(seconds: Int, test_: fn() -> Nil)
}

/// Start `count` connected peers named after `prefix`, run `run` with
/// them, and stop every peer afterwards whatever happens.
@external(erlang, "brazier_peer_ffi", "with_cluster")
pub fn with_cluster(count: Int, prefix: String, run: fn(List(Peer)) -> a) -> a

/// `with_cluster` where every peer (and every peer added later) runs a
/// cluster manager and every pair has verified each other before `run`.
@external(erlang, "brazier_peer_ffi", "with_members")
pub fn with_members(count: Int, prefix: String, run: fn(List(Peer)) -> a) -> a

/// `with_members` with extra command-line arguments for every peer.
@external(erlang, "brazier_peer_ffi", "with_members_args")
pub fn with_members_args(
  count: Int,
  prefix: String,
  args: List(String),
  run: fn(List(Peer)) -> a,
) -> a

/// `with_cluster` with peers named `name@127.0.0.1` (DNS discovery makes
/// node names from IP addresses).
@external(erlang, "brazier_peer_ffi", "with_long_name_cluster")
pub fn with_long_name_cluster(
  count: Int,
  prefix: String,
  run: fn(List(Peer)) -> a,
) -> a

/// Wait on `peer` until its cluster manager has verified `node`, for at
/// most `timeout_ms`. An error describes why it was not.
@external(erlang, "brazier_peer_ffi", "await_member")
pub fn await_member(
  peer: Peer,
  node: Node,
  timeout_ms: Int,
) -> Result(Nil, String)

/// `with_cluster` with extra command-line arguments for every peer.
@external(erlang, "brazier_peer_ffi", "with_cluster_args")
pub fn with_cluster_args(
  count: Int,
  prefix: String,
  args: List(String),
  run: fn(List(Peer)) -> a,
) -> a

/// `add_peer` with extra command-line arguments for the new peer.
@external(erlang, "brazier_peer_ffi", "add_peer_args")
pub fn add_peer_args(existing: Peer, prefix: String, args: List(String)) -> Peer

/// Start one more, unconnected, peer owned by the same cluster as
/// `existing`. Use `connect` to join it.
@external(erlang, "brazier_peer_ffi", "add_peer")
pub fn add_peer(existing: Peer, prefix: String) -> Peer

/// Run `run` on `peer` and return its result, or a description of the
/// failure (the closure raised, or the peer is gone).
pub fn rpc(peer: Peer, run: fn() -> a) -> Result(a, String) {
  rpc_ffi(peer, run, 10_000)
}

/// Run `run` on `peer`; crash the test with the reason if it fails.
pub fn on(peer: Peer, run: fn() -> a) -> a {
  on_within(peer, 10_000, run)
}

/// `on` for a closure that waits: the call gives up after `timeout_ms`
/// instead of `on`'s 10 seconds.
pub fn on_within(peer: Peer, timeout_ms: Int, run: fn() -> a) -> a {
  let outcome = rpc_ffi(peer, run, timeout_ms)
  // INVARIANT: test helper. A failed remote call means the test cannot
  // continue, so the reason is surfaced as the crash value.
  let assert Ok(value) = outcome as "the remote call on the peer failed"
  value
}

/// What wakes `until`. Called in the waiting process on the peer before
/// the first check, it arranges for that process to receive a message
/// whenever the watched state may have changed, and returns the function
/// that undoes the arrangement.
pub type Wake =
  fn() -> fn() -> Nil

/// Run `check` on `peer` until it returns True, re-running it each time
/// `wake` delivers a message, for at most `timeout_ms`. Returns whether it
/// held. The whole wait is one rpc, run in a process of its own on the
/// peer (`peer:call/5` spawns one per call), so every message that process
/// receives is a wake-up; `wake` is undone however the wait ends. Wake-ups
/// that arrive while `check` runs are taken together before the next check:
/// each announces a change made before it was sent, which that check sees.
pub fn until(
  peer: Peer,
  wake: Wake,
  check: fn() -> Bool,
  timeout_ms: Int,
) -> Bool {
  let wait = fn() {
    let undo = wake()
    use <- monitored.with_cleanup(undo)
    recheck(check, now_ms() + timeout_ms)
  }
  // INVARIANT: test helper. The rpc gets a margin over the wait, so a
  // failure here is the peer or the check crashing, which ends the test.
  let assert Ok(held) = rpc_ffi(peer, wait, timeout_ms + 5000)
    as "the wait on the peer failed"
  held
}

fn recheck(check: fn() -> Bool, deadline: Int) -> Bool {
  case check() {
    True -> True
    False -> {
      case
        process.selector_receive(any_message(), int.max(0, deadline - now_ms()))
      {
        Ok(Nil) -> {
          drain()
          recheck(check, deadline)
        }
        Error(Nil) -> False
      }
    }
  }
}

fn any_message() -> process.Selector(Nil) {
  process.new_selector() |> process.select_other(fn(_) { Nil })
}

fn drain() -> Nil {
  case process.selector_receive(any_message(), 0) {
    Ok(Nil) -> drain()
    Error(Nil) -> Nil
  }
}

/// Wake on every node that connects to or disconnects from the peer
/// (`net_kernel:monitor_nodes/1`).
pub fn node_changes() -> Wake {
  fn() {
    monitor_nodes(True)
    fn() { monitor_nodes(False) }
  }
}

/// Wake when `pid` exits (a process monitor).
pub fn process_down(pid: Pid) -> Wake {
  fn() {
    let monitor = process.monitor(pid)
    fn() { process.demonitor_process(monitor) }
  }
}

/// Wake on every join and leave of `group` in the pg scope `scope`
/// (`pg:monitor/2`, OTP 25.1). `group` is the group term itself, such as
/// a tuple.
pub fn pg_changes(scope: String, group: group) -> Wake {
  fn() {
    let ref = pg_monitor(scope, group)
    fn() { pg_demonitor(scope, ref) }
  }
}

/// Wake on every telemetry event in `names` emitted on the peer.
pub fn events(names: List(List(String))) -> Wake {
  fn() {
    let emitted = process.new_subject()
    let id = "brazier_peer_until_" <> int.to_string(unique_integer())
    let assert Ok(Nil) =
      telemetry.attach(id, names, fn(_event) { process.send(emitted, Nil) })
      as "the wake handler attaches"
    fn() {
      let assert Ok(Nil) = telemetry.detach(id) as "the wake handler detaches"
      Nil
    }
  }
}

/// Wake on every telemetry event in `names` emitted on any of `nodes`, for
/// a check that reads state on several nodes (through `on_node`). The
/// peer must be connected to each of them. If an attach fails the wait
/// fails, and the handlers already attached end with their peers, which
/// `with_cluster` always stops.
pub fn events_on(nodes: List(Node), names: List(List(String))) -> Wake {
  fn() {
    let emitted = process.new_subject()
    let id = "brazier_peer_until_" <> int.to_string(unique_integer())
    list.each(nodes, fn(n) {
      on_node(n, fn() {
        let assert Ok(Nil) =
          telemetry.attach(id, names, fn(_event) { process.send(emitted, Nil) })
          as "the wake handler attaches"
        Nil
      })
    })
    fn() {
      list.each(nodes, fn(n) {
        on_node(n, fn() {
          let assert Ok(Nil) = telemetry.detach(id)
            as "the wake handler detaches"
          Nil
        })
      })
    }
  }
}

/// Run `run` on `node` from code already running on a peer (`erpc:call/5`),
/// for a check that spans peers. A failure on `node` crashes the caller.
pub fn on_node(node: Node, run: fn() -> a) -> a {
  on_node_ffi(node, run, 10_000)
}

/// Wake on every message that arrives in `pid`'s mailbox (`erlang:trace/3`
/// with `'receive'`), for a process that is suspended or announces nothing,
/// so a check can count its queue. `check` must not send to `pid`: its own
/// messages would be traced too and wake it again. A process has at most
/// one tracer.
pub fn receives(pid: Pid) -> Wake {
  fn() {
    trace_receive(pid, True)
    fn() { trace_receive(pid, False) }
  }
}

/// Wake each time the sys-compliant process `pid` (a gen_server, such as a
/// presence shard) receives the plain atom message `message`, such as its
/// own timer tick (`await.watch_info`, the OTP sys debug hook). The hook
/// reports a message before `pid` handles it, so `check` must read the
/// state through `pid` itself (a call or `sys:get_state/1`), which `pid`
/// answers only once it has handled the message.
pub fn info(pid: Pid, message: String) -> Wake {
  fn() {
    let watch = await.watch_info(pid, message)
    fn() {
      // As in `await.with_watch_info`: the hook lives inside `pid`, so a
      // process that has exited holds none to remove.
      case process.is_alive(pid) {
        True -> await.unwatch(watch)
        False -> Nil
      }
    }
  }
}

/// Wake on any of `wakes`.
pub fn any(wakes: List(Wake)) -> Wake {
  fn() {
    let undos = list.map(wakes, fn(wake) { wake() })
    fn() { list.each(undos, fn(undo) { undo() }) }
  }
}

/// Poll `check` every 10ms until it returns True or `timeout_ms` passes.
/// Returns whether it held. Only for state that announces nothing (see the
/// module doc); prefer `until`.
pub fn eventually(check: fn() -> Bool, timeout_ms: Int) -> Bool {
  case check() {
    True -> True
    False ->
      case timeout_ms <= 0 {
        True -> False
        False -> {
          pause(10)
          eventually(check, timeout_ms - 10)
        }
      }
  }
}

/// The process registered as `name` on the node this runs on (call it
/// inside `on` for a peer's process).
@external(erlang, "brazier_peer_ffi", "registered")
pub fn registered(name: String) -> Result(Pid, Nil)

/// The peer's node.
pub fn node(peer: Peer) -> Node {
  peer.node
}

/// Halt the peer immediately (no graceful shutdown).
@external(erlang, "brazier_peer_ffi", "crash")
pub fn crash(peer: Peer) -> Nil

/// Shut the peer down gracefully (`init:stop/0`).
@external(erlang, "brazier_peer_ffi", "stop")
pub fn stop(peer: Peer) -> Nil

/// Split `a` from `b`: they disconnect and cannot reconnect until `heal`.
@external(erlang, "brazier_peer_ffi", "partition")
pub fn partition(a: Peer, b: Peer) -> Nil

/// Undo `partition` and reconnect `a` and `b` (waiting for the peer check
/// when both run a cluster manager, as `connect` does).
@external(erlang, "brazier_peer_ffi", "heal")
pub fn heal(a: Peer, b: Peer) -> Nil

/// Undo `partition` without connecting `a` and `b`.
@external(erlang, "brazier_peer_ffi", "restore")
pub fn restore(a: Peer, b: Peer) -> Nil

/// Connect peer `a` to peer `b`. When both run a cluster manager, returns
/// once each has verified the other.
@external(erlang, "brazier_peer_ffi", "connect")
pub fn connect(a: Peer, b: Peer) -> Result(Nil, String)

/// Whether the peer's control process is still running.
@external(erlang, "brazier_peer_ffi", "alive")
pub fn alive(peer: Peer) -> Bool

@external(erlang, "brazier_peer_ffi", "rpc")
fn rpc_ffi(peer: Peer, run: fn() -> a, timeout_ms: Int) -> Result(a, String)

@external(erlang, "brazier_peer_ffi", "on_node")
fn on_node_ffi(node: Node, run: fn() -> a, timeout_ms: Int) -> a

@external(erlang, "brazier_peer_ffi", "pause")
fn pause(ms: Int) -> Nil

@external(erlang, "brazier_peer_ffi", "monitor_nodes")
fn monitor_nodes(on: Bool) -> Nil

type PgRef

@external(erlang, "brazier_peer_ffi", "pg_monitor")
fn pg_monitor(scope: String, group: group) -> PgRef

@external(erlang, "brazier_peer_ffi", "pg_demonitor")
fn pg_demonitor(scope: String, ref: PgRef) -> Nil

@external(erlang, "brazier_peer_ffi", "trace_receive")
fn trace_receive(pid: Pid, on: Bool) -> Nil

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "brazier_peer_ffi", "now_ms")
fn now_ms() -> Int
