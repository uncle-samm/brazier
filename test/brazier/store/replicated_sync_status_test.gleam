//// `replicated.synced` and `replicated.context_size` on one node: a replica
//// with no peer is in sync with itself, its context counts one clock entry
//// per incarnation that wrote, and both calls report a stopped replica as
//// unavailable. `store.synced` asks the same replica and refuses a local
//// store; `[brazier, store, synced]` marks the change into sync. The
//// multi-node behaviour is in
//// cluster/store_floor_test.

import brazier/await
import brazier/monitored
import brazier/pubsub
import brazier/store
import brazier/store/replicated
import brazier/telemetry
import gleam/int
import gleam/list

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn unique(prefix: String) -> String {
  pubsub.start()
  prefix <> "_" <> int.to_string(int.absolute_value(unique_integer()))
}

pub fn a_replica_without_peers_is_synced_test() {
  let name = unique("rss_alone")
  let assert Ok(kv) =
    store.open(name, store.Replicated(replicated.default_config()))
  let assert Ok(#(srv, _table)) =
    replicated.start(replicated.KeyValue, name, replicated.default_config())
  assert replicated.synced(srv) == Ok(True)
  // A write ends "in sync" only while some peer has not seen it.
  store.put(kv, "k", 1)
  assert replicated.synced(srv) == Ok(True)
  let assert Ok(Nil) = replicated.stop(srv)
}

pub fn the_context_counts_one_entry_per_writing_incarnation_test() {
  let name = unique("rss_context")
  let assert Ok(kv) =
    store.open(name, store.Replicated(replicated.default_config()))
  let assert Ok(#(srv, _table)) =
    replicated.start(replicated.KeyValue, name, replicated.default_config())
  assert replicated.context_size(srv) == Ok(0)
  store.put(kv, "a", 1)
  store.put(kv, "b", 2)
  store.put(kv, "a", 3)
  // Three writes of one incarnation: one clock entry, counters 1..3.
  assert replicated.context_size(srv) == Ok(1)
  let assert Ok(Nil) = replicated.stop(srv)
}

pub fn a_stopped_replica_reports_sync_status_unavailable_test() {
  let name = unique("rss_stopped")
  let assert Ok(_kv) =
    store.open(name, store.Replicated(replicated.default_config()))
  let assert Ok(#(srv, _table)) =
    replicated.start(replicated.KeyValue, name, replicated.default_config())
  let assert Ok(Nil) = replicated.stop(srv)
  let assert Error(replicated.Unavailable(_)) = replicated.synced(srv)
  let assert Error(replicated.Unavailable(_)) = replicated.context_size(srv)
}

// === store.synced ===

pub fn store_synced_asks_the_replica_test() {
  let name = unique("rss_store_synced")
  let assert Ok(kv) =
    store.open(name, store.Replicated(replicated.default_config()))
  assert store.synced(kv) == Ok(True)
  store.put(kv, "k", 1)
  assert store.synced(kv) == Ok(True)
  let list_name = unique("rss_list_synced")
  let assert Ok(ls) =
    store.open_list(list_name, store.Replicated(replicated.default_config()))
  assert store.list_synced(ls) == Ok(True)
  let assert Ok(#(srv, _table)) =
    replicated.start(replicated.KeyValue, name, replicated.default_config())
  let assert Ok(Nil) = replicated.stop(srv)
  let assert Ok(#(list_srv, _table)) =
    replicated.start(replicated.List, list_name, replicated.default_config())
  let assert Ok(Nil) = replicated.stop(list_srv)
}

pub fn store_synced_of_a_local_store_is_an_error_test() {
  let name = unique("rss_local")
  let kv: store.Store(Int) = store.new(name)
  assert store.synced(kv) == Error(store.NotReplicated(topic: "store:" <> name))
  let ls: store.ListStore(Int) = store.new_list(name)
  assert store.list_synced(ls)
    == Error(store.NotReplicated(topic: "store:" <> name))
}

pub fn store_synced_of_a_stopped_replica_is_an_error_test() {
  let name = unique("rss_store_stopped")
  let assert Ok(kv) =
    store.open(name, store.Replicated(replicated.default_config()))
  let assert Ok(#(srv, _table)) =
    replicated.start(replicated.KeyValue, name, replicated.default_config())
  let assert Ok(Nil) = replicated.stop(srv)
  let assert Error(store.ReplicaFailed(replicated.Unavailable(_))) =
    store.synced(kv)
}

// === [brazier, store, synced] ===

/// A replica alone comes in sync with its 0 peers once, and emits the
/// event once: its first note of the sync state (at the latest, the write
/// below) is the change into sync, and a later write keeps it in sync.
/// The replica emits before it replies to the write, and both go from the
/// replica to this process, so after a write returns its event is already
/// in the mailbox.
pub fn a_replica_emits_synced_once_on_coming_in_sync_test() {
  let name = unique("rss_event")
  use events <- monitored.listening([["brazier", "store", "synced"]])
  let assert Ok(kv) =
    store.open(name, store.Replicated(replicated.default_config()))
  store.put(kv, "a", 1)
  let ours = fn(event: telemetry.Event) {
    telemetry.string(event, "store") == Ok(name)
  }
  let event = await.expect(events, "the synced event of " <> name, ours)
  assert telemetry.int(event, "peers") == Ok(0)
  store.put(kv, "b", 2)
  assert store.synced(kv) == Ok(True)
  assert list.filter(await.drain(events), ours) == []
  let assert Ok(#(srv, _table)) =
    replicated.start(replicated.KeyValue, name, replicated.default_config())
  let assert Ok(Nil) = replicated.stop(srv)
}
