# Beacon Phase 2 (WS7) public API redesign

Status: accepted design (Milestone 117, WS7). Decisions in section 9 are recorded at the end of this file. The core change: `update` becomes server-only and returns effects, client-only state gets its own small update function, and the codegen decides what goes to the browser by following references from `view` instead of matching names. Five decisions are listed in section 9; the rest of the plan assumes the recommendations unless the decision record at the end says otherwise.

A few things I could not read, so the design rests on assumptions:
- I did not read `docs/COMPONENTS.md`, `HTML_ELEMENTS.md`, `STATE_MANAGEMENT.md`, `EFFECTS.md`, `ROUTING.md` or the Lustre/LiveView sources. The patterns below follow their published APIs from memory.
- The routing-convention doc linked from CLAUDE.md does not exist, and no route generator exists in `src/`. Only `docs/ROUTING.md` does.

## 1. Two findings that shape the design

**Effects cannot run in the browser.** `src/beacon/effect.gleam` uses Erlang-only FFI (`beacon_effect_ffi`: timers, spawn, keyed processes). So "update returns `#(model, Effect(msg))` everywhere" means update runs only on the server. Today the client runs `update` itself for instant feedback whenever the app has no `Server` type (`include_update = !analysis.has_server`). That has to stop. Instant, client-side UI moves to the Local layer, which is the LiveView model: the server owns the state, and client-side behaviour is opt-in.

**The client bundle is chosen by guesswork.** `analyzer.gleam` decides what is server-only using:
- names: `Server`, `ServerState`, `init_server`, `server_*` constants;
- `function_references_server_code`, a substring match that even contains example-specific strings (`"openrouter."`, `"agent.new("`, `"run.generate("`, `"Agent("`, `"envoy.get("`);
- `body_modifies_model` / `body_modifies_local`, which inspect `case` arms.

The redesign replaces all of this with reachability: a type or function goes into the JS bundle only if `view`, `init_local` or `update_local` can reach it. That closes the leak risk, and these heuristics are on the point 8 removal list.

## 2. Public module list

Public (documented):
- `beacon` – app constructors, `Context`, builder options, `start`
- `beacon/element` – `Element(msg)`, `element`, `text`, `none`, `keyed`, `memo`, `map`, `to_string`, `unsafe_raw_html`
- `beacon/attribute` – `Attribute(msg)`, `attribute`, `class`, `id`, `href`, `src`, `action`, `value`, `style`, `disabled`, `checked`, `ignore_updates`, `hook`, `watch`, …
- `beacon/event` – `on`, `on_*` helpers, `prevent_default`, `stop_propagation`, `debounce`, `throttle`, payload decoders
- `beacon/html`, `beacon/svg` – tag helpers over `Element(msg)` / `Attribute(msg)`
- `beacon/effect` – unchanged surface (`none`, `from`, `batch`, `map`, `after`, `every`, `keyed`, `cancellable`, `background`); server-only
- `beacon/local` – the client-only state layer
- `beacon/router` – URL helpers and navigation effects; server-only
- Unchanged in shape, retyped to the user's state (no triple): `beacon/api`, `auth`, `cookie`, `session`, `store`, `pubsub`, `middleware`, `static`, `upload`, `form`, `config`, `error`, `error_page`, `log`, `notification`
- Tools, kept public but not imported by apps: `beacon/dev`, `beacon/lint`

Internal (listed in `internal_modules`): `beacon/runtime`, `beacon/transport`, `beacon/transport/*`, `beacon/ssr`, `beacon/patch`, `beacon/build`, `beacon/build/*`, `beacon/application`, `beacon/state_manager`, `beacon/rate_limit`, `beacon/debug`, plus a new `beacon/internal/render` (the walk that produces HTML plus the handler table).

Deleted (only their own tests or nothing import them; checked with grep):
- `beacon/handler` + `beacon_handler_ffi.erl` (used by `src/beacon.gleam` and `ssr.gleam`; replaced)
- `beacon/component`
- `beacon/island` (folded into `attribute.ignore_updates`/`hook`)
- `beacon/state`, `beacon/substate`, `beacon/diff`, `beacon/view`, `beacon/template/*`
- `beacon/stress` + `beacon_stress_ffi.erl` (move to `test/` or a bench example)
- `beacon/examples/todos.gleam`
- `beacon_chat_ffi.erl` (referenced nowhere)
- `beacon_client/src/beacon_client/handler.gleam`
- The hand-written JS `beacon` shim in `build.gleam`

## 3. Key types and signatures

### `beacon/element`
```gleam
pub opaque type Element(msg)        // was element.Node(msg)
pub fn element(tag: String, attrs: List(Attribute(msg)), children: List(Element(msg))) -> Element(msg)
pub fn text(String) -> Element(msg)
pub fn none() -> Element(msg)
pub fn keyed(key: String, child: Element(msg)) -> Element(msg)
pub fn memo(key: String, deps: List(String), child: Element(msg)) -> Element(msg)
pub fn unsafe_raw_html(html: String) -> Element(msg)   // renamed from RawHtml
pub fn map(el: Element(a), f: fn(a) -> b) -> Element(b)  // maps every event handler
pub fn to_string(el: Element(msg)) -> String
```

### `beacon/attribute`
```gleam
pub opaque type Attribute(msg)
// internally: Attr(name, value)
//           | Event(name, handler: Decoder(msg), prevent_default: Bool,
//                   stop_propagation: Bool, debounce_ms: Int, throttle_ms: Int)
pub fn attribute(name: String, value: String) -> Attribute(msg)  // rejects on*, checks URL-bearing names
pub fn href(String) -> Attribute(msg)    // also src, action, formaction, poster, cite
pub fn class(String) / id / name / type_ / value / placeholder
pub fn style(property: String, value: String) -> Attribute(msg)  // Lustre v5 style
pub fn disabled(Bool) / checked(Bool)
pub fn ignore_updates() -> Attribute(msg)      // was beacon.preserve_children (LiveView phx-update="ignore")
pub fn hook(name: String) -> Attribute(msg)    // LiveView phx-hook; island.mount folds into this
pub fn watch(attrs: List(String)) -> Attribute(msg)  // was beacon.hook_watch
pub fn map(Attribute(a), fn(a) -> b) -> Attribute(b)
```

### `beacon/event` (Lustre's `event` module shape)
```gleam
pub fn on(name: String, handler: Decoder(msg)) -> Attribute(msg)
pub fn prevent_default(Attribute(msg)) -> Attribute(msg)
pub fn stop_propagation(Attribute(msg)) -> Attribute(msg)
pub fn debounce(Attribute(msg), ms: Int) -> Attribute(msg)
pub fn throttle(Attribute(msg), ms: Int) -> Attribute(msg)

pub fn on_click(msg) -> Attribute(msg)
pub fn on_mouse_down(msg) / on_mouse_up / on_mouse_enter / on_mouse_leave / on_mouse_over / on_mouse_out
pub fn on_input(fn(String) -> msg)      // target.value
pub fn on_change(fn(String) -> msg)
pub fn on_check(fn(Bool) -> msg)        // target.checked
pub fn on_submit(fn(List(#(String, String))) -> msg)  // calls prevent_default
pub fn on_keydown(fn(String) -> msg) / on_keyup / on_keypress   // event.key
pub fn on_focus(msg) / on_blur(msg)
pub fn on_drag_start(msg) / on_drag_end(msg) / on_drop(msg)
pub fn on_drag_over(msg)                // calls prevent_default

// payload decoders, for use with `on`
pub fn value() -> Decoder(String)
pub fn checked() -> Decoder(Bool)
pub fn key() -> Decoder(String)
pub fn mouse_position() -> Decoder(#(Float, Float))   // offsetX / offsetY
pub fn form_data() -> Decoder(List(#(String, String)))
```

### `beacon/local`
```gleam
pub opaque type Layer(model, local, msg)
pub opaque type Update(local)
pub fn layer(init: fn(model) -> local, update: fn(model, local, msg) -> Update(local)) -> Layer(model, local, msg)
pub fn none() -> Layer(model, Nil, msg)
pub fn handled(local) -> Update(local)  // apply on the client; do NOT send msg to the server
pub fn forward(local) -> Update(local)  // apply on the client AND send msg to the server
```

### `beacon`
```gleam
pub opaque type App(state, model, local, msg)
pub opaque type Context

pub fn uri(Context) -> Uri
pub fn cookie(Context, String) -> Result(String, Nil)
pub fn is_connected(Context) -> Bool     // LiveView connected?/1
pub fn session_id(Context) -> String

// Synced Model only (most apps)
pub fn application(
  init init: fn(Context) -> #(model, Effect(msg)),
  update update: fn(model, msg) -> #(model, Effect(msg)),
  view view: fn(model) -> Element(msg),
) -> App(model, model, Nil, msg)

// All three layers
pub fn full_application(
  init init: fn(Context) -> #(state, Effect(msg)),
  update update: fn(state, msg) -> #(state, Effect(msg)),
  sync sync: fn(state) -> model,           // the part of state sent to the client
  local local: local.Layer(model, local, msg),
  view view: fn(model, local) -> Element(msg),
) -> App(state, model, local, msg)

pub fn with_router(app, parse parse: fn(Uri) -> Result(route, Nil), on_change on_change: fn(route) -> msg) -> App(...)
pub fn title(app, fn(model) -> String) -> App(...)
pub fn subscriptions(app, fn(model) -> List(String)) -> App(...)
pub fn on_notify(app, fn(String) -> msg) / on_notification(app, fn(Notification) -> msg)
// head_html, api_routes, ws_auth, security_limits, secret_key, with_middleware,
// static_dir, dev_mode, with_state_recovery: same as today, retyped
pub fn start(app, port: Int) -> ...   // signature owned by WS1
```

### `beacon/router` (server-only)
```gleam
pub fn segments(Uri) -> List(String)            // percent-decoded
pub fn query(Uri) -> List(#(String, String))    // percent-decoded
pub fn push(path: String) -> Effect(msg)        // LiveView push_patch: history push + on_change
pub fn replace(path: String) -> Effect(msg)
pub fn redirect(url: String) -> Effect(msg)     // full page load (was hard_redirect)
```

## 4. Before / after examples

### Counter: before (current API, abridged)
```gleam
import beacon
import beacon/effect
import beacon/element
import beacon/html

pub type Model { Model(count: Int) }
pub type Msg { Increment Decrement }

pub fn init() { #(Model(0), effect.none()) }

pub fn update(model: Model, _local: Nil, _server: Nil, msg: Msg) -> #(Model, Nil, Nil) {
  case msg {
    Increment -> #(Model(model.count + 1), Nil, Nil)
    Decrement -> #(Model(model.count - 1), Nil, Nil)
  }
}

pub fn view(model: Model, _local: Nil) -> element.Node(Msg) {
  html.div([], [html.button([beacon.on_click(Decrement)], [html.text("-")]), ...])
}

pub fn main() {
  beacon.app(init:, init_local: beacon.no_local, init_server: beacon.no_server, update:, view:)
  |> beacon.title("Counter")
  |> beacon.start(8080)
}
```
The generated codec takes `#(counter.Model, Nil, Nil)`.

### Counter: after
```gleam
import beacon
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/event
import beacon/html
import gleam/int

pub type Model { Model(count: Int) }
pub type Msg { Increment Decrement }

fn init(_ctx: beacon.Context) -> #(Model, Effect(Msg)) {
  #(Model(count: 0), effect.none())
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Increment -> #(Model(count: model.count + 1), effect.none())
    Decrement -> #(Model(count: model.count - 1), effect.none())
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.button([event.on_click(Decrement)], [html.text("-")]),
    html.span([], [html.text(int.to_string(model.count))]),
    html.button([event.on_click(Increment)], [html.text("+")]),
  ])
}

pub fn main() {
  beacon.application(init:, update:, view:)
  |> beacon.title(fn(_) { "Counter" })
  |> beacon.start(8080)
}
```
`view` and `Model` must be `pub`; `init` and `update` may be private because they never go to the client.

### Routed app with a component: before
`examples/routed/src/main.gleam` today has:
- two route tables: `pages()` (`List(route.Page(Model, Msg))` for `dispatch_view`) and `server_pages()` (`List(route.Page(#(Model, Nil, Server), Msg))` for `route_pages`);
- `update_client`, a copy of `update`;
- child views that take `wrap: fn(Msg) -> msg` because `map_node` does not map handlers;
- a stringly-typed `RouteChanged(String)`.

### Routed app with a component: after
`src/app/widget.gleam` (a nested component, Elm/Lustre style):
```gleam
pub type Model { Model(value: Int, step_text: String) }
pub type Msg { Inc StepInput(String) Save }

pub fn init() -> Model { Model(value: 0, step_text: "1") }

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Inc -> case int.parse(model.step_text) {
      Ok(step) -> #(Model(..model, value: model.value + step), effect.none())
      Error(Nil) -> #(model, effect.none())   // shown as invalid in view
    }
    StepInput(text) -> #(Model(..model, step_text: text), effect.none())
    Save -> #(model, save_value(model.value))   // server effect
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.input([attribute.value(model.step_text), event.on_input(StepInput) |> event.debounce(150)]),
    html.button([event.on_click(Inc)], [html.text("+")]),
    html.button([event.on_click(Save)], [html.text("Save")]),
  ])
}
```

`src/app.gleam`:
```gleam
pub type Route { Home Stats User(id: String) }
pub type Model { Model(route: Route, widget: widget.Model, visits: Int) }
pub type Msg { RouteChanged(Route) WidgetMsg(widget.Msg) }

fn parse_route(uri: Uri) -> Result(Route, Nil) {   // the single route declaration
  case router.segments(uri) {
    [] -> Ok(Home)
    ["stats"] -> Ok(Stats)
    ["users", id] -> Ok(User(id))
    _ -> Error(Nil)                                  // SSR 404
  }
}

pub fn href(route: Route) -> String {
  case route {
    Home -> "/"
    Stats -> "/stats"
    User(id) -> "/users/" <> uri.percent_encode(id)
  }
}

fn init(_ctx) -> #(Model, Effect(Msg)) {
  #(Model(route: Home, widget: widget.init(), visits: 0), effect.none())
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RouteChanged(route) -> #(Model(..model, route:, visits: model.visits + 1), effect.none())
    WidgetMsg(child_msg) -> {
      let #(child, eff) = widget.update(model.widget, child_msg)
      #(Model(..model, widget: child), effect.map(eff, WidgetMsg))
    }
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.nav([], [
      html.a([attribute.href(href(Home))], [html.text("Home")]),
      html.a([attribute.href(href(Stats))], [html.text("Stats")]),
    ]),
    case model.route {
      Home -> html.h1([], [html.text("Home")])
      Stats -> html.section([], [
        html.p([], [html.text("Visits: " <> int.to_string(model.visits))]),
        widget.view(model.widget) |> element.map(WidgetMsg),
      ])
      User(id) -> html.p([], [html.text("User " <> id)])
    },
  ])
}

pub fn main() {
  beacon.application(init:, update:, view:)
  |> beacon.with_router(parse: parse_route, on_change: RouteChanged)
  |> beacon.start(8080)
}
```
Like LiveView's mount followed by `handle_params`, the runtime calls `update(model, on_change(route))` right after `init` and before the first render, both for SSR and on connect.

### Three layers together (chat-style app)
```gleam
pub type Session { Session(model: Model, api_key: String, history: List(Turn)) } // server-only
pub type Model { Model(messages: List(String), pending: Bool) }                    // synced
pub type Local { Local(draft: String) }                                            // client-only
pub type Msg { DraftChanged(String) Send(String) GotReply(String) }

fn sync(s: Session) -> Model { s.model }

pub fn init_local(_model: Model) -> Local { Local(draft: "") }

pub fn update_local(_model: Model, l: Local, msg: Msg) -> local.Update(Local) {
  case msg {
    DraftChanged(text) -> local.handled(Local(draft: text))
    Send(_) -> local.forward(Local(draft: ""))
    _ -> local.forward(l)
  }
}

fn update(s: Session, msg: Msg) -> #(Session, Effect(Msg)) { ... }  // GotReply comes from an effect

pub fn view(model: Model, l: Local) -> Element(Msg) {
  html.form([event.on_submit(fn(_) { Send(l.draft) })], [
    html.input([attribute.value(l.draft), event.on_input(DraftChanged)]),
  ])
}

beacon.full_application(init:, update:, sync:, local: local.layer(init: init_local, update: update_local), view:)
```

## 5. How each of the 10 points is met

1. **Typed events.** `Attribute(msg)` / `Element(msg)` are parameterised, and an event holds a `Decoder(msg)`. The process-dictionary registry (`handler.register_simple`, `beacon_handler_ffi`, its JS twin) goes away. Handler ids come from the element's position in the tree (e.g. `0.2.1`), emitted as `data-beacon-on-click="0.2.1"`. Because the same model gives the same ids in SSR and in the client's first render, pre-hydration replay keeps working. The internal render returns `#(html, Dict(id, Handler(msg)))`.
2. **`map` maps handlers.** `element.map` / `attribute.map` rewrite every event decoder with `decode.map`. This replaces `component.map_node` (which today copies attributes unchanged and logs on every call) and removes the `wrap:` parameters. Eager mapping is enough because `MemoNode` already holds a built child.
3. **`update` returns effects everywhere.** Every `update` is `fn(state, msg) -> #(state, Effect(msg))`, including child modules (`effect.map`). `on_update` and the separate pure update are removed. `update_local` is not a model update; it returns `local.Update`.
4. **No triple.** No public type mentions `#(model, local, server)`. Route handling, `ws_init`, subscriptions and the codec all take `model` (or the user's own `state` record). The runtime keeps its own private session record.
5. **Single route declaration.** One user `Route` type, one `parse`, `with_router(parse:, on_change:)`. The route lives in the Model, so the codec encodes it like any custom type. `Page`, `page_model`, `route_pages`, `dispatch_view`, `dispatch_page`, `update_model`, `update_server_model`, `on_route_leave`, guards and layouts are removed.
6. **Typed payloads.** Payloads are decoders run on the client against the real DOM event, using `gleam/dynamic/decode`, which works on JS objects. The hard-coded per-event extraction in `beacon_client_ffi.mjs` (`"x,y"` strings, `data-drag-id`, pointer trail, form snapshot) is removed. Only submit gets help: the client attaches `formData` to submit events, as Lustre does. A decode failure logs a `console.warn` with the event name and errors and drops the event; nothing is silently ignored.
7. **`internal_modules`.** Added to `gleam.toml` with the explicit list in section 2.
8. **Dead and example-only code.** Removed per section 2, plus:
   - `AppBuilder.init_simple` / `update_simple`;
   - the legacy `build_base_client`;
   - `application.AppConfig.decode_event`'s advanced path;
   - `route.RouteGuard`, `RouteDefinition`, `with_layout`, `guarded*`, `match_guarded`, `is_valid_path`;
   - the analyzer's example-specific substrings and name heuristics.
9. **Dangerous URLs.** One `safe_url` check used by `href`, `src`, `action`, `formaction`, `poster`, `cite`, `xlink:href` and by the `attribute()` escape hatch for those names, and checked again in `to_string`.
   - Normalisation: strip leading and trailing whitespace and control characters, remove tab, CR and LF anywhere, lowercase, then read the scheme (text before the first `:` that comes before any `/ ? #`).
   - Allowed: relative URLs, `http`, `https`, `mailto`, `tel`.
   - Not allowed: the attribute is dropped and a `log.warning` records the name and a truncated value. This follows React's blocking of `javascript:` URLs; it is a choice, not a silent fallback.
   - The client gets the same check for free because it renders through the same Gleam code.
   - Remaining hole, by design: `unsafe_raw_html` bypasses all of this.
10. **Examples.** All 24 are migrated (step 10 in section 8). Notable cases:
    - canvas: pointer trail goes into Local, using `mouse_position` with `throttle`;
    - kanban and multi_kanban: `on_drag_start(DragStart(card.id))` / `on_drop(DropOn(col))`;
    - routed, routed_workspace, route_server_workspace, auth_workspace: the new router;
    - private_session, privacy_demo, ai_chat: `full_application` with a Session record;
    - counter_local, local_first_form: the Local layer.

## 6. How the three state layers are expressed

- **Model (synced).** Whatever `sync(state)` returns; for `application` it is the whole state. The server holds it, encodes it in `model_sync`, and the client renders `view` from it. The server is always authoritative.
- **Server (server-only).** Everything in the user's state record that `sync` leaves out. It is never encoded. The codegen can prove this because only types reachable from Model, Local and Msg are emitted. This replaces the `Server` type name, `init_server`, the `server_` prefix and the `ServerState` heuristics. It matches LiveView, where the server holds everything and the client sees only what is rendered.
- **Local (client-only).**
  - `local.layer(init:, update:)` runs only in the browser and is never sent to the server.
  - `update_local` returns `handled` (client only) or `forward` (also send to the server). The `_ -> local.forward(l)` default means a forgotten case just costs a no-op round-trip.
  - This explicit choice replaces the analyzer's "does this case arm change the model" guess and `msg_affects_model`. The precedent is LiveView's split between `JS` commands and `push`.
- **Init.** `init(ctx)` runs for SSR and again on connect, as LiveView mount does. Effects returned during SSR are dropped and logged at debug level; they run on the connected mount.

## 7. Codegen impact (`build.gleam` / `analyzer.gleam`)

1. **Finding the app.** Parse the constructor call in `main` (`application` / `full_application` / `with_router` labels), resolve the named functions, and read the types from their signatures. If something cannot be resolved (for example `view` is not `pub`), fail the build with a clear message; no guessing by name.
2. **Choosing client code by reachability.** Starting from `view`, `init_local` and `update_local`, collect the functions, constants and types they reach across user modules, then their imports. This replaces `server_only_functions`, `function_references_server_code`, `has_server_boundary` and the `include_update` switch. `update`, `init`, `sync` and `parse` are never emitted.
3. **No hand-written shim.** Delete `generate_js_beacon()`. Instead copy the real target-neutral modules: `element`, `attribute`, `event`, `html`, `svg`, `local`, `internal/render`, `log`. `beacon/element`'s Erlang FFI (`beacon_element_ffi.erl`) must get a JS twin or be removed. The analyzer's allowlist (`is_safe_import`) becomes exactly those modules; `beacon`, `beacon/route` and `beacon/effect` become server-only.
4. **Entry point (`generate_entry_point`).** It exports:
   - `render(model, local) -> #(String, Dict(String, Handler(Msg)))`
   - `decode_model`
   - `init_local` / `update_local` (or stubs for `local.none()`)
   - `encode_msg`

   It drops `start_render`, `finish_render`, `resolve_handler`, `view_to_html`, `update`, `msg_affects_model` and `decode_local`.
5. **Client FFI (`beacon_client_ffi.mjs`).**
   - Generic delegation: after each render, add one capture-phase document listener for any new event name in the handler table.
   - Dispatch: find the id on the nearest `data-beacon-on-*` ancestor, apply prevent-default, stop-propagation, debounce and throttle from the handler, run the decoder, then call `update_local` if present and send to the server unless the result is `handled`.
   - Prevent-default before hydration: SSR emits a marker so early submits can still call `preventDefault`.
   - Remove `attachEvents`' hard-coded event list and the per-event payload code.
6. **Codec.** `encode_model` / `decode_model` take `Model`, not a triple. The `Route` type is covered by the existing custom-type codegen, and child Msg types are covered by the existing external-Msg handling.
7. **Server message allowlist.** Derive it: `decode_event` accepts only Msg constructors that appear as expressions (not patterns) in client-reachable code. `GotReply` above can then only come from server effects. `pub type ClientMsg` is removed.
8. **Removed analyzer code.** `classify_variants`, `body_modifies_*`, the `MsgImpact` labels, the computed-field skipping, and the `UpdateSideEffect` / `CapturedUpdateFactory` purity errors. They become unnecessary once update is never compiled to JS.

## 8. Migration list (old → new)

| Old | New |
|---|---|
| `beacon.app(init, init_local, init_server, update, view)` | `beacon.application(init, update, view)` or `beacon.full_application(init, update, sync, local, view)` |
| `beacon.no_local`, `beacon.no_server` | `local.none()`; `sync: function.identity` |
| `update(model, local, server, msg) -> #(m, l, s)` + `on_update(fn(state, msg) -> Effect)` | `update(state, msg) -> #(state, Effect(msg))` + optional `update_local` |
| `init_server: fn() -> server` | fields of the state record, built in `init(ctx)` |
| `ws_init(fn(req) -> triple)`, `beacon.get_cookie` | `init(ctx)` with `beacon.cookie(ctx, name)`, `beacon.is_connected(ctx)` |
| `element.Node(msg)`, `element.Attr`, `HtmlAttr` / `EventAttr` | `element.Element(msg)`, `attribute.Attribute(msg)` (opaque) |
| `html.class` / `href` / `src_` / … | `attribute.class` / `href` / `src` / … |
| `beacon.on_click(msg)`, `on_input(fn)`, `on_keydown(fn)` | `event.on_click`, `event.on_input`, `event.on_keydown` |
| debounce argument / `data-beacon-input-debounce` | `event.debounce(attr, ms)` |
| mouse `"x,y"` strings, pointer trail | `event.on("mousemove", event.mouse_position() \|> decode.map(Moved))` + Local |
| `data-drag-id` drag payloads | typed messages in `on_drag_start` / `on_drop` |
| submit-local `formSnapshot` | `event.on_submit(fn(fields) -> msg)` |
| `beacon.keyed`, `preserve_children`, `hook_watch`, `island.mount` | `element.keyed`, `attribute.ignore_updates`, `attribute.watch`, `attribute.hook` |
| `component.Component` / `render` / `map_node` / `update_component` | plain child modules + `element.map` + `effect.map` |
| `route.page`, `page_model`, `route_pages`, `dispatch_view`, `dispatch_page`, `update_model`, `update_server_model`, `on_route_leave`, `RouteChanged(String)` | `Route` type + `parse` + `with_router(parse:, on_change:)` |
| `route.param` / `query_param` | pattern match on `router.segments` / `router.query` |
| route guards and layouts | middleware (auth) and plain view functions |
| `beacon.redirect` / `hard_redirect` | `router.push` / `replace` / `redirect` |
| `beacon.title(String)` | `beacon.title(fn(model) -> String)` |
| `model_encoder` | removed (codegen) |
| `pub type ClientMsg` | removed (derived allowlist) |
| `subscriptions`, `on_notify`, `on_notification`, `broadcast*` | unchanged, retyped |

## 9. Decisions for you

1. **Losing instant model updates in pure apps.** With update server-only, the counter waits one round-trip per click.
   - Option: keep a Lustre-style `beacon.simple(init, update: fn(model, msg) -> model, view)` that is compiled to JS and applied immediately, with the server confirming. This breaks "effects everywhere".
   - **Recommendation:** no `simple`. Instant UI goes through Local. One rule, and no purity guessing.
2. **How the server-only layer is expressed.**
   - Option A: `sync` projection over a user state record (as designed).
   - Option B: a separate argument, `update(model, server, msg) -> #(model, server, Effect)`.
   - **Recommendation:** A. No tuple, and privacy is provable through reachability. The cost is nested record updates (`Session(..s, model: Model(..s.model, …))`); a small helper per app softens it.
3. **Local-only decision.**
   - Option: explicit `local.handled` / `local.forward`.
   - Option: keep inferring it from `update`'s case arms.
   - **Recommendation:** explicit. It is reliable, removes the most fragile part of the analyzer, and the default of forwarding is safe. The cost is that server `update` needs an empty arm for local-only messages.
4. **Server message allowlist.**
   - Option: derived from client-reachable constructors.
   - Option: keep `pub type ClientMsg`.
   - **Recommendation:** derived. It is secure by default, but needs good analyzer tests for constructors passed as function values (`element.map(_, WidgetMsg)` counts as a reference).
5. **Initial route.**
   - Option: LiveView-style, where `init` sets a placeholder route and `on_change` is dispatched before the first render.
   - Option: `init: fn(Context, route)`, which doubles the constructors.
   - **Recommendation:** LiveView-style.

Smaller choices, with my recommendations:
- **`data:` URLs:** allow `data:image/png|gif|jpeg|webp` in `src` only, never `svg+xml`, and block them in `href`.
- **Moving internals under `beacon/internal/`:** list them explicitly now and move files during the Phase 4 rename, so nothing collides with WS1/WS4. Also check whether Gleam warns when generated user code imports a dependency's internal module. If it does, generated code must import only public modules; the codec already imports only `gleam_json` and `decode`.
- **Pre-hydration events:**
  - Option: queue the event and a snapshot of the common fields (`target.value`, `checked`, `key`, offsets, form data), then replay through the decoders after hydration if the id still exists. This needs position-based ids and coordination with WS3.
  - Option: drop pre-hydration events (LiveView behaviour).
  - **Recommendation:** queue and replay.
- **Stateful LiveView-style live components** (runtime-owned child state): defer; nested child modules cover today's uses.

## 10. Implementation plan (one implementer, green at each step)

0. **Prepare.**
   - Rebase onto the WS1 and WS4 merges; WS4 rewrites `build.gleam`, so steps 3 and 6 must come after it.
   - Record a baseline: `gleam build` (zero warnings), `gleam test`, and builds of the counter and routed examples.
   - Use counter and routed as canary examples at every step; migrate the rest in step 10.
1. **URL filter.** Add `safe_url` to the current `element`/`html` code, in both attribute construction and `to_string`.
   - Tests: `javascript:`, `JaVaScRiPt:`, leading spaces, `java\tscript:`, `vbscript:`, `data:text/html` blocked; relative, `http(s)`, `mailto`, `tel` and allowed `data:image` kept; the escape hatch is covered; a warning is logged.
2. **Typed rendering core.**
   - Add `attribute`, `event` and `Element(msg)` with decoder events, `element.map` / `attribute.map`, and `internal/render` with position-based ids.
   - Retype `html` and `svg`.
   - Tests: render ids are deterministic; running a mapped handler's decoder on a fake event built with `dynamic.properties` yields the mapped message; `on_input`, `on_check`, `on_submit` and `on_keydown` decode correctly; the same tests pass under `gleam test --target javascript`.
3. **Client runtime.**
   - Generic delegation and decoder dispatch in `beacon_client_ffi.mjs`.
   - New entry point; copy the real modules and delete `generate_js_beacon`.
   - Early-event snapshot and replay.
   - Tests: JS unit tests for dispatch, prevent-default, debounce and throttle; browser end-to-end tests on counter (click, typing, early click before hydration).
4. **Remove the server handler registry.** SSR uses the new render; delete `handler.gleam`, `beacon_handler_ffi.erl` and the JS handler module.
   - Tests: SSR HTML ids match the client's first render for the same model.
5. **App constructors and runtime.**
   - `application` / `full_application`, `Context`, the local layer, effects returned from `update`, effects dropped during SSR.
   - Remove `on_update`, `ws_init`, the triple, `init_simple` and `update_simple`.
   - Tests: effects run after update; SSR drops effects; `handled` messages never reach the server and `forward` ones do; the `model_sync` JSON never contains Session fields.
6. **Codegen.**
   - Find the app from the constructor call; reachability-based client code; codec over Model only; derived message allowlist.
   - Delete `classify_variants` and the string heuristics, including the example-specific strings.
   - Tests: analyzer fixtures for a secret constant used only in `update` (not emitted), the Session type (not emitted), `GotReply` (rejected by `decode_event`), a non-`pub` view (build error), and a child Msg reached through `element.map(_, WidgetMsg)` (accepted).
7. **Router.**
   - `beacon/router`, `with_router`, `on_change` dispatched before the first render, SSR 404 through `error_page`, navigation effects, and a hard navigation for unknown routes on the client.
   - Delete the `Page` code and dead guard code from `route.gleam`.
   - Tests: percent-decoding, 404 status, ordering of `on_change` relative to `init`, browser end-to-end navigation on routed.
8. **Components.** Delete `component.gleam` and rewrite `docs/COMPONENTS.md` around nested child modules.
   - Tests: a parent/child update with `effect.map`.
9. **Clean-up.**
   - Add `internal_modules`.
   - Delete the dead modules and FFI files after a final grep: `beacon_chat_ffi.erl`, `stress.gleam` plus `beacon_stress_ffi.erl` (moved to `test/`), `examples/todos.gleam`, `state`, `substate`, `diff`, `view`, `template/*`, `island`, and their tests.
   - Tests: zero-warning build; `gleam docs build` shows only public modules.
10. **Examples.** Migrate all 24, simplest first: counter, counter_local, todo, triple_counter, multi_todo, cart, local_first_form, dashboard, spreadsheet, kanban, multi_kanban, snake, pong, canvas, chat, domains, middleware_demo, privacy_demo, private_session, auth_workspace, routed, routed_workspace, route_server_workspace, ai_chat.
    - Each must build its client bundle and pass a smoke test (SSR 200 plus one event round-trip).
11. **Docs.** Rewrite `GETTING_STARTED.md`, `STATE_MANAGEMENT.md`, `EFFECTS.md`, `ROUTING.md`, `HTML_ELEMENTS.md`, `SECURITY.md` (URL policy and `unsafe_raw_html`) and `ARCHITECTURE.md`; mark Milestone 117 done in `PROGRESS.md`.

### Critical Files for Implementation
- /Users/samb/Documents/Repositories/Personal/beacon/.claude/worktrees/distracted-robinson-07e77d/src/beacon/element.gleam
- /Users/samb/Documents/Repositories/Personal/beacon/.claude/worktrees/distracted-robinson-07e77d/src/beacon.gleam
- /Users/samb/Documents/Repositories/Personal/beacon/.claude/worktrees/distracted-robinson-07e77d/src/beacon/build/analyzer.gleam
- /Users/samb/Documents/Repositories/Personal/beacon/.claude/worktrees/distracted-robinson-07e77d/src/beacon/build.gleam
- /Users/samb/Documents/Repositories/Personal/beacon/.claude/worktrees/distracted-robinson-07e77d/beacon_client/src/beacon_client_ffi.mjs
## Decision record (2026-11-02)

User decisions on section 9:

1. **Instant UI: also offer `beacon.simple`.** This overrides the recommendation.
   - Add a Lustre-style `beacon.simple(init: fn(Context) -> model, update: fn(model, msg) -> model, view: fn(model) -> Element(msg))`.
   - The codegen compiles `update` to JS and applies it in the browser immediately. The message is still sent to the server, which runs the same pure `update` and stays authoritative: if the client and server models differ, the server's `model_sync` wins, and the mismatch is logged on the client.
   - `simple` has no effects and no server-only state. Anything that needs effects uses `application` or `full_application`.
   - The analyzer must prove that a `simple` app's `update` is client-safe: it may reach only the client-safe module allowlist (the same reachability walk as `view`). Anything else is a hard build error naming the call, never a guess.
   - `application` and `full_application` keep a server-only `update` that returns effects.
2. **Server-only state: state record + `sync`** (recommendation adopted).
3. **Local-only decision: explicit `local.handled` / `local.forward`** (recommendation adopted).
4. **Server message allowlist: derived** (recommendation adopted). For `simple` apps, every Msg constructor reachable from `view` is allowed.
5. **Initial route: LiveView-style** (recommendation adopted).

The smaller choices follow the recommendations:
- `data:image/*` (but not svg) is allowed in `src` only.
- Internal modules are listed now and moved during the rename.
- Pre-hydration events are queued and replayed.
- Live components are deferred.

## Implementation notes

Where the code forced a choice the design did not make, WS7 picked the option closest to the design's intent. Each choice is listed here.

### Public API

- **`attribute.styles(List(#(String, String)))`.** Added next to `attribute.style`, as in Lustre, because the examples set many properties at once.
- **`api.Request` and `api.Response`.** These are aliases for `request.Request(Connection)` and `response.Response(ResponseBody)`, as `wisp.Request` and `wisp.Response` are. `beacon.api_routes`, `beacon.ws_auth` and the examples use them. They are the same types `middleware.Middleware` takes, so no example imports `beacon/transport/server`. `beacon/transport` itself stays public, because the middleware and auth APIs still expose its types.
- **`Context.session_id` returns `Result(String, Nil)`, not `String`.** Without a session cookie there is no id. An app that needs a per-tab key makes its own: `cart` uses a random id.
- **`beacon.title(fn(model) -> String)` is used only for SSR.** The client does not update `document.title`.
- **`init` has no error channel.** `init_from_session` crashes the session when the store is unavailable, through a helper that logs first, with no guest fallback. The cheap fix would be `init: fn(Context) -> Result(model, InitError)`, with an `Error` answered as a 503 on SSR and a close on the WebSocket. That would change three constructor signatures, so it is left for WS10 to decide.
  - **Resolved in WS8b.** All three constructors, `simple` included, take `init: fn(Context) -> Result(_, InitError)`. An `Error` is answered on the dead render with its status and closes the WebSocket with `4000 + status`; a crash is a 500 or a 1011 close. `init_from_session` returns `error.unavailable` on a store outage. See ERROR_HANDLING.md.
- **Unknown route at start.** A `with_router` parse error on the first request is a 404 SSR response. Bad percent-encoding is a 400.
- **Default middleware.** `[middleware.secure_headers()]` is on unless replaced.
- **`beacon.start` reads no environment variables.** Reading `PORT` or `SECRET_KEY` inside `start` would hide configuration in the framework. Apps call `config.port()` and `config.secret_key()` themselves, and both return a `Result`. The docs show this with `let assert` and a reason.
- **Examples need `-m <module>`.** An example's entry module is the module that calls a constructor, and it is not always named after the package (`app`, `main`, `todo_app`). Each README says which module to run.

### Analyzer and codegen

- The analyzer finds the app from the constructor call, and requires `view` to be `pub`. For `simple`, `update` must be `pub` too, because the generated JS entry imports it.
- A Msg constructor with a framework-typed field (`Context`, `Effect`, a store) is a build error naming the field. Such a value cannot cross the wire.
- The allowlist is the closure of Msg constructors reachable from `view` (and the local layer's view-side update), not every constructor of the Msg type. The analyzer also walks the Model's type closure, so the codec never encodes a server-only type.
- The JS entry wraps handlers in generic functions instead of generating one per handler.
- `decode_event` returns `Result(msg, String)`. The runtime wraps the String in its own error type and logs it.

### Client runtime

- **Synchronous render.** The client renders after each event, without `requestAnimationFrame` batching, as Lustre does in its default mode. `docs/PROGRESS.md` line 3105 still mentions rAF.
- **`stop_propagation` among Beacon handlers.** It works between Beacon handlers on ancestor elements. Delegation is at the root, so it cannot stop a native listener that a page adds elsewhere.
- **Debounce.** A debounced event decodes when it fires, not when the timer ends. The decoder sees the real event object, which the browser may recycle later.
- **Packaging.** `beacon_client/` is a plain JS directory, not a Gleam package. `start(App)` replaces auto-boot, so the generated entry decides when to start.
- **Held server state.** Only a `simple` app holds server patches while its own events are unacknowledged. Held patches still advance the patch cache, so the next diff applies. `application` apps render server state as it arrives.
- **Focused inputs.** A focused input keeps what the user typed until the server acknowledges the event (LiveView's rule). A focused control that the morph replaces is refocused by `name`.
- **Autofocus.** The client honours `autofocus` after each render, because a morph does not trigger the browser's own autofocus.
- **Mount frame.** The client logs a server `mount` frame as an unsupported error rather than ignoring it silently.
- **Follow-up: build id.** A tab opened before a rebuild can receive a `model_sync` from a new Model shape. A build-id handshake is left for WS10.

### Server and runtime

- The SSR fallback to `priv/static` was removed. When the build manifest is missing, the server answers with a static 500 page and logs the path it looked for.
- Store writes before `beacon.start` crash, because the store's process does not exist yet. Examples seed shared state as constants replayed on read (see `kanban`'s `starting_board`), not with startup writes.
- `beacon.start` returns an `Error` when it fails, but `gleam run` still exits 0 when `main` drops the result, as the examples do. Making `start` crash, or documenting `let assert`, is a WS10 follow-up.

### Examples

- **`triple_counter`** is a `full_application`, not `simple`, because it persists counts and `simple` has no effects.
- **Shared state.** `todo`, `triple_counter`, `cart`, `kanban` and the snake high scores use append-only store logs, replayed on read. `spreadsheet` stores one key per cell. The store has no atomic read-modify-write, so a read-then-write would lose concurrent updates.
- **`dashboard`** reads VM metrics through its own FFI, not `beacon/debug`, which is internal.
- **`kanban`.** The server remembers the dragged card between `DragStart` and `DropOn`, because a drop event cannot carry it.
- **`pong`** runs its loop on a keyed `effect.after`, so pressing Start twice keeps one loop.
- **`canvas`** derives stroke numbering from pen-up events instead of a counter.
- **`chat`** uses `beacon/presence`. This argues for keeping `presence` public.
- **`privacy_demo`** drops computed fields and the `server_` naming convention. Privacy now comes from reachability, so the demo shows a Session field that never reaches the bundle.
- **`ai_chat`** streams with `effect.background`. A stream that sends no chunk for 5 s ends with `StreamError`, and a `notice` field shows refusals.
- **`routed_workspace`** keeps the `Route` in the Model and validates params in `parse`.
- **`route_server_workspace`** folds the separate server update into one page `update(model, server, msg)`.
- **Pages keyed by route.** `routed`, `routed_workspace` and `route_server_workspace` wrap the page in `element.keyed(href(route), ...)`. Without a key, the morph reuses one page's nodes for the next page by position. Focus and input state carry over, and the moved nodes show up as layout shift. ROUTING.md documents the pattern. A follow-up could have the client key the root on navigation by itself.
- **`auth_workspace` WebSocket auth.** `auth.protect_ws` refuses guest sockets. On a page that guests may open, a revoked or missing session would then make the client reconnect forever. The example wraps `protect_ws` in a `ws_auth` that sends a signed-in request through `protect_ws`, connects a request with no live signed-in session as a guest, and refuses the socket when the store is unavailable. An `auth.allow_guests_ws` helper in `beacon/auth` (owned by ws8b) would remove the wrapper.

### Tooling

- Test log capture for my modules lives in `test/beacon_own_log_capture_ffi.erl`. It forwards only the events the calling process logs, so tests running in parallel do not see each other's lines. WS8a's `beacon_log_capture_ffi.erl` is unchanged.
- `test_all_cdp.py` finds buttons by text, because handler ids are positional and internal. Forms are submitted through their submit button.
- `test_all_cdp.py` ignores the browser's automatic `/favicon.ico` 404, because the examples ship no favicon. Every other failed request is still an error, reported with its URL. A layout-shift failure reports its `sources` so the shifted node is named.
- **Step 11 docs.** `STATE_MANAGEMENT.md` is on the step 11 list but belongs to ws8b, so WS7 did not rewrite it. GETTING_STARTED, ROUTING, EFFECTS, HTML_ELEMENTS, SECURITY and ARCHITECTURE were rewritten.

### Candidates for `internal_modules`

These modules are public now but have no documented use outside Beacon: `presence` (although `chat` uses it), `store/crdt`, `hlc` and `replicated`. `beacon_middleware_ffi.erl` is dead code, and so is a `data-beacon-auto` check left in `transport`.
