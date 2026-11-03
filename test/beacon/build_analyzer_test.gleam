/// Tests for the build analyzer on in-memory app sources: the app call, the
/// Model and Msg types, what reaches the browser, the message allowlist, and
/// the code generated from the analysis.
import beacon/build/analyzer.{type Analysis}
import beacon/build/app_call
import beacon/build/client_entry
import beacon/build/contract
import beacon/build/server_codec
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string

// --- helpers -----------------------------------------------------------------

const header =
  "import beacon
import beacon/element.{type Element}
import beacon/event
import beacon/html
import gleam/int
"

fn analyze_app(source: String) -> Result(Analysis, String) {
  analyzer.analyze("app", [#("app", source)])
}

fn analyze_error(modules: List(#(String, String))) -> String {
  let assert Error(reason) = analyzer.analyze("app", modules)
  reason
}

fn client_source(analysis: Analysis, path: String) -> String {
  let assert Ok(emitted) = list.find(analysis.client, fn(e) { e.path == path })
  emitted.source
}

fn client_paths(analysis: Analysis) -> List(String) {
  list.map(analysis.client, fn(e) { e.path })
}

fn assert_contains(haystack: String, needle: String) -> Nil {
  let assert True = string.contains(haystack, needle)
    as { "expected to find " <> needle <> " in:\n" <> haystack }
  Nil
}

const counter =
  "import beacon
import beacon/element.{type Element}
import beacon/event
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Decrement
  Reset
}

const step = 1

const audit_token = \"server_audit_token\"

pub fn init(_ctx: beacon.Context) -> Model {
  Model(count: 0)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + step)
    Decrement -> Model(count: model.count - step)
    Reset -> Model(count: 0)
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.button([event.on_click(Decrement)], [html.text(\"-\")]),
    html.text(int.to_string(model.count)),
    html.button([event.on_click(Increment)], [html.text(\"+\")]),
  ])
}

pub fn audit() -> String {
  audit_token
}

pub fn main() {
  beacon.simple(init:, update:, view:) |> beacon.start(8080)
}
"

// --- simple apps -------------------------------------------------------------

pub fn simple_app_is_analyzed_test() {
  let assert Ok(analysis) = analyze_app(counter)
  let assert app_call.Simple = analysis.call.kind
  let assert app_call.FunctionRef("app", "view") = analysis.call.view
  let assert Some(app_call.FunctionRef("app", "update")) = analysis.call.update
  let assert app_call.NoLocal = analysis.call.local
  let assert #("app", "Msg") = analysis.msg
  let assert ["app"] = client_paths(analysis)
}

pub fn simple_app_allows_only_what_view_builds_test() {
  // Reset appears only as a pattern; nothing the browser runs builds it.
  let assert Ok(analysis) = analyze_app(counter)
  let assert True =
    analysis.codecs.allowed
    == set.from_list([#("app", "Increment"), #("app", "Decrement")])
}

pub fn simple_app_emits_view_and_update_only_test() {
  let assert Ok(analysis) = analyze_app(counter)
  let source = client_source(analysis, "app")
  assert_contains(source, "pub fn view(")
  assert_contains(source, "pub fn update(")
  assert_contains(source, "const step")
  let assert False = string.contains(source, "fn init(")
  let assert False = string.contains(source, "fn main(")
  let assert False = string.contains(source, "fn audit(")
  let assert False = string.contains(source, "server_audit_token")
  // Imports only what the emitted code uses.
  let assert False = string.contains(source, "import beacon\n")
}

pub fn simple_update_reaching_a_server_module_is_an_error_test() {
  let app =
    string.replace(
      counter,
      "Increment -> Model(count: model.count + step)",
      "Increment -> Model(count: helpers.bump(model.count))",
    )
    |> string.replace(
      "import gleam/int\n",
      "import gleam/int\nimport helpers\n",
    )
  let helpers =
    "import beacon/effect

pub fn bump(n: Int) -> Int {
  case effect.is_none(effect.none()) {
    True -> n + 1
    False -> n
  }
}
"
  let reason = analyze_error([#("app", app), #("helpers", helpers)])
  assert_contains(reason, "helpers.gleam:")
  assert_contains(reason, "`helpers.bump` uses `beacon/effect.")
  assert_contains(reason, "does not run in the browser")
}

pub fn simple_update_may_use_client_modules_and_packages_test() {
  let app =
    string.replace(
      counter,
      "Reset -> Model(count: 0)",
      "Reset -> Model(count: list.length(list.range(1, 3)))",
    )
    |> string.replace(
      "import gleam/int\n",
      "import gleam/int\nimport gleam/list\n",
    )
  let assert Ok(analysis) = analyze_app(app)
  assert_contains(client_source(analysis, "app"), "import gleam/list")
}

pub fn aliased_import_with_positional_arguments_test() {
  let app =
    counter
    |> string.replace("import beacon\n", "import beacon as b\n")
    |> string.replace("beacon.Context", "b.Context")
    |> string.replace(
      "beacon.simple(init:, update:, view:) |> beacon.start(8080)",
      "b.simple(init, update, view) |> b.start(8080)",
    )
  let assert Ok(analysis) = analyze_app(app)
  let assert app_call.FunctionRef("app", "view") = analysis.call.view
}

// --- application: server-only messages ---------------------------------------

const ping =
  "import beacon
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/event
import beacon/html

pub type Model {
  Model(reply: String)
}

pub type Msg {
  Send
  GotReply(text: String)
}

pub fn init(_ctx: beacon.Context) -> #(Model, Effect(Msg)) {
  #(Model(reply: \"\"), effect.none())
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Send -> #(model, effect.from(fn(dispatch) { dispatch(GotReply(\"pong\")) }))
    GotReply(text:) -> #(Model(reply: text), effect.none())
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.button([event.on_click(Send)], [html.text(model.reply)])
}

pub fn main() {
  beacon.application(init:, update:, view:) |> beacon.start(8080)
}
"

pub fn application_update_stays_on_the_server_test() {
  let assert Ok(analysis) = analyze_app(ping)
  let assert app_call.Application = analysis.call.kind
  let assert None = analysis.call.update
  let source = client_source(analysis, "app")
  let assert False = string.contains(source, "fn update(")
  let assert False = string.contains(source, "effect")
}

pub fn server_built_constructor_is_not_allowed_test() {
  let assert Ok(analysis) = analyze_app(ping)
  let assert True = analysis.codecs.allowed == set.from_list([#("app", "Send")])
  // The server's decoder knows only what the browser can build.
  let assert Ok(codec) = server_codec.generate(analysis)
  assert_contains(codec, "\"Send\"")
  let assert False = string.contains(codec, "GotReply")
}

/// `beacon.presence` and `beacon.on_notification` deliver their payloads
/// as messages, so `Msg` must be able to carry them.
fn ping_with_server_payloads(payloads: String, imports: String) -> String {
  ping
  |> string.replace(
    "  GotReply(text: String)\n",
    "  GotReply(text: String)\n" <> payloads,
  )
  |> string.replace("import beacon/html\n", "import beacon/html\n" <> imports)
}

pub fn presence_and_notification_payloads_may_reach_the_browser_test() {
  let app =
    ping_with_server_payloads(
      "  PresenceChanged(sync.Diff(String))\n  Notified(Notification)\n",
      "import beacon/notification.{type Notification}\nimport beacon/presence/sync\n",
    )
  let assert Ok(analysis) = analyze_app(app)
  // The server builds these messages; the browser can never send them.
  let assert True = analysis.codecs.allowed == set.from_list([#("app", "Send")])
  let assert Ok(codec) = server_codec.generate(analysis)
  let assert False = string.contains(codec, "PresenceChanged")
  let assert False = string.contains(codec, "Notified")
}

pub fn tracker_types_in_msg_are_an_error_test() {
  let app =
    ping_with_server_payloads(
      "  PresenceFailed(presence.PresenceError)\n",
      "import beacon/presence\n",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "uses `beacon/presence.PresenceError`")
  assert_contains(reason, "does not run in the browser")
}

// --- view and annotations ----------------------------------------------------

pub fn view_reaching_a_server_module_is_an_error_test() {
  let app =
    string.replace(
      ping,
      "html.button([event.on_click(Send)], [html.text(model.reply)])",
      "case effect.is_none(effect.none()) { True -> html.text(model.reply) False -> html.text(\"\") }",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "`app.view` uses `beacon/effect.")
}

pub fn private_view_is_an_error_test() {
  let app = string.replace(counter, "pub fn view(", "fn view(")
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "which is not `pub`")
}

pub fn anonymous_view_is_an_error_test() {
  let app =
    string.replace(
      counter,
      "beacon.simple(init:, update:, view:)",
      "beacon.simple(init:, update:, view: fn(model) { view(model) })",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "must name a `pub fn`")
}

pub fn missing_model_annotation_is_an_error_test() {
  let app =
    string.replace(
      counter,
      "pub fn view(model: Model) -> Element(Msg)",
      "pub fn view(model) -> Element(Msg)",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "needs a type annotation on its Model parameter")
}

pub fn missing_return_annotation_is_an_error_test() {
  let app =
    string.replace(
      counter,
      "pub fn view(model: Model) -> Element(Msg)",
      "pub fn view(model: Model)",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "needs a return annotation")
}

pub fn non_custom_msg_type_is_an_error_test() {
  let app =
    counter
    |> string.replace(
      "pub fn view(model: Model) -> Element(Msg) {",
      "pub fn view(model: Model) -> Element(Int) {",
    )
    |> string.replace("event.on_click(Decrement)", "event.on_click(1)")
    |> string.replace("event.on_click(Increment)", "event.on_click(2)")
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "The Msg type must be a custom type")
}

pub fn model_containing_msg_is_an_error_test() {
  let app =
    string.replace(
      counter,
      "Model(count: Int)",
      "Model(count: Int, last: List(Msg))",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "contains the Msg type app.Msg")
}

pub fn framework_type_in_model_is_an_error_test() {
  let app =
    string.replace(
      counter,
      "Model(count: Int)",
      "Model(count: Int, ctx: beacon.Context)",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(
    reason,
    "The Model type app.Model cannot be sent to the browser: field `ctx`",
  )
}

pub fn unsupported_model_field_type_is_an_error_test() {
  let app =
    string.replace(
      counter,
      "Model(count: Int)",
      "Model(count: Int, on_tick: fn(Int) -> Int)",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "field `on_tick`: functions cannot be sent")
}

// --- the app call ------------------------------------------------------------

pub fn main_without_an_app_call_is_an_error_test() {
  let app =
    string.replace(
      counter,
      "beacon.simple(init:, update:, view:) |> beacon.start(8080)",
      "audit()",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "does not reach a call to beacon.simple")
}

pub fn several_app_calls_is_an_error_test() {
  let app =
    string.replace(
      counter,
      "beacon.simple(init:, update:, view:) |> beacon.start(8080)",
      "let first = beacon.simple(init:, update:, view:)
  let second = beacon.simple(init:, update:, view:)
  #(first, second)",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "more than one app constructor call")
}

pub fn missing_main_is_an_error_test() {
  let app = string.replace(counter, "pub fn main()", "pub fn start()")
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "has no `pub fn main`")
}

pub fn view_in_another_module_test() {
  let pages = header <> "import app.{type Model, type Msg, Increment}

pub fn view(model: Model) -> Element(Msg) {
  html.button([event.on_click(Increment)], [html.text(int.to_string(model.count))])
}
"
  let app =
    string.replace(
      counter,
      "beacon.simple(init:, update:, view:)",
      "beacon.simple(init:, update:, view: pages.view)",
    )
    |> string.replace("import gleam/int\n", "import gleam/int\nimport pages\n")
  let assert Ok(analysis) =
    analyzer.analyze("app", [#("app", app), #("pages", pages)])
  let assert app_call.FunctionRef("pages", "view") = analysis.call.view
  let assert #("app", "Msg") = analysis.msg
  let assert ["app", "pages"] = client_paths(analysis)
  let assert True =
    analysis.codecs.allowed == set.from_list([#("app", "Increment")])
}

// --- full_application and the local layer ------------------------------------

const draft_app =
  "import beacon
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/event
import beacon/html
import beacon/local
import gleam/option.{type Option}

pub type State {
  State(model: Model, token: String)
}

pub type Model {
  Model(saved: String)
}

pub type Msg {
  Typed(text: String)
  Save
  Cleared
}

pub type Draft {
  Draft(text: String, last: Option(Msg))
}

pub fn init(_ctx: beacon.Context) -> #(State, Effect(Msg)) {
  #(State(model: Model(saved: \"\"), token: \"server_token\"), effect.none())
}

pub fn update(state: State, _msg: Msg) -> #(State, Effect(Msg)) {
  #(state, effect.none())
}

pub fn sync(state: State) -> Model {
  state.model
}

pub fn local_init(_model: Model) -> Draft {
  Draft(text: \"\", last: option.None)
}

pub fn local_update(_model: Model, draft: Draft, msg: Msg) -> local.Update(Draft) {
  case msg {
    Typed(text:) -> local.handled(Draft(text:, last: option.Some(Cleared)))
    Save | Cleared -> local.forward(draft)
  }
}

pub fn view(model: Model, draft: Draft) -> Element(Msg) {
  html.div([], [
    html.input([event.on_input(Typed)]),
    html.button([event.on_click(Save)], [html.text(model.saved <> draft.text)]),
  ])
}

pub fn main() {
  beacon.full_application(
    init:,
    update:,
    sync:,
    local: local.layer(init: local_init, update: local_update),
    view:,
  )
  |> beacon.start(8080)
}
"

pub fn local_layer_is_resolved_and_emitted_test() {
  let assert Ok(analysis) = analyze_app(draft_app)
  let assert app_call.FullApplication = analysis.call.kind
  let assert app_call.LocalLayer(
    init: app_call.FunctionRef("app", "local_init"),
    update: app_call.FunctionRef("app", "local_update"),
  ) = analysis.call.local
  let source = client_source(analysis, "app")
  assert_contains(source, "pub fn local_init(")
  assert_contains(source, "pub fn local_update(")
  let assert False = string.contains(source, "fn sync(")
  let assert False = string.contains(source, "server_token")
}

pub fn local_layer_built_constructors_are_allowed_test() {
  // Typed is passed to on_input, Save is built by view, Cleared by the
  // local layer.
  let assert Ok(analysis) = analyze_app(draft_app)
  let assert [#("app", "Cleared"), #("app", "Save"), #("app", "Typed")] =
    list.sort(set.to_list(analysis.codecs.allowed), fn(a, b) {
      string.compare(a.1, b.1)
    })
}

pub fn local_none_test() {
  let app =
    draft_app
    |> string.replace(
      "local: local.layer(init: local_init, update: local_update)",
      "local: local.none()",
    )
    |> string.replace(
      "pub fn view(model: Model, draft: Draft) -> Element(Msg) {",
      "pub fn view(model: Model, _local: Nil) -> Element(Msg) {
  let draft = local_init(model)",
    )
  let assert Ok(analysis) = analyze_app(app)
  let assert app_call.NoLocal = analysis.call.local
  let source = client_source(analysis, "app")
  let assert False = string.contains(source, "fn local_update(")
}

pub fn local_layer_not_written_in_the_call_is_an_error_test() {
  let app =
    draft_app
    |> string.replace(
      "local: local.layer(init: local_init, update: local_update),",
      "local: layer(),",
    )
    |> string.replace(
      "pub fn main() {",
      "pub fn layer() {
  local.layer(init: local_init, update: local_update)
}

pub fn main() {",
    )
  let reason = analyze_error([#("app", app)])
  assert_contains(reason, "`local:` must be `local.none()` or `local.layer(")
}

// --- element.map and child modules -------------------------------------------

const child =
  "import beacon/element.{type Element}
import beacon/event
import beacon/html

pub type Model {
  Model(on: Bool)
}

pub type Msg {
  Toggle
  Secret
}

pub fn view(model: Model) -> Element(Msg) {
  html.button([event.on_click(Toggle)], [
    html.text(case model.on {
      True -> \"on\"
      False -> \"off\"
    }),
  ])
}
"

const parent =
  "import beacon
import beacon/element.{type Element}
import child

pub type Model {
  Model(child: child.Model)
}

pub type Msg {
  ChildMsg(child.Msg)
  Other
}

pub fn init(_ctx: beacon.Context) -> Model {
  Model(child: child.Model(on: False))
}

pub fn update(model: Model, _msg: Msg) -> Model {
  model
}

pub fn view(model: Model) -> Element(Msg) {
  element.map(child.view(model.child), ChildMsg)
}

pub fn main() {
  beacon.simple(init:, update:, view:) |> beacon.start(8080)
}
"

pub fn element_map_child_messages_are_allowed_test() {
  let assert Ok(analysis) =
    analyzer.analyze("app", [#("app", parent), #("child", child)])
  let assert ["app", "child"] = client_paths(analysis)
  let assert True =
    analysis.codecs.allowed
    == set.from_list([#("app", "ChildMsg"), #("child", "Toggle")])
  let assert Ok(codec) = server_codec.generate(analysis)
  assert_contains(codec, "import child as beacon_m_child")
  assert_contains(codec, "beacon_m_child.Toggle")
  let assert False = string.contains(codec, "Secret")
  let assert False = string.contains(codec, "\"Other\"")
  let assert Ok(entry) = client_entry.generate(analysis)
  assert_contains(entry, "import child as beacon_m_child")
  assert_contains(entry, "pub fn update(")
}

// --- types in nested user modules --------------------------------------------

pub fn nested_type_modules_are_imported_by_generated_code_test() {
  let app = header <> "import types/models

pub type Model {
  Model(status: models.Status)
}

pub type Msg {
  Refresh
}

pub fn init(_ctx: beacon.Context) -> Model {
  Model(status: models.Status(kind: models.default_kind()))
}

pub fn update(model: Model, _msg: Msg) -> Model {
  model
}

pub fn view(_model: Model) -> Element(Msg) {
  html.button([event.on_click(Refresh)], [html.text(int.to_string(1))])
}

pub fn main() {
  beacon.simple(init:, update:, view:) |> beacon.start(8080)
}
"
  let models =
    "import types/enums

pub type Status {
  Status(kind: enums.Kind)
}

pub fn default_kind() -> enums.Kind {
  enums.Codex
}
"
  let enums = "pub type Kind {\n  Codex\n  Gemini\n}\n"
  let assert Ok(analysis) =
    analyzer.analyze("app", [
      #("app", app),
      #("types/models", models),
      #("types/enums", enums),
    ])
  let assert Ok(codec) = server_codec.generate(analysis)
  assert_contains(codec, "import types/models as beacon_m_types__models")
  assert_contains(codec, "import types/enums as beacon_m_types__enums")
  let assert Ok(entry) = client_entry.generate(analysis)
  assert_contains(entry, "import types/models as beacon_m_types__models")
  assert_contains(entry, "import types/enums as beacon_m_types__enums")
  // The view uses no function of types/models, but the client decodes its
  // types, so its type definitions are emitted.
  let assert True = list.contains(client_paths(analysis), "types/models")
}

// --- externals ---------------------------------------------------------------

fn clock_app() -> String {
  string.replace(
    counter,
    "html.text(int.to_string(model.count)),",
    "html.text(int.to_string(model.count + clock.now())),",
  )
  |> string.replace("import gleam/int\n", "import clock\nimport gleam/int\n")
}

pub fn erlang_only_external_in_client_code_is_an_error_test() {
  let clock =
    "@external(erlang, \"os\", \"system_time\")\npub fn now() -> Int\n"
  let reason = analyze_error([#("app", clock_app()), #("clock", clock)])
  assert_contains(reason, "is implemented only in Erlang")
  assert_contains(reason, "clock.now")
}

pub fn javascript_external_is_emitted_with_its_ffi_file_test() {
  let clock =
    "@external(erlang, \"os\", \"system_time\")
@external(javascript, \"./clock_ffi.mjs\", \"now\")
pub fn now() -> Int
"
  let assert Ok(analysis) =
    analyzer.analyze("app", [#("app", clock_app()), #("clock", clock)])
  let assert Ok(emitted) =
    list.find(analysis.client, fn(e) { e.path == "clock" })
  let assert ["clock_ffi.mjs"] = emitted.ffi_files
}

// --- module set --------------------------------------------------------------

pub fn modules_with_clashing_aliases_are_an_error_test() {
  let reason =
    analyze_error([
      #("app", counter),
      #("a__b", "pub const x = 1\n"),
      #("a/b", "pub const y = 2\n"),
    ])
  assert_contains(reason, "map to the same generated alias")
}

pub fn module_given_twice_is_an_error_test() {
  let reason = analyze_error([#("app", counter), #("app", counter)])
  assert_contains(reason, "given to the analyzer twice")
}

pub fn unparsable_module_is_an_error_test() {
  let reason = analyze_error([#("app", counter), #("broken", "pub fn ( {")])
  assert_contains(reason, "Cannot parse")
  assert_contains(reason, "broken.gleam")
}

// --- reports and generated code ----------------------------------------------

pub fn contract_report_test() {
  let assert Ok(analysis) = analyze_app(counter)
  let report = contract.report("src/app.gleam", analysis)
  assert_contains(report, "\"source\":\"src/app.gleam\"")
  assert_contains(report, "\"kind\":\"simple\"")
  assert_contains(report, "\"view\":\"app.view\"")
  assert_contains(report, "\"client_update\":\"app.update\"")
  assert_contains(report, "\"local\":null")
  assert_contains(report, "\"msg\":\"app.Msg\"")
  assert_contains(
    report,
    "\"client_messages\":[\"app.Decrement\",\"app.Increment\"]",
  )
  assert_contains(report, "\"client_modules\":[\"app\"]")
}

pub fn client_entry_reflects_the_app_kind_test() {
  let assert Ok(simple) = analyze_app(counter)
  let assert Ok(simple_entry) = client_entry.generate(simple)
  assert_contains(simple_entry, "pub fn update(")
  assert_contains(simple_entry, "beacon_m_app.update(model, msg)")
  let assert Ok(application) = analyze_app(ping)
  let assert Ok(application_entry) = client_entry.generate(application)
  let assert False = string.contains(application_entry, "pub fn update(")
  let assert Ok(full) = analyze_app(draft_app)
  let assert Ok(full_entry) = client_entry.generate(full)
  assert_contains(full_entry, "beacon_m_app.local_update(model, local, msg)")
  assert_contains(full_entry, "beacon_m_app.view(model, local)")
}
