# Wire Protocol

Beacon communicates over WebSocket at `/ws` using JSON messages with a `type` discriminator.

## Client Messages (browser to server)

**join** -- Sent after WebSocket opens. `path` drives routing. `token` remains in the JSON shape for direct runtime tests and non-browser clients, but browser join/session recovery uses the HttpOnly `beacon_join_token` cookie from the WebSocket upgrade request.
```json
{"type": "join", "token": "", "path": "/"}
```

**event** -- DOM event. Generated clients resolve `handler_id` in the browser
and put the encoded typed message in `data.__beacon_msg`; the server decodes
that generated event contract and never renders `view` to resolve handlers.
`clock` is monotonic. `ops` is an optional client-computed patch hint (empty
string if none). The server never treats `ops` as authoritative state; it runs
the server-side update and replies with the server-computed model state or patch.
```json
{"type": "event", "name": "click", "handler_id": "h0", "data": "{\"__beacon_msg\":\"{\\\"tag\\\":\\\"Increment\\\"}\",\"__beacon_event\":\"{}\"}", "target_path": "0.1.0", "clock": 5, "ops": ""}
```

**event_batch** -- Bounded batch for explicit non-browser clients that need to
submit multiple server-visible events in one frame. Generated browser clients do
not replay local-only events through this path; local state stays local until a
server-visible event sends its own `event`.
```json
{"type": "event_batch", "events": [{"name": "click", ...}]}
```

**heartbeat** -- Keep-alive, sent every 30s.
```json
{"type": "heartbeat"}
```

**navigate** -- Client-side SPA navigation.
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

**mount** -- Reserved HTML remount message. Normal SSR + client-state apps do
not receive `mount` on join or on ordinary updates. First paint comes from HTTP
SSR; live join replies with `model_sync`, and later updates use `model_sync` or
`patch`.
```json
{"type": "mount", "payload": "<div>...</div>"}
```

**model_sync** -- Full authoritative model state. Sent on join and whenever the
server must replace the client's cached model JSON.
```json
{"type": "model_sync", "model": "{\"count\":1}", "version": 1, "ack_clock": 1}
```

**patch** -- Incremental server-computed JSON Patch ops. Sent after events when
model changes and the server can describe the change compactly.
```json
{"type": "patch", "ops": "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":2}]", "version": 2, "ack_clock": 2}
```

**heartbeat_ack** -- Acknowledges heartbeat.
```json
{"type": "heartbeat_ack"}
```

**error** -- Server error (decode failure, rate limiting).
```json
{"type": "error", "reason": "Rate limited"}
```

**navigate** -- Server-initiated redirect.
```json
{"type": "navigate", "path": "/dashboard"}
```

### hard_navigate (server → client)
Full page navigation via `window.location.href`. Unlike `navigate` (which uses pushState),
this triggers a real HTTP request — use when the browser needs to receive HTTP headers
(e.g., Set-Cookie after login).

```json
{"type": "hard_navigate", "path": "/api/auth/session/TOKEN"}
```

**reload** -- Dev mode: tells browser to reload.
```json
{"type": "reload"}
```

## Event Clocking

Each `event` has a monotonic `clock`. The server echoes it back as `ack_clock` on `model_sync` and `patch`, letting the client discard stale responses.

## Reconnection Flow

1. Client reopens WebSocket to `/ws`.
2. Browser sends `join` with an empty token; the cookie is carried by the WebSocket upgrade request.
3. Server validates token age (max 24h) and deserializes model.
4. Success: `model_sync` with recovered state. Failure: uses current model and logs the recovery error.

## Upgrade Handshake

The server answers `GET /ws` with `101 Switching Protocols` only when every
check passes. Checks run in this order, and each rejection is logged with the
connection id and peer address:

| Check | Rejection |
|-------|-----------|
| `SecurityLimits` are valid | 500 |
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
request scheme is the first `X-Forwarded-Proto` token when present (only
`http` or `https` are accepted; any other value is a 403), and plain `http`
otherwise, since Beacon does not terminate TLS itself. So `https://app.example`
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

- When `ws_auth` is configured (for example `auth.ws_session_auth`), the
  upgrade requires a valid session cookie. A missing, unknown or expired
  session gets 401.
- The check runs again every `ws_auth_recheck_interval_ms` (60s) on live
  sockets. A failed re-check closes with **4401** `authentication expired`.
- Logging out, rotating the session id (on login or a privilege change) or
  deleting the session closes every live socket bound to it immediately with
  **4401** `session revoked`. The old id is then rejected with 401.
- A client receiving **4401** must not reconnect with the same session. It
  should reload or send the user to log in.

## Close Codes

| Code | Meaning |
|------|---------|
| 1000 | Normal close, pong timeout or idle timeout |
| 1002 | Protocol error (bad frame, bad close payload) |
| 1003 | Binary data not supported |
| 1005 | Reported for an empty close frame (never sent as a code) |
| 1007 | Invalid UTF-8 in a text message |
| 1008 | Policy violation: rate limit or decode-error flood |
| 1009 | Message too big |
| 1011 | Internal error (runtime startup failure or an unexpected process message) |
| 1013 | Try again later (backpressure or overload) |
| 4401 | Session revoked or authentication expired. Do not reconnect |
