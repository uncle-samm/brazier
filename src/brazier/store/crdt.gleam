//// Add-wins last-writer-wins map: the delta-state CRDT behind replicated
//// stores. A port of the AWLWWMap of delta_crdt_ex (DeltaCrdt.AWLWWMap),
//// itself the "add-wins observed-remove map" of Almeida, Shoker and
//// Baquero, "Delta State Replicated Data Types" (2018), with a timestamp on
//// every value.
////
//// Every value written gets a fresh *dot* `(replica, counter)`. The state
//// is the live dots of every key plus a *causal context*: the set of every
//// dot this replica has ever observed, live or removed. The context is a
//// version vector (`clock`: replica -> highest counter, meaning counters
//// 1..n were all seen) plus a `cloud` of dots seen out of order.
////
//// A write never sends the whole state, only a *delta*: a state fragment
//// with the new dots and, in its context, the dots the write replaced or
//// removed. Joining two states keeps a dot when
////
//// - both sides have it, or
//// - one side has it and the other side's context does not contain it
////   (the other side never saw it, so it cannot have removed it).
////
//// So a removal only removes the dots it observed, and a concurrent write
//// on another node survives it (add wins). Two concurrent writes of one key
//// both survive as dots; reads pick the value with the greatest
//// `(timestamp, dot)` (last writer wins), the same on every node, and the
//// next write of the key replaces both.
////
//// Join is commutative, associative and idempotent, so replicas converge
//// whatever order, duplication or batching deltas and full states arrive
//// in.

import brazier/store/hlc.{type Timestamp}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// One incarnation of a replica: a node and the time its store server
/// started (microseconds). A restarted server is a new replica, so the
/// dots it creates never collide with the ones its previous incarnation
/// created.
pub type Replica {
  Replica(node: String, incarnation: Int)
}

/// The unique identity of one written value.
pub type Dot {
  Dot(replica: Replica, counter: Int)
}

/// A written value with the timestamp that orders it and the extra PubSub
/// topics that are notified when it is added or removed on another node.
pub type Entry(value) {
  Entry(value: value, ts: Timestamp, topics: List(String))
}

/// Every dot observed: `clock` covers counters `1..n` of each replica,
/// `cloud` holds the dots seen beyond a gap.
pub type Context {
  Context(clock: Dict(Replica, Int), cloud: Set(Dot))
}

/// The live dots of a key.
pub type Dots(value) =
  Dict(Dot, Entry(value))

/// A replica's state. `size` is the number of live dots over every key.
pub type State(value) {
  State(entries: Dict(String, Dots(value)), context: Context, size: Int)
}

/// A state fragment produced by a write. `entries` names every key the
/// write touched (a removed key with no dots), `topics` the extra topics
/// to notify on the nodes that merge it.
pub type Delta(value) {
  Delta(
    entries: Dict(String, Dots(value)),
    context: Context,
    topics: List(String),
  )
}

/// A dot that a join added or removed, with its key and entry.
pub type Change(value) {
  Added(key: String, dot: Dot, entry: Entry(value))
  Removed(key: String, dot: Dot, entry: Entry(value))
}

/// The empty state.
pub fn new() -> State(value) {
  State(entries: dict.new(), context: empty_context(), size: 0)
}

fn empty_context() -> Context {
  Context(clock: dict.new(), cloud: set.new())
}

// --- Writes (each returns the new state, its delta and the changes) ---

/// Set `key` to `value`, replacing every value of `key` this replica has
/// observed.
pub fn put(
  state: State(value),
  replica: Replica,
  key: String,
  value: value,
  ts: Timestamp,
  topics: List(String),
) -> #(State(value), Delta(value), List(Change(value))) {
  let dot = next_dot(state.context, replica)
  let entry = Entry(value: value, ts: ts, topics: topics)
  let observed = dict.keys(key_dots(state, key))
  let delta =
    Delta(
      entries: dict.from_list([#(key, dict.from_list([#(dot, entry)]))]),
      context: context_of([dot, ..observed]),
      topics: [],
    )
  apply(state, delta)
}

/// Add every value to `key`, keeping the values already there. Each item
/// gets its own dot; `items` pairs each value with its timestamp.
pub fn append(
  state: State(value),
  replica: Replica,
  key: String,
  items: List(#(value, Timestamp)),
  topics: List(String),
) -> #(State(value), Delta(value), List(Change(value))) {
  let first = next_dot(state.context, replica)
  let added =
    list.index_map(items, fn(item, index) {
      let #(value, ts) = item
      #(
        Dot(replica: replica, counter: first.counter + index),
        Entry(value: value, ts: ts, topics: topics),
      )
    })
  let delta =
    Delta(
      entries: dict.from_list([#(key, dict.from_list(added))]),
      context: context_of(list.map(added, fn(pair) { pair.0 })),
      topics: [],
    )
  apply(state, delta)
}

/// Remove every value of `key` this replica has observed. Values written
/// concurrently on other nodes survive (add wins).
pub fn remove(
  state: State(value),
  key: String,
  topics: List(String),
) -> #(State(value), Delta(value), List(Change(value))) {
  let observed = dict.keys(key_dots(state, key))
  let delta =
    Delta(
      entries: dict.from_list([#(key, dict.new())]),
      context: context_of(observed),
      topics: topics,
    )
  apply(state, delta)
}

fn apply(
  state: State(value),
  delta: Delta(value),
) -> #(State(value), Delta(value), List(Change(value))) {
  let #(next, changes) = join(state, delta)
  #(next, delta, changes)
}

// --- Joins ---

/// Merge a delta: only the keys the delta names can change.
pub fn join(
  state: State(value),
  delta: Delta(value),
) -> #(State(value), List(Change(value))) {
  join_keys(state, delta.entries, delta.context, dict.keys(delta.entries))
}

/// Merge another replica's full state (see `to_delta`): every key of
/// either side can change, since a key absent from `full` may have been
/// removed there.
pub fn join_full(
  state: State(value),
  full: Delta(value),
) -> #(State(value), List(Change(value))) {
  let keys =
    set.union(
      set.from_list(dict.keys(state.entries)),
      set.from_list(dict.keys(full.entries)),
    )
    |> set.to_list
  join_keys(state, full.entries, full.context, keys)
}

fn join_keys(
  state: State(value),
  other: Dict(String, Dots(value)),
  other_context: Context,
  keys: List(String),
) -> #(State(value), List(Change(value))) {
  let #(entries, size, changes) =
    list.fold(keys, #(state.entries, state.size, []), fn(acc, key) {
      let #(entries, size, changes) = acc
      let mine = dict_get_or_empty(entries, key)
      let theirs = dict_get_or_empty(other, key)
      let #(kept, removed) =
        dict.fold(mine, #(dict.new(), []), fn(acc, dot, entry) {
          let #(kept, removed) = acc
          case dict.has_key(theirs, dot) || !covers(other_context, dot) {
            True -> #(dict.insert(kept, dot, entry), removed)
            False -> #(kept, [Removed(key:, dot:, entry:), ..removed])
          }
        })
      let #(joined, added) =
        dict.fold(theirs, #(kept, []), fn(acc, dot, entry) {
          let #(joined, added) = acc
          case dict.has_key(mine, dot) || covers(state.context, dot) {
            True -> acc
            False -> #(dict.insert(joined, dot, entry), [
              Added(key:, dot:, entry:),
              ..added
            ])
          }
        })
      let entries = case dict.is_empty(joined) {
        True -> dict.delete(entries, key)
        False -> dict.insert(entries, key, joined)
      }
      let size = size - list.length(removed) + list.length(added)
      #(entries, size, list.flatten([added, removed, changes]))
    })
  let context = union_context(state.context, other_context)
  #(State(entries:, context:, size:), list.reverse(changes))
}

fn dict_get_or_empty(
  entries: Dict(String, Dots(value)),
  key: String,
) -> Dots(value) {
  case dict.get(entries, key) {
    Ok(dots) -> dots
    Error(Nil) -> dict.new()
  }
}

// --- Causal context ---

/// Whether the context has observed `dot`.
pub fn covers(context: Context, dot: Dot) -> Bool {
  case dict.get(context.clock, dot.replica) {
    Ok(max) if dot.counter <= max -> True
    Ok(_) | Error(Nil) -> set.contains(context.cloud, dot)
  }
}

/// The next dot of `replica`. A replica's own dots are created in order and
/// recorded at once, so they are always compacted into the clock.
fn next_dot(context: Context, replica: Replica) -> Dot {
  let counter = case dict.get(context.clock, replica) {
    Ok(max) -> max + 1
    Error(Nil) -> 1
  }
  Dot(replica: replica, counter: counter)
}

/// The exact context of a set of dots (compaction is lossless: it only
/// moves a dot from the cloud into the clock when every lower counter of
/// its replica is already there).
fn context_of(dots: List(Dot)) -> Context {
  compact(Context(clock: dict.new(), cloud: set.from_list(dots)))
}

fn union_context(a: Context, b: Context) -> Context {
  let clock = dict.combine(a.clock, b.clock, fn(x, y) { int.max(x, y) })
  compact(Context(clock: clock, cloud: set.union(a.cloud, b.cloud)))
}

/// Move every cloud dot that extends its replica's clock into the clock and
/// drop the cloud dots the clock already covers.
fn compact(context: Context) -> Context {
  let sorted = list.sort(set.to_list(context.cloud), compare_dots)
  let #(clock, cloud) =
    list.fold(sorted, #(context.clock, set.new()), fn(acc, dot) {
      let #(clock, cloud) = acc
      let max = case dict.get(clock, dot.replica) {
        Ok(max) -> max
        Error(Nil) -> 0
      }
      case dot.counter <= max, dot.counter == max + 1 {
        True, _ -> acc
        False, True -> #(dict.insert(clock, dot.replica, dot.counter), cloud)
        False, False -> #(clock, set.insert(cloud, dot))
      }
    })
  Context(clock: clock, cloud: cloud)
}

// --- Reads ---

/// The value of `key`: the entry with the greatest `(timestamp, dot)`.
pub fn value(state: State(value), key: String) -> Result(value, Nil) {
  key_dots(state, key)
  |> dict.to_list
  |> list.reduce(fn(a, b) {
    case compare_entries(a, b) {
      order.Lt -> b
      order.Eq | order.Gt -> a
    }
  })
  |> result.map(fn(pair) { { pair.1 }.value })
}

/// Every value of `key`, in `(timestamp, dot)` order.
pub fn values(state: State(value), key: String) -> List(value) {
  key_dots(state, key)
  |> dict.to_list
  |> list.sort(compare_entries)
  |> list.map(fn(pair) { { pair.1 }.value })
}

/// The live dots of `key`.
pub fn key_dots(state: State(value), key: String) -> Dots(value) {
  dict_get_or_empty(state.entries, key)
}

/// The number of live dots over every key.
pub fn size(state: State(value)) -> Int {
  state.size
}

/// The whole state as a delta, for a full sync (merge it with
/// `join_full`).
pub fn to_delta(state: State(value)) -> Delta(value) {
  Delta(entries: state.entries, context: state.context, topics: [])
}

/// The number of dots a delta carries.
pub fn delta_size(delta: Delta(value)) -> Int {
  dict.fold(delta.entries, 0, fn(total, _key, dots) { total + dict.size(dots) })
}

/// The latest timestamp a delta carries, to advance the receiver's clock.
pub fn max_timestamp(delta: Delta(value)) -> Result(Timestamp, Nil) {
  dict.fold(delta.entries, Error(Nil), fn(acc, _key, dots) {
    dict.fold(dots, acc, fn(acc, _dot, entry) {
      case acc {
        Ok(ts) -> Ok(hlc.max(ts, entry.ts))
        Error(Nil) -> Ok(entry.ts)
      }
    })
  })
}

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
        order.Eq -> compare_dots(a.1, b.1)
        other -> other
      }
    })
  let clock =
    dict.to_list(state.context.clock)
    |> list.sort(fn(a, b) { compare_replicas(a.0, b.0) })
  let cloud = list.sort(set.to_list(state.context.cloud), compare_dots)
  #(live, clock, cloud)
}

// --- Order ---

/// Last writer wins: timestamp first, then dot, so the order is total.
fn compare_entries(a: #(Dot, Entry(value)), b: #(Dot, Entry(value))) -> Order {
  case hlc.compare({ a.1 }.ts, { b.1 }.ts) {
    order.Eq -> compare_dots(a.0, b.0)
    other -> other
  }
}

/// Replica, then counter.
pub fn compare_dots(a: Dot, b: Dot) -> Order {
  case compare_replicas(a.replica, b.replica) {
    order.Eq -> int.compare(a.counter, b.counter)
    other -> other
  }
}

fn compare_replicas(a: Replica, b: Replica) -> Order {
  case string.compare(a.node, b.node) {
    order.Eq -> int.compare(a.incarnation, b.incarnation)
    other -> other
  }
}

/// `node/incarnation`, for logs.
pub fn replica_to_string(replica: Replica) -> String {
  replica.node <> "/" <> int.to_string(replica.incarnation)
}
