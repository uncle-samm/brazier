//// Multi-node PubSub tests (design test matrix, "PubSub" rows).
////
//// Every test runs on peer nodes started by `beacon/cluster/peer`; the test
//// runner itself stays non-distributed. Subscribers on a peer are recorder
//// processes (see beacon_cluster_test_ffi) whose deliveries are read back
//// through rpc. Waiting is always `peer.eventually` with a deadline.

import beacon/cluster/peer.{type Peer, Timeout}
import beacon/pubsub
import beacon/store
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
  use peers <- peer.with_cluster(3, "beacon_ps_fanout")
  let assert [a, b, c] = peers
  start_all(peers)
  await_workers(a, 2)
  let topic = "fanout"
  let on_a = peer.on(a, fn() { spawn_recorders(topic, 2) })
  let on_b = peer.on(b, fn() { spawn_recorders(topic, 3) })
  let on_c = peer.on(c, fn() { spawn_recorders(topic, 1) })

  // Hold B's forwarding worker so its mailbox can be counted.
  peer.on(b, fn() { suspend_worker(0) })
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "hello") })
  assert peer.eventually(
    fn() { peer.on(b, fn() { worker_queue_len(0) }) == 1 },
    wait_ms,
  )
  peer.on(b, fn() { resume_worker(0) })

  assert peer.eventually(fn() { all_recorded(a, on_a, ["hello"]) }, wait_ms)
  assert peer.eventually(fn() { all_recorded(b, on_b, ["hello"]) }, wait_ms)
  assert peer.eventually(fn() { all_recorded(c, on_c, ["hello"]) }, wait_ms)
  // B still holds exactly one forward's worth: nothing arrived twice.
  assert peer.on(b, fn() { worker_queue_len(0) }) == 0
}

/// `local_broadcast` stays on the node it was called on.
pub fn local_broadcast_stays_local_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_ps_local")
  let assert [a, b] = peers
  start_all(peers)
  await_workers(a, 1)
  let topic = "local-only"
  let on_a = peer.on(a, fn() { spawn_recorders(topic, 1) })
  let on_b = peer.on(b, fn() { spawn_recorders(topic, 1) })

  // Both sends come from one process on A, so B sees them in order: the
  // marker arriving alone proves the local message never left A.
  let assert Ok(Nil) =
    peer.on(a, fn() {
      let assert Ok(Nil) = pubsub.local_broadcast(topic, "local")
      pubsub.try_broadcast(topic, "marker")
    })
  assert peer.eventually(
    fn() { all_recorded(a, on_a, ["local", "marker"]) },
    wait_ms,
  )
  assert peer.eventually(fn() { all_recorded(b, on_b, ["marker"]) }, wait_ms)
}

/// `direct_broadcast` reaches only the named node; a node that is not
/// connected is an error, not a silent drop.
pub fn direct_broadcast_remote_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(3, "beacon_ps_direct")
  let assert [a, b, c] = peers
  start_all(peers)
  await_workers(a, 2)
  let topic = "direct"
  let on_b = peer.on(b, fn() { spawn_recorders(topic, 2) })
  let on_c = peer.on(c, fn() { spawn_recorders(topic, 1) })
  let b_node = peer.node(b)

  let assert Ok(Nil) =
    peer.on(a, fn() {
      let assert Ok(Nil) = pubsub.direct_broadcast(b_node, topic, "only-b")
      pubsub.try_broadcast(topic, "marker")
    })
  assert peer.eventually(
    fn() { all_recorded(b, on_b, ["only-b", "marker"]) },
    wait_ms,
  )
  assert peer.eventually(fn() { all_recorded(c, on_c, ["marker"]) }, wait_ms)

  // Invalid topics are rejected before anything is sent.
  let assert Error(pubsub.InvalidTopic(_)) =
    peer.on(a, fn() { pubsub.direct_broadcast(b_node, "", "x") })

  let c_node = peer.node(c)
  let c_name = node_name(c_node)
  peer.crash(c)
  assert peer.eventually(
    fn() { !list.contains(peer.on(a, fn() { remote_worker_nodes(0) }), c_node) },
    wait_ms,
  )
  let assert Error(pubsub.NodeNotConnected(node: reported)) =
    peer.on(a, fn() { pubsub.direct_broadcast(c_node, topic, "lost") })
  assert reported == c_name
}

// --- Failure ---

/// A node that dies does not make broadcasts fail, even before pg has
/// noticed it is gone; the surviving nodes keep receiving.
pub fn down_node_does_not_break_broadcast_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(3, "beacon_ps_down")
  let assert [a, b, c] = peers
  start_all(peers)
  await_workers(a, 2)
  let topic = "survivors"
  let on_b = peer.on(b, fn() { spawn_recorders(topic, 1) })
  let assert [_] = peer.on(c, fn() { spawn_recorders(topic, 1) })

  peer.crash(c)
  // Straight away: A's pg view may still list C's worker.
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "one") })
  assert peer.eventually(
    fn() { peer.on(a, fn() { remote_worker_nodes(0) }) == [peer.node(b)] },
    wait_ms,
  )
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "two") })
  assert peer.eventually(
    fn() { all_recorded(b, on_b, ["one", "two"]) },
    wait_ms,
  )
}

/// During a netsplit each side delivers only to itself; nothing sent
/// during the split arrives after it heals, and delivery resumes.
pub fn netsplit_isolates_and_heals_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_ps_split")
  let assert [a, b] = peers
  start_all(peers)
  await_workers(a, 1)
  await_workers(b, 1)
  let topic = "split"
  let on_a = peer.on(a, fn() { spawn_recorders(topic, 1) })
  let on_b = peer.on(b, fn() { spawn_recorders(topic, 1) })

  peer.partition(a, b)
  assert peer.eventually(
    fn() { peer.on(a, fn() { remote_worker_nodes(0) }) == [] },
    wait_ms,
  )
  assert peer.eventually(
    fn() { peer.on(b, fn() { remote_worker_nodes(0) }) == [] },
    wait_ms,
  )
  let assert Ok(Nil) =
    peer.on(a, fn() { pubsub.try_broadcast(topic, "from-a-split") })
  let assert Ok(Nil) =
    peer.on(b, fn() { pubsub.try_broadcast(topic, "from-b-split") })
  assert peer.eventually(
    fn() { all_recorded(a, on_a, ["from-a-split"]) },
    wait_ms,
  )
  assert peer.eventually(
    fn() { all_recorded(b, on_b, ["from-b-split"]) },
    wait_ms,
  )

  peer.heal(a, b)
  await_workers(a, 1)
  await_workers(b, 1)
  let assert Ok(Nil) =
    peer.on(a, fn() { pubsub.try_broadcast(topic, "from-a-healed") })
  assert peer.eventually(
    fn() { all_recorded(b, on_b, ["from-b-split", "from-a-healed"]) },
    wait_ms,
  )
  assert peer.eventually(
    fn() { all_recorded(a, on_a, ["from-a-split", "from-a-healed"]) },
    wait_ms,
  )
}

/// A forwarding worker whose mailbox passes `max_forward_queue` reports
/// overload (telemetry) and still delivers every message.
pub fn forward_overload_reported_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_ps_overload")
  let assert [a, b] = peers
  peer.on(a, pubsub.start)
  let assert Ok(Nil) =
    peer.on(b, fn() {
      pubsub.start_with(pubsub.default_config() |> pubsub.max_forward_queue(2))
    })
  await_workers(a, 1)
  let topic = "flood"
  let on_b = peer.on(b, fn() { spawn_recorders(topic, 1) })
  peer.on(b, fn() {
    count_events(["beacon", "pubsub", "forward", "overloaded"])
  })

  peer.on(b, fn() { suspend_worker(0) })
  let assert Ok(Nil) =
    peer.on(a, fn() {
      list.try_each(["m1", "m2", "m3", "m4", "m5"], fn(message) {
        pubsub.try_broadcast(topic, message)
      })
    })
  assert peer.eventually(
    fn() { peer.on(b, fn() { worker_queue_len(0) }) == 5 },
    wait_ms,
  )
  peer.on(b, fn() { resume_worker(0) })

  assert peer.eventually(
    fn() { all_recorded(b, on_b, ["m1", "m2", "m3", "m4", "m5"]) },
    wait_ms,
  )
  // The first message handled saw the other four queued behind it; the
  // report is rate limited, so the rest of the burst adds no events.
  let assert [queue_len] = peer.on(b, counted_events)
  assert queue_len > 2
}

/// Killing a partition stops the subscribers it tracks (Registry-style
/// links) instead of leaving them subscribed with no table rows; the
/// restarted partition accepts new subscriptions.
pub fn partition_kill_stops_subscribers_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_ps_partkill")
  let assert [a] = peers
  peer.on(a, pubsub.start)
  let topic = "partition"
  let assert [subscriber] = peer.on(a, fn() { spawn_recorders(topic, 1) })
  let assert Ok(partition) =
    peer.on(a, fn() { pubsub.partition_for(subscriber) })

  peer.on(a, fn() { kill(partition) })
  assert peer.on(a, fn() { wait_down(subscriber, wait_ms) })
  assert peer.eventually(
    fn() {
      case peer.on(a, fn() { pubsub.partition_for(subscriber) }) {
        Ok(restarted) -> restarted != partition
        Error(_) -> False
      }
    },
    wait_ms,
  )
  let on_a = peer.on(a, fn() { spawn_recorders(topic, 1) })
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "again") })
  assert peer.eventually(fn() { all_recorded(a, on_a, ["again"]) }, wait_ms)
}

/// After `pubsub.stop()` a node reports NotStarted for every operation, and
/// the other nodes stop forwarding to it without failing.
pub fn stopped_node_reports_not_started_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_ps_stopped")
  let assert [a, b] = peers
  start_all(peers)
  await_workers(a, 1)
  let assert Ok(Nil) = peer.on(b, pubsub.stop)

  let assert Error(pubsub.NotStarted) =
    peer.on(b, fn() { pubsub.try_broadcast("t", "x") })
  let assert Error(pubsub.NotStarted) =
    peer.on(b, fn() { pubsub.try_subscribe("t") })
  let assert Error(pubsub.NotStarted) =
    peer.on(b, fn() { pubsub.local_broadcast("t", "x") })
  assert peer.eventually(
    fn() { peer.on(a, fn() { remote_worker_nodes(0) }) == [] },
    wait_ms,
  )
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast("t", "x") })
  Nil
}

/// Subscribers that exit are removed from their node's registry, and a
/// broadcast from another node finds no one left to deliver to there.
pub fn remote_subscriber_exit_cleans_up_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_ps_exit")
  let assert [a, b] = peers
  start_all(peers)
  await_workers(a, 1)
  let topic = "leaving"
  let assert [leaver, stayer] = peer.on(b, fn() { spawn_recorders(topic, 2) })
  assert peer.on(b, fn() { pubsub.local_subscriber_count(topic) }) == 2

  peer.on(b, fn() { kill(leaver) })
  assert peer.eventually(
    fn() { peer.on(b, fn() { pubsub.local_subscriber_count(topic) }) == 1 },
    wait_ms,
  )
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "hi") })
  assert peer.eventually(fn() { all_recorded(b, [stayer], ["hi"]) }, wait_ms)
}

// --- Stores (step 2 regression) ---

/// A store write notifies watchers on its own node only: the other node's
/// table did not change, so its watchers must not be told it did.
pub fn store_notification_is_node_local_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_ps_store")
  let assert [a, b] = peers
  start_all(peers)
  await_workers(a, 1)
  let watch = fn() {
    let s: store.Store(String) = store.new("cluster_regression")
    spawn_recorders(store.topic(s), 1)
  }
  let assert [on_a] = peer.on(a, watch)
  let assert [on_b] = peer.on(b, watch)

  let assert Ok(Nil) =
    peer.on(a, fn() {
      let s: store.Store(String) = store.new("cluster_regression")
      store.put(s, "k", "v")
      pubsub.try_broadcast(store.topic(s), "marker")
    })
  // A saw the change notification and the marker; B only the marker.
  assert peer.eventually(
    fn() { peer.on(a, fn() { recorded_count(on_a) }) == 2 },
    wait_ms,
  )
  assert peer.eventually(
    fn() { peer.on(b, fn() { recorded_count(on_b) }) == 1 },
    wait_ms,
  )
  assert peer.on(b, fn() { recorded(on_b) }) == ["marker"]
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
  use peers <- peer.with_cluster(3, "beacon_ps_bench")
  let assert [a, ..] = peers
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
          #(started_os, now_us() - started)
        })
      assert peer.eventually(
        fn() {
          list.all(peers, fn(p) {
            peer.on(p, fn() { round_done_at(round) }) != Error(Nil)
          })
        },
        30_000,
      )
      let finished =
        list.fold(peers, 0, fn(latest, p) {
          let assert Ok(at) = peer.on(p, fn() { round_done_at(round) })
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
  value
}

fn last(sorted: List(Int)) -> Int {
  let assert Ok(value) = list.last(sorted)
  value
}

// --- Helpers ---

fn start_all(peers: List(Peer)) -> Nil {
  list.each(peers, fn(p) { peer.on(p, pubsub.start) })
}

/// Wait until `p` sees shard-0 forwarding workers on `count` other nodes.
fn await_workers(p: Peer, count: Int) -> Nil {
  assert peer.eventually(
    fn() { list.length(peer.on(p, fn() { remote_worker_nodes(0) })) == count },
    wait_ms,
  )
}

fn all_recorded(p: Peer, recorders: List(Pid), expected: List(String)) -> Bool {
  peer.on(p, fn() { recorded_all(recorders) })
  |> list.all(fn(messages) { messages == expected })
}

fn node_name(n: node.Node) -> String {
  atom_to_binary(n)
}

@external(erlang, "erlang", "atom_to_binary")
fn atom_to_binary(n: node.Node) -> String

@external(erlang, "beacon_cluster_test_ffi", "spawn_recorders")
fn spawn_recorders(topic: String, count: Int) -> List(Pid)

@external(erlang, "beacon_cluster_test_ffi", "recorded")
fn recorded(pid: Pid) -> List(String)

@external(erlang, "beacon_cluster_test_ffi", "recorded_all")
fn recorded_all(pids: List(Pid)) -> List(List(String))

@external(erlang, "beacon_cluster_test_ffi", "recorded_count")
fn recorded_count(pid: Pid) -> Int

@external(erlang, "beacon_cluster_test_ffi", "worker_queue_len")
fn worker_queue_len(shard: Int) -> Int

@external(erlang, "beacon_cluster_test_ffi", "suspend_worker")
fn suspend_worker(shard: Int) -> Nil

@external(erlang, "beacon_cluster_test_ffi", "resume_worker")
fn resume_worker(shard: Int) -> Nil

@external(erlang, "beacon_cluster_test_ffi", "remote_worker_nodes")
fn remote_worker_nodes(shard: Int) -> List(node.Node)

@external(erlang, "beacon_cluster_test_ffi", "count_events")
fn count_events(event: List(String)) -> Nil

@external(erlang, "beacon_cluster_test_ffi", "counted_events")
fn counted_events() -> List(Int)

@external(erlang, "beacon_cluster_test_ffi", "kill")
fn kill(pid: Pid) -> Nil

@external(erlang, "beacon_cluster_test_ffi", "wait_down")
fn wait_down(pid: Pid, timeout_ms: Int) -> Bool

@external(erlang, "beacon_cluster_test_ffi", "spawn_counters")
fn spawn_counters(topic: String, count: Int) -> Int

@external(erlang, "beacon_cluster_test_ffi", "round_done_at")
fn round_done_at(round: Int) -> Result(Int, Nil)

@external(erlang, "beacon_cluster_test_ffi", "os_us")
fn os_us() -> Int

@external(erlang, "beacon_cluster_test_ffi", "now_us")
fn now_us() -> Int

@external(erlang, "beacon_cluster_test_ffi", "report")
fn report(line: String) -> Nil
