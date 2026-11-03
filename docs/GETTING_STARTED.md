# Getting Started with Beacon

Beacon is a full-stack Gleam web framework on the BEAM. Each browser tab is
one server process running a Model-View-Update loop; the browser receives the
model over a WebSocket and renders it with JavaScript compiled from your
`view`.

## Quick Start

### 1. Create a new Gleam project

```bash
gleam new my_app
cd my_app
```

### 2. Add Beacon as a dependency

```bash
gleam add beacon
```

### 3. Write your app

```gleam
// src/my_app.gleam
import beacon
import beacon/element.{type Element}
import beacon/event
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Decrement
}

fn init(_ctx: beacon.Context) -> Result(Model, beacon.InitError) {
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
  beacon.simple(init:, update:, view:)
  |> beacon.title(fn(_model) { "My Counter" })
  |> beacon.start(8080)
}
```

### 4. Run it

During development, run dev mode. It builds the app, starts it, and rebuilds
whenever a `.gleam` file changes:

```bash
gleam run -m beacon/dev
```

To run without dev mode, build first and then run. `beacon.start` refuses to
start without the build's output:

```bash
gleam run -m beacon/build
gleam run
```

Open http://localhost:8080 in your browser.

## Three Constructors

Pick the smallest constructor that fits the app. All three take labelled
arguments and return an `App` that the builder functions below configure.

| Constructor | `init` | `update` | `view` | Use when |
|---|---|---|---|---|
| `beacon.simple(init:, update:, view:)` | `fn(Context) -> Result(model, InitError)` | `fn(model, msg) -> model` | `fn(model) -> Element(msg)` | The update is pure and safe to run in the browser |
| `beacon.application(init:, update:, view:)` | `fn(Context) -> Result(#(model, Effect(msg)), InitError)` | `fn(model, msg) -> #(model, Effect(msg))` | `fn(model) -> Element(msg)` | The update needs effects or must stay on the server |
| `beacon.full_application(init:, update:, sync:, local:, view:)` | `fn(Context) -> Result(#(state, Effect(msg)), InitError)` | `fn(state, msg) -> #(state, Effect(msg))` | `fn(model, local) -> Element(msg)` | The server keeps private state, or the browser keeps per-tab state |

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
  beacon.full_application(
    init:,
    update:,
    sync:,
    local: local.layer(init: init_local, update: update_local),
    view:,
  )
  |> beacon.start(8080)
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

### The `Context`

`init` receives a `beacon.Context` describing the request:

- `beacon.uri(ctx)`: the requested URL.
- `beacon.cookie(ctx, name)`: a request cookie, `Result(String, Nil)`.
- `beacon.is_connected(ctx)`: `False` on the HTML render, `True` on the
  WebSocket mount.
- `beacon.session_id(ctx)`: the Beacon session id, `Result(String, Nil)`.

`init` runs twice: once for the HTML render and once when the WebSocket
connects. Effects returned from the HTML render are dropped, so a timer or a
subscription starts once, on the connected mount.

### Refusing in `init`

`init` returns `Error(InitError)` when it cannot build the page, for example
when a database it reads is down. Build the error with `beacon/error`:

```gleam
import beacon/error

fn init(ctx: beacon.Context) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  case orders.load(ctx) {
    Ok(orders) -> Ok(#(Model(orders:), effect.none()))
    Error(orders.DatabaseDown(reason)) -> Error(error.unavailable(reason))
    Error(orders.NotAMember) -> Error(error.refuse(403, "not a member"))
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
browser reloads the page on 4401 and reconnects with backoff on other codes.

A crash in `init` is not a refusal: the HTML render answers 500 and the
WebSocket closes with 1011 `startup failure`.

### Events

Event handlers live in `beacon/event`:

```gleam
html.input([attribute.value(model.name), event.on_input(SetName)])
html.form([event.on_submit(Submitted)], [
  html.input([attribute.name("title")]),
  html.button([attribute.type_("submit")], [html.text("Save")]),
])
```

`event.on_submit(fn(List(#(String, String))) -> msg)` prevents the browser's
form submission and delivers the form's current fields. Every message
constructor that `view` can produce is accepted from the browser; any other
message is refused as a forged event.

## Routing

```gleam
fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case router.segments(uri) {
    [] -> Ok(HomePage)
    ["users", id] -> Ok(UserPage(id:))
    _ -> Error(Nil)
  }
}

beacon.application(init:, update:, view:)
|> beacon.with_router(parse: parse_route, on_change: RouteChanged)
|> beacon.start(8080)
```

Beacon dispatches `on_change(route)` after `init` and on every client
navigation, answers URLs `parse` rejects with 404, and intercepts same-origin
links. `router.push`, `router.replace` and `router.redirect` navigate from
`update`. See [ROUTING.md](ROUTING.md).

## Shared State (Stores)

Per-session state lives in the model. State that several sessions share
lives in a `beacon/store`, and sessions subscribe to its topic:

```gleam
let shared = store.new("counter")

beacon.application(init:, update:, view:)
|> beacon.subscriptions(fn(_model) { [store.topic(shared)] })
|> beacon.on_notify(fn(_topic) { CounterChanged })
|> beacon.start(8080)
```

Write to the store from an effect, so the write runs on the server:

```gleam
Increment -> #(model, effect.from(fn(_dispatch) { store.put(shared, "count", model.count + 1) }))
```

`subscriptions(fn(state) -> List(String))` is evaluated after each update, so
a session can join and leave topics as its state changes.
`beacon.broadcast(topic)` notifies subscribers without a store write. See
[STATE_MANAGEMENT.md](STATE_MANAGEMENT.md).

## API Routes

```gleam
import beacon/api
import gleam/json

beacon.application(init:, update:, view:)
|> beacon.api_routes(api.routes([
  api.get("/api/status", fn(_req) {
    api.json_value(200, json.object([#("ok", json.bool(True))]))
  }),
  api.post("/api/webhook", handle_webhook),
]))
|> beacon.start(8080)
```

API routes run **before** page rendering and static files. A method and path
that no route matches falls through to normal page rendering.

For request bodies, use the size-limited helpers:

```gleam
fn handle_greeting(req: api.Request) -> api.Response {
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
pass any `fn(api.Request) -> Option(api.Response)` to `beacon.api_routes`.

## Custom Head HTML

```gleam
beacon.application(init:, update:, view:)
|> beacon.head_html("<link rel='stylesheet' href='/styles.css'>")
|> beacon.start(8080)
```

`beacon.head_html(html_string)` injects trusted content into the `<head>` of
the HTML render. Use it for stylesheets, meta tags or fonts. Never pass user
input to `head_html`.

## Cookies

In `init`, read a cookie with `beacon.cookie(ctx, name)`. In API handlers and
middleware, use `beacon/cookie`:

```gleam
import beacon/cookie

// Read a cookie from a request.
let token = cookie.get(req, "session_token")

// Set a cookie with secure defaults: HttpOnly, Secure, SameSite=Lax, path "/".
let resp = api.text(200, "ok") |> cookie.set_default("session", token)

// Set a cookie with custom options.
let resp =
  api.text(200, "ok")
  |> cookie.set("theme", "dark", cookie.CookieOptions(
    ..cookie.default_options(),
    http_only: False,
  ))

// Delete a cookie set with the default options.
let resp = api.text(200, "ok") |> cookie.delete("session")
```

`cookie.set`, `cookie.set_default` and `cookie.delete` return
`Result(Response, CookieError)`: a name, value or path outside the RFC 6265
character sets is refused and logged, never sent.

## Session Auth

`beacon/auth` provides the standard session shape: an opaque HttpOnly
`beacon_session` cookie, a server-side session store, a CSRF token returned
from login, and WebSocket auth that checks the same session.

```gleam
import beacon/api
import beacon/auth
import beacon/session

pub fn main() {
  let store = session.new_store("my_app_sessions")
  let config = auth.default_session_config()

  beacon.application(init: init(store, config), update:, view:)
  |> beacon.api_routes(auth.session_routes(store, config, authenticate_login))
  |> beacon.ws_auth(auth.allow_guests_ws(store, config))
  |> beacon.start(8080)
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

```gleam
fn init(store, config: auth.SessionConfig) {
  auth.init_from_session(
    store,
    config,
    guest_init: fn(_ctx) { Ok(#(guest_model(), effect.none())) },
    authenticated_init: fn(_ctx, _session, user) {
      Ok(#(signed_in_model(user), effect.none()))
    },
  )
}

beacon.application(init: init(store, config), update:, view:)
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

`beacon.ws_auth(fn(api.Request) -> Result(Nil, String))` runs before the
WebSocket upgrade; `Error(reason)` rejects it with 401.
`auth.protect_ws(store, config)` accepts only a live session and binds the
socket to it: logout, session rotation or expiry closes the socket with code
4401, and the browser reloads the page.

`protect_ws` refuses guests. An app with a guest page must let guest sockets
connect, or the guest page's reconnects are refused forever. Use
`auth.allow_guests_ws(store, config)` instead, next to `init_from_session`:

```gleam
beacon.application(init: init(store, config), update:, view:)
|> beacon.ws_auth(auth.allow_guests_ws(store, config))
```

It binds a signed-in socket to its session as `protect_ws` does, connects a
request with no live signed-in session as a guest, and refuses the socket
when the session store cannot answer. The server still checks every event:
a guest's socket can send only messages that the guest page's `view`
produces, and `update` must refuse signed-in actions from a guest.

## Effects and Async

With `application` and `full_application`, `init` and `update` return
effects:

```gleam
fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
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

```gleam
Saved(user) -> #(model, router.push("/users/" <> user.id))
SignedIn -> #(model, router.redirect("/dashboard"))
```

`router.push` and `router.replace` change the URL without a page load and run
`on_change`. `router.redirect` loads the page, so use it when the browser
must make a real HTTP request, for example to receive a `Set-Cookie` header.
All three take same-origin paths only.

## Production Deployment

### Configuration

`beacon.start(app, port)` uses the port it is given, and signs tokens with
the key from `beacon.secret_key(key)`. Without one it generates a random key
and logs a warning: tokens then stop working after a restart. Read both from
the environment with `beacon/config`:

| Function | Variable | Behaviour |
|----------|----------|-----------|
| `config.port()` | `PORT` | 8080 when unset; an error when not an integer in 0..65535 |
| `config.secret_key()` | `SECRET_KEY` | An error when unset, shorter than the minimum, or the old built-in dev secret |
| `config.is_production()` | `BEACON_ENV` | `True` for `production` or `prod` |

```gleam
pub fn main() {
  let assert Ok(port) = config.port() as "PORT is valid (the error is logged)"
  let assert Ok(key) = config.secret_key() as "SECRET_KEY is set and strong (the error is logged)"
  beacon.simple(init:, update:, view:)
  |> beacon.secret_key(key)
  |> beacon.start(port)
}
```

### Docker

```bash
docker build -t my_app .
docker run -p 8080:8080 -e SECRET_KEY=your-secret my_app
```

### Health Check

`GET /health` returns `{"status":"ok"}` with 200.

See [DEPLOYMENT.md](DEPLOYMENT.md).

## Build Tool

```bash
gleam run -m beacon/build
```

The build finds the app module in `src/`, generates `src/beacon_codec.gleam`
for the model, writes the event contract to `build/beacon_contract.json`, and
compiles the client code to a content-hashed bundle like
`priv/static/beacon_client_HASH.js`. When more than one module could be the
app, name it: `gleam run -m beacon/build -- src/my_app.gleam`. It needs
`node` and `npx`.

Client code is what `view`, a Local layer and a `simple` app's `update`
reach, and the types they use, `Msg` and the Model included. It may use any
package that compiles to JavaScript, but only these Beacon modules:
`beacon/attribute`, `beacon/element`, `beacon/event`, `beacon/html`,
`beacon/local`, `beacon/log`, `beacon/notification`, `beacon/presence/sync`
and `beacon/svg`. Anything else (a store, an effect, the tracker) is a build
error that names the file and line.

On any failure it prints the reason (file and location for parse errors, type
and field for an unsupported model field) and exits with status 1. Run it
before `gleam run` and in every deployment; `beacon.start` never builds.

## Development Mode

```bash
gleam run -m beacon/dev
```

Dev mode is the only place Beacon builds automatically:

- It runs the build, then starts the app module's `main`. If the first build
  fails, dev mode exits with status 1.
- It watches `src/` for `.gleam` changes with `fswatch` (macOS) or
  `inotifywait` (Linux), or polls every 500ms when neither is installed.
- On each change it rebuilds and hot-loads the changed BEAM modules into the
  running app without restarting it.
- A failed rebuild is logged and the app keeps running the last good build.
- Connected browsers are not reloaded automatically yet; refresh the page to
  pick up client-side changes.

## Server Privacy

The JavaScript bundle contains only the code the browser runs: what `view`
reaches, plus `init_local` and `update_local` for a `local.layer`, plus
`update` for `simple`. Anything else, such as server state, database calls,
secrets and the functions that use them, is never compiled to JavaScript.

```gleam
const signing_key = "sk_live_secret_key"   // not reached from view: stays on the server
const app_title = "My App"                 // used by view: in the bundle
```

With `full_application`, the browser receives only what `sync` returns, so
private fields of the server state never leave the server. The build fails
when browser code reaches a server-only module such as `beacon/store` or
`beacon/effect`. See [SECURITY.md](SECURITY.md).
