/// External programs the build runs: `gleam`, `npx esbuild`.
///
/// Programs run without a shell, so project paths and arguments cannot inject
/// commands. A non-zero exit status is an `Error` carrying the program's
/// combined output.
import brazier/log
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The esbuild release the client bundles are built with. Pinned so the same
/// sources always produce the same bundle bytes, and so the content-hashed
/// filename is stable.
pub const esbuild = "esbuild@0.25.12"

/// Run `program args` in `cwd` and return its output.
pub fn run(
  cwd: String,
  program: String,
  args: List(String),
) -> Result(String, String) {
  let command = string.join([program, ..args], " ")
  log.info("brazier.build.program", "Running `" <> command <> "` in " <> cwd)
  case run_program(cwd, program, args) {
    Ok(output) -> {
      log.debug("brazier.build.program", "`" <> command <> "` succeeded")
      Ok(output)
    }
    Error(output) -> {
      log.error(
        "brazier.build.program",
        "`" <> command <> "` failed in " <> cwd,
      )
      Error("`" <> command <> "` failed in " <> cwd <> ":\n" <> output)
    }
  }
}

/// One warning from `gleam build`.
pub type Warning {
  Warning(
    /// The text after `warning: `, e.g. `Unused private function`.
    headline: String,
    /// Where the compiler points, `/abs/path/src/app.gleam:3:1`, when it
    /// gives a location.
    location: Option(String),
  )
}

/// `headline at location`, or the headline alone.
pub fn describe_warning(warning: Warning) -> String {
  case warning.location {
    Some(location) -> warning.headline <> " at " <> location
    None -> warning.headline
  }
}

/// The file a warning points at: its location without the trailing
/// `:line:column`. `None` for a warning without a location.
pub fn warning_file(warning: Warning) -> Option(String) {
  use location <- option.map(warning.location)
  case list.reverse(string.split(location, ":")) {
    [column, line, ..file] ->
      case int.parse(column), int.parse(line), file {
        Ok(_), Ok(_), [_, ..] -> string.join(list.reverse(file), ":")
        _, _, _ -> location
      }
    _ -> location
  }
}

/// Run `gleam build` in `cwd` and return its warnings.
///
/// A warning does not fail this compile, but it is never dropped: each one is
/// logged at warning level, naming the project, and returned so the caller
/// can refuse the ones it must (see `client_bundle`). The generated client
/// project is the build's one JavaScript compile, so a warning only the
/// JavaScript target raises is seen there or nowhere.
pub fn gleam_build(cwd: String) -> Result(List(Warning), String) {
  case run(cwd, "gleam", ["build"]) {
    Ok(output) -> {
      let found = warnings(output)
      list.each(found, fn(warning) {
        log.warning(
          "brazier.build.program",
          "`gleam build` in " <> cwd <> " warned: " <> describe_warning(warning),
        )
      })
      Ok(found)
    }
    Error(reason) -> Error(reason)
  }
}

/// The warnings in the output of `gleam build`, one entry each: the
/// `warning: ` headline, and the source location on the line after it when
/// the compiler gives one.
pub fn warnings(output: String) -> List(Warning) {
  collect_warnings(string.split(output, "\n"), [])
}

fn collect_warnings(lines: List(String), acc: List(Warning)) -> List(Warning) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] ->
      case string.starts_with(line, "warning: ") {
        False -> collect_warnings(rest, acc)
        True -> {
          let headline = string.drop_start(line, string.length("warning: "))
          case rest {
            [next, ..after] ->
              case string.trim_start(next) {
                "┌─ " <> location ->
                  collect_warnings(after, [
                    Warning(headline:, location: Some(location)),
                    ..acc
                  ])
                _ ->
                  collect_warnings(rest, [
                    Warning(headline:, location: None),
                    ..acc
                  ])
              }
            [] ->
              collect_warnings(rest, [Warning(headline:, location: None), ..acc])
          }
        }
      }
  }
}

/// Bundle `entry` (relative to `cwd`) into one minified IIFE at `outfile`
/// (relative to `cwd`) with the pinned esbuild.
pub fn esbuild_bundle(
  cwd: String,
  entry: String,
  outfile: String,
) -> Result(Nil, String) {
  case
    run(cwd, "npx", [
      "--yes",
      esbuild,
      entry,
      "--bundle",
      "--format=iife",
      "--minify",
      "--log-level=warning",
      "--outfile=" <> outfile,
    ])
  {
    Ok(_output) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// An absolute path for `path`, resolved against the current directory. An
/// `Error` when the current directory cannot be read (it was deleted, or a
/// parent is no longer searchable): a build run from there cannot name its
/// files.
pub fn absolute_path(path: String) -> Result(String, String) {
  case do_absolute_path(path) {
    Ok(absolute) -> Ok(absolute)
    Error(reason) -> {
      log.error("brazier.build.program", reason)
      Error(reason)
    }
  }
}

/// The first 16 hex digits of the SHA-256 of `contents`.
@external(erlang, "brazier_build_ffi", "content_hash")
pub fn content_hash(contents: String) -> String

/// Print `reason` to stderr and halt the VM with exit status 1.
@external(erlang, "brazier_build_ffi", "exit_failure")
pub fn exit_failure(reason: String) -> Nil

/// Command-line arguments after `gleam run -m <module>`.
@external(erlang, "brazier_codegen_ffi", "get_args")
pub fn args() -> List(String)

@external(erlang, "brazier_build_ffi", "run_program")
fn run_program(
  cwd: String,
  program: String,
  args: List(String),
) -> Result(String, String)

@external(erlang, "brazier_build_ffi", "absolute_path")
fn do_absolute_path(path: String) -> Result(String, String)
