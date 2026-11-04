//// The sorted fingerprint the replica digest was computed from before it
//// became incremental (brazier/store/crdt.digest), kept verbatim as the
//// oracle the digest is checked against: two states have equal
//// fingerprints exactly when they hold the same live `(key, dot)`s, clock
//// and cloud.

import brazier/store/crdt.{type Dot, type Replica, type State}
import gleam/dict
import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/set
import gleam/string

/// A canonical description of the state (every live `(key, dot)` and the
/// context, sorted) that is equal on two replicas exactly when their states
/// are equal. Values are left out: a dot names one value forever.
pub fn fingerprint(
  state: State(value),
) -> #(List(#(String, Dot)), List(#(Replica, Int)), List(Dot)) {
  let live =
    dict.fold(state.entries, [], fn(acc, key, dots) {
      list.fold(dict.keys(dots), acc, fn(acc, dot) { [#(key, dot), ..acc] })
    })
    |> list.sort(fn(a, b) {
      case string.compare(a.0, b.0) {
        order.Eq -> crdt.compare_dots(a.1, b.1)
        other -> other
      }
    })
  let clock =
    dict.to_list(state.context.clock)
    |> list.sort(fn(a, b) { compare_replicas(a.0, b.0) })
  let cloud = list.sort(set.to_list(state.context.cloud), crdt.compare_dots)
  #(live, clock, cloud)
}

fn compare_replicas(a: Replica, b: Replica) -> Order {
  case string.compare(a.node, b.node) {
    order.Eq -> int.compare(a.incarnation, b.incarnation)
    other -> other
  }
}
