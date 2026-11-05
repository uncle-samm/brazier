//// The windows in which a node's membership could disagree with the
//// connection it is about, or one side's view of the other could differ
//// from the other side's.
////
//// A member row names the distribution connection its peer check passed
//// on, and counts only while the node is still connected over it
//// (brazier_cluster_ffi:verified/1). The manager is suspended to hold a
//// window open: it then handles no nodedown or nodeup, so its rows stay
//// as they were while the connections change under them.
////
//// Waits (brazier_cluster_ffi:await_verified/1) and mutual subscriptions
//// (subscribe_mutual/1) live in the table brazier_cluster_waiters, outside
//// the manager, so a manager restart loses none of them.

import brazier/cluster
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/cluster/relay
import brazier/presence/holder.{type Holder}
import brazier/session.{type ExternalBackend, type SessionStore, External}
import brazier/telemetry
import gleam/dynamic.{type Dynamic}
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/list

const wait_ms = 5000

/// The secret with_members starts every manager with
/// (test/brazier_peer_ffi.erl, MEMBER_SECRET): a manager restarted here
/// must pass the other members' check.
const member_secret = "brazier-test-member-secret-0123456789-abcdefghijklmnop"

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

/// A process waiting for a node to pass the check is told once, by the
/// manager that sees it pass, even when the manager it asked was killed in
/// the meantime.
pub fn a_wait_survives_a_manager_restart_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_mw_restart")
  let assert [a, b] = peers as "with_members(2) starts two peers"
  let b_node = peer.node(b)

  // B's manager answers no hello until it is resumed, so A's restarted
  // manager cannot verify B yet.
  peer.on(b, manager_suspend)
  restart_manager(a)
  assert !peer.on(a, fn() { verified(b_node) })
  let waiter = peer.on(a, fn() { spawn_verified_waiter(b_node) })
  assert peer.on(a, fn() { waiter_result(waiter, False) }) == 0
  assert peer.on(a, fn() { wait_rows(b_node) }) == 1

  // A crash: no terminate runs. The wait is kept, and the new manager
  // keeps it at init (the waiter lives and B is on the same connection).
  peer.on(a, kill_manager)
  assert peer.on(a, fn() { wait_rows(b_node) }) == 1
  start_manager(a)
  assert peer.on(a, fn() { wait_rows(b_node) }) == 1

  // B now answers both managers' hellos; the first ack verifies it.
  peer.on(b, manager_resume)
  assert peer.on(a, fn() { waiter_result(waiter, True) }) == 1
  // The notice took the row, so the second ack tells no one.
  assert peer.on(a, fn() { wait_rows(b_node) }) == 0
  peer.on(b, manager_barrier)
  peer.on(a, manager_barrier)
  assert peer.on(a, fn() { waiter_result(waiter, False) }) == 1
}

/// The manager's init drops the waits nobody can be told about: of a
/// process that died, for a connection that is no longer the node's, and
/// for a node that is not connected. A live wait on a current connection
/// is kept, and told.
pub fn init_drops_stale_waits_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_mw_prune")
  let assert [a, b] = peers as "with_members(2) starts two peers"
  let b_node = peer.node(b)
  let gone = node_named("brazier_mw_gone@nowhere")

  peer.on(b, manager_suspend)
  peer.on(a, kill_manager)
  let #(kept, stale) =
    peer.on(a, fn() {
      let id = connection_id(b_node)
      insert_wait(b_node, dead_pid(), id)
      let stale = spawn_row_waiter(b_node, id + 1)
      insert_wait(gone, stale, id)
      #(spawn_row_waiter(b_node, id), stale)
    })
  assert peer.on(a, fn() { wait_rows(b_node) }) == 3
  assert peer.on(a, fn() { wait_rows(gone) }) == 1

  start_manager(a)
  // Only the live waiter's row on B's current connection is left.
  assert peer.on(a, fn() { wait_rows(b_node) }) == 1
  assert peer.on(a, fn() { wait_rows(gone) }) == 0
  peer.on(b, manager_resume)
  assert peer.on(a, fn() { verified_count(kept, b_node, True) }) == 1
  assert peer.on(a, fn() { wait_rows(b_node) }) == 0
  peer.on(b, manager_barrier)
  peer.on(a, manager_barrier)
  assert peer.on(a, fn() { verified_count(stale, b_node, False) }) == 0
}

/// A wait for a node that is not connected is not recorded: the node can
/// never pass on a connection that does not exist. Without a manager there
/// is nothing to wait on.
pub fn a_wait_for_an_unconnected_node_leaves_no_row_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_mw_ghost")
  let assert [a] = peers as "with_members(1) starts one peer"
  let ghost_node = node_named("brazier_mw_ghost@nowhere")
  assert peer.on(a, fn() { cluster_await_verified(ghost_node) }) == Ok(Nil)
  assert peer.on(a, fn() { wait_rows(ghost_node) }) == 0
  let assert Ok(Nil) = peer.on(a, cluster.stop) as "the manager stops"
  assert peer.on(a, fn() { await_without_manager(ghost_node) })
    == Error(cluster.NotStarted)
  assert peer.on(a, fn() { wait_rows(ghost_node) }) == 0
}

/// A subscriber that died is pruned and never told; one that unsubscribes
/// leaves no row.
pub fn dead_subscribers_are_pruned_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_mw_subs")
  let assert [a] = peers as "with_members(1) starts one peer"
  peer.on(a, fn() {
    let live = spawn_mutual_recorder()
    let dead = dead_pid()
    let assert Ok(Nil) = subscribe_mutual(dead)
      as "a dead pid can be subscribed; it is pruned"
    assert subscriber_row(dead)
    let subscribers = live_subscribers()
    assert list.contains(subscribers, live)
    assert !list.contains(subscribers, dead)
    assert !subscriber_row(dead)
    assert subscriber_row(live)
    unsubscribe_mutual(live)
    assert !subscriber_row(live)
  })
}

/// A manager restarted while the connection stayed up has not verified
/// its peer, which still counts it a member. Its hello makes the peer
/// expect an ack again, and that ack tells the peer's subscribers that both
/// sides verify each other once more.
pub fn a_restarted_manager_is_mutual_again_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_mw_mutual")
  let assert [a, b] = peers as "with_members(2) starts two peers"
  let a_node = peer.node(a)
  let b_node = peer.node(b)
  let on_b = peer.on(b, spawn_mutual_recorder)
  let on_a = peer.on(a, spawn_mutual_recorder)

  restart_manager(a)
  assert peer.on(b, fn() { mutual_count(on_b, a_node, True) }) == 1
  assert peer.on(a, fn() { mutual_count(on_a, b_node, True) }) == 1
  // Once each: the restart sent one hello, B acked it once and A answered
  // that ack once.
  peer.on(a, manager_barrier)
  peer.on(b, manager_barrier)
  assert peer.on(b, fn() { mutual_count(on_b, a_node, False) }) == 1
  assert peer.on(a, fn() { mutual_count(on_a, b_node, False) }) == 1
}

/// The one-sided window: B counts A a member, A's manager is not running,
/// so A counts no one and its revocation skips B's socket. When A's
/// manager starts and the two verify each other again, B re-checks its
/// bound sessions and revokes the socket.
pub fn a_revocation_skipped_by_a_one_sided_check_is_caught_up_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_mw_onesided")
  let assert [a, b] = peers as "with_members(2) starts two peers"
  let name = "onesided"
  let a_node = peer.node(a)
  let b_node = peer.node(b)
  peer.on(a, fn() { start_db(name) })
  let store_a = start_store(a, name, a_node)
  let store_b = start_store(b, name, a_node)

  let s = peer.on(a, fn() { session.create(store_a) })
  let socket = bind_on(b, store_b, s.id)
  assert bound_seen_from(a, name, s.id, 1)
  let revoked = relay.events(b, [["brazier", "session", "revoked"]])

  let assert Ok(Nil) = peer.on(a, cluster.stop) as "a's manager stops"
  // B still counts A; A counts no one, so its revocation skips B's socket
  // (notify_revoked sends only to verified nodes).
  assert peer.on(b, fn() { verified(a_node) })
  assert !peer.on(a, fn() { verified(b_node) })
  peer.on(a, fn() { session.delete(store_a, s.id) })

  start_manager(a)
  assert revoked_on(b, socket, s.id, "deleted")
  let assert Ok(event) = relay.next_event(b, revoked, wait_ms)
    as "b's re-check emits brazier.session.revoked"
  assert telemetry.string(event, "reason") == Ok("recheck")
}

/// pg replicates group names to every connected node, where
/// pg:which_groups lists them. A binding's group is seen from the other
/// node, but neither the session id nor its binding fingerprint is in any
/// group name there.
pub fn group_names_seen_from_another_node_hold_no_session_id_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_mw_groups")
  let assert [a, b] = peers as "with_members(2) starts two peers"
  let name = "groupnames"
  let a_node = peer.node(a)
  peer.on(a, fn() { start_db(name) })
  let store_a = start_store(a, name, a_node)
  let store_b = start_store(b, name, a_node)

  let s = peer.on(a, fn() { session.create(store_a) })
  let _socket = bind_on(b, store_b, s.id)
  assert bound_seen_from(a, name, s.id, 1)

  let names = peer.on(a, group_names)
  assert list.contains(names, session_group("external:" <> name, s.id))
  assert !names_mention(names, s.id)
  assert !names_mention(names, fingerprint(s.id))
  // B's own view is the same.
  assert !names_mention(peer.on(b, group_names), s.id)
}

// --- Helpers ----------------------------------------------------------------

fn members(p: Peer) -> List(Node) {
  let assert Ok(members) = peer.on(p, cluster.members)
    as "with_members runs a manager on every peer"
  members
}

fn start_manager(p: Peer) -> Nil {
  let assert Ok(Nil) =
    peer.on(p, fn() {
      cluster.start(cluster.new(cluster.NoDiscovery), secret_key: member_secret)
    })
    as "the cluster manager starts"
  Nil
}

fn restart_manager(p: Peer) -> Nil {
  let assert Ok(Nil) = peer.on(p, cluster.stop) as "the cluster manager stops"
  start_manager(p)
}

/// A session store on `p` backed by the fake database on `db`.
fn start_store(p: Peer, name: String, db: Node) -> SessionStore {
  peer.on(p, fn() {
    // No application runs on the peer: start the session scope it would
    // own, so bindings on this node can be made and seen from here.
    session.ensure_registry()
    let ext = backend(name, db)
    let assert Ok(store) =
      owned(fn() {
        session.start_store(External(ext), session.default_store_config())
      })
      as "session.start_store succeeds"
    store
  })
}

/// A bound process standing in for a socket, and the holder on its peer
/// that spawned it and receives its revocation reports.
type Socket {
  Socket(holder: Holder, pid: Pid)
}

fn bind_on(p: Peer, store: SessionStore, id: String) -> Socket {
  peer.on(p, fn() {
    // The holder ends with the peer (see holder.gleam).
    let h = holder.start()
    let pid =
      holder.run(h, fn() {
        spawn_bound(fn() { session.bind_current_process(store, id) })
      })
    Socket(holder: h, pid:)
  })
}

/// Whether `p` sees `expected` bound processes for the session, re-checked
/// on each join and leave of its pg group.
fn bound_seen_from(p: Peer, name: String, id: String, expected: Int) -> Bool {
  let namespace = "external:" <> name
  let group = session_group(namespace, id)
  peer.until(
    p,
    peer.pg_changes("brazier_session_pg", group),
    fn() { bound_everywhere(namespace, id) == expected },
    wait_ms,
  )
}

/// Whether `socket` on `p` is told its session was revoked for `reason`.
fn revoked_on(p: Peer, socket: Socket, id: String, reason: String) -> Bool {
  peer.on(p, fn() {
    holder.run(socket.holder, fn() {
      await_revoked(socket.pid, id, reason, wait_ms)
    })
  })
  == Ok(Nil)
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

@external(erlang, "brazier_membership_window_ffi", "kill_manager")
fn kill_manager() -> Nil

@external(erlang, "brazier_membership_window_ffi", "wait_rows")
fn wait_rows(node: Node) -> Int

@external(erlang, "brazier_membership_window_ffi", "insert_wait")
fn insert_wait(node: Node, pid: Pid, connection_id: Int) -> Nil

@external(erlang, "brazier_membership_window_ffi", "dead_pid")
fn dead_pid() -> Pid

@external(erlang, "brazier_membership_window_ffi", "connection_id")
fn connection_id(node: Node) -> Int

@external(erlang, "brazier_membership_window_ffi", "spawn_mutual_recorder")
fn spawn_mutual_recorder() -> Pid

@external(erlang, "brazier_membership_window_ffi", "spawn_row_waiter")
fn spawn_row_waiter(node: Node, connection_id: Int) -> Pid

@external(erlang, "brazier_membership_window_ffi", "mutual_count")
fn mutual_count(recorder: Pid, node: Node, await: Bool) -> Int

@external(erlang, "brazier_membership_window_ffi", "verified_count")
fn verified_count(recorder: Pid, node: Node, await: Bool) -> Int

@external(erlang, "brazier_membership_window_ffi", "subscriber_row")
fn subscriber_row(pid: Pid) -> Bool

@external(erlang, "brazier_membership_window_ffi", "live_subscribers")
fn live_subscribers() -> List(Pid)

@external(erlang, "brazier_membership_window_ffi", "await_without_manager")
fn await_without_manager(node: Node) -> Result(Nil, cluster.ClusterError)

@external(erlang, "brazier_cluster_ffi", "await_verified")
fn cluster_await_verified(node: Node) -> Result(Nil, cluster.ClusterError)

@external(erlang, "brazier_cluster_ffi", "subscribe_mutual")
fn subscribe_mutual(pid: Pid) -> Result(Nil, Dynamic)

@external(erlang, "brazier_cluster_ffi", "unsubscribe_mutual")
fn unsubscribe_mutual(pid: Pid) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "manager_suspend")
fn manager_suspend() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "manager_resume")
fn manager_resume() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "manager_barrier")
fn manager_barrier() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "spawn_verified_waiter")
fn spawn_verified_waiter(node: Node) -> Pid

@external(erlang, "brazier_cluster_test_ffi", "waiter_result")
fn waiter_result(waiter: Pid, await: Bool) -> Int

@external(erlang, "brazier_session_test_ffi", "start_db")
fn start_db(name: String) -> Nil

@external(erlang, "brazier_session_test_ffi", "backend")
fn backend(name: String, db: Node) -> ExternalBackend

@external(erlang, "brazier_session_test_ffi", "owned")
fn owned(run: fn() -> a) -> a

@external(erlang, "brazier_session_test_ffi", "spawn_bound")
fn spawn_bound(bind: fn() -> Nil) -> Pid

@external(erlang, "brazier_session_test_ffi", "await_revoked")
fn await_revoked(
  pid: Pid,
  id: String,
  reason: String,
  timeout_ms: Int,
) -> Result(Nil, List(#(String, String)))

@external(erlang, "brazier_session_test_ffi", "bound_everywhere")
fn bound_everywhere(namespace: String, id: String) -> Int

@external(erlang, "brazier_session_ffi", "session_group")
fn session_group(namespace: String, id: String) -> Dynamic

@external(erlang, "brazier_session_bindings_test_ffi", "group_names")
fn group_names() -> List(Dynamic)

@external(erlang, "brazier_session_bindings_test_ffi", "names_mention")
fn names_mention(names: List(Dynamic), needle: String) -> Bool

@external(erlang, "brazier_session_bindings_test_ffi", "fingerprint")
fn fingerprint(id: String) -> String

@external(erlang, "brazier_membership_window_ffi", "node_named")
fn node_named(name: String) -> Node
