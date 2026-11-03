# Components

Beacon has no component type. A reusable piece of UI is a plain Gleam module with its own `Model`, `Msg`, `update` and `view`, nested inside a parent the way Elm and Lustre nest modules:

- the parent keeps the child's model in a field of its own model;
- the parent has one message constructor that wraps the child's messages;
- the parent's `view` wraps the child's view with `element.map`;
- the parent's `update` forwards the wrapped message and wraps the child's effects with `effect.map`.

The child's state lives in the parent's state, so it is synced, kept on the server, or both, exactly like the rest of the parent's state. The runtime does not own child state. Stateful, runtime-owned live components (LiveView's `live_component`) are not supported.

## The child module

<!-- docs-check: module my_app/counter -->
```gleam
// src/my_app/counter.gleam
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/event
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Decrement
}

pub fn init() -> Model {
  Model(count: 0)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Increment -> #(Model(count: model.count + 1), effect.none())
    Decrement -> #(Model(count: model.count - 1), effect.none())
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.button([event.on_click(Decrement)], [html.text("-")]),
    html.text(int.to_string(model.count)),
    html.button([event.on_click(Increment)], [html.text("+")]),
  ])
}
```

A child used from a `beacon.simple` app has `update: fn(Model, Msg) -> Model` instead, and the parent calls it without `effect.map`.

## Nesting it in a parent

<!-- docs-check: module my_app -->
```gleam
// src/my_app.gleam
import beacon
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/html
import my_app/counter

pub type Model {
  Model(left: counter.Model, right: counter.Model)
}

pub type Msg {
  LeftMsg(counter.Msg)
  RightMsg(counter.Msg)
}

pub fn init(_ctx: beacon.Context) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model(left: counter.init(), right: counter.init()), effect.none()))
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    LeftMsg(child_msg) -> {
      let #(left, eff) = counter.update(model.left, child_msg)
      #(Model(..model, left: left), effect.map(eff, LeftMsg))
    }
    RightMsg(child_msg) -> {
      let #(right, eff) = counter.update(model.right, child_msg)
      #(Model(..model, right: right), effect.map(eff, RightMsg))
    }
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    element.map(counter.view(model.left), LeftMsg),
    element.map(counter.view(model.right), RightMsg),
  ])
}

pub fn main() {
  beacon.application(init:, update:, view:)
  |> beacon.start(8080)
}
```

`element.map` rewrites every event handler in the child's tree, so a click on the left `+` button reaches the parent's `update` as `LeftMsg(counter.Increment)`. `attribute.map` does the same for a single attribute. `effect.map` wraps every message the child's effect dispatches, including messages from timers and background work, so `effect.after(1000, fn() { counter.Increment })` returned by the child arrives as `LeftMsg(counter.Increment)`.

## What the build does with child modules

The build follows references from `view` (see `docs/ARCHITECTURE.md`). The child's `view`, and its `Msg` and `Model` types, are compiled into the client bundle because the parent's `view` reaches them. The child's `update` is compiled only for a `beacon.simple` app.

The server accepts a child message only when the constructors that build it are reachable from `view`. `element.map(counter.view(model.left), LeftMsg)` counts as a use of `LeftMsg`, and `event.on_click(Increment)` inside `counter.view` counts as a use of `counter.Increment`. A child message that only an effect produces (for example a `Loaded(data)` dispatched by `effect.from`) is never accepted from the browser.

## Communicating with the parent

A child that needs to tell its parent something returns that information from `update` instead of sending a message upwards. Lustre and Elm use the same pattern:

<!-- docs-check: wrap
import beacon/effect.{type Effect}

pub type Model {
  Model(draft: String)
}

pub type Msg {
  Typed(String)
  Submit
}

{{block}}
-->
```gleam
pub type OutMsg {
  Submitted(String)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg), List(OutMsg)) {
  case msg {
    Typed(text) -> #(Model(draft: text), effect.none(), [])
    Submit -> #(Model(draft: ""), effect.none(), [Submitted(model.draft)])
  }
}
```

The parent pattern-matches the returned list in its own `update`.

## Migrating from `beacon/component`

| Old | New |
|---|---|
| `component.new(init, update, view, to_parent)` | a module with `init`, `update` and `view` |
| `component.render(comp, model)` | `element.map(child.view(model), ToParent)` |
| `component.update_component(comp, model, msg)` | `child.update(model, msg)` plus `effect.map(eff, ToParent)` |
| `component.map_node(node, f)` | `element.map(element, f)` |

`test/beacon/child_module_test.gleam` runs this pattern through the runtime.
