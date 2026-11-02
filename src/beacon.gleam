/// Beacon — the simple API for building full-stack Gleam web apps.
///
/// ```gleam
/// import beacon
/// import beacon/html
///
/// pub fn main() {
///   beacon.app(init, beacon.no_local, beacon.no_server, update, view)
///   |> beacon.title("My App")
///   |> beacon.start(8080)
/// }
/// ```
import beacon/application
import beacon/effect
import beacon/element.{type Attr}
import beacon/error
import beacon/handler
import beacon/notification.{type Notification}
import beacon/transport/server.{type Connection, type ResponseBody}

/// A node in the virtual DOM tree. Re-exported from `beacon/element`.
pub type Node(msg) =
  element.Node(msg)

import beacon/log
import beacon/middleware
import beacon/pubsub
import beacon/route
import beacon/runtime
import beacon/transport
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

// ===== Event Helpers =====
// These register client-side handler metadata. Generated encode_msg/decode_event
// carries the typed event contract to the server.

/// Attach a click handler that sends the given message.
/// ```gleam
/// html.button([beacon.on_click(Increment)], [html.text("+")])
/// ```
pub fn on_click(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: "click", handler_id: id, debounce_ms: None)
}

/// Attach an input handler that extracts the value and passes it to your callback.
/// ```gleam
/// html.input([beacon.on_input(fn(text) { SetName(text) })])
/// ```
pub fn on_input(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "input", handler_id: id, debounce_ms: None)
}

/// Attach an input handler with a per-node debounce window in milliseconds.
pub fn on_input_debounced(delay_ms: Int, callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.on_debounced("input", id, delay_ms)
}

/// Attach a submit handler.
pub fn on_submit(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: "submit", handler_id: id, debounce_ms: None)
}

/// Attach a submit handler that receives a live browser snapshot.
///
/// The callback receives the submitted form's current fields as a JSON string.
/// Use this when a submit message depends on current Local/draft input values;
/// do not close over server-side Local in `on_submit(Save(local.draft))`.
pub fn on_submit_local(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(
    event_name: "submit-local",
    handler_id: id,
    debounce_ms: None,
  )
}

/// Attach a change handler with value extraction.
pub fn on_change(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "change", handler_id: id, debounce_ms: None)
}

/// Attach a focus handler.
pub fn on_focus(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: "focus", handler_id: id, debounce_ms: None)
}

/// Attach a blur handler.
pub fn on_blur(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: "blur", handler_id: id, debounce_ms: None)
}

/// Attach a mousedown handler that receives x,y coordinates as "x,y".
pub fn on_mousedown(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "mousedown", handler_id: id, debounce_ms: None)
}

/// Attach a mouseup handler that receives x,y coordinates as "x,y".
pub fn on_mouseup(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "mouseup", handler_id: id, debounce_ms: None)
}

/// Attach a mousemove handler that receives x,y coordinates as "x,y".
pub fn on_mousemove(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "mousemove", handler_id: id, debounce_ms: None)
}

/// Attach a keydown handler that receives the key name (e.g., "ArrowUp", "Enter", "a").
pub fn on_keydown(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "keydown", handler_id: id, debounce_ms: None)
}

/// Attach a dragstart handler. The callback receives the element's `data-drag-id` value.
/// Use with `html.attribute("draggable", "true")` and `html.attribute("data-drag-id", id)`.
pub fn on_dragstart(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "dragstart", handler_id: id, debounce_ms: None)
}

/// Attach a dragover handler. Automatically calls preventDefault to allow drops.
pub fn on_dragover(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: "dragover", handler_id: id, debounce_ms: None)
}

/// Attach a drop handler. The callback receives the dragged element's `data-drag-id`.
pub fn on_drop(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "drop", handler_id: id, debounce_ms: None)
}

/// Broadcast a PubSub notification to a topic.
/// All runtimes subscribed to this topic will receive their `on_pubsub` message.
pub fn broadcast(topic: String) -> Nil {
  pubsub.broadcast(topic, Nil)
}

/// Broadcast a typed payload to a topic.
pub fn broadcast_payload(topic: String, payload: a) -> Nil {
  pubsub.broadcast(topic, payload)
}

/// Decode a notification payload into a concrete type.
pub fn notification_payload(
  notification: Notification,
  decoder: decode.Decoder(a),
) -> Result(a, List(decode.DecodeError)) {
  decode.run(notification.payload, decoder)
}

// ===== Cookie Helpers =====
// Convenience re-exports from beacon/cookie for common use in ws_auth and api_routes.

import beacon/cookie

/// Get a cookie value from a request by name.
/// Shorthand for `beacon/cookie.get(req, name)`.
pub fn get_cookie(
  req: request.Request(body),
  name: String,
) -> Result(String, Nil) {
  cookie.get(req, name)
}

// ===== App Builder =====

/// An app being configured. Use `app()` to create, then pipe through
/// configuration functions, then call `start()`.
pub opaque type AppBuilder(model, msg) {
  AppBuilder(
    init_simple: Option(fn() -> model),
    init_effect: Option(fn() -> #(model, effect.Effect(msg))),
    update_simple: Option(fn(model, msg) -> model),
    update_effect: Option(fn(model, msg) -> #(model, effect.Effect(msg))),
    view: fn(model) -> Node(msg),
    title: String,
    secret_key: String,
    middlewares: List(middleware.Middleware),
    static_dir: Option(String),
    serialize_model: Option(fn(model) -> String),
    deserialize_model: Option(fn(String) -> Result(model, String)),
    /// True when the app defines client-owned Local state.
    has_local: Bool,
    /// Route patterns for URL matching (e.g., ["/", "/blog/:slug"]).
    route_patterns: List(route.RoutePattern),
    /// Called when the URL changes — produces a Msg for the update loop.
    on_route_change: Option(fn(route.Route) -> msg),
    /// Called before a client-side route transition is applied.
    /// Use this to cancel route-scoped work or tear down live surfaces.
    on_route_leave: Option(fn(route.Route, route.Route) -> effect.Effect(msg)),
    /// Dynamic subscription function: model → list of topics.
    dynamic_subscriptions: Option(fn(model) -> List(String)),
    /// Topic-aware notification handler for dynamic subscriptions.
    on_notify: Option(fn(String) -> msg),
    /// Typed notification handler for dynamic subscriptions.
    on_notification: Option(fn(Notification) -> msg),
    /// Server-side effect handler — runs AFTER update on the server.
    /// Used to separate pure update logic (compiles to JS) from side effects (server only).
    on_update_effect: Option(fn(model, msg) -> effect.Effect(msg)),
    /// Configurable security limits for the transport layer.
    security_limits: transport.SecurityLimits,
    /// Optional: extra HTML to inject into `<head>` (stylesheets, meta tags, etc.).
    head_html: Option(String),
    /// Optional: API route handler — runs BEFORE SSR/static file routing.
    /// If it returns Some(response), that response is sent immediately.
    /// If it returns None, the request falls through to SSR/static serving.
    api_handler: Option(
      fn(request.Request(Connection)) -> Option(response.Response(ResponseBody)),
    ),
    /// Optional: WebSocket authentication function.
    /// Runs before WS upgrade — Ok allows, Error(reason) rejects with 401.
    ws_auth: Option(fn(request.Request(Connection)) -> Result(Nil, String)),
    /// Optional: request-aware server state initializer.
    /// Replaces init_server with a function that receives the HTTP request,
    /// so it can read cookies, headers, etc. to populate server state.
    ws_init: Option(fn(request.Request(Connection)) -> model),
    /// Enable framework-owned client tracing and diagnostics.
    dev_mode: Bool,
  )
}

/// Default Local initializer for apps without client-owned state.
///
/// Use as the second argument to `app` when the app does not need drafts,
/// dropdown state, pointer trails, or other client-only UI state.
pub fn no_local(_model: model) -> Nil {
  Nil
}

/// Default Server initializer for apps without private server state.
///
/// Use as the third argument to `app` when the app does not need session,
/// secret, database, audit, or other server-only state.
pub fn no_server() -> Nil {
  Nil
}

/// Create a Beacon app.
///
/// `Model` is server-authoritative state: SSR uses it for first paint, then the
/// client receives model sync/patch updates and renders from generated code.
/// `Local` is client-owned per-tab state. Use `Nil` via `no_local` when absent.
/// `Server` is private per-session state. Use `Nil` via `no_server` when absent.
/// The view receives `Model` and `Local`; it never receives `Server`.
///
/// ```gleam
/// beacon.app(fn() { #(init(), effect.none()) }, beacon.no_local, beacon.no_server, update, view)
/// |> beacon.start(8080)
/// ```
pub fn app(
  init: fn() -> #(model, effect.Effect(msg)),
  init_local: fn(model) -> local,
  init_server: fn() -> server,
  update: fn(model, local, server, msg) -> #(model, local, server),
  view: fn(model, local) -> Node(msg),
) -> AppBuilder(#(model, local, server), msg) {
  // Wrap into one runtime state: #(Model, Local, Server). The generated model
  // encoder serializes only Model plus client-visible Local; Server is private.
  let combined_init = fn() {
    let #(model, initial_effect) = init()
    let local = init_local(model)
    let server = init_server()
    #(#(model, local, server), initial_effect)
  }
  let combined_update = fn(combined: #(model, local, server), msg: msg) {
    let #(model, local, server) = combined
    let #(new_model, new_local, new_server) = update(model, local, server, msg)
    #(#(new_model, new_local, new_server), effect.none())
  }
  let combined_view = fn(combined: #(model, local, server)) {
    let #(model, local, _server) = combined
    view(model, local)
  }
  AppBuilder(
    init_simple: None,
    init_effect: Some(combined_init),
    update_simple: None,
    update_effect: Some(combined_update),
    view: combined_view,
    title: "Beacon",
    secret_key: generate_secret(),
    middlewares: [middleware.secure_headers()],
    static_dir: None,
    serialize_model: None,
    deserialize_model: None,
    has_local: True,
    route_patterns: [],
    on_route_change: None,
    on_route_leave: None,
    dynamic_subscriptions: None,
    on_notify: None,
    on_notification: None,
    on_update_effect: None,
    security_limits: transport.default_security_limits(),
    head_html: None,
    api_handler: None,
    ws_auth: None,
    ws_init: None,
    dev_mode: False,
  )
}

/// Set the page title.
pub fn title(
  builder: AppBuilder(model, msg),
  t: String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, title: t)
}

/// Preserve DOM identity across reorders and unrelated morphs.
/// Pair with `preserve_children()` for client-owned DOM that must not remount.
pub fn keyed(key: String, child: Node(msg)) -> Node(msg) {
  element.keyed(key, child)
}

/// Preserve an element's children on the client while still allowing attribute updates.
pub fn preserve_children() -> Attr {
  element.attr("data-beacon-preserve-children", "true")
}

/// Restrict hook updates to a stable subset of attribute names.
/// When omitted, Beacon compares all rendered attributes on the hook node.
pub fn hook_watch(attr_names: List(String)) -> Attr {
  element.attr("data-beacon-hook-watch", string.join(attr_names, ","))
}

/// Enable Beacon client dev tracing.
pub fn dev_mode(
  builder: AppBuilder(model, msg),
  enabled: Bool,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, dev_mode: enabled)
}

/// Inject custom HTML into the `<head>` of the SSR page.
/// Use this for stylesheets, meta tags, fonts, or other head content.
///
/// ```gleam
/// beacon.app(init, beacon.no_local, beacon.no_server, update, view)
/// |> beacon.head_html("<link rel=\"stylesheet\" href=\"/static/styles.css\">")
/// |> beacon.start(8080)
/// ```
pub fn head_html(
  builder: AppBuilder(model, msg),
  html: String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, head_html: Some(html))
}

/// Register an API route handler.
/// The handler runs BEFORE SSR/static file routing on every HTTP request.
/// Return `Some(response)` to handle the request, `None` to fall through.
///
/// Prefer `beacon/api.routes` with `api.get`, `api.post`, and response helpers
/// for ordinary JSON/text endpoints. Use this raw handler form when you need
/// custom matching or transport-level control.
///
/// Use `beacon/transport/http.read_body(req, max_bytes)` to read POST bodies.
///
/// ```gleam
/// import beacon/api
///
/// beacon.app(init, beacon.no_local, beacon.no_server, update, view)
/// |> beacon.api_routes(api.routes([
///   api.get("/api/status", fn(_req) { api.json(200, "{\"ok\":true}") }),
///   api.post("/api/webhook", handle_webhook),
/// ]))
/// |> beacon.start(8080)
/// ```
///
/// Raw handler example:
///
/// ```gleam
/// import gleam/http
/// import gleam/http/request
/// import gleam/http/response
/// import gleam/option.{None, Some}
/// import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
///
/// beacon.app(init, beacon.no_local, beacon.no_server, update, view)
/// |> beacon.api_routes(fn(req) {
///   case req.method, request.path_segments(req) {
///     http.Post, ["api", "login"] -> Some(handle_login(req))
///     http.Get, ["api", "status"] -> Some(json_ok())
///     _, _ -> None
///   }
/// })
/// |> beacon.start(8080)
/// ```
pub fn api_routes(
  builder: AppBuilder(model, msg),
  handler: fn(request.Request(Connection)) ->
    Option(response.Response(ResponseBody)),
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, api_handler: Some(handler))
}

/// Set WebSocket authentication.
/// Runs before the WebSocket upgrade handshake — can read cookies, headers, etc.
/// Return `Ok(Nil)` to allow the connection, `Error(reason)` to reject with 401.
///
/// ```gleam
/// beacon.app(init, beacon.no_local, beacon.no_server, update, view)
/// |> beacon.ws_auth(fn(req) {
///   case beacon.get_cookie(req, "session_token") {
///     Ok(token) -> validate_session(token)
///     Error(Nil) -> Error("No session cookie")
///   }
/// })
/// |> beacon.start(8080)
/// ```
pub fn ws_auth(
  builder: AppBuilder(model, msg),
  auth_fn: fn(request.Request(Connection)) -> Result(Nil, String),
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, ws_auth: Some(auth_fn))
}

/// Set a request-aware server state initializer.
/// Replaces both `init` and `init_server` with a function that receives the HTTP request
/// from the WebSocket upgrade, so it can read cookies, headers, query params, etc.
///
/// Use with `app` to populate request-aware model/local/server state from
/// session cookies:
///
/// ```gleam
/// beacon.app(init, beacon.no_local, init_server, update, view)
/// |> beacon.ws_init(fn(req) {
///   case beacon.get_cookie(req, "session_token") {
///     Ok(token) -> #(Model(user_id: validate(token)), Nil, init_server())
///     Error(Nil) -> #(Model(user_id: None), Nil, init_server())
///   }
/// })
/// |> beacon.start(8080)
/// ```
///
/// When set, `ws_init` replaces the default init entirely.
pub fn ws_init(
  builder: AppBuilder(model, msg),
  init_fn: fn(request.Request(Connection)) -> model,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, ws_init: Some(init_fn))
}

/// Set a model encoder for model_sync.
/// The encoder serializes the Model to JSON so the server can send
/// authoritative state to the client after model-affecting events.
/// The generated encoder receives the full #(Model, Local, Server) state and
/// excludes private Server fields.
pub fn model_encoder(
  builder: AppBuilder(model, msg),
  encoder: fn(model) -> String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, serialize_model: option.Some(encoder))
}

/// Register an explicit page manifest for the app.
///
/// This is the route declaration API. Each `route.page` entry owns the URL
/// pattern and the message to send when the route is entered.
///
/// ```gleam
/// beacon.app(init, beacon.no_local, beacon.no_server, update, view)
/// |> beacon.route_pages([
///   route.page(
///     "/",
///     fn(r) { RouteChanged(r.path) },
///     fn(model, _route) { home_view(model) },
///   ),
/// ])
/// |> beacon.start(8080)
/// ```
pub fn route_pages(
  builder: AppBuilder(model, msg),
  pages: List(route.Page(model, msg)),
) -> AppBuilder(model, msg) {
  AppBuilder(
    ..builder,
    route_patterns: route.page_patterns(pages),
    on_route_change: Some(fn(resolved) {
      // Invariant: `resolved` is produced by matching `route_patterns`, which
      // are extracted from this same `pages` list. A mismatch means the app
      // builder was corrupted, so startup/navigation must fail loudly.
      let assert Ok(msg) = route.dispatch_page(pages, resolved)
      msg
    }),
  )
}

/// Set the callback that runs before a client-side route transition is applied.
/// This is not called on the initial page load.
pub fn on_route_leave(
  builder: AppBuilder(model, msg),
  handler: fn(route.Route, route.Route) -> effect.Effect(msg),
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, on_route_leave: Some(handler))
}

/// Create a redirect effect — navigates the client to a new URL via pushState.
/// Return this from the `on_update` handler to redirect after login, logout, etc.
/// The effect sends a ServerNavigate message to ONLY the triggering client
/// (not broadcast to all connections).
/// Must be returned from `on_update` so it runs within the connection's effect context.
/// SECURITY: Only use with validated paths. Never pass raw user input.
pub fn redirect(path: String) -> effect.Effect(msg) {
  effect.from(fn(_dispatch) {
    case runtime.get_redirect_target() {
      option.Some(subject) ->
        process.send(subject, transport.SendNavigate(path: path))
      option.None -> {
        log.debug(
          "beacon",
          "No redirect target available (effect ran outside connection context)",
        )
        Nil
      }
    }
  })
}

/// Create a hard redirect effect — navigates via window.location.href (full page reload).
/// Unlike `redirect` (which uses pushState), this triggers a real HTTP request.
/// Use when the browser needs to receive HTTP headers (e.g., Set-Cookie after login).
/// SECURITY: Only relative paths (starting with /) are allowed by the client.
///
/// Returned from the `on_update` handler (the server-side effect handler);
/// `update` stays pure.
/// ```gleam
/// fn after_update(state: #(Model, Nil, Nil), msg: Msg) -> effect.Effect(Msg) {
///   case msg {
///     LoginSuccess(token) -> beacon.hard_redirect("/api/auth/session/" <> token)
///     _ -> effect.none()
///   }
/// }
/// ```
pub fn hard_redirect(path: String) -> effect.Effect(msg) {
  effect.from(fn(_dispatch) {
    case runtime.get_redirect_target() {
      option.Some(subject) ->
        process.send(subject, transport.SendHardNavigate(path: path))
      option.None -> {
        log.debug(
          "beacon",
          "No hard_redirect target available (effect ran outside connection context)",
        )
        Nil
      }
    }
  })
}

/// Set dynamic subscriptions derived from the model.
/// Called after every update. The framework diffs the result against
/// the current subscription set and subscribes/unsubscribes as needed.
/// ```gleam
/// beacon.app(init, beacon.no_local, beacon.no_server, update, view)
/// |> beacon.subscriptions(fn(model) { ["room:" <> model.current_room] })
/// |> beacon.on_notify(fn(topic) { RoomUpdated(topic) })
/// |> beacon.start(8080)
/// ```
pub fn subscriptions(
  builder: AppBuilder(model, msg),
  compute: fn(model) -> List(String),
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, dynamic_subscriptions: Some(compute))
}

/// Set the handler for notifications on dynamically subscribed topics.
/// Receives the topic string so you can distinguish between sources.
pub fn on_notify(
  builder: AppBuilder(model, msg),
  handler: fn(String) -> msg,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, on_notify: Some(handler))
}

/// Set the handler for typed notifications on dynamically subscribed topics.
pub fn on_notification(
  builder: AppBuilder(model, msg),
  handler: fn(Notification) -> msg,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, on_notification: Some(handler))
}

/// Register a server-side effect handler.
/// Runs AFTER update on the server — use for stores, PubSub, BEAM operations.
/// This keeps update() pure (compilable to JS for LOCAL events).
/// ```gleam
/// beacon.app(init, init_local, beacon.no_server, update, view)
/// |> beacon.on_update(fn(state, msg) {
///   case msg {
///     AddCard -> effect.from(fn(_) { store.put(store, "v", ...) })
///     _ -> effect.none()
///   }
/// })
/// |> beacon.start(8080)
/// ```
pub fn on_update(
  builder: AppBuilder(model, msg),
  handler: fn(model, msg) -> effect.Effect(msg),
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, on_update_effect: Some(handler))
}

/// Override security limits for the app.
/// Use `transport.default_security_limits()` as a starting point and modify fields.
///
/// Example:
/// ```gleam
/// beacon.app(init, beacon.no_local, beacon.no_server, update, view)
/// |> beacon.security_limits(transport.SecurityLimits(
///   ..transport.default_security_limits(),
///   max_connections: 5000,
///   max_events_per_second: 100,
/// ))
/// |> beacon.start(8080)
/// ```
pub fn security_limits(
  builder: AppBuilder(model, msg),
  limits: transport.SecurityLimits,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, security_limits: limits)
}

/// Set the secret key for session tokens.
pub fn secret_key(
  builder: AppBuilder(model, msg),
  key: String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, secret_key: key)
}

/// Add a middleware to the pipeline.
pub fn with_middleware(
  builder: AppBuilder(model, msg),
  mw: middleware.Middleware,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, middlewares: list_append(builder.middlewares, [mw]))
}

/// Enable static file serving from a directory.
pub fn static_dir(
  builder: AppBuilder(model, msg),
  dir: String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, static_dir: Some(dir))
}

/// Enable state recovery on WebSocket reconnect.
pub fn with_state_recovery(
  builder: AppBuilder(model, msg),
  serialize: fn(model) -> String,
  deserialize: fn(String) -> Result(model, String),
) -> AppBuilder(model, msg) {
  AppBuilder(
    ..builder,
    serialize_model: Some(serialize),
    deserialize_model: Some(deserialize),
  )
}

/// Start the app on the given port. Blocks forever.
pub fn start(
  builder: AppBuilder(model, msg),
  port: Int,
) -> Result(Nil, error.BeaconError) {
  log.configure()
  // Validate required functions before doing any work.
  // Both init and update must be provided (either simple or effect variant).
  let wrapped_init = case builder.init_effect {
    Some(init_fn) -> Ok(init_fn)
    None ->
      case builder.init_simple {
        Some(init_fn) -> Ok(fn() { #(init_fn(), effect.none()) })
        None ->
          Error(error.ConfigError(
            reason: "No init function provided — use beacon.app()",
          ))
      }
  }
  let base_update = case builder.update_effect {
    Some(update_fn) -> Ok(update_fn)
    None ->
      case builder.update_simple {
        Some(update_fn) ->
          Ok(fn(model, msg) { #(update_fn(model, msg), effect.none()) })
        None ->
          Error(error.ConfigError(
            reason: "No update function provided — use beacon.app()",
          ))
      }
  }
  // Return early if validation failed
  case wrapped_init, base_update {
    Error(err), _ -> {
      log.error("beacon", "Configuration error: " <> error.to_string(err))
      Error(err)
    }
    _, Error(err) -> {
      log.error("beacon", "Configuration error: " <> error.to_string(err))
      Error(err)
    }
    Ok(init_fn), Ok(update_fn) ->
      start_validated(builder, port, init_fn, update_fn)
  }
}

/// Internal: start the app after validation passes. The server codec and the
/// client bundle are build artifacts of `gleam run -m beacon/build` (or
/// `gleam run -m beacon/dev`); starting without them is an error.
fn start_validated(
  builder: AppBuilder(model, msg),
  port: Int,
  wrapped_init: fn() -> #(model, effect.Effect(msg)),
  base_update: fn(model, msg) -> #(model, effect.Effect(msg)),
) -> Result(Nil, error.BeaconError) {
  let checked = case require_client_bundle() {
    Ok(Nil) -> runtime.verify_generated_contract()
    Error(err) -> Error(err)
  }
  case checked {
    Error(err) -> {
      log.error("beacon", error.to_string(err))
      Error(err)
    }
    Ok(Nil) ->
      start_with_verified_contract(builder, port, wrapped_init, base_update)
  }
}

fn start_with_verified_contract(
  builder: AppBuilder(model, msg),
  port: Int,
  wrapped_init: fn() -> #(model, effect.Effect(msg)),
  base_update: fn(model, msg) -> #(model, effect.Effect(msg)),
) -> Result(Nil, error.BeaconError) {
  // If on_update_effect is set, chain it after the base update
  let wrapped_update = case builder.on_update_effect {
    None -> base_update
    Some(on_update_fn) -> fn(model, msg) {
      let #(new_model, base_effect) = base_update(model, msg)
      let extra_effect = on_update_fn(new_model, msg)
      #(new_model, effect.batch([base_effect, extra_effect]))
    }
  }
  let config =
    application.AppConfig(
      port: port,
      init: wrapped_init,
      update: wrapped_update,
      view: builder.view,
      decode_event: None,
      secret_key: builder.secret_key,
      title: builder.title,
      serialize_model: builder.serialize_model,
      deserialize_model: builder.deserialize_model,
      middlewares: builder.middlewares,
      static_dir: builder.static_dir,
      route_patterns: builder.route_patterns,
      on_route_change: builder.on_route_change,
      on_route_leave: builder.on_route_leave,
      dynamic_subscriptions: builder.dynamic_subscriptions,
      on_notify: builder.on_notify,
      on_notification: builder.on_notification,
      security_limits: builder.security_limits,
      head_html: builder.head_html,
      api_handler: builder.api_handler,
      ws_auth: builder.ws_auth,
      init_from_request: case builder.ws_init {
        Some(ws_init_fn) -> Some(fn(req) { #(ws_init_fn(req), effect.none()) })
        None -> None
      },
      dev_mode: builder.dev_mode,
    )
  case application.start(config) {
    Ok(_app) -> {
      log.info("beacon", "Running at http://localhost:" <> int.to_string(port))
      application.wait_forever()
      Ok(Nil)
    }
    Error(err) -> Error(err)
  }
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

fn list_append(a: List(x), b: List(x)) -> List(x) {
  do_list_append(a, b)
}

@external(erlang, "lists", "append")
fn do_list_append(a: List(x), b: List(x)) -> List(x)

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
