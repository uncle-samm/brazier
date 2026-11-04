/// Telemetry emitted by effects: the `[brazier, effect, run]` span around
/// effect callbacks and `[brazier, effect, timer, rejected]` at the timer
/// cap.
///
/// Sync and keyed callbacks run in the calling process; background work
/// runs in its own process. Every handler forwards to a subject owned by
/// the test, and tests synchronize on those events; nothing sleeps.
import brazier/effect
import brazier/log_capture
import brazier/telemetry.{type Event}
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list

const run_events = [
  ["brazier", "effect", "run", "start"],
  ["brazier", "effect", "run", "stop"],
  ["brazier", "effect", "run", "exception"],
]

const rejected_event = ["brazier", "effect", "timer", "rejected"]

fn listen(names: List(List(String))) -> #(String, Subject(Event)) {
  let assert Ok(Nil) = telemetry.start()
  let id = "effect_telemetry_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let assert Ok(Nil) =
    telemetry.attach(id, names, fn(event) { process.send(events, event) })
  #(id, events)
}

/// The first event matching `matches`; events from other live listeners
/// are skipped, never asserted on.
fn expect(events: Subject(Event), matches: fn(Event) -> Bool) -> Event {
  let assert Ok(event) = process.receive(events, 2000)
    as "expected telemetry event did not arrive within 2s"
  case matches(event) {
    True -> event
    False -> expect(events, matches)
  }
}

fn run_event(suffix: String, effect: String) -> fn(Event) -> Bool {
  fn(event: Event) {
    event.name == ["brazier", "effect", "run", suffix]
    && telemetry.string(event, "effect") == Ok(effect)
  }
}

fn perform(eff: effect.Effect(a), dispatch: fn(a) -> Nil) -> List(process.Pid) {
  effect.perform_tracked(eff, dispatch, fn(_, _, _) { Nil })
}

pub fn sync_effect_runs_inside_a_span_test() {
  let #(id, events) = listen(run_events)
  let dispatched = process.new_subject()
  let assert [] =
    perform(effect.from(fn(dispatch) { dispatch(7) }), process.send(
      dispatched,
      _,
    ))
  let assert Ok(7) = process.receive(dispatched, 0)
    as "a sync effect dispatches before perform returns"
  let _start = expect(events, run_event("start", "sync"))
  let stop = expect(events, run_event("stop", "sync"))
  let assert Ok(duration) = telemetry.int(stop, "duration")
  let assert True = duration >= 0
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn keyed_effect_reports_keyed_kind_test() {
  let #(id, events) = listen(run_events)
  let keyed = process.new_subject()
  effect.perform(
    effect.keyed("load", effect.from(fn(dispatch) { dispatch(1) })),
    fn(_) { Nil },
    fn(key, _generation, value) { process.send(keyed, #(key, value)) },
  )
  let assert Ok(#("load", 1)) = process.receive(keyed, 0)
  let _start = expect(events, run_event("start", "keyed"))
  let _stop = expect(events, run_event("stop", "keyed"))
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn background_effect_is_measured_in_its_own_process_test() {
  let #(id, events) = listen(run_events)
  let ready = process.new_subject()
  let dispatched = process.new_subject()
  let assert [pid] =
    perform(
      effect.background(fn(dispatch) {
        // Block until the test releases the work, so the start event is
        // observed while the span is still open. A subject is received on
        // only by its owner, so the worker makes its own and hands it over.
        let release = process.new_subject()
        process.send(ready, release)
        let assert Ok(Nil) = process.receive(release, 2000)
          as "test must release the background effect"
        dispatch(3)
      }),
      process.send(dispatched, _),
    )
  let _start = expect(events, run_event("start", "background"))
  let assert Ok(release) = process.receive(ready, 2000)
    as "the background worker must hand over its release subject"
  process.send(release, Nil)
  let _stop = expect(events, run_event("stop", "background"))
  let assert Ok(3) = process.receive(dispatched, 2000)
  let assert True = pid != process.self()
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn crashing_sync_effect_emits_exception_and_reraises_test() {
  let #(id, events) = listen(run_events)
  let assert Error(#("error", _reason)) =
    rescue(fn() {
      perform(effect.from(fn(_dispatch) { crash() }), fn(_) { Nil })
    })
  let exception = expect(events, run_event("exception", "sync"))
  // The exception class is in `kind`; the effect label survives beside it.
  let assert Ok("error") = telemetry.string(exception, "kind")
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn crashing_background_effect_emits_exception_test() {
  let #(id, events) = listen(run_events)
  let assert [pid] =
    perform(effect.background(fn(_dispatch) { crash() }), fn(_) { Nil })
  let monitor = process.monitor(pid)
  let _exception = expect(events, run_event("exception", "background"))
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(_down) = process.selector_receive(selector, 2000)
    as "the crashed background process must exit"
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn timer_cap_emits_rejected_with_limit_test() {
  let #(id, events) = listen([rejected_event])
  // The timer registry lives in this process; fill all ten slots with
  // timers that never tick during the test.
  let fillers =
    list.repeat(Nil, 10)
    |> list.flat_map(fn(_) {
      perform(effect.every(60_000, fn() { 0 }), fn(_) { Nil })
    })
  let assert 10 = list.length(fillers)
  let assert [] = perform(effect.every(60_000, fn() { 0 }), fn(_) { Nil })
    as "the eleventh timer must be rejected"
  let rejected =
    expect(events, fn(event: Event) { event.name == rejected_event })
  let assert Ok(10) = telemetry.int(rejected, "limit")
  stop_all(fillers)
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn after_cap_emits_rejected_with_limit_test() {
  let event_name = ["brazier", "effect", "after", "rejected"]
  let #(id, events) = listen([event_name])
  let fired = process.new_subject()
  // Fill every slot with timers that do not fire during the test.
  list.each(list.repeat(Nil, effect.max_after_timers), fn(_) {
    let assert [] =
      perform(effect.after(60_000, fn() { 0 }), process.send(fired, _))
  })
  let assert 100 = effect.pending_after_timers()
  let #(rejected_pids, logs) =
    log_capture.capture(fn() {
      perform(effect.after(0, fn() { 1 }), process.send(fired, _))
    })
  let assert [] = rejected_pids
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "After-timer limit reached", "100/100",
    ])
  let assert 100 = effect.pending_after_timers()
    as "the rejected timer must not be armed"
  let rejected = expect(events, fn(event: Event) { event.name == event_name })
  let assert Ok(100) = telemetry.int(rejected, "limit")
  let assert #(0, 100) = effect.stop_owned()
  let assert Error(Nil) = process.receive(fired, 0)
  let assert Ok(Nil) = telemetry.detach(id)
}

pub fn background_cap_emits_rejected_with_limit_test() {
  let event_name = ["brazier", "effect", "background", "rejected"]
  let #(id, events) = listen([event_name])
  let ran = process.new_subject()
  let workers =
    list.repeat(Nil, effect.max_background_processes)
    |> list.flat_map(fn(_) {
      perform(
        effect.background(fn(_dispatch) { process.sleep_forever() }),
        fn(_) { Nil },
      )
    })
  let assert 32 = list.length(workers)
  let #(rejected_pids, logs) =
    log_capture.capture(fn() {
      perform(
        effect.background(fn(_dispatch) { process.send(ran, Nil) }),
        fn(_) { Nil },
      )
    })
  let assert [] = rejected_pids as "the 33rd worker must not start"
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "Background effect limit reached", "32/32",
    ])
  let rejected = expect(events, fn(event: Event) { event.name == event_name })
  let assert Ok(32) = telemetry.int(rejected, "limit")
  // A finished worker frees its slot: stop one and the next one starts.
  stop_all([first_worker(workers)])
  let assert [_worker] =
    perform(effect.background(fn(_dispatch) { process.send(ran, Nil) }), fn(_) {
      Nil
    })
  let assert Ok(Nil) = process.receive(ran, 2000)
    as "a worker under the cap must run"
  let assert #(_, 0) = effect.stop_owned()
  let assert Ok(Nil) = telemetry.detach(id)
}

fn first_worker(workers: List(process.Pid)) -> process.Pid {
  let assert [first, ..] = workers as "the cap test started workers"
  first
}

pub fn effect_without_handler_runs_normally_test() {
  let dispatched = process.new_subject()
  let assert [] =
    perform(effect.from(fn(dispatch) { dispatch(5) }), process.send(
      dispatched,
      _,
    ))
  let assert Ok(5) = process.receive(dispatched, 0)
}

/// Kill every pid and wait for each to exit, so the timer registry of this
/// process holds no live timers afterwards.
fn stop_all(pids: List(process.Pid)) -> Nil {
  list.each(pids, fn(pid) {
    let monitor = process.monitor(pid)
    process.kill(pid)
    let selector =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
    let assert Ok(_down) = process.selector_receive(selector, 2000)
      as "a killed timer must exit"
    Nil
  })
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, dynamic.Dynamic))

@external(erlang, "brazier_http_raw_ffi", "crash")
fn crash() -> a
