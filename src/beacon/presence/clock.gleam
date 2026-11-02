//// Vector clocks for presence replication, ported from Phoenix.Tracker.Clock.
////
//// A clock maps each replica to the highest clock value seen from it.
//// A clockset is a list of
//// `#(replica, clock)` pairs that no member dominates: the set of peers
//// whose state this replica has not yet caught up with.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/set.{type Set}

pub type Clock(r) =
  Dict(r, Int)

/// Whether `c1` names every replica of `c2` with at least its value.
/// Phoenix: `dominates?/2`.
pub fn dominates(c1: Clock(r), c2: Clock(r)) -> Bool {
  case dict.size(c1) < dict.size(c2) {
    True -> False
    False ->
      dict.fold(c2, True, fn(acc, replica, clock) {
        acc
        && case dict.get(c1, replica) {
          Ok(value) -> value >= clock
          Error(Nil) -> False
        }
      })
  }
}

/// Whether every entry of `c1` is at least the matching entry of `c2`.
/// An empty `c1` only dominates-or-equals another empty clock.
/// Phoenix: `dominates_or_equal?/2`.
pub fn dominates_or_equal(c1: Clock(r), c2: Clock(r)) -> Bool {
  case dict.is_empty(c1) {
    True -> dict.is_empty(c2)
    False ->
      dict.fold(c1, True, fn(acc, replica, clock) {
        acc && clock >= get(c2, replica)
      })
  }
}

/// The entrywise maximum of two clocks.
pub fn upperbound(c1: Clock(r), c2: Clock(r)) -> Clock(r) {
  dict.combine(c1, c2, int.max)
}

/// The entrywise minimum of two clocks.
pub fn lowerbound(c1: Clock(r), c2: Clock(r)) -> Clock(r) {
  dict.combine(c1, c2, int.min)
}

/// The clock restricted to `replicas`.
pub fn filter_replicas(clock: Clock(r), replicas: List(r)) -> Clock(r) {
  dict.take(clock, replicas)
}

/// The replicas a clock mentions.
pub fn replicas(clock: Clock(r)) -> List(r) {
  dict.keys(clock)
}

/// Add a replica's clock to a clockset, keeping only clocks no other
/// member dominates. Phoenix: `append_clock/2`.
pub fn append_clock(
  clockset: List(#(n, Clock(r))),
  entry: #(n, Clock(r)),
) -> List(#(n, Clock(r))) {
  let #(_, clock) = entry
  case dict.is_empty(clock) {
    True -> clockset
    False -> {
      let big =
        list.fold(clockset, dict.new(), fn(acc, member) {
          upperbound(acc, member.1)
        })
      case dominates(clock, big), dominates(big, clock) {
        True, _ -> [entry]
        False, True -> clockset
        False, False -> filter_clocks(clockset, entry)
      }
    }
  }
}

fn filter_clocks(
  clockset: List(#(n, Clock(r))),
  entry: #(n, Clock(r)),
) -> List(#(n, Clock(r))) {
  let #(_, clock) = entry
  let #(kept, insert) =
    list.fold(clockset, #([], False), fn(acc, member) {
      let #(kept, insert) = acc
      let #(_, member_clock) = member
      case dominates(clock, member_clock) {
        True -> #(kept, True)
        False -> #([member, ..kept], insert || !dominates(member_clock, clock))
      }
    })
  case insert {
    True -> [entry, ..kept]
    False -> kept
  }
}

/// The replicas named in a clockset.
pub fn clockset_replicas(clockset: List(#(n, Clock(r)))) -> Set(n) {
  list.fold(clockset, set.new(), fn(acc, member) { set.insert(acc, member.0) })
}

fn get(clock: Clock(r), replica: r) -> Int {
  case dict.get(clock, replica) {
    Ok(value) -> value
    Error(Nil) -> 0
  }
}
