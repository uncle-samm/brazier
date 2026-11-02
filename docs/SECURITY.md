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

**HTTP middleware:** The `middleware.rate_limit(limiter)` middleware returns HTTP 429 (with `Retry-After` set to the window length) when a client exceeds the configured request rate. It keys on the socket peer address and ignores `X-Forwarded-For` / `Forwarded`, so a client cannot get a fresh budget by inventing addresses. Behind a reverse proxy use `middleware.rate_limit_behind_proxies(limiter, trusted)` (see Trusted Proxies). A request whose peer address cannot be read gets 400.

The limiter (`beacon/rate_limit`) is a fixed-window counter in an ETS table owned by a dedicated process, linked to and monitoring its creator. Memory is bounded: expired windows are swept every window, and the table holds at most `max_keys` clients (default `rate_limit.default_max_keys`, 100,000; set it with `rate_limit.new_with_max_keys`). At the cap, new clients are refused (fail closed) while known clients keep their budget, and every sweep logs an error with the number of refusals. If the limiter process is gone, every check is refused and logged.

## Trusted Proxies

`SecurityLimits.trusted_proxies` lists the reverse proxies (addresses or CIDRs such as `"10.0.0.0/8"`, `"fd00::/8"`) whose forwarding headers Beacon believes. It is validated at startup; an invalid entry refuses to start. `beacon/transport/client` is the single resolver used by the HTTP rate limiter, the per-IP WebSocket cap and the WebSocket Origin check:

- **Client IP:** the socket peer, unless the peer is a trusted proxy. Then it is the right-most `Forwarded` (preferred) or `X-Forwarded-For` hop that is not itself a trusted proxy (RFC 7239 section 7.4; the Plug `RemoteIp` / Rails `remote_ip` rule). A client can prepend hops but cannot forge the ones its proxies append. A malformed hop stops the walk at the last trusted address and is logged.
- **Scheme:** `http` (Beacon does not terminate TLS), unless a trusted proxy sends `X-Forwarded-Proto`, which must then be `http` or `https`; anything else, or several of the header, rejects the request. From an untrusted peer the header is ignored, so a direct client cannot claim `https` to pass an `https://` Origin check.

With the default empty list, no forwarding header is ever honoured. Use the same list for `middleware.rate_limit_behind_proxies` via `ip.parse_trusted_proxies` (or `transport.trusted_proxies(limits)`).

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
- `X-XSS-Protection: 0` (the legacy XSS auditor is itself exploitable; OWASP recommends disabling it and relying on CSP)
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: camera=(), microphone=(), geolocation=()`
- `Content-Security-Policy:` `middleware.default_csp`, which is `default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://avatars.githubusercontent.com; connect-src 'self' ws: wss:; frame-ancestors 'self'; object-src 'none'; base-uri 'self'`. `frame-ancestors 'self'` is the CSP form of `X-Frame-Options: SAMEORIGIN`.

HSTS is opt-in because Beacon does not terminate TLS: add `middleware.hsts(31_536_000, True)` (it returns a `Result`; a negative max-age is an error) when the app is served over HTTPS behind a TLS proxy.

## Route Scoping

`middleware.only`, `middleware.at` and `middleware.except` compare paths segment by segment, the way the routers read them, not as raw string prefixes. `only("/admin", mw)` covers `/admin` and `/admin/users` but not `/administrator`. A path is read both with empty segments dropped (page routing) and with dot segments resolved (API routing): `only` and `at` apply when either reading matches, and `except` skips the middleware only when both readings are under the prefix. So `//admin` still gets `only("/admin", auth)`, and `/public/../admin` still gets `except("/public", auth)`.

## Session Tokens

SSR pages set a signed join/state recovery token in the HttpOnly `beacon_join_token` cookie. The browser client sends an empty join token; the runtime reads the cookie from the WebSocket upgrade request. Tokens are created with `crypto.sign_message` using HMAC-SHA256 and contain a JSON payload with a timestamp, version, and optionally serialized model state. The `verify_session_token` function checks the signature and rejects tokens older than `max_age_seconds` (default 24 hours / 86400 seconds).

The cookie is `HttpOnly`, `SameSite=Lax`, path `/`, and has `Max-Age=86400`. JavaScript cannot read it, so XSS cannot directly steal the join token from DOM state.

The secret key must be at least 32 bytes (`config.min_secret_key_bytes`, the
HMAC-SHA256 output size; RFC 2104 section 3). `application.start`,
`start_advanced` and `start_supervised` refuse an empty key, a shorter key and
the formerly built-in dev secret with a `ConfigError` before any process is
started or port bound. The key is never logged. `config.secret_key()` reads
`SECRET_KEY` and applies the same check; there is no default.

`beacon.app` generates a random per-process key when none is set, and warns at
startup: tokens then die on restart and differ between nodes. Set an explicit
key for production (generate one with `openssl rand -base64 48`):

```gleam
let assert Ok(secret) = config.secret_key() as "SECRET_KEY must be set"
beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.secret_key(secret)
|> beacon.start(8080)
```

## CSRF Tokens

`beacon/form` CSRF tokens are 256 random bits from
`crypto.strong_random_bytes`, hex encoded; they are not derived from the
secret key, the time or a counter. `form.verify_session_csrf` compares the
submitted token with `crypto:hash_equals` (constant time) and consumes it with
an atomic compare-and-delete, so a token is accepted exactly once even when
several requests race, and a wrong guess does not burn the real token.
Issuing a new token for a session replaces the old one.

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

The login and logout helpers return `Result(_, cookie.CookieError)`. The
cookie config is checked before a session is created, so an invalid
`SessionConfig` never leaves an orphan session; `auth.login_route()` and
`auth.logout_route()` answer 500 and log the error.

## Cookies

`beacon/cookie` validates every cookie it sets against RFC 6265 and returns a
`Result`; nothing is stripped or rewritten:

- the name must be an RFC 7230 token;
- the value must be cookie-octets (optionally wrapped in double quotes): no
  whitespace, `;`, `,`, `"`, `\` or control bytes, so a value cannot add its own
  attributes (`abc; Domain=evil.example`) or headers;
- `Path` must start with `/` and contain no control bytes or `;`;
- `SameSite` must be exactly `Strict`, `Lax` or `None`, and `None` needs
  `Secure`;
- `Max-Age` cannot be negative;
- `__Secure-` names need `Secure`, and `__Host-` names need `Secure` and
  `Path=/` (prefixes are matched case-insensitively, as browsers do);
- name plus value is at most 4096 bytes and the path at most 1024 bytes.

A response carries one `Set-Cookie` per name: setting a name again replaces
it, and other cookies are kept. `cookie.delete` uses the same attributes as
`cookie.default_options()` (including `Secure`); use `delete_with_options`
for a cookie set with other options. Error messages name the cookie but never
include its value.

When the browser sends two cookies with the same name, `cookie.get` returns
the first. A sibling subdomain can plant such a cookie ("cookie tossing"); a
`__Host-` name prevents that, because the browser accepts it only from the
exact host, with `Secure` and `Path=/`.

## File Uploads

`beacon/upload` trusts nothing the client sends in a multipart request:

- **Bounded reading.** `upload.read_multipart(req, config)` refuses a
  non-multipart Content-Type (415) before touching the body, and a declared
  Content-Length above `max_request_bytes` (413, default 11 MB) before reading
  a byte. It then reads exactly that many bytes; chunked bodies are refused by
  the server, so a request never buffers more than the cap. Each file is then
  held to `max_size` (default 10 MB).
- **Content sniffing.** A file's type comes from its leading bytes: PNG, JPEG,
  GIF, WebP and PDF are recognised. The sniffed type must be in
  `allowed_types` *and* match the declared Content-Type (case and parameters
  ignored). Bytes that match no signature (HTML, SVG, scripts, text) are
  refused, whatever they claim to be. `validate_config` refuses an allow-list
  naming a type that cannot be sniffed.
- **Strict parsing.** A missing close delimiter, a part without a `form-data`
  Content-Disposition or name, duplicate part headers, a non-UTF-8 field and an
  invalid boundary are all errors; a single bad file fails the whole form.
- **Storage.** `upload.save(file, dir)` names the file `<32 random hex>.<ext>`,
  with the extension taken from the content, and creates it exclusively
  (`O_EXCL`), so an existing file or planted symlink is never overwritten. The
  client's filename is kept only as `original_filename`: reduced to its last
  path segment, without control characters, at most 255 characters.
- **Serving.** `upload.serve(dir, stored_name, download_name)` accepts only a
  name `save` produced, reads only regular files, takes the Content-Type from
  the stored extension and always answers with `Content-Disposition:
  attachment` (RFC 6266, with an RFC 8187 `filename*`),
  `X-Content-Type-Options: nosniff` and `Content-Security-Policy: default-src
  'none'; sandbox`, so a stored file is never rendered inline.

`upload.error_status` maps each error to 400, 413, 415 or 500.

## Timer Cap

The effect system caps periodic timers at 10 per runtime process (`effect.every`). Attempts to create additional timers are rejected with a warning log. This prevents runaway timer creation from buggy update handlers.

## Model Size Bounds

The runtime tracks serialized model size. Models exceeding 1MB trigger a warning log. Models exceeding 5MB are rejected to prevent memory exhaustion.

## WebSocket Authentication

Optional custom auth can be added via the transport config's `ws_auth` field. When set, the function runs before the WebSocket upgrade and can reject connections with HTTP 401.
