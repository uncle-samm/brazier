/// Brazier application: starts the HTTP/WebSocket listener with a runtime per
/// connection and per-request server rendering.
///
/// `start_supervised` (what `brazier.start` uses) runs everything under one
/// root supervisor with the `RestForOne` strategy, children in this order:
///
/// 1. the ETS table owner (`state_manager.table_owner_supervised`)
/// 2. PubSub (`pubsub.supervised`)
/// 3. the cluster manager, when configured (`cluster.supervised`)
/// 4. the session revocation scope (`session.registry_supervised`)
/// 5. the presence tracker, when configured (`presence.supervised`)
/// 6. the HTTP/WebSocket listener (`transport.supervised`)
///
/// The table owner holds the stores' data, so it comes first: no other
/// child's restart may delete its tables. It adopts the tables of stores
/// created before the tree (in `main`), and `stop` deletes them. An owner
/// that crashes owning tables is not restarted empty: the restart fails and
/// the tree gives up, because every store handle now names a lost table.
///
/// A child that crashes is restarted together with every child after it:
/// a PubSub restart also restarts the cluster manager, the session scope,
/// the presence tracker and the listener (closing every connection, whose
/// runtimes were linked to PubSub partitions anyway); a listener restart
/// touches nothing before it. A single presence shard that crashes is
/// restarted by the tracker's own supervisor, and every session tracks its
/// entries on it again. Past the restart tolerance the supervisor gives up and exits, which
/// `wait_forever` turns into a crash of the main process.
///
/// `start` is the unsupervised form for embedding and tests: it makes sure
/// PubSub, the session scope and the presence tracker run on the node
/// (unlinked, shared) and links only the listener to the caller.
///
/// `brazier.start` builds an `AppConfig` from the app and the generated codec;
/// tests build it directly with hand-written codecs.
///
/// Reference: Phoenix application structure (Phoenix.PubSub, the endpoint
/// and Presence as ordered children of the application supervisor), OTP
/// `rest_for_one` supervision.
import brazier/cluster
import brazier/config as brazier_config
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/error
import brazier/internal/context.{type Context}
import brazier/internal/presence_watch
import brazier/log
import brazier/middleware
import brazier/notification.{type Notification}
import brazier/presence
import brazier/pubsub
import brazier/runtime
import brazier/session
import brazier/ssr
import brazier/state_manager
import brazier/static
import brazier/telemetry
import brazier/transport
import brazier/transport/server.{type Connection, type ResponseBody}
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
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
    /// Build the state for a request (dead render) or a connection. An
    /// `Error` refuses it: an error page for its status on the dead render,
    /// a close with `error.init_close_code` on the WebSocket.
    init: fn(Context) -> Result(#(state, Effect(msg)), error.InitError),
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
    /// `brazier_codec.decode_event`).
    decode_event: fn(String, String, String, String) ->
      Result(msg, error.BrazierError),
    /// Rebuild a state from client-visible model JSON and the fresh state
    /// `init` built for the connection (state recovery). When set, the dead
    /// render embeds the model in the signed join token.
    restore_model: Option(fn(String, state) -> Result(state, String)),
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
    /// Presence: the tracker the tree runs, and what each session tracks
    /// and is told (`brazier.presence`).
    presence: Option(presence_watch.Watch(state, msg)),
  )
}

/// A running Brazier application.
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
    /// How long stopping the listener waits for its connections to finish
    /// (`drain_timeout_ms` of the security limits, or
    /// `BRAZIER_SHUTDOWN_TIMEOUT`).
    drain_timeout_ms: Int,
  )
}

/// How long `stop` waits for the tree to shut down beyond the listener's
/// drain timeout (each child has its own shutdown timeout inside this
/// bound).
const stop_margin_ms = 30_000

/// Start a Brazier application without the root supervision tree: every
/// page request is rendered with `init(ctx)` (and the route), and every
/// WebSocket connection gets its own runtime process. Refuses a weak secret
/// key.
///
/// PubSub, the cluster manager (when configured), the session revocation
/// scope and the presence tracker (when configured) are started unlinked
/// if they are not running yet, and stay running after `stop`: they are shared by every app on the node.
/// Only the listener is linked to the caller. Use `start_supervised` in
/// production.
pub fn start(config: AppConfig(state, msg)) -> Result(App, error.BrazierError) {
  log.configure()
  // A variable set under its pre-rename name would be ignored: refuse.
  use Nil <- result.try(brazier_config.refuse_renamed_env(
    brazier_config.framework_env_vars,
  ))
  // A weak secret makes every signed join token forgeable: refuse to start.
  use _ <- result.try(brazier_config.validate_secret_key(config.secret_key))
  use Nil <- result.try(start_telemetry())
  use config <- result.try(apply_shutdown_timeout(config))
  use Nil <- result.try(
    pubsub.start_with(config.pubsub)
    |> result.map_error(fn(reason) {
      config_error("PubSub failed to start: " <> pubsub.describe(reason))
    }),
  )
  use Nil <- result.try(case config.cluster {
    None -> Ok(Nil)
    Some(cluster_config) ->
      cluster.start(cluster_config, secret_key: config.secret_key)
      |> result.map_error(fn(reason) {
        config_error(
          "Cluster manager failed to start: " <> cluster.describe(reason),
        )
      })
  })
  session.ensure_registry()
  use Nil <- result.try(case config.presence {
    None -> Ok(Nil)
    Some(watch) ->
      presence_watch.ensure_started(watch)
      |> result.map_error(fn(reason) {
        config_error(
          "Presence tracker "
          <> presence_watch.name(watch)
          <> " failed to start: "
          <> presence.describe(reason),
        )
      })
  })
  log_starting(config, "unsupervised")
  case transport.start_listener(transport_config(config)) {
    Ok(listener) -> {
      let port = server.get_port(listener)
      log.info(
        "brazier.application",
        "Brazier application started (unsupervised) on port "
          <> int.to_string(port),
      )
      Ok(
        remember(App(
          supervisor_pid: server.get_supervisor(listener),
          port: port,
          listener: listener,
          drain_timeout_ms: config.security_limits.drain_timeout_ms,
        )),
      )
    }
    Error(err) -> {
      log.error(
        "brazier.application",
        "Failed to start transport: " <> error.to_string(err),
      )
      Error(err)
    }
  }
}

/// Start a Brazier application under the root supervision tree (see the
/// module documentation for the children and their restart semantics).
/// The root supervisor is linked to the caller. This is the production
/// entry point; stop it with `stop`.
///
/// Refuses to start when PubSub, the cluster manager, the session scope or
/// the presence tracker already run on this node outside a tree: the tree must own them, or a
/// crash of theirs would go unnoticed.
pub fn start_supervised(
  config: AppConfig(state, msg),
) -> Result(App, error.BrazierError) {
  log.configure()
  // Refuse a variable set under its pre-rename name, and a weak secret,
  // before any process is started, so a failed start leaves nothing running.
  use Nil <- result.try(brazier_config.refuse_renamed_env(
    brazier_config.framework_env_vars,
  ))
  use _ <- result.try(brazier_config.validate_secret_key(config.secret_key))
  use Nil <- result.try(start_telemetry())
  use config <- result.try(apply_shutdown_timeout(config))
  use Nil <- result.try(refuse_running_infrastructure(config))
  use pubsub_child <- result.try(
    pubsub.supervised(config.pubsub)
    |> result.map_error(fn(reason) {
      config_error("Invalid PubSub configuration: " <> pubsub.describe(reason))
    }),
  )
  use cluster_child <- result.try(case config.cluster {
    None -> Ok(None)
    Some(cluster_config) ->
      cluster.supervised(cluster_config, secret_key: config.secret_key)
      |> result.map(Some)
      |> result.map_error(fn(reason) {
        config_error(
          "Invalid cluster configuration: " <> cluster.describe(reason),
        )
      })
  })
  use presence_child <- result.try(case config.presence {
    None -> Ok(None)
    Some(watch) ->
      presence_watch.supervised(watch)
      |> result.map(Some)
      |> result.map_error(fn(reason) {
        config_error(
          "Invalid presence configuration: " <> presence.describe(reason),
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
                "brazier.application",
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
    |> supervisor.add(state_manager.table_owner_supervised())
    |> supervisor.add(pubsub_child)
  let builder = case cluster_child {
    Some(child) -> supervisor.add(builder, child)
    None -> builder
  }
  let builder =
    builder
    |> supervisor.add(session.registry_supervised())
  let builder = case presence_child {
    Some(child) -> supervisor.add(builder, child)
    None -> builder
  }
  let builder = supervisor.add(builder, listener_child)

  case supervisor.start(builder) {
    Ok(started) ->
      // INVARIANT: supervisor.start returns only after every child started,
      // and the listener child sent its Listener before returning.
      case process.receive(first_start, 0) {
        Ok(listener) -> {
          let port = server.get_port(listener)
          log.info(
            "brazier.application",
            "Brazier application started (supervised) on port "
              <> int.to_string(port),
          )
          Ok(
            remember(App(
              supervisor_pid: started.pid,
              port: port,
              listener: listener,
              drain_timeout_ms: config.security_limits.drain_timeout_ms,
            )),
          )
        }
        Error(Nil) -> {
          let reason = "the listener did not report its port after starting"
          log.error("brazier.application", reason)
          fail_loudly(reason)
        }
      }
    Error(err) -> {
      let reason = describe_start_error(err)
      log.error(
        "brazier.application",
        "Failed to start the supervision tree: " <> reason,
      )
      Error(config_error("Supervision tree failed to start: " <> reason))
    }
  }
}

/// Stop an application: shuts the tree down child by child in reverse
/// start order (listener first, the ETS table owner last) and returns once
/// every process of the tree has exited. The owner's tables go with it, so a
/// store from before the stop must not be used after it. For an app from
/// `start`, this stops the listener only (the shared infrastructure keeps
/// running).
///
/// The listener drains first: open connections get up to the app's drain
/// timeout to finish (see `transport.SecurityLimits.drain_timeout_ms`).
///
/// Stopping is a normal exit, so a linked caller is not taken down.
///
/// An app that is not running (stopped already, or its tree died) is an
/// error saying so, logged once as a warning; a stop that fails is an
/// error, logged once as an error.
pub fn stop(app: App) -> Result(Nil, error.BrazierError) {
  stop_app(app)
  |> result.map_error(fn(failure) { error.ConfigError(reason: failure.reason) })
}

/// Stop an application and log the outcome once: a stop that failed is an
/// error, an application that was not running a warning.
fn stop_app(app: App) -> Result(Nil, StopFailure) {
  log.info(
    "brazier.application",
    "Stopping Brazier application on port "
      <> int.to_string(app.port)
      <> " (drain timeout "
      <> int.to_string(app.drain_timeout_ms)
      <> "ms)",
  )
  case
    stop_supervisor(app.supervisor_pid, app.drain_timeout_ms + stop_margin_ms)
  {
    Ok(Nil) -> {
      forget_app(app.supervisor_pid)
      case server.release(app.listener) {
        True -> Nil
        False ->
          log.warning(
            "brazier.application",
            "The listener of the application on port "
              <> int.to_string(app.port)
              <> " had no remembered port",
          )
      }
      log.info(
        "brazier.application",
        "Brazier application stopped (port " <> int.to_string(app.port) <> ")",
      )
      Ok(Nil)
    }
    // Already stopped (a second `stop`), or the tree died on its own: an
    // unexpected call, not a failed shutdown, so it is one warning. A tree
    // that died without `stop` still held its port memory: it goes now.
    Error(NotRunning(reason)) -> {
      forget_app(app.supervisor_pid)
      let message =
        "The application on port "
        <> int.to_string(app.port)
        <> " was not stopped: "
        <> reason
        <> case server.release(app.listener) {
          True -> " (it exited without stop; its port is forgotten now)"
          False -> " (it was stopped already)"
        }
      log.warning("brazier.application", message)
      Error(NotRunning(message))
    }
    Error(StopFailed(reason)) -> {
      let message = "Application stop failed: " <> reason
      log.error("brazier.application", message)
      Error(StopFailed(message))
    }
  }
}

/// Why `stop_supervisor` did not stop a supervisor.
type StopFailure {
  /// It was not running.
  NotRunning(reason: String)
  /// It did not stop in time, or exited with another reason.
  StopFailed(reason: String)
}

/// Remember an app node-wide, for `wait_forever`.
fn remember(app: App) -> App {
  remember_app(app.supervisor_pid, app)
  app
}

/// `BRAZIER_SHUTDOWN_TIMEOUT` (milliseconds), when set, replaces the
/// configured `drain_timeout_ms`: operators tune the drain without a
/// rebuild. A value that is not an integer in range refuses the start.
fn apply_shutdown_timeout(
  config: AppConfig(state, msg),
) -> Result(AppConfig(state, msg), error.BrazierError) {
  let configured = config.security_limits.drain_timeout_ms
  use drain_ms <- result.try(case get_env_int("BRAZIER_SHUTDOWN_TIMEOUT") {
    Ok(ms) -> {
      log.info(
        "brazier.application",
        "BRAZIER_SHUTDOWN_TIMEOUT="
          <> int.to_string(ms)
          <> "ms replaces the configured drain_timeout_ms ("
          <> int.to_string(configured)
          <> "ms)",
      )
      transport.validate_drain_timeout(ms)
      |> result.map(fn(_) { ms })
      |> result.map_error(fn(reason) {
        config_error("BRAZIER_SHUTDOWN_TIMEOUT: " <> reason)
      })
    }
    Error(EnvNotSet) -> {
      log.debug(
        "brazier.application",
        "BRAZIER_SHUTDOWN_TIMEOUT not set, draining for the configured "
          <> int.to_string(configured)
          <> "ms",
      )
      transport.validate_drain_timeout(configured)
      |> result.map(fn(_) { configured })
      |> result.map_error(config_error)
    }
    Error(EnvNotInteger(value)) ->
      Error(config_error(
        "BRAZIER_SHUTDOWN_TIMEOUT must be an integer of milliseconds, got \""
        <> value
        <> "\"",
      ))
  })
  Ok(
    AppConfig(
      ..config,
      security_limits: transport.SecurityLimits(
        ..config.security_limits,
        drain_timeout_ms: drain_ms,
      ),
    ),
  )
}

fn start_telemetry() -> Result(Nil, error.BrazierError) {
  case telemetry.start() {
    Ok(Nil) -> Ok(Nil)
    Error(reason) ->
      Error(config_error(
        "Telemetry failed to start: " <> string.inspect(reason),
      ))
  }
}

/// The tree owns PubSub, the cluster manager, the session scope and the
/// presence tracker; one already running was started by someone else and
/// would not be watched.
fn refuse_running_infrastructure(
  config: AppConfig(state, msg),
) -> Result(Nil, error.BrazierError) {
  let pubsub_running = result.is_ok(pubsub.running_config())
  let cluster_running = result.is_ok(cluster.members())
  let presence_running = case config.presence {
    Some(watch) -> presence_watch.running(watch)
    None -> False
  }
  // The tracker needs PubSub, so it is checked first: a running tracker
  // means PubSub runs too, and the tracker is the more specific report.
  case
    presence_running,
    pubsub_running,
    cluster_running,
    session.registry_running()
  {
    True, _, _, _ ->
      Error(config_error(
        "The presence tracker is already running on this node outside a supervision tree",
      ))
    _, True, _, _ ->
      Error(config_error(
        "PubSub is already running on this node outside a supervision tree",
      ))
    _, _, True, _ ->
      Error(config_error(
        "The cluster manager is already running on this node outside a supervision tree",
      ))
    _, _, _, True ->
      Error(config_error(
        "The session scope is already running on this node outside a supervision tree",
      ))
    False, False, False, False -> Ok(Nil)
  }
}

fn config_error(reason: String) -> error.BrazierError {
  log.error("brazier.application", reason)
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
    "brazier.application",
    "Starting Brazier application ("
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
      <> ", presence: "
      <> case config.presence {
      Some(watch) -> presence_watch.name(watch)
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
      presence: config.presence,
      title: Some(config.title),
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
/// Returns when the application should stop:
///
/// - **SIGTERM** (`docker stop`, Kubernetes, systemd): every application
///   running on this node is stopped with `stop`, whichever process started
///   it, so each listener drains its connections (up to its drain timeout),
///   and then `wait_forever` returns. While a process waits here, SIGTERM no
///   longer runs OTP's default `init:stop()`; SIGUSR1 and SIGQUIT still
///   halt the node. A further SIGTERM during the drain is logged and
///   ignored: the drain is not cut short. When several processes wait,
///   they drain one after the other, and none returns before the drain is
///   over.
/// - **The application was stopped** elsewhere (`stop` on its supervisor,
///   which already drained): returns at once.
///
/// The calling process traps exits. The abnormal exit of any linked
/// process (for example the root supervisor giving up after repeated
/// crashes) is received here and re-raised: the application never keeps
/// running with a dead tree. Nothing is polled and nothing sleeps.
pub fn wait_forever() -> Nil {
  let waiter = process.self()
  trap_exit()
  case install_signal_handler(waiter) {
    Ok(Nil) -> Nil
    Error(reason) -> fail_loudly("SIGTERM handling: " <> reason)
  }
  log.info("brazier.application", "Application running. Press Ctrl+C to stop.")
  case receive_wait_event() {
    Sigterm -> {
      // The handler stays installed through the drain, so a second SIGTERM
      // reaches it (logged and ignored), not OTP's `init:stop()`.
      let failures = drain_exclusively(stop_on_sigterm)
      leave_signal_handler(waiter)
      case failures {
        [] -> log.info("brazier.application", "Shutdown complete.")
        _ -> {
          let message =
            "Shutdown after SIGTERM failed: " <> string.join(failures, "; ")
          log.error("brazier.application", message)
          fail_loudly(message)
        }
      }
    }
    ShutdownRequested -> {
      leave_signal_handler(waiter)
      pass_on_late_sigterm()
      log.info(
        "brazier.application",
        "The application was stopped, wait_forever returns",
      )
    }
    LinkedProcessExited(reason) -> {
      leave_signal_handler(waiter)
      pass_on_late_sigterm()
      let message = "Linked application process exited: " <> reason
      log.error("brazier.application", message)
      fail_loudly(message)
    }
  }
}

/// What ended `wait_forever`'s wait.
type WaitEvent {
  /// The OS sent SIGTERM.
  Sigterm
  /// A linked process exited normally (the application was stopped).
  ShutdownRequested
  /// A linked process exited abnormally.
  LinkedProcessExited(reason: String)
}

fn leave_signal_handler(waiter: process.Pid) -> Nil {
  case uninstall_signal_handler(waiter) {
    Ok(Nil) -> Nil
    Error(reason) -> fail_loudly("SIGTERM handling: " <> reason)
  }
}

/// A SIGTERM that arrived after the wait ended for another reason, and
/// before the handler let this process go, was forwarded here and nobody
/// would act on it: hand it back to the signal server, so another waiter or
/// OTP's `init:stop()` answers it as if it arrived now.
fn pass_on_late_sigterm() -> Nil {
  case take_pending_sigterm() {
    False -> Nil
    True -> {
      log.warning(
        "brazier.application",
        "SIGTERM arrived as wait_forever was returning: passing it on",
      )
      pass_on_sigterm()
    }
  }
}

/// Stop every application running on this node, newest first, and return
/// the failures. Each stop drains its listener. Runs under the node's drain
/// lock (`drain_exclusively`), so an application is stopped by one waiter
/// only. An application found not running (stopped, or its tree died
/// earlier) is a warning from `stop`, not a failure of the shutdown.
fn stop_on_sigterm() -> List(String) {
  let apps = remembered_apps()
  case apps {
    [] ->
      log.info(
        "brazier.application",
        "SIGTERM: no application left running on this node, nothing to drain",
      )
    _ ->
      log.info(
        "brazier.application",
        "SIGTERM received, stopping "
          <> int.to_string(list.length(apps))
          <> " application(s) and draining their connections",
      )
  }
  list.filter_map(apps, fn(app) {
    // Stopping a linked supervisor sends this process (trapping exits)
    // its EXIT: take it, so it is not mistaken for a later event.
    let linked = is_linked(app.supervisor_pid)
    case stop_app(app) {
      Ok(Nil) -> {
        case linked {
          True -> {
            let reason = await_exit(app.supervisor_pid)
            log.debug(
              "brazier.application",
              "Stopped supervisor exited with " <> reason,
            )
          }
          False -> Nil
        }
        Error(Nil)
      }
      // The tree is gone already, which is what SIGTERM asks for.
      Error(NotRunning(_)) -> Error(Nil)
      Error(StopFailed(reason)) -> Ok(reason)
    }
  })
}

/// Why an integer environment variable could not be read.
type EnvIntError {
  EnvNotSet
  EnvNotInteger(value: String)
}

@external(erlang, "brazier_application_ffi", "trap_exit")
fn trap_exit() -> Nil

@external(erlang, "brazier_application_ffi", "receive_wait_event")
fn receive_wait_event() -> WaitEvent

@external(erlang, "brazier_signal_handler", "install")
fn install_signal_handler(waiter: process.Pid) -> Result(Nil, String)

@external(erlang, "brazier_signal_handler", "uninstall")
fn uninstall_signal_handler(waiter: process.Pid) -> Result(Nil, String)

@external(erlang, "brazier_application_ffi", "remember_app")
fn remember_app(supervisor: process.Pid, app: App) -> Nil

@external(erlang, "brazier_application_ffi", "forget_app")
fn forget_app(supervisor: process.Pid) -> Nil

@external(erlang, "brazier_application_ffi", "remembered_apps")
fn remembered_apps() -> List(App)

@external(erlang, "brazier_application_ffi", "drain_exclusively")
fn drain_exclusively(drain: fn() -> List(String)) -> List(String)

@external(erlang, "brazier_application_ffi", "take_pending_sigterm")
fn take_pending_sigterm() -> Bool

@external(erlang, "brazier_application_ffi", "pass_on_sigterm")
fn pass_on_sigterm() -> Nil

@external(erlang, "brazier_application_ffi", "is_linked")
fn is_linked(pid: process.Pid) -> Bool

/// The EXIT message of a linked process just stopped, formatted.
@external(erlang, "brazier_application_ffi", "await_exit")
fn await_exit(pid: process.Pid) -> String

@external(erlang, "brazier_application_ffi", "get_env_int")
fn get_env_int(name: String) -> Result(Int, EnvIntError)

/// Stop the calling process with an error (crash loudly).
@external(erlang, "brazier_application_ffi", "fail_loudly")
fn fail_loudly(reason: String) -> a

/// A one-shot flag: `once_take` returns True exactly once.
type Once

@external(erlang, "brazier_application_ffi", "once_new")
fn once_new() -> Once

@external(erlang, "brazier_application_ffi", "once_take")
fn once_take(once: Once) -> Bool

/// Stop a supervisor with reason `normal`, waiting up to `timeout` ms.
@external(erlang, "brazier_application_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid, timeout: Int) -> Result(Nil, StopFailure)
