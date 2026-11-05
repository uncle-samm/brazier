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
with its own changelog, so they are not listed here. Entries tagged `(M118
...)` come from Milestone 118 (streams, the shifted-array diff and the
open follow-ups), which is in progress.

### Breaking

- (M118 backpressure) `RuntimeMessage` gains `ConnectionOwnerDown`;
  `runtime.HeldStreamErrors`, `runtime.held_stream_errors_max` and
  `runtime.LiveJoin` are new, and `RuntimeState` gains `held_stream_errors`
  and `live_join`.

- (M118 transport) **Wire break:** a page from an older bundle is closed
  with 4499 `stale build`, not 4409, so every stale-build close is in the
  reload range (4400-4499) and 4409 is free. In dev mode `join` may carry
  an optional `dev_build`, and a join from a stale dev build gets a
  `reload` reply instead of a close. An old client that sees 4499 reloads
  as it did for 4409, since both are in the reload range.
- (M118 transport) `error.refuse(499, _)` crashes `init`: 4000 + 499 is the
  stale-build close code, so a refusal can't use it.
- (M118 transport) `transport.check_join_build` is `@internal` and takes a
  `ConnectionState`; `transport.check_join_dev_build` checks the dev build.
  `ConnectionState` has a new field, `warned_no_build`.
- (M118 transport) The client manifest is read once, at startup. Outside
  dev mode, a rebuilt bundle needs a restart. `ssr.render_page_from` is
  replaced by `ssr.render_page_with_bundle`, which takes the bundle name
  (`ssr.client_bundle()`, loaded by `ssr.load_client_bundle()` at start; a
  failed load fails the start).
- (M118 transport) `server.read_body` returns `BodyReadError`, and
  `transport_http.read_body` returns `ReadBodyError`, instead of strings. A
  body read cut short by the request deadline is `RequestDeadlineExceeded`,
  and the error descriptions name `body_read_timeout_ms` and
  `request_timeout_ms`.
- (M118 streams) **Wire break:** `patch` and `model_sync` carry a required
  `streams` array, empty when no stream changed. A server from before this
  sends no `streams`, which this client treats as a stream fault; a client
  from before it ignores the field and never shows stream items. The
  stale-build close (4499) reloads pages across the change.
- (M118 streams) `transport.SendPatch` and `transport.SendModelSync` gain a
  `streams_json` field, and `ssr.SsrConfig` a `stream_limits` field.
- (M118 cluster) **Wire break (between nodes):** the replicated-store CRDT
  context is `{context, Clock, Cloud, Floors}`, so replicas on mixed versions
  refuse each other's payloads as malformed. Session revocation pg groups
  are `{brazier_session, Namespace, Hash}` (SHA-256, not the raw session
  id), so revocations don't reach nodes on an older version. Upgrade a
  cluster all at once.
- (M118 logs) `server.Connection` has a new `resolved` field: the client
  address the WebSocket upgrade resolved once. The middleware gate and every
  later join and navigation reuse it. Code that builds `Connection(socket:)`
  by hand must set it.

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
- (M117 transport follow-ups) **Wire break:** the client `event`'s
  optional `ops` is a raw JSON array (`"ops":[{"op":"replace",...}]`), as
  the server's `patch` already is, not a string holding the array. The
  server decodes it strictly (RFC 6902 op names and members, RFC 6901
  pointers, no `__proto__`/`constructor`/`prototype` segment) and refuses
  an event or `event_batch` with any malformed op whole: a warning with the
  connection id, the `error` frame `"Invalid event ops"`, and one count
  toward `ws_max_decode_errors`. The old string form is refused the same
  way. A page from an older bundle sends its build id on join and gets 4409,
  so it reloads before it sends an event. `ClientEvent.ops` and
  `ClientEventReceived.ops` are `List(transport.ClientOp)`, not `String`.
- (M117 transport follow-ups) **New close code 4600:** a WebSocket upgrade
  whose page the route middleware refuses now completes the handshake and
  closes with 4600 `middleware refused <status>`, instead of answering the
  upgrade with the middleware's response, which a browser cannot read. The
  client answers 4600 by loading the current URL behind its reload guard
  (at most 3 loads per tab within 60 seconds), so the page shows the
  middleware's answer, where it used to retry the upgrade with backoff
  forever. The middleware now runs after the connection limits, the origin
  and `ws_auth` checks and the RFC 6455 handshake checks, not before them,
  so a cross-origin upgrade never reaches it, and the `/ws` request span it
  emits appears only for upgrades that passed those checks. Other 4xxx
  codes the client does not know still reconnect with backoff. The 4xxx
  scheme (4400-4499 reload, 4500-4599 reconnect, 4600-4699 transport
  refusals) is in `docs/WIRE_PROTOCOL.md`. This follows LiveView, whose
  `onJoinError` navigates to the page's URL when a join is refused.
- (M117 follow-up) `brazier/store/crdt.fingerprint` is removed: a state
  carries its anti-entropy digest (`State(.., digest:)`, read with
  `crdt.digest`, checked with `crdt.recompute_digest`). The digest a replica
  broadcasts is a different value from the old sorted-fingerprint hash, so
  a cluster mixing builds from before and after this change full-syncs on
  every tick until every node runs the same build.
- (M117 follow-up) `brazier/build/program.absolute_path` returns
  `Result(String, String)`, and the resolver passed to
  `project_toml.pinned_dependency_line` returns one too.
- (M117 follow-up) `telemetry.store_sync_span`'s function returns
  `#(result, entries, bytes, outcome, reason)`: the outcome and reason are
  the stop event's `result` and `reason` metadata.

### Added

- (M118 followups) `[brazier, runtime, connection, forgotten]` telemetry
  when the runtime forgets a slow or gone connection, with `count` and
  `queue_len` measurements and `reason` (`slow` or `down`) and
  `connection_id` metadata.
- (M118 followups) docs/CLUSTERING.md documents `store.synced`,
  `store.list_synced` and the `[brazier, store, synced]` event.
- (M118 streams) `brazier/stream` declares streams (`stream.new` with a
  `KeepFirst` or `KeepLast` limit and an explicit codec) and builds their
  ops (`insert`, `insert_many`, `delete`, `delete_key`, `reset`), with the
  test helpers `stream.emitted` and `stream.round_trip`. The internal
  `stream_window` keeps each stream's keys and computes exact per-update
  deltas, trims included, and refuses every stream bound with a typed
  error. Shared delta and fault vectors are in
  `test/fixtures/stream_vectors.json` (`docs/design/STREAMS.md`).
- (M118 streams) Streams run end to end. Stream ops are effects, rendered
  by a stream container node whose items have item-relative handler ids
  (`i0`, `i0.2`), and the dead render fills them. Each connection keeps
  its own windows, so its indices are its own, and ops applied before any
  connection joins reach the first join as resets. An op on an undeclared
  stream, an oversized item, an over-max limit or a bad key is refused
  with an `error` frame and a log line, grouped per stream and reason. The
  build checks stream declarations and item render functions (named, no
  closures) and generates `stream_names()`.
- (M118 streams) The browser runtime applies the `streams` field of every
  frame: it keeps each rendered container in step item by item, keeps
  nodes across updates and moves (`moveBefore`), and keeps debounce and
  throttle per item. A stream fault logs a `console.error`, closes with
  4000 `stream fault` and reconnects; the join refills the streams.
- (M118 streams) `SecurityLimits.stream_max_limit` (1000, at most 1000),
  `stream_item_max_bytes` (65,536), `stream_ops_max_per_update` (1000),
  `stream_frame_max_bytes` (1,048,576) and `stream_key_max_bytes` (256),
  all validated.
- (M118 streams) Telemetry events `[brazier, stream, delta]` and
  `[brazier, stream, refused]`, and a `stream_bytes` measurement on the
  render span's stop.
- (M118 client) `examples/timeline`, the canonical stream example, with
  its browser slice (`make browser-timeline`).
- (M118 client) `docs/STREAMS.md`, the streams guide.
- (M118 client) Stream benches: `runtime.stream.append` and `chunk`,
  `wire.stream_patch`, `ssr.stream_300`, `client.stream.append.300` and
  `client.stream.chunk.300`. They have no baseline yet.
- (M118 streams-build) `store.synced` and `store.list_synced` report
  whether a replicated store's replica is in sync with every peer, as
  `Result(Bool, SyncedError)`: `NotReplicated(topic)` for a local store,
  `ReplicaFailed(WriteError)` when the replica can't answer. A
  `[brazier, store, synced]` telemetry event (`peers`, `store`) fires each
  time a replica comes into sync.
- (M118 streams-build) `gleam test` runs the client stream vectors.
- (M118 cluster) `replicated.synced/1` is true when every peer's last
  digest equals this replica's (and when there are no peers), and
  `replicated.context_size/1` reports the causal context's size.
- (M118 tests) The test runner fails a test that leaves messages in its
  mailbox and names them (`docs/TESTING.md`, "Mailbox residue"). No
  module is exempt.
- (M118 diff-shift) `test/brazier/bench/patch_bench.gleam` measures the
  model diff on sliding windows and on edits that are not shifts.

- (M117 transport follow-ups) A live navigation to another page's fragment
  (`/docs#install`, by a link or `router.push`) scrolls to it once the new
  page is rendered: to the element with that id, else the `<a>` with that
  name, or to the top with a console warning when there is neither, as
  LiveView's `Browser.pushState` does. To find that render, the client's
  `navigate` now carries a `clock` from the events' counter and the server
  acknowledges it like an event: the frame with the navigation's state
  carries `ack_clock` = `clock`, and a navigation that leaves the model as
  it was gets an empty ack patch (it used to get no frame). The field is
  additive: a `navigate` without `clock` is acknowledged at 0. A
  `router.push` path's fragment is no longer sent to the server.

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
- (PERF-9) Bench scenarios for:
  - static files of 100 KB and 10 MB, both served and revalidated with a 304
    from the digest cache
  - gzip of a 100 KB body
  - SSR at 100 and 1000 rows
  - presence track, untrack and list in rooms of 10 and 10000 entries
  - the browser client's render and patch path at 100 and 1000 rows, run in
    node against a built fixture app

  Each scenario checks the answers it times. The baseline now records the
  load average it was taken under.
- (M117 follow-up) The `[brazier, store, sync]` stop event carries `result`
  (`ok`, `malformed`, `too_large` or `too_many_entries`) and `reason` (the
  failing field of a malformed payload, or the limit a refused one broke:
  `max_delta_bytes`, `max_sync_bytes`, `max_entries`; `none` when merged),
  with the store and the peer node, so a refused payload is told apart from
  an empty one. Phoenix puts the outcome in the stop metadata the same
  way, as `[brazier, ws, upgrade]` does.

### Changed

- (M118 followups) The build refuses `data-brazier-stream` outside
  `stream.render` whenever it can know the attribute name statically: a
  literal, a constant (local or imported) or a `<>` join of them, given
  through `attribute.attribute`, `attribute.data` or `attribute.boolean`.
  A name computed at runtime is still refused by the attribute constructor
  and the render.
- (M118 followups) The client bundle build fails on a compiler warning in a
  file Brazier writes (copied Brazier modules, the log shim, the generated
  entry, `gleam.toml`, or a warning naming no file), listing each file,
  line, column and warning. A warning in the app's own code stays a logged
  warning. `program.gleam_build` returns warnings as a `Warning` type.
- (M118 followups) `scripts/run_cdp_shards_docker.sh` defaults the shard
  total to the number of examples the harness in the image selects, and
  refuses a larger total (those shards would run nothing and pass).
- (M118 followups) docs/WIRE_PROTOCOL.md says a navigation refused by the
  runtime is acked with an empty patch (one refused by the transport, or a
  hard navigation, is not), and gives the order a join receives frames in:
  the route error, the stream refusals held from `init`, then `model_sync`.
- (M118 backpressure) A navigation the runtime refuses with an `error`
  frame is followed by an empty patch acking its clock, so the client's
  pending fragment scroll settles on it instead of on a later event.
- (M118 backpressure) The non-monotonic clock warning names what carried
  the clock: an event, a batch event or a navigation.
- (M118 backpressure) The first join receives the stream refusals made
  before it (during `init`) as `error` frames before its `model_sync`, at
  most 32; past that it gets one error counting the rest, which are in the
  server log.

- (M118 diff-shift) The model diff (server and client, op for op) finds a
  shifted array middle in linear time with Knuth-Morris-Pratt. A sliding
  window (drop k items at the front, add m at the end) is k `remove` ops
  and one `append`, not a replace of the whole array: a 2000-item window
  went from 148091 bytes to 199 bytes and from about 6.5 ms to 340 µs. The
  mirror case (remove at the back, add at the front) is found by the same
  scan. There are no new op types.
- (M118 build) The generated client project gets a `manifest.toml`
  derived from the app's lock, so its `gleam build` never resolves
  versions from Hex. Parallel builds no longer hit the Hex rate limit, and
  two builds of one app compile the same client packages. The build fails
  with a message naming the fix, instead of resolving from Hex, on a
  missing app `manifest.toml`, a Hex entry without `outer_checksum`, a
  lock requirement with no entry of its own, or a
  `build/packages/packages.toml` that disagrees with the lock.
- (M118 transport) A join without a build id is a warning once per
  connection, then debug. In dev mode the page carries its dev build, and
  a join from before the last rebuild (a page between sockets during a
  rebuild) gets `reload` and is not dispatched.
- (M118 transport) `window.__brazierOutboundPendingForTest()` returns
  `{queued, scheduled, debounced}`, so a debounced send whose timer has not
  fired no longer looks drained.
- (M118 logs) Every WebSocket close log line reads "with <code> (reason
  <label>)", using the label the `[brazier, ws, close]` event reports. The
  three 4401 closes are told apart: `init_refused`, `session_revoked` and
  `authentication_expired`.
- (M118 logs) A refused security setting logs one line with the detail; the
  parsers (`parse_allowed_hosts`, `parse_allowed_origins`,
  `validate_drain_timeout`, `ip.parse_trusted_proxies`) no longer log their
  own refusal first.
- (M118 logs) The `uri_check` reason for a bad query string no longer
  contains the query, which can carry a token, and the 417 reason quotes the
  client's `Expect` value.

- (PERF-9) Every bench metric is gated:
  - A metric's tolerance is max(25%, spread), not max(25%, 2 × spread), so
    a 1.5× regression fails every gated metric.
  - A metric whose baseline spread is 50% or more is no longer reported and
    ignored. `make bench-baseline` refuses to write such a baseline, and
    `make bench-check` fails on it.
  - `make bench-check` also fails on a metric missing from the baseline or
    from the run.
  - Sample counts were raised until every metric's spread is under 50%.
  - Every bench p50 and p99 is now the median over rounds of each round's
    p50 and p99, not a percentile of every sample pooled, so a burst of
    outside load in one round does not set it. A scenario that times one
    long sequence cuts it into 5 consecutive rounds.
  - Each scenario runs in a fresh process. Timed in the bench process,
    whose heap grows run over run, several metrics drifted upward from run
    to run.

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
- Merging a delta into a replicated store no longer sorts the replica's
  whole causal-context cloud (the dots seen out of order). Only the
  replicas the delta names are compacted, from their clock upwards, so a
  one-dot delta against a 10,000-dot cloud fell from about 1.3 million
  reductions to the cost of the same merge against a 10-dot cloud. The
  result is the one the sort gave, checked against it as an oracle.
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
- (Wave 4 test hygiene) Telemetry handlers, sys watches and presence
  holders in the telemetry, presence and cluster tests are scoped to the
  test body (`monitored.with_handler`, `await.with_watch_info`,
  `with_watch_exit`, `with_watch_down`, `holder.with_holder`) and removed
  even when the body crashes, like ExUnit's `on_exit/1`.
  `presence/scoped_cleanup_test` shows it for watches and holders.
- (Wave 4 test hygiene) The multi-node tests wait for messages instead of
  polling. `peer.until` runs one check on a peer and checks again on each
  wake-up (`node_changes`, `process_down`, `pg_changes`, `events`,
  `events_on`, `receives`, `info`, `any`), draining queued wake-ups first.
  `peer.on_node`, `peer.registered`, `cluster/relay` (telemetry events and
  PubSub deliveries forwarded from a peer) and `presence/wake` support it.
  The pubsub, store and presence cluster tests no longer call
  `peer.eventually`; the store tests wait on the
  `[brazier, store, sync, stop]` span event.
- (Wave 4 test hygiene, TS-12) The unused `sleep_ms` helper is gone from
  `brazier_ws_test_ffi`, the runtime
  telemetry test asserts the exact exit reason, and every `let assert` in
  the touched tests carries an `as` message.

### Fixed

- (M118 backpressure) A dead connection read as 1000000000 queued
  messages, and a slow one was closed again, with another warning, on
  every broadcast. The runtime now monitors each connection's owner (as
  `Phoenix.Channel.Server` does) and forgets a slow or gone connection
  once, with one log line.
- (M118 backpressure) A join after the first, or a rejoin, that changed
  the route got the route's model but not its stream entries, so its
  windows disagreed with every later op. The joiner's windows now exist
  before its route runs, and its `model_sync` carries the route's entries.

- (M118 lifecycle) A page title over `runtime.title_max_bytes` is reported
  once each time it goes over the limit, not after every update. Going
  back within the limit is logged, and going over again is reported again.
- (M118 lifecycle) `application.wait_forever` no longer returns when an
  unrelated linked process exits normally. Only the normal exit of an
  application it waits on ends the wait. Other normal exits are logged,
  and abnormal exits still end it loudly.
- (M118 lifecycle) An application whose tree crashes is forgotten at once,
  with its bound port, and the crash is logged with its reason. SIGTERM no
  longer finds a crashed tree still recorded, and `stop` returns only
  after the record is cleared.
- (M118 lifecycle) The `ws8c_runtime_stop_test` flake is explained: on
  OTP 28 the scheduler can hold back a monitor signal, so the DOWN said
  `noproc`. The barrier added in Milestone 117 fixes it; a replay test now
  covers the `noproc` case.
- (M118 tests) The store-replica tests wait for the peer's
  `[brazier, store, sync, stop]` events instead of polling, and
  `peer.eventually` is removed. The supervisor-restart tests wait on a
  supervisor hook instead of spinning on `erlang:yield`.
- (M118) `pubsub_test` left both forwarded broadcasts in the mailbox of
  the next test, and `join_build_test` its `on_close` notices; they now
  receive them.
- (M118) The prebuilt runtime bundle in `priv/static` is rebuilt, so it
  carries the shifted-array diff.
- (M118 cluster) Cluster membership is per distribution connection: a stale
  verified row no longer survives between a disconnect and the nodedown.
  Peer-check waits survive a cluster manager restart. Session re-checks
  and store syncs wait until both sides have verified each other, so a
  revocation is no longer lost while only one side has.
- (M118 cluster) A refused replicated-store merge backs off per peer
  (jittered, capped at max(interval, 60 s), logged as a warning). Replicas
  raise per-node floors once in sync, so the causal context no longer
  gains an entry on every replica restart. A replica that sees its own
  node's floor above its incarnation logs an error, stops, and restarts
  above it.
- (M118 residue) Creating a named ETS table crashed the caller when the
  table owner the lookup found was gone before it was monitored (it had
  just handed its tables over, or died). The creation now looks the owner
  up again, within the same bounded number of attempts as a moved owner.
- (M118 residue) `build_handshake_test`, `dev_reload_test`,
  `ws_protocol_test` and `http_server_test` receive every message they
  cause. Two `http_server_test` tests that flaked on a telemetry event
  left in the mailbox now receive each event exactly.
- (M118) The CRDT append cost test flaked because a garbage collection in
  the test process was counted as the append's reductions. The cost is
  now measured in a fresh process with room for the work, and a trace
  session asserts no collection ran during it.
- (M118 client) A live navigation (a link, `router.push`,
  `router.replace`) replaces the page instead of morphing the old one into
  it, so pages no longer need an `element.keyed` root, and it scrolls to
  the top when the URL has no fragment. Back and forward keep the browser's
  scroll restoration.
- (M118 client) docs/HTML_ELEMENTS.md named a `Brazier.hooks` object and an
  `updated` callback that don't exist; it now names
  `window.brazierClient.registerHook` and `update(node, state)`.
- (M118 streams-build) The dead render refused nothing: an op on an
  undeclared stream is now refused there with `unknown_stream`, as live.
- (M118 streams-build) `data-brazier-stream` is refused outside
  `stream.render`, by the build and by the render.
- (M118 streams-build) The build refuses a stream item function from a
  dependency or a Brazier module (it can't check it is named), and fails
  when it can't resolve a stream's item type; before, it went on with no
  type. The client allowlist message lists `brazier/stream`.
- (M118 streams-build) The generated client project's build warnings were
  thrown away; each is now logged at warning level with its location.
- (M118 streams-build) A log line keeps at most 256 bytes of a page path
  (never splitting a character) and says after the closing quote how many
  bytes it left out.
- (M118 residue2) `await.until_telemetry` (a test helper) left events in
  the mailbox: one that arrived after the condition held, or from an
  emitter that found the handler just before the detach. Its handler now
  sends through a per-call process alias, closed and flushed after the
  detach, and it crashes naming what it waited for when the deadline
  passes. `runtime_test`, `runtime_telemetry_test`,
  `runtime_versioning_test` and `session_security_test` receive every
  frame they cause and stop their runtimes.
- (M118 streams) The client's `syncHooks` threw its invariant when one
  frame inserted a key and then deleted it.
- (M118 logs) A static file name longer than the file system allows is a
  404 logged at debug (as in Plug.Static), not a 500 with an error log.
- (M118 logs) A malformed forwarding hop is logged once per WebSocket
  connection. Before, the middleware gate, each join and each navigation
  resolved the client again and logged it again.

- (M117 transport follow-ups) A WebSocket upgrade logged a malformed
  forwarding hop (and a `Forwarded` request's unconfigured `X-Forwarded-*`
  headers) twice: the per-IP cap and the Origin check each parsed the
  forwarding header. The upgrade now resolves the address and scheme
  together, from one parse (`ip.client`), and logs each problem once.
- (M117 transport follow-ups) `start_listener` and `transport.supervised`
  logged "Invalid security limits" and "Invalid static config" twice, in
  the check and again in the listener. Each refusal is logged once, and the
  static config is checked only after the limits pass.
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
- (Audit TS-12) `brazier/lint` has a `let-assert-message` rule: a
  `let assert` in `src/` without an `as` message, or with an empty one, is
  a violation, and the last ten such asserts have messages. The lint also
  skipped every directory named `build`, so `src/brazier/build` was never
  linted; only the `build` next to a `gleam.toml` is skipped now.
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
    sometimes cut the two verified members apart. The manager no longer
    disconnects (see the next entry), and the tests run on OTP's defaults.
- (Audit fix-cluster-reject) Rejecting a peer could partition the verified
  members. The manager called `erlang:disconnect_node/1` on a rejected
  peer. Under OTP's default `prevent_overlapping_partitions`, `global` on
  the rejecting node then told every other node that it had lost the peer,
  and each of them cut its own link to that peer in turn. One rejected
  intruder could leave the real members of a deployment apart, and with no
  discovery nothing reconnected them. A rejected peer now stays connected
  and is not a member: it is logged at error level and reported with
  `[brazier, cluster, peer, rejected]` as before, and its later hello is
  checked again. OTP 25's `global_group` made the same change
  (`disconnect_nodes/1` excludes a node instead of disconnecting it), and
  Mnesia likewise ignores connected nodes outside `db_nodes`. A process
  waiting for a node to pass the check keeps waiting through a rejection.
- (Wave 4) A client hook element that stays in the page but loses its
  `data-brazier-hook`, or names another hook, now unmounts the old hook
  (and mounts the new one). Before, the old hook stayed mounted and a hook
  added back later never mounted again. This is LiveView's
  `View.performPatch`, which destroys a removed or changed `phx-hook`.
- (Wave 4) Clicking an in-page fragment link (`#section`, `/this/page#x` or
  `#`) is left to the browser, which scrolls to the anchor; the client no
  longer prevents it. Back and forward between fragments of the same page
  send no `navigate`. A link to another page's fragment keeps the fragment
  in the pushed URL and sends the server only the path. This is LiveView's
  `DOM.isNewPageClick` and its popstate rule.
- (Wave 4) Keyed children (`data-brazier-key`, or `id`) are matched by key
  at any distance, so a reorder moves elements instead of rebuilding them:
  every keyed element keeps its identity, focus, selection and mounted hook
  (morphdom's and idiomorph's id matching). A key rendered with another tag
  is a new element; before, the old element kept its old tag. A key
  repeated among siblings is logged as an error, and only the first keeps
  the element. A focused input that moves keeps its unacknowledged value.
- (Wave 4) A WebSocket that closes before it opens (how a browser reports a
  refused upgrade, an unreachable server, or a disallowed origin) still
  reconnects with the capped backoff, and from the third such close in a
  row logs an error that names those causes, instead of a warning each
  time. An opened socket resets the count. A seeded random morph test in
  the client harness checks that the DOM matches the markup, keyed elements
  survive, and mounted hooks match hook elements after every render.
- (Audit TS-12) Every `let assert` in `runtime_versioning_test` has an `as`
  message.
- The client bundle cache could serve a stale bundle. It checked an entry
  against the file's size and mtime only, so a same-size rewrite in the
  same second, or a rename of a new file with the same size and mtime over
  the old one, kept the old bytes and ETag. An entry is now checked against
  the size, mtime, ctime, inode and device, and one recorded less than 2 s
  after the file's last change is rebuilt rather than trusted (git's
  racy-clean rule, `Documentation/technical/racy-git.txt`), the rule the
  static digest cache already follows. The recording time is taken before
  the read. `static.load_client_asset_at` takes the time and reports
  whether the entry was used or why it was rebuilt; misses are logged at
  debug.
- The CDP suite's `stop_server` only logged a page that did not unload, in
  verbose mode. Now that, an output reader that outlives the server, and a
  port still open are each recorded as a failure, and `stop_server` returns
  False, so `start_example` does not start the next example against a page
  still connected to the old server.
- (M117 follow-up) A replicated store's digest is kept up to date by every
  merge instead of computed on each sync tick: the XOR of a SHA-256 hash of
  each live entry, clock entry and cloud dot, updated with the elements a
  merge adds and removes (Riak's TicTac AAE `leveled_tictac`;
  delta_crdt_ex updates its MerkleMap on every change). A tick used to sort
  and hash the whole state, O(n log n); it is now O(1), and a write costs a
  few hashes more.
- (M117 follow-up) `brazier/build/program.absolute_path` reads the current
  directory itself and returns its error (`Cannot resolve PATH: cannot read
  the current directory: REASON`, logged at error) when the directory was
  deleted under the VM or is no longer searchable. `filename:absname/1`
  crashed the build with a `badmatch` there, behind an `Ok` the FFI spec
  promised always.

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
- A replicated store checks every field of a delta or full state from
  another member (keys, dots, replicas, timestamps, topics, the clock and
  cloud, and that each live dot is covered by its own context) before it
  reads or joins it. A malformed payload is refused, logged at error with
  the failing field and reported in the `[brazier, store, sync]` span with
  `entries` 0, `result` `malformed` and the field as `reason`; the replica
  keeps its state. It used to read the payload
  unchecked, so a malformed term from a verified member crashed the
  replica or was joined (Phoenix.Tracker validates a replica's message
  before merging it).
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
  upgrade (a refusal closes the socket with 4600; see Breaking), and at every `navigate` and
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
- (Audit SEC-11) The rest of the client paths are quoted too: static
  serving, the HTTP head and body-length logs, multipart upload logs and
  errors (field names and parameter keys), client-IP resolution, and an
  invalid `Content-Length` value. Filesystem paths built from a request are
  quoted with `string.inspect`.
- (SEC-4 follow-up) The scheme comes from the configured forwarding header
  only. `X-Forwarded-Proto` was read whatever `forwarding_header` said, so
  behind a proxy that sets `Forwarded` a client could send its own
  `X-Forwarded-Proto: https`, and `Forwarded` `proto=` was never read. Now
  `ip.Forwarded` reads the `proto=` of the client's element (the one the
  address walk stops at), `ip.XForwardedFor` reads `X-Forwarded-Proto`, and
  `ip.NoForwardingHeader` is always `http` (before, a listed proxy's
  `X-Forwarded-Proto` was believed). A repeated `proto=` in one element is
  rejected (RFC 7239 section 4). `ip.client_scheme` is the rule;
  `client.scheme_from` calls it. Plug.RewriteOn and Django's
  `SECURE_PROXY_SSL_HEADER` likewise read only the header they are given.
- (TS-9 follow-up) The listener parses `trusted_proxies` once, when it
  starts, with the origins and hosts, and refuses to start on a bad entry;
  WebSocket upgrades no longer parse the list again for the client address
  and the Origin check's scheme.
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
