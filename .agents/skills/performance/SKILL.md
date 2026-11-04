---
name: performance
description: Audit Brazier performance — first page load, SSR, hydration, final render, WebSocket throughput, high-frequency apps, multi-user load, CPU, RAM, allocations, and benchmark quality.
user_invocable: true
---

# Performance Audit

Run a performance audit on Brazier as a full-stack Gleam framework. Focus on
user-visible latency, throughput, CPU/RAM efficiency, allocation pressure, and
whether current tests can prove performance under realistic load.

## Usage

- `/performance` — audit full framework performance
- `/performance first-load` — focus on SSR, bundle size, first byte, first
  paint, hydration, and final rendered state
- `/performance websocket` — focus on high-frequency WebSocket events and
  state sync/patch throughput
- `/performance game` — focus on game-like workloads with rapid input, low
  latency, and many active sessions
- `/performance multi-user` — focus on many concurrent users/sessions
- `/performance client` — focus on browser CPU, DOM mutations, patch apply,
  local state, and hydration cost
- `/performance server` — focus on BEAM processes, serialization, diffing,
  memory, PubSub/store fanout, and schedulers
- `/performance benchmarks` — focus on benchmark design, instrumentation,
  thresholds, and regression tracking

## Philosophy

Brazier should be fast by construction:

- SSR must make first paint useful without waiting for WebSocket hydration.
- Hydration should take over once and avoid visible flicker.
- Local-only UI changes should be instant and zero server traffic.
- Model changes should send compact state sync/patch payloads, not HTML morphs.
- High-frequency apps should avoid per-event full re-render, full JSON encode,
  full DOM replace, or unbounded mailbox growth.
- Many users should scale mostly with active work, not idle connection count.
- Benchmarks must report latency distributions and resource use, not only
  pass/fail.

Always separate:

- **Latency** — first byte, first paint, input-to-DOM, event round trip, p95/p99.
- **Throughput** — events/sec, patches/sec, sessions/core, broadcasts/sec.
- **Efficiency** — CPU %, reductions, RAM/session, allocations/event, bytes/event.
- **Benchmark quality** — whether the measurement is realistic and repeatable.

## What to Check

### 1. First Page Load

Check SSR, static assets, generated bundles, and startup path.

- Time to first byte for SSR routes.
- SSR render time for small, medium, and large model/view trees.
- Initial HTML size and critical CSS/JS placement.
- Client bundle size, cacheability, hash manifest behavior, and compression.
- Time from navigation start to useful first paint.
- Time from first paint to hydration complete.
- Whether final rendered state matches SSR without flicker or duplicate work.

Flag:
```text
[HIGH][FIRST-LOAD] src/brazier/ssr.gleam:180 — full model serialized twice before first paint
  Impact: Large models pay avoidable CPU and latency on every initial request.
  Measure: Add SSR benchmark with 1KB, 100KB, and 1MB model JSON.
  Fix: Reuse encoded model or generate only the HttpOnly recovery payload needed.
```

### 2. Hydration And Final Render

Check `brazier_client/src`, generated client app code, and CDP traces.

- Hydration must run once and attach event handlers without replacing stable DOM.
- First `ServerModelSync` should not cause visible flicker when it matches SSR.
- Local state init should be cheap and derived from initial model only once.
- DOM mutation count should be proportional to changed UI, not whole document.
- Final render after hydration should be stable under slow network/CPU.

Recommended browser measurements:

- Performance marks: navigation, SSR HTML parsed, bundle loaded, hydration
  start/end, first WebSocket join, first model sync, final render stable.
- MutationObserver counts between SSR paint and hydration stable.
- Long task count/duration during hydration and rapid updates.
- Console errors and failed network requests treated as performance test
  failures, not noise.

### 3. High-Frequency WebSocket Workloads

Simulate apps like games, drawing tools, collaborative cursors, and realtime
dashboards.

- Many small client events per second from one session.
- Many sessions sending events at once.
- Server broadcasts or PubSub fanout to many subscribers.
- Back-to-back `ClientEventBatch` messages.
- Large or frequent `ServerPatch` / `ServerModelSync` responses.
- Slow clients that cannot read as fast as the server writes.

Measure:

- Event input rate and accepted/rejected rate.
- End-to-end event-to-DOM latency p50/p95/p99.
- Server event handling time p50/p95/p99.
- WebSocket bytes in/out per event.
- Mailbox length / queue pressure during burst traffic.
- CPU and RAM at steady state and during spikes.

### 4. Multi-User Load

Use simulation tests, WebSocket load clients, and browser shards where useful.

Scenarios to require before claiming high performance:

- Idle connections: 1k, 5k, 10k sessions with heartbeat only.
- Active users: 100, 500, 1k sessions sending 1-10 events/sec.
- Game-like room: 16, 64, 256 clients sending 20-60 events/sec.
- Broadcast: one publisher to 10, 100, 1k subscribers.
- Large model: frequent updates against 100KB, 1MB, and larger models.
- Route churn: many users navigating while events are in flight.
- Reconnect storm: many clients reconnecting after server restart/deploy.

For each scenario, record:

- Peak and steady CPU.
- Peak and steady RAM.
- RAM/session and RAM/active event.
- Events/sec sustained without queue growth.
- p95/p99 latency.
- Error/reject/close counts and reasons.

### 5. Server Hot Paths

Check `src/brazier/runtime.gleam`, `src/brazier/transport.gleam`,
`src/brazier/patch.gleam`, `src/brazier/element.gleam`,
`src/brazier/view.gleam`, build/codegen, stores, and PubSub.

- Full view render per event vs dirty/substate render.
- JSON encode/decode cost and repeated serialization.
- Patch diff cost vs full sync threshold.
- Handler registry rebuild cost.
- Route dispatch and child model update cost.
- PubSub/store fanout complexity.
- Process mailbox growth under burst traffic.
- Timer/effect scheduling overhead.
- Allocation-heavy list/string building in hot paths.

Look for accidental O(n²) behavior in:

- Element tree traversal.
- Attribute diffing.
- JSON patch generation.
- Route matching.
- PubSub fanout.
- String concatenation for HTML/JSON/wire messages.

### 6. Client Hot Paths

Check `brazier_client/src/*.mjs` and generated bundles.

- Patch apply complexity and allocation.
- DOM query frequency and selector/path lookup cost.
- Event delegation vs per-node handlers.
- Layout thrash: repeated read/write cycles.
- Large text/list update behavior.
- Local-only state update cost without WebSocket traffic.
- Browser memory growth after long sessions.
- Animation/game loop compatibility: Brazier should not block the main thread.

For game-like apps, prefer:

- Local input prediction or local state for immediate feedback.
- Server-authoritative model sync at controlled frequency.
- Batching/coalescing where it preserves correctness.
- Avoiding whole-model sync for rapidly changing per-frame state.

### 7. Benchmark And Test Quality

Performance tests must be repeatable and actionable.

- Include warmup and steady-state windows.
- Report p50/p95/p99, not only averages.
- Capture CPU/RAM alongside latency/throughput.
- Use fixed seeds and deterministic scenarios where possible.
- Compare against a baseline and fail on meaningful regressions.
- Separate browser rendering cost from server transport cost.
- Store raw results or summaries in a predictable artifact path.
- Run small perf smoke tests in CI and heavier tests manually or nightly.

Flag weak benchmarks:

```text
[MEDIUM][BENCHMARK] test/brazier/sim/load_test.gleam:88 — only asserts no crash
  Impact: A 10x latency regression would still pass.
  Measure: Track events/sec, p95 latency, RAM/session, and mailbox growth.
  Fix: Add thresholds and write a summary artifact.
```

### 8. Resource Bounds And Limits

Performance and safety overlap. Check that limits are cheap and enforced early.

- Incoming frame/body/header limits before expensive decode.
- Outgoing patch/model size thresholds.
- Max timers, effects, subscriptions, batch size, and event rate.
- Static asset caching and compression strategy.
- Backpressure for slow clients.
- Clear metrics/logging when limits reject work.

### 9. Instrumentation

Prefer measurements that can be automated:

- BEAM reductions/process memory/message queue length.
- Total VM memory and scheduler utilization.
- Per-runtime event counters and render durations.
- Transport bytes in/out and frame counts.
- Client Performance API marks and long tasks.
- CDP network, console, DOM mutation, and CPU traces.

If instrumentation is missing, report it as a performance blocker.

## Search Hints

Use `rg` first. Useful patterns:

```sh
rg -n "render|to_string|json|encode|decode|diff|patch|sync|broadcast|pubsub|send|receive|timer|sleep|batch|queue|mailbox|memory|byte_size|length|map|fold|append|concat" src brazier_client test examples --glob '!**/build/**'
rg -n "performance|mark|measure|MutationObserver|requestAnimationFrame|WebSocket|network|cpu|memory|shard|load|users|latency|p95|p99" test_all_cdp.py scripts docs .github
```

## Output Format

Lead with bottlenecks that affect user-visible latency or scalability.

Use this format:

```text
[SEVERITY][AREA] file:line — Short title
  Impact: User-visible or operator-visible performance cost.
  Evidence: Code path, benchmark result, trace, or missing measurement.
  Measure: Specific benchmark/load test to prove and track it.
  Fix: Concrete optimization or instrumentation change.
```

Severity:

- `CRITICAL` — likely collapse under expected production/game-like load.
- `HIGH` — major latency/CPU/RAM bottleneck or missing benchmark for a core
  performance claim.
- `MEDIUM` — plausible bottleneck with limited scope or unproven impact.
- `LOW` — hardening, instrumentation, or micro-optimization.

Area:

- `FIRST-LOAD`
- `HYDRATION`
- `WEBSOCKET`
- `MULTI-USER`
- `SERVER`
- `CLIENT`
- `BENCHMARK`
- `DOCS`

End with:

```text
Performance Audit Results:
  Files/scenarios scanned: N
  Findings: N total
    Critical: N
    High: N
    Medium: N
    Low: N
  Missing benchmarks: N
  Highest-risk workload: ...
  Current confidence: LOW / MEDIUM / HIGH
  Recommended next benchmark:
    Scenario: ...
    Metrics: ...
    Thresholds: ...
```
