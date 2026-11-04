//// Multi-node presence tests (design test matrix, "Presence" rows).
////
//// Every node runs PubSub and a tracker with the same name. Tracking goes
//// through holder processes on a peer (brazier/presence/holder); diffs and
//// telemetry are relayed to holders on a peer (brazier/cluster/relay) and
//// taken one at a time. Heartbeats are fast (50ms) and peers go down after
//// 300ms of silence.
////
//// Nothing here polls. A wait is `peer.until` on what announces the
//// change: the diffs a shard reports after writing its table, the replica
//// events a shard emits while it changes a replica's status, a shard's own
//// heartbeat tick, a supervisor handling its shard's exit.

import brazier/await
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/cluster/relay
import brazier/presence.{type Presence, Down, Up}
import brazier/presence/holder.{type Holder}
import brazier/presence/sync.{Diff, Entry}
import brazier/presence/wake
import brazier/pubsub
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

/// The keys this node sees on `topic`, with the node of each meta.
fn listed(tracker: Presence(String), topic: String) -> List(#(String, String)) {
  let assert Ok(entries) = presence.list(tracker, topic)
    as "presence.list succeeds"
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(meta) { #(entry.key, meta.node) })
  })
}

fn listed_keys(tracker: Presence(String), topic: String) -> List(String) {
  listed(tracker, topic) |> list.map(fn(pair) { pair.0 })
}

fn keys(p: Peer, tracker: Presence(String), topic: String) -> List(String) {
  peer.on(p, fn() { listed_keys(tracker, topic) })
}

/// Whether `p` comes to list `expected` on `topic`, re-checked on each diff
/// it reports there.
fn sees(
  p: Peer,
  tracker: Presence(String),
  topic: String,
  expected: List(String),
) -> Bool {
  peer.until(
    p,
    wake.diffs(tracker, topic),
    fn() { listed_keys(tracker, topic) == expected },
    wait_ms,
  )
}

fn replicas_here(
  tracker: Presence(String),
) -> List(#(String, presence.ReplicaStatus)) {
  let assert Ok(replicas) = presence.replicas(tracker, "any")
    as "presence.replicas succeeds"
  replicas
}

fn replicas(
  p: Peer,
  tracker: Presence(String),
) -> List(#(String, presence.ReplicaStatus)) {
  peer.on(p, fn() { replicas_here(tracker) })
}

/// Whether `p`'s replicas come to satisfy `holds`, re-checked on each
/// replica status change there.
fn replicas_reach(
  p: Peer,
  tracker: Presence(String),
  holds: fn(List(#(String, presence.ReplicaStatus))) -> Bool,
) -> Bool {
  peer.until(
    p,
    wake.replica_changes(),
    fn() { holds(replicas_here(tracker)) },
    wait_ms,
  )
}

fn node_name(p: Peer) -> String {
  atom.to_string(node.name(peer.node(p)))
}

fn shard(tracker: Presence(String), topic: String) -> Pid {
  let assert Ok(shard) = presence.shard_pid(tracker, topic)
    as "presence.shard_pid succeeds"
  shard
}

/// Whether `p`'s shard for `topic` comes to have sent every change in a
/// heartbeat, re-checked on each heartbeat tick. `shard_has_delta` reads
/// the state through the shard, which answers after handling the tick.
fn delta_sent(p: Peer, tracker: Presence(String), topic: String) -> Bool {
  let shard = peer.on(p, fn() { shard(tracker, topic) })
  peer.until(
    p,
    peer.info(shard, "heartbeat"),
    fn() { !shard_has_delta(shard) },
    wait_ms,
  )
}

/// A relay on `p` of the diffs it reports on `topic`.
fn record_diffs(
  p: Peer,
  tracker: Presence(String),
  topic: String,
) -> relay.Deliveries {
  relay.deliveries(p, [presence.diff_topic(tracker, topic)])
}

/// The next diff `recorder` on `p` receives, as #(joins, leaves) of
/// `key=value` strings.
fn next_diff(
  p: Peer,
  tracker: Presence(String),
  recorder: relay.Deliveries,
) -> Result(#(List(String), List(String)), Nil) {
  relay.next_delivery(p, recorder, wait_ms, fn(message) {
    let assert Ok(Diff(_, joins, leaves)) =
      presence.decode_diff(tracker, message)
      as "presence.decode_diff succeeds"
    #(flatten(joins), flatten(leaves))
  })
}

/// The joins of the diffs `recorder` on `p` receives, taken until there
/// are `count` of them.
fn joins(
  p: Peer,
  tracker: Presence(String),
  recorder: relay.Deliveries,
  count: Int,
) -> List(String) {
  case count <= 0 {
    True -> []
    False -> {
      let assert Ok(#(joined, [])) = next_diff(p, tracker, recorder)
        as "a diff of joins arrives"
      list.append(
        joined,
        joins(p, tracker, recorder, count - list.length(joined)),
      )
    }
  }
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
    assert peer.until(
      p,
      wake.diffs(tracker, "room"),
      fn() { listed(tracker, "room") == expected },
      wait_ms,
    )
  })
  let joined = joins(c, tracker, recorder, 2) |> list.sort(string.compare)
  assert joined == ["alice=online", "bob=away"]
  assert relay.pending_deliveries(c, recorder) == 0
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
  assert next_diff(b, tracker, recorder) == Ok(#(["alice=v1"], []))
  let assert Ok(_) =
    run_on(a, h, fn() { presence.update(tracker, "room", "alice", "v2") })
    as "presence.update succeeds"
  assert next_diff(b, tracker, recorder) == Ok(#(["alice=v2"], ["alice=v1"]))
  let assert Ok(_) =
    run_on(a, h, fn() { presence.update(tracker, "room", "alice", "v3") })
    as "presence.update succeeds"
  assert next_diff(b, tracker, recorder) == Ok(#(["alice=v3"], ["alice=v2"]))
  let assert Ok(Nil) =
    run_on(a, h, fn() { presence.untrack(tracker, "room", "alice") })
    as "presence.untrack succeeds"
  assert next_diff(b, tracker, recorder) == Ok(#([], ["alice=v3"]))
  assert relay.pending_deliveries(b, recorder) == 0
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
  assert peer.until(
    b,
    wake.diffs(tracker, "room"),
    fn() {
      presence.get_by_key(tracker, "room", "alice") |> result_values == ["v4"]
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
  assert delta_sent(a, tracker, "room")
  let transfers = relay.events(b, [["brazier", "presence", "transfer", "stop"]])
  let _ = start_on(b, fast_config())
  assert sees(b, tracker, "room", ["alice", "bob"])
  // The span's stop event follows the merge that reported the joins.
  let assert Ok(_) = relay.next_event(b, transfers, wait_ms)
    as "B merges a transfer"
  Nil
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

  let a_name = node_name(a)
  let c_name = node_name(c)
  peer.crash(c)
  assert sees(b, tracker, "room", ["alice"])
  assert sees(a, tracker, "room", ["alice"])
  assert replicas_reach(b, tracker, list.contains(_, #(c_name, Down)))
  assert next_diff(b, tracker, recorder) == Ok(#([], ["carol=online"]))
  assert replicas_reach(b, tracker, fn(r) { r == [#(a_name, Up)] })
  // Permanently down reports nothing more: carol had already left.
  assert relay.pending_deliveries(b, recorder) == 0
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

  peer.on_within(a, await.deadline_ms + 10_000, fn() {
    let old = shard(tracker, "room")
    // The supervisor restarts the shard while handling its 'EXIT', and the
    // new shard registers in its init, before the supervisor goes on.
    let supervisor = parent(old)
    {
      use restart <- await.with_watch_exit(supervisor, old)
      process.kill(old)
      await.expect_info(
        restart,
        supervisor,
        "the supervisor restarting the shard",
      )
    }
    assert shard(tracker, "room") != old
  })
  // The empty new shard heartbeats after max_silent_periods.
  assert sees(b, tracker, "room", [])
  let assert Ok(_) =
    run_on(a, h, fn() { presence.track(tracker, "room", "alice", "v2") })
    as "presence.track succeeds"
  assert sees(b, tracker, "room", ["alice"])
  assert replicas(b, tracker) == [#(node_name(a), Up)]
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
  // The shard forgets the replica while handling the message whose diff
  // reports alice leaving, so the replicas call after it sees none.
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
  assert delta_sent(a, tracker, "room")
  let limits = relay.events(b, [["brazier", "presence", "limit_exceeded"]])
  let _ = start_on(b, fast_config() |> presence.max_transfer_entries(2))
  let assert Ok(_) = relay.next_event(b, limits, wait_ms)
    as "B rejects the transfer"
  let assert Ok(_) = relay.next_event(b, limits, wait_ms)
    as "B rejects the transfer again"
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
  assert list.all(peers, fn(p) {
    peer.until(
      p,
      wake.diffs(tracker, "bench"),
      fn() {
        let assert Ok(entries) = presence.list(tracker, "bench")
          as "presence.list succeeds"
        list.length(entries) == total
      },
      60_000,
    )
  })
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

@external(erlang, "brazier_presence_test_ffi", "shard_has_delta")
fn shard_has_delta(shard: Pid) -> Bool

/// The process that started `pid` (its supervisor, for a shard).
@external(erlang, "brazier_presence_test_ffi", "parent")
fn parent(pid: Pid) -> Pid

@external(erlang, "brazier_cluster_test_ffi", "now_us")
fn now_us() -> Int

@external(erlang, "brazier_cluster_test_ffi", "report")
fn report(line: String) -> Nil
