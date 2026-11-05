/// Builds an app's client bundle: the code the app's view (and a `simple`
/// app's update, and a Local layer) reaches, compiled to JavaScript together
/// with the Brazier client runtime, written to `priv/static` under a content
/// hash.
///
/// The build writes a JavaScript-target Gleam project to
/// `build/brazier_client_app`:
///
/// - Each user module with reached definitions, at its own module path,
///   holding only those definitions (see `brazier/build/reach`), plus the
///   JavaScript FFI files their externals load.
/// - The Brazier modules those import (`brazier/element`, `brazier/html`, ...),
///   copied from Brazier's sources with the JavaScript FFI files their
///   externals load, and a generated `brazier/log` (see `client_shim`).
/// - The client runtime: `brazier_client_ffi.mjs` and the
///   `brazier_client/*.mjs` modules.
/// - `src/brazier_app_entry.gleam`, the interface the runtime calls.
/// - `gleam.toml`, pinning every package the sources import to the exact
///   version in the app's `manifest.toml`, and a `manifest.toml` copied
///   from the app's entries for those packages. With the lock in place,
///   `gleam build` uses it as it is: it resolves nothing, so it never asks
///   Hex for versions, and every build of one app uses the same packages.
///   Packages it has not unpacked yet come from Gleam's package cache, where
///   the app's own download put them, checked against the locked checksum.
///
/// The project is compiled with `gleam build` and bundled with the pinned
/// esbuild. Every step's failure stops the build; no bundle is written until
/// all of them succeed.
import brazier/build/analyzer.{type Analysis}
import brazier/build/client_entry
import brazier/build/client_shim
import brazier/build/discovery.{type AppModule}
import brazier/build/files
import brazier/build/program
import brazier/build/project_toml.{type LockedPackage}
import brazier/build/reach
import brazier/build/source_map
import brazier/build/sources
import brazier/log
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// The client project, relative to the app project.
pub const client_dir = "build/brazier_client_app"

/// Where bundles and their manifest are written, relative to the app project.
pub const static_dir = "priv/static"

/// The file in `static_dir` naming the current bundle.
pub const manifest_file = "brazier_client.manifest"

/// Bundle file names: `brazier_client_<hash>.js`.
pub const bundle_prefix = "brazier_client_"

/// A written bundle.
pub type Bundle {
  Bundle(
    /// File name in `static_dir`, e.g. `brazier_client_0123456789abcdef.js`.
    filename: String,
    /// Path of the bundle file.
    path: String,
  )
}

/// One file of the client project: #(path relative to the project, contents).
pub type ProjectFile =
  #(String, String)

/// Build the client bundle of `app` in the app project at `project`, whose
/// Gleam sources are in `src_dir`, whose Brazier sources are at
/// `brazier_root`, and whose client runtime is in `runtime_dir` (see
/// `project_toml.client_runtime_dir`).
pub fn build(
  project: String,
  src_dir: String,
  brazier_root: String,
  runtime_dir: String,
  app: AppModule,
  analysis: Analysis,
) -> Result(Bundle, String) {
  log.info(
    "brazier.build.client_bundle",
    "Building client bundle for " <> app.path,
  )
  use project_files <- result.try(project_files(
    src_dir,
    brazier_root,
    runtime_dir,
    analysis,
  ))
  use packages <- result.try(pin_dependencies(project, project_files))
  let dir = files.join(project, client_dir)
  use Nil <- result.try(write_project(
    dir,
    project_files,
    app_manifest(project),
    packages,
  ))
  use Nil <- result.try(compile(dir, src_dir, app_modules(analysis)))
  use Nil <- result.try(files.write(files.join(dir, "bundle_entry.mjs"), entry))
  use Nil <- result.try(program.esbuild_bundle(
    dir,
    "bundle_entry.mjs",
    "bundle.js",
  ))
  use bundle <- result.try(files.read(files.join(dir, "bundle.js")))
  publish(files.join(project, static_dir), bundle)
}

/// Write `contents` to `static_dir` as `brazier_client_<hash>.js`, point the
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
    "brazier.build.client_bundle",
    "Wrote "
      <> path
      <> " ("
      <> string.inspect(string.byte_size(contents))
      <> " bytes) and "
      <> files.join(static, manifest_file),
  )
  Ok(Bundle(filename:, path:))
}

/// Compile the client project at `dir` with `gleam build`.
///
/// `app_modules` are the emitted app modules, holding the app's own reached
/// definitions sliced unchanged from its sources in `src_dir`. A warning in
/// one of them is the app's, as the server's `gleam build` of the same
/// source is: it is logged and does not fail the build, so an unused
/// variable in a view does not stop a bundle that Gleam itself would build.
/// The compiler names the copy in the client project, whose line numbers
/// are not the source's, so the log names the place in the app's own file,
/// mapped through the module's segments (`source_map`). A place the build
/// generated (a regenerated import, an `@external` line) has no place in
/// the app's file, and the log says so, naming the copy.
///
/// Every other file is one Brazier writes: the copied and sliced Brazier
/// modules, the `brazier/log` shim, the generated entry and `gleam.toml`.
/// These must compile on JavaScript without a warning, so a warning in one,
/// or a warning naming no file, fails the build, naming each file and
/// warning. `--warnings-as-errors` is not used because it would refuse the
/// app's own warnings too.
pub fn compile(
  dir: String,
  src_dir: String,
  app_modules: List(reach.Emitted),
) -> Result(Nil, String) {
  use warnings <- result.try(program.gleam_build_warnings(dir))
  let user_modules = list.map(app_modules, fn(emitted) { emitted.path })
  use Nil <- result.try(
    list.try_each(warnings, fn(warning) {
      case app_module_of(warning, app_modules) {
        Ok(#(emitted, copy)) -> {
          use file <- result.map(
            program.absolute_path(files.join(src_dir, emitted.path <> ".gleam")),
          )
          log.warning(
            "brazier.build.client_bundle",
            "`gleam build` of the client project in "
              <> dir
              <> " warned in the app's code: "
              <> describe_app_warning(warning.headline, copy, emitted, file),
          )
        }
        Error(Nil) -> Ok(Nil)
      }
    }),
  )
  case brazier_warnings(warnings, user_modules) {
    [] -> Ok(Nil)
    refused -> {
      let reason =
        "`gleam build` in "
        <> dir
        <> " warned in files Brazier writes, which must compile without warnings. This is a Brazier bug; the bundle was not written:\n"
        <> string.join(
          list.map(refused, fn(w) { "- " <> program.describe_warning(w) }),
          "\n",
        )
      log.error("brazier.build.client_bundle", reason)
      Error(reason)
    }
  }
}

/// The warnings that do not point into one of `user_modules` (module
/// paths): those whose file does not end with `/src/<module>.gleam`, and
/// those naming no file. The compiler prints absolute paths; matching the
/// end does not depend on how the project's directory is spelled.
pub fn brazier_warnings(
  warnings: List(program.Warning),
  user_modules: List(String),
) -> List(program.Warning) {
  list.filter(warnings, fn(warning) {
    case program.warning_file(warning) {
      option.Some(file) ->
        !list.any(user_modules, fn(module) {
          string.ends_with(file, "/" <> module_file(module))
        })
      option.None -> True
    }
  })
}

/// The app module whose copy `warning` points into, by the same rule as
/// `brazier_warnings`, and the warning's location there.
fn app_module_of(
  warning: program.Warning,
  app_modules: List(reach.Emitted),
) -> Result(#(reach.Emitted, String), Nil) {
  use location <- result.try(option.to_result(warning.location, Nil))
  use file <- result.try(option.to_result(program.warning_file(warning), Nil))
  list.find(app_modules, fn(emitted) {
    string.ends_with(file, "/" <> module_file(emitted.path))
  })
  |> result.map(fn(emitted) { #(emitted, location) })
}

/// An app module's warning `headline`, at `copy` (the compiler's
/// `file:line:column` in `emitted`'s copy), described at the place in the
/// app's file `source_file` that it maps to, followed by the copy's
/// location. When it maps to no place, the copy's location and why: the
/// position is in a line the build generated, or the compiler gave no line
/// and column. Never a guessed line.
pub fn describe_app_warning(
  headline: String,
  copy: String,
  emitted: reach.Emitted,
  source_file: String,
) -> String {
  case program.location_line_column(copy) {
    option.Some(#(line, column)) ->
      case source_map.locate(emitted.segments, line, column) {
        source_map.InSource(line:, column:) ->
          headline
          <> " at "
          <> source_file
          <> ":"
          <> int.to_string(line)
          <> ":"
          <> int.to_string(column)
          <> " (the client project's copy: "
          <> copy
          <> ")"
        source_map.Generated ->
          headline
          <> " at "
          <> copy
          <> ", in a line the build generated for "
          <> emitted.path
          <> " (its imports or an @external attribute), not in your source "
          <> source_file
      }
    option.None ->
      headline
      <> " at "
      <> copy
      <> ", which gives no line and column, so it cannot be mapped to a place in your source "
      <> source_file
  }
}

/// The emitted app modules in the client project: those that are not
/// Brazier's.
fn app_modules(analysis: Analysis) -> List(reach.Emitted) {
  list.filter(analysis.client, fn(emitted) {
    !reach.is_framework_module(emitted.path)
  })
}

/// The esbuild entry: starts the runtime with the generated entry module.
const entry =
  "import { start } from './build/dev/javascript/brazier_client_app/brazier_client_ffi.mjs';
import * as App from './build/dev/javascript/brazier_client_app/brazier_app_entry.mjs';
start(App);
"

fn project_files(
  src_dir: String,
  brazier_root: String,
  runtime_dir: String,
  analysis: Analysis,
) -> Result(List(ProjectFile), String) {
  use entry_module <- result.try(client_entry.generate(analysis))
  // An emitted Brazier module (`brazier/stream`) loads its FFI files from
  // Brazier's sources, a user module from the app's.
  use ffi <- result.try(
    analysis.client
    |> list.flat_map(fn(emitted) {
      let root = case reach.is_framework_module(emitted.path) {
        True -> files.join(brazier_root, "src")
        False -> src_dir
      }
      list.map(emitted.ffi_files, fn(path) { #(root, path) })
    })
    |> list.unique
    |> list.try_map(fn(entry) {
      let #(root, path) = entry
      use text <- result.map(files.read(files.join(root, path)))
      #("src/" <> path, text)
    }),
  )
  use framework <- result.try(
    sources.framework_closure(brazier_root, [
      entry_module,
      ..list.map(analysis.client, fn(emitted) { emitted.source })
    ]),
  )
  use framework_ffi <- result.try(framework_ffi_files(brazier_root, framework))
  use runtime <- result.try(runtime_files(runtime_dir))
  let project_files =
    list.flatten([
      list.map(analysis.client, fn(emitted) {
        #(module_file(emitted.path), emitted.source)
      }),
      ffi,
      list.map(framework, fn(s) { #(module_file(s.0), s.1) }),
      framework_ffi,
      [
        #(module_file("brazier/log"), client_shim.log_module),
        #(module_file(client_entry.module_path), entry_module),
      ],
      runtime,
    ])
  use Nil <- result.try(unique_paths(project_files))
  log.debug(
    "brazier.build.client_bundle",
    "Client project: "
      <> string.inspect(list.length(analysis.client))
      <> " app modules, "
      <> string.inspect(list.length(ffi))
      <> " FFI files, "
      <> string.inspect(list.length(framework))
      <> " framework modules, "
      <> string.inspect(list.length(framework_ffi))
      <> " framework FFI files",
  )
  Ok(project_files)
}

/// The JavaScript FFI files that the `@external(javascript, ...)` attributes
/// of the copied framework modules load, read from Brazier's sources at
/// `brazier_root/src`, at the same path in the client project. A referenced
/// file that does not exist is a build error: the client project cannot
/// compile without it.
pub fn framework_ffi_files(
  brazier_root: String,
  framework: List(sources.Source),
) -> Result(List(#(String, String)), String) {
  use externals <- result.try(
    list.try_map(framework, fn(source) {
      let #(module_path, text) = source
      use module <- result.try(analyzer.parse(module_path <> ".gleam", text))
      module.functions
      |> list.filter_map(fn(def) {
        option.to_result(reach.javascript_external(def.attributes), Nil)
      })
      |> list.try_map(fn(external) {
        reach.resolve_ffi_path(module_path, external.0)
        |> result.map(fn(path) { #(path, module_path) })
      })
    })
    |> result.map(list.flatten),
  )
  externals
  |> list.group(fn(external) { external.0 })
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.try_map(fn(entry) {
    let #(path, users) = entry
    let users =
      users
      |> list.map(fn(user) { "`" <> user.1 <> "`" })
      |> list.unique
      |> list.sort(string.compare)
    let file = files.join(brazier_root, "src/" <> path)
    use exists <- result.try(files.is_file(file))
    case exists {
      True -> {
        use text <- result.map(files.read(file))
        log.debug(
          "brazier.build.client_bundle",
          "Framework FFI file " <> path <> " copied from " <> file,
        )
        #("src/" <> path, text)
      }
      False ->
        Error(
          "The JavaScript FFI file "
          <> file
          <> ", loaded by an @external(javascript, ...) attribute in "
          <> string.join(users, ", ")
          <> ", does not exist. The Brazier sources at "
          <> brazier_root
          <> " are incomplete.",
        )
    }
  })
}

/// The client runtime from `runtime_src`: the FFI module and every `.mjs`
/// module in `brazier_client/`.
fn runtime_files(runtime_src: String) -> Result(List(ProjectFile), String) {
  let package_dir = files.join(runtime_src, "brazier_client")
  use entries <- result.try(files.list_directory(package_dir))
  use package_files <- result.try(
    entries
    |> list.filter(string.ends_with(_, ".mjs"))
    |> list.sort(string.compare)
    |> list.try_map(fn(entry) {
      files.read(files.join(package_dir, entry))
      |> result.map(fn(text) { #("src/brazier_client/" <> entry, text) })
    }),
  )
  use ffi <- result.map(
    files.read(files.join(runtime_src, "brazier_client_ffi.mjs")),
  )
  [#("src/brazier_client_ffi.mjs", ffi), ..package_files]
}

/// Two sources for one path means a user module shadows a module the build
/// writes, e.g. a user `brazier_app_entry.gleam`.
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
        <> ". Rename the user module so it does not clash with a module the Brazier build generates.",
      )
  }
}

/// The packages the client project depends on: every package that provides
/// a module the project's Gleam sources import, and everything those
/// packages need, as the app's `manifest.toml` locks them. A local
/// package's path is made relative to the client project.
///
/// The client project's lock is derived from the app's, never resolved on
/// its own, so `gleam build` there never asks Hex for versions and two
/// builds of one app use the same packages. A missing app manifest, or one
/// that disagrees with the packages Gleam downloaded for the app, is an
/// error; nothing is resolved afresh.
pub fn pin_dependencies(
  project: String,
  project_files: List(ProjectFile),
) -> Result(List(LockedPackage), String) {
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
  let manifest_path = app_manifest(project)
  use manifest <- result.try(read_app_manifest(manifest_path))
  use providers <- result.try(
    list.try_map(external, fn(module) { provider(project, manifest, module) }),
  )
  use packages <- result.try(project_toml.locked_closure(
    manifest,
    list.unique(providers),
  ))
  use Nil <- result.try(check_downloaded(project, packages))
  use client <- result.try(
    program.absolute_path(files.join(project, client_dir)),
  )
  use packages <- result.try(
    list.try_map(packages, fn(package) { relocate(project, client, package) }),
  )
  log.debug(
    "brazier.build.client_bundle",
    "Pinning the client project to the lock in "
      <> manifest_path
      <> ", with no version resolution: "
      <> string.join(list.map(packages, describe_pin), ", "),
  )
  Ok(packages)
}

/// The app's lock file.
fn app_manifest(project: String) -> String {
  files.join(project, "manifest.toml")
}

fn read_app_manifest(
  path: String,
) -> Result(Dict(String, LockedPackage), String) {
  use exists <- result.try(files.is_file(path))
  case exists {
    True -> project_toml.read_manifest(path)
    False -> {
      log.error(
        "brazier.build.client_bundle",
        "No app lock file at " <> path <> "; refusing to resolve from Hex",
      )
      Error(
        path
        <> " does not exist. The client bundle's packages are pinned to the app's lock file, never resolved from Hex. Run `gleam build` in the app so Gleam writes it, then build again.",
      )
    }
  }
}

/// Every Hex package in `packages` must be the version Gleam downloaded for
/// the app (`build/packages/packages.toml`): the modules each package
/// provides were read from those sources, and the client project pins the
/// manifest's version. A difference means the lock and the downloads
/// disagree.
fn check_downloaded(
  project: String,
  packages: List(LockedPackage),
) -> Result(Nil, String) {
  let hex =
    list.filter(packages, fn(package) {
      case package.source {
        project_toml.HexSource(..) -> True
        project_toml.LocalSource(..) | project_toml.GitSource(..) -> False
      }
    })
  case hex {
    [] -> Ok(Nil)
    _ -> {
      let path = files.join(project, "build/packages/packages.toml")
      use exists <- result.try(files.is_file(path))
      use downloaded <- result.try(case exists {
        True -> project_toml.read_downloaded(path)
        False -> {
          log.error(
            "brazier.build.client_bundle",
            "No download record at " <> path <> "; cannot check the app lock",
          )
          Error(
            path
            <> " does not exist, so the app's packages were never downloaded. Run `gleam deps download` in the app, then build again.",
          )
        }
      })
      list.try_each(hex, fn(package) {
        case dict.get(downloaded, package.name) {
          Ok(version) if version == package.version -> Ok(Nil)
          found -> {
            let held = case found {
              Ok(version) -> "holds " <> package.name <> " " <> version
              Error(Nil) -> "does not hold " <> package.name
            }
            log.error(
              "brazier.build.client_bundle",
              "App lock and downloads disagree on " <> package.name,
            )
            Error(
              app_manifest(project)
              <> " locks "
              <> package.name
              <> " "
              <> package.version
              <> ", but "
              <> files.join(project, "build/packages")
              <> " "
              <> held
              <> " ("
              <> path
              <> "). Run `gleam deps download` in the app so the downloads match the lock, then build again.",
            )
          }
        }
      })
    }
  }
}

/// `package` with a local path made relative to the client project at the
/// absolute path `client`, the form Gleam writes in a manifest.
fn relocate(
  project: String,
  client: String,
  package: LockedPackage,
) -> Result(LockedPackage, String) {
  case package.source {
    project_toml.LocalSource(path:) -> {
      use absolute <- result.try(
        program.absolute_path(files.resolve(project, path)),
      )
      use relative <- result.map(files.relative_path(client, absolute))
      project_toml.LockedPackage(
        ..package,
        source: project_toml.LocalSource(relative),
      )
    }
    project_toml.HexSource(..) | project_toml.GitSource(..) -> Ok(package)
  }
}

fn describe_pin(package: LockedPackage) -> String {
  package.name
  <> " "
  <> package.version
  <> case package.source {
    project_toml.HexSource(..) -> " (hex)"
    project_toml.LocalSource(path:) -> " (path " <> path <> ")"
    project_toml.GitSource(repo:, ..) -> " (git " <> repo <> ")"
  }
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
        "brazier.build.client_bundle",
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
    project_toml.LocalSource(path:) -> files.resolve(project, path)
    project_toml.HexSource(..) | project_toml.GitSource(..) ->
      files.join(project, "build/packages/" <> package.name)
  }
}

/// Replace the client project at `dir`: its sources, its `gleam.toml`
/// pinning `packages` (from `pin_dependencies`) and its `manifest.toml`
/// locking them as the app's lock at `app_manifest` does. The project's own
/// `build` directory is kept so unchanged packages are not recompiled.
pub fn write_project(
  dir: String,
  project_files: List(ProjectFile),
  app_manifest: String,
  packages: List(LockedPackage),
) -> Result(Nil, String) {
  use lines <- result.try(list.try_map(
    packages,
    project_toml.pinned_dependency_line,
  ))
  use manifest <- result.try(project_toml.client_manifest(
    app_manifest,
    packages,
  ))
  use Nil <- result.try(files.delete_if_exists(files.join(dir, "src")))
  use Nil <- result.try(
    list.try_each(project_files, fn(file) {
      files.write(files.join(dir, file.0), file.1)
    }),
  )
  let toml =
    "name = \"brazier_client_app\"\nversion = \"0.1.0\"\ntarget = \"javascript\"\n\n[dependencies]\n"
    <> string.concat(list.map(lines, fn(line) { line <> "\n" }))
  use Nil <- result.try(files.write(files.join(dir, "gleam.toml"), toml))
  use Nil <- result.try(files.write(files.join(dir, "manifest.toml"), manifest))
  log.info(
    "brazier.build.client_bundle",
    "Wrote client project "
      <> dir
      <> " with "
      <> string.inspect(list.length(project_files))
      <> " files and "
      <> string.inspect(list.length(packages))
      <> " dependencies locked to "
      <> app_manifest,
  )
  Ok(Nil)
}

fn module_file(module_path: String) -> String {
  "src/" <> module_path <> ".gleam"
}
