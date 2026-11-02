/// Cookie-based session management.
/// Sessions are stored in ETS (server-side) with a session ID in a cookie.
///
/// Security properties:
/// - Every session has an absolute lifetime and an idle lifetime. Expired
///   sessions are never returned by `get`, are deleted lazily on access, and
///   are swept periodically by a sweeper process tied to the store owner.
/// - Writes (`set`) are atomic compare-and-swap updates: concurrent writers
///   never lose each other's keys, and a write never resurrects a session
///   that was deleted (logout) or expired.
/// - `rotate` issues a fresh session id carrying the same data and deletes
///   the old id. Use it on login and on any privilege change (OWASP session
///   fixation guidance).
/// - Live WebSocket connections can bind to a session id
///   (`bind_current_process`). Deleting, rotating, or expiring the session
///   sends `{beacon_session_revoked, Id, Reason}` to every bound process; the
///   transport closes those sockets.
///
/// Reference: OWASP Session Management Cheat Sheet; Phoenix
/// `live_socket_id` disconnect broadcasts.
import beacon/cookie
import beacon/log
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A session with key-value data.
pub type Session {
  Session(
    /// Unique session identifier (stored in cookie).
    id: String,
    /// Session data (key-value pairs).
    data: Dict(String, String),
  )
}

/// Lifetime configuration for a session store.
pub type StoreConfig {
  StoreConfig(
    /// Maximum age of a session from creation, in milliseconds.
    absolute_ttl_ms: Int,
    /// Maximum time between accesses, in milliseconds.
    idle_ttl_ms: Int,
    /// How often the background sweeper deletes expired sessions.
    sweep_interval_ms: Int,
  )
}

/// Session store backed by ETS.
pub opaque type SessionStore {
  SessionStore(table: SessionTable, table_name: String, config: StoreConfig)
}

/// Opaque ETS table reference.
pub type SessionTable

/// Why a session write or rotation failed.
pub type SessionStoreError {
  /// The session does not exist: never created, deleted, or rotated away.
  SessionNotFound
  /// The session existed but its absolute or idle lifetime has passed.
  SessionExpired
  /// The compare-and-swap lost too many races in a row. This indicates a
  /// pathological write storm on one session and is reported, never hidden.
  SessionContention
}

/// Why a bound process was told its session is gone.
pub type RevocationReason {
  /// The session was deleted (logout).
  Deleted
  /// The session id was replaced by `rotate` (login or privilege change).
  Rotated
  /// The session's absolute or idle lifetime passed.
  Expired
}

/// Default absolute lifetime: 24 hours.
pub const default_absolute_ttl_ms = 86_400_000

/// Default idle lifetime: 2 hours.
pub const default_idle_ttl_ms = 7_200_000

/// Default sweep interval: 60 seconds.
pub const default_sweep_interval_ms = 60_000

/// Bounded retries for the compare-and-swap loop in `set`.
const max_cas_attempts = 64

/// Default store lifetimes (24h absolute, 2h idle, sweep every minute).
pub fn default_store_config() -> StoreConfig {
  StoreConfig(
    absolute_ttl_ms: default_absolute_ttl_ms,
    idle_ttl_ms: default_idle_ttl_ms,
    sweep_interval_ms: default_sweep_interval_ms,
  )
}

/// Create a new session store with default lifetimes.
///
/// The ETS table is owned by the calling process; the expiry sweeper exits
/// when that process exits.
pub fn new_store(name: String) -> SessionStore {
  new_store_with_config(name, default_store_config())
}

/// Create a new session store with explicit lifetimes.
pub fn new_store_with_config(
  name: String,
  config: StoreConfig,
) -> SessionStore {
  // Invariant: lifetimes must be positive or every session is born expired
  // (or the sweeper spins). Crash at configuration time, not per request.
  let assert True = config.absolute_ttl_ms > 0
  let assert True = config.idle_ttl_ms > 0
  let assert True = config.sweep_interval_ms > 0
  let table = session_ets_new(name)
  let store =
    SessionStore(table: table, table_name: table_name(table), config: config)
  let _sweeper =
    start_sweeper(process.self(), config.sweep_interval_ms, fn() {
      sweep_expired(store)
      Nil
    })
  log.info(
    "beacon.session",
    "Created session store "
      <> store.table_name
      <> " (absolute_ttl_ms="
      <> int.to_string(config.absolute_ttl_ms)
      <> ", idle_ttl_ms="
      <> int.to_string(config.idle_ttl_ms)
      <> ")",
  )
  store
}

/// The lifetime configuration of a store.
pub fn store_config(store: SessionStore) -> StoreConfig {
  store.config
}

/// Create a new session with a generated ID.
pub fn create(store: SessionStore) -> Session {
  create_with_data(store, dict.new())
}

/// Create a new session with a generated ID and initial data, in one write.
pub fn create_with_data(
  store: SessionStore,
  data: Dict(String, String),
) -> Session {
  let id = generate_id()
  let session = Session(id: id, data: data)
  // Invariant: 256-bit random ids do not collide. If insert_new reports an
  // existing row the RNG is broken and continuing would hand one user's
  // session to another, so crash loudly.
  let assert True =
    session_ets_insert_new(store.table, id, 0, now_ms(), session)
  log.debug("beacon.session", "Created session in " <> store.table_name)
  session
}

/// Generate a cryptographically random, URL-safe token.
///
/// Used for session IDs and session-bound CSRF tokens.
pub fn generate_id() -> String {
  generate_session_id()
}

/// Get a live session by ID and refresh its idle deadline.
///
/// Returns None for unknown, deleted, rotated, or expired sessions. Expired
/// sessions are deleted on the spot and their bound sockets are notified.
pub fn get(store: SessionStore, id: String) -> Option(Session) {
  case lookup_live(store, id) {
    Ok(#(_version, session)) -> {
      // update_element never recreates a row deleted concurrently; a False
      // here means the session vanished between lookup and touch.
      case session_ets_touch(store.table, id, now_ms()) {
        True -> Some(session)
        False -> {
          log.debug(
            "beacon.session",
            "Session removed concurrently during get in " <> store.table_name,
          )
          None
        }
      }
    }
    Error(SessionNotFound) -> {
      log.debug("beacon.session", "Session not found in " <> store.table_name)
      None
    }
    Error(SessionExpired) -> None
    Error(SessionContention) -> None
  }
}

/// Read a row, enforcing lifetimes. Expired rows are deleted and revoked.
fn lookup_live(
  store: SessionStore,
  id: String,
) -> Result(#(Int, Session), SessionStoreError) {
  case session_ets_lookup(store.table, id) {
    Error(Nil) -> Error(SessionNotFound)
    Ok(#(version, created_at, last_seen, session)) -> {
      let now = now_ms()
      case is_expired(store.config, now, created_at, last_seen) {
        False -> Ok(#(version, session))
        True -> {
          expire_row(store, id, version)
          Error(SessionExpired)
        }
      }
    }
  }
}

fn is_expired(
  config: StoreConfig,
  now: Int,
  created_at: Int,
  last_seen: Int,
) -> Bool {
  now - created_at >= config.absolute_ttl_ms
  || now - last_seen >= config.idle_ttl_ms
}

/// Delete an expired row (only if unchanged) and notify bound sockets.
fn expire_row(store: SessionStore, id: String, version: Int) -> Nil {
  case session_ets_delete_if_version(store.table, id, version) {
    True -> {
      log.info("beacon.session", "Session expired in " <> store.table_name)
      revoke_bound(store, id, Expired)
    }
    False ->
      log.debug(
        "beacon.session",
        "Expired session already changed or removed in " <> store.table_name,
      )
  }
}

/// Atomically set one key in a session.
///
/// The write is applied to the CURRENT stored data (not the possibly stale
/// `session` argument), so concurrent `set` calls on different keys never
/// lose each other's writes. A deleted or expired session is never
/// recreated: the error is returned instead.
pub fn set(
  store: SessionStore,
  session: Session,
  key: String,
  value: String,
) -> Result(Session, SessionStoreError) {
  update(store, session.id, fn(data) { dict.insert(data, key, value) })
}

/// Atomically apply `transform` to a session's data.
///
/// `transform` may run more than once if another writer wins the race, so it
/// must be pure.
pub fn update(
  store: SessionStore,
  id: String,
  transform: fn(Dict(String, String)) -> Dict(String, String),
) -> Result(Session, SessionStoreError) {
  let result = update_loop(store, id, transform, max_cas_attempts)
  case result {
    Ok(_) -> log.debug("beacon.session", "Updated session")
    Error(SessionNotFound) ->
      log.warning(
        "beacon.session",
        "Refusing to write missing session in " <> store.table_name,
      )
    Error(SessionExpired) ->
      log.warning(
        "beacon.session",
        "Refusing to write expired session in " <> store.table_name,
      )
    Error(SessionContention) ->
      log.error(
        "beacon.session",
        "Session write lost "
          <> int.to_string(max_cas_attempts)
          <> " compare-and-swap races in "
          <> store.table_name,
      )
  }
  result
}

fn update_loop(
  store: SessionStore,
  id: String,
  transform: fn(Dict(String, String)) -> Dict(String, String),
  attempts_left: Int,
) -> Result(Session, SessionStoreError) {
  case attempts_left <= 0 {
    True -> Error(SessionContention)
    False -> {
      case session_ets_lookup(store.table, id) {
        Error(Nil) -> Error(SessionNotFound)
        Ok(#(version, created_at, last_seen, current)) -> {
          let now = now_ms()
          case is_expired(store.config, now, created_at, last_seen) {
            True -> {
              expire_row(store, id, version)
              Error(SessionExpired)
            }
            False -> {
              let updated = Session(..current, data: transform(current.data))
              let row = #(id, version + 1, created_at, now, updated)
              case session_ets_cas(store.table, id, version, row) {
                True -> Ok(updated)
                False -> update_loop(store, id, transform, attempts_left - 1)
              }
            }
          }
        }
      }
    }
  }
}

/// Get a value from a session.
pub fn get_value(session: Session, key: String) -> Option(String) {
  case dict.get(session.data, key) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

/// Delete a session (logout). Bound WebSockets are told to close.
pub fn delete(store: SessionStore, id: String) -> Nil {
  session_ets_delete(store.table, id)
  log.info("beacon.session", "Deleted session in " <> store.table_name)
  revoke_bound(store, id, Deleted)
}

/// Replace a session id with a fresh one carrying the same data.
///
/// The old id is deleted first-come-first-served: if two requests rotate the
/// same id concurrently exactly one succeeds and the other gets
/// `SessionNotFound`. Bound WebSockets on the old id are told to close; they
/// reconnect with the new cookie.
pub fn rotate(
  store: SessionStore,
  old_id: String,
) -> Result(Session, SessionStoreError) {
  case lookup_live(store, old_id) {
    Error(err) -> {
      log.warning(
        "beacon.session",
        "Cannot rotate session in "
          <> store.table_name
          <> ": "
          <> store_error_to_string(err),
      )
      Error(err)
    }
    Ok(#(version, old_session)) -> {
      case session_ets_delete_if_version(store.table, old_id, version) {
        False -> {
          log.warning(
            "beacon.session",
            "Session changed during rotation in " <> store.table_name,
          )
          Error(SessionContention)
        }
        True -> {
          let fresh = create_with_data(store, old_session.data)
          log.info("beacon.session", "Rotated session in " <> store.table_name)
          revoke_bound(store, old_id, Rotated)
          Ok(fresh)
        }
      }
    }
  }
}

/// Delete every expired session and notify their bound sockets.
/// Returns how many sessions were removed. Runs automatically every
/// `sweep_interval_ms`; exposed for tests and manual maintenance.
pub fn sweep_expired(store: SessionStore) -> Int {
  let now = now_ms()
  let expired =
    session_ets_expired_ids(
      store.table,
      now - store.config.absolute_ttl_ms,
      now - store.config.idle_ttl_ms,
    )
  let removed =
    list.fold(expired, 0, fn(count, entry) {
      let #(id, version) = entry
      case session_ets_delete_if_version(store.table, id, version) {
        True -> {
          revoke_bound(store, id, Expired)
          count + 1
        }
        False -> count
      }
    })
  case removed {
    0 -> log.debug("beacon.session", "Sweep found no expired sessions")
    n ->
      log.info(
        "beacon.session",
        "Swept "
          <> int.to_string(n)
          <> " expired session(s) from "
          <> store.table_name,
      )
  }
  removed
}

/// Number of rows currently stored (including not-yet-swept expired rows).
pub fn count(store: SessionStore) -> Int {
  session_ets_size(store.table)
}

// === Request helpers ===

/// Read the raw session id from a request cookie.
///
/// Does NOT check the store; use `get` to validate the session.
pub fn id_from_request(
  req: Request(body),
  cookie_name: String,
) -> Result(String, Nil) {
  case cookie.get(req, cookie_name) {
    Ok(id) ->
      case string.is_empty(id) {
        True -> Error(Nil)
        False -> Ok(id)
      }
    Error(Nil) -> Error(Nil)
  }
}

/// Lowercase hex SHA-256 of a session id.
///
/// Embed this (never the raw id, which is a bearer secret) in signed tokens
/// that must be bound to a session, such as the WebSocket join token.
pub fn binding_fingerprint(session_id: String) -> String {
  ffi_binding_fingerprint(session_id)
}

// === Live-connection binding ===

/// Bind the calling process (a WebSocket handler) to a session.
///
/// When the session is deleted, rotated, or expires, the process receives
/// `{beacon_session_revoked, SessionId, ReasonBinary}`. Binding is idempotent
/// and is released automatically when the process exits.
pub fn bind_current_process(store: SessionStore, session_id: String) -> Nil {
  let members = bind_process(store.table_name, session_id, process.self())
  log.debug(
    "beacon.session",
    "Bound process to session in "
      <> store.table_name
      <> " ("
      <> int.to_string(members)
      <> " bound)",
  )
}

/// How many live processes are bound to a session id.
pub fn bound_process_count(store: SessionStore, session_id: String) -> Int {
  ffi_bound_process_count(store.table_name, session_id)
}

fn revoke_bound(
  store: SessionStore,
  id: String,
  reason: RevocationReason,
) -> Nil {
  let reason_str = revocation_reason_to_string(reason)
  let notified = notify_revoked(store.table_name, id, reason_str)
  case notified {
    0 -> Nil
    n ->
      log.info(
        "beacon.session",
        "Revoked "
          <> int.to_string(n)
          <> " live connection(s) for "
          <> reason_str
          <> " session in "
          <> store.table_name,
      )
  }
}

/// Stable text for a revocation reason (sent to bound processes).
pub fn revocation_reason_to_string(reason: RevocationReason) -> String {
  case reason {
    Deleted -> "deleted"
    Rotated -> "rotated"
    Expired -> "expired"
  }
}

/// Stable text for a store error.
pub fn store_error_to_string(err: SessionStoreError) -> String {
  case err {
    SessionNotFound -> "session not found"
    SessionExpired -> "session expired"
    SessionContention -> "session write contention"
  }
}

/// Constant-time string comparison for secrets such as CSRF tokens.
pub fn secure_compare(a: String, b: String) -> Bool {
  constant_time_equal(a, b)
}

// === FFI ===

@external(erlang, "beacon_session_ffi", "session_ets_new")
fn session_ets_new(name: String) -> SessionTable

@external(erlang, "beacon_session_ffi", "table_name")
fn table_name(table: SessionTable) -> String

@external(erlang, "beacon_session_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "beacon_session_ffi", "session_ets_insert_new")
fn session_ets_insert_new(
  table: SessionTable,
  id: String,
  version: Int,
  now: Int,
  session: Session,
) -> Bool

@external(erlang, "beacon_session_ffi", "session_ets_lookup")
fn session_ets_lookup(
  table: SessionTable,
  id: String,
) -> Result(#(Int, Int, Int, Session), Nil)

@external(erlang, "beacon_session_ffi", "session_ets_cas")
fn session_ets_cas(
  table: SessionTable,
  id: String,
  expected_version: Int,
  row: #(String, Int, Int, Int, Session),
) -> Bool

@external(erlang, "beacon_session_ffi", "session_ets_touch")
fn session_ets_touch(table: SessionTable, id: String, now: Int) -> Bool

@external(erlang, "beacon_session_ffi", "session_ets_delete")
fn session_ets_delete(table: SessionTable, key: String) -> Nil

@external(erlang, "beacon_session_ffi", "session_ets_delete_if_version")
fn session_ets_delete_if_version(
  table: SessionTable,
  id: String,
  version: Int,
) -> Bool

@external(erlang, "beacon_session_ffi", "session_ets_expired_ids")
fn session_ets_expired_ids(
  table: SessionTable,
  absolute_cutoff: Int,
  idle_cutoff: Int,
) -> List(#(String, Int))

@external(erlang, "beacon_session_ffi", "session_ets_size")
fn session_ets_size(table: SessionTable) -> Int

@external(erlang, "beacon_session_ffi", "generate_session_id")
fn generate_session_id() -> String

@external(erlang, "beacon_session_ffi", "binding_fingerprint")
fn ffi_binding_fingerprint(session_id: String) -> String

@external(erlang, "beacon_session_ffi", "constant_time_equal")
fn constant_time_equal(a: String, b: String) -> Bool

@external(erlang, "beacon_session_ffi", "bind_process")
fn bind_process(table_name: String, session_id: String, pid: Pid) -> Int

@external(erlang, "beacon_session_ffi", "bound_process_count")
fn ffi_bound_process_count(table_name: String, session_id: String) -> Int

@external(erlang, "beacon_session_ffi", "notify_revoked")
fn notify_revoked(table_name: String, session_id: String, reason: String) -> Int

@external(erlang, "beacon_session_ffi", "start_sweeper")
fn start_sweeper(owner: Pid, interval_ms: Int, sweep: fn() -> Nil) -> Pid
