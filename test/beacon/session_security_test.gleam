/// Session security: lifetimes, atomic writes, rotation, revocation.
/// Unhappy paths first.
import beacon/api
import beacon/auth
import beacon/log_capture
import beacon/session
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
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

fn short_idle_store(name: String) -> session.SessionStore {
  session.new_store_with_config(
    name,
    session.StoreConfig(
      absolute_ttl_ms: 60_000,
      idle_ttl_ms: 40,
      sweep_interval_ms: 60_000,
    ),
  )
}

// --- Expiry ---

pub fn idle_expired_session_is_rejected_test() {
  let store = short_idle_store("sec_idle_expired")
  let sess = session.create(store)
  sleep_ms(80)
  should.equal(session.get(store, sess.id), None)
  // Expired rows are deleted on access, not left behind.
  should.equal(session.count(store), 0)
}

pub fn write_to_expired_session_is_rejected_and_not_resurrected_test() {
  let store = short_idle_store("sec_write_expired")
  let sess = session.create(store)
  sleep_ms(80)
  should.equal(
    session.set(store, sess, "k", "v"),
    Error(session.SessionExpired),
  )
  should.equal(session.count(store), 0)
  should.equal(session.get(store, sess.id), None)
}

pub fn absolute_lifetime_is_enforced_despite_activity_test() {
  let store =
    session.new_store_with_config(
      "sec_absolute_expired",
      session.StoreConfig(
        absolute_ttl_ms: 100,
        idle_ttl_ms: 60_000,
        sweep_interval_ms: 60_000,
      ),
    )
  let sess = session.create(store)
  // Keep it busy: idle never passes, absolute does.
  list.each(seq(1, 6), fn(_) {
    sleep_ms(25)
    let _ = session.get(store, sess.id)
    Nil
  })
  sleep_ms(30)
  should.equal(session.get(store, sess.id), None)
}

pub fn activity_extends_idle_lifetime_test() {
  let store =
    session.new_store_with_config(
      "sec_idle_extend",
      session.StoreConfig(
        absolute_ttl_ms: 60_000,
        idle_ttl_ms: 150,
        sweep_interval_ms: 60_000,
      ),
    )
  let sess = session.create(store)
  list.each(seq(1, 5), fn(_) {
    sleep_ms(60)
    let assert Some(_) = session.get(store, sess.id)
    Nil
  })
}

pub fn sweep_removes_expired_sessions_test() {
  let store = short_idle_store("sec_sweep_manual")
  let _a = session.create(store)
  let _b = session.create(store)
  should.equal(session.count(store), 2)
  sleep_ms(80)
  let live = session.create(store)
  should.equal(session.sweep_expired(store), Ok(2))
  should.equal(session.count(store), 1)
  let assert Some(_) = session.get(store, live.id)
}

pub fn background_sweeper_removes_expired_sessions_test() {
  let store =
    session.new_store_with_config(
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
  sleep_ms(200)
  should.equal(session.count(store), 0)
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
  let store =
    session.new_store_with_config(
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
  let assert Ok(Ok(#(_, reason))) = process.receive(result, 1000)
  should.equal(reason, "expired")
}

pub fn bindings_are_released_when_process_exits_test() {
  let store = session.new_store("sec_binding_release")
  let sess = session.create(store)
  let ready = process.new_subject()
  // No application runs here: start the node-wide session scope.
  session.ensure_registry()
  let pid =
    process.spawn(fn() {
      session.bind_current_process(store, sess.id)
      session.bind_current_process(store, sess.id)
      process.send(ready, Nil)
      sleep_ms(30)
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  // Idempotent: binding twice is one membership.
  should.equal(session.bound_process_count(store, sess.id), 1)
  should.be_true(wait_until_dead(pid, 50))
  sleep_ms(20)
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
  let #(outcome, logs) = log_capture.capture(fn() { auth_fn(req) })
  should.equal(outcome, Ok(Nil))
  should.equal(session.bound_process_count(store, login.session.id), 0)
  let assert True =
    log_capture.has(logs, level: "debug", containing: [
      "a guest", "invalid session",
    ])
}

pub fn allow_guests_ws_admits_a_session_without_a_user_unbound_test() {
  let store = session.new_store("sec_guests_ws_no_user")
  let config = auth.dev_session_config()
  let anon = session.create(store)
  let auth_fn = auth.allow_guests_ws(store, config)
  let req = cookie_request("GET", "/ws", config.cookie_name, anon.id)
  should.equal(auth_fn(req), Ok(Nil))
  should.equal(session.bound_process_count(store, anon.id), 0)
}

pub fn allow_guests_ws_binds_a_signed_in_session_test() {
  let store = session.new_store("sec_guests_ws_binds")
  let config = auth.dev_session_config()
  let assert Ok(login) = auth.create_login(store, "alice")
  let auth_fn = auth.allow_guests_ws(store, config)
  let req = cookie_request("GET", "/ws", config.cookie_name, login.session.id)
  should.equal(auth_fn(req), Ok(Nil))
  should.equal(session.bound_process_count(store, login.session.id), 1)
  // Logout revokes the bound socket, as with protect_ws; the same request
  // then connects as a guest.
  session.delete(store, login.session.id)
  let assert Ok(#(_, "deleted")) = receive_revoked(1000)
  should.equal(auth_fn(req), Ok(Nil))
}

// --- Request helpers / secrets ---

pub fn empty_session_cookie_is_missing_test() {
  let req = cookie_request("GET", "/", "beacon_session", "")
  should.equal(session.id_from_request(req, "beacon_session"), Error(Nil))
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
      cookie_request("GET", "/x", "beacon_session", login.session.id),
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

@external(erlang, "beacon_middleware_test_ffi", "make_request")
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

/// Inclusive integer sequence.
fn seq(from: Int, to: Int) -> List(Int) {
  int.range(from: to, to: from - 1, with: [], run: fn(acc, i) { [i, ..acc] })
}

fn wait_until_dead(pid: process.Pid, attempts: Int) -> Bool {
  case process.is_alive(pid), attempts {
    False, _ -> True
    True, 0 -> False
    True, n -> {
      sleep_ms(10)
      wait_until_dead(pid, n - 1)
    }
  }
}

@external(erlang, "beacon_ws_test_ffi", "receive_revoked")
fn receive_revoked(timeout_ms: Int) -> Result(#(String, String), Nil)

@external(erlang, "beacon_ws_test_ffi", "sleep_ms")
fn sleep_ms(ms: Int) -> Nil

@external(erlang, "beacon_ws_test_ffi", "run_parallel")
fn run_parallel(n: Int, f: fn(Int) -> a) -> List(a)
