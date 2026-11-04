//// Session presence over real runtimes on peer nodes (`brazier.presence`).
////
//// Each session is a runtime started on a peer inside a holder process
//// (brazier/presence/holder). The holder owns the runtime's link and the
//// proof subject the app's `update` reports every presence message to, so
//// the test reads what the app saw through the holder. Waiting is always
//// a receive or `peer.eventually` with a deadline.

import brazier/cluster/peer.{type Peer, Timeout}
import brazier/effect
import brazier/error
import brazier/internal/presence_watch
import brazier/presence.{type Presence, Tracking}
import brazier/presence/holder.{type Holder}
import brazier/presence/sync.{type Diff, type Entry}
import brazier/pubsub
import brazier/runtime
import brazier/test_ctx
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
    as "presence.handle succeeds"
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
    title: None,
  )
}

// --- Helpers ------------------------------------------------------------------

/// PubSub and the tracker on `p`.
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
  user: String,
  room: Option(String),
  track: fn(Model) -> List(presence.Tracking(String)),
) -> Result(Session, error.BrazierError) {
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
    as "try_session succeeds"
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
      as "presence.list succeeds"
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
      as "presence.track succeeds"
    h
  })
}

fn runtime_pid(session: Session) -> Pid {
  // INVARIANT: a started runtime's subject is owned by its actor.
  let assert Ok(pid) = process.subject_owner(session.runtime)
    as "process.subject_owner succeeds"
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
  use peers <- peer.with_members(2, "brazier_pw_cross")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_tracker(a)
  start_tracker(b)

  let ann = start_session(a, "ann", Some("lobby"))
  let assert Ok([first]) = await_view(a, ann, ["ann=here"])
    as "await_view succeeds"
  let assert [] = first.leaves as "first.leaves returns an empty list"

  let bob = track_on(b, "lobby", "bob", "idle")
  let assert Ok(_) = await_view(a, ann, ["ann=here", "bob=idle"])
    as "await_view succeeds"

  let bea = start_session(b, "bea", Some("lobby"))
  let all = ["ann=here", "bea=here", "bob=idle"]
  let assert Ok(_) = await_view(b, bea, all) as "await_view succeeds"
  let assert Ok(_) = await_view(a, ann, all) as "await_view succeeds"

  // A state change updates the tracked meta everywhere.
  send(a, ann, SetStatus("away"))
  let away = ["ann=away", "bea=here", "bob=idle"]
  let assert Ok(_) = await_view(a, ann, away) as "await_view succeeds"
  let assert Ok(_) = await_view(b, bea, away) as "await_view succeeds"
  assert sees(b, "lobby", ["ann", "bea", "bob"])

  // Leaving the room: the others see the leave, the session sees all leave.
  send(b, bea, Leave)
  let assert Ok(left) = await_view(b, bea, []) as "await_view succeeds"
  let assert [_, ..] = left as "left returns a non-empty list"
  let assert Ok(_) = await_view(a, ann, ["ann=away", "bob=idle"])
    as "await_view succeeds"
  assert sees(a, "lobby", ["ann", "bob"])

  // A tracked process exiting leaves too.
  peer.on(b, fn() { holder.kill(bob) })
  let assert Ok(_) = await_view(a, ann, ["ann=away"]) as "await_view succeeds"
  Nil
}

/// Diffs that queue up while the watcher is busy reach the app as one
/// message per 100.
pub fn coalesces_queued_diffs_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_pw_coalesce")
  let assert [a] = peers as "the cluster starts one peer"
  start_tracker(a)
  let ann = start_session(a, "ann", Some("lobby"))
  let assert Ok(_) = await_view(a, ann, ["ann=here"]) as "await_view succeeds"

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
            as "presence.track succeeds"
          h
        })
      resume(w)
      holders
    })
  let assert 150 = list.length(holders) as "list.length returns 150"

  let assert Ok(#(first, _)) = next(a, ann) as "next succeeds"
  let assert Ok(#(second, online)) = next(a, ann) as "next succeeds"
  let assert 100 = list.length(flatten(first.joins))
    as "list.length returns 100"
  let assert 50 = list.length(flatten(second.joins)) as "list.length returns 50"
  let assert [] = first.leaves as "first.leaves returns an empty list"
  let assert [] = second.leaves as "second.leaves returns an empty list"
  let assert 151 = list.length(online) as "list.length returns 151"
  Nil
}

/// When the topic's shard dies, the watcher tracks the session again on
/// the restarted shard and tells the app the old entry left and the new
/// one joined, in one message.
pub fn retracks_after_shard_restart_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pw_shard")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_tracker(a)
  start_tracker(b)
  let ann = start_session(a, "ann", Some("lobby"))
  let assert Ok(_) = await_view(a, ann, ["ann=here"]) as "await_view succeeds"
  assert sees(b, "lobby", ["ann"])
  let assert [old] = refs(listed(a, "lobby")) as "refs returns a list of one"

  let old_shard =
    peer.on(a, fn() {
      let assert Ok(shard) = presence.shard_pid(tracker(), "lobby")
        as "presence.shard_pid succeeds"
      process.kill(shard)
      shard
    })
  let assert Ok(#(diff, online)) = next(a, ann) as "next succeeds"
  let assert [new] = refs(diff.joins) as "refs returns a list of one"
  let assert [left] = refs(diff.leaves) as "refs returns a list of one"
  assert left == old
  assert new != old
  assert refs(online) == [new]

  let assert Ok(new_shard) =
    peer.on(a, fn() { presence.shard_pid(tracker(), "lobby") })
    as "presence.shard_pid succeeds"
  assert new_shard != old_shard
  assert refs(listed(a, "lobby")) == [new]
  assert peer.eventually(fn() { refs(listed(b, "lobby")) == [new] }, wait_ms)
  Nil
}

/// A runtime that is killed or shut down takes its entries with it, on
/// every node, and its watcher is gone.
pub fn cleanup_when_runtime_dies_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_pw_cleanup")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_tracker(a)
  start_tracker(b)
  let ann = start_session(a, "ann", Some("lobby"))
  let amy = start_session(a, "amy", Some("lobby"))
  assert sees(b, "lobby", ["amy", "ann"])
  let #(ann_watcher, amy_watcher) =
    peer.on(a, fn() { #(watcher(ann), watcher(amy)) })

  peer.on(a, fn() { process.kill(runtime_pid(ann)) })
  assert sees(b, "lobby", ["amy"])
  assert peer.eventually(fn() { !alive(a, ann_watcher) }, wait_ms)

  peer.on(a, fn() { process.send(amy.runtime, runtime.Shutdown) })
  assert sees(b, "lobby", [])
  assert sees(a, "lobby", [])
  assert peer.eventually(fn() { !alive(a, amy_watcher) }, wait_ms)
  Nil
}

/// Losing the PubSub partition the watcher subscribes through stops the
/// runtime with `brazier_pubsub_down`.
pub fn stops_when_pubsub_partition_dies_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_pw_pubsub")
  let assert [a] = peers as "the cluster starts one peer"
  start_tracker(a)
  let ann = start_session(a, "ann", Some("lobby"))
  let assert Ok(_) = await_view(a, ann, ["ann=here"]) as "await_view succeeds"

  let reason =
    peer.on(a, fn() {
      let assert Ok(partition) = pubsub.partition_for(watcher(ann))
        as "pubsub.partition_for succeeds"
      process.kill(partition)
      await_exit(runtime_pid(ann), receive_ms)
    })
  let assert Ok(reason) = reason as "the runtime exited within the wait"
  assert string.contains(reason, "brazier_pubsub_down")
  Nil
}

/// Trackings the tracker refuses, or a key tracked twice on a topic, fail
/// the runtime's start and leave nothing tracked.
pub fn refused_trackings_fail_the_start_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_pw_refused")
  let assert [a] = peers as "the cluster starts one peer"
  start_tracker(a)

  let assert Error(error.RuntimeError(reason)) =
    try_session(a, "", Some("lobby"), in_room)
    as "try_session returns Error(RuntimeError)"
  assert string.contains(reason, "presence")

  let twice = fn(_model) {
    [
      Tracking(topic: "lobby", key: "ann", meta: "a"),
      Tracking(topic: "lobby", key: "ann", meta: "b"),
    ]
  }
  let assert Error(error.RuntimeError(reason)) =
    try_session(a, "ann", Some("lobby"), twice)
    as "try_session returns Error(RuntimeError)"
  assert string.contains(reason, "presence")
  assert string.contains(reason, "twice")

  let assert [] = keys(a, "lobby") as "keys returns an empty list"
  Nil
}

/// A tracker that never comes up stops the runtime with
/// `brazier_presence_down` once the retries run out.
pub fn stops_when_tracker_never_starts_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_pw_down")
  let assert [a] = peers as "the cluster starts one peer"
  peer.on(a, fn() { pubsub.start() })
  let ann = start_session(a, "ann", Some("lobby"))

  let reason = peer.on(a, fn() { await_exit(runtime_pid(ann), 9000) })
  let assert Ok(reason) = reason as "the runtime exited within the wait"
  assert string.contains(reason, "brazier_presence_down")
  Nil
}

// --- FFI ------------------------------------------------------------------------

@external(erlang, "brazier_presence_watch_test_ffi", "watcher_of")
fn watcher_of(runtime: Pid) -> Result(Pid, Nil)

@external(erlang, "brazier_presence_watch_test_ffi", "suspend")
fn suspend(pid: Pid) -> Nil

@external(erlang, "brazier_presence_watch_test_ffi", "resume")
fn resume(pid: Pid) -> Nil

@external(erlang, "brazier_presence_watch_test_ffi", "await_exit")
fn await_exit(pid: Pid, timeout_ms: Int) -> Result(String, Nil)
