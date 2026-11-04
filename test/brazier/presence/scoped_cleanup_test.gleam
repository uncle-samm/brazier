//// The scoped helpers clean up when the test body crashes, like ExUnit's
//// `on_exit/1`: `await.with_watch_info` removes its sys hook from the
//// watched process, and `holder.with_holder` kills its holder. Both
//// re-raise the body's crash unchanged.

import brazier/await
import brazier/presence/holder
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/otp/actor

const tick = "brazier_scoped_cleanup_tick"

/// A gleam_otp actor that accepts any message, so a plain atom sent to it
/// is handled without a warning.
fn start_sink() -> Pid {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(_subject) {
      let selector =
        process.new_selector() |> process.select_other(fn(_) { Nil })
      actor.initialised(Nil)
      |> actor.selecting(selector)
      |> Ok
    })
    |> actor.on_message(fn(state, _) { actor.continue(state) })
    |> actor.start
    as "the sink actor starts"
  started.pid
}

pub fn with_watch_info_unwatches_when_the_body_crashes_test() {
  let message = atom.create(tick)
  let sink = start_sink()
  let assert Error(#("error", _)) =
    rescue(fn() {
      use _watch <- await.with_watch_info(sink, tick)
      panic as "test body crashed on purpose"
    })
    as "the body's crash is re-raised"
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
  // actor.start links the sink to this process, which eunit reuses for the
  // module's other tests: unlink before the kill so it does not spread.
  process.unlink(sink)
  process.kill(sink)
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

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))
