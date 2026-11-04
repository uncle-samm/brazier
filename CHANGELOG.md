# Changelog

All notable changes to Beacon are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

**No version has been published.** Nothing has gone to Hex, and no release has
been tagged. `gleam.toml` says `0.1.0`, the version the first release will
take. An earlier copy of this file had `0.1.0` and `0.2.0` entries from
2026-03-15 and 2026-03-16. Neither was ever released, and their contents no
longer describe the code. They have been removed, and the history before
Milestone 117 is summarised at the end of this file.

The package will be renamed from `beacon` to `brazier` before it is first
published, because the `beacon` name is taken on Hex. That rename has not
happened yet. When it does, it will cover the package, the modules, the FFI
modules, the client package, the DOM attributes, the cookie names and the
docs, and the old names will stop working. There will be no aliases.

`scripts/publish.sh` refuses to publish unless the `gleam.toml` version has a
`## [X.Y.Z]` heading here. `make publish-dry-run` runs the whole release gate
without contacting Hex.

## [Unreleased]

Milestone 117, the full review remediation. The workstreams are listed in
`docs/PROGRESS.md`. WS5 and WS6 changed postgleam, which is a separate package
with its own changelog, so they are not listed here.

### Breaking

- (WS7) The application API was redesigned; see `docs/design/API_REDESIGN.md`.
  - There are three constructors: `beacon.simple`, `beacon.application` and
    `beacon.full_application`. They take a `Context` and the router, and
    `init` receives a `Context`.
  - `update` returns effects.
  - The `#(model, local, server)` triple is gone from every public type.
  - Each route is declared once.
  - Events are typed `Attr(msg)` values, and event payloads are typed.
  - Components are nested child modules, and `component.map_node` maps their
    handlers.
- (WS7) Many modules are now internal (`internal_modules` in `gleam.toml`),
  among them `runtime`, `ssr`, `patch`, `rate_limit`, `state_manager` and the
  build and transport internals.
- (WS7) `beacon.start` reads no environment variables. Apps call
  `config.port()` and `config.secret_key()`, which return a `Result`.
- (WS1) The secret key, `config.*` and the cookie functions return a
  `Result`. An empty `secret_key` is rejected.
- (WS8b) `init` returns `Result(model, InitError)`. A refusal answers the
  server render with that HTTP status and closes the socket with
  4000 + the status. A crash answers 500 and closes the socket with 1011.
- (WS8b) The `auth.login*` and `auth.create_login*` functions return a
  `Result`. `auth.logout_response` returns a `ResponseError`, and it does not
  clear the cookie when the session store fails.
- (WS8a) `cluster.new` takes `secret_key`. Presence `members`, `list` and
  `get_by_key` return a `Result`.
- (WS10b) A join token that does not verify, a token model that `restore`
  cannot decode, and a missing token while state recovery is enabled refuse
  the connection before `init` runs: the socket closes with 4400 and the
  browser reloads the page. The session no longer continues from `init`'s
  state. State recovery with an empty secret key fails the runtime's start.
- (WS10b) `store.StoreError` is a store type, `InvalidName`,
  `TableTypeMismatch` or `TableOwnerUnavailable`, not an alias of the
  internal `state_manager.EtsError`. `replicated.InvalidName` carries
  `name` and `reason`.

### Added

- (WS1) Supervised HTTP listener with an acceptor pool, keep-alive and
  `Connection: close`. It binds to port 0 and reports the bound port.
- (WS1) A connection tracker owned by a supervised process, so a connection
  crash still frees its slot. There are also per-IP connection caps.
- (WS2) RFC 6455 frame validation, fragmentation, ping/pong, an idle timeout,
  `send_timeout`, per-IP WebSocket caps and a maximum message size.
- (WS2) Session TTL, session rotation on login, and a re-check of open
  sockets on logout or a role change. `session.set` is atomic.
- (WS3) The client reconnects with backoff, stops on close code 4401, and
  paces its sends.
- (WS4) The client `beacon` shim is generated from the server API
  (`on_focus`, `on_blur`, `on_input_debounced`). Dict and tuple model fields
  are supported or rejected at build time.
- (WS7) `beacon.simple`, for an app whose state lives in the browser.
- (WS7) A URL policy for URL attributes, and `unsafe_raw_html`.
- (WS8a) `beacon/telemetry`, over Erlang `telemetry`. A handler that crashes
  is detached and logged.
- (WS8a) A partitioned PubSub ported from Phoenix.PubSub's pg adapter, with
  `local_broadcast` and `direct_broadcast`.
- (WS8a) A cluster manager with static and DNS discovery, backoff with
  jitter and an HMAC check of peers (see Security). Mutual-TLS distribution
  has tests.
- (WS8a) Session backends: `LocalEts` and `External`. Writes are
  compare-and-swap, and a revocation reaches every node.
- (WS8a) Presence, ported from Phoenix.Tracker: shards, a delta CRDT,
  heartbeats and transfers.
- (WS8b) Telemetry for HTTP requests, connections, WebSocket events, the
  runtime, effects, sessions and store writes, with route tags.
- (WS8b) A replicated store mode, `store.open` and `store.open_list` with
  `Replicated(config)`. It is an add-wins LWW CRDT with a hybrid logical
  clock. `store.new` stays node-local.
- (WS8b) One rest-for-one application tree (PubSub, cluster, session scope,
  presence, listener) with a real stop.
- (WS8b) `beacon.presence(tracker:, track:, on_presence:)`, plus the
  client-safe `beacon/presence/sync` types.
- (WS8b) `auth.allow_guests_ws`. `auth.init_from_session` now takes init
  functions that receive a `Context`.
- (WS10) An MIT `LICENSE`.
- (WS10) `scripts/check_docs.sh`. It checks every relative link and anchor
  in the docs. It also compiles every Gleam sample in them with zero
  warnings, except samples marked as fragments.
- (WS10) `make publish-dry-run`, and a release gate in `scripts/publish.sh`.
- (WS10b) `store.describe_error`.
- (WS10b) `beacon.track_and_watch_presence`: a session tracks itself on
  the topics `track` returns and follows the topics `watch` returns.
- (WS10b) `beacon/rate_limit` is public, since `middleware.rate_limit` takes
  its `RateLimiter`; `rate_limit.config` and `rate_limit.max_keys` read a
  limiter's settings.
- (WS10b) `[beacon, subscription, changed]` telemetry: a runtime's PubSub
  listener joined or left a topic.

### Changed

- (Phase 0) Gleam is pinned to 1.19.2 through `mise.toml`, and the
  dependency floors were raised.
- (WS3) Per-event cost fell from about 243 µs to about 48 µs for an event
  that changes the model, and about 20 µs for one that does not.
- (WS3) Patch operations the client does not know fail loudly instead of
  being ignored.
- (WS3) Runtime, timer and listener lifetimes are tied together with
  monitors, so no process is left orphaned. A re-keyed `every` timer no
  longer leaks.
- (WS4) The build tool uses glance 7 and finds modules by parsing them, not
  by matching strings. It parses TOML properly, and it exits non-zero on
  failure.
- (WS4) A production build happens only at build time. The server never
  runs `gleam` or `npx`.
- (WS7) The build starts from the app constructor call. Only modules the
  browser reaches go into the bundle, and the server accepts only message
  types the browser can construct.
- (WS7) The client runtime is generic (`start(App)`, event delegation).
- (WS8a) Stores are node-local unless `Replicated` is chosen.
- (WS8b) `auth.init_from_session` refuses the page with 503 and the socket
  with 4503 when the session store cannot answer; it does not render the
  guest state.
- (WS8b) Per-event telemetry costs about 10%, which was accepted. Changed
  events went from 41–42 to 45–47 µs, and unchanged events from 17–18 to
  18–21 µs.
- (WS10) The docs were rewritten to match the code. Historical notes moved
  to `docs/archive/`.
- (WS10) The release scripts are strict bash. `run_canonical_cdp.sh` is now
  `run_all_cdp.sh --canonical`.
- (WS10b) Every example's `main` crashes when `beacon.start` returns an
  error, so `gleam run` without `gleam run -m beacon/build` first exits with
  status 1 and names the missing artifact; before, it exited 0 in silence.
  The examples ship an inline SVG favicon, so the browser requests no
  `/favicon.ico`.
- (WS10b) The Hex package carries the client runtime: `scripts/publish.sh`
  copies `beacon_client/src` to `priv/beacon_client_src` for the tarball and
  checks the tarball holds it, and `beacon/build` reads the runtime from
  there when the app gets Beacon from Hex. Before, an app on the Hex package
  could not build its client bundle.
- (WS10b) The examples' generated `src/beacon_codec.gleam` and
  `priv/static/` bundles are no longer tracked; build an example before its
  first run.
- (WS10b) CI runs `scripts/check_docs.sh` and the CDP suite at the mobile
  viewport as well as the desktop one. The samples in CLUSTERING, TELEMETRY,
  ERROR_HANDLING and TESTING are compiled too, and ERROR_HANDLING describes
  the transport, rate limit, join token and model size errors as the code
  raises them.

### Removed

- (WS7) The legacy modules and their tests: `state`, `substate`, `diff`,
  `view`, `template/*`, `island`, `handler`, `route`, `component`, and
  `build/{ast_refs,messages,shape}`.
- (WS7) `on_update`, `ws_init`, `init_simple` and `update_simple`.
- (WS7) The `examples/todos` app and the example-only FFI.
- (WS7) The server-render fallback to `priv/static`.
- (WS10) The expect-based `scripts/publish.sh`, which fed the Hex key to
  `gleam publish --yes` and answered its prompts automatically.

### Security

- (WS1) HTTP: request-line forms (absolute URI and `*`); limits on headers,
  bodies and packets; read timeouts against slowloris; HEAD responses carry
  no body.
- (WS1) Static files: the `/` prefix boundary is enforced and hashed-asset
  paths are normalized.
- (WS1) Uploads are type-sniffed, get generated filenames and are served
  safely.
- (WS1) Rate limiting by peer IP, with explicit trusted-proxy configuration
  and bounded memory.
- (WS1) Cookie values are validated, and a deleted cookie is `Secure` by
  default. The CSRF compare runs in constant time, and the auth and CSRF
  names can be configured. The Origin scheme is checked.
- (WS2) Each event in a batch counts towards the rate limit, and decode
  errors are rate-limited.
- (WS3) The join token is bound to the session, and the serializer never
  sees `Server` state. Patches escape `~` and `/`. A model over 5 MB is an
  error.
- (WS7) `javascript:` URLs are filtered from URL attributes.
- (WS8a) Cluster peers are checked with an HMAC hello/ack. A production node
  refuses to run without secure distribution.
- (WS10b) `examples/auth_workspace` checks its login form against a random
  per-browser token in an HttpOnly cookie (a double-submit cookie), renewed
  at each login, instead of a constant that protected nothing.

## Before Milestone 117 (never released)

Milestones 0 to 116, from 2026-03-15 up to the 2026-11-02 review, built the
first versions of:

- the MVU runtime with one process per connection;
- the server render with hydration;
- the WebSocket transport;
- the client runtime and its build tool;
- routing, middleware, stores, PubSub, sessions and auth;
- the examples.

None of those versions was tagged or published. Their notes are in
`docs/archive/PROGRESS.md`.
