//// Multi-node replicated store tests (brazier/store with mode Replicated).
////
//// Every node opens the same store with a fast anti-entropy period
//// (100ms). Two replicas have converged when their digests (a hash of the
//// whole CRDT state) are equal.
////
//// Nothing here polls. A replica changes only through this node's writes,
//// which return once applied, and remote merges, each run inside a
//// `[brazier, store, sync]` span whose stop event comes after the merge
//// has updated the replica and its ETS mirror. So a wait is `peer.until`
//// woken by those stop events: on one node for what that node reads, or on
//// every node (`peer.events_on`) for convergence. Sync spans, deliveries
//// and restarts are taken as messages, like ExUnit's `assert_receive`.

import brazier/await
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/cluster/relay.{type Deliveries, type Events}
import brazier/pubsub
import brazier/store
import brazier/store/replicated.{Config}
import brazier/telemetry
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

const wait_ms = 10_000

const name = "rsc"

/// The stop event of the span every remote merge runs in.
const merged = ["brazier", "store", "sync", "stop"]

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
  peer.on(p, fn() { digest_here(kind, cfg) })
}

fn digest_here(
  kind: replicated.Kind,
  cfg: replicated.Config,
) -> Result(BitArray, Nil) {
  let assert Ok(#(server, _table)) = replicated.start(kind, name, cfg)
    as "replicated.start succeeds"
  case replicated.digest(server) {
    Ok(digest) -> Ok(digest)
    Error(_) -> Error(Nil)
  }
}

/// Whether the replicas on `peers` come to have one digest within
/// `timeout_ms`. The first peer waits, woken by a merge on any of them; a
/// digest is read through its replica, so after the merge.
fn converge_within(
  peers: List(Peer),
  kind: replicated.Kind,
  timeout_ms: Int,
) -> Bool {
  let assert [first, ..] = peers as "converge_within needs a peer"
  let nodes = list.map(peers, peer.node)
  peer.until(
    first,
    peer.events_on(nodes, [merged]),
    fn() { digests_agree(nodes, kind) },
    timeout_ms,
  )
}

fn converge(peers: List(Peer), kind: replicated.Kind) -> Bool {
  converge_within(peers, kind, wait_ms)
}

fn digests_agree(nodes: List(Node), kind: replicated.Kind) -> Bool {
  let digests =
    list.map(nodes, fn(n) {
      peer.on_node(n, fn() { digest_here(kind, fast()) })
    })
  case digests {
    [Ok(first), ..rest] -> list.all(rest, fn(d) { d == Ok(first) })
    _ -> False
  }
}

/// Whether `check` comes to hold on `p`, re-checked after each merge there.
fn after_merges(p: Peer, check: fn() -> Bool) -> Bool {
  peer.until(p, peer.events([merged]), check, wait_ms)
}

fn sees(p: Peer, kv: store.Store(String), key: String, value: String) -> Bool {
  after_merges(p, fn() { store.get(kv, key) == Ok(value) })
}

fn lacks(p: Peer, kv: store.Store(String), key: String) -> Bool {
  after_merges(p, fn() { store.get(kv, key) == Error(Nil) })
}

/// One remote merge, as its sync span reports it.
type Sync {
  Sync(store: String, from: String, entries: Int, bytes: Int)
}

/// Take relayed sync spans until every one of `wanted` has matched one of
/// them; the spans taken, in order, or Error if one did not come in time.
fn take_syncs(
  p: Peer,
  syncs: Events,
  wanted: List(fn(Sync) -> Bool),
  taken: List(Sync),
) -> Result(List(Sync), Nil) {
  case list.filter(wanted, fn(w) { !list.any(taken, w) }) {
    [] -> Ok(list.reverse(taken))
    missing -> {
      use event <- result.try(relay.next_event(p, syncs, wait_ms))
      take_syncs(p, syncs, missing, [sync_of(event), ..taken])
    }
  }
}

fn sync_of(event: telemetry.Event) -> Sync {
  let assert Ok(store_name) = telemetry.string(event, "store")
    as "a sync span names its store"
  let assert Ok(from) = telemetry.string(event, "peer")
    as "a sync span names its peer"
  let assert Ok(entries) = telemetry.int(event, "entries")
    as "a sync span counts its entries"
  let assert Ok(bytes) = telemetry.int(event, "bytes")
    as "a sync span counts its bytes"
  Sync(store: store_name, from:, entries:, bytes:)
}

/// Whether `count` notifications reach `watcher` on `p`, each in time, and
/// no more so far.
fn notified(p: Peer, watcher: Deliveries, count: Int) -> Bool {
  list.all(list.repeat(Nil, count), fn(_) {
    relay.next_delivery(p, watcher, wait_ms, fn(message) { message })
    != Error(Nil)
  })
  && relay.pending_deliveries(p, watcher) == 0
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

  assert converge(peers, replicated.KeyValue)
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

  assert converge(peers, replicated.List)
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
  assert converge(peers, replicated.KeyValue)
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
  assert after_merges(b, fn() { store.get_all(messages, "room") == ["old"] })

  peer.partition(a, b)
  delete_on(a, kv, "k")
  peer.on(a, fn() { store.delete_all(messages, "room") })
  put_on(b, kv, "k", "v1")
  peer.on(b, fn() { store.append(messages, "room", "new") })
  assert get_on(a, kv, "k") == Error(Nil)

  peer.heal(a, b)
  assert converge(peers, replicated.KeyValue)
  assert converge(peers, replicated.List)
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
  assert converge(peers, replicated.KeyValue)

  peer.crash(c)
  put_on(a, kv, "after_crash", "a")
  delete_on(b, kv, "c_deleted")
  let d = peer.add_peer(a, "brazier_rs_crash_d")
  start_on(d, fast())
  assert get_on(d, kv, "from_c") == Error(Nil)
  let assert Ok(Nil) = peer.connect(d, a) as "peer.connect succeeds"

  let survivors = [a, b, d]
  assert converge(survivors, replicated.KeyValue)
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
  assert converge(peers, replicated.KeyValue)

  // The supervisor has restarted the replica, under its registered name,
  // once it has handled the replica's exit (OTP supervisors restart a
  // child while handling the EXIT).
  peer.on(b, fn() {
    let assert Ok(old) = replica_pid(name) as "b runs the replica"
    let supervisor = parent(old)
    await.with_watch_exit(supervisor, old, fn(watch) {
      kill(old)
      await.expect_info(watch, supervisor, "the replica's exit")
    })
    let assert Ok(restarted) = replica_pid(name)
      as "the supervisor restarted the replica"
    assert restarted != old
  })
  assert converge(peers, replicated.KeyValue)
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
  let syncs = relay.events(b, [merged])
  // b's PubSub started inside start_on, and pg tells a about b's forwarding
  // worker asynchronously (not ordered with start_on's reply). Until a lists
  // it, a's deltas skip b, and b refuses every full sync here, so no write
  // may run before then.
  let b_node = peer.node(b)
  assert peer.until(
    a,
    peer.pg_changes("brazier_pubsub_pg", #(atom.create("brazier_pubsub"), 0)),
    fn() { remote_worker_nodes(0) == [b_node] },
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
  // refused.
  let from_a = node_name(a)
  assert after_merges(b, fn() {
    store.get(kv, "s3") == Ok("3") && store.get(kv, "s1") == Error(Nil)
  })
  assert get_on(b, kv, "s1") == Error(Nil)
  assert get_on(b, kv, "s2") == Ok("2")
  assert get_on(b, kv, "s3") == Ok("3")
  assert get_on(b, kv, "s4") == Error(Nil)
  assert get_on(b, kv, "big") == Error(Nil)
  assert count_on(b, kv) == 2
  assert digest_on(a, replicated.KeyValue, fast())
    != digest_on(b, replicated.KeyValue, small)

  // Every merge on b is a span from a, among them an empty one (the
  // removal's delta, or a's reply to b's startup sync_req), the refused
  // delta of "big", and, as anti-entropy keeps pulling a's full state, a
  // refused full state of its four entries.
  let assert Ok(taken) =
    take_syncs(
      b,
      syncs,
      [
        fn(sync: Sync) { sync.entries == 0 },
        fn(sync: Sync) { sync.entries == 1 && sync.bytes > 2000 },
        fn(sync: Sync) { sync.entries == 4 && sync.bytes > 4000 },
      ],
      [],
    )
    as "b reports every kind of merge it was sent"
  assert list.all(taken, fn(sync) { sync.store == name && sync.from == from_a })
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
  let store_watcher = relay.deliveries(b, [store.list_topic(messages)])
  let key_watcher = relay.deliveries(b, ["room:general"])
  let syncs = relay.events(b, [merged])

  // The replica announces a merge after writing it to its table.
  peer.on(a, fn() { store.append_notify(messages, "general", "hi", "room:") })
  assert notified(b, key_watcher, 1)
  assert peer.on(b, fn() { store.get_all(messages, "general") }) == ["hi"]
  peer.on(a, fn() { store.delete_all_notify(messages, "general", "room:") })
  assert notified(b, key_watcher, 1)
  assert notified(b, store_watcher, 2)
  assert peer.on(b, fn() { store.get_all(messages, "general") }) == []
  let from_a = node_name(a)
  let assert Ok(taken) =
    take_syncs(b, syncs, [fn(sync: Sync) { sync.entries == 1 }], [])
    as "b reports merging a's append"
  assert list.all(taken, fn(sync) { sync.store == name && sync.from == from_a })
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
  assert converge_within(peers, replicated.KeyValue, 60_000)
  let converged_ms = { now_us() - started } / 1000
  let total = per_node * 3
  assert list.all(peers, fn(p) { count_on(p, kv) == total })

  let d = peer.add_peer(a, "brazier_rs_bench_d")
  start_on(d, fast())
  let join_started = now_us()
  let assert Ok(Nil) = peer.connect(d, a) as "peer.connect succeeds"
  assert converge_within([a, d], replicated.KeyValue, 60_000)
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

@external(erlang, "brazier_cluster_test_ffi", "kill")
fn kill(pid: Pid) -> Nil

@external(erlang, "brazier_presence_test_ffi", "parent")
fn parent(pid: Pid) -> Pid

@external(erlang, "brazier_cluster_test_ffi", "remote_worker_nodes")
fn remote_worker_nodes(shard: Int) -> List(node.Node)

@external(erlang, "brazier_store_test_ffi", "now_us")
fn now_us() -> Int

@external(erlang, "brazier_cluster_test_ffi", "report")
fn report(line: String) -> Nil
