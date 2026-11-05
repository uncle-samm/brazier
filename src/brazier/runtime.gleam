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
/// ## Streams (LiveView `stream/4`, docs/design/STREAMS.md 7)
///
/// The stream ops an update's effects carry (`effect.take_stream_ops`) are
/// applied to the session's windows (`brazier/internal/stream_session`)
/// and sent in the `streams` array of that update's frame: on its patch
/// when the model changed, otherwise on an empty patch at the current
/// revision to every joined connection, which also acknowledges each one's
/// events. A batch sends the ops of all its events, in order, in its one
/// broadcast. Every patch and model_sync carries `streams`, `[]` when there
/// is nothing.
///
/// Ops applied before the first join (`init`, the initial route, messages
/// dispatched before it) are kept and sent to the first joiner as resets
/// in its model_sync. Each connection has windows of its own, of the keys
/// its client was sent: a later connection, and a rejoin, are sent no
/// items (no replay), and each entry is relative to the receiving
/// connection's window. A refused op (an undeclared stream, a limit, key or
/// item over `SecurityLimits`) is logged at error, counted by
/// `[brazier, stream, refused]` and sent to every joined connection as an
/// `error` frame; the rest of the update is sent.
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
/// runtime, render]`, which measures the patch's `patch_bytes` and the
/// largest `streams` array it sent as `stream_bytes`; every stream entry
/// sent emits `[brazier, stream, delta]`. `event` is the message's constructor name in
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
import brazier/internal/local_path
import brazier/internal/log_path
import brazier/internal/presence_watch
import brazier/internal/stream_op
import brazier/internal/stream_session
import brazier/internal/stream_window
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
  /// The full client-visible model JSON with its decoded form, so the next
  /// diff decodes only the new model (PERF-2). Costs the decoded term on the
  /// runtime heap, roughly the size of the JSON again.
  FullModelCache(snapshot: patch.Snapshot)
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
    /// Model ops the client attached, already checked by the transport.
    /// `[]` means none. They are never applied (see `warn_client_ops`).
    ops: List(transport.ClientOp),
  )
  /// A batch of events to process atomically (all updates, one render).
  /// Used when LOCAL events are replayed before a MODEL event.
  ClientEventBatchReceived(
    conn_id: transport.ConnectionId,
    events: List(
      #(String, String, String, String, Int, List(transport.ClientOp)),
    ),
  )
  /// A client navigated to a new URL path.
  /// `clock` is the navigation's event clock: the frame with its state, or
  /// an ack when the model did not change, acknowledges it.
  ClientNavigated(conn_id: transport.ConnectionId, path: String, clock: Int)
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
  /// An `effect.after` timer the runtime armed in its own mailbox fired.
  /// Delivered by the VM's `erlang:send_after`; nothing sends it.
  EffectTimerFired(timer: effect.AfterTimer)
  /// Shutdown the runtime.
  Shutdown
  /// An exit signal the runtime trapped: a linked process (the connection
  /// handler that started it, its PubSub listener or presence watcher, a
  /// process the app linked) exited, or a process sent the runtime an
  /// exit. Delivered by the VM; nothing sends it.
  ExitTrapped(exit: process.ExitMessage)
  /// A process the runtime monitors went down: the owner of a registered
  /// connection's subject (its transport handler). The runtime monitors
  /// each connection's owner when it registers, as `Phoenix.Channel.Server`
  /// monitors its transport pid, so a handler that exits without sending
  /// `ClientDisconnected` is still forgotten. Delivered by the VM; nothing
  /// sends it.
  ConnectionOwnerDown(down: process.Down)
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
    /// The monitor on each registered connection's subject owner. Same
    /// keys as `connections`: both are set together on `ClientConnected`
    /// and removed together by `forget_connection`.
    owner_monitors: Dict(transport.ConnectionId, process.Monitor),
    /// Connections that completed a join. Only these receive patches and
    /// may send events. Always a subset of `connections`.
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
    /// Rebuild the server state from join-token model JSON and the state
    /// `init` built (state recovery).
    restore_model: Option(fn(String, model) -> Result(model, String)),
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
    /// The session's presence watcher, when the app has presence.
    presence: Option(presence_watch.Watcher(model)),
    /// Native monotonic time the runtime started, for its uptime.
    started_at: Int,
    /// The document title for the server state, when the app has one.
    title: Option(fn(model) -> String),
    /// What the joined connections were last told about the title.
    title_sync: TitleSync,
    /// The stream windows of the session and of each joined connection.
    streams: stream_session.Streams,
    /// The stream refusals made before the runtime's first join, which no
    /// connection was joined to be sent; the first join is sent them.
    held_stream_errors: HeldStreamErrors,
    /// The later join (or rejoin) whose route `accept_join` is applying.
    live_join: Option(LiveJoin),
  )
}

/// Stream refusals made while no connection had joined the runtime yet
/// (`init`, the initial route, messages before the first join, the first
/// join's own route). Each was logged at error when it was refused; the
/// runtime's first join is sent them as `error` frames before its
/// model_sync (docs/design/STREAMS.md 7.4, 12). At most
/// `held_stream_errors_max` reasons are kept; the rest are counted and the
/// first join is told how many.
pub type HeldStreamErrors {
  HeldStreamErrors(
    /// The kept reasons, newest first.
    reasons: List(String),
    /// The number of reasons not kept, past the bound.
    dropped: Int,
  )
}

/// The most stream refusal reasons held for the first join.
pub const held_stream_errors_max = 32

/// A join after the runtime's first one (or a rejoin) while its route is
/// applied. The joiner has its stream windows but is not joined yet: the
/// route's update applies its stream ops to those windows, and the entries
/// and refusals it makes for the joiner wait for its join model_sync.
pub type LiveJoin {
  LiveJoin(
    conn_id: transport.ConnectionId,
    /// The `streams` array of the join model_sync.
    frame: String,
    /// The reasons of the `error` frames to send the joiner before its
    /// join model_sync.
    errors: List(String),
  )
}

/// What the joined connections were last told about the title. A title
/// over `title_max_bytes` is reported once when it goes over the limit,
/// not after every update while it stays over; it is reported again only
/// after it has been back under the limit.
pub type TitleSync {
  /// The title is within the limit. `last_sent` is the title the joined
  /// connections were last sent: `None` until the first join (the server
  /// render carried the title until then), and after a connection joined
  /// while the title was over the limit (it has the server render's title,
  /// so the next title within the limit goes to everyone).
  TitleWithinLimit(last_sent: Option(String))
  /// The title is over the limit and has been reported to the joined
  /// connections; they still show `last_sent`.
  TitleOverLimit(last_sent: Option(String))
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
    /// by a join token and the fresh state `init` (and the initial route)
    /// built for this connection, as LiveView re-runs `mount` on a
    /// reconnect. Set only when the app opted into state recovery.
    restore_model: Option(fn(String, state) -> Result(state, String)),
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
    /// The streams the build declared and the bounds their ops are held to.
    streams: StreamConfig,
  )
}

/// The streams a runtime accepts ops for (docs/design/STREAMS.md 7.4 and
/// 7.5). An op on any other name is refused with `unknown_stream`.
pub type StreamConfig {
  StreamConfig(
    /// The declared names: the generated `brazier_codec.stream_names()`.
    names: List(String),
    /// The bounds: `transport.stream_limits` of the app's `SecurityLimits`.
    limits: stream_window.Limits,
  )
}

/// The `StreamConfig` of an app that declares no stream: every stream op
/// is refused, under the default bounds.
pub fn no_streams() -> StreamConfig {
  log.debug(
    "brazier.runtime",
    "Stream config: no declared stream, every stream op is refused",
  )
  StreamConfig(names: [], limits: stream_window.default_limits())
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
    "Starting a runtime outside the transport for "
      <> describe_uri(context.uri(ctx)),
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
  recovered: Option(Recovery(model)),
) -> Result(Subject(RuntimeMessage(msg)), error.BrazierError) {
  let page_uri = context.uri(ctx)
  use Nil <- result.try(check_recovery_config(config))
  case uri_check.check(page_uri) {
    Error(reason) -> {
      log.error(
        "brazier.runtime",
        "Refusing to start a runtime for "
          <> describe_uri(page_uri)
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
/// `stream_ops` holds the stream ops taken out of `init`'s effects and of
/// the route message's, one update each, as the dead render applies them
/// (`brazier/internal/stream_ssr`); `effects` holds the rest.
type Mounted(model, msg) {
  Mounted(
    model: model,
    effects: Effect(msg),
    route_msg: Option(msg),
    stream_ops: List(#(String, List(stream_op.Op))),
  )
}

/// A runtime that does not start is logged once, here, where the cause is
/// known: by `mount`, `refuse_join_token`, `start_presence` or
/// `spawn_actor`, with the page and connection. The callers up to the
/// transport only pass the error on (the transport logs the close it
/// answers with at info).
fn start_actor(
  config: RuntimeConfig(model, msg),
  ctx: Context,
  page_uri: Uri,
  connection_id: String,
  recovered: Option(Recovery(model)),
) -> Result(Subject(RuntimeMessage(msg)), error.BrazierError) {
  let started_at = monotonic_time()
  use mounted <- result.try(mount(config, ctx, page_uri, connection_id))
  // `init` and the initial route run first, as LiveView re-runs `mount` on
  // a reconnect: their effects and route message stand, and `restore` gets
  // the recovered model with the fresh state they built (SEC-17), before
  // presence, subscriptions and effect messages first see the state.
  use mounted <- result.try(case recovered {
    None -> Ok(mounted)
    Some(recovery) ->
      restore_mounted(recovery, mounted, page_uri, connection_id)
  })
  spawn_actor(config, mounted, page_uri, started_at, connection_id)
}

/// Put the recovered model in place of the mounted one. `restore` is app
/// code running in the connection's handler, so a crash in it is caught
/// and closes the socket with 1011, as a crash in `init` does; a model it
/// refuses closes with 4400 so the browser reloads for a fresh token.
fn restore_mounted(
  recovery: Recovery(model),
  mounted: Mounted(model, msg),
  page_uri: Uri,
  connection_id: String,
) -> Result(Mounted(model, msg), error.BrazierError) {
  let restored =
    run_guarded(fn() {
      restore_recovered(recovery, mounted.model, connection_id)
    })
  case restored {
    Ok(Ok(model)) -> Ok(Mounted(..mounted, model: model))
    Ok(Error(reason)) ->
      Error(refuse_join_token(connection_id, page_uri, reason))
    Error(#(crash, stacktrace)) -> {
      log.error(
        "brazier.runtime",
        "restore crashed for "
          <> describe_uri(page_uri)
          <> " (connection "
          <> connection_id
          <> "): "
          <> crash
          <> "\n"
          <> stacktrace,
      )
      Error(error.RuntimeError(reason: "restore crashed: " <> crash))
    }
  }
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
  let #(init_ops, init_effects) = effect.take_stream_ops(init_effects)
  let init_only =
    Mounted(
      model: initial_model,
      effects: init_effects,
      route_msg: None,
      stream_ops: [#("init", init_ops)],
    )
  case config.route {
    None -> init_only
    Some(route) ->
      case route(page_uri) {
        Ok(msg) -> {
          log.debug(
            "brazier.runtime",
            "Applying the initial route for " <> describe_uri(page_uri),
          )
          let #(routed, route_effects) = config.update(initial_model, msg)
          let #(route_ops, route_effects) =
            effect.take_stream_ops(route_effects)
          Mounted(
            model: routed,
            effects: effect.batch([init_effects, route_effects]),
            route_msg: Some(msg),
            stream_ops: [#("init", init_ops), #(event_label(msg), route_ops)],
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
          init_only
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
    stream_ops: initial_stream_ops,
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
      // No connection has joined: the ops of `init` and the initial route
      // fill the session's windows, which keep their items until the first
      // join (docs/design/STREAMS.md 7.2). Their refusals are held for it.
      let #(streams, held_stream_errors) =
        list.fold(
          initial_stream_ops,
          #(
            stream_session.new(config.streams.names, config.streams.limits),
            no_held_stream_errors,
          ),
          fn(acc, update) {
            let #(streams, held) = acc
            let #(cause, ops) = update
            let applied = stream_session.apply(streams, ops, [], cause)
            #(applied.streams, hold_stream_errors(held, applied.errors, cause))
          },
        )
      run_effects(initial_effects, subject)
      let state =
        RuntimeState(
          model: initial_model,
          update: config.update,
          decode_event: config.decode_event,
          connections: dict.new(),
          owner_monitors: dict.new(),
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
          presence: watcher,
          started_at: started_at,
          title: config.title,
          title_sync: TitleWithinLimit(last_sent: None),
          streams: streams,
          held_stream_errors: held_stream_errors,
          live_join: None,
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
        // Every DOWN: the runtime's own monitors are the connection owner
        // monitors; a process.call made in the runtime receives its own
        // DOWN in its selective receive before the actor loop sees it.
        |> process.select_monitors(ConnectionOwnerDown)
        |> effect.select_after_timers(EffectTimerFired)

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
    ClientConnected(conn_id, subject) ->
      actor.continue(register_connection(state, conn_id, subject))

    ClientDisconnected(conn_id) ->
      case dict.has_key(state.connections, conn_id) {
        True -> {
          log.info("brazier.runtime", "Client disconnected: " <> conn_id)
          actor.continue(forget_connection(state, conn_id))
        }
        // The runtime forgot it first: it was closed for backpressure, its
        // handler was found gone by a send, or its owner's DOWN came first.
        False -> {
          log.debug(
            "brazier.runtime",
            "Client disconnected: " <> conn_id <> " (already forgotten)",
          )
          actor.continue(state)
        }
      }

    ConnectionOwnerDown(down) -> actor.continue(handle_owner_down(state, down))

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
          let state = record_ack(state, conn_id, clock, EventClock)
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
                  let state =
                    send_to_conn_id(
                      state,
                      conn_id,
                      transport.SendError(err_str),
                    )
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

    ClientNavigated(conn_id, path, clock) ->
      case set.contains(state.joined, conn_id) {
        False ->
          actor.continue(reject_before_join(state, conn_id, "navigation"))
        True -> {
          log.info(
            "brazier.runtime",
            "Navigation: " <> conn_id <> " → " <> log_path(path),
          )
          // Acknowledged like an event (LiveView answers a live_patch with
          // a reply), so the client can tell the render of the new page
          // from a broadcast that arrives before it.
          let state = record_ack(state, conn_id, clock, NavigationClock)
          let #(state, answered) = handle_navigation(state, conn_id, path)
          actor.continue(ack_if_unchanged(state, conn_id, answered))
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

    EffectTimerFired(timer) -> {
      log.debug("brazier.runtime", "An after timer fired")
      effect.fire_after_timer(timer)
      actor.continue(state)
    }

    Shutdown -> {
      log.info("brazier.runtime", "Runtime shutting down")
      telemetry.runtime_stop(monotonic_time() - state.started_at, "shutdown")
      stop_listener(state.listener_subject)
      stop_effect_processes()
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

/// Register a connection's subject and monitor its owner (the transport
/// handler), as `Phoenix.Channel.Server` monitors its transport pid in
/// `init_join` and stops on its `:DOWN`. A registration under an id that is
/// already registered forgets the old one first: it must join again.
///
/// A subject with no owner is a named subject whose name no process holds:
/// nothing can receive what the runtime would send, so it is refused, not
/// registered.
fn register_connection(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  subject: Subject(transport.InternalMessage),
) -> RuntimeState(model, msg) {
  case process.subject_owner(subject) {
    Error(Nil) -> {
      log.warning(
        "brazier.runtime",
        "Connection "
          <> conn_id
          <> " not registered: its subject is named and no process holds the name",
      )
      state
    }
    Ok(owner) -> {
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
      // A monitor of a process that already exited fires at once (noproc),
      // so a handler that is gone by now is forgotten when its DOWN is
      // handled, or earlier by a send that finds it gone.
      let monitor = process.monitor(owner)
      RuntimeState(
        ..state,
        connections: dict.insert(state.connections, conn_id, subject),
        owner_monitors: dict.insert(state.owner_monitors, conn_id, monitor),
      )
    }
  }
}

/// The owner of a connection's subject went down. Its handler exited without
/// a `ClientDisconnected` the runtime has handled yet (it crashed, was
/// killed, or the disconnect is still queued behind this): forget the
/// connection, as `ClientDisconnected` does. A DOWN no connection's monitor
/// matches cannot come from `forget_connection` (it demonitors with flush),
/// so it is logged and discarded like any message the actor does not expect.
fn handle_owner_down(
  state: RuntimeState(model, msg),
  down: process.Down,
) -> RuntimeState(model, msg) {
  case down {
    process.ProcessDown(monitor:, pid:, reason:) -> {
      let owned =
        dict.to_list(state.owner_monitors)
        |> list.find(fn(entry) { entry.1 == monitor })
      case owned {
        Ok(#(conn_id, _)) -> {
          log.info(
            "brazier.runtime",
            "Connection "
              <> conn_id
              <> " handler "
              <> string.inspect(pid)
              <> " went down ("
              <> describe_down_reason(reason)
              <> "); forgetting it",
          )
          telemetry.runtime_connection_forgotten(
            telemetry.ConnectionDown,
            0,
            conn_id,
          )
          forget_connection(state, conn_id)
        }
        Error(Nil) -> {
          log.warning(
            "brazier.runtime",
            "Discarding a DOWN of "
              <> string.inspect(pid)
              <> " for a monitor no connection holds",
          )
          state
        }
      }
    }
    process.PortDown(port:, ..) -> {
      log.warning(
        "brazier.runtime",
        "Discarding a DOWN of port "
          <> string.inspect(port)
          <> ": the runtime monitors no port",
      )
      state
    }
  }
}

fn describe_down_reason(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    _ -> describe_exit(reason)
  }
}

/// Remove every trace of a connection, and stop monitoring its owner. With
/// no joined connection left the cache no longer describes anyone's state.
fn forget_connection(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
) -> RuntimeState(model, msg) {
  case dict.get(state.owner_monitors, conn_id) {
    // Flushes a DOWN already in the mailbox, so none arrives for a
    // connection that is no longer registered.
    Ok(monitor) -> process.demonitor_process(monitor)
    Error(Nil) -> Nil
  }
  let joined = set.delete(state.joined, conn_id)
  RuntimeState(
    ..state,
    connections: dict.delete(state.connections, conn_id),
    owner_monitors: dict.delete(state.owner_monitors, conn_id),
    joined: joined,
    client_acks: dict.delete(state.client_acks, conn_id),
    cached_model: case set.is_empty(joined) {
      True -> NoCache
      False -> state.cached_model
    },
    streams: stream_session.forget(state.streams, conn_id),
  )
}

fn warn_client_ops(
  conn_id: transport.ConnectionId,
  ops: List(transport.ClientOp),
) -> Nil {
  case ops {
    [] -> Nil
    _ ->
      log.warning(
        "brazier.runtime",
        "Ignoring "
          <> int.to_string(list.length(ops))
          <> " client-supplied model ops from "
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

/// Log and build the error of a connection refused for its join token
/// (`join_token_refused_status`).
fn refuse_join_token(
  conn_id: transport.ConnectionId,
  page_uri: Uri,
  reason: String,
) -> error.BrazierError {
  log.warning(
    "brazier.runtime",
    "Refusing connection "
      <> conn_id
      <> " for "
      <> describe_uri(page_uri)
      <> ": "
      <> reason
      <> " (close "
      <> int.to_string(error.init_close_code_base + join_token_refused_status)
      <> ": the browser reloads the page for a fresh token)",
  )
  error.InitRejected(error.refuse(
    join_token_refused_status,
    "join token refused: " <> reason,
  ))
}

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
              <> log_path(path)
              <> " — full resync, join token not used",
          )
          Ok(RuntimeState(..state, joined: set.delete(state.joined, conn_id)))
        }
        False -> {
          log.info(
            "brazier.runtime",
            "Client joined: " <> conn_id <> " path: " <> log_path(path),
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
  // A later join (or a rejoin) gets its stream windows before its route is
  // applied, so that the route's stream ops reach them; the first join gets
  // its windows after, from the session's, which the route filled.
  let state = case state.accepted_first_join {
    False -> state
    True -> begin_live_join(state, conn_id)
  }
  // Route changes are broadcast to the OTHER joined connections; the
  // joiner is not joined yet and gets the result in its model_sync.
  let state = route_join(state, conn_id, path)
  let live_join = state.live_join
  let state = RuntimeState(..state, live_join: None)
  case dict.has_key(state.connections, conn_id) {
    True -> complete_join(state, conn_id, live_join)
    // The route's error frame found the joiner gone or slow, and forgot it
    // (logged there): there is nothing left to join.
    False -> {
      log.debug(
        "brazier.runtime",
        "Join of " <> conn_id <> " not completed: forgotten while routing it",
      )
      state
    }
  }
}

/// Give a join after the first one (or a rejoin) its stream windows, before
/// its route is applied: a new connection's start empty (no replay,
/// docs/design/STREAMS.md 7.3), a rejoin keeps its own (7.2).
fn begin_live_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
) -> RuntimeState(model, msg) {
  // Invariant: a join completes or is dropped within one message, and the
  // joiner is not joined while it joins (a rejoin left the joined set).
  let assert None = state.live_join
    as "brazier/runtime: a join started while another one was in progress"
  let assert False = set.contains(state.joined, conn_id)
    as "brazier/runtime: a joining connection is in the joined set"
  let #(streams, frame, errors) = stream_session.join(state.streams, conn_id)
  RuntimeState(
    ..state,
    streams: streams,
    live_join: Some(LiveJoin(conn_id: conn_id, frame: frame, errors: errors)),
  )
}

/// The rest of a join, once its route was applied: the joiner is
/// registered. `live_join` is the join's stream state when it is not the
/// runtime's first (`begin_live_join`).
fn complete_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  live_join: Option(LiveJoin),
) -> RuntimeState(model, msg) {
  // If the cache is unusable, the other joined connections may be stale
  // too: resync everyone, not just the joiner.
  let stale_others = case state.cached_model {
    NoCache -> set.to_list(state.joined)
    _ -> []
  }
  // The joiner's stream entries and refusals. On the runtime's first join:
  // every window filled before it (docs/design/STREAMS.md 7.2), and every
  // refusal made before it. On a later join: what its route's update made
  // for its windows. The others' stores are not part of a resync.
  let #(state, join_frame, stream_errors) = case live_join {
    Some(LiveJoin(conn_id: joiner, frame: frame, errors: errors)) -> {
      let assert True = joiner == conn_id
        as "brazier/runtime: a join completed with another connection's stream state"
      #(state, frame, errors)
    }
    None -> {
      // Invariant: `accept_join` begins a live join for every join after
      // the first.
      let assert False = state.accepted_first_join
        as "brazier/runtime: a later join has no live join stream state"
      let #(streams, frame, snapshot_errors) =
        stream_session.join(state.streams, conn_id)
      let held = take_held_stream_errors(state.held_stream_errors, conn_id)
      #(
        RuntimeState(
          ..state,
          streams: streams,
          held_stream_errors: no_held_stream_errors,
        ),
        frame,
        list.append(held, snapshot_errors),
      )
    }
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
  let state = send_stream_errors(state, [conn_id], stream_errors)
  let #(state, sent) =
    send_model_sync_to(
      state,
      [conn_id, ..stale_others],
      "join_model_sync",
      fn(target) {
        case target == conn_id {
          True -> join_frame
          False -> stream_session.empty_frame
        }
      },
    )
  let state = case sent {
    True -> state
    False ->
      RuntimeState(
        ..state,
        streams: stream_session.client_holds_nothing(state.streams, conn_id),
      )
  }
  let state = case set.contains(state.joined, conn_id) {
    True -> send_title_on_join(state, conn_id)
    // A send of this join found the joiner gone or slow and forgot it
    // (logged there); the title has no one to go to.
    False -> state
  }
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
      use recovered <- result.try(check_join_token(
        restore,
        option.is_some(state.restore_model),
        state.secret_key,
        token,
        session_fingerprint,
        conn_id,
      ))
      case recovered {
        // No connection has joined the runtime yet, so its state is the
        // one `init` built when it started (plus any messages its effects
        // dispatched since). `restore` runs in the actor: a crash in it
        // crashes the runtime, as a crash in `update` does.
        Some(recovery) -> {
          use model <- result.map(restore_recovered(
            recovery,
            state.model,
            conn_id,
          ))
          RuntimeState(..state, model: model)
        }
        None -> Ok(state)
      }
    }
  }
}

/// The model a verified join token carries, waiting for the fresh state
/// `init` builds: `restore` gets both (SEC-17).
type Recovery(model) {
  Recovery(
    restore: fn(String, model) -> Result(model, String),
    model_json: String,
  )
}

/// Run the app's `restore` on a recovered model and the fresh state.
fn restore_recovered(
  recovery: Recovery(model),
  fresh: model,
  conn_id: transport.ConnectionId,
) -> Result(model, String) {
  case recovery.restore(recovery.model_json, fresh) {
    Ok(model) -> {
      log.info(
        "brazier.runtime",
        "State recovered from the join token for " <> conn_id,
      )
      Ok(model)
    }
    Error(reason) ->
      Error("the join token's model does not restore: " <> reason)
  }
}

/// Check a join token. `Ok(Some(recovery))` is the model to recover from
/// it, `Ok(None)` a token with nothing to recover (or none, without state
/// recovery), and `Error(reason)` a join that must be refused:
///
/// - a token that does not verify: malformed, signed with another key (an
///   older server process with a generated secret), expired, or issued to
///   another browser session;
/// - no token while state recovery is enabled: the server render always
///   sets the cookie, so its absence means the browser did not keep it;
/// - a token without a model while state recovery is enabled: the server
///   render always puts the model in (it refuses the page when the model is
///   too large for a cookie), so the token was minted without recovery.
///
/// A model that `restore` refuses (its shape changed) is refused too, by
/// `restore_recovered`, once `init` has built the fresh state.
///
/// `restore` is `None` when no model is to be recovered (recovery disabled,
/// or the runtime already joined a connection); `recovery_enabled` says
/// whether the app opted into state recovery at all.
fn check_join_token(
  restore: Option(fn(String, model) -> Result(model, String)),
  recovery_enabled: Bool,
  secret_key: String,
  token: String,
  session_fingerprint: String,
  conn_id: transport.ConnectionId,
) -> Result(Option(Recovery(model)), String) {
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
        // The page render puts the model in every join token while state
        // recovery is on, and refuses a page whose token would not fit in
        // a cookie. A token without one was minted elsewhere (by a server
        // without recovery): restarting from `init` would silently lose
        // the session's state.
        Some(_), None ->
          Error("state recovery is enabled and the join token carries no model")
        Some(restore), Some(model_json) -> {
          log.debug(
            "brazier.runtime",
            "Join token from "
              <> conn_id
              <> " verified; its model is restored once init has run",
          )
          Ok(Some(Recovery(restore: restore, model_json: model_json)))
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
  events: List(#(String, String, String, String, Int, List(transport.ClientOp))),
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
      // The stream ops of every event, in order, ride the batch's one
      // broadcast (docs/design/STREAMS.md 7.1). Kept newest event first.
      let #(state, failures, stream_ops) =
        list.index_fold(events, #(state, [], []), fn(acc, evt, idx) {
          let #(acc_state, failures, stream_ops) = acc
          let #(event_name, handler_id, event_data, target_path, clock, ops) =
            evt
          warn_client_ops(conn_id, ops)
          let acc_state = record_ack(acc_state, conn_id, clock, BatchEventClock)
          case
            acc_state.decode_event(
              event_name,
              handler_id,
              event_data,
              target_path,
            )
          {
            Ok(msg) -> {
              let #(acc_state, ops) =
                run_update_only(acc_state, msg, Some(conn_id))
              #(acc_state, failures, [ops, ..stream_ops])
            }
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
              #(acc_state, [reason, ..failures], stream_ops)
            }
          }
        })
      let state = case list.reverse(failures) {
        [] -> state
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
      let #(state, changed) =
        broadcast_model(
          state,
          "batch",
          Some(conn_id),
          list.flatten(list.reverse(stream_ops)),
        )
      let state = reconcile_subscriptions(state)
      ack_if_unchanged(state, conn_id, changed)
    }
  }
}

/// What carried a clock: events, events of a batch and navigations share
/// one per-connection counter on the client.
type ClockSource {
  EventClock
  BatchEventClock
  NavigationClock
}

fn clock_source_label(source: ClockSource) -> String {
  case source {
    EventClock -> "event"
    BatchEventClock -> "batch event"
    NavigationClock -> "navigation"
  }
}

/// Record `clock` as acknowledged for `conn_id`. A clock below the one
/// already recorded is logged as a warning naming its `source` and does not
/// move the ack back.
fn record_ack(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  clock: Int,
  source: ClockSource,
) -> RuntimeState(model, msg) {
  let previous = ack_for(state, conn_id)
  case clock < previous {
    True ->
      log.warning(
        "brazier.runtime",
        "Non-monotonic "
          <> clock_source_label(source)
          <> " clock from "
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
    True -> state
    // The connection was joined when its message arrived, so if it is no
    // longer registered a send while handling the message forgot it.
    False ->
      send_to_targets(state, [conn_id], fn(conn_id) {
        transport.SendPatch(
          ops_json: "[]",
          version: state.revision,
          ack_clock: ack_for(state, conn_id),
          streams_json: stream_session.empty_frame,
        )
      })
  }
}

/// Why a client-reported path cannot be routed in place.
type PathProblem {
  /// Not a same-origin path (`internal/local_path`): never navigated to.
  NotLocal(reason: String)
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
  use Nil <- result.try(local_path.check(path) |> result.map_error(NotLocal))
  use parsed <- result.try(
    uri.parse(path)
    |> result.replace_error(BadEncoding("the path does not parse as a URL")),
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
///
/// Returns whether the client was already answered: by the broadcast of a
/// changed model, or by the `hard_navigate` of a refusal. When it was not
/// (`on_change` left the model as it was, or the refusal was an `error`
/// frame, which carries no clock), the caller sends an ack, so every
/// navigation the runtime handles settles its clock on the client.
fn handle_navigation(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  path: String,
) -> #(RuntimeState(model, msg), Bool) {
  let resolved = case state.route {
    None -> Error(NoRouter)
    Some(route) ->
      route_for_path(route, state.page_uri, path)
      |> result.map_error(Unroutable)
  }
  case resolved {
    Ok(msg) -> {
      let state = RuntimeState(..state, current_route_msg: Some(msg))
      run_update_for(state, msg, Some(conn_id), Some(telemetry.Navigate))
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
/// (the dead render answers it), or an error for a non-local path. The
/// `Bool` is whether that answered the navigation: an `error` frame does
/// not carry the navigation's clock, so after one the caller sends the
/// empty-patch ack that settles it (as for an event that changed nothing).
fn refuse_navigation(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  path: String,
  problem: NavigationProblem,
) -> #(RuntimeState(model, msg), Bool) {
  case problem {
    NoRouter -> {
      log.warning(
        "brazier.runtime",
        "Navigation to "
          <> log_path(path)
          <> " from "
          <> conn_id
          <> " but the app has no router; loading the page",
      )
      hard_navigate(state, conn_id, path)
    }
    Unroutable(problem) ->
      case problem {
        NotLocal(reason) -> {
          log.warning(
            "brazier.runtime",
            "Navigation from "
              <> conn_id
              <> " to a non-local path refused ("
              <> reason
              <> "): "
              <> log_path(path),
          )
          let state =
            send_to_conn_id(
              state,
              conn_id,
              transport.SendError(
                reason: "navigation path must be a same-origin path",
              ),
            )
          #(state, False)
        }
        BadEncoding(reason) -> {
          log.warning(
            "brazier.runtime",
            "Navigation from "
              <> conn_id
              <> " to "
              <> log_path(path)
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
              <> log_path(path)
              <> "; loading the page (the server answers 404)",
          )
          hard_navigate(state, conn_id, path)
        }
      }
  }
}

/// Send a hard navigation to `path`: the browser loads it. Only a
/// same-origin path is ever sent (`internal/local_path`); every caller has
/// already checked it, so another path is a bug in the runtime, which is
/// logged as an error and answered with an error, never sent. The `Bool`
/// is whether the navigation was answered (see `refuse_navigation`): the
/// hard navigation answers it, the error does not.
fn hard_navigate(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  path: String,
) -> #(RuntimeState(model, msg), Bool) {
  case local_path.check(path) {
    Ok(Nil) -> #(
      send_to_conn_id(state, conn_id, transport.SendHardNavigate(path: path)),
      True,
    )
    Error(reason) -> {
      log.error(
        "brazier.runtime",
        "Refusing to send a hard navigation to "
          <> conn_id
          <> " for "
          <> log_path(path)
          <> ": not a same-origin path, "
          <> reason,
      )
      #(
        send_to_conn_id(
          state,
          conn_id,
          transport.SendError(reason: "Invalid page path"),
        ),
        False,
      )
    }
  }
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
                "Join path "
                  <> log_path(path)
                  <> " changes the route; running on_change",
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
            NotLocal(reason) ->
              "join path is not a same-origin path: " <> reason
            BadEncoding(reason) ->
              "join path has an invalid encoding: " <> reason
            UnknownRoute -> "no route for the joined path " <> log_path(path)
          }
          log.warning(
            "brazier.runtime",
            "Join from " <> conn_id <> ": " <> reason,
          )
          send_to_conn_id(state, conn_id, transport.SendError(reason: reason))
        }
      }
  }
}

/// A page URL for logs: its path only (see `brazier/internal/log_path`).
fn describe_uri(page_uri: Uri) -> String {
  log_path.describe_uri(page_uri)
}

/// A client-supplied page path for logs (see `brazier/internal/log_path`).
fn log_path(path: String) -> String {
  log_path.describe(path)
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
  // The stream ops ride the broadcast of this update; the other effects
  // run after it (docs/design/STREAMS.md 7.1).
  let #(stream_ops, effects) = effect.take_stream_ops(effects)
  let #(state, changed) =
    broadcast_model(
      RuntimeState(..state, model: new_model),
      label,
      conn_id,
      stream_ops,
    )
  run_effects_with_context(effects, state.self, conn_id, state.connections)
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
      // Most updates do not change the topics: an equal list needs no diff.
      case new_subs == state.current_subscriptions {
        True -> state
        False -> {
          apply_subscription_diff(
            listener,
            set.from_list(state.current_subscriptions),
            set.from_list(new_subs),
          )
          RuntimeState(..state, current_subscriptions: new_subs)
        }
      }
    }
    _, _ -> state
  }
}

/// Send the listener the topics to join and leave, diffed as sets so the
/// cost is O(n log n) in the number of topics.
fn apply_subscription_diff(
  listener: Subject(ListenerCommand),
  current: Set(String),
  wanted: Set(String),
) -> Nil {
  let to_subscribe = set.to_list(set.difference(wanted, current))
  let to_unsubscribe = set.to_list(set.difference(current, wanted))
  list.each(to_subscribe, fn(t) { process.send(listener, SubscribeTo(t)) })
  list.each(to_unsubscribe, fn(t) { process.send(listener, UnsubscribeFrom(t)) })
  case to_subscribe, to_unsubscribe {
    [], [] -> Nil
    _, _ ->
      log.info(
        "brazier.subscription",
        "Subscriptions updated: +"
          <> int.to_string(list.length(to_subscribe))
          <> " -"
          <> int.to_string(list.length(to_unsubscribe)),
      )
  }
}

/// Run update WITHOUT broadcasting — for atomic batch processing.
/// Only updates the model and executes effects. The broadcast happens once
/// after the batch, and carries the stream ops returned here.
fn run_update_only(
  state: RuntimeState(model, msg),
  msg: msg,
  conn_id: Option(transport.ConnectionId),
) -> #(RuntimeState(model, msg), List(stream_op.Op)) {
  let #(new_model, effects) =
    telemetry.runtime_span(
      telemetry.HandleEvent,
      transport.page_route,
      event_label(msg),
      connection_label(conn_id),
      fn() { state.update(state.model, msg) },
    )
  let #(stream_ops, effects) = effect.take_stream_ops(effects)
  run_effects_with_context(effects, state.self, conn_id, state.connections)
  #(RuntimeState(..state, model: new_model), stream_ops)
}

/// The generated server codec (`brazier_codec`, written by
/// `gleam run -m brazier/build`) for the app's Model and Msg.
pub type GeneratedCodec(model, msg) {
  GeneratedCodec(
    encode_model: fn(model) -> String,
    decode_model: fn(String) -> Result(model, String),
    decode_event: fn(String, String, String, String) ->
      Result(msg, error.BrazierError),
    /// The streams the app declares (`brazier_codec.stream_names`).
    stream_names: List(String),
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
  use stream_names <- result.try(
    try_load_codec_stream_names()
    |> result.replace_error(missing("stream_names/0")),
  )
  let stream_names = stream_names()
  log.info(
    "brazier.runtime",
    "The generated codec declares "
      <> int.to_string(list.length(stream_names))
      <> " stream(s)",
  )
  Ok(GeneratedCodec(
    encode_model: encode_model,
    decode_model: decode_model,
    decode_event: fn(name, handler_id, data, target_path) {
      decode_event(name, handler_id, data, target_path)
      |> result.map_error(fn(reason) {
        error.CodecError(reason: reason, raw: data)
      })
    },
    stream_names: stream_names,
  ))
}

@external(erlang, "brazier_runtime_ffi", "try_load_codec_stream_names")
fn try_load_codec_stream_names() -> Result(fn() -> List(String), Nil)

@external(erlang, "brazier_runtime_ffi", "try_load_codec_encoder")
fn try_load_codec_encoder() -> Result(fn(model) -> String, Nil)

@external(erlang, "brazier_runtime_ffi", "try_load_codec_decoder")
fn try_load_codec_decoder() -> Result(fn(String) -> Result(model, String), Nil)

@external(erlang, "brazier_runtime_ffi", "try_load_codec_event_decoder")
fn try_load_codec_event_decoder() -> Result(
  fn(String, String, String, String) -> Result(msg, String),
  Nil,
)

/// The outcome of diffing the cache against a freshly encoded model. Every
/// variant but `InvalidJson` carries the snapshot of the new model, which
/// becomes the cache once it is sent.
@internal
pub type SnapshotDiff {
  /// The client-visible JSON is identical (or decodes equal): nothing to
  /// send.
  Unchanged(snapshot: patch.Snapshot)
  /// Send these ops (a non-empty JSON array) as a patch.
  Changed(ops_json: String, snapshot: patch.Snapshot)
  /// The cache cannot be diffed against: send a full model_sync.
  Resync(snapshot: patch.Snapshot)
  /// The model encoder returned something that is not JSON: nothing can be
  /// sent.
  InvalidJson(reason: String)
}

/// Diff the cached model against the new model JSON. JSON equal to the
/// cached string short-circuits without decoding; otherwise only the new
/// model is decoded, since the cached one is kept decoded (PERF-2).
@internal
pub fn diff_snapshot(old: CachedModelState, new_json: String) -> SnapshotDiff {
  case old {
    FullModelCache(cached) ->
      case patch.snapshot_json(cached) == new_json {
        True -> Unchanged(cached)
        False ->
          case patch.snapshot(new_json) {
            Error(reason) -> InvalidJson(reason)
            Ok(new) ->
              case patch.diff_snapshots(cached, new) {
                patch.Unchanged -> Unchanged(new)
                patch.Ops(ops_json) -> Changed(ops_json:, snapshot: new)
              }
          }
      }
    NoCache -> {
      log.debug(
        "brazier.runtime",
        "No cached model to diff against; full resync",
      )
      case patch.snapshot(new_json) {
        Ok(new) -> Resync(new)
        Error(reason) -> InvalidJson(reason)
      }
    }
  }
}

/// The snapshot to send for `model_json`: the cached one when the JSON is
/// the cached string, so a join or resync of an unchanged model decodes
/// nothing.
fn snapshot_for(
  cached: CachedModelState,
  model_json: String,
) -> Result(patch.Snapshot, String) {
  case cached {
    FullModelCache(snapshot) ->
      case patch.snapshot_json(snapshot) == model_json {
        True -> Ok(snapshot)
        False -> patch.snapshot(model_json)
      }
    NoCache -> patch.snapshot(model_json)
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
  model_not_sent(
    state,
    targets,
    "Model too large: "
      <> int.to_string(size)
      <> " bytes exceeds the "
      <> int.to_string(model_size_max_bytes)
      <> " byte limit",
  )
}

/// The model encoder returned text that is not JSON (an app bug): nothing
/// is sent, so a client never holds a model it cannot parse. Handled like
/// `model_too_large`: the affected connections are told, and the cache is
/// dropped so the next broadcast is a full resync, which decodes again and
/// fails again until the encoder is fixed.
fn model_invalid(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  reason: String,
  context: String,
) -> RuntimeState(model, msg) {
  log.error(
    "brazier.runtime",
    "Model encoder returned invalid JSON in "
      <> context
      <> " — not sent to "
      <> int.to_string(list.length(targets))
      <> " connection(s): "
      <> reason,
  )
  model_not_sent(state, targets, "Model encoder returned invalid JSON")
}

/// Tell `targets` the model could not be sent, and drop the cache.
fn model_not_sent(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  reason: String,
) -> RuntimeState(model, msg) {
  let state = RuntimeState(..state, cached_model: NoCache)
  send_to_targets(state, targets, fn(_conn_id) {
    transport.SendError(reason: reason)
  })
}

/// Broadcast the current model and the update's `stream_ops` to every
/// joined connection: a patch when the cache can be diffed, a full
/// model_sync otherwise. The stream entries ride that frame; when the
/// model is unchanged (or could not be sent) and a connection has stream
/// entries, they ride an empty patch at the current revision
/// (docs/design/STREAMS.md 7.1). Returns whether anything was sent.
///
/// The ops are applied to the session's windows even with no connection
/// joined: they are the items a first join is sent (7.2).
///
/// With joined connections, the broadcast is a `[brazier, runtime, render]`
/// span for `event` (the message's label, or `"batch"`); with none,
/// nothing is rendered and nothing is emitted.
fn broadcast_model(
  state: RuntimeState(model, msg),
  event: String,
  conn_id: Option(transport.ConnectionId),
  stream_ops: List(stream_op.Op),
) -> #(RuntimeState(model, msg), Bool) {
  let targets = set.to_list(state.joined)
  // A later joiner whose route this update is takes the stream ops on its
  // own windows; its entries and refusals ride its join model_sync. A
  // joiner forgotten while routing it has no windows left.
  let joiner = case state.live_join {
    Some(live) ->
      case dict.has_key(state.connections, live.conn_id) {
        True -> Some(live)
        False -> None
      }
    None -> None
  }
  let stream_targets = case joiner {
    Some(live) -> [live.conn_id, ..targets]
    None -> targets
  }
  let update =
    stream_session.apply(state.streams, stream_ops, stream_targets, event)
  let state = RuntimeState(..state, streams: update.streams)
  let #(state, update) = case joiner {
    Some(live) -> {
      // Invariant: a join's route runs one update (`route_join`).
      let assert True = live.frame == stream_session.empty_frame
        as "brazier/runtime: a joiner's route ran more than one update"
      let #(frame, update) = stream_session.take_frame(update, live.conn_id)
      #(
        RuntimeState(
          ..state,
          live_join: Some(
            LiveJoin(
              ..live,
              frame: frame,
              errors: list.append(live.errors, update.errors),
            ),
          ),
        ),
        update,
      )
    }
    None ->
      case state.accepted_first_join {
        // No connection has joined yet: the first join is sent these.
        False -> #(
          RuntimeState(
            ..state,
            held_stream_errors: hold_stream_errors(
              state.held_stream_errors,
              update.errors,
              event,
            ),
          ),
          update,
        )
        // Nothing is replayed (docs/design/STREAMS.md 7.3): with no
        // connection joined, a refusal is in the error log only.
        True -> #(state, update)
      }
  }
  let state = send_stream_errors(state, targets, update.errors)
  // A connection the error frames found gone or slow was forgotten; the
  // model frame goes to the ones still joined.
  let targets = list.filter(targets, set.contains(state.joined, _))
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
          let #(state, changed, sent_bytes) =
            broadcast_to(state, targets, update)
          #(
            #(sync_title(state, targets), changed),
            sent_bytes,
            largest_frame_bytes(update, targets),
          )
        },
      )
  }
}

/// The size in bytes of the largest `streams` array `update` sends to one
/// of `targets`; 0 when it sends none.
fn largest_frame_bytes(
  update: stream_session.Update,
  targets: List(transport.ConnectionId),
) -> Int {
  case stream_session.has_entries(update) {
    False -> 0
    True ->
      list.fold(targets, 0, fn(largest, conn_id) {
        int.max(
          largest,
          string.byte_size(stream_session.frame(update, conn_id)),
        )
      })
  }
}

/// Send one `error` frame per refused stream op group to each of
/// `targets`. Each refusal was logged at error and counted by
/// `[brazier, stream, refused]` when it was refused.
fn send_stream_errors(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  errors: List(String),
) -> RuntimeState(model, msg) {
  list.fold(errors, state, fn(state, reason) {
    send_to_targets(state, targets, fn(_conn_id) {
      transport.SendError(reason: reason)
    })
  })
}

const no_held_stream_errors = HeldStreamErrors(reasons: [], dropped: 0)

/// Hold the stream refusals of an update made before the runtime's first
/// join (`cause` names it), up to `held_stream_errors_max` reasons; the
/// rest are counted.
fn hold_stream_errors(
  held: HeldStreamErrors,
  errors: List(String),
  cause: String,
) -> HeldStreamErrors {
  list.fold(errors, held, fn(held, reason) {
    case list.length(held.reasons) < held_stream_errors_max {
      True -> {
        log.debug(
          "brazier.runtime",
          "No connection joined yet; the stream refusal of the update for "
            <> cause
            <> " is held for the first join",
        )
        HeldStreamErrors(..held, reasons: [reason, ..held.reasons])
      }
      False -> {
        let dropped = held.dropped + 1
        log.warning(
          "brazier.runtime",
          "No connection joined yet and "
            <> int.to_string(held_stream_errors_max)
            <> " stream refusals are held for the first join; the refusal of the update for "
            <> cause
            <> " is counted only ("
            <> int.to_string(dropped)
            <> " counted so far)",
        )
        HeldStreamErrors(..held, dropped: dropped)
      }
    }
  })
}

/// The `error` frame reasons the runtime's first join `conn_id` is sent for
/// the refusals held before it, oldest first; one more names the number of
/// refusals past the bound.
fn take_held_stream_errors(
  held: HeldStreamErrors,
  conn_id: transport.ConnectionId,
) -> List(String) {
  let reasons = list.reverse(held.reasons)
  let reasons = case held.dropped {
    0 -> reasons
    dropped -> {
      log.warning(
        "brazier.runtime",
        "First join "
          <> conn_id
          <> ": "
          <> int.to_string(dropped)
          <> " stream refusal(s) made before it were past the bound of "
          <> int.to_string(held_stream_errors_max)
          <> "; it is sent their count only",
      )
      list.append(reasons, [
        int.to_string(dropped)
        <> " more stream refusal(s) before the join; see the server log",
      ])
    }
  }
  case reasons {
    [] -> Nil
    _ ->
      log.info(
        "brazier.runtime",
        "First join "
          <> conn_id
          <> ": sending "
          <> int.to_string(list.length(reasons))
          <> " error frame(s) for the stream refusals made before it",
      )
  }
  reasons
}

/// The model sent no frame, but `update` has stream entries: send them on
/// an empty patch at the current revision, which also acknowledges each
/// connection's events. Every target gets one so that no connection is
/// acknowledged twice. Returns whether anything was sent.
fn send_stream_only(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  update: stream_session.Update,
) -> #(RuntimeState(model, msg), Bool) {
  case stream_session.has_entries(update) {
    False -> #(state, False)
    True -> {
      log.debug(
        "brazier.runtime",
        "Model frame not sent; sending the stream entries on an empty patch"
          <> " at revision "
          <> int.to_string(state.revision)
          <> " to "
          <> int.to_string(list.length(targets))
          <> " connection(s)",
      )
      let state =
        send_to_targets(state, targets, fn(conn_id) {
          transport.SendPatch(
            ops_json: "[]",
            version: state.revision,
            ack_clock: ack_for(state, conn_id),
            streams_json: stream_session.frame(update, conn_id),
          )
        })
      #(state, True)
    }
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

/// The title has gone over `title_max_bytes`: log it once for this time
/// over the limit and report it to `targets`. Nothing is sent in its place
/// and the last title sent stays the browsers' title.
fn title_went_over_limit(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  size: Int,
) -> RuntimeState(model, msg) {
  log.error(
    "brazier.runtime",
    "Title went over the limit: "
      <> int.to_string(size)
      <> " bytes, over the "
      <> int.to_string(title_max_bytes)
      <> " byte limit; not sent, reported to "
      <> int.to_string(list.length(targets))
      <> " connection(s) until it is back under the limit",
  )
  report_title_too_large(state, targets, size)
}

/// The title went back under `title_max_bytes` after it was reported.
fn log_title_back_within_limit(size: Int) -> Nil {
  log.info(
    "brazier.runtime",
    "Title back within the "
      <> int.to_string(title_max_bytes)
      <> " byte limit at "
      <> int.to_string(size)
      <> " bytes; a later title over it is reported again",
  )
}

/// Send the `error` frame for a title over `title_max_bytes` to `targets`.
fn report_title_too_large(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  size: Int,
) -> RuntimeState(model, msg) {
  let reason =
    "Title too large: "
    <> int.to_string(size)
    <> " bytes exceeds the "
    <> int.to_string(title_max_bytes)
    <> " byte limit"
  send_to_targets(state, targets, fn(_conn_id) {
    transport.SendError(reason: reason)
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
      case state.title_sync {
        TitleWithinLimit(_) -> Nil
        // The state changed while no connection was joined to be synced.
        TitleOverLimit(_) ->
          log_title_back_within_limit(string.byte_size(title))
      }
      log.debug("brazier.runtime", "Sending title to joined " <> conn_id)
      let state =
        send_to_conn_id(state, conn_id, transport.SendTitle(title: title))
      // The other joined connections were synced before this join (a route
      // change is broadcast to them first), so they all have this title.
      RuntimeState(
        ..state,
        title_sync: TitleWithinLimit(last_sent: Some(title)),
      )
    }
    Error(size) -> {
      let state = case state.title_sync {
        TitleWithinLimit(_) -> title_went_over_limit(state, [conn_id], size)
        TitleOverLimit(_) -> {
          // Already logged for this time over the limit; this connection
          // has not been told yet.
          log.debug(
            "brazier.runtime",
            "Title still over the limit at "
              <> int.to_string(size)
              <> " bytes; reported to joined "
              <> conn_id,
          )
          report_title_too_large(state, [conn_id], size)
        }
      }
      // The joiner shows the server render's title, not the last one sent,
      // so the next title within the limit is sent to everyone.
      RuntimeState(..state, title_sync: TitleOverLimit(last_sent: None))
    }
  }
}

/// After an update, send the title to `targets` (every joined connection)
/// when it differs from the one they were last sent. The title is a
/// function of the server state, so it can change when the client-visible
/// model does not. A title over the limit is reported when it goes over,
/// and not again until it has been back within the limit.
fn sync_title(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
) -> RuntimeState(model, msg) {
  case current_title(state) {
    Ok(None) -> state
    Ok(Some(title)) -> {
      let last_sent = case state.title_sync {
        TitleWithinLimit(last_sent:) -> last_sent
        TitleOverLimit(last_sent:) -> {
          log_title_back_within_limit(string.byte_size(title))
          last_sent
        }
      }
      let state = case last_sent == Some(title) {
        True -> state
        False -> {
          log.info(
            "brazier.runtime",
            "Title changed; sending it to "
              <> int.to_string(list.length(targets))
              <> " connection(s)",
          )
          send_to_targets(state, targets, fn(_conn_id) {
            transport.SendTitle(title: title)
          })
        }
      }
      RuntimeState(
        ..state,
        title_sync: TitleWithinLimit(last_sent: Some(title)),
      )
    }
    Error(size) ->
      case state.title_sync {
        TitleWithinLimit(last_sent:) -> {
          let state = title_went_over_limit(state, targets, size)
          RuntimeState(..state, title_sync: TitleOverLimit(last_sent:))
        }
        TitleOverLimit(_) -> {
          log.debug(
            "brazier.runtime",
            "Title still over the limit at "
              <> int.to_string(size)
              <> " bytes; already reported",
          )
          state
        }
      }
  }
}

/// The broadcast to a non-empty `targets`. The `Int` is the size in bytes
/// of what each connection was sent: the patch ops, the model on a
/// resync, 0 when no model frame was sent. Each connection's stream
/// entries in `update` ride the model frame, or an empty patch when there
/// is none.
fn broadcast_to(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  update: stream_session.Update,
) -> #(RuntimeState(model, msg), Bool, Int) {
  let model_json = state.model_encoder(state.model)
  let model_bytes = string.byte_size(model_json)
  case check_model_size(model_bytes, "broadcast") {
    TooLarge(size) -> {
      let state = model_too_large(state, targets, size, "broadcast")
      let #(state, sent) = send_stream_only(state, targets, update)
      #(state, sent, 0)
    }
    SizeOk ->
      case diff_snapshot(state.cached_model, model_json) {
        InvalidJson(reason) -> {
          let state = model_invalid(state, targets, reason, "broadcast")
          let #(state, sent) = send_stream_only(state, targets, update)
          #(state, sent, 0)
        }
        Unchanged(snapshot) -> {
          log.debug("brazier.runtime", "Model unchanged, skipping broadcast")
          let state =
            RuntimeState(..state, cached_model: FullModelCache(snapshot))
          let #(state, sent) = send_stream_only(state, targets, update)
          #(state, sent, 0)
        }
        Changed(ops_json, snapshot) -> {
          let revision = state.revision + 1
          let state =
            RuntimeState(
              ..state,
              revision: revision,
              cached_model: FullModelCache(snapshot),
            )
          log.debug(
            "brazier.runtime",
            "Broadcasting patch revision " <> int.to_string(revision),
          )
          // The cache is set first: a connection forgotten below that
          // leaves none joined drops it again (`forget_connection`).
          let state =
            send_to_targets(state, targets, fn(conn_id) {
              transport.SendPatch(
                ops_json: ops_json,
                version: revision,
                ack_clock: ack_for(state, conn_id),
                streams_json: stream_session.frame(update, conn_id),
              )
            })
          #(state, True, string.byte_size(ops_json))
        }
        Resync(snapshot) -> {
          log.debug(
            "brazier.runtime",
            "No usable cache; broadcasting full model_sync",
          )
          // The model was encoded and decoded above; send that snapshot
          // rather than encoding it again.
          let state = RuntimeState(..state, revision: state.revision + 1)
          let state =
            send_snapshot_to(
              state,
              targets,
              snapshot,
              "broadcast_resync",
              fn(conn_id) { stream_session.frame(update, conn_id) },
            )
          #(state, True, model_bytes)
        }
      }
  }
}

/// Encode the current model and send it as a model_sync (current
/// revision, each connection's own ack, the `streams` array `frames`
/// gives each connection), then cache its snapshot. The `Bool` is whether
/// it was sent: a model over the size limit or not valid JSON is reported
/// instead.
///
/// Callers must include every joined connection in `targets` when the
/// cache is `NoCache`, since the cache is about to describe all of them.
fn send_model_sync_to(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  context: String,
  frames: fn(transport.ConnectionId) -> String,
) -> #(RuntimeState(model, msg), Bool) {
  let model_json = state.model_encoder(state.model)
  case check_model_size(string.byte_size(model_json), context) {
    TooLarge(size) -> #(model_too_large(state, targets, size, context), False)
    SizeOk ->
      case snapshot_for(state.cached_model, model_json) {
        Ok(snapshot) -> #(
          send_snapshot_to(state, targets, snapshot, context, frames),
          True,
        )
        Error(reason) -> #(
          model_invalid(state, targets, reason, context),
          False,
        )
      }
  }
}

/// Send an already encoded, size-checked and decoded model as a model_sync
/// and cache it. Same `targets` rule as `send_model_sync_to`.
fn send_snapshot_to(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  snapshot: patch.Snapshot,
  context: String,
  frames: fn(transport.ConnectionId) -> String,
) -> RuntimeState(model, msg) {
  let model_json = patch.snapshot_json(snapshot)
  // The cache is set first: a connection forgotten below that leaves none
  // joined drops it again (`forget_connection`).
  let state = RuntimeState(..state, cached_model: FullModelCache(snapshot))
  let state =
    send_to_targets(state, targets, fn(conn_id) {
      transport.SendModelSync(
        model_json: model_json,
        version: state.revision,
        ack_clock: ack_for(state, conn_id),
        streams_json: frames(conn_id),
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
  state
}

/// Full resync for one connection (or all joined ones when the cache is
/// unusable, since they may be stale too). A resync carries no stream
/// entries: the clients keep the stream items they hold (STREAMS.md 6.1).
fn resync(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  context: String,
) -> RuntimeState(model, msg) {
  let targets = case state.cached_model {
    NoCache -> set.to_list(set.insert(state.joined, conn_id))
    _ -> [conn_id]
  }
  let #(state, _sent) =
    send_model_sync_to(state, targets, context, fn(_conn_id) {
      stream_session.empty_frame
    })
  // A resync that was not sent was reported to `targets` by
  // `send_model_sync_to`; no stream window changed.
  state
}

/// Execute effects by providing a dispatch function that sends messages
/// back to the runtime actor.
fn run_effects(
  effects: Effect(msg),
  self: Subject(RuntimeMessage(msg)),
) -> Nil {
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
) -> Nil {
  case effect.is_none(effects) {
    True -> Nil
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
      effect.perform(effects, dispatch, dispatch_keyed)
    }
  }
}

/// Stop the effect processes and timers this runtime owns. The effect
/// module tracks them in the runtime's process, each kind bounded by its
/// limit (see `brazier/effect`), so this costs at most the sum of the
/// limits.
fn stop_effect_processes() -> Nil {
  case effect.stop_owned() {
    #(0, 0) -> Nil
    #(processes, timers) ->
      log.info(
        "brazier.runtime",
        "Stopped "
          <> int.to_string(processes)
          <> " effect process(es) and cancelled "
          <> int.to_string(timers)
          <> " after timer(s)",
      )
  }
}

fn stop_listener(listener: Option(Subject(ListenerCommand))) -> Nil {
  case listener {
    Some(subject) -> process.send(subject, ShutdownListener)
    None -> Nil
  }
}

const max_outbound_mailbox_messages = 1000

/// Send a reply to the connection whose message is being handled, by id.
/// An id that is not registered is logged and nothing is sent. The returned
/// state has forgotten the connection when the send found it slow (it was
/// told to close) or gone (see `send_to_connection`).
fn send_to_conn_id(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  message: transport.InternalMessage,
) -> RuntimeState(model, msg) {
  case dict.get(state.connections, conn_id) {
    Ok(subject) -> send_to_connection(state, conn_id, subject, message)
    Error(Nil) -> {
      log.warning(
        "brazier.runtime",
        "Cannot send to unregistered connection " <> conn_id,
      )
      state
    }
  }
}

/// Send to each of `targets` the message `message_for` builds for it, in
/// order. Every caller passes connections that were registered when the
/// runtime began handling the current message (joined connections, or the
/// connection being joined), so a target that is no longer registered was
/// forgotten by an earlier send of this same message (logged there) and is
/// skipped. The returned state has forgotten every target a send found slow
/// or gone.
fn send_to_targets(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  message_for: fn(transport.ConnectionId) -> transport.InternalMessage,
) -> RuntimeState(model, msg) {
  list.fold(targets, state, fn(state, conn_id) {
    case dict.get(state.connections, conn_id) {
      Ok(subject) ->
        send_to_connection(state, conn_id, subject, message_for(conn_id))
      Error(Nil) -> {
        log.debug(
          "brazier.runtime",
          "Not sending to " <> conn_id <> ": forgotten earlier in this update",
        )
        state
      }
    }
  })
}

/// Send `message` to a registered connection, unless it cannot take it:
///
/// - its handler has exited (no mailbox): it is gone, not slow. It is
///   forgotten, logged once at info; its `ClientDisconnected` or its owner's
///   DOWN, when either arrives, finds it already forgotten.
/// - its mailbox holds more than `max_outbound_mailbox_messages`: it is told
///   to close (`CloseForBackpressure`, which the transport answers with an
///   `error` frame and close 1013) and forgotten at once, so it is warned
///   about and told to close once, not again on every later broadcast.
fn send_to_connection(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  subject: Subject(transport.InternalMessage),
  message: transport.InternalMessage,
) -> RuntimeState(model, msg) {
  let queue_len = case process.subject_owner(subject) {
    Ok(pid) ->
      process_message_queue_len(pid)
      |> result.replace_error("handler " <> string.inspect(pid) <> " exited")
    // A named subject whose name was released after it registered.
    Error(Nil) -> Error("no process holds its subject's name")
  }
  case queue_len {
    Error(why) -> {
      log.info(
        "brazier.runtime",
        "Connection " <> conn_id <> " is gone (" <> why <> "); forgetting it",
      )
      telemetry.runtime_connection_forgotten(
        telemetry.ConnectionDown,
        0,
        conn_id,
      )
      forget_connection(state, conn_id)
    }
    Ok(queue_len) ->
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
              <> "); closing slow client and forgetting it",
          )
          process.send(
            subject,
            transport.CloseForBackpressure(
              reason: "Connection is too far behind; reconnect to resync",
            ),
          )
          telemetry.runtime_connection_forgotten(
            telemetry.ConnectionSlow,
            queue_len,
            conn_id,
          )
          forget_connection(state, conn_id)
        }
        False -> {
          process.send(subject, message)
          state
        }
      }
  }
}

/// The length of a local process's mailbox, or `Error(Nil)` when the
/// process has exited.
@external(erlang, "brazier_runtime_ffi", "message_queue_len")
fn process_message_queue_len(pid: Pid) -> Result(Int, Nil)

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
/// fresh token. A model recovered from the token goes to the app's
/// `restore` with the state `init` built, before the runtime starts; a
/// model `restore` refuses is refused the same way.
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
        Error(reason) ->
          Error(refuse_join_token(conn_id, context.uri(ctx), reason))
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

/// The Context for a connected mount, from the upgrade request. Its page is
/// `transport.get_upgrade_page`, the page the transport gated the upgrade on.
@internal
pub fn connected_context(
  req: request.Request(server.Connection),
) -> Result(Context, String) {
  log.debug(
    "brazier.runtime",
    "Building connected context from upgrade request " <> log_path(req.path),
  )
  use page <- result.try(transport.get_upgrade_page(req))
  let page_uri =
    uri.Uri(..request.to_uri(req), path: page.path, query: page.query)
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
  recovered: Option(Recovery(model)),
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
    transport.ClientNavigate(path, clock) ->
      process.send(
        runtime_subject,
        ClientNavigated(conn_id: conn_id, path: path, clock: clock),
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
    /// "listener <pid> of runtime <pid>", the prefix of every log line.
    log_context: String,
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
  let listener_pid =
    process.spawn_unlinked(fn() {
      let log_context =
        "listener "
        <> string.inspect(process.self())
        <> " of runtime "
        <> string.inspect(runtime_pid)
      // Monitor before linking: if the runtime is already gone the monitor
      // delivers DOWN (noproc) and the loop exits on its first receive.
      let owner_monitor = process.monitor(runtime_pid)
      case process.link(runtime_pid) {
        True -> Nil
        // The runtime already exited; the monitor above delivers DOWN and
        // the loop stops on its first receive.
        False ->
          log.debug(
            "brazier.subscription",
            log_context <> ": runtime already exited before link",
          )
      }
      // Create the command subject HERE — inside the spawned process —
      // so it's owned by this process and receives messages correctly.
      let command_subject = process.new_subject()

      // Subscribe to the initial topics BEFORE replying, so that once
      // `start` returns no broadcast to an initial topic can be missed.
      let topics = set.from_list(topics)
      subscribe_initial(log_context, set.to_list(topics), 0)
      process.send(reply_subject, command_subject)
      log.info(
        "brazier.subscription",
        log_context
          <> ": started with "
          <> int.to_string(set.size(topics))
          <> " initial topic(s)",
      )
      listener_loop(
        Listener(
          runtime_subject: runtime_subject,
          command_subject: command_subject,
          owner_monitor: owner_monitor,
          on_notify: on_notify,
          on_notification: on_notification,
          log_context: log_context,
        ),
        topics,
      )
    })
  // INVARIANT: the listener replies as soon as it has joined its initial
  // topics. No reply within 5s means it crashed (it is linked to this
  // runtime, so that crash also arrives as an exit signal) or is stuck:
  // either way the runtime cannot deliver notifications, so it crashes.
  let assert Ok(command_subject) = process.receive(reply_subject, 5000)
    as {
      "PubSub listener "
      <> string.inspect(listener_pid)
      <> " of runtime "
      <> string.inspect(runtime_pid)
      <> " did not report its command subject within 5000ms"
    }
  command_subject
}

/// Listener receive loop — handles commands and PubSub notifications.
fn listener_loop(listener: Listener(msg), subscriptions: Set(String)) -> Nil {
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
      case set.contains(subscriptions, topic) {
        True -> {
          log.debug(
            "brazier.subscription",
            listener.log_context
              <> ": already subscribed to "
              <> string.inspect(topic),
          )
          listener_loop(listener, subscriptions)
        }
        False -> {
          pubsub.subscribe(topic)
          let subscriptions = set.insert(subscriptions, topic)
          log.debug(
            "brazier.subscription",
            listener.log_context
              <> ": subscribed to "
              <> string.inspect(topic)
              <> " ("
              <> int.to_string(set.size(subscriptions))
              <> " topic(s))",
          )
          telemetry.subscription_changed(
            telemetry.Subscribe,
            set.size(subscriptions),
          )
          listener_loop(listener, subscriptions)
        }
      }
    CommandReceived(UnsubscribeFrom(topic)) ->
      case set.contains(subscriptions, topic) {
        True -> {
          pubsub.unsubscribe(topic)
          let subscriptions = set.delete(subscriptions, topic)
          log.debug(
            "brazier.subscription",
            listener.log_context
              <> ": unsubscribed from "
              <> string.inspect(topic)
              <> " ("
              <> int.to_string(set.size(subscriptions))
              <> " topic(s))",
          )
          telemetry.subscription_changed(
            telemetry.Unsubscribe,
            set.size(subscriptions),
          )
          listener_loop(listener, subscriptions)
        }
        False -> {
          log.debug(
            "brazier.subscription",
            listener.log_context
              <> ": ignoring unsubscribe from non-subscribed topic "
              <> string.inspect(topic),
          )
          listener_loop(listener, subscriptions)
        }
      }
    CommandReceived(ShutdownListener) -> {
      log.info(
        "brazier.subscription",
        listener.log_context
          <> ": shutting down, leaving "
          <> int.to_string(set.size(subscriptions))
          <> " topic(s)",
      )
      unsubscribe_all(listener.log_context, set.to_list(subscriptions))
    }
    OwnerExited(reason) -> {
      log.info(
        "brazier.subscription",
        listener.log_context
          <> ": owning runtime exited ("
          <> reason
          <> "); stopping, leaving "
          <> int.to_string(set.size(subscriptions))
          <> " topic(s)",
      )
      unsubscribe_all(listener.log_context, set.to_list(subscriptions))
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
fn subscribe_initial(
  log_context: String,
  topics: List(String),
  subscribed: Int,
) -> Nil {
  case topics {
    [] -> Nil
    [topic, ..rest] -> {
      log.info(
        "brazier.subscription",
        log_context <> ": subscribing to " <> string.inspect(topic),
      )
      pubsub.subscribe(topic)
      telemetry.subscription_changed(telemetry.Subscribe, subscribed + 1)
      subscribe_initial(log_context, rest, subscribed + 1)
    }
  }
}

fn unsubscribe_all(log_context: String, subscriptions: List(String)) -> Nil {
  case subscriptions {
    [] -> Nil
    [topic, ..rest] -> {
      log.debug(
        "brazier.subscription",
        log_context <> ": unsubscribing on stop from " <> string.inspect(topic),
      )
      pubsub.unsubscribe(topic)
      telemetry.subscription_changed(telemetry.Unsubscribe, list.length(rest))
      unsubscribe_all(log_context, rest)
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
