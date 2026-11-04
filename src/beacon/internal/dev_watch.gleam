//// The file watcher `beacon/dev` needs: `fswatch` on macOS, `inotifywait`
//// (from inotify-tools) on Linux. Dev mode checks for it before it builds
//// and exits when it is missing; it has no polling mode.

/// Check that this OS's watcher is installed. Returns the program, or the
/// error dev mode exits with, which names what to install.
pub fn check() -> Result(String, String) {
  check_with(requirement(), find_executable)
}

/// `check` with its inputs given: `requirement` is the watcher program and
/// the package that provides it, or why the OS has none; `find` looks a
/// program up on the `PATH`.
pub fn check_with(
  requirement: Result(#(String, String), String),
  find: fn(String) -> Result(String, Nil),
) -> Result(String, String) {
  case requirement {
    Error(reason) -> Error(reason)
    Ok(#(program, package)) ->
      case find(program) {
        Ok(_path) -> Ok(program)
        Error(Nil) ->
          Error(
            "Dev mode watches src with "
            <> program
            <> ", which is not installed or not on the PATH. Install "
            <> package
            <> ", or build with `gleam run -m beacon/build` and start the app yourself.",
          )
      }
  }
}

/// This OS's watcher program and the package that provides it, or why the
/// OS has none.
@external(erlang, "beacon_dev_ffi", "watcher_requirement")
pub fn requirement() -> Result(#(String, String), String)

/// The path of `program` on the `PATH`.
@external(erlang, "beacon_dev_ffi", "find_executable")
pub fn find_executable(program: String) -> Result(String, Nil)
