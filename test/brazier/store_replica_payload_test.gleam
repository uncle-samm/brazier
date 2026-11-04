//// A replica checks every field of a peer's delta or full state before it
//// reads or joins it (brazier_store_replica:check_payload/2). Every
//// payload brazier/store/crdt builds passes, and each malformed variant in
//// brazier_store_replica_test_ffi fails with a reason naming its field.
//// The replica-level behaviour (refused, logged, telemetry, state kept) is
//// in cluster/store_replica_validation_test.

import brazier/store/crdt.{Replica}
import brazier/store/hlc.{Timestamp}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string

/// The `What` atom of check_payload/2.
type What {
  Delta
  Sync
}

const ra = Replica(node: "a@host", incarnation: 1)

const rb = Replica(node: "b@host", incarnation: 7)

fn ts(wall: Int, node: String) -> hlc.Timestamp {
  Timestamp(wall_ms: wall, logical: 0, node: node)
}

pub fn every_delta_the_crdt_builds_is_accepted_test() {
  let #(s1, put, _) = crdt.put(crdt.new(), ra, "k", "v", ts(10, ra.node), [])
  assert check_payload(Delta, put) == Ok(Nil)
  let #(s2, append, _) =
    crdt.append(
      s1,
      ra,
      "list",
      [#("one", ts(11, ra.node)), #("two", ts(12, ra.node))],
      ["room:1"],
    )
  assert check_payload(Delta, append) == Ok(Nil)
  // A removal names its key with no dots and carries delta topics.
  let #(_s3, remove, _) = crdt.remove(s2, "k", ["room:k"])
  assert check_payload(Delta, remove) == Ok(Nil)
}

/// A full state with concurrent values, two replicas in the clock and a
/// dot in the cloud (seen past a gap), which exercises the gleam/set
/// representation the check relies on.
pub fn a_full_state_is_accepted_test() {
  let #(b1, _first, _) = crdt.put(crdt.new(), rb, "x", 1, ts(10, rb.node), [])
  let #(_b2, second, _) = crdt.put(b1, rb, "y", 2, ts(11, rb.node), [])
  let #(a1, _, _) = crdt.put(crdt.new(), ra, "x", 3, ts(10, ra.node), [])
  // a sees b's second write without its first: b's dot 2 is in the cloud.
  let #(a2, _) = crdt.join(a1, second)
  let full = crdt.to_delta(a2)
  assert full.context.cloud != crdt.new().context.cloud
  assert check_payload(Sync, full) == Ok(Nil)
  assert check_payload(Delta, full) == Ok(Nil)
  // The empty state is a valid full state too.
  assert check_payload(Sync, crdt.to_delta(crdt.new())) == Ok(Nil)
}

pub fn every_malformed_payload_is_refused_with_its_field_named_test() {
  let cases = malformed_payloads()
  assert list.length(cases) >= 25
  list.each(cases, fn(entry) {
    let #(label, what, payload, fragment) = entry
    case check_payload(what, payload) {
      Error(reason) ->
        case string.contains(reason, fragment) {
          True -> Nil
          False ->
            panic as {
              label
              <> ": reason "
              <> string.inspect(reason)
              <> " does not name "
              <> string.inspect(fragment)
            }
        }
      Ok(Nil) -> panic as { label <> ": a malformed payload was accepted" }
    }
  })
}

/// How a replica admits a payload before joining it
/// (brazier_store_replica:admit/4): the result and reason it puts on the
/// `[brazier, store, sync]` stop event, and the entries it reports.
type Admission {
  Admitted(entries: Int)
  Refused(entries: Int, result: String, reason: String)
}

pub fn a_malformed_payload_is_refused_with_its_field_as_reason_test() {
  list.each(malformed_payloads(), fn(entry) {
    let #(label, what, payload, fragment) = entry
    let bytes = 100
    case admit(what, payload, bytes, 1_000_000) {
      Refused(entries: 0, result: "malformed", reason:) ->
        case string.contains(reason, fragment) {
          True -> Nil
          False ->
            panic as {
              label
              <> ": reason "
              <> string.inspect(reason)
              <> " does not name "
              <> string.inspect(fragment)
            }
        }
      other -> panic as { label <> ": admitted as " <> string.inspect(other) }
    }
  })
}

pub fn a_payload_over_its_byte_limit_is_refused_as_too_large_test() {
  let #(s1, put, _) = crdt.put(crdt.new(), ra, "k", "v", ts(10, ra.node), [])
  let #(_s2, second, _) = crdt.put(s1, ra, "j", "w", ts(11, ra.node), [])
  // The limit is inclusive: a payload of exactly the limit is admitted.
  assert admit(Delta, put, 500, 500) == Admitted(entries: 1)
  assert admit(Delta, put, 501, 500)
    == Refused(entries: 1, result: "too_large", reason: "max_delta_bytes")
  let full = crdt.to_delta(crdt.join(s1, second).0)
  assert admit(Sync, full, 4000, 4000) == Admitted(entries: 2)
  assert admit(Sync, full, 4001, 4000)
    == Refused(entries: 2, result: "too_large", reason: "max_sync_bytes")
}

/// A malformed payload is refused as malformed even when it is also too
/// large: its entries cannot be counted, and its field is the reason.
pub fn a_malformed_payload_over_its_limit_is_refused_as_malformed_test() {
  let payload = dynamic.string("nope")
  let assert Error(reason) = check_payload(Delta, payload)
    as "a string is not a delta"
  assert admit(Delta, payload, 10_000, 10)
    == Refused(entries: 0, result: "malformed", reason:)
    as "malformed is checked before size"
}

@external(erlang, "brazier_store_replica", "admit")
fn admit(what: What, payload: payload, bytes: Int, max_bytes: Int) -> Admission

@external(erlang, "brazier_store_replica", "check_payload")
fn check_payload(what: What, payload: payload) -> Result(Nil, String)

@external(erlang, "brazier_store_replica_test_ffi", "malformed_payloads")
fn malformed_payloads() -> List(#(String, What, Dynamic, String))
