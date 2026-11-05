/// Tests for the build's stream checks (docs/design/STREAMS.md 10): literal
/// and unique names, named item functions, client code limited to the
/// client half of `brazier/stream`, and the stream lists the build writes
/// into the server codec, the client entry and the contract report.
import brazier/attribute
import brazier/build/analyzer.{type Analysis, StreamDecl}
import brazier/build/client_entry
import brazier/build/contract
import brazier/build/files
import brazier/build/server_codec
import brazier/build/sources
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- helpers -----------------------------------------------------------------

/// The analyzer indexes `brazier/stream` with the user modules, as the build
/// does (`sources.pruned_framework_sources`).
fn stream_source() -> #(String, String) {
  let assert Ok(text) = files.read("src/brazier/stream.gleam")
  #("brazier/stream", text)
}

fn analyze(modules: List(#(String, String))) -> Result(Analysis, String) {
  analyzer.analyze("app", [stream_source(), ..modules])
}

fn analyze_app(app: String) -> Analysis {
  let assert Ok(analysis) = analyze([#("app", app)])
  analysis
}

fn analyze_error(modules: List(#(String, String))) -> String {
  let assert Error(reason) = analyze(modules)
  reason
}

fn assert_contains(haystack: String, needle: String) -> Nil {
  let assert True = string.contains(haystack, needle)
    as { "expected to find " <> needle <> " in:\n" <> haystack }
  Nil
}

fn client_source(analysis: Analysis, path: String) -> String {
  let assert Ok(emitted) = list.find(analysis.client, fn(e) { e.path == path })
    as { "no emitted client module " <> path }
  emitted.source
}

/// An application with one stream, `log`, filled by `update` and rendered
/// by `view` with the named item function `render_line`.
const app =
  "import brazier
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/stream.{type Stream}
import gleam/dynamic/decode
import gleam/json

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Add
}

pub type Line {
  Line(id: String, text: String)
}

pub fn log() -> Stream(Line) {
  stream.new(
    \"log\",
    key: line_key,
    encode: encode_line,
    decoder: line_decoder(),
    limit: stream.KeepLast(300),
  )
}

pub fn line_key(line: Line) -> String {
  line.id
}

pub fn encode_line(line: Line) -> json.Json {
  json.object([#(\"id\", json.string(line.id)), #(\"text\", json.string(line.text))])
}

pub fn line_decoder() -> decode.Decoder(Line) {
  use id <- decode.field(\"id\", decode.string)
  use text <- decode.field(\"text\", decode.string)
  decode.success(Line(id:, text:))
}

pub fn init(_ctx: brazier.Context) -> #(Model, Effect(Msg)) {
  #(Model(count: 0), effect.none())
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Add -> #(
      Model(count: model.count + 1),
      stream.insert(log(), Line(id: \"1\", text: \"hi\"), at: stream.Append),
    )
  }
}

pub fn view(_model: Model) -> Element(Msg) {
  html.div([], [
    html.button([event.on_click(Add)], [html.text(\"add\")]),
    stream.render(log(), \"ol\", [], render_line),
  ])
}

pub fn render_line(line: Line) -> Element(Msg) {
  html.li([], [html.text(line.text)])
}

pub fn main() {
  brazier.application(init:, update:, view:) |> brazier.start(8080)
}
"

const render_call = "stream.render(log(), \"ol\", [], render_line)"

fn with_render(source: String, render: String) -> String {
  string.replace(source, render_call, render)
}

// --- accepted apps -----------------------------------------------------------

pub fn declared_stream_is_listed_test() {
  let analysis = analyze_app(app)
  let assert [StreamDecl(name: "log", at:, item_type: Some(item_type))] =
    analysis.streams
  assert_contains(at, "app.gleam:")
  let assert "app.Line" = item_type
}

pub fn unannotated_stream_has_no_item_type_test() {
  let analysis =
    analyze_app(string.replace(
      app,
      "pub fn log() -> Stream(Line) {",
      "pub fn log() {",
    ))
  let assert [StreamDecl(name: "log", item_type: None, ..)] = analysis.streams
}

/// `app` with `log`'s return annotation replaced by `annotation`, and
/// `extra` appended (imports go first, so `extra_imports` is separate).
fn with_annotation(
  annotation: String,
  extra_imports: String,
  extra: String,
) -> String {
  app
  |> string.replace(
    "pub fn log() -> Stream(Line) {",
    "pub fn log() -> " <> annotation <> " {",
  )
  |> string.replace(
    "import gleam/json\n",
    "import gleam/json\n" <> extra_imports,
  )
  |> string.append(extra)
}

fn item_type_of(source: String) -> option.Option(String) {
  let assert [StreamDecl(name: "log", item_type:, ..)] =
    analyze_app(source).streams
  item_type
}

pub fn a_dependency_item_type_is_qualified_test() {
  // A stream's items are carried by its own encode and decoder, not by a
  // generated codec, so a dependency's type is a valid item type.
  let source =
    with_annotation(
      "Stream(timestamp.Timestamp)",
      "import gleam/time/timestamp\n",
      "",
    )
  let assert Some("gleam/time/timestamp.Timestamp") = item_type_of(source)
}

pub fn prelude_and_imported_item_types_are_written_test() {
  let source =
    with_annotation(
      "Stream(#(Option(Line), Result(Int, String)))",
      "import gleam/option.{type Option}\n",
      "",
    )
  let assert Some("#(gleam/option.Option(app.Line), Result(Int, String))") =
    item_type_of(source)
}

pub fn an_item_type_through_type_aliases_is_resolved_test() {
  let plain =
    with_annotation("LogStream", "", "\npub type LogStream = Stream(Line)\n")
  let assert Some("app.Line") = item_type_of(plain)
  let generic =
    with_annotation("Of(Line)", "", "\npub type Of(item) = Stream(item)\n")
  let assert Some("app.Line") = item_type_of(generic)
}

pub fn an_owner_that_returns_no_stream_has_no_item_type_test() {
  // The owner's annotation is not a `Stream` (the build reads annotations,
  // not inferred types), so it names no item type.
  let source = with_annotation("#(Stream(Line), Int)", "", "")
  let assert None = item_type_of(source)
}

pub fn an_unresolved_item_type_is_refused_test() {
  let reason =
    analyze_error([#("app", with_annotation("Stream(Missing)", "", ""))])
  assert_contains(reason, "app.gleam:")
  assert_contains(
    reason,
    "the stream \"log\": the return annotation `Stream(Missing)` of `app.log` does not name the item type: type `Missing` is not defined in app or imported unqualified",
  )
}

pub fn an_item_type_from_a_module_not_imported_is_refused_test() {
  let reason =
    analyze_error([#("app", with_annotation("Stream(nope.Line)", "", ""))])
  assert_contains(
    reason,
    "`nope.Line` uses module `nope`, which app does not import",
  )
}

pub fn an_item_type_hole_is_refused_test() {
  let reason = analyze_error([#("app", with_annotation("Stream(_)", "", ""))])
  assert_contains(
    reason,
    "the return annotation `Stream(_)` of `app.log` does not name the item type: the type hole `_` names no type",
  )
}

pub fn an_item_type_variable_is_refused_test() {
  let reason =
    analyze_error([#("app", with_annotation("Stream(item)", "", ""))])
  assert_contains(reason, "the type variable `item` names no concrete type")
}

pub fn a_stream_with_two_type_arguments_is_refused_test() {
  let reason =
    analyze_error([#("app", with_annotation("Stream(Line, Int)", "", ""))])
  assert_contains(
    reason,
    "the return annotation `Stream(Line, Int)` of `app.log` cannot be read: `Stream` takes one type argument, the item type; found 2",
  )
}

pub fn app_without_streams_lists_none_test() {
  let source =
    "import brazier
import brazier/element.{type Element}
import brazier/event
import brazier/html

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Add
}

pub fn init(_ctx: brazier.Context) -> Model {
  Model(count: 0)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Add -> Model(count: model.count + 1)
  }
}

pub fn view(_model: Model) -> Element(Msg) {
  html.button([event.on_click(Add)], [html.text(\"add\")])
}

pub fn main() {
  brazier.simple(init:, update:, view:) |> brazier.start(8080)
}
"
  let analysis = analyze_app(source)
  let assert [] = analysis.streams
  let assert Ok(codec) = server_codec.generate(analysis)
  assert_contains(codec, "pub fn stream_names() -> List(String) {\n[]")
  let assert False =
    list.any(analysis.client, fn(e) { e.path == "brazier/stream" })
}

pub fn emitted_stream_module_holds_only_reached_definitions_test() {
  let analysis = analyze_app(app)
  let source = client_source(analysis, "brazier/stream")
  assert_contains(source, "pub fn new(")
  assert_contains(source, "pub fn render(")
  // The ops run only on the server; the effect module is Erlang-only.
  let assert False = string.contains(source, "fn insert(")
  let assert False = string.contains(source, "fn reset(")
  let assert False = string.contains(source, "brazier/effect")
}

pub fn piped_and_captured_render_is_accepted_test() {
  let piped =
    analyze_app(with_render(
      app,
      "log() |> stream.render(\"ol\", [], render_line)",
    ))
  let assert [StreamDecl(name: "log", ..)] = piped.streams
  let captured =
    analyze_app(with_render(
      app,
      "log() |> stream.render(_, \"ol\", [], render_line)",
    ))
  let assert [StreamDecl(name: "log", ..)] = captured.streams
}

pub fn qualified_item_from_a_user_module_is_accepted_test() {
  let lines =
    "import brazier/element.{type Element}
import brazier/html

pub fn render_text(text: String) -> Element(msg) {
  html.li([], [html.text(text)])
}
"
  let source =
    app
    |> string.replace(
      "import gleam/json\n",
      "import gleam/json\nimport lines\n",
    )
    |> with_render("stream.render(log(), \"ol\", [], line_item)")
    |> string.append(
      "\npub fn line_item(line: Line) -> Element(Msg) {\n  lines.render_text(line.text)\n}\n",
    )
  let assert Ok(analysis) = analyze([#("app", source), #("lines", lines)])
  let assert [StreamDecl(name: "log", ..)] = analysis.streams
}

// --- the container's attribute -----------------------------------------------

/// `app` with the view's `div` given `attributes`, `import_line` added.
fn with_div_attributes(import_line: String, attributes: String) -> String {
  app
  |> string.replace("import gleam/json\n", "import gleam/json\n" <> import_line)
  |> string.replace(
    "  html.div([], [\n",
    "  html.div([" <> attributes <> "], [\n",
  )
}

pub fn the_stream_attribute_on_an_element_is_refused_test() {
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute\n",
          "attribute.attribute(\"data-brazier-stream\", \"log\")",
        ),
      ),
    ])
  assert_contains(reason, "app.gleam:")
  assert_contains(
    reason,
    "`attribute.attribute(\"data-brazier-stream\", ..)` sets data-brazier-stream, which marks a stream's container",
  )
  assert_contains(reason, "Only `stream.render` sets it")
}

pub fn the_stream_attribute_through_data_in_any_case_is_refused_test() {
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute.{data}\n",
          "data(\"Brazier-Stream\", \"log\")",
        ),
      ),
    ])
  assert_contains(
    reason,
    "`attribute.data(\"Brazier-Stream\", ..)` sets data-brazier-stream",
  )
}

pub fn the_stream_attribute_in_server_code_is_refused_test() {
  // The scan covers every module of the app, not only client code.
  let server =
    "import brazier/attribute

pub fn mark() -> attribute.Attribute(msg) {
  \"data-brazier-stream\" |> attribute.attribute(\"log\")
}
"
  let reason = analyze_error([#("app", app), #("server_only", server)])
  assert_contains(reason, "server_only.gleam:")
  assert_contains(reason, "sets data-brazier-stream")
}

pub fn other_data_attributes_are_accepted_test() {
  // A `data-brazier-` name that is app API, and names outside the prefix.
  let analysis =
    analyze_app(with_div_attributes(
      "import brazier/attribute\n",
      "attribute.data(\"Brazier-Hook\", \"x\"), attribute.attribute(\"data-stream\", \"log\"), attribute.data(\"brazierkey\", \"k\")",
    ))
  let assert [StreamDecl(name: "log", ..)] = analysis.streams
}

pub fn the_key_attribute_on_an_element_is_refused_test() {
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute\n",
          "attribute.attribute(\"data-brazier-key\", \"k\")",
        ),
      ),
    ])
  assert_contains(reason, "app.gleam:")
  assert_contains(
    reason,
    "`attribute.attribute(\"data-brazier-key\", ..)` sets data-brazier-key, which gives an element its identity",
  )
  assert_contains(reason, "`element.keyed(key, child)`")
}

pub fn a_reserved_event_attribute_through_a_constant_is_refused_test() {
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute\n\nconst click = \"Brazier-On-Click\"\n",
          "attribute.data(click, \"1\")",
        ),
      ),
    ])
  assert_contains(
    reason,
    "`attribute.data(\"Brazier-On-Click\", ..)` (the name is the constant `click`) sets data-brazier-on-click, a name Brazier reserves for its client",
  )
  assert_contains(
    reason,
    "data-brazier-external, data-brazier-hook, data-brazier-hook-watch, data-brazier-preserve-children",
  )
}

pub fn a_reserved_name_brazier_may_add_later_is_refused_test() {
  // The whole prefix is reserved, not only the names the client reads today.
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute\n",
          "attribute.boolean(\"data-brazier-\" <> \"future\", False)",
        ),
      ),
    ])
  assert_contains(
    reason,
    "`attribute.boolean(\"data-brazier-future\", ..)` (the name is a concatenation) sets data-brazier-future, a name Brazier reserves for its client",
  )
}

pub fn the_stream_attribute_through_a_constant_is_refused_test() {
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute\n\nconst container = \"data-brazier-stream\"\n",
          "attribute.attribute(container, \"log\")",
        ),
      ),
    ])
  assert_contains(
    reason,
    "`attribute.attribute(\"data-brazier-stream\", ..)` (the name is the constant `container`) sets data-brazier-stream",
  )
}

pub fn the_stream_attribute_through_another_modules_constants_is_refused_test() {
  // A qualified constant of another app module, itself a `<>` of a
  // constant and a literal.
  let names =
    "pub const prefix = \"data-brazier-\"

pub const container = prefix <> \"Stream\"
"
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute\nimport names\n",
          "attribute.attribute(names.container, \"log\")",
        ),
      ),
      #("names", names),
    ])
  assert_contains(
    reason,
    "`attribute.attribute(\"data-brazier-Stream\", ..)` (the name is the constant `names.container`) sets data-brazier-stream",
  )
}

pub fn the_stream_attribute_through_an_unqualified_constant_is_refused_test() {
  let names = "pub const container = \"brazier-stream\"\n"
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute\nimport names.{container}\n",
          "attribute.data(container, \"log\")",
        ),
      ),
      #("names", names),
    ])
  assert_contains(
    reason,
    "`attribute.data(\"brazier-stream\", ..)` (the name is the constant `container`) sets data-brazier-stream",
  )
}

pub fn the_stream_attribute_through_a_concatenation_is_refused_test() {
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute\n",
          "attribute.data(\"brazier-\" <> \"stream\", \"log\")",
        ),
      ),
    ])
  assert_contains(
    reason,
    "`attribute.data(\"brazier-stream\", ..)` (the name is a concatenation) sets data-brazier-stream",
  )
}

pub fn the_stream_attribute_through_boolean_is_refused_test() {
  let reason =
    analyze_error([
      #(
        "app",
        with_div_attributes(
          "import brazier/attribute\n",
          "attribute.boolean(\"data-brazier-stream\", True)",
        ),
      ),
    ])
  assert_contains(
    reason,
    "`attribute.boolean(\"data-brazier-stream\", ..)` sets data-brazier-stream",
  )
}

/// A local variable shadows the constant of the same name: its value is
/// not known to the build.
pub fn a_parameter_shadowing_a_constant_is_not_read_test() {
  let source =
    with_div_attributes(
      "import brazier/attribute\n\nconst name = \"data-brazier-stream\"\n",
      "named(\"data-x\")",
    )
    <> "\npub fn named(name: String) -> attribute.Attribute(Msg) {\n  attribute.attribute(name, \"log\")\n}\n\npub fn unused() -> String {\n  name\n}\n"
  let analysis = analyze_app(source)
  let assert [StreamDecl(name: "log", ..)] = analysis.streams
}

/// A name computed when the view runs is not refused by the build: every
/// helper that forwards a name would be. The attribute's constructor
/// refuses the container's attribute then, however the name was built.
pub fn a_computed_name_is_refused_when_the_view_runs_test() {
  let source =
    with_div_attributes("import brazier/attribute\n", "named(\"data-x\")")
    <> "\npub fn named(name: String) -> attribute.Attribute(Msg) {\n  attribute.attribute(name, \"log\")\n}\n"
  let analysis = analyze_app(source)
  let assert [StreamDecl(name: "log", ..)] = analysis.streams
  let computed = "data-" <> string.lowercase("BRAZIER") <> "-stream"
  let assert Error(#("error", _)) =
    rescue(fn() { attribute.attribute(computed, "log") })
  let assert Error(#("error", _)) =
    rescue(fn() { attribute.boolean(string.uppercase(computed), True) })
  let assert Error(#("error", _)) =
    rescue(fn() { attribute.data(string.drop_start(computed, 5), "log") })
}

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))

// --- generated exports -------------------------------------------------------

pub fn server_codec_exports_stream_names_test() {
  let assert Ok(codec) = server_codec.generate(analyze_app(app))
  assert_contains(codec, "pub fn stream_names() -> List(String) {\n[\"log\"]")
}

pub fn stream_names_are_sorted_test() {
  let source =
    app
    |> string.append(
      "\npub fn alerts() -> Stream(Line) {\n  stream.new(\"alerts\", key: line_key, encode: encode_line, decoder: line_decoder(), limit: stream.KeepFirst(10))\n}\n",
    )
  let analysis = analyze_app(source)
  let assert ["alerts", "log"] = server_codec.stream_names(analysis)
}

pub fn client_entry_exports_the_stream_functions_test() {
  let assert Ok(entry) = client_entry.generate(analyze_app(app))
  assert_contains(entry, "pub fn stream_names() -> List(String) {\n[\"log\"]")
  assert_contains(entry, "render_containers(")
  assert_contains(entry, "pub fn container_name(")
  assert_contains(entry, "pub fn container_keep(")
  assert_contains(entry, "pub fn container_limit(")
  assert_contains(entry, "pub fn container_item(")
  assert_contains(entry, "pub fn render_item(")
}

pub fn contract_lists_the_streams_test() {
  let analysis = analyze_app(app)
  let report = contract.report("src/app.gleam", analysis)
  assert_contains(
    report,
    "\"streams\":[{\"name\":\"log\",\"item_type\":\"app.Line\",\"at\":\"",
  )
}

// --- refused names -----------------------------------------------------------

pub fn non_literal_name_is_refused_test() {
  let source =
    string.replace(app, "    \"log\",\n    key:", "    log_name(),\n    key:")
    |> string.append("\nfn log_name() -> String {\n  \"log\"\n}\n")
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "app.gleam:")
  assert_contains(
    reason,
    "the name of a stream must be a string literal in the `stream.new` call, not a function call",
  )
}

pub fn invalid_literal_name_is_refused_test() {
  let source = string.replace(app, "    \"log\",\n", "    \"Log-1\",\n")
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "the stream name \"Log-1\" is not valid")
}

pub fn duplicate_name_is_refused_test() {
  let source =
    app
    |> string.append(
      "\npub fn other_log() -> Stream(Line) {\n  stream.new(\"log\", key: line_key, encode: encode_line, decoder: line_decoder(), limit: stream.KeepLast(5))\n}\n",
    )
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "The stream name \"log\" is declared more than once")
}

pub fn duplicate_name_across_modules_is_refused_test() {
  let other =
    "import brazier/stream.{type Stream}
import gleam/dynamic/decode
import gleam/json

pub fn other() -> Stream(String) {
  stream.new(
    \"log\",
    key: fn(s: String) { s },
    encode: json.string,
    decoder: decode.string,
    limit: stream.KeepLast(5),
  )
}
"
  let source =
    string.replace(
      app,
      "import gleam/json\n",
      "import gleam/json\nimport other\n",
    )
    |> string.append(
      "\npub fn other_log() -> Stream(String) {\n  other.other()\n}\n",
    )
  let reason = analyze_error([#("app", source), #("other", other)])
  assert_contains(reason, "is declared more than once")
  assert_contains(reason, "app.gleam:")
  assert_contains(reason, "other.gleam:")
}

// --- refused item functions --------------------------------------------------

pub fn anonymous_item_function_is_refused_test() {
  let reason =
    analyze_error([
      #(
        "app",
        with_render(
          app,
          "stream.render(log(), \"ol\", [], fn(line) { render_line(line) })",
        ),
      ),
    ])
  assert_contains(
    reason,
    "the item function of `stream.render` must be a named top-level function",
  )
  assert_contains(reason, "not an anonymous function")
}

pub fn captured_item_function_is_refused_test() {
  let source =
    with_render(
      app,
      "stream.render(log(), \"ol\", [], render_tagged(_, \"x\"))",
    )
    |> string.append(
      "\npub fn render_tagged(line: Line, tag: String) -> Element(Msg) {\n  html.li([], [html.text(tag <> line.text)])\n}\n",
    )
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "not a function capture")
}

pub fn local_variable_item_is_refused_test() {
  let source =
    string.replace(
      app,
      "pub fn view(_model: Model) -> Element(Msg) {\n",
      "pub fn view(_model: Model) -> Element(Msg) {\n  let item = render_line\n",
    )
    |> with_render("stream.render(log(), \"ol\", [], item)")
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "not the local variable `item`")
}

pub fn constant_item_is_refused_test() {
  let source =
    with_render(app, "stream.render(log(), \"ol\", [], renderer)")
    |> string.append("\nconst renderer = render_line\n")
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "not the constant `renderer`")
}

pub fn piped_anonymous_item_is_refused_test() {
  let reason =
    analyze_error([
      #(
        "app",
        with_render(
          app,
          "log() |> stream.render(\"ol\", [], fn(l) { render_line(l) })",
        ),
      ),
    ])
  assert_contains(reason, "not an anonymous function")
}

/// `app` importing `widgets`, a module the analyzer is not given: a
/// dependency's, whose source the build does not read.
fn with_dependency(import_line: String, render: String) -> String {
  app
  |> string.replace("import gleam/json\n", "import gleam/json\n" <> import_line)
  |> with_render(render)
}

pub fn qualified_item_from_a_dependency_is_refused_test() {
  let source =
    with_dependency(
      "import widgets\n",
      "stream.render(log(), \"ol\", [], widgets.render_line)",
    )
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "app.gleam:")
  assert_contains(
    reason,
    "the item function of `stream.render` is `widgets.render_line`, from widgets, which the build does not analyze",
  )
  assert_contains(reason, "Wrap it in a named function of an app module")
}

pub fn unqualified_item_from_a_dependency_is_refused_test() {
  let source =
    with_dependency(
      "import widgets.{render_row}\n",
      "stream.render(log(), \"ol\", [], render_row)",
    )
  let reason = analyze_error([#("app", source)])
  assert_contains(
    reason,
    "the item function of `stream.render` is `render_row`, from widgets",
  )
}

pub fn item_from_a_brazier_module_is_refused_test() {
  // Brazier's own modules are not analyzed either (only `brazier/stream`).
  let reason =
    analyze_error([
      #("app", with_render(app, "stream.render(log(), \"ol\", [], html.text)")),
    ])
  assert_contains(
    reason,
    "the item function of `stream.render` is `html.text`, from brazier/html",
  )
}

pub fn every_refusal_is_reported_together_test() {
  let source =
    string.replace(app, "    \"log\",\n", "    \"Bad\",\n")
    |> with_render("stream.render(log(), \"ol\", [], fn(l) { render_line(l) })")
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "the stream name \"Bad\" is not valid")
  assert_contains(reason, "not an anonymous function")
}

// --- client code -------------------------------------------------------------

pub fn stream_op_in_client_code_is_refused_test() {
  let source =
    string.replace(
      app,
      "pub fn view(_model: Model) -> Element(Msg) {\n",
      "pub fn view(_model: Model) -> Element(Msg) {\n  let _op = stream.delete_key(log(), \"1\")\n",
    )
  let reason = analyze_error([#("app", source)])
  assert_contains(
    reason,
    "`brazier/stream.delete_key`, which runs only on the server",
  )
}

pub fn stream_used_as_a_value_is_refused_test() {
  let source =
    app
    |> string.append(
      "\npub fn renderer() -> fn(Stream(Line), String, List(a), fn(Line) -> Element(Msg)) -> Element(Msg) {\n  stream.render\n}\n",
    )
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "`stream.render` is used as a value")
}

pub fn simple_app_rendering_a_stream_is_refused_test() {
  let source =
    app
    |> string.replace(
      "pub fn init(_ctx: brazier.Context) -> #(Model, Effect(Msg)) {\n  #(Model(count: 0), effect.none())\n}",
      "pub fn init(_ctx: brazier.Context) -> Model {\n  Model(count: 0)\n}",
    )
    |> string.replace(
      "pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {\n  case msg {\n    Add -> #(\n      Model(count: model.count + 1),\n      stream.insert(log(), Line(id: \"1\", text: \"hi\"), at: stream.Append),\n    )\n  }\n}",
      "pub fn update(model: Model, msg: Msg) -> Model {\n  case msg {\n    Add -> Model(count: model.count + 1)\n  }\n}",
    )
    |> string.replace("import brazier/effect.{type Effect}\n", "")
    |> string.replace("brazier.application(", "brazier.simple(")
  let reason = analyze_error([#("app", source)])
  assert_contains(reason, "a `brazier.simple` app renders a stream")
}

// --- framework modules -------------------------------------------------------

pub fn other_framework_module_is_refused_test() {
  let reason =
    analyze_error([
      #("app", app),
      #("brazier/effect", "pub fn none() { Nil }\n"),
    ])
  assert_contains(
    reason,
    "Invariant violated: the Brazier module brazier/effect",
  )
}

pub fn framework_closure_skips_the_pruned_stream_module_test() {
  let assert Ok(closure) =
    sources.framework_closure(".", [
      "import brazier/stream\nimport brazier/internal/stream_op\n",
    ])
  let paths = list.map(closure, fn(source) { source.0 })
  let assert True = list.contains(paths, "brazier/internal/stream_op")
  let assert False = list.contains(paths, "brazier/stream")
  // brazier/stream's own imports (brazier/effect) are not followed either.
  let assert False = list.contains(paths, "brazier/effect")
}

pub fn pruned_framework_sources_reads_the_stream_module_test() {
  let assert Ok([#("brazier/stream", text)]) =
    sources.pruned_framework_sources(".")
  assert_contains(text, "pub fn render(")
}
