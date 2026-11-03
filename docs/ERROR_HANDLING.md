# Error Handling

All framework errors use `BeaconError` from `src/beacon/error.gleam`.

## Error Variants

| Variant | When it occurs |
|---------|----------------|
| `TransportError` | WebSocket bind/send failure |
| `CodecError` | Malformed JSON from client (carries raw payload) |
| `RuntimeError` | Event decode failure, unknown handler |
| `DiffError` | VDOM diffing failure |
| `RenderError` | SSR rendering failure |
| `RouteError` | Route matching or codegen failure |
| `EffectError` | Effect execution failure |
| `SessionError` | Token expired, state recovery failure |
| `ConfigError` | Missing init/update, invalid config |
| `InitRejected` | The app's `init` returned `Error(InitError)` on the connected mount |

## Errors in `init`

`init` returns `Result(_, InitError)`. Build the error with
`error.unavailable(reason)` (503) or `error.refuse(status, reason)` (any status
from 400 to 599; another status crashes, because it is a bug in the app).

| Where | `Error(InitError)` | `init` crashes |
|---|---|---|
| HTML render | A static error page with the error's status; the bundle is not loaded and no join cookie is set | 500, with no join cookie |
| WebSocket mount | Close with `4000 + status` (4503, 4404, ...) and the reason `init refused` | Close with 1011 and the reason `startup failure` |

The reason is logged, as an error for a 5xx status and as a warning for a 4xx
one, and never sent to the browser. The browser reloads the page on 4400 to
4499, at most 3 times per tab within 60 seconds (after that it shows an error
state instead), and reconnects with backoff on any other close, 4500 to 4599
and 1011 included. See
[WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#client-connection-behaviour). A static error page (a refusal,
an init crash, an unknown route, a missing bundle) opens no session, so it
neither sets the `beacon_join_token` cookie nor replaces one that another tab
is still joining with. `auth.init_from_session` answers a
session store outage with `error.unavailable`. See
[GETTING_STARTED.md](GETTING_STARTED.md#refusing-in-init).

A connection whose runtime does not start is logged once, where the cause is
known, with the connection id and page: a crash in `init` or the initial
route with its class, reason and stacktrace; a refusal at its status's level;
a presence refusal with its tracker. The layers between log the same failure
at debug, and the transport logs the close it answers with at info.

## Runtime Crashes

A runtime that crashes after it started (in `update`, the view or the codec)
dies with the crash's reason, and its connections close and reconnect to a
new one. Before it dies it emits `[beacon, runtime, stop]` with reason `crash`
and the reason as `error`; a runtime stopped by an exit signal (a linked
process failing) emits it with reason `exit`. See
[TELEMETRY.md](TELEMETRY.md).

## Transport Errors

Malformed messages get a `ServerError` response. Oversized messages (above 64KB) are rejected with `"Message too large"`.

## Rate Limiting

Exceeding `max_events_per_second` (default 50) returns `{"type":"error","reason":"Rate limited"}`. Heartbeats are exempt. The window resets every second.

## Token Expiration

Tokens expire after 24 hours. Expired or invalid tokens are rejected and logged;
the connection must rejoin with a valid session.

## Model Size Limits

Serialized model checked before broadcast: above 1MB logs a warning; above 5MB skips broadcast entirely.

## View Crashes

View rendering is wrapped in `rescue`. On crash: error logged, `ServerError` sent to client, runtime continues. Subsequent events and joins still work.

## Handling Errors in Update

Match on `Result` in update. For effects that can fail, dispatch error messages back:

```gleam
fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Save ->
      case validate(model) {
        Ok(_) -> #(Model(..model, saved: True), effect.none())
        Error(reason) -> #(Model(..model, error: Some(reason)), effect.none())
      }
  }
}
```
