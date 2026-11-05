//// Test-side references for stream windows: a naive model of the window
//// rules (docs/design/STREAMS.md 7.3) and an applier of wire entries that
//// follows the client rules of section 6.2, faults included. The property
//// test and the shared vectors check `brazier/internal/stream_window`
//// against both; the browser client's applier will be checked against the
//// same vectors.

import brazier/internal/stream_op
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/result

/// A client store: the stream's declared limit and its items, in order,
/// as `#(key, item_json)`.
pub type Store {
  Store(name: String, keep: String, limit: Int, items: List(#(String, String)))
}

/// A decoded wire entry. Insert items are JSON text.
pub type Entry {
  Entry(
    name: String,
    keep: String,
    limit: Int,
    reset: Bool,
    deletes: List(String),
    inserts: List(#(String, Int, String)),
  )
}

/// Encode a decoded JSON value as JSON text. Maps are written in key
/// order, so equal values give equal text.
@external(erlang, "brazier_stream_test_ffi", "encode_term")
pub fn encode_dynamic(value: Dynamic) -> String

/// Decode one wire entry, or `Error("malformed")`.
pub fn decode_entry(value: Dynamic) -> Result(Entry, String) {
  decode.run(value, entry_decoder())
  |> result.replace_error("malformed")
}

/// Decode a wire `streams` array.
pub fn decode_streams(value: Dynamic) -> Result(List(Entry), String) {
  decode.run(value, decode.list(entry_decoder()))
  |> result.replace_error("malformed")
}

fn entry_decoder() -> decode.Decoder(Entry) {
  use name <- decode.field("name", decode.string)
  use keep <- decode.field("keep", keep_decoder())
  use limit <- decode.field("limit", limit_decoder())
  use reset <- decode.field("reset", decode.bool)
  use deletes <- decode.field("deletes", decode.list(decode.string))
  use inserts <- decode.field("inserts", decode.list(insert_decoder()))
  decode.success(Entry(name:, keep:, limit:, reset:, deletes:, inserts:))
}

fn keep_decoder() -> decode.Decoder(String) {
  use keep <- decode.then(decode.string)
  case keep {
    "first" | "last" -> decode.success(keep)
    _ -> decode.failure(keep, "first or last")
  }
}

fn limit_decoder() -> decode.Decoder(Int) {
  use limit <- decode.then(decode.int)
  case limit >= 1 && limit <= 1000 {
    True -> decode.success(limit)
    False -> decode.failure(limit, "a limit from 1 to 1000")
  }
}

fn insert_decoder() -> decode.Decoder(#(String, Int, String)) {
  use key <- decode.field("key", decode.string)
  use at <- decode.field("at", decode.int)
  use item <- decode.field("item", decode.dynamic)
  decode.success(#(key, at, encode_dynamic(item)))
}

/// Apply one entry to a store as the client does (section 6.2): reset,
/// then deletes, then inserts in order. `Error(reason)` is a stream fault.
pub fn apply_entry(store: Store, entry: Entry) -> Result(Store, String) {
  use <- guard(entry.name != store.name, "unknown_stream")
  use <- guard(entry.keep != store.keep, "keep_mismatch")
  use <- guard(entry.limit != store.limit, "limit_mismatch")
  let items = case entry.reset {
    True -> []
    False -> store.items
  }
  use items <- result.try(
    list.try_fold(entry.deletes, items, fn(items, key) {
      case list.key_find(items, key) {
        Ok(_) -> Ok(list.filter(items, fn(item) { item.0 != key }))
        Error(Nil) -> Error("delete_unknown_key")
      }
    }),
  )
  use items <- result.try(
    list.try_fold(entry.inserts, items, fn(items, insert) {
      let #(key, at, json) = insert
      case index_of(items, key) {
        Ok(index) if index == at -> Ok(replace(items, key, json))
        Ok(_) -> Error("insert_wrong_index")
        Error(Nil) ->
          case at < 0 || at > list.length(items) {
            True -> Error("insert_past_end")
            False ->
              Ok(
                list.flatten([
                  list.take(items, at),
                  [#(key, json)],
                  list.drop(items, at),
                ]),
              )
          }
      }
    }),
  )
  use <- guard(list.length(items) > store.limit, "over_limit")
  Ok(Store(..store, items: items))
}

fn guard(
  fault: Bool,
  reason: String,
  next: fn() -> Result(Store, String),
) -> Result(Store, String) {
  case fault {
    True -> Error(reason)
    False -> next()
  }
}

fn index_of(items: List(#(String, String)), key: String) -> Result(Int, Nil) {
  list.index_fold(items, Error(Nil), fn(found, item, index) {
    case found, item.0 == key {
      Ok(_), _ -> found
      Error(Nil), True -> Ok(index)
      Error(Nil), False -> found
    }
  })
}

fn replace(
  items: List(#(String, String)),
  key: String,
  json: String,
) -> List(#(String, String)) {
  list.map(items, fn(item) {
    case item.0 == key {
      True -> #(key, json)
      False -> item
    }
  })
}

/// The naive window: items in order, and the number of items trimmed.
pub type Model {
  Model(limit: stream_op.Limit, items: List(#(String, String)), trimmed: Int)
}

/// Apply one action to the naive window. The `Bool` is whether it was a
/// delete of a key the window did not hold.
pub fn model_apply(model: Model, action: stream_op.Action) -> #(Model, Bool) {
  case action {
    stream_op.Insert(key, json, at) -> #(
      model_insert(model, key, json, at),
      False,
    )
    stream_op.Delete(key) ->
      case list.key_find(model.items, key) {
        Ok(_) -> #(
          Model(..model, items: list.filter(model.items, fn(i) { i.0 != key })),
          False,
        )
        Error(Nil) -> #(model, True)
      }
    stream_op.Reset(items) -> #(
      list.fold(items, Model(..model, items: []), fn(model, item) {
        model_insert(model, item.0, item.1, stream_op.Back)
      }),
      False,
    )
  }
}

fn model_insert(
  model: Model,
  key: String,
  json: String,
  at: stream_op.End,
) -> Model {
  case list.key_find(model.items, key) {
    Ok(_) -> Model(..model, items: replace(model.items, key, json))
    Error(Nil) -> {
      let grown = case at {
        stream_op.Back -> list.append(model.items, [#(key, json)])
        stream_op.Front -> [#(key, json), ..model.items]
      }
      case list.length(grown) > model.limit.count {
        False -> Model(..model, items: grown)
        True -> {
          // Trim one item from the end the limit drops.
          let items = case model.limit.keep {
            stream_op.Last -> list.drop(grown, 1)
            stream_op.First -> list.take(grown, model.limit.count)
          }
          Model(..model, items: items, trimmed: model.trimmed + 1)
        }
      }
    }
  }
}
