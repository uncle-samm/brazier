# Beacon Architecture

Beacon is a full-stack Gleam web framework on the BEAM. An app is an MVU loop
that runs on the server, one runtime process per WebSocket connection. The
server renders the first page as HTML (LiveView's dead render); after the
WebSocket joins, the browser renders the view itself from the model the
server sends. Views are plain Gleam functions: no templates and no macros.
A build step reads the app's source with Glance, generates the wire codecs,
and compiles only the code the browser needs to JavaScript.

## The App

`beacon.gleam` is the public entry point. An app is built with one of three
constructors and started with `beacon.start(app, port)`:

| Constructor | `update` runs | State |
|---|---|---|
| `beacon.simple(init:, update:, view:)` | in the browser and on the server | `model` |
| `beacon.application(init:, update:, view:)` | on the server, with effects | `model` |
| `beacon.full_application(init:, update:, sync:, local:, view:)` | on the server, with effects | server `state`, synced `model`, browser `local` |

- **`init(Context)`** receives the request context (`beacon.uri`,
  `beacon.cookie`, `beacon.is_connected`, `beacon.session_id`). It runs twice:
  once for the HTML render and once for the connected mount. Effects returned
  on the HTML render are dropped. It returns `Result(_, InitError)`: an
  `Error` is answered with its status on the HTML render and closes the
  WebSocket with `4000 + status`.
- **`sync(state) -> model`** (full application) chooses what the browser
  receives. The rest of `state` never leaves the server.
- **`local`** is `local.none()` or `local.layer(init:, update:)`. Local state
  lives only in the browser. Its `update` returns `local.handled(local)` to
  keep the message in the browser, or `local.forward(local)` to also send it
  to the server.
- **`simple`**'s `update` is compiled to JavaScript. The browser applies it
  at once and still sends the message. The server stays authoritative: its
  `model_sync` replaces the browser's prediction, and the client logs a
  mismatch.

Builder functions add the rest: `with_router`, `title`, `subscriptions`,
`on_notify`, `on_notification`, `head_html`, `api_routes`, `ws_auth`,
`security_limits`, `secret_key`, `with_middleware`, `static_dir`, `dev_mode`
and `with_state_recovery`.

`beacon.start` checks for the build artifacts (`priv/static/beacon_client.manifest`
must name a bundle that exists, and the generated `beacon_codec` module must
load), composes the app with its `sync` and local layer into an
`application.AppConfig`, and starts the listener. It does not read
environment variables; apps read them with `beacon/config` (`config.port()`,
`config.secret_key()`, `config.is_production()`). Without
`beacon.secret_key`, start generates a random key and logs a warning.

## Request Lifecycle

```
GET /path ──► middleware ──► api_routes? ──► static? ──► SSR (dead render)
                                                          │ init(ctx) → route msg → view → HTML
                                                          │ + join-token cookie + <script bundle>
browser loads bundle ──► WS /ws?path=/path ──► ws_auth? ──► runtime process
                                                          │ init(ctx) → route msg
                                                          │ ◄── join
                                                          │ ──► model_sync (full model JSON)
click ──► decoder → Msg → update_local / simple update → re-render
      ──► event {data: encode_msg(msg), clock} ──► decode_event → update
                                                          │ ──► patch (JSON Patch of the model)
```

### 1. Dead render (`ssr.gleam`)

On HTTP GET, after middleware, API routes and static files, `ssr.gleam`:

1. checks the URL's percent-encoding (`internal/uri_check`, 400 on failure);
2. runs `init(ctx)` and, with a router, `update` with the route message for
   the URL (404 when `parse` rejects it). An `Error(InitError)` from `init`
   answers a static error page with its status and skips the route message;
3. renders `view` to HTML with `internal/render` and the `beacon.title`;
4. sets a signed HttpOnly join-token cookie (Phoenix.Token style: purpose,
   version, issue time, expiry and the browser-session fingerprint, signed
   with HMAC); with `with_state_recovery` the token carries the model;
5. returns the page shell: `<div id="beacon-app">` with the HTML and the
   bundle named in `beacon_client.manifest`.

### 2. Live mount (`runtime.gleam`)

`application.gleam` spawns one runtime actor per WebSocket connection
(`runtime.connect_transport_per_connection`). The runtime runs `init(ctx)`
and the route message again, performs their effects, and answers the
client's `join` with a `model_sync` of the encoded model. When `init` refuses,
no runtime starts and the socket closes with `4000 + status`; when it
crashes, the socket closes with 1011. With state
recovery, a verified join token restores the model instead of running
`init`.

### 3. Events

The browser decodes a DOM event into a `Msg`, applies it locally, and sends
it as `{"__beacon_msg": ...}` encoded by the generated `encode_msg`. The
runtime decodes it with the generated `beacon_codec.decode_event`, runs
`update`, performs the effects, encodes the model and sends a `patch` with
the JSON Patch from the previous model (`patch.gleam`), or nothing when the
model did not change.

`decode_event` accepts only the constructors that client code can build.
Anything else is refused: the runtime logs a warning, sends an `error`, and
acknowledges the event clock so the browser drops its prediction. See
[SECURITY.md](SECURITY.md#events-from-the-browser).

### 4. Navigation (`router.gleam`)

`beacon.with_router(parse:, on_change:)` makes the route part of the model.
A same-origin link click or the back button sends `navigate`; the runtime
parses the path and runs `update(model, on_change(route))`. `router.push` and
`router.replace` are effects that change the URL and run the same path;
`router.redirect` makes the browser load a page. A path the app does not route
is answered with `hard_navigate`, so the 404 comes from a real HTTP response.
See [ROUTING.md](ROUTING.md).

## Server Runtime (`runtime.gleam`)

The runtime is an OTP actor. Its `RuntimeConfig` holds `init`, `update`,
`encode_model`, `decode_event`, `restore_model`, `route`,
`dynamic_subscriptions` (with `on_notify` and `on_notification`) and the
secret key.

- **Versioning.** One `revision` counter, incremented exactly when the
  client-visible model JSON changes. A `patch` carries the revision it
  produces; a `model_sync` carries the current one. The client applies a
  non-empty patch only at `current + 1`, ignores stale ones and sends
  `request_sync` on a gap or on any patch it cannot apply.
- **Event clocks.** Every event carries a monotonic `clock`; `ack_clock` on
  `patch` and `model_sync` is the highest clock that connection sent which the
  server has processed (LiveView 1.1 event clocking).
- **Effects** (`effect.gleam`) are data: `none`, `from`, `background`,
  `after`, `every`, `batch`, `map`, `keyed` and `cancellable`/`cancel`.
  Timers, background processes and PubSub listeners belong to the runtime and
  stop when it stops. See [EFFECTS.md](EFFECTS.md).
- **Subscriptions.** `beacon.subscriptions(fn(model) -> List(topic))` is
  re-evaluated after each update; the runtime joins and leaves PubSub topics
  to match, and `on_notify`/`on_notification` turn broadcasts into messages.

## Client Runtime (`beacon_client/`)

`beacon_client_ffi.mjs` is the only hand-written JavaScript in the browser.
It owns the WebSocket, event delegation and DOM morphing.
`beacon_client/patch.mjs` holds the JSON Patch, version classification,
send budget and reconnect backoff, mirroring `patch.gleam`.

The app's own code reaches the runtime through the generated entry module
`beacon_app_entry` (`build/client_entry.gleam`). The runtime checks these
exports at startup: `decode_model`, `init_local`, `render`, `lookup_handler`,
`run_handler`, `handler_options`, `event_names`, `update_local`,
`encode_msg`, `same_model` and `is_simple`. A `simple` app also exports
`update`.

- **Rendering.** `render(model, local)` returns the HTML and the handler
  table from `internal/render.gleam`, the same target-neutral module SSR
  uses. Handlers are keyed by event name and position id (`"0.1"`); keyed
  and memo nodes are transparent, so server and browser agree on ids. The DOM
  is morphed toward the new HTML; `data-beacon-key` gives a node identity.
- **Events.** One capture listener per event name matches elements carrying
  `data-beacon-on-<name>`. Handler options apply prevent-default,
  stop-propagation, debounce and throttle. The decoder runs against the real
  event; a decode failure is a `console.warn` and the event is dropped.
- **Before hydration** there is no handler table. Events on marked elements
  are queued with a snapshot of their fields and replayed after the first
  `model_sync`.
- **Connection.** Heartbeats every 30 s, a client send budget, reconnect
  with exponential backoff and jitter. Close code 4401 (session revoked)
  stops reconnecting.

## Build (`build.gleam`, `build/`)

`gleam run -m beacon/build` (or `gleam run -m beacon/dev`, which rebuilds and
hot-reloads on change) runs, from the app project:

1. **Discovery** (`discovery`, `sources`, `app_call`): find the app module,
   whose `pub fn main` reaches a `beacon.simple`, `beacon.application` or
   `beacon.full_application` call, and the user modules it imports.
2. **Analysis** (`analyzer`, `field_type`): read the constructor call, the
   synced `Model` and the `Msg` type.
3. **Reachability** (`reach`): walk from `view`, a `simple` app's `update`,
   and the Local layer's `init` and `update`, following references to user
   functions, constants, types and constructors with scope tracking. A
   reference to a Beacon module outside the client allowlist
   (`beacon/attribute`, `element`, `event`, `html`, `local`, `log`, `svg`)
   fails the build, naming the call site. The Msg constructors reached are the
   ones `decode_event` will accept.
4. **Contract** (`contract`): write `build/beacon_contract.json`, listing
   what crosses the wire and what code reaches the browser.
5. **Server codec** (`server_codec`, `codec_gen`, `gleam_code`): generate
   `src/beacon_codec.gleam` (`encode_model`, `decode_model`, `decode_event`)
   and compile the project. A codec that does not compile is deleted.
6. **Client bundle** (`client_bundle`, `client_entry`, `client_shim`): write a
   JavaScript-target project to `build/beacon_client_app` holding only the
   reached definitions (sliced out of their files, with imports regenerated),
   the Beacon client modules, a JavaScript `beacon/log`, the runtime and
   `beacon_app_entry.gleam`, with packages pinned to `manifest.toml`. Compile
   it, bundle it with the pinned esbuild, and write
   `priv/static/beacon_client_<hash>.js` and the manifest. A failure deletes
   the manifest, so `beacon.start` refuses stale artifacts.

`gleam run -m beacon/build/runtime_bundle` rebuilds the repository's
prebuilt runtime bundle from `beacon_client/src`.

## Wire Protocol

JSON text frames over `/ws`. Full examples are in
[WIRE_PROTOCOL.md](WIRE_PROTOCOL.md).

### Client to server (`transport.ClientMessage`)

| `type` | Variant | Fields | Purpose |
|---|---|---|---|
| `join` | `ClientJoin` | token, path | Live mount; the recovery token comes from the HttpOnly cookie |
| `event` | `ClientEvent` | name, handler_id, data, target_path, clock, ops | A forwarded Msg in `data`; `ops` are untrusted hints |
| `event_batch` | `ClientEventBatch` | events | A bounded batch of events |
| `navigate` | `ClientNavigate` | path | Client navigation |
| `request_sync` | `ClientRequestSync` | | Ask for a full `model_sync` |
| `heartbeat` | `ClientHeartbeat` | | Keep-alive |

### Server to client (`transport.ServerMessage`)

| `type` | Variant | Fields | Purpose |
|---|---|---|---|
| `model_sync` | `ServerModelSync` | model, version, ack_clock | The full model |
| `patch` | `ServerPatch` | ops, version, ack_clock | JSON Patch of the model |
| `navigate` | `ServerNavigate`, `ServerReplaceNavigate` | path, replace | `router.push` / `router.replace` |
| `hard_navigate` | `ServerHardNavigate` | path | `router.redirect`, or an unrouted path |
| `error` | `ServerError` | reason | A refused event or other error |
| `heartbeat_ack` | `ServerHeartbeatAck` | | Heartbeat reply |
| `reload` | `ServerReload` | | Dev mode: reload the page |
| `mount` | `ServerMount` | payload | Not sent to browser clients; the client logs and ignores it |

## Transport (`transport.gleam`, `transport/`)

Beacon has its own HTTP/1.1 and WebSocket server on `gen_tcp`
(`transport/server.gleam`, `http.gleam`, `ws.gleam`, `client.gleam` and the
`beacon_http_*` Erlang modules), with one process per connection.
`transport.SecurityLimits` bounds everything that comes from the network:
message size (64 KB), events per second (50), connections (10,000 total, per
IP for HTTP and WebSocket), header counts and sizes, body size and read
timeouts, keep-alive, WebSocket ping/pong and idle timeouts, the outbound
queue, and decode errors. Forwarding headers are honoured only from
`trusted_proxies`. The WebSocket upgrade checks the origin and runs the
optional `ws_auth` hook, which is rechecked every
`ws_auth_recheck_interval_ms`. See [SECURITY.md](SECURITY.md).

## Supervision (`application.gleam`)

`beacon.start` runs `application.start_supervised`: one root supervisor with
the `RestForOne` strategy, so a crashing child restarts with every child
after it and never one before it. The children, in start order:

1. **The ETS table owner** (`state_manager.table_owner_supervised`). It owns
   every local store's table, so it comes first: no other child's restart
   deletes store data. Stores are usually created in `main` before the tree,
   by an owner started on demand; the supervised owner takes that owner's
   name and its tables (`ets:give_away/3`), so the data is kept. Stopping
   the tree stops the owner and deletes its tables. An owner that crashes
   owning tables is not restarted empty: its restart fails, the supervisor
   gives up, `wait_forever` crashes the main process, and the node refuses
   to create tables on demand until a new tree starts. An owner that owned
   no table restarts normally.
2. **PubSub** (`pubsub.supervised`).
3. **The cluster manager**, when configured (`cluster.supervised`).
4. **The session revocation scope** (`session.registry_supervised`).
5. **The presence tracker**, when configured (`presence.supervised`).
6. **The HTTP/WebSocket listener** (`transport.supervised`).

`application.start` (tests, embedding) starts the shared infrastructure
unsupervised, and the table owner on demand runs until the node stops.

## Modules

### View

| Module | Contents |
|---|---|
| `element` | `Element(msg)`: `element`, `text`, `none`, `keyed`, `memo`, `map`, `unsafe_raw_html`, `to_string` |
| `html`, `svg` | Element helpers ([HTML_ELEMENTS.md](HTML_ELEMENTS.md), [SVG.md](SVG.md)) |
| `attribute` | Attributes; URL attributes go through `internal/url` |
| `event` | Listeners holding a `Decoder(msg)`; payload decoders; modifiers |
| `local` | The Local layer |
| `internal/render` | Target-neutral rendering to HTML plus the handler table |
| `internal/url` | The URL policy for `href`, `src` and the other URL attributes |

### Server

| Module | Contents |
|---|---|
| `application` | Builds the runtime and SSR configs and starts the listener, optionally supervised |
| `runtime` | The MVU actor |
| `ssr` | Dead render, page shell, join token |
| `transport`, `transport/*` | HTTP/WebSocket server and wire protocol |
| `effect` | Effects |
| `router` | `segments`, `query`, `push`, `replace`, `redirect` |
| `patch` | JSON Patch diff and apply (Erlang FFI) |
| `api` | Typed handlers for `beacon.api_routes` |
| `middleware` | HTTP middleware pipeline ([MIDDLEWARE.md](MIDDLEWARE.md)) |
| `static` | Static files with traversal prevention |
| `cookie`, `session`, `auth` | Cookies, server-side sessions, login/logout and session-bound WebSockets |
| `form`, `upload` | Form helpers and CSRF; bounded multipart uploads with content sniffing |
| `rate_limit`, `ip` | Fixed-window rate limiting; trusted-proxy client addresses |
| `pubsub`, `presence`, `presence/sync` | Ports of Phoenix.PubSub (pg adapter) and Phoenix.Tracker; `presence/sync` holds the diff types and `merge`, which run in the browser too |
| `store`, `store/*` | ETS stores that broadcast on change; replicated stores as an add-wins LWW CRDT |
| `state_manager` | ETS storage behind stores |
| `cluster` | Node discovery and reconnection ([CLUSTERING.md](CLUSTERING.md)) |
| `telemetry` | Events through the Erlang `telemetry` library ([TELEMETRY.md](TELEMETRY.md)) |
| `config` | `port`, `secret_key`, `is_production` from the environment |
| `error`, `error_page`, `log` | Error types, error pages, structured logging |
| `notification` | Typed PubSub payloads for `on_notification` |
| `debug` | Runtime statistics |

### Tooling

| Module | Contents |
|---|---|
| `build`, `build/*` | The build pipeline above |
| `dev` | Build, run, rebuild and hot-reload on change |
| `lint` | Glance-based linter for the engineering principles (`gleam run -m beacon/lint`) |

## Dependencies

| Package | Purpose |
|---|---|
| gleam_stdlib, gleam_erlang, gleam_otp | Standard library, processes, actors and supervisors |
| gleam_http | Request and Response types |
| gleam_json | JSON encoding and decoding |
| gleam_crypto | HMAC signing, random secrets |
| glance, glexer | Gleam parsing for the build and the linter |
| tom | `gleam.toml` and `manifest.toml` for the build |
| logging | Logging backend |
| simplifile | File access |
| telemetry | Telemetry events |
| gleeunit | Tests (dev only) |

Beacon does not depend on Lustre, Wisp or Mist; it follows their designs
(see below) with its own element type, middleware and server.

## Project Structure

```
src/
  beacon.gleam            # Public API: constructors, builders, start
  beacon/                 # Modules above
    build/                # Build pipeline
    internal/             # render, url, uri_check, context
    presence/, store/     # Presence and replicated-store internals (and presence/sync)
    transport/            # HTTP/WebSocket server
  beacon_*.erl            # Erlang FFI and OTP processes
beacon_client/src/
  beacon_client_ffi.mjs   # Browser runtime
  beacon_client/patch.mjs # JSON Patch, versions, send budget, backoff
examples/                 # 24 apps, each built with `gleam run -m beacon/build`
test/                     # Unit, runtime, integration, build and cluster tests
test_all_cdp.py           # Browser tests over the examples (see TESTING.md)
```

## Design Sources

| Pattern | Source | Where |
|---|---|---|
| MVU, effects as data, element/attribute/event layout | Elm, Lustre | `runtime`, `effect`, `element`, `event` |
| Dead render, then live mount | LiveView | `ssr`, `runtime` |
| Route as model, `handle_params` | LiveView | `with_router`, `router` |
| Event clocks and acknowledgements | LiveView 1.1 | `clock`, `ack_clock` |
| Signed join tokens | Phoenix.Token | `ssr` |
| PubSub, presence | Phoenix.PubSub, Phoenix.Tracker | `pubsub`, `presence` |
| Codegen from source analysis | Squirrel | `build` |
| Model JSON patches | RFC 6902, RFC 6901 | `patch`, `patch.mjs` |
