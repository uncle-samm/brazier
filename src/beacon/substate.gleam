/// Substates as OTP actors — allows splitting model state across multiple
/// processes for isolation and concurrent access.
///
/// Reference: Reflex.dev substates, Architecture doc section 3.
import beacon/log
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

/// Messages a substate actor can receive.
pub type SubstateMessage(state, msg) {
  /// Get the current state.
  GetState(reply_to: Subject(state))
  /// Update the state with a message.
  UpdateState(msg: msg)
  /// Replace the state entirely.
  SetState(new_state: state)
  /// Shut down the substate actor.
  ShutdownSubstate
}

/// Configuration for a substate actor.
pub type SubstateConfig(state, msg) {
  SubstateConfig(
    /// The name/identifier for this substate (for logging).
    name: String,
    /// Initial state value.
    initial: state,
    /// Update function for this substate.
    update: fn(state, msg) -> state,
  )
}

/// Start a substate actor.
/// Returns a Subject for sending messages to the substate.
pub fn start(
  config: SubstateConfig(state, msg),
) -> Result(Subject(SubstateMessage(state, msg)), actor.StartError) {
  log.info("beacon.substate", "Starting substate: " <> config.name)

  actor.new(config.initial)
  |> actor.on_message(fn(state, message) {
    case message {
      GetState(reply_to) -> {
        process.send(reply_to, state)
        actor.continue(state)
      }
      UpdateState(msg) -> {
        let new_state = config.update(state, msg)
        actor.continue(new_state)
      }
      SetState(new_state) -> {
        actor.continue(new_state)
      }
      ShutdownSubstate -> {
        log.info("beacon.substate", "Shutting down substate: " <> config.name)
        actor.stop()
      }
    }
  })
  |> actor.start
  |> result_map(fn(started) {
    log.info("beacon.substate", "Substate started: " <> config.name)
    started.data
  })
}

/// Get the current state from a substate actor.
/// This is a synchronous call that blocks until the response is received.
pub fn get(
  subject: Subject(SubstateMessage(state, msg)),
  timeout: Int,
) -> state {
  actor.call(subject, timeout, GetState)
}

/// Send an update message to a substate actor.
/// This is asynchronous — it returns immediately.
pub fn update(subject: Subject(SubstateMessage(state, msg)), msg: msg) -> Nil {
  process.send(subject, UpdateState(msg: msg))
}

/// Replace the state of a substate actor.
pub fn set(
  subject: Subject(SubstateMessage(state, msg)),
  new_state: state,
) -> Nil {
  process.send(subject, SetState(new_state: new_state))
}

/// Shut down a substate actor.
pub fn shutdown(subject: Subject(SubstateMessage(state, msg))) -> Nil {
  process.send(subject, ShutdownSubstate)
}

// --- Internal ---

fn result_map(result: Result(a, e), f: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(a) -> Ok(f(a))
    Error(e) -> Error(e)
  }
}
