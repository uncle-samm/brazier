/// Tests for the client-side build pieces: the generated `brazier/log` shim,
/// app module discovery, bundle publishing, the framework FFI files the
/// client project gets, the warnings its compile refuses, placed in the
/// sources Brazier sliced them from, and the app's own warnings, logged at
/// their places in the app's files.
import brazier/build/client_bundle
import brazier/build/client_shim
import brazier/build/discovery
import brazier/build/program
import brazier/build/reach
import brazier/build/source_map
import brazier/build/sources
import brazier/log_capture
import glance
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import simplifile

const scratch = "build/brazier_build_client_test"

fn fresh_dir(name: String) -> String {
  let dir = scratch <> "/" <> name
  let assert Ok(Nil) = case simplifile.delete(dir) {
    Ok(Nil) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  dir
}

fn write(dir: String, path: String, contents: String) -> Nil {
  let full = dir <> "/" <> path
  let assert [_, ..parents] = string.split(full, "/") |> list.reverse
  let assert Ok(Nil) =
    simplifile.create_directory_all(list.reverse(parents) |> string.join("/"))
  let assert Ok(Nil) = simplifile.write(full, contents)
  Nil
}

/// Public functions of a parsed module: name -> arity.
fn public_functions(module: glance.Module) -> dict.Dict(String, Int) {
  module.functions
  |> list.filter(fn(def) { def.definition.publicity == glance.Public })
  |> list.map(fn(def) {
    #(def.definition.name, list.length(def.definition.parameters))
  })
  |> dict.from_list
}

fn parse_file(path: String) -> glance.Module {
  let assert Ok(source) = simplifile.read(path)
  let assert Ok(module) = glance.module(source)
  module
}

pub fn log_shim_matches_server_log_api_test() {
  let server = public_functions(parse_file("src/brazier/log.gleam"))
  let assert Ok(shim) = glance.module(client_shim.log_module)
  // configure and set_level set up the Erlang logger; client code never
  // calls them.
  let expected =
    server
    |> dict.delete("configure")
    |> dict.delete("set_level")
  let assert True = public_functions(shim) == expected
  let assert True = dict.size(expected) == 4
}

// --- discovery ---------------------------------------------------------------

/// The parts of an app module other than `main`. It only needs to parse.
const app_body =
  "
pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

pub fn init(_ctx) {
  Model(0)
}

pub fn update(model, _msg) {
  model
}

pub fn view(model) {
  model
}
"

pub fn discovery_aliased_import_test() {
  let dir = fresh_dir("aliased")
  write(
    dir,
    "a_helper.gleam",
    "import brazier as b\n" <> app_body <> "pub fn other() { b.title }\n",
  )
  write(
    dir,
    "main_app.gleam",
    "import brazier as b\n"
      <> app_body
      <> "pub fn main() { b.simple(init, update, view) |> b.start(8080) }\n",
  )
  let assert Ok(app) = discovery.find(dir)
  let assert True = app.path == dir <> "/main_app.gleam"
  let assert "main_app" = app.module_path
}

pub fn discovery_unqualified_import_test() {
  let dir = fresh_dir("unqualified")
  write(dir, "other.gleam", "import brazier\n" <> app_body)
  write(
    dir,
    "web/app.gleam",
    "import brazier.{application}\n"
      <> app_body
      <> "pub fn main() { application(init:, update:, view:) }\n",
  )
  let assert Ok(app) = discovery.find(dir)
  let assert "web/app" = app.module_path
}

pub fn discovery_follows_main_into_helpers_test() {
  let dir = fresh_dir("helper_call")
  write(
    dir,
    "app.gleam",
    "import brazier.{full_application as full}\n"
      <> app_body
      <> "fn build() { full(init, update, Nil, Nil, view) }\npub fn main() { build() }\n",
  )
  let assert Ok(app) = discovery.find(dir)
  let assert "app" = app.module_path
}

pub fn discovery_ignores_calls_main_does_not_reach_test() {
  let dir = fresh_dir("unreached_call")
  write(
    dir,
    "app.gleam",
    "import brazier\n"
      <> app_body
      <> "pub fn app() { brazier.simple(init, update, view) }\npub fn main() { Nil }\n",
  )
  let assert Error(reason) = discovery.find(dir)
  let assert True = string.contains(reason, "No app module found in " <> dir)
}

pub fn discovery_ignores_private_main_test() {
  let dir = fresh_dir("private_main")
  write(
    dir,
    "app.gleam",
    "import brazier\n"
      <> app_body
      <> "fn main() { brazier.simple(init, update, view) }\n",
  )
  let assert Error(reason) = discovery.find(dir)
  let assert True = string.contains(reason, "No app module found")
}

pub fn discovery_ignores_entrypoint_in_comments_and_strings_test() {
  let dir = fresh_dir("comment_entrypoint")
  write(
    dir,
    "a.gleam",
    "import brazier\n// pub fn main() { brazier.simple(init, update, view) }\n"
      <> app_body
      <> "pub const doc = \"brazier.simple(init, update, view)\"\npub fn main() { doc }\n",
  )
  let assert Error(reason) = discovery.find(dir)
  let assert True = string.contains(reason, "No app module found in " <> dir)
}

pub fn discovery_ignores_other_modules_named_brazier_test() {
  // `simple` from a module other than `brazier` is not an app constructor.
  let dir = fresh_dir("other_simple")
  write(
    dir,
    "app.gleam",
    "import brazier_extra\n"
      <> app_body
      <> "pub fn main() { brazier_extra.simple(init, update, view) }\n",
  )
  let assert Error(_) = discovery.find(dir)
}

pub fn discovery_several_apps_is_an_error_test() {
  let dir = fresh_dir("several")
  let main =
    "import brazier\n"
    <> app_body
    <> "pub fn main() { brazier.simple(init, update, view) }\n"
  write(dir, "a.gleam", main)
  write(dir, "b.gleam", main)
  let assert Error(reason) = discovery.find(dir)
  let assert True = string.contains(reason, "Several modules")
  let assert True = string.contains(reason, dir <> "/a.gleam")
  let assert True = string.contains(reason, dir <> "/b.gleam")
}

pub fn discovery_skips_codec_and_framework_modules_test() {
  let dir = fresh_dir("skips")
  let main =
    "import brazier\n"
    <> app_body
    <> "pub fn main() { brazier.simple(init, update, view) }\n"
  write(dir, "brazier_codec.gleam", main)
  write(dir, "brazier/vendored.gleam", main)
  write(dir, "brazier.gleam", main)
  write(dir, "brazier_extra/app.gleam", main)
  let assert Ok(app) = discovery.find(dir)
  // brazier_extra is not Brazier's package; only `brazier` and `brazier/*` are.
  let assert "brazier_extra/app" = app.module_path
}

pub fn discovery_unparsable_module_is_an_error_test() {
  let dir = fresh_dir("unparsable")
  write(dir, "app.gleam", app_body)
  write(dir, "broken.gleam", "pub fn broken( {\n")
  let assert Error(reason) = discovery.find(dir)
  let assert True = string.contains(reason, dir <> "/broken.gleam")
}

pub fn discovery_missing_dir_is_an_error_test() {
  let assert Error(reason) = discovery.find(scratch <> "/does-not-exist")
  let assert True = string.contains(reason, "does-not-exist")
}

pub fn module_path_test() {
  let assert Ok("a/b") = discovery.module_path("src", "src/a/b.gleam")
  let assert Ok("a") = discovery.module_path("src/", "src/a.gleam")
  let assert Error(reason) = discovery.module_path("src", "lib/a.gleam")
  let assert True = string.contains(reason, "lib/a.gleam")
  let assert Error(_) = discovery.module_path("src", "src/a.txt")
  // A sibling directory sharing the prefix is not below the source dir.
  let assert Error(_) = discovery.module_path("src", "src2/a.gleam")
}

// --- bundle publishing -------------------------------------------------------

fn bundles(dir: String) -> List(String) {
  let assert Ok(entries) = simplifile.read_directory(dir)
  entries
  |> list.filter(string.starts_with(_, client_bundle.bundle_prefix))
  |> list.sort(string.compare)
}

pub fn publish_writes_hashed_bundle_and_manifest_test() {
  let dir = fresh_dir("publish")
  let assert Ok(bundle) = client_bundle.publish(dir, "console.log(1);")
  let assert True = string.starts_with(bundle.filename, "brazier_client_")
  let assert True = string.ends_with(bundle.filename, ".js")
  // brazier_client_ + 16 hex digits + .js
  let assert 34 = string.length(bundle.filename)
  let assert True = bundle.path == dir <> "/" <> bundle.filename
  let assert Ok("console.log(1);") = simplifile.read(bundle.path)
  let assert Ok(manifest) =
    simplifile.read(dir <> "/" <> client_bundle.manifest_file)
  let assert True = manifest == bundle.filename
}

pub fn publish_same_contents_same_name_test() {
  let dir = fresh_dir("publish_same")
  let assert Ok(first) = client_bundle.publish(dir, "same")
  let assert Ok(second) = client_bundle.publish(dir, "same")
  let assert True = first == second
  let assert True = bundles(dir) == [first.filename]
}

pub fn publish_replaces_old_bundles_only_test() {
  let dir = fresh_dir("publish_replace")
  write(dir, "app.css", "body {}")
  write(dir, "brazier_client_notes.txt", "kept: not a bundle")
  let assert Ok(old) = client_bundle.publish(dir, "old")
  let assert Ok(new) = client_bundle.publish(dir, "new")
  let assert True = old.filename != new.filename
  let assert True =
    bundles(dir) |> set.from_list
    == set.from_list([new.filename, "brazier_client_notes.txt"])
  let assert Ok("body {}") = simplifile.read(dir <> "/app.css")
  let assert Ok(manifest) =
    simplifile.read(dir <> "/" <> client_bundle.manifest_file)
  let assert True = manifest == new.filename
}

// --- Framework FFI files ---

pub fn framework_ffi_files_copies_the_render_ffi_test() {
  // A view module reaches `brazier/internal/render`, whose name checks and
  // escapers are JavaScript externals in `brazier_render_ffi.mjs`.
  let view = "import brazier/element\npub fn view() { element.text(\"x\") }\n"
  let assert Ok(framework) = sources.framework_closure(".", [view])
  let assert True =
    list.any(framework, fn(source) { source.0 == "brazier/internal/render" })
  let assert Ok(ffi) = client_bundle.framework_ffi_files(".", framework)
  let assert Ok(copied) = list.key_find(ffi, "src/brazier_render_ffi.mjs")
  let assert Ok(original) = simplifile.read("src/brazier_render_ffi.mjs")
  let assert True = copied == original
  // Each file once, however many externals load it.
  let assert True =
    list.length(ffi) == list.length(list.unique(list.map(ffi, fn(f) { f.0 })))
}

pub fn framework_ffi_files_missing_file_is_an_error_test() {
  let root = fresh_dir("framework_ffi_missing")
  let module =
    "@external(javascript, \"../gone_ffi.mjs\", \"go\")\npub fn go() -> Nil\n"
  write(root, "src/brazier/thing.gleam", module)
  let assert Error(reason) =
    client_bundle.framework_ffi_files(root, [#("brazier/thing", module)])
  let assert True = string.contains(reason, root <> "/src/gone_ffi.mjs")
  let assert True = string.contains(reason, "`brazier/thing`")
  let assert True = string.contains(reason, "does not exist")
}

pub fn framework_ffi_files_without_externals_is_empty_test() {
  let assert Ok([]) =
    client_bundle.framework_ffi_files(".", [
      #("brazier/plain", "pub fn id(x) { x }\n"),
    ])
}

// --- Client project warnings ---

/// An app module with two warnings in reached code, laid out so the sliced
/// copy moves both: the unreached `server_only` and the Erlang external go,
/// so every later line shifts up. `unused` is an unused variable on a
/// definition's inner line (11:7). The Int on line 15 is one JavaScript
/// cannot represent, a warning only the JavaScript target raises; it sits on
/// the first line of `big`, after a constant the copy drops, whose `ë` is
/// two code points and three bytes, so its column (44) is right only when
/// the map counts code points as the compiler does.
const view_source =
  "/// Server-only: not reached, so the copy leaves it out.
pub fn server_only(x) {
  x
}

@external(erlang, \"erlang\", \"abs\")
@external(javascript, \"./view_ffi.mjs\", \"abs\")
fn abs(x: Int) -> Int

pub fn view(model: Int) -> Int {
  let unused = 1
  abs(model) + big()
}

pub const label = \"zoe\u{0308}\" fn big() -> Int { 9007199254740993 }
"

const view_ffi = "export function abs(x) { return Math.abs(x); }\n"

const js_toml =
  "name = \"warned_client\"\nversion = \"1.0.0\"\ntarget = \"javascript\"\n"

/// The emitted copy of the app module `app/view` with source `source`, its
/// `view` reached.
fn emit_view(source: String) -> reach.Emitted {
  let assert Ok(ast) = glance.module(source)
  let assert Ok(index) = reach.index([#("app/view", source, ast)])
  let assert Ok(reached) =
    reach.walk(index, [], [reach.FunctionItem("app/view", "view")])
  let assert Ok([emitted]) = reach.emit(index, reached)
  emitted
}

/// A JavaScript project like the client project at `dir`: the app module
/// copy `view`, its FFI file and a generated entry. With `brazier_warnings`,
/// the entry has an unused private function and a Brazier module has an
/// Int JavaScript cannot represent.
fn client_project(
  dir: String,
  view: reach.Emitted,
  brazier_warnings: Bool,
) -> Nil {
  write(dir, "gleam.toml", js_toml)
  write(dir, "src/app/view.gleam", view.source)
  write(dir, "src/app/view_ffi.mjs", view_ffi)
  write(dir, "src/app/helpers.gleam", "pub fn id(x) { x }\n")
  case brazier_warnings {
    True -> {
      write(
        dir,
        "src/brazier_app_entry.gleam",
        "pub fn main() { 1 }\n\nfn unused() { 2 }\n",
      )
      write(dir, "src/brazier/big.gleam", "pub fn big() { 9007199254740993 }\n")
    }
    False -> write(dir, "src/brazier_app_entry.gleam", "pub fn main() { 1 }\n")
  }
}

/// The app project the copy came from, compiled to JavaScript as it is:
/// the compiler's own locations of its warnings, the ground truth the
/// mapped ones must equal.
fn original_warnings(dir: String) -> List(program.Warning) {
  write(dir, "gleam.toml", js_toml)
  write(dir, "src/app/view.gleam", view_source)
  write(dir, "src/app/view_ffi.mjs", view_ffi)
  let assert Ok(output) = program.run(dir, "gleam", ["build"])
  program.warnings(output)
}

pub fn emitted_segments_point_at_the_copied_text_test() {
  let emitted = emit_view(view_source)
  let copy = string.split(emitted.source, "\n")
  let original = string.split(view_source, "\n")
  let assert [abs, view, big] = emitted.segments
  let assert source_map.Segment(copy_line: 2, lines: 1, source_line: 8, ..) =
    abs
  let assert source_map.Segment(copy_line: 4, lines: 4, source_line: 10, ..) =
    view
  let assert source_map.Segment(copy_line: 9, lines: 1, source_line: 15, ..) =
    big
  // Every copied line is the original's line, the first one from the
  // segment's starting column on.
  list.each(emitted.segments, fn(segment) {
    let lines = fn(all, first) {
      all |> list.drop(first - 1) |> list.take(segment.lines)
    }
    let assert Ok(pairs) =
      list.strict_zip(
        lines(copy, segment.copy_line),
        lines(original, segment.source_line),
      )
    let assert True = list.length(pairs) == segment.lines
    list.index_map(pairs, fn(pair, i) {
      let #(copied, source) = pair
      let expected = case i {
        0 ->
          string.to_utf_codepoints(source)
          |> list.drop(segment.source_column - 1)
          |> string.from_utf_codepoints
        _ -> source
      }
      let assert True = copied == expected
    })
  })
  let assert 1 = abs.source_column
  let assert 1 = view.source_column
  let assert 26 = big.source_column
}

pub fn compile_logs_an_app_warning_at_the_apps_own_line_test() {
  let root = fresh_dir("compile_app_warning")
  let assert [
    program.Warning("Unused variable", Some(unused_at)),
    program.Warning(
      "Int is outside JavaScript's safe integer range",
      Some(int_at),
    ),
  ] = original_warnings(root <> "/app")
  let assert True = string.ends_with(unused_at, "/app/src/app/view.gleam:11:7")
  let assert True = string.ends_with(int_at, "/app/src/app/view.gleam:15:44")
  let dir = root <> "/client"
  let emitted = emit_view(view_source)
  client_project(dir, emitted, False)
  let #(result, logs) =
    log_capture.capture(fn() {
      client_bundle.compile(dir, root <> "/app/src", ".", [emitted])
    })
  let assert Ok(Nil) = result
  // Each warning names the place the compiler names in the original, and
  // the copy's place after it.
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "`gleam build` of the client project in " <> dir,
      "warned in the app's code: Unused variable at " <> unused_at <> " (",
      "the client project's copy: ",
      "/client/src/app/view.gleam:5:7)",
    ])
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "warned in the app's code: Int is outside JavaScript's safe integer range at "
        <> int_at
        <> " (",
      "/client/src/app/view.gleam:9:19)",
    ])
  // No warning is logged at the copy's place alone.
  let assert False =
    list.any(logs, fn(event) {
      string.contains(event.message, "warned: ")
      && string.contains(event.message, "/client/src/app/view.gleam")
    })
}

pub fn compile_refuses_a_warning_in_a_line_the_build_generated_test() {
  let dir = fresh_dir("compile_generated_warning")
  let emitted = emit_view(view_source)
  // As a Brazier bug in the regenerated imports would: an import the copied
  // definitions do not use, on a line the build wrote.
  let emitted =
    reach.Emitted(
      ..emitted,
      source: "import app/helpers\n\n" <> emitted.source,
      segments: list.map(emitted.segments, fn(segment) {
        source_map.Segment(..segment, copy_line: segment.copy_line + 2)
      }),
    )
  client_project(dir, emitted, False)
  let #(result, logs) =
    log_capture.capture(fn() {
      client_bundle.compile(dir, "app_src", ".", [emitted])
    })
  let assert Error(reason) = result
  let assert Ok(source_file) = program.absolute_path("app_src/app/view.gleam")
  let assert True = string.contains(reason, "`gleam build` in " <> dir)
  let assert True = string.contains(reason, "This is a Brazier bug")
  // The copy's path, line and column, the warning, and that the build
  // generated the line. It is the only one refused, so the reason ends with
  // it.
  let assert True =
    string.contains(reason, "\n- Unused imported module at /")
    && string.ends_with(
      reason,
      "/compile_generated_warning/src/app/view.gleam:1:1, in a line the build generated for app/view (its imports or an @external attribute), not in its source "
        <> source_file,
    )
  // No line of the source is guessed for it.
  let assert False = string.contains(reason, source_file <> ":")
  let assert True = log_capture.has(logs, level: "error", containing: [reason])
  // The app's own warnings below it are still its own: mapped and logged,
  // not refused.
  let assert False = string.contains(reason, "Unused variable")
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "warned in the app's code: Unused variable at "
        <> source_file
        <> ":11:7 (",
      "/compile_generated_warning/src/app/view.gleam:7:7)",
    ])
}

pub fn compile_refuses_a_pruned_brazier_module_warning_at_its_own_line_test() {
  let root = fresh_dir("compile_pruned_brazier_warning")
  // The view module's slice standing in for a pruned Brazier module whose
  // reached definitions warn: the copy at `src/brazier/stream.gleam` of
  // `<brazier_root>/src/brazier/stream.gleam`.
  let emitted =
    reach.Emitted(..emit_view(view_source), path: reach.stream_module)
  let dir = root <> "/client"
  write(dir, "gleam.toml", js_toml)
  write(dir, "src/brazier/stream.gleam", emitted.source)
  write(dir, "src/brazier/view_ffi.mjs", view_ffi)
  write(dir, "src/brazier_app_entry.gleam", "pub fn main() { 1 }\n")
  let #(result, logs) =
    log_capture.capture(fn() {
      client_bundle.compile(dir, "app_src", root <> "/brazier", [emitted])
    })
  let assert Error(reason) = result
  let assert Ok(source_file) =
    program.absolute_path(root <> "/brazier/src/brazier/stream.gleam")
  // Both warnings name Brazier's own source at the lines the compiler gives
  // for the original (see `compile_logs_an_app_warning_at_the_apps_own_line_test`),
  // with the copy's place alongside.
  let assert True =
    string.contains(
      reason,
      "- Unused variable at "
        <> source_file
        <> ":11:7 (the client project's copy: /",
    )
    && string.contains(reason, "/client/src/brazier/stream.gleam:5:7)")
  let assert True =
    string.contains(
      reason,
      "- Int is outside JavaScript's safe integer range at "
        <> source_file
        <> ":15:44 (the client project's copy: /",
    )
    && string.contains(reason, "/client/src/brazier/stream.gleam:9:19)")
  let assert True = log_capture.has(logs, level: "error", containing: [reason])
  // None of it is logged as the app's.
  let assert False =
    list.any(logs, fn(event) {
      string.contains(event.message, "warned in the app's code")
    })
}

pub fn compile_refuses_a_warning_in_a_file_brazier_writes_test() {
  let dir = fresh_dir("compile_brazier_warning")
  client_project(dir, emit_view(view_source), True)
  let #(result, logs) =
    log_capture.capture(fn() {
      client_bundle.compile(dir, "app_src", ".", [emit_view(view_source)])
    })
  let assert Error(reason) = result
  let assert True = string.contains(reason, "`gleam build` in " <> dir)
  let assert True = string.contains(reason, "This is a Brazier bug")
  let assert True =
    string.contains(reason, "- Unused private function at /")
    && string.contains(reason, "/src/brazier_app_entry.gleam:3:1")
  let assert True =
    string.contains(
      reason,
      "- Int is outside JavaScript's safe integer range at /",
    )
    && string.contains(reason, "/src/brazier/big.gleam:1:16")
  // The app's own warnings are not among the refused ones; they are logged
  // at their own places.
  let assert False = string.contains(reason, "app/view.gleam")
  let assert False = string.contains(reason, "Unused variable")
  let assert True = log_capture.has(logs, level: "error", containing: [reason])
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "Unused variable at /", "/app_src/app/view.gleam:11:7 (",
    ])
}

pub fn place_maps_an_app_warning_to_the_apps_line_test() {
  let sliced = [
    client_bundle.Sliced(emit_view(view_source), "/p/app/view.gleam"),
  ]
  let at = fn(location) {
    client_bundle.place(program.Warning("w", Some(location)), sliced)
  }
  let assert client_bundle.InAppCode(
    "w at /p/app/view.gleam:11:7 (the client project's copy: /c/src/app/view.gleam:5:7)",
  ) = at("/c/src/app/view.gleam:5:7")
  // On the first line of `big`, the column shifts by where it starts.
  let assert client_bundle.InAppCode(
    "w at /p/app/view.gleam:15:44 (the client project's copy: /c/src/app/view.gleam:9:19)",
  ) = at("/c/src/app/view.gleam:9:19")
}

pub fn place_refuses_an_app_warning_it_cannot_place_test() {
  let sliced = [
    client_bundle.Sliced(emit_view(view_source), "/p/app/view.gleam"),
  ]
  let at = fn(location) {
    client_bundle.place(program.Warning("w", Some(location)), sliced)
  }
  // The @external line before `abs`, and the blank line after it, are the
  // build's.
  let assert client_bundle.InBrazierCode(
    "w at /c/src/app/view.gleam:1:2, in a line the build generated for app/view (its imports or an @external attribute), not in its source /p/app/view.gleam",
  ) = at("/c/src/app/view.gleam:1:2")
  let assert client_bundle.InBrazierCode(
    "w at /c/src/app/view.gleam:3:1, in a line the build generated for app/view (its imports or an @external attribute), not in its source /p/app/view.gleam",
  ) = at("/c/src/app/view.gleam:3:1")
  // Past the last definition.
  let assert client_bundle.InBrazierCode(_) = at("/c/src/app/view.gleam:10:1")
  // A location without a line and column cannot be placed in the app's code.
  let assert client_bundle.InBrazierCode(
    "w at /c/src/app/view.gleam, which gives no line and column, so it cannot be placed in its source /p/app/view.gleam",
  ) = at("/c/src/app/view.gleam")
}

pub fn place_refuses_warnings_outside_app_modules_test() {
  let sliced = [
    client_bundle.Sliced(emit_view(view_source), "/p/app/view.gleam"),
    client_bundle.Sliced(
      reach.Emitted(..emit_view(view_source), path: "view"),
      "/p/view.gleam",
    ),
  ]
  let place = fn(location) {
    client_bundle.place(program.Warning("w", location), sliced)
  }
  // A generated file.
  let assert client_bundle.InBrazierCode(
    "w at /p/build/brazier_client_app/src/brazier_app_entry.gleam:3:1",
  ) = place(Some("/p/build/brazier_client_app/src/brazier_app_entry.gleam:3:1"))
  // A Brazier module whose file name ends like an app module's.
  let assert client_bundle.InBrazierCode(
    "w at /p/build/brazier_client_app/src/brazier/view.gleam:2:1",
  ) = place(Some("/p/build/brazier_client_app/src/brazier/view.gleam:2:1"))
  // A warning naming no file cannot be the app's.
  let assert client_bundle.InBrazierCode("w") = place(None)
  // With no sliced modules, every warning is Brazier's.
  let assert client_bundle.InBrazierCode(_) =
    client_bundle.place(
      program.Warning("w", Some("/c/src/app/view.gleam:5:7")),
      [],
    )
}
