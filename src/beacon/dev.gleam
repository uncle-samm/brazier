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
/// 3. Watches `src` for `.gleam` changes with `fswatch` (macOS) or
///    `inotifywait` (Linux, from inotify-tools). Each change reruns the
///    build; on success the changed modules are hot-reloaded into the running
///    app and every connected browser is told to reload its page (the
///    `reload` server message). A failed rebuild is logged and the app keeps
///    running the last good build until the next change.
///
/// Dev mode checks for the watcher before it builds, and exits with status 1
/// naming the program to install when it is missing: there is no polling
/// mode that would rebuild late or not at all.
///
/// Reference: Phoenix's `Phoenix.LiveReloader` and `Phoenix.CodeReloader`.
/// A file watcher triggers the rebuild, the server broadcasts on a PubSub
/// topic every page's socket listens to, and the page reloads itself.
///
/// Production never builds: `beacon.start` requires the artifacts of
/// `gleam run -m beacon/build`.
import beacon/build
import beacon/build/discovery.{type AppModule}
import beacon/build/program
import beacon/build/project_toml
import beacon/internal/dev_watch
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
  case dev_watch.check() {
    Error(reason) -> Error(reason)
    Ok(program) -> {
      log.info("beacon.dev", "File watcher: " <> program)
      case project_toml.read_project("gleam.toml") {
        Error(reason) -> Error(reason)
        Ok(project) ->
          case rebuild(project.name) {
            Error(reason) -> Error("Initial build failed: " <> reason)
            Ok(app) -> {
              // Before the app starts, so every WebSocket it accepts listens
              // for the reload of the next rebuild.
              enable_live_reload()
              log.info(
                "beacon.dev",
                "Live reload on: each WebSocket subscribes to "
                  <> live_reload_topic(),
              )
              log.info("beacon.dev", "Starting " <> app.module_path <> ".main")
              start_app(erlang_module(app.module_path))
            }
          }
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
  log.info("beacon.dev", "Watching " <> string.join(watch_dirs, ", "))
  case start_native_watcher(watch_dirs) {
    Ok(Nil) -> native_watch_loop()
    Error(reason) -> {
      log.error("beacon.dev", "Cannot start the file watcher: " <> reason)
      program.exit_failure(reason)
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
            Ok(connections) ->
              log.info(
                "beacon.dev",
                "Rebuild complete; told "
                  <> int.to_string(connections)
                  <> " connected page(s) to reload",
              )
            // The app runs the new build either way. The pages open now are
            // not reloaded; one whose client bundle changed reloads when its
            // next join is refused with 4409 (stale build).
            Error(reason) ->
              log.error(
                "beacon.dev",
                "Rebuild complete, but telling the pages to reload failed: "
                  <> reason,
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

@external(erlang, "beacon_dev_ffi", "enable_live_reload")
fn enable_live_reload() -> Nil

@external(erlang, "beacon_dev_ffi", "live_reload_topic")
fn live_reload_topic() -> String

@external(erlang, "beacon_dev_ffi", "start_native_watcher")
fn start_native_watcher(dirs: List(String)) -> Result(Nil, String)

@external(erlang, "beacon_dev_ffi", "poll_native_watcher")
fn poll_native_watcher() -> Bool

/// Tell every WebSocket connection on this node to reload its page. Returns
/// how many were subscribed.
@external(erlang, "beacon_dev_ffi", "notify_browser_reload")
fn notify_browser_reload() -> Result(Int, String)
