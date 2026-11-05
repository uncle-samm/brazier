//// What watchers see when the shard of a tracking session restarts. The
//// session tracks itself again, under a new ref, and every watcher, on
//// the same node or another, sees the old ref leave and the new ref join.
//// This is Phoenix.Tracker's model: a restarted shard is a new replica
//// (a new vsn), its old replica is permanently down at once, and a
//// presence is identified by its ref, so a tracking made again is a new
//// presence. CLUSTERING.md ("Shard restarts") documents it.
////
//// Sessions are runtimes on peer nodes inside holder processes (see
//// ws8c_presence_watch_only_test). Waiting is always a receive with a
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
import brazier/presence/sync.{type Diff, type Entry, type Meta}
import brazier/presence/wake
import brazier/pubsub
import brazier/runtime
import brazier/test_ctx
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

const receive_ms = 5000

const name = "prs"

const topic = "lobby"

// --- The app ------------------------------------------------------------------

/// `room` is where the session tracks itself as "me" ("" tracks nothing);
/// `watched` are the topics it follows without being on them.
type Model {
  Model(
    room: String,
    watched: List(String),
    online: Dict(String, List(Entry(String))),
  )
}

type Msg {
  Online(Diff(String))
}

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

fn presence_of_app() -> presence_watch.Watch(Model, Msg) {
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
      init: fn(_ctx) { Ok(Model(room: "", watched: [], online: dict.new())) },
      update: fn(model, _msg) { model },
      view: fn(_model) { element.text("") },
    )
    |> brazier.secret_key("a-test-secret-that-is-long-enough-0123456789")
    |> brazier.track_and_watch_presence(
      tracker: fast_config(),
      track: fn(model: Model) {
        case model.room {
          "" -> []
          room -> [presence.Tracking(topic: room, key: "me", meta: "here")]
        }
      },
      watch: fn(model: Model) { model.watched },
      on_presence: Online,
    )
    |> brazier.to_config(codec, 8080)
    as "the app has a secret key"
  let assert Some(watch) = config.presence
    as "track_and_watch_presence sets presence"
  watch
}

fn session_config(
  room: String,
  watched: List(String),
  proof: Subject(Proof),
) -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) {
      Ok(#(Model(room:, watched:, online: dict.new()), effect.none()))
    },
    update: fn(model: Model, msg: Msg) {
      case msg {
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
    presence: Some(presence_of_app()),
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

fn start_session(p: Peer, room: String, watched: List(String)) -> Session {
  peer.on(p, fn() {
    let h = holder.start()
    let #(proof, started) =
      holder.run(h, fn() {
        let proof = process.new_subject()
        #(
          proof,
          runtime.start(session_config(room, watched, proof), test_ctx.root()),
        )
      })
    let assert Ok(rt) = started as "runtime.start succeeds"
    Session(holder: h, runtime: rt, proof:)
  })
}

fn next(p: Peer, session: Session) -> Result(Proof, Nil) {
  peer.on(p, fn() {
    holder.run(session.holder, fn() {
      process.receive(session.proof, receive_ms)
    })
  })
}

/// The refs of "me" in a list.
fn refs_of_me(entries: List(Entry(String))) -> List(String) {
  entries
  |> list.filter(fn(entry) { entry.key == "me" })
  |> list.flat_map(fn(entry) { entry.metas })
  |> list.map(fn(meta: Meta(String)) { meta.ref })
}

/// Receive messages on the topic until the view holds exactly one "me"
/// whose ref is not `old`; the diffs on the way, in order.
fn collect_until_new_ref(
  p: Peer,
  session: Session,
  old: String,
  diffs: List(Diff(String)),
) -> #(List(Diff(String)), String) {
  let assert Ok(#(diff, view)) = next(p, session)
    as "no presence message in time"
  let diffs = case diff.topic == topic {
    True -> [diff, ..diffs]
    False -> diffs
  }
  case diff.topic == topic, refs_of_me(view) {
    True, [ref] if ref != old -> #(list.reverse(diffs), ref)
    _, _ -> collect_until_new_ref(p, session, old, diffs)
  }
}

/// The index of the first diff for which `has` holds.
fn first_index(
  diffs: List(Diff(String)),
  has: fn(Diff(String)) -> Bool,
) -> Result(Int, Nil) {
  diffs
  |> list.index_map(fn(diff, index) { #(diff, index) })
  |> list.find(fn(pair) { has(pair.0) })
  |> result.map(fn(pair) { pair.1 })
}

/// The watcher's first view of the lobby holds "me" once: its ref.
fn first_ref(p: Peer, session: Session) -> String {
  let assert Ok(#(diff, view)) = next(p, session)
    as "no first presence message in time"
  assert diff.topic == topic
  let assert [ref] = refs_of_me(view) as "the first view holds me once"
  ref
}

/// After the restart, the watcher's diffs carry the old ref as a leave and
/// the new one as a join, the leave not after the join, and its view ends
/// with the new ref only.
fn assert_leave_then_join(p: Peer, session: Session, old: String) -> Nil {
  let #(diffs, new) = collect_until_new_ref(p, session, old, [])
  let assert Ok(left) =
    first_index(diffs, fn(diff) { list.contains(refs_of_me(diff.leaves), old) })
    as "the old ref never left"
  let assert Ok(joined) =
    first_index(diffs, fn(diff) { list.contains(refs_of_me(diff.joins), new) })
    as "the new ref never joined"
  assert left <= joined
  // Nothing on the way re-joined the old ref or left the new one.
  assert !list.any(diffs, fn(diff) {
    list.contains(refs_of_me(diff.joins), old)
    || list.contains(refs_of_me(diff.leaves), new)
  })
}

// --- Tests --------------------------------------------------------------------

/// The tracking session is on A. A's lobby shard restarts: the session
/// tracks itself again under a new ref. A watcher on A and a watcher on B
/// each see the old ref leave and the new ref join.
pub fn retracked_entry_leaves_and_joins_for_every_watcher_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_ws10b_restart_semantics")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_tracker(a)
  start_tracker(b)
  let tracked = start_session(a, topic, [])
  let own = first_ref(a, tracked)

  let on_a = start_session(a, "", [topic])
  let on_b = start_session(b, "", [topic])
  assert first_ref(a, on_a) == own
  assert first_ref(b, on_b) == own

  peer.on(a, fn() {
    let assert Ok(shard) = presence.shard_pid(tracker(), topic)
      as "the lobby has a shard"
    process.kill(shard)
  })

  assert_leave_then_join(a, on_a, own)
  assert_leave_then_join(b, on_b, own)
}

/// The race behind the test above, made certain. A watcher on A is held
/// still while A's lobby shard restarts and the tracking session tracks
/// itself again, so the new shard's join is queued behind the old shard's
/// DOWN when it runs. The join must not be reported before the leave: the
/// watcher reports both from the read it does once the shard is back.
pub fn queued_join_waits_for_the_leave_of_the_restarted_shard_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(1, "brazier_ws10b_restart_queued")
  let assert [a] = peers as "the cluster starts one peer"
  start_tracker(a)
  let tracked = start_session(a, topic, [])
  let own = first_ref(a, tracked)
  let on_a = start_session(a, "", [topic])
  assert first_ref(a, on_a) == own

  // `erlang:suspend_process/1` is undone when the suspender exits, so a
  // holder on A suspends and later resumes the watcher (it ends with A).
  let #(suspender, w) =
    peer.on(a, fn() {
      let suspender = holder.start()
      let w = watcher(on_a)
      holder.run(suspender, fn() { suspend(w) })
      let assert Ok(shard) = presence.shard_pid(tracker(), topic)
        as "the lobby has a shard"
      process.kill(shard)
      #(suspender, w)
    })
  // The session's tracking on the new shard is a join the shard reports
  // after storing it, so each diff re-checks the listing.
  let retracked =
    peer.until(
      a,
      wake.diffs(tracker(), topic),
      fn() {
        case presence.list(tracker(), topic) {
          // The shard is restarting.
          Error(presence.TrackerDown) -> False
          listed -> {
            let assert Ok(entries) = listed as "the lobby can be listed"
            case refs_of_me(entries) {
              [ref] -> ref != own
              _ -> False
            }
          }
        }
      },
      receive_ms,
    )
  peer.on(a, fn() { holder.run(suspender, fn() { resume(w) }) })
  assert retracked as "the session never tracked itself again"

  let #(diffs, new) = collect_until_new_ref(a, on_a, own, [])
  let assert [diff] = diffs as "the leave and the join come in one message"
  assert refs_of_me(diff.leaves) == [own]
  assert refs_of_me(diff.joins) == [new]
}

/// The session's presence watcher; call on the session's node.
fn watcher(session: Session) -> process.Pid {
  let assert Ok(runtime) = process.subject_owner(session.runtime)
    as "a started runtime's subject is owned by its actor"
  let assert Ok(pid) = watcher_of(runtime)
    as "the runtime has no presence watcher"
  pid
}

@external(erlang, "brazier_presence_watch_test_ffi", "watcher_of")
fn watcher_of(runtime: process.Pid) -> Result(process.Pid, Nil)

@external(erlang, "brazier_presence_watch_test_ffi", "suspend")
fn suspend(pid: process.Pid) -> Nil

@external(erlang, "brazier_presence_watch_test_ffi", "resume")
fn resume(pid: process.Pid) -> Nil
