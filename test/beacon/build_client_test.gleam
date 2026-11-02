/// Tests for the client-side build pieces: the generated `beacon` and
/// `beacon/log` shims, app module discovery, and bundle publishing.
import beacon/build/client_bundle
import beacon/build/client_shim
import beacon/build/discovery
import glance
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/set
import gleam/string
import simplifile

const scratch = "build/beacon_build_client_test"

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

// --- client beacon shim ------------------------------------------------------

pub fn shim_has_every_public_view_helper_test() {
  // Independently of client_shim's own filter: every public function of the
  // server `beacon` module whose return type is Attr or Node.
  let server = parse_file("src/beacon.gleam")
  let view_helpers =
    server.functions
    |> list.filter(fn(def) {
      def.definition.publicity == glance.Public
      && case def.definition.return {
        Some(glance.NamedType(name: "Attr", ..))
        | Some(glance.NamedType(name: "Node", ..)) -> True
        _ -> False
      }
    })
    |> list.map(fn(def) {
      #(def.definition.name, list.length(def.definition.parameters))
    })
  let assert Ok(shim_source) = client_shim.beacon_module(".")
  let assert Ok(shim) = glance.module(shim_source)
  let shim_functions = public_functions(shim)
  let missing =
    list.filter(view_helpers, fn(helper) {
      dict.get(shim_functions, helper.0) != Ok(helper.1)
    })
  let assert [] = missing
  // The helpers the hand-written shim used to miss are present.
  let assert Ok(1) = dict.get(shim_functions, "on_focus")
  let assert Ok(1) = dict.get(shim_functions, "on_blur")
  let assert Ok(2) = dict.get(shim_functions, "on_input_debounced")
  // The shim adds nothing the server module does not have.
  let assert True =
    list.length(view_helpers) == dict.size(shim_functions)
    && list.length(view_helpers) >= 18
}

pub fn shim_defines_node_alias_test() {
  let assert Ok(shim_source) = client_shim.beacon_module(".")
  let assert Ok(shim) = glance.module(shim_source)
  let assert True =
    list.any(shim.type_aliases, fn(def) {
      def.definition.name == "Node" && def.definition.publicity == glance.Public
    })
}

pub fn log_shim_matches_server_log_api_test() {
  let server = public_functions(parse_file("src/beacon/log.gleam"))
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

pub fn shim_rejects_helper_using_other_module_test() {
  let source =
    "import beacon/element.{type Attr}
import gleam/int

pub fn bad_count(n: Int) -> Attr {
  element.attr(\"data-count\", int.to_string(n))
}
"
  let assert Error(reason) = client_shim.helpers("fake/beacon.gleam", source)
  let assert True = string.contains(reason, "`beacon.bad_count`")
  let assert True = string.contains(reason, "fake/beacon.gleam")
  let assert True = string.contains(reason, "it uses int.")
}

pub fn shim_rejects_helper_using_unknown_function_test() {
  let source =
    "import beacon/element.{type Attr}

pub fn bad_secret() -> Attr {
  element.attr(\"data-secret\", read_secret())
}

fn read_secret() -> String {
  \"x\"
}
"
  let assert Error(reason) = client_shim.helpers("fake/beacon.gleam", source)
  let assert True = string.contains(reason, "`beacon.bad_secret`")
  let assert True = string.contains(reason, "read_secret")
}

pub fn shim_allows_helpers_calling_helpers_test() {
  let source =
    "import beacon/element.{type Attr}

/// Doc comments are kept out of the copied source.
pub fn first(name: String) -> Attr {
  let value = string.lowercase(name)
  element.attr(\"data-first\", value)
}

pub fn second() -> Attr {
  first(\"X\")
}

pub fn not_a_helper() -> Int {
  1
}
"
  let assert Ok([first, second]) =
    client_shim.helpers("fake/beacon.gleam", source)
  let assert client_shim.Helper(name: "first", arity: 1, source: first_source) =
    first
  let assert True = string.starts_with(first_source, "pub fn first(")
  let assert True = string.ends_with(first_source, "}")
  let assert client_shim.Helper(name: "second", arity: 0, ..) = second
}

// --- discovery ---------------------------------------------------------------

/// A module that defines a complete app. It only needs to parse.
const app_body =
  "
pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
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
    "a_helper_app.gleam",
    "import beacon as b\n" <> app_body <> "pub fn other() { b.title }\n",
  )
  write(
    dir,
    "main_app.gleam",
    "import beacon as b\n"
      <> app_body
      <> "pub fn main() { b.app(1, 2, 3, update, view) |> b.start(8080) }\n",
  )
  let assert Ok(app) = discovery.find(dir)
  let assert True = app.path == dir <> "/main_app.gleam"
  let assert "main_app" = app.module_path
}

pub fn discovery_unqualified_import_test() {
  let dir = fresh_dir("unqualified")
  write(dir, "other.gleam", "import beacon\n" <> app_body)
  write(
    dir,
    "web/app.gleam",
    "import beacon.{app}\n"
      <> app_body
      <> "pub fn main() { app(1, 2, 3, update, view) }\n",
  )
  let assert Ok(app) = discovery.find(dir)
  let assert "web/app" = app.module_path
}

pub fn discovery_unqualified_alias_import_test() {
  let dir = fresh_dir("unqualified_alias")
  write(dir, "other.gleam", app_body)
  write(
    dir,
    "app.gleam",
    "import beacon.{start as serve}\n"
      <> app_body
      <> "pub fn main() { serve(1, 8080) }\n",
  )
  let assert Ok(app) = discovery.find(dir)
  let assert "app" = app.module_path
}

pub fn discovery_ignores_entrypoint_in_comments_and_strings_test() {
  let dir = fresh_dir("comment_entrypoint")
  write(
    dir,
    "a.gleam",
    "import beacon\n// beacon.start(8080)\n"
      <> app_body
      <> "pub const doc = \"beacon.app(init) |> beacon.start(8080)\"\n",
  )
  write(dir, "b.gleam", app_body)
  let assert Error(reason) = discovery.find(dir)
  let assert True = string.contains(reason, "Several modules")
  let assert True = string.contains(reason, dir <> "/a.gleam")
  let assert True = string.contains(reason, dir <> "/b.gleam")
}

pub fn discovery_ignores_definitions_in_comments_test() {
  let dir = fresh_dir("comment_definitions")
  write(
    dir,
    "notes.gleam",
    "// pub type Model { Model }
// pub type Msg { Msg }
// pub fn update(model, msg) { model }
// pub fn view(model) { model }
pub const doc = \"pub type Model pub type Msg pub fn update pub fn view\"
",
  )
  let assert Error(reason) = discovery.find(dir)
  let assert True = string.contains(reason, "No app module found in " <> dir)
  write(dir, "app.gleam", app_body)
  let assert Ok(app) = discovery.find(dir)
  let assert "app" = app.module_path
}

pub fn discovery_skips_codec_and_framework_modules_test() {
  let dir = fresh_dir("skips")
  write(dir, "beacon_codec.gleam", app_body)
  write(dir, "beacon/vendored.gleam", app_body)
  write(dir, "beacon.gleam", app_body)
  write(dir, "beacon_extra/app.gleam", app_body)
  let assert Ok(app) = discovery.find(dir)
  // beacon_extra is not Beacon's package; only `beacon` and `beacon/*` are.
  let assert "beacon_extra/app" = app.module_path
}

pub fn discovery_requires_update_or_make_update_test() {
  let dir = fresh_dir("no_update")
  write(
    dir,
    "app.gleam",
    "pub type Model { Model }\npub type Msg { Msg }\npub fn view(m) { m }\n",
  )
  let assert Error(reason) = discovery.find(dir)
  let assert True = string.contains(reason, "No app module found")
  write(
    dir,
    "app.gleam",
    "pub type Model { Model }\npub type Msg { Msg }\npub fn view(m) { m }\npub fn make_update(x) { x }\n",
  )
  let assert Ok(_) = discovery.find(dir)
}

pub fn discovery_private_types_do_not_count_test() {
  let dir = fresh_dir("private")
  write(
    dir,
    "app.gleam",
    "type Model { Model }\npub type Msg { Msg }\npub fn view(m) { m }\npub fn update(m, _) { m }\n",
  )
  let assert Error(reason) = discovery.find(dir)
  let assert True = string.contains(reason, "No app module found")
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
  let assert True = string.starts_with(bundle.filename, "beacon_client_")
  let assert True = string.ends_with(bundle.filename, ".js")
  // beacon_client_ + 16 hex digits + .js
  let assert 33 = string.length(bundle.filename)
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
  write(dir, "beacon_client_notes.txt", "kept: not a bundle")
  let assert Ok(old) = client_bundle.publish(dir, "old")
  let assert Ok(new) = client_bundle.publish(dir, "new")
  let assert True = old.filename != new.filename
  let assert True =
    bundles(dir) |> set.from_list
    == set.from_list([new.filename, "beacon_client_notes.txt"])
  let assert Ok("body {}") = simplifile.read(dir <> "/app.css")
  let assert Ok(manifest) =
    simplifile.read(dir <> "/" <> client_bundle.manifest_file)
  let assert True = manifest == new.filename
}
