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

- **Issue:** dev-mode browser reload never reaches a browser.
  - **Context:** `dev.gleam:151` calls `notify_browser_reload`, which sends to
    the local subscribers of `beacon:reload` (`beacon_dev_ffi.erl:155`).
    Nothing subscribes to that topic, and `transport.ServerReload`
    (`transport.gleam:106`, handled at `:642`) is never constructed.
  - **Files:** `src/beacon/dev.gleam`, `src/beacon_dev_ffi.erl`, `src/beacon/transport.gleam`
- **Issue:** the dev watcher falls back to polling every 500 ms when neither
  `fswatch` nor `inotifywait` is installed (`dev.gleam:104-107`), against the
  no-fallbacks rule.
  - **Files:** `src/beacon/dev.gleam`
- **Issue:** `middleware.body_parser(max_bytes)` passes through a request whose
  `Content-Length` is missing or does not parse (`middleware.gleam:282`).
  - **Files:** `src/beacon/middleware.gleam`
- **Issue:** `middleware.Context` (`new_context`, `set_context`,
  `get_context`, `middleware.gleam:519-538`) is carried by nothing; its doc
  comment says it passes data to the handler.
  - **Files:** `src/beacon/middleware.gleam`
- **Issue:** `/health` answers every method, not only GET and HEAD
  (`transport.gleam:2374`).
  - **Files:** `src/beacon/transport.gleam`
- **Issue:** `beacon.title` is computed only for the HTML render
  (`ssr.gleam:308`); a client navigation leaves `document.title` unchanged.
  - **Files:** `src/beacon/ssr.gleam`, `beacon_client/`
- **Issue:** `transport/http.read_body` returns `Result(BitArray, String)`
  and is internal (`transport/http.gleam:508`); the public way to read a body
  is `api.read_text` / `api.read_form`. Older docs pointed users at
  `read_body`.
  - **Files:** `src/beacon/transport/http.gleam`
- **Issue:** the `Dockerfile` HEALTHCHECK comment (`Dockerfile:66-67`) says
  Beacon has no built-in health route; `/health` exists.
  - **Files:** `Dockerfile`
- **Issue:** several simulation tests allow leaked processes or failed
  connections (`sim_test.gleam:177`, `:247`, `:320`, `:377-379`), against
  TIGERSTYLE's zero-leak rule.
  - **Files:** `test/beacon/sim_test.gleam`

## Resolved Issues

<!-- Move resolved issues here with full resolution details -->

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
