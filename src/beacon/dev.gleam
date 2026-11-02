/// Development mode: build, run the app, rebuild and hot-reload on change.
///
/// Usage, from the app project's root:
///
/// ```sh
/// gleam run -m beacon/dev
/// ```
///
/// Dev mode is the only place Beacon builds automatically. It:
///
/// 1. Runs the Beacon build (`beacon/build`): server codec, `gleam build`
///    and client bundle. If this first build fails, dev mode exits with
///    status 1.
/// 2. Loads the freshly compiled modules and starts the app by calling the
///    app module's `main` (the module the build found, see
///    `beacon/build/discovery`).
/// 3. Watches `src` for `.gleam` changes. Each change reruns the build; on
///    success the changed modules are hot-reloaded into the running app. A
///    failed rebuild is logged and the app keeps running the last good build
///    until the next change.
///
/// Production never builds: `beacon.start` requires the artifacts of
/// `gleam run -m beacon/build`.
import beacon/build
import beacon/build/discovery.{type AppModule}
import beacon/build/program
import beacon/build/project_toml
import beacon/log
import gleam/int
import gleam/list
import gleam/string

const watch_dirs = ["src"]

pub fn main() -> Nil {
  log.configure()
  log.info("beacon.dev", "Starting dev mode")
  case start() {
    Ok(Nil) -> watch()
    Error(reason) -> {
      log.error("beacon.dev", "Dev mode failed to start: " <> reason)
      program.exit_failure(reason)
    }
  }
}

fn start() -> Result(Nil, String) {
  case project_toml.read_project("gleam.toml") {
    Error(reason) -> Error(reason)
    Ok(project) ->
      case rebuild(project.name) {
        Error(reason) -> Error("Initial build failed: " <> reason)
        Ok(app) -> {
          log.info("beacon.dev", "Starting " <> app.module_path <> ".main")
          start_app(erlang_module(app.module_path))
        }
      }
  }
}

/// Build, then load every changed module of the project.
fn rebuild(project_name: String) -> Result(AppModule, String) {
  case build.build(".", build.SourceDir("src")) {
    Error(reason) -> Error(reason)
    Ok(built) ->
      case reload_modules(ebin_dir(project_name)) {
        Error(reason) -> Error("Hot reload failed: " <> reason)
        Ok(reloaded) -> {
          log.info(
            "beacon.dev",
            "Loaded "
              <> int.to_string(list.length(reloaded))
              <> " changed module(s): "
              <> string.join(reloaded, ", "),
          )
          Ok(built.app)
        }
      }
  }
}

fn watch() -> Nil {
  case native_watcher_available() {
    True -> {
      log.info(
        "beacon.dev",
        "Watching "
          <> string.join(watch_dirs, ", ")
          <> " with fswatch/inotifywait",
      )
      case start_native_watcher(watch_dirs) {
        Ok(Nil) -> native_watch_loop()
        Error(reason) -> {
          log.error("beacon.dev", "Cannot start the file watcher: " <> reason)
          program.exit_failure(reason)
        }
      }
    }
    False -> {
      log.info(
        "beacon.dev",
        "Watching "
          <> string.join(watch_dirs, ", ")
          <> " by polling every 500ms (install fswatch or inotify-tools for instant rebuilds)",
      )
      record_file_timestamps(watch_dirs)
      poll_watch_loop()
    }
  }
}

fn native_watch_loop() -> Nil {
  case poll_native_watcher() {
    False -> Nil
    True -> {
      on_change()
      case start_native_watcher(watch_dirs) {
        Ok(Nil) -> Nil
        Error(reason) -> {
          log.error("beacon.dev", "Cannot restart the file watcher: " <> reason)
          program.exit_failure(reason)
        }
      }
    }
  }
  native_watch_loop()
}

fn poll_watch_loop() -> Nil {
  sleep(500)
  case check_for_changes(watch_dirs) {
    True -> on_change()
    False -> Nil
  }
  poll_watch_loop()
}

fn on_change() -> Nil {
  log.info("beacon.dev", "Change detected, rebuilding")
  case project_toml.read_project("gleam.toml") {
    Error(reason) -> log.error("beacon.dev", "Rebuild failed: " <> reason)
    Ok(project) ->
      case rebuild(project.name) {
        Error(reason) ->
          log.error(
            "beacon.dev",
            "Rebuild failed; the app keeps running the last good build: "
              <> reason,
          )
        Ok(_app) ->
          case notify_browser_reload() {
            Ok(Nil) -> log.info("beacon.dev", "Rebuild complete")
            Error(reason) ->
              log.warning(
                "beacon.dev",
                "Rebuild complete, but notifying browsers failed: " <> reason,
              )
          }
      }
  }
}

fn ebin_dir(project_name: String) -> String {
  "build/dev/erlang/" <> project_name <> "/ebin"
}

/// The Erlang module a Gleam module compiles to: `app/main` is `app@main`.
fn erlang_module(module_path: String) -> String {
  string.replace(module_path, "/", "@")
}

// === FFI ===

/// Load every module in `ebin` whose compiled code differs from the loaded
/// version. Returns the reloaded module names.
@external(erlang, "beacon_dev_ffi", "reload_modules")
fn reload_modules(ebin: String) -> Result(List(String), String)

/// Call `module:main()` (an Erlang module name) in a new process linked to
/// this one.
@external(erlang, "beacon_dev_ffi", "start_app")
fn start_app(module: String) -> Result(Nil, String)

@external(erlang, "beacon_dev_ffi", "sleep")
fn sleep(ms: Int) -> Nil

@external(erlang, "beacon_dev_ffi", "check_for_changes")
fn check_for_changes(dirs: List(String)) -> Bool

@external(erlang, "beacon_dev_ffi", "record_file_timestamps")
fn record_file_timestamps(dirs: List(String)) -> Nil

@external(erlang, "beacon_dev_ffi", "native_watcher_available")
fn native_watcher_available() -> Bool

@external(erlang, "beacon_dev_ffi", "start_native_watcher")
fn start_native_watcher(dirs: List(String)) -> Result(Nil, String)

@external(erlang, "beacon_dev_ffi", "poll_native_watcher")
fn poll_native_watcher() -> Bool

@external(erlang, "beacon_dev_ffi", "notify_browser_reload")
fn notify_browser_reload() -> Result(Nil, String)
