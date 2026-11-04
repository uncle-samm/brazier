//// A replica refuses a malformed delta or full state from a cluster member:
//// it logs an error, reports the merge in its `[brazier, store, sync]` span
//// with 0 entries, `result` malformed and the failing field as `reason`,
//// keeps its state, and keeps running. Before, the CRDT
//// functions read the payload unchecked, so a malformed term crashed the
//// replica (or was joined, breaking convergence).
////
//// The payloads are injected into b's replica as if a (a verified member)
//// had sent them; which fields are checked is covered field by field in
//// store_replica_payload_test.

import brazier/cluster/log_capture
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/cluster/relay.{type Events}
import brazier/pubsub
import brazier/store
import brazier/store/replicated.{Config}
import brazier/telemetry
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/string

const wait_ms = 10_000

const name = "rsv"

pub fn malformed_peer_payloads_are_refused_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_rs_valid")
  let assert [a, b] = peers as "the cluster starts two peers"
  let config = Config(..replicated.default_config(), sync_interval_ms: 100)
  let stores =
    list.map(peers, fn(p) {
      peer.on(p, fn() {
        pubsub.start()
        let assert Ok(kv) = store.open(name, store.Replicated(config))
          as "store.open succeeds"
        kv
      })
    })
  let assert [kv, ..] = stores as "every peer opened the store"
  peer.on(a, fn() { store.put(kv, "before", "1") })
  assert peer.eventually(
    fn() { peer.on(b, fn() { store.get(kv, "before") }) == Ok("1") },
    wait_ms,
  )
  let assert Ok(pid) = peer.on(b, fn() { replica_pid(name) })
    as "b's replica runs"
  let syncs = relay.events(b, [["brazier", "store", "sync", "stop"]])

  let from = peer.node(a)
  let cases = malformed_payloads()
  let #(Nil, lines) =
    peer.on(b, fn() {
      log_capture.capture(fn() {
        list.each(cases, fn(entry) {
          let #(_label, what, payload, _fragment) = entry
          inject(name, from, what, payload)
        })
      })
    })

  // Every payload was refused with its reason, and nothing crashed.
  list.each(cases, fn(entry) {
    let #(_label, _what, _payload, fragment) = entry
    assert log_capture.contains(lines, "error", fragment)
  })
  assert log_capture.contains(lines, "error", "refused a malformed delta")
  assert log_capture.contains(lines, "error", "refused a malformed sync")
  assert peer.on(b, fn() { replica_pid(name) }) == Ok(pid)
  assert peer.on(b, fn() { store.get(kv, "before") }) == Ok("1")
  assert peer.on(b, fn() { store.count(kv) }) == 1

  // Each refusal ran in a sync span from a, in injection order, with no
  // entries counted, result malformed and the failing field as its reason.
  let from_a = atom.to_string(node.name(from))
  list.each(cases, fn(entry) {
    let #(label, _what, _payload, fragment) = entry
    let assert Ok(event) = next_refusal(b, syncs)
      as "every malformed payload is reported by its sync span"
    assert telemetry.string(event, "store") == Ok(name)
    assert telemetry.string(event, "peer") == Ok(from_a)
    assert telemetry.int(event, "entries") == Ok(0)
    let assert Ok(reason) = telemetry.string(event, "reason")
      as "a refused sync names its reason"
    case string.contains(reason, fragment) {
      True -> Nil
      False ->
        panic as {
          label
          <> ": the sync span's reason "
          <> string.inspect(reason)
          <> " does not name "
          <> string.inspect(fragment)
        }
    }
  })

  // Replication still works.
  peer.on(a, fn() { store.put(kv, "after", "2") })
  assert peer.eventually(
    fn() { peer.on(b, fn() { store.get(kv, "after") }) == Ok("2") },
    wait_ms,
  )
}

/// The next sync span on `p` whose result is malformed. Anti-entropy may
/// report accepted merges between the injected ones; only an injection is
/// malformed, and the replica handles them in the order they were sent.
fn next_refusal(p: Peer, syncs: Events) -> Result(telemetry.Event, Nil) {
  case relay.next_event(p, syncs, wait_ms) {
    Error(Nil) -> Error(Nil)
    Ok(event) ->
      case telemetry.string(event, "result") {
        Ok("malformed") -> Ok(event)
        Ok("ok") -> next_refusal(p, syncs)
        other ->
          panic as {
            "an unexpected sync result during injection: "
            <> string.inspect(other)
          }
      }
  }
}

@external(erlang, "brazier_store_replica_test_ffi", "malformed_payloads")
fn malformed_payloads() -> List(#(String, Dynamic, Dynamic, String))

@external(erlang, "brazier_store_replica_test_ffi", "inject")
fn inject(name: String, from: Node, what: Dynamic, payload: Dynamic) -> Nil

@external(erlang, "brazier_store_test_ffi", "replica_pid")
fn replica_pid(name: String) -> Result(Pid, Nil)
