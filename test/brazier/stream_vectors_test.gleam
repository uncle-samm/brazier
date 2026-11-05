//// The shared stream vectors, `test/fixtures/stream_vectors.json`, checked
//// on the server. The browser client's stream applier reads the same file
//// (the `format` field and docs/design/STREAMS.md 13 describe it).
////
//// The file holds two lists:
////
//// - `deltas`: `{name, stream, keep, limit, before, ops, entry, after}`. A
////   stream with `keep` (`"first"` or `"last"`) and `limit` holds `before`
////   (`[{key, item}]`). The server applies `ops` in one update, each one of
////   `{"op": "insert", key, at: "append" | "prepend", item}`,
////   `{"op": "delete", key}` or `{"op": "reset", items: [{key, item}]}`.
////   `entry` is the wire entry of section 6.1 it sends for the stream, or
////   `null` when it sends none. A client store holding `before` that
////   applies `entry` holds `after`.
//// - `faults`: `{name, stream, keep, limit, before, entry, reason}`. A
////   client store for `stream` with `keep` and `limit` holding `before`
////   that applies `entry` faults (section 6.2) with `reason`, one of
////   `malformed`, `unknown_stream`, `keep_mismatch`, `limit_mismatch`,
////   `delete_unknown_key`, `insert_wrong_index`, `insert_past_end`,
////   `over_limit`.
////
//// Items are JSON values and compare as values. Here each vector is
//// checked three ways: the server's window applied to `ops` gives the
//// entry and `after`'s keys; the reference applier (`stream_reference`)
//// applied to `entry` gives `after`; every fault faults with its reason.

import brazier/internal/stream_op.{Op}
import brazier/internal/stream_window
import brazier/stream_reference.{type Store, Store}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import simplifile

const vectors_path = "test/fixtures/stream_vectors.json"

type DeltaVector {
  DeltaVector(
    name: String,
    stream: String,
    limit: stream_op.Limit,
    before: List(#(String, String)),
    ops: List(stream_op.Action),
    entry: Result(Dynamic, Nil),
    after: List(#(String, String)),
  )
}

type FaultVector {
  FaultVector(
    name: String,
    stream: String,
    limit: stream_op.Limit,
    before: List(#(String, String)),
    entry: Dynamic,
    reason: String,
  )
}

fn read_vectors() -> #(List(DeltaVector), List(FaultVector)) {
  let assert Ok(text) = simplifile.read(vectors_path)
  let decoder = {
    use format <- decode.field("format", decode.string)
    use deltas <- decode.field("deltas", decode.list(delta_vector_decoder()))
    use faults <- decode.field("faults", decode.list(fault_vector_decoder()))
    decode.success(#(format, deltas, faults))
  }
  let assert Ok(#(_format, deltas, faults)) = json.parse(text, decoder)
  #(deltas, faults)
}

fn limit_decoder() -> decode.Decoder(stream_op.Limit) {
  use keep <- decode.field("keep", decode.string)
  use count <- decode.field("limit", decode.int)
  case keep {
    "first" -> decode.success(stream_op.Limit(stream_op.First, count))
    "last" -> decode.success(stream_op.Limit(stream_op.Last, count))
    _ -> decode.failure(stream_op.Limit(stream_op.Last, count), "first or last")
  }
}

fn item_decoder() -> decode.Decoder(#(String, String)) {
  use key <- decode.field("key", decode.string)
  use item <- decode.field("item", decode.dynamic)
  decode.success(#(key, stream_reference.encode_dynamic(item)))
}

fn action_decoder() -> decode.Decoder(stream_op.Action) {
  use op <- decode.field("op", decode.string)
  case op {
    "insert" -> {
      use key <- decode.field("key", decode.string)
      use at <- decode.field("at", decode.string)
      use item <- decode.field("item", decode.dynamic)
      let json = stream_reference.encode_dynamic(item)
      case at {
        "append" -> decode.success(stream_op.Insert(key, json, stream_op.Back))
        "prepend" ->
          decode.success(stream_op.Insert(key, json, stream_op.Front))
        _ -> decode.failure(stream_op.Delete(key), "append or prepend")
      }
    }
    "delete" -> {
      use key <- decode.field("key", decode.string)
      decode.success(stream_op.Delete(key))
    }
    "reset" -> {
      use items <- decode.field("items", decode.list(item_decoder()))
      decode.success(stream_op.Reset(items))
    }
    _ -> decode.failure(stream_op.Delete(""), "insert, delete or reset")
  }
}

fn delta_vector_decoder() -> decode.Decoder(DeltaVector) {
  use name <- decode.field("name", decode.string)
  use stream <- decode.field("stream", decode.string)
  use limit <- decode.then(limit_decoder())
  use before <- decode.field("before", decode.list(item_decoder()))
  use ops <- decode.field("ops", decode.list(action_decoder()))
  use entry <- decode.field("entry", decode.optional(decode.dynamic))
  use after <- decode.field("after", decode.list(item_decoder()))
  let entry = option.to_result(entry, Nil)
  decode.success(DeltaVector(
    name:,
    stream:,
    limit:,
    before:,
    ops:,
    entry:,
    after:,
  ))
}

fn fault_vector_decoder() -> decode.Decoder(FaultVector) {
  use name <- decode.field("name", decode.string)
  use stream <- decode.field("stream", decode.string)
  use limit <- decode.then(limit_decoder())
  use before <- decode.field("before", decode.list(item_decoder()))
  use entry <- decode.field("entry", decode.dynamic)
  use reason <- decode.field("reason", decode.string)
  decode.success(FaultVector(name:, stream:, limit:, before:, entry:, reason:))
}

fn store(
  stream: String,
  limit: stream_op.Limit,
  items: List(#(String, String)),
) -> Store {
  Store(
    name: stream,
    keep: stream_op.keep_to_string(limit.keep),
    limit: limit.count,
    items: items,
  )
}

pub fn vectors_cover_every_fault_reason_test() {
  let #(deltas, faults) = read_vectors()
  let assert True = list.length(deltas) >= 15
  let reasons = list.map(faults, fn(fault) { fault.reason }) |> list.unique
  let assert True =
    list.sort(reasons, string.compare)
    == list.sort(
      [
        "malformed", "unknown_stream", "keep_mismatch", "limit_mismatch",
        "delete_unknown_key", "insert_wrong_index", "insert_past_end",
        "over_limit",
      ],
      string.compare,
    )
}

pub fn server_sends_each_vector_entry_test() {
  let #(deltas, _) = read_vectors()
  list.each(deltas, fn(vector) {
    let op = fn(action) {
      Op(name: vector.stream, limit: vector.limit, action:)
    }
    let limits = stream_window.default_limits()
    let assert Ok(seeded) =
      stream_window.apply_update(
        stream_window.new(keep_items: False),
        [op(stream_op.Reset(vector.before))],
        limits,
      )
    let assert Ok(applied) =
      stream_window.apply_update(
        seeded.windows,
        list.map(vector.ops, op),
        limits,
      )
      as vector.name
    let assert [] = applied.refused as vector.name
    let sent = case applied.changes {
      [] -> Error(Nil)
      [change] -> {
        let assert Ok(value) =
          json.parse(stream_window.encode_delta(change.delta), decode.dynamic)
          as vector.name
        Ok(value)
      }
      _ -> panic as "stream_vectors_test: more than one entry for one stream"
    }
    let assert True = sent == vector.entry as vector.name
    let assert Ok(keys) = stream_window.keys(applied.windows, vector.stream)
    let assert True = keys == list.map(vector.after, fn(item) { item.0 })
      as vector.name
  })
}

pub fn reference_applier_reaches_each_vector_after_test() {
  let #(deltas, _) = read_vectors()
  list.each(deltas, fn(vector) {
    let before = store(vector.stream, vector.limit, vector.before)
    let after = case vector.entry {
      Error(Nil) -> before
      Ok(entry) -> {
        let assert Ok(entry) = stream_reference.decode_entry(entry)
          as vector.name
        let assert Ok(after) = stream_reference.apply_entry(before, entry)
          as vector.name
        after
      }
    }
    let assert True = after.items == vector.after as vector.name
  })
}

pub fn reference_applier_faults_each_fault_vector_test() {
  let #(_, faults) = read_vectors()
  list.each(faults, fn(vector) {
    let before = store(vector.stream, vector.limit, vector.before)
    let result = case stream_reference.decode_entry(vector.entry) {
      Error(reason) -> Error(reason)
      Ok(entry) -> stream_reference.apply_entry(before, entry)
    }
    let assert True = result == Error(vector.reason) as vector.name
  })
}

/// The window never sends an entry that faults: every vector's ops,
/// applied by the server, give an entry the reference applier accepts.
pub fn server_entries_never_fault_test() {
  let #(deltas, _) = read_vectors()
  list.each(deltas, fn(vector) {
    let op = fn(action) {
      Op(name: vector.stream, limit: vector.limit, action:)
    }
    let limits = stream_window.default_limits()
    let assert Ok(seeded) =
      stream_window.apply_update(
        stream_window.new(keep_items: False),
        [op(stream_op.Reset(vector.before))],
        limits,
      )
    let assert Ok(applied) =
      stream_window.apply_update(
        seeded.windows,
        list.map(vector.ops, op),
        limits,
      )
    let assert Ok(entries) =
      json.parse(applied.streams_json, decode.dynamic)
      |> fn(parsed) {
        let assert Ok(value) = parsed as vector.name
        stream_reference.decode_streams(value)
      }
    let before = store(vector.stream, vector.limit, vector.before)
    let after =
      list.fold(entries, before, fn(current, entry) {
        let assert Ok(next) = stream_reference.apply_entry(current, entry)
          as vector.name
        next
      })
    let assert True = after.items == vector.after as vector.name
  })
}
