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
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type ExitReason, type Monitor, type Pid}
import gleam/int

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
