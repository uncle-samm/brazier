/// Beacon: full-stack Gleam web apps on the BEAM.
///
/// An app is an MVU loop that runs on the server, one process per browser
/// tab, and renders in the browser from a synced Model.
///
/// ```gleam
/// import beacon
/// import beacon/effect.{type Effect}
/// import beacon/element.{type Element}
/// import beacon/event
/// import beacon/html
/// import gleam/int
///
/// pub type Model { Model(count: Int) }
/// pub type Msg { Increment Decrement }
///
/// fn init(_ctx: beacon.Context) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
///   Ok(#(Model(count: 0), effect.none()))
/// }
///
/// fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
///   case msg {
///     Increment -> #(Model(count: model.count + 1), effect.none())
///     Decrement -> #(Model(count: model.count - 1), effect.none())
///   }
/// }
///
/// pub fn view(model: Model) -> Element(Msg) {
///   html.div([], [
///     html.button([event.on_click(Decrement)], [html.text("-")]),
///     html.span([], [html.text(int.to_string(model.count))]),
///     html.button([event.on_click(Increment)], [html.text("+")]),
///   ])
/// }
///
/// pub fn main() {
///   beacon.application(init:, update:, view:)
///   |> beacon.title(fn(_) { "Counter" })
///   |> beacon.start(8080)
/// }
/// ```
///
/// Three constructors:
/// - `simple`: a pure `update`, also compiled to JavaScript and applied in
///   the browser at once; the server runs the same `update` and stays
///   authoritative (Lustre's `simple`).
/// - `application`: a server `update` that returns effects. The whole model
///   is synced to the client.
/// - `full_application`: a server state record, of which `sync` picks the
///   client-visible Model, plus a client-only Local layer.
///
/// `view` and the `Model` type must be `pub`, because the build compiles
/// them to JavaScript.
///
/// Reference: Lustre `application`/`simple`, LiveView mount.
import beacon/api
import beacon/application
import beacon/cluster as beacon_cluster
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/error
import beacon/internal/context
import beacon/internal/presence_watch
import beacon/local
import beacon/log
import beacon/middleware
import beacon/notification.{type Notification}
import beacon/presence as beacon_presence
import beacon/presence/sync as presence_sync
import beacon/pubsub
import beacon/runtime
import beacon/transport
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import simplifile

// ===== Context =====

/// What `init` knows about the request it runs for: the page URL, the
/// cookies, whether this is the connected mount (WebSocket) or the dead
/// render (HTTP), and the browser session.
///
/// `init` runs twice per page, like LiveView's mount: once for the HTML
/// response (`is_connected` False, effects dropped) and once when the
/// browser connects (`is_connected` True, effects run).
pub type Context =
  context.Context

/// The page URL (for the connected mount, the URL the browser shows).
pub fn uri(ctx: Context) -> Uri {
  context.uri(ctx)
}

/// A request cookie by name.
pub fn cookie(ctx: Context, name: String) -> Result(String, Nil) {
  context.cookie(ctx, name)
}

/// True for the connected mount, False for the dead render (LiveView's
/// `connected?/1`).
pub fn is_connected(ctx: Context) -> Bool {
  context.is_connected(ctx)
}

/// Why `init` refused to start a session. Build one with `error.unavailable`
/// (503) or `error.refuse(status, reason)` from `beacon/error`.
///
/// Every constructor's `init` returns `Result(_, InitError)`, like LiveView's
/// `mount` returning `{:ok, socket}`. An `Error` is answered on the dead
/// render with an error page for its status, and on the connected mount by
/// closing the WebSocket with `4000 + status` (4503 for `unavailable`). The
/// reason is logged and never sent to the browser. A crash in `init` is
/// answered with 500 on the dead render and closes the WebSocket with 1011.
pub type InitError =
  error.InitError

/// An opaque, stable id for the browser session (a hash of Beacon's session
/// cookie), the same for the dead render and the connected mount. Error
/// when the request has no Beacon session cookie (its first page load).
pub fn session_id(ctx: Context) -> Result(String, Nil) {
  context.session_id(ctx)
}

// ===== App =====

/// An app being configured. Build one with `simple`, `application` or
/// `full_application`, pipe it through the options, then call `start`.
///
/// - `state`: what the server holds per session.
/// - `model`: the client-visible part (`sync(state)`), sent to the browser.
/// - `local`: client-only state, never sent to the server.
/// - `msg`: the app's messages.
pub opaque type App(state, model, local, msg) {
  App(
    init: fn(Context) -> Result(#(state, Effect(msg)), InitError),
    update: fn(state, msg) -> #(state, Effect(msg)),
    sync: fn(state) -> model,
    local: local.Layer(model, local, msg),
    view: fn(model, local) -> Element(msg),
    route: Option(fn(Uri) -> Result(msg, Nil)),
    title: fn(model) -> String,
    restore: Option(fn(model) -> state),
    subscriptions: Option(fn(state) -> List(String)),
    on_notify: Option(fn(String) -> msg),
    on_notification: Option(fn(Notification) -> msg),
    secret_key: Option(String),
    middlewares: List(middleware.Middleware),
    static_dir: Option(String),
    security_limits: transport.SecurityLimits,
    head_html: Option(String),
    api_handler: Option(fn(api.Request) -> Option(api.Response)),
    ws_auth: Option(fn(api.Request) -> Result(Nil, String)),
    dev_mode: Bool,
    pubsub: pubsub.PubSubConfig,
    cluster: Option(beacon_cluster.ClusterConfig),
    presence: Option(presence_watch.Watch(state, msg)),
  )
}

/// A Lustre-style app with a pure `update`.
///
/// The build compiles `update` to JavaScript, so a click updates the page
/// at once. The message is still sent to the server, which runs the same
/// `update` and stays authoritative: when the two models differ, the
/// server's model wins and the browser logs the mismatch.
///
/// `update` may only use code that can run in the browser (the same rule
/// as `view`); the build fails, naming the call, when it reaches anything
/// else. Use `application` for effects or server-only work.
pub fn simple(
  init init: fn(Context) -> Result(model, InitError),
  update update: fn(model, msg) -> model,
  view view: fn(model) -> Element(msg),
) -> App(model, model, Nil, msg) {
  new_app(
    init: fn(ctx) {
      result.map(init(ctx), fn(model) { #(model, effect.none()) })
    },
    update: fn(model, msg) { #(update(model, msg), effect.none()) },
    sync: identity,
    local: local.none(),
    view: fn(model, _local) { view(model) },
  )
}

/// An app whose whole model is synced to the client. `update` runs only on
/// the server and returns effects.
pub fn application(
  init init: fn(Context) -> Result(#(model, Effect(msg)), InitError),
  update update: fn(model, msg) -> #(model, Effect(msg)),
  view view: fn(model) -> Element(msg),
) -> App(model, model, Nil, msg) {
  new_app(
    init: init,
    update: update,
    sync: identity,
    local: local.none(),
    view: fn(model, _local) { view(model) },
  )
}

/// An app with all three state layers:
/// - `state`, held only by the server (secrets, history, handles);
/// - the Model, `sync(state)`, rendered by `view` and sent to the browser;
/// - Local, client-only state from the `local` layer (`local.layer` or
///   `local.none()`).
///
/// Only the types `sync`, `view` and the Local layer reach are compiled for
/// the browser, so the rest of `state` never leaves the server.
pub fn full_application(
  init init: fn(Context) -> Result(#(state, Effect(msg)), InitError),
  update update: fn(state, msg) -> #(state, Effect(msg)),
  sync sync: fn(state) -> model,
  local local: local.Layer(model, local, msg),
  view view: fn(model, local) -> Element(msg),
) -> App(state, model, local, msg) {
  new_app(init: init, update: update, sync: sync, local: local, view: view)
}

fn new_app(
  init init: fn(Context) -> Result(#(state, Effect(msg)), InitError),
  update update: fn(state, msg) -> #(state, Effect(msg)),
  sync sync: fn(state) -> model,
  local local: local.Layer(model, local, msg),
  view view: fn(model, local) -> Element(msg),
) -> App(state, model, local, msg) {
  App(
    init: init,
    update: update,
    sync: sync,
    local: local,
    view: view,
    route: None,
    title: fn(_model) { "Beacon" },
    restore: None,
    subscriptions: None,
    on_notify: None,
    on_notification: None,
    secret_key: None,
    middlewares: [middleware.secure_headers()],
    static_dir: None,
    security_limits: transport.default_security_limits(),
    head_html: None,
    api_handler: None,
    ws_auth: None,
    dev_mode: False,
    pubsub: pubsub.default_config(),
    cluster: None,
    presence: None,
  )
}

fn identity(value: a) -> a {
  value
}

// ===== Options =====

/// Route the app by URL. Declare one `Route` type and a `parse` function
/// (usually a `case` over `router.segments(uri)`); Beacon runs
/// `update(state, on_change(route))` right after `init`, before the first
/// render, and again on every client navigation (LiveView's
/// `handle_params`). A URL `parse` rejects is answered with 404, and a URL
/// whose percent-encoding does not decode with 400.
pub fn with_router(
  app: App(state, model, local, msg),
  parse parse: fn(Uri) -> Result(route, Nil),
  on_change on_change: fn(route) -> msg,
) -> App(state, model, local, msg) {
  App(
    ..app,
    route: Some(fn(page_uri) { parse(page_uri) |> result.map(on_change) }),
  )
}

/// The page title, computed from the model of the first render.
pub fn title(
  app: App(state, model, local, msg),
  title: fn(model) -> String,
) -> App(state, model, local, msg) {
  App(..app, title: title)
}

/// Topics this session subscribes to, computed from the state after every
/// update. Beacon diffs the list and subscribes or unsubscribes as needed.
/// ```gleam
/// beacon.application(init:, update:, view:)
/// |> beacon.subscriptions(fn(model) { ["room:" <> model.current_room] })
/// |> beacon.on_notify(RoomUpdated)
/// ```
pub fn subscriptions(
  app: App(state, model, local, msg),
  compute: fn(state) -> List(String),
) -> App(state, model, local, msg) {
  App(..app, subscriptions: Some(compute))
}

/// The message for a notification on a subscribed topic (by topic).
pub fn on_notify(
  app: App(state, model, local, msg),
  handler: fn(String) -> msg,
) -> App(state, model, local, msg) {
  App(..app, on_notify: Some(handler))
}

/// The message for a typed notification on a subscribed topic.
pub fn on_notification(
  app: App(state, model, local, msg),
  handler: fn(Notification) -> msg,
) -> App(state, model, local, msg) {
  App(..app, on_notification: Some(handler))
}

/// Extra HTML for the page's `<head>` (stylesheets, meta tags, fonts).
pub fn head_html(
  app: App(state, model, local, msg),
  html: String,
) -> App(state, model, local, msg) {
  App(..app, head_html: Some(html))
}

/// Register an API route handler. It runs before page rendering and static
/// files on every HTTP request: `Some(response)` answers the request, `None`
/// falls through.
///
/// Prefer `beacon/api.routes` with `api.get`, `api.post` and the response
/// helpers for ordinary JSON/text endpoints.
pub fn api_routes(
  app: App(state, model, local, msg),
  handler: fn(api.Request) -> Option(api.Response),
) -> App(state, model, local, msg) {
  App(..app, api_handler: Some(handler))
}

/// Authenticate WebSocket connections. Runs before the upgrade; `Error`
/// rejects the connection with 401.
pub fn ws_auth(
  app: App(state, model, local, msg),
  auth: fn(api.Request) -> Result(Nil, String),
) -> App(state, model, local, msg) {
  App(..app, ws_auth: Some(auth))
}

/// Override the transport's security limits. Start from
/// `transport.default_security_limits()`.
pub fn security_limits(
  app: App(state, model, local, msg),
  limits: transport.SecurityLimits,
) -> App(state, model, local, msg) {
  App(..app, security_limits: limits)
}

/// The secret key for signed tokens: at least 32 bytes. Without one, a
/// random key is generated at start (tokens then do not survive a restart).
pub fn secret_key(
  app: App(state, model, local, msg),
  key: String,
) -> App(state, model, local, msg) {
  App(..app, secret_key: Some(key))
}

/// Add a middleware to the HTTP pipeline (after the ones already added).
pub fn with_middleware(
  app: App(state, model, local, msg),
  mw: middleware.Middleware,
) -> App(state, model, local, msg) {
  App(..app, middlewares: list.append(app.middlewares, [mw]))
}

/// Serve static files from `dir` under `/static`.
pub fn static_dir(
  app: App(state, model, local, msg),
  dir: String,
) -> App(state, model, local, msg) {
  App(..app, static_dir: Some(dir))
}

/// Enable Beacon's client dev tracing.
pub fn dev_mode(
  app: App(state, model, local, msg),
  enabled: Bool,
) -> App(state, model, local, msg) {
  App(..app, dev_mode: enabled)
}

/// Configure PubSub (partitions, pool size, limits). Start from
/// `pubsub.default_config()`. PubSub runs as the first child of the
/// application's supervision tree.
pub fn pubsub_config(
  app: App(state, model, local, msg),
  config: pubsub.PubSubConfig,
) -> App(state, model, local, msg) {
  App(..app, pubsub: config)
}

/// Join a cluster: the cluster manager (built with `cluster.new`) runs in
/// the application's supervision tree right after PubSub, connecting to
/// and checking peers. Start fails when the configuration or this node's
/// distribution does not pass `cluster`'s checks.
pub fn cluster(
  app: App(state, model, local, msg),
  config: beacon_cluster.ClusterConfig,
) -> App(state, model, local, msg) {
  App(..app, cluster: Some(config))
}

/// Track who is here (Phoenix.Presence). The tracker (built with
/// `presence.new`) runs in the application's supervision tree, and every
/// session tracks what `track` returns for its state: computed after every
/// update, tracked, updated and untracked as the list changes, and gone
/// when the session ends. Every change on a tracked topic, from any node,
/// arrives as `on_presence(diff)`: the session's first message for a topic
/// lists everyone already there as joins, and up to 100 queued changes are
/// coalesced into one message. Keep the entries with
/// `beacon/presence/sync.merge`. The diff, entry and meta types live in
/// `beacon/presence/sync`, which runs in the browser, so `Msg` and the
/// Model can carry them.
///
/// ```gleam
/// pub type Msg {
///   PresenceChanged(sync.Diff(Profile))
/// }
///
/// beacon.application(init:, update:, view:)
/// |> beacon.presence(
///   tracker: presence.new("online", encode_user, user_decoder()),
///   track: fn(model) {
///     [presence.Tracking(topic: "room:" <> model.room, key: model.user, meta: model.profile)]
///   },
///   on_presence: PresenceChanged,
/// )
/// ```
///
/// A tracking the tracker refuses (a limit, an invalid topic or key, the
/// same key twice on a topic) stops the session with a logged error. When
/// a shard of the tracker restarts, every session tracks its entries on it
/// again. Start fails when the tracker configuration is invalid.
pub fn presence(
  app: App(state, model, local, msg),
  tracker tracker: beacon_presence.PresenceConfig(meta),
  track track: fn(state) -> List(beacon_presence.Tracking(meta)),
  on_presence on_presence: fn(presence_sync.Diff(meta)) -> msg,
) -> App(state, model, local, msg) {
  App(..app, presence: Some(presence_watch.new(tracker, track, on_presence)))
}

/// Watch who is here without being there: every session follows the topics
/// `watch` returns for its state (computed after every update) and tracks
/// nothing. A dashboard or a lobby list uses this. The diffs are those of
/// `presence`: the first message for a topic lists everyone already there
/// as joins, up to 100 queued changes are coalesced into one message, every
/// entry is reported exactly once, and a topic the session stops watching
/// reports everyone it knew there as leaves.
///
/// ```gleam
/// beacon.application(init:, update:, view:)
/// |> beacon.watch_presence(
///   tracker: presence.new("online", encode_user, user_decoder()),
///   watch: fn(model) { ["room:" <> model.room] },
///   on_presence: PresenceChanged,
/// )
/// ```
///
/// It, `presence` and `track_and_watch_presence` set the same thing: the
/// later call replaces the earlier. To track and watch, use
/// `track_and_watch_presence`. An invalid topic (empty, or over
/// `presence.max_topic_bytes`) fails the session's start, or stops it
/// later, with a logged error.
/// Start fails when the tracker configuration is invalid.
pub fn watch_presence(
  app: App(state, model, local, msg),
  tracker tracker: beacon_presence.PresenceConfig(meta),
  watch watch: fn(state) -> List(String),
  on_presence on_presence: fn(presence_sync.Diff(meta)) -> msg,
) -> App(state, model, local, msg) {
  let watching =
    presence_watch.new_watching(tracker, fn(_state) { [] }, watch, on_presence)
  App(..app, presence: Some(watching))
}

/// `presence` and `watch_presence` together: every session tracks what
/// `track` returns for its state and also follows the topics `watch`
/// returns, without being on them. A chat room that shows who is in the
/// room and how many are in the lobby uses this. Both lists are computed
/// after every update. A topic that is both tracked and watched is followed
/// once, so its diffs arrive once. The diffs, limits and failures are those
/// of `presence` and `watch_presence`.
///
/// ```gleam
/// beacon.application(init:, update:, view:)
/// |> beacon.track_and_watch_presence(
///   tracker: presence.new("online", encode_user, user_decoder()),
///   track: fn(model) {
///     [presence.Tracking(topic: "room:" <> model.room, key: model.user, meta: model.profile)]
///   },
///   watch: fn(_model) { ["lobby"] },
///   on_presence: PresenceChanged,
/// )
/// ```
///
/// It, `presence` and `watch_presence` set the same thing: the later call
/// replaces the earlier.
pub fn track_and_watch_presence(
  app: App(state, model, local, msg),
  tracker tracker: beacon_presence.PresenceConfig(meta),
  track track: fn(state) -> List(beacon_presence.Tracking(meta)),
  watch watch: fn(state) -> List(String),
  on_presence on_presence: fn(presence_sync.Diff(meta)) -> msg,
) -> App(state, model, local, msg) {
  let watching = presence_watch.new_watching(tracker, track, watch, on_presence)
  App(..app, presence: Some(watching))
}

/// Recover the session after a reconnect to a new server process: the
/// page carries the Model in a signed join token, and `restore` rebuilds
/// the server state from it. For `simple` and `application`, where the
/// state is the Model, pass `function.identity`.
pub fn with_state_recovery(
  app: App(state, model, local, msg),
  restore restore: fn(model) -> state,
) -> App(state, model, local, msg) {
  App(..app, restore: Some(restore))
}

// ===== Notifications =====

/// Broadcast a notification to a topic. Every session subscribed to it
/// gets its `on_notify` message.
pub fn broadcast(topic: String) -> Nil {
  pubsub.broadcast(topic, Nil)
}

/// Broadcast a typed payload to a topic (read it in `on_notification` with
/// `notification_payload`).
pub fn broadcast_payload(topic: String, payload: a) -> Nil {
  pubsub.broadcast(topic, payload)
}

/// Decode a notification's payload.
pub fn notification_payload(
  notification: Notification,
  decoder: decode.Decoder(a),
) -> Result(a, List(decode.DecodeError)) {
  decode.run(notification.payload, decoder)
}

// ===== Start =====

/// Start the app on `port` under its supervision tree and block forever.
/// If the tree gives up (a child keeps crashing), the calling process
/// crashes with the reason instead of running on without it.
///
/// The server codec and the client bundle are build artifacts of
/// `gleam run -m beacon/build` (or `gleam run -m beacon/dev`); starting
/// without them is an error.
pub fn start(
  app: App(state, model, local, msg),
  port: Int,
) -> Result(Nil, error.BeaconError) {
  log.configure()
  let checked = {
    use Nil <- result.try(require_client_bundle())
    runtime.load_generated_codec()
  }
  case checked {
    Error(err) -> {
      log.error("beacon", error.to_string(err))
      Error(err)
    }
    Ok(codec) -> {
      let config = to_config(app, codec, port)
      case application.start_supervised(config) {
        Ok(_app) -> {
          log.info(
            "beacon",
            "Running at http://localhost:" <> int.to_string(port),
          )
          application.wait_forever()
          Ok(Nil)
        }
        Error(err) -> Error(err)
      }
    }
  }
}

/// The application config for an app and its codec.
@internal
pub fn to_config(
  app: App(state, model, local, msg),
  codec: runtime.GeneratedCodec(model, msg),
  port: Int,
) -> application.AppConfig(state, msg) {
  let sync = app.sync
  let init_local = local.init(app.local)
  let encode_model = fn(state) { codec.encode_model(sync(state)) }
  application.AppConfig(
    port: port,
    init: app.init,
    update: app.update,
    view: fn(state) {
      let model = sync(state)
      app.view(model, init_local(model))
    },
    title: fn(state) { app.title(sync(state)) },
    encode_model: encode_model,
    decode_event: codec.decode_event,
    restore_model: case app.restore {
      None -> None
      Some(restore) ->
        Some(fn(json) { codec.decode_model(json) |> result.map(restore) })
    },
    route: app.route,
    secret_key: case app.secret_key {
      Some(key) -> key
      None -> generate_secret()
    },
    middlewares: app.middlewares,
    static_dir: app.static_dir,
    dynamic_subscriptions: app.subscriptions,
    on_notify: app.on_notify,
    on_notification: app.on_notification,
    security_limits: app.security_limits,
    head_html: app.head_html,
    api_handler: app.api_handler,
    ws_auth: app.ws_auth,
    dev_mode: app.dev_mode,
    pubsub: app.pubsub,
    cluster: app.cluster,
    presence: app.presence,
  )
}

// === Internal ===

fn generate_secret() -> String {
  let secret = do_generate_strong_secret()
  log.warning(
    "beacon",
    "Using auto-generated secret_key — tokens will be invalid after restart. Set explicit secret_key() for production.",
  )
  secret
}

@external(erlang, "beacon_application_ffi", "generate_strong_secret")
fn do_generate_strong_secret() -> String

const client_manifest = "priv/static/beacon_client.manifest"

const build_hint =
  "Run `gleam run -m beacon/build` before starting the app, or `gleam run -m beacon/dev` while developing."

/// Check that the client bundle built by `gleam run -m beacon/build` exists:
/// `priv/static/beacon_client.manifest` must name a bundle in `priv/static`.
fn require_client_bundle() -> Result(Nil, error.BeaconError) {
  case simplifile.read(client_manifest) {
    Error(err) ->
      Error(error.ConfigError(
        reason: "No client bundle: cannot read "
        <> client_manifest
        <> " ("
        <> simplifile.describe_error(err)
        <> "). "
        <> build_hint,
      ))
    Ok(contents) -> {
      let bundle = "priv/static/" <> string.trim(contents)
      case string.trim(contents), simplifile.is_file(bundle) {
        "", _ ->
          Error(error.ConfigError(
            reason: client_manifest <> " is empty. " <> build_hint,
          ))
        _, Ok(True) -> {
          log.info("beacon", "Client bundle " <> bundle)
          Ok(Nil)
        }
        _, Ok(False) ->
          Error(error.ConfigError(
            reason: client_manifest
            <> " names "
            <> bundle
            <> ", which does not exist. "
            <> build_hint,
          ))
        _, Error(err) ->
          Error(error.ConfigError(
            reason: "Cannot inspect "
            <> bundle
            <> ": "
            <> simplifile.describe_error(err),
          ))
      }
    }
  }
}
