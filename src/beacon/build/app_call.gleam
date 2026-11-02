/// Finds the app constructor call in an app module: the one call to
/// `beacon.simple`, `beacon.application` or `beacon.full_application` that
/// `pub fn main` reaches, and the functions passed to it.
///
/// Only what the client needs is resolved: `view`, a `simple` app's
/// `update`, and a Local layer's `init` and `update`. Each must be a named
/// function (`view`, `module.view`, or a shorthand `view:` label), so the
/// build can compile it for the browser. `init`, a server `update` and
/// `sync` run only on the server and may be anything.
import beacon/build/reach.{type ModuleInfo}
import beacon/build/source_location
import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// The framework module the constructors live in.
const beacon_module = "beacon"

const local_module = "beacon/local"

pub type Kind {
  /// `beacon.simple`: a pure update compiled to JavaScript too.
  Simple
  /// `beacon.application`: a server-only update with effects.
  Application
  /// `beacon.full_application`: state, `sync`, a Local layer and `view`.
  FullApplication
}

/// A function named by the app call: #(module path, function name).
pub type FunctionRef {
  FunctionRef(module: String, name: String)
}

pub type LocalLayer {
  NoLocal
  LocalLayer(init: FunctionRef, update: FunctionRef)
}

pub type AppCall {
  AppCall(
    kind: Kind,
    view: FunctionRef,
    /// The client-side update of a `simple` app.
    update: Option(FunctionRef),
    local: LocalLayer,
  )
}

pub fn kind_name(kind: Kind) -> String {
  case kind {
    Simple -> "simple"
    Application -> "application"
    FullApplication -> "full_application"
  }
}

fn kind_of(name: String) -> Result(Kind, Nil) {
  case name {
    "simple" -> Ok(Simple)
    "application" -> Ok(Application)
    "full_application" -> Ok(FullApplication)
    _ -> Error(Nil)
  }
}

fn parameters(kind: Kind) -> List(String) {
  case kind {
    Simple | Application -> ["init", "update", "view"]
    FullApplication -> ["init", "update", "sync", "local", "view"]
  }
}

/// A constructor call found in the app module.
type Found {
  Found(
    kind: Kind,
    owner: String,
    location: glance.Span,
    arguments: List(glance.Field(glance.Expression)),
  )
}

/// True when `pub fn main` reaches an app constructor call. Discovery uses
/// this to tell the app module from other modules that import `beacon`.
pub fn defines_app(info: ModuleInfo) -> Bool {
  case dict.get(info.functions, "main") {
    Ok(def) -> def.definition.publicity == glance.Public && find(info) != []
    Error(Nil) -> False
  }
}

/// The app call of the app module `info`, with its functions resolved
/// against `index`.
pub fn resolve(
  index: reach.Index,
  info: ModuleInfo,
) -> Result(AppCall, String) {
  use main <- result.try(case dict.get(info.functions, "main") {
    Ok(def) ->
      case def.definition.publicity {
        glance.Public -> Ok(def)
        glance.Private ->
          Error(info.path <> ".gleam: `fn main` must be `pub fn main`.")
      }
    Error(Nil) ->
      Error(
        info.path
        <> ".gleam has no `pub fn main`. The app module's `main` must build the app with beacon.simple, beacon.application or beacon.full_application.",
      )
  })
  case find(info) {
    [] ->
      Error(
        info.path
        <> ".gleam:"
        <> source_location.format_span(info.source, main.definition.location)
        <> ": `pub fn main` does not reach a call to beacon.simple, beacon.application or beacon.full_application.",
      )
    [found] -> resolve_found(index, info, found)
    many ->
      Error(
        info.path
        <> ".gleam: `pub fn main` reaches more than one app constructor call ("
        <> string.join(
          list.map(many, fn(found) {
            "beacon."
            <> kind_name(found.kind)
            <> " at "
            <> source_location.format_span(info.source, found.location)
          }),
          ", ",
        )
        <> "). Build exactly one app.",
      )
  }
}

fn resolve_found(
  index: reach.Index,
  info: ModuleInfo,
  found: Found,
) -> Result(AppCall, String) {
  let where =
    info.path
    <> ".gleam:"
    <> source_location.format_span(info.source, found.location)
    <> ": beacon."
    <> kind_name(found.kind)
  use arguments <- result.try(
    bind_arguments(parameters(found.kind), found.arguments)
    |> result.map_error(fn(reason) { where <> ": " <> reason }),
  )
  let argument = fn(label) {
    // Invariant: bind_arguments returns exactly the constructor's labels.
    let assert Ok(expr) = dict.get(arguments, label)
      as "bound app constructor arguments lack a label"
    expr
  }
  use view <- result.try(function_ref(
    index,
    info,
    where,
    "view",
    argument("view"),
  ))
  use update <- result.try(case found.kind {
    Simple ->
      function_ref(index, info, where, "update", argument("update"))
      |> result.map(Some)
    Application | FullApplication -> Ok(None)
  })
  use local <- result.map(case found.kind {
    FullApplication -> local_layer(index, info, where, argument("local"))
    Simple | Application -> Ok(NoLocal)
  })
  AppCall(kind: found.kind, view:, update:, local:)
}

/// Map call arguments to parameter labels: labelled ones by label, then the
/// unlabelled ones, in order, to the parameters still open.
fn bind_arguments(
  labels: List(String),
  arguments: List(glance.Field(glance.Expression)),
) -> Result(dict.Dict(String, glance.Expression), String) {
  use #(labelled, positional) <- result.try(
    list.try_fold(arguments, #(dict.new(), []), fn(acc, field) {
      let #(labelled, positional) = acc
      case field {
        glance.LabelledField(label:, item:, ..) ->
          add_label(labels, labelled, label, item)
          |> result.map(fn(labelled) { #(labelled, positional) })
        glance.ShorthandField(label:, location:) ->
          add_label(
            labels,
            labelled,
            label,
            glance.Variable(location:, name: label),
          )
          |> result.map(fn(labelled) { #(labelled, positional) })
        glance.UnlabelledField(item:) -> Ok(#(labelled, [item, ..positional]))
      }
    }),
  )
  let open = list.filter(labels, fn(label) { !dict.has_key(labelled, label) })
  let positional = list.reverse(positional)
  case list.length(open) == list.length(positional) {
    False ->
      Error(
        "expected the arguments "
        <> string.join(labels, ", ")
        <> ", got "
        <> string.inspect(dict.size(labelled) + list.length(positional)),
      )
    True ->
      Ok(
        list.zip(open, positional)
        |> list.fold(labelled, fn(acc, pair) {
          dict.insert(acc, pair.0, pair.1)
        }),
      )
  }
}

fn add_label(
  labels: List(String),
  labelled: dict.Dict(String, glance.Expression),
  label: String,
  item: glance.Expression,
) -> Result(dict.Dict(String, glance.Expression), String) {
  case list.contains(labels, label), dict.has_key(labelled, label) {
    False, _ -> Error("unknown argument `" <> label <> ":`")
    True, True -> Error("argument `" <> label <> ":` is given twice")
    True, False -> Ok(dict.insert(labelled, label, item))
  }
}

/// The `pub` user function an argument names.
fn function_ref(
  index: reach.Index,
  info: ModuleInfo,
  where: String,
  label: String,
  expr: glance.Expression,
) -> Result(FunctionRef, String) {
  let not_named =
    where
    <> ": `"
    <> label
    <> ":` must name a `pub fn` in an app module (`"
    <> label
    <> "`, `module."
    <> label
    <> "`), so the build can compile it for the browser. An anonymous function or other expression cannot be compiled on its own."
  use ref <- result.try(case expr {
    glance.Variable(name:, ..) ->
      case dict.has_key(info.functions, name), dict.get(info.values, name) {
        True, _ -> Ok(FunctionRef(info.path, name))
        False, Ok(#(module, original)) -> Ok(FunctionRef(module, original))
        False, Error(Nil) -> Error(not_named)
      }
    glance.FieldAccess(
      container: glance.Variable(name: qualifier, ..),
      label:,
      ..,
    ) ->
      case dict.get(info.aliases, qualifier) {
        Ok(module) -> Ok(FunctionRef(module, label))
        Error(Nil) -> Error(not_named)
      }
    _ -> Error(not_named)
  })
  case dict.get(index, ref.module) {
    Error(Nil) ->
      Error(
        where
        <> ": `"
        <> label
        <> ":` names "
        <> ref.module
        <> "."
        <> ref.name
        <> ", which is not in an app module. Client code must be app code the build can analyze.",
      )
    Ok(target) ->
      case dict.get(target.functions, ref.name) {
        Error(Nil) ->
          Error(
            where
            <> ": `"
            <> label
            <> ":` names "
            <> ref.module
            <> "."
            <> ref.name
            <> ", which is not a function.",
          )
        Ok(def) ->
          case def.definition.publicity {
            glance.Public -> Ok(ref)
            glance.Private ->
              Error(
                where
                <> ": `"
                <> label
                <> ":` names `fn "
                <> ref.name
                <> "` in "
                <> ref.module
                <> ".gleam, which is not `pub`. The client entry calls it from another module; make it `pub fn "
                <> ref.name
                <> "`.",
              )
          }
      }
  }
}

/// `local.none()` or `local.layer(init:, update:)`.
fn local_layer(
  index: reach.Index,
  info: ModuleInfo,
  where: String,
  expr: glance.Expression,
) -> Result(LocalLayer, String) {
  let invalid =
    where
    <> ": `local:` must be `local.none()` or `local.layer(init: .., update: ..)` written in the call, so the build can find the Local layer's functions."
  case expr {
    glance.Call(function:, arguments:, ..) ->
      case local_function(info, function) {
        Ok("none") ->
          case arguments {
            [] -> Ok(NoLocal)
            _ -> Error(invalid)
          }
        Ok("layer") -> {
          use bound <- result.try(
            bind_arguments(["init", "update"], arguments)
            |> result.map_error(fn(reason) {
              where <> ": local.layer: " <> reason
            }),
          )
          // Invariant: bind_arguments returns exactly the given labels.
          let assert Ok(init) = dict.get(bound, "init")
            as "bound local.layer arguments lack init"
          let assert Ok(update) = dict.get(bound, "update")
            as "bound local.layer arguments lack update"
          use init <- result.try(function_ref(
            index,
            info,
            where <> " local.layer",
            "init",
            init,
          ))
          use update <- result.map(function_ref(
            index,
            info,
            where <> " local.layer",
            "update",
            update,
          ))
          LocalLayer(init:, update:)
        }
        _ -> Error(invalid)
      }
    _ -> Error(invalid)
  }
}

/// The name of the `beacon/local` function `expr` refers to.
fn local_function(
  info: ModuleInfo,
  expr: glance.Expression,
) -> Result(String, Nil) {
  case expr {
    glance.FieldAccess(
      container: glance.Variable(name: qualifier, ..),
      label:,
      ..,
    ) ->
      case dict.get(info.aliases, qualifier) {
        Ok(module) if module == local_module -> Ok(label)
        _ -> Error(Nil)
      }
    glance.Variable(name:, ..) ->
      case dict.get(info.values, name) {
        Ok(#(module, original)) if module == local_module -> Ok(original)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// ===== Finding the call =====

/// Every constructor call in the app-module functions `main` reaches through
/// calls to functions of the same module, in source order.
fn find(info: ModuleInfo) -> List(Found) {
  reachable_functions(info, ["main"], set.new())
  |> set.to_list
  |> list.sort(string.compare)
  |> list.flat_map(fn(name) {
    case dict.get(info.functions, name) {
      Ok(def) -> scan_statements(info, name, def.definition.body, #([], [])).0
      Error(Nil) -> []
    }
  })
  |> list.sort(fn(a, b) { int.compare(a.location.start, b.location.start) })
}

fn reachable_functions(
  info: ModuleInfo,
  pending: List(String),
  seen: Set(String),
) -> Set(String) {
  case pending {
    [] -> seen
    [name, ..rest] ->
      case set.contains(seen, name), dict.get(info.functions, name) {
        False, Ok(def) -> {
          let #(_, names) =
            scan_statements(info, name, def.definition.body, #([], []))
          let next =
            list.filter(names, fn(n) { dict.has_key(info.functions, n) })
          reachable_functions(
            info,
            list.append(next, rest),
            set.insert(seen, name),
          )
        }
        _, _ -> reachable_functions(info, rest, seen)
      }
  }
}

/// #(constructor calls, referenced variable names).
type Scan =
  #(List(Found), List(String))

fn scan_statements(
  info: ModuleInfo,
  owner: String,
  statements: List(glance.Statement),
  acc: Scan,
) -> Scan {
  list.fold(statements, acc, fn(acc, statement) {
    case statement {
      glance.Use(function:, ..) -> scan(info, owner, function, acc)
      glance.Assignment(value:, ..) -> scan(info, owner, value, acc)
      glance.Assert(expression:, ..) -> scan(info, owner, expression, acc)
      glance.Expression(expression) -> scan(info, owner, expression, acc)
    }
  })
}

fn scan(
  info: ModuleInfo,
  owner: String,
  expr: glance.Expression,
  acc: Scan,
) -> Scan {
  case expr {
    glance.BinaryOperator(
      name: glance.Pipe,
      left:,
      right: glance.Call(location:, function:, arguments:),
      ..,
    ) ->
      case constructor(info, function) {
        Ok(kind) -> {
          let arguments = [glance.UnlabelledField(left), ..arguments]
          let #(found, names) = scan_fields(info, owner, arguments, acc)
          #([Found(kind:, owner:, location:, arguments:), ..found], names)
        }
        Error(Nil) -> scan_children(info, owner, expr, acc)
      }
    glance.Call(location:, function:, arguments:) ->
      case constructor(info, function) {
        Ok(kind) -> {
          let #(found, names) = scan_fields(info, owner, arguments, acc)
          #([Found(kind:, owner:, location:, arguments:), ..found], names)
        }
        Error(Nil) -> scan_children(info, owner, expr, acc)
      }
    glance.Variable(name:, ..) -> #(acc.0, [name, ..acc.1])
    _ -> scan_children(info, owner, expr, acc)
  }
}

fn scan_fields(
  info: ModuleInfo,
  owner: String,
  fields: List(glance.Field(glance.Expression)),
  acc: Scan,
) -> Scan {
  list.fold(fields, acc, fn(acc, field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        scan(info, owner, item, acc)
      glance.ShorthandField(label:, ..) -> #(acc.0, [label, ..acc.1])
    }
  })
}

fn scan_children(
  info: ModuleInfo,
  owner: String,
  expr: glance.Expression,
  acc: Scan,
) -> Scan {
  let all = fn(exprs: List(glance.Expression), acc) {
    list.fold(exprs, acc, fn(acc, e) { scan(info, owner, e, acc) })
  }
  let maybe = fn(expr: Option(glance.Expression), acc) {
    case expr {
      Some(e) -> scan(info, owner, e, acc)
      None -> acc
    }
  }
  case expr {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> acc
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      scan(info, owner, value, acc)
    glance.Block(statements:, ..) ->
      scan_statements(info, owner, statements, acc)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      maybe(message, acc)
    glance.Tuple(elements:, ..) -> all(elements, acc)
    glance.List(elements:, rest:, ..) -> maybe(rest, all(elements, acc))
    glance.Fn(body:, ..) -> scan_statements(info, owner, body, acc)
    glance.RecordUpdate(record:, fields:, ..) ->
      list.fold(fields, scan(info, owner, record, acc), fn(acc, field) {
        maybe(field.item, acc)
      })
    glance.FieldAccess(container:, ..) -> scan(info, owner, container, acc)
    glance.Call(function:, arguments:, ..) ->
      scan_fields(info, owner, arguments, scan(info, owner, function, acc))
    glance.TupleIndex(tuple:, ..) -> scan(info, owner, tuple, acc)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      scan(info, owner, function, acc)
      |> scan_fields(info, owner, arguments_before, _)
      |> scan_fields(info, owner, arguments_after, _)
    glance.BitString(segments:, ..) ->
      all(list.map(segments, fn(segment) { segment.0 }), acc)
    glance.Case(subjects:, clauses:, ..) ->
      list.fold(clauses, all(subjects, acc), fn(acc, clause) {
        scan(info, owner, clause.body, maybe(clause.guard, acc))
      })
    glance.BinaryOperator(left:, right:, ..) ->
      scan(info, owner, right, scan(info, owner, left, acc))
    glance.Echo(expression:, message:, ..) ->
      maybe(message, maybe(expression, acc))
  }
}

/// The constructor `function` names, if it is `beacon.simple`,
/// `beacon.application` or `beacon.full_application`.
fn constructor(
  info: ModuleInfo,
  function: glance.Expression,
) -> Result(Kind, Nil) {
  case function {
    glance.FieldAccess(
      container: glance.Variable(name: qualifier, ..),
      label:,
      ..,
    ) ->
      case dict.get(info.aliases, qualifier) {
        Ok(module) if module == beacon_module -> kind_of(label)
        _ -> Error(Nil)
      }
    glance.Variable(name:, ..) ->
      case dict.get(info.values, name) {
        Ok(#(module, original)) if module == beacon_module -> kind_of(original)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}
