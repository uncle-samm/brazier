/// Collects the source modules the analyzer and the client bundle need.
///
/// Imports are read from the glance AST. An imported module is a user module
/// when `<src_dir>/<module>.gleam` exists; anything else comes from a
/// dependency and is skipped. Brazier's own modules (`brazier` and `brazier/*`)
/// are skipped by exact name. A user module that exists but cannot be read
/// or parsed is an error.
import brazier/build/analyzer
import brazier/build/discovery
import brazier/build/files
import brazier/build/reach
import brazier/log
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// #(module path, source text).
pub type Source =
  #(String, String)

/// Framework modules the client project gets as generated shims instead of
/// copies of their server source.
pub const shimmed_framework_modules = ["brazier/log"]

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

/// The sources of the Brazier modules the analyzer indexes with the user
/// modules (`reach.is_pruned_framework_module`), from `brazier_root/src`.
pub fn pruned_framework_sources(
  brazier_root: String,
) -> Result(List(Source), String) {
  let path = module_file(files.join(brazier_root, "src"), reach.stream_module)
  use text <- result.map(files.read(path))
  log.debug("brazier.build.sources", "Pruned framework module " <> path)
  [#(reach.stream_module, text)]
}

/// The Brazier framework modules (`brazier/*`) that `sources` import, followed
/// transitively through Brazier's own sources in `brazier_root/src`. Shimmed
/// modules are not followed: the client project gets generated versions.
/// Pruned modules (`brazier/stream`) are not followed either: the analyzer
/// emitted their reached definitions with the client modules, and those
/// copies' imports are in `sources`.
pub fn framework_closure(
  brazier_root: String,
  sources: List(String),
) -> Result(List(Source), String) {
  use start <- result.try(
    list.try_map(sources, fn(source) {
      framework_imports("client source", source)
    })
    |> result.map(list.flatten),
  )
  walk_framework(brazier_root, start, set.new(), [])
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
          log.debug("brazier.build.sources", "User module " <> module_path)
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
              "brazier.build.sources",
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
  brazier_root: String,
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
        || reach.is_pruned_framework_module(module_path)
      {
        True -> walk_framework(brazier_root, rest, seen, acc)
        False -> {
          let path = module_file(files.join(brazier_root, "src"), module_path)
          use text <- result.try(files.read(path))
          use children <- result.try(framework_imports(path, text))
          walk_framework(
            brazier_root,
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
    case string.starts_with(module_path, "brazier/") {
      True -> Ok(module_path)
      False -> Error(Nil)
    }
  })
}

fn module_file(src_dir: String, module_path: String) -> String {
  files.join(src_dir, module_path <> ".gleam")
}
