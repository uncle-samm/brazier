import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html

pub fn view(name: String, on_input: fn(String) -> msg) -> Element(msg) {
  html.section([], [
    html.h1([], [html.text("Settings")]),
    html.label([], [
      html.text("Display name"),
      html.input([
        attribute.type_("text"),
        attribute.value(name),
        event.on_input(on_input),
        attribute.data("testid", "name-input"),
      ]),
    ]),
    html.p([attribute.data("testid", "saved-name")], [
      html.text("Name: " <> name),
    ]),
  ])
}
