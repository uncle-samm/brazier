# Testing

```sh
gleam test          # unit, runtime, transport, sim, stress, cluster, client JS
make test-client    # the client JS checks alone (fast loop)
make test-flake     # gleam test 5 times under 8 busy loops
make browser-all    # every example through Chrome DevTools Protocol
make bench-check    # benchmarks against the committed baseline (not a test)
```

A change is done when all of the following pass:

- `gleam build --warnings-as-errors`
- `gleam format --check src test`
- `gleam test`
- `gleam run -m brazier/lint`
- the CDP suite

CI runs the same steps (see [CI](#ci)).

## Requirements

`gleam test` needs **node** on `PATH`. The client runtime is tested by
running it, so a missing node is a test failure, never a skip. Several
tests depend on it:

- `patch_test`: runs the client's patch application on server-made vectors
  (`brazier_client/test/patch_vectors.mjs`), its patch safety checks
  (`patch_safety.mjs`, which also prints the client's unsafe-key list for
  comparison with the server's) and the comparison of its apply engine with
  the per-op copying engine it replaced (`apply_equivalence.mjs`).
- `router_test`: runs the client's navigation-path rule on the server's
  cases (`local_path_parity.mjs`) and holds every verdict equal to
  `router.check_local_path`'s.
- `runtime_versioning_test`: runs the client sync state machine
  (`sync_vectors.mjs`) and its FFI harness (`ffi_harness.mjs`).
- `build_fixture_test`: also needs **npx**, which runs the pinned esbuild
  (`esbuild@0.25.12` in `src/brazier/build/program.gleam`) exactly as
  `brazier/build` does. The first run downloads it into the npx cache.

`make test-client` runs `ffi_harness.mjs`, `patch_safety.mjs` and
`apply_equivalence.mjs` directly.
These are the client checks that need no Gleam-generated input. It is the
quick loop when you are changing `brazier_client/src`, and it fails
immediately, by name, when node is missing.

The CDP suite needs Chrome and the project-local Python environment
(`.venv`, with `websocket-client`).

## Rules

These follow CLAUDE.md, applied to tests.

- **Assert the value, not the absence of a crash.** A test that only
  checks `Ok(_)`, `True`, or that a call returned proves nothing about
  behaviour. Assert the concrete result: the exact log line, the decoded
  message, the count, the error variant. A log test captures the log
  line and compares it. A token test checks the token's structure and
  that the secret is not in it.
- **Test the unhappy path.** For every accept test there is a refuse
  test. A cap test must use input that only the cap rejects. For
  example, the 24 h session-token cap is tested with a 25 h old token
  and a max_age of 999_999, so it fails if the cap is removed.
- **No sleeps.** Wait for the event the test expects (see below). A sleep
  is allowed only when the passage of wall-clock time is the thing under
  test, and it must carry a comment saying so. Those that remain are
  listed under [Deliberate waits](#deliberate-waits).
- **Bounded waits fail loudly.** Every wait has a deadline. When it
  passes, the test crashes and says what it waited for and what arrived
  instead.

## Waiting for events: `brazier/await`

`test/brazier/await.gleam` follows the ExUnit and LiveView test helpers. A
passing test never waits a deadline out. The deadline
(`await.deadline_ms`, 5000 ms) is generous enough that the flake gate's
busy loops never trip it.

| Helper | Use it to |
|--------|-----------|
| `barrier(subject)` / `barrier_pid(pid)` | Know an actor has handled every message sent to it before the call (a `sys:get_state` round trip, as LiveView's `render/1` does). Whatever it sent you is then already in your mailbox. |
| `expect(subject, what, matching)` | `assert_receive`: block until a message matches; crash naming `what` and everything that arrived instead. |
| `receive_matching(subject, within:, matching:)` | The same, returning `Error(skipped)` instead of crashing. |
| `drain(subject)` / `settle(actor, subject)` | Everything already in the mailbox, after a barrier (`settle` is barrier + drain). Use it to assert that nothing *else* was sent. |
| `await_down(pid, within:)` / `expect_down(pid, what)` | Wait on a monitor for a process to exit. Never poll `is_alive`. |
| `watch_info(pid, atom)` + `expect_info` | Wait for an OTP process to receive and handle a timer tick (through the sys debug hook) instead of sleeping past its interval. |
| `watch_exit(sup, child)` + `expect_info` | Wait for a supervisor to handle a child's exit, i.e. to have restarted it. |
| `watch_pg_scope` + `expect_pg_leave` | Wait for pg to drop an exited member before reading group membership. |
| `until_telemetry(events, what, condition)` | Re-check state that another process updates and then announces with a telemetry event (e.g. an HTTP slot released before `[brazier, http, connection, closed]`). |

A bounded wait for *nothing* to arrive is still a time window. Use one
only after a barrier proves that the work which could produce the
message is done.

### Instead of a sleep

When the thing under test depends on time, or on a process being slow,
make that state happen rather than waiting for it:

| Situation | Do this | Example |
|-----------|---------|---------|
| Code compares against the clock (windows, TTLs, staleness) | Take the time as an `@internal` argument and pass a later one. | `rate_limit.sweep_with(limiter, now + 2, _)`; `static.file_digest_at(path, now, _)` |
| A call must time out | `sys:suspend` the server, make the call with a short timeout, then `sys:resume` it. | `sweep_of_a_suspended_owner_is_a_timeout_test` |
| Something must happen after a message has arrived | `erlang:trace(Pid, true, ['receive'])` and wait for the trace message. | `sweep_of_an_owner_that_dies_mid_call_is_a_call_failure_test` kills the owner once the call is in its mailbox |
| A client must be slow (slowloris) | Send a byte each time `gen_tcp:recv` times out, until the server answers. | `slow_headers_get_408_test` (`drip_until_answer`) |
| A process must have handled earlier messages | `await.barrier`. | see the table above |

The fixtures for these are in `test/brazier_rate_limit_test_ffi.erl` and
`test/brazier_http_raw_ffi.erl`.

Example: a runtime test, connected through a fake transport subject:

<!-- docs-check: fragment uses the test-only helpers in test/brazier (test_ctx, await), which apps cannot import -->
```gleam
let assert Ok(rt) = runtime.start(config, test_ctx.root())
let transport_subject = process.new_subject()
process.send(rt, runtime.ClientConnected(conn_id: "c1", subject: transport_subject))
process.send(rt, runtime.ClientJoined(conn_id: "c1", token: "", path: "/"))
let assert transport.SendModelSync(model_json:, ..) =
  await.expect(transport_subject, "the join's model sync", fn(m) {
    case m {
      transport.SendModelSync(..) -> True
      _ -> False
    }
  })
assert string.contains(model_json, "\"count\":0")
```

Send events with `runtime.ClientEventReceived` and expect a `SendPatch` or
`SendModelSync` that carries the event's clock. Regression tests must
also assert that a live join and normal post-mount updates send no
`SendMount`.

Client-sent `ops` are untrusted. Runtime tests send malicious ops and
assert that the server-computed update wins.

## Capturing logs: `brazier/log_capture`

`log_capture.capture(fun)` runs `fun` and returns its result together with
every log event the calling process emitted while it ran, as
`Captured(level:, message:)`, in order. While it runs, it raises the
primary logger level so that debug events are captured. `log_capture.has`
checks for a level plus message fragments.

<!-- docs-check: fragment uses the test-only helpers in test/brazier (log_capture), which apps cannot import -->
```gleam
let #(Nil, logs) = log_capture.capture(fn() { log.warning("my_mod", "slow") })
assert logs == [Captured(level: "warning", message: "[my_mod] slow")]
```

The test runner (`test/brazier_test.gleam`) sets the logger to `critical`
to keep output quiet. Do not call `log.configure()` in a test: it resets
that level for every test that runs after it.

## Transport tests

Round-trip the wire protocol, including malformed and hostile input:

<!-- docs-check: wrap
import brazier/transport

{{block}}
-->
```gleam
pub fn decode_heartbeat_test() {
  let assert Ok(transport.ClientHeartbeat) =
    transport.decode_client_message("{\"type\":\"heartbeat\"}")
}
```

The security transport tests cover:

- origin validation;
- rate limiting;
- WebSocket message and buffer caps;
- RFC 6455 frame validation;
- HTTP pre-upgrade limits.

## Simulation tests (`brazier/sim`)

These tests drive real WebSocket connections against an app started on an
OS-assigned port:

<!-- docs-check: fragment uses the test-only helpers in test/brazier (sim/test_app, sim/pool, sim/metrics, sim/teardown), which apps cannot import -->
```gleam
let assert Ok(app) = test_app.start_counter_app()
let mt = metrics.new()
let watch = teardown.watch(app)
let result = pool.run(pool.PoolConfig(
  concurrency: 100, host: "localhost", port: app.port,
  scenario: scenario.counter(20), stagger_ms: 5, metrics: mt,
))
teardown.await_closed(watch, result.upgraded)
let assert [] = result.failures
```

`teardown.await_closed` waits until the server has closed every connection
the pool opened and every process those connections reported has exited.
Leak snapshots taken after it measure cleanup that has finished, not
cleanup that a sleep hoped had finished. See `run_measured` in
`test/brazier/sim_test.gleam`.

Every simulation test ends with `assert_all_clean`: no failed connection
and exactly 0 processes kept. The 1000-connection test also requires all
5000 events to be acknowledged. `sim_memory_leak_test` runs two rounds of
100 connect/disconnect cycles and asserts that the second keeps no ETS
table, no ETS object and no atom. It logs memory in bytes but does not
assert it: a heap's size depends on its GC history and an ETS table's on
its peak load, so no bound on bytes is both stable and tight.

Scenarios:

- `counter(n)`
- `connect_disconnect()`
- `malformed()`
- `flood(n)`
- `draw(n)`
- `reconnect(n)`
- `patch_efficiency(n)`
- `server_push(ms)`
- `corrupt()`

## Stress tests (`brazier/stress`)

`stress.run` opens N joined connections. On each it sends M events and
waits for the patch acknowledging each one. It holds all connections open
at the same moment, then runs the close handshake on every one. The
result reports:

- attempted, succeeded and failed connections, with a reason for each
  failure;
- `held`: connections open at once;
- events acknowledged;
- process count and memory, before the run and while everything was held.

`test/brazier/stress_test.gleam` asserts on these values and on process
identity, not on node-wide count deltas.

Against a running server:

```sh
gleam run -m counter        # in examples/counter
gleam run -m brazier/stress  # in the repository root; exits non-zero on any failure
```

## Flake gate

```sh
make test-flake                       # 5 runs, 8 busy loops
FLAKE_RUNS=10 FLAKE_BUSY=12 make test-flake
```

`scripts/flake_gate.sh` runs `gleam test` repeatedly while `yes >
/dev/null` loops compete for every core, and fails if any run fails.

- Each run's output is kept in `build/flake_gate/run_N.log`.
- Failures print the assertion site, test name and value.
- The busy loops are killed on exit, including on failure or Ctrl-C.

A test that passes only on an idle machine is waiting on timing, not on an
event. Fix the wait, not the deadline.

If a failure shows `eaddrinuse`, first check for a concurrent run
(`pgrep -f "gleam test"`, `pgrep -f test_all_cdp.py`) before treating it
as a flake.

A listener restarted under load used to hit `eaddrinuse`, because the
acceptors owned the listen socket and the runtime closed it some time after
they exited. The socket now has an owner process of its own
(`brazier_http_listen_socket`) that closes it before it exits, so a restart
on the same port never races the old socket; an `eaddrinuse` in a test run
is another process on the port.

## Example and CDP tests (browser)

End-to-end tests run every example in Chrome through the Chrome DevTools
Protocol (`test_all_cdp.py`):

```sh
make browser-canonical  # contract examples, desktop + mobile
make browser-all        # every example, desktop + mobile
PYTHON_BIN=.venv/bin/python BRAZIER_CDP_VIEWPORTS=desktop sh scripts/run_all_cdp.sh
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py auth_workspace --viewport desktop
```

Narrower loops: `make browser-canonical-desktop`,
`make browser-canonical-mobile`, `make browser-all-desktop`,
`make browser-all-mobile`.

### What a run does

For each example:

1. **Build.** It runs `gleam run -m brazier/build` in the example, so the
   client bundle and `build/brazier_contract.json` exist and match the
   source. A build failure or timeout (`BRAZIER_CDP_BUILD_TIMEOUT`, 300 s)
   fails the example and prints the build output.
2. **Start.** It starts the server and waits for its started line. If the
   line does not come within `BRAZIER_CDP_SERVER_TIMEOUT` (90 s), or the
   server dies, the example fails and the last 40 lines of server output
   are printed.
3. **Check.** It opens the page, acts on it, and asserts the concrete
   values it acts on: totals, counts, cells, text. It also checks:
   - the generated contract, and that normal updates cause no post-SSR
     HTML mount;
   - WebSocket frame types;
   - DOM mutation buckets and layout shift;
   - reconnect behaviour;
   - mobile horizontal overflow;
   - console and runtime errors from document start.
4. **Stop.** It stops the server, scoped to the process group so
   parallel shards do not kill each other's `gleam run`, and waits for
   the port to be released.

The script exits 1 if any check failed (an example that does not start
counts as a failure) and 0 otherwise. A broken harness stops the run with
a `CdpError` instead of failing checks one by one: a `*.enable` command
that gets no answer or an error (the suite would then record no console
errors or frames, and checks reading them would pass on nothing), or a
`Runtime.evaluate` whose script throws or returns no JSON value. The one
error a wait retries is the page's JavaScript context being replaced by a
navigation (`CdpContextGone`).

### Waiting

The harness uses Playwright's auto-wait model. After an action, a check
re-evaluates its condition, reading CDP events in between, until it holds
or `BRAZIER_CDP_WAIT_SECONDS` (default 10) passes. A passing check returns
immediately.

A check that the browser sent *no* model event waits on the client, not on
a quiet period: after the local update is visible, `wait_outbound_drained`
waits until `window.__brazierOutboundPendingForTest()` (behind
`__BRAZIER_ENABLE_TEST_HOOKS`) reports an empty paced queue and no scheduled
send, then takes a CDP barrier so every frame written before it is
recorded. The hook does not yet count a debounced send whose timer has not
fired (see [TODO.md](TODO.md)).

One deliberate window remains: Pong's "frozen while paused" check holds
still for many ticks, because the stillness is the thing under test.

### Concurrency

Before starting a run, check that no other run is using the ports
(`pgrep -f test_all_cdp.py`; the CDP port is 9223 and the app port 8080).

The full matrix shards deterministically. Use one container per shard so
each shard has its own ports:

```sh
BRAZIER_CDP_VIEWPORTS=desktop BRAZIER_CDP_SHARD=1/4 make browser-all-shard
make browser-all-docker-shards
BRAZIER_CDP_TOTAL_SHARDS=23 BRAZIER_CDP_VIEWPORTS=desktop BRAZIER_CDP_PARALLEL=5 make browser-all-docker-shards
```

Docker runner knobs:

- `BRAZIER_CDP_SHARDS="1,6,11"` runs a selected shard list from the
  configured total (for multi-VM runners).
- `BRAZIER_CDP_PREBUILD_EXAMPLES=1` bakes `gleam build` output for the root
  package and every example into the image, which avoids per-shard first
  compiles.
- `BRAZIER_CDP_SKIP_DOCKER_BUILD=1` reuses an existing image and fails if
  it is missing. Use it only with warmed images, such as forked Boxd
  workers.
- `BRAZIER_CDP_KILL_PORT=1` kills whatever holds the app port. Use it only
  when you are deliberately cleaning up a stuck local port.

On the 10-CPU, 16 GB development host, `BRAZIER_CDP_PARALLEL=5` is the
measured stable setting. Higher local parallelism ran faster but was
unreliable:

- 10-way finished in 5:32, with shard failures;
- 7-way finished in 7:29, with server startup timeouts.

For Boxd-style VM fan-out:

1. Build a warmed image once:

   ```sh
   BRAZIER_CDP_DOCKER_IMAGE=brazier-cdp:boxd BRAZIER_CDP_PREBUILD_EXAMPLES=1 \
     BRAZIER_CDP_TOTAL_SHARDS=23 BRAZIER_CDP_SHARDS=1 BRAZIER_CDP_PARALLEL=1 \
     sh scripts/run_cdp_shards_docker.sh
   ```

2. Fork the VM and run non-overlapping shard lists on each fork:

   ```sh
   BRAZIER_CDP_DOCKER_IMAGE=brazier-cdp:boxd BRAZIER_CDP_SKIP_DOCKER_BUILD=1 \
     BRAZIER_CDP_TOTAL_SHARDS=23 BRAZIER_CDP_SHARDS="1,6,11,16,21" \
     BRAZIER_CDP_PARALLEL=2 sh scripts/run_cdp_shards_docker.sh
   ```

## Benchmarks

Benchmarks are not tests and never run in `gleam test`. Use `make bench`,
`make bench-check` and `make bench-baseline`. See
[PERFORMANCE.md](PERFORMANCE.md) for the scenarios, the committed
baseline and how tolerances are chosen.

## CI

`.github/workflows/ci.yml` builds `Dockerfile.ci` and runs two jobs:

- **Gleam build, test, lint.** These steps run in order and stop at the
  first failure:
  1. `gleam format --check src test`
  2. `node --version`
  3. `make test-client`
  4. `gleam build --warnings-as-errors`
  5. `gleam test`
  6. `gleam run -m brazier/lint`
  7. `scripts/check_docs.sh`
- **Browser all.** 23 shards at each viewport (desktop and mobile), each
  running `make browser-all-shard` with `BRAZIER_CDP_VIEWPORTS` set to the
  viewport.

## Deliberate waits

These are the waits that remain, and why.

| Where | Wait | Why it stays |
|-------|------|--------------|
| `ws_protocol_test` idle timeout | 4 × `process.sleep(550)` | Wall-clock time must pass the idle timeout while only heartbeats arrive. |
| `brazier/stress` | `hold_duration_ms` | Holding connections open is the load being measured (0 in tests). |
| `brazier/sim` pool | `stagger_ms` | Connection pacing is part of the scenario. |
| CDP pong pause | see [Waiting](#waiting) | The stillness is under test. |
| Peer-node tests (`cluster/*`, `ws8c_presence_*`, `ws10b_presence_restart_semantics`) | `peer.eventually`: re-checks every 10 ms until a deadline | A poll, not a barrier, and the one left to replace. It waits for state to converge across nodes (replication, pg, `net_kernel`), or, in `ws10b_presence_restart_semantics`, for a session to track itself again after its shard restarts. No single process announces either to the test. Do not use it in single-node tests: those wait on a monitor, a sys hook (`await.watch_info`, `watch_exit`, `watch_down`) or a message. |
