import brazier/element.{type Element}
import brazier/html

pub fn view() -> Element(msg) {
  html.section([], [
    html.h1([], [html.text("About")]),
    html.p([], [
      html.text(
        "This page is imported explicitly from routed/pages/about. Brazier does not scan the filesystem for routes: the app's Route type and parse function are the only route declaration.",
      ),
    ]),
  ])
}
