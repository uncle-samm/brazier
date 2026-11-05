# Middleware

Beacon's middleware system processes HTTP requests and responses. Middleware can inspect/modify requests, modify responses, or short-circuit (e.g., return 401).

## Pipeline

A `Middleware` takes a request and a `next` function, returning a response. Chain them with `pipeline(middlewares, handler)` -- they execute in order:

```gleam
let handler = middleware.pipeline(
  [middleware.logger(), middleware.rate_limit(limiter)],
  my_app_handler,
)
```

## Built-in Middleware

| Function | Description |
|----------|-------------|
| `secure_headers()` | Sets CSP, X-Frame-Options, and other security headers (included by default) |
| `logger()` | Logs request method, path, and response status |
| `rate_limit(limiter)` | Returns 429 when requests exceed the configured rate |
| `compress()` | Gzip-compresses text responses when client sends `Accept-Encoding: gzip` |
| `request_id()` | Generates a unique `x-request-id` response header |
| `body_parser(max_bytes)` | Returns 413 if `Content-Length` exceeds `max_bytes` |
| `cors(config)` | Sets CORS headers; handles preflight OPTIONS with 204 |
| `secure_headers_with_csp(csp)` | Like `secure_headers()` but applies a custom CSP policy string |
| `csp_connect_src(sources)` | Adds route-scoped CSP `connect-src` sources when composed with `at`, `only`, or `methods` |

## Route-Specific CSP Connect Sources

Beacon keeps the default `connect-src 'self' ws: wss:` policy strict. When one
authenticated route needs an additional connection target, add it on that
response:

```gleam
api.get("/viewer", fn(_req) {
  api.text(200, "viewer")
  |> middleware.with_csp_connect_src(["https://localhost:4433"])
})
```

Or scope it as middleware:

```gleam
beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.with_middleware(
  middleware.at(
    "/viewer",
    middleware.csp_connect_src(["https://gateway.example"]),
  ),
)
```

Beacon merges these sources into the response CSP emitted by
`secure_headers()` and emits a single `connect-src` directive.

## Scoping

Apply middleware conditionally using scope functions:

```gleam
middleware.only("/admin", auth_middleware)       // Only paths starting with /admin
middleware.except("/public", auth_middleware)     // All paths EXCEPT /public prefix
middleware.at("/healthz", skip_auth_middleware)   // Exact path match only
middleware.methods([http.Post, http.Put], rate_limiter)  // Only specific HTTP methods
middleware.group([mw1, mw2, mw3])                // Combine multiple into one
```

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
