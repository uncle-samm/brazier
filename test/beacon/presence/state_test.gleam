//// Tests for the presence CRDT, its clocks and delta generations. The state
//// scenarios port Phoenix.Tracker.StateTest: replicas are strings and every
//// "node" is a pure state, so transfers are passed by hand.

import beacon/presence/clock
import beacon/presence/delta_generation
import beacon/presence/state.{
  type Element, type State, DeltaTransfer, Down, NotContiguous, SnapshotTransfer,
  Tag, Up,
}
import gleam/dict
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/set
import gleam/string

// --- Helpers ----------------------------------------------------------------

fn new_pid() -> Pid {
  process.spawn_unlinked(fn() { Nil })
}

/// States for `names`, each marking the others up (Phoenix:
/// `given_connected_cluster`).
fn cluster(names: List(String)) -> List(State(String, String)) {
  list.map(names, fn(name) {
    list.fold(names, state.new(name), fn(acc, other) {
      case other == name {
        True -> acc
        False -> {
          let #(acc, _, _) = state.replica_up(acc, other)
          acc
        }
      }
    })
  })
}

fn join(
  s: State(String, String),
  pid: Pid,
  topic: String,
  key: String,
  meta: String,
) -> State(String, String) {
  let assert Ok(#(s, _)) = state.join(s, pid, topic, key, meta)
  s
}

/// A snapshot of `from` for `to`, merged into `to`.
fn sync(
  to: State(String, String),
  from: State(String, String),
) -> #(State(String, String), List(String), List(String)) {
  let #(_, context) = state.clocks(to)
  let snapshot = state.extract(from, state.replica(to), context)
  let #(to, joins, leaves) = state.merge(to, SnapshotTransfer(snapshot))
  #(to, keys(joins), keys(leaves))
}

/// `from`'s delta merged into `to`.
fn sync_delta(
  to: State(String, String),
  from: State(String, String),
) -> #(State(String, String), List(String), List(String)) {
  let #(to, joins, leaves) = state.merge(to, DeltaTransfer(state.delta(from)))
  #(to, keys(joins), keys(leaves))
}

fn keys(elements: List(Element(String, String))) -> List(String) {
  elements
  |> list.map(fn(e) { e.key.key <> "=" <> e.meta })
  |> list.sort(string.compare)
}

fn topic_keys(s: State(String, String), topic: String) -> List(String) {
  keys(state.get_by_topic(s, topic))
}

fn ctx(pairs: List(#(String, Int))) -> clock.Clock(String) {
  dict.from_list(pairs)
}

fn sorted_clouds(clouds: dict.Dict(String, set.Set(Int))) -> List(String) {
  clouds
  |> dict.to_list
  |> list.flat_map(fn(pair) {
    set.to_list(pair.1)
    |> list.map(fn(clock) { pair.0 <> ":" <> string.inspect(clock) })
  })
  |> list.sort(string.compare)
}

// --- State: Phoenix scenarios -----------------------------------------------

pub fn new_state_test() {
  let s: State(String, String) = state.new("s1")
  assert state.replica(s) == "s1"
  assert state.context(s) == ctx([#("s1", 0)])
  assert dict.is_empty(state.clouds(s))
  assert state.size(s) == 0
  assert !state.has_delta(s)
  assert state.replica_status(s, "s1") == Ok(Up)
}

pub fn join_and_leave_test() {
  let s = state.new("s1")
  let pid = new_pid()
  let assert Ok(#(s, joined)) = state.join(s, pid, "lobby", "alice", "m1")
  assert joined.tag == Tag("s1", 1)
  assert topic_keys(s, "lobby") == ["alice=m1"]
  // Tracking the same key twice is refused.
  assert state.join(s, pid, "lobby", "alice", "m2") == Error(Nil)
  let assert Ok(#(s, left)) = state.leave(s, pid, "lobby", "alice")
  assert left == joined
  assert topic_keys(s, "lobby") == []
  assert state.leave(s, pid, "lobby", "alice") == Error(Nil)
  // A join and a leave are two clock bumps.
  assert state.context(s) == ctx([#("s1", 2)])
  assert state.pid_entry_count(s, pid) == 0
}

pub fn merge_from_other_replicas_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let s1 = join(s1, new_pid(), "lobby", "alice", "a")
  let bob = new_pid()
  let s2 = join(s2, bob, "lobby", "bob", "b")

  let #(s1, joins, leaves) = sync(s1, s2)
  assert joins == ["bob=b"]
  assert leaves == []
  assert topic_keys(s1, "lobby") == ["alice=a", "bob=b"]

  // Merging the same state again reports nothing.
  let #(s1, joins, leaves) = sync(s1, s2)
  assert joins == []
  assert leaves == []

  let assert Ok(#(s2, _)) = state.leave(s2, bob, "lobby", "bob")
  let #(s1, joins, leaves) = sync(s1, s2)
  assert joins == []
  assert leaves == ["bob=b"]
  assert topic_keys(s1, "lobby") == ["alice=a"]
  assert state.context(s1) == ctx([#("s1", 1), #("s2", 2)])
}

pub fn basic_netsplit_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let s1 = join(s1, new_pid(), "lobby", "alice", "a")
  let s2 = join(s2, new_pid(), "lobby", "bob", "b")
  let #(s1, _, _) = sync(s1, s2)

  let #(s1, joins, leaves) = state.replica_down(s1, "s2")
  assert keys(joins) == []
  assert keys(leaves) == ["bob=b"]
  assert topic_keys(s1, "lobby") == ["alice=a"]
  assert state.replica_status(s1, "s2") == Ok(Down)
  // Down replicas are left out of the clocks.
  assert state.clocks(s1) == #("s1", ctx([#("s1", 1)]))

  // A snapshot asked for while s2 is down leaves s2 out entirely.
  let s2 = join(state.reset_delta(s2), new_pid(), "lobby", "carol", "c")
  let #(s1, joins, _) = sync(s1, s2)
  assert joins == []
  // A delta is merged but stays hidden; it does not bring bob back either.
  let #(s1, joins, _) = sync_delta(s1, s2)
  assert joins == ["carol=c"]
  assert topic_keys(s1, "lobby") == ["alice=a"]

  let #(s1, joins, leaves) = state.replica_up(s1, "s2")
  assert keys(joins) == ["bob=b", "carol=c"]
  assert keys(leaves) == []
  assert topic_keys(s1, "lobby") == ["alice=a", "bob=b", "carol=c"]
}

pub fn joins_observed_via_another_replica_test() {
  let assert [s1, s2, s3] = cluster(["s1", "s2", "s3"])
  let s1 = join(s1, new_pid(), "lobby", "alice", "a")
  let #(s2, joins, _) = sync(s2, s1)
  assert joins == ["alice=a"]
  // s3 never hears from s1 but learns alice through s2.
  let #(s3, joins, _) = sync(s3, s2)
  assert joins == ["alice=a"]
  assert topic_keys(s3, "lobby") == ["alice=a"]
}

pub fn removes_observed_via_another_replica_test() {
  let assert [s1, s2, s3] = cluster(["s1", "s2", "s3"])
  let alice = new_pid()
  let s1 = join(s1, alice, "lobby", "alice", "a")
  let #(s2, _, _) = sync(s2, s1)
  let #(s3, _, _) = sync(s3, s2)

  let assert Ok(#(s1, _)) = state.leave(s1, alice, "lobby", "alice")
  let #(s2, _, leaves) = sync(s2, s1)
  assert leaves == ["alice=a"]
  let #(s3, _, leaves) = sync(s3, s2)
  assert leaves == ["alice=a"]
  assert topic_keys(s3, "lobby") == []
}

pub fn get_by_pid_test() {
  let s = state.new("s1")
  let pid = new_pid()
  let other = new_pid()
  let s = join(s, pid, "lobby", "a", "1")
  let s = join(s, pid, "room", "b", "2")
  let s = join(s, other, "lobby", "c", "3")
  assert keys(state.get_by_pid(s, pid)) == ["a=1", "b=2"]
  assert state.pid_entry_count(s, pid) == 2
  let assert Ok(found) = state.get_by_pid_key(s, pid, "room", "b")
  assert found.meta == "2"
  assert state.get_by_pid_key(s, pid, "room", "a") == Error(Nil)
  assert state.get_by_pid(s, new_pid()) == []
}

pub fn get_by_key_hides_down_replicas_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let s1 = join(s1, new_pid(), "lobby", "u1", "tab1")
  let s1 = join(s1, new_pid(), "lobby", "u2", "x")
  let s2 = join(s2, new_pid(), "lobby", "u1", "tab2")
  let s2 = join(s2, new_pid(), "other", "u1", "y")
  let #(s1, _, _) = sync(s1, s2)
  assert keys(state.get_by_key(s1, "lobby", "u1")) == ["u1=tab1", "u1=tab2"]
  assert keys(state.online_list(s1)) == ["u1=tab1", "u1=tab2", "u1=y", "u2=x"]

  let #(s1, _, _) = state.replica_down(s1, "s2")
  assert keys(state.get_by_key(s1, "lobby", "u1")) == ["u1=tab1"]
  assert topic_keys(s1, "lobby") == ["u1=tab1", "u2=x"]
  assert topic_keys(s1, "other") == []
}

pub fn remove_down_replicas_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let s1 = join(s1, new_pid(), "lobby", "alice", "a")
  let s2 = join(s2, new_pid(), "lobby", "bob", "b")
  let #(s1, _, _) = sync(s1, s2)
  let #(s1, _, _) = state.replica_down(s1, "s2")
  let s1 = state.remove_down_replicas(s1, "s2")
  assert state.size(s1) == 1
  assert state.context(s1) == ctx([#("s1", 1)])
  assert state.replica_status(s1, "s2") == Error(Nil)
  // A forgotten replica's entries are not taken from later transfers.
  let #(s1, joins, _) = sync(s1, s2)
  assert joins == []
  assert topic_keys(s1, "lobby") == ["alice=a"]
}

pub fn removing_own_replica_crashes_test() {
  let s: State(String, String) = state.new("s1")
  assert raises(fn() { state.remove_down_replicas(s, "s1") })
}

pub fn leave_join_reports_both_sides_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let pid = new_pid()
  let s1 = join(s1, pid, "lobby", "alice", "v1")
  let #(s2, _, _) = sync(s2, s1)

  let s1 = state.reset_delta(s1)
  let assert Ok(#(s1, previous, current)) =
    state.leave_join(s1, pid, "lobby", "alice", "v2")
  assert previous.meta == "v1"
  assert current.meta == "v2"
  assert current.tag == Tag("s1", 3)
  assert topic_keys(s1, "lobby") == ["alice=v2"]
  assert state.leave_join(s1, new_pid(), "lobby", "alice", "v3") == Error(Nil)

  let #(s2, joins, leaves) = sync_delta(s2, s1)
  assert joins == ["alice=v2"]
  assert leaves == ["alice=v1"]
  assert topic_keys(s2, "lobby") == ["alice=v2"]
  assert state.context(s2) == ctx([#("s1", 3), #("s2", 0)])
}

pub fn leave_pid_removes_every_entry_test() {
  let s = state.new("s1")
  let pid = new_pid()
  let s = join(s, pid, "a", "k", "1")
  let s = join(s, pid, "b", "k", "2")
  let s = join(s, new_pid(), "a", "j", "3")
  let #(s, left) = state.leave_pid(s, pid)
  assert keys(left) == ["k=1", "k=2"]
  assert keys(state.online_list(s)) == ["j=3"]
  let #(_, left) = state.leave_pid(s, pid)
  assert left == []
}

/// Deltas that arrive out of order wait in the clouds until the gap fills,
/// then compact into the context.
pub fn clocks_and_compaction_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let s1 = join(s1, new_pid(), "lobby", "x1", "1")
  let d1 = state.delta(s1)
  let s1 = join(state.reset_delta(s1), new_pid(), "lobby", "x2", "2")
  let d2 = state.delta(s1)
  let s1 = join(state.reset_delta(s1), new_pid(), "lobby", "x3", "3")
  let d3 = state.delta(s1)

  let #(s2, _, _) = state.merge(s2, DeltaTransfer(d1))
  assert state.clocks(s2) == #("s2", ctx([#("s1", 1), #("s2", 0)]))
  assert dict.is_empty(state.clouds(s2))

  let #(s2, joins, _) = state.merge(s2, DeltaTransfer(d3))
  assert keys(joins) == ["x3=3"]
  assert state.context(s2) == ctx([#("s1", 1), #("s2", 0)])
  assert sorted_clouds(state.clouds(s2)) == ["s1:3"]
  // s2 is behind s1, so it would ask s1 for a transfer.
  assert !clock.dominates(state.context(s2), state.context(s1))

  let #(s2, joins, _) = state.merge(s2, DeltaTransfer(d2))
  assert keys(joins) == ["x2=2"]
  assert state.context(s2) == ctx([#("s1", 3), #("s2", 0)])
  assert dict.is_empty(state.clouds(s2))
  assert topic_keys(s2, "lobby") == ["x1=1", "x2=2", "x3=3"]
}

pub fn has_delta_and_reset_test() {
  let s = join(state.new("s1"), new_pid(), "lobby", "a", "1")
  assert state.has_delta(s)
  assert state.delta_size(state.delta(s)) == 2
  let s = state.reset_delta(s)
  assert !state.has_delta(s)
  let d = state.delta(s)
  assert d.range_start == ctx([#("s1", 1)])
  assert d.range_end == ctx([#("s1", 1)])
}

pub fn merge_deltas_not_contiguous_test() {
  let s = join(state.new("s1"), new_pid(), "lobby", "a", "1")
  let d1 = state.delta(s)
  let s = join(state.reset_delta(s), new_pid(), "lobby", "b", "2")
  let s = join(state.reset_delta(s), new_pid(), "lobby", "c", "3")
  let d3 = state.delta(s)
  assert state.merge_deltas(d1, d3) == Error(NotContiguous)
  assert state.merge_deltas(d3, d1) == Error(NotContiguous)
}

pub fn extract_restricts_to_known_replicas_test() {
  let assert [s1, s2, s3] = cluster(["s1", "s2", "s3"])
  let s1 = join(s1, new_pid(), "lobby", "a", "1")
  let s2 = join(s2, new_pid(), "lobby", "b", "2")
  let s3 = join(s3, new_pid(), "lobby", "c", "3")
  let #(s1, _, _) = sync(s1, s2)
  let #(s1, _, _) = sync(s1, s3)
  // The requester knows only s1 and itself.
  let snapshot = state.extract(s1, "s2", ctx([#("s1", 0), #("s2", 1)]))
  assert snapshot.context == ctx([#("s1", 1), #("s2", 1)])
  assert dict.keys(snapshot.values) == [Tag("s1", 1)]
}

pub fn merging_deltas_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let s1 = join(s1, new_pid(), "lobby", "a", "1")
  let s1 = join(s1, new_pid(), "lobby", "b", "2")
  let s2 = join(s2, new_pid(), "lobby", "c", "3")
  let s2 = join(s2, new_pid(), "lobby", "d", "4")
  let assert Ok(merged) = state.merge_deltas(state.delta(s1), state.delta(s2))
  assert dict.size(merged.values) == 4
  assert merged.range_start == ctx([#("s1", 0), #("s2", 0)])
  assert merged.range_end == ctx([#("s1", 2), #("s2", 2)])
}

pub fn merging_deltas_with_removes_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let s1 = join(s1, new_pid(), "lobby", "a", "1")
  let s1 = join(s1, new_pid(), "lobby", "b", "2")
  let pid = new_pid()
  let s2 = join(s2, pid, "lobby", "c", "3")
  let assert Ok(#(s2, _)) = state.leave(s2, pid, "lobby", "c")
  let assert Ok(merged) = state.merge_deltas(state.delta(s1), state.delta(s2))
  assert list.sort(dict.keys(merged.values), fn(a, b) {
      string.compare(string.inspect(a), string.inspect(b))
    })
    == [Tag("s1", 1), Tag("s1", 2)]
  assert sorted_clouds(merged.clouds) == ["s1:1", "s1:2", "s2:1", "s2:2"]
  // Merging the same delta again changes nothing.
  assert state.merge_deltas(merged, state.delta(s2)) == Ok(merged)
}

/// A generation that holds a value is cleared of it by a later delta that
/// removes it.
pub fn merging_a_later_remove_drops_the_value_test() {
  let s = state.new("s1")
  let pid = new_pid()
  let s = join(s, pid, "lobby", "a", "1")
  let first = state.delta(s)
  let assert Ok(#(s, _)) = state.leave(state.reset_delta(s), pid, "lobby", "a")
  let assert Ok(merged) = state.merge_deltas(first, state.delta(s))
  assert dict.is_empty(merged.values)
  assert sorted_clouds(merged.clouds) == ["s1:1", "s1:2"]
  assert merged.range_start == ctx([#("s1", 0)])
  assert merged.range_end == ctx([#("s1", 2)])
}

/// A remove merged from a peer is recorded in this replica's delta, so it
/// keeps spreading.
pub fn observed_removes_enter_the_delta_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let pid = new_pid()
  let s1 = join(s1, pid, "lobby", "a", "1")
  let #(s2, _, _) = sync(s2, s1)
  let s2 = state.reset_delta(s2)
  let assert Ok(#(s1, _)) = state.leave(s1, pid, "lobby", "a")
  let #(s2, _, leaves) = sync(s2, s1)
  assert leaves == ["a=1"]
  assert state.has_delta(s2)
  assert sorted_clouds(state.delta(s2).clouds) == ["s1:1"]
}

/// A delta and a snapshot carrying the same change give the same result.
pub fn delta_and_snapshot_merges_agree_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let pid = new_pid()
  let s1 = join(s1, pid, "lobby", "a", "1")
  let s1 = join(s1, new_pid(), "lobby", "b", "2")
  let #(s2, _, _) = sync(s2, s1)
  let s1 = state.reset_delta(s1)
  let assert Ok(#(s1, _)) = state.leave(s1, pid, "lobby", "a")
  let s1 = join(s1, new_pid(), "lobby", "c", "3")

  let #(by_delta, joins_d, leaves_d) = sync_delta(s2, s1)
  let #(by_snapshot, joins_s, leaves_s) = sync(s2, s1)
  assert joins_d == joins_s
  assert leaves_d == leaves_s
  assert joins_d == ["c=3"]
  assert leaves_d == ["a=1"]
  assert topic_keys(by_delta, "lobby") == topic_keys(by_snapshot, "lobby")
  assert state.context(by_delta) == state.context(by_snapshot)
}

/// Another replica's transfer never removes or duplicates this replica's
/// own entries.
pub fn own_entries_are_authoritative_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let s1 = join(s1, new_pid(), "lobby", "a", "1")
  let #(s2, _, _) = sync(s2, s1)
  let s2 = state.remove_down_replicas(s2, "s1")
  let #(s1, joins, leaves) = sync(s1, s2)
  assert joins == []
  assert leaves == []
  assert topic_keys(s1, "lobby") == ["a=1"]
}

/// Entries from a replica this state has never seen are not merged.
pub fn unknown_replicas_are_ignored_test() {
  let s1 = state.new("s1")
  let s2 = join(state.new("s2"), new_pid(), "lobby", "b", "2")
  let #(s1, joins, _) = sync_delta(s1, s2)
  assert joins == []
  assert state.size(s1) == 0
  assert state.context(s1) == ctx([#("s1", 0)])
}

// --- Clocks -----------------------------------------------------------------

pub fn dominates_test() {
  assert clock.dominates(ctx([#("a", 2), #("b", 1)]), ctx([#("a", 1)]))
  assert clock.dominates(ctx([#("a", 1)]), ctx([#("a", 1)]))
  assert !clock.dominates(ctx([#("a", 1)]), ctx([#("a", 2)]))
  assert !clock.dominates(ctx([#("a", 5)]), ctx([#("a", 1), #("b", 0)]))
  // A replica missing from the first clock is not dominated, even at 0.
  assert !clock.dominates(
    ctx([#("a", 1), #("b", 0)]),
    ctx([#("a", 1), #("c", 0)]),
  )
  assert clock.dominates(ctx([]), ctx([]))
}

pub fn dominates_or_equal_test() {
  assert clock.dominates_or_equal(ctx([]), ctx([]))
  assert !clock.dominates_or_equal(ctx([]), ctx([#("a", 1)]))
  assert clock.dominates_or_equal(ctx([#("a", 1)]), ctx([#("a", 1)]))
  assert !clock.dominates_or_equal(ctx([#("a", 1)]), ctx([#("a", 2)]))
  // Only the first clock's replicas are compared.
  assert clock.dominates_or_equal(ctx([#("a", 1)]), ctx([#("b", 5)]))
}

pub fn bounds_test() {
  let c1 = ctx([#("a", 1), #("b", 5)])
  let c2 = ctx([#("a", 3), #("c", 2)])
  assert clock.upperbound(c1, c2) == ctx([#("a", 3), #("b", 5), #("c", 2)])
  assert clock.lowerbound(c1, c2) == ctx([#("a", 1), #("b", 5), #("c", 2)])
  assert clock.filter_replicas(c1, ["a"]) == ctx([#("a", 1)])
  assert list.sort(clock.replicas(c1), string.compare) == ["a", "b"]
}

pub fn append_clock_test() {
  let set0 = clock.append_clock([], #("n1", ctx([#("a", 1)])))
  assert set0 == [#("n1", ctx([#("a", 1)]))]
  // A dominating clock replaces the set.
  let set1 = clock.append_clock(set0, #("n2", ctx([#("a", 2)])))
  assert set1 == [#("n2", ctx([#("a", 2)]))]
  // A dominated clock is dropped.
  assert clock.append_clock(set1, #("n3", ctx([#("a", 1)]))) == set1
  // An empty clock is a no-op.
  assert clock.append_clock(set1, #("n4", ctx([]))) == set1
  // A concurrent clock joins the set.
  let set2 = clock.append_clock(set1, #("n5", ctx([#("b", 1)])))
  assert clock.clockset_replicas(set2) == set.from_list(["n2", "n5"])
  // A clock that dominates one member but not the other replaces only it.
  let set3 = clock.append_clock(set2, #("n6", ctx([#("a", 3), #("c", 1)])))
  assert clock.clockset_replicas(set3) == set.from_list(["n5", "n6"])
}

// --- Delta generations ------------------------------------------------------

pub fn push_seeds_and_bounds_generations_test() {
  let s = join(state.new("s1"), new_pid(), "lobby", "a", "1")
  let d1 = state.delta(s)
  let s = state.reset_delta(s)
  let gens = delta_generation.push(s, [], d1, [2, 10])
  assert list.length(gens) == 2
  assert list.all(gens, fn(g) { dict.size(g.values) == 1 })

  let s = join(s, new_pid(), "lobby", "b", "2")
  let d2 = state.delta(s)
  let s = state.reset_delta(s)
  let assert [small, large] = delta_generation.push(s, gens, d2, [2, 10])
  // Merging into the small generation would exceed 2, so it restarts.
  assert small == d2
  assert dict.size(large.values) == 2
  assert large.range_start == ctx([#("s1", 0)])
  assert large.range_end == ctx([#("s1", 2)])
}

pub fn push_keeps_generations_it_cannot_continue_test() {
  let s = join(state.new("s1"), new_pid(), "lobby", "a", "1")
  let d1 = state.delta(s)
  let s = join(state.reset_delta(s), new_pid(), "lobby", "b", "2")
  let s = join(state.reset_delta(s), new_pid(), "lobby", "c", "3")
  let d3 = state.delta(s)
  let gens = delta_generation.push(s, [d1], d3, [10])
  assert gens == [d1]
}

pub fn extract_picks_the_smallest_covering_generation_test() {
  let s = join(state.new("s1"), new_pid(), "lobby", "a", "1")
  let gens =
    delta_generation.push(state.reset_delta(s), [], state.delta(s), [2, 10])
  let s = state.reset_delta(s)
  let s = join(s, new_pid(), "lobby", "b", "2")
  let gens =
    delta_generation.push(state.reset_delta(s), gens, state.delta(s), [2, 10])
  let s = state.reset_delta(s)

  // One clock behind: the small generation covers the gap.
  let assert DeltaTransfer(d) =
    delta_generation.extract(s, gens, "s2", ctx([#("s1", 1), #("s2", 0)]))
  assert dict.keys(d.values) == [Tag("s1", 2)]
  // Two behind: only the large one does.
  let assert DeltaTransfer(d) =
    delta_generation.extract(s, gens, "s2", ctx([#("s1", 0), #("s2", 0)]))
  assert dict.size(d.values) == 2
  // A peer that has never seen s1 cannot use a delta.
  let assert SnapshotTransfer(snapshot) =
    delta_generation.extract(s, gens, "s2", ctx([#("s2", 0)]))
  assert dict.is_empty(snapshot.values)
  // No generations: always a snapshot.
  let assert SnapshotTransfer(snapshot) =
    delta_generation.extract(s, [], "s2", ctx([#("s1", 0), #("s2", 0)]))
  assert dict.size(snapshot.values) == 2
}

pub fn generations_drop_down_replicas_test() {
  let assert [s1, s2] = cluster(["s1", "s2"])
  let s2 = join(s2, new_pid(), "lobby", "b", "2")
  let gens = delta_generation.push(s1, [], state.delta(s2), [10])
  let assert [g] = delta_generation.remove_down_replicas(gens, "s2")
  assert dict.is_empty(g.values)
  assert !dict.has_key(g.range_end, "s2")
  assert !dict.has_key(g.clouds, "s2")
}

@external(erlang, "beacon_session_test_ffi", "raises")
fn raises(run: fn() -> a) -> Bool
