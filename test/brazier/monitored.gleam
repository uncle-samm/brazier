//// Monitors that cannot race the exit they report, and test bodies run in
//// a process of their own.
////
//// A monitor taken on a process that is already gone reports `noproc`, not
//// the reason it died. So a test that spawns a process, lets it crash, and
//// only then calls `process.monitor` passes on any abnormal DOWN, whether
//// or not the process crashed the way the test claims. OTP's answer is to
//// take the monitor with the spawn (`erlang:spawn_monitor/1`), or before
//// whatever makes the process exit:
////
//// - `spawn` starts a process with its monitor already in place;
//// - `down_reason` waits for a DOWN and fails loudly on `noproc`, which
////   always means a monitor taken too late;
//// - `isolated` runs a test body in a new process (ExUnit runs every test
////   in its own process), so subscriptions, links and stray messages die
////   with it instead of reaching the next test in eunit's shared process.

import brazier/await
import brazier/telemetry.{type Event}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{
  type ExitReason, type Monitor, type Pid, type Subject,
}
import gleam/int
import gleam/string

/// Spawn an unlinked process running `running`, monitored from the start:
/// its DOWN always carries the reason it exited with.
@external(erlang, "erlang", "spawn_monitor")
pub fn spawn(running: fn() -> anything) -> #(Pid, Monitor)

/// Wait for the DOWN of `monitor` and return its reason. Panics, naming
/// `what`, if none arrives by `await.deadline_ms`, and on a `noproc` DOWN:
/// the process was gone before the monitor was taken, so its real reason is
/// lost and the test is missing a barrier or a `spawn`.
pub fn down_reason(monitor: Monitor, what: String) -> ExitReason {
  down_reason_within(monitor, what, await.deadline_ms)
}

/// `down_reason` for an exit that takes longer than `await.deadline_ms` by
/// design (a retry budget, a restart window): waits up to `timeout_ms`.
pub fn down_reason_within(
  monitor: Monitor,
  what: String,
  timeout_ms: Int,
) -> ExitReason {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  case process.selector_receive(selector, timeout_ms) {
    Ok(process.ProcessDown(reason:, ..)) | Ok(process.PortDown(reason:, ..)) ->
      case is_noproc(reason) {
        True ->
          panic as {
            what
            <> ": the monitor reported noproc, so the process exited before "
            <> "the monitor was taken and its real exit reason is lost"
          }
        False -> reason
      }
    Error(Nil) ->
      panic as {
        what <> ": no DOWN within " <> int.to_string(timeout_ms) <> " ms"
      }
  }
}

/// An exit reason as Erlang prints it (`~0p`): `normal`, `killed`, or the
/// abnormal term, such as `{brazier_pubsub_down,...}`. `string.inspect`
/// prints atoms in Gleam style instead.
pub fn describe(reason: ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(term) -> format_term(term)
  }
}

@external(erlang, "brazier_monitored_ffi", "format_term")
fn format_term(term: Dynamic) -> String

fn is_noproc(reason: ExitReason) -> Bool {
  reason == process.Abnormal(atom.to_dynamic(atom.create("noproc")))
}

/// Run `run` in a new process and return its result once that process has
/// exited. A crash in `run` fails the caller with the crash's reason.
@external(erlang, "brazier_monitored_ffi", "isolated")
pub fn isolated(run: fn() -> a) -> a

/// Run `run`, then `cleanup`, whether `run` returned or crashed (ExUnit's
/// `on_exit`). Use it for state that outlives the test process: a telemetry
/// handler, an unlinked helper process. A crash in `run` is re-raised
/// unchanged once `cleanup` has run.
@external(erlang, "brazier_monitored_ffi", "with_cleanup")
pub fn with_cleanup(cleanup cleanup: fn() -> Nil, run run: fn() -> a) -> a

/// Attach the telemetry handler `id` to `names`, run `run`, then detach it,
/// whether `run` returned or crashed. Telemetry handlers are node-wide and
/// outlive the test process, so a handler left attached by a failing test
/// keeps sending every later event to eunit's shared test process (ExUnit's
/// `on_exit(fn -> :telemetry.detach(id) end)` pattern).
///
/// Crashes if the attach fails, and if the handler is no longer attached at
/// cleanup: a test that detaches its own handler uses `with_cleanup` and
/// `detach_unless_detached` instead.
pub fn with_handler(
  id: String,
  names: List(List(String)),
  handler: fn(Event) -> Nil,
  run: fn() -> a,
) -> a {
  case telemetry.start() {
    Ok(Nil) -> Nil
    Error(reason) ->
      panic as { "with_handler: telemetry start: " <> string.inspect(reason) }
  }
  case telemetry.attach(id, names, handler) {
    Ok(Nil) -> Nil
    Error(reason) ->
      panic as {
        "with_handler: attach " <> id <> ": " <> string.inspect(reason)
      }
  }
  use <- with_cleanup(fn() {
    case telemetry.detach(id) {
      Ok(Nil) -> Nil
      Error(reason) ->
        panic as {
          "with_handler: detach " <> id <> ": " <> string.inspect(reason)
        }
    }
  })
  run()
}

/// `with_handler` with a fresh handler id and a handler that forwards every
/// event to a subject owned by the calling process, which `run` receives.
///
/// No event outlives the scope in the caller's mailbox. eunit runs every
/// test of every module in one process, so an event left unreceived (an
/// accepted upgrade the test did not assert on) once reached a later
/// module's test. The handler sends through a process alias, and the
/// cleanup, after the detach, deactivates the alias and removes the scope's
/// events still in the mailbox. An emitter that looked the handler up
/// before the detach and sends after it sends to an inactive alias, which
/// the runtime drops: the pattern OTP uses for late `gen_server:call`
/// replies, as `erlang:demonitor(Ref, [flush])` is for a late DOWN.
pub fn listening(names: List(List(String)), run: fn(Subject(Event)) -> a) -> a {
  let id = "brazier_listening_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let alias = new_alias()
  // Registered first, so it runs after with_handler's detach.
  use <- with_cleanup(fn() { close_alias(alias, events) })
  use <- with_handler(id, names, fn(event) {
    send_through_alias(alias, events, event)
  })
  run(events)
}

/// A process alias (`erlang:alias/0`) of the calling process.
type Alias

@external(erlang, "erlang", "alias")
fn new_alias() -> Alias

/// Send `event` on `subject`'s tag to the alias instead of the owner's pid.
@external(erlang, "brazier_monitored_ffi", "send_through_alias")
fn send_through_alias(
  alias: Alias,
  subject: Subject(Event),
  event: Event,
) -> Nil

/// Deactivate `alias` and remove the messages on `subject`'s tag already in
/// the mailbox. Crashes if the alias was not active.
@external(erlang, "brazier_monitored_ffi", "close_alias")
fn close_alias(alias: Alias, subject: Subject(Event)) -> Nil

/// Cleanup for a test that detaches handler `id` itself (to check detach,
/// or because telemetry detached a crashing handler): detach it if the body
/// failed before doing so. `NotAttached` is the expected outcome when the
/// body ran to the end, so it is the one error accepted; any other crashes.
pub fn detach_unless_detached(id: String) -> Nil {
  case telemetry.detach(id) {
    Ok(Nil) | Error(telemetry.NotAttached(_)) -> Nil
    Error(reason) ->
      panic as {
        "detach_unless_detached " <> id <> ": " <> string.inspect(reason)
      }
  }
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
