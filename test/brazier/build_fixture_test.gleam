/// End-to-end test of the Brazier build on a fixture app project.
///
/// The fixture app is a `full_application` with a local layer, server state
/// holding a secret, a Model with Dict(String, _), Dict(Int, _), tuple,
/// Option, List and nested-module union fields, a Msg constructor only the
/// server builds, and a stream its view renders and its update fills. It
/// imports brazier under an alias and sits next to a
/// decoy module whose `pub fn main` mentions `brazier.simple` without calling
/// it. The test:
///
/// 1. Builds the fixture with `build.build`: discovery, analysis, codec
///    generation, `gleam build`, and the JavaScript client project compiled
///    and bundled with esbuild.
/// 2. Runs `fixture_roundtrip` in the fixture. The server codec encodes
///    models; node decodes them with the client entry, renders the view,
///    runs its handlers and the local layer, and encodes a Msg. The server
///    checks node rendered the same HTML it renders, decodes the Msg, and
///    rejects a server-only constructor. Node also renders a stream item
///    from its JSON, and the server checks it renders the same HTML.
///
/// The fixture project lives in `build/brazier_fixture_app` and its sources
/// are rewritten only when they change, so later runs compile incrementally.
/// It needs `node` and the pinned esbuild (`npx`), like the build itself.
import brazier/build
import brazier/build/client_bundle
import brazier/build/files
import brazier/build/program
import gleam/list
import gleam/string

const fixture = "build/brazier_fixture_app"

/// An eunit test with a timeout in seconds: `{timeout, Seconds, Fun}`.
/// The first run compiles Brazier and its dependencies for the fixture, which
/// takes longer than eunit's default of 5 seconds.
pub type Timeout {
  Timeout(seconds: Int, test_: fn() -> Nil)
}

pub fn fixture_app_builds_and_round_trips_test_() -> Timeout {
  Timeout(180, fn() {
    write_fixture()
    let assert Ok(built) = build.build(fixture, build.SourceDir("src"))
    // Discovery picked the app that calls `b.full_application`, not the decoy.
    let assert "codec_fixture" = built.app.module_path
    let assert True = built.codec_path == fixture <> "/src/brazier_codec.gleam"
    let assert Ok(manifest) =
      files.read(
        fixture
        <> "/"
        <> client_bundle.static_dir
        <> "/"
        <> client_bundle.manifest_file,
      )
    let assert True = manifest == built.bundle.filename
    let assert Ok(bundle) = files.read(built.bundle.path)
    // The server state's secret and the server update never reach the
    // browser.
    let assert False = string.contains(bundle, "sk_fixture_secret")
    let assert Ok(app_js) =
      files.read(
        fixture
        <> "/"
        <> client_bundle.client_dir
        <> "/build/dev/javascript/brazier_client_app/codec_fixture.mjs",
      )
    let assert True = string.contains(app_js, "on_focus(")
    let assert False = string.contains(app_js, "api_key")
    let assert False = string.contains(app_js, "function update(")
    let assert False = string.contains(app_js, "function sync(")
    let assert True = string.contains(app_js, "function local_update(")
    // The client gets brazier/stream's client half only: the stream ops
    // are effects, which run on the server.
    let assert Ok(stream_js) =
      files.read(
        fixture
        <> "/"
        <> client_bundle.client_dir
        <> "/build/dev/javascript/brazier_client_app/brazier/stream.mjs",
      )
    let assert True = string.contains(stream_js, "function render(")
    let assert False = string.contains(stream_js, "function insert(")
    let assert False = string.contains(stream_js, "brazier/effect")
    let assert Ok(output) =
      program.run(fixture, "gleam", ["run", "-m", "fixture_roundtrip"])
    let assert True = string.contains(output, "ROUNDTRIP OK")
    client_project_builds_offline()
    Nil
  })
}

/// The client project is locked to the app's manifest, so building it again
/// needs no Hex: with every proxy pointing at a closed port, `gleam build`
/// there still succeeds. Without the client manifest the same offline build
/// must try to resolve versions and fail, which shows the proxies do cut Hex
/// off and that the manifest is what keeps the build off the network.
fn client_project_builds_offline() -> Nil {
  let client = fixture <> "/" <> client_bundle.client_dir
  let lock = client <> "/manifest.toml"
  let assert Ok(_output) = run_offline(client, "gleam", ["build"])
  let assert Ok(locked) = files.read(lock)
  let assert Ok(Nil) = files.delete_if_exists(lock)
  let unlocked = run_offline(client, "gleam", ["build"])
  let assert Ok(Nil) = files.write(lock, locked)
  let assert Error(reason) = unlocked
  let assert True = string.contains(reason, "Resolving versions")
  Nil
}

/// `program.run` with the HTTP(S) proxies pointing at a closed localhost
/// port, so the program cannot reach Hex.
@external(erlang, "brazier_build_test_ffi", "run_offline")
fn run_offline(
  cwd: String,
  program: String,
  args: List(String),
) -> Result(String, String)

fn write_fixture() -> Nil {
  // The fixture depends on exactly what the counter example does, from the
  // same relative path, so the counter's lock file pins its packages.
  let assert Ok(manifest) = files.read("examples/counter/manifest.toml")
  let sources = [
    #("gleam.toml", gleam_toml),
    #("manifest.toml", manifest),
    #("src/codec_fixture.gleam", app_source),
    #("src/fixture/kinds.gleam", kinds_source),
    #("src/fixture_decoy.gleam", decoy_source),
    #("src/fixture_roundtrip.gleam", roundtrip_source),
    #("roundtrip.mjs", node_source),
  ]
  list.each(sources, fn(file) {
    let assert Ok(_written) =
      files.write_if_changed(fixture <> "/" <> file.0, file.1)
  })
}

const gleam_toml =
  "name = \"brazier_fixture_app\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"
brazier = { path = \"../..\" }
gleam_json = \">= 3.1.0 and < 4.0.0\"
"

const app_source =
  "//// The fixture app. This comment mentions pub type Model and
//// brazier.simple(init, update, view); discovery and analysis read only code.
import brazier as b
import brazier/effect
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/stream.{type Stream}
import fixture/kinds.{type Kind}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}

// pub type Model { Old(count: Int) }

/// Server state. The key is never synced, so it never reaches the browser.
pub type State {
  State(model: Model, api_key: String)
}

pub type Model {
  Model(
    count: Int,
    scores: Dict(String, Int),
    labels: Dict(Int, String),
    pair: #(Int, String),
    tags: List(String),
    note: Option(String),
    focused: Bool,
    kind: Kind,
  )
}

pub type Msg {
  Focused
  Blurred
  SetScore(name: String, score: Int)
  Typed(text: String)
  /// Built only by a server effect.
  GotSecret(key: String)
}

/// The local layer's state: the text being typed.
pub type Draft {
  Draft(text: String)
}

const api_key = \"sk_fixture_secret\"

/// A stream item: the server sends it once and does not keep it.
pub type Line {
  Line(id: String, text: String)
}

pub fn log() -> Stream(Line) {
  stream.new(
    \"log\",
    key: line_key,
    encode: encode_line,
    decoder: line_decoder(),
    limit: stream.KeepLast(50),
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

pub fn render_line(line: Line) -> Element(Msg) {
  html.li([event.on_click(Blurred)], [html.text(line.text)])
}

pub fn init(_ctx: b.Context) -> Result(#(State, effect.Effect(Msg)), b.InitError) {
  let model =
    Model(
      count: 0,
      scores: dict.new(),
      labels: dict.new(),
      pair: #(0, \"\"),
      tags: [],
      note: option.None,
      focused: False,
      kind: kinds.Plain,
    )
  Ok(#(State(model:, api_key:), effect.none()))
}

pub fn update(state: State, msg: Msg) -> #(State, effect.Effect(Msg)) {
  let model = state.model
  case msg {
    Focused -> #(
      State(..state, model: Model(..model, focused: True)),
      effect.from(fn(dispatch) { dispatch(GotSecret(state.api_key)) }),
    )
    Blurred -> #(
      State(..state, model: Model(..model, focused: False)),
      stream.insert(log(), Line(id: int.to_string(model.count), text: \"blurred\"), at: stream.Append),
    )
    SetScore(name:, score:) -> #(
      State(
        ..state,
        model: Model(
          ..model,
          count: model.count + 1,
          scores: dict.insert(model.scores, name, score),
        ),
      ),
      effect.none(),
    )
    Typed(..) | GotSecret(..) -> #(state, effect.none())
  }
}

pub fn sync(state: State) -> Model {
  state.model
}

pub fn local_init(_model: Model) -> Draft {
  Draft(text: \"\")
}

pub fn local_update(_model: Model, draft: Draft, msg: Msg) -> local.Update(Draft) {
  case msg {
    Typed(text:) -> local.handled(Draft(text:))
    Focused | Blurred | SetScore(..) | GotSecret(..) -> local.forward(draft)
  }
}

pub fn view(model: Model, draft: Draft) -> Element(Msg) {
  html.div([], [
    html.input([
      event.on_focus(Focused),
      event.on_blur(Blurred),
      event.on_input(Typed),
    ]),
    html.p([], [html.text(draft.text)]),
    html.p([], [html.text(option.unwrap(model.note, \"-\"))]),
    html.p([], [html.text(case dict.get(model.labels, -7) {
      Ok(label) -> label
      Error(Nil) -> \"no label\"
    })]),
    html.ul([], list.map(model.tags, fn(tag) { html.li([], [html.text(tag)]) })),
    html.p([], [html.text(kinds.describe(model.kind))]),
    html.p([], [html.text(case model.focused {
      True -> \"focused\"
      False -> \"blurred\"
    })]),
    html.button([event.on_click(SetScore(model.pair.1, model.count + 4))], [
      html.text(int.to_string(dict.size(model.scores))),
    ]),
    stream.render(log(), \"ol\", [], render_line),
  ])
}

pub fn main() {
  b.full_application(
    init:,
    update:,
    sync:,
    local: local.layer(init: local_init, update: local_update),
    view:,
  )
  |> b.start(8080)
}
"

const kinds_source =
  "//// A Model field type from a nested user module.
import gleam/int

pub type Kind {
  Plain
  Fancy(level: Int)
}

pub fn describe(kind: Kind) -> String {
  case kind {
    Plain -> \"plain\"
    Fancy(level:) -> \"fancy \" <> int.to_string(level)
  }
}
"

const decoy_source =
  "//// Not the app: its `pub fn main` names brazier.simple without calling it,
//// and brazier.simple(init, update, view) appears only here and in a string.
import brazier
import brazier/element.{type Element}
import brazier/html

pub type Model {
  Model
}

pub type Msg {
  Msg
}

pub fn update(model: Model, _msg: Msg) -> Model {
  model
}

pub fn view(_model: Model) -> Element(Msg) {
  html.text(note)
}

pub const note = \"brazier.simple(init, update, view) |> brazier.start(8080)\"

pub fn main() {
  brazier.simple
}
"

const roundtrip_source =
  "//// Run by the build fixture test: server encode, node decode, render and
//// encode with the client bundle's code, server decode.
import brazier/build/files
import brazier/build/program
import brazier/element
import brazier/internal/render
import brazier_codec
import codec_fixture.{Draft, Line, Model, SetScore}
import fixture/kinds
import gleam/dict
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/option
import gleam/string

const dir = \"build/roundtrip\"

fn write(name: String, contents: String) -> Nil {
  let assert Ok(Nil) = files.write(dir <> \"/\" <> name, contents)
  Nil
}

fn read(name: String) -> String {
  let assert Ok(contents) = files.read(dir <> \"/\" <> name)
  contents
}

pub fn main() -> Nil {
  let tricky = \"quote \\\" backslash \\\\ </script> zoë\"
  let model =
    Model(
      count: 3,
      scores: dict.from_list([#(\"alice\", 1), #(tricky, -2)]),
      labels: dict.from_list([#(1, \"one\"), #(-7, tricky)]),
      pair: #(42, tricky),
      tags: [\"a\", tricky],
      note: option.Some(tricky),
      focused: True,
      kind: kinds.Fancy(level: -1),
    )
  // The same model built in another order, and a different one.
  let reordered =
    Model(..model, scores: dict.from_list([#(tricky, -2), #(\"alice\", 1)]))
  let other = Model(..model, kind: kinds.Fancy(level: 2))
  write(\"server.json\", brazier_codec.encode_model(model))
  write(\"reordered.json\", brazier_codec.encode_model(reordered))
  write(\"other.json\", brazier_codec.encode_model(other))
  write(\"bad.json\", \"{\\\"count\\\": \\\"three\\\"}\")
  let item_json =
    json.to_string(codec_fixture.encode_line(Line(id: \"l1\", text: tricky)))
  write(\"item.json\", item_json)
  let assert [\"log\"] = brazier_codec.stream_names()
  let assert Ok(output) = program.run(\".\", \"node\", [\"roundtrip.mjs\", dir])
  let assert True = string.contains(output, \"NODE OK\")
  // The browser rendered the stream item exactly as the server renders it.
  let #(_html, _handlers, containers) =
    render.render_containers(
      element.to_node(codec_fixture.view(model, Draft(text: \"\"))),
    )
  let assert [container] = containers
  let assert Ok(item) = json.parse(item_json, decode.dynamic)
  let assert Ok(#(item_html, _item_handlers)) =
    render.render_item(container, \"l1\", item)
  let assert True = read(\"item.html\") == item_html
  // The browser rendered the decoded model exactly as the server renders
  // the original.
  let assert True =
    read(\"client.html\")
    == element.to_string(codec_fixture.view(model, Draft(text: \"\")))
  // The click the browser encoded decodes to the Msg the view built.
  let click = read(\"click.json\")
  let assert Ok(msg) = brazier_codec.decode_event(\"click\", \"0\", click, \"\")
  let assert True = msg == SetScore(name: tricky, score: 7)
  // A constructor only the server builds, an unknown one and malformed
  // JSON never decode from a client.
  let assert True = string.contains(click, \"\\\"SetScore\\\"\")
  let refused =
    \"Cannot decode the client message: UnableToDecode([DecodeError(\\\"\"
    <> \"codec_fixture.Msg sent by the client (a constructor the browser builds)\"
    <> \"\\\", \\\"Dict\\\", [\\\"__brazier_msg\\\"])])\"
  let assert Error(secret) =
    brazier_codec.decode_event(
      \"click\",
      \"0\",
      string.replace(click, \"\\\"SetScore\\\"\", \"\\\"GotSecret\\\"\"),
      \"\",
    )
  let assert True = secret == refused
  let assert Error(unknown) =
    brazier_codec.decode_event(
      \"click\",
      \"0\",
      string.replace(click, \"\\\"SetScore\\\"\", \"\\\"Nope\\\"\"),
      \"\",
    )
  let assert True = unknown == refused
  // A missing field and a value of the wrong type name their path.
  let assert True = string.contains(click, \"\\\"tag\\\"\")
  let assert Error(untagged) =
    brazier_codec.decode_event(
      \"click\",
      \"0\",
      string.replace(click, \"\\\"tag\\\"\", \"\\\"tog\\\"\"),
      \"\",
    )
  let assert True =
    untagged
    == \"Cannot decode the client message: UnableToDecode([DecodeError(\\\"Field\\\", \\\"Nothing\\\", [\\\"__brazier_msg\\\", \\\"tag\\\"])])\"
  let assert Error(no_envelope) =
    brazier_codec.decode_event(\"click\", \"0\", \"[]\", \"\")
  let assert True =
    no_envelope
    == \"Cannot decode the client message: UnableToDecode([DecodeError(\\\"Dict\\\", \\\"List\\\", [])])\"
  let assert Error(malformed) =
    brazier_codec.decode_event(\"click\", \"0\", \"{\", \"\")
  let assert True =
    string.starts_with(malformed, \"Cannot decode the client message: \")
  let assert Error(bad_model) = brazier_codec.decode_model(read(\"bad.json\"))
  let assert True =
    bad_model
    == \"Cannot decode the model: UnableToDecode([DecodeError(\\\"Int\\\", \\\"String\\\", [\\\"count\\\"])])\"
  // The server decodes its own encoding, also without the optional value
  // and with empty collections.
  let assert Ok(decoded) =
    brazier_codec.decode_model(brazier_codec.encode_model(model))
  let assert True = decoded == model
  let empty =
    Model(
      ..model,
      scores: dict.new(),
      labels: dict.new(),
      tags: [],
      note: option.None,
      kind: kinds.Plain,
    )
  let assert Ok(decoded_empty) =
    brazier_codec.decode_model(brazier_codec.encode_model(empty))
  let assert True = decoded_empty == empty
  io.println(\"ROUNDTRIP OK\")
}
"

const node_source =
  "// Run by fixture_roundtrip: decode the server's JSON with the client
// entry, render the view, run its handlers and the local layer, and encode
// the clicked Msg back.
import { readFileSync, writeFileSync } from 'node:fs';
import * as entry from './build/brazier_client_app/build/dev/javascript/brazier_client_app/brazier_app_entry.mjs';

const [dir] = process.argv.slice(2);
const fail = (what) => {
  console.error(what);
  process.exit(1);
};
const read = (name) => JSON.parse(readFileSync(dir + '/' + name, 'utf8'));

const decoded = entry.decode_model(read('server.json'));
if (!decoded.isOk()) fail('decode_model failed: ' + decoded[0]);
const model = decoded[0];
const reordered = entry.decode_model(read('reordered.json'));
if (!reordered.isOk() || !entry.same_model(model, reordered[0])) {
  fail('same_model: the reordered model differs');
}
const other = entry.decode_model(read('other.json'));
if (!other.isOk() || entry.same_model(model, other[0])) {
  fail('same_model: a different model is equal');
}
const bad = entry.decode_model(read('bad.json'));
if (bad.isOk()) fail('decode_model accepted a malformed model');
const badExpected =
  'Cannot decode the model: [DecodeError(expected: \"Int\", found: \"String\", path: [\"count\"])]';
if (bad[0] !== badExpected) fail('decode_model error: ' + bad[0]);
if (entry.is_simple()) fail('is_simple is true for a full_application');

const local = entry.init_local(model);
const [html, handlers, containers] = entry.render(model, local);
writeFileSync(dir + '/client.html', html);

// The view's stream container, and one item rendered from its JSON.
const streamNames = entry.stream_names().toArray();
if (streamNames.join(',') !== 'log') fail('stream_names: ' + streamNames);
const found = containers.toArray();
if (found.length !== 1) fail('render found ' + found.length + ' stream containers');
const [container] = found;
if (entry.container_name(container) !== 'log') fail('container_name: ' + entry.container_name(container));
if (entry.container_keep(container) !== 'last') fail('container_keep: ' + entry.container_keep(container));
if (entry.container_limit(container) !== 50) fail('container_limit: ' + entry.container_limit(container));
const again = entry.render(model, local)[2].toArray()[0];
if (entry.container_item(container) !== entry.container_item(again)) {
  fail('container_item differs between two renders of the same view');
}
const item = entry.render_item(container, 'l1', read('item.json'));
if (!item.isOk()) fail('render_item: ' + item[0]);
const [itemHtml, itemHandlers] = item[0];
writeFileSync(dir + '/item.html', itemHtml);
if (!entry.event_names(itemHandlers).toArray().includes('click')) {
  fail('The item has no click handler: ' + itemHtml);
}
if (entry.render_item(container, 'l2', { id: 'l2' }).isOk()) {
  fail('render_item accepted an item its decoder refuses');
}
const names = entry.event_names(handlers).toArray();
for (const name of ['focus', 'blur', 'input', 'click']) {
  if (!names.includes(name)) fail('event_names lacks ' + name + ': ' + names);
}
const handler = (event) => {
  const found = html.match(new RegExp('data-brazier-on-' + event + '=\"([^\"]+)\"'));
  if (!found) fail('No ' + event + ' handler in ' + html);
  const result = entry.lookup_handler(handlers, event, found[1]);
  if (!result.isOk()) fail('lookup_handler found no ' + event + ' handler');
  return result[0];
};
const run = (event, data) => {
  const result = entry.run_handler(handler(event), data);
  if (!result.isOk()) fail('run_handler ' + event + ': ' + result[0]);
  return result[0];
};

// A decoder failure is an error, not a dropped or made-up message.
if (entry.run_handler(handler('input'), {}).isOk()) {
  fail('run_handler accepted an input event without a target');
}

// The local layer keeps typing in the browser and forwards the rest.
const typed = run('input', { target: { value: 'draft text' } });
const [drafted, typedForwarded] = entry.update_local(model, local, typed);
if (typedForwarded) fail('Typed was forwarded to the server');
if (!entry.render(model, drafted)[0].includes('<p>draft text</p>')) {
  fail('The local draft is not rendered');
}
const click = run('click', {});
const [, clickForwarded] = entry.update_local(model, drafted, click);
if (!clickForwarded) fail('SetScore was not forwarded to the server');
writeFileSync(dir + '/click.json', entry.encode_msg(click));
console.log('NODE OK');
"
