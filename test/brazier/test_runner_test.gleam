//// The suite's runner (brazier_test_runner_ffi) ends every module with a
//// check that its tests left no telemetry handler attached. These tests
//// drive that check directly.

import brazier/monitored
import gleam/dynamic.{type Dynamic}
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

@external(erlang, "brazier_test_runner_ffi", "handler_snapshot")
fn handler_snapshot() -> Snapshot

@external(erlang, "brazier_test_runner_ffi", "handler_check")
fn handler_check(module: String, before: Snapshot) -> Nil

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
