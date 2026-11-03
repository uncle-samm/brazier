import beacon/attribute
import beacon/element.{type Element}
import beacon/html
import gleam/int

pub fn view(visits: Int) -> Element(msg) {
  html.section([], [
    html.h1([], [html.text("Stats")]),
    html.p([attribute.data("testid", "visits")], [
      html.text("Route changes observed: " <> int.to_string(visits)),
    ]),
  ])
}
