//// Delta generations, ported from Phoenix.Tracker.DeltaGeneration.
////
//// A shard keeps a few accumulated deltas of growing size (by default up
//// to 100, 1000 and 10000 tags). Every broadcast or received delta is
//// merged into each generation that it continues and that stays within
//// its size; a generation that would grow too big is restarted from the
//// latest delta alone. A peer that falls behind gets the smallest
//// generation that covers its gap, and a snapshot when none does.

import brazier/presence/clock
import brazier/presence/state.{
  type Delta, type State, type Transfer, DeltaTransfer, NotContiguous,
  SnapshotTransfer,
}
import gleam/dict
import gleam/list

/// Add `delta` to every generation. With no generations yet, each starts
/// from the state's current (empty) delta.
pub fn push(
  current: State(r, m),
  generations: List(Delta(r, m)),
  delta: Delta(r, m),
  max_sizes: List(Int),
) -> List(Delta(r, m)) {
  let generations = case generations {
    [] -> list.map(max_sizes, fn(_) { state.delta(current) })
    _ -> generations
  }
  let assert Ok(pairs) = list.strict_zip(generations, max_sizes)
    as "there is one generation per configured size"
  let #(_, pushed) =
    list.fold(pairs, #(delta, []), fn(acc, pair) {
      let #(previous, pushed) = acc
      let #(generation, max_size) = pair
      case state.merge_deltas(generation, delta) {
        Ok(merged) ->
          case state.delta_size(merged) <= max_size {
            True -> #(merged, [merged, ..pushed])
            False -> #(merged, [previous, ..pushed])
          }
        Error(NotContiguous) -> #(generation, [generation, ..pushed])
      }
    })
  list.reverse(pushed)
}

/// What to send a peer with `remote_context`: the first generation that
/// starts at or before its clock and ends after it, else a snapshot.
pub fn extract(
  current: State(r, m),
  generations: List(Delta(r, m)),
  remote_ref: r,
  remote_context: clock.Clock(r),
) -> Transfer(r, m) {
  let known = dict.keys(remote_context)
  let fulfilling =
    list.find(generations, fn(generation) {
      let start = clock.filter_replicas(generation.range_start, known)
      let end = clock.filter_replicas(generation.range_end, known)
      !clock.dominates_or_equal(start, end)
      && clock.dominates_or_equal(remote_context, start)
      && !clock.dominates(remote_context, end)
    })
  case fulfilling {
    Ok(generation) ->
      DeltaTransfer(state.extract_delta(generation, remote_ref, remote_context))
    Error(Nil) ->
      SnapshotTransfer(state.extract(current, remote_ref, remote_context))
  }
}

/// Drop a permanently down replica from every generation.
pub fn remove_down_replicas(
  generations: List(Delta(r, m)),
  replica: r,
) -> List(Delta(r, m)) {
  list.map(generations, state.delta_remove_replica(_, replica))
}
