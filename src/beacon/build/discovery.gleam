/// Finds the app module of a project from the glance AST of its sources.
///
/// An app module defines `pub type Model`, `pub type Msg`, `pub fn view` and
/// `pub fn update` (or `pub fn make_update`). When several modules do, the one
/// that references `beacon.app` or `beacon.start` wins; the reference is found
/// through the module's imports, so `import beacon as b` with `b.app(..)` and
/// `import beacon.{app}` with `app(..)` both count, and text in comments or
/// strings never does. Anything else ambiguous is an error that lists the
/// candidates, so the build never picks a module by file order.
import beacon/build/analyzer
import beacon/build/ast_refs.{type Refs}
import beacon/build/files
import beacon/log
import glance
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string

/// The generated server codec. It is build output, never an app module.
pub const codec_module = "beacon_codec"

pub type AppModule {
  AppModule(
    /// File path, e.g. `src/app.gleam`.
    path: String,
    /// Gleam module path, e.g. `app` or `my_app/main`.
    module_path: String,
    source: String,
  )
}

type Candidate {
  Candidate(app: AppModule, starts_beacon: Bool)
}

/// Find the app module below `src_dir`.
pub fn find(src_dir: String) -> Result(AppModule, String) {
  use paths <- result.try(files.list_files(src_dir))
  use candidates <- result.try(
    paths
    |> list.filter(string.ends_with(_, ".gleam"))
    |> list.try_map(fn(path) { candidate(src_dir, path) }),
  )
  let candidates = option.values(candidates)
  let entrypoints = list.filter(candidates, fn(c) { c.starts_beacon })
  case entrypoints, candidates {
    [only], _ -> found(only, "it defines the app and calls beacon.app/start")
    [], [only] -> found(only, "it is the only module that defines the app")
    [], [] ->
      Error(
        "No app module found in "
        <> src_dir
        <> ". Beacon needs one module with `pub type Model`, `pub type Msg`, `pub fn update` (or `pub fn make_update`) and `pub fn view`.",
      )
    [], many -> ambiguous(src_dir, many)
    many, _ -> ambiguous(src_dir, many)
  }
}

/// The Gleam module path of a source file below `src_dir`.
pub fn module_path(src_dir: String, path: String) -> Result(String, String) {
  let prefix = case string.ends_with(src_dir, "/") {
    True -> src_dir
    False -> src_dir <> "/"
  }
  case string.starts_with(path, prefix), string.ends_with(path, ".gleam") {
    True, True ->
      path
      |> string.drop_start(string.length(prefix))
      |> string.drop_end(string.length(".gleam"))
      |> Ok
    _, _ ->
      Error(
        path <> " is not a .gleam file below the source directory " <> src_dir,
      )
  }
}

/// True for the modules Beacon itself provides: `beacon` and `beacon/*`.
pub fn is_framework_module(module_path: String) -> Bool {
  module_path == "beacon" || string.starts_with(module_path, "beacon/")
}

/// True when `module` defines a complete app: Model, Msg, update and view.
pub fn is_app_module(module: glance.Module) -> Bool {
  let public_type = fn(name) {
    list.any(module.custom_types, fn(def) {
      def.definition.name == name && def.definition.publicity == glance.Public
    })
  }
  let public_function = fn(name) {
    list.any(module.functions, fn(def) {
      def.definition.name == name && def.definition.publicity == glance.Public
    })
  }
  public_type("Model")
  && public_type("Msg")
  && public_function("view")
  && { public_function("update") || public_function("make_update") }
}

/// True when `module` references `beacon.app` or `beacon.start`, through a
/// qualified import (aliased or not) or an unqualified one.
pub fn references_beacon_entrypoint(module: glance.Module) -> Bool {
  let beacon_imports =
    list.filter_map(module.imports, fn(def) {
      case def.definition.module {
        "beacon" -> Ok(def.definition)
        _ -> Error(Nil)
      }
    })
  case beacon_imports {
    [] -> False
    _ -> {
      let refs = module_refs(module)
      list.any(beacon_imports, fn(import_) {
        let qualified = case ast_refs.import_qualifier(import_) {
          Ok(qualifier) ->
            set.contains(refs.qualified, #(qualifier, "app"))
            || set.contains(refs.qualified, #(qualifier, "start"))
          Error(Nil) -> False
        }
        let unqualified =
          list.any(import_.unqualified_values, fn(item) {
            { item.name == "app" || item.name == "start" }
            && set.contains(refs.names, option.unwrap(item.alias, item.name))
          })
        qualified || unqualified
      })
    }
  }
}

fn module_refs(module: glance.Module) -> Refs {
  let refs =
    list.fold(module.functions, ast_refs.empty(), fn(refs, def) {
      ast_refs.function(refs, def.definition)
    })
  list.fold(module.constants, refs, fn(refs, def) {
    ast_refs.constant(refs, def.definition)
  })
}

fn candidate(
  src_dir: String,
  path: String,
) -> Result(option.Option(Candidate), String) {
  use module_path <- result.try(module_path(src_dir, path))
  case module_path == codec_module || is_framework_module(module_path) {
    True -> {
      log.debug("beacon.build.discovery", "Skipping " <> path)
      Ok(option.None)
    }
    False -> {
      use source <- result.try(files.read(path))
      use module <- result.try(analyzer.parse(path, source))
      case is_app_module(module) {
        False -> Ok(option.None)
        True -> {
          let starts_beacon = references_beacon_entrypoint(module)
          log.debug(
            "beacon.build.discovery",
            "App module candidate "
              <> path
              <> case starts_beacon {
              True -> " (references beacon.app/start)"
              False -> ""
            },
          )
          Ok(
            option.Some(Candidate(
              app: AppModule(path:, module_path:, source:),
              starts_beacon:,
            )),
          )
        }
      }
    }
  }
}

fn found(candidate: Candidate, reason: String) -> Result(AppModule, String) {
  log.info(
    "beacon.build.discovery",
    "App module: " <> candidate.app.path <> " (" <> reason <> ")",
  )
  Ok(candidate.app)
}

fn ambiguous(
  src_dir: String,
  candidates: List(Candidate),
) -> Result(AppModule, String) {
  let paths = list.map(candidates, fn(c) { c.app.path })
  Error(
    "Several modules in "
    <> src_dir
    <> " define a Beacon app: "
    <> string.join(paths, ", ")
    <> ". Pass the app module to the build, e.g. `gleam run -m beacon/build -- "
    <> result.unwrap(list.first(paths), src_dir)
    <> "`.",
  )
}
