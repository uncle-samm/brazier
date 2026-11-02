# State Management

Each Beacon session has three state layers, plus cross-user stores:

- **Model** — server-authoritative UI state. Synced to the client and drives
  the rendered view.
- **Local** — client-only, per-tab state. Lives in the browser, is never sent
  to the server, and costs zero network traffic.
- **Server** — private, per-session state. Lives on the server only and is
  never serialized to the client.
- **Shared stores** — cross-user state shared by all connections (see below).

`update` always receives `(model, local, server, msg)` and returns
`#(model, local, server)`.

## Model (Server-Authoritative)

Each browser tab gets its own BEAM process holding the Model. Updates go
through the server, which re-renders and syncs the Model to the client.

```gleam
beacon.app(init, beacon.no_local, beacon.no_server, update, view) |> beacon.start(8080)
```

## Local State (Zero Traffic)

Split state into Model (server-synced) and Local (instant, no network).
Messages that only change Local run in the browser with no round trip.

```gleam
beacon.app(init, init_local, beacon.no_server, update, view) |> beacon.start(8080)
```

## Server State (Private)

Per-session state that stays on the server and is never sent to the client —
use it for secrets, tokens, and bookkeeping the browser must not see.

```gleam
beacon.app(init, beacon.no_local, init_server, update, view) |> beacon.start(8080)
```

## Shared State (Store)

ETS-backed stores visible to all connections. Auto-broadcasts via PubSub on mutation.

```gleam
import beacon/store
let s = store.new("settings")       // Create (or reuse) the store
store.put(s, "theme", "dark")       // Set (auto-broadcasts)
store.get(s, "theme")               // Ok("dark")
store.delete(s, "theme")            // Remove (auto-broadcasts)
```

Creation is **idempotent**: `store.new("settings")` called again -- from any
process, at any time -- returns a handle to the same data. The backing ETS
tables are owned by a long-lived Beacon table-owner process, not by the
caller, so a store created inside a request handler, a runtime or `init`
survives that process exiting.

Store names are developer-chosen constants: 1-255 bytes of `[A-Za-z0-9_-]`
(they become ETS table atoms; never derive a name from user input).
`store.new` / `store.new_list` log and crash loudly on an invalid name; use
`store.try_new` / `store.try_new_list` to get a typed
`Result(_, store.StoreError)` instead:

```gleam
case store.try_new(name) {
  Ok(s) -> use_store(s)
  Error(err) -> log.error("app", state_manager.describe_ets_error(err))
}
```

A `Store` and a `ListStore` with the same name are separate tables, but they
share the PubSub topic `"store:" <> name`.

### List Store

Any number of values per key (ETS `duplicate_bag`). Good for chat messages
and logs: appending the same value twice stores it twice, and `get_all`
returns values in insertion order.

```gleam
let msgs = store.new_list("messages")
store.append(msgs, "room1", msg)           // Add value
store.get_all(msgs, "room1")               // All values for key, oldest first
store.append_many(msgs, "room1", [a, b])   // Bulk insert, broadcasts once
store.delete_all(msgs, "room1")            // Remove all for key
store.append_notify(msgs, room_id, msg, "room:")  // Also broadcasts to "room:{room_id}"
```

### Reacting to Store Changes

Mutations broadcast `Nil` on the store's topic. Subscribe to it with
`beacon.subscriptions` and re-read the store in the handler:

```gleam
let messages = store.new_list("messages")

beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.subscriptions(fn(_model) { [store.list_topic(messages)] })
|> beacon.on_notify(fn(_topic) { MessagesChanged })
|> beacon.start(8080)
```

## PubSub

Low-level publish/subscribe using Erlang `pg` (works across distributed nodes).

```gleam
import beacon/pubsub
pubsub.subscribe("chat:lobby")
pubsub.broadcast("chat:lobby", Nil)
pubsub.unsubscribe("chat:lobby")
```

## Dynamic Subscriptions

Subscribe to topics derived from the model. The framework diffs subscriptions after each update.

```gleam
beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.subscriptions(fn(model) { ["room:" <> model.current_room] })
|> beacon.on_notify(fn(topic) { RoomUpdated(topic) })
|> beacon.start(8080)
```

When `model.current_room` changes, the old topic is unsubscribed and the new one subscribed automatically.

## Computed Fields

Public functions with the signature `fn(Model) -> T` are automatically detected as computed fields. Their values are calculated server-side on each update and included in `model_sync` messages sent to the client.

- Computed values are derived, never stored — recalculated after every model change
- Supported return types: `Int`, `String`, `Float`, `Bool`
- No attribute needed — detection is by function signature

```gleam
pub fn total(model: Model) -> Int {
  model.price * model.qty
}
```

The client receives `total` alongside the model fields, but it is never part of the `Model` type itself.

## Cross-Route State Sharing

Wrap the store in a function and call it from multiple routes -- because
creation is idempotent, every call returns the same store. Use
`beacon.subscriptions` with `store.topic(shared.cart())` in each route to
react to changes:

```gleam
pub fn cart() { store.new("cart") }  // in shared.gleam
// Route A: store.put(shared.cart(), "items", new_items)
// Route B: store.get(shared.cart(), "items")
```
