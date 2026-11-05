# Security

Beacon includes built-in security protections across the transport, middleware, and SSR layers.

## SecurityLimits

The `SecurityLimits` type in `beacon/transport` controls connection-level protections:

```gleam
pub type SecurityLimits {
  SecurityLimits(
    max_message_bytes: Int,        // Default: 65536 (64KB)
    max_events_per_second: Int,    // Default: 50
    max_connections: Int,          // Default: 10000
    max_http_headers: Int,         // Default: 100
    max_http_header_bytes: Int,    // Default: 65536
    pre_upgrade_timeout_ms: Int,   // Default: 5000
  )
}
```

Override defaults via the builder:

```gleam
import beacon
import beacon/transport

beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.security_limits(transport.SecurityLimits(
  ..transport.default_security_limits(),
  max_connections: 5000,
  max_events_per_second: 100,
))
|> beacon.start(8080)
```

Route-aware apps use the same `beacon.security_limits(builder, limits)` builder
as every other Beacon app.

## Origin Validation

On every WebSocket upgrade, the transport checks the `Origin` header against the `Host` header. Missing origins, empty origins, empty hosts, protocol-relative values, and mismatches are rejected with HTTP 403. Non-browser clients must send an explicit same-host `Origin` header.

## Rate Limiting

**Per-connection (server-side, transport layer):** Each WebSocket connection tracks events per 1-second sliding window. When `max_events_per_second` (default 50) is exceeded, the server sends a `ServerError("Rate limited")` message and drops the event. Heartbeats are exempt from rate limiting.

**HTTP middleware:** The `middleware.rate_limit(limiter)` middleware returns HTTP 429 when a client exceeds the configured request rate. It identifies clients by `X-Forwarded-For` header or request host.

## Message Size Limits

WebSocket text frames exceeding `max_message_bytes` (default 64KB) are rejected before decoding. The incomplete frame buffer is also capped before full-frame decode, so a peer cannot slowly accumulate an oversized partial frame. The server sends a `ServerError("Message too large")` response and closes the socket.

## Connection Limits

Global pre-upgrade and WebSocket connection count is tracked via ETS. When `max_connections` (default 10,000) is reached, new requests receive HTTP 503.

## HTTP Pre-Upgrade Limits

Before WebSocket upgrade, Beacon limits total header count, total request/header bytes, and total request/header read time using one monotonic deadline. Slow or oversized pre-upgrade requests fail before any runtime process is started.

## Response Header Validation

HTTP responses are validated immediately before serialization. Header names must be RFC token names, and header values must not contain CR, LF, or NUL bytes. Unsafe response headers fail loudly instead of being written to the socket, preventing HTTP response splitting from API routes or middleware.

## HTML Attribute Validation

Beacon escapes text and attribute values during SSR. Generic custom attribute names are validated before rendering and cannot be inline event attributes such as `onclick`; use Beacon event helpers instead. Event handler IDs are rendered as escaped attribute values.

`element.raw_html` and `head_html` are trusted-only escape hatches for already-sanitized HTML. Do not pass user input to them.

## Build And Dev Command Execution

Build and dev tooling launches `gleam`, `npx`, `fswatch`, and `inotifywait` with argv-based Erlang ports instead of shell strings. Project paths and path dependencies are not interpolated into shell commands.

## Secure Headers

The `middleware.secure_headers()` middleware (included by default in all apps) sets:

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: SAMEORIGIN`
- `X-XSS-Protection: 1; mode=block`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: camera=(), microphone=(), geolocation=()`
- `Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://avatars.githubusercontent.com; connect-src 'self' ws: wss:`

For a route that needs an extra WebTransport, EventSource, or fetch target,
keep the global default strict and add route-specific `connect-src` sources on
that response:

```gleam
api.text(200, "viewer")
|> middleware.with_csp_connect_src(["https://localhost:4433"])
```

`secure_headers()` merges the route addition into its baseline CSP and
normalizes the result so the response has one `connect-src` directive.

## Session Tokens

SSR pages set a signed join/state recovery token in the HttpOnly `beacon_join_token` cookie. The browser client sends an empty join token; the runtime reads the cookie from the WebSocket upgrade request. Tokens are created with `crypto.sign_message` using HMAC-SHA256 and contain a JSON payload with a timestamp, version, and optionally serialized model state. The `verify_session_token` function checks the signature and rejects tokens older than `max_age_seconds` (default 24 hours / 86400 seconds).

The cookie is `HttpOnly`, `SameSite=Lax`, path `/`, and has `Max-Age=86400`. JavaScript cannot read it, so XSS cannot directly steal the join token from DOM state.

Auto-generated secret keys are warned about at startup. Set an explicit key for production:

```gleam
beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.secret_key("your-production-secret")
|> beacon.start(8080)
```

## Application Session Auth

For application auth, prefer `beacon/auth` helpers over hand-written cookie and
CSRF handling. `auth.default_session_config()` sets an opaque `beacon_session`
cookie with `HttpOnly`, `Secure`, `SameSite=Lax`, and path `/`.

`auth.login_json_response()` and `auth.login_route()` create a server-side
session and a cryptographically random session-bound CSRF token. Return that
CSRF token in the login response body and require it on state-changing API
routes with `auth.protect_api_with_csrf()` or `auth.csrf_authenticated()`. Do
not store the CSRF token in a cookie.

Use `auth.protect_ws(store, config)` for WebSocket upgrades that should share
the same session policy. Use `auth.dev_session_config()` only for localhost
HTTP development, where the `Secure` cookie attribute would prevent the browser
from storing the cookie.

## Timer Cap

The effect system caps periodic timers at 10 per runtime process (`effect.every`). Attempts to create additional timers are rejected with a warning log. This prevents runaway timer creation from buggy update handlers.

## Model Size Bounds

The runtime tracks serialized model size. Models exceeding 1MB trigger a warning log. Models exceeding 5MB are rejected to prevent memory exhaustion.

## WebSocket Authentication

Optional custom auth can be added via the transport config's `ws_auth` field. When set, the function runs before the WebSocket upgrade and can reject connections with HTTP 401.
