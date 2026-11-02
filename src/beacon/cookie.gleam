/// Cookie parsing and setting utilities for HTTP requests and responses.
///
/// Parses the `Cookie` header from requests and sets `Set-Cookie` headers
/// on responses. Follows RFC 6265 (HTTP State Management Mechanism).
import beacon/log
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Options for setting a cookie.
pub type CookieOptions {
  CookieOptions(
    /// Max age in seconds. None = session cookie.
    max_age: Option(Int),
    /// Cookie path. Defaults to "/".
    path: String,
    /// HttpOnly flag — prevents JavaScript access.
    http_only: Bool,
    /// Secure flag — only sent over HTTPS.
    secure: Bool,
    /// SameSite attribute: "Strict", "Lax", or "None".
    same_site: String,
  )
}

/// Default cookie options — secure, HttpOnly, SameSite=Lax, path="/".
/// Production defaults — Secure=True requires HTTPS. Set secure=False for local dev.
pub fn default_options() -> CookieOptions {
  CookieOptions(
    max_age: None,
    path: "/",
    http_only: True,
    secure: True,
    same_site: "Lax",
  )
}

/// Parse all cookies from a request's Cookie header.
/// Returns a list of (name, value) pairs.
///
/// ```gleam
/// let cookies = cookie.parse(request)
/// // [#("session", "abc123"), #("theme", "dark")]
/// ```
pub fn parse(req: Request(body)) -> List(#(String, String)) {
  case request.get_header(req, "cookie") {
    Error(Nil) -> {
      log.debug("beacon.cookie", "No Cookie header present")
      []
    }
    Ok(cookie_header) -> parse_cookie_header(cookie_header)
  }
}

/// Get a single cookie value by name from a request.
///
/// ```gleam
/// case cookie.get(request, "session_token") {
///   Ok(token) -> validate(token)
///   Error(Nil) -> redirect_to_login()
/// }
/// ```
pub fn get(req: Request(body), name: String) -> Result(String, Nil) {
  let cookies = parse(req)
  case list.find(cookies, fn(pair) { pair.0 == name }) {
    Ok(#(_, value)) -> Ok(value)
    Error(Nil) -> Error(Nil)
  }
}

/// Set a cookie on a response with the given options.
///
/// ```gleam
/// response.new(200)
/// |> cookie.set("session", token, cookie.default_options())
/// ```
pub fn set(
  resp: Response(body),
  name: String,
  value: String,
  opts: CookieOptions,
) -> Response(body) {
  let cookie_str = build_set_cookie(name, value, opts)
  response.set_header(resp, "set-cookie", cookie_str)
}

/// Set a cookie with default options (secure, HttpOnly, SameSite=Lax).
pub fn set_default(
  resp: Response(body),
  name: String,
  value: String,
) -> Response(body) {
  set(resp, name, value, default_options())
}

/// Delete a cookie by setting it to empty with max-age=0.
pub fn delete(resp: Response(body), name: String) -> Response(body) {
  delete_with_options(
    resp,
    name,
    CookieOptions(
      max_age: None,
      path: "/",
      http_only: True,
      secure: False,
      same_site: "Lax",
    ),
  )
}

/// Delete a cookie using the same path/security attributes used to set it.
pub fn delete_with_options(
  resp: Response(body),
  name: String,
  opts: CookieOptions,
) -> Response(body) {
  let opts =
    CookieOptions(
      max_age: Some(0),
      path: opts.path,
      http_only: opts.http_only,
      secure: opts.secure,
      same_site: opts.same_site,
    )
  set(resp, name, "", opts)
}

// --- Internal ---

/// Parse a Cookie header string into (name, value) pairs.
/// Format: "name1=value1; name2=value2; ..."
fn parse_cookie_header(header: String) -> List(#(String, String)) {
  header
  |> string.split(";")
  |> list.filter_map(fn(part) {
    let trimmed = string.trim(part)
    case string.split_once(trimmed, "=") {
      Ok(#(name, value)) -> Ok(#(string.trim(name), string.trim(value)))
      Error(Nil) -> Error(Nil)
    }
  })
}

/// Build a Set-Cookie header value.
/// SECURITY: Strips \r and \n from name and value to prevent header injection.
fn build_set_cookie(
  name: String,
  value: String,
  opts: CookieOptions,
) -> String {
  let safe_name = sanitize_cookie_value(name)
  let safe_value = sanitize_cookie_value(value)
  let base = safe_name <> "=" <> safe_value
  let parts = [base]
  let parts = case opts.max_age {
    Some(age) -> list.append(parts, ["Max-Age=" <> int.to_string(age)])
    None -> parts
  }
  let parts = list.append(parts, ["Path=" <> sanitize_cookie_value(opts.path)])
  let parts = case opts.http_only {
    True -> list.append(parts, ["HttpOnly"])
    False -> parts
  }
  let parts = case opts.secure {
    True -> list.append(parts, ["Secure"])
    False -> parts
  }
  let parts =
    list.append(parts, ["SameSite=" <> sanitize_cookie_value(opts.same_site)])
  string.join(parts, "; ")
}

/// Strip characters that could enable header injection (CR, LF, null).
/// Note: semicolons are intentionally not stripped — they are valid in
/// cookie values and the cookie name=value is already delimited by "; ".
/// Uses FFI for reliable byte-level matching on BEAM.
@external(erlang, "beacon_cookie_ffi", "sanitize_cookie_value")
fn sanitize_cookie_value(value: String) -> String
