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

A text message that does not decode gets an `error` frame with the reason
`Invalid message`; the raw text is never logged or echoed, only its size.
After `ws_max_decode_errors` (default 10) such messages the connection
closes with 1008. A message over `max_message_bytes` (default 64 KB)
closes the connection with 1009 ("message too big"), checked from the frame
header before the payload is buffered. See [SECURITY.md](SECURITY.md).

## Rate Limiting

Each connection may send `max_events_per_second` events per one-second
window (default 50); each event in a batch counts. An event over the budget
is dropped and answered with `{"type":"error","reason":"Rate limited"}`.
Heartbeats have their own limit of 2 per second: one over it is not acked.
Every rejection counts as a violation, and a connection with more than
`ws_max_rate_violations` (default 100) closes with 1008. A new window
resets the budget and forgives earlier violations.

## Join Tokens

A join token lives 24 hours. A token that does not verify (malformed, badly
signed, expired, or issued to another browser session), a token model that
`restore` refuses, and a missing token while state recovery is enabled each
refuse the connection
before `init` runs: the socket closes with 4400 and the browser reloads the
page for a fresh token. The refusal is logged with its reason.

## Model Size Limits

The client-visible model JSON is measured before it is sent. Over 1 MB logs
a warning. Over 5 MB logs an error, sends nothing but an `error` frame
(`Model too large: ...`) to the affected connections, and drops the cached
model, so they resync with a full model once it shrinks.

## Crashes in `update` and the View

There is no rescue around `update` or the view: a crash in either is a
runtime crash (see [Runtime Crashes](#runtime-crashes)). Return an error
value from `update` instead of crashing when the failure is expected.

## Handling Errors in Update

Match on `Result` in `update`. For effects that can fail, send an error
message back:

<!-- docs-check: wrap
import beacon/effect.{type Effect}
import gleam/option.{type Option, Some}

pub type Model {
  Model(name: String, saved: Bool, error: Option(String))
}

pub type Msg {
  Save
}

fn validate(model: Model) -> Result(Model, String) {
  case model.name {
    "" -> Error("a name is required")
    _ -> Ok(model)
  }
}

pub fn run(model: Model) -> #(Model, Effect(Msg)) {
  update(model, Save)
}

{{block}}
-->
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
