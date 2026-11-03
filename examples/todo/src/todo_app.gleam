/// Todo App, demonstrating:
/// - a draft and a filter kept in Local state (no server traffic while
///   typing or filtering);
/// - a shared todo list for every session, kept in a `beacon/store` list as
///   an append-only change log, so concurrent sessions never overwrite each
///   other's changes;
/// - a PubSub subscription that re-reads the log when another session
///   changes it;
/// - derived values in the view ("items left" is not stored).
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
import gleam/string

// --- Types ---

pub type Todo {
  Todo(id: Int, text: String, completed: Bool)
}

/// Synced to the browser.
pub type Model {
  Model(todos: List(Todo))
}

pub type Filter {
  All
  Active
  Completed
}

/// Client-only.
pub type Local {
  Local(draft: String, filter: Filter)
}

pub type Msg {
  DraftChanged(String)
  SetFilter(Filter)
  AddTodo(String)
  ToggleTodo(Int)
  DeleteTodo(Int)
  ClearCompleted
  /// Another session (or this one) changed the shared log.
  TodosChanged
}

/// One entry of the shared change log. A todo's id is the log position of
/// its `Added` change, which is the same for every reader because a local
/// list store returns values in insertion order. Server-only: the log is
/// never sent to the browser.
pub type Change {
  Added(text: String)
  Toggled(id: Int)
  Deleted(id: Int)
  ClearedCompleted
}

const log_key = "todos"

const max_todo_length = 200

// --- Shared log ---

fn replay(changes: List(Change)) -> List(Todo) {
  let #(reversed, _position) =
    list.fold(changes, #([], 0), fn(acc, change) {
      let #(todos, position) = acc
      let todos = case change {
        Added(text) -> [Todo(id: position, text:, completed: False), ..todos]
        Toggled(id) ->
          list.map(todos, fn(t) {
            case t.id == id {
              True -> Todo(..t, completed: !t.completed)
              False -> t
            }
          })
        Deleted(id) -> list.filter(todos, fn(t) { t.id != id })
        ClearedCompleted -> list.filter(todos, fn(t) { !t.completed })
      }
      #(todos, position + 1)
    })
  list.reverse(reversed)
}

fn read_todos(changes: ListStore(Change)) -> List(Todo) {
  replay(store.get_all(changes, log_key))
}

/// Append a change; the store broadcasts on its topic, which every session
/// (this one included) turns into `TodosChanged`.
fn record(changes: ListStore(Change), change: Change) -> Effect(Msg) {
  effect.from(fn(_dispatch) { store.append(changes, log_key, change) })
}

// --- Init and update (server) ---

fn init(
  changes: ListStore(Change),
) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model(todos: read_todos(changes)), effect.none()))
}

fn update(
  changes: ListStore(Change),
  model: Model,
  msg: Msg,
) -> #(Model, Effect(Msg)) {
  case msg {
    AddTodo(text) -> {
      let text = string.trim(text)
      case string.is_empty(text), string.length(text) > max_todo_length {
        True, _ -> {
          log.warning("todo_app", "Rejected an empty todo")
          #(model, effect.none())
        }
        _, True -> {
          log.warning(
            "todo_app",
            "Rejected a todo of "
              <> int.to_string(string.length(text))
              <> " characters (max "
              <> int.to_string(max_todo_length)
              <> ")",
          )
          #(model, effect.none())
        }
        False, False -> #(model, record(changes, Added(text)))
      }
    }
    ToggleTodo(id) -> change_existing(changes, model, id, Toggled(id), "toggle")
    DeleteTodo(id) -> change_existing(changes, model, id, Deleted(id), "delete")
    ClearCompleted -> #(model, record(changes, ClearedCompleted))
    TodosChanged -> #(Model(todos: read_todos(changes)), effect.none())
    // `update_local` handles these in the browser and never forwards them.
    DraftChanged(_) | SetFilter(_) -> #(model, effect.none())
  }
}

fn change_existing(
  changes: ListStore(Change),
  model: Model,
  id: Int,
  change: Change,
  action: String,
) -> #(Model, Effect(Msg)) {
  case list.any(model.todos, fn(t) { t.id == id }) {
    True -> #(model, record(changes, change))
    False -> {
      log.warning(
        "todo_app",
        "Ignored " <> action <> " of unknown todo " <> int.to_string(id),
      )
      #(model, effect.none())
    }
  }
}

// --- Local (browser) ---

pub fn init_local(_model: Model) -> Local {
  Local(draft: "", filter: All)
}

pub fn update_local(
  _model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    DraftChanged(text) -> local.handled(Local(..local, draft: text))
    SetFilter(filter) -> local.handled(Local(..local, filter:))
    AddTodo(text) ->
      case string.trim(text) {
        "" -> local.handled(local)
        _ -> local.forward(Local(..local, draft: ""))
      }
    ToggleTodo(_) | DeleteTodo(_) | ClearCompleted | TodosChanged ->
      local.forward(local)
  }
}

fn sync(model: Model) -> Model {
  model
}

// --- View ---

pub fn view(model: Model, local: Local) -> Element(Msg) {
  let visible = case local.filter {
    All -> model.todos
    Active -> list.filter(model.todos, fn(t) { !t.completed })
    Completed -> list.filter(model.todos, fn(t) { t.completed })
  }
  let active_count = list.count(model.todos, fn(t) { !t.completed })
  let has_completed = list.any(model.todos, fn(t) { t.completed })

  html.div(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "500px"),
        #("margin", "2rem auto"),
        #("padding", "0 1rem"),
      ]),
    ],
    [
      html.h1([], [html.text("Todo App")]),
      html.form(
        [
          event.on_submit(fn(_fields) { AddTodo(local.draft) }),
          attribute.styles([
            #("display", "flex"),
            #("gap", "8px"),
            #("margin-bottom", "1rem"),
          ]),
        ],
        [
          html.input([
            attribute.type_("text"),
            attribute.placeholder("What needs to be done?"),
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
              ]),
            ],
            [html.text("Add")],
          ),
        ],
      ),
      html.div(
        [
          attribute.styles([
            #("display", "flex"),
            #("gap", "8px"),
            #("margin-bottom", "1rem"),
          ]),
        ],
        [
          filter_button(All, "All", local.filter),
          filter_button(Active, "Active", local.filter),
          filter_button(Completed, "Completed", local.filter),
        ],
      ),
      html.div(
        [],
        list.map(visible, fn(t) {
          element.keyed(int.to_string(t.id), render_todo(t))
        }),
      ),
      html.div(
        [
          attribute.styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("margin-top", "1rem"),
            #("padding-top", "0.5rem"),
            #("border-top", "1px solid #eee"),
            #("color", "#666"),
            #("font-size", "14px"),
          ]),
        ],
        [
          html.span([], [
            html.text(
              int.to_string(active_count)
              <> " item"
              <> case active_count {
                1 -> ""
                _ -> "s"
              }
              <> " left",
            ),
          ]),
          case has_completed {
            True ->
              html.button(
                [
                  event.on_click(ClearCompleted),
                  attribute.styles([
                    #("background", "none"),
                    #("border", "1px solid #ddd"),
                    #("border-radius", "4px"),
                    #("padding", "4px 12px"),
                    #("cursor", "pointer"),
                    #("color", "#666"),
                  ]),
                ],
                [html.text("Clear completed")],
              )
            False -> element.none()
          },
        ],
      ),
    ],
  )
}

fn render_todo(item: Todo) -> Element(Msg) {
  let text_style = case item.completed {
    True -> [#("text-decoration", "line-through"), #("color", "#999")]
    False -> [#("color", "#333")]
  }
  let toggle_background = case item.completed {
    True -> "#4CAF50"
    False -> "white"
  }
  html.div(
    [
      attribute.styles([
        #("display", "flex"),
        #("align-items", "center"),
        #("gap", "8px"),
        #("padding", "8px 0"),
        #("border-bottom", "1px solid #f0f0f0"),
      ]),
    ],
    [
      html.button(
        [
          event.on_click(ToggleTodo(item.id)),
          attribute.aria("label", "Toggle " <> item.text),
          attribute.styles([
            #("width", "24px"),
            #("height", "24px"),
            #("border", "2px solid #ccc"),
            #("border-radius", "50%"),
            #("cursor", "pointer"),
            #("background", toggle_background),
          ]),
        ],
        [],
      ),
      html.span(
        [
          attribute.styles(text_style),
          attribute.styles([#("flex", "1"), #("font-size", "14px")]),
        ],
        [
          html.text(item.text),
        ],
      ),
      html.button(
        [
          event.on_click(DeleteTodo(item.id)),
          attribute.aria("label", "Delete " <> item.text),
          attribute.styles([
            #("background", "none"),
            #("border", "none"),
            #("color", "#e57373"),
            #("cursor", "pointer"),
            #("font-size", "18px"),
          ]),
        ],
        [html.text("x")],
      ),
    ],
  )
}

fn filter_button(
  filter: Filter,
  label: String,
  current: Filter,
) -> Element(Msg) {
  let colours = case filter == current {
    True -> [
      #("background", "#e3f2fd"),
      #("border-color", "#2196F3"),
      #("color", "#2196F3"),
    ]
    False -> [
      #("background", "white"),
      #("border-color", "#ddd"),
      #("color", "#666"),
    ]
  }
  html.button(
    [
      event.on_click(SetFilter(filter)),
      attribute.styles([
        #("padding", "6px 16px"),
        #("border", "1px solid"),
        #("border-radius", "4px"),
        #("cursor", "pointer"),
        ..colours
      ]),
    ],
    [html.text(label)],
  )
}

// --- Start ---

pub fn main() {
  let changes = store.new_list("todo_changes")
  beacon.full_application(
    init: fn(_ctx) { init(changes) },
    update: fn(model, msg) { update(changes, model, msg) },
    sync:,
    local: local.layer(init: init_local, update: update_local),
    view:,
  )
  |> beacon.title(fn(_model) { "Todo App" })
  |> beacon.subscriptions(fn(_model) { [store.list_topic(changes)] })
  |> beacon.on_notify(fn(_topic) { TodosChanged })
  |> beacon.start(8080)
}
