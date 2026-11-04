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

import brazier/telemetry
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/string

/// The deadline for a message a test expects. Long enough that 8 busy loops
/// on every scheduler (the stress gate) never trip it; a passing test
/// returns as soon as the message arrives.
pub const deadline_ms = 5000

@external(erlang, "brazier_await_ffi", "barrier")
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

@external(erlang, "brazier_await_ffi", "watch_info")
fn watch_info_ffi(pid: Pid, message: String) -> Result(InfoWatch, String)

@external(erlang, "brazier_await_ffi", "next_info")
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

@external(erlang, "brazier_await_ffi", "watch_exit")
fn watch_exit_ffi(pid: Pid, child: Pid) -> Result(InfoWatch, String)

/// Watch for the sys-compliant process `pid` (a supervisor, or an actor
/// trapping exits) receiving `child`'s exit signal. `expect_info` then
/// returns once `pid` has handled it, for example once a supervisor has
/// restarted the child, instead of sleeping and hoping it has.
pub fn watch_exit(pid: Pid, child: Pid) -> InfoWatch {
  case watch_exit_ffi(pid, child) {
    Ok(watch) -> watch
    Error(reason) ->
      panic as {
        "watch_exit: cannot install a sys hook on "
        <> string.inspect(pid)
        <> ": "
        <> reason
      }
  }
}

@external(erlang, "brazier_await_ffi", "watch_down")
fn watch_down_ffi(pid: Pid, target: Pid) -> Result(InfoWatch, String)

/// Watch for the sys-compliant process `pid` (such as a presence shard)
/// receiving the DOWN of a monitor it holds on `target`. `expect_info` then
/// returns once `pid` has handled it, for example once a shard has removed
/// a dead session's presence, instead of polling until it has.
pub fn watch_down(pid: Pid, target: Pid) -> InfoWatch {
  case watch_down_ffi(pid, target) {
    Ok(watch) -> watch
    Error(reason) ->
      panic as {
        "watch_down: cannot install a sys hook on "
        <> string.inspect(pid)
        <> ": "
        <> reason
      }
  }
}

@external(erlang, "brazier_await_ffi", "unwatch")
fn unwatch_ffi(watch: InfoWatch) -> Nil

/// Remove a watch's hook from its process and drop its pending notices.
/// Call it when the watched process outlives the test (the shared PubSub
/// partitions and presence shards do): a forgotten hook keeps notifying the
/// test process, which eunit reuses for the module's later tests. The
/// watched process must still be alive.
pub fn unwatch(watch: InfoWatch) -> Nil {
  unwatch_ffi(watch)
}

/// `watch_info` scoped to `run`: the hook is removed when `run` returns or
/// crashes, so a failing test never leaves it on a process that outlives
/// the test. Prefer it to `watch_info` plus `unwatch`.
pub fn with_watch_info(pid: Pid, message: String, run: fn(InfoWatch) -> a) -> a {
  scoped_watch(pid, watch_info(pid, message), run)
}

/// `watch_exit` scoped to `run`, as `with_watch_info`.
pub fn with_watch_exit(pid: Pid, child: Pid, run: fn(InfoWatch) -> a) -> a {
  scoped_watch(pid, watch_exit(pid, child), run)
}

/// `watch_down` scoped to `run`, as `with_watch_info`.
pub fn with_watch_down(pid: Pid, target: Pid, run: fn(InfoWatch) -> a) -> a {
  scoped_watch(pid, watch_down(pid, target), run)
}

fn scoped_watch(pid: Pid, watch: InfoWatch, run: fn(InfoWatch) -> a) -> a {
  use <- with_cleanup(fn() {
    // A sys hook lives inside the watched process, so a process that has
    // exited (a test that stops it) holds none to remove, and sys:remove/2
    // would exit on it. Its pending notices carry the watch's own ref, which
    // no later watch selects on.
    case process.is_alive(pid) {
      True -> unwatch(watch)
      False -> Nil
    }
  })
  run(watch)
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

/// Wait one watched message at a time until `check` holds: for state a
/// process changes on its own timer (a presence shard marking a replica
/// down on a heartbeat tick). `check` runs first, then after each message
/// the process has handled. Crashes with `what` if it still fails after
/// `max_messages`, or if a message does not arrive by the deadline.
pub fn until_info(
  watch: InfoWatch,
  pid: Pid,
  check: fn() -> Bool,
  max_messages: Int,
  what: String,
) -> Nil {
  case check() {
    True -> Nil
    False if max_messages <= 0 ->
      panic as { "expected " <> what <> ": still false after its last message" }
    False -> {
      expect_info(watch, pid, what)
      until_info(watch, pid, check, max_messages - 1, what)
    }
  }
}

/// A subscription to membership changes in a pg scope.
pub type ScopeWatch

@external(erlang, "brazier_await_ffi", "watch_pg_scope")
fn watch_pg_scope_ffi(scope: String) -> Result(ScopeWatch, String)

@external(erlang, "brazier_await_ffi", "next_pg_leave")
fn next_pg_leave_ffi(
  watch: ScopeWatch,
  pid: Pid,
  timeout_ms: Int,
) -> Result(Nil, Nil)

@external(erlang, "brazier_await_ffi", "unwatch_pg_scope")
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

/// Return once `condition` holds, re-checking it each time one of `events`
/// is emitted, and crash naming `what` if it still fails at the deadline.
///
/// For state that another process updates and then announces with a
/// telemetry event (a connection slot released before
/// `[brazier, http, connection, closed]`, a session row deleted before
/// `[brazier, session, expired]`). The handler is attached before the first
/// check, so an update that lands at any point is either seen by that
/// check or followed by an event that triggers another. The events are
/// node-wide; one from elsewhere only causes an extra check.
pub fn until_telemetry(
  events: List(List(String)),
  what: String,
  condition: fn() -> Bool,
) -> Nil {
  let emitted = process.new_subject()
  let id = "brazier_await_" <> int.to_string(unique_integer())
  case telemetry.start() {
    Ok(Nil) -> Nil
    Error(reason) -> panic as { "until_telemetry: " <> string.inspect(reason) }
  }
  case
    telemetry.attach(id, events, fn(event) { process.send(emitted, event.name) })
  {
    Ok(Nil) -> Nil
    Error(reason) ->
      panic as { "until_telemetry: attach failed: " <> string.inspect(reason) }
  }
  // Detached even when `condition` crashes: the handler is global, and
  // left attached it would send every later event to this process.
  let outcome = {
    use <- with_cleanup(fn() {
      case telemetry.detach(id) {
        Ok(Nil) -> Nil
        Error(reason) ->
          panic as {
            "until_telemetry: detach failed: " <> string.inspect(reason)
          }
      }
    })
    recheck(emitted, condition, now_ms() + deadline_ms, 0)
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(seen) ->
      panic as {
        "expected "
        <> what
        <> " within "
        <> int.to_string(deadline_ms)
        <> " ms; still false after "
        <> int.to_string(seen)
        <> " events"
      }
  }
}

fn recheck(
  emitted: Subject(List(String)),
  condition: fn() -> Bool,
  deadline: Int,
  seen: Int,
) -> Result(Nil, Int) {
  case condition() {
    True -> Ok(Nil)
    False ->
      case process.receive(emitted, int.max(0, deadline - now_ms())) {
        Ok(_name) -> recheck(emitted, condition, deadline, seen + 1)
        Error(Nil) -> Error(seen)
      }
  }
}

/// `monitored.with_cleanup`, which this module cannot import: `monitored`
/// imports it.
@external(erlang, "brazier_monitored_ffi", "with_cleanup")
fn with_cleanup(cleanup: fn() -> Nil, run: fn() -> a) -> a

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: MillisecondUnit) -> Int

type MillisecondUnit {
  Millisecond
}

fn now_ms() -> Int {
  monotonic_time(Millisecond)
}
