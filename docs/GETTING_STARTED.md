# Getting Started with Brazier

Brazier is a full-stack Gleam web framework on the BEAM. Each browser tab is
one server process running a Model-View-Update loop; the browser receives the
model over a WebSocket and renders it with JavaScript compiled from your
`view`.

## Quick Start

### 1. Create a new Gleam project

```bash
gleam new my_app
cd my_app
```

### 2. Add Brazier as a dependency

Brazier is not published on Hex (the `brazier` package there is another
project). Clone the repository and depend on the checkout by path in
`gleam.toml`, as the apps in `examples/` do:

```toml
[dependencies]
brazier = { path = "../brazier" }
```

### 3. Write your app

```gleam
// src/my_app.gleam
import brazier
import brazier/config
import brazier/element.{type Element}
import brazier/event
import brazier/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Decrement
}

fn init(_ctx: brazier.Context) -> Result(Model, brazier.InitError) {
  Ok(Model(count: 0))
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    Decrement -> Model(count: model.count - 1)
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.h1([], [html.text("Counter")]),
    html.button([event.on_click(Decrement)], [html.text("-")]),
    html.text(" " <> int.to_string(model.count) <> " "),
    html.button([event.on_click(Increment)], [html.text("+")]),
  ])
}

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let assert Ok(Nil) =
    brazier.simple(init:, update:, view:)
    |> brazier.title(fn(_model) { "My Counter" })
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
```

Every app needs a secret key: `brazier.start` refuses an app without
`brazier.secret_key` and does not generate one. The later samples leave it
out to stay short; see [Configuration](#configuration).

### 4. Run it

Set `SECRET_KEY` first. Keep the same value across restarts, because a new
key invalidates the tokens of open tabs. During development, run dev mode. It
builds the app, starts it, and rebuilds whenever a `.gleam` file changes:

```bash
export SECRET_KEY="$(openssl rand -base64 48)"
gleam run -m brazier/dev
```

To run without dev mode, build first and then run. Without the build's
output, `brazier.start` logs and returns an error that names the missing
artifact, and `main` crashes on it, so `gleam run` exits with status 1:

```bash
gleam run -m brazier/build
gleam run
```

Open http://localhost:8080 in your browser.

## Three Constructors

Pick the smallest constructor that fits the app. All three take labelled
arguments and return an `App` that the builder functions below configure.

| Constructor | `init` | `update` | `view` | Use when |
|---|---|---|---|---|
| `brazier.simple(init:, update:, view:)` | `fn(Context) -> Result(model, InitError)` | `fn(model, msg) -> model` | `fn(model) -> Element(msg)` | The update is pure and safe to run in the browser |
| `brazier.application(init:, update:, view:)` | `fn(Context) -> Result(#(model, Effect(msg)), InitError)` | `fn(model, msg) -> #(model, Effect(msg))` | `fn(model) -> Element(msg)` | The update needs effects or must stay on the server |
| `brazier.full_application(init:, update:, sync:, local:, view:)` | `fn(Context) -> Result(#(state, Effect(msg)), InitError)` | `fn(state, msg) -> #(state, Effect(msg))` | `fn(model, local) -> Element(msg)` | The server keeps private state, or the browser keeps per-tab state |

Every `init` can refuse the request; see [Refusing in `init`](#refusing-in-init).

### `simple`

The build compiles `update` to JavaScript, so an event updates the page at
once. The server runs the same `update` and stays authoritative: when its
model differs from the browser's, the server's model wins and the browser
logs the mismatch. Keep `update` pure; it cannot return effects.

### `application`

`update` runs only on the server and returns effects (see
[EFFECTS.md](EFFECTS.md)). The browser sends each event and renders the model
the server sends back.

### `full_application`

The server holds a `state` that can be larger than the model the browser
sees. `sync(state) -> model` chooses what is sent; everything else stays on
the server. `local` adds client-only state per tab:

<!-- docs-check: wrap
import brazier
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/html
import brazier/local

pub type State {
  State(count: Int, audit_log: List(String))
}

pub type Model {
  Model(count: Int)
}

pub type Msg {
  SetInput(String)
  ToggleMenu
  Increment
  Decrement
}

fn init(_ctx: brazier.Context) -> Result(#(State, Effect(Msg)), brazier.InitError) {
  Ok(#(State(count: 0, audit_log: []), effect.none()))
}

pub fn update(state: State, msg: Msg) -> #(State, Effect(Msg)) {
  case msg {
    Increment -> #(State(..state, count: state.count + 1), effect.none())
    Decrement -> #(State(..state, count: state.count - 1), effect.none())
    SetInput(_) | ToggleMenu -> #(state, effect.none())
  }
}

pub fn sync(state: State) -> Model {
  Model(count: state.count)
}

pub fn view(_model: Model, local: Local) -> Element(Msg) {
  html.text(local.input)
}

{{block}}
-->
```gleam
pub type Local {
  Local(input: String, menu_open: Bool)
}

pub fn init_local(_model: Model) -> Local {
  Local(input: "", menu_open: False)
}

/// Runs in the browser.
pub fn update_local(_model: Model, local: Local, msg: Msg) -> local.Update(Local) {
  case msg {
    SetInput(text) -> local.handled(Local(..local, input: text))
    ToggleMenu -> local.handled(Local(..local, menu_open: !local.menu_open))
    Increment | Decrement -> local.forward(local)
  }
}

pub fn main() {
  brazier.full_application(
    init:,
    update:,
    sync:,
    local: local.layer(init: init_local, update: update_local),
    view:,
  )
  |> brazier.start(8080)
}
```

- `local.handled(local)` applies the new local state and keeps the message in
  the browser: no traffic.
- `local.forward(local)` applies it and also sends the message to the
  server's `update`.
- `local.none()` means no client-only state; `view` then receives `Nil` as
  its second argument.

`init_local` runs once in the browser with the first synced model.
`examples/counter_local` is the complete version of this app.

### Streams

A list that grows without bound, such as a chat log or an agent's output,
does not belong in any of these layers: the server would keep every item
for every session. A stream (`brazier/stream`) holds it instead. `update`
returns ops that insert, update, move or delete items, the runtime sends
each change once, and the browser keeps the items, at most the stream's
limit of them; the server keeps their keys only. A `simple` app cannot fill
one. See [STREAMS.md](STREAMS.md); `examples/timeline` is the complete app.

### The `Context`

`init` receives a `brazier.Context` describing the request:

- `brazier.uri(ctx)`: the requested URL.
- `brazier.cookie(ctx, name)`: a request cookie, `Result(String, Nil)`.
- `brazier.is_connected(ctx)`: `False` on the HTML render, `True` on the
  WebSocket mount.
- `brazier.session_id(ctx)`: the Brazier session id, `Result(String, Nil)`.

`init` runs twice: once for the HTML render and once when the WebSocket
connects. Effects returned from the HTML render are dropped, so a timer or a
subscription starts once, on the connected mount.

### Refusing in `init`

`init` returns `Error(InitError)` when it cannot build the page, for example
when a database it reads is down. Build the error with `brazier/error`:

<!-- docs-check: wrap
{{block}}

pub type Model {
  Model(orders: List(String))
}

pub type Msg {
  Refresh
}

pub type LoadError {
  DatabaseDown(String)
  NotAMember
}

fn load_orders(_ctx: brazier.Context) -> Result(List(String), LoadError) {
  Error(DatabaseDown("connection refused"))
}
-->
```gleam
import brazier
import brazier/effect.{type Effect}
import brazier/error

pub fn init(ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  case load_orders(ctx) {
    Ok(orders) -> Ok(#(Model(orders:), effect.none()))
    Error(DatabaseDown(reason)) -> Error(error.unavailable(reason))
    Error(NotAMember) -> Error(error.refuse(403, "not a member"))
  }
}
```

- `error.unavailable(reason)` refuses with 503.
- `error.refuse(status, reason)` refuses with any status from 400 to 599. A
  status outside that range is a bug in the app, so `refuse` crashes.

The HTML render answers a refusal with a static error page for its status. The
WebSocket mount closes the socket with code `4000 + status`, for example 4503,
and the reason `init refused`. The reason you pass is logged (an error for a
5xx status, a warning for a 4xx one) and never sent to the browser. The
browser reloads the page on a 4xx refusal (4400 to 4499; at most 3 times
within 60 seconds, then it shows an error state) and reconnects with backoff
on other codes, a 5xx refusal included.

A crash in `init` is not a refusal: the HTML render answers 500 and the
WebSocket closes with 1011 `startup failure`.

### Events

Event handlers live in `brazier/event`:

<!-- docs-check: wrap
import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html

pub type Model {
  Model(title: String)
}

pub type Msg {
  SetTitle(String)
  Submitted(List(#(String, String)))
}

{{block}}
-->
```gleam
pub fn view(model: Model) -> Element(Msg) {
  html.form([event.on_submit(Submitted)], [
    html.input([
      attribute.name("title"),
      attribute.value(model.title),
      event.on_input(SetTitle),
    ]),
    html.button([attribute.type_("submit")], [html.text("Save")]),
  ])
}
```

`event.on_submit(fn(List(#(String, String))) -> msg)` prevents the browser's
form submission and delivers the form's current fields. Every message
constructor that `view` can produce is accepted from the browser; any other
message is refused as a forged event.

## Routing

<!-- docs-check: wrap
import brazier
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/router
import gleam/uri.{type Uri}

pub type Route {
  HomePage
  UserPage(id: String)
}

pub type Model {
  Model(route: Route)
}

pub type Msg {
  RouteChanged(Route)
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(route: HomePage), effect.none()))
}

pub fn update(_model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RouteChanged(route) -> #(Model(route:), effect.none())
  }
}

pub fn view(_model: Model) -> Element(Msg) {
  element.text("page")
}

{{block}}
-->
```gleam
pub fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case router.segments(uri) {
    [] -> Ok(HomePage)
    ["users", id] -> Ok(UserPage(id:))
    _ -> Error(Nil)
  }
}

pub fn main() {
  brazier.application(init:, update:, view:)
  |> brazier.with_router(parse: parse_route, on_change: RouteChanged)
  |> brazier.start(8080)
}
```

Brazier dispatches `on_change(route)` after `init` and on every client
navigation, answers URLs `parse` rejects with 404, and intercepts same-origin
links. `router.push`, `router.replace` and `router.redirect` navigate from
`update`. See [ROUTING.md](ROUTING.md).

## Shared State (Stores)

Per-session state lives in the model. State that several sessions share
lives in a `brazier/store`, and sessions subscribe to its topic. Write to
the store from an effect, so the write runs on the server:

<!-- docs-check: wrap
import brazier/element.{type Element}

{{block}}

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  CounterChanged
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(count: 0), effect.none()))
}

pub fn view(_model: Model) -> Element(Msg) {
  element.text("count")
}
-->
```gleam
import brazier
import brazier/effect.{type Effect}
import brazier/store.{type Store}

pub fn main() {
  let shared = store.new("counter")
  brazier.application(
    init:,
    update: fn(model, msg) { update(shared, model, msg) },
    view:,
  )
  |> brazier.subscriptions(fn(_model) { [store.topic(shared)] })
  |> brazier.on_notify(fn(_topic) { CounterChanged })
  |> brazier.start(8080)
}

pub fn update(
  shared: Store(Int),
  model: Model,
  msg: Msg,
) -> #(Model, Effect(Msg)) {
  case msg {
    Increment -> #(
      model,
      effect.from(fn(_dispatch) { store.put(shared, "count", model.count + 1) }),
    )
    CounterChanged ->
      case store.get(shared, "count") {
        Ok(count) -> #(Model(count:), effect.none())
        Error(Nil) -> #(model, effect.none())
      }
  }
}
```

`subscriptions(fn(state) -> List(String))` is evaluated after each update, so
a session can join and leave topics as its state changes.
`brazier.broadcast(topic)` notifies subscribers without a store write. See
[STATE_MANAGEMENT.md](STATE_MANAGEMENT.md).

## API Routes

<!-- docs-check: wrap
import brazier/effect.{type Effect}
import brazier/element.{type Element}

{{block}}

fn handle_webhook(_req: api.Request) -> api.Response {
  api.empty(204)
}

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(count: 0), effect.none()))
}

pub fn update(model: Model, _msg: Msg) -> #(Model, Effect(Msg)) {
  #(model, effect.none())
}

pub fn view(_model: Model) -> Element(Msg) {
  element.text("count")
}
-->
```gleam
import brazier
import brazier/api
import gleam/json

pub fn main() {
  brazier.application(init:, update:, view:)
  |> brazier.api_routes(api.routes([
    api.get("/api/status", fn(_req) {
      api.json_value(200, json.object([#("ok", json.bool(True))]))
    }),
    api.post("/api/webhook", handle_webhook),
  ]))
  |> brazier.start(8080)
}
```

API routes run **before** page rendering and static files. A method and path
that no route matches falls through to normal page rendering.

For request bodies, use the size-limited helpers:

<!-- docs-check: wrap
import brazier/api

{{block}}
-->
```gleam
pub fn handle_greeting(req: api.Request) -> api.Response {
  case api.read_form(req, 4096) {
    Ok(fields) ->
      case api.form_field(fields, "username") {
        Ok(username) -> api.text(200, "hello " <> username)
        Error(reason) -> api.text(400, reason)
      }
    Error(reason) -> api.text(400, reason)
  }
}
```

Use `api.read_text(req, max_bytes)` for raw UTF-8 bodies. For custom matching,
pass any `fn(api.Request) -> Option(api.Response)` to `brazier.api_routes`.

## Custom Head HTML

<!-- docs-check: wrap
import brazier
import brazier/effect.{type Effect}
import brazier/element.{type Element}

pub fn main() {
  {{block}}
}

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(count: 0), effect.none()))
}

pub fn update(model: Model, _msg: Msg) -> #(Model, Effect(Msg)) {
  #(model, effect.none())
}

pub fn view(_model: Model) -> Element(Msg) {
  element.text("count")
}
-->
```gleam
brazier.application(init:, update:, view:)
|> brazier.head_html("<link rel='stylesheet' href='/static/styles.css'>")
|> brazier.start(8080)
```

`brazier.head_html(html_string)` injects trusted content into the `<head>` of
the HTML render. Use it for stylesheets, meta tags or fonts. Never pass user
input to `head_html`. `brazier.static_dir(dir)` serves the files of `dir`
under `/static`, as the stylesheet above expects.

## Cookies

In `init`, read a cookie with `brazier.cookie(ctx, name)`. In API handlers and
middleware, use `brazier/cookie`:

```gleam
import brazier/api
import brazier/cookie

/// Read a cookie from a request.
pub fn theme(req: api.Request) -> Result(String, Nil) {
  cookie.get(req, "theme")
}

/// Set a cookie with secure defaults: HttpOnly, Secure, SameSite=Lax, path "/".
pub fn remember(token: String) -> Result(api.Response, cookie.CookieError) {
  api.text(200, "ok") |> cookie.set_default("remember", token)
}

/// Set a cookie with custom options: this one page scripts may read.
pub fn set_theme(theme: String) -> Result(api.Response, cookie.CookieError) {
  api.text(200, "ok")
  |> cookie.set(
    "theme",
    theme,
    cookie.CookieOptions(..cookie.default_options(), http_only: False),
  )
}

/// Delete a cookie set with the default options.
pub fn forget() -> Result(api.Response, cookie.CookieError) {
  api.text(200, "ok") |> cookie.delete("remember")
}
```

`cookie.set`, `cookie.set_default` and `cookie.delete` return
`Result(Response, CookieError)`: a name, value or path outside the RFC 6265
character sets is refused and logged, never sent.

## Session Auth

`brazier/auth` provides the standard session shape: an opaque HttpOnly
`brazier_session` cookie, a server-side session store, a CSRF token returned
from login, and WebSocket auth that checks the same session.

<!-- docs-check: wrap
import brazier/effect.{type Effect}
import brazier/element.{type Element}

{{block}}

fn init(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> fn(brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  auth.init_from_session(
    store,
    config,
    guest_init: fn(_ctx) { Ok(#(Guest, effect.none())) },
    authenticated_init: fn(_ctx, _session, user) {
      Ok(#(SignedIn(user:), effect.none()))
    },
  )
}

pub type Model {
  Guest
  SignedIn(user: String)
}

pub type Msg {
  Refresh
}

pub fn update(model: Model, _msg: Msg) -> #(Model, Effect(Msg)) {
  #(model, effect.none())
}

pub fn view(_model: Model) -> Element(Msg) {
  element.text("page")
}
-->
```gleam
import brazier
import brazier/api
import brazier/auth
import brazier/session

pub fn main() {
  let store = session.new_store("my_app_sessions")
  let config = auth.default_session_config()

  brazier.application(init: init(store, config), update:, view:)
  |> brazier.api_routes(auth.session_routes(store, config, authenticate_login))
  |> brazier.ws_auth(auth.allow_guests_ws(store, config))
  |> brazier.start(8080)
}

fn authenticate_login(req: api.Request) -> Result(String, String) {
  case api.read_form(req, 4096) {
    Ok(fields) -> api.form_field(fields, "username")
    Error(reason) -> Error(reason)
  }
}
```

`session_routes` serves `POST /api/login`, `GET /api/me` and
`POST /api/logout`. For localhost HTTP development, use
`auth.dev_session_config()` explicitly; the default config keeps the cookie
`Secure`, `HttpOnly` and `SameSite=Lax`.

For custom routes, use `auth.login_route`, `auth.current_user_route`,
`auth.logout_route`, `auth.protect_api` and `auth.protect_api_with_csrf`.
When you write the handlers yourself:

- `auth.login`, `auth.login_rotating`, `auth.create_login` and
  `auth.create_login_rotating` return `Result(_, auth.SessionError)`. A store
  failure is `SessionStoreUnavailable(reason)`; answer it with 503.
- `auth.logout_response` returns `Result(Response, auth.ResponseError)`. On
  `StoreFailed`, answer 503 and keep the cookie: the session may still exist,
  so the browser must not believe it signed out.

### Signed-in first render

`auth.init_from_session` reads the session cookie through the `Context`, so
the HTML render is already signed in:

<!-- docs-check: wrap
import brazier
import brazier/auth
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/session

{{block}}

fn guest_model() -> Model {
  Guest
}

fn signed_in_model(user: String) -> Model {
  SignedIn(user:)
}

pub type Model {
  Guest
  SignedIn(user: String)
}

pub type Msg {
  Refresh
}

pub fn update(model: Model, _msg: Msg) -> #(Model, Effect(Msg)) {
  #(model, effect.none())
}

pub fn view(_model: Model) -> Element(Msg) {
  element.text("page")
}
-->
```gleam
pub fn init(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> fn(brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  auth.init_from_session(
    store,
    config,
    guest_init: fn(_ctx) { Ok(#(guest_model(), effect.none())) },
    authenticated_init: fn(_ctx, _session, user) {
      Ok(#(signed_in_model(user), effect.none()))
    },
  )
}

pub fn app(store: session.SessionStore, config: auth.SessionConfig) {
  brazier.application(init: init(store, config), update:, view:)
}
```

- No cookie, or a cookie that names no live session, renders the guest page.
  A dead session is logged as a warning.
- A store that cannot answer refuses the request with `error.unavailable`:
  the HTML render answers 503 and the WebSocket closes with 4503. A signed-in
  user never sees the guest page because of an outage.
- `authenticated_init` can refuse on its own, for example with
  `error.refuse(403, ..)` for a user who may not see the page.

`examples/auth_workspace` is the complete version.

### WebSocket auth

`brazier.ws_auth(fn(api.Request) -> Result(Nil, String))` runs before the
WebSocket upgrade; `Error(reason)` rejects it with 401.
`auth.protect_ws(store, config)` accepts only a live session and binds the
socket to it: logout, session rotation or expiry closes the socket with code
4401, and the browser reloads the page.

`protect_ws` refuses guests. An app with a guest page must let guest sockets
connect, or the guest page's reconnects are refused forever. Use
`auth.allow_guests_ws(store, config)` instead, next to `init_from_session`:

<!-- docs-check: wrap
import brazier
import brazier/auth
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/session

pub fn app(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> brazier.App(Model, Model, Nil, Msg) {
  {{block}}
}

fn init(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> fn(brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  auth.init_from_session(
    store,
    config,
    guest_init: fn(_ctx) { Ok(#(Guest, effect.none())) },
    authenticated_init: fn(_ctx, _session, user) {
      Ok(#(SignedIn(user:), effect.none()))
    },
  )
}

pub type Model {
  Guest
  SignedIn(user: String)
}

pub type Msg {
  Refresh
}

pub fn update(model: Model, _msg: Msg) -> #(Model, Effect(Msg)) {
  #(model, effect.none())
}

pub fn view(_model: Model) -> Element(Msg) {
  element.text("page")
}
-->
```gleam
brazier.application(init: init(store, config), update:, view:)
|> brazier.ws_auth(auth.allow_guests_ws(store, config))
```

It binds a signed-in socket to its session as `protect_ws` does, connects a
request with no live signed-in session as a guest, and refuses the socket
when the session store cannot answer. The server still checks every event:
a guest's socket can send only messages that the guest page's `view`
produces, and `update` must refuse signed-in actions from a guest.

## Effects and Async

With `application` and `full_application`, `init` and `update` return
effects:

<!-- docs-check: wrap
import brazier/effect.{type Effect}

pub type Model {
  Model(draft: String, saving: Bool, result: Result(Nil, String))
}

pub type Msg {
  Save
  Saved(Result(Nil, String))
}

fn persist(_model: Model) -> Result(Nil, String) {
  Ok(Nil)
}

{{block}}
-->
```gleam
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Save -> #(Model(..model, saving: True), effect.from(fn(dispatch) {
      dispatch(Saved(persist(model)))
    }))
    Saved(result) -> #(Model(..model, saving: False, result:), effect.none())
  }
}
```

- `effect.from(fn(dispatch) { ... })`: run work, dispatch messages back.
- `effect.background(fn(dispatch) { ... })`: run in a spawned process.
- `effect.every(ms, fn() { msg })` and `effect.after(ms, fn() { msg })`:
  timers.
- `effect.keyed`, `effect.cancellable` and `effect.cancel`: replace or stop
  running effects.
- `effect.batch([...])`, `effect.map(effect, f)`, `effect.none()`.

See [EFFECTS.md](EFFECTS.md).

### Navigation

<!-- docs-check: wrap
import brazier/effect.{type Effect}
import brazier/router

pub type User {
  User(id: String)
}

pub type Model {
  Model
}

pub type Msg {
  Saved(User)
  SignedIn
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    {{block}}
  }
}
-->
```gleam
Saved(user) -> #(model, router.push("/users/" <> user.id))
SignedIn -> #(model, router.redirect("/dashboard"))
```

`router.push` and `router.replace` change the URL without a page load and run
`on_change`. `router.redirect` loads the page, so use it when the browser
must make a real HTTP request, for example to receive a `Set-Cookie` header.
All three take same-origin paths only (see
[Navigation Targets](SECURITY.md#navigation-targets)).

## Production Deployment

### Configuration

`brazier.start(app, port)` uses the port it is given, and signs tokens with
the key from `brazier.secret_key(key)`. The key is required. Without one,
`start` logs and returns a `ConfigError` that names `brazier.secret_key` and
`SECRET_KEY`. The same key keys the cluster peer check, so every node of a
deployment must use the same one. Read both from the environment with
`brazier/config`; each function logs and returns an `Error` for a bad value:

| Function | Variable | Behaviour |
|----------|----------|-----------|
| `config.port()` | `PORT` | 8080 when unset; an error when not an integer in 0..65535 |
| `config.secret_key()` | `SECRET_KEY` | An error when unset, shorter than the minimum, or the old built-in dev secret |
| `config.is_production()` | `BRAZIER_ENV` | `True` for `production` or `prod` |

[DEPLOYMENT.md](DEPLOYMENT.md#secret-key) has a `main` that reads both and
stops loudly when either is wrong, and lists the other variables Brazier reads.

### Docker

The repository's `Dockerfile` builds an example app and is a template for
yours; see [DEPLOYMENT.md](DEPLOYMENT.md#docker).

### Health Check

Brazier answers `/health` with 200 and `{"status":"ok"}`. It is a liveness
check only; see [DEPLOYMENT.md](DEPLOYMENT.md#health-check).

## Build Tool

```bash
gleam run -m brazier/build
```

The build finds the app module in `src/`, generates `src/brazier_codec.gleam`
for the model, writes the event contract to `build/brazier_contract.json`, and
compiles the client code to a content-hashed bundle like
`priv/static/brazier_client_HASH.js`. When more than one module could be the
app, name it: `gleam run -m brazier/build -- src/my_app.gleam`. It needs
`node` and `npx`. The client's packages are the versions your app's
`manifest.toml` locks, never resolved again from Hex, so keep that file in
version control.

Client code is what `view`, a Local layer and a `simple` app's `update`
reach, and the types they use, `Msg` and the Model included. It may use any
package that compiles to JavaScript, but only these Brazier modules:
`brazier/attribute`, `brazier/element`, `brazier/event`, `brazier/html`,
`brazier/local`, `brazier/log`, `brazier/notification`, `brazier/presence/sync`
and `brazier/svg`. Anything else (a store, an effect, the tracker) is a build
error that names the file and line.

On any failure it prints the reason (file and location for parse errors, type
and field for an unsupported model field) and exits with status 1. Run it
before `gleam run` and in every deployment; `brazier.start` never builds.

## Development Mode

```bash
gleam run -m brazier/dev
```

Dev mode is the only place Brazier builds automatically:

- It runs the build, then starts the app module's `main`. If the first build
  fails, dev mode exits with status 1.
- It watches `src/` for `.gleam` changes with `fswatch` (macOS) or
  `inotifywait` (Linux, from inotify-tools). When that program is not
  installed, dev mode exits with status 1 and names the package to install.
- On each change it rebuilds and hot-loads the changed BEAM modules into the
  running app without restarting it, then tells every open page to reload.
- A failed rebuild is logged and the app keeps running the last good build.

## Server Privacy

The JavaScript bundle contains only the code the browser runs: what `view`
reaches, plus `init_local` and `update_local` for a `local.layer`, plus
`update` for `simple`. Anything else, such as server state, database calls,
secrets and the functions that use them, is never compiled to JavaScript.

```gleam
import brazier/element.{type Element}
import brazier/html

// Reached only from server code: never in the bundle.
const inventory_service = "http://10.0.0.5:9000/inventory"

// Reached from view: compiled into the bundle.
const app_title = "My App"

pub fn inventory_url(sku: String) -> String {
  inventory_service <> "/" <> sku
}

pub fn view(_model: Nil) -> Element(msg) {
  html.h1([], [html.text(app_title)])
}
```

With `full_application`, the browser receives only what `sync` returns, so
private fields of the server state never leave the server. The build fails
when browser code reaches a server-only module such as `brazier/store` or
`brazier/effect`. See [SECURITY.md](SECURITY.md).
