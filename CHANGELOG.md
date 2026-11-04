# Changelog

All notable changes to Brazier (named Beacon until 2026-11-04) are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

**No version has been published.** Nothing has gone to Hex, and no release has
been tagged. `gleam.toml` says `0.1.0`, the version the first release will
take. An earlier copy of this file had `0.1.0` and `0.2.0` entries from
2026-03-15 and 2026-03-16. Neither was ever released, and their contents no
longer describe the code. They have been removed, and the history before
Milestone 117 is summarised at the end of this file.

The package was renamed from `beacon` to `brazier` on 2026-11-04, before it
was first published, because the `beacon` name is taken on Hex. The first
`### Breaking` entry under `[Unreleased]` lists what changed. The entries
below it were written before the rename and keep the old names.

`scripts/publish.sh` refuses to publish unless the `gleam.toml` version has a
`## [X.Y.Z]` heading here. `make publish-dry-run` runs the whole release gate
without contacting Hex.

## [Unreleased]

Milestone 117, the full review remediation. The workstreams are listed in
`docs/PROGRESS.md`. WS5 and WS6 changed postgleam, which is a separate package
with its own changelog, so they are not listed here.

### Breaking

- The package is renamed from `beacon` to `brazier`. There are no aliases or
  compatibility re-exports: every old name below stops existing.
  - Package and modules: `gleam.toml` `name = "brazier"`; depend on
    `brazier`, and import `brazier` and `brazier/...` (`beacon/element`
    becomes `brazier/element`, and so on). The error type `BeaconError` is
    `BrazierError`.
  - CLIs: `gleam run -m brazier/build`, `gleam run -m brazier/lint` and
    `gleam run -m brazier/build/runtime_bundle`.
  - Generated files: `src/brazier_codec.gleam`, `build/brazier_contract.json`,
    `priv/static/brazier_client.manifest` and
    `priv/static/brazier_client_<hash>.js`. Delete the old `beacon_codec.gleam`
    and `beacon_client*` files and rebuild.
  - Erlang FFI modules: `beacon_*.erl` are `brazier_*.erl`, and the Erlang
    module atoms of Gleam modules are `brazier@...`.
  - The client runtime package is `brazier_client/` (`brazier_client_ffi.mjs`,
    `brazier_client/patch.mjs`); the Hex tarball carries it as
    `priv/brazier_client_src`.
  - DOM and client hooks: `data-brazier-*` attributes (`data-brazier-on-*`,
    `data-brazier-key`, `data-brazier-hook`, `data-brazier-prevent-*`, ...),
    the `#brazier-app` root, `window.__brazier*` hooks and
    `window.__BRAZIER_ENABLE_TEST_HOOKS`. Pages rendered by an old server do
    not hydrate with the new client, and the reverse.
  - Cookies: the default session cookie is `brazier_session`, and the join
    token cookie `brazier_join_token`. Existing browser sessions are not
    carried over.
  - Telemetry: every event starts with `brazier` (`telemetry.prefix`), so
    handlers attach to `[brazier, ...]`.
  - Logs: module names are `brazier.*` (`"brazier.runtime"`, ...), and the
    Erlang logger domain is `[brazier]`.
  - Node-wide names: pg scopes, ETS tables, persistent_term keys,
    registered processes and PubSub topics (`brazier:dev:reload`, ...) use
    `brazier`. The cluster peer check signs `brazier-cluster-v1`, so a
    renamed node does not join a cluster of old nodes.
  - Environment variables: `BRAZIER_ENV`, `BRAZIER_SHUTDOWN_TIMEOUT`, and the
    repository's `BRAZIER_CDP_*`, `BRAZIER_PORT` and `BRAZIER_BENCH_RUNS`.
    An old `BEACON_*` name is refused, never read: `brazier.start` and
    `cluster.start` fail with an error naming the variable to set instead,
    and the CDP scripts and the bench exit non-zero. The old published dev
    secret `beacon-dev-secret-change-in-production` is still refused as a
    weak key.
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
- (Final audit) `element.memo` is removed (see Removed).
  `attribute.attribute` crashes on `srcdoc` (use `attribute.unsafe_srcdoc`)
  and on `attributeName` with a value containing `href`, and rendering
  crashes on an attribute that reaches it with a refused name.
  `middleware.default_csp` no longer allows inline scripts, any `ws:`/`wss:`
  host or `avatars.githubusercontent.com` (see Changed).

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
- (WS10b) The page title follows live updates. The server sends a `title`
  frame on every join and after each update that changes `beacon.title`'s
  result, and the client sets `document.title`, like LiveView's
  `page_title`.
- (WS10b) A build-id handshake. The client's `join` carries the content hash
  of the bundle its page loaded (`build`). A server that serves another
  bundle closes with 4409 `stale build`, and the client reloads behind its
  reload guard, so a page left open across a deploy never decodes a model
  with the codec of another build. An unreadable client manifest at join
  closes with 1011. A join without a build is let through with a warning.
- (WS10b) `window.__beaconOutboundPendingForTest()` behind
  `__BEACON_ENABLE_TEST_HOOKS`: the client's queued and scheduled sends, for
  browser tests that wait on the client instead of a quiet period.
- (Final audit) `attribute.unsafe_srcdoc(html)`: an `<iframe>` `srcdoc`,
  named for what it does like `element.unsafe_raw_html`.

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
- (WS10b) Static files are sent with `file:sendfile` from a new
  `server.File` response body, so a file is never read into memory to be
  served. The ETag is still the content hash, now computed in 64 KiB chunks.
  A FIFO, socket or device under the static directory is never opened.
  `middleware.compress` passes a file body through uncompressed.
- (WS10b) A request under the static prefix that names no file answers 404.
  It used to fall through to the page and answer 200 `text/html`.
- (WS10b) The per-IP WebSocket slots are kept by the listener's connection
  owner (`beacon_http_conns`), which releases a slot when its handler exits
  for any reason. They used to live in a `beacon_ws_pg` pg scope that the
  first upgrade started outside any supervisor. With it go the
  `local_port_unavailable` upgrade outcome and `ws.get_ip_slot_count`; tests
  read `server.get_ws_connection_count_for_ip`.
- (WS10b) A `max_events_per_second` below 50, the rate the generated client
  paces itself for, is logged as a warning when the listener starts. The
  limit is still not advertised to the client, as in Phoenix channels.
- (Final audit) `middleware.default_csp` is `default-src 'self'; script-src
  'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;
  connect-src 'self'; frame-ancestors 'self'; object-src 'none'; base-uri
  'self'`. Brazier renders no inline script, so `'unsafe-inline'` in
  `script-src` only helped injected markup. `connect-src 'self'` covers the
  same-origin WebSocket in CSP Level 3; Safari 15 and earlier need the
  app's own `wss://host` through `secure_headers_with_csp`.
- (Final audit) Rendering is faster: the name checks and the HTML escapers
  are FFI (`brazier_render_ffi.erl` and `.mjs`) that scan bytes or code
  units in one pass, as Phoenix.HTML escapes, instead of splitting into
  graphemes and chaining `string.replace`. A 1000-row table renders about
  2.3 times faster on Erlang; escaping is about 8 times faster. The client
  build copies the framework's JavaScript FFI files into the client project
  and fails when one is missing.
- (PERF-7) Appending to a replicated list store, and merging that append on
  every other node, no longer costs time in proportion to the values already
  under the key. On a 10,000-value key an append fell from about 2,200 µs to
  about 1 µs. `crdt.join` now only looks at the dots the delta's causal
  context covers, the delta-state rule of Almeida, Shoker and Baquero (2018).
  `crdt.join_full` gives the same results and is still linear. `crdt.join`
  returns its changes in no particular order. A clock entry now covers only
  counters from 1 up, so a malformed peer dot with counter 0 or below is
  covered only through the cloud. The bench suite has a new
  `store.crdt_append.{10,1000,10000}` case; its metrics need a re-baseline
  before `brazier_bench_check` accepts them.

### Fixed

- (WS10b) After a shard restart, a session on the shard's node that follows
  the topic could get the new entry's join before the old entry's leave.
  The new shard's diffs that arrive before the session's read of the
  restarted shard are left to that read, which reports both in one message.
- (WS10b) A listener restarted under load could fail to bind its port with
  `eaddrinuse` and use up the restart tolerance of the application tree. The
  listen socket now has an owner process of its own
  (`beacon_http_listen_socket`), which closes it synchronously before it
  exits. The acceptors no longer own it.
- (WS10b) `middleware.body_parser` passed a request whose `Content-Length`
  was missing or unparseable. It now applies the listener's framing rule:
  400 for a repeated or non-decimal length, 501 for `Transfer-Encoding`, 413
  over the limit.
- (WS10b) A response to a request whose body the handler left unread was
  held back until the server had discarded that body, so an early refusal
  such as a 413 waited for a body the client never sent, up to the body read
  timeout. The response is now written first, and a leftover of at most
  64 KiB is discarded after it so the connection can be reused (the order
  cowboy and Bandit use).
- (WS10b) An HTTP handler crash was logged twice, once with the stacktrace
  and once with the route. It is logged once, with both.
- (WS10b) `wait_forever` drained only the apps started by its own process.
  It now drains every app running on the node, recorded node-wide when it
  starts. A second SIGTERM during the drain reached OTP's `init:stop()` and
  cut the drain short; it is now logged and ignored. Several waiting
  processes drain one after the other.
- (WS10b) Stopping an app twice logged two errors. An app that is not running
  is now one warning, and its error says whether it was stopped already or
  its tree died (whose remembered port is then forgotten). `server.release`
  returns whether a port was remembered.
- (WS10b) `/health` answered every method. Methods other than GET and HEAD
  get 405 with `allow: GET, HEAD`, and the answer is `cache-control:
  no-store`.
- (WS10b) Dev mode's browser reload never reached a browser: nothing
  subscribed to its topic. Under `beacon/dev` every WebSocket handler now
  subscribes to `beacon:dev:reload`, and each rebuild sends every open page a
  `reload`. A handler that cannot subscribe closes 1011.

### Removed

- (WS7) The legacy modules and their tests: `state`, `substate`, `diff`,
  `view`, `template/*`, `island`, `handler`, `route`, `component`, and
  `build/{ast_refs,messages,shape}`.
- (WS7) `on_update`, `ws_init`, `init_simple` and `update_simple`.
- (WS7) The `examples/todos` app and the example-only FFI.
- (WS7) The server-render fallback to `priv/static`.
- (WS10) The expect-based `scripts/publish.sh`, which fed the Hex key to
  `gleam publish --yes` and answered its prompts automatically.
- (WS10b) `middleware.Context`, `new_context`, `set_context` and
  `get_context`, which nothing carried to a handler.
- (WS10b) The unused request readers `transport/http.read_request` and
  `read_request_with_limits` with their FFI, the dead
  `beacon_middleware_ffi.erl`, and the `data-beacon-auto` attribute on the
  default page, which nothing read.
- (WS10b) The per-upgrade check of the security limits, which the listener
  already validates when it starts, and with it the `invalid_limits`
  WebSocket upgrade outcome.
- (WS10b) Dev mode's polling watcher. Without `fswatch` (macOS) or
  `inotifywait` (Linux) dev mode now exits with status 1 and names the package
  to install.
- (Final audit) `element.memo` and `render.Memo`. Nothing read its key or
  dependencies, on the server or in the browser, so it skipped no work. Remove
  the call and keep its child.

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
- (Final audit) On Erlang the HTML escapers missed a `"`, `&` or `<` that a
  combining mark followed (`string.replace` matches whole graphemes), so a
  value such as `x"` + U+0301 + ` onmouseover=...` closed its attribute and
  added a handler in server-rendered HTML. The escapers now work on bytes.
- (Final audit) The URL policy reads the scheme by code point, as the
  WHATWG URL parser does. A combining mark after the `:` (`javascript:` +
  U+0E33) hid the colon from the grapheme-based reader, so the value passed
  as relative and the browser ran it.
- (Final audit) `srcdoc` and an SVG `attributeName` targeting `href` or
  `xlink:href` are refused, as DOMPurify refuses them: both put markup or a
  URL in the page past the URL policy.

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
