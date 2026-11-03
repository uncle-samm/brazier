//// Session presence over real runtimes on peer nodes (`beacon.presence`).
////
//// Each session is a runtime started on a peer inside a holder process
//// (beacon/presence/holder). The holder owns the runtime's link and the
//// proof subject the app's `update` reports every presence message to, so
//// the test reads what the app saw through the holder. Waiting is always
//// a receive or `peer.eventually` with a deadline.

import beacon/cluster/peer.{type Peer, Timeout}
import beacon/effect
import beacon/error
import beacon/internal/presence_watch
import beacon/presence.{type Presence, Tracking}
import beacon/presence/holder.{type Holder}
import beacon/presence/sync.{type Diff, type Entry}
import beacon/pubsub
import beacon/runtime
import beacon/test_ctx
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

const wait_ms = 10_000

const receive_ms = 5000

const name = "pw"

// --- The app ------------------------------------------------------------------

type Model {
  Model(
    user: String,
    room: Option(String),
    status: String,
    online: List(Entry(String)),
  )
}

type Msg {
  Leave
  SetStatus(String)
  Online(Diff(String))
}

/// What the app saw: the diff and its merged view after it.
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
  // INVARIANT: fast_config is a valid configuration.
  let assert Ok(tracker) = presence.handle(fast_config())
  tracker
}

/// The session tracks its user in its room while it has one.
fn in_room(model: Model) -> List(presence.Tracking(String)) {
  case model.room {
    Some(room) -> [Tracking(topic: room, key: model.user, meta: model.status)]
    None -> []
  }
}

fn session_config(
  user: String,
  room: Option(String),
  proof: Subject(Proof),
  track: fn(Model) -> List(presence.Tracking(String)),
) -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) {
      Ok(#(Model(user:, room:, status: "here", online: []), effect.none()))
    },
    update: fn(model: Model, msg: Msg) {
      case msg {
        Leave -> #(Model(..model, room: None), effect.none())
        SetStatus(status) -> #(Model(..model, status:), effect.none())
        Online(diff) -> {
          let online = sync.merge(model.online, diff)
          process.send(proof, #(diff, online))
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
    presence: Some(presence_watch.new(fast_config(), track, Online)),
  )
}

// --- Helpers ------------------------------------------------------------------

/// PubSub and the tracker on `p`.
fn start_tracker(p: Peer) -> Nil {
  peer.on(p, fn() {
    pubsub.start()
    let assert Ok(_) = presence.start(fast_config())
    Nil
  })
}

fn try_session(
  p: Peer,
  user: String,
  room: Option(String),
  track: fn(Model) -> List(presence.Tracking(String)),
) -> Result(Session, error.BeaconError) {
  peer.on(p, fn() {
    let h = holder.start()
    let #(proof, started) =
      holder.run(h, fn() {
        let proof = process.new_subject()
        let config = session_config(user, room, proof, track)
        #(proof, runtime.start(config, test_ctx.root()))
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

fn start_session(p: Peer, user: String, room: Option(String)) -> Session {
  let assert Ok(session) = try_session(p, user, room, in_room)
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

/// Receive presence messages until the app's merged view is `expected`;
/// the diffs on the way, or the view it was left with.
fn await_view(
  p: Peer,
  session: Session,
  expected: List(String),
) -> Result(List(Diff(String)), List(String)) {
  await_view_loop(p, session, expected, [], [])
}

fn await_view_loop(
  p: Peer,
  session: Session,
  expected: List(String),
  diffs: List(Diff(String)),
  last: List(String),
) -> Result(List(Diff(String)), List(String)) {
  case next(p, session) {
    Error(Nil) -> Error(last)
    Ok(#(diff, online)) -> {
      let diffs = [diff, ..diffs]
      case flatten(online) == expected {
        True -> Ok(list.reverse(diffs))
        False -> await_view_loop(p, session, expected, diffs, flatten(online))
      }
    }
  }
}

fn flatten(entries: List(Entry(String))) -> List(String) {
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(meta) { entry.key <> "=" <> meta.value })
  })
}

fn refs(entries: List(Entry(String))) -> List(String) {
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(meta) { entry.key <> "@" <> meta.ref })
  })
}

/// The keys `p`'s tracker lists on `topic`.
fn listed(p: Peer, topic: String) -> List(Entry(String)) {
  peer.on(p, fn() {
    let assert Ok(entries) = presence.list(tracker(), topic)
    entries
  })
}

fn keys(p: Peer, topic: String) -> List(String) {
  listed(p, topic) |> list.map(fn(entry) { entry.key })
}

fn sees(p: Peer, topic: String, expected: List(String)) -> Bool {
  peer.eventually(fn() { keys(p, topic) == expected }, wait_ms)
}

/// A holder on `p` tracking `key` on `topic`.
fn track_on(p: Peer, topic: String, key: String, meta: String) -> Holder {
  peer.on(p, fn() {
    let h = holder.start()
    let assert Ok(_) =
      holder.run(h, fn() { presence.track(tracker(), topic, key, meta) })
    h
  })
}

fn runtime_pid(session: Session) -> Pid {
  // INVARIANT: a started runtime's subject is owned by its actor.
  let assert Ok(pid) = process.subject_owner(session.runtime)
  pid
}

/// The session's presence watcher; call on the session's node.
fn watcher(session: Session) -> Pid {
  let assert Ok(pid) = watcher_of(runtime_pid(session))
    as "the runtime has no presence watcher"
  pid
}

fn alive(p: Peer, pid: Pid) -> Bool {
  peer.on(p, fn() { process.is_alive(pid) })
}

// --- Tests --------------------------------------------------------------------

/// Sessions on two nodes see each other and a plain tracked process join,
/// change and leave; a session that leaves its room is told everything it
/// knew left.
pub fn cross_node_joins_and_leaves_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_pw_cross")
  let assert [a, b] = peers
  start_tracker(a)
  start_tracker(b)

  let ann = start_session(a, "ann", Some("lobby"))
  let assert Ok([first]) = await_view(a, ann, ["ann=here"])
  let assert [] = first.leaves

  let bob = track_on(b, "lobby", "bob", "idle")
  let assert Ok(_) = await_view(a, ann, ["ann=here", "bob=idle"])

  let bea = start_session(b, "bea", Some("lobby"))
  let all = ["ann=here", "bea=here", "bob=idle"]
  let assert Ok(_) = await_view(b, bea, all)
  let assert Ok(_) = await_view(a, ann, all)

  // A state change updates the tracked meta everywhere.
  send(a, ann, SetStatus("away"))
  let away = ["ann=away", "bea=here", "bob=idle"]
  let assert Ok(_) = await_view(a, ann, away)
  let assert Ok(_) = await_view(b, bea, away)
  let assert True = sees(b, "lobby", ["ann", "bea", "bob"])

  // Leaving the room: the others see the leave, the session sees all leave.
  send(b, bea, Leave)
  let assert Ok(left) = await_view(b, bea, [])
  let assert [_, ..] = left
  let assert Ok(_) = await_view(a, ann, ["ann=away", "bob=idle"])
  let assert True = sees(a, "lobby", ["ann", "bob"])

  // A tracked process exiting leaves too.
  peer.on(b, fn() { holder.kill(bob) })
  let assert Ok(_) = await_view(a, ann, ["ann=away"])
  Nil
}

/// Diffs that queue up while the watcher is busy reach the app as one
/// message per 100.
pub fn coalesces_queued_diffs_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_pw_coalesce")
  let assert [a] = peers
  start_tracker(a)
  let ann = start_session(a, "ann", Some("lobby"))
  let assert Ok(_) = await_view(a, ann, ["ann=here"])

  let holders =
    peer.on(a, fn() {
      let w = watcher(ann)
      suspend(w)
      let holders =
        int.range(from: 150, to: 0, with: [], run: fn(acc, i) { [i, ..acc] })
        |> list.map(fn(i) {
          let h = holder.start()
          let key = "u" <> string.pad_start(int.to_string(i), 3, "0")
          let assert Ok(_) =
            holder.run(h, fn() { presence.track(tracker(), "lobby", key, "x") })
          h
        })
      resume(w)
      holders
    })
  let assert 150 = list.length(holders)

  let assert Ok(#(first, _)) = next(a, ann)
  let assert Ok(#(second, online)) = next(a, ann)
  let assert 100 = list.length(flatten(first.joins))
  let assert 50 = list.length(flatten(second.joins))
  let assert [] = first.leaves
  let assert [] = second.leaves
  let assert 151 = list.length(online)
  Nil
}

/// When the topic's shard dies, the watcher tracks the session again on
/// the restarted shard and tells the app the old entry left and the new
/// one joined, in one message.
pub fn retracks_after_shard_restart_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_pw_shard")
  let assert [a, b] = peers
  start_tracker(a)
  start_tracker(b)
  let ann = start_session(a, "ann", Some("lobby"))
  let assert Ok(_) = await_view(a, ann, ["ann=here"])
  let assert True = sees(b, "lobby", ["ann"])
  let assert [old] = refs(listed(a, "lobby"))

  let old_shard =
    peer.on(a, fn() {
      let assert Ok(shard) = presence.shard_pid(tracker(), "lobby")
      process.kill(shard)
      shard
    })
  let assert Ok(#(diff, online)) = next(a, ann)
  let assert [new] = refs(diff.joins)
  let assert [left] = refs(diff.leaves)
  let assert True = left == old
  let assert True = new != old
  let assert True = refs(online) == [new]

  let assert Ok(new_shard) =
    peer.on(a, fn() { presence.shard_pid(tracker(), "lobby") })
  let assert True = new_shard != old_shard
  let assert True = refs(listed(a, "lobby")) == [new]
  let assert True =
    peer.eventually(fn() { refs(listed(b, "lobby")) == [new] }, wait_ms)
  Nil
}

/// A runtime that is killed or shut down takes its entries with it, on
/// every node, and its watcher is gone.
pub fn cleanup_when_runtime_dies_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_pw_cleanup")
  let assert [a, b] = peers
  start_tracker(a)
  start_tracker(b)
  let ann = start_session(a, "ann", Some("lobby"))
  let amy = start_session(a, "amy", Some("lobby"))
  let assert True = sees(b, "lobby", ["amy", "ann"])
  let #(ann_watcher, amy_watcher) =
    peer.on(a, fn() { #(watcher(ann), watcher(amy)) })

  peer.on(a, fn() { process.kill(runtime_pid(ann)) })
  let assert True = sees(b, "lobby", ["amy"])
  let assert True = peer.eventually(fn() { !alive(a, ann_watcher) }, wait_ms)

  peer.on(a, fn() { process.send(amy.runtime, runtime.Shutdown) })
  let assert True = sees(b, "lobby", [])
  let assert True = sees(a, "lobby", [])
  let assert True = peer.eventually(fn() { !alive(a, amy_watcher) }, wait_ms)
  Nil
}

/// Losing the PubSub partition the watcher subscribes through stops the
/// runtime with `beacon_pubsub_down`.
pub fn stops_when_pubsub_partition_dies_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_pw_pubsub")
  let assert [a] = peers
  start_tracker(a)
  let ann = start_session(a, "ann", Some("lobby"))
  let assert Ok(_) = await_view(a, ann, ["ann=here"])

  let reason =
    peer.on(a, fn() {
      let assert Ok(partition) = pubsub.partition_for(watcher(ann))
      process.kill(partition)
      await_exit(runtime_pid(ann), receive_ms)
    })
  let assert Ok(reason) = reason
  let assert True = string.contains(reason, "beacon_pubsub_down")
  Nil
}

/// Trackings the tracker refuses, or a key tracked twice on a topic, fail
/// the runtime's start and leave nothing tracked.
pub fn refused_trackings_fail_the_start_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_pw_refused")
  let assert [a] = peers
  start_tracker(a)

  let assert Error(error.RuntimeError(reason)) =
    try_session(a, "", Some("lobby"), in_room)
  let assert True = string.contains(reason, "presence")

  let twice = fn(_model) {
    [
      Tracking(topic: "lobby", key: "ann", meta: "a"),
      Tracking(topic: "lobby", key: "ann", meta: "b"),
    ]
  }
  let assert Error(error.RuntimeError(reason)) =
    try_session(a, "ann", Some("lobby"), twice)
  let assert True = string.contains(reason, "presence")
  let assert True = string.contains(reason, "twice")

  let assert [] = keys(a, "lobby")
  Nil
}

/// A tracker that never comes up stops the runtime with
/// `beacon_presence_down` once the retries run out.
pub fn stops_when_tracker_never_starts_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_pw_down")
  let assert [a] = peers
  peer.on(a, fn() { pubsub.start() })
  let ann = start_session(a, "ann", Some("lobby"))

  let reason = peer.on(a, fn() { await_exit(runtime_pid(ann), 9000) })
  let assert Ok(reason) = reason
  let assert True = string.contains(reason, "beacon_presence_down")
  Nil
}

// --- FFI ------------------------------------------------------------------------

@external(erlang, "beacon_presence_watch_test_ffi", "watcher_of")
fn watcher_of(runtime: Pid) -> Result(Pid, Nil)

@external(erlang, "beacon_presence_watch_test_ffi", "suspend")
fn suspend(pid: Pid) -> Nil

@external(erlang, "beacon_presence_watch_test_ffi", "resume")
fn resume(pid: Pid) -> Nil

@external(erlang, "beacon_presence_watch_test_ffi", "await_exit")
fn await_exit(pid: Pid, timeout_ms: Int) -> Result(String, Nil)
