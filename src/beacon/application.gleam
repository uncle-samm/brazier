/// Beacon application: starts the HTTP/WebSocket listener with a runtime per
/// connection and per-request server rendering, optionally under an OTP
/// supervisor.
///
/// `beacon.start` builds an `AppConfig` from the app and the generated codec;
/// tests build it directly with hand-written codecs.
///
/// Reference: Phoenix application structure, Erlang/OTP supervisor pattern.
import beacon/config as beacon_config
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/error
import beacon/internal/context.{type Context}
import beacon/log
import beacon/middleware
import beacon/notification.{type Notification}
import beacon/pubsub
import beacon/runtime
import beacon/ssr
import beacon/state_manager
import beacon/static
import beacon/transport
import beacon/transport/server.{type Connection, type ResponseBody}
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import gleam/uri.{type Uri}

/// Everything needed to serve an app, over the app's server `state`.
pub type AppConfig(state, msg) {
  AppConfig(
    /// Port to listen on (0 picks a free port).
    port: Int,
    /// Build the state for a request (dead render) or a connection.
    init: fn(Context) -> #(state, Effect(msg)),
    /// The server update.
    update: fn(state, msg) -> #(state, Effect(msg)),
    /// Render the state (the app's `view` over `sync` and the initial
    /// Local), for the dead render.
    view: fn(state) -> Element(msg),
    /// The page title for the dead render.
    title: fn(state) -> String,
    /// Encode the client-visible model of a state (`model_sync`, patches).
    encode_model: fn(state) -> String,
    /// Decode a client event into a message (the generated
    /// `beacon_codec.decode_event`).
    decode_event: fn(String, String, String, String) ->
      Result(msg, error.BeaconError),
    /// Rebuild a state from client-visible model JSON (state recovery).
    /// When set, the dead render embeds the model in the signed join token.
    restore_model: Option(fn(String) -> Result(state, String)),
    /// The app's `parse` composed with `on_change`, when it has a router.
    route: Option(fn(Uri) -> Result(msg, Nil)),
    /// Secret key for join tokens: at least 32 bytes
    /// (`config.min_secret_key_bytes`), or start fails with a ConfigError.
    secret_key: String,
    /// Middleware pipeline (applied to all HTTP requests).
    middlewares: List(middleware.Middleware),
    /// Static file serving directory (e.g., "priv/static").
    static_dir: Option(String),
    /// Dynamic subscription function: state → list of topics.
    dynamic_subscriptions: Option(fn(state) -> List(String)),
    /// Topic-aware notification handler for dynamic subscriptions.
    on_notify: Option(fn(String) -> msg),
    /// Typed notification handler for dynamic subscriptions.
    on_notification: Option(fn(Notification) -> msg),
    /// Configurable security limits for the transport layer.
    security_limits: transport.SecurityLimits,
    /// Extra HTML for `<head>` (stylesheets, meta tags, etc.).
    head_html: Option(String),
    /// API route handler — runs BEFORE SSR/static file routing. Some(response)
    /// is sent immediately; None falls through to SSR/static serving.
    api_handler: Option(
      fn(Request(Connection)) -> Option(response.Response(ResponseBody)),
    ),
    /// WebSocket authentication: runs before the upgrade; Error(reason)
    /// rejects with 401.
    ws_auth: Option(fn(Request(Connection)) -> Result(Nil, String)),
    /// Enable framework-owned client tracing.
    dev_mode: Bool,
  )
}

/// A running Beacon application.
pub type App {
  App(
    /// The supervisor PID.
    supervisor_pid: process.Pid,
    /// The TCP port the application is listening on. When the configured
    /// port is 0 this is the OS-assigned port.
    port: Int,
  )
}

/// Start a Beacon application: every page request is rendered with
/// `init(ctx)` (and the route), and every WebSocket connection gets its own
/// runtime process. Refuses a weak secret key.
pub fn start(config: AppConfig(state, msg)) -> Result(App, error.BeaconError) {
  log.configure()
  // A weak secret makes every signed join token forgeable: refuse to start.
  case beacon_config.validate_secret_key(config.secret_key) {
    Error(err) -> Error(err)
    Ok(_) -> start_with_valid_secret(config)
  }
}

fn start_with_valid_secret(
  config: AppConfig(state, msg),
) -> Result(App, error.BeaconError) {
  pubsub.start()
  log.info(
    "beacon.application",
    "Starting Beacon application on port "
      <> int.to_string(config.port)
      <> " (router: "
      <> case config.route {
      Some(_) -> "yes"
      None -> "no"
    }
      <> ", state recovery: "
      <> case config.restore_model {
      Some(_) -> "yes"
      None -> "no"
    }
      <> ")",
  )

  let ssr_config =
    ssr.SsrConfig(
      init: config.init,
      update: config.update,
      route: config.route,
      view: config.view,
      title: config.title,
      secret_key: config.secret_key,
      head_html: config.head_html,
      dev_mode: config.dev_mode,
      recovery_encoder: case config.restore_model {
        Some(_) -> Some(config.encode_model)
        None -> None
      },
    )
  // Every page is rendered for its request: init reads the request's URL,
  // cookies and session through the Context.
  let ssr_factory = fn(req: Request(Connection), _path: String) {
    ssr.render_page(ssr_config, req)
  }

  let runtime_config =
    runtime.RuntimeConfig(
      init: config.init,
      update: config.update,
      encode_model: config.encode_model,
      decode_event: config.decode_event,
      restore_model: config.restore_model,
      route: config.route,
      dynamic_subscriptions: config.dynamic_subscriptions,
      on_notify: config.on_notify,
      on_notification: config.on_notification,
      secret_key: config.secret_key,
    )

  let base_transport_config =
    runtime.connect_transport_per_connection(runtime_config, config.port, None)
  let static_cfg = case config.static_dir {
    Some(dir) ->
      Some(static.StaticConfig(directory: dir, prefix: "/static", max_age: 3600))
    None -> None
  }
  let transport_config =
    transport.TransportConfig(
      ..base_transport_config,
      middlewares: config.middlewares,
      static_config: static_cfg,
      security_limits: config.security_limits,
      ssr_factory: Some(ssr_factory),
      api_handler: config.api_handler,
      ws_auth: config.ws_auth,
    )
  case transport.start_listener(transport_config) {
    Ok(listener) -> {
      let port = server.get_port(listener)
      log.info(
        "beacon.application",
        "Beacon application started (per-connection mode) on port "
          <> int.to_string(port),
      )
      Ok(App(supervisor_pid: server.get_supervisor(listener), port: port))
    }
    Error(err) -> {
      log.error(
        "beacon.application",
        "Failed to start transport: " <> error.to_string(err),
      )
      Error(err)
    }
  }
}

/// Start a Beacon application with a full OTP supervision tree.
/// Uses `static_supervisor` to supervise the state manager.
///
/// This is the production-ready entry point.
pub fn start_supervised(
  config: AppConfig(state, msg),
) -> Result(App, error.BeaconError) {
  start_supervised_with(config, start)
}

fn start_supervised_with(
  config: AppConfig(model, msg),
  start_fn: fn(AppConfig(model, msg)) -> Result(App, error.BeaconError),
) -> Result(App, error.BeaconError) {
  log.configure()
  // Refuse a weak secret before any process is started, so a failed start
  // leaves nothing running.
  case beacon_config.validate_secret_key(config.secret_key) {
    Error(err) -> Error(err)
    Ok(_) -> start_supervised_with_valid_secret(config, start_fn)
  }
}

fn start_supervised_with_valid_secret(
  config: AppConfig(model, msg),
  start_fn: fn(AppConfig(model, msg)) -> Result(App, error.BeaconError),
) -> Result(App, error.BeaconError) {
  log.info(
    "beacon.application",
    "Starting supervised Beacon application on port "
      <> int.to_string(config.port),
  )

  // Start state manager under supervision. The supervisor must be given
  // the state manager's own pid (not the supervisor's) so it can monitor
  // and restart it.
  let state_mgr_spec =
    supervision.worker(fn() {
      case state_manager.start_in_memory() {
        Ok(subject) ->
          case process.subject_owner(subject) {
            Ok(pid) -> Ok(actor.Started(pid: pid, data: subject))
            Error(Nil) -> {
              log.error(
                "beacon.application",
                "State manager subject has no owner process",
              )
              Error(actor.InitFailed("state manager subject has no owner"))
            }
          }
        Error(err) -> Error(err)
      }
    })

  // Build supervisor
  let sup_result =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(state_mgr_spec)
    |> supervisor.start

  case sup_result {
    Ok(sup_started) -> {
      log.info("beacon.application", "Supervisor started")
      case start_fn(config) {
        Ok(app) -> {
          log.info("beacon.application", "Application fully started")
          Ok(App(supervisor_pid: sup_started.pid, port: app.port))
        }
        Error(err) -> Error(err)
      }
    }
    Error(err) -> {
      log.error(
        "beacon.application",
        "Failed to start supervisor: " <> string.inspect(err),
      )
      Error(error.ConfigError(
        reason: "Supervisor start failed: " <> string.inspect(err),
      ))
    }
  }
}

/// Keep the main process alive so the application keeps running.
/// Call this after `start()` in your main function.
///
/// The calling process traps exits so a shutdown signal can drain
/// connections. Because of that, the exit of any linked process (for
/// example the listener supervisor giving up after repeated crashes) is
/// received here and re-raised: the application never keeps running with
/// a dead listener.
///
/// `BEACON_SHUTDOWN_TIMEOUT` (milliseconds, default 5000) is validated
/// before waiting; a value that is not a non-negative integer stops the
/// process with an error instead of being ignored.
pub fn wait_forever() -> Nil {
  let timeout = case shutdown_timeout() {
    Ok(ms) -> ms
    Error(reason) -> {
      log.error("beacon.application", reason)
      fail_loudly(reason)
    }
  }
  log.info("beacon.application", "Application running. Press Ctrl+C to stop.")
  // Trap exit signals for graceful shutdown
  trap_exit()
  wait_for_shutdown(timeout)
}

/// What `receive_shutdown_signal` observed.
type ShutdownSignal {
  /// Nothing arrived before the timeout.
  NoSignal
  /// A linked process asked this one to shut down.
  ShutdownRequested
  /// A linked process exited abnormally.
  LinkedProcessExited(reason: String)
}

/// Wait for shutdown signal, then drain connections.
fn wait_for_shutdown(timeout: Int) -> Nil {
  case receive_shutdown_signal(60_000) {
    ShutdownRequested -> {
      log.info(
        "beacon.application",
        "Shutdown signal received, draining connections...",
      )
      // Give in-flight requests time to complete
      log.info(
        "beacon.application",
        "Draining for " <> int.to_string(timeout) <> "ms...",
      )
      process.sleep(timeout)
      log.info("beacon.application", "Shutdown complete.")
    }
    LinkedProcessExited(reason) -> {
      let message = "Linked application process exited: " <> reason
      log.error("beacon.application", message)
      fail_loudly(message)
    }
    NoSignal -> wait_for_shutdown(timeout)
  }
}

/// Why an integer environment variable could not be read.
type EnvIntError {
  EnvNotSet
  EnvNotInteger(value: String)
}

/// Shutdown drain timeout in milliseconds from `BEACON_SHUTDOWN_TIMEOUT`,
/// 5000 when the variable is unset. A malformed or negative value is an
/// error.
fn shutdown_timeout() -> Result(Int, String) {
  case get_env_int("BEACON_SHUTDOWN_TIMEOUT") {
    Ok(ms) if ms >= 0 -> {
      log.debug(
        "beacon.application",
        "BEACON_SHUTDOWN_TIMEOUT=" <> int.to_string(ms) <> "ms",
      )
      Ok(ms)
    }
    Ok(ms) ->
      Error(
        "BEACON_SHUTDOWN_TIMEOUT must be a non-negative integer of milliseconds, got "
        <> int.to_string(ms),
      )
    Error(EnvNotSet) -> {
      log.debug(
        "beacon.application",
        "BEACON_SHUTDOWN_TIMEOUT not set, using the 5000ms default",
      )
      Ok(5000)
    }
    Error(EnvNotInteger(value)) ->
      Error(
        "BEACON_SHUTDOWN_TIMEOUT must be a non-negative integer of milliseconds, got \""
        <> value
        <> "\"",
      )
  }
}

@external(erlang, "beacon_application_ffi", "trap_exit")
fn trap_exit() -> Nil

@external(erlang, "beacon_application_ffi", "receive_shutdown_signal")
fn receive_shutdown_signal(timeout: Int) -> ShutdownSignal

@external(erlang, "beacon_application_ffi", "get_env_int")
fn get_env_int(name: String) -> Result(Int, EnvIntError)

/// Stop the calling process with an error (crash loudly).
@external(erlang, "beacon_application_ffi", "fail_loudly")
fn fail_loudly(reason: String) -> a
