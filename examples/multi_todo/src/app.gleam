/// Multi-file Todo: the TodoItem and Filter types live in a separate module,
/// `domains/task.gleam`, and the codegen follows them there.
///
/// - The todos are per session, held by the session's server process.
/// - The draft and the filter are Local: typing and filtering never reach
///   the server.
import brazier
import brazier/attribute
import brazier/config
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import domains/task
import gleam/int
import gleam/list
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

/// Synced to the browser.
pub type Model {
  Model(todos: List(task.TodoItem), next_id: Int)
}

/// Client-only.
pub type Local {
  Local(draft: String, filter: task.Filter)
}

pub type Msg {
  DraftChanged(String)
  SetFilter(task.Filter)
  AddTodo(String)
  ToggleTodo(Int)
  DeleteTodo(Int)
  ClearCompleted
}

const max_todo_length = 200

// --- Init and update (server) ---

fn init(
  _ctx: brazier.Context,
) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(
    Model(
      todos: [
        task.TodoItem(id: 1, text: "Learn Gleam", completed: True),
        task.TodoItem(id: 2, text: "Build with Brazier", completed: False),
        task.TodoItem(id: 3, text: "Ship it", completed: False),
      ],
      next_id: 4,
    ),
    effect.none(),
  ))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  let model = case msg {
    AddTodo(text) -> add_todo(model, string.trim(text))
    ToggleTodo(id) ->
      change_existing(model, id, "toggle", fn(todos) {
        list.map(todos, fn(t) {
          case t.id == id {
            True -> task.TodoItem(..t, completed: !t.completed)
            False -> t
          }
        })
      })
    DeleteTodo(id) ->
      change_existing(model, id, "delete", fn(todos) {
        list.filter(todos, fn(t) { t.id != id })
      })
    ClearCompleted ->
      Model(..model, todos: list.filter(model.todos, fn(t) { !t.completed }))
    // `update_local` handles these in the browser and never forwards them.
    DraftChanged(_) | SetFilter(_) -> model
  }
  #(model, effect.none())
}

fn add_todo(model: Model, text: String) -> Model {
  case string.is_empty(text), string.length(text) > max_todo_length {
    True, _ -> {
      log.warning("multi_todo", "Rejected an empty todo")
      model
    }
    _, True -> {
      log.warning(
        "multi_todo",
        "Rejected a todo of "
          <> int.to_string(string.length(text))
          <> " characters (max "
          <> int.to_string(max_todo_length)
          <> ")",
      )
      model
    }
    False, False -> {
      let item = task.TodoItem(id: model.next_id, text:, completed: False)
      Model(todos: list.append(model.todos, [item]), next_id: model.next_id + 1)
    }
  }
}

fn change_existing(
  model: Model,
  id: Int,
  action: String,
  change: fn(List(task.TodoItem)) -> List(task.TodoItem),
) -> Model {
  case list.any(model.todos, fn(t) { t.id == id }) {
    True -> Model(..model, todos: change(model.todos))
    False -> {
      log.warning(
        "multi_todo",
        "Ignored " <> action <> " of unknown todo " <> int.to_string(id),
      )
      model
    }
  }
}

fn sync(model: Model) -> Model {
  model
}

// --- Local (browser) ---

pub fn init_local(_model: Model) -> Local {
  Local(draft: "", filter: task.All)
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
    ToggleTodo(_) | DeleteTodo(_) | ClearCompleted -> local.forward(local)
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> Element(Msg) {
  let visible = case local.filter {
    task.All -> model.todos
    task.Active -> list.filter(model.todos, fn(t) { !t.completed })
    task.Completed -> list.filter(model.todos, fn(t) { t.completed })
  }
  let remaining = list.count(model.todos, fn(t) { !t.completed })

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
      html.h1([], [html.text("Multi-File Todo")]),
      html.p([attribute.style("color", "#666")], [
        html.text("TodoItem + Filter types from domains/task.gleam"),
      ]),
      html.form(
        [
          event.on_submit(fn(_fields) { AddTodo(local.draft) }),
          attribute.styles([
            #("display", "flex"),
            #("gap", "8px"),
            #("margin", "1rem 0"),
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
          filter_button("All", local.filter, task.All),
          filter_button("Active", local.filter, task.Active),
          filter_button("Completed", local.filter, task.Completed),
          html.button(
            [
              event.on_click(ClearCompleted),
              attribute.styles([
                #("margin-left", "auto"),
                #("padding", "8px 16px"),
                #("background", "#f44336"),
                #("color", "white"),
                #("border", "none"),
                #("border-radius", "6px"),
                #("cursor", "pointer"),
              ]),
            ],
            [html.text("Clear Done")],
          ),
        ],
      ),
      html.div(
        [],
        list.map(visible, fn(item) {
          element.keyed(int.to_string(item.id), view_item(item))
        }),
      ),
      html.p([attribute.styles([#("color", "#999"), #("margin-top", "1rem")])], [
        html.text(int.to_string(remaining) <> " items remaining"),
      ]),
    ],
  )
}

fn filter_button(
  label: String,
  current: task.Filter,
  this: task.Filter,
) -> Element(Msg) {
  let colours = case current == this {
    True -> [#("background", "#1976d2"), #("color", "white")]
    False -> [#("background", "#eee"), #("color", "#333")]
  }
  html.button(
    [
      event.on_click(SetFilter(this)),
      attribute.styles([
        #("padding", "8px 16px"),
        #("border", "none"),
        #("border-radius", "6px"),
        #("cursor", "pointer"),
        ..colours
      ]),
    ],
    [html.text(label)],
  )
}

fn view_item(item: task.TodoItem) -> Element(Msg) {
  let text_style = case item.completed {
    True -> [#("text-decoration", "line-through"), #("opacity", "0.5")]
    False -> []
  }
  html.div(
    [
      attribute.styles([
        #("display", "flex"),
        #("align-items", "center"),
        #("gap", "12px"),
        #("padding", "12px"),
        #("border-bottom", "1px solid #eee"),
      ]),
    ],
    [
      html.span(
        [
          event.on_click(ToggleTodo(item.id)),
          attribute.aria("label", "Toggle " <> item.text),
          attribute.styles([#("cursor", "pointer"), #("font-size", "20px")]),
        ],
        [
          html.text(case item.completed {
            True -> "☑"
            False -> "☐"
          }),
        ],
      ),
      html.span([attribute.styles([#("flex", "1"), ..text_style])], [
        html.text(item.text),
      ]),
      html.button(
        [
          event.on_click(DeleteTodo(item.id)),
          attribute.aria("label", "Delete " <> item.text),
          attribute.styles([
            #("background", "none"),
            #("border", "none"),
            #("color", "#ccc"),
            #("cursor", "pointer"),
            #("font-size", "18px"),
          ]),
        ],
        [html.text("x")],
      ),
    ],
  )
}

// --- Start ---

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let assert Ok(Nil) =
    brazier.full_application(
      init:,
      update:,
      sync:,
      local: local.layer(init: init_local, update: update_local),
      view:,
    )
    |> brazier.title(fn(_model) { "Multi-File Todo" })
    |> brazier.head_html(favicon)
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
