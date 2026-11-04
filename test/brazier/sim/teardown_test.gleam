//// The sim teardown watch is scoped: its telemetry handler is detached and
//// its reports are gone from the mailbox however the body ends. The test
//// process stands in for the listener's connection owner, so a child it
//// spawns is reported as one of its connection handlers.

import brazier/sim/teardown
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/list
import gleam/string

pub fn watching_detaches_when_the_body_crashes_test() {
  let assert Error(#("error", _)) =
    rescue(fn() {
      use _watch <- teardown.watching_connections(process.self())
      let assert 1 = close_reporter()()
        as "the watch's handler is attached inside the scope"
      panic as "test body crashed on purpose"
    })
    as "the body's crash is re-raised"
  assert watch_handlers() == []
  assert !close_report_waiting()
}

pub fn watching_leaves_no_report_in_the_mailbox_test() {
  // A close the body never awaits, as a run that opened one connection
  // more than it waited for would leave.
  teardown.watching_connections(process.self(), fn(_watch) {
    let assert 1 = close_reporter()() as "one watch handler reports the close"
    assert close_report_waiting()
  })
  assert !close_report_waiting()
    as "the scope removed its unawaited report when it ended"
}

pub fn watching_drops_a_report_that_races_the_detach_test() {
  // A connection handler that looked the watch up before the detach and
  // reports after it: telemetry:execute reads the handler table, then
  // calls each handler.
  let late =
    teardown.watching_connections(process.self(), fn(_watch) {
      close_reporter()
    })
  let assert 1 = late() as "the late call ran the watch's handler"
  assert !close_report_waiting()
    as "a report sent after the scope ended was dropped, not delivered"
}

/// The teardown watch handlers attached on `[brazier, ws, close]`.
fn watch_handlers() -> List(String) {
  handler_ids(["brazier", "ws", "close"])
  |> list.filter(string.starts_with(_, "brazier-sim-teardown-"))
}

@external(erlang, "brazier_sim_ffi", "close_reporter")
fn close_reporter() -> fn() -> Int

@external(erlang, "brazier_sim_ffi", "close_report_waiting")
fn close_report_waiting() -> Bool

@external(erlang, "brazier_telemetry_test_ffi", "handler_ids")
fn handler_ids(name: List(String)) -> List(String)

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))
