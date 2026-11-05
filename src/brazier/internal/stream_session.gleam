/// A runtime's streams: the session's windows, one set of windows per
/// joined connection, and the frames each update sends
/// (docs/design/STREAMS.md 7.1 to 7.5).
///
/// The session windows take every update. Until the first join they keep
/// their items (7.2); the first join sends them as `reset` entries and from
/// then on they hold keys only. They decide what is refused and which
/// deletes are of unknown keys, so those are logged once per update, not
/// once per connection.
///
/// Each joined connection has its own windows: exactly the keys its client
/// holds. A connection that joins after the first one holds nothing, so its
/// windows start empty and its entries are computed against them, never
/// against the session's: a delete of a key that connection was never sent
/// is not sent to it, and an insert is placed at its index in that
/// connection's store. One set of windows for every connection would send a
/// late joiner deletes of keys it does not hold, which its client treats as
/// a fault (6.2). LiveView has one stream state per LiveView process, and a
/// process per connection (`Phoenix.LiveView.stream/4`, `LiveStream`);
/// these windows are that per-connection state.
///
/// Every refusal is logged at error, emitted as `[brazier, stream,
/// refused]`, and returned as the reason of an `error` frame for the joined
/// connections. Refusals of one update are grouped per stream and reason,
/// so an update of a thousand oversized items is one log line, one event
/// and one frame. Every frame sent emits one `[brazier, stream, delta]` per
/// entry, per connection.
import brazier/internal/stream_op.{type Op}
import brazier/internal/stream_window.{
  type Change, type Delta, type Limits, type OpRefusal, type UpdateRefusal,
  type Windows, FrameTooLarge, ItemTooLarge, ItemsNotKept, KeyTooLarge,
  TooManyOps,
}
import brazier/log
import brazier/telemetry
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string

/// The streams of one runtime.
pub opaque type Streams {
  Streams(
    /// The names the build declared (`brazier_codec.stream_names`).
    names: Set(String),
    limits: Limits,
    /// Every accepted op, applied in order.
    session: Windows,
    /// The keys each joined (or rejoining) connection's client holds.
    connections: Dict(String, Windows),
    /// The streams whose first op has been logged.
    seen: Set(String),
  )
}

/// The outcome of one update's ops.
pub type Update {
  Update(
    streams: Streams,
    /// The encoded `streams` array for each joined connection. A connection
    /// with no entry is sent `[]`.
    frames: Dict(String, String),
    /// The reasons of the `error` frames to send to the joined connections,
    /// one per refusal group. Each was logged at error.
    errors: List(String),
  )
}

/// The streams of a runtime whose build declared `names`. No op has run.
pub fn new(names: List(String), limits: Limits) -> Streams {
  Streams(
    names: set.from_list(names),
    limits: limits,
    session: stream_window.new(keep_items: True),
    connections: dict.new(),
    seen: set.new(),
  )
}

/// The `streams` array of `update` for `conn_id`: `[]` when the update
/// changed nothing that connection holds.
pub fn frame(update: Update, conn_id: String) -> String {
  case dict.get(update.frames, conn_id) {
    Ok(json) -> json
    Error(Nil) -> empty_frame
  }
}

/// Whether `update` sends a stream entry to any connection.
pub fn has_entries(update: Update) -> Bool {
  dict.size(update.frames) > 0
}

/// The `streams` array of `update` for `conn_id`, and `update` without it:
/// for a connection whose entries ride another frame than the update's
/// broadcast (a joiner's, in its join `model_sync`).
pub fn take_frame(update: Update, conn_id: String) -> #(String, Update) {
  #(
    frame(update, conn_id),
    Update(..update, frames: dict.delete(update.frames, conn_id)),
  )
}

/// The `streams` array of a frame that changes no stream.
pub const empty_frame = "[]"

/// Apply one update's `ops`, in order, to the session and to every
/// connection in `joined`. `cause` names the update in the logs (the
/// message's label, `"batch"`, `"init"`).
///
/// An op on a name the build did not declare is refused (`unknown_stream`);
/// the others go through `stream_window.apply_update`. An update over a
/// per-update bound, for the session or for any connection, refuses every
/// op: no window changes and no entry is sent.
pub fn apply(
  streams: Streams,
  ops: List(Op),
  joined: List(String),
  cause: String,
) -> Update {
  case ops {
    [] -> Update(streams: streams, frames: dict.new(), errors: [])
    _ -> {
      let #(known, unknown) =
        list.partition(ops, fn(op) { set.contains(streams.names, op.name) })
      let unknown_errors = refuse_unknown(unknown, cause)
      let #(update, errors) = apply_known(streams, known, joined, cause)
      Update(..update, errors: list.append(unknown_errors, errors))
    }
  }
}

/// The ops of `known` are on declared streams.
fn apply_known(
  streams: Streams,
  known: List(Op),
  joined: List(String),
  cause: String,
) -> #(Update, List(String)) {
  let unchanged = Update(streams: streams, frames: dict.new(), errors: [])
  case known {
    [] -> #(unchanged, [])
    _ ->
      case stream_window.apply_update(streams.session, known, streams.limits) {
        Error(refusal) -> #(
          unchanged,
          refuse_update(known, refusal, "the session", cause),
        )
        Ok(applied) -> {
          let op_errors = refuse_ops(known, applied.refused, cause)
          log_unknown_deletes(applied.unknown_deletes, cause)
          let accepted = without_refused(known, applied.refused)
          case apply_to_connections(streams, accepted, joined) {
            Error(#(conn_id, refusal)) -> #(
              unchanged,
              list.append(
                op_errors,
                refuse_update(
                  accepted,
                  refusal,
                  "connection " <> conn_id,
                  cause,
                ),
              ),
            )
            Ok(#(connections, sent)) -> {
              let seen =
                log_first_use(streams.seen, applied.windows, accepted, cause)
              let frames =
                list.fold(sent, dict.new(), fn(frames, entry) {
                  let #(conn_id, json, changes) = entry
                  report_changes(changes, conn_id, cause)
                  dict.insert(frames, conn_id, json)
                })
              #(
                Update(
                  streams: Streams(
                    ..streams,
                    session: applied.windows,
                    connections: connections,
                    seen: seen,
                  ),
                  frames: frames,
                  errors: [],
                ),
                op_errors,
              )
            }
          }
        }
      }
  }
}

/// Apply the accepted ops to every joined connection's windows. The
/// session accepted every op, so a connection refuses none of them; it can
/// only refuse the whole update, when its entries are over the frame
/// bound. Each connection with a change gets its `streams` array.
fn apply_to_connections(
  streams: Streams,
  accepted: List(Op),
  joined: List(String),
) -> Result(
  #(Dict(String, Windows), List(#(String, String, List(Change)))),
  #(String, UpdateRefusal),
) {
  case accepted {
    [] -> Ok(#(streams.connections, []))
    _ ->
      list.try_fold(joined, #(streams.connections, []), fn(acc, conn_id) {
        let #(connections, sent) = acc
        // Invariant: `join` gives every connection windows before the
        // runtime adds it to the joined set, and `forget` removes both.
        let assert Ok(windows) = dict.get(connections, conn_id)
          as "brazier/internal/stream_session: a joined connection has no stream windows"
        case stream_window.apply_update(windows, accepted, streams.limits) {
          Error(refusal) -> Error(#(conn_id, refusal))
          Ok(applied) -> {
            // Invariant: every op-level check depends on the op and the
            // stream's limit only, and the session accepted these ops with
            // the limits every window of the stream was made with.
            let assert [] = applied.refused
              as "brazier/internal/stream_session: a connection refused an op the session accepted"
            case applied.unknown_deletes {
              [] -> Nil
              unknown ->
                log.debug(
                  "brazier.stream",
                  "Connection "
                    <> conn_id
                    <> " does not hold "
                    <> int.to_string(list.length(unknown))
                    <> " deleted key(s) (it joined after they were sent); nothing sent for them",
                )
            }
            let connections = dict.insert(connections, conn_id, applied.windows)
            case applied.changes {
              [] -> Ok(#(connections, sent))
              changes ->
                Ok(
                  #(connections, [
                    #(conn_id, applied.streams_json, changes),
                    ..sent
                  ]),
                )
            }
          }
        }
      })
  }
}

/// Join `conn_id`. Returns the streams, the join `model_sync`'s `streams`
/// array for it, and the reasons of the `error` frames to send it.
///
/// - The runtime's first join: every window `init` and the messages before
///   the join filled is sent as a `reset` entry with its items, and the
///   items are dropped (7.2). Entries over the frame bound are refused:
///   the windows are emptied, since the client then holds nothing.
/// - A connection that already has windows (a rejoin on the same socket):
///   no item is kept to send again, so its windows stay and it is sent
///   `[]`; a rejoin while they hold keys is logged at warning.
/// - Any other join: the connection holds nothing yet.
///
/// The runtime joins a later connection (or a rejoin) before it applies the
/// join's route, so that the route's update is applied to its windows too;
/// the first join after its route, so that the route's items are in the
/// snapshot.
pub fn join(
  streams: Streams,
  conn_id: String,
) -> #(Streams, String, List(String)) {
  case dict.get(streams.connections, conn_id) {
    Ok(windows) -> {
      case stream_window.key_count(windows) {
        0 -> Nil
        count ->
          log.warning(
            "brazier.stream",
            "Rejoin from "
              <> conn_id
              <> " while its streams hold "
              <> int.to_string(count)
              <> " key(s); their items are not kept, so none is sent again",
          )
      }
      #(streams, empty_frame, [])
    }
    Error(Nil) ->
      case stream_window.snapshot(streams.session) {
        Error(ItemsNotKept) -> {
          log.debug(
            "brazier.stream",
            "Connection "
              <> conn_id
              <> " joins a live runtime; its streams start empty",
          )
          #(
            add_connection(
              streams,
              conn_id,
              stream_window.new(keep_items: False),
            ),
            empty_frame,
            [],
          )
        }
        Ok(#(deltas, keys_only)) ->
          first_join(streams, conn_id, deltas, keys_only)
      }
  }
}

/// The runtime's first join: send what the session kept since `init`.
fn first_join(
  streams: Streams,
  conn_id: String,
  deltas: List(Delta),
  keys_only: Windows,
) -> #(Streams, String, List(String)) {
  case stream_window.check_frame(deltas, streams.limits) {
    Ok(json) -> {
      case deltas {
        [] -> Nil
        _ ->
          log.info(
            "brazier.stream",
            "First join "
              <> conn_id
              <> ": sending "
              <> int.to_string(list.length(deltas))
              <> " stream(s) filled before the join; their items are no longer kept",
          )
      }
      list.each(deltas, fn(delta) {
        report_delta(delta, list.length(delta.inserts), 0, 0, conn_id, "join")
      })
      let streams = Streams(..streams, session: keys_only)
      #(add_connection(streams, conn_id, keys_only), json, [])
    }
    Error(refusal) -> {
      let error =
        refuse_snapshot(deltas, refusal, "the first join of " <> conn_id)
      let emptied = stream_window.emptied(keys_only)
      let streams = Streams(..streams, session: emptied)
      #(add_connection(streams, conn_id, emptied), empty_frame, [error])
    }
  }
}

fn add_connection(
  streams: Streams,
  conn_id: String,
  windows: Windows,
) -> Streams {
  Streams(
    ..streams,
    connections: dict.insert(streams.connections, conn_id, windows),
  )
}

/// `conn_id` joined but its join `model_sync` was not sent (the model was
/// over its size limit or not JSON), so its client holds no item: empty
/// its windows, keeping each stream's limit.
pub fn client_holds_nothing(streams: Streams, conn_id: String) -> Streams {
  case dict.get(streams.connections, conn_id) {
    Error(Nil) -> streams
    Ok(windows) -> {
      case stream_window.key_count(windows) {
        0 -> Nil
        count ->
          log.warning(
            "brazier.stream",
            "The join frame of "
              <> conn_id
              <> " was not sent; its "
              <> int.to_string(count)
              <> " stream key(s) are dropped from its windows",
          )
      }
      add_connection(streams, conn_id, stream_window.emptied(windows))
    }
  }
}

/// Drop the windows of a connection that left.
pub fn forget(streams: Streams, conn_id: String) -> Streams {
  Streams(..streams, connections: dict.delete(streams.connections, conn_id))
}

/// The keys `conn_id`'s windows hold for stream `name`, in order.
@internal
pub fn connection_keys(
  streams: Streams,
  conn_id: String,
  name: String,
) -> Result(List(String), Nil) {
  case dict.get(streams.connections, conn_id) {
    Ok(windows) -> stream_window.keys(windows, name)
    Error(Nil) -> Error(Nil)
  }
}

/// The keys the session holds for stream `name`, in order.
@internal
pub fn session_keys(
  streams: Streams,
  name: String,
) -> Result(List(String), Nil) {
  stream_window.keys(streams.session, name)
}

// --- Refusals ---------------------------------------------------------------

/// The refusals of one stream for one reason, in one update.
type Group {
  Group(
    stream: String,
    reason: String,
    count: Int,
    bytes: Int,
    description: String,
  )
}

/// Add one refused op to `groups` (most recent group first).
fn add_to_groups(
  groups: List(Group),
  stream: String,
  reason: String,
  bytes: Int,
  description: String,
) -> List(Group) {
  let #(found, groups) =
    list.fold(groups, #(False, []), fn(acc, group) {
      let #(found, kept) = acc
      case group.stream == stream && group.reason == reason {
        True -> #(True, [
          Group(..group, count: group.count + 1, bytes: group.bytes + bytes),
          ..kept
        ])
        False -> #(found, [group, ..kept])
      }
    })
  let groups = list.reverse(groups)
  case found {
    True -> groups
    False -> [
      Group(
        stream: stream,
        reason: reason,
        count: 1,
        bytes: bytes,
        description: description,
      ),
      ..groups
    ]
  }
}

/// Log and emit every group, oldest first, and return their error reasons.
fn report_groups(groups: List(Group), cause: String) -> List(String) {
  list.reverse(groups)
  |> list.map(fn(group) {
    log.error(
      "brazier.stream",
      "Refused "
        <> int.to_string(group.count)
        <> " op(s) on stream "
        <> group.stream
        <> " ("
        <> group.reason
        <> ", update for "
        <> cause
        <> "): "
        <> group.description,
    )
    telemetry.stream_refused(
      group.count,
      group.bytes,
      group.stream,
      group.reason,
    )
    "Stream "
    <> group.stream
    <> ": refused "
    <> int.to_string(group.count)
    <> " op(s): "
    <> group.description
  })
}

/// Ops on names the build did not declare (7.5).
fn refuse_unknown(unknown: List(Op), cause: String) -> List(String) {
  list.fold(unknown, [], fn(groups, op) {
    add_to_groups(
      groups,
      op.name,
      "unknown_stream",
      0,
      "the build declared no stream with this name",
    )
  })
  |> report_groups(cause)
}

/// The ops `apply_update` refused one by one.
fn refuse_ops(
  ops: List(Op),
  refused: List(OpRefusal),
  cause: String,
) -> List(String) {
  case refused {
    [] -> []
    _ -> {
      // Invariant: `apply_update` reports indices of ops of `ops`.
      let total = list.length(ops)
      let assert True =
        list.all(refused, fn(refusal) {
          refusal.index >= 0 && refusal.index < total
        })
        as "brazier/internal/stream_session: a refused op's index is outside the update"
      list.fold(refused, [], fn(groups, refusal) {
        add_to_groups(
          groups,
          refusal.stream,
          stream_window.op_reason_name(refusal.reason),
          reason_bytes(refusal),
          stream_window.describe_op_reason(refusal.reason),
        )
      })
      |> report_groups(cause)
    }
  }
}

/// The size an op refusal measured: the item or the key; 0 for a reason
/// that measures no size.
fn reason_bytes(refusal: OpRefusal) -> Int {
  case refusal.reason {
    ItemTooLarge(bytes, _) | KeyTooLarge(bytes, _) -> bytes
    _ -> 0
  }
}

/// Every op of an update was refused: one event per stream, one log line
/// and one error frame. `whose` names the windows that refused it.
fn refuse_update(
  ops: List(Op),
  refusal: UpdateRefusal,
  whose: String,
  cause: String,
) -> List(String) {
  let reason = stream_window.update_refusal_name(refusal)
  let bytes = case refusal {
    FrameTooLarge(bytes, _) -> bytes
    TooManyOps(..) -> 0
  }
  let counts = ops_per_stream(ops)
  log.error(
    "brazier.stream",
    "Refused every stream op of the update for "
      <> cause
      <> " ("
      <> reason
      <> ", for "
      <> whose
      <> ", "
      <> int.to_string(list.length(ops))
      <> " op(s) on "
      <> int.to_string(list.length(counts))
      <> " stream(s)): "
      <> stream_window.describe_update_refusal(refusal),
  )
  list.each(counts, fn(entry) {
    telemetry.stream_refused(entry.1, bytes, entry.0, reason)
  })
  [
    "Refused every stream op of the update: "
    <> stream_window.describe_update_refusal(refusal),
  ]
}

/// The first join's entries are over the frame bound.
fn refuse_snapshot(
  deltas: List(Delta),
  refusal: UpdateRefusal,
  whose: String,
) -> String {
  let reason = stream_window.update_refusal_name(refusal)
  let bytes = case refusal {
    FrameTooLarge(bytes, _) -> bytes
    TooManyOps(..) -> 0
  }
  log.error(
    "brazier.stream",
    "Refused the stream items kept before "
      <> whose
      <> " ("
      <> reason
      <> ", "
      <> int.to_string(list.length(deltas))
      <> " stream(s)); the streams start empty: "
      <> stream_window.describe_update_refusal(refusal),
  )
  list.each(deltas, fn(delta) {
    telemetry.stream_refused(
      list.length(delta.inserts),
      bytes,
      delta.name,
      reason,
    )
  })
  "Refused the stream items filled before the join: "
  <> stream_window.describe_update_refusal(refusal)
}

/// The number of ops of each stream, in order of first use.
fn ops_per_stream(ops: List(Op)) -> List(#(String, Int)) {
  list.fold(ops, [], fn(counts, op) {
    case list.key_find(counts, op.name) {
      Ok(count) -> list.key_set(counts, op.name, count + 1)
      Error(Nil) -> [#(op.name, 1), ..counts]
    }
  })
  |> list.reverse
}

/// `ops` without the refused ones.
fn without_refused(ops: List(Op), refused: List(OpRefusal)) -> List(Op) {
  case refused {
    [] -> ops
    _ -> {
      let indices = set.from_list(list.map(refused, fn(r) { r.index }))
      list.index_fold(ops, [], fn(kept, op, index) {
        case set.contains(indices, index) {
          True -> kept
          False -> [op, ..kept]
        }
      })
      |> list.reverse
    }
  }
}

// --- Logs and telemetry -----------------------------------------------------

/// Deletes of keys the session does not hold: a warning with a count per
/// stream. Keys can identify a user, so they are not logged.
fn log_unknown_deletes(
  unknown: List(stream_window.UnknownDelete),
  cause: String,
) -> Nil {
  case unknown {
    [] -> Nil
    _ -> {
      let counts =
        list.fold(unknown, [], fn(counts, delete) {
          case list.key_find(counts, delete.stream) {
            Ok(count) -> list.key_set(counts, delete.stream, count + 1)
            Error(Nil) -> [#(delete.stream, 1), ..counts]
          }
        })
        |> list.reverse
      list.each(counts, fn(entry) {
        log.warning(
          "brazier.stream",
          "Stream "
            <> entry.0
            <> ": "
            <> int.to_string(entry.1)
            <> " delete(s) of keys it does not hold (update for "
            <> cause
            <> "); nothing sent for them",
        )
      })
    }
  }
}

/// Log, at info, the first accepted op of each stream with the limit its
/// window was made with.
fn log_first_use(
  seen: Set(String),
  session: Windows,
  accepted: List(Op),
  cause: String,
) -> Set(String) {
  list.fold(accepted, seen, fn(seen, op) {
    case set.contains(seen, op.name) {
      True -> seen
      False -> {
        // Invariant: the session accepted `op`, so its stream has a window.
        let assert Ok(limit) = stream_window.limit(session, op.name)
          as "brazier/internal/stream_session: an accepted op's stream has no window"
        log.info(
          "brazier.stream",
          "Stream "
            <> op.name
            <> " first used with "
            <> stream_window.describe_limit(limit)
            <> " (update for "
            <> cause
            <> ")",
        )
        set.insert(seen, op.name)
      }
    }
  })
}

/// One `[brazier, stream, delta]` and one debug line per entry sent.
fn report_changes(
  changes: List(Change),
  conn_id: String,
  cause: String,
) -> Nil {
  list.each(changes, fn(change) {
    let inserts = list.length(change.delta.inserts) - change.updated
    report_delta(
      change.delta,
      inserts,
      change.updated,
      change.trimmed,
      conn_id,
      cause,
    )
  })
}

fn report_delta(
  delta: Delta,
  inserts: Int,
  updates: Int,
  trimmed: Int,
  conn_id: String,
  cause: String,
) -> Nil {
  let deletes = list.length(delta.deletes)
  let bytes = string.byte_size(stream_window.encode_delta(delta))
  log.debug(
    "brazier.stream",
    "Stream "
      <> delta.name
      <> " entry for "
      <> conn_id
      <> " ("
      <> cause
      <> "): reset="
      <> case delta.reset {
      True -> "true"
      False -> "false"
    }
      <> " inserts="
      <> int.to_string(inserts)
      <> " updates="
      <> int.to_string(updates)
      <> " deletes="
      <> int.to_string(deletes)
      <> " trimmed="
      <> int.to_string(trimmed)
      <> " bytes="
      <> int.to_string(bytes),
  )
  telemetry.stream_delta(
    inserts,
    updates,
    deletes,
    trimmed,
    bytes,
    delta.name,
    delta.reset,
    conn_id,
  )
}
