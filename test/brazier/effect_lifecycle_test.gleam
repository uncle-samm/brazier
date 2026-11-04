//// Lifecycle tests: every framework-owned effect process (background
//// workers and their guardians, every/after timers, the PubSub listener)
//// must die with the process that owns it, and keyed effects must replace
//// rather than leak their previous process.
////
//// Synchronisation uses monitors and selectors only — no sleeps.

import brazier/effect
import brazier/error
import brazier/pubsub
import brazier/runtime
import brazier/test_ctx
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

@external(erlang, "brazier_effect_test_ffi", "effect_guardian")
fn effect_guardian(worker: Pid) -> Result(Pid, Nil)

@external(erlang, "brazier_effect_test_ffi", "pg_members")
fn pg_members(topic: String) -> List(Pid)

/// Wait, on a debug hook in the owning registry partition, until the
/// topic's dead subscribers are removed; returns the members still present
/// at the deadline.
@external(erlang, "brazier_effect_test_ffi", "await_pg_empty")
fn await_pg_empty(topic: String, timeout_ms: Int) -> List(Pid)

const down_timeout_ms = 2000

/// Wait until every pid has exited, asserting via monitors. Fails the test
/// (crashes) naming how many pids were still alive at the deadline.
fn assert_all_down(pids: List(Pid)) -> Nil {
  let monitors = list.map(pids, process.monitor)
  let selector =
    process.new_selector()
    |> process.select_monitors(fn(down) { down })
  await_downs(selector, list.length(monitors))
}

fn await_downs(
  selector: process.Selector(process.Down),
  remaining: Int,
) -> Nil {
  case remaining {
    0 -> Nil
    _ ->
      case process.selector_receive(selector, down_timeout_ms) {
        Ok(_down) -> await_downs(selector, remaining - 1)
        Error(Nil) ->
          panic as {
            int.to_string(remaining) <> " owned process(es) still alive"
          }
      }
  }
}

fn receive_pid(subject: Subject(Pid)) -> Pid {
  let assert Ok(pid) = process.receive(subject, down_timeout_ms)
  pid
}

fn perform(eff: effect.Effect(a)) -> List(Pid) {
  effect.perform_tracked(eff, fn(_) { Nil }, fn(_, _, _) { Nil })
}

/// An owner process performs a background effect, an `every` timer and an
/// `after` timer, reports every pid (worker, guardian, timers), then waits
/// for the `stop` instruction. Returns #(owner, owned_pids).
fn spawn_owner_with_effects(stop: fn() -> Nil) -> #(Pid, List(Pid)) {
  let report = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let worker_subject = process.new_subject()
      let timer_pids =
        perform(
          effect.batch([
            effect.every(60_000, fn() { Nil }),
            effect.after(60_000, fn() { Nil }),
          ]),
        )
      let worker_pids =
        perform(
          effect.background(fn(_dispatch) {
            process.send(worker_subject, process.self())
            process.sleep_forever()
          }),
        )
      let worker = receive_pid(worker_subject)
      let assert [tracked_worker] = worker_pids
      let assert True = tracked_worker == worker
      let assert Ok(guardian) = effect_guardian(worker)
      process.send(report, [worker, guardian, ..timer_pids])
      stop()
    })
  let assert Ok(owned) = process.receive(report, down_timeout_ms)
  #(owner, owned)
}

// --- Unhappy paths first ---

pub fn owned_processes_die_when_owner_is_killed_test() {
  let #(owner, owned) =
    spawn_owner_with_effects(fn() { process.sleep_forever() })
  let assert 4 = list.length(owned)
  list.each(owned, fn(pid) {
    let assert True = process.is_alive(pid)
  })
  process.kill(owner)
  assert_all_down(owned)
}

pub fn owned_processes_die_when_owner_crashes_test() {
  let #(owner, owned) =
    spawn_owner_with_effects(fn() { process.sleep_forever() })
  // An abnormal (non-kill) exit models a crash of the owner.
  process.send_abnormal_exit(owner, "simulated crash")
  assert_all_down([owner, ..owned])
}

pub fn owned_processes_die_when_owner_exits_normally_test() {
  // The owner returns as soon as it has reported its pids: a normal exit,
  // which links would NOT propagate. Monitors must still reap everything.
  let #(_owner, owned) = spawn_owner_with_effects(fn() { Nil })
  assert_all_down(owned)
}

pub fn every_over_cap_returns_no_placeholder_pid_test() {
  let fillers =
    list.flat_map(list.repeat(Nil, 10), fn(_) {
      perform(effect.every(60_000, fn() { Nil }))
    })
  let assert 10 = list.length(fillers)
  // At the cap the timer is rejected and NO pid (dummy or otherwise) is
  // returned for the runtime to track.
  let assert [] = perform(effect.every(60_000, fn() { Nil }))
  list.each(fillers, process.kill)
  assert_all_down(fillers)
}

pub fn every_rejects_non_positive_interval_test() {
  let ticks = process.new_subject()
  let assert [] = perform(effect.every(0, fn() { process.send(ticks, 1) }))
  let assert [] = perform(effect.every(-5, fn() { process.send(ticks, 1) }))
  let assert Error(Nil) = process.receive(ticks, 50)
}

pub fn after_rejects_negative_delay_test() {
  let fired = process.new_subject()
  let assert [] = perform(effect.after(-1, fn() { process.send(fired, 1) }))
  let assert Error(Nil) = process.receive(fired, 50)
}

pub fn rekeyed_every_replaces_previous_timer_test() {
  let first = perform(effect.keyed("clock", effect.every(60_000, fn() { Nil })))
  let assert [first_pid] = first
  // Re-keying 20 times must never exceed the cap or leak a timer: each
  // perform stops the previous "clock" timer before starting the new one.
  let last =
    list.fold(list.repeat(Nil, 20), first, fn(_previous, _) {
      perform(effect.keyed("clock", effect.every(60_000, fn() { Nil })))
    })
  let assert [last_pid] = last
  assert_all_down([first_pid])
  let assert True = process.is_alive(last_pid)
  // The single keyed timer occupies one slot, so nine more fit and the
  // eleventh is rejected.
  let others =
    list.flat_map(list.repeat(Nil, 9), fn(_) {
      perform(effect.every(60_000, fn() { Nil }))
    })
  let assert 9 = list.length(others)
  let assert [] = perform(effect.every(60_000, fn() { Nil }))
  let all = [last_pid, ..others]
  list.each(all, process.kill)
  assert_all_down(all)
}

pub fn rekeyed_timer_stops_ticking_test() {
  let ticks = process.new_subject()
  let assert [old] =
    perform(effect.keyed(
      "poll",
      effect.every(5, fn() { process.send(ticks, "old") }),
    ))
  let assert Ok("old") = process.receive(ticks, down_timeout_ms)
  let assert [new] =
    perform(effect.keyed("poll", effect.every(60_000, fn() { Nil })))
  assert_all_down([old])
  // Drain anything the old timer sent before it died; nothing may follow.
  drain(ticks)
  let assert Error(Nil) = process.receive(ticks, 50)
  process.kill(new)
  assert_all_down([new])
}

pub fn cancel_kills_keyed_background_process_test() {
  let started = process.new_subject()
  let #(eff, token) =
    effect.cancellable(
      effect.background(fn(_dispatch) {
        process.send(started, process.self())
        process.sleep_forever()
      }),
    )
  let assert [worker] = perform(eff)
  let assert True = receive_pid(started) == worker
  let assert Ok(guardian) = effect_guardian(worker)
  let assert [] = perform(effect.cancel(token))
  assert_all_down([worker, guardian])
}

pub fn finished_background_worker_releases_guardian_test() {
  let started = process.new_subject()
  let assert [worker] =
    perform(
      effect.background(fn(_dispatch) {
        // Block until told to finish so the guardian can be read first.
        let finish = process.new_subject()
        process.send(started, finish)
        let assert Ok(Nil) = process.receive(finish, down_timeout_ms)
        Nil
      }),
    )
  let assert Ok(finish) = process.receive(started, down_timeout_ms)
  let assert Ok(guardian) = effect_guardian(worker)
  let assert True = process.is_alive(guardian)
  // The owner (this test process) stays alive: the guardian must exit
  // because the worker finished, not because the owner died.
  process.send(finish, Nil)
  assert_all_down([worker, guardian])
}

fn drain(subject: Subject(a)) -> Nil {
  case process.receive(subject, 0) {
    Ok(_) -> drain(subject)
    Error(Nil) -> Nil
  }
}

// --- Runtime-level: nothing survives the runtime ---

pub type LifeModel {
  LifeModel(ticks: Int)
}

pub type LifeMsg {
  LifeTick
  LifeNotified
}

fn lifecycle_config(
  reports: Subject(Pid),
  topic: String,
) -> runtime.RuntimeConfig(LifeModel, LifeMsg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) {
      Ok(#(
        LifeModel(ticks: 0),
        effect.batch([
          effect.background(fn(_dispatch) {
            process.send(reports, process.self())
            process.sleep_forever()
          }),
          // The timer reports its own pid from inside make_msg on the
          // first tick.
          effect.every(10, fn() {
            process.send(reports, process.self())
            LifeTick
          }),
        ]),
      ))
    },
    update: fn(model, msg) {
      case msg {
        LifeTick -> #(LifeModel(ticks: model.ticks + 1), effect.none())
        LifeNotified -> #(model, effect.none())
      }
    },
    decode_event: fn(_, _, _, _) {
      Error(error.RuntimeError(reason: "lifecycle test decodes no events"))
    },
    encode_model: fn(model: LifeModel) { int.to_string(model.ticks) },
    route: option.None,
    restore_model: option.None,
    dynamic_subscriptions: option.Some(fn(_model) { [topic] }),
    on_notify: option.Some(fn(_topic) { LifeNotified }),
    on_notification: option.None,
    secret_key: "",
    presence: None,
    title: None,
  )
}

/// Start a lifecycle runtime and collect: runtime subject and pid, and the
/// background worker, its guardian, the interval timer and the PubSub
/// listener. The runtime is unlinked from the test process so killing it
/// does not kill the test.
fn start_lifecycle_runtime(
  topic: String,
) -> #(Subject(runtime.RuntimeMessage(LifeMsg)), Pid, List(Pid)) {
  pubsub.start()
  let reports = process.new_subject()
  let assert Ok(subject) =
    runtime.start(lifecycle_config(reports, topic), test_ctx.root())
  let assert Ok(runtime_pid) = process.subject_owner(subject)
  process.unlink(runtime_pid)
  // The timer reports on every tick, the worker once. The worker is the
  // pid with a guardian; the other is the timer.
  let #(worker, timer) = collect_worker_and_timer(reports, None, None)
  let assert Ok(guardian) = effect_guardian(worker)
  // The listener subscribes to its initial topics before runtime.start
  // returns, so membership is already established — exactly once.
  let assert [listener] = pg_members(topic)
  #(subject, runtime_pid, [worker, guardian, timer, listener])
}

fn collect_worker_and_timer(
  reports: Subject(Pid),
  worker: Option(Pid),
  timer: Option(Pid),
) -> #(Pid, Pid) {
  case worker, timer {
    Some(worker), Some(timer) -> #(worker, timer)
    _, _ -> {
      let pid = receive_pid(reports)
      case effect_guardian(pid) {
        Ok(_) -> collect_worker_and_timer(reports, Some(pid), timer)
        Error(Nil) -> collect_worker_and_timer(reports, worker, Some(pid))
      }
    }
  }
}

fn unique_topic(prefix: String) -> String {
  prefix <> "_" <> int.to_string(int.random(1_000_000_000))
}

pub fn runtime_kill_reaps_all_owned_processes_test() {
  let topic = unique_topic("lifecycle_kill")
  let #(_subject, runtime_pid, owned) = start_lifecycle_runtime(topic)
  process.kill(runtime_pid)
  assert_all_down([runtime_pid, ..owned])
  let assert [] = await_pg_empty(topic, down_timeout_ms)
}

pub fn runtime_crash_reaps_all_owned_processes_test() {
  let topic = unique_topic("lifecycle_crash")
  let #(_subject, runtime_pid, owned) = start_lifecycle_runtime(topic)
  process.send_abnormal_exit(runtime_pid, "simulated runtime crash")
  assert_all_down([runtime_pid, ..owned])
  let assert [] = await_pg_empty(topic, down_timeout_ms)
}

pub fn runtime_shutdown_reaps_all_owned_processes_test() {
  let topic = unique_topic("lifecycle_shutdown")
  let #(subject, runtime_pid, owned) = start_lifecycle_runtime(topic)
  process.send(subject, runtime.Shutdown)
  assert_all_down([runtime_pid, ..owned])
  let assert [] = await_pg_empty(topic, down_timeout_ms)
}

pub fn listener_crash_is_loud_and_takes_runtime_down_test() {
  // A dead listener means silently lost notifications; it is linked to the
  // runtime so the failure is loud instead.
  let topic = unique_topic("lifecycle_listener_crash")
  let #(_subject, runtime_pid, owned) = start_lifecycle_runtime(topic)
  let assert [_worker, _guardian, _timer, listener] = owned
  process.send_abnormal_exit(listener, "simulated listener crash")
  assert_all_down([runtime_pid, ..owned])
}
