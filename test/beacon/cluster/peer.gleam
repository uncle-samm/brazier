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
@external(erlang, "beacon_peer_ffi", "with_cluster")
pub fn with_cluster(count: Int, prefix: String, run: fn(List(Peer)) -> a) -> a

/// Start one more, unconnected, peer owned by the same cluster as
/// `existing`. Use `connect` to join it.
@external(erlang, "beacon_peer_ffi", "add_peer")
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
  let assert Ok(value) = outcome
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
@external(erlang, "beacon_peer_ffi", "crash")
pub fn crash(peer: Peer) -> Nil

/// Shut the peer down gracefully (`init:stop/0`).
@external(erlang, "beacon_peer_ffi", "stop")
pub fn stop(peer: Peer) -> Nil

/// Split `a` from `b`: they disconnect and cannot reconnect until `heal`.
@external(erlang, "beacon_peer_ffi", "partition")
pub fn partition(a: Peer, b: Peer) -> Nil

/// Undo `partition` and reconnect `a` and `b`.
@external(erlang, "beacon_peer_ffi", "heal")
pub fn heal(a: Peer, b: Peer) -> Nil

/// Connect peer `a` to peer `b`.
@external(erlang, "beacon_peer_ffi", "connect")
pub fn connect(a: Peer, b: Peer) -> Result(Nil, String)

/// Whether the peer's control process is still running.
@external(erlang, "beacon_peer_ffi", "alive")
pub fn alive(peer: Peer) -> Bool

@external(erlang, "beacon_peer_ffi", "rpc")
fn rpc_ffi(peer: Peer, run: fn() -> a, timeout_ms: Int) -> Result(a, String)

@external(erlang, "beacon_peer_ffi", "pause")
fn pause(ms: Int) -> Nil
