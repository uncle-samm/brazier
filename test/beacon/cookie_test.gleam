import beacon/cookie
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{None, Some}
import gleeunit/should

pub fn parse_empty_cookies_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
  cookie.parse(req)
  |> should.equal([])
}

pub fn parse_single_cookie_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("cookie", "session=abc123")
  cookie.parse(req)
  |> should.equal([#("session", "abc123")])
}

pub fn parse_multiple_cookies_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("cookie", "session=abc123; theme=dark; lang=en")
  let cookies = cookie.parse(req)
  cookies
  |> should.equal([#("session", "abc123"), #("theme", "dark"), #("lang", "en")])
}

pub fn parse_cookies_with_spaces_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("cookie", " session = abc123 ; theme = dark ")
  let cookies = cookie.parse(req)
  cookies
  |> should.equal([#("session", "abc123"), #("theme", "dark")])
}

pub fn get_cookie_found_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("cookie", "session=abc123; theme=dark")
  cookie.get(req, "session")
  |> should.equal(Ok("abc123"))
}

pub fn get_cookie_not_found_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("cookie", "session=abc123")
  cookie.get(req, "missing")
  |> should.equal(Error(Nil))
}

pub fn get_cookie_no_header_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
  cookie.get(req, "session")
  |> should.equal(Error(Nil))
}

// Regression: an attacker-supplied cookie whose name merely *contains* the
// real cookie name must never shadow it. The previous FFI did a substring
// match on the raw header, so `evil_beacon_session=attacker` could be read as
// the `beacon_session` cookie. Exact per-name matching closes that hole.
pub fn get_cookie_ignores_prefixed_shadow_name_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header(
      "cookie",
      "evil_beacon_session=attacker; beacon_session=real",
    )
  cookie.get(req, "beacon_session")
  |> should.equal(Ok("real"))
}

pub fn get_cookie_ignores_suffixed_shadow_name_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header(
      "cookie",
      "beacon_session=real; beacon_session_evil=attacker",
    )
  cookie.get(req, "beacon_session")
  |> should.equal(Ok("real"))
}

pub fn get_cookie_no_exact_match_with_only_shadow_name_test() {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("cookie", "evil_beacon_session=attacker")
  cookie.get(req, "beacon_session")
  |> should.equal(Error(Nil))
}

pub fn set_cookie_default_test() {
  let assert Ok(resp) =
    response.new(200)
    |> cookie.set_default("session", "abc123")
  let assert Ok(value) = find_header(resp.headers, "set-cookie")
  should.equal(value, "session=abc123; Path=/; HttpOnly; Secure; SameSite=Lax")
}

pub fn set_cookie_with_max_age_test() {
  let opts =
    cookie.CookieOptions(
      max_age: Some(3600),
      path: "/",
      http_only: True,
      secure: True,
      same_site: "Strict",
    )
  let assert Ok(resp) =
    response.new(200)
    |> cookie.set("token", "xyz", opts)
  let assert Ok(value) = find_header(resp.headers, "set-cookie")
  should.be_true(contains(value, "token=xyz"))
  should.be_true(contains(value, "Max-Age=3600"))
  should.be_true(contains(value, "SameSite=Strict"))
}

/// Regression: `delete` used Secure=False while `default_options` (what
/// `set_default` uses) is Secure=True, so the deletion did not match the
/// cookie it was meant to remove.
pub fn delete_cookie_matches_default_options_test() {
  let assert Ok(resp) =
    response.new(200)
    |> cookie.delete("session")
  let assert Ok(value) = find_header(resp.headers, "set-cookie")
  should.equal(
    value,
    "session=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax",
  )
}

pub fn delete_cookie_with_options_preserves_security_attributes_test() {
  let opts =
    cookie.CookieOptions(
      max_age: Some(3600),
      path: "/app",
      http_only: True,
      secure: True,
      same_site: "Strict",
    )
  let assert Ok(resp) =
    response.new(200)
    |> cookie.delete_with_options("session", opts)
  let assert Ok(value) = find_header(resp.headers, "set-cookie")
  should.be_true(contains(value, "session="))
  should.be_true(contains(value, "Max-Age=0"))
  should.be_true(contains(value, "Path=/app"))
  should.be_true(contains(value, "HttpOnly"))
  should.be_true(contains(value, "Secure"))
  should.be_true(contains(value, "SameSite=Strict"))
}

pub fn default_options_test() {
  let opts = cookie.default_options()
  opts.http_only
  |> should.be_true()
  opts.secure
  |> should.be_true()
  opts.same_site
  |> should.equal("Lax")
  opts.path
  |> should.equal("/")
  opts.max_age
  |> should.equal(None)
}

// --- Several cookies on one response ---

/// Regression: `set` used `response.set_header`, so a second cookie
/// silently replaced the first Set-Cookie header.
pub fn two_cookies_are_both_sent_test() {
  let assert Ok(resp) = cookie.set_default(response.new(200), "a", "1")
  let assert Ok(resp) = cookie.set_default(resp, "b", "2")
  let values = set_cookie_values(resp)
  let assert 2 = list.length(values)
  let assert True = list.any(values, fn(v) { string.starts_with(v, "a=1;") })
  let assert True = list.any(values, fn(v) { string.starts_with(v, "b=2;") })
}

pub fn setting_a_name_again_replaces_it_test() {
  let assert Ok(resp) = cookie.set_default(response.new(200), "a", "1")
  let assert Ok(resp) = cookie.set_default(resp, "ab", "keep")
  let assert Ok(resp) = cookie.set_default(resp, "a", "2")
  let values = set_cookie_values(resp)
  let assert 2 = list.length(values)
  let assert True = list.any(values, fn(v) { string.starts_with(v, "a=2;") })
  let assert True =
    list.any(values, fn(v) { string.starts_with(v, "ab=keep;") })
}

pub fn other_headers_are_kept_test() {
  let assert Ok(resp) =
    response.new(200)
    |> response.set_header("x-other", "yes")
    |> cookie.set_default("a", "1")
  let assert Ok("yes") = response.get_header(resp, "x-other")
}

// --- RFC 6265 validation ---

pub fn valid_cookie_octets_are_accepted_test() {
  // Session ids are url-safe base64; signed tokens add dots.
  let assert Ok(_) =
    cookie.set_default(
      response.new(200),
      "beacon_session",
      "aZ09-_.~!#$%&'()*+/:<=>?@[]^`{|}",
    )
  let assert Ok(_) = cookie.set_default(response.new(200), "quoted", "\"abc\"")
  let assert Ok(_) = cookie.set_default(response.new(200), "empty", "")
}

pub fn invalid_values_are_rejected_test() {
  let resp = response.new(200)
  let bad = [
    "has space", "semi;colon", "com,ma", "back\\slash", "quo\"te", "tab\there",
    "del\u{007F}", "caf\u{00E9}", "\"unterminated",
  ]
  list.each(bad, fn(value) {
    let assert Error(cookie.InvalidValue("c")) =
      cookie.set_default(resp, "c", value)
  })
}

pub fn invalid_names_are_rejected_test() {
  let resp = response.new(200)
  let bad = [
    "",
    "a b",
    "a=b",
    "a;b",
    "a,b",
    "(a)",
    "a/b",
    "a\"b",
    "caf\u{00E9}",
  ]
  list.each(bad, fn(name) {
    let assert Error(cookie.InvalidName(_)) =
      cookie.set_default(resp, name, "v")
  })
}

pub fn invalid_paths_are_rejected_test() {
  let resp = response.new(200)
  list.each(["", "app", "/a;b", "/a\nb"], fn(path) {
    let assert Error(cookie.InvalidPath(..)) =
      cookie.set(
        resp,
        "c",
        "v",
        cookie.CookieOptions(..cookie.default_options(), path: path),
      )
  })
}

pub fn same_site_must_be_exact_test() {
  let resp = response.new(200)
  list.each(["lax", "", "Lax ", "Medium"], fn(same_site) {
    let assert Error(cookie.InvalidSameSite(..)) =
      cookie.set(
        resp,
        "c",
        "v",
        cookie.CookieOptions(..cookie.default_options(), same_site: same_site),
      )
  })
}

pub fn same_site_none_requires_secure_test() {
  let insecure =
    cookie.CookieOptions(
      ..cookie.default_options(),
      same_site: "None",
      secure: False,
    )
  let assert Error(cookie.InsecureSameSiteNone("c")) =
    cookie.set(response.new(200), "c", "v", insecure)
  let assert Ok(_) =
    cookie.set(
      response.new(200),
      "c",
      "v",
      cookie.CookieOptions(..insecure, secure: True),
    )
}

pub fn negative_max_age_is_rejected_test() {
  let assert Error(cookie.NegativeMaxAge("c", -1)) =
    cookie.set(
      response.new(200),
      "c",
      "v",
      cookie.CookieOptions(..cookie.default_options(), max_age: Some(-1)),
    )
}

pub fn cookie_prefixes_are_enforced_test() {
  let insecure = cookie.CookieOptions(..cookie.default_options(), secure: False)
  let resp = response.new(200)
  let assert Error(cookie.PrefixViolation(..)) =
    cookie.set(resp, "__Secure-id", "v", insecure)
  let assert Error(cookie.PrefixViolation(..)) =
    cookie.set(resp, "__Host-id", "v", insecure)
  // Browsers match prefixes case-insensitively.
  let assert Error(cookie.PrefixViolation(..)) =
    cookie.set(resp, "__host-id", "v", insecure)
  let assert Error(cookie.PrefixViolation(..)) =
    cookie.set(
      resp,
      "__Host-id",
      "v",
      cookie.CookieOptions(..cookie.default_options(), path: "/app"),
    )
  let assert Ok(_) = cookie.set_default(resp, "__Host-id", "v")
  let assert Ok(_) = cookie.set_default(resp, "__Secure-id", "v")
}

pub fn oversized_cookie_is_rejected_test() {
  let resp = response.new(200)
  let assert Error(cookie.TooLarge("c", 4097)) =
    cookie.set_default(resp, "c", string.repeat("a", 4096))
  let assert Ok(_) = cookie.set_default(resp, "c", string.repeat("a", 4095))
  let assert Error(cookie.TooLarge(..)) =
    cookie.set(
      resp,
      "c",
      "v",
      cookie.CookieOptions(
        ..cookie.default_options(),
        path: "/" <> string.repeat("p", 1024),
      ),
    )
}

pub fn validate_options_checks_without_a_value_test() {
  let assert Ok(Nil) =
    cookie.validate_options("beacon_session", cookie.default_options())
  let assert Error(cookie.InvalidName(_)) =
    cookie.validate_options("bad name", cookie.default_options())
}

pub fn error_to_string_does_not_leak_the_value_test() {
  let assert Error(error) =
    cookie.set_default(response.new(200), "session", "secret value")
  let message = cookie.error_to_string(error)
  let assert True = contains(message, "session")
  let assert False = contains(message, "secret")
}

// --- Parsing ---

pub fn parse_skips_empty_names_and_bare_tokens_test() {
  let req =
    request.new()
    |> request.set_header("cookie", "=orphan; bare; a=1;; b=")
  cookie.parse(req)
  |> should.equal([#("a", "1"), #("b", "")])
}

pub fn parse_reads_every_cookie_header_test() {
  let req =
    request.new()
    |> request.prepend_header("cookie", "b=2")
    |> request.prepend_header("cookie", "a=1")
  cookie.parse(req)
  |> should.equal([#("a", "1"), #("b", "2")])
}

pub fn get_returns_the_first_of_duplicate_names_test() {
  let req =
    request.new()
    |> request.set_header("cookie", "id=specific; id=general")
  cookie.get(req, "id")
  |> should.equal(Ok("specific"))
}

pub fn values_keep_equals_signs_test() {
  let req =
    request.new()
    |> request.set_header("cookie", "tok=a.b=c==")
  cookie.get(req, "tok")
  |> should.equal(Ok("a.b=c=="))
}

// --- helpers ---

import gleam/list
import gleam/string

fn find_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case list.find(headers, fn(h) { h.0 == name }) {
    Ok(#(_, v)) -> Ok(v)
    Error(Nil) -> Error(Nil)
  }
}

fn set_cookie_values(resp: response.Response(body)) -> List(String) {
  list.filter_map(resp.headers, fn(h) {
    case h.0 == "set-cookie" {
      True -> Ok(h.1)
      False -> Error(Nil)
    }
  })
}

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}
