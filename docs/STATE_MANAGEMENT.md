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

State that must outlive a page load, such as who is signed in, belongs in a
cookie session from `beacon/session`: the cookie holds only an id, and the
data stays in a server-side store (`LocalEts` on one node, or `External`
functions you supply for a cluster). See
[GETTING_STARTED.md](GETTING_STARTED.md#session-auth) and
[SECURITY.md](SECURITY.md). `beacon.session_id(ctx)` gives `init` a stable
id for the browser session, for keying a store.

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

<!-- docs-check: wrap
import beacon
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import gleam/int

pub fn main() {
  {{block}}
}

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

fn init(_ctx: beacon.Context) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model(count: 0), effect.none()))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Increment -> #(Model(count: model.count + 1), effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  element.text(int.to_string(model.count))
}
-->
```gleam
beacon.application(init:, update:, view:)
|> beacon.start(8080)
```

## Server State (Private)

With `full_application`, `update` works on a `state` that the browser never
sees. `sync(state) -> model` runs after every update and chooses what is
sent; secrets, tokens and bookkeeping stay in the state.

<!-- docs-check: wrap
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

fn init(_ctx: beacon.Context) -> Result(#(Session, Effect(Msg)), beacon.InitError) {
  Ok(#(Session(model: Model(count: 0), api_key: "loaded on the server"), effect.none()))
}

fn update(session: Session, msg: Msg) -> #(Session, Effect(Msg)) {
  case msg {
    Increment -> #(
      Session(..session, model: Model(count: session.model.count + 1)),
      effect.none(),
    )
  }
}

fn view(model: Model, _local: Nil) -> Element(Msg) {
  element.text(int.to_string(model.count))
}

{{block}}
-->
```gleam
import beacon
import beacon/local

pub type Session {
  Session(model: Model, api_key: String)
}

fn sync(session: Session) -> Model {
  session.model
}

pub fn main() {
  beacon.full_application(init:, update:, sync:, local: local.none(), view:)
  |> beacon.start(8080)
}
```

### Recovering state after a reconnect

When a browser reconnects and a new server process serves it (after a
restart, or on another node), `init` runs again for it. `beacon.with_state_recovery(restore:)` replaces the state
`init` returned: the page carries the model in its signed join token, and
`restore(model)` returns the state. Anything that is not in the model must be
rebuilt or reloaded by `restore`. For `simple` and `application`, where the
state is the model, pass `function.identity`.

- The token is signed with the app's secret key. Recovery after a restart or
  on another node needs the same `beacon.secret_key` on every node (see
  [DEPLOYMENT.md](DEPLOYMENT.md#secret-key)).
- The join token is checked before `init` runs. A token that does not verify
  (malformed, signed with another key, older than 24 hours, or issued to
  another browser session), a token whose model `restore` cannot decode, and
  a missing token while recovery is enabled refuse the connection. The
  refusal is logged as a warning, the WebSocket closes with **4400**, and the
  browser reloads the page, whose server render issues a fresh token (at most
  3 reloads per tab within 60 seconds, then the page shows an error state).
  The session never continues from `init`'s state in place of a token it
  could not use. LiveView does the same with a stale session token: it
  refuses the join and the client reloads.
- An open tab whose server was restarted without a fixed `beacon.secret_key`
  therefore reloads once on reconnect: the new process generated a new key.
- Recovery with an empty secret key is a configuration error: the runtime
  refuses to start.
- Without `with_state_recovery` the session starts from `init`. A missing
  token is then fine, but a token that does not verify still refuses the
  connection the same way.

## Local State (Zero Traffic)

`local.layer(init:, update:)` adds state that lives only in the browser.
Its `update` runs in the browser for every event: `local.handled(local)`
keeps the message in the browser (no traffic), and `local.forward(local)`
also sends it to the server. `view` receives the model and the local state.

<!-- docs-check: wrap
import beacon
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/local
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Local {
  Local(menu_open: Bool)
}

pub type Msg {
  Increment
  ToggleMenu
}

fn init(_ctx: beacon.Context) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model(count: 0), effect.none()))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Increment -> #(Model(count: model.count + 1), effect.none())
    ToggleMenu -> #(model, effect.none())
  }
}

fn sync(model: Model) -> Model {
  model
}

fn init_local(_model: Model) -> Local {
  Local(menu_open: False)
}

fn update_local(_model: Model, local: Local, msg: Msg) -> local.Update(Local) {
  case msg {
    ToggleMenu -> local.handled(Local(menu_open: !local.menu_open))
    Increment -> local.forward(local)
  }
}

fn view(model: Model, _local: Local) -> Element(Msg) {
  element.text(int.to_string(model.count))
}

pub fn main() {
  {{block}}
}
-->
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

pub fn theme_round_trip() -> Result(String, Nil) {
  let s = store.new("settings")       // create (or reuse) the store
  store.put(s, "theme", "dark")       // set (broadcasts)
  let theme = store.get(s, "theme")   // Ok("dark")
  store.delete(s, "theme")            // remove (broadcasts)
  theme
}
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

Under `beacon.start` the table owner is the first child of the application's
supervision tree, so a restart of PubSub, the session scope or the listener
never touches store data. A store created in `main` before `beacon.start`
keeps its contents: the tree's owner adopts the table. `application.stop`
deletes every local store's table, so a store handle from before the stop
must not be used after it (it crashes with `badarg`). If the owner itself
crashes while it owns tables, their data is gone: Beacon does not restart it
with empty tables but stops the application loudly, and creating a store on
that node fails with `TableOwnerUnavailable` until the application starts
again. See [ARCHITECTURE.md](ARCHITECTURE.md#supervision-applicationgleam).

Store names are developer-chosen constants: 1-255 bytes of `[A-Za-z0-9_-]`
(they become ETS table atoms; never derive a name from user input).
`store.new` / `store.new_list` log and crash loudly on an invalid name; use
`store.try_new` / `store.try_new_list` to get a
`Result(_, store.StoreError)` instead:

<!-- docs-check: wrap
import beacon/log
import beacon/store
import gleam/string

pub fn open_named(name: String) -> Nil {
  {{block}}
}

fn use_store(s: store.Store(String)) -> Nil {
  store.put(s, "opened", "yes")
}
-->
```gleam
case store.try_new(name) {
  Ok(s) -> use_store(s)
  Error(err) -> log.error("app", "store " <> name <> ": " <> string.inspect(err))
}
```

`store.StoreError` is an alias of a type in an internal module, so an app
cannot name its constructors (an invalid name, a table that exists with the
other type, or a table owner that could not create the table) without
importing that module.

A `Store` and a `ListStore` with the same name are separate tables, but they
share the PubSub topic `"store:" <> name`.

### List Store

Any number of values per key (ETS `duplicate_bag`). Good for chat messages
and logs: appending the same value twice stores it twice, and `get_all`
returns values in insertion order.

<!-- docs-check: wrap
import beacon/store

pub fn chat(room_id: String, msg: String, a: String, b: String) -> List(String) {
  {{block}}
  history
}
-->
```gleam
let msgs = store.new_list("messages")
store.append(msgs, "room1", msg)                  // add a value
let history = store.get_all(msgs, "room1")        // all values for the key, oldest first
store.append_many(msgs, "room1", [a, b])          // bulk insert, broadcasts once
store.delete_all(msgs, "room1")                   // remove every value for the key
store.append_notify(msgs, room_id, msg, "room:")  // also broadcasts to "room:" <> room_id
```

### Reacting to Store Changes

Mutations broadcast `Nil` on the store's topic. Subscribe to it with
`beacon.subscriptions` and re-read the store in the handler:

<!-- docs-check: wrap
import beacon
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/store
import gleam/int

pub type Model {
  Model(message_count: Int)
}

pub type Msg {
  MessagesChanged
}

fn init(_ctx: beacon.Context) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model(message_count: 0), effect.none()))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    MessagesChanged -> #(model, effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  element.text(int.to_string(model.message_count))
}

pub fn main() {
  {{block}}
}
-->
```gleam
let messages: store.ListStore(String) = store.new_list("messages")

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
import gleam/result

pub fn open_shared() -> Result(store.ListStore(String), store.OpenError) {
  use settings <- result.try(
    store.open("settings", store.Replicated(replicated.default_config())),
  )
  store.put(settings, "theme", "dark")   // applied here, then replicated

  store.open_list(
    "chat",
    store.Replicated(
      replicated.Config(..replicated.default_config(), max_entries: 50_000),
    ),
  )
}
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

pub fn lobby() -> Nil {
  pubsub.subscribe("chat:lobby")
  pubsub.broadcast("chat:lobby", Nil)
  pubsub.unsubscribe("chat:lobby")
}
```

## Dynamic Subscriptions

`beacon.subscriptions(fn(state) -> List(String))` computes the session's
topics from its state after every update. Beacon diffs the list against the
previous one and subscribes or unsubscribes as needed.

<!-- docs-check: wrap
import beacon
import beacon/effect.{type Effect}
import beacon/element.{type Element}

pub type Model {
  Model(current_room: String)
}

pub type Msg {
  RoomUpdated(String)
}

fn init(_ctx: beacon.Context) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model(current_room: "lobby"), effect.none()))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RoomUpdated(_topic) -> #(model, effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  element.text(model.current_room)
}

pub fn main() {
  {{block}}
}
-->
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
`beacon/presence/sync`) applies it to the list the session keeps.
`beacon.watch_presence(tracker:, watch:, on_presence:)` gets the same
messages for the topics `watch` returns without tracking the session. See
[CLUSTERING.md](CLUSTERING.md#session-presence).

## Cross-Route State Sharing

Every route of a `with_router` app runs in the same session, so the
session's state is already shared between routes. Between sessions, wrap
the store in a function and call it from every route: creation is
idempotent, so every call returns the same store. Subscribe to
`store.topic(shared.cart())` to react to changes:

<!-- docs-check: module shared -->
```gleam
// shared.gleam
import beacon/store

pub fn cart() -> store.Store(List(String)) {
  store.new("cart")
}

// Route A: store.put(shared.cart(), "items", new_items)
// Route B: store.get(shared.cart(), "items")
```
