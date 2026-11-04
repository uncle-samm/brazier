//// Relays for multi-node tests. A relay is a holder process on a peer
//// (brazier/presence/holder) that receives what a test waits for, so the
//// test takes each message with a deadline, like ExUnit's
//// `assert_receive`, instead of polling a counter or a recorder that tells
//// no one. Set a relay up before triggering what it waits for. It ends
//// with its peer, which `peer.with_cluster` always stops.

import brazier/cluster/peer.{type Peer}
import brazier/presence/holder.{type Holder}
import brazier/pubsub
import brazier/telemetry
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list

/// Telemetry events emitted on a peer, relayed to a holder there.
pub type Events {
  Events(holder: Holder, events: Subject(telemetry.Event))
}

/// Relay every event in `names` emitted on `p`. The handler sends to a
/// subject the holder owns, so the event itself is the message: no read
/// of state another handler of the same event fills, which telemetry runs
/// in no set order.
pub fn events(p: Peer, names: List(List(String))) -> Events {
  peer.on(p, fn() {
    let h = holder.start()
    let events =
      holder.run(h, fn() {
        let events = process.new_subject()
        let id = "brazier_cluster_relay_" <> int.to_string(unique_integer())
        let assert Ok(Nil) =
          telemetry.attach(id, names, fn(event) { process.send(events, event) })
          as "the relay handler attaches"
        events
      })
    Events(holder: h, events:)
  })
}

/// The next relayed event, waiting up to `timeout_ms` for it.
pub fn next_event(
  p: Peer,
  relay: Events,
  timeout_ms: Int,
) -> Result(telemetry.Event, Nil) {
  within(p, relay.holder, timeout_ms, fn() {
    process.receive(relay.events, timeout_ms)
  })
}

/// How many relayed events have arrived and not been taken, without
/// waiting.
pub fn pending_events(p: Peer, relay: Events) -> Int {
  peer.on(p, fn() {
    holder.run(relay.holder, fn() {
      count_pending(fn() { process.receive(relay.events, 0) }, 0)
    })
  })
}

/// PubSub deliveries on a peer, received by a holder subscribed there.
pub type Deliveries {
  Deliveries(holder: Holder)
}

/// A holder on `p` subscribed to `topics`.
pub fn deliveries(p: Peer, topics: List(String)) -> Deliveries {
  peer.on(p, fn() {
    let h = holder.start()
    holder.run(h, fn() {
      list.each(topics, fn(topic) {
        let assert Ok(Nil) = pubsub.try_subscribe(topic)
          as "the relay subscribes"
        Nil
      })
    })
    Deliveries(holder: h)
  })
}

/// The next delivered message (the `Message` of
/// `{brazier_pubsub, Topic, Message}`), decoded on the peer with `decode`,
/// waiting up to `timeout_ms` for it.
pub fn next_delivery(
  p: Peer,
  relay: Deliveries,
  timeout_ms: Int,
  decode: fn(Dynamic) -> a,
) -> Result(a, Nil) {
  within(p, relay.holder, timeout_ms, fn() {
    case process.selector_receive(delivered(), timeout_ms) {
      Ok(message) -> Ok(decode(message))
      Error(Nil) -> Error(Nil)
    }
  })
}

/// How many deliveries have arrived and not been taken, without waiting.
pub fn pending_deliveries(p: Peer, relay: Deliveries) -> Int {
  peer.on(p, fn() {
    holder.run(relay.holder, fn() {
      count_pending(fn() { process.selector_receive(delivered(), 0) }, 0)
    })
  })
}

fn delivered() -> process.Selector(Dynamic) {
  process.new_selector()
  |> process.select_record(
    tag: atom.create("brazier_pubsub"),
    fields: 2,
    mapping: fn(delivery) { element(3, delivery) },
  )
}

/// Run a waiting `run` in `h` on `p`. The holder and the rpc get margins
/// over the wait, so only a stuck holder or a lost peer trips them.
fn within(p: Peer, h: Holder, timeout_ms: Int, run: fn() -> a) -> a {
  peer.on_within(p, timeout_ms + 10_000, fn() {
    holder.run_within(h, timeout_ms + 5000, run)
  })
}

fn count_pending(take: fn() -> Result(a, Nil), count: Int) -> Int {
  case take() {
    Ok(_) -> count_pending(take, count + 1)
    Error(Nil) -> count
  }
}

@external(erlang, "erlang", "element")
fn element(index: Int, tuple: Dynamic) -> Dynamic

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
