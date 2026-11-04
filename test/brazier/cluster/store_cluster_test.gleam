//// Multi-node replicated store tests (brazier/store with mode Replicated).
////
//// Every node opens the same store with a fast anti-entropy period
//// (100ms). Two replicas have converged when their digests (a hash of the
//// whole CRDT state) are equal; waiting is always `peer.eventually` with a
//// deadline.

import brazier/cluster/peer.{type Peer, Timeout}
import brazier/pubsub
import brazier/store
import brazier/store/replicated.{Config}
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/string

const wait_ms = 10_000

const name = "rsc"

// --- Helpers ----------------------------------------------------------------

fn fast() -> replicated.Config {
  Config(..replicated.default_config(), sync_interval_ms: 100)
}

/// Open the store on `p` without keeping the handle (every node's handle
/// is the same).
fn start_on(p: Peer, cfg: replicated.Config) -> Nil {
  let kv = open_on(p, cfg)
  assert store.topic(kv) == "store:" <> name
}

fn open_on(p: Peer, cfg: replicated.Config) -> store.Store(String) {
  peer.on(p, fn() {
    pubsub.start()
    let assert Ok(kv) = store.open(name, store.Replicated(cfg))
      as "store.open succeeds"
    kv
  })
}

fn open_all(peers: List(Peer)) -> store.Store(String) {
  let stores = list.map(peers, open_on(_, fast()))
  // INVARIANT: every node builds the same handle (registered names) for
  // the same store name and kind.
  let assert [kv, ..] = stores as "stores returns a non-empty list"
  kv
}

fn open_list_on(p: Peer) -> store.ListStore(String) {
  peer.on(p, fn() {
    pubsub.start()
    let assert Ok(messages) = store.open_list(name, store.Replicated(fast()))
      as "store.open_list succeeds"
    messages
  })
}

fn put_on(p: Peer, kv: store.Store(String), key: String, value: String) -> Nil {
  peer.on(p, fn() { store.put(kv, key, value) })
}

fn delete_on(p: Peer, kv: store.Store(String), key: String) -> Nil {
  peer.on(p, fn() { store.delete(kv, key) })
}

fn get_on(
  p: Peer,
  kv: store.Store(String),
  key: String,
) -> Result(String, Nil) {
  peer.on(p, fn() { store.get(kv, key) })
}

fn count_on(p: Peer, kv: store.Store(String)) -> Int {
  peer.on(p, fn() { store.count(kv) })
}

/// The digest of the replica on `p` (opened with `cfg`), or Error while it
/// is down.
fn digest_on(
  p: Peer,
  kind: replicated.Kind,
  cfg: replicated.Config,
) -> Result(BitArray, Nil) {
  peer.on(p, fn() {
    let assert Ok(#(server, _table)) = replicated.start(kind, name, cfg)
      as "replicated.start succeeds"
    case replicated.digest(server) {
      Ok(digest) -> Ok(digest)
      Error(_) -> Error(Nil)
    }
  })
}

fn converged(peers: List(Peer), kind: replicated.Kind) -> Bool {
  case list.map(peers, digest_on(_, kind, fast())) {
    [Ok(first), ..rest] -> list.all(rest, fn(d) { d == Ok(first) })
    _ -> False
  }
}

fn sees(p: Peer, kv: store.Store(String), key: String, value: String) -> Bool {
  peer.eventually(fn() { get_on(p, kv, key) == Ok(value) }, wait_ms)
}

fn lacks(p: Peer, kv: store.Store(String), key: String) -> Bool {
  peer.eventually(fn() { get_on(p, kv, key) == Error(Nil) }, wait_ms)
}

fn node_name(p: Peer) -> String {
  atom.to_string(node.name(peer.node(p)))
}

/// Run `run` on every peer at once (so no write observes another node's
/// writes first) and wait for all of them.
fn in_parallel(peers: List(Peer), run: fn(Peer) -> Nil) -> Nil {
  let done: Subject(Nil) = process.new_subject()
  list.each(peers, fn(p) {
    process.spawn(fn() {
      run(p)
      process.send(done, Nil)
    })
  })
  list.each(peers, fn(_) {
    let assert Ok(Nil) = process.receive(done, wait_ms)
      as "process.receive succeeds"
  })
}

/// `[1, 2, ..., n]`.
fn seq(n: Int) -> List(Int) {
  int.range(from: n, to: 0, with: [], run: list.prepend)
}

// --- Convergence ------------------------------------------------------------

/// Concurrent writes to the same key and to distinct keys on three nodes
/// converge to the same state, with the same last-writer winner everywhere.
pub fn concurrent_writes_converge_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(3, "brazier_rs_conc")
  let kv = open_all(peers)
  in_parallel(peers, fn(p) {
    let me = node_name(p)
    peer.on(p, fn() {
      list.each(seq(50), fn(i) {
        store.put(kv, "shared", me <> ":" <> int.to_string(i))
        store.put(kv, me <> ":" <> int.to_string(i), "v")
      })
    })
  })

  assert peer.eventually(
    fn() { converged(peers, replicated.KeyValue) },
    wait_ms,
  )
  let winners = list.map(peers, get_on(_, kv, "shared"))
  let assert [Ok(winner), ..] = winners as "winners returns a non-empty list"
  assert list.all(winners, fn(w) { w == Ok(winner) })
  assert string.ends_with(winner, ":50")
  assert list.all(peers, fn(p) { count_on(p, kv) == 151 })
}

/// Concurrent appends on three nodes list the same values in the same
/// (timestamp) order on every node.
pub fn concurrent_appends_converge_in_one_order_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(3, "brazier_rs_app")
  let lists = list.map(peers, open_list_on)
  let assert [messages, ..] = lists as "every peer opened a list store"
  in_parallel(peers, fn(p) {
    let me = node_name(p)
    peer.on(p, fn() {
      list.each(seq(20), fn(i) {
        store.append(messages, "room", me <> ":" <> int.to_string(i))
      })
    })
  })

  assert peer.eventually(fn() { converged(peers, replicated.List) }, wait_ms)
  let views =
    list.map(peers, fn(p) {
      peer.on(p, fn() { store.get_all(messages, "room") })
    })
  let assert [first, ..] = views as "views returns a non-empty list"
  assert list.length(first) == 60
  assert list.all(views, fn(view) { view == first })
  // Each node's own appends keep their order.
  let assert [a, ..] = peers as "the cluster starts at least one peer"
  let mine =
    list.filter(first, fn(v) { string.starts_with(v, node_name(a) <> ":") })
  assert mine
    == list.map(seq(20), fn(i) { node_name(a) <> ":" <> int.to_string(i) })
}

// --- Partitions -------------------------------------------------------------

/// During a netsplit each side keeps writing and sees only its own writes;
/// after it heals both sides converge, including deletes made during the
/// split.
pub fn partition_heal_converges_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_rs_split")
  let assert [a, b] = peers as "the cluster starts two peers"
  let kv = open_all(peers)
  put_on(a, kv, "k", "before")
  put_on(b, kv, "gone", "x")
  assert sees(b, kv, "k", "before")
  assert sees(a, kv, "gone", "x")

  peer.partition(a, b)
  put_on(a, kv, "only_a", "a")
  put_on(b, kv, "only_b", "b")
  put_on(a, kv, "k", "a side")
  delete_on(a, kv, "gone")
  assert get_on(b, kv, "only_a") == Error(Nil)
  assert get_on(a, kv, "only_b") == Error(Nil)
  assert get_on(b, kv, "gone") == Ok("x")
  put_on(b, kv, "k", "b side")

  peer.heal(a, b)
  assert peer.eventually(
    fn() { converged(peers, replicated.KeyValue) },
    wait_ms,
  )
  assert sees(a, kv, "only_b", "b")
  assert sees(b, kv, "only_a", "a")
  assert lacks(b, kv, "gone")
  let assert Ok(winner) = get_on(a, kv, "k") as "get_on succeeds"
  assert get_on(b, kv, "k") == Ok(winner)
  assert winner == "a side" || winner == "b side"
}

/// A delete concurrent with a write to the same key loses: the write that
/// the deleting node never saw survives on every node (add wins).
pub fn delete_loses_to_a_concurrent_write_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_rs_addwins")
  let assert [a, b] = peers as "the cluster starts two peers"
  let kv = open_all(peers)
  let lists = list.map(peers, open_list_on)
  let assert [messages, ..] = lists as "every peer opened a list store"
  put_on(a, kv, "k", "v0")
  peer.on(a, fn() { store.append(messages, "room", "old") })
  assert sees(b, kv, "k", "v0")
  assert peer.eventually(
    fn() { peer.on(b, fn() { store.get_all(messages, "room") }) == ["old"] },
    wait_ms,
  )

  peer.partition(a, b)
  delete_on(a, kv, "k")
  peer.on(a, fn() { store.delete_all(messages, "room") })
  put_on(b, kv, "k", "v1")
  peer.on(b, fn() { store.append(messages, "room", "new") })
  assert get_on(a, kv, "k") == Error(Nil)

  peer.heal(a, b)
  assert peer.eventually(
    fn() { converged(peers, replicated.KeyValue) },
    wait_ms,
  )
  assert peer.eventually(fn() { converged(peers, replicated.List) }, wait_ms)
  assert get_on(a, kv, "k") == Ok("v1")
  assert get_on(b, kv, "k") == Ok("v1")
  // The delete removed the value it saw; the concurrent append survives.
  list.each(peers, fn(p) {
    assert peer.on(p, fn() { store.get_all(messages, "room") }) == ["new"]
  })
}

// --- Crashes and rejoins ----------------------------------------------------

/// A node that crashes loses nothing it replicated; a new node that joins
/// later pulls the whole state, including deletes made after the crash.
pub fn new_node_gets_a_full_sync_after_a_crash_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(3, "brazier_rs_crash")
  let assert [a, b, c] = peers as "the cluster starts three peers"
  let kv = open_all(peers)
  put_on(a, kv, "from_a", "a")
  put_on(b, kv, "from_b", "b")
  put_on(c, kv, "from_c", "c")
  put_on(c, kv, "c_deleted", "c")
  assert peer.eventually(
    fn() { converged(peers, replicated.KeyValue) },
    wait_ms,
  )

  peer.crash(c)
  put_on(a, kv, "after_crash", "a")
  delete_on(b, kv, "c_deleted")
  let d = peer.add_peer(a, "brazier_rs_crash_d")
  start_on(d, fast())
  assert get_on(d, kv, "from_c") == Error(Nil)
  let assert Ok(Nil) = peer.connect(d, a) as "peer.connect succeeds"

  let survivors = [a, b, d]
  assert peer.eventually(
    fn() { converged(survivors, replicated.KeyValue) },
    wait_ms,
  )
  assert get_on(d, kv, "from_a") == Ok("a")
  assert get_on(d, kv, "from_b") == Ok("b")
  assert get_on(d, kv, "from_c") == Ok("c")
  assert get_on(d, kv, "after_crash") == Ok("a")
  assert get_on(d, kv, "c_deleted") == Error(Nil)
  assert count_on(d, kv) == 4
}

/// A replica process that crashes is restarted by its supervisor as a new
/// incarnation with an empty state, and pulls its peers' state back.
pub fn restarted_replica_resyncs_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_rs_restart")
  let assert [a, b] = peers as "the cluster starts two peers"
  let kv = open_all(peers)
  put_on(a, kv, "k1", "a")
  put_on(b, kv, "k2", "b")
  assert peer.eventually(
    fn() { converged(peers, replicated.KeyValue) },
    wait_ms,
  )

  let old = peer.on(b, fn() { kill_replica(name) })
  assert peer.eventually(
    fn() {
      case peer.on(b, fn() { replica_pid(name) }) {
        Ok(pid) -> pid != old
        Error(Nil) -> False
      }
    },
    wait_ms,
  )
  assert peer.eventually(
    fn() { converged(peers, replicated.KeyValue) },
    wait_ms,
  )
  // Its own write before the crash came back from a.
  assert get_on(b, kv, "k2") == Ok("b")
  assert get_on(b, kv, "k1") == Ok("a")
  // The new incarnation writes again, and a sees it.
  put_on(b, kv, "k3", "after restart")
  assert sees(a, kv, "k3", "after restart")
}

// --- Limits -----------------------------------------------------------------

/// A replica refuses remote deltas and full states larger than its limits,
/// and remote writes that would grow it past max_entries; each refusal is
/// still reported as a [brazier, store, sync] span.
pub fn remote_merges_past_the_limits_are_refused_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_rs_limits")
  let assert [a, b] = peers as "the cluster starts two peers"
  let kv = open_on(a, fast())
  let small =
    Config(
      ..fast(),
      max_entries: 3,
      max_value_bytes: 1000,
      max_delta_bytes: 2000,
      max_sync_bytes: 4000,
    )
  start_on(b, small)
  peer.on(b, record_syncs)
  // b's PubSub started inside start_on, and pg tells a about b's forwarding
  // worker asynchronously (not ordered with start_on's reply). Until a lists
  // it, a's deltas skip b, and b refuses every full sync here, so no write
  // may run before then.
  let b_node = peer.node(b)
  assert peer.eventually(
    fn() { peer.on(a, fn() { remote_worker_nodes(0) }) == [b_node] },
    wait_ms,
  )

  // Larger than b's delta and sync limits: never merged on b.
  put_on(a, kv, "big", string.repeat("x", 5000))
  put_on(a, kv, "s1", "1")
  put_on(a, kv, "s2", "2")
  put_on(a, kv, "s3", "3")
  // b holds s1..s3 (3 entries): s4 would be the fourth.
  put_on(a, kv, "s4", "4")
  // A removal shrinks b, so it merges; it arrives after s4's delta.
  delete_on(a, kv, "s1")
  // a's deltas reach b in write order (one sender, one forwarding shard),
  // so s3 present with s1 gone means every delta above was merged or
  // refused. A merge span cannot mark that point: a's reply to b's startup
  // sync_req carries no entries either, like the removal's delta.
  let from_a = node_name(a)
  assert peer.eventually(
    fn() { get_on(b, kv, "s3") == Ok("3") && get_on(b, kv, "s1") == Error(Nil) },
    wait_ms,
  )
  assert list.any(peer.on(b, recorded_syncs), fn(sync) {
    sync.1 == from_a && sync.2 == 0
  })
  assert get_on(b, kv, "s1") == Error(Nil)
  assert get_on(b, kv, "s2") == Ok("2")
  assert get_on(b, kv, "s3") == Ok("3")
  assert get_on(b, kv, "s4") == Error(Nil)
  assert get_on(b, kv, "big") == Error(Nil)
  assert count_on(b, kv) == 2
  assert digest_on(a, replicated.KeyValue, fast())
    != digest_on(b, replicated.KeyValue, small)

  // Anti-entropy keeps pulling a's full state, and b keeps refusing it.
  assert peer.eventually(
    fn() {
      list.any(peer.on(b, recorded_syncs), fn(sync) {
        let #(store_name, from, entries, bytes, _duration) = sync
        store_name == name && from == from_a && entries == 4 && bytes > 4000
      })
    },
    wait_ms,
  )
  let syncs = peer.on(b, recorded_syncs)
  assert list.all(syncs, fn(sync) { sync.0 == name && sync.1 == from_a })
  assert list.any(syncs, fn(sync) { sync.2 == 1 && sync.3 > 2000 })
}

// --- Notifications ----------------------------------------------------------

/// Remote writes notify the watchers on every other node: the store topic,
/// and the per-key topic of an append_notify / delete_all_notify.
pub fn remote_writes_notify_watchers_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_rs_notify")
  let assert [a, b] = peers as "the cluster starts two peers"
  let lists = list.map(peers, open_list_on)
  let assert [messages, ..] = lists as "every peer opened a list store"
  let store_watcher =
    peer.on(b, fn() { spawn_recorder([store.list_topic(messages)]) })
  let key_watcher = peer.on(b, fn() { spawn_recorder(["room:general"]) })
  peer.on(b, record_syncs)

  peer.on(a, fn() { store.append_notify(messages, "general", "hi", "room:") })
  assert peer.eventually(
    fn() { peer.on(b, fn() { recorded_count(key_watcher) }) == 1 },
    wait_ms,
  )
  assert peer.on(b, fn() { store.get_all(messages, "general") }) == ["hi"]
  peer.on(a, fn() { store.delete_all_notify(messages, "general", "room:") })
  assert peer.eventually(
    fn() { peer.on(b, fn() { recorded_count(key_watcher) }) == 2 },
    wait_ms,
  )
  assert peer.eventually(
    fn() { peer.on(b, fn() { recorded_count(store_watcher) }) == 2 },
    wait_ms,
  )
  assert peer.on(b, fn() { store.get_all(messages, "general") }) == []
  let from_a = node_name(a)
  assert list.any(peer.on(b, recorded_syncs), fn(sync) {
    sync.0 == name && sync.1 == from_a && sync.2 == 1
  })
}

// --- Benchmark --------------------------------------------------------------

/// Convergence of a write burst on three nodes, then the full sync of a
/// node that joins afterwards.
pub fn convergence_bench_test_() -> peer.Timeout {
  use <- Timeout(120)
  use peers <- peer.with_members(3, "brazier_rs_bench")
  let assert [a, ..] = peers as "the cluster starts at least one peer"
  let kv = open_all(peers)
  let per_node = 2000
  let started = now_us()
  let write_us: Subject(Int) = process.new_subject()
  in_parallel(peers, fn(p) {
    let me = node_name(p)
    let took =
      peer.on(p, fn() {
        let t0 = now_us()
        list.each(seq(per_node), fn(i) {
          store.put(kv, me <> ":" <> int.to_string(i), "value")
        })
        now_us() - t0
      })
    process.send(write_us, took)
  })
  let slowest =
    list.fold(peers, 0, fn(acc, _) {
      let assert Ok(took) = process.receive(write_us, 0)
        as "process.receive succeeds"
      int.max(acc, took)
    })
  assert peer.eventually(fn() { converged(peers, replicated.KeyValue) }, 60_000)
  let converged_ms = { now_us() - started } / 1000
  let total = per_node * 3
  assert list.all(peers, fn(p) { count_on(p, kv) == total })

  let d = peer.add_peer(a, "brazier_rs_bench_d")
  start_on(d, fast())
  let join_started = now_us()
  let assert Ok(Nil) = peer.connect(d, a) as "peer.connect succeeds"
  assert peer.eventually(
    fn() { converged([a, d], replicated.KeyValue) },
    60_000,
  )
  let join_ms = { now_us() - join_started } / 1000
  assert count_on(d, kv) == total

  report(
    "[bench] replicated store: 3 nodes x "
    <> int.to_string(per_node)
    <> " puts, slowest node wrote in "
    <> int.to_string(slowest / 1000)
    <> "ms ("
    <> int.to_string(per_node * 1_000_000 / int.max(1, slowest))
    <> " puts/s); all "
    <> int.to_string(total)
    <> " converged after "
    <> int.to_string(converged_ms)
    <> "ms; a joining node synced "
    <> int.to_string(total)
    <> " entries in "
    <> int.to_string(join_ms)
    <> "ms",
  )
}

// --- FFI --------------------------------------------------------------------

@external(erlang, "brazier_store_test_ffi", "replica_pid")
fn replica_pid(name: String) -> Result(Pid, Nil)

@external(erlang, "brazier_store_test_ffi", "kill_replica")
fn kill_replica(name: String) -> Pid

@external(erlang, "brazier_store_test_ffi", "record_syncs")
fn record_syncs() -> Nil

@external(erlang, "brazier_store_test_ffi", "recorded_syncs")
fn recorded_syncs() -> List(#(String, String, Int, Int, Int))

@external(erlang, "brazier_cluster_test_ffi", "spawn_recorder")
fn spawn_recorder(topics: List(String)) -> Pid

@external(erlang, "brazier_cluster_test_ffi", "recorded_count")
fn recorded_count(pid: Pid) -> Int

@external(erlang, "brazier_cluster_test_ffi", "remote_worker_nodes")
fn remote_worker_nodes(shard: Int) -> List(node.Node)

@external(erlang, "brazier_store_test_ffi", "now_us")
fn now_us() -> Int

@external(erlang, "brazier_cluster_test_ffi", "report")
fn report(line: String) -> Nil
