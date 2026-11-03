# Effects

Effects are descriptions of side effects that the Beacon runtime executes. Following Lustre's design, effects are data -- not actions. The `Effect(msg)` type is opaque and composed via combinators.

## Where Effects Come From

`beacon.application` and `beacon.full_application` return effects from
`init` and `update`, as Lustre's `application` does. Both functions run only
on the server, so an effect may use stores, PubSub, HTTP, the environment,
randomness and any other BEAM-only code.

```gleam
fn init(_ctx: beacon.Context) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model(loading: True, items: []), effect.background(fn(dispatch) {
    dispatch(ItemsLoaded(load_items()))
  })))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ItemsLoaded(items) -> #(Model(loading: False, items:), effect.none())
    Save(item) -> #(model, effect.from(fn(_dispatch) { db.save(item) }))
  }
}

pub fn main() {
  beacon.application(init:, update:, view:)
  |> beacon.start(8080)
}
```

`beacon.simple` has no effects: its `update` is also compiled to JavaScript
and runs in the browser. Use `application` as soon as an update needs
server-only work.

`init` runs twice per page, as LiveView's mount does. On the HTML render
(`beacon.is_connected(ctx)` is False) Beacon drops the returned effect. When
the WebSocket connects, it runs `init` again and performs the effect. A
startup effect therefore runs once per connected session, not once per HTTP
request.

Beacon performs an effect after the update that returned it and after the
new model is sent to the browser.

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

## Navigation Effects

`beacon/router` returns navigation as effects (LiveView's `push_patch`,
`push_navigate` and `redirect`):

- **`router.push(path)`**: change the URL and add a history entry without
  reloading. The app's `on_change` then runs for the new route, as for a link
  click.
- **`router.replace(path)`**: the same, replacing the current history entry.
- **`router.redirect(url)`**: a full page load. It ends the session. Use it
  when the browser must make a real HTTP request, for example to receive a
  `Set-Cookie` header.

All three take same-origin paths only (`/` but not `//`). Any other value is
logged as an error and not sent.

```gleam
fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    LoggedIn -> #(model, router.push("/dashboard"))
    LoggedOut -> #(model, router.redirect("/login"))
    _ -> #(model, effect.none())
  }
}
```

## Child Modules

A parent that nests a child module maps the child's effects into its own
message type with `effect.map`, as it maps the child's view with
`element.map`. See [COMPONENTS.md](COMPONENTS.md).
