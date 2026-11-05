# Streams

A stream is a keyed list of items that the server sends once and does not
keep: a chat log, a feed, an agent's output. `update` returns ops that
insert, update, move, delete or reset items; the runtime sends each change
in the same frame as the model change, and the browser keeps the items, at
most the stream's limit of them. It is LiveView's `stream/4`, with the
limit in the declaration and the item function checked by the build.

Use a stream when the list grows without bound, or when its items are large
and change one at a time. A list in the model costs its whole size on the
server for every session, and its diff grows with it; a stream costs the
server its keys only, at most `limit` of them per connection.

A list the view filters, sorts or counts belongs in the model: the server
does not have a stream's items, and an item renders from the item alone.

`examples/timeline` is the complete app: an agent's steps in a
`KeepLast(20)` stream, with every op, an item hook and the browser checks
listed in [CONFORMANCE.md](CONFORMANCE.md#timeline-contract). The design,
with the wire format and the reasons, is
[design/STREAMS.md](design/STREAMS.md).

## Declaring a stream

Declare each stream once, in a `pub fn`, so `init`, `update` and `view`
share it. The codec is explicit, as for presence:

<!-- docs-check: module streams_guide/steps -->
```gleam
import brazier/stream.{type Stream}
import gleam/dynamic/decode
import gleam/int
import gleam/json

pub type Step {
  Step(agent: String, seq: Int, text: String, done: Bool)
}

pub fn steps() -> Stream(Step) {
  stream.new(
    "steps",
    key: step_key,
    encode: encode_step,
    decoder: step_decoder(),
    limit: stream.KeepLast(300),
  )
}

pub fn step_key(step: Step) -> String {
  step.agent <> ":" <> int.to_string(step.seq)
}

pub fn encode_step(step: Step) -> json.Json {
  json.object([
    #("agent", json.string(step.agent)),
    #("seq", json.int(step.seq)),
    #("text", json.string(step.text)),
    #("done", json.bool(step.done)),
  ])
}

pub fn step_decoder() -> decode.Decoder(Step) {
  use agent <- decode.field("agent", decode.string)
  use seq <- decode.field("seq", decode.int)
  use text <- decode.field("text", decode.string)
  use done <- decode.field("done", decode.bool)
  decode.success(Step(agent:, seq:, text:, done:))
}
```

- The name is a string literal of 1 to 64 characters of `a-z`, `0-9` and
  `_`, starting with a letter, and unique in the app. The build refuses a
  name that is not a literal and a name declared twice, naming both places;
  `stream.new` crashes on a bad name.
- The key identifies an item in the stream and in the page
  (`data-brazier-key`). It must be 1 to 256 bytes.
- `decoder` runs in the browser, on the item JSON `encode` produced.
  `stream.round_trip` checks that the two agree (see [Testing](#testing)).
- `limit` is the most items the browser keeps; see [Limits](#limits).

## Ops

Each op is an `Effect(msg)`. It calls `key` and `encode` when it is
called, so the effect holds the item's key and JSON text, not the item.

| Op | What it does |
|----|--------------|
| `stream.insert(s, item, at: stream.Append)` | A new key goes at the end (`Prepend`: the front). A key already in the stream is updated in place and keeps its position |
| `stream.insert_many(s, items, at:)` | `Append` keeps the list's order at the end; `Prepend` puts the list's first item first. A key twice in `items` is one insert, at its first place, with its last item |
| `stream.delete(s, item)` | Removes the item with `item`'s key. A key not in the stream changes nothing; the runtime logs it at warning |
| `stream.delete_key(s, key)` | The same, by key |
| `stream.reset(s, items)` | Empties the stream, then appends `items` in order. `reset(s, [])` empties it |

A delete and an insert of the same key in one update is a move: the item
goes to its new place and keeps its DOM node, its focus and its hooks.

Ops compose with `effect.batch`, in order, and `effect.map` passes them
through, so a child module's ops reach its parent (see
[COMPONENTS.md](COMPONENTS.md)). `effect.keyed` and `effect.cancellable`
do not key or cancel them: an op is applied when the update that returned
it returns. Work that runs later, such as a timer or a `background`
process reading an agent's output, dispatches a message, and that
message's `update` returns the op (see [EFFECTS.md](EFFECTS.md)).

`init` fills the stream the same way. Its ops reach the browser in the
join's `model_sync`, and the server holds those items, at most `limit` per
stream, only until that first join.

An agent's output, re-inserting the step as each chunk arrives:

<!-- docs-check: wrap
import brazier
import brazier/effect.{type Effect}
import brazier/stream
import streams_guide/steps.{type Step, Step}

pub type Model {
  Model(running: Int)
}

pub type Msg {
  Started(Step)
  ChunkArrived(Step)
  Finished(Step)
  MovedToTop(Step)
  Dismissed(String)
  Cleared
}

{{block}}
-->
```gleam
pub fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  let first = Step(agent: "planner", seq: 1, text: "Read the task", done: True)
  Ok(#(Model(running: 0), stream.insert_many(steps.steps(), [first], at: stream.Append)))
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Started(step) -> #(
      Model(running: model.running + 1),
      stream.insert(steps.steps(), step, at: stream.Append),
    )
    // The key is in the stream, so the step is updated where it is.
    ChunkArrived(step) -> #(
      model,
      stream.insert(steps.steps(), step, at: stream.Append),
    )
    Finished(step) -> #(
      Model(running: model.running - 1),
      stream.insert(steps.steps(), Step(..step, done: True), at: stream.Append),
    )
    // A delete and an insert of one key in one update: a move.
    MovedToTop(step) -> #(
      model,
      effect.batch([
        stream.delete(steps.steps(), step),
        stream.insert(steps.steps(), step, at: stream.Prepend),
      ]),
    )
    Dismissed(key) -> #(model, stream.delete_key(steps.steps(), key))
    Cleared -> #(Model(running: 0), stream.reset(steps.steps(), []))
  }
}
```

## Rendering

`stream.render(s, tag, attributes, item)` is the stream's container: a
`tag` element whose children are the stream's items, each rendered by
`item`, with its root keyed by the stream's key.

<!-- docs-check: wrap
import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/stream
import gleam/int
import streams_guide/steps.{type Step}

pub type Model {
  Model(running: Int)
}

pub type Msg {
  MovedToTop(Step)
  Dismissed(String)
}

{{block}}
-->
```gleam
pub fn view(model: Model) -> Element(Msg) {
  html.main([], [
    html.h1([], [html.text(int.to_string(model.running) <> " running")]),
    stream.render(steps.steps(), "ol", [attribute.class("steps")], render_step),
  ])
}

pub fn render_step(step: Step) -> Element(Msg) {
  html.li([attribute.classes([#("done", step.done)])], [
    html.span([], [html.text(step.agent)]),
    html.pre([], [html.text(step.text)]),
    html.button([event.on_click(MovedToTop(step))], [html.text("Top")]),
    html.button([event.on_click(Dismissed(steps.step_key(step)))], [
      html.text("Dismiss"),
    ]),
  ])
}
```

The rules, each checked:

- `item` is a named top-level function (`render_step` or
  `module.render_step`), not an anonymous `fn` or a capture such as
  `render_step(_, model.selected)`. The build refuses anything else and
  names the place. An item is rendered when it is inserted or updated and
  never again, so it can depend on the item only. State that changes how
  every item looks, such as a selection or a filter, goes on the
  container's attributes and CSS, or the app re-inserts the items it
  changes.
- The item's root is one element: not text, `element.none()`,
  `unsafe_raw_html` or `element.keyed`. The stream keys the root itself.
- A view renders a stream at most once, and never inside another stream's
  item. A second render crashes the render.
- A `brazier.simple` app cannot render a stream: its `update` returns no
  effects, so nothing could fill it. The build says so; use
  `brazier.application` or `brazier.full_application`.

The page's morph does not descend into a container: it morphs the
container's own attributes, and the stream patches the children from each
frame. A stream whose container is not in the current view keeps its items
in the browser, bounded by its limit, and the container is filled when it
appears.

### Events inside items

A handler inside an item is numbered from the item's root, so a prepend
does not change any other item's markup, and a click on an item after
other items were inserted before it still sends that item's message. A
click on a server-rendered item before the join answers is queued and
replayed once the join renders, on the same item; if the join removed the
item, the event is dropped with a warning.

Messages built in an item function are reached from `view`, so they are in
the server's message allowlist like any other (see
[SECURITY.md](SECURITY.md#events-from-the-browser)).

### Hooks inside items

An item can hold a client hook (`attribute.hook`, see
[HTML_ELEMENTS.md](HTML_ELEMENTS.md#client-hooks)). Its `mount` runs when
the item is inserted, `update` when the item is updated in place and an
attribute named in `attribute.watch` changed, and `unmount` when the item
is deleted, trimmed or reset away. A move keeps the hook mounted. Give the
element the hook draws into `attribute.ignore_updates()`, so the morph of
an updated item leaves the hook's children alone.

The hook is registered in the browser with
`window.brazierClient.registerHook(name, {mount, update, unmount})`;
`mount(el)` returns the hook's state, and `update(el, state)` and
`unmount(el, state)` receive it. `registerHook` exists once the client has
booted on `DOMContentLoaded`, so a script loaded with `defer` from
`brazier.head_html` registers in its own `DOMContentLoaded` listener, as
`examples/timeline/static/timeline_hooks.js` does. The page's CSP allows
same-origin scripts only, so the hook is a static file.

## Limits

| Limit | Full stream, new key appended | Full stream, new key prepended | LiveView |
|-------|------------------------------|--------------------------------|----------|
| `stream.KeepLast(n)` | The first item is dropped | The new item is dropped | `limit: -n` |
| `stream.KeepFirst(n)` | The new item is dropped | The last item is dropped | `limit: n` |

An update in place never trims. `insert_many` and `reset` trim as the
items are inserted one by one, so `KeepLast(20)` after an append of 25 new
items holds the last 20 of them. An item inserted and trimmed in the same
update is never sent.

The server computes every trim and sends it as a delete; the browser does
not trim, and treats a store over its limit as a fault. The limit is part
of the declaration, so it is never repeated, or forgotten, on an insert.
The largest limit is `SecurityLimits.stream_max_limit`, 1000 by default
and at most 1000.

## Page loads and reconnects

- **The first render** (SSR) runs `init` and the route message, applies
  their stream ops and renders the items into the HTML, keyed. An item
  that does not decode crashes that render, so the page answers 500: an
  encoder and a decoder that disagree fail on the first page load.
- **The join** runs `init` again, as for the model, so a data fetch in
  `init` runs twice per page load, as LiveView's `mount` does. The join's
  `model_sync` carries `init`'s items, and the browser reconciles each
  container by key: a server-rendered item that is sent again keeps its
  DOM node, its focus and its hooks.
- **A reconnect** starts a new session, so `init` refills every stream;
  there is no replay buffer. The page keeps the old items until the join
  answers, then keeps the nodes of the items `init` sent again and removes
  the others, unmounting only their hooks. Each tab is its own session
  with its own `init`; a connection that joins a session after its first
  is sent the changes from its join on, not the items before it.
- **Model sync** never sees items: the diff, the revision,
  `request_sync` and the state recovery of `with_state_recovery` do not
  carry streams.

A route change that shows another list resets the stream in the route
message's `update`, as a LiveView resets in `handle_params`: a stream
belongs to the session, not to a route.

## Errors and bounds

| Case | Caught by | What happens |
|------|-----------|--------------|
| A name that is not a literal, a name declared twice, an item function that is anonymous or a capture, a stream in a `simple` app | build | Build error naming the place |
| A bad name, or a limit below 1 | `stream.new` | Crash with a message |
| An empty key, a key over 256 bytes, an item over 64 KB, a limit over `stream_max_limit`, a name the build did not declare, a second limit for one name | runtime | That op is refused |
| Over 1000 ops in one update, or over 1 MB of stream entries in one frame | runtime | Every stream op of the update is refused; the model part is sent |
| A delete of a key not in the stream | runtime | Warning, nothing sent |
| An item that does not decode or render | SSR | The render crashes (500) |
| A frame that does not fit the browser's stores, or an item that does not decode or render there | browser | Stream fault |

A refused op is logged at error with the stream, the size and the bound,
emits `[brazier, stream, refused]`, and sends an `error` frame to the
joined connections. It is not applied, so the server still knows what each
browser holds. The bounds are `SecurityLimits` fields (see
[SECURITY.md](SECURITY.md#stream-bounds)); the events are in
[TELEMETRY.md](TELEMETRY.md#event-catalogue).

A **stream fault** means the browser's store can no longer be trusted. The
client logs one `console.error` naming the stream and the reason, closes
the socket with 4000 `stream fault`, and reconnects with backoff, and the
new session's `init` refills every stream (see
[WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#close-codes)). The server checks every
frame before it sends it, so a fault is an app codec bug, a framework bug
or a frame from another build. A codec bug faults on every join, so it is
a reconnect loop held to the backoff, as an `init` that crashes is; the
first page load usually shows it first, as a 500.

## Testing

`stream.emitted` lists the ops an effect carries, in the order they are
applied, as `Inserted(stream:, key:, json:, at:)`, `Deleted(stream:, key:)`
and `Reset(stream:, items:)`. `stream.round_trip` encodes an item and
decodes it with the stream's decoder, so a unit test checks the codec the
browser will use:

<!-- docs-check: wrap
import brazier/effect
import brazier/stream
import streams_guide/steps.{Step}

{{block}}
-->
```gleam
pub fn move_to_top_test() {
  let step = Step(agent: "coder", seq: 4, text: "Edit the file", done: False)
  let move =
    effect.batch([
      stream.delete(steps.steps(), step),
      stream.insert(steps.steps(), step, at: stream.Prepend),
    ])
  let assert [
    stream.Deleted(stream: "steps", key: "coder:4"),
    stream.Inserted(stream: "steps", key: "coder:4", json: _, at: stream.Prepend),
  ] = stream.emitted(move)
}

pub fn codec_test() {
  let step = Step(agent: "coder", seq: 4, text: "Edit \"the\" file", done: True)
  let assert Ok(decoded) = stream.round_trip(steps.steps(), step)
  assert decoded == step
}
```

The browser side (node identity, focus, hooks, trims, the reconnect
reconcile, a stream fault and pre-hydration replay) is checked over CDP by
the timeline slice: `make browser-timeline`. See
[TESTING.md](TESTING.md#example-and-cdp-tests-browser).
