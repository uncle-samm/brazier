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
  let resp =
    response.new(200)
    |> cookie.set_default("session", "abc123")
  let headers = resp.headers
  let cookie_header = find_header(headers, "set-cookie")
  cookie_header
  |> should.be_ok()
  let assert Ok(value) = cookie_header
  should.be_true(contains(value, "session=abc123"))
  should.be_true(contains(value, "HttpOnly"))
  should.be_true(contains(value, "Secure"))
  should.be_true(contains(value, "SameSite=Lax"))
  should.be_true(contains(value, "Path=/"))
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
  let resp =
    response.new(200)
    |> cookie.set("token", "xyz", opts)
  let assert Ok(value) = find_header(resp.headers, "set-cookie")
  should.be_true(contains(value, "token=xyz"))
  should.be_true(contains(value, "Max-Age=3600"))
  should.be_true(contains(value, "SameSite=Strict"))
}

pub fn delete_cookie_test() {
  let resp =
    response.new(200)
    |> cookie.delete("session")
  let assert Ok(value) = find_header(resp.headers, "set-cookie")
  should.be_true(contains(value, "session="))
  should.be_true(contains(value, "Max-Age=0"))
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
  let resp =
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

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}
