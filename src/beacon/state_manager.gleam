/// State manager — manages session state persistence.
/// Provides an abstraction over different storage backends.
///
/// Reference: Reflex.dev state manager (in-memory dict → Redis).
import beacon/log
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

/// Messages for the state manager actor.
pub type StateManagerMessage(state) {
  /// Store state for a session.
  Put(session_id: String, state: state)
  /// Retrieve state for a session.
  Get(session_id: String, reply_to: Subject(Result(state, Nil)))
  /// Remove state for a session.
  Delete(session_id: String)
  /// Get the number of stored sessions.
  Count(reply_to: Subject(Int))
}

/// State manager's internal state — a dict of session_id → state.
type ManagerState(state) =
  Dict(String, state)

/// Start an in-memory state manager.
/// This is the default for development. For production, use ETS or Redis.
pub fn start_in_memory() -> Result(
  Subject(StateManagerMessage(state)),
  actor.StartError,
) {
  log.info("beacon.state_manager", "Starting in-memory state manager")
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.start
  |> result_map(fn(started) {
    log.info("beacon.state_manager", "In-memory state manager started")
    started.data
  })
}

/// Handle state manager messages.
fn handle_message(
  state: ManagerState(s),
  message: StateManagerMessage(s),
) -> actor.Next(ManagerState(s), StateManagerMessage(s)) {
  case message {
    Put(session_id, session_state) -> {
      log.debug(
        "beacon.state_manager",
        "Storing state for session: " <> session_id,
      )
      actor.continue(dict.insert(state, session_id, session_state))
    }
    Get(session_id, reply_to) -> {
      let result = dict.get(state, session_id)
      process.send(reply_to, result)
      actor.continue(state)
    }
    Delete(session_id) -> {
      log.debug(
        "beacon.state_manager",
        "Deleting state for session: " <> session_id,
      )
      actor.continue(dict.delete(state, session_id))
    }
    Count(reply_to) -> {
      process.send(reply_to, dict.size(state))
      actor.continue(state)
    }
  }
}

/// Store state for a session.
pub fn put(
  manager: Subject(StateManagerMessage(state)),
  session_id: String,
  state: state,
) -> Nil {
  process.send(manager, Put(session_id: session_id, state: state))
}

/// Retrieve state for a session. Returns Error(Nil) if not found.
pub fn get(
  manager: Subject(StateManagerMessage(state)),
  session_id: String,
  timeout: Int,
) -> Result(state, Nil) {
  actor.call(manager, timeout, fn(reply_to) {
    Get(session_id: session_id, reply_to: reply_to)
  })
}

/// Remove state for a session.
pub fn delete(
  manager: Subject(StateManagerMessage(state)),
  session_id: String,
) -> Nil {
  process.send(manager, Delete(session_id: session_id))
}

/// Get the number of stored sessions.
pub fn count(
  manager: Subject(StateManagerMessage(state)),
  timeout: Int,
) -> Int {
  actor.call(manager, timeout, Count)
}

// --- ETS-Based State Manager ---

/// An ETS-based state manager that persists state in a named, public ETS
/// table.
///
/// The table is owned by a long-lived, node-wide owner process rather than
/// the caller, so it survives the process that created it (a request handler,
/// a runtime, a test). Creation is idempotent: starting a manager with a name
/// that already exists returns the same table.
///
/// Note: ETS tables use Erlang terms, so state must be serializable.
/// The table is `public` so any process can read/write.
pub type EtsManager {
  EtsManager(table: EtsTable)
}

/// Opaque reference to an ETS table.
pub type EtsTable

/// Why an ETS table could not be created or reused.
pub type EtsError {
  /// The name is not 1-255 bytes of `[A-Za-z0-9_-]` (names become atoms).
  InvalidTableName(name: String, reason: String)
  /// A table with this name already exists with a different type, e.g. a
  /// `set` where a `duplicate_bag` was requested.
  TableTypeMismatch(name: String, expected: String, found: String)
  /// The table owner process could not create the table.
  TableOwnerUnavailable(name: String, reason: String)
}

/// The ETS table type to create.
pub type EtsTableType {
  /// One value per key.
  EtsSet
  /// Any number of values per key, duplicates kept, insertion order kept.
  EtsDuplicateBag
}

/// Create (or reuse) a named ETS table of the given type, owned by the
/// long-lived table owner.
pub fn ensure_table(
  table_name: String,
  table_type: EtsTableType,
) -> Result(EtsTable, EtsError) {
  case ets_ensure_table(table_name, table_type) {
    Ok(table) -> {
      log.debug("beacon.state_manager", "ETS table ready: " <> table_name)
      Ok(table)
    }
    Error(err) -> {
      log.error(
        "beacon.state_manager",
        "ETS table "
          <> table_name
          <> " unavailable: "
          <> describe_ets_error(err),
      )
      Error(err)
    }
  }
}

/// Human-readable description of an `EtsError`, for logs and messages.
pub fn describe_ets_error(err: EtsError) -> String {
  case err {
    InvalidTableName(name:, reason:) ->
      "invalid table name \"" <> name <> "\": " <> reason
    TableTypeMismatch(name:, expected:, found:) ->
      "table \""
      <> name
      <> "\" already exists as "
      <> found
      <> ", expected "
      <> expected
    TableOwnerUnavailable(name:, reason:) ->
      "table owner could not create \"" <> name <> "\": " <> reason
  }
}

/// Start (or reuse) an ETS-based state manager.
/// Calling this twice with the same name returns the same table.
pub fn try_start_ets(table_name: String) -> Result(EtsManager, EtsError) {
  log.info("beacon.state_manager", "Starting ETS state manager: " <> table_name)
  case ensure_table(table_name, EtsSet) {
    Ok(table) -> Ok(EtsManager(table: table))
    Error(err) -> Error(err)
  }
}

/// Start (or reuse) an ETS-based state manager.
///
/// Table names are developer-supplied constants, so an `EtsError` here is a
/// programming error (an invalid name, or a name already used by a table of
/// another type). It is logged and then crashes the caller loudly; use
/// `try_start_ets` to handle it as a value instead.
pub fn start_ets(table_name: String) -> EtsManager {
  let result = try_start_ets(table_name)
  // Invariant: table names are compile-time constants chosen by the
  // developer; a failure is a bug to surface at startup, already logged by
  // ensure_table above.
  let assert Ok(manager) = result as "beacon.state_manager.start_ets failed"
  manager
}

/// Store state in the ETS table.
pub fn ets_put(manager: EtsManager, session_id: String, state: state) -> Nil {
  ets_ffi_put(manager.table, session_id, state)
}

/// Retrieve state from the ETS table.
pub fn ets_get(manager: EtsManager, session_id: String) -> Result(state, Nil) {
  ets_ffi_get(manager.table, session_id)
}

/// Delete state from the ETS table.
pub fn ets_delete(manager: EtsManager, session_id: String) -> Nil {
  ets_ffi_delete(manager.table, session_id)
}

/// Count entries in the ETS table.
pub fn ets_count(manager: EtsManager) -> Int {
  ets_ffi_count(manager.table)
}

@external(erlang, "beacon_ets_ffi", "ensure_table")
fn ets_ensure_table(
  name: String,
  table_type: EtsTableType,
) -> Result(EtsTable, EtsError)

@external(erlang, "beacon_ets_ffi", "put")
fn ets_ffi_put(table: EtsTable, key: String, value: state) -> Nil

@external(erlang, "beacon_ets_ffi", "get")
fn ets_ffi_get(table: EtsTable, key: String) -> Result(state, Nil)

@external(erlang, "beacon_ets_ffi", "delete")
fn ets_ffi_delete(table: EtsTable, key: String) -> Nil

@external(erlang, "beacon_ets_ffi", "count")
fn ets_ffi_count(table: EtsTable) -> Int

// --- Internal ---

fn result_map(result: Result(a, e), f: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(a) -> Ok(f(a))
    Error(e) -> Error(e)
  }
}
