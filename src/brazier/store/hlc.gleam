//// Hybrid logical clock (Kulkarni, Demirbas et al., "Logical Physical
//// Clocks and Consistent Snapshots in Globally Distributed Databases",
//// 2014), used to order writes to a replicated store.
////
//// A timestamp is the wall clock in milliseconds, a logical counter that
//// orders events within the same millisecond (or while the wall clock lags
//// a timestamp already seen), and the writing node's name. Timestamps
//// compare by wall time, then logical counter, then node name, so every two
//// timestamps from different nodes are ordered the same way on every node.
////
//// The clock never goes backwards: `tick` (a local write) and `observe` (a
//// remote write merged here) both return a timestamp strictly greater than
//// every timestamp this node has produced or seen, even if the wall clock
//// stepped back.

import gleam/int
import gleam/order.{type Order}
import gleam/string

/// One hybrid logical clock reading.
pub type Timestamp {
  Timestamp(wall_ms: Int, logical: Int, node: String)
}

/// The clock of a node that has not produced or seen any timestamp yet.
pub fn zero(node: String) -> Timestamp {
  Timestamp(wall_ms: 0, logical: 0, node: node)
}

/// The timestamp of a local event (a write on this node). `last` is the
/// clock's current value, `now_ms` the wall clock.
pub fn tick(last: Timestamp, now_ms: Int) -> Timestamp {
  case now_ms > last.wall_ms {
    True -> Timestamp(wall_ms: now_ms, logical: 0, node: last.node)
    False ->
      Timestamp(
        wall_ms: last.wall_ms,
        logical: last.logical + 1,
        node: last.node,
      )
  }
}

/// The clock after merging a remote timestamp: greater than both `last` and
/// `remote`. Keeps this node's name.
pub fn observe(last: Timestamp, remote: Timestamp, now_ms: Int) -> Timestamp {
  let wall = int.max(now_ms, int.max(last.wall_ms, remote.wall_ms))
  let logical = case wall == last.wall_ms, wall == remote.wall_ms {
    True, True -> int.max(last.logical, remote.logical) + 1
    True, False -> last.logical + 1
    False, True -> remote.logical + 1
    False, False -> 0
  }
  Timestamp(wall_ms: wall, logical: logical, node: last.node)
}

/// How far `remote` is ahead of the wall clock, in milliseconds (0 if it is
/// not ahead). The replica logs a warning above its drift threshold.
pub fn drift_ms(remote: Timestamp, now_ms: Int) -> Int {
  int.max(0, remote.wall_ms - now_ms)
}

/// Total order: wall time, then logical counter, then node name.
pub fn compare(a: Timestamp, b: Timestamp) -> Order {
  case int.compare(a.wall_ms, b.wall_ms) {
    order.Eq ->
      case int.compare(a.logical, b.logical) {
        order.Eq -> string.compare(a.node, b.node)
        other -> other
      }
    other -> other
  }
}

/// The later of two timestamps.
pub fn max(a: Timestamp, b: Timestamp) -> Timestamp {
  case compare(a, b) {
    order.Lt -> b
    order.Eq | order.Gt -> a
  }
}

/// `wall_ms.logical@node`, for logs.
pub fn to_string(ts: Timestamp) -> String {
  int.to_string(ts.wall_ms)
  <> "."
  <> int.to_string(ts.logical)
  <> "@"
  <> ts.node
}
