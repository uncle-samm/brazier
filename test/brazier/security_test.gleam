/// Security tests — verify that security hardening actually works.
/// Each test targets a specific vulnerability from the security audit.
import brazier/ssr
import brazier/transport
import brazier/transport/http as transport_http
import gleam/option.{None}
import gleam/string

// === Origin Validation Tests ===

pub fn origin_empty_string_rejected_test() {
  // CVE: empty origin_host bypassed CSWSH check
  let assert Error(_) = transport.origin_allowed_for_host("", "localhost:8080")
}

pub fn origin_missing_host_rejected_test() {
  let assert Error(_) =
    transport.origin_allowed_for_host("http://localhost:8080", "")
}

pub fn origin_mismatch_rejected_test() {
  let assert Error(_) =
    transport.origin_allowed_for_host("https://evil.example", "localhost:8080")
}

pub fn origin_matching_host_allowed_test() {
  let assert Ok(Nil) =
    transport.origin_allowed_for_host(
      "http://localhost:8080/some/path",
      "localhost:8080",
    )
}

pub fn origin_scheme_and_host_compare_in_ascii_case_only_test() {
  let assert Ok(Nil) =
    transport.origin_allowed_for_host(
      "HTTP://Kitchen.Example:8080",
      "kitchen.EXAMPLE:8080",
    )
  // The Kelvin sign U+212A lowercases to `k` in Unicode, not in ASCII: an
  // Origin naming it is not the page's own origin.
  let assert Error(reason) =
    transport.origin_allowed_for_host(
      "http://\u{212A}itchen.example:8080",
      "kitchen.example:8080",
    )
  assert string.contains(reason, "non-ASCII characters in host")
  let assert Error(reason) =
    transport.origin_allowed_for_host(
      "http://kitchen.example:8080",
      "\u{212A}itchen.example:8080",
    )
  assert string.contains(reason, "invalid Host: non-ASCII characters in host")
  // A listed origin with a non-ASCII host is refused when it is parsed.
  let assert Error(reason) =
    transport.parse_allowed_origins(["https://b\u{00FC}cher.example"])
  assert string.contains(reason, "non-ASCII characters in host")
  let assert Ok(origins) =
    transport.parse_allowed_origins(["HTTPS://App.Example.com"])
  let assert Ok(Nil) =
    transport.origin_allowed(
      "https://app.example.COM",
      "http",
      "localhost:8080",
      origins,
    )
}

pub fn response_header_rejects_crlf_value_test() {
  let assert Error(_) =
    transport_http.validate_response_header(
      "x-user",
      "sam\r\nset-cookie: admin=true",
    )
}

pub fn response_header_rejects_invalid_name_test() {
  let assert Error(_) =
    transport_http.validate_response_header("x-bad\r\nname", "ok")
}

pub fn response_header_accepts_rfc_token_name_test() {
  let assert Ok(Nil) =
    transport_http.validate_response_header("x-trace-id", "abc123")
}

// === Token Expiration Tests ===

pub fn token_lifetime_is_24h_test() {
  // A join token cannot be kept alive past its fixed 24 h lifetime: the
  // expiry is signed into it (Phoenix.Token's max_age), not chosen by the
  // verifier.
  let secret = "test-secret-key-long-enough-32chars!!"
  let now = system_time_seconds()
  let hour = 3600
  let stale = ssr.sign_join_token(secret, "", None, now - 25 * hour)
  let assert Error(ssr.JoinTokenExpired(expired_at: expired_at, now: _)) =
    ssr.verify_join_token(stale, secret, "", now)
  assert expired_at == now - 25 * hour + ssr.join_token_lifetime_seconds
  // Inside the lifetime the token verifies and reports its issue time.
  let issued_at = now - 23 * hour
  let fresh = ssr.sign_join_token(secret, "", None, issued_at)
  let assert Ok(verified) = ssr.verify_join_token(fresh, secret, "", now)
  assert verified.issued_at == issued_at
}

@external(erlang, "brazier_ssr_ffi", "system_time_seconds")
fn system_time_seconds() -> Int

pub fn token_issued_in_the_future_rejected_test() {
  // A token whose issue time is past the clock-skew allowance is refused.
  let secret = "test-secret-key-long-enough-32chars!!"
  let now = system_time_seconds()
  let token = ssr.sign_join_token(secret, "", None, now + 3600)
  let assert Error(ssr.JoinTokenInvalid(reason: "issued in the future")) =
    ssr.verify_join_token(token, secret, "", now)
}

pub fn token_wrong_secret_rejected_test() {
  let now = system_time_seconds()
  let token =
    ssr.sign_join_token(
      "correct-secret-key-long-enough-32chars!!",
      "",
      None,
      now,
    )
  let assert Error(ssr.JoinTokenInvalid(reason: "signature verification failed")) =
    ssr.verify_join_token(
      token,
      "wrong-secret-key-long-enough-32chars!!",
      "",
      now,
    )
}

// === Wire Protocol Security Tests ===

pub fn security_limits_include_pre_upgrade_caps_test() {
  let limits = transport.default_security_limits()
  let assert 100 = limits.max_http_headers
  let assert 65_536 = limits.max_http_header_bytes
  let assert 5000 = limits.pre_upgrade_timeout_ms
  let assert 65_536 = limits.max_message_bytes
}

pub fn oversized_message_type_does_not_crash_test() {
  // DoS: very long type field shouldn't crash decoder
  let long_type = string.repeat("a", 10_000)
  let raw = "{\"type\":\"" <> long_type <> "\"}"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn null_fields_in_event_rejected_test() {
  // Injection: null values where strings expected
  let raw =
    "{\"type\":\"event\",\"name\":null,\"data\":\"{}\",\"target_path\":\"0\"}"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn deeply_nested_json_does_not_crash_test() {
  // DoS: deeply nested JSON shouldn't stack overflow
  let nested = string.repeat("{\"a\":", 100) <> "1" <> string.repeat("}", 100)
  let raw =
    "{\"type\":\"event\",\"name\":\"click\",\"data\":\""
    <> nested
    <> "\",\"target_path\":\"0\"}"
  // Deeply nested JSON should be rejected, not crash
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn event_with_script_injection_in_handler_id_test() {
  // XSS: handler_id with script tags should be harmless
  // (handler_id is used as data-brazier-event-* attribute value, must be escaped)
  let raw =
    "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"<script>alert(1)</script>\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":1}"
  let assert Ok(transport.ClientEvent(handler_id: hid, ..)) =
    transport.decode_client_message(raw)
  // The handler_id is stored as-is — escaping happens in HTML rendering
  let assert True = string.contains(hid, "script")
}

pub fn event_with_huge_data_field_test() {
  // DoS: large data field (but within message size limit)
  let big_data = string.repeat("x", 50_000)
  let raw =
    "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"h0\",\"data\":\""
    <> big_data
    <> "\",\"target_path\":\"0\",\"clock\":1}"
  // Should decode (under 64KB default limit)
  let assert Ok(transport.ClientEvent(data: data, ..)) =
    transport.decode_client_message(raw)
  let assert True = string.length(data) == 50_000
}

// === Server Message Encoding Security ===

pub fn server_error_does_not_leak_stack_trace_test() {
  // Info disclosure: error messages should be user-friendly, not internal
  let msg = transport.ServerError(reason: "Rate limited")
  let encoded = transport.encode_server_message(msg)
  let assert True = string.contains(encoded, "Rate limited")
  // Should NOT contain file paths, line numbers, or Erlang internals
  let assert False = string.contains(encoded, ".gleam")
  let assert False = string.contains(encoded, ".erl")
  let assert False = string.contains(encoded, "stacktrace")
}

// === Constant Leak Prevention Security Tests ===

pub fn unreached_secret_constants_never_reach_client_code_test() {
  // Only what view reaches is emitted for the browser, whatever the
  // constants are called.
  let source =
    "
import brazier
import brazier/element.{type Element}
import brazier/html

pub type Model { Model(count: Int) }
pub type Msg { Inc }

const stripe_key = \"sk_live_secret\"
const server_db_password = \"p@ssw0rd!\"
pub const jwt_secret = \"jwt_hmac_256_key\"
const public_app_name = \"My App\"

fn init(_ctx) { Model(count: bool_to_int(stripe_key == server_db_password)) }
fn bool_to_int(b: Bool) -> Int { case b { True -> 1 False -> 0 } }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(_model: Model) -> Element(Msg) {
  html.text(public_app_name)
}
pub fn main() { brazier.simple(init:, update:, view:) |> brazier.start(8080) }
"
  let assert Ok(analysis) = analyzer.analyze("app", [#("app", source)])
  let client =
    string.join(list.map(analysis.client, fn(emitted) { emitted.source }), "\n")
  let assert False = string.contains(client, "sk_live_secret")
  let assert False = string.contains(client, "p@ssw0rd!")
  let assert False = string.contains(client, "jwt_hmac_256_key")
  let assert False = string.contains(client, "stripe_key")
  let assert False = string.contains(client, "fn init")
  let assert True = string.contains(client, "public_app_name")
}

import brazier/build/analyzer
import gleam/list

// === Cookie Header Injection Tests ===

import brazier/cookie
import gleam/http/response

pub fn cookie_value_newline_is_rejected_test() {
  // CVE: newlines in cookie values enable header injection. The value is
  // rejected outright rather than stripped into something else.
  let assert Error(cookie.InvalidValue("session")) =
    response.new(200)
    |> cookie.set_default("session", "abc\r\nSet-Cookie: admin=true")
}

pub fn cookie_value_null_byte_is_rejected_test() {
  let assert Error(cookie.InvalidValue("tok")) =
    response.new(200)
    |> cookie.set_default("tok", "abc\u{0000}def")
}

pub fn cookie_name_newline_is_rejected_test() {
  let assert Error(cookie.InvalidName(_)) =
    response.new(200)
    |> cookie.set_default("bad\r\nname", "value")
}

/// Regression: semicolons were passed through, so a value could append
/// its own attributes (`Domain=`, `Path=`, `SameSite=None`).
pub fn cookie_value_attribute_injection_is_rejected_test() {
  let resp = response.new(200)
  let assert Error(cookie.InvalidValue(_)) =
    cookie.set_default(resp, "session", "abc; Domain=evil.example")
  let assert Error(cookie.InvalidValue(_)) =
    cookie.set_default(resp, "session", "abc,other=1")
  let assert Error(cookie.InvalidPath(..)) =
    cookie.set(
      resp,
      "session",
      "abc",
      cookie.CookieOptions(..cookie.default_options(), path: "/; Domain=evil"),
    )
  let assert Error(cookie.InvalidSameSite(..)) =
    cookie.set(
      resp,
      "session",
      "abc",
      cookie.CookieOptions(..cookie.default_options(), same_site: "Lax; Secure"),
    )
  // Nothing was written by any of the refused calls.
  let assert Error(Nil) = find_header(resp.headers, "set-cookie")
}

fn find_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case k == name {
        True -> Ok(v)
        False -> find_header(rest, name)
      }
  }
}

// === Static File Traversal Tests ===

import brazier/static

pub fn traversal_encoded_dots_rejected_test() {
  // CVE: %2e%2e/ bypasses simple ".." check
  let assert True = static.contains_traversal("%2e%2e/etc/passwd")
}

pub fn traversal_encoded_slash_rejected_test() {
  // CVE: %2f bypasses simple "/" check
  let assert True = static.contains_traversal("..%2fetc%2fpasswd")
}

pub fn traversal_encoded_backslash_rejected_test() {
  let assert True = static.contains_traversal("..%5cwindows%5csystem32")
}

pub fn traversal_null_byte_rejected_test() {
  let assert True = static.contains_traversal("file\u{0000}.txt")
}

pub fn traversal_case_insensitive_encoding_test() {
  // %2E is uppercase version of %2e
  let assert True = static.contains_traversal("%2E%2E/etc/passwd")
}

pub fn traversal_clean_path_allowed_test() {
  let assert False = static.contains_traversal("/css/style.css")
  let assert False = static.contains_traversal("/images/logo.png")
}
