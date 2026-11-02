/// The Beacon build: generates an app's server codec and client bundle.
///
/// Usage, from the app project's root:
///
/// ```sh
/// gleam run -m beacon/build                    # find the app module in src
/// gleam run -m beacon/build -- src/my_app.gleam  # use this app module
/// ```
///
/// The build:
///
/// 1. Finds the app module (see `beacon/build/discovery`) and the user
///    modules it uses (`beacon/build/sources`).
/// 2. Analyzes them (`beacon/build/analyzer`) and checks the app has a shape
///    the generated code supports (`beacon/build/shape`).
/// 3. Writes `build/beacon_contract.json` (`beacon/build/contract`).
/// 4. Generates `src/beacon_codec.gleam` (`beacon/build/server_codec`) and
///    compiles the project with `gleam build`.
/// 5. Builds the client bundle into `priv/static` and points
///    `priv/static/beacon_client.manifest` at it
///    (`beacon/build/client_bundle`).
///
/// Any failure stops the build and exits with status 1. A codec that does
/// not compile is deleted, and a failed client bundle deletes the manifest,
/// so `beacon.start` refuses to run with artifacts from an older build.
import beacon/build/analyzer.{type Analysis}
import beacon/build/client_bundle
import beacon/build/contract
import beacon/build/discovery.{type AppModule}
import beacon/build/files
import beacon/build/program
import beacon/build/project_toml
import beacon/build/server_codec
import beacon/build/shape
import beacon/build/sources
import beacon/log
import gleam/list
import gleam/result
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
  "Usage: gleam run -m beacon/build [-- <source directory> | <app module .gleam file>]"

/// The generated server codec's file name in the source directory.
pub const codec_file = "beacon_codec.gleam"

/// `gleam run -m beacon/build`. Exits with status 1 on any failure.
pub fn main() -> Nil {
  log.configure()
  let outcome = {
    use target <- result.try(parse_args(program.args()))
    build(".", target)
  }
  case outcome {
    Ok(built) ->
      log.info(
        "beacon.build",
        "Build complete: "
          <> built.app.path
          <> " -> "
          <> built.codec_path
          <> ", "
          <> built.bundle.path,
      )
    Error(reason) -> {
      log.error("beacon.build", "Build failed: " <> reason)
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
  use beacon_root <- result.try(project_toml.beacon_root(project))
  use config <- result.try(
    project_toml.read_project(files.join(project, "gleam.toml")),
  )
  use #(src_dir, app) <- result.try(find_app(project, target))
  log.info(
    "beacon.build",
    "Building " <> app.path <> " (" <> app.module_path <> ")",
  )
  use analysis <- result.try(analyze(src_dir, app))
  use client <- result.try(shape.check(analysis, app.source))
  use Nil <- result.try(contract.write(
    project,
    app.path,
    app.module_path,
    analysis,
  ))
  use codec_path <- result.try(write_codec(project, src_dir, app, analysis))
  use Nil <- result.try(compile(project, config.name, codec_path))
  use bundle <- result.try(
    client_bundle.build(project, src_dir, beacon_root, app, analysis, client)
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
      log.info("beacon.build", "Using app module " <> path)
      #(src_dir, discovery.AppModule(path:, module_path:, source:))
    }
  }
}

fn analyze(src_dir: String, app: AppModule) -> Result(Analysis, String) {
  use externals <- result.try(sources.app_externals(src_dir, app))
  use analysis <- result.try(
    analyzer.analyze_multi(app.source, externals)
    |> result.map_error(fn(reason) {
      "Analysis of " <> app.path <> " failed: " <> reason
    }),
  )
  list.each(analyzer.state_diagnostics(analysis), log.info("beacon.build", _))
  list.each(analyzer.client_contract_report(analysis), log.info(
    "beacon.build",
    _,
  ))
  log.info("beacon.build", analyzer.client_contract_summary(analysis))
  list.each(analysis.msg_variants, fn(variant) {
    log.info(
      "beacon.build",
      "  "
        <> variant.name
        <> " -> "
        <> analyzer.msg_impact_label(analyzer.msg_impact(variant)),
    )
  })
  Ok(analysis)
}

/// Generate the codec and format it in `build/beacon_codegen` first, then
/// write it to the source directory only when it changed. An unchanged codec
/// keeps its modification time, so `gleam build` does not recompile it and a
/// dev-mode watcher on `src` does not see the build's own output as an edit.
fn write_codec(
  project: String,
  src_dir: String,
  app: AppModule,
  analysis: Analysis,
) -> Result(String, String) {
  use codec <- result.try(server_codec.generate(analysis, app.module_path))
  let staged = files.join(project, "build/beacon_codegen/" <> codec_file)
  use Nil <- result.try(files.write(staged, codec))
  use _output <- result.try(
    program.run(".", "gleam", ["format", program.absolute_path(staged)]),
  )
  use formatted <- result.try(files.read(staged))
  let path = files.join(src_dir, codec_file)
  use written <- result.try(files.write_if_changed(path, formatted))
  case written {
    True -> log.info("beacon.build", "Wrote server codec " <> path)
    False ->
      log.info("beacon.build", "Server codec " <> path <> " is unchanged")
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
  case program.gleam_build(project) {
    Ok(Nil) -> Ok(Nil)
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
          case string.starts_with(entry, "beacon_codec.") {
            True -> Ok(files.join(artefacts, entry))
            False -> Error(Nil)
          }
        }),
      )
    False -> Ok([])
  })
  let paths = [
    codec_path,
    files.join(erlang_dir, "ebin/beacon_codec.beam"),
    ..artefact_files
  ]
  use Nil <- result.try(list.try_each(paths, files.delete_if_exists))
  log.warning(
    "beacon.build",
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
        "beacon.build",
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
