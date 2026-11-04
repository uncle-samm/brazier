/// Multi-file Kanban, demonstrating:
/// - `brazier.simple` with model and message types from another module
///   (`domains/board.gleam`): the build generates their codecs and compiles
///   `update`, imports included, to JavaScript;
/// - drag and drop on a simple app. `update` runs in the browser first, so a
///   moved card lands instantly, and the server, which stays authoritative,
///   runs the same `update`;
/// - a throttled `dragover`: the default is still prevented on every event,
///   so the column stays a drop target, but at most four messages a second
///   reach `update`.
///
/// The board belongs to one session; see the `kanban` example for a board
/// shared between sessions.
import brazier
import brazier/attribute
import brazier/config
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/log
import domains/board
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

pub type Model {
  Model(
    cards: List(board.Card),
    next_id: Int,
    draft: String,
    dragging: Option(Int),
    over: Option(board.Column),
  )
}

pub type Msg {
  DraftChanged(String)
  AddCard
  DeleteCard(Int)
  DragStart(Int)
  DragOver(board.Column)
  DropOn(board.Column)
  DragEnd
}

const max_title_length = 100

const columns = [board.Todo, board.Doing, board.Done]

fn init(_ctx: brazier.Context) -> Result(Model, brazier.InitError) {
  Ok(Model(
    cards: [
      board.Card(id: 1, title: "Design API", column: board.Todo),
      board.Card(id: 2, title: "Write tests", column: board.Doing),
      board.Card(id: 3, title: "Build UI", column: board.Todo),
    ],
    next_id: 4,
    draft: "",
    dragging: None,
    over: None,
  ))
}

/// Runs in the browser and on the server, so it is pure apart from logging.
pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    DraftChanged(text) -> Model(..model, draft: text)
    AddCard -> add_card(model)
    DeleteCard(id) ->
      Model(
        ..model,
        cards: list.filter(model.cards, fn(card) { card.id != id }),
      )
    DragStart(id) -> Model(..model, dragging: Some(id), over: None)
    DragOver(column) -> Model(..model, over: Some(column))
    DropOn(column) ->
      case model.dragging {
        None -> {
          log.warning(
            "multi_kanban",
            "Ignored a drop on " <> column_slug(column) <> " with no drag",
          )
          Model(..model, over: None)
        }
        Some(id) ->
          Model(
            ..model,
            cards: list.map(model.cards, fn(card) {
              case card.id == id {
                True -> board.Card(..card, column:)
                False -> card
              }
            }),
            dragging: None,
            over: None,
          )
      }
    DragEnd -> Model(..model, dragging: None, over: None)
  }
}

fn add_card(model: Model) -> Model {
  let title = string.trim(model.draft)
  case string.is_empty(title), string.length(title) > max_title_length {
    True, _ -> model
    _, True -> {
      log.warning(
        "multi_kanban",
        "Rejected a card title of "
          <> int.to_string(string.length(title))
          <> " characters (max "
          <> int.to_string(max_title_length)
          <> ")",
      )
      model
    }
    False, False ->
      Model(
        ..model,
        cards: list.append(model.cards, [
          board.Card(id: model.next_id, title:, column: board.Todo),
        ]),
        next_id: model.next_id + 1,
        draft: "",
      )
  }
}

fn column_slug(column: board.Column) -> String {
  case column {
    board.Todo -> "todo"
    board.Doing -> "doing"
    board.Done -> "done"
  }
}

fn column_label(column: board.Column) -> String {
  case column {
    board.Todo -> "Todo"
    board.Doing -> "In Progress"
    board.Done -> "Done"
  }
}

fn column_colour(column: board.Column) -> String {
  case column {
    board.Todo -> "#e3f2fd"
    board.Doing -> "#fff3e0"
    board.Done -> "#e8f5e9"
  }
}

pub fn view(model: Model) -> Element(Msg) {
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
      html.h1([], [html.text("Multi-File Kanban")]),
      html.p(
        [attribute.styles([#("color", "#666"), #("margin-bottom", "1rem")])],
        [
          html.text(
            "Drag cards between columns. The Card and Column types come from domains/board.gleam.",
          ),
        ],
      ),
      html.form(
        [
          event.on_submit(fn(_fields) { AddCard }),
          attribute.styles([
            #("display", "flex"),
            #("gap", "8px"),
            #("margin-bottom", "1.5rem"),
          ]),
        ],
        [
          html.input([
            attribute.type_("text"),
            attribute.placeholder("New card..."),
            attribute.aria("label", "New card title"),
            attribute.value(model.draft),
            event.on_input(DraftChanged),
            attribute.styles([
              #("flex", "1"),
              #("padding", "10px"),
              #("border", "1px solid #ddd"),
              #("border-radius", "6px"),
            ]),
          ]),
          html.button(
            [
              attribute.type_("submit"),
              attribute.styles([
                #("padding", "10px 20px"),
                #("background", "#4CAF50"),
                #("color", "white"),
                #("border", "none"),
                #("border-radius", "6px"),
                #("cursor", "pointer"),
              ]),
            ],
            [html.text("Add Card")],
          ),
        ],
      ),
      html.div(
        [
          attribute.styles([
            #("display", "grid"),
            #("grid-template-columns", "repeat(3,1fr)"),
            #("gap", "1rem"),
          ]),
        ],
        list.map(columns, fn(column) { render_column(model, column) }),
      ),
    ],
  )
}

fn render_column(model: Model, column: board.Column) -> Element(Msg) {
  let cards = list.filter(model.cards, fn(card) { card.column == column })
  let outline = case model.dragging, model.over == Some(column) {
    Some(_), True -> "2px dashed #2196F3"
    _, _ -> "2px solid transparent"
  }
  html.div(
    [
      event.on_drag_over(DragOver(column)) |> event.throttle(250),
      event.on_drop(DropOn(column)),
      attribute.data("column", column_slug(column)),
      attribute.styles([
        #("background", column_colour(column)),
        #("border-radius", "12px"),
        #("padding", "1rem"),
        #("min-height", "200px"),
        #("outline", outline),
      ]),
    ],
    [
      html.h3(
        [
          attribute.styles([
            #("margin", "0 0 1rem"),
            #("color", "#555"),
            #("font-size", "0.9rem"),
            #("text-transform", "uppercase"),
          ]),
        ],
        [
          html.text(
            column_label(column)
            <> " ("
            <> int.to_string(list.length(cards))
            <> ")",
          ),
        ],
      ),
      html.div(
        [
          attribute.styles([
            #("display", "flex"),
            #("flex-direction", "column"),
            #("gap", "8px"),
          ]),
        ],
        list.map(cards, fn(card) {
          element.keyed(
            int.to_string(card.id),
            render_card(card, model.dragging == Some(card.id)),
          )
        }),
      ),
    ],
  )
}

fn render_card(card: board.Card, is_dragging: Bool) -> Element(Msg) {
  let opacity = case is_dragging {
    True -> "0.4"
    False -> "1"
  }
  html.div(
    [
      attribute.draggable(True),
      attribute.data("card", int.to_string(card.id)),
      event.on_drag_start(DragStart(card.id)),
      event.on_drag_end(DragEnd),
      attribute.styles([
        #("background", "white"),
        #("padding", "12px"),
        #("border-radius", "8px"),
        #("border", "1px solid #e0e0e0"),
        #("cursor", "grab"),
        #("display", "flex"),
        #("justify-content", "space-between"),
        #("opacity", opacity),
      ]),
    ],
    [
      html.span([], [html.text(card.title)]),
      html.button(
        [
          event.on_click(DeleteCard(card.id)),
          attribute.aria("label", "Delete " <> card.title),
          attribute.styles([
            #("background", "none"),
            #("border", "none"),
            #("color", "#bbb"),
            #("cursor", "pointer"),
          ]),
        ],
        [html.text("x")],
      ),
    ],
  )
}

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let assert Ok(Nil) =
    brazier.simple(init:, update:, view:)
    |> brazier.title(fn(_model) { "Multi-File Kanban" })
    |> brazier.head_html(favicon)
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
