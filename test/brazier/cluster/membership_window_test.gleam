//// The windows in which a node's membership could disagree with the
//// connection it is about.
////
//// A member row names the distribution connection its peer check passed
//// on, and counts only while the node is still connected over it
//// (brazier_cluster_ffi:verified/1). The manager is suspended to hold a
//// window open: it then handles no nodedown or nodeup, so its rows stay
//// as they were while the connections change under them.

import brazier/cluster
import brazier/cluster/peer.{type Peer, Timeout}
import gleam/erlang/node.{type Node}

const wait_ms = 10_000

/// The row of a verified node outlives its connection until the manager
/// handles the nodedown. Meanwhile the node is no member, and a new
/// connection to it is not one either until it passes its own check.
pub fn a_member_row_counts_only_on_its_own_connection_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_mw_conn")
  let assert [a, b] = peers as "with_members(2) starts two peers"
  let b_node = peer.node(b)
  assert peer.on(a, fn() { verified(b_node) })
  assert members(a) == [b_node]

  peer.on(a, manager_suspend)
  peer.on(a, fn() { disconnect(b_node) })
  // The manager has not handled the nodedown: the row is still there.
  assert peer.on(a, fn() { member_row(b_node) })
  assert !peer.on(a, fn() { verified(b_node) })
  assert members(a) == []

  // A new connection to the same node, before the manager ran again.
  peer.on(a, fn() { connect(b_node) })
  assert peer.on(a, fn() { member_row(b_node) })
  assert !peer.on(a, fn() { verified(b_node) })
  assert members(a) == []

  // The manager handles the nodedown and the nodeup, and checks the new
  // connection.
  peer.on(a, manager_resume)
  let assert Ok(Nil) = peer.await_member(a, b_node, wait_ms)
    as "b passes the check on its new connection"
  assert peer.on(a, fn() { verified(b_node) })
  assert members(a) == [b_node]
}

// --- Helpers ----------------------------------------------------------------

fn members(p: Peer) -> List(Node) {
  let assert Ok(members) = peer.on(p, cluster.members)
    as "with_members runs a manager on every peer"
  members
}

// --- FFI --------------------------------------------------------------------

@external(erlang, "brazier_membership_window_ffi", "member_row")
fn member_row(node: Node) -> Bool

@external(erlang, "brazier_membership_window_ffi", "verified")
fn verified(node: Node) -> Bool

@external(erlang, "brazier_membership_window_ffi", "disconnect")
fn disconnect(node: Node) -> Nil

@external(erlang, "brazier_membership_window_ffi", "connect")
fn connect(node: Node) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "manager_suspend")
fn manager_suspend() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "manager_resume")
fn manager_resume() -> Nil
