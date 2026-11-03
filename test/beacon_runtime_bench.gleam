//// Runtime per-update benchmark.
////
//// Run with: `gleam run -m beacon_runtime_bench`
////
//// Measures the wall-clock cost of pushing client events through a live
//// runtime actor and receiving the resulting wire message. Two scenarios:
////
//// - `changed`: every event changes one field of a ~200-item model, so the
////   runtime must serialize, diff and broadcast a patch.
//// - `unchanged`: events leave the model untouched, so the runtime should
////   do as little work as possible. One changing event is sent at the end of
////   each batch so the benchmark can synchronise on its patch.
////
//// This module is not a test (no `_test` suffix) so gleeunit never runs it.

import beacon/effect
import beacon/error
import beacon/runtime
import beacon/test_ctx
import beacon/transport
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/option

type BenchModel {
  BenchModel(count: Int, items: List(String))
}

type BenchMsg {
  Bump
  Nothing
}

@external(erlang, "beacon_runtime_test_ffi", "now_us")
fn now_us() -> Int

const item_count = 200

const iterations = 2000

fn bench_config() -> runtime.RuntimeConfig(BenchModel, BenchMsg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) {
      #(
        BenchModel(
          count: 0,
          items: int.range(from: item_count, to: 0, with: [], run: fn(acc, i) {
            ["item-number-" <> int.to_string(i), ..acc]
          }),
        ),
        effect.none(),
      )
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
  )
}

fn send_event(
  rt: process.Subject(runtime.RuntimeMessage(BenchMsg)),
  handler_id: String,
  clock: Int,
) -> Nil {
  process.send(
    rt,
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

/// Block until a message acknowledging `clock` arrives. Panics on timeout so
/// a broken runtime cannot produce a misleadingly fast number.
fn await_ack(
  selector: process.Selector(transport.InternalMessage),
  clock: Int,
) -> Nil {
  case process.selector_receive(selector, 5000) {
    Ok(transport.SendPatch(ack_clock: ack, ..))
    | Ok(transport.SendModelSync(ack_clock: ack, ..)) ->
      case ack >= clock {
        True -> Nil
        False -> await_ack(selector, clock)
      }
    Ok(_) -> await_ack(selector, clock)
    Error(Nil) -> panic as "benchmark timed out waiting for runtime ack"
  }
}

fn run_scenario(name: String, handler_id: String) -> Nil {
  let assert Ok(rt) = runtime.start(bench_config(), test_ctx.root())
  let transport_subject = process.new_subject()
  let selector = process.new_selector() |> process.select(transport_subject)
  process.send(
    rt,
    runtime.ClientConnected(conn_id: "bench", subject: transport_subject),
  )
  process.send(rt, runtime.ClientJoined(conn_id: "bench", token: "", path: "/"))
  // The join sends a model_sync acknowledging clock 0.
  await_ack(selector, 0)

  let start = now_us()
  int.range(from: 1, to: iterations + 1, with: Nil, run: fn(_, clock) {
    send_event(rt, handler_id, clock)
  })
  // Final changing event so the unchanged scenario has a patch to wait on.
  send_event(rt, "bump", iterations + 1)
  await_ack(selector, iterations + 1)
  let elapsed = now_us() - start

  process.send(rt, runtime.Shutdown)
  io.println(
    name
    <> ": "
    <> int.to_string(iterations)
    <> " events in "
    <> int.to_string(elapsed / 1000)
    <> "ms ("
    <> int.to_string(elapsed / iterations)
    <> "us/event)",
  )
}

pub fn main() -> Nil {
  io.println(
    "beacon runtime bench: "
    <> int.to_string(item_count)
    <> "-item model, "
    <> int.to_string(iterations)
    <> " events per scenario",
  )
  // Warm-up run so code loading does not skew the first scenario.
  run_scenario("warmup", "bump")
  run_scenario("changed", "bump")
  run_scenario("unchanged", "nothing")
}
