---
name: security
description: Audit code for security vulnerabilities — XSS, injection, auth bypass, CSRF, DoS, secret leaks, unsafe FFI, transport hardening.
user_invocable: true
---

# Security Audit

Run a security audit on the Brazier codebase (or a specific file/module).

## Usage

- `/security` — audit the full codebase
- `/security src/brazier/transport.gleam` — audit a specific file
- `/security auth` — audit authentication/authorization code
- `/security client` — audit client-side JavaScript

## What to Check

Scan all `.gleam`, `.erl`, `.mjs` files in `src/`, `test/`, and `brazier_client/src/`. For each category below, search for the listed patterns and report every instance found.

### 1. Cross-Site Scripting (XSS)

**Where to look:** `element.gleam`, `ssr.gleam`, `view.gleam`, `html.gleam`, `brazier_client_ffi.mjs`

- Text content rendered without HTML escaping — check `element.to_string()` and `to_html()` for raw string interpolation
- `innerHTML` assignments in `.mjs` files without sanitization — especially `morphInnerHTML`, `morphChildren`
- User-controlled strings injected into HTML attributes (check `href`, `src`, `style`, `on*` attributes)
- Generated HTML in codegen (route_dispatcher, brazier_codec) — are user values escaped?
- Template rendering (`view.gleam` rendered struct) — are dynamic values in statics/dynamics escaped?
- Check: does `html.text()` escape `<`, `>`, `&`, `"`? Does `html.attribute()` escape attribute values?

### 2. Injection Attacks

**Where to look:** `build.gleam`, `brazier_build_ffi.erl`, all `_ffi.erl` files

- **Command injection:** `run_command()` calls in build.gleam — are user/file paths shell-escaped? Could a malicious filename like `; rm -rf /` be injected?
- **Path traversal:** File read/write operations — can `../` in route names or module paths escape the project directory?
- **Erlang code injection:** `code:ensure_loaded`, `apply/3` calls — can module names be controlled by user input?
- **JSON injection:** Does `gleam_json` handle all edge cases? Check raw JSON string concatenation (not via `json.object`/`json.string`)

### 3. Authentication & Session Security

**Where to look:** `ssr.gleam`, `runtime.gleam`, `transport.gleam`, `route.gleam`

- **Session tokens:** Are they cryptographically signed? What algorithm? Is the secret key strong enough?
- **Token expiration:** Is `max_age_seconds` enforced? What's the default? Is it configurable?
- **Token replay:** Can a captured token be reused? Is there a nonce or jti?
- **Secret key generation:** Check `generate_secret()` — is it cryptographically random or just `unique_integer`?
- **Route guards:** Do guards run BEFORE init? Can they be bypassed by direct WebSocket messages?
- **State recovery:** When deserializing model from tokens, is the data validated? Can a tampered token inject arbitrary model state?

### 4. WebSocket Security

**Where to look:** `transport.gleam`, `brazier_client_ffi.mjs`

- **Origin checking:** Does the WS upgrade check the Origin header? Can cross-origin pages connect?
- **Rate limiting:** Is there per-connection message rate limiting? Can a client flood the server with events?
- **Message size limits:** Are incoming WS frames bounded? Can a client send a 100MB JSON payload?
- **Connection limits:** Is there a max connections per IP? Can one client open unlimited connections?
- **Auth on upgrade:** Is `ws_auth` used? What happens if it's `None` — is the WS open to anyone?
- **Heartbeat abuse:** Can a client skip heartbeats to keep stale connections alive? Or spam heartbeats?
- **Event spoofing:** Can a client send events with forged `handler_id` values to trigger handlers they shouldn't access?

### 5. Denial of Service (DoS)

**Where to look:** `runtime.gleam`, `transport.gleam`, `pubsub.gleam`, `build.gleam`

- **CPU exhaustion:** Can a client trigger expensive view re-renders by spamming events? Is there debouncing?
- **Memory exhaustion:** Is model state bounded? Can a client grow the model infinitely (e.g., infinite list append)?
- **PubSub amplification:** Can a client subscribe to topics that broadcast to many receivers?
- **Process exhaustion:** Each connection spawns a runtime process — is there a max process limit?
- **Build-time DoS:** Can malicious route files cause the scanner/codegen to loop or consume excessive memory?
- **Reconnection storms:** On server restart, do all clients reconnect simultaneously? Is there jitter/backoff?
- **Effect abuse:** Can `effect.every()` or `effect.from()` be used to spawn unbounded work?

### 6. Cross-Site Request Forgery (CSRF)

**Where to look:** `transport.gleam`, `middleware.gleam`, `ssr.gleam`

- **State-changing HTTP requests:** Are POST/PUT/DELETE protected with CSRF tokens?
- **Server functions:** Can `ClientServerFn` messages be triggered from cross-origin scripts?
- **Cookie security:** If cookies are used, do they have `SameSite`, `Secure`, `HttpOnly` flags?

### 7. Secret & Credential Leaks

**Where to look:** All files, especially `.erl`, `.mjs`, `gleam.toml`, test files

- **Hardcoded secrets:** Search for `"secret"`, `"password"`, `"api_key"`, `"token"` in string literals
- **Secret in logs:** Is `secret_key` ever logged? Check all `log.info`/`log.debug` calls
- **Secret in HTML:** Is the secret key embedded in the SSR HTML? (It shouldn't be — only signed tokens)
- **Test secrets:** Do test files use real credentials or properly mocked values?
- **Git-tracked secrets:** Check `.gitignore` — are `.env`, `credentials`, `*.pem` excluded?
- **Error messages:** Do error responses leak internal paths, stack traces, or configuration?

### 8. Client-Side Security

**Where to look:** `brazier_client_ffi.mjs`, `patch.mjs`, generated JS bundles

- **eval/Function usage:** Any `eval()`, `new Function()`, or `setTimeout(string)` calls?
- **Prototype pollution:** Does `applyOps` or `diffModels` guard against `__proto__`, `constructor`, `prototype` keys in model JSON?
- **DOM clobbering:** Can server-rendered HTML include elements with `id` or `name` that shadow global JS APIs?
- **postMessage:** If used, is the origin validated?
- **Content Security Policy:** Is a CSP header set? Does `secure_headers` middleware include it?
- **Unsafe assignments:** Check for `.innerHTML =` outside the morphing engine

### 9. Dependency Security

**Where to look:** `gleam.toml`, `manifest.toml`

- **Outdated deps:** Are dependencies pinned to secure versions?
- **Transitive deps:** Are there unexpected transitive dependencies?
- **Supply chain:** Are all deps from hex.pm? Any git dependencies?

### 10. FFI Security

**Where to look:** All `.erl` and `.mjs` files

- **Erlang FFI:** Check for `os:cmd`, `erlang:apply` with user input, `file:read_file` with unvalidated paths
- **JavaScript FFI:** Check for DOM manipulation with unsanitized data, `fetch` to arbitrary URLs
- **Type boundary crossing:** Are Gleam types properly validated when crossing FFI boundaries? Can Erlang/JS return unexpected shapes?

## Output Format

For each finding, report severity and details:
```
[CRITICAL] src/brazier/transport.gleam:42 — No Origin check on WebSocket upgrade
  Risk: Cross-origin WebSocket hijacking — any page can connect and control user sessions
  Fix: Add Origin validation in ws_auth or create a default origin-checking middleware

[HIGH] src/brazier/build.gleam:335 — Shell command with unescaped file path
  Risk: Command injection via malicious filenames (e.g., "; rm -rf /")
  Fix: Use erlang:open_port with argument list instead of os:cmd with string interpolation

[MEDIUM] src/brazier/ssr.gleam:510 — Secret key generated from unique_integer (not cryptographic)
  Risk: Predictable session tokens if the BEAM's integer sequence is known
  Fix: Use crypto:strong_rand_bytes/1 for secret key generation

[LOW] brazier_client/src/brazier_client_ffi.mjs:420 — No CSP meta tag in generated HTML
  Risk: XSS via injected scripts has no browser-level defense
  Fix: Add Content-Security-Policy header in secure_headers middleware

[INFO] gleam.toml — Consider adding rate_limiter dependency for per-IP connection limits
```

At the end, summarize:
```
Security Audit Results:
  Files scanned: N
  Findings: N total
    Critical: N (must fix before deploy)
    High: N (fix before production traffic)
    Medium: N (fix soon)
    Low: N (hardening)
    Info: N (best practices)
  Top priority: [one-line description of most critical finding]
```
