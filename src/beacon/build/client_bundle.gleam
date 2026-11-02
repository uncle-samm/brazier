/// Builds an app's client bundle: the app's client-visible Model, Msg, view
/// (and update, without Server state) compiled to JavaScript together with
/// the Beacon client runtime, written to `priv/static` under a content hash.
///
/// The build writes a JavaScript-target Gleam project to
/// `build/beacon_client_app`:
///
/// - `src/app.gleam`: the app module's client-visible source.
/// - The client-visible part of each user module it imports.
/// - The Beacon modules those import (`beacon/element`, `beacon/html`, ...),
///   copied from Beacon's sources, and generated `beacon` and `beacon/log`
///   modules (see `client_shim`).
/// - The client runtime: `beacon_client_ffi.mjs`, the `beacon_client/*.mjs`
///   modules and `beacon_client/handler.gleam`.
/// - `src/beacon_app_entry.gleam`, the interface the runtime calls.
/// - `gleam.toml`, pinning every package the sources import to the exact
///   version in the app's `manifest.toml`.
///
/// The project is compiled with `gleam build` and bundled with the pinned
/// esbuild. Every step's failure stops the build; no bundle is written until
/// all of them succeed.
import beacon/build/analyzer.{type Analysis}
import beacon/build/client_entry
import beacon/build/client_shim
import beacon/build/discovery.{type AppModule}
import beacon/build/files
import beacon/build/program
import beacon/build/project_toml.{type LockedPackage}
import beacon/build/shape.{type ClientApp}
import beacon/build/sources
import beacon/log
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// The client project, relative to the app project.
pub const client_dir = "build/beacon_client_app"

/// Where bundles and their manifest are written, relative to the app project.
pub const static_dir = "priv/static"

/// The file in `static_dir` naming the current bundle.
pub const manifest_file = "beacon_client.manifest"

/// Bundle file names: `beacon_client_<hash>.js`.
pub const bundle_prefix = "beacon_client_"

/// A written bundle.
pub type Bundle {
  Bundle(
    /// File name in `static_dir`, e.g. `beacon_client_0123456789abcdef.js`.
    filename: String,
    /// Path of the bundle file.
    path: String,
  )
}

/// One file of the client project: #(path relative to the project, contents).
type ProjectFile =
  #(String, String)

/// Build the client bundle of `app` in the app project at `project`, whose
/// Gleam sources are in `src_dir` and whose Beacon sources are at
/// `beacon_root`.
pub fn build(
  project: String,
  src_dir: String,
  beacon_root: String,
  app: AppModule,
  analysis: Analysis,
  client: ClientApp,
) -> Result(Bundle, String) {
  log.info(
    "beacon.build.client_bundle",
    "Building client bundle for " <> app.path,
  )
  use project_files <- result.try(project_files(
    src_dir,
    beacon_root,
    app,
    analysis,
    client,
  ))
  use dependencies <- result.try(dependencies(project, project_files))
  let dir = files.join(project, client_dir)
  use Nil <- result.try(write_project(dir, project_files, dependencies))
  use Nil <- result.try(program.gleam_build(dir))
  use Nil <- result.try(files.write(files.join(dir, "bundle_entry.mjs"), entry))
  use Nil <- result.try(program.esbuild_bundle(
    dir,
    "bundle_entry.mjs",
    "bundle.js",
  ))
  use bundle <- result.try(files.read(files.join(dir, "bundle.js")))
  publish(files.join(project, static_dir), bundle)
}

/// Write `contents` to `static_dir` as `beacon_client_<hash>.js`, point the
/// manifest at it, and delete the bundles it replaces.
pub fn publish(static: String, contents: String) -> Result(Bundle, String) {
  let filename = bundle_prefix <> program.content_hash(contents) <> ".js"
  let path = files.join(static, filename)
  use Nil <- result.try(files.write(path, contents))
  use Nil <- result.try(files.write(files.join(static, manifest_file), filename))
  use entries <- result.try(files.list_directory(static))
  use Nil <- result.try(
    entries
    |> list.filter(fn(entry) {
      entry != filename
      && string.starts_with(entry, bundle_prefix)
      && string.ends_with(entry, ".js")
    })
    |> list.try_each(fn(entry) {
      files.delete_if_exists(files.join(static, entry))
    }),
  )
  log.info(
    "beacon.build.client_bundle",
    "Wrote "
      <> path
      <> " ("
      <> string.inspect(string.byte_size(contents))
      <> " bytes) and "
      <> files.join(static, manifest_file),
  )
  Ok(Bundle(filename:, path:))
}

/// The esbuild entry: exposes the generated entry module to the runtime as
/// `window.BeaconApp`, then starts the runtime.
const entry =
  "import { initClientAfterBoot } from './build/dev/javascript/beacon_client_app/beacon_client_ffi.mjs';
import * as App from './build/dev/javascript/beacon_client_app/beacon_app_entry.mjs';
window.BeaconApp = App;
initClientAfterBoot();
"

fn project_files(
  src_dir: String,
  beacon_root: String,
  app: AppModule,
  analysis: Analysis,
  client: ClientApp,
) -> Result(List(ProjectFile), String) {
  use externals <- result.try(sources.client_externals(
    src_dir,
    app.path,
    client.source,
  ))
  use beacon_module <- result.try(client_shim.beacon_module(beacon_root))
  use entry_module <- result.try(client_entry.generate(
    analysis,
    client.has_update,
  ))
  use framework <- result.try(
    sources.framework_closure(beacon_root, [
      client.source,
      beacon_module,
      entry_module,
      ..list.map(externals, fn(s) { s.2 })
    ]),
  )
  use runtime <- result.try(runtime_files(beacon_root))
  let project_files =
    list.flatten([
      [#(module_file(client_entry.app_module), client.source)],
      list.map(externals, fn(s) { #(module_file(s.1), s.2) }),
      list.map(framework, fn(s) { #(module_file(s.1), s.2) }),
      [
        #(module_file("beacon"), beacon_module),
        #(module_file("beacon/log"), client_shim.log_module),
        #(module_file("beacon_app_entry"), entry_module),
      ],
      runtime,
    ])
  use Nil <- result.try(unique_paths(project_files))
  Ok(project_files)
}

/// The client runtime from `beacon_root/beacon_client/src`: the FFI module,
/// every module in `beacon_client/`.
fn runtime_files(beacon_root: String) -> Result(List(ProjectFile), String) {
  let runtime_src = files.join(beacon_root, "beacon_client/src")
  let package_dir = files.join(runtime_src, "beacon_client")
  use entries <- result.try(files.list_directory(package_dir))
  let wanted =
    list.filter(entries, fn(entry) {
      string.ends_with(entry, ".mjs") || entry == "handler.gleam"
    })
  use package_files <- result.try(
    list.try_map(wanted, fn(entry) {
      files.read(files.join(package_dir, entry))
      |> result.map(fn(text) { #("src/beacon_client/" <> entry, text) })
    }),
  )
  use ffi <- result.try(
    files.read(files.join(runtime_src, "beacon_client_ffi.mjs")),
  )
  case
    list.any(package_files, fn(f) { f.0 == "src/beacon_client/handler.gleam" })
  {
    True -> Ok([#("src/beacon_client_ffi.mjs", ffi), ..package_files])
    False ->
      Error(
        "The Beacon client runtime at "
        <> package_dir
        <> " has no handler.gleam. The Beacon sources at "
        <> beacon_root
        <> " are incomplete.",
      )
  }
}

/// Two sources for one path means a user module shadows a module the build
/// writes, e.g. a user `beacon_app_entry.gleam`.
fn unique_paths(project_files: List(ProjectFile)) -> Result(Nil, String) {
  let duplicates =
    project_files
    |> list.group(fn(f) { f.0 })
    |> dict.filter(fn(_path, group) { list.length(group) > 1 })
    |> dict.keys
    |> list.sort(string.compare)
  case duplicates {
    [] -> Ok(Nil)
    _ ->
      Error(
        "The client project would contain more than one "
        <> string.join(duplicates, ", ")
        <> ". Rename the user module so it does not clash with a module the Beacon build generates.",
      )
  }
}

/// The `[dependencies]` lines of the client project: every package that
/// provides a module the project's Gleam sources import, and everything
/// those packages need, pinned to the version in the app's manifest.
fn dependencies(
  project: String,
  project_files: List(ProjectFile),
) -> Result(List(String), String) {
  let gleam_files =
    list.filter(project_files, fn(f) { string.ends_with(f.0, ".gleam") })
  let own_modules =
    gleam_files
    |> list.map(fn(f) {
      f.0 |> string.drop_start(4) |> string.drop_end(string.length(".gleam"))
    })
    |> set.from_list
  use imported <- result.try(imported_modules(gleam_files))
  let external = set.difference(imported, own_modules) |> set.to_list
  let manifest_path = files.join(project, "manifest.toml")
  use manifest <- result.try(project_toml.read_manifest(manifest_path))
  use providers <- result.try(
    list.try_map(external, fn(module) { provider(project, manifest, module) }),
  )
  use packages <- result.try(project_toml.locked_closure(
    manifest,
    list.unique(providers),
  ))
  list.try_map(packages, fn(package) {
    project_toml.pinned_dependency_line(package, fn(path) {
      program.absolute_path(files.join(project, path))
    })
  })
}

fn imported_modules(
  gleam_files: List(ProjectFile),
) -> Result(Set(String), String) {
  list.try_fold(gleam_files, set.new(), fn(acc, file) {
    use module <- result.map(analyzer.parse(client_dir <> "/" <> file.0, file.1))
    list.fold(module.imports, acc, fn(acc, def) {
      set.insert(acc, def.definition.module)
    })
  })
}

/// The manifest package whose sources contain `module`.
fn provider(
  project: String,
  manifest: Dict(String, LockedPackage),
  module: String,
) -> Result(String, String) {
  use found <- result.try(
    manifest
    |> dict.values
    |> list.try_fold([], fn(acc, package) {
      let path =
        files.join(package_dir(project, package), "src/" <> module <> ".gleam")
      use exists <- result.map(files.is_file(path))
      case exists {
        True -> [package.name, ..acc]
        False -> acc
      }
    }),
  )
  case found {
    [name] -> {
      log.debug(
        "beacon.build.client_bundle",
        "Module " <> module <> " comes from package " <> name,
      )
      Ok(name)
    }
    [] ->
      Error(
        "The client-visible code imports `"
        <> module
        <> "`, which no package in "
        <> files.join(project, "manifest.toml")
        <> " provides. Add the package to gleam.toml and run `gleam deps download`, or move the import out of client-visible code.",
      )
    many ->
      Error(
        "Module `"
        <> module
        <> "` is provided by several packages: "
        <> string.join(list.sort(many, string.compare), ", "),
      )
  }
}

fn package_dir(project: String, package: LockedPackage) -> String {
  case package.source {
    project_toml.LocalSource(path:) -> files.join(project, path)
    project_toml.HexSource | project_toml.GitSource(..) ->
      files.join(project, "build/packages/" <> package.name)
  }
}

/// Replace the project's sources and `gleam.toml`. The project's own
/// `build` directory is kept so unchanged packages are not recompiled.
fn write_project(
  dir: String,
  project_files: List(ProjectFile),
  dependencies: List(String),
) -> Result(Nil, String) {
  use Nil <- result.try(files.delete_if_exists(files.join(dir, "src")))
  use Nil <- result.try(
    list.try_each(project_files, fn(file) {
      files.write(files.join(dir, file.0), file.1)
    }),
  )
  let toml =
    "name = \"beacon_client_app\"\nversion = \"0.1.0\"\ntarget = \"javascript\"\n\n[dependencies]\n"
    <> string.join(dependencies, "\n")
    <> "\n"
  use Nil <- result.try(files.write(files.join(dir, "gleam.toml"), toml))
  log.info(
    "beacon.build.client_bundle",
    "Wrote client project "
      <> dir
      <> " with "
      <> string.inspect(list.length(project_files))
      <> " files and "
      <> string.inspect(list.length(dependencies))
      <> " pinned dependencies",
  )
  Ok(Nil)
}

fn module_file(module_path: String) -> String {
  "src/" <> module_path <> ".gleam"
}
