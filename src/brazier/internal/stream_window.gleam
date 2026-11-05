/// A session's stream windows and the delta each update sends
/// (docs/design/STREAMS.md 7.2 to 7.4).
///
/// A window is one stream's keys, in order, at most its limit. The server
/// keeps keys, not items (LiveView frees items after render,
/// `lib/phoenix_live_view.ex` l.1894), so it knows exactly what the client
/// holds and computes every trim itself (decision D6). Windows made with
/// `new(keep_items: True)` also keep each key's latest item JSON: the
/// runtime uses them before the first join and SSR uses them for the dead
/// render; `snapshot` sends them once and drops the items.
///
/// `apply_update` applies one update's ops, in order, and returns one
/// `Delta` per stream the update changed, which is the wire entry of
/// docs/design/STREAMS.md 6.1:
///
/// - an `Insert` of a key in the window updates it in place and never
///   moves it (LiveView `stream_insert`, l.2122);
/// - an `Insert` of a new key goes to the front or the back, then the other
///   end is trimmed to the limit. A `Prepend` into a full `KeepLast`
///   window, or an `Append` into a full `KeepFirst` one, trims the new item
///   itself (LiveView `maybeLimitStream` in `dom_patch.ts`);
/// - a `Delete` of a key not in the window changes nothing; it is reported
///   in `unknown_deletes` for the runtime to log at warning. LiveView
///   records such a delete and its client skips an id it cannot find
///   (`dom_patch.ts`, the `deleteIds` loop); here the window knows the
///   client's keys, so nothing is sent, and the client treats a delete of a
///   key it does not hold as a fault;
/// - a `Reset` empties the window and inserts its items at the back.
///
/// The delta then holds, with `W` the window before the update and `W2`
/// after it: `reset` when a `Reset` ran (and then no deletes, and every key
/// of `W2` as an insert); otherwise the keys of `W` that left it at some
/// point in the update as `deletes`, in `W` order, and the keys of `W2`
/// that are new, moved (deleted, then inserted again) or updated as
/// `inserts`, each at its index in `W2`, in ascending order. A client that
/// applies the deletes, then the inserts in order, ends with `W2`. An item
/// inserted and then trimmed or deleted in the same update is never sent
/// (LiveView's "latest insert wins", `LiveStream` `uniq_inserts`).
///
/// Every bound is an `Error` value: an op over a per-op bound is refused
/// and not applied (the rest of the update is), and an update over a
/// per-update bound is refused whole, with the windows unchanged. Nothing
/// is clamped or dropped silently. This module is pure; the runtime logs.
import brazier/internal/stream_op.{
  type Action, type End, type Limit, type Op, Back, Delete, First, Front, Insert,
  Last, Reset,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/set.{type Set}
import gleam/string

/// The stream bounds (decision D4). They will be `SecurityLimits` fields
/// (`stream_max_limit`, `stream_item_max_bytes`,
/// `stream_ops_max_per_update`, `stream_frame_max_bytes`,
/// `stream_key_max_bytes`); until then the caller passes them.
pub type Limits {
  Limits(
    /// The largest limit a stream may have.
    max_limit: Int,
    /// The largest item JSON, in bytes.
    item_max_bytes: Int,
    /// The most ops one update may carry, all streams together. A `Reset`
    /// counts one per item, and at least one.
    ops_max_per_update: Int,
    /// The largest encoded `streams` array of one frame, in bytes.
    frame_max_bytes: Int,
    /// The longest key, in bytes. A key must also not be empty.
    key_max_bytes: Int,
  )
}

/// The defaults decided in D4.
pub fn default_limits() -> Limits {
  Limits(
    max_limit: 1000,
    item_max_bytes: 65_536,
    ops_max_per_update: 1000,
    frame_max_bytes: 1_048_576,
    key_max_bytes: 256,
  )
}

/// Why one op was refused. A refused op is not applied.
pub type OpReason {
  /// The op's limit is below 1 or above `max_limit`. No window is made.
  LimitOutOfRange(count: Int, max: Int)
  /// The stream's window was made with another limit (design 7.5).
  LimitMismatch(window: Limit, op: Limit)
  /// A key is the empty string.
  KeyEmpty
  /// A key is longer than `key_max_bytes`.
  KeyTooLarge(bytes: Int, max: Int)
  /// An item's JSON is longer than `item_max_bytes`.
  ItemTooLarge(bytes: Int, max: Int)
}

/// A refused op: its index in the update's op list, its stream and why.
pub type OpRefusal {
  OpRefusal(index: Int, stream: String, reason: OpReason)
}

/// Why a whole update was refused. No op of it is applied.
pub type UpdateRefusal {
  /// The update carries more ops than `ops_max_per_update`.
  TooManyOps(count: Int, max: Int)
  /// The update's encoded deltas are larger than `frame_max_bytes`.
  FrameTooLarge(bytes: Int, max: Int)
}

/// A delete of a key the window did not hold at that point of the update.
pub type UnknownDelete {
  UnknownDelete(index: Int, stream: String, key: String)
}

/// One stream's change in one frame: the wire entry of
/// docs/design/STREAMS.md 6.1. `encode_deltas` writes it.
pub type Delta {
  Delta(
    name: String,
    limit: Limit,
    reset: Bool,
    deletes: List(String),
    inserts: List(DeltaInsert),
  )
}

/// An insert of a delta: `key` at index `at` of the window after the
/// update, with its latest item JSON.
pub type DeltaInsert {
  DeltaInsert(key: String, at: Int, json: String)
}

/// A delta with the counts telemetry reports (design 11). `updated` is the
/// number of inserts that update a key in place; `trimmed` the number of
/// keys the limit removed during the update, new items trimmed at once
/// included.
pub type Change {
  Change(delta: Delta, updated: Int, trimmed: Int)
}

/// The result of an accepted update.
pub type Applied {
  Applied(
    /// The windows after the update.
    windows: Windows,
    /// One change per stream the update changed, in the order the update
    /// first used each stream.
    changes: List(Change),
    /// The ops that were refused, in order. The other ops were applied.
    refused: List(OpRefusal),
    /// The deletes of keys not in their window, in order.
    unknown_deletes: List(UnknownDelete),
    /// The encoded `streams` array: `encode_deltas` of the changes.
    streams_json: String,
  )
}

/// `snapshot` was called on windows that do not keep items.
pub type SnapshotError {
  ItemsNotKept
}

/// A session's windows, one per stream used so far.
pub opaque type Windows {
  Windows(streams: Dict(String, Window), keep_items: Bool)
}

type Window {
  Window(
    name: String,
    limit: Limit,
    /// In order, unique, at most `limit.count`.
    keys: List(String),
    /// `list.length(keys)`.
    size: Int,
    /// The keys, as a set.
    members: Set(String),
    items: Items,
  )
}

type Items {
  NoItems
  /// The latest JSON of every key in the window, and of no other key.
  Kept(Dict(String, String))
}

/// One stream's work during one update.
type Work {
  Work(
    window: Window,
    old_keys: List(String),
    old_members: Set(String),
    /// Keys of the old window that left the window at some point.
    removed: Set(String),
    /// The latest JSON of every key inserted during the update.
    touched: Dict(String, String),
    reset: Bool,
    trimmed: Int,
  )
}

/// No windows. With `keep_items`, every window also keeps its items'
/// latest JSON until `snapshot`.
pub fn new(keep_items keep_items: Bool) -> Windows {
  Windows(streams: dict.new(), keep_items: keep_items)
}

/// The keys of stream `name`'s window, in order. `Error(Nil)` when no op
/// has used the stream.
pub fn keys(windows: Windows, name: String) -> Result(List(String), Nil) {
  case dict.get(windows.streams, name) {
    Ok(window) -> Ok(window.keys)
    Error(Nil) -> Error(Nil)
  }
}

/// The limit stream `name`'s window was made with.
pub fn limit(windows: Windows, name: String) -> Result(Limit, Nil) {
  case dict.get(windows.streams, name) {
    Ok(window) -> Ok(window.limit)
    Error(Nil) -> Error(Nil)
  }
}

/// Apply one update's ops, in order. `Error` when the update is over a
/// per-update bound; the windows are then unchanged.
pub fn apply_update(
  windows: Windows,
  ops: List(Op),
  limits: Limits,
) -> Result(Applied, UpdateRefusal) {
  assert_limits(limits)
  let count = op_count(ops)
  case count > limits.ops_max_per_update {
    True -> Error(TooManyOps(count: count, max: limits.ops_max_per_update))
    False -> {
      let state = run_ops(windows, ops, limits)
      let #(streams, changes) =
        list.fold(
          list.reverse(state.order),
          #(windows.streams, []),
          fn(acc, name) {
            let #(streams, changes) = acc
            // Invariant: `order` holds exactly the names that have work.
            let assert Ok(work) = dict.get(state.work, name)
              as "brazier/internal/stream_window: a stream in the update's order has no work"
            let #(window, change) = finish(work)
            let changes = case change {
              Ok(change) -> [change, ..changes]
              Error(Nil) -> changes
            }
            #(dict.insert(streams, name, window), changes)
          },
        )
      let changes = list.reverse(changes)
      let deltas = list.map(changes, fn(change) { change.delta })
      case check_frame(deltas, limits) {
        Error(refusal) -> Error(refusal)
        Ok(streams_json) ->
          Ok(Applied(
            windows: Windows(..windows, streams: streams),
            changes: changes,
            refused: list.reverse(state.refused),
            unknown_deletes: list.reverse(state.unknown_deletes),
            streams_json: streams_json,
          ))
      }
    }
  }
}

/// Every window that holds items, as a `reset` delta with its items, in
/// name order; and the windows without their items. The runtime sends the
/// deltas in the first join's `model_sync` (design 7.2); SSR renders their
/// items. `Error` when the windows do not keep items.
pub fn snapshot(
  windows: Windows,
) -> Result(#(List(Delta), Windows), SnapshotError) {
  case windows.keep_items {
    False -> Error(ItemsNotKept)
    True -> {
      let named =
        dict.to_list(windows.streams)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      let deltas =
        list.filter_map(named, fn(entry) {
          let #(_, window) = entry
          case window.keys {
            [] -> Error(Nil)
            _ -> Ok(snapshot_delta(window))
          }
        })
      let streams =
        dict.map_values(windows.streams, fn(_, window) {
          Window(..window, items: NoItems)
        })
      Ok(#(deltas, Windows(streams: streams, keep_items: False)))
    }
  }
}

/// The encoded `streams` array of `deltas`, or `FrameTooLarge` when it is
/// over `frame_max_bytes`.
pub fn check_frame(
  deltas: List(Delta),
  limits: Limits,
) -> Result(String, UpdateRefusal) {
  let text = encode_deltas(deltas)
  let bytes = string.byte_size(text)
  case bytes > limits.frame_max_bytes {
    True -> Error(FrameTooLarge(bytes: bytes, max: limits.frame_max_bytes))
    False -> Ok(text)
  }
}

/// The wire `streams` array: `[entry, ...]`, each entry as
/// docs/design/STREAMS.md 6.1 lays it out. Item JSON is embedded as it is.
pub fn encode_deltas(deltas: List(Delta)) -> String {
  "[" <> string.join(list.map(deltas, encode_delta), ",") <> "]"
}

/// One wire entry:
/// `{"name":..,"keep":..,"limit":..,"reset":..,"deletes":[..],"inserts":[{"key":..,"at":..,"item":..}]}`.
pub fn encode_delta(delta: Delta) -> String {
  let inserts =
    list.map(delta.inserts, fn(insert) {
      "{\"key\":"
      <> json_string(insert.key)
      <> ",\"at\":"
      <> int.to_string(insert.at)
      <> ",\"item\":"
      <> insert.json
      <> "}"
    })
  "{\"name\":"
  <> json_string(delta.name)
  <> ",\"keep\":"
  <> json_string(stream_op.keep_to_string(delta.limit.keep))
  <> ",\"limit\":"
  <> int.to_string(delta.limit.count)
  <> ",\"reset\":"
  <> bool_text(delta.reset)
  <> ",\"deletes\":["
  <> string.join(list.map(delta.deletes, json_string), ",")
  <> "],\"inserts\":["
  <> string.join(inserts, ",")
  <> "]}"
}

/// The wire name of an op refusal, for telemetry (design 11).
pub fn op_reason_name(reason: OpReason) -> String {
  case reason {
    LimitOutOfRange(..) -> "limit_out_of_range"
    LimitMismatch(..) -> "limit_mismatch"
    KeyEmpty -> "key_empty"
    KeyTooLarge(..) -> "key_too_large"
    ItemTooLarge(..) -> "item_too_large"
  }
}

/// The wire name of an update refusal, for telemetry (design 11).
pub fn update_refusal_name(refusal: UpdateRefusal) -> String {
  case refusal {
    TooManyOps(..) -> "too_many_ops"
    FrameTooLarge(..) -> "frame_too_large"
  }
}

/// How many ops an update counts against `ops_max_per_update`: one per
/// `Insert` and `Delete`, one per item of a `Reset` and at least one.
pub fn op_count(ops: List(Op)) -> Int {
  list.fold(ops, 0, fn(total, op) {
    case op.action {
      Insert(..) | Delete(..) -> total + 1
      Reset(items) -> total + int.max(1, list.length(items))
    }
  })
}

// --- Applying ops -----------------------------------------------------------

type RunState {
  RunState(
    work: Dict(String, Work),
    /// Stream names in reverse order of first use.
    order: List(String),
    refused: List(OpRefusal),
    unknown_deletes: List(UnknownDelete),
    index: Int,
  )
}

fn run_ops(windows: Windows, ops: List(Op), limits: Limits) -> RunState {
  let start =
    RunState(
      work: dict.new(),
      order: [],
      refused: [],
      unknown_deletes: [],
      index: 0,
    )
  list.fold(ops, start, fn(state, op) {
    let index = state.index
    let state = RunState(..state, index: index + 1)
    case work_for(windows, state, op, limits) {
      Error(reason) ->
        RunState(..state, refused: [
          OpRefusal(index: index, stream: op.name, reason: reason),
          ..state.refused
        ])
      Ok(#(work, is_new)) ->
        case check_action(op.action, limits) {
          Error(reason) -> {
            // The window is still recorded: the first op on a stream fixes
            // its limit even when its action is refused.
            let state = store_work(state, op.name, work, is_new)
            RunState(..state, refused: [
              OpRefusal(index: index, stream: op.name, reason: reason),
              ..state.refused
            ])
          }
          Ok(Nil) -> {
            let #(work, unknown) = apply_action(work, op.action)
            let state = store_work(state, op.name, work, is_new)
            case unknown {
              Ok(key) ->
                RunState(..state, unknown_deletes: [
                  UnknownDelete(index: index, stream: op.name, key: key),
                  ..state.unknown_deletes
                ])
              Error(Nil) -> state
            }
          }
        }
    }
  })
}

fn store_work(
  state: RunState,
  name: String,
  work: Work,
  is_new: Bool,
) -> RunState {
  let order = case is_new {
    True -> [name, ..state.order]
    False -> state.order
  }
  RunState(..state, work: dict.insert(state.work, name, work), order: order)
}

/// The stream's work so far in this update, starting it from the stream's
/// window, or from a new window. `is_new` is whether the update had not
/// used the stream before.
fn work_for(
  windows: Windows,
  state: RunState,
  op: Op,
  limits: Limits,
) -> Result(#(Work, Bool), OpReason) {
  case dict.get(state.work, op.name) {
    Ok(work) ->
      case work.window.limit == op.limit {
        True -> Ok(#(work, False))
        False -> Error(LimitMismatch(window: work.window.limit, op: op.limit))
      }
    Error(Nil) ->
      case dict.get(windows.streams, op.name) {
        Ok(window) ->
          case window.limit == op.limit {
            True -> Ok(#(start_work(window), True))
            False -> Error(LimitMismatch(window: window.limit, op: op.limit))
          }
        Error(Nil) ->
          case op.limit.count < 1 || op.limit.count > limits.max_limit {
            True ->
              Error(LimitOutOfRange(
                count: op.limit.count,
                max: limits.max_limit,
              ))
            False -> {
              let items = case windows.keep_items {
                True -> Kept(dict.new())
                False -> NoItems
              }
              let window =
                Window(
                  name: op.name,
                  limit: op.limit,
                  keys: [],
                  size: 0,
                  members: set.new(),
                  items: items,
                )
              Ok(#(start_work(window), True))
            }
          }
      }
  }
}

fn start_work(window: Window) -> Work {
  Work(
    window: window,
    old_keys: window.keys,
    old_members: window.members,
    removed: set.new(),
    touched: dict.new(),
    reset: False,
    trimmed: 0,
  )
}

fn check_action(action: Action, limits: Limits) -> Result(Nil, OpReason) {
  case action {
    Insert(key, json, _) ->
      case check_key(key, limits) {
        Error(reason) -> Error(reason)
        Ok(Nil) -> check_item(json, limits)
      }
    Delete(key) -> check_key(key, limits)
    Reset(items) ->
      list.try_each(items, fn(item) {
        let #(key, json) = item
        case check_key(key, limits) {
          Error(reason) -> Error(reason)
          Ok(Nil) -> check_item(json, limits)
        }
      })
  }
}

fn check_key(key: String, limits: Limits) -> Result(Nil, OpReason) {
  let bytes = string.byte_size(key)
  case bytes {
    0 -> Error(KeyEmpty)
    _ if bytes > limits.key_max_bytes ->
      Error(KeyTooLarge(bytes: bytes, max: limits.key_max_bytes))
    _ -> Ok(Nil)
  }
}

fn check_item(json: String, limits: Limits) -> Result(Nil, OpReason) {
  let bytes = string.byte_size(json)
  case bytes > limits.item_max_bytes {
    True -> Error(ItemTooLarge(bytes: bytes, max: limits.item_max_bytes))
    False -> Ok(Nil)
  }
}

/// Apply one checked action. The second value is the key of a delete that
/// found no key to remove.
fn apply_action(work: Work, action: Action) -> #(Work, Result(String, Nil)) {
  case action {
    Insert(key, json, at) -> #(insert(work, key, json, at), Error(Nil))
    Delete(key) ->
      case set.contains(work.window.members, key) {
        True -> {
          let window = work.window
          let window =
            Window(
              ..window,
              keys: list.filter(window.keys, fn(other) { other != key }),
              size: window.size - 1,
            )
          #(forget(Work(..work, window: window), key), Error(Nil))
        }
        False -> #(work, Ok(key))
      }
    Reset(items) -> {
      let window = work.window
      let emptied = case window.items {
        Kept(_) -> Kept(dict.new())
        NoItems -> NoItems
      }
      let window =
        Window(..window, keys: [], size: 0, members: set.new(), items: emptied)
      let work = Work(..work, window: window, touched: dict.new(), reset: True)
      let work =
        list.fold(items, work, fn(work, item) {
          insert(work, item.0, item.1, Back)
        })
      #(work, Error(Nil))
    }
  }
}

fn insert(work: Work, key: String, json: String, at: End) -> Work {
  let work = Work(..work, touched: dict.insert(work.touched, key, json))
  let window = work.window
  case set.contains(window.members, key) {
    // Update in place: the key keeps its position.
    True ->
      Work(
        ..work,
        window: Window(..window, items: put(window.items, key, json)),
      )
    False -> place(work, key, json, at)
  }
}

/// Put a new key at `at` and trim the other end to the limit.
fn place(work: Work, key: String, json: String, at: End) -> Work {
  let window = work.window
  let full = window.size >= window.limit.count
  let added = fn(keys) {
    Window(
      ..window,
      keys: keys,
      size: window.size + 1,
      members: set.insert(window.members, key),
      items: put(window.items, key, json),
    )
  }
  case full, window.limit.keep, at {
    False, _, Back ->
      Work(..work, window: added(list.append(window.keys, [key])))
    False, _, Front -> Work(..work, window: added([key, ..window.keys]))
    // A full window keeps its first items: an append is trimmed at once.
    True, First, Back -> Work(..work, trimmed: work.trimmed + 1)
    // A full window keeps its last items: a prepend is trimmed at once.
    True, Last, Front -> Work(..work, trimmed: work.trimmed + 1)
    True, Last, Back -> {
      // Invariant: a full window holds `limit.count` >= 1 keys.
      let assert [dropped, ..kept] = window.keys
        as "brazier/internal/stream_window: a full window has no first key"
      let grown = added(list.append(kept, [key]))
      trim(Work(..work, window: Window(..grown, size: grown.size - 1)), dropped)
    }
    True, First, Front -> {
      // Invariant: a full window holds `limit.count` >= 1 keys.
      let assert Ok(dropped) = list.last(window.keys)
        as "brazier/internal/stream_window: a full window has no last key"
      let grown = added([key, ..list.take(window.keys, window.size - 1)])
      trim(Work(..work, window: Window(..grown, size: grown.size - 1)), dropped)
    }
  }
}

/// `dropped` has already left `keys` and `size`; forget it and count it.
fn trim(work: Work, dropped: String) -> Work {
  let work = forget(work, dropped)
  Work(..work, trimmed: work.trimmed + 1)
}

/// `key` has already left `keys` and `size`: remove it from the members
/// and the items, and record it when the old window held it.
fn forget(work: Work, key: String) -> Work {
  let window = work.window
  let items = case window.items {
    Kept(items) -> Kept(dict.delete(items, key))
    NoItems -> NoItems
  }
  let window =
    Window(..window, members: set.delete(window.members, key), items: items)
  let removed = case set.contains(work.old_members, key) {
    True -> set.insert(work.removed, key)
    False -> work.removed
  }
  Work(..work, window: window, removed: removed)
}

fn put(items: Items, key: String, json: String) -> Items {
  case items {
    Kept(items) -> Kept(dict.insert(items, key, json))
    NoItems -> NoItems
  }
}

// --- The delta --------------------------------------------------------------

/// The window after the update and its change, or `Error(Nil)` when the
/// client's window does not change.
fn finish(work: Work) -> #(Window, Result(Change, Nil)) {
  let window = work.window
  assert_window(window)
  let indexed = list.index_map(window.keys, fn(key, index) { #(key, index) })
  let #(delta, updated) = case work.reset {
    True -> {
      let inserts =
        list.map(indexed, fn(entry) {
          DeltaInsert(key: entry.0, at: entry.1, json: latest(work, entry.0))
        })
      #(
        Delta(
          name: window.name,
          limit: window.limit,
          reset: True,
          deletes: [],
          inserts: inserts,
        ),
        0,
      )
    }
    False -> {
      let deletes =
        list.filter(work.old_keys, fn(key) { set.contains(work.removed, key) })
      let #(inserts, updated) =
        list.fold(indexed, #([], 0), fn(acc, entry) {
          let #(inserts, updated) = acc
          let #(key, index) = entry
          let stable =
            set.contains(work.old_members, key)
            && !set.contains(work.removed, key)
          case stable, dict.get(work.touched, key) {
            True, Ok(json) -> #(
              [DeltaInsert(key: key, at: index, json: json), ..inserts],
              updated + 1,
            )
            True, Error(Nil) -> #(inserts, updated)
            False, _ -> #(
              [
                DeltaInsert(key: key, at: index, json: latest(work, key)),
                ..inserts
              ],
              updated,
            )
          }
        })
      #(
        Delta(
          name: window.name,
          limit: window.limit,
          reset: False,
          deletes: deletes,
          inserts: list.reverse(inserts),
        ),
        updated,
      )
    }
  }
  let old_size = list.length(work.old_keys)
  assert_delta(delta, old_size, window.size, updated)
  case delta.reset, delta.deletes, delta.inserts {
    False, [], [] -> #(window, Error(Nil))
    _, _, _ -> #(
      window,
      Ok(Change(delta: delta, updated: updated, trimmed: work.trimmed)),
    )
  }
}

/// The JSON of a key the update inserted.
fn latest(work: Work, key: String) -> String {
  // Invariant: a key in the new window that is new, moved or reset was
  // inserted during this update, so `touched` holds its latest JSON.
  let assert Ok(json) = dict.get(work.touched, key)
    as "brazier/internal/stream_window: a key that entered the window has no JSON"
  json
}

fn snapshot_delta(window: Window) -> Delta {
  // Invariant: `snapshot` is only reached for windows that keep items.
  let assert Kept(items) = window.items
    as "brazier/internal/stream_window: snapshot of a window without items"
  let inserts =
    list.index_map(window.keys, fn(key, index) {
      // Invariant: a kept window holds the JSON of every key in it.
      let assert Ok(json) = dict.get(items, key)
        as "brazier/internal/stream_window: a kept key has no JSON"
      DeltaInsert(key: key, at: index, json: json)
    })
  Delta(
    name: window.name,
    limit: window.limit,
    reset: True,
    deletes: [],
    inserts: inserts,
  )
}

// --- Invariants -------------------------------------------------------------

fn assert_limits(limits: Limits) -> Nil {
  let assert True =
    limits.max_limit >= 1
    && limits.item_max_bytes >= 1
    && limits.ops_max_per_update >= 1
    && limits.frame_max_bytes >= 1
    && limits.key_max_bytes >= 1
    as "brazier/internal/stream_window: every stream bound must be at least 1"
  Nil
}

/// The window holds at most its limit of unique keys, and its items (when
/// kept) are exactly its keys'.
fn assert_window(window: Window) -> Nil {
  let assert True = window.size == list.length(window.keys)
    as "brazier/internal/stream_window: window size differs from its key count"
  let assert True = window.size <= window.limit.count
    as "brazier/internal/stream_window: window holds more keys than its limit"
  let assert True = set.size(window.members) == window.size
    as "brazier/internal/stream_window: window keys are not unique"
  let assert True = case window.items {
    Kept(items) -> dict.size(items) == window.size
    NoItems -> True
  }
    as "brazier/internal/stream_window: kept items differ from the window's keys"
  Nil
}

/// Every insert index is in range and ascending, the deletes are unique
/// keys of the old window, and applying the delta yields `new_size` keys.
fn assert_delta(
  delta: Delta,
  old_size: Int,
  new_size: Int,
  updated: Int,
) -> Nil {
  let ascending =
    list.fold(delta.inserts, Ok(-1), fn(previous, insert) {
      case previous {
        Ok(previous) ->
          case insert.at > previous && insert.at < new_size {
            True -> Ok(insert.at)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    })
  let assert Ok(_) = ascending
    as "brazier/internal/stream_window: delta insert indexes are out of range or not ascending"
  let deletes = list.length(delta.deletes)
  let assert True =
    deletes <= old_size && set.size(set.from_list(delta.deletes)) == deletes
    as "brazier/internal/stream_window: delta deletes are not unique keys of the old window"
  let landed = list.length(delta.inserts) - updated
  let assert True = case delta.reset {
    True -> deletes == 0 && landed == new_size
    False -> old_size - deletes + landed == new_size
  }
    as "brazier/internal/stream_window: delta does not account for the new window"
  Nil
}

fn json_string(text: String) -> String {
  json.to_string(json.string(text))
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
