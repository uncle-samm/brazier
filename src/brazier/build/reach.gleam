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
/// A reference into a Brazier module outside the client allowlist is an
/// error naming the call site. References into dependencies are not
/// followed: whether a package runs on JavaScript is the JavaScript
/// compiler's call.
///
/// Emission slices the source of each reached definition out of its file
/// and regenerates the imports from what those definitions use, so a
/// server-only import, function, constant or type never reaches the client
/// project. Each emitted module records a `source_map.Segment` per copied
/// definition, so a compiler warning at a line of the copy is reported at
/// the line of the file it was sliced from (the app's, or Brazier's for
/// `brazier/stream`). A warning in a line emission writes (an import, an
/// `@external` attribute) can only be a Brazier bug, and fails the build.
import brazier/build/field_type
import brazier/build/source_location
import brazier/build/source_map.{type Segment}
import brazier/internal/ascii
import brazier/internal/render
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
    /// The uses of `stream.new` and `stream.render` in the reached user
    /// code, in no particular order.
    streams: List(StreamUse),
  )
}

/// A use of `brazier/stream.new` or `brazier/stream.render` in a user
/// module, or of the attribute that marks a stream's container
/// (docs/design/STREAMS.md 10). `at` is the place, as
/// `path.gleam:line:column`.
pub type StreamUse {
  /// A `stream.new` call: its name argument as the literal string, or what
  /// the argument is instead.
  Declared(
    at: String,
    module: String,
    owner: String,
    name: Result(String, String),
  )
  /// A `stream.render` call: `Ok` when its item argument is a named
  /// function, or why it is refused.
  Rendered(at: String, item: Result(Nil, ItemRefusal))
  /// `stream.new` or `stream.render` used as a value instead of called, so
  /// its arguments cannot be checked.
  Referenced(at: String, function: String)
  /// A `function(name, ..)` call (`attribute.attribute`, `attribute.data`
  /// or `attribute.boolean`) whose `name` makes a reserved `data-brazier-*`
  /// name (`render.is_reserved_attribute_name`), in any case: one the
  /// render or the client owns, such as `data-brazier-stream`, which marks
  /// a stream's container and only `stream.render` sets. `attribute` is the
  /// whole name, lowercased. The build reads every name it can know without
  /// running code: a literal, a constant of an app module, or a `<>` of
  /// those. `written` says how a name that is not a literal was written.
  ///
  /// A name computed when the view runs is not refused here: the
  /// attribute's constructor refuses it then, on the server and in the
  /// browser alike, and the render checks it again. LiveView's HEEx
  /// compiler draws the same line: it checks a literal `phx-update` value
  /// at compile time, and leaves `phx-update={@value}` and `{@rest}` to the
  /// runtime.
  ReservedAttribute(
    at: String,
    function: String,
    name: String,
    attribute: String,
    written: Option(String),
  )
}

/// Why the item argument of a `stream.render` call is refused.
pub type ItemRefusal {
  /// It is not a named top-level function: `kind` says what it is.
  NotNamedFunction(kind: String)
  /// `written` names a definition of `module`, which the analyzer does not
  /// index (a dependency's, or a Brazier module's), so the build cannot
  /// check that it is a top-level function.
  UncheckedModule(written: String, module: String)
}

/// The Brazier module whose definitions reach the client one by one, as
/// user modules' do: its other definitions run only on the server.
pub const stream_module = "brazier/stream"

/// The definitions of `brazier/stream` client code may use. The rest make
/// effects or are test helpers, which run only on the server.
const stream_client_names = [
  "Stream", "Limit", "KeepFirst", "KeepLast", "Position", "Append", "Prepend",
  "new", "name", "limit", "key", "render",
]

/// The Brazier modules the reached definitions of `brazier/stream` may use,
/// besides the client modules.
const stream_internal_modules = [
  "brazier/internal/render", "brazier/internal/stream_op",
]

/// True for the modules Brazier itself provides: `brazier` and `brazier/*`.
pub fn is_framework_module(module_path: String) -> Bool {
  module_path == "brazier" || string.starts_with(module_path, "brazier/")
}

/// True for a Brazier module the analyzer indexes and the client gets
/// pruned to the reached definitions, as a user module: `brazier/stream`.
pub fn is_pruned_framework_module(module_path: String) -> Bool {
  list.contains(pruned_framework_modules, module_path)
}

/// Every pruned Brazier module (`is_pruned_framework_module`).
pub const pruned_framework_modules = [stream_module]

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
    streams: List(StreamUse),
    errors: List(String),
    /// True when walking client code: the Brazier allowlist and the
    /// browser checks apply. False for `scan`.
    client: Bool,
  )
}

type Ctx {
  Ctx(
    index: Index,
    /// Brazier modules client code may use.
    allowed: Set(String),
    info: ModuleInfo,
    /// The definition being walked, for messages.
    owner: String,
    client: Bool,
  )
}

/// Everything reachable from `roots`. `allowed` lists the Brazier modules
/// client code may use; reaching any other Brazier module is an error. All
/// errors are returned, each naming its call site.
pub fn walk(
  index: Index,
  allowed: List(String),
  roots: List(Item),
) -> Result(Reach, List(String)) {
  traverse(index, allowed, roots, True)
}

/// The stream uses in every function and constant of `modules`, whatever
/// runs them: the build checks every `stream.new` of the app's modules, not
/// only the client's (docs/design/STREAMS.md 10). No client check applies.
pub fn scan(
  index: Index,
  modules: List(String),
) -> Result(List(StreamUse), List(String)) {
  use roots <- result.try(
    list.try_map(modules, fn(module) {
      case dict.get(index, module) {
        Ok(info) ->
          Ok(list.append(
            dict.keys(info.functions) |> list.map(FunctionItem(module, _)),
            dict.keys(info.constants) |> list.map(ConstantItem(module, _)),
          ))
        Error(Nil) ->
          Error([
            "Invariant violated: scanned module " <> module <> " is not indexed",
          ])
      }
    }),
  )
  traverse(index, [], list.flatten(roots), False)
  |> result.map(fn(reached) { reached.streams })
}

fn traverse(
  index: Index,
  allowed: List(String),
  roots: List(Item),
  client: Bool,
) -> Result(Reach, List(String)) {
  let state =
    run(
      State(
        seen: set.new(),
        pending: roots,
        built: set.new(),
        usage: dict.new(),
        streams: [],
        errors: [],
        client:,
      ),
      index,
      set.from_list(allowed),
    )
  case state.errors {
    [] ->
      Ok(Reach(
        items: state.seen,
        built: state.built,
        usage: state.usage,
        streams: state.streams,
      ))
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
      // The reached definitions of a pruned Brazier module use Brazier's
      // internal client modules too.
      let allowed = case is_pruned_framework_module(item.module) {
        True -> set.union(allowed, set.from_list(stream_internal_modules))
        False -> allowed
      }
      let ctx =
        Ctx(index:, allowed:, info:, owner: item.name, client: st.client)
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
  let st = case ctx.client && erlang_only(attributes, function) {
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

/// Whether `name` starts with `A-Z`. Names come from glance, whose lexer
/// (glexer's `lex_uppercase_name` and `lex_lowercase_name`) starts an upper
/// name with `A-Z` and a lower name with `a-z` or `_`: Gleam names are
/// ASCII by grammar, so the first byte decides, and no Unicode case mapping
/// is involved.
fn is_upper_name(name: String) -> Bool {
  case <<name:utf8>> {
    <<first, _:bytes>> -> first >= 0x41 && first <= 0x5a
    _ -> False
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
/// module or a pruned Brazier module, checked when it is another Brazier
/// module, left alone otherwise.
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
      case client_name_refused(ctx, module, name) {
        True -> refuse_server_name(st, ctx, module, name, span)
        False -> follow_value(st, info, module, name, as_value)
      }
    Error(Nil) -> check_framework(st, ctx, module, name, span)
  }
}

/// Follow `module.name` into its indexed module.
fn follow_value(
  st: State,
  info: ModuleInfo,
  module: String,
  name: String,
  as_value: Bool,
) -> State {
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
}

/// True when client code in a user module uses a definition of a pruned
/// Brazier module that runs only on the server, such as `stream.insert`.
fn client_name_refused(ctx: Ctx, module: String, name: String) -> Bool {
  ctx.client
  && is_pruned_framework_module(module)
  && !is_framework_module(ctx.info.path)
  && !list.contains(stream_client_names, name)
}

fn refuse_server_name(
  st: State,
  ctx: Ctx,
  module: String,
  name: String,
  span: glance.Span,
) -> State {
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
      <> "`, which runs only on the server. Client code (what `view`, a `simple` app's `update` and a Local layer reach) may use only "
      <> string.join(
      list.map(stream_client_names, fn(n) { module <> "." <> n }),
      ", ",
    )
      <> " of "
      <> module
      <> ": stream ops are effects, which `update` returns on the server.",
  )
}

fn check_framework(
  st: State,
  ctx: Ctx,
  module: String,
  name: String,
  span: glance.Span,
) -> State {
  case
    ctx.client
    && is_framework_module(module)
    && !set.contains(ctx.allowed, module)
  {
    False -> st
    True ->
      case is_pruned_framework_module(module) {
        // The build gives the analyzer the pruned modules' sources.
        True ->
          add_error(
            st,
            "Invariant violated: "
              <> at(ctx, span)
              <> " uses "
              <> module
              <> "."
              <> name
              <> ", but the source of "
              <> module
              <> " was not given to the analyzer",
          )
        False ->
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
              <> describe_client_modules(ctx.allowed)
              <> " and non-Brazier packages.",
          )
      }
  }
}

/// The Brazier modules client code may use, for messages: the ones
/// `check_framework` lets through, `allowed` and the pruned modules, from
/// the same lists, so the text cannot drift from the check. A pruned module
/// is listed with the definitions client code may use of it.
fn describe_client_modules(allowed: Set(String)) -> String {
  set.to_list(allowed)
  |> list.append(pruned_framework_modules)
  |> list.unique
  |> list.sort(string.compare)
  |> list.map(fn(module) {
    case module == stream_module {
      True ->
        module <> " (only " <> string.join(stream_client_names, ", ") <> ")"
      False -> module
    }
  })
  |> string.join(", ")
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
        walk_expr(st, ctx, locals, glance.Variable(location:, name: label))
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
    glance.Variable(location:, ..)
    | glance.FieldAccess(location:, container: glance.Variable(..), ..) ->
      record_reference(st, ctx, locals, expr, location)
      |> walk_callee(ctx, locals, expr)
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
          None ->
            walk_expr(
              st,
              ctx,
              locals,
              glance.Variable(location:, name: field.label),
            )
        }
      })
    }
    glance.FieldAccess(container:, ..) -> walk_expr(st, ctx, locals, container)
    glance.Call(location:, function:, arguments:) ->
      walk_call(st, ctx, locals, location, function, arguments, None)
    glance.TupleIndex(tuple:, ..) -> walk_expr(st, ctx, locals, tuple)
    glance.FnCapture(
      location:,
      label:,
      function:,
      arguments_before:,
      arguments_after:,
    ) ->
      walk_capture(
        st,
        ctx,
        locals,
        location,
        label,
        function,
        arguments_before,
        arguments_after,
        None,
      )
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
    glance.BinaryOperator(name: glance.Pipe, left:, right:, ..) ->
      walk_pipe(st, ctx, locals, left, right)
    glance.BinaryOperator(left:, right:, ..) ->
      walk_expr(st, ctx, locals, left) |> walk_expr(ctx, locals, right)
    glance.Echo(expression:, message:, ..) ->
      walk_optional_expr(st, ctx, locals, expression)
      |> walk_optional_expr(ctx, locals, message)
  }
}

/// The function of a call, or a reference: a variable or `alias.name`.
/// Walking it records no stream use; the caller does.
fn walk_callee(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  function: glance.Expression,
) -> State {
  case function {
    glance.Variable(location:, name:) ->
      ref_value(st, ctx, locals, name, location, True)
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
    _ -> walk_expr(st, ctx, locals, function)
  }
}

/// `function(arguments)`, or `piped |> function(arguments)` when `piped` is
/// `Some`.
fn walk_call(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  location: glance.Span,
  function: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
  piped: Option(glance.Expression),
) -> State {
  let st = case stream_callee(ctx, locals, function) {
    Ok(callee) -> {
      let given = list.map(positional(arguments), Some)
      let given = case piped {
        Some(left) -> [Some(left), ..given]
        None -> given
      }
      record_call(st, ctx, locals, callee, location, given)
    }
    Error(Nil) -> st
  }
  walk_callee(st, ctx, locals, function)
  |> walk_fields(ctx, locals, arguments)
}

/// `function(before.., _, after..)`, or `piped |> function(.., _, ..)` when
/// `piped` is `Some`: the pipe fills the hole.
fn walk_capture(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  location: glance.Span,
  label: Option(String),
  function: glance.Expression,
  before: List(glance.Field(glance.Expression)),
  after: List(glance.Field(glance.Expression)),
  piped: Option(glance.Expression),
) -> State {
  let st = case stream_callee(ctx, locals, function) {
    Ok(callee) -> {
      // A labelled hole fills a labelled parameter, not a positional one.
      let hole = case label {
        None -> [piped]
        Some(_) -> []
      }
      let given =
        list.flatten([
          list.map(positional(before), Some),
          hole,
          list.map(positional(after), Some),
        ])
      record_call(st, ctx, locals, callee, location, given)
    }
    Error(Nil) -> st
  }
  walk_callee(st, ctx, locals, function)
  |> walk_fields(ctx, locals, before)
  |> walk_fields(ctx, locals, after)
}

/// `left |> right`: `right` is called with `left` as its first argument, or
/// as its hole when it is a capture.
fn walk_pipe(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  left: glance.Expression,
  right: glance.Expression,
) -> State {
  let st = walk_expr(st, ctx, locals, left)
  case right {
    glance.Call(location:, function:, arguments:) ->
      walk_call(st, ctx, locals, location, function, arguments, Some(left))
    glance.FnCapture(
      location:,
      label:,
      function:,
      arguments_before:,
      arguments_after:,
    ) ->
      walk_capture(
        st,
        ctx,
        locals,
        location,
        label,
        function,
        arguments_before,
        arguments_after,
        Some(left),
      )
    glance.Variable(location:, ..)
    | glance.FieldAccess(location:, container: glance.Variable(..), ..) ->
      case stream_callee(ctx, locals, right) {
        Ok(callee) ->
          record_call(st, ctx, locals, callee, location, [Some(left)])
          |> walk_callee(ctx, locals, right)
        Error(Nil) -> walk_expr(st, ctx, locals, right)
      }
    _ -> walk_expr(st, ctx, locals, right)
  }
}

// ----- Stream uses -----

/// The Brazier module whose `attribute` and `data` calls are checked for
/// the stream container's attribute.
const attribute_module = "brazier/attribute"

/// A Brazier function whose calls the build checks.
type StreamFunction {
  StreamNew
  StreamRender
  /// `brazier/attribute.attribute` or `.boolean` (`prefix` `""`), or
  /// `.data` (`prefix` `"data-"`): a name the build can know that makes a
  /// reserved name (`render.is_reserved_attribute_name`) is refused.
  AttributeName(function: String, prefix: String)
}

/// `stream.new`, `stream.render`, `attribute.attribute`, `attribute.data`
/// or `attribute.boolean` when `expr` names one of them in a user module, through an unshadowed
/// import alias or an unqualified import.
fn stream_callee(
  ctx: Ctx,
  locals: Set(String),
  expr: glance.Expression,
) -> Result(StreamFunction, Nil) {
  case is_framework_module(ctx.info.path) {
    True -> Error(Nil)
    False -> {
      let named = case expr {
        glance.Variable(name:, ..) ->
          case
            set.contains(locals, name)
            || dict.has_key(ctx.info.functions, name)
            || dict.has_key(ctx.info.constants, name)
          {
            True -> Error(Nil)
            False -> dict.get(ctx.info.values, name)
          }
        glance.FieldAccess(
          container: glance.Variable(name: qualifier, ..),
          label:,
          ..,
        ) ->
          module_alias(ctx, locals, qualifier)
          |> result.map(fn(module) { #(module, label) })
        _ -> Error(Nil)
      }
      case named {
        Ok(#(module, "new")) if module == stream_module -> Ok(StreamNew)
        Ok(#(module, "render")) if module == stream_module -> Ok(StreamRender)
        Ok(#(module, "attribute")) if module == attribute_module ->
          Ok(AttributeName(function: "attribute.attribute", prefix: ""))
        Ok(#(module, "data")) if module == attribute_module ->
          Ok(AttributeName(function: "attribute.data", prefix: "data-"))
        Ok(#(module, "boolean")) if module == attribute_module ->
          Ok(AttributeName(function: "attribute.boolean", prefix: ""))
        _ -> Error(Nil)
      }
    }
  }
}

/// `stream.new` or `stream.render` used as a value, not called. An
/// attribute function used as a value is not recorded: the attribute's
/// constructor and the render refuse a reserved name on any element
/// (`render.is_reserved_attribute_name`).
fn record_reference(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  expr: glance.Expression,
  location: glance.Span,
) -> State {
  let referenced = fn(function) {
    add_stream_use(st, Referenced(at: at(ctx, location), function:))
  }
  case stream_callee(ctx, locals, expr) {
    Ok(StreamNew) -> referenced("new")
    Ok(StreamRender) -> referenced("render")
    Ok(AttributeName(..)) | Error(Nil) -> st
  }
}

/// A call of `stream.new` or `stream.render` with its positional arguments
/// in order; `None` is a capture hole.
fn record_call(
  st: State,
  ctx: Ctx,
  locals: Set(String),
  function: StreamFunction,
  location: glance.Span,
  arguments: List(Option(glance.Expression)),
) -> State {
  let at = at(ctx, location)
  case function {
    StreamNew ->
      add_stream_use(
        st,
        Declared(
          at:,
          module: ctx.info.path,
          owner: ctx.owner,
          name: stream_name_argument(list.first(arguments)),
        ),
      )
    StreamRender ->
      add_stream_use(
        st,
        Rendered(
          at:,
          item: item_argument(
            ctx,
            locals,
            list.drop(arguments, 3) |> list.first,
          ),
        ),
      )
    // A name the build can know (`static_name`) is checked here. Any other
    // name is known only when the view runs, and the attribute's
    // constructor refuses a reserved name then
    // (`render.is_reserved_attribute_name`): the build does not refuse a
    // name for being computed, which every helper that forwards a name
    // does.
    AttributeName(function:, prefix:) ->
      case list.first(arguments) {
        Ok(Some(argument)) ->
          case static_name(ctx.index, ctx.info, locals, argument) {
            Ok(name) ->
              case render.is_reserved_attribute_name(prefix <> name) {
                True ->
                  add_stream_use(
                    st,
                    ReservedAttribute(
                      at:,
                      function:,
                      name:,
                      // ASCII: `is_reserved_attribute_name` accepts
                      // only `a-z A-Z 0-9 - _ : .`.
                      attribute: ascii.lowercase(prefix <> name),
                      written: written_name(argument),
                    ),
                  )
                False -> st
              }
            Error(Nil) -> st
          }
        Ok(None) | Error(Nil) -> st
      }
  }
}

/// The value of an attribute name argument when the build can know it
/// without running code: a string literal, a constant of an analyzed
/// module whose value is one, or a `<>` of such parts. `Error(Nil)` for
/// any other expression (a parameter, a local variable, a call's result).
fn static_name(
  index: Index,
  info: ModuleInfo,
  locals: Set(String),
  expr: glance.Expression,
) -> Result(String, Nil) {
  static_string(index, info, locals, expr, set.new())
}

/// `static_name`. `seen` holds the constants being resolved, as
/// `module.name`: Gleam refuses a constant that refers to itself, so a
/// constant met again is an app that does not compile, and its name is not
/// known.
fn static_string(
  index: Index,
  info: ModuleInfo,
  locals: Set(String),
  expr: glance.Expression,
  seen: Set(String),
) -> Result(String, Nil) {
  case expr {
    glance.String(value:, ..) -> Ok(value)
    glance.BinaryOperator(name: glance.Concatenate, left:, right:, ..) -> {
      use left <- result.try(static_string(index, info, locals, left, seen))
      use right <- result.try(static_string(index, info, locals, right, seen))
      Ok(left <> right)
    }
    glance.Variable(name:, ..) ->
      case set.contains(locals, name), dict.has_key(info.constants, name) {
        True, _ -> Error(Nil)
        False, True -> constant_string(index, info.path, name, seen)
        False, False ->
          case dict.get(info.values, name) {
            Ok(#(module, original)) ->
              constant_string(index, module, original, seen)
            Error(Nil) -> Error(Nil)
          }
      }
    glance.FieldAccess(
      container: glance.Variable(name: qualifier, ..),
      label:,
      ..,
    ) ->
      case set.contains(locals, qualifier) {
        True -> Error(Nil)
        False ->
          case dict.get(info.aliases, qualifier) {
            Ok(module) -> constant_string(index, module, label, seen)
            Error(Nil) -> Error(Nil)
          }
      }
    _ -> Error(Nil)
  }
}

/// The string value of constant `name` of `module`, when `module` is
/// analyzed and the constant's value is known (`static_string`).
fn constant_string(
  index: Index,
  module: String,
  name: String,
  seen: Set(String),
) -> Result(String, Nil) {
  let key = module <> "." <> name
  case set.contains(seen, key) {
    True -> Error(Nil)
    False -> {
      use info <- result.try(dict.get(index, module))
      use def <- result.try(dict.get(info.constants, name))
      // A constant's value has no local variables.
      static_string(
        index,
        info,
        set.new(),
        def.definition.value,
        set.insert(seen, key),
      )
    }
  }
}

/// How a name argument was written, for the refusal: `None` for a
/// literal, which the message already shows.
fn written_name(expr: glance.Expression) -> Option(String) {
  case expr {
    glance.String(..) -> None
    glance.Variable(name:, ..) -> Some("the constant `" <> name <> "`")
    glance.FieldAccess(
      container: glance.Variable(name: qualifier, ..),
      label:,
      ..,
    ) -> Some("the constant `" <> qualifier <> "." <> label <> "`")
    _ -> Some("a concatenation")
  }
}

fn add_stream_use(st: State, stream_use: StreamUse) -> State {
  State(..st, streams: [stream_use, ..st.streams])
}

/// The unlabelled arguments of a call, in order.
fn positional(
  arguments: List(glance.Field(glance.Expression)),
) -> List(glance.Expression) {
  list.filter_map(arguments, fn(field) {
    case field {
      glance.UnlabelledField(item:) -> Ok(item)
      glance.LabelledField(..) | glance.ShorthandField(..) -> Error(Nil)
    }
  })
}

/// The name argument of `stream.new`: the literal string, or what it is.
fn stream_name_argument(
  argument: Result(Option(glance.Expression), Nil),
) -> Result(String, String) {
  case argument {
    Ok(Some(glance.String(value:, ..))) -> Ok(value)
    Ok(Some(expr)) -> Error(describe_expression(expr))
    Ok(None) -> Error("a capture hole")
    Error(Nil) -> Error("missing")
  }
}

/// The item argument of `stream.render`: `Ok` when it names a top-level
/// function, or why it is refused.
fn item_argument(
  ctx: Ctx,
  locals: Set(String),
  argument: Result(Option(glance.Expression), Nil),
) -> Result(Nil, ItemRefusal) {
  let not_named = fn(kind) { Error(NotNamedFunction(kind)) }
  case argument {
    Error(Nil) -> not_named("missing")
    Ok(None) -> not_named("a capture hole")
    Ok(Some(glance.Variable(name:, ..))) ->
      case set.contains(locals, name), is_upper_name(name) {
        True, _ -> not_named("the local variable `" <> name <> "`")
        False, True -> not_named("the constructor `" <> name <> "`")
        False, False ->
          case
            dict.has_key(ctx.info.functions, name),
            dict.has_key(ctx.info.constants, name),
            dict.get(ctx.info.values, name)
          {
            True, _, _ -> Ok(Nil)
            False, True, _ -> not_named("the constant `" <> name <> "`")
            False, False, Ok(#(module, original)) ->
              imported_item(ctx, module, original, name)
            // The compiler rejects a name that is not defined.
            False, False, Error(Nil) ->
              not_named("`" <> name <> "`, which is not defined")
          }
      }
    Ok(Some(
      glance.FieldAccess(
        container: glance.Variable(name: qualifier, ..),
        label:,
        ..,
      ) as expr,
    )) ->
      case module_alias(ctx, locals, qualifier) {
        Ok(module) ->
          imported_item(ctx, module, label, qualifier <> "." <> label)
        Error(Nil) -> not_named(describe_expression(expr))
      }
    Ok(Some(expr)) -> not_named(describe_expression(expr))
  }
}

/// `written` names `module.name`. The definition is checked in `module`'s
/// source; a module the analyzer does not index (a dependency's, or a
/// Brazier module's) has no source here, so its definition is refused
/// rather than accepted unchecked.
fn imported_item(
  ctx: Ctx,
  module: String,
  name: String,
  written: String,
) -> Result(Nil, ItemRefusal) {
  case is_upper_name(name), dict.get(ctx.index, module) {
    True, _ -> Error(NotNamedFunction("the constructor `" <> written <> "`"))
    False, Error(Nil) -> Error(UncheckedModule(written:, module:))
    False, Ok(info) ->
      case
        dict.has_key(info.functions, name),
        dict.has_key(info.constants, name)
      {
        True, _ -> Ok(Nil)
        False, True ->
          Error(NotNamedFunction("the constant `" <> written <> "`"))
        False, False ->
          Error(NotNamedFunction("`" <> written <> "`, which is not defined"))
      }
  }
}

fn describe_expression(expr: glance.Expression) -> String {
  case expr {
    glance.Fn(..) -> "an anonymous function"
    glance.FnCapture(..) -> "a function capture"
    glance.Call(..) -> "a function call"
    glance.Variable(name:, ..) -> "the variable `" <> name <> "`"
    glance.FieldAccess(..) -> "a record field"
    glance.Int(..) | glance.Float(..) | glance.String(..) -> "a literal"
    glance.Case(..) -> "a case expression"
    glance.Block(..) -> "a block"
    glance.BinaryOperator(name: glance.Pipe, ..) -> "a pipeline"
    _ -> "an expression"
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
    /// Where each definition copied into `source` came from in the module's
    /// file, in copy order: positions in `source` map back through them
    /// (see `source_map`).
    segments: List(Segment),
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

/// One reached definition as the copy holds it.
type Piece {
  Piece(
    /// The definition's byte offset in the module's source.
    start: Int,
    /// The line the build writes before the definition (its JavaScript
    /// external), or "".
    glue: String,
    /// The definition, verbatim from the source.
    text: String,
    /// The JavaScript FFI path its external loads.
    ffi: Option(String),
  )
}

/// The copy is the regenerated imports and a blank line, then each piece
/// in source order (its glue line, then its text) with a blank line between
/// two pieces. Each piece's text gets a segment at the copy line it lands
/// on.
fn emit_module(
  info: ModuleInfo,
  items: List(Item),
  usage: Usage,
) -> Result(Emitted, String) {
  let bytes = <<info.source:utf8>>
  use pieces <- result.try(
    list.try_map(items, fn(item) { definition_text(info, bytes, item) }),
  )
  let pieces = list.sort(pieces, fn(a, b) { int.compare(a.start, b.start) })
  let ffi_files =
    list.filter_map(pieces, fn(piece) { option.to_result(piece.ffi, Nil) })
  use ffi_files <- result.try(
    list.try_map(list.unique(ffi_files), resolve_ffi_path(info.path, _)),
  )
  let header = case list.filter_map(info.ast.imports, emit_import(_, usage)) {
    [] -> ""
    imports -> string.join(imports, "\n") <> "\n\n"
  }
  use #(_next_line, segments) <- result.try(
    list.try_fold(
      pieces,
      #(source_map.newlines(header) + 1, []),
      fn(acc, piece) {
        let #(line, segments) = acc
        use segment <- result.map(source_map.segment(
          copy_line: line + source_map.newlines(piece.glue),
          text: piece.text,
          source: info.source,
          start: piece.start,
        ))
        // The piece's lines, then the blank line after it.
        #(line + source_map.newlines(piece.glue <> piece.text) + 2, [
          segment,
          ..segments
        ])
      },
    ),
  )
  let body = list.map(pieces, fn(piece) { piece.glue <> piece.text })
  Ok(Emitted(
    path: info.path,
    source: header <> string.join(body, "\n\n") <> "\n",
    ffi_files:,
    segments: list.reverse(segments),
  ))
}

/// One definition's piece.
fn definition_text(
  info: ModuleInfo,
  bytes: BitArray,
  item: Item,
) -> Result(Piece, String) {
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
) -> Result(Piece, String) {
  use text <- result.map(slice(bytes, span))
  case javascript_external(attributes) {
    Some(#(path, name)) ->
      Piece(
        start: span.start,
        glue: "@external(javascript, "
          <> string.inspect(path)
          <> ", "
          <> string.inspect(name)
          <> ")\n",
        text:,
        ffi: Some(path),
      )
    None -> Piece(start: span.start, glue: "", text:, ffi: None)
  }
}

fn slice(bytes: BitArray, span: glance.Span) -> Result(String, String) {
  bit_array.slice(bytes, span.start, span.end - span.start)
  |> result.try(bit_array.to_string)
  |> result.replace_error(
    "Invariant violated: a glance span is not a UTF-8 slice of the parsed source",
  )
}

/// A JavaScript external path, relative to the file of the module at
/// module path `module`, as a path relative to the source directory. A path
/// that is not relative, or that leaves the source directory, is an error.
///
/// The client bundle uses it for user modules and for the Brazier modules it
/// copies.
pub fn resolve_ffi_path(
  module: String,
  path: String,
) -> Result(String, String) {
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
