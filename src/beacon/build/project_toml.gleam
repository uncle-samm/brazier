/// Read `gleam.toml` and `manifest.toml` with a real TOML parser.
///
/// The build needs three facts from these files: the project name, where the
/// Beacon sources live, and the exact package versions the app is locked to so
/// the generated client project uses the same ones. Every malformed or missing
/// value is an error naming the file and key; nothing is guessed.
import beacon/log
import gleam/dict.{type Dict}
import gleam/list
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
  HexSource
  LocalSource(path: String)
  GitSource(repo: String, commit: String)
}

/// One entry from the `packages` array of `manifest.toml`.
pub type LockedPackage {
  LockedPackage(
    name: String,
    version: String,
    requirements: List(String),
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
  use name <- result.try(string_field("name"))
  use version <- result.try(string_field("version"))
  use source_kind <- result.try(string_field("source"))
  use requirements <- result.try(case tom.get_array(table, ["requirements"]) {
    Ok(items) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String(requirement) -> Ok(requirement)
          _ -> Error(context <> ": requirements must be strings")
        }
      })
    Error(err) -> Error(context <> ": " <> describe_get_error(err))
  })
  use source <- result.try(case source_kind {
    "hex" -> Ok(HexSource)
    "local" -> result.map(string_field("path"), LocalSource)
    "git" -> {
      use repo <- result.try(string_field("repo"))
      use commit <- result.try(string_field("commit"))
      Ok(GitSource(repo:, commit:))
    }
    other -> Error(context <> ": unknown source " <> string.inspect(other))
  })
  Ok(LockedPackage(name:, version:, requirements:, source:))
}

/// Find the directory holding Beacon's own sources for the project whose
/// `gleam.toml` is at `project_dir`.
///
/// - The Beacon repository itself (`name = "beacon"`) uses `project_dir`.
/// - A path dependency uses that path, relative to `project_dir`.
/// - A Hex or git dependency uses `build/packages/beacon`, which must exist.
pub fn beacon_root(project_dir: String) -> Result(String, String) {
  let toml_path = join(project_dir, "gleam.toml")
  use project <- result.try(read_project(toml_path))
  let root = case project.name, dict.get(project.dependencies, "beacon") {
    "beacon", _ -> Ok(project_dir)
    _, Ok(PathRequirement(path:)) -> Ok(join(project_dir, path))
    _, Ok(HexRequirement(..)) | _, Ok(GitRequirement(..)) ->
      Ok(join(project_dir, "build/packages/beacon"))
    _, Error(Nil) ->
      Error(
        toml_path
        <> " does not list `beacon` under [dependencies]. Add it before running the Beacon build.",
      )
  }
  use root <- result.try(root)
  let marker = join(root, "src/beacon/element.gleam")
  case simplifile.is_file(marker) {
    Ok(True) -> {
      log.debug("beacon.build.project_toml", "Beacon sources at " <> root)
      Ok(root)
    }
    Ok(False) ->
      Error(
        "Beacon sources not found: "
        <> marker
        <> " does not exist. Run `gleam deps download` or fix the beacon dependency in "
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
  use found <- result.try(walk_closure(manifest, names, dict.new()))
  found
  |> dict.values
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  |> Ok
}

fn walk_closure(
  manifest: Dict(String, LockedPackage),
  pending: List(String),
  found: Dict(String, LockedPackage),
) -> Result(Dict(String, LockedPackage), String) {
  case pending {
    [] -> Ok(found)
    [name, ..rest] ->
      case dict.has_key(found, name) {
        True -> walk_closure(manifest, rest, found)
        False ->
          case dict.get(manifest, name) {
            Ok(package) ->
              walk_closure(
                manifest,
                list.append(package.requirements, rest),
                dict.insert(found, name, package),
              )
            Error(Nil) ->
              Error(
                "Package `"
                <> name
                <> "` is needed by the client bundle but is not locked in manifest.toml. Add it to gleam.toml and run `gleam deps download`.",
              )
          }
      }
  }
}

/// Render the `[dependencies]` entry that pins a locked package exactly.
/// Local packages keep their path (made absolute by the caller); git
/// packages are rejected because the client project cannot reproduce the
/// lock for them.
pub fn pinned_dependency_line(
  package: LockedPackage,
  local_path: fn(String) -> String,
) -> Result(String, String) {
  case package.source {
    HexSource ->
      Ok(package.name <> " = " <> toml_string("== " <> package.version))
    LocalSource(path:) ->
      Ok(
        package.name <> " = { path = " <> toml_string(local_path(path)) <> " }",
      )
    GitSource(repo:, ..) ->
      Error(
        "Package `"
        <> package.name
        <> "` comes from git ("
        <> repo
        <> "). Client bundles support Hex and path dependencies only.",
      )
  }
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
