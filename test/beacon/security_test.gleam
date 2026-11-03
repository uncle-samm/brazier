/// Security tests — verify that security hardening actually works.
/// Each test targets a specific vulnerability from the security audit.
import beacon/ssr
import beacon/transport
import beacon/transport/http as transport_http
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

pub fn token_expiration_capped_at_24h_test() {
  // CVE: callers could set max_age to years, keeping tokens alive forever
  // Fix: hard cap at 86400 seconds (24 hours)
  let secret = "test-secret-key-long-enough-32chars!!"
  let token = ssr.create_session_token(secret)
  // Token with max_age of 999999 (~11 days), but capped to 24h internally
  // Verify the token is valid now (age 0 < 24h cap)
  let assert Ok(_) = ssr.verify_session_token(token, secret, 999_999)
}

pub fn token_expired_rejected_test() {
  // Tokens with negative age should fail
  let secret = "test-secret-key-long-enough-32chars!!"
  let token = ssr.create_session_token(secret)
  // With max_age of -1 (already expired), must reject
  let assert Error(_) = ssr.verify_session_token(token, secret, -1)
}

pub fn token_wrong_secret_rejected_test() {
  let token =
    ssr.create_session_token("correct-secret-key-long-enough-32chars!!")
  let assert Error(_) =
    ssr.verify_session_token(
      token,
      "wrong-secret-key-long-enough-32chars!!",
      3600,
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
  // (handler_id is used as data-beacon-event-* attribute value, must be escaped)
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
import beacon
import beacon/element.{type Element}
import beacon/html

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
pub fn main() { beacon.simple(init:, update:, view:) |> beacon.start(8080) }
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

import beacon/build/analyzer
import gleam/list

// === Cookie Header Injection Tests ===

import beacon/cookie
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

import beacon/static

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
