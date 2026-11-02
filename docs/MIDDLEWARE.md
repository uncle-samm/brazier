# Middleware

Beacon's middleware system processes HTTP requests and responses. Middleware can inspect/modify requests, modify responses, or short-circuit (e.g., return 401).

## Pipeline

A `Middleware` takes a request and a `next` function, returning a response. Chain them with `pipeline(middlewares, handler)` -- they execute in order:

```gleam
let assert Ok(limiter) =
  rate_limit.new("api", rate_limit.RateLimitConfig(max_requests: 100, window_seconds: 60))
  as "rate limiter settings are constants"
let handler = middleware.pipeline(
  [middleware.logger(), middleware.rate_limit(limiter)],
  my_app_handler,
)
```

`rate_limit.new` returns a `Result`: invalid settings, an invalid name, or a
name already in use are errors.

## Built-in Middleware

| Function | Description |
|----------|-------------|
| `secure_headers()` | Sets CSP, X-Frame-Options, and other security headers (included by default) |
| `logger()` | Logs request method, path, and response status |
| `rate_limit(limiter)` | Returns 429 (with `Retry-After`) when a client exceeds the configured rate. Keys on the socket peer IP; forwarding headers are ignored |
| `rate_limit_behind_proxies(limiter, trusted)` | Like `rate_limit`, but the client is resolved through trusted proxies (right-most untrusted `Forwarded` / `X-Forwarded-For` hop). See SECURITY.md, Trusted Proxies |
| `hsts(max_age_seconds, include_subdomains)` | Sets `Strict-Transport-Security`. Returns `Result` (negative max-age is an error). Use only behind HTTPS |
| `compress()` | Gzip-compresses text responses when client sends `Accept-Encoding: gzip` |
| `request_id()` | Generates a unique `x-request-id` response header |
| `body_parser(max_bytes)` | Returns 413 if `Content-Length` exceeds `max_bytes` |
| `cors(config)` | Sets CORS headers; handles preflight OPTIONS with 204 |
| `secure_headers_with_csp(csp)` | Like `secure_headers()` but applies a custom CSP policy string |

## Scoping

Apply middleware conditionally using scope functions:

```gleam
middleware.only("/admin", auth_middleware)       // /admin and paths below it
middleware.except("/public", auth_middleware)     // All paths EXCEPT /public and below
middleware.at("/healthz", skip_auth_middleware)   // Exact path match only
middleware.methods([http.Post, http.Put], rate_limiter)  // Only specific HTTP methods
middleware.group([mw1, mw2, mw3])                // Combine multiple into one
```

Paths are matched on segment boundaries, the way the routers read them:
`only("/admin", ..)` does not match `/administrator`, and empty segments and
dot segments are normalised, so `//admin` and `/public/../admin` cannot slip
past a scoped auth middleware. A trailing slash is ignored.

Add middleware to an app with `beacon.with_middleware(builder, mw)`. Route-aware
apps use the same builder because there is only one app startup path.

## Writing Custom Middleware

```gleam
fn require_api_key() -> middleware.Middleware {
  fn(req, next) {
    case request.get_header(req, "x-api-key") {
      Ok("valid-key") -> next(req)
      _ ->
        response.new(401)
        |> response.set_body(Bytes(bytes_tree.from_string("Unauthorized")))
    }
  }
}
```

## Reading Request Bodies

To read an HTTP request body manually (outside the middleware pipeline), use `transport_http.read_body(request, max_bytes)`. It returns `Result(BitArray, Nil)` and enforces the byte limit to prevent oversized payloads.

## Request Context

Middleware can pass data using `Context` (a `Dict(String, String)`): `new_context()`, `set_context(ctx, key, value)`, `get_context(ctx, key)`.
