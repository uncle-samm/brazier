# Getting Started with Beacon

Beacon is a full-stack Gleam web framework that runs on BEAM with client-side local execution.

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
import beacon/effect
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Decrement
}

pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(Model(count: 0), effect.none())
}

pub fn update(
  model: Model,
  _local: Nil,
  _server: Nil,
  msg: Msg,
) -> #(Model, Nil, Nil) {
  case msg {
    Increment -> #(Model(count: model.count + 1), Nil, Nil)
    Decrement -> #(Model(count: model.count - 1), Nil, Nil)
  }
}

pub fn view(model: Model, _local: Nil) -> beacon.Node(Msg) {
  html.div([], [
    html.h1([], [html.text("Counter")]),
    html.button([beacon.on_click(Decrement)], [html.text("-")]),
    html.text(" " <> int.to_string(model.count) <> " "),
    html.button([beacon.on_click(Increment)], [html.text("+")]),
  ])
}

pub fn main() {
  beacon.app(init, beacon.no_local, beacon.no_server, update, view)
  |> beacon.title("My Counter")
  |> beacon.start(8080)
}
```

### 4. Run it

```bash
gleam run
```

Open http://localhost:8080 in your browser.

## Key Concepts

### Model-View-Update (MVU)

Beacon uses the MVU architecture:
- **Model** — your app's state
- **View** — renders the Model to HTML
- **Update** — handles messages and returns new Model

### One App State Shape

Beacon apps are one MVU app with up to three named state areas:

1. **Model** — server-authoritative UI state. It is rendered on the server for
   first paint, then synchronized as JSON patches/syncs.
2. **Local** — optional per-tab client state. Use `pub type Local` for dropdowns,
   drafts, focus state, and other interactions that should not touch the server.
3. **Server** — optional private server state. Use `pub type Server` for session
   IDs, database handles, audit keys, and anything that must not enter the
   client bundle.

Shared state via `store` is separate from per-session app state and is used when
multiple users should see the same data.

Beacon does one full server render for first paint. After the WebSocket joins,
normal updates are model sync/patch messages and the browser renders from the
generated client code. If the generated client renderer cannot be built, startup
fails instead of serving a degraded app.

Live events use a generated event decoder contract. Generated clients
resolve DOM handlers in the browser, encode the typed `Msg`, and the server
decodes that envelope before running the authoritative update. If the generated
contract cannot be built, startup fails; Beacon does not render `view` on the
server to decode events after SSR.

For privileged/internal server messages, add a `ClientMsg` type containing only
the `Msg` variants that may come from browser events:

```gleam
pub type Msg {
  Increment
  AdminReset
}

pub type ClientMsg {
  Increment
}
```

The generated contract will decode browser events into `Increment` only;
`AdminReset` remains server/internal.

The public API uses one constructor:
`beacon.app(init, init_local, init_server, update, view)`. Use
`beacon.no_local` or `beacon.no_server` when a state area is absent.

### Local State (Zero Traffic)

```gleam
pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg {
  Increment        // → changes Model → syncs with server
  SetInput(String) // → changes Local → instant, zero traffic
}

beacon.app(init, init_local, beacon.no_server, update, view)
```

`init_local(model)` receives the initial `Model`, so the first client-only values
can be derived from server-known state without exposing `Server`.

For submit boundaries that depend on current browser draft values, prefer the
snapshot helper:

```gleam
html.form([beacon.on_submit_local(fn(fields_json) { Save(fields_json) })], [
  html.input([html.name("title"), beacon.on_input(SetTitle)]),
])
```

`on_submit_local` sends a live form snapshot as JSON event data. This avoids the
stale-handler bug caused by closing over server-side Local in
`on_submit(Save(local.draft))`.

### Routing

```gleam
fn pages() -> List(route.Page(#(Model, Nil, Nil), Msg)) {
  [
    route.page("/", fn(r) { RouteChanged(r.path) }, fn(_state, _route) { home_view() }),
    route.page("/about", fn(r) { RouteChanged(r.path) }, fn(_state, _route) { about_view() }),
    route.page("/blog/:slug", fn(r) { RouteChanged(r.path) }, fn(state, route) {
      let #(model, _local, _server) = state
      blog_view(model, route)
    }),
  ]
}

pub fn view(model: Model, _local: Nil) -> beacon.Node(Msg) {
  let assert Ok(page) = route.dispatch_view(pages(), #(model, Nil, Nil), model.path)
  page
}

beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.route_pages(pages())
|> beacon.start(8080)
```

Route modules can also own their own state:

```gleam
pub type Model {
  Model(path: String, home: home.Model)
}

pub type Msg {
  RouteChanged(String)
  Home(home.Msg)
}

pub fn update(model: Model, _local: Nil, _server: Nil, msg: Msg) -> #(Model, Nil, Nil) {
  case msg {
    RouteChanged(path) -> #(Model(..model, path: path), Nil, Nil)
    Home(child_msg) -> {
      let model = route.update_model(
        model,
        child_msg,
        fn(model) { model.home },
        fn(model, home) { Model(..model, home: home) },
        home.update,
      )
      #(model, Nil, Nil)
    }
  }
}
```

### Shared State (Stores)

```gleam
let shared = store.new("counter")
store.put(shared, "count", 0)

beacon.app(init, init_local, beacon.no_server, update, view)
|> beacon.subscriptions(fn(_model) { [store.topic(shared)] })
|> beacon.on_notify(fn(_topic) { CounterUpdated })
|> beacon.start(8080)
```

### API Routes

```gleam
import beacon/api
import gleam/json

beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.api_routes(api.routes([
  api.get("/api/status", fn(_req) {
    api.json_value(200, json.object([#("ok", json.bool(True))]))
  }),
  api.post("/api/webhook", handle_webhook),
]))
|> beacon.start(8080)
```

API routes run **before** SSR/static file routing. Unknown method/path combinations fall through to normal page rendering.

For request bodies, prefer the high-level helpers:

```gleam
fn handle_login(req) {
  case api.read_form(req, 4096) {
    Ok(fields) -> {
      case api.form_field(fields, "username") {
        Ok(username) -> api.text(200, "hello " <> username)
        Error(reason) -> api.text(400, reason)
      }
    }
    Error(reason) -> api.text(400, reason)
  }
}
```

Use `api.read_text(req, max_bytes)` for raw UTF-8 bodies. For fully custom
matching, pass a raw `fn(req) -> Option(Response(ResponseBody))` to
`beacon.api_routes`.

### Advanced: Custom Head HTML

```gleam
beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.head_html("<link rel='stylesheet' href='/styles.css'>")
|> beacon.start(8080)
```

`beacon.head_html(html_string)` injects trusted content into the `<head>` of the
SSR page. Use it for static stylesheets, meta tags, or fonts. Do not pass user
input to `head_html`.

### Cookies

```gleam
import beacon/cookie

// Read cookies from a request
let token = cookie.get(req, "session_token")

// Set a cookie on a response (secure defaults: HttpOnly, Secure, SameSite=Lax)
response.new(200)
|> cookie.set_default("session", token)

// Set with custom options
response.new(200)
|> cookie.set("session", token, cookie.CookieOptions(
  max_age: Some(86400),
  path: "/",
  http_only: True,
  secure: False,  // False for local development
  same_site: "Lax",
))

// Delete a cookie
response.new(200)
|> cookie.delete("session")
```

Shorthand: `beacon.get_cookie(req, "name")` is available on the main module.

### Session Auth

Use `beacon/auth` when your app wants the standard Beacon session shape: an
opaque HttpOnly `beacon_session` cookie, a server-side session store, a readable
CSRF token returned from login, and WebSocket auth that checks the same session.

```gleam
import beacon/api
import beacon/auth
import beacon/session

let store = session.new_store("my_app_sessions")
let auth_config = auth.default_session_config()

beacon.app(init, beacon.no_local, init_server, update, view)
|> beacon.api_routes(auth.session_routes(store, auth_config, authenticate_login))
|> beacon.ws_auth(auth.protect_ws(store, auth_config))
|> beacon.start(8080)

fn authenticate_login(req) {
  case api.read_form(req, 4096) {
    Ok(fields) -> api.form_field(fields, "username")
    Error(reason) -> Error(reason)
  }
}
```

For localhost HTTP development, use `auth.dev_session_config()` explicitly. The
default config keeps the cookie `Secure`, `HttpOnly`, and `SameSite=Lax`.

Use `auth.login_route`, `auth.current_user_route`, and `auth.logout_route` when
you want the standard JSON/cookie behavior but custom route names. Use
`auth.protect_api` and `auth.protect_api_with_csrf` for custom authenticated
API handlers.

### Advanced: WebSocket Authentication

```gleam
beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.ws_auth(fn(req) {
  case beacon.get_cookie(req, "session_token") {
    Ok(token) -> validate_session(token)
    Error(Nil) -> Error("No session cookie")
  }
})
|> beacon.start(8080)
```

Runs before the WebSocket upgrade handshake. Return `Ok(Nil)` to allow, `Error(reason)` to reject with 401.

If you are using standard Beacon sessions, prefer
`auth.protect_ws(store, auth_config)` over a custom hook.

### Request-Aware Server Init

With `Server state`, the `init_server` function takes no arguments. Use
`auth.init_from_session` when SSR should render a signed-in model on first
paint:

```gleam
beacon.app(init, beacon.no_local, init_server, update, view)
|> beacon.ws_auth(auth.protect_ws(store, auth_config))
|> beacon.ws_init(auth.init_from_session(
  store,
  auth_config,
  fn(_req) {
    let #(model, _effect) = init()
    #(model, Nil, init_server())
  },
  fn(req, sess, user_id) {
    #(init_authenticated(req.path, sess, user_id), Nil, init_server())
  },
))
|> beacon.start(8080)
```

Both branches must return the full combined state `#(Model, Local, Server)` —
here `#(Model, Nil, Server)` because the app uses `beacon.no_local`. `init()`
returns `#(Model, effect.Effect(Msg))`, so destructure it and drop the init
effect; `ws_init` does not carry one. `init_authenticated` returns a bare
`Model`.

`beacon.ws_init` is the raw hook underneath this helper. When set, it replaces
both `init` and `init_server` and returns the full combined state
`#(Model, Local, Server)`, so keep it for request-aware initialization only.

### Effects and Async

For apps that need side effects (HTTP calls, database queries, timers):

```gleam
beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.on_update(fn(model, msg) {
  case msg {
    Saved -> effect.from(fn(_) { persist(model) })
    _ -> effect.none()
  }
})
|> beacon.start(8080)
```

Keep `update` pure and deterministic. Put stores, PubSub, HTTP, env reads,
random values, and other BEAM-only work in `on_update`; the build/linter will
reject those calls inside client-visible `update`. Keep startup work in
`init`'s returned effect and event-triggered server work in `on_update`.

Available effects:
- `effect.from(fn(dispatch) { ... })` -- run async work, dispatch messages back
- `effect.background(fn(dispatch) { ... })` -- spawned process, won't block
- `effect.every(ms, fn() { msg })` -- recurring timer
- `effect.batch([effect1, effect2])` -- run multiple effects
- `effect.none()` -- no side effect

### Server-Only State

Private state that never reaches the client. Add `pub type Server` when the app
needs secrets, sessions, database handles, audit state, or other private values:

```gleam
beacon.app(init, beacon.no_local, init_server, update, view)
|> beacon.start(8080)
```

- `init_server` returns server-only state (DB pools, API keys, etc.)
- `update` receives `model`, `local`, and `server`, returning `#(model, local, server)`
- `view` receives only `model` and `local` -- server state is invisible to the view
- Server state is never serialized, never sent to client, never in JS bundle
- Model updates ARE automatically pushed to the client via an auto-generated codec -- the build system generates `beacon_codec.gleam` for `Server state` apps too, encoding only Model fields (never Server)

### Redirects

Navigate the client to a new URL from the server. Redirects are effects, so
they are returned from the `on_update` handler — `update` itself stays pure and
returns only `#(model, local, server)`:

```gleam
fn after_update(state: #(Model, Nil, Nil), msg: Msg) -> effect.Effect(Msg) {
  case msg {
    LoginSuccess -> beacon.redirect("/dashboard")
    Logout -> beacon.redirect("/login")
    _ -> effect.none()
  }
}

beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.on_update(after_update)
|> beacon.start(8080)
```

`beacon.hard_redirect(path)` triggers a full page reload via `window.location.href` instead of pushState. Use when the browser needs to make a real HTTP request (e.g., to receive a `Set-Cookie` header after login):

```gleam
fn after_update(state: #(Model, Nil, Nil), msg: Msg) -> effect.Effect(Msg) {
  case msg {
    LoginSuccess(token) -> beacon.hard_redirect("/api/auth/session/" <> token)
    _ -> effect.none()
  }
}
```

### Form Submission

```gleam
html.form([beacon.on_submit(FormSubmitted)], [
  html.input([html.type_("text"), beacon.on_input(SetName)]),
  html.button([html.type_("submit")], [html.text("Submit")]),
])
```

`on_submit` prevents the default form submission and sends the message to the server.
Use `on_submit_local(fn(fields_json) { ... })` when the submit depends on the
current form values rather than a fixed message.

## Production Deployment

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8080 | Server port |
| `SECRET_KEY` | dev default | Session signing key |
| `BEACON_ENV` | development | Set to `production` for prod |

### Docker

```bash
docker build -t my_app .
docker run -p 8080:8080 -e SECRET_KEY=your-secret my_app
```

### Health Check

`GET /health` returns `{"status":"ok"}` with 200.

## Build Tool

Compile user code to JavaScript for client-side execution:

```bash
gleam run -m beacon/build
```

This creates a content-hashed file like `priv/static/beacon_client_HASH.js` — local events run in the browser with zero server traffic.

## Development Mode

For a fast feedback loop during development:

```bash
gleam run -m beacon/dev
```

This starts your app with file watching and hot module reload:

- Watches `.gleam` files for changes, auto-rebuilds server + client
- Hot-swaps BEAM modules without restarting — no lost WebSocket connections
- Notifies connected browsers to reload automatically
- Uses native file watchers (`fswatch` on macOS, `inotifywait` on Linux) or a polling watcher when native tooling is unavailable

For production, use `gleam run` directly — no file watcher, no HMR overhead.

## Server Privacy

The build system automatically strips server-only code from the client JS bundle. Three mechanisms keep secrets server-side:

1. **`server_` prefix** on constants — excluded from the client bundle
2. **`pub type Server`** — private server-side state that never reaches the client
3. **Server-module references** — code referencing `store`, `effect`, `pubsub`, `process` is automatically excluded

Code referencing server-only modules (`store`, `effect`, `pubsub`, `process`) is automatically detected and excluded.

```gleam
const server_api_key = "sk_live_secret_key"   // stripped from client JS
const app_title = "My App"                     // included — used by view
```

The `Server` type is available in `update` but not `view`, so the compiler itself prevents accidental leaks.
Imported route modules follow the same rule: route-local `Server`,
`init_server`, `update_server`, and `server_` constants are stripped before the
module is copied into the generated client bundle. Use
`route.update_server_model` when a route mini-app owns private server state.
