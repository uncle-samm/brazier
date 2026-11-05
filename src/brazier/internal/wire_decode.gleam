/// The decoders the generated codecs (`brazier/build/codec_gen`) read the
/// wire format with, on the server (`brazier_codec.decode_model` and
/// `decode_event`) and in the browser (`brazier_app_entry.decode_model`).
///
/// Each decoder is a plain function `fn(Dynamic) -> Result(a, DecodeError)`
/// over a parsed JSON value. It stops at the first failure and adds a path
/// segment to the error only on the way out of a failure, so a value that
/// decodes builds no error or path at all. `gleam/dynamic/decode` pushes a
/// path and keeps an error list on every step, which was about 40% of the
/// browser's time to decode a model after each patch.
///
/// The errors are `gleam/dynamic/decode` errors, with the same expected
/// names, found names (`dynamic.classify`) and paths as the first error the
/// standard decoders report for the same value:
///
/// - a scalar that does not match: `DecodeError("Int", "String", [])`;
/// - a missing object key: `DecodeError("Field", "Nothing", [key])`;
/// - a value that is not an object where one is read:
///   `DecodeError("Dict", found, [])`;
/// - a list element: its index as the path segment, a dict value its key, a
///   dict key `"keys"`.
///
/// The decoders read JSON values only: an object is a plain object on
/// JavaScript and a map on Erlang, an array a JavaScript array or an Erlang
/// list. On both targets an object's key must be its own key (a JavaScript
/// prototype key such as `toString` is missing), and an array where an
/// object is read is a `Dict` error.
///
/// Reference: Elm's `Json.Decode` and serde, which fail fast and build the
/// path of the failure while returning from it.
///
/// The JavaScript implementations are in `brazier_wire_decode_ffi.mjs`; the
/// Gleam bodies are the Erlang implementations, over the type checks in
/// `brazier_wire_decode_ffi.erl`.
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type DecodeError, DecodeError}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// A decoder of one value.
pub type Decoder(a) =
  fn(Dynamic) -> Result(a, DecodeError)

/// The error for `data` that is not the `expected` kind of value.
pub fn failure(expected: String, data: Dynamic) -> DecodeError {
  DecodeError(expected:, found: dynamic.classify(data), path: [])
}

/// A JSON integer.
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "int")
pub fn int(data: Dynamic) -> Result(Int, DecodeError) {
  case erlang_int(data) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error(failure("Int", data))
  }
}

/// A JSON number. An integer is accepted too, because JavaScript writes the
/// float `1.0` as `1`.
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "float")
pub fn float(data: Dynamic) -> Result(Float, DecodeError) {
  case erlang_float(data) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error(failure("Float", data))
  }
}

/// `true` or `false`.
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "bool")
pub fn bool(data: Dynamic) -> Result(Bool, DecodeError) {
  case erlang_bool(data) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error(failure("Bool", data))
  }
}

/// A JSON string.
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "string")
pub fn string(data: Dynamic) -> Result(String, DecodeError) {
  case erlang_string(data) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error(failure("String", data))
  }
}

/// `None` for `null`, otherwise `Some` of the value `inner` decodes. An
/// error of `inner` is returned unchanged, as `decode.optional` does.
pub fn optional(
  data: Dynamic,
  inner: Decoder(a),
) -> Result(Option(a), DecodeError) {
  case is_null(data) {
    True -> Ok(None)
    False ->
      case inner(data) {
        Ok(value) -> Ok(Some(value))
        Error(error) -> Error(error)
      }
  }
}

/// `value` when `data` is an object, for a record without fields: its
/// encoder writes `{}`.
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "object")
pub fn object(data: Dynamic, value: a) -> Result(a, DecodeError) {
  case erlang_is_object(data) {
    True -> Ok(value)
    False -> Error(failure("Dict", data))
  }
}

/// The value at `key` of an object, decoded with `inner`. An error of
/// `inner` gets `key` in front of its path.
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "field")
pub fn field(
  data: Dynamic,
  key: String,
  inner: Decoder(a),
) -> Result(a, DecodeError) {
  case erlang_object_get(data, key) {
    Ok(Some(value)) -> at(inner(value), key)
    Ok(None) ->
      Error(DecodeError(expected: "Field", found: "Nothing", path: [key]))
    Error(Nil) -> Error(failure("Dict", data))
  }
}

/// An array, every element decoded with `inner`. The first element that
/// fails is reported, with its index in front of its path.
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "list")
pub fn list(data: Dynamic, inner: Decoder(a)) -> Result(List(a), DecodeError) {
  case erlang_list(data) {
    Ok(items) -> list_loop(items, inner, 0, [])
    Error(Nil) -> Error(failure("List", data))
  }
}

fn list_loop(
  items: List(Dynamic),
  inner: Decoder(a),
  index: Int,
  acc: List(a),
) -> Result(List(a), DecodeError) {
  case items {
    [] -> Ok(list.reverse(acc))
    [item, ..rest] ->
      case inner(item) {
        Ok(value) -> list_loop(rest, inner, index + 1, [value, ..acc])
        Error(error) -> Error(push(error, int.to_string(index)))
      }
  }
}

/// Element `index` of an array of exactly `size` elements, decoded with
/// `inner`: one element of a tuple. Any other value, an array of another
/// length included, is an `array of <size> elements` error. An error of
/// `inner` gets the index in front of its path.
///
/// The generated tuple decoders call it with `0 <= index < size`; any other
/// index is a bug in them and crashes.
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "element")
pub fn element(
  data: Dynamic,
  index: Int,
  size: Int,
  inner: Decoder(a),
) -> Result(a, DecodeError) {
  let assert True = index >= 0 && index < size
    as "brazier/internal/wire_decode: element index outside the tuple"
  let expected = "array of " <> int.to_string(size) <> " elements"
  case erlang_list(data) {
    Ok(items) ->
      case list.length(items) == size, list.drop(items, index) {
        True, [item, ..] -> at(inner(item), int.to_string(index))
        _, _ -> Error(failure(expected, data))
      }
    Error(Nil) -> Error(failure(expected, data))
  }
}

/// An object as a `Dict(String, a)`, every value decoded with `inner`. The
/// first value that fails is reported, with its key in front of its path.
pub fn string_dict(
  data: Dynamic,
  inner: Decoder(a),
) -> Result(Dict(String, a), DecodeError) {
  entries(data, Ok, inner, dict.new(), dict.insert)
}

/// An object as a `Dict(Int, a)`. Every key must be the canonical decimal
/// form of an Int (`"7"`, `"-7"`; not `"07"` or `"+7"`), or the dict is an
/// `Int dict key` error at path `["keys"]`.
pub fn int_dict(
  data: Dynamic,
  inner: Decoder(a),
) -> Result(Dict(Int, a), DecodeError) {
  entries(data, int_key, inner, dict.new(), dict.insert)
}

fn int_key(text: String) -> Result(Int, DecodeError) {
  let refused =
    Error(DecodeError(expected: "Int dict key", found: "String", path: []))
  case int.parse(text) {
    Ok(value) ->
      case int.to_string(value) == text {
        True -> Ok(value)
        False -> refused
      }
    Error(Nil) -> refused
  }
}

/// The entries of an object, keys decoded with `key` and values with
/// `value`, inserted into `empty` with `insert`. A key error gets `"keys"`
/// in front of its path, a value error the key. `empty` and `insert` are
/// `dict.new()` and `dict.insert`, passed in so the JavaScript loop builds
/// the dict with the standard library's own functions.
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "entries")
fn entries(
  data: Dynamic,
  key: fn(String) -> Result(k, DecodeError),
  value: Decoder(v),
  empty: Dict(k, v),
  insert: fn(Dict(k, v), k, v) -> Dict(k, v),
) -> Result(Dict(k, v), DecodeError) {
  case erlang_entries(data) {
    Ok(pairs) -> entries_loop(pairs, key, value, empty, insert)
    Error(Nil) -> Error(failure("Dict", data))
  }
}

fn entries_loop(
  pairs: List(#(Dynamic, Dynamic)),
  key: fn(String) -> Result(k, DecodeError),
  value: Decoder(v),
  acc: Dict(k, v),
  insert: fn(Dict(k, v), k, v) -> Dict(k, v),
) -> Result(Dict(k, v), DecodeError) {
  case pairs {
    [] -> Ok(acc)
    [#(raw_key, raw_value), ..rest] -> {
      let decoded_key = case string(raw_key) {
        Ok(text) -> at(key(text), "keys") |> with_text(text)
        Error(error) -> Error(push(error, "keys"))
      }
      case decoded_key {
        Error(error) -> Error(error)
        Ok(#(decoded, text)) ->
          case value(raw_value) {
            Ok(decoded_value) ->
              entries_loop(
                rest,
                key,
                value,
                insert(acc, decoded, decoded_value),
                insert,
              )
            Error(error) -> Error(push(error, text))
          }
      }
    }
  }
}

fn with_text(
  result: Result(k, DecodeError),
  text: String,
) -> Result(#(k, String), DecodeError) {
  case result {
    Ok(decoded) -> Ok(#(decoded, text))
    Error(error) -> Error(error)
  }
}

/// `result` with `segment` in front of its error's path.
fn at(
  result: Result(a, DecodeError),
  segment: String,
) -> Result(a, DecodeError) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(push(error, segment))
  }
}

fn push(error: DecodeError, segment: String) -> DecodeError {
  DecodeError(..error, path: [segment, ..error.path])
}

/// `null`, as `decode.optional` reads it: JavaScript `null` and
/// `undefined`, Erlang `null`, `nil` and `undefined`.
@external(erlang, "brazier_wire_decode_ffi", "is_null")
@external(javascript, "../../brazier_wire_decode_ffi.mjs", "is_null")
fn is_null(data: Dynamic) -> Bool

@external(erlang, "brazier_wire_decode_ffi", "to_int")
fn erlang_int(data: Dynamic) -> Result(Int, Nil)

@external(erlang, "brazier_wire_decode_ffi", "to_float")
fn erlang_float(data: Dynamic) -> Result(Float, Nil)

@external(erlang, "brazier_wire_decode_ffi", "to_bool")
fn erlang_bool(data: Dynamic) -> Result(Bool, Nil)

@external(erlang, "brazier_wire_decode_ffi", "to_string")
fn erlang_string(data: Dynamic) -> Result(String, Nil)

@external(erlang, "brazier_wire_decode_ffi", "is_object")
fn erlang_is_object(data: Dynamic) -> Bool

/// `Ok(Some(value))` for a key of an object, `Ok(None)` for a missing key,
/// `Error(Nil)` when `data` is not an object.
@external(erlang, "brazier_wire_decode_ffi", "object_get")
fn erlang_object_get(data: Dynamic, key: String) -> Result(Option(Dynamic), Nil)

@external(erlang, "brazier_wire_decode_ffi", "to_list")
fn erlang_list(data: Dynamic) -> Result(List(Dynamic), Nil)

@external(erlang, "brazier_wire_decode_ffi", "to_entries")
fn erlang_entries(data: Dynamic) -> Result(List(#(Dynamic, Dynamic)), Nil)
