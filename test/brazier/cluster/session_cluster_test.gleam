//// Multi-node session tests (design test matrix, "Sessions" rows).
////
//// Stores on several peers share one External backend: a fake database
//// in ETS on one node, reached over erpc (see brazier_session_test_ffi), the
//// way every node would reach Postgres. Bound processes stand in for
//// WebSocket handlers; the transport turns the revocation message they
//// record into a 4401 close (covered by ws_protocol_test).
////
//// Nothing here polls. A bound process is spawned by a holder on its peer,
//// so it reports each revocation to that long-lived holder, which waits
//// for it (`await_revoked`); pg membership is watched with `pg:monitor/2`;
//// telemetry is relayed to a holder (brazier/cluster/relay) that receives
//// it like ExUnit's `assert_receive`.

import brazier/cluster/log_capture
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/cluster/relay
import brazier/presence/holder.{type Holder}
import brazier/session.{type ExternalBackend, type SessionStore, External}
import brazier/telemetry
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{None, Some}

const wait_ms = 5000

/// A bound process standing in for a socket, and the holder on its peer
/// that spawned it and receives its revocation reports.
pub type Socket {
  Socket(holder: Holder, pid: Pid)
}

/// Peers keep connections to the database node while a netsplit separates
/// two app nodes, as app servers keep reaching Postgres. OTP's default
/// (prevent_overlapping_partitions) would instead cut one of them off the
/// database node too.
const partial_partitions = ["-kernel", "prevent_overlapping_partitions", "false"]

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
  let group = #(atom.create("brazier_session"), namespace, id)
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

/// Regression: logout on node A closes the session's sockets on node B.
pub fn logout_on_one_node_revokes_on_another_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_sess_logout")
  let assert [a, b] = peers as "the cluster starts two peers"
  let name = "logout"
  let db = peer.node(a)
  peer.on(a, fn() { start_db(name) })
  let store_a = start_store(a, name, db)
  let store_b = start_store(b, name, db)

  let s = peer.on(a, fn() { session.create(store_a) })
  let socket = bind_on(b, store_b, s.id)
  assert bound_seen_from(a, name, s.id, 1)

  peer.on(a, fn() { session.delete(store_a, s.id) })
  assert revoked_on(b, socket, s.id, "deleted")
  assert peer.on(b, fn() { session.get(store_b, s.id) }) == None
}

/// A logout during a netsplit cannot reach the other side; when the nodes
/// reconnect, the other side re-checks its bound sessions and revokes it.
pub fn revocation_during_partition_is_enforced_on_heal_test_() -> peer.Timeout {
  use <- Timeout(90)
  use peers <- peer.with_members_args(
    3,
    "brazier_sess_split",
    partial_partitions,
  )
  let assert [a, b, c] = peers as "the cluster starts three peers"
  let name = "split"
  let db = peer.node(c)
  peer.on(c, fn() { start_db(name) })
  let store_a = start_store(a, name, db)
  let store_b = start_store(b, name, db)

  let s = peer.on(a, fn() { session.create(store_a) })
  let kept = peer.on(a, fn() { session.create(store_a) })
  let socket = bind_on(b, store_b, s.id)
  let _kept_socket = bind_on(b, store_b, kept.id)
  assert bound_seen_from(a, name, s.id, 1)
  let revoked = relay.events(b, [["brazier", "session", "revoked"]])

  peer.partition(a, b)
  // A no longer sees B's socket, so the logout cannot reach it.
  assert bound_seen_from(a, name, s.id, 0)
  peer.on(a, fn() { session.delete(store_a, s.id) })
  assert !list.contains(peer.on(b, revocations), #(s.id, "deleted"))
  // B still reaches the database throughout.
  assert peer.on(b, fn() { session.get(store_b, s.id) }) == None

  peer.heal(a, b)
  assert revoked_on(b, socket, s.id, "deleted")
  // The live session's socket is left alone.
  assert peer.on(b, fn() { session.get(store_b, kept.id) }) == Some(kept)
  assert !list.any(peer.on(b, revocations), fn(r) { r.0 == kept.id })
  // The re-check reports its revocation, once: the kept session is live.
  // The event comes after the socket is told (the re-check logs how many
  // sockets it notified, then emits), so wait for it.
  let assert Ok(event) = relay.next_event(b, revoked, wait_ms)
    as "the re-check emits brazier.session.revoked"
  assert telemetry.string(event, "reason") == Ok("recheck")
  assert telemetry.string(event, "node") == Error(Nil)
  // Only one: no second revocation was relayed behind it.
  assert relay.pending_events(b, revoked) == 0
}

/// Sessions on an External backend are the same session on every node.
pub fn external_backend_works_from_both_nodes_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_sess_shared")
  let assert [a, b] = peers as "the cluster starts two peers"
  let name = "shared"
  let db = peer.node(a)
  peer.on(a, fn() { start_db(name) })
  let store_a = start_store(a, name, db)
  let store_b = start_store(b, name, db)

  let s =
    peer.on(a, fn() {
      session.create_with_data(store_a, dict.from_list([#("user", "u1")]))
    })
  assert peer.on(b, fn() { session.get(store_b, s.id) }) == Some(s)

  let assert Ok(written) =
    peer.on(b, fn() { session.set(store_b, s, "role", "admin") })
    as "session.set succeeds"
  assert peer.on(a, fn() { session.get(store_a, s.id) }) == Some(written)

  let assert Ok(fresh) = peer.on(b, fn() { session.rotate(store_b, s.id) })
    as "session.rotate succeeds"
  assert peer.on(a, fn() { session.get(store_a, s.id) }) == None
  assert peer.on(a, fn() { session.get(store_a, fresh.id) }) == Some(fresh)
  assert peer.on(a, fn() { session.count(store_a) }) == 1

  peer.on(a, fn() { session.delete(store_a, fresh.id) })
  assert peer.on(b, fn() { session.get(store_b, fresh.id) }) == None
  assert peer.on(b, fn() { session.count(store_b) }) == 0
}

/// The database node going down is a backend failure on the others, not a
/// missing session, and the sockets stay bound.
pub fn database_node_down_is_a_backend_failure_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_sess_dbdown")
  let assert [a, b] = peers as "the cluster starts two peers"
  let name = "dbdown"
  let db = peer.node(b)
  peer.on(b, fn() { start_db(name) })
  let store_a = start_store(a, name, db)
  let s = peer.on(a, fn() { session.create(store_a) })
  peer.crash(b)
  let assert Error(session.SessionBackendFailed(_)) =
    peer.on(a, fn() { session.fetch(store_a, s.id) })
    as "session.fetch returns Error(SessionBackendFailed)"
  Nil
}

/// A LocalEts store on a distributed node logs a warning: its sessions do
/// not exist on the other nodes.
pub fn local_ets_store_warns_when_clustered_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_sess_warn")
  let assert [a] = peers as "the cluster starts one peer"
  let #(_, lines) =
    peer.on(a, fn() {
      log_capture.capture(fn() { owned(fn() { session.new_store("warned") }) })
    })
  assert log_capture.contains(lines, "warning", "LocalEts session store")
  assert log_capture.contains(lines, "warning", "sticky")
}

// --- FFI ---

@external(erlang, "brazier_session_test_ffi", "start_db")
fn start_db(name: String) -> Nil

@external(erlang, "brazier_session_test_ffi", "backend")
fn backend(name: String, db: Node) -> ExternalBackend

@external(erlang, "brazier_session_test_ffi", "owned")
fn owned(run: fn() -> a) -> a

@external(erlang, "brazier_session_test_ffi", "spawn_bound")
fn spawn_bound(bind: fn() -> Nil) -> Pid

@external(erlang, "brazier_session_test_ffi", "revocations")
fn revocations() -> List(#(String, String))

@external(erlang, "brazier_session_test_ffi", "await_revoked")
fn await_revoked(
  pid: Pid,
  id: String,
  reason: String,
  timeout_ms: Int,
) -> Result(Nil, List(#(String, String)))

@external(erlang, "brazier_session_test_ffi", "bound_everywhere")
fn bound_everywhere(namespace: String, id: String) -> Int
