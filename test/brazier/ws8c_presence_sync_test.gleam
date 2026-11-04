//// The shard's sync waiters (brazier_presence_shard, "Sync waiters"),
//// driven on one node by fake peers (see brazier_presence_test_ffi): a
//// process asks when the shard has caught up with some nodes and gets one
//// answer per node, after the diffs of what the shard learnt before.

import brazier/cluster/log_capture
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
  p
}

fn shard(p: Presence(String)) -> Pid {
  let assert Ok(shard) = presence.shard_pid(p, "room")
  shard
}

/// Deliver `message` as a peer would, and wait until the shard handled it
/// (the replicas call is answered after it).
fn send_peer(p: Presence(String), message: Dynamic) -> Nil {
  let topic = "brazier_presence:" <> presence.name(p) <> ":1"
  send_peer_ffi(shard(p), topic, message)
  let assert Ok(_) = presence.replicas(p, "room")
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
  let p = start(5000)
  let _ = flush_diffs()
  let assert Ok(Nil) = presence.subscribe(p, "room")
  let ghost = fake_ref("ghost@host", 1)
  send_peer(p, heartbeat_at(ghost, 1, 1))
  await_sync(shard(p), ["ghost@host"])
  let assert Ok(_) = presence.replicas(p, "room")
  // A call answered after the request: nothing was sent yet.
  let assert Error(Nil) = receive_synced(shard(p), 0)

  send_peer(p, transfer_ack(ghost, 1, "room", [#("remote", "\"hi\"")]))
  let assert Ok("diff") = receive_any(wait_ms)
  let assert Ok(#("ghost@host", "synced")) = answer(shard(p))
  let assert Ok(Nil) = presence.unsubscribe(p, "room")
  let assert Ok(Nil) = presence.stop(p)
}

/// A node the shard knows and holds everything of is answered at once.
pub fn synced_at_once_when_already_caught_up_test() {
  let p = start(5000)
  let ghost = fake_ref("ghost@host", 1)
  send_peer(p, transfer_ack(ghost, 1, "room", [#("remote", "\"hi\"")]))
  send_peer(p, heartbeat_at(ghost, 1, 1))
  await_sync(shard(p), ["ghost@host"])
  let assert Ok(_) = presence.replicas(p, "room")
  let assert Ok(#("ghost@host", "synced")) = receive_synced(shard(p), 0)
  let assert Ok(Nil) = presence.stop(p)
}

/// A node never heard from is absent once down_period has passed since the
/// shard started (the rule that would mark it down had it been known).
pub fn absent_for_a_node_never_heard_from_test() {
  let p = start(100)
  await_sync(shard(p), ["nobody@host"])
  let assert Ok(#("nobody@host", "absent")) = answer(shard(p))
  let assert Ok(Nil) = presence.stop(p)
}

/// A node whose replica is down is answered at once: its entries are
/// hidden, so a watcher holding them reports them gone.
pub fn down_for_a_node_that_is_down_test() {
  let p = start(100)
  let ghost = fake_ref("ghost@host", 1)
  send_peer(p, transfer_ack(ghost, 1, "room", [#("remote", "\"hi\"")]))
  let assert True =
    eventually(
      fn() { presence.replicas(p, "room") == Ok([#("ghost@host", Down)]) },
      wait_ms,
    )
  await_sync(shard(p), ["ghost@host"])
  let assert Ok(#("ghost@host", "down")) = answer(shard(p))
  let assert Ok(Nil) = presence.stop(p)
}

/// The ghost keeps heartbeating a clock the shard never catches up with
/// (it answers no transfer request): the waiter is told `timeout` after
/// down_period, and the shard logs it.
pub fn timeout_when_the_node_never_catches_up_test() {
  let p = start(300)
  let ghost = fake_ref("ghost@host", 1)
  send_peer(p, heartbeat_at(ghost, 1, 5))
  let #(answered, lines) =
    log_capture.capture(fn() {
      await_sync(shard(p), ["ghost@host"])
      keep_alive_until_answered(p, ghost, 60)
    })
  let assert Ok(#("ghost@host", "timeout")) = answered
  let assert True =
    log_capture.contains(lines, "warning", "did not sync with ghost@host")
  let assert Ok(Nil) = presence.stop(p)
}

/// Heartbeat every 50ms (the receive's timeout paces it) until the shard
/// answers, at most `rounds` times.
fn keep_alive_until_answered(
  p: Presence(String),
  ghost: Ref,
  rounds: Int,
) -> Result(#(String, String), Nil) {
  case receive_synced(shard(p), 50) {
    Ok(answered) -> Ok(answered)
    Error(Nil) if rounds <= 0 -> Error(Nil)
    Error(Nil) -> {
      send_peer(p, heartbeat_at(ghost, 1, 5))
      keep_alive_until_answered(p, ghost, rounds - 1)
    }
  }
}

/// Several nodes in one request get one answer each; duplicates are one.
pub fn one_answer_per_distinct_node_test() {
  let p = start(100)
  await_sync(shard(p), ["b@host", "a@host", "b@host"])
  let assert Ok(first) = answer(shard(p))
  let assert Ok(second) = answer(shard(p))
  let assert True =
    [first, second] == [#("a@host", "absent"), #("b@host", "absent")]
    || [first, second] == [#("b@host", "absent"), #("a@host", "absent")]
  let assert Ok(_) = presence.replicas(p, "room")
  let assert Error(Nil) = receive_synced(shard(p), 0)
  let assert Ok(Nil) = presence.stop(p)
}

/// Requests with nodes that are not binaries, or without a list, are
/// logged and ignored; the shard keeps running and answers the next one.
pub fn malformed_requests_are_logged_and_ignored_test() {
  let p = start(100)
  let before = shard(p)
  let tag = atom.create("brazier_presence_await_sync")
  let #(_, lines) =
    log_capture.capture(fn() {
      send_raw(before, #(tag, process.self(), [atom.create("a@host")]))
      send_raw(before, #(tag, process.self(), "a@host"))
      let assert Ok(_) = presence.replicas(p, "room")
      Nil
    })
  let assert True = log_capture.contains(lines, "warning", "non-binary nodes")
  let assert True = log_capture.contains(lines, "warning", "unexpected message")
  let assert Error(Nil) = receive_synced(before, 0)
  await_sync(before, ["a@host"])
  let assert Ok(#("a@host", "absent")) = answer(before)
  let assert True = shard(p) == before
  let assert Ok(Nil) = presence.stop(p)
}

/// Poll `check` every 5ms until it holds or `timeout_ms` passes.
fn eventually(check: fn() -> Bool, timeout_ms: Int) -> Bool {
  case check() {
    True -> True
    False if timeout_ms <= 0 -> False
    False -> {
      pause(5)
      eventually(check, timeout_ms - 5)
    }
  }
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

@external(erlang, "brazier_presence_test_ffi", "flush_diffs")
fn flush_diffs() -> Int

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

@external(erlang, "brazier_pubsub_test_ffi", "pause")
fn pause(ms: Int) -> Nil
