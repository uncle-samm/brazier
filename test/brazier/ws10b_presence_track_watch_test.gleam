//// Tracking and watching together (`brazier.track_and_watch_presence`): a
//// session is on the topics `track` gives and follows the topics `watch`
//// gives without being on them.
////
//// Sessions are runtimes on peer nodes inside holder processes (see
//// ws8c_presence_watch_only_test); their presence comes from the public
//// builder. Waiting is always a receive or `peer.eventually` with a
//// deadline.

import brazier
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/effect
import brazier/element
import brazier/error
import brazier/internal/presence_watch
import brazier/presence.{type Presence}
import brazier/presence/holder.{type Holder}
import brazier/presence/sync.{type Diff, type Entry}
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
import gleam/string

const wait_ms = 10_000

const receive_ms = 5000

const name = "ptw"

// --- The app ------------------------------------------------------------------

type Model {
  Model(
    room: String,
    watched: List(String),
    online: Dict(String, List(Entry(String))),
  )
}

type Msg {
  Online(Diff(String))
  SetRoom(String)
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
  // INVARIANT: fast_config is a valid configuration.
  let assert Ok(tracker) = presence.handle(fast_config())
  tracker
}

/// The app's presence, built with the public builder: the session is "me"
/// in its room, and it watches the topics in `watched`.
fn tracking_and_watching() -> presence_watch.Watch(Model, Msg) {
  let codec =
    runtime.GeneratedCodec(
      encode_model: fn(_model) { "{}" },
      decode_model: fn(json) { Error("no model codec: " <> json) },
      decode_event: fn(_name, handler_id, _data, _path) {
        Error(error.RuntimeError(reason: "no client events: " <> handler_id))
      },
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
        [presence.Tracking(topic: model.room, key: "me", meta: "here")]
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
        SetRoom(room) -> #(Model(..model, room:), effect.none())
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
    presence: Some(tracking_and_watching()),
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
    let assert Ok(rt) = started
    Session(holder: h, runtime: rt, proof:)
  })
}

fn send(p: Peer, session: Session, msg: Msg) -> Nil {
  peer.on(p, fn() {
    process.send(session.runtime, runtime.EffectDispatched(message: msg))
  })
}

/// The next presence message the app on `p` saw, as its topic, join keys
/// and leave keys.
fn next(p: Peer, session: Session) -> #(String, List(String), List(String)) {
  let received =
    peer.on(p, fn() {
      holder.run(session.holder, fn() {
        process.receive(session.proof, receive_ms)
      })
    })
  let assert Ok(#(diff, _view)) = received as "no presence message in time"
  #(diff.topic, keys(diff.joins), keys(diff.leaves))
}

fn keys(entries: List(Entry(String))) -> List(String) {
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(_) { entry.key })
  })
}

fn listed(p: Peer, topic: String) -> List(String) {
  peer.on(p, fn() {
    let assert Ok(entries) = presence.list(tracker(), topic)
    keys(entries)
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

// --- Tests --------------------------------------------------------------------

/// The session is on its room and hears it, and it hears the watched lobby
/// without being on it. The room is also in the watched list, and it is
/// followed once: its first message comes once, and the next change is the
/// next message.
pub fn tracks_its_room_and_watches_the_lobby_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_ws10b_track_watch")
  let assert [a] = peers
  start_tracker(a)
  let _bob = track_on(a, "lobby", "bob")
  let assert True =
    peer.eventually(fn() { listed(a, "lobby") == ["bob"] }, wait_ms)

  let session = start_session(a, "room", ["lobby", "room"])
  let first = next(a, session)
  let second = next(a, session)
  let assert [#("lobby", ["bob"], []), #("room", ["me"], [])] =
    list.sort([first, second], fn(x, y) { string.compare(x.0, y.0) })
  let assert ["me"] = listed(a, "room")
  let assert ["bob"] = listed(a, "lobby")

  // The next change on the room is the next message: the room was not
  // followed a second time for being watched as well.
  let _cat = track_on(a, "room", "cat")
  let assert #("room", ["cat"], []) = next(a, session)
  let _dan = track_on(a, "lobby", "dan")
  let assert #("lobby", ["dan"], []) = next(a, session)
  Nil
}

/// Moving rooms moves the tracking; the watched lobby stays followed and
/// the session never appears there.
pub fn tracking_follows_the_state_while_watching_stays_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_ws10b_track_watch_move")
  let assert [a] = peers
  start_tracker(a)
  let session = start_session(a, "red", ["lobby"])
  let assert #("red", ["me"], []) = next(a, session)

  // The leave on red and the join on blue are reports on two topics, so
  // their order is not part of the contract.
  send(a, session, SetRoom("blue"))
  let first = next(a, session)
  let second = next(a, session)
  let assert [#("blue", ["me"], []), #("red", [], ["me"])] =
    list.sort([first, second], fn(x, y) { string.compare(x.0, y.0) })
  let assert True = peer.eventually(fn() { listed(a, "red") == [] }, wait_ms)
  let assert ["me"] = listed(a, "blue")

  let _bob = track_on(a, "lobby", "bob")
  let assert #("lobby", ["bob"], []) = next(a, session)
  let assert ["bob"] = listed(a, "lobby")
  Nil
}
