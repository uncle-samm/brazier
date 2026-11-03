//// Test synchronisation: wait for the event a test expects instead of
//// sleeping and hoping the system has settled.
////
//// The patterns come from ExUnit/LiveView test helpers:
//// - `receive_matching` is `assert_receive`: a selective receive with a
////   bounded deadline. A passing test never waits the deadline out, so the
////   deadline can be generous enough for a starved CI scheduler.
//// - `barrier` is the synchronous call LiveView's `render/1` makes before it
////   reads a view: once an actor answers it, every message sent to the actor
////   before the barrier has been handled.
//// - `await_down` waits on a monitor, never on `is_alive` polling.
////
//// A bounded wait for "nothing arrives" is still a time window. Use it only
//// after a barrier proves the work that could produce the message is done,
//// so the window guards against late, asynchronous sends and not against a
//// slow scheduler.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/string

/// The deadline for a message a test expects. Long enough that 8 busy loops
/// on every scheduler (the stress gate) never trip it; a passing test
/// returns as soon as the message arrives.
pub const deadline_ms = 5000

@external(erlang, "beacon_await_ffi", "barrier")
fn barrier_ffi(pid: Pid, timeout_ms: Int) -> Result(Nil, String)

/// Return once the actor that owns `subject` has handled every message sent
/// to it before this call. Whatever the actor sent this process while
/// handling them is then already in this process's mailbox.
///
/// Crashes, naming the reason, if the owner is dead or does not answer
/// within `deadline_ms`.
pub fn barrier(subject: Subject(a)) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) -> barrier_pid(pid)
    Error(Nil) -> panic as "barrier: the subject is named and has no owner pid"
  }
}

/// `barrier` for a process known by pid (a gen_server or gleam_otp actor).
pub fn barrier_pid(pid: Pid) -> Nil {
  case barrier_ffi(pid, deadline_ms) {
    Ok(Nil) -> Nil
    Error(reason) ->
      panic as {
        "barrier: "
        <> string.inspect(pid)
        <> " did not answer sys:get_state: "
        <> reason
      }
  }
}

/// Receive from `subject` until a message satisfies `matches`, waiting at
/// most `within` ms in total. Messages that do not match are consumed and
/// returned, in arrival order, in the `Error` so a failure can say what
/// arrived instead.
pub fn receive_matching(
  subject: Subject(a),
  within within: Int,
  matching matches: fn(a) -> Bool,
) -> Result(a, List(a)) {
  receive_until(subject, now_ms() + within, matches, [])
}

fn receive_until(
  subject: Subject(a),
  deadline: Int,
  matches: fn(a) -> Bool,
  skipped: List(a),
) -> Result(a, List(a)) {
  let remaining = int.max(0, deadline - now_ms())
  case process.receive(subject, remaining) {
    Ok(message) ->
      case matches(message) {
        True -> Ok(message)
        False -> receive_until(subject, deadline, matches, [message, ..skipped])
      }
    Error(Nil) -> Error(list.reverse(skipped))
  }
}

/// `receive_matching` that crashes with `what` and everything that arrived
/// instead when nothing matches by the deadline.
pub fn expect(
  subject: Subject(a),
  what: String,
  matching matches: fn(a) -> Bool,
) -> a {
  case receive_matching(subject, deadline_ms, matches) {
    Ok(message) -> message
    Error(skipped) ->
      panic as {
        "expected "
        <> what
        <> " within "
        <> int.to_string(deadline_ms)
        <> " ms; received instead: "
        <> string.inspect(skipped)
      }
  }
}

/// Every message already in the mailbox for `subject`, oldest first,
/// without waiting. Use it after a `barrier`.
pub fn drain(subject: Subject(a)) -> List(a) {
  drain_loop(subject, [])
}

fn drain_loop(subject: Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(message) -> drain_loop(subject, [message, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

/// `barrier` on the actor, then everything it has sent on `subject`.
pub fn settle(actor: Subject(b), subject: Subject(a)) -> List(a) {
  barrier(actor)
  drain(subject)
}

/// Wait on a monitor until `pid` exits. `Error(Nil)` if it is still alive
/// at the deadline.
pub fn await_down(pid: Pid, within within: Int) -> Result(Nil, Nil) {
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })
  case process.selector_receive(selector, within) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> {
      process.demonitor_process(monitor)
      Error(Nil)
    }
  }
}

/// `await_down` that crashes naming the process when it outlives the
/// deadline.
pub fn expect_down(pid: Pid, what: String) -> Nil {
  case await_down(pid, deadline_ms) {
    Ok(Nil) -> Nil
    Error(Nil) ->
      panic as {
        what
        <> " ("
        <> string.inspect(pid)
        <> ") still alive after "
        <> int.to_string(deadline_ms)
        <> " ms"
      }
  }
}

/// A watch on the plain messages one OTP process receives (see
/// `watch_info`).
pub type InfoWatch

@external(erlang, "beacon_await_ffi", "watch_info")
fn watch_info_ffi(pid: Pid, message: String) -> Result(InfoWatch, String)

@external(erlang, "beacon_await_ffi", "next_info")
fn next_info_ffi(watch: InfoWatch, timeout_ms: Int) -> Result(Nil, Nil)

/// Watch for the sys-compliant process `pid` (a gen_server or gleam_otp
/// actor) receiving the plain atom message `message`, such as a periodic
/// timer tick, through the OTP sys debug hook. Use it to wait for a timer
/// to fire instead of sleeping past its interval. The atom must exist.
pub fn watch_info(pid: Pid, message: String) -> InfoWatch {
  case watch_info_ffi(pid, message) {
    Ok(watch) -> watch
    Error(reason) ->
      panic as {
        "watch_info: cannot install a sys hook on "
        <> string.inspect(pid)
        <> ": "
        <> reason
      }
  }
}

/// Return once the watched process has received and handled the next
/// watched message. Crashes with `what` if none arrives by the deadline.
pub fn expect_info(watch: InfoWatch, pid: Pid, what: String) -> Nil {
  case next_info_ffi(watch, deadline_ms) {
    Ok(Nil) -> barrier_pid(pid)
    Error(Nil) ->
      panic as {
        "expected " <> what <> " within " <> int.to_string(deadline_ms) <> " ms"
      }
  }
}

/// A subscription to membership changes in a pg scope.
pub type ScopeWatch

@external(erlang, "beacon_await_ffi", "watch_pg_scope")
fn watch_pg_scope_ffi(scope: String) -> Result(ScopeWatch, String)

@external(erlang, "beacon_await_ffi", "next_pg_leave")
fn next_pg_leave_ffi(
  watch: ScopeWatch,
  pid: Pid,
  timeout_ms: Int,
) -> Result(Nil, Nil)

@external(erlang, "beacon_await_ffi", "unwatch_pg_scope")
fn unwatch_pg_scope_ffi(watch: ScopeWatch) -> Nil

/// Subscribe to joins and leaves in the running pg scope `scope`.
pub fn watch_pg_scope(scope: String) -> ScopeWatch {
  case watch_pg_scope_ffi(scope) {
    Ok(watch) -> watch
    Error(reason) -> panic as { "watch_pg_scope: " <> reason }
  }
}

/// Return once pg has removed `pid` from a group of the watched scope, as
/// it does when a member exits. Membership read afterwards is final.
pub fn expect_pg_leave(watch: ScopeWatch, pid: Pid, what: String) -> Nil {
  case next_pg_leave_ffi(watch, pid, deadline_ms) {
    Ok(Nil) -> Nil
    Error(Nil) ->
      panic as {
        what
        <> " ("
        <> string.inspect(pid)
        <> ") did not leave its pg group within "
        <> int.to_string(deadline_ms)
        <> " ms"
      }
  }
}

/// End the subscription and drop its pending notices.
pub fn unwatch_pg_scope(watch: ScopeWatch) -> Nil {
  unwatch_pg_scope_ffi(watch)
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: MillisecondUnit) -> Int

type MillisecondUnit {
  Millisecond
}

fn now_ms() -> Int {
  monotonic_time(Millisecond)
}
