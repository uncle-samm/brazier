//// The shard's sync waiters (brazier_presence_shard, "Sync waiters"),
//// driven on one node by fake peers (see brazier_presence_test_ffi): a
//// process asks when the shard has caught up with some nodes and gets one
//// answer per node, after the diffs of what the shard learnt before. A
//// shard takes replication messages only from verified cluster members, so
//// the tests that hear from the ghost count it as one (with_verified).
////
//// Every presence is stopped after its test even when the test fails
//// (with_presence), and nothing polls: a test waits for the shard's own
//// heartbeat ticks (await.with_watch_info) or for its answer.

import brazier/await
import brazier/cluster/log_capture
import brazier/monitored
import brazier/presence.{type Presence, Down}
import brazier/pubsub
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/json

const wait_ms = 5000

type Ref

fn start(down_period: Int) -> Presence(String) {
  pubsub.start()
  let name = "ws8c_sync" <> int.to_string(unique_integer())
  let assert Ok(p) =
    presence.start(
      presence.new(name, json.string, decode.string)
      |> presence.broadcast_period(20)
      |> presence.max_silent_periods(2)
      |> presence.down_period(down_period)
      |> presence.permdown_period(down_period * 100),
    )
    as "presence.start succeeds"
  p
}

/// Run `body` with a fresh presence and stop it afterwards, even when
/// `body` fails: a shard left running keeps heartbeating every 20 ms for
/// the rest of the test run.
fn with_presence(down_period: Int, body: fn(Presence(String)) -> a) -> a {
  let p = start(down_period)
  use <- monitored.with_cleanup(fn() {
    let assert Ok(Nil) = presence.stop(p) as "stopping the test's presence"
    Nil
  })
  body(p)
}

/// The number of 20 ms heartbeat ticks that fit in `wait_ms`: the bound
/// for a test that waits tick by tick.
const max_ticks = 250

fn shard(p: Presence(String)) -> Pid {
  let assert Ok(shard) = presence.shard_pid(p, "room")
    as "presence.shard_pid succeeds"
  shard
}

/// Deliver `message` as a peer would, and wait until the shard handled it
/// (the replicas call is answered after it).
fn send_peer(p: Presence(String), message: Dynamic) -> Nil {
  let topic = "brazier_presence:" <> presence.name(p) <> ":1"
  send_peer_ffi(shard(p), topic, message)
  let assert Ok(_) = presence.replicas(p, "room")
    as "presence.replicas succeeds"
  Nil
}

/// The shard's answer for one node, waiting at most `wait_ms`.
fn answer(shard: Pid) -> Result(#(String, String), Nil) {
  receive_synced(shard, wait_ms)
}

// --- Tests --------------------------------------------------------------------

/// The ghost node says it issued one event; the shard holds none of them.
/// The answer only comes once the transfer brought its entry, and after
/// the diff of that entry.
pub fn synced_comes_after_the_entries_it_waited_for_test() {
  // Isolated: it subscribes the test process, whose mailbox then gets the
  // diffs. In eunit's shared process a failure here would leave that
  // subscription, and its diffs, to the next tests.
  use <- monitored.isolated
  use <- with_verified(["ghost@host"])
  use p <- with_presence(5000)
  let assert Ok(Nil) = presence.subscribe(p, "room")
    as "presence.subscribe succeeds"
  let ghost = fake_ref("ghost@host", 1)
  send_peer(p, heartbeat_at(ghost, 1, 1))
  await_sync(shard(p), ["ghost@host"])
  let assert Ok(_) = presence.replicas(p, "room")
    as "presence.replicas succeeds"
  // A call answered after the request: nothing was sent yet.
  let assert Error(Nil) = receive_synced(shard(p), 0)
    as "receive_synced returns Error(Nil)"

  send_peer(p, transfer_ack(ghost, 1, "room", [#("remote", "\"hi\"")]))
  let assert Ok("diff") = receive_any(wait_ms) as "receive_any succeeds"
  let assert Ok(#("ghost@host", "synced")) = answer(shard(p))
    as "answer succeeds"
  let assert Ok(Nil) = presence.unsubscribe(p, "room")
    as "presence.unsubscribe succeeds"
}

/// A node the shard knows and holds everything of is answered at once.
pub fn synced_at_once_when_already_caught_up_test() {
  use <- with_verified(["ghost@host"])
  use p <- with_presence(5000)
  let ghost = fake_ref("ghost@host", 1)
  send_peer(p, transfer_ack(ghost, 1, "room", [#("remote", "\"hi\"")]))
  send_peer(p, heartbeat_at(ghost, 1, 1))
  await_sync(shard(p), ["ghost@host"])
  let assert Ok(_) = presence.replicas(p, "room")
    as "presence.replicas succeeds"
  let assert Ok(#("ghost@host", "synced")) = receive_synced(shard(p), 0)
    as "receive_synced succeeds"
}

/// A node never heard from is absent once down_period has passed since the
/// shard started (the rule that would mark it down had it been known).
pub fn absent_for_a_node_never_heard_from_test() {
  use p <- with_presence(100)
  await_sync(shard(p), ["nobody@host"])
  let assert Ok(#("nobody@host", "absent")) = answer(shard(p))
    as "answer succeeds"
}

/// A node whose replica is down is answered at once: its entries are
/// hidden, so a watcher holding them reports them gone.
pub fn down_for_a_node_that_is_down_test() {
  use <- with_verified(["ghost@host"])
  use p <- with_presence(100)
  use tick <- await.with_watch_info(shard(p), "heartbeat")
  let ghost = fake_ref("ghost@host", 1)
  send_peer(p, transfer_ack(ghost, 1, "room", [#("remote", "\"hi\"")]))
  // The shard marks a silent replica down on a heartbeat tick, once
  // down_period has passed: check after each tick.
  await.until_info(
    tick,
    shard(p),
    fn() { presence.replicas(p, "room") == Ok([#("ghost@host", Down)]) },
    max_ticks,
    "the ghost's replica marked down",
  )
  await_sync(shard(p), ["ghost@host"])
  let assert Ok(#("ghost@host", "down")) = answer(shard(p)) as "answer succeeds"
}

/// The ghost keeps heartbeating a clock the shard never catches up with
/// (it answers no transfer request): the waiter is told `timeout` after
/// down_period, and the shard logs it.
pub fn timeout_when_the_node_never_catches_up_test() {
  use <- with_verified(["ghost@host"])
  use p <- with_presence(300)
  use tick <- await.with_watch_info(shard(p), "heartbeat")
  let ghost = fake_ref("ghost@host", 1)
  send_peer(p, heartbeat_at(ghost, 1, 5))
  let #(answered, lines) =
    log_capture.capture(fn() {
      await_sync(shard(p), ["ghost@host"])
      keep_alive_until_answered(p, tick, ghost, max_ticks)
    })
  let assert Ok(#("ghost@host", "timeout")) = answered as "answered is Ok"
  assert log_capture.contains(lines, "warning", "did not sync with ghost@host")
}

/// Heartbeat as the ghost once per shard heartbeat tick, so the shard never
/// marks it down, until the shard answers, at most `ticks` times. The shard
/// answers while handling a tick, and `expect_info` returns once it has, so
/// a 0 ms receive sees any answer.
fn keep_alive_until_answered(
  p: Presence(String),
  tick: await.InfoWatch,
  ghost: Ref,
  ticks: Int,
) -> Result(#(String, String), Nil) {
  case receive_synced(shard(p), 0) {
    Ok(answered) -> Ok(answered)
    Error(Nil) if ticks <= 0 -> Error(Nil)
    Error(Nil) -> {
      await.expect_info(tick, shard(p), "a shard heartbeat tick")
      send_peer(p, heartbeat_at(ghost, 1, 5))
      keep_alive_until_answered(p, tick, ghost, ticks - 1)
    }
  }
}

/// Several nodes in one request get one answer each; duplicates are one.
pub fn one_answer_per_distinct_node_test() {
  use p <- with_presence(100)
  await_sync(shard(p), ["b@host", "a@host", "b@host"])
  let assert Ok(first) = answer(shard(p)) as "answer succeeds"
  let assert Ok(second) = answer(shard(p)) as "answer succeeds"
  assert [first, second] == [#("a@host", "absent"), #("b@host", "absent")]
    || [first, second] == [#("b@host", "absent"), #("a@host", "absent")]
  let assert Ok(_) = presence.replicas(p, "room")
    as "presence.replicas succeeds"
  let assert Error(Nil) = receive_synced(shard(p), 0)
    as "receive_synced returns Error(Nil)"
}

/// Requests with nodes that are not binaries, or without a list, are
/// logged and ignored; the shard keeps running and answers the next one.
pub fn malformed_requests_are_logged_and_ignored_test() {
  use p <- with_presence(100)
  let before = shard(p)
  let tag = atom.create("brazier_presence_await_sync")
  let #(_, lines) =
    log_capture.capture(fn() {
      send_raw(before, #(tag, process.self(), [atom.create("a@host")]))
      send_raw(before, #(tag, process.self(), "a@host"))
      let assert Ok(_) = presence.replicas(p, "room")
        as "presence.replicas succeeds"
      Nil
    })
  assert log_capture.contains(lines, "warning", "non-binary nodes")
  assert log_capture.contains(lines, "warning", "unexpected message")
  let assert Error(Nil) = receive_synced(before, 0)
    as "receive_synced returns Error(Nil)"
  await_sync(before, ["a@host"])
  let assert Ok(#("a@host", "absent")) = answer(before) as "answer succeeds"
  assert shard(p) == before
}

// --- FFI ----------------------------------------------------------------------

@external(erlang, "brazier_presence_test_ffi", "fake_ref")
fn fake_ref(node: String, vsn: Int) -> Ref

@external(erlang, "brazier_presence_test_ffi", "transfer_ack")
fn transfer_ack(
  ref: Ref,
  pool_size: Int,
  topic: String,
  entries: List(#(String, String)),
) -> Dynamic

@external(erlang, "brazier_presence_test_ffi", "send_peer")
fn send_peer_ffi(shard: Pid, topic: String, message: Dynamic) -> Nil

@external(erlang, "brazier_presence_test_ffi", "with_verified")
fn with_verified(nodes: List(String), run: fn() -> a) -> a

@external(erlang, "brazier_presence_test_ffi", "unique_positive")
fn unique_integer() -> Int

@external(erlang, "brazier_ws8c_presence_sync_ffi", "heartbeat_at")
fn heartbeat_at(ref: Ref, pool_size: Int, clock: Int) -> Dynamic

@external(erlang, "brazier_ws8c_presence_sync_ffi", "await_sync")
fn await_sync(shard: Pid, nodes: List(String)) -> Nil

@external(erlang, "brazier_ws8c_presence_sync_ffi", "send_raw")
fn send_raw(pid: Pid, term: a) -> Nil

@external(erlang, "brazier_ws8c_presence_sync_ffi", "receive_synced")
fn receive_synced(shard: Pid, timeout_ms: Int) -> Result(#(String, String), Nil)

@external(erlang, "brazier_ws8c_presence_sync_ffi", "receive_any")
fn receive_any(timeout_ms: Int) -> Result(String, Nil)
