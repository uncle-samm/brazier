//// The presence CRDT, ported from Phoenix.Tracker.State.
////
//// An observed-remove set of `(topic, pid, key) -> meta` entries with a
//// causal context. Every local change bumps this replica's clock and tags
//// the entry with `#(replica, clock)`. Removes leave no tombstone: a peer
//// infers one when a tag it holds is covered by the sender's context or
//// clouds but absent from the sender's values. Clouds hold tags seen out of
//// order; `compact` folds contiguous ones into the context.
////
//// Every change is also recorded in the delta, which the shard broadcasts
//// on its next heartbeat and then resets. A peer whose clock falls behind
//// asks for a transfer and gets a delta generation or a snapshot (see
//// `brazier/presence/delta_generation`).
////
//// This module is pure. `brazier_presence_shard` owns one state per shard
//// and mirrors the visible entries into ETS for reads; the read functions
//// here scan every value and exist for tests and introspection.
////
//// Differences from Phoenix, none of which change the merge results:
//// - values are keyed by tag, with indices from `(topic, pid, key)` to tag
////   and from pid to keys for this replica's own entries only (the API
////   tracks only processes on the tracking node);
//// - a delta merge finds removes by walking the delta's clouds instead of
////   every local value, so a heartbeat costs the size of the delta;
//// - a cloud holds clock values, not whole tags.

import brazier/presence/clock.{type Clock}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/set.{type Set}

/// A unique event id: the replica that made the change and its clock value.
pub type Tag(r) {
  Tag(replica: r, clock: Int)
}

/// What is tracked. A pid can track several keys per topic.
pub type Key {
  Key(topic: String, pid: Pid, key: String)
}

/// One tracked entry, as returned in joins, leaves and reads.
pub type Element(r, m) {
  Element(key: Key, meta: m, tag: Tag(r))
}

pub type ReplicaStatus {
  Up
  Down
}

/// The changes since the last reset, covering clocks `range_start` to
/// `range_end` (exclusive start, inclusive end). Phoenix keeps this as a
/// State in `:delta` mode.
pub type Delta(r, m) {
  Delta(
    values: Dict(Tag(r), #(Key, m)),
    clouds: Dict(r, Set(Int)),
    range_start: Clock(r),
    range_end: Clock(r),
  )
}

/// A full state extracted for one peer.
pub type Snapshot(r, m) {
  Snapshot(
    context: Clock(r),
    clouds: Dict(r, Set(Int)),
    values: Dict(Tag(r), #(Key, m)),
  )
}

pub type Transfer(r, m) {
  DeltaTransfer(Delta(r, m))
  SnapshotTransfer(Snapshot(r, m))
}

pub type DeltaError {
  /// The two deltas leave a gap between their ranges.
  NotContiguous
}

pub opaque type State(r, m) {
  State(
    replica: r,
    context: Clock(r),
    clouds: Dict(r, Set(Int)),
    values: Dict(Tag(r), #(Key, m)),
    /// This replica's entries by key.
    local: Dict(Key, Tag(r)),
    /// This replica's keys by pid.
    pids: Dict(Pid, Set(Key)),
    replicas: Dict(r, ReplicaStatus),
    delta: Delta(r, m),
  )
}

// --- Construction and accessors ---------------------------------------------

pub fn new(replica: r) -> State(r, m) {
  let context = dict.from_list([#(replica, 0)])
  State(
    replica:,
    context:,
    clouds: dict.new(),
    values: dict.new(),
    local: dict.new(),
    pids: dict.new(),
    replicas: dict.from_list([#(replica, Up)]),
    delta: empty_delta(replica, context),
  )
}

pub fn replica(state: State(r, m)) -> r {
  state.replica
}

pub fn context(state: State(r, m)) -> Clock(r) {
  state.context
}

pub fn clouds(state: State(r, m)) -> Dict(r, Set(Int)) {
  state.clouds
}

pub fn delta(state: State(r, m)) -> Delta(r, m) {
  state.delta
}

/// The number of values held, from every replica.
pub fn size(state: State(r, m)) -> Int {
  dict.size(state.values)
}

/// The number of this replica's entries for `pid`.
pub fn pid_entry_count(state: State(r, m), pid: Pid) -> Int {
  case dict.get(state.pids, pid) {
    Ok(keys) -> set.size(keys)
    Error(Nil) -> 0
  }
}

/// This replica and its context without down replicas. Down replicas are
/// left out because deltas leave them out too: a peer that came up after a
/// replica went down would otherwise ask for a full transfer forever.
pub fn clocks(state: State(r, m)) -> #(r, Clock(r)) {
  let context =
    dict.filter(state.context, fn(replica, _) {
      replica_status(state, replica) != Ok(Down)
    })
  #(state.replica, context)
}

pub fn replica_status(
  state: State(r, m),
  replica: r,
) -> Result(ReplicaStatus, Nil) {
  dict.get(state.replicas, replica)
}

// --- Local changes ----------------------------------------------------------

/// Track `key` for `pid` on `topic`. `Error(Nil)` if already tracked.
pub fn join(
  state: State(r, m),
  pid: Pid,
  topic: String,
  key: String,
  meta: m,
) -> Result(#(State(r, m), Element(r, m)), Nil) {
  let k = Key(topic:, pid:, key:)
  case dict.has_key(state.local, k) {
    True -> Error(Nil)
    False -> {
      let #(state, tag) = bump_clock(state)
      Ok(#(insert_local(state, k, meta, tag), Element(key: k, meta:, tag:)))
    }
  }
}

/// Stop tracking `key` for `pid` on `topic`. `Error(Nil)` if not tracked.
pub fn leave(
  state: State(r, m),
  pid: Pid,
  topic: String,
  key: String,
) -> Result(#(State(r, m), Element(r, m)), Nil) {
  let k = Key(topic:, pid:, key:)
  case dict.get(state.local, k) {
    Error(Nil) -> Error(Nil)
    Ok(tag) -> {
      let removed = local_element(state, k, tag)
      let #(state, _) = bump_clock(remove_local(state, k, tag))
      Ok(#(state, removed))
    }
  }
}

/// Stop tracking everything `pid` tracks.
pub fn leave_pid(
  state: State(r, m),
  pid: Pid,
) -> #(State(r, m), List(Element(r, m))) {
  case dict.get(state.pids, pid) {
    Error(Nil) -> #(state, [])
    Ok(keys) ->
      set.fold(keys, #(state, []), fn(acc, k) {
        let #(state, removed) = acc
        let assert Ok(#(state, element)) = leave(state, k.pid, k.topic, k.key)
          as "every key in the pid index is a tracked local entry"
        #(state, [element, ..removed])
      })
  }
}

/// Replace the meta of a tracked entry: a leave of the old tag and a join
/// under a new one. Returns the previous and the new element.
/// `Error(Nil)` if not tracked.
pub fn leave_join(
  state: State(r, m),
  pid: Pid,
  topic: String,
  key: String,
  meta: m,
) -> Result(#(State(r, m), Element(r, m), Element(r, m)), Nil) {
  let k = Key(topic:, pid:, key:)
  case dict.get(state.local, k) {
    Error(Nil) -> Error(Nil)
    Ok(old_tag) -> {
      let previous = local_element(state, k, old_tag)
      let #(state, _) = bump_clock(remove_local(state, k, old_tag))
      let #(state, tag) = bump_clock(state)
      let state = insert_local(state, k, meta, tag)
      Ok(#(state, previous, Element(key: k, meta:, tag:)))
    }
  }
}

fn local_element(state: State(r, m), k: Key, tag: Tag(r)) -> Element(r, m) {
  let assert Ok(#(_, meta)) = dict.get(state.values, tag)
    as "every tag in the local index has a value"
  Element(key: k, meta:, tag:)
}

fn insert_local(
  state: State(r, m),
  k: Key,
  meta: m,
  tag: Tag(r),
) -> State(r, m) {
  let pid_keys = case dict.get(state.pids, k.pid) {
    Ok(keys) -> set.insert(keys, k)
    Error(Nil) -> set.from_list([k])
  }
  State(
    ..state,
    values: dict.insert(state.values, tag, #(k, meta)),
    local: dict.insert(state.local, k, tag),
    pids: dict.insert(state.pids, k.pid, pid_keys),
    delta: Delta(
      ..state.delta,
      values: dict.insert(state.delta.values, tag, #(k, meta)),
    ),
  )
}

/// Delete a local entry and record the removed tag in the delta.
fn remove_local(state: State(r, m), k: Key, tag: Tag(r)) -> State(r, m) {
  let assert Ok(keys) = dict.get(state.pids, k.pid)
    as "every local entry is in the pid index"
  let keys = set.delete(keys, k)
  let pids = case set.is_empty(keys) {
    True -> dict.delete(state.pids, k.pid)
    False -> dict.insert(state.pids, k.pid, keys)
  }
  State(
    ..state,
    values: dict.delete(state.values, tag),
    local: dict.delete(state.local, k),
    pids:,
    clouds: delete_tag(state.clouds, tag),
    delta: remove_delta_tag(state.delta, tag),
  )
}

fn bump_clock(state: State(r, m)) -> #(State(r, m), Tag(r)) {
  let next = own_clock(state) + 1
  let tag = Tag(replica: state.replica, clock: next)
  let state =
    State(
      ..state,
      delta: Delta(..state.delta, clouds: put_tag(state.delta.clouds, tag)),
    )
  #(put_context(state, dict.insert(state.context, state.replica, next)), tag)
}

fn own_clock(state: State(r, m)) -> Int {
  let assert Ok(value) = dict.get(state.context, state.replica)
    as "a replica is always in its own context"
  value
}

/// Set the context and extend the delta's range to this replica's clock.
fn put_context(state: State(r, m), context: Clock(r)) -> State(r, m) {
  let own = case dict.get(context, state.replica) {
    Ok(value) -> value
    Error(Nil) -> 0
  }
  State(
    ..state,
    context:,
    delta: Delta(
      ..state.delta,
      range_end: dict.insert(state.delta.range_end, state.replica, own),
    ),
  )
}

// --- Reads ------------------------------------------------------------------

/// This replica's entries for `pid`.
pub fn get_by_pid(state: State(r, m), pid: Pid) -> List(Element(r, m)) {
  case dict.get(state.pids, pid) {
    Error(Nil) -> []
    Ok(keys) ->
      set.fold(keys, [], fn(acc, k) {
        let assert Ok(tag) = dict.get(state.local, k)
          as "every key in the pid index is in the local index"
        [local_element(state, k, tag), ..acc]
      })
  }
}

/// This replica's entry for `pid` under `topic` and `key`.
pub fn get_by_pid_key(
  state: State(r, m),
  pid: Pid,
  topic: String,
  key: String,
) -> Result(Element(r, m), Nil) {
  let k = Key(topic:, pid:, key:)
  case dict.get(state.local, k) {
    Ok(tag) -> Ok(local_element(state, k, tag))
    Error(Nil) -> Error(Nil)
  }
}

/// Visible entries (not from down replicas) on `topic`.
pub fn get_by_topic(state: State(r, m), topic: String) -> List(Element(r, m)) {
  visible(state, fn(k) { k.topic == topic })
}

/// Visible entries on `topic` under `key`, from any pid.
pub fn get_by_key(
  state: State(r, m),
  topic: String,
  key: String,
) -> List(Element(r, m)) {
  visible(state, fn(k) { k.topic == topic && k.key == key })
}

/// Every visible entry.
pub fn online_list(state: State(r, m)) -> List(Element(r, m)) {
  visible(state, fn(_) { True })
}

fn visible(state: State(r, m), keep: fn(Key) -> Bool) -> List(Element(r, m)) {
  dict.fold(state.values, [], fn(acc, tag, entry) {
    let #(k, meta) = entry
    case keep(k) && replica_status(state, tag.replica) != Ok(Down) {
      True -> [Element(key: k, meta:, tag:), ..acc]
      False -> acc
    }
  })
}

fn replica_values(state: State(r, m), replica: r) -> List(Element(r, m)) {
  dict.fold(state.values, [], fn(acc, tag, entry) {
    case tag.replica == replica {
      True -> [Element(key: entry.0, meta: entry.1, tag:), ..acc]
      False -> acc
    }
  })
}

// --- Replicas ---------------------------------------------------------------

/// Mark `replica` up. Its values become visible and are returned as joins.
pub fn replica_up(
  state: State(r, m),
  replica: r,
) -> #(State(r, m), List(Element(r, m)), List(Element(r, m))) {
  let context = case dict.has_key(state.context, replica) {
    True -> state.context
    False -> dict.insert(state.context, replica, 0)
  }
  let state =
    State(..state, context:, replicas: dict.insert(state.replicas, replica, Up))
  #(state, replica_values(state, replica), [])
}

/// Mark `replica` down. Its values are hidden and returned as leaves; they
/// stay in the state until `remove_down_replicas`, so a quick recovery does
/// not need a transfer.
pub fn replica_down(
  state: State(r, m),
  replica: r,
) -> #(State(r, m), List(Element(r, m)), List(Element(r, m))) {
  let state =
    State(..state, replicas: dict.insert(state.replicas, replica, Down))
  #(state, [], replica_values(state, replica))
}

/// Forget a permanently down replica: its values, context and clouds.
pub fn remove_down_replicas(state: State(r, m), replica: r) -> State(r, m) {
  let assert False = replica == state.replica
    as "a replica never removes itself"
  State(
    ..state,
    values: dict.filter(state.values, fn(tag, _) { tag.replica != replica }),
    context: dict.delete(state.context, replica),
    clouds: dict.delete(state.clouds, replica),
    replicas: dict.delete(state.replicas, replica),
    delta: delta_remove_replica(state.delta, replica),
  )
}

/// Drop a replica from a delta's range, clouds and values.
pub fn delta_remove_replica(delta: Delta(r, m), replica: r) -> Delta(r, m) {
  Delta(
    values: dict.filter(delta.values, fn(tag, _) { tag.replica != replica }),
    clouds: dict.delete(delta.clouds, replica),
    range_start: dict.delete(delta.range_start, replica),
    range_end: dict.delete(delta.range_end, replica),
  )
}

// --- Deltas -----------------------------------------------------------------

/// Whether there are changes to broadcast.
pub fn has_delta(state: State(r, m)) -> Bool {
  dict.fold(state.delta.clouds, False, fn(acc, _, cloud) {
    acc || !set.is_empty(cloud)
  })
}

/// Values plus cloud tags: what bounds a delta generation.
pub fn delta_size(delta: Delta(r, m)) -> Int {
  dict.fold(delta.clouds, dict.size(delta.values), fn(acc, _, cloud) {
    acc + set.size(cloud)
  })
}

/// Start a new empty delta at the current clock.
pub fn reset_delta(state: State(r, m)) -> State(r, m) {
  State(..state, delta: empty_delta(state.replica, state.context))
}

fn empty_delta(replica: r, context: Clock(r)) -> Delta(r, m) {
  let range = dict.take(context, [replica])
  Delta(
    values: dict.new(),
    clouds: dict.new(),
    range_start: range,
    range_end: range,
  )
}

/// Fold cloud tags that continue the context into it, and drop those it
/// already covers. Empty clouds are removed.
pub fn compact(state: State(r, m)) -> State(r, m) {
  let #(context, clouds) =
    dict.fold(
      state.clouds,
      #(state.context, dict.new()),
      fn(acc, replica, cloud) {
        let #(context, clouds) = acc
        let #(context, kept) =
          set.to_list(cloud)
          |> list.sort(int.compare)
          |> list.fold(#(context, []), fn(acc, clock) {
            let #(context, kept) = acc
            case dict.get(context, replica) {
              Error(Nil) ->
                case clock == 1 {
                  True -> #(dict.insert(context, replica, 1), kept)
                  False -> #(context, [clock, ..kept])
                }
              Ok(current) ->
                case current + 1 == clock, current >= clock {
                  True, _ -> #(dict.insert(context, replica, clock), kept)
                  False, True -> #(context, kept)
                  False, False -> #(context, [clock, ..kept])
                }
            }
          })
        case kept {
          [] -> #(context, clouds)
          _ -> #(context, dict.insert(clouds, replica, set.from_list(kept)))
        }
      },
    )
  put_context(State(..state, clouds:), context)
}

/// Merge two deltas into one covering both ranges. Phoenix: `merge_deltas`.
pub fn merge_deltas(
  local: Delta(r, m),
  remote: Delta(r, m),
) -> Result(Delta(r, m), DeltaError) {
  case
    clock.dominates_or_equal(remote.range_end, local.range_start)
    && clock.dominates_or_equal(local.range_end, remote.range_start)
  {
    False -> Error(NotContiguous)
    True -> {
      let kept =
        dict.filter(local.values, fn(tag, _) {
          dict.has_key(remote.values, tag) || !in_clouds(remote.clouds, tag)
        })
      let values =
        dict.fold(remote.values, kept, fn(acc, tag, entry) {
          case dict.has_key(local.values, tag) || in_clouds(local.clouds, tag) {
            True -> acc
            False -> dict.insert(acc, tag, entry)
          }
        })
      Ok(Delta(
        values:,
        clouds: dict.combine(local.clouds, remote.clouds, set.union),
        range_start: clock.lowerbound(local.range_start, remote.range_start),
        range_end: clock.upperbound(local.range_end, remote.range_end),
      ))
    }
  }
}

// --- Transfers --------------------------------------------------------------

/// The full state a peer with `remote_context` needs: the replicas it knows,
/// without its own values.
pub fn extract(
  state: State(r, m),
  remote_ref: r,
  remote_context: Clock(r),
) -> Snapshot(r, m) {
  let known = dict.keys(remote_context)
  Snapshot(
    context: dict.take(state.context, known),
    clouds: dict.take(state.clouds, known),
    values: for_peer(state.values, remote_ref, remote_context),
  )
}

/// A delta restricted the same way as `extract`.
pub fn extract_delta(
  delta: Delta(r, m),
  remote_ref: r,
  remote_context: Clock(r),
) -> Delta(r, m) {
  let known = dict.keys(remote_context)
  Delta(
    values: for_peer(delta.values, remote_ref, remote_context),
    clouds: dict.take(delta.clouds, known),
    range_start: dict.take(delta.range_start, known),
    range_end: dict.take(delta.range_end, known),
  )
}

fn for_peer(
  values: Dict(Tag(r), #(Key, m)),
  remote_ref: r,
  remote_context: Clock(r),
) -> Dict(Tag(r), #(Key, m)) {
  dict.filter(values, fn(tag, _) {
    tag.replica != remote_ref && dict.has_key(remote_context, tag.replica)
  })
}

/// The number of values a transfer carries: what `max_transfer_entries`
/// bounds.
pub fn transfer_size(transfer: Transfer(r, m)) -> Int {
  case transfer {
    DeltaTransfer(delta) -> dict.size(delta.values)
    SnapshotTransfer(snapshot) -> dict.size(snapshot.values)
  }
}

/// Merge a delta or snapshot from a peer. Returns the entries that joined
/// and left. Joins are only taken from replicas this state knows, and
/// leaves only touch other replicas' entries: a tag the sender has seen
/// (in its context or clouds) but no longer holds was removed.
pub fn merge(
  state: State(r, m),
  transfer: Transfer(r, m),
) -> #(State(r, m), List(Element(r, m)), List(Element(r, m))) {
  let #(remote_context, remote_clouds, remote_values) = case transfer {
    DeltaTransfer(delta) -> #(dict.new(), delta.clouds, delta.values)
    SnapshotTransfer(snapshot) -> #(
      snapshot.context,
      snapshot.clouds,
      snapshot.values,
    )
  }
  let joins =
    dict.fold(remote_values, [], fn(acc, tag, entry) {
      case
        dict.has_key(state.context, tag.replica)
        && !covered(state.context, state.clouds, tag)
      {
        True -> [Element(key: entry.0, meta: entry.1, tag:), ..acc]
        False -> acc
      }
    })
  let leaves = case transfer {
    // A delta has no context, so only tags in its clouds are covered.
    DeltaTransfer(_) ->
      dict.fold(remote_clouds, [], fn(acc, replica, cloud) {
        case replica == state.replica {
          True -> acc
          False ->
            set.fold(cloud, acc, fn(acc, clock) {
              let tag = Tag(replica:, clock:)
              case
                dict.get(state.values, tag),
                dict.has_key(remote_values, tag)
              {
                Ok(#(k, meta)), False -> [Element(key: k, meta:, tag:), ..acc]
                Ok(_), True -> acc
                Error(Nil), _ -> acc
              }
            })
        }
      })
    SnapshotTransfer(_) ->
      dict.fold(state.values, [], fn(acc, tag, entry) {
        case
          tag.replica != state.replica
          && covered(remote_context, remote_clouds, tag)
          && !dict.has_key(remote_values, tag)
        {
          True -> [Element(key: entry.0, meta: entry.1, tag:), ..acc]
          False -> acc
        }
      })
  }
  let unioned =
    dict.fold(remote_clouds, state.clouds, fn(acc, replica, cloud) {
      case dict.has_key(state.context, replica) {
        False -> acc
        True ->
          case dict.get(acc, replica) {
            Ok(existing) ->
              dict.insert(acc, replica, set.union(existing, cloud))
            Error(Nil) -> dict.insert(acc, replica, cloud)
          }
      }
    })
  let #(clouds, delta, values) =
    list.fold(leaves, #(unioned, state.delta, state.values), fn(acc, left) {
      let #(clouds, delta, values) = acc
      #(
        delete_tag(clouds, left.tag),
        remove_delta_tag(delta, left.tag),
        dict.delete(values, left.tag),
      )
    })
  let values =
    list.fold(joins, values, fn(acc, joined) {
      dict.insert(acc, joined.tag, #(joined.key, joined.meta))
    })
  let context =
    clock.upperbound(
      state.context,
      dict.take(remote_context, dict.keys(state.context)),
    )
  let state =
    State(..state, values:, clouds:, delta:)
    |> put_context(context)
    |> compact
  #(state, joins, leaves)
}

// --- Tags -------------------------------------------------------------------

fn covered(context: Clock(r), clouds: Dict(r, Set(Int)), tag: Tag(r)) -> Bool {
  let seen = case dict.get(context, tag.replica) {
    Ok(value) -> value >= tag.clock
    Error(Nil) -> False
  }
  seen || in_clouds(clouds, tag)
}

fn in_clouds(clouds: Dict(r, Set(Int)), tag: Tag(r)) -> Bool {
  case dict.get(clouds, tag.replica) {
    Ok(cloud) -> set.contains(cloud, tag.clock)
    Error(Nil) -> False
  }
}

fn put_tag(clouds: Dict(r, Set(Int)), tag: Tag(r)) -> Dict(r, Set(Int)) {
  case dict.get(clouds, tag.replica) {
    Ok(cloud) -> dict.insert(clouds, tag.replica, set.insert(cloud, tag.clock))
    Error(Nil) -> dict.insert(clouds, tag.replica, set.from_list([tag.clock]))
  }
}

fn delete_tag(clouds: Dict(r, Set(Int)), tag: Tag(r)) -> Dict(r, Set(Int)) {
  case dict.get(clouds, tag.replica) {
    Ok(cloud) -> dict.insert(clouds, tag.replica, set.delete(cloud, tag.clock))
    Error(Nil) -> clouds
  }
}

/// Record a removed tag in a delta so peers see the remove.
fn remove_delta_tag(delta: Delta(r, m), tag: Tag(r)) -> Delta(r, m) {
  Delta(
    ..delta,
    clouds: put_tag(delta.clouds, tag),
    values: dict.delete(delta.values, tag),
  )
}
