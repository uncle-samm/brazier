# Beacon — Issues, Bugs, and Deferred Items

> Track all issues here with full context. When fixing a bug, document:
> what broke, why, and how the fix prevents recurrence.

## Open Issues

<!-- Add issues here with:
  - **Issue:** one-line description
  - **Context:** what was happening when this was discovered
  - **Error:** exact error message if applicable
  - **Files:** relevant source files
  - **Attempted:** what was tried (if anything)
  - **Resolution:** how it was fixed (fill in when resolved)
-->

Found while making the docs match the code (Milestone 117, WS10a, 2026-11-03).
The docs describe the current behaviour; each item is a code change.

- **Issue:** `transport/http.read_body` returns `Result(BitArray, String)`
  and is internal (`transport/http.gleam:508`); the public way to read a body
  is `api.read_text` / `api.read_form`. Older docs pointed users at
  `read_body`.
  - **Files:** `src/beacon/transport/http.gleam`
- **Issue:** several simulation tests allow leaked processes or failed
  connections (`sim_test.gleam:177`, `:247`, `:320`, `:377-379`), against
  TIGERSTYLE's zero-leak rule.
  - **Files:** `test/beacon/sim_test.gleam`

Found while merging WS10b (Milestone 117, 2026-11-04).

- **Issue:** `ws_client_ip` parses `trusted_proxies` again on every upgrade
  (`transport.gleam`); the listener could parse them once when it starts.
  - **Files:** `src/beacon/transport.gleam`
- **Issue:** a join without a build id is logged as a warning on every join
  (`transport.check_join_build`). A client that loads the unversioned
  `/beacon_client.js` fills the log; one warning per connection is enough.
  - **Files:** `src/beacon/transport.gleam`
- **Issue:** the client manifest has two readers (`transport.check_join_build`
  and `ssr`), and the join path reads it from disk on every join, a cost
  the benches do not measure. Production could read it once; dev mode needs
  the re-read.
  - **Files:** `src/beacon/transport.gleam`, `src/beacon/ssr.gleam`, `bench/`
- **Issue:** an `init` refusing with 409 closes with 4409, the same code as
  a stale build, so the two cannot be told apart from the close code.
  - **Files:** `src/beacon/error.gleam`, `src/beacon/transport/ws.gleam`
- **Issue:** `beacon_application_ffi:receive_wait_event` takes any
  `{'EXIT', _, normal}` as a shutdown request, so a linked helper that exits
  normally stops the wait.
  - **Files:** `src/beacon_application_ffi.erl`
- **Issue:** the node-wide app record keeps the `persistent_term` entry of a
  tree that crashed until a `stop` or a SIGTERM finds it not running.
  - **Files:** `src/beacon_application_ffi.erl`
- **Issue:** a page that is reconnecting while dev mode rebuilds misses the
  `reload` (it is not subscribed between sockets); it then joins with a
  stale build and reloads through 4409 instead, behind the reload guard.
  - **Files:** `src/beacon/transport.gleam`
- **Issue:** `window.__beaconOutboundPendingForTest()` does not count a
  debounced send whose timer has not fired (`beacon_client_ffi.mjs`).
  - **Files:** `beacon_client/src/beacon_client_ffi.mjs`, `test_all_cdp.py`
- **Issue:** a title over `runtime.title_max_bytes` is reported with an
  `error` frame and a log line after every update while it stays too large.
  - **Files:** `src/beacon/runtime.gleam`

## Resolved Issues

<!-- Move resolved issues here with full resolution details -->

- **Issue:** `beacon.title` was computed only for the HTML render
  (`ssr.gleam:308`); a client navigation or a live update left
  `document.title` unchanged.
  - **Files:** `src/beacon/runtime.gleam`, `src/beacon/transport.gleam`,
    `src/beacon/application.gleam`, `beacon_client/`
  - **Resolution:** (WS10b) `RuntimeConfig.title` carries the app's title.
    The runtime sends a `title` frame on every join and after an update that
    changes the title (it is a function of the server state, so it can
    change when the client model does not). The client sets
    `document.title`. A title over `runtime.title_max_bytes` is logged and
    reported with an `error` frame instead. LiveView sends `page_title` the
    same way, in the join render and then only when it changes.
    `runtime_title_test` covers it.

- **Issue:** `store.StoreError` aliased `state_manager.EtsError`
  (`store.gleam:44`), and `state_manager` is an internal module, so an app
  could not match or describe the error without importing it.
  `replicated.StartError.InvalidName` carried the same internal type.
  - **Files:** `src/beacon/store.gleam`, `src/beacon/store/replicated.gleam`
  - **Resolution:** (WS10b) `store.StoreError` is a store type
    (`InvalidName`, `TableTypeMismatch`, `TableOwnerUnavailable`) with
    `store.describe_error`, converted from the internal error in one place.
    `replicated.InvalidName` carries `name` and `reason`. `store_test`
    matches each constructor through `beacon/store`.
- **Issue:** `beacon/rate_limit` was an internal module (`gleam.toml`
  `internal_modules`), but `middleware.rate_limit` needs a
  `rate_limit.RateLimiter` from `rate_limit.new`.
  - **Files:** `gleam.toml`, `src/beacon/rate_limit.gleam`
  - **Resolution:** (WS10b) `beacon/rate_limit` is public. The test-only
    `owner` is `@internal`, and `config` and `max_keys` read a limiter's
    settings. `internal_modules_test` checks the module stays public.

- **Issue:** a join token whose model does not decode was logged and the
  session continued with the state `init` returned (`runtime.gleam:920-929`),
  a silent degradation for the user.
  - **Files:** `src/beacon/runtime.gleam`
  - **Resolution:** (WS10b) `runtime.check_join_token` refuses a token that
    does not verify, a model `restore` refuses, and a missing token with
    state recovery enabled. On the session path the check runs before
    `init`, and the refusal closes the socket with 4400, so the browser
    reloads for a fresh token, as LiveView does with a stale session token.
    A join on a runtime without the upgrade request gets an `error` frame
    ("join refused") and stays unjoined. `runtime_test` covers each case.
- **Issue:** `middleware.body_parser(max_bytes)` passed through a request whose
  `Content-Length` was missing or did not parse.
  - **Resolution:** (Milestone 117, WS10b-T) `body_parser` applies the
    listener's framing rule (`transport/http.declared_body_length`): a
    repeated or non-decimal `Content-Length` is 400, `Transfer-Encoding` is
    501 (400 with a `Content-Length`), over the limit is 413, and no header
    means no body. Tests: `middleware_test.body_parser_rejects_*`.
- **Issue:** `middleware.Context` (`new_context`, `set_context`,
  `get_context`) was carried by nothing; its doc comment said it passed data
  to the handler.
  - **Resolution:** (Milestone 117, WS10b-T) removed, with its tests. Request
    data reaches a handler through the request itself, as in Plug, where the
    conn is the only carrier.
- **Issue:** `/health` answered every method, not only GET and HEAD.
  - **Resolution:** (Milestone 117, WS10b-T) other methods get 405 with
    `allow: GET, HEAD`, and the answer carries `cache-control: no-store`.
    Tests: `http_routes_test.health_*`.
- **Issue:** dev-mode browser reload never reached a browser: `dev.gleam`
  sent to the subscribers of `beacon:reload`, and nothing subscribed.
  - **Resolution:** (Milestone 117, WS10b-T) as in Phoenix.LiveReloader,
    `dev.start` turns live reload on before it starts the app, every
    WebSocket handler then subscribes to `beacon:dev:reload`, and each
    rebuild sends every open page a `reload`. A handler that cannot
    subscribe closes 1011.
- **Issue:** the dev watcher fell back to polling every 500 ms when neither
  `fswatch` nor `inotifywait` was installed, against the no-fallbacks rule.
  - **Resolution:** (Milestone 117, WS10b-T) a native watcher is required;
    dev mode checks for it before building and exits with status 1 naming the program to install.
