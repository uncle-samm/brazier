/// Session security: lifetimes, atomic writes, rotation, revocation.
/// Unhappy paths first.
import brazier/api
import brazier/auth
import brazier/await
import brazier/log_capture
import brazier/session
import brazier/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

/// A LocalEts store whose wall clock only moves when the test advances it.
fn clocked_store(
  name: String,
  config: session.StoreConfig,
) -> #(session.SessionStore, ManualClock) {
  let clock = new_clock(1_000_000)
  let assert Ok(store) =
    session.start_store_with_clock(session.LocalEts(name), config, fn() {
      clock_now(clock)
    })
  #(store, clock)
}

fn short_idle_store(name: String) -> #(session.SessionStore, ManualClock) {
  clocked_store(
    name,
    session.StoreConfig(
      absolute_ttl_ms: 60_000,
      idle_ttl_ms: 40,
      sweep_interval_ms: 60_000,
    ),
  )
}

// --- Expiry ---

// Lifetimes are read from the store's clock, which these tests advance by
// hand: no test sleeps, and every boundary is exact.

pub fn idle_expired_session_is_rejected_test() {
  let #(store, clock) = short_idle_store("sec_idle_expired")
  let sess = session.create(store)
  advance(clock, 39)
  let assert Some(_) = session.get(store, sess.id)
  // That read touched the session; idle time restarts from it.
  advance(clock, 40)
  should.equal(session.get(store, sess.id), None)
  // Expired rows are deleted on access, not left behind.
  should.equal(session.count(store), 0)
}

pub fn write_to_expired_session_is_rejected_and_not_resurrected_test() {
  let #(store, clock) = short_idle_store("sec_write_expired")
  let sess = session.create(store)
  advance(clock, 40)
  should.equal(
    session.set(store, sess, "k", "v"),
    Error(session.SessionExpired),
  )
  should.equal(session.count(store), 0)
  should.equal(session.get(store, sess.id), None)
}

pub fn absolute_lifetime_is_enforced_despite_activity_test() {
  let #(store, clock) =
    clocked_store(
      "sec_absolute_expired",
      session.StoreConfig(
        absolute_ttl_ms: 100,
        idle_ttl_ms: 60_000,
        sweep_interval_ms: 60_000,
      ),
    )
  let sess = session.create(store)
  // Keep it busy: idle never passes, absolute does.
  list.each(seq(1, 3), fn(_) {
    advance(clock, 33)
    let assert Some(_) = session.get(store, sess.id)
    Nil
  })
  // 99 ms old: still alive. 100 ms old: gone, however recently touched.
  advance(clock, 1)
  should.equal(session.get(store, sess.id), None)
}

pub fn activity_extends_idle_lifetime_test() {
  let #(store, clock) =
    clocked_store(
      "sec_idle_extend",
      session.StoreConfig(
        absolute_ttl_ms: 60_000,
        idle_ttl_ms: 400,
        sweep_interval_ms: 60_000,
      ),
    )
  let sess = session.create(store)
  // Four touches 399 ms apart span 1596 ms, four times the idle TTL.
  list.each(seq(1, 4), fn(_) {
    advance(clock, 399)
    let assert Some(_) = session.get(store, sess.id)
    Nil
  })
  advance(clock, 400)
  should.equal(session.get(store, sess.id), None)
}

pub fn sweep_removes_expired_sessions_test() {
  let #(store, clock) =
    clocked_store(
      "sec_sweep_manual",
      session.StoreConfig(
        absolute_ttl_ms: 60_000,
        idle_ttl_ms: 500,
        sweep_interval_ms: 60_000,
      ),
    )
  let _a = session.create(store)
  let _b = session.create(store)
  should.equal(session.count(store), 2)
  advance(clock, 500)
  let live = session.create(store)
  should.equal(session.sweep_expired(store), Ok(2))
  should.equal(session.count(store), 1)
  let assert Some(_) = session.get(store, live.id)
}

pub fn background_sweeper_removes_expired_sessions_test() {
  let #(store, clock) =
    clocked_store(
      "sec_sweep_background",
      session.StoreConfig(
        absolute_ttl_ms: 60_000,
        idle_ttl_ms: 30,
        sweep_interval_ms: 20,
      ),
    )
  list.each(seq(1, 10), fn(_) {
    let _ = session.create(store)
    Nil
  })
  // The sweeper reads the same clock: nothing has expired yet.
  should.equal(session.count(store), 10)
  advance(clock, 30)
  // Nothing reads the sessions, so only the background sweeper removes
  // them. It emits one expired event per row, after deleting the row: each
  // event is a point to look, instead of sleeping and hoping enough sweeps
  // ran.
  await.until_telemetry(
    [["brazier", "session", "expired"]],
    "the background sweeper to empty the store",
    fn() { session.count(store) == 0 },
  )
}

// --- Writes never resurrect / never lose data ---

pub fn write_after_logout_does_not_resurrect_session_test() {
  let store = session.new_store("sec_no_resurrect")
  let sess = session.create(store)
  session.delete(store, sess.id)
  should.equal(
    session.set(store, sess, "user_id", "mallory"),
    Error(session.SessionNotFound),
  )
  should.equal(session.get(store, sess.id), None)
  should.equal(session.count(store), 0)
}

pub fn concurrent_set_does_not_lose_writes_test() {
  let store = session.new_store("sec_concurrent_set")
  let sess = session.create(store)
  let writers = 200
  let results =
    run_parallel(writers, fn(i) {
      session.set(store, sess, "k" <> int.to_string(i), int.to_string(i))
    })
  list.each(results, fn(r) {
    let assert Ok(_) = r
    Nil
  })
  let assert Some(found) = session.get(store, sess.id)
  should.equal(dict.size(found.data), writers)
  list.each(seq(1, writers), fn(i) {
    should.equal(
      session.get_value(found, "k" <> int.to_string(i)),
      Some(int.to_string(i)),
    )
  })
}

pub fn concurrent_update_increments_are_serialised_test() {
  let store = session.new_store("sec_concurrent_update")
  let sess =
    session.create_with_data(store, dict.from_list([#("counter", "0")]))
  let _ =
    run_parallel(50, fn(_) {
      session.update(store, sess.id, fn(data) {
        let assert Ok(raw) = dict.get(data, "counter")
          as "counter key is written at creation and never removed"
        let assert Ok(n) = int.parse(raw)
          as "counter is only ever written by int.to_string"
        dict.insert(data, "counter", int.to_string(n + 1))
      })
    })
  let assert Some(found) = session.get(store, sess.id)
  should.equal(session.get_value(found, "counter"), Some("50"))
}

// --- Rotation / fixation ---

pub fn rotate_makes_old_id_unusable_test() {
  let store = session.new_store("sec_rotate")
  let sess = session.create_with_data(store, dict.from_list([#("a", "1")]))
  let assert Ok(fresh) = session.rotate(store, sess.id)
  should.not_equal(fresh.id, sess.id)
  should.equal(session.get(store, sess.id), None)
  should.equal(
    session.set(store, sess, "a", "2"),
    Error(session.SessionNotFound),
  )
  let assert Some(found) = session.get(store, fresh.id)
  should.equal(session.get_value(found, "a"), Some("1"))
  // Rotating the dead id again fails loudly.
  should.equal(session.rotate(store, sess.id), Error(session.SessionNotFound))
}

pub fn old_session_id_unusable_after_login_test() {
  let store = session.new_store("sec_login_rotates")
  let config = auth.dev_session_config()
  // Attacker plants an anonymous session id in the victim's browser.
  let planted = session.create(store)
  let assert Ok(login) =
    auth.create_login_rotating(store, Some(planted.id), "victim")
  should.not_equal(login.session.id, planted.id)
  should.equal(session.get(store, planted.id), None)
  let req = cookie_request("GET", "/", config.cookie_name, planted.id)
  should.equal(
    auth.current_user_from_request(req, store, config),
    Error(auth.InvalidSession),
  )
  let req = cookie_request("GET", "/", config.cookie_name, login.session.id)
  should.equal(auth.current_user_from_request(req, store, config), Ok("victim"))
}

pub fn login_route_rotates_existing_cookie_test() {
  let store = session.new_store("sec_login_route_rotates")
  let config = auth.dev_session_config()
  let planted = session.create(store)
  let handler =
    api.routes([
      auth.login_route("/api/login", store, config, fn(_req) { Ok("user") }),
    ])
  let req = cookie_request("POST", "/api/login", config.cookie_name, planted.id)
  let assert Some(resp) = handler(req)
  should.equal(resp.status, 200)
  should.equal(session.get(store, planted.id), None)
  should.equal(session.count(store), 1)
}

pub fn change_privileges_rotates_and_applies_updates_test() {
  let store = session.new_store("sec_change_privileges")
  let assert Ok(login) = auth.create_login(store, "alice")
  let assert Ok(promoted) =
    auth.change_privileges(store, login.session.id, [#("role", "admin")])
  should.not_equal(promoted.session.id, login.session.id)
  should.not_equal(promoted.csrf_token, login.csrf_token)
  should.equal(session.get(store, login.session.id), None)
  let assert Some(found) = session.get(store, promoted.session.id)
  should.equal(session.get_value(found, "role"), Some("admin"))
  should.equal(auth.current_user(found), Ok("alice"))
}

pub fn change_privileges_on_dead_session_fails_test() {
  let store = session.new_store("sec_change_privileges_dead")
  let assert Ok(login) = auth.create_login(store, "alice")
  session.delete(store, login.session.id)
  should.equal(
    auth.change_privileges(store, login.session.id, [#("role", "admin")]),
    Error(auth.InvalidSession),
  )
  should.equal(session.count(store), 0)
}

// --- Live connection revocation ---

pub fn logout_notifies_bound_processes_test() {
  let store = session.new_store("sec_revoke_logout")
  let sess = session.create(store)
  let #(ready, result) = spawn_bound_watcher(store, sess.id)
  let assert Ok(Nil) = process.receive(ready, 1000)
  should.equal(session.bound_process_count(store, sess.id), 1)
  session.delete(store, sess.id)
  let assert Ok(Ok(#(id, reason))) = process.receive(result, 1000)
  should.equal(id, sess.id)
  should.equal(reason, "deleted")
}

pub fn rotation_notifies_bound_processes_test() {
  let store = session.new_store("sec_revoke_rotate")
  let sess = session.create(store)
  let #(ready, result) = spawn_bound_watcher(store, sess.id)
  let assert Ok(Nil) = process.receive(ready, 1000)
  let assert Ok(_fresh) = session.rotate(store, sess.id)
  let assert Ok(Ok(#(_, reason))) = process.receive(result, 1000)
  should.equal(reason, "rotated")
}

pub fn expiry_notifies_bound_processes_test() {
  let #(store, clock) =
    clocked_store(
      "sec_revoke_expire",
      session.StoreConfig(
        absolute_ttl_ms: 60_000,
        idle_ttl_ms: 30,
        sweep_interval_ms: 15,
      ),
    )
  let sess = session.create(store)
  let #(ready, result) = spawn_bound_watcher(store, sess.id)
  let assert Ok(Nil) = process.receive(ready, 1000)
  // The background sweeper finds the session expired once time passes.
  advance(clock, 30)
  let assert Ok(Ok(#(_, reason))) = process.receive(result, 1000)
  should.equal(reason, "expired")
}

pub fn bindings_are_released_when_process_exits_test() {
  let store = session.new_store("sec_binding_release")
  let sess = session.create(store)
  let ready = process.new_subject()
  // No application runs here: start the node-wide session scope.
  session.ensure_registry()
  use watch <- await.with_watch_pg_scope("brazier_session_pg")
  let pid =
    process.spawn(fn() {
      session.bind_current_process(store, sess.id)
      session.bind_current_process(store, sess.id)
      let release = process.new_subject()
      process.send(ready, release)
      // Stay bound until the test has counted.
      let assert Ok(Nil) = process.receive(release, await.deadline_ms)
      Nil
    })
  let assert Ok(release) = process.receive(ready, 1000)
  // Idempotent: binding twice is one membership.
  should.equal(session.bound_process_count(store, sess.id), 1)
  process.send(release, Nil)
  await.expect_down(pid, "the bound process")
  // pg drops a member when it exits; once it says so the count is final.
  await.expect_pg_leave(watch, pid, "the bound process")
  should.equal(session.bound_process_count(store, sess.id), 0)
}

pub fn ws_session_auth_binds_calling_process_test() {
  let store = session.new_store("sec_ws_auth_binds")
  let config = auth.dev_session_config()
  let assert Ok(login) = auth.create_login(store, "alice")
  let auth_fn = auth.ws_session_auth(store, config)
  let req = cookie_request("GET", "/ws", config.cookie_name, login.session.id)
  should.equal(auth_fn(req), Ok(Nil))
  should.equal(session.bound_process_count(store, login.session.id), 1)
  session.delete(store, login.session.id)
  let assert Ok(#(_, "deleted")) = receive_revoked(1000)
  // After logout the same request is rejected.
  should.equal(auth_fn(req), Error("invalid session"))
}

pub fn ws_session_auth_rejects_session_without_user_test() {
  let store = session.new_store("sec_ws_auth_no_user")
  let config = auth.dev_session_config()
  let anon = session.create(store)
  let auth_fn = auth.ws_session_auth(store, config)
  let req = cookie_request("GET", "/ws", config.cookie_name, anon.id)
  let assert Error(_) = auth_fn(req)
  should.equal(session.bound_process_count(store, anon.id), 0)
}

pub fn allow_guests_ws_admits_a_request_without_a_cookie_test() {
  let store = session.new_store("sec_guests_ws_no_cookie")
  let auth_fn = auth.allow_guests_ws(store, auth.dev_session_config())
  let req = make_request("GET", "/ws")
  let #(outcome, logs) = log_capture.capture(fn() { auth_fn(req) })
  should.equal(outcome, Ok(Nil))
  let assert True =
    log_capture.has(logs, level: "debug", containing: [
      "a guest", "missing session cookie",
    ])
}

pub fn allow_guests_ws_admits_a_dead_session_unbound_test() {
  let store = session.new_store("sec_guests_ws_dead")
  let config = auth.dev_session_config()
  let assert Ok(login) = auth.create_login(store, "alice")
  session.delete(store, login.session.id)
  let auth_fn = auth.allow_guests_ws(store, config)
  let req = cookie_request("GET", "/ws", config.cookie_name, login.session.id)
  // A stale cookie on a fresh connection is a guest, not a revocation.
  should.be_false(session.is_current_process_bound(store, login.session.id))
  let #(outcome, logs) = log_capture.capture(fn() { auth_fn(req) })
  should.equal(outcome, Ok(Nil))
  should.equal(session.bound_process_count(store, login.session.id), 0)
  let assert True =
    log_capture.has(logs, level: "debug", containing: [
      "a guest", "invalid session",
    ])
  let assert False =
    log_capture.has(logs, level: "warning", containing: ["no longer valid"])
}

pub fn allow_guests_ws_admits_a_session_without_a_user_unbound_test() {
  let store = session.new_store("sec_guests_ws_no_user")
  let config = auth.dev_session_config()
  let anon = session.create(store)
  let auth_fn = auth.allow_guests_ws(store, config)
  let req = cookie_request("GET", "/ws", config.cookie_name, anon.id)
  should.equal(auth_fn(req), Ok(Nil))
  should.equal(session.bound_process_count(store, anon.id), 0)
  // Admitting a guest binds nothing, so its recheck is a guest again.
  should.equal(auth_fn(req), Ok(Nil))
}

pub fn allow_guests_ws_binds_a_signed_in_session_test() {
  let store = session.new_store("sec_guests_ws_binds")
  let config = auth.dev_session_config()
  let assert Ok(login) = auth.create_login(store, "alice")
  let auth_fn = auth.allow_guests_ws(store, config)
  let req = cookie_request("GET", "/ws", config.cookie_name, login.session.id)
  should.equal(auth_fn(req), Ok(Nil))
  should.equal(session.bound_process_count(store, login.session.id), 1)
  // Logout revokes the bound socket, as with protect_ws.
  session.delete(store, login.session.id)
  let assert Ok(#(_, "deleted")) = receive_revoked(1000)
  // The bound socket's recheck refuses, so it closes with 4401 instead of
  // carrying on as a guest.
  let #(outcome, logs) = log_capture.capture(fn() { auth_fn(req) })
  should.equal(outcome, Error("invalid session"))
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "WS auth rejected", "no longer valid", "invalid session",
    ])
  // The reloaded page opens a new socket: that one is a guest.
  should.equal(auth_in_new_process(auth_fn, req), Ok(Nil))
}

pub fn allow_guests_ws_refuses_a_bound_socket_whose_session_expired_test() {
  let config = auth.dev_session_config()
  let #(store, clock) = short_idle_store("sec_guests_ws_expired")
  let assert Ok(sess) = auth.login(store, "alice")
  let auth_fn = auth.allow_guests_ws(store, config)
  let req = cookie_request("GET", "/ws", config.cookie_name, sess.id)
  should.equal(auth_fn(req), Ok(Nil))
  should.be_true(session.is_current_process_bound(store, sess.id))
  // No sweep runs, so no revocation is sent: only the recheck sees expiry.
  advance(clock, 40)
  let #(outcome, logs) = log_capture.capture(fn() { auth_fn(req) })
  should.equal(outcome, Error("invalid session"))
  let assert True =
    log_capture.has(logs, level: "warning", containing: ["no longer valid"])
  should.equal(auth_in_new_process(auth_fn, req), Ok(Nil))
}

pub fn allow_guests_ws_refuses_a_bound_socket_whose_user_was_removed_test() {
  let store = session.new_store("sec_guests_ws_user_removed")
  let config = auth.dev_session_config()
  let assert Ok(login) = auth.create_login(store, "alice")
  let auth_fn = auth.allow_guests_ws(store, config)
  let req = cookie_request("GET", "/ws", config.cookie_name, login.session.id)
  should.equal(auth_fn(req), Ok(Nil))
  // Removing the user changes the data but sends no revocation.
  let assert Ok(_) =
    session.update(store, login.session.id, dict.delete(_, "user_id"))
  let #(outcome, logs) = log_capture.capture(fn() { auth_fn(req) })
  let assert Error(reason) = outcome
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "no longer valid", reason,
    ])
  // The session itself lives on, so a new socket is a guest on it.
  should.equal(auth_in_new_process(auth_fn, req), Ok(Nil))
}

pub fn is_current_process_bound_matches_binding_test() {
  let store = session.new_store("sec_is_bound")
  let other_store = session.new_store("sec_is_bound_other")
  let sess = session.create(store)
  let other = session.create(store)
  session.ensure_registry()
  should.be_false(session.is_current_process_bound(store, sess.id))
  session.bind_current_process(store, sess.id)
  should.be_true(session.is_current_process_bound(store, sess.id))
  // Bound to that session in that store only, and only in this process.
  should.be_false(session.is_current_process_bound(store, other.id))
  should.be_false(session.is_current_process_bound(other_store, sess.id))
  let answer = process.new_subject()
  process.spawn(fn() {
    process.send(answer, session.is_current_process_bound(store, sess.id))
  })
  let assert Ok(False) = process.receive(answer, 1000)
}

// --- Request helpers / secrets ---

pub fn empty_session_cookie_is_missing_test() {
  let req = cookie_request("GET", "/", "brazier_session", "")
  should.equal(session.id_from_request(req, "brazier_session"), Error(Nil))
}

pub fn binding_fingerprint_hides_session_id_test() {
  let fp = session.binding_fingerprint("secret-session-id")
  should.equal(string.length(fp), 64)
  should.be_false(string.contains(fp, "secret"))
  should.equal(fp, session.binding_fingerprint("secret-session-id"))
  should.not_equal(fp, session.binding_fingerprint("secret-session-id2"))
}

pub fn secure_compare_test() {
  should.be_true(session.secure_compare("abc", "abc"))
  should.be_false(session.secure_compare("abc", "abd"))
  should.be_false(session.secure_compare("abc", "abcd"))
  should.be_false(session.secure_compare("", "a"))
}

pub fn csrf_middleware_with_config_uses_configured_cookie_test() {
  let store = session.new_store("sec_csrf_config")
  let config =
    auth.SessionConfig(..auth.dev_session_config(), cookie_name: "sid")
  let assert Ok(login) = auth.create_login(store, "alice")
  let mw = auth.csrf_protection_with_config(store, config)
  let ok_req =
    cookie_request("POST", "/x", "sid", login.session.id)
    |> request.set_header(config.csrf_header, login.csrf_token)
  let bad_req =
    cookie_request("POST", "/x", "sid", login.session.id)
    |> request.set_header(config.csrf_header, login.csrf_token <> "x")
  should.equal(mw(ok_req, ok_handler).status, 200)
  should.equal(mw(bad_req, ok_handler).status, 403)
}

pub fn require_auth_with_config_uses_configured_cookie_test() {
  let store = session.new_store("sec_require_auth_config")
  let config =
    auth.SessionConfig(..auth.dev_session_config(), cookie_name: "sid")
  let assert Ok(login) = auth.create_login(store, "alice")
  let mw = auth.require_auth_with_config(store, config)
  should.equal(
    mw(cookie_request("GET", "/x", "sid", login.session.id), ok_handler).status,
    200,
  )
  should.equal(
    mw(
      cookie_request("GET", "/x", "brazier_session", login.session.id),
      ok_handler,
    ).status,
    401,
  )
}

// --- Helpers ---

fn ok_handler(_req: Request(Connection)) -> response.Response(ResponseBody) {
  response.new(200)
  |> response.set_body(Bytes(bytes_tree.new()))
}

fn cookie_request(
  method: String,
  path: String,
  cookie_name: String,
  value: String,
) -> Request(Connection) {
  make_request(method, path)
  |> request.set_header("cookie", cookie_name <> "=" <> value)
}

@external(erlang, "brazier_middleware_test_ffi", "make_request")
fn make_request(method: String, path: String) -> Request(Connection)

fn spawn_bound_watcher(
  store: session.SessionStore,
  session_id: String,
) -> #(process.Subject(Nil), process.Subject(Result(#(String, String), Nil))) {
  let ready = process.new_subject()
  let result = process.new_subject()
  // No application runs here: start the node-wide session scope.
  session.ensure_registry()
  let _pid =
    process.spawn(fn() {
      session.bind_current_process(store, session_id)
      process.send(ready, Nil)
      process.send(result, receive_revoked(2000))
    })
  #(ready, result)
}

/// Runs the auth function in a fresh process, as a new socket would.
fn auth_in_new_process(
  auth_fn: fn(Request(Connection)) -> Result(Nil, String),
  req: Request(Connection),
) -> Result(Nil, String) {
  let answer = process.new_subject()
  process.spawn(fn() { process.send(answer, auth_fn(req)) })
  let assert Ok(outcome) = process.receive(answer, 1000)
    as "the auth process answers"
  outcome
}

/// Inclusive integer sequence.
fn seq(from: Int, to: Int) -> List(Int) {
  int.range(from: to, to: from - 1, with: [], run: fn(acc, i) { [i, ..acc] })
}

/// A manual wall clock (see brazier_session_clock_test_ffi).
type ManualClock

@external(erlang, "brazier_session_clock_test_ffi", "new")
fn new_clock(start_ms: Int) -> ManualClock

@external(erlang, "brazier_session_clock_test_ffi", "now")
fn clock_now(clock: ManualClock) -> Int

@external(erlang, "brazier_session_clock_test_ffi", "advance")
fn advance(clock: ManualClock, ms: Int) -> Nil

@external(erlang, "brazier_ws_test_ffi", "receive_revoked")
fn receive_revoked(timeout_ms: Int) -> Result(#(String, String), Nil)

@external(erlang, "brazier_ws_test_ffi", "run_parallel")
fn run_parallel(n: Int, f: fn(Int) -> a) -> List(a)
