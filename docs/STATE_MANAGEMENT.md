# State Management

A Beacon session keeps its state in up to three layers, and sessions share
state through stores and PubSub:

- **Model**: what the browser sees. The server sends it to the browser, and
  `view` renders it.
- **Server state**: the session's full state, which stays on the server.
  With `full_application` it can be larger than the model; `sync(state)`
  chooses the model.
- **Local state**: per-tab state in the browser, never sent to the server.
- **Stores, PubSub and presence**: state shared by every session (see
  below).

Pick the constructor by the layers the app needs (the full table is in
[GETTING_STARTED.md](GETTING_STARTED.md#three-constructors)):

| Constructor | Server state | Local state |
|---|---|---|
| `beacon.simple(init:, update:, view:)` | The model itself | None |
| `beacon.application(init:, update:, view:)` | The model itself | None |
| `beacon.full_application(init:, update:, sync:, local:, view:)` | Any `state`; `sync` derives the model | `local.layer(..)` or `local.none()` |

## Model (Server-Authoritative)

Each browser tab gets its own BEAM process holding the session's state.
Events go to the server, which runs `update`, re-renders and sends the
browser what changed. With `simple` the browser also runs `update` at once,
and the server's model wins when the two differ.

```gleam
beacon.application(init:, update:, view:)
|> beacon.start(8080)
```

## Server State (Private)

With `full_application`, `update` works on a `state` that the browser never
sees. `sync(state) -> model` runs after every update and chooses what is
sent; secrets, tokens and bookkeeping stay in the state.

```gleam
pub type Session {
  Session(model: Model, api_key: String)
}

fn sync(session: Session) -> Model {
  session.model
}

beacon.full_application(init:, update:, sync:, local: local.none(), view:)
|> beacon.start(8080)
```

After a reconnect to a new server process, `beacon.with_state_recovery(restore:)`
rebuilds the state: the page carries the model in its signed join token, and
`restore(model)` returns the state. Anything that is not in the model must
be rebuilt or reloaded by `restore`.

## Local State (Zero Traffic)

`local.layer(init:, update:)` adds state that lives only in the browser.
Its `update` runs in the browser for every event: `local.handled(local)`
keeps the message in the browser (no traffic), and `local.forward(local)`
also sends it to the server. `view` receives the model and the local state.

```gleam
beacon.full_application(
  init:,
  update:,
  sync:,
  local: local.layer(init: init_local, update: update_local),
  view:,
)
|> beacon.start(8080)
```

`examples/counter_local` is a complete app with a local layer.

## Shared State (Store)

ETS-backed stores visible to all connections. Auto-broadcasts via PubSub on mutation.

```gleam
import beacon/store
let s = store.new("settings")       // Create (or reuse) the store
store.put(s, "theme", "dark")       // Set (auto-broadcasts)
store.get(s, "theme")               // Ok("dark")
store.delete(s, "theme")            // Remove (auto-broadcasts)
```

`store.new` and `store.new_list` open a **local** store: each node has its
own table, and change notifications reach watchers on that node only. For a
store whose contents every node shares, open it in replicated mode (see
[Replicated stores](#replicated-stores) below).

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

beacon.application(init:, update:, view:)
|> beacon.subscriptions(fn(_model) { [store.list_topic(messages)] })
|> beacon.on_notify(fn(_topic) { MessagesChanged })
|> beacon.start(8080)
```

Write to a store from an effect, so the write runs on the server and never
in the browser's copy of `update`.

### Replicated stores

A replicated store keeps a full replica on every node that opens it, and
the replicas converge. Open it with `store.open` or `store.open_list` and
the `Replicated` mode. Every other call (`get`, `put`, `append`,
`get_all`, `topic`, ...) is the same as for a local store.

```gleam
import beacon/store
import beacon/store/replicated

let assert Ok(settings) =
  store.open("settings", store.Replicated(replicated.default_config()))
store.put(settings, "theme", "dark")   // applied here, then replicated

let assert Ok(chat) =
  store.open_list("chat", store.Replicated(
    replicated.Config(..replicated.default_config(), max_entries: 50_000),
  ))
```

- **Opt-in.** `Local` is the default mode, and `store.new` / `new_list`
  always open local stores. A name is open in one mode only: opening a
  local store's name as replicated (or the reverse) returns
  `Error(InvalidConfig(_))`, and so does reopening with a different
  configuration. Every node must open the store with the same
  configuration.
- **Names** are 1 to 200 bytes of `[A-Za-z0-9_-]`.
- **Reads stay on the node.** Each replica mirrors its state into ETS, so
  `get`, `get_all` and `count` read locally. They crash the caller loudly
  (after logging) while this node's replica is restarting.
- **Writes can fail.** A replicated write fails when it would pass a limit
  (`TooManyEntries`, `ValueTooLarge`, `DeltaTooLarge`) or when the local
  replica is down (`Unavailable`). `put`, `delete`, `append`, ... log and
  crash the caller. `try_put`, `try_delete`, `try_append`, ... return
  `Result(Nil, store.WriteError)` instead, for callers that handle it.
- **Conflicts.** Concurrent writes of one key resolve the same way on every
  node: the latest hybrid-logical-clock timestamp wins, with the node name
  as tiebreak. A delete never removes a value written concurrently on
  another node (add wins).
- **List order.** A replicated list store returns values in timestamp
  order. For writes from one node, that is insertion order.
- **Notifications.** Watchers on every node are notified on the store's
  topic when a change reaches their node, whether the write was local or
  remote. `append_notify` topics are announced on every node too.

Replication, anti-entropy, limits and failure behaviour are described in
[CLUSTERING.md](CLUSTERING.md#replicated-stores).

## PubSub

Low-level publish/subscribe, a port of Phoenix.PubSub over Erlang `pg`.
`broadcast` reaches subscribers on every connected node; `local_broadcast`
reaches this node only. See [CLUSTERING.md](CLUSTERING.md#pubsub-across-nodes)
for what a cluster needs and what happens during a netsplit.

```gleam
import beacon/pubsub
pubsub.subscribe("chat:lobby")
pubsub.broadcast("chat:lobby", Nil)
pubsub.unsubscribe("chat:lobby")
```

## Dynamic Subscriptions

`beacon.subscriptions(fn(state) -> List(String))` computes the session's
topics from its state after every update. Beacon diffs the list against the
previous one and subscribes or unsubscribes as needed.

```gleam
beacon.application(init:, update:, view:)
|> beacon.subscriptions(fn(model) { ["room:" <> model.current_room] })
|> beacon.on_notify(fn(topic) { RoomUpdated(topic) })
|> beacon.start(8080)
```

When `model.current_room` changes, the old topic is unsubscribed and the
new one subscribed.

- `beacon.on_notify(fn(topic) -> msg)` turns every notification into a
  message, by topic.
- `beacon.broadcast(topic)` notifies subscribers without a store write.
- `beacon.broadcast_payload(topic, payload)` sends a value with the
  notification. Read it with `beacon.on_notification(fn(Notification) ->
  msg)` and `beacon.notification_payload(notification, decoder)`, which
  returns an `Error` when the payload does not decode.

## Presence

`beacon.presence(tracker:, track:, on_presence:)` tracks which sessions are
on a topic, on every node, from each session's state. Every join and leave
arrives as an `on_presence(diff)` message, and `sync.merge` (from
`beacon/presence/sync`) applies it to the list the session keeps. See
[CLUSTERING.md](CLUSTERING.md#session-presence).

## Cross-Route State Sharing

Every route of a `with_router` app runs in the same session, so the
session's state is already shared between routes. Between sessions, wrap
the store in a function and call it from every route: creation is
idempotent, so every call returns the same store. Subscribe to
`store.topic(shared.cart())` to react to changes:

```gleam
pub fn cart() { store.new("cart") }  // in shared.gleam
// Route A: store.put(shared.cart(), "items", new_items)
// Route B: store.get(shared.cart(), "items")
```
