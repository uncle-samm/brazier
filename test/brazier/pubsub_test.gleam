//// Single-node PubSub tests. Multi-node behaviour (forwarding, netsplits,
//// partition kills, overload, a stopped registry) is covered with real
//// peer nodes in test/brazier/cluster/pubsub_cluster_test.gleam.

import brazier/await
import brazier/cluster/log_capture
import brazier/monitored
import brazier/pubsub.{
  InvalidConfig, InvalidTopic, NodeNotConnected, TooManySubscriptions,
}
import brazier/telemetry
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/string

// --- Helpers ----------------------------------------------------------------

type Delivery {
  Delivery(subscriber: Pid, topic: String, message: Dynamic)
}

fn unique(label: String) -> String {
  label <> "_" <> int.to_string(unique_integer())
}

/// A subscriber process: subscribes to `topics`, reports its pid on
/// `ready`, then forwards every delivery to `out` until killed. Unlinked so
/// tests can kill it.
fn spawn_subscriber(
  topics: List(String),
  ready: Subject(Pid),
  out: Subject(Delivery),
) -> Pid {
  process.spawn_unlinked(fn() {
    list.each(topics, fn(topic) {
      // INVARIANT: the test topics are valid and PubSub is running.
      let assert Ok(Nil) = pubsub.try_subscribe(topic)
    })
    process.send(ready, process.self())
    forward_loop(out)
  })
}

fn forward_loop(out: Subject(Delivery)) -> Nil {
  case receive_pubsub(60_000) {
    Ok(#(topic, message)) -> {
      process.send(out, Delivery(process.self(), topic, message))
      forward_loop(out)
    }
    Error(Nil) -> Nil
  }
}

fn await_ready(ready: Subject(Pid)) -> Pid {
  let assert Ok(pid) = process.receive(ready, 1000)
    as "a subscriber did not subscribe within 1 s"
  pid
}

/// Start one subscriber per entry of `topics`, wait until all have
/// subscribed, and run `body` with their pids. The subscribers are
/// unlinked, so they are killed after `body` even when it fails: otherwise
/// a failed test leaves them subscribed for 60 s, forwarding to a subject
/// of eunit's shared test process.
fn with_subscribers(
  topics: List(List(String)),
  out: Subject(Delivery),
  body: fn(List(Pid)) -> a,
) -> a {
  let ready = process.new_subject()
  let pids = list.map(topics, fn(each) { spawn_subscriber(each, ready, out) })
  use <- monitored.with_cleanup(fn() { list.each(pids, process.kill) })
  list.each(pids, fn(_) { await_ready(ready) })
  body(pids)
}

fn string_message(delivery: Delivery) -> String {
  let assert Ok(text) = decode.run(delivery.message, decode.string)
  text
}

// --- Lifecycle and configuration -------------------------------------------

pub fn start_is_idempotent_test() {
  pubsub.start()
  pubsub.start()
  let assert Ok(config) = pubsub.running_config()
  let assert Ok(_) = pubsub.validate_config(config)
  let assert 0 = pubsub.subscriber_count(unique("nobody"))
}

pub fn start_with_running_config_is_ok_test() {
  pubsub.start()
  let assert Ok(config) = pubsub.running_config()
  let assert Ok(Nil) = pubsub.start_with(config)
}

pub fn start_with_different_config_is_refused_test() {
  pubsub.start()
  let assert Ok(config) = pubsub.running_config()
  let different = pubsub.max_forward_queue(config, config.max_forward_queue + 1)
  let assert Error(InvalidConfig(reason)) = pubsub.start_with(different)
  let assert True = string.contains(reason, "different configuration")
}

pub fn invalid_configs_are_rejected_test() {
  let base = pubsub.default_config()
  let assert Error(InvalidConfig(_)) =
    pubsub.validate_config(pubsub.partitions(base, 0))
  let assert Error(InvalidConfig(_)) =
    pubsub.validate_config(pubsub.partitions(base, pubsub.max_partitions + 1))
  let assert Error(InvalidConfig(_)) =
    pubsub.validate_config(pubsub.pool_size(base, 0))
  let assert Error(InvalidConfig(_)) =
    pubsub.validate_config(pubsub.pool_size(base, pubsub.max_pool_size + 1))
  let assert Error(InvalidConfig(_)) =
    pubsub.validate_config(pubsub.max_forward_queue(base, 0))
  let assert Error(InvalidConfig(_)) =
    pubsub.validate_config(pubsub.max_topics_per_subscriber(base, 0))
  let assert Error(InvalidConfig(_)) =
    pubsub.validate_config(pubsub.max_topics_per_subscriber(
      base,
      pubsub.max_topics_limit + 1,
    ))
  let assert Error(InvalidConfig(_)) =
    pubsub.start_with(pubsub.pool_size(base, -1))
  let assert Error(InvalidConfig(_)) =
    pubsub.supervised(pubsub.partitions(base, 0))
  let assert Ok(_) = pubsub.validate_config(base)
}

// --- Delivery ----------------------------------------------------------------

pub fn broadcast_delivers_to_every_subscriber_once_test() {
  pubsub.start()
  let topic = unique("fanout")
  let out = process.new_subject()
  use subscribers <- with_subscribers([[topic], [topic], [topic]], out)
  let assert 3 = pubsub.subscriber_count(topic)

  pubsub.broadcast(topic, "hello")
  pubsub.broadcast(topic, "end")
  let deliveries = collect(out, 6, [])
  // Each subscriber sees hello then end, and nothing in between: a
  // duplicate hello would arrive before its end.
  list.each(subscribers, fn(pid) {
    let assert ["hello", "end"] =
      deliveries
      |> list.filter(fn(d) { d.subscriber == pid })
      |> list.map(string_message)
  })
  let assert True = list.all(deliveries, fn(d) { d.topic == topic })
}

fn collect(
  out: Subject(Delivery),
  remaining: Int,
  acc: List(Delivery),
) -> List(Delivery) {
  case remaining {
    0 -> list.reverse(acc)
    _ -> {
      let assert Ok(delivery) = process.receive(out, 1000)
      collect(out, remaining - 1, [delivery, ..acc])
    }
  }
}

pub fn subscribing_twice_is_one_subscription_test() {
  pubsub.start()
  let topic = unique("twice")
  let out = process.new_subject()
  use pids <- with_subscribers([[topic, topic]], out)
  let assert [pid] = pids
  let assert 1 = pubsub.subscriber_count(topic)
  let assert Ok([subscriber]) = pubsub.local_subscribers(topic)
  let assert True = subscriber == pid

  let assert Ok(Nil) = pubsub.try_broadcast(topic, "once")
  let assert Ok(Nil) = pubsub.try_broadcast(topic, "end")
  let assert ["once", "end"] = list.map(collect(out, 2, []), string_message)
}

// The tests that subscribe the test process itself run isolated: a failed
// assertion would otherwise leave eunit's shared test process subscribed
// and linked to a partition for the rest of the module.

pub fn unsubscribe_stops_delivery_and_unlinks_test() {
  use <- monitored.isolated
  pubsub.start()
  let topic = unique("unsub")
  let assert Ok(Nil) = pubsub.try_subscribe(topic)
  let assert Ok(partition) = pubsub.partition_for(process.self())
  let assert True = linked(process.self(), partition)

  let assert Ok(Nil) = pubsub.try_unsubscribe(topic)
  let assert 0 = pubsub.subscriber_count(topic)
  // The last subscription in a partition removes the link (as
  // Registry.unregister does), so the test process no longer depends on it.
  let assert False = linked(process.self(), partition)
  let assert Ok(Nil) = pubsub.try_broadcast(topic, "unseen")
  let assert Error(Nil) = receive_pubsub(0)
  // Unsubscribing from a topic the process is not subscribed to is Ok.
  let assert Ok(Nil) = pubsub.try_unsubscribe(topic)
}

pub fn unsubscribe_keeps_link_while_other_topics_remain_test() {
  use <- monitored.isolated
  pubsub.start()
  let first = unique("keep_a")
  let second = unique("keep_b")
  let assert Ok(Nil) = pubsub.try_subscribe(first)
  let assert Ok(Nil) = pubsub.try_subscribe(second)
  let assert Ok(partition) = pubsub.partition_for(process.self())
  let assert Ok(Nil) = pubsub.try_unsubscribe(first)
  let assert True = linked(process.self(), partition)
  let assert Ok(Nil) = pubsub.local_broadcast(second, "still")
  let assert Ok(#(topic, _)) = receive_pubsub(1000)
  let assert True = topic == second
  let assert Ok(Nil) = pubsub.try_unsubscribe(second)
  let assert False = linked(process.self(), partition)
}

pub fn subscriber_exit_removes_its_subscriptions_test() {
  pubsub.start()
  let topic_a = unique("exit_a")
  let topic_b = unique("exit_b")
  let out = process.new_subject()
  use pids <- with_subscribers([[topic_a, topic_b]], out)
  let assert [pid] = pids
  let assert 1 = pubsub.subscriber_count(topic_a)
  let assert 1 = pubsub.subscriber_count(topic_b)

  // The subscriber's partition traps its exit and removes its rows when it
  // handles the 'EXIT': wait for exactly that instead of polling the counts.
  let assert Ok(partition) = pubsub.partition_for(pid)
  use exit <- await.with_watch_exit(partition, pid)
  process.kill(pid)
  await.expect_info(exit, partition, "the partition handling the kill")
  let assert 0 = pubsub.subscriber_count(topic_a)
  let assert 0 = pubsub.subscriber_count(topic_b)
}

pub fn local_broadcast_delivers_on_this_node_test() {
  pubsub.start()
  let topic = unique("local")
  let out = process.new_subject()
  use _ <- with_subscribers([[topic]], out)
  let assert Ok(Nil) = pubsub.local_broadcast(topic, "here")
  let assert ["here"] = list.map(collect(out, 1, []), string_message)
}

pub fn direct_broadcast_to_this_node_delivers_locally_test() {
  pubsub.start()
  let topic = unique("direct_self")
  let out = process.new_subject()
  use _ <- with_subscribers([[topic]], out)
  let assert Ok(Nil) = pubsub.direct_broadcast(node.self(), topic, "me")
  let assert ["me"] = list.map(collect(out, 1, []), string_message)
}

pub fn direct_broadcast_to_unknown_node_is_an_error_test() {
  pubsub.start()
  let assert Error(NodeNotConnected("ghost@nowhere")) =
    pubsub.direct_broadcast(node_named("ghost@nowhere"), unique("direct"), 1)
}

// --- Limits ------------------------------------------------------------------

pub fn topic_length_is_validated_test() {
  use <- monitored.isolated
  pubsub.start()
  let too_long = string.repeat("x", 256)
  // Unique, so no other test or run shares the 255-byte topic.
  let prefix = unique("longest")
  let longest = prefix <> string.repeat("y", 255 - string.byte_size(prefix))
  let assert 255 = string.byte_size(longest)
  let assert Error(InvalidTopic("")) = pubsub.try_subscribe("")
  let assert Error(InvalidTopic(_)) = pubsub.try_subscribe(too_long)
  let assert Error(InvalidTopic(_)) = pubsub.try_unsubscribe(too_long)
  let assert Error(InvalidTopic(_)) = pubsub.try_broadcast(too_long, 1)
  let assert Error(InvalidTopic(_)) = pubsub.local_broadcast("", 1)
  let assert Error(InvalidTopic(_)) =
    pubsub.direct_broadcast(node.self(), too_long, 1)
  // 255 bytes is the limit, counted in bytes not characters.
  let assert Ok(Nil) = pubsub.try_subscribe(longest)
  let assert Ok(Nil) = pubsub.try_unsubscribe(longest)
  let assert Error(InvalidTopic(_)) =
    pubsub.try_subscribe(string.repeat("é", 128))
}

pub fn subscription_limit_is_enforced_test() {
  pubsub.start()
  let assert Ok(config) = pubsub.running_config()
  let limit = config.max_topics_per_subscriber
  let prefix = unique("limit")
  let result = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      subscribe_numbered(prefix, 1, limit)
      // An existing topic is not a new subscription, so it is still Ok.
      let again = pubsub.try_subscribe(prefix <> "_1")
      let over = pubsub.try_subscribe(prefix <> "_over")
      process.send(result, #(again, over))
    })
  let assert Ok(#(Ok(Nil), Error(TooManySubscriptions(reported)))) =
    process.receive(result, 5000)
  let assert True = reported == limit
}

fn subscribe_numbered(prefix: String, from: Int, to: Int) -> Nil {
  case from > to {
    True -> Nil
    False -> {
      let assert Ok(Nil) =
        pubsub.try_subscribe(prefix <> "_" <> int.to_string(from))
      subscribe_numbered(prefix, from + 1, to)
    }
  }
}

pub fn legacy_functions_crash_loudly_on_error_test() {
  pubsub.start()
  let #(outcome, lines) =
    log_capture.capture(fn() { rescue(fn() { pubsub.subscribe("") }) })
  let assert Error("error") = outcome
  let assert True =
    log_capture.contains(lines, "error", "subscribe on  failed: invalid topic")

  let #(outcome, lines) =
    log_capture.capture(fn() {
      rescue(fn() { pubsub.broadcast(string.repeat("z", 300), Nil) })
    })
  let assert Error("error") = outcome
  let assert True = log_capture.contains(lines, "error", "300 bytes")
}

// --- Telemetry ---------------------------------------------------------------

pub fn broadcasts_emit_telemetry_with_scope_test() {
  pubsub.start()
  let assert Ok(Nil) = telemetry.start()
  let topic = unique("telemetry")
  let id = unique("pubsub_handler")
  let events = process.new_subject()
  let me = process.self()
  let assert Ok(Nil) =
    telemetry.attach(id, [["brazier", "pubsub", "broadcast"]], fn(event) {
      // Handlers run in the emitting process: keep only this test's.
      case process.self() == me {
        True -> process.send(events, event)
        False -> Nil
      }
    })
  // Telemetry handlers are global: detach even when an assertion fails.
  use <- monitored.with_cleanup(fn() {
    let assert Ok(Nil) = telemetry.detach(id)
      as "detaching the test's telemetry handler"
    Nil
  })
  let out = process.new_subject()
  use _ <- with_subscribers([[topic]], out)

  let assert Ok(Nil) = pubsub.try_broadcast(topic, 1)
  let assert Ok(cluster) = process.receive(events, 0)
  let assert Ok("cluster") = telemetry.string(cluster, "scope")
  let assert Ok(1) = telemetry.int(cluster, "local_subscribers")
  let assert Ok(0) = telemetry.int(cluster, "remote_nodes")

  let assert Ok(Nil) = pubsub.local_broadcast(topic, 2)
  let assert Ok(local) = process.receive(events, 0)
  let assert Ok("local") = telemetry.string(local, "scope")

  // The subscriber forwards both broadcasts asynchronously: receive them,
  // so neither reaches the mailbox after the test ends.
  let assert [Ok(1), Ok(2)] =
    collect(out, 2, [])
    |> list.map(fn(d) { decode.run(d.message, decode.int) })
}

// --- FFI ---------------------------------------------------------------------

@external(erlang, "brazier_pubsub_test_ffi", "receive_pubsub")
fn receive_pubsub(timeout_ms: Int) -> Result(#(String, Dynamic), Nil)

@external(erlang, "brazier_pubsub_test_ffi", "node_named")
fn node_named(name: String) -> Node

@external(erlang, "brazier_pubsub_test_ffi", "linked")
fn linked(pid: Pid, other: Pid) -> Bool

@external(erlang, "brazier_pubsub_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, String)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
