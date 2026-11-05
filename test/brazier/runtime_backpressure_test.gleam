//// L453: the runtime tells a slow connection to close once and forgets it,
//// forgets a connection whose handler is gone instead of calling it slow,
//// and forgets a connection whose handler went down without a
//// `ClientDisconnected` (it monitors the owner of each connection's
//// subject, as `Phoenix.Channel.Server` monitors its transport pid). A
//// forgotten connection is dropped from the stream session too, so its
//// windows do not leak into a later connection under the same id.
////
//// Ported from docs/design/backpressure_cascade_repro.gleam.txt, which
//// reproduced the cascade: a dead pid answered `message_queue_len` with
//// 1000000000, so every broadcast called it slow, and a slow reader was
//// warned about and sent another close on every broadcast past the limit.
////
//// Synchronisation: `await.settle` (a barrier on the runtime, then the
//// mailbox) for what the runtime sent; for a DOWN, a trace of the runtime's
//// own mailbox (see brazier_runtime_backpressure_test_ffi.erl).

import brazier/await
import brazier/cluster/log_capture as node_log
import brazier/effect
import brazier/error
import brazier/internal/stream_window
import brazier/monitored
import brazier/runtime
import brazier/stream
import brazier/telemetry
import brazier/test_ctx
import brazier/transport.{type InternalMessage}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/string

// --- A connection whose handler is gone ----------------------------------------

/// A connection whose handler exited is not a slow client: it is forgotten
/// once, at info, and never sent a close.
pub fn dead_connection_is_forgotten_not_called_slow_test() {
  let rt = start(config())
  let fast = process.new_subject()
  let gone = subject_in_dead_process()
  let #(received, logs) =
    node_log.capture(fn() {
      connect(rt, "fast", fast)
      connect(rt, "gone", gone)
      let _ = await.settle(rt, fast)
      click(rt, "fast", 1)
      click(rt, "fast", 2)
      click(rt, "fast", 3)
      await.settle(rt, fast)
    })
  assert patches(received) == 3
  let slow_lines =
    lines_about(logs, "Connection gone outbound mailbox exceeded")
  assert slow_lines == [] as string.inspect(slow_lines)
  // Forgotten once, at info, naming the connection: by the join's send
  // finding the handler gone, or by the monitor's DOWN (noproc), whichever
  // the runtime handled first.
  let forgotten =
    list.filter(lines_about(logs, "gone"), fn(line) {
      string.contains(line.message, "forgetting it")
    })
  assert list.map(forgotten, fn(line) { line.level }) == ["info"]
    as string.inspect(forgotten)
  // The other one's DOWN was flushed by the forget, not discarded later.
  assert lines_about(logs, "Discarding a DOWN") == []
}

// --- A slow connection ---------------------------------------------------------

/// A slow connection is warned about and told to close once, then
/// forgotten: later broadcasts send it nothing.
pub fn slow_connection_is_closed_once_test() {
  let rt = start(config())
  let fast = process.new_subject()
  let #(slow, slow_pid) = subject_in_live_process()
  let #(received, logs) =
    node_log.capture(fn() {
      connect(rt, "fast", fast)
      connect(rt, "slow", slow)
      let _ = await.settle(rt, fast)
      fill(slow, 1001)
      click(rt, "fast", 1)
      click(rt, "fast", 2)
      click(rt, "fast", 3)
      await.settle(rt, fast)
    })
  // The healthy connection gets every patch.
  assert patches(received) == 3
  let warnings = lines_about(logs, "Connection slow outbound mailbox exceeded")
  assert list.map(warnings, fn(line) { line.level }) == ["warning"]
    as string.inspect(warnings)
  let assert [warning] = warnings
  assert string.contains(warning.message, "forgetting it")
  process.kill(slow_pid)
}

/// The slow reader's mailbox holds exactly one close, behind the backlog,
/// and nothing after it.
pub fn slow_connection_mailbox_ends_with_one_close_test() {
  let rt = start(config())
  let fast = process.new_subject()
  let slow = start_reader()
  connect(rt, "fast", fast)
  connect(rt, "slow", slow.subject)
  let _ = await.settle(rt, fast)
  let assert [transport.SendModelSync(..)] = read_all(slow, rt)
  fill(slow.subject, 1001)
  click(rt, "fast", 1)
  click(rt, "fast", 2)
  let _ = await.settle(rt, fast)
  let after_backlog = list.drop(read_all(slow, rt), 1001)
  let assert [transport.CloseForBackpressure(reason:)] = after_backlog
    as string.inspect(after_backlog)
  assert string.contains(reason, "too far behind")
  process.kill(slow.pid)
}

/// The transport's `ClientDisconnected` for a connection the runtime
/// already forgot is expected (the handler closes after the close frame):
/// logged at debug, not treated as unknown.
pub fn disconnect_after_a_backpressure_close_is_debug_test() {
  let rt = start(config())
  let fast = process.new_subject()
  let #(slow, slow_pid) = subject_in_live_process()
  connect(rt, "fast", fast)
  connect(rt, "slow", slow)
  let _ = await.settle(rt, fast)
  fill(slow, 1001)
  let #(_, logs) =
    node_log.capture(fn() {
      click(rt, "fast", 1)
      process.send(rt, runtime.ClientDisconnected(conn_id: "slow"))
      await.settle(rt, fast)
    })
  let disconnects = lines_about(logs, "Client disconnected: slow")
  assert list.map(disconnects, fn(line) { #(line.level, line.message) })
    == [
      #(
        "debug",
        "[brazier.runtime] Client disconnected: slow (already forgotten)",
      ),
    ]
    as string.inspect(disconnects)
  process.kill(slow_pid)
}

// --- A handler that went down --------------------------------------------------

/// A handler killed without a `ClientDisconnected` is forgotten when the
/// runtime handles its DOWN; the same id then registers as a new
/// connection, not a re-registration.
pub fn connection_whose_handler_went_down_is_forgotten_test() {
  let rt = start(config())
  let assert Ok(rt_pid) = process.subject_owner(rt)
  let fast = process.new_subject()
  let #(doomed, doomed_pid) = subject_in_live_process()
  connect(rt, "fast", fast)
  connect(rt, "doomed", doomed)
  let _ = await.settle(rt, fast)
  assert list.contains(monitored_pids(rt_pid), doomed_pid)
  let #(received, logs) =
    node_log.capture(fn() {
      let trace = trace_receive(rt_pid)
      process.kill(doomed_pid)
      let assert Ok(Nil) =
        await_down_received(rt_pid, doomed_pid, await.deadline_ms)
        as "the runtime must receive the DOWN of the killed handler"
      stop_trace(trace, rt_pid)
      click(rt, "fast", 1)
      let received = await.settle(rt, fast)
      // The id is free again: registering it is a new connection.
      let again = process.new_subject()
      connect(rt, "doomed", again)
      let _ = await.settle(rt, again)
      received
    })
  assert patches(received) == 1
  assert !list.contains(monitored_pids(rt_pid), doomed_pid)
  let doomed_lines = lines_about(logs, "doomed")
  let went_down =
    list.filter(doomed_lines, fn(line) {
      string.contains(line.message, "went down (killed); forgetting it")
    })
  assert list.map(went_down, fn(line) { line.level }) == ["info"]
    as string.inspect(doomed_lines)
  // Nothing was sent to it after the DOWN, and the new registration is not
  // a re-registration.
  assert !list.any(doomed_lines, fn(line) {
    string.contains(line.message, "is gone")
    || string.contains(line.message, "registered again")
  })
    as string.inspect(doomed_lines)
  assert list.any(doomed_lines, fn(line) {
    line.level == "info"
    && line.message == "[brazier.runtime] Client connected: doomed"
  })
    as string.inspect(doomed_lines)
}

/// A connection registered again under its id (a reconnect the transport
/// reports before the old handler's disconnect) is forgotten and its old
/// owner unmonitored: the old handler going down later is not taken for
/// the new connection.
pub fn old_owner_going_down_after_a_reregistration_is_ignored_test() {
  let rt = start(config())
  let assert Ok(rt_pid) = process.subject_owner(rt)
  let #(old, old_pid) = subject_in_live_process()
  let new = process.new_subject()
  connect(rt, "c", old)
  let #(received, logs) =
    node_log.capture(fn() {
      connect(rt, "c", new)
      let _ = await.settle(rt, new)
      // The old owner is no longer monitored, so its exit sends the
      // runtime no DOWN at all.
      assert !list.contains(monitored_pids(rt_pid), old_pid)
      assert list.contains(monitored_pids(rt_pid), process.self())
      process.kill(old_pid)
      await.expect_down(old_pid, "the old handler")
      click(rt, "c", 1)
      await.settle(rt, new)
    })
  let c_lines = lines_about(logs, "Connection c ")
  assert list.map(c_lines, fn(line) { line.level }) == ["warning"]
    as string.inspect(c_lines)
  let assert [registered_again] = c_lines
  assert string.contains(registered_again.message, "registered again")
  // The new connection gets its patch after the old owner's exit.
  let assert [transport.SendPatch(ack_clock: 1, ..)] = received
    as string.inspect(received)
}

// --- Telemetry of a forgotten connection ---------------------------------------

/// A slow connection emits one `[brazier, runtime, connection, forgotten]`
/// with reason `slow` and its mailbox length, however many broadcasts find
/// it after; the healthy connection emits none.
pub fn slow_connection_emits_one_forgotten_event_test() {
  let rt = start(config())
  let fast_id = unique("fast")
  let slow_id = unique("slow")
  let fast = process.new_subject()
  let #(slow, slow_pid) = subject_in_live_process()
  let events = {
    use events <- monitored.listening([forgotten_event])
    connect(rt, fast_id, fast)
    connect(rt, slow_id, slow)
    let _ = await.settle(rt, fast)
    fill(slow, 1001)
    click(rt, fast_id, 1)
    click(rt, fast_id, 2)
    click(rt, fast_id, 3)
    let received = await.settle(rt, fast)
    assert patches(received) == 3
    forgotten(events, [fast_id, slow_id])
  }
  let assert [Forgotten(reason: "slow", count: 1, queue_len:, connection_id:)] =
    events
    as string.inspect(events)
  assert connection_id == slow_id
  // The join's model sync is in its mailbox behind the 1001 queued frames.
  assert queue_len > 1001 as int.to_string(queue_len)
  stop(rt)
  process.kill(slow_pid)
}

/// A handler killed without a `ClientDisconnected` emits one event with
/// reason `down` when the runtime handles its DOWN.
pub fn killed_handler_emits_one_down_event_test() {
  let rt = start(config())
  let assert Ok(rt_pid) = process.subject_owner(rt)
  let fast_id = unique("fast")
  let doomed_id = unique("doomed")
  let fast = process.new_subject()
  let #(doomed, doomed_pid) = subject_in_live_process()
  connect(rt, fast_id, fast)
  connect(rt, doomed_id, doomed)
  let _ = await.settle(rt, fast)
  let events = {
    use events <- monitored.listening([forgotten_event])
    let trace = trace_receive(rt_pid)
    process.kill(doomed_pid)
    let assert Ok(Nil) =
      await_down_received(rt_pid, doomed_pid, await.deadline_ms)
      as "the runtime must receive the DOWN of the killed handler"
    stop_trace(trace, rt_pid)
    click(rt, fast_id, 1)
    let received = await.settle(rt, fast)
    assert patches(received) == 1
    forgotten(events, [fast_id, doomed_id])
  }
  assert events
    == [
      Forgotten(
        reason: "down",
        count: 1,
        queue_len: 0,
        connection_id: doomed_id,
      ),
    ]
    as string.inspect(events)
  stop(rt)
}

/// A handler that exited before it registered emits one event with reason
/// `down`, whether a send or the monitor's DOWN (noproc) found it first.
pub fn dead_handler_emits_one_down_event_test() {
  let rt = start(config())
  let fast_id = unique("fast")
  let gone_id = unique("gone")
  let fast = process.new_subject()
  let gone = subject_in_dead_process()
  let events = {
    use events <- monitored.listening([forgotten_event])
    connect(rt, fast_id, fast)
    connect(rt, gone_id, gone)
    let _ = await.settle(rt, fast)
    click(rt, fast_id, 1)
    click(rt, fast_id, 2)
    let received = await.settle(rt, fast)
    assert patches(received) == 2
    forgotten(events, [fast_id, gone_id])
  }
  assert events
    == [
      Forgotten(reason: "down", count: 1, queue_len: 0, connection_id: gone_id),
    ]
    as string.inspect(events)
  stop(rt)
}

/// A connection the transport reports disconnected, and one registered
/// again under its id, are forgotten because the runtime was told, so
/// neither emits the event.
pub fn told_forgets_emit_no_forgotten_event_test() {
  let rt = start(config())
  let left_id = unique("left")
  let again_id = unique("again")
  let left = process.new_subject()
  let old = process.new_subject()
  let new = process.new_subject()
  let events = {
    use events <- monitored.listening([forgotten_event])
    connect(rt, left_id, left)
    connect(rt, again_id, old)
    let _ = await.settle(rt, left)
    let _ = await.drain(old)
    process.send(rt, runtime.ClientDisconnected(conn_id: left_id))
    connect(rt, again_id, new)
    let assert [transport.SendModelSync(..)] = await.settle(rt, new)
    forgotten(events, [left_id, again_id])
  }
  assert events == [] as string.inspect(events)
  assert await.drain(left) == []
  assert await.drain(old) == []
  stop(rt)
}

// --- Stream windows of a forgotten connection ----------------------------------

/// A slow connection's stream windows are dropped when it is forgotten: the
/// same id joining again starts empty, without a "Rejoin" warning about
/// keys it held, and is sent its own indices.
pub fn forgotten_connection_drops_its_stream_windows_test() {
  let name = unique("log")
  let rt = start(stream_config(name))
  let fast = process.new_subject()
  let slow = start_reader()
  connect(rt, "fast", fast)
  connect(rt, "slow", slow.subject)
  let _ = await.settle(rt, fast)
  let assert [transport.SendModelSync(..)] = read_all(slow, rt)
  log_line(rt, "fast", "a", 1)
  let assert [transport.SendPatch(streams_json:, ..)] = await.settle(rt, fast)
  assert inserts(streams_json) == [#("a", 0)]
  let assert [transport.SendPatch(streams_json:, ..)] = read_all(slow, rt)
  assert inserts(streams_json) == [#("a", 0)]
  fill(slow.subject, 1001)
  let #(_, logs) =
    node_log.capture(fn() {
      // Sending "b" finds slow over the limit: it is closed and forgotten.
      log_line(rt, "fast", "b", 2)
      let _ = await.settle(rt, fast)
      process.send(rt, runtime.ClientDisconnected(conn_id: "slow"))
      let again = process.new_subject()
      connect(rt, "slow", again)
      let assert [transport.SendModelSync(streams_json: "[]", ..)] =
        await.settle(rt, again)
      log_line(rt, "fast", "c", 3)
      let assert [transport.SendPatch(streams_json:, ..)] =
        await.settle(rt, again)
      // Its window starts empty: "c" is its first item.
      assert inserts(streams_json) == [#("c", 0)]
      let assert [transport.SendPatch(streams_json:, ..)] = await.drain(fast)
      assert inserts(streams_json) == [#("c", 2)]
    })
  let rejoin =
    list.filter(logs, fn(line) {
      string.contains(line.message, "Rejoin from slow")
    })
  assert rejoin == [] as string.inspect(rejoin)
  assert list.any(logs, fn(line) {
    string.contains(line.message, "slow joins a live runtime")
  })
  process.kill(slow.pid)
}

// --- Helpers -------------------------------------------------------------------

const forgotten_event = ["brazier", "runtime", "connection", "forgotten"]

type Forgotten {
  Forgotten(reason: String, count: Int, queue_len: Int, connection_id: String)
}

/// The forgotten events received so far for any of `connection_ids`
/// (other tests' runtimes may emit their own), oldest first.
fn forgotten(
  events: Subject(telemetry.Event),
  connection_ids: List(String),
) -> List(Forgotten) {
  await.drain(events)
  |> list.map(fn(event) {
    assert event.name == forgotten_event
    let assert Ok(reason) = telemetry.string(event, "reason")
      as "a forgotten event carries its reason"
    let assert Ok(count) = telemetry.int(event, "count")
      as "a forgotten event carries count"
    let assert Ok(queue_len) = telemetry.int(event, "queue_len")
      as "a forgotten event carries queue_len"
    let assert Ok(connection_id) = telemetry.string(event, "connection_id")
      as "a forgotten event names its connection"
    Forgotten(reason:, count:, queue_len:, connection_id:)
  })
  |> list.filter(fn(event) {
    list.contains(connection_ids, event.connection_id)
  })
}

/// Shut the runtime down and return once it has exited.
fn stop(rt: Subject(runtime.RuntimeMessage(Msg))) -> Nil {
  let assert Ok(pid) = process.subject_owner(rt)
    as "the runtime's subject has an owner"
  process.send(rt, runtime.Shutdown)
  await.expect_down(pid, "the runtime after Shutdown")
}

fn patches(received: List(InternalMessage)) -> Int {
  list.count(received, fn(message) {
    case message {
      transport.SendPatch(..) -> True
      _ -> False
    }
  })
}

fn lines_about(
  logs: List(node_log.Line),
  fragment: String,
) -> List(node_log.Line) {
  list.filter(logs, fn(line) {
    string.starts_with(line.message, "[brazier.runtime]")
    && string.contains(line.message, fragment)
  })
}

/// The inserts of a frame's one entry, as `#(key, at)`.
fn inserts(frame: String) -> List(#(String, Int)) {
  let insert_decoder = {
    use key <- decode.field("key", decode.string)
    use at <- decode.field("at", decode.int)
    decode.success(#(key, at))
  }
  let entry_decoder = decode.at(["inserts"], decode.list(insert_decoder))
  let assert Ok([entry]) = json.parse(frame, decode.list(entry_decoder))
    as frame
  entry
}

pub type Model {
  Model(count: Int, log: String)
}

pub type Msg {
  Increment
  /// Inserts a line into the stream named by the model; the model is
  /// unchanged.
  LogLine(id: String)
}

pub type Line {
  Line(id: String)
}

fn log_stream(name: String) -> stream.Stream(Line) {
  stream.new(
    name,
    key: fn(line: Line) { line.id },
    encode: fn(line: Line) { json.object([#("id", json.string(line.id))]) },
    decoder: {
      use id <- decode.field("id", decode.string)
      decode.success(Line(id:))
    },
    limit: stream.KeepLast(3),
  )
}

fn config() -> runtime.RuntimeConfig(Model, Msg) {
  config_with(runtime.no_streams(), "")
}

fn stream_config(name: String) -> runtime.RuntimeConfig(Model, Msg) {
  config_with(
    runtime.StreamConfig(names: [name], limits: stream_window.default_limits()),
    name,
  )
}

fn config_with(
  streams: runtime.StreamConfig,
  name: String,
) -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(count: 0, log: name), effect.none())) },
    update: fn(model: Model, msg) {
      case msg {
        Increment -> #(Model(..model, count: model.count + 1), effect.none())
        LogLine(id) -> #(
          model,
          stream.insert(log_stream(model.log), Line(id:), at: stream.Append),
        )
      }
    },
    encode_model: fn(model: Model) {
      "{\"count\":" <> int.to_string(model.count) <> "}"
    },
    decode_event: fn(_name, handler_id, data, _path) {
      case handler_id {
        "increment" -> Ok(Increment)
        "log" -> Ok(LogLine(data))
        _ -> Error(error.RuntimeError(reason: "unknown handler " <> handler_id))
      }
    },
    restore_model: option.None,
    route: option.None,
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    secret_key: "",
    presence: option.None,
    title: option.None,
    streams: streams,
  )
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn unique(label: String) -> String {
  label
  <> "_"
  <> int.to_string(int.absolute_value(unique_integer() % 1_000_000))
}

fn start(
  config: runtime.RuntimeConfig(Model, Msg),
) -> Subject(runtime.RuntimeMessage(Msg)) {
  let assert Ok(rt) = runtime.start(config, test_ctx.root())
  rt
}

fn connect(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  subject: Subject(InternalMessage),
) -> Nil {
  process.send(rt, runtime.ClientConnected(conn_id: conn_id, subject: subject))
  process.send(rt, runtime.ClientJoined(conn_id: conn_id, token: "", path: "/"))
}

fn click(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  clock: Int,
) -> Nil {
  send_event(rt, conn_id, "increment", "{}", clock)
}

fn log_line(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  id: String,
  clock: Int,
) -> Nil {
  send_event(rt, conn_id, "log", id, clock)
}

fn send_event(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  handler_id: String,
  data: String,
  clock: Int,
) -> Nil {
  process.send(
    rt,
    runtime.ClientEventReceived(
      conn_id: conn_id,
      event_name: "click",
      handler_id: handler_id,
      event_data: data,
      target_path: "0",
      clock: clock,
      ops: [],
    ),
  )
}

/// A subject whose owner is alive and never reads it: a slow reader.
fn subject_in_live_process() -> #(Subject(InternalMessage), Pid) {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(reply, process.new_subject())
      process.receive_forever(process.new_subject())
    })
  let assert Ok(subject) = process.receive(reply, await.deadline_ms)
    as "the reader must hand over its subject"
  #(subject, pid)
}

/// A subject whose owner has exited: a handler that is gone.
fn subject_in_dead_process() -> Subject(InternalMessage) {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() { process.send(reply, process.new_subject()) })
  let assert Ok(subject) = process.receive(reply, await.deadline_ms)
    as "the handler must hand over its subject"
  await.expect_down(pid, "the handler")
  subject
}

/// A reader that reads its subject only when asked: a slow connection
/// whose mailbox a test can inspect.
type Reader {
  Reader(
    subject: Subject(InternalMessage),
    control: Subject(#(Pid, Subject(List(InternalMessage)))),
    pid: Pid,
  )
}

fn start_reader() -> Reader {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      let control = process.new_subject()
      process.send(reply, #(subject, control))
      reader_loop(subject, control)
    })
  let assert Ok(#(subject, control)) = process.receive(reply, await.deadline_ms)
    as "the reader must hand over its subjects"
  Reader(subject:, control:, pid:)
}

fn reader_loop(
  subject: Subject(InternalMessage),
  control: Subject(#(Pid, Subject(List(InternalMessage)))),
) -> Nil {
  let #(runtime_pid, reply_to) = process.receive_forever(control)
  // A barrier from the reader itself: what the runtime sent the reader
  // before answering it is in the reader's mailbox (one sender, in order).
  await.barrier_pid(runtime_pid)
  process.send(reply_to, await.drain(subject))
  reader_loop(subject, control)
}

/// Everything the runtime has sent `reader` so far, oldest first.
fn read_all(
  reader: Reader,
  rt: Subject(runtime.RuntimeMessage(Msg)),
) -> List(InternalMessage) {
  let assert Ok(runtime_pid) = process.subject_owner(rt)
  let reply = process.new_subject()
  process.send(reader.control, #(runtime_pid, reply))
  let assert Ok(messages) = process.receive(reply, await.deadline_ms)
    as "the reader must answer"
  messages
}

fn fill(subject: Subject(InternalMessage), remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      process.send(subject, transport.SendError(reason: "queued"))
      fill(subject, remaining - 1)
    }
  }
}

type TraceSession

@external(erlang, "brazier_runtime_backpressure_test_ffi", "trace_receive")
fn trace_receive(pid: Pid) -> TraceSession

@external(erlang, "brazier_runtime_backpressure_test_ffi", "await_down_received")
fn await_down_received(
  pid: Pid,
  target: Pid,
  timeout_ms: Int,
) -> Result(Nil, Nil)

/// The processes `pid` monitors.
@external(erlang, "brazier_runtime_backpressure_test_ffi", "monitored_pids")
fn monitored_pids(pid: Pid) -> List(Pid)

@external(erlang, "brazier_runtime_backpressure_test_ffi", "stop_trace")
fn stop_trace(session: TraceSession, pid: Pid) -> Nil
