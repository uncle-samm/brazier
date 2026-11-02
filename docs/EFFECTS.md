# Effects

Effects are descriptions of side effects that the Beacon runtime executes. Following Lustre's design, effects are data -- not actions. The `Effect(msg)` type is opaque and composed via combinators.

## Effects Outside Update

Prefer a pure `update` plus `beacon.on_update` for application side effects.
That shape keeps the generated client renderer predictable: `update` can be
analyzed and compiled for client rendering, while stores, PubSub, HTTP, env
reads, randomness, and other BEAM-only work stay on the server.

`init` returns the initial model and a startup effect. Event-triggered effects
belong in `on_update`; `update` returns only the new `Model`, `Local`, and
`Server` values.

```gleam
fn init() -> #(Model, effect.Effect(Msg)) {
  #(Model(loading: True), effect.background(fn(dispatch) {
    let data = fetch_data()
    dispatch(DataLoaded(data))
  }))
}

fn update(model: Model, local: Nil, server: Nil, msg: Msg) -> #(Model, Nil, Nil) {
  #(handle_msg(model, msg), local, server)
}
```

## Core Functions

**`effect.none()`** -- No side effect. Use when update only changes the model.

**`effect.from(fn(dispatch) { ... })`** -- One-shot synchronous effect. The callback runs in the runtime process and receives a `dispatch` function to send messages back to the update loop.

**`effect.background(fn(dispatch) { ... })`** -- Runs the callback in a separate BEAM process. Does not block the update loop. Use for database queries, HTTP calls, or other I/O.

**`effect.every(interval_ms, fn() { Msg })`** -- Periodic timer that dispatches the message every `interval_ms` milliseconds (re-armed with `erlang:send_after` each tick, like LiveView's `Process.send_after`). Capped at 10 concurrent timers per runtime; additional timers are rejected with a warning and no process is started. `interval_ms < 1` is rejected with an error log. Each un-keyed call starts a NEW timer -- key it to replace instead (see below).

**`effect.after(delay_ms, fn() { Msg })`** -- Delayed one-shot. Dispatches the message once after `delay_ms` milliseconds. A negative delay is rejected with an error log.

**`effect.batch([effect1, effect2])`** -- Combine multiple effects. All callbacks execute with no ordering guarantees between them.

**`effect.map(effect, fn(a) -> b)`** -- Transform the message type. Used internally for component composition.

**`effect.keyed(key, effect)`** -- Tag an effect with a stable key. Messages from an older generation of the same key are dropped by the runtime. For spawned effects (`background`, `every`, `after`) the key is also single-flight: performing a keyed spawned effect first stops the process previously started under that key. Re-keying a timer therefore replaces it and never consumes an extra timer slot:

```gleam
// Restarting the poller on every filter change keeps exactly one timer.
effect.keyed("poll", effect.every(5000, fn() { Poll }))
```

**`effect.cancellable(effect)` / `effect.cancel(token)`** -- Generate a unique key for an effect and return a token. Cancelling drops any later messages from that effect and stops its process.

## Process Lifecycle

`background`, `every` and `after` processes are owned by the runtime that performed them and never outlive it:

- Timers (`every`, `after`) monitor the runtime and stop on its `DOWN`, whatever the exit reason (normal shutdown, crash or kill).
- A `background` worker runs arbitrary code and so cannot watch its owner itself; a small guardian process monitors the runtime, links to the worker and kills it when the runtime exits. The guardian exits as soon as the worker finishes.
- The dynamic-subscription PubSub listener links to and monitors the runtime. A runtime exit stops it (and pg drops its memberships); a listener crash crashes the runtime loudly instead of silently losing notifications.
- On `Shutdown` the runtime additionally kills its tracked effect processes and asks the listener to unsubscribe.

Effects that spawn their own processes inside `effect.from` are not tracked; use `effect.background` for work that should die with the session.

## Server-Side Effect Handler

Use `beacon.on_update` to attach server-only effects that run after update:

```gleam
beacon.app(init, init_local, beacon.no_server, update, view)
|> beacon.on_update(fn(state, msg) {
  let #(model, _local, _server) = state
  case msg {
    SaveItem(item) -> effect.from(fn(_) { db.save(item) })
    _ -> effect.none()
  }
})
|> beacon.start(8080)
```

This keeps `update` pure (compilable to JS) while server effects run only on the BEAM.
