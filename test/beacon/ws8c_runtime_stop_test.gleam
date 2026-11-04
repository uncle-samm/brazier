//// `[beacon, runtime, stop]` for every stop that runs code: a crash in the
//// message handler (reason `crash`), an exit signal (reason `exit`) and a
//// `Shutdown`. The runtime still dies with the original reason, so its
//// links see what they saw before it trapped exits.
////
//// Each runtime is started by a helper process, so the runtime's link is
//// to the helper and not to the test process. The tests synchronize on the
//// telemetry event and the runtime's DOWN; nothing sleeps.

import beacon/effect
import beacon/error
import beacon/internal/context
import beacon/runtime
import beacon/telemetry.{type Event}
import gleam/dynamic/decode
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
    /// Tells the helper to return, exiting normally.
    release: Subject(Nil),
  )
}

/// Start a runtime from a helper process that stays alive until released.
fn start() -> Started {
  let reply = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(runtime) = runtime.start(config(), context())
        as "the test runtime must start"
      let release = process.new_subject()
      process.send(reply, #(runtime, release))
      process.receive_forever(release)
    })
  let assert Ok(#(runtime, release)) = process.receive(reply, 2000)
    as "the helper reports the started runtime"
  let assert Ok(runtime_pid) = process.subject_owner(runtime)
    as "a started runtime has an owner process"
  Started(runtime:, runtime_pid:, owner:, release:)
}

fn listen() -> #(String, Subject(Event)) {
  let assert Ok(Nil) = telemetry.start()
  let id = "ws8c_runtime_stop_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let assert Ok(Nil) =
    telemetry.attach(id, [["beacon", "runtime", "stop"]], fn(event) {
      process.send(events, event)
    })
  #(id, events)
}

fn expect_stop(events: Subject(Event)) -> Event {
  let assert Ok(event) = process.receive(events, 2000)
    as "[beacon, runtime, stop] must arrive within 2s"
  event
}

/// The runtime's exit reason, from its DOWN.
fn await_down(monitor: process.Monitor) -> process.ExitReason {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(reason:, ..)) =
    process.selector_receive(selector, 2000)
    as "the runtime must exit"
  reason
}

pub fn crash_in_update_reports_stop_with_its_reason_test() {
  let started = start()
  let #(id, events) = listen()
  let monitor = process.monitor(started.runtime_pid)
  let owner_monitor = process.monitor(started.owner)

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
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn failing_linked_process_reports_stop_with_exit_test() {
  let started = start()
  let #(id, events) = listen()
  let monitor = process.monitor(started.runtime_pid)

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
  let assert Error(Nil) = process.receive(events, 0)
    as "an exit signal reports one stop"
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn exit_signal_sent_to_the_runtime_reports_stop_test() {
  let started = start()
  let #(id, events) = listen()
  let monitor = process.monitor(started.runtime_pid)

  process.send_abnormal_exit(started.runtime_pid, "ws8c stopped from outside")

  let stop = expect_stop(events)
  let assert Ok("exit") = telemetry.string(stop, "reason")
  let assert Ok(description) = telemetry.string(stop, "error")
  let assert True = string.contains(description, "ws8c stopped from outside")
  let assert process.Abnormal(_) = await_down(monitor)
  let assert Ok(Nil) = telemetry.detach(id)
  process.send(started.release, Nil)
}

pub fn normal_exit_of_a_linked_process_does_not_stop_the_runtime_test() {
  let started = start()
  let #(id, events) = listen()
  let owner_monitor = process.monitor(started.owner)
  let monitor = process.monitor(started.runtime_pid)

  // The helper returns: its link delivers a normal exit, which the runtime
  // traps and ignores, as an untrapped link would.
  process.send(started.release, Nil)
  let assert process.Normal = await_down(owner_monitor)

  // Still serving: a Shutdown is answered with the shutdown stop.
  process.send(started.runtime, runtime.EffectDispatched(Increment))
  process.send(started.runtime, runtime.Shutdown)
  let stop = expect_stop(events)
  let assert Ok("shutdown") = telemetry.string(stop, "reason")
  let assert Error(Nil) = telemetry.string(stop, "kind")
  let assert process.Normal = await_down(monitor)
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn killed_runtime_emits_nothing_test() {
  // `kill` cannot be trapped: the one stop that runs no code.
  let started = start()
  let #(id, events) = listen()
  let monitor = process.monitor(started.runtime_pid)
  process.kill(started.runtime_pid)
  let assert process.Killed = await_down(monitor)
  let assert Error(Nil) = process.receive(events, 0)
    as "a killed runtime emits nothing"
  let assert Ok(Nil) = telemetry.detach(id)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
