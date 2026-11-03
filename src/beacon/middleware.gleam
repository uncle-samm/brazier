/// Middleware pipeline for request/response processing.
/// Middleware can inspect/modify requests, modify responses, or short-circuit
/// (e.g., return 401 for unauthorized requests).
///
/// The framework is auth-agnostic — middleware is the hook point for any
/// auth library. You plug in whatever auth you want.
///
/// Reference: Wisp middleware, Phoenix plugs, Express middleware.
import beacon/internal/http_status
import beacon/ip
import beacon/log
import beacon/rate_limit
import beacon/transport/client
import beacon/transport/http as transport_http
import beacon/transport/server.{type Connection, type ResponseBody, Bytes, File}
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/string
import gleam/uri

/// A middleware function.
/// Takes a request and a `next` function, returns a response.
/// Can modify the request before passing to next, modify the response after,
/// or short-circuit by returning a response without calling next.
pub type Middleware =
  fn(Request(Connection), fn(Request(Connection)) -> Response(ResponseBody)) ->
    Response(ResponseBody)

/// Chain multiple middleware into a single handler.
/// Middleware execute in order: first middleware wraps the second, etc.
/// The innermost handler is the actual app handler.
///
/// Example:
/// ```gleam
/// let handler = middleware.pipeline(
///   [middleware.logger(), middleware.cors(cors_config)],
///   my_app_handler,
/// )
/// ```
pub fn pipeline(
  middlewares: List(Middleware),
  handler: fn(Request(Connection)) -> Response(ResponseBody),
) -> fn(Request(Connection)) -> Response(ResponseBody) {
  list.fold_right(middlewares, handler, fn(next, mw) {
    fn(req: Request(Connection)) { mw(req, next) }
  })
}

/// Logger middleware — logs request method, path, and response status.
pub fn logger() -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    let method = http.method_to_string(req.method)
    let path = req.path
    log.info("beacon.middleware", method <> " " <> path)
    let resp = next(req)
    log.info(
      "beacon.middleware",
      method <> " " <> path <> " → " <> int.to_string(resp.status),
    )
    resp
  }
}

/// CORS configuration.
pub type CorsConfig {
  CorsConfig(
    /// Allowed origins (e.g., ["https://example.com"]). Use ["*"] for any.
    allow_origins: List(String),
    /// Allowed HTTP methods.
    allow_methods: List(String),
    /// Allowed headers.
    allow_headers: List(String),
    /// Max age for preflight cache (seconds).
    max_age: Int,
  )
}

/// Default CORS config allowing all origins.
pub fn default_cors() -> CorsConfig {
  CorsConfig(
    allow_origins: ["*"],
    allow_methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers: ["content-type", "authorization"],
    max_age: 86_400,
  )
}

/// CORS middleware — sets Access-Control-* headers.
pub fn cors(config: CorsConfig) -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    let origin = string.join(config.allow_origins, ", ")
    let methods = string.join(config.allow_methods, ", ")
    let headers = string.join(config.allow_headers, ", ")

    // Handle preflight OPTIONS request
    case req.method {
      http.Options -> {
        response.new(204)
        |> response.set_header("access-control-allow-origin", origin)
        |> response.set_header("access-control-allow-methods", methods)
        |> response.set_header("access-control-allow-headers", headers)
        |> response.set_header(
          "access-control-max-age",
          int.to_string(config.max_age),
        )
        |> response.set_body(Bytes(bytes_tree.new()))
      }
      _ -> {
        let resp = next(req)
        resp
        |> response.set_header("access-control-allow-origin", origin)
      }
    }
  }
}

/// Security headers middleware — sets common security headers.
/// Reference: OWASP secure headers project.
/// Uses the default CSP policy. For custom CSP, use `secure_headers_with_csp`.
pub fn secure_headers() -> Middleware {
  secure_headers_with_csp(default_csp)
}

/// Default Content-Security-Policy value. `frame-ancestors 'self'` is the
/// CSP equivalent of `X-Frame-Options: SAMEORIGIN` (clickjacking);
/// `object-src 'none'` and `base-uri 'self'` close plugin and `<base>`
/// injection vectors.
pub const default_csp =
  "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://avatars.githubusercontent.com; connect-src 'self' ws: wss:; frame-ancestors 'self'; object-src 'none'; base-uri 'self'"

/// Security headers middleware with a custom Content-Security-Policy.
/// Use this when the default CSP is too strict (e.g., external stylesheets,
/// fonts, or images from CDNs).
///
/// Example:
/// ```gleam
/// middleware.secure_headers_with_csp(
///   "default-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' https://fonts.gstatic.com; connect-src 'self' ws: wss:",
/// )
/// ```
pub fn secure_headers_with_csp(csp: String) -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    let resp = next(req)
    resp
    |> response.set_header("x-content-type-options", "nosniff")
    |> response.set_header("x-frame-options", "SAMEORIGIN")
    // OWASP: the legacy XSS auditor is itself exploitable; disable it and
    // rely on CSP.
    |> response.set_header("x-xss-protection", "0")
    |> response.set_header("referrer-policy", "strict-origin-when-cross-origin")
    |> response.set_header(
      "permissions-policy",
      "camera=(), microphone=(), geolocation=()",
    )
    |> response.set_header("content-security-policy", csp)
  }
}

/// HTTP Strict Transport Security. Add this when the app is served over
/// HTTPS (Beacon does not terminate TLS: this is for deployments behind a
/// TLS proxy). Browsers ignore the header on plain-http responses
/// (RFC 6797 section 8.1), so it cannot pin an http-only deployment.
/// A typical production value is one year: `hsts(31_536_000, True)`.
/// Errors on a negative max-age.
pub fn hsts(
  max_age_seconds: Int,
  include_subdomains: Bool,
) -> Result(Middleware, String) {
  case max_age_seconds < 0 {
    True -> {
      let reason =
        "HSTS max-age must be >= 0, got " <> int.to_string(max_age_seconds)
      log.error("beacon.middleware", reason)
      Error(reason)
    }
    False -> {
      let value =
        "max-age="
        <> int.to_string(max_age_seconds)
        <> case include_subdomains {
          True -> "; includeSubDomains"
          False -> ""
        }
      log.info("beacon.middleware", "HSTS enabled: " <> value)
      Ok(
        fn(
          req: Request(Connection),
          next: fn(Request(Connection)) -> Response(ResponseBody),
        ) -> Response(ResponseBody) {
          next(req)
          |> response.set_header("strict-transport-security", value)
        },
      )
    }
  }
}

/// Rate limiting middleware — limits requests per client IP.
/// Returns 429 Too Many Requests when the limit is exceeded.
///
/// The client is the socket peer address. Forwarding headers
/// (`X-Forwarded-For`, `Forwarded`) are ignored, so a client cannot dodge
/// the limit by inventing addresses. Behind a reverse proxy use
/// `rate_limit_behind_proxies`, otherwise every client shares the proxy's
/// budget.
pub fn rate_limit(limiter: rate_limit.RateLimiter) -> Middleware {
  rate_limit_behind_proxies(limiter, ip.no_trusted_proxies())
}

/// Rate limiting keyed on the client IP resolved through trusted proxies:
/// forwarding headers are honoured only when the socket peer is one of
/// `trusted`, and the client is the right-most hop that is not a trusted
/// proxy. Build `trusted` with `ip.parse_trusted_proxies` (use the same
/// list as `SecurityLimits.trusted_proxies`).
pub fn rate_limit_behind_proxies(
  limiter: rate_limit.RateLimiter,
  trusted: ip.TrustedProxies,
) -> Middleware {
  let retry_after = int.to_string(limiter.config.window_seconds)
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case client.ip(req, trusted) {
      Error(reason) -> {
        // No peer address means the connection is already gone; refuse
        // rather than lumping the request in with some other key.
        log.warning(
          "beacon.middleware",
          "Rate limit cannot identify client: " <> reason,
        )
        plain_text(400, "Bad Request")
      }
      Ok(client_ip) ->
        case rate_limit.check(limiter, client_ip) {
          rate_limit.Allowed(_remaining) -> next(req)
          rate_limit.RateLimited ->
            plain_text(429, "Too Many Requests")
            |> response.set_header("retry-after", retry_after)
        }
    }
  }
}

fn plain_text(status: Int, body: String) -> Response(ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

/// Request ID middleware — generates a unique ID for each request.
/// Adds `x-request-id` to the response headers and logs it.
/// Useful for tracing requests through distributed systems.
pub fn request_id() -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    let id = generate_request_id()
    log.debug("beacon.middleware", "Request " <> id <> ": " <> req.path)
    let resp = next(req)
    resp
    |> response.set_header("x-request-id", id)
  }
}

/// Body limit middleware: refuses a request whose declared body is not
/// acceptable before the handler runs. It reads no body.
///
/// The length is checked with the listener's own framing rules
/// (`transport/http.declared_body_length`, RFC 9112 section 6):
/// - a request with neither Content-Length nor Transfer-Encoding has an
///   empty body and passes;
/// - a Content-Length that is not 1-19 ASCII digits, or more than one, is
///   answered with 400;
/// - Transfer-Encoding is answered with 501 (400 with a Content-Length);
/// - a length above `max_bytes` is answered with 413.
///
/// The listener applies the same rules with its own `max_body_bytes` before
/// any middleware runs, so this middleware is a tighter limit for the
/// routes it wraps.
///
/// Reference: Bandit (`Bandit.Headers.get_content_length`) and Cowboy answer
/// a bad Content-Length with 400 and treat a missing one as an empty body;
/// Plug.Parsers answers an oversized body with 413.
pub fn body_parser(max_bytes: Int) -> Middleware {
  // A negative limit is a programming error: no request could pass.
  let assert True = max_bytes >= 0
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case transport_http.declared_body_length(req, max_bytes) {
      Ok(_length) -> next(req)
      // declared_body_length has logged the refusal with the path.
      Error(transport_http.FramingError(status:, reason: _)) -> {
        response.new(status)
        |> response.set_header("content-type", "text/plain; charset=utf-8")
        |> response.set_body(
          Bytes(bytes_tree.from_string(http_status.reason_phrase(status))),
        )
      }
    }
  }
}

/// Compression middleware — compresses response body with gzip when the
/// client sends `Accept-Encoding: gzip`.
/// Only compresses text-based responses (HTML, CSS, JS, JSON).
pub fn compress() -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    let accepts_gzip = case request.get_header(req, "accept-encoding") {
      Ok(val) -> string.contains(val, "gzip")
      Error(Nil) -> {
        log.debug("beacon.middleware", "No Accept-Encoding header")
        False
      }
    }
    let resp = next(req)
    case accepts_gzip {
      False -> resp
      True -> {
        // Only compress if response is compressible (text-based content)
        case response.get_header(resp, "content-type") {
          Ok(ct) -> {
            case is_compressible(ct) {
              True -> compress_response(resp)
              False -> resp
            }
          }
          Error(Nil) -> resp
        }
      }
    }
  }
}

/// Check if a content type is compressible.
fn is_compressible(content_type: String) -> Bool {
  string.contains(content_type, "text/")
  || string.contains(content_type, "application/javascript")
  || string.contains(content_type, "application/json")
  || string.contains(content_type, "image/svg")
}

/// Compress a response body with gzip.
///
/// A `File` body (a static file, sent with `file:sendfile`) is sent as it
/// is: compressing it would mean reading the whole file into memory, which
/// is what sendfile avoids. cowboy_compress_h makes the same choice for
/// sendfile bodies.
fn compress_response(resp: Response(ResponseBody)) -> Response(ResponseBody) {
  case resp.body {
    Bytes(body_tree) -> {
      let body_str = bytes_tree.to_bit_array(body_tree)
      let compressed = gzip_compress(body_str)
      resp
      |> response.set_header("content-encoding", "gzip")
      |> response.set_header("vary", "Accept-Encoding")
      |> response.set_body(Bytes(bytes_tree.from_bit_array(compressed)))
    }
    File(path:, ..) -> {
      log.debug(
        "beacon.middleware",
        "compress: sending file body " <> path <> " uncompressed",
      )
      resp
    }
  }
}

/// Generate a unique request ID.
fn generate_request_id() -> String {
  let unique = erlang_unique_integer()
  let time = erlang_monotonic_time()
  "req_" <> int.to_string(time) <> "_" <> int.to_string(unique)
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

@external(erlang, "erlang", "monotonic_time")
fn erlang_monotonic_time() -> Int

@external(erlang, "zlib", "gzip")
fn gzip_compress(data: BitArray) -> BitArray

// ===== Route Scoping =====
//
// Paths are compared segment by segment, the way the routers see them, not
// as raw strings: `only("/admin", ..)` covers `/admin` and `/admin/users`
// but not `/administrator`, and `//admin` or `/public/../admin` cannot slip
// past it. A request path is read two ways — raw segments with empty ones
// dropped (page routing, `route.parse_path`) and dot-segment-resolved
// segments (API routing, `request.path_segments`) — and each combinator
// picks the conservative answer for its purpose.

/// Apply middleware only when the request path is `prefix` or below it
/// (segment boundary). Applied when either reading of the path matches.
///
/// ```gleam
/// middleware.only("/admin", auth.require_auth(store))
/// middleware.only("/api", middleware.rate_limit(limiter))
/// ```
pub fn only(prefix: String, mw: Middleware) -> Middleware {
  let prefix_segments = raw_segments(prefix)
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case
      list.any(path_readings(req.path), fn(segments) {
        has_segment_prefix(segments, prefix_segments)
      })
    {
      True -> mw(req, next)
      False -> next(req)
    }
  }
}

/// Apply middleware only when the request path is exactly `path`
/// (ignoring empty segments and a trailing slash). Applied when either
/// reading of the path matches.
///
/// ```gleam
/// middleware.at("/login", middleware.rate_limit(login_limiter))
/// ```
pub fn at(path: String, mw: Middleware) -> Middleware {
  let target = raw_segments(path)
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case list.contains(path_readings(req.path), target) {
      True -> mw(req, next)
      False -> next(req)
    }
  }
}

/// Apply middleware to all paths EXCEPT `prefix` and below it (segment
/// boundary). Useful for skipping auth on public routes. The middleware is
/// skipped only when BOTH readings of the path are under the prefix, so
/// `/public/../admin` still gets it.
///
/// ```gleam
/// middleware.except("/public", auth.require_auth(store))
/// ```
pub fn except(prefix: String, mw: Middleware) -> Middleware {
  let prefix_segments = raw_segments(prefix)
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case
      list.all(path_readings(req.path), fn(segments) {
        has_segment_prefix(segments, prefix_segments)
      })
    {
      True -> next(req)
      False -> mw(req, next)
    }
  }
}

fn path_readings(path: String) -> List(List(String)) {
  [raw_segments(path), uri.path_segments(path)]
}

fn raw_segments(path: String) -> List(String) {
  path
  |> string.split("/")
  |> list.filter(fn(segment) { segment != "" })
}

fn has_segment_prefix(segments: List(String), prefix: List(String)) -> Bool {
  case prefix, segments {
    [], _ -> True
    [_, ..], [] -> False
    [p, ..prefix_rest], [s, ..rest] ->
      p == s && has_segment_prefix(rest, prefix_rest)
  }
}

/// Apply middleware only for specific HTTP methods.
///
/// ```gleam
/// middleware.methods([http.Post, http.Put], middleware.rate_limit(limiter))
/// ```
pub fn methods(allowed: List(http.Method), mw: Middleware) -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case list.contains(allowed, req.method) {
      True -> mw(req, next)
      False -> next(req)
    }
  }
}

/// Group multiple middleware into one. All run in order on matching requests.
///
/// ```gleam
/// middleware.only("/admin", middleware.group([
///   auth.require_auth(store),
///   auth.csrf_protection(store),
///   middleware.rate_limit(limiter),
/// ]))
/// ```
pub fn group(middlewares: List(Middleware)) -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    let handler = pipeline(middlewares, next)
    handler(req)
  }
}
