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
- **Issue:** `store.StoreError` aliases `state_manager.EtsError`
  (`store.gleam:44`), and `state_manager` is an internal module, so an app
  cannot match or describe the error without importing it.
  - **Files:** `src/beacon/store.gleam`, `src/beacon/state_manager.gleam`
- **Issue:** `beacon/rate_limit` is an internal module (`gleam.toml`
  `internal_modules`), but `middleware.rate_limit` needs a
  `rate_limit.RateLimiter` from `rate_limit.new`.
  - **Files:** `gleam.toml`, `src/beacon/rate_limit.gleam`
- **Issue:** `beacon.title` is computed only for the HTML render
  (`ssr.gleam:308`); a client navigation leaves `document.title` unchanged.
  - **Files:** `src/beacon/ssr.gleam`, `beacon_client/`
- **Issue:** a join token whose model does not decode is logged and the
  session continues with the state `init` returned (`runtime.gleam:920-929`),
  a silent degradation for the user.
  - **Files:** `src/beacon/runtime.gleam`
- **Issue:** `transport/http.read_body` returns `Result(BitArray, String)`
  and is internal (`transport/http.gleam:508`); the public way to read a body
  is `api.read_text` / `api.read_form`. Older docs pointed users at
  `read_body`.
  - **Files:** `src/beacon/transport/http.gleam`
- **Issue:** the `Dockerfile` HEALTHCHECK comment (`Dockerfile:66-67`) says
  Beacon has no built-in health route; `/health` exists.
  - **Files:** `Dockerfile`
- **Issue:** `examples/auth_workspace` checks the login form against a
  constant CSRF token (`auth_workspace/app.gleam:12`), so the login CSRF
  check does not protect anything.
  - **Files:** `examples/auth_workspace/src/auth_workspace/app.gleam`
- **Issue:** several simulation tests allow leaked processes or failed
  connections (`sim_test.gleam:177`, `:247`, `:320`, `:377-379`), against
  TIGERSTYLE's zero-leak rule.
  - **Files:** `test/beacon/sim_test.gleam`

## Resolved Issues

<!-- Move resolved issues here with full resolution details -->

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
