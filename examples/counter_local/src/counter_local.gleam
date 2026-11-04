/// Counter with Local state: the Model + Local architecture.
/// - `Model.count` is synced: the server holds it and the browser renders it.
/// - `Local.input` and `Local.menu_open` are client-only: they change at once
///   in the browser and are never sent to the server.
import brazier
import brazier/attribute
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import gleam/int

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

/// Synced state, held by the server.
pub type Model {
  Model(count: Int)
}

/// Client-only state, per tab.
pub type Local {
  Local(input: String, menu_open: Bool)
}

pub type Msg {
  Increment
  Decrement
  SetInput(String)
  ToggleMenu
}

fn init(
  _ctx: brazier.Context,
) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(count: 0), effect.none()))
}

pub fn init_local(_model: Model) -> Local {
  Local(input: "", menu_open: False)
}

/// Runs in the browser. Local messages are handled here and never reach the
/// server; the counter messages are forwarded to `update`.
pub fn update_local(
  _model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    SetInput(text) -> local.handled(Local(..local, input: text))
    ToggleMenu -> local.handled(Local(..local, menu_open: !local.menu_open))
    Increment | Decrement -> local.forward(local)
  }
}

/// Runs on the server for forwarded messages.
fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Increment -> #(Model(count: model.count + 1), effect.none())
    Decrement -> #(Model(count: model.count - 1), effect.none())
    // `update_local` handles these in the browser and never forwards them.
    SetInput(_) | ToggleMenu -> #(model, effect.none())
  }
}

fn sync(model: Model) -> Model {
  model
}

pub fn view(model: Model, local: Local) -> Element(Msg) {
  html.div([attribute.class("counter-local")], [
    html.h1([], [html.text("Counter with Local State")]),
    html.div([attribute.class("server-state")], [
      html.p([], [html.text("Count (server): " <> int.to_string(model.count))]),
      html.button([event.on_click(Decrement)], [html.text("-")]),
      html.button([event.on_click(Increment)], [html.text("+")]),
    ]),
    html.div([attribute.class("local-state")], [
      html.p([], [html.text("Input (local): " <> local.input)]),
      html.input([
        attribute.type_("text"),
        attribute.placeholder("Type here (local state)..."),
        attribute.value(local.input),
        event.on_input(SetInput),
      ]),
      html.button([event.on_click(ToggleMenu)], [html.text("Toggle Menu")]),
      case local.menu_open {
        True ->
          html.div([attribute.class("dropdown")], [
            html.p([], [html.text("Menu is open! (local state)")]),
          ])
        False -> element.none()
      },
    ]),
  ])
}

pub fn main() {
  let assert Ok(Nil) =
    brazier.full_application(
      init:,
      update:,
      sync:,
      local: local.layer(init: init_local, update: update_local),
      view:,
    )
    |> brazier.title(fn(_model) { "Counter with Local State" })
    |> brazier.head_html(favicon)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
