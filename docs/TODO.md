# Brazier — Issues, Bugs, and Deferred Items

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

- **Issue:** the listener's `eacces` path is tested only where the OS
  refuses a privileged port. macOS lets any user bind port 1 on the
  wildcard address, so `a_privileged_port_matches_what_the_os_says_test`
  checks there that the start succeeds; on Linux as non-root it checks the
  `"cannot listen on port 1: eacces (permission denied)"` error. The
  wording itself is covered on every OS by
  `a_start_error_names_the_posix_cause_test`.
  - **Context:** Milestone 118, m118-server-residue.
  - **Files:** `test/brazier/listener_start_failure_test.gleam`
  - **Attempted:** binding a specific address the user may not use gives
    `eaddrnotavail`, whose text is OS-specific, and the listener has no
    bind-address option to test it through.

- **Issue:** `wire.patch` and `wire.model_sync_50kb` are 13% slower on
  their medians than at 4b274e8 (the 2026-11-04 baseline's commit), with
  under 2% noise between runs. Inside the gate's 25% floor, so
  `bench-check` passes it.
  - **Context:** Milestone 118 re-baseline, an A/B of 4b274e8 and 7bef17a
    run alternately on one machine (docs/PERFORMANCE.md, "Changes since
    the 2026-11-04 baseline").
  - **Files:** `src/brazier/transport.gleam` (`encode_server_message`),
    `test/brazier/bench/suite.gleam` (the wire scenario)
  - **Attempted:** nothing yet. Bisect the commits between the two that
    touch the frame encoding or the bench's wire scenario.

- **Issue:** `presence.list.10.p99` is 1.56x what it was at 4b274e8 (about
  13 µs), with under 5% noise between runs; its median and the 10,000-entry
  metrics did not move.
  - **Context:** the same A/B as the `wire` issue above.
  - **Files:** `src/brazier/presence.gleam`, `src/brazier_presence_ffi.erl`,
    `test/brazier/bench/presence_bench.gleam`
  - **Attempted:** nothing yet.

- **Issue:** `presence.list` grows faster than the room past about 10,000
  entries: 0.46 µs an entry at 3,000, 0.61 at 10,000 and 0.92 to 1.13 at
  30,000. Every `brazier.presence` session that starts following a topic
  pays one list, so a join into a 30,000-entry room costs about 30 ms of
  the watcher's time.
  - **Context:** Milestone 118, m118-perf-server, `presence.list.10000`
    at about 5.9 ms (docs/PERFORMANCE.md, "`presence.list.10000`").
  - **Files:** `src/brazier/presence.gleam`,
    `src/brazier_presence_ffi.erl`, `src/brazier_presence_shard.erl`
  - **Attempted:** a profile shows the ETS copy and the JSON decode flat
    per entry and the growth in collecting the caller's heap. Neither a
    one-pass decode-and-group nor reading in 256-row chunks gained more
    than 4 to 6%, so neither shipped. What is left changes what a list
    returns or what the shards store, for the design to decide. One
    option is metas kept as terms for this node's entries, decoded once
    at track: no decode on read, but the shard row grows and remote
    entries still decode. Another is a list that hands the caller one
    chunk of entries at a time.

## Resolved Issues

<!-- Move resolved issues here with full resolution details -->

- **Issue:** `application.start_supervised` started its root as a
  `static_supervisor` that listed its children at start, so a listener that
  could not bind (a taken or privileged port) failed the root's own start:
  the root exited `{shutdown, {failed_to_start_child, ...}}`, which killed a
  caller of `brazier.start` that did not trap exits, and gleam_otp reported
  the start error as `InitFailed("shutdown")`, the cause only in the log.
  - **Files:** `src/brazier/application.gleam`, `src/brazier_app_sup.erl`
  - **Resolution:** (Milestone 118, m118-residue-3) The root is
    `brazier_app_sup`, an Erlang supervisor that starts with no children and
    adds each one with `supervisor:start_child`, as Ranch adds a listener to
    the running `ranch_sup` and `brazier_http_listener_sup` adds its own
    children. A child that cannot start stops the partly started tree,
    unlinked from the caller first, and its own start error is returned:
    `"Supervision tree failed to start: cannot listen on port N: eaddrinuse
    (address already in use)"`. The restart semantics are those of the
    static_supervisor it replaces: `rest_for_one`, 2 restarts in 5 seconds,
    child N with the id N, and each gleam_otp child spec turned into the
    same OTP child map. `test/brazier/cluster/app_tree_start_failure_test.gleam`
    covers a taken port with a caller that does not trap exits (links,
    leftovers, the logged cause, a start and stop afterwards), one that
    does (no `EXIT` message), and the child specs, which it also checked
    against the old root.

- **Issue:** `server.start` on a taken port killed a caller that did not
  trap exits, and a caller that did got the error `"shutdown"`, the cause
  lost. The listener supervisor listed its children in `init`, so a socket
  owner that could not bind failed the supervisor's own start
  (`{shutdown, {failed_to_start_child, listen_socket, ...}}`), an exit
  signal to the linked caller.
  - **Files:** `src/brazier_http_listener_sup.erl`,
    `src/brazier/transport/server.gleam`
  - **Resolution:** (Milestone 118, m118-server-residue) The listener
    supervisor (`brazier_http_listener_sup`) starts empty and adds its
    three children with `supervisor:start_child`, as Ranch's
    `start_listener` adds a listener to `ranch_sup` and returns
    `{error, eaddrinuse | eacces}`. A failed child is a returned error; the
    partly started tree is stopped and the start returns
    `"cannot listen on port N: eaddrinuse (address already in use)"`.
    `server.supervised` returns it as `InitFailed` and logs it.
    `test/brazier/listener_start_failure_test.gleam` checks the error, the
    caller's links, trap flag and mailbox, the keepers left, and the
    supervised path.

- **Issue:** a supervised listener removed from its parent
  (`supervisor:terminate_child`, then `delete_child`) kept its
  `persistent_term` entries until the parent exited.
  - **Files:** `src/brazier/transport/server.gleam`
  - **Resolution:** (Milestone 118, m118-server-residue) Documented, not
    erased on removal: the parent holds the entries because a terminated
    child can still be restarted (`restart_child`) and must rebind the port
    it bound first, and the supervisor tells nothing when a spec is
    deleted. The parent that removes the listener releases it with
    `server.release`, as Ranch's `stop_listener` cleans up its listener's
    options itself between the terminate and the delete. `server.supervised`
    says so; `listener_name_test` removes a listener, sees the entries kept,
    releases it and sees them go.

- **Issue:** `brazier/internal/url.is_url_attribute` lowercased every
  attribute name with `string.lowercase`. On Erlang, OTP's
  `string:lowercase/1` raises and catches an exception inside for a name
  that is already lowercase, about 0.1 µs a name, and `attribute.attribute`
  paid it once per attribute it builds (`url.check`).
  - **Files:** `src/brazier/internal/url.gleam`,
    `src/brazier/internal/ascii.gleam`
  - **Resolution:** (Milestone 118, m118-server-residue) Every
    `string.lowercase` outside render and build now uses
    `brazier/internal/ascii.lowercase`, which lowercases `A-Z` only, url
    among them. The render keeps `brazier_render_ffi:ascii_lowercase`, its
    owner's to fold into the shared module.

- **Issue:** every bench suite run after the first left 7 more atoms in
  the atom table. Listing the atoms each run creates (by index) showed all
  7 were `brazier_http_conns_<N>`: `brazier_http_conns:new_name/0` named
  each listener's connection owner with a fresh atom, one per listener
  start, and the suite starts 7 listeners. Atoms are never collected, so a
  node that starts and stops listeners (a test suite, a bench, an app that
  restarts its listener) grew its atom table without bound.
  - **Files:** `src/brazier_http_conns.erl`,
    `src/brazier/transport/server.gleam`,
    `src/brazier_http_listen_socket.erl`,
    `src/brazier_http_acceptors_sup.erl`, `src/brazier_server_ffi.erl`
  - **Resolution:** (Milestone 118, m118-perf-server) The owner's name is
    `{via, brazier_http_conns, Ref}` for a fresh reference, and
    `brazier_http_conns` is the via registry: the owner's pid sits in a
    persistent_term keyed by Ref, beside the bound port the listener
    already kept there, and `forget_port/1` (run by `server.stop`) erases
    both. A pid fits in one machine word, so an owner restart (which
    replaces it) or a stop (which erases it) runs no global GC. A dead
    owner reads as none, so a call to a restarting listener exits with
    `noproc` as it did for an unregistered atom. This is Ranch's pattern:
    `ranch_server` registers a listener's connection supervisor under the
    listener's Ref instead of an atom. The suite census now shows no new
    atom after the first run. `test/brazier/listener_name_test.gleam`
    checks that 10 start/stop cycles create no atom and leave no registry
    entry, and covers the registry's refusals (a second live owner, a dead
    owner, a send with no owner, an unregister by another process).

- **Issue:** a listener's `persistent_term` entries (its connection owner,
  its bound port) went only with a release (`server.stop`, the app
  watcher). A listener tree that crashed with nothing to release it left
  both behind, and a start that failed to bind left an owner entry naming
  a dead pid.
  - **Files:** `src/brazier_http_conns.erl`,
    `src/brazier/transport/server.gleam`, `src/brazier/application.gleam`
  - **Resolution:** (Milestone 118, m118-server-residue) Each listener name
    gets a keeper process, made with the name. The keeper monitors the
    listener's holders: the process that made the name until a holder is
    added, the starter of an unsupervised listener (`server.start`), the
    parent that restarts a supervised one (`server.supervised`, held each
    time its child spec starts), and any process that will release it
    (`server.stop`, the app watcher, through `server.hold`). A release
    erases the entries and ends the keeper; when the last holder exits
    without one, the keeper erases them and logs it (info). This is the
    shape of Ranch's cleanup: `ranch_server` monitors a listener's
    supervisor and drops its options on a stop, while `stop_listener`
    cleans explicitly; the holders cover the restarted tree, whose pid
    changes, and keep the bound port for a parent's restart. A start that
    fails erases what it registered and says whether a port was forgotten.
    `test/brazier/listener_name_test.gleam` covers a crash with no release,
    a held listener kept until its release, a holder that exits before
    releasing, every holder exiting, a supervised listener kept across a
    parent restart and erased when the parent stops, and a failed start.

- **Issue:** an `init` refusing with 401 closes with 4401, the code of a
  revoked session or expired authentication, so the two are told apart only
  by the close reason and the server log. The client action is the same (a
  reload behind the guard), so nothing misbehaves; a monitor that counts
  revocations by close code also counts 401 refusals.
  - **Files:** `src/brazier/transport.gleam`, `docs/WIRE_PROTOCOL.md`,
    `docs/TELEMETRY.md`
  - **Resolution:** (Milestone 118, m118-logs) Decision: 4401 stays shared.
    The client does the same thing for all three causes, and a code per
    cause would only move the distinction into a table the client does not
    need. The server tells them apart: the `[brazier, ws, close]` event
    already carried `init_refused`, `session_revoked` or
    `authentication_expired` as its `reason`, but the log lines did not
    (the connection close line said only `auth re-check failed` or
    `session revoked`, the startup close line only the code). Every close
    line now reads `with <code> (reason <label>)`, the label taken from the
    one function that also labels the event (`close_summary`, and
    `startup_close` for a runtime that did not start), so the two cannot
    drift. `close_cause_4401_test` covers each cause over a real listener,
    asserting the close frame, the event's code and label and the one log
    line.

- **Issue:** `brazier_application_ffi:receive_wait_event` takes any
  `{'EXIT', _, normal}` as a shutdown request, so a linked helper that exits
  normally stops the wait.
  - **Files:** `src/brazier_application_ffi.erl`,
    `src/brazier/application.gleam`
  - **Resolution:** (Milestone 118, m118-lifecycle) `wait_forever` traps
    exits, so every linked process's exit reaches its receive, and the
    receive matched `normal` from any sender. A helper that finished (a
    `process.spawn` task) therefore ended the wait as if the application had
    been stopped: `wait_forever` returned while the application was still
    running. `wait_forever` now notes, before it traps exits, the supervisors
    of the remembered applications linked to it, and `receive_wait_event`
    takes that list: a `normal` exit of one of them is the stop; a `normal`
    exit of any other linked process is logged (info) and the wait goes on,
    as it would without trapping exits; any abnormal exit still ends the
    wait loudly. An application stopped before the list is taken sends
    nothing the waiter could receive, trapped or not, as before.
    `app_lifecycle_test` covers a helper that exits normally (logged, the
    waiter keeps waiting, then `stop` ends the wait) and one that crashes.
- **Issue:** the node-wide app record keeps the `persistent_term` entry of a
  tree that crashed until a `stop` or a SIGTERM finds it not running.
  - **Files:** `src/brazier_application_ffi.erl`,
    `src/brazier/application.gleam`
  - **Resolution:** (Milestone 118, m118-lifecycle) The record was written
    by `start` and erased by `stop` only, so nothing noticed a tree that died
    on its own: the record (and the listener's remembered bound port) stayed
    until a `stop` or a SIGTERM drain found the tree not running. Each
    application now has a watcher, spawned unlinked by `start`, which
    monitors the root supervisor before it writes the record (so a tree that
    dies at any point after its start is reported, `noproc` at worst). When
    the monitor fires, stopped or crashed, the watcher erases the record and
    the bound port, logs it (info for a stop, error with the reason for a
    crash) and exits, as OTP's application controller drops an application
    whose master exits. `stop` returns once the watcher has forgotten the
    tree, and fails if it exited without doing so. `app_lifecycle_test`
    covers a killed tree (forgotten at once, the error logged, a later
    `stop` one warning), a stop, and a SIGTERM after a crash (nothing to
    drain, no warning).

- **Issue:** a title over `runtime.title_max_bytes` is reported with an
  `error` frame and a log line after every update while it stays too large.
  - **Files:** `src/brazier/runtime.gleam`
  - **Resolution:** (Milestone 118, m118-lifecycle) The runtime reported
    from the size check alone, with no memory of having reported, so every
    update re-sent the error. The runtime state now holds a `TitleSync`
    (`TitleWithinLimit` / `TitleOverLimit`, each with the last title sent).
    Going over the limit is logged as an error and reported to every
    connection once; while it stays over, an update logs at debug and sends
    nothing, and a connection that joins meanwhile is told once. Going back
    within the limit is logged (info), sends the title if it differs from
    the one last sent, and re-arms the report. `runtime_title_limit_test`
    covers staying over, going over again after being within, and a join
    while over, counting the log lines.
- **Issue:** `ws8c_runtime_stop_test`
  (`failing_linked_process_reports_stop_with_exit_test`) failed once: the
  stop event carried the owner's reason, but the runtime's DOWN reason was
  an atom.
  - **Files:** `test/brazier/ws8c_runtime_stop_test.gleam`
  - **Resolution:** (Milestone 118, m118-lifecycle) The test, not the
    runtime. On OTP 28 `erlang:monitor` on a normal scheduler parks the
    monitor signal in the scheduler's pending slot (`erl_proc_sig_queue.c`,
    `erts_proc_sig_send_monitor`); it is enqueued only when the sender is
    scheduled out, signals the same target again, or creates another
    monitor. The helper's exit reached the runtime from another process,
    so the runtime could leave first, and a monitor that reaches an exited
    process reports `noproc`: the atom. Measured with the real runtime and
    a forced spin while the monitor is parked: 1079 and 598 of 2000 runs
    gave `noproc`; with a message to the runtime after the monitor, and
    with `await.barrier_pid`, 0 of 2000 each. The flake was recorded
    (fa127d4) before the barrier was added after the monitor (3bc6444),
    which fixes it: the synchronous request goes to the same target, so it
    enqueues the monitor first. The module doc now names the mechanism,
    `monitor_reaching_an_exited_runtime_reports_noproc_test` replays the
    symptom in a fixed order, and the diagnostic is removed. The parked
    slot cannot be held from Erlang code (any schedule-out flushes it), so
    no test can force the race; what stretched the window in that one run
    (likely the OS descheduling a scheduler thread on a loaded clean build)
    is not known.

- **Issue:** `transport/http.read_body` returned `Result(BitArray, String)`,
  and `transport/server.read_body` did too, so a caller could only match on
  text: `upload` could not tell a too-large body (413) from a failed read
  (400) without comparing strings, and a new failure reached every caller
  unnoticed.
  - **Files:** `src/brazier/transport/http.gleam`,
    `src/brazier/transport/server.gleam`, `src/brazier_transport_ffi.erl`,
    `src/brazier/api.gleam`, `src/brazier/upload.gleam`
  - **Resolution:** (Milestone 118) `transport_http.read_body` returns a
    `ReadBodyError` (`MissingContentLength`, `InvalidContentLength`,
    `BodyTooLarge(length, limit)`, `BodyAlreadyConsumed`,
    `BodyReadFailed(server.BodyReadError)`), and `server.read_body` a
    `BodyReadError` (`NoActiveRequest`, `BodyUnavailable`,
    `ReadPastBody(requested, remaining)`, `BodyReadTimeout`,
    `RequestDeadlineExceeded`, `SocketFailed(reason)`), each with a
    `describe_*` function. Every caller lists every variant, so a new one
    is a compile error at each of them: `api.read_text` replies with the
    description, `upload.read_multipart` maps `BodyTooLarge` to
    `RequestTooLarge` (413) and the rest to `BodyReadError`, and
    `finish_body` logs the description. A body read that a request
    deadline cut short used to be reported as a read timeout; it is now
    `RequestDeadlineExceeded`. `test/brazier/read_body_error_test.gleam`
    drives each variant through a listener over a raw socket (or, for the
    two a listener never lets through, a request built outside one).
    While there, `upload`'s early Content-Length check logged the raw
    request path; it now quotes it (`log_forging_paths_test`).

- **Issue:** a join without a build id was logged as a warning on every
  join, so a client on the unversioned `/brazier_client.js` filled the log.
  - **Files:** `src/brazier/transport.gleam`
  - **Resolution:** (Milestone 118) `ConnectionState` remembers that the
    connection already warned: the first join without a build id logs a
    warning, later joins on that connection log at debug. A new connection
    warns again. `test/brazier/join_build_test.gleam` captures the log of
    two joins on one connection and asserts one warning.
    The ws bench (`test/brazier/bench/suite.gleam`) logged that warning on
    every connection, and its joins were not the ones a real client sends.
    It now joins with the hash of the bundle the listener loaded
    (`ssr.client_bundle`), as a page rendered by that server does, so the
    server checks the build on each join and logs nothing. The bench fails
    by name if no bundle is loaded. `brazier/stress` joins the same way
    (`StressConfig.build`): `stress.page_build` takes the bundle a listener
    in its own VM loaded and fails by name if none is, and the CLI, which
    drives a server in another VM, reads the bundle from the `<script>` of
    the page that server serves at `/` (`stress.served_build`), as a
    browser does. `test/brazier/stress_test.gleam` asserts that a run logs
    no join without a build and that a join from another build is closed
    with 4499.

- **Issue:** the client manifest had two readers (`ssr` for the page and
  `transport.check_join_build` for the join), and the join read it from
  disk on every join, a cost the benches did not measure; the two could
  also disagree mid-rebuild.
  - **Files:** `src/brazier/ssr.gleam`, `src/brazier/transport.gleam`,
    `src/brazier.gleam`, `src/brazier/dev.gleam`,
    `src/brazier_bundle_manifest_ffi.erl`
  - **Resolution:** (Milestone 118) `ssr.load_client_bundle` reads the
    manifest and stores the outcome in one `persistent_term` slot;
    `ssr.client_bundle` is the one reader, used by the page render and the
    join check. The server loads it when it starts (`brazier.start` and
    `transport.start_listener`), and a failed load fails the start;
    `brazier/dev` loads it again after each successful rebuild. No other
    code reads the manifest. `test/brazier/join_build_test.gleam` traces
    file operations during a join and asserts there are none, and
    `test/brazier/dev_build_test.gleam` covers a listener that cannot load
    the bundle, a join after a failed load (1011), and a bundle read once
    and again only on a load.

- **Issue:** an `init` refusing with 409 closed with 4409, the same code as
  a stale build, so the two could not be told apart from the close code.
  - **Files:** `src/brazier/error.gleam`, `src/brazier/transport/ws.gleam`,
    `brazier_client/src/brazier_client/patch.mjs`
  - **Resolution:** (Milestone 118) stale build closes with 4499
    (`ws.close_stale_build`, the client's `CLOSE_STALE_BUILD`), still in
    the 4400-4499 reload band, so an older page reloads on it too. `init`
    keeps 4000 + status, and `error.refuse(499, _)` is a programming error
    that crashes `init` (`error.reserved_status`), so no refusal can share
    the stale-build code. 499 is not an HTTP status. The client harness
    and `sync_vectors.mjs` pin 4499, and `build_handshake_test` asserts it
    on the wire.

- **Issue:** a page that was reconnecting while dev mode rebuilt missed the
  `reload` broadcast (it is not subscribed between sockets), and ran on
  with the old server's page; it reloaded only when its client bundle also
  changed, through the stale-build close and its guard.
  - **Files:** `src/brazier/transport.gleam`, `src/brazier/ssr.gleam`,
    `src/brazier/dev.gleam`, `brazier_client/src/brazier_client_ffi.mjs`
  - **Resolution:** (Milestone 118) each dev rebuild sets a new dev build
    (`ssr.new_dev_build`), rendered as `data-brazier-dev-build` on
    `#brazier-app`. The client sends it in the join as `dev_build`, and the
    server answers a join whose dev build is not the current one with
    `reload` and does not dispatch it. Outside dev mode nothing is checked.
    `test/brazier/dev_build_test.gleam` covers a matching, a stale and a
    missing dev build, and a page between sockets during a rebuild that
    reloads on its join; the client harness asserts the join carries it
    on reconnect and that a `reload` answer reloads outside the guard.

- **Issue:** `window.__brazierOutboundPendingForTest()` did not count a
  debounced send whose timer had not fired, so a CDP check could see the
  outbound queue as drained while a send was still to come.
  - **Files:** `brazier_client/src/brazier_client_ffi.mjs`,
    `test_all_cdp.py`
  - **Resolution:** (Milestone 118) the hook returns
    `{queued, scheduled, debounced}`, `debounced` counting the debounce
    timers still pending, and `test_all_cdp.py`'s drained state requires
    `debounced: 0`. A harness scenario counts one debounced send before its
    timer fires and none after.

- **Issue:** several simulation tests allow leaked processes or failed
  connections (`sim_test.gleam:177`, `:247`, `:320`, `:377-379`), against
  TIGERSTYLE's zero-leak rule.
  - **Files:** `test/brazier/sim_test.gleam`
  - **Resolution:** (Milestone 117 audit, TS-6) Every simulation test ends
    with `assert_all_clean`: no failed connection, every worker succeeded,
    and exactly 0 processes kept after teardown. `sim_memory_leak_test`,
    which measured memory but asserted nothing about it, now runs two
    rounds of 100 connect/disconnect cycles and asserts that the second
    keeps no ETS table, no ETS object and no atom
    (`test/brazier_sim_memory_ffi.erl`). Bytes are logged, not asserted:
    heap and ETS sizes depend on GC history and peak load, so no bound on
    them is both stable and tight.

- **Issue:** `brazier.title` was computed only for the HTML render
  (`ssr.gleam:308`); a client navigation or a live update left
  `document.title` unchanged.
  - **Files:** `src/brazier/runtime.gleam`, `src/brazier/transport.gleam`,
    `src/brazier/application.gleam`, `brazier_client/`
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
  - **Files:** `src/brazier/store.gleam`, `src/brazier/store/replicated.gleam`
  - **Resolution:** (WS10b) `store.StoreError` is a store type
    (`InvalidName`, `TableTypeMismatch`, `TableOwnerUnavailable`) with
    `store.describe_error`, converted from the internal error in one place.
    `replicated.InvalidName` carries `name` and `reason`. `store_test`
    matches each constructor through `brazier/store`.
- **Issue:** `brazier/rate_limit` was an internal module (`gleam.toml`
  `internal_modules`), but `middleware.rate_limit` needs a
  `rate_limit.RateLimiter` from `rate_limit.new`.
  - **Files:** `gleam.toml`, `src/brazier/rate_limit.gleam`
  - **Resolution:** (WS10b) `brazier/rate_limit` is public. The test-only
    `owner` is `@internal`, and `config` and `max_keys` read a limiter's
    settings. `internal_modules_test` checks the module stays public.

- **Issue:** a join token whose model does not decode was logged and the
  session continued with the state `init` returned (`runtime.gleam:920-929`),
  a silent degradation for the user.
  - **Files:** `src/brazier/runtime.gleam`
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
  sent to the subscribers of `brazier:reload`, and nothing subscribed.
  - **Resolution:** (Milestone 117, WS10b-T) as in Phoenix.LiveReloader,
    `dev.start` turns live reload on before it starts the app, every
    WebSocket handler then subscribes to `brazier:dev:reload`, and each
    rebuild sends every open page a `reload`. A handler that cannot
    subscribe closes 1011.
- **Issue:** the dev watcher fell back to polling every 500 ms when neither
  `fswatch` nor `inotifywait` was installed, against the no-fallbacks rule.
  - **Resolution:** (Milestone 117, WS10b-T) a native watcher is required;
    dev mode checks for it before building and exits with status 1 naming the program to install.
