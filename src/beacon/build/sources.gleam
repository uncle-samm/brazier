/// Collects the source modules the analyzer and the client bundle need.
///
/// Imports are read from the glance AST. An imported module is a user module
/// when `<src_dir>/<module>.gleam` exists; anything else comes from a
/// dependency and is skipped. Beacon's own modules (`beacon` and `beacon/*`)
/// are skipped by exact name. A user module that exists but cannot be read
/// or parsed is an error.
import beacon/build/analyzer
import beacon/build/discovery
import beacon/build/files
import beacon/log
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// #(module path, source text).
pub type Source =
  #(String, String)

/// Framework modules the client project gets as generated shims instead of
/// copies of their server source.
pub const shimmed_framework_modules = ["beacon/log"]

/// Every user module reachable from the app module's imports, in import
/// order, each once, the app module excluded.
pub fn app_externals(
  src_dir: String,
  app: discovery.AppModule,
) -> Result(List(Source), String) {
  use direct <- result.try(user_imports(src_dir, app.path, app.source))
  use imported <- result.map(walk_user(src_dir, direct, set.new(), []))
  list.filter(imported, fn(s) { s.0 != app.module_path })
}

/// The Beacon framework modules (`beacon/*`) that `sources` import, followed
/// transitively through Beacon's own sources in `beacon_root/src`. Shimmed
/// modules are not followed: the client project gets generated versions.
pub fn framework_closure(
  beacon_root: String,
  sources: List(String),
) -> Result(List(Source), String) {
  use start <- result.try(
    list.try_map(sources, fn(source) {
      framework_imports("client source", source)
    })
    |> result.map(list.flatten),
  )
  walk_framework(beacon_root, start, set.new(), [])
}

fn walk_user(
  src_dir: String,
  pending: List(String),
  seen: Set(String),
  acc: List(Source),
) -> Result(List(Source), String) {
  case pending {
    [] -> Ok(list.reverse(acc))
    [module_path, ..rest] ->
      case set.contains(seen, module_path) {
        True -> walk_user(src_dir, rest, seen, acc)
        False -> {
          let path = module_file(src_dir, module_path)
          use text <- result.try(files.read(path))
          use children <- result.try(user_imports(src_dir, path, text))
          log.debug("beacon.build.sources", "User module " <> module_path)
          walk_user(
            src_dir,
            list.append(children, rest),
            set.insert(seen, module_path),
            [#(module_path, text), ..acc],
          )
        }
      }
  }
}

/// The module path of each user module `source` imports.
fn user_imports(
  src_dir: String,
  path: String,
  source: String,
) -> Result(List(String), String) {
  use module <- result.try(analyzer.parse(path, source))
  list.try_fold(module.imports, [], fn(acc, def) {
    let import_ = def.definition
    case discovery.is_framework_module(import_.module) {
      True -> Ok(acc)
      False -> {
        use is_user <- result.map(
          files.is_file(module_file(src_dir, import_.module)),
        )
        case is_user {
          True -> [import_.module, ..acc]
          False -> {
            log.debug(
              "beacon.build.sources",
              import_.module
                <> " is not in "
                <> src_dir
                <> "; dependency module",
            )
            acc
          }
        }
      }
    }
  })
  |> result.map(list.reverse)
}

fn walk_framework(
  beacon_root: String,
  pending: List(String),
  seen: Set(String),
  acc: List(Source),
) -> Result(List(Source), String) {
  case pending {
    [] -> Ok(list.reverse(acc))
    [module_path, ..rest] ->
      case
        set.contains(seen, module_path)
        || list.contains(shimmed_framework_modules, module_path)
      {
        True -> walk_framework(beacon_root, rest, seen, acc)
        False -> {
          let path = module_file(files.join(beacon_root, "src"), module_path)
          use text <- result.try(files.read(path))
          use children <- result.try(framework_imports(path, text))
          walk_framework(
            beacon_root,
            list.append(children, rest),
            set.insert(seen, module_path),
            [#(module_path, text), ..acc],
          )
        }
      }
  }
}

fn framework_imports(
  path: String,
  source: String,
) -> Result(List(String), String) {
  use module <- result.map(analyzer.parse(path, source))
  list.filter_map(module.imports, fn(def) {
    let module_path = def.definition.module
    case string.starts_with(module_path, "beacon/") {
      True -> Ok(module_path)
      False -> Error(Nil)
    }
  })
}

fn module_file(src_dir: String, module_path: String) -> String {
  files.join(src_dir, module_path <> ".gleam")
}
