//// Single-node presence tests: configuration, tracking, limits, diffs,
//// lifecycle, and the shard's replica handling driven by fake replication
//// messages (see brazier_presence_test_ffi). Real multi-node behaviour is in
//// test/brazier/cluster/presence_cluster_test.gleam.

import brazier/cluster/log_capture
import brazier/presence.{
  type Presence, AlreadyTracked, Down, InvalidConfig, InvalidKey, InvalidMessage,
  InvalidTopic, MetaDecodeFailed, MetaTooLarge, NotTracked,
  PresenceLimitExceeded, StartFailed, TrackerDown, Up,
}
import brazier/presence/holder.{type Holder}
import brazier/presence/sync.{Diff, Entry, Meta}
import brazier/pubsub
import brazier/telemetry
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/string

const wait_ms = 5000

// --- Helpers ----------------------------------------------------------------

type Ref

fn unique_name() -> String {
  "t" <> int.to_string(unique_integer())
}

fn config(name: String) -> presence.PresenceConfig(String) {
  presence.new(name, json.string, decode.string)
}

fn start(config: presence.PresenceConfig(String)) -> Presence(String) {
  pubsub.start()
  let assert Ok(p) = presence.start(config)
  p
}

fn start_default() -> Presence(String) {
  start(config(unique_name()))
}

/// A tracker whose fake peers go down after 100ms and permanently down
/// after 300ms.
fn start_fast(name: String) -> Presence(String) {
  start(
    config(name)
    |> presence.broadcast_period(20)
    |> presence.max_silent_periods(2)
    |> presence.down_period(100)
    |> presence.permdown_period(300),
  )
}

fn track(
  p: Presence(String),
  h: Holder,
  topic: String,
  key: String,
  meta: String,
) -> String {
  let assert Ok(ref) =
    holder.run(h, fn() { presence.track(p, topic, key, meta) })
  ref
}

fn keys(p: Presence(String), topic: String) -> List(String) {
  let assert Ok(entries) = presence.list(p, topic)
  list.map(entries, fn(entry) { entry.key })
}

fn next_diff(p: Presence(String)) -> sync.Diff(String) {
  let assert Ok(message) = receive_diff(wait_ms)
  let assert Ok(diff) = presence.decode_diff(p, message)
  diff
}

fn entry_keys(entries: List(sync.Entry(String))) -> List(String) {
  list.map(entries, fn(entry) { entry.key })
}

fn shard_topic(p: Presence(String)) -> String {
  "brazier_presence:" <> presence.name(p) <> ":1"
}

/// Deliver `message` to the shard as a peer would, and wait until the
/// shard has handled it.
fn send_peer(p: Presence(String), message: Dynamic) -> Nil {
  let assert Ok(shard) = presence.shard_pid(p, "any")
  send_peer_ffi(shard, shard_topic(p), message)
  let _ = replicas(p)
  Nil
}

/// Subscribe the test process to diffs on `topic`. eunit runs tests in one
/// process, so diffs left by an earlier test are dropped first.
fn subscribe(p: Presence(String), topic: String) -> Nil {
  let _ = flush_diffs()
  let assert Ok(Nil) = presence.subscribe(p, topic)
  Nil
}

/// End a test that subscribed to `topic`: unsubscribe and stop the tracker,
/// then check every diff was consumed. Once the tracker has stopped no diff
/// is in flight, and one left in the mailbox would reach a later test.
fn finish(p: Presence(String), topic: String) -> Nil {
  let assert Ok(Nil) = presence.unsubscribe(p, topic)
  let assert Ok(Nil) = presence.stop(p)
  let assert Error(Nil) = receive_diff(0) as "a diff was left unconsumed"
  Nil
}

/// The shard's peers. A call, so every message sent to the shard before
/// it has been handled.
fn replicas(p: Presence(String)) -> List(#(String, presence.ReplicaStatus)) {
  let assert Ok(replicas) = presence.replicas(p, "any")
  replicas
}

fn this_node() -> String {
  atom.to_string(node.name(node.self()))
}

// --- Configuration ----------------------------------------------------------

pub fn invalid_configs_are_rejected_test() {
  let base = config("valid")
  let assert Ok(_) = presence.validate_config(base)
  let invalid = [
    config(""),
    config("Upper"),
    config("has-dash"),
    config(string.repeat("a", 33)),
    presence.pool_size(base, 0),
    presence.pool_size(base, 129),
    presence.broadcast_period(base, 0),
    presence.max_silent_periods(base, 0),
    presence.clock_sample_periods(base, 0),
    presence.max_meta_bytes(base, 0),
    presence.max_topics_per_pid(base, 0),
    presence.max_entries_per_shard(base, -1),
    presence.max_transfer_entries(base, 0),
    // down_period below twice the broadcast period.
    base
      |> presence.broadcast_period(1000)
      |> presence.max_silent_periods(1)
      |> presence.down_period(1999),
    // down_period not longer than the keepalive interval (3000ms).
    base
      |> presence.broadcast_period(1000)
      |> presence.max_silent_periods(2)
      |> presence.down_period(3000),
    // The defaults with a down_period inside the keepalive interval.
    presence.down_period(base, 16_500),
    // permdown_period not longer than down_period.
    base |> presence.down_period(5000) |> presence.permdown_period(5000),
    presence.max_delta_sizes(base, []),
    presence.max_delta_sizes(base, [0, 10]),
    presence.max_delta_sizes(base, [10, 10]),
    presence.max_delta_sizes(base, [100, 10]),
  ]
  list.each(invalid, fn(c) {
    let assert Error(InvalidConfig(_)) = presence.validate_config(c)
    let assert Error(InvalidConfig(_)) = presence.start(c)
    let assert Error(InvalidConfig(_)) = presence.supervised(c)
    let assert Error(InvalidConfig(_)) = presence.handle(c)
  })
  let assert Ok(_) = presence.validate_config(config(string.repeat("a", 32)))
  // Just longer than the keepalive interval.
  let assert Ok(_) =
    base
    |> presence.broadcast_period(1000)
    |> presence.max_silent_periods(2)
    |> presence.down_period(3001)
    |> presence.validate_config
}

pub fn starting_a_running_tracker_twice_fails_test() {
  let name = unique_name()
  let p = start(config(name))
  let #(outcome, lines) =
    log_capture.capture(fn() { presence.start(config(name)) })
  let assert Error(StartFailed(reason)) = outcome
  assert string.contains(reason, "already running")
  assert log_capture.contains(lines, "error", "already running")
  let assert Ok(Nil) = presence.stop(p)
}

// --- Tracking ---------------------------------------------------------------

pub fn track_list_untrack_test() {
  let p = start_default()
  let h = holder.start()
  let ref = track(p, h, "room", "alice", "online")
  assert string.length(ref) == 11

  let assert Ok([Entry("alice", [meta])]) = presence.list(p, "room")
  assert meta == Meta(value: "online", ref:, ref_prev: None, node: this_node())
  let assert Ok(Entry("alice", [_])) = presence.get_by_key(p, "room", "alice")
  let assert Error(NotTracked) = presence.get_by_key(p, "room", "bob")
  let assert Ok([]) = presence.list(p, "other")

  let assert Ok(Nil) =
    holder.run(h, fn() { presence.untrack(p, "room", "alice") })
  let assert Ok([]) = presence.list(p, "room")
  let assert Error(NotTracked) =
    holder.run(h, fn() { presence.untrack(p, "room", "alice") })
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p)
}

pub fn tracking_a_key_twice_is_refused_test() {
  let p = start_default()
  let h = holder.start()
  let _ = track(p, h, "room", "alice", "a")
  let assert Error(AlreadyTracked) =
    holder.run(h, fn() { presence.track(p, "room", "alice", "b") })
  // The same key from another process is a second meta of one entry.
  let other = holder.start()
  let _ = track(p, other, "room", "alice", "c")
  let assert Ok([Entry("alice", metas)]) = presence.list(p, "room")
  assert list.sort(list.map(metas, fn(m) { m.value }), string.compare)
    == ["a", "c"]
  holder.kill(h)
  holder.kill(other)
  let assert Ok(Nil) = presence.stop(p)
}

pub fn list_is_ordered_by_key_test() {
  let p = start_default()
  let h = holder.start()
  list.each(["carol", "alice", "bob"], fn(key) {
    let _ = track(p, h, "room", key, key)
  })
  assert keys(p, "room") == ["alice", "bob", "carol"]
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p)
}

pub fn update_replaces_meta_and_keeps_ref_prev_test() {
  let p = start_default()
  let h = holder.start()
  let first = track(p, h, "room", "alice", "online")
  let assert Ok(second) =
    holder.run(h, fn() { presence.update(p, "room", "alice", "away") })
  assert second != first
  let assert Ok(Entry("alice", [meta])) =
    presence.get_by_key(p, "room", "alice")
  assert meta.value == "away"
  assert meta.ref == second
  assert meta.ref_prev == Some(first)

  let assert Error(NotTracked) =
    holder.run(h, fn() { presence.update(p, "room", "bob", "x") })
  // Another process cannot update this process's entry.
  let assert Error(NotTracked) = presence.update(p, "room", "alice", "x")
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p)
}

pub fn untrack_all_removes_every_topic_test() {
  let p = start(config(unique_name()) |> presence.pool_size(4))
  let h = holder.start()
  let topics = ["a", "b", "c", "d", "e", "f"]
  list.each(topics, fn(topic) {
    let _ = track(p, h, topic, "k", "m")
  })
  list.each(topics, fn(topic) {
    let assert ["k"] = keys(p, topic)
  })
  let assert Ok(Nil) = holder.run(h, fn() { presence.untrack_all(p) })
  list.each(topics, fn(topic) {
    let assert [] = keys(p, topic)
  })
  // Nothing tracked is fine.
  let assert Ok(Nil) = holder.run(h, fn() { presence.untrack_all(p) })
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p)
}

pub fn exited_process_leaves_test() {
  let p = start_default()
  let h = holder.start()
  let stays = holder.start()
  let _ = track(p, h, "room", "alice", "a")
  let _ = track(p, h, "lobby", "alice", "a")
  let _ = track(p, stays, "room", "bob", "b")
  holder.kill(h)
  assert eventually(fn() { keys(p, "room") == ["bob"] }, wait_ms)
  assert eventually(fn() { keys(p, "lobby") == [] }, wait_ms)
  holder.kill(stays)
  assert eventually(fn() { keys(p, "room") == [] }, wait_ms)
  let assert Ok(Nil) = presence.stop(p)
}

// --- Validation and limits --------------------------------------------------

pub fn topic_and_key_are_validated_test() {
  let p = start_default()
  let h = holder.start()
  let max = presence.max_topic_bytes(p)
  assert max == 255 - string.byte_size("presence:" <> presence.name(p) <> ":")
  let longest = string.repeat("t", max)
  let _ = track(p, h, longest, "k", "m")
  let assert Ok(["k"]) = presence.list(p, longest) |> result_keys
  let too_long = longest <> "t"
  let assert Error(InvalidTopic(_)) =
    holder.run(h, fn() { presence.track(p, too_long, "k", "m") })
  let assert Error(InvalidTopic(_)) =
    holder.run(h, fn() { presence.track(p, "", "k", "m") })
  let assert Error(InvalidTopic(_)) = presence.list(p, too_long)
  let assert Error(InvalidTopic(_)) = presence.subscribe(p, "")

  let _ = track(p, h, "room", string.repeat("k", 255), "m")
  let assert Error(InvalidKey(_)) =
    holder.run(h, fn() {
      presence.track(p, "room", string.repeat("k", 256), "m")
    })
  let assert Error(InvalidKey(_)) =
    holder.run(h, fn() { presence.track(p, "room", "", "m") })
  let assert Error(InvalidKey(_)) = presence.get_by_key(p, "room", "")
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p)
}

fn result_keys(
  outcome: Result(List(sync.Entry(String)), presence.PresenceError),
) -> Result(List(String), presence.PresenceError) {
  case outcome {
    Ok(entries) -> Ok(entry_keys(entries))
    Error(error) -> Error(error)
  }
}

pub fn oversized_meta_is_refused_with_telemetry_test() {
  let name = unique_name()
  let p = start(config(name) |> presence.max_meta_bytes(10))
  let assert Ok(Nil) = telemetry.start()
  let events = process.new_subject()
  let id = unique_name()
  let assert Ok(Nil) =
    telemetry.attach(id, [["brazier", "presence", "limit_exceeded"]], fn(event) {
      case telemetry.string(event, "tracker") {
        Ok(tracker) if tracker == name -> process.send(events, event)
        _ -> Nil
      }
    })
  let h = holder.start()
  // "12345678" encodes as 10 bytes with its quotes: the limit is inclusive.
  let _ = track(p, h, "room", "fits", "12345678")
  let assert Error(MetaTooLarge(11)) =
    holder.run(h, fn() { presence.track(p, "room", "big", "123456789") })
  let assert Error(MetaTooLarge(11)) =
    holder.run(h, fn() { presence.update(p, "room", "fits", "123456789") })
  let assert Ok(event) = process.receive(events, wait_ms)
  let assert Ok(1) = telemetry.int(event, "count")
  assert keys(p, "room") == ["fits"]
  let assert Ok(Nil) = telemetry.detach(id)
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p)
}

pub fn meta_that_does_not_decode_is_refused_test() {
  pubsub.start()
  let assert Ok(p) =
    presence.start(presence.new(
      unique_name(),
      fn(meta: String) { json.int(string.length(meta)) },
      decode.string,
    ))
  let h = holder.start()
  let assert Error(MetaDecodeFailed(_)) =
    holder.run(h, fn() { presence.track(p, "room", "alice", "online") })
  let assert Ok([]) = presence.list(p, "room")
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p)
}

pub fn per_process_limit_test() {
  let p = start(config(unique_name()) |> presence.max_topics_per_pid(2))
  let h = holder.start()
  let _ = track(p, h, "a", "k", "m")
  let _ = track(p, h, "b", "k", "m")
  let #(outcome, lines) =
    log_capture.capture(fn() {
      holder.run(h, fn() { presence.track(p, "c", "k", "m") })
    })
  let assert Error(PresenceLimitExceeded("max_topics_per_pid")) = outcome
  assert log_capture.contains(lines, "warning", "max_topics_per_pid")
  // Another process has its own allowance.
  let other = holder.start()
  let _ = track(p, other, "c", "k", "m")
  // Untracking frees a slot.
  let assert Ok(Nil) = holder.run(h, fn() { presence.untrack(p, "a", "k") })
  let _ = track(p, h, "c", "k2", "m")
  holder.kill(h)
  holder.kill(other)
  let assert Ok(Nil) = presence.stop(p)
}

pub fn per_shard_limit_test() {
  let p = start(config(unique_name()) |> presence.max_entries_per_shard(2))
  let a = holder.start()
  let b = holder.start()
  let c = holder.start()
  let _ = track(p, a, "room", "a", "m")
  let _ = track(p, b, "room", "b", "m")
  let assert Error(PresenceLimitExceeded("max_entries_per_shard")) =
    holder.run(c, fn() { presence.track(p, "room", "c", "m") })
  holder.kill(a)
  assert eventually(fn() { keys(p, "room") == ["b"] }, wait_ms)
  let _ = track(p, c, "room", "c", "m")
  holder.kill(b)
  holder.kill(c)
  let assert Ok(Nil) = presence.stop(p)
}

// --- Diffs ------------------------------------------------------------------

pub fn diffs_arrive_in_order_test() {
  let p = start_default()
  subscribe(p, "room")
  let h = holder.start()
  let first = track(p, h, "room", "alice", "online")
  let assert Ok(second) =
    holder.run(h, fn() { presence.update(p, "room", "alice", "away") })
  let _ = track(p, h, "room", "bob", "online")
  let assert Ok(Nil) =
    holder.run(h, fn() { presence.untrack(p, "room", "bob") })
  holder.kill(h)

  let assert Diff("room", [Entry("alice", [join])], []) = next_diff(p)
  assert join.ref == first
  let assert Diff("room", [Entry("alice", [updated])], [Entry("alice", [old])]) =
    next_diff(p)
  assert updated.value == "away"
  assert updated.ref == second
  assert updated.ref_prev == Some(first)
  assert old.value == "online"
  let assert Diff("room", [Entry("bob", _)], []) = next_diff(p)
  let assert Diff("room", [], [Entry("bob", _)]) = next_diff(p)
  let assert Diff("room", [], [Entry("alice", _)]) = next_diff(p)
  finish(p, "room")
}

pub fn diffs_are_per_topic_test() {
  let p = start_default()
  subscribe(p, "room")
  let h = holder.start()
  let _ = track(p, h, "lobby", "alice", "m")
  let _ = track(p, h, "room", "bob", "m")
  let assert Diff("room", [Entry("bob", _)], []) = next_diff(p)
  // An exit with entries on two topics reports one diff per topic.
  holder.kill(h)
  let assert Diff("room", [], [Entry("bob", _)]) = next_diff(p)
  // No diff for "lobby" reached this subscriber.
  finish(p, "room")
}

pub fn decode_diff_rejects_other_messages_test() {
  let p = start_default()
  let other = start_default()
  subscribe(other, "room")
  let h = holder.start()
  let _ = track(other, h, "room", "alice", "m")
  let assert Ok(message) = receive_diff(wait_ms)
  // A diff of another tracker.
  let assert Error(InvalidMessage) = presence.decode_diff(p, message)
  let assert Ok(_) = presence.decode_diff(other, message)
  let assert Error(InvalidMessage) =
    presence.decode_diff(p, dynamic.string("nope"))
  holder.kill(h)
  let assert Diff("room", [], [Entry("alice", _)]) = next_diff(other)
  let assert Ok(Nil) = presence.stop(p)
  finish(other, "room")
}

// --- merge ------------------------------------------------------------------

fn meta(value: String, ref: String) -> sync.Meta(String) {
  Meta(value:, ref:, ref_prev: None, node: "n@host")
}

/// key=value@ref, in order.
fn view(entries: List(sync.Entry(String))) -> List(String) {
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(m) { entry.key <> "=" <> m.value <> "@" <> m.ref })
  })
}

pub fn merge_adds_joins_sorted_by_key_test() {
  let diff =
    Diff(
      "room",
      [Entry("carol", [meta("x", "3")]), Entry("alice", [meta("y", "1")])],
      [],
    )
  let assert ["alice=y@1", "carol=x@3"] = view(sync.merge([], diff))
}

pub fn merge_is_idempotent_test() {
  let diff =
    Diff("room", [Entry("alice", [meta("a", "1"), meta("b", "2")])], [
      Entry("bob", [meta("c", "9")]),
    ])
  let start = [Entry("bob", [meta("c", "9")])]
  let once = sync.merge(start, diff)
  let assert ["alice=a@1", "alice=b@2"] = view(once)
  let assert True = sync.merge(once, diff) == once
}

/// An update arrives as a join of the new ref and a leave of the old one in
/// one diff: the joins apply first, so the key never disappears.
pub fn merge_applies_joins_then_leaves_test() {
  let start = [Entry("alice", [meta("here", "1")])]
  let diff =
    Diff("room", [Entry("alice", [meta("away", "2")])], [
      Entry("alice", [meta("here", "1")]),
    ])
  let assert ["alice=away@2"] = view(sync.merge(start, diff))
  // A join and leave of the same ref in one diff leaves nothing.
  let flap =
    Diff("room", [Entry("bob", [meta("x", "5")])], [
      Entry("bob", [meta("x", "5")]),
    ])
  let assert ["alice=here@1"] = view(sync.merge(start, flap))
}

pub fn merge_drops_keys_without_metas_test() {
  let start = [
    Entry("alice", [meta("a", "1"), meta("b", "2")]),
    Entry("bob", [meta("c", "3")]),
  ]
  let diff =
    Diff("room", [], [
      Entry("alice", [meta("a", "1")]),
      Entry("bob", [meta("c", "3")]),
      Entry("zed", [meta("unknown", "99")]),
    ])
  let merged = sync.merge(start, diff)
  let assert ["alice=b@2"] = view(merged)
  let assert [Entry("alice", [_])] = merged
}

// --- Lifecycle --------------------------------------------------------------

pub fn stopped_tracker_is_down_test() {
  let p = start_default()
  let h = holder.start()
  let _ = track(p, h, "room", "alice", "m")
  let assert Ok(Nil) = presence.stop(p)
  let assert Error(TrackerDown) =
    holder.run(h, fn() { presence.track(p, "room", "bob", "m") })
  let assert Error(TrackerDown) = presence.list(p, "room")
  let assert Error(TrackerDown) = presence.get_by_key(p, "room", "alice")
  let assert Error(TrackerDown) = presence.shard_pid(p, "room")
  let assert Error(TrackerDown) =
    holder.run(h, fn() { presence.untrack_all(p) })
  let assert Error(TrackerDown) = presence.stop(p)
  holder.kill(h)
}

pub fn restarted_shard_starts_empty_test() {
  let p = start_default()
  let h = holder.start()
  let _ = track(p, h, "room", "alice", "m")
  let assert Ok(shard) = presence.shard_pid(p, "room")
  process.kill(shard)
  assert eventually(
    fn() {
      case presence.shard_pid(p, "room") {
        Ok(new) -> new != shard
        Error(_) -> False
      }
    },
    wait_ms,
  )
  assert eventually(fn() { presence.list(p, "room") == Ok([]) }, wait_ms)
  // The holder tracks again, as the runtime does after a shard restart.
  let _ = track(p, h, "room", "alice", "m")
  assert keys(p, "room") == ["alice"]
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p)
}

pub fn supervised_tracker_test() {
  pubsub.start()
  let c = config(unique_name())
  let assert Ok(p) = presence.handle(c)
  let assert Error(TrackerDown) = presence.list(p, "room")
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(child) = presence.supervised(c)
      let assert Ok(_) =
        supervisor.new(supervisor.OneForOne)
        |> supervisor.add(child)
        |> supervisor.start
      process.send(ready, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(ready, wait_ms)
  let h = holder.start()
  let _ = track(p, h, "room", "alice", "m")
  assert keys(p, "room") == ["alice"]
  holder.kill(h)
  process.kill(owner)
  assert eventually(
    fn() { presence.list(p, "room") == Error(TrackerDown) },
    wait_ms,
  )
}

// --- Replicas (fake peers) --------------------------------------------------

pub fn remote_entries_join_go_down_and_permdown_test() {
  let p = start_fast(unique_name())
  subscribe(p, "room")
  let ref = fake_ref("fake@host", 1)
  send_peer(p, transfer_ack(ref, 1, "room", [#("remote", "\"hi\"")]))
  assert replicas(p) == [#("fake@host", Up)]
  let assert Ok([Entry("remote", [meta])]) = presence.list(p, "room")
  assert meta
    == Meta(value: "hi", ref: "fake-remote", ref_prev: None, node: "fake@host")
  let assert Diff("room", [Entry("remote", _)], []) = next_diff(p)

  // No heartbeats: down after 100ms (entries leave), forgotten after 300ms.
  assert eventually(fn() { replicas(p) == [#("fake@host", Down)] }, wait_ms)
  let assert Ok([]) = presence.list(p, "room")
  let assert Diff("room", [], [Entry("remote", _)]) = next_diff(p)
  assert eventually(fn() { replicas(p) == [] }, wait_ms)
  finish(p, "room")
}

pub fn heartbeat_brings_a_down_replica_back_test() {
  let p =
    start(
      config(unique_name())
      |> presence.broadcast_period(20)
      |> presence.max_silent_periods(2)
      |> presence.down_period(100)
      |> presence.permdown_period(60_000),
    )
  let ref = fake_ref("fake@host", 1)
  send_peer(p, transfer_ack(ref, 1, "room", [#("remote", "\"hi\"")]))
  assert eventually(fn() { replicas(p) == [#("fake@host", Down)] }, wait_ms)
  let assert Ok([]) = presence.list(p, "room")
  send_peer(p, heartbeat(ref, 1))
  assert replicas(p) == [#("fake@host", Up)]
  assert keys(p, "room") == ["remote"]
  let assert Ok(Nil) = presence.stop(p)
}

pub fn graceful_permdown_drops_entries_at_once_test() {
  let p = start(config(unique_name()))
  let ref = fake_ref("fake@host", 1)
  send_peer(p, transfer_ack(ref, 1, "room", [#("remote", "\"hi\"")]))
  assert keys(p, "room") == ["remote"]
  // A graceful_permdown from another version is ignored.
  send_peer(p, graceful_permdown(fake_ref("fake@host", 2), 1))
  assert replicas(p) == [#("fake@host", Up)]
  send_peer(p, graceful_permdown(ref, 1))
  assert replicas(p) == []
  let assert Ok([]) = presence.list(p, "room")
  let assert Ok(Nil) = presence.stop(p)
}

pub fn new_version_replaces_the_old_replica_test() {
  let p = start(config(unique_name()))
  subscribe(p, "room")
  send_peer(
    p,
    transfer_ack(fake_ref("fake@host", 1), 1, "room", [#("old", "\"a\"")]),
  )
  let assert Diff("room", [Entry("old", _)], []) = next_diff(p)
  // The node's shard restarted: its old entries leave at once.
  send_peer(p, heartbeat(fake_ref("fake@host", 2), 1))
  let assert Diff("room", [], [Entry("old", _)]) = next_diff(p)
  assert replicas(p) == [#("fake@host", Up)]
  let assert Ok([]) = presence.list(p, "room")
  send_peer(
    p,
    transfer_ack(fake_ref("fake@host", 2), 1, "room", [#("new", "\"b\"")]),
  )
  let assert Diff("room", [Entry("new", _)], []) = next_diff(p)
  assert keys(p, "room") == ["new"]
  finish(p, "room")
}

pub fn pool_size_mismatch_is_ignored_and_logged_once_test() {
  let p = start(config(unique_name()))
  let ref = fake_ref("fake@host", 1)
  let #(_, lines) =
    log_capture.capture(fn() {
      send_peer(p, heartbeat(ref, 3))
      send_peer(p, transfer_ack(ref, 3, "room", [#("remote", "\"hi\"")]))
      replicas(p)
    })
  assert replicas(p) == []
  let assert Ok([]) = presence.list(p, "room")
  let mismatches =
    list.filter(lines, fn(line) {
      line.level == "error" && string.contains(line.message, "pool size")
    })
  assert list.length(mismatches) == 1
  let assert Ok(Nil) = presence.stop(p)
}

pub fn oversized_transfer_is_rejected_test() {
  let p = start(config(unique_name()) |> presence.max_transfer_entries(2))
  let ref = fake_ref("fake@host", 1)
  let #(_, lines) =
    log_capture.capture(fn() {
      send_peer(
        p,
        transfer_ack(ref, 1, "room", [
          #("a", "\"1\""),
          #("b", "\"2\""),
          #("c", "\"3\""),
        ]),
      )
      replicas(p)
    })
  assert log_capture.contains(
    lines,
    "error",
    "rejected a transfer of 3 entries",
  )
  assert replicas(p) == []
  let assert Ok([]) = presence.list(p, "room")
  send_peer(p, transfer_ack(ref, 1, "room", [#("a", "\"1\""), #("b", "\"2\"")]))
  assert keys(p, "room") == ["a", "b"]
  let assert Ok(Nil) = presence.stop(p)
}

pub fn malformed_peer_messages_are_logged_test() {
  let p = start(config(unique_name()))
  let #(_, lines) =
    log_capture.capture(fn() {
      list.each(malformed_messages(), send_peer(p, _))
      replicas(p)
    })
  let unexpected =
    list.filter(lines, fn(line) {
      line.level == "warning"
      && string.contains(line.message, "unexpected replication message")
    })
  assert list.length(unexpected) == list.length(malformed_messages())
  assert replicas(p) == []
  let assert Ok(Nil) = presence.stop(p)
}

// --- FFI --------------------------------------------------------------------

@external(erlang, "brazier_presence_test_ffi", "fake_ref")
fn fake_ref(node: String, vsn: Int) -> Ref

@external(erlang, "brazier_presence_test_ffi", "heartbeat")
fn heartbeat(ref: Ref, pool_size: Int) -> Dynamic

@external(erlang, "brazier_presence_test_ffi", "transfer_ack")
fn transfer_ack(
  ref: Ref,
  pool_size: Int,
  topic: String,
  entries: List(#(String, String)),
) -> Dynamic

@external(erlang, "brazier_presence_test_ffi", "graceful_permdown")
fn graceful_permdown(ref: Ref, pool_size: Int) -> Dynamic

@external(erlang, "brazier_presence_test_ffi", "send_peer")
fn send_peer_ffi(shard: process.Pid, topic: String, message: Dynamic) -> Nil

@external(erlang, "brazier_presence_test_ffi", "flush_diffs")
fn flush_diffs() -> Int

@external(erlang, "brazier_presence_test_ffi", "receive_diff")
fn receive_diff(timeout_ms: Int) -> Result(Dynamic, Nil)

@external(erlang, "brazier_presence_test_ffi", "unique_positive")
fn unique_integer() -> Int

@external(erlang, "brazier_presence_test_ffi", "malformed_messages")
fn malformed_messages() -> List(Dynamic)

@external(erlang, "brazier_pubsub_test_ffi", "pause")
fn pause(ms: Int) -> Nil

/// Poll `check` every 5ms until it holds or `timeout_ms` passes.
fn eventually(check: fn() -> Bool, timeout_ms: Int) -> Bool {
  case check() {
    True -> True
    False ->
      case timeout_ms <= 0 {
        True -> False
        False -> {
          pause(5)
          eventually(check, timeout_ms - 5)
        }
      }
  }
}
