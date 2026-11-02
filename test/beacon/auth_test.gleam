import beacon/api
import beacon/auth
import beacon/cookie
import beacon/session
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should

pub fn login_creates_session_test() {
  let store = session.new_store("auth_login")
  let sess = auth.login(store, "user123")
  // Session should exist with user_id
  let assert Some(found) = session.get(store, sess.id)
  let assert Ok("user123") = auth.current_user(found)
}

pub fn logout_destroys_session_test() {
  let store = session.new_store("auth_logout")
  let sess = auth.login(store, "user456")
  auth.logout(store, sess.id)
  // Session should be gone
  let assert option.None = session.get(store, sess.id)
}

pub fn current_user_no_user_test() {
  let store = session.new_store("auth_nouser")
  let sess = session.create(store)
  // No user_id set
  let assert Error(Nil) = auth.current_user(sess)
}

pub fn current_user_with_user_test() {
  let store = session.new_store("auth_withuser")
  let sess = auth.login(store, "admin")
  let assert Ok("admin") = auth.current_user(sess)
}

pub fn login_response_sets_session_cookie_and_csrf_test() {
  let store = session.new_store("auth_login_response")
  let config = auth.dev_session_config()
  let assert Ok(result) =
    auth.login_response(store, "user789", empty_response(), config)

  let assert Some(found) = session.get(store, result.session.id)
  let assert Some("user789") = session.get_value(found, "user_id")
  let assert Some(stored_csrf) = session.get_value(found, "csrf_token")
  should.equal(stored_csrf, result.csrf_token)
  should.be_true(string.length(result.csrf_token) >= 32)

  let assert Ok(cookie_header) =
    find_header(result.response.headers, "set-cookie")
  should.be_true(contains(cookie_header, "beacon_session=" <> result.session.id))
  should.be_true(contains(cookie_header, "HttpOnly"))
  should.be_true(contains(cookie_header, "SameSite=Lax"))
  should.be_false(contains(cookie_header, "Secure"))
}

pub fn create_login_then_with_session_cookie_supports_custom_response_test() {
  let store = session.new_store("auth_create_login")
  let config = auth.dev_session_config()
  let login = auth.create_login(store, "custom-user")

  let assert Ok(resp) =
    api_json("{\"csrf\":\"" <> login.csrf_token <> "\"}")
    |> auth.with_session_cookie(login.session, config)

  let assert Some(found) = session.get(store, login.session.id)
  let assert Some("custom-user") = session.get_value(found, "user_id")
  let assert Some(stored_csrf) = session.get_value(found, "csrf_token")
  should.equal(stored_csrf, login.csrf_token)
  let assert Ok(cookie_header) = find_header(resp.headers, "set-cookie")
  should.be_true(contains(cookie_header, "beacon_session=" <> login.session.id))
}

pub fn login_json_response_sets_standard_json_body_test() {
  let store = session.new_store("auth_login_json_response")
  let config = auth.dev_session_config()
  let assert Ok(result) = auth.login_json_response(store, "json-user", config)

  should.equal(result.response.status, 200)
  should.be_true(contains(response_body(result.response), "\"ok\":true"))
  should.be_true(contains(response_body(result.response), result.csrf_token))
  let assert Ok(cookie_header) =
    find_header(result.response.headers, "set-cookie")
  should.be_true(contains(cookie_header, "beacon_session=" <> result.session.id))
}

/// Regression: an invalid cookie config used to produce a broken
/// Set-Cookie header. It is now refused before any session is created, so
/// no orphan session is left in the store.
pub fn login_with_invalid_cookie_config_creates_no_session_test() {
  let store = session.new_store("auth_login_bad_cookie")
  let bad_name =
    auth.SessionConfig(..auth.dev_session_config(), cookie_name: "bad name")
  let insecure_none =
    auth.SessionConfig(
      ..auth.dev_session_config(),
      cookie_options: cookie.CookieOptions(
        ..auth.dev_session_config().cookie_options,
        same_site: "None",
        secure: False,
      ),
    )
  let before = session.count(store)
  let assert Error(cookie.InvalidName(_)) =
    auth.login_response(store, "u", empty_response(), bad_name)
  let assert Error(cookie.InvalidName(_)) =
    auth.login_json_response(store, "u", bad_name)
  let assert Error(cookie.InsecureSameSiteNone(_)) =
    auth.login_json_response_rotating(store, option.None, "u", insecure_none)
  should.equal(session.count(store), before)
}

pub fn login_route_with_invalid_cookie_config_returns_500_test() {
  let store = session.new_store("auth_login_route_bad_cookie")
  let config =
    auth.SessionConfig(..auth.dev_session_config(), cookie_name: "bad;name")
  let handler =
    api.routes([
      auth.login_route("/api/login", store, config, fn(_req) { Ok("u") }),
    ])
  let req: Request(Connection) = make_request("POST", "/api/login")
  let assert Some(resp) = handler(req)
  should.equal(resp.status, 500)
  let assert Error(Nil) = find_header(resp.headers, "set-cookie")
  should.equal(session.count(store), 0)
}

pub fn default_session_config_uses_secure_cookie_defaults_test() {
  let config = auth.default_session_config()
  should.equal(config.cookie_name, auth.default_session_cookie_name)
  should.equal(config.csrf_header, auth.default_csrf_header_name)
  should.be_true(config.cookie_options.http_only)
  should.be_true(config.cookie_options.secure)
  should.equal(config.cookie_options.same_site, "Lax")
}

pub fn session_from_request_reads_configured_cookie_test() {
  let store = session.new_store("auth_request_session")
  let config = auth.dev_session_config()
  let assert Ok(result) =
    auth.login_response(store, "request-user", empty_response(), config)
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("cookie", "beacon_session=" <> result.session.id)

  let assert Ok(sess) = auth.session_from_request(req, store, config)
  should.equal(sess.id, result.session.id)
}

pub fn session_from_request_rejects_missing_and_invalid_cookie_test() {
  let store = session.new_store("auth_request_missing")
  let config = auth.dev_session_config()
  let missing_req =
    request.new()
    |> request.set_method(http.Get)
  let invalid_req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("cookie", "beacon_session=missing")

  should.equal(
    auth.session_from_request(missing_req, store, config),
    Error(auth.MissingSessionCookie),
  )
  should.equal(
    auth.session_from_request(invalid_req, store, config),
    Error(auth.InvalidSession),
  )
}

pub fn validate_csrf_accepts_matching_header_test() {
  let store = session.new_store("auth_csrf_valid")
  let config = auth.dev_session_config()
  let assert Ok(result) =
    auth.login_response(store, "csrf-user", empty_response(), config)
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_header("x-csrf-token", result.csrf_token)

  should.equal(auth.validate_csrf(req, result.session, config), Ok(Nil))
}

pub fn validate_csrf_rejects_missing_and_invalid_header_test() {
  let store = session.new_store("auth_csrf_invalid")
  let config = auth.dev_session_config()
  let assert Ok(result) =
    auth.login_response(store, "csrf-user", empty_response(), config)
  let missing_req =
    request.new()
    |> request.set_method(http.Post)
  let invalid_req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_header("x-csrf-token", "wrong")

  should.equal(
    auth.validate_csrf(missing_req, result.session, config),
    Error(auth.MissingCsrfToken),
  )
  should.equal(
    auth.validate_csrf(invalid_req, result.session, config),
    Error(auth.InvalidCsrfToken),
  )
}

pub fn ws_session_auth_accepts_valid_session_and_rejects_missing_test() {
  let store = session.new_store("auth_ws_session")
  let config = auth.dev_session_config()
  let assert Ok(result) =
    auth.login_response(store, "socket-user", empty_response(), config)
  let auth_fn = auth.ws_session_auth(store, config)
  let authed_req: Request(Connection) =
    make_request("GET", "/ws")
    |> request.set_header("cookie", "beacon_session=" <> result.session.id)
  let missing_req: Request(Connection) = make_request("GET", "/ws")

  should.equal(auth_fn(authed_req), Ok(Nil))
  should.equal(auth_fn(missing_req), Error("missing session cookie"))
}

pub fn protect_ws_alias_matches_session_auth_test() {
  let store = session.new_store("auth_protect_ws")
  let config = auth.dev_session_config()
  let assert Ok(result) = auth.login_json_response(store, "socket-user", config)
  let auth_fn = auth.protect_ws(store, config)
  let req: Request(Connection) =
    make_request("GET", "/ws")
    |> request.set_header("cookie", "beacon_session=" <> result.session.id)

  should.equal(auth_fn(req), Ok(Nil))
}

pub fn csrf_authenticated_wraps_api_handler_test() {
  let store = session.new_store("auth_api_wrapper")
  let config = auth.dev_session_config()
  let assert Ok(result) =
    auth.login_response(store, "api-user", empty_response(), config)
  let handler =
    auth.csrf_authenticated(store, config, fn(_req, _sess, user_id) {
      response.new(200)
      |> response.set_body(Bytes(bytes_tree.from_string("user:" <> user_id)))
    })
  let valid_req: Request(Connection) =
    make_request("POST", "/api/save")
    |> request.set_header("cookie", "beacon_session=" <> result.session.id)
    |> request.set_header("x-csrf-token", result.csrf_token)
  let missing_csrf_req: Request(Connection) =
    make_request("POST", "/api/save")
    |> request.set_header("cookie", "beacon_session=" <> result.session.id)

  let ok_resp = handler(valid_req)
  should.equal(ok_resp.status, 200)
  let forbidden_resp = handler(missing_csrf_req)
  should.equal(forbidden_resp.status, 403)
}

pub fn auth_login_route_creates_session_and_cookie_test() {
  let store = session.new_store("auth_login_route")
  let config = auth.dev_session_config()
  let handler =
    api.routes([
      auth.login_route("/api/login", store, config, fn(_req) {
        Ok("route-user")
      }),
    ])
  let req: Request(Connection) = make_request("POST", "/api/login")

  let assert Some(resp) = handler(req)
  should.equal(resp.status, 200)
  should.be_true(contains(response_body(resp), "\"ok\":true"))
  let assert Ok(cookie_header) = find_header(resp.headers, "set-cookie")
  should.be_true(contains(cookie_header, "beacon_session="))
}

pub fn auth_login_route_rejects_failed_authentication_test() {
  let store = session.new_store("auth_login_route_reject")
  let config = auth.dev_session_config()
  let handler =
    api.routes([
      auth.login_route("/api/login", store, config, fn(_req) {
        Error("bad credentials")
      }),
    ])
  let req: Request(Connection) = make_request("POST", "/api/login")

  let assert Some(resp) = handler(req)
  should.equal(resp.status, 401)
  should.equal(response_body(resp), "bad credentials")
}

pub fn auth_current_user_route_returns_user_test() {
  let store = session.new_store("auth_current_user_route")
  let config = auth.dev_session_config()
  let assert Ok(result) = auth.login_json_response(store, "route-user", config)
  let handler = api.routes([auth.current_user_route("/api/me", store, config)])
  let req: Request(Connection) =
    make_request("GET", "/api/me")
    |> request.set_header("cookie", "beacon_session=" <> result.session.id)

  let assert Some(resp) = handler(req)
  should.equal(resp.status, 200)
  should.equal(response_body(resp), "{\"user\":\"route-user\"}")
}

pub fn auth_logout_route_requires_csrf_and_deletes_session_test() {
  let store = session.new_store("auth_logout_route")
  let config = auth.dev_session_config()
  let assert Ok(result) = auth.login_json_response(store, "route-user", config)
  let handler = api.routes([auth.logout_route("/api/logout", store, config)])
  let req: Request(Connection) =
    make_request("POST", "/api/logout")
    |> request.set_header("cookie", "beacon_session=" <> result.session.id)
    |> request.set_header("x-csrf-token", result.csrf_token)

  let assert Some(resp) = handler(req)
  should.equal(resp.status, 200)
  should.equal(response_body(resp), "{\"ok\":true}")
  should.equal(session.get(store, result.session.id), option.None)
}

pub fn init_from_session_uses_authenticated_or_guest_init_test() {
  let store = session.new_store("auth_init_from_session")
  let config = auth.dev_session_config()
  let assert Ok(result) = auth.login_json_response(store, "init-user", config)
  let init =
    auth.init_from_session(
      store,
      config,
      fn(_req) { "guest" },
      fn(_req, _sess, user_id) { "user:" <> user_id },
    )
  let authed_req: Request(Connection) =
    make_request("GET", "/")
    |> request.set_header("cookie", "beacon_session=" <> result.session.id)
  let guest_req: Request(Connection) = make_request("GET", "/")

  should.equal(init(authed_req), "user:init-user")
  should.equal(init(guest_req), "guest")
}

// --- helpers ---

fn find_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case list.find(headers, fn(header) { header.0 == name }) {
    Ok(#(_, value)) -> Ok(value)
    Error(Nil) -> Error(Nil)
  }
}

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

fn empty_response() -> response.Response(ResponseBody) {
  response.new(200)
  |> response.set_body(Bytes(bytes_tree.new()))
}

fn api_json(body: String) -> response.Response(ResponseBody) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

fn response_body(resp: response.Response(ResponseBody)) -> String {
  let Bytes(tree) = resp.body
  let assert Ok(body) = tree |> bytes_tree.to_bit_array |> bit_array.to_string
  body
}

fn make_request(method: String, path: String) -> Request(Connection) {
  do_make_request(method, path)
}

@external(erlang, "beacon_middleware_test_ffi", "make_request")
fn do_make_request(method: String, path: String) -> Request(Connection)
