//// Multi-node presence tests (design test matrix, "Presence" rows).
////
//// Every node runs PubSub and a tracker with the same name. Tracking goes
//// through holder processes on a peer (brazier/presence/holder), diffs are
//// recorded by PubSub recorders on a peer and decoded there. Heartbeats
//// are fast (50ms) and peers go down after 300ms of silence; waiting is
//// always `peer.eventually` with a deadline.

import brazier/cluster/peer.{type Peer, Timeout}
import brazier/presence.{type Presence, Down, Up}
import brazier/presence/holder.{type Holder}
import brazier/presence/sync.{Diff, Entry}
import brazier/pubsub
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/json
import gleam/list
import gleam/string

const wait_ms = 10_000

const name = "pc"

// --- Helpers ----------------------------------------------------------------

fn fast_config() -> presence.PresenceConfig(String) {
  presence.new(name, json.string, decode.string)
  |> presence.broadcast_period(50)
  |> presence.max_silent_periods(2)
  |> presence.down_period(500)
  |> presence.permdown_period(2000)
}

fn start_on(
  p: Peer,
  config: presence.PresenceConfig(String),
) -> Presence(String) {
  peer.on(p, fn() {
    pubsub.start()
    let assert Ok(tracker) = presence.start(config) as "presence.start succeeds"
    tracker
  })
}

fn start_all(
  peers: List(Peer),
  config: presence.PresenceConfig(String),
) -> Presence(String) {
  let trackers = list.map(peers, start_on(_, config))
  // INVARIANT: every node computes the same handle from the same config.
  let assert [tracker, ..] = trackers as "trackers returns a non-empty list"
  tracker
}

/// A holder on `p` that tracks `key` on `topic`.
fn track_on(
  p: Peer,
  tracker: Presence(String),
  topic: String,
  key: String,
  meta: String,
) -> Holder {
  peer.on(p, fn() {
    let h = holder.start()
    let assert Ok(_) =
      holder.run(h, fn() { presence.track(tracker, topic, key, meta) })
      as "presence.track succeeds"
    h
  })
}

fn run_on(p: Peer, h: Holder, run: fn() -> a) -> a {
  peer.on(p, fn() { holder.run(h, run) })
}

/// The keys `p` sees on `topic`, with the node of each meta.
fn seen(
  p: Peer,
  tracker: Presence(String),
  topic: String,
) -> List(#(String, String)) {
  peer.on(p, fn() {
    let assert Ok(entries) = presence.list(tracker, topic)
      as "presence.list succeeds"
    list.flat_map(entries, fn(entry) {
      list.map(entry.metas, fn(meta) { #(entry.key, meta.node) })
    })
  })
}

fn keys(p: Peer, tracker: Presence(String), topic: String) -> List(String) {
  seen(p, tracker, topic) |> list.map(fn(pair) { pair.0 })
}

fn sees(
  p: Peer,
  tracker: Presence(String),
  topic: String,
  expected: List(String),
) -> Bool {
  peer.eventually(fn() { keys(p, tracker, topic) == expected }, wait_ms)
}

fn replicas(
  p: Peer,
  tracker: Presence(String),
) -> List(#(String, presence.ReplicaStatus)) {
  peer.on(p, fn() {
    let assert Ok(replicas) = presence.replicas(tracker, "any")
      as "presence.replicas succeeds"
    replicas
  })
}

fn node_name(p: Peer) -> String {
  atom.to_string(node.name(peer.node(p)))
}

/// A diff recorder on `p` for `topic`.
fn record_diffs(p: Peer, tracker: Presence(String), topic: String) -> Pid {
  peer.on(p, fn() { spawn_recorder([presence.diff_topic(tracker, topic)]) })
}

/// The diffs `recorder` on `p` received, as #(joins, leaves) of
/// `key=value` strings.
fn diffs(
  p: Peer,
  tracker: Presence(String),
  recorder: Pid,
) -> List(#(List(String), List(String))) {
  peer.on(p, fn() {
    recorded(recorder)
    |> list.map(fn(message) {
      let assert Ok(Diff(_, joins, leaves)) =
        presence.decode_diff(tracker, message)
        as "presence.decode_diff succeeds"
      #(flatten(joins), flatten(leaves))
    })
  })
}

fn flatten(entries: List(sync.Entry(String))) -> List(String) {
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(meta) { entry.key <> "=" <> meta.value })
  })
}

// --- Replication ------------------------------------------------------------

/// Entries tracked on any node are listed on every node, with their node,
/// and each node reports the joins to its diff subscribers.
pub fn cross_node_track_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(3, "brazier_pr_cross")
  let assert [a, b, c] = peers as "the cluster starts three peers"
  let tracker = start_all(peers, fast_config())
  let recorder = record_diffs(c, tracker, "room")
  let _ = track_on(a, tracker, "room", "alice", "online")
  let _ = track_on(b, tracker, "room", "bob", "away")

  let expected = [#("alice", node_name(a)), #("bob", node_name(b))]
  list.each(peers, fn(p) {
    assert peer.eventually(
      fn() { seen(p, tracker, "room") == expected },
      wait_ms,
    )
  })
  let joined =
    diffs(c, tracker, recorder)
    |> list.flat_map(fn(diff) { diff.0 })
    |> list.sort(string.compare)
  assert joined == ["alice=online", "bob=away"]
  let assert Ok(Entry("bob", [meta])) =
    peer.on(c, fn() { presence.get_by_key(tracker, "room", "bob") })
    as "presence.get_by_key succeeds"
  assert meta.value == "away"
  assert meta.node == node_name(b)
}

/// A tracked process that exits leaves on every node.
pub fn leave_on_process_exit_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pr_exit")
  let assert [a, b] = peers as "the cluster starts two peers"
  let tracker = start_all(peers, fast_config())
  let h = track_on(a, tracker, "room", "alice", "online")
  assert sees(b, tracker, "room", ["alice"])
  peer.on(a, fn() { holder.kill(h) })
  assert sees(b, tracker, "room", [])
  assert sees(a, tracker, "room", [])
}

/// Changes reach a remote node in the order they were made. Each step
/// waits for the remote node, so no heartbeat carries two of them.
pub fn diffs_arrive_in_order_remotely_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pr_order")
  let assert [a, b] = peers as "the cluster starts two peers"
  let tracker = start_all(peers, fast_config())
  let recorder = record_diffs(b, tracker, "room")
  let h = track_on(a, tracker, "room", "alice", "v1")
  let step = fn(count) {
    assert peer.eventually(
      fn() { list.length(diffs(b, tracker, recorder)) == count },
      wait_ms,
    )
  }
  step(1)
  let assert Ok(_) =
    run_on(a, h, fn() { presence.update(tracker, "room", "alice", "v2") })
    as "presence.update succeeds"
  step(2)
  let assert Ok(_) =
    run_on(a, h, fn() { presence.update(tracker, "room", "alice", "v3") })
    as "presence.update succeeds"
  step(3)
  let assert Ok(Nil) =
    run_on(a, h, fn() { presence.untrack(tracker, "room", "alice") })
    as "presence.untrack succeeds"
  step(4)
  assert diffs(b, tracker, recorder)
    == [
      #(["alice=v1"], []),
      #(["alice=v2"], ["alice=v1"]),
      #(["alice=v3"], ["alice=v2"]),
      #([], ["alice=v3"]),
    ]
}

/// Changes made within one heartbeat reach remote nodes as their final
/// state.
pub fn rapid_changes_converge_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pr_rapid")
  let assert [a, b] = peers as "the cluster starts two peers"
  let tracker = start_all(peers, fast_config())
  let h = track_on(a, tracker, "room", "alice", "v1")
  run_on(a, h, fn() {
    list.each(["v2", "v3", "v4"], fn(value) {
      let assert Ok(_) = presence.update(tracker, "room", "alice", value)
        as "presence.update succeeds"
    })
    let assert Ok(_) = presence.track(tracker, "room", "bob", "b")
      as "presence.track succeeds"
    let assert Ok(Nil) = presence.untrack(tracker, "room", "bob")
      as "presence.untrack succeeds"
    Nil
  })
  assert peer.eventually(
    fn() {
      peer.on(b, fn() { presence.get_by_key(tracker, "room", "alice") })
      |> result_values
      == ["v4"]
    },
    wait_ms,
  )
  assert keys(b, tracker, "room") == ["alice"]
}

fn result_values(
  outcome: Result(sync.Entry(String), presence.PresenceError),
) -> List(String) {
  case outcome {
    Ok(entry) -> list.map(entry.metas, fn(meta) { meta.value })
    Error(_) -> []
  }
}

/// A node that starts later receives what is already tracked through a
/// transfer.
pub fn late_node_receives_a_transfer_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pr_late")
  let assert [a, b] = peers as "the cluster starts two peers"
  let tracker = start_on(a, fast_config())
  let _ = track_on(a, tracker, "room", "alice", "online")
  let _ = track_on(a, tracker, "room", "bob", "online")
  // A's heartbeat has sent these changes, to nobody: B can only get them
  // through a transfer.
  assert peer.eventually(
    fn() { !peer.on(a, fn() { shard_has_delta(tracker, "room") }) },
    wait_ms,
  )
  peer.on(b, fn() { count_events(["brazier", "presence", "transfer", "stop"]) })
  let _ = start_on(b, fast_config())
  assert sees(b, tracker, "room", ["alice", "bob"])
  assert peer.on(b, counted_events) != []
}

fn shard_has_delta(tracker: Presence(String), topic: String) -> Bool {
  let assert Ok(shard) = presence.shard_pid(tracker, topic)
    as "presence.shard_pid succeeds"
  shard_has_delta_ffi(shard)
}

// --- Failures ---------------------------------------------------------------

/// A node that crashes is down after down_period (its entries leave) and
/// permanently down after permdown_period (forgotten).
pub fn crashed_node_goes_down_then_permdown_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(3, "brazier_pr_crash")
  let assert [a, b, c] = peers as "the cluster starts three peers"
  let tracker = start_all(peers, fast_config())
  let _ = track_on(a, tracker, "room", "alice", "online")
  let _ = track_on(c, tracker, "room", "carol", "online")
  assert sees(b, tracker, "room", ["alice", "carol"])
  let recorder = record_diffs(b, tracker, "room")

  peer.crash(c)
  assert sees(b, tracker, "room", ["alice"])
  assert sees(a, tracker, "room", ["alice"])
  assert peer.eventually(
    fn() { list.contains(replicas(b, tracker), #(node_name(c), Down)) },
    wait_ms,
  )
  assert diffs(b, tracker, recorder) == [#([], ["carol=online"])]
  assert peer.eventually(
    fn() { replicas(b, tracker) == [#(node_name(a), Up)] },
    wait_ms,
  )
}

/// During a netsplit each side sees only its own entries; after it heals
/// both sides converge, including changes made during the split.
pub fn netsplit_and_heal_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pr_split")
  let assert [a, b] = peers as "the cluster starts two peers"
  let tracker =
    start_all(peers, fast_config() |> presence.permdown_period(60_000))
  let _ = track_on(a, tracker, "room", "alice", "a")
  let bob = track_on(b, tracker, "room", "bob", "b")
  assert sees(a, tracker, "room", ["alice", "bob"])
  assert sees(b, tracker, "room", ["alice", "bob"])

  peer.partition(a, b)
  assert sees(a, tracker, "room", ["alice"])
  assert sees(b, tracker, "room", ["bob"])
  let _ = track_on(a, tracker, "room", "carol", "c")
  let assert Ok(Nil) =
    run_on(b, bob, fn() { presence.untrack(tracker, "room", "bob") })
    as "presence.untrack succeeds"
  let _ = track_on(b, tracker, "room", "dave", "d")

  peer.heal(a, b)
  assert sees(a, tracker, "room", ["alice", "carol", "dave"])
  assert sees(b, tracker, "room", ["alice", "carol", "dave"])
}

/// A shard that restarts comes back with a new version: peers drop the old
/// version's entries at once, and processes that track again reappear.
pub fn restarted_shard_is_a_new_replica_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pr_restart")
  let assert [a, b] = peers as "the cluster starts two peers"
  // Long periods: only the new version can explain the entries leaving.
  let config =
    fast_config()
    |> presence.down_period(30_000)
    |> presence.permdown_period(60_000)
  let tracker = start_all(peers, config)
  let h = track_on(a, tracker, "room", "alice", "v1")
  assert sees(b, tracker, "room", ["alice"])

  let old =
    peer.on(a, fn() {
      let assert Ok(shard) = presence.shard_pid(tracker, "room")
        as "presence.shard_pid succeeds"
      process.kill(shard)
      shard
    })
  assert peer.eventually(
    fn() {
      peer.on(a, fn() { presence.shard_pid(tracker, "room") }) |> is_new(old)
    },
    wait_ms,
  )
  // The empty new shard heartbeats after max_silent_periods.
  assert sees(b, tracker, "room", [])
  let assert Ok(_) =
    run_on(a, h, fn() { presence.track(tracker, "room", "alice", "v2") })
    as "presence.track succeeds"
  assert sees(b, tracker, "room", ["alice"])
  assert replicas(b, tracker) == [#(node_name(a), Up)]
}

fn is_new(outcome: Result(Pid, presence.PresenceError), old: Pid) -> Bool {
  case outcome {
    Ok(pid) -> pid != old
    Error(_) -> False
  }
}

/// A tracker that stops tells its peers, which drop its entries at once
/// instead of after down_period.
pub fn graceful_stop_drops_entries_at_once_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pr_graceful")
  let assert [a, b] = peers as "the cluster starts two peers"
  let config =
    fast_config()
    |> presence.down_period(30_000)
    |> presence.permdown_period(60_000)
  let tracker = start_all(peers, config)
  let _ = track_on(a, tracker, "room", "alice", "online")
  let _ = track_on(b, tracker, "room", "bob", "online")
  assert sees(b, tracker, "room", ["alice", "bob"])
  assert replicas(b, tracker) == [#(node_name(a), Up)]

  let assert Ok(Nil) = peer.on(a, fn() { presence.stop(tracker) })
    as "presence.stop succeeds"
  assert sees(b, tracker, "room", ["bob"])
  assert replicas(b, tracker) == []
}

// --- Limits -----------------------------------------------------------------

/// Remote entries count towards a shard's entry limit.
pub fn shard_limit_counts_remote_entries_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pr_limit")
  let assert [a, b] = peers as "the cluster starts two peers"
  let tracker =
    start_all(peers, fast_config() |> presence.max_entries_per_shard(2))
  let _ = track_on(a, tracker, "room", "alice", "a")
  let _ = track_on(a, tracker, "room", "bob", "b")
  assert sees(b, tracker, "room", ["alice", "bob"])
  let outcome =
    peer.on(b, fn() {
      let h = holder.start()
      holder.run(h, fn() { presence.track(tracker, "room", "carol", "c") })
    })
  assert outcome
    == Error(presence.PresenceLimitExceeded("max_entries_per_shard"))
}

/// A transfer larger than max_transfer_entries is rejected (and reported)
/// rather than merged.
pub fn oversized_transfer_is_rejected_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pr_transfer")
  let assert [a, b] = peers as "the cluster starts two peers"
  let tracker = start_on(a, fast_config())
  let h = peer.on(a, holder.start)
  run_on(a, h, fn() {
    list.each(["k1", "k2", "k3"], fn(key) {
      let assert Ok(_) = presence.track(tracker, "room", key, "m")
        as "presence.track succeeds"
    })
  })
  // A's heartbeat has sent the changes, to nobody: B can only get them
  // through a transfer.
  assert peer.eventually(
    fn() { !peer.on(a, fn() { shard_has_delta(tracker, "room") }) },
    wait_ms,
  )
  peer.on(b, fn() { count_events(["brazier", "presence", "limit_exceeded"]) })
  let _ = start_on(b, fast_config() |> presence.max_transfer_entries(2))
  assert peer.eventually(
    fn() { peer.on(b, counted_events) |> list.length >= 2 },
    wait_ms,
  )
  // Rejected every time: nothing was merged, though A's keepalives keep
  // it up.
  assert keys(b, tracker, "room") == []
  assert replicas(b, tracker) == [#(node_name(a), Up)]
}

// --- Benchmark --------------------------------------------------------------

/// 10,000 entries tracked across 3 nodes, until every node lists them all.
pub fn presence_convergence_benchmark_test_() -> peer.Timeout {
  use <- Timeout(120)
  use peers <- peer.with_members(3, "brazier_pr_bench")
  let config =
    presence.new(name, json.string, decode.string)
    |> presence.broadcast_period(50)
    |> presence.down_period(5000)
    |> presence.permdown_period(60_000)
    |> presence.max_topics_per_pid(4000)
  let tracker = start_all(peers, config)
  let per_node = 3334
  let total = per_node * 3
  let started = now_us()
  let track_us =
    list.index_map(peers, fn(p, index) {
      peer.on(p, fn() {
        let h = holder.start()
        holder.run(h, fn() {
          let began = now_us()
          int.range(from: 0, to: per_node, with: Nil, run: fn(_, i) {
            let key = int.to_string(index) <> "-" <> int.to_string(i)
            let assert Ok(_) = presence.track(tracker, "bench", key, "m")
              as "presence.track succeeds"
            Nil
          })
          now_us() - began
        })
      })
    })
  assert peer.eventually(
    fn() {
      list.all(peers, fn(p) {
        peer.on(p, fn() {
          let assert Ok(entries) = presence.list(tracker, "bench")
            as "presence.list succeeds"
          list.length(entries)
        })
        == total
      })
    },
    60_000,
  )
  let converged_us = now_us() - started
  let slowest = list.fold(track_us, 0, int.max)
  report(
    "presence: "
    <> int.to_string(total)
    <> " tracks on 3 nodes, slowest node tracked its "
    <> int.to_string(per_node)
    <> " in "
    <> int.to_string(slowest)
    <> "us ("
    <> int.to_string(per_node * 1_000_000 / int.max(slowest, 1))
    <> " tracks/s); every node lists all "
    <> int.to_string(total)
    <> " after "
    <> int.to_string(converged_us / 1000)
    <> "ms",
  )
}

// --- FFI --------------------------------------------------------------------

@external(erlang, "brazier_cluster_test_ffi", "spawn_recorder")
fn spawn_recorder(topics: List(String)) -> Pid

@external(erlang, "brazier_cluster_test_ffi", "recorded")
fn recorded(pid: Pid) -> List(Dynamic)

@external(erlang, "brazier_cluster_test_ffi", "count_events")
fn count_events(event: List(String)) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "counted_events")
fn counted_events() -> List(Int)

@external(erlang, "brazier_presence_test_ffi", "shard_has_delta")
fn shard_has_delta_ffi(shard: Pid) -> Bool

@external(erlang, "brazier_cluster_test_ffi", "now_us")
fn now_us() -> Int

@external(erlang, "brazier_cluster_test_ffi", "report")
fn report(line: String) -> Nil
