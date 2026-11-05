//// Watch-only presence (`brazier.watch_presence`): a session follows a
//// topic's diffs without tracking itself there.
////
//// Sessions are runtimes on peer nodes inside holder processes (see
//// cluster/presence_watch_test); their presence comes from the
//// `brazier.watch_presence` builder. Waiting is always a receive with a
//// deadline: the app's presence messages, or `peer.until` woken by each
//// diff the tracker reports (brazier/presence/wake).

import brazier
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/effect
import brazier/element
import brazier/error
import brazier/internal/presence_watch
import brazier/presence.{type Presence}
import brazier/presence/holder.{type Holder}
import brazier/presence/sync.{type Diff, type Entry}
import brazier/presence/wake
import brazier/pubsub
import brazier/runtime
import brazier/test_ctx
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

const wait_ms = 10_000

const receive_ms = 5000

const name = "pwo"

// --- The app ------------------------------------------------------------------

type Model {
  Model(watched: List(String), online: Dict(String, List(Entry(String))))
}

type Msg {
  Online(Diff(String))
  SetWatched(List(String))
}

/// What the app saw: the diff and its merged view of the diff's topic.
type Proof =
  #(Diff(String), List(Entry(String)))

type Session {
  Session(
    holder: Holder,
    runtime: Subject(runtime.RuntimeMessage(Msg)),
    proof: Subject(Proof),
  )
}

fn fast_config() -> presence.PresenceConfig(String) {
  presence.new(name, json.string, decode.string)
  |> presence.broadcast_period(50)
  |> presence.max_silent_periods(2)
  |> presence.down_period(500)
  |> presence.permdown_period(2000)
}

fn tracker() -> Presence(String) {
  let assert Ok(tracker) = presence.handle(fast_config())
    as "fast_config is a valid presence configuration"
  tracker
}

/// The app's presence, built with the public builder.
fn watching() -> presence_watch.Watch(Model, Msg) {
  let codec =
    runtime.GeneratedCodec(
      encode_model: fn(_model) { "{}" },
      decode_model: fn(json) { Error("no model codec: " <> json) },
      decode_event: fn(_name, handler_id, _data, _path) {
        Error(error.RuntimeError(reason: "no client events: " <> handler_id))
      },
      stream_names: [],
    )
  let assert Ok(config) =
    brazier.simple(
      init: fn(_ctx) { Ok(Model(watched: [], online: dict.new())) },
      update: fn(model, _msg) { model },
      view: fn(_model) { element.text("") },
    )
    |> brazier.secret_key("a-test-secret-that-is-long-enough-0123456789")
    |> brazier.watch_presence(
      tracker: fast_config(),
      watch: fn(model: Model) { model.watched },
      on_presence: Online,
    )
    |> brazier.to_config(codec, 8080)
    as "the app has a secret key"
  let assert Some(watch) = config.presence as "watch_presence sets presence"
  watch
}

fn session_config(
  watched: List(String),
  proof: Subject(Proof),
) -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(watched:, online: dict.new()), effect.none())) },
    update: fn(model: Model, msg: Msg) {
      case msg {
        SetWatched(watched) -> #(Model(..model, watched:), effect.none())
        Online(diff) -> {
          let view =
            dict.get(model.online, diff.topic)
            |> result.unwrap([])
            |> sync.merge(diff)
          process.send(proof, #(diff, view))
          let online = dict.insert(model.online, diff.topic, view)
          #(Model(..model, online:), effect.none())
        }
      }
    },
    encode_model: fn(_model) { "{}" },
    decode_event: fn(_name, handler_id, _data, _path) {
      Error(error.RuntimeError(reason: "no client events: " <> handler_id))
    },
    restore_model: None,
    route: None,
    dynamic_subscriptions: None,
    on_notify: None,
    on_notification: None,
    secret_key: "",
    presence: Some(watching()),
    title: None,
    streams: runtime.no_streams(),
  )
}

// --- Helpers ------------------------------------------------------------------

fn start_tracker(p: Peer) -> Nil {
  peer.on(p, fn() {
    pubsub.start()
    let assert Ok(_) = presence.start(fast_config())
      as "presence.start succeeds"
    Nil
  })
}

fn try_session(
  p: Peer,
  watched: List(String),
) -> Result(Session, error.BrazierError) {
  peer.on(p, fn() {
    let h = holder.start()
    let #(proof, started) =
      holder.run(h, fn() {
        let proof = process.new_subject()
        #(proof, runtime.start(session_config(watched, proof), test_ctx.root()))
      })
    case started {
      Ok(rt) -> Ok(Session(holder: h, runtime: rt, proof:))
      Error(reason) -> {
        holder.kill(h)
        Error(reason)
      }
    }
  })
}

fn start_session(p: Peer, watched: List(String)) -> Session {
  let assert Ok(session) = try_session(p, watched) as "the session starts"
  session
}

fn send(p: Peer, session: Session, msg: Msg) -> Nil {
  peer.on(p, fn() {
    process.send(session.runtime, runtime.EffectDispatched(message: msg))
  })
}

/// The next presence message the app on `p` saw.
fn next(p: Peer, session: Session) -> Result(Proof, Nil) {
  peer.on(p, fn() {
    holder.run(session.holder, fn() {
      process.receive(session.proof, receive_ms)
    })
  })
}

/// Receive presence messages until the app's view of `topic` has the keys
/// `expected`; the diffs on the way, or the keys it was left with.
fn collect_until(
  p: Peer,
  session: Session,
  topic: String,
  expected: List(String),
) -> Result(List(Diff(String)), List(String)) {
  collect_loop(p, session, topic, expected, [], [])
}

fn collect_loop(
  p: Peer,
  session: Session,
  topic: String,
  expected: List(String),
  diffs: List(Diff(String)),
  last: List(String),
) -> Result(List(Diff(String)), List(String)) {
  case next(p, session) {
    Error(Nil) -> Error(last)
    Ok(#(diff, view)) -> {
      let diffs = [diff, ..diffs]
      case diff.topic == topic && keys(view) == expected {
        True -> Ok(list.reverse(diffs))
        False -> collect_loop(p, session, topic, expected, diffs, keys(view))
      }
    }
  }
}

fn keys(entries: List(Entry(String))) -> List(String) {
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(_) { entry.key })
  })
}

/// The keys this node's tracker lists on `topic`.
fn listed_here(topic: String) -> List(String) {
  let assert Ok(entries) = presence.list(tracker(), topic)
    as "presence.list succeeds"
  keys(entries)
}

fn listed(p: Peer, topic: String) -> List(String) {
  peer.on(p, fn() { listed_here(topic) })
}

/// Whether `p`'s tracker comes to list the keys `expected` on `topic`,
/// re-checked on each diff it reports there. A restarted shard reports
/// the entries it merges from a peer, so catching up wakes this.
fn lists(p: Peer, topic: String, expected: List(String)) -> Bool {
  peer.until(
    p,
    wake.diffs(tracker(), topic),
    fn() { listed_here(topic) == expected },
    wait_ms,
  )
}

/// A holder on `p` tracking `key` on `topic`.
fn track_on(p: Peer, topic: String, key: String) -> Holder {
  peer.on(p, fn() {
    let h = holder.start()
    let assert Ok(_) =
      holder.run(h, fn() { presence.track(tracker(), topic, key, "idle") })
      as "presence.track succeeds"
    h
  })
}

fn kill_shard(p: Peer, topic: String) -> Nil {
  peer.on(p, fn() {
    let assert Ok(shard) = presence.shard_pid(tracker(), topic)
      as "the topic has a shard"
    process.kill(shard)
  })
}

/// The session's presence watcher; call on the session's node.
fn watcher(session: Session) -> Pid {
  let assert Ok(runtime) = process.subject_owner(session.runtime)
    as "a started runtime's subject is owned by its actor"
  let assert Ok(pid) = watcher_of(runtime)
    as "the runtime has no presence watcher"
  pid
}

// --- Tests --------------------------------------------------------------------

/// A watching session on A hears everyone on the lobby, from both nodes,
/// and is not on it itself: neither node lists anything of the session.
/// Joins and leaves after that arrive one by one.
pub fn watches_without_tracking_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_ws8c_watch_only")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_tracker(a)
  start_tracker(b)
  let ann = track_on(a, "lobby", "ann")
  let _bob = track_on(b, "lobby", "bob")
  assert lists(a, "lobby", ["ann", "bob"])

  let viewer = start_session(a, ["lobby"])
  let assert Ok(#(first, view)) = next(a, viewer) as "the viewer sees the lobby"
  assert first.topic == "lobby"
  assert keys(first.joins) == ["ann", "bob"]
  assert first.leaves == []
  assert keys(view) == ["ann", "bob"]

  let _cat = track_on(b, "lobby", "cat")
  let assert Ok(#(joined, _)) = next(a, viewer) as "the viewer sees cat join"
  assert keys(joined.joins) == ["cat"]
  assert joined.leaves == []

  peer.on(a, fn() { holder.kill(ann) })
  let assert Ok(#(left, view)) = next(a, viewer) as "the viewer sees ann leave"
  assert left.joins == []
  assert keys(left.leaves) == ["ann"]
  assert keys(view) == ["bob", "cat"]

  // The session never appears on the topic, on either node.
  assert listed(a, "lobby") == ["bob", "cat"]
  assert lists(b, "lobby", ["bob", "cat"])
}

/// Changes queued while the watcher is busy reach the app coalesced, as
/// with `brazier.presence`: up to 100 deliveries per message.
pub fn queued_changes_are_coalesced_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_ws8c_watch_coalesce")
  let assert [a] = peers as "the cluster starts one peer"
  start_tracker(a)
  let viewer = start_session(a, ["lobby"])
  let _ann = track_on(a, "lobby", "ann")
  let assert Ok(_) = collect_until(a, viewer, "lobby", ["ann"])
    as "the viewer sees ann"

  let holders =
    peer.on(a, fn() {
      let w = watcher(viewer)
      suspend(w)
      let holders =
        int.range(from: 120, to: 0, with: [], run: fn(acc, i) { [i, ..acc] })
        |> list.map(fn(i) {
          let h = holder.start()
          let key = "u" <> string.pad_start(int.to_string(i), 3, "0")
          let assert Ok(_) =
            holder.run(h, fn() { presence.track(tracker(), "lobby", key, "x") })
            as "presence.track succeeds"
          h
        })
      resume(w)
      holders
    })
  assert list.length(holders) == 120

  let assert Ok(#(first, _)) = next(a, viewer) as "the first batch arrives"
  let assert Ok(#(second, view)) = next(a, viewer) as "the second batch arrives"
  assert list.length(keys(first.joins)) == 100
  assert list.length(keys(second.joins)) == 20
  assert first.leaves == []
  assert second.leaves == []
  assert list.length(view) == 121
  // Only the holders are tracked; the watching session is not.
  assert list.length(listed(a, "lobby")) == 121
}

/// The watched topics follow the state. Moving from the lobby to the hall
/// reports everyone known on the lobby as leaving and everyone on the hall
/// as joining; the lobby's later changes do not reach the app, and
/// watching nothing reports the hall's entries as leaving. A topic listed
/// twice is followed once. Each step checks that the message it expects is
/// the next one, so nothing extra (a second initial join, a late hall
/// diff) was on the way before it.
pub fn watched_topics_follow_the_state_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_ws8c_watch_move")
  let assert [a] = peers as "the cluster starts one peer"
  start_tracker(a)
  let _ann = track_on(a, "lobby", "ann")
  let _bob = track_on(a, "hall", "bob")

  let viewer = start_session(a, ["lobby", "lobby"])
  let assert Ok(#(first, _)) = next(a, viewer) as "the viewer sees the lobby"
  assert summary(first) == #("lobby", ["ann"], [])

  send(a, viewer, SetWatched(["hall"]))
  let assert Ok(#(left, _)) = next(a, viewer) as "the viewer leaves the lobby"
  assert summary(left) == #("lobby", [], ["ann"])
  let assert Ok(#(joined, _)) = next(a, viewer) as "the viewer sees the hall"
  assert summary(joined) == #("hall", ["bob"], [])

  // A lobby change is not reported; the hall change after it is next.
  let _cat = track_on(a, "lobby", "cat")
  let _dan = track_on(a, "hall", "dan")
  let assert Ok(#(dan, _)) = next(a, viewer) as "the viewer sees dan join"
  assert summary(dan) == #("hall", ["dan"], [])

  send(a, viewer, SetWatched([]))
  let assert Ok(#(gone, view)) = next(a, viewer) as "the viewer leaves the hall"
  assert summary(gone) == #("hall", [], ["bob", "dan"])
  assert view == []

  send(a, viewer, SetWatched(["lobby"]))
  let assert Ok(#(back, _)) = next(a, viewer)
    as "the viewer sees the lobby again"
  assert summary(back) == #("lobby", ["ann", "cat"], [])
  assert listed(a, "lobby") == ["ann", "cat"]
}

/// A diff's topic, joined keys and left keys.
fn summary(diff: Diff(String)) -> #(String, List(String), List(String)) {
  #(diff.topic, keys(diff.joins), keys(diff.leaves))
}

/// When A's lobby shard restarts, a watching session on A hears ann (an
/// entry of A, gone with the old shard) leave at once, while bob, tracked
/// on B the whole time, neither leaves nor joins as A's new shard catches
/// up with B. The next change after that is the next thing it sees.
pub fn shard_restart_does_not_flap_remote_entries_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_ws8c_watch_restart")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_tracker(a)
  start_tracker(b)
  let _ann = track_on(a, "lobby", "ann")
  let _bob = track_on(b, "lobby", "bob")
  let viewer = start_session(a, ["lobby"])
  let assert Ok(_) = collect_until(a, viewer, "lobby", ["ann", "bob"])
    as "the viewer sees ann and bob"

  kill_shard(a, "lobby")
  let assert Ok(#(restart, view)) = next(a, viewer)
    as "the viewer sees the restart"
  assert restart.joins == []
  assert keys(restart.leaves) == ["ann"]
  assert keys(view) == ["bob"]

  assert lists(a, "lobby", ["bob"])
  let _cat = track_on(b, "lobby", "cat")
  let assert Ok(#(after, view)) = next(a, viewer) as "the viewer sees cat join"
  assert after.leaves == []
  assert keys(after.joins) == ["cat"]
  assert keys(view) == ["bob", "cat"]
}

/// A watched topic the tracker refuses (empty) fails the start; one the
/// state moves to later stops the session with `brazier_presence_failed`
/// (the exit of its watcher, which the runtime is linked to).
pub fn invalid_watched_topic_fails_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_ws8c_watch_invalid")
  let assert [a] = peers as "the cluster starts one peer"
  start_tracker(a)

  let assert Error(error.RuntimeError(reason)) = try_session(a, [""])
    as "try_session returns Error(RuntimeError)"
  assert string.contains(reason, "presence")

  let viewer = start_session(a, ["lobby"])
  let reason =
    peer.on(a, fn() {
      let assert Ok(runtime) = process.subject_owner(viewer.runtime)
        as "a started runtime's subject is owned by its actor"
      // Monitor before the message, so the exit cannot come first.
      let monitor = process.monitor(runtime)
      process.send(
        viewer.runtime,
        runtime.EffectDispatched(message: SetWatched([""])),
      )
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down.reason })
      |> process.selector_receive(receive_ms)
    })
  let assert Ok(process.Abnormal(reason)) = reason
    as "the runtime exits abnormally"
  let reason = string.inspect(reason)
  assert string.contains(reason, "BrazierPresenceFailed") as reason
  assert string.contains(reason, "subscribing") as reason
}

// --- FFI ----------------------------------------------------------------------

@external(erlang, "brazier_presence_watch_test_ffi", "watcher_of")
fn watcher_of(runtime: Pid) -> Result(Pid, Nil)

@external(erlang, "brazier_presence_watch_test_ffi", "suspend")
fn suspend(pid: Pid) -> Nil

@external(erlang, "brazier_presence_watch_test_ffi", "resume")
fn resume(pid: Pid) -> Nil
