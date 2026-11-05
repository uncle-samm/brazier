/// Rows: a 1000-row list, the browser bench of the client's DOM morph.
///
/// Every row has a click handler, as in the node client bench
/// (`test/brazier/bench/client_bench.gleam`). "Relabel" changes every tenth
/// label and moves the selection, the change that bench's patch carries.
/// The update runs on the server (`brazier.application`), so each click
/// comes back as one patch and one render of the page; the CDP harness
/// (`test_all_cdp.py`, section Rows) times the morph of that render.
import brazier
import brazier/attribute
import brazier/config
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import gleam/int
import gleam/list

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%2322c55e'/></svg>\">"

/// How many rows the list holds.
const row_count = 1000

pub type Row {
  Row(id: Int, label: String)
}

/// `round` counts the relabels; `selected` is a row id, 0 for none.
pub type Model {
  Model(rows: List(Row), selected: Int, round: Int)
}

pub type Msg {
  Select(id: Int)
  Relabel
}

fn init(
  _ctx: brazier.Context,
) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(initial(), effect.none()))
}

fn initial() -> Model {
  Model(
    rows: int.range(from: row_count, to: 0, with: [], run: fn(acc, id) {
      [Row(id:, label: "row label number " <> int.to_string(id)), ..acc]
    }),
    selected: 0,
    round: 0,
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Select(id:) -> #(Model(..model, selected: id), effect.none())
    Relabel -> #(relabel(model), effect.none())
  }
}

/// Round n: every tenth row is labelled for round n, and row n * 7 (wrapped
/// into 1..row_count) is selected, so every round changes the same 100
/// labels and moves the selection.
fn relabel(model: Model) -> Model {
  let round = model.round + 1
  Model(
    rows: list.map(model.rows, fn(row) {
      case row.id % 10 {
        0 ->
          Row(
            ..row,
            label: "label "
              <> int.to_string(row.id)
              <> " round "
              <> int.to_string(round),
          )
        _ -> row
      }
    }),
    selected: { round * 7 } % row_count + 1,
    round:,
  )
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("rows")], [
    html.h1([], [html.text("Brazier Rows")]),
    html.p([attribute.data("testid", "status")], [
      html.text(
        "Round "
        <> int.to_string(model.round)
        <> ", selected "
        <> int.to_string(model.selected),
      ),
    ]),
    html.button([attribute.id("relabel"), event.on_click(Relabel)], [
      html.text("Relabel"),
    ]),
    html.ul(
      [attribute.id("rows")],
      list.map(model.rows, fn(row) {
        html.li(
          [
            attribute.class(case row.id == model.selected {
              True -> "row selected"
              False -> "row"
            }),
            attribute.data("row", int.to_string(row.id)),
            event.on_click(Select(row.id)),
          ],
          [
            html.span([], [html.text(int.to_string(row.id))]),
            html.span([attribute.class("label")], [html.text(row.label)]),
          ],
        )
      }),
    ),
  ])
}

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let assert Ok(Nil) =
    brazier.application(init:, update:, view:)
    |> brazier.title(fn(_model) { "Brazier Rows" })
    |> brazier.head_html(favicon)
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
