//// Streams: a keyed list of items the server sends once and does not keep
//// (docs/design/STREAMS.md). A chat log, a feed or an agent's output
//// grows without the model holding every item: `update` returns ops that
//// insert, update, delete or reset items, the runtime sends the change, and
//// the client keeps the items, at most the stream's limit of them.
////
//// Declare each stream once, in a `pub fn`, so `update` and `view` share
//// it:
////
//// ```gleam
//// import brazier/stream.{type Stream}
//// import gleam/dynamic/decode
//// import gleam/json
////
//// pub type Line {
////   Line(id: String, text: String)
//// }
////
//// pub fn log() -> Stream(Line) {
////   stream.new(
////     "log",
////     key: fn(line: Line) { line.id },
////     encode: fn(line: Line) {
////       json.object([
////         #("id", json.string(line.id)),
////         #("text", json.string(line.text)),
////       ])
////     },
////     decoder: {
////       use id <- decode.field("id", decode.string)
////       use text <- decode.field("text", decode.string)
////       decode.success(Line(id:, text:))
////     },
////     limit: stream.KeepLast(300),
////   )
//// }
//// ```
////
//// Each op calls the stream's `key` and `encode` when it is called, so it
//// holds the item's key and JSON text, never the item.
////
//// Each op function returns an `Effect(msg)`. Ops compose with
//// `effect.batch`, in order, and `effect.map` passes them through, so a
//// child module's ops reach its parent. `effect.keyed` and
//// `effect.cancellable` do not key them: an op is applied when its update
//// returns. `emitted` lists the ops an effect carries, for tests.
////
//// `render` puts the stream in the view: a container element whose
//// children are the stream's items, each rendered by a named top-level
//// function of the item (docs/design/STREAMS.md 5.3):
////
//// ```gleam
//// import brazier/element.{type Element}
//// import brazier/html
//// import brazier/stream.{type Stream}
////
//// pub type Line {
////   Line(id: String, text: String)
//// }
////
//// pub fn view(log: Stream(Line)) -> Element(msg) {
////   html.main([], [stream.render(log, "ol", [], render_line)])
//// }
////
//// pub fn render_line(line: Line) -> Element(msg) {
////   html.li([], [html.text(line.text)])
//// }
//// ```

import brazier/attribute.{type Attribute}
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/internal/render
import brazier/internal/stream_op
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

/// A keyed stream of items of one type, made by `new`.
pub opaque type Stream(item) {
  Stream(
    name: String,
    key: fn(item) -> String,
    encode: fn(item) -> json.Json,
    decoder: decode.Decoder(item),
    limit: Limit,
  )
}

/// Which end a full stream keeps. With `KeepLast(300)` an append past 300
/// items drops the oldest one at the front (LiveView `limit: -300`); with
/// `KeepFirst(300)` a prepend past 300 drops the last one (LiveView
/// `limit: 300`). An append into a full `KeepFirst` stream, or a prepend
/// into a full `KeepLast` one, drops the new item itself.
pub type Limit {
  KeepFirst(Int)
  KeepLast(Int)
}

/// Where a new item goes. An item whose key is in the stream stays where
/// it is and is updated in place.
pub type Position {
  Append
  Prepend
}

/// One stream op, for app unit tests: the stream's name, the item's key
/// and its encoded JSON text.
pub type Emitted {
  Inserted(stream: String, key: String, json: String, at: Position)
  Deleted(stream: String, key: String)
  Reset(stream: String, items: List(#(String, String)))
}

/// Declare a stream. The name identifies it on the wire and in the page.
///
/// Crashes, as `attribute.attribute` does for a bad name, when `name` is
/// not 1 to 64 characters of `a-z`, `0-9` and `_` starting with a letter,
/// or when the limit is below 1. The largest limit is a server bound
/// (1000 by default): a stream over it has its ops refused and logged by
/// the runtime.
///
/// ```gleam
/// stream.new(
///   "log",
///   key: fn(line: Line) { line.id },
///   encode: encode_line,
///   decoder: line_decoder(),
///   limit: stream.KeepLast(300),
/// )
/// ```
pub fn new(
  name: String,
  key key: fn(item) -> String,
  encode encode: fn(item) -> json.Json,
  decoder decoder: decode.Decoder(item),
  limit limit: Limit,
) -> Stream(item) {
  let assert True = is_valid_name(name)
    as "brazier/stream.new: a stream name must be 1 to 64 characters of a-z, 0-9 and _, starting with a letter"
  let assert True = limit_count(limit) >= 1
    as "brazier/stream.new: a stream limit must be at least 1"
  Stream(name:, key:, encode:, decoder:, limit:)
}

/// The stream's name.
pub fn name(stream: Stream(item)) -> String {
  stream.name
}

/// The stream's limit.
pub fn limit(stream: Stream(item)) -> Limit {
  stream.limit
}

/// The key the stream gives `item`.
pub fn key(stream: Stream(item), item: item) -> String {
  stream.key(item)
}

/// Insert `item` at `position`, or update it in place when its key is in
/// the stream.
///
/// ```gleam
/// stream.insert(log(), Line(id: "7", text: "done"), at: stream.Append)
/// ```
pub fn insert(
  stream: Stream(item),
  item: item,
  at position: Position,
) -> Effect(msg) {
  effect.from_stream_ops([
    insert_op(stream, stream.key(item), encode(stream, item), position),
  ])
}

/// Insert several items: `Append` keeps the list's order at the end,
/// `Prepend` puts the list's first item first. When a key appears twice in
/// `items`, it takes the place of its first appearance and the item of its
/// last, as one insert.
///
/// ```gleam
/// stream.insert_many(log(), [first, second], at: stream.Prepend)
/// // The stream now starts with first, then second.
/// ```
pub fn insert_many(
  stream: Stream(item),
  items: List(item),
  at position: Position,
) -> Effect(msg) {
  let entries = unique_entries(stream, items)
  // Prepending one by one puts the last prepended first, so the list is
  // prepended from its end.
  let entries = case position {
    Append -> entries
    Prepend -> list.reverse(entries)
  }
  effect.from_stream_ops(
    list.map(entries, fn(entry) {
      insert_op(stream, entry.0, entry.1, position)
    }),
  )
}

/// Delete the item with `item`'s key. A key not in the stream changes
/// nothing; the runtime logs it at warning.
pub fn delete(stream: Stream(item), item: item) -> Effect(msg) {
  delete_key(stream, stream.key(item))
}

/// Delete the item with `key` (LiveView `stream_delete_by_dom_id/3`).
pub fn delete_key(stream: Stream(item), key: String) -> Effect(msg) {
  effect.from_stream_ops([
    stream_op.Op(
      name: stream.name,
      limit: to_op_limit(stream.limit),
      action: stream_op.Delete(key),
    ),
  ])
}

/// Empty the stream, then insert `items` in order at the end.
/// `reset(stream, [])` empties it. A key that appears twice is one item, as
/// in `insert_many`.
pub fn reset(stream: Stream(item), items: List(item)) -> Effect(msg) {
  effect.from_stream_ops([
    stream_op.Op(
      name: stream.name,
      limit: to_op_limit(stream.limit),
      action: stream_op.Reset(unique_entries(stream, items)),
    ),
  ])
}

/// The stream's container: a `tag` element holding the stream's items, in
/// order, each rendered by `item` with its root keyed by the stream's key
/// (LiveView's `phx-update="stream"` container).
///
/// `item` must be a named top-level function, not an anonymous `fn` or a
/// capture: an item is rendered when it is inserted or updated, never
/// again, so it can depend on the item only. Its root must be one element,
/// not text, `element.none()`, `unsafe_raw_html` or `element.keyed`. A view
/// renders a stream at most once and never inside another stream's item;
/// a second render of the same stream crashes the render. The build checks
/// the rest (docs/design/STREAMS.md 5.3).
///
/// ```gleam
/// stream.render(log(), "ol", [attribute.class("log")], render_line)
/// ```
pub fn render(
  stream: Stream(item),
  tag: String,
  attributes: List(Attribute(msg)),
  item: fn(item) -> Element(msg),
) -> Element(msg) {
  let assert True = render.is_valid_tag_name(tag)
    as "brazier/stream.render: tag names are a-z A-Z 0-9 - _ : ."
  let decoder = stream.decoder
  element.from_node(render.Stream(
    name: stream.name,
    limit: to_op_limit(stream.limit),
    tag: tag,
    attributes: list.map(attributes, attribute.to_attr),
    item: fn(value: Dynamic) {
      case decode.run(value, decoder) {
        Ok(decoded) -> Ok(element.to_node(item(decoded)))
        Error(errors) ->
          Error(
            "the stream's decoder refused the item: "
            <> string.join(list.map(errors, describe_decode_error), "; "),
          )
      }
    },
    item_ref: render.item_ref(item),
  ))
}

/// The stream ops an effect carries, in the order they are applied: an
/// `insert_many` with `Prepend` lists its items from the last. The
/// effect's other callbacks are ignored.
///
/// ```gleam
/// stream.emitted(stream.delete_key(log(), "7"))
/// // -> [stream.Deleted(stream: "log", key: "7")]
/// ```
pub fn emitted(effect: Effect(msg)) -> List(Emitted) {
  let #(ops, _rest) = effect.take_stream_ops(effect)
  list.map(ops, fn(op) {
    case op.action {
      stream_op.Insert(key, json, at) ->
        Inserted(stream: op.name, key: key, json: json, at: case at {
          stream_op.Back -> Append
          stream_op.Front -> Prepend
        })
      stream_op.Delete(key) -> Deleted(stream: op.name, key: key)
      stream_op.Reset(items) -> Reset(stream: op.name, items: items)
    }
  })
}

/// Encode `item` and decode it again with the stream's decoder, so a test
/// can check the stream's codec. The error describes the decode failure.
pub fn round_trip(stream: Stream(item), item: item) -> Result(item, String) {
  case json.parse(encode(stream, item), stream.decoder) {
    Ok(decoded) -> Ok(decoded)
    Error(error) -> Error(describe_json_error(error))
  }
}

/// A public limit as the internal one.
@internal
pub fn to_op_limit(limit: Limit) -> stream_op.Limit {
  case limit {
    KeepFirst(count) -> stream_op.Limit(keep: stream_op.First, count: count)
    KeepLast(count) -> stream_op.Limit(keep: stream_op.Last, count: count)
  }
}

fn insert_op(
  stream: Stream(item),
  key: String,
  json: String,
  position: Position,
) -> stream_op.Op {
  let at = case position {
    Append -> stream_op.Back
    Prepend -> stream_op.Front
  }
  stream_op.Op(
    name: stream.name,
    limit: to_op_limit(stream.limit),
    action: stream_op.Insert(key: key, json: json, at: at),
  )
}

fn encode(stream: Stream(item), item: item) -> String {
  json.to_string(stream.encode(item))
}

/// `#(key, json)` of each item, one per key: at the key's first place, with
/// its last item.
fn unique_entries(
  stream: Stream(item),
  items: List(item),
) -> List(#(String, String)) {
  let #(order, latest) =
    list.fold(items, #([], dict.new()), fn(acc, item) {
      let #(order, latest) = acc
      let key = stream.key(item)
      let order = case dict.has_key(latest, key) {
        True -> order
        False -> [key, ..order]
      }
      #(order, dict.insert(latest, key, encode(stream, item)))
    })
  list.reverse(order)
  |> list.map(fn(key) {
    // Invariant: every key in `order` was put in `latest` with it.
    let assert Ok(json) = dict.get(latest, key)
      as "brazier/stream: a batch key has no item"
    #(key, json)
  })
}

fn limit_count(limit: Limit) -> Int {
  case limit {
    KeepFirst(count) -> count
    KeepLast(count) -> count
  }
}

/// The rule `new` asserts, which the build checks too on every literal name
/// (`brazier/build/analyzer`).
@internal
pub fn is_valid_name(name: String) -> Bool {
  case string.to_utf_codepoints(name) |> list.map(string.utf_codepoint_to_int) {
    [] -> False
    [first, ..rest] ->
      string.length(name) <= 64
      && is_lower(first)
      && list.all(rest, fn(c) { is_lower(c) || is_digit(c) || c == 95 })
  }
}

fn is_lower(c: Int) -> Bool {
  c >= 97 && c <= 122
}

fn is_digit(c: Int) -> Bool {
  c >= 48 && c <= 57
}

fn describe_json_error(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "the encoded item is not complete JSON"
    json.UnexpectedByte(byte) ->
      "the encoded item has an unexpected byte " <> byte
    json.UnexpectedSequence(sequence) ->
      "the encoded item has an unexpected sequence " <> sequence
    json.UnableToDecode(errors) ->
      "the decoder refused the encoded item: "
      <> string.join(list.map(errors, describe_decode_error), "; ")
  }
}

fn describe_decode_error(error: decode.DecodeError) -> String {
  let path = case error.path {
    [] -> "the item"
    path -> string.join(path, ".")
  }
  "expected " <> error.expected <> " at " <> path <> ", found " <> error.found
}
