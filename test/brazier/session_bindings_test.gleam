/// Session bindings on one node: the pg group names carry no session id,
/// and the node-local bindings table that maps them back to ids drops the
/// rows of processes that have exited. The view from another node is in
/// test/brazier/cluster/membership_window_test.gleam.
import gleam/erlang/process.{type Pid}

const session_id = "bindings-test-session-id-0123456789abcdefghijklmnopqrstuv"

/// A group name holds a hash of the id, never the id, and the hash is
/// neither the plain SHA-256 nor the binding fingerprint of the id.
pub fn a_group_name_does_not_hold_the_session_id_test() {
  let namespace = "bindings-name"
  let holder = spawn_holder()
  assert bind(namespace, session_id, holder) == 1

  let names = group_names()
  assert !names_mention(names, session_id)
  assert !names_mention(names, fingerprint(session_id))
  let key = group_key(namespace, session_id)
  assert key != plain_sha256(<<session_id:utf8>>)
  assert key != <<fingerprint(session_id):utf8>>
  stop(holder)
}

/// The same id in two namespaces gives two groups, and two ids in one
/// namespace give two groups.
pub fn group_keys_differ_by_namespace_and_id_test() {
  assert group_key("bindings-a", session_id)
    != group_key("bindings-b", session_id)
  assert group_key("bindings-a", session_id)
    != group_key("bindings-a", session_id <> "x")
  // The namespace is length-prefixed, so moving bytes from the namespace
  // to the id changes the key.
  assert group_key("bindings-ab", "c" <> session_id)
    != group_key("bindings-a", "bc" <> session_id)
}

/// The re-check reads the ids back from the bindings table: one id for
/// any number of bound processes, and none once they have all exited.
pub fn bound_sessions_come_from_the_bindings_table_test() {
  let namespace = "bindings-recheck"
  let first = spawn_holder()
  let second = spawn_holder()
  assert bind(namespace, session_id, first) == 1
  assert bind(namespace, session_id, second) == 2
  // Binding again is idempotent: no second row, no second member.
  assert bind(namespace, session_id, first) == 2
  assert binding_rows(namespace) == 2
  assert bound_sessions(namespace) == [session_id]

  stop(first)
  assert bound_sessions(namespace) == [session_id]
  assert binding_rows(namespace) == 1

  stop(second)
  assert bound_sessions(namespace) == []
  assert binding_rows(namespace) == 0
}

/// Other namespaces' bindings are neither listed nor pruned.
pub fn bound_sessions_are_per_namespace_test() {
  let holder = spawn_holder()
  assert bind("bindings-ours", session_id, holder) == 1
  assert bound_sessions("bindings-theirs") == []
  assert binding_rows("bindings-ours") == 1
  stop(holder)
  assert bound_sessions("bindings-theirs") == []
  assert binding_rows("bindings-ours") == 1
  assert bound_sessions("bindings-ours") == []
  assert binding_rows("bindings-ours") == 0
}

/// The maintenance sweep deletes the rows of exited processes even when no
/// re-check runs, and keeps the live ones.
pub fn the_sweep_prunes_ended_bindings_test() {
  let namespace = "bindings-sweep"
  let owner = start_maintenance(namespace)
  let ended = spawn_holder()
  let live = spawn_holder()
  assert bind(namespace, session_id, ended) == 1
  assert bind(namespace, session_id <> "-live", live) == 1
  assert binding_rows(namespace) == 2

  stop(ended)
  await_sweep(owner)
  assert binding_rows(namespace) == 1

  stop(live)
  await_sweep(owner)
  assert binding_rows(namespace) == 0
  stop_owner(owner)
}

// --- FFI --------------------------------------------------------------------

type GroupNames

@external(erlang, "brazier_session_bindings_test_ffi", "spawn_holder")
fn spawn_holder() -> Pid

@external(erlang, "brazier_session_bindings_test_ffi", "bind")
fn bind(namespace: String, id: String, pid: Pid) -> Int

@external(erlang, "brazier_session_bindings_test_ffi", "stop")
fn stop(pid: Pid) -> Nil

@external(erlang, "brazier_session_bindings_test_ffi", "binding_rows")
fn binding_rows(namespace: String) -> Int

@external(erlang, "brazier_session_bindings_test_ffi", "bound_sessions")
fn bound_sessions(namespace: String) -> List(String)

@external(erlang, "brazier_session_bindings_test_ffi", "group_names")
fn group_names() -> GroupNames

@external(erlang, "brazier_session_bindings_test_ffi", "names_mention")
fn names_mention(names: GroupNames, needle: String) -> Bool

@external(erlang, "brazier_session_bindings_test_ffi", "group_key")
fn group_key(namespace: String, id: String) -> BitArray

@external(erlang, "brazier_session_bindings_test_ffi", "fingerprint")
fn fingerprint(id: String) -> String

@external(erlang, "brazier_session_bindings_test_ffi", "plain_sha256")
fn plain_sha256(bytes: BitArray) -> BitArray

@external(erlang, "brazier_session_bindings_test_ffi", "start_maintenance")
fn start_maintenance(namespace: String) -> Pid

@external(erlang, "brazier_session_bindings_test_ffi", "await_sweep")
fn await_sweep(owner: Pid) -> Nil

@external(erlang, "brazier_session_bindings_test_ffi", "stop_owner")
fn stop_owner(owner: Pid) -> Nil
