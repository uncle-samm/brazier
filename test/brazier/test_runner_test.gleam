//// The suite's runner (brazier_test_runner_ffi) fails every test that
//// leaves a message in the test process's mailbox, and ends every module
//// with a check that its tests left no telemetry handler attached. These
//// tests drive both checks directly.

import brazier/monitored
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/int
import gleam/string

type Snapshot

pub fn handler_check_passes_when_the_table_is_unchanged_test() {
  let before = handler_snapshot()
  let assert Ok(Nil) = rescue(fn() { handler_check("unchanged", before) })
    as "an unchanged handler table passes"
}

pub fn handler_check_names_a_handler_left_attached_test() {
  let id = "brazier_runner_leak_" <> int.to_string(unique_integer())
  let before = handler_snapshot()
  // The handler is attached after the snapshot, as by a module's test that
  // never detached it; with_handler detaches it once the check has run.
  use <- monitored.with_handler(id, [["brazier_test", id]], fn(_) { Nil })
  let assert Error(#("error", reason)) =
    rescue(fn() { handler_check("leaking_module", before) })
    as "a handler attached since the snapshot fails the check"
  let described = string.inspect(reason)
  assert string.contains(described, id)
  assert string.contains(described, "leaking_module")
}

pub fn handler_check_names_a_handler_detached_since_the_snapshot_test() {
  let id = "brazier_runner_gone_" <> int.to_string(unique_integer())
  let before =
    monitored.with_handler(id, [["brazier_test", id]], fn(_) { Nil }, fn() {
      handler_snapshot()
    })
  let assert Error(#("error", reason)) =
    rescue(fn() { handler_check("detaching_module", before) })
    as "a handler detached since the snapshot fails the check"
  assert string.contains(string.inspect(reason), id)
}

// --- the per-test mailbox check -------------------------------------------

pub fn mailbox_check_passes_a_test_that_leaves_nothing_test() {
  let inbox = process.new_subject()
  let assert Ok(Nil) =
    rescue(fn() {
      mailbox_checked([], fake_module(), fake_function(), fn() {
        process.send(inbox, "received in the test")
        let assert Ok("received in the test") = process.receive(inbox, 0)
        Nil
      })
    })
    as "a test that received everything it caused passes"
}

pub fn mailbox_check_fails_the_test_that_left_a_message_test() {
  let inbox = process.new_subject()
  let assert Error(#("error", reason)) =
    rescue(fn() {
      mailbox_checked([], fake_module(), fake_function(), fn() {
        process.send(inbox, "left behind")
      })
    })
    as "a message left in the mailbox fails the test"
  // {mailbox_residue, {Module, Function}, Residue}, the residue being the
  // one message left: {SubjectTag, <<"left behind">>}.
  let described = string.inspect(reason)
  assert string.starts_with(
    described,
    "MailboxResidue(BrazierRunnerFakeModule(BrazierRunnerFakeTest), [#(",
  )
  assert string.ends_with(described, ", \"left behind\")])")
  let assert Error(Nil) = process.receive(inbox, 0)
    as "the residue is emptied, so it cannot reach the next test"
}

pub fn mailbox_check_reports_the_tests_own_failure_test() {
  let inbox = process.new_subject()
  let assert Error(#("error", reason)) =
    rescue(fn() {
      mailbox_checked([], fake_module(), fake_function(), fn() {
        process.send(inbox, "left by a failing test")
        fail_with("the test's own failure")
      })
    })
    as "a failing test still fails"
  assert reason == dynamic.string("the test's own failure")
  let assert Error(Nil) = process.receive(inbox, 0)
    as "a failing test's residue is emptied too"
}

pub fn mailbox_check_empties_a_pending_modules_residue_test() {
  let inbox = process.new_subject()
  let assert Ok(Nil) =
    rescue(fn() {
      mailbox_checked([fake_module()], fake_module(), fake_function(), fn() {
        process.send(inbox, "left by a pending module")
      })
    })
    as "residue of a module waiting for its fix does not fail the test"
  let assert Error(Nil) = process.receive(inbox, 0)
    as "a pending module's residue is emptied"
}

pub fn unsupported_test_generator_crashes_naming_the_test_test() {
  let assert Error(#("error", reason)) =
    rescue(fn() {
      checked_generated(
        fake_module(),
        fake_function(),
        dynamic.string("not a timeout"),
      )
    })
    as "a generator that returns something other than a Timeout crashes"
  assert string.inspect(reason)
    == "UnsupportedTestGenerator(BrazierRunnerFakeModule, BrazierRunnerFakeTest, \"not a timeout\")"
}

fn fake_module() -> Atom {
  atom.create("brazier_runner_fake_module")
}

fn fake_function() -> Atom {
  atom.create("brazier_runner_fake_test")
}

@external(erlang, "brazier_test_runner_ffi", "mailbox_checked")
fn mailbox_checked(
  pending: List(Atom),
  module: Atom,
  function: Atom,
  run: fn() -> Nil,
) -> Nil

@external(erlang, "brazier_test_runner_ffi", "checked_generated")
fn checked_generated(
  module: Atom,
  function: Atom,
  generated: Dynamic,
) -> Dynamic

@external(erlang, "erlang", "error")
fn fail_with(reason: String) -> Nil

@external(erlang, "brazier_test_runner_ffi", "handler_snapshot")
fn handler_snapshot() -> Snapshot

@external(erlang, "brazier_test_runner_ffi", "handler_check")
fn handler_check(module: String, before: Snapshot) -> Nil

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
