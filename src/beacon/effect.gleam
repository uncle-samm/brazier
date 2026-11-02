/// Beacon's effect system.
/// Effects are descriptions of side effects that the runtime will execute.
/// Following Lustre's design: effects are data, not actions.
///
/// Reference: Lustre's effect.gleam — same pattern (opaque type, from/none/batch),
/// but Beacon's is simpler: only synchronous effects with dispatch callback.
///
/// ## Process lifecycle
///
/// `background`, `after` and `every` run in separate BEAM processes that are
/// OWNED by the process performing the effect (the runtime actor). Owned
/// processes monitor their owner and exit when it exits for any reason, so a
/// runtime that stops or crashes never leaves timers or workers behind.
///
/// Keyed spawned effects are single-flight per key: performing a keyed
/// spawned effect kills the process previously started under the same key
/// (so re-keying an `every` timer replaces it instead of leaking it and
/// consuming a timer slot), and `cancel` kills it as well.
import beacon/log
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

/// Spawned callbacks return `None` when the process was deliberately not
/// started (timer cap reached, invalid interval) — never a placeholder pid.
type Callback(msg) {
  SimpleCallback(run: fn(fn(msg) -> Nil) -> Nil)
  KeyedCallback(key: String, run: fn(fn(msg) -> Nil) -> Nil)
  SpawnedCallback(run: fn(fn(msg) -> Nil) -> Option(process.Pid))
  KeyedSpawnedCallback(
    key: String,
    run: fn(fn(msg) -> Nil) -> Option(process.Pid),
  )
  CancelKeyCallback(key: String)
}

pub opaque type Cancel {
  Cancel(key: String)
}

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
        SpawnedCallback(run) -> KeyedSpawnedCallback(key: key, run: run)
        KeyedSpawnedCallback(_, run) -> KeyedSpawnedCallback(key: key, run: run)
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
        SpawnedCallback(run) ->
          SpawnedCallback(run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        KeyedSpawnedCallback(key, run) ->
          KeyedSpawnedCallback(key: key, run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        CancelKeyCallback(key) -> CancelKeyCallback(key: key)
      }
    })
  Effect(callbacks: mapped_callbacks)
}

/// Execute all callbacks in the effect with the given dispatch function.
/// Called by the runtime — not by user code. Spawned processes are still
/// owned by (and die with) the calling process.
pub fn perform(
  effect: Effect(msg),
  dispatch: fn(msg) -> Nil,
  dispatch_keyed: fn(String, Int, msg) -> Nil,
) -> Nil {
  let pids = perform_tracked(effect, dispatch, dispatch_keyed)
  log.debug(
    "beacon.effect",
    "Performed effect; spawned "
      <> int.to_string(list.length(pids))
      <> " owned processes",
  )
}

/// Execute callbacks and return framework-owned spawned process IDs.
/// The runtime uses this to kill timers/background work during shutdown.
pub fn perform_tracked(
  effect: Effect(msg),
  dispatch: fn(msg) -> Nil,
  dispatch_keyed: fn(String, Int, msg) -> Nil,
) -> List(process.Pid) {
  list.fold(effect.callbacks, [], fn(pids, callback) {
    case callback {
      SimpleCallback(run) -> {
        run(dispatch)
        pids
      }
      KeyedCallback(key, run) -> {
        let generation = register_key_generation(key)
        run(fn(message) { dispatch_keyed(key, generation, message) })
        pids
      }
      SpawnedCallback(run) ->
        case run(dispatch) {
          Some(pid) -> [pid, ..pids]
          None -> pids
        }
      KeyedSpawnedCallback(key, run) -> {
        let generation = register_key_generation(key)
        // Stop the previous process for this key BEFORE starting the new one
        // so a re-keyed timer frees its slot before the cap is checked.
        stop_keyed_process(key, "re-keyed")
        case run(fn(message) { dispatch_keyed(key, generation, message) }) {
          Some(pid) -> {
            track_keyed_process(key, pid)
            [pid, ..pids]
          }
          None -> pids
        }
      }
      CancelKeyCallback(key) -> {
        cancel_key_generation(key)
        stop_keyed_process(key, "cancelled")
        pids
      }
    }
  })
}

fn stop_keyed_process(key: String, reason: String) -> Nil {
  case take_keyed_process(key) {
    Some(pid) ->
      case stop_process(pid) {
        True ->
          log.debug(
            "beacon.effect",
            "Stopped keyed effect process for key "
              <> key
              <> " ("
              <> reason
              <> ")",
          )
        False ->
          log.debug(
            "beacon.effect",
            "Keyed effect process for key " <> key <> " had already exited",
          )
      }
    None -> Nil
  }
}

/// Create a background effect that runs in a separate BEAM process.
/// Unlike `from`, this doesn't block the main update loop.
/// The callback runs in a spawned process and can dispatch messages back.
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
    SpawnedCallback(run: fn(dispatch) {
      let pid = spawn_owned(fn() { callback(dispatch) })
      log.debug("beacon.effect", "Started owned background effect process")
      Some(pid)
    }),
  ])
}

/// Maximum concurrent timers per runtime process.
/// Prevents runaway timer creation from buggy update handlers.
const max_timers = 10

/// Create a periodic timer effect. Dispatches `make_msg()` every `interval_ms`.
/// The timer runs in a separate BEAM process owned by the runtime and stops
/// when the runtime stops or crashes.
/// Capped at 10 concurrent timers per runtime — additional timers are
/// rejected with a warning. An `interval_ms` below 1 is rejected with an
/// error log (it would be a busy loop).
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
    SpawnedCallback(run: fn(dispatch) {
      case interval_ms < 1 {
        True -> {
          log.error(
            "beacon.effect",
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
              None
            }
            False -> {
              let pid = start_interval(interval_ms, make_msg, dispatch)
              register_timer(pid)
              log.debug(
                "beacon.effect",
                "Started interval timer ("
                  <> int.to_string(interval_ms)
                  <> "ms, "
                  <> int.to_string(current + 1)
                  <> "/"
                  <> int.to_string(max_timers)
                  <> " timers)",
              )
              Some(pid)
            }
          }
        }
      }
    }),
  ])
}

/// Count live timers for this runtime, pruning any that have exited.
/// Effects execute inside the runtime process, so the count is per-runtime.
/// Self-healing: timers that died free up slots, so the cap can never
/// permanently lock out new timers (unlike a monotonic counter).
@external(erlang, "beacon_effect_ffi", "live_timer_count")
fn live_timer_count() -> Int

/// Track a spawned timer pid so it counts toward the live limit.
@external(erlang, "beacon_effect_ffi", "register_timer")
fn register_timer(pid: process.Pid) -> Nil

/// Log a warning when the timer limit is reached.
@external(erlang, "beacon_effect_ffi", "log_timer_limit_warning")
fn log_timer_limit_warning(current: Int, max: Int) -> Nil

/// Spawn a process owned by the caller: it is killed when the caller exits.
@external(erlang, "beacon_effect_ffi", "spawn_owned")
fn spawn_owned(work: fn() -> Nil) -> process.Pid

/// Start an owned periodic timer (send_after re-armed per tick).
@external(erlang, "beacon_effect_ffi", "start_interval")
fn start_interval(
  interval_ms: Int,
  make_msg: fn() -> msg,
  dispatch: fn(msg) -> Nil,
) -> process.Pid

/// Start an owned one-shot timer.
@external(erlang, "beacon_effect_ffi", "start_after")
fn start_after(
  delay_ms: Int,
  make_msg: fn() -> msg,
  dispatch: fn(msg) -> Nil,
) -> process.Pid

/// Remove and return the process currently tracked for a key.
@external(erlang, "beacon_effect_ffi", "take_keyed_process")
fn take_keyed_process(key: String) -> Option(process.Pid)

/// Track the live process for a key.
@external(erlang, "beacon_effect_ffi", "track_keyed_process")
fn track_keyed_process(key: String, pid: process.Pid) -> Nil

/// Kill a process and free its timer slot. Returns whether it was alive.
@external(erlang, "beacon_effect_ffi", "stop_process")
fn stop_process(pid: process.Pid) -> Bool

@external(erlang, "beacon_effect_ffi", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "beacon_effect_ffi", "register_key_generation")
fn register_key_generation(key: String) -> Int

@external(erlang, "beacon_effect_ffi", "cancel_key_generation")
fn cancel_key_generation(key: String) -> Nil

@external(erlang, "beacon_effect_ffi", "is_current_key_generation")
pub fn is_current_key_generation(key: String, generation: Int) -> Bool

/// Create a single delayed effect. Dispatches `make_msg()` once after `delay_ms`.
/// The timer is owned by the runtime and is cancelled if the runtime stops
/// first. A negative `delay_ms` is rejected with an error log.
///
/// Example:
/// ```gleam
/// effect.after(3000, fn() { HideNotification })
/// ```
pub fn after(delay_ms: Int, make_msg: fn() -> msg) -> Effect(msg) {
  Effect(callbacks: [
    SpawnedCallback(run: fn(dispatch) {
      case delay_ms < 0 {
        True -> {
          log.error(
            "beacon.effect",
            "effect.after rejected: delay_ms must be >= 0, got "
              <> int.to_string(delay_ms),
          )
          None
        }
        False -> {
          log.debug(
            "beacon.effect",
            "Started delayed effect (" <> int.to_string(delay_ms) <> "ms)",
          )
          Some(start_after(delay_ms, make_msg, dispatch))
        }
      }
    }),
  ])
}

/// Check if an effect has any callbacks to execute.
pub fn is_none(effect: Effect(msg)) -> Bool {
  list.is_empty(effect.callbacks)
}
