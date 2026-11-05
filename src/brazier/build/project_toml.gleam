/// Read `gleam.toml` and `manifest.toml` with a real TOML parser.
///
/// The build needs three facts from these files: the project name, where the
/// Brazier sources live, and the exact package versions the app is locked to so
/// the generated client project uses the same ones. It also renders that
/// client project's `gleam.toml` pins and `manifest.toml` from the app's lock.
/// Every malformed or missing value is an error naming the file and key;
/// nothing is guessed.
import brazier/log
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tom

/// How a dependency is declared in `gleam.toml`.
pub type Requirement {
  /// `pkg = ">= 1.0.0 and < 2.0.0"` or `pkg = { version = "..." }`
  HexRequirement(version: String)
  /// `pkg = { path = "../pkg" }`
  PathRequirement(path: String)
  /// `pkg = { git = "...", ref = "..." }`
  GitRequirement(repo: String)
}

/// The parts of `gleam.toml` the build uses.
pub type ProjectConfig {
  ProjectConfig(name: String, dependencies: Dict(String, Requirement))
}

/// Where a locked package came from.
pub type PackageSource {
  /// A Hex package. `outer_checksum` is the SHA-256 of its tarball, which
  /// Gleam checks when it unpacks the package.
  HexSource(outer_checksum: String)
  /// A path dependency, relative to the project that holds the manifest.
  LocalSource(path: String)
  GitSource(repo: String, commit: String)
}

/// One entry from the `packages` array of `manifest.toml`.
pub type LockedPackage {
  LockedPackage(
    name: String,
    version: String,
    build_tools: List(String),
    requirements: List(String),
    /// The OTP application name. Gleam writes it for Hex packages only.
    otp_app: Option(String),
    source: PackageSource,
  )
}

/// Read and parse a `gleam.toml` file.
pub fn read_project(path: String) -> Result(ProjectConfig, String) {
  use text <- result.try(read_file(path))
  parse_project(path, text)
}

/// Parse `gleam.toml` contents. `path` is used only in error messages.
pub fn parse_project(
  path: String,
  text: String,
) -> Result(ProjectConfig, String) {
  use doc <- result.try(parse_toml(path, text))
  use name <- result.try(
    tom.get_string(doc, ["name"]) |> result.map_error(get_error(path, _)),
  )
  use dependencies <- result.try(case tom.get_table(doc, ["dependencies"]) {
    Ok(table) -> parse_requirements(path, table)
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(err) -> Error(get_error(path, err))
  })
  Ok(ProjectConfig(name:, dependencies:))
}

fn parse_requirements(
  path: String,
  table: Dict(String, tom.Toml),
) -> Result(Dict(String, Requirement), String) {
  table
  |> dict.to_list
  |> list.try_map(fn(entry) {
    let #(name, value) = entry
    parse_requirement(path, name, value)
    |> result.map(fn(requirement) { #(name, requirement) })
  })
  |> result.map(dict.from_list)
}

fn parse_requirement(
  path: String,
  name: String,
  value: tom.Toml,
) -> Result(Requirement, String) {
  let key = ["dependencies", name]
  case value {
    tom.String(version) -> Ok(HexRequirement(version:))
    tom.InlineTable(table) | tom.Table(table) ->
      case
        tom.get_string(table, ["path"]),
        tom.get_string(table, ["git"]),
        tom.get_string(table, ["version"])
      {
        Ok(dep_path), _, _ -> Ok(PathRequirement(path: dep_path))
        _, Ok(repo), _ -> Ok(GitRequirement(repo:))
        _, _, Ok(version) -> Ok(HexRequirement(version:))
        _, _, _ ->
          Error(
            path
            <> ": "
            <> string.join(key, ".")
            <> " must set one of `version`, `path` or `git`",
          )
      }
    _ ->
      Error(
        path
        <> ": "
        <> string.join(key, ".")
        <> " must be a version string or a table",
      )
  }
}

/// Read and parse a `manifest.toml` file into a map of package name to entry.
pub fn read_manifest(
  path: String,
) -> Result(Dict(String, LockedPackage), String) {
  use text <- result.try(read_file(path))
  parse_manifest(path, text)
}

/// Parse `manifest.toml` contents. `path` is used only in error messages.
pub fn parse_manifest(
  path: String,
  text: String,
) -> Result(Dict(String, LockedPackage), String) {
  use doc <- result.try(parse_toml(path, text))
  use entries <- result.try(case dict.get(doc, "packages") {
    Ok(tom.Array(items)) -> Ok(items)
    Ok(_) -> Error(path <> ": `packages` must be an array")
    Error(Nil) -> Error(path <> ": missing `packages`")
  })
  entries
  |> list.index_map(fn(entry, index) { parse_package(path, index, entry) })
  |> result.all
  |> result.map(fn(packages) {
    packages
    |> list.map(fn(package) { #(package.name, package) })
    |> dict.from_list
  })
}

fn parse_package(
  path: String,
  index: Int,
  entry: tom.Toml,
) -> Result(LockedPackage, String) {
  let context = path <> ": packages[" <> string.inspect(index) <> "]"
  use table <- result.try(case entry {
    tom.InlineTable(table) | tom.Table(table) -> Ok(table)
    _ -> Error(context <> " must be a table")
  })
  let string_field = fn(key) {
    tom.get_string(table, [key])
    |> result.map_error(fn(err) { context <> ": " <> describe_get_error(err) })
  }
  let string_array_field = fn(key) {
    case tom.get_array(table, [key]) {
      Ok(items) ->
        list.try_map(items, fn(item) {
          case item {
            tom.String(value) -> Ok(value)
            _ -> Error(context <> ": " <> key <> " must be strings")
          }
        })
      Error(err) -> Error(context <> ": " <> describe_get_error(err))
    }
  }
  use name <- result.try(string_field("name"))
  use version <- result.try(string_field("version"))
  use source_kind <- result.try(string_field("source"))
  use build_tools <- result.try(string_array_field("build_tools"))
  use requirements <- result.try(string_array_field("requirements"))
  use otp_app <- result.try(case tom.get_string(table, ["otp_app"]) {
    Ok(otp_app) -> Ok(Some(otp_app))
    Error(tom.NotFound(_)) -> Ok(None)
    Error(err) -> Error(context <> ": " <> describe_get_error(err))
  })
  use source <- result.try(case source_kind {
    "hex" ->
      string_field("outer_checksum")
      |> result.map(HexSource)
      |> result.map_error(fn(reason) {
        reason
        <> ". Gleam writes the checksum of every Hex package; without it the lock cannot be verified. Delete "
        <> path
        <> " and run `gleam deps download` to rewrite it."
      })
    "local" -> result.map(string_field("path"), LocalSource)
    "git" -> {
      use repo <- result.try(string_field("repo"))
      use commit <- result.try(string_field("commit"))
      Ok(GitSource(repo:, commit:))
    }
    other -> Error(context <> ": unknown source " <> string.inspect(other))
  })
  Ok(LockedPackage(
    name:,
    version:,
    build_tools:,
    requirements:,
    otp_app:,
    source:,
  ))
}

/// Read Gleam's record of the packages it downloaded,
/// `build/packages/packages.toml`: package name to version. Gleam writes it
/// after every download, so it says which version of each Hex package the
/// sources in `build/packages` are.
pub fn read_downloaded(path: String) -> Result(Dict(String, String), String) {
  use text <- result.try(read_file(path))
  parse_downloaded(path, text)
}

/// Parse `build/packages/packages.toml` contents. `path` is used only in
/// error messages.
pub fn parse_downloaded(
  path: String,
  text: String,
) -> Result(Dict(String, String), String) {
  use doc <- result.try(parse_toml(path, text))
  use table <- result.try(
    tom.get_table(doc, ["packages"]) |> result.map_error(get_error(path, _)),
  )
  table
  |> dict.to_list
  |> list.try_map(fn(entry) {
    case entry.1 {
      tom.String(version) -> Ok(#(entry.0, version))
      _ ->
        Error(path <> ": packages." <> entry.0 <> " must be a version string")
    }
  })
  |> result.map(dict.from_list)
}

/// Find the directory holding Brazier's own sources for the project whose
/// `gleam.toml` is at `project_dir`.
///
/// - The Brazier repository itself (`name = "brazier"`) uses `project_dir`.
/// - A path dependency uses that path, relative to `project_dir`.
/// - A Hex or git dependency uses `build/packages/brazier`, which must exist.
pub fn brazier_root(project_dir: String) -> Result(String, String) {
  locate_brazier(project_dir)
  |> result.map(fn(found) { found.0 })
}

/// The directory holding the client runtime (`brazier_client_ffi.mjs` and
/// `brazier_client/*.mjs`) for the project at `project_dir`.
///
/// - A checkout of the Brazier repository (the repository itself, a path
///   dependency, or a git dependency) has it at `brazier_client/src`.
/// - A Hex package has it at `priv/brazier_client_src`, because a Hex
///   tarball carries only `src` and `priv`; `scripts/publish.sh` copies
///   `brazier_client/src` there before it builds the tarball.
///
/// A directory without `brazier_client_ffi.mjs` is an error naming it.
pub fn client_runtime_dir(project_dir: String) -> Result(String, String) {
  use #(root, layout) <- result.try(locate_brazier(project_dir))
  let dir = case layout {
    Checkout -> join(root, "brazier_client/src")
    HexPackage -> join(root, hex_client_runtime_dir)
  }
  let marker = join(dir, "brazier_client_ffi.mjs")
  case simplifile.is_file(marker) {
    Ok(True) -> {
      log.debug("brazier.build.project_toml", "Client runtime at " <> dir)
      Ok(dir)
    }
    Ok(False) ->
      Error(
        "Brazier client runtime not found: "
        <> marker
        <> " does not exist. "
        <> case layout {
          Checkout -> "The Brazier checkout is incomplete."
          HexPackage ->
            "The brazier package was published without it; publish with scripts/publish.sh."
        },
      )
    Error(err) ->
      Error("Cannot check " <> marker <> ": " <> simplifile.describe_error(err))
  }
}

/// Where a Hex package of Brazier carries the client runtime, relative to
/// the package root.
pub const hex_client_runtime_dir = "priv/brazier_client_src"

/// How a project gets Brazier's sources.
type Layout {
  /// The whole repository: Brazier itself, a path or a git dependency.
  Checkout
  /// A package downloaded from Hex: only `src`, `priv` and metadata.
  HexPackage
}

/// Find Brazier's root for the project at `project_dir`, and its layout.
/// The root must hold `src/brazier/element.gleam`.
fn locate_brazier(project_dir: String) -> Result(#(String, Layout), String) {
  let toml_path = join(project_dir, "gleam.toml")
  use project <- result.try(read_project(toml_path))
  let root = case project.name, dict.get(project.dependencies, "brazier") {
    "brazier", _ -> Ok(#(project_dir, Checkout))
    _, Ok(PathRequirement(path:)) -> Ok(#(join(project_dir, path), Checkout))
    _, Ok(GitRequirement(..)) ->
      Ok(#(join(project_dir, "build/packages/brazier"), Checkout))
    _, Ok(HexRequirement(..)) ->
      Ok(#(join(project_dir, "build/packages/brazier"), HexPackage))
    _, Error(Nil) ->
      Error(
        toml_path
        <> " does not list `brazier` under [dependencies]. Add it before running the Brazier build.",
      )
  }
  use #(root, layout) <- result.try(root)
  let marker = join(root, "src/brazier/element.gleam")
  case simplifile.is_file(marker) {
    Ok(True) -> {
      log.debug("brazier.build.project_toml", "Brazier sources at " <> root)
      Ok(#(root, layout))
    }
    Ok(False) ->
      Error(
        "Brazier sources not found: "
        <> marker
        <> " does not exist. Run `gleam deps download` or fix the brazier dependency in "
        <> toml_path
        <> ".",
      )
    Error(err) ->
      Error("Cannot check " <> marker <> ": " <> simplifile.describe_error(err))
  }
}

/// Collect `names` and every package they depend on, transitively, from a
/// parsed manifest. Returns the packages sorted by name. A name that is not
/// in the manifest is an error, because the client project would otherwise
/// resolve it to whatever version Hex offers today.
pub fn locked_closure(
  manifest: Dict(String, LockedPackage),
  names: List(String),
) -> Result(List(LockedPackage), String) {
  let pending = list.map(names, fn(name) { #(name, None) })
  use found <- result.try(walk_closure(manifest, pending, dict.new()))
  found
  |> dict.values
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  |> Ok
}

/// `pending` holds each package still to visit and the locked package that
/// requires it (`None` for a root).
fn walk_closure(
  manifest: Dict(String, LockedPackage),
  pending: List(#(String, Option(String))),
  found: Dict(String, LockedPackage),
) -> Result(Dict(String, LockedPackage), String) {
  case pending {
    [] -> Ok(found)
    [#(name, required_by), ..rest] ->
      case dict.has_key(found, name) {
        True -> walk_closure(manifest, rest, found)
        False ->
          case dict.get(manifest, name), required_by {
            Ok(package), _ ->
              walk_closure(
                manifest,
                list.append(
                  list.map(package.requirements, fn(requirement) {
                    #(requirement, Some(name))
                  }),
                  rest,
                ),
                dict.insert(found, name, package),
              )
            Error(Nil), None ->
              Error(
                "Package `"
                <> name
                <> "` is needed by the client bundle but is not locked in manifest.toml. Add it to gleam.toml and run `gleam deps download`.",
              )
            Error(Nil), Some(parent) ->
              Error(
                "manifest.toml is inconsistent: the locked package `"
                <> parent
                <> "` requires `"
                <> name
                <> "`, which has no entry of its own. Delete manifest.toml and run `gleam deps download` to rewrite it.",
              )
          }
      }
  }
}

/// Render the `[dependencies]` entry of the client project's `gleam.toml`
/// that pins a locked package exactly. A local package's path is used as
/// given, so the caller makes it relative to the client project first. Git
/// packages are rejected because the client project cannot reproduce the
/// lock for them.
pub fn pinned_dependency_line(
  package: LockedPackage,
) -> Result(String, String) {
  use requirement <- result.map(pinned_requirement(package))
  package.name <> " = " <> requirement
}

/// The requirement that pins `package`: `"== 1.2.3"` for Hex, an inline
/// `{ path = ... }` table for a local package.
fn pinned_requirement(package: LockedPackage) -> Result(String, String) {
  case package.source {
    HexSource(..) -> Ok(toml_string("== " <> package.version))
    LocalSource(path:) -> Ok("{ path = " <> toml_string(path) <> " }")
    GitSource(repo:, ..) -> git_unsupported(package.name, repo)
  }
}

fn git_unsupported(name: String, repo: String) -> Result(a, String) {
  Error(
    "Package `"
    <> name
    <> "` comes from git ("
    <> repo
    <> "). Client bundles support Hex and path dependencies only.",
  )
}

/// Render the client project's `manifest.toml` from the locked `packages`
/// the client's `gleam.toml` pins (see `pinned_dependency_line`), copied
/// from the app's lock file at `source`. The `[requirements]` table states
/// exactly what that `gleam.toml` declares, so Gleam finds the manifest up
/// to date and uses it without resolving versions, which needs Hex. Local
/// paths are used as given, relative to the client project.
pub fn client_manifest(
  source: String,
  packages: List(LockedPackage),
) -> Result(String, String) {
  let packages =
    list.sort(packages, fn(a, b) { string.compare(a.name, b.name) })
  use entries <- result.try(list.try_map(packages, manifest_entry))
  use requirements <- result.try(
    list.try_map(packages, fn(package) {
      use requirement <- result.map(pinned_requirement(package))
      let requirement = case package.source {
        HexSource(..) -> "{ version = " <> requirement <> " }"
        LocalSource(..) | GitSource(..) -> requirement
      }
      package.name <> " = " <> requirement
    }),
  )
  Ok(
    "# Generated by the Brazier build from "
    <> source
    <> ".\n# Every build rewrites it. It pins the client project to the app's lock,\n# so `gleam build` here never resolves versions from Hex.\n\npackages = [\n"
    <> string.concat(list.map(entries, fn(entry) { "  " <> entry <> ",\n" }))
    <> "]\n\n[requirements]\n"
    <> string.concat(list.map(requirements, fn(line) { line <> "\n" })),
  )
}

/// One `packages` entry, in the order and format Gleam writes it.
fn manifest_entry(package: LockedPackage) -> Result(String, String) {
  let strings = fn(values) {
    "[" <> string.join(list.map(values, toml_string), ", ") <> "]"
  }
  use source <- result.map(case package.source {
    HexSource(outer_checksum:) ->
      Ok("source = \"hex\", outer_checksum = " <> toml_string(outer_checksum))
    LocalSource(path:) -> Ok("source = \"local\", path = " <> toml_string(path))
    GitSource(repo:, ..) -> git_unsupported(package.name, repo)
  })
  let otp_app = case package.otp_app {
    Some(otp_app) -> ", otp_app = " <> toml_string(otp_app)
    None -> ""
  }
  "{ name = "
  <> toml_string(package.name)
  <> ", version = "
  <> toml_string(package.version)
  <> ", build_tools = "
  <> strings(package.build_tools)
  <> ", requirements = "
  <> strings(package.requirements)
  <> otp_app
  <> ", "
  <> source
  <> " }"
}

/// Quote a value as a TOML basic string.
pub fn toml_string(value: String) -> String {
  let escaped =
    value
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\r", "\\r")
    |> string.replace("\t", "\\t")
  "\"" <> escaped <> "\""
}

fn read_file(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(err) {
    "Cannot read " <> path <> ": " <> simplifile.describe_error(err)
  })
}

fn parse_toml(
  path: String,
  text: String,
) -> Result(Dict(String, tom.Toml), String) {
  tom.parse(text)
  |> result.map_error(fn(err) {
    case err {
      tom.Unexpected(got:, expected:) ->
        "Invalid TOML in "
        <> path
        <> ": expected "
        <> expected
        <> ", got "
        <> string.inspect(got)
      tom.KeyAlreadyInUse(key:) ->
        "Invalid TOML in "
        <> path
        <> ": key "
        <> string.join(key, ".")
        <> " is defined twice"
    }
  })
}

fn get_error(path: String, err: tom.GetError) -> String {
  path <> ": " <> describe_get_error(err)
}

fn describe_get_error(err: tom.GetError) -> String {
  case err {
    tom.NotFound(key:) -> "missing key `" <> string.join(key, ".") <> "`"
    tom.WrongType(key:, expected:, got:) ->
      "key `"
      <> string.join(key, ".")
      <> "` must be "
      <> expected
      <> ", got "
      <> got
  }
}

fn join(dir: String, path: String) -> String {
  case dir, string.starts_with(path, "/") {
    _, True -> path
    ".", False -> path
    "", False -> path
    _, False -> dir <> "/" <> path
  }
}
