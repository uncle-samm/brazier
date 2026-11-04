//// A replica refuses a malformed delta or full state from a cluster member:
//// it logs an error, reports the merge in its `[brazier, store, sync]` span
//// with 0 entries, keeps its state, and keeps running. Before, the CRDT
//// functions read the payload unchecked, so a malformed term crashed the
//// replica (or was joined, breaking convergence).
////
//// The payloads are injected into b's replica as if a (a verified member)
//// had sent them; which fields are checked is covered field by field in
//// store_replica_payload_test.

import brazier/cluster/log_capture
import brazier/cluster/peer.{Timeout}
import brazier/pubsub
import brazier/store
import brazier/store/replicated.{Config}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/list

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
  peer.on(b, record_syncs)

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

  // Each refusal ran in a sync span from a, with no entries counted.
  let from_a = atom.to_string(node.name(from))
  let refused =
    list.filter(peer.on(b, recorded_syncs), fn(sync) {
      sync.0 == name && sync.1 == from_a && sync.2 == 0
    })
  assert list.length(refused) >= list.length(cases)

  // Replication still works.
  peer.on(a, fn() { store.put(kv, "after", "2") })
  assert peer.eventually(
    fn() { peer.on(b, fn() { store.get(kv, "after") }) == Ok("2") },
    wait_ms,
  )
}

@external(erlang, "brazier_store_replica_test_ffi", "malformed_payloads")
fn malformed_payloads() -> List(#(String, Dynamic, Dynamic, String))

@external(erlang, "brazier_store_replica_test_ffi", "inject")
fn inject(name: String, from: Node, what: Dynamic, payload: Dynamic) -> Nil

@external(erlang, "brazier_store_test_ffi", "replica_pid")
fn replica_pid(name: String) -> Result(Pid, Nil)

@external(erlang, "brazier_store_test_ffi", "record_syncs")
fn record_syncs() -> Nil

@external(erlang, "brazier_store_test_ffi", "recorded_syncs")
fn recorded_syncs() -> List(#(String, String, Int, Int, Int))
