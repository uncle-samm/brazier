//// Session stores on an External backend (a fake database in ETS, see
//// brazier_session_test_ffi), backend failures, and the clock skew
//// tolerance. Multi-node behaviour is in cluster/session_cluster_test.

import brazier/cluster/log_capture
import brazier/cluster/peer
import brazier/session.{
  type ExternalBackend, type SessionStore, External, ExternalBackend,
  InvalidBackend, LocalEts, Session, SessionBackendFailed, SessionExpired,
  SessionNotFound, StoredSession,
}
import gleam/dict
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{None, Some}

fn fresh_name(prefix: String) -> String {
  prefix <> int.to_string(unique())
}

/// A new database on this node and a backend over it.
fn new_backend(prefix: String) -> #(String, ExternalBackend) {
  let name = fresh_name(prefix)
  start_db(name)
  #(name, backend(name, node.self()))
}

fn new_store(prefix: String) -> #(String, SessionStore) {
  let #(name, ext) = new_backend(prefix)
  let assert Ok(store) =
    owned(fn() {
      session.start_store(External(ext), session.default_store_config())
    })
  #(name, store)
}

fn row(id: String, created_at: Int, last_seen: Int) -> session.StoredSession {
  StoredSession(
    session: Session(id: id, data: dict.from_list([#("user", "u1")])),
    version: 0,
    created_at_ms: created_at,
    last_seen_ms: last_seen,
  )
}

fn bind(store: SessionStore, id: String) -> Pid {
  // No application runs here: start the node-wide session scope.
  session.ensure_registry()
  spawn_bound(fn() { session.bind_current_process(store, id) })
}

/// Whether a bound process recorded this revocation within the deadline
/// (delivery is a message, so it is asynchronous).
fn revoked(id: String, reason: String) -> Bool {
  peer.eventually(fn() { list.contains(revocations(), #(id, reason)) }, 5000)
}

// --- CRUD on External ---

pub fn external_create_get_set_delete_test() {
  let #(_, store) = new_store("crud")
  let s = session.create_with_data(store, dict.from_list([#("a", "1")]))
  assert session.get(store, s.id) == Some(s)
  let assert Ok(updated) = session.set(store, s, "b", "2")
  assert session.get_value(updated, "a") == Some("1")
  assert session.get_value(updated, "b") == Some("2")
  assert session.fetch(store, s.id) == Ok(updated)
  assert session.count(store) == 1
  assert session.try_delete(store, s.id) == Ok(Nil)
  assert session.get(store, s.id) == None
  assert session.fetch(store, s.id) == Error(SessionNotFound)
  assert session.count(store) == 0
  // A write never recreates a deleted session.
  assert session.set(store, s, "c", "3") == Error(SessionNotFound)
  assert session.count(store) == 0
}

pub fn external_update_applies_to_current_data_test() {
  let #(_, store) = new_store("cas")
  let s = session.create(store)
  // Two writers holding the same stale copy both keep their keys.
  let assert Ok(_) = session.set(store, s, "x", "1")
  let assert Ok(after) = session.set(store, s, "y", "2")
  assert dict.size(after.data) == 2
}

pub fn external_rotate_moves_data_and_revokes_test() {
  let #(_, store) = new_store("rotate")
  let s = session.create_with_data(store, dict.from_list([#("k", "v")]))
  let _pid = bind(store, s.id)
  let assert Ok(fresh) = session.rotate(store, s.id)
  assert fresh.id != s.id
  assert fresh.data == s.data
  assert session.get(store, s.id) == None
  assert session.get(store, fresh.id) == Some(fresh)
  assert revoked(s.id, "rotated")
  // Rotating the old id again is refused.
  assert session.rotate(store, s.id) == Error(SessionNotFound)
}

pub fn external_delete_revokes_bound_processes_test() {
  let #(_, store) = new_store("revoke")
  let s = session.create(store)
  let _pid = bind(store, s.id)
  assert session.bound_process_count(store, s.id) == 1
  session.delete(store, s.id)
  assert revoked(s.id, "deleted")
}

// --- Backend failures ---

pub fn backend_failures_are_returned_test() {
  let #(name, store) = new_store("fail")
  let s = session.create(store)
  set_failing(node.self(), name, True)
  let assert Error(SessionBackendFailed(reason)) =
    session.try_create_with_data(store, dict.new())
  assert reason == "injected failure"
  let assert Error(SessionBackendFailed(_)) = session.fetch(store, s.id)
  let assert Error(SessionBackendFailed(_)) = session.set(store, s, "k", "v")
  let assert Error(SessionBackendFailed(_)) = session.rotate(store, s.id)
  let assert Error(SessionBackendFailed(_)) = session.sweep_expired(store)
  set_failing(node.self(), name, False)
  // Nothing was lost or changed while failing.
  assert session.get(store, s.id) == Some(s)
}

pub fn failed_delete_still_revokes_test() {
  let #(name, store) = new_store("faildel")
  let s = session.create(store)
  let _pid = bind(store, s.id)
  set_failing(node.self(), name, True)
  let #(outcome, lines) =
    log_capture.capture(fn() { session.try_delete(store, s.id) })
  let assert Error(SessionBackendFailed(_)) = outcome
  set_failing(node.self(), name, False)
  // Regression (TS-8): the delete's own error line dropped the reason.
  assert log_capture.contains(
    lines,
    "error",
    "Session delete failed in external "
      <> name
      <> ": session backend failed: injected failure",
  )
  // The socket is told to close; the row survives for a retried logout.
  assert revoked(s.id, "deleted")
  assert session.count(store) == 1
}

/// The operations without an error channel crash the caller (like a
/// raising Plug.Session store) instead of pretending the session is gone.
pub fn infallible_operations_crash_on_failure_test() {
  let #(name, store) = new_store("crash")
  let s = session.create(store)
  set_failing(node.self(), name, True)
  assert raises(fn() { session.create(store) })
  assert raises(fn() { session.get(store, s.id) })
  assert raises(fn() { session.delete(store, s.id) })
  assert raises(fn() { session.count(store) })
  set_failing(node.self(), name, False)
}

pub fn unreachable_database_is_a_backend_failure_test() {
  let name = fresh_name("gone")
  // No database was started under this name.
  let ext = backend(name, node.self())
  let assert Ok(store) =
    owned(fn() {
      session.start_store(External(ext), session.default_store_config())
    })
  let assert Error(SessionBackendFailed(_)) =
    session.try_create_with_data(store, dict.new())
}

pub fn invalid_backends_are_rejected_test() {
  let #(_, ext) = new_backend("invalid")
  let config = session.default_store_config()
  let assert Error(InvalidBackend(_)) =
    session.start_store(External(ExternalBackend(..ext, name: "")), config)
  let assert Error(InvalidBackend(_)) =
    session.start_store(
      External(ext),
      session.StoreConfig(..config, idle_ttl_ms: 0),
    )
  let assert Error(InvalidBackend(_)) =
    session.start_store(
      External(ext),
      session.StoreConfig(..config, sweep_interval_ms: 0),
    )
  let assert Error(InvalidBackend(_)) =
    session.start_store(LocalEts(""), config)
}

/// A backend that returns more rows than the batch limit is refused rather
/// than letting a sweep load an unbounded result.
pub fn oversized_expired_batch_is_refused_test() {
  let #(_, ext) = new_backend("oversize")
  let flood =
    ExternalBackend(..ext, expired: fn(_, _, limit) {
      Ok(list.repeat(#("x", 0), limit + 1))
    })
  let assert Ok(store) =
    owned(fn() {
      session.start_store(External(flood), session.default_store_config())
    })
  let assert Error(SessionBackendFailed(_)) = session.sweep_expired(store)
}

// --- Expiry and clock skew ---

pub fn sweep_runs_in_batches_test() {
  let #(_, ext) = new_backend("batches")
  let assert Ok(store) =
    owned(fn() {
      session.start_store(External(ext), session.default_store_config())
    })
  let old = system_now() - session.default_absolute_ttl_ms - 1000
  int.range(from: 0, to: 2500, with: Nil, run: fn(_, i) {
    let assert Ok(True) = ext.create(row("old" <> int.to_string(i), old, old))
    Nil
  })
  let live = session.create(store)
  let _pid = bind(store, "old7")
  assert session.sweep_expired(store) == Ok(2500)
  assert session.count(store) == 1
  assert session.get(store, live.id) == Some(live)
  assert revoked("old7", "expired")
}

pub fn small_clock_skew_is_tolerated_test() {
  let #(_, ext) = new_backend("skewok")
  let assert Ok(store) =
    owned(fn() {
      session.start_store(External(ext), session.default_store_config())
    })
  // Written by a node whose clock is 3s ahead of ours.
  let ahead = system_now() + 3000
  let assert Ok(True) = ext.create(row("ahead", ahead, ahead))
  let assert Ok(s) = session.fetch(store, "ahead")
  assert session.get_value(s, "user") == Some("u1")
}

pub fn large_clock_skew_ends_the_session_test() {
  let #(_, ext) = new_backend("skewbad")
  let assert Ok(store) =
    owned(fn() {
      session.start_store(External(ext), session.default_store_config())
    })
  let far = system_now() + session.clock_skew_tolerance_ms + 5000
  let assert Ok(True) = ext.create(row("future", far, far))
  let _pid = bind(store, "future")
  let #(outcome, lines) =
    log_capture.capture(fn() { session.fetch(store, "future") })
  assert outcome == Error(SessionExpired)
  assert log_capture.contains(lines, "error", "in the future")
  // Deleted and revoked like any expired session.
  assert session.fetch(store, "future") == Error(SessionNotFound)
  assert revoked("future", "expired")
}

pub fn old_last_seen_expires_test() {
  let #(_, ext) = new_backend("idle")
  let assert Ok(store) =
    owned(fn() {
      session.start_store(External(ext), session.default_store_config())
    })
  let now = system_now()
  let idle = now - session.default_idle_ttl_ms - 1
  let assert Ok(True) = ext.create(row("idle", now - 1000, idle))
  assert session.fetch(store, "idle") == Error(SessionExpired)
}

// --- LocalEts ---

pub fn local_store_does_not_warn_when_not_distributed_test() {
  let #(_, lines) =
    log_capture.capture(fn() {
      owned(fn() { session.new_store(fresh_name("nowarn")) })
    })
  assert !log_capture.contains(lines, "warning", "LocalEts session store")
}

// --- FFI ---

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

@external(erlang, "brazier_session_test_ffi", "start_db")
fn start_db(name: String) -> Nil

@external(erlang, "brazier_session_test_ffi", "backend")
fn backend(name: String, db: Node) -> ExternalBackend

@external(erlang, "brazier_session_test_ffi", "set_failing")
fn set_failing(db: Node, name: String, failing: Bool) -> Nil

@external(erlang, "brazier_session_test_ffi", "owned")
fn owned(run: fn() -> a) -> a

@external(erlang, "brazier_session_test_ffi", "spawn_bound")
fn spawn_bound(bind: fn() -> Nil) -> Pid

@external(erlang, "brazier_session_test_ffi", "revocations")
fn revocations() -> List(#(String, String))

@external(erlang, "brazier_session_test_ffi", "raises")
fn raises(run: fn() -> a) -> Bool

@external(erlang, "brazier_session_test_ffi", "system_now")
fn system_now() -> Int
