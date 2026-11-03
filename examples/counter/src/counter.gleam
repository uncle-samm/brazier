/// Counter, the simplest Beacon app.
///
/// Demonstrates `beacon.simple`: a pure `update` that the build also
/// compiles to JavaScript, so a click updates the page at once while the
/// server runs the same `update` and stays authoritative.
import beacon
import beacon/attribute
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

fn init(_ctx: beacon.Context) -> Model {
  Model(count: 0)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    Decrement -> Model(count: model.count - 1)
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("counter")], [
    html.h1([], [html.text("Beacon Counter")]),
    html.p([], [html.text("Count: " <> int.to_string(model.count))]),
    html.button([event.on_click(Decrement)], [html.text("-")]),
    html.button([event.on_click(Increment)], [html.text("+")]),
  ])
}

pub fn main() {
  beacon.simple(init:, update:, view:)
  |> beacon.title(fn(_model) { "Beacon Counter" })
  |> beacon.start(8080)
}
