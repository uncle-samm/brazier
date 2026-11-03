# Middleware

Beacon's middleware system processes HTTP requests and responses. Middleware can inspect/modify requests, modify responses, or short-circuit (e.g., return 401).

## Pipeline

A `Middleware` takes a request and a `next` function, returning a response.
Add one to an app with `beacon.with_middleware(app, mw)`; they run in the order
they are added, before the app's API routes, the framework routes
(`/health`, the client bundle, `/static`) and page rendering. They also run on
a WebSocket upgrade request: a middleware that answers instead of calling
`next` refuses the upgrade with its response.
`beacon.simple`, `beacon.application` and `beacon.full_application` start with
`secure_headers()` already in the list.

<!-- docs-check: wrap
import beacon/effect.{type Effect}
import beacon/element.{type Element}

{{block}}

pub type Model {
  Model
}

pub type Msg {
  Noop
}

fn init(_ctx: beacon.Context) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model, effect.none()))
}

pub fn update(model: Model, _msg: Msg) -> #(Model, Effect(Msg)) {
  #(model, effect.none())
}

pub fn view(_model: Model) -> Element(Msg) {
  element.text("page")
}
-->
```gleam
import beacon
import beacon/error.{type BeaconError}
import beacon/middleware
import beacon/rate_limit
import gleam/result

pub fn start() -> Result(Nil, BeaconError) {
  use limiter <- result.try(
    rate_limit.new(
      "api",
      rate_limit.RateLimitConfig(max_requests: 100, window_seconds: 60),
    )
    |> result.map_error(error.ConfigError),
  )
  beacon.application(init:, update:, view:)
  |> beacon.with_middleware(middleware.logger())
  |> beacon.with_middleware(middleware.rate_limit(limiter))
  |> beacon.start(8080)
}
```

`rate_limit.new` returns a `Result`: invalid settings, an invalid name, or a
name already in use are errors. `middleware.pipeline(middlewares, handler)`
chains middleware around a handler of your own, in the same order.

## Built-in Middleware

| Function | Description |
|----------|-------------|
| `secure_headers()` | Sets CSP, X-Frame-Options, and other security headers (in every app's list from the start) |
| `logger()` | Logs request method, path, and response status |
| `rate_limit(limiter)` | Returns 429 (with `Retry-After`) when a client exceeds the configured rate. Keys on the socket peer IP; forwarding headers are ignored |
| `rate_limit_behind_proxies(limiter, trusted)` | Like `rate_limit`, but the client is resolved through trusted proxies (right-most untrusted `Forwarded` / `X-Forwarded-For` hop). See SECURITY.md, Trusted Proxies |
| `hsts(max_age_seconds, include_subdomains)` | Sets `Strict-Transport-Security`. Returns `Result` (negative max-age is an error). Use only behind HTTPS |
| `compress()` | Gzip-compresses text responses when client sends `Accept-Encoding: gzip` |
| `request_id()` | Generates a unique `x-request-id` response header |
| `body_parser(max_bytes)` | Returns 413 if `Content-Length` exceeds `max_bytes`. A request without a `Content-Length` that parses as an integer passes through, so it is not a body limit: `api.read_text` and `api.read_form` enforce their own |
| `cors(config)` | Sets CORS headers; handles preflight OPTIONS with 204 |
| `secure_headers_with_csp(csp)` | Like `secure_headers()` but applies a custom CSP policy string |

## Scoping

Apply middleware conditionally using scope functions:

<!-- docs-check: wrap
import beacon/middleware.{type Middleware}
import gleam/http

pub fn scoped(
  auth_middleware: Middleware,
  rate_limiter: Middleware,
  mw1: Middleware,
  mw2: Middleware,
) -> List(Middleware) {
  [
    {{block}}
  ]
}
-->
```gleam
middleware.only("/admin", auth_middleware),     // /admin and paths below it
middleware.except("/public", auth_middleware),  // all paths except /public and below
middleware.at("/metrics", auth_middleware),     // this exact path only
middleware.methods([http.Post, http.Put], rate_limiter),  // only these methods
middleware.group([mw1, mw2]),                   // several as one
```

Paths are matched on segment boundaries, the way the routers read them:
`only("/admin", ..)` does not match `/administrator`, and empty segments and
dot segments are normalised, so `//admin` and `/public/../admin` cannot slip
past a scoped auth middleware. A trailing slash is ignored.

Route-aware apps use the same `beacon.with_middleware` builder because there
is only one app startup path.

## Writing Custom Middleware

```gleam
import beacon/api
import beacon/middleware.{type Middleware}
import beacon/session
import gleam/http/request

/// Refuse requests whose `x-api-key` header is not `expected`.
pub fn require_api_key(expected: String) -> Middleware {
  fn(req, next) {
    case request.get_header(req, "x-api-key") {
      Ok(key) ->
        // A constant-time comparison: the time taken does not reveal the key.
        case session.secure_compare(key, expected) {
          True -> next(req)
          False -> api.text(401, "Unauthorized")
        }
      Error(Nil) -> api.text(401, "Unauthorized")
    }
  }
}
```

## Reading Request Bodies

Read a body with `api.read_text(req, max_bytes)` (UTF-8 text) or
`api.read_form(req, max_bytes)` (URL-encoded form fields). Both return an
`Error` with the reason for a body over `max_bytes`, a body that is not valid
UTF-8 or a form that does not decode. See
[GETTING_STARTED.md](GETTING_STARTED.md#api-routes).

## Passing Data to the Handler

A middleware passes only the request to `next`, so data for the handler
travels on the request: set a header with `request.set_header(req, name,
value)` before calling `next`. `set_header` replaces any value the client sent
under that name, so the handler can trust it only when that middleware runs on
every path the handler serves.

`middleware.Context` with `new_context`, `set_context` and `get_context` is a
plain `Dict(String, String)`; nothing in the pipeline carries it from a
middleware to a handler.
