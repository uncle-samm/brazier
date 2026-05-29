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
| `RouterError` | Route matching or codegen failure |
| `EffectError` | Effect execution failure |
| `SessionError` | Token expired, state recovery failure |
| `ConfigError` | Missing init/update, invalid config |

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
fn update(model, local, server, msg) {
  case msg {
    Save ->
      case validate(model) {
        Ok(_) -> #(Model(..model, saved: True), local, server)
        Error(reason) -> #(Model(..model, error: Some(reason)), local, server)
      }
  }
}
```
