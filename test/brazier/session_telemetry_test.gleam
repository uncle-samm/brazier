/// Session lifecycle telemetry: `[brazier, session, created | revoked |
/// expired | contention]`, emitted only after the backend confirmed the
/// change.
///
/// Expiry, contention and backend failures come from fake External
/// backends whose functions answer fixed values, so every path is reached
/// deterministically without waiting for a clock.
import brazier/monitored
import brazier/session.{
  type ExternalBackend, type SessionStore, type StoredSession, External,
  ExternalBackend, LocalEts, Session, SessionBackendFailed, SessionContention,
  SessionExpired, StoredSession,
}
import brazier/telemetry.{type Event}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}

const session_events = [
  ["brazier", "session", "created"],
  ["brazier", "session", "revoked"],
  ["brazier", "session", "expired"],
  ["brazier", "session", "contention"],
]

/// Run `run` with this process's own session events forwarded to it; the
/// handler is detached afterwards even if `run` crashes.
fn listen(run: fn(Subject(Event)) -> a) -> a {
  let id = "session_telemetry_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let owner = process.self()
  // Handlers run in the emitting process. Only events emitted by this test
  // process are forwarded, so a sweeper of some other test's store can
  // never add to the exact sequences asserted below.
  use <- monitored.with_handler(id, session_events, fn(event) {
    case process.self() == owner {
      True -> process.send(events, event)
      False -> Nil
    }
  })
  run(events)
}

/// Every session event received so far, oldest first. Session events are
/// emitted in the calling process, so they are already in the mailbox when
/// the operation returns: a zero timeout drains them without waiting.
fn drain(events: Subject(Event)) -> List(#(String, String)) {
  drain_loop(events, [])
}

fn drain_loop(
  events: Subject(Event),
  acc: List(#(String, String)),
) -> List(#(String, String)) {
  case process.receive(events, 0) {
    Error(Nil) -> list.reverse(acc)
    Ok(event) -> {
      let assert [_, _, kind] = event.name as "event.name is [_, _, kind]"
      let assert Ok(1) = telemetry.int(event, "count")
        as "telemetry.int succeeds"
      let assert Ok(reason) = telemetry.string(event, "reason")
        as "telemetry.string succeeds"
      drain_loop(events, [#(kind, reason), ..acc])
    }
  }
}

fn local_store() -> SessionStore {
  let assert Ok(store) =
    session.start_store(
      LocalEts("session_telemetry_" <> int.to_string(unique_integer())),
      session.default_store_config(),
    )
    as "session.start_store succeeds"
  store
}

fn row(created_at: Int, last_seen: Int) -> StoredSession {
  StoredSession(
    session: Session(id: "fake", data: dict.from_list([#("user", "u1")])),
    version: 0,
    created_at_ms: created_at,
    last_seen_ms: last_seen,
  )
}

/// A backend holding one row that every operation succeeds on.
fn fake(stored: StoredSession) -> ExternalBackend {
  ExternalBackend(
    name: "fake_" <> int.to_string(unique_integer()),
    create: fn(_) { Ok(True) },
    fetch: fn(_) { Ok(Some(stored)) },
    touch: fn(_, _) { Ok(True) },
    replace: fn(_, _) { Ok(True) },
    delete: fn(_) { Ok(Nil) },
    delete_version: fn(_, _) { Ok(True) },
    expired: fn(_, _, _) { Ok([]) },
    count: fn() { Ok(1) },
  )
}

fn external_store(ext: ExternalBackend) -> SessionStore {
  let assert Ok(store) =
    session.start_store(External(ext), session.default_store_config())
    as "session.start_store succeeds"
  store
}

pub fn create_delete_and_rotate_emit_lifecycle_events_test() {
  use events <- listen()
  let store = local_store()
  let assert Ok(first) = session.try_create_with_data(store, dict.new())
    as "session.try_create_with_data succeeds"
  let assert Ok(second) = session.rotate(store, first.id)
    as "session.rotate succeeds"
  let assert Ok(Nil) = session.try_delete(store, second.id)
    as "session.try_delete succeeds"
  assert drain(events)
    == [
      #("created", "create"),
      #("revoked", "rotated"),
      #("created", "rotate"),
      #("revoked", "deleted"),
    ]
}

pub fn lookups_past_a_lifetime_emit_expired_with_the_cause_test() {
  use events <- listen()
  let now = system_now()
  let absolute = external_store(fake(row(0, now)))
  let idle = external_store(fake(row(now, now - session.default_idle_ttl_ms)))
  let skewed =
    external_store(fake(row(now + session.clock_skew_tolerance_ms * 10, now)))
  let assert Error(SessionExpired) = session.fetch(absolute, "fake")
    as "session.fetch returns Error(SessionExpired)"
  let assert Error(SessionExpired) = session.fetch(idle, "fake")
    as "session.fetch returns Error(SessionExpired)"
  let assert Error(SessionExpired) = session.fetch(skewed, "fake")
    as "session.fetch returns Error(SessionExpired)"
  assert drain(events)
    == [
      #("expired", "absolute_ttl"),
      #("expired", "idle_ttl"),
      #("expired", "clock_skew"),
    ]
}

pub fn expiry_lost_to_a_concurrent_change_emits_nothing_test() {
  use events <- listen()
  let ext =
    ExternalBackend(..fake(row(0, system_now())), delete_version: fn(_, _) {
      Ok(False)
    })
  let assert Error(SessionExpired) = session.fetch(external_store(ext), "fake")
    as "session.fetch returns Error(SessionExpired)"
  let assert [] = drain(events) as "drain returns []"
}

pub fn sweep_emits_one_expired_event_per_deleted_row_test() {
  use events <- listen()
  let ext =
    ExternalBackend(..fake(row(0, 0)), expired: fn(_, _, _) {
      Ok([#("a", 0), #("b", 3)])
    })
  let assert Ok(2) = session.sweep_expired(external_store(ext))
    as "session.sweep_expired succeeds"
  let assert [#("expired", "sweep"), #("expired", "sweep")] = drain(events)
    as "drain returns [#(..)"
}

pub fn update_that_loses_every_race_emits_contention_test() {
  use events <- listen()
  let now = system_now()
  let ext =
    ExternalBackend(..fake(row(now, now)), replace: fn(_, _) { Ok(False) })
  let assert Error(SessionContention) =
    session.update(external_store(ext), "fake", fn(data) { data })
    as "session.update returns Error(SessionContention)"
  let assert [#("contention", "update")] = drain(events)
    as "drain returns [#('contention', 'update')]"
}

pub fn rotate_racing_a_write_emits_contention_test() {
  use events <- listen()
  let now = system_now()
  let ext =
    ExternalBackend(..fake(row(now, now)), delete_version: fn(_, _) {
      Ok(False)
    })
  let assert Error(SessionContention) =
    session.rotate(external_store(ext), "fake")
    as "session.rotate returns Error(SessionContention)"
  let assert [#("contention", "rotate")] = drain(events)
    as "drain returns [#('contention', 'rotate')]"
}

pub fn failed_backend_writes_emit_no_lifecycle_event_test() {
  use events <- listen()
  let now = system_now()
  let ext =
    ExternalBackend(
      ..fake(row(now, now)),
      create: fn(_) { Error("database down") },
      delete: fn(_) { Error("database down") },
    )
  let store = external_store(ext)
  let assert Error(SessionBackendFailed("database down")) =
    session.try_create_with_data(store, dict.new())
    as "session.try_create_with_data returns Error(..)"
  let assert Error(SessionBackendFailed("database down")) =
    session.try_delete(store, "fake")
    as "session.try_delete returns Error(..)"
  // A rotation that deleted the old id but could not create the new one
  // reports the revocation and no creation.
  let assert Error(SessionBackendFailed("database down")) =
    session.rotate(store, "fake")
    as "session.rotate returns Error(..)"
  let assert [#("revoked", "rotated")] = drain(events)
    as "drain returns [#('revoked', 'rotated')]"
}

pub fn unknown_session_emits_nothing_test() {
  use events <- listen()
  let ext = ExternalBackend(..fake(row(0, 0)), fetch: fn(_) { Ok(None) })
  let assert Error(session.SessionNotFound) =
    session.fetch(external_store(ext), "fake")
    as "session.fetch returns Error(session.SessionNotFound)"
  let assert [] = drain(events) as "drain returns []"
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "brazier_session_test_ffi", "system_now")
fn system_now() -> Int
