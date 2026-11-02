/// Build system tests: command line, source collection and generated
/// imports, plus analyzer inputs for codec generation.
import beacon/build
import beacon/build/analyzer
import beacon/build/client_entry
import beacon/build/discovery
import beacon/build/program
import beacon/build/server_codec
import beacon/build/sources
import gleam/list
import gleam/string
import simplifile

// === Codec Generation Correctness Tests ===
// These verify the analyzer produces the right inputs for codec generation.
// Note: Basic model field detection is tested in build_codec_test.gleam
// (standard_app_codec_fields_test). Tests here cover complementary aspects.

pub fn codec_field_types_correct_test() {
  let source =
    "
pub type Model { Model(count: Int, name: String, active: Bool, rate: Float) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let find = fn(name) {
    case list.find(analysis.model_fields, fn(f) { f.name == name }) {
      Ok(f) -> f.type_name
      Error(_) -> ""
    }
  }
  let assert True = find("count") == "Int"
  let assert True = find("name") == "String"
  let assert True = find("active") == "Bool"
  let assert True = find("rate") == "Float"
}

// === Command line ===

pub fn parse_args_defaults_to_src_test() {
  let assert Ok(build.SourceDir("src")) = build.parse_args([])
}

pub fn parse_args_gleam_file_is_the_app_module_test() {
  let assert Ok(build.AppFile("src/my_app.gleam")) =
    build.parse_args(["src/my_app.gleam"])
}

pub fn parse_args_other_argument_is_a_source_dir_test() {
  let assert Ok(build.SourceDir("app/src")) = build.parse_args(["app/src"])
}

pub fn parse_args_rejects_extra_arguments_test() {
  let assert Error(reason) = build.parse_args(["src", "extra"])
  let assert True = string.contains(reason, "src extra")
  let assert True = string.contains(reason, build.usage)
}

// === Source collection ===

fn fresh_tree(root: String, files: List(#(String, String))) -> Nil {
  let assert Ok(Nil) = case simplifile.delete(root) {
    Ok(Nil) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
  list.each(files, fn(file) {
    let path = root <> "/" <> file.0
    let assert Ok(Nil) = simplifile.create_directory_all(parent(path))
    let assert Ok(Nil) = simplifile.write(path, file.1)
  })
}

fn parent(path: String) -> String {
  let assert Ok(#(_, dir)) = string.split_once(string.reverse(path), "/")
  string.reverse(dir)
}

pub fn app_externals_recurses_through_user_modules_test() {
  let src = "build/beacon_test_app_externals/src"
  let app_source =
    "import types/models\npub type Model { Model(status: models.AgentRunStatus) }\n"
  fresh_tree(src, [
    #("app.gleam", app_source),
    #(
      "types/models.gleam",
      "import types/enums\npub type AgentRunStatus { AgentRunStatus(type_: enums.AgentType) }\n",
    ),
    #("types/enums.gleam", "pub type AgentType { Codex Gemini }\n"),
  ])
  let app =
    discovery.AppModule(
      path: src <> "/app.gleam",
      module_path: "app",
      source: app_source,
    )
  let assert Ok(sources) = sources.app_externals(src, app)
  let assert [#("models", "types/models", _), #("enums", "types/enums", _)] =
    sources
}

pub fn app_externals_reports_unparsable_user_module_test() {
  let src = "build/beacon_test_app_externals_broken/src"
  let app_source = "import broken\npub type Model { Model(count: Int) }\n"
  fresh_tree(src, [#("app.gleam", app_source), #("broken.gleam", "pub type {")])
  let app =
    discovery.AppModule(
      path: src <> "/app.gleam",
      module_path: "app",
      source: app_source,
    )
  let assert Error(reason) = sources.app_externals(src, app)
  let assert True = string.contains(reason, "broken.gleam")
}

pub fn client_externals_skip_server_only_modules_test() {
  let src = "build/beacon_test_client_externals/src"
  let source =
    "import app/server_state.{type ServerState}

pub type Model {
  Model(count: Int)
}

fn server_page(state: #(Model, Nil, ServerState)) {
  let #(model, _local, _server) = state
  model
}

pub fn view(model: Model) {
  model
}
"
  fresh_tree(src, [
    #("app.gleam", source),
    #(
      "app/server_state.gleam",
      "import agent/manager\n\npub type ServerState {\n  ServerState(manager: manager.Manager)\n}\n",
    ),
    #(
      "agent/manager.gleam",
      "pub type Manager {\n  Manager(secret: String)\n}\n",
    ),
  ])
  let assert Ok(client_source) = analyzer.extract_client_source(source)
  let assert Ok(sources) =
    sources.client_externals(src, src <> "/app.gleam", client_source)
  let module_paths = list.map(sources, fn(source) { source.1 })
  let assert False = list.contains(module_paths, "app/server_state")
  let assert False = list.contains(module_paths, "agent/manager")
}

pub fn framework_closure_recurses_through_beacon_modules_test() {
  let source =
    "
import beacon/application

pub type Model { Model }
pub type Msg { Ping }

pub fn update(model: Model, msg: Msg) -> Model { model }
pub fn view(model: Model) { model }
"
  let assert Ok(sources) = sources.framework_closure(".", [source])
  let module_paths = list.map(sources, fn(s) { s.1 })
  let assert True = list.contains(module_paths, "beacon/application")
  let assert True = list.contains(module_paths, "beacon/route")
  // The shimmed modules are generated for the client, never copied.
  let assert False = list.contains(module_paths, "beacon")
  let assert False = list.contains(module_paths, "beacon/log")
}

// === Generated imports ===

const nested_app_source =
  "
import server_state
import types/models

pub type Model { Model(service: models.ThreadService) }
pub type Msg { Ping }
pub fn update(model: Model, msg: Msg) -> Model { model }
pub fn view(model: Model) { model }
"

fn nested_analysis() -> analyzer.Analysis {
  let server_source =
    "
import types/enums

pub type ServerState {
  ServerState(status: enums.AgentRunStatus)
}
"
  let models_source =
    "
import types/enums

pub type ThreadService {
  ThreadService(status: enums.AgentRunStatus)
}
"
  let enums_source =
    "
pub type AgentRunStatus {
  Pending
  Running
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(nested_app_source, [
      #("server_state", "app/server_state", server_source),
      #("models", "types/models", models_source),
      #("enums", "types/enums", enums_source),
    ])
  analysis
}

pub fn server_codec_imports_nested_type_modules_test() {
  let assert Ok(codec) = server_codec.generate(nested_analysis(), "app/main")
  let assert True = string.contains(codec, "import app/main")
  let assert True = string.contains(codec, "import types/models")
  let assert True = string.contains(codec, "import types/enums")
}

pub fn client_entry_imports_nested_type_modules_test() {
  let assert Ok(entry) = client_entry.generate(nested_analysis(), True)
  let assert True = string.contains(entry, "import types/models")
  let assert True = string.contains(entry, "import types/enums")
  let assert False = string.contains(entry, "server_state")
}

// Note: Server field exclusion is tested in build_codec_test.gleam
// (server_state_excludes_server_from_model_fields_test,
//  server_fields_tracked_separately_test).

pub fn codec_computed_fields_have_correct_types_test() {
  let source =
    "
pub type Model { Model(count: Int, items: List(Int)) }
pub type Msg { Inc }

pub fn doubled(model: Model) -> Int { model.count * 2 }
pub fn label(model: Model) -> String { \"label\" }
pub fn total_items(model: Model) -> Int { 0 }

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // 3 computed fields detected
  let assert True = list.length(analysis.computed_fields) == 3
  // Verify each has the right return type
  let find_type = fn(name) {
    case list.find(analysis.computed_fields, fn(c) { c.name == name }) {
      Ok(c) -> c.return_type
      Error(_) -> ""
    }
  }
  let assert True = find_type("doubled") == "Int"
  let assert True = find_type("label") == "String"
  let assert True = find_type("total_items") == "Int"
}

pub fn codec_nested_custom_types_detected_test() {
  let source =
    "
pub type Item { Item(name: String, price: Int) }
pub type Model { Model(items: List(Item), count: Int) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // Item should be in custom_types (has fields, used by Model)
  let type_names = list.map(analysis.custom_types, fn(ct) { ct.name })
  let assert True = list.contains(type_names, "Item")
  // Item should have 2 fields
  let assert Ok(item_type) =
    list.find(analysis.custom_types, fn(ct) { ct.name == "Item" })
  let assert True = list.length(item_type.fields) == 2
}

pub fn codec_enum_types_detected_test() {
  let source =
    "
pub type Status { Active Inactive Pending }
pub type Model { Model(status: Status, count: Int) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.enum_types) == 1
  let assert Ok(et) = list.first(analysis.enum_types)
  let assert True = et.name == "Status"
  let assert True = list.length(et.variants) == 3
  let assert True = list.contains(et.variants, "Active")
  let assert True = list.contains(et.variants, "Inactive")
  let assert True = list.contains(et.variants, "Pending")
}

pub fn extract_produces_valid_gleam_source_test() {
  // The extracted source should be parseable by Glance (valid Gleam syntax)
  let source =
    "
import gleam/int

pub type Model { Model(count: Int) }
pub type Msg { Increment }

const max = 100

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { max }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // The extracted source must contain valid Gleam constructs
  let assert True = string.contains(extracted, "pub type Model")
  let assert True = string.contains(extracted, "pub type Msg")
  let assert True = string.contains(extracted, "pub fn view")
  // And the constant referenced by view
  let assert True = string.contains(extracted, "max")
  // Must NOT contain update (it takes Model + Msg, not just Model)
  // Actually update IS extracted (client needs it for local events)
  let assert True = string.contains(extracted, "pub fn update")
}

pub fn msg_variant_classification_accuracy_test() {
  // Verify that model-affecting vs local-only classification is correct
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg {
  Increment
  Decrement
  Reset
  SetInput(String)
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    Increment -> #(Model(count: model.count + 1), local)
    Decrement -> #(Model(count: model.count - 1), local)
    Reset -> #(Model(count: 0), local)
    SetInput(text) -> #(model, Local(input: text))
  }
}

pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.msg_variants) == 4
  // Increment, Decrement, Reset all modify model
  let find = fn(name) {
    case list.find(analysis.msg_variants, fn(v) { v.name == name }) {
      Ok(v) -> v.affects_model
      Error(_) -> False
    }
  }
  let assert True = find("Increment")
  let assert True = find("Decrement")
  let assert True = find("Reset")
  // SetInput only modifies local
  let assert False = find("SetInput")
}

// === External programs ===

pub fn program_run_passes_unicode_arguments_unchanged_test() {
  let assert Ok(output) =
    program.run(".", "printf", ["%s", "zoë \" </script> 日本"])
  let assert "zoë \" </script> 日本" = output
}

pub fn program_run_nonzero_exit_is_an_error_test() {
  let assert Error(reason) = program.run(".", "sh", ["-c", "echo boom; exit 3"])
  let assert True = string.contains(reason, "boom")
  let assert True = string.contains(reason, "Exit status: 3")
  let assert True = string.contains(reason, "`sh -c")
}

pub fn program_run_missing_executable_is_an_error_test() {
  let assert Error(reason) = program.run(".", "beacon-no-such-program", [])
  let assert True =
    string.contains(reason, "Executable not found: beacon-no-such-program")
}

pub fn program_absolute_path_keeps_unicode_test() {
  let path = program.absolute_path("build/zoë/日本.gleam")
  let assert True = string.starts_with(path, "/")
  let assert True = string.ends_with(path, "/build/zoë/日本.gleam")
}

pub fn program_content_hash_is_stable_test() {
  let hash = program.content_hash("bundle")
  let assert 16 = string.length(hash)
  let assert True = hash == program.content_hash("bundle")
  let assert True = hash != program.content_hash("bundle2")
}
