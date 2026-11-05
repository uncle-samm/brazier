//// The lifecycle of a started application around `wait_forever`:
////
//// - only the normal exit of an application the waiting process started
////   ends the wait; another linked process that exits normally is logged
////   and the wait goes on, and one that crashes still ends it loudly;
//// - the node-wide record of an application (what SIGTERM stops) is
////   forgotten by its watcher as soon as the tree goes, stopped or
////   crashed, together with the listener's bound port.
////
//// Tests that wait run on a peer node, so the test VM's own signal
//// handling is untouched. Everything synchronizes on monitors, traces,
//// replies and log lines forwarded as they are logged; nothing sleeps.

import brazier/app_config_fixture
import brazier/application
import brazier/cluster/log_capture
import brazier/cluster/peer.{Timeout}
import brazier/effect
import brazier/error
import brazier/html
import brazier/monitored
import brazier/transport/server
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/string

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Inc
}

const helper_exited_normally =
  "exited normally; it is not an application this process waits on"

fn config() -> application.AppConfig(Model, Msg) {
  app_config_fixture.new(
    port: 0,
    init: fn(_ctx) { Ok(#(Model(count: 0), effect.none())) },
    update: fn(model: Model, _msg) {
      #(Model(count: model.count + 1), effect.none())
    },
    view: fn(model: Model) {
      html.div([], [html.text(int.to_string(model.count))])
    },
    encode_model: fn(model: Model) {
      "{\"count\":" <> int.to_string(model.count) <> "}"
    },
    decode_event: fn(_name, _handler, _data, _path) { Ok(Inc) },
  )
}

/// A process in `wait_forever` with its application and a linked helper.
type Waiting {
  Waiting(
    waiter: Pid,
    /// The waiter's monitor, taken at its spawn.
    monitor: process.Monitor,
    app: application.App,
    /// Tells the helper how to exit: `Ok(Nil)` normally, `Error(reason)`
    /// with that reason.
    helper: Subject(Result(Nil, String)),
    /// Told when `wait_forever` returns.
    returned: Subject(Nil),
  )
}

/// Spawn a process that starts the application, links a helper and blocks
/// in `wait_forever`. Returns once its SIGTERM handler is installed, so it
/// traps exits and waits.
fn start_waiting() -> Waiting {
  let ready = process.new_subject()
  let started = process.new_subject()
  let returned = process.new_subject()
  let #(waiter, monitor) =
    monitored.spawn(fn() {
      let go = process.new_subject()
      process.send(ready, go)
      let assert Ok(Nil) = process.receive(go, 5000)
        as "the test lets the waiter go"
      let assert Ok(app) = application.start_supervised(config())
        as "the application starts"
      let helper_told = process.new_subject()
      // `process.spawn` links the helper to the waiter.
      process.spawn(fn() {
        let told = process.new_subject()
        process.send(helper_told, told)
        case process.receive_forever(told) {
          Ok(Nil) -> Nil
          Error(reason) -> exit_with(reason)
        }
      })
      let assert Ok(helper) = process.receive(helper_told, 5000)
        as "the helper reports its subject"
      process.send(started, #(app, helper))
      application.wait_forever()
      process.send(returned, Nil)
    })
  let assert Ok(go) = process.receive(ready, 5000)
    as "the waiter reports its subject"
  trace_install(waiter)
  process.send(go, Nil)
  let assert Ok(#(app, helper)) = process.receive(started, 10_000)
    as "the waiter starts the application and its helper"
  let assert Ok(Nil) = await_install(waiter, 5000)
  Waiting(waiter:, monitor:, app:, helper:, returned:)
}

pub fn linked_helper_exiting_normally_does_not_end_the_wait_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "lifecycle_helper_normal")
  let assert [p] = peers
  let outcome =
    peer.on(p, fn() {
      let waiting = start_waiting()
      // The waiter logs the helper's exit from its own process, after it
      // received the EXIT and before it waits again.
      let assert Ok(_line) =
        run_then_await_log(
          fn() { process.send(waiting.helper, Ok(Nil)) },
          "info",
          helper_exited_normally,
          5000,
        )
        as "the waiter logs the helper's normal exit"
      let early = process.receive(waiting.returned, 0)
      let alive = process.is_alive(waiting.waiter)
      // Stopping the application it waits on does end the wait.
      let assert Ok(Nil) = application.stop(waiting.app)
      let assert Ok(Nil) = process.receive(waiting.returned, 5000)
        as "wait_forever must return once the application stopped"
      let assert process.Normal =
        monitored.down_reason(waiting.monitor, "the waiter")
      #(early, alive, signal_handlers())
    })
  let assert #(Error(Nil), True, ["erl_signal_handler"]) = outcome
  Nil
}

pub fn linked_helper_crashing_ends_the_wait_loudly_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "lifecycle_helper_crash")
  let assert [p] = peers
  let reason =
    peer.on(p, fn() {
      let waiting = start_waiting()
      process.send(waiting.helper, Error("lifecycle_helper_failed"))
      monitored.down_reason(waiting.monitor, "the waiter")
      |> monitored.describe
    })
  assert string.contains(reason, "Linked application process exited")
  assert string.contains(reason, "lifecycle_helper_failed")
  Nil
}

/// Start an application in a process linked to its tree, which blocks
/// until the tree takes it down. Returns the app and a monitor of its
/// watcher.
fn start_linked() -> #(application.App, process.Monitor) {
  let started = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(app) = application.start(config()) as "the application starts"
    process.send(started, app)
    let never: Subject(Nil) = process.new_subject()
    process.receive_forever(never)
  })
  let assert Ok(app) = process.receive(started, 5000)
    as "the starter reports the started application"
  let assert True = application.is_recorded(app)
  let assert Ok(watcher) = application.watcher(app)
    as "a running application has a watcher"
  #(app, process.monitor(watcher))
}

pub fn crashed_tree_is_forgotten_at_once_test() {
  let #(app, watcher) = start_linked()
  let #(Nil, lines) =
    log_capture.capture(fn() {
      process.kill(app.supervisor_pid)
      // The watcher forgets the tree, logs it, and exits.
      let assert process.Normal =
        monitored.down_reason(watcher, "the application's watcher")
      Nil
    })
  let assert False = application.is_recorded(app)
  // Its bound port went with it: there is nothing left to release.
  let assert False = server.release(app.listener)
  let assert True =
    log_capture.contains(
      lines,
      "error",
      "exited with Killed: its node-wide record is forgotten, its bound port too",
    )
  // A later stop finds it gone: one warning.
  let assert Error(error.ConfigError(reason)) = application.stop(app)
  let assert True = string.contains(reason, "is not running")
  let assert True = string.contains(reason, "or its tree exited")
  Nil
}

pub fn stop_returns_once_the_watcher_forgot_the_tree_test() {
  let assert Ok(app) = application.start(config())
  let assert Ok(watcher) = application.watcher(app)
  let #(stopped, lines) = log_capture.capture(fn() { application.stop(app) })
  let assert Ok(Nil) = stopped
  // `stop` waited for the watcher: nothing is left behind.
  let assert False = process.is_alive(watcher)
  let assert False = application.is_recorded(app)
  let assert False = server.release(app.listener)
  let assert True =
    log_capture.contains(
      lines,
      "info",
      "stopped: its node-wide record is forgotten, its bound port too",
    )
  Nil
}

/// Before the watcher, SIGTERM found the crashed tree still recorded and
/// tried to stop it.
pub fn sigterm_after_a_crash_finds_nothing_to_drain_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "lifecycle_sigterm_crashed")
  let assert [p] = peers
  let #(recorded, lines) =
    peer.on(p, fn() {
      let #(app, watcher) = start_linked()
      process.kill(app.supervisor_pid)
      let assert process.Normal =
        monitored.down_reason(watcher, "the application's watcher")
      let recorded = application.is_recorded(app)
      let returned = spawn_waiter()
      let #(Nil, lines) =
        log_capture.capture(fn() {
          sigterm_and_wait()
          let assert Ok(Nil) = process.receive(returned, 10_000)
            as "wait_forever must return after SIGTERM"
          Nil
        })
      #(recorded, lines)
    })
  let assert False = recorded
  let assert True =
    log_capture.contains(lines, "info", "no application left running")
  let assert False = log_capture.contains(lines, "warning", "was not stopped")
  Nil
}

/// A process that blocks in `wait_forever` without an application of its
/// own. Returns once its SIGTERM handler is installed, with the subject
/// told when `wait_forever` returns.
fn spawn_waiter() -> Subject(Nil) {
  let ready = process.new_subject()
  let returned = process.new_subject()
  let waiter =
    process.spawn_unlinked(fn() {
      let go = process.new_subject()
      process.send(ready, go)
      let assert Ok(Nil) = process.receive(go, 5000)
      application.wait_forever()
      process.send(returned, Nil)
    })
  let assert Ok(go) = process.receive(ready, 5000)
  trace_install(waiter)
  process.send(go, Nil)
  let assert Ok(Nil) = await_install(waiter, 5000)
  returned
}

@external(erlang, "brazier_app_lifecycle_test_ffi", "run_then_await_log")
fn run_then_await_log(
  run: fn() -> Nil,
  level: String,
  fragment: String,
  timeout: Int,
) -> Result(String, String)

@external(erlang, "brazier_app_lifecycle_test_ffi", "exit_with")
fn exit_with(reason: String) -> Nil

@external(erlang, "brazier_ws8c_drain_ffi", "trace_install")
fn trace_install(pid: Pid) -> Nil

@external(erlang, "brazier_ws8c_drain_ffi", "await_install")
fn await_install(pid: Pid, timeout: Int) -> Result(Nil, String)

@external(erlang, "brazier_ws8c_drain_ffi", "signal_handlers")
fn signal_handlers() -> List(String)

@external(erlang, "brazier_sigterm_test_ffi", "sigterm_and_wait")
fn sigterm_and_wait() -> Nil
