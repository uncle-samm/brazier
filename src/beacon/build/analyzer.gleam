/// Glance-based code analyzer for the build tool.
/// Parses user source code and classifies Msg variants.
/// Also validates purity and extracts pure code for JS compilation.
import beacon/log
import glance
import gleam/int
import gleam/list
import gleam/option
import gleam/string

/// A field in a Model or Local type.
pub type TypeField {
  TypeField(
    /// The field name (e.g., "count").
    name: String,
    /// The field type name (e.g., "Int", "String", "Bool", "List").
    type_name: String,
    /// For generic types like List(Stroke), the inner type name.
    inner_type: String,
    /// Module qualifier for the type (e.g., "auth" for auth.AuthState). Empty = local.
    module: String,
    /// Module qualifier for the inner type (e.g., "card" for List(card.Card)). Empty = local.
    inner_module: String,
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
    /// The return type name (e.g., "Int", "String", "Float", "Bool").
    return_type: String,
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
    /// Variants carried by this Msg type.
    variants: List(MsgVariant),
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
    /// All Msg type variants with their classification.
    msg_variants: List(MsgVariant),
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

/// Analyze a Gleam source string.
/// Returns the Msg variants with model-impact classification.
pub fn analyze(source: String) -> Result(Analysis, String) {
  case glance.module(source) {
    Ok(module) -> {
      // Find Msg type
      let msg_type = find_custom_type(module, "Msg")
      // Find update function (try "update" first, then "make_update")
      let has_direct_init = case find_function(module, "init") {
        Ok(_) -> True
        Error(_) -> False
      }
      let has_direct_update = case find_function(module, "update") {
        Ok(_) -> True
        Error(_) -> False
      }
      let has_direct_view = case find_function(module, "view") {
        Ok(_) -> True
        Error(_) -> False
      }
      let update_fn = case find_function(module, "update") {
        Ok(f) -> Ok(f)
        Error(_) -> find_function(module, "make_update")
      }
      // Check for Local type
      let #(has_local, local_fields) = case find_custom_type(module, "Local") {
        Ok(local_type) -> #(True, extract_fields(local_type))
        Error(_) -> #(False, [])
      }

      // Check for Server type (private server-side state)
      let #(has_server, server_module_alias, server_type_name, server_fields) = case
        find_custom_type(module, "Server")
      {
        Ok(server_type) -> #(True, "", "Server", extract_fields(server_type))
        Error(_) -> #(False, "", "Server", [])
      }

      // Extract Model fields for JSON codec generation
      let #(has_model, model_fields) = case find_custom_type(module, "Model") {
        Ok(model_type) -> #(True, extract_fields(model_type))
        Error(_) -> {
          log.debug(
            "beacon.analyzer",
            "No Model type found — this module may not be an app component",
          )
          #(False, [])
        }
      }

      // Extract ALL custom types for nested decoder generation
      let custom_types =
        list.filter_map(module.custom_types, fn(def) {
          let name = def.definition.name
          // Skip Model, Local, Msg, Server — we handle those specially
          case
            name == "Model"
            || name == "Local"
            || name == "Msg"
            || name == "Server"
          {
            True -> Error(Nil)
            False -> {
              let fields = extract_fields(def.definition)
              case fields {
                [] -> Error(Nil)
                _ -> Ok(CustomTypeInfo(name: name, fields: fields, module: ""))
              }
            }
          }
        })

      // Extract enum types (multiple variants, no fields — e.g., Column { Todo; Doing; Done })
      let enum_types =
        list.filter_map(module.custom_types, fn(def) {
          let ct = def.definition
          // Skip Model, Local, Msg
          case ct.name == "Model" || ct.name == "Local" || ct.name == "Msg" {
            True -> Error(Nil)
            False -> {
              // An enum type has multiple variants, ALL with zero fields
              let all_fieldless =
                list.all(ct.variants, fn(v) { list.is_empty(v.fields) })
              case all_fieldless && list.length(ct.variants) >= 2 {
                True -> {
                  let variant_names = list.map(ct.variants, fn(v) { v.name })
                  Ok(EnumTypeInfo(
                    name: ct.name,
                    variants: variant_names,
                    module: "",
                  ))
                }
                False -> Error(Nil)
              }
            }
          }
        })

      // Detect substates: Model fields whose types are custom record types.
      // These are tracked independently for efficient per-substate diffing.
      let substates =
        list.filter_map(model_fields, fn(f) {
          case f.type_name {
            "List" ->
              case
                list.find(custom_types, fn(ct) {
                  ct.name == f.inner_type && ct.module == f.inner_module
                })
              {
                Ok(_) ->
                  Ok(SubstateInfo(
                    field_name: f.name,
                    type_name: f.inner_type,
                    is_list: True,
                    module: f.inner_module,
                  ))
                Error(_) -> Error(Nil)
              }
            _ ->
              case
                list.find(custom_types, fn(ct) {
                  ct.name == f.type_name && ct.module == f.module
                })
              {
                Ok(_) ->
                  Ok(SubstateInfo(
                    field_name: f.name,
                    type_name: f.type_name,
                    is_list: False,
                    module: f.module,
                  ))
                Error(_) -> Error(Nil)
              }
          }
        })

      // Detect computed fields — pub fn that takes exactly 1 param of type Model
      // and returns a known type. Excludes view (returns Node), update (takes 2+ params),
      // init (takes 0 params), and server_only_functions.
      let computed_excluded = [
        "view",
        "init",
        "init_local",
        "init_server",
        "update",
        "start",
        "main",
        "on_update",
        "make_update",
        "make_init",
        "make_on_update",
      ]
      let computed_fields =
        list.filter_map(module.functions, fn(def) {
          let func = def.definition
          // Must be public
          case func.publicity {
            glance.Public -> {
              // Must not be in excluded list
              case list.contains(computed_excluded, func.name) {
                True -> Error(Nil)
                False -> {
                  // Must take exactly 1 parameter of type Model
                  case func.parameters {
                    [
                      glance.FunctionParameter(
                        type_: option.Some(glance.NamedType(name: "Model", ..)),
                        ..,
                      ),
                    ] -> {
                      // Extract return type — must not be Node (that's view)
                      let return_type = case func.return {
                        option.Some(glance.NamedType(name: name, ..)) ->
                          case name {
                            // Node return = view-like, not computed
                            "Node" -> Error(Nil)
                            _ -> Ok(name)
                          }
                        _ -> Ok("String")
                      }
                      case return_type {
                        Ok(rt) ->
                          Ok(ComputedField(name: func.name, return_type: rt))
                        Error(Nil) -> Error(Nil)
                      }
                    }
                    _ -> Error(Nil)
                  }
                }
              }
            }
            _ -> Error(Nil)
          }
        })

      // Classify Msg variants if both Msg type and update function are present.
      // When either is missing (multi-file apps where Msg/update are in separate files),
      // succeed with empty msg_variants — the codec only needs Model fields.
      let variants = case msg_type, update_fn {
        Ok(msg), Ok(func) -> classify_variants(msg, func, has_local)
        _, _ -> {
          log.debug(
            "beacon.analyzer",
            "No Msg type or update function in this file — codec-only analysis",
          )
          []
        }
      }
      let client_variants = case find_custom_type(module, "ClientMsg") {
        Ok(client_msg) -> variants_from_msg_type(client_msg)
        Error(_) -> []
      }
      Ok(
        Analysis(
          has_model: has_model,
          model_module: "",
          model_type_name: "Model",
          msg_variants: variants,
          msg_module: "",
          msg_type_name: "Msg",
          client_msg_variants: client_variants,
          has_local: has_local,
          local_module: "",
          local_type_name: "Local",
          local_fields: local_fields,
          has_server: has_server,
          server_module: server_module_alias,
          server_type_name: server_type_name,
          server_fields: server_fields,
          model_fields: model_fields,
          has_direct_init: has_direct_init,
          has_direct_update: has_direct_update,
          has_direct_view: has_direct_view,
          custom_types: custom_types,
          enum_types: enum_types,
          substates: substates,
          computed_fields: computed_fields,
          imported_modules: [],
          external_msg_types: [],
        ),
      )
    }
    Error(_) -> Error("Failed to parse source")
  }
}

/// Analyze a multi-file app: main source + external module sources.
/// Each external source is a #(alias, module_path, source_text) triple where:
/// - alias is the module qualifier (e.g., "auth" for `import domains/auth`)
/// - module_path is the import path (e.g., "domains/auth")
/// - source_text is the file contents
/// Extracts types from external modules and merges them into the analysis.
pub fn analyze_multi(
  source: String,
  external_sources: List(#(String, String, String)),
) -> Result(Analysis, String) {
  case analyze(source) {
    Error(reason) -> Error(reason)
    Ok(analysis) -> {
      // Parse each external source and extract types tagged with the module alias
      let #(ext_custom_types, ext_enum_types, imported_modules, ext_msg_types) =
        list.fold(external_sources, #([], [], [], []), fn(acc, ext) {
          let #(alias, module_path, ext_source) = ext
          case glance.module(ext_source) {
            Error(_) -> acc
            Ok(ext_module) -> {
              let #(cts, ets, ims, msgs) = acc
              let im = ImportedModule(module_path: module_path, alias: alias)
              let ext_cts =
                list.filter_map(ext_module.custom_types, fn(def) {
                  let ct = def.definition
                  // Skip non-public and server/message boundary types.
                  case ct.publicity {
                    glance.Public
                      if ct.name != "Msg"
                      && ct.name != "ClientMsg"
                      && ct.name != "Server"
                    -> {
                      let fields =
                        extract_fields(ct)
                        |> qualify_external_fields(alias)
                      case fields {
                        [] -> Error(Nil)
                        _ ->
                          Ok(CustomTypeInfo(
                            name: ct.name,
                            fields: fields,
                            module: alias,
                          ))
                      }
                    }
                    _ -> Error(Nil)
                  }
                })
              let ext_ets =
                list.filter_map(ext_module.custom_types, fn(def) {
                  let ct = def.definition
                  case ct.publicity {
                    glance.Public
                      if ct.name != "Msg"
                      && ct.name != "ClientMsg"
                      && ct.name != "Server"
                    -> {
                      let all_fieldless =
                        list.all(ct.variants, fn(v) { list.is_empty(v.fields) })
                      case all_fieldless && list.length(ct.variants) >= 2 {
                        True -> {
                          let variant_names =
                            list.map(ct.variants, fn(v) { v.name })
                          Ok(EnumTypeInfo(
                            name: ct.name,
                            variants: variant_names,
                            module: alias,
                          ))
                        }
                        False -> Error(Nil)
                      }
                    }
                    _ -> Error(Nil)
                  }
                })
              let ext_msgs = case find_custom_type(ext_module, "Msg") {
                Ok(msg_type) -> {
                  let update_fn = case find_function(ext_module, "update") {
                    Ok(func) -> Ok(func)
                    Error(_) -> find_function(ext_module, "make_update")
                  }
                  let variants = case
                    find_custom_type(ext_module, "ClientMsg")
                  {
                    Ok(client_msg) -> variants_from_msg_type(client_msg)
                    Error(_) ->
                      case analysis.client_msg_variants {
                        [_, ..] -> analysis.client_msg_variants
                        [] ->
                          case update_fn {
                            Ok(func) -> classify_variants(msg_type, func, False)
                            Error(_) -> variants_from_msg_type(msg_type)
                          }
                      }
                  }
                  [MsgTypeInfo(module: alias, variants: variants)]
                }
                Error(_) -> []
              }
              #(
                list.append(cts, ext_cts),
                list.append(ets, ext_ets),
                [im, ..ims],
                list.append(msgs, ext_msgs),
              )
            }
          }
        })

      // Merge external types into analysis
      let all_custom_types =
        list.append(analysis.custom_types, ext_custom_types)
      let all_enum_types = list.append(analysis.enum_types, ext_enum_types)

      let #(has_model, model_module_alias, model_type_name, model_fields) = case
        analysis.has_model
      {
        True -> #(
          True,
          analysis.model_module,
          analysis.model_type_name,
          analysis.model_fields,
        )
        False -> {
          let ext_model =
            list.find_map(external_sources, fn(ext) {
              let #(alias, _module_path, ext_source) = ext
              case glance.module(ext_source) {
                Error(_) -> Error(Nil)
                Ok(ext_module) -> {
                  case
                    list.find(ext_module.custom_types, fn(def) {
                      def.definition.name == "Model"
                      && def.definition.publicity == glance.Public
                    })
                  {
                    Ok(def) ->
                      Ok(#(
                        alias,
                        def.definition.name,
                        extract_fields(def.definition)
                          |> qualify_external_fields(alias),
                      ))
                    Error(Nil) -> Error(Nil)
                  }
                }
              }
            })
          case ext_model {
            Ok(#(alias, type_name, fields)) -> {
              log.info(
                "beacon.analyzer",
                "Found Model type in external module: " <> alias,
              )
              #(True, alias, type_name, fields)
            }
            Error(Nil) -> #(False, "", "Model", [])
          }
        }
      }

      let #(msg_variants, msg_module_alias, msg_type_name, client_msg_variants) = case
        analysis.msg_variants
      {
        [_, ..] -> #(
          analysis.msg_variants,
          analysis.msg_module,
          analysis.msg_type_name,
          analysis.client_msg_variants,
        )
        [] -> {
          let ext_msg =
            list.find_map(external_sources, fn(ext) {
              let #(alias, _module_path, ext_source) = ext
              case glance.module(ext_source) {
                Error(_) -> Error(Nil)
                Ok(ext_module) -> {
                  case find_custom_type(ext_module, "Msg") {
                    Ok(msg_type) -> {
                      let update_fn = case find_function(ext_module, "update") {
                        Ok(func) -> Ok(func)
                        Error(_) -> find_function(ext_module, "make_update")
                      }
                      let variants = case
                        find_custom_type(ext_module, "ClientMsg")
                      {
                        Ok(client_msg) -> variants_from_msg_type(client_msg)
                        Error(_) ->
                          case analysis.client_msg_variants {
                            [_, ..] -> analysis.client_msg_variants
                            [] ->
                              case update_fn {
                                Ok(func) ->
                                  classify_variants(
                                    msg_type,
                                    func,
                                    analysis.has_local,
                                  )
                                Error(_) -> variants_from_msg_type(msg_type)
                              }
                          }
                      }
                      let client_variants = case
                        find_custom_type(ext_module, "ClientMsg")
                      {
                        Ok(client_msg) -> variants_from_msg_type(client_msg)
                        Error(_) -> analysis.client_msg_variants
                      }
                      Ok(#(alias, msg_type.name, variants, client_variants))
                    }
                    Error(_) -> Error(Nil)
                  }
                }
              }
            })
          case ext_msg {
            Ok(#(alias, type_name, variants, client_variants)) -> {
              log.info(
                "beacon.analyzer",
                "Found Msg type in external module: " <> alias,
              )
              #(variants, alias, type_name, client_variants)
            }
            Error(Nil) -> #([], "", "Msg", [])
          }
        }
      }

      // Re-detect substates with the full type set (including external types)
      let substates =
        list.filter_map(model_fields, fn(f) {
          case f.type_name {
            "List" ->
              case
                list.find(all_custom_types, fn(ct) {
                  ct.name == f.inner_type && ct.module == f.inner_module
                })
              {
                Ok(_) ->
                  Ok(SubstateInfo(
                    field_name: f.name,
                    type_name: f.inner_type,
                    is_list: True,
                    module: f.inner_module,
                  ))
                Error(_) -> Error(Nil)
              }
            _ ->
              case
                list.find(all_custom_types, fn(ct) {
                  ct.name == f.type_name && ct.module == f.module
                })
              {
                Ok(_) ->
                  Ok(SubstateInfo(
                    field_name: f.name,
                    type_name: f.type_name,
                    is_list: False,
                    module: f.module,
                  ))
                Error(_) -> Error(Nil)
              }
          }
        })

      // Check external sources for Server type (multi-file apps may have it in a separate module)
      let #(has_server, server_module_alias, server_type_name, server_fields) = case
        analysis.has_server
      {
        True -> #(
          True,
          analysis.server_module,
          analysis.server_type_name,
          analysis.server_fields,
        )
        False -> {
          // Search external modules for a type named "Server" or "ServerState"
          let ext_server =
            list.find_map(external_sources, fn(ext) {
              let #(alias, _module_path, ext_source) = ext
              case glance.module(ext_source) {
                Error(_) -> Error(Nil)
                Ok(ext_module) -> {
                  // Look for Server or ServerState type
                  let server_type =
                    list.find(ext_module.custom_types, fn(def) {
                      let name = def.definition.name
                      { name == "Server" || name == "ServerState" }
                      && def.definition.publicity == glance.Public
                    })
                  case server_type {
                    Ok(def) ->
                      Ok(#(
                        alias,
                        def.definition.name,
                        extract_fields(def.definition),
                      ))
                    Error(Nil) -> Error(Nil)
                  }
                }
              }
            })
          case ext_server {
            Ok(#(srv_alias, srv_type_name, fields)) -> {
              log.info(
                "beacon.analyzer",
                "Found "
                  <> srv_type_name
                  <> " type in external module: "
                  <> srv_alias,
              )
              #(True, srv_alias, srv_type_name, fields)
            }
            Error(Nil) -> #(False, "", "Server", [])
          }
        }
      }

      // Check external sources for Local type (multi-file apps may keep Local
      // in a separate client-visible module).
      let #(has_local, local_module_alias, local_type_name, local_fields) = case
        analysis.has_local
      {
        True -> #(
          True,
          analysis.local_module,
          analysis.local_type_name,
          analysis.local_fields,
        )
        False -> {
          let ext_local =
            list.find_map(external_sources, fn(ext) {
              let #(alias, _module_path, ext_source) = ext
              case glance.module(ext_source) {
                Error(_) -> Error(Nil)
                Ok(ext_module) -> {
                  case
                    list.find(ext_module.custom_types, fn(def) {
                      def.definition.name == "Local"
                      && def.definition.publicity == glance.Public
                    })
                  {
                    Ok(def) ->
                      Ok(#(
                        alias,
                        def.definition.name,
                        extract_fields(def.definition)
                          |> qualify_external_fields(alias),
                      ))
                    Error(Nil) -> Error(Nil)
                  }
                }
              }
            })
          case ext_local {
            Ok(#(alias, type_name, fields)) -> #(True, alias, type_name, fields)
            Error(Nil) -> #(False, "", "Local", [])
          }
        }
      }

      let external_msg_types = case msg_module_alias {
        "" -> ext_msg_types
        alias -> list.filter(ext_msg_types, fn(info) { info.module != alias })
      }

      Ok(
        Analysis(
          ..analysis,
          has_model: has_model,
          model_module: model_module_alias,
          model_type_name: model_type_name,
          msg_variants: msg_variants,
          msg_module: msg_module_alias,
          msg_type_name: msg_type_name,
          client_msg_variants: client_msg_variants,
          has_local: has_local,
          local_module: local_module_alias,
          local_type_name: local_type_name,
          local_fields: local_fields,
          has_server: has_server,
          server_module: server_module_alias,
          server_type_name: server_type_name,
          server_fields: server_fields,
          model_fields: model_fields,
          custom_types: all_custom_types,
          enum_types: all_enum_types,
          substates: substates,
          imported_modules: imported_modules,
          external_msg_types: external_msg_types,
        ),
      )
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

/// Extract labelled fields from a custom type's first variant.
fn extract_fields(custom_type: glance.CustomType) -> List(TypeField) {
  case custom_type.variants {
    [variant, ..] ->
      list.filter_map(variant.fields, fn(field) {
        case field {
          glance.LabelledVariantField(item: field_type, label: name) -> {
            let #(type_name, inner, mod_val, inner_mod_val) =
              type_parts(field_type, name)
            Ok(TypeField(
              name: name,
              type_name: type_name,
              inner_type: inner,
              module: mod_val,
              inner_module: inner_mod_val,
            ))
          }
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

fn extract_variant_fields(variant: glance.Variant) -> List(TypeField) {
  variant.fields
  |> list.index_map(fn(field, idx) {
    let name = case field {
      glance.LabelledVariantField(label: label, ..) -> label
      glance.UnlabelledVariantField(..) -> "arg" <> int.to_string(idx)
    }
    let field_type = case field {
      glance.LabelledVariantField(item: item, ..) -> item
      glance.UnlabelledVariantField(item: item) -> item
    }
    let #(type_name, inner, mod_val, inner_mod_val) =
      type_parts(field_type, name)
    TypeField(
      name: name,
      type_name: type_name,
      inner_type: inner,
      module: mod_val,
      inner_module: inner_mod_val,
    )
  })
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
      fields: extract_variant_fields(variant),
      affects_model: affects_model,
      affects_local: affects_local,
    )
  })
}

fn variants_from_msg_type(msg_type: glance.CustomType) -> List(MsgVariant) {
  list.map(msg_type.variants, fn(variant) {
    MsgVariant(
      name: variant.name,
      fields: extract_variant_fields(variant),
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
pub fn client_contract_report(
  source: String,
  analysis: Analysis,
) -> List(String) {
  let skipped_imports = skipped_client_imports(source)
  let skipped_line = case skipped_imports {
    [] -> "Skipped client imports: none"
    _ -> "Skipped client imports: " <> string.join(skipped_imports, ", ")
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

fn skipped_client_imports(source: String) -> List(String) {
  case glance.module(source) {
    Error(_) -> ["<parse failed>"]
    Ok(module) ->
      list.filter_map(module.imports, fn(def) {
        let import_ = def.definition
        case is_server_only_import(import_.module) {
          True -> Ok(import_.module)
          False -> Error(Nil)
        }
      })
  }
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
  case glance.module(source) {
    Error(_) -> Error("Failed to parse source for purity validation")
    Ok(module) -> {
      let errors = find_purity_errors(module)
      case errors {
        [] -> Ok(Nil)
        _ -> Error(format_purity_errors(errors))
      }
    }
  }
}

/// Validate the client-visible update contract.
///
/// `update` must be pure enough to run in the browser. Server work such as
/// stores, PubSub, HTTP, env reads, FFI, process APIs, and random values belongs
/// in `on_update`.
pub fn validate_client_update_purity(source: String) -> Result(Nil, String) {
  case client_update_purity_errors(source) {
    [] -> Ok(Nil)
    errors -> Error(format_purity_errors(errors))
  }
}

/// Return client-visible update purity violations without formatting.
pub fn client_update_purity_errors(source: String) -> List(PurityError) {
  case glance.module(source) {
    Error(_) -> [UpdateSideEffect("failed to parse source for update purity")]
    Ok(module) -> {
      let aliases = side_effect_import_aliases(module)
      let external_names = erlang_external_function_names(module)
      let update_errors = case find_function(module, "update") {
        Ok(func) ->
          function_body_side_effects(func.body, aliases, external_names)
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
  }
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

fn side_effect_import_aliases(
  module: glance.Module,
) -> List(#(String, String)) {
  list.filter_map(module.imports, fn(def) {
    let import_ = def.definition
    case is_update_side_effect_module(import_.module) {
      True -> {
        let alias = case import_.alias {
          option.Some(glance.Named(name)) -> name
          option.Some(glance.Discarded(name)) -> name
          option.None -> module_short_name(import_.module)
        }
        Ok(#(alias, import_.module))
      }
      False -> Error(Nil)
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
  aliases: List(#(String, String)),
  external_names: List(String),
) -> List(PurityError) {
  body
  |> list.flat_map(fn(statement) {
    statement_side_effects(statement, aliases, external_names)
  })
  |> unique_purity_errors
}

fn statement_side_effects(
  statement: glance.Statement,
  aliases: List(#(String, String)),
  external_names: List(String),
) -> List(PurityError) {
  case statement {
    glance.Expression(expr) ->
      expression_side_effects(expr, aliases, external_names)
    glance.Assignment(value: expr, ..) ->
      expression_side_effects(expr, aliases, external_names)
    _ -> []
  }
}

fn expression_side_effects(
  expr: glance.Expression,
  aliases: List(#(String, String)),
  external_names: List(String),
) -> List(PurityError) {
  case expr {
    glance.Call(function: func, arguments: args, ..) -> {
      let own = call_side_effect(func, aliases, external_names)
      let func_nested = expression_side_effects(func, aliases, external_names)
      let arg_nested =
        list.flat_map(args, fn(arg) {
          case arg {
            glance.LabelledField(item: value, ..) ->
              expression_side_effects(value, aliases, external_names)
            glance.UnlabelledField(item: value) ->
              expression_side_effects(value, aliases, external_names)
            glance.ShorthandField(..) -> []
          }
        })
      list.flatten([own, func_nested, arg_nested])
    }
    glance.Block(statements: stmts, ..) ->
      list.flat_map(stmts, fn(stmt) {
        statement_side_effects(stmt, aliases, external_names)
      })
    glance.Case(subjects: subjects, clauses: clauses, ..) -> {
      let subject_errors =
        list.flat_map(subjects, fn(subject) {
          expression_side_effects(subject, aliases, external_names)
        })
      let clause_errors =
        list.flat_map(clauses, fn(clause) {
          expression_side_effects(clause.body, aliases, external_names)
        })
      list.append(subject_errors, clause_errors)
    }
    glance.BinaryOperator(left: left, right: right, ..) ->
      list.append(
        expression_side_effects(left, aliases, external_names),
        expression_side_effects(right, aliases, external_names),
      )
    glance.Fn(body: body, ..) ->
      list.flat_map(body, fn(stmt) {
        statement_side_effects(stmt, aliases, external_names)
      })
    glance.List(elements: elements, ..) ->
      list.flat_map(elements, fn(item) {
        expression_side_effects(item, aliases, external_names)
      })
    glance.Tuple(elements: elements, ..) ->
      list.flat_map(elements, fn(item) {
        expression_side_effects(item, aliases, external_names)
      })
    glance.FieldAccess(container: inner, ..) ->
      expression_side_effects(inner, aliases, external_names)
    glance.NegateInt(value: inner, ..) | glance.NegateBool(value: inner, ..) ->
      expression_side_effects(inner, aliases, external_names)
    _ -> []
  }
}

fn call_side_effect(
  func: glance.Expression,
  aliases: List(#(String, String)),
  external_names: List(String),
) -> List(PurityError) {
  case func {
    glance.FieldAccess(
      container: glance.Variable(name: alias, ..),
      label: call_name,
      ..,
    ) -> {
      let module_error = case list.find(aliases, fn(item) { item.0 == alias }) {
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
    glance.Variable(name: name, ..) -> {
      case list.contains(external_names, name) {
        True -> [UpdateSideEffect(name <> " external FFI")]
        False -> []
      }
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
pub fn has_server_boundary(source: String) -> Bool {
  case glance.module(source) {
    Error(_) -> True
    Ok(module) -> {
      list.any(module.custom_types, fn(def) { def.definition.name == "Server" })
      || list.any(module.functions, fn(def) {
        def.definition.name == "init_server"
        || def.definition.name == "update_server"
      })
      || list.any(module.constants, fn(def) {
        string.starts_with(def.definition.name, "server_")
      })
    }
  }
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
  case glance.module(source) {
    Error(_) -> Error("Failed to parse source for extraction")
    Ok(module) -> {
      let source_bytes = string_to_bytes(source)

      // Collect all type definitions (Model, Local, Msg, custom types)
      // Exclude Server/ServerState types — private server-side state is never
      // sent to client bundles or codecs.
      let type_texts =
        list.filter_map(module.custom_types, fn(def) {
          case
            def.definition.name == "Server"
            || def.definition.name == "ServerState"
          {
            True -> Error(Nil)
            False -> Ok(slice_source(source_bytes, def.definition.location))
          }
        })

      // Collect type aliases
      let alias_texts =
        list.map(module.type_aliases, fn(def) {
          slice_source(source_bytes, def.definition.location)
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
                    True -> Ok(#(func.name, is_public, func_text))
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
                                False -> Ok(#(func.name, is_public, func_text))
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

      let function_texts =
        list.filter_map(function_candidates, fn(candidate) {
          let #(name, is_public, func_text) = candidate
          case
            is_public
            || function_is_referenced_by_candidate(name, function_candidates)
          {
            True -> Ok(func_text)
            False -> Error(Nil)
          }
        })

      // Collect constants — filtered to prevent leaking server-side secrets.
      // Rules (in order):
      // 1. Skip if constant name starts with "server_" (server-only by convention)
      // 2. Skip if constant body references server-only modules
      // 3. Skip if constant is not referenced by any extracted function
      let constant_texts =
        list.filter_map(module.constants, fn(def) {
          let const_name = def.definition.name
          // Rule 1: skip server_ prefixed constants
          case string.starts_with(const_name, "server_") {
            True -> Error(Nil)
            False -> {
              let const_text =
                slice_source(source_bytes, def.definition.location)
              // Rule 2: skip if body references server-only code
              case function_references_server_code(const_text) {
                True -> Error(Nil)
                False -> {
                  // Rule 3: skip if not referenced by any extracted function
                  let is_referenced =
                    list.any(function_texts, fn(ft) {
                      string.contains(ft, const_name)
                    })
                  case is_referenced {
                    True -> Ok(const_text)
                    False -> Error(Nil)
                  }
                }
              }
            }
          }
        })

      let body_text =
        list.flatten([type_texts, alias_texts, constant_texts, function_texts])
        |> string.join("\n\n")

      // Collect safe imports that are still referenced by the extracted client
      // code. Server-only functions are stripped above, so their imports must
      // not keep server graphs reachable in the generated JS project.
      let import_texts =
        list.filter_map(module.imports, fn(def) {
          let import_ = def.definition
          let import_text = slice_source(source_bytes, import_.location)
          let alias_name = case import_.alias {
            option.Some(glance.Named(name)) -> name
            option.Some(glance.Discarded(name)) -> name
            option.None -> {
              case string.split(import_.module, "/") |> list.last {
                Ok(name) -> name
                Error(_) -> import_.module
              }
            }
          }
          case
            is_server_only_import(import_.module)
            || !import_referenced(import_text, alias_name, body_text)
          {
            True -> Error(Nil)
            False -> Ok(import_text)
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

/// Check if a function body references server-only code.
/// Checks if the function text references any module that was skipped
/// from the safe imports list, or uses known server-only patterns.
fn import_referenced(
  import_text: String,
  alias_name: String,
  body_text: String,
) -> Bool {
  string.contains(body_text, alias_name <> ".")
  || imported_unqualified_name_referenced(import_text, body_text)
}

fn imported_unqualified_name_referenced(
  import_text: String,
  body_text: String,
) -> Bool {
  case string.split(import_text, "{") {
    [_, rest] -> {
      let names_text = case string.split(rest, "}") {
        [names, ..] -> names
        _ -> ""
      }
      names_text
      |> string.split(",")
      |> list.any(fn(raw_name) {
        let name =
          raw_name
          |> string.trim
          |> strip_prefix("type ")
          |> strip_import_alias
        name != "" && string.contains(body_text, name)
      })
    }
    _ -> False
  }
}

fn function_is_referenced_by_candidate(
  name: String,
  candidates: List(#(String, Bool, String)),
) -> Bool {
  candidates
  |> list.any(fn(candidate) {
    let #(other_name, _is_public, other_text) = candidate
    other_name != name && string.contains(other_text, name)
  })
}

fn strip_prefix(text: String, prefix: String) -> String {
  case string.starts_with(text, prefix) {
    True -> string.drop_start(text, string.length(prefix))
    False -> text
  }
}

fn strip_import_alias(text: String) -> String {
  case string.split(text, " as ") {
    [name, ..] -> string.trim(name)
    _ -> text
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
