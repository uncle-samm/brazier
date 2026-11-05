//// `await.until_telemetry` leaves nothing in the test process's mailbox:
//// not the events emitted after the check that held, not an event an
//// emitter sends after the detach, and not after a failure. It never
//// consumes a message that is not one of its own events.

import brazier/await
import brazier/telemetry
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/string

pub fn events_after_the_check_that_held_are_removed_test() {
  let name = unique_name("after")
  let failing = failing_checks(1)
  let checks = process.new_subject()
  // Each check emits the event, so when the second check holds, its own
  // event is queued on the helper's alias: the residue that once failed
  // http_fuzz_test.
  await.until_telemetry([name], "the second check", fn() {
    emit(name)
    process.send(checks, Nil)
    holds(failing)
  })
  let assert Ok(Nil) = process.receive(checks, 0) as "the first check ran"
  let assert Ok(Nil) = process.receive(checks, 0) as "the second check ran"
  let assert Error(Nil) = process.receive(checks, 0)
    as "the helper stopped at the check that held"
  assert queued() == 0
}

pub fn an_event_sent_after_the_detach_is_dropped_test() {
  let name = unique_name("late")
  let captured = process.new_subject()
  // The check takes the call telemetry:execute would make to the helper's
  // handler, as an emitter that read the handler table before the detach
  // does, and the test makes that call after the helper has returned.
  await.until_telemetry([name], "the capture", fn() {
    process.send(captured, looked_up_handler(name))
    True
  })
  let assert Ok(late_call) = process.receive(captured, 0)
    as "the check captured the handler"
  late_call()
  assert queued() == 0
}

pub fn messages_that_are_not_its_events_are_kept_test() {
  let name = unique_name("other")
  let failing = failing_checks(1)
  let other = process.new_subject()
  process.send(other, "sent before")
  await.until_telemetry([name], "the second check", fn() {
    process.send(other, "sent during")
    emit(name)
    holds(failing)
  })
  let assert Ok("sent before") = process.receive(other, 0)
    as "a message sent before the helper was kept"
  let assert Ok("sent during") = process.receive(other, 0)
    as "a message sent during the first check was kept"
  let assert Ok("sent during") = process.receive(other, 0)
    as "a message sent during the second check was kept"
  assert queued() == 0
}

pub fn a_condition_that_never_holds_crashes_naming_it_and_leaves_nothing_test() {
  let name = unique_name("never")
  // One event, from the first check, then none: the helper checks twice
  // and then waits its 0 ms deadline out.
  let first = failing_checks(1)
  let assert Error(#("error", reason)) =
    rescue(fn() {
      await.until_telemetry_within([name], "a state never reached", 0, fn() {
        case holds(first) {
          False -> emit(name)
          True -> Nil
        }
        False
      })
    })
    as "the helper crashes at its deadline"
  // A Gleam panic's reason is a map whose message is the panic's text.
  assert string.contains(
    string.inspect(reason),
    "\"expected a state never reached within 0 ms; still false after 1 events\"",
  )
  // The handler is detached (the runner's module check also fails on a
  // handler left attached).
  assert handler_ids(name) == []
  assert queued() == 0
}

pub fn a_crashing_condition_detaches_and_leaves_nothing_test() {
  let name = unique_name("crash")
  let assert Error(#("error", reason)) =
    rescue(fn() {
      await.until_telemetry([name], "a crashing check", fn() {
        // Queued on the helper's alias when the check crashes.
        emit(name)
        panic as "the check crashed on purpose"
      })
    })
    as "the check's crash is re-raised"
  assert string.contains(
    string.inspect(reason),
    "\"the check crashed on purpose\"",
  )
  assert handler_ids(name) == []
  assert queued() == 0
}

fn unique_name(label: String) -> List(String) {
  ["brazier_await_test", label <> "_" <> int.to_string(unique_integer())]
}

fn emit(name: List(String)) -> Nil {
  let assert Ok(Nil) = telemetry.execute(name, dict.new(), dict.new())
    as "the test event is emitted"
  Nil
}

/// The number of messages in this process's mailbox: the runner's check,
/// made inside the test so that a failure names the helper.
fn queued() -> Int {
  let #(_key, length) =
    process_info(process.self(), atom.create("message_queue_len"))
  length
}

/// A check that fails `times` times, then holds (see `holds`).
fn failing_checks(times: Int) -> Subject(Nil) {
  let tokens = process.new_subject()
  repeat(times, fn() { process.send(tokens, Nil) })
  tokens
}

/// False while `failing` has a token left, taking it; then True.
fn holds(failing: Subject(Nil)) -> Bool {
  case process.receive(failing, 0) {
    Ok(Nil) -> False
    Error(Nil) -> True
  }
}

fn repeat(times: Int, run: fn() -> Nil) -> Nil {
  case times > 0 {
    True -> {
      run()
      repeat(times - 1, run)
    }
    False -> Nil
  }
}

@external(erlang, "erlang", "process_info")
fn process_info(pid: Pid, item: Atom) -> #(Atom, Int)

@external(erlang, "brazier_telemetry_test_ffi", "looked_up_handler")
fn looked_up_handler(name: List(String)) -> fn() -> Nil

@external(erlang, "brazier_telemetry_test_ffi", "handler_ids")
fn handler_ids(name: List(String)) -> List(String)

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
