/// Collects the source modules the analyzer and the client bundle need.
///
/// Imports are read from the glance AST. An imported module is a user module
/// when `<src_dir>/<module>.gleam` exists; anything else comes from a
/// dependency and is skipped. Beacon's own modules (`beacon` and `beacon/*`)
/// are skipped by exact name. A user module that exists but cannot be read
/// or parsed is an error.
///
/// Every module is returned as a `Source` triple, the shape
/// `analyzer.analyze_multi` takes: #(alias, module path, source text).
import beacon/build/analyzer
import beacon/build/ast_refs
import beacon/build/discovery
import beacon/build/field_type
import beacon/build/files
import beacon/log
import glance
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// #(alias, module path, source text).
pub type Source =
  #(String, String, String)

/// Framework modules the client project gets as generated shims instead of
/// copies of their server source.
pub const shimmed_framework_modules = ["beacon", "beacon/log"]

/// Every user module reachable from the app module's imports, plus the other
/// modules in the app module's directory. Import order is kept, each module
/// appears once, and the app module itself is excluded.
pub fn app_externals(
  src_dir: String,
  app: discovery.AppModule,
) -> Result(List(Source), String) {
  use imported <- result.try(
    transitive_user_imports(src_dir, app.path, app.source, fn(_path, source) {
      Ok(source)
    }),
  )
  use siblings <- result.try(siblings(src_dir, app))
  let imported_paths = set.from_list(list.map(imported, fn(s) { s.1 }))
  let extra =
    list.filter(siblings, fn(s) { !set.contains(imported_paths, s.1) })
  Ok(
    list.filter(list.append(imported, extra), fn(s) { s.1 != app.module_path }),
  )
}

/// The client-visible part of every user module reachable from
/// `client_source`. Each module is reduced to its client source before its
/// imports are followed, so a server-only import never pulls a private
/// module into the JavaScript build. Modules with no client-visible code are
/// left out.
pub fn client_externals(
  src_dir: String,
  app_path: String,
  client_source: String,
) -> Result(List(Source), String) {
  transitive_user_imports(src_dir, app_path, client_source, fn(path, source) {
    analyzer.extract_client_source(source)
    |> result.map_error(fn(reason) {
      "Cannot extract the client-visible part of " <> path <> ": " <> reason
    })
  })
  |> result.map(list.filter(_, fn(s) { string.trim(s.2) != "" }))
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

/// The user modules `source` imports, transitively. `prepare` turns a
/// module's file contents into the text that is kept and whose imports are
/// followed.
fn transitive_user_imports(
  src_dir: String,
  path: String,
  source: String,
  prepare: fn(String, String) -> Result(String, String),
) -> Result(List(Source), String) {
  use direct <- result.try(user_imports(src_dir, path, source))
  walk_user(src_dir, direct, prepare, set.new(), [])
}

fn walk_user(
  src_dir: String,
  pending: List(#(String, String)),
  prepare: fn(String, String) -> Result(String, String),
  seen: Set(String),
  acc: List(Source),
) -> Result(List(Source), String) {
  case pending {
    [] -> Ok(list.reverse(acc))
    [#(alias, module_path), ..rest] ->
      case set.contains(seen, module_path) {
        True -> walk_user(src_dir, rest, prepare, seen, acc)
        False -> {
          let path = module_file(src_dir, module_path)
          use text <- result.try(files.read(path))
          use kept <- result.try(prepare(path, text))
          use children <- result.try(user_imports(src_dir, path, kept))
          log.debug(
            "beacon.build.sources",
            "User module " <> module_path <> " (alias " <> alias <> ")",
          )
          walk_user(
            src_dir,
            list.append(children, rest),
            prepare,
            set.insert(seen, module_path),
            [#(alias, module_path, kept), ..acc],
          )
        }
      }
  }
}

/// The #(alias, module path) of each user module `source` imports.
fn user_imports(
  src_dir: String,
  path: String,
  source: String,
) -> Result(List(#(String, String)), String) {
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
          True -> [#(alias(import_), import_.module), ..acc]
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

/// The other `.gleam` files in the app module's directory, with the file
/// name as alias.
fn siblings(
  src_dir: String,
  app: discovery.AppModule,
) -> Result(List(Source), String) {
  let dir = files.parent(app.path)
  use entries <- result.try(files.list_directory(dir))
  entries
  |> list.filter(string.ends_with(_, ".gleam"))
  |> list.map(files.join(dir, _))
  |> list.filter(fn(path) { path != app.path })
  |> list.try_fold([], fn(acc, path) {
    use module_path <- result.try(discovery.module_path(src_dir, path))
    case
      module_path == discovery.codec_module
      || discovery.is_framework_module(module_path)
    {
      True -> Ok(acc)
      False -> {
        use text <- result.map(files.read(path))
        [#(last_segment(module_path), module_path, text), ..acc]
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
            [#(last_segment(module_path), module_path, text), ..acc],
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

/// The alias a module is analyzed under: the import's alias, or its last
/// path segment when the import has none or discards it.
fn alias(import_: glance.Import) -> String {
  case ast_refs.import_qualifier(import_) {
    Ok(alias) -> alias
    Error(Nil) -> last_segment(import_.module)
  }
}

fn last_segment(module_path: String) -> String {
  let assert Ok(segment) = field_type.last_segment(module_path)
    as "string.split always returns at least one segment"
  segment
}
