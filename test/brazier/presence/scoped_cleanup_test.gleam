//// The scoped helpers clean up when the test body crashes, like ExUnit's
//// `on_exit/1`: `await.with_watch_info` removes its sys hook from the
//// watched process, `await.with_watch_pg_scope` removes its pg scope
//// monitor, and `holder.with_holder` kills its holder. All re-raise the
//// body's crash unchanged.

import brazier/await
import brazier/monitored
import brazier/presence/holder
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/string

const tick = "brazier_scoped_cleanup_tick"

pub fn with_watch_info_unwatches_when_the_body_crashes_test() {
  let message = atom.create(tick)
  // A gen_server: gleam_otp actors do not answer sys:install (see
  // brazier_sink_ffi), so a hook on one is never installed.
  let sink = start_sink()
  use <- monitored.with_cleanup(fn() { stop_sink(sink) })
  let assert Error(#("error", reason)) =
    rescue(fn() {
      use watch <- await.with_watch_info(sink, tick)
      // The hook is installed: it reports the tick.
      send_raw(sink, message)
      await.expect_info(watch, sink, "the tick sent while watching")
      panic as "test body crashed on purpose"
    })
    as "the body's crash is re-raised"
  assert string.contains(string.inspect(reason), "test body crashed on purpose")
    as "the crash re-raised is the body's, not the watch's"
  // A hook still installed would notify this process while the sink
  // handles the tick, before it answers the barrier's sys:get_state.
  send_raw(sink, message)
  await.barrier_pid(sink)
  // Only the hook's notices are selected: eunit runs the module's tests in
  // one process, whose mailbox may hold messages left by earlier tests.
  let notices =
    process.new_selector()
    |> process.select_record(atom.create("brazier_await_info"), 1, fn(m) { m })
  let assert Error(Nil) = process.selector_receive(notices, 0)
    as "the hook was removed although the body crashed"
}

pub fn with_watch_pg_scope_unwatches_when_the_body_crashes_test() {
  let scope = "brazier_scoped_cleanup_pg"
  let _scope_pid = start_pg_scope(scope)
  use <- monitored.with_cleanup(fn() { stop_pg_scope(scope) })
  let watches = process.new_subject()
  let assert Error(#("error", _)) =
    rescue(fn() {
      use watch <- await.with_watch_pg_scope(scope)
      process.send(watches, watch)
      panic as "test body crashed on purpose"
    })
    as "the body's crash is re-raised"
  let assert Ok(watch) = process.receive(watches, 0)
    as "the body ran with a watch"
  assert !pg_scope_watched(watch)
    as "the scope monitor was removed although the body crashed"
}

pub fn with_holder_kills_the_holder_when_the_body_crashes_test() {
  let started = process.new_subject()
  let assert Error(#("error", _)) =
    rescue(fn() {
      use h <- holder.with_holder()
      process.send(started, h.pid)
      panic as "test body crashed on purpose"
    })
    as "the body's crash is re-raised"
  let assert Ok(pid) = process.receive(started, 0)
    as "the body ran with a holder"
  // with_holder's kill waits for the holder's DOWN before re-raising.
  assert !process.is_alive(pid)
}

@external(erlang, "erlang", "send")
fn send_raw(pid: Pid, message: Atom) -> Atom

@external(erlang, "brazier_sink_ffi", "start")
fn start_sink() -> Pid

@external(erlang, "brazier_sink_ffi", "stop")
fn stop_sink(sink: Pid) -> Nil

@external(erlang, "brazier_await_ffi", "start_pg_scope")
fn start_pg_scope(scope: String) -> Pid

@external(erlang, "brazier_await_ffi", "stop_pg_scope")
fn stop_pg_scope(scope: String) -> Nil

@external(erlang, "brazier_await_ffi", "pg_scope_watched")
fn pg_scope_watched(watch: await.ScopeWatch) -> Bool

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))
