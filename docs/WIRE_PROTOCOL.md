# Wire Protocol

Brazier communicates over WebSocket at `/ws` using JSON messages with a `type` discriminator.

The browser connects to `/ws?path=<page path>`, the URL-encoded path and
query string of the page (`encodeURIComponent(location.pathname +
location.search)`), on the first connection and on every reconnect. The server
resolves the route from it, so `init` sees the same URL as the server render.
`path` is required: the upgrade is refused with 400 (logging a warning) when
it is missing or not a same-origin path. The app's middleware runs on a `GET`
of that page with the upgrade's headers, once the handshake checks pass. When
it refuses the page, the server completes the handshake and closes the socket
with **4600** `middleware refused <status>`, and the client loads the page
over HTTP to show the middleware's answer (see
[Close Codes](#close-codes) and
[MIDDLEWARE.md](MIDDLEWARE.md#the-live-page)).

## Client Messages (browser to server)

**join** -- Sent after WebSocket opens. `path` drives routing. `token` remains in the JSON shape for direct runtime tests and non-browser clients, but browser join/session recovery uses the HttpOnly `brazier_join_token` cookie from the WebSocket upgrade request.
```json
{"type": "join", "token": "", "path": "/", "build": "8a13610f74006aaf", "dev_build": "k3x9q"}
```
`build` is optional. It is the build id of the client bundle the page
loaded: the content hash in `/brazier_client_<hash>.js`, which the client
reads from the URL of its own script (`document.currentScript`). The server
compares it with the bundle `priv/static/brazier_client.manifest` named when
the server started (or, under `brazier/dev`, after the last rebuild). The
manifest is read then, not on each join, so a join touches no file:

- the same bundle: the join goes on;
- another one (the app was rebuilt or redeployed since the page loaded): the
  server closes with **4499** `stale build`, and the client reloads the page
  behind its reload guard (see
  [Client Connection Behaviour](#client-connection-behaviour)), so a page
  never decodes a model with the codec of another build;
- the server has no loaded bundle (a failed load; a server that cannot read
  its manifest at start does not start): the server logs an error and closes
  with **1011** `internal error`;
- no `build` (the page loaded the client from the unversioned
  `/brazier_client.js`, or a non-browser client): the join goes on unchecked,
  and the server logs a warning once per connection, at debug on later
  joins. The client also warns once when it finds no build id in its script
  URL.

`dev_build` is optional too, and only a server under `brazier/dev` reads it.
It is the dev build the page was rendered under: the server renders it as
`data-brazier-dev-build` on `#brazier-app`, and a new one is made on every
rebuild. A join whose `dev_build` is not the server's current one is from a
page rendered before the last rebuild, which may have been between sockets
when the rebuild's `reload` frame went out: the server answers
`{"type": "reload"}` and does not dispatch the join, and the page reloads
(see **reload** under [Server Messages](#server-messages-server-to-browser)).
A join without `dev_build`, or a server outside dev mode, is not checked.

A join without `build` stays accepted because non-browser clients and the
unversioned bundle have no build id to send, and refusing them would break
both. The cost is that such a client is not protected from a wire change: a
client from before `model` and `ops` became raw JSON values gets a
`model_sync` it cannot read. It does not run on with a wrong model: it fails
the sync loudly, retries `request_sync` up to 3 times, logs an error and
stops (see [Versioning](#versioning)). A page that loads its bundle by hash
always sends `build`, and gets 4499 instead.

A `build` that is not a string makes the join a message that fails to
decode. The check follows LiveView's `phx-track-static`: the client reports
the digested assets its page loaded on join, and an outdated page is told to
reload.

**event** -- A Msg the browser decoded from a DOM event. The client runs the
handler's decoder against the event, applies the Msg locally, and sends it
unless the Local layer handled it. `data` is the generated entry's
`encode_msg` output: a JSON string `{"__brazier_msg": <Msg>}`, the Msg in the
app's generated codec. The server decodes only the Msg constructors the
client-reachable code builds, and never renders `view` to resolve handlers.
`handler_id` and `target_path` are both the position id of the element whose
handler produced the Msg (`"0"` is the root, `"0.N"` its children); they are
for logs and traces. `clock` is monotonic per connection.
```json
{"type": "event", "name": "click", "handler_id": "0.1.0", "data": "{\"__brazier_msg\":{\"tag\":\"SetName\",\"arg0\":\"Ada\"}}", "target_path": "0.1.0", "clock": 5}
```
`ops` is optional, and the browser client does not send it. It is an array
of RFC 6902 ops, embedded in the frame as a JSON value like a `patch`'s
`ops`, never a string holding JSON:
```json
{"type": "event", "name": "click", "handler_id": "0.1.0", "data": "{\"__brazier_msg\":{\"tag\":\"Inc\"}}", "target_path": "0.1.0", "clock": 6, "ops": [{"op": "replace", "path": "/count", "value": 2}]}
```
The server never applies the ops: its own `update` decides the model, and
the runtime logs a warning that it ignored them. It still decodes them
strictly, so a client that sends malformed ops learns at once:

- every op is an object whose `op` is one of `add`, `remove`, `replace`,
  `move`, `copy`, `test` or `append`;
- `path`, and `from` for `move` and `copy`, are RFC 6901 JSON Pointers:
  empty or starting with `/`, with `~` only in `~0` or `~1`, and no
  `__proto__`, `constructor` or `prototype` segment;
- `add`, `replace` and `test` carry a `value`, and `append` carries an array
  `value`. Members an op does not define are ignored (RFC 6902 §4).

An event, or an `event_batch`, with any op that breaks these rules is refused
whole (RFC 6902 §5): the server logs a warning with the connection id and the
first error, answers `{"type":"error","reason":"Invalid event ops"}`, and does
not dispatch it. It counts as a message that failed to decode (see
[Rate Limiting and Abuse](#rate-limiting-and-abuse)).

`ops` used to be a string holding the JSON array (see `CHANGELOG.md`). That
form is now refused as invalid ops. A page whose bundle is from before the
change sends its `build` id on join and gets **4499** `stale build`, so it
reloads with the current bundle before it sends an event (see `build` under
**join** above).

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
of the old page are sent before it. `path` is the pathname and search; the
URL's fragment stays in the browser. `clock` comes from the same per-connection
counter as the events' clocks, and the server acknowledges it like an event:
the first `model_sync` or `patch` it sends this connection after handling the
navigation carries `ack_clock` = `clock`, and a navigation that leaves the
client-visible model as it was is answered with an ack (an empty patch). A
navigation the server refuses (`hard_navigate`, `error`) gets no ack. A
`navigate` without `clock` is acknowledged at 0; one whose `clock` is not an
integer is malformed.
```json
{"type": "navigate", "path": "/about", "clock": 7}
```
That ack is how the browser client finds the frame that shows the new page.
After a link click or a server `navigate` to a URL with a fragment
(`/docs#install`), it scrolls once the first applied frame with `ack_clock` ≥
the navigate's clock is rendered: to the element whose id is the fragment,
else to the `<a>` with that `name` (the fragment as written, then
percent-decoded), and to the top of the page, with a console warning, when
there is neither. This is LiveView's `Browser.pushState` after a patch reply
(`getHashTargetEl`, `scrollIntoView`, else `window.scroll(0, 0)`). Back and
forward keep the browser's scroll restoration and schedule no scroll. A
navigate written to a socket that dropped before its ack is answered by the
next connection's join `model_sync`, whose page is the current URL's.
The middleware runs on a `GET` of the target page first, as it does at the
upgrade. A page it refuses is not navigated to: the server sends
`hard_navigate` to the path, so the browser loads it over HTTP and gets the
middleware's answer. A path that is not a same-origin path gets
`{"type":"error","reason":"Invalid page path"}`. A `join` whose `path` is
not the upgrade's page is gated the same way.

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
`model` is the client-visible model as a JSON value, embedded in the frame as
it is (not a JSON string holding it). `streams` is required (see
**Streams** below).
```json
{"type": "model_sync", "model": {"count": 1}, "version": 1, "ack_clock": 1, "streams": []}
```

**patch** -- Incremental server-computed RFC 6902 JSON Patch ops against the
client-visible model JSON. `version` is the revision the patch produces.
`ops` is the array of ops, embedded in the frame as it is. `streams` is
required (see **Streams** below).
```json
{"type": "patch", "ops": [{"op": "replace", "path": "/count", "value": 2}], "version": 2, "ack_clock": 2, "streams": []}
```
A patch with `"ops": []` is an **ack**: the server processed the
connection's events and navigations up to `ack_clock` without changing the
client-visible model. Its `version` is the current revision, not a new one.
```json
{"type": "patch", "ops": [], "version": 2, "ack_clock": 3, "streams": []}
```

**Streams** -- Every `patch` and `model_sync` carries a required `streams`
array, last in the frame: one entry per stream (`brazier/stream`, as
LiveView's `stream/4`) whose items the frame changes for this connection,
`[]` when it changes none. A frame without `streams`, or with one that is
not an array, is a protocol error, never "no change". Each entry:

| Field | Type | Meaning |
|-------|------|---------|
| `name` | string | The stream's declared name |
| `keep` | `"first"` or `"last"` | The end the limit keeps |
| `limit` | integer, 1 to 1000 | The limit |
| `reset` | boolean | Empty the stream before the deletes and inserts |
| `deletes` | array of keys | Keys to remove, those the limit trims included |
| `inserts` | array of `{key, at, item}` | `at` is the item's index in the stream after this entry, in ascending order; `item` is the stream's encoded item, embedded as JSON |

Stream ops ride the frame of the update that made them. When the model
changed, that is the update's patch:
```json
{"type": "patch", "ops": [{"op": "replace", "path": "/count", "value": 3}], "version": 3, "ack_clock": 4,
 "streams": [{"name": "log", "keep": "last", "limit": 3, "reset": false,
              "deletes": ["a"],
              "inserts": [{"key": "d", "at": 2, "item": {"id": "d", "text": "added"}}]}]}
```
When it did not, the entries go on an ack-shaped patch (`"ops": []` at the
current revision, with that connection's own `ack_clock`) to every joined
connection, not only the one whose event caused them. The items `init`
filled before the first join arrive on that join's `model_sync` as
`reset: true` entries; a later connection, a rejoin and a `model_sync`
answering `request_sync` carry `"streams": []` (the server keeps keys,
not items, once a connection joined, so it never sends items again). Each
connection's entries are computed against what that connection was sent,
so two connections can get different `at` indices for one insert.

The server checks every entry before it sends it: a refused stream op (an
undeclared stream, a limit, key or item over the `SecurityLimits` stream
bounds, see [SECURITY.md](SECURITY.md#stream-bounds)) is not sent, and the
joined connections get an `error` frame for it instead, before the frame
of its update:
```json
{"type": "error", "reason": "Stream log: refused 1 op(s): the item is 70013 bytes, over the limit of 65536"}
```
The browser client's rules for applying an entry, and the `stream fault`
close when one cannot be applied, are in
[design/STREAMS.md](design/STREAMS.md#62-client-rules).
The server writes `model`, `ops` and each stream `item` into the frame
without decoding or re-encoding them, as Phoenix's V2 serializer embeds a
reply's payload, and a client parses each frame once. That is safe because
the runtime builds all three from its own encoder output: the model JSON is
checked to be valid JSON before it is cached or sent, the ops come from
diffing two decoded models, and each item is the stream's `encode` output
through `gleam/json`. Before this change `model` and `ops` were JSON
strings, which made the server escape every quote in the model and the
client parse it twice.

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
when `replace` is true, and answers with its own `navigate` for the path
without its fragment, scrolling to the fragment as for a link. A path that is not
local (does not start with `/`, or starts with `//`) is logged as an error and
ignored; the current path is not navigated again.
```json
{"type": "navigate", "path": "/dashboard"}
{"type": "navigate", "path": "/search?q=x", "replace": true}
```

**title** -- The page title, from the app's `brazier.title`. Sent on every
join, and after an update to every joined connection when the title differs
from the last one sent (it is a function of the server state, so it can
change when the client-visible model does not). The client sets
`document.title`; a frame without a string `title` is logged as an error and
ignored. An app without `brazier.title` never sends it. A title over
`runtime.title_max_bytes` (4096) is not sent: the server logs an error and
sends `{"type":"error","reason":"Title too large: ..."}` instead, and the
page keeps its last title. The error is sent once when the title goes over
the limit (and to a connection that joins while it is over), not after each
update while it stays over; the title going back within the limit is
logged, and a later title over it is reported again.
```json
{"type": "title", "title": "Inbox (3)"}
```

### hard_navigate (server → client)
Full page navigation via `window.location.href`. Unlike `navigate` (which uses pushState),
this triggers a real HTTP request — use when the browser needs to receive HTTP headers
(e.g., Set-Cookie after login). The server also sends it for a `navigate` or
`join` the middleware refuses. The client follows only a same-origin path.

```json
{"type": "hard_navigate", "path": "/api/auth/session/TOKEN"}
```

**reload** -- Dev mode only: the app was rebuilt, reload the page. Under
`gleam run -m brazier/dev` every WebSocket handler subscribes to the PubSub
topic `brazier:dev:reload`, and each successful rebuild broadcasts on it, so
every open page gets one `reload`. The server keeps the socket open; the
page's reload closes it. A page that was between sockets during the
broadcast misses it, so the server also answers a `join` whose `dev_build`
is not the current one with `reload` instead of dispatching it (see
**join**). Outside dev mode no handler subscribes, no join is checked, and
the server never sends it.
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
  patch (`"ops": []`) at the current revision. A failed event sends its
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

A patch whose `ops` is not an array, or that fails to apply or decode, or a
server frame that is not JSON, drops the cached model and sends
`request_sync`. A `model_sync` with no `model`, or one whose `model` does not
decode (a JSON string holding the model, as an older server sent, does not),
is a failed sync. Only one
`request_sync` is in flight at a time; any `model_sync` answers it. A
`model_sync` that cannot be decoded is retried with `request_sync` up to 3
times in a row. After that the client logs an error and stops requesting
syncs on that connection (a reload recovers). A new connection starts over.

## Event Clocking

Each `event` and `navigate` has a monotonic `clock`, from one counter. The
server keeps the highest clock it has processed per connection and echoes it back as `ack_clock` on `model_sync` and
`patch`, so the client knows which of its optimistic events the server state
already includes. A frame whose `ack_clock` is behind the client's pending
model event is held until the server catches up. `clock` and `ack_clock` are
required non-negative integers. A `model_sync` or `patch` without a valid
`ack_clock` is a protocol error, logged in the browser, and the client asks
for a full sync. It never defaults the value to 0.

## Client Connection Behaviour

The generated browser client handles close codes, reconnects and sending as
follows.

- **4400 to 4499**: the server refused this page's session. That is `init`
  refusing with a 4xx status (4000 + the status), 4401 for a revoked session
  or failed authentication, and 4499 `stale build` for a page from another
  build. The client stops reconnecting, logs an error and reloads the page.
  The new page load decides: the server renders the page again (a fresh
  session, the login page, or the page with the current bundle) or answers
  with its error page, which opens no socket.
  A reload guard in `sessionStorage` (`brazier:reloads`) allows at most 3 such
  reloads per tab within 60 seconds, whatever the code. After that, or when
  `sessionStorage` cannot be used, the client does not reload. It logs the
  reason, marks the app root with `data-brazier-error` and puts a
  `role="alert"` notice (`data-brazier-error-notice`) at the top of the root.
  The guard is what stops a loop: a deployment whose pages keep naming
  another bundle than its manifest gets 3 reloads, then the error state.
- **4600**: the app's middleware refused this page's live connection. The
  client stops reconnecting, logs an error naming the middleware's status and
  loads the current URL (`location.reload()`, which keeps the query and
  fragment), so the browser shows the middleware's own answer: its redirect,
  its 403 page, its login page. The load shares the reload guard above. A
  middleware that admits the page's `GET` but refuses its live connection
  therefore gets 3 loads, then the error state, never a reconnect loop.
- **Any other close** (including 1001, 1008, 1009, 1011, 1013, 4500 to
  4599, and any other 4xxx code, which the client does not know): reconnect
  after `min(1s * 2^attempts, 30s)` plus up to 1s of random
  jitter. `attempts` resets only after a `model_sync` is applied. A server
  that keeps refusing (4503 while a store is down, 1011 for an `init` that
  crashes) or that accepts and drops sockets is therefore tried at most once
  every 31 seconds per tab. 1001 is a server that is shutting down: the
  reconnect reaches the next instance, or this one once it is back.
- **A socket that closes before it opens** (1006 without `onopen`) is
  retried the same way. A browser reports every failed upgrade like this,
  whatever the server answered: an unreachable server, an origin or host
  the server does not allow, `ws_auth` refusing the upgrade, or a connection
  limit. Middleware refusing the page is not one of them: the server
  completes that handshake so it can close with 4600, which the browser can
  read. The first two such closes in a row are warnings;
  from the third the client logs an error that names these causes. A socket
  that opens resets the count.
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
3. Server checks the token before `init` runs: it must verify (signature,
   age at most 24h, the same browser session). With state recovery enabled,
   a join without a token fails the check too. Then `init` and the route
   run, and the token's model must decode; the app's `restore` puts it onto
   the fresh state (see
   [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md#recovering-state-after-a-reconnect)). A `restore`
   that crashes closes the socket with 1011.
4. Success: `model_sync` with the recovered state. Failure: the refusal is
   logged and the socket closes with 4400, so the client reloads the page
   (behind the reload guard) and the new render issues a fresh token. The
   session never continues with a state it could not recover.

## Upgrade Handshake

The server answers `GET /ws` with `101 Switching Protocols` only when every
check passes. Checks run in this order, and each rejection is logged with the
connection id and peer address. The `SecurityLimits` are not checked here:
the listener refuses to start with invalid ones.

| Check | Rejection |
|-------|-----------|
| `Host` in `allowed_hosts` (see [SECURITY.md](SECURITY.md#allowed-hosts)) | 400 |
| No request body, and no bytes sent before the handshake | 400 |
| `path` query parameter present and a same-origin path | 400 |
| Global connection limit (`max_connections`, 10,000) | 503 |
| Per-IP WebSocket cap (`max_ws_connections_per_ip`, 100) | 429 |
| `Origin` present and allowed (see below) | 403 |
| `ws_auth` callback, if configured | 401 |
| Method is `GET` | 400 |
| `Upgrade` contains the `websocket` token, `Connection` contains `upgrade` | 400 |
| `Sec-WebSocket-Version: 13` | 426 with `Sec-WebSocket-Version: 13` |
| `Sec-WebSocket-Key` is 24 base64 chars that decode to 16 bytes | 400 |
| The middleware admits a `GET` of the page | 101, then close **4600** `middleware refused <status>` |

The middleware runs last, on a request that has passed every other check.
A browser cannot read the status of an upgrade that fails: `onclose` reports
1006 for a 403 and for an unreachable server alike. So a refusal by the
middleware completes the handshake and closes the socket at once with 4600,
whose reason carries the middleware's status (`middleware refused 403`). The
server logs a warning with the connection id, the peer, the page and the
status, sends nothing else, and starts no runtime. The connection's slots
are released before the TCP socket closes. The client answers by loading the
page (see [Client Connection Behaviour](#client-connection-behaviour)). This
is LiveView's answer to a refused join: `view.ts` `onJoinError` navigates to
the page's own URL, so the HTTP request shows the refusal.

Running the middleware after the origin, `ws_auth` and handshake checks
means a cross-origin page never reaches it, so the 101-then-4600 answer
tells no foreign page anything about the app's routes. Those checks answer
over HTTP, as before.

**Origin rules.** The `Origin` header is required. It must match the request's
own origin on scheme, host and port, or equal one entry of
`ws_allowed_origins` (each a bare `scheme://host[:port]`). Default ports are
applied (`http` 80, `https` 443), and comparison is case-insensitive. The
request scheme is the first `X-Forwarded-Proto` token when the peer is one of
`trusted_proxies` (only `http` or `https` are accepted, and several
`X-Forwarded-Proto` headers are refused; either is a 403), and plain `http`
otherwise: the header is ignored from any other peer, since Brazier does not
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
  times out or fails closes the connection. Brazier does not retry it.
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
- The limit is not sent to the client. Like Phoenix channels, Brazier does
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
  `{"type":"error","reason":"Invalid message"}`, or with
  `{"type":"error","reason":"Invalid event ops"}` when only its `ops` are
  malformed (see **event**). More than
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
| 1011 | Internal error (`internal error`): `init` crashed, the runtime did not start, the handler got a message it does not know, or a join's build cannot be checked because the server has no loaded client bundle. The client reconnects with backoff |
| 1013 | Try again later (backpressure or overload) |
| 4400-4499 | The server refused this page's session. The client does not reconnect: it reloads the page, at most 3 times per tab within 60 seconds |
| 4000 + status | `init` refused with that 4xx status (4404, 4403, 4409, ...). Never 4499: `error.refuse(499, _)` is a programming error and crashes `init` |
| 4401 | Session revoked (`session revoked`) or authentication expired (`authentication expired`). The page reloads, so the server renders it for whoever the cookie now names, or the login page |
| 4499 | Stale build (`stale build`): the join's `build` is not the bundle the server serves now. The page reloads and gets the current bundle |
| 4500-4599 | `init` refused with a 5xx status (4503 for `error.unavailable`). The client reconnects with backoff |
| 4600 | The app's middleware refused the page's live connection (`middleware refused <status>`), sent right after the handshake. The client does not reconnect: it loads the current URL behind the reload guard, so the browser shows the middleware's answer |

An `init` refusal with 409 closes with 4409, and a stale build with 4499,
so the close code alone tells them apart. 499 is not an HTTP status (nginx
uses it in its logs for a client that went away), so no `init` needs it,
and `error.reserved_status` names it. Stale build closed with 4409 before
this release (see `CHANGELOG.md`); a page from before then reloads on
either code, because both are in the reload band.

An `init` refusal with 401 still closes with 4401, the code of a revoked
session or expired authentication. The action is the same, a reload, and
the close reason and the server log tell them apart.

**The 4xxx scheme.** RFC 6455 §7.4.2 leaves 4000-4999 to applications.
Brazier splits it by what the client does, so the client decides from the
code alone and needs no table of reasons:

| Range | Who closes | Client action |
|-------|------------|---------------|
| 4400-4499 | `init` or the session refused (4000 + a 4xx status, 4401), or a stale build (4499) | Reload the page, behind the guard |
| 4500-4599 | `init` refused with a 5xx status | Reconnect with backoff |
| 4600-4699 | The transport refused the connection before any runtime (4600: the middleware) | 4600: load the page, behind the guard |
| Other 4xxx | Not sent by Brazier | Reconnect with backoff, like any unknown close |

4600 cannot collide with `init`'s codes: 4000 + status stays at or below
4599 because an HTTP status is at most 599. The client treats only the
codes it knows specially, so a server from a later release that sends a new
code does not make an older page reload in a loop.
