/// Routed: one `Route` type, one `parse`, and `brazier.with_router`.
///
/// The pages are plain view modules imported explicitly; the home page is
/// a nested component whose messages are mapped with `element.map(Home)`.
/// Brazier runs `update(model, RouteChanged(route))` after `init` and on
/// every client navigation, and answers paths `parse` rejects with 404.
import brazier
import brazier/attribute
import brazier/config
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/html
import brazier/log
import brazier/router
import gleam/int
import gleam/string
import gleam/uri.{type Uri}
import routed/pages/about
import routed/pages/home
import routed/pages/settings
import routed/pages/stats

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

const max_name_length = 100

pub type Route {
  HomePage
  AboutPage
  SettingsPage
  StatsPage
}

pub type Model {
  Model(route: Route, home: home.Model, name: String, visits: Int)
}

pub type Msg {
  RouteChanged(Route)
  Home(home.Msg)
  SetName(String)
}

/// The single route declaration.
fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case router.segments(uri) {
    [] -> Ok(HomePage)
    ["about"] -> Ok(AboutPage)
    ["settings"] -> Ok(SettingsPage)
    ["stats"] -> Ok(StatsPage)
    _ -> Error(Nil)
  }
}

pub fn href(route: Route) -> String {
  case route {
    HomePage -> "/"
    AboutPage -> "/about"
    SettingsPage -> "/settings"
    StatsPage -> "/stats"
  }
}

fn init(
  _ctx: brazier.Context,
) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  // `with_router` dispatches RouteChanged for the requested URL before the
  // first render, so this route is only a placeholder.
  Ok(#(
    Model(route: HomePage, home: home.init(), name: "", visits: 0),
    effect.none(),
  ))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  let model = case msg {
    RouteChanged(route) -> {
      log.debug("routed", "Route changed to " <> href(route))
      Model(..model, route:, visits: model.visits + 1)
    }
    Home(child_msg) -> Model(..model, home: home.update(model.home, child_msg))
    SetName(name) ->
      case string.length(name) > max_name_length {
        True -> {
          log.warning(
            "routed",
            "Refusing a name of "
              <> int.to_string(string.length(name))
              <> " characters (limit "
              <> int.to_string(max_name_length)
              <> ")",
          )
          model
        }
        False -> Model(..model, name:)
      }
  }
  #(model, effect.none())
}

pub fn view(model: Model) -> Element(Msg) {
  html.main(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "780px"),
        #("margin", "32px auto"),
        #("padding", "0 16px"),
      ]),
    ],
    [
      html.nav(
        [
          attribute.styles([
            #("display", "flex"),
            #("gap", "12px"),
            #("margin-bottom", "24px"),
          ]),
        ],
        [
          html.a([attribute.href(href(HomePage))], [html.text("Home")]),
          html.a([attribute.href(href(AboutPage))], [html.text("About")]),
          html.a([attribute.href(href(SettingsPage))], [html.text("Settings")]),
          html.a([attribute.href(href(StatsPage))], [html.text("Stats")]),
        ],
      ),
      // Keyed by route: a route change replaces the page's DOM instead of
      // morphing one page's nodes into the next page.
      element.keyed(href(model.route), case model.route {
        HomePage -> home.view(model.home) |> element.map(Home)
        AboutPage -> about.view()
        SettingsPage -> settings.view(model.name, SetName)
        StatsPage -> stats.view(model.visits)
      }),
    ],
  )
}

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let assert Ok(Nil) =
    brazier.application(init:, update:, view:)
    |> brazier.with_router(parse: parse_route, on_change: RouteChanged)
    |> brazier.title(fn(_model) { "Brazier Routed" })
    |> brazier.head_html(favicon)
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
