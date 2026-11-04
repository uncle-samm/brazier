/// Brazier's server-side MVU runtime.
/// Runs the Model-View-Update loop as an OTP actor, one per user session.
/// Follows Lustre's runtime/server/runtime.gleam pattern.
///
/// Reference: Lustre server runtime, LiveView process model, Reflex event chain.
///
/// ## Versioning (one rule, shared with the client)
///
/// The runtime keeps a single `revision` counter. It starts at 0 and is
/// incremented exactly when the client-visible model JSON changes and is
/// sent as a patch or resync broadcast. Every `patch` carries the revision
/// it produces; every `model_sync` carries the current revision. The client
/// applies a non-empty patch only when `version == current + 1`, treats an
/// empty patch at `version == current` as a pure acknowledgement, ignores
/// stale versions, and requests a full sync on a gap. Navigation, joins and
/// acknowledgements never bump the revision on their own.
///
/// `ack_clock` is per connection: the highest event clock that connection
/// sent which the server has processed. It is never shared between
/// connections.
///
/// ## Routing (LiveView mount + handle_params)
///
/// `start` runs `init(ctx)` and then, when the app has a router, `update`
/// with the route message for `ctx`'s URL, before anything is rendered. A
/// client navigation runs `update` with the new route's message; a URL the
/// app does not route (or whose encoding does not decode) is answered with
/// a hard navigation, so the server's dead render produces the 404 or 400.
///
/// ## Presence
///
/// With `presence` configured, the initialiser starts the session's
/// presence watcher (`brazier/internal/presence_watch`) with the initial
/// state's trackings and fails the start if they are refused. After every
/// update (like dynamic subscriptions) the trackings are computed again and
/// handed to the watcher when they changed; its `on_presence` messages
/// arrive as dispatched effects. The watcher is linked: if it fails (PubSub
/// or the tracker gone for good, a refused track) the runtime exits with
/// its reason and the clients reconnect.
///
/// ## Telemetry
///
/// `start` runs inside a `[brazier, runtime, mount]` span; every client
/// event's `update` inside `[brazier, runtime, handle_event]`; a client
/// navigation's (or a join's route change) inside `[brazier, runtime,
/// navigate]`; every broadcast to joined connections inside `[brazier,
/// runtime, render]`. `event` is the message's constructor name in
/// snake_case (`SetCount(9)` is `"set_count"`), or
/// `"unknown"` for an event or path the app does not handle, so the label
/// set stays the app's finite set of constructors. `route` is
/// `transport.page_route`: the typed router has no patterns.
///
/// Every stop that runs code emits `[brazier, runtime, stop]` with the
/// runtime's uptime: a `Shutdown` with reason `shutdown`; a crash in the
/// message handler with reason `crash`, the exception class as `kind` and
/// the reason as `error` (the handler is guarded the way gen_server calls
/// `terminate/2` for a callback that raises; the crash then goes on
/// unchanged); an exit signal (a linked process failing, an exit sent to
/// the runtime) with reason `exit`. The runtime traps exits for that, and
/// leaves with the signal's reason. Only an untrappable `kill` emits
/// nothing.
import brazier/cookie
import brazier/effect.{type Effect}
import brazier/error
import brazier/internal/context.{type Context}
import brazier/internal/presence_watch
import brazier/internal/uri_check
import brazier/log
import brazier/notification.{type Notification, Notification}
import brazier/patch
import brazier/pubsub
import brazier/ssr
import brazier/telemetry
import brazier/transport
import brazier/transport/server
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/uri.{type Uri}

/// The client-visible model JSON every joined connection currently holds
/// (at `revision`). Diffs are computed against it.
///
/// Invariant: when the cache is not `NoCache` it equals the JSON of the
/// runtime's current model as last sent to every joined connection.
pub type CachedModelState {
  /// Nothing trustworthy is cached (no joined connections yet, or the last
  /// broadcast failed). The next broadcast is a full `model_sync`.
  NoCache
  /// The full client-visible model JSON.
  FullModelCache(json: String)
}

/// Messages the runtime actor can receive.
pub type RuntimeMessage(msg) {
  /// A client connected — register their transport subject for pushing updates.
  ClientConnected(
    conn_id: transport.ConnectionId,
    subject: Subject(transport.InternalMessage),
  )
  /// A client disconnected — remove their transport subject.
  ClientDisconnected(conn_id: transport.ConnectionId)
  /// A client sent a join request with no browser session binding
  /// (equivalent to `ClientJoinedWithSession` with fingerprint "").
  ClientJoined(conn_id: transport.ConnectionId, token: String, path: String)
  /// A client sent a join request. `token` is the signed join token (empty
  /// for none) and `session_fingerprint` identifies the browser session the
  /// connection belongs to (see `ssr.session_fingerprint`); the token only
  /// verifies for the session it was issued to.
  ///
  /// A token that does not verify, a token model that does not restore,
  /// and a missing token while state recovery is enabled refuse the join:
  /// the connection gets an `error` frame and stays unjoined.
  ClientJoinedWithSession(
    conn_id: transport.ConnectionId,
    token: String,
    path: String,
    session_fingerprint: String,
  )
  /// A join on the connection of a runtime started by
  /// `start_and_connect_with_request`. Its join token was read from the
  /// upgrade request's cookie and checked before the runtime started (a
  /// bad one refused the connection), and a recovered model is already in
  /// place, so the join uses no token.
  ClientJoinedVerified(conn_id: transport.ConnectionId, path: String)
  /// A client event was received — decode to user message and run update.
  ClientEventReceived(
    conn_id: transport.ConnectionId,
    event_name: String,
    handler_id: String,
    event_data: String,
    target_path: String,
    clock: Int,
    /// JSON-encoded patch ops from client. Empty string means no ops.
    ops: String,
  )
  /// A batch of events to process atomically (all updates, one render).
  /// Used when LOCAL events are replayed before a MODEL event.
  ClientEventBatchReceived(
    conn_id: transport.ConnectionId,
    events: List(#(String, String, String, String, Int, String)),
  )
  /// A client navigated to a new URL path.
  ClientNavigated(conn_id: transport.ConnectionId, path: String)
  /// Client requested a full model sync without a remount.
  ClientSyncRequested(conn_id: transport.ConnectionId)
  /// Set the listener subject for dynamic subscription management.
  SetListenerSubject(
    listener: Subject(ListenerCommand),
    initial_subs: List(String),
  )
  /// An effect dispatched a message back to the runtime.
  EffectDispatched(message: msg)
  /// A keyed effect dispatched a message back to the runtime.
  EffectDispatchedKeyed(key: String, generation: Int, message: msg)
  /// Shutdown the runtime.
  Shutdown
  /// An exit signal the runtime trapped: a linked process (the connection
  /// handler that started it, its PubSub listener or presence watcher, a
  /// process the app linked) exited, or a process sent the runtime an
  /// exit. Delivered by the VM; nothing sends it.
  ExitTrapped(exit: process.ExitMessage)
}

/// The runtime's internal state. `model` is the app's server state (for
/// `full_application`, the state record that `sync` projects).
pub type RuntimeState(model, msg) {
  RuntimeState(
    /// The application's current server state.
    model: model,
    /// The update function: state + message → new state + effects.
    update: fn(model, msg) -> #(model, Effect(msg)),
    /// Decodes client events into user messages.
    decode_event: fn(String, String, String, String) ->
      Result(msg, error.BrazierError),
    /// Currently connected clients: conn_id → transport subject.
    connections: Dict(
      transport.ConnectionId,
      Subject(transport.InternalMessage),
    ),
    /// Connections that completed a join. Only these receive patches and
    /// may send events.
    joined: Set(transport.ConnectionId),
    /// Per-connection acknowledged event clock.
    client_acks: Dict(transport.ConnectionId, Int),
    /// Client-visible model revision (see the module docs).
    revision: Int,
    /// Whether a join has been accepted. Join-token state recovery only
    /// applies to the first join of a runtime.
    accepted_first_join: Bool,
    /// The runtime's own subject for dispatching effect messages.
    self: Subject(RuntimeMessage(msg)),
    /// Client-visible model encoder (the generated codec over `sync`).
    model_encoder: fn(model) -> String,
    /// Rebuild the server state from join-token model JSON (state recovery).
    restore_model: Option(fn(String) -> Result(model, String)),
    /// Secret key for join tokens.
    secret_key: String,
    /// The app's `parse` composed with `on_change`, when it has a router.
    route: Option(fn(Uri) -> Result(msg, Nil)),
    /// The URL the session was started for. A navigation path replaces its
    /// path and query; scheme, host and port stay.
    page_uri: Uri,
    /// The route message last applied, so a join for the same route does
    /// not run `on_change` again.
    current_route_msg: Option(msg),
    /// Subject for sending commands to the PubSub listener process.
    listener_subject: Option(Subject(ListenerCommand)),
    /// Current set of dynamic subscriptions (for diffing).
    current_subscriptions: List(String),
    /// Dynamic subscription function: model → list of topics.
    dynamic_subscriptions: Option(fn(model) -> List(String)),
    /// Cached client-visible model JSON for diffing.
    cached_model: CachedModelState,
    /// Framework-owned effect processes, such as effect.every timers.
    effect_processes: List(Pid),
    /// The session's presence watcher, when the app has presence.
    presence: Option(presence_watch.Watcher(model)),
    /// Native monotonic time the runtime started, for its uptime.
    started_at: Int,
    /// The document title for the server state, when the app has one.
    title: Option(fn(model) -> String),
    /// The title the joined connections were last sent. `None` until the
    /// first join (the server render carried the title until then).
    last_title: Option(String),
  )
}

/// Configuration needed to start a runtime. `brazier.start` builds it from
/// the app and the generated codec; tests build it directly.
pub type RuntimeConfig(state, msg) {
  RuntimeConfig(
    /// The app's `init`, run with the connected-mount context. An `Error`
    /// refuses the start (`error.InitRejected`).
    init: fn(Context) -> Result(#(state, Effect(msg)), error.InitError),
    /// The app's server `update`.
    update: fn(state, msg) -> #(state, Effect(msg)),
    /// Encode the client-visible model (the codec's `encode_model` over the
    /// app's `sync`). Its output is what `model_sync` and patches carry.
    encode_model: fn(state) -> String,
    /// Decode a client event into a message (the generated
    /// `brazier_codec.decode_event`, which enforces the message allowlist).
    decode_event: fn(String, String, String, String) ->
      Result(msg, error.BrazierError),
    /// Rebuild the server state from the client-visible model JSON carried
    /// by a join token. Set only when the app opted into state recovery.
    restore_model: Option(fn(String) -> Result(state, String)),
    /// The app's `parse` composed with `on_change`, when it has a router.
    route: Option(fn(Uri) -> Result(msg, Nil)),
    /// Dynamic subscription function: given the current state, returns
    /// the set of topics this runtime should be subscribed to.
    /// Called after every update and join. The framework diffs against
    /// current subscriptions.
    dynamic_subscriptions: Option(fn(state) -> List(String)),
    /// Called when a PubSub notification arrives on a dynamically subscribed topic.
    /// Receives the topic string so the handler can distinguish between sources.
    on_notify: Option(fn(String) -> msg),
    /// Called when a typed PubSub notification arrives on a dynamically subscribed topic.
    on_notification: Option(fn(Notification) -> msg),
    /// Secret key for join-token verification.
    /// Must not be empty when state recovery is enabled.
    secret_key: String,
    /// The app's presence: what the session tracks for its state and the
    /// message for a change on its topics.
    presence: Option(presence_watch.Watch(state, msg)),
    /// The document title for the server state (the app's `title`). Sent
    /// on every join and whenever an update changes it, so the browser's
    /// title follows live updates. `None` sends no title.
    title: Option(fn(state) -> String),
  )
}

/// Start a runtime actor for the session described by `ctx`. Returns a
/// Subject for sending RuntimeMessages.
///
/// Runs `init(ctx)` and, when the app has a router, `update` with the route
/// message for `ctx`'s URL (LiveView's mount followed by handle_params).
/// A URL whose encoding does not decode is a `RuntimeError`: the client
/// only reports URLs the browser already loaded, so it means a forged or
/// broken connect request.
pub fn start(
  config: RuntimeConfig(model, msg),
  ctx: Context,
) -> Result(Subject(RuntimeMessage(msg)), error.BrazierError) {
  log.debug(
    "brazier.runtime",
    "Starting a runtime outside the transport for " <> context.uri(ctx).path,
  )
  start_for(config, ctx, no_connection, None)
}

/// The `connection_id` telemetry label of work no connection caused (an
/// effect's message, a runtime started outside the transport).
const no_connection = "none"

/// State recovery signs and verifies join tokens with the secret key, so
/// an empty key with recovery enabled is a configuration error: every
/// join would be refused.
fn check_recovery_config(
  config: RuntimeConfig(model, msg),
) -> Result(Nil, error.BrazierError) {
  case config.restore_model, config.secret_key {
    Some(_), "" -> {
      let reason =
        "state recovery is enabled but the secret key is empty, so no join token can verify"
      log.error("brazier.runtime", "Refusing to start a runtime: " <> reason)
      Error(error.ConfigError(reason: reason))
    }
    _, _ -> Ok(Nil)
  }
}

/// `start`, with the connection the mount span is reported for and the
/// model recovered from the connection's join token, if any.
fn start_for(
  config: RuntimeConfig(model, msg),
  ctx: Context,
  connection_id: String,
  recovered: Option(model),
) -> Result(Subject(RuntimeMessage(msg)), error.BrazierError) {
  let page_uri = context.uri(ctx)
  use Nil <- result.try(check_recovery_config(config))
  case uri_check.check(page_uri) {
    Error(reason) -> {
      log.error(
        "brazier.runtime",
        "Refusing to start a runtime for "
          <> uri.to_string(page_uri)
          <> ": "
          <> reason,
      )
      Error(error.RuntimeError(reason: "Invalid page URL: " <> reason))
    }
    Ok(Nil) ->
      telemetry.runtime_span(
        telemetry.Mount,
        transport.page_route,
        "mount",
        connection_id,
        fn() { start_actor(config, ctx, page_uri, connection_id, recovered) },
      )
  }
}

/// The model a session starts from: `init`, then the initial route.
type Mounted(model, msg) {
  Mounted(model: model, effects: Effect(msg), route_msg: Option(msg))
}

/// A runtime that does not start is logged once, here, where the cause is
/// known: by `mount`, `start_presence` or `spawn_actor`, with the page and
/// connection. The callers up to the transport only pass the error on (the
/// transport logs the close it answers with at info).
fn start_actor(
  config: RuntimeConfig(model, msg),
  ctx: Context,
  page_uri: Uri,
  connection_id: String,
  recovered: Option(model),
) -> Result(Subject(RuntimeMessage(msg)), error.BrazierError) {
  let started_at = monotonic_time()
  use mounted <- result.try(mount(config, ctx, page_uri, connection_id))
  // `init` and the initial route still run (their effects and route
  // message stand); the recovered model replaces the state they built,
  // before presence, subscriptions and effect messages first see it.
  let mounted = case recovered {
    None -> mounted
    Some(model) -> {
      log.info(
        "brazier.runtime",
        "Starting connection "
          <> connection_id
          <> " from the model recovered from its join token",
      )
      Mounted(..mounted, model: model)
    }
  }
  spawn_actor(config, mounted, page_uri, started_at, connection_id)
}

/// Run the app's `init` and initial route in the calling process (the
/// connection's handler). A crash in either is caught, logged once with its
/// stacktrace and returned as a `RuntimeError`, so the socket is closed
/// with 1011 instead of the handler process dying without a close frame
/// (LiveView answers a crash in the connected mount by failing the join).
fn mount(
  config: RuntimeConfig(model, msg),
  ctx: Context,
  page_uri: Uri,
  connection_id: String,
) -> Result(Mounted(model, msg), error.BrazierError) {
  let path = describe_uri(page_uri) <> " (connection " <> connection_id <> ")"
  case run_guarded(fn() { init_and_route(config, ctx, page_uri) }) {
    Error(#(crash, stacktrace)) -> {
      log.error(
        "brazier.runtime",
        "init or the initial route crashed for "
          <> path
          <> ": "
          <> crash
          <> "\n"
          <> stacktrace,
      )
      Error(error.RuntimeError(reason: "init crashed: " <> crash))
    }
    Ok(Error(init_error)) -> {
      let message =
        "init refused the session for "
        <> path
        <> " ("
        <> error.init_error_to_string(init_error)
        <> ")"
      case error.init_error_status(init_error) >= 500 {
        True -> log.error("brazier.runtime", message)
        False -> log.warning("brazier.runtime", message)
      }
      Error(error.InitRejected(init_error))
    }
    Ok(Ok(mounted)) -> Ok(mounted)
  }
}

fn init_and_route(
  config: RuntimeConfig(model, msg),
  ctx: Context,
  page_uri: Uri,
) -> Result(Mounted(model, msg), error.InitError) {
  use #(initial_model, init_effects) <- result.map(config.init(ctx))
  case config.route {
    None ->
      Mounted(model: initial_model, effects: init_effects, route_msg: None)
    Some(route) ->
      case route(page_uri) {
        Ok(msg) -> {
          log.debug(
            "brazier.runtime",
            "Applying the initial route for " <> describe_uri(page_uri),
          )
          let #(routed, route_effects) = config.update(initial_model, msg)
          Mounted(
            model: routed,
            effects: effect.batch([init_effects, route_effects]),
            route_msg: Some(msg),
          )
        }
        Error(Nil) -> {
          // The dead render answered this URL with a 404 page without the
          // client script, so a connect for it is unusual; the join reports
          // the unknown route to the client.
          log.warning(
            "brazier.runtime",
            "No route for the session URL " <> describe_uri(page_uri),
          )
          Mounted(model: initial_model, effects: init_effects, route_msg: None)
        }
      }
  }
}

/// Run `run`, returning a crash (error, exit or throw) as `Error` with its
/// `class:reason` and its formatted stacktrace. It logs nothing.
@external(erlang, "brazier_runtime_ffi", "run_guarded")
fn run_guarded(run: fn() -> a) -> Result(a, #(String, String))

fn spawn_actor(
  config: RuntimeConfig(model, msg),
  mounted: Mounted(model, msg),
  page_uri: Uri,
  started_at: Int,
  connection_id: String,
) -> Result(Subject(RuntimeMessage(msg)), error.BrazierError) {
  let Mounted(
    model: initial_model,
    effects: initial_effects,
    route_msg: route_msg,
  ) = mounted
  let result =
    actor.new_with_initialiser(5000, fn(subject) {
      // Presence first: a refused tracking fails the start before any
      // effect runs.
      use watcher <- result.try(start_presence(
        config.presence,
        subject,
        initial_model,
        connection_id,
      ))
      let initial_effect_processes = run_effects(initial_effects, subject)
      let state =
        RuntimeState(
          model: initial_model,
          update: config.update,
          decode_event: config.decode_event,
          connections: dict.new(),
          joined: set.new(),
          client_acks: dict.new(),
          revision: 0,
          accepted_first_join: False,
          self: subject,
          model_encoder: config.encode_model,
          restore_model: config.restore_model,
          secret_key: config.secret_key,
          route: config.route,
          page_uri: page_uri,
          current_route_msg: route_msg,
          listener_subject: None,
          current_subscriptions: [],
          dynamic_subscriptions: config.dynamic_subscriptions,
          cached_model: NoCache,
          effect_processes: initial_effect_processes,
          presence: watcher,
          started_at: started_at,
          title: config.title,
          last_title: None,
        )
      log.debug("brazier.runtime", "Runtime initialising")
      // Trap exits so a stop caused by a linked process still reports
      // [brazier, runtime, stop] (see handle_exit). An untrappable `kill`
      // is the only stop that runs no code. Because of the trap the runtime
      // must not stop with actor.stop_abnormal: gleam_otp implements it as
      // an exit signal to itself, which a trapping process receives as a
      // message and then exits normally.
      process.trap_exits(True)
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_trapped_exits(ExitTrapped)

      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(guarded_handle_message)
    |> actor.start

  case result {
    Ok(started) -> {
      log.info("brazier.runtime", "Runtime actor started")
      let subject = started.data
      log.debug(
        "brazier.runtime",
        "Dynamic subs: "
          <> yes_no(option.is_some(config.dynamic_subscriptions))
          <> ", on_notify: "
          <> yes_no(option.is_some(config.on_notify))
          <> ", on_notification: "
          <> yes_no(option.is_some(config.on_notification))
          <> ", router: "
          <> yes_no(option.is_some(config.route))
          <> ", presence: "
          <> yes_no(option.is_some(config.presence)),
      )
      case config.dynamic_subscriptions {
        Some(compute) -> {
          let initial_topics = compute(initial_model)
          let listener =
            start_pubsub_listener(
              subject,
              started.pid,
              config.on_notify,
              config.on_notification,
              initial_topics,
            )
          process.send(
            subject,
            SetListenerSubject(listener: listener, initial_subs: initial_topics),
          )
        }
        None -> Nil
      }
      Ok(subject)
    }
    Error(actor.InitTimeout) -> {
      log.error(
        "brazier.runtime",
        "Failed to start the runtime for connection "
          <> connection_id
          <> ": its initialiser did not finish within 5000ms",
      )
      Error(error.RuntimeError(reason: "Runtime init timed out"))
    }
    // The initialiser fails only when presence refuses the session, and
    // start_presence logged that with the tracker and connection.
    Error(actor.InitFailed(reason)) -> {
      log.debug(
        "brazier.runtime",
        "No runtime for connection " <> connection_id <> ": " <> reason,
      )
      Error(error.RuntimeError(reason: "Runtime init failed: " <> reason))
    }
    Error(actor.InitExited(reason)) -> {
      let reason = string.inspect(reason)
      log.error(
        "brazier.runtime",
        "Failed to start the runtime for connection "
          <> connection_id
          <> ": its initialiser exited with "
          <> reason,
      )
      Error(error.RuntimeError(
        reason: "Runtime init process exited: " <> reason,
      ))
    }
  }
}

/// Start the presence watcher from inside the runtime's initialiser, so the
/// runtime is its owner.
fn start_presence(
  watch: Option(presence_watch.Watch(model, msg)),
  subject: Subject(RuntimeMessage(msg)),
  model: model,
  connection_id: String,
) -> Result(Option(presence_watch.Watcher(model)), String) {
  case watch {
    None -> Ok(None)
    Some(watch) ->
      presence_watch.start(
        watch,
        fn(msg) { process.send(subject, EffectDispatched(message: msg)) },
        model,
      )
      |> result.map(Some)
      |> result.map_error(fn(reason) {
        log.error(
          "brazier.runtime",
          "Presence of tracker "
            <> presence_watch.name(watch)
            <> " refused the session of connection "
            <> connection_id
            <> ": "
            <> reason,
        )
        "presence: " <> reason
      })
  }
}

fn yes_no(flag: Bool) -> String {
  case flag {
    True -> "YES"
    False -> "NO"
  }
}

/// `handle_message`, reporting a crash in it (the app's `update`, `view` or
/// codec, an effect run in the runtime, a broken invariant) as
/// `[brazier, runtime, stop]` with reason `crash` before the crash goes on
/// unchanged: the runtime dies with the original reason and stacktrace and
/// the VM's crash report logs it, as before.
fn guarded_handle_message(
  state: RuntimeState(model, msg),
  message: RuntimeMessage(msg),
) -> actor.Next(RuntimeState(model, msg), RuntimeMessage(msg)) {
  case message {
    // Outside the guard: handle_exit leaves with the signal's reason by
    // raising an exit, which the guard would report again as a crash.
    ExitTrapped(exit) -> handle_exit(state, exit)
    _ ->
      guard_handler(
        fn() { handle_message(state, message) },
        fn(kind, description) {
          telemetry.runtime_stop_failed(
            monotonic_time() - state.started_at,
            "crash",
            kind,
            description,
          )
        },
      )
  }
}

@external(erlang, "brazier_runtime_ffi", "guard_handler")
fn guard_handler(run: fn() -> a, on_crash: fn(String, String) -> Nil) -> a

/// A trapped exit. A normal exit of a linked process does not stop the
/// runtime, as an untrapped link would not; any other exit stops it with
/// the same reason, after `[brazier, runtime, stop]` with reason `exit`, so
/// the runtime's own links (the listener, the watcher) see what they would
/// have seen without the trap.
fn handle_exit(
  state: RuntimeState(model, msg),
  exit: process.ExitMessage,
) -> actor.Next(RuntimeState(model, msg), RuntimeMessage(msg)) {
  case exit.reason {
    process.Normal -> {
      log.debug(
        "brazier.runtime",
        "Linked process " <> string.inspect(exit.pid) <> " exited normally",
      )
      actor.continue(state)
    }
    reason -> {
      let description = describe_exit(reason)
      // The process that failed reports its own crash; this is the
      // runtime's stop that follows from it.
      log.warning(
        "brazier.runtime",
        "Runtime stopping with "
          <> int.to_string(dict.size(state.connections))
          <> " connection(s): exit signal from "
          <> string.inspect(exit.pid)
          <> ": "
          <> description,
      )
      telemetry.runtime_stop_failed(
        monotonic_time() - state.started_at,
        "exit",
        "exit",
        description,
      )
      exit_like(reason)
    }
  }
}

@external(erlang, "brazier_runtime_ffi", "describe_exit")
fn describe_exit(reason: process.ExitReason) -> String

/// Exit with `reason` (never `Normal`).
@external(erlang, "brazier_runtime_ffi", "exit_like")
fn exit_like(reason: process.ExitReason) -> a

/// The main message loop for the runtime actor.
/// Follows Lustre's loop pattern: handle message → update state → return Next.
fn handle_message(
  state: RuntimeState(model, msg),
  message: RuntimeMessage(msg),
) -> actor.Next(RuntimeState(model, msg), RuntimeMessage(msg)) {
  case message {
    ClientConnected(conn_id, subject) -> {
      let state = case dict.has_key(state.connections, conn_id) {
        True -> {
          log.warning(
            "brazier.runtime",
            "Connection "
              <> conn_id
              <> " registered again; it must join again before receiving updates",
          )
          forget_connection(state, conn_id)
        }
        False -> {
          log.info("brazier.runtime", "Client connected: " <> conn_id)
          state
        }
      }
      actor.continue(
        RuntimeState(
          ..state,
          connections: dict.insert(state.connections, conn_id, subject),
        ),
      )
    }

    ClientDisconnected(conn_id) -> {
      log.info("brazier.runtime", "Client disconnected: " <> conn_id)
      actor.continue(forget_connection(state, conn_id))
    }

    ClientJoined(conn_id, token, path) ->
      actor.continue(handle_join(
        state,
        conn_id,
        VerifyAtJoin(token: token, session_fingerprint: ""),
        path,
      ))

    ClientJoinedWithSession(conn_id, token, path, session_fingerprint) ->
      actor.continue(handle_join(
        state,
        conn_id,
        VerifyAtJoin(token: token, session_fingerprint: session_fingerprint),
        path,
      ))

    ClientJoinedVerified(conn_id, path) ->
      actor.continue(handle_join(state, conn_id, VerifiedAtStart, path))

    ClientEventReceived(
      conn_id,
      event_name,
      handler_id,
      event_data,
      target_path,
      clock,
      ops,
    ) ->
      case set.contains(state.joined, conn_id) {
        False -> actor.continue(reject_before_join(state, conn_id, "event"))
        True -> {
          log.debug(
            "brazier.runtime",
            "Event from "
              <> conn_id
              <> ": "
              <> event_name
              <> " ["
              <> handler_id
              <> "] clock="
              <> int.to_string(clock),
          )
          warn_client_ops(conn_id, ops)
          let state = record_ack(state, conn_id, clock)
          case
            state.decode_event(event_name, handler_id, event_data, target_path)
          {
            Ok(msg) -> {
              let #(state, changed) =
                run_update_for(
                  state,
                  msg,
                  Some(conn_id),
                  Some(telemetry.HandleEvent),
                )
              actor.continue(ack_if_unchanged(state, conn_id, changed))
            }
            Error(err) ->
              telemetry.runtime_span(
                telemetry.HandleEvent,
                transport.page_route,
                unknown_event,
                conn_id,
                fn() {
                  let err_str = error.to_string(err)
                  log.warning(
                    "brazier.runtime",
                    "Failed to decode event from " <> conn_id <> ": " <> err_str,
                  )
                  send_to_conn_id(state, conn_id, transport.SendError(err_str))
                  // The rejected event is still acknowledged so the client
                  // drops its optimistic state and returns to the server's
                  // model.
                  actor.continue(ack_if_unchanged(state, conn_id, False))
                },
              )
          }
        }
      }

    ClientEventBatchReceived(conn_id, events) ->
      case set.contains(state.joined, conn_id) {
        False ->
          actor.continue(reject_before_join(state, conn_id, "event batch"))
        True -> actor.continue(handle_batch(state, conn_id, events))
      }

    ClientNavigated(conn_id, path) ->
      case set.contains(state.joined, conn_id) {
        False ->
          actor.continue(reject_before_join(state, conn_id, "navigation"))
        True -> {
          log.info(
            "brazier.runtime",
            "Navigation: " <> conn_id <> " → " <> path,
          )
          actor.continue(handle_navigation(state, conn_id, path))
        }
      }

    ClientSyncRequested(conn_id) ->
      case set.contains(state.joined, conn_id) {
        False ->
          actor.continue(reject_before_join(state, conn_id, "sync request"))
        True -> {
          log.warning(
            "brazier.runtime",
            "Client requested full model sync: " <> conn_id,
          )
          actor.continue(resync(state, conn_id, "client_request_sync"))
        }
      }

    SetListenerSubject(listener, initial_subs) -> {
      log.debug("brazier.runtime", "Listener subject registered")
      // The model may have changed (init effects) since the initial topics
      // were computed; reconcile immediately.
      actor.continue(reconcile_subscriptions(
        RuntimeState(
          ..state,
          listener_subject: Some(listener),
          current_subscriptions: initial_subs,
        ),
      ))
    }

    EffectDispatched(msg) -> {
      log.debug("brazier.runtime", "Effect dispatched a message")
      let #(state, _changed) = run_update_for(state, msg, None, None)
      actor.continue(state)
    }

    EffectDispatchedKeyed(key, generation, msg) -> {
      case effect.is_current_key_generation(key, generation) {
        True -> {
          log.debug(
            "brazier.runtime",
            "Keyed effect dispatched for key " <> key,
          )
          let #(state, _changed) = run_update_for(state, msg, None, None)
          actor.continue(state)
        }
        False -> {
          log.debug(
            "brazier.runtime",
            "Dropping stale keyed effect for key " <> key,
          )
          actor.continue(state)
        }
      }
    }

    Shutdown -> {
      log.info("brazier.runtime", "Runtime shutting down")
      telemetry.runtime_stop(monotonic_time() - state.started_at, "shutdown")
      stop_listener(state.listener_subject)
      stop_effect_processes(state.effect_processes)
      case state.presence {
        Some(watcher) -> presence_watch.stop(watcher)
        None -> Nil
      }
      actor.stop()
    }

    // guarded_handle_message answers trapped exits before this is called.
    ExitTrapped(exit) -> handle_exit(state, exit)
  }
}

/// Remove every trace of a connection. With no joined connection left the
/// cache no longer describes anyone's state.
fn forget_connection(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
) -> RuntimeState(model, msg) {
  let joined = set.delete(state.joined, conn_id)
  RuntimeState(
    ..state,
    connections: dict.delete(state.connections, conn_id),
    joined: joined,
    client_acks: dict.delete(state.client_acks, conn_id),
    cached_model: case set.is_empty(joined) {
      True -> NoCache
      False -> state.cached_model
    },
  )
}

fn warn_client_ops(conn_id: transport.ConnectionId, ops: String) -> Nil {
  case ops {
    "" -> Nil
    _ ->
      log.warning(
        "brazier.runtime",
        "Ignoring client-supplied model ops from "
          <> conn_id
          <> " because server update is authoritative",
      )
  }
}

/// Reject a message that requires a joined connection. Nothing is applied.
fn reject_before_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  what: String,
) -> RuntimeState(model, msg) {
  log.warning(
    "brazier.runtime",
    "Rejected " <> what <> " from " <> conn_id <> ": connection has not joined",
  )
  send_to_conn_id(
    state,
    conn_id,
    transport.SendError(reason: what <> " received before join"),
  )
  state
}

/// How a join's token is checked.
type JoinToken {
  /// Verify `token` at the join: a runtime started without the upgrade
  /// request (`start`, `start_and_connect`), where the join message
  /// carries the token.
  VerifyAtJoin(token: String, session_fingerprint: String)
  /// The token came from the upgrade request's cookie and was checked
  /// before the runtime started (`start_and_connect_with_request`).
  VerifiedAtStart
}

/// The HTTP status of a connection refused for its join token. The socket
/// closes with 4400 (`error.init_close_code`), and the browser reloads the
/// page, whose server render issues a fresh token.
///
/// Reference: LiveView answers a join whose session token does not verify
/// with a "stale" or "unauthorized" join error, and its client reloads the
/// page (knowledge of `Phoenix.LiveView.Channel` and the JS client, not
/// code read here).
pub const join_token_refused_status = 400

/// Join (or rejoin) a connection.
///
/// - First join of a connection: its join token is checked (see
///   `check_join_token`). A token that fails the check refuses the join
///   loudly: the refusal is logged, the connection gets an `error` frame
///   ("join refused") and stays unjoined. The session never continues with
///   the server model in place of a token it could not use.
/// - Repeated join on an already-joined connection: an explicit, logged
///   rejoin. The token is not used; the connection gets a full model_sync.
/// - `on_change` runs only when the joined path's route message differs
///   from the one last applied (a join never re-runs it for the same
///   route). A joined path the app does not route is reported to the
///   client as an error.
fn handle_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  join_token: JoinToken,
  path: String,
) -> RuntimeState(model, msg) {
  case dict.has_key(state.connections, conn_id) {
    False -> {
      log.warning(
        "brazier.runtime",
        "Join from unregistered connection " <> conn_id <> " rejected",
      )
      state
    }
    True -> {
      let checked = case set.contains(state.joined, conn_id) {
        True -> {
          log.info(
            "brazier.runtime",
            "Rejoin from "
              <> conn_id
              <> " path: "
              <> path
              <> " — full resync, join token not used",
          )
          Ok(RuntimeState(..state, joined: set.delete(state.joined, conn_id)))
        }
        False -> {
          log.info(
            "brazier.runtime",
            "Client joined: " <> conn_id <> " path: " <> path,
          )
          recover_at_join(state, conn_id, join_token)
        }
      }
      case checked {
        Error(reason) -> {
          log.warning(
            "brazier.runtime",
            "Join from " <> conn_id <> " refused: " <> reason,
          )
          send_to_conn_id(
            state,
            conn_id,
            transport.SendError(reason: join_refused_reason),
          )
          state
        }
        Ok(state) -> accept_join(state, conn_id, path)
      }
    }
  }
}

/// The `error` frame reason of a join refused for its token. The cause is
/// only logged.
const join_refused_reason = "join refused"

fn accept_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  path: String,
) -> RuntimeState(model, msg) {
  // Route changes are broadcast to the OTHER joined connections; the
  // joiner is not joined yet and gets the result in its model_sync.
  let state = route_join(state, conn_id, path)
  // If the cache is unusable, the other joined connections may be stale
  // too: resync everyone, not just the joiner.
  let stale_others = case state.cached_model {
    NoCache -> set.to_list(state.joined)
    _ -> []
  }
  let state =
    RuntimeState(
      ..state,
      joined: set.insert(state.joined, conn_id),
      accepted_first_join: True,
      client_acks: case dict.has_key(state.client_acks, conn_id) {
        True -> state.client_acks
        False -> dict.insert(state.client_acks, conn_id, 0)
      },
    )
  let state =
    send_model_sync_to(state, [conn_id, ..stale_others], "join_model_sync")
  let state = send_title_on_join(state, conn_id)
  reconcile_subscriptions(state)
}

/// Check the token of a connection's first join and, on the runtime's
/// first join, put the model it recovers in place.
fn recover_at_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  join_token: JoinToken,
) -> Result(RuntimeState(model, msg), String) {
  case join_token {
    VerifiedAtStart -> {
      log.debug(
        "brazier.runtime",
        "Join token of " <> conn_id <> " was checked when its runtime started",
      )
      Ok(state)
    }
    VerifyAtJoin(token, session_fingerprint) -> {
      let restore = case state.accepted_first_join {
        // A second connection joining a live runtime must not replace the
        // model the first one is looking at; its token is still checked.
        True -> None
        False -> state.restore_model
      }
      use recovered <- result.map(check_join_token(
        restore,
        option.is_some(state.restore_model),
        state.secret_key,
        token,
        session_fingerprint,
        conn_id,
      ))
      case recovered {
        Some(model) -> RuntimeState(..state, model: model)
        None -> state
      }
    }
  }
}

/// Check a join token. `Ok(Some(model))` is the model recovered from it,
/// `Ok(None)` a token with nothing to recover (or none, without state
/// recovery), and `Error(reason)` a join that must be refused:
///
/// - a token that does not verify: malformed, signed with another key (an
///   older server process with a generated secret), expired, or issued to
///   another browser session;
/// - a token whose model `restore` refuses (the model's shape changed);
/// - no token while state recovery is enabled: the server render always
///   sets the cookie, so its absence means the browser did not keep it.
///
/// `restore` is `None` when no model is to be recovered (recovery disabled,
/// or the runtime already joined a connection); `recovery_enabled` says
/// whether the app opted into state recovery at all.
fn check_join_token(
  restore: Option(fn(String) -> Result(model, String)),
  recovery_enabled: Bool,
  secret_key: String,
  token: String,
  session_fingerprint: String,
  conn_id: transport.ConnectionId,
) -> Result(Option(model), String) {
  case token, recovery_enabled {
    "", False -> {
      log.debug("brazier.runtime", "No join token for " <> conn_id)
      Ok(None)
    }
    "", True ->
      Error(
        "state recovery is enabled and the join carries no join token (the "
        <> ssr.session_cookie_name
        <> " cookie is missing)",
      )
    _, _ -> {
      use verified <- result.try(
        ssr.verify_join_token(
          token,
          secret_key,
          session_fingerprint,
          system_time_seconds(),
        )
        |> result.map_error(fn(err) {
          "the join token does not verify: "
          <> ssr.describe_join_token_error(err)
        }),
      )
      case restore, verified.model_json {
        None, _ -> {
          log.debug(
            "brazier.runtime",
            "Join token from "
              <> conn_id
              <> " verified; no model is recovered for this join",
          )
          Ok(None)
        }
        Some(_), None -> {
          log.debug(
            "brazier.runtime",
            "Join token from " <> conn_id <> " carries no model",
          )
          Ok(None)
        }
        Some(restore), Some(model_json) ->
          case restore(model_json) {
            Ok(model) -> {
              log.info(
                "brazier.runtime",
                "State recovered from the join token for " <> conn_id,
              )
              Ok(Some(model))
            }
            Error(reason) ->
              Error("the join token's model does not restore: " <> reason)
          }
      }
    }
  }
}

/// Process a batch: every update runs, then one broadcast. The batch is
/// acknowledged up to its highest clock, including events that failed to
/// decode (they are reported to the client, never silently dropped).
fn handle_batch(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  events: List(#(String, String, String, String, Int, String)),
) -> RuntimeState(model, msg) {
  let count = list.length(events)
  log.debug(
    "brazier.runtime",
    "Atomic batch from " <> conn_id <> ": " <> int.to_string(count) <> " events",
  )
  case events {
    [] -> {
      log.warning(
        "brazier.runtime",
        "Empty event batch from " <> conn_id <> " ignored",
      )
      state
    }
    _ -> {
      let #(state, failures) =
        list.index_fold(events, #(state, []), fn(acc, evt, idx) {
          let #(acc_state, failures) = acc
          let #(event_name, handler_id, event_data, target_path, clock, ops) =
            evt
          warn_client_ops(conn_id, ops)
          let acc_state = record_ack(acc_state, conn_id, clock)
          case
            acc_state.decode_event(
              event_name,
              handler_id,
              event_data,
              target_path,
            )
          {
            Ok(msg) -> #(
              run_update_only(acc_state, msg, Some(conn_id)),
              failures,
            )
            Error(err) -> {
              let reason = error.to_string(err)
              // The rejection itself is the event's span: nothing ran.
              telemetry.runtime_span(
                telemetry.HandleEvent,
                transport.page_route,
                unknown_event,
                conn_id,
                fn() { Nil },
              )
              log.warning(
                "brazier.runtime",
                "Event rejected in batch from "
                  <> conn_id
                  <> " (idx "
                  <> int.to_string(idx)
                  <> "/"
                  <> int.to_string(count)
                  <> ", handler="
                  <> handler_id
                  <> "): "
                  <> reason,
              )
              #(acc_state, [reason, ..failures])
            }
          }
        })
      case list.reverse(failures) {
        [] -> Nil
        [first, ..] as all ->
          send_to_conn_id(
            state,
            conn_id,
            transport.SendError(
              reason: int.to_string(list.length(all))
              <> " of "
              <> int.to_string(count)
              <> " batched events rejected: "
              <> first,
            ),
          )
      }
      let #(state, changed) = broadcast_model(state, "batch", Some(conn_id))
      let state = reconcile_subscriptions(state)
      ack_if_unchanged(state, conn_id, changed)
    }
  }
}

fn record_ack(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  clock: Int,
) -> RuntimeState(model, msg) {
  let previous = ack_for(state, conn_id)
  case clock < previous {
    True ->
      log.warning(
        "brazier.runtime",
        "Non-monotonic event clock from "
          <> conn_id
          <> ": "
          <> int.to_string(clock)
          <> " after "
          <> int.to_string(previous),
      )
    False -> Nil
  }
  RuntimeState(
    ..state,
    client_acks: dict.insert(
      state.client_acks,
      conn_id,
      int.max(previous, clock),
    ),
  )
}

fn ack_for(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
) -> Int {
  case dict.get(state.client_acks, conn_id) {
    Ok(clock) -> clock
    // No event from this connection has been processed yet.
    Error(Nil) -> 0
  }
}

/// When an event did not change the client-visible model no patch went
/// out, so acknowledge it explicitly with an empty patch at the current
/// revision.
fn ack_if_unchanged(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  changed: Bool,
) -> RuntimeState(model, msg) {
  case changed {
    True -> Nil
    False ->
      send_to_conn_id(
        state,
        conn_id,
        transport.SendPatch(
          ops_json: "[]",
          version: state.revision,
          ack_clock: ack_for(state, conn_id),
        ),
      )
  }
  state
}

/// Why a client-reported path cannot be routed in place.
type PathProblem {
  /// Not a same-origin path (`/…`, not `//…`): never navigated to.
  NotLocal
  /// A path whose encoding does not decode: the dead render answers 400.
  BadEncoding(reason: String)
  /// A path the app's `parse` does not accept: the dead render answers 404.
  UnknownRoute
}

/// Resolve a client-reported path (`/users/7?tab=posts`) to its route
/// message, against the session's URL.
fn route_for_path(
  route: fn(Uri) -> Result(msg, Nil),
  page_uri: Uri,
  path: String,
) -> Result(msg, PathProblem) {
  use parsed <- result.try(
    case string.starts_with(path, "/") && !string.starts_with(path, "//") {
      False -> Error(NotLocal)
      True ->
        uri.parse(path)
        |> result.replace_error(BadEncoding("the path does not parse as a URL"))
    },
  )
  let target = uri.Uri(..page_uri, path: parsed.path, query: parsed.query)
  use Nil <- result.try(
    uri_check.check(target) |> result.map_error(BadEncoding),
  )
  route(target) |> result.replace_error(UnknownRoute)
}

/// A client navigation (link click, back/forward, or the client's half of
/// `router.push`/`replace`). Like LiveView's `handle_params` on every live
/// patch, `on_change` always runs for a known route.
fn handle_navigation(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  path: String,
) -> RuntimeState(model, msg) {
  let resolved = case state.route {
    None -> Error(NoRouter)
    Some(route) ->
      route_for_path(route, state.page_uri, path)
      |> result.map_error(Unroutable)
  }
  case resolved {
    Ok(msg) -> {
      let state = RuntimeState(..state, current_route_msg: Some(msg))
      let #(state, _changed) =
        run_update_for(state, msg, Some(conn_id), Some(telemetry.Navigate))
      state
    }
    Error(problem) ->
      telemetry.runtime_span(
        telemetry.Navigate,
        transport.page_route,
        unknown_event,
        conn_id,
        fn() { refuse_navigation(state, conn_id, path, problem) },
      )
  }
}

/// Why a client navigation is not run in place.
type NavigationProblem {
  /// The app has no router: every navigation loads the page.
  NoRouter
  Unroutable(PathProblem)
}

/// Answer a navigation that does not run `on_change`: a hard navigation
/// (the dead render answers it), or an error for a non-local path.
fn refuse_navigation(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  path: String,
  problem: NavigationProblem,
) -> RuntimeState(model, msg) {
  case problem {
    NoRouter -> {
      log.warning(
        "brazier.runtime",
        "Navigation to "
          <> path
          <> " from "
          <> conn_id
          <> " but the app has no router; loading the page",
      )
      hard_navigate(state, conn_id, path)
    }
    Unroutable(problem) ->
      case problem {
        NotLocal -> {
          log.warning(
            "brazier.runtime",
            "Navigation from "
              <> conn_id
              <> " to a non-local path refused: "
              <> string.inspect(path),
          )
          send_to_conn_id(
            state,
            conn_id,
            transport.SendError(reason: "navigation path must start with /"),
          )
          state
        }
        BadEncoding(reason) -> {
          log.warning(
            "brazier.runtime",
            "Navigation from "
              <> conn_id
              <> " to "
              <> path
              <> " has an invalid encoding ("
              <> reason
              <> "); loading the page",
          )
          hard_navigate(state, conn_id, path)
        }
        UnknownRoute -> {
          log.info(
            "brazier.runtime",
            "Navigation from "
              <> conn_id
              <> " to unknown route "
              <> path
              <> "; loading the page (the server answers 404)",
          )
          hard_navigate(state, conn_id, path)
        }
      }
  }
}

fn hard_navigate(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  path: String,
) -> RuntimeState(model, msg) {
  send_to_conn_id(state, conn_id, transport.SendHardNavigate(path: path))
  state
}

/// Route a join's path: run `on_change` when its message differs from the
/// last one applied.
fn route_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  path: String,
) -> RuntimeState(model, msg) {
  case state.route {
    None -> state
    Some(route) ->
      case route_for_path(route, state.page_uri, path) {
        Ok(msg) ->
          case state.current_route_msg == Some(msg) {
            True -> {
              log.debug(
                "brazier.runtime",
                "Join route unchanged; on_change not re-run",
              )
              state
            }
            False -> {
              log.debug(
                "brazier.runtime",
                "Join path " <> path <> " changes the route; running on_change",
              )
              let state = RuntimeState(..state, current_route_msg: Some(msg))
              let #(state, _changed) =
                run_update_for(
                  state,
                  msg,
                  Some(conn_id),
                  Some(telemetry.Navigate),
                )
              state
            }
          }
        Error(problem) -> {
          let reason = case problem {
            NotLocal -> "join path must start with /"
            BadEncoding(reason) ->
              "join path has an invalid encoding: " <> reason
            UnknownRoute -> "no route for the joined path " <> path
          }
          log.warning(
            "brazier.runtime",
            "Join from " <> conn_id <> ": " <> reason,
          )
          send_to_conn_id(state, conn_id, transport.SendError(reason: reason))
          state
        }
      }
  }
}

/// Path and query for logs.
fn describe_uri(page_uri: Uri) -> String {
  case page_uri.query {
    Some(query) -> page_uri.path <> "?" <> query
    None -> page_uri.path
  }
}

/// Run the update cycle: update model → broadcast the client-visible change
/// → run effects → reconcile subscriptions. Returns whether a patch or
/// model_sync was broadcast.
///
/// With `span`, the update runs inside that runtime span (a client event or
/// navigation); an effect's message has none.
fn run_update_for(
  state: RuntimeState(model, msg),
  msg: msg,
  conn_id: Option(transport.ConnectionId),
  span: Option(telemetry.RuntimeSpan),
) -> #(RuntimeState(model, msg), Bool) {
  let label = event_label(msg)
  let #(new_model, effects) = case span {
    None -> state.update(state.model, msg)
    Some(kind) ->
      telemetry.runtime_span(
        kind,
        transport.page_route,
        label,
        connection_label(conn_id),
        fn() { state.update(state.model, msg) },
      )
  }
  let #(state, changed) =
    broadcast_model(RuntimeState(..state, model: new_model), label, conn_id)
  let effect_processes =
    run_effects_with_context(effects, state.self, conn_id, state.connections)
  let state = track_effect_processes(state, effect_processes)
  #(reconcile_subscriptions(state), changed)
}

/// After an update (or a join), bring dynamic subscriptions and presence
/// trackings in line with the model.
fn reconcile_subscriptions(
  state: RuntimeState(model, msg),
) -> RuntimeState(model, msg) {
  let state = update_dynamic_subscriptions(state)
  case state.presence {
    None -> state
    Some(watcher) ->
      RuntimeState(
        ..state,
        presence: Some(presence_watch.sync(watcher, state.model)),
      )
  }
}

/// Diff dynamic subscriptions and apply changes.
fn update_dynamic_subscriptions(
  state: RuntimeState(model, msg),
) -> RuntimeState(model, msg) {
  case state.dynamic_subscriptions, state.listener_subject {
    Some(compute_subs), Some(listener) -> {
      let new_subs = compute_subs(state.model)
      // Find topics to subscribe/unsubscribe
      let to_subscribe =
        list.filter(new_subs, fn(t) {
          !list.contains(state.current_subscriptions, t)
        })
      let to_unsubscribe =
        list.filter(state.current_subscriptions, fn(t) {
          !list.contains(new_subs, t)
        })
      // Apply changes
      list.each(to_subscribe, fn(t) { process.send(listener, SubscribeTo(t)) })
      list.each(to_unsubscribe, fn(t) {
        process.send(listener, UnsubscribeFrom(t))
      })
      case list.length(to_subscribe) + list.length(to_unsubscribe) > 0 {
        True ->
          log.info(
            "brazier.subscription",
            "Subscriptions updated: +"
              <> int.to_string(list.length(to_subscribe))
              <> " -"
              <> int.to_string(list.length(to_unsubscribe)),
          )
        False -> Nil
      }
      RuntimeState(..state, current_subscriptions: new_subs)
    }
    _, _ -> state
  }
}

/// Run update WITHOUT broadcasting — for atomic batch processing.
/// Only updates the model and executes effects. The broadcast happens once
/// after the batch.
fn run_update_only(
  state: RuntimeState(model, msg),
  msg: msg,
  conn_id: Option(transport.ConnectionId),
) -> RuntimeState(model, msg) {
  let #(new_model, effects) =
    telemetry.runtime_span(
      telemetry.HandleEvent,
      transport.page_route,
      event_label(msg),
      connection_label(conn_id),
      fn() { state.update(state.model, msg) },
    )
  let effect_processes =
    run_effects_with_context(effects, state.self, conn_id, state.connections)
  track_effect_processes(
    RuntimeState(..state, model: new_model),
    effect_processes,
  )
}

/// The generated server codec (`brazier_codec`, written by
/// `gleam run -m brazier/build`) for the app's Model and Msg.
pub type GeneratedCodec(model, msg) {
  GeneratedCodec(
    encode_model: fn(model) -> String,
    decode_model: fn(String) -> Result(model, String),
    decode_event: fn(String, String, String, String) ->
      Result(msg, error.BrazierError),
  )
}

/// Load the generated codec. Public Brazier apps call this before binding a
/// port, so stale or missing codegen fails at startup instead of at the
/// first WebSocket event.
///
/// The codec is found by module name, so its types are not checked here:
/// the build generates it from the same app's Model and Msg (see
/// `brazier/build`), which is what makes these types right.
pub fn load_generated_codec() -> Result(
  GeneratedCodec(model, msg),
  error.BrazierError,
) {
  log.info("brazier.runtime", "Loading the generated brazier_codec module")
  let missing = fn(name) {
    error.ConfigError(
      reason: "Generated contract missing brazier_codec."
      <> name
      <> " — run `gleam run -m brazier/build`",
    )
  }
  use encode_model <- result.try(
    try_load_codec_encoder() |> result.replace_error(missing("encode_model/1")),
  )
  use decode_model <- result.try(
    try_load_codec_decoder() |> result.replace_error(missing("decode_model/1")),
  )
  use decode_event <- result.try(
    try_load_codec_event_decoder()
    |> result.replace_error(missing("decode_event/4")),
  )
  Ok(
    GeneratedCodec(
      encode_model: encode_model,
      decode_model: decode_model,
      decode_event: fn(name, handler_id, data, target_path) {
        decode_event(name, handler_id, data, target_path)
        |> result.map_error(fn(reason) {
          error.CodecError(reason: reason, raw: data)
        })
      },
    ),
  )
}

@external(erlang, "brazier_runtime_ffi", "try_load_codec_encoder")
fn try_load_codec_encoder() -> Result(fn(model) -> String, Nil)

@external(erlang, "brazier_runtime_ffi", "try_load_codec_decoder")
fn try_load_codec_decoder() -> Result(fn(String) -> Result(model, String), Nil)

@external(erlang, "brazier_runtime_ffi", "try_load_codec_event_decoder")
fn try_load_codec_event_decoder() -> Result(
  fn(String, String, String, String) -> Result(msg, String),
  Nil,
)

@internal
pub type SnapshotDiff {
  /// The client-visible JSON is identical: nothing to send.
  Unchanged
  /// Send these ops as a patch.
  Changed(ops_json: String)
  /// The cache cannot be diffed against: send a full model_sync.
  Resync
}

/// Diff the cached model JSON against the new one. Equal JSON
/// short-circuits without running the diff.
@internal
pub fn diff_snapshot(old: CachedModelState, new_json: String) -> SnapshotDiff {
  case old {
    FullModelCache(old_json) ->
      case old_json == new_json {
        True -> Unchanged
        False -> {
          let ops = patch.diff(old_json, new_json)
          case patch.is_empty(ops) {
            True -> Unchanged
            False -> Changed(ops)
          }
        }
      }
    NoCache -> {
      log.debug(
        "brazier.runtime",
        "No cached model to diff against; full resync",
      )
      Resync
    }
  }
}

/// Model JSON size warning threshold: 1MB.
const model_size_warn_bytes = 1_048_576

/// Model JSON size hard limit: 5MB. Nothing larger is sent.
const model_size_max_bytes = 5_242_880

type ModelSize {
  SizeOk
  TooLarge(size: Int)
}

/// Check model JSON size. Warn at 1MB, reject at 5MB.
fn check_model_size(size: Int, context: String) -> ModelSize {
  case size > model_size_max_bytes, size > model_size_warn_bytes {
    True, _ -> TooLarge(size)
    False, True -> {
      log.warning(
        "brazier.runtime",
        "Model JSON is large ("
          <> int.to_string(size)
          <> " bytes) in "
          <> context
          <> " — consider reducing model size",
      )
      SizeOk
    }
    False, False -> SizeOk
  }
}

/// The model exceeded the hard limit: tell the affected connections, and
/// drop the cache so the next successful broadcast is a full resync.
fn model_too_large(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  size: Int,
  context: String,
) -> RuntimeState(model, msg) {
  log.error(
    "brazier.runtime",
    "Model JSON is "
      <> int.to_string(size)
      <> " bytes in "
      <> context
      <> ", over the "
      <> int.to_string(model_size_max_bytes)
      <> " byte limit — not sent; clients resync once it shrinks",
  )
  list.each(targets, fn(conn_id) {
    send_to_conn_id(
      state,
      conn_id,
      transport.SendError(
        reason: "Model too large: "
        <> int.to_string(size)
        <> " bytes exceeds the "
        <> int.to_string(model_size_max_bytes)
        <> " byte limit",
      ),
    )
  })
  RuntimeState(..state, cached_model: NoCache)
}

/// Broadcast the current model to every joined connection: a patch when
/// the cache can be diffed, a full model_sync otherwise, nothing when the
/// client-visible JSON is unchanged. Returns whether anything was sent.
///
/// With joined connections, the broadcast is a `[brazier, runtime, render]`
/// span for `event` (the message's label, or `"batch"`); with none,
/// nothing is rendered and nothing is emitted.
fn broadcast_model(
  state: RuntimeState(model, msg),
  event: String,
  conn_id: Option(transport.ConnectionId),
) -> #(RuntimeState(model, msg), Bool) {
  let targets = set.to_list(state.joined)
  case targets {
    [] -> {
      log.debug(
        "brazier.runtime",
        "No joined connections; nothing to broadcast",
      )
      #(RuntimeState(..state, cached_model: NoCache), False)
    }
    _ ->
      telemetry.runtime_render_span(
        transport.page_route,
        event,
        connection_label(conn_id),
        fn() {
          let #(state, changed, sent_bytes) = broadcast_to(state, targets)
          #(#(sync_title(state, targets), changed), sent_bytes)
        },
      )
  }
}

/// The largest title, in bytes, sent to a browser. A title is one line of
/// the tab strip; one this large is an app bug, not a title.
pub const title_max_bytes = 4096

/// The title for the current state, checked against `title_max_bytes`.
/// `Ok(None)` when the app has no title.
fn current_title(
  state: RuntimeState(model, msg),
) -> Result(Option(String), Int) {
  case state.title {
    None -> Ok(None)
    Some(title_fn) -> {
      let title = title_fn(state.model)
      let size = string.byte_size(title)
      case size > title_max_bytes {
        True -> Error(size)
        False -> Ok(Some(title))
      }
    }
  }
}

/// Report a title over `title_max_bytes` to `targets`; nothing is sent in
/// its place and the last title sent stays the browsers' title.
fn title_too_large(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  size: Int,
) -> Nil {
  log.error(
    "brazier.runtime",
    "Title is "
      <> int.to_string(size)
      <> " bytes, over the "
      <> int.to_string(title_max_bytes)
      <> " byte limit; not sent to "
      <> int.to_string(list.length(targets))
      <> " connection(s)",
  )
  list.each(targets, fn(conn_id) {
    send_to_conn_id(
      state,
      conn_id,
      transport.SendError(
        reason: "Title too large: "
        <> int.to_string(size)
        <> " bytes exceeds the "
        <> int.to_string(title_max_bytes)
        <> " byte limit",
      ),
    )
  })
}

/// Send the title to a connection that just joined. Always sent: the page
/// may have been rendered long before this (re)join, under another title.
///
/// Reference: LiveView sends `page_title` in a join's rendered diff and,
/// after that, only in diffs where it changed (the `"t"` key; knowledge of
/// `Phoenix.LiveView.Diff`, not code read here).
fn send_title_on_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
) -> RuntimeState(model, msg) {
  case current_title(state) {
    Ok(None) -> state
    Ok(Some(title)) -> {
      log.debug("brazier.runtime", "Sending title to joined " <> conn_id)
      send_to_conn_id(state, conn_id, transport.SendTitle(title: title))
      RuntimeState(..state, last_title: Some(title))
    }
    Error(size) -> {
      title_too_large(state, [conn_id], size)
      state
    }
  }
}

/// After an update, send the title to `targets` (every joined connection)
/// when it differs from the one they were last sent. The title is a
/// function of the server state, so it can change when the client-visible
/// model does not.
fn sync_title(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
) -> RuntimeState(model, msg) {
  case current_title(state) {
    Ok(None) -> state
    Ok(Some(title)) ->
      case state.last_title == Some(title) {
        True -> state
        False -> {
          log.info(
            "brazier.runtime",
            "Title changed; sending it to "
              <> int.to_string(list.length(targets))
              <> " connection(s)",
          )
          list.each(targets, fn(conn_id) {
            send_to_conn_id(state, conn_id, transport.SendTitle(title: title))
          })
          RuntimeState(..state, last_title: Some(title))
        }
      }
    Error(size) -> {
      title_too_large(state, targets, size)
      state
    }
  }
}

/// The broadcast to a non-empty `targets`. The `Int` is the size in bytes
/// of what each connection was sent: the patch ops, the model on a
/// resync, 0 when nothing was sent.
fn broadcast_to(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
) -> #(RuntimeState(model, msg), Bool, Int) {
  let model_json = state.model_encoder(state.model)
  let model_bytes = string.byte_size(model_json)
  let snapshot = FullModelCache(json: model_json)
  case check_model_size(model_bytes, "broadcast") {
    TooLarge(size) -> #(
      model_too_large(state, targets, size, "broadcast"),
      False,
      0,
    )
    SizeOk ->
      case diff_snapshot(state.cached_model, model_json) {
        Unchanged -> {
          log.debug("brazier.runtime", "Model unchanged, skipping broadcast")
          #(RuntimeState(..state, cached_model: snapshot), False, 0)
        }
        Changed(ops_json) -> {
          let revision = state.revision + 1
          let state =
            RuntimeState(..state, revision: revision, cached_model: snapshot)
          log.debug(
            "brazier.runtime",
            "Broadcasting patch revision " <> int.to_string(revision),
          )
          list.each(targets, fn(conn_id) {
            send_to_conn_id(
              state,
              conn_id,
              transport.SendPatch(
                ops_json: ops_json,
                version: revision,
                ack_clock: ack_for(state, conn_id),
              ),
            )
          })
          #(state, True, string.byte_size(ops_json))
        }
        Resync -> {
          log.debug(
            "brazier.runtime",
            "No usable cache; broadcasting full model_sync",
          )
          let state = RuntimeState(..state, revision: state.revision + 1)
          let state = send_model_sync_to(state, targets, "broadcast_resync")
          #(state, True, model_bytes)
        }
      }
  }
}

/// Send the current model as a model_sync (current revision, each
/// connection's own ack) and cache its snapshot.
///
/// Callers must include every joined connection in `targets` when the
/// cache is `NoCache`, since the cache is about to describe all of them.
fn send_model_sync_to(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  context: String,
) -> RuntimeState(model, msg) {
  let model_json = state.model_encoder(state.model)
  case check_model_size(string.byte_size(model_json), context) {
    TooLarge(size) -> model_too_large(state, targets, size, context)
    SizeOk -> {
      list.each(targets, fn(conn_id) {
        send_to_conn_id(
          state,
          conn_id,
          transport.SendModelSync(
            model_json: model_json,
            version: state.revision,
            ack_clock: ack_for(state, conn_id),
          ),
        )
      })
      log.debug(
        "brazier.runtime",
        "Sent model_sync ("
          <> context
          <> ") revision "
          <> int.to_string(state.revision)
          <> " to "
          <> int.to_string(list.length(targets))
          <> " connection(s)",
      )
      RuntimeState(..state, cached_model: FullModelCache(json: model_json))
    }
  }
}

/// Full resync for one connection (or all joined ones when the cache is
/// unusable, since they may be stale too).
fn resync(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  context: String,
) -> RuntimeState(model, msg) {
  let targets = case state.cached_model {
    NoCache -> set.to_list(set.insert(state.joined, conn_id))
    _ -> [conn_id]
  }
  send_model_sync_to(state, targets, context)
}

/// Execute effects by providing a dispatch function that sends messages
/// back to the runtime actor.
fn run_effects(
  effects: Effect(msg),
  self: Subject(RuntimeMessage(msg)),
) -> List(Pid) {
  run_effects_with_context(effects, self, None, dict.new())
}

/// The connections a `router` navigation effect run now should navigate:
/// the connection whose event is being handled, or, for effects run outside
/// a client event (an effect's dispatched message, a notification), every
/// connection of this session, since they all render the same model.
fn navigation_targets(
  conn_id: Option(transport.ConnectionId),
  connections: Dict(transport.ConnectionId, Subject(transport.InternalMessage)),
) -> List(Subject(transport.InternalMessage)) {
  case conn_id {
    Some(cid) ->
      case dict.get(connections, cid) {
        Ok(subject) -> [subject]
        Error(Nil) -> {
          log.warning(
            "brazier.runtime",
            "Connection "
              <> cid
              <> " left before its event's effects ran; navigation effects have no target",
          )
          []
        }
      }
    None -> dict.values(connections)
  }
}

/// Execute effects with connection context for targeted sends (navigation).
fn run_effects_with_context(
  effects: Effect(msg),
  self: Subject(RuntimeMessage(msg)),
  conn_id: Option(transport.ConnectionId),
  connections: Dict(transport.ConnectionId, Subject(transport.InternalMessage)),
) -> List(Pid) {
  case effect.is_none(effects) {
    True -> []
    False -> {
      log.debug("brazier.runtime", "Executing effects")
      store_navigation_targets(navigation_targets(conn_id, connections))
      let dispatch = fn(msg) {
        process.send(self, EffectDispatched(message: msg))
      }
      let dispatch_keyed = fn(key, generation, msg) {
        process.send(
          self,
          EffectDispatchedKeyed(key: key, generation: generation, message: msg),
        )
      }
      effect.perform_tracked(effects, dispatch, dispatch_keyed)
    }
  }
}

fn track_effect_processes(
  state: RuntimeState(model, msg),
  new_processes: List(Pid),
) -> RuntimeState(model, msg) {
  case new_processes {
    [] -> state
    _ -> {
      let live_existing =
        list.filter(state.effect_processes, fn(pid) { process.is_alive(pid) })
      RuntimeState(
        ..state,
        effect_processes: list.append(new_processes, live_existing),
      )
    }
  }
}

fn stop_effect_processes(processes: List(Pid)) -> Nil {
  let live_processes = list.filter(processes, fn(pid) { process.is_alive(pid) })
  case list.length(live_processes) {
    0 -> Nil
    count ->
      log.info(
        "brazier.runtime",
        "Stopping " <> int.to_string(count) <> " effect processes",
      )
  }
  list.each(live_processes, fn(pid) { process.kill(pid) })
}

fn stop_listener(listener: Option(Subject(ListenerCommand))) -> Nil {
  case listener {
    Some(subject) -> process.send(subject, ShutdownListener)
    None -> Nil
  }
}

const max_outbound_mailbox_messages = 1000

/// Send to a registered connection by id (logged when it is unknown).
fn send_to_conn_id(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  message: transport.InternalMessage,
) -> Nil {
  case dict.get(state.connections, conn_id) {
    Ok(subject) -> send_to_connection(conn_id, subject, message)
    Error(Nil) ->
      log.warning(
        "brazier.runtime",
        "Cannot send to unregistered connection " <> conn_id,
      )
  }
}

fn send_to_connection(
  conn_id: transport.ConnectionId,
  subject: Subject(transport.InternalMessage),
  message: transport.InternalMessage,
) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) -> {
      let queue_len = process_message_queue_len(pid)
      case queue_len > max_outbound_mailbox_messages {
        True -> {
          log.warning(
            "brazier.runtime",
            "Connection "
              <> conn_id
              <> " outbound mailbox exceeded "
              <> int.to_string(max_outbound_mailbox_messages)
              <> " messages ("
              <> int.to_string(queue_len)
              <> "); closing slow client",
          )
          process.send(
            subject,
            transport.CloseForBackpressure(
              reason: "Connection is too far behind; reconnect to resync",
            ),
          )
        }
        False -> process.send(subject, message)
      }
    }
    Error(Nil) -> {
      log.warning(
        "brazier.runtime",
        "Cannot send to connection " <> conn_id <> ": subject has no owner",
      )
      Nil
    }
  }
}

@external(erlang, "brazier_runtime_ffi", "message_queue_len")
fn process_message_queue_len(pid: Pid) -> Int

/// The telemetry `event` of an app message: its constructor name in
/// snake_case (the atom the BEAM uses for it), or
/// `"unknown"` for a message type without constructors (a String or Int).
@external(erlang, "brazier_runtime_ffi", "event_label")
fn event_label(msg: msg) -> String

/// The telemetry `event` of an event or path the app does not handle.
const unknown_event = "unknown"

fn connection_label(conn_id: Option(transport.ConnectionId)) -> String {
  option.unwrap(conn_id, no_connection)
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time() -> Int

/// Create a TransportConfig that wires transport events to a runtime.
/// This is the glue between the transport and runtime layers.
pub fn connect_transport(
  runtime: Subject(RuntimeMessage(msg)),
  port: Int,
) -> transport.TransportConfig {
  log.info(
    "brazier.runtime",
    "Connecting transport on port " <> int.to_string(port),
  )
  connect_transport_with_ssr(runtime, port, None)
}

/// Create a TransportConfig with SSR-rendered HTML.
pub fn connect_transport_with_ssr(
  runtime: Subject(RuntimeMessage(msg)),
  port: Int,
  page_html: Option(ssr.RenderedPage),
) -> transport.TransportConfig {
  log.info(
    "brazier.runtime",
    "Connecting transport on port " <> int.to_string(port),
  )
  transport.TransportConfig(
    port: port,
    page_html: page_html,
    middlewares: [],
    static_config: None,
    runtime_factory: None,
    on_connect: fn(conn_id, subject) {
      process.send(runtime, ClientConnected(conn_id: conn_id, subject: subject))
    },
    on_event: fn(conn_id, client_msg) {
      forward_client_message(runtime, conn_id, False, client_msg)
    },
    on_disconnect: fn(conn_id) {
      process.send(runtime, ClientDisconnected(conn_id: conn_id))
    },
    ws_auth: None,
    ssr_factory: None,
    security_limits: transport.default_security_limits(),
    api_handler: None,
  )
}

/// Start a runtime for a specific connection and return type-erased handler closures.
/// This is the core helper used by app startup and test harnesses.
/// Each call spawns a new runtime actor, registers the connection, and returns:
/// - on_event: forwards ClientMessages to the runtime
/// - shutdown: kills the runtime process
///
/// Types are erased at the function boundary — the returned closures work
/// with untyped ConnectionId + ClientMessage regardless of Model/Msg types.
pub fn start_and_connect(
  config: RuntimeConfig(model, msg),
  ctx: Context,
  conn_id: transport.ConnectionId,
  transport_subject: process.Subject(transport.InternalMessage),
) -> Result(
  #(fn(transport.ConnectionId, transport.ClientMessage) -> Nil, fn() -> Nil),
  error.BrazierError,
) {
  log.info("brazier.runtime", "Starting runtime connection for " <> conn_id)
  spawn_and_connect(config, ctx, conn_id, transport_subject, False, None)
}

/// Start a per-connection runtime for a WebSocket upgrade request. The
/// client connects to `/ws?path=<page path and query>`; the Context's URL
/// is the upgrade request's URL with that page path and query, so `init`
/// sees the same URL as the dead render. A missing or invalid `path`
/// refuses the connection.
///
/// The join token is read from the request's HttpOnly cookie and checked
/// before `init` runs (see `check_join_token`). A token that fails the
/// check refuses the connection with
/// `error.InitRejected(error.refuse(join_token_refused_status, _))`, so
/// the socket closes with 4400 and the browser reloads the page for a
/// fresh token. A model recovered from the token replaces the state `init`
/// built before the runtime starts.
pub fn start_and_connect_with_request(
  config: RuntimeConfig(model, msg),
  conn_id: transport.ConnectionId,
  transport_subject: process.Subject(transport.InternalMessage),
  req: request.Request(server.Connection),
) -> Result(
  #(fn(transport.ConnectionId, transport.ClientMessage) -> Nil, fn() -> Nil),
  error.BrazierError,
) {
  case connected_context(req) {
    Error(reason) -> {
      log.warning(
        "brazier.runtime",
        "Refusing connection " <> conn_id <> ": " <> reason,
      )
      Error(error.RuntimeError(reason: reason))
    }
    Ok(ctx) -> {
      use Nil <- result.try(check_recovery_config(config))
      case
        check_join_token(
          config.restore_model,
          option.is_some(config.restore_model),
          config.secret_key,
          join_token_cookie(req),
          ssr.session_fingerprint(req),
          conn_id,
        )
      {
        Error(reason) -> {
          log.warning(
            "brazier.runtime",
            "Refusing connection "
              <> conn_id
              <> " for "
              <> describe_uri(context.uri(ctx))
              <> ": "
              <> reason
              <> " (close "
              <> int.to_string(
              error.init_close_code_base + join_token_refused_status,
            )
              <> ": the browser reloads the page for a fresh token)",
          )
          Error(
            error.InitRejected(error.refuse(
              join_token_refused_status,
              "join token refused: " <> reason,
            )),
          )
        }
        Ok(recovered) ->
          spawn_and_connect(
            config,
            ctx,
            conn_id,
            transport_subject,
            True,
            recovered,
          )
      }
    }
  }
}

/// The Context for a connected mount, from the upgrade request.
@internal
pub fn connected_context(
  req: request.Request(server.Connection),
) -> Result(Context, String) {
  log.debug(
    "brazier.runtime",
    "Building connected context from upgrade request " <> req.path,
  )
  use pairs <- result.try(
    request.get_query(req)
    |> result.replace_error("the WebSocket URL's query string does not parse"),
  )
  use page_path <- result.try(
    list.key_find(pairs, "path")
    |> result.replace_error(
      "the WebSocket URL has no path parameter (expected /ws?path=<page path>)",
    ),
  )
  use parsed <- result.try(
    case
      string.starts_with(page_path, "/") && !string.starts_with(page_path, "//")
    {
      False ->
        Error(
          "the WebSocket path parameter is not a local path: "
          <> string.inspect(page_path),
        )
      True ->
        uri.parse(page_path)
        |> result.replace_error(
          "the WebSocket path parameter does not parse: "
          <> string.inspect(page_path),
        )
    },
  )
  let page_uri =
    uri.Uri(..request.to_uri(req), path: parsed.path, query: parsed.query)
  Ok(context.new(
    uri: page_uri,
    cookies: cookie.parse(req),
    is_connected: True,
    session_id: ssr.session_id_for_request(req),
  ))
}

fn spawn_and_connect(
  config: RuntimeConfig(model, msg),
  ctx: Context,
  conn_id: transport.ConnectionId,
  transport_subject: process.Subject(transport.InternalMessage),
  token_checked: Bool,
  recovered: Option(model),
) -> Result(
  #(fn(transport.ConnectionId, transport.ClientMessage) -> Nil, fn() -> Nil),
  error.BrazierError,
) {
  log.info("brazier.runtime", "Spawning runtime for " <> conn_id)
  case start_for(config, ctx, conn_id, recovered) {
    Ok(runtime_subject) -> {
      // Register this connection with the new runtime
      process.send(
        runtime_subject,
        ClientConnected(conn_id: conn_id, subject: transport_subject),
      )
      // Return per-connection event and shutdown handlers
      let on_event = fn(_cid: transport.ConnectionId, client_msg) {
        forward_client_message(
          runtime_subject,
          conn_id,
          token_checked,
          client_msg,
        )
      }
      let shutdown = fn() {
        log.info("brazier.runtime", "Shutting down runtime for " <> conn_id)
        process.send(runtime_subject, Shutdown)
      }
      Ok(#(on_event, shutdown))
    }
    // The start logged the cause once, where it was known (see
    // start_actor), at the level it calls for.
    Error(err) -> {
      log.debug(
        "brazier.runtime",
        "No runtime for " <> conn_id <> ": " <> error.to_string(err),
      )
      Error(err)
    }
  }
}

/// Forward a client message to a runtime actor.
/// Translates transport.ClientMessage variants into RuntimeMessage variants.
/// With `token_checked`, the connection's join token came from the upgrade
/// request's HttpOnly cookie and was checked before its runtime started,
/// so a join carries no token (the token in the client's join message is
/// ignored: the browser client sends an empty one).
fn forward_client_message(
  runtime_subject: Subject(RuntimeMessage(msg)),
  conn_id: transport.ConnectionId,
  token_checked: Bool,
  client_msg: transport.ClientMessage,
) -> Nil {
  case client_msg {
    transport.ClientEvent(name, handler_id, data, target_path, clock, ops) ->
      process.send(
        runtime_subject,
        ClientEventReceived(
          conn_id: conn_id,
          event_name: name,
          handler_id: handler_id,
          event_data: data,
          target_path: target_path,
          clock: clock,
          ops: ops,
        ),
      )
    transport.ClientJoin(token, path) ->
      case token_checked {
        True ->
          process.send(
            runtime_subject,
            ClientJoinedVerified(conn_id: conn_id, path: path),
          )
        False ->
          process.send(
            runtime_subject,
            ClientJoined(conn_id: conn_id, token: token, path: path),
          )
      }
    transport.ClientNavigate(path) ->
      process.send(
        runtime_subject,
        ClientNavigated(conn_id: conn_id, path: path),
      )
    transport.ClientRequestSync ->
      process.send(runtime_subject, ClientSyncRequested(conn_id: conn_id))
    transport.ClientEventBatch(events) -> {
      let #(event_tuples, nested) =
        list.fold(list.reverse(events), #([], 0), fn(acc, evt) {
          let #(tuples, nested) = acc
          case evt {
            transport.ClientEvent(
              name,
              handler_id,
              data,
              target_path,
              clock,
              ops,
            ) -> #(
              [#(name, handler_id, data, target_path, clock, ops), ..tuples],
              nested,
            )
            _ -> #(tuples, nested + 1)
          }
        })
      case nested {
        0 -> Nil
        n ->
          log.warning(
            "brazier.runtime",
            "Dropped "
              <> int.to_string(n)
              <> " non-event message(s) inside an event batch from "
              <> conn_id,
          )
      }
      process.send(
        runtime_subject,
        ClientEventBatchReceived(conn_id: conn_id, events: event_tuples),
      )
    }
    transport.ClientHeartbeat -> Nil
  }
}

fn join_token_cookie(req: request.Request(server.Connection)) -> String {
  case cookie.get(req, ssr.session_cookie_name) {
    Ok(token) -> token
    Error(Nil) -> ""
  }
}

/// Create a TransportConfig that spawns a NEW runtime per WebSocket connection.
/// Each connection gets its own Model, its own MVU loop, its own BEAM process.
/// This is the LiveView-style architecture for multi-user apps.
pub fn connect_transport_per_connection(
  config: RuntimeConfig(model, msg),
  port: Int,
  page_html: Option(ssr.RenderedPage),
) -> transport.TransportConfig {
  log.info(
    "brazier.runtime",
    "Connecting transport (per-connection mode) on port " <> int.to_string(port),
  )
  transport.TransportConfig(
    port: port,
    page_html: page_html,
    middlewares: [],
    static_config: None,
    runtime_factory: Some(
      fn(
        conn_id: transport.ConnectionId,
        transport_subject: process.Subject(transport.InternalMessage),
        req: request.Request(server.Connection),
      ) {
        case
          start_and_connect_with_request(
            config,
            conn_id,
            transport_subject,
            req,
          )
        {
          Ok(#(on_event, shutdown)) -> {
            let on_disconnect = fn(_cid: transport.ConnectionId) { shutdown() }
            Ok(#(on_event, on_disconnect))
          }
          // Logged where it happened; the transport logs the close.
          Error(error.InitRejected(init_error)) ->
            Error(transport.InitRefused(init_error))
          Error(err) -> Error(transport.StartupFailed(error.to_string(err)))
        }
      },
    ),
    // These are unused when runtime_factory is set, but needed for the type
    on_connect: fn(_, _) { Nil },
    on_event: fn(_, _) { Nil },
    on_disconnect: fn(_) { Nil },
    ws_auth: None,
    ssr_factory: None,
    security_limits: transport.default_security_limits(),
    api_handler: None,
  )
}

/// Commands sent to the PubSub listener process.
pub type ListenerCommand {
  /// Subscribe to a new PubSub topic.
  SubscribeTo(topic: String)
  /// Unsubscribe from a PubSub topic.
  UnsubscribeFrom(topic: String)
  /// Shut down the listener process.
  ShutdownListener
}

/// Result from the listener's receive FFI.
type ListenerReceiveResult {
  /// A command was received from the runtime.
  CommandReceived(command: ListenerCommand)
  /// A PubSub notification was received on a topic.
  NotificationReceived(topic: String, payload: Dynamic)
  /// The owning runtime exited (DOWN from the listener's monitor).
  OwnerExited(reason: String)
  /// Timeout — no message within the window.
  ReceiveTimeout
}

/// Immutable context of a PubSub listener process.
type Listener(msg) {
  Listener(
    runtime_subject: Subject(RuntimeMessage(msg)),
    command_subject: Subject(ListenerCommand),
    /// Monitor on the owning runtime — the listener exits when it fires.
    owner_monitor: process.Monitor,
    on_notify: Option(fn(String) -> msg),
    on_notification: Option(fn(Notification) -> msg),
  )
}

/// Start the PubSub listener — spawns a process that handles
/// dynamic subscription commands and forwards notifications.
/// Returns a Subject for sending commands to the listener.
///
/// Lifecycle: the listener is bound to the RUNTIME, not to the caller. It
/// links to the runtime (so a crashing listener crashes the runtime loudly
/// instead of silently dropping notifications, and an abnormal runtime exit
/// kills the listener) and monitors it (so a normal runtime exit, which a
/// link does not propagate, also stops the listener and unsubscribes).
fn start_pubsub_listener(
  runtime_subject: Subject(RuntimeMessage(msg)),
  runtime_pid: Pid,
  on_notify: Option(fn(String) -> msg),
  on_notification: Option(fn(Notification) -> msg),
  topics: List(String),
) -> Subject(ListenerCommand) {
  // Use a subject on the CALLER to receive the listener's command subject
  let reply_subject = process.new_subject()
  // The listener sends its command subject back on `reply_subject`; its Pid
  // is not needed.
  process.spawn_unlinked(fn() {
    // Monitor before linking: if the runtime is already gone the monitor
    // delivers DOWN (noproc) and the loop exits on its first receive.
    let owner_monitor = process.monitor(runtime_pid)
    case process.link(runtime_pid) {
      True -> Nil
      // The runtime already exited; the monitor above delivers DOWN and
      // the loop stops on its first receive.
      False ->
        log.debug(
          "brazier.runtime",
          "PubSub listener: runtime already exited before link",
        )
    }
    // Create the command subject HERE — inside the spawned process —
    // so it's owned by this process and receives messages correctly.
    let command_subject = process.new_subject()

    log.info("brazier.subscription", "Listener process spawned")
    // Subscribe to the initial topics BEFORE replying, so that once
    // `start` returns no broadcast to an initial topic can be missed.
    let topics = list.unique(topics)
    subscribe_initial(topics, 0)
    process.send(reply_subject, command_subject)
    log.info(
      "brazier.subscription",
      "Listener started with "
        <> int.to_string(list.length(topics))
        <> " initial topics",
    )
    listener_loop(
      Listener(
        runtime_subject: runtime_subject,
        command_subject: command_subject,
        owner_monitor: owner_monitor,
        on_notify: on_notify,
        on_notification: on_notification,
      ),
      topics,
    )
  })
  // INVARIANT: The listener process was just spawned and MUST send its
  // command_subject back immediately. If this times out (5s), the listener
  // failed to start — a fatal configuration error. Crash is intentional:
  // the runtime cannot function without its PubSub listener.
  let assert Ok(command_subject) = process.receive(reply_subject, 5000)
  command_subject
}

/// Listener receive loop — handles commands and PubSub notifications.
fn listener_loop(listener: Listener(msg), subscriptions: List(String)) -> Nil {
  case
    receive_with_commands(
      listener.command_subject,
      listener.owner_monitor,
      60_000,
    )
  {
    CommandReceived(SubscribeTo(topic)) ->
      // pg allows a process to join a group more than once (and then
      // delivers every broadcast once per membership), so joining is
      // guarded by the listener's own subscription set.
      case list.contains(subscriptions, topic) {
        True -> {
          log.debug("brazier.subscription", "Already subscribed to: " <> topic)
          listener_loop(listener, subscriptions)
        }
        False -> {
          pubsub.subscribe(topic)
          log.debug("brazier.subscription", "Subscribed to: " <> topic)
          let subscriptions = [topic, ..subscriptions]
          telemetry.subscription_changed(
            telemetry.Subscribe,
            list.length(subscriptions),
          )
          listener_loop(listener, subscriptions)
        }
      }
    CommandReceived(UnsubscribeFrom(topic)) ->
      case list.contains(subscriptions, topic) {
        True -> {
          pubsub.unsubscribe(topic)
          log.debug("brazier.subscription", "Unsubscribed from: " <> topic)
          let subscriptions =
            list.filter(subscriptions, fn(existing) { existing != topic })
          telemetry.subscription_changed(
            telemetry.Unsubscribe,
            list.length(subscriptions),
          )
          listener_loop(listener, subscriptions)
        }
        False -> {
          log.debug(
            "brazier.subscription",
            "Ignoring unsubscribe from non-subscribed topic: " <> topic,
          )
          listener_loop(listener, subscriptions)
        }
      }
    CommandReceived(ShutdownListener) -> {
      log.info("brazier.subscription", "Listener shutting down")
      unsubscribe_all(subscriptions)
    }
    OwnerExited(reason) -> {
      log.info(
        "brazier.subscription",
        "Owning runtime exited (" <> reason <> "); listener stopping",
      )
      unsubscribe_all(subscriptions)
    }
    NotificationReceived(topic, payload) -> {
      case listener.on_notify {
        Some(handler) ->
          process.send(
            listener.runtime_subject,
            EffectDispatched(message: handler(topic)),
          )
        None -> Nil
      }
      case listener.on_notification {
        Some(handler) ->
          process.send(
            listener.runtime_subject,
            EffectDispatched(
              message: handler(Notification(topic: topic, payload: payload)),
            ),
          )
        None -> Nil
      }
      listener_loop(listener, subscriptions)
    }
    ReceiveTimeout -> listener_loop(listener, subscriptions)
  }
}

/// Join the listener's initial topics, counting the subscriptions made.
fn subscribe_initial(topics: List(String), subscribed: Int) -> Nil {
  case topics {
    [] -> Nil
    [topic, ..rest] -> {
      log.info("brazier.subscription", "Subscribing to: " <> topic)
      pubsub.subscribe(topic)
      telemetry.subscription_changed(telemetry.Subscribe, subscribed + 1)
      subscribe_initial(rest, subscribed + 1)
    }
  }
}

fn unsubscribe_all(subscriptions: List(String)) -> Nil {
  case subscriptions {
    [] -> Nil
    [topic, ..rest] -> {
      log.debug("brazier.subscription", "Unsubscribing on shutdown: " <> topic)
      pubsub.unsubscribe(topic)
      telemetry.subscription_changed(telemetry.Unsubscribe, list.length(rest))
      unsubscribe_all(rest)
    }
  }
}

@external(erlang, "brazier_subscription_ffi", "receive_with_commands")
fn receive_with_commands(
  subject: Subject(ListenerCommand),
  owner_monitor: process.Monitor,
  timeout: Int,
) -> ListenerReceiveResult

/// Record, in the runtime's process dictionary, the connections that
/// `router` navigation effects run from this process should navigate.
@external(erlang, "brazier_runtime_ffi", "store_navigation_targets")
fn store_navigation_targets(
  subjects: List(process.Subject(transport.InternalMessage)),
) -> Nil

/// Create a signed join token carrying the serialized model, not bound to
/// any browser session. Prefer `ssr.join_token_for` for request-bound pages.
pub fn create_state_token(
  model: model,
  serialize: fn(model) -> String,
  secret_key: String,
) -> String {
  ssr.sign_join_token(
    secret_key,
    "",
    Some(serialize(model)),
    system_time_seconds(),
  )
}

@external(erlang, "brazier_ssr_ffi", "system_time_seconds")
fn system_time_seconds() -> Int
