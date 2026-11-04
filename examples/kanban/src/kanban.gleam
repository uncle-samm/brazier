/// Kanban Board, demonstrating:
/// - HTML5 drag and drop with typed messages: `on_drag_start(DragStart(id))`
///   on a card and `on_drop(DropOn(column))` on a column;
/// - the high-frequency `dragover` events and the new-card draft handled in
///   Local state, so they never reach the server;
/// - a board shared by every session, kept in a `beacon/store` list as an
///   append-only change log, so concurrent sessions never overwrite each
///   other's changes;
/// - a PubSub subscription that re-reads the log when any session changes it.
import beacon
import beacon/attribute
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/event
import beacon/html
import beacon/local
import beacon/log
import beacon/store.{type ListStore}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

// --- Types ---

pub type Column {
  Todo
  Doing
  Done
}

pub type Card {
  Card(id: Int, title: String, column: Column)
}

/// Synced to the browser.
pub type Model {
  Model(cards: List(Card))
}

/// Server-only, per session.
pub type State {
  State(
    model: Model,
    /// The card this session is dragging. A drop target does not know which
    /// card was dropped on it, so the server remembers `DragStart`.
    dragging: Option(Int),
  )
}

/// Client-only.
pub type Local {
  Local(draft: String, dragging: Option(Int), over: Option(Column))
}

pub type Msg {
  DraftChanged(String)
  AddCard(String)
  DeleteCard(Int)
  DragStart(Int)
  DragOver(Column)
  DropOn(Column)
  DragEnd
  /// A session (this one included) changed the shared log.
  BoardChanged
}

/// One entry of the shared change log. A card's id is the position of its
/// `Added` change in `starting_board` followed by the log, which is the
/// same for every reader because a local list store returns values in
/// insertion order. Server-only.
pub type Change {
  Added(title: String)
  Moved(id: Int, column: Column)
  Deleted(id: Int)
}

const log_key = "board"

const max_title_length = 100

const columns = [Todo, Doing, Done]

fn column_label(column: Column) -> String {
  case column {
    Todo -> "Todo"
    Doing -> "In Progress"
    Done -> "Done"
  }
}

fn column_slug(column: Column) -> String {
  case column {
    Todo -> "todo"
    Doing -> "doing"
    Done -> "done"
  }
}

fn column_colour(column: Column) -> String {
  case column {
    Todo -> "#e3f2fd"
    Doing -> "#fff3e0"
    Done -> "#e8f5e9"
  }
}

// --- Shared log ---

fn replay(changes: List(Change)) -> List(Card) {
  let #(reversed, _position) =
    list.fold(changes, #([], 0), fn(acc, change) {
      let #(cards, position) = acc
      let cards = case change {
        Added(title) -> [Card(id: position, title:, column: Todo), ..cards]
        Moved(id, column) ->
          list.map(cards, fn(card) {
            case card.id == id {
              True -> Card(..card, column:)
              False -> card
            }
          })
        Deleted(id) -> list.filter(cards, fn(card) { card.id != id })
      }
      #(cards, position + 1)
    })
  list.reverse(reversed)
}

/// The starting board, replayed ahead of the shared log. It is a constant
/// rather than a startup write, so there is nothing to seed and no race
/// between sessions over who seeds.
const starting_board = [
  Added("Design API"),
  Added("Write tests"),
  Added("Build UI"),
  Moved(id: 2, column: Doing),
  Added("Deploy v0.1"),
]

fn read_board(changes: ListStore(Change)) -> Model {
  Model(
    cards: replay(list.append(starting_board, store.get_all(changes, log_key))),
  )
}

/// Append a change; the store broadcasts on its topic, which every session
/// (this one included) turns into `BoardChanged`.
fn record(changes: ListStore(Change), change: Change) -> Effect(Msg) {
  effect.from(fn(_dispatch) { store.append(changes, log_key, change) })
}

// --- Init and update (server) ---

fn init(
  changes: ListStore(Change),
) -> Result(#(State, Effect(Msg)), beacon.InitError) {
  Ok(#(State(model: read_board(changes), dragging: None), effect.none()))
}

fn update(
  changes: ListStore(Change),
  state: State,
  msg: Msg,
) -> #(State, Effect(Msg)) {
  case msg {
    AddCard(title) -> {
      let title = string.trim(title)
      case string.is_empty(title), string.length(title) > max_title_length {
        True, _ -> {
          log.warning("kanban", "Rejected an empty card")
          #(state, effect.none())
        }
        _, True -> {
          log.warning(
            "kanban",
            "Rejected a card title of "
              <> int.to_string(string.length(title))
              <> " characters (max "
              <> int.to_string(max_title_length)
              <> ")",
          )
          #(state, effect.none())
        }
        False, False -> #(state, record(changes, Added(title)))
      }
    }
    DeleteCard(id) ->
      case has_card(state.model, id) {
        True -> #(state, record(changes, Deleted(id)))
        False -> {
          log.warning(
            "kanban",
            "Ignored delete of unknown card " <> int.to_string(id),
          )
          #(state, effect.none())
        }
      }
    DragStart(id) ->
      case has_card(state.model, id) {
        True -> #(State(..state, dragging: Some(id)), effect.none())
        False -> {
          log.warning(
            "kanban",
            "Ignored drag of unknown card " <> int.to_string(id),
          )
          #(State(..state, dragging: None), effect.none())
        }
      }
    DropOn(column) ->
      case state.dragging {
        None -> {
          log.warning(
            "kanban",
            "Ignored a drop on " <> column_slug(column) <> " with no drag",
          )
          #(state, effect.none())
        }
        Some(id) ->
          case has_card(state.model, id) {
            True -> {
              log.info(
                "kanban",
                "Moving card "
                  <> int.to_string(id)
                  <> " to "
                  <> column_slug(column),
              )
              #(
                State(..state, dragging: None),
                record(changes, Moved(id:, column:)),
              )
            }
            // Another session deleted the card mid-drag.
            False -> {
              log.warning(
                "kanban",
                "Ignored a drop of card "
                  <> int.to_string(id)
                  <> ", which no longer exists",
              )
              #(State(..state, dragging: None), effect.none())
            }
          }
      }
    DragEnd -> #(State(..state, dragging: None), effect.none())
    BoardChanged -> #(State(..state, model: read_board(changes)), effect.none())
    // `update_local` handles these in the browser and never forwards them.
    DraftChanged(_) | DragOver(_) -> #(state, effect.none())
  }
}

fn has_card(model: Model, id: Int) -> Bool {
  list.any(model.cards, fn(card) { card.id == id })
}

fn sync(state: State) -> Model {
  state.model
}

// --- Local (browser) ---

pub fn init_local(_model: Model) -> Local {
  Local(draft: "", dragging: None, over: None)
}

pub fn update_local(
  _model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    DraftChanged(text) -> local.handled(Local(..local, draft: text))
    AddCard(title) ->
      case string.trim(title) {
        "" -> local.handled(local)
        _ -> local.forward(Local(..local, draft: ""))
      }
    DragStart(id) -> local.forward(Local(..local, dragging: Some(id)))
    // `dragover` fires many times a second; only a change of column
    // re-renders, and none of it reaches the server.
    DragOver(column) -> local.handled(Local(..local, over: Some(column)))
    DropOn(_) | DragEnd ->
      local.forward(Local(..local, dragging: None, over: None))
    DeleteCard(_) | BoardChanged -> local.forward(local)
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
      html.h1([], [html.text("Kanban Board")]),
      html.p(
        [attribute.styles([#("color", "#666"), #("margin-bottom", "1rem")])],
        [
          html.text("Drag cards between columns"),
        ],
      ),
      html.form(
        [
          event.on_submit(fn(_fields) { AddCard(local.draft) }),
          attribute.styles([
            #("display", "flex"),
            #("gap", "8px"),
            #("margin-bottom", "1.5rem"),
          ]),
        ],
        [
          html.input([
            attribute.type_("text"),
            attribute.placeholder("New card title..."),
            attribute.aria("label", "New card title"),
            attribute.value(local.draft),
            event.on_input(DraftChanged),
            attribute.styles([
              #("flex", "1"),
              #("padding", "10px"),
              #("border", "1px solid #ddd"),
              #("border-radius", "6px"),
              #("font-size", "14px"),
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
                #("font-size", "14px"),
                #("font-weight", "500"),
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
        list.map(columns, fn(column) { render_column(model, local, column) }),
      ),
    ],
  )
}

fn render_column(model: Model, local: Local, column: Column) -> Element(Msg) {
  let cards = list.filter(model.cards, fn(card) { card.column == column })
  let outline = case local.dragging, local.over == Some(column) {
    Some(_), True -> "2px dashed #2196F3"
    _, _ -> "2px solid transparent"
  }
  html.div(
    [
      event.on_drag_over(DragOver(column)),
      event.on_drop(DropOn(column)),
      attribute.data("column", column_slug(column)),
      attribute.styles([
        #("background", column_colour(column)),
        #("border-radius", "12px"),
        #("padding", "1rem"),
        #("min-height", "250px"),
        #("outline", outline),
      ]),
    ],
    [
      html.h3(
        [
          attribute.styles([
            #("margin", "0 0 1rem 0"),
            #("color", "#555"),
            #("font-size", "0.9rem"),
            #("text-transform", "uppercase"),
            #("letter-spacing", "0.5px"),
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
            render_card(card, local.dragging == Some(card.id)),
          )
        }),
      ),
    ],
  )
}

fn render_card(card: Card, is_dragging: Bool) -> Element(Msg) {
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
        #("padding", "12px 16px"),
        #("border-radius", "8px"),
        #("border", "1px solid #e0e0e0"),
        #("cursor", "grab"),
        #("display", "flex"),
        #("justify-content", "space-between"),
        #("align-items", "center"),
        #("box-shadow", "0 1px 3px rgba(0,0,0,0.08)"),
        #("opacity", opacity),
      ]),
    ],
    [
      html.span(
        [attribute.styles([#("font-size", "14px"), #("color", "#333")])],
        [
          html.text(card.title),
        ],
      ),
      html.button(
        [
          event.on_click(DeleteCard(card.id)),
          attribute.aria("label", "Delete " <> card.title),
          attribute.styles([
            #("background", "none"),
            #("border", "none"),
            #("color", "#bbb"),
            #("cursor", "pointer"),
            #("font-size", "18px"),
            #("padding", "0 4px"),
            #("line-height", "1"),
          ]),
        ],
        [html.text("x")],
      ),
    ],
  )
}

// --- Start ---

pub fn main() {
  let changes = store.new_list("kanban_changes")
  let assert Ok(Nil) =
    beacon.full_application(
      init: fn(_ctx) { init(changes) },
      update: fn(state, msg) { update(changes, state, msg) },
      sync:,
      local: local.layer(init: init_local, update: update_local),
      view:,
    )
    |> beacon.title(fn(_model) { "Kanban Board" })
    |> beacon.subscriptions(fn(_state) { [store.list_topic(changes)] })
    |> beacon.on_notify(fn(_topic) { BoardChanged })
    |> beacon.head_html(favicon)
    |> beacon.start(8080)
    as "beacon.start failed (it logs the error)"
}
