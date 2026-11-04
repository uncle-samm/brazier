---
name: stability
description: Audit Brazier stability and reliability — concurrency, lifecycle, resource bounds, flakes, reconnects, ordering, backpressure, recovery, and production failure modes.
user_invocable: true
---

# Stability Audit

Run a stability audit on Brazier as a long-running BEAM web framework. Focus on
whether real apps keep behaving predictably under concurrency, disconnects,
slow clients, large state, repeated navigation, failed builds, and resource
pressure.

## Usage

- `/stability` — audit full framework reliability
- `/stability runtime` — focus on MVU process lifecycle and message ordering
- `/stability transport` — focus on HTTP/WebSocket lifecycle, buffers, limits,
  reconnects, and backpressure
- `/stability routing` — focus on route transitions, guards, route SSR, and
  route-local state
- `/stability client` — focus on hydration, DOM updates, patch application, and
  browser-side failure behavior
- `/stability examples` — focus on example apps as reliability coverage
- `/stability ci` — focus on flaky tests, browser shards, Docker/Boxd runners,
  and environment sensitivity

## Philosophy

Brazier should be boring under stress:

- First paint is SSR, then client rendering from state sync/patch messages.
- No normal runtime HTML morph fallback.
- Unsupported app shapes fail before serving traffic.
- Local-only changes stay local and instant.
- Server-authoritative changes are deterministic and ordered.
- Slow, malicious, or disconnected clients cannot destabilize other sessions.
- Resource limits reject work loudly with logs and useful errors.

Stability audits must distinguish:

- **Framework stability risk** — Brazier could fail for users in production.
- **Test/harness flake** — the framework may be fine, but the check is timing
  sensitive or environment dependent.
- **Example bug** — example code teaches or exercises an unreliable pattern.

## What to Check

### 1. Process Lifecycle

Check `src/brazier/runtime.gleam`, `src/brazier/transport.gleam`,
`src/brazier/application.gleam`, supervisors, and tests.

- Are runtime processes spawned, linked, monitored, and stopped deliberately?
- Are disconnects, reconnects, and duplicate joins handled deterministically?
- Can a runtime leak after the last connection closes?
- Are session/runtime IDs unique enough and logged without leaking secrets?
- Are crashes isolated to one session unless a supervisor policy says otherwise?
- Are startup failures propagated instead of logging and continuing?

Flag:
```
[HIGH][FRAMEWORK] src/brazier/runtime.gleam:421 — runtime can survive after last connection
  Risk: Long-lived apps leak BEAM processes under reconnect churn.
  Fix: Add deterministic shutdown on zero connections and test repeated connect/disconnect.
```

### 2. Ordering And Determinism

- Are client events processed in a stable order?
- Are stale or replayed event clocks rejected?
- Can batched events interleave with route changes or reconnect joins wrongly?
- Does server-computed model state always win over client-sent hints?
- Are model patches generated from the actual previous committed model?
- Are route transitions idempotent across SSR, live mount, and client navigate?

### 3. Backpressure And Resource Bounds

Check all network, runtime, PubSub, store, and build boundaries.

- Are WebSocket buffers capped before complete-frame decode?
- Are HTTP headers, body reads, request-line parsing, and pre-upgrade sockets
  bounded by byte count, count, and deadlines?
- Are outgoing send queues or slow clients bounded?
- Can one session grow model JSON, patches, subscriptions, timers, effects, or
  pending messages without limit?
- Are PubSub fanout and store updates bounded or observable?
- Do large models use patch/sync thresholds predictably?

### 4. Recovery And Reconnects

- Does SSR token/cookie recovery handle expired, missing, tampered, and stale
  state loudly and safely?
- Does reconnect preserve user-visible state without duplicate effects?
- Does reconnect after deploy or bundle hash change produce a clear reload path?
- Are WebSocket close reasons and auth failures logged with context?
- Are browser reloads/navigations free of flicker and duplicate DOM churn?

### 5. Client Runtime Stability

Check `brazier_client/src`, generated bundles, and CDP tests.

- Does hydration run once and take ownership without replacing stable DOM
  repeatedly?
- Are DOM mutations minimal and expected for Local-only and Model updates?
- Do JSON patch failures fail closed with visible/logged errors?
- Are event handlers re-bound predictably after patches/navigation?
- Are browser console errors treated as test failures?
- Are mutation observers or CDP traces checking for flicker/spam where relevant?

### 6. Route And App Shape Stability

- Do normal and routed apps use the same rendering/update path?
- Are multi-file and `app_with_server` apps accepted only when generated client
  code/codecs are complete?
- Are unsupported route guards/loaders/actions rejected or not documented?
- Does `Server` state stay private across SSR, generated client bundles, logs,
  and JSON sync?
- Are route-local child models updated without dropping sibling state?

### 7. Effects, Timers, Stores, And PubSub

- Are effects run exactly once per committed server update?
- Can timers be duplicated on reconnect, navigation, or re-render?
- Are effect failures logged and represented in app state where appropriate?
- Are store and PubSub operations kept out of client-visible `update`?
- Are dynamic subscriptions updated atomically with model changes?
- Can a PubSub notification storm starve normal client events?

### 8. CI, Browser, And Simulation Flakes

Classify flakes as harness, environment, or framework risks.

- Are sleeps used where event-based waits would be stronger?
- Are ports, ETS tables, static files, build dirs, and examples isolated per
  test/shard?
- Do Docker/Boxd shards rebuild or share state unexpectedly?
- Are CDP tests deterministic across desktop/mobile viewports?
- Do slow CPUs expose real startup timeouts or harness assumptions?
- Are failed browser logs, network traces, and DOM mutation traces captured?

### 9. Observability

- Are stability-relevant state transitions logged at useful levels?
- Do logs include module, phase, route/session/connection context, and reason?
- Are logs free of secrets, tokens, full cookies, and private server state?
- Can a production user tell whether an issue was auth rejection, build failure,
  transport limit, patch failure, route mismatch, or app exception?

## Search Hints

Use `rg` first. Useful patterns:

```sh
rg -n "sleep|timeout|timer|heartbeat|reconnect|disconnect|join|buffer|queue|limit|max_|spawn|monitor|link|send|receive|Error\\(_\\)|panic|todo|fallback|retry" src test brazier_client examples --glob '!**/build/**'
rg -n "MutationObserver|console|network|websocket|wait|sleep|timeout|shard|docker|boxd" test_all_cdp.py scripts .github
```

## Output Format

Lead with risks that can cause production instability or false confidence.

Use this format:

```text
[SEVERITY][SCOPE] file:line — Short title
  Risk: What can break for users or operators.
  Evidence: Specific code/test behavior observed.
  Fix: Concrete change or test to add.
```

Severity:

- `CRITICAL` — data/session corruption, cross-session impact, unbounded crash
  loop, or production traffic cannot be trusted.
- `HIGH` — likely process/resource leak, ordering bug, flake masking real
  regressions, or route/render inconsistency.
- `MEDIUM` — reliability gap with plausible edge-case impact.
- `LOW` — hardening or observability improvement.

Scope:

- `FRAMEWORK` — Brazier code can fail for users.
- `CLIENT` — browser runtime, hydration, DOM, or patch stability.
- `EXAMPLE` — example app teaches or exercises an unstable pattern.
- `TEST` — tests give flaky or incomplete stability signal.
- `CI` — runner/container/Boxd/GitHub Actions reliability.
- `DOCS` — docs promise stability behavior not enforced by code/tests.

End with:

```text
Stability Audit Results:
  Files scanned: N
  Findings: N total
    Critical: N
    High: N
    Medium: N
    Low: N
  Classification:
    Framework risks: N
    Test/harness flakes: N
    Example issues: N
  Top priority: ...
  Confidence: LOW / MEDIUM / HIGH
```
