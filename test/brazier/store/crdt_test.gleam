//// Properties of the AWLWWMap join (brazier/store/crdt) over random
//// operation histories, checked against the full-scan join it replaced,
//// which is kept here verbatim as the oracle (`oracle_*`). The histories
//// come from fixed seeds, so every failure names a reproducible seed and
//// step. The single-case tests in store_replicated_test cover the
//// documented behaviour; this module covers the join's algebra and the
//// cost of appending.

import brazier/store/crdt.{
  type Change, type Context, type Delta, type Dot, type Dots, type State, Added,
  Context, Delta, Dot, Removed, Replica, State,
}
import brazier/store/hlc.{Timestamp}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/set
import gleam/string

const replica_count = 3

const key_count = 3

const history_seeds = [
  1, 7, 42, 99, 314, 2718, 4242, 9001, 12_345, 20_261_104, 31_337, 65_521,
  77_777, 100_003, 271_828, 314_159, 424_242, 999_983, 1_234_567, 7_654_321,
]

const history_steps = 500

/// How far back a catching-up delivery reaches into the pool.
const recent_deltas = 8

// --- Random histories ---------------------------------------------------

/// A 31-bit linear congruential generator (the ANSI C constants): enough
/// spread for picking operations, and the same sequence on every run.
type Rng {
  Rng(seed: Int)
}

fn next(rng: Rng, bound: Int) -> #(Int, Rng) {
  let seed = { rng.seed * 1_103_515_245 + 12_345 } % 2_147_483_648
  // The low bits of an LCG cycle quickly; use the high ones.
  #({ seed / 65_536 } % bound, Rng(seed))
}

type Node {
  Node(replica: crdt.Replica, state: State(Int))
}

/// Three replicas and every delta any of them ever produced (`pool`, by
/// index), so a delivery can repeat a delta or deliver it late.
type World {
  World(
    nodes: Dict(Int, Node),
    pool: Dict(Int, Delta(Int)),
    rng: Rng,
    tally: Tally,
  )
}

/// How often the history exercised each way of finding removed dots: by
/// listing a context smaller than the key (`listed`) or by scanning a key
/// no larger than the context (`scanned`). Counted only for joins that
/// removed something, so a zero means the history never tested that path.
type Tally {
  Tally(listed: Int, scanned: Int)
}

fn new_world(seed: Int) -> World {
  let nodes =
    int.range(from: 0, to: replica_count, with: dict.new(), run: fn(nodes, i) {
      let replica =
        Replica(node: "n" <> int.to_string(i) <> "@host", incarnation: 1)
      dict.insert(nodes, i, Node(replica: replica, state: crdt.new()))
    })
  World(nodes:, pool: dict.new(), rng: Rng(seed), tally: Tally(0, 0))
}

fn run_history(seed: Int) -> World {
  int.range(
    from: 0,
    to: history_steps,
    with: new_world(seed),
    run: fn(world, step) { step_world(seed, step, world) },
  )
}

fn node_at(world: World, slot: Int) -> Node {
  let assert Ok(node) = dict.get(world.nodes, slot)
    as "new_world fills every slot below replica_count"
  node
}

fn step_world(seed: Int, step: Int, world: World) -> World {
  let label = "seed " <> int.to_string(seed) <> " step " <> int.to_string(step)
  let #(op, rng) = next(world.rng, 100)
  let #(slot, rng) = next(rng, replica_count)
  let #(k, rng) = next(rng, key_count)
  let key = "k" <> int.to_string(k)
  let node = node_at(world, slot)
  // Every third step shares a wall time, so timestamps tie and the dot
  // breaks the tie.
  let at = Timestamp(wall_ms: step / 3, logical: 0, node: node.replica.node)
  case op {
    op if op < 30 -> {
      let #(extra, rng) = next(rng, 3)
      let items =
        int.range(from: 0, to: extra + 1, with: [], run: fn(items, i) {
          [#(step * 10 + i, at), ..items]
        })
      let world = World(..world, rng:)
      local(
        label <> " append",
        world,
        slot,
        node,
        crdt.append(node.state, node.replica, key, items, []),
      )
    }
    op if op < 45 ->
      local(
        label <> " put",
        World(..world, rng:),
        slot,
        node,
        crdt.put(node.state, node.replica, key, step * 10, at, []),
      )
    op if op < 55 ->
      local(
        label <> " remove",
        World(..world, rng:),
        slot,
        node,
        crdt.remove(node.state, key, []),
      )
    op if op < 90 ->
      case dict.size(world.pool) {
        0 -> World(..world, rng:)
        size -> {
          // Mostly one of the last few deltas (a peer catching up), one
          // time in four any delta at all (late or repeated).
          let #(stale, rng) = next(rng, 4)
          let #(index, rng) = case stale {
            0 -> next(rng, size)
            _ -> {
              let #(back, rng) = next(rng, int.min(size, recent_deltas))
              #(size - 1 - back, rng)
            }
          }
          let assert Ok(delta) = dict.get(world.pool, index)
            as "the pool is indexed 0..size-1"
          let tally = tally_join(world.tally, node.state, delta)
          let state =
            same_join(
              label <> " deliver delta " <> int.to_string(index),
              crdt.join(node.state, delta),
              oracle_join(node.state, delta),
            )
          World(
            ..world,
            nodes: dict.insert(world.nodes, slot, Node(..node, state:)),
            rng:,
            tally:,
          )
        }
      }
    op if op < 98 -> {
      let #(hop, rng) = next(rng, replica_count - 1)
      let other = node_at(world, { slot + 1 + hop } % replica_count)
      let full = crdt.to_delta(other.state)
      let state =
        same_join(
          label <> " full sync",
          crdt.join_full(node.state, full),
          oracle_join_full(node.state, full),
        )
      World(
        ..world,
        nodes: dict.insert(world.nodes, slot, Node(..node, state:)),
        rng:,
      )
    }
    _ -> {
      // A restarted store server is a new replica with an empty state.
      let replica =
        Replica(..node.replica, incarnation: node.replica.incarnation + 1)
      World(
        ..world,
        nodes: dict.insert(world.nodes, slot, Node(replica:, state: crdt.new())),
        rng:,
      )
    }
  }
}

/// A local write: the state it returns must be the oracle's join of its
/// own delta, and the delta joins the pool.
fn local(
  label: String,
  world: World,
  slot: Int,
  node: Node,
  written: #(State(Int), Delta(Int), List(Change(Int))),
) -> World {
  let #(next_state, delta, changes) = written
  let state =
    same_join(label, #(next_state, changes), oracle_join(node.state, delta))
  World(
    ..world,
    nodes: dict.insert(world.nodes, slot, Node(..node, state:)),
    pool: dict.insert(world.pool, dict.size(world.pool), delta),
  )
}

fn tally_join(tally: Tally, state: State(Int), delta: Delta(Int)) -> Tally {
  dict.fold(delta.entries, tally, fn(tally, key, theirs) {
    let mine = crdt.key_dots(state, key)
    let removes =
      dict.fold(mine, False, fn(found, dot, _entry) {
        found
        || { crdt.covers(delta.context, dot) && !dict.has_key(theirs, dot) }
      })
    case removes, listed_dots(delta.context) < dict.size(mine) {
      False, _ -> tally
      True, True -> Tally(..tally, listed: tally.listed + 1)
      True, False -> Tally(..tally, scanned: tally.scanned + 1)
    }
  })
}

fn listed_dots(context: Context) -> Int {
  dict.fold(context.clock, set.size(context.cloud), fn(n, _replica, max) {
    n + int.max(max, 0)
  })
}

/// The pool in the order the deltas were made.
fn pool_list(world: World) -> List(Delta(Int)) {
  int.range(from: dict.size(world.pool) - 1, to: -1, with: [], run: fn(acc, i) {
    let assert Ok(delta) = dict.get(world.pool, i)
      as "the pool is indexed 0..size-1"
    [delta, ..acc]
  })
}

fn shuffle(items: List(a), rng: Rng) -> #(List(a), Rng) {
  let #(keyed, rng) =
    list.fold(items, #([], rng), fn(acc, item) {
      let #(keyed, rng) = acc
      let #(r, rng) = next(rng, 1_000_000)
      #([#(r, item), ..keyed], rng)
    })
  #(
    keyed
      |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
      |> list.map(fn(pair) { pair.1 }),
    rng,
  )
}

fn join_all(state: State(Int), deltas: List(Delta(Int))) -> State(Int) {
  list.fold(deltas, state, fn(state, delta) { crdt.join(state, delta).0 })
}

// --- Checks -------------------------------------------------------------

/// The new join and the oracle agree exactly on the state (entries, every
/// value, context, size) and on the set of changes; the result keeps the
/// state invariants. Returns the joined state.
fn same_join(
  label: String,
  new: #(State(Int), List(Change(Int))),
  old: #(State(Int), List(Change(Int))),
) -> State(Int) {
  check_same(label, new, old)
  new.0
}

fn check_same(
  label: String,
  new: #(State(Int), List(Change(Int))),
  old: #(State(Int), List(Change(Int))),
) -> Nil {
  assert new.0 == old.0 as { label <> ": the joined states differ" }
  assert sorted_changes(new.1) == sorted_changes(old.1)
    as { label <> ": the changes differ" }
  check_invariants(label, new.0)
}

/// No key is kept with no dots, `size` counts the live dots, and the
/// context has observed every live dot.
fn check_invariants(label: String, state: State(Int)) -> Nil {
  let live =
    dict.fold(state.entries, 0, fn(live, key, dots) {
      assert !dict.is_empty(dots) as { label <> ": " <> key <> " has no dots" }
      dict.fold(dots, live, fn(live, dot, _entry) {
        assert crdt.covers(state.context, dot)
          as { label <> ": a live dot of " <> key <> " is not in the context" }
        live + 1
      })
    })
  assert crdt.size(state) == live
    as {
      label
      <> ": size "
      <> int.to_string(crdt.size(state))
      <> " but "
      <> int.to_string(live)
      <> " live dots"
    }
}

fn sorted_changes(changes: List(Change(Int))) -> List(Change(Int)) {
  list.sort(changes, compare_changes)
}

fn compare_changes(a: Change(Int), b: Change(Int)) -> Order {
  use <- order.lazy_break_tie(string.compare(a.key, b.key))
  use <- order.lazy_break_tie(crdt.compare_dots(a.dot, b.dot))
  int.compare(change_kind(a), change_kind(b))
}

fn change_kind(change: Change(Int)) -> Int {
  case change {
    Added(..) -> 0
    Removed(..) -> 1
  }
}

// --- Properties over random histories ----------------------------------

pub fn every_join_of_a_random_history_matches_the_full_scan_oracle_test() {
  let tally =
    list.fold(history_seeds, Tally(0, 0), fn(tally, seed) {
      let world = run_history(seed)
      Tally(
        listed: tally.listed + world.tally.listed,
        scanned: tally.scanned + world.tally.scanned,
      )
    })
  // The histories removed dots through both paths of join_keys, so the
  // oracle comparison above covered both.
  let counts =
    "listed "
    <> int.to_string(tally.listed)
    <> ", scanned "
    <> int.to_string(tally.scanned)
  assert tally.listed >= 50 as { "too few listing-path removals: " <> counts }
  assert tally.scanned >= 50 as { "too few scanning-path removals: " <> counts }
}

pub fn replicas_converge_whatever_order_deltas_arrive_in_test() {
  list.each(history_seeds, fn(seed) {
    let label = "seed " <> int.to_string(seed)
    let world = run_history(seed)
    let deltas = pool_list(world)
    let forward = join_all(crdt.new(), deltas)
    let backward = join_all(crdt.new(), list.reverse(deltas))
    check_invariants(label <> " forward", forward)
    assert forward == backward as { label <> ": delta order changed the state" }
    // Every replica, given every delta in its own random order (late and
    // repeated ones included), reaches the same state.
    int.range(from: 0, to: replica_count, with: Nil, run: fn(_, slot) {
      let rng = Rng(seed * 31 + slot)
      let #(order, rng) = shuffle(deltas, rng)
      let #(again, _) = shuffle(deltas, rng)
      let node = node_at(world, slot)
      let reached = join_all(node.state, list.append(order, again))
      assert reached == forward
        as {
          label <> ": replica " <> int.to_string(slot) <> " did not converge"
        }
    })
  })
}

pub fn join_is_idempotent_test() {
  list.each(history_seeds, fn(seed) {
    let label = "seed " <> int.to_string(seed)
    let world = run_history(seed)
    let deltas = pool_list(world)
    let all = join_all(crdt.new(), deltas)
    list.each(deltas, fn(delta) {
      assert crdt.join(all, delta) == #(all, [])
        as { label <> ": a delta joined twice changed the state" }
    })
    list.each(dict.values(world.nodes), fn(node) {
      assert crdt.join_full(node.state, crdt.to_delta(node.state))
        == #(node.state, [])
        as { label <> ": a state joined with itself changed" }
    })
  })
}

pub fn join_full_is_commutative_and_associative_test() {
  list.each(history_seeds, fn(seed) {
    let label = "seed " <> int.to_string(seed)
    let world = run_history(seed)
    let x = node_at(world, 0).state
    let y = node_at(world, 1).state
    let z = node_at(world, 2).state
    let full = fn(a: State(Int), b: State(Int)) {
      crdt.join_full(a, crdt.to_delta(b)).0
    }
    assert full(x, y) == full(y, x) as { label <> ": x ⊔ y != y ⊔ x" }
    assert full(y, z) == full(z, y) as { label <> ": y ⊔ z != z ⊔ y" }
    assert full(full(x, y), z) == full(x, full(y, z))
      as { label <> ": (x ⊔ y) ⊔ z != x ⊔ (y ⊔ z)" }
    check_invariants(label, full(full(x, y), z))
  })
}

/// Deltas no write would make, against a state with long keys: contexts
/// with gaps, cloud dots the clock already covers, clocks of 0 or below,
/// keys the state does not have. The two ways of finding removed dots
/// must still agree with the oracle on every one.
pub fn arbitrary_delta_contexts_match_the_full_scan_oracle_test() {
  list.each(history_seeds, fn(seed) {
    let base = long_keys(seed)
    let #(last, _) =
      int.range(from: 0, to: 200, with: #(base, Rng(seed)), run: fn(acc, i) {
        let #(state, rng) = acc
        let label =
          "seed " <> int.to_string(seed) <> " delta " <> int.to_string(i)
        let #(delta, rng) = arbitrary_delta(rng)
        let joined =
          same_join(label, crdt.join(state, delta), oracle_join(state, delta))
        // Also as a full state, through join_full's path.
        check_same(
          label <> " as full",
          crdt.join_full(state, delta),
          oracle_join_full(state, delta),
        )
        // Keep the long keys long: restart from the base now and then.
        case i % 20 {
          19 -> #(base, rng)
          _ -> #(joined, rng)
        }
      })
    // The last delta of each seed (199) restarts from the base.
    assert last == base
  })
}

const arbitrary_replicas = [
  Replica(node: "a@host", incarnation: 1),
  Replica(node: "a@host", incarnation: 2),
  Replica(node: "b@host", incarnation: 1),
  Replica(node: "c@host", incarnation: 1),
]

fn pick_replica(rng: Rng) -> #(crdt.Replica, Rng) {
  let #(i, rng) = next(rng, list.length(arbitrary_replicas))
  let assert Ok(replica) = list.first(list.drop(arbitrary_replicas, i))
    as "i is below the list's length"
  #(replica, rng)
}

fn pick_dot(rng: Rng) -> #(Dot, Rng) {
  let #(replica, rng) = pick_replica(rng)
  let #(counter, rng) = next(rng, 40)
  #(Dot(replica:, counter: counter + 1), rng)
}

/// Every arbitrary replica appends 30 values to k0, 10 to k1 and 2 to k2,
/// joined into one state.
fn long_keys(seed: Int) -> State(Int) {
  list.fold(arbitrary_replicas, crdt.new(), fn(state, replica) {
    list.fold([#("k0", 30), #("k1", 10), #("k2", 2)], state, fn(state, spec) {
      let #(key, count) = spec
      let items =
        int.range(from: 0, to: count, with: [], run: fn(items, i) {
          [
            #(seed + i, Timestamp(wall_ms: i, logical: 0, node: replica.node)),
            ..items
          ]
        })
      let #(_, delta, _) = crdt.append(crdt.new(), replica, key, items, [])
      crdt.join(state, delta).0
    })
  })
}

fn arbitrary_delta(rng: Rng) -> #(Delta(Int), Rng) {
  let #(k, rng) = next(rng, key_count + 1)
  let key = "k" <> int.to_string(k)
  let #(entry_count, rng) = next(rng, 3)
  let #(dots, rng) = repeat_pick(entry_count, rng, pick_dot)
  let #(clock_count, rng) = next(rng, 4)
  let #(clock, rng) =
    repeat_pick(clock_count, rng, fn(rng) {
      let #(replica, rng) = pick_replica(rng)
      // -2..40: a clock of 0 or below covers nothing.
      let #(max, rng) = next(rng, 43)
      #(#(replica, max - 2), rng)
    })
  let #(cloud_count, rng) = next(rng, 5)
  let #(cloud, rng) = repeat_pick(cloud_count, rng, pick_dot)
  let entries =
    dots
    |> list.map(fn(dot) {
      #(dot, crdt.Entry(value: -1, ts: Timestamp(0, 0, "x"), topics: []))
    })
    |> dict.from_list
  // The delta's context holds its own dots, as every real delta's does;
  // nothing compacts it.
  let context =
    Context(
      clock: dict.from_list(clock),
      cloud: set.from_list(list.append(cloud, dots)),
    )
  #(
    Delta(entries: dict.from_list([#(key, entries)]), context:, topics: []),
    rng,
  )
}

fn repeat_pick(
  count: Int,
  rng: Rng,
  pick: fn(Rng) -> #(a, Rng),
) -> #(List(a), Rng) {
  int.range(from: 0, to: count, with: #([], rng), run: fn(acc, _) {
    let #(items, rng) = acc
    let #(item, rng) = pick(rng)
    #([item, ..items], rng)
  })
}

// --- Cost and malformed contexts ---------------------------------------

const ra = Replica(node: "a@host", incarnation: 1)

const rb = Replica(node: "b@host", incarnation: 1)

fn ts(wall: Int) -> hlc.Timestamp {
  Timestamp(wall_ms: wall, logical: 0, node: ra.node)
}

/// A list key holding values `0..count-1`, value `i` at dot `(ra, i + 1)`.
/// One append, so building it is linear whatever join is under test.
fn list_key(count: Int) -> State(Int) {
  let items =
    int.range(from: count - 1, to: -1, with: [], run: fn(items, i) {
      [#(i, ts(i)), ..items]
    })
  crdt.append(crdt.new(), ra, "room", items, []).0
}

@external(erlang, "brazier_crdt_test_ffi", "reductions")
fn reductions(run: fn() -> a) -> Int

/// PERF-7: appending used to rebuild the key's dots on every write (and
/// every receiving join), O(values already under the key). It must now
/// cost the same on a key of 10 values as on one of 10,000.
pub fn append_cost_does_not_grow_with_the_values_under_the_key_test() {
  let small = list_key(10)
  let large = list_key(10_000)
  let append = fn(state) {
    fn() { crdt.append(state, ra, "room", [#(-1, ts(20_000))], []) }
  }
  let small_cost = reductions(append(small))
  let large_cost = reductions(append(large))
  // The full scan cost about one reduction per value: ~10,000 here.
  assert large_cost < small_cost * 3 + 200
    as {
      "append on 10,000 values cost "
      <> int.to_string(large_cost)
      <> " reductions, on 10 values "
      <> int.to_string(small_cost)
    }
  // The same for the join on a node that has the 10,000 values: its own
  // delta and a concurrent one from another replica.
  let #(_, own, _) = append(large)()
  let #(_, remote, _) =
    crdt.append(crdt.new(), rb, "room", [#(-2, ts(20_000))], [])
  let peer = crdt.join_full(crdt.new(), crdt.to_delta(large)).0
  assert peer == large
  let join_cost = fn(state, delta) {
    reductions(fn() { crdt.join(state, delta) })
  }
  let small_join = join_cost(small, remote)
  assert join_cost(peer, own) < small_join * 3 + 200
    as "joining an append delta grows with the values under the key"
  assert join_cost(peer, remote) < small_join * 3 + 200
    as "joining a remote append delta grows with the values under the key"
  // And the result is still every value, in order.
  let #(appended, _, _) = append(large)()
  assert crdt.size(appended) == 10_001
  assert list.last(crdt.values(appended, "room")) == Ok(-1)
}

/// A peer's delta whose clock claims a billion dots, against a key of two
/// values: the join scans the two values instead of listing the clock.
pub fn a_huge_delta_clock_scans_the_small_key_instead_test() {
  let state = list_key(2)
  let delta =
    Delta(
      entries: dict.from_list([#("room", dict.new())]),
      context: Context(
        clock: dict.from_list([#(ra, 1_000_000_000)]),
        cloud: set.new(),
      ),
      topics: [],
    )
  let cost = reductions(fn() { crdt.join(state, delta) })
  assert cost < 10_000
    as { "the join cost " <> int.to_string(cost) <> " reductions" }
  let #(joined, changes) = crdt.join(state, delta)
  assert list.length(changes) == 2
  assert list.all(changes, fn(change) { change_kind(change) == 1 })
  assert crdt.values(joined, "room") == []
  assert crdt.size(joined) == 0
}

/// A context whose cloud repeats a dot its clock covers (one no compacted
/// context has) removes that dot once, on the listing path (20 values,
/// context of 6 dots).
pub fn an_uncompacted_context_removes_each_dot_once_test() {
  let state = list_key(20)
  let delta =
    Delta(
      entries: dict.from_list([#("room", dict.new())]),
      context: Context(
        clock: dict.from_list([#(ra, 5)]),
        cloud: set.from_list([Dot(ra, 3)]),
      ),
      topics: [],
    )
  let #(joined, changes) = crdt.join(state, delta)
  let removed =
    changes
    |> sorted_changes
    |> list.map(fn(change) { change.dot.counter })
  assert removed == [1, 2, 3, 4, 5]
  assert crdt.size(joined) == 15
  assert crdt.values(joined, "room")
    == [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
  check_same("uncompacted", #(joined, changes), oracle_join(state, delta))
}

/// A clock entry covers counters 1..n only. A malformed peer delta can
/// put a dot of counter 0 into a state; a later clock must then leave it
/// on both paths of the join (a key smaller and larger than the context),
/// or replicas holding different numbers of values would disagree.
pub fn a_clock_never_covers_counters_below_one_test() {
  let context = Context(clock: dict.from_list([#(rb, 5)]), cloud: set.new())
  assert !crdt.covers(context, Dot(rb, 0))
  assert !crdt.covers(context, Dot(rb, -3))
  assert crdt.covers(context, Dot(rb, 1))
  assert crdt.covers(context, Dot(rb, 5))
  assert !crdt.covers(context, Dot(rb, 6))
  let zero = Dot(rb, 0)
  let inject =
    Delta(
      entries: dict.from_list([
        #(
          "room",
          dict.from_list([#(zero, crdt.Entry(value: 0, ts: ts(0), topics: []))]),
        ),
      ]),
      context: Context(clock: dict.new(), cloud: set.from_list([zero])),
      topics: [],
    )
  let removal =
    Delta(
      entries: dict.from_list([#("room", dict.new())]),
      context: context,
      topics: [],
    )
  // 1 value plus the zero dot (scan: the context lists 5) and 10 values
  // plus it (listing).
  list.each([1, 10], fn(count) {
    let #(state, _) = crdt.join(list_key(count), inject)
    assert dict.has_key(crdt.key_dots(state, "room"), zero)
    let #(after, changes) = crdt.join(state, removal)
    assert changes == []
      as {
        "a clock removed the zero dot from "
        <> int.to_string(count)
        <> " values"
      }
    assert after.entries == state.entries
  })
}

// --- The oracle: the full-scan join before PERF-7, verbatim ------------

fn oracle_join(
  state: State(value),
  delta: Delta(value),
) -> #(State(value), List(Change(value))) {
  oracle_join_keys(
    state,
    delta.entries,
    delta.context,
    dict.keys(delta.entries),
  )
}

fn oracle_join_full(
  state: State(value),
  full: Delta(value),
) -> #(State(value), List(Change(value))) {
  let keys =
    set.union(
      set.from_list(dict.keys(state.entries)),
      set.from_list(dict.keys(full.entries)),
    )
    |> set.to_list
  oracle_join_keys(state, full.entries, full.context, keys)
}

fn oracle_join_keys(
  state: State(value),
  other: Dict(String, Dots(value)),
  other_context: Context,
  keys: List(String),
) -> #(State(value), List(Change(value))) {
  let #(entries, size, changes) =
    list.fold(keys, #(state.entries, state.size, []), fn(acc, key) {
      let #(entries, size, changes) = acc
      let mine = oracle_get_or_empty(entries, key)
      let theirs = oracle_get_or_empty(other, key)
      let #(kept, removed) =
        dict.fold(mine, #(dict.new(), []), fn(acc, dot, entry) {
          let #(kept, removed) = acc
          case dict.has_key(theirs, dot) || !oracle_covers(other_context, dot) {
            True -> #(dict.insert(kept, dot, entry), removed)
            False -> #(kept, [Removed(key:, dot:, entry:), ..removed])
          }
        })
      let #(joined, added) =
        dict.fold(theirs, #(kept, []), fn(acc, dot, entry) {
          let #(joined, added) = acc
          case dict.has_key(mine, dot) || oracle_covers(state.context, dot) {
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
  let context = oracle_union_context(state.context, other_context)
  #(State(entries:, context:, size:), list.reverse(changes))
}

fn oracle_get_or_empty(
  entries: Dict(String, Dots(value)),
  key: String,
) -> Dots(value) {
  case dict.get(entries, key) {
    Ok(dots) -> dots
    Error(Nil) -> dict.new()
  }
}

fn oracle_covers(context: Context, dot: Dot) -> Bool {
  case dict.get(context.clock, dot.replica) {
    Ok(max) if dot.counter <= max -> True
    Ok(_) | Error(Nil) -> set.contains(context.cloud, dot)
  }
}

fn oracle_union_context(a: Context, b: Context) -> Context {
  let clock = dict.combine(a.clock, b.clock, fn(x, y) { int.max(x, y) })
  oracle_compact(Context(clock: clock, cloud: set.union(a.cloud, b.cloud)))
}

fn oracle_compact(context: Context) -> Context {
  let sorted = list.sort(set.to_list(context.cloud), crdt.compare_dots)
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
