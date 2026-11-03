# Wire Protocol

Beacon communicates over WebSocket at `/ws` using JSON messages with a `type` discriminator.

The browser connects to `/ws?path=<page path>`, the URL-encoded path and
query string of the page (`encodeURIComponent(location.pathname +
location.search)`), on the first connection and on every reconnect. The server
resolves the route from it, so `init` sees the same URL as the server render,
and refuses the connection (logging a warning) when `path` is missing or not a
local path.

## Client Messages (browser to server)

**join** -- Sent after WebSocket opens. `path` drives routing. `token` remains in the JSON shape for direct runtime tests and non-browser clients, but browser join/session recovery uses the HttpOnly `beacon_join_token` cookie from the WebSocket upgrade request.
```json
{"type": "join", "token": "", "path": "/", "build": "8a13610f74006aaf"}
```
`build` is optional. It is the build id of the client bundle the page
loaded: the content hash in `/beacon_client_<hash>.js`, which the client
reads from the URL of its own script (`document.currentScript`). The server
compares it with the bundle `priv/static/beacon_client.manifest` names now,
read on every join:

- the same bundle: the join goes on;
- another one (the app was rebuilt or redeployed since the page loaded): the
  server closes with **4409** `stale build`, and the client reloads the page
  behind its reload guard (see
  [Client Connection Behaviour](#client-connection-behaviour)), so a page
  never decodes a model with the codec of another build;
- the manifest cannot be read, or names a bundle that does not exist: the
  server logs an error and closes with **1011** `internal error`;
- no `build` (the page loaded the client from the unversioned
  `/beacon_client.js`, or a non-browser client): the join goes on unchecked,
  and the server logs a warning. The client also warns once when it finds no
  build id in its script URL.

A `build` that is not a string makes the join a message that fails to
decode. The check follows LiveView's `phx-track-static`: the client reports
the digested assets its page loaded on join, and an outdated page is told to
reload.

**event** -- A Msg the browser decoded from a DOM event. The client runs the
handler's decoder against the event, applies the Msg locally, and sends it
unless the Local layer handled it. `data` is the generated entry's
`encode_msg` output: a JSON string `{"__beacon_msg": <Msg>}`, the Msg in the
app's generated codec. The server decodes only the Msg constructors the
client-reachable code builds, and never renders `view` to resolve handlers.
`handler_id` and `target_path` are both the position id of the element whose
handler produced the Msg (`"0"` is the root, `"0.N"` its children); they are
for logs and traces. `clock` is monotonic per connection. `ops` is optional and
the browser client does not send it; the server never treats it as
authoritative state.
```json
{"type": "event", "name": "click", "handler_id": "0.1.0", "data": "{\"__beacon_msg\":{\"tag\":\"SetName\",\"arg0\":\"Ada\"}}", "target_path": "0.1.0", "clock": 5}
```

**event_batch** -- Bounded batch for explicit non-browser clients that need to
submit multiple server-visible events in one frame. Generated browser clients do
not replay local-only events through this path; local state stays local until a
server-visible event sends its own `event`.
```json
{"type": "event_batch", "events": [{"name": "click", ...}]}
```

**heartbeat** -- Keep-alive, sent every 30s. The browser client never sends
two within 500ms, writes it straight to the socket and never queues it, so a
reconnect does not release a burst of heartbeats.
```json
{"type": "heartbeat"}
```

**navigate** -- Client-side SPA navigation: a same-origin link click,
back/forward, or the client following a server `navigate`. Debounced events
of the old page are sent before it.
```json
{"type": "navigate", "path": "/about"}
```

**request_sync** -- Client requests a full authoritative model sync after it
cannot safely apply a server patch. The server responds with `model_sync`
without sending a new `mount`.
```json
{"type": "request_sync"}
```

## Server Messages (server to browser)

**mount** -- Reserved. The server does not send it: first paint comes from
HTTP SSR, a join is answered with `model_sync`, and later updates use
`model_sync` or `patch`. The browser client logs a received `mount` as an
error and ignores it.
```json
{"type": "mount", "payload": "<div>...</div>"}
```

**model_sync** -- Full authoritative model state. Sent on join, on rejoin, in
answer to `request_sync`, and whenever the server must replace the client's
cached model JSON. `version` is the current revision (see Versioning).
```json
{"type": "model_sync", "model": "{\"count\":1}", "version": 1, "ack_clock": 1}
```

**patch** -- Incremental server-computed RFC 6902 JSON Patch ops against the
client-visible model JSON. `version` is the revision the patch produces.
```json
{"type": "patch", "ops": "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":2}]", "version": 2, "ack_clock": 2}
```
A patch with `"ops": "[]"` is an **ack**: the server processed the
connection's events up to `ack_clock` without changing the client-visible
model. Its `version` is the current revision, not a new one.
```json
{"type": "patch", "ops": "[]", "version": 2, "ack_clock": 3}
```

**heartbeat_ack** -- Acknowledges heartbeat.
```json
{"type": "heartbeat_ack"}
```

**error** -- Server error (decode failure, rate limiting).
```json
{"type": "error", "reason": "Rate limited"}
```

**navigate** -- Server-initiated navigation (`router.push` / `router.replace`).
The client pushes the path onto the history, or replaces the current entry
when `replace` is true, and answers with its own `navigate`. A path that is not
local (does not start with `/`, or starts with `//`) is logged as an error and
ignored; the current path is not navigated again.
```json
{"type": "navigate", "path": "/dashboard"}
{"type": "navigate", "path": "/search?q=x", "replace": true}
```

### hard_navigate (server → client)
Full page navigation via `window.location.href`. Unlike `navigate` (which uses pushState),
this triggers a real HTTP request — use when the browser needs to receive HTTP headers
(e.g., Set-Cookie after login).

```json
{"type": "hard_navigate", "path": "/api/auth/session/TOKEN"}
```

**reload** -- Dev mode: tells the browser to reload. See `beacon/dev`.
```json
{"type": "reload"}
```

## Versioning

The runtime keeps one `revision` per session (the `version` field on the wire).

- It is bumped only when the client-visible model JSON changes, and every such
  change is broadcast to all joined connections as a patch carrying the new
  revision (or as a `model_sync` at the new revision when the server has no
  cached model to diff against). Changes from any source count: an event from any connection, an
  effect, a store or PubSub update, a timer, a navigation or a join that
  changes the model.
- Navigation and joins never bump the revision by themselves. A navigation
  that leaves the model unchanged sends nothing.
- `model_sync` carries the current revision. A patch carries the revision it
  produces, which is always the previous revision plus one.
- An event that leaves the model unchanged (or fails) is answered with an ack
  patch (`"ops": "[]"`) at the current revision. A failed event sends its
  `error` first.

Client rules, which the generated browser client follows:

| Frame | Condition | Action |
|-------|-----------|--------|
| `model_sync` | `version` not a non-negative integer | Treat as a failed sync |
| `model_sync` | older than the cached revision | Ignore |
| `model_sync` | otherwise | Replace the cached model |
| `patch` | no synced model yet | Gap: `request_sync` |
| `patch` with ops | `version` = cached + 1 | Apply |
| `patch` with ops | `version` <= cached | Ignore (stale) |
| `patch` with ops | `version` > cached + 1 | Gap: `request_sync` |
| `patch` `[]` | `version` = cached | Ack |
| `patch` `[]` | `version` < cached | Ignore (stale) |
| `patch` `[]` | `version` > cached | Gap: `request_sync` |

A patch that fails to parse, apply or decode, or a server frame that is not
JSON, drops the cached model and sends `request_sync`. Only one
`request_sync` is in flight at a time; any `model_sync` answers it. A
`model_sync` that cannot be decoded is retried with `request_sync` up to 3
times in a row. After that the client logs an error and stops requesting
syncs on that connection (a reload recovers). A new connection starts over.

## Event Clocking

Each `event` has a monotonic `clock`. The server keeps the highest clock it has
processed per connection and echoes it back as `ack_clock` on `model_sync` and
`patch`, so the client knows which of its optimistic events the server state
already includes. A frame whose `ack_clock` is behind the client's pending
model event is held until the server catches up.

## Client Connection Behaviour

The generated browser client handles close codes, reconnects and sending as
follows.

- **4400 to 4499**: the server refused this page's session. That is `init`
  refusing with a 4xx status (4000 + the status), 4401 for a revoked session
  or failed authentication, and 4409 `stale build` for a page from another
  build. The client stops reconnecting, logs an error and reloads the page.
  The new page load decides: the server renders the page again (a fresh
  session, the login page, or the page with the current bundle) or answers
  with its error page, which opens no socket.
  A reload guard in `sessionStorage` (`beacon:reloads`) allows at most 3 such
  reloads per tab within 60 seconds, whatever the code. After that, or when
  `sessionStorage` cannot be used, the client does not reload. It logs the
  reason, marks the app root with `data-beacon-error` and puts a
  `role="alert"` notice (`data-beacon-error-notice`) at the top of the root.
  The guard is what stops a loop: a deployment whose pages keep naming
  another bundle than its manifest gets 3 reloads, then the error state.
- **Any other close** (including 1001, 1008, 1009, 1011, 1013 and 4500 to
  4599): reconnect after `min(1s * 2^attempts, 30s)` plus up to 1s of random
  jitter. `attempts` resets only after a `model_sync` is applied. A server
  that keeps refusing (4503 while a store is down, 1011 for an `init` that
  crashes) or that accepts and drops sockets is therefore tried at most once
  every 31 seconds per tab. 1001 is a server that is shutting down: the
  reconnect reaches the next instance, or this one once it is back.
- A `reload` message (dev mode) reloads the page at once, without the guard:
  the server sends it once per rebuild, never in answer to a join.
- **Outbound pacing**: every message except `heartbeat` passes through one
  queue paced at 40 messages per sliding 1s window (an `event_batch` costs one
  per event, as on the server), below the server's 50 per second. The queue
  holds 200 messages. `request_sync` goes ahead of queued events. Events wait
  until the first `model_sync` on a connection. A full queue is
  logged as an error and, once the queue drains, followed by `request_sync`.
  Nothing is dropped silently.
- **Batches**: an `event_batch` with more than 40 events is split into
  batches of at most 40, sent in order.
- **`Rate limited` and `Batch too large`** errors are logged and followed by
  `request_sync`, since the rejected message may have carried state the
  client already applied optimistically. Other `error` reasons are logged.
- Unknown server message types are logged as errors.

## Reconnection Flow

1. Client reopens WebSocket to `/ws?path=<current page path>`.
2. Browser sends `join` with an empty token; the cookie is carried by the WebSocket upgrade request.
3. Server validates token age (max 24h) and deserializes model.
4. Success: `model_sync` with recovered state. Failure: uses current model and logs the recovery error.

## Upgrade Handshake

The server answers `GET /ws` with `101 Switching Protocols` only when every
check passes. Checks run in this order, and each rejection is logged with the
connection id and peer address. The `SecurityLimits` are not checked here:
the listener refuses to start with invalid ones.

| Check | Rejection |
|-------|-----------|
| Global connection limit (`max_connections`, 10,000) | 503 |
| Per-IP WebSocket cap (`max_ws_connections_per_ip`, 100) | 429 |
| `Origin` present and allowed (see below) | 403 |
| `ws_auth` callback, if configured | 401 |
| Method is `GET` | 400 |
| `Upgrade` contains the `websocket` token, `Connection` contains `upgrade` | 400 |
| `Sec-WebSocket-Version: 13` | 426 with `Sec-WebSocket-Version: 13` |
| `Sec-WebSocket-Key` is 24 base64 chars that decode to 16 bytes | 400 |

**Origin rules.** The `Origin` header is required. It must match the request's
own origin on scheme, host and port, or equal one entry of
`ws_allowed_origins` (each a bare `scheme://host[:port]`). Default ports are
applied (`http` 80, `https` 443), and comparison is case-insensitive. The
request scheme is the first `X-Forwarded-Proto` token when the peer is one of
`trusted_proxies` (only `http` or `https` are accepted, and several
`X-Forwarded-Proto` headers are refused; either is a 403), and plain `http`
otherwise: the header is ignored from any other peer, since Beacon does not
terminate TLS itself. So `https://app.example`
is rejected against a plain-http request for the same host, and so is
`http://app.example:8080` against `app.example:3000`.

## Frames (RFC 6455)

Client frames are validated as they arrive. A violation closes the connection
with a close frame carrying the code below, then the TCP socket:

| Violation | Close code |
|-----------|------------|
| Unmasked client frame, non-zero RSV bits, unknown opcode | 1002 |
| Control frame fragmented or with a payload over 125 bytes | 1002 |
| Continuation with no message in progress, or a new data frame mid-message | 1002 |
| Close payload of 1 byte, or a code a peer must not send (1004-1006, 1015, below 1000, 1016-2999, 5000 and up) | 1002 |
| Frame or reassembled message over `max_message_bytes` (64KB) | 1009 |
| Text message (including one split across fragments) that is not valid UTF-8 | 1007 |
| Binary message | 1003 |

A client close frame is echoed with the same code, and an empty close is
answered with an empty close (reported as 1005). The connection closes after
the echo.

## Liveness

- The server sends a ping every `ws_ping_interval_ms` (30s). If no pong arrives
  within `ws_pong_timeout_ms` (20s) it closes with **1000** `pong timeout`.
  Browsers answer pings automatically. Pings may be interleaved with the
  fragments of a message.
- With no client message (events, heartbeats or pongs) for `ws_idle_timeout_ms`
  (90s) the server closes with **1000** `idle timeout`. A `heartbeat` counts
  as activity.
- On every close the handler process, its runtime, its timers and its per-IP
  slot are released.

## Backpressure

- Each socket send has a timeout of `ws_send_timeout_ms` (15s). A send that
  times out or fails closes the connection. Beacon does not retry it.
- If more than `ws_max_outbound_queue` (1000) messages are waiting in the
  connection's mailbox, it closes with **1013** `server overloaded`.
- When the runtime asks for a slow connection to be dropped
  (`CloseForBackpressure`), the server sends an `error` message with the
  reason and then closes with **1013** `backpressure`.

## Rate Limiting and Abuse

- Events are limited to `max_events_per_second` (50) per connection. Every
  event inside an `event_batch` counts, and a batch that would exceed the
  remaining budget is rejected whole with `{"type":"error","reason":"Rate limited"}`.
  A batch with more than 100 events is rejected with `Batch too large`, so a
  batch larger than `max_events_per_second` can never be accepted. Clients
  should cap batches at `max_events_per_second`.
- The limit is not sent to the client. Like Phoenix channels, Beacon does
  not advertise it: it is there for clients that do not pace themselves, and
  an advertised number would not slow those down. The generated client paces
  itself at 40 events per second against the default of 50 (see
  [Client Connection Behaviour](#client-connection-behaviour)). A lower
  `max_events_per_second` is allowed, and the listener logs a warning at
  start, since a burst from an honest client is then rate limited.
- Heartbeats are limited to 2 per second. Extra heartbeats are not acked and
  count as violations.
- Each rejected message is one rate violation. More than
  `ws_max_rate_violations` (100) violations within one 1-second window closes
  the connection with **1008** `rate limit exceeded`.
- Each message that fails to decode is answered with
  `{"type":"error","reason":"Invalid message"}`. More than
  `ws_max_decode_errors` (10) over the life of the connection close it with
  **1008** `too many invalid messages`.

## Sessions and Authentication

- When `ws_auth` is configured with `auth.protect_ws`, the upgrade requires
  a valid session cookie naming a logged-in user. A missing, unknown or
  expired session gets 401. `auth.allow_guests_ws` admits guests and binds a
  logged-in session the same way.
- The check runs again every `ws_auth_recheck_interval_ms` (60s) on live
  sockets. A failed re-check closes with **4401** `authentication expired`.
- Logging out, rotating the session id (on login or a privilege change) or
  deleting the session closes every live socket bound to it immediately with
  **4401** `session revoked`. The old id is then rejected with 401.
- A client receiving **4401** must not reconnect with the same session. The
  generated client reloads the page (behind its reload guard), so the server
  renders it for the session the cookie now names, or the login page.

## Close Codes

| Code | Meaning |
|------|---------|
| 1000 | Normal close, pong timeout or idle timeout |
| 1001 | Going away: the server is draining for a shutdown (`server shutting down`). The client reconnects with backoff |
| 1002 | Protocol error (bad frame, bad close payload) |
| 1003 | Binary data not supported |
| 1005 | Reported for an empty close frame (never sent as a code) |
| 1007 | Invalid UTF-8 in a text message |
| 1008 | Policy violation: rate limit or decode-error flood |
| 1009 | Message too big |
| 1011 | Internal error (`internal error`): `init` crashed, the runtime did not start, the handler got a message it does not know, or a join's build cannot be checked because the client bundle is missing. The client reconnects with backoff |
| 1013 | Try again later (backpressure or overload) |
| 4400-4499 | The server refused this page's session. The client does not reconnect: it reloads the page, at most 3 times per tab within 60 seconds |
| 4000 + status | `init` refused with that 4xx status (4404, 4403, ...) |
| 4401 | Session revoked (`session revoked`) or authentication expired (`authentication expired`). The page reloads, so the server renders it for whoever the cookie now names, or the login page |
| 4409 | Stale build (`stale build`): the join's `build` is not the bundle the server serves now. The page reloads and gets the current bundle |
| 4500-4599 | `init` refused with a 5xx status (4503 for `error.unavailable`). The client reconnects with backoff |

An `init` refusal with 401 or 409 also closes with 4401 or 4409. The action
is the same, a reload, and the close reason and the server log tell them
apart.
