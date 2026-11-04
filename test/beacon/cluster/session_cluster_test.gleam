//// Multi-node session tests (design test matrix, "Sessions" rows).
////
//// Stores on several peers share one External backend: a fake database
//// in ETS on one node, reached over erpc (see beacon_session_test_ffi), the
//// way every node would reach Postgres. Bound processes stand in for
//// WebSocket handlers; the transport turns the revocation message they
//// record into a 4401 close (covered by ws_protocol_test).

import beacon/cluster/log_capture
import beacon/cluster/peer.{type Peer, Timeout}
import beacon/session.{type ExternalBackend, type SessionStore, External}
import gleam/dict
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{None, Some}

const wait_ms = 5000

/// A telemetry event recorded on a peer (see beacon_cluster_test_ffi).
pub type RecordedEvent {
  // The constructor name is the tag the FFI builds the tuple with.
  Event(name: String, node: String, reason: String)
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
    store
  })
}

fn bind_on(p: Peer, store: SessionStore, id: String) -> Pid {
  peer.on(p, fn() {
    spawn_bound(fn() { session.bind_current_process(store, id) })
  })
}

fn bound_seen_from(p: Peer, name: String, id: String, expected: Int) -> Bool {
  peer.eventually(
    fn() {
      peer.on(p, fn() { bound_everywhere("external:" <> name, id) }) == expected
    },
    wait_ms,
  )
}

fn revoked_on(p: Peer, id: String, reason: String) -> Bool {
  peer.eventually(
    fn() { peer.on(p, fn() { list.contains(revocations(), #(id, reason)) }) },
    wait_ms,
  )
}

/// Regression: logout on node A closes the session's sockets on node B.
pub fn logout_on_one_node_revokes_on_another_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_sess_logout")
  let assert [a, b] = peers
  let name = "logout"
  let db = peer.node(a)
  peer.on(a, fn() { start_db(name) })
  let store_a = start_store(a, name, db)
  let store_b = start_store(b, name, db)

  let s = peer.on(a, fn() { session.create(store_a) })
  let _socket = bind_on(b, store_b, s.id)
  assert bound_seen_from(a, name, s.id, 1)

  peer.on(a, fn() { session.delete(store_a, s.id) })
  assert revoked_on(b, s.id, "deleted")
  assert peer.on(b, fn() { session.get(store_b, s.id) }) == None
}

/// A logout during a netsplit cannot reach the other side; when the nodes
/// reconnect, the other side re-checks its bound sessions and revokes it.
pub fn revocation_during_partition_is_enforced_on_heal_test_() -> peer.Timeout {
  use <- Timeout(90)
  use peers <- peer.with_cluster_args(
    3,
    "beacon_sess_split",
    partial_partitions,
  )
  let assert [a, b, c] = peers
  let name = "split"
  let db = peer.node(c)
  peer.on(c, fn() { start_db(name) })
  let store_a = start_store(a, name, db)
  let store_b = start_store(b, name, db)

  let s = peer.on(a, fn() { session.create(store_a) })
  let kept = peer.on(a, fn() { session.create(store_a) })
  let _socket = bind_on(b, store_b, s.id)
  let _kept_socket = bind_on(b, store_b, kept.id)
  assert bound_seen_from(a, name, s.id, 1)
  peer.on(b, fn() { record_events([["beacon", "session", "revoked"]]) })

  peer.partition(a, b)
  // A no longer sees B's socket, so the logout cannot reach it.
  assert bound_seen_from(a, name, s.id, 0)
  peer.on(a, fn() { session.delete(store_a, s.id) })
  assert !list.contains(peer.on(b, revocations), #(s.id, "deleted"))
  // B still reaches the database throughout.
  assert peer.on(b, fn() { session.get(store_b, s.id) }) == None

  peer.heal(a, b)
  assert revoked_on(b, s.id, "deleted")
  // The live session's socket is left alone.
  assert peer.on(b, fn() { session.get(store_b, kept.id) }) == Some(kept)
  assert !list.any(peer.on(b, revocations), fn(r) { r.0 == kept.id })
  // The re-check reports its revocation, once: the kept session is live.
  // The event comes after the socket is told (the re-check logs how many
  // sockets it notified, then emits), so the socket seeing the revocation
  // does not mean the event is recorded yet: wait for it.
  assert peer.eventually(fn() { revoked_events(b) != [] }, wait_ms)
  assert revoked_events(b) == [Event("beacon.session.revoked", "", "recheck")]
}

fn revoked_events(p: Peer) -> List(RecordedEvent) {
  peer.on(p, recorded_events)
  |> list.filter(fn(e) { e.name == "beacon.session.revoked" })
}

/// Sessions on an External backend are the same session on every node.
pub fn external_backend_works_from_both_nodes_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_sess_shared")
  let assert [a, b] = peers
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
  assert peer.on(a, fn() { session.get(store_a, s.id) }) == Some(written)

  let assert Ok(fresh) = peer.on(b, fn() { session.rotate(store_b, s.id) })
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
  use peers <- peer.with_cluster(2, "beacon_sess_dbdown")
  let assert [a, b] = peers
  let name = "dbdown"
  let db = peer.node(b)
  peer.on(b, fn() { start_db(name) })
  let store_a = start_store(a, name, db)
  let s = peer.on(a, fn() { session.create(store_a) })
  peer.crash(b)
  let assert Error(session.SessionBackendFailed(_)) =
    peer.on(a, fn() { session.fetch(store_a, s.id) })
  Nil
}

/// A LocalEts store on a distributed node logs a warning: its sessions do
/// not exist on the other nodes.
pub fn local_ets_store_warns_when_clustered_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_sess_warn")
  let assert [a] = peers
  let #(_, lines) =
    peer.on(a, fn() {
      log_capture.capture(fn() { owned(fn() { session.new_store("warned") }) })
    })
  assert log_capture.contains(lines, "warning", "LocalEts session store")
  assert log_capture.contains(lines, "warning", "sticky")
}

// --- FFI ---

@external(erlang, "beacon_session_test_ffi", "start_db")
fn start_db(name: String) -> Nil

@external(erlang, "beacon_session_test_ffi", "backend")
fn backend(name: String, db: Node) -> ExternalBackend

@external(erlang, "beacon_session_test_ffi", "owned")
fn owned(run: fn() -> a) -> a

@external(erlang, "beacon_session_test_ffi", "spawn_bound")
fn spawn_bound(bind: fn() -> Nil) -> Pid

@external(erlang, "beacon_session_test_ffi", "revocations")
fn revocations() -> List(#(String, String))

@external(erlang, "beacon_cluster_test_ffi", "record_events")
fn record_events(names: List(List(String))) -> Nil

@external(erlang, "beacon_cluster_test_ffi", "recorded_events")
fn recorded_events() -> List(RecordedEvent)

@external(erlang, "beacon_session_test_ffi", "bound_everywhere")
fn bound_everywhere(namespace: String, id: String) -> Int
