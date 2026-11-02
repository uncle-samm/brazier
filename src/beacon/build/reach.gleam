/// Scope-aware reachability over the app's user modules, and the client
/// modules emitted from what is reached.
///
/// The walk starts from named functions (the app's `view`, a `simple` app's
/// `update`, a Local layer's `init` and `update`) and follows every
/// reference to a user function, constant, type or constructor. Local
/// bindings (parameters, `let`, `use`, `case` patterns, `fn` arguments) are
/// tracked, so a variable named like a module function or an import alias is
/// never mistaken for it.
///
/// A reference into a Beacon module outside the client allowlist is an
/// error naming the call site. References into dependencies are not
/// followed: whether a package runs on JavaScript is the JavaScript
/// compiler's call.
///
/// Emission slices the source of each reached definition out of its file
/// and regenerates the imports from what those definitions use, so a
/// server-only import, function, constant or type never reaches the client
/// project.
import beacon/build/field_type
import beacon/build/source_location
import glance
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// What one parsed user module defines and imports.
pub type ModuleInfo {
  ModuleInfo(
    path: String,
    source: String,
    ast: glance.Module,
    /// Import alias as written in this file -> module path.
    aliases: Dict(String, String),
    /// Unqualified imported value (as named here) -> #(module, original name).
    values: Dict(String, #(String, String)),
    /// Unqualified imported type (as named here) -> #(module, original name).
    types: Dict(String, #(String, String)),
    functions: Dict(String, glance.Definition(glance.Function)),
    constants: Dict(String, glance.Definition(glance.Constant)),
    custom_types: Dict(String, glance.Definition(glance.CustomType)),
    type_aliases: Dict(String, glance.Definition(glance.TypeAlias)),
    /// Constructor name -> the name of the custom type that defines it.
    constructors: Dict(String, String),
  )
}

/// Every user module the build analyzes, by module path.
pub type Index =
  Dict(String, ModuleInfo)

/// A top-level definition in a user module.
pub type Item {
  FunctionItem(module: String, name: String)
  ConstantItem(module: String, name: String)
  /// A custom type or a type alias.
  TypeItem(module: String, name: String)
}

/// What the reached definitions of one module use from its imports.
pub type Usage {
  Usage(
    /// Import aliases used as `alias.name` or `alias.Type`.
    qualifiers: Set(String),
    /// Unqualified imported values, as named in the file.
    values: Set(String),
    /// Unqualified imported types, as named in the file.
    types: Set(String),
  )
}

pub type Reach {
  Reach(
    items: Set(Item),
    /// #(module, constructor) for every constructor the reached code uses as
    /// a value (called, passed, or updated), never as a pattern.
    built: Set(#(String, String)),
    usage: Dict(String, Usage),
  )
}

/// True for the modules Beacon itself provides: `beacon` and `beacon/*`.
pub fn is_framework_module(module_path: String) -> Bool {
  module_path == "beacon" || string.starts_with(module_path, "beacon/")
}

/// Index parsed modules, given as #(module path, source, AST).
pub fn index(
  modules: List(#(String, String, glance.Module)),
) -> Result(Index, String) {
  list.try_fold(modules, dict.new(), fn(acc, entry) {
    let #(path, source, ast) = entry
    case dict.has_key(acc, path) {
      True -> Error("Module " <> path <> " was given to the analyzer twice")
      False -> Ok(dict.insert(acc, path, module_info(path, source, ast)))
    }
  })
}

pub fn module_info(
  path: String,
  source: String,
  ast: glance.Module,
) -> ModuleInfo {
  let #(aliases, values, types) =
    list.fold(ast.imports, #(dict.new(), dict.new(), dict.new()), fn(acc, def) {
      let import_ = def.definition
      let #(aliases, values, types) = acc
      let aliases = case field_type.import_alias(import_) {
        Ok(alias) -> dict.insert(aliases, alias, import_.module)
        Error(Nil) -> aliases
      }
      let add = fn(table, items: List(glance.UnqualifiedImport)) {
        list.fold(items, table, fn(table, item) {
          dict.insert(table, option.unwrap(item.alias, item.name), #(
            import_.module,
            item.name,
          ))
        })
      }
      #(
        aliases,
        add(values, import_.unqualified_values),
        add(types, import_.unqualified_types),
      )
    })
  let by_name = fn(defs: List(glance.Definition(a)), name: fn(a) -> String) {
    list.fold(defs, dict.new(), fn(acc, def) {
      dict.insert(acc, name(def.definition), def)
    })
  }
  let constructors =
    list.fold(ast.custom_types, dict.new(), fn(acc, def) {
      list.fold(def.definition.variants, acc, fn(acc, variant) {
        dict.insert(acc, variant.name, def.definition.name)
      })
    })
  ModuleInfo(
    path:,
    source:,
    ast:,
    aliases:,
    values:,
    types:,
    functions: by_name(ast.functions, fn(f: glance.Function) { f.name }),
    constants: by_name(ast.constants, fn(c: glance.Constant) { c.name }),
    custom_types: by_name(ast.custom_types, fn(t: glance.CustomType) { t.name }),
    type_aliases: by_name(ast.type_aliases, fn(t: glance.TypeAlias) { t.name }),
    constructors:,
  )
}

// ===== The walk =====

type State {
  State(
    seen: Set(Item),
    pending: List(Item),
    built: Set(#(String, String)),
    usage: Dict(String, Usage),
    errors: List(String),
  )
}

type Ctx {
  Ctx(
    index: Index,
    /// Beacon modules client code may use.
    allowed: Set(String),
    info: ModuleInfo,
    /// The definition being walked, for messages.
    owner: String,
  )
}

/// Everything reachable from `roots`. `allowed` lists the Beacon modules
/// client code may use; reaching any other Beacon module is an error. All
/// errors are returned, each naming its call site.
pub fn walk(
  index: Index,
  allowed: List(String),
  roots: List(Item),
) -> Result(Reach, List(String)) {
  let state =
    run(
      State(
        seen: set.new(),
        pending: roots,
        built: set.new(),
        usage: dict.new(),
        errors: [],
      ),
      index,
      set.from_list(allowed),
    )
  case state.errors {
    [] -> Ok(Reach(items: state.seen, built: state.built, usage: state.usage))
    errors -> Error(list.unique(list.reverse(errors)))
  }
}

fn run(st: State, index: Index, allowed: Set(String)) -> State {
  case st.pending {
    [] -> st
    [item, ..rest] -> {
      let st = State(..st, pending: rest)
      case set.contains(st.seen, item) {
        True -> run(st, index, allowed)
        False ->
          State(..st, seen: set.insert(st.seen, item))
          |> visit(index, allowed, item)
          |> run(index, allowed)
      }
    }
  }
}

fn visit(st: State, index: Index, allowed: Set(String), item: Item) -> State {
  case dict.get(index, item.module) {
    Error(Nil) ->
      add_error(
        st,
        "Invariant violated: reached "
          <> describe_item(item)
          <> " outside the analyzed modules",
      )
    Ok(info) -> {
      let ctx = Ctx(index:, allowed:, info:, owner: item.name)
      case item {
        FunctionItem(name:, ..) ->
          case dict.get(info.functions, name) {
            Ok(def) -> visit_function(st, ctx, def)
            Error(Nil) -> missing(st, item)
          }
        ConstantItem(name:, ..) ->
          case dict.get(info.constants, name) {
            Ok(def) -> {
              let st = walk_optional_type(st, ctx, def.definition.annotation)
              walk_expr(st, ctx, set.new(), def.definition.value)
            }
            Error(Nil) -> missing(st, item)
          }
        TypeItem(name:, ..) ->
          case
            dict.get(info.custom_types, name),
            dict.get(info.type_aliases, name)
          {
            Ok(def), _ ->
              list.fold(def.definition.variants, st, fn(st, variant) {
                list.fold(variant.fields, st, fn(st, field) {
                  walk_type(st, ctx, field.item)
                })
              })
            Error(Nil), Ok(def) -> walk_type(st, ctx, def.definition.aliased)
            Error(Nil), Error(Nil) -> missing(st, item)
          }
      }
    }
  }
}

fn missing(st: State, item: Item) -> State {
  add_error(
    st,
    "Invariant violated: "
      <> describe_item(item)
      <> " was reached but is not defined",
  )
}

fn describe_item(item: Item) -> String {
  case item {
    FunctionItem(module:, name:) -> "function " <> module <> "." <> name
    ConstantItem(module:, name:) -> "constant " <> module <> "." <> name
    TypeItem(module:, name:) -> "type " <> module <> "." <> name
  }
}

fn visit_function(
  st: State,
  ctx: Ctx,
  def: glance.Definition(glance.Function),
) -> State {
  let glance.Definition(attributes:, definition: function) = def
  let st = case erlang_only(attributes, function) {
    True ->
      add_error(
        st,
        at(ctx, function.location)
          <> ": `"
          <> ctx.info.path
          <> "."
          <> function.name
          <> "` is implemented only in Erlang (`@external(erlang, ..)`) and has no Gleam body, so it cannot run in the browser. Give it an `@external(javascript, ..)` implementation or a Gleam body, or keep it out of client code.",
      )
    False -> st
  }
  let st =
    list.fold(function.parameters, st, fn(st, param) {
      walk_optional_type(st, ctx, param.type_)
    })
  let st = walk_optional_type(st, ctx, function.return)
  let locals =
    list.fold(function.parameters, set.new(), fn(acc, param) {
      bind_name(acc, param.name)
    })
  walk_statements(st, ctx, locals, function.body)
}

fn erlang_only(
  attributes: List(glance.Attribute),
  function: glance.Function,
) -> Bool {
  function.body == []
  && list.any(attributes, is_external_for(_, "erlang"))
  && !list.any(attributes, is_external_for(_, "javascript"))
}

fn is_external_for(attribute: glance.Attribute, target: String) -> Bool {
  case attribute {
    glance.Attribute(
      name: "external",
      arguments: [glance.Variable(name:, ..), ..],
    ) -> name == target
    _ -> False
  }
}

/// `@external(javascript, "path", "name")` as #(path, name).
pub fn javascript_external(
  attributes: List(glance.Attribute),
) -> Option(#(String, String)) {
  list.find_map(attributes, fn(attribute) {
    case attribute {
      glance.Attribute(
        name: "external",
        arguments: [
          glance.Variable(name: "javascript", ..),
          glance.String(value: path, ..),
          glance.String(value: name, ..),
        ],
      ) -> Ok(#(path, name))
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn at(ctx: Ctx, span: glance.Span) -> String {
  ctx.info.path
  <> ".gleam:"
  <> source_location.format_span(ctx.info.source, span)
}

fn add_error(st: State, message: String) -> State {
  State(..st, errors: [message, ..st.errors])
}

fn add_item(st: State, item: Item) -> State {
  case set.contains(st.seen, item) {
    True -> st
    False -> State(..st, pending: [item, ..st.pending])
  }
}

fn use_qualifier(st: State, ctx: Ctx, qualifier: String) -> State {
  update_usage(st, ctx.info.path, fn(usage) {
    Usage(..usage, qualifiers: set.insert(usage.qualifiers, qualifier))
  })
}

fn use_value(st: State, ctx: Ctx, name: String) -> State {
  update_usage(st, ctx.info.path, fn(usage) {
    Usage(..usage, values: set.insert(usage.values, name))
  })
}

fn use_type(st: State, ctx: Ctx, name: String) -> State {
  update_usage(st, ctx.info.path, fn(usage) {
    Usage(..usage, types: set.insert(usage.types, name))
  })
}

fn update_usage(st: State, module: String, f: fn(Usage) -> Usage) -> State {
  let usage = case dict.get(st.usage, module) {
    Ok(usage) -> usage
    Error(Nil) -> Usage(set.new(), set.new(), set.new())
  }
  State(..st, usage: dict.insert(st.usage, module, f(usage)))
}

// ----- Names -----

fn is_upper_name(name: String) -> Bool {
  case string.first(name) {
    Ok(first) ->
      string.uppercase(first) == first && string.lowercase(first) != first
    Error(Nil) -> False
  }
}

fn bind_name(locals: Set(String), name: glance.AssignmentName) -> Set(String) {
  case name {
    glance.Named(name) -> set.insert(locals, name)
    glance.Discarded(_) -> locals
  }
}

/// An unqualified value reference: a local variable, a definition in this
/// module, an unqualified import, or a prelude name.
fn ref_value(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  name: String,
  span: glance.Span,
  as_value: Bool,
) -> State {
  case set.contains(locals, name) {
    True -> st
    False -> {
      let module = ctx.info.path
      case is_upper_name(name) {
        True ->
          case dict.get(ctx.info.constructors, name) {
            Ok(type_name) -> constructor(st, module, type_name, name, as_value)
            Error(Nil) -> imported_value(st, ctx, name, span, as_value)
          }
        False ->
          case
            dict.has_key(ctx.info.functions, name),
            dict.has_key(ctx.info.constants, name)
          {
            True, _ -> add_item(st, FunctionItem(module, name))
            False, True -> add_item(st, ConstantItem(module, name))
            False, False -> imported_value(st, ctx, name, span, as_value)
          }
      }
    }
  }
}

fn imported_value(
  st: State,
  ctx: Ctx,
  name: String,
  span: glance.Span,
  as_value: Bool,
) -> State {
  case dict.get(ctx.info.values, name) {
    Ok(#(module, original)) ->
      use_value(st, ctx, name)
      |> external_value(ctx, module, original, span, as_value)
    // A prelude name (`True`, `Ok`, ..); anything else the compiler rejects.
    Error(Nil) -> st
  }
}

fn constructor(
  st: State,
  module: String,
  type_name: String,
  name: String,
  as_value: Bool,
) -> State {
  let st = add_item(st, TypeItem(module, type_name))
  case as_value {
    True -> State(..st, built: set.insert(st.built, #(module, name)))
    False -> st
  }
}

/// A value `name` defined in another module: followed when it is a user
/// module, checked when it is a Beacon module, left alone otherwise.
fn external_value(
  st: State,
  ctx: Ctx,
  module: String,
  name: String,
  span: glance.Span,
  as_value: Bool,
) -> State {
  case dict.get(ctx.index, module) {
    Ok(info) ->
      case is_upper_name(name) {
        True ->
          case dict.get(info.constructors, name) {
            Ok(type_name) -> constructor(st, module, type_name, name, as_value)
            Error(Nil) -> st
          }
        False ->
          case
            dict.has_key(info.functions, name),
            dict.has_key(info.constants, name)
          {
            True, _ -> add_item(st, FunctionItem(module, name))
            False, True -> add_item(st, ConstantItem(module, name))
            False, False -> st
          }
      }
    Error(Nil) -> check_framework(st, ctx, module, name, span)
  }
}

fn check_framework(
  st: State,
  ctx: Ctx,
  module: String,
  name: String,
  span: glance.Span,
) -> State {
  case is_framework_module(module) && !set.contains(ctx.allowed, module) {
    False -> st
    True ->
      add_error(
        st,
        at(ctx, span)
          <> ": `"
          <> ctx.info.path
          <> "."
          <> ctx.owner
          <> "` uses `"
          <> module
          <> "."
          <> name
          <> "`, but "
          <> module
          <> " does not run in the browser. Client code (what `view`, a `simple` app's `update` and a Local layer reach) may use only "
          <> string.join(
          set.to_list(ctx.allowed) |> list.sort(string.compare),
          ", ",
        )
          <> " and non-Beacon packages.",
      )
  }
}

/// `qualifier.name` where `qualifier` is an import alias.
fn ref_qualified(
  st: State,
  ctx: Ctx,
  qualifier: String,
  module: String,
  name: String,
  span: glance.Span,
  as_value: Bool,
) -> State {
  use_qualifier(st, ctx, qualifier)
  |> external_value(ctx, module, name, span, as_value)
}

/// The module an unshadowed import alias names.
fn module_alias(
  ctx: Ctx,
  locals: Set(String),
  qualifier: String,
) -> Result(String, Nil) {
  case set.contains(locals, qualifier) {
    True -> Error(Nil)
    False -> dict.get(ctx.info.aliases, qualifier)
  }
}

// ----- Types -----

fn walk_optional_type(
  st: State,
  ctx: Ctx,
  type_: Option(glance.Type),
) -> State {
  case type_ {
    Some(type_) -> walk_type(st, ctx, type_)
    None -> st
  }
}

fn walk_type(st: State, ctx: Ctx, type_: glance.Type) -> State {
  case type_ {
    glance.NamedType(location:, name:, module: Some(qualifier), parameters:) -> {
      let st = use_qualifier(st, ctx, qualifier)
      let st = case dict.get(ctx.info.aliases, qualifier) {
        Ok(module) -> external_type(st, ctx, module, name, location)
        // The compiler rejects an unknown qualifier.
        Error(Nil) -> st
      }
      list.fold(parameters, st, fn(st, t) { walk_type(st, ctx, t) })
    }
    glance.NamedType(location:, name:, module: None, parameters:) -> {
      let st = case
        dict.has_key(ctx.info.custom_types, name)
        || dict.has_key(ctx.info.type_aliases, name)
      {
        True -> add_item(st, TypeItem(ctx.info.path, name))
        False ->
          case dict.get(ctx.info.types, name) {
            Ok(#(module, original)) ->
              use_type(st, ctx, name)
              |> external_type(ctx, module, original, location)
            // A prelude type.
            Error(Nil) -> st
          }
      }
      list.fold(parameters, st, fn(st, t) { walk_type(st, ctx, t) })
    }
    glance.TupleType(elements:, ..) ->
      list.fold(elements, st, fn(st, t) { walk_type(st, ctx, t) })
    glance.FunctionType(parameters:, return:, ..) ->
      list.fold(parameters, walk_type(st, ctx, return), fn(st, t) {
        walk_type(st, ctx, t)
      })
    glance.VariableType(..) | glance.HoleType(..) -> st
  }
}

fn external_type(
  st: State,
  ctx: Ctx,
  module: String,
  name: String,
  span: glance.Span,
) -> State {
  case dict.get(ctx.index, module) {
    Ok(info) ->
      case
        dict.has_key(info.custom_types, name)
        || dict.has_key(info.type_aliases, name)
      {
        True -> add_item(st, TypeItem(module, name))
        False -> st
      }
    Error(Nil) -> check_framework(st, ctx, module, name, span)
  }
}

// ----- Statements and expressions -----

fn walk_statements(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  statements: List(glance.Statement),
) -> State {
  case statements {
    [] -> st
    [statement, ..rest] -> {
      let #(st, locals) = walk_statement(st, ctx, locals, statement)
      walk_statements(st, ctx, locals, rest)
    }
  }
}

fn walk_statement(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  statement: glance.Statement,
) -> #(State, Set(String)) {
  case statement {
    glance.Use(patterns:, function:, ..) -> {
      let st = walk_expr(st, ctx, locals, function)
      list.fold(patterns, #(st, locals), fn(acc, use_pattern) {
        let #(st, bound) = acc
        let st = walk_optional_type(st, ctx, use_pattern.annotation)
        walk_pattern(st, ctx, bound, use_pattern.pattern)
      })
    }
    glance.Assignment(kind:, pattern:, annotation:, value:, ..) -> {
      let st = walk_expr(st, ctx, locals, value)
      let st = case kind {
        glance.LetAssert(message: Some(message)) ->
          walk_expr(st, ctx, locals, message)
        glance.LetAssert(message: None) | glance.Let -> st
      }
      let st = walk_optional_type(st, ctx, annotation)
      walk_pattern(st, ctx, locals, pattern)
    }
    glance.Assert(expression:, message:, ..) -> {
      let st = walk_expr(st, ctx, locals, expression)
      #(walk_optional_expr(st, ctx, locals, message), locals)
    }
    glance.Expression(expression) -> #(
      walk_expr(st, ctx, locals, expression),
      locals,
    )
  }
}

fn walk_optional_expr(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  expr: Option(glance.Expression),
) -> State {
  case expr {
    Some(expr) -> walk_expr(st, ctx, locals, expr)
    None -> st
  }
}

fn walk_exprs(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  exprs: List(glance.Expression),
) -> State {
  list.fold(exprs, st, fn(st, expr) { walk_expr(st, ctx, locals, expr) })
}

fn walk_fields(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  fields: List(glance.Field(glance.Expression)),
) -> State {
  list.fold(fields, st, fn(st, field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        walk_expr(st, ctx, locals, item)
      // `f(label:)` passes the variable or function named `label`.
      glance.ShorthandField(label:, location:) ->
        ref_value(st, ctx, locals, label, location, True)
    }
  })
}

fn walk_expr(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  expr: glance.Expression,
) -> State {
  case expr {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> st
    glance.Variable(location:, name:) ->
      ref_value(st, ctx, locals, name, location, True)
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      walk_expr(st, ctx, locals, value)
    glance.Block(statements:, ..) ->
      walk_statements(st, ctx, locals, statements)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      walk_optional_expr(st, ctx, locals, message)
    glance.Tuple(elements:, ..) -> walk_exprs(st, ctx, locals, elements)
    glance.List(elements:, rest:, ..) ->
      walk_exprs(st, ctx, locals, elements)
      |> walk_optional_expr(ctx, locals, rest)
    glance.Fn(arguments:, return_annotation:, body:, ..) -> {
      let st =
        list.fold(arguments, st, fn(st, argument) {
          walk_optional_type(st, ctx, argument.type_)
        })
      let st = walk_optional_type(st, ctx, return_annotation)
      let inner =
        list.fold(arguments, locals, fn(acc, argument) {
          bind_name(acc, argument.name)
        })
      walk_statements(st, ctx, inner, body)
    }
    glance.RecordUpdate(location:, module:, constructor:, record:, fields:) -> {
      let st = case module {
        Some(qualifier) ->
          case module_alias(ctx, locals, qualifier) {
            Ok(path) ->
              ref_qualified(
                st,
                ctx,
                qualifier,
                path,
                constructor,
                location,
                True,
              )
            Error(Nil) -> st
          }
        None -> ref_value(st, ctx, locals, constructor, location, True)
      }
      let st = walk_expr(st, ctx, locals, record)
      list.fold(fields, st, fn(st, field) {
        case field.item {
          Some(item) -> walk_expr(st, ctx, locals, item)
          // `Record(..r, label:)` uses the variable named `label`.
          None -> ref_value(st, ctx, locals, field.label, location, True)
        }
      })
    }
    glance.FieldAccess(
      location:,
      container: glance.Variable(name: qualifier, ..) as container,
      label:,
    ) ->
      case module_alias(ctx, locals, qualifier) {
        Ok(path) ->
          ref_qualified(st, ctx, qualifier, path, label, location, True)
        Error(Nil) -> walk_expr(st, ctx, locals, container)
      }
    glance.FieldAccess(container:, ..) -> walk_expr(st, ctx, locals, container)
    glance.Call(function:, arguments:, ..) ->
      walk_expr(st, ctx, locals, function)
      |> walk_fields(ctx, locals, arguments)
    glance.TupleIndex(tuple:, ..) -> walk_expr(st, ctx, locals, tuple)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      walk_expr(st, ctx, locals, function)
      |> walk_fields(ctx, locals, arguments_before)
      |> walk_fields(ctx, locals, arguments_after)
    glance.BitString(segments:, ..) ->
      list.fold(segments, st, fn(st, segment) {
        let #(value, options) = segment
        let st = walk_expr(st, ctx, locals, value)
        list.fold(options, st, fn(st, option) {
          case option {
            glance.SizeValueOption(size) -> walk_expr(st, ctx, locals, size)
            _ -> st
          }
        })
      })
    glance.Case(subjects:, clauses:, ..) -> {
      let st = walk_exprs(st, ctx, locals, subjects)
      list.fold(clauses, st, fn(st, clause) {
        let #(st, bound) =
          list.fold(list.flatten(clause.patterns), #(st, locals), fn(acc, p) {
            let #(st, bound) = acc
            walk_pattern(st, ctx, bound, p)
          })
        walk_optional_expr(st, ctx, bound, clause.guard)
        |> walk_expr(ctx, bound, clause.body)
      })
    }
    glance.BinaryOperator(left:, right:, ..) ->
      walk_expr(st, ctx, locals, left) |> walk_expr(ctx, locals, right)
    glance.Echo(expression:, message:, ..) ->
      walk_optional_expr(st, ctx, locals, expression)
      |> walk_optional_expr(ctx, locals, message)
  }
}

/// Record the types and constructors a pattern names, and add the names it
/// binds to `locals`.
fn walk_pattern(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  pattern: glance.Pattern,
) -> #(State, Set(String)) {
  case pattern {
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..) -> #(st, locals)
    glance.PatternVariable(name:, ..) -> #(st, set.insert(locals, name))
    glance.PatternTuple(elements:, ..) ->
      walk_patterns(st, ctx, locals, elements)
    glance.PatternList(elements:, tail:, ..) -> {
      let #(st, locals) = walk_patterns(st, ctx, locals, elements)
      case tail {
        Some(tail) -> walk_pattern(st, ctx, locals, tail)
        None -> #(st, locals)
      }
    }
    glance.PatternAssignment(pattern:, name:, ..) -> {
      let #(st, locals) = walk_pattern(st, ctx, locals, pattern)
      #(st, set.insert(locals, name))
    }
    glance.PatternConcatenate(prefix_name:, rest_name:, ..) -> {
      let locals = case prefix_name {
        Some(name) -> bind_name(locals, name)
        None -> locals
      }
      #(st, bind_name(locals, rest_name))
    }
    glance.PatternBitString(segments:, ..) ->
      list.fold(segments, #(st, locals), fn(acc, segment) {
        let #(st, bound) = acc
        let #(segment_pattern, options) = segment
        // Sizes refer to names bound before this segment.
        let st =
          list.fold(options, st, fn(st, option) {
            case option {
              glance.SizeValueOption(size) -> walk_size(st, ctx, bound, size)
              _ -> st
            }
          })
        walk_pattern(st, ctx, bound, segment_pattern)
      })
    glance.PatternVariant(location:, module:, constructor:, arguments:, ..) -> {
      let st = case module {
        Some(qualifier) ->
          case dict.get(ctx.info.aliases, qualifier) {
            Ok(path) ->
              ref_qualified(
                st,
                ctx,
                qualifier,
                path,
                constructor,
                location,
                False,
              )
            Error(Nil) -> st
          }
        None -> ref_value(st, ctx, set.new(), constructor, location, False)
      }
      list.fold(arguments, #(st, locals), fn(acc, argument) {
        let #(st, bound) = acc
        case argument {
          glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
            walk_pattern(st, ctx, bound, item)
          // `Variant(label:)` binds `label`.
          glance.ShorthandField(label:, ..) -> #(st, set.insert(bound, label))
        }
      })
    }
  }
}

fn walk_patterns(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  patterns: List(glance.Pattern),
) -> #(State, Set(String)) {
  list.fold(patterns, #(st, locals), fn(acc, pattern) {
    let #(st, bound) = acc
    walk_pattern(st, ctx, bound, pattern)
  })
}

fn walk_size(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  size: glance.BitArraySize,
) -> State {
  case size {
    glance.BitArraySizeInt(..) -> st
    glance.BitArraySizeVariable(location:, name:) ->
      ref_value(st, ctx, locals, name, location, True)
    glance.BitArraySizeBinaryOperator(left:, right:, ..) ->
      walk_size(st, ctx, locals, left) |> walk_size(ctx, locals, right)
    glance.BitArraySizeBlock(inner:, ..) -> walk_size(st, ctx, locals, inner)
  }
}

// ===== Emission =====

/// A client module: its path and generated source.
pub type Emitted {
  Emitted(
    path: String,
    source: String,
    /// JavaScript FFI files the module's externals load, as paths relative
    /// to the source directory, e.g. `app/widget_ffi.mjs`.
    ffi_files: List(String),
  )
}

/// The client source of every module with reached definitions, sorted by
/// module path.
pub fn emit(index: Index, reach: Reach) -> Result(List(Emitted), String) {
  let by_module =
    set.fold(reach.items, dict.new(), fn(acc, item) {
      let items = case dict.get(acc, item.module) {
        Ok(items) -> items
        Error(Nil) -> []
      }
      dict.insert(acc, item.module, [item, ..items])
    })
  dict.to_list(by_module)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.try_map(fn(entry) {
    let #(path, items) = entry
    case dict.get(index, path) {
      Ok(info) -> emit_module(info, items, usage_of(reach, path))
      Error(Nil) ->
        Error(
          "Invariant violated: reached module " <> path <> " is not indexed",
        )
    }
  })
}

fn usage_of(reach: Reach, path: String) -> Usage {
  case dict.get(reach.usage, path) {
    Ok(usage) -> usage
    Error(Nil) -> Usage(set.new(), set.new(), set.new())
  }
}

fn emit_module(
  info: ModuleInfo,
  items: List(Item),
  usage: Usage,
) -> Result(Emitted, String) {
  let bytes = <<info.source:utf8>>
  use pieces <- result.try(
    list.try_map(items, fn(item) { definition_text(info, bytes, item) }),
  )
  let pieces = list.sort(pieces, fn(a, b) { int.compare(a.0, b.0) })
  let ffi_files =
    list.filter_map(pieces, fn(piece) { option.to_result(piece.2, Nil) })
  use ffi_files <- result.try(
    list.try_map(list.unique(ffi_files), resolve_ffi_path(info.path, _)),
  )
  let imports = list.filter_map(info.ast.imports, emit_import(_, usage))
  let body = list.map(pieces, fn(piece) { piece.1 })
  let source =
    case imports {
      [] -> body
      _ -> [string.join(imports, "\n"), ..body]
    }
    |> string.join("\n\n")
  Ok(Emitted(path: info.path, source: source <> "\n", ffi_files:))
}

/// #(start offset, text, JavaScript FFI path) of one definition.
fn definition_text(
  info: ModuleInfo,
  bytes: BitArray,
  item: Item,
) -> Result(#(Int, String, Option(String)), String) {
  let not_found = fn() {
    Error(
      "Invariant violated: "
      <> describe_item(item)
      <> " is not defined in "
      <> info.path,
    )
  }
  case item {
    FunctionItem(name:, ..) ->
      case dict.get(info.functions, name) {
        Ok(def) ->
          with_externals(bytes, def.attributes, def.definition.location)
        Error(Nil) -> not_found()
      }
    ConstantItem(name:, ..) ->
      case dict.get(info.constants, name) {
        Ok(def) -> with_externals(bytes, [], def.definition.location)
        Error(Nil) -> not_found()
      }
    TypeItem(name:, ..) ->
      case
        dict.get(info.custom_types, name),
        dict.get(info.type_aliases, name)
      {
        Ok(def), _ ->
          with_externals(bytes, def.attributes, def.definition.location)
        Error(Nil), Ok(def) ->
          with_externals(bytes, [], def.definition.location)
        Error(Nil), Error(Nil) -> not_found()
      }
  }
}

/// The definition's text, preceded by its JavaScript external, if any.
/// Erlang externals are dropped: the client project only targets
/// JavaScript.
fn with_externals(
  bytes: BitArray,
  attributes: List(glance.Attribute),
  span: glance.Span,
) -> Result(#(Int, String, Option(String)), String) {
  use text <- result.map(slice(bytes, span))
  case javascript_external(attributes) {
    Some(#(path, name)) -> #(
      span.start,
      "@external(javascript, "
        <> string.inspect(path)
        <> ", "
        <> string.inspect(name)
        <> ")\n"
        <> text,
      Some(path),
    )
    None -> #(span.start, text, None)
  }
}

fn slice(bytes: BitArray, span: glance.Span) -> Result(String, String) {
  bit_array.slice(bytes, span.start, span.end - span.start)
  |> result.try(bit_array.to_string)
  |> result.replace_error(
    "Invariant violated: a glance span is not a UTF-8 slice of the parsed source",
  )
}

/// A JavaScript external path, relative to the module's file, as a path
/// relative to the source directory.
fn resolve_ffi_path(module: String, path: String) -> Result(String, String) {
  let invalid = fn(reason) {
    Error(
      "The JavaScript external "
      <> string.inspect(path)
      <> " in "
      <> module
      <> ".gleam "
      <> reason,
    )
  }
  case string.starts_with(path, "./") || string.starts_with(path, "../") {
    False ->
      invalid(
        "is not a relative path; client code may load only FFI files that sit next to its modules (`./name.mjs`)",
      )
    True -> {
      let directory =
        string.split(module, "/")
        |> list.reverse
        |> list.drop(1)
        |> list.reverse
      case normalise(directory, string.split(path, "/")) {
        Ok(segments) -> Ok(string.join(segments, "/"))
        Error(Nil) -> invalid("points outside the source directory")
      }
    }
  }
}

fn normalise(
  directory: List(String),
  segments: List(String),
) -> Result(List(String), Nil) {
  case segments {
    [] -> Ok(directory)
    [".", ..rest] -> normalise(directory, rest)
    ["..", ..rest] ->
      case list.reverse(directory) {
        [] -> Error(Nil)
        [_, ..parent] -> normalise(list.reverse(parent), rest)
      }
    ["", ..] -> Error(Nil)
    [segment, ..rest] -> normalise(list.append(directory, [segment]), rest)
  }
}

/// The import, keeping only what the emitted definitions use, or Error(Nil)
/// when they use nothing from it.
fn emit_import(
  def: glance.Definition(glance.Import),
  usage: Usage,
) -> Result(String, Nil) {
  let import_ = def.definition
  let qualified = case field_type.import_alias(import_) {
    Ok(alias) -> set.contains(usage.qualifiers, alias)
    Error(Nil) -> False
  }
  let used = fn(items: List(glance.UnqualifiedImport), names: Set(String)) {
    list.filter(items, fn(item) {
      set.contains(names, option.unwrap(item.alias, item.name))
    })
  }
  let types = used(import_.unqualified_types, usage.types)
  let values = used(import_.unqualified_values, usage.values)
  case qualified, types, values {
    False, [], [] -> Error(Nil)
    _, _, _ -> {
      let render = fn(prefix, item: glance.UnqualifiedImport) {
        prefix
        <> item.name
        <> case item.alias {
          Some(alias) -> " as " <> alias
          None -> ""
        }
      }
      let unqualified =
        list.append(
          list.map(types, render("type ", _)),
          list.map(values, render("", _)),
        )
      let unqualified = case unqualified {
        [] -> ""
        _ -> ".{" <> string.join(unqualified, ", ") <> "}"
      }
      let alias = case qualified, import_.alias {
        True, Some(glance.Named(alias)) -> " as " <> alias
        _, _ -> ""
      }
      Ok("import " <> import_.module <> unqualified <> alias)
    }
  }
}
