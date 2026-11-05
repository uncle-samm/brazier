/// Cookie parsing and setting utilities for HTTP requests and responses.
///
/// Parses the `Cookie` header from requests and sets `Set-Cookie` headers
/// on responses, following RFC 6265 (and the cookie prefix and size rules of
/// RFC 6265bis).
///
/// Setting a cookie validates it and returns a `Result`: a name that is not
/// a token, a value with `;`, `,`, whitespace, quotes or control bytes, a
/// bad `Path` or `SameSite`, or a violated `__Secure-` / `__Host-` prefix is
/// an error, never sanitized into something else. This rules out header and
/// attribute injection (`value; Domain=evil.example`) by construction.
///
/// Reference: Plug.Conn.Cookies (encoding, one Set-Cookie per name).
import brazier/internal/ascii
import brazier/log
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Options for setting a cookie.
pub type CookieOptions {
  CookieOptions(
    /// Max age in seconds. None = session cookie. Must be >= 0.
    max_age: Option(Int),
    /// Cookie path. Must start with "/". Defaults to "/".
    path: String,
    /// HttpOnly flag — prevents JavaScript access.
    http_only: Bool,
    /// Secure flag — only sent over HTTPS.
    secure: Bool,
    /// SameSite attribute: "Strict", "Lax", or "None" ("None" requires
    /// `secure: True`).
    same_site: String,
  )
}

/// Why a cookie could not be set. Values are never included: they are
/// often secrets.
pub type CookieError {
  /// The name is empty or not an RFC 7230 token.
  InvalidName(name: String)
  /// The value contains bytes outside the RFC 6265 cookie-octet set.
  InvalidValue(name: String)
  /// The path is empty, does not start with "/", or has a CTL or ";".
  InvalidPath(name: String, path: String)
  /// SameSite is not exactly "Strict", "Lax" or "None".
  InvalidSameSite(name: String, same_site: String)
  /// SameSite=None without Secure is rejected by browsers.
  InsecureSameSiteNone(name: String)
  /// Max-Age is negative.
  NegativeMaxAge(name: String, max_age: Int)
  /// A `__Secure-` or `__Host-` prefix requirement is not met.
  PrefixViolation(name: String, reason: String)
  /// Name and value together exceed `max_name_value_bytes`, or the path
  /// exceeds `max_attribute_bytes`. Browsers drop such cookies silently.
  TooLarge(name: String, bytes: Int)
}

/// RFC 6265bis: browsers ignore cookies whose name and value together
/// exceed 4096 bytes.
pub const max_name_value_bytes = 4096

/// RFC 6265bis: browsers ignore attribute values over 1024 bytes.
pub const max_attribute_bytes = 1024

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

/// Human-readable description of a cookie error.
pub fn error_to_string(error: CookieError) -> String {
  case error {
    InvalidName(name) ->
      "cookie name " <> string.inspect(name) <> " is not an RFC 7230 token"
    InvalidValue(name) ->
      "value of cookie "
      <> string.inspect(name)
      <> " has bytes outside the RFC 6265 cookie-octet set"
    InvalidPath(name, path) ->
      "path "
      <> string.inspect(path)
      <> " of cookie "
      <> string.inspect(name)
      <> " must start with / and contain no control bytes or ;"
    InvalidSameSite(name, same_site) ->
      "SameSite "
      <> string.inspect(same_site)
      <> " of cookie "
      <> string.inspect(name)
      <> " must be Strict, Lax or None"
    InsecureSameSiteNone(name) ->
      "cookie " <> string.inspect(name) <> " has SameSite=None without Secure"
    NegativeMaxAge(name, max_age) ->
      "cookie "
      <> string.inspect(name)
      <> " has negative Max-Age "
      <> int.to_string(max_age)
    PrefixViolation(name, reason) ->
      "cookie " <> string.inspect(name) <> ": " <> reason
    TooLarge(name, bytes) ->
      "cookie "
      <> string.inspect(name)
      <> " is "
      <> int.to_string(bytes)
      <> " bytes, over the browser limit"
  }
}

/// Parse all cookies from a request's Cookie header(s).
/// Returns a list of (name, value) pairs in header order. Pairs without
/// `=` or with an empty name are skipped. Several `Cookie` headers (as
/// HTTP/2 proxies may send) are read in order.
///
/// ```gleam
/// let cookies = cookie.parse(request)
/// // [#("session", "abc123"), #("theme", "dark")]
/// ```
pub fn parse(req: Request(body)) -> List(#(String, String)) {
  let headers =
    list.filter_map(req.headers, fn(header) {
      case header.0 == "cookie" {
        True -> Ok(header.1)
        False -> Error(Nil)
      }
    })
  case headers {
    [] -> {
      log.debug("brazier.cookie", "No Cookie header present")
      []
    }
    _ -> list.flat_map(headers, parse_cookie_header)
  }
}

/// Get a single cookie value by name from a request. When the browser sent
/// several cookies with the same name (different paths or domains), the
/// first one wins, as in Plug. Use a `__Host-` name to stop a sibling
/// subdomain from planting a same-named cookie.
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

/// Check a cookie's name and options without a value. Use it to reject a
/// bad configuration before doing work whose result is a cookie.
pub fn validate_options(
  name: String,
  opts: CookieOptions,
) -> Result(Nil, CookieError) {
  use <- check(valid_name(name), InvalidName(name))
  use <- check(
    string.starts_with(opts.path, "/") && valid_path(opts.path),
    InvalidPath(name, opts.path),
  )
  let path_bytes = string.byte_size(opts.path)
  use <- check(path_bytes <= max_attribute_bytes, TooLarge(name, path_bytes))
  use <- check(
    list.contains(["Strict", "Lax", "None"], opts.same_site),
    InvalidSameSite(name, opts.same_site),
  )
  use <- check(
    opts.same_site != "None" || opts.secure,
    InsecureSameSiteNone(name),
  )
  use <- check(
    case opts.max_age {
      Some(age) -> age >= 0
      None -> True
    },
    NegativeMaxAge(name, option.unwrap(opts.max_age, 0)),
  )
  check_prefix(name, opts)
}

/// Check a complete cookie: name, value and options.
pub fn validate(
  name: String,
  value: String,
  opts: CookieOptions,
) -> Result(Nil, CookieError) {
  case validate_options(name, opts) {
    Error(error) -> Error(error)
    Ok(Nil) -> {
      use <- check(valid_value(value), InvalidValue(name))
      let bytes = string.byte_size(name) + string.byte_size(value)
      check(bytes <= max_name_value_bytes, TooLarge(name, bytes), fn() {
        Ok(Nil)
      })
    }
  }
}

/// Set a cookie on a response with the given options. A response carries
/// at most one Set-Cookie per name: setting a name again replaces it.
///
/// ```gleam
/// use resp <- result.try(
///   response.new(200)
///   |> cookie.set("session", token, cookie.default_options()),
/// )
/// ```
pub fn set(
  resp: Response(body),
  name: String,
  value: String,
  opts: CookieOptions,
) -> Result(Response(body), CookieError) {
  case validate(name, value, opts) {
    Error(error) -> {
      log.error(
        "brazier.cookie",
        "Refusing to set cookie: " <> error_to_string(error),
      )
      Error(error)
    }
    Ok(Nil) -> {
      let header = build_set_cookie(name, value, opts)
      let others =
        list.filter(resp.headers, fn(h) {
          !{ h.0 == "set-cookie" && string.starts_with(h.1, name <> "=") }
        })
      log.debug("brazier.cookie", "Set cookie " <> name)
      Ok(
        Response(
          ..resp,
          headers: list.append(others, [#("set-cookie", header)]),
        ),
      )
    }
  }
}

/// Set a cookie with default options (secure, HttpOnly, SameSite=Lax).
pub fn set_default(
  resp: Response(body),
  name: String,
  value: String,
) -> Result(Response(body), CookieError) {
  set(resp, name, value, default_options())
}

/// Delete a cookie set with `default_options()` (Secure, HttpOnly,
/// SameSite=Lax, path "/"): an empty value with Max-Age=0.
pub fn delete(
  resp: Response(body),
  name: String,
) -> Result(Response(body), CookieError) {
  delete_with_options(resp, name, default_options())
}

/// Delete a cookie using the same path/security attributes used to set it.
pub fn delete_with_options(
  resp: Response(body),
  name: String,
  opts: CookieOptions,
) -> Result(Response(body), CookieError) {
  set(resp, name, "", CookieOptions(..opts, max_age: Some(0)))
}

// --- Internal ---

fn check(
  ok: Bool,
  error: CookieError,
  next: fn() -> Result(Nil, CookieError),
) -> Result(Nil, CookieError) {
  case ok {
    True -> next()
    False -> Error(error)
  }
}

/// RFC 6265bis section 4.1.3: `__Secure-` needs Secure; `__Host-` needs
/// Secure and Path=/ (Brazier never sets Domain). Matched case-insensitively
/// in ASCII, as browsers do. `validate_options` refuses a name that is not
/// a token (`InvalidName`) before this runs, so the name is ASCII.
fn check_prefix(name: String, opts: CookieOptions) -> Result(Nil, CookieError) {
  let lower = ascii.lowercase(name)
  case
    string.starts_with(lower, "__secure-"),
    string.starts_with(lower, "__host-")
  {
    True, _ if !opts.secure ->
      Error(PrefixViolation(name, "__Secure- cookies require Secure"))
    _, True if !opts.secure ->
      Error(PrefixViolation(name, "__Host- cookies require Secure"))
    _, True if opts.path != "/" ->
      Error(PrefixViolation(name, "__Host- cookies require Path=/"))
    _, _ -> Ok(Nil)
  }
}

/// Parse a Cookie header string into (name, value) pairs.
/// Format: "name1=value1; name2=value2; ..."
fn parse_cookie_header(header: String) -> List(#(String, String)) {
  header
  |> string.split(";")
  |> list.filter_map(fn(part) {
    case string.split_once(string.trim(part), "=") {
      Ok(#(name, value)) ->
        case string.trim(name) {
          "" -> Error(Nil)
          trimmed -> Ok(#(trimmed, string.trim(value)))
        }
      Error(Nil) -> Error(Nil)
    }
  })
}

/// Build a Set-Cookie header value from validated parts.
fn build_set_cookie(
  name: String,
  value: String,
  opts: CookieOptions,
) -> String {
  let max_age = case opts.max_age {
    Some(age) -> ["Max-Age=" <> int.to_string(age)]
    None -> []
  }
  let http_only = case opts.http_only {
    True -> ["HttpOnly"]
    False -> []
  }
  let secure = case opts.secure {
    True -> ["Secure"]
    False -> []
  }
  [
    [name <> "=" <> value],
    max_age,
    ["Path=" <> opts.path],
    http_only,
    secure,
    ["SameSite=" <> opts.same_site],
  ]
  |> list.flatten
  |> string.join("; ")
}

@external(erlang, "brazier_cookie_ffi", "valid_name")
fn valid_name(name: String) -> Bool

@external(erlang, "brazier_cookie_ffi", "valid_value")
fn valid_value(value: String) -> Bool

@external(erlang, "brazier_cookie_ffi", "valid_path")
fn valid_path(path: String) -> Bool
