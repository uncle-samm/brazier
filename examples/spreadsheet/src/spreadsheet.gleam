/// Spreadsheet, demonstrating:
/// - a grid shared by every session, one `brazier/store` entry per cell, so
///   edits to different cells never overwrite each other;
/// - selection and the edit buffer in Local state: clicking and typing
///   never reach the server, only a saved cell does;
/// - a PubSub subscription that re-reads the grid when any session saves.
import brazier
import brazier/attribute
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import brazier/store.{type Store}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

// --- Types ---

/// Synced to the browser: `num_rows` rows of one value per column.
pub type Model {
  Model(rows: List(List(String)))
}

pub type Position {
  Position(row: Int, col: Int)
}

/// Client-only.
pub type Local {
  Local(selected: Option(Position), editing: Bool, buffer: String)
}

pub type Msg {
  /// Select a cell, or start editing it when it is already selected.
  CellClicked(row: Int, col: Int)
  BufferChanged(String)
  KeyPressed(String)
  SaveCell(row: Int, col: Int, value: String)
  /// A session saved a cell.
  CellsChanged
}

const num_rows = 10

const max_value_length = 1000

/// The column names, in order; the grid has one column per name.
const columns = ["A", "B", "C", "D", "E"]

/// "A1" for row 0, column 0. Also the cell's store key.
fn cell_name(row: Int, col: Int) -> String {
  // Invariant: `col` comes from `columns` (the view) or was bounds-checked
  // by `in_grid` (the server).
  let assert Ok(column) = list.drop(columns, col) |> list.first
  column <> int.to_string(row + 1)
}

fn in_grid(row: Int, col: Int) -> Bool {
  row >= 0 && row < num_rows && col >= 0 && col < list.length(columns)
}

fn cell_value(model: Model, position: Position) -> String {
  // Invariant: `read_grid` always builds a full grid, and positions come
  // from the view's own indices.
  let assert Ok(values) = list.drop(model.rows, position.row) |> list.first
  let assert Ok(value) = list.drop(values, position.col) |> list.first
  value
}

// --- Shared grid ---

fn read_grid(cells: Store(String)) -> Model {
  Model(
    rows: list.index_map(list.repeat(Nil, num_rows), fn(_, row) {
      list.index_map(columns, fn(_, col) {
        case store.get(cells, cell_name(row, col)) {
          Ok(value) -> value
          // A cell nobody has written yet is empty.
          Error(Nil) -> ""
        }
      })
    }),
  )
}

// --- Init and update (server) ---

fn init(
  cells: Store(String),
) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(read_grid(cells), effect.none()))
}

fn update(
  cells: Store(String),
  model: Model,
  msg: Msg,
) -> #(Model, Effect(Msg)) {
  case msg {
    SaveCell(row:, col:, value:) ->
      case in_grid(row, col), string.length(value) > max_value_length {
        False, _ -> {
          log.warning(
            "spreadsheet",
            "Rejected a save outside the grid at row "
              <> int.to_string(row)
              <> ", column "
              <> int.to_string(col),
          )
          #(model, effect.none())
        }
        True, True -> {
          log.warning(
            "spreadsheet",
            "Rejected a "
              <> int.to_string(string.length(value))
              <> "-character value for "
              <> cell_name(row, col)
              <> " (max "
              <> int.to_string(max_value_length)
              <> ")",
          )
          #(model, effect.none())
        }
        True, False -> {
          let name = cell_name(row, col)
          log.info("spreadsheet", "Saving " <> name)
          // The store broadcasts on its topic, which every session (this
          // one included) turns into `CellsChanged`.
          #(model, effect.from(fn(_dispatch) { store.put(cells, name, value) }))
        }
      }
    CellsChanged -> #(read_grid(cells), effect.none())
    // `update_local` handles these in the browser and never forwards them.
    CellClicked(..) | BufferChanged(_) | KeyPressed(_) -> #(
      model,
      effect.none(),
    )
  }
}

fn sync(model: Model) -> Model {
  model
}

// --- Local (browser) ---

pub fn init_local(_model: Model) -> Local {
  Local(selected: None, editing: False, buffer: "")
}

pub fn update_local(
  model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    CellClicked(row:, col:) -> {
      let position = Position(row:, col:)
      case local.selected == Some(position) {
        True ->
          local.handled(
            Local(..local, editing: True, buffer: cell_value(model, position)),
          )
        False ->
          local.handled(Local(
            selected: Some(position),
            editing: False,
            buffer: "",
          ))
      }
    }
    BufferChanged(text) -> local.handled(Local(..local, buffer: text))
    KeyPressed("Escape") -> local.handled(Local(..local, editing: False))
    KeyPressed(_) -> local.handled(local)
    SaveCell(..) -> local.forward(Local(..local, editing: False))
    CellsChanged -> local.forward(local)
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "900px"),
        #("margin", "2rem auto"),
        #("padding", "0 1rem"),
      ]),
    ],
    [
      html.h1([], [html.text("Spreadsheet")]),
      html.p(
        [attribute.styles([#("color", "#666"), #("margin-bottom", "1rem")])],
        [
          html.text(
            "Click a cell to select, click again to edit. Enter saves, Escape cancels.",
          ),
        ],
      ),
      html.div(
        [
          attribute.styles([
            #("border", "1px solid #ccc"),
            #("border-radius", "4px"),
            #("overflow", "auto"),
          ]),
        ],
        [
          html.table(
            [
              attribute.styles([
                #("border-collapse", "collapse"),
                #("width", "100%"),
              ]),
              attribute.data("grid", "true"),
            ],
            [
              html.thead([], [
                html.tr([], [
                  html.th([attribute.styles(header_style())], []),
                  ..list.map(columns, fn(column) {
                    html.th(
                      [
                        attribute.styles(header_style()),
                        attribute.style("min-width", "80px"),
                      ],
                      [html.text(column)],
                    )
                  })
                ]),
              ]),
              html.tbody(
                [],
                list.index_map(model.rows, fn(values, row) {
                  render_row(local, values, row)
                }),
              ),
            ],
          ),
        ],
      ),
      html.div(
        [
          attribute.styles([
            #("margin-top", "0.5rem"),
            #("font-size", "0.85rem"),
            #("color", "#999"),
          ]),
        ],
        [
          html.text(case local.selected {
            Some(Position(row:, col:)) ->
              "Selected: "
              <> cell_name(row, col)
              <> case local.editing {
                True -> " (editing)"
                False -> ""
              }
            None -> "Click a cell to select"
          }),
        ],
      ),
    ],
  )
}

fn header_style() -> List(#(String, String)) {
  [
    #("padding", "8px"),
    #("background", "#f5f5f5"),
    #("border", "1px solid #ddd"),
    #("font-weight", "600"),
    #("color", "#555"),
  ]
}

fn render_row(local: Local, values: List(String), row: Int) -> Element(Msg) {
  html.tr([], [
    html.td(
      [
        attribute.styles([
          #("padding", "4px 8px"),
          #("background", "#f5f5f5"),
          #("border", "1px solid #ddd"),
          #("text-align", "center"),
          #("font-weight", "600"),
          #("color", "#555"),
          #("font-size", "13px"),
        ]),
      ],
      [html.text(int.to_string(row + 1))],
    ),
    ..list.index_map(values, fn(value, col) {
      render_cell(local, Position(row:, col:), value)
    })
  ])
}

fn render_cell(
  local: Local,
  position: Position,
  value: String,
) -> Element(Msg) {
  let Position(row:, col:) = position
  let is_selected = local.selected == Some(position)
  let border = case is_selected {
    True -> "2px solid #2196F3"
    False -> "1px solid #ddd"
  }
  case is_selected && local.editing {
    True ->
      html.td([attribute.styles([#("border", border), #("padding", "0")])], [
        html.form(
          [
            event.on_submit(fn(_fields) {
              SaveCell(row:, col:, value: local.buffer)
            }),
            attribute.style("display", "flex"),
          ],
          [
            html.input([
              attribute.type_("text"),
              attribute.value(local.buffer),
              attribute.aria("label", "Edit " <> cell_name(row, col)),
              attribute.autofocus(True),
              event.on_input(BufferChanged),
              event.on_keydown(KeyPressed),
              attribute.styles([
                #("flex", "1"),
                #("min-width", "0"),
                #("padding", "4px 8px"),
                #("border", "none"),
                #("outline", "none"),
                #("font-size", "13px"),
              ]),
            ]),
            html.button(
              [
                attribute.type_("submit"),
                attribute.styles([
                  #("width", "48px"),
                  #("padding", "4px"),
                  #("border", "0"),
                  #("border-left", "1px solid #ddd"),
                  #("background", "#eef5ff"),
                  #("cursor", "pointer"),
                  #("font-size", "12px"),
                ]),
              ],
              [html.text("Save")],
            ),
          ],
        ),
      ])
    False ->
      html.td(
        [
          event.on_click(CellClicked(row:, col:)),
          attribute.data("cell", cell_name(row, col)),
          attribute.styles([
            #("border", border),
            #("padding", "4px 8px"),
            #("cursor", "pointer"),
            #("height", "24px"),
            #("font-size", "13px"),
          ]),
        ],
        [html.text(value)],
      )
  }
}

// --- Start ---

pub fn main() {
  let cells = store.new("spreadsheet_cells")
  let assert Ok(Nil) =
    brazier.full_application(
      init: fn(_ctx) { init(cells) },
      update: fn(model, msg) { update(cells, model, msg) },
      sync:,
      local: local.layer(init: init_local, update: update_local),
      view:,
    )
    |> brazier.title(fn(_model) { "Spreadsheet" })
    |> brazier.subscriptions(fn(_model) { [store.topic(cells)] })
    |> brazier.on_notify(fn(_topic) { CellsChanged })
    |> brazier.head_html(favicon)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
