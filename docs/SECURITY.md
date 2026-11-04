# Security

Brazier includes built-in security protections across the transport, middleware, and SSR layers.

## SecurityLimits

The `SecurityLimits` type in `brazier/transport` controls connection-level
protections. `transport.validate_security_limits` checks it when the listener
starts; an invalid value (a non-positive size or interval, a timer too large
for `erlang:send_after/3`, a malformed trusted proxy, allowed origin or
allowed host, an empty `allowed_hosts` in production) refuses to start. The
origin and host lists are parsed once, when the listener starts, as Phoenix
compiles its `check_origin` list once.

<!-- docs-check: fragment an excerpt of the SecurityLimits type in brazier/transport, defaults as comments -->
```gleam
pub type SecurityLimits {
  SecurityLimits(
    max_message_bytes: Int,           // 65536: one WS frame or reassembled message
    max_events_per_second: Int,       // 50 per WS connection
    max_connections: Int,             // 10000 HTTP + WS connections, global
    max_http_headers: Int,            // 100
    max_http_header_bytes: Int,       // 65536
    pre_upgrade_timeout_ms: Int,      // 5000: deadline for request line + headers
    // HTTP limits
    max_connections_per_ip: Int,      // 256 (trusted proxies exempt)
    max_request_line_bytes: Int,      // 8192, longer gets 414
    max_body_bytes: Int,              // 8388608, larger Content-Length gets 413
    body_read_timeout_ms: Int,        // 30000 per body chunk
    request_timeout_ms: Int,          // 60000 total for the body
    keepalive_idle_timeout_ms: Int,   // 15000 between keep-alive requests
    max_keepalive_requests: Int,      // 1000 per connection
    send_timeout_ms: Int,             // 30000 per blocked socket send
    drain_timeout_ms: Int,            // 5000 for open connections on stop
    trusted_proxies: List(String),    // [] (see Trusted Proxies)
    forwarding_header: ip.ForwardingHeader, // ip.NoForwardingHeader
    // WebSocket limits
    max_ws_connections_per_ip: Int,   // 100
    ws_ping_interval_ms: Int,         // 30000
    ws_pong_timeout_ms: Int,          // 20000
    ws_idle_timeout_ms: Int,          // 90000
    ws_send_timeout_ms: Int,          // 15000
    ws_max_outbound_queue: Int,       // 1000
    ws_auth_recheck_interval_ms: Int, // 60000
    ws_max_decode_errors: Int,        // 10
    ws_max_rate_violations: Int,      // 100
    ws_allowed_origins: List(String), // []
    allowed_hosts: List(String),      // []: localhost names in development; required in production
  )
}
```

## HTTP Server Hardening

The HTTP/1.1 server (`brazier/transport/server`, `brazier/transport/http`)
follows the cowboy/ranch and Plug conventions:

- **Request line:** origin-form and absolute-form (the path is taken from an
  absolute URI) are accepted; `*` only for `OPTIONS`; authority-form and
  anything malformed get 400, an unknown method 501, a version other than
  HTTP/1.0 or 1.1 505, and a request line over `max_request_line_bytes` 414.
- **Headers:** more than `max_http_headers` or `max_http_header_bytes` gets
  431; an invalid header line 400; HTTP/1.1 without exactly one `Host` 400.
- **Smuggling:** `Content-Length` together with `Transfer-Encoding`, a
  duplicate or non-numeric `Content-Length` get 400; chunked bodies get 501.
- **Slow clients:** the request head must arrive within
  `pre_upgrade_timeout_ms` (otherwise 408), each body chunk within
  `body_read_timeout_ms` and the whole body within `request_timeout_ms`; an
  idle keep-alive connection is closed after `keepalive_idle_timeout_ms`.
- **Keep-alive:** `Connection: close` from either side and HTTP/1.0 without
  `keep-alive` close the connection after the response, which then carries
  `Connection: close`. `HEAD` responses keep `Content-Length` with no body.
  The response is written before any unread body is touched, so a refusal
  such as 413 reaches the client at once. Afterwards an unread body of at
  most 64 KiB is discarded so the connection can be reused; a larger one, or
  any unread body of an `Expect: 100-continue` request, closes it.
- **Closing:** a connection the server ends after a response is half-closed
  and drained for at most 1 s or 1 MiB before the socket closes, so unread
  request bytes do not make the kernel reset the connection and destroy the
  response (cowboy's `linger_timeout`).
- **Connections:** the listener's connection owner (`brazier_http_conns`)
  holds the connection slots, per peer IP and in all, and the WebSocket
  slots per client IP; a slot is released when its process exits for any
  reason. Connections over `max_connections` or `max_connections_per_ip` get
  503 and are closed.
- **Supervision:** acceptors run under an OTP supervisor and are restarted
  (and logged) when they crash; a crashing handler gets 500 and closes only
  its own connection. The listen socket has its own owner process, which
  closes it when the listener stops, so the port is free again at once.
- **Shutdown:** a stopping listener first stops its acceptors and closes the
  listen socket, then gives open connections `drain_timeout_ms` (0 kills
  them at once; at most 4294967295) to finish, and kills the rest.
  `BRAZIER_SHUTDOWN_TIMEOUT` overrides it. See
  [DEPLOYMENT.md](DEPLOYMENT.md#graceful-shutdown).

A seeded raw-socket fuzz test (`test/brazier/http_fuzz_test.gleam`) sends
mutated and random requests and checks that the server never crashes, hangs,
leaks a connection slot or loses an acceptor.

Override defaults via the builder:

<!-- docs-check: wrap
{{block}}

pub type Model {
  Model
}

pub type Msg {
  Noop
}

fn init(_ctx: brazier.Context) -> Result(Model, brazier.InitError) {
  Ok(Model)
}

pub fn update(model: Model, _msg: Msg) -> Model {
  model
}

pub fn view(_model: Model) -> element.Element(Msg) {
  element.text("")
}
-->
```gleam
import brazier
import brazier/element
import brazier/transport

pub fn main() {
  brazier.simple(init:, update:, view:)
  |> brazier.security_limits(transport.SecurityLimits(
    ..transport.default_security_limits(),
    max_connections: 5000,
    max_events_per_second: 100,
  ))
  |> brazier.start(8080)
}
```

## WebSocket Limits

An upgrade request is admitted in this order. The first check that fails
answers with an HTTP status and no socket is opened, except the last, the
middleware, whose refusal completes the handshake and closes with 4600:

| Check | Refusal |
|-------|---------|
| `Host` in `allowed_hosts` (see [Allowed Hosts](#allowed-hosts)) | 400 |
| No request body, and no bytes sent before the handshake answer | 400 |
| A `path` query parameter naming a local page path | 400 |
| Global `max_connections` | 503 |
| `max_ws_connections_per_ip`, keyed on the client address resolved through `trusted_proxies` | 429 |
| Origin (below) | 403 |
| `ws_auth`, when configured | 401 |
| RFC 6455 handshake (method, `Upgrade`, `Connection`, `Sec-WebSocket-Key`) | 400; an unsupported `Sec-WebSocket-Version` gets 426 |
| The app's middleware, run on a `GET` of that page (see [The Live Page and Middleware](#the-live-page-and-middleware)) | 101, then close 4600 `middleware refused <status>` |

On an open socket, `max_message_bytes`, `max_events_per_second`,
`ws_max_rate_violations`, `ws_max_decode_errors`, the ping, pong and idle
timeouts, `ws_send_timeout_ms`, `ws_max_outbound_queue` and the
`ws_auth_recheck_interval_ms` re-check each close the socket with a specific
code. [WIRE_PROTOCOL.md](WIRE_PROTOCOL.md) describes each rule
([Frames](WIRE_PROTOCOL.md#frames-rfc-6455),
[Liveness](WIRE_PROTOCOL.md#liveness),
[Backpressure](WIRE_PROTOCOL.md#backpressure),
[Rate Limiting and Abuse](WIRE_PROTOCOL.md#rate-limiting-and-abuse),
[Sessions and Authentication](WIRE_PROTOCOL.md#sessions-and-authentication))
and lists the codes in [Close Codes](WIRE_PROTOCOL.md#close-codes).

## Origin Validation

Origin validation is the defence against cross-site WebSocket hijacking. On
every upgrade the `Origin` header must equal the request's own origin, or an
entry of `ws_allowed_origins`; scheme, host and port must all match, with the
default port applied (80 for `http`, 443 for `https`):

- the request's host and port come from its `Host` header;
- its scheme is `http`, or the scheme a trusted proxy sent in the configured
  forwarding header (see Trusted Proxies);
- a missing `Origin`, one that does not parse (empty, no scheme,
  protocol-relative, a path), an unusable `Host` and any mismatch get 403.

Non-browser clients must send an explicit `Origin`. `ws_allowed_origins`
entries are bare `scheme://host[:port]` origins, parsed once when the
listener starts: an entry with a path, or one that does not parse, refuses
to start.

The origin check alone does not stop DNS rebinding: a page on
`evil.example` whose name is rebound to this server's address is
same-origin with itself, so its upgrade carries `Origin:
http://evil.example` and `Host: evil.example`, which match. The host check
below refuses it.

## Allowed Hosts

`SecurityLimits.allowed_hosts` lists the host names the server answers to,
as Django's `ALLOWED_HOSTS` does. Every HTTP request and every WebSocket
upgrade whose `Host` header names another host gets 400 (upgrade result
`rejected_host`), before any middleware or handler runs.

- `"example.com"`, `"127.0.0.1"`, `"[::1]"` match that host only.
- `".example.com"` matches `example.com` and every subdomain.
- `"*"` matches every host, which turns the check off; the listener logs a
  warning when it starts.
- The port is not compared, case is ignored, and one trailing dot of the
  request's host (`example.com.`) is dropped.
- An entry with a port, a scheme or path, a `*` inside a name or a
  trailing dot refuses to start.
- An empty list means `transport.development_allowed_hosts`
  (`[".localhost", "127.0.0.1", "[::1]"]`) in development. In production
  (`BRAZIER_ENV=production`) the listener refuses to start with an empty
  list, and the error names the setting. See
  [DEPLOYMENT.md](DEPLOYMENT.md#allowed-hosts).
- A request with no `Host` passes (only HTTP/1.0 can omit it; HTTP/1.1
  without exactly one `Host` is already refused). Browsers always send it,
  so a rebound page cannot use this.

## The Live Page and Middleware

The app's middleware decides who may see a page, and a live session must
not reach a page the middleware refuses over HTTP. Following Phoenix
LiveView, which runs a `live_session`'s `on_mount` hooks at the first mount
and again at every live navigation, the same pipeline gates the live page:

- **Upgrade.** The upgrade's `path` query parameter is required and must be
  a local path (the [Navigation Targets](#navigation-targets) rule);
  otherwise 400 (`rejected_path`). A `GET` of that page, with the upgrade's
  headers and cookies, is run through the middleware once every other
  upgrade check has passed. When the pipeline does not reach the handler,
  the handshake completes and the socket closes with 4600 `middleware
  refused <status>` (`rejected_middleware`); no runtime starts, and the
  client loads the page over HTTP, where the middleware answers it. Because
  the origin check runs first, a cross-origin page never reaches the
  middleware and learns nothing about the app's routes from the answer.
- **Navigation and join.** Every `navigate`, and every `join` for a page
  other than the one the connection was admitted for, runs the same gate.
  A refused page is answered with `hard_navigate` to it: the browser loads
  it over HTTP, where the middleware answers it (a redirect to sign in, a
  403). The refusal emits `[brazier, ws, navigation_refused]`. A path that
  is not local gets `error "Invalid page path"`.

The gate runs the middleware for its decision only: a response it builds
for the gated page is not sent over the socket.

## Rate Limiting

**Per-connection (server-side, transport layer):** Each WebSocket connection counts events per 1-second window. An event over `max_events_per_second` (default 50) is dropped and answered with `{"type":"error","reason":"Rate limited"}`; heartbeats have their own limit of 2 per second. Repeated violations close the socket with 1008. The limit is not advertised to the client; the generated client paces itself at 40 per second, and a `max_events_per_second` below 50 is logged as a warning when the listener starts. See [WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#rate-limiting-and-abuse).

**HTTP middleware:** The `middleware.rate_limit(limiter)` middleware returns HTTP 429 (with `Retry-After` set to the window length) when a client exceeds the configured request rate. It keys on the socket peer address and ignores `X-Forwarded-For` / `Forwarded`, so a client cannot get a fresh budget by inventing addresses. Behind a reverse proxy use `middleware.rate_limit_behind_proxies(limiter, trusted)` (see Trusted Proxies). A request whose peer address cannot be read gets 400.

The limiter (`brazier/rate_limit`) is a fixed-window counter in an ETS table owned by a dedicated process, linked to and monitoring its creator. Memory is bounded: expired windows are swept every window, and the table holds at most `max_keys` clients (default `rate_limit.default_max_keys`, 100,000; set it with `rate_limit.new_with_max_keys`). At the cap, new clients are refused (fail closed) while known clients keep their budget, and every sweep logs an error with the number of refusals. If the limiter process is gone, every check is refused and logged.

## Trusted Proxies

`SecurityLimits.trusted_proxies` lists the reverse proxies (addresses or CIDRs such as `"10.0.0.0/8"`, `"fd00::/8"`) that Brazier believes. `SecurityLimits.forwarding_header` names the one header those proxies set to name the client: `ip.Forwarded`, `ip.XForwardedFor` or `ip.NoForwardingHeader` (the default). Both are parsed once, when the listener starts, and every request uses that parse: an invalid entry, or a forwarding header with no trusted proxies (it would never be read), refuses to start. `brazier/transport/client` is the single resolver used by the HTTP rate limiter, the per-IP WebSocket cap and the WebSocket Origin check:

- **Client IP:** the socket peer, unless the peer is a trusted proxy and a forwarding header is configured. Then it is the right-most hop of that header that is not itself a trusted proxy (RFC 7239 section 7.4; the Plug `RemoteIp` / Rails `remote_ip` rule). A client can prepend hops but cannot forge the ones its proxies append. A malformed hop stops the walk at the last trusted address and is logged.
- **One header, chosen by the operator:** Brazier never picks between `Forwarded` and `X-Forwarded-For`. A proxy usually sets only one of them and passes the other through from the client untouched, so preferring either would let a client name its own address whenever the proxy does not set the preferred one. This follows `Plug.RewriteOn`, which rewrites only from the headers the app lists, and Rails `RemoteIp`, which treats disagreeing client headers as a spoof (`IpSpoofAttackError`). The other header is never read; when a trusted proxy passes one through, the request is served and a warning names the ignored value (the configured proxy never sets it, so it came from the client or from a proxy that is set up differently from `forwarding_header`). With `ip.NoForwardingHeader`, both are ignored and logged at debug.
- **Scheme:** `http` (Brazier does not terminate TLS), unless a trusted proxy sends one in the configured header: with `ip.Forwarded`, the `proto=` of the element that names the client (the element the address walk stops at, which the outermost trusted proxy appended); with `ip.XForwardedFor`, the left-most value of `X-Forwarded-Proto`, as Django's `SECURE_PROXY_SSL_HEADER` reads it. The other header is never read (a warning names an `X-Forwarded-Proto` that reaches a `Forwarded` deployment), and with `ip.NoForwardingHeader` the scheme is always `http`, as `Plug.RewriteOn` rewrites the scheme only from the headers it is given. The scheme must be `http` or `https`; anything else, several `X-Forwarded-Proto` headers, or several `proto=` in one element rejects the request. From an untrusted peer nothing is read, so a direct client cannot claim `https` to pass an `https://` Origin check.

With the default empty list, no forwarding header is ever honoured. Use the same settings for `middleware.rate_limit_behind_proxies` via `ip.parse_trusted_proxies(entries, header)` (or `transport.trusted_proxies(limits)`).

## Message Size Limits

A WebSocket frame, or a message reassembled from fragments, over `max_message_bytes` (default 64KB) closes the connection with 1009 before it is decoded. The length is checked from the frame header, so a peer cannot slowly accumulate an oversized partial frame.

## Connection Limits

A supervised tracker counts every HTTP and WebSocket connection. When `max_connections` (default 10,000) is reached, a new connection gets HTTP 503 before its request is read.

## HTTP Pre-Upgrade Limits

Before WebSocket upgrade, Brazier limits total header count, total request/header bytes, and total request/header read time using one monotonic deadline. Slow or oversized pre-upgrade requests fail before any runtime process is started.

## Response Header Validation

HTTP responses are validated immediately before serialization. Header names must be RFC token names, and header values must not contain CR, LF, or NUL bytes. Unsafe response headers fail loudly instead of being written to the socket, preventing HTTP response splitting from API routes or middleware.

## HTML Attribute Validation

Brazier escapes text (`&`, `<`, `>`) and attribute values (also `"`) during SSR and in the browser. The escapers work on bytes on Erlang and UTF-16 code units in JavaScript, never on graphemes, so every `"` is escaped even when a combining mark follows it and the two form one grapheme.

`attribute.attribute(name, value)` crashes on these names, and rendering crashes again on an attribute that reaches it without the constructor:

- an inline event attribute such as `onclick`: use `brazier/event`;
- `srcdoc`, whose value is a whole HTML document: use `attribute.unsafe_srcdoc` (see [Escape Hatches](#escape-hatches));
- `attributeName` with a value containing `href`: an SVG `<animate>` or `<set>` targeting `href` or `xlink:href` would change a link after the URL policy checked it. DOMPurify refuses the same values. See [SVG.md](SVG.md#animation);
- a name with characters outside `a-z A-Z 0-9 - _ : .`.

Names match case-insensitively. Attribute names come from application code, so such a name is a bug in the view. Event handler IDs are rendered as escaped attribute values.

### URL Policy

Attributes the browser treats as a URL (`href`, `src`, `action`, `formaction`, `poster`, `cite`, `xlink:href`) are checked when the attribute is built and again when it is rendered, on the server and in the browser bundle, which runs the same code. Allowed values:

- relative URLs (no scheme before the first `/`, `?` or `#`);
- `http:`, `https:`, `mailto:` and `tel:`;
- in `src` only, `data:image/png`, `data:image/gif`, `data:image/jpeg` and `data:image/webp`. `data:image/svg+xml` is never allowed, because an SVG document can run script.

Any other value (`javascript:`, `vbscript:`, `data:text/html`, ...) drops the attribute and logs a warning naming it, as React does for `javascript:` URLs. The scheme is read the way a browser's URL parser reads it (the WHATWG URL Standard's scheme state), one code point at a time:

- tabs and newlines are removed anywhere, and leading and trailing C0 control characters and spaces are stripped, so `" JaVa\tScRiPt:"` is refused;
- a scheme is an ASCII letter followed by ASCII letters, digits, `+`, `-` or `.`, up to the first `:`. Anything else before the `:` makes the value relative, as it is to the browser;
- case is ignored for ASCII letters only.

Reading by code point matters: a combining mark right after the `:` (`javascript:` followed by U+0E33) joins the colon into one grapheme, and a grapheme-based reader found no `:` and treated the value as relative, while the browser ran it.

### Escape Hatches

`element.unsafe_raw_html` and `brazier.head_html` insert trusted HTML without escaping or the URL policy. `attribute.unsafe_srcdoc` gives an `<iframe>` a whole document that is not checked; its value is attribute-escaped and the browser decodes it back to HTML, which runs with the page's origin unless the iframe's `sandbox` withholds `allow-scripts` or `allow-same-origin`. Do not pass user input to any of them.

## Build And Dev Command Execution

Build and dev tooling launches `gleam`, `npx`, `fswatch`, and `inotifywait` with argv-based Erlang ports instead of shell strings. Project paths and path dependencies are not interpolated into shell commands.

## Secure Headers

The `middleware.secure_headers()` middleware (included by default in all apps) sets:

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: SAMEORIGIN`
- `X-XSS-Protection: 0` (the legacy XSS auditor is itself exploitable; OWASP recommends disabling it and relying on CSP)
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: camera=(), microphone=(), geolocation=()`
- `Content-Security-Policy:` `middleware.default_csp`, which is `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; object-src 'none'; base-uri 'self'`.
  - `script-src 'self'` runs only scripts the app serves. Brazier loads its client bundle with `<script src>` and renders no inline script or `on*` attribute, so an injected script or handler does not run. A `head_html` with an inline `<script>` needs its own policy.
  - `connect-src 'self'` lets the WebSocket and `fetch` reach only the page's origin. CSP Level 3 matches same-origin `ws:` and `wss:` against `'self'`. Safari 15 and earlier did not (WebKit bugs 201591 and 235873), so an app that supports them passes a policy naming its own `wss://host` to `middleware.secure_headers_with_csp`.
  - `img-src 'self' data:` allows no third-party image host.
  - `style-src` keeps `'unsafe-inline'`, which `attribute.style` needs.
  - `frame-ancestors 'self'` is the CSP form of `X-Frame-Options: SAMEORIGIN`.

HSTS is opt-in because Brazier does not terminate TLS: add `middleware.hsts(31_536_000, True)` (it returns a `Result`; a negative max-age is an error) when the app is served over HTTPS behind a TLS proxy.

## Route Scoping

`middleware.only`, `middleware.at` and `middleware.except` compare paths segment by segment, the way the routers read them, not as raw string prefixes. `only("/admin", mw)` covers `/admin` and `/admin/users` but not `/administrator`. A path is read four ways: with empty segments dropped, with dot segments resolved (API routing), and both again after percent-decoding (page routing decodes segments, so `/%61dmin` is the `admin` route). `only` and `at` apply when any reading matches, and `except` skips the middleware only when every reading is under the prefix. So `//admin` and `/%61dmin` still get `only("/admin", auth)`, and `/public/../admin` and `/public/%2E%2E/admin` still get `except("/public", auth)`. A path that does not percent-decode has no decoded reading; the page router answers it with 400 before an app sees it.

## Join Tokens

SSR pages set a signed join token in the HttpOnly `brazier_join_token` cookie; static error pages (4xx/5xx, which load no client) set none. The browser client sends an empty join token; the runtime reads the cookie from the WebSocket upgrade request. Tokens follow Phoenix.Token: `ssr.sign_join_token` signs a JSON payload with `crypto.sign_message` (HMAC-SHA256) holding a purpose, the issue time, the expiry, a fingerprint of the browser session and, with state recovery, the client-visible model. `ssr.verify_join_token` checks the signature, the purpose, the session fingerprint and the expiry. A token lives 24 hours (`ssr.join_token_lifetime_seconds`); the expiry is signed into it, so a verifier cannot extend it. Signing with an empty secret key is a broken invariant (the app refuses to start without a key) and crashes.

The token must fit in a cookie: a browser drops a cookie over 4096 bytes. A page whose token is over `ssr.join_token_cookie_budget_bytes` (3800 bytes) is refused with a plain-text 500 and no cookie, the error is logged with the token size, and `[brazier, ssr, join_token, too_large]` is emitted. The model is never dropped to make the token fit: the session would then restart from `init` on its next reconnect with nothing to say why. Keep the client-visible model small, or do not use state recovery.

While state recovery is enabled, the runtime refuses a join (4400, the browser reloads for a fresh token) whose token is missing, does not verify, carries no model, or carries a model the codec cannot decode or `restore` refuses. The signature, age and session are checked before `init` runs; the model is restored after it. See [ERROR_HANDLING.md](ERROR_HANDLING.md#join-tokens).

**What state recovery restores.** A recovered model is the client-visible model as it was when the page was rendered, up to 24 hours earlier. As LiveView re-runs `mount` on every reconnect and reloads the user from the session there, Brazier runs `init` and the initial route for the reconnecting connection first, with the current request and session, and then calls `restore(model, fresh)` with the recovered model and the state they built. Take authorization (a role, a permission, the signed-in user) from `fresh`, never from the recovered model: the model brings back what the page had, even if it was revoked since. A `restore` that copies only the client-visible fields onto `fresh` (`Session(..fresh, model: model)`) keeps every server-only field current.

The cookie is `HttpOnly`, `SameSite=Lax`, path `/`, and has `Max-Age=86400`. JavaScript cannot read it, so XSS cannot directly steal the join token from DOM state.

The secret key must be at least 32 bytes (`config.min_secret_key_bytes`, the
HMAC-SHA256 output size; RFC 2104 section 3). `application.start`,
`start_advanced` and `start_supervised` refuse an empty key, a shorter key and
the formerly built-in dev secret with a `ConfigError` before any process is
started or port bound. The key is never logged. `config.secret_key()` reads
`SECRET_KEY` and applies the same check; there is no default.

The key is required. `brazier.start` refuses an app without
`brazier.secret_key` with a `ConfigError` that names the setting and the
`SECRET_KEY` variable. It never generates a key, because a generated key
would end every token at a restart and differ between nodes. The app has one
key. The cluster peer check derives its MAC from it with a purpose label
(`HMAC-SHA256(secret_key, "brazier-cluster-v1")`), so no token signature
equals the MAC. Generate a key with `openssl rand -base64 48`. The full
`main` is in [DEPLOYMENT.md](DEPLOYMENT.md#secret-key):

<!-- docs-check: wrap
import brazier
import brazier/config
import brazier/error.{type BrazierError}
import gleam/result

pub fn with_secret(
  app: brazier.App(state, model, local, msg),
) -> Result(brazier.App(state, model, local, msg), BrazierError) {
  {{block}}
}
-->
```gleam
use secret <- result.try(config.secret_key())
Ok(brazier.secret_key(app, secret))
```

## CSRF Tokens

`brazier/form` CSRF tokens are 256 random bits from
`crypto.strong_random_bytes`, hex encoded; they are not derived from the
secret key, the time or a counter. `form.verify_session_csrf` compares the
submitted token with `crypto:hash_equals` (constant time) and consumes it with
an atomic compare-and-delete, so a token is accepted exactly once even when
several requests race, and a wrong guess does not burn the real token.
Issuing a new token for a session replaces the old one.

## Application Session Auth

For application auth, prefer `brazier/auth` helpers over hand-written cookie and
CSRF handling. `auth.default_session_config()` sets an opaque `brazier_session`
cookie with `HttpOnly`, `Secure`, `SameSite=Lax`, and path `/`.

`auth.login_json_response()` and `auth.login_route()` create a server-side
session and a cryptographically random session-bound CSRF token. Return that
CSRF token in the login response body and require it on state-changing API
routes with `auth.protect_api_with_csrf()` or `auth.csrf_authenticated()`. Do
not store the CSRF token in a cookie. Use the `_rotating` variants when the
request may already carry a session id, so the old id is deleted and cannot
be replayed (session fixation); when it cannot be deleted, no new session is
created.

Use `auth.dev_session_config()` only for localhost HTTP development, where the
`Secure` cookie attribute would prevent the browser from storing the cookie.

### Store and cookie failures

- `auth.login`, `login_rotating`, `create_login` and `create_login_rotating`
  return `Result(_, auth.SessionError)`. A store that cannot answer is
  `SessionStoreUnavailable(reason)`, logged as an error by `brazier/auth`.
- The response helpers (`login_response`, `login_json_response`,
  `logout_response`) return `Result(_, auth.ResponseError)`: `StoreFailed` or
  `CookieRejected`. The cookie config is checked before a session is created,
  so an invalid `SessionConfig` never leaves an orphan session.
- `logout_response` builds no response when the store fails: clearing the
  cookie would tell the user they signed out while the session may still
  exist. Answer 503 and keep the cookie.
- `auth.login_route()` and `auth.logout_route()` answer 503 (with
  `Retry-After`) on `StoreFailed` and 500 on `CookieRejected`.
- `auth.init_from_session` treats a missing, unknown or expired session as a
  guest, and refuses the request with `error.unavailable` when the store
  cannot answer: the HTML render answers 503 and the WebSocket closes with
  4503. It never renders a guest page for a session it could not check. See
  [GETTING_STARTED.md](GETTING_STARTED.md#signed-in-first-render).

### WebSocket sessions

`auth.protect_ws(store, config)` accepts an upgrade only for a live session
with a user, and binds the socket's process to that session. Logout, session
rotation or expiry closes the socket at once with close code 4401, and the
check is repeated every `ws_auth_recheck_interval_ms`. On 4401 the browser
logs an error, never reconnects with the revoked session, and reloads the
page. The reload guard allows at most 3 such reloads per tab within 60 s;
past that the page shows an error and stops.

`protect_ws` refuses guests. An app that serves a guest page uses
`auth.allow_guests_ws(store, config)` instead (see `examples/auth_workspace`).
It binds a signed-in socket exactly as `protect_ws` does, connects a request
with no cookie, a dead session or a session without a user as an unbound
guest, and refuses the socket when the store cannot answer, so an outage is
never hidden behind a guest page. A socket that was bound never becomes a
guest: when its recheck finds the session deleted, expired or without a
user, the check fails, a warning is logged and the socket closes with 4401,
so the page reloads and opens a new, unbound guest socket. This catches a
revocation that sent no notice, such as a user removed with
`session.update`, as Phoenix LiveView disconnects every socket of a
`live_socket_id` on logout. The server then still decides
per event: a guest socket can send only messages its page's `view` produces,
and `update` must refuse signed-in actions from a guest.

## Cookies

`brazier/cookie` validates every cookie it sets against RFC 6265 and returns a
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

`brazier/upload` trusts nothing the client sends in a multipart request:

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

## Effect Caps

The effect system caps what one runtime process can have running: 10 periodic timers (`effect.every`), 100 pending `effect.after` timers and 32 live `effect.background` workers. One more is rejected with a warning log and a `rejected` telemetry event. This prevents runaway timer or process creation from buggy update handlers. See [EFFECTS.md](EFFECTS.md#limits).

## Model Size Bounds

The runtime tracks serialized model size. Models exceeding 1MB trigger a warning log. Models exceeding 5MB are rejected to prevent memory exhaustion.

## WebSocket Authentication

`brazier.ws_auth(fn(api.Request) -> Result(Nil, String))` runs before the WebSocket upgrade and again every `ws_auth_recheck_interval_ms`. `Error(reason)` rejects the upgrade with HTTP 401, or closes a live socket with 4401. For Brazier sessions use `auth.protect_ws`, or `auth.allow_guests_ws` when guests may open the page (see Application Session Auth).

## Events From the Browser

The server decodes every event with the generated `brazier_codec.decode_event`. The accepted messages are exactly the `Msg` constructors that client code (what `view`, a Local layer and a `simple` app's `update` reach) can build, as found by the build. Any other message is refused before `update` runs: the server logs a warning, answers with an error, and the browser drops its optimistic state. Messages that only effects, subscriptions or the router produce cannot be sent from the browser.

An accepted message is still only a request: `update` runs on the server and must check that the session may perform it (for example, that a guest is not sending a signed-in action). With `brazier.simple` the browser runs `update` first for instant feedback, but the server runs it too and its model wins; a mismatch is logged in the browser.

## Navigation Targets

`router.push`, `router.replace` and `router.redirect` send the browser to a
path, so a path built from user input (a `?next=` parameter) must not become
an open redirect. A browser's URL parser reads `\` as `/` and strips tab,
newline and carriage return anywhere in a URL. That means `/\evil.example`
and `/<tab>/evil.example` load evil.example just as `//evil.example` does.
The router accepts a path only when all of these hold:

- it starts with `/`, but not with `//` or `/\`;
- it has no `\`;
- it has no ASCII control character (U+0000 to U+001F, U+007F);
- it has no `/%09`, an encoded tab that some browsers strip.

This is Phoenix's `validate_local_url` rule plus the control characters. A
refused path is logged as an error with the reason and never sent.

The client applies the same rule, with the same reasons, to the `navigate`
and `hard_navigate` frames. It then refuses a path that
`new URL(path, location.origin)` resolves to another origin. `router_test`
holds the server's and the client's verdicts equal on every case.

## Client Text in Logs

The transport, the runtime, the router and `middleware.logger` quote what
the client chose with `string.inspect` when they log it, so a newline or
control character in it cannot forge a second log line: event names and
message types, `Origin` and `Host` header values, and the scheme and port
parsed from them. A path they log (the transport's static and error
responses, a `join` or `navigate` path, a `router.push` target, a refused
hard navigation) loses its query and fragment before it is quoted, since
those can carry tokens or personal data, as LiveView's `filter_parameters`
keeps such values out of its logs: `router.push("/reset?token=...")` is
logged as `"/reset"`. `test/brazier/log_forging_test.gleam` holds these
rules.

## Model Patches

A patch path never goes through `__proto__`, `constructor` or `prototype`.
The client refuses any patch with such a segment, so applying it cannot reach
`Object.prototype`. The diff never writes one: when such a key is added,
removed or changed, the server and the client replace the object holding it
whole. The server's `patch.unsafe_keys()` is the canonical list, and
`patch_test` holds the client's `UNSAFE_PATCH_KEYS` equal to it.

## Client Bundle Privacy

The build compiles to JavaScript only the code the browser runs: what `view` reaches, plus `init_local` and `update_local` of a `local.layer`, plus `update` for `brazier.simple`. Each reached definition is sliced out of its source file and its imports regenerated, so a function, constant, type or import that the browser does not reach never appears in the bundle. A reference from browser code into a server-only Brazier module (for example `brazier/store`, `brazier/effect` or `brazier/session`) fails the build with the call site.

At runtime, a `full_application` sends the browser only what `sync(state)` returns. Keep secrets, session ids and private records in the server state outside the synced model; `examples/privacy_demo` and `examples/route_server_workspace` show the pattern.

## Clustering

Erlang distribution has no permission model: a node that holds the cookie can run any code on every node. [CLUSTERING.md](CLUSTERING.md#security-first-what-distribution-means) has the full setup. Brazier enforces this much:

- **Production distribution.** With `BRAZIER_ENV=prod`, the cluster manager refuses to start over plain TCP, with a cookie shorter than 32 bytes, or with TLS that does not verify peers. Verifying peers means server `verify_peer` with `fail_if_no_peer_cert`, and client `verify_peer`. `allow_insecure_distribution(reason)` overrides the refusal and logs the reason.
- **Verified membership.** A connected node becomes a member only after it proves it holds the app's secret key (the peer check). PubSub, replicated stores, presence and session revocation send to members only and drop what other nodes send. There is no fallback to every connected node (see [Membership](CLUSTERING.md#membership)). This keeps a deployment that shares a cookie by mistake out of the data. It does not stop a node with the cookie, which can run code directly.
- **The MAC is a secret.** The peer-check MAC is derived from the secret key with a purpose label. It is never logged. The manager's `format_status` shows it, and any MAC in a message it holds, as `redacted`. A malformed hello is logged with only its tag, size and sender.
- **Atoms from DNS are bounded.** DNS discovery makes node names (atoms, never freed) only from well-formed IP addresses. It makes at most `max_discovered_nodes` of them over the VM's life.
