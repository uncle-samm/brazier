/// Privacy Demo: secrets stay on the server.
///
/// The session holds an API key, a database URL and a request count next to
/// the Model. `sync` hands only the Model to the browser, and the build
/// compiles for the browser only what `view` reaches. So the secrets are
/// never encoded and never in the client bundle, whatever they are named.
///
/// The subtotal, tax and total are not stored: `view` derives them from
/// the Model, and those functions run in the browser too.
import brazier
import brazier/attribute
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import gleam/float
import gleam/int
import gleam/list
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

// Only the server reads these: `init` puts them in the Session, and `view`
// never reaches them.
const api_key = "sk_live_secret_do_not_leak_this"

const db_url = "postgres://user:pass@localhost/db"

// `view` reaches this one, so it is in the client bundle.
const app_title = "Privacy Demo"

pub type Model {
  Model(items: List(Item), tax_rate: Float)
}

pub type Item {
  Item(name: String, price_cents: Int, qty: Int)
}

/// What the server holds per session. Only `model` is synced.
pub type Session {
  Session(model: Model, api_key: String, db_url: String, request_count: Int)
}

pub type Msg {
  AddItem
  ClearItems
}

fn init(
  _ctx: brazier.Context,
) -> Result(#(Session, Effect(Msg)), brazier.InitError) {
  Ok(#(
    Session(
      model: Model(
        items: [
          Item(name: "Widget", price_cents: 1000, qty: 2),
          Item(name: "Gadget", price_cents: 2500, qty: 1),
        ],
        tax_rate: 0.08,
      ),
      api_key:,
      db_url:,
      request_count: 0,
    ),
    effect.none(),
  ))
}

fn update(session: Session, msg: Msg) -> #(Session, Effect(Msg)) {
  let session = Session(..session, request_count: session.request_count + 1)
  let model = session.model
  let model = case msg {
    AddItem ->
      Model(..model, items: [
        Item(name: "New Item", price_cents: 500, qty: 1),
        ..model.items
      ])
    ClearItems -> Model(..model, items: [])
  }
  log.info(
    "privacy_demo",
    "Handled request "
      <> int.to_string(session.request_count)
      <> " ("
      <> int.to_string(list.length(model.items))
      <> " items)",
  )
  #(Session(..session, model:), effect.none())
}

fn sync(session: Session) -> Model {
  session.model
}

fn subtotal(model: Model) -> Int {
  list.fold(model.items, 0, fn(sum, item) { sum + item.price_cents * item.qty })
}

fn tax(model: Model) -> Int {
  float.round(int.to_float(subtotal(model)) *. model.tax_rate)
}

fn format_cents(cents: Int) -> String {
  "$"
  <> int.to_string(cents / 100)
  <> "."
  <> string.pad_start(int.to_string(cents % 100), to: 2, with: "0")
}

pub fn view(model: Model, _local: Nil) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "600px"),
        #("margin", "2rem auto"),
        #("padding", "0 1rem"),
      ]),
    ],
    [
      html.h1([], [html.text(app_title)]),
      html.ul([], list.map(model.items, view_item)),
      html.p([], [
        html.text("Items: " <> int.to_string(list.length(model.items))),
      ]),
      html.p([], [html.text("Subtotal: " <> format_cents(subtotal(model)))]),
      html.p([], [
        html.text(
          "Tax ("
          <> int.to_string(float.round(model.tax_rate *. 100.0))
          <> "%): "
          <> format_cents(tax(model)),
        ),
      ]),
      html.p([], [
        html.strong([], [
          html.text("Total: " <> format_cents(subtotal(model) + tax(model))),
        ]),
      ]),
      html.button(
        [event.on_click(AddItem), attribute.style("margin-right", "8px")],
        [html.text("Add Item")],
      ),
      html.button([event.on_click(ClearItems)], [html.text("Clear")]),
    ],
  )
}

fn view_item(item: Item) -> Element(Msg) {
  html.li([], [
    html.text(
      item.name
      <> " x"
      <> int.to_string(item.qty)
      <> ": "
      <> format_cents(item.price_cents * item.qty),
    ),
  ])
}

pub fn main() {
  let assert Ok(Nil) =
    brazier.full_application(init:, update:, sync:, local: local.none(), view:)
    |> brazier.title(fn(_model) { app_title })
    |> brazier.head_html(favicon)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
