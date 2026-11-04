//// The benchmark suite: one run measures every scenario and returns a
//// `report.Report`. Run it through `beacon_bench` (print),
//// `beacon_bench_check` (compare with bench/baselines.json) or
//// `beacon_bench_baseline` (re-baseline); see docs/PERFORMANCE.md.
////
//// Scenarios, each warmed up before it is measured:
////
//// - http: keep-alive clients against a listener answering `/bench`.
////   Requests per second (median of the rounds) and per-request latency
////   (p50/p99 over every request of every measured round).
//// - ws: N joined connections x M events each, every event timed from its
////   send to the patch acknowledging it. Events per second (median of the
////   rounds) and per-event latency p50/p99.
//// - runtime: events pushed straight into a runtime actor holding a
////   200-item model. Pipelined cost per event (median of the rounds) when
////   every event changes the model (patch) and when none does (empty
////   acknowledgement), and the p50/p99 of one event at a time.
//// - pubsub: one broadcast timed until every one of S subscribers has it.
//// - store: put/get/delete timed in blocks of 1000 operations.
////
//// Every generator checks every answer it times (beacon_bench_ffi): a
//// failure is an Error naming it, never a fast number. Logging is set to
//// warning once the app is up, so the numbers are the framework's, not the
//// console's. Nothing here is a test; gleam test never runs it.

import beacon/application
import beacon/bench/report.{type Metric, HigherIsBetter, LowerIsBetter, Metric}
import beacon/bench/stats
import beacon/effect
import beacon/error
import beacon/log
import beacon/runtime
import beacon/sim/test_app
import beacon/store
import beacon/test_ctx
import beacon/transport
import beacon/transport/server.{type Connection, Bytes}
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import logging

/// Every wait inside a round is bounded by this; a round that misses it
/// fails the run.
const timeout_ms = 30_000

const http_clients = 8

const http_requests = 2000

const http_warmup_rounds = 2

const ws_grid = [#(1, 200), #(10, 200), #(100, 200)]

const ws_warmup_rounds = 1

const runtime_items = 200

const runtime_events = 2000

const runtime_warmup_rounds = 1

const pubsub_subscribers = [1, 100, 1000]

/// Broadcasts to the same subscribers before the measured ones, so the
/// measured ones reach processes that have already run.
const pubsub_warmup_broadcasts = 100

const pubsub_broadcasts = 1000

const store_block = 1000

const store_warmup_blocks = 5

const store_blocks = 50

/// Measured rounds per throughput scenario.
const rounds = 5

@external(erlang, "beacon_bench_ffi", "now_ns")
fn now_ns() -> Int

@external(erlang, "beacon_bench_ffi", "machine")
fn machine() -> List(#(String, String))

@external(erlang, "beacon_bench_ffi", "gc")
fn gc() -> Nil

@external(erlang, "beacon_bench_ffi", "expect_empty_mailbox")
fn expect_empty_mailbox(scenario: String) -> Result(Nil, String)

@external(erlang, "beacon_bench_ffi", "http_round")
fn http_round(
  port: Int,
  clients: Int,
  requests: Int,
  timeout_ms: Int,
) -> Result(#(Int, List(Int)), String)

@external(erlang, "beacon_bench_ffi", "ws_round")
fn ws_round(
  host: String,
  port: Int,
  conns: Int,
  events: Int,
  timeout_ms: Int,
) -> Result(#(Int, List(Int)), String)

@external(erlang, "beacon_bench_ffi", "pubsub_fanout")
fn pubsub_fanout(
  topic: String,
  subscribers: Int,
  warmup: Int,
  broadcasts: Int,
  timeout_ms: Int,
) -> Result(List(Int), String)

/// Run every scenario once. Starts (and stops) its own app on an
/// OS-assigned port.
pub fn run() -> Result(report.Report, String) {
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
  let measured = {
    use http <- result.try(http_scenario())
    use Nil <- result.try(expect_empty_mailbox("http"))
    use ws <- result.try(ws_scenario(app.port))
    use Nil <- result.try(expect_empty_mailbox("ws"))
    use rt <- result.try(runtime_scenario())
    use Nil <- result.try(expect_empty_mailbox("runtime"))
    use ps <- result.try(pubsub_scenario())
    use Nil <- result.try(expect_empty_mailbox("pubsub"))
    use st <- result.try(store_scenario())
    use Nil <- result.try(expect_empty_mailbox("store"))
    Ok(list.flatten([http, ws, rt, ps, st]))
  }
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

// --- http ---

fn http_scenario() -> Result(List(Metric), String) {
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_id, _subject) { Nil },
      on_event: fn(_id, _msg) { Nil },
      on_disconnect: fn(_id) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: None,
      ws_auth: None,
      ssr_factory: None,
      security_limits: transport.SecurityLimits(
        ..transport.default_security_limits(),
        max_keepalive_requests: http_requests + 1,
      ),
      api_handler: Some(http_handler),
    )
  use listener <- result.try(
    transport.start_listener(config)
    |> result.map_error(fn(e) { "http listener: " <> string_of(e) }),
  )
  let port = server.get_port(listener)
  let outcome = {
    use _ <- result.try(
      repeat(http_warmup_rounds, fn() {
        http_round(port, http_clients, http_requests, timeout_ms)
      }),
    )
    use samples <- result.try(
      repeat(rounds, fn() {
        gc()
        http_round(port, http_clients, http_requests, timeout_ms)
      }),
    )
    let total = http_clients * http_requests
    throughput_and_latency(
      "http.keepalive." <> int.to_string(http_clients) <> "c",
      "req/s",
      total,
      samples,
    )
  }
  server.stop(listener)
  outcome
  |> result.map_error(fn(reason) { "http: " <> reason })
}

fn http_handler(
  req: Request(Connection),
) -> option.Option(response.Response(server.ResponseBody)) {
  case req.path {
    "/bench" ->
      Some(
        response.new(200)
        |> response.set_header("content-type", "text/plain")
        |> response.set_body(Bytes(bytes_tree.from_string("ok"))),
      )
    _ -> None
  }
}

// --- ws ---

fn ws_scenario(port: Int) -> Result(List(Metric), String) {
  list.try_map(ws_grid, fn(cell) {
    let #(conns, events) = cell
    let name = "ws." <> int.to_string(conns) <> "x" <> int.to_string(events)
    let round = fn() { ws_round("localhost", port, conns, events, timeout_ms) }
    {
      use _ <- result.try(repeat(ws_warmup_rounds, round))
      use samples <- result.try(
        repeat(rounds, fn() {
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

/// From rounds of #(elapsed_us, latencies_us): the median round's
/// throughput and the latency p50/p99 over every sample of every round.
fn throughput_and_latency(
  name: String,
  unit: String,
  per_round: Int,
  samples: List(#(Int, List(Int))),
) -> Result(List(Metric), String) {
  let rates =
    list.map(samples, fn(sample) {
      int.to_float(per_round) /. { int.to_float(sample.0) /. 1_000_000.0 }
    })
  let latencies = list.flat_map(samples, fn(sample) { sample.1 })
  use <- check(
    list.length(latencies) == per_round * list.length(samples),
    "expected "
      <> int.to_string(per_round * list.length(samples))
      <> " latencies, got "
      <> int.to_string(list.length(latencies)),
  )
  use rate <- result.try(
    stats.median(rates) |> result.replace_error("no rounds"),
  )
  use latency <- result.try(
    stats.summarize_ints(latencies) |> result.replace_error("no latencies"),
  )
  Ok([
    Metric(name <> ".throughput", unit, HigherIsBetter, rate),
    Metric(name <> ".latency_p50", "us", LowerIsBetter, latency.median),
    Metric(name <> ".latency_p99", "us", LowerIsBetter, latency.p99),
  ])
}

// --- runtime ---

type BenchModel {
  BenchModel(count: Int, items: List(String))
}

type BenchMsg {
  Bump
  Nothing
}

fn runtime_config() -> runtime.RuntimeConfig(BenchModel, BenchMsg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) {
      Ok(#(
        BenchModel(
          count: 0,
          items: int.range(
            from: runtime_items,
            to: 0,
            with: [],
            run: fn(acc, i) { ["item-number-" <> int.to_string(i), ..acc] },
          ),
        ),
        effect.none(),
      ))
    },
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
    encode_model: fn(model: BenchModel) {
      json.object([
        #("count", json.int(model.count)),
        #("items", json.array(model.items, json.string)),
      ])
      |> json.to_string
    },
    route: option.None,
    restore_model: option.None,
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    secret_key: "bench-secret-key-that-is-long-enough-for-hmac",
    presence: option.None,
    title: option.None,
  )
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
      use rt <- result.try(start_runtime())
      let outcome = {
        // Clocks run on across rounds; every round starts after the last
        // acknowledgement of the one before.
        use #(clock, _) <- result.try(
          repeat_from(runtime_warmup_rounds, 0, fn(clock) {
            pipelined(rt, handler_id, clock)
          }),
        )
        use #(clock, per_event) <- result.try(
          repeat_from(rounds, clock, fn(clock) {
            gc()
            pipelined(rt, handler_id, clock)
          }),
        )
        use latencies <- result.try(sequential(rt, handler_id, clock))
        use cost <- result.try(
          stats.median(per_event) |> result.replace_error("no rounds"),
        )
        use latency <- result.try(
          stats.summarize(latencies) |> result.replace_error("no latencies"),
        )
        let prefix = "runtime." <> name
        Ok([
          Metric(prefix <> ".pipelined", "us/event", LowerIsBetter, cost),
          Metric(prefix <> ".latency_p50", "us", LowerIsBetter, latency.median),
          Metric(prefix <> ".latency_p99", "us", LowerIsBetter, latency.p99),
        ])
      }
      process.send(rt.subject, runtime.Shutdown)
      outcome
    }
    |> result.map_error(fn(reason) { "runtime." <> name <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

fn start_runtime() -> Result(Runtime, String) {
  use subject <- result.try(
    runtime.start(runtime_config(), test_ctx.root())
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

/// Send `runtime_events` events without waiting, then wait for the last
/// one's acknowledgement. Returns the last clock and microseconds per event.
fn pipelined(
  rt: Runtime,
  handler_id: String,
  after: Int,
) -> Result(#(Int, Float), String) {
  let last = after + runtime_events
  let start = now_ns()
  int.range(from: after + 1, to: last + 1, with: Nil, run: fn(_, clock) {
    send_event(rt, handler_id, clock)
  })
  use Nil <- result.try(await_ack(rt, last))
  let elapsed_us = int.to_float(now_ns() - start) /. 1000.0
  Ok(#(last, elapsed_us /. int.to_float(runtime_events)))
}

/// Send `runtime_events` events one at a time, timing each from its send
/// to its acknowledgement (microseconds).
fn sequential(
  rt: Runtime,
  handler_id: String,
  after: Int,
) -> Result(List(Float), String) {
  int.range(
    from: after + 1,
    to: after + runtime_events + 1,
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
      ops: "",
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

// --- pubsub ---

fn pubsub_scenario() -> Result(List(Metric), String) {
  list.try_map(pubsub_subscribers, fn(subscribers) {
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
      use summary <- result.try(
        list.map(latencies_ns, fn(ns) { int.to_float(ns) /. 1000.0 })
        |> stats.summarize
        |> result.replace_error("no samples"),
      )
      Ok([
        Metric(name <> ".p50", "us", LowerIsBetter, summary.median),
        Metric(name <> ".p99", "us", LowerIsBetter, summary.p99),
      ])
    }
    |> result.map_error(fn(reason) { name <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

// --- store ---

fn store_scenario() -> Result(List(Metric), String) {
  let bench_store: store.Store(Int) = store.new("beacon_bench")
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
      use summary <- result.try(
        stats.summarize(per_op) |> result.replace_error(name <> ": no blocks"),
      )
      Ok([
        Metric(
          "store." <> name <> ".median",
          "ns/op",
          LowerIsBetter,
          summary.median,
        ),
        Metric("store." <> name <> ".p99", "ns/op", LowerIsBetter, summary.p99),
      ])
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

// --- helpers ---

/// Run `step` `times` times, stopping at the first error.
fn repeat(
  times: Int,
  step: fn() -> Result(a, String),
) -> Result(List(a), String) {
  int.range(from: 0, to: times, with: Ok([]), run: fn(acc, _) {
    use done <- result.try(acc)
    use value <- result.try(step())
    Ok([value, ..done])
  })
  |> result.map(list.reverse)
}

/// `repeat` for steps that thread a clock: each step gets the clock the
/// previous one returned. Returns the last clock and every step's value.
fn repeat_from(
  times: Int,
  clock: Int,
  step: fn(Int) -> Result(#(Int, a), String),
) -> Result(#(Int, List(a)), String) {
  int.range(from: 0, to: times, with: Ok(#(clock, [])), run: fn(acc, _) {
    use #(clock, done) <- result.try(acc)
    use #(next, value) <- result.try(step(clock))
    Ok(#(next, [value, ..done]))
  })
  |> result.map(fn(acc) { #(acc.0, list.reverse(acc.1)) })
}

fn check(
  condition: Bool,
  message: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(message)
  }
}

fn string_of(value: a) -> String {
  string.inspect(value)
}

/// Rendered for reports: `name = value unit`.
pub fn describe(metric: Metric) -> String {
  metric.name <> " = " <> report.number(metric.value) <> " " <> metric.unit
}
