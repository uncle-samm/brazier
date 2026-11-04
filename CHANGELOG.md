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
- `ssr.create_session_token`, `ssr.verify_session_token` and
  `ssr.max_token_lifetime_seconds` (the v1 session token) are removed. Use
  `ssr.sign_join_token` and `ssr.verify_join_token`; a join token's
  lifetime is `ssr.join_token_lifetime_seconds`.
- `RenderedPage.sign_join_token` and `ssr.join_token_for` return
  `Result(String, ssr.JoinTokenTooLarge)`: a token over the 3800-byte
  cookie budget is an error, no longer a token with its model dropped.
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
- (Audit TS-2) The secret key is required. `brazier.start` refuses an app
  without `brazier.secret_key` with a `ConfigError` that names the setting
  and `SECRET_KEY`. It no longer generates a random key per process with a
  warning. Every example reads `SECRET_KEY` through `config.secret_key()`.
- (Audit TS-2) `cluster.new(discovery)` no longer takes `secret_key`.
  `cluster.start` and `cluster.supervised` take `secret_key:`, and a
  Brazier app passes its own key. The app now has one key, and the peer
  check derives its MAC from it with the purpose label
  `"brazier-cluster-v1"`.
- (Audit SEC-3) `pubsub.direct_broadcast` to a connected node that has not
  passed the cluster peer check returns `Error(NodeNotVerified(node))`.
- (Audit SEC-8) With `BRAZIER_ENV=prod`, TLS distribution without peer
  verification is refused. The server needs `verify_peer` and
  `fail_if_no_peer_cert`, and the client needs `verify_peer`.
- (Audit TS-7) `rate_limit.reset`, `rate_limit.key_count` and
  `rate_limit.sweep` return `Error(rate_limit.LimiterError)` instead of
  `Error(Nil)`: `LimiterNotRunning` (the owner and its table are gone),
  `LimiterTimeout(timeout_ms)` (the owner is alive but did not answer) or
  `LimiterCallFailed(reason)` (the owner exited during the call).
  `rate_limit.describe_error` renders one for logs.
- (Final audit) `element.memo` is removed (see Removed).
  `attribute.attribute` crashes on `srcdoc` (use `attribute.unsafe_srcdoc`)
  and on `attributeName` with a value containing `href`, and rendering
  crashes on an attribute that reaches it with a refused name.
  `middleware.default_csp` no longer allows inline scripts, any `ws:`/`wss:`
  host or `avatars.githubusercontent.com` (see Changed).
- (Audit SEC-2) The middleware no longer runs on the `/ws` upgrade request.
  It runs on a `GET` of the live page, with the upgrade's headers, at the
  upgrade and at every live navigation and join to another page (see
  Security). `middleware.only("/ws", ..)` and other scopes on `/ws` never
  apply; check the socket with `brazier.ws_auth`. The upgrade's `path`
  query parameter is required (400 without it).
- (Audit SEC-16) `SecurityLimits` has an `allowed_hosts` field. With
  `BRAZIER_ENV=production` an empty list refuses to start the listener;
  in development it means `transport.development_allowed_hosts`
  (`.localhost`, `127.0.0.1`, `[::1]`). Every request, `/health` included,
  whose `Host` is not listed gets 400, so health checks and probes must send
  a listed `Host`.
- (Audit SEC-17) `brazier.with_state_recovery` takes
  `restore: fn(model, state) -> state`, called with the recovered model and
  the state `init` and the route produced for this connection. `init` runs
  before the token's model is decoded, so the server state comes from this
  connection, not from the token. Pass `fn(model, _fresh) { model }` for
  `simple` and `application`. The token's signature, age and session are
  still checked before `init`; a model that does not decode refuses the
  join (4400) after `init` has run, and a crash in `restore` closes with
  1011. `AppConfig.restore_model` takes the fresh state too.
- (Final audit SEC-4) `SecurityLimits` has a `forwarding_header` field
  (`ip.Forwarded`, `ip.XForwardedFor` or the default `ip.NoForwardingHeader`)
  naming the one header trusted proxies set. An app behind a proxy must set
  it, or the client address stays the proxy's. A header with an empty
  `trusted_proxies` refuses to start. `ip.parse_trusted_proxies(entries,
  header)` takes the header, and the listener's address set is
  `ip.parse_proxy_networks` returning `ip.ProxyNetworks`.
- (Final audit SEC-7) `auth.allow_guests_ws` refuses a bound socket whose
  session is gone, expired or has no user (4401, the page reloads) instead
  of keeping it open as a guest.
- (Audit PERF-6) Wire format: `model_sync`'s `model` and `patch`'s `ops`
  are raw JSON values in the frame (`"model":{"count":1}`,
  `"ops":[...]`, an ack is `"ops":[]`), not JSON strings holding them. A
  client must not parse them a second time. A client built before this
  change, loaded without a build id, fails its syncs loudly (3 retries,
  then an error) instead of running on; a page loaded from the hashed
  bundle gets 4409 and reloads. The generated `brazier_app_entry`'s
  `decode_model` takes the parsed `model` as a `Dynamic`, not JSON text.
- (Audit PERF-2) `patch.diff` returns `Result(Diff, String)` (`Unchanged`
  or `Ops(json)`), and an input that is not JSON is an `Error` instead of a
  crash. `patch.is_empty`, `patch.diff_json` and `patch.merge_ops_json`
  are removed. The runtime's cached model is
  `FullModelCache(snapshot: patch.Snapshot)`.

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

- The bundle name in `brazier_client.manifest` is cached in
  `persistent_term` and validated by a stat of the manifest, as the client
  asset cache is: a page render or join no longer reads the manifest. A
  manifest modified in the second it was read is never trusted (git's
  racy-clean rule), so a rebuild is always seen.
- `effect.after` no longer spawns a process. It is an `erlang:send_after`
  into the runtime's own mailbox (LiveView's `Process.send_after(self(), ...)`),
  and its `make_msg` runs in the runtime when it fires. At most 100 timers
  (`effect.max_after_timers`) can be pending per runtime; one more is
  rejected with a warning and `[brazier, effect, after, rejected]`. A keyed
  or cancellable `after` cancels its timer, and a message that was already
  in flight is dropped.
- `effect.background` is capped at 32 live workers per runtime
  (`effect.max_background_processes`); one more never runs and is logged at
  warning with `[brazier, effect, background, rejected]`.
- The runtime no longer keeps a list of effect pids and no longer scans it
  with `is_alive` on every update. The effect module tracks what each
  runtime owns, bounded by the limits above, and `Shutdown` stops it all.
- A dynamic-subscription change is diffed with sets, and not at all when
  `subscriptions(model)` returns the same list as before.
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
- (PERF-8) A patch with many array ops copies each array once instead of
  once per op, on the server (`patch.apply`) and in the client. With 4000
  items and 1300 ops it is 5 to 9 times faster on the server and 3 to 9
  times faster in the client. A test checks both against the old
  op-by-op apply.
- (PERF-1, PERF-15) Client render changes:
  - A render whose HTML equals the last render's reuses the parsed
    fragment, which makes it about 2 times faster. It still morphs, so DOM
    drift is undone.
  - Hooks are synced only for the elements a morph inserted or changed,
    not by scanning the whole root. If a hook's unmount removes an element
    that the morph touched, the render now fails, and the client asks the
    server for a full sync.
  - The dev flag is read once, and trace details are built only in dev
    mode.
- (Audit PERF-3) A static file's ETag digest is cached in an ETS table
  keyed by path and checked against the file's size, mtime, ctime, inode
  and device, so a repeat request does not read and hash the whole file.
  As in git's racy-clean rule, an entry cached within 2 s of the file's last
  change is not trusted and the file is hashed again. The cache holds at
  most 2048 files.
- (Audit PERF-13) The HTTP server sends a response as iodata: the head is
  prepended to the body's bytes tree, which goes to `gen_tcp:send` without
  being flattened into one binary.
- (Audit PERF-10) `brazier/log` asks `logger:allow/2` whether a level is
  enabled before it prefixes the module and calls the logger, as OTP's
  `?LOG_*` macros do, so a disabled `debug` line skips both.
- (Audit TS-13) `brazier/lint` visits every node of a function body:
  `use` callbacks, `assert` and `let assert` messages, case guards, list
  tails, bit array segments, record updates, captures and `echo`. Before,
  a `todo`, a `panic`, a `let _ =` discard or a log call in any of those
  places was not seen. The walker matches every glance expression variant
  without a catch-all, so a new variant is a compile error, not a blind
  spot. A new `stale-name` rule reports the pre-rename project name in
  `src/`, `test/` and `examples/`; only `config.gleam`'s refusal of the old
  variables and the tests of that refusal may name it.
- (Audit TS-4) The rate-limit sweep test and the HTTP slow-header test no
  longer sleep: the sweep takes the time as an argument
  (`rate_limit.sweep_with`), and the slow client sends a byte each time a
  receive times out. `docs/TESTING.md` lists these patterns.
- (Audit TS-5) The CDP suite stops with a `CdpError` when a `*.enable`
  command or a viewport setting gets no answer or an error, and when a
  `Runtime.evaluate` script throws or returns no JSON value. Before, an
  evaluation returned the strings `"TIMEOUT"`, `"ERR"` or `"EXCEPTION: ..."`,
  which a check could compare against, and a failed enable went unnoticed.
  A wait still retries while a navigation replaces the page's context.
- (Audit TS-6) `sim_memory_leak_test` asserts what it measures: a second
  round of 100 connect/disconnect cycles keeps no ETS table, ETS object or
  atom, besides no process. Before, it measured memory and asserted nothing
  about it.
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
- (Audit TS-9) The listener parses `ws_allowed_origins` and
  `allowed_hosts` once, when it starts, as Phoenix compiles `check_origin`,
  and refuses to start with an invalid entry. Origins used to be parsed on
  every upgrade, and an invalid entry silently matched nothing.
- (Audit PERF-2) The runtime keeps the last model it sent decoded as well
  as encoded (`patch.Snapshot`, as LiveView keeps the last rendered tree on
  the socket), so a changed event decodes only the new model, the diff
  reports an empty result without parsing the ops back, and a broadcast
  that falls back to `model_sync` no longer encodes the model twice. With a
  500 KB model a changed event went from about 4.1 ms to 2.5 ms. Encoder
  output that is not JSON is logged as an error and answered with an
  `error` frame instead of crashing the diff or being sent raw.
- (Audit PERF-6) A `model_sync` or `patch` frame is built as iodata: the
  model and ops JSON go into the envelope as they are (Phoenix's V2
  serializer), the WebSocket header goes in front of the text (cowlib's
  `cow_ws:frame`), and `gen_tcp:send` writes it without flattening. A
  50 KB `model_sync` costs about 0.3 µs to frame instead of 117 µs, and
  the browser parses each frame once instead of parsing the model again.

### Fixed

- (Final audit TS-8) A failed `session.try_delete` logs the store's error
  reason.
- (Final audit TS-4) The session store reads its time from a clock, so the
  expiry tests advance a manual clock instead of sleeping, and check each
  boundary to the millisecond. The clock is injectable only from tests
  (`session.start_store_with_clock` is internal).
- A `background` worker could run for a moment with no guardian watching
  its owner, so an owner dying in that window left it orphaned. The
  guardian now starts first, monitors the owner, and only then starts the
  worker linked to itself.
- `ws8c_runtime_stop_test` flaked when the runtime exited, from its
  helper's exit signal, before it had handled the test's monitor, so the
  DOWN said `noproc`. The test now makes the runtime (and the helper)
  answer a synchronous request after each such monitor, and fails with a
  clear message on a `noproc` DOWN.
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
- (Audit STAB-3) A PubSub partition registered its name before it created
  its tables. A subscribe in that window, or during a partition restart,
  crashed with `badarg` or `noproc`, or left rows in a table that no
  process owned. The partition now registers after its tables exist.
  `subscribe` links to the partition it looked up, then checks the name
  again after inserting. A partition that is gone or was replaced makes
  `subscribe` return `Error(NotStarted)` with a warning, not crash.
- (Audit STAB-4) A peer-check timer of an earlier connection could fire
  after the node reconnected and reject the new connection early. Timers
  now carry their reference and act only when they belong to the node's
  current check.
- (Audit TS-12) Every `let assert` in `brazier/cluster`, `brazier/pubsub`
  and the cluster tests has an `as` message. `let assert True = e` in those
  tests is now `assert e`.
- (TS-3) The client defaulted a missing `ack_clock`, and a missing event
  clock, to 0. Now a `model_sync` or `patch` without a valid `ack_clock` (a
  non-negative integer) is a protocol error, logged, that requests a full
  sync. A queued event without a valid clock is an invariant error.
- (Audit STAB-1) Tests are now race-free and isolated from each other.
  - Some tests monitored a process after starting it. If it had already died,
    they got `noproc` and passed without checking its real exit reason. They
    now use `spawn_monitor` or monitor first, and they fail clearly on
    `noproc`.
  - PubSub and presence tests now use their own topics. Subscribers,
    telemetry handlers and sys hooks are removed even when a test fails
    (`monitored.isolated` and `with_cleanup`).
  - Polling and sleeps in single-node tests are replaced by monitors, sys
    hooks and messages.
  - The membership tests with an intruder node failed about 1 run in 10.
    When the intruder disconnected one verified member, OTP's `global`
    sometimes cut the two verified members apart. Their peers now run with
    `prevent_overlapping_partitions` off. The manager's own handling of
    this is an open issue.

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

- (Final audit SEC-4) A client behind a trusted proxy could name its own
  address: the resolver preferred `Forwarded` over `X-Forwarded-For`, and a
  proxy that sets only `X-Forwarded-For` passes a client's `Forwarded`
  through. Now only the configured `forwarding_header` is read, and a
  trusted proxy that passes the other one through is logged at warning
  (Plug.RewriteOn; Rails `RemoteIp`, `IpSpoofAttackError`; RFC 7239
  section 7.4).
- (Final audit SEC-7) An `allow_guests_ws` socket that was bound to a
  signed-in session became a guest on recheck once the session was deleted,
  expired or lost its user, so a revocation that sent no notice left it
  open. Its recheck now fails and the socket closes with 4401, as LiveView
  disconnects a `live_socket_id` on logout.
- A page whose join token is over the 3800-byte cookie budget is refused
  with a 500 and no cookie, logged at error and reported as
  `[brazier, ssr, join_token, too_large]`. It used to drop the model from
  the token, so the session silently restarted from `init` on reconnect.
- With state recovery on, a join token without a model refuses the join
  (4400, the browser reloads) instead of starting the session from `init`.
- Signing a join token with an empty secret key crashes instead of minting
  a token that never verifies; the app already refuses to start without a
  key.
- Runtime and SSR logs name a page by its path only: the query string and
  fragment (which can hold tokens or personal data) are dropped, and the
  path is quoted with `string.inspect`, so a CR or LF from the browser
  cannot forge a log line (LiveView's `filter_parameters` keeps such values
  out of its logs).
- SECURITY.md documents that state recovery restores the client-visible
  model up to 24 hours old, and that authorization must not live in it.
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
- (Audit SEC-3) Cluster traffic is gated on verified membership. PubSub,
  replicated stores, presence and session revocation send only to nodes
  that passed the peer check, and drop what any other connected node sends.
  There is no fallback to every connected node. Stores and session
  maintenance sync with a node when it is verified, not on `nodeup`.
- (Audit SEC-9) DNS discovery makes node names only from well-formed IP
  addresses, in canonical form, and logs the entries it drops. A
  `max_discovered_nodes` cap (default 16,384) bounds the node-name atoms it
  makes over the VM's life. The `basename` is at most 190 bytes.
- (Audit SEC-10) The cluster manager's `format_status` shows its MAC, and
  any MAC in a message it holds, as `redacted`. A malformed hello is logged
  with its tag, size and sender only.
- (SEC-5) `router.push`, `router.replace` and `router.redirect` refuse
  paths a browser resolves to another host. The URL parser reads `\` as
  `/` and strips tab, newline and carriage return, so `/\evil.example` and
  `/<tab>/evil.example` both loaded evil.example. A path is now refused when
  it starts with `//` or `/\`, contains a `\`, an ASCII control character or
  `/%09`. The error log gives the reason. The client applies the same rule
  to the `navigate` and `hard_navigate` frames, and also refuses a path that
  `new URL(path, location.origin)` resolves to another origin. A test holds
  the server's and the client's verdicts equal.
- (SEC-14) Neither the server's nor the client's diff writes a patch path
  through `__proto__`, `constructor` or `prototype`. When such a key is
  added, removed or changed, the object holding it is replaced whole. The
  server's list of these keys is the canonical one, and a test holds the
  client's equal to it.
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
- (Audit SEC-2) A live session can no longer reach a page the middleware
  refuses over HTTP. The middleware ran only on the `/ws` request, so an
  auth middleware scoped to `/admin` never saw a WebSocket mounting or
  navigating to `/admin`. It now runs on a `GET` of the page at the
  upgrade (a refusal answers the upgrade), and at every `navigate` and
  every `join` for another page, where a refusal sends `hard_navigate` so
  the browser loads the page and gets the middleware's response. A refusal
  is logged and emits `[brazier, ws, navigation_refused]`. This follows
  Phoenix LiveView, which runs a `live_session`'s `on_mount` hooks at the
  connected mount and at each live navigation. Scoped middleware also
  matches the percent-decoded path, so `/%61dmin` is under `/admin`.
- (Audit SEC-16) The `Host` header is checked against
  `SecurityLimits.allowed_hosts` on every request and upgrade (400
  otherwise), following Django's `ALLOWED_HOSTS`: `.example.com` matches
  the domain and its subdomains, `*` matches any host, the port and case
  are ignored. Without it a DNS-rebinding page under the attacker's name
  passed the origin check, since its `Origin` and `Host` agreed.
- (Audit SEC-11) Text from the client (a page path, a `Host`, an `Origin`,
  a navigation target) is quoted with `string.inspect` in the transport,
  runtime, router and `middleware.logger` logs, and a path is logged
  without its query and fragment, so a CR or LF cannot forge a log line.
- (Audit SEC-17) State recovery no longer lets a join token decide the
  server state: `restore` receives the state this connection's `init` and
  route produced, and only the client-visible model comes from the token.

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
