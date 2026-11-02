import beacon/build/analyzer
import gleam/list
import gleam/string

pub fn analyzes_counter_local_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String, menu_open: Bool) }
pub type Msg {
  Increment
  Decrement
  SetInput(String)
  ToggleMenu
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    Increment -> #(Model(count: model.count + 1), local)
    Decrement -> #(Model(count: model.count - 1), local)
    SetInput(text) -> #(model, Local(..local, input: text))
    ToggleMenu -> #(model, Local(..local, menu_open: !local.menu_open))
  }
}

pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_local
  let assert 4 = list.length(analysis.msg_variants)
  // Increment and Decrement modify model
  let assert True =
    find_variant(analysis.msg_variants, "Increment").affects_model
  let assert True =
    find_variant(analysis.msg_variants, "Decrement").affects_model
  // SetInput and ToggleMenu only modify local
  let assert False =
    find_variant(analysis.msg_variants, "SetInput").affects_model
  let assert False =
    find_variant(analysis.msg_variants, "ToggleMenu").affects_model
  let assert True =
    find_variant(analysis.msg_variants, "SetInput").affects_local
  let assert True =
    find_variant(analysis.msg_variants, "ToggleMenu").affects_local
  let assert analyzer.LocalOnly =
    analyzer.msg_impact(find_variant(analysis.msg_variants, "SetInput"))
}

pub fn classifies_local_model_and_mixed_messages_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String, saving: Bool) }
pub type Msg {
  SetInput(String)
  Save
  Reset
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    SetInput(text) -> #(model, Local(..local, input: text))
    Save -> #(Model(count: model.count + 1), Local(..local, saving: True))
    Reset -> #(Model(count: 0), local)
  }
}

pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)

  let set_input = find_variant(analysis.msg_variants, "SetInput")
  let save = find_variant(analysis.msg_variants, "Save")
  let reset = find_variant(analysis.msg_variants, "Reset")

  let assert False = set_input.affects_model
  let assert True = set_input.affects_local
  let assert analyzer.LocalOnly = analyzer.msg_impact(set_input)

  let assert True = save.affects_model
  let assert True = save.affects_local
  let assert analyzer.ModelAndLocal = analyzer.msg_impact(save)

  let assert True = reset.affects_model
  let assert False = reset.affects_local
  let assert analyzer.ModelOnly = analyzer.msg_impact(reset)
}

pub fn client_msg_allowlist_is_detected_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg {
  Increment
  AdminReset
}

pub type ClientMsg {
  Increment
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    AdminReset -> Model(count: 0)
  }
}

pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert 2 = list.length(analysis.msg_variants)
  let assert 1 = list.length(analysis.client_msg_variants)
  let assert "Increment" =
    find_variant(analysis.client_msg_variants, "Increment").name
}

pub fn entry_client_msg_allowlist_applies_to_imported_msg_test() {
  let app_source =
    "
import app/msg

pub type Model { Model(count: Int) }
pub type ClientMsg {
  Increment
}

pub fn update(model: Model, _msg: msg.Msg) -> Model { model }
pub fn view(model: Model) { model }
"
  let msg_source =
    "
pub type Msg {
  Increment
  AdminReset
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [#("msg", "app/msg", msg_source)])
  let assert "msg" = analysis.msg_module
  let assert 1 = list.length(analysis.msg_variants)
  let assert 1 = list.length(analysis.client_msg_variants)
  let assert "Increment" =
    find_variant(analysis.client_msg_variants, "Increment").name
  let assert False =
    list.any(analysis.msg_variants, fn(v) { v.name == "AdminReset" })
}

pub fn tuple_list_field_type_is_preserved_test() {
  let source =
    "
pub type Model {
  Model(github_installations: List(#(String, String, String)))
}
pub type Msg { NoOp }
pub fn update(model: Model, _msg: Msg) -> Model { model }
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert Ok(field) =
    list.find(analysis.model_fields, fn(f) { f.name == "github_installations" })
  let assert "List" = field.type_name
  let assert "#(String, String, String)" = field.inner_type
}

pub fn state_diagnostics_describe_model_local_server_shape_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String, saving: Bool) }
pub type Server { Server(secret: String) }
pub type Msg {
  SetInput(String)
  Save
  Reset
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    SetInput(text) -> #(model, Local(..local, input: text))
    Save -> #(Model(count: model.count + 1), Local(..local, saving: True))
    Reset -> #(Model(count: 0), local)
  }
}

pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let diagnostics = analyzer.state_diagnostics(analysis)
  let joined = string.join(diagnostics, "\n")

  let assert True =
    string.contains(joined, "Beacon app state shape: Model + Local + Server")
  let assert True =
    string.contains(joined, "Local inferred from pub type Local (2 fields)")
  let assert True =
    string.contains(joined, "Server inferred from pub type Server (1 fields)")
  let assert True =
    string.contains(joined, "Message impacts: LOCAL=1, MODEL=1, MODEL+LOCAL=1")
}

pub fn analyzes_simple_counter_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg {
  Increment
  Decrement
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    Decrement -> Model(count: model.count - 1)
  }
}

pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_local
  // Both modify model
  let assert True =
    find_variant(analysis.msg_variants, "Increment").affects_model
  let assert True =
    find_variant(analysis.msg_variants, "Decrement").affects_model
}

pub fn extracts_model_fields_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String, menu_open: Bool) }
pub type Msg { Increment }
pub fn update(model: Model, local: Local, _server: Nil, msg: Msg) -> #(Model, Local, Nil) {
  case msg { Increment -> #(Model(count: model.count + 1), local, Nil) }
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert 1 = list.length(analysis.model_fields)
  let assert Ok(field) = list.first(analysis.model_fields)
  let assert "count" = field.name
  let assert "Int" = field.type_name
}

pub fn detects_direct_init_update_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg { Increment }
pub fn init() -> Model { Model(count: 0) }
pub fn init_local(_m: Model) -> Local { Local(input: \"\") }
pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg { Increment -> #(Model(count: model.count + 1), local) }
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_direct_init
  let assert True = analysis.has_direct_update
}

pub fn detects_factory_pattern_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg { Increment }
pub fn init_local(_m: Model) -> Local { Local(input: \"\") }
pub fn make_update(store) -> fn(Model, Local, Nil, Msg) -> #(Model, Local, Nil) {
  fn(model, local, _server, msg) {
    case msg { Increment -> #(Model(count: model.count + 1), local, Nil) }
  }
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_direct_init
  let assert False = analysis.has_direct_update
}

pub fn no_msg_type_succeeds_with_empty_variants_test() {
  // When Msg type is missing (multi-file app), analysis succeeds with empty variants.
  // The codec only needs Model fields — Msg is not required.
  let source =
    "pub fn update(m, msg) { m }\npub fn view(m) { m }\npub type Model { M }\n"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.msg_variants == []
}

fn find_variant(
  variants: List(analyzer.MsgVariant),
  name: String,
) -> analyzer.MsgVariant {
  let assert Ok(v) = list.find(variants, fn(v) { v.name == name })
  v
}

// ===== Purity Validation Tests =====

pub fn pure_module_passes_validation_test() {
  let source =
    "
import beacon
import beacon/html
import gleam/int
import gleam/list
import gleam/string

pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg {
  Increment
  SetInput(String)
}

pub fn init() -> Model { Model(count: 0) }
pub fn init_local(_m: Model) -> Local { Local(input: \"\") }
pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    Increment -> #(Model(count: model.count + 1), local)
    SetInput(t) -> #(model, Local(input: t))
  }
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(Nil) = analyzer.validate_purity(source)
}

pub fn impure_store_import_fails_validation_test() {
  let source =
    "
import beacon
import beacon/store

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Error(msg) = analyzer.validate_purity(source)
  let assert True = string.contains(msg, "beacon/store")
}

pub fn impure_effect_import_fails_validation_test() {
  let source =
    "
import beacon
import beacon/effect

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Error(msg) = analyzer.validate_purity(source)
  let assert True = string.contains(msg, "beacon/effect")
}

pub fn impure_erlang_process_import_fails_test() {
  let source =
    "
import beacon
import gleam/erlang/process

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Error(msg) = analyzer.validate_purity(source)
  let assert True = string.contains(msg, "gleam/erlang/process")
}

pub fn impure_external_erlang_fails_validation_test() {
  let source =
    "
import beacon

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }

@external(erlang, \"erlang\", \"unique_integer\")
fn unique_int() -> Int
"
  let assert Error(msg) = analyzer.validate_purity(source)
  let assert True = string.contains(msg, "unique_int")
  let assert True = string.contains(msg, "@external(erlang")
}

pub fn multiple_purity_errors_reported_test() {
  let source =
    "
import beacon
import beacon/store
import beacon/pubsub

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }

@external(erlang, \"erlang\", \"unique_integer\")
fn unique_int() -> Int
"
  let assert Error(msg) = analyzer.validate_purity(source)
  // All three errors should be reported
  let assert True = string.contains(msg, "beacon/store")
  let assert True = string.contains(msg, "beacon/pubsub")
  let assert True = string.contains(msg, "unique_int")
}

pub fn safe_imports_pass_validation_test() {
  // These imports are all pure Gleam — should pass
  let source =
    "
import beacon
import beacon/html
import beacon/element
import gleam/int
import gleam/list
import gleam/string
import gleam/float
import gleam/bool
import gleam/option
import gleam/result
import gleam/dict
import gleam/json

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Ok(Nil) = analyzer.validate_purity(source)
}

// ===== AST Extraction Tests =====

pub fn extracts_pure_types_and_functions_test() {
  let source =
    "import beacon
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Local {
  Local(input: String)
}

pub type Msg {
  Increment
  SetInput(String)
}

pub fn init() -> Model {
  Model(count: 0)
}

pub fn init_local(_m: Model) -> Local {
  Local(input: \"\")
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    Increment -> #(Model(count: model.count + 1), local)
    SetInput(t) -> #(model, Local(input: t))
  }
}

pub fn view(model: Model, local: Local) { model }

pub fn start() {
  todo
}
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // Should contain types, init, update, view
  let assert True = string.contains(extracted, "pub type Model")
  let assert True = string.contains(extracted, "pub type Local")
  let assert True = string.contains(extracted, "pub type Msg")
  let assert True = string.contains(extracted, "pub fn init()")
  let assert True = string.contains(extracted, "pub fn init_local(")
  // Pure update IS extracted — enables LOCAL events + optimistic updates
  let assert True = string.contains(extracted, "pub fn update(")
  let assert True = string.contains(extracted, "pub fn view(")
  // Should NOT contain start
  let assert False = string.contains(extracted, "pub fn start()")
  // Should drop unused imports, even when they are client-safe.
  let assert False = string.contains(extracted, "import beacon")
  let assert False = string.contains(extracted, "import gleam/int")
}

pub fn skips_server_imports_in_extraction_test() {
  let source =
    "import beacon
import beacon/store
import beacon/effect
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // Should drop unused safe imports too
  let assert False = string.contains(extracted, "import beacon")
  let assert False = string.contains(extracted, "import gleam/int")
  // Should NOT contain server-only imports
  let assert False = string.contains(extracted, "import beacon/store")
  let assert False = string.contains(extracted, "import beacon/effect")
}

pub fn keeps_referenced_client_imports_and_drops_server_siblings_test() {
  let source =
    "import beacon/html
import gleam/string
import agent/manager

pub type Model {
  Model(name: String)
}

pub type Msg {
  NoOp
}

pub fn view(model: Model) {
  html.div([], [html.text(string.uppercase(model.name))])
}

pub fn init_server() {
  manager.start()
}
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "import gleam/string")
  let assert False = string.contains(extracted, "import agent/manager")
}

pub fn drops_server_state_route_page_helpers_from_client_extraction_test() {
  let source =
    "import app/server_state.{type ServerState, ServerState}
import beacon/route as beacon_route

pub type Model {
  Model(route: String)
}

pub type Msg {
  RouteChanged(String)
}

fn app_view(model: Model) {
  model
}

fn render_route_page(
  state: #(Model, Nil, ServerState),
  route_info: beacon_route.Route,
) {
  let #(model, _local, _server) = state
  app_view(Model(..model, route: route_info.path))
}

fn route_pages() -> List(beacon_route.Page(#(Model, Nil, ServerState), Msg)) {
  [beacon_route.page(\"/\", fn(r) { RouteChanged(r.path) }, render_route_page)]
}

pub fn view(model: Model) {
  app_view(model)
}
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "pub fn view(")
  let assert False = string.contains(extracted, "import app/server_state")
  let assert False = string.contains(extracted, "import beacon/route")
  let assert False = string.contains(extracted, "render_route_page")
  let assert False = string.contains(extracted, "route_pages")
  let assert False = string.contains(extracted, "ServerState")
}

pub fn keeps_private_helper_referenced_as_function_value_test() {
  let source =
    "import gleam/list

pub type Model {
  Model(lines: List(String))
}

fn render_line(line: String) {
  line
}

pub fn view(model: Model) {
  list.map(model.lines, render_line)
}
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "fn render_line")
}

pub fn keeps_client_safe_log_import_in_extraction_test() {
  let source =
    "import beacon/html
import beacon/log

pub type Model {
  Model(count: Int)
}

pub type Msg {
  BadInput(String)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    BadInput(value) -> {
      log.warning(\"example\", \"bad input: \" <> value)
      model
    }
  }
}

pub fn view(model: Model) {
  html.div([], [])
}
"
  let assert Ok(Nil) = analyzer.validate_purity(source)
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "import beacon/log")
  let assert True = string.contains(extracted, "log.warning")
}

pub fn strips_known_server_only_package_imports_from_client_source_test() {
  let source =
    "import beacon/html
import envoy
import glean/run

pub type Model {
  Model(prompt: String)
}

pub type Msg {
  Submit
}

pub fn update(model: Model, msg: Msg) -> Model {
  model
}

pub fn view(model: Model) {
  html.div([], [])
}
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "import beacon/html")
  let assert False = string.contains(extracted, "import envoy")
  let assert False = string.contains(extracted, "import glean/run")
}

pub fn strips_route_local_server_from_extracted_client_source_test() {
  let source =
    "import beacon
import beacon/html
import beacon/route
import gleam/int

const server_secret = \"route_secret_must_not_ship\"

pub type Model {
  Model(count: Int, server_updates: Int)
}

pub type Server {
  Server(secret: String, writes: Int)
}

pub type Msg {
  Increment
}

pub fn init() -> Model {
  Model(count: 0, server_updates: 0)
}

pub fn init_server() -> Server {
  Server(secret: server_secret, writes: 0)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(..model, count: model.count + 1)
  }
}

pub fn update_server(model: Model, server: Server, msg: Msg) -> #(Model, Server) {
  let updated = update(model, msg)
  case msg {
    Increment -> #(
      Model(..updated, server_updates: updated.server_updates + 1),
      Server(..server, writes: server.writes + 1),
    )
  }
}

pub fn page(
  on_enter: fn(route.Route) -> msg,
  select: fn(model) -> Model,
  wrap: fn(Msg) -> msg,
) -> route.Page(model, msg) {
  route.page_model(\"/\", on_enter, select, fn(model, _route) {
    view(model, wrap)
  })
}

pub fn view(model: Model, wrap: fn(Msg) -> msg) -> beacon.Node(msg) {
  html.button([beacon.on_click(wrap(Increment))], [
    html.text(int.to_string(model.count)),
  ])
}
"
  let assert Ok(True) = analyzer.has_server_boundary(source)
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "pub type Model")
  let assert True = string.contains(extracted, "pub type Msg")
  let assert True = string.contains(extracted, "pub fn update(")
  let assert True = string.contains(extracted, "pub fn page(")
  let assert True = string.contains(extracted, "pub fn view(")
  let assert False = string.contains(extracted, "pub type Server")
  let assert False = string.contains(extracted, "pub fn init_server")
  let assert False = string.contains(extracted, "pub fn update_server")
  let assert False = string.contains(extracted, "server_secret")
  let assert False = string.contains(extracted, "route_secret_must_not_ship")
}

pub fn skips_external_erlang_functions_test() {
  let source =
    "import beacon

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}

pub fn view(model: Model) { model }

@external(erlang, \"erlang\", \"unique_integer\")
fn unique_int() -> Int
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // Should contain update and view
  // Pure update IS extracted — enables LOCAL events + optimistic updates
  let assert True = string.contains(extracted, "pub fn update(")
  let assert True = string.contains(extracted, "pub fn view(")
  // Should NOT contain the external function
  let assert False = string.contains(extracted, "unique_int")
  let assert False = string.contains(extracted, "@external")
}

pub fn preserves_helper_functions_test() {
  let source =
    "import beacon

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

fn helper(x: Int) -> Int {
  x + 1
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: helper(model.count)) }
}

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // Should preserve helper functions
  let assert True = string.contains(extracted, "fn helper(")
}

// === Substate Detection Tests ===

pub fn detects_record_field_as_substate_test() {
  let source =
    "
pub type Settings { Settings(theme: String, language: String) }
pub type Model { Model(count: Int, settings: Settings) }
pub type Msg { Increment
  UpdateSettings }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(..model, count: model.count + 1)
    _ -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.substates) == 1
  let assert Ok(s) = list.first(analysis.substates)
  let assert True = s.field_name == "settings"
  let assert True = s.type_name == "Settings"
  let assert True = s.is_list == False
}

pub fn detects_list_record_as_substate_test() {
  let source =
    "
pub type Card { Card(id: Int, title: String) }
pub type Model { Model(cards: List(Card), next_id: Int) }
pub type Msg { AddCard }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddCard -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.substates) == 1
  let assert Ok(s) = list.first(analysis.substates)
  let assert True = s.field_name == "cards"
  let assert True = s.type_name == "Card"
  let assert True = s.is_list == True
}

pub fn primitives_not_substates_test() {
  let source =
    "
pub type Model { Model(count: Int, name: String, active: Bool) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.substates == []
}

pub fn enums_not_substates_test() {
  let source =
    "
pub type Status { Active
  Inactive
  Pending }
pub type Model { Model(status: Status, count: Int) }
pub type Msg { Toggle }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Toggle -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.substates == []
}

pub fn multiple_substates_test() {
  let source =
    "
pub type Card { Card(id: Int, title: String) }
pub type Message { Message(text: String, sender: String) }
pub type Model { Model(cards: List(Card), messages: List(Message), count: Int) }
pub type Msg { AddCard }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddCard -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.substates) == 2
}

// ===== Multi-file Analyzer Tests =====

pub fn analyzes_external_type_field_test() {
  // App module references auth.User from an external module
  let app_source =
    "
import domains/auth

pub type Model { Model(user: auth.User, count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(..model, count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let auth_source =
    "
pub type User { User(name: String, email: String) }
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [#("auth", "domains/auth", auth_source)])

  // Should detect the external User type
  let assert True = list.length(analysis.custom_types) == 1
  let assert Ok(ct) = list.first(analysis.custom_types)
  let assert True = ct.name == "User"
  let assert True = ct.module == "auth"
  let assert True = list.length(ct.fields) == 2

  // Model field should have module qualifier
  let assert Ok(user_field) =
    list.find(analysis.model_fields, fn(f) { f.name == "user" })
  let assert True = user_field.type_name == "User"
  let assert True = user_field.module == "auth"

  // Should be a substate (custom record type)
  let assert True = list.length(analysis.substates) == 1
  let assert Ok(s) = list.first(analysis.substates)
  let assert True = s.field_name == "user"
  let assert True = s.type_name == "User"
  let assert True = s.module == "auth"

  // Should have the imported module
  let assert True = list.length(analysis.imported_modules) == 1
}

pub fn analyzes_external_list_type_test() {
  // App references List(card.Card) from an external module
  let app_source =
    "
import domains/card

pub type Model { Model(cards: List(card.Card), count: Int) }
pub type Msg { AddCard }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddCard -> model }
}
pub fn view(model: Model) { model }
"
  let card_source =
    "
pub type Card { Card(id: Int, title: String, done: Bool) }
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [#("card", "domains/card", card_source)])

  // Should detect the external Card type
  let assert True = list.length(analysis.custom_types) == 1
  let assert Ok(ct) = list.first(analysis.custom_types)
  let assert True = ct.name == "Card"
  let assert True = ct.module == "card"

  // Model field should have inner_module qualifier
  let assert Ok(cards_field) =
    list.find(analysis.model_fields, fn(f) { f.name == "cards" })
  let assert True = cards_field.type_name == "List"
  let assert True = cards_field.inner_type == "Card"
  let assert True = cards_field.inner_module == "card"

  // Should be detected as a list substate
  let assert True = list.length(analysis.substates) == 1
  let assert Ok(s) = list.first(analysis.substates)
  let assert True = s.field_name == "cards"
  let assert True = s.type_name == "Card"
  let assert True = s.is_list == True
  let assert True = s.module == "card"
}

pub fn analyzes_external_enum_type_test() {
  // App references an enum type from an external module
  let app_source =
    "
import domains/status

pub type Model { Model(status: status.Status, count: Int) }
pub type Msg { Toggle }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Toggle -> model }
}
pub fn view(model: Model) { model }
"
  let status_source =
    "
pub type Status { Active
  Inactive
  Pending }
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [
      #("status", "domains/status", status_source),
    ])

  // Should detect the external enum type
  let assert True = list.length(analysis.enum_types) == 1
  let assert Ok(et) = list.first(analysis.enum_types)
  let assert True = et.name == "Status"
  let assert True = et.module == "status"
  let assert True = list.length(et.variants) == 3

  // Should NOT be a substate (enums are not substates)
  let assert True = analysis.substates == []
}

pub fn single_file_backward_compat_test() {
  // Existing single-file apps should work exactly as before
  let source =
    "
pub type Card { Card(id: Int, title: String) }
pub type Model { Model(cards: List(Card), count: Int) }
pub type Msg { AddCard }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddCard -> model }
}
pub fn view(model: Model) { model }
"
  // analyze_multi with empty externals should match analyze
  let assert Ok(analysis_single) = analyzer.analyze(source)
  let assert Ok(analysis_multi) = analyzer.analyze_multi(source, [])

  let assert True =
    list.length(analysis_single.custom_types)
    == list.length(analysis_multi.custom_types)
  let assert True =
    list.length(analysis_single.substates)
    == list.length(analysis_multi.substates)
  let assert True =
    list.length(analysis_single.model_fields)
    == list.length(analysis_multi.model_fields)
  let assert True = analysis_single.imported_modules == []
  let assert True = analysis_multi.imported_modules == []
}

pub fn mixed_local_and_external_test() {
  // Model with both local and external types
  let app_source =
    "
import domains/auth

pub type Settings { Settings(theme: String, language: String) }
pub type Model {
  Model(
    user: auth.User,
    settings: Settings,
    messages: List(auth.ChatMessage),
    count: Int,
  )
}
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(..model, count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let auth_source =
    "
pub type User { User(name: String, email: String) }
pub type ChatMessage { ChatMessage(text: String, sender: String) }
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [#("auth", "domains/auth", auth_source)])

  // Should have 3 custom types: 1 local (Settings) + 2 external (User, ChatMessage)
  let assert True = list.length(analysis.custom_types) == 3

  // Local Settings type should have module == ""
  let assert Ok(settings_ct) =
    list.find(analysis.custom_types, fn(ct) { ct.name == "Settings" })
  let assert True = settings_ct.module == ""

  // External User type should have module == "auth"
  let assert Ok(user_ct) =
    list.find(analysis.custom_types, fn(ct) { ct.name == "User" })
  let assert True = user_ct.module == "auth"

  // 3 substates: user (auth, single), settings (local, single), messages (auth, list)
  let assert True = list.length(analysis.substates) == 3

  // Check user substate
  let assert Ok(user_s) =
    list.find(analysis.substates, fn(s) { s.field_name == "user" })
  let assert True = user_s.module == "auth"
  let assert True = user_s.is_list == False

  // Check settings substate (local)
  let assert Ok(settings_s) =
    list.find(analysis.substates, fn(s) { s.field_name == "settings" })
  let assert True = settings_s.module == ""
  let assert True = settings_s.is_list == False

  // Check messages substate (external list)
  let assert Ok(messages_s) =
    list.find(analysis.substates, fn(s) { s.field_name == "messages" })
  let assert True = messages_s.module == "auth"
  let assert True = messages_s.is_list == True
}

pub fn user_module_passes_purity_test() {
  // Importing user domain modules should pass purity validation
  let source =
    "
import beacon
import domains/auth
import domains/chat

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Ok(Nil) = analyzer.validate_purity(source)
}

// === Constant Leak Prevention Tests ===

pub fn server_prefix_constant_not_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

const server_api_key = \"sk_live_abc123\"

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "server_api_key")
  let assert False = string.contains(extracted, "sk_live_abc123")
}

pub fn server_module_constant_not_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

const db_config = process.self()

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "db_config")
}

pub fn referenced_constant_is_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

const max_count = 100

pub fn view(model: Model) { max_count }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "max_count")
  let assert True = string.contains(extracted, "100")
}

pub fn unreferenced_constant_not_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

const unused_value = 42

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "unused_value")
}

// === Server Type Tests ===

pub fn detects_server_type_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Server { Server(api_key: String) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_server
  let assert True = list.length(analysis.server_fields) == 1
  let assert Ok(field) = list.first(analysis.server_fields)
  let assert True = field.name == "api_key"
}

pub fn no_server_type_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_server
  let assert True = analysis.server_fields == []
}

pub fn server_type_not_in_extracted_client_source_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Server { Server(api_key: String, db_conn: String) }
pub type Msg { Increment }
pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "pub type Model")
  let assert False = string.contains(extracted, "Server")
  let assert False = string.contains(extracted, "api_key")
  let assert False = string.contains(extracted, "db_conn")
}

pub fn init_server_not_in_extracted_client_source_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Server { Server(key: String) }
pub type Msg { Increment }

fn init_server() { Server(key: \"secret\") }

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "init_server")
}

// === Computed Field Tests ===
// Computed fields are detected by signature: pub fn(Model) -> T
// (not view/update/init, not returning Node)

pub fn detects_computed_fields_by_signature_test() {
  let source =
    "
pub type Model { Model(items: List(Int), tax_rate: Float) }
pub type Msg { AddItem }

pub fn subtotal(model: Model) -> Int {
  0
}

pub fn total(model: Model) -> Int {
  0
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddItem -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.computed_fields) == 2
  let names = list.map(analysis.computed_fields, fn(c) { c.name })
  let assert True = list.contains(names, "subtotal")
  let assert True = list.contains(names, "total")
}

pub fn computed_field_return_type_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

pub fn display_count(model: Model) -> String {
  \"count\"
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.computed_fields) == 1
  let assert Ok(field) = list.first(analysis.computed_fields)
  let assert True = field.name == "display_count"
  let assert True = field.return_type == "String"
}

pub fn computed_function_not_in_extracted_client_source_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

pub fn doubled(model: Model) -> Int {
  model.count * 2
}

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "fn doubled")
}

pub fn view_not_detected_as_computed_test() {
  let source =
    "
import beacon
pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) -> beacon.Node(Msg) { beacon.text(\"hi\") }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // view takes Model but returns Node — should NOT be computed
  let names = list.map(analysis.computed_fields, fn(c) { c.name })
  let assert False = list.contains(names, "view")
}

pub fn private_fn_not_computed_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

fn helper(model: Model) -> Int { model.count + 1 }

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // Private fn(Model) -> T is NOT computed (not pub)
  let assert True = analysis.computed_fields == []
}

pub fn non_computed_helper_still_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

fn helper(x: Int) -> Int { x + 1 }

pub fn view(model: Model) { helper(model.count) }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "helper")
}

// === Build Integration / Leak Prevention Tests ===
// End-to-end tests that verify no secrets leak through extract_client_source.
// Tests edge cases: ordering, multiple constants, mixed server/client, etc.

pub fn full_privacy_demo_extraction_test() {
  // Mirrors the privacy_demo example — all features at once
  let source =
    "
import beacon
import beacon/html
import gleam/int
import gleam/list

const server_api_key = \"sk_live_abc\"
const server_db_url = \"postgres://secret\"
const app_title = \"My App\"
const unused_value = 99

pub type Model { Model(count: Int, name: String) }
pub type Server { Server(key: String) }
pub type Item { Item(price: Int) }
pub type Msg { Inc }

pub fn init() -> Model { Model(count: 0, name: \"\") }
pub fn init_server() -> Server { Server(key: server_api_key) }

pub fn subtotal(model: Model) -> Int { model.count }
pub fn total(model: Model) -> Int { model.count + 1 }

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> Model(..model, count: model.count + 1) }
}
pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div([], [html.text(app_title)])
}
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // Server secrets: MUST NOT be in client source
  let assert False = string.contains(extracted, "server_api_key")
  let assert False = string.contains(extracted, "sk_live_abc")
  let assert False = string.contains(extracted, "server_db_url")
  let assert False = string.contains(extracted, "postgres://secret")
  // Server type: MUST NOT be in client source
  let assert False = string.contains(extracted, "pub type Server")
  let assert False = string.contains(extracted, "init_server")
  // Computed functions: MUST NOT be in client source
  let assert False = string.contains(extracted, "fn subtotal")
  let assert False = string.contains(extracted, "fn total")
  // Unreferenced constant: MUST NOT be in client source
  let assert False = string.contains(extracted, "unused_value")
  // Client-safe content: MUST be in client source
  let assert True = string.contains(extracted, "pub type Model")
  let assert True = string.contains(extracted, "pub type Msg")
  let assert True = string.contains(extracted, "pub fn view")
  let assert True = string.contains(extracted, "app_title")
}

pub fn multiple_server_constants_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Inc }

const server_stripe_key = \"sk_live\"
const server_openai_key = \"sk-abc\"
const server_db_password = \"hunter2\"
const color = \"#ff0000\"

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { color }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "server_stripe_key")
  let assert False = string.contains(extracted, "server_openai_key")
  let assert False = string.contains(extracted, "server_db_password")
  let assert False = string.contains(extracted, "hunter2")
  // color IS referenced by view
  let assert True = string.contains(extracted, "color")
  let assert True = string.contains(extracted, "#ff0000")
}

pub fn constant_referenced_by_helper_not_view_test() {
  // Constant used by a pure helper that IS extracted — should be included
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Inc }

const max_value = 999

fn clamp(x: Int) -> Int { max_value }

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { clamp(model.count) }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // clamp is a pure helper used by view — extracted
  let assert True = string.contains(extracted, "clamp")
  // max_value is referenced by clamp — extracted
  let assert True = string.contains(extracted, "max_value")
}

pub fn computed_with_various_return_types_test() {
  let source =
    "
pub type Model { Model(count: Int, name: String, active: Bool, rate: Float) }
pub type Msg { Inc }

pub fn doubled(model: Model) -> Int { model.count * 2 }
pub fn label(model: Model) -> String { model.name }
pub fn is_valid(model: Model) -> Bool { model.active }
pub fn adjusted_rate(model: Model) -> Float { model.rate }

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.computed_fields) == 4
  // Verify return types
  let find_type = fn(name) {
    case list.find(analysis.computed_fields, fn(c) { c.name == name }) {
      Ok(c) -> c.return_type
      Error(_) -> ""
    }
  }
  let assert True = find_type("doubled") == "Int"
  let assert True = find_type("label") == "String"
  let assert True = find_type("is_valid") == "Bool"
  let assert True = find_type("adjusted_rate") == "Float"
}

pub fn update_not_computed_despite_model_param_test() {
  // update takes Model but also takes Msg — NOT computed
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let names = list.map(analysis.computed_fields, fn(c) { c.name })
  let assert False = list.contains(names, "update")
}

pub fn server_constant_definition_excluded_even_if_referenced_test() {
  // server_ prefix ALWAYS excludes the constant DEFINITION from extraction.
  // The view may still reference the name (which will fail JS compilation
  // since the constant won't exist) — but the SECRET VALUE never leaks.
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Inc }

const server_secret = \"leaked?\"

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { server_secret }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // The constant DEFINITION (with the secret value) is excluded
  let assert False = string.contains(extracted, "leaked?")
  // The constant DEFINITION line itself is excluded
  let assert False = string.contains(extracted, "const server_secret")
  // The view references it by name — that's OK, it'll fail JS compilation
  // (the name appears in view source, but the value is never in the bundle)
  let assert True = string.contains(extracted, "pub fn view")
}

pub fn server_type_fields_never_in_analysis_custom_types_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Server { Server(api_key: String, db: String) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // Server should NOT appear in custom_types (it's handled separately)
  let type_names = list.map(analysis.custom_types, fn(ct) { ct.name })
  let assert False = list.contains(type_names, "Server")
  // But has_server should be true
  let assert True = analysis.has_server
  let assert True = list.length(analysis.server_fields) == 2
}

pub fn empty_model_no_computed_test() {
  // Edge case: Model with no fields
  let source =
    "
pub type Model { Model }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.computed_fields == []
}

pub fn client_update_purity_rejects_store_call_test() {
  let source =
    "
import beacon/store

pub type Model { Model(count: Int) }
pub type Msg { Save }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Save -> {
      store.put(store.new(\"bad\"), \"count\", model.count)
      model
    }
  }
}
pub fn view(model: Model) { model }
"
  let assert Error(message) = analyzer.validate_client_update_purity(source)
  let assert True = string.contains(message, "store.put")
  let assert True = string.contains(message, "move this to on_update")
}

pub fn client_update_purity_rejects_random_call_test() {
  let source =
    "
import gleam/int

pub type Model { Model(count: Int) }
pub type Msg { Roll }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Roll -> Model(count: int.random(10))
  }
}
pub fn view(model: Model) { model }
"
  let assert Error(message) = analyzer.validate_client_update_purity(source)
  let assert True = string.contains(message, "int.random")
}

pub fn client_update_purity_rejects_captured_make_update_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Inc }
pub fn make_update(shared: Int) -> fn(Model, Msg) -> Model {
  fn(model: Model, msg: Msg) {
    case msg { Inc -> Model(count: model.count + shared) }
  }
}
pub fn view(model: Model) { model }
"
  let assert Error(message) = analyzer.validate_client_update_purity(source)
  let assert True = string.contains(message, "make_update")
  let assert True = string.contains(message, "on_update")
}

pub fn client_contract_report_lists_state_and_codecs_test() {
  let source =
    "
import beacon/store

pub type Model { Model(count: Int) }
pub type Local { Local(draft: String) }
pub type Server { Server(secret: String) }
pub type Msg {
  Save
  SetDraft(String)
}
pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    Save -> #(Model(count: model.count + 1), local)
    SetDraft(text) -> #(model, Local(draft: text))
  }
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let report = analyzer.client_contract_report(analysis)
  let joined = string.join(report, "\n")
  let assert True = string.contains(joined, "Client contract")
  let assert True = string.contains(joined, "Model: count: Int")
  let assert True = string.contains(joined, "Local: draft: String")
  let assert True = string.contains(joined, "Server: Server")
  let assert True = string.contains(joined, "beacon/store")
  let assert True = string.contains(joined, "Msg.SetDraft: LOCAL")
  let assert True = string.contains(joined, "Generated codecs")
}

pub fn client_contract_summary_counts_client_allowlist_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg {
  Increment
  AdminReset
}
pub type ClientMsg {
  Increment
}
pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    AdminReset -> Model(count: 0)
  }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let summary = analyzer.client_contract_summary(analysis)
  let assert True = string.contains(summary, "ClientMsg=allowlist")
  let assert True = string.contains(summary, "browser messages=1")
  let assert True = string.contains(summary, "server/internal messages=1")
  let assert True = string.contains(summary, "render_model")
}
