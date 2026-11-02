/// JSON encoders and decoders for resolved field types, built with
/// `beacon/build/gleam_code`. Shared by the server codec and the client entry
/// module so both sides of the wire use one encoding.
///
/// Wire format:
/// - `Int`, `Float`, `Bool`, `String`: JSON scalars. Decoding a `Float`
///   also accepts a JSON integer, because JavaScript prints `1.0` as `1`.
/// - `Option(a)`: the value, or `null`.
/// - `List(a)`: an array.
/// - `Dict(String, a)` and `Dict(Int, a)`: an object. Int keys are written in
///   canonical decimal form, and any other key is rejected when decoding.
/// - `#(a, b, ..)`: an array with exactly one element per tuple element.
/// - a record: an object keyed by field label.
/// - an enum: the lowercased variant name. Unknown names are rejected.
///
/// Every helper the encoders and decoders call is generated once per type,
/// and only when something reachable from the given roots uses it, so the
/// generated module has no unused functions.
import beacon/build/field_type.{type FieldType, type TypeDef}
import beacon/build/gleam_code.{
  type Definition, type Expr, type Import, type Stmt, type TypeExpr, Arg, Call,
  Case, Clause, Ctor, ExprStmt, FieldAccess, FnExpr, Function, Import, IntLit,
  ListExpr, PCtor, PDiscard, PString, PVar, Param, Ref, Str, TNamed, TupleExpr,
  TupleIndex, Use, Var,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// Aliases the generated modules import the standard library under. They are
/// prefixed so they can never clash with a user module's alias.
pub const json = "beacon_json"

pub const decode = "beacon_decode"

pub const int_module = "beacon_int"

pub const list_module = "beacon_list"

pub const element = "beacon_element"

pub const result_module = "beacon_result"

pub const string_module = "beacon_string"

/// The standard imports generated modules may use. `gleam_code.render` drops
/// the ones a module does not reference.
pub fn std_imports() -> List(Import) {
  [
    Import("beacon/element", Some(element)),
    Import("gleam/dynamic/decode", Some(decode)),
    Import("gleam/int", Some(int_module)),
    Import("gleam/json", Some(json)),
    Import("gleam/list", Some(list_module)),
    Import("gleam/result", Some(result_module)),
    Import("gleam/string", Some(string_module)),
  ]
}

/// The import for a user module: `import path`, or `import path as alias`
/// when the alias is not the path's last segment.
pub fn module_import(path: String, alias: String) -> Import {
  case field_type.last_segment(path) {
    Ok(last) if last == alias -> Import(path, None)
    _ -> Import(path, Some(alias))
  }
}

/// What the generators need to know about the analyzed app.
pub type Codecs {
  Codecs(
    /// Every user type, keyed by #(canonical module alias, name); the app
    /// module's alias is "".
    type_defs: Dict(#(String, String), TypeDef),
    /// The alias the generated module imports the app module under.
    app_qualifier: String,
  )
}

/// The alias generated code refers to a type's module by.
pub fn qualifier(codecs: Codecs, module: String) -> String {
  case module {
    "" -> codecs.app_qualifier
    _ -> module
  }
}

/// `q.Name` as a type annotation.
pub fn named_type(codecs: Codecs, module: String, name: String) -> TypeExpr {
  TNamed(Some(qualifier(codecs, module)), name, [])
}

/// `beacon_json.Json`
pub fn json_type() -> TypeExpr {
  TNamed(Some(json), "Json", [])
}

pub fn string_type() -> TypeExpr {
  TNamed(None, "String", [])
}

pub fn nil_type() -> TypeExpr {
  TNamed(None, "Nil", [])
}

pub fn bool_type() -> TypeExpr {
  TNamed(None, "Bool", [])
}

/// `Result(ok, String)`
pub fn result_type(ok: TypeExpr) -> TypeExpr {
  TNamed(None, "Result", [ok, string_type()])
}

pub fn true_() -> Expr {
  Ctor(None, "True")
}

pub fn false_() -> Expr {
  Ctor(None, "False")
}

pub fn nil() -> Expr {
  Ctor(None, "Nil")
}

pub fn ok(value: Expr) -> Expr {
  Call(Ctor(None, "Ok"), [Arg(value)])
}

pub fn error(value: Expr) -> Expr {
  Call(Ctor(None, "Error"), [Arg(value)])
}

/// `Ok(name)` as a pattern.
pub fn ok_pattern(name: String) -> gleam_code.Pattern {
  PCtor(None, "Ok", [PVar(name)], False)
}

/// `Error(_)` as a pattern.
pub fn error_pattern() -> gleam_code.Pattern {
  PCtor(None, "Error", [PDiscard("")], False)
}

/// `Error(name)` as a pattern.
pub fn error_pattern_named(name: String) -> gleam_code.Pattern {
  PCtor(None, "Error", [PVar(name)], False)
}

pub fn json_call(name: String, args: List(Expr)) -> Expr {
  Call(Ref(Some(json), name), list.map(args, Arg))
}

pub fn decode_call(name: String, args: List(Expr)) -> Expr {
  Call(Ref(Some(decode), name), list.map(args, Arg))
}

/// `beacon_json.to_string(value)`
pub fn json_to_string(value: Expr) -> Expr {
  json_call("to_string", [value])
}

/// `beacon_json.object([#("key", value), ..])`
pub fn json_object(entries: List(#(String, Expr))) -> Expr {
  json_call("object", [
    ListExpr(
      list.map(entries, fn(entry) { TupleExpr([Str(entry.0), entry.1]) }),
    ),
  ])
}

/// `use name <- beacon_decode.field("key", decoder)`
pub fn decode_field(name: String, key: String, decoder: Expr) -> Stmt {
  Use([name], decode_call("field", [Str(key), decoder]))
}

/// `beacon_decode.success(value)`
pub fn decode_success(value: Expr) -> Expr {
  decode_call("success", [value])
}

/// The local variable a decoded record field is bound to. The prefix keeps
/// it apart from the module aliases and from the generator's own names.
pub fn field_var(label: String) -> String {
  "beacon_v_" <> label
}

// ===== Encoding =====

/// An expression encoding `value`, of type `type_`, to `beacon_json.Json`.
pub fn encode(
  codecs: Codecs,
  type_: FieldType,
  value: Expr,
) -> Result(Expr, String) {
  encode_at(codecs, type_, value, 0)
}

fn encode_at(
  codecs: Codecs,
  type_: FieldType,
  value: Expr,
  depth: Int,
) -> Result(Expr, String) {
  case type_ {
    field_type.IntType -> Ok(json_call("int", [value]))
    field_type.FloatType -> Ok(json_call("float", [value]))
    field_type.BoolType -> Ok(json_call("bool", [value]))
    field_type.StringType -> Ok(json_call("string", [value]))
    field_type.OptionType(inner) -> {
      use of <- result.map(encoder_fn(codecs, inner, depth))
      json_call("nullable", [value, of])
    }
    field_type.ListType(inner) -> {
      use of <- result.map(encoder_fn(codecs, inner, depth))
      json_call("array", [value, of])
    }
    field_type.DictType(key, inner) -> {
      use keys <- result.try(key_encoder(key, depth))
      use values <- result.map(encoder_fn(codecs, inner, depth))
      json_call("dict", [value, keys, values])
    }
    field_type.TupleType(elements) -> {
      use encoded <- result.map(
        list.index_map(elements, fn(element, index) { #(index, element) })
        |> list.try_map(fn(entry) {
          encode_at(codecs, entry.1, TupleIndex(value, entry.0), depth)
        }),
      )
      json_call("preprocessed_array", [ListExpr(encoded)])
    }
    field_type.NamedType(module:, name:) -> {
      use Nil <- result.map(require_def(codecs, module, name))
      Call(Ref(None, helper_name("encode", module, name)), [Arg(value)])
    }
    field_type.UnsupportedType(reason) -> Error(unsupported(reason))
  }
}

/// A function value encoding one `type_`, for `nullable`, `array` and `dict`.
fn encoder_fn(
  codecs: Codecs,
  type_: FieldType,
  depth: Int,
) -> Result(Expr, String) {
  case type_ {
    field_type.IntType -> Ok(Ref(Some(json), "int"))
    field_type.FloatType -> Ok(Ref(Some(json), "float"))
    field_type.BoolType -> Ok(Ref(Some(json), "bool"))
    field_type.StringType -> Ok(Ref(Some(json), "string"))
    field_type.NamedType(module:, name:) -> {
      use Nil <- result.map(require_def(codecs, module, name))
      Ref(None, helper_name("encode", module, name))
    }
    _ -> {
      let var = "beacon_x" <> int.to_string(depth)
      use body <- result.map(encode_at(codecs, type_, Var(var), depth + 1))
      FnExpr([var], [ExprStmt(body)])
    }
  }
}

fn key_encoder(key: FieldType, depth: Int) -> Result(Expr, String) {
  case key {
    field_type.StringType -> {
      let var = "beacon_k" <> int.to_string(depth)
      Ok(FnExpr([var], [ExprStmt(Var(var))]))
    }
    field_type.IntType -> Ok(Ref(Some(int_module), "to_string"))
    _ -> Error(unsupported_key(key))
  }
}

// ===== Decoding =====

/// An expression of type `beacon_decode.Decoder(t)` for `type_`.
pub fn decoder(codecs: Codecs, type_: FieldType) -> Result(Expr, String) {
  decoder_at(codecs, type_, 0)
}

fn decoder_at(
  codecs: Codecs,
  type_: FieldType,
  depth: Int,
) -> Result(Expr, String) {
  case type_ {
    field_type.IntType -> Ok(Ref(Some(decode), "int"))
    field_type.BoolType -> Ok(Ref(Some(decode), "bool"))
    field_type.StringType -> Ok(Ref(Some(decode), "string"))
    field_type.FloatType ->
      Ok(
        decode_call("one_of", [
          Ref(Some(decode), "float"),
          ListExpr([
            decode_call("map", [
              Ref(Some(decode), "int"),
              Ref(Some(int_module), "to_float"),
            ]),
          ]),
        ]),
      )
    field_type.OptionType(inner) -> {
      use inner <- result.map(decoder_at(codecs, inner, depth + 1))
      decode_call("optional", [inner])
    }
    field_type.ListType(inner) -> {
      use inner <- result.map(decoder_at(codecs, inner, depth + 1))
      decode_call("list", [inner])
    }
    field_type.DictType(key, inner) -> {
      use keys <- result.try(key_decoder(key, depth))
      use values <- result.map(decoder_at(codecs, inner, depth + 1))
      decode_call("dict", [keys, values])
    }
    field_type.TupleType(elements) -> tuple_decoder(codecs, elements, depth)
    field_type.NamedType(module:, name:) -> {
      use Nil <- result.map(require_def(codecs, module, name))
      Call(Ref(None, helper_name("decode", module, name)), [])
    }
    field_type.UnsupportedType(reason) -> Error(unsupported(reason))
  }
}

/// Object keys are JSON strings. An Int key must be the canonical decimal
/// form of an Int, so `"01"` or `"+1"` is rejected instead of being read as 1.
fn key_decoder(key: FieldType, depth: Int) -> Result(Expr, String) {
  case key {
    field_type.StringType -> Ok(Ref(Some(decode), "string"))
    field_type.IntType -> {
      let raw = "beacon_key" <> int.to_string(depth)
      let parsed = "beacon_n" <> int.to_string(depth)
      let reject = decode_call("failure", [IntLit(0), Str("Int dict key")])
      Ok(
        gleam_code.Block([
          Use([raw], decode_call("then", [Ref(Some(decode), "string")])),
          ExprStmt(
            Case([Call(Ref(Some(int_module), "parse"), [Arg(Var(raw))])], [
              Clause(
                [ok_pattern(parsed)],
                Case(
                  [
                    gleam_code.BinOp(
                      gleam_code.Equal,
                      Call(Ref(Some(int_module), "to_string"), [
                        Arg(Var(parsed)),
                      ]),
                      Var(raw),
                    ),
                  ],
                  [
                    Clause(
                      [PCtor(None, "True", [], False)],
                      decode_success(Var(parsed)),
                    ),
                    Clause([PCtor(None, "False", [], False)], reject),
                  ],
                ),
              ),
              Clause(
                [PCtor(None, "Error", [PCtor(None, "Nil", [], False)], False)],
                reject,
              ),
            ]),
          ),
        ]),
      )
    }
    _ -> Error(unsupported_key(key))
  }
}

/// A tuple is an array with exactly one element per tuple element. The
/// elements are decoded by index, then the length is checked so extra
/// elements are rejected rather than ignored.
fn tuple_decoder(
  codecs: Codecs,
  elements: List(FieldType),
  depth: Int,
) -> Result(Expr, String) {
  let size = list.length(elements)
  use Nil <- result.try(case size >= 2 && size <= field_type.max_tuple_size {
    True -> Ok(Nil)
    False ->
      Error(
        "Invariant violated: tuple of "
        <> int.to_string(size)
        <> " elements reached code generation; the analyzer accepts 2 to "
        <> int.to_string(field_type.max_tuple_size),
      )
  })
  let prefix = "beacon_e" <> int.to_string(depth) <> "_"
  let items = "beacon_items" <> int.to_string(depth)
  use uses <- result.map(
    list.index_map(elements, fn(element, index) { #(index, element) })
    |> list.try_map(fn(entry) {
      let #(index, element) = entry
      use element_decoder <- result.map(decoder_at(codecs, element, depth + 1))
      Use(
        [prefix <> int.to_string(index)],
        decode_call("subfield", [ListExpr([IntLit(index)]), element_decoder]),
      )
    }),
  )
  let values =
    TupleExpr(
      list.index_map(elements, fn(_, index) {
        Var(prefix <> int.to_string(index))
      }),
    )
  let expected = "array of " <> int.to_string(size) <> " elements"
  gleam_code.Block(
    list.append(uses, [
      Use(
        [items],
        decode_call("then", [
          decode_call("list", [Ref(Some(decode), "dynamic")]),
        ]),
      ),
      ExprStmt(
        Case(
          [
            gleam_code.BinOp(
              gleam_code.Equal,
              Call(Ref(Some(list_module), "length"), [Arg(Var(items))]),
              IntLit(size),
            ),
          ],
          [
            Clause([PCtor(None, "True", [], False)], decode_success(values)),
            Clause(
              [PCtor(None, "False", [], False)],
              decode_call("failure", [values, Str(expected)]),
            ),
          ],
        ),
      ),
    ]),
  )
}

// ===== Helpers for user types =====

/// The helper functions the encoders of `encode_roots` and the decoders of
/// `decode_roots` call, each generated once, sorted by name.
pub fn helpers(
  codecs: Codecs,
  encode_roots: List(FieldType),
  decode_roots: List(FieldType),
) -> Result(List(Definition), String) {
  use encode_types <- result.try(reachable(codecs, encode_roots))
  use decode_types <- result.try(reachable(codecs, decode_roots))
  use encoders <- result.try(
    list.try_map(encode_types, fn(key) { encoder_helper(codecs, key.0, key.1) }),
  )
  use decoders <- result.map(
    list.try_map(decode_types, fn(key) { decoder_helper(codecs, key.0, key.1) }),
  )
  list.append(encoders, decoders)
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

/// Every user type reachable from `roots` through record fields, in a
/// stable order.
fn reachable(
  codecs: Codecs,
  roots: List(FieldType),
) -> Result(List(#(String, String)), String) {
  let start = list.flat_map(roots, field_type.named_types)
  use seen <- result.map(walk(codecs, start, set.new()))
  set.to_list(seen)
  |> list.sort(fn(a, b) { string.compare(a.0 <> "." <> a.1, b.0 <> "." <> b.1) })
}

fn walk(
  codecs: Codecs,
  pending: List(#(String, String)),
  seen: Set(#(String, String)),
) -> Result(Set(#(String, String)), String) {
  case pending {
    [] -> Ok(seen)
    [key, ..rest] ->
      case set.contains(seen, key) {
        True -> walk(codecs, rest, seen)
        False -> {
          use def <- result.try(lookup(codecs, key.0, key.1))
          let next = case def {
            field_type.RecordDef(fields:, ..) ->
              list.flat_map(fields, fn(f) { field_type.named_types(f.1) })
            _ -> []
          }
          walk(codecs, list.append(next, rest), set.insert(seen, key))
        }
      }
  }
}

fn encoder_helper(
  codecs: Codecs,
  module: String,
  name: String,
) -> Result(Definition, String) {
  let q = qualifier(codecs, module)
  let fn_name = helper_name("encode", module, name)
  let param_type = named_type(codecs, module, name)
  use def <- result.try(lookup(codecs, module, name))
  case def {
    field_type.RecordDef(fields: [], ..) ->
      Ok(
        Function(
          fn_name,
          False,
          [],
          [Param("_beacon_value", param_type)],
          json_type(),
          [ExprStmt(json_object([]))],
        ),
      )
    field_type.RecordDef(fields:, ..) -> {
      use entries <- result.map(
        list.try_map(fields, fn(f) {
          let #(label, type_) = f
          use encoded <- result.map(encode(
            codecs,
            type_,
            FieldAccess(Var("beacon_value"), label),
          ))
          #(label, encoded)
        }),
      )
      Function(
        fn_name,
        False,
        [],
        [Param("beacon_value", param_type)],
        json_type(),
        [ExprStmt(json_object(entries))],
      )
    }
    field_type.EnumDef(variants) -> {
      use Nil <- result.map(check_enum_names(module, name, variants))
      Function(
        fn_name,
        False,
        [],
        [Param("beacon_value", param_type)],
        json_type(),
        [
          ExprStmt(Case(
            [Var("beacon_value")],
            list.map(variants, fn(variant) {
              Clause(
                [PCtor(Some(q), variant, [], False)],
                json_call("string", [Str(field_type.enum_wire_name(variant))]),
              )
            }),
          )),
        ],
      )
    }
    field_type.AliasDef(..) | field_type.UnsupportedDef(..) ->
      Error(not_generatable(module, name, def))
  }
}

fn decoder_helper(
  codecs: Codecs,
  module: String,
  name: String,
) -> Result(Definition, String) {
  let q = qualifier(codecs, module)
  let fn_name = helper_name("decode", module, name)
  let return =
    TNamed(Some(decode), "Decoder", [named_type(codecs, module, name)])
  use def <- result.try(lookup(codecs, module, name))
  case def {
    field_type.RecordDef(constructor:, fields:) -> {
      use body <- result.map(record_decoder_body(
        codecs,
        module,
        constructor,
        fields,
      ))
      Function(fn_name, False, [], [], return, body)
    }
    field_type.EnumDef(variants: [first, ..] as variants) -> {
      use Nil <- result.map(check_enum_names(module, name, variants))
      let clauses =
        list.map(variants, fn(variant) {
          Clause(
            [PString(field_type.enum_wire_name(variant))],
            decode_success(Ctor(Some(q), variant)),
          )
        })
      let reject =
        Clause(
          [PDiscard("")],
          decode_call("failure", [
            Ctor(Some(q), first),
            Str(field_type.qualified_name(module, name)),
          ]),
        )
      Function(fn_name, False, [], [], return, [
        Use(["beacon_tag"], decode_call("then", [Ref(Some(decode), "string")])),
        ExprStmt(Case([Var("beacon_tag")], list.append(clauses, [reject]))),
      ])
    }
    field_type.EnumDef(variants: []) ->
      Error(
        "Invariant violated: enum "
        <> field_type.qualified_name(module, name)
        <> " has no variants",
      )
    field_type.AliasDef(..) | field_type.UnsupportedDef(..) ->
      Error(not_generatable(module, name, def))
  }
}

/// The statements of a decoder for a record: one `decode.field` per label,
/// then `decode.success` of the constructor.
pub fn record_decoder_body(
  codecs: Codecs,
  module: String,
  constructor: String,
  fields: List(#(String, FieldType)),
) -> Result(List(Stmt), String) {
  use uses <- result.map(field_decoders(codecs, fields))
  list.append(uses, [
    ExprStmt(decode_success(construct(codecs, module, constructor, fields))),
  ])
}

/// `use beacon_v_label <- beacon_decode.field("label", decoder)` for each
/// field, in order.
pub fn field_decoders(
  codecs: Codecs,
  fields: List(#(String, FieldType)),
) -> Result(List(Stmt), String) {
  list.try_map(fields, fn(f) {
    let #(label, type_) = f
    use field_decoder <- result.map(decoder(codecs, type_))
    decode_field(field_var(label), label, field_decoder)
  })
}

/// `case beacon_json.parse(input, decoder) { Ok(name) -> on_ok  pattern -> on_error }`
pub fn parse_json(
  input: Expr,
  decoder: Expr,
  on_ok: #(String, Expr),
  on_error: #(gleam_code.Pattern, Expr),
) -> Expr {
  Case([json_call("parse", [input, decoder])], [
    Clause([ok_pattern(on_ok.0)], on_ok.1),
    Clause([on_error.0], on_error.1),
  ])
}

/// `q.Ctor(label: beacon_v_label, ..)`, or `q.Ctor` without fields.
pub fn construct(
  codecs: Codecs,
  module: String,
  constructor: String,
  fields: List(#(String, FieldType)),
) -> Expr {
  let ctor = Ctor(Some(qualifier(codecs, module)), constructor)
  case fields {
    [] -> ctor
    _ ->
      Call(
        ctor,
        list.map(fields, fn(f) { gleam_code.Labelled(f.0, Var(field_var(f.0))) }),
      )
  }
}

/// The record definition of a root type such as Model or Local.
pub fn record(
  codecs: Codecs,
  module: String,
  name: String,
) -> Result(#(String, List(#(String, FieldType))), String) {
  use def <- result.try(lookup(codecs, module, name))
  case def {
    field_type.RecordDef(constructor:, fields:) -> Ok(#(constructor, fields))
    _ ->
      Error(
        "Invariant violated: "
        <> field_type.qualified_name(module, name)
        <> " must be a record with one constructor to be generated",
      )
  }
}

/// `encode_type__<name>` for app types, `encode_type__<alias>__<name>` for
/// types from other modules.
pub fn helper_name(kind: String, module: String, name: String) -> String {
  case module {
    "" -> kind <> "_type__" <> snake_case(name)
    _ -> kind <> "_type__" <> module <> "__" <> snake_case(name)
  }
}

fn snake_case(name: String) -> String {
  string.to_graphemes(name)
  |> list.index_map(fn(c, index) {
    case index > 0 && string.uppercase(c) == c && string.lowercase(c) != c {
      True -> "_" <> string.lowercase(c)
      False -> string.lowercase(c)
    }
  })
  |> string.concat
}

fn lookup(
  codecs: Codecs,
  module: String,
  name: String,
) -> Result(TypeDef, String) {
  case dict.get(codecs.type_defs, #(module, name)) {
    Ok(def) -> Ok(def)
    Error(Nil) ->
      Error(
        "Invariant violated: type "
        <> field_type.qualified_name(module, name)
        <> " reached code generation without a definition; validate_codec_types should have rejected it",
      )
  }
}

fn require_def(
  codecs: Codecs,
  module: String,
  name: String,
) -> Result(Nil, String) {
  use def <- result.try(lookup(codecs, module, name))
  case def {
    field_type.RecordDef(..) | field_type.EnumDef(..) -> Ok(Nil)
    field_type.AliasDef(..) | field_type.UnsupportedDef(..) ->
      Error(not_generatable(module, name, def))
  }
}

/// Two variants whose lowercased names are equal would share a wire name.
fn check_enum_names(
  module: String,
  name: String,
  variants: List(String),
) -> Result(Nil, String) {
  let wire = list.map(variants, field_type.enum_wire_name)
  case list.length(list.unique(wire)) == list.length(wire) {
    True -> Ok(Nil)
    False ->
      Error(
        "Enum "
        <> field_type.qualified_name(module, name)
        <> " has variants whose lowercased names are equal ("
        <> string.join(variants, ", ")
        <> "); they would be indistinguishable on the wire. Rename one of them.",
      )
  }
}

fn not_generatable(module: String, name: String, def: TypeDef) -> String {
  let label = field_type.qualified_name(module, name)
  case def {
    field_type.UnsupportedDef(reason) ->
      "Type " <> label <> " cannot be encoded: " <> reason
    field_type.AliasDef(..) ->
      "Invariant violated: type alias "
      <> label
      <> " reached code generation unexpanded"
    field_type.RecordDef(..) | field_type.EnumDef(..) ->
      "Invariant violated: type " <> label <> " is generatable"
  }
}

fn unsupported(reason: String) -> String {
  "Invariant violated: an unsupported type reached code generation ("
  <> reason
  <> "); validate_codec_types should have rejected it"
}

fn unsupported_key(key: FieldType) -> String {
  "Invariant violated: Dict key type "
  <> field_type.describe(key)
  <> " reached code generation; only String and Int keys are supported"
}
