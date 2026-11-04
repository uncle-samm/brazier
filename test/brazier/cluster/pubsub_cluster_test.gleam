//// Multi-node PubSub tests (design test matrix, "PubSub" rows).
////
//// Every test runs on peer nodes started by `brazier/cluster/peer`; the test
//// runner itself stays non-distributed. Subscribers on a peer are relay
//// holders (brazier/cluster/relay) that take each delivery with a
//// deadline, like ExUnit's `assert_receive`, so a test asserts the exact
//// messages each one got and that nothing else came before them.
////
//// Nothing here polls but the benchmark. Forwarding workers are waited
//// for with `pg:monitor/2` on their pg group, a suspended worker's queue
//// with a receive trace, and a restart through the supervisor's sys hook
//// (`await.with_watch_exit`).

import brazier/await
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/cluster/relay.{type Deliveries}
import brazier/pubsub
import brazier/store
import brazier/telemetry
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list

const wait_ms = 5000

// --- Cross-node delivery ---

/// A cluster broadcast reaches every subscriber on every node exactly once,
/// and each remote node receives one forward however many subscribers it
/// has.
pub fn cross_node_delivery_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(3, "brazier_ps_fanout")
  let assert [a, b, c] = peers as "the cluster starts three peers"
  start_all(peers)
  await_workers(a, 2)
  let topic = "fanout"
  let on_a = subscribe(a, topic, 2)
  let on_b = subscribe(b, topic, 3)
  let on_c = subscribe(c, topic, 1)

  // Hold B's forwarding worker so its mailbox can be counted.
  peer.on(b, fn() { suspend_worker(0) })
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "hello") })
    as "pubsub.try_broadcast succeeds"
  assert worker_queue_reaches(b, 1)
  peer.on(b, fn() { resume_worker(0) })

  assert all_receive(a, on_a, ["hello"])
  assert all_receive(b, on_b, ["hello"])
  assert all_receive(c, on_c, ["hello"])
  // B still holds exactly one forward's worth: nothing arrived twice.
  assert peer.on(b, fn() { worker_queue_len(0) }) == 0
}

/// `local_broadcast` stays on the node it was called on.
pub fn local_broadcast_stays_local_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_ps_local")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_all(peers)
  await_workers(a, 1)
  let topic = "local-only"
  let on_a = subscribe(a, topic, 1)
  let on_b = subscribe(b, topic, 1)

  // Both sends come from one process on A, so B sees them in order: the
  // marker arriving alone proves the local message never left A.
  let assert Ok(Nil) =
    peer.on(a, fn() {
      let assert Ok(Nil) = pubsub.local_broadcast(topic, "local")
        as "pubsub.local_broadcast succeeds"
      pubsub.try_broadcast(topic, "marker")
    })
    as "the marker broadcast succeeds"
  assert all_receive(a, on_a, ["local", "marker"])
  assert all_receive(b, on_b, ["marker"])
}

/// `direct_broadcast` reaches only the named node; a node that is not
/// connected is an error, not a silent drop.
pub fn direct_broadcast_remote_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(3, "brazier_ps_direct")
  let assert [a, b, c] = peers as "the cluster starts three peers"
  start_all(peers)
  await_workers(a, 2)
  let topic = "direct"
  let on_b = subscribe(b, topic, 2)
  let on_c = subscribe(c, topic, 1)
  let b_node = peer.node(b)

  let assert Ok(Nil) =
    peer.on(a, fn() {
      let assert Ok(Nil) = pubsub.direct_broadcast(b_node, topic, "only-b")
        as "pubsub.direct_broadcast succeeds"
      pubsub.try_broadcast(topic, "marker")
    })
    as "the marker broadcast succeeds"
  assert all_receive(b, on_b, ["only-b", "marker"])
  assert all_receive(c, on_c, ["marker"])

  // Invalid topics are rejected before anything is sent.
  let assert Error(pubsub.InvalidTopic(_)) =
    peer.on(a, fn() { pubsub.direct_broadcast(b_node, "", "x") })
    as "pubsub.direct_broadcast returns Error(InvalidTopic)"

  let c_node = peer.node(c)
  let c_name = node_name(c_node)
  peer.crash(c)
  assert workers_reach(a, fn(nodes) { !list.contains(nodes, c_node) })
  let assert Error(pubsub.NodeNotConnected(node: reported)) =
    peer.on(a, fn() { pubsub.direct_broadcast(c_node, topic, "lost") })
    as "pubsub.direct_broadcast returns Error(NodeNotConnected)"
  assert reported == c_name
}

// --- Failure ---

/// A node that dies does not make broadcasts fail, even before pg has
/// noticed it is gone; the surviving nodes keep receiving.
pub fn down_node_does_not_break_broadcast_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(3, "brazier_ps_down")
  let assert [a, b, c] = peers as "the cluster starts three peers"
  start_all(peers)
  await_workers(a, 2)
  let topic = "survivors"
  let on_b = subscribe(b, topic, 1)
  let _on_c = subscribe(c, topic, 1)

  peer.crash(c)
  // Straight away: A's pg view may still list C's worker.
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "one") })
    as "pubsub.try_broadcast succeeds"
  assert workers_reach(a, fn(nodes) { nodes == [peer.node(b)] })
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "two") })
    as "pubsub.try_broadcast succeeds"
  assert all_receive(b, on_b, ["one", "two"])
}

/// During a netsplit each side delivers only to itself; nothing sent
/// during the split arrives after it heals, and delivery resumes.
pub fn netsplit_isolates_and_heals_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_ps_split")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_all(peers)
  await_workers(a, 1)
  await_workers(b, 1)
  let topic = "split"
  let on_a = subscribe(a, topic, 1)
  let on_b = subscribe(b, topic, 1)

  peer.partition(a, b)
  await_workers(a, 0)
  await_workers(b, 0)
  let assert Ok(Nil) =
    peer.on(a, fn() { pubsub.try_broadcast(topic, "from-a-split") })
    as "pubsub.try_broadcast succeeds"
  let assert Ok(Nil) =
    peer.on(b, fn() { pubsub.try_broadcast(topic, "from-b-split") })
    as "pubsub.try_broadcast succeeds"
  assert all_receive(a, on_a, ["from-a-split"])
  assert all_receive(b, on_b, ["from-b-split"])

  peer.heal(a, b)
  await_workers(a, 1)
  await_workers(b, 1)
  let assert Ok(Nil) =
    peer.on(a, fn() { pubsub.try_broadcast(topic, "from-a-healed") })
    as "pubsub.try_broadcast succeeds"
  // Each side's next message is the one sent after the heal.
  assert all_receive(b, on_b, ["from-a-healed"])
  assert all_receive(a, on_a, ["from-a-healed"])
}

/// A forwarding worker whose mailbox passes `max_forward_queue` reports
/// overload (telemetry) and still delivers every message.
pub fn forward_overload_reported_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_ps_overload")
  let assert [a, b] = peers as "the cluster starts two peers"
  peer.on(a, pubsub.start)
  let assert Ok(Nil) =
    peer.on(b, fn() {
      pubsub.start_with(pubsub.default_config() |> pubsub.max_forward_queue(2))
    })
    as "pubsub.start_with succeeds"
  await_workers(a, 1)
  let topic = "flood"
  let on_b = subscribe(b, topic, 1)
  let overloaded =
    relay.events(b, [["brazier", "pubsub", "forward", "overloaded"]])

  peer.on(b, fn() { suspend_worker(0) })
  let assert Ok(Nil) =
    peer.on(a, fn() {
      list.try_each(["m1", "m2", "m3", "m4", "m5"], fn(message) {
        pubsub.try_broadcast(topic, message)
      })
    })
    as "list.try_each succeeds"
  assert worker_queue_reaches(b, 5)
  peer.on(b, fn() { resume_worker(0) })

  assert all_receive(b, on_b, ["m1", "m2", "m3", "m4", "m5"])
  // The first message handled saw the other four queued behind it; the
  // report is rate limited, so the rest of the burst adds no events. The
  // worker reports before it delivers, so the event is already relayed.
  let assert Ok(event) = relay.next_event(b, overloaded, wait_ms)
    as "the worker reports overload"
  let assert Ok(queue_len) = telemetry.int(event, "queue_len")
    as "the overload event carries queue_len"
  assert queue_len > 2
  assert relay.pending_events(b, overloaded) == 0
}

/// Killing a partition stops the subscribers it tracks (Registry-style
/// links) instead of leaving them subscribed with no table rows; the
/// restarted partition accepts new subscriptions.
pub fn partition_kill_stops_subscribers_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_ps_partkill")
  let assert [a] = peers as "the cluster starts one peer"
  peer.on(a, pubsub.start)
  let topic = "partition"
  let assert [subscriber] = subscribe(a, topic, 1)
    as "subscribe returns a list of one"
  let pid = subscriber.holder.pid
  let assert Ok(partition) = peer.on(a, fn() { pubsub.partition_for(pid) })
    as "pubsub.partition_for succeeds"

  // The supervisor has restarted the partition once it has handled its
  // exit (OTP supervisors restart a child while handling the EXIT).
  peer.on(a, fn() {
    let supervisor = parent(partition)
    use watch <- await.with_watch_exit(supervisor, partition)
    kill(partition)
    await.expect_info(watch, supervisor, "the partition's exit")
  })
  assert peer.on(a, fn() { wait_down(pid, wait_ms) })
  let assert Ok(restarted) = peer.on(a, fn() { pubsub.partition_for(pid) })
    as "the restarted partition is registered"
  assert restarted != partition
  let on_a = subscribe(a, topic, 1)
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "again") })
    as "pubsub.try_broadcast succeeds"
  assert all_receive(a, on_a, ["again"])
}

/// Subscribing while partitions restart (STAB-3). A partition takes its
/// name only once its tables exist, and `subscribe` checks the name still
/// names the partition it linked to after its inserts. So a subscriber
/// racing a restart gets `Ok` or `NotStarted`, never a crash on a missing
/// table, and no row is left in a restarted partition's tables for a
/// process that partition is not linked to (such rows would never be
/// removed). Every partition is killed once, within the restart intensity
/// (one per partition per 5s).
pub fn partition_churn_leaves_no_orphan_rows_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_ps_churn")
  let assert [a] = peers as "with_cluster(1) starts one peer"
  let config = pubsub.default_config() |> pubsub.partitions(16)
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.start_with(config) })
    as "16 partitions is a valid PubSub config"
  let #(unexpected, rows) =
    peer.on(a, fn() { partition_churn("churn", 8, 500) })
  assert unexpected == []
  assert rows == 0
}

/// After `pubsub.stop()` a node reports NotStarted for every operation, and
/// the other nodes stop forwarding to it without failing.
pub fn stopped_node_reports_not_started_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_ps_stopped")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_all(peers)
  await_workers(a, 1)
  let assert Ok(Nil) = peer.on(b, pubsub.stop) as "pubsub.stop succeeds"

  let assert Error(pubsub.NotStarted) =
    peer.on(b, fn() { pubsub.try_broadcast("t", "x") })
    as "pubsub.try_broadcast returns Error(NotStarted)"
  let assert Error(pubsub.NotStarted) =
    peer.on(b, fn() { pubsub.try_subscribe("t") })
    as "pubsub.try_subscribe returns Error(NotStarted)"
  let assert Error(pubsub.NotStarted) =
    peer.on(b, fn() { pubsub.local_broadcast("t", "x") })
    as "pubsub.local_broadcast returns Error(NotStarted)"
  await_workers(a, 0)
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast("t", "x") })
    as "pubsub.try_broadcast succeeds"
  Nil
}

/// Subscribers that exit are removed from their node's registry, and a
/// broadcast from another node finds no one left to deliver to there.
pub fn remote_subscriber_exit_cleans_up_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_ps_exit")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_all(peers)
  await_workers(a, 1)
  let topic = "leaving"
  let assert [leaver, stayer] = subscribe(b, topic, 2)
    as "subscribe returns a list of two"
  assert peer.on(b, fn() { pubsub.local_subscriber_count(topic) }) == 2

  // The partition traps exits and removes the leaver's rows when it
  // handles its EXIT, so the count is read once it has.
  peer.on(b, fn() {
    let pid = leaver.holder.pid
    let assert Ok(partition) = pubsub.partition_for(pid)
      as "pubsub.partition_for succeeds"
    use watch <- await.with_watch_exit(partition, pid)
    kill(pid)
    await.expect_info(watch, partition, "the leaver's exit")
  })
  assert peer.on(b, fn() { pubsub.local_subscriber_count(topic) }) == 1
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "hi") })
    as "pubsub.try_broadcast succeeds"
  assert all_receive(b, [stayer], ["hi"])
}

// --- Stores (step 2 regression) ---

/// A store write notifies watchers on its own node only: the other node's
/// table did not change, so its watchers must not be told it did.
pub fn store_notification_is_node_local_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_ps_store")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_all(peers)
  await_workers(a, 1)
  let store_topic = fn(p) {
    peer.on(p, fn() {
      let s: store.Store(String) = store.new("cluster_regression")
      store.topic(s)
    })
  }
  let on_a = relay.deliveries(a, [store_topic(a)])
  let on_b = relay.deliveries(b, [store_topic(b)])

  let assert Ok(Nil) =
    peer.on(a, fn() {
      let s: store.Store(String) = store.new("cluster_regression")
      store.put(s, "k", "v")
      pubsub.try_broadcast(store.topic(s), "marker")
    })
    as "the marker broadcast succeeds"
  // A saw the change notification, then the marker (both sent by the
  // writing process, so in that order); B only the marker.
  let assert Ok(_notification) =
    relay.next_delivery(a, on_a, wait_ms, as_string)
    as "A's watcher is notified of the put"
  assert next_message(a, on_a) == Ok("marker")
  assert relay.pending_deliveries(a, on_a) == 0
  assert all_receive(b, [on_b], ["marker"])
  assert peer.on(b, fn() {
      let s: store.Store(String) = store.new("cluster_regression")
      store.get(s, "k")
    })
    == Error(Nil)
}

// --- Benchmark ---

/// Fan-out across 3 nodes with 10,000 subscribers each, over several
/// rounds: how long the broadcast call takes on A, and how long until the
/// last subscriber on any node has the message (OS clock, shared by the
/// peers on this host). Reports the median and worst round.
pub fn fanout_benchmark_test_() -> peer.Timeout {
  use <- Timeout(120)
  use peers <- peer.with_members(3, "brazier_ps_bench")
  let assert [a, ..] = peers as "the cluster starts at least one peer"
  start_all(peers)
  await_workers(a, 2)
  let topic = "bench"
  let per_node = 10_000
  let rounds = 7
  list.each(peers, fn(p) {
    assert peer.on(p, fn() { spawn_counters(topic, per_node) }) == per_node
  })

  let samples =
    bench_rounds(peers, a, topic, 1, rounds, [])
    |> list.reverse
  let calls =
    list.map(samples, fn(sample) { sample.0 }) |> list.sort(int.compare)
  let totals =
    list.map(samples, fn(sample) { sample.1 }) |> list.sort(int.compare)
  report(
    "[bench] pubsub fan-out, 3 nodes x "
    <> int.to_string(per_node)
    <> " subscribers, "
    <> int.to_string(rounds)
    <> " rounds: broadcast call median "
    <> int.to_string(median(calls))
    <> "us (max "
    <> int.to_string(last(calls))
    <> "us); all 30000 delivered median "
    <> int.to_string(median(totals))
    <> "us (max "
    <> int.to_string(last(totals))
    <> "us)",
  )
}

/// Run fan-out rounds `round`..`rounds`, one at a time, each waiting for
/// complete delivery before the next. Samples are #(call_us, total_us).
fn bench_rounds(
  peers: List(Peer),
  origin: Peer,
  topic: String,
  round: Int,
  rounds: Int,
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case round > rounds {
    True -> acc
    False -> {
      let #(started_os, call_us) =
        peer.on(origin, fn() {
          let started_os = os_us()
          let started = now_us()
          let assert Ok(Nil) = pubsub.try_broadcast(topic, round)
            as "pubsub.try_broadcast succeeds"
          #(started_os, now_us() - started)
        })
      // The counter that completes a round on a peer stores the time and
      // then tells the waiter (brazier_cluster_test_ffi:await_round/2), so
      // the notice is not on the path being measured; the times are the
      // ones the counters stored.
      let finished =
        list.fold(peers, 0, fn(latest, p) {
          let assert Ok(at) =
            peer.on_within(p, 35_000, fn() { await_round(round, 30_000) })
            as "every peer completes the round"
          int.max(latest, at)
        })
      bench_rounds(peers, origin, topic, round + 1, rounds, [
        #(call_us, finished - started_os),
        ..acc
      ])
    }
  }
}

fn median(sorted: List(Int)) -> Int {
  let assert Ok(value) =
    list.drop(sorted, list.length(sorted) / 2) |> list.first
    as "list.drop succeeds"
  value
}

fn last(sorted: List(Int)) -> Int {
  let assert Ok(value) = list.last(sorted) as "list.last succeeds"
  value
}

// --- Helpers ---

fn start_all(peers: List(Peer)) -> Nil {
  list.each(peers, fn(p) { peer.on(p, pubsub.start) })
}

/// Whether the nodes whose shard-0 forwarding worker `p` sees come to
/// satisfy `holds`, re-checked on each join and leave of the workers' pg
/// group (`{brazier_pubsub, 0}` in scope `brazier_pubsub_pg`).
fn workers_reach(p: Peer, holds: fn(List(node.Node)) -> Bool) -> Bool {
  peer.until(
    p,
    peer.pg_changes("brazier_pubsub_pg", #(atom.create("brazier_pubsub"), 0)),
    fn() { holds(remote_worker_nodes(0)) },
    wait_ms,
  )
}

/// Wait until `p` sees shard-0 forwarding workers on `count` other nodes.
fn await_workers(p: Peer, count: Int) -> Nil {
  assert workers_reach(p, fn(nodes) { list.length(nodes) == count })
}

/// Whether `p`'s suspended shard-0 worker comes to hold `count` messages,
/// re-checked on each message it receives (a receive trace: the check
/// reads its queue length without sending to it).
fn worker_queue_reaches(p: Peer, count: Int) -> Bool {
  let worker = peer.on(p, fn() { worker_pid(0) })
  peer.until(
    p,
    peer.receives(worker),
    fn() { worker_queue_len(0) == count },
    wait_ms,
  )
}

fn worker_pid(shard: Int) -> Pid {
  let assert Ok(pid) =
    peer.registered("brazier_pubsub_worker_" <> int.to_string(shard))
    as "the forwarding worker is registered"
  pid
}

/// `count` subscribers to `topic` on `p`.
fn subscribe(p: Peer, topic: String, count: Int) -> List(Deliveries) {
  list.repeat(Nil, count)
  |> list.map(fn(_) { relay.deliveries(p, [topic]) })
}

/// Whether each of `subscribers` on `p` receives exactly `expected` next,
/// in order, with nothing else arrived after them so far.
fn all_receive(
  p: Peer,
  subscribers: List(Deliveries),
  expected: List(String),
) -> Bool {
  list.all(subscribers, fn(subscriber) {
    let received = list.map(expected, fn(_) { next_message(p, subscriber) })
    received == list.map(expected, Ok)
    && relay.pending_deliveries(p, subscriber) == 0
  })
}

/// The next String delivered to `subscriber`, or Error(Nil) if none came
/// in time or it was not a String.
fn next_message(p: Peer, subscriber: Deliveries) -> Result(String, Nil) {
  case relay.next_delivery(p, subscriber, wait_ms, as_string) {
    Ok(Ok(message)) -> Ok(message)
    Ok(Error(_)) | Error(Nil) -> Error(Nil)
  }
}

fn as_string(message: Dynamic) -> Result(String, List(decode.DecodeError)) {
  decode.run(message, decode.string)
}

fn node_name(n: node.Node) -> String {
  atom_to_binary(n)
}

@external(erlang, "erlang", "atom_to_binary")
fn atom_to_binary(n: node.Node) -> String

@external(erlang, "brazier_cluster_test_ffi", "worker_queue_len")
fn worker_queue_len(shard: Int) -> Int

@external(erlang, "brazier_cluster_test_ffi", "suspend_worker")
fn suspend_worker(shard: Int) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "resume_worker")
fn resume_worker(shard: Int) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "remote_worker_nodes")
fn remote_worker_nodes(shard: Int) -> List(node.Node)

@external(erlang, "brazier_cluster_test_ffi", "kill")
fn kill(pid: Pid) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "wait_down")
fn wait_down(pid: Pid, timeout_ms: Int) -> Bool

@external(erlang, "brazier_presence_test_ffi", "parent")
fn parent(pid: Pid) -> Pid

@external(erlang, "brazier_cluster_test_ffi", "partition_churn")
fn partition_churn(
  topic: String,
  per_round: Int,
  iterations: Int,
) -> #(List(String), Int)

@external(erlang, "brazier_cluster_test_ffi", "spawn_counters")
fn spawn_counters(topic: String, count: Int) -> Int

@external(erlang, "brazier_cluster_test_ffi", "await_round")
fn await_round(round: Int, timeout_ms: Int) -> Result(Int, Nil)

@external(erlang, "brazier_cluster_test_ffi", "os_us")
fn os_us() -> Int

@external(erlang, "brazier_cluster_test_ffi", "now_us")
fn now_us() -> Int

@external(erlang, "brazier_cluster_test_ffi", "report")
fn report(line: String) -> Nil
