/// End-to-end test of the Beacon build on a fixture app project.
///
/// The fixture app has Dict(String, _), Dict(Int, _), tuple, Option and List
/// fields, uses `on_focus`/`on_blur`, imports beacon under an alias, and sits
/// next to a decoy module that defines a complete app but only mentions
/// `beacon.start` in comments and strings. The test:
///
/// 1. Builds the fixture with `build.build`: discovery, analysis, codec
///    generation, `gleam build`, and the JavaScript client project compiled
///    and bundled with esbuild.
/// 2. Runs `fixture_roundtrip` in the fixture: the server codec encodes a
///    model; node decodes it with the client bundle's generated decoder,
///    re-encodes it and encodes a Msg; the server codec decodes both and
///    checks they equal the originals.
///
/// The fixture project lives in `build/beacon_fixture_app` and its sources
/// are rewritten only when they change, so later runs compile incrementally.
/// It needs `node` and the pinned esbuild (`npx`), like the build itself.
import beacon/build
import beacon/build/client_bundle
import beacon/build/files
import beacon/build/program
import gleam/list
import gleam/string

const fixture = "build/beacon_fixture_app"

/// An eunit test with a timeout in seconds: `{timeout, Seconds, Fun}`.
/// The first run compiles Beacon and its dependencies for the fixture, which
/// takes longer than eunit's default of 5 seconds.
pub type Timeout {
  Timeout(seconds: Int, test_: fn() -> Nil)
}

pub fn fixture_app_builds_and_round_trips_test_() -> Timeout {
  Timeout(120, fn() {
    write_fixture()
    let assert Ok(built) = build.build(fixture, build.SourceDir("src"))
    // Discovery picked the app that calls `b.app`, not the decoy.
    let assert "codec_fixture" = built.app.module_path
    let assert True = built.codec_path == fixture <> "/src/beacon_codec.gleam"
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
    let assert True = string.contains(bundle, "\"focus\"")
    // The view compiled for the JavaScript target against the generated
    // shim, which carries on_focus and on_blur.
    let assert Ok(app_js) =
      files.read(
        fixture
        <> "/"
        <> client_bundle.client_dir
        <> "/build/dev/javascript/beacon_client_app/app.mjs",
      )
    let assert True = string.contains(app_js, "on_focus(")
    let assert True = string.contains(app_js, "on_blur(")
    let assert Ok(output) =
      program.run(fixture, "gleam", ["run", "-m", "fixture_roundtrip"])
    let assert True = string.contains(output, "ROUNDTRIP OK")
    Nil
  })
}

fn write_fixture() -> Nil {
  // The fixture depends on exactly what the counter example does, from the
  // same relative path, so the counter's lock file pins its packages.
  let assert Ok(manifest) = files.read("examples/counter/manifest.toml")
  let sources = [
    #("gleam.toml", gleam_toml),
    #("manifest.toml", manifest),
    #("src/codec_fixture.gleam", app_source),
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
  "name = \"beacon_fixture_app\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"
beacon = { path = \"../..\" }
gleam_json = \">= 3.1.0 and < 4.0.0\"
"

const app_source =
  "//// The fixture app. This comment mentions pub type Model and
//// beacon.start(8080); discovery and analysis must read only the code.
import beacon as b
import beacon/effect
import beacon/html
import gleam/dict.{type Dict}
import gleam/int
import gleam/option.{type Option}

// pub type Model { Old(count: Int) }

pub type Model {
  Model(
    count: Int,
    scores: Dict(String, Int),
    labels: Dict(Int, String),
    pair: #(Int, String),
    tags: List(String),
    note: Option(String),
    focused: Bool,
  )
}

pub type Msg {
  Focused
  Blurred
  SetScore(name: String, score: Int)
}

pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(
    Model(
      count: 0,
      scores: dict.new(),
      labels: dict.new(),
      pair: #(0, \"\"),
      tags: [],
      note: option.None,
      focused: False,
    ),
    effect.none(),
  )
}

pub fn update(model: Model, _local: Nil, _server: Nil, msg: Msg) -> #(Model, Nil, Nil) {
  let model = case msg {
    Focused -> Model(..model, focused: True)
    Blurred -> Model(..model, focused: False)
    SetScore(name:, score:) ->
      Model(..model, count: model.count + 1, scores: dict.insert(model.scores, name, score))
  }
  #(model, Nil, Nil)
}

pub fn view(model: Model, _local: Nil) -> b.Node(Msg) {
  html.div([], [
    html.input([b.on_focus(Focused), b.on_blur(Blurred)]),
    html.button([b.on_click(SetScore(\"a\", model.count + 1))], [
      html.text(int.to_string(dict.size(model.scores))),
    ]),
  ])
}

pub fn main() {
  b.app(init, b.no_local, b.no_server, update, view)
  |> b.start(8080)
}
"

const decoy_source =
  "//// Not the app: it defines Model, Msg, update and view, and mentions
//// beacon.start(8080) only here and in a string.
import beacon
import beacon/html

pub type Model {
  Model
}

pub type Msg {
  Msg
}

pub fn update(model: Model, _msg: Msg) -> Model {
  model
}

pub fn view(_model: Model) -> beacon.Node(Msg) {
  html.text(note)
}

pub const note = \"beacon.app(init) |> beacon.start(8080)\"
"

const roundtrip_source =
  "//// Run by the build fixture test: server encode, node decode and
//// re-encode with the client bundle's code, server decode.
import beacon/build/files
import beacon/build/program
import beacon_codec
import codec_fixture.{Model, SetScore}
import gleam/dict
import gleam/io
import gleam/json
import gleam/option

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
    )
  let server_json = beacon_codec.encode_model(#(model, Nil, Nil))
  let assert Ok(Nil) = files.write(\"build/roundtrip/server.json\", server_json)
  let assert Ok(_) =
    program.run(\".\", \"node\", [\"roundtrip.mjs\", \"build/roundtrip\", tricky])
  let assert Ok(client_json) = files.read(\"build/roundtrip/model.json\")
  let assert Ok(#(decoded, Nil, Nil)) = beacon_codec.decode_model(client_json)
  let assert True = decoded == model
  let assert Ok(msg_json) = files.read(\"build/roundtrip/msg.json\")
  let envelope =
    json.object([#(\"__beacon_msg\", json.string(msg_json))]) |> json.to_string
  let assert Ok(msg) = beacon_codec.decode_event(\"click\", \"h0\", envelope, \"\")
  let assert True = msg == SetScore(name: tricky, score: 7)
  // A model without the optional value and with empty collections.
  let empty =
    Model(..model, scores: dict.new(), labels: dict.new(), tags: [], note: option.None)
  let assert Ok(#(decoded_empty, Nil, Nil)) =
    beacon_codec.decode_model(beacon_codec.encode_model(#(empty, Nil, Nil)))
  let assert True = decoded_empty == empty
  io.println(\"ROUNDTRIP OK\")
}
"

const node_source =
  "// Run by fixture_roundtrip: decode the server's JSON with the client
// bundle's generated decoder, then encode the model and a Msg back.
import { readFileSync, writeFileSync } from 'node:fs';
import * as entry from './build/beacon_client_app/build/dev/javascript/beacon_client_app/beacon_app_entry.mjs';
import * as app from './build/beacon_client_app/build/dev/javascript/beacon_client_app/app.mjs';

const [dir, tricky] = process.argv.slice(2);
const decoded = entry.decode_model(readFileSync(dir + '/server.json', 'utf8'));
if (!decoded.isOk()) {
  console.error('Client decode_model failed: ' + JSON.stringify(decoded[0]));
  process.exit(1);
}
writeFileSync(dir + '/model.json', entry.encode_model(decoded[0], undefined));
writeFileSync(dir + '/msg.json', entry.encode_msg(new app.SetScore(tricky, 7)));
"
