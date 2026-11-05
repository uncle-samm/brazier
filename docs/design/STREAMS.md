# Design: Streams (Milestone 118)

Status: proposed design, not built. It is written for Sam and Modorra to
review before any code is written. It follows Phoenix LiveView's streams
(`stream/4`, `stream_insert/4`, `stream_delete/3`, `limit`, `reset`) and
adapts them to Brazier, where the browser renders the view from a decoded
model. Section 15 lists the decisions to make and the questions for Modorra.

LiveView references are to `phoenixframework/phoenix_live_view` at commit
`882655c` (1.3.0-dev). Brazier references are to this repository at
`4b1702b`.

## 1. What Modorra asked for

Modorra's request R1 (answered 2026-11-04) is an agent timeline: a few
hundred entries that grow at one end while agents work, with the output of
a running turn arriving in chunks.

- Items are keyed, for example `agent_id:seq`, and sent as ops: insert,
  update in place when the key exists, delete and reset.
- Items are not in the synced model, so the model diff never sees the
  window.
- Inserting an existing key updates that item in place. This covers
  chunked output: each chunk re-inserts the turn's entry.
- A `limit` of a few hundred trims the other end, on the client and, as a
  bound, on the server.
- There is no replay. After a reconnect the stream starts empty and `init`
  refills it. Modorra refetches from its last seq over HTTP.
- Work per update is bounded, and an op over the frame limit fails loudly.

## 2. Current state

Today a timeline must be a `List(Entry)` in the model.

- Every update encodes the whole model and diffs it against the cached
  snapshot (`broadcast_to` in `src/brazier/runtime.gleam`). The
  `runtime.list` bench shows the cost grows with the list: see
  [PERFORMANCE.md](../PERFORMANCE.md#scenarios).
- A chunk appended to one entry bumps the revision. A prepend or a trim at
  the front rewrites every index in the RFC 6902 ops, because the array
  diff has no shift detection (a separate Milestone 118 item).
- The browser re-renders the whole view and morphs every row on every
  patch (`renderNow` and `morphInnerHTML` in
  `brazier_client/src/brazier_client_ffi.mjs`).
- The server holds every entry for the life of the session, and so does
  the join token when state recovery is on.

`examples/ai_chat` keeps its streamed text in the model
(`streaming_text: String`), which is fine for one answer but not for a
window of hundreds.

## 3. LiveView's streams

What Brazier copies, with where it is in LiveView:

- **Declaration and ops.** `stream/4` (`lib/phoenix_live_view.ex` doc
  l.1847, definition l.2038), `stream_insert/4`, `stream_delete/3`,
  `stream_delete_by_dom_id/3`. `at: -1` appends, `at: 0` prepends.
  `reset: true` empties the container, or replaces its contents when
  items are given.
- **Update in place.** Inserting an id already in the container updates
  that item and keeps its position; `at` has no effect (l.2122, l.2158).
- **No items on the server.** Items are "freed from socket state
  immediately after the render/1 function is invoked" (l.1894).
  `LiveStream.prune/1` runs after render (`lib/phoenix_live_view/live_stream.ex`
  l.57). The stream keeps only queued inserts and deletes
  (`defstruct`, l.4).
- **Latest insert wins.** Inserts of one id in one render are de-duplicated
  by `reduce` (l.101, changelog 1.0.2, #3599).
- **Unknown stream.** An op on a stream never declared raises "no stream
  with name ... previously defined" (l.2303). Configuring a stream twice
  raises (l.2061).
- **Wire.** The comprehension carries
  `"stream": [ref, [[dom_id, at, limit, update_only], ...], [deleted_ids], reset?]`
  (`lib/phoenix_live_view/diff.ex`). Inserted items are sent as full
  renders. The client keeps no item trees (`assets/js/phoenix_live_view/rendered.js`).
- **Client order of work.** In `assets/js/phoenix_live_view/dom_patch.ts`:
  the stream inserts are indexed and a reset removes the stream's children
  (l.517 to l.530), then deletes run, then a join patch clears every stream
  container (l.535). A removed node whose id is inserted again in the same
  patch is stashed and restored by morphing, which keeps its identity,
  hooks and JS state (`removeStreamChildElement`, about l.686).
- **Existing items are not walked.** `skipFromChildren` (l.228) stops
  morphdom from indexing a stream container's children. An update morphs
  the item in place and does not move it. Only a new item, or every item
  on a reset, is positioned (`maybeReOrderStream`), with `moveBefore` when
  the browser has it (#4212).
- **Limit.** `maybeLimitStream` (l.783) runs after each positioned item:
  a negative limit removes from the front, a positive one from the end. An
  append to a container already at a positive limit removes the new item.
  The server never trims, and the limit must be passed on every insert
  (`lib/phoenix_live_view.ex` l.1880, l.1921 to l.1931).
- **Lessons from the changelog.** 0.20.4: never move an existing item, apply
  the limit to bulk inserts, run the reset before the inserts. 1.0.5: stream
  refs collided across nested views (#3681). 1.0.15: empty text nodes grew
  inside containers. `lib/phoenix_live_view/test/tree_dom.ex` applies
  streams without a DOM for `LiveViewTest`.

Where Brazier must differ:

- LiveView renders item HTML on the server. Brazier's view runs in the
  browser, and event handlers are client closures (decoders) in the
  compiled view, so server HTML would have no handler table. Brazier sends
  item data and renders it on the client with a template from the view.
- LiveView has one process per LiveView and per tab. Brazier has one
  runtime per WebSocket connection (see
  [ARCHITECTURE.md](../ARCHITECTURE.md)), so a reconnect is a new runtime
  and `init` runs again. That is what Modorra asked for.
- LiveView never trims on the server, so it cannot bound the client's
  window. Brazier's server keeps each stream's keys (not its items) and
  computes the trims itself (section 7.3).

## 4. Design in one page

1. A stream is declared once, as a typed handle: `stream.new("timeline",
   key:, encode:, decoder:, limit:)` returns `Stream(Entry)`. The name is a
   string literal, unique in the app; the build checks both.
2. `update` and `init` emit ops as effects: `stream.insert`,
   `stream.insert_many`, `stream.delete`, `stream.delete_key`,
   `stream.reset`. Each encodes its items when it is called.
3. The runtime takes the stream ops out of the update's effect before it
   broadcasts (they are data, not callbacks), applies them to the stream's
   key window, and sends the resulting delta in the same frame as the model
   change: a new required `streams` field on `patch` and `model_sync`. A
   stream-only update sends a `patch` with `"ops": []` at the current
   revision, which every client already treats as an ack.
4. The view places the stream with `stream.render(timeline(), "ol", attrs,
   render_entry)`. `render_entry` is a named `fn(Entry) -> Element(msg)`;
   the build refuses an anonymous function. An item renders from the item
   alone, as in LiveView.
5. The browser keeps a store per stream: the items in order, as parsed
   JSON, at most `limit` of them. The view's morph does not descend into a
   stream container. A stream applier patches the container from each
   frame's delta: deletes, then inserts at their final index. An update
   morphs the item in place.
6. The dead render (SSR) applies `init`'s and the route's stream ops to a
   throwaway store and renders the items into the HTML. The live mount runs
   `init` again; its ops go into the join's `model_sync`, and the first
   frame of each connection reconciles every container by key, so SSR nodes
   that are still in the stream keep their identity.
7. A new connection starts with empty stores. There is no replay buffer.

## 5. API

All of this is proposed. A new module `brazier/stream` is added to the
client allowlist (`client_modules` in `src/brazier/build/analyzer.gleam`),
because the view calls `stream.render` and the handle function.

### 5.1 Declaration

<!-- docs-check: fragment proposed API, not built yet -->
```gleam
/// A keyed stream of items of one type. Opaque.
pub opaque type Stream(item)

/// Which end a full stream keeps. `KeepLast(300)` drops the oldest items
/// at the front when an append goes over 300 (LiveView `limit: -300`).
/// `KeepFirst(300)` drops from the end (LiveView `limit: 300`).
pub type Limit {
  KeepFirst(Int)
  KeepLast(Int)
}

/// Declare a stream. Crashes, as `attribute.attribute` does for a bad
/// name, when:
/// - `name` is not 1 to 64 characters of `a-z`, `0-9` and `_`, starting
///   with a letter;
/// - the limit is below 1 or above `max_limit`.
pub fn new(
  name: String,
  key key: fn(item) -> String,
  encode encode: fn(item) -> json.Json,
  decoder decoder: decode.Decoder(item),
  limit limit: Limit,
) -> Stream(item)

/// The largest limit a stream may have.
pub const max_limit = 1000
```

An app declares each stream in one `pub fn`, so `update` and `view` share
it:

<!-- docs-check: fragment proposed API, not built yet -->
```gleam
import brazier/stream.{type Stream}
import gleam/dynamic/decode
import gleam/int
import gleam/json

pub type Entry {
  Entry(agent_id: String, seq: Int, text: String, done: Bool)
}

pub fn timeline() -> Stream(Entry) {
  stream.new(
    "timeline",
    key: fn(entry: Entry) { entry.agent_id <> ":" <> int.to_string(entry.seq) },
    encode: encode_entry,
    decoder: entry_decoder(),
    limit: stream.KeepLast(300),
  )
}

pub fn encode_entry(entry: Entry) -> json.Json {
  json.object([
    #("agent_id", json.string(entry.agent_id)),
    #("seq", json.int(entry.seq)),
    #("text", json.string(entry.text)),
    #("done", json.bool(entry.done)),
  ])
}

pub fn entry_decoder() -> decode.Decoder(Entry) {
  use agent_id <- decode.field("agent_id", decode.string)
  use seq <- decode.field("seq", decode.int)
  use text <- decode.field("text", decode.string)
  use done <- decode.field("done", decode.bool)
  decode.success(Entry(agent_id:, seq:, text:, done:))
}
```

The codec is explicit, as `presence.new(name, encode, decoder)` takes one
(`src/brazier/presence.gleam`). Section 14 says why a generated codec is
not proposed for the first version, and decision D1 asks.

The limit is part of the declaration, not of each insert. LiveView's limit
must be repeated on every `stream_insert`, and forgetting it is a known
mistake (`lib/phoenix_live_view.ex` l.1880). Here both the server and the
client know it from the handle, and the wire carries it so a store can be
bounded before its container is rendered.

### 5.2 Ops

<!-- docs-check: fragment proposed API, not built yet -->
```gleam
/// Where a new item goes. An existing key stays where it is.
pub type Position {
  Append
  Prepend
}

/// Insert an item, or update it in place when its key is in the stream.
pub fn insert(stream: Stream(item), item: item, at position: Position) -> Effect(msg)

/// Insert several items in order: `Append` keeps the list's order at the
/// end, `Prepend` puts the list's first item first.
pub fn insert_many(
  stream: Stream(item),
  items: List(item),
  at position: Position,
) -> Effect(msg)

/// Delete the item with this item's key. A key not in the stream is
/// logged at warning and sends nothing.
pub fn delete(stream: Stream(item), item: item) -> Effect(msg)

/// Delete by key (LiveView `stream_delete_by_dom_id/3`).
pub fn delete_key(stream: Stream(item), key: String) -> Effect(msg)

/// Empty the stream, then insert `items` in order. `reset(s, [])` empties it.
pub fn reset(stream: Stream(item), items: List(item)) -> Effect(msg)
```

Each op calls `key` and `encode` when it is called, so the effect holds the
item's JSON text, not the item. A key that is empty or over
`max_key_bytes` (256) crashes there, in `update`, as a bad attribute
crashes in `view`.

Ops are effects because effects are already the data `update` returns:

- they compose with `effect.batch`, and `effect.map` passes them through
  unchanged, so a child module's ops reach its parent (see
  [COMPONENTS.md](../COMPONENTS.md));
- an effect's work (a timer, a `background` process reading an agent's
  output) emits ops the way it changes the model: it dispatches a message,
  and that message's `update` returns `stream.insert`;
- `effect.keyed` and `effect.cancellable` wrap callbacks that run later.
  A stream op is applied when its update returns, so it is never keyed or
  cancelled. The op is taken out of any wrapper, and the docs say so.

Modorra's chunked output, with the turn's entry keyed `agent_id:seq`:

<!-- docs-check: fragment proposed API, not built yet -->
```gleam
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // Each chunk re-inserts the whole entry; the existing key is updated
    // in place and keeps its position.
    ChunkArrived(entry) -> #(
      model,
      stream.insert(timeline(), entry, at: stream.Append),
    )
    TurnStarted(agent_id) -> #(
      Model(..model, running: [agent_id, ..model.running]),
      effect.none(),
    )
  }
}
```

### 5.3 View

<!-- docs-check: fragment proposed API, not built yet -->
```gleam
/// The stream's container: a `tag` element holding the stream's items, in
/// order, each rendered by `item` and keyed by the stream's key.
pub fn render(
  stream: Stream(item),
  tag: String,
  attributes: List(Attribute(msg)),
  item: fn(item) -> Element(msg),
) -> Element(msg)
```

<!-- docs-check: fragment proposed API, not built yet -->
```gleam
pub fn view(model: Model) -> Element(Msg) {
  html.main([], [
    html.h1([], [html.text(int.to_string(list.length(model.running)) <> " running")]),
    stream.render(timeline(), "ol", [attribute.class("timeline")], render_entry),
  ])
}

pub fn render_entry(entry: Entry) -> Element(Msg) {
  html.li([attribute.classes([#("done", entry.done)])], [
    html.span([], [html.text(entry.agent_id)]),
    html.pre([], [html.text(entry.text)]),
    html.button([event.on_click(Retry(entry.agent_id, entry.seq))], [
      html.text("Retry"),
    ]),
  ])
}
```

Rules, each checked:

- `item` must be a reference to a named top-level function (`render_entry`
  or `module.render_entry`), not an anonymous `fn` or a capture such as
  `render_entry(_, model.selected)`. The build refuses anything else and
  names the place. Reason: the applier renders an item only when it is
  inserted or updated, so an item cannot depend on the model or Local
  state. LiveView behaves the same way (items render from the assigns at
  insert time); here the build makes it visible. State that changes how
  every item looks (a selection, a filter) goes on the container's
  attributes and CSS, or the app re-inserts the affected items.
- `item` must return one element. A text node, `element.none()`,
  `unsafe_raw_html` or `element.keyed` at the item root is an error: the
  stream sets the root's key itself.
- A stream is rendered at most once per view, and never inside another
  stream's item.
- `stream.render` in a `brazier.simple` app is a build error: a simple app
  has no effects, so it can never fill a stream.

`stream.render` builds a new `render.Node` variant in
`src/brazier/internal/render.gleam`:

<!-- docs-check: fragment proposed API, not built yet -->
```gleam
Stream(
  name: String,
  limit: stream.Limit,
  tag: String,
  attrs: List(Attr(msg)),
  // Decode one item's JSON and render it. `element.map` composes onto it.
  item: fn(Dynamic) -> Result(Node(msg), String),
)
```

`map_node` composes the message mapping onto `item`, so a child module's
stream works through `element.map`.

### 5.4 Test helpers

<!-- docs-check: fragment proposed API, not built yet -->
```gleam
/// One stream op an effect carries, for app unit tests.
pub type Emitted {
  Inserted(stream: String, key: String, json: String, at: Position)
  Deleted(stream: String, key: String)
  Reset(stream: String, items: List(#(String, String)))
}

/// The stream ops in an effect, in the order they are applied.
pub fn emitted(effect: Effect(msg)) -> List(Emitted)

/// Encode `item` and decode it again with the stream's decoder, so a test
/// can check the explicit codec.
pub fn round_trip(stream: Stream(item), item: item) -> Result(item, String)
```

## 6. Wire

### 6.1 Frames

`patch` and `model_sync` gain a required field `streams`: an array with
one entry per stream the frame changes, in no particular order. A frame
that changes no stream carries `"streams": []`. The field is required, as
`ack_clock` is, so a missing one is a protocol error and is never read as
"no change".

Each entry:

| Field | Type | Meaning |
|-------|------|---------|
| `name` | string | The stream's declared name |
| `keep` | `"first"` or `"last"` | The limit's end |
| `limit` | integer, 1 to 1000 | The limit |
| `reset` | boolean | Empty the stream before the deletes and inserts |
| `deletes` | array of keys | Keys to remove, trims included |
| `inserts` | array of `{key, at, item}` | `at` is the item's index in the stream after this entry; `item` is the encoded item, embedded as JSON |

An event that appends a chunk and changes the model:

```json
{"type": "patch",
 "ops": [{"op": "replace", "path": "/running/0", "value": "agent-2"}],
 "version": 8, "ack_clock": 3,
 "streams": [
   {"name": "timeline", "keep": "last", "limit": 300, "reset": false,
    "deletes": ["agent-1:12"],
    "inserts": [
      {"key": "agent-2:40", "at": 299,
       "item": {"agent_id": "agent-2", "seq": 40, "text": "Reading the file", "done": false}}
    ]}
 ]}
```

The same append when the model does not change. The revision does not
move, so this is an ack at the current revision, and every connection gets
it, not only the one whose event caused it:

```json
{"type": "patch", "ops": [], "version": 8, "ack_clock": 3,
 "streams": [
   {"name": "timeline", "keep": "last", "limit": 300, "reset": false,
    "deletes": [],
    "inserts": [
      {"key": "agent-2:40", "at": 299,
       "item": {"agent_id": "agent-2", "seq": 40, "text": "Reading the file twice", "done": false}}
    ]}
 ]}
```

The join. `init` filled the stream before the connection joined; the
`model_sync` resets every stream `init` touched:

```json
{"type": "model_sync", "model": {"running": []}, "version": 0, "ack_clock": 0,
 "streams": [
   {"name": "timeline", "keep": "last", "limit": 300, "reset": true,
    "deletes": [],
    "inserts": [
      {"key": "agent-1:11", "at": 0, "item": {"agent_id": "agent-1", "seq": 11, "text": "Done", "done": true}},
      {"key": "agent-1:12", "at": 1, "item": {"agent_id": "agent-1", "seq": 12, "text": "Planning", "done": true}}
    ]}
 ]}
```

A `model_sync` that answers `request_sync` carries `"streams": []`. A
resync restores the model only; the stores are not part of it.

The server embeds each item's JSON in the frame as it is, as it embeds
`model` and `ops` (see [WIRE_PROTOCOL.md](../WIRE_PROTOCOL.md#server-messages-server-to-browser)).
Each item was produced by the stream's `encode` through `gleam/json`, so it
is valid JSON.

### 6.2 Client rules

The `streams` field is applied before the model part of the frame, under
every model verdict of `classifyPatch` (apply, ack, stale, gap) and while a
frame is held for a pending prediction (`shouldHoldServerState`). Stream
deltas are not versioned: the socket orders them, and each is applied
exactly once, in arrival order. A stale or held model does not make a
stream delta stale.

| Condition | Action |
|-----------|--------|
| `streams` missing or not an array | Stream fault |
| An entry with a missing field, a wrong type, or an unknown `name` | Stream fault |
| `keep` or `limit` differs from the store's or the container's | Stream fault |
| A delete of a key not in the store | Stream fault |
| An insert whose `at` is not the index it lands at, or a new key whose `at` is past the end | Stream fault |
| The store would hold more than `limit` items after the entry | Stream fault |
| An item that does not decode, or that `render_item` refuses for any other reason (only when it is rendered) | Stream fault (`item_render_failed`) |
| Otherwise | Apply to the store; patch every rendered container of that stream |

The rows are checked in this order, and an entry is checked against its
store before its rendered container, so a fault names the first row it
hits (the shared vectors in `test/fixtures/stream_vectors.json` fix the
order). Every entry of a frame is checked before any store changes: a
fault leaves the stores and the containers as they were, and the frame's
model part is not applied. Entries for one name in one frame apply in
order.

A **stream fault** means the store can no longer be trusted, and a
`request_sync` cannot repair it. The client logs a `console.error` naming
the stream and the reason, and closes the socket with 4000
`stream fault`, as it does when a join cannot be written
(`sendJoin`). Frames that arrive on that socket after the fault are
ignored with a warning, without relying on the browser dropping them.
That close reconnects with backoff; the new runtime runs
`init`, which refills every stream. An app bug that faults every time (a
decoder that does not match its encoder) is therefore a reconnect loop held
to one attempt per `RECONNECT_MAX_MS`, the same as an `init` that crashes
(see [WIRE_PROTOCOL.md](../WIRE_PROTOCOL.md#close-codes)). The dead render
decodes every item too, so such a codec usually fails there first.

The server checks everything in this table before it sends, so a fault
means a framework bug, a frame from another build, or an app codec bug.

### 6.3 Wire break

This is a wire break. Proposed CHANGELOG entry, for the coordinator to
write:

> **Wire break:** `patch` and `model_sync` carry a required `streams` array
> (LiveView-style streams, `brazier/stream`). A client from before this
> change ignores it and never shows stream items; a server from before it
> sends no `streams`, which this client treats as a protocol error. The
> build id check (4409 `stale build`) reloads pages across the change.

## 7. Server

### 7.1 Taking ops out of effects

`brazier/effect` gets a new private `Callback` variant,
`StreamCallback(op: stream_op.Op)`, where `brazier/internal/stream_op`
holds `Op(name, limit, action)` and the action is `Insert(key, json, at)`,
`Delete(key)` or `Reset(List(#(key, json)))`. `effect.map`, `keyed` and
`cancellable` pass it through. An `@internal` function splits an effect:

<!-- docs-check: fragment proposed API, not built yet -->
```gleam
@internal
pub fn take_stream_ops(effect: Effect(msg)) -> #(List(stream_op.Op), Effect(msg))
```

`run_update_for` in `src/brazier/runtime.gleam` broadcasts the model
before it runs the effects. The split happens first, so the ops ride in the
same frame as the model change:

1. `update` returns `#(model, effect)`.
2. `take_stream_ops` splits off the ops, in order.
3. The ops are applied to the session's windows (7.3), producing one entry
   per stream.
4. `broadcast_model` sends the patch, the ack or the `model_sync` with
   those entries. When the model did not change and an entry is not empty,
   it sends an ack-shaped patch (`"ops": []` at the current revision, each
   connection's own `ack_clock`) to every joined connection.
5. The other callbacks run, as today.

`run_update_only`, which handles an `event_batch`, keeps the ops of every
event in the batch, and the batch's one broadcast carries them, in order.

### 7.2 Before the first join

`init` and the route message run in the actor's initialiser, before any
connection has joined (`spawn_actor`), and messages their effects dispatch
can run before the join too. Ops from that time cannot be sent. The
runtime keeps them in the windows with their item JSON, at most `limit`
items per stream. The first `accept_join` sends every non-empty window as a
`reset: true` entry in the join's `model_sync`, then drops the item JSON;
from then on a window holds keys only. This is the only time the server
holds items, and it is bounded by `limit` and the item size limit.

A second join on the same connection (the server's "Rejoin ... full
resync" path in `handle_join`) has no items to send again. The browser
client never sends one: it sends `join` once per socket, in `onopen`. The
runtime logs that rejoin at warning when a window is not empty, and its
`model_sync` carries `"streams": []`.

### 7.3 Windows and deltas

The runtime keeps one window per stream: the keys in order, at most
`limit`, and the limit the stream was first used with. It does not keep
items, as LiveView frees them after render.

For each update, per stream, the runtime applies the ops one by one to a
copy of the window:

- `Insert` of a key in the window updates it in place (its position does
  not change). Of a new key, it puts it at the front or the end, then
  trims the other end to `limit`. With `KeepLast`, a `Prepend` into a full
  window trims the new item itself; with `KeepFirst`, so does an `Append`.
  That matches LiveView's `maybeLimitStream`.
- `Delete` removes the key. A key not in the window is logged at warning
  and changes nothing.
- `Reset` empties the window and inserts its items at the end, in order,
  with the same trimming.

Then it diffs the old window `W` against the new one `W2`:

- `reset` is true when a `Reset` ran;
- `deletes` are the keys of `W` not in `W2`, plus keys that moved (deleted
  and inserted again in the same update);
- `inserts` are the keys of `W2` that are new, moved or updated, each with
  its index in `W2` and its latest JSON, in ascending index order.

Keys that were not touched keep their order, so a client that applies the
deletes and then the inserts in ascending index order ends with `W2`: when
it inserts the key at index `i`, every key before `i` in `W2` is already
in place. An item inserted and then trimmed or deleted in the same update
is never sent. This is LiveView's "latest insert wins" (`reduce`, 1.0.2)
and its bulk-limit fix (0.20.4), applied on the server.

The client still enforces the limit: it checks that a store never holds
more than `limit` items and faults if it does. It does not compute trims
itself. One side computes them, so the two cannot disagree.

Correction (step 5): the session's windows validate every op, and each
joined connection also has windows of its own, of the keys its client was
sent (`brazier/internal/stream_session`). A connection that joins after
the first starts with no window and is sent no items (no replay), so the
entries each connection is sent, and their `at` indices, are computed
against its own windows. A connection's windows are dropped when it
disconnects, and emptied when its join `model_sync` was not sent.

### 7.4 Bounds

| Bound (`SecurityLimits` field) | Default | When it is exceeded |
|-------|-------|---------------------|
| `stream_max_limit` | 1000, and at most 1000 | the op is refused (`limit_out_of_range`) |
| `stream_key_max_bytes` | 256; an empty key is refused too | the op is refused (`key_too_large`, `key_empty`) |
| `stream_item_max_bytes` | 65_536 | the op is refused (`item_too_large`) |
| `stream_ops_max_per_update` | 1000 ops, all streams together | every op of the update is refused (`too_many_ops`) |
| `stream_frame_max_bytes` | 1_048_576 of stream entries per frame | every op of the update is refused (`frame_too_large`) |

`stream.new` crashes only for a limit below 1 or a bad name.

Work per update is O(ops × limit) for the windows, at most
1000 × 1000 key comparisons, and the delta is at most `limit` deletes and
`limit` inserts per stream. The client's work per frame is bounded by the
same numbers.

A refused op is not applied to the window, so the window still equals what
the client holds. The runtime logs an error naming the stream, the size and
the limit, emits `[brazier, stream, refused]`, and sends
`{"type": "error", "reason": "Stream log: refused 1 op(s): the item is 70013 bytes, over the limit of 65536"}`
to the joined connections, one per stream and reason, as it does for a
model over `model_size_max_bytes` (`model_too_large`). An update refused
whole sends one `error` beginning "Refused every stream op of the update".
The model part of the update is sent as usual. When the first join's
entries (7.2) are over `stream_frame_max_bytes`, every window is emptied,
because the client then holds nothing.

Correction (step 5): these bounds are `SecurityLimits` fields
(`transport.stream_limits` reads them), validated as the other fields are:
each must be positive, and `stream_max_limit` at most 1000, the largest
limit the wire and the client accept. An earlier draft made them
constants; decision D4 set the defaults above.

### 7.5 Unknown streams and duplicate declarations

The build records every declared stream name and puts the list in the
generated server codec (`brazier_codec`) and the client entry. At run time:

- An op on a name not in the list is refused with reason `unknown_stream`.
  With the build check this can only be a stream declared outside the
  app's modules, such as in a dependency.
- The first op on a stream fixes the window's limit. An op with another
  limit under the same name is refused with reason `limit_mismatch`.

### 7.6 SSR

`ssr.gleam` runs `init` and the route message and drops their effects. It
will take the stream ops out first (`take_stream_ops`), apply them to fresh
windows that keep their items, and pass the items to the render. The
render decodes each item with the stream's decoder and renders it with the
stream's item function, keyed, so the HTML holds the same items the join
will send. A decode failure there crashes the dead render, which serves the
500 page: an encoder and a decoder that do not agree fail on the first page
load, before any socket opens. The windows are then dropped. The other
effects are still dropped, as today.

The live mount runs `init` again, as it does for the model, so its data
fetch runs twice per page load. That is LiveView's `mount` behaviour too.

## 8. Client

### 8.1 Stores and rendering

The client keeps a `Map` from stream name to a store: `keep`, `limit`, the
keys in order, and per key the parsed item JSON
(`brazier_client/src/brazier_client/stream.mjs`). A store is created by
the first entry for its name. Stores for streams whose container is not
rendered are kept and bounded like any other. What is rendered from a store
belongs to its container's view, not to the store: the item element and the
handler table of each key. So the items a reconnect leaves on the page stay
clickable while the stores are empty.

The client's `render(model, local)` renders a `Stream` node as the
container's opening and closing tags, with `data-brazier-stream="<name>"`
and no children, and lists the node in a table of containers next to the
handler table: `render` returns `#(html, handlers, containers)`. The
runtime reads a container with `container_name`, `container_keep`,
`container_limit` and `container_item`, and renders one item with
`render_item(container, key, item)`, which returns the item's HTML and
handler table or an error. `container_item` is the item function itself,
compared by reference only and never called, so the runtime can tell when
the same element now renders its items with another function. Two
`element.map` wrappers around one item function compare equal. `morphChildren` treats an element with
`data-brazier-stream` like one with `data-brazier-preserve-children`
(`attribute.ignore_updates`): it morphs the container's own attributes and
does not descend. This is LiveView's `skipFromChildren`.

After every render, and after every frame that changes a store, the
stream applier visits each container in the table:

- **A container that is new in the DOM**, one whose item function
  changed, or any container on the first frame of a connection (the first
  `patch` or `model_sync` it receives, which is the join's `model_sync`):
  full reconcile. Every child whose key is not in the store is
  removed (its hooks unmounted). Every key in the store is placed in
  order; a child that already has that key is kept and morphed, so it keeps
  its identity, focus and hook state. This is the join path of
  `dom_patch.ts`. The reconcile works from the children on the page, so it
  also repairs a container that a fault left half patched. An element that
  the page morph turns into a container loses its page children first: a
  child is adopted as an item only when it was rendered as one.
- **An existing container**: apply the frame's entry only. A reset removes
  every child. Deletes remove their children. Each insert of a new key
  renders the item and inserts it at `at`; each insert of an existing key
  renders the item and morphs the child in place without moving it; a
  moved key was deleted first and is restored from the stash. Moves use
  `moveBefore` when the browser has it.

Rendering an item decodes its JSON with the node's `item` function. There
is no cache of the rendered HTML: an item renders when it is inserted or
updated, and every item of a container renders again on a full reconcile.
An insert or update renders that item only, which is what a cache would
save on the hot path; the build's guarantee that `item` depends on the item
only is what makes the item's markup independent of its position.

Rendering stays synchronous, as `renderNow` is today: the model render and
the stream patch of one frame happen in the same task, so the browser
never paints a model without its items.

### 8.2 Handler ids inside items

Handler ids are positional (`walk` in `src/brazier/internal/render.gleam`
numbers every child). Inside an item, an id is relative to the item's root
and starts with `i`: `data-brazier-on-click="i0.2"`. The client resolves
it by walking up to the closest element with `data-brazier-key` whose
parent has `data-brazier-stream`, and looks the id up in that item's
handler table. An id is an item id only when it matches
`i<n>(.<n>)*` exactly; an item id outside any item is an error and the
event is dropped. Throttle and debounce are kept per stream, key and id,
since every item repeats its ids. So:

- a prepend does not change the attributes of any other item;
- an item's markup is the same wherever the item moves;
- pre-hydration event replay records `(stream, key, id)` and finds the
  same item after the join, or drops the event with a warning when the
  join removed it.

Messages built in an item function are reached from `view`, so they are in
the server's message allowlist like any other (see
[SECURITY.md](../SECURITY.md#events-from-the-browser)).

### 8.3 Reconnect and build id

`connect()` empties every store and marks the next frame with a `streams`
field (the join's `model_sync`) as the connection's first frame. Until it arrives, the containers keep showing
the old items. The join's `model_sync` then reconciles every container:
items `init` sent again keep their nodes, the rest are removed. This is
LiveView's rejoin, where items `mount` does not send again are cleared.

A page from another build is closed with 4409 `stale build` before it
joins, so an item decoder in the bundle always matches the server that
sends it. Streams need nothing more there. The contract report
(`src/brazier/build/contract.gleam`) lists the declared streams with their
item types.

## 9. Interactions

- **`element.keyed`.** The stream sets each item root's
  `data-brazier-key` to the stream key. `element.keyed` inside an item
  works as usual among its siblings. A keyed item root is an error (5.3).
- **Hooks inside items.** An inserted item's hooks mount, an item morphed
  in place gets `update` when a watched attribute changes
  (`attribute.watch`), and a deleted, trimmed or reset item's hooks
  unmount (`unmountSubtree`). That is LiveView's `mounted`, `updated` and
  `destroyed` for stream items.
- **Model sync.** Items are not in the model, so the diff, the revision,
  `request_sync` and the join token never see them. A resync does not
  touch the stores. State recovery (`with_state_recovery`) does not carry
  streams; `init` refills them.
- **Components.** A child module renders its stream through
  `element.map`, and its ops reach the parent through `effect.map`. Stream
  names are global to the app and checked unique by the build, which
  avoids LiveView's cross-view ref collision (#3681). A child module
  rendered twice cannot have a stream per instance in the first version
  (question Q4).
- **Routes.** A stream belongs to the runtime, not to a route. A route
  change that shows another agent's timeline resets the stream in the
  route message's `update`, as a LiveView resets in `handle_params`.
- **Local state and `simple` apps.** Items cannot read Local state (5.3).
  A `simple` app's `update`, which the browser also runs for predictions,
  has no effects, so it can emit no ops.
- **Pre-hydration events.** See 8.2.

## 10. Build

- `brazier/stream` joins `client_modules` in
  `src/brazier/build/analyzer.gleam`.
- The analyzer finds every `stream.new` call in the app's modules,
  resolving the import alias as `reach` does. The name must be a string
  literal; a name declared twice is a build error naming both places.
- `reach` checks the fourth argument of every `stream.render` in code the
  client runs: it must be a function reference. An anonymous `fn` or a
  capture is a build error naming the place.
- `stream.render` in a `brazier.simple` app's view is a build error.
- `server_codec` and `client_entry` emit the list of stream names (a new
  `stream_names` export) for the checks in 6.2 and 7.5.

## 11. Telemetry

| Event | Measurements | Metadata | Emitted |
|-------|--------------|----------|---------|
| `[brazier, stream, delta]` | `inserts`, `updates`, `deletes`, `trimmed`, `bytes` | `stream`, `reset`, `connection_id` | once per stream per frame sent, `brazier/runtime` |
| `[brazier, stream, refused]` | `count`, `bytes` | `stream`, `reason`: `item_too_large`, `too_many_ops`, `frame_too_large`, `unknown_stream`, `limit_mismatch`, `limit_out_of_range`, `key_empty` or `key_too_large` | `brazier/runtime` |
| `[brazier, runtime, render]` S | adds `stream_bytes` (stop) | unchanged | `brazier/runtime` |

Keys and items are never in metadata: a key such as `agent_id:seq` can
identify a user (see [TELEMETRY.md](../TELEMETRY.md#privacy)).

Logs: an info line when a stream's first op arrives (name, limit), debug
per delta (counts only), warning for a delete of an unknown key and for a
rejoin with non-empty windows, error for every refusal. The browser logs a
`console.error` per stream fault and per view error.

## 12. Error cases

| Case | Where it is caught | What happens |
|------|--------------------|--------------|
| Unknown stream: op on a name the build did not declare | runtime | Refused, `unknown_stream`, error log, `error` frame |
| Unknown stream: wire entry with a name not in the bundle | browser | Stream fault, reconnect |
| Duplicate declaration: two `stream.new` with one name | build | Build error naming both places |
| Same name used with two limits at run time | runtime | Refused, `limit_mismatch` |
| A stream rendered twice in one view | render | SSR crashes the dead render (500); the browser's render throws, which takes the existing render-failure path |
| Limit 0 or negative | `stream.new` | Crash with a message |
| Limit over `stream_max_limit` | runtime | That op refused, `limit_out_of_range` |
| Empty or over-long key | runtime | That op refused, `key_empty` or `key_too_large` |
| Item over `item_max_bytes` | runtime | That op refused, error log, `error` frame; the rest of the update is sent |
| More ops than `ops_max_per_update`, or stream entries over `frame_max_bytes` | runtime | Every op of the update refused; the model part is sent |
| Ops for a stream not in the current view | browser | Not an error: the store keeps them, bounded by the limit, and the container is filled by a full reconcile when it appears |
| Delete of a key not in the stream | runtime | Warning, nothing sent |
| An item function that is anonymous or a capture | build | Build error naming the place |
| Item root that is not one element, or a stream inside an item | render | SSR crash; in the browser `render_item` returns an error, which is a stream fault (`item_render_failed`) |
| Item that does not decode | SSR, browser | SSR crash (500); browser stream fault |
| A malformed `streams` field | browser | Stream fault |

## 13. Testing

Following [TESTING.md](../TESTING.md). Unhappy paths first.

**Unit (Gleam).**

- `brazier/stream`: every crash in `new` and in the ops; `emitted` and
  `round_trip`; `effect.map`, `batch`, `keyed` and `cancellable` keep ops
  in order.
- The window module: each rule in 7.3, both limits, both positions,
  update in place, trims of the new item, deletes of unknown keys, resets.
  A generated property: for random op sequences, applying the emitted delta
  to `W` equals applying the ops one by one.
- Runtime (`runtime_test`): ops ride the same patch as the model change; a
  stream-only update sends an ack-shaped patch to every joined connection;
  an `event_batch` keeps ops in order; ops before the first join arrive in
  the join's `model_sync` as resets, and the items are then dropped;
  every refusal, with `log_capture` and a telemetry handler; a rejoin.
- SSR: items in the HTML, keyed, with item-relative handler ids; a decode
  failure crashes the dead render.
- Build (`build_analyzer_test`): a non-literal name, a duplicate name, an
  anonymous item function, a capture, a stream in a `simple` app, the
  allowlist.

**Shared vectors.** A `stream_vectors` table of windows, op lists and the
expected deltas, read by the Gleam tests and by a node script that runs the
browser's applier on them, as `patch_vectors.mjs` and `sync_vectors.mjs`
check `patch.gleam` against `patch.mjs`.

**Client harness** (`brazier_client/test/ffi_harness.mjs`, fake socket and
fake DOM):

- every stream-fault row of 6.2 closes with 4000 `stream fault` and
  reconnects;
- a delta is applied under each model verdict: stale, gap, ack and held;
- an update in place keeps the node object, and a move restores it;
- hooks mount on insert, update on a watched change, and unmount on
  delete, trim and reset;
- a container that appears later is filled; one rendered twice throws;
- reconnect empties the stores and the join reconciles the old DOM;
- item handlers dispatch by `(key, id)`; pre-hydration replay on SSR
  items, and on an item the join removed.

**Simulation** (`brazier/sim`): a `stream(n)` scenario where each
connection appends n chunks and checks every frame's delta against its own
window; `assert_all_clean` as for the others.

**CDP.** A new example, `examples/timeline`, added to the canonical set in
[CONFORMANCE.md](../CONFORMANCE.md): agents append entries and stream chunks
into them. The test checks:

- the SSR items are the nodes the live page keeps (a property set on a node
  before the join survives);
- an update in place keeps focus and the text selection in the item;
- the limit trims at 300;
- a hook in each item mounts and unmounts the right number of times;
- killing the socket shows the old items until the rejoin, then the items
  `init` sends.

## 14. Rejected alternatives

- **Items in the model, with array shift detection.** The diff would still
  encode and compare the whole window per update, the revision would bump
  per chunk, and the view would re-render every row. Shift detection is
  worth doing for ordinary lists and is its own Milestone 118 item.
- **Server-rendered item HTML, as LiveView sends.** Brazier's event
  handlers are client closures in the compiled view. Server HTML would need
  a second handler scheme, and the server would run the view per item,
  which it never does after the dead render.
- **Item functions that may close over the model.** Every model change
  would have to re-render every item, which is the cost streams exist to
  avoid, or cached items would silently show old state. The build check
  makes the LiveView rule explicit instead.
- **The whole window in the client's HTML string, morphed as keyed
  children.** Simple, and the morph already moves keyed nodes. But every
  frame, including a model change unrelated to the stream, would build and
  morph all items: O(window) work per frame instead of O(delta).
- **A separate `stream` frame.** It keeps `patch` untouched, but two frames
  are two tasks, so the browser can paint the model change without its
  items, and the join needs a rule to keep SSR items until the second
  frame arrives. LiveView sends streams inside the diff, in one frame.
- **Trimming on the client only, as LiveView does.** The server could not
  bound the client's window, could not drop bulk inserts that will be
  trimmed, and would need the limit on every insert. With the server's key
  window the trims are computed once.
- **Keeping items on the server for replay.** Modorra asked for no replay
  and refetches over HTTP. Items would cost `limit` × item size per
  connection for the life of the session. The server keeps items only
  until the first join (7.2).
- **A generated item codec**, like the Model's. The ops would carry items
  of many types through one runtime, so the item would have to be erased to
  `Dynamic` and matched to a generated encoder by name; user code cannot
  import `brazier_codec`, which imports the user's modules. The explicit
  codec follows `presence.new`, needs no new codegen, and the dead render
  checks it on every page load. D1 asks whether to generate it later.
- **Stream ops through a process dictionary, as `router.push` finds its
  connections.** The op would run as a callback after the broadcast and
  arrive in a second frame. Taking the ops out of the effect keeps them in
  the update's frame and keeps them visible to `stream.emitted` in tests.
- **`update_only`** (LiveView 1.1.0-rc.0). Modorra's first chunk creates the
  entry and later chunks update it, which `insert` covers. Q2 asks.

## 15. Implementation order

1. `brazier/internal/stream_op` and the window module with its delta, plus
   the shared vectors. Pure, no wire.
2. `brazier/stream` (declaration, ops, test helpers) and the effect
   variant with `take_stream_ops`.
3. Render node, SSR, and the item-relative handler ids, with SSR tests.
4. Build checks and the allowlist, the `stream_names` exports, the
   contract report.
5. Runtime: windows, pre-join items, bounds, telemetry; the `streams` field
   in `transport.SendPatch` and `SendModelSync`.
6. Client: stores, applier, faults, reconnect; the harness and vectors.
7. `examples/timeline` and its CDP test; the benches; docs
   (a `STREAMS.md` user guide, `WIRE_PROTOCOL.md`, `TELEMETRY.md`,
   `HTML_ELEMENTS.md`), and the CHANGELOG wire break.

## 16. Bench

Added to the suite in [PERFORMANCE.md](../PERFORMANCE.md#scenarios), each
checking what it times:

- `runtime.stream.append`: a runtime actor with a full `KeepLast(300)`
  stream of 1 KB items; each event appends one item (one insert, one trim).
  Compared with `runtime.list` at a model list of the same size, which is
  the cost streams replace. The check: each frame's delta is one delete and
  one insert at index 299.
- `runtime.stream.chunk`: each event re-inserts the last item with 100
  more bytes of text. The check: one update at index 299, no deletes.
- `wire.stream_patch`: a patch frame carrying one 1 KB insert, encoded as
  `send_ws_message` hands it to `gen_tcp:send/2`.
- `ssr.stream_300`: the dead render of a page with a 300-item stream.
- `client.stream.append.300` and `client.stream.chunk.300`, in node like
  `client.patch.rows_1000`: the store update and item render for one frame,
  without the DOM. The check: the item HTML equals the server's for the
  same item.

The DOM work (insert, morph of one item) needs a browser and is measured
over CDP in the timeline example, not gated.

## 17. Decisions and questions

**For Sam:**

- **D1. Item codec.** Explicit `encode` and `decoder` on `stream.new`
  (proposed, as `presence.new`), or a generated codec later? Generated
  needs items erased to `Dynamic` in the effect and a name-keyed encoder
  table in `brazier_codec`.
- **D2. Item functions must be named.** The build refuses closures, so
  items never depend on the model (proposed). The alternative re-renders
  every item when the model changes.
- **D3. Stream fault means reconnect** (close 4000 `stream fault`), which
  can loop with backoff on an app codec bug. The alternative is to log and
  leave the stream wrong until the next reconnect, which is the silent
  degradation the engineering rules forbid.
- **D4. Numbers.** `max_limit` 1000, `item_max_bytes` 64 KB,
  `ops_max_per_update` 1000, `frame_max_bytes` 1 MB, `max_key_bytes` 256.
  Constants, or `SecurityLimits` fields?
- **D5. `streams` is required on every `patch` and `model_sync`**, as
  `ack_clock` is, at 14 bytes per frame (`,"streams":[]`). The alternative
  is to omit it when empty.
- **D6. The server keeps each stream's keys** and computes the trims; the
  client checks the limit but does not trim. LiveView trims only on the
  client.
- **D7. Decode on the server too?** Each op could decode its JSON again
  with the stream's decoder, so a codec mismatch fails in `update` instead
  of the browser. It doubles the codec work per op. Proposed: no; the dead
  render and `stream.round_trip` catch it.

**For Modorra:**

- **Q1. Positions.** Is `Append` and `Prepend` enough, or do you need an
  index (`at: 3`) or "after this key"?
- **Q2. `update_only`.** Do you need an insert that only updates, and does
  nothing when the key has been trimmed? Today a late chunk for a trimmed
  entry would insert it again at the end.
- **Q3. Items and the model.** An item renders from the item alone. Do any
  timeline entries need model state (a selected agent, a filter), and is a
  container attribute plus CSS, or re-inserting the affected entries,
  acceptable?
- **Q4. One timeline or several.** Is one stream per page enough, or do
  you render a child module with its own stream more than once (one per
  agent)? That needs per-instance stream names, which the first version
  does not have.
- **Q5. Sizes.** What is the largest entry in bytes, and the largest
  `init` refill? A reset of 300 entries must fit in 1 MB.
- **Q6. Refill on reconnect.** The stream starts empty and `init` refills
  it; the old items stay on screen until the join. Is a refill that runs
  in `init` (before the join, sent in the join's `model_sync`) the shape
  you want, or will you refill from an effect after the join?
