//// The client scenario of the benchmark suite: the browser's render and
//// patch work for a 100-row and a 1000-row model, run in node with the
//// code a real build produces.
////
//// `prepare` writes a fixture app project (`build/brazier_bench_client_app`,
//// sources rewritten only when they change, as in build_fixture_test) and
//// builds it with `build.build`, which generates the codecs and the client
//// entry. A generator in the fixture then encodes each model with the
//// server codec, computes the patch the runtime would send for a change of
//// every tenth label and the selection (`patch.diff`), and writes the HTML
//// the server renders for the model before and after it.
////
//// Each run starts node once (bench.mjs). For each size it checks that the
//// client renders exactly the server's HTML before and after the patch,
//// warms up, and times:
////
//// - client.render.rows_N: `render(model, local)` and `event_names`, what
////   `renderNow` does before the morph.
//// - client.patch.rows_N: the patch path of `handlePatch` before the morph:
////   `JSON.parse` of the ops, `applyOps` on the cached model value
////   (brazier_client/patch.mjs, imported from the source), `decode_model`,
////   `render` and `event_names`.
////
//// Every timed call's HTML is checked against the expected length. The
//// DOM morph is not measured: node has no DOM. It is a browser (CDP)
//// measurement.

import brazier/bench/measure.{check}
import brazier/bench/report.{type Metric}
import brazier/build
import brazier/build/files
import brazier/build/program
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

const fixture = "build/brazier_bench_client_app"

/// Where the generator writes the inputs and node the results, relative
/// to the fixture.
const inputs = "build/inputs"

const patch_module = "brazier_client/src/brazier_client/patch.mjs"

/// Each size: #(rows, warm-up calls, timed calls).
fn sizes() -> List(#(Int, Int, Int)) {
  [#(100, 500, 2000), #(1000, 100, 400)]
}

/// The built fixture, ready for `run`.
pub opaque type Fixture {
  Fixture(dir: String)
}

/// Write and build the fixture and generate its inputs.
pub fn prepare() -> Result(Fixture, String) {
  use Nil <- result.try(
    list.try_each(sources(), fn(file) {
      files.write_if_changed(fixture <> "/" <> file.0, file.1)
      |> result.replace(Nil)
    }),
  )
  use manifest <- result.try(files.read("examples/counter/manifest.toml"))
  use _ <- result.try(files.write_if_changed(
    fixture <> "/manifest.toml",
    manifest,
  ))
  use built <- result.try(
    build.build(fixture, build.SourceDir("src"))
    |> result.map_error(fn(reason) { "client fixture build: " <> reason }),
  )
  use <- check(
    built.app.module_path == "bench_rows",
    "the client fixture build found app " <> built.app.module_path,
  )
  use output <- result.try(
    program.run(fixture, "gleam", ["run", "-m", "bench_inputs"]),
  )
  use <- check(
    string.contains(output, "INPUTS OK"),
    "the client fixture generator did not finish:\n" <> output,
  )
  Ok(Fixture(dir: fixture))
}

/// Run node once over every size and turn its samples into metrics.
pub fn run(fixture: Fixture) -> Result(List(Metric), String) {
  let args =
    list.flat_map(sizes(), fn(size) {
      [int.to_string(size.0), int.to_string(size.1), int.to_string(size.2)]
    })
  use output <- result.try(
    program.run(fixture.dir, "node", [
      "bench.mjs",
      inputs,
      program.absolute_path(patch_module),
      ..args
    ]),
  )
  use <- check(
    string.contains(output, "NODE OK"),
    "the client bench did not finish:\n" <> output,
  )
  use text <- result.try(files.read(
    fixture.dir <> "/" <> inputs <> "/results.json",
  ))
  use samples <- result.try(
    json.parse(text, decode.dict(decode.string, decode.list(decode.int)))
    |> result.map_error(fn(e) {
      "the client bench results do not parse: " <> string.inspect(e)
    }),
  )
  list.try_map(sizes(), fn(size) {
    let #(rows, _warmup, timed) = size
    let suffix = ".rows_" <> int.to_string(rows)
    list.try_map(
      ["client.render" <> suffix, "client.patch" <> suffix],
      fn(name) {
        use ns <- result.try(
          dict.get(samples, name)
          |> result.replace_error("the client bench reported no " <> name),
        )
        use <- check(
          list.length(ns) == timed,
          name
            <> ": expected "
            <> int.to_string(timed)
            <> " samples, got "
            <> int.to_string(list.length(ns)),
        )
        measure.median_and_p99(
          name,
          "us",
          list.map(ns, fn(n) { int.to_float(n) /. 1000.0 }),
        )
      },
    )
    |> result.map(list.flatten)
  })
  |> result.map(list.flatten)
}

fn sources() -> List(#(String, String)) {
  [
    #("gleam.toml", gleam_toml),
    #("src/bench_rows.gleam", app_source),
    #("src/bench_inputs.gleam", inputs_source),
    #("bench.mjs", node_source),
  ]
}

const gleam_toml =
  "name = \"brazier_bench_client_app\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"
brazier = { path = \"../..\" }
gleam_json = \">= 3.1.0 and < 4.0.0\"
"

const app_source =
  "//// The client bench app: rows with a click handler each.
import brazier as b
import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html
import gleam/int
import gleam/list

pub type Row {
  Row(id: Int, label: String)
}

pub type Model {
  Model(rows: List(Row), selected: Int)
}

pub type Msg {
  Select(id: Int)
}

pub fn init(_ctx: b.Context) -> Result(Model, b.InitError) {
  Ok(model(1000))
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Select(id:) -> Model(..model, selected: id)
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class(\"rows\")], [
    html.p([], [html.text(\"selected \" <> int.to_string(model.selected))]),
    html.ul(
      [],
      list.map(model.rows, fn(row) {
        html.li(
          [
            attribute.class(case row.id == model.selected {
              True -> \"row selected\"
              False -> \"row\"
            }),
            event.on_click(Select(row.id)),
          ],
          [
            html.span([], [html.text(int.to_string(row.id))]),
            html.span([], [html.text(row.label)]),
          ],
        )
      }),
    ),
  ])
}

/// `rows` rows, none selected.
pub fn model(rows: Int) -> Model {
  Model(
    rows: int.range(from: rows, to: 0, with: [], run: fn(acc, i) {
      [Row(id: i, label: \"row label number \" <> int.to_string(i)), ..acc]
    }),
    selected: 0,
  )
}

/// Every tenth label changed and row 7 selected: the change the patch
/// carries.
pub fn changed(model: Model) -> Model {
  Model(
    rows: list.map(model.rows, fn(row) {
      case row.id % 10 {
        0 -> Row(..row, label: \"changed label \" <> int.to_string(row.id))
        _ -> row
      }
    }),
    selected: 7,
  )
}

pub fn main() {
  b.simple(init:, update:, view:)
  |> b.start(8080)
}
"

const inputs_source =
  "//// Run by the client bench's prepare: for each size, the model as the
//// server encodes it, the patch the runtime sends for `changed`, and the
//// HTML the server renders before and after.
import bench_rows
import brazier/build/files
import brazier/element
import brazier/patch
import brazier_codec
import gleam/int
import gleam/io
import gleam/list

const dir = \"build/inputs\"

fn write(name: String, contents: String) -> Nil {
  let assert Ok(_) = files.write_if_changed(dir <> \"/\" <> name, contents)
    as \"the client bench inputs directory is writable\"
  Nil
}

pub fn main() -> Nil {
  list.each([100, 1000], fn(rows) {
    let n = int.to_string(rows)
    let before = bench_rows.model(rows)
    let after = bench_rows.changed(before)
    let before_json = brazier_codec.encode_model(before)
    let assert Ok(patch.Ops(json: ops)) =
      patch.diff(before_json, brazier_codec.encode_model(after))
      as \"changed models differ, so the diff has ops\"
    write(\"model_\" <> n <> \".json\", before_json)
    write(\"ops_\" <> n <> \".json\", ops)
    write(\"before_\" <> n <> \".html\", element.to_string(bench_rows.view(before)))
    write(\"after_\" <> n <> \".html\", element.to_string(bench_rows.view(after)))
  })
  io.println(\"INPUTS OK\")
}
"

const node_source =
  "// Run by the client bench: time the client's render and patch work with
// the built client entry. Arguments: the inputs directory, the absolute
// path of brazier_client/patch.mjs, then rows, warm-up and timed calls for
// each size. Writes results.json (nanoseconds per call) and prints NODE OK.
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import * as entry from './build/brazier_client_app/build/dev/javascript/brazier_client_app/brazier_app_entry.mjs';

const [dir, patchModule, ...sizeArgs] = process.argv.slice(2);
const { applyOps } = await import(pathToFileURL(patchModule).href);
const fail = (what) => {
  console.error(what);
  process.exit(1);
};
const read = (name) => readFileSync(dir + '/' + name, 'utf8');

if (sizeArgs.length === 0 || sizeArgs.length % 3 !== 0) fail('bad size arguments: ' + sizeArgs);
const results = {};
for (let i = 0; i < sizeArgs.length; i += 3) {
  const [rows, warmup, timed] = sizeArgs.slice(i, i + 3).map(Number);
  const modelValue = JSON.parse(read('model_' + rows + '.json'));
  const opsText = read('ops_' + rows + '.json');
  const before = read('before_' + rows + '.html');
  const after = read('after_' + rows + '.html');
  const decoded = entry.decode_model(modelValue);
  if (!decoded.isOk()) fail('decode_model failed: ' + decoded[0]);
  const model = decoded[0];
  const local = entry.init_local(model);
  const render = () => {
    const [html, handlers] = entry.render(model, local);
    return [html, entry.event_names(handlers).toArray()];
  };
  const patch = () => {
    const next = applyOps(modelValue, JSON.parse(opsText));
    const result = entry.decode_model(next);
    if (!result.isOk()) fail('decode_model of the patched model failed: ' + result[0]);
    const [html, handlers] = entry.render(result[0], local);
    return [html, entry.event_names(handlers).toArray()];
  };
  const expect = (name, out, html) => {
    if (out[0] !== html) fail(name + ': the client HTML is not the server HTML');
    if (!out[1].includes('click')) fail(name + ': event_names lacks click: ' + out[1]);
  };
  expect('render', render(), before);
  expect('patch', patch(), after);
  const time = (name, fn, html) => {
    for (let n = 0; n < warmup; n++) fn();
    const samples = [];
    for (let n = 0; n < timed; n++) {
      const t0 = process.hrtime.bigint();
      const out = fn();
      const t1 = process.hrtime.bigint();
      if (out[0].length !== html.length) fail(name + ': rendered ' + out[0].length + ' bytes');
      samples.push(Number(t1 - t0));
    }
    results[name + '.rows_' + rows] = samples;
  };
  time('client.render', render, before);
  time('client.patch', patch, after);
}
writeFileSync(dir + '/results.json', JSON.stringify(results));
console.log('NODE OK');
"
