//// The replicated store on one node: the AWLWWMap (beacon/store/crdt),
//// the hybrid logical clock (beacon/store/hlc), and beacon/store opened
//// with mode Replicated (limits, errors, telemetry, notifications).
//// Multi-node behaviour is in cluster/store_cluster_test.

import beacon/cluster/peer
import beacon/pubsub
import beacon/store
import beacon/store/crdt.{type Delta, type State, Replica}
import beacon/store/hlc.{Timestamp}
import beacon/store/replicated.{Config}
import beacon/telemetry.{type Event}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string

// --- CRDT ---------------------------------------------------------------

const ra = Replica(node: "a@host", incarnation: 1)

const rb = Replica(node: "b@host", incarnation: 1)

fn ts(wall: Int, node: String) -> hlc.Timestamp {
  Timestamp(wall_ms: wall, logical: 0, node: node)
}

fn put(
  state: State(v),
  replica: crdt.Replica,
  key: String,
  value: v,
  at: hlc.Timestamp,
) -> #(State(v), Delta(v)) {
  let #(next, delta, _changes) = crdt.put(state, replica, key, value, at, [])
  #(next, delta)
}

fn join(state: State(v), delta: Delta(v)) -> State(v) {
  crdt.join(state, delta).0
}

pub fn crdt_last_write_wins_on_one_replica_test() {
  let #(s1, _) = put(crdt.new(), ra, "k", 1, ts(10, ra.node))
  let #(s2, _) = put(s1, ra, "k", 2, ts(20, ra.node))
  assert crdt.value(s2, "k") == Ok(2)
  // The second put replaced the first value's dot.
  assert crdt.size(s2) == 1
  assert crdt.value(s2, "missing") == Error(Nil)
}

pub fn crdt_concurrent_puts_resolve_the_same_in_either_join_order_test() {
  let #(sa, da) = put(crdt.new(), ra, "k", "from a", ts(10, ra.node))
  let #(sb, db) = put(crdt.new(), rb, "k", "from b", ts(10, rb.node))
  let ab = join(sa, db)
  let ba = join(sb, da)
  // Same wall time and logical counter: the node name breaks the tie.
  assert crdt.value(ab, "k") == Ok("from b")
  assert crdt.value(ba, "k") == Ok("from b")
  assert crdt.fingerprint(ab) == crdt.fingerprint(ba)
  // Both concurrent values stay until a write that observed them.
  assert crdt.size(ab) == 2
  let #(after, _) = put(ab, ra, "k", "resolved", ts(11, ra.node))
  assert crdt.size(after) == 1
  assert crdt.value(after, "k") == Ok("resolved")
}

pub fn crdt_later_timestamp_wins_regardless_of_node_test() {
  let #(sa, da) = put(crdt.new(), ra, "k", "late a", ts(20, ra.node))
  let #(sb, db) = put(crdt.new(), rb, "k", "early b", ts(10, rb.node))
  assert crdt.value(join(sa, db), "k") == Ok("late a")
  assert crdt.value(join(sb, da), "k") == Ok("late a")
}

pub fn crdt_remove_only_removes_observed_values_add_wins_test() {
  // Both replicas see v0, then a removes it while b concurrently writes v1.
  let #(sa, d0) = put(crdt.new(), ra, "k", "v0", ts(10, ra.node))
  let sb = join(crdt.new(), d0)
  let #(sa, removal, _) = crdt.remove(sa, "k", [])
  assert crdt.value(sa, "k") == Error(Nil)
  let #(sb, write) = put(sb, rb, "k", "v1", ts(11, rb.node))
  let sa = join(sa, write)
  let sb = join(sb, removal)
  assert crdt.value(sa, "k") == Ok("v1")
  assert crdt.value(sb, "k") == Ok("v1")
  assert crdt.fingerprint(sa) == crdt.fingerprint(sb)
}

pub fn crdt_remove_of_a_value_seen_everywhere_removes_it_everywhere_test() {
  let #(sa, d0) = put(crdt.new(), ra, "k", "v0", ts(10, ra.node))
  let sb = join(crdt.new(), d0)
  let #(sa, removal, changes) = crdt.remove(sa, "k", ["room:k"])
  let assert [crdt.Removed(key: "k", dot: _, entry: _)] = changes
  let #(sb, changes) = crdt.join(sb, removal)
  let assert [crdt.Removed(key: "k", dot: _, entry: _)] = changes
  assert crdt.value(sb, "k") == Error(Nil)
  assert crdt.size(sa) == 0
  assert crdt.size(sb) == 0
}

pub fn crdt_join_is_idempotent_and_commutative_test() {
  let #(s, d1) = put(crdt.new(), ra, "x", 1, ts(10, ra.node))
  let #(_, d2) = put(s, ra, "y", 2, ts(11, ra.node))
  let #(_, d3) = put(crdt.new(), rb, "x", 3, ts(12, rb.node))
  let forward = crdt.new() |> join(d1) |> join(d2) |> join(d3)
  let backward = crdt.new() |> join(d3) |> join(d2) |> join(d1)
  let twice = forward |> join(d1) |> join(d2) |> join(d3)
  assert crdt.fingerprint(forward) == crdt.fingerprint(backward)
  assert crdt.fingerprint(forward) == crdt.fingerprint(twice)
  assert crdt.value(forward, "x") == Ok(3)
  assert crdt.value(backward, "y") == Ok(2)
  // A repeated delta changes nothing.
  let #(_, changes) = crdt.join(forward, d1)
  assert changes == []
}

pub fn crdt_append_keeps_every_value_in_timestamp_order_test() {
  let #(sa, da, changes) =
    crdt.append(
      crdt.new(),
      ra,
      "room",
      [#("first", ts(5, ra.node)), #("third", ts(7, ra.node))],
      [],
    )
  assert list.length(changes) == 2
  let #(_, db, _) =
    crdt.append(crdt.new(), rb, "room", [#("second", ts(6, rb.node))], [])
  let merged_a = join(sa, db)
  let merged_b = join(crdt.new(), db) |> join(da)
  assert crdt.values(merged_a, "room") == ["first", "second", "third"]
  assert crdt.values(merged_b, "room") == ["first", "second", "third"]
  assert crdt.size(merged_a) == 3
}

pub fn crdt_join_full_removes_keys_deleted_since_test() {
  let #(sa, _) = put(crdt.new(), ra, "gone", 1, ts(10, ra.node))
  let #(sa, _) = put(sa, ra, "kept", 2, ts(11, ra.node))
  let sb = crdt.join_full(crdt.new(), crdt.to_delta(sa)).0
  assert crdt.value(sb, "gone") == Ok(1)
  let #(sa, _, _) = crdt.remove(sa, "gone", [])
  // The full state no longer names the key: only join_full can see that
  // its dot is covered by the sender's context and drop it.
  assert crdt.value(join(sb, crdt.to_delta(sa)), "gone") == Ok(1)
  let #(sb, changes) = crdt.join_full(sb, crdt.to_delta(sa))
  let assert [crdt.Removed(key: "gone", dot: _, entry: _)] = changes
  assert crdt.value(sb, "gone") == Error(Nil)
  assert crdt.value(sb, "kept") == Ok(2)
  assert crdt.fingerprint(sb) == crdt.fingerprint(sa)
}

pub fn crdt_context_compacts_deltas_received_out_of_order_test() {
  let #(s1, d1) = put(crdt.new(), ra, "a", 1, ts(1, ra.node))
  let #(s2, d2) = put(s1, ra, "b", 2, ts(2, ra.node))
  let #(_, d3) = put(s2, ra, "c", 3, ts(3, ra.node))
  let partial = join(crdt.new(), d3)
  let #(_, clock, cloud) = crdt.fingerprint(partial)
  // Dot 3 alone cannot extend the clock, so it waits in the cloud.
  assert clock == []
  assert cloud == [crdt.Dot(replica: ra, counter: 3)]
  assert !crdt.covers(partial.context, crdt.Dot(replica: ra, counter: 2))
  let complete = partial |> join(d1) |> join(d2)
  let #(_, clock, cloud) = crdt.fingerprint(complete)
  assert clock == [#(ra, 3)]
  assert cloud == []
  assert crdt.values(complete, "c") == [3]
}

pub fn crdt_dots_order_by_node_then_incarnation_then_counter_test() {
  let newer = Replica(node: "a@host", incarnation: 2)
  assert crdt.compare_dots(crdt.Dot(ra, 9), crdt.Dot(newer, 1)) == order.Lt
  assert crdt.compare_dots(crdt.Dot(newer, 1), crdt.Dot(rb, 1)) == order.Lt
  assert crdt.compare_dots(crdt.Dot(ra, 1), crdt.Dot(ra, 2)) == order.Lt
}

// --- HLC ----------------------------------------------------------------

pub fn hlc_tick_is_monotonic_when_the_wall_clock_steps_back_test() {
  let t1 = hlc.tick(hlc.zero("a"), 100)
  assert t1 == Timestamp(wall_ms: 100, logical: 0, node: "a")
  let t2 = hlc.tick(t1, 50)
  assert t2 == Timestamp(wall_ms: 100, logical: 1, node: "a")
  assert hlc.compare(t2, t1) == order.Gt
  let t3 = hlc.tick(t2, 200)
  assert t3 == Timestamp(wall_ms: 200, logical: 0, node: "a")
}

pub fn hlc_observe_is_ahead_of_both_clocks_test() {
  let last = Timestamp(wall_ms: 100, logical: 3, node: "a")
  let remote = Timestamp(wall_ms: 150, logical: 2, node: "b")
  let merged = hlc.observe(last, remote, 120)
  assert merged == Timestamp(wall_ms: 150, logical: 3, node: "a")
  assert hlc.compare(merged, last) == order.Gt
  assert hlc.compare(merged, remote) == order.Gt
  // Equal walls ahead of the wall clock: the larger counter plus one.
  let same = Timestamp(wall_ms: 100, logical: 5, node: "b")
  assert hlc.observe(last, same, 50)
    == Timestamp(wall_ms: 100, logical: 6, node: "a")
  // The wall clock ahead of both resets the counter.
  assert hlc.observe(last, remote, 500)
    == Timestamp(wall_ms: 500, logical: 0, node: "a")
}

pub fn hlc_orders_by_wall_then_logical_then_node_test() {
  let a = Timestamp(wall_ms: 1, logical: 0, node: "a")
  let b = Timestamp(wall_ms: 1, logical: 0, node: "b")
  assert hlc.compare(a, b) == order.Lt
  assert hlc.max(a, b) == b
  assert hlc.compare(Timestamp(2, 0, "a"), Timestamp(1, 9, "z")) == order.Gt
  assert hlc.drift_ms(Timestamp(1500, 0, "a"), 1000) == 500
  assert hlc.drift_ms(Timestamp(500, 0, "a"), 1000) == 0
  assert hlc.to_string(Timestamp(7, 2, "n@h")) == "7.2@n@h"
}

// --- One node -----------------------------------------------------------

fn unique(prefix: String) -> String {
  pubsub.start()
  prefix <> "_" <> int.to_string(unique_integer())
}

fn config() -> replicated.Config {
  replicated.default_config()
}

fn server(kind: replicated.Kind, name: String, cfg: replicated.Config) {
  let assert Ok(#(server, _table)) = replicated.start(kind, name, cfg)
  server
}

fn stop(kind: replicated.Kind, name: String, cfg: replicated.Config) -> Nil {
  let assert Ok(Nil) = replicated.stop(server(kind, name, cfg))
  Nil
}

pub fn replicated_key_value_store_reads_its_writes_test() {
  let name = unique("rs_basic")
  let assert Ok(kv) = store.open(name, store.Replicated(config()))
  assert store.get(kv, "a") == Error(Nil)
  store.put(kv, "a", 1)
  store.put(kv, "b", 2)
  store.put(kv, "a", 3)
  assert store.get(kv, "a") == Ok(3)
  assert store.count(kv) == 2
  store.delete(kv, "a")
  assert store.get(kv, "a") == Error(Nil)
  assert store.count(kv) == 1
  // Deleting a key that was never written is not an error.
  assert store.try_delete(kv, "never") == Ok(Nil)
  assert store.topic(kv) == "store:" <> name
  stop(replicated.KeyValue, name, config())
}

pub fn replicated_list_store_keeps_append_order_test() {
  let name = unique("rs_list")
  let assert Ok(messages) = store.open_list(name, store.Replicated(config()))
  store.append(messages, "room", "hi")
  store.append_many(messages, "room", ["a", "b", "c"])
  store.append_notify(messages, "other", "x", "room:")
  assert store.get_all(messages, "room") == ["hi", "a", "b", "c"]
  assert store.get_all(messages, "other") == ["x"]
  store.delete_all(messages, "room")
  assert store.get_all(messages, "room") == []
  store.delete_all_notify(messages, "other", "room:")
  assert store.get_all(messages, "other") == []
  stop(replicated.List, name, config())
}

pub fn opening_twice_with_the_same_config_returns_the_same_store_test() {
  let name = unique("rs_reopen")
  let assert Ok(first) = store.open(name, store.Replicated(config()))
  store.put(first, "k", "v")
  let assert Ok(second) = store.open(name, store.Replicated(config()))
  assert store.get(second, "k") == Ok("v")
  let other = Config(..config(), max_entries: 10)
  let assert Error(store.InvalidConfig(reason)) =
    store.open(name, store.Replicated(other))
  assert string.contains(reason, "different configuration")
  stop(replicated.KeyValue, name, config())
}

pub fn a_local_store_cannot_be_reopened_as_replicated_test() {
  let name = unique("rs_local_first")
  let local: store.Store(Int) = store.new(name)
  store.put(local, "k", 1)
  let assert Error(store.InvalidConfig(reason)) =
    store.open(name, store.Replicated(config()))
  assert string.contains(reason, "local mode")
  let list_name = unique("rs_local_list_first")
  let local_list: store.ListStore(Int) = store.new_list(list_name)
  store.append(local_list, "k", 1)
  let assert Error(store.InvalidConfig(_)) =
    store.open_list(list_name, store.Replicated(config()))
}

pub fn a_replicated_store_cannot_be_reopened_as_local_test() {
  let name = unique("rs_replicated_first")
  let assert Ok(_) = store.open(name, store.Replicated(config()))
  let assert Error(store.InvalidStore(_)) = store.open(name, store.Local)
  let assert Error(_) = store.try_new(name)
  stop(replicated.KeyValue, name, config())
  let list_name = unique("rs_replicated_list_first")
  let assert Ok(_) = store.open_list(list_name, store.Replicated(config()))
  let assert Error(store.InvalidStore(_)) =
    store.open_list(list_name, store.Local)
  stop(replicated.List, list_name, config())
}

pub fn invalid_names_are_rejected_test() {
  pubsub.start()
  let assert Error(store.InvalidStore(_)) =
    store.open("has space", store.Replicated(config()))
  let assert Error(store.InvalidStore(_)) =
    store.open("", store.Replicated(config()))
  let assert Error(store.InvalidStore(_)) =
    store.open(string.repeat("n", 201), store.Replicated(config()))
  let assert Error(store.InvalidStore(_)) =
    store.open_list("bad:name", store.Replicated(config()))
}

pub fn invalid_configs_are_rejected_test() {
  let name = unique("rs_bad_config")
  let bad = [
    Config(..config(), sync_interval_ms: 0),
    Config(..config(), sync_interval_ms: 3_600_001),
    Config(..config(), max_entries: 0),
    Config(..config(), max_entries: 10_000_001),
    Config(..config(), max_value_bytes: 0),
    Config(..config(), max_value_bytes: 2048, max_delta_bytes: 2048),
    Config(..config(), max_delta_bytes: 4096, max_sync_bytes: 4095),
    Config(..config(), max_sync_bytes: 1_073_741_825),
  ]
  list.each(bad, fn(cfg) {
    let assert Error(store.InvalidConfig(_)) =
      store.open(name, store.Replicated(cfg))
    let assert Error(replicated.InvalidConfig(_)) =
      replicated.validate_config(cfg)
  })
  let assert Ok(_) = replicated.validate_config(config())
  // Nothing was started by the rejected opens.
  let assert Error(_) = replica_pid(name)
}

pub fn writes_past_max_entries_are_rejected_test() {
  let name = unique("rs_full")
  let cfg = Config(..config(), max_entries: 2)
  let assert Ok(kv) = store.open(name, store.Replicated(cfg))
  assert store.try_put(kv, "a", 1) == Ok(Nil)
  assert store.try_put(kv, "b", 2) == Ok(Nil)
  assert store.try_put(kv, "c", 3) == Error(replicated.TooManyEntries(2))
  assert store.get(kv, "c") == Error(Nil)
  // Overwriting does not grow the store.
  assert store.try_put(kv, "a", 10) == Ok(Nil)
  assert store.get(kv, "a") == Ok(10)
  // Deleting frees room.
  assert store.try_delete(kv, "b") == Ok(Nil)
  assert store.try_put(kv, "c", 3) == Ok(Nil)
  assert store.count(kv) == 2
  stop(replicated.KeyValue, name, cfg)
}

pub fn values_past_max_value_bytes_are_rejected_test() {
  let name = unique("rs_big_value")
  let cfg = Config(..config(), max_value_bytes: 100)
  let assert Ok(kv) = store.open(name, store.Replicated(cfg))
  let assert Error(replicated.ValueTooLarge(bytes:, limit: 100)) =
    store.try_put(kv, "k", string.repeat("x", 200))
  assert bytes > 200
  assert store.get(kv, "k") == Error(Nil)
  assert store.try_put(kv, "k", "small") == Ok(Nil)
  stop(replicated.KeyValue, name, cfg)
}

pub fn deltas_past_max_delta_bytes_are_rejected_whole_test() {
  let name = unique("rs_big_delta")
  let cfg = Config(..config(), max_value_bytes: 100, max_delta_bytes: 400)
  let assert Ok(messages) = store.open_list(name, store.Replicated(cfg))
  // Every value fits, but together they are one delta that does not.
  let values = list.repeat(string.repeat("v", 50), 20)
  let assert Error(replicated.DeltaTooLarge(bytes:, limit: 400)) =
    store.try_append_many(messages, "room", values)
  assert bytes > 400
  assert store.get_all(messages, "room") == []
  assert store.try_append(messages, "room", "one") == Ok(Nil)
  assert store.get_all(messages, "room") == ["one"]
  stop(replicated.List, name, cfg)
}

pub fn an_invalid_per_key_topic_writes_nothing_test() {
  let name = unique("rs_bad_topic")
  let assert Ok(messages) = store.open_list(name, store.Replicated(config()))
  let long_key = string.repeat("k", 300)
  let assert Error(replicated.InvalidTopic(_)) =
    store.try_append_notify(messages, long_key, "v", "room:")
  assert store.get_all(messages, long_key) == []
  stop(replicated.List, name, config())
}

pub fn writes_to_a_stopped_replica_are_unavailable_test() {
  let name = unique("rs_stopped")
  let assert Ok(kv) = store.open(name, store.Replicated(config()))
  store.put(kv, "k", 1)
  let assert Ok(#(srv, table)) =
    replicated.start(replicated.KeyValue, name, config())
  let assert Ok(Nil) = replicated.stop(srv)
  let assert Error(replicated.Unavailable(_)) = store.try_put(kv, "k", 2)
  let assert Error(replicated.Unavailable(_)) = replicated.digest(srv)
  // The mirror went with the replica: a read reports it, not "missing".
  let assert Error("replica not running") = replicated.get(table, "k")
  let assert Error(_) = replicated.stop(srv)
}

pub fn replicated_writes_emit_store_write_with_mode_replicated_test() {
  let name = unique("rs_telemetry")
  let assert Ok(kv) = store.open(name, store.Replicated(config()))
  let #(id, events) = listen()
  store.put(kv, "a", "small")
  store.delete(kv, "a")
  // A rejected write is not reported as a write.
  let assert Error(_) = store.try_put(kv, "big", string.repeat("x", 70 * 1024))
  assert drain(events)
    == [#(name, "put", "replicated", 1), #(name, "delete", "replicated", 1)]
  let assert Ok(Nil) = telemetry.detach(id)
  stop(replicated.KeyValue, name, config())
}

pub fn replicated_writes_notify_local_watchers_test() {
  let name = unique("rs_notify")
  let assert Ok(messages) = store.open_list(name, store.Replicated(config()))
  let store_watcher = spawn_recorder(["store:" <> name])
  let key_watcher = spawn_recorder(["room:general"])
  store.append_notify(messages, "general", "hi", "room:")
  store.append(messages, "general", "again")
  assert wait_for(store_watcher, 2)
  assert wait_for(key_watcher, 1)
  stop(replicated.List, name, config())
}

pub fn replica_digest_and_size_describe_its_state_test() {
  let name = unique("rs_digest")
  let assert Ok(kv) = store.open(name, store.Replicated(config()))
  let srv = server(replicated.KeyValue, name, config())
  let assert Ok(empty) = replicated.digest(srv)
  store.put(kv, "k", 1)
  let assert Ok(one) = replicated.digest(srv)
  assert empty != one
  assert replicated.digest(srv) == Ok(one)
  assert replicated.size(srv) == Ok(1)
  assert replicated.get(table_of(name), "k") == Ok(Some(1))
  assert replicated.get(table_of(name), "other") == Ok(None)
  stop(replicated.KeyValue, name, config())
}

fn table_of(name: String) {
  let assert Ok(#(_, table)) =
    replicated.start(replicated.KeyValue, name, config())
  table
}

// --- Helpers ------------------------------------------------------------

const write_event = ["beacon", "store", "write"]

fn listen() -> #(String, Subject(Event)) {
  let assert Ok(Nil) = telemetry.start()
  let id = "store_replicated_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let owner = process.self()
  let assert Ok(Nil) =
    telemetry.attach(id, [write_event], fn(event) {
      case process.self() == owner {
        True -> process.send(events, event)
        False -> Nil
      }
    })
  #(id, events)
}

fn drain(events: Subject(Event)) -> List(#(String, String, String, Int)) {
  drain_loop(events, [])
}

fn drain_loop(
  events: Subject(Event),
  acc: List(#(String, String, String, Int)),
) -> List(#(String, String, String, Int)) {
  case process.receive(events, 0) {
    Error(Nil) -> list.reverse(acc)
    Ok(event) -> {
      let assert Ok(name) = telemetry.string(event, "store")
      let assert Ok(op) = telemetry.string(event, "op")
      let assert Ok(mode) = telemetry.string(event, "mode")
      let assert Ok(count) = telemetry.int(event, "count")
      drain_loop(events, [#(name, op, mode, count), ..acc])
    }
  }
}

/// Whether `recorder` receives `count` deliveries within 5 seconds.
fn wait_for(recorder: Pid, count: Int) -> Bool {
  peer.eventually(fn() { recorded_count(recorder) == count }, 5000)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "beacon_store_test_ffi", "replica_pid")
fn replica_pid(name: String) -> Result(Pid, Nil)

@external(erlang, "beacon_cluster_test_ffi", "spawn_recorder")
fn spawn_recorder(topics: List(String)) -> Pid

@external(erlang, "beacon_cluster_test_ffi", "recorded_count")
fn recorded_count(recorder: Pid) -> Int
