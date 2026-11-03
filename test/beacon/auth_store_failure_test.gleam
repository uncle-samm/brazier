/// beacon/auth against an External session backend that fails.
///
/// Every helper with an error channel must return (or answer with) the
/// failure instead of crashing or treating it as "no session": wrappers
/// and middleware answer 503, WebSocket auth rejects, and login never
/// creates a session after it failed to delete the previous one.
/// `init_from_session` refuses with 503 instead of rendering the guest
/// state.
///
/// The fakes are plain Gleam functions answering fixed values; the ones
/// that must never run report to a subject owned by the test.
import beacon/api
import beacon/auth
import beacon/error
import beacon/log_capture
import beacon/session.{
  type ExternalBackend, type SessionStore, External, ExternalBackend, Session,
  SessionBackendFailed, StoredSession,
}
import beacon/test_ctx
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const csrf = "csrf-token-for-the-fake-session"

const down = "database down"

/// A backend holding one live session of user "alice", on which every
/// operation succeeds.
fn healthy() -> ExternalBackend {
  let now = system_now()
  let stored =
    StoredSession(
      session: Session(
        id: "fake",
        data: dict.from_list([#("user_id", "alice"), #("csrf_token", csrf)]),
      ),
      version: 0,
      created_at_ms: now,
      last_seen_ms: now,
    )
  ExternalBackend(
    name: "auth_fake_" <> int.to_string(unique_integer()),
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

/// A backend whose every read and write fails.
fn broken() -> ExternalBackend {
  ExternalBackend(
    ..healthy(),
    create: fn(_) { Error(down) },
    fetch: fn(_) { Error(down) },
    touch: fn(_, _) { Error(down) },
    replace: fn(_, _) { Error(down) },
    delete: fn(_) { Error(down) },
    delete_version: fn(_, _) { Error(down) },
  )
}

/// A backend that reads fine but cannot delete, and reports every create
/// attempt to the returned subject.
fn undeletable() -> #(ExternalBackend, Subject(Nil)) {
  let created = process.new_subject()
  let ext =
    ExternalBackend(..healthy(), delete: fn(_) { Error(down) }, create: fn(_) {
      process.send(created, Nil)
      Ok(True)
    })
  #(ext, created)
}

fn store(ext: ExternalBackend) -> SessionStore {
  let assert Ok(store) =
    session.start_store(External(ext), session.default_store_config())
  store
}

fn with_cookie(method: String, path: String) -> Request(Connection) {
  make_request(method, path)
  |> request.set_header("cookie", "beacon_session=fake")
  |> request.set_header("x-csrf-token", csrf)
}

pub fn login_returns_store_unavailable_test() {
  let store = store(broken())
  let assert Error(auth.SessionStoreUnavailable(reason)) =
    auth.login(store, "alice")
  let assert True = reason != ""
  let assert Error(auth.SessionStoreUnavailable(_)) =
    auth.create_login(store, "alice")
}

pub fn login_creates_nothing_when_the_previous_session_survives_test() {
  let #(ext, created) = undeletable()
  let store = store(ext)
  let assert Error(auth.SessionStoreUnavailable(_)) =
    auth.login_rotating(store, Some("fake"), "alice")
  let assert Error(auth.SessionStoreUnavailable(_)) =
    auth.create_login_rotating(store, Some("fake"), "alice")
  let assert Error(auth.StoreFailed(SessionBackendFailed(_))) =
    auth.login_json_response_rotating(
      store,
      Some("fake"),
      "alice",
      auth.dev_session_config(),
    )
  let assert Error(Nil) = process.receive(created, 0)
    as "no session may be created while the previous one still exists"
  // Without a previous session the same backend logs in normally.
  let assert Ok(_) = auth.login_rotating(store, None, "alice")
  let assert Ok(Nil) = process.receive(created, 0)
}

pub fn login_responses_return_store_failed_test() {
  let store = store(broken())
  let config = auth.dev_session_config()
  let assert Error(auth.StoreFailed(SessionBackendFailed(reason))) =
    auth.login_response(store, "alice", empty_response(), config)
  let assert True = reason == down
  let assert Error(auth.StoreFailed(SessionBackendFailed(_))) =
    auth.login_json_response(store, "alice", config)
}

pub fn logout_returns_store_unavailable_test() {
  let store = store(broken())
  let assert Error(auth.SessionStoreUnavailable(_)) = auth.logout(store, "fake")
}

pub fn logout_response_keeps_the_cookie_when_the_delete_fails_test() {
  let #(ext, _created) = undeletable()
  let store = store(ext)
  let assert Error(auth.StoreFailed(SessionBackendFailed(_)) as err) =
    auth.logout_response(
      store,
      Session(id: "fake", data: dict.new()),
      empty_response(),
      auth.dev_session_config(),
    )
  let assert "session store unavailable: " <> _ =
    auth.response_error_to_string(err)
}

pub fn change_privileges_returns_store_unavailable_test() {
  let store = store(broken())
  let assert Error(auth.SessionStoreUnavailable(_)) =
    auth.change_privileges(store, "fake", [#("role", "admin")])
}

pub fn unavailable_store_is_not_an_invalid_session_test() {
  let config = auth.dev_session_config()
  let req = with_cookie("GET", "/")
  let assert Error(auth.SessionStoreUnavailable(_) as err) =
    auth.session_from_request(req, store(broken()), config)
  // The backend's reason is logged, never shown to clients.
  let assert "session store unavailable" = auth.error_to_string(err)
  let assert Error(auth.SessionStoreUnavailable(_)) =
    auth.current_user_from_request(req, store(broken()), config)
}

pub fn wrappers_answer_503_when_the_store_is_unavailable_test() {
  let store = store(broken())
  let config = auth.dev_session_config()
  let ok = fn(_req, _sess, _user) { empty_response() }
  let authed = auth.authenticated(store, config, ok)(with_cookie("GET", "/"))
  let csrf_authed =
    auth.csrf_authenticated(store, config, ok)(with_cookie("POST", "/"))
  list.each([authed, csrf_authed], expect_unavailable)
}

pub fn middleware_answers_503_when_the_store_is_unavailable_test() {
  let store = store(broken())
  let config = auth.dev_session_config()
  let next = fn(_req) { panic as "next must not run without a session" }
  expect_unavailable(auth.require_auth_with_config(store, config)(
    with_cookie("GET", "/"),
    next,
  ))
  expect_unavailable(auth.csrf_protection_with_config(store, config)(
    with_cookie("POST", "/"),
    next,
  ))
}

pub fn session_routes_answer_503_when_the_store_is_unavailable_test() {
  let store = store(broken())
  let handler =
    auth.session_routes(store, auth.dev_session_config(), fn(_req) {
      Ok("alice")
    })
  let assert Some(login) = handler(make_request("POST", "/api/login"))
  let assert Some(me) = handler(with_cookie("GET", "/api/me"))
  list.each([login, me], expect_unavailable)
}

pub fn logout_route_answers_503_when_the_delete_fails_test() {
  let #(ext, _created) = undeletable()
  let handler =
    api.routes([
      auth.logout_route("/api/logout", store(ext), auth.dev_session_config()),
    ])
  let assert Some(resp) = handler(with_cookie("POST", "/api/logout"))
  expect_unavailable(resp)
}

pub fn ws_auth_rejects_when_the_store_is_unavailable_test() {
  let auth_fn = auth.ws_session_auth(store(broken()), auth.dev_session_config())
  let assert Error("session store unavailable") =
    auth_fn(with_cookie("GET", "/ws"))
}

pub fn init_refuses_with_503_when_the_store_is_unavailable_test() {
  let init =
    auth.init_from_session(
      store(broken()),
      auth.dev_session_config(),
      fn(_ctx) { Ok("guest") },
      fn(_ctx, _sess, user_id) { Ok("user:" <> user_id) },
    )
  let ctx = test_ctx.with_cookies("/", [#("beacon_session", "fake")])
  // Never the guest state: that would show a signed-in user a logged-out
  // page and hide the outage.
  let #(outcome, logs) = log_capture.capture(fn() { init(ctx) })
  let assert Error(refusal) = outcome
  let assert 503 = error.init_error_status(refusal)
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "init cannot verify the session",
      "503",
    ])
  // The backend's reason is logged, never carried to the browser.
  let assert True = log_capture.has(logs, level: "error", containing: [down])
  let assert False = string.contains(error.init_error_reason(refusal), down)
  // The same context against a healthy store is authenticated, so the
  // refusal above came from the failure, not from the context.
  let healthy_init =
    auth.init_from_session(
      store(healthy()),
      auth.dev_session_config(),
      fn(_ctx) { Ok("guest") },
      fn(_ctx, _sess, user_id) { Ok("user:" <> user_id) },
    )
  let assert Ok("user:alice") = healthy_init(ctx)
}

// --- helpers ---

fn expect_unavailable(resp: Response(ResponseBody)) -> Nil {
  let assert 503 = resp.status
  let assert Ok("1") = response.get_header(resp, "retry-after")
  let assert Error(Nil) = response.get_header(resp, "set-cookie")
    as "a failed store must never set or clear the session cookie"
  let assert "Service Unavailable" = body(resp)
  Nil
}

fn body(resp: Response(ResponseBody)) -> String {
  let Bytes(tree) = resp.body
  let assert Ok(text) = tree |> bytes_tree.to_bit_array |> bit_array.to_string
  text
}

fn empty_response() -> Response(ResponseBody) {
  response.new(200)
  |> response.set_body(Bytes(bytes_tree.new()))
}

@external(erlang, "beacon_middleware_test_ffi", "make_request")
fn make_request(method: String, path: String) -> Request(Connection)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "beacon_session_test_ffi", "system_now")
fn system_now() -> Int
