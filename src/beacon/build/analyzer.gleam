/// Glance-based code analyzer for the build tool.
///
/// Parses user source code, resolves the types of every field that crosses
/// the wire, and classifies Msg variants. Also validates purity and extracts
/// pure code for JS compilation.
import beacon/build/ast_refs
import beacon/build/field_type.{type FieldType, type TypeDef}
import beacon/build/source_location
import beacon/log
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// A field in a Model or Local type, or an argument of a Msg variant.
pub type TypeField {
  TypeField(
    /// The field name (e.g., "count"). Unlabelled Msg arguments are `argN`.
    name: String,
    /// The outer type name as written (e.g., "Int", "List"). Descriptive only;
    /// code generation uses `field_type`.
    type_name: String,
    /// For generic types like List(Stroke), the inner type name. Descriptive only.
    inner_type: String,
    /// Module qualifier for the type (e.g., "auth" for auth.AuthState). Empty = local.
    module: String,
    /// Module qualifier for the inner type (e.g., "card" for List(card.Card)). Empty = local.
    inner_module: String,
    /// The resolved type, with imports and aliases applied.
    field_type: FieldType,
  )
}

/// A custom type with its fields (for JSON codec generation).
pub type CustomTypeInfo {
  CustomTypeInfo(
    /// The type name (e.g., "Stroke").
    name: String,
    /// The type's fields.
    fields: List(TypeField),
    /// Module this type comes from (e.g., "auth"). Empty = local to the app module.
    module: String,
  )
}

/// A substate — a Model field whose type is a custom record type.
/// The framework tracks and diffs these independently for efficiency.
/// When a substate's JSON hasn't changed, its diff is skipped entirely.
pub type SubstateInfo {
  SubstateInfo(
    /// The field name in Model (e.g., "cards").
    field_name: String,
    /// The type name (e.g., "Card" for List(Card), or "Settings" for Settings).
    type_name: String,
    /// Whether this is a List of the type (true) or a single instance (false).
    is_list: Bool,
    /// Module this type comes from (e.g., "auth"). Empty = local.
    module: String,
  )
}

/// An enum type — custom type with multiple variants, no fields (e.g., Column { Todo; Doing; Done }).
/// Encoded as strings in JSON, decoded back to the enum type.
pub type EnumTypeInfo {
  EnumTypeInfo(
    /// The type name (e.g., "Column").
    name: String,
    /// The variant names (e.g., ["Todo", "Doing", "Done"]).
    variants: List(String),
    /// Module this type comes from (e.g., "auth"). Empty = local.
    module: String,
  )
}

/// A computed field — a server-side derived value from Model.
/// Detected automatically: public functions with signature fn(Model) -> T.
/// Computed values are included in model_sync JSON but NOT in client encode_model.
pub type ComputedField {
  ComputedField(
    /// The function name (e.g., "subtotal", "total").
    name: String,
    /// The return type name as written (e.g., "Int"). Empty when unannotated.
    return_type: String,
    /// The resolved return type. Unannotated functions are unsupported.
    field_type: FieldType,
  )
}

/// An imported module resolved from user source imports.
pub type ImportedModule {
  ImportedModule(
    /// The module path as used in the import (e.g., "domains/auth").
    module_path: String,
    /// The alias used to reference it (e.g., "auth" for `import domains/auth`).
    alias: String,
  )
}

/// A Msg type from an imported client-visible module.
pub type MsgTypeInfo {
  MsgTypeInfo(
    /// Module alias used from the app source.
    module: String,
    /// Variants the browser may send: the module's `ClientMsg` allowlist when
    /// it has one, otherwise every variant.
    variants: List(MsgVariant),
    /// Every variant of the Msg type, whether or not the browser may send it.
    /// Generated client encoders match on these exhaustively.
    all_variants: List(MsgVariant),
  )
}

/// Result of analyzing a user's app module.
pub type Analysis {
  Analysis(
    /// Whether a public Model type was found in the primary or imported module.
    has_model: Bool,
    /// Module alias of the Model type (empty string if in primary file).
    model_module: String,
    /// Type name of the Model type.
    model_type_name: String,
    /// Msg variants with their classification. Empty when the app has no
    /// update function. When the Msg type is imported and the app defines a
    /// `ClientMsg` allowlist, only the allowed variants.
    msg_variants: List(MsgVariant),
    /// Every variant of the primary Msg type, classified against the update
    /// function when there is one. Generated client code matches on these
    /// exhaustively, so a Msg variant is never handled by a catch-all.
    msg_type_variants: List(MsgVariant),
    /// Module alias of the primary Msg type (empty string if in primary file).
    msg_module: String,
    /// Type name of the primary Msg type.
    msg_type_name: String,
    /// Optional allowlist of browser-originated Msg variants from `ClientMsg`.
    client_msg_variants: List(MsgVariant),
    /// Whether the module has a Local type.
    has_local: Bool,
    /// Module alias of the Local type (empty string if in primary file).
    local_module: String,
    /// Type name of the Local type.
    local_type_name: String,
    /// Fields of the Local type, when present.
    local_fields: List(TypeField),
    /// Whether the module has a Server type (private server-side state).
    has_server: Bool,
    /// Module alias of the Server type (empty string if in primary file, e.g. "server_state").
    server_module: String,
    /// Type name of the Server type (e.g. "Server" or "ServerState").
    server_type_name: String,
    /// Fields of the Server type (never sent to client).
    server_fields: List(TypeField),
    /// Fields of the Model type (for JSON codec generation).
    model_fields: List(TypeField),
    /// Whether the module has a direct `pub fn init` (vs make_init factory).
    has_direct_init: Bool,
    /// Whether the module has a direct `pub fn update` (vs make_update factory).
    has_direct_update: Bool,
    /// Whether the module has a direct `pub fn view`.
    has_direct_view: Bool,
    /// All custom types found in the module (for nested decoder generation).
    custom_types: List(CustomTypeInfo),
    /// Enum types — custom types with multiple variants, no fields.
    enum_types: List(EnumTypeInfo),
    /// Substates — Model fields that are custom record types, tracked independently.
    substates: List(SubstateInfo),
    /// Computed fields — @computed pub fn functions, server-side derived values.
    computed_fields: List(ComputedField),
    /// External modules imported by the user app (for multi-file analysis).
    imported_modules: List(ImportedModule),
    /// Imported module Msg types used by routed/component apps.
    external_msg_types: List(MsgTypeInfo),
    /// Every custom type and type alias in the analyzed modules, keyed by
    /// #(canonical module alias, type name). The app module's alias is "".
    type_defs: Dict(#(String, String), TypeDef),
    /// Server-only modules the app module imports. They are stripped from
    /// the client bundle.
    skipped_client_imports: List(String),
  )
}

/// A single Msg variant with its model-impact classification.
pub type MsgVariant {
  MsgVariant(
    /// The variant name (e.g., "Increment", "SetInput").
    name: String,
    /// Fields carried by this message variant, in constructor order.
    fields: List(TypeField),
    /// True if this variant's update branch modifies Model.
    affects_model: Bool,
    /// True if this variant's update branch modifies Local.
    affects_local: Bool,
  )
}

/// Message state impact used by diagnostics and generated client behavior.
pub type MsgImpact {
  /// Updates only Local state, so the browser can handle it without server traffic.
  LocalOnly
  /// Updates only Model state, so it must go through the server-authoritative loop.
  ModelOnly
  /// Updates both Model and Local. The browser may update Local immediately, but
  /// the event still needs server-authoritative Model sync/patch.
  ModelAndLocal
}

/// An imported module parsed once, with the scope its type names resolve in.
type External {
  External(
    alias: String,
    module_path: String,
    module: glance.Module,
    scope: field_type.Scope,
  )
}

/// Analyze a single Gleam source string.
pub fn analyze(source: String) -> Result(Analysis, String) {
  analyze_path("app module", source, [])
}

/// Analyze a multi-file app: main source + external module sources.
/// Each external source is a #(alias, module_path, source_text) triple where:
/// - alias is the module qualifier (e.g., "auth" for `import domains/auth`)
/// - module_path is the import path (e.g., "domains/auth")
/// - source_text is the file contents
pub fn analyze_multi(
  source: String,
  external_sources: List(#(String, String, String)),
) -> Result(Analysis, String) {
  analyze_path("app module", source, external_sources)
}

/// Analyze an app module read from `path`, plus its imported app modules.
/// `path` is used only in parse error messages.
pub fn analyze_path(
  path: String,
  source: String,
  external_sources: List(#(String, String, String)),
) -> Result(Analysis, String) {
  use module <- result.try(parse(path, source))
  let external_sources = unique_by_path(external_sources)
  use canonical <- result.try(
    external_sources
    |> list.map(fn(ext) { #(ext.0, ext.1) })
    |> field_type.canonical_aliases,
  )
  use externals <- result.try(
    list.try_map(external_sources, fn(ext) {
      let #(alias, module_path, ext_source) = ext
      use ext_module <- result.map(parse(module_path <> ".gleam", ext_source))
      External(
        alias:,
        module_path:,
        module: ext_module,
        scope: field_type.scope(ext_module, alias, canonical),
      )
    }),
  )
  let analysis =
    analyze_primary(module, field_type.scope(module, "", canonical))
  let analysis = case externals {
    [] -> analysis
    _ -> merge_externals(analysis, externals)
  }
  Ok(finish(analysis))
}

fn parse(path: String, source: String) -> Result(glance.Module, String) {
  glance.module(source)
  |> result.map_error(fn(err) {
    let message = source_location.describe_parse_error(path, source, err)
    log.error("beacon.build.analyzer", "Cannot parse " <> message)
    "Cannot parse " <> message
  })
}

fn unique_by_path(
  sources: List(#(String, String, String)),
) -> List(#(String, String, String)) {
  let #(_seen, kept) =
    list.fold(sources, #(set.new(), []), fn(acc, ext) {
      let #(seen, kept) = acc
      case set.contains(seen, ext.1) {
        True -> acc
        False -> #(set.insert(seen, ext.1), [ext, ..kept])
      }
    })
  list.reverse(kept)
}

const computed_excluded = [
  "view", "init", "init_local", "init_server", "update", "start", "main",
  "on_update", "make_update", "make_init", "make_on_update",
]

fn analyze_primary(module: glance.Module, scope: field_type.Scope) -> Analysis {
  let msg_type = find_custom_type(module, "Msg")
  let has_direct_init = result.is_ok(find_function(module, "init"))
  let has_direct_update = result.is_ok(find_function(module, "update"))
  let has_direct_view = result.is_ok(find_function(module, "view"))
  let update_fn = find_update_function(module)

  let #(has_local, local_fields) = case find_custom_type(module, "Local") {
    Ok(local_type) -> #(True, extract_fields(scope, local_type))
    Error(_) -> #(False, [])
  }
  let #(has_server, server_fields) = case find_custom_type(module, "Server") {
    Ok(server_type) -> #(True, extract_fields(scope, server_type))
    Error(_) -> #(False, [])
  }
  let #(has_model, model_fields) = case find_custom_type(module, "Model") {
    Ok(model_type) -> #(True, extract_fields(scope, model_type))
    Error(_) -> {
      log.debug(
        "beacon.build.analyzer",
        "No Model type found — this module may not be an app component",
      )
      #(False, [])
    }
  }

  let custom_types =
    list.filter_map(module.custom_types, fn(def) {
      let name = def.definition.name
      case list.contains(["Model", "Local", "Msg", "Server"], name) {
        True -> Error(Nil)
        False ->
          case extract_fields(scope, def.definition) {
            [] -> Error(Nil)
            fields -> Ok(CustomTypeInfo(name:, fields:, module: ""))
          }
      }
    })
  let enum_types =
    list.filter_map(module.custom_types, fn(def) {
      case list.contains(["Model", "Local", "Msg"], def.definition.name) {
        True -> Error(Nil)
        False -> enum_info(def.definition, "")
      }
    })

  let computed_fields =
    list.filter_map(module.functions, fn(def) { computed_field(scope, def) })

  let msg_type_variants = case msg_type, update_fn {
    Ok(msg), Ok(func) -> classify_variants(scope, msg, func, has_local)
    Ok(msg), Error(_) -> variants_from_msg_type(scope, msg)
    Error(_), _ -> []
  }
  let variants = case msg_type, update_fn {
    Ok(_), Ok(_) -> msg_type_variants
    _, _ -> {
      log.debug(
        "beacon.build.analyzer",
        "No Msg type or update function in this file — codec-only analysis",
      )
      []
    }
  }
  let client_variants = case find_custom_type(module, "ClientMsg") {
    Ok(client_msg) -> variants_from_msg_type(scope, client_msg)
    Error(_) -> []
  }
  Analysis(
    has_model:,
    model_module: "",
    model_type_name: "Model",
    msg_variants: variants,
    msg_type_variants:,
    msg_module: "",
    msg_type_name: "Msg",
    client_msg_variants: client_variants,
    has_local:,
    local_module: "",
    local_type_name: "Local",
    local_fields:,
    has_server:,
    server_module: "",
    server_type_name: "Server",
    server_fields:,
    model_fields:,
    has_direct_init:,
    has_direct_update:,
    has_direct_view:,
    custom_types:,
    enum_types:,
    substates: [],
    computed_fields:,
    imported_modules: [],
    external_msg_types: [],
    type_defs: module_type_defs(module, scope),
    skipped_client_imports: skipped_client_imports(module),
  )
}

fn find_update_function(
  module: glance.Module,
) -> Result(glance.Function, String) {
  case find_function(module, "update") {
    Ok(func) -> Ok(func)
    Error(_) -> find_function(module, "make_update")
  }
}

fn enum_info(
  custom_type: glance.CustomType,
  module_alias: String,
) -> Result(EnumTypeInfo, Nil) {
  let all_fieldless =
    list.all(custom_type.variants, fn(v) { list.is_empty(v.fields) })
  case all_fieldless && list.length(custom_type.variants) >= 2 {
    True ->
      Ok(EnumTypeInfo(
        name: custom_type.name,
        variants: list.map(custom_type.variants, fn(v) { v.name }),
        module: module_alias,
      ))
    False -> Error(Nil)
  }
}

/// A computed field is a public function taking exactly one `Model` argument
/// that does not return a `Node`. Its return type must be annotated so the
/// codec knows how to encode it.
fn computed_field(
  scope: field_type.Scope,
  def: glance.Definition(glance.Function),
) -> Result(ComputedField, Nil) {
  let func = def.definition
  let is_candidate =
    func.publicity == glance.Public
    && !list.contains(computed_excluded, func.name)
  case is_candidate, func.parameters, func.return {
    False, _, _ -> Error(Nil)
    True,
      [
        glance.FunctionParameter(
          type_: option.Some(glance.NamedType(name: "Model", ..)),
          ..,
        ),
      ],
      option.Some(glance.NamedType(name: "Node", ..))
    -> Error(Nil)
    True,
      [
        glance.FunctionParameter(
          type_: option.Some(glance.NamedType(name: "Model", ..)),
          ..,
        ),
      ],
      option.Some(return_type)
    ->
      Ok(ComputedField(
        name: func.name,
        return_type: written_type_name(return_type),
        field_type: field_type.resolve(scope, return_type),
      ))
    True,
      [
        glance.FunctionParameter(
          type_: option.Some(glance.NamedType(name: "Model", ..)),
          ..,
        ),
      ],
      option.None
    ->
      Ok(ComputedField(
        name: func.name,
        return_type: "",
        field_type: field_type.UnsupportedType(
          "computed field `"
          <> func.name
          <> "` has no return annotation; add `-> Type` so its value can be encoded",
        ),
      ))
    True, _, _ -> Error(Nil)
  }
}

fn written_type_name(type_: glance.Type) -> String {
  case type_ {
    glance.NamedType(name:, ..) -> name
    glance.TupleType(elements:, ..) -> tuple_type_name(elements)
    glance.FunctionType(..) -> "fn"
    glance.VariableType(name:, ..) -> name
    glance.HoleType(name:, ..) -> name
  }
}

fn module_type_defs(
  module: glance.Module,
  scope: field_type.Scope,
) -> Dict(#(String, String), TypeDef) {
  let customs =
    list.map(module.custom_types, fn(def) {
      #(
        #(scope.current, def.definition.name),
        field_type.custom_type_def(scope, def.definition),
      )
    })
  let aliases =
    list.map(module.type_aliases, fn(def) {
      #(
        #(scope.current, def.definition.name),
        field_type.type_alias_def(scope, def.definition),
      )
    })
  dict.from_list(list.append(customs, aliases))
}

/// Fold imported app modules into the primary module's analysis: their types,
/// their nested Msg types, and Model/Msg/Server/Local when the primary module
/// does not define them itself.
fn merge_externals(analysis: Analysis, externals: List(External)) -> Analysis {
  let boundary_types = ["Msg", "ClientMsg", "Server"]
  let ext_custom_types =
    list.flat_map(externals, fn(ext) {
      list.filter_map(ext.module.custom_types, fn(def) {
        let ct = def.definition
        case
          ct.publicity == glance.Public
          && !list.contains(boundary_types, ct.name)
        {
          False -> Error(Nil)
          True ->
            case
              extract_fields(ext.scope, ct)
              |> qualify_external_fields(ext.alias)
            {
              [] -> Error(Nil)
              fields ->
                Ok(CustomTypeInfo(name: ct.name, fields:, module: ext.alias))
            }
        }
      })
    })
  let ext_enum_types =
    list.flat_map(externals, fn(ext) {
      list.filter_map(ext.module.custom_types, fn(def) {
        let ct = def.definition
        case
          ct.publicity == glance.Public
          && !list.contains(boundary_types, ct.name)
        {
          False -> Error(Nil)
          True -> enum_info(ct, ext.alias)
        }
      })
    })
  let ext_msg_types =
    list.filter_map(externals, fn(ext) {
      case find_custom_type(ext.module, "Msg") {
        Ok(_) ->
          Ok(MsgTypeInfo(
            module: ext.alias,
            variants: external_msg_variants(ext, False),
            all_variants: external_msg_type_variants(ext, False),
          ))
        Error(_) -> Error(Nil)
      }
    })
  let imported_modules =
    list.map(externals, fn(ext) {
      ImportedModule(module_path: ext.module_path, alias: ext.alias)
    })
    |> list.reverse
  let type_defs =
    list.fold(externals, analysis.type_defs, fn(acc, ext) {
      dict.merge(acc, module_type_defs(ext.module, ext.scope))
    })

  let #(has_model, model_module, model_type_name, model_fields) = case
    analysis.has_model
  {
    True -> #(
      True,
      analysis.model_module,
      analysis.model_type_name,
      analysis.model_fields,
    )
    False ->
      case find_external_type(externals, ["Model"]) {
        Ok(#(ext, ct)) -> {
          log.info(
            "beacon.build.analyzer",
            "Found Model type in external module: " <> ext.alias,
          )
          #(
            True,
            ext.alias,
            ct.name,
            extract_fields(ext.scope, ct) |> qualify_external_fields(ext.alias),
          )
        }
        Error(Nil) -> #(False, "", "Model", [])
      }
  }

  let #(
    msg_variants,
    msg_type_variants,
    msg_module,
    msg_type_name,
    client_msg_variants,
  ) = case analysis.msg_variants {
    [_, ..] -> #(
      analysis.msg_variants,
      analysis.msg_type_variants,
      analysis.msg_module,
      analysis.msg_type_name,
      analysis.client_msg_variants,
    )
    [] ->
      case
        list.find(externals, fn(ext) {
          result.is_ok(find_custom_type(ext.module, "Msg"))
        })
      {
        Ok(ext) -> {
          log.info(
            "beacon.build.analyzer",
            "Found Msg type in external module: " <> ext.alias,
          )
          // The app module's ClientMsg allowlist, when it has one, applies to
          // the Msg type it imports: only those variants are generated.
          let #(variants, client_variants) = case
            find_custom_type(ext.module, "ClientMsg"),
            analysis.client_msg_variants
          {
            Ok(client_msg), _ -> {
              let allowed = variants_from_msg_type(ext.scope, client_msg)
              #(allowed, allowed)
            }
            Error(_), [_, ..] as allowed -> #(allowed, allowed)
            Error(_), [] -> #(
              external_msg_variants(ext, analysis.has_local),
              [],
            )
          }
          #(
            variants,
            external_msg_type_variants(ext, analysis.has_local),
            ext.alias,
            "Msg",
            client_variants,
          )
        }
        Error(Nil) -> #([], analysis.msg_type_variants, "", "Msg", [])
      }
  }

  let #(has_server, server_module, server_type_name, server_fields) = case
    analysis.has_server
  {
    True -> #(
      True,
      analysis.server_module,
      analysis.server_type_name,
      analysis.server_fields,
    )
    False ->
      case find_external_type(externals, ["Server", "ServerState"]) {
        Ok(#(ext, ct)) -> {
          log.info(
            "beacon.build.analyzer",
            "Found " <> ct.name <> " type in external module: " <> ext.alias,
          )
          #(
            True,
            ext.alias,
            ct.name,
            extract_fields(ext.scope, ct) |> qualify_external_fields(ext.alias),
          )
        }
        Error(Nil) -> #(False, "", "Server", [])
      }
  }

  let #(has_local, local_module, local_type_name, local_fields) = case
    analysis.has_local
  {
    True -> #(
      True,
      analysis.local_module,
      analysis.local_type_name,
      analysis.local_fields,
    )
    False ->
      case find_external_type(externals, ["Local"]) {
        Ok(#(ext, ct)) -> #(
          True,
          ext.alias,
          ct.name,
          extract_fields(ext.scope, ct) |> qualify_external_fields(ext.alias),
        )
        Error(Nil) -> #(False, "", "Local", [])
      }
  }

  let external_msg_types = case msg_module {
    "" -> ext_msg_types
    alias -> list.filter(ext_msg_types, fn(info) { info.module != alias })
  }

  Analysis(
    ..analysis,
    has_model:,
    model_module:,
    model_type_name:,
    msg_variants:,
    msg_type_variants:,
    msg_module:,
    msg_type_name:,
    client_msg_variants:,
    has_local:,
    local_module:,
    local_type_name:,
    local_fields:,
    has_server:,
    server_module:,
    server_type_name:,
    server_fields:,
    model_fields:,
    custom_types: list.append(analysis.custom_types, ext_custom_types),
    enum_types: list.append(analysis.enum_types, ext_enum_types),
    imported_modules:,
    external_msg_types:,
    type_defs:,
  )
}

/// The variants of an imported module's Msg type: its own `ClientMsg`
/// allowlist when it has one, otherwise every Msg variant, classified
/// against the module's update function when it has one.
fn external_msg_variants(ext: External, has_local: Bool) -> List(MsgVariant) {
  case find_custom_type(ext.module, "ClientMsg") {
    Ok(client_msg) -> variants_from_msg_type(ext.scope, client_msg)
    Error(_) ->
      case find_custom_type(ext.module, "Msg") {
        Error(_) -> []
        Ok(msg_type) ->
          case find_update_function(ext.module) {
            Ok(func) -> classify_variants(ext.scope, msg_type, func, has_local)
            Error(_) -> variants_from_msg_type(ext.scope, msg_type)
          }
      }
  }
}

/// Every variant of an imported module's Msg type, classified against the
/// module's update function when it has one.
fn external_msg_type_variants(
  ext: External,
  has_local: Bool,
) -> List(MsgVariant) {
  case find_custom_type(ext.module, "Msg") {
    Error(_) -> []
    Ok(msg_type) ->
      case find_update_function(ext.module) {
        Ok(func) -> classify_variants(ext.scope, msg_type, func, has_local)
        Error(_) -> variants_from_msg_type(ext.scope, msg_type)
      }
  }
}

/// The first public custom type named one of `names` in any imported module.
fn find_external_type(
  externals: List(External),
  names: List(String),
) -> Result(#(External, glance.CustomType), Nil) {
  list.find_map(externals, fn(ext) {
    list.find_map(ext.module.custom_types, fn(def) {
      case
        list.contains(names, def.definition.name)
        && def.definition.publicity == glance.Public
      {
        True -> Ok(#(ext, def.definition))
        False -> Error(Nil)
      }
    })
  })
}

/// Expand type aliases everywhere and derive substates from resolved types.
fn finish(analysis: Analysis) -> Analysis {
  let aliases =
    dict.fold(analysis.type_defs, dict.new(), fn(acc, key, def) {
      case def {
        field_type.AliasDef(target) -> dict.insert(acc, key, target)
        _ -> acc
      }
    })
  let expand = fn(type_) { field_type.expand_aliases(type_, aliases) }
  let expand_fields = fn(fields: List(TypeField)) {
    list.map(fields, fn(f) { TypeField(..f, field_type: expand(f.field_type)) })
  }
  let expand_variants = fn(variants: List(MsgVariant)) {
    list.map(variants, fn(v) {
      MsgVariant(..v, fields: expand_fields(v.fields))
    })
  }
  let type_defs =
    dict.map_values(analysis.type_defs, fn(_key, def) {
      case def {
        field_type.RecordDef(constructor:, fields:) ->
          field_type.RecordDef(
            constructor:,
            fields: list.map(fields, fn(f) { #(f.0, expand(f.1)) }),
          )
        field_type.AliasDef(target) -> field_type.AliasDef(expand(target))
        field_type.EnumDef(..) | field_type.UnsupportedDef(..) -> def
      }
    })
  let model_fields = expand_fields(analysis.model_fields)
  Analysis(
    ..analysis,
    model_fields:,
    local_fields: expand_fields(analysis.local_fields),
    server_fields: expand_fields(analysis.server_fields),
    msg_variants: expand_variants(analysis.msg_variants),
    msg_type_variants: expand_variants(analysis.msg_type_variants),
    client_msg_variants: expand_variants(analysis.client_msg_variants),
    external_msg_types: list.map(analysis.external_msg_types, fn(info) {
      MsgTypeInfo(
        ..info,
        variants: expand_variants(info.variants),
        all_variants: expand_variants(info.all_variants),
      )
    }),
    computed_fields: list.map(analysis.computed_fields, fn(c) {
      ComputedField(..c, field_type: expand(c.field_type))
    }),
    type_defs:,
    substates: list.filter_map(model_fields, fn(f) { substate(type_defs, f) }),
  )
}

/// A Model field is a substate when it holds a record (or a list of records)
/// with at least one field.
fn substate(
  type_defs: Dict(#(String, String), TypeDef),
  field: TypeField,
) -> Result(SubstateInfo, Nil) {
  let #(target, is_list) = case field.field_type {
    field_type.ListType(inner) -> #(inner, True)
    other -> #(other, False)
  }
  case target {
    field_type.NamedType(module:, name:) ->
      case dict.get(type_defs, #(module, name)) {
        Ok(field_type.RecordDef(fields: [_, ..], ..)) ->
          Ok(SubstateInfo(
            field_name: field.name,
            type_name: name,
            is_list:,
            module:,
          ))
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// ===== Codec type validation =====

/// The Msg variants the browser may send: the `ClientMsg` allowlist when the
/// app defines one, otherwise every Msg variant.
pub fn client_event_variants(analysis: Analysis) -> List(MsgVariant) {
  case analysis.client_msg_variants {
    [] -> analysis.msg_variants
    variants -> variants
  }
}

/// Check that every type the generated codecs must encode or decode is
/// supported: Model and Local fields, browser-sent Msg variants, nested Msg
/// types and computed fields. Every problem is reported, each naming the
/// field and the type.
pub fn validate_codec_types(analysis: Analysis) -> Result(Nil, String) {
  let nested_msg_modules =
    list.map(analysis.external_msg_types, fn(info) { info.module })
  let checker = Checker(type_defs: analysis.type_defs, nested_msg_modules:)
  let model_errors = case analysis.has_model {
    False -> []
    True ->
      root_errors(
        checker,
        analysis.model_module,
        analysis.model_type_name,
        analysis.model_fields,
      )
  }
  let local_errors = case analysis.has_local {
    False -> []
    True ->
      root_errors(
        checker,
        analysis.local_module,
        analysis.local_type_name,
        analysis.local_fields,
      )
  }
  let msg_label =
    field_type.qualified_name(analysis.msg_module, analysis.msg_type_name)
  let msg_errors =
    variant_errors(checker, msg_label, client_event_variants(analysis))
  let nested_errors =
    list.flat_map(analysis.external_msg_types, fn(info) {
      variant_errors(checker, info.module <> ".Msg", info.variants)
    })
  let computed_errors =
    list.flat_map(analysis.computed_fields, fn(c) {
      check_type(
        checker,
        "computed field `" <> c.name <> "`",
        c.field_type,
        set.new(),
      )
    })
  case
    list.flatten([
      model_errors,
      local_errors,
      msg_errors,
      nested_errors,
      computed_errors,
    ])
    |> list.unique
  {
    [] -> Ok(Nil)
    errors -> {
      let message =
        "Generated codecs cannot handle these types:\n  - "
        <> string.join(errors, "\n  - ")
      log.error("beacon.build.analyzer", message)
      Error(message)
    }
  }
}

type Checker {
  Checker(
    type_defs: Dict(#(String, String), TypeDef),
    nested_msg_modules: List(String),
  )
}

fn root_errors(
  checker: Checker,
  module: String,
  name: String,
  fields: List(TypeField),
) -> List(String) {
  let label = field_type.qualified_name(module, name)
  case dict.get(checker.type_defs, #(module, name)) {
    Ok(field_type.RecordDef(..)) ->
      list.flat_map(fields, fn(f) {
        check_type(
          checker,
          label <> "." <> f.name,
          f.field_type,
          set.from_list([#(module, name)]),
        )
      })
    Ok(field_type.UnsupportedDef(reason)) -> [label <> ": " <> reason]
    Ok(field_type.EnumDef(..)) | Ok(field_type.AliasDef(..)) -> [
      label <> ": must be a record with a single constructor",
    ]
    Error(Nil) -> [label <> ": type definition not found"]
  }
}

fn variant_errors(
  checker: Checker,
  msg_label: String,
  variants: List(MsgVariant),
) -> List(String) {
  list.flat_map(variants, fn(variant) {
    list.flat_map(variant.fields, fn(f) {
      let context = msg_label <> "." <> variant.name <> "." <> f.name
      case f.field_type {
        // A nested Msg is carried as an argument of a parent Msg variant.
        field_type.NamedType(module:, name: "Msg") ->
          case list.contains(checker.nested_msg_modules, module) {
            True -> []
            False -> check_type(checker, context, f.field_type, set.new())
          }
        other -> check_type(checker, context, other, set.new())
      }
    })
  })
}

fn check_type(
  checker: Checker,
  context: String,
  type_: FieldType,
  visiting: Set(#(String, String)),
) -> List(String) {
  let problem = fn(reason) {
    [
      context
      <> ": "
      <> reason
      <> " (type "
      <> field_type.describe(type_)
      <> ")",
    ]
  }
  case type_ {
    field_type.IntType
    | field_type.FloatType
    | field_type.BoolType
    | field_type.StringType -> []
    field_type.OptionType(inner) | field_type.ListType(inner) ->
      check_type(checker, context, inner, visiting)
    field_type.DictType(key:, value:) -> {
      let key_errors = case key {
        field_type.StringType | field_type.IntType -> []
        _ ->
          problem(
            "Dict keys must be String or Int, found `"
            <> field_type.describe(key)
            <> "`",
          )
      }
      list.append(key_errors, check_type(checker, context, value, visiting))
    }
    field_type.TupleType(elements) ->
      list.flat_map(elements, check_type(checker, context, _, visiting))
    field_type.UnsupportedType(reason) -> [context <> ": " <> reason]
    field_type.NamedType(module:, name:) -> {
      let key = #(module, name)
      let label = field_type.qualified_name(module, name)
      case set.contains(visiting, key), dict.get(checker.type_defs, key) {
        True, _ ->
          problem(
            "recursive type `"
            <> label
            <> "` cannot be encoded; generated codecs need a finite shape",
          )
        False, Error(Nil) ->
          problem("type `" <> label <> "` is not defined in an analyzed module")
        False, Ok(field_type.RecordDef(fields:, ..)) ->
          list.flat_map(fields, fn(f) {
            check_type(
              checker,
              context <> " → " <> label <> "." <> f.0,
              f.1,
              set.insert(visiting, key),
            )
          })
        False, Ok(field_type.EnumDef(variants)) -> {
          let wire_names = list.map(variants, field_type.enum_wire_name)
          case list.length(list.unique(wire_names)) == list.length(wire_names) {
            True -> []
            False ->
              problem(
                "enum `"
                <> label
                <> "` has variants that differ only by case; they would encode to the same JSON string",
              )
          }
        }
        // Aliases are expanded by `finish`, so one surviving here is a bug.
        False, Ok(field_type.AliasDef(..)) ->
          problem("type alias `" <> label <> "` was not expanded")
        False, Ok(field_type.UnsupportedDef(reason)) -> problem(reason)
      }
    }
  }
}

fn qualify_external_fields(
  fields: List(TypeField),
  module_alias: String,
) -> List(TypeField) {
  list.map(fields, fn(field) {
    TypeField(
      ..field,
      module: qualify_external_type_module(
        field.type_name,
        field.module,
        module_alias,
      ),
      inner_module: qualify_external_type_module(
        field.inner_type,
        field.inner_module,
        module_alias,
      ),
    )
  })
}

fn qualify_external_type_module(
  type_name: String,
  current_module: String,
  module_alias: String,
) -> String {
  case current_module, type_name {
    mod, _ if mod != "" -> mod
    _, "" -> ""
    _, "Int" -> ""
    _, "Float" -> ""
    _, "Bool" -> ""
    _, "String" -> ""
    _, "List" -> ""
    _, "Option" -> ""
    _, "Result" -> ""
    _, "Nil" -> ""
    _, _ -> module_alias
  }
}

/// Find a custom type by name in a module.
fn find_custom_type(
  module: glance.Module,
  name: String,
) -> Result(glance.CustomType, String) {
  case list.find(module.custom_types, fn(def) { def.definition.name == name }) {
    Ok(def) -> Ok(def.definition)
    Error(Nil) -> Error("Type '" <> name <> "' not found")
  }
}

/// Find a public function by name.
fn find_function(
  module: glance.Module,
  name: String,
) -> Result(glance.Function, String) {
  case
    list.find(module.functions, fn(def) {
      def.definition.name == name && def.definition.publicity == glance.Public
    })
  {
    Ok(def) -> Ok(def.definition)
    Error(Nil) -> Error("Public function '" <> name <> "' not found")
  }
}

/// Extract labelled fields from a custom type's first variant. Whether the
/// type is a valid record is checked by `validate_codec_types` through its
/// `TypeDef`.
fn extract_fields(
  scope: field_type.Scope,
  custom_type: glance.CustomType,
) -> List(TypeField) {
  case custom_type.variants {
    [variant, ..] ->
      list.filter_map(variant.fields, fn(field) {
        case field {
          glance.LabelledVariantField(item:, label:) ->
            Ok(type_field(scope, label, item))
          glance.UnlabelledVariantField(..) -> Error(Nil)
        }
      })
    [] -> []
  }
}

fn extract_variant_fields(
  scope: field_type.Scope,
  variant: glance.Variant,
) -> List(TypeField) {
  list.index_map(variant.fields, fn(field, idx) {
    case field {
      glance.LabelledVariantField(item:, label:) ->
        type_field(scope, label, item)
      glance.UnlabelledVariantField(item:) ->
        type_field(scope, "arg" <> int.to_string(idx), item)
    }
  })
}

fn type_field(
  scope: field_type.Scope,
  name: String,
  annotation: glance.Type,
) -> TypeField {
  let #(type_name, inner_type, module, inner_module) =
    type_parts(annotation, name)
  TypeField(
    name:,
    type_name:,
    inner_type:,
    module:,
    inner_module:,
    field_type: field_type.resolve(scope, annotation),
  )
}

fn type_parts(
  field_type: glance.Type,
  field_name: String,
) -> #(String, String, String, String) {
  case field_type {
    glance.NamedType(name: n, module: mod, parameters: params, ..) ->
      case params {
        [glance.NamedType(name: inner_name, module: inner_mod, ..)] -> {
          let m = module_name_or_empty(mod, field_name, False)
          let im = module_name_or_empty(inner_mod, field_name, True)
          #(n, inner_name, m, im)
        }
        [glance.TupleType(elements: elements, ..)] -> {
          let m = module_name_or_empty(mod, field_name, False)
          #(n, tuple_type_name(elements), m, "")
        }
        _ -> {
          let m = module_name_or_empty(mod, field_name, False)
          #(n, "", m, "")
        }
      }
    glance.TupleType(elements: elements, ..) -> #(
      "Tuple",
      tuple_type_name(elements),
      "",
      "",
    )
    _ -> #("Unknown", "", "", "")
  }
}

fn tuple_type_name(elements: List(glance.Type)) -> String {
  "#("
  <> {
    elements
    |> list.map(tuple_element_type_name)
    |> string.join(", ")
  }
  <> ")"
}

fn tuple_element_type_name(type_: glance.Type) -> String {
  case type_ {
    glance.NamedType(name: name, ..) -> name
    glance.TupleType(elements: elements, ..) -> tuple_type_name(elements)
    _ -> "Unknown"
  }
}

fn module_name_or_empty(
  module_name: option.Option(String),
  field_name: String,
  inner: Bool,
) -> String {
  case module_name {
    option.Some(name) -> name
    option.None -> {
      let label = case inner {
        True -> "inner module qualifier"
        False -> "module qualifier"
      }
      log.debug(
        "beacon.build.analyzer",
        "No " <> label <> " for type field '" <> field_name <> "'",
      )
      ""
    }
  }
}

/// Classify each Msg variant based on the update function's case arms.
/// A variant affects the model if its case arm returns a modified model
/// (not just returning the input model unchanged).
fn classify_variants(
  scope: field_type.Scope,
  msg_type: glance.CustomType,
  update_fn: glance.Function,
  has_local: Bool,
) -> List(MsgVariant) {
  // Get the model parameter name.
  // For direct update(model, local, msg), it's the first param.
  // For make_update(shared) -> fn(model, local, msg), it's the first param
  // of the INNER anonymous function.
  let model_param = case update_fn.body {
    // Factory pattern: body is fn(model, local, msg) { ... }
    [glance.Expression(glance.Fn(arguments: args, ..))] ->
      case args {
        [glance.FnParameter(name: glance.Named(name), ..), ..] -> name
        _ -> "model"
      }
    // Direct function: first param is model
    _ ->
      case update_fn.parameters {
        [first, ..] ->
          case first.name {
            glance.Named(name) -> name
            glance.Discarded(_) -> "model"
          }
        _ -> "model"
      }
  }

  let local_param = case update_fn.body {
    // Factory pattern: body is fn(model, local, msg) { ... }
    [glance.Expression(glance.Fn(arguments: args, ..))] ->
      case args {
        [_, glance.FnParameter(name: glance.Named(name), ..), ..] -> name
        _ -> "local"
      }
    // Direct function: second param is local when present
    _ ->
      case update_fn.parameters {
        [_, second, ..] ->
          case second.name {
            glance.Named(name) -> name
            glance.Discarded(_) -> "local"
          }
        _ -> "local"
      }
  }

  // Try to analyze the case expression in update
  let case_arms = extract_case_arms(update_fn)

  // For each variant, check if its case arm modifies the model
  list.map(msg_type.variants, fn(variant) {
    let name = variant.name
    let arm = find_arm_for_variant(case_arms, name)
    let affects_model = case arm {
      Ok(body) -> body_modifies_model(body, model_param)
      Error(Nil) -> True
    }
    let affects_local = case has_local, arm {
      True, Ok(body) -> body_modifies_local(body, local_param)
      _, _ -> False
    }
    MsgVariant(
      name: name,
      fields: extract_variant_fields(scope, variant),
      affects_model: affects_model,
      affects_local: affects_local,
    )
  })
}

fn variants_from_msg_type(
  scope: field_type.Scope,
  msg_type: glance.CustomType,
) -> List(MsgVariant) {
  list.map(msg_type.variants, fn(variant) {
    MsgVariant(
      name: variant.name,
      fields: extract_variant_fields(scope, variant),
      affects_model: True,
      affects_local: False,
    )
  })
}

/// Extract case arms from the update function body.
/// Looks for a top-level `case msg { ... }` expression, or inside a nested
/// anonymous function (for make_update factory pattern).
fn extract_case_arms(func: glance.Function) -> List(glance.Clause) {
  case func.body {
    // Direct: pub fn update(...) { case msg { ... } } or
    // universal app shape: let #(model, local) = case msg { ... }
    body -> case_arms_from_statements(body)
  }
}

fn case_arms_from_statements(
  statements: List(glance.Statement),
) -> List(glance.Clause) {
  case statements {
    [glance.Expression(glance.Case(clauses: clauses, ..)), ..] -> clauses
    [glance.Assignment(value: glance.Case(clauses: clauses, ..), ..), ..] ->
      clauses
    // Factory: pub fn make_update(...) { fn(...) { case msg { ... } } }
    [glance.Expression(glance.Fn(body: body, ..))] ->
      case_arms_from_statements(body)
    _ -> []
  }
}

/// Find the case arm that matches a specific variant name.
fn find_arm_for_variant(
  arms: List(glance.Clause),
  variant_name: String,
) -> Result(glance.Expression, Nil) {
  list.find_map(arms, fn(clause) {
    // Check if any pattern in this clause matches the variant
    let matches =
      list.any(clause.patterns, fn(pattern_group) {
        list.any(pattern_group, fn(pattern) {
          pattern_matches_variant(pattern, variant_name)
        })
      })
    case matches {
      True -> Ok(clause.body)
      False -> Error(Nil)
    }
  })
}

/// Check if a pattern matches a specific variant name.
fn pattern_matches_variant(
  pattern: glance.Pattern,
  variant_name: String,
) -> Bool {
  case pattern {
    glance.PatternVariant(constructor: ctor, ..) -> ctor == variant_name
    _ -> False
  }
}

/// Check if a case arm body modifies the model parameter.
/// Heuristic: if the body constructs a new Model (contains "Model(" or
/// a record update "Model(..") it modifies the model.
/// If it just returns the model variable unchanged, it doesn't.
fn body_modifies_model(body: glance.Expression, model_param: String) -> Bool {
  case body {
    // #(Model(..model, ...), local) — tuple with model constructor
    glance.Tuple(elements: [first, ..], ..) ->
      expression_constructs_new(first, model_param)
    // Model(..model, ...) — direct model constructor (simple update)
    glance.Call(function: glance.Variable(name: name, ..), ..)
      if name != model_param
    -> True
    // Just returning the model variable unchanged
    glance.Variable(name: name, ..) if name == model_param -> False
    // Block { let x = ...; #(model, local) } — check last statement
    glance.Block(statements: stmts, ..) ->
      case last_expression(stmts) {
        Ok(last) -> body_modifies_model(last, model_param)
        Error(Nil) -> True
      }
    // case x { ... } — check if ALL arms don't modify model
    glance.Case(clauses: clauses, ..) ->
      list.any(clauses, fn(clause) {
        body_modifies_model(clause.body, model_param)
      })
    // Anything else — assume it modifies (conservative)
    _ -> True
  }
}

fn body_modifies_local(body: glance.Expression, local_param: String) -> Bool {
  case body {
    // #(model, Local(..local, ...)) — tuple with Local in the second slot.
    glance.Tuple(elements: [_, second, ..], ..) ->
      expression_constructs_new(second, local_param)
    // Block { let x = ...; #(model, local) } — check last statement.
    glance.Block(statements: stmts, ..) ->
      case last_expression(stmts) {
        Ok(last) -> body_modifies_local(last, local_param)
        Error(Nil) -> False
      }
    // case x { ... } — local changes if any branch changes local.
    glance.Case(clauses: clauses, ..) ->
      list.any(clauses, fn(clause) {
        body_modifies_local(clause.body, local_param)
      })
    _ -> False
  }
}

/// Classify a message variant into its state-impact category.
pub fn msg_impact(variant: MsgVariant) -> MsgImpact {
  case variant.affects_model, variant.affects_local {
    False, True -> LocalOnly
    True, True -> ModelAndLocal
    _, _ -> ModelOnly
  }
}

/// Human-readable label for a message impact.
pub fn msg_impact_label(impact: MsgImpact) -> String {
  case impact {
    LocalOnly -> "LOCAL"
    ModelOnly -> "MODEL"
    ModelAndLocal -> "MODEL+LOCAL"
  }
}

/// Human-readable diagnostics for the inferred Beacon app state shape.
pub fn state_diagnostics(analysis: Analysis) -> List(String) {
  let shape = case analysis.has_local, analysis.has_server {
    False, False -> "Model"
    True, False -> "Model + Local"
    False, True -> "Model + Server"
    True, True -> "Model + Local + Server"
  }

  let local_line = case analysis.has_local {
    True ->
      "Local inferred from pub type Local ("
      <> int.to_string(list.length(analysis.local_fields))
      <> " fields): LOCAL messages stay client-only; MODEL+LOCAL messages still sync Model through the server."
    False ->
      "No Local type inferred: every client event is server-authoritative."
  }

  let server_line = case analysis.has_server {
    True -> {
      let module_label = case analysis.server_module {
        "" -> analysis.server_type_name
        alias -> alias <> "." <> analysis.server_type_name
      }
      "Server inferred from pub type "
      <> module_label
      <> " ("
      <> int.to_string(list.length(analysis.server_fields))
      <> " fields): Server is private and excluded from client bundles/codecs."
    }
    False ->
      "No Server type inferred: all app state visible to view/client is Model or Local."
  }

  [
    "Beacon app state shape: " <> shape,
    local_line,
    server_line,
    "Message impacts: " <> message_impact_summary(analysis.msg_variants),
  ]
}

/// Human-readable build-time client contract report.
///
/// This is intentionally explicit: every Beacon app should make it obvious
/// which state is client-visible, which imports were stripped from the client
/// bundle, which codecs were generated, and why each message is LOCAL, MODEL,
/// or MODEL+LOCAL.
pub fn client_contract_report(analysis: Analysis) -> List(String) {
  let skipped_line = case analysis.skipped_client_imports {
    [] -> "Skipped client imports: none"
    skipped -> "Skipped client imports: " <> string.join(skipped, ", ")
  }

  let codec_names =
    list.flatten([
      ["Model encoder", "Model decoder"],
      case analysis.has_local {
        True -> ["Local decoder", "Model+Local encoder"]
        False -> []
      },
      list.map(analysis.custom_types, fn(ct) {
        "codec " <> qualified_type_label(ct.module, ct.name)
      }),
      list.map(analysis.enum_types, fn(et) {
        "enum codec " <> qualified_type_label(et.module, et.name)
      }),
    ])

  let codec_line = case codec_names {
    [] -> "Generated codecs: none"
    _ -> "Generated codecs: " <> string.join(codec_names, ", ")
  }

  list.flatten([
    [
      "Client contract:",
      "  Model: " <> field_summary(analysis.model_fields),
      "  Local: "
        <> optional_field_summary(analysis.has_local, analysis.local_fields),
      "  Server: " <> server_summary(analysis),
      "  " <> skipped_line,
      "  " <> codec_line,
    ],
    list.map(analysis.msg_variants, fn(v) {
      "  Msg."
      <> v.name
      <> ": "
      <> msg_impact_label(msg_impact(v))
      <> " — "
      <> msg_impact_reason(v)
    }),
  ])
}

/// One-line build summary intended for normal startup/codegen logs.
pub fn client_contract_summary(analysis: Analysis) -> String {
  let client_message_count = case analysis.client_msg_variants {
    [] -> list.length(analysis.msg_variants)
    variants -> list.length(variants)
  }
  let internal_message_count =
    list.length(analysis.msg_variants) - client_message_count
  let local = case analysis.has_local {
    True -> "Local=yes"
    False -> "Local=no"
  }
  let server = case analysis.has_server {
    True -> "Server=private"
    False -> "Server=none"
  }
  let client_msg = case analysis.client_msg_variants {
    [] -> "ClientMsg=all Msg variants"
    _ -> "ClientMsg=allowlist"
  }

  "Build contract summary: Model fields="
  <> int.to_string(list.length(analysis.model_fields))
  <> ", "
  <> local
  <> ", "
  <> server
  <> ", "
  <> client_msg
  <> ", browser messages="
  <> int.to_string(client_message_count)
  <> ", server/internal messages="
  <> int.to_string(internal_message_count)
  <> ", nested Msg types="
  <> int.to_string(list.length(analysis.external_msg_types))
  <> ", generated=encode_model/decode_model/decode_event/encode_msg/render_model"
}

fn skipped_client_imports(module: glance.Module) -> List(String) {
  list.filter_map(module.imports, fn(def) {
    let import_ = def.definition
    case is_server_only_import(import_.module) {
      True -> Ok(import_.module)
      False -> Error(Nil)
    }
  })
}

fn qualified_type_label(module_name: String, type_name: String) -> String {
  case module_name {
    "" -> type_name
    _ -> module_name <> "." <> type_name
  }
}

fn field_summary(fields: List(TypeField)) -> String {
  case fields {
    [] -> "no fields"
    _ ->
      fields
      |> list.map(fn(field) { field.name <> ": " <> field_type_label(field) })
      |> string.join(", ")
  }
}

fn optional_field_summary(has_fields: Bool, fields: List(TypeField)) -> String {
  case has_fields {
    True -> field_summary(fields)
    False -> "not defined"
  }
}

fn server_summary(analysis: Analysis) -> String {
  case analysis.has_server {
    True -> {
      let type_label = case analysis.server_module {
        "" -> analysis.server_type_name
        module_name -> module_name <> "." <> analysis.server_type_name
      }
      type_label <> " (" <> field_summary(analysis.server_fields) <> ")"
    }
    False -> "not defined"
  }
}

fn field_type_label(field: TypeField) -> String {
  case field.type_name, field.module, field.inner_type, field.inner_module {
    "List", _, inner, inner_module if inner != "" ->
      "List(" <> qualified_type_label(inner_module, inner) <> ")"
    type_name, module_name, _, _ -> qualified_type_label(module_name, type_name)
  }
}

fn msg_impact_reason(variant: MsgVariant) -> String {
  case variant.affects_model, variant.affects_local {
    False, True -> "update returns the original Model and a changed Local"
    True, True ->
      "update changes both Model and Local, so server sync is required"
    True, False -> "update changes Model, so server authority is required"
    False, False ->
      "update leaves Local unchanged and is treated as server-authoritative Model"
  }
}

fn message_impact_summary(variants: List(MsgVariant)) -> String {
  case variants {
    [] -> "none detected"
    _ -> {
      let local_count =
        variants
        |> list.filter(fn(v) { msg_impact(v) == LocalOnly })
        |> list.length
      let model_count =
        variants
        |> list.filter(fn(v) { msg_impact(v) == ModelOnly })
        |> list.length
      let mixed_count =
        variants
        |> list.filter(fn(v) { msg_impact(v) == ModelAndLocal })
        |> list.length
      "LOCAL="
      <> int.to_string(local_count)
      <> ", MODEL="
      <> int.to_string(model_count)
      <> ", MODEL+LOCAL="
      <> int.to_string(mixed_count)
    }
  }
}

/// Get the last Expression from a list of Statements.
fn last_expression(
  stmts: List(glance.Statement),
) -> Result(glance.Expression, Nil) {
  case list.last(stmts) {
    Ok(glance.Expression(expr)) -> Ok(expr)
    _ -> Error(Nil)
  }
}

/// Check if an expression constructs a new value (not just passing through the variable).
fn expression_constructs_new(
  expr: glance.Expression,
  model_param: String,
) -> Bool {
  case expr {
    // Variable reference to model → unchanged
    glance.Variable(name: name, ..) if name == model_param -> False
    // Anything else (constructor, function call, etc.) → new value
    _ -> True
  }
}

// ===== Purity Validation =====
// Walks the Glance AST to verify a module is safe to compile to JavaScript.
// No regex — all checks are proper AST analysis.

/// A purity violation found during AST analysis.
pub type PurityError {
  /// Module imports a server-only module.
  ServerImport(module_path: String)
  /// Function has @external(erlang, ...) annotation.
  ErlangExternal(function_name: String)
  /// Client-visible update calls a server-only or nondeterministic API.
  UpdateSideEffect(call: String)
  /// Client-visible update is hidden behind a factory that captures server state.
  CapturedUpdateFactory(function_name: String)
}

/// Validate that a source module is pure Gleam (safe to compile to JS).
/// Walks the Glance AST — no regex, no string matching on source.
///
/// Returns Ok(Nil) if the module is pure, or Error with a clear message.
pub fn validate_purity(source: String) -> Result(Nil, String) {
  use module <- result.try(parse("app module", source))
  case find_purity_errors(module) {
    [] -> Ok(Nil)
    errors -> Error(format_purity_errors(errors))
  }
}

/// Validate the client-visible update contract.
///
/// `update` must be pure enough to run in the browser. Server work such as
/// stores, PubSub, HTTP, env reads, FFI, process APIs, and random values belongs
/// in `on_update`.
pub fn validate_client_update_purity(source: String) -> Result(Nil, String) {
  use module <- result.try(parse("app module", source))
  case client_update_purity_errors(module) {
    [] -> Ok(Nil)
    errors -> Error(format_purity_errors(errors))
  }
}

/// Return client-visible update purity violations without formatting.
pub fn client_update_purity_errors(module: glance.Module) -> List(PurityError) {
  let names = effect_names(module)
  let update_errors = case find_function(module, "update") {
    Ok(func) -> function_body_side_effects(func.body, names)
    // An app without a direct `update` has no client-visible update to check.
    Error(_) -> []
  }
  let factory_errors =
    list.filter_map(module.functions, fn(def) {
      let func = def.definition
      case func.name == "make_update" && !list.is_empty(func.parameters) {
        True -> Ok(CapturedUpdateFactory(function_name: "make_update"))
        False -> Error(Nil)
      }
    })
  list.append(update_errors, factory_errors)
}

/// Walk the AST and collect all purity violations.
fn find_purity_errors(module: glance.Module) -> List(PurityError) {
  let import_errors = check_imports(module)
  let external_errors = check_externals(module)
  list.append(import_errors, external_errors)
}

/// Check all imports for server-only modules.
fn check_imports(module: glance.Module) -> List(PurityError) {
  list.filter_map(module.imports, fn(def) {
    let import_ = def.definition
    case is_server_only_import(import_.module) {
      True -> Ok(ServerImport(module_path: import_.module))
      False -> Error(Nil)
    }
  })
}

/// Check if an import is safe for JS compilation.
/// Uses an allowlist — only known-pure modules are kept.
fn is_server_only_import(module_path: String) -> Bool {
  !is_safe_import(module_path)
}

/// Allowlist of imports safe for JS compilation.
fn is_safe_import(module_path: String) -> Bool {
  // Known server-only modules — explicit blocklist
  case is_known_server_import(module_path) {
    True -> False
    False ->
      // beacon framework modules that are pure Gleam
      module_path == "beacon"
      || module_path == "beacon/html"
      || module_path == "beacon/element"
      || module_path == "beacon/route"
      || module_path == "beacon/log"
      // gleam stdlib — all pure (except erlang/otp, caught above)
      || string.starts_with(module_path, "gleam/")
      // User domain modules — assumed pure (will be validated individually)
      || is_user_module(module_path)
  }
}

/// Check if a module path is a known server-only import.
fn is_known_server_import(module_path: String) -> Bool {
  string.starts_with(module_path, "gleam/erlang")
  || string.starts_with(module_path, "gleam/otp")
  || string.starts_with(module_path, "gleam/http")
  || module_path == "mist"
  || string.starts_with(module_path, "mist/")
  || module_path == "envoy"
  || string.starts_with(module_path, "glean/")
  || {
    string.starts_with(module_path, "beacon/")
    && module_path != "beacon/html"
    && module_path != "beacon/element"
    && module_path != "beacon/route"
    && module_path != "beacon/log"
  }
}

/// Check if a module path looks like a user-defined module.
/// User modules don't start with known framework/stdlib prefixes.
fn is_user_module(module_path: String) -> Bool {
  !string.starts_with(module_path, "gleam/")
  && !string.starts_with(module_path, "beacon")
  && !string.starts_with(module_path, "mist")
  && !string.starts_with(module_path, "wisp")
  && !string.starts_with(module_path, "simplifile")
  && !string.starts_with(module_path, "glance")
}

/// Check all function definitions for @external(erlang, ...) annotations.
fn check_externals(module: glance.Module) -> List(PurityError) {
  list.filter_map(module.functions, fn(def) {
    let has_erlang_external =
      list.any(def.attributes, fn(attr) {
        case attr {
          glance.Attribute(name: "external", arguments: [first, ..]) ->
            is_erlang_target(first)
          _ -> False
        }
      })
    case has_erlang_external {
      True -> Ok(ErlangExternal(function_name: def.definition.name))
      False -> Error(Nil)
    }
  })
}

fn erlang_external_function_names(module: glance.Module) -> List(String) {
  list.filter_map(module.functions, fn(def) {
    let has_erlang_external =
      list.any(def.attributes, fn(attr) {
        case attr {
          glance.Attribute(name: "external", arguments: [first, ..]) ->
            is_erlang_target(first)
          _ -> False
        }
      })
    case has_erlang_external {
      True -> Ok(def.definition.name)
      False -> Error(Nil)
    }
  })
}

/// Names through which an update function can reach a side-effecting API.
type EffectNames {
  EffectNames(
    /// #(local alias, module path) of imported side-effect modules.
    aliases: List(#(String, String)),
    /// Functions defined in this module with `@external(erlang, ...)`.
    external_names: List(String),
    /// #(local name, "module.name") of values imported unqualified from
    /// side-effect modules, e.g. `import beacon/store.{put}`.
    unqualified: List(#(String, String)),
  )
}

fn effect_names(module: glance.Module) -> EffectNames {
  EffectNames(
    aliases: side_effect_import_aliases(module),
    external_names: erlang_external_function_names(module),
    unqualified: side_effect_unqualified_values(module),
  )
}

/// Imported side-effect modules and the alias they are referenced by. An
/// import discarded with `as _name` cannot be referenced, so it has no alias.
fn side_effect_import_aliases(
  module: glance.Module,
) -> List(#(String, String)) {
  list.filter_map(module.imports, fn(def) {
    let import_ = def.definition
    case is_update_side_effect_module(import_.module), import_.alias {
      False, _ -> Error(Nil)
      True, option.Some(glance.Discarded(_)) -> Error(Nil)
      True, option.Some(glance.Named(name)) -> Ok(#(name, import_.module))
      True, option.None ->
        Ok(#(module_short_name(import_.module), import_.module))
    }
  })
}

fn side_effect_unqualified_values(
  module: glance.Module,
) -> List(#(String, String)) {
  list.flat_map(module.imports, fn(def) {
    let import_ = def.definition
    case is_update_side_effect_module(import_.module) {
      False -> []
      True ->
        list.map(import_.unqualified_values, fn(value) {
          let local = option.unwrap(value.alias, value.name)
          #(local, import_.module <> "." <> value.name)
        })
    }
  })
}

fn module_short_name(module_path: String) -> String {
  case string.split(module_path, "/") |> list.last {
    Ok(name) -> name
    Error(_) -> module_path
  }
}

fn is_update_side_effect_module(module_path: String) -> Bool {
  module_path == "beacon/store"
  || module_path == "beacon/pubsub"
  || module_path == "beacon/config"
  || string.starts_with(module_path, "beacon/transport")
  || string.starts_with(module_path, "gleam/http")
  || string.starts_with(module_path, "gleam/erlang")
  || string.starts_with(module_path, "gleam/otp")
  || module_path == "envoy"
  || module_path == "mist"
  || string.starts_with(module_path, "mist/")
  || string.starts_with(module_path, "glean/")
}

fn function_body_side_effects(
  body: List(glance.Statement),
  names: EffectNames,
) -> List(PurityError) {
  body
  |> list.flat_map(statement_side_effects(_, names))
  |> unique_purity_errors
}

fn statement_side_effects(
  statement: glance.Statement,
  names: EffectNames,
) -> List(PurityError) {
  case statement {
    glance.Expression(expr) -> expression_side_effects(expr, names)
    glance.Assignment(value:, kind:, ..) ->
      list.append(expression_side_effects(value, names), case kind {
        glance.LetAssert(message: option.Some(message)) ->
          expression_side_effects(message, names)
        glance.LetAssert(message: option.None) | glance.Let -> []
      })
    glance.Use(function:, ..) -> expression_side_effects(function, names)
    glance.Assert(expression:, message:, ..) ->
      list.append(
        expression_side_effects(expression, names),
        optional_side_effects(message, names),
      )
  }
}

fn optional_side_effects(
  expr: option.Option(glance.Expression),
  names: EffectNames,
) -> List(PurityError) {
  case expr {
    option.Some(inner) -> expression_side_effects(inner, names)
    option.None -> []
  }
}

fn field_side_effects(
  fields: List(glance.Field(glance.Expression)),
  names: EffectNames,
) -> List(PurityError) {
  list.flat_map(fields, fn(field) {
    case field {
      glance.LabelledField(item: value, ..)
      | glance.UnlabelledField(item: value) ->
        expression_side_effects(value, names)
      glance.ShorthandField(..) -> []
    }
  })
}

/// Walk every sub-expression. Every expression form is listed so a new
/// glance variant is a compile error here rather than a silent gap.
fn expression_side_effects(
  expr: glance.Expression,
  names: EffectNames,
) -> List(PurityError) {
  case expr {
    glance.Call(function:, arguments:, ..) ->
      list.flatten([
        call_side_effect(function, names),
        expression_side_effects(function, names),
        field_side_effects(arguments, names),
      ])
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      list.flatten([
        call_side_effect(function, names),
        expression_side_effects(function, names),
        field_side_effects(arguments_before, names),
        field_side_effects(arguments_after, names),
      ])
    glance.BinaryOperator(name: glance.Pipe, left:, right:, ..) ->
      list.flatten([
        expression_side_effects(left, names),
        // `x |> store.put` calls the right-hand side.
        call_side_effect(right, names),
        expression_side_effects(right, names),
      ])
    glance.BinaryOperator(left:, right:, ..) ->
      list.append(
        expression_side_effects(left, names),
        expression_side_effects(right, names),
      )
    glance.Block(statements:, ..) | glance.Fn(body: statements, ..) ->
      list.flat_map(statements, statement_side_effects(_, names))
    glance.Case(subjects:, clauses:, ..) ->
      list.append(
        list.flat_map(subjects, expression_side_effects(_, names)),
        list.flat_map(clauses, fn(clause) {
          list.append(
            optional_side_effects(clause.guard, names),
            expression_side_effects(clause.body, names),
          )
        }),
      )
    glance.List(elements:, rest:, ..) ->
      list.append(
        list.flat_map(elements, expression_side_effects(_, names)),
        optional_side_effects(rest, names),
      )
    glance.Tuple(elements:, ..) ->
      list.flat_map(elements, expression_side_effects(_, names))
    glance.RecordUpdate(record:, fields:, ..) ->
      list.append(
        expression_side_effects(record, names),
        list.flat_map(fields, fn(field) {
          optional_side_effects(field.item, names)
        }),
      )
    glance.FieldAccess(container: inner, ..)
    | glance.TupleIndex(tuple: inner, ..)
    | glance.NegateInt(value: inner, ..)
    | glance.NegateBool(value: inner, ..) ->
      expression_side_effects(inner, names)
    glance.BitString(segments:, ..) ->
      list.flat_map(segments, fn(segment) {
        list.append(
          expression_side_effects(segment.0, names),
          list.flat_map(segment.1, fn(option) {
            case option {
              glance.SizeValueOption(size) ->
                expression_side_effects(size, names)
              _ -> []
            }
          }),
        )
      })
    glance.Echo(expression:, message:, ..) ->
      list.append(
        optional_side_effects(expression, names),
        optional_side_effects(message, names),
      )
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      optional_side_effects(message, names)
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> []
  }
}

/// The side effect of calling `func`, if it names a side-effecting API.
fn call_side_effect(
  func: glance.Expression,
  names: EffectNames,
) -> List(PurityError) {
  case func {
    glance.FieldAccess(
      container: glance.Variable(name: alias, ..),
      label: call_name,
      ..,
    ) -> {
      let module_error = case
        list.find(names.aliases, fn(item) { item.0 == alias })
      {
        Ok(#(_, module_path)) -> [
          UpdateSideEffect(alias <> "." <> call_name <> " from " <> module_path),
        ]
        Error(Nil) -> []
      }
      let random_error = case is_random_call(alias, call_name) {
        True -> [UpdateSideEffect(alias <> "." <> call_name)]
        False -> []
      }
      list.append(module_error, random_error)
    }
    glance.Variable(name:, ..) -> {
      let external_error = case list.contains(names.external_names, name) {
        True -> [UpdateSideEffect(name <> " external FFI")]
        False -> []
      }
      let unqualified_error = case
        list.find(names.unqualified, fn(item) { item.0 == name })
      {
        Ok(#(_, qualified)) -> [
          UpdateSideEffect(name <> " (imported " <> qualified <> ")"),
        ]
        Error(Nil) -> []
      }
      list.append(external_error, unqualified_error)
    }
    _ -> []
  }
}

fn is_random_call(alias: String, call_name: String) -> Bool {
  { alias == "int" || alias == "float" || alias == "list" }
  && string.contains(call_name, "random")
}

fn unique_purity_errors(errors: List(PurityError)) -> List(PurityError) {
  errors
  |> list.fold([], fn(acc, err) {
    case list.contains(list.map(acc, purity_error_key), purity_error_key(err)) {
      True -> acc
      False -> [err, ..acc]
    }
  })
  |> list.reverse
}

fn purity_error_key(err: PurityError) -> String {
  case err {
    ServerImport(module_path) -> "import:" <> module_path
    ErlangExternal(function_name) -> "external:" <> function_name
    UpdateSideEffect(call) -> "update:" <> call
    CapturedUpdateFactory(function_name) -> "factory:" <> function_name
  }
}

/// Check if an expression represents the "erlang" target atom.
fn is_erlang_target(expr: glance.Expression) -> Bool {
  case expr {
    glance.Variable(name: "erlang", ..) -> True
    glance.String(value: "erlang", ..) -> True
    _ -> False
  }
}

/// Format purity errors into a clear, actionable message.
fn format_purity_errors(errors: List(PurityError)) -> String {
  let messages =
    list.map(errors, fn(err) {
      case err {
        ServerImport(path) -> "  - imports server-only module '" <> path <> "'"
        ErlangExternal(name) ->
          "  - function '" <> name <> "' has @external(erlang, ...) annotation"
        UpdateSideEffect(call) ->
          "  - client-visible update calls '"
          <> call
          <> "'; move this to on_update."
        CapturedUpdateFactory(name) ->
          "  - client-visible "
          <> name
          <> "(...) captures server state; move this to on_update."
      }
    })
  "Module is not pure Gleam (cannot compile to JS for LOCAL events):\n"
  <> string.join(messages, "\n")
  <> "\n\nTo fix: move server-only code (stores, effects, PubSub) to on_update()."
}

// ===== AST Extraction + Source Emission =====
// Extracts pure types/functions from user source using Glance AST byte offsets.
// No source reconstruction — slices original source text using Span positions.
// This preserves exact formatting and is reliable without glance_printer.

/// Names of server-only functions to skip during extraction.
/// For state-over-the-wire, the client only needs view + types + helpers.
/// update runs on the server — not compiled to JS.
const server_only_functions = [
  "start", "main", "on_update", "make_update", "make_init", "make_on_update",
  "init_server", "update_server",
]

/// Return True when a source module contains server-only declarations that
/// require client extraction before the module can be copied into a JS build.
pub fn has_server_boundary(source: String) -> Result(Bool, String) {
  use module <- result.map(parse("app module", source))
  list.any(module.custom_types, fn(def) { def.definition.name == "Server" })
  || list.any(module.functions, fn(def) {
    def.definition.name == "init_server"
    || def.definition.name == "update_server"
  })
  || list.any(module.constants, fn(def) {
    string.starts_with(def.definition.name, "server_")
  })
}

/// Names of functions that MUST be extracted even if they reference server code.
/// view is always needed. init/init_local may fail to compile if they use
/// server-only code — the entry point generates stubs for those.
const always_extract_functions = ["view", "init_local"]

/// Extract pure client code from a source module.
/// Returns the extracted Gleam source string containing only:
/// - Safe imports (beacon, beacon/html, beacon/element, gleam/*)
/// - All type definitions (Model, Local, Msg, custom types)
/// - Pure functions (init, init_local, update, view, helpers)
///
/// Skips: server-only imports, @external(erlang) functions, start/main/on_update.
/// The source must pass validate_purity() first.
pub fn extract_client_source(source: String) -> Result(String, String) {
  extract_client_source_with_update(source, True)
}

pub fn extract_client_source_for_bundle(
  source: String,
  include_update: Bool,
) -> Result(String, String) {
  extract_client_source_with_update(source, include_update)
}

fn extract_client_source_with_update(
  source: String,
  include_update: Bool,
) -> Result(String, String) {
  case parse("client module", source) {
    Error(reason) -> Error(reason)
    Ok(module) -> {
      let source_bytes = string_to_bytes(source)

      // Collect all type definitions (Model, Local, Msg, custom types)
      // Exclude Server/ServerState types — private server-side state is never
      // sent to client bundles or codecs.
      let client_types =
        list.filter(module.custom_types, fn(def) {
          def.definition.name != "Server"
          && def.definition.name != "ServerState"
        })
      let type_texts =
        list.map(client_types, fn(def) {
          slice_source(source_bytes, def.definition.location)
        })

      // Collect type aliases
      let alias_texts =
        list.map(module.type_aliases, fn(def) {
          slice_source(source_bytes, def.definition.location)
        })
      let type_refs =
        list.fold(module.type_aliases, ast_refs.empty(), fn(acc, def) {
          ast_refs.type_alias(acc, def.definition)
        })
      let type_refs =
        list.fold(client_types, type_refs, fn(acc, def) {
          ast_refs.custom_type(acc, def.definition)
        })

      // Collect pure functions (skip server-only, skip @external(erlang),
      // skip functions that reference server-only APIs in their body)
      let function_candidates =
        list.filter_map(module.functions, fn(def) {
          let func = def.definition
          // Skip server-only functions by name
          case !include_update && func.name == "update" {
            True -> Error(Nil)
            False -> {
              case list.contains(server_only_functions, func.name) {
                True -> Error(Nil)
                False -> {
                  let func_text = slice_source(source_bytes, func.location)
                  let is_public = case func.publicity {
                    glance.Public -> True
                    _ -> False
                  }
                  // Always extract view/init/init_local — client needs them
                  case list.contains(always_extract_functions, func.name) {
                    True -> Ok(#(func.name, is_public, func_text, func))
                    False -> {
                      // Skip computed fields — pub fn(Model) -> T (not Node return)
                      let is_computed = case func.publicity, func.parameters {
                        glance.Public,
                          [
                            glance.FunctionParameter(
                              type_: option.Some(glance.NamedType(
                                name: "Model",
                                ..,
                              )),
                              ..,
                            ),
                          ]
                        ->
                          case func.return {
                            option.Some(glance.NamedType(name: "Node", ..)) ->
                              False
                            _ -> True
                          }
                        _, _ -> False
                      }
                      case is_computed {
                        True -> Error(Nil)
                        False -> {
                          // Skip functions with @external(erlang) annotations
                          let has_erlang_external =
                            list.any(def.attributes, fn(attr) {
                              case attr {
                                glance.Attribute(
                                  name: "external",
                                  arguments: [first, ..],
                                ) -> is_erlang_target(first)
                                _ -> False
                              }
                            })
                          case has_erlang_external {
                            True -> Error(Nil)
                            False ->
                              // Skip if the body references server-only modules
                              case function_references_server_code(func_text) {
                                True -> Error(Nil)
                                False ->
                                  Ok(#(func.name, is_public, func_text, func))
                              }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        })

      let candidate_refs =
        list.map(function_candidates, fn(candidate) {
          let #(name, is_public, text, func) = candidate
          #(name, is_public, text, ast_refs.function(ast_refs.empty(), func))
        })
      let kept_functions = reachable_functions(candidate_refs)
      let function_texts =
        list.filter_map(candidate_refs, fn(candidate) {
          case set.contains(kept_functions, candidate.0) {
            True -> Ok(candidate.2)
            False -> Error(Nil)
          }
        })
      let function_refs =
        list.fold(candidate_refs, ast_refs.empty(), fn(acc, candidate) {
          case set.contains(kept_functions, candidate.0) {
            True -> ast_refs.merge(acc, candidate.3)
            False -> acc
          }
        })

      // Collect constants — filtered to prevent leaking server-side secrets.
      // Rules (in order):
      // 1. Skip if constant name starts with "server_" (server-only by convention)
      // 2. Skip if constant body references server-only modules
      // 3. Skip if no extracted function (or kept constant) refers to it
      let constant_candidates =
        list.filter_map(module.constants, fn(def) {
          let constant = def.definition
          case string.starts_with(constant.name, "server_") {
            True -> Error(Nil)
            False -> {
              let text = slice_source(source_bytes, constant.location)
              case function_references_server_code(text) {
                True -> Error(Nil)
                False ->
                  Ok(#(
                    constant.name,
                    text,
                    ast_refs.constant(ast_refs.empty(), constant),
                  ))
              }
            }
          }
        })
      let kept_constants =
        reachable_constants(function_refs, constant_candidates)
      let constant_texts =
        list.filter_map(constant_candidates, fn(candidate) {
          case set.contains(kept_constants, candidate.0) {
            True -> Ok(candidate.1)
            False -> Error(Nil)
          }
        })

      let body_refs =
        constant_candidates
        |> list.filter(fn(candidate) {
          set.contains(kept_constants, candidate.0)
        })
        |> list.fold(ast_refs.merge(type_refs, function_refs), fn(acc, c) {
          ast_refs.merge(acc, c.2)
        })

      // Keep the safe imports the extracted client code still refers to.
      // Server-only functions are stripped above, so their imports must not
      // keep server graphs reachable in the generated JS project.
      let import_texts =
        list.filter_map(module.imports, fn(def) {
          let import_ = def.definition
          case
            is_server_only_import(import_.module)
            || !ast_refs.uses_import(body_refs, import_)
          {
            True -> Error(Nil)
            False -> Ok(slice_source(source_bytes, import_.location))
          }
        })

      // Assemble the client module
      let parts =
        list.flatten([
          import_texts,
          [""],
          type_texts,
          alias_texts,
          [""],
          constant_texts,
          [""],
          function_texts,
        ])
        |> list.filter(fn(s) { !string.is_empty(string.trim(s)) })

      Ok(string.join(parts, "\n\n"))
    }
  }
}

/// Public candidates plus every private candidate they reach.
fn reachable_functions(
  candidates: List(#(String, Bool, String, ast_refs.Refs)),
) -> Set(String) {
  let roots =
    candidates
    |> list.filter(fn(candidate) { candidate.1 })
    |> list.map(fn(candidate) { candidate.0 })
  reach(set.from_list(roots), roots, fn(name) {
    case list.find(candidates, fn(candidate) { candidate.0 == name }) {
      Ok(candidate) ->
        list.filter_map(candidates, fn(other) {
          case set.contains(candidate.3.names, other.0) {
            True -> Ok(other.0)
            False -> Error(Nil)
          }
        })
      Error(Nil) -> []
    }
  })
}

/// Constants referenced by kept functions, plus the constants they reach.
fn reachable_constants(
  function_refs: ast_refs.Refs,
  candidates: List(#(String, String, ast_refs.Refs)),
) -> Set(String) {
  let refers = fn(refs: ast_refs.Refs) {
    list.filter_map(candidates, fn(candidate) {
      case set.contains(refs.names, candidate.0) {
        True -> Ok(candidate.0)
        False -> Error(Nil)
      }
    })
  }
  let roots = refers(function_refs)
  reach(set.from_list(roots), roots, fn(name) {
    case list.find(candidates, fn(candidate) { candidate.0 == name }) {
      Ok(candidate) -> refers(candidate.2)
      Error(Nil) -> []
    }
  })
}

fn reach(
  seen: Set(String),
  pending: List(String),
  next: fn(String) -> List(String),
) -> Set(String) {
  case pending {
    [] -> seen
    [name, ..rest] -> {
      let fresh = list.filter(next(name), fn(n) { !set.contains(seen, n) })
      reach(list.fold(fresh, seen, set.insert), list.append(rest, fresh), next)
    }
  }
}

fn function_references_server_code(func_text: String) -> Bool {
  // Check for common server-only module references
  string.contains(func_text, "store.")
  || string.contains(func_text, "effect.")
  || string.contains(func_text, "pubsub.")
  || string.contains(func_text, "debug.")
  || string.contains(func_text, "process.")
  || string.contains(func_text, "mist.")
  || string.contains(func_text, "request.")
  || string.contains(func_text, "response.")
  || string.contains(func_text, "middleware.")
  || string.contains(func_text, "Server(")
  || string.contains(func_text, ": Server")
  || string.contains(func_text, "server: Server")
  || string.contains(func_text, "ServerState")
  || string.contains(func_text, "beacon_route.Page")
  || string.contains(func_text, "bytes_tree.")
  || string.contains(func_text, "message.user(")
  || string.contains(func_text, "message.assistant(")
  || string.contains(func_text, "agent.new(")
  || string.contains(func_text, "run.generate(")
  || string.contains(func_text, "run.stream(")
  || string.contains(func_text, "envoy.get(")
  || string.contains(func_text, "openrouter.")
  || string.contains(func_text, "Agent(")
  // Known server-only function calls
  || string.contains(func_text, "unique_int(")
  || string.contains(func_text, "abs_int(")
  || string.contains(func_text, "timer.sleep")
  || string.contains(func_text, "sleep(")
}

/// Slice a portion of the source using byte offsets from a Span.
fn slice_source(source_bytes: List(Int), span: glance.Span) -> String {
  let glance.Span(start: start, end: end) = span
  source_bytes
  |> list.drop(start)
  |> list.take(end - start)
  |> bytes_to_string()
}

/// Convert a string to a list of byte values.
/// We need this because Glance Span uses byte offsets, not character offsets.
@external(erlang, "beacon_build_ffi", "string_to_bytes")
fn string_to_bytes(s: String) -> List(Int)

/// Convert a list of byte values back to a string.
@external(erlang, "beacon_build_ffi", "bytes_to_string")
fn bytes_to_string(bytes: List(Int)) -> String
