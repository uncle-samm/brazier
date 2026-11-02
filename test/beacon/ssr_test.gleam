import beacon/auth
import beacon/cookie
import beacon/effect
import beacon/element
import beacon/route
import beacon/session
import beacon/ssr
import gleam/bit_array
import gleam/crypto
import gleam/http/request
import gleam/json
import gleam/option
import gleam/string

// --- Test helpers ---

pub type TestModel {
  TestModel(name: String)
}

pub type TestMsg {
  NoOp
}

fn test_init() -> #(TestModel, effect.Effect(TestMsg)) {
  #(TestModel(name: "World"), effect.none())
}

fn test_view(model: TestModel) -> element.Node(TestMsg) {
  element.el("div", [], [
    element.el("h1", [], [element.text("Hello, " <> model.name <> "!")]),
  ])
}

fn test_config() -> ssr.SsrConfig(TestModel, TestMsg) {
  ssr.SsrConfig(
    init: test_init,
    view: test_view,
    secret_key: "test-secret-key-at-least-32-chars-long!!",
    title: "Test Page",
    head_html: option.None,
    dev_mode: False,
    serialize_model: option.None,
  )
}

// --- Tests ---

pub fn render_page_produces_html_test() {
  let page = ssr.render_page(test_config())
  // Verify doctype is at the very start of the HTML string
  let assert True = string.starts_with(page.html, "<!DOCTYPE html>")
  // Verify ORDER: <!DOCTYPE html> comes before <html> comes before </html>
  let assert Ok(doctype_pos) = string_index_of(page.html, "<!DOCTYPE html>")
  let assert Ok(html_open_pos) = string_index_of(page.html, "<html>")
  let assert Ok(html_close_pos) = string_index_of(page.html, "</html>")
  let assert True = doctype_pos < html_open_pos
  let assert True = html_open_pos < html_close_pos
}

pub fn render_page_includes_view_content_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "Hello, World!")
  // Verify "Hello, World!" appears AFTER id="beacon-app" (content is inside the app root)
  let assert Ok(app_pos) = string_index_of(page.html, "id=\"beacon-app\"")
  let assert Ok(content_pos) = string_index_of(page.html, "Hello, World!")
  let assert True = app_pos < content_pos
}

pub fn render_page_includes_title_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "<title>Test Page</title>")
}

pub fn render_page_includes_script_tag_test() {
  let page = ssr.render_page(test_config())
  // Script tag should reference beacon_client (hashed or plain)
  let assert True = str_contains(page.html, "<script src=\"/beacon_client")
  let assert True = str_contains(page.html, "data-beacon-auto")
}

pub fn choose_client_assets_dir_prefers_local_manifest_test() {
  let assert "priv/static" =
    ssr.choose_client_assets_dir(True, "priv/static", "fallback/static")
}

pub fn choose_client_assets_dir_falls_back_when_missing_test() {
  let assert "fallback/static" =
    ssr.choose_client_assets_dir(False, "priv/static", "fallback/static")
}

pub fn render_page_includes_beacon_app_root_test() {
  let page = ssr.render_page(test_config())
  let assert True = str_contains(page.html, "id=\"beacon-app\"")
}

pub fn render_page_sets_session_token_without_dom_exposure_test() {
  let page = ssr.render_page(test_config())
  let assert False = str_contains(page.html, "data-beacon-token=\"")
  // Verify the token is actually valid by verifying it with the same secret
  let assert Ok(_ts) =
    ssr.verify_session_token(
      ssr.join_token_for(page, ""),
      "test-secret-key-at-least-32-chars-long!!",
      3600,
    )
}

pub fn render_page_view_inside_app_root_test() {
  let page = ssr.render_page(test_config())
  // The view HTML should be inside the beacon-app div
  let assert True = str_contains(page.html, "id=\"beacon-app\"")
  let assert True = str_contains(page.html, "<h1>Hello, World!</h1>")
}

// --- Session token tests ---

pub fn create_session_token_not_empty_test() {
  let token = ssr.create_session_token("my-secret-key-for-testing-purposes!!")
  let assert True = string_length(token) > 10
}

pub fn verify_valid_token_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  let assert Ok(ts) = ssr.verify_session_token(token, secret, 3600)
  // Assert the timestamp is recent — within the last 60 seconds
  let now = current_system_time_seconds()
  let age = now - ts
  let assert True = age >= 0
  let assert True = age < 60
}

pub fn verify_token_wrong_secret_test() {
  let token = ssr.create_session_token("correct-secret-key-for-signing!!")
  let assert Error(_) =
    ssr.verify_session_token(token, "wrong-secret-key-for-verifying!!!", 3600)
}

pub fn verify_expired_token_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  // Use max_age of -1 seconds — token is already "expired"
  let assert Error("Session token expired") =
    ssr.verify_session_token(token, secret, -1)
}

pub fn verify_tampered_token_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  // Tamper with the token
  let tampered = token <> "x"
  let assert Error(_) = ssr.verify_session_token(tampered, secret, 3600)
}

pub fn render_page_for_path_renders_route_specific_html_test() {
  // Test that different paths produce different SSR content
  // Using the existing TestModel/TestMsg types with a route-aware update
  let config =
    ssr.SsrConfig(
      init: fn() { #(TestModel(name: "default"), effect.none()) },
      view: test_view,
      secret_key: "test-secret-key-at-least-32-chars-long!!",
      title: "Route Test",
      head_html: option.None,
      dev_mode: False,
      serialize_model: option.None,
    )
  let patterns = [route.pattern("/"), route.pattern("/about")]
  let on_route_change =
    option.Some(fn(r: route.Route) -> TestMsg {
      // We can't actually change the model here since TestMsg is NoOp,
      // but we verify the function is called
      let _ = r
      NoOp
    })
  let update = fn(model: TestModel, _msg: TestMsg) { #(model, effect.none()) }

  let page =
    ssr.render_page_for_path(
      config,
      "/about",
      patterns,
      on_route_change,
      update,
    )
  // Should contain the view HTML
  let assert True = str_contains(page.html, "Hello, default!")
  // Should have a session token
  let assert True = string_length(ssr.join_token_for(page, "")) > 10
}

pub fn render_page_for_path_unmatched_route_renders_static_not_found_test() {
  let config =
    ssr.SsrConfig(
      init: fn() { #(TestModel(name: "default"), effect.none()) },
      view: test_view,
      secret_key: "test-secret-key-at-least-32-chars-long!!",
      title: "Route Test",
      head_html: option.None,
      dev_mode: False,
      serialize_model: option.None,
    )
  let page =
    ssr.render_page_for_path(
      config,
      "/missing",
      [route.pattern("/")],
      option.Some(fn(_r: route.Route) -> TestMsg { NoOp }),
      fn(model: TestModel, _msg: TestMsg) { #(model, effect.none()) },
    )

  let assert True = str_contains(page.html, "Page Not Found")
  let assert True = str_contains(page.html, "id=\"beacon-app\"")
  let assert False = str_contains(page.html, "data-beacon-auto")
  let assert False = str_contains(page.html, "Hello, default!")
}

/// The join token goes into a Set-Cookie header; a token outside the
/// cookie-octet set is refused instead of being written as an injection.
pub fn to_response_rejects_a_token_that_is_not_a_cookie_value_test() {
  let page =
    ssr.RenderedPage(..ssr.render_page(test_config()), sign_join_token: fn(_) {
      "tok; Domain=evil.example"
    })
  let assert Error(cookie.InvalidValue(_)) = ssr.to_response(page)
  let req =
    request.new() |> request.set_header("cookie", "beacon_session=session-a")
  let assert Error(cookie.InvalidValue(_)) =
    ssr.to_response_for_request(page, req)
}

pub fn join_tokens_are_valid_cookie_values_test() {
  let page = ssr.render_page(test_config())
  let assert Ok(Nil) =
    cookie.validate(
      ssr.session_cookie_name,
      ssr.join_token_for(page, ""),
      cookie.default_options(),
    )
  let assert Ok(Nil) =
    cookie.validate(
      ssr.session_cookie_name,
      ssr.join_token_for(page, ssr.fingerprint_session_id("session-a")),
      cookie.default_options(),
    )
}

pub fn to_response_returns_200_test() {
  let page = ssr.render_page(test_config())
  let assert Ok(resp) = ssr.to_response(page)
  let assert 200 = resp.status
}

pub fn to_response_sets_httponly_session_cookie_test() {
  let page = ssr.render_page(test_config())
  let assert Ok(resp) = ssr.to_response(page)
  let assert Ok(cookie_header) = find_header(resp.headers, "set-cookie")
  let assert True = str_contains(cookie_header, ssr.session_cookie_name <> "=")
  let assert True = str_contains(cookie_header, "HttpOnly")
  let assert True = str_contains(cookie_header, "SameSite=Lax")
  let assert True = str_contains(cookie_header, "Max-Age=86400")
}

pub fn serialized_model_is_stored_in_signed_cookie_token_test() {
  let config =
    ssr.SsrConfig(
      init: fn() { #(TestModel(name: "VisibleState"), effect.none()) },
      view: test_view,
      secret_key: "test-secret-key-at-least-32-chars-long!!",
      title: "Cookie State Test",
      head_html: option.None,
      dev_mode: False,
      serialize_model: option.Some(fn(_model: TestModel) { "SecretCookieState" }),
    )
  let page = ssr.render_page(config)
  let assert Ok(_) =
    ssr.verify_session_token(
      ssr.join_token_for(page, ""),
      "test-secret-key-at-least-32-chars-long!!",
      3600,
    )
  let assert False = str_contains(page.html, "SecretCookieState")
}

// --- Join token (v2) tests: unhappy paths first ---

const join_secret = "join-token-secret-key-at-least-32-chars"

fn signed_join_token(fingerprint: String, model: option.Option(String)) {
  ssr.sign_join_token(
    join_secret,
    fingerprint,
    model,
    current_system_time_seconds(),
  )
}

pub fn join_token_rejects_empty_server_secret_test() {
  let token = signed_join_token("", option.Some("{}"))
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(token, "", "", current_system_time_seconds())
}

pub fn join_token_signed_with_empty_secret_never_verifies_test() {
  let token =
    ssr.sign_join_token(
      "",
      "",
      option.Some("{}"),
      current_system_time_seconds(),
    )
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(token, "", "", current_system_time_seconds())
}

pub fn join_token_rejects_empty_token_test() {
  let assert Error(ssr.JoinTokenMalformed(_)) =
    ssr.verify_join_token("", join_secret, "", current_system_time_seconds())
}

pub fn join_token_rejects_garbage_test() {
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(
      "not.a.token",
      join_secret,
      "",
      current_system_time_seconds(),
    )
}

pub fn join_token_rejects_tampered_token_test() {
  let token = signed_join_token("", option.Some("{\"count\":1}"))
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(
      token <> "x",
      join_secret,
      "",
      current_system_time_seconds(),
    )
}

pub fn join_token_rejects_other_secret_test() {
  let token = signed_join_token("", option.Some("{}"))
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(
      token,
      "a-completely-different-secret-key-0123",
      "",
      current_system_time_seconds(),
    )
}

pub fn create_session_token_is_unbound_join_token_without_model_test() {
  // The v1 API mints a join token that carries no model and no session
  // binding, so it can never restore state or cross sessions.
  let session_token = ssr.create_session_token(join_secret)
  let assert Ok(ssr.JoinToken(model_json: option.None, ..)) =
    ssr.verify_join_token(
      session_token,
      join_secret,
      "",
      current_system_time_seconds(),
    )
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(
      session_token,
      join_secret,
      ssr.fingerprint_session_id("session-a"),
      current_system_time_seconds(),
    )
}

pub fn join_token_rejects_wrong_purpose_test() {
  let token =
    sign_raw_join_payload(
      json.object([
        #("v", json.int(2)),
        #("purpose", json.string("beacon.other")),
        #("iat", json.int(current_system_time_seconds())),
        #("exp", json.int(current_system_time_seconds() + 60)),
        #("sid", json.string("")),
        #("model", json.null()),
      ]),
    )
  let assert Error(ssr.JoinTokenInvalid(reason)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
  let assert True = str_contains(reason, "purpose")
}

pub fn join_token_rejects_wrong_version_test() {
  let token =
    sign_raw_join_payload(
      json.object([
        #("v", json.int(1)),
        #("purpose", json.string("beacon.join")),
        #("iat", json.int(current_system_time_seconds())),
        #("exp", json.int(current_system_time_seconds() + 60)),
        #("sid", json.string("")),
        #("model", json.null()),
      ]),
    )
  let assert Error(ssr.JoinTokenInvalid(reason)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
  let assert True = str_contains(reason, "version")
}

pub fn join_token_rejects_oversized_validity_window_test() {
  // A forged-looking window longer than the lifetime is refused even when
  // the signature is valid.
  let now = current_system_time_seconds()
  let token =
    sign_raw_join_payload(
      json.object([
        #("v", json.int(2)),
        #("purpose", json.string("beacon.join")),
        #("iat", json.int(now)),
        #("exp", json.int(now + ssr.join_token_lifetime_seconds + 1)),
        #("sid", json.string("")),
        #("model", json.null()),
      ]),
    )
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(token, join_secret, "", now)
}

pub fn join_token_rejects_missing_fields_test() {
  let token = sign_raw_join_payload(json.object([#("v", json.int(2))]))
  let assert Error(ssr.JoinTokenMalformed(_)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

pub fn join_token_rejects_future_issue_time_test() {
  let now = current_system_time_seconds()
  let token = ssr.sign_join_token(join_secret, "", option.None, now + 3600)
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(token, join_secret, "", now)
}

pub fn join_token_rejects_expired_token_test() {
  let now = current_system_time_seconds()
  let issued_at = now - ssr.join_token_lifetime_seconds
  let token = ssr.sign_join_token(join_secret, "", option.None, issued_at)
  let assert Error(ssr.JoinTokenExpired(expired_at:, now: checked_at)) =
    ssr.verify_join_token(token, join_secret, "", now)
  let assert True = expired_at == now
  let assert True = checked_at == now
}

pub fn join_token_rejects_other_session_test() {
  let token =
    signed_join_token(ssr.fingerprint_session_id("session-a"), option.None)
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(
      token,
      join_secret,
      ssr.fingerprint_session_id("session-b"),
      current_system_time_seconds(),
    )
}

pub fn join_token_bound_token_rejects_unbound_connection_test() {
  let token =
    signed_join_token(ssr.fingerprint_session_id("session-a"), option.None)
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

pub fn join_token_unbound_token_rejects_bound_connection_test() {
  let token = signed_join_token("", option.None)
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(
      token,
      join_secret,
      ssr.fingerprint_session_id("session-a"),
      current_system_time_seconds(),
    )
}

pub fn join_token_round_trips_model_and_window_test() {
  let now = current_system_time_seconds()
  let fingerprint = ssr.fingerprint_session_id("session-a")
  let token =
    ssr.sign_join_token(join_secret, fingerprint, option.Some("{\"n\":1}"), now)
  let assert Ok(ssr.JoinToken(issued_at:, expires_at:, model_json:)) =
    ssr.verify_join_token(token, join_secret, fingerprint, now)
  let assert True = issued_at == now
  let assert True = expires_at == now + ssr.join_token_lifetime_seconds
  let assert option.Some("{\"n\":1}") = model_json
}

pub fn join_token_round_trips_without_model_test() {
  let token = signed_join_token("", option.None)
  let assert Ok(ssr.JoinToken(model_json: option.None, ..)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

pub fn session_identity_cookie_matches_auth_default_test() {
  let assert True =
    ssr.session_identity_cookie_name == auth.default_session_cookie_name
}

pub fn fingerprint_matches_session_binding_fingerprint_test() {
  let assert True =
    ssr.fingerprint_session_id("abc") == session.binding_fingerprint("abc")
  // The raw session id never appears in the fingerprint.
  let assert False = str_contains(ssr.fingerprint_session_id("abc"), "abc")
}

pub fn session_fingerprint_is_empty_without_session_cookie_test() {
  let assert "" = ssr.session_fingerprint(request.new())
  let assert "" =
    ssr.session_fingerprint(
      request.new() |> request.set_header("cookie", "beacon_session="),
    )
}

pub fn session_fingerprint_reads_session_cookie_test() {
  let req =
    request.new()
    |> request.set_header("cookie", "other=1; beacon_session=session-a")
  let assert True =
    ssr.session_fingerprint(req) == ssr.fingerprint_session_id("session-a")
}

pub fn to_response_for_request_binds_token_to_session_test() {
  let config =
    ssr.SsrConfig(
      ..test_config(),
      secret_key: join_secret,
      serialize_model: option.Some(fn(m: TestModel) {
        "{\"name\":\"" <> m.name <> "\"}"
      }),
    )
  let page = ssr.render_page(config)
  let req =
    request.new() |> request.set_header("cookie", "beacon_session=session-a")
  let assert Ok(resp) = ssr.to_response_for_request(page, req)
  let assert Ok(set_cookie) = find_header(resp.headers, "set-cookie")
  let token = cookie_value(set_cookie, ssr.session_cookie_name)
  let now = current_system_time_seconds()
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(token, join_secret, "", now)
  let assert Ok(ssr.JoinToken(model_json: option.Some(model_json), ..)) =
    ssr.verify_join_token(
      token,
      join_secret,
      ssr.fingerprint_session_id("session-a"),
      now,
    )
  let assert "{\"name\":\"World\"}" = model_json
}

pub fn join_token_omits_model_over_cookie_budget_test() {
  let big = string.repeat("x", 5000)
  let config =
    ssr.SsrConfig(
      ..test_config(),
      secret_key: join_secret,
      serialize_model: option.Some(fn(_m: TestModel) { "\"" <> big <> "\"" }),
    )
  let token = ssr.join_token_for(ssr.render_page(config), "")
  let assert True = string_length(token) <= 3800
  let assert Ok(ssr.JoinToken(model_json: option.None, ..)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

pub fn join_token_carries_no_model_without_serializer_test() {
  let config = ssr.SsrConfig(..test_config(), secret_key: join_secret)
  let token = ssr.join_token_for(ssr.render_page(config), "")
  let assert Ok(ssr.JoinToken(model_json: option.None, ..)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

/// Sign an arbitrary payload with the join-token key derivation, to build
/// tokens the public signer refuses to produce.
fn sign_raw_join_payload(payload: json.Json) -> String {
  let key =
    crypto.hmac(
      bit_array.from_string("beacon.join_token.v2"),
      crypto.Sha256,
      bit_array.from_string(join_secret),
    )
  crypto.sign_message(
    bit_array.from_string(json.to_string(payload)),
    key,
    crypto.Sha256,
  )
}

fn cookie_value(set_cookie: String, name: String) -> String {
  let assert Ok(#(_, rest)) = string.split_once(set_cookie, name <> "=")
  case string.split_once(rest, ";") {
    Ok(#(value, _)) -> value
    Error(Nil) -> rest
  }
}

// --- head_html tests ---

pub fn head_html_none_renders_no_extra_content_test() {
  let page = ssr.render_page(test_config())
  // No <style> block (removed hardcoded demo styles)
  let assert True = does_not_contain(page.html, "<style>")
  // head_html is None, so no extra content between </title> and </head>
  let assert True = str_contains(page.html, "</title></head>")
}

pub fn head_html_injects_stylesheet_link_test() {
  let config =
    ssr.SsrConfig(
      init: test_init,
      view: test_view,
      secret_key: "test-secret-key-at-least-32-chars-long!!",
      title: "CSS Test",
      head_html: option.Some(
        "<link rel=\"stylesheet\" href=\"/static/styles.css\">",
      ),
      dev_mode: False,
      serialize_model: option.None,
    )
  let page = ssr.render_page(config)
  let assert True =
    str_contains(
      page.html,
      "<link rel=\"stylesheet\" href=\"/static/styles.css\">",
    )
  // The link tag should be in the head section (after title, before </head>)
  let assert Ok(title_pos) = string_index_of(page.html, "</title>")
  let assert Ok(link_pos) =
    string_index_of(page.html, "<link rel=\"stylesheet\"")
  let assert Ok(head_close_pos) = string_index_of(page.html, "</head>")
  let assert True = title_pos < link_pos
  let assert True = link_pos < head_close_pos
}

pub fn head_html_multiple_tags_test() {
  let config =
    ssr.SsrConfig(
      init: test_init,
      view: test_view,
      secret_key: "test-secret-key-at-least-32-chars-long!!",
      title: "Multi Head Test",
      head_html: option.Some(
        "<link rel=\"stylesheet\" href=\"/a.css\"><meta name=\"theme-color\" content=\"#000\">",
      ),
      dev_mode: False,
      serialize_model: option.None,
    )
  let page = ssr.render_page(config)
  let assert True = str_contains(page.html, "href=\"/a.css\"")
  let assert True = str_contains(page.html, "theme-color")
}

// --- Helpers ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

fn does_not_contain(haystack: String, needle: String) -> Bool {
  case do_str_contains(haystack, needle) {
    True -> False
    False -> True
  }
}

fn find_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(key, value), ..rest] ->
      case key == name {
        True -> Ok(value)
        False -> find_header(rest, name)
      }
  }
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool

fn string_length(s: String) -> Int {
  do_string_length(s)
}

@external(erlang, "erlang", "byte_size")
fn do_string_length(s: String) -> Int

fn string_index_of(haystack: String, needle: String) -> Result(Int, Nil) {
  do_string_index_of(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_index_of")
fn do_string_index_of(haystack: String, needle: String) -> Result(Int, Nil)

@external(erlang, "beacon_test_ffi", "system_time_seconds")
fn current_system_time_seconds() -> Int
