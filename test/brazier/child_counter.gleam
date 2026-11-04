//// A child module with its own Model, Msg, update and view, nested in a
//// parent by `child_module_test` the way docs/COMPONENTS.md describes.

import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import gleam/int

pub type Model {
  Model(clicks: Int, loaded: Int)
}

pub type Msg {
  /// The button was clicked; the update asks for a load.
  Clicked
  /// The load finished.
  Loaded(Int)
  /// Clicked without asking for anything else.
  Reset
}

pub const loaded_value = 100

pub fn init() -> Model {
  Model(clicks: 0, loaded: 0)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Clicked -> #(
      Model(..model, clicks: model.clicks + 1),
      effect.from(fn(dispatch) { dispatch(Loaded(loaded_value)) }),
    )
    Loaded(value) -> #(Model(..model, loaded: value), effect.none())
    Reset -> #(init(), effect.none())
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.button([event.on_click(Clicked)], [
      html.text(int.to_string(model.clicks)),
    ]),
    html.button([event.on_click(Reset)], [html.text("reset")]),
  ])
}
