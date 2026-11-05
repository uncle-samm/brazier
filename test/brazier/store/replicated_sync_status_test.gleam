//// `replicated.synced` and `replicated.context_size` on one node: a replica
//// with no peer is in sync with itself, its context counts one clock entry
//// per incarnation that wrote, and both calls report a stopped replica as
//// unavailable. The multi-node behaviour is in
//// cluster/store_floor_test.

import brazier/pubsub
import brazier/store
import brazier/store/replicated
import gleam/int

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
