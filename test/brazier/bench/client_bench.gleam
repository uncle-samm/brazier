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
////
//// The stream scenarios (docs/design/STREAMS.md 16) use a second fixture,
//// `build/brazier_bench_stream_app`: a view holding a full `KeepLast(300)`
//// stream of 1 KB lines. Its generator applies the app's own stream ops
//// with the server's stream windows (`stream_window.apply_update`) and
//// writes the `streams` field of the frames the runtime sends: the 300
//// lines `init` inserts, the append of line 301 (one insert, one trim)
//// and a grown line 300 (one update in place). It also writes the HTML the
//// server renders for the inserted and the updated line
//// (`render.render_item`). Node (stream_bench.mjs) fills a store with the
//// first frame, then times, for one frame applied to that store:
////
//// - client.stream.append.300 and client.stream.chunk.300: `JSON.parse`
////   of the field, `decodeStreams` and `applyEntry`
////   (brazier_client/stream.mjs, imported from the source), and
////   `render_item` with `event_names` for every inserted or updated item,
////   what `applyFrameStreams` does before the DOM work.
////
//// Every timed call's item HTML must equal the server's.

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

const stream_fixture = "build/brazier_bench_stream_app"

const stream_module = "brazier_client/src/brazier_client/stream.mjs"

/// The stream frames: #(name, warm-up calls, timed calls).
fn stream_frames() -> List(#(String, Int, Int)) {
  [#("append", 500, 2000), #("chunk", 500, 2000)]
}

/// Each size: #(rows, warm-up calls, timed calls). The 1000-row size
/// times 1000 calls so its p99 is the tenth slowest, not the fourth.
fn sizes() -> List(#(Int, Int, Int)) {
  [#(100, 500, 2000), #(1000, 100, 1000)]
}

/// The built fixture, ready for `run`.
pub opaque type Fixture {
  Fixture(dir: String, stream_dir: String)
}

/// Write and build the fixtures and generate their inputs.
pub fn prepare() -> Result(Fixture, String) {
  use Nil <- result.try(prepare_fixture(
    fixture,
    sources(),
    "bench_rows",
    "bench_inputs",
  ))
  use Nil <- result.try(prepare_fixture(
    stream_fixture,
    stream_sources(),
    "bench_stream",
    "bench_stream_inputs",
  ))
  Ok(Fixture(dir: fixture, stream_dir: stream_fixture))
}

/// Write the fixture project at `dir`, build it (the build must find app
/// `app_module`) and run its `generator`, which prints INPUTS OK.
fn prepare_fixture(
  dir: String,
  sources: List(#(String, String)),
  app_module: String,
  generator: String,
) -> Result(Nil, String) {
  use Nil <- result.try(
    list.try_each(sources, fn(file) {
      files.write_if_changed(dir <> "/" <> file.0, file.1)
      |> result.replace(Nil)
    }),
  )
  use manifest <- result.try(files.read("examples/counter/manifest.toml"))
  use _ <- result.try(files.write_if_changed(dir <> "/manifest.toml", manifest))
  use built <- result.try(
    build.build(dir, build.SourceDir("src"))
    |> result.map_error(fn(reason) { dir <> " build: " <> reason }),
  )
  use <- check(
    built.app.module_path == app_module,
    "the " <> dir <> " build found app " <> built.app.module_path,
  )
  use output <- result.try(program.run(dir, "gleam", ["run", "-m", generator]))
  use <- check(
    string.contains(output, "INPUTS OK"),
    "the " <> dir <> " generator did not finish:\n" <> output,
  )
  Ok(Nil)
}

/// Run node once over every size, and once over every stream frame, and
/// turn their samples into metrics.
pub fn run(fixture: Fixture) -> Result(List(Metric), String) {
  use rows <- result.try(rows_run(fixture))
  use streams <- result.try(stream_run(fixture))
  Ok(list.append(rows, streams))
}

fn rows_run(fixture: Fixture) -> Result(List(Metric), String) {
  let args =
    list.flat_map(sizes(), fn(size) {
      [int.to_string(size.0), int.to_string(size.1), int.to_string(size.2)]
    })
  use patch_path <- result.try(
    program.absolute_path(patch_module)
    |> result.map_error(fn(reason) { "the client patch module: " <> reason }),
  )
  use output <- result.try(
    program.run(fixture.dir, "node", ["bench.mjs", inputs, patch_path, ..args]),
  )
  use <- check(
    string.contains(output, "NODE OK"),
    "the client bench did not finish:\n" <> output,
  )
  use samples <- result.try(read_results(fixture.dir))
  list.try_map(sizes(), fn(size) {
    let #(rows, _warmup, timed) = size
    let suffix = ".rows_" <> int.to_string(rows)
    list.try_map(
      ["client.render" <> suffix, "client.patch" <> suffix],
      fn(name) { metrics_of(samples, name, timed) },
    )
    |> result.map(list.flatten)
  })
  |> result.map(list.flatten)
}

fn stream_run(fixture: Fixture) -> Result(List(Metric), String) {
  let args =
    list.flat_map(stream_frames(), fn(frame) {
      [frame.0, int.to_string(frame.1), int.to_string(frame.2)]
    })
  use stream_path <- result.try(
    program.absolute_path(stream_module)
    |> result.map_error(fn(reason) { "the client stream module: " <> reason }),
  )
  use output <- result.try(
    program.run(fixture.stream_dir, "node", [
      "stream_bench.mjs",
      inputs,
      stream_path,
      ..args
    ]),
  )
  use <- check(
    string.contains(output, "NODE OK"),
    "the client stream bench did not finish:\n" <> output,
  )
  use samples <- result.try(read_results(fixture.stream_dir))
  list.try_map(stream_frames(), fn(frame) {
    let #(name, _warmup, timed) = frame
    metrics_of(samples, "client.stream." <> name <> ".300", timed)
  })
  |> result.map(list.flatten)
}

/// The nanosecond samples node wrote to `dir`'s results.json, by metric.
fn read_results(dir: String) -> Result(dict.Dict(String, List(Int)), String) {
  use text <- result.try(files.read(dir <> "/" <> inputs <> "/results.json"))
  json.parse(text, decode.dict(decode.string, decode.list(decode.int)))
  |> result.map_error(fn(e) {
    "the client bench results of "
    <> dir
    <> " do not parse: "
    <> string.inspect(e)
  })
}

/// The median and p99, in microseconds, of `name`'s `timed` samples.
fn metrics_of(
  samples: dict.Dict(String, List(Int)),
  name: String,
  timed: Int,
) -> Result(List(Metric), String) {
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

fn stream_sources() -> List(#(String, String)) {
  [
    #("gleam.toml", stream_gleam_toml),
    #("src/bench_stream.gleam", stream_app_source),
    #("src/bench_stream_inputs.gleam", stream_inputs_source),
    #("stream_bench.mjs", stream_node_source),
  ]
}

const stream_gleam_toml =
  "name = \"brazier_bench_stream_app\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"
brazier = { path = \"../..\" }
gleam_json = \">= 3.1.0 and < 4.0.0\"
"

/// The same line, stream and item as brazier/bench/stream_bench, which the
/// runtime and SSR stream scenarios use.
const stream_app_source =
  "//// The client stream bench app: a full KeepLast(300) stream of 1 KB
//// lines, each with a click handler.
import brazier as b
import brazier/attribute
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/stream.{type Stream}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/string

pub const limit = 300

pub const line_bytes = 1024

pub type Line {
  Line(id: String, text: String)
}

pub type Model {
  Model(picked: String)
}

pub type Msg {
  Picked(id: String)
}

pub fn log() -> Stream(Line) {
  stream.new(
    \"bench_log\",
    key: fn(line: Line) { line.id },
    encode: encode_line,
    decoder: line_decoder(),
    limit: stream.KeepLast(limit),
  )
}

pub fn encode_line(line: Line) -> json.Json {
  json.object([
    #(\"id\", json.string(line.id)),
    #(\"text\", json.string(line.text)),
  ])
}

fn line_decoder() -> decode.Decoder(Line) {
  use id <- decode.field(\"id\", decode.string)
  use text <- decode.field(\"text\", decode.string)
  decode.success(Line(id:, text:))
}

/// Line `n` with `bytes` bytes of text, which holds characters the render
/// escapes.
pub fn line(n: Int, bytes: Int) -> Line {
  let id = \"k\" <> int.to_string(n)
  Line(id:, text: string.pad_end(\"line \" <> id <> \" <&> \", bytes, \"x\"))
}

/// The ops `init` returns: lines 1 to `limit`.
pub fn fill() -> Effect(Msg) {
  let lines =
    int.range(from: limit, to: 0, with: [], run: fn(acc, n) {
      [line(n, line_bytes), ..acc]
    })
  stream.insert_many(log(), lines, at: stream.Append)
}

/// The ops of one append: line `n` at the end.
pub fn append(n: Int) -> Effect(Msg) {
  stream.insert(log(), line(n, line_bytes), at: stream.Append)
}

/// The ops of one chunk: the last line, `grown` bytes longer.
pub fn chunk(grown: Int) -> Effect(Msg) {
  stream.insert(log(), line(limit, line_bytes + grown), at: stream.Append)
}

pub fn init(_ctx: b.Context) -> Result(#(Model, Effect(Msg)), b.InitError) {
  Ok(#(Model(picked: \"\"), fill()))
}

pub fn update(_model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Picked(id:) -> #(Model(picked: id), effect.none())
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class(\"log\")], [
    html.p([], [html.text(\"picked \" <> model.picked)]),
    stream.render(log(), \"ol\", [], render_line),
  ])
}

pub fn render_line(line: Line) -> Element(Msg) {
  html.li([attribute.class(\"line\")], [
    html.span([attribute.class(\"id\")], [html.text(line.id)]),
    html.span([attribute.class(\"text\")], [html.text(line.text)]),
    html.button([event.on_click(Picked(line.id))], [html.text(\"Pick\")]),
  ])
}

pub fn main() {
  b.application(init:, update:, view:)
  |> b.start(8080)
}
"

const stream_inputs_source =
  "//// Run by the client stream bench's prepare: the streams field of the
//// frames the runtime sends for the app's ops, computed with the server's
//// stream windows, and the HTML the server renders for the items they
//// insert and update.
import bench_stream
import brazier/build/files
import brazier/effect.{type Effect}
import brazier/element
import brazier/internal/render
import brazier/internal/stream_window.{type Windows}
import brazier_codec
import gleam/dynamic/decode
import gleam/io
import gleam/json

const dir = \"build/inputs\"

/// The bytes the chunk frame adds to the last line.
const grown = 100

fn write(name: String, contents: String) -> Nil {
  let assert Ok(_) = files.write_if_changed(dir <> \"/\" <> name, contents)
    as \"the client stream bench inputs directory is writable\"
  Nil
}

/// Apply `ops` as the runtime applies one update's ops: the windows after
/// and the frame's streams field.
fn apply(
  windows: Windows,
  ops: Effect(bench_stream.Msg),
) -> #(Windows, String) {
  let #(ops, _rest) = effect.take_stream_ops(ops)
  let assert Ok(applied) =
    stream_window.apply_update(windows, ops, stream_window.default_limits())
    as \"the bench ops are within the default stream bounds\"
  let assert [] = applied.refused as \"no bench op is refused\"
  #(applied.windows, applied.streams_json)
}

fn item_html(
  container: render.Container(bench_stream.Msg),
  line: bench_stream.Line,
) -> String {
  let assert Ok(item) =
    json.parse(json.to_string(bench_stream.encode_line(line)), decode.dynamic)
    as \"an encoded line parses\"
  let assert Ok(#(html, _handlers)) =
    render.render_item(container, line.id, item)
    as \"a bench line renders\"
  html
}

pub fn main() -> Nil {
  let model = bench_stream.Model(picked: \"\")
  let #(full, initial) =
    apply(stream_window.new(keep_items: False), bench_stream.fill())
  let #(_, append) = apply(full, bench_stream.append(bench_stream.limit + 1))
  let #(_, chunk) = apply(full, bench_stream.chunk(grown))
  let assert #(_, _, [container]) =
    render.render_containers(element.to_node(bench_stream.view(model)))
    as \"the bench view renders one stream container\"
  let appended =
    bench_stream.line(bench_stream.limit + 1, bench_stream.line_bytes)
  let chunked =
    bench_stream.line(bench_stream.limit, bench_stream.line_bytes + grown)
  write(\"model.json\", brazier_codec.encode_model(model))
  write(\"initial.json\", initial)
  write(\"append.json\", append)
  write(\"chunk.json\", chunk)
  write(\"append.html\", item_html(container, appended))
  write(\"chunk.html\", item_html(container, chunked))
  io.println(\"INPUTS OK\")
}
"

const stream_node_source =
  "// Run by the client bench: time the client's work for one stream frame
// with the built client entry, before the DOM. Arguments: the inputs
// directory, the absolute path of brazier_client/stream.mjs, then a frame
// name, warm-up and timed calls for each frame. Writes results.json
// (nanoseconds per call) and prints NODE OK.
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import * as entry from './build/brazier_client_app/build/dev/javascript/brazier_client_app/brazier_app_entry.mjs';

const [dir, streamModule, ...frameArgs] = process.argv.slice(2);
const { decodeStreams, applyEntry } = await import(pathToFileURL(streamModule).href);
const fail = (what) => {
  console.error(what);
  process.exit(1);
};
const read = (name) => readFileSync(dir + '/' + name, 'utf8');
const names = new Set(entry.stream_names().toArray());

if (frameArgs.length === 0 || frameArgs.length % 3 !== 0) fail('bad frame arguments: ' + frameArgs);
const decoded = entry.decode_model(JSON.parse(read('model.json')));
if (!decoded.isOk()) fail('decode_model failed: ' + decoded[0]);
const model = decoded[0];
const containers = entry.render(model, entry.init_local(model))[2].toArray();
if (containers.length !== 1 || entry.container_name(containers[0]) !== 'bench_log') {
  fail('the view does not render the bench_log container alone');
}
const container = containers[0];

// What applyFrameStreams does with a frame's streams field before the DOM:
// decode it, apply each entry, render every inserted or updated item.
const applyFrame = (store, text) => {
  const frame = decodeStreams(JSON.parse(text));
  if (!frame.ok) fail('the frame does not decode: ' + JSON.stringify(frame.fault));
  const html = [];
  for (const streamEntry of frame.entries) {
    const result = applyEntry(store, streamEntry, names);
    if (!result.ok) fail('the frame does not apply: ' + JSON.stringify(result.fault));
    store = result.store;
    for (const step of result.steps) {
      if (step.op !== 'insert' && step.op !== 'update') continue;
      const rendered = entry.render_item(container, step.key, store.items.get(step.key));
      if (!rendered.isOk()) fail('render_item failed: ' + rendered[0]);
      if (!entry.event_names(rendered[0][1]).toArray().includes('click')) fail('event_names lacks click');
      html.push(rendered[0][0]);
    }
  }
  return [store, html];
};

const [full] = applyFrame(null, read('initial.json'));
if (full.keys.length !== 300) fail('the first frame filled ' + full.keys.length + ' lines');
const results = {};
for (let i = 0; i < frameArgs.length; i += 3) {
  const name = frameArgs[i];
  const [warmup, timed] = frameArgs.slice(i + 1, i + 3).map(Number);
  const text = read(name + '.json');
  const expected = read(name + '.html');
  const check = (out) => {
    if (out[1].length !== 1 || out[1][0] !== expected) fail(name + ': the client item HTML is not the server item HTML');
    if (out[0].keys.length !== 300) fail(name + ': the store holds ' + out[0].keys.length + ' lines');
  };
  check(applyFrame(full, text));
  for (let n = 0; n < warmup; n++) applyFrame(full, text);
  const samples = [];
  for (let n = 0; n < timed; n++) {
    const t0 = process.hrtime.bigint();
    const out = applyFrame(full, text);
    const t1 = process.hrtime.bigint();
    check(out);
    samples.push(Number(t1 - t0));
  }
  results['client.stream.' + name + '.300'] = samples;
}
writeFileSync(dir + '/results.json', JSON.stringify(results));
console.log('NODE OK');
"
