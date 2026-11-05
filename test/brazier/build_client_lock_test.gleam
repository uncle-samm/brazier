/// Tests that the client project is locked to the app's `manifest.toml`:
/// `client_bundle.pin_dependencies` picks the app's locked entries for the
/// packages the client imports, and `client_bundle.write_project` writes them
/// as the client's `gleam.toml` pins and `manifest.toml`, so `gleam build`
/// there resolves nothing from Hex. A missing app lock, or one that disagrees
/// with the packages Gleam downloaded for the app, is an error and nothing
/// is written.
///
/// Each test builds a fake app project below `build/brazier_client_lock_test`:
/// a manifest, Gleam's `build/packages/packages.toml`, and package sources
/// holding only the modules the client imports. No Gleam or network is used.
import brazier/build/client_bundle
import brazier/build/files
import brazier/build/project_toml.{HexSource, LocalSource, LockedPackage}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

const scratch = "build/brazier_client_lock_test"

const app_manifest =
  "# Do not manually edit this file, it is managed by Gleam.

packages = [
  { name = \"gleam_json\", version = \"3.1.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], otp_app = \"gleam_json\", source = \"hex\", outer_checksum = \"44FDAA8847BE8FC48CA7A1C089706BD54BADCC4C45B237A992EDDF9F2CDB2836\" },
  { name = \"gleam_stdlib\", version = \"1.0.5\", build_tools = [\"gleam\"], requirements = [], otp_app = \"gleam_stdlib\", source = \"hex\", outer_checksum = \"CEE5B6C076A85B45F60C585F4316C63EC8B7127C119D5738C3958A9C4D50404E\" },
  { name = \"mylib\", version = \"0.2.0\", build_tools = [\"gleam\"], requirements = [\"gleam_stdlib\"], source = \"local\", path = \"../mylib\" },
  { name = \"unrelated\", version = \"9.9.9\", build_tools = [\"gleam\"], requirements = [], otp_app = \"unrelated\", source = \"hex\", outer_checksum = \"EF\" },
]

[requirements]
gleam_json = { version = \">= 3.1.0 and < 4.0.0\" }
mylib = { path = \"../mylib\" }
unrelated = { version = \">= 9.0.0 and < 10.0.0\" }
"

const downloaded =
  "[packages]
gleam_json = \"3.1.0\"
gleam_stdlib = \"1.0.5\"
unrelated = \"9.9.9\"

[git]
"

/// The client sources: an app module importing a Hex package, a local
/// package and a framework module the client project carries itself.
const client_files = [
  #(
    "src/app.gleam",
    "import brazier/element\nimport gleam/json\nimport mylib\npub fn x() { 1 }\n",
  ),
  #("src/brazier/element.gleam", "pub fn y() { 1 }\n"),
]

/// A fake app project at `<scratch>/<name>/app` with its local package
/// `mylib` at `<scratch>/<name>/mylib`.
fn fake_app(name: String, manifest: String, packages_toml: String) -> String {
  let root = scratch <> "/" <> name
  let assert Ok(Nil) = case simplifile.delete(root) {
    Ok(Nil) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
  let project = root <> "/app"
  write(project <> "/manifest.toml", manifest)
  write(project <> "/build/packages/packages.toml", packages_toml)
  write(
    project <> "/build/packages/gleam_json/src/gleam/json.gleam",
    "pub fn j() { 1 }\n",
  )
  write(
    project <> "/build/packages/gleam_stdlib/src/gleam/list.gleam",
    "pub fn l() { 1 }\n",
  )
  write(
    project <> "/build/packages/unrelated/src/unrelated.gleam",
    "pub fn u() { 1 }\n",
  )
  write(root <> "/mylib/src/mylib.gleam", "pub fn m() { 1 }\n")
  project
}

fn write(path: String, contents: String) -> Nil {
  let assert Ok(Nil) = files.write(path, contents)
  Nil
}

pub fn client_project_is_locked_to_the_app_manifest_test() {
  let project = fake_app("locked", app_manifest, downloaded)
  let assert Ok(packages) =
    client_bundle.pin_dependencies(project, client_files)
  let assert Ok(app) =
    project_toml.parse_manifest(project <> "/manifest.toml", app_manifest)
  let assert Ok(json) = dict.get(app, "gleam_json")
  let assert Ok(stdlib) = dict.get(app, "gleam_stdlib")
  let assert Ok(mylib) = dict.get(app, "mylib")
  // The imported packages and what they need, as the app locks them; the
  // unrelated package and the framework module the project carries are not
  // dependencies. The local path is made relative to the client project.
  assert packages
    == [
      json,
      stdlib,
      LockedPackage(..mylib, source: LocalSource("../../../mylib")),
    ]

  let dir = project <> "/" <> client_bundle.client_dir
  let assert Ok(Nil) =
    client_bundle.write_project(
      dir,
      client_files,
      project <> "/manifest.toml",
      packages,
    )
  let assert Ok(gleam_toml) = files.read(dir <> "/gleam.toml")
  assert string.ends_with(
    gleam_toml,
    "[dependencies]
gleam_json = \"== 3.1.0\"
gleam_stdlib = \"== 1.0.5\"
mylib = { path = \"../../../mylib\" }
",
  )
  let assert Ok(manifest_text) = files.read(dir <> "/manifest.toml")
  let assert Ok(client) =
    project_toml.parse_manifest(dir <> "/manifest.toml", manifest_text)
  assert list.sort(dict.values(client), fn(a, b) {
      string.compare(a.name, b.name)
    })
    == packages
  let assert Ok(HexSource(checksum)) =
    dict.get(client, "gleam_json") |> result_source
  assert checksum
    == "44FDAA8847BE8FC48CA7A1C089706BD54BADCC4C45B237A992EDDF9F2CDB2836"
  // The manifest's requirements state exactly the gleam.toml pins, so Gleam
  // takes the manifest as up to date and resolves nothing.
  assert string.ends_with(
    manifest_text,
    "[requirements]
gleam_json = { version = \"== 3.1.0\" }
gleam_stdlib = { version = \"== 1.0.5\" }
mylib = { path = \"../../../mylib\" }
",
  )
  let assert Ok(written) = files.read(dir <> "/src/app.gleam")
  assert string.contains(written, "import gleam/json")
}

fn result_source(
  found: Result(project_toml.LockedPackage, Nil),
) -> Result(project_toml.PackageSource, Nil) {
  case found {
    Ok(package) -> Ok(package.source)
    Error(Nil) -> Error(Nil)
  }
}

/// Without the app's lock there is nothing to pin to, and the build says so
/// instead of resolving versions from Hex.
pub fn missing_app_manifest_is_an_error_test() {
  let project = fake_app("no_manifest", app_manifest, downloaded)
  let assert Ok(Nil) = simplifile.delete(project <> "/manifest.toml")
  let assert Error(reason) =
    client_bundle.pin_dependencies(project, client_files)
  assert string.contains(reason, project <> "/manifest.toml does not exist")
  assert string.contains(reason, "never resolved from Hex")
  assert string.contains(reason, "Run `gleam build` in the app")
}

/// The lock says gleam_json 3.1.0 but Gleam downloaded 3.0.0 for the app:
/// the modules were read from one version and the pin would name another.
pub fn manifest_disagreeing_with_downloads_is_an_error_test() {
  let stale =
    string.replace(
      downloaded,
      "gleam_json = \"3.1.0\"",
      "gleam_json = \"3.0.0\"",
    )
  let project = fake_app("mismatch", app_manifest, stale)
  let assert Error(reason) =
    client_bundle.pin_dependencies(project, client_files)
  assert string.contains(reason, "locks gleam_json 3.1.0")
  assert string.contains(reason, "holds gleam_json 3.0.0")
  assert string.contains(reason, "gleam deps download")
}

pub fn locked_package_never_downloaded_is_an_error_test() {
  let missing = string.replace(downloaded, "gleam_stdlib = \"1.0.5\"\n", "")
  let project = fake_app("not_downloaded", app_manifest, missing)
  let assert Error(reason) =
    client_bundle.pin_dependencies(project, client_files)
  assert string.contains(reason, "locks gleam_stdlib 1.0.5")
  assert string.contains(reason, "does not hold gleam_stdlib")
}

pub fn missing_download_record_is_an_error_test() {
  let project = fake_app("no_downloads", app_manifest, downloaded)
  let assert Ok(Nil) =
    simplifile.delete(project <> "/build/packages/packages.toml")
  let assert Error(reason) =
    client_bundle.pin_dependencies(project, client_files)
  assert string.contains(reason, "packages.toml does not exist")
  assert string.contains(reason, "gleam deps download")
}

/// An import no locked package provides is reported, not looked up on Hex.
pub fn import_no_locked_package_provides_is_an_error_test() {
  let project = fake_app("unprovided", app_manifest, downloaded)
  let assert Error(reason) =
    client_bundle.pin_dependencies(project, [
      #("src/app.gleam", "import gleam/http\npub fn x() { 1 }\n"),
    ])
  assert string.contains(reason, "imports `gleam/http`")
}

/// A lock entry without its checksum fails the build, naming the entry.
pub fn manifest_without_checksum_is_an_error_test() {
  let manifest =
    string.replace(
      app_manifest,
      ", outer_checksum = \"CEE5B6C076A85B45F60C585F4316C63EC8B7127C119D5738C3958A9C4D50404E\"",
      "",
    )
  let project = fake_app("no_checksum", manifest, downloaded)
  let assert Error(reason) =
    client_bundle.pin_dependencies(project, client_files)
  assert string.contains(reason, "packages[1]")
  assert string.contains(reason, "missing key `outer_checksum`")
}

pub fn relative_path_test() {
  assert files.relative_path("/a/b/c", "/a/d") == Ok("../../d")
  assert files.relative_path("/a/b", "/a/b/c/d") == Ok("c/d")
  assert files.relative_path("/a/b", "/a/b") == Ok(".")
  assert files.relative_path("/a/./b/../b/c", "/a/x/") == Ok("../../x")
  assert files.relative_path("/", "/a") == Ok("a")
}

pub fn relative_path_rejects_relative_and_climbing_paths_test() {
  let assert Error(reason) = files.relative_path("a/b", "/a")
  assert string.contains(reason, "a/b")
  assert string.contains(reason, "not absolute")
  let assert Error(reason) = files.relative_path("/a", "/../b")
  assert string.contains(reason, "climbs above /")
}

pub fn resolve_keeps_absolute_paths_test() {
  assert files.resolve("app", "/abs/lib") == "/abs/lib"
  assert files.resolve("app", "../lib") == "app/../lib"
  assert files.resolve(".", "lib") == "lib"
}

/// `None` and `Some` are the two shapes of `otp_app` in a lock entry.
pub fn otp_app_shapes_survive_the_client_manifest_test() {
  let project = fake_app("otp_app", app_manifest, downloaded)
  let assert Ok(packages) =
    client_bundle.pin_dependencies(project, client_files)
  assert list.map(packages, fn(p) { p.otp_app })
    == [Some("gleam_json"), Some("gleam_stdlib"), None]
}
