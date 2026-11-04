//// `[brazier, runtime, stop]` for every stop that runs code: a crash in the
//// message handler (reason `crash`), an exit signal (reason `exit`) and a
//// `Shutdown`. The runtime still dies with the original reason, so its
//// links see what they saw before it trapped exits.
////
//// Each runtime is started by a helper process, so the runtime's link is
//// to the helper and not to the test process. The tests synchronize on the
//// telemetry event and the runtime's DOWN; nothing sleeps.
////
//// A monitor is a signal from the test process. When the process it
//// targets is then stopped by a signal from ANOTHER process (the helper's
//// exit reaching the runtime through their link, or the runtime's crash
//// reaching the helper), the two signals have no ordering guarantee: the
//// target can exit before it handles the monitor, and the monitor then
//// reports `noproc` instead of the real reason. Every such monitor is
//// followed by a barrier (a synchronous request from the test process,
//// handled after the monitor), and `await_down` fails loudly on `noproc`.

import brazier/await
import brazier/effect
import brazier/error
import brazier/internal/context
import brazier/monitored
import brazier/runtime
import brazier/telemetry.{type Event}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/option
import gleam/string
import gleam/uri

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Explode
}

fn config() -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(count: 0), effect.none())) },
    update: fn(model: Model, msg: Msg) {
      case msg {
        Increment -> #(Model(count: model.count + 1), effect.none())
        Explode -> panic as "ws8c update explodes on purpose"
      }
    },
    encode_model: fn(model: Model) {
      "{\"count\":" <> int.to_string(model.count) <> "}"
    },
    decode_event: fn(_name, _handler_id, _data, _path) {
      Error(error.RuntimeError(reason: "no events"))
    },
    restore_model: option.None,
    route: option.None,
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    secret_key: "",
    presence: option.None,
    title: option.None,
  )
}

fn context() -> context.Context {
  context.new(
    uri: uri.Uri(
      ..uri.empty,
      scheme: option.Some("http"),
      host: option.Some("localhost"),
      path: "/",
    ),
    cookies: [],
    is_connected: True,
    session_id: Error(Nil),
  )
}

type Started {
  Started(
    runtime: Subject(runtime.RuntimeMessage(Msg)),
    runtime_pid: Pid,
    /// The helper that started (and is linked to) the runtime.
    owner: Pid,
    /// Controls the helper: `Release` makes it return, exiting normally.
    control: Subject(HelperMsg),
  )
}

type HelperMsg {
  /// Answer, proving every signal the test sent before has been handled.
  Ping(reply: Subject(Nil))
  Release
}

/// Start a runtime from a helper process that stays alive until released.
fn start() -> Started {
  let reply = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(runtime) = runtime.start(config(), context())
        as "the test runtime must start"
      let control = process.new_subject()
      process.send(reply, #(runtime, control))
      helper_loop(control)
    })
  let assert Ok(#(runtime, control)) = process.receive(reply, 2000)
    as "the helper reports the started runtime"
  let assert Ok(runtime_pid) = process.subject_owner(runtime)
    as "a started runtime has an owner process"
  Started(runtime:, runtime_pid:, owner:, control:)
}

fn helper_loop(control: Subject(HelperMsg)) -> Nil {
  case process.receive_forever(control) {
    Ping(reply:) -> {
      process.send(reply, Nil)
      helper_loop(control)
    }
    Release -> Nil
  }
}

/// The barrier for the helper, which is not a sys process: once it answers
/// a ping, it has handled every signal this process sent it before.
fn barrier_owner(started: Started) -> Nil {
  process.call(started.control, waiting: await.deadline_ms, sending: Ping)
}

/// Run `run` with the `[brazier, runtime, stop]` events sent to a subject it receives. The handler is
/// detached however `run` ends: telemetry handlers are node-wide, and one
/// left by a failing test would send every later event to eunit's shared
/// test process.
fn listen(run: fn(Subject(Event)) -> a) -> a {
  monitored.listening([["brazier", "runtime", "stop"]], run)
}

fn expect_stop(events: Subject(Event)) -> Event {
  let assert Ok(event) = process.receive(events, 2000)
    as "[brazier, runtime, stop] must arrive within 2s"
  event
}

/// The exit reason of a monitored process, from its DOWN. A `noproc`
/// reason means the process was gone before it handled the monitor, so the
/// real reason is lost: that is a missing barrier in the test, never a
/// result to assert on.
fn await_down(monitor: process.Monitor) -> process.ExitReason {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(reason:, ..)) =
    process.selector_receive(selector, await.deadline_ms)
    as "the monitored process must exit"
  case reason == process.Abnormal(atom.to_dynamic(atom.create("noproc"))) {
    True ->
      panic as {
        "the monitor reported noproc: the process exited before it handled "
        <> "the monitor, so a barrier is missing after process.monitor"
      }
    False -> reason
  }
}

pub fn crash_in_update_reports_stop_with_its_reason_test() {
  let started = start()
  use events <- listen()
  let monitor = process.monitor(started.runtime_pid)
  let owner_monitor = process.monitor(started.owner)
  // The helper dies from the runtime's exit signal, not from one of ours.
  barrier_owner(started)

  process.send(started.runtime, runtime.EffectDispatched(Explode))

  let stop = expect_stop(events)
  let assert Ok("crash") = telemetry.string(stop, "reason")
  let assert Ok("error") = telemetry.string(stop, "kind")
  let assert Ok(description) = telemetry.string(stop, "error")
  let assert True =
    string.contains(description, "ws8c update explodes on purpose")
  let assert Ok(uptime) = telemetry.int(stop, "uptime")
  let assert True = uptime > 0

  // The crash went on unchanged: the runtime died with the panic, and its
  // link took the helper down with it.
  let assert process.Abnormal(reason) = await_down(monitor)
  let assert True =
    string.contains(string.inspect(reason), "ws8c update explodes on purpose")
  let assert process.Abnormal(_) = await_down(owner_monitor)
  let assert Error(Nil) = process.receive(events, 0)
    as "a crash reports one stop"
}

pub fn failing_linked_process_reports_stop_with_exit_test() {
  let started = start()
  use events <- listen()
  let monitor = process.monitor(started.runtime_pid)
  // The runtime dies from the helper's exit signal, not from one of ours,
  // so make it handle the monitor first (the flake this test once had).
  await.barrier_pid(started.runtime_pid)

  // The helper is the runtime's link (as a connection handler is).
  process.send_abnormal_exit(started.owner, "ws8c linked owner fails")

  let stop = expect_stop(events)
  let assert Ok("exit") = telemetry.string(stop, "reason")
  let assert Ok("exit") = telemetry.string(stop, "kind")
  let assert Ok(description) = telemetry.string(stop, "error")
  let assert True = string.contains(description, "ws8c linked owner fails")

  // The runtime left with the signal's reason, as an untrapped link would.
  let assert process.Abnormal(reason) = await_down(monitor)
  let assert Ok("ws8c linked owner fails") = decode.run(reason, decode.string)
    as {
      "the runtime must leave with the signal's reason, not "
      <> string.inspect(reason)
    }
  let assert Error(Nil) = process.receive(events, 0)
    as "an exit signal reports one stop"
}

pub fn exit_signal_sent_to_the_runtime_reports_stop_test() {
  let started = start()
  use events <- listen()
  let monitor = process.monitor(started.runtime_pid)

  process.send_abnormal_exit(started.runtime_pid, "ws8c stopped from outside")

  let stop = expect_stop(events)
  let assert Ok("exit") = telemetry.string(stop, "reason")
  let assert Ok(description) = telemetry.string(stop, "error")
  let assert True = string.contains(description, "ws8c stopped from outside")
  let assert process.Abnormal(_) = await_down(monitor)
  process.send(started.control, Release)
}

pub fn normal_exit_of_a_linked_process_does_not_stop_the_runtime_test() {
  let started = start()
  use events <- listen()
  let owner_monitor = process.monitor(started.owner)
  let monitor = process.monitor(started.runtime_pid)

  // The helper returns: its link delivers a normal exit, which the runtime
  // traps and ignores, as an untrapped link would.
  process.send(started.control, Release)
  let assert process.Normal = await_down(owner_monitor)

  // Still serving: a Shutdown is answered with the shutdown stop.
  process.send(started.runtime, runtime.EffectDispatched(Increment))
  process.send(started.runtime, runtime.Shutdown)
  let stop = expect_stop(events)
  let assert Ok("shutdown") = telemetry.string(stop, "reason")
  let assert Error(Nil) = telemetry.string(stop, "kind")
  let assert process.Normal = await_down(monitor)
}

pub fn killed_runtime_emits_nothing_test() {
  // `kill` cannot be trapped: the one stop that runs no code.
  let started = start()
  use events <- listen()
  let monitor = process.monitor(started.runtime_pid)
  process.kill(started.runtime_pid)
  let assert process.Killed = await_down(monitor)
  let assert Error(Nil) = process.receive(events, 0)
    as "a killed runtime emits nothing"
}
