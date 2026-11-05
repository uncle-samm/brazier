# Middleware

Brazier's middleware system processes HTTP requests and responses. Middleware can inspect/modify requests, modify responses, or short-circuit (e.g., return 401).

## Pipeline

A `Middleware` takes a request and a `next` function, returning a response.
Add one to an app with `brazier.with_middleware(app, mw)`; they run in the order
they are added, before the app's API routes, the framework routes
(`/health`, the client bundle, `/static`) and page rendering.
`brazier.simple`, `brazier.application` and `brazier.full_application` start with
`secure_headers()` already in the list.

<!-- docs-check: wrap
import brazier/effect.{type Effect}
import brazier/element.{type Element}

{{block}}

pub type Model {
  Model
}

pub type Msg {
  Noop
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
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
import brazier
import brazier/error.{type BrazierError}
import brazier/middleware
import brazier/rate_limit
import gleam/result

pub fn start() -> Result(Nil, BrazierError) {
  use limiter <- result.try(
    rate_limit.new(
      "api",
      rate_limit.RateLimitConfig(max_requests: 100, window_seconds: 60),
    )
    |> result.map_error(error.ConfigError),
  )
  brazier.application(init:, update:, view:)
  |> brazier.with_middleware(middleware.logger())
  |> brazier.with_middleware(middleware.rate_limit(limiter))
  |> brazier.start(8080)
}
```

`rate_limit.new` returns a `Result`: invalid settings, an invalid name, or a
name already in use are errors. `middleware.pipeline(middlewares, handler)`
chains middleware around a handler of your own, in the same order.

## The Live Page

The middleware also decides which pages a live session may show, so a
WebSocket cannot reach a page the middleware refuses over HTTP. It runs on
the page, not on the `/ws` request: Brazier builds a `GET` of the page with
the connection's upgrade headers (its cookies, `Authorization` and
forwarding headers) and runs the pipeline on it, at three points:

| When | Page | Refusal |
|------|------|---------|
| The WebSocket upgrade | the upgrade's required `path` query parameter (`/ws?path=%2Fadmin`) | the handshake completes and the socket closes at once with 4600 `middleware refused <status>`; no runtime starts (upgrade result `rejected_middleware`). The client loads the page, so the browser gets the middleware's answer |
| A client `navigate` (link click, back/forward, `router.push`/`replace`) | the target path | `hard_navigate` to it: the browser loads it over HTTP and gets the middleware's answer |
| A `join` for a page other than the upgrade's | the joined path | `hard_navigate`, as for `navigate` |

A browser cannot read the HTTP status of a failed upgrade: a 403 looks like
an unreachable server. So the upgrade does not answer with the middleware's
response. The middleware runs after the origin, `ws_auth` and handshake
checks, and a refusal is a 101 followed by close 4600, which the client can
read. The client stops reconnecting and loads the current URL, behind the
same guard as its other reloads (at most 3 per tab within 60 seconds; see
[WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#client-connection-behaviour)). The
server logs the refusal as a warning with the connection id, the page and
the status. LiveView does the same for a refused join: `onJoinError`
navigates to the page's URL.

A middleware that refuses a page's live connection but admits its `GET`
(it tells the two apart by `Upgrade: websocket`, say) makes the page load
three times, then show the client's error notice. Gate the page the same
way for both, or check the socket with `brazier.ws_auth`.

The page is admitted when the pipeline reaches the handler (some middleware
calls `next` all the way through); any response a middleware returns
instead is a refusal. A refused navigation is logged as a warning and emits
`[brazier, ws, navigation_refused]` (see
[TELEMETRY.md](TELEMETRY.md#event-catalogue)); the runtime never sees it,
so no `on_change` runs. A `path` that is not a same-origin path (see
[SECURITY.md](SECURITY.md#navigation-targets)) gets 400 on the upgrade
(`rejected_path`) and an `error` frame on `navigate` or `join`.

This follows Phoenix LiveView, which runs a `live_session`'s `on_mount`
hooks at the connected mount and at every live navigation, and answers an
unauthorized navigation with a full page load through the router's plugs.

Consequences for a middleware:

- It sees the method `GET` and the page's path and query, plus the upgrade
  request's headers, including `Upgrade: websocket`. It must decide from
  the request alone: a response it builds (headers, cookies, a body) is not
  sent for a navigation, and `next`'s response is not the page.
- It runs once per navigation, so a rate limiter in the pipeline counts
  live navigations as page loads.
- Nothing runs on the `/ws` request itself: `middleware.only("/ws", ..)`
  never applies. Check the socket with `brazier.ws_auth` (see
  [SECURITY.md](SECURITY.md#websocket-authentication)).

## Built-in Middleware

| Function | Description |
|----------|-------------|
| `secure_headers()` | Sets CSP, X-Frame-Options, and other security headers (in every app's list from the start) |
| `logger()` | Logs request method, path, and response status |
| `rate_limit(limiter)` | Returns 429 (with `Retry-After`) when a client exceeds the configured rate. Keys on the socket peer IP; forwarding headers are ignored |
| `rate_limit_behind_proxies(limiter, trusted)` | Like `rate_limit`, but the client is resolved through trusted proxies (the right-most untrusted hop of the one forwarding header `trusted` names). Parse `trusted` once, when building the pipeline, with `ip.parse_trusted_proxies` or `transport.trusted_proxies(limits)`. On a WebSocket connection it reuses the upgrade's one resolution of the client (built from the listener's limits, the proxies are equal), so the forwarding header is parsed once per connection. See SECURITY.md, Trusted Proxies |
| `hsts(max_age_seconds, include_subdomains)` | Sets `Strict-Transport-Security`. Returns `Result` (negative max-age is an error). Use only behind HTTPS |
| `compress()` | Gzip-compresses text responses when client sends `Accept-Encoding: gzip`. A file body (a static file sent with `sendfile`) is passed through uncompressed |
| `request_id()` | Generates a unique `x-request-id` response header |
| `body_parser(max_bytes)` | Applies the listener's framing rule with a tighter limit: 413 if `Content-Length` exceeds `max_bytes`, 400 if it is repeated or not a plain decimal integer, 501 for `Transfer-Encoding`, 400 for both. A request with neither header has no body and passes through |
| `cors(config)` | Sets CORS headers; handles preflight OPTIONS with 204 |
| `secure_headers_with_csp(csp)` | Like `secure_headers()` but applies a custom CSP policy string |

## Scoping

Apply middleware conditionally using scope functions:

<!-- docs-check: wrap
import brazier/middleware.{type Middleware}
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
`only("/admin", ..)` does not match `/administrator`. A path is read with
empty segments dropped, with dot segments resolved, and both again after
percent-decoding (the page router decodes segments, so `/%61dmin` is the
`admin` page). `only` and `at` apply when any reading matches, and `except`
skips its middleware only when every reading is under the prefix, so
`//admin`, `/%61dmin`, `/public/../admin` and `/public/%2E%2E/admin` cannot
slip past a scoped auth middleware. A trailing slash is ignored.

Route-aware apps use the same `brazier.with_middleware` builder because there
is only one app startup path.

## Writing Custom Middleware

```gleam
import brazier/api
import brazier/middleware.{type Middleware}
import brazier/session
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
`Error` with the reason for a missing or invalid `Content-Length`, a body
over `max_bytes`, a body already read, a read that failed or timed out, a
body that is not valid UTF-8 or a form that does not decode. See
[GETTING_STARTED.md](GETTING_STARTED.md#api-routes).

## Passing Data to the Handler

A middleware passes only the request to `next`, so data for the handler
travels on the request: set a header with `request.set_header(req, name,
value)` before calling `next`. `set_header` replaces any value the client sent
under that name, so the handler can trust it only when that middleware runs on
every path the handler serves.
