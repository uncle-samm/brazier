import beacon/state_manager
import beacon/store
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string

// --- Unhappy paths: creation errors ---

pub fn try_new_rejects_invalid_name_test() {
  let assert Error(state_manager.InvalidTableName(name:, reason: _)) =
    store.try_new("bad name!")
  let assert True = string.contains(name, "bad name!")
}

pub fn try_new_list_rejects_empty_name_test() {
  let assert Error(state_manager.InvalidTableName(_, _)) =
    store.try_new_list("")
}

pub fn try_new_rejects_overlong_name_test() {
  let assert Error(state_manager.InvalidTableName(_, reason)) =
    store.try_new(string.repeat("a", 256))
  let assert True = string.contains(reason, "too long")
}

pub fn new_with_invalid_name_crashes_loudly_test() {
  let pid = process.spawn_unlinked(fn() { store.new("no spaces allowed") })
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down.reason })
  let assert Ok(process.Abnormal(_)) = process.selector_receive(selector, 1000)
}

pub fn ensure_table_type_mismatch_is_typed_error_test() {
  let name = "beacon_test_mismatch_" <> uid()
  let assert Ok(_) = state_manager.ensure_table(name, state_manager.EtsSet)
  let assert Error(state_manager.TableTypeMismatch(
    name: found_name,
    expected: "duplicate_bag",
    found: "set",
  )) = state_manager.ensure_table(name, state_manager.EtsDuplicateBag)
  let assert True = found_name == name
}

// --- Regression: store.new crashed on the second call (named table exists) ---

pub fn store_new_twice_returns_same_store_test() {
  let name = "test_store_twice_" <> uid()
  let first = store.new(name)
  store.put(first, "k", "v")
  let second = store.new(name)
  let assert Ok("v") = store.get(second, "k")
  let assert 1 = store.count(second)
}

pub fn list_store_new_twice_returns_same_store_test() {
  let name = "test_ls_twice_" <> uid()
  let first = store.new_list(name)
  store.append(first, "room", "hello")
  let second = store.new_list(name)
  let assert ["hello"] = store.get_all(second, "room")
}

pub fn concurrent_new_list_all_share_one_table_test() {
  let name = "test_ls_concurrent_" <> uid()
  let subject = process.new_subject()
  list.each(one_to(20), fn(i) {
    process.spawn(fn() {
      let s = store.new_list(name)
      store.append(s, "k", i)
      process.send(subject, Nil)
    })
  })
  list.each(one_to(20), fn(_) {
    let assert Ok(Nil) = process.receive(subject, 2000)
  })
  let assert 20 = list.length(store.get_all(store.new_list(name), "k"))
}

pub fn store_and_list_store_with_same_name_do_not_alias_test() {
  let name = "test_alias_" <> uid()
  let kv = store.new(name)
  let ls = store.new_list(name)
  store.put(kv, "k", "kv")
  store.append(ls, "k", "ls")
  let assert Ok("kv") = store.get(kv, "k")
  let assert ["ls"] = store.get_all(ls, "k")
}

// --- Regression: tables died with the process that created them ---

pub fn store_outlives_creating_process_test() {
  let name = "test_store_owner_" <> uid()
  let ls_name = "test_ls_owner_" <> uid()
  let pid =
    process.spawn_unlinked(fn() {
      store.put(store.new(name), "k", "kept")
      store.append(store.new_list(ls_name), "k", "kept")
    })
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down.reason })
  let assert Ok(process.Normal) = process.selector_receive(selector, 1000)
  let assert Ok("kept") = store.get(store.new(name), "k")
  let assert ["kept"] = store.get_all(store.new_list(ls_name), "k")
}

// --- Regression: ListStore was an ETS bag, which dropped duplicate messages ---

pub fn list_store_keeps_duplicate_values_test() {
  let s = store.new_list("test_ls_dupes_" <> uid())
  store.append(s, "room", "hi")
  store.append(s, "room", "hi")
  store.append_many(s, "room", ["hi", "bye", "hi"])
  let assert ["hi", "hi", "hi", "bye", "hi"] = store.get_all(s, "room")
}

pub fn list_store_preserves_insertion_order_test() {
  let s = store.new_list("test_ls_order_" <> uid())
  list.each(one_to(50), fn(i) { store.append(s, "k", i) })
  let assert True = store.get_all(s, "k") == one_to(50)
}

// --- Happy paths ---

pub fn store_put_and_get_test() {
  let s = store.new("test_store_" <> uid())
  store.put(s, "key1", "value1")
  let assert Ok("value1") = store.get(s, "key1")
}

pub fn store_get_missing_test() {
  let s = store.new("test_store_miss_" <> uid())
  let assert Error(Nil) = store.get(s, "nope")
}

pub fn store_delete_test() {
  let s = store.new("test_store_del_" <> uid())
  store.put(s, "k", "v")
  store.delete(s, "k")
  let assert Error(Nil) = store.get(s, "k")
}

pub fn store_count_test() {
  let s = store.new("test_store_cnt_" <> uid())
  let assert 0 = store.count(s)
  store.put(s, "a", "1")
  store.put(s, "b", "2")
  let assert 2 = store.count(s)
}

pub fn list_store_append_and_get_all_test() {
  let s = store.new_list("test_ls_" <> uid())
  store.append(s, "room1", "msg_a")
  store.append(s, "room1", "msg_b")
  store.append(s, "room1", "msg_c")
  let msgs = store.get_all(s, "room1")
  let assert 3 = list_length(msgs)
}

pub fn list_store_different_keys_test() {
  let s = store.new_list("test_ls_keys_" <> uid())
  store.append(s, "general", "hello")
  store.append(s, "random", "world")
  let assert 1 = list_length(store.get_all(s, "general"))
  let assert 1 = list_length(store.get_all(s, "random"))
}

pub fn list_store_empty_key_test() {
  let s = store.new_list("test_ls_empty_" <> uid())
  let assert [] = store.get_all(s, "empty")
}

pub fn list_store_delete_all_test() {
  let s = store.new_list("test_ls_delall_" <> uid())
  store.append(s, "k", "a")
  store.append(s, "k", "b")
  store.delete_all(s, "k")
  let assert [] = store.get_all(s, "k")
}

/// [1, 2, ..., n]
fn one_to(n: Int) -> List(Int) {
  int.range(from: n, to: 0, with: [], run: fn(acc, i) { [i, ..acc] })
}

fn uid() -> String {
  int.to_string(erlang_unique())
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique() -> Int

fn list_length(l: List(a)) -> Int {
  do_list_length(l, 0)
}

fn do_list_length(l: List(a), acc: Int) -> Int {
  case l {
    [] -> acc
    [_, ..rest] -> do_list_length(rest, acc + 1)
  }
}
