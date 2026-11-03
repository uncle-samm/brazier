import beacon/element.{type Element}
import beacon/html

pub fn view() -> Element(msg) {
  html.section([], [
    html.h1([], [html.text("About")]),
    html.p([], [
      html.text(
        "This page is imported explicitly from routed/pages/about. Beacon does not scan the filesystem for routes: the app's Route type and parse function are the only route declaration.",
      ),
    ]),
  ])
}
