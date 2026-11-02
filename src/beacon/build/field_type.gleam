/// Resolved field types for codec generation.
///
/// The analyzer reads type annotations from the glance AST. A bare annotation
/// such as `Option(Card)` or `c.Card` means nothing on its own: `Option` may be
/// imported unqualified, `c` may be an alias for `app/card`, and `Cards` may be
/// a type alias. A `Scope` holds what one source file's imports and
/// definitions say, and `resolve` turns an annotation into a `FieldType` whose
/// named types carry the canonical module alias the generated code imports.
///
/// Anything the codecs cannot encode becomes `UnsupportedType` with a reason,
/// so the analyzer can fail the build naming the type and field.
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// The shape of a field the generated codecs know how to encode and decode.
pub type FieldType {
  IntType
  FloatType
  BoolType
  StringType
  OptionType(inner: FieldType)
  ListType(inner: FieldType)
  DictType(key: FieldType, value: FieldType)
  TupleType(elements: List(FieldType))
  /// A user-defined type. `module` is the canonical alias used by generated
  /// code; the empty string means the primary app module.
  NamedType(module: String, name: String)
  /// A type the codecs cannot handle, with the reason.
  UnsupportedType(reason: String)
}

/// The most elements a tuple field may have. Decoders read tuples from JSON
/// arrays by index, and `gleam/dynamic/decode` indexes lists up to 7.
pub const max_tuple_size = 8

/// What one source file's imports and definitions say about type names.
pub type Scope {
  Scope(
    /// Canonical alias for types defined in this file ("" for the app module).
    current: String,
    /// Module alias as written in this file -> module path.
    aliases: Dict(String, String),
    /// Unqualified imported type name -> #(module path, original name).
    unqualified: Dict(String, #(String, String)),
    /// Names of custom types defined in this file.
    local_types: Set(String),
    /// Module path -> canonical alias used by generated code.
    canonical: Dict(String, String),
  )
}

/// Build the scope for a parsed module.
pub fn scope(
  module: glance.Module,
  current: String,
  canonical: Dict(String, String),
) -> Scope {
  let #(aliases, unqualified) =
    list.fold(module.imports, #(dict.new(), dict.new()), fn(acc, def) {
      let import_ = def.definition
      let #(aliases, unqualified) = acc
      let aliases = case import_alias(import_) {
        Ok(alias) -> dict.insert(aliases, alias, import_.module)
        Error(Nil) -> aliases
      }
      let unqualified =
        list.fold(import_.unqualified_types, unqualified, fn(acc, item) {
          let local_name = option.unwrap(item.alias, item.name)
          dict.insert(acc, local_name, #(import_.module, item.name))
        })
      #(aliases, unqualified)
    })
  let local_types =
    list.fold(module.custom_types, set.new(), fn(acc, def) {
      set.insert(acc, def.definition.name)
    })
    |> fn(names) {
      list.fold(module.type_aliases, names, fn(acc, def) {
        set.insert(acc, def.definition.name)
      })
    }
  Scope(current:, aliases:, unqualified:, local_types:, canonical:)
}

/// The name an import is referenced by: its `as` alias or its last segment.
/// A discarded alias (`as _x`) makes the module unreferenceable.
pub fn import_alias(import_: glance.Import) -> Result(String, Nil) {
  case import_.alias {
    option.Some(glance.Named(name)) -> Ok(name)
    option.Some(glance.Discarded(_)) -> Error(Nil)
    option.None -> last_segment(import_.module)
  }
}

/// The last `/`-separated segment of a module path.
pub fn last_segment(module_path: String) -> Result(String, Nil) {
  string.split(module_path, "/") |> list.last
}

/// Resolve a type annotation in a scope.
pub fn resolve(scope: Scope, type_: glance.Type) -> FieldType {
  case type_ {
    glance.NamedType(name:, module: option.Some(qualifier), parameters:, ..) ->
      case dict.get(scope.aliases, qualifier) {
        Ok(path) -> resolve_from_module(scope, path, name, parameters)
        Error(Nil) ->
          UnsupportedType(
            "`"
            <> qualifier
            <> "."
            <> name
            <> "` uses module `"
            <> qualifier
            <> "`, which this file does not import",
          )
      }
    glance.NamedType(name:, module: option.None, parameters:, ..) ->
      resolve_unqualified(scope, name, parameters)
    glance.TupleType(elements:, ..) -> {
      let size = list.length(elements)
      case size > max_tuple_size {
        True ->
          UnsupportedType(
            "tuples of more than "
            <> int.to_string(max_tuple_size)
            <> " elements are not supported (found "
            <> int.to_string(size)
            <> ")",
          )
        False -> TupleType(list.map(elements, resolve(scope, _)))
      }
    }
    glance.FunctionType(..) ->
      UnsupportedType("functions cannot be sent over the wire")
    glance.VariableType(name:, ..) ->
      UnsupportedType(
        "type variable `" <> name <> "` cannot be encoded; use a concrete type",
      )
    glance.HoleType(name:, ..) ->
      UnsupportedType("type hole `" <> name <> "` cannot be encoded")
  }
}

fn resolve_unqualified(
  scope: Scope,
  name: String,
  parameters: List(glance.Type),
) -> FieldType {
  case set.contains(scope.local_types, name) {
    True -> user_type(scope.current, name, parameters)
    False ->
      case dict.get(scope.unqualified, name) {
        Ok(#(path, original)) ->
          resolve_from_module(scope, path, original, parameters)
        Error(Nil) -> resolve_prelude(scope, name, parameters)
      }
  }
}

fn resolve_prelude(
  scope: Scope,
  name: String,
  parameters: List(glance.Type),
) -> FieldType {
  case name, parameters {
    "Int", [] -> IntType
    "Float", [] -> FloatType
    "Bool", [] -> BoolType
    "String", [] -> StringType
    "List", [inner] -> ListType(resolve(scope, inner))
    "Nil", [] -> UnsupportedType("`Nil` carries no data; remove the field")
    "Result", _ ->
      UnsupportedType(
        "`Result` is not supported; use a custom type with one variant per case",
      )
    "BitArray", [] -> UnsupportedType("`BitArray` is not supported")
    "UtfCodepoint", [] -> UnsupportedType("`UtfCodepoint` is not supported")
    _, _ ->
      UnsupportedType(
        "type `"
        <> name
        <> "` is not defined in this module or imported unqualified",
      )
  }
}

fn resolve_from_module(
  scope: Scope,
  path: String,
  name: String,
  parameters: List(glance.Type),
) -> FieldType {
  case path, name, parameters {
    "gleam/option", "Option", [inner] -> OptionType(resolve(scope, inner))
    "gleam/dict", "Dict", [key, value] ->
      DictType(resolve(scope, key), resolve(scope, value))
    _, _, _ ->
      case dict.get(scope.canonical, path) {
        Ok(alias) -> user_type(alias, name, parameters)
        Error(Nil) ->
          UnsupportedType(
            "`"
            <> name
            <> "` comes from `"
            <> path
            <> "`, which is not an app module the build analyzes",
          )
      }
  }
}

fn user_type(
  module: String,
  name: String,
  parameters: List(glance.Type),
) -> FieldType {
  case parameters {
    [] -> NamedType(module:, name:)
    _ ->
      UnsupportedType(
        "generic type `"
        <> qualified_name(module, name)
        <> "` is not supported; use a concrete type",
      )
  }
}

/// What a user-defined type looks like to the generated codecs.
pub type TypeDef {
  /// One variant. Encoded as a JSON object keyed by field label.
  RecordDef(constructor: String, fields: List(#(String, FieldType)))
  /// Several variants without fields. Encoded as the lowercased variant name.
  EnumDef(variants: List(String))
  /// A type alias, replaced by its target before code generation.
  AliasDef(target: FieldType)
  /// A type the codecs cannot handle, with the reason.
  UnsupportedDef(reason: String)
}

/// Classify a custom type defined in the module `scope` describes.
pub fn custom_type_def(
  scope: Scope,
  custom_type: glance.CustomType,
) -> TypeDef {
  let name = custom_type.name
  let all_fieldless =
    list.all(custom_type.variants, fn(variant) { variant.fields == [] })
  case custom_type {
    glance.CustomType(parameters: [_, ..], ..) ->
      UnsupportedDef(
        "generic type `" <> name <> "` is not supported; use a concrete type",
      )
    glance.CustomType(opaque_: True, ..) ->
      UnsupportedDef(
        "opaque type `"
        <> name
        <> "` cannot be built by generated codecs; make it a plain `pub type`",
      )
    glance.CustomType(publicity: glance.Private, ..) ->
      UnsupportedDef(
        "type `"
        <> name
        <> "` is private; make it `pub` so generated codecs can use it",
      )
    glance.CustomType(variants: [variant], ..) ->
      record_def(scope, name, variant)
    glance.CustomType(variants: [_, _, ..] as variants, ..) if all_fieldless ->
      EnumDef(list.map(variants, fn(variant) { variant.name }))
    glance.CustomType(variants: [], ..) ->
      UnsupportedDef("type `" <> name <> "` has no constructors")
    glance.CustomType(..) ->
      UnsupportedDef(
        "type `"
        <> name
        <> "` has several variants that carry fields; generated codecs support records (one variant) and enums (variants without fields)",
      )
  }
}

fn record_def(scope: Scope, name: String, variant: glance.Variant) -> TypeDef {
  let fields =
    list.try_map(variant.fields, fn(field) {
      case field {
        glance.LabelledVariantField(item:, label:) ->
          Ok(#(label, resolve(scope, item)))
        glance.UnlabelledVariantField(..) -> Error(Nil)
      }
    })
  case fields {
    Ok(fields) -> RecordDef(constructor: variant.name, fields:)
    Error(Nil) ->
      UnsupportedDef(
        "record `"
        <> name
        <> "` has unlabelled fields; label every field so it can be encoded as a JSON object",
      )
  }
}

/// Classify a type alias defined in the module `scope` describes.
pub fn type_alias_def(scope: Scope, alias: glance.TypeAlias) -> TypeDef {
  case alias.parameters {
    [] -> AliasDef(resolve(scope, alias.aliased))
    _ ->
      UnsupportedDef(
        "generic type alias `"
        <> alias.name
        <> "` is not supported; use a concrete type",
      )
  }
}

/// The JSON string an enum variant is encoded as.
pub fn enum_wire_name(variant: String) -> String {
  string.lowercase(variant)
}

/// Replace references to type aliases with what they alias. `aliases` maps
/// #(module, name) to the resolved aliased type. Aliases cannot be cyclic in
/// Gleam, but the depth is bounded anyway so a bug here cannot loop forever.
pub fn expand_aliases(
  type_: FieldType,
  aliases: Dict(#(String, String), FieldType),
) -> FieldType {
  expand(type_, aliases, 0)
}

const max_alias_depth = 32

fn expand(
  type_: FieldType,
  aliases: Dict(#(String, String), FieldType),
  depth: Int,
) -> FieldType {
  case depth > max_alias_depth {
    True ->
      UnsupportedType(
        "type aliases nest more than "
        <> int.to_string(max_alias_depth)
        <> " levels deep",
      )
    False ->
      case type_ {
        NamedType(module:, name:) ->
          case dict.get(aliases, #(module, name)) {
            Ok(target) -> expand(target, aliases, depth + 1)
            Error(Nil) -> type_
          }
        OptionType(inner) -> OptionType(expand(inner, aliases, depth + 1))
        ListType(inner) -> ListType(expand(inner, aliases, depth + 1))
        DictType(key, value) ->
          DictType(
            expand(key, aliases, depth + 1),
            expand(value, aliases, depth + 1),
          )
        TupleType(elements) ->
          TupleType(list.map(elements, expand(_, aliases, depth + 1)))
        IntType | FloatType | BoolType | StringType | UnsupportedType(_) ->
          type_
      }
  }
}

/// Render a field type the way a user would write it, for error messages.
pub fn describe(type_: FieldType) -> String {
  case type_ {
    IntType -> "Int"
    FloatType -> "Float"
    BoolType -> "Bool"
    StringType -> "String"
    OptionType(inner) -> "Option(" <> describe(inner) <> ")"
    ListType(inner) -> "List(" <> describe(inner) <> ")"
    DictType(key, value) ->
      "Dict(" <> describe(key) <> ", " <> describe(value) <> ")"
    TupleType(elements) ->
      "#(" <> string.join(list.map(elements, describe), ", ") <> ")"
    NamedType(module:, name:) -> qualified_name(module, name)
    UnsupportedType(reason) -> "<unsupported: " <> reason <> ">"
  }
}

/// `module.Name`, or `Name` for the app module.
pub fn qualified_name(module: String, name: String) -> String {
  case module {
    "" -> name
    _ -> module <> "." <> name
  }
}

/// Every named type referenced anywhere inside a field type, in order.
pub fn named_types(type_: FieldType) -> List(#(String, String)) {
  case type_ {
    NamedType(module:, name:) -> [#(module, name)]
    OptionType(inner) | ListType(inner) -> named_types(inner)
    DictType(key, value) -> list.append(named_types(key), named_types(value))
    TupleType(elements) -> list.flat_map(elements, named_types)
    IntType | FloatType | BoolType | StringType | UnsupportedType(_) -> []
  }
}

/// Build the canonical module path -> alias map, failing when two different
/// modules would be imported under the same alias in generated code.
pub fn canonical_aliases(
  modules: List(#(String, String)),
) -> Result(Dict(String, String), String) {
  list.try_fold(modules, #(dict.new(), dict.new()), fn(acc, entry) {
    let #(by_path, by_alias) = acc
    let #(alias, path) = entry
    case dict.get(by_alias, alias), dict.get(by_path, path) {
      Ok(other_path), _ if other_path != path ->
        Error(
          "Modules `"
          <> other_path
          <> "` and `"
          <> path
          <> "` are both referred to as `"
          <> alias
          <> "`. Give one of them a different alias with `import "
          <> path
          <> " as <name>` so generated code can import both.",
        )
      _, Ok(_) -> Ok(acc)
      _, Error(Nil) ->
        Ok(#(
          dict.insert(by_path, path, alias),
          dict.insert(by_alias, alias, path),
        ))
    }
  })
  |> result.map(fn(acc) { acc.0 })
}
