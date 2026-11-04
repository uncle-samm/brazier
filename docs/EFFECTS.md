# Effects

Effects are descriptions of side effects that the Brazier runtime executes. Following Lustre's design, effects are data -- not actions. The `Effect(msg)` type is opaque and composed via combinators.

## Where Effects Come From

`brazier.application` and `brazier.full_application` return effects from
`init` and `update`, as Lustre's `application` does. Both functions run only
on the server, so an effect may use stores, PubSub, HTTP, the environment,
randomness and any other BEAM-only code.

```gleam
import brazier
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import gleam/list

pub type Model {
  Model(loading: Bool, items: List(String))
}

pub type Msg {
  ItemsLoaded(List(String))
  Save(String)
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(
    Model(loading: True, items: []),
    effect.background(fn(dispatch) { dispatch(ItemsLoaded(load_items())) }),
  ))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ItemsLoaded(items) -> #(Model(loading: False, items:), effect.none())
    Save(item) -> #(model, effect.from(fn(_dispatch) { save_item(item) }))
  }
}

fn view(model: Model) -> Element(Msg) {
  html.ul(
    [],
    list.map(model.items, fn(item) {
      html.li([event.on_click(Save(item))], [html.text(item)])
    }),
  )
}

pub fn main() {
  brazier.application(init:, update:, view:)
  |> brazier.start(8080)
}

// The app's own database calls.
fn load_items() -> List(String) {
  ["first", "second"]
}

fn save_item(_item: String) -> Nil {
  Nil
}
```

`brazier.simple` has no effects: its `update` is also compiled to JavaScript
and runs in the browser. Use `application` as soon as an update needs
server-only work.

`init` runs twice per page, as LiveView's mount does. On the HTML render
(`brazier.is_connected(ctx)` is False) Brazier drops the returned effect. When
the WebSocket connects, it runs `init` again and performs the effect. A
startup effect therefore runs once per connected session, not once per HTTP
request.

Brazier performs an effect after the update that returned it and after the
new model is sent to the browser.

## Core Functions

**`effect.none()`** -- No side effect. Use when update only changes the model.

**`effect.from(fn(dispatch) { ... })`** -- One-shot synchronous effect. The callback runs in the runtime process and receives a `dispatch` function to send messages back to the update loop.

**`effect.background(fn(dispatch) { ... })`** -- Runs the callback in a separate BEAM process. Does not block the update loop. Use for database queries, HTTP calls, or other I/O. At most 32 workers (`effect.max_background_processes`) can be alive per runtime; one more is rejected (its callback never runs) with a warning log and `[brazier, effect, background, rejected]`. A finished worker frees its slot.

**`effect.every(interval_ms, fn() { Msg })`** -- Periodic timer that dispatches the message every `interval_ms` milliseconds (re-armed with `erlang:send_after` each tick, like LiveView's `Process.send_after`). Capped at 10 concurrent timers per runtime (`effect.max_timers`); additional timers are rejected with a warning and `[brazier, effect, timer, rejected]`, and no process is started. `interval_ms < 1` is rejected with an error log. Each un-keyed call starts a NEW timer -- key it to replace instead (see below).

**`effect.after(delay_ms, fn() { Msg })`** -- Delayed one-shot. Dispatches the message once after `delay_ms` milliseconds. No process is started: the timer is an `erlang:send_after` into the runtime's own mailbox (LiveView's `Process.send_after(self(), ...)`), and the `fn() { Msg }` runs in the runtime process when it fires, just before the message reaches `update`. At most 100 timers (`effect.max_after_timers`) can be pending per runtime; one more is rejected with a warning log and `[brazier, effect, after, rejected]`. A negative delay is rejected with an error log.

**`effect.batch([effect1, effect2])`** -- Combine multiple effects. All callbacks execute with no ordering guarantees between them.

**`effect.map(effect, fn(a) -> b)`** -- Transform the message type. Used internally for component composition.

**`effect.keyed(key, effect)`** -- Tag an effect with a stable key. Messages from an older generation of the same key are dropped by the runtime. For `background`, `every` and `after` the key is also single-flight: performing a keyed effect first stops the process, or cancels the pending `after` timer, previously started under that key. Re-keying a timer therefore replaces it and never consumes an extra timer slot:

<!-- docs-check: wrap
import brazier/effect.{type Effect}

pub type Msg {
  Poll
}

pub fn poller() -> Effect(Msg) {
  {{block}}
}
-->
```gleam
// Restarting the poller on every filter change keeps exactly one timer.
effect.keyed("poll", effect.every(5000, fn() { Poll }))
```

**`effect.cancellable(effect)` / `effect.cancel(token)`** -- Generate a unique key for an effect and return a token. Cancelling drops any later messages from that effect and stops its process or cancels its `after` timer. A cancelled `after` whose message was already in the mailbox (`erlang:cancel_timer` cannot recall it) is dropped when it arrives.

### Limits

Every limit is per runtime, so one session cannot exhaust the node:

| Effect | Limit | Over the limit |
|--------|-------|----------------|
| `background` | 32 live workers (`effect.max_background_processes`) | warning log, `[brazier, effect, background, rejected]`, the callback never runs |
| `every` | 10 live timers (`effect.max_timers`) | warning log, `[brazier, effect, timer, rejected]`, no timer |
| `after` | 100 pending timers (`effect.max_after_timers`) | warning log, `[brazier, effect, after, rejected]`, no timer |

A rejected effect dispatches nothing; it is not queued or retried. Key a recurring effect so each new one replaces the last instead of adding up.

## Process Lifecycle

`background` workers, `every` timers and `after` timers are owned by the runtime that performed them and never outlive it:

- An `every` timer is a process that monitors the runtime and stops on its `DOWN`, whatever the exit reason (normal shutdown, crash or kill).
- An `after` timer is not a process. It is an `erlang:send_after` to the runtime itself, which the VM cancels when the runtime exits.
- A `background` worker runs arbitrary code and so cannot watch its owner itself. A small guardian process is started first: it monitors the runtime, then starts the worker linked to itself, and kills it when the runtime exits. There is no moment when the worker runs unwatched. The guardian exits as soon as the worker finishes.
- The dynamic-subscription PubSub listener links to and monitors the runtime. A runtime exit stops it (and pg drops its memberships); a listener crash crashes the runtime loudly instead of silently losing notifications.
- On `Shutdown` the runtime additionally kills its live effect processes, cancels its pending `after` timers and asks the listener to unsubscribe.

Effects that spawn their own processes inside `effect.from` are not tracked; use `effect.background` for work that should die with the session.

## Navigation Effects

`brazier/router` returns navigation as effects (LiveView's `push_patch`,
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

<!-- docs-check: wrap
import brazier/effect.{type Effect}
import brazier/router

pub type Model {
  Model
}

pub type Msg {
  LoggedIn
  LoggedOut
  Refresh
}

{{block}}
-->
```gleam
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
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
