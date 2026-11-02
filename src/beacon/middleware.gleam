/// Middleware pipeline for request/response processing.
/// Middleware can inspect/modify requests, modify responses, or short-circuit
/// (e.g., return 401 for unauthorized requests).
///
/// The framework is auth-agnostic — middleware is the hook point for any
/// auth library. You plug in whatever auth you want.
///
/// Reference: Wisp middleware, Phoenix plugs, Express middleware.
import beacon/log
import beacon/rate_limit
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/string

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

/// Default Content-Security-Policy value.
const default_csp =
  "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://avatars.githubusercontent.com; connect-src 'self' ws: wss:"

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
    |> response.set_header("x-xss-protection", "1; mode=block")
    |> response.set_header("referrer-policy", "strict-origin-when-cross-origin")
    |> response.set_header(
      "permissions-policy",
      "camera=(), microphone=(), geolocation=()",
    )
    |> response.set_header("content-security-policy", csp)
  }
}

/// Rate limiting middleware — limits requests per IP using a RateLimiter.
/// Returns 429 Too Many Requests when the limit is exceeded.
pub fn rate_limit(limiter: rate_limit.RateLimiter) -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    // Use the request path + host as a simple client identifier
    // In production, you'd extract the real client IP from headers
    let client_key = case request.get_header(req, "x-forwarded-for") {
      Ok(ip) -> ip
      Error(Nil) -> req.host
    }
    case rate_limit.check(limiter, client_key) {
      rate_limit.Allowed(_remaining) -> next(req)
      rate_limit.RateLimited -> {
        response.new(429)
        |> response.set_header("content-type", "text/plain")
        |> response.set_header("retry-after", "60")
        |> response.set_body(Bytes(bytes_tree.from_string("Too Many Requests")))
      }
    }
  }
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

/// Body parser middleware — reads request body up to a size limit.
/// If the body exceeds `max_bytes`, returns 413 Payload Too Large.
/// Passes the request through if body is within limits or has no body.
pub fn body_parser(max_bytes: Int) -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    // Check Content-Length header if present
    case request.get_header(req, "content-length") {
      Ok(length_str) -> {
        case int.parse(length_str) {
          Ok(length) if length > max_bytes -> {
            log.warning(
              "beacon.middleware",
              "Request body too large: "
                <> int.to_string(length)
                <> " > "
                <> int.to_string(max_bytes),
            )
            response.new(413)
            |> response.set_header("content-type", "text/plain")
            |> response.set_body(
              Bytes(bytes_tree.from_string("Payload Too Large")),
            )
          }
          _ -> next(req)
        }
      }
      Error(Nil) -> next(req)
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

/// Apply middleware only when the request path starts with the given prefix.
///
/// ```gleam
/// middleware.only("/admin", auth.require_auth(store))
/// middleware.only("/api", middleware.rate_limit(limiter))
/// ```
pub fn only(prefix: String, mw: Middleware) -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case string.starts_with(req.path, prefix) {
      True -> mw(req, next)
      False -> next(req)
    }
  }
}

/// Apply middleware only when the request path exactly matches.
///
/// ```gleam
/// middleware.at("/healthz", middleware.skip_auth())
/// ```
pub fn at(path: String, mw: Middleware) -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case req.path == path {
      True -> mw(req, next)
      False -> next(req)
    }
  }
}

/// Apply middleware to all paths EXCEPT those starting with the given prefix.
/// Useful for skipping auth on public routes.
///
/// ```gleam
/// middleware.except("/public", auth.require_auth(store))
/// ```
pub fn except(prefix: String, mw: Middleware) -> Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case string.starts_with(req.path, prefix) {
      True -> next(req)
      False -> mw(req, next)
    }
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

/// Request context — a dictionary that middleware can attach data to.
/// This is how middleware passes information (e.g., authenticated user)
/// to the application handler.
pub type Context =
  Dict(String, String)

/// Create a new empty context.
pub fn new_context() -> Context {
  dict.new()
}

/// Set a value in the context.
pub fn set_context(ctx: Context, key: String, value: String) -> Context {
  dict.insert(ctx, key, value)
}

/// Get a value from the context.
pub fn get_context(ctx: Context, key: String) -> Result(String, Nil) {
  dict.get(ctx, key)
}
