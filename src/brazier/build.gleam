/// The Brazier build: generates an app's server codec and client bundle.
///
/// Usage, from the app project's root:
///
/// ```sh
/// gleam run -m brazier/build                    # find the app module in src
/// gleam run -m brazier/build -- src/my_app.gleam  # use this app module
/// ```
///
/// The build:
///
/// 1. Finds the app module (see `brazier/build/discovery`) and the user
///    modules it uses (`brazier/build/sources`).
/// 2. Analyzes them (`brazier/build/analyzer`): the app constructor call, the
///    code that reaches the browser, and the Model and Msg codecs.
/// 3. Writes `build/brazier_contract.json` (`brazier/build/contract`).
/// 4. Generates `src/brazier_codec.gleam` (`brazier/build/server_codec`) and
///    compiles the project with `gleam build`.
/// 5. Builds the client bundle into `priv/static` and points
///    `priv/static/brazier_client.manifest` at it
///    (`brazier/build/client_bundle`).
///
/// Any failure stops the build and exits with status 1. A codec that does
/// not compile is deleted, and a failed client bundle deletes the manifest,
/// so `brazier.start` refuses to run with artifacts from an older build.
import brazier/build/analyzer.{type Analysis}
import brazier/build/client_bundle
import brazier/build/contract
import brazier/build/discovery.{type AppModule}
import brazier/build/files
import brazier/build/program
import brazier/build/project_toml
import brazier/build/server_codec
import brazier/build/sources
import brazier/log
import gleam/list
import gleam/result
import gleam/set
import gleam/string

/// What to build.
pub type Target {
  /// Find the app module below this source directory.
  SourceDir(path: String)
  /// Build this app module; its source directory is the project's `src`.
  AppFile(path: String)
}

/// The artifacts of a successful build.
pub type Built {
  Built(app: AppModule, codec_path: String, bundle: client_bundle.Bundle)
}

pub const usage =
  "Usage: gleam run -m brazier/build [-- <source directory> | <app module .gleam file>]"

/// The generated server codec's file name in the source directory.
pub const codec_file = "brazier_codec.gleam"

/// `gleam run -m brazier/build`. Exits with status 1 on any failure.
pub fn main() -> Nil {
  log.configure()
  let outcome = {
    use target <- result.try(parse_args(program.args()))
    build(".", target)
  }
  case outcome {
    Ok(built) ->
      log.info(
        "brazier.build",
        "Build complete: "
          <> built.app.path
          <> " -> "
          <> built.codec_path
          <> ", "
          <> built.bundle.path,
      )
    Error(reason) -> {
      log.error("brazier.build", "Build failed: " <> reason)
      program.exit_failure(reason)
    }
  }
}

/// The build target named by the command-line arguments: none means the
/// project's `src` directory.
pub fn parse_args(args: List(String)) -> Result(Target, String) {
  case args {
    [] -> Ok(SourceDir("src"))
    [arg] ->
      case string.ends_with(arg, ".gleam") {
        True -> Ok(AppFile(arg))
        False -> Ok(SourceDir(arg))
      }
    _ ->
      Error(
        "Expected at most one argument, got "
        <> string.join(args, " ")
        <> ". "
        <> usage,
      )
  }
}

/// Build the app project at `project` (a directory relative to the current
/// one). Target paths are relative to `project`.
pub fn build(project: String, target: Target) -> Result(Built, String) {
  use brazier_root <- result.try(project_toml.brazier_root(project))
  use runtime_dir <- result.try(project_toml.client_runtime_dir(project))
  use config <- result.try(
    project_toml.read_project(files.join(project, "gleam.toml")),
  )
  use #(src_dir, app) <- result.try(find_app(project, target))
  log.info(
    "brazier.build",
    "Building " <> app.path <> " (" <> app.module_path <> ")",
  )
  use analysis <- result.try(analyze(src_dir, brazier_root, app))
  use Nil <- result.try(contract.write(project, app.path, analysis))
  use codec_path <- result.try(write_codec(project, src_dir, analysis))
  use Nil <- result.try(compile(project, config.name, codec_path))
  use bundle <- result.try(
    client_bundle.build(
      project,
      src_dir,
      brazier_root,
      runtime_dir,
      app,
      analysis,
    )
    |> result.try_recover(fn(reason) { remove_manifest(project, reason) }),
  )
  Ok(Built(app:, codec_path:, bundle:))
}

fn find_app(
  project: String,
  target: Target,
) -> Result(#(String, AppModule), String) {
  case target {
    SourceDir(path:) -> {
      let src_dir = files.join(project, path)
      use app <- result.map(discovery.find(src_dir))
      #(src_dir, app)
    }
    AppFile(path:) -> {
      let src_dir = files.join(project, "src")
      let path = files.join(project, path)
      use module_path <- result.try(discovery.module_path(src_dir, path))
      use source <- result.map(files.read(path))
      log.info("brazier.build", "Using app module " <> path)
      #(src_dir, discovery.AppModule(path:, module_path:, source:))
    }
  }
}

fn analyze(
  src_dir: String,
  brazier_root: String,
  app: AppModule,
) -> Result(Analysis, String) {
  use externals <- result.try(sources.app_externals(src_dir, app))
  use pruned <- result.try(sources.pruned_framework_sources(brazier_root))
  use analysis <- result.try(
    analyzer.analyze(
      app.module_path,
      list.flatten([[#(app.module_path, app.source)], externals, pruned]),
    )
    |> result.map_error(fn(reason) {
      "Analysis of " <> app.path <> " failed: " <> reason
    }),
  )
  log.info(
    "brazier.build",
    "Analyzed "
      <> app.module_path
      <> ": "
      <> string.inspect(list.length(analysis.client))
      <> " client modules, "
      <> string.inspect(set.size(analysis.codecs.allowed))
      <> " client-built constructors, "
      <> string.inspect(list.length(analysis.streams))
      <> " streams",
  )
  Ok(analysis)
}

/// Generate the codec and format it in `build/brazier_codegen` first, then
/// write it to the source directory only when it changed. An unchanged codec
/// keeps its modification time, so `gleam build` does not recompile it and a
/// dev-mode watcher on `src` does not see the build's own output as an edit.
fn write_codec(
  project: String,
  src_dir: String,
  analysis: Analysis,
) -> Result(String, String) {
  use codec <- result.try(server_codec.generate(analysis))
  let staged = files.join(project, "build/brazier_codegen/" <> codec_file)
  use Nil <- result.try(files.write(staged, codec))
  use staged_path <- result.try(program.absolute_path(staged))
  use _output <- result.try(program.run(".", "gleam", ["format", staged_path]))
  use formatted <- result.try(files.read(staged))
  let path = files.join(src_dir, codec_file)
  use written <- result.try(files.write_if_changed(path, formatted))
  case written {
    True -> log.info("brazier.build", "Wrote server codec " <> path)
    False ->
      log.info("brazier.build", "Server codec " <> path <> " is unchanged")
  }
  Ok(path)
}

/// Compile the project with the new codec. On failure the codec and its
/// compiled module are deleted, so no later start or reload can use a codec
/// from an earlier build.
fn compile(
  project: String,
  project_name: String,
  codec_path: String,
) -> Result(Nil, String) {
  // The app's own warnings never fail its build: `gleam_build` logged each.
  case program.gleam_build(project) {
    Ok(_warnings) -> Ok(Nil)
    Error(reason) -> {
      use Nil <- result.try(remove_codec(project, project_name, codec_path))
      Error(
        "The project does not compile with the generated codec. Deleted "
        <> codec_path
        <> " and its compiled module so no stale codec is used. Fix the error and rebuild:\n"
        <> reason,
      )
    }
  }
}

fn remove_codec(
  project: String,
  project_name: String,
  codec_path: String,
) -> Result(Nil, String) {
  let erlang_dir = files.join(project, "build/dev/erlang/" <> project_name)
  let artefacts = files.join(erlang_dir, "_gleam_artefacts")
  use has_artefacts <- result.try(files.is_directory(artefacts))
  use artefact_files <- result.try(case has_artefacts {
    True ->
      files.list_directory(artefacts)
      |> result.map(
        list.filter_map(_, fn(entry) {
          case string.starts_with(entry, "brazier_codec.") {
            True -> Ok(files.join(artefacts, entry))
            False -> Error(Nil)
          }
        }),
      )
    False -> Ok([])
  })
  let paths = [
    codec_path,
    files.join(erlang_dir, "ebin/brazier_codec.beam"),
    ..artefact_files
  ]
  use Nil <- result.try(list.try_each(paths, files.delete_if_exists))
  log.warning(
    "brazier.build",
    "Removed the generated codec: " <> string.join(paths, ", "),
  )
  Ok(Nil)
}

/// After a failed client bundle, delete the manifest so the server cannot
/// start with a bundle from an earlier build next to the new codec.
fn remove_manifest(project: String, reason: String) -> Result(a, String) {
  let manifest =
    files.join(
      project,
      client_bundle.static_dir <> "/" <> client_bundle.manifest_file,
    )
  case files.delete_if_exists(manifest) {
    Ok(Nil) -> {
      log.warning(
        "brazier.build",
        "Deleted " <> manifest <> " after a failed client bundle",
      )
      Error("Client bundle failed: " <> reason)
    }
    Error(delete_failure) ->
      Error(
        "Client bundle failed: "
        <> reason
        <> "\nThe old manifest could not be deleted either: "
        <> delete_failure,
      )
  }
}
