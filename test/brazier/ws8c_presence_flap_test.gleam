//// Session presence across a shard restart: entries from other nodes that
//// were present the whole time must not leave and join again while the
//// restarted shard catches up with its peers.
////
//// Sessions are runtimes on peer nodes inside holder processes (see
//// cluster/presence_watch_test). Waiting is always a receive or
//// `peer.eventually` with a deadline.

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
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

const wait_ms = 10_000

const receive_ms = 5000

const name = "pf"

// --- The app ------------------------------------------------------------------

type Model {
  Model(user: String, room: Option(String), online: List(Entry(String)))
}

type Msg {
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

fn in_room(model: Model) -> List(presence.Tracking(String)) {
  case model.room {
    Some(room) -> [Tracking(topic: room, key: model.user, meta: "here")]
    None -> []
  }
}

fn session_config(
  user: String,
  room: Option(String),
  proof: Subject(Proof),
) -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(user:, room:, online: []), effect.none())) },
    update: fn(model: Model, msg: Msg) {
      case msg {
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
    presence: Some(presence_watch.new(fast_config(), in_room, Online)),
    title: None,
  )
}

// --- Helpers ------------------------------------------------------------------

fn start_tracker(p: Peer) -> Nil {
  peer.on(p, fn() {
    pubsub.start()
    let assert Ok(_) = presence.start(fast_config())
    Nil
  })
}

fn start_session(p: Peer, user: String, room: String) -> Session {
  peer.on(p, fn() {
    let h = holder.start()
    let #(proof, started) =
      holder.run(h, fn() {
        let proof = process.new_subject()
        let config = session_config(user, Some(room), proof)
        #(proof, runtime.start(config, test_ctx.root()))
      })
    let assert Ok(runtime) = started
    Session(holder: h, runtime:, proof:)
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

/// Receive presence messages until `done` holds for the merged view; the
/// diffs on the way, or the view the app was left with.
fn collect_until(
  p: Peer,
  session: Session,
  done: fn(List(Entry(String))) -> Bool,
) -> Result(List(Diff(String)), List(String)) {
  collect_loop(p, session, done, [], [])
}

fn collect_loop(
  p: Peer,
  session: Session,
  done: fn(List(Entry(String))) -> Bool,
  diffs: List(Diff(String)),
  last: List(String),
) -> Result(List(Diff(String)), List(String)) {
  case next(p, session) {
    Error(Nil) -> Error(last)
    Ok(#(diff, online)) -> {
      let diffs = [diff, ..diffs]
      case done(online) {
        True -> Ok(list.reverse(diffs))
        False -> collect_loop(p, session, done, diffs, refs(online))
      }
    }
  }
}

fn view_is(expected: List(String)) -> fn(List(Entry(String))) -> Bool {
  fn(online) { keys(online) == expected }
}

fn keys(entries: List(Entry(String))) -> List(String) {
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(_) { entry.key })
  })
}

fn refs(entries: List(Entry(String))) -> List(String) {
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(meta) { entry.key <> "@" <> meta.ref })
  })
}

fn listed(p: Peer, topic: String) -> List(Entry(String)) {
  peer.on(p, fn() {
    let assert Ok(entries) = presence.list(tracker(), topic)
    entries
  })
}

/// A holder on `p` tracking `key` on `topic`.
fn track_on(p: Peer, topic: String, key: String) -> Holder {
  peer.on(p, fn() {
    let h = holder.start()
    let assert Ok(_) =
      holder.run(h, fn() { presence.track(tracker(), topic, key, "idle") })
    h
  })
}

fn kill_shard(p: Peer, topic: String) -> Nil {
  peer.on(p, fn() {
    let assert Ok(shard) = presence.shard_pid(tracker(), topic)
    process.kill(shard)
  })
}

/// The session's presence watcher; call on the session's node.
fn watcher(session: Session) -> Pid {
  // INVARIANT: a started runtime's subject is owned by its actor.
  let assert Ok(runtime) = process.subject_owner(session.runtime)
  let assert Ok(pid) = watcher_of(runtime)
    as "the runtime has no presence watcher"
  pid
}

/// Every ref of `key` in the joins and in the leaves of `diffs`.
fn mentions(diffs: List(Diff(String)), key: String) -> #(Int, Int) {
  let count = fn(entries: List(Entry(String))) {
    list.filter(keys(entries), fn(k) { k == key }) |> list.length
  }
  list.fold(diffs, #(0, 0), fn(acc, diff) {
    #(acc.0 + count(diff.joins), acc.1 + count(diff.leaves))
  })
}

// --- Tests --------------------------------------------------------------------

/// After the lobby's shard restarts on A, ann's session sees only its own
/// old entry leave and its new one join. bob, tracked on B the whole time,
/// neither leaves nor joins while A's new shard catches up with B. The next
/// change after that (cat joining on B) is the next thing ann sees, so no
/// late leave or join of bob is still on the way.
pub fn remote_entries_do_not_flap_on_shard_restart_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_ws8c_flap")
  let assert [a, b] = peers
  start_tracker(a)
  start_tracker(b)
  let ann = start_session(a, "ann", "lobby")
  let _bob = track_on(b, "lobby", "bob")
  let assert Ok(_) = collect_until(a, ann, view_is(["ann", "bob"]))
  let assert [ann_old, bob_ref] = refs(listed(a, "lobby"))

  kill_shard(a, "lobby")
  let assert Ok(#(restart, online)) = next(a, ann)
  let assert [left] = refs(restart.leaves)
  let assert True = left == ann_old
  let assert [ann_new] = refs(restart.joins)
  let assert True = ann_new != ann_old
  let assert True = refs(online) == [ann_new, bob_ref]

  // A's new shard has bob again once it has caught up with B.
  let assert True =
    peer.eventually(
      fn() { refs(listed(a, "lobby")) == [ann_new, bob_ref] },
      wait_ms,
    )
  let _cat = track_on(b, "lobby", "cat")
  let assert Ok(after) = collect_until(a, ann, view_is(["ann", "bob", "cat"]))
  let assert #(0, 0) = mentions(after, "bob")
  let assert [only] = after
  let assert [] = only.leaves
  let assert ["cat"] = keys(only.joins)
  Nil
}

/// bob leaves on B while A's lobby shard restarts. A's new shard never
/// held bob, so the transfer from B has nothing to remove: ann's session
/// still hears bob leave, exactly once, once A's shard has caught up with
/// B, and never sees bob join again.
pub fn remote_leave_during_restart_is_reported_once_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_ws8c_flap_leave")
  let assert [a, b] = peers
  start_tracker(a)
  start_tracker(b)
  let ann = start_session(a, "ann", "lobby")
  let bob = track_on(b, "lobby", "bob")
  let assert Ok(_) = collect_until(a, ann, view_is(["ann", "bob"]))

  kill_shard(a, "lobby")
  peer.on(b, fn() { holder.kill(bob) })
  let assert Ok(diffs) = collect_until(a, ann, view_is(["ann"]))
  let assert #(0, 1) = mentions(diffs, "bob")

  let _cat = track_on(b, "lobby", "cat")
  let assert Ok(after) = collect_until(a, ann, view_is(["ann", "cat"]))
  let assert #(0, 0) = mentions(after, "bob")
  Nil
}

/// A restarted shard that never hears from B (A and B are partitioned):
/// bob is not reported gone at the restart, but once down_period passes
/// without B, bob leaves, once. When the partition heals bob joins again.
pub fn unreachable_node_entries_leave_after_down_period_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_ws8c_flap_part")
  let assert [a, b] = peers
  start_tracker(a)
  start_tracker(b)
  let ann = start_session(a, "ann", "lobby")
  let _bob = track_on(b, "lobby", "bob")
  let assert Ok(_) = collect_until(a, ann, view_is(["ann", "bob"]))

  peer.partition(a, b)
  kill_shard(a, "lobby")
  let assert Ok(#(restart, _)) = next(a, ann)
  let assert #(0, 0) = mentions([restart], "bob")
  let assert Ok(gone) = collect_until(a, ann, view_is(["ann"]))
  let assert #(0, 1) = mentions(gone, "bob")

  peer.heal(a, b)
  let assert Ok(back) = collect_until(a, ann, view_is(["ann", "bob"]))
  let assert #(1, 0) = mentions(back, "bob")
  Nil
}

/// Sync answers the watcher must not act on, sent while it holds bob after
/// the restart: one from a process that is not the lobby's shard (what a
/// shard that has since gone down sends), and one from the shard with a
/// status the watcher does not know. Acting on the first would re-read the
/// shard before it caught up with B and make bob leave and join again; the
/// second is logged and skipped. The watcher keeps going: the next change
/// (cat joining) is the next thing ann sees.
pub fn stale_and_unknown_sync_answers_are_ignored_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_ws8c_flap_stale")
  let assert [a, b] = peers
  start_tracker(a)
  start_tracker(b)
  let ann = start_session(a, "ann", "lobby")
  let _bob = track_on(b, "lobby", "bob")
  let assert Ok(_) = collect_until(a, ann, view_is(["ann", "bob"]))
  let b_node = peer.on(b, node_name)

  kill_shard(a, "lobby")
  let assert Ok(#(restart, _)) = next(a, ann)
  let assert #(0, 0) = mentions([restart], "bob")
  let watcher_pid = peer.on(a, fn() { watcher(ann) })
  peer.on(a, fn() {
    let assert Ok(shard) = presence.shard_pid(tracker(), "lobby")
    let tag = atom.create("brazier_presence_synced")
    send_raw(watcher_pid, #(tag, process.self(), b_node, atom.create("synced")))
    send_raw(watcher_pid, #(tag, shard, b_node, atom.create("bogus")))
  })

  let assert True =
    peer.eventually(
      fn() { keys(listed(a, "lobby")) == ["ann", "bob"] },
      wait_ms,
    )
  let _cat = track_on(b, "lobby", "cat")
  let assert Ok(after) = collect_until(a, ann, view_is(["ann", "bob", "cat"]))
  let assert #(0, 0) = mentions(after, "bob")
  let assert [only] = after
  let assert [] = only.leaves
  let assert ["cat"] = keys(only.joins)
  let assert True = peer.on(a, fn() { process.is_alive(watcher_pid) })
  Nil
}

// --- FFI ----------------------------------------------------------------------

@external(erlang, "brazier_presence_watch_test_ffi", "watcher_of")
fn watcher_of(runtime: Pid) -> Result(Pid, Nil)

@external(erlang, "brazier_ws8c_presence_sync_ffi", "send_raw")
fn send_raw(pid: Pid, term: a) -> Nil

@external(erlang, "brazier_presence_watch_ffi", "node_name")
fn node_name() -> String
