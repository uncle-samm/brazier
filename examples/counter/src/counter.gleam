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

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Decrement
}

fn init(_ctx: beacon.Context) -> Result(Model, beacon.InitError) {
  Ok(Model(count: 0))
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
  let assert Ok(Nil) =
    beacon.simple(init:, update:, view:)
    |> beacon.title(fn(_model) { "Beacon Counter" })
    |> beacon.head_html(favicon)
    |> beacon.start(8080)
    as "beacon.start failed (it logs the error)"
}
