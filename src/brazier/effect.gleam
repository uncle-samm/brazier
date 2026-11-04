/// Brazier's effect system.
/// Effects are descriptions of side effects that the runtime will execute.
/// Following Lustre's design: effects are data, not actions.
///
/// Reference: Lustre's effect.gleam — same pattern (opaque type, from/none/batch),
/// but Brazier's is simpler: only synchronous effects with dispatch callback.
///
/// ## Process lifecycle
///
/// `background` and `every` run in separate BEAM processes that are OWNED
/// by the process performing the effect (the runtime actor). Owned
/// processes monitor their owner and exit when it exits for any reason, so a
/// runtime that stops or crashes never leaves timers or workers behind.
///
/// `after` starts no process: it is an `erlang:send_after` into the
/// performing process's own mailbox (LiveView's
/// `Process.send_after(self(), ...)`). The runtime selects the timer's
/// message and calls `fire_after_timer`, which dispatches `make_msg()`. The
/// VM cancels a timer whose destination has exited, so it cannot outlive
/// the runtime either.
///
/// Keyed owned effects are single-flight per key: performing a keyed
/// `background`, `every` or `after` stops whatever was started under the
/// same key (so re-keying a timer replaces it instead of leaking it and
/// consuming a slot), and `cancel` stops it as well.
///
/// ## Limits
///
/// Every limit is per runtime and rejects the new effect, with a warning
/// and a telemetry event, instead of queueing it:
///
/// - `every`: `max_timers` (10) live interval timers.
/// - `after`: `max_after_timers` (100) pending one-shot timers.
/// - `background`: `max_background_processes` (32) live workers.
///
/// ## Telemetry
///
/// - `[brazier, effect, run]` span around every callback that runs code:
///   `effect` is `"sync"` for `from` (it runs in the runtime and blocks its
///   update loop), `"keyed"` for a keyed `from`, and `"background"` for the
///   work of a `background` effect (measured in its own process). Starting
///   timers is not a span; a crash inside the span emits `exception` and
///   is re-raised unchanged.
/// - `[brazier, effect, timer, rejected]` with `limit` when `every` hits the
///   per-runtime timer cap.
/// - `[brazier, effect, after, rejected]` with `limit` when `after` hits the
///   per-runtime pending-timer cap.
/// - `[brazier, effect, background, rejected]` with `limit` when
///   `background` hits the per-runtime worker cap.
import brazier/log
import brazier/telemetry
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// An effect is a list of callbacks that will be executed by the runtime.
/// Each callback receives a `dispatch` function to send messages back to
/// the update loop.
pub opaque type Effect(msg) {
  Effect(callbacks: List(Callback(msg)))
}

/// Owned callbacks return `None` when nothing was deliberately started
/// (a cap reached, an invalid interval or delay) — never a placeholder.
type Callback(msg) {
  SimpleCallback(run: fn(fn(msg) -> Nil) -> Nil)
  KeyedCallback(key: String, run: fn(fn(msg) -> Nil) -> Nil)
  OwnedCallback(run: fn(fn(msg) -> Nil) -> Option(Owned))
  KeyedOwnedCallback(key: String, run: fn(fn(msg) -> Nil) -> Option(Owned))
  CancelKeyCallback(key: String)
}

/// What an owned effect started: a process (`background`, `every`) or a
/// timer in the owner's own mailbox (`after`).
type Owned {
  OwnedProcess(pid: process.Pid)
  OwnedTimer(timer: AfterTimer)
}

/// A pending `after` timer: the id carried by the
/// `{brazier_effect_after, Id}` message that `erlang:send_after` delivers
/// to the process that performed the effect.
pub type AfterTimer

pub opaque type Cancel {
  Cancel(key: String)
}

/// Maximum live `background` workers per runtime. Each is two processes
/// (the worker and its guardian), so a session holds at most 64 of them.
/// A worker counts until it exits.
pub const max_background_processes = 32

/// Maximum concurrent `every` timers per runtime process.
/// Prevents runaway timer creation from buggy update handlers.
pub const max_timers = 10

/// Maximum pending `after` timers per runtime. A timer counts from the
/// update that performed it until it fires or is cancelled.
pub const max_after_timers = 100

/// No effects to perform. Use when update doesn't need side effects.
pub fn none() -> Effect(msg) {
  Effect(callbacks: [])
}

/// Create an effect from a callback function.
/// The callback receives a `dispatch` function that sends messages
/// back to the runtime's update loop.
///
/// Example:
/// ```gleam
/// effect.from(fn(dispatch) {
///   // Do some async work...
///   dispatch(DataLoaded(result))
/// })
/// ```
pub fn from(callback: fn(fn(msg) -> Nil) -> Nil) -> Effect(msg) {
  Effect(callbacks: [SimpleCallback(run: callback)])
}

/// Associate an effect with a stable key so stale async completions can be dropped.
pub fn keyed(key: String, inner: Effect(msg)) -> Effect(msg) {
  Effect(
    callbacks: list.map(inner.callbacks, fn(callback) {
      case callback {
        SimpleCallback(run) -> KeyedCallback(key: key, run: run)
        KeyedCallback(_, run) -> KeyedCallback(key: key, run: run)
        OwnedCallback(run) -> KeyedOwnedCallback(key: key, run: run)
        KeyedOwnedCallback(_, run) -> KeyedOwnedCallback(key: key, run: run)
        CancelKeyCallback(cancel_key) -> CancelKeyCallback(key: cancel_key)
      }
    }),
  )
}

/// Wrap an effect in a generated cancel key and return the cancel token.
pub fn cancellable(inner: Effect(msg)) -> #(Effect(msg), Cancel) {
  let key = "cancel_" <> int.to_string(unique_integer())
  #(keyed(key, inner), Cancel(key: key))
}

/// Cancel a previously created cancellable effect token.
pub fn cancel(token: Cancel) -> Effect(msg) {
  Effect(callbacks: [CancelKeyCallback(key: token.key)])
}

/// Combine multiple effects into one. All will be executed.
/// No ordering guarantees between effects in the batch.
pub fn batch(effects: List(Effect(msg))) -> Effect(msg) {
  let all_callbacks =
    list.fold(effects, [], fn(acc, eff) { list.append(acc, eff.callbacks) })
  Effect(callbacks: all_callbacks)
}

/// Transform the message type of an effect.
/// Useful when composing effects from child components.
pub fn map(effect: Effect(a), f: fn(a) -> b) -> Effect(b) {
  let mapped_callbacks =
    list.map(effect.callbacks, fn(callback) {
      case callback {
        SimpleCallback(run) ->
          SimpleCallback(run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        KeyedCallback(key, run) ->
          KeyedCallback(key: key, run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        OwnedCallback(run) ->
          OwnedCallback(run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        KeyedOwnedCallback(key, run) ->
          KeyedOwnedCallback(key: key, run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        CancelKeyCallback(key) -> CancelKeyCallback(key: key)
      }
    })
  Effect(callbacks: mapped_callbacks)
}

/// Execute all callbacks in the effect with the given dispatch function.
/// Called by the runtime — not by user code. Started processes and timers
/// are owned by (and die with) the calling process.
pub fn perform(
  effect: Effect(msg),
  dispatch: fn(msg) -> Nil,
  dispatch_keyed: fn(String, Int, msg) -> Nil,
) -> Nil {
  let pids = perform_tracked(effect, dispatch, dispatch_keyed)
  log.debug(
    "brazier.effect",
    "Performed effect; spawned "
      <> int.to_string(list.length(pids))
      <> " owned processes",
  )
}

/// Execute callbacks and return the pids of the processes they started
/// (`background` workers and `every` timers; an `after` timer is not a
/// process). The calling process also tracks everything it owns, bounded
/// by the limits, and `stop_owned` stops it all.
pub fn perform_tracked(
  effect: Effect(msg),
  dispatch: fn(msg) -> Nil,
  dispatch_keyed: fn(String, Int, msg) -> Nil,
) -> List(process.Pid) {
  list.fold(effect.callbacks, [], fn(pids, callback) {
    case callback {
      SimpleCallback(run) -> {
        telemetry.effect_run_span("sync", fn() { run(dispatch) })
        pids
      }
      KeyedCallback(key, run) -> {
        let generation = register_key_generation(key)
        telemetry.effect_run_span("keyed", fn() {
          run(fn(message) { dispatch_keyed(key, generation, message) })
        })
        pids
      }
      OwnedCallback(run) -> with_process(run(dispatch), pids)
      KeyedOwnedCallback(key, run) -> {
        let generation = register_key_generation(key)
        // Stop what this key started BEFORE starting the new one so a
        // re-keyed timer frees its slot before the cap is checked.
        stop_keyed(key, "re-keyed")
        let owned =
          run(fn(message) { dispatch_keyed(key, generation, message) })
        case owned {
          Some(owned) -> track_keyed(key, owned)
          None -> Nil
        }
        with_process(owned, pids)
      }
      CancelKeyCallback(key) -> {
        cancel_key_generation(key)
        stop_keyed(key, "cancelled")
        pids
      }
    }
  })
}

fn with_process(
  owned: Option(Owned),
  pids: List(process.Pid),
) -> List(process.Pid) {
  case owned {
    Some(OwnedProcess(pid)) -> [pid, ..pids]
    Some(OwnedTimer(_)) | None -> pids
  }
}

fn stop_keyed(key: String, reason: String) -> Nil {
  case take_keyed(key) {
    Some(OwnedProcess(pid)) ->
      case stop_process(pid) {
        True ->
          log.debug(
            "brazier.effect",
            "Stopped keyed effect process for key "
              <> key
              <> " ("
              <> reason
              <> ")",
          )
        False ->
          log.debug(
            "brazier.effect",
            "Keyed effect process for key " <> key <> " had already exited",
          )
      }
    Some(OwnedTimer(timer)) ->
      case cancel_after_timer(timer) {
        True ->
          log.debug(
            "brazier.effect",
            "Cancelled keyed after timer for key "
              <> key
              <> " ("
              <> reason
              <> ")",
          )
        False ->
          log.debug(
            "brazier.effect",
            "Keyed after timer for key " <> key <> " had already fired",
          )
      }
    None -> Nil
  }
}

/// Stop everything the calling process owns: kill its `every` timers and
/// `background` workers and cancel its pending `after` timers. The runtime
/// calls it on `Shutdown`; on any other exit the owned processes stop on
/// their own (they monitor the owner) and the VM drops the timers.
/// Returns how many processes were stopped and how many timers cancelled.
@internal
pub fn stop_owned() -> #(Int, Int) {
  stop_all_owned()
}

/// Create a background effect that runs in a separate BEAM process.
/// Unlike `from`, this doesn't block the main update loop.
/// The callback runs in a spawned process and can dispatch messages back.
///
/// At most `max_background_processes` (32) workers can be alive per
/// runtime; one more is rejected (it never runs) with a warning and
/// `[brazier, effect, background, rejected]`.
///
/// Reference: Reflex `rx.event(background=True)`.
///
/// Example:
/// ```gleam
/// effect.background(fn(dispatch) {
///   let data = expensive_database_query()
///   dispatch(DataLoaded(data))
/// })
/// ```
pub fn background(callback: fn(fn(msg) -> Nil) -> Nil) -> Effect(msg) {
  Effect(callbacks: [
    OwnedCallback(run: fn(dispatch) {
      let current = live_background_count(max_background_processes)
      case current >= max_background_processes {
        True -> {
          log.warning(
            "brazier.effect",
            "Background effect limit reached ("
              <> int.to_string(current)
              <> "/"
              <> int.to_string(max_background_processes)
              <> " live workers) - new background effect rejected",
          )
          telemetry.effect_background_rejected(max_background_processes)
          None
        }
        False -> {
          let pid =
            spawn_owned(fn() {
              telemetry.effect_run_span("background", fn() {
                callback(dispatch)
              })
            })
          register_background(pid)
          log.debug(
            "brazier.effect",
            "Started owned background effect process ("
              <> int.to_string(current + 1)
              <> "/"
              <> int.to_string(max_background_processes)
              <> " workers)",
          )
          Some(OwnedProcess(pid))
        }
      }
    }),
  ])
}

/// Create a periodic timer effect. Dispatches `make_msg()` every `interval_ms`.
/// The timer runs in a separate BEAM process owned by the runtime and stops
/// when the runtime stops or crashes.
/// Capped at `max_timers` (10) concurrent timers per runtime — additional
/// timers are rejected with a warning and
/// `[brazier, effect, timer, rejected]`. An `interval_ms` below 1 is
/// rejected with an error log (it would be a busy loop).
///
/// Each un-keyed call creates a NEW timer. To replace a timer instead of
/// adding one, key it: `effect.keyed("clock", effect.every(1000, Tick))` —
/// performing it again stops the previous "clock" timer first, and
/// `effect.cancel` (via `effect.cancellable`) stops it outright.
///
/// Reference: Phoenix LiveView `Process.send_after` in `handle_info`.
///
/// Example:
/// ```gleam
/// effect.every(150, fn() { Tick })  // game loop at ~7fps
/// effect.every(1000, fn() { RefreshStats })  // dashboard update every second
/// ```
pub fn every(interval_ms: Int, make_msg: fn() -> msg) -> Effect(msg) {
  Effect(callbacks: [
    OwnedCallback(run: fn(dispatch) {
      case interval_ms < 1 {
        True -> {
          log.error(
            "brazier.effect",
            "effect.every rejected: interval_ms must be >= 1, got "
              <> int.to_string(interval_ms),
          )
          None
        }
        False -> {
          let current = live_timer_count()
          case current >= max_timers {
            True -> {
              log_timer_limit_warning(current, max_timers)
              telemetry.effect_timer_rejected(max_timers)
              None
            }
            False -> {
              let pid = start_interval(interval_ms, make_msg, dispatch)
              register_timer(pid)
              log.debug(
                "brazier.effect",
                "Started interval timer ("
                  <> int.to_string(interval_ms)
                  <> "ms, "
                  <> int.to_string(current + 1)
                  <> "/"
                  <> int.to_string(max_timers)
                  <> " timers)",
              )
              Some(OwnedProcess(pid))
            }
          }
        }
      }
    }),
  ])
}

/// Create a single delayed effect. Dispatches `make_msg()` once after
/// `delay_ms`.
///
/// No process is started: the timer is an `erlang:send_after` into the
/// runtime's own mailbox (LiveView's `Process.send_after(self(), ...)`),
/// and `make_msg` runs in the runtime when it fires. The VM drops the timer
/// if the runtime stops first.
///
/// A negative `delay_ms` is rejected with an error log. At most
/// `max_after_timers` (100) timers can be pending per runtime; one more is
/// rejected with a warning and `[brazier, effect, after, rejected]`. Key
/// it (`effect.keyed("toast", effect.after(...))`) to replace the pending
/// timer instead of adding one; `effect.cancel` cancels it.
///
/// Example:
/// ```gleam
/// effect.after(3000, fn() { HideNotification })
/// ```
pub fn after(delay_ms: Int, make_msg: fn() -> msg) -> Effect(msg) {
  Effect(callbacks: [
    OwnedCallback(run: fn(dispatch) {
      case delay_ms < 0 {
        True -> {
          log.error(
            "brazier.effect",
            "effect.after rejected: delay_ms must be >= 0, got "
              <> int.to_string(delay_ms),
          )
          None
        }
        False -> {
          let pending = pending_after_count()
          case pending >= max_after_timers {
            True -> {
              log.warning(
                "brazier.effect",
                "After-timer limit reached ("
                  <> int.to_string(pending)
                  <> "/"
                  <> int.to_string(max_after_timers)
                  <> " pending) - new delayed effect rejected",
              )
              telemetry.effect_after_rejected(max_after_timers)
              None
            }
            False -> {
              let timer =
                start_after_timer(delay_ms, fn() { dispatch(make_msg()) })
              log.debug(
                "brazier.effect",
                "Armed delayed effect ("
                  <> int.to_string(delay_ms)
                  <> "ms, "
                  <> int.to_string(pending + 1)
                  <> "/"
                  <> int.to_string(max_after_timers)
                  <> " pending)",
              )
              Some(OwnedTimer(timer))
            }
          }
        }
      }
    }),
  ])
}

/// Add the `after` timer messages of the calling process to `selector`.
/// The runtime selects them into its own message type and hands each to
/// `fire_after_timer`.
@internal
pub fn select_after_timers(
  selector: process.Selector(payload),
  mapping: fn(AfterTimer) -> payload,
) -> process.Selector(payload) {
  process.select_record(
    selector,
    tag: atom.create("brazier_effect_after"),
    fields: 1,
    mapping: fn(message) { mapping(after_timer_of_message(message)) },
  )
}

/// An `after` timer's message arrived: dispatch its `make_msg()`. A timer
/// cancelled after its message was already sent (a re-key or `cancel`
/// racing the expiry) is dropped here, because `erlang:cancel_timer`
/// cannot recall a message in flight.
@internal
pub fn fire_after_timer(timer: AfterTimer) -> Nil {
  case take_after_timer(timer) {
    Some(fire) -> fire()
    None ->
      log.debug(
        "brazier.effect",
        "Dropped the message of an after timer cancelled after it fired",
      )
  }
}

/// `after` timers the calling process has armed that have neither fired
/// nor been cancelled.
@internal
pub fn pending_after_timers() -> Int {
  pending_after_count()
}

/// Check if an effect has any callbacks to execute.
pub fn is_none(effect: Effect(msg)) -> Bool {
  list.is_empty(effect.callbacks)
}

/// Count live timers for this runtime, pruning any that have exited.
/// Effects execute inside the runtime process, so the count is per-runtime.
/// Self-healing: timers that died free up slots, so the cap can never
/// permanently lock out new timers (unlike a monotonic counter).
@external(erlang, "brazier_effect_ffi", "live_timer_count")
fn live_timer_count() -> Int

/// Track a spawned timer pid so it counts toward the live limit.
@external(erlang, "brazier_effect_ffi", "register_timer")
fn register_timer(pid: process.Pid) -> Nil

/// Log a warning when the timer limit is reached.
@external(erlang, "brazier_effect_ffi", "log_timer_limit_warning")
fn log_timer_limit_warning(current: Int, max: Int) -> Nil

/// Count live background workers (pruning dead ones once the tracked list
/// reaches the limit).
@external(erlang, "brazier_effect_ffi", "live_background_count")
fn live_background_count(max: Int) -> Int

/// Track a started background worker so it counts toward the limit.
@external(erlang, "brazier_effect_ffi", "register_background")
fn register_background(pid: process.Pid) -> Nil

/// Spawn a process owned by the caller: it is killed when the caller exits.
@external(erlang, "brazier_effect_ffi", "spawn_owned")
fn spawn_owned(work: fn() -> Nil) -> process.Pid

/// Start an owned periodic timer (send_after re-armed per tick).
@external(erlang, "brazier_effect_ffi", "start_interval")
fn start_interval(
  interval_ms: Int,
  make_msg: fn() -> msg,
  dispatch: fn(msg) -> Nil,
) -> process.Pid

/// Arm a one-shot `erlang:send_after` into the caller's own mailbox and
/// remember `fire` under the returned timer.
@external(erlang, "brazier_effect_ffi", "start_after_timer")
fn start_after_timer(delay_ms: Int, fire: fn() -> Nil) -> AfterTimer

@external(erlang, "brazier_effect_ffi", "pending_after_count")
fn pending_after_count() -> Int

@external(erlang, "brazier_effect_ffi", "take_after_timer")
fn take_after_timer(timer: AfterTimer) -> Option(fn() -> Nil)

/// Cancel a pending timer. Returns whether it was still pending.
@external(erlang, "brazier_effect_ffi", "cancel_after_timer")
fn cancel_after_timer(timer: AfterTimer) -> Bool

@external(erlang, "brazier_effect_ffi", "after_timer_of_message")
fn after_timer_of_message(message: dynamic.Dynamic) -> AfterTimer

/// Remove and return what is currently tracked for a key.
@external(erlang, "brazier_effect_ffi", "take_keyed")
fn take_keyed(key: String) -> Option(Owned)

/// Track what a keyed effect started.
@external(erlang, "brazier_effect_ffi", "track_keyed")
fn track_keyed(key: String, owned: Owned) -> Nil

/// Kill a process and free its slot. Returns whether it was alive.
@external(erlang, "brazier_effect_ffi", "stop_process")
fn stop_process(pid: process.Pid) -> Bool

@external(erlang, "brazier_effect_ffi", "stop_all_owned")
fn stop_all_owned() -> #(Int, Int)

@external(erlang, "brazier_effect_ffi", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "brazier_effect_ffi", "register_key_generation")
fn register_key_generation(key: String) -> Int

@external(erlang, "brazier_effect_ffi", "cancel_key_generation")
fn cancel_key_generation(key: String) -> Nil

@external(erlang, "brazier_effect_ffi", "is_current_key_generation")
pub fn is_current_key_generation(key: String, generation: Int) -> Bool
