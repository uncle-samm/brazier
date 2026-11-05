/// Tests for the client-side build pieces: the generated `brazier/log` shim,
/// app module discovery, bundle publishing, the framework FFI files the
/// client project gets, and the warnings its compile refuses.
import brazier/build/client_bundle
import brazier/build/client_shim
import brazier/build/discovery
import brazier/build/program
import brazier/build/sources
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

/// A JavaScript project like the client project: an app module whose view
/// ignores an argument and a generated entry. With `brazier_warnings`, the
/// entry has an unused private function and a Brazier module has an Int
/// JavaScript cannot represent, a warning only the JavaScript target raises.
fn warning_project(name: String, brazier_warnings: Bool) -> String {
  let dir = fresh_dir(name)
  write(
    dir,
    "gleam.toml",
    "name = \"warned_client\"\nversion = \"1.0.0\"\ntarget = \"javascript\"\n",
  )
  write(dir, "src/app/view.gleam", "pub fn view(model) { 1 }\n")
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
  dir
}

pub fn compile_leaves_an_app_modules_warning_to_the_app_test() {
  let dir = warning_project("compile_app_warning", False)
  let assert Ok(Nil) = client_bundle.compile(dir, ["app/view"])
}

pub fn compile_refuses_a_warning_in_a_file_brazier_writes_test() {
  let dir = warning_project("compile_brazier_warning", True)
  let assert Error(reason) = client_bundle.compile(dir, ["app/view"])
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
  // The app's own warning is not among the refused ones.
  let assert False = string.contains(reason, "app/view.gleam")
  let assert False = string.contains(reason, "Unused function argument")
}

pub fn brazier_warnings_keeps_only_warnings_outside_app_modules_test() {
  let warning = fn(location) { program.Warning("w", location) }
  let app = warning(Some("/p/build/brazier_client_app/src/app/view.gleam:1:10"))
  let entry =
    warning(Some("/p/build/brazier_client_app/src/brazier_app_entry.gleam:3:1"))
  // A Brazier module whose file name matches an app module's.
  let brazier_view =
    warning(Some("/p/build/brazier_client_app/src/brazier/view.gleam:2:1"))
  // A warning naming no file cannot be the app's.
  let unlocated = warning(None)
  let assert [] = client_bundle.brazier_warnings([app], ["app/view"])
  let assert True =
    client_bundle.brazier_warnings([app, entry, brazier_view, unlocated], [
      "app/view", "view",
    ])
    == [entry, brazier_view, unlocated]
  // With no app modules, every warning is Brazier's.
  let assert [_] = client_bundle.brazier_warnings([app], [])
}
