/// Analyzes an app's user modules for code generation.
///
/// 1. Find the app constructor call that `pub fn main` reaches
///    (`brazier/build/app_call`) and the functions it names.
/// 2. Read the Model and Msg types from `view`'s annotations:
///    `fn(Model) -> Element(Msg)` (or `fn(Model, Local) -> Element(Msg)`).
/// 3. Walk what the client runs (`brazier/build/reach`): `view` and a Local
///    layer's `init` and `update`, plus a `simple` app's `update`. Only
///    allowlisted Brazier modules may be reached.
/// 4. Derive the server's message allowlist: the Msg constructors that
///    `view` and the Local layer build as values. For a `simple` app this is
///    what `view` builds. `decode_event` accepts nothing else.
/// 5. Emit the client modules: each reached definition, sliced from its
///    source, with only the imports it uses.
///
/// Nothing is guessed: a missing annotation, a non-`pub` client function,
/// or a reference to a server-only Brazier module is a build error naming
/// the place.
import brazier/build/app_call.{type AppCall, type FunctionRef}
import brazier/build/codec_gen.{type Codecs, Codecs}
import brazier/build/field_type.{type FieldType, type TypeDef}
import brazier/build/reach
import brazier/build/source_location
import brazier/build/stream_item
import brazier/internal/render
import brazier/log
import brazier/stream
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// The Brazier modules client code may use. Everything else in `brazier` and
/// `brazier/*` runs only on the server.
pub const client_modules = [
  "brazier/attribute", "brazier/element", "brazier/event", "brazier/html",
  "brazier/local", "brazier/log", "brazier/notification",
  "brazier/presence/sync", "brazier/svg",
]

const element_module = "brazier/element"

pub type Analysis {
  Analysis(
    call: AppCall,
    /// Module path of the app module.
    app_module: String,
    /// The synced Model, aliases expanded.
    model: FieldType,
    /// #(module path, type name) of the Msg type.
    msg: #(String, String),
    codecs: Codecs,
    /// The client modules, sorted by path.
    client: List(reach.Emitted),
    /// The streams the app's modules declare, sorted by name.
    streams: List(StreamDecl),
  )
}

/// A stream an app module declares: one `stream.new` call.
pub type StreamDecl {
  StreamDecl(
    name: String,
    /// The place of the `stream.new` call, as `path.gleam:line:column`.
    at: String,
    /// The item type, from the declaring function's `-> Stream(Item)`
    /// annotation; `None` when the function has no such annotation.
    item_type: option.Option(String),
  )
}

/// Parse a module, with a located message on failure.
pub fn parse(path: String, source: String) -> Result(glance.Module, String) {
  glance.module(source)
  |> result.map_error(fn(err) {
    let message = source_location.describe_parse_error(path, source, err)
    log.error("brazier.build.analyzer", "Cannot parse " <> message)
    "Cannot parse " <> message
  })
}

/// True when the module's `pub fn main` reaches an app constructor call.
pub fn defines_app(
  module_path: String,
  source: String,
  module: glance.Module,
) -> Bool {
  app_call.defines_app(reach.module_info(module_path, source, module))
}

/// Analyze the app whose module path is `app_module`. `modules` lists every
/// user module the app uses, the app module included, as #(module path,
/// source), plus the source of `brazier/stream`, which the client gets
/// pruned to what it reaches (`reach.is_pruned_framework_module`).
pub fn analyze(
  app_module: String,
  modules: List(#(String, String)),
) -> Result(Analysis, String) {
  use parsed <- result.try(
    list.try_map(modules, fn(module) {
      let #(path, source) = module
      parse(path <> ".gleam", source)
      |> result.map(fn(ast) { #(path, source, ast) })
    }),
  )
  use Nil <- result.try(check_framework_modules(modules))
  use Nil <- result.try(check_aliases(
    list.map(modules, fn(m) { m.0 })
    |> list.filter(fn(path) { !reach.is_framework_module(path) }),
  ))
  use index <- result.try(reach.index(parsed))
  use info <- result.try(
    dict.get(index, app_module)
    |> result.replace_error(
      "Invariant violated: the app module "
      <> app_module
      <> " is not among the analyzed modules",
    ),
  )
  use call <- result.try(app_call.resolve(index, info))
  log.info(
    "brazier.build.analyzer",
    app_module
      <> " builds a brazier."
      <> app_call.kind_name(call.kind)
      <> " app with view "
      <> describe_ref(call.view),
  )
  use #(model, msg) <- result.try(view_types(index, call.view))
  use type_defs <- result.try(type_defs(index))
  let model = field_type.expand_aliases(model, aliases_of(type_defs))
  let model_closure = closure(type_defs, field_type.named_types(model))
  use Nil <- result.try(case set.contains(model_closure, msg) {
    True ->
      Error(
        "The Model type "
        <> field_type.describe(model)
        <> " contains the Msg type "
        <> field_type.qualified_name(msg.0, msg.1)
        <> ". The server sends the Model to the browser and only the browser sends messages; keep messages out of the Model.",
      )
    False -> Ok(Nil)
  })
  use Nil <- result.try(check_model_types(type_defs, model_closure))
  let sent = set.difference(closure(type_defs, [msg]), model_closure)
  let allow_roots = allow_roots(call)
  use allowed_reach <- result.try(walk(index, allow_roots))
  use client_reach <- result.try(case call.update {
    Some(update) -> walk(index, [to_item(update), ..allow_roots])
    None -> Ok(allowed_reach)
  })
  use streams <- result.try(streams(index, call, client_reach))
  // Client code builds other values too (a local layer's state, view
  // helpers' records); only the constructors of types a Msg carries are
  // messages the browser may send.
  let allowed =
    set.intersection(
      allowed_reach.built,
      constructors_of(type_defs, closure(type_defs, [msg])),
    )
  log_allowlist(msg, type_defs, allowed)
  use client <- result.map(reach.emit(index, client_reach))
  log.info(
    "brazier.build.analyzer",
    "Client code: "
      <> string.join(list.map(client, fn(e) { e.path }), ", ")
      <> " ("
      <> string.inspect(set.size(client_reach.items))
      <> " definitions)",
  )
  Analysis(
    call:,
    app_module:,
    model:,
    msg:,
    codecs: Codecs(type_defs:, sent:, allowed:),
    client:,
    streams:,
  )
}

/// Only the pruned Brazier modules may be given with the user modules.
fn check_framework_modules(
  modules: List(#(String, String)),
) -> Result(Nil, String) {
  list.try_each(modules, fn(module) {
    case
      reach.is_framework_module(module.0)
      && !reach.is_pruned_framework_module(module.0)
    {
      True ->
        Error(
          "Invariant violated: the Brazier module "
          <> module.0
          <> " was given to the analyzer; only "
          <> reach.stream_module
          <> " is analyzed with the user modules",
        )
      False -> Ok(Nil)
    }
  })
}

/// The user modules of `index`, without the pruned Brazier modules.
fn user_paths(index: reach.Index) -> Set(String) {
  dict.keys(index)
  |> list.filter(fn(path) { !reach.is_framework_module(path) })
  |> set.from_list
}

// ===== Streams =====

/// Check every `stream.new` and `stream.render` of the app's modules
/// (docs/design/STREAMS.md 10) and list the declared streams. All errors
/// are reported together, each naming its place.
fn streams(
  index: reach.Index,
  call: AppCall,
  client_reach: reach.Reach,
) -> Result(List(StreamDecl), String) {
  let modules = user_paths(index) |> set.to_list |> list.sort(string.compare)
  use uses <- result.try(
    reach.scan(index, modules)
    |> result.map_error(fn(errors) {
      list.each(errors, log.error("brazier.build.analyzer", _))
      string.join(errors, "\n")
    }),
  )
  let declared =
    list.filter_map(uses, fn(stream_use) {
      case stream_use {
        reach.Declared(at:, module:, owner:, name:) ->
          Ok(#(at, module, owner, name))
        reach.Rendered(..)
        | reach.Referenced(..)
        | reach.ReservedAttribute(..) -> Error(Nil)
      }
    })
  let named =
    list.filter_map(declared, fn(d) {
      case d.3 {
        Ok(name) -> Ok(#(name, d))
        Error(_) -> Error(Nil)
      }
    })
  let errors =
    list.flatten([
      list.filter_map(uses, stream_use_error),
      duplicate_stream_errors(named),
      simple_app_stream_errors(call, client_reach.streams),
    ])
    |> list.unique
    |> list.sort(string.compare)
  use Nil <- result.try(stream_errors(errors))
  let #(decls, errors) =
    list.map(named, fn(entry) {
      let #(name, #(at, module, owner, _)) = entry
      stream_item.item_type(index, module, owner)
      |> result.map(fn(item_type) { StreamDecl(name:, at:, item_type:) })
      |> result.map_error(fn(reason) {
        at <> ": the stream \"" <> name <> "\": " <> reason
      })
    })
    |> result.partition
  use Nil <- result.map(stream_errors(list.sort(errors, string.compare)))
  let decls = list.sort(decls, fn(a, b) { string.compare(a.name, b.name) })
  list.each(decls, fn(decl) {
    log.info(
      "brazier.build.analyzer",
      "Stream "
        <> decl.name
        <> " declared at "
        <> decl.at
        <> " (items: "
        <> option.unwrap(decl.item_type, "type not annotated")
        <> ")",
    )
  })
  decls
}

/// `Error` listing `errors`, each logged at error, when there is any.
fn stream_errors(errors: List(String)) -> Result(Nil, String) {
  case errors {
    [] -> Ok(Nil)
    errors -> {
      list.each(errors, log.error("brazier.build.analyzer", _))
      Error(
        "The app's streams break the build's rules (docs/design/STREAMS.md 10):\n"
        <> string.join(list.map(errors, fn(e) { "  " <> e }), "\n"),
      )
    }
  }
}

fn stream_use_error(stream_use: reach.StreamUse) -> Result(String, Nil) {
  case stream_use {
    reach.Declared(name: Ok(name), at:, ..) ->
      case stream.is_valid_name(name) {
        True -> Error(Nil)
        False ->
          Ok(
            at
            <> ": the stream name \""
            <> name
            <> "\" is not valid: a stream name is 1 to 64 characters of a-z, 0-9 and _, starting with a letter.",
          )
      }
    reach.Declared(name: Error(kind), at:, ..) ->
      Ok(
        at
        <> ": the name of a stream must be a string literal in the `stream.new` call, not "
        <> kind
        <> ". The build reads the names to check they are unique and to list them for the runtime and the client.",
      )
    reach.Rendered(item: Ok(Nil), ..) -> Error(Nil)
    reach.Rendered(item: Error(reach.UncheckedModule(written:, module:)), at:) ->
      Ok(
        at
        <> ": the item function of `stream.render` is `"
        <> written
        <> "`, from "
        <> module
        <> ", which the build does not analyze, so it cannot check that `"
        <> written
        <> "` is a named top-level function. Wrap it in a named function of an app module: `fn render_item(item) { "
        <> written
        <> "(item) }`, and pass `render_item`.",
      )
    reach.Rendered(item: Error(reach.NotNamedFunction(kind)), at:) ->
      Ok(
        at
        <> ": the item function of `stream.render` must be a named top-level function (`render_line` or `module.render_line`), not "
        <> kind
        <> ". The browser renders an item only when it is inserted or updated, so an item cannot depend on the model or Local state; put state that changes every item on the container's attributes, or insert the items again.",
      )
    reach.ReservedAttribute(at:, function:, name:, attribute:, written:) ->
      Ok(
        at
        <> ": `"
        <> function
        <> "(\""
        <> name
        <> "\", ..)`"
        <> case written {
          None -> ""
          Some(written) -> " (the name is " <> written <> ")"
        }
        <> reserved_attribute_reason(attribute),
      )
    reach.Referenced(at:, function:) ->
      Ok(
        at
        <> ": `stream."
        <> function
        <> "` is used as a value. Call it directly (`stream."
        <> function
        <> "(..)`) so the build can check its arguments.",
      )
  }
}

/// Why setting the reserved name `attribute` (lowercased) is refused, and
/// what to use instead.
fn reserved_attribute_reason(attribute: String) -> String {
  case attribute {
    _ if attribute == render.stream_attribute ->
      " sets data-brazier-stream, which marks a stream's container: the browser applies the stream's inserts and deletes to the element that carries it. Only `stream.render` sets it; render the stream with `stream.render(my_stream(), \"ol\", attributes, render_item)`."
    _ if attribute == render.key_attribute ->
      " sets data-brazier-key, which gives an element its identity for the browser's morph. Only the render sets it; key a child with `element.keyed(key, child)`, and a stream keys its items itself."
    _ ->
      " sets "
      <> attribute
      <> ", a name Brazier reserves for its client (docs/HTML_ELEMENTS.md). The `data-brazier-` names an app may set are "
      <> string.join(render.app_attributes, ", ")
      <> "; events go through `brazier/event`."
  }
}

fn duplicate_stream_errors(
  named: List(#(String, #(String, String, String, Result(String, String)))),
) -> List(String) {
  named
  |> list.group(fn(entry) { entry.0 })
  |> dict.to_list
  |> list.filter_map(fn(group) {
    let #(name, entries) = group
    let places =
      list.map(entries, fn(entry) { entry.1.0 })
      |> list.unique
      |> list.sort(string.compare)
    case places {
      [_, _, ..] ->
        Ok(
          "The stream name \""
          <> name
          <> "\" is declared more than once: at "
          <> string.join(places, " and at ")
          <> ". Stream names are global to the app; give each `stream.new` its own name.",
        )
      [] | [_] -> Error(Nil)
    }
  })
}

fn simple_app_stream_errors(
  call: AppCall,
  client_uses: List(reach.StreamUse),
) -> List(String) {
  case call.kind {
    app_call.Simple ->
      list.filter_map(client_uses, fn(stream_use) {
        case stream_use {
          reach.Rendered(at:, ..) ->
            Ok(
              at
              <> ": a `brazier.simple` app renders a stream, but a simple app's `update` returns no effects, so nothing can fill it. Build the app with `brazier.application` and fill the stream from `update` with `stream.insert`.",
            )
          reach.Declared(..)
          | reach.Referenced(..)
          | reach.ReservedAttribute(..) -> Error(Nil)
        }
      })
    app_call.Application | app_call.FullApplication -> []
  }
}

fn describe_ref(ref: FunctionRef) -> String {
  ref.module <> "." <> ref.name
}

fn to_item(ref: FunctionRef) -> reach.Item {
  reach.FunctionItem(ref.module, ref.name)
}

fn allow_roots(call: AppCall) -> List(reach.Item) {
  case call.local {
    app_call.NoLocal -> [to_item(call.view)]
    app_call.LocalLayer(init:, update:) -> [
      to_item(call.view),
      to_item(init),
      to_item(update),
    ]
  }
}

fn walk(
  index: reach.Index,
  roots: List(reach.Item),
) -> Result(reach.Reach, String) {
  reach.walk(index, client_modules, roots)
  |> result.map_error(fn(errors) {
    list.each(errors, log.error("brazier.build.analyzer", _))
    "Client code reaches code that cannot run in the browser:\n"
    <> string.join(list.map(errors, fn(e) { "  " <> e }), "\n")
  })
}

fn log_allowlist(
  msg: #(String, String),
  type_defs: Dict(#(String, String), TypeDef),
  allowed: Set(#(String, String)),
) -> Nil {
  let variants = case dict.get(type_defs, msg) {
    Ok(field_type.RecordDef(constructor:, ..)) -> [constructor]
    Ok(field_type.EnumDef(variants)) -> variants
    Ok(field_type.UnionDef(variants)) -> list.map(variants, fn(v) { v.0 })
    Ok(field_type.AliasDef(..))
    | Ok(field_type.UnsupportedDef(..))
    | Error(Nil) -> []
  }
  list.each(variants, fn(variant) {
    let verdict = case set.contains(allowed, #(msg.0, variant)) {
      True -> "accepted from the browser"
      False -> "server only (rejected from the browser)"
    }
    log.info("brazier.build.analyzer", "  " <> variant <> ": " <> verdict)
  })
}

/// Two module paths whose generated aliases are equal (`a/b_c` and
/// `a_b/c` are fine, `a__b` and `a/b` are not) cannot both be imported by
/// generated code.
fn check_aliases(paths: List(String)) -> Result(Nil, String) {
  // The same module twice is a caller bug, reported as such rather than as
  // an alias clash with itself.
  let clashes =
    list.unique(paths)
    |> list.group(codec_gen.module_alias)
    |> dict.values
    |> list.filter(fn(group) { list.length(group) > 1 })
  case clashes {
    [] -> Ok(Nil)
    [group, ..] -> {
      // Invariant: list.group never yields an empty group.
      let assert [first, ..] = group as "list.group produced an empty group"
      Error(
        "The modules "
        <> string.join(list.sort(group, string.compare), " and ")
        <> " map to the same generated alias "
        <> codec_gen.module_alias(first)
        <> ". Rename one of them.",
      )
    }
  }
}

// ===== Types =====

/// #(Model, Msg) from `view`'s first parameter and `Element(Msg)` return
/// annotations.
fn view_types(
  index: reach.Index,
  view: FunctionRef,
) -> Result(#(FieldType, #(String, String)), String) {
  // Invariant: app_call.resolve checked that `view` is a function in an
  // indexed module.
  let assert Ok(info) = dict.get(index, view.module)
    as "resolved view module is not indexed"
  let assert Ok(def) = dict.get(info.functions, view.name)
    as "resolved view function is not defined"
  let function = def.definition
  let scope = field_type.scope(info.ast, info.path, user_paths(index))
  let where =
    info.path
    <> ".gleam:"
    <> source_location.format_span(info.source, function.location)
    <> ": `"
    <> view.name
    <> "`"
  use model <- result.try(case function.parameters {
    [glance.FunctionParameter(type_: Some(type_), ..), ..] ->
      case field_type.resolve(scope, type_) {
        field_type.UnsupportedType(reason) ->
          Error(
            where <> "'s Model type cannot be sent to the browser: " <> reason,
          )
        model -> Ok(model)
      }
    [glance.FunctionParameter(type_: None, ..), ..] ->
      Error(
        where
        <> " needs a type annotation on its Model parameter (`fn "
        <> view.name
        <> "(model: Model) -> Element(Msg)`); the build reads the Model type from it.",
      )
    [] -> Error(where <> " must take the Model as its first parameter.")
  })
  use msg <- result.map(case function.return {
    Some(glance.NamedType(name:, module:, parameters: [msg_type], ..)) ->
      case is_element(info, module, name) {
        True ->
          case field_type.resolve(scope, msg_type) {
            field_type.NamedType(module:, name:) -> Ok(#(module, name))
            other ->
              Error(
                where
                <> " returns Element("
                <> field_type.describe(other)
                <> "). The Msg type must be a custom type defined in an app module.",
              )
          }
        False -> Error(where <> " must return brazier/element.Element(Msg).")
      }
    Some(_) -> Error(where <> " must return brazier/element.Element(Msg).")
    None ->
      Error(
        where
        <> " needs a return annotation (`-> Element(Msg)`); the build reads the Msg type from it.",
      )
  })
  #(model, msg)
}

fn is_element(
  info: reach.ModuleInfo,
  qualifier: option.Option(String),
  name: String,
) -> Bool {
  is_type(info, qualifier, name, element_module, "Element")
}

/// True when `qualifier.name` (or `name` unqualified) written in `info`'s
/// module names `module.type_name`.
fn is_type(
  info: reach.ModuleInfo,
  qualifier: option.Option(String),
  name: String,
  module: String,
  type_name: String,
) -> Bool {
  case qualifier {
    Some(qualifier) ->
      name == type_name && dict.get(info.aliases, qualifier) == Ok(module)
    None -> dict.get(info.types, name) == Ok(#(module, type_name))
  }
}

/// Every user type, with type aliases expanded inside the definitions. The
/// pruned Brazier modules' types are not user types: no codec is generated
/// for them.
fn type_defs(
  index: reach.Index,
) -> Result(Dict(#(String, String), TypeDef), String) {
  let known = user_paths(index)
  let raw =
    dict.fold(index, dict.new(), fn(acc, path, info) {
      use <- bool.guard(!set.contains(known, path), acc)
      let scope = field_type.scope(info.ast, path, known)
      let acc =
        list.fold(info.ast.custom_types, acc, fn(acc, def) {
          dict.insert(
            acc,
            #(path, def.definition.name),
            field_type.custom_type_def(scope, def.definition),
          )
        })
      list.fold(info.ast.type_aliases, acc, fn(acc, def) {
        dict.insert(
          acc,
          #(path, def.definition.name),
          field_type.type_alias_def(scope, def.definition),
        )
      })
    })
  let aliases = aliases_of(raw)
  let expand = field_type.expand_aliases(_, aliases)
  Ok(
    dict.map_values(raw, fn(_key, def) {
      case def {
        field_type.RecordDef(constructor:, fields:) ->
          field_type.RecordDef(
            constructor:,
            fields: list.map(fields, fn(f) { #(f.0, expand(f.1)) }),
          )
        field_type.UnionDef(variants) ->
          field_type.UnionDef(
            list.map(variants, fn(v) { #(v.0, list.map(v.1, expand)) }),
          )
        field_type.AliasDef(target) -> field_type.AliasDef(expand(target))
        field_type.EnumDef(..) | field_type.UnsupportedDef(..) -> def
      }
    }),
  )
}

fn aliases_of(
  defs: Dict(#(String, String), TypeDef),
) -> Dict(#(String, String), FieldType) {
  dict.fold(defs, dict.new(), fn(acc, key, def) {
    case def {
      field_type.AliasDef(target) -> dict.insert(acc, key, target)
      _ -> acc
    }
  })
}

/// Every user type reachable from `roots` through all variants' fields.
/// The server sends the whole Model, so every type it reaches must have a
/// codec. Msg types are checked by codec generation, which sees only the
/// constructors the browser builds.
fn check_model_types(
  defs: Dict(#(String, String), TypeDef),
  model_closure: Set(#(String, String)),
) -> Result(Nil, String) {
  model_closure
  |> set.to_list
  |> list.sort(fn(a, b) { string.compare(a.0 <> "." <> a.1, b.0 <> "." <> b.1) })
  |> list.try_each(fn(key) {
    let name = field_type.qualified_name(key.0, key.1)
    let fail = fn(reason) {
      Error(
        "The Model type "
        <> name
        <> " cannot be sent to the browser: "
        <> reason,
      )
    }
    case dict.get(defs, key) {
      Ok(field_type.UnsupportedDef(reason)) -> fail(reason)
      Ok(field_type.RecordDef(fields:, ..)) ->
        list.try_each(fields, fn(field) {
          case field_type.unsupported_reason(field.1) {
            Ok(reason) -> fail("field `" <> field.0 <> "`: " <> reason)
            Error(Nil) -> Ok(Nil)
          }
        })
      Ok(field_type.UnionDef(variants)) ->
        list.try_each(variants, fn(variant) {
          case list.find_map(variant.1, field_type.unsupported_reason) {
            Ok(reason) -> fail("variant `" <> variant.0 <> "`: " <> reason)
            Error(Nil) -> Ok(Nil)
          }
        })
      Ok(field_type.AliasDef(target)) ->
        case field_type.unsupported_reason(target) {
          Ok(reason) -> fail(reason)
          Error(Nil) -> Ok(Nil)
        }
      Ok(field_type.EnumDef(..)) -> Ok(Nil)
      Error(Nil) -> fail("its definition is not among the analyzed modules")
    }
  })
}

/// #(module, constructor) for every constructor of `types`.
fn constructors_of(
  defs: Dict(#(String, String), TypeDef),
  types: Set(#(String, String)),
) -> Set(#(String, String)) {
  set.fold(types, set.new(), fn(acc, key) {
    let names = case dict.get(defs, key) {
      Ok(field_type.RecordDef(constructor:, ..)) -> [constructor]
      Ok(field_type.EnumDef(variants)) -> variants
      Ok(field_type.UnionDef(variants)) -> list.map(variants, fn(v) { v.0 })
      Ok(field_type.AliasDef(..))
      | Ok(field_type.UnsupportedDef(..))
      | Error(Nil) -> []
    }
    list.fold(names, acc, fn(acc, name) { set.insert(acc, #(key.0, name)) })
  })
}

fn closure(
  defs: Dict(#(String, String), TypeDef),
  roots: List(#(String, String)),
) -> Set(#(String, String)) {
  closure_loop(defs, roots, set.new())
}

fn closure_loop(
  defs: Dict(#(String, String), TypeDef),
  pending: List(#(String, String)),
  seen: Set(#(String, String)),
) -> Set(#(String, String)) {
  case pending {
    [] -> seen
    [key, ..rest] ->
      case set.contains(seen, key) {
        True -> closure_loop(defs, rest, seen)
        False -> {
          let fields = case dict.get(defs, key) {
            Ok(field_type.RecordDef(fields:, ..)) ->
              list.map(fields, fn(f) { f.1 })
            Ok(field_type.UnionDef(variants)) ->
              list.flat_map(variants, fn(v) { v.1 })
            Ok(field_type.AliasDef(target)) -> [target]
            Ok(field_type.EnumDef(..))
            | Ok(field_type.UnsupportedDef(..))
            | Error(Nil) -> []
          }
          closure_loop(
            defs,
            list.append(list.flat_map(fields, field_type.named_types), rest),
            set.insert(seen, key),
          )
        }
      }
  }
}
