/// The settings page: a component with a public Model and a private audit
/// log. Only `view` and the Model reach the browser.
import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/log
import gleam/int
import gleam/list
import gleam/string

const signing_key = "route_settings_private_key_must_not_ship"

const max_email_length = 254

/// The server keeps the newest audit entries up to this many.
const max_audit_entries = 100

pub type Model {
  Model(email: String, saved: Int, last_saved: String)
}

/// Server-only: never synced.
pub type Server {
  Server(
    signing_key: String,
    /// Newest first, at most `max_audit_entries`.
    audit_entries: List(String),
  )
}

pub type Msg {
  SetEmail(String)
  SaveSettings
}

pub fn init() -> Model {
  Model(email: "ada@example.test", saved: 0, last_saved: "Not saved yet")
}

pub fn init_server() -> Server {
  Server(signing_key:, audit_entries: [])
}

pub fn update(model: Model, server: Server, msg: Msg) -> #(Model, Server) {
  case msg {
    SetEmail(email) ->
      case string.length(email) > max_email_length {
        True -> {
          log.warning(
            "settings",
            "Refusing an email of "
              <> int.to_string(string.length(email))
              <> " characters (limit "
              <> int.to_string(max_email_length)
              <> ")",
          )
          #(model, server)
        }
        False -> #(Model(..model, email:), server)
      }
    SaveSettings ->
      case string.contains(model.email, "@") {
        False -> {
          log.warning("settings", "Refusing to save an email without \"@\"")
          #(Model(..model, last_saved: "Not saved: enter an email"), server)
        }
        True -> {
          let saved = model.saved + 1
          log.info(
            "settings",
            "Saved settings (save " <> int.to_string(saved) <> ")",
          )
          #(
            Model(..model, saved:, last_saved: "Saved " <> model.email),
            Server(
              ..server,
              audit_entries: list.take(
                ["save-" <> int.to_string(saved), ..server.audit_entries],
                max_audit_entries,
              ),
            ),
          )
        }
      }
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.section([], [
    html.h1([], [html.text("Settings")]),
    html.p([], [
      html.text("The audit log and signing key are route-local server state."),
    ]),
    html.label([], [
      html.text("Email"),
      html.input([
        attribute.data("testid", "settings-email"),
        attribute.type_("email"),
        attribute.value(model.email),
        event.on_input(SetEmail),
      ]),
    ]),
    html.button([event.on_click(SaveSettings)], [html.text("Save settings")]),
    html.p([attribute.data("testid", "settings-last-saved")], [
      html.text(model.last_saved),
    ]),
    html.p([attribute.data("testid", "settings-save-count")], [
      html.text("Saves: " <> int.to_string(model.saved)),
    ]),
  ])
}
