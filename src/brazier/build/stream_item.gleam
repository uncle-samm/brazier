/// The item type of a declared stream, read from the return annotation of
/// the function whose body calls `stream.new` (`-> Stream(Item)`), for the
/// contract report.
///
/// The item type is not a codec type: a stream's own `encode` and `decoder`
/// carry its items, so any type is accepted, a dependency's included. It is
/// written with every named type qualified by the path of the module that
/// defines it (`app.Line`, `gleam/time/timestamp.Timestamp`); prelude types
/// stay bare (`Int`, `List(app.Line)`).
///
/// A function with no return annotation, or one whose annotation is not a
/// `brazier/stream` `Stream` (a `view` that declares a stream inline), gives
/// no item type. An annotation that is a `Stream`, directly or through type
/// aliases of the app's modules, but whose item names no type the build can
/// resolve is an error: the build does not guess.
import brazier/build/reach
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Type aliases followed before the build refuses an annotation. Gleam
/// rejects alias cycles, so a deeper chain means the walk itself is wrong.
pub const max_alias_depth = 32

/// Prelude types, written bare unless a module defines or imports a type
/// of the same name.
const prelude = [
  "Int", "Float", "Bool", "String", "List", "Result", "Nil", "BitArray",
  "UtfCodepoint",
]

/// The item type of the stream declared in `module.owner`. `Ok(None)` when
/// the owner's return annotation is absent or is not a `Stream`; `Error`
/// with the reason when it is a `Stream` whose item does not resolve, or
/// when `module.owner` is not indexed (an invariant of the analyzer).
pub fn item_type(
  index: reach.Index,
  module: String,
  owner: String,
) -> Result(Option(String), String) {
  use info <- result.try(
    dict.get(index, module)
    |> result.replace_error(
      "Invariant violated: the module "
      <> module
      <> " of a stream is not indexed",
    ),
  )
  use def <- result.try(
    dict.get(info.functions, owner)
    |> result.replace_error(
      "Invariant violated: "
      <> module
      <> "."
      <> owner
      <> ", which declares a stream, is not a function of its module",
    ),
  )
  case def.definition.return {
    None -> Ok(None)
    Some(annotation) ->
      case stream_argument(index, info, annotation, dict.new(), 0) {
        Ok(None) -> Ok(None)
        Ok(Some(#(scope, item, env))) ->
          describe(scope, item, env)
          |> result.map(Some)
          |> result.map_error(fn(reason) {
            "the return annotation `"
            <> write(annotation)
            <> "` of `"
            <> module
            <> "."
            <> owner
            <> "` does not name the item type: "
            <> reason
          })
        Error(reason) ->
          Error(
            "the return annotation `"
            <> write(annotation)
            <> "` of `"
            <> module
            <> "."
            <> owner
            <> "` cannot be read: "
            <> reason,
          )
      }
  }
}

/// The binding of an alias's type parameter: the argument's type, the
/// module it is written in and the bindings in force there.
type Binding {
  Binding(info: reach.ModuleInfo, type_: glance.Type, env: Env)
}

type Env =
  Dict(String, Binding)

/// The item argument of `type_` when it is `brazier/stream`'s `Stream`,
/// directly or through type aliases of indexed modules, with the module it
/// is written in and the bindings in force there.
fn stream_argument(
  index: reach.Index,
  info: reach.ModuleInfo,
  type_: glance.Type,
  env: Env,
  depth: Int,
) -> Result(Option(#(reach.ModuleInfo, glance.Type, Env)), String) {
  case depth > max_alias_depth {
    True ->
      Error(
        "more than "
        <> int.to_string(max_alias_depth)
        <> " type aliases deep; Gleam rejects alias cycles, so this is a bug in the build",
      )
    False ->
      case type_ {
        glance.NamedType(name:, module: qualifier, parameters:, ..) ->
          case origin(info, qualifier, name) {
            Ok(#(path, original))
              if path == reach.stream_module && original == "Stream"
            ->
              case parameters {
                [item] -> Ok(Some(#(info, item, env)))
                _ ->
                  Error(
                    "`Stream` takes one type argument, the item type; found "
                    <> int.to_string(list.length(parameters)),
                  )
              }
            Ok(#(path, original)) ->
              follow_alias(index, info, path, original, parameters, env, depth)
            // A name the compiler resolves some other way (a prelude type)
            // is not a stream.
            Error(Nil) -> Ok(None)
          }
        glance.VariableType(name:, ..) ->
          case dict.get(env, name) {
            Ok(bound) ->
              stream_argument(
                index,
                bound.info,
                bound.type_,
                bound.env,
                depth + 1,
              )
            Error(Nil) -> Ok(None)
          }
        glance.TupleType(..) | glance.FunctionType(..) | glance.HoleType(..) ->
          Ok(None)
      }
  }
}

/// `path.name` when it is a type alias of an indexed module: what it
/// aliases, with its parameters bound to `arguments`.
fn follow_alias(
  index: reach.Index,
  info: reach.ModuleInfo,
  path: String,
  name: String,
  arguments: List(glance.Type),
  env: Env,
  depth: Int,
) -> Result(Option(#(reach.ModuleInfo, glance.Type, Env)), String) {
  let alias = {
    use target <- result.try(dict.get(index, path))
    use def <- result.map(dict.get(target.type_aliases, name))
    #(target, def.definition)
  }
  case alias {
    // Not an alias of an analyzed module: a custom type, or a dependency's
    // type. Neither is a `Stream`.
    Error(Nil) -> Ok(None)
    Ok(#(target, alias)) ->
      case list.length(alias.parameters) == list.length(arguments) {
        False ->
          Error(
            "the type alias `"
            <> path
            <> "."
            <> name
            <> "` takes "
            <> int.to_string(list.length(alias.parameters))
            <> " type argument(s); found "
            <> int.to_string(list.length(arguments)),
          )
        True -> {
          let bound =
            list.zip(alias.parameters, arguments)
            |> list.fold(dict.new(), fn(acc, pair) {
              dict.insert(acc, pair.0, Binding(info:, type_: pair.1, env:))
            })
          stream_argument(index, target, alias.aliased, bound, depth + 1)
        }
      }
  }
}

/// The module path and original name of the type `qualifier.name` written
/// in `info`. `Error` for a prelude name, or one `info` does not resolve.
fn origin(
  info: reach.ModuleInfo,
  qualifier: Option(String),
  name: String,
) -> Result(#(String, String), Nil) {
  case qualifier {
    Some(qualifier) ->
      dict.get(info.aliases, qualifier)
      |> result.map(fn(path) { #(path, name) })
    None ->
      case
        dict.has_key(info.custom_types, name)
        || dict.has_key(info.type_aliases, name)
      {
        True -> Ok(#(info.path, name))
        False -> dict.get(info.types, name)
      }
  }
}

/// `type_`, written in `info` with the bindings `env`, with every named
/// type qualified. `Error` names what does not resolve.
fn describe(
  info: reach.ModuleInfo,
  type_: glance.Type,
  env: Env,
) -> Result(String, String) {
  let all = fn(types) { list.try_map(types, describe(info, _, env)) }
  case type_ {
    glance.NamedType(name:, module: qualifier, parameters:, ..) -> {
      use head <- result.try(case origin(info, qualifier, name), qualifier {
        Ok(#(path, original)), _ -> Ok(path <> "." <> original)
        Error(Nil), Some(qualifier) ->
          Error(
            "`"
            <> qualifier
            <> "."
            <> name
            <> "` uses module `"
            <> qualifier
            <> "`, which "
            <> info.path
            <> " does not import",
          )
        Error(Nil), None ->
          case list.contains(prelude, name) {
            True -> Ok(name)
            False ->
              Error(
                "type `"
                <> name
                <> "` is not defined in "
                <> info.path
                <> " or imported unqualified",
              )
          }
      })
      use arguments <- result.map(all(parameters))
      case arguments {
        [] -> head
        _ -> head <> "(" <> string.join(arguments, ", ") <> ")"
      }
    }
    glance.TupleType(elements:, ..) -> {
      use elements <- result.map(all(elements))
      "#(" <> string.join(elements, ", ") <> ")"
    }
    glance.FunctionType(parameters:, return:, ..) -> {
      use parameters <- result.try(all(parameters))
      use return <- result.map(describe(info, return, env))
      "fn(" <> string.join(parameters, ", ") <> ") -> " <> return
    }
    glance.VariableType(name:, ..) ->
      case dict.get(env, name) {
        Ok(bound) -> describe(bound.info, bound.type_, bound.env)
        Error(Nil) ->
          Error(
            "the type variable `"
            <> name
            <> "` names no concrete type; annotate the item type",
          )
      }
    glance.HoleType(..) ->
      Error(
        "the type hole `"
        <> write(type_)
        <> "` names no type; annotate the item type",
      )
  }
}

/// `type_` as written in the source, for messages.
pub fn write(type_: glance.Type) -> String {
  let all = fn(types) { list.map(types, write) |> string.join(", ") }
  case type_ {
    glance.NamedType(name:, module: qualifier, parameters:, ..) -> {
      let head = case qualifier {
        Some(qualifier) -> qualifier <> "." <> name
        None -> name
      }
      case parameters {
        [] -> head
        _ -> head <> "(" <> all(parameters) <> ")"
      }
    }
    glance.TupleType(elements:, ..) -> "#(" <> all(elements) <> ")"
    glance.FunctionType(parameters:, return:, ..) ->
      "fn(" <> all(parameters) <> ") -> " <> write(return)
    glance.VariableType(name:, ..) -> name
    // glance keeps a hole's name without its leading `_`.
    glance.HoleType(name:, ..) -> "_" <> name
  }
}
