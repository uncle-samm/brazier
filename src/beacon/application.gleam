/// Beacon application: starts the HTTP/WebSocket listener with a runtime per
/// connection and per-request server rendering.
///
/// `start_supervised` (what `beacon.start` uses) runs everything under one
/// root supervisor with the `RestForOne` strategy, children in this order:
///
/// 1. PubSub (`pubsub.supervised`)
/// 2. the cluster manager, when configured (`cluster.supervised`)
/// 3. the session revocation scope (`session.registry_supervised`)
/// 4. the HTTP/WebSocket listener (`transport.supervised`)
///
/// A child that crashes is restarted together with every child after it:
/// a PubSub restart also restarts the cluster manager, the session scope
/// and the listener (closing every connection, whose runtimes were linked
/// to PubSub partitions anyway); a listener restart touches nothing before
/// it. Past the restart tolerance the supervisor gives up and exits, which
/// `wait_forever` turns into a crash of the main process.
///
/// `start` is the unsupervised form for embedding and tests: it makes sure
/// PubSub and the session scope run on the node (unlinked, shared) and
/// links only the listener to the caller.
///
/// `beacon.start` builds an `AppConfig` from the app and the generated codec;
/// tests build it directly with hand-written codecs.
///
/// Reference: Phoenix application structure (Phoenix.PubSub, the endpoint
/// and Presence as ordered children of the application supervisor), OTP
/// `rest_for_one` supervision.
import beacon/cluster
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
import beacon/session
import beacon/ssr
import beacon/static
import beacon/telemetry
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
import gleam/result
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
    /// PubSub configuration (partitions, pool size, limits).
    pubsub: pubsub.PubSubConfig,
    /// Cluster membership, when the node joins a cluster.
    cluster: Option(cluster.ClusterConfig),
  )
}

/// A running Beacon application.
pub type App {
  App(
    /// The root supervisor PID (`start_supervised`), or the listener's
    /// supervisor PID (`start`).
    supervisor_pid: process.Pid,
    /// The TCP port the application is listening on. When the configured
    /// port is 0 this is the OS-assigned port; a restarted listener binds
    /// the same port again.
    port: Int,
    /// The listener as it first started (its connection registry and
    /// remembered port outlive restarts of the listener child).
    listener: server.Listener,
  )
}

/// How long `stop` waits for the tree to shut down (each child has its own
/// shutdown timeout inside this bound).
const stop_timeout_ms = 30_000

/// Start a Beacon application without the root supervision tree: every
/// page request is rendered with `init(ctx)` (and the route), and every
/// WebSocket connection gets its own runtime process. Refuses a weak secret
/// key.
///
/// PubSub, the cluster manager (when configured) and the session
/// revocation scope are started unlinked if they are not running yet, and
/// stay running after `stop`: they are shared by every app on the node.
/// Only the listener is linked to the caller. Use `start_supervised` in
/// production.
pub fn start(config: AppConfig(state, msg)) -> Result(App, error.BeaconError) {
  log.configure()
  // A weak secret makes every signed join token forgeable: refuse to start.
  use _ <- result.try(beacon_config.validate_secret_key(config.secret_key))
  use Nil <- result.try(start_telemetry())
  use Nil <- result.try(
    pubsub.start_with(config.pubsub)
    |> result.map_error(fn(reason) {
      config_error("PubSub failed to start: " <> pubsub.describe(reason))
    }),
  )
  use Nil <- result.try(case config.cluster {
    None -> Ok(Nil)
    Some(cluster_config) ->
      cluster.start(cluster_config)
      |> result.map_error(fn(reason) {
        config_error(
          "Cluster manager failed to start: " <> cluster.describe(reason),
        )
      })
  })
  session.ensure_registry()
  log_starting(config, "unsupervised")
  case transport.start_listener(transport_config(config)) {
    Ok(listener) -> {
      let port = server.get_port(listener)
      log.info(
        "beacon.application",
        "Beacon application started (unsupervised) on port "
          <> int.to_string(port),
      )
      Ok(App(
        supervisor_pid: server.get_supervisor(listener),
        port: port,
        listener: listener,
      ))
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

/// Start a Beacon application under the root supervision tree (see the
/// module documentation for the children and their restart semantics).
/// The root supervisor is linked to the caller. This is the production
/// entry point; stop it with `stop`.
///
/// Refuses to start when PubSub, the cluster manager or the session scope
/// already run on this node outside a tree: the tree must own them, or a
/// crash of theirs would go unnoticed.
pub fn start_supervised(
  config: AppConfig(state, msg),
) -> Result(App, error.BeaconError) {
  log.configure()
  // Refuse a weak secret before any process is started, so a failed start
  // leaves nothing running.
  use _ <- result.try(beacon_config.validate_secret_key(config.secret_key))
  use Nil <- result.try(start_telemetry())
  use Nil <- result.try(refuse_running_infrastructure())
  use pubsub_child <- result.try(
    pubsub.supervised(config.pubsub)
    |> result.map_error(fn(reason) {
      config_error("Invalid PubSub configuration: " <> pubsub.describe(reason))
    }),
  )
  use cluster_child <- result.try(case config.cluster {
    None -> Ok(None)
    Some(cluster_config) ->
      cluster.supervised(cluster_config)
      |> result.map(Some)
      |> result.map_error(fn(reason) {
        config_error(
          "Invalid cluster configuration: " <> cluster.describe(reason),
        )
      })
  })
  use listener_child <- result.try(
    transport.supervised(transport_config(config)),
  )
  log_starting(config, "supervised")

  // The listener reports its port to this process on its first start only:
  // restarts must not leave messages in a mailbox nobody reads.
  let first_start = process.new_subject()
  let once = once_new()
  let listener_child =
    supervision.ChildSpecification(..listener_child, start: fn() {
      case listener_child.start() {
        Ok(started) -> {
          case once_take(once) {
            True -> process.send(first_start, started.data)
            False ->
              log.warning(
                "beacon.application",
                "Listener restarted on port "
                  <> int.to_string(server.get_port(started.data)),
              )
          }
          Ok(started)
        }
        Error(reason) -> Error(reason)
      }
    })

  let builder =
    supervisor.new(supervisor.RestForOne)
    |> supervisor.add(pubsub_child)
  let builder = case cluster_child {
    Some(child) -> supervisor.add(builder, child)
    None -> builder
  }
  let builder =
    builder
    |> supervisor.add(session.registry_supervised())
    |> supervisor.add(listener_child)

  case supervisor.start(builder) {
    Ok(started) ->
      // INVARIANT: supervisor.start returns only after every child started,
      // and the listener child sent its Listener before returning.
      case process.receive(first_start, 0) {
        Ok(listener) -> {
          let port = server.get_port(listener)
          log.info(
            "beacon.application",
            "Beacon application started (supervised) on port "
              <> int.to_string(port),
          )
          Ok(App(supervisor_pid: started.pid, port: port, listener: listener))
        }
        Error(Nil) -> {
          let reason = "the listener did not report its port after starting"
          log.error("beacon.application", reason)
          fail_loudly(reason)
        }
      }
    Error(err) -> {
      let reason = describe_start_error(err)
      log.error(
        "beacon.application",
        "Failed to start the supervision tree: " <> reason,
      )
      Error(config_error("Supervision tree failed to start: " <> reason))
    }
  }
}

/// Stop an application: shuts the tree down child by child in reverse
/// start order (listener first, PubSub last) and returns once every
/// process of the tree has exited. For an app from `start`, this stops the
/// listener only (the shared infrastructure keeps running).
///
/// Stopping is a normal exit, so a linked caller is not taken down.
pub fn stop(app: App) -> Result(Nil, error.BeaconError) {
  log.info(
    "beacon.application",
    "Stopping Beacon application on port " <> int.to_string(app.port),
  )
  case stop_supervisor(app.supervisor_pid, stop_timeout_ms) {
    Ok(Nil) -> {
      server.release(app.listener)
      log.info(
        "beacon.application",
        "Beacon application stopped (port " <> int.to_string(app.port) <> ")",
      )
      Ok(Nil)
    }
    Error(reason) -> {
      log.error(
        "beacon.application",
        "Failed to stop the application: " <> reason,
      )
      Error(config_error("Application stop failed: " <> reason))
    }
  }
}

fn start_telemetry() -> Result(Nil, error.BeaconError) {
  case telemetry.start() {
    Ok(Nil) -> Ok(Nil)
    Error(reason) ->
      Error(config_error(
        "Telemetry failed to start: " <> string.inspect(reason),
      ))
  }
}

/// The tree owns PubSub, the cluster manager and the session scope; one
/// already running was started by someone else and would not be watched.
fn refuse_running_infrastructure() -> Result(Nil, error.BeaconError) {
  let pubsub_running = result.is_ok(pubsub.running_config())
  let cluster_running = result.is_ok(cluster.members())
  case pubsub_running, cluster_running, session.registry_running() {
    True, _, _ ->
      Error(config_error(
        "PubSub is already running on this node outside a supervision tree",
      ))
    _, True, _ ->
      Error(config_error(
        "The cluster manager is already running on this node outside a supervision tree",
      ))
    _, _, True ->
      Error(config_error(
        "The session scope is already running on this node outside a supervision tree",
      ))
    False, False, False -> Ok(Nil)
  }
}

fn config_error(reason: String) -> error.BeaconError {
  log.error("beacon.application", reason)
  error.ConfigError(reason: reason)
}

fn describe_start_error(err: actor.StartError) -> String {
  case err {
    actor.InitTimeout -> "a child did not start in time"
    actor.InitFailed(reason) -> reason
    actor.InitExited(reason) -> "a child exited: " <> string.inspect(reason)
  }
}

fn log_starting(config: AppConfig(state, msg), mode: String) -> Nil {
  log.info(
    "beacon.application",
    "Starting Beacon application ("
      <> mode
      <> ") on port "
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
      <> ", cluster: "
      <> case config.cluster {
      Some(_) -> "yes"
      None -> "no"
    }
      <> ")",
  )
}

/// The transport configuration of an app: server rendering per request and
/// a runtime per WebSocket connection.
fn transport_config(
  config: AppConfig(state, msg),
) -> transport.TransportConfig {
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
  transport.TransportConfig(
    ..base_transport_config,
    middlewares: config.middlewares,
    static_config: static_cfg,
    security_limits: config.security_limits,
    ssr_factory: Some(ssr_factory),
    api_handler: config.api_handler,
    ws_auth: config.ws_auth,
  )
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

/// A one-shot flag: `once_take` returns True exactly once.
type Once

@external(erlang, "beacon_application_ffi", "once_new")
fn once_new() -> Once

@external(erlang, "beacon_application_ffi", "once_take")
fn once_take(once: Once) -> Bool

/// Stop a supervisor with reason `normal`, waiting up to `timeout` ms.
@external(erlang, "beacon_application_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid, timeout: Int) -> Result(Nil, String)
