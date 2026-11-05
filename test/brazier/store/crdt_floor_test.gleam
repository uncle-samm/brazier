//// Floors of the causal context (brazier/store/crdt, "Floors"): what a
//// floor covers, what raising one drops and keeps, how a late write of an
//// earlier incarnation is treated, convergence and the join algebra over
//// random histories with restarts and floor raises, and the bound on the
//// context across a hundred restarts. crdt_test covers the join without
//// floors against its full-scan oracle.

import brazier/store/crdt.{type Delta, type State, Context, Delta, Dot, Replica}
import brazier/store/hlc.{Timestamp}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/set

const n1 = "n1@host"

const n2 = "n2@host"

fn ts(wall: Int, node: String) -> hlc.Timestamp {
  Timestamp(wall_ms: wall, logical: 0, node:)
}

fn put(
  state: State(Int),
  replica: crdt.Replica,
  key: String,
  value: Int,
) -> #(State(Int), Delta(Int)) {
  let #(state, delta, _changes) =
    crdt.put(state, replica, key, value, ts(value, replica.node), [])
  #(state, delta)
}

fn floors_only(node: String, incarnation: Int) -> crdt.Context {
  Context(
    clock: dict.new(),
    cloud: set.new(),
    floors: dict.from_list([#(node, incarnation)]),
  )
}

// --- Single cases --------------------------------------------------------

/// A floor covers every counter of every incarnation of its node below it,
/// and nothing of its own incarnation or of another node.
pub fn a_floor_covers_every_dot_of_older_incarnations_only_test() {
  let context = floors_only(n1, 10)
  assert crdt.covers(context, Dot(Replica(n1, 9), 1_000_000))
  assert crdt.covers(context, Dot(Replica(n1, 0), 1))
  assert !crdt.covers(context, Dot(Replica(n1, 10), 1))
  assert !crdt.covers(context, Dot(Replica(n1, 11), 1))
  assert !crdt.covers(context, Dot(Replica(n2, 9), 1))
}

const old = Replica(node: n1, incarnation: 1)

const current = Replica(node: n1, incarnation: 2)

const other = Replica(node: n2, incarnation: 1)

/// The state of a node that ran `old` and now runs `current`: a live value
/// and a removed one of `old`, a dot of `old` seen beyond a gap, a value of
/// `current` and one of another node.
fn restarted_state() -> State(Int) {
  let #(state, _) = put(crdt.new(), old, "kept", 1)
  let #(state, _) = put(state, old, "gone", 2)
  let #(state, _, _) = crdt.remove(state, "gone", [])
  let gap =
    Delta(
      entries: dict.new(),
      context: Context(
        clock: dict.new(),
        cloud: set.from_list([Dot(old, 9)]),
        floors: dict.new(),
      ),
      topics: [],
    )
  let #(state, _) = crdt.join(state, gap)
  let #(state, _) = put(state, current, "fresh", 3)
  let #(state, _) = put(state, other, "theirs", 4)
  state
}

/// Raising the floor drops the clock entry and the cloud dot of the older
/// incarnation, keeps its live value live and its removed value removed,
/// and keeps the digest equal to the recomputed one. The broadcast delta
/// carries only the floor.
pub fn raising_the_floor_drops_older_incarnations_and_keeps_live_values_test() {
  let state = restarted_state()
  assert dict.get(state.context.clock, old) == Ok(2)
  assert set.contains(state.context.cloud, Dot(old, 9))
  assert crdt.has_older_incarnation(state, current)
  assert !crdt.has_older_incarnation(state, old)
  // old's clock entry and cloud dot, current's and other's clock entries.
  assert crdt.context_size(state) == 4
  assert crdt.floor(state, n1) == 0

  let assert Ok(#(raised, delta)) = crdt.raise_floor(state, current)
    as "the node has no floor, so its incarnation 2 is above it"
  assert crdt.floor(raised, n1) == 2
  assert crdt.floor(raised, n2) == 0
  assert dict.get(raised.context.clock, old) == Error(Nil)
  assert !set.contains(raised.context.cloud, Dot(old, 9))
  // current's and other's clock entries and the floor.
  assert crdt.context_size(raised) == 3
  assert raised.entries == state.entries
  assert crdt.size(raised) == crdt.size(state)
  assert crdt.value(raised, "kept") == Ok(1)
  assert crdt.value(raised, "gone") == Error(Nil)
  assert crdt.value(raised, "fresh") == Ok(3)
  assert crdt.value(raised, "theirs") == Ok(4)
  assert crdt.digest(raised) == crdt.recompute_digest(raised)
  assert crdt.digest(raised) != crdt.digest(state)
  assert !crdt.has_older_incarnation(raised, current)

  assert delta.entries == dict.new()
  assert delta.context == floors_only(n1, 2)
  assert delta.topics == []
  // Another replica holding the same state ends up with the same one.
  assert crdt.join(state, delta) == #(raised, [])

  // Nothing to raise once the floor is there, or for an older incarnation.
  assert crdt.raise_floor(raised, current) == Error(Nil)
  assert crdt.raise_floor(raised, old) == Error(Nil)
  // A floor joined twice changes nothing.
  assert crdt.join(raised, delta) == #(raised, [])
}

/// A write of the older incarnation still in flight when the floor rose is
/// covered on arrival: its value is not added and its clock entry does not
/// come back.
pub fn a_late_write_of_an_older_incarnation_is_dropped_test() {
  let state = restarted_state()
  let #(_, late) = put(state, old, "late", 7)
  let assert Ok(#(raised, _)) = crdt.raise_floor(state, current)
    as "the node has no floor, so its incarnation 2 is above it"
  assert crdt.join(raised, late) == #(raised, [])
  assert crdt.value(raised, "late") == Error(Nil)
  assert dict.get(raised.context.clock, old) == Error(Nil)
}

/// A replica that held a value of the older incarnation the raiser never
/// saw (out of reach when the floor rose) loses it on the full sync, and
/// both converge on the raiser's state with the floor. A value of the
/// older incarnation both held stays.
pub fn a_full_sync_with_a_floor_converges_without_the_unseen_older_value_test() {
  let state = restarted_state()
  let #(unreachable, _) = put(state, old, "unseen", 8)
  // More values under one key than the raiser's context lists dots: the
  // floor covers them all the same.
  let items = [#(10, ts(10, n1)), #(11, ts(11, n1)), #(12, ts(12, n1))]
  let #(unreachable, _, _) = crdt.append(unreachable, old, "log", items, [])
  let assert Ok(#(raised, _)) = crdt.raise_floor(state, current)
    as "the node has no floor, so its incarnation 2 is above it"

  let #(received, changes) = crdt.join_full(unreachable, crdt.to_delta(raised))
  assert list.length(changes) == 4
  assert crdt.value(received, "unseen") == Error(Nil)
  assert crdt.values(received, "log") == []
  assert crdt.value(received, "kept") == Ok(1)
  assert crdt.floor(received, n1) == 2
  assert dict.get(received.context.clock, old) == Error(Nil)
  assert crdt.digest(received) == crdt.recompute_digest(received)

  let #(sent, changes) = crdt.join_full(raised, crdt.to_delta(unreachable))
  assert changes == []
  assert sent == raised
  assert received == raised
}

/// A hundred restarts of one node, each pulling its peer's state, writing,
/// and raising its floor once in sync: the context of both replicas stays
/// at most four elements (three after each raise), where without floors it
/// grows by one clock entry per restart.
pub fn a_hundred_restarts_keep_the_context_bounded_test() {
  let peer = Replica(n2, 1)
  let #(peer_state, _) = put(crdt.new(), peer, "peer", 0)

  let restart = fn(peer_state: State(Int), incarnation: Int, raise: Bool) {
    let me = Replica(n1, incarnation)
    let #(mine, _) = crdt.join_full(crdt.new(), crdt.to_delta(peer_state))
    let #(mine, delta) = put(mine, me, "mine", incarnation)
    let #(peer_state, _) = crdt.join(peer_state, delta)
    assert crdt.digest(mine) == crdt.digest(peer_state)
    let before = int.max(crdt.context_size(mine), crdt.context_size(peer_state))
    case raise && crdt.has_older_incarnation(mine, me) {
      False -> #(mine, peer_state, before)
      True -> {
        let assert Ok(#(mine, floor)) = crdt.raise_floor(mine, me)
          as "an older incarnation outside the floor means the floor is below this one"
        let #(peer_state, _) = crdt.join(peer_state, floor)
        assert mine == peer_state
        assert crdt.context_size(mine) == 3
        #(mine, peer_state, before)
      }
    }
  }

  let #(mine, peer_state, largest) =
    int.range(
      from: 1,
      to: 101,
      with: #(crdt.new(), peer_state, 0),
      run: fn(acc, incarnation) {
        let #(_, peer_state, largest) = acc
        let #(mine, peer_state, before) = restart(peer_state, incarnation, True)
        #(mine, peer_state, int.max(largest, before))
      },
    )
  assert largest <= 4
  assert crdt.context_size(mine) == 3
  assert crdt.context_size(peer_state) == 3
  assert crdt.floor(peer_state, n1) == 100
  assert crdt.value(mine, "mine") == Ok(100)
  assert crdt.value(peer_state, "mine") == Ok(100)
  assert crdt.value(peer_state, "peer") == Ok(0)

  // The same restarts without floors: one clock entry per incarnation.
  let #(unbounded, _) = put(crdt.new(), peer, "peer", 0)
  let unbounded =
    int.range(from: 1, to: 101, with: unbounded, run: fn(peer_state, i) {
      restart(peer_state, i, False).1
    })
  assert crdt.context_size(unbounded) == 101
}

// --- Random histories with restarts and floor raises ---------------------

const history_seeds = [
  3, 11, 58, 271, 1009, 4096, 31_415, 65_537, 524_287, 9_999_991,
]

const history_steps = 400

/// How far back a late delivery reaches into the pool.
const recent_deltas = 8

/// The ANSI C linear congruential generator, as in crdt_test.
type Rng {
  Rng(seed: Int)
}

fn next(rng: Rng, bound: Int) -> #(Int, Rng) {
  let seed = { rng.seed * 1_103_515_245 + 12_345 } % 2_147_483_648
  #({ seed / 65_536 } % bound, Rng(seed))
}

type Peer {
  Peer(replica: crdt.Replica, state: State(Int))
}

/// Three nodes and every delta any incarnation produced (newest first).
/// The tallies show the history did restart, raise and drop.
type Sim {
  Sim(
    peers: Dict(Int, Peer),
    pool: List(Delta(Int)),
    rng: Rng,
    restarts: Int,
    raises: Int,
    dropped: Int,
  )
}

fn new_sim(seed: Int) -> Sim {
  let peers =
    int.range(from: 0, to: 3, with: dict.new(), run: fn(peers, slot) {
      let replica = Replica(node: "n" <> int.to_string(slot), incarnation: 1)
      dict.insert(peers, slot, Peer(replica:, state: crdt.new()))
    })
  Sim(peers:, pool: [], rng: Rng(seed), restarts: 0, raises: 0, dropped: 0)
}

fn peer_at(sim: Sim, slot: Int) -> Peer {
  let assert Ok(peer) = dict.get(sim.peers, slot)
    as "a slot is always one of the three peers"
  peer
}

fn set_peer(sim: Sim, slot: Int, peer: Peer, label: String) -> Sim {
  check_invariants(label, peer.state)
  Sim(..sim, peers: dict.insert(sim.peers, slot, peer))
}

fn step(seed: Int, index: Int, sim: Sim) -> Sim {
  let label = "seed " <> int.to_string(seed) <> " step " <> int.to_string(index)
  let #(op, rng) = next(sim.rng, 10)
  let #(slot, rng) = next(rng, 3)
  let #(from, rng) = next(rng, 3)
  let #(key, rng) = next(rng, 3)
  let #(back, rng) = next(rng, recent_deltas)
  let sim = Sim(..sim, rng:)
  let peer = peer_at(sim, slot)
  let key = "k" <> int.to_string(key)
  case op {
    0 | 1 | 2 | 3 -> {
      let #(state, delta) = put(peer.state, peer.replica, key, index)
      let sim = Sim(..sim, pool: [delta, ..sim.pool])
      set_peer(sim, slot, Peer(..peer, state:), label <> " put")
    }
    4 -> {
      let #(state, delta, _) = crdt.remove(peer.state, key, [])
      let sim = Sim(..sim, pool: [delta, ..sim.pool])
      set_peer(sim, slot, Peer(..peer, state:), label <> " remove")
    }
    5 | 6 ->
      case list.first(list.drop(sim.pool, back)) {
        Ok(delta) -> {
          let #(state, _) = crdt.join(peer.state, delta)
          set_peer(sim, slot, Peer(..peer, state:), label <> " deliver")
        }
        Error(Nil) -> sim
      }
    7 -> {
      let full = crdt.to_delta(peer_at(sim, from).state)
      let #(state, _) = crdt.join_full(peer.state, full)
      set_peer(sim, slot, Peer(..peer, state:), label <> " sync")
    }
    8 -> {
      // A new incarnation starts empty and pulls one peer's state (none
      // when it picked itself: a restart with no peer reachable).
      let replica =
        Replica(..peer.replica, incarnation: peer.replica.incarnation + 1)
      let state = case from == slot {
        True -> crdt.new()
        False ->
          crdt.join_full(crdt.new(), crdt.to_delta(peer_at(sim, from).state)).0
      }
      let sim = Sim(..sim, restarts: sim.restarts + 1)
      set_peer(sim, slot, Peer(replica:, state:), label <> " restart")
    }
    _ ->
      case crdt.raise_floor(peer.state, peer.replica) {
        Ok(#(state, delta)) -> {
          let dropped = listed(peer.state) - listed(state)
          let sim =
            Sim(
              ..sim,
              pool: [delta, ..sim.pool],
              raises: sim.raises + 1,
              dropped: sim.dropped + dropped,
            )
          set_peer(sim, slot, Peer(..peer, state:), label <> " raise")
        }
        Error(Nil) -> sim
      }
  }
}

/// The clock entries and cloud dots of the state's context (its size
/// without the floors).
fn listed(state: State(Int)) -> Int {
  dict.size(state.context.clock) + set.size(state.context.cloud)
}

/// The digest is the recomputed one, the context is compacted, no clock
/// entry or cloud dot is under a floor, every live dot is in the context,
/// and the size is the number of live dots.
fn check_invariants(label: String, state: State(Int)) -> Nil {
  let context = state.context
  assert crdt.digest(state) == crdt.recompute_digest(state)
    as { label <> ": the kept digest differs from the recomputed one" }
  let under_floor = fn(replica: crdt.Replica) {
    case dict.get(context.floors, replica.node) {
      Ok(floor) -> replica.incarnation < floor
      Error(Nil) -> False
    }
  }
  dict.each(context.clock, fn(replica, _max) {
    assert !under_floor(replica)
      as { label <> ": a clock entry is under its node's floor" }
  })
  dict.each(context.floors, fn(_node, floor) {
    assert floor >= 1 as { label <> ": a floor below 1" }
  })
  set.fold(context.cloud, Nil, fn(_, dot) {
    assert !under_floor(dot.replica)
      as { label <> ": a cloud dot is under its node's floor" }
    let max = case dict.get(context.clock, dot.replica) {
      Ok(max) -> max
      Error(Nil) -> 0
    }
    assert dot.counter > max + 1
      as { label <> ": the context is not compacted" }
  })
  let live =
    dict.fold(state.entries, 0, fn(live, key, dots) {
      assert !dict.is_empty(dots) as { label <> ": " <> key <> " has no dots" }
      dict.fold(dots, live, fn(live, dot, _entry) {
        assert crdt.covers(context, dot)
          as { label <> ": a live dot of " <> key <> " is not in the context" }
        live + 1
      })
    })
  assert crdt.size(state) == live as { label <> ": the size is off" }
}

fn run(seed: Int) -> Sim {
  int.range(from: 0, to: history_steps, with: new_sim(seed), run: fn(sim, i) {
    step(seed, i, sim)
  })
}

fn states(sim: Sim) -> List(State(Int)) {
  [peer_at(sim, 0).state, peer_at(sim, 1).state, peer_at(sim, 2).state]
}

fn full(a: State(Int), b: State(Int)) -> State(Int) {
  crdt.join_full(a, crdt.to_delta(b)).0
}

/// Two rounds of every replica joining every other's full state.
fn sync_all(label: String, states: List(State(Int))) -> List(State(Int)) {
  let round = fn(states: List(State(Int))) {
    list.map(states, fn(state) {
      let joined = list.fold(states, state, full)
      check_invariants(label <> " sync", joined)
      joined
    })
  }
  let synced = round(round(states))
  let assert [first, ..rest] = synced as "three replicas"
  list.each(rest, fn(state) {
    assert state == first as { label <> ": a full-mesh sync did not converge" }
  })
  synced
}

pub fn histories_with_restarts_and_floors_converge_test() {
  let totals =
    list.fold(history_seeds, #(0, 0, 0), fn(totals, seed) {
      let label = "seed " <> int.to_string(seed)
      let sim = run(seed)
      let converged = sync_all(label, states(sim))
      // Every delta of the history, late, in a different order on each
      // replica, then a sync: still one state.
      let deltas = list.reverse(sim.pool)
      let late =
        list.index_map(converged, fn(state, i) {
          let order = list.append(list.drop(deltas, i), list.take(deltas, i))
          list.fold(order, state, fn(state, delta) { crdt.join(state, delta).0 })
        })
      let _ = sync_all(label <> " late", late)
      #(totals.0 + sim.restarts, totals.1 + sim.raises, totals.2 + sim.dropped)
    })
  assert totals.0 >= 50 as "too few restarts"
  assert totals.1 >= 50 as "too few floor raises"
  assert totals.2 >= 50 as "too few context elements dropped by a raise"
}

pub fn the_join_with_floors_is_commutative_associative_and_idempotent_test() {
  list.each(history_seeds, fn(seed) {
    let label = "seed " <> int.to_string(seed)
    let sim = run(seed)
    let assert [x, y, z] = states(sim) as "three replicas"
    assert full(x, y) == full(y, x) as { label <> ": x ⊔ y != y ⊔ x" }
    assert full(y, z) == full(z, y) as { label <> ": y ⊔ z != z ⊔ y" }
    assert full(full(x, y), z) == full(x, full(y, z))
      as { label <> ": (x ⊔ y) ⊔ z != x ⊔ (y ⊔ z)" }
    list.each([x, y, z], fn(state) {
      assert crdt.join_full(state, crdt.to_delta(state)) == #(state, [])
        as { label <> ": a state joined with itself changed" }
    })
    list.each(sim.pool, fn(delta) {
      let #(once, _) = crdt.join(x, delta)
      assert crdt.join(once, delta) == #(once, [])
        as { label <> ": a delta joined twice changed the state" }
    })
  })
}
