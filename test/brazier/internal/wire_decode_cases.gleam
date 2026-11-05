//// The cases of `wire_decode_test`, run on both targets: the test runs
//// them on Erlang and copies this module into a JavaScript project to run
//// them under node. It imports only `brazier/internal/wire_decode`, the
//// standard library and `gleam_json`, so that the copy compiles alone.
////
//// Every case is a decoder name, a JSON text and the result expected on
//// each target. A case with `parity` also runs the `gleam/dynamic/decode`
//// decoder the generated codecs used before `wire_decode` and expects its
//// first error (or its value) to be the same, so the error messages users
//// see did not change.

import brazier/internal/wire_decode
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type DecodeError}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/string

pub type Target {
  Erlang
  Javascript
}

/// Which targets the standard decoder gives the same result on.
pub type Parity {
  Both
  ErlangOnly
  Neither
}

pub type Case {
  Case(
    decoder: String,
    json: String,
    expected: String,
    javascript: Option(String),
    parity: Parity,
  )
}

/// The failure lines for `target`; empty when every case passes.
pub fn check_all(target: Target) -> List(String) {
  list.flat_map(cases(), fn(case_) { check(case_, target) })
}

fn check(case_: Case, target: Target) -> List(String) {
  let Case(decoder:, json: text, expected:, javascript:, parity:) = case_
  let expected = case target, javascript {
    Javascript, option.Some(override) -> override
    _, _ -> expected
  }
  let label = decoder <> " " <> text
  let wire = run(decoder, text, wire_decoder(decoder))
  let compare = case parity, target {
    Both, _ | ErlangOnly, Erlang -> True
    ErlangOnly, Javascript | Neither, _ -> False
  }
  let mismatch = case wire == expected {
    True -> []
    False -> [label <> ": expected " <> expected <> ", got " <> wire]
  }
  let standard = run(decoder, text, standard_decoder(decoder))
  let parity_mismatch = case compare && standard != wire {
    True -> [label <> ": gleam/dynamic/decode gives " <> standard]
    False -> []
  }
  list.append(mismatch, parity_mismatch)
}

fn run(
  decoder: String,
  text: String,
  decode_with: fn(Dynamic) -> Result(String, DecodeError),
) -> String {
  case json.parse(text, decode.dynamic) {
    Error(error) ->
      "bad json in case " <> decoder <> ": " <> string.inspect(error)
    Ok(data) ->
      case decode_with(data) {
        Ok(shown) -> "ok:" <> shown
        Error(error) -> show_error(error)
      }
  }
}

/// A target-independent rendering: `string.inspect` of a record shows its
/// labels on JavaScript only.
fn show_error(error: DecodeError) -> String {
  "error:"
  <> error.expected
  <> "/"
  <> error.found
  <> "/"
  <> string.join(error.path, ".")
}

/// `error:expected/found/path`
fn err(expected: String, found: String, path: String) -> String {
  "error:" <> expected <> "/" <> found <> "/" <> path
}

pub fn cases() -> List(Case) {
  let both = fn(decoder, json, expected) {
    Case(decoder:, json:, expected:, javascript: None, parity: Both)
  }
  // The found name of a JSON object and array differs between targets
  // (`dynamic.classify`): `Dict` and `List` on Erlang, `Object` and `Array`
  // on JavaScript.
  let split = fn(decoder, json, expected, javascript, parity) {
    Case(
      decoder:,
      json:,
      expected:,
      javascript: option.Some(javascript),
      parity:,
    )
  }
  let own = fn(decoder, json, expected) {
    Case(decoder:, json:, expected:, javascript: None, parity: Neither)
  }
  [
    both("int", "7", "ok:7"),
    both("int", "-12", "ok:-12"),
    both("int", "1.5", err("Int", "Float", "")),
    both("int", "\"7\"", err("Int", "String", "")),
    both("int", "null", err("Int", "Nil", "")),
    both("float", "1.5", "ok:1.5"),
    both("float", "2", "ok:2.0"),
    both("float", "true", err("Float", "Bool", "")),
    both("float", "\"1.5\"", err("Float", "String", "")),
    both("bool", "true", "ok:True"),
    both("bool", "false", "ok:False"),
    both("bool", "0", err("Bool", "Int", "")),
    both("bool", "null", err("Bool", "Nil", "")),
    both("string", "\"a\\u00e9\"", "ok:\"aé\""),
    both("string", "\"\"", "ok:\"\""),
    both("string", "1", err("String", "Int", "")),
    split(
      "string",
      "[]",
      err("String", "List", ""),
      err("String", "Array", ""),
      Both,
    ),
    both("option_int", "null", "ok:None"),
    both("option_int", "3", "ok:Some(3)"),
    both("option_int", "\"x\"", err("Int", "String", "")),
    both("list_int", "[1,2,3]", "ok:[1, 2, 3]"),
    both("list_int", "[]", "ok:[]"),
    both("list_int", "[1,\"x\",3]", err("Int", "String", "1")),
    both("list_int", "[1,2,null]", err("Int", "Nil", "2")),
    split(
      "list_int",
      "{}",
      err("List", "Dict", ""),
      err("List", "Object", ""),
      Both,
    ),
    both("list_int", "1", err("List", "Int", "")),
    both(
      "string_dict_int",
      "{\"a\":1,\"b\":2}",
      "ok:[#(\"a\", 1), #(\"b\", 2)]",
    ),
    both("string_dict_int", "{}", "ok:[]"),
    both("string_dict_int", "{\"a\":\"x\"}", err("Int", "String", "a")),
    both("string_dict_int", "1", err("Dict", "Int", "")),
    both("string_dict_int", "null", err("Dict", "Nil", "")),
    split(
      "string_dict_int",
      "[]",
      err("Dict", "List", ""),
      err("Dict", "Array", ""),
      Both,
    ),
    both(
      "int_dict_string",
      "{\"1\":\"a\",\"-2\":\"b\"}",
      "ok:[#(-2, \"b\"), #(1, \"a\")]",
    ),
    both("int_dict_string", "{\"0\":\"z\"}", "ok:[#(0, \"z\")]"),
    both(
      "int_dict_string",
      "{\"01\":\"a\"}",
      err("Int dict key", "String", "keys"),
    ),
    both(
      "int_dict_string",
      "{\"+1\":\"a\"}",
      err("Int dict key", "String", "keys"),
    ),
    both(
      "int_dict_string",
      "{\"-0\":\"a\"}",
      err("Int dict key", "String", "keys"),
    ),
    both(
      "int_dict_string",
      "{\"x\":\"a\"}",
      err("Int dict key", "String", "keys"),
    ),
    both(
      "int_dict_string",
      "{\"\":\"a\"}",
      err("Int dict key", "String", "keys"),
    ),
    both("int_dict_string", "{\"1\":2}", err("String", "Int", "1")),
    both("tuple_int_string", "[1,\"a\"]", "ok:#(1, \"a\")"),
    both("tuple_int_string", "[\"a\",\"b\"]", err("Int", "String", "0")),
    both("tuple_int_string", "[1,2]", err("String", "Int", "1")),
    // The length is checked before the elements. The generated standard
    // decoder read the elements first, so it reported a short array as a
    // missing element or a wrong element; a long one it reported the same.
    split(
      "tuple_int_string",
      "[1]",
      err("array of 2 elements", "List", ""),
      err("array of 2 elements", "Array", ""),
      Neither,
    ),
    split(
      "tuple_int_string",
      "[1,\"a\",3]",
      err("array of 2 elements", "List", ""),
      err("array of 2 elements", "Array", ""),
      Both,
    ),
    split(
      "tuple_int_string",
      "[\"a\"]",
      err("array of 2 elements", "List", ""),
      err("array of 2 elements", "Array", ""),
      Neither,
    ),
    split(
      "tuple_int_string",
      "{}",
      err("array of 2 elements", "Dict", ""),
      err("array of 2 elements", "Object", ""),
      Neither,
    ),
    own("tuple_int_string", "null", err("array of 2 elements", "Nil", "")),
    both(
      "record",
      "{\"count\":1,\"tags\":[\"a\"],\"note\":null}",
      "ok:#(1, [\"a\"], None)",
    ),
    both(
      "record",
      "{\"note\":\"n\",\"tags\":[],\"count\":-1,\"extra\":true}",
      "ok:#(-1, [], Some(\"n\"))",
    ),
    both(
      "record",
      "{\"tags\":[],\"note\":null}",
      err("Field", "Nothing", "count"),
    ),
    both("record", "{}", err("Field", "Nothing", "count")),
    both("record", "{\"count\":1,\"tags\":[]}", err("Field", "Nothing", "note")),
    both(
      "record",
      "{\"count\":\"1\",\"tags\":[],\"note\":null}",
      err("Int", "String", "count"),
    ),
    both(
      "record",
      "{\"count\":1,\"tags\":[\"a\",2],\"note\":null}",
      err("String", "Int", "tags.1"),
    ),
    both(
      "record",
      "{\"count\":1,\"tags\":[],\"note\":5}",
      err("String", "Int", "note"),
    ),
    both("record", "null", err("Dict", "Nil", "")),
    both("record", "3", err("Dict", "Int", "")),
    // An array is not an object: on JavaScript the standard decoders read
    // an array as an object that lacks the field (`Field`, `Nothing`).
    split(
      "record",
      "[]",
      err("Dict", "List", ""),
      err("Dict", "Array", ""),
      ErlangOnly,
    ),
    both(
      "rows",
      "[{\"id\":1,\"label\":\"a\"},{\"id\":2,\"label\":\"b\"}]",
      "ok:[#(1, \"a\"), #(2, \"b\")]",
    ),
    both(
      "rows",
      "[{\"id\":1,\"label\":\"a\"},{\"id\":\"2\",\"label\":\"b\"}]",
      err("Int", "String", "1.id"),
    ),
    both(
      "rows",
      "[{\"id\":1,\"label\":\"a\"},{\"id\":2}]",
      err("Field", "Nothing", "1.label"),
    ),
    split(
      "rows",
      "[{\"id\":1,\"label\":\"a\"},[]]",
      err("Dict", "List", "1"),
      err("Dict", "Array", "1"),
      ErlangOnly,
    ),
    // A record without fields is written `{}` and read only from an
    // object; the standard decoders accepted any value for it.
    own("empty_record", "{}", "ok:Empty"),
    own("empty_record", "{\"x\":1}", "ok:Empty"),
    own("empty_record", "null", err("Dict", "Nil", "")),
    own("empty_record", "\"{}\"", err("Dict", "String", "")),
    split(
      "empty_record",
      "[]",
      err("Dict", "List", ""),
      err("Dict", "Array", ""),
      Neither,
    ),
    // Only an object's own keys are fields: the standard decoders find a
    // JavaScript prototype method such as `toString`.
    Case(
      decoder: "proto",
      json: "{}",
      expected: err("Field", "Nothing", "toString"),
      javascript: None,
      parity: ErlangOnly,
    ),
    both("proto", "{\"toString\":3}", "ok:3"),
  ]
}

fn wire_decoder(name: String) -> fn(Dynamic) -> Result(String, DecodeError) {
  case name {
    "int" -> shown(wire_decode.int, int.to_string)
    "float" -> shown(wire_decode.float, float.to_string)
    "bool" -> shown(wire_decode.bool, string.inspect)
    "string" -> shown(wire_decode.string, string.inspect)
    "option_int" ->
      shown(
        fn(data) { wire_decode.optional(data, wire_decode.int) },
        string.inspect,
      )
    "list_int" ->
      shown(
        fn(data) { wire_decode.list(data, wire_decode.int) },
        string.inspect,
      )
    "string_dict_int" ->
      shown(
        fn(data) { wire_decode.string_dict(data, wire_decode.int) },
        sorted_entries,
      )
    "int_dict_string" ->
      shown(
        fn(data) { wire_decode.int_dict(data, wire_decode.string) },
        sorted_entries,
      )
    "tuple_int_string" -> shown(wire_tuple, string.inspect)
    "record" -> shown(wire_record, string.inspect)
    "rows" ->
      shown(fn(data) { wire_decode.list(data, wire_row) }, string.inspect)
    "empty_record" ->
      shown(fn(data) { wire_decode.object(data, "Empty") }, fn(s) { s })
    "proto" ->
      shown(
        fn(data) { wire_decode.field(data, "toString", wire_decode.int) },
        int.to_string,
      )
    _ -> fn(_data) {
      Error(decode.DecodeError("a known case decoder", name, []))
    }
  }
}

/// The decoders `brazier/build/codec_gen` generated before `wire_decode`,
/// with their first error.
fn standard_decoder(
  name: String,
) -> fn(Dynamic) -> Result(String, DecodeError) {
  case name {
    "int" -> standard(decode.int, int.to_string)
    "float" ->
      standard(
        decode.one_of(decode.float, [decode.map(decode.int, int.to_float)]),
        float.to_string,
      )
    "bool" -> standard(decode.bool, string.inspect)
    "string" -> standard(decode.string, string.inspect)
    "option_int" -> standard(decode.optional(decode.int), string.inspect)
    "list_int" -> standard(decode.list(decode.int), string.inspect)
    "string_dict_int" ->
      standard(decode.dict(decode.string, decode.int), sorted_entries)
    "int_dict_string" ->
      standard(decode.dict(standard_int_key(), decode.string), sorted_entries)
    "tuple_int_string" -> {
      // The elements, then the length, as the generated decoder read them.
      let decoder = {
        use first <- decode.subfield([0], decode.int)
        use second <- decode.subfield([1], decode.string)
        use items <- decode.then(decode.list(decode.dynamic))
        case list.length(items) == 2 {
          True -> decode.success(#(first, second))
          False -> decode.failure(#(first, second), "array of 2 elements")
        }
      }
      standard(decoder, string.inspect)
    }
    "record" -> {
      let decoder = {
        use count <- decode.field("count", decode.int)
        use tags <- decode.field("tags", decode.list(decode.string))
        use note <- decode.field("note", decode.optional(decode.string))
        decode.success(#(count, tags, note))
      }
      standard(decoder, string.inspect)
    }
    "rows" -> standard(decode.list(standard_row()), string.inspect)
    "empty_record" -> standard(decode.success("Empty"), fn(s) { s })
    "proto" ->
      standard(
        decode.field("toString", decode.int, decode.success),
        int.to_string,
      )
    _ -> fn(_data) {
      Error(decode.DecodeError("a known case decoder", name, []))
    }
  }
}

fn standard_int_key() -> decode.Decoder(Int) {
  use text <- decode.then(decode.string)
  case int.parse(text) {
    Ok(value) ->
      case int.to_string(value) == text {
        True -> decode.success(value)
        False -> decode.failure(0, "Int dict key")
      }
    Error(Nil) -> decode.failure(0, "Int dict key")
  }
}

fn standard_row() -> decode.Decoder(#(Int, String)) {
  use id <- decode.field("id", decode.int)
  use label <- decode.field("label", decode.string)
  decode.success(#(id, label))
}

fn wire_tuple(data: Dynamic) -> Result(#(Int, String), DecodeError) {
  case wire_decode.element(data, 0, 2, wire_decode.int) {
    Error(error) -> Error(error)
    Ok(first) ->
      case wire_decode.element(data, 1, 2, wire_decode.string) {
        Error(error) -> Error(error)
        Ok(second) -> Ok(#(first, second))
      }
  }
}

fn wire_record(
  data: Dynamic,
) -> Result(#(Int, List(String), Option(String)), DecodeError) {
  case wire_decode.field(data, "count", wire_decode.int) {
    Error(error) -> Error(error)
    Ok(count) ->
      case
        wire_decode.field(data, "tags", fn(tags) {
          wire_decode.list(tags, wire_decode.string)
        })
      {
        Error(error) -> Error(error)
        Ok(tags) ->
          case
            wire_decode.field(data, "note", fn(note) {
              wire_decode.optional(note, wire_decode.string)
            })
          {
            Error(error) -> Error(error)
            Ok(note) -> Ok(#(count, tags, note))
          }
      }
  }
}

fn wire_row(data: Dynamic) -> Result(#(Int, String), DecodeError) {
  case wire_decode.field(data, "id", wire_decode.int) {
    Error(error) -> Error(error)
    Ok(id) ->
      case wire_decode.field(data, "label", wire_decode.string) {
        Error(error) -> Error(error)
        Ok(label) -> Ok(#(id, label))
      }
  }
}

fn shown(
  decoder: fn(Dynamic) -> Result(a, DecodeError),
  show: fn(a) -> String,
) -> fn(Dynamic) -> Result(String, DecodeError) {
  fn(data) {
    case decoder(data) {
      Ok(value) -> Ok(show(value))
      Error(error) -> Error(error)
    }
  }
}

fn standard(
  decoder: decode.Decoder(a),
  show: fn(a) -> String,
) -> fn(Dynamic) -> Result(String, DecodeError) {
  fn(data) {
    case decode.run(data, decoder) {
      Ok(value) -> Ok(show(value))
      Error([first, ..]) -> Error(first)
      Error([]) ->
        Error(
          decode.DecodeError("an error from a failed decode.run", "none", []),
        )
    }
  }
}

/// A dict's entries in key order: the iteration order of a dict differs
/// between the targets.
fn sorted_entries(entries: dict.Dict(k, v)) -> String {
  dict.to_list(entries)
  |> list.sort(fn(a, b) {
    string.compare(string.inspect(a.0), string.inspect(b.0))
  })
  |> string.inspect
}
