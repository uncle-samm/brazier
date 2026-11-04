//// Tests for the helpers in brazier_cluster_test_ffi and
//// brazier_store_test_ffi that cluster tests run on a peer. Each wait must
//// be woken by a change made after it started waiting and leave nothing in
//// the waiting process's mailbox however it ends; each recorder whose
//// handler lives as long as its node must refuse the shared test runner.

import brazier/cluster/peer.{Timeout}
import brazier/pubsub
import brazier/telemetry
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list

const wait_ms = 10_000

/// A wait on the event recorder wakes on an event recorded after the
/// wait's first check: the check emits it and still answers with what it
/// saw before, so only the recorder's notice can end the wait.
pub fn recorder_wakes_its_watchers_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_harness_recorder")
  let assert [a] = peers as "the cluster starts one peer"
  let name = ["brazier_harness_test", "recorded"]
  peer.on(a, fn() { record_events([name]) })

  let woken =
    peer.until(
      a,
      recorder_changes(),
      fn() {
        let seen = seen_before()
        let assert Ok(Nil) = telemetry.execute(name, dict.new(), dict.new())
          as "telemetry.execute succeeds"
        seen
      },
      wait_ms,
    )
  assert woken
  assert peer.on(a, recorded_count) == 2
}

/// `record_events` attaches a handler that lives as long as its node, so
/// on the test runner, which every test module shares, it refuses instead.
pub fn record_events_refuses_the_test_runner_test() {
  let outcome = rescue(fn() { record_events([["brazier_harness_test", "x"]]) })
  assert outcome == Error("error")
  assert registered("brazier_test_event_recorder") == Error(Nil)
}

/// `record_syncs` refuses the test runner for the same reason.
pub fn record_syncs_refuses_the_test_runner_test() {
  assert rescue(record_syncs) == Error("error")
}

/// `await_recorded` answers with every delivery up to its count, whichever
/// process broadcast them and whenever: deliveries from another process
/// that are still on their way when it asks, and a delivery broadcast
/// after it asked. A request that times out leaves no late answer behind.
pub fn await_recorded_sees_every_delivery_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_harness_await")
  let assert [a] = peers as "the cluster starts one peer"
  peer.on(a, pubsub.start)
  let topic = "harness:recorded"
  let assert [recorder] = peer.on(a, fn() { spawn_recorders(topic, 1) })
    as "one recorder starts"

  let #(sent_before, timed_out, held, left) =
    peer.on_within(a, wait_ms * 3, fn() {
      // Broadcast from another process, which has finished sending when
      // this one asks: its deliveries and the request come from two
      // senders, so the recorder may get them in either order.
      let sent = process.new_subject()
      process.spawn(fn() {
        broadcast(topic, "one")
        broadcast(topic, "two")
        process.send(sent, Nil)
      })
      let assert Ok(Nil) = process.receive(sent, wait_ms)
        as "the broadcaster finishes"
      let sent_before = await_recorded(recorder, 2, wait_ms)

      let timed_out = await_recorded(recorder, 3, 50)

      // A request held by the recorder until a later broadcast.
      let answer = process.new_subject()
      process.spawn(fn() {
        process.send(answer, await_recorded(recorder, 3, wait_ms))
      })
      broadcast(topic, "three")
      let assert Ok(held) = process.receive(answer, wait_ms + 5000)
        as "the held request is answered"
      #(sent_before, timed_out, held, mailbox_len())
    })
  assert sent_before == Ok(["one", "two"])
  assert timed_out == Error(["one", "two"])
  assert held == Ok(["one", "two", "three"])
  assert left == 0
}

/// `await_round` sees every round, whether the round completes before the
/// waiter registers or after: each round's waiter starts in a process of
/// its own while the round is broadcast, so both orders occur. A wait that
/// times out leaves nothing behind.
pub fn await_round_sees_every_round_test_() -> peer.Timeout {
  use <- Timeout(120)
  use peers <- peer.with_cluster(1, "brazier_harness_round")
  let assert [a] = peers as "the cluster starts one peer"
  peer.on(a, pubsub.start)
  let topic = "harness:rounds"
  let rounds = 200
  assert peer.on(a, fn() { spawn_counters(topic, 2) }) == 2

  let missed =
    peer.on_within(a, wait_ms * 3, fn() {
      int.range(from: 1, to: rounds + 1, with: [], run: fn(missed, round) {
        let done = process.new_subject()
        process.spawn(fn() { process.send(done, await_round(round, wait_ms)) })
        broadcast(topic, int.to_string(round))
        let assert Ok(outcome) = process.receive(done, wait_ms + 5000)
          as "the waiter answers"
        case outcome {
          Ok(_) -> missed
          Error(Nil) -> [round, ..missed]
        }
      })
    })
  assert missed == []

  let #(timed_out, later, left) =
    peer.on_within(a, wait_ms * 2, fn() {
      let next = rounds + 1
      let timed_out = await_round(next, 50)
      broadcast(topic, "late")
      let later = await_round(next, wait_ms)
      #(timed_out, later, mailbox_len())
    })
  assert timed_out == Error(Nil)
  let assert Ok(_) = later as "the late round completes"
  assert left == 0
}

fn broadcast(topic: String, message: String) -> Nil {
  let assert Ok(Nil) = pubsub.local_broadcast(topic, message)
    as "pubsub is running on the peer"
  Nil
}

/// Wake on each event the peer's recorder records.
fn recorder_changes() -> peer.Wake {
  fn() {
    let watch = watch_recorded()
    fn() { unwatch_recorded(watch) }
  }
}

fn recorded_count() -> Int {
  list.length(recorded_events())
}

/// Whether this rpc process has called it before (its process dictionary
/// lives as long as the one rpc).
fn seen_before() -> Bool {
  put(atom.create("brazier_harness_test_seen"), True) == dynamic.bool(True)
}

@external(erlang, "erlang", "put")
fn put(key: Atom, value: Bool) -> Dynamic

@external(erlang, "brazier_pubsub_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, String)

@external(erlang, "brazier_cluster_test_ffi", "record_events")
fn record_events(names: List(List(String))) -> Nil

@external(erlang, "brazier_store_test_ffi", "record_syncs")
fn record_syncs() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "recorded_events")
fn recorded_events() -> List(Dynamic)

/// A subscription to the recorder's notices (watch_recorded/0).
type RecorderWatch

@external(erlang, "brazier_cluster_test_ffi", "watch_recorded")
fn watch_recorded() -> RecorderWatch

@external(erlang, "brazier_cluster_test_ffi", "unwatch_recorded")
fn unwatch_recorded(watch: RecorderWatch) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "registered")
fn registered(name: String) -> Result(Pid, Nil)

@external(erlang, "brazier_cluster_test_ffi", "spawn_recorders")
fn spawn_recorders(topic: String, count: Int) -> List(Pid)

@external(erlang, "brazier_cluster_test_ffi", "await_recorded")
fn await_recorded(
  pid: Pid,
  count: Int,
  timeout_ms: Int,
) -> Result(List(String), List(String))

@external(erlang, "brazier_cluster_test_ffi", "spawn_counters")
fn spawn_counters(topic: String, count: Int) -> Int

@external(erlang, "brazier_cluster_test_ffi", "await_round")
fn await_round(round: Int, timeout_ms: Int) -> Result(Int, Nil)

@external(erlang, "brazier_cluster_test_ffi", "mailbox_len")
fn mailbox_len() -> Int
