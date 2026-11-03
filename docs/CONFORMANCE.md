# Beacon Conformance Matrix

Beacon's framework contract is tested through a small set of canonical apps.
Each canonical app must cover a real composition of features, not isolated smoke
checks.

## Canonical Examples

| Example | Contract |
| --- | --- |
| `examples/counter` | Minimal server-authoritative model update |
| `examples/counter_local` | Client-only Local state with zero WebSocket traffic |
| `examples/local_first_form` | Local draft/dropdown state with model submit boundary |
| `examples/private_session` | `Server state` privacy and server-only state stripping |
| `examples/routed` | Explicit imported route modules with root-owned `Model`/`Msg` |
| `examples/routed_workspace` | Explicit route-aware app with Local/model state |
| `examples/route_server_workspace` | Explicit route mini-apps with route-local private `Server` state |
| `examples/auth_workspace` | API login/logout, HttpOnly auth cookie, CSRF, `ws_auth` with `auth.allow_guests_ws`, `init` through `auth.init_from_session`, a role-gated route, route-aware SSR, and server-private session state |

## Required Checks

Every canonical example should be covered by:

- Clean `gleam build` from source.
- Build-pipeline analysis proving the generated client-state bundle shape is supported.
- Server-side integration tests for HTTP, WebSocket, cookies, and security boundaries.
- Browser/CDP tests for SSR first paint, hydration, DOM stability, local-only traffic,
  server-authoritative patches, route navigation, and console errors.

The repeatable browser entrypoint is:

```sh
make browser-canonical
```

That command starts a temporary headless Chrome with CDP enabled and runs the
canonical matrix in both desktop and mobile viewport profiles:

```sh
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py --canonical --viewport desktop
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py --canonical --viewport mobile
```

For a narrower loop, use `make browser-canonical-desktop`,
`make browser-canonical-mobile`, or set `BEACON_CDP_VIEWPORTS`.

The canonical target intentionally runs the contract examples only. To exercise
every example covered by `test_all_cdp.py`, run the full matrix:

```sh
make browser-all
```

For a narrower full-matrix loop, use `make browser-all-desktop`,
`make browser-all-mobile`, or pass an example name through the script:

```sh
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py canvas --viewport desktop
```

For container-parallel CI, shard the selected example list with `--shard`:

```sh
BEACON_CDP_VIEWPORTS=desktop BEACON_CDP_SHARD=1/4 make browser-all-shard
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py --canonical --shard 2/4
```

Sharding is deterministic over the harness example order and applies after the
optional canonical/filter selection.

For local per-container sharding, use the Docker runner:

```sh
BEACON_CDP_TOTAL_SHARDS=23 BEACON_CDP_VIEWPORTS=desktop BEACON_CDP_PARALLEL=5 make browser-all-docker-shards
```

The Docker runner also supports selected shard lists and warmed images:

```sh
BEACON_CDP_SHARDS="1,6,11" BEACON_CDP_TOTAL_SHARDS=23 make browser-all-docker-shards
BEACON_CDP_PREBUILD_EXAMPLES=1 BEACON_CDP_TOTAL_SHARDS=23 make browser-all-docker-shards
BEACON_CDP_SKIP_DOCKER_BUILD=1 BEACON_CDP_DOCKER_IMAGE=beacon-cdp:boxd make browser-all-docker-shards
```

Latest measured local timings on the 10 CPU / 16 GB development host:

- Sequential desktop all-example container run: 11:59, with the final failure
  fixed by the current Pong pause-position assertion.
- Docker shards, 23 total / 5 concurrent: 8:11, 361 passed, 0 failed, 506
  skipped.
- Docker shards, 23 total / 10 concurrent: 5:32, unstable under host pressure.
- Docker shards, 23 total / 7 concurrent: 7:29, unstable under host pressure.

Latest Boxd measurement with five 4 vCPU / 16 GB VMs, forked from one warmed
base image but before example build artifacts were baked into the image:

- Slowest VM: 6:25 for its selected shard list.
- Aggregate run was not accepted: several examples timed out at startup during
  first compile, and Pong had one timing assertion failure on one worker.
- Conclusion: Boxd has enough aggregate CPU/RAM, but the runner must use
  `BEACON_CDP_PREBUILD_EXAMPLES=1` on the base image and
  `BEACON_CDP_SKIP_DOCKER_BUILD=1` on forks before comparing throughput.

Latest Boxd measurement after baking example build artifacts and skipping the
Docker image probe on forks:

- 22 of 23 shards passed; slowest VM completed in 5:42.
- The remaining shard exposed a real Beacon auto-build bug:
  `route_server_workspace` selected an imported route page as the app module.
- After fixing app-module discovery, focused shard 22 passed in 1:14.

CDP example startup is part of the assertion surface. If an attempted example
server exits or fails to become ready before timeout, the browser run fails.

CI should run `make browser-canonical` after `gleam build`, `gleam test`, and
`gleam run -m beacon/lint`. Set `CHROME_BIN`, `CDP_PORT`, or `PYTHON_BIN`
explicitly when the CI image does not expose the defaults.

## Auth Workspace Contract

`examples/auth_workspace` is the canonical full-stack auth app. It must keep the
following guarantees:

- `/login` renders without an authenticated session.
- `POST /api/login` requires the login CSRF field, creates a server-side session,
  and sets `beacon_session` as an HttpOnly cookie.
- `GET /api/me` requires `beacon_session`.
- `POST /api/profile` requires the authenticated session and matching CSRF token.
- `POST /api/logout` requires CSRF, deletes the server session, and clears the cookie.
- A WebSocket upgrade without `beacon_session` connects as a guest
  (`auth.allow_guests_ws`); one with a signed-in session is bound to it, so
  logout closes the socket.
- `init` loads the account from `beacon_session` through
  `auth.init_from_session`, on the HTML render and on the connected mount. A
  session store that cannot answer refuses the page with 503 and the socket
  with close code 4503.
- `/admin` shows its content only to an account with the admin role, and
  `update` refuses admin events from any other account.
- Server-only fields such as session ID, CSRF token, audit key, and audit log never
  appear in the public client model, DOM, or client bundle.

## Browser Harness Status

`test_all_cdp.py --canonical` contains browser coverage for the canonical
`counter`, `counter_local`, `local_first_form`, `private_session`, `routed`,
`routed_workspace`, `route_server_workspace`, and `auth_workspace` slices. The
browser harness runs through the project-local `.venv` and
`requirements-dev.txt`. `make browser-all` removes the canonical filter and
runs every example slice implemented in the harness. `--shard INDEX/TOTAL`
splits that same list for per-container parallel runs.

The permanent harness now asserts:

- DOM mutation buckets stay under a fixed threshold instead of only checking final text.
- `layout-shift` entries stay below the accepted cumulative threshold.
- Mobile canonical runs have no horizontal overflow at DOM stability checkpoints.
- Browser startup failures, console errors, runtime exceptions, and early
  hydration errors are captured as test failures.
- Local-only events send zero model WebSocket events.
- Model events receive `patch` or `model_sync` frames and do not receive post-update
  HTML `mount` frames.
- Explicit route apps restore URL and view state through browser back/forward
  and send `navigate` frames from `popstate`.
- Reconnect tests force a real browser WebSocket close, wait for the reconnect
  `join`, then prove the app remains interactive without duplicate model events.
  The forced-close hook is only enabled when the CDP harness injects
  `window.__BEACON_ENABLE_TEST_HOOKS`.

Latest routed slice run:

```sh
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py routed -v
```

Result: 22 passed, 0 failed, 18 skipped. The routed slice asserts SSR first
paint, client-side route navigation, model event state sync/patches, no normal
post-update `mount` frames, static not-found rendering, DOM mutation bucket
limits, and layout-shift limits.

Latest new example slices:

```sh
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py local_first_form -v
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py route_server_workspace -v
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py auth_workspace -v
```

Results:

- `local_first_form`: 10 passed, 0 failed, 20 skipped
- `route_server_workspace`: 11 passed, 0 failed, 20 skipped
- `auth_workspace`: 11 passed, 0 failed, 20 skipped

Latest canonical browser run:

```sh
make browser-canonical-desktop
make browser-canonical-mobile
```

Results:

- `desktop`: 227 passed, 0 failed, 15 skipped
- `mobile`: 235 passed, 0 failed, 15 skipped

Latest route-history/reconnect canonical runs:

```sh
make browser-canonical-desktop
make browser-canonical-mobile
```

Results:

- `desktop`: 227 passed, 0 failed, 15 skipped
- `mobile`: 235 passed, 0 failed, 15 skipped

Latest all-example desktop run:

```sh
make browser-all-desktop
```

Result: 361 passed, 0 failed. This full run also verifies the older example
slices that are not part of the canonical contract matrix: Kanban, Canvas,
Snake, Chat, Dashboard, Pong, Triple Counter, Todo, Cart, Spreadsheet, AI Chat,
middleware, and explicit multi-file domain examples.

These runs cover the full canonical matrix with DOM mutation bucket checks,
cumulative layout-shift checks, parsed WebSocket frame assertions, Local-only
no-traffic assertions, server-private bundle/DOM privacy checks, route
navigation, auth API flow, no normal post-update HTML `mount` frames, and
mobile horizontal-overflow checks. The latest route-history/reconnect runs also
cover browser back/forward route restoration and forced WebSocket reconnect for
both unauthenticated and authenticated sessions.
