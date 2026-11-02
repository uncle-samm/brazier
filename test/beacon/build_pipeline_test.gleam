/// Build pipeline tests — verify the analysis pipeline works correctly
/// against real example apps and across rebuild scenarios.
import beacon/build/analyzer.{type Analysis}
import beacon/build/discovery
import beacon/build/shape
import beacon/build/sources
import gleam/list
import gleam/string
import simplifile

// === Example App Analysis Tests ===

/// Analyze the app module below `src_dir` the way `beacon/build` does: with
/// every user module it reaches.
fn analyze_example(src_dir: String) -> #(String, Analysis) {
  let assert Ok(app) = discovery.find(src_dir)
  let assert Ok(externals) = sources.app_externals(src_dir, app)
  let assert Ok(analysis) = analyzer.analyze_multi(app.source, externals)
  #(app.source, analysis)
}

/// Every example has an app shape the generated code supports.
pub fn every_example_passes_analysis_and_shape_check_test() {
  let assert Ok(examples) = simplifile.read_directory("examples")
  let checked =
    examples
    |> list.sort(string.compare)
    |> list.filter(fn(name) {
      simplifile.is_file("examples/" <> name <> "/gleam.toml") == Ok(True)
    })
    |> list.map(fn(name) {
      let #(source, analysis) = analyze_example("examples/" <> name <> "/src")
      case shape.check(analysis, source) {
        Ok(_) -> Ok(name)
        Error(reason) -> Error(#(name, reason))
      }
    })
  let assert [] =
    list.filter_map(checked, fn(r) {
      case r {
        Ok(_) -> Error(Nil)
        Error(failure) -> Ok(failure)
      }
    })
  let assert True = list.length(checked) > 10
}

pub fn counter_example_analyzes_correctly_test() {
  let assert Ok(source) = simplifile.read("examples/counter/src/counter.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_server
  let assert False = analysis.has_local
  let assert True = list.any(analysis.model_fields, fn(f) { f.name == "count" })
  let assert True =
    list.any(analysis.msg_variants, fn(v) { v.name == "Increment" })
  let assert True =
    list.any(analysis.msg_variants, fn(v) { v.name == "Decrement" })
}

pub fn privacy_demo_analyzes_correctly_test() {
  let assert Ok(source) =
    simplifile.read("examples/privacy_demo/src/privacy_demo.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_server
  let assert False = analysis.has_local
  let assert True = list.length(analysis.server_fields) >= 1
  // Model fields should NOT include server fields
  let server_field_names = list.map(analysis.server_fields, fn(f) { f.name })
  list.each(server_field_names, fn(name) {
    let assert False = list.any(analysis.model_fields, fn(f) { f.name == name })
  })
  let assert True = list.length(analysis.computed_fields) >= 1
}

pub fn private_session_example_supports_server_state_bundle_test() {
  let assert Ok(source) =
    simplifile.read("examples/private_session/src/private_session.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_server
  let assert False = analysis.has_local
  let assert True =
    list.any(analysis.server_fields, fn(f) { f.name == "signing_key" })
  let assert Ok(_) = shape.check(analysis, source)
}

pub fn auth_workspace_example_supports_server_state_bundle_test() {
  let assert Ok(source) =
    simplifile.read("examples/auth_workspace/src/auth_workspace/app.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_server
  let assert False = analysis.has_local
  let assert True =
    list.any(analysis.server_fields, fn(f) { f.name == "private_audit_key" })
  let assert False =
    list.any(analysis.model_fields, fn(f) { f.name == "private_audit_key" })
  let assert Ok(_) = shape.check(analysis, source)
}

pub fn counter_local_analyzes_correctly_test() {
  let assert Ok(source) =
    simplifile.read("examples/counter_local/src/counter_local.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_local
  let assert False = analysis.has_server
}

pub fn local_first_form_analyzes_as_local_model_split_test() {
  let assert Ok(source) =
    simplifile.read("examples/local_first_form/src/local_first_form.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_local
  let assert False = analysis.has_server
  let assert True =
    list.any(analysis.msg_variants, fn(v) {
      v.name == "UpdateDraft" && !v.affects_model
    })
  let assert True =
    list.any(analysis.msg_variants, fn(v) {
      v.name == "SubmitSearch" && v.affects_model
    })
  let assert Ok(_) = shape.check(analysis, source)
}

pub fn routed_workspace_app_supports_client_state_bundle_test() {
  let assert Ok(source) =
    simplifile.read("examples/routed_workspace/src/main.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_local
  let assert False = analysis.has_server
  let assert True =
    list.any(analysis.msg_variants, fn(v) { v.name == "RouteChanged" })
  let assert Ok(_) = shape.check(analysis, source)
}

pub fn routed_example_supports_imported_page_modules_test() {
  let #(source, analysis) = analyze_example("examples/routed/src")
  let assert False = analysis.has_local
  let assert True = analysis.has_server
  let assert True = list.any(analysis.model_fields, fn(f) { f.name == "path" })
  let assert True =
    list.any(analysis.server_fields, fn(f) {
      f.name == "home" && f.module == "home" && f.type_name == "Server"
    })
  let assert True =
    list.any(analysis.model_fields, fn(f) {
      f.name == "home" && f.module == "home" && f.type_name == "Model"
    })
  let assert True =
    list.any(analysis.msg_variants, fn(v) { v.name == "RouteChanged" })
  let assert Ok(_) = shape.check(analysis, source)
}

pub fn routed_example_route_local_home_model_analyzes_test() {
  let assert Ok(source) = simplifile.read("examples/routed/src/main.gleam")
  let assert Ok(home_source) =
    simplifile.read("examples/routed/src/routed/pages/home.gleam")
  let assert Ok(analysis) =
    analyzer.analyze_multi(source, [
      #("home", "routed/pages/home", home_source),
    ])
  let assert True =
    list.any(analysis.model_fields, fn(f) {
      f.name == "home" && f.module == "home" && f.type_name == "Model"
    })
  let assert True =
    list.any(analysis.custom_types, fn(ct) {
      ct.module == "home" && ct.name == "Model"
    })
  let assert False =
    list.any(analysis.custom_types, fn(ct) {
      ct.module == "home" && ct.name == "Server"
    })
  let assert False =
    list.any(analysis.enum_types, fn(et) {
      et.module == "home" && et.name == "Msg"
    })
  let assert True =
    list.any(analysis.server_fields, fn(f) {
      f.name == "home" && f.module == "home" && f.type_name == "Server"
    })
  let assert True = list.any(analysis.msg_variants, fn(v) { v.name == "Home" })
}

pub fn route_server_workspace_route_servers_are_private_test() {
  let assert Ok(source) =
    simplifile.read("examples/route_server_workspace/src/main.gleam")
  let assert Ok(accounts_source) =
    simplifile.read(
      "examples/route_server_workspace/src/route_server_workspace/pages/accounts.gleam",
    )
  let assert Ok(settings_source) =
    simplifile.read(
      "examples/route_server_workspace/src/route_server_workspace/pages/settings.gleam",
    )
  let assert Ok(analysis) =
    analyzer.analyze_multi(source, [
      #("accounts", "route_server_workspace/pages/accounts", accounts_source),
      #("settings", "route_server_workspace/pages/settings", settings_source),
    ])

  let assert True = analysis.has_server
  let assert True =
    list.any(analysis.model_fields, fn(f) {
      f.name == "accounts" && f.module == "accounts" && f.type_name == "Model"
    })
  let assert True =
    list.any(analysis.server_fields, fn(f) {
      f.name == "accounts" && f.module == "accounts" && f.type_name == "Server"
    })
  let assert False =
    list.any(analysis.custom_types, fn(ct) {
      ct.module == "accounts" && ct.name == "Server"
    })
  let assert False =
    list.any(analysis.custom_types, fn(ct) {
      ct.module == "settings" && ct.name == "Server"
    })
  let assert Ok(_) = shape.check(analysis, source)
}

pub fn routed_example_uses_explicit_imported_page_modules_test() {
  let assert Ok(source) = simplifile.read("examples/routed/src/main.gleam")
  let assert True = string.contains(source, "import routed/pages/home")
  let assert True = string.contains(source, "import routed/pages/about")
  let assert True = string.contains(source, "import routed/pages/settings")
  let assert True = string.contains(source, "import routed/pages/stats")
  let assert True = string.contains(source, "beacon.route_pages")
  let assert True = string.contains(source, "home.page(")
  let assert False = string.contains(source, "beacon.router")
  let assert False = string.contains(source, "start_router")
}

pub fn auth_workspace_uses_route_pages_not_low_level_routes_test() {
  let assert Ok(source) =
    simplifile.read("examples/auth_workspace/src/auth_workspace.gleam")
  let assert True = string.contains(source, "beacon.route_pages")
  let assert True = string.contains(source, "auth_pages()")
  let assert False = string.contains(source, "beacon.routes(")
  let assert False = string.contains(source, "beacon.on_route_change")
}

pub fn routed_workspace_uses_explicit_route_pages_test() {
  let assert Ok(source) =
    simplifile.read("examples/routed_workspace/src/main.gleam")
  let assert True = string.contains(source, "beacon.route_pages")
  let assert True = string.contains(source, "beacon.route_pages(pages())")
  let assert True = string.contains(source, "route.dispatch_view")
  let assert True = string.contains(source, "\"/pipeline\"")
  let assert True = string.contains(source, "\"/settings\"")
}

pub fn domains_multi_file_analyzes_correctly_test() {
  let assert Ok(app_source) = simplifile.read("examples/domains/src/app.gleam")
  let externals = case
    simplifile.read("examples/domains/src/domains/auth.gleam"),
    simplifile.read("examples/domains/src/domains/items.gleam")
  {
    Ok(auth_src), Ok(items_src) -> [
      #("auth", "domains/auth", auth_src),
      #("items", "domains/items", items_src),
    ]
    _, _ -> []
  }
  // Both external files must be readable
  let assert True = list.length(externals) == 2
  let assert Ok(analysis) = analyzer.analyze_multi(app_source, externals)
  let assert True = list.length(analysis.custom_types) >= 1
  let assert True = list.length(analysis.model_fields) >= 1
  let assert True =
    list.any(analysis.enum_types, fn(et) {
      et.module == "auth" && et.name == "Role"
    })
}

pub fn domains_multi_file_supports_enhanced_bundle_test() {
  let assert Ok(app_source) = simplifile.read("examples/domains/src/app.gleam")
  let assert Ok(auth_src) =
    simplifile.read("examples/domains/src/domains/auth.gleam")
  let assert Ok(items_src) =
    simplifile.read("examples/domains/src/domains/items.gleam")
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [
      #("auth", "domains/auth", auth_src),
      #("items", "domains/items", items_src),
    ])
  let assert Ok(_) = shape.check(analysis, app_source)
}

pub fn effect_app_without_local_supports_client_renderer_test() {
  let assert Ok(source) =
    simplifile.read("examples/dashboard/src/dashboard.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_local
  let assert False = analysis.has_server
  let assert Ok(_) = shape.check(analysis, source)
}

// === Idempotency Tests ===

pub fn analysis_with_different_source_produces_different_result_test() {
  let source_v1 =
    "
pub type Model {
  Model(count: Int)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let source_v2 =
    "
pub type Model {
  Model(count: Int, name: String, items: List(String))
}
pub type Msg {
  Inc
  Dec
  Add(String)
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(a1) = analyzer.analyze(source_v1)
  let assert Ok(a2) = analyzer.analyze(source_v2)
  let assert True = list.length(a1.model_fields) == 1
  let assert True = list.length(a2.model_fields) == 3
  let assert True = list.length(a1.msg_variants) == 1
  let assert True = list.length(a2.msg_variants) == 3
}

// === Rebuild Scenario Tests ===

pub fn analysis_after_model_change_reflects_new_fields_test() {
  let source_v1 =
    "
pub type Model {
  Model(count: Int)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let source_v2 =
    "
pub type Model {
  Model(count: Int, name: String)
}
pub type Msg {
  Inc
  SetName(String)
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(a1) = analyzer.analyze(source_v1)
  let assert True = list.length(a1.model_fields) == 1
  let assert False = list.any(a1.model_fields, fn(f) { f.name == "name" })

  let assert Ok(a2) = analyzer.analyze(source_v2)
  let assert True = list.length(a2.model_fields) == 2
  let assert True = list.any(a2.model_fields, fn(f) { f.name == "name" })
}

pub fn analysis_after_adding_server_type_detects_it_test() {
  let source_v1 =
    "
pub type Model {
  Model(count: Int)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let source_v2 =
    "
pub type Model {
  Model(count: Int)
}
pub type Server {
  Server(api_key: String)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(a1) = analyzer.analyze(source_v1)
  let assert False = a1.has_server

  let assert Ok(a2) = analyzer.analyze(source_v2)
  let assert True = a2.has_server
  let assert True = list.any(a2.server_fields, fn(f) { f.name == "api_key" })
}

pub fn enhanced_bundle_supported_for_standard_app_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Inc }
pub fn update(model: Model, _local: Nil, _server: Nil, _msg: Msg) -> #(Model, Nil, Nil) { #(model, Nil, Nil) }
pub fn view(model: Model, _local: Nil) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert Ok(_) = shape.check(analysis, source)
}

pub fn enhanced_bundle_supported_for_server_state_view_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Server { Server(secret: String) }
pub type Msg { Inc }
pub fn update(model: Model, _local: Nil, server: Server, _msg: Msg) -> #(Model, Nil, Server) {
  #(model, Nil, server)
}
pub fn view(model: Model, _local: Nil) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert Ok(_) = shape.check(analysis, source)
}

pub fn enhanced_bundle_skipped_for_model_only_multi_file_test() {
  let source =
    "
pub type Model { Model(count: Int) }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert Error(_) = shape.check(analysis, source)
}
