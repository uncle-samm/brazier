import beacon/effect
import gleam/erlang/process
import gleam/list

fn perform(effect_: effect.Effect(a), dispatch: fn(a) -> Nil) -> Nil {
  effect.perform(effect_, dispatch, fn(_, _, _) { Nil })
}

pub fn none_is_none_test() {
  let eff = effect.none()
  let assert True = effect.is_none(eff)
}

pub fn from_is_not_none_test() {
  let eff = effect.from(fn(_dispatch) { Nil })
  let assert False = effect.is_none(eff)
}

pub fn from_dispatches_message_test() {
  let eff = effect.from(fn(dispatch) { dispatch(42) })
  let received = new_ref(0)
  perform(eff, fn(n) { set_ref(received, n) })
  let assert 42 = get_ref(received)
}

pub fn batch_combines_effects_test() {
  let eff1 = effect.from(fn(dispatch) { dispatch(1) })
  let eff2 = effect.from(fn(dispatch) { dispatch(2) })
  let batched = effect.batch([eff1, eff2])
  let assert False = effect.is_none(batched)
  let sum = new_ref(0)
  perform(batched, fn(n) { set_ref(sum, get_ref(sum) + n) })
  let assert 3 = get_ref(sum)
}

pub fn batch_empty_is_none_test() {
  let batched = effect.batch([])
  let assert True = effect.is_none(batched)
}

pub fn batch_of_nones_is_none_test() {
  let batched = effect.batch([effect.none(), effect.none()])
  let assert True = effect.is_none(batched)
}

pub fn map_transforms_message_test() {
  let eff = effect.from(fn(dispatch) { dispatch(10) })
  let mapped = effect.map(eff, fn(n) { n * 2 })
  let result = new_ref(0)
  perform(mapped, fn(n) { set_ref(result, n) })
  let assert 20 = get_ref(result)
}

pub fn perform_none_does_nothing_test() {
  let called = new_ref(0)
  perform(effect.none(), fn(_) { set_ref(called, 1) })
  let assert 0 = get_ref(called)
}

pub fn background_runs_in_separate_process_test() {
  let subject = process.new_subject()
  let eff = effect.background(fn(dispatch) { dispatch(42) })
  // Use a subject-based dispatch to capture the async result
  perform(eff, fn(n) { process.send(subject, n) })
  let selector =
    process.new_selector()
    |> process.select(subject)
  let assert Ok(42) = process.selector_receive(selector, 1000)
}

pub fn background_does_not_block_test() {
  let subject = process.new_subject()
  let eff =
    effect.background(fn(dispatch) {
      // Simulate slow work
      process.sleep(50)
      dispatch(99)
    })
  perform(eff, fn(n) { process.send(subject, n) })
  // Should return immediately (not blocked by the 50ms sleep)
  // Wait for the background process to finish
  let selector =
    process.new_selector()
    |> process.select(subject)
  let assert Ok(99) = process.selector_receive(selector, 1000)
}

pub fn background_is_not_none_test() {
  let eff = effect.background(fn(_dispatch) { Nil })
  let assert False = effect.is_none(eff)
}

pub fn every_dispatches_periodically_test() {
  let subject = process.new_subject()
  let eff = effect.every(50, fn() { 1 })
  let pids =
    effect.perform_tracked(eff, fn(n) { process.send(subject, n) }, fn(_, _, _) {
      Nil
    })
  // Should receive at least 3 ticks in 200ms
  let assert Ok(1) = process.receive(subject, 200)
  let assert Ok(1) = process.receive(subject, 200)
  let assert Ok(1) = process.receive(subject, 200)
  // Tests in a module share one eunit process (and so one timer registry):
  // stop the timer so it does not occupy a slot in later tests.
  list.each(pids, process.kill)
}

pub fn after_dispatches_once_test() {
  let subject = process.new_subject()
  let eff = effect.after(50, fn() { 42 })
  perform(eff, fn(n) { process.send(subject, n) })
  // Should receive exactly once after ~50ms
  let assert Ok(42) = process.receive(subject, 200)
  // Should NOT receive again
  let assert Error(Nil) = process.receive(subject, 150)
}

pub fn perform_tracked_returns_spawned_effect_process_test() {
  let eff = effect.after(1000, fn() { 42 })
  let pids = effect.perform_tracked(eff, fn(_) { Nil }, fn(_, _, _) { Nil })
  let assert True = list.length(pids) == 1
  let assert Ok(pid) = list.first(pids)
  let assert True = process.is_alive(pid)
  list.each(pids, fn(pid) { process.kill(pid) })
}

// Regression: the per-runtime timer cap must self-heal as timers die. An
// earlier implementation used a monotonic counter that only ever incremented,
// so once 10 timers had been created no further timer could start — even after
// the originals exited. Live-pid tracking prunes dead timers, freeing slots.
//
// Effects run synchronously in the calling process and the timer registry is
// per-process (Erlang process dictionary). eunit runs a module's tests in one
// process, so every test in this module must stop the timers it starts; this
// test then starts with an empty registry.
pub fn every_self_heals_after_timers_die_test() {
  // Fill every available slot (max_timers = 10). Long interval so the fillers
  // never tick during the test — we only care that they occupy slots.
  let filler_pids =
    list.repeat(Nil, 10)
    |> list.flat_map(fn(_i) {
      effect.perform_tracked(
        effect.every(60_000, fn() { 0 }),
        fn(_) { Nil },
        fn(_, _, _) { Nil },
      )
    })
  let assert True = list.length(filler_pids) == 10

  // At the cap, an additional timer is rejected and must never tick.
  let blocked_subject = process.new_subject()
  let blocked_pids =
    effect.perform_tracked(
      effect.every(50, fn() { 1 }),
      fn(n) { process.send(blocked_subject, n) },
      fn(_, _, _) { Nil },
    )
  let assert Error(Nil) = process.receive(blocked_subject, 150)

  // Kill the fillers and let the scheduler mark them dead.
  list.each(filler_pids, process.kill)
  process.sleep(20)

  // A new timer must now start: dead timers are pruned, freeing slots. Under
  // the old monotonic counter this stayed blocked forever and never ticked.
  let healed_subject = process.new_subject()
  let healed_pids =
    effect.perform_tracked(
      effect.every(50, fn() { 1 }),
      fn(n) { process.send(healed_subject, n) },
      fn(_, _, _) { Nil },
    )
  let assert Ok(1) = process.receive(healed_subject, 300)

  // Clean up spawned timers.
  list.each(blocked_pids, process.kill)
  list.each(healed_pids, process.kill)
}

pub fn keyed_effect_dispatches_through_keyed_channel_test() {
  let subject = process.new_subject()
  let eff =
    effect.keyed("load-projects", effect.from(fn(dispatch) { dispatch(7) }))
  effect.perform(eff, fn(_) { Nil }, fn(key, generation, value) {
    process.send(subject, #(key, generation, value))
  })
  let assert Ok(#("load-projects", 1, 7)) = process.receive(subject, 200)
}

pub fn cancellable_effect_emits_no_message_after_cancel_test() {
  let subject = process.new_subject()
  let #(eff, cancel_token) =
    effect.cancellable(
      effect.background(fn(dispatch) {
        process.sleep(50)
        dispatch(99)
      }),
    )
  effect.perform(eff, fn(_) { Nil }, fn(key, generation, value) {
    case effect.is_current_key_generation(key, generation) {
      True -> process.send(subject, value)
      False -> Nil
    }
  })
  perform(effect.cancel(cancel_token), fn(_) { Nil })
  let assert Error(Nil) = process.receive(subject, 200)
}

// --- Mutable ref helpers using process dictionary ---
// Used only in tests to capture side effects.

fn new_ref(initial: a) -> String {
  let key = "test_ref_" <> unique_string()
  put_process_dict(key, initial)
  key
}

fn get_ref(ref: String) -> a {
  get_process_dict(ref)
}

fn set_ref(ref: String, value: a) -> Nil {
  put_process_dict(ref, value)
  Nil
}

fn unique_string() -> String {
  erlang_unique_ref()
}

/// We use a simpler approach: just use a mutable list to capture dispatched values.
/// Actually, let's just use erlang process dictionary with proper binary keys.
@external(erlang, "beacon_test_ffi", "unique_ref")
fn erlang_unique_ref() -> String

@external(erlang, "beacon_test_ffi", "pd_put")
fn put_process_dict(key: String, value: a) -> Nil

@external(erlang, "beacon_test_ffi", "pd_get")
fn get_process_dict(key: String) -> a
