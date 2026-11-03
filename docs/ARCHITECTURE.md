# Beacon Architecture

Full-stack Gleam web framework running on BEAM. One OTP process per session,
server-authoritative state with client-side local execution. No templates,
no macros — pure function calls for views, build-time AST analysis via Glance.

## Core Layers

### 1. Transport (`src/beacon/transport.gleam`)

WebSocket via Beacon's gen_tcp server, one BEAM actor per connection.

**Wire protocol:**
- 6 `ClientMessage` variants: `ClientEvent`, `ClientHeartbeat`, `ClientJoin`, `ClientNavigate`, `ClientRequestSync`, `ClientEventBatch`
- 8 `ServerMessage` variants: `ServerMount`, `ServerHeartbeatAck`, `ServerError`, `ServerModelSync`, `ServerPatch`, `ServerNavigate`, `ServerHardNavigate`, `ServerReload`

**Security (`SecurityLimits`):**
- Per-connection rate limiting: 50 events/sec (configurable)
- Message size cap: 64KB (configurable)
- Global connection cap: 10,000 (configurable)
- Origin validation on WebSocket upgrade
- Optional `ws_auth` hook — runs before upgrade, rejects with 401

**`TransportConfig`** ties it together: port, on_connect/on_event/on_disconnect callbacks,
optional SSR factory, middleware pipeline, static file config, runtime factory for
per-connection runtime spawning, optional API route handler (for custom route handling before SSR),
and security limits.

### 2. Runtime (`src/beacon/runtime.gleam`)

MVU loop as OTP actor. One per user session.

**`RuntimeConfig`** defines an app:
- `init: fn() -> #(model, Effect(msg))`
- `update: fn(model, msg) -> #(model, Effect(msg))`
- `view: fn(model) -> Node(msg)`
- `decode_event` from app config or generated `beacon_codec.decode_event/4`
- Optional `serialize_model`/`deserialize_model` for state recovery
- Route patterns + `on_route_change` callback
- Dynamic subscriptions: `fn(model) -> List(String)` with `on_notify` handler

**`RuntimeState`** tracks:
- Current model, connections map, event clock (monotonic, for ordering)
- Optional client handler metadata; not a server-side event decoder
- `CachedModelState`: either `FullModelCache` or `SubstateCache` (per-field JSON caching)
- PubSub listener subject and current subscriptions

State recovery uses HMAC-SHA256 signed session tokens stored in an HttpOnly SSR cookie.
On WebSocket reconnect, the token restores model state without re-running init.

### 3. View Layer

**`element.gleam`** — The VDOM node types:
- `TextNode(content)` — text content
- `ElementNode(tag, attributes, children)` — HTML element
- `MemoNode(key, deps, child)` — memoized subtree (skips re-render when deps match)
- `NoneNode` — empty node for conditional rendering
- `RawHtml(html)` — raw HTML content (pre-sanitized only)
- `Attr`: `HtmlAttr(name, value)` or `EventAttr(event_name, handler_id)`

**`html.gleam`** — 54 element helpers and attribute builders (`div`, `span`, `p`, `h1`-`h6`, `ul`, `li`,
`button`, `input`, `form`, `table`, `canvas`, `select`, `option`, etc.).

**`view.gleam`** — Converts a `Node` tree into a `Rendered` struct by splitting
static HTML from dynamic text content. Static parts are sent once on mount;
subsequent updates send only changed dynamic values.

### 4. Diffing and Patching

Three diffing layers, each operating at a different granularity:

**Template-level (`template/rendered.gleam` + `template/analyzer.gleam`):**
- `Rendered` struct: fingerprint + statics list + dynamics list
- Fingerprint-based change detection — if fingerprints match, only dynamic diffs sent
- `analyzer.gleam`: Glance AST analysis classifying view expressions as `Static` or `Dynamic(dependencies)`

**VDOM (`diff.gleam`):**
- Tree diff producing 8 `Patch` variants: `ReplaceText`, `ReplaceNode`, `InsertChild`, `RemoveChild`, `SetAttribute`, `RemoveAttribute`, `SetEvent`, `RemoveEvent`
- Each patch carries a path (`List(Int)`) for targeting
- `MemoNode` comparison skips subtrees when deps are equal

**JSON Patch (`patch.gleam`):**
- RFC 6902-inspired ops for state deltas: `replace`, `append`, `remove`
- `diff(old_json, new_json) -> ops_json` — implemented in Erlang FFI
- `apply_ops(model_json, ops_json) -> Result(String, String)`
- Used by the runtime to send `ServerPatch` instead of full `ServerModelSync` when changes are small

**Substate tracking (`runtime.gleam` `CachedModelState`):**
- `SubstateCache` tracks per-field JSON strings independently
- Only changed substates trigger re-serialization and diffing
- Uses `FullModelCache` for models without substates

### 5. Routing (`src/beacon/route.gleam`)

Routing is explicit and uses the same app/runtime path as every other Beacon app.
There is no filesystem route discovery, generated route dispatcher, or separate
router startup mode.

**`route.gleam`:** `Route` type with path, segments, params dict, query dict.
`RoutePattern` for registered patterns. `match_path` does segment-by-segment
matching with `:param` extraction.

**App integration:** `beacon.route_pages([...])` registers explicit `route.page`
manifest entries. Each page entry contains a pattern, the message to send on
initial SSR or client-side navigation, and a typed render function used by
`route.dispatch_view`. Route-aware SSR runs the same update path before rendering
first paint, so hydrated state matches the HTML. There is one public route API:
`route_pages`.

**Route mini-apps:** `route.page_model` lets a page module own a child `Model`,
`Msg`, `update`, and `view` while the root app embeds that child state and wraps
child messages. `route.update_model` handles the select-update-replace loop.
`route.update_server_model` does the same for `Server state`, updating the
embedded child `Model` and private child `Server` together. Client bundle
generation sanitizes imported route modules before copying them into the JS
project, so route-local `Server`, `init_server`, `update_server`, and `server_`
constants do not ship. This keeps route-local state explicit in Gleam types
without creating a second router runtime or filesystem discovery step.

### 6. SSR (`src/beacon/ssr.gleam`)

LiveView's two-phase mount: dead render (HTTP) then live mount (WebSocket).

**Dead render:** `render_page(SsrConfig) -> RenderedPage`
1. Run `init()` to get initial model
2. Call `view(model)` to get Node tree
3. Render Node tree to HTML string via `element.to_string`
4. Sign a session token (HMAC-SHA256) containing model identity/state
5. Wrap in full HTML document with client JS bundle injected

**Live mount:** On WebSocket connect, the browser sends `ClientJoin("", path)`.
Runtime reads the HttpOnly join cookie from the upgrade request, deserializes
model state when available (or re-runs init), and sends `ServerModelSync`.

**Route-aware SSR:** `ssr_factory` in `TransportConfig` maps URL paths to different
HTML, enabling per-route dead renders.

### 7. Effects (`src/beacon/effect.gleam`)

Effects are data, not actions. `Effect(msg)` is an opaque list of callbacks.

- `none()` — no effects
- `from(fn(dispatch) -> Nil)` — synchronous effect
- `background(fn(dispatch) -> Nil)` — spawns a new BEAM process
- `every(interval_ms, fn(dispatch) -> Nil)` — repeating timer
- `after(delay_ms, fn() -> msg)` — delayed message
- `batch(List(Effect))` — combine multiple effects
- `map(Effect(a), fn(a) -> b)` — transform message type

Spawned background work, delayed messages, repeating timers, and dynamic PubSub
listeners are runtime-owned. Runtime shutdown stops live effect processes and
listener subscriptions so reconnect churn does not leak work.

### 8. Generated Event And Render Contract

Live events require a generated `decode_event` contract. The runtime
does not render `view` on live join or normal model updates; the browser renders
from model sync/patch state and sends an encoded Msg envelope for server
authority.

The handler registry is client-side metadata in generated apps:

1. Browser render starts a registry for DOM event attributes
2. During render: `on_click(Increment)` calls `register_simple(msg)`, returns handler ID (`"h0"`, `"h1"`, ...)
3. Browser events resolve the handler ID to a typed `Msg`
4. Generated `encode_msg` serializes the `Msg` into `data.__beacon_msg`
5. Server `beacon_codec.decode_event/4` decodes that envelope and runs `update`

If generated `beacon_codec.decode_event/4` is not available for a public app,
startup fails. The low-level `application.AppConfig.decode_event` field remains
only for advanced non-browser transports. There is no server-rendered
handler-registry event path.

Generated `beacon_codec.render_model/1` is also part of the startup contract for
public apps. SSR uses this generated renderer when the app is started through
the public Beacon builder, so first paint and post-hydration rendering are tied
to the same generated contract. The build also writes
`build/beacon_contract.json` with Model, Local, Server, client message,
component message, skipped server state, and generated codec details.

Apps may define `pub type ClientMsg` to explicitly allow only a subset of
top-level `Msg` variants to originate from the browser. Variants excluded from
`ClientMsg` can still be produced by server effects or server-side update code,
but generated browser events will not decode into them.

Two handler types: `simple` (fixed Msg) and `parameterized` (callback that receives event data string).
Uses process dictionary for storage since view runs synchronously in a single BEAM process.
Stack-based for nested component renders.

### 9. Client Runtime (`beacon_client/`)

The browser-side JavaScript follows one rendering model:

**SSR first render:** HTTP requests receive fully rendered HTML for first paint,
SEO, and accessibility. On WebSocket join, the server sends authoritative
`ServerModelSync` for hydration and must not remount the SSR HTML.

**Client-state live rendering:** After hydration, normal model updates are
`ServerPatch` or `ServerModelSync`; the server does not use repeated HTML mount
messages for ordinary live updates. The client decodes model JSON, runs the
generated `view`, and updates the DOM locally.

**Local-only state:** When user code has a `Local` state and
`msg_affects_model(msg)` returns `False`, the client runs `update` and renders
immediately without WebSocket traffic. This covers UI-only state such as
dropdowns, focused editor state, and input drafts.

The build analyzer reports one state shape for every app: `Model`,
`Model + Local`, `Model + Server`, or `Model + Local + Server`. It also
classifies messages as `LOCAL`, `MODEL`, or `MODEL+LOCAL`. `LOCAL` messages are
purely client-side. `MODEL` messages and `MODEL+LOCAL` messages still go through
the server-authoritative update path; the local part can update the browser
immediately, but the model part is confirmed by server patch/sync.

When a message affects `Model`, the client can optimistically render its local
result, but the server remains authoritative. Client-sent patch ops are hints
only; server state comes from the server-side `update`.

Generated client code is required for normal apps:
- `initClient()` waits for `ServerModelSync` to get authoritative model
- On event: runs `update` locally for instant DOM update
- If model changed: sends event to server, awaits `ServerModelSync`/`ServerPatch`
- If only local state changed: no server traffic (zero latency)
- If patch application fails: sends `ClientRequestSync`; server replies with
  `ServerModelSync` and no post-mount HTML
- RAF-throttled rendering — multiple events batch into one DOM update per frame

If Beacon cannot generate the client renderer/model codec for an app shape, app
startup fails with a structured error instead of serving a degraded runtime.

**Client-side protections:**
- Rate limiting: 30 events/sec
- Reconnect with exponential backoff + jitter
- Cached model JSON for patch diffing

Files: `beacon_client.gleam` (Gleam types), `beacon_client_ffi.mjs` (JS runtime),
`beacon_client/patch.mjs` (client-side JSON diff/apply).

## Supporting Modules

### State Management
- **`state.gleam`** — Dirty-var tracking: `compute_dirty_fields(old, new, field_checks) -> DirtySet`. Computed vars with caching and dependency tracking.
- **`substate.gleam`** — Substates as OTP actors: `SubstateConfig(name, initial, update)`. Messages: `GetState`, `UpdateState`, `SetState`, `ShutdownSubstate`.
- **`state_manager.gleam`** — ETS-backed state storage for cross-process access.

### Application Layer
- **`beacon.gleam`** — Top-level API. `AppBuilder` with one constructor: `app(init, init_local, init_server, update, view)`. `beacon.no_local` and `beacon.no_server` supply `Nil` state when an app does not need Local or Server. Event helpers: `on_click`, `on_input`, `on_submit`, `on_submit_local`, `on_change`, `on_mousedown`, `on_mouseup`, `on_mousemove`, `on_keydown`, `on_dragstart`, `on_dragover`, `on_drop`. Configuration: `title`, `secret_key`, `static_dir`, `route_pages`, `security_limits`. Starts with `beacon.start(port)`.
- **`application.gleam`** — OTP application with supervision tree. `AppConfig` wraps all config. Supervisor manages transport, state manager, per-connection runtimes.
- **`component.gleam`** — Composable MVU units: `Component(init, update, view, to_parent)` with message mapping.
- **`config.gleam`** — Environment-based configuration: `get_env`, `get_env_or`, `get_env_int`, `port()`.

### HTTP and Middleware
- **`middleware.gleam`** — `Middleware` type: `fn(Request, fn(Request) -> Response) -> Response`. Combinators: `pipeline`, `only`, `except`, `at`, `methods`. Built-in: `logger`, `secure_headers`, `cors`, `rate_limit`, `compress`.
- **`static.gleam`** — Static file serving: `StaticConfig(directory, prefix, max_age)`. MIME types, cache headers, directory traversal prevention.

### PubSub and Stores
- **`pubsub.gleam`** — A port of Phoenix.PubSub's `pg` adapter: `subscribe(topic)`, `unsubscribe(topic)`, `broadcast(topic, message)` reaches every connected node; `local_broadcast` and `direct_broadcast` target one node. See `docs/CLUSTERING.md`.
- **`store.gleam`** — ETS-backed shared stores: `Store` (key-value) and `ListStore` (bag-type). Auto-broadcast via PubSub on mutation (`put`, `delete`, `push`). Use `beacon.watch(store, fn() -> msg)` to subscribe. Stores from `store.new` are node-local; `store.open` with `Replicated(config)` replicates one across the cluster as an add-wins LWW CRDT (see `docs/CLUSTERING.md`).
- **`session.gleam`** — Cookie-based sessions stored in ETS with TTL.
- **`cookie.gleam`** — Cookie parsing and setting utilities (parse, get, set, delete with secure defaults).

### Build Tooling
- **`build.gleam`** — Client JS codegen: `gleam run -m beacon/build src/<entry>.gleam`. Beacon validates the full SSR + generated client-state contract before writing `src/beacon_codec.gleam` or `build/beacon_contract.json`; codec-only or base-client builds are not a public app path. `build_base_client()` remains as a legacy name, but it delegates to the full app build and exits on failure so missing `decode_event` / `render_model` cannot be hidden.
- **`build/analyzer.gleam`** — Glance-based source analysis for codegen. Extracts `Model`, optional `Local`, optional private `Server`, primary `Msg`, message impacts (`LOCAL`, `MODEL`, `MODEL+LOCAL`), model fields, and event handlers from the entry module or imported client-visible modules.
- **`lint.gleam`** — Custom Glance-based linter enforcing engineering principles: no `todo`/`panic`, no silent catch-alls, logging requirements.

### Error Handling and Logging
- **`error.gleam`** — 9 error variants: `TransportError`, `CodecError`, `RuntimeError`, `DiffError`, `RenderError`, `RouterError`, `EffectError`, `SessionError`, `ConfigError`. Each carries a `reason` string (plus `raw` for codec errors).
- **`log.gleam`** — Structured logging with module context. Levels: `error`, `warning`, `info`, `debug`.

### Additional
- **`auth.gleam`** — Authentication middleware hooks.
- **`form.gleam`** — Form validation helpers.
- **`upload.gleam`** — File upload handling.
- **`rate_limit.gleam`** — Per-IP rate limiting (used by middleware).
- **`debug.gleam`** — Debug utilities.
- **`dev.gleam`** — Development mode helpers (auto-reload).
- **`error_page.gleam`** — Error page rendering.
- **`stress.gleam`** — Load testing utilities.

## Wire Protocol Detail

### Client -> Server
| Message | Fields | Purpose |
|---------|--------|---------|
| `ClientEvent` | name, handler_id, data, target_path, clock, ops | DOM event; ops are untrusted client hints |
| `ClientHeartbeat` | — | Keep-alive |
| `ClientJoin` | token, path | Live hydration request; browser recovery token is read from HttpOnly cookie |
| `ClientNavigate` | path | SPA navigation |
| `ClientRequestSync` | - | Full model resync request after client patch failure |
| `ClientEventBatch` | events: List(ClientMessage) | Bounded explicit batch for non-browser clients; generated browser clients do not replay local-only events |

### Server -> Client
| Message | Fields | Purpose |
|---------|--------|---------|
| `ServerMount` | payload (HTML) | Reserved remount message; normal apps use SSR HTML plus `ServerModelSync` |
| `ServerHeartbeatAck` | — | Heartbeat response |
| `ServerError` | reason | Error notification |
| `ServerModelSync` | model_json, version, ack_clock | Full authoritative model state |
| `ServerPatch` | ops_json, version, ack_clock | Incremental model delta (JSON Patch ops) |
| `ServerNavigate` | path | Server-initiated redirect |
| `ServerReload` | — | Dev mode: trigger browser reload |

Event clocking: `ClientEvent.clock` is monotonic. `ServerModelSync.ack_clock` acknowledges
which client events have been processed, enabling optimistic update reconciliation.

## Dependencies (from gleam.toml)

| Package | Version | Purpose |
|---------|---------|---------|
| gleam_stdlib | >= 0.44.0 | Standard library |
| gleam_erlang | >= 1.3.0 | BEAM interop, process spawning |
| gleam_otp | >= 1.2.0 | Actors, supervisors, subjects |
| gleam_http | >= 4.3.0 | HTTP types (Request, Response) |
| gleam_json | >= 3.1.0 | JSON encoding/decoding |
| gleam_crypto | >= 1.5.1 | HMAC-SHA256 session signing |
| glance | >= 6.0.0 | Gleam AST parser (codegen + linting) |
| logging | >= 1.3.0 | Structured logging |
| simplifile | >= 2.4.0 | File system access |
| gleeunit | >= 1.0.0 | Test runner (dev only) |

No dependency on wisp, lustre, or glance_printer. Beacon implements its own
Element type, view helpers, middleware, and routing.

## Project Structure

```
src/
  beacon.gleam                  # Top-level API (AppBuilder, event helpers)
  beacon/
    transport.gleam             # Transport orchestration, WS lifecycle, connection state
    transport/
      server.gleam            # HTTP/1.1 + WebSocket server on gen_tcp
      http.gleam              # HTTP request parsing, response writing
      ws.gleam                # WebSocket upgrade + frame encode/decode
    runtime.gleam               # MVU loop, OTP actor, state management
    element.gleam               # Node/Attr types, to_string
    html.gleam                  # HTML element helpers
    svg.gleam                   # SVG element helpers and attributes
    view.gleam                  # Node -> Rendered splitting
    diff.gleam                  # VDOM tree diffing
    patch.gleam                 # JSON Patch for state deltas
    ssr.gleam                   # Dead render + session tokens
    effect.gleam                # Effect system
    handler.gleam               # Auto event decoding registry
    component.gleam             # Composable MVU units
    route.gleam                 # Route/RoutePattern types
    template/
      rendered.gleam            # Rendered struct (statics/dynamics/fingerprint)
      analyzer.gleam            # Glance AST static/dynamic classifier
    build.gleam                 # Client JS build tool
    build/
      analyzer.gleam            # Source analysis for codegen
    state.gleam                 # Dirty-var tracking, computed vars
    substate.gleam              # Substates as OTP actors
    state_manager.gleam         # ETS-backed state storage
    middleware.gleam             # HTTP middleware pipeline
    pubsub.gleam                # Erlang pg-based pub/sub
    store.gleam                 # ETS-backed shared stores
    session.gleam               # Cookie-based sessions
    static.gleam                # Static file serving
    application.gleam           # OTP supervision tree
    config.gleam                # Environment configuration
    error.gleam                 # 9 error variants
    log.gleam                   # Structured logging
    lint.gleam                  # Custom Glance-based linter
    auth.gleam                  # Authentication
    form.gleam                  # Form validation
    upload.gleam                # File uploads
    rate_limit.gleam            # Per-IP rate limiting
    debug.gleam                 # Debug utilities
    dev.gleam                   # Dev mode (auto-reload)
    error_page.gleam            # Error page rendering
    stress.gleam                # Load testing
  beacon_*_ffi.erl (28 files)  # Erlang FFI modules
beacon_client/
  src/
    beacon_client.gleam         # Client Gleam types
    beacon_client_ffi.mjs       # Client JS runtime (WS, events, morphing)
    beacon_client/patch.mjs     # Client-side JSON diff/apply
examples/                       # 19 example apps (counter, chat, kanban, snake, etc.)
test/                           # Tests mirroring src structure
```

47 Gleam modules + 29 Erlang FFI files + 4 client JS/Gleam files.

## Design Patterns Implemented

| Pattern | Source | Where in Beacon |
|---------|--------|-----------------|
| MVU (Model-View-Update) | Elm, Lustre | `runtime.gleam`, `effect.gleam` |
| Static/dynamic splitting | LiveView Rendered struct | `view.gleam`, `template/rendered.gleam` |
| Fingerprint-based diffing | LiveView | `template/rendered.gleam` |
| Dead render + live mount | LiveView two-phase mount | `ssr.gleam` |
| Event clocking | LiveView 1.1 | `ClientEvent.clock`, `ServerModelSync.ack_clock` |
| Dirty-var tracking | Reflex.dev | `state.gleam`, `CachedModelState` |
| Substates as actors | Reflex.dev | `substate.gleam` |
| Computed var caching | Reflex.dev | `state.gleam` |
| Build-time codegen | Squirrel | `build.gleam`, `build/analyzer.gleam` |
| Handler registry | Beacon original | `handler.gleam` (auto-decode from view) |
| Client-side local execution | Beacon original | `beacon_client_ffi.mjs`, Model/Local split |
| JSON Patch state sync | RFC 6902 | `patch.gleam`, `ServerPatch` |
