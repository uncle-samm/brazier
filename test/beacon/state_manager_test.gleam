import beacon/state_manager
import gleam/erlang/process
import gleam/int

pub fn start_test() {
  let assert Ok(manager) = state_manager.start_in_memory()
  let assert 0 = state_manager.count(manager, 1000)
}

// No sleeps: `put` and `delete` are casts and `get`/`count` are calls, all
// from this process, so the actor handles them in the order they were sent.

pub fn put_and_get_test() {
  let assert Ok(manager) = state_manager.start_in_memory()
  state_manager.put(manager, "session_1", 42)
  let assert Ok(42) = state_manager.get(manager, "session_1", 1000)
}

pub fn get_nonexistent_test() {
  let assert Ok(manager) = state_manager.start_in_memory()
  let assert Error(Nil) = state_manager.get(manager, "no_such_session", 1000)
}

pub fn delete_test() {
  let assert Ok(manager) = state_manager.start_in_memory()
  state_manager.put(manager, "session_1", "data")
  state_manager.put(manager, "session_2", "kept")
  state_manager.delete(manager, "session_1")
  let assert Error(Nil) = state_manager.get(manager, "session_1", 1000)
  // Delete removes only its own session.
  let assert Ok("kept") = state_manager.get(manager, "session_2", 1000)
  let assert 1 = state_manager.count(manager, 1000)
}

pub fn count_test() {
  let assert Ok(manager) = state_manager.start_in_memory()
  let assert 0 = state_manager.count(manager, 1000)
  state_manager.put(manager, "s1", "a")
  state_manager.put(manager, "s2", "b")
  let assert 2 = state_manager.count(manager, 1000)
}

pub fn overwrite_test() {
  let assert Ok(manager) = state_manager.start_in_memory()
  state_manager.put(manager, "session_1", "old")
  state_manager.put(manager, "session_1", "new")
  let assert Ok("new") = state_manager.get(manager, "session_1", 1000)
  let assert 1 = state_manager.count(manager, 1000)
}

pub fn multiple_sessions_test() {
  let assert Ok(manager) = state_manager.start_in_memory()
  state_manager.put(manager, "s1", 100)
  state_manager.put(manager, "s2", 200)
  state_manager.put(manager, "s3", 300)
  let assert Ok(100) = state_manager.get(manager, "s1", 1000)
  let assert Ok(200) = state_manager.get(manager, "s2", 1000)
  let assert Ok(300) = state_manager.get(manager, "s3", 1000)
}

// --- ETS State Manager Tests ---

pub fn ets_start_test() {
  let manager = state_manager.start_ets("beacon_test_ets_" <> unique_id())
  let assert 0 = state_manager.ets_count(manager)
}

pub fn ets_start_twice_reuses_table_test() {
  let name = "beacon_test_ets_twice_" <> unique_id()
  let first = state_manager.start_ets(name)
  state_manager.ets_put(first, "s1", 7)
  let second = state_manager.start_ets(name)
  let assert Ok(7) = state_manager.ets_get(second, "s1")
}

pub fn try_start_ets_invalid_name_is_typed_error_test() {
  let assert Error(state_manager.InvalidTableName(_, _)) =
    state_manager.try_start_ets("not valid")
}

pub fn ets_put_and_get_test() {
  let manager = state_manager.start_ets("beacon_test_ets_pg_" <> unique_id())
  state_manager.ets_put(manager, "s1", 42)
  let assert Ok(42) = state_manager.ets_get(manager, "s1")
}

pub fn ets_get_nonexistent_test() {
  let manager = state_manager.start_ets("beacon_test_ets_ne_" <> unique_id())
  let assert Error(Nil) = state_manager.ets_get(manager, "nope")
}

pub fn ets_delete_test() {
  let manager = state_manager.start_ets("beacon_test_ets_del_" <> unique_id())
  state_manager.ets_put(manager, "s1", "data")
  state_manager.ets_delete(manager, "s1")
  let assert Error(Nil) = state_manager.ets_get(manager, "s1")
}

pub fn ets_count_test() {
  let manager = state_manager.start_ets("beacon_test_ets_cnt_" <> unique_id())
  let assert 0 = state_manager.ets_count(manager)
  state_manager.ets_put(manager, "s1", "a")
  state_manager.ets_put(manager, "s2", "b")
  let assert 2 = state_manager.ets_count(manager)
}

pub fn ets_overwrite_test() {
  let manager = state_manager.start_ets("beacon_test_ets_ow_" <> unique_id())
  state_manager.ets_put(manager, "s1", "old")
  state_manager.ets_put(manager, "s1", "new")
  let assert Ok("new") = state_manager.ets_get(manager, "s1")
  let assert 1 = state_manager.ets_count(manager)
}

pub fn ets_cross_process_access_test() {
  // ETS is accessible from any process (public table)
  let table_name = "beacon_test_ets_xp_" <> unique_id()
  let manager = state_manager.start_ets(table_name)
  state_manager.ets_put(manager, "s1", 99)
  // Read from a different process
  let subject = process.new_subject()
  let _ =
    process.spawn(fn() {
      let result = state_manager.ets_get(manager, "s1")
      process.send(subject, result)
    })
  let selector =
    process.new_selector()
    |> process.select(subject)
  let assert Ok(Ok(99)) = process.selector_receive(selector, 1000)
}

fn unique_id() -> String {
  int.to_string(erlang_unique())
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique() -> Int
