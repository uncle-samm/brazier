/// Multi-file domains, demonstrating:
/// - `brazier.simple` with a Model built from types in other modules
///   (`auth.User`, `List(items.Item)`);
/// - the build following those modules: it generates the codec for their
///   types and compiles the functions `update` and `view` call from them
///   (`auth.parse_role`, `auth.role_label`) to JavaScript.
import brazier
import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/log
import domains/auth
import domains/items
import gleam/int
import gleam/list
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

pub type Model {
  Model(user: auth.User, items: List(items.Item), next_id: Int, input: String)
}

pub type Msg {
  SetInput(String)
  AddItem
  ToggleItem(Int)
  /// The value of the chosen role's `<option>`.
  RoleSelected(String)
}

const max_item_length = 200

fn init(_ctx: brazier.Context) -> Result(Model, brazier.InitError) {
  Ok(Model(
    user: auth.User(
      name: "Alice",
      email: "alice@example.com",
      role: auth.Member,
    ),
    items: [
      items.Item(id: 1, name: "Buy groceries", done: False),
      items.Item(id: 2, name: "Write tests", done: True),
    ],
    next_id: 3,
    input: "",
  ))
}

/// Runs in the browser and on the server, so it is pure apart from logging.
pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    SetInput(text) -> Model(..model, input: text)
    AddItem -> add_item(model)
    ToggleItem(id) ->
      case list.any(model.items, fn(item) { item.id == id }) {
        True ->
          Model(
            ..model,
            items: list.map(model.items, fn(item) {
              case item.id == id {
                True -> items.Item(..item, done: !item.done)
                False -> item
              }
            }),
          )
        False -> {
          log.warning(
            "domains",
            "Ignored a toggle of unknown item " <> int.to_string(id),
          )
          model
        }
      }
    RoleSelected(value) ->
      case auth.parse_role(value) {
        Ok(role) -> Model(..model, user: auth.User(..model.user, role:))
        Error(Nil) -> {
          log.warning("domains", "Rejected unknown role " <> value)
          model
        }
      }
  }
}

fn add_item(model: Model) -> Model {
  let name = string.trim(model.input)
  case string.is_empty(name), string.length(name) > max_item_length {
    True, _ -> model
    _, True -> {
      log.warning(
        "domains",
        "Rejected an item of "
          <> int.to_string(string.length(name))
          <> " characters (max "
          <> int.to_string(max_item_length)
          <> ")",
      )
      model
    }
    False, False ->
      Model(
        ..model,
        items: list.append(model.items, [
          items.Item(id: model.next_id, name:, done: False),
        ]),
        next_id: model.next_id + 1,
        input: "",
      )
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class("domains-app"),
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "600px"),
        #("margin", "2rem auto"),
        #("padding", "0 1rem"),
      ]),
    ],
    [
      html.h1([], [html.text("Multi-File Domains")]),
      html.div([attribute.class("user-info")], [
        html.h2([], [html.text("User: " <> model.user.name)]),
        html.p([], [html.text("Email: " <> model.user.email)]),
        html.p([], [html.text("Role: " <> auth.role_label(model.user.role))]),
        html.select(
          [attribute.aria("label", "Role"), event.on_change(RoleSelected)],
          list.map(auth.roles, fn(role) {
            html.option(
              [
                attribute.value(auth.role_value(role)),
                attribute.selected(role == model.user.role),
              ],
              [html.text(auth.role_label(role))],
            )
          }),
        ),
      ]),
      html.div([attribute.class("items")], [
        html.h2([], [
          html.text("Items (" <> int.to_string(list.length(model.items)) <> ")"),
        ]),
        html.div([], list.map(model.items, view_item)),
        html.form(
          [
            attribute.class("add-item"),
            event.on_submit(fn(_fields) { AddItem }),
          ],
          [
            html.input([
              attribute.type_("text"),
              attribute.placeholder("New item..."),
              attribute.aria("label", "New item"),
              attribute.attribute("maxlength", int.to_string(max_item_length)),
              attribute.value(model.input),
              event.on_input(SetInput),
            ]),
            html.button([attribute.type_("submit")], [html.text("Add")]),
          ],
        ),
      ]),
    ],
  )
}

fn view_item(item: items.Item) -> Element(Msg) {
  html.div(
    [
      attribute.class("item"),
      attribute.styles(case item.done {
        True -> [#("text-decoration", "line-through"), #("opacity", "0.6")]
        False -> []
      }),
      attribute.style("cursor", "pointer"),
      event.on_click(ToggleItem(item.id)),
    ],
    [
      html.text(
        case item.done {
          True -> "[x] "
          False -> "[ ] "
        }
        <> item.name,
      ),
    ],
  )
}

pub fn main() {
  let assert Ok(Nil) =
    brazier.simple(init:, update:, view:)
    |> brazier.title(fn(_model) { "Brazier Domains" })
    |> brazier.head_html(favicon)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
