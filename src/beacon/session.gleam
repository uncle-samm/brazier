/// Cookie-based session management.
/// A session id lives in a cookie; the session data lives server-side in a
/// backend: `LocalEts` (an ETS table on this node, the default) or
/// `External` (functions you supply, for example over Postgres, shared by
/// every node).
///
/// Security properties:
/// - Every session has an absolute lifetime and an idle lifetime. Expired
///   sessions are never returned by `get`, are deleted lazily on access, and
///   are swept periodically by a maintenance process tied to the store owner.
/// - Writes (`set`) are atomic compare-and-swap updates: concurrent writers
///   never lose each other's keys, and a write never resurrects a session
///   that was deleted (logout) or expired.
/// - `rotate` issues a fresh session id carrying the same data and deletes
///   the old id. Use it on login and on any privilege change (OWASP session
///   fixation guidance).
/// - Live WebSocket connections can bind to a session id
///   (`bind_current_process`). Deleting, rotating, or expiring the session
///   sends `{beacon_session_revoked, Id, Reason}` to every bound process on
///   every connected node; the transport closes those sockets.
/// - A revocation sent during a netsplit cannot reach the other side. When
///   a node connects, every store re-checks the sessions its local
///   processes are bound to and revokes those that are gone.
///
/// Clustering: `LocalEts` data exists only on the node that created it, so
/// a cluster needs a sticky load balancer (a warning is logged when a
/// LocalEts store is used on a distributed node). `External` shares data
/// between nodes. Timestamps are `erlang:system_time(millisecond)` so that
/// nodes can compare them; clocks may differ by up to
/// `clock_skew_tolerance_ms`, so a lifetime can end up to that much early
/// or late. A timestamp further in the future than the tolerance means a
/// broken clock: the session is treated as expired and an error is logged.
///
/// Telemetry: `[beacon, session, created | revoked | expired | contention]`
/// with `count` 1 and a bounded `reason`, emitted only after the backend
/// confirmed the change:
/// - `created`: `"create"` or `"rotate"` (the fresh id of a rotation).
/// - `revoked`: `"deleted"` (logout) or `"rotated"` (the old id).
/// - `expired`: `"absolute_ttl"`, `"idle_ttl"` or `"clock_skew"` when a
///   lookup finds the row past its lifetime, `"sweep"` from the sweeper.
/// - `contention`: `"update"` when a write loses every compare-and-swap
///   attempt, `"rotate"` when the row changed during a rotation.
///
/// Reference: OWASP Session Management Cheat Sheet; Phoenix
/// `live_socket_id` disconnect broadcasts; Plug.Session stores.
import beacon/cookie
import beacon/log
import beacon/telemetry
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const module_name = "beacon.session"

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

/// Where a store keeps its sessions.
pub type SessionBackend {
  /// An ETS table on this node. Sessions are not shared between nodes.
  LocalEts(name: String)
  /// Functions over shared storage, used the same way from every node.
  External(backend: ExternalBackend)
}

/// A session row as a backend stores it. `version` increases on every data
/// write; times are `erlang:system_time(millisecond)`.
pub type StoredSession {
  StoredSession(
    session: Session,
    version: Int,
    created_at_ms: Int,
    last_seen_ms: Int,
  )
}

/// Storage operations for an `External` backend. Each returns
/// `Error(reason)` when the storage fails; Beacon logs it and returns
/// `SessionBackendFailed(reason)`. Every operation must be atomic on its
/// own; Beacon builds updates and rotation from them.
pub type ExternalBackend {
  ExternalBackend(
    /// Names the store in logs and in the live-connection registry. Every
    /// node using the same storage must use the same name.
    name: String,
    /// Insert a new row. `Ok(False)` when the id already exists.
    create: fn(StoredSession) -> Result(Bool, String),
    /// The row for an id, `Ok(None)` when there is none. Lifetimes are
    /// checked by Beacon.
    fetch: fn(String) -> Result(Option(StoredSession), String),
    /// Set a row's `last_seen_ms`. `Ok(False)` when the row is gone. Must
    /// not create a row.
    touch: fn(String, Int) -> Result(Bool, String),
    /// Replace the row with the same id only if its version is still the
    /// given one (compare-and-swap). `Ok(False)` when it is not.
    replace: fn(StoredSession, Int) -> Result(Bool, String),
    /// Delete a row. Deleting a missing row succeeds.
    delete: fn(String) -> Result(Nil, String),
    /// Delete a row only if its version is still the given one.
    delete_version: fn(String, Int) -> Result(Bool, String),
    /// Up to `limit` `#(id, version)` pairs of rows created before the
    /// first cutoff or last seen before the second.
    expired: fn(Int, Int, Int) -> Result(List(#(String, Int)), String),
    /// The number of rows.
    count: fn() -> Result(Int, String),
  )
}

/// A session store handle.
pub opaque type SessionStore {
  SessionStore(
    backend: Backend,
    /// Name used in logs.
    name: String,
    /// Live-connection registry namespace (the same on every node).
    namespace: String,
    config: StoreConfig,
  )
}

type Backend {
  Ets(table: SessionTable)
  Ext(ExternalBackend)
}

/// Opaque ETS table reference.
pub type SessionTable

/// Why a session operation failed.
pub type SessionStoreError {
  /// The session does not exist: never created, deleted, or rotated away.
  SessionNotFound
  /// The session existed but its absolute or idle lifetime has passed.
  SessionExpired
  /// The compare-and-swap lost too many races in a row. This indicates a
  /// pathological write storm on one session and is reported, never hidden.
  SessionContention
  /// An `External` backend operation failed.
  SessionBackendFailed(reason: String)
  /// The backend configuration is invalid.
  InvalidBackend(reason: String)
}

/// Why a bound process was told its session is gone.
pub type RevocationReason {
  /// The session was deleted (logout), or was found missing when the
  /// bindings were re-checked after a node connected.
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

/// How far apart node clocks may be. A stored timestamp up to this far in
/// the future is accepted; one further ahead is rejected.
pub const clock_skew_tolerance_ms = 5000

/// Bounded retries for the compare-and-swap loop in `set`/`update`.
/// A writer only loses a round when another write to the same session wins
/// it, so N concurrent writers need at most N attempts each; the bound is
/// set well above any realistic per-session concurrency (requests plus live
/// sockets of one user) and the loop yields between attempts.
const max_cas_attempts = 1024

/// Expired rows handled per sweep batch. A sweep runs batches until one is
/// short, so this bounds memory per batch, not the work per sweep.
const sweep_batch = 1000

const max_name_bytes = 255

/// Default store lifetimes (24h absolute, 2h idle, sweep every minute).
pub fn default_store_config() -> StoreConfig {
  StoreConfig(
    absolute_ttl_ms: default_absolute_ttl_ms,
    idle_ttl_ms: default_idle_ttl_ms,
    sweep_interval_ms: default_sweep_interval_ms,
  )
}

/// Create a new LocalEts session store with default lifetimes.
///
/// The ETS table is owned by the calling process; the maintenance process
/// (sweeper and re-checks) exits when that process exits.
pub fn new_store(name: String) -> SessionStore {
  new_store_with_config(name, default_store_config())
}

/// Create a new LocalEts session store with explicit lifetimes.
pub fn new_store_with_config(
  name: String,
  config: StoreConfig,
) -> SessionStore {
  // Invariant: LocalEts names are developer constants (they become an ETS
  // table name); the FFI also refuses names that are not [A-Za-z0-9_-]+.
  // An invalid constant is a programming error caught at startup.
  let assert Ok(store) = start_store(LocalEts(name), config)
    as "invalid LocalEts session store name or config; see the error log"
  store
}

/// Create a session store on any backend. The calling process owns it: a
/// LocalEts table and the maintenance process live as long as it does.
pub fn start_store(
  backend: SessionBackend,
  config: StoreConfig,
) -> Result(SessionStore, SessionStoreError) {
  use Nil <- result.try(validate_config(config))
  use store <- result.try(case backend {
    LocalEts(name) -> {
      use Nil <- result.try(validate_name("LocalEts name", name))
      let table = session_ets_new(name)
      let table_name = table_name(table)
      Ok(SessionStore(
        backend: Ets(table),
        name: table_name,
        namespace: table_name,
        config: config,
      ))
    }
    External(ext) -> {
      use Nil <- result.try(validate_name("External name", ext.name))
      Ok(SessionStore(
        backend: Ext(ext),
        name: "external " <> ext.name,
        namespace: "external:" <> ext.name,
        config: config,
      ))
    }
  })
  // Join the registry scope now, so the scope has synced with the other
  // nodes before the first revocation needs their members.
  ensure_registry()
  // The maintenance process monitors the owner (this process) and exits
  // when it dies, so its Pid does not need to be kept.
  start_maintenance(
    process.self(),
    config.sweep_interval_ms,
    fn() { sweep_in_background(store) },
    fn(joined) { recheck_bound(store, joined) },
  )
  log.info(
    module_name,
    "Created session store "
      <> store.name
      <> " (absolute_ttl_ms="
      <> int.to_string(config.absolute_ttl_ms)
      <> ", idle_ttl_ms="
      <> int.to_string(config.idle_ttl_ms)
      <> ")",
  )
  warn_if_local_and_clustered(store, "created on a distributed node")
  Ok(store)
}

fn validate_config(config: StoreConfig) -> Result(Nil, SessionStoreError) {
  // Lifetimes must be positive or every session is born expired (or the
  // sweeper spins).
  case
    config.absolute_ttl_ms > 0
    && config.idle_ttl_ms > 0
    && config.sweep_interval_ms > 0
  {
    True -> Ok(Nil)
    False -> invalid_backend("lifetimes and sweep interval must be positive")
  }
}

fn validate_name(what: String, name: String) -> Result(Nil, SessionStoreError) {
  let size = bit_array.byte_size(<<name:utf8>>)
  case size {
    0 -> invalid_backend(what <> " is empty")
    _ if size > max_name_bytes ->
      invalid_backend(
        what <> " is longer than " <> int.to_string(max_name_bytes) <> " bytes",
      )
    _ -> Ok(Nil)
  }
}

fn invalid_backend(reason: String) -> Result(a, SessionStoreError) {
  log.error(module_name, "Invalid session store: " <> reason)
  Error(InvalidBackend(reason))
}

fn warn_if_local_and_clustered(store: SessionStore, context: String) -> Nil {
  case store.backend, is_distributed() {
    Ets(_), True ->
      log.warning(
        module_name,
        "LocalEts session store "
          <> store.name
          <> " "
          <> context
          <> ": sessions exist only on this node, so a cluster needs a sticky "
          <> "load balancer; use an External backend to share them",
      )
    Ets(_), False | Ext(_), _ -> Nil
  }
}

/// The lifetime configuration of a store.
pub fn store_config(store: SessionStore) -> StoreConfig {
  store.config
}

/// Create a new session with a generated ID.
///
/// Crashes the calling process if an External backend fails (see
/// `try_create_with_data`).
pub fn create(store: SessionStore) -> Session {
  create_with_data(store, dict.new())
}

/// Create a new session with a generated ID and initial data, in one write.
///
/// Crashes the calling process if an External backend fails (see
/// `try_create_with_data`).
pub fn create_with_data(
  store: SessionStore,
  data: Dict(String, String),
) -> Session {
  try_create_with_data(store, data) |> or_crash(store, "create")
}

/// Create a new session, returning backend failures.
pub fn try_create_with_data(
  store: SessionStore,
  data: Dict(String, String),
) -> Result(Session, SessionStoreError) {
  create_row(store, data, "create")
}

/// Insert a fresh row; `reason` labels the `created` event.
fn create_row(
  store: SessionStore,
  data: Dict(String, String),
  reason: String,
) -> Result(Session, SessionStoreError) {
  let id = generate_id()
  let session = Session(id: id, data: data)
  let now = now_ms()
  let row =
    StoredSession(
      session: session,
      version: 0,
      created_at_ms: now,
      last_seen_ms: now,
    )
  use inserted <- result.try(backend_create(store, row))
  // Invariant: 256-bit random ids do not collide. If the backend reports an
  // existing row the RNG is broken and continuing would hand one user's
  // session to another, so crash loudly.
  let assert True = inserted as "session id collision: the RNG is broken"
  log.debug(module_name, "Created session in " <> store.name)
  telemetry.session_event(telemetry.Created, reason)
  Ok(session)
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
/// Crashes the calling process if an External backend fails (see `fetch`).
pub fn get(store: SessionStore, id: String) -> Option(Session) {
  case fetch(store, id) {
    Ok(session) -> Some(session)
    Error(SessionNotFound) | Error(SessionExpired) | Error(SessionContention) ->
      None
    Error(SessionBackendFailed(reason)) ->
      Some(or_crash(Error(SessionBackendFailed(reason)), store, "get"))
    Error(InvalidBackend(reason)) ->
      Some(or_crash(Error(InvalidBackend(reason)), store, "get"))
  }
}

/// Get a live session by ID and refresh its idle deadline, returning why
/// there is none.
pub fn fetch(
  store: SessionStore,
  id: String,
) -> Result(Session, SessionStoreError) {
  use row <- result.try(lookup_live(store, id))
  // touch never recreates a row deleted concurrently; False means the
  // session vanished between lookup and touch.
  use touched <- result.try(backend_touch(store, id, now_ms()))
  case touched {
    True -> Ok(row.session)
    False -> {
      log.debug(
        module_name,
        "Session removed concurrently during get in " <> store.name,
      )
      Error(SessionNotFound)
    }
  }
}

/// Read a row, enforcing lifetimes. Expired rows are deleted and revoked.
fn lookup_live(
  store: SessionStore,
  id: String,
) -> Result(StoredSession, SessionStoreError) {
  use found <- result.try(backend_fetch(store, id))
  case found {
    None -> {
      log.debug(module_name, "Session not found in " <> store.name)
      Error(SessionNotFound)
    }
    Some(row) ->
      case liveness(store, now_ms(), row) {
        Live -> Ok(row)
        Ended(reason) -> {
          use Nil <- result.try(expire_row(store, id, row.version, reason))
          Error(SessionExpired)
        }
      }
  }
}

type Liveness {
  Live
  /// `reason` is the `expired` event's label.
  Ended(reason: String)
}

/// Whether a row is within its lifetimes. A timestamp further in the
/// future than the skew tolerance ends the session.
fn liveness(store: SessionStore, now: Int, row: StoredSession) -> Liveness {
  let ahead = int.max(row.created_at_ms, row.last_seen_ms) - now
  case ahead > clock_skew_tolerance_ms {
    True -> {
      log.error(
        module_name,
        "Session timestamp is "
          <> int.to_string(ahead)
          <> " ms in the future in "
          <> store.name
          <> " (tolerance "
          <> int.to_string(clock_skew_tolerance_ms)
          <> " ms): a node clock is wrong; treating the session as expired",
      )
      Ended("clock_skew")
    }
    False ->
      case
        now - row.created_at_ms >= store.config.absolute_ttl_ms,
        now - row.last_seen_ms >= store.config.idle_ttl_ms
      {
        True, _ -> Ended("absolute_ttl")
        False, True -> Ended("idle_ttl")
        False, False -> Live
      }
  }
}

/// Delete an expired row (only if unchanged) and notify bound sockets.
fn expire_row(
  store: SessionStore,
  id: String,
  version: Int,
  reason: String,
) -> Result(Nil, SessionStoreError) {
  use deleted <- result.try(backend_delete_version(store, id, version))
  case deleted {
    True -> {
      log.info(
        module_name,
        "Session expired (" <> reason <> ") in " <> store.name,
      )
      telemetry.session_event(telemetry.Expired, reason)
      revoke_bound(store, id, Expired)
    }
    False ->
      log.debug(
        module_name,
        "Expired session already changed or removed in " <> store.name,
      )
  }
  Ok(Nil)
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
  let outcome = update_loop(store, id, transform, max_cas_attempts)
  case outcome {
    Ok(_) -> log.debug(module_name, "Updated session")
    Error(SessionNotFound) ->
      log.warning(
        module_name,
        "Refusing to write missing session in " <> store.name,
      )
    Error(SessionExpired) ->
      log.warning(
        module_name,
        "Refusing to write expired session in " <> store.name,
      )
    Error(SessionContention) -> {
      log.error(
        module_name,
        "Session write lost "
          <> int.to_string(max_cas_attempts)
          <> " compare-and-swap races in "
          <> store.name,
      )
      telemetry.session_event(telemetry.Contention, "update")
    }
    // Already logged where the backend failed.
    Error(SessionBackendFailed(_)) | Error(InvalidBackend(_)) -> Nil
  }
  outcome
}

fn update_loop(
  store: SessionStore,
  id: String,
  transform: fn(Dict(String, String)) -> Dict(String, String),
  attempts_left: Int,
) -> Result(Session, SessionStoreError) {
  use <- guard_attempts(attempts_left)
  use current <- result.try(lookup_live(store, id))
  let updated =
    Session(..current.session, data: transform(current.session.data))
  let row =
    StoredSession(
      ..current,
      session: updated,
      version: current.version + 1,
      last_seen_ms: now_ms(),
    )
  use swapped <- result.try(backend_replace(store, row, current.version))
  case swapped {
    True -> Ok(updated)
    False -> {
      // Let the winning writer finish before re-reading.
      erlang_yield()
      update_loop(store, id, transform, attempts_left - 1)
    }
  }
}

fn guard_attempts(
  attempts_left: Int,
  next: fn() -> Result(Session, SessionStoreError),
) -> Result(Session, SessionStoreError) {
  case attempts_left <= 0 {
    True -> Error(SessionContention)
    False -> next()
  }
}

/// Get a value from a session.
pub fn get_value(session: Session, key: String) -> Option(String) {
  case dict.get(session.data, key) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

/// Delete a session (logout). Bound WebSockets on every node are told to
/// close. Crashes the calling process if an External backend fails (see
/// `try_delete`).
pub fn delete(store: SessionStore, id: String) -> Nil {
  try_delete(store, id) |> or_crash(store, "delete")
}

/// Delete a session (logout), returning backend failures. Bound WebSockets
/// are told to close even when the backend fails, so a failed logout never
/// leaves a live socket behind; the session itself may still exist then.
pub fn try_delete(
  store: SessionStore,
  id: String,
) -> Result(Nil, SessionStoreError) {
  let deleted = backend_delete(store, id)
  case deleted {
    Ok(Nil) -> {
      log.info(module_name, "Deleted session in " <> store.name)
      telemetry.session_event(telemetry.Revoked, "deleted")
    }
    Error(_) ->
      log.error(
        module_name,
        "Session delete failed in "
          <> store.name
          <> "; closing its live connections anyway",
      )
  }
  revoke_bound(store, id, Deleted)
  deleted
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
        module_name,
        "Cannot rotate session in "
          <> store.name
          <> ": "
          <> store_error_to_string(err),
      )
      Error(err)
    }
    Ok(old) -> {
      use deleted <- result.try(backend_delete_version(
        store,
        old_id,
        old.version,
      ))
      case deleted {
        False -> {
          log.warning(
            module_name,
            "Session changed during rotation in " <> store.name,
          )
          telemetry.session_event(telemetry.Contention, "rotate")
          Error(SessionContention)
        }
        True -> {
          // The old id is gone from here on, so its sockets are told even
          // when creating the new one fails.
          telemetry.session_event(telemetry.Revoked, "rotated")
          revoke_bound(store, old_id, Rotated)
          use fresh <- result.try(create_row(store, old.session.data, "rotate"))
          log.info(module_name, "Rotated session in " <> store.name)
          Ok(fresh)
        }
      }
    }
  }
}

/// Delete every expired session and notify their bound sockets.
/// Returns how many sessions were removed. Runs automatically every
/// `sweep_interval_ms`; exposed for tests and manual maintenance.
pub fn sweep_expired(store: SessionStore) -> Result(Int, SessionStoreError) {
  let outcome = sweep_batches(store, 0)
  case outcome {
    Ok(0) -> log.debug(module_name, "Sweep found no expired sessions")
    Ok(n) ->
      log.info(
        module_name,
        "Swept "
          <> int.to_string(n)
          <> " expired session(s) from "
          <> store.name,
      )
    Error(err) ->
      log.error(
        module_name,
        "Sweep of " <> store.name <> " failed: " <> store_error_to_string(err),
      )
  }
  outcome
}

fn sweep_batches(
  store: SessionStore,
  removed_so_far: Int,
) -> Result(Int, SessionStoreError) {
  let now = now_ms()
  use expired <- result.try(backend_expired(
    store,
    now - store.config.absolute_ttl_ms,
    now - store.config.idle_ttl_ms,
    sweep_batch,
  ))
  use removed <- result.try(
    list.try_fold(expired, 0, fn(count, entry) {
      let #(id, version) = entry
      use deleted <- result.map(backend_delete_version(store, id, version))
      case deleted {
        True -> {
          telemetry.session_event(telemetry.Expired, "sweep")
          revoke_bound(store, id, Expired)
          count + 1
        }
        False -> count
      }
    }),
  )
  let total = removed_so_far + removed
  // A full batch may have more behind it. A full batch where nothing could
  // be deleted (every row changed meanwhile) stops the sweep so it cannot
  // spin; the next sweep picks those rows up.
  let full = list.length(expired) == sweep_batch
  case full, removed > 0 {
    True, True -> sweep_batches(store, total)
    True, False -> {
      log.warning(
        module_name,
        "Sweep of "
          <> store.name
          <> " deleted nothing from a full batch (rows changed meanwhile); "
          <> "stopping until the next sweep",
      )
      Ok(total)
    }
    False, _ -> Ok(total)
  }
}

fn sweep_in_background(store: SessionStore) -> Nil {
  // sweep_expired logs failures; the next interval retries.
  case sweep_expired(store) {
    Ok(_) -> Nil
    Error(_) -> Nil
  }
}

/// Number of rows currently stored (including not-yet-swept expired rows).
/// Crashes the calling process if an External backend fails.
pub fn count(store: SessionStore) -> Int {
  backend_count(store) |> or_crash(store, "count")
}

/// `create`, `create_with_data`, `get`, `delete` and `count` predate
/// External backends and have no error channel; `beacon/auth` builds on
/// them. A backend failure there crashes the calling (request) process
/// after logging, as a raising Plug.Session store does; the `try_` and
/// `fetch` variants return the error instead.
fn or_crash(
  outcome: Result(a, SessionStoreError),
  store: SessionStore,
  operation: String,
) -> a {
  case outcome {
    Ok(_) -> Nil
    Error(err) ->
      log.error(
        module_name,
        "Session "
          <> operation
          <> " failed in "
          <> store.name
          <> ": "
          <> store_error_to_string(err)
          <> "; crashing the caller (use the try_ variant to handle it)",
      )
  }
  let assert Ok(value) = outcome
    as "session backend failed in an operation with no error channel"
  value
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
/// When the session is deleted, rotated, or expires (on any connected
/// node), the process receives `{beacon_session_revoked, SessionId,
/// ReasonBinary}`. Binding is idempotent and is released automatically when
/// the process exits.
pub fn bind_current_process(store: SessionStore, session_id: String) -> Nil {
  let members = bind_process(store.namespace, session_id, process.self())
  log.debug(
    module_name,
    "Bound process to session in "
      <> store.name
      <> " ("
      <> int.to_string(members)
      <> " bound on this node)",
  )
}

/// How many live processes on this node are bound to a session id.
pub fn bound_process_count(store: SessionStore, session_id: String) -> Int {
  ffi_bound_process_count(store.namespace, session_id)
}

/// Tell every bound process on every connected node.
fn revoke_bound(
  store: SessionStore,
  id: String,
  reason: RevocationReason,
) -> Nil {
  let reason_str = revocation_reason_to_string(reason)
  let notified = notify_revoked(store.namespace, id, reason_str)
  log_revoked(store, notified, reason_str, "")
}

fn log_revoked(
  store: SessionStore,
  notified: Int,
  reason: String,
  context: String,
) -> Nil {
  case notified {
    0 -> Nil
    n ->
      log.info(
        module_name,
        "Revoked "
          <> int.to_string(n)
          <> " live connection(s) for "
          <> reason
          <> " session in "
          <> store.name
          <> context,
      )
  }
}

/// After a node connects, check every session a local process is bound to
/// and revoke the ones that are gone: a revocation sent while the nodes
/// were apart never arrived. Runs in the maintenance process.
fn recheck_bound(store: SessionStore, joined: Node) -> Nil {
  let joined_name = atom.to_string(node.name(joined))
  warn_if_local_and_clustered(store, "used while " <> joined_name <> " joined")
  let ids = local_bound_sessions(store.namespace)
  log.info(
    module_name,
    "Node "
      <> joined_name
      <> " connected; re-checking "
      <> int.to_string(list.length(ids))
      <> " bound session(s) in "
      <> store.name,
  )
  let #(revoked, failed) =
    list.fold(ids, #(0, 0), fn(acc, id) {
      let #(revoked, failed) = acc
      case lookup_live(store, id) {
        Ok(_) -> acc
        // lookup_live already deleted the row and revoked its bindings.
        Error(SessionExpired) -> #(revoked + 1, failed)
        Error(SessionNotFound) -> {
          let notified =
            notify_revoked_local(
              store.namespace,
              id,
              revocation_reason_to_string(Deleted),
            )
          log_revoked(store, notified, "deleted", " (re-check)")
          #(revoked + 1, failed)
        }
        Error(SessionContention)
        | Error(SessionBackendFailed(_))
        | Error(InvalidBackend(_)) -> #(revoked, failed + 1)
      }
    })
  case failed {
    0 ->
      log.info(
        module_name,
        "Re-check of "
          <> store.name
          <> " revoked "
          <> int.to_string(revoked)
          <> " session(s)",
      )
    _ ->
      log.error(
        module_name,
        "Re-check of "
          <> store.name
          <> " could not check "
          <> int.to_string(failed)
          <> " session(s); their sockets stay open until the transport's "
          <> "periodic auth re-check",
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
    SessionBackendFailed(reason) -> "session backend failed: " <> reason
    InvalidBackend(reason) -> "invalid session store: " <> reason
  }
}

/// Constant-time string comparison for secrets such as CSRF tokens.
pub fn secure_compare(a: String, b: String) -> Bool {
  constant_time_equal(a, b)
}

// === Backend dispatch ===

fn backend_create(
  store: SessionStore,
  row: StoredSession,
) -> Result(Bool, SessionStoreError) {
  case store.backend {
    Ets(table) ->
      Ok(session_ets_insert_new(
        table,
        row.session.id,
        row.version,
        row.created_at_ms,
        row.session,
      ))
    Ext(ext) -> external(store, "create", ext.create(row))
  }
}

fn backend_fetch(
  store: SessionStore,
  id: String,
) -> Result(Option(StoredSession), SessionStoreError) {
  case store.backend {
    Ets(table) ->
      case session_ets_lookup(table, id) {
        Ok(#(version, created_at, last_seen, session)) ->
          Ok(
            Some(StoredSession(
              session: session,
              version: version,
              created_at_ms: created_at,
              last_seen_ms: last_seen,
            )),
          )
        Error(Nil) -> Ok(None)
      }
    Ext(ext) -> external(store, "fetch", ext.fetch(id))
  }
}

fn backend_touch(
  store: SessionStore,
  id: String,
  now: Int,
) -> Result(Bool, SessionStoreError) {
  case store.backend {
    Ets(table) -> Ok(session_ets_touch(table, id, now))
    Ext(ext) -> external(store, "touch", ext.touch(id, now))
  }
}

fn backend_replace(
  store: SessionStore,
  row: StoredSession,
  expected_version: Int,
) -> Result(Bool, SessionStoreError) {
  case store.backend {
    Ets(table) ->
      Ok(
        session_ets_cas(table, row.session.id, expected_version, #(
          row.session.id,
          row.version,
          row.created_at_ms,
          row.last_seen_ms,
          row.session,
        )),
      )
    Ext(ext) -> external(store, "replace", ext.replace(row, expected_version))
  }
}

fn backend_delete(
  store: SessionStore,
  id: String,
) -> Result(Nil, SessionStoreError) {
  case store.backend {
    Ets(table) -> Ok(session_ets_delete(table, id))
    Ext(ext) -> external(store, "delete", ext.delete(id))
  }
}

fn backend_delete_version(
  store: SessionStore,
  id: String,
  version: Int,
) -> Result(Bool, SessionStoreError) {
  case store.backend {
    Ets(table) -> Ok(session_ets_delete_if_version(table, id, version))
    Ext(ext) ->
      external(store, "delete_version", ext.delete_version(id, version))
  }
}

fn backend_expired(
  store: SessionStore,
  absolute_cutoff: Int,
  idle_cutoff: Int,
  limit: Int,
) -> Result(List(#(String, Int)), SessionStoreError) {
  case store.backend {
    Ets(table) ->
      Ok(session_ets_expired_ids(table, absolute_cutoff, idle_cutoff, limit))
    Ext(ext) -> {
      use rows <- result.try(external(
        store,
        "expired",
        ext.expired(absolute_cutoff, idle_cutoff, limit),
      ))
      // A backend returning more than asked breaks the batch bound.
      case list.length(rows) > limit {
        True -> {
          let reason =
            "expired returned more than " <> int.to_string(limit) <> " rows"
          log.error(
            module_name,
            "Session backend " <> store.name <> ": " <> reason,
          )
          Error(SessionBackendFailed(reason))
        }
        False -> Ok(rows)
      }
    }
  }
}

fn backend_count(store: SessionStore) -> Result(Int, SessionStoreError) {
  case store.backend {
    Ets(table) -> Ok(session_ets_size(table))
    Ext(ext) -> external(store, "count", ext.count())
  }
}

fn external(
  store: SessionStore,
  operation: String,
  outcome: Result(a, String),
) -> Result(a, SessionStoreError) {
  case outcome {
    Ok(value) -> Ok(value)
    Error(reason) -> {
      log.error(
        module_name,
        "Session backend "
          <> store.name
          <> " failed in "
          <> operation
          <> ": "
          <> reason,
      )
      Error(SessionBackendFailed(reason))
    }
  }
}

// === FFI ===

@external(erlang, "erlang", "yield")
fn erlang_yield() -> Bool

@external(erlang, "erlang", "is_alive")
fn is_distributed() -> Bool

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
  limit: Int,
) -> List(#(String, Int))

@external(erlang, "beacon_session_ffi", "session_ets_size")
fn session_ets_size(table: SessionTable) -> Int

@external(erlang, "beacon_session_ffi", "generate_session_id")
fn generate_session_id() -> String

@external(erlang, "beacon_session_ffi", "binding_fingerprint")
fn ffi_binding_fingerprint(session_id: String) -> String

@external(erlang, "beacon_session_ffi", "constant_time_equal")
fn constant_time_equal(a: String, b: String) -> Bool

@external(erlang, "beacon_session_ffi", "ensure_registry")
fn ensure_registry() -> Nil

@external(erlang, "beacon_session_ffi", "bind_process")
fn bind_process(namespace: String, session_id: String, pid: Pid) -> Int

@external(erlang, "beacon_session_ffi", "bound_process_count")
fn ffi_bound_process_count(namespace: String, session_id: String) -> Int

@external(erlang, "beacon_session_ffi", "notify_revoked")
fn notify_revoked(namespace: String, session_id: String, reason: String) -> Int

@external(erlang, "beacon_session_ffi", "notify_revoked_local")
fn notify_revoked_local(
  namespace: String,
  session_id: String,
  reason: String,
) -> Int

@external(erlang, "beacon_session_ffi", "local_bound_sessions")
fn local_bound_sessions(namespace: String) -> List(String)

@external(erlang, "beacon_session_ffi", "start_maintenance")
fn start_maintenance(
  owner: Pid,
  interval_ms: Int,
  sweep: fn() -> Nil,
  recheck: fn(Node) -> Nil,
) -> Pid
