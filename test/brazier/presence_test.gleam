//// Single-node presence tests: configuration, tracking, limits, diffs,
//// lifecycle, and the shard's replica handling driven by fake replication
//// messages (see brazier_presence_test_ffi). Real multi-node behaviour is in
//// test/brazier/cluster/presence_cluster_test.gleam.
////
//// A test that has messages delivered to the test process (diffs, sys hook
//// notices) runs in a process of its own (monitored.isolated): eunit runs
//// every test of this module in one process, so a failure would leave its
//// subscription or hook feeding that process for the tests after it.
//// Nothing polls: a test waits for the shard to handle the DOWN, EXIT or
//// heartbeat tick that changes what it checks.

import brazier/await
import brazier/cluster/log_capture
import brazier/monitored
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
  let assert Ok(p) = presence.start(config) as "presence.start succeeds"
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
    as "holder.run succeeds"
  ref
}

fn keys(p: Presence(String), topic: String) -> List(String) {
  let assert Ok(entries) = presence.list(p, topic) as "presence.list succeeds"
  list.map(entries, fn(entry) { entry.key })
}

fn next_diff(p: Presence(String)) -> sync.Diff(String) {
  let assert Ok(message) = receive_diff(wait_ms) as "receive_diff succeeds"
  let assert Ok(diff) = presence.decode_diff(p, message)
    as "presence.decode_diff succeeds"
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
    as "presence.shard_pid succeeds"
  send_peer_ffi(shard, shard_topic(p), message)
  let _ = replicas(p)
  Nil
}

/// Subscribe the test process to diffs on `topic`. Only isolated tests
/// subscribe, so no diff can be waiting yet; one that is was left by
/// another test and fails this one loudly instead of being dropped.
fn subscribe(p: Presence(String), topic: String) -> Nil {
  let assert Error(Nil) = receive_diff(0)
    as "a diff from before this test was in the test process's mailbox"
  let assert Ok(Nil) = presence.subscribe(p, topic)
    as "presence.subscribe succeeds"
  Nil
}

/// The single shard of a tracker with the default pool size of 1, which
/// holds every topic.
fn only_shard(p: Presence(String)) -> process.Pid {
  let assert Ok(shard) = presence.shard_pid(p, "any")
    as "presence.shard_pid succeeds"
  shard
}

/// Kill `h` and return once the shard has handled the DOWN of its monitor
/// on it, so its entries are gone. The tracker must have one shard.
fn kill_and_await_leave(p: Presence(String), h: Holder) -> Nil {
  let shard = only_shard(p)
  use down <- await.with_watch_down(shard, h.pid)
  holder.kill(h)
  await.expect_info(down, shard, "the shard handling the holder's DOWN")
}

/// A fast tracker's heartbeat ticks, every 20 ms: the bound for a test that
/// waits tick by tick for a replica to go down.
const max_ticks = 250

/// Return once the shard's replicas are `expected`, checking after each of
/// its heartbeat ticks (replicas go down and are forgotten on a tick).
fn await_replicas(
  p: Presence(String),
  tick: await.InfoWatch,
  expected: List(#(String, presence.ReplicaStatus)),
  what: String,
) -> Nil {
  await.until_info(
    tick,
    only_shard(p),
    fn() { replicas(p) == expected },
    max_ticks,
    what,
  )
}

/// End a test that subscribed to `topic`: unsubscribe and stop the tracker,
/// then check every diff was consumed. Once the tracker has stopped no diff
/// is in flight, and one left in the mailbox would reach a later test.
fn finish(p: Presence(String), topic: String) -> Nil {
  let assert Ok(Nil) = presence.unsubscribe(p, topic)
    as "presence.unsubscribe succeeds"
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
  let assert Error(Nil) = receive_diff(0) as "a diff was left unconsumed"
  Nil
}

/// The shard's peers. A call, so every message sent to the shard before
/// it has been handled.
fn replicas(p: Presence(String)) -> List(#(String, presence.ReplicaStatus)) {
  let assert Ok(replicas) = presence.replicas(p, "any")
    as "presence.replicas succeeds"
  replicas
}

fn this_node() -> String {
  atom.to_string(node.name(node.self()))
}

// --- Configuration ----------------------------------------------------------

pub fn invalid_configs_are_rejected_test() {
  let base = config("valid")
  let assert Ok(_) = presence.validate_config(base)
    as "presence.validate_config succeeds"
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
      as "presence.validate_config returns Error(InvalidConfig(_))"
    let assert Error(InvalidConfig(_)) = presence.start(c)
      as "presence.start returns Error(InvalidConfig(_))"
    let assert Error(InvalidConfig(_)) = presence.supervised(c)
      as "presence.supervised returns Error(InvalidConfig(_))"
    let assert Error(InvalidConfig(_)) = presence.handle(c)
      as "presence.handle returns Error(InvalidConfig(_))"
  })
  let assert Ok(_) = presence.validate_config(config(string.repeat("a", 32)))
    as "presence.validate_config succeeds"
  // Just longer than the keepalive interval.
  let assert Ok(_) =
    base
    |> presence.broadcast_period(1000)
    |> presence.max_silent_periods(2)
    |> presence.down_period(3001)
    |> presence.validate_config
    as "base is Ok"
}

pub fn starting_a_running_tracker_twice_fails_test() {
  let name = unique_name()
  let p = start(config(name))
  let #(outcome, lines) =
    log_capture.capture(fn() { presence.start(config(name)) })
  let assert Error(StartFailed(reason)) = outcome
    as "outcome is Error(StartFailed(reason))"
  assert string.contains(reason, "already running")
  assert log_capture.contains(lines, "error", "already running")
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

// --- Tracking ---------------------------------------------------------------

pub fn track_list_untrack_test() {
  let p = start_default()
  use h <- holder.with_holder
  let ref = track(p, h, "room", "alice", "online")
  assert string.length(ref) == 11

  let assert Ok([Entry("alice", [meta])]) = presence.list(p, "room")
    as "presence.list succeeds"
  assert meta == Meta(value: "online", ref:, ref_prev: None, node: this_node())
  let assert Ok(Entry("alice", [_])) = presence.get_by_key(p, "room", "alice")
    as "presence.get_by_key succeeds"
  let assert Error(NotTracked) = presence.get_by_key(p, "room", "bob")
    as "presence.get_by_key returns Error(NotTracked)"
  let assert Ok([]) = presence.list(p, "other") as "presence.list succeeds"

  let assert Ok(Nil) =
    holder.run(h, fn() { presence.untrack(p, "room", "alice") })
    as "holder.run succeeds"
  let assert Ok([]) = presence.list(p, "room") as "presence.list succeeds"
  let assert Error(NotTracked) =
    holder.run(h, fn() { presence.untrack(p, "room", "alice") })
    as "holder.run returns Error(NotTracked)"
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn tracking_a_key_twice_is_refused_test() {
  let p = start_default()
  use h <- holder.with_holder
  let _ = track(p, h, "room", "alice", "a")
  let assert Error(AlreadyTracked) =
    holder.run(h, fn() { presence.track(p, "room", "alice", "b") })
    as "holder.run returns Error(AlreadyTracked)"
  // The same key from another process is a second meta of one entry.
  use other <- holder.with_holder
  let _ = track(p, other, "room", "alice", "c")
  let assert Ok([Entry("alice", metas)]) = presence.list(p, "room")
    as "presence.list succeeds"
  assert list.sort(list.map(metas, fn(m) { m.value }), string.compare)
    == ["a", "c"]
  holder.kill(h)
  holder.kill(other)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn list_is_ordered_by_key_test() {
  let p = start_default()
  use h <- holder.with_holder
  list.each(["carol", "alice", "bob"], fn(key) {
    let _ = track(p, h, "room", key, key)
  })
  assert keys(p, "room") == ["alice", "bob", "carol"]
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn update_replaces_meta_and_keeps_ref_prev_test() {
  let p = start_default()
  use h <- holder.with_holder
  let first = track(p, h, "room", "alice", "online")
  let assert Ok(second) =
    holder.run(h, fn() { presence.update(p, "room", "alice", "away") })
    as "holder.run succeeds"
  assert second != first
  let assert Ok(Entry("alice", [meta])) =
    presence.get_by_key(p, "room", "alice")
    as "presence.get_by_key succeeds"
  assert meta.value == "away"
  assert meta.ref == second
  assert meta.ref_prev == Some(first)

  let assert Error(NotTracked) =
    holder.run(h, fn() { presence.update(p, "room", "bob", "x") })
    as "holder.run returns Error(NotTracked)"
  // Another process cannot update this process's entry.
  let assert Error(NotTracked) = presence.update(p, "room", "alice", "x")
    as "presence.update returns Error(NotTracked)"
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn untrack_all_removes_every_topic_test() {
  let p = start(config(unique_name()) |> presence.pool_size(4))
  use h <- holder.with_holder
  let topics = ["a", "b", "c", "d", "e", "f"]
  list.each(topics, fn(topic) {
    let _ = track(p, h, topic, "k", "m")
  })
  list.each(topics, fn(topic) {
    let assert ["k"] = keys(p, topic) as "keys returns ['k']"
  })
  let assert Ok(Nil) = holder.run(h, fn() { presence.untrack_all(p) })
    as "holder.run succeeds"
  list.each(topics, fn(topic) {
    let assert [] = keys(p, topic) as "keys returns []"
  })
  // Nothing tracked is fine.
  let assert Ok(Nil) = holder.run(h, fn() { presence.untrack_all(p) })
    as "holder.run succeeds"
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn exited_process_leaves_test() {
  use <- monitored.isolated
  let p = start_default()
  use h <- holder.with_holder
  use stays <- holder.with_holder
  let _ = track(p, h, "room", "alice", "a")
  let _ = track(p, h, "lobby", "alice", "a")
  let _ = track(p, stays, "room", "bob", "b")
  // One shard holds both topics and monitors the holder once.
  let assert Ok(lobby_shard) = presence.shard_pid(p, "lobby")
    as "presence.shard_pid succeeds"
  assert lobby_shard == only_shard(p)
  kill_and_await_leave(p, h)
  assert keys(p, "room") == ["bob"]
  assert keys(p, "lobby") == []
  kill_and_await_leave(p, stays)
  assert keys(p, "room") == []
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

// --- Validation and limits --------------------------------------------------

pub fn topic_and_key_are_validated_test() {
  let p = start_default()
  use h <- holder.with_holder
  let max = presence.max_topic_bytes(p)
  assert max == 255 - string.byte_size("presence:" <> presence.name(p) <> ":")
  let longest = string.repeat("t", max)
  let _ = track(p, h, longest, "k", "m")
  let assert Ok(["k"]) = presence.list(p, longest) |> result_keys
    as "presence.list succeeds"
  let too_long = longest <> "t"
  let assert Error(InvalidTopic(_)) =
    holder.run(h, fn() { presence.track(p, too_long, "k", "m") })
    as "holder.run returns Error(InvalidTopic(_))"
  let assert Error(InvalidTopic(_)) =
    holder.run(h, fn() { presence.track(p, "", "k", "m") })
    as "holder.run returns Error(InvalidTopic(_))"
  let assert Error(InvalidTopic(_)) = presence.list(p, too_long)
    as "presence.list returns Error(InvalidTopic(_))"
  let assert Error(InvalidTopic(_)) = presence.subscribe(p, "")
    as "presence.subscribe returns Error(InvalidTopic(_))"

  let _ = track(p, h, "room", string.repeat("k", 255), "m")
  let assert Error(InvalidKey(_)) =
    holder.run(h, fn() {
      presence.track(p, "room", string.repeat("k", 256), "m")
    })
    as "holder.run returns Error(InvalidKey(_))"
  let assert Error(InvalidKey(_)) =
    holder.run(h, fn() { presence.track(p, "room", "", "m") })
    as "holder.run returns Error(InvalidKey(_))"
  let assert Error(InvalidKey(_)) = presence.get_by_key(p, "room", "")
    as "presence.get_by_key returns Error(InvalidKey(_))"
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
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
  let events = process.new_subject()
  // Telemetry handlers are global: with_handler detaches even when an
  // assertion fails.
  use <- monitored.with_handler(
    unique_name(),
    [["brazier", "presence", "limit_exceeded"]],
    fn(event) {
      case telemetry.string(event, "tracker") {
        Ok(tracker) if tracker == name -> process.send(events, event)
        _ -> Nil
      }
    },
  )
  use h <- holder.with_holder
  // "12345678" encodes as 10 bytes with its quotes: the limit is inclusive.
  let _ = track(p, h, "room", "fits", "12345678")
  let assert Error(MetaTooLarge(11)) =
    holder.run(h, fn() { presence.track(p, "room", "big", "123456789") })
    as "holder.run returns Error(MetaTooLarge(11))"
  let assert Error(MetaTooLarge(11)) =
    holder.run(h, fn() { presence.update(p, "room", "fits", "123456789") })
    as "holder.run returns Error(MetaTooLarge(11))"
  let assert Ok(event) = process.receive(events, wait_ms)
    as "process.receive succeeds"
  let assert Ok(1) = telemetry.int(event, "count") as "telemetry.int succeeds"
  assert keys(p, "room") == ["fits"]
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn meta_that_does_not_decode_is_refused_test() {
  pubsub.start()
  let assert Ok(p) =
    presence.start(presence.new(
      unique_name(),
      fn(meta: String) { json.int(string.length(meta)) },
      decode.string,
    ))
    as "presence.start succeeds"
  use h <- holder.with_holder
  let assert Error(MetaDecodeFailed(_)) =
    holder.run(h, fn() { presence.track(p, "room", "alice", "online") })
    as "holder.run returns Error(MetaDecodeFailed(_))"
  let assert Ok([]) = presence.list(p, "room") as "presence.list succeeds"
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn per_process_limit_test() {
  let p = start(config(unique_name()) |> presence.max_topics_per_pid(2))
  use h <- holder.with_holder
  let _ = track(p, h, "a", "k", "m")
  let _ = track(p, h, "b", "k", "m")
  let #(outcome, lines) =
    log_capture.capture(fn() {
      holder.run(h, fn() { presence.track(p, "c", "k", "m") })
    })
  let assert Error(PresenceLimitExceeded("max_topics_per_pid")) = outcome
    as "outcome is Error(..)"
  assert log_capture.contains(lines, "warning", "max_topics_per_pid")
  // Another process has its own allowance.
  use other <- holder.with_holder
  let _ = track(p, other, "c", "k", "m")
  // Untracking frees a slot.
  let assert Ok(Nil) = holder.run(h, fn() { presence.untrack(p, "a", "k") })
    as "holder.run succeeds"
  let _ = track(p, h, "c", "k2", "m")
  holder.kill(h)
  holder.kill(other)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn per_shard_limit_test() {
  use <- monitored.isolated
  let p = start(config(unique_name()) |> presence.max_entries_per_shard(2))
  use a <- holder.with_holder
  use b <- holder.with_holder
  use c <- holder.with_holder
  let _ = track(p, a, "room", "a", "m")
  let _ = track(p, b, "room", "b", "m")
  let assert Error(PresenceLimitExceeded("max_entries_per_shard")) =
    holder.run(c, fn() { presence.track(p, "room", "c", "m") })
    as "holder.run returns Error(..)"
  kill_and_await_leave(p, a)
  assert keys(p, "room") == ["b"]
  let _ = track(p, c, "room", "c", "m")
  holder.kill(b)
  holder.kill(c)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

// --- Diffs ------------------------------------------------------------------

pub fn diffs_arrive_in_order_test() {
  use <- monitored.isolated
  let p = start_default()
  subscribe(p, "room")
  use h <- holder.with_holder
  let first = track(p, h, "room", "alice", "online")
  let assert Ok(second) =
    holder.run(h, fn() { presence.update(p, "room", "alice", "away") })
    as "holder.run succeeds"
  let _ = track(p, h, "room", "bob", "online")
  let assert Ok(Nil) =
    holder.run(h, fn() { presence.untrack(p, "room", "bob") })
    as "holder.run succeeds"
  holder.kill(h)

  let assert Diff("room", [Entry("alice", [join])], []) = next_diff(p)
    as "next_diff returns Diff(..)"
  assert join.ref == first
  let assert Diff("room", [Entry("alice", [updated])], [Entry("alice", [old])]) =
    next_diff(p)
    as "next_diff returns Diff(..)"
  assert updated.value == "away"
  assert updated.ref == second
  assert updated.ref_prev == Some(first)
  assert old.value == "online"
  let assert Diff("room", [Entry("bob", _)], []) = next_diff(p)
    as "next_diff returns Diff('room', [Entry('bob', _)], [])"
  let assert Diff("room", [], [Entry("bob", _)]) = next_diff(p)
    as "next_diff returns Diff('room', [], [Entry('bob', _)])"
  let assert Diff("room", [], [Entry("alice", _)]) = next_diff(p)
    as "next_diff returns Diff('room', [], [Entry('alice', _)])"
  finish(p, "room")
}

pub fn diffs_are_per_topic_test() {
  use <- monitored.isolated
  let p = start_default()
  subscribe(p, "room")
  use h <- holder.with_holder
  let _ = track(p, h, "lobby", "alice", "m")
  let _ = track(p, h, "room", "bob", "m")
  let assert Diff("room", [Entry("bob", _)], []) = next_diff(p)
    as "next_diff returns Diff('room', [Entry('bob', _)], [])"
  // An exit with entries on two topics reports one diff per topic.
  holder.kill(h)
  let assert Diff("room", [], [Entry("bob", _)]) = next_diff(p)
    as "next_diff returns Diff('room', [], [Entry('bob', _)])"
  // No diff for "lobby" reached this subscriber.
  finish(p, "room")
}

pub fn decode_diff_rejects_other_messages_test() {
  use <- monitored.isolated
  let p = start_default()
  let other = start_default()
  subscribe(other, "room")
  use h <- holder.with_holder
  let _ = track(other, h, "room", "alice", "m")
  let assert Ok(message) = receive_diff(wait_ms) as "receive_diff succeeds"
  // A diff of another tracker.
  let assert Error(InvalidMessage) = presence.decode_diff(p, message)
    as "presence.decode_diff returns Error(InvalidMessage)"
  let assert Ok(_) = presence.decode_diff(other, message)
    as "presence.decode_diff succeeds"
  let assert Error(InvalidMessage) =
    presence.decode_diff(p, dynamic.string("nope"))
    as "presence.decode_diff returns Error(InvalidMessage)"
  holder.kill(h)
  let assert Diff("room", [], [Entry("alice", _)]) = next_diff(other)
    as "next_diff returns Diff('room', [], [Entry('alice', _)])"
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
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
    as "view returns ['alice=y@1', 'carol=x@3']"
}

pub fn merge_is_idempotent_test() {
  let diff =
    Diff("room", [Entry("alice", [meta("a", "1"), meta("b", "2")])], [
      Entry("bob", [meta("c", "9")]),
    ])
  let start = [Entry("bob", [meta("c", "9")])]
  let once = sync.merge(start, diff)
  let assert ["alice=a@1", "alice=b@2"] = view(once)
    as "view returns ['alice=a@1', 'alice=b@2']"
  assert sync.merge(once, diff) == once
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
    as "view returns ['alice=away@2']"
  // A join and leave of the same ref in one diff leaves nothing.
  let flap =
    Diff("room", [Entry("bob", [meta("x", "5")])], [
      Entry("bob", [meta("x", "5")]),
    ])
  let assert ["alice=here@1"] = view(sync.merge(start, flap))
    as "view returns ['alice=here@1']"
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
  let assert ["alice=b@2"] = view(merged) as "view returns ['alice=b@2']"
  let assert [Entry("alice", [_])] = merged as "merged is [Entry('alice', [_])]"
}

// --- Lifecycle --------------------------------------------------------------

pub fn stopped_tracker_is_down_test() {
  let p = start_default()
  use h <- holder.with_holder
  let _ = track(p, h, "room", "alice", "m")
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
  let assert Error(TrackerDown) =
    holder.run(h, fn() { presence.track(p, "room", "bob", "m") })
    as "holder.run returns Error(TrackerDown)"
  let assert Error(TrackerDown) = presence.list(p, "room")
    as "presence.list returns Error(TrackerDown)"
  let assert Error(TrackerDown) = presence.get_by_key(p, "room", "alice")
    as "presence.get_by_key returns Error(TrackerDown)"
  let assert Error(TrackerDown) = presence.shard_pid(p, "room")
    as "presence.shard_pid returns Error(TrackerDown)"
  let assert Error(TrackerDown) =
    holder.run(h, fn() { presence.untrack_all(p) })
    as "holder.run returns Error(TrackerDown)"
  let assert Error(TrackerDown) = presence.stop(p)
    as "presence.stop returns Error(TrackerDown)"
  holder.kill(h)
}

pub fn restarted_shard_starts_empty_test() {
  use <- monitored.isolated
  let p = start_default()
  use h <- holder.with_holder
  let _ = track(p, h, "room", "alice", "m")
  let assert Ok(shard) = presence.shard_pid(p, "room")
    as "presence.shard_pid succeeds"
  // The supervisor restarts the shard while handling its 'EXIT', and the
  // new shard registers in its init, before the supervisor goes on.
  let supervisor = parent(shard)
  {
    use restart <- await.with_watch_exit(supervisor, shard)
    process.kill(shard)
    await.expect_info(
      restart,
      supervisor,
      "the supervisor restarting the shard",
    )
  }
  let assert Ok(new) = presence.shard_pid(p, "room")
    as "presence.shard_pid succeeds"
  assert new != shard
  assert presence.list(p, "room") == Ok([])
  // The holder tracks again, as the runtime does after a shard restart.
  let _ = track(p, h, "room", "alice", "m")
  assert keys(p, "room") == ["alice"]
  holder.kill(h)
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn supervised_tracker_test() {
  pubsub.start()
  let c = config(unique_name())
  let assert Ok(p) = presence.handle(c) as "presence.handle succeeds"
  let assert Error(TrackerDown) = presence.list(p, "room")
    as "presence.list returns Error(TrackerDown)"
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(child) = presence.supervised(c)
        as "presence.supervised succeeds"
      let assert Ok(started) =
        supervisor.new(supervisor.OneForOne)
        |> supervisor.add(child)
        |> supervisor.start
        as "the supervisor holding the tracker must start"
      process.send(ready, started.pid)
      process.sleep_forever()
    })
  let assert Ok(tree) = process.receive(ready, wait_ms)
    as "the owner did not start the tree"
  use h <- holder.with_holder
  let _ = track(p, h, "room", "alice", "m")
  assert keys(p, "room") == ["alice"]
  holder.kill(h)
  // The tree is linked to its owner: killing the owner stops the tree,
  // which stops the tracker before the tree itself exits.
  let tree_down = process.monitor(tree)
  process.kill(owner)
  let assert process.Killed =
    monitored.down_reason(tree_down, "the tree linked to the killed owner")
    as "monitored.down_reason returns process.Killed"
  assert presence.list(p, "room") == Error(TrackerDown)
}

// --- Replicas (fake peers) --------------------------------------------------
//
// A shard takes replication messages only from verified cluster members, so
// each of these tests counts the fake node as one (with_verified).

pub fn remote_entries_join_go_down_and_permdown_test() {
  use <- monitored.isolated
  use <- with_verified(["fake@host"])
  let p = start_fast(unique_name())
  {
    use tick <- await.with_watch_info(only_shard(p), "heartbeat")
    subscribe(p, "room")
    let ref = fake_ref("fake@host", 1)
    send_peer(p, transfer_ack(ref, 1, "room", [#("remote", "\"hi\"")]))
    assert replicas(p) == [#("fake@host", Up)]
    let assert Ok([Entry("remote", [meta])]) = presence.list(p, "room")
      as "presence.list succeeds"
    assert meta
      == Meta(
        value: "hi",
        ref: "fake-remote",
        ref_prev: None,
        node: "fake@host",
      )
    let assert Diff("room", [Entry("remote", _)], []) = next_diff(p)
      as "next_diff returns Diff('room', [Entry('remote', _)], [])"

    // No heartbeats: down after 100ms (entries leave), forgotten after 300ms.
    await_replicas(p, tick, [#("fake@host", Down)], "the fake replica down")
    let assert Ok([]) = presence.list(p, "room") as "presence.list succeeds"
    let assert Diff("room", [], [Entry("remote", _)]) = next_diff(p)
      as "next_diff returns Diff('room', [], [Entry('remote', _)])"
    await_replicas(p, tick, [], "the fake replica forgotten")
  }
  finish(p, "room")
}

pub fn heartbeat_brings_a_down_replica_back_test() {
  use <- monitored.isolated
  use <- with_verified(["fake@host"])
  let p =
    start(
      config(unique_name())
      |> presence.broadcast_period(20)
      |> presence.max_silent_periods(2)
      |> presence.down_period(100)
      |> presence.permdown_period(60_000),
    )
  let ref = fake_ref("fake@host", 1)
  {
    use tick <- await.with_watch_info(only_shard(p), "heartbeat")
    send_peer(p, transfer_ack(ref, 1, "room", [#("remote", "\"hi\"")]))
    await_replicas(p, tick, [#("fake@host", Down)], "the fake replica down")
  }
  let assert Ok([]) = presence.list(p, "room") as "presence.list succeeds"
  send_peer(p, heartbeat(ref, 1))
  assert replicas(p) == [#("fake@host", Up)]
  assert keys(p, "room") == ["remote"]
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn graceful_permdown_drops_entries_at_once_test() {
  use <- with_verified(["fake@host"])
  let p = start(config(unique_name()))
  let ref = fake_ref("fake@host", 1)
  send_peer(p, transfer_ack(ref, 1, "room", [#("remote", "\"hi\"")]))
  assert keys(p, "room") == ["remote"]
  // A graceful_permdown from another version is ignored.
  send_peer(p, graceful_permdown(fake_ref("fake@host", 2), 1))
  assert replicas(p) == [#("fake@host", Up)]
  send_peer(p, graceful_permdown(ref, 1))
  assert replicas(p) == []
  let assert Ok([]) = presence.list(p, "room") as "presence.list succeeds"
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn new_version_replaces_the_old_replica_test() {
  use <- monitored.isolated
  use <- with_verified(["fake@host"])
  let p = start(config(unique_name()))
  subscribe(p, "room")
  send_peer(
    p,
    transfer_ack(fake_ref("fake@host", 1), 1, "room", [#("old", "\"a\"")]),
  )
  let assert Diff("room", [Entry("old", _)], []) = next_diff(p)
    as "next_diff returns Diff('room', [Entry('old', _)], [])"
  // The node's shard restarted: its old entries leave at once.
  send_peer(p, heartbeat(fake_ref("fake@host", 2), 1))
  let assert Diff("room", [], [Entry("old", _)]) = next_diff(p)
    as "next_diff returns Diff('room', [], [Entry('old', _)])"
  assert replicas(p) == [#("fake@host", Up)]
  let assert Ok([]) = presence.list(p, "room") as "presence.list succeeds"
  send_peer(
    p,
    transfer_ack(fake_ref("fake@host", 2), 1, "room", [#("new", "\"b\"")]),
  )
  let assert Diff("room", [Entry("new", _)], []) = next_diff(p)
    as "next_diff returns Diff('room', [Entry('new', _)], [])"
  assert keys(p, "room") == ["new"]
  finish(p, "room")
}

pub fn pool_size_mismatch_is_ignored_and_logged_once_test() {
  use <- with_verified(["fake@host"])
  let p = start(config(unique_name()))
  let ref = fake_ref("fake@host", 1)
  let #(_, lines) =
    log_capture.capture(fn() {
      send_peer(p, heartbeat(ref, 3))
      send_peer(p, transfer_ack(ref, 3, "room", [#("remote", "\"hi\"")]))
      replicas(p)
    })
  assert replicas(p) == []
  let assert Ok([]) = presence.list(p, "room") as "presence.list succeeds"
  let mismatches =
    list.filter(lines, fn(line) {
      line.level == "error" && string.contains(line.message, "pool size")
    })
  assert list.length(mismatches) == 1
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn oversized_transfer_is_rejected_test() {
  use <- with_verified(["fake@host"])
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
  let assert Ok([]) = presence.list(p, "room") as "presence.list succeeds"
  send_peer(p, transfer_ack(ref, 1, "room", [#("a", "\"1\""), #("b", "\"2\"")]))
  assert keys(p, "room") == ["a", "b"]
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn peer_messages_from_a_non_member_are_dropped_test() {
  let p = start(config(unique_name()))
  let ref = fake_ref("fake@host", 1)
  let #(_, lines) =
    log_capture.capture(fn() {
      send_peer(p, transfer_ack(ref, 1, "room", [#("remote", "\"hi\"")]))
      send_peer(p, heartbeat(ref, 1))
      replicas(p)
    })
  assert replicas(p) == []
  let assert Ok([]) = presence.list(p, "room") as "presence.list succeeds"
  let dropped =
    list.filter(lines, fn(line) {
      line.level == "warning"
      && string.contains(line.message, "fake@host: not a verified")
    })
  assert list.length(dropped) == 2
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
}

pub fn malformed_peer_messages_are_logged_test() {
  use <- with_verified(["fake@host"])
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
  let assert Ok(Nil) = presence.stop(p) as "presence.stop succeeds"
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

/// The process that started `pid` (its supervisor, for a shard).
@external(erlang, "brazier_presence_test_ffi", "parent")
fn parent(pid: process.Pid) -> process.Pid

@external(erlang, "brazier_presence_test_ffi", "receive_diff")
fn receive_diff(timeout_ms: Int) -> Result(Dynamic, Nil)

@external(erlang, "brazier_presence_test_ffi", "unique_positive")
fn unique_integer() -> Int

@external(erlang, "brazier_presence_test_ffi", "malformed_messages")
fn malformed_messages() -> List(Dynamic)

/// Run `run` with `nodes` counted as verified cluster members.
@external(erlang, "brazier_presence_test_ffi", "with_verified")
fn with_verified(nodes: List(String), run: fn() -> a) -> a
