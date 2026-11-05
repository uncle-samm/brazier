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
////
//// Every state carries a `digest` of itself for anti-entropy, kept up to
//// date by every join instead of recomputed (see `digest`).
////
//// ## Floors: a context bounded across restarts
////
//// A restarted store server is a new replica (a new incarnation of its
//// node), so without more every restart would add a clock entry that no
//// replica could ever drop. The context therefore also holds *floors*:
//// `floors[node] = i` covers every dot of every incarnation of `node`
//// below `i`, so the clock entries and cloud dots of those incarnations
//// are dropped. Only an incarnation raises its own node's floor, to
//// itself (`raise_floor`), and only once every replica it can reach holds
//// the same state, so every dot of an earlier incarnation any of them
//// holds is in its own state: a live one stays live (a floor covers a dot,
//// it does not remove it), a removed one stays removed. The context then
//// holds at most one incarnation per node name that is still compacting,
//// plus the incarnations that started since a node's last raise.
////
//// The cost is a narrow loss: a dot of an earlier incarnation that only a
//// replica out of reach held (partitioned, or a node whose replica had not
//// yet joined), or that was still in flight, is covered without having
//// been seen, so it is dropped wherever it arrives. The earlier
//// incarnation itself is gone, and its writes are fire and forget, so such
//// a write was already at risk; docs/CLUSTERING.md says when it happens.
////
//// ## Against delta_crdt_ex
////
//// The join of dot sets is delta_crdt_ex's `AWLWWMap.join_dot_sets/4`
//// (the formula on `join_keys`); the differences are:
////
//// - The context is exact: delta_crdt_ex's `Dots.compress` folds a dot
////   set into one counter per replica, which also covers counters below
////   it that it never saw. Here a dot beyond a gap stays in the cloud
////   until the gap fills, and only a contiguous run moves into the clock.
//// - Values are ordered by a hybrid logical clock (`brazier/store/hlc`)
////   and ties break on the dot, a total order, so every node reads the
////   same value. delta_crdt_ex stamps a value with the writer's
////   `System.monotonic_time`, which is not comparable across nodes, and
////   reads the greatest with `Enum.max_by`, with no tie-break.
//// - Floors (above): delta_crdt_ex never shrinks its context, and its node
////   id is a fresh `:rand.uniform(1_000_000_000)` on every start, so its
////   context grows with every restart (and two starts can draw one id).
//// - Anti-entropy compares one incremental digest (see `digest`) and a
////   mismatch pulls the whole state; delta_crdt_ex walks a Merkle tree
////   down to the differing keys and sends only those, one sync in flight
////   per neighbour until it is acknowledged.

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
/// `cloud` holds the dots seen beyond a gap, and `floors` covers every dot
/// of each node's incarnations below its floor (node name -> incarnation,
/// always at least 1; see the module doc). No clock entry or cloud dot of
/// a state is under a floor: joins drop them.
pub type Context {
  Context(clock: Dict(Replica, Int), cloud: Set(Dot), floors: Dict(String, Int))
}

/// The live dots of a key.
pub type Dots(value) =
  Dict(Dot, Entry(value))

/// A replica's state. `size` is the number of live dots over every key and
/// `digest` the XOR of the hashes of its elements (see `digest`); both are
/// kept up to date by every join.
pub type State(value) {
  State(
    entries: Dict(String, Dots(value)),
    context: Context,
    size: Int,
    digest: Int,
  )
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

/// The empty state. Its digest is 0, the XOR of no hashes.
pub fn new() -> State(value) {
  State(entries: dict.new(), context: empty_context(), size: 0, digest: 0)
}

fn empty_context() -> Context {
  Context(clock: dict.new(), cloud: set.new(), floors: dict.new())
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

/// Merge a delta: only the keys the delta names can change. The cost
/// follows the delta, not the key: appending to a key that holds 10,000
/// values visits none of them (see `join_keys`). The changes come in no
/// particular order.
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

/// The DotSet join of Almeida, Shoker and Baquero, key by key:
///
///     (s, c) ⊔ (s', c') = ((s ∩ s') ∪ (s \ c') ∪ (s' \ c), c ∪ c')
///
/// (delta_crdt_ex `AWLWWMap.join_dot_sets/4` computes the same three sets).
/// Written as edits to `s`: a dot of `s` goes when `c'` covers it and `s'`
/// lacks it, and a dot of `s'` comes in when `c` does not cover it.
///
/// The removed dots are `s ∩ c'` minus `s'`, and `s ∩ c'` is found from
/// whichever side is smaller: scanning `s` and testing `c'` (what a full
/// state needs: its context covers everything), or listing the dots of
/// `c'` and looking each up in `s` (what a delta needs: an append's
/// context is only its own new dots, so the values already under the key
/// are never visited). Both give the same set; `observed` is the number of
/// dots `c'` lists, counted once per join. So a join costs
/// O(min(|s|, |c'|) + |s'|) per key, never more than the full scan.
fn join_keys(
  state: State(value),
  other: Dict(String, Dots(value)),
  other_context: Context,
  keys: List(String),
) -> #(State(value), List(Change(value))) {
  let observed = context_dot_count(other_context)
  let start = #(state.entries, state.size, [], state.digest)
  let #(entries, size, changes, digest) =
    list.fold(keys, start, fn(acc, key) {
      let #(entries, size, changes, digest) = acc
      let mine = dict_get_or_empty(entries, key)
      let theirs = dict_get_or_empty(other, key)
      let #(removed, removed_count) =
        removed_dots(mine, theirs, other_context, observed)
      let #(changes, digest) =
        list.fold(removed, #(changes, digest), fn(acc, pair) {
          #(
            [Removed(key:, dot: pair.0, entry: pair.1), ..acc.0],
            toggle(acc.1, LiveDot(key:, dot: pair.0)),
          )
        })
      let kept = case removed_count == dict.size(mine) {
        // A put or remove replaces every value it observed: nothing to
        // drop one by one.
        True -> dict.new()
        False ->
          case removed {
            [] -> mine
            _ -> dict.drop(mine, list.map(removed, fn(pair) { pair.0 }))
          }
      }
      let #(joined, changes, added, digest) =
        dict.fold(theirs, #(kept, changes, 0, digest), fn(acc, dot, entry) {
          let #(joined, changes, added, digest) = acc
          case dict.has_key(mine, dot) || covers(state.context, dot) {
            True -> acc
            False -> #(
              dict.insert(joined, dot, entry),
              [Added(key:, dot:, entry:), ..changes],
              added + 1,
              toggle(digest, LiveDot(key:, dot:)),
            )
          }
        })
      let entries = case dict.is_empty(joined) {
        True -> dict.delete(entries, key)
        False -> dict.insert(entries, key, joined)
      }
      #(entries, size - removed_count + added, changes, digest)
    })
  let #(context, digest) =
    union_context(state.context, other_context, digest, toggle)
  #(State(entries:, context:, size:, digest:), list.reverse(changes))
}

/// The dots of `mine` that `context` covers and `theirs` lacks (the ones
/// the other side saw and then replaced or removed), each once, and how
/// many there are. `observed` is `context_dot_count(context)`. A context
/// with floors covers dots no listing can name (every counter of an older
/// incarnation), so it is always scanned; a write's delta has none, so its
/// joins keep the listing path.
fn removed_dots(
  mine: Dots(value),
  theirs: Dots(value),
  context: Context,
  observed: Int,
) -> #(List(#(Dot, Entry(value))), Int) {
  case observed < dict.size(mine) && dict.is_empty(context.floors) {
    True -> {
      // Collected in a dict: an uncompacted context lists a dot twice.
      let removed =
        fold_context_dots(context, dict.new(), fn(removed, dot) {
          case dict.get(mine, dot) {
            Ok(entry) ->
              case dict.has_key(theirs, dot) {
                True -> removed
                False -> dict.insert(removed, dot, entry)
              }
            Error(Nil) -> removed
          }
        })
      #(dict.to_list(removed), dict.size(removed))
    }
    False ->
      dict.fold(mine, #([], 0), fn(acc, dot, entry) {
        case !dict.has_key(theirs, dot) && covers(context, dot) {
          True -> #([#(dot, entry), ..acc.0], acc.1 + 1)
          False -> acc
        }
      })
  }
}

/// How many dots `fold_context_dots` visits: every counter `1..n` of each
/// clock entry plus the cloud.
fn context_dot_count(context: Context) -> Int {
  dict.fold(context.clock, set.size(context.cloud), fn(count, _replica, max) {
    count + int.max(max, 0)
  })
}

/// Visit every dot the context lists: counters `1..n` of each clock entry,
/// then the cloud. A cloud dot the clock also covers (a context that was
/// not compacted) is visited twice; callers collect into a dict, so that
/// is harmless.
fn fold_context_dots(
  context: Context,
  acc: acc,
  visit: fn(acc, Dot) -> acc,
) -> acc {
  let acc =
    dict.fold(context.clock, acc, fn(acc, replica, max) {
      fold_counters(replica, 1, max, acc, visit)
    })
  set.fold(context.cloud, acc, visit)
}

fn fold_counters(
  replica: Replica,
  counter: Int,
  max: Int,
  acc: acc,
  visit: fn(acc, Dot) -> acc,
) -> acc {
  case counter > max {
    True -> acc
    False ->
      fold_counters(
        replica,
        counter + 1,
        max,
        visit(acc, Dot(replica:, counter:)),
        visit,
      )
  }
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

/// Whether the context has observed `dot`. A clock entry `n` covers
/// counters `1..n` only: `next_dot` never makes a counter below 1, and a
/// clock that covered one would cover dots `fold_context_dots` cannot list,
/// so the two ways `join_keys` finds removed dots would disagree on a
/// malformed delta from a peer. A floor covers every dot of the node's
/// incarnations below it.
pub fn covers(context: Context, dot: Dot) -> Bool {
  case below_floor(context.floors, dot.replica) {
    True -> True
    False ->
      case dict.get(context.clock, dot.replica) {
        Ok(max) if dot.counter >= 1 && dot.counter <= max -> True
        Ok(_) | Error(Nil) -> set.contains(context.cloud, dot)
      }
  }
}

/// Whether `replica` is an incarnation below its node's floor.
fn below_floor(floors: Dict(String, Int), replica: Replica) -> Bool {
  case dict.get(floors, replica.node) {
    Ok(floor) -> replica.incarnation < floor
    Error(Nil) -> False
  }
}

/// The floor of `node` in the state's context: 0 when it has none (an
/// incarnation is never below 0).
pub fn floor(state: State(value), node: String) -> Int {
  floor_or_zero(state.context.floors, node)
}

fn floor_or_zero(floors: Dict(String, Int), node: String) -> Int {
  case dict.get(floors, node) {
    Ok(floor) -> floor
    Error(Nil) -> 0
  }
}

/// Whether the state's context holds a clock entry or cloud dot of an
/// incarnation of `replica`'s node older than `replica`: what
/// `raise_floor` would drop. O(clock entries + cloud dots); a replica asks
/// once it is in sync with every peer, not on every join.
pub fn has_older_incarnation(state: State(value), replica: Replica) -> Bool {
  let older = fn(other: Replica) {
    other.node == replica.node && other.incarnation < replica.incarnation
  }
  list.any(dict.keys(state.context.clock), older)
  || set.fold(state.context.cloud, False, fn(found, dot) {
    found || older(dot.replica)
  })
}

/// Raise `replica`'s node's floor to `replica`'s incarnation, covering
/// every dot of the node's older incarnations and dropping their clock
/// entries and cloud dots. Their live dots stay live. Returns the new state
/// and the delta to broadcast (a context with only the floor, so a join of
/// it removes no live dot), or `Error(Nil)` when the floor is already
/// there or higher (nothing to raise). Only the incarnation itself may
/// raise its node's floor, and only once it holds every reachable
/// replica's state (see the module doc).
pub fn raise_floor(
  state: State(value),
  replica: Replica,
) -> Result(#(State(value), Delta(value)), Nil) {
  case replica.incarnation > floor(state, replica.node) {
    False -> Error(Nil)
    True -> {
      let delta =
        Delta(
          entries: dict.new(),
          context: Context(
            clock: dict.new(),
            cloud: set.new(),
            floors: dict.from_list([#(replica.node, replica.incarnation)]),
          ),
          topics: [],
        )
      let #(next, _changes) = join(state, delta)
      Ok(#(next, delta))
    }
  }
}

/// The number of elements the state's context holds: clock entries, cloud
/// dots and floors. Floors keep it bounded across restarts.
pub fn context_size(state: State(value)) -> Int {
  dict.size(state.context.clock)
  + set.size(state.context.cloud)
  + dict.size(state.context.floors)
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
/// A delta has no digest, so its context is built untracked.
fn context_of(dots: List(Dot)) -> Context {
  let #(context, _digest) =
    union_context(
      empty_context(),
      Context(clock: dict.new(), cloud: set.from_list(dots), floors: dict.new()),
      0,
      untracked,
    )
  context
}

/// The compacted union of a compacted context `a` (a state's context: every
/// context this module builds is compacted) and any context `b`.
///
/// *Compacted* means: no cloud dot is at or below its replica's clock (0
/// when the replica has no entry), and no cloud dot is the counter right
/// after it, so the clock cannot be extended. Given that of `a`, only the
/// replicas `b` names can change, and only by the dots `b` brings: the
/// cloud dots of `a` its clock now covers are dropped, `b`'s cloud dots
/// above the clock are added, and each named replica's clock is extended
/// while the next counter is in the cloud. The cost is
/// O(|b| + min(counters b's clock newly covers, |a.cloud|) + dots absorbed
/// into the clock), not O(|a.cloud| log |a.cloud|): the cloud of a state is
/// never sorted, and is walked only when `b`'s clock newly covers more
/// counters than the cloud holds. The result is exactly the one
/// sorting the whole cloud gives (the oracle in crdt_test), and is
/// compacted again, so the invariant holds for every state.
///
/// The compaction rule is the one of Almeida, Shoker and Baquero (a dot
/// joins the version vector once every lower counter of its replica has
/// been seen); applying it only to the replicas a delta names is what keeps
/// a join's cost following the delta, as `join_keys` does for the dots.
///
/// `digest` is the digest of a state whose context is `a`; the result
/// carries it updated for the new context. `toggle` folds in every element
/// of the context that is added or removed (`untracked` for a context with
/// no digest), so the digest costs O(elements that change), as the rest of
/// the union does.
///
/// Floors come first: each floor `b` raises drops the clock entries and
/// cloud dots of `a` it now covers (one pass over `a`'s clock and cloud,
/// only when a floor rises, which is once per restart of a node), and the
/// clock entries and cloud dots of `b` under the joined floors are left
/// out, so no state ever holds an element a floor covers. With no floor on
/// either side this costs nothing.
fn union_context(
  a: Context,
  b: Context,
  digest: Int,
  toggle: fn(Int, Element) -> Int,
) -> #(Context, Int) {
  let #(a, digest) = raise_floors(a, b.floors, digest, toggle)
  let b = above_floors(b, a.floors)
  let clock = dict.combine(a.clock, b.clock, fn(x, y) { int.max(x, y) })
  let #(cloud, digest) = drop_covered(a, b.clock, digest, toggle)
  // Every replica `b` names is a candidate for extension: its clock may
  // have moved (up, or for a replica `a` lacked, below 0) or its cloud
  // grown.
  let #(cloud, touched, digest) =
    set.fold(b.cloud, #(cloud, dict.keys(b.clock), digest), fn(acc, dot) {
      let #(cloud, touched, digest) = acc
      case dot.counter <= clock_or_zero(clock, dot.replica) {
        True -> acc
        False ->
          case set.contains(cloud, dot) {
            True -> #(cloud, [dot.replica, ..touched], digest)
            False -> #(
              set.insert(cloud, dot),
              [dot.replica, ..touched],
              toggle(digest, CloudDot(dot)),
            )
          }
      }
    })
  let #(clock, cloud, digest) =
    list.fold(touched, #(clock, cloud, digest), fn(acc, replica) {
      let #(clock, cloud, digest) = acc
      extend(clock, cloud, replica, digest, toggle)
    })
  // Only a replica `b` names can have a new clock entry: fold out the old
  // entry and in the new one of each that moved, once.
  let digest =
    set.fold(set.from_list(touched), digest, fn(digest, replica) {
      let old = dict.get(a.clock, replica)
      let new = dict.get(clock, replica)
      case old == new {
        True -> digest
        False ->
          digest
          |> toggle_entry(old, replica, toggle)
          |> toggle_entry(new, replica, toggle)
      }
    })
  #(Context(clock:, cloud:, floors: a.floors), digest)
}

/// `a` with every floor of `floors` that is higher than its own, and
/// without the clock entries and cloud dots those floors now cover, with
/// `digest` updated for every element that changed.
fn raise_floors(
  a: Context,
  floors: Dict(String, Int),
  digest: Int,
  toggle: fn(Int, Element) -> Int,
) -> #(Context, Int) {
  let raised =
    dict.fold(floors, dict.new(), fn(raised, node, floor) {
      case floor > floor_or_zero(a.floors, node) {
        True -> dict.insert(raised, node, floor)
        False -> raised
      }
    })
  case dict.is_empty(raised) {
    True -> #(a, digest)
    False -> {
      let digest =
        dict.fold(raised, digest, fn(digest, node, floor) {
          let digest = case dict.get(a.floors, node) {
            Ok(old) -> toggle(digest, FloorEntry(node:, incarnation: old))
            Error(Nil) -> digest
          }
          toggle(digest, FloorEntry(node:, incarnation: floor))
        })
      let #(clock, digest) =
        dict.fold(a.clock, #(a.clock, digest), fn(acc, replica, max) {
          case below_floor(raised, replica) {
            True -> #(
              dict.delete(acc.0, replica),
              toggle(acc.1, ClockEntry(replica:, max:)),
            )
            False -> acc
          }
        })
      let #(cloud, digest) =
        set.fold(a.cloud, #(a.cloud, digest), fn(acc, dot) {
          case below_floor(raised, dot.replica) {
            True -> #(set.delete(acc.0, dot), toggle(acc.1, CloudDot(dot)))
            False -> acc
          }
        })
      let floors = dict.merge(a.floors, raised)
      #(Context(clock:, cloud:, floors:), digest)
    }
  }
}

/// `b` without the clock entries and cloud dots `floors` covers. `b` is
/// not part of any digest, so nothing is folded.
fn above_floors(b: Context, floors: Dict(String, Int)) -> Context {
  case dict.is_empty(floors) {
    True -> b
    False ->
      Context(
        ..b,
        clock: dict.filter(b.clock, fn(replica, _max) {
          !below_floor(floors, replica)
        }),
        cloud: set.filter(b.cloud, fn(dot) { !below_floor(floors, dot.replica) }),
      )
  }
}

fn toggle_entry(
  digest: Int,
  entry: Result(Int, Nil),
  replica: Replica,
  toggle: fn(Int, Element) -> Int,
) -> Int {
  case entry {
    Ok(max) -> toggle(digest, ClockEntry(replica:, max:))
    Error(Nil) -> digest
  }
}

/// The cloud of `a` without the dots `clock` (another context's clock)
/// covers and `a.clock` did not, with `digest` updated for each dot
/// dropped. Probes each newly covered counter, or scans the cloud once
/// when that is fewer steps.
fn drop_covered(
  a: Context,
  clock: Dict(Replica, Int),
  digest: Int,
  toggle: fn(Int, Element) -> Int,
) -> #(Set(Dot), Int) {
  let raised =
    dict.fold(clock, [], fn(raised, replica, max) {
      let old = clock_or_zero(a.clock, replica)
      case max > old {
        True -> [#(replica, old, max), ..raised]
        False -> raised
      }
    })
  let probes =
    list.fold(raised, 0, fn(probes, raise) { probes + raise.2 - raise.1 })
  case raised, probes <= set.size(a.cloud) {
    [], _ -> #(a.cloud, digest)
    _, True ->
      list.fold(raised, #(a.cloud, digest), fn(acc, raise) {
        let #(replica, old, max) = raise
        drop_counters(acc.0, replica, old + 1, max, acc.1, toggle)
      })
    _, False -> {
      let raised =
        list.fold(raised, dict.new(), fn(raised, raise) {
          dict.insert(raised, raise.0, raise.2)
        })
      set.fold(a.cloud, #(a.cloud, digest), fn(acc, dot) {
        case dict.get(raised, dot.replica) {
          Ok(max) if dot.counter <= max -> #(
            set.delete(acc.0, dot),
            toggle(acc.1, CloudDot(dot)),
          )
          Ok(_) | Error(Nil) -> acc
        }
      })
    }
  }
}

fn drop_counters(
  cloud: Set(Dot),
  replica: Replica,
  counter: Int,
  max: Int,
  digest: Int,
  toggle: fn(Int, Element) -> Int,
) -> #(Set(Dot), Int) {
  case counter > max {
    True -> #(cloud, digest)
    False -> {
      let dot = Dot(replica:, counter:)
      let #(cloud, digest) = case set.contains(cloud, dot) {
        True -> #(set.delete(cloud, dot), toggle(digest, CloudDot(dot)))
        False -> #(cloud, digest)
      }
      drop_counters(cloud, replica, counter + 1, max, digest, toggle)
    }
  }
}

/// Move the cloud dots that continue `replica`'s clock into the clock, one
/// counter at a time, with `digest` updated for each dot that leaves the
/// cloud (`union_context` updates it for the clock entry). A replica with
/// no entry starts at 0 and gets one only if its counter 1 is in the cloud.
fn extend(
  clock: Dict(Replica, Int),
  cloud: Set(Dot),
  replica: Replica,
  digest: Int,
  toggle: fn(Int, Element) -> Int,
) -> #(Dict(Replica, Int), Set(Dot), Int) {
  let max = clock_or_zero(clock, replica)
  let next = Dot(replica:, counter: max + 1)
  case set.contains(cloud, next) {
    False -> #(clock, cloud, digest)
    True ->
      extend(
        dict.insert(clock, replica, next.counter),
        set.delete(cloud, next),
        replica,
        toggle(digest, CloudDot(next)),
        toggle,
      )
  }
}

fn clock_or_zero(clock: Dict(Replica, Int), replica: Replica) -> Int {
  case dict.get(clock, replica) {
    Ok(max) -> max
    Error(Nil) -> 0
  }
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

// --- Digest ---

/// One element of a state, as the digest hashes it: a live dot under its
/// key, a clock entry, a cloud dot or a floor. Values are left out: a dot
/// names one value forever.
type Element {
  LiveDot(key: String, dot: Dot)
  ClockEntry(replica: Replica, max: Int)
  CloudDot(dot: Dot)
  FloorEntry(node: String, incarnation: Int)
}

/// The state's digest for anti-entropy: the XOR of the 256-bit hashes of
/// its elements (every live `(key, dot)`, clock entry, cloud dot and
/// floor). Two
/// replicas hold the same digest exactly when they hold the same elements,
/// up to a hash collision. Reading it costs nothing: every join folds in
/// the elements it adds and removes (XOR is its own inverse, and the
/// result does not depend on order), so a write costs a few hashes and a
/// digest exchange never walks the state.
///
/// This is the incremental tree hash of Riak's TicTac AAE
/// (`leveled_tictac`, whose segment hashes are XORs of per-key hashes,
/// updated by XOR-ing in the hash of each change), with one segment, since
/// a mismatch pulls the whole state. delta_crdt_ex keeps its MerkleMap up
/// to date on every change for the same reason. XOR resists accidental
/// collisions, not crafted ones, which is enough between members: they
/// trust each other completely.
pub fn digest(state: State(value)) -> Int {
  state.digest
}

/// The digest computed from the whole state, in O(state) and without
/// sorting: what `digest` must always equal (the tests check it after
/// every join).
pub fn recompute_digest(state: State(value)) -> Int {
  let digest =
    dict.fold(state.entries, 0, fn(digest, key, dots) {
      dict.fold(dots, digest, fn(digest, dot, _entry) {
        toggle(digest, LiveDot(key:, dot:))
      })
    })
  let digest =
    dict.fold(state.context.clock, digest, fn(digest, replica, max) {
      toggle(digest, ClockEntry(replica:, max:))
    })
  let digest =
    set.fold(state.context.cloud, digest, fn(digest, dot) {
      toggle(digest, CloudDot(dot))
    })
  dict.fold(state.context.floors, digest, fn(digest, node, incarnation) {
    toggle(digest, FloorEntry(node:, incarnation:))
  })
}

/// Fold `element` into or out of `digest`.
fn toggle(digest: Int, element: Element) -> Int {
  int.bitwise_exclusive_or(digest, element_hash(element))
}

fn untracked(digest: Int, _element: Element) -> Int {
  digest
}

/// The SHA-256 of the element's canonical external term format, as a
/// 256-bit integer: the same on every node and OTP release.
@external(erlang, "brazier_crdt_ffi", "element_hash")
fn element_hash(element: Element) -> Int

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
