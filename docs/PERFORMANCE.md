# Performance

Beacon has one benchmark suite. It measures the HTTP listener, WebSocket
event round trips, the runtime actor, PubSub fan-out and the store. Its
baseline is committed, and `make bench-check` fails when a metric regresses
past its tolerance.

Benchmarks are not tests. `gleam test` never runs them: no bench module has
a `_test` suffix. The generators still check every answer they time
against the wire protocol, so a broken server produces an error naming the
failure, not a misleadingly fast number.

## Commands

| Command | What it does |
|---------|--------------|
| `make bench` | One run. Prints every metric and writes `build/bench/latest.json`. |
| `make bench-check` | `BEACON_BENCH_RUNS` runs (default 3), combined by median and compared with `bench/baselines.json`. Exits non-zero on a regression, a missing or new metric, or a different machine. |
| `make bench-baseline` | `BEACON_BENCH_RUNS` runs (default 5, minimum 3) back to back, written to `bench/baselines.json`. |

Run `bench-baseline` on an otherwise idle machine. Commit the new
`bench/baselines.json` together with the change that moved the numbers,
and say in the commit message why they moved.

A check run on a different machine fails on the machine fields (CPU, OTP
release, erts version, architecture, schedulers) before any metric is
compared. Baselines do not transfer between machines.

## Scenarios

The suite lives in `test/beacon/bench/suite.gleam`, with the generators in
`test/beacon_bench_ffi.erl`. It starts its own counter app on an
OS-assigned port. Every scenario is warmed up before it is measured.
Logging is raised to `warning` once the app is up, so the numbers measure
the framework, not the console.

| Scenario | Load | Metrics |
|----------|------|---------|
| http | 8 keep-alive clients, 2000 requests per round, 5 rounds against `/bench` | requests/s (median of rounds); per-request p50/p99 |
| ws | N joined connections × 200 events each, for N = 1, 10, 100. Each event is timed from its send to the patch that acknowledges its clock. | events/s (median of rounds); per-event p50/p99 |
| runtime | Events pushed straight into a runtime actor holding a 200-item model, 2000 per round. `changed`: every event changes the model and gets a patch. `unchanged`: none does, and each gets an empty acknowledgement. | pipelined µs/event (median of rounds); p50/p99 of one event at a time |
| pubsub | 1000 broadcasts to S subscribers (S = 1, 100, 1000), each timed until every subscriber has it | p50/p99 |
| store | put/get/delete, timed in 50 blocks of 1000 operations | ns/op median and p99 over the blocks |

After each scenario the bench process must have an empty mailbox (see
[the mailbox leak](#the-mailbox-leak)). A stray message fails the run and
names the scenario.

## Tolerances

For each metric the baseline records the median, min and max of its runs.
Spread is (max − min) / median. Each metric's tolerance is then

    tolerance = max(25%, 2 × spread)

and it is not gated at all when that tolerance would exceed 100%.

A check fails a gated metric that is worse than its baseline median by
more than its tolerance. Worse means slower. For lower-is-better metrics
the ratio is value / median. For higher-is-better ones it is
median / value, so a 25% tolerance fails a throughput below median / 1.25.

Why these numbers:

- **2 × spread.** Five back-to-back runs see less variation than separate
  sessions do, so the observed range is doubled.
- **25% floor.** Back-to-back runs never see drift between sessions
  (thermal state, other load, power management), and that drift is
  large. The old `beacon_runtime_bench` was rerun in this session on
  source unchanged since commit efc9412, which had recorded it at
  45–47 µs/event for changed events. It measured 58–61 µs/event, +28%
  for the same code. A tighter floor would fail unchanged code.
- **100% ceiling.** A tolerance above 100% lets a 2× slowdown pass, so it
  cannot catch a regression. Those metrics are reported with their spread
  but never fail a check.
- **What the floor gives up.** A regression under 25% passes
  `bench-check`. The roughly 10% cost of the WS8b telemetry spans is an
  example. A change suspected of costing that much has to be measured
  head to head: base commit next to branch, in one session. WS8b did
  this.

## Baseline

`bench/baselines.json`, 5 runs, measured 2026-11-03.

- **Machine:** Apple M2 Pro, 10 logical processors and 10 schedulers
  online, OTP 28, erts 16.3, aarch64-apple-darwin.
- **Not an idle machine:** the 1-minute load average was about 5.9,
  because other agents' builds and tests were running. Re-baseline on an
  idle machine when one is available.

| Metric | Median | Range | Spread | Tolerance |
|--------|--------|-------|--------|-----------|
| `http.keepalive.8c.throughput` | 51398 req/s | 49740..52149 | 4.7% | 25% |
| `http.keepalive.8c.latency_p50` | 149 µs | 147..154 | 4.7% | 25% |
| `http.keepalive.8c.latency_p99` | 263 µs | 255..290 | 13.3% | 26.6% |
| `ws.1x200.throughput` | 12587 events/s | 11464..15375 | 31.1% | 62.1% |
| `ws.1x200.latency_p50` | 75.5 µs | 71..84 | 17.2% | 34.4% |
| `ws.1x200.latency_p99` | 126 µs | 106..266 | 127% | not gated |
| `ws.10x200.throughput` | 48452 events/s | 46965..49219 | 4.7% | 25% |
| `ws.10x200.latency_p50` | 198 µs | 196..200 | 2.0% | 25% |
| `ws.10x200.latency_p99` | 331 µs | 321..343 | 6.6% | 25% |
| `ws.100x200.throughput` | 56967 events/s | 55661..58654 | 5.3% | 25% |
| `ws.100x200.latency_p50` | 1577 µs | 1545..1618 | 4.6% | 25% |
| `ws.100x200.latency_p99` | 4323 µs | 3996..4516 | 12.0% | 25% |
| `runtime.changed.pipelined` | 60.3 µs/event | 57.2..61.9 | 7.8% | 25% |
| `runtime.changed.latency_p50` | 49.2 µs | 49.0..51.2 | 4.5% | 25% |
| `runtime.changed.latency_p99` | 68.8 µs | 66.7..75.9 | 13.3% | 26.7% |
| `runtime.unchanged.pipelined` | 24.7 µs/event | 22.4..26.8 | 17.5% | 35% |
| `runtime.unchanged.latency_p50` | 19.3 µs | 19.3..19.3 | 0.2% | 25% |
| `runtime.unchanged.latency_p99` | 28.7 µs | 25.9..31.5 | 19.5% | 39% |
| `pubsub.fanout.1.p50` | 1.92 µs | 1.92..1.92 | 0.1% | 25% |
| `pubsub.fanout.1.p99` | 3.58 µs | 2.92..3.96 | 29.1% | 58.1% |
| `pubsub.fanout.100.p50` | 148.4 µs | 127.9..153.5 | 17.3% | 34.5% |
| `pubsub.fanout.100.p99` | 315.6 µs | 273.1..347.8 | 23.6% | 47.3% |
| `pubsub.fanout.1000.p50` | 1708 µs | 1442..1721 | 16.3% | 32.7% |
| `pubsub.fanout.1000.p99` | 2272 µs | 2103..2755 | 28.7% | 57.4% |
| `store.put.median` | 1565 ns/op | 1534..1581 | 3.0% | 25% |
| `store.put.p99` | 1658 ns/op | 1583..1720 | 8.2% | 25% |
| `store.get.median` | 292.8 ns/op | 285.9..298.2 | 4.2% | 25% |
| `store.get.p99` | 323.5 ns/op | 316.3..337.1 | 6.4% | 25% |
| `store.delete.median` | 1575 ns/op | 1515..1602 | 5.5% | 25% |
| `store.delete.p99` | 1689 ns/op | 1652..1779 | 7.5% | 25% |

Two `make bench-check` runs after this baseline both passed. In each, the
only line not marked as passing was the informational line for the
ungated `ws.1x200.latency_p99`.

Some notes on reading the numbers:

- **The ws.1x200 rows** measure one connection, so they are one scheduler
  waiting on one socket. Their spread comes from scheduler placement and
  wake-up, not from Beacon. 10 and 100 connections are the stable ws
  numbers.
- **Repeated p50 values.** On Darwin, `erlang:monotonic_time` ticks at
  about 41.67 ns, so every timing is a whole number of ticks. A
  percentile taken over thousands of samples from a tight distribution
  often lands on the same tick in every run. That, not a perfectly quiet
  machine, is why `pubsub.fanout.1.p50` and
  `runtime.unchanged.latency_p50` show near-zero spreads.

## Runtime re-measurement

The previous runtime figures in docs/PROGRESS.md (WS8b) are 45–47 µs/event
changed and 18–21 µs/event unchanged, from `beacon_runtime_bench`. Here is
what that bench measured in this session, interleaved with the new
suite's runtime scenario, on the same source:

| Round (load avg) | Old bench, changed | Old bench, unchanged | New suite, changed (pipelined) | New suite, unchanged (pipelined) |
|-------|---------|-----------|----------|------------|
| 1 (3.5) | 61 | 27 | 56.7 | 22.2 |
| 2 (4.2) | 58 | 25 | 56.9 | 25.0 |
| 3 (4.8) | 59 | 26 | 57.0 | 24.7 |

All values are µs/event. The old bench divides total time, including one
final changing event, by 2000 and truncates to whole microseconds. The
new suite times exactly its 2000 events and takes the median of rounds.
This explains why the old numbers read slightly higher.

Two conclusions follow:

- **The suites agree.** The new runtime scenario measures the same thing
  as the old bench, within the old bench's rounding, so its baseline is a
  re-measurement, not a different harness.
- **The gap from 45–47 µs is not code.** No file under `src/` changed
  between efc9412, which recorded 45–47 µs, and this baseline. The gap
  is session-to-session drift on a loaded machine. That drift is the
  reason for the 25% floor.

## The mailbox leak

The first version of the suite showed PubSub fan-out latencies that rose
from run to run within one session.

**Cause.** The http clients were monitored but their `DOWN` messages were
never received. They piled up in the bench process: the new invariant
reported 56 after one http scenario. Every later selective
receive scanned past them, and PubSub, which receives once per subscriber
per broadcast, paid for that on every message.

**Fix.** Every client is now awaited to exit with its monitor consumed,
and the suite asserts an empty mailbox after each scenario. Three timeouts
that the bench FFI had silently ignored now return errors. PubSub p50 for
1/100/1000 subscribers dropped from 2.67/229.8/2373 µs to
1.92/148.4/1708 µs.

The lesson applies beyond benchmarks: a long-lived process that monitors
short-lived ones has to receive every `DOWN`. If it does not, every
selective receive it makes gets slower.
