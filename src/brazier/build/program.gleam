/// External programs the build runs: `gleam`, `npx esbuild`.
///
/// Programs run without a shell, so project paths and arguments cannot inject
/// commands. A non-zero exit status is an `Error` carrying the program's
/// combined output.
import brazier/log
import gleam/list
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

/// Run `gleam build` in `cwd`.
///
/// A warning does not fail the build, but it is never dropped: each one is
/// logged at warning level, naming the project. The generated client project
/// is the build's one JavaScript compile, so a warning only the JavaScript
/// target raises is seen here or nowhere.
pub fn gleam_build(cwd: String) -> Result(Nil, String) {
  case run(cwd, "gleam", ["build"]) {
    Ok(output) -> {
      list.each(warnings(output), fn(warning) {
        log.warning(
          "brazier.build.program",
          "`gleam build` in " <> cwd <> " warned: " <> warning,
        )
      })
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// The warnings in the output of `gleam build`, one entry each: the
/// `warning: ` headline, then the source location on the line after it when
/// the compiler gives one.
pub fn warnings(output: String) -> List(String) {
  collect_warnings(string.split(output, "\n"), [])
}

fn collect_warnings(lines: List(String), acc: List(String)) -> List(String) {
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
                    headline <> " at " <> location,
                    ..acc
                  ])
                _ -> collect_warnings(rest, [headline, ..acc])
              }
            [] -> collect_warnings(rest, [headline, ..acc])
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
