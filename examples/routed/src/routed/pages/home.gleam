/// The home page: a nested component with its own Model, Msg, update and
/// view (Elm/Lustre style). The root app maps its messages with
/// `element.map(Home)`.
import beacon/attribute
import beacon/element.{type Element}
import beacon/event
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int, server_updates: Int)
}

pub type Msg {
  Increment
  Decrement
}

pub fn init() -> Model {
  Model(count: 0, server_updates: 0)
}

/// Runs on the server (the root is a `beacon.application`), so
/// `server_updates` counts the events the server handled.
pub fn update(model: Model, msg: Msg) -> Model {
  let model = Model(..model, server_updates: model.server_updates + 1)
  case msg {
    Increment -> Model(..model, count: model.count + 1)
    Decrement -> Model(..model, count: model.count - 1)
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.section([], [
    html.h1([], [html.text("Routed")]),
    html.p([], [
      html.text("Home owns a route-local Model and Msg inside one Beacon app."),
    ]),
    html.div(
      [
        attribute.styles([
          #("display", "flex"),
          #("gap", "8px"),
          #("align-items", "center"),
        ]),
      ],
      [
        html.button([event.on_click(Decrement)], [html.text("-")]),
        html.strong([attribute.data("testid", "count")], [
          html.text(int.to_string(model.count)),
        ]),
        html.button([event.on_click(Increment)], [html.text("+")]),
      ],
    ),
    html.p([attribute.data("testid", "server-updates")], [
      html.text(
        "Server-authoritative updates: " <> int.to_string(model.server_updates),
      ),
    ]),
  ])
}
