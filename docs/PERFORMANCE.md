# Performance

Brazier has one benchmark suite. It measures the HTTP listener, static
files, gzip, server rendering, WebSocket event round trips, the runtime
actor, streams, the wire encoding, PubSub fan-out, the store, presence and
the browser client's render, patch and stream work. Its baseline is committed, and
`make bench-check` fails when a metric regresses past its tolerance, and
when any metric cannot be gated.

Benchmarks are not tests. `gleam test` never runs them: no bench module has
a `_test` suffix. The generators still check every answer they time
against the wire protocol, so a broken server produces an error naming the
failure, not a misleadingly fast number.

## Commands

| Command | What it does |
|---------|--------------|
| `make bench` | One run. Prints every metric and writes `build/bench/latest.json`. |
| `make bench-check` | `BRAZIER_BENCH_RUNS` runs (default 3), combined by median and compared with `bench/baselines.json`. Exits non-zero on a regression, a metric too noisy to gate, a metric missing from the baseline or from the run, a metric whose unit or direction changed, or a different machine. |
| `make bench-baseline` | `BRAZIER_BENCH_RUNS` runs (default 5, minimum 3) back to back, written to `bench/baselines.json` with the load average before and after. Refuses, writing `build/bench/refused_baseline.json` instead, when any metric is too noisy to gate. |

Each invocation first prepares the fixtures once: it writes the static
files and builds the two client fixture apps. That work is not part of any run.

Run `bench-baseline` on an otherwise idle machine. Commit the new
`bench/baselines.json` together with the change that moved the numbers,
and say in the commit message why they moved.

A check run on a different machine fails on the machine fields (CPU, OTP
release, erts version, architecture, schedulers) before any metric is
compared. Baselines do not transfer between machines.

## Scenarios

The suite lives in `test/brazier/bench/suite.gleam`, which runs the
scenarios of `http_bench.gleam`, `stream_bench.gleam`,
`presence_bench.gleam` and `client_bench.gleam` beside its own. The generators are in
`test/brazier_bench_ffi.erl`. Each HTTP scenario starts its own listener,
and the ws scenario its own counter app, on an OS-assigned port. Every
scenario is warmed up before it is measured. Logging is raised to `warning`
once the app is up, so the numbers measure the framework, not the console.

Every timed answer is checked. An HTTP scenario first sends one probe whose
whole response is compared with what it must be (status, headers, body
bytes), then checks every timed response's status, length and named
headers against the probe. A wrong answer fails the run with a reason.

The HTTP scenarios run 15 measured rounds after 2 warm-up rounds. A round takes 0.1 to 0.5 s, so a burst of outside load must last several seconds to cover the eight rounds that move a median.

| Scenario | Load | Metrics |
|----------|------|---------|
| http | 8 keep-alive clients, 2000 requests per round against `/bench`, a 2-byte answer | requests/s and per-request p50/p99, each the median over rounds |
| static | `brazier/static` serving a 100 KB file (8 clients × 500 requests) and a 10 MB file (4 clients × 25), sent with sendfile (`.200`), and the same files revalidated with the probe's ETag (`.304`, 8 clients × 1000, timed first). The run fails unless the file's digest comes from the digest cache, as it does in production once a file is older than the cache's racy window. | requests/s and per-request p50/p99, each the median over rounds |
| gzip | A 100 KB HTML body through `middleware.compress` with `Accept-Encoding: gzip`, 8 clients × 100. The probe gunzips the body, compares it with the original and checks it compressed to under half. | requests/s and per-request p50/p99, each the median over rounds |
| ssr | `ssr.render_page` of a 100-row (8 × 800 requests) and a 1000-row (8 × 50) view with a click handler per row, as `brazier.start` serves the first page. The probe checks every row and the client bundle's script tag. | requests/s and per-request p50/p99, each the median over rounds |
| ssr stream | `ssr.stream_300`: as `ssr`, for a page whose `init` fills a `KeepLast(300)` stream with 300 lines of 1 KB text and a click handler each (8 × 50). The probe checks the 300 item keys, in order, and the client bundle's script tag. | requests/s and per-request p50/p99, each the median over rounds |
| ws | N joined connections × 200 events each, for N = 1, 10, 100, in 25, 15 and 5 measured rounds. Each event is timed from its send to the patch that acknowledges its clock. | events/s and per-event p50/p99, each the median over rounds |
| runtime | Events pushed straight into a runtime actor holding a 200-item model, 2000 per round. `changed`: every event changes the model and gets a patch. `unchanged`: none does, and each gets an empty acknowledgement. | pipelined µs/event (median of rounds); p50/p99 of one event at a time, by round |
| runtime list | As `runtime` `changed`, against a model whose list encodes to about 50 KB (1000 items, 200 events per round, 1000 sequential) and 500 KB (10000 items, 40 per round, 300 sequential). Each event changes one field, so the metric is the cost of the work done on the whole model. | pipelined µs/event (median of rounds); p50/p99 of one event at a time, by round |
| runtime stream | Events pushed straight into a runtime actor whose `KeepLast(300)` stream of 1 KB lines is full from the join on, 1000 per round after one warm-up round, then 1000 sequential. `append`: each event appends a line, so its frame carries one insert at 299 and the trim of the oldest line. `chunk`: each event re-inserts the last line with 100 more bytes, an update in place with no delete. Every event must be acknowledged by its own patch, in clock order, and each patch's `streams` field is decoded and checked against the event's change after the timer stops. | pipelined µs/event (median of rounds); p50/p99 of one event at a time, by round |
| wire | A one-op `patch` and a `model_sync` of the 50 KB model, each encoded into the frame `send_ws_message` hands `gen_tcp:send/2`, in 500 blocks of 200. `wire.stream_patch` is a one-op `patch` whose `streams` field inserts one 1 KB line and trims one. | ns/frame median and p99 of the block timings, by round |
| pubsub | Broadcasts to S subscribers, each timed until every subscriber has it: 20000 to 1, 2000 to 100, 1000 to 1000 | µs p50/p99, by round |
| store | put/get/delete, timed in 50 blocks of 1000 operations | ns/op median and p99 of the block timings, by round |
| crdt append | One value appended to a replicated list key holding 10, 1000 or 10000 values (`brazier/store/crdt`, the work the replica server and every receiving node do per write), in 50 blocks of 1000 | ns/op median and p99 of the block timings, by round |
| presence | A `brazier/presence` tracker with a room of 10 entries and one of 10000 (100 holder processes × 100 keys), filled before anything is timed. `track`/`untrack`: 10000 of each, each timed until the subscriber has the diff naming exactly that key. `list`: the whole room, checked to hold every entry, 2000 times for 10 entries and 50 for 10000. | µs median and p99, by round |
| client | The browser client's work for a 100- and a 1000-row model, in node, with the client entry a real `build.build` produces. `render`: `render` and `event_names`, what `renderNow` does before the DOM morph (2000 and 400 calls). `patch`: `handlePatch` before the morph, that is `JSON.parse` of the ops, `applyOps`, `decode_model`, `render` and `event_names`, for a patch that changes every tenth label and the selection. The client's HTML must equal the server's before and after the patch. | µs median and p99, by round |
| client stream | A second fixture app holding a full `KeepLast(300)` stream of 1 KB lines. Its generator applies the app's own ops with the server's stream windows (`stream_window.apply_update`) and writes the `streams` fields the runtime sends, and the server's HTML for each new item (`render.render_item`). Node fills a store with the 300-line frame, then times one frame applied to it: `JSON.parse`, `decodeStreams`, `applyEntry`, and `render_item` with `event_names` for each inserted or updated item, what `applyFrameStreams` does before the DOM work (500 warm-up and 2000 timed calls). `append`: one insert and one trim. `chunk`: the last line grown by 100 bytes. Every call's item HTML must equal the server's. | µs median and p99, by round |

The client scenarios do not measure the DOM work: node has no DOM. The
morph, and the stream item insertion, need a browser measurement over CDP.

Every percentile is taken per round. A metric's median (p50) and p99 are
the medians over rounds of each round's median and p99, as a throughput is
the median round's. They are not percentiles of the pooled samples of every
round:

- The round-based scenarios (http, static, gzip, ssr, ws) use their own
  rounds.
- The scenarios that time one long sequence (runtime sequential events,
  wire, pubsub, store, crdt append, presence, client) cut it, in the order
  it was taken, into 5 equal consecutive rounds
  (`measure.percentiles_by_round`).

On a shared machine a burst of outside load can slow part of one round, and
pooled, that round's slow samples become the run's p99. A nearest-rank p99
over 50 block timings is the slowest block, so one preempted block set it.
A slowdown in the code shows in every round's p99, so it moves their
median. A burst in fewer than half the rounds does not move it. This is the
per-iteration statistic that criterion and JMH report. `measure_test.gleam`
checks both cases.

Each scenario runs in a fresh process (`measure.isolated`). The bench
process holds the prepared fixtures and every earlier run's results, so
its heap grows run over run, and a scenario timed in it pays for
collecting that heap. Timed in the bench process, `pubsub.fanout.1.p99`
rose in every one of five runs (2.7, 3.3, 3.8, 4.8, 5.5 µs). The same
fan-out on its own in a VM held at 2.0–2.7 µs over eight runs.
`wire.patch`, `wire.model_sync_50kb` and `store.crdt_append.1000` drifted
up by 10–15% the same way. With isolation, VM memory after each run holds
at about 59 MB instead of climbing from 59 to 80 MB, and the drift is
gone. Benchee runs each scenario in its own process for the same reason.

When a scenario finishes, both its process and the bench process must have
an empty mailbox (see [the mailbox leak](#the-mailbox-leak)). A stray
message fails the run and names the scenario. After every run the suite
prints a census of the VM: processes, ports, ETS tables, memory and atoms.
A scenario that leaks one of these shows as a count that grows run over
run.

## Tolerances

For each metric the baseline records the median, min and max of its runs.
Spread is (max − min) / median. A metric is gated when its spread is
under 50%, and its tolerance is then

    tolerance = max(25%, spread)

A metric whose spread is 50% or more has no tolerance. `make
bench-baseline` refuses to write a baseline that holds one, and names
each such metric with its spread. The fix is more samples for that
metric, not a wider rule.

A check fails a gated metric that is worse than its baseline median by
more than its tolerance. Worse means slower. For lower-is-better metrics
the ratio is value / median. For higher-is-better ones it is
median / value, so a 25% tolerance fails a throughput below median / 1.25.
A value exactly at the limit passes.

`make bench-check` fails, naming the metric, in each of these cases:

| Verdict | When |
|---------|------|
| regressed | worse than the baseline median by more than the tolerance |
| too noisy | the baseline has no tolerance for it (a baseline from before this rule, or edited by hand) |
| missing | in the baseline but not measured by this run |
| unexpected | measured but not in the baseline |
| redefined | its unit or direction differs from the baseline's |

A different machine fails before any metric is compared.

Why these numbers:

- **A 1.5× slowdown fails every gated metric.** The spread must be under
  50%, so every tolerance is under 50%, and a ratio of 1.5 is past it.
  This is why the tolerance is the spread itself and not a multiple of
  it: with 2 × spread, any metric with a spread of 25% or more would pass
  a 1.5× slowdown. The unit tests check this at the widest gated spread,
  49%.
- **Spread as the margin.** A check compares the median of 3 runs. That
  median falls outside the baseline's own range only when two of the
  three runs do, so a tolerance equal to the observed range does not fail
  unchanged code on one bad run.
- **25% floor.** Back-to-back runs never see drift between sessions
  (thermal state, other load, power management), and that drift is
  large. The old `brazier_runtime_bench` was rerun in this session on
  source unchanged since commit efc9412, which had recorded it at
  45–47 µs/event for changed events. It measured 58–61 µs/event, +28%
  for the same code. A tighter floor would fail unchanged code. Under the
  load the 2026-11-04 baseline was taken in, four of its 87 metrics
  spread past the floor, the widest `pubsub.fanout.1.p99` at 37%.
- **50% bound, strict.** A metric whose own runs differ by half its median
  cannot tell a 1.5× regression from noise. Reporting it without gating
  it would let any slowdown through, so it is refused instead. Each
  scenario's sample count is set so that its p99 settles under the bound:
  a p99 over 1000 samples is moved by any 10 slow ones.
- **What the floor gives up.** A regression under 25% passes
  `bench-check`. The roughly 10% cost of the WS8b telemetry spans is an
  example. A change suspected of costing that much has to be measured
  head to head: base commit next to branch, in one session. WS8b did
  this.

## Baseline

`bench/baselines.json`, 5 runs, recorded 2026-11-04T21:05:39Z by `make
bench-baseline`. Every one of its 87 metrics is gated.

- **Machine:** Apple M2 Pro, 10 logical processors and 10 schedulers
  online, OTP 28, erts 16.3, aarch64-apple-darwin.
- **Not an idle machine:** the load average (1, 5 and 15 minutes) was
  2.18 3.82 4.95 before the runs and 8.18 7.02 6.14
  after, because other agents' builds and tests were running. The file
  records both under `conditions`. This baseline is to be replaced by one
  taken on an idle machine; until then, treat a failure near the limit as
  a reason to rerun on a quiet machine before blaming the code.

| Metric | Median | Range | Spread | Tolerance |
|--------|--------|-------|--------|-----------|
| `http.keepalive.8c.throughput` | 61910 req/s | 61353..62696 | 2.2% | 25% |
| `http.keepalive.8c.latency_p50` | 124.0 µs | 122.0..125.0 | 2.4% | 25% |
| `http.keepalive.8c.latency_p99` | 225.0 µs | 222.0..229.0 | 3.1% | 25% |
| `http.static.100kb.200.throughput` | 14054 req/s | 13958..14233 | 2.0% | 25% |
| `http.static.100kb.200.latency_p50` | 555.5 µs | 552.0..561.0 | 1.6% | 25% |
| `http.static.100kb.200.latency_p99` | 839.0 µs | 826.0..844.0 | 2.1% | 25% |
| `http.static.100kb.304.throughput` | 21930 req/s | 21286..22896 | 7.3% | 25% |
| `http.static.100kb.304.latency_p50` | 354.0 µs | 337.0..365.0 | 7.9% | 25% |
| `http.static.100kb.304.latency_p99` | 575.0 µs | 537.0..592.0 | 9.6% | 25% |
| `http.static.10mb.200.throughput` | 812.9 req/s | 805.6..817.6 | 1.5% | 25% |
| `http.static.10mb.200.latency_p50` | 4738 µs | 4674..4802 | 2.7% | 25% |
| `http.static.10mb.200.latency_p99` | 6549 µs | 6447..6562 | 1.8% | 25% |
| `http.static.10mb.304.throughput` | 22223 req/s | 21065..23160 | 9.4% | 25% |
| `http.static.10mb.304.latency_p50` | 347.0 µs | 332.0..368.0 | 10.4% | 25% |
| `http.static.10mb.304.latency_p99` | 565.0 µs | 553.0..607.0 | 9.6% | 25% |
| `http.gzip_100kb.throughput` | 7336 req/s | 7290..7462 | 2.4% | 25% |
| `http.gzip_100kb.latency_p50` | 1016 µs | 1004..1033 | 2.9% | 25% |
| `http.gzip_100kb.latency_p99` | 1643 µs | 1624..1649 | 1.5% | 25% |
| `ssr.rows_100.throughput` | 7505 req/s | 7434..7647 | 2.8% | 25% |
| `ssr.rows_100.latency_p50` | 1043 µs | 1024..1052 | 2.7% | 25% |
| `ssr.rows_100.latency_p99` | 1555 µs | 1518..1597 | 5.1% | 25% |
| `ssr.rows_1000.throughput` | 943.9 req/s | 919.7..950.7 | 3.3% | 25% |
| `ssr.rows_1000.latency_p50` | 7930 µs | 7905..7986 | 1.0% | 25% |
| `ssr.rows_1000.latency_p99` | 15012 µs | 14068..16435 | 15.8% | 25% |
| `ws.1x200.throughput` | 15518 events/s | 15378..15598 | 1.4% | 25% |
| `ws.1x200.latency_p50` | 62.0 µs | 61.5..62.5 | 1.6% | 25% |
| `ws.1x200.latency_p99` | 101.0 µs | 97.0..102.0 | 5.0% | 25% |
| `ws.10x200.throughput` | 60080 events/s | 59643..61497 | 3.1% | 25% |
| `ws.10x200.latency_p50` | 158.0 µs | 155.0..159.0 | 2.5% | 25% |
| `ws.10x200.latency_p99` | 276.0 µs | 263.0..282.0 | 6.9% | 25% |
| `ws.100x200.throughput` | 71213 events/s | 70762..71929 | 1.6% | 25% |
| `ws.100x200.latency_p50` | 1316 µs | 1307..1326 | 1.4% | 25% |
| `ws.100x200.latency_p99` | 2910 µs | 2848..2937 | 3.1% | 25% |
| `runtime.changed.pipelined` | 31.6 µs/event | 31.5..31.9 | 1.2% | 25% |
| `runtime.changed.latency_p50` | 25.3 µs | 25.2..25.3 | 0.3% | 25% |
| `runtime.changed.latency_p99` | 44.5 µs | 39.3..51.1 | 26.5% | 26.5% |
| `runtime.unchanged.pipelined` | 17.8 µs/event | 17.0..21.2 | 23.4% | 25% |
| `runtime.unchanged.latency_p50` | 13.5 µs | 13.4..13.5 | 0.6% | 25% |
| `runtime.unchanged.latency_p99` | 25.1 µs | 24.4..26.2 | 7.3% | 25% |
| `runtime.list_50kb.changed.pipelined` | 147.7 µs/event | 145.5..148.5 | 2.1% | 25% |
| `runtime.list_50kb.changed.latency_p50` | 151.0 µs | 151.0..151.3 | 0.2% | 25% |
| `runtime.list_50kb.changed.latency_p99` | 189.4 µs | 175.7..198.0 | 11.8% | 25% |
| `runtime.list_500kb.changed.pipelined` | 1816 µs/event | 1739..1828 | 4.9% | 25% |
| `runtime.list_500kb.changed.latency_p50` | 1825 µs | 1738..1844 | 5.8% | 25% |
| `runtime.list_500kb.changed.latency_p99` | 2350 µs | 2314..2387 | 3.1% | 25% |
| `wire.patch.median` | 320.2 ns/frame | 318.7..321.9 | 1.0% | 25% |
| `wire.patch.p99` | 441.9 ns/frame | 419.4..467.5 | 10.9% | 25% |
| `wire.model_sync_50kb.median` | 316.3 ns/frame | 314.8..328.9 | 4.4% | 25% |
| `wire.model_sync_50kb.p99` | 416.9 ns/frame | 404.4..465.6 | 14.7% | 25% |
| `pubsub.fanout.1.p50` | 1.38 µs | 1.33..1.38 | 3.0% | 25% |
| `pubsub.fanout.1.p99` | 2.83 µs | 2.46..3.50 | 36.8% | 36.8% |
| `pubsub.fanout.100.p50` | 105.3 µs | 100.9..105.9 | 4.7% | 25% |
| `pubsub.fanout.100.p99` | 232.4 µs | 221.8..244.3 | 9.6% | 25% |
| `pubsub.fanout.1000.p50` | 1287 µs | 1239..1307 | 5.3% | 25% |
| `pubsub.fanout.1000.p99` | 1677 µs | 1654..1687 | 2.0% | 25% |
| `store.put.median` | 1014 ns/op | 1004..1029 | 2.5% | 25% |
| `store.put.p99` | 1159 ns/op | 1095..1166 | 6.1% | 25% |
| `store.get.median` | 132.3 ns/op | 131.2..138.6 | 5.6% | 25% |
| `store.get.p99` | 151.8 ns/op | 139.8..164.4 | 16.2% | 25% |
| `store.delete.median` | 994.5 ns/op | 986.5..1054 | 6.8% | 25% |
| `store.delete.p99` | 1125 ns/op | 1098..1160 | 5.5% | 25% |
| `store.crdt_append.10.median` | 816.4 ns/op | 801.5..822.2 | 2.5% | 25% |
| `store.crdt_append.10.p99` | 896.5 ns/op | 844.2..973.6 | 14.4% | 25% |
| `store.crdt_append.1000.median` | 489.1 ns/op | 486.2..489.9 | 0.7% | 25% |
| `store.crdt_append.1000.p99` | 535.2 ns/op | 530.0..545.9 | 3.0% | 25% |
| `store.crdt_append.10000.median` | 538.7 ns/op | 529.0..546.8 | 3.3% | 25% |
| `store.crdt_append.10000.p99` | 597.5 ns/op | 573.0..612.0 | 6.5% | 25% |
| `presence.track.10.median` | 5.29 µs | 5.25..5.33 | 1.6% | 25% |
| `presence.track.10.p99` | 18.9 µs | 17.8..20.2 | 13.0% | 25% |
| `presence.untrack.10.median` | 3.38 µs | 3.33..3.38 | 1.2% | 25% |
| `presence.untrack.10.p99` | 15.5 µs | 13.2..17.4 | 26.8% | 26.8% |
| `presence.list.10.median` | 3.42 µs | 3.38..3.42 | 1.2% | 25% |
| `presence.list.10.p99` | 10.6 µs | 9.67..13.0 | 31.4% | 31.4% |
| `presence.track.10000.median` | 5.88 µs | 5.67..6.04 | 6.4% | 25% |
| `presence.track.10000.p99` | 17.3 µs | 15.0..17.8 | 16.2% | 25% |
| `presence.untrack.10000.median` | 4.04 µs | 3.88..4.08 | 5.1% | 25% |
| `presence.untrack.10000.p99` | 12.8 µs | 11.1..13.1 | 16.0% | 25% |
| `presence.list.10000.median` | 5890 µs | 5197..6125 | 15.8% | 25% |
| `presence.list.10000.p99` | 7479 µs | 6930..7671 | 9.9% | 25% |
| `client.render.rows_100.median` | 156.2 µs | 155.5..157.3 | 1.1% | 25% |
| `client.render.rows_100.p99` | 308.7 µs | 305.6..323.8 | 5.9% | 25% |
| `client.patch.rows_100.median` | 260.4 µs | 259.7..261.6 | 0.7% | 25% |
| `client.patch.rows_100.p99` | 412.4 µs | 408.2..439.2 | 7.5% | 25% |
| `client.render.rows_1000.median` | 1647 µs | 1634..1664 | 1.8% | 25% |
| `client.render.rows_1000.p99` | 2872 µs | 2742..2928 | 6.5% | 25% |
| `client.patch.rows_1000.median` | 2765 µs | 2745..2788 | 1.5% | 25% |
| `client.patch.rows_1000.p99` | 4054 µs | 3952..4154 | 5.0% | 25% |

A `make bench-check` right after this baseline passed, under a load
average of 7 to 9. Its worst metric was `pubsub.fanout.1.p99`, at 1.15×
its median against a limit of 1.37×; every other metric was within 1.07×.

Some notes on reading the numbers:

- **The `wire` numbers stay flat with model size** because the frame is
  iodata: the model JSON goes into it as the binary the runtime already
  holds, so the cost of copying it into the socket, paid in the kernel by
  both the old and the new frame, is not in the metric. The flat encoding
  these rows replaced measured 117 µs per 50 KB `model_sync` and about
  1 µs per patch.
- **Growth with size.** The table's `ssr.rows_1000` (about 8 ms a page
  against 1 ms at 100 rows) was superlinear. A single-process profile of
  the page (2026-11-05, a loaded machine) put the render at 0.3 ms for
  100 rows, 4 ms for 1000 and 110 ms for 10,000: 14x, then 28x, for 10x
  the rows, while every function's call count grew linearly. The growth
  was `string_tree.to_string`, which is `unicode:characters_to_binary`:
  on the deep left-nested iolist a render builds it costs 0.017 µs a
  piece at 3,000 pieces, 0.028 at 30,000 and 0.121 at 300,000, where
  `iolist_to_binary` stays at 0.011 to 0.015. A render's tree holds only
  Gleam strings, which are UTF-8 already, so the walk now ends with
  `iolist_to_binary` (`brazier_render_ffi:iodata_to_string`). The second
  cost was OTP's `string:lowercase/1`, which raises and catches an
  exception inside for a name that is already lowercase: about 0.1 µs a
  name, 13% of the render, paid twice per attribute. The attribute name
  policy now lowercases `A-Z` itself; `brazier/internal/url` still calls
  `string.lowercase` once per attribute (a follow-up in docs/TODO.md).
  After both, the same profile renders 100, 1000 and 10,000 rows in
  0.25, 3.0 and 45 ms: 12x, then 15x, the rest being garbage collection
  of the bigger heap. In `http_bench`, three runs each, interleaved on
  the same loaded machine: `ssr.rows_1000` went from 913 to 929 req/s
  (p50 8.2 to 8.4 ms) to 1146 to 1195 req/s (p50 6.5 to 6.7 ms), about
  28% more pages; `ssr.rows_100` did not move outside its noise (8650 to
  9890 req/s either way) and `ssr.stream_300` rose about 3% (826 to 838
  req/s, then 850 to 866). `ssr.stream_300` is linear: of its 5.4 ms
  single-process page, the 300 items cost about 1 to 2.5 µs per KB in
  each of escaping, decoding the item JSON back (the check that the
  stream's encoder and decoder agree) and its UTF-8 check in
  `gleam/dynamic/decode`, and encoding the join's JSON.
  `client.patch.rows_1000` is about 2.8 ms.
- **`presence.list.10000`** is about 5.9 ms, while `track` and `untrack`
  stay flat at 4 to 6 µs. A list copies every row of the topic out of
  the shard's ETS table into the caller and decodes each meta, which is
  Phoenix's pattern too: `Phoenix.Tracker.list` is one `:ets.select` of
  the topic and `Phoenix.Presence.list` groups the result by key. Phoenix
  keeps metas as terms; Brazier keeps the JSON it replicates and decodes
  it with the tracker's decoder on read, the type check on metas that
  came from other nodes. A single-process profile (2026-11-05, load 6 to
  9), median of 21 fresh processes, in µs per entry:

  | Entries | `ets:select` | `json.parse` | `list` | `list`, heap that never collects |
  |---------|------|------|------|------|
  | 3,000 | 0.21 | 0.16 | 0.46 | 0.35 |
  | 10,000 | 0.42 to 0.53 | 0.17 | 0.61 to 0.63 | 0.38 to 0.40 |
  | 30,000 | 0.38 | 0.19 | 0.92 to 1.13 | 0.45 to 0.51 |

  With a heap big enough to never collect, every stage stays near flat
  per entry, the select at 0.13 to 0.21 µs and the decode at 0.11 (OTP's
  `json:decode` alone is 0.05; the rest is gleam_json's wrapper and the
  decoder). What grows is the collection of the caller's heap as the
  10,000 entries' 340,000 words land on it, about a third of the list at
  10,000 entries and half of it at 30,000. Two changes measured no real
  gain, so neither shipped. Grouping and decoding in one pass instead of
  `try_map`, `chunk` and `map` gave no difference outside the noise.
  Reading the topic in chunks of 256 rows (`ets:select/3`), decoding each
  before reading the next so the raw rows of the whole room are never
  live at once, cut a list's minor collections from 8 to 3. Yet in four
  interleaved A/B runs against the old code it was 5.5 to 5.9 ms against
  5.9 to 6.1, 4 to 6%, and the heap after a list was the same 196,650
  words, as the result itself is most of it. A `brazier.presence`
  watcher lists a topic once when its session starts following it and
  again to reconcile after a shard restart, and otherwise applies diffs,
  as a Phoenix channel pushes `presence_state` once on join and then
  diffs. So the list cost is paid per join, not per change. The open
  issue is in docs/TODO.md.
- **Repeated p50 values.** On Darwin, `erlang:monotonic_time` ticks at
  about 41.67 ns, so every timing is a whole number of ticks. A
  percentile taken over thousands of samples from a tight distribution
  often lands on the same tick in every run. That, not a perfectly quiet
  machine, is why `runtime.changed.latency_p50` and
  `runtime.list_50kb.changed.latency_p50` show near-zero spreads.

## Streams

The stream scenarios (design §16 of `docs/design/STREAMS.md`) postdate the
2026-11-04 baseline, so `bench/baselines.json` does not hold their 15
metrics, and `make bench-check` fails them as unexpected until the next
`make bench-baseline`. One `make bench` on 2026-11-05, on the baseline's
machine with other agents' builds running:

| Metric | Value |
|--------|-------|
| `ssr.stream_300.throughput` | 867.8 req/s |
| `ssr.stream_300.latency_p50` | 8832 µs |
| `ssr.stream_300.latency_p99` | 12259 µs |
| `runtime.stream.append.pipelined` | 87.8 µs/event |
| `runtime.stream.append.latency_p50` | 82.2 µs |
| `runtime.stream.append.latency_p99` | 135.4 µs |
| `runtime.stream.chunk.pipelined` | 67.8 µs/event |
| `runtime.stream.chunk.latency_p50` | 63.5 µs |
| `runtime.stream.chunk.latency_p99` | 91.5 µs |
| `wire.stream_patch.median` | 383.1 ns/frame |
| `wire.stream_patch.p99` | 481.7 ns/frame |
| `client.stream.append.300.median` | 21.4 µs |
| `client.stream.append.300.p99` | 81.7 µs |
| `client.stream.chunk.300.median` | 20.2 µs |
| `client.stream.chunk.300.p99` | 64.4 µs |

The design compares a stream with a model list of the same size. The suite
has no 300 KB list scenario; the two it has bracket one. In the same run,
`runtime.list_50kb.changed.pipelined` was 150.9 µs/event and
`runtime.list_500kb.changed.pipelined` 1779 µs/event, so a list event costs
about 3.5 µs per KB of model, and by that slope a 300 KB list would cost
about 1 ms an event. That is an estimate, not a measurement. Against it,
an append to the 300 KB stream costs 88 µs: the runtime encodes and sends
only the line the event adds and the key it trims, while a list event
re-encodes and diffs the whole model. On the client, applying one stream
frame and rendering its line takes about 21 µs, against 2.75 ms for a
1000-row `client.patch`, which re-renders the whole view.

`ssr.stream_300` is a page of about 300 KB of escaped text and 300
handlers; at 8.8 ms it costs about what `ssr.rows_1000` does (7.9 ms in the
same run). The first page renders every item, so a stream saves nothing
there.

## Runtime re-measurement

The previous runtime figures in docs/PROGRESS.md (WS8b) are 45–47 µs/event
changed and 18–21 µs/event unchanged, from `brazier_runtime_bench`. Here is
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
