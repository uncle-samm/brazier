/// Development mode: build, run the app, rebuild and hot-reload on change.
///
/// Usage, from the app project's root:
///
/// ```sh
/// gleam run -m brazier/dev
/// ```
///
/// Dev mode is the only place Brazier builds automatically. It:
///
/// 1. Runs the Brazier build (`brazier/build`): server codec, `gleam build`
///    and client bundle. If this first build fails, dev mode exits with
///    status 1.
/// 2. Loads the freshly compiled modules and starts the app by calling the
///    app module's `main` (the module the build found, see
///    `brazier/build/discovery`).
/// 3. Watches `src` for `.gleam` changes with `fswatch` (macOS) or
///    `inotifywait` (Linux, from inotify-tools). Each change reruns the
///    build; on success the changed modules are hot-reloaded into the running
///    app, the rebuilt client bundle is loaded, and every connected browser
///    is told to reload its page (the `reload` server message). A page that
///    was between sockets then is told on its next join: each page carries
///    the dev build it was rendered under, and a rebuild starts a new one
///    (`ssr.new_dev_build`). A failed rebuild is logged and the app keeps
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
/// Production never builds: `brazier.start` requires the artifacts of
/// `gleam run -m brazier/build`.
import brazier/build
import brazier/build/discovery.{type AppModule}
import brazier/build/program
import brazier/build/project_toml
import brazier/internal/dev_watch
import brazier/log
import brazier/ssr
import gleam/int
import gleam/list
import gleam/string

const watch_dirs = ["src"]

pub fn main() -> Nil {
  log.configure()
  log.info("brazier.dev", "Starting dev mode")
  case start() {
    Ok(Nil) -> watch()
    Error(reason) -> {
      log.error("brazier.dev", "Dev mode failed to start: " <> reason)
      program.exit_failure(reason)
    }
  }
}

fn start() -> Result(Nil, String) {
  case dev_watch.check() {
    Error(reason) -> Error(reason)
    Ok(program) -> {
      log.info("brazier.dev", "File watcher: " <> program)
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
                "brazier.dev",
                "Live reload on: each WebSocket subscribes to "
                  <> live_reload_topic(),
              )
              // Every page the app renders carries the dev build, and a join
              // from a page of an older one is told to reload.
              let dev_build = ssr.new_dev_build()
              log.info(
                "brazier.dev",
                "Starting "
                  <> app.module_path
                  <> ".main under dev build "
                  <> dev_build,
              )
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
            "brazier.dev",
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
  log.info("brazier.dev", "Watching " <> string.join(watch_dirs, ", "))
  case start_native_watcher(watch_dirs) {
    Ok(Nil) -> native_watch_loop()
    Error(reason) -> {
      log.error("brazier.dev", "Cannot start the file watcher: " <> reason)
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
          log.error(
            "brazier.dev",
            "Cannot restart the file watcher: " <> reason,
          )
          program.exit_failure(reason)
        }
      }
    }
  }
  native_watch_loop()
}

fn on_change() -> Nil {
  log.info("brazier.dev", "Change detected, rebuilding")
  case project_toml.read_project("gleam.toml") {
    Error(reason) -> log.error("brazier.dev", "Rebuild failed: " <> reason)
    Ok(project) ->
      case rebuild(project.name) {
        Error(reason) ->
          log.error(
            "brazier.dev",
            "Rebuild failed; the app keeps running the last good build: "
              <> reason,
          )
        Ok(_app) -> publish_rebuild()
      }
  }
}

/// After a successful rebuild: load the rebuilt client bundle, start a new
/// dev build, then tell every open page to reload. In that order, a page
/// that is between sockets when the reload is broadcast joins after the
/// new dev build, and is told to reload then (`ssr.new_dev_build`).
fn publish_rebuild() -> Nil {
  case ssr.load_client_bundle() {
    // The pages are not told to reload: they would reload into a 500. A
    // join from one closes 1011 and reconnects, and the next good rebuild
    // reloads it.
    Error(reason) ->
      log.error(
        "brazier.dev",
        "Rebuild complete, but its client bundle cannot be loaded; pages "
          <> "answer 500 until the next good rebuild: "
          <> reason,
      )
    Ok(bundle) -> {
      let dev_build = ssr.new_dev_build()
      case notify_browser_reload() {
        Ok(connections) ->
          log.info(
            "brazier.dev",
            "Rebuild complete ("
              <> bundle
              <> ", dev build "
              <> dev_build
              <> "); told "
              <> int.to_string(connections)
              <> " connected page(s) to reload",
          )
        // The app runs the new build either way. A page open now is not
        // reloaded until its next join, which the new dev build refuses
        // with a `reload`.
        Error(reason) ->
          log.error(
            "brazier.dev",
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
@external(erlang, "brazier_dev_ffi", "reload_modules")
fn reload_modules(ebin: String) -> Result(List(String), String)

/// Call `module:main()` (an Erlang module name) in a new process linked to
/// this one.
@external(erlang, "brazier_dev_ffi", "start_app")
fn start_app(module: String) -> Result(Nil, String)

@external(erlang, "brazier_dev_ffi", "enable_live_reload")
fn enable_live_reload() -> Nil

@external(erlang, "brazier_dev_ffi", "live_reload_topic")
fn live_reload_topic() -> String

@external(erlang, "brazier_dev_ffi", "start_native_watcher")
fn start_native_watcher(dirs: List(String)) -> Result(Nil, String)

@external(erlang, "brazier_dev_ffi", "poll_native_watcher")
fn poll_native_watcher() -> Bool

/// Tell every WebSocket connection on this node to reload its page. Returns
/// how many were subscribed.
@external(erlang, "brazier_dev_ffi", "notify_browser_reload")
fn notify_browser_reload() -> Result(Int, String)
