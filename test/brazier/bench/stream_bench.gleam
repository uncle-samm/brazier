//// The server stream scenarios of the benchmark suite
//// (docs/design/STREAMS.md 16), on a `KeepLast(300)` stream of 1 KB
//// lines:
////
//// - runtime.stream.append: events pushed straight into a runtime actor
////   whose stream is full; each event appends one line, so the frame
////   carries one insert and the trim of the first line.
//// - runtime.stream.chunk: each event re-inserts the last line with 100
////   more bytes of text (back to 1 KB every 10 events, so it stays far
////   under the 64 KB item bound): one update in place, no delete.
////
//// Both report the pipelined cost per event and the p50/p99 of one event
//// at a time, as the runtime scenarios of brazier/bench/suite do. Every
//// event must be acknowledged by its own patch, in clock order, and every
//// patch's `streams` field is decoded and checked against the change the
//// event makes once the round's timer has stopped, so the checking is not
//// timed. The join's model_sync must carry the 300 lines `init` inserted.
////
//// `wire_stream_patch` is the message of wire.stream_patch, which the
//// suite's wire scenario times; `log`, `line` and `render_line` are the
//// stream and item of ssr.stream_300 in brazier/bench/http_bench.

import brazier/attribute
import brazier/bench/measure.{
  check, gc, now_ns, percentiles_by_round, repeat_from, rounds, string_of,
  timeout_ms,
}
import brazier/bench/report.{type Metric, LowerIsBetter, Metric}
import brazier/bench/stats
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/error
import brazier/event
import brazier/html
import brazier/internal/stream_window
import brazier/runtime
import brazier/stream.{type Stream}
import brazier/test_ctx
import brazier/transport
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// The stream's name, as the runtime's `StreamConfig` declares it.
pub const stream_name = "bench_log"

/// The stream's limit, and the number of lines `init` inserts: the stream
/// is full from the join on.
pub const stream_limit = 300

/// The text of a line, in bytes, before it grows. A line's JSON is this
/// plus its id and the field names.
pub const line_bytes = 1024

/// The bytes the chunk event adds to the last line's text.
const chunk_step_bytes = 100

/// The chunk events after which the last line is back to `line_bytes`.
const chunk_cycle = 10

/// Events per pipelined round, and the sequential events whose p50/p99
/// are reported (a multiple of `rounds`).
const pipelined_events = 1000

const sequential_events = 1000

const warmup_rounds = 1

/// One line of the stream.
pub type Line {
  Line(id: String, text: String)
}

type Model {
  Model(appended: Int, chunks: Int)
}

type Msg {
  AppendLine
  GrowChunk
}

/// The bench stream: `stream_limit` lines, the last kept.
pub fn log() -> Stream(Line) {
  stream.new(
    stream_name,
    key: fn(line: Line) { line.id },
    encode: encode_line,
    decoder: line_decoder(),
    limit: stream.KeepLast(stream_limit),
  )
}

fn encode_line(line: Line) -> json.Json {
  json.object([#("id", json.string(line.id)), #("text", json.string(line.text))])
}

fn line_decoder() -> decode.Decoder(Line) {
  use id <- decode.field("id", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(Line(id:, text:))
}

/// Line `n` (key `k<n>`) with `bytes` bytes of text. The text holds
/// characters the render escapes, so the escaping is part of the work.
pub fn line(n: Int, bytes: Int) -> Line {
  let id = "k" <> int.to_string(n)
  Line(id:, text: string.pad_end("line " <> id <> " <&> ", bytes, "x"))
}

/// Lines 1 to `stream_limit`, each of `line_bytes`.
pub fn initial_lines() -> List(Line) {
  int.range(from: stream_limit, to: 0, with: [], run: fn(acc, n) {
    [line(n, line_bytes), ..acc]
  })
}

/// One line: its id, its text and a button with a click handler, as a
/// log or chat line has.
pub fn render_line(line: Line, on_pick: fn(String) -> msg) -> Element(msg) {
  html.li([attribute.class("line")], [
    html.span([attribute.class("id")], [html.text(line.id)]),
    html.span([attribute.class("text")], [html.text(line.text)]),
    html.button([event.on_click(on_pick(line.id))], [html.text("Pick")]),
  ])
}

/// The text size of the last line after chunk event `chunk`.
fn chunk_bytes(chunk: Int) -> Int {
  line_bytes + chunk_step_bytes * { chunk % chunk_cycle }
}

fn runtime_config() -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) {
      Ok(#(
        Model(appended: stream_limit, chunks: 0),
        stream.insert_many(log(), initial_lines(), at: stream.Append),
      ))
    },
    update: update,
    decode_event: fn(_name, handler_id, _data, _path) {
      case handler_id {
        "append" -> Ok(AppendLine)
        "chunk" -> Ok(GrowChunk)
        _ -> Error(error.RuntimeError(reason: "unknown handler " <> handler_id))
      }
    },
    encode_model: fn(model: Model) {
      json.object([
        #("appended", json.int(model.appended)),
        #("chunks", json.int(model.chunks)),
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
    streams: runtime.StreamConfig(
      names: [stream_name],
      limits: stream_window.default_limits(),
    ),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    AppendLine -> {
      let appended = model.appended + 1
      #(
        Model(..model, appended:),
        stream.insert(log(), line(appended, line_bytes), at: stream.Append),
      )
    }
    GrowChunk -> {
      let chunks = model.chunks + 1
      #(
        Model(..model, chunks:),
        stream.insert(
          log(),
          line(stream_limit, chunk_bytes(chunks)),
          at: stream.Append,
        ),
      )
    }
  }
}

/// The change one event must make: the keys deleted and the inserts, each
/// #(key, index, text bytes).
type Expected {
  Expected(deletes: List(String), inserts: List(#(String, Int, Int)))
}

/// Event `clock` of a fresh runtime that only appends: the clock-th append
/// adds line `stream_limit + clock` at the end and trims line `clock`.
fn expect_append(clock: Int) -> Expected {
  Expected(deletes: ["k" <> int.to_string(clock)], inserts: [
    #("k" <> int.to_string(stream_limit + clock), stream_limit - 1, line_bytes),
  ])
}

/// Event `clock` of a fresh runtime that only grows the last line.
fn expect_chunk(clock: Int) -> Expected {
  Expected(deletes: [], inserts: [
    #("k" <> int.to_string(stream_limit), stream_limit - 1, chunk_bytes(clock)),
  ])
}

/// Run the runtime stream scenarios.
pub fn run() -> Result(List(Metric), String) {
  list.try_map([#("append", expect_append), #("chunk", expect_chunk)], fn(kind) {
    let #(handler_id, expect) = kind
    let prefix = "runtime.stream." <> handler_id
    stream_rounds(prefix, handler_id, expect)
    |> result.map_error(fn(reason) { prefix <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

type Runtime {
  Runtime(
    subject: process.Subject(runtime.RuntimeMessage(Msg)),
    selector: process.Selector(transport.InternalMessage),
  )
}

fn stream_rounds(
  prefix: String,
  handler_id: String,
  expect: fn(Int) -> Expected,
) -> Result(List(Metric), String) {
  use rt <- result.try(start_runtime())
  let outcome = {
    use #(clock, _) <- result.try(
      repeat_from(warmup_rounds, 0, fn(clock) {
        pipelined(rt, handler_id, clock, expect)
      }),
    )
    use #(clock, per_event) <- result.try(
      repeat_from(rounds, clock, fn(clock) {
        gc()
        pipelined(rt, handler_id, clock, expect)
      }),
    )
    use latencies <- result.try(sequential(rt, handler_id, clock, expect))
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

/// Start the runtime, join it, and check the join's model_sync carries the
/// lines `init` inserted, in order.
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
  let rt = Runtime(subject:, selector:)
  case process.selector_receive(selector, timeout_ms) {
    Ok(transport.SendModelSync(ack_clock: 0, streams_json: streams_json, ..)) -> {
      use entries <- result.try(decode_frame(streams_json))
      let expected =
        list.index_map(initial_lines(), fn(line, index) {
          #(line.id, index, line_bytes)
        })
      case entries {
        [Entry(name:, deletes: [], inserts:, ..)]
          if name == stream_name && inserts == expected
        -> Ok(rt)
        _ ->
          Error(
            "the join's streams do not hold the "
            <> int.to_string(stream_limit)
            <> " initial lines: "
            <> string.slice(streams_json, 0, 300),
          )
      }
    }
    Ok(other) ->
      Error("the join answered with " <> string.slice(string_of(other), 0, 300))
    Error(Nil) -> Error("the join was not answered in time")
  }
}

/// Send `events` events without waiting, then receive their patches. The
/// timer stops at the last patch; the patches are checked after it.
/// Returns the last clock and microseconds per event.
fn pipelined(
  rt: Runtime,
  handler_id: String,
  after: Int,
  expect: fn(Int) -> Expected,
) -> Result(#(Int, Float), String) {
  let last = after + pipelined_events
  let start = now_ns()
  int.range(from: after + 1, to: last + 1, with: Nil, run: fn(_, clock) {
    send_event(rt, handler_id, clock)
  })
  use frames <- result.try(receive_patches(rt, after + 1, last, []))
  let elapsed_us = int.to_float(now_ns() - start) /. 1000.0
  use Nil <- result.try(check_frames(frames, expect))
  Ok(#(last, elapsed_us /. int.to_float(pipelined_events)))
}

/// Send `sequential_events` events one at a time, timing each from its
/// send to its patch (microseconds). Each patch is checked after its
/// event's timer stops.
fn sequential(
  rt: Runtime,
  handler_id: String,
  after: Int,
  expect: fn(Int) -> Expected,
) -> Result(List(Float), String) {
  int.range(
    from: after + 1,
    to: after + sequential_events + 1,
    with: Ok([]),
    run: fn(acc, clock) {
      use latencies <- result.try(acc)
      let start = now_ns()
      send_event(rt, handler_id, clock)
      use frames <- result.try(receive_patches(rt, clock, clock, []))
      let latency = int.to_float(now_ns() - start) /. 1000.0
      use Nil <- result.try(check_frames(frames, expect))
      Ok([latency, ..latencies])
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

/// Receive the patches acknowledging clocks `next` to `last`, one each, in
/// order: #(clock, streams_json), first clock first. Any other message, a
/// patch out of order, or none in time is an error.
fn receive_patches(
  rt: Runtime,
  next: Int,
  last: Int,
  received: List(#(Int, String)),
) -> Result(List(#(Int, String)), String) {
  case process.selector_receive(rt.selector, timeout_ms) {
    Ok(transport.SendPatch(ack_clock: ack, streams_json: streams_json, ..))
      if ack == next
    -> {
      let received = [#(ack, streams_json), ..received]
      case ack == last {
        True -> Ok(list.reverse(received))
        False -> receive_patches(rt, next + 1, last, received)
      }
    }
    Ok(transport.SendPatch(ack_clock: ack, ..)) ->
      Error(
        "a patch acknowledged clock "
        <> int.to_string(ack)
        <> " while clock "
        <> int.to_string(next)
        <> " was expected",
      )
    Ok(other) ->
      Error(
        "expected the patch of clock "
        <> int.to_string(next)
        <> ", got "
        <> string.slice(string_of(other), 0, 300),
      )
    Error(Nil) ->
      Error("no patch acknowledged clock " <> int.to_string(next) <> " in time")
  }
}

/// One wire entry, with each insert as #(key, at, text bytes).
type Entry {
  Entry(
    name: String,
    reset: Bool,
    deletes: List(String),
    inserts: List(#(String, Int, Int)),
  )
}

fn decode_frame(streams_json: String) -> Result(List(Entry), String) {
  let insert = {
    use key <- decode.field("key", decode.string)
    use at <- decode.field("at", decode.int)
    use text <- decode.subfield(["item", "text"], decode.string)
    decode.success(#(key, at, string.byte_size(text)))
  }
  let entry = {
    use name <- decode.field("name", decode.string)
    use reset <- decode.field("reset", decode.bool)
    use deletes <- decode.field("deletes", decode.list(decode.string))
    use inserts <- decode.field("inserts", decode.list(insert))
    decode.success(Entry(name:, reset:, deletes:, inserts:))
  }
  json.parse(streams_json, decode.list(entry))
  |> result.map_error(fn(e) {
    "a frame's streams do not decode ("
    <> string_of(e)
    <> "): "
    <> string.slice(streams_json, 0, 300)
  })
}

/// Every frame must carry exactly the change its event makes.
fn check_frames(
  frames: List(#(Int, String)),
  expect: fn(Int) -> Expected,
) -> Result(Nil, String) {
  list.try_each(frames, fn(frame) {
    let #(clock, streams_json) = frame
    use entries <- result.try(decode_frame(streams_json))
    let Expected(deletes:, inserts:) = expect(clock)
    use <- check(
      entries == [Entry(name: stream_name, reset: False, deletes:, inserts:)],
      "the patch of clock "
        <> int.to_string(clock)
        <> " carries "
        <> string.slice(streams_json, 0, 300)
        <> ", expected deletes "
        <> string_of(deletes)
        <> " and inserts "
        <> string_of(inserts),
    )
    Ok(Nil)
  })
}

/// wire.stream_patch: a patch of one model op whose `streams` field holds
/// one 1 KB insert at the end of the full stream, encoded by the runtime's
/// own encoder. Returns the message and the bytes of its payload.
pub fn wire_stream_patch() -> #(transport.ServerMessage, Int) {
  let ops_json = "[{\"op\":\"replace\",\"path\":\"/appended\",\"value\":12345}]"
  let item = line(12_345, line_bytes)
  let streams_json =
    stream_window.encode_deltas([
      stream_window.Delta(
        name: stream_name,
        limit: stream.to_op_limit(stream.KeepLast(stream_limit)),
        reset: False,
        deletes: ["k12045"],
        inserts: [
          stream_window.DeltaInsert(
            key: item.id,
            at: stream_limit - 1,
            json: json.to_string(encode_line(item)),
          ),
        ],
      ),
    ])
  // INVARIANT: the item is 1 KB of text, so the entry is at least that.
  let assert True = string.byte_size(streams_json) > line_bytes
    as "the wire.stream_patch entry holds its 1 KB item"
  #(
    transport.ServerPatch(
      ops_json: ops_json,
      version: 12_345,
      ack_clock: 12_345,
      streams_json: streams_json,
    ),
    string.byte_size(ops_json) + string.byte_size(streams_json),
  )
}
