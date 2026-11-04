/// Finds the app module of a project from the glance AST of its sources.
///
/// The app module is the one whose `pub fn main` reaches a call to
/// `brazier.simple`, `brazier.application` or `brazier.full_application`
/// (see `brazier/build/app_call`). The call is found through the module's
/// imports, so `import brazier as b` with `b.simple(..)` and
/// `import brazier.{simple}` with `simple(..)` both count, and text in
/// comments or strings never does. More than one such module is an error
/// that lists them, so the build never picks a module by file order.
import brazier/build/analyzer
import brazier/build/files
import brazier/build/reach
import brazier/log
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// The generated server codec. It is build output, never an app module.
pub const codec_module = "brazier_codec"

pub type AppModule {
  AppModule(
    /// File path, e.g. `src/app.gleam`.
    path: String,
    /// Gleam module path, e.g. `app` or `my_app/main`.
    module_path: String,
    source: String,
  )
}

/// Find the app module below `src_dir`.
pub fn find(src_dir: String) -> Result(AppModule, String) {
  use paths <- result.try(files.list_files(src_dir))
  use candidates <- result.try(
    paths
    |> list.filter(string.ends_with(_, ".gleam"))
    |> list.sort(string.compare)
    |> list.try_map(fn(path) { candidate(src_dir, path) }),
  )
  case option.values(candidates) {
    [only] -> {
      log.info(
        "brazier.build.discovery",
        "App module: " <> only.path <> " (its `pub fn main` builds the app)",
      )
      Ok(only)
    }
    [] ->
      Error(
        "No app module found in "
        <> src_dir
        <> ". Brazier needs one module whose `pub fn main` builds the app with brazier.simple, brazier.application or brazier.full_application.",
      )
    [first, ..] as many -> {
      let paths = list.map(many, fn(app) { app.path })
      Error(
        "Several modules in "
        <> src_dir
        <> " build a Brazier app in `pub fn main`: "
        <> string.join(paths, ", ")
        <> ". Pass the app module to the build, e.g. `gleam run -m brazier/build -- "
        <> first.path
        <> "`.",
      )
    }
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

/// True for the modules Brazier itself provides: `brazier` and `brazier/*`.
pub fn is_framework_module(module_path: String) -> Bool {
  reach.is_framework_module(module_path)
}

fn candidate(
  src_dir: String,
  path: String,
) -> Result(option.Option(AppModule), String) {
  use module_path <- result.try(module_path(src_dir, path))
  case module_path == codec_module || is_framework_module(module_path) {
    True -> {
      log.debug("brazier.build.discovery", "Skipping " <> path)
      Ok(option.None)
    }
    False -> {
      use source <- result.try(files.read(path))
      use module <- result.map(analyzer.parse(path, source))
      case analyzer.defines_app(module_path, source, module) {
        False -> option.None
        True -> {
          log.debug("brazier.build.discovery", "App module candidate " <> path)
          option.Some(AppModule(path:, module_path:, source:))
        }
      }
    }
  }
}
