//// The benchmark suite: one run measures every scenario and returns a
//// `report.Report`. Run it through `brazier_bench` (print),
//// `brazier_bench_check` (compare with bench/baselines.json) or
//// `brazier_bench_baseline` (re-baseline); see docs/PERFORMANCE.md.
////
//// `prepare` runs once per invocation (static files, the client fixture
//// build); `run` measures every scenario once. Scenarios, each warmed up
//// before it is measured:
////
//// - http, static, gzip, ssr: brazier/bench/http_bench. Requests per
////   second (median of the rounds) and per-request latency (p50/p99 over
////   every request of every measured round).
//// - ws: N joined connections x M events each, every event timed from its
////   send to the patch acknowledging it. Events per second (median of the
////   rounds) and per-event latency p50/p99.
//// - runtime: events pushed straight into a runtime actor holding a
////   200-item model. Pipelined cost per event (median of the rounds) when
////   every event changes the model (patch) and when none does (empty
////   acknowledgement), and the p50/p99 of one event at a time.
//// - runtime list: the runtime's changed events against a model whose list
////   encodes to about 50 KB or 500 KB, so one changed field costs whatever
////   the per-event work on the whole model costs (encode, diff, patch).
//// - wire: a server message encoded into the WebSocket frame handed to the
////   socket, for a one-op patch and for a model_sync of the 50 KB model.
//// - pubsub: one broadcast timed until every one of S subscribers has it.
//// - store: put/get/delete timed in blocks of 1000 operations.
//// - crdt append: one value appended to a replicated list key that holds
////   10, 1000 or 10000 values (brazier/store/crdt, the work the replica
////   server and every receiving node do per write), in blocks of 1000.
//// - presence: brazier/bench/presence_bench, track/untrack/list in rooms
////   of 10 and 10000 entries.
//// - patch: brazier/bench/patch_bench, the server diff of a sliding
////   window of 200 and 2000 events (ops, bytes and time per diff).
//// - client: brazier/bench/client_bench, the browser's render and patch
////   work for 100 and 1000 rows, in node.
////
//// Every generator checks every answer it times (brazier_bench_ffi): a
//// failure is an Error naming it, never a fast number. Logging is set to
//// warning once the app is up, so the numbers are the framework's, not the
//// console's. Nothing here is a test; gleam test never runs it.

import brazier/application
import brazier/bench/client_bench
import brazier/bench/http_bench
import brazier/bench/measure.{
  check, gc, isolated, median_and_p99, now_ns, percentiles_by_round, repeat,
  repeat_from, rounds, string_of, throughput_and_latency, timeout_ms,
}
import brazier/bench/patch_bench
import brazier/bench/presence_bench
import brazier/bench/report.{type Metric, LowerIsBetter, Metric}
import brazier/bench/stats
import brazier/effect
import brazier/error
import brazier/log
import brazier/runtime
import brazier/sim/test_app
import brazier/store
import brazier/store/crdt
import brazier/store/hlc
import brazier/test_ctx
import brazier/transport
import brazier/transport/ws
import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/order
import gleam/result
import gleam/string
import logging

/// #(connections, events per connection, measured rounds). The latency
/// p99 is over every event of every round, so the small cells run more
/// rounds: 1x200 x 5 rounds is 1000 events, whose p99 is its 10 slowest
/// and moved by any scheduling hiccup.
const ws_grid = [#(1, 200, 25), #(10, 200, 15), #(100, 200, 5)]

const ws_warmup_rounds = 1

const runtime_items = 200

const runtime_events = 2000

const runtime_warmup_rounds = 1

/// The large-model runtime scenarios: #(name, items, events per pipelined
/// round, sequential events). Every item encodes to `list_item_bytes` + 3
/// bytes (quotes and comma), so 1000 items are about 50 KB of JSON and
/// 10000 about 500 KB. Fewer events per round for the larger model keep a
/// round near a second; the sequential events, whose p99 is gated, are
/// enough for that p99 not to be one of a handful of samples.
const list_models = [
  #("list_50kb", 1000, 200, 1000),
  #("list_500kb", 10_000, 40, 300),
]

const list_item_bytes = 48

/// Frames per timed block of the wire scenario, and the blocks timed.
const wire_block = 200

const wire_warmup_blocks = 5

const wire_blocks = 500

/// #(subscribers, measured broadcasts). The one-subscriber broadcast takes
/// about a microsecond, so its p99 needs many more samples to settle.
const pubsub_fanouts = [#(1, 20_000), #(100, 2000), #(1000, 1000)]

/// Broadcasts to the same subscribers before the measured ones, so the
/// measured ones reach processes that have already run.
const pubsub_warmup_broadcasts = 100

const store_block = 1000

const store_warmup_blocks = 5

const store_blocks = 50

@external(erlang, "brazier_bench_ffi", "machine")
fn machine() -> List(#(String, String))

@external(erlang, "brazier_bench_ffi", "ws_round")
fn ws_round(
  host: String,
  port: Int,
  conns: Int,
  events: Int,
  timeout_ms: Int,
) -> Result(#(Int, List(Int)), String)

@external(erlang, "brazier_bench_ffi", "pubsub_fanout")
fn pubsub_fanout(
  topic: String,
  subscribers: Int,
  warmup: Int,
  broadcasts: Int,
  timeout_ms: Int,
) -> Result(List(Int), String)

/// What `prepare` made for every run: the static files are on disk, the
/// client fixture is built.
pub opaque type Prepared {
  Prepared(client: client_bench.Fixture)
}

/// Write the static bench files and build the client fixture. Once per
/// invocation: the fixture build and the static files' racy window are not
/// part of any run.
pub fn prepare() -> Result(Prepared, String) {
  use Nil <- result.try(
    http_bench.prepare()
    |> result.map_error(fn(reason) { "prepare static files: " <> reason }),
  )
  use client <- result.try(
    client_bench.prepare()
    |> result.map_error(fn(reason) { "prepare client fixture: " <> reason }),
  )
  Ok(Prepared(client:))
}

/// Run every scenario once. Starts (and stops) its own app on an
/// OS-assigned port.
pub fn run(prepared: Prepared) -> Result(report.Report, String) {
  use app <- result.try(
    test_app.start_counter_app_with_limits(
      transport.SecurityLimits(
        ..test_app.sim_security_limits(),
        // The WS scenario sends as fast as the server answers; the
        // default 50/s per connection would refuse it.
        max_events_per_second: 1_000_000,
      ),
    )
    |> result.map_error(fn(e) { "bench app: " <> error.to_string(e) }),
  )
  log.set_level(logging.Warning)
  // Each scenario runs in a fresh process (measure.isolated), which also
  // fails the run when it leaves a message in either mailbox.
  let measured =
    [
      #("http", http_bench.run),
      #("ws", fn() { ws_scenario(app.port) }),
      #("runtime", runtime_scenario),
      #("runtime list", runtime_list_scenario),
      #("wire", wire_scenario),
      #("pubsub", pubsub_scenario),
      #("store", store_scenario),
      #("crdt append", crdt_append_scenario),
      #("presence", presence_bench.run),
      #("patch", patch_bench.run),
      #("client", fn() { client_bench.run(prepared.client) }),
    ]
    |> list.try_map(fn(scenario) { isolated(scenario.0, scenario.1) })
    |> result.map(list.flatten)
  log.set_level(logging.Info)
  let stopped =
    application.stop(app)
    |> result.map_error(fn(e) { "bench app stop: " <> error.to_string(e) })
  case measured, stopped {
    Ok(metrics), Ok(Nil) -> Ok(report.new_report(machine(), metrics))
    Error(reason), _ -> Error(reason)
    Ok(_), Error(reason) -> Error(reason)
  }
}

// --- ws ---

fn ws_scenario(port: Int) -> Result(List(Metric), String) {
  list.try_map(ws_grid, fn(cell) {
    let #(conns, events, measured) = cell
    let name = "ws." <> int.to_string(conns) <> "x" <> int.to_string(events)
    let round = fn() { ws_round("localhost", port, conns, events, timeout_ms) }
    {
      use _ <- result.try(repeat(ws_warmup_rounds, round))
      use samples <- result.try(
        repeat(measured, fn() {
          gc()
          round()
        }),
      )
      throughput_and_latency(name, "events/s", conns * events, samples)
    }
    |> result.map_error(fn(reason) { name <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

// --- runtime ---

type BenchModel {
  BenchModel(count: Int, items: List(String))
}

type BenchMsg {
  Bump
  Nothing
}

fn runtime_config(
  items: List(String),
) -> runtime.RuntimeConfig(BenchModel, BenchMsg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(BenchModel(count: 0, items: items), effect.none())) },
    update: fn(model: BenchModel, msg: BenchMsg) {
      case msg {
        Bump -> #(BenchModel(..model, count: model.count + 1), effect.none())
        Nothing -> #(model, effect.none())
      }
    },
    decode_event: fn(_name, handler_id, _data, _path) {
      case handler_id {
        "bump" -> Ok(Bump)
        "nothing" -> Ok(Nothing)
        _ -> Error(error.RuntimeError(reason: "unknown handler " <> handler_id))
      }
    },
    encode_model: encode_bench_model,
    route: option.None,
    restore_model: option.None,
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    secret_key: "bench-secret-key-that-is-long-enough-for-hmac",
    presence: option.None,
    title: option.None,
    streams: runtime.no_streams(),
  )
}

fn encode_bench_model(model: BenchModel) -> String {
  json.object([
    #("count", json.int(model.count)),
    #("items", json.array(model.items, json.string)),
  ])
  |> json.to_string
}

/// The 200 short items of the runtime scenario.
fn runtime_scenario_items() -> List(String) {
  int.range(from: runtime_items, to: 0, with: [], run: fn(acc, i) {
    ["item-number-" <> int.to_string(i), ..acc]
  })
}

/// `count` items of exactly `list_item_bytes` bytes each.
fn list_items(count: Int) -> List(String) {
  int.range(from: count, to: 0, with: [], run: fn(acc, i) {
    [string.pad_start(int.to_string(i), list_item_bytes, "x"), ..acc]
  })
}

type Runtime {
  Runtime(
    subject: process.Subject(runtime.RuntimeMessage(BenchMsg)),
    selector: process.Selector(transport.InternalMessage),
  )
}

fn runtime_scenario() -> Result(List(Metric), String) {
  list.try_map([#("changed", "bump"), #("unchanged", "nothing")], fn(kind) {
    let #(name, handler_id) = kind
    {
      runtime_rounds(
        "runtime." <> name,
        runtime_scenario_items(),
        handler_id,
        runtime_events,
        runtime_events,
      )
    }
    |> result.map_error(fn(reason) { "runtime." <> name <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

/// The changed-event rounds against the large list models. The model is
/// checked to encode to at least its nominal size, so the metric's name
/// stays true.
fn runtime_list_scenario() -> Result(List(Metric), String) {
  list.try_map(list_models, fn(shape) {
    let #(name, count, events, sequential_events) = shape
    let items = list_items(count)
    let bytes =
      string.byte_size(encode_bench_model(BenchModel(count: 0, items: items)))
    {
      use <- check(
        bytes >= count * { list_item_bytes + 2 },
        "the model encodes to only " <> int.to_string(bytes) <> " bytes",
      )
      runtime_rounds(
        "runtime." <> name <> ".changed",
        items,
        "bump",
        events,
        sequential_events,
      )
    }
    |> result.map_error(fn(reason) { "runtime." <> name <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

/// Warm-up and measured pipelined rounds of `events` events, then
/// `sequential_events` sequential ones, on a fresh runtime holding `items`.
fn runtime_rounds(
  prefix: String,
  items: List(String),
  handler_id: String,
  events: Int,
  sequential_events: Int,
) -> Result(List(Metric), String) {
  use rt <- result.try(start_runtime(items))
  let outcome = {
    // Clocks run on across rounds; every round starts after the last
    // acknowledgement of the one before.
    use #(clock, _) <- result.try(
      repeat_from(runtime_warmup_rounds, 0, fn(clock) {
        pipelined(rt, handler_id, clock, events)
      }),
    )
    use #(clock, per_event) <- result.try(
      repeat_from(rounds, clock, fn(clock) {
        gc()
        pipelined(rt, handler_id, clock, events)
      }),
    )
    use latencies <- result.try(sequential(
      rt,
      handler_id,
      clock,
      sequential_events,
    ))
    use cost <- result.try(
      stats.median(per_event) |> result.replace_error("no rounds"),
    )
    use #(p50, p99) <- result.try(percentiles_by_round(prefix, latencies))
    Ok([
      Metric(prefix <> ".pipelined", "us/event", LowerIsBetter, cost),
      Metric(prefix <> ".latency_p50", "us", LowerIsBetter, p50),
      Metric(prefix <> ".latency_p99", "us", LowerIsBetter, p99),
    ])
  }
  process.send(rt.subject, runtime.Shutdown)
  outcome
}

fn start_runtime(items: List(String)) -> Result(Runtime, String) {
  use subject <- result.try(
    runtime.start(runtime_config(items), test_ctx.root())
    |> result.map_error(fn(e) { "start: " <> string_of(e) }),
  )
  let transport_subject = process.new_subject()
  let selector = process.new_selector() |> process.select(transport_subject)
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "bench", subject: transport_subject),
  )
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "bench", token: "", path: "/"),
  )
  let rt = Runtime(subject: subject, selector: selector)
  // The join answers with a model_sync acknowledging clock 0.
  use Nil <- result.try(await_ack(rt, 0))
  Ok(rt)
}

/// Send `events` events without waiting, then wait for the last one's
/// acknowledgement. Returns the last clock and microseconds per event.
fn pipelined(
  rt: Runtime,
  handler_id: String,
  after: Int,
  events: Int,
) -> Result(#(Int, Float), String) {
  let last = after + events
  let start = now_ns()
  int.range(from: after + 1, to: last + 1, with: Nil, run: fn(_, clock) {
    send_event(rt, handler_id, clock)
  })
  use Nil <- result.try(await_ack(rt, last))
  let elapsed_us = int.to_float(now_ns() - start) /. 1000.0
  Ok(#(last, elapsed_us /. int.to_float(events)))
}

/// Send `events` events one at a time, timing each from its send to its
/// acknowledgement (microseconds).
fn sequential(
  rt: Runtime,
  handler_id: String,
  after: Int,
  events: Int,
) -> Result(List(Float), String) {
  int.range(
    from: after + 1,
    to: after + events + 1,
    with: Ok([]),
    run: fn(acc, clock) {
      use latencies <- result.try(acc)
      let start = now_ns()
      send_event(rt, handler_id, clock)
      use Nil <- result.try(await_ack(rt, clock))
      Ok([int.to_float(now_ns() - start) /. 1000.0, ..latencies])
    },
  )
}

fn send_event(rt: Runtime, handler_id: String, clock: Int) -> Nil {
  process.send(
    rt.subject,
    runtime.ClientEventReceived(
      conn_id: "bench",
      event_name: "click",
      handler_id: handler_id,
      event_data: "{}",
      target_path: "0",
      clock: clock,
      ops: [],
    ),
  )
}

/// Wait for the acknowledgement of `clock`. Every event is acknowledged
/// (by a patch, or an empty patch when the model did not change), so the
/// acknowledgements arrive in clock order; a later one, or none in time,
/// is an error.
fn await_ack(rt: Runtime, clock: Int) -> Result(Nil, String) {
  case process.selector_receive(rt.selector, timeout_ms) {
    Ok(transport.SendPatch(ack_clock: ack, ..))
    | Ok(transport.SendModelSync(ack_clock: ack, ..)) ->
      case int.compare(ack, clock) {
        order.Eq -> Ok(Nil)
        order.Lt -> await_ack(rt, clock)
        order.Gt ->
          Error(
            "acknowledged clock "
            <> int.to_string(ack)
            <> " while waiting for "
            <> int.to_string(clock),
          )
      }
    Ok(_) -> await_ack(rt, clock)
    Error(Nil) ->
      Error(
        "no acknowledgement of clock " <> int.to_string(clock) <> " in time",
      )
  }
}

// --- wire ---

/// Encode a one-op patch and a model_sync of the 50 KB list model into the
/// frame the transport hands the socket, in blocks of `wire_block`.
/// Nanoseconds per frame, median and p99 over the blocks.
fn wire_scenario() -> Result(List(Metric), String) {
  let model_json =
    encode_bench_model(BenchModel(count: 0, items: list_items(1000)))
  let ops_json = "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":12345}]"
  let messages = [
    #(
      "wire.patch",
      transport.ServerPatch(
        ops_json: ops_json,
        version: 12_345,
        ack_clock: 12_345,
        streams_json: "[]",
      ),
      string.byte_size(ops_json),
    ),
    #(
      "wire.model_sync_50kb",
      transport.ServerModelSync(
        model_json: model_json,
        version: 12_345,
        ack_clock: 12_345,
        streams_json: "[]",
      ),
      string.byte_size(model_json),
    ),
  ]
  list.try_map(messages, fn(entry) {
    let #(name, msg, payload_bytes) = entry
    let block = fn() { wire_block_round(msg, payload_bytes) }
    {
      use _ <- result.try(repeat(wire_warmup_blocks, block))
      gc()
      use per_frame <- result.try(repeat(wire_blocks, block))
      median_and_p99(name, "ns/frame", per_frame)
    }
    |> result.map_error(fn(reason) { name <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

/// Encode `msg` into a frame `wire_block` times; nanoseconds per frame,
/// after checking every frame holds at least the payload and a header.
fn wire_block_round(
  msg: transport.ServerMessage,
  payload_bytes: Int,
) -> Result(Float, String) {
  let t0 = now_ns()
  let short =
    int.range(from: 0, to: wire_block, with: 0, run: fn(short, _) {
      case wire_frame_bytes(msg) >= payload_bytes + 2 {
        True -> short
        False -> short + 1
      }
    })
  let t1 = now_ns()
  use <- check(
    short == 0,
    int.to_string(short) <> " frames are shorter than their payload",
  )
  Ok(int.to_float(t1 - t0) /. int.to_float(wire_block))
}

/// The size of the frame the transport writes for `msg`: the iodata frame
/// `send_ws_message` hands `gen_tcp:send/2`, measured with `iolist_size`.
fn wire_frame_bytes(msg: transport.ServerMessage) -> Int {
  bytes_tree.byte_size(
    ws.encode_text_tree(transport.encode_server_message_tree(msg)),
  )
}

// --- pubsub ---

fn pubsub_scenario() -> Result(List(Metric), String) {
  list.try_map(pubsub_fanouts, fn(fanout) {
    let #(subscribers, pubsub_broadcasts) = fanout
    let name = "pubsub.fanout." <> int.to_string(subscribers)
    let topic = "bench:fanout:" <> int.to_string(subscribers)
    {
      gc()
      use latencies_ns <- result.try(pubsub_fanout(
        topic,
        subscribers,
        pubsub_warmup_broadcasts,
        pubsub_broadcasts,
        timeout_ms,
      ))
      use <- check(
        list.length(latencies_ns) == pubsub_broadcasts,
        "expected "
          <> int.to_string(pubsub_broadcasts)
          <> " samples, got "
          <> int.to_string(list.length(latencies_ns)),
      )
      use #(p50, p99) <- result.try(percentiles_by_round(
        name,
        list.map(latencies_ns, fn(ns) { int.to_float(ns) /. 1000.0 }),
      ))
      Ok([
        Metric(name <> ".p50", "us", LowerIsBetter, p50),
        Metric(name <> ".p99", "us", LowerIsBetter, p99),
      ])
    }
    |> result.map_error(fn(reason) { name <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

// --- store ---

fn store_scenario() -> Result(List(Metric), String) {
  let bench_store: store.Store(Int) = store.new("brazier_bench")
  let keys =
    int.range(from: store_block, to: 0, with: [], run: fn(acc, i) {
      ["key-" <> int.to_string(i), ..acc]
    })
  use _ <- result.try(
    repeat(store_warmup_blocks, fn() { store_block_round(bench_store, keys) }),
  )
  gc()
  use blocks <- result.try(
    repeat(store_blocks, fn() { store_block_round(bench_store, keys) }),
  )
  list.try_map(
    [
      #("put", list.map(blocks, fn(b) { b.0 })),
      #("get", list.map(blocks, fn(b) { b.1 })),
      #("delete", list.map(blocks, fn(b) { b.2 })),
    ],
    fn(op) {
      let #(name, per_op) = op
      median_and_p99("store." <> name, "ns/op", per_op)
    },
  )
  |> result.map(list.flatten)
  |> result.map_error(fn(reason) { "store: " <> reason })
}

/// Put, get and delete every key once; nanoseconds per operation of each,
/// after checking that every get read back its value and the deletes
/// emptied the store.
fn store_block_round(
  bench_store: store.Store(Int),
  keys: List(String),
) -> Result(#(Float, Float, Float), String) {
  let t0 = now_ns()
  list.each(keys, fn(key) { store.put(bench_store, key, 1) })
  let t1 = now_ns()
  let found =
    list.fold(keys, 0, fn(found, key) {
      case store.get(bench_store, key) {
        Ok(1) -> found + 1
        _ -> found
      }
    })
  let t2 = now_ns()
  list.each(keys, fn(key) { store.delete(bench_store, key) })
  let t3 = now_ns()
  use <- check(
    found == store_block,
    "read back " <> int.to_string(found) <> " of " <> int.to_string(store_block),
  )
  use <- check(store.count(bench_store) == 0, "the deletes left entries behind")
  let per_op = fn(ns) { int.to_float(ns) /. int.to_float(store_block) }
  Ok(#(per_op(t1 - t0), per_op(t2 - t1), per_op(t3 - t2)))
}

// --- crdt append ---

const crdt_append_sizes = [10, 1000, 10_000]

const crdt_append_warmup_blocks = 5

/// The p99 of 50 blocks was the worst block but one, which a single
/// scheduling hiccup moved by 60%; at 500 it is the fifth worst.
const crdt_append_blocks = 500

fn crdt_append_scenario() -> Result(List(Metric), String) {
  let replica = crdt.Replica(node: "bench@host", incarnation: 1)
  list.try_map(crdt_append_sizes, fn(values) {
    let name = "store.crdt_append." <> int.to_string(values)
    let items =
      int.range(from: values - 1, to: -1, with: [], run: fn(items, i) {
        [
          #(i, hlc.Timestamp(wall_ms: i, logical: 0, node: replica.node)),
          ..items
        ]
      })
    let #(base, _, _) = crdt.append(crdt.new(), replica, "room", items, [])
    let block = fn() { crdt_append_block(base, replica, values) }
    use _ <- result.try(repeat(crdt_append_warmup_blocks, block))
    gc()
    use per_op <- result.try(repeat(crdt_append_blocks, block))
    median_and_p99(name, "ns/op", per_op)
  })
  |> result.map(list.flatten)
  |> result.map_error(fn(reason) { "crdt append: " <> reason })
}

/// Append one value to `base` (a key of `values` values) `store_block`
/// times; nanoseconds per append, after checking every append kept the
/// values and added one.
fn crdt_append_block(
  base: crdt.State(Int),
  replica: crdt.Replica,
  values: Int,
) -> Result(Float, String) {
  let at = hlc.Timestamp(wall_ms: values, logical: 0, node: replica.node)
  let t0 = now_ns()
  let grown =
    int.range(from: 0, to: store_block, with: 0, run: fn(grown, i) {
      let #(next, _, _) = crdt.append(base, replica, "room", [#(-i, at)], [])
      case crdt.size(next) == values + 1 {
        True -> grown + 1
        False -> grown
      }
    })
  let t1 = now_ns()
  use <- check(
    grown == store_block,
    int.to_string(store_block - grown)
      <> " appends to "
      <> int.to_string(values)
      <> " values did not leave "
      <> int.to_string(values + 1),
  )
  Ok(int.to_float(t1 - t0) /. int.to_float(store_block))
}

// --- helpers ---

/// Rendered for reports: `name = value unit`.
pub fn describe(metric: Metric) -> String {
  metric.name <> " = " <> report.number(metric.value) <> " " <> metric.unit
}
