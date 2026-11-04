//// Multi-node test harness over OTP's `peer` module.
////
//// The test runner stays non-distributed. `with_cluster` starts peer nodes
//// over a standard_io control connection, connects them to each other,
//// runs the test body and always stops the peers afterwards, including
//// when the body fails or the test process is killed.
////
//// Code runs on a peer through `rpc` with a closure; peers load the same
//// compiled modules as the runner. Use `eventually` to wait for a
//// condition, never a fixed sleep.
////
//// PubSub, replicated stores, presence and session revocation exchange
//// messages only with verified cluster members, so a test of traffic
//// between nodes uses `with_members`: every peer runs a cluster manager
//// with one test secret, and `connect` (and `heal`) return once both
//// managers have verified the connection. `with_cluster` peers run no
//// manager, for tests of the manager itself and of unverified nodes.

import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}

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
  let outcome = rpc(peer, run)
  // INVARIANT: test helper. A failed remote call means the test cannot
  // continue, so the reason is surfaced as the crash value.
  let assert Ok(value) = outcome as "the remote call on the peer failed"
  value
}

/// Poll `check` every 10ms until it returns True or `timeout_ms` passes.
/// Returns whether it held.
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

@external(erlang, "brazier_peer_ffi", "pause")
fn pause(ms: Int) -> Nil
