/// JSON encoders and decoders for resolved field types, built with
/// `brazier/build/gleam_code`. Shared by the server codec and the client entry
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
/// - a record (one variant, every field labelled): an object keyed by label.
/// - an enum (variants without fields): the lowercased variant name.
/// - a union (anything else): `{"tag": "Variant", "arg0": .., "arg1": ..}`.
///   Unknown tags are rejected.
///
/// Message mode: a type in `Codecs.sent` is one whose values only the
/// client's own code builds (a Msg type, or a type only Msg variants carry).
/// Its helpers accept only the constructors in `Codecs.allowed`, the ones the
/// client-reachable code builds, so the server decodes nothing the browser
/// could not have produced. Fields of other constructors are never walked,
/// so a server-only variant may carry types the wire cannot encode.
///
/// Every helper is generated once per type, and only when something
/// reachable from the given roots uses it, so the generated module has no
/// unused functions.
import brazier/build/field_type.{type FieldType, type TypeDef}
import brazier/build/gleam_code.{
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
pub const json = "brazier_json"

pub const decode = "brazier_decode"

pub const int_module = "brazier_int"

pub const list_module = "brazier_list"

pub const option_module = "brazier_option"

pub const dict_module = "brazier_dict"

pub const result_module = "brazier_result"

pub const string_module = "brazier_string"

/// The standard imports generated modules may use. `gleam_code.render` drops
/// the ones a module does not reference.
pub fn std_imports() -> List(Import) {
  [
    Import("gleam/dict", Some(dict_module)),
    Import("gleam/dynamic/decode", Some(decode)),
    Import("gleam/int", Some(int_module)),
    Import("gleam/json", Some(json)),
    Import("gleam/list", Some(list_module)),
    Import("gleam/option", Some(option_module)),
    Import("gleam/result", Some(result_module)),
    Import("gleam/string", Some(string_module)),
  ]
}

/// The alias generated code imports the user module `path` under:
/// `app/card` becomes `brazier_m_app__card`. The prefix keeps it apart from
/// the standard aliases above; the analyzer rejects two paths that map to
/// the same alias.
pub fn module_alias(path: String) -> String {
  "brazier_m_" <> string.replace(path, "/", "__")
}

/// `import path as <module_alias(path)>`.
pub fn module_import(path: String) -> Import {
  Import(path, Some(module_alias(path)))
}

/// What the generators need to know about the analyzed app.
pub type Codecs {
  Codecs(
    /// Every user type, keyed by #(module path, name), with type aliases
    /// already expanded inside the definitions.
    type_defs: Dict(#(String, String), TypeDef),
    /// Types in message mode (see the module docs).
    sent: Set(#(String, String)),
    /// #(module path, constructor) the client-reachable code builds.
    allowed: Set(#(String, String)),
  )
}

/// `alias.Name` as a type annotation.
pub fn named_type(module: String, name: String) -> TypeExpr {
  TNamed(Some(module_alias(module)), name, [])
}

/// The annotation for a value of `type_` in generated code.
pub fn type_expr(type_: FieldType) -> Result(TypeExpr, String) {
  case type_ {
    field_type.IntType -> Ok(TNamed(None, "Int", []))
    field_type.FloatType -> Ok(TNamed(None, "Float", []))
    field_type.BoolType -> Ok(TNamed(None, "Bool", []))
    field_type.StringType -> Ok(string_type())
    field_type.OptionType(inner) -> {
      use inner <- result.map(type_expr(inner))
      TNamed(Some(option_module), "Option", [inner])
    }
    field_type.ListType(inner) -> {
      use inner <- result.map(type_expr(inner))
      TNamed(None, "List", [inner])
    }
    field_type.DictType(key, value) -> {
      use key <- result.try(type_expr(key))
      use value <- result.map(type_expr(value))
      TNamed(Some(dict_module), "Dict", [key, value])
    }
    field_type.TupleType(elements) ->
      list.try_map(elements, type_expr) |> result.map(gleam_code.TTuple)
    field_type.NamedType(module, name) -> Ok(named_type(module, name))
    field_type.UnsupportedType(reason) -> Error(unsupported(reason))
  }
}

/// `brazier_json.Json`
pub fn json_type() -> TypeExpr {
  TNamed(Some(json), "Json", [])
}

pub fn string_type() -> TypeExpr {
  TNamed(None, "String", [])
}

/// `Result(ok, String)`
pub fn result_type(ok: TypeExpr) -> TypeExpr {
  TNamed(None, "Result", [ok, string_type()])
}

/// `brazier_decode.Decoder(inner)`
pub fn decoder_type(inner: TypeExpr) -> TypeExpr {
  TNamed(Some(decode), "Decoder", [inner])
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

/// `brazier_json.to_string(value)`
pub fn json_to_string(value: Expr) -> Expr {
  json_call("to_string", [value])
}

/// `brazier_json.object([#("key", value), ..])`
pub fn json_object(entries: List(#(String, Expr))) -> Expr {
  json_call("object", [
    ListExpr(
      list.map(entries, fn(entry) { TupleExpr([Str(entry.0), entry.1]) }),
    ),
  ])
}

/// `use name <- brazier_decode.field("key", decoder)`
pub fn decode_field(name: String, key: String, decoder: Expr) -> Stmt {
  Use([name], decode_call("field", [Str(key), decoder]))
}

/// `brazier_decode.success(value)`
pub fn decode_success(value: Expr) -> Expr {
  decode_call("success", [value])
}

/// `Error(prefix <> brazier_string.inspect(name))`
pub fn inspect_error(prefix: String, name: String) -> Expr {
  error(gleam_code.BinOp(
    gleam_code.Concat,
    Str(prefix),
    Call(Ref(Some(string_module), "inspect"), [Arg(Var(name))]),
  ))
}

/// The local variable a decoded field is bound to. The prefix keeps it apart
/// from the module aliases and from the generator's own names.
fn field_var(label: String) -> String {
  "brazier_v_" <> label
}

fn arg_var(index: Int) -> String {
  "brazier_a" <> int.to_string(index)
}

// ===== Encoding =====

/// An expression encoding `value`, of type `type_`, to `brazier_json.Json`.
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
      Call(Ref(None, helper_name(codecs, Encoder, module, name)), [Arg(value)])
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
      Ref(None, helper_name(codecs, Encoder, module, name))
    }
    _ -> {
      let var = "brazier_x" <> int.to_string(depth)
      use body <- result.map(encode_at(codecs, type_, Var(var), depth + 1))
      FnExpr([var], [ExprStmt(body)])
    }
  }
}

fn key_encoder(key: FieldType, depth: Int) -> Result(Expr, String) {
  case key {
    field_type.StringType -> {
      let var = "brazier_k" <> int.to_string(depth)
      Ok(FnExpr([var], [ExprStmt(Var(var))]))
    }
    field_type.IntType -> Ok(Ref(Some(int_module), "to_string"))
    _ -> Error(unsupported_key(key))
  }
}

// ===== Decoding =====

/// An expression of type `brazier_decode.Decoder(t)` for `type_`.
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
      // `recursive` defers building the helper's decoder until it runs, so a
      // recursive type does not build its decoder forever.
      decode_call("recursive", [
        Ref(None, helper_name(codecs, Decoder, module, name)),
      ])
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
      let raw = "brazier_key" <> int.to_string(depth)
      let parsed = "brazier_n" <> int.to_string(depth)
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
  let prefix = "brazier_e" <> int.to_string(depth) <> "_"
  let items = "brazier_items" <> int.to_string(depth)
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

type Kind {
  Encoder
  Decoder
  ZeroKind
}

/// The helper functions the encoders of `encode_roots` and the decoders of
/// `decode_roots` call, each generated once, sorted by name.
pub fn helpers(
  codecs: Codecs,
  encode_roots: List(FieldType),
  decode_roots: List(FieldType),
) -> Result(List(Definition), String) {
  use encode_types <- result.try(reachable(codecs, encode_roots))
  use decode_types <- result.try(reachable(codecs, decode_roots))
  use zeros <- result.try(zero_choices(codecs))
  use zero_types <- result.try(zero_closure(codecs, zeros, decode_types))
  use encoders <- result.try(
    list.try_map(encode_types, fn(key) { encoder_helper(codecs, key.0, key.1) }),
  )
  use decoders <- result.try(
    list.try_map(decode_types, fn(key) {
      decoder_helper(codecs, zeros, key.0, key.1)
    }),
  )
  use zero_helpers <- result.map(
    list.try_map(zero_types, fn(key) { zero_helper(zeros, key) }),
  )
  list.flatten([encoders, decoders, zero_helpers])
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

/// Every user type reachable from `roots`, in a stable order. A message-mode
/// type contributes only the fields of its allowed constructors.
fn reachable(
  codecs: Codecs,
  roots: List(FieldType),
) -> Result(List(#(String, String)), String) {
  let start = list.flat_map(roots, field_type.named_types)
  use seen <- result.map(walk(codecs, start, set.new()))
  sort_keys(set.to_list(seen))
}

fn sort_keys(keys: List(#(String, String))) -> List(#(String, String)) {
  list.sort(keys, fn(a, b) {
    string.compare(a.0 <> "." <> a.1, b.0 <> "." <> b.1)
  })
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
          let next =
            walked_fields(codecs, key.0, key.1, def)
            |> list.flat_map(field_type.named_types)
          walk(codecs, list.append(next, rest), set.insert(seen, key))
        }
      }
  }
}

/// The field types the helpers of a type encode or decode.
fn walked_fields(
  codecs: Codecs,
  module: String,
  name: String,
  def: TypeDef,
) -> List(FieldType) {
  case def {
    field_type.RecordDef(constructor:, fields:) ->
      case is_allowed(codecs, module, name, constructor) {
        True -> list.map(fields, fn(f) { f.1 })
        False -> []
      }
    field_type.UnionDef(variants) ->
      list.flat_map(variants, fn(variant) {
        case is_allowed(codecs, module, name, variant.0) {
          True -> variant.1
          False -> []
        }
      })
    field_type.EnumDef(..)
    | field_type.AliasDef(..)
    | field_type.UnsupportedDef(..) -> []
  }
}

/// Whether the helpers of type `module.name` handle `constructor`: always
/// outside message mode, only when allowed inside it.
fn is_allowed(
  codecs: Codecs,
  module: String,
  name: String,
  constructor: String,
) -> Bool {
  !set.contains(codecs.sent, #(module, name))
  || set.contains(codecs.allowed, #(module, constructor))
}

fn encoder_helper(
  codecs: Codecs,
  module: String,
  name: String,
) -> Result(Definition, String) {
  let q = module_alias(module)
  let fn_name = helper_name(codecs, Encoder, module, name)
  let param_type = named_type(module, name)
  use def <- result.try(lookup(codecs, module, name))
  let function = fn(body) {
    Function(
      fn_name,
      False,
      [],
      [Param("brazier_value", param_type)],
      json_type(),
      [ExprStmt(body)],
    )
  }
  case def {
    field_type.RecordDef(constructor:, fields:) ->
      case is_allowed(codecs, module, name, constructor), fields {
        True, [_, ..] -> {
          use entries <- result.map(
            list.try_map(fields, fn(f) {
              let #(label, type_) = f
              use encoded <- result.map(encode(
                codecs,
                type_,
                FieldAccess(Var("brazier_value"), label),
              ))
              #(label, encoded)
            }),
          )
          function(json_object(entries))
        }
        // No field to read, or a record the client never builds: the
        // server rejects the empty object when it is not allowed.
        _, _ -> Ok(unused_value_encoder(fn_name, param_type))
      }
    field_type.EnumDef(variants) -> {
      use Nil <- result.map(check_enum_names(module, name, variants))
      function(Case(
        [Var("brazier_value")],
        list.map(variants, fn(variant) {
          Clause(
            [PCtor(Some(q), variant, [], False)],
            json_call("string", [Str(field_type.enum_wire_name(variant))]),
          )
        }),
      ))
    }
    field_type.UnionDef(variants) -> {
      use clauses <- result.map(
        list.try_map(variants, fn(variant) {
          let #(constructor, fields) = variant
          let tag = #("tag", json_call("string", [Str(constructor)]))
          case is_allowed(codecs, module, name, constructor), fields {
            True, [_, ..] -> {
              let indexed =
                list.index_map(fields, fn(field, index) { #(index, field) })
              use entries <- result.map(
                list.try_map(indexed, fn(entry) {
                  let #(index, type_) = entry
                  use encoded <- result.map(encode(
                    codecs,
                    type_,
                    Var(arg_var(index)),
                  ))
                  #(field_type.union_arg_key(index), encoded)
                }),
              )
              Clause(
                [
                  PCtor(
                    Some(q),
                    constructor,
                    list.map(indexed, fn(entry) { PVar(arg_var(entry.0)) }),
                    False,
                  ),
                ],
                json_object([tag, ..entries]),
              )
            }
            // A constructor without fields, or one the client never builds
            // (only its tag is written; the server rejects it).
            _, _ ->
              Ok(Clause(
                [PCtor(Some(q), constructor, [], fields != [])],
                json_object([tag]),
              ))
          }
        }),
      )
      function(Case([Var("brazier_value")], clauses))
    }
    field_type.AliasDef(..) | field_type.UnsupportedDef(..) ->
      Error(not_generatable(module, name, def))
  }
}

fn unused_value_encoder(fn_name: String, param_type: TypeExpr) -> Definition {
  Function(
    fn_name,
    False,
    [],
    [Param("_brazier_value", param_type)],
    json_type(),
    [ExprStmt(json_object([]))],
  )
}

fn decoder_helper(
  codecs: Codecs,
  zeros: Dict(#(String, String), Zero),
  module: String,
  name: String,
) -> Result(Definition, String) {
  let q = module_alias(module)
  let key = #(module, name)
  let fn_name = helper_name(codecs, Decoder, module, name)
  let return = decoder_type(named_type(module, name))
  let label = field_type.qualified_name(module, name)
  use def <- result.try(lookup(codecs, module, name))
  case def {
    field_type.RecordDef(constructor:, fields:) ->
      case is_allowed(codecs, module, name, constructor) {
        True -> {
          use uses <- result.map(
            list.try_map(fields, fn(f) {
              let #(label, type_) = f
              use field_decoder <- result.map(decoder(codecs, type_))
              decode_field(field_var(label), label, field_decoder)
            }),
          )
          let built = case fields {
            [] -> Ctor(Some(q), constructor)
            _ ->
              Call(
                Ctor(Some(q), constructor),
                list.map(fields, fn(f) {
                  gleam_code.Labelled(f.0, Var(field_var(f.0)))
                }),
              )
          }
          Function(
            fn_name,
            False,
            [],
            [],
            return,
            list.append(uses, [ExprStmt(decode_success(built))]),
          )
        }
        False -> {
          use placeholder <- result.map(zero_call(zeros, key))
          Function(fn_name, False, [], [], return, [
            ExprStmt(
              decode_call("failure", [
                placeholder,
                Str(
                  label
                  <> " ("
                  <> constructor
                  <> " is never sent by the client)",
                ),
              ]),
            ),
          ])
        }
      }
    field_type.EnumDef(variants: [first, ..] as variants) -> {
      use Nil <- result.map(check_enum_names(module, name, variants))
      let clauses =
        list.filter_map(variants, fn(variant) {
          case is_allowed(codecs, module, name, variant) {
            True ->
              Ok(Clause(
                [PString(field_type.enum_wire_name(variant))],
                decode_success(Ctor(Some(q), variant)),
              ))
            False -> Error(Nil)
          }
        })
      let reject =
        Clause(
          [PDiscard("")],
          decode_call("failure", [
            Ctor(Some(q), first),
            Str(expected(codecs, key)),
          ]),
        )
      Function(fn_name, False, [], [], return, [
        Use(["brazier_tag"], decode_call("then", [Ref(Some(decode), "string")])),
        ExprStmt(Case([Var("brazier_tag")], list.append(clauses, [reject]))),
      ])
    }
    field_type.EnumDef(variants: []) ->
      Error("Invariant violated: enum " <> label <> " has no variants")
    field_type.UnionDef(variants) -> {
      use clauses <- result.try(
        list.try_map(
          list.filter(variants, fn(variant) {
            is_allowed(codecs, module, name, variant.0)
          }),
          fn(variant) { union_variant_clause(codecs, q, variant) },
        ),
      )
      use placeholder <- result.map(zero_call(zeros, key))
      let reject =
        Clause(
          [PDiscard("")],
          decode_call("failure", [placeholder, Str(expected(codecs, key))]),
        )
      Function(fn_name, False, [], [], return, [
        decode_field("brazier_tag", "tag", Ref(Some(decode), "string")),
        ExprStmt(Case([Var("brazier_tag")], list.append(clauses, [reject]))),
      ])
    }
    field_type.AliasDef(..) | field_type.UnsupportedDef(..) ->
      Error(not_generatable(module, name, def))
  }
}

/// What a decoder failure says was expected: the type, and in message mode
/// that only the client's constructors are accepted.
fn expected(codecs: Codecs, key: #(String, String)) -> String {
  let label = field_type.qualified_name(key.0, key.1)
  case set.contains(codecs.sent, key) {
    True -> label <> " sent by the client (a constructor the browser builds)"
    False -> label
  }
}

/// `"Tag" -> { use brazier_a0 <- field("arg0", ..) .. success(q.Tag(..)) }`
fn union_variant_clause(
  codecs: Codecs,
  q: String,
  variant: #(String, List(FieldType)),
) -> Result(gleam_code.Clause, String) {
  let #(constructor, fields) = variant
  case fields {
    [] ->
      Ok(Clause(
        [PString(constructor)],
        decode_success(Ctor(Some(q), constructor)),
      ))
    _ -> {
      let indexed = list.index_map(fields, fn(field, index) { #(index, field) })
      use uses <- result.map(
        list.try_map(indexed, fn(entry) {
          let #(index, type_) = entry
          use field_decoder <- result.map(decoder(codecs, type_))
          decode_field(
            arg_var(index),
            field_type.union_arg_key(index),
            field_decoder,
          )
        }),
      )
      let built =
        Call(
          Ctor(Some(q), constructor),
          list.map(indexed, fn(entry) { Arg(Var(arg_var(entry.0))) }),
        )
      Clause(
        [PString(constructor)],
        gleam_code.Block(list.append(uses, [ExprStmt(decode_success(built))])),
      )
    }
  }
}

// ===== Placeholders =====

/// A value of a type that `decode.failure` returns alongside its error. It is
/// never seen by the app: a failed decode is an `Error`.
type Zero {
  Zero(constructor: String, fields: List(FieldType))
}

/// For every user type that has a finite value, the constructor to build
/// its placeholder with. Types are added in rounds: a type joins once one of
/// its constructors has only fields whose placeholders are already known, so
/// a placeholder never refers back to itself.
fn zero_choices(
  codecs: Codecs,
) -> Result(Dict(#(String, String), Zero), String) {
  let entries =
    dict.to_list(codecs.type_defs)
    |> list.sort(fn(a, b) {
      string.compare(a.0.0 <> "." <> a.0.1, b.0.0 <> "." <> b.0.1)
    })
  Ok(zero_rounds(entries, dict.new(), list.length(entries) + 1))
}

fn zero_rounds(
  entries: List(#(#(String, String), TypeDef)),
  known: Dict(#(String, String), Zero),
  rounds_left: Int,
) -> Dict(#(String, String), Zero) {
  let next =
    list.fold(entries, known, fn(acc, entry) {
      let #(key, def) = entry
      case dict.has_key(acc, key) {
        True -> acc
        False ->
          case zero_for(def, acc) {
            Ok(zero) -> dict.insert(acc, key, zero)
            Error(Nil) -> acc
          }
      }
    })
  // Each round adds at least one type or ends, so `rounds_left` (one more
  // than the number of types) only bounds the loop against a bug here.
  case dict.size(next) == dict.size(known) || rounds_left <= 0 {
    True -> next
    False -> zero_rounds(entries, next, rounds_left - 1)
  }
}

fn zero_for(
  def: TypeDef,
  known: Dict(#(String, String), Zero),
) -> Result(Zero, Nil) {
  let candidates = case def {
    field_type.RecordDef(constructor:, fields:) -> [
      #(constructor, list.map(fields, fn(f) { f.1 })),
    ]
    field_type.EnumDef(variants) -> list.map(variants, fn(v) { #(v, []) })
    // Prefer a constructor without fields, then the first that works.
    field_type.UnionDef(variants) ->
      list.append(
        list.filter(variants, fn(v) { v.1 == [] }),
        list.filter(variants, fn(v) { v.1 != [] }),
      )
    field_type.AliasDef(..) | field_type.UnsupportedDef(..) -> []
  }
  list.find(candidates, fn(candidate) {
    list.all(candidate.1, has_zero(_, known))
  })
  |> result.map(fn(candidate) { Zero(candidate.0, candidate.1) })
}

fn has_zero(type_: FieldType, known: Dict(#(String, String), Zero)) -> Bool {
  case type_ {
    field_type.IntType
    | field_type.FloatType
    | field_type.BoolType
    | field_type.StringType
    | field_type.OptionType(_)
    | field_type.ListType(_)
    | field_type.DictType(..) -> True
    field_type.TupleType(elements) -> list.all(elements, has_zero(_, known))
    field_type.NamedType(module:, name:) -> dict.has_key(known, #(module, name))
    field_type.UnsupportedType(_) -> False
  }
}

/// The placeholder helpers the decoders of `decode_types` need: one per
/// union and per message-mode record the client never builds, plus the
/// helpers those placeholders call.
fn zero_closure(
  codecs: Codecs,
  zeros: Dict(#(String, String), Zero),
  decode_types: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  use roots <- result.map(
    list.try_fold(decode_types, [], fn(acc, key) {
      use def <- result.map(lookup(codecs, key.0, key.1))
      case def {
        field_type.UnionDef(..) -> [key, ..acc]
        field_type.RecordDef(constructor:, ..) ->
          case is_allowed(codecs, key.0, key.1, constructor) {
            True -> acc
            False -> [key, ..acc]
          }
        field_type.EnumDef(..)
        | field_type.AliasDef(..)
        | field_type.UnsupportedDef(..) -> acc
      }
    }),
  )
  zero_walk(zeros, roots, set.new())
  |> set.to_list
  |> sort_keys
}

fn zero_walk(
  zeros: Dict(#(String, String), Zero),
  pending: List(#(String, String)),
  seen: Set(#(String, String)),
) -> Set(#(String, String)) {
  case pending {
    [] -> seen
    [key, ..rest] ->
      case set.contains(seen, key), dict.get(zeros, key) {
        True, _ -> zero_walk(zeros, rest, seen)
        // No placeholder: `zero_call` reports it when the decoder is built.
        False, Error(Nil) -> zero_walk(zeros, rest, seen)
        False, Ok(Zero(fields:, ..)) ->
          zero_walk(
            zeros,
            list.append(list.flat_map(fields, field_type.named_types), rest),
            set.insert(seen, key),
          )
      }
  }
}

fn zero_call(
  zeros: Dict(#(String, String), Zero),
  key: #(String, String),
) -> Result(Expr, String) {
  case dict.get(zeros, key) {
    Ok(_) -> Ok(Call(Ref(None, zero_name(key)), []))
    Error(Nil) ->
      Error(
        "Type "
        <> field_type.qualified_name(key.0, key.1)
        <> " has no constructor whose fields all have a plain value, so its decoder cannot report a failure; add a constructor without fields or with plain fields",
      )
  }
}

fn zero_name(key: #(String, String)) -> String {
  "zero_type__" <> module_tag(key.0) <> "__" <> snake_case(key.1)
}

fn zero_helper(
  zeros: Dict(#(String, String), Zero),
  key: #(String, String),
) -> Result(Definition, String) {
  case dict.get(zeros, key) {
    Error(Nil) ->
      Error(
        "Invariant violated: placeholder helper for "
        <> field_type.qualified_name(key.0, key.1)
        <> " requested without a placeholder choice",
      )
    Ok(Zero(constructor:, fields:)) -> {
      let ctor = Ctor(Some(module_alias(key.0)), constructor)
      use args <- result.map(list.try_map(fields, zero_value(zeros, _)))
      let value = case args {
        [] -> ctor
        _ -> Call(ctor, list.map(args, Arg))
      }
      Function(zero_name(key), False, [], [], named_type(key.0, key.1), [
        ExprStmt(value),
      ])
    }
  }
}

fn zero_value(
  zeros: Dict(#(String, String), Zero),
  type_: FieldType,
) -> Result(Expr, String) {
  case type_ {
    field_type.IntType -> Ok(IntLit(0))
    field_type.FloatType ->
      Ok(Call(Ref(Some(int_module), "to_float"), [Arg(IntLit(0))]))
    field_type.BoolType -> Ok(Ctor(None, "False"))
    field_type.StringType -> Ok(Str(""))
    field_type.OptionType(_) -> Ok(Ctor(Some(option_module), "None"))
    field_type.ListType(_) -> Ok(ListExpr([]))
    field_type.DictType(..) -> Ok(Call(Ref(Some(dict_module), "new"), []))
    field_type.TupleType(elements) ->
      list.try_map(elements, zero_value(zeros, _)) |> result.map(TupleExpr)
    field_type.NamedType(module:, name:) -> zero_call(zeros, #(module, name))
    field_type.UnsupportedType(reason) -> Error(unsupported(reason))
  }
}

// ===== Names and lookups =====

/// `encode_type__<module>__<name>`; `encode_sent__..` and `decode_sent__..`
/// for message-mode types.
fn helper_name(
  codecs: Codecs,
  kind: Kind,
  module: String,
  name: String,
) -> String {
  let mode = case set.contains(codecs.sent, #(module, name)) {
    True -> "_sent__"
    False -> "_type__"
  }
  let prefix = case kind {
    Encoder -> "encode"
    Decoder -> "decode"
    ZeroKind -> "zero"
  }
  prefix <> mode <> module_tag(module) <> "__" <> snake_case(name)
}

/// The name of the encoder helper for `module.name`, for callers that build
/// their own entry points around it.
pub fn encoder_name(codecs: Codecs, module: String, name: String) -> String {
  helper_name(codecs, Encoder, module, name)
}

/// The name of the decoder helper for `module.name`.
pub fn decoder_name(codecs: Codecs, module: String, name: String) -> String {
  helper_name(codecs, Decoder, module, name)
}

fn module_tag(path: String) -> String {
  string.replace(path, "/", "__")
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
        <> " reached code generation without a definition",
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
    field_type.RecordDef(..)
    | field_type.EnumDef(..)
    | field_type.UnionDef(..) -> Ok(Nil)
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
    field_type.RecordDef(..)
    | field_type.EnumDef(..)
    | field_type.UnionDef(..) ->
      "Invariant violated: type " <> label <> " is generatable"
  }
}

fn unsupported(reason: String) -> String {
  "A type cannot be encoded: " <> reason
}

fn unsupported_key(key: FieldType) -> String {
  "Dict key type "
  <> field_type.describe(key)
  <> " cannot be encoded; only String and Int keys are supported"
}
