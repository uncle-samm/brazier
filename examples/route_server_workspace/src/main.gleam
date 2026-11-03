/// Route Server Workspace: routed pages that are components with private
/// server state.
///
/// Each page module has a public Model and a server-only `Server` record.
/// The root `Session` holds both pages' server records next to the Model;
/// `sync` sends only the Model, and the build compiles only what `view`
/// reaches, so the pages' signing keys never reach the browser.
import beacon
import beacon/attribute
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/html
import beacon/local
import beacon/router
import gleam/int
import gleam/uri.{type Uri}
import route_server_workspace/pages/accounts
import route_server_workspace/pages/settings

pub type Route {
  AccountsPage
  SettingsPage
}

pub type Model {
  Model(
    route: Route,
    accounts: accounts.Model,
    settings: settings.Model,
    visits: Int,
  )
}

/// What the server holds per session. Only `model` is synced.
pub type Session {
  Session(model: Model, accounts: accounts.Server, settings: settings.Server)
}

pub type Msg {
  RouteChanged(Route)
  Accounts(accounts.Msg)
  Settings(settings.Msg)
}

fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case router.segments(uri) {
    [] -> Ok(AccountsPage)
    ["settings"] -> Ok(SettingsPage)
    _ -> Error(Nil)
  }
}

pub fn href(route: Route) -> String {
  case route {
    AccountsPage -> "/"
    SettingsPage -> "/settings"
  }
}

fn init(
  _ctx: beacon.Context,
) -> Result(#(Session, Effect(Msg)), beacon.InitError) {
  // `with_router` dispatches RouteChanged for the requested URL before the
  // first render, so this route is only a placeholder.
  Ok(#(
    Session(
      model: Model(
        route: AccountsPage,
        accounts: accounts.init(),
        settings: settings.init(),
        visits: 0,
      ),
      accounts: accounts.init_server(),
      settings: settings.init_server(),
    ),
    effect.none(),
  ))
}

fn update(session: Session, msg: Msg) -> #(Session, Effect(Msg)) {
  let model = session.model
  let session = case msg {
    RouteChanged(route) ->
      Session(
        ..session,
        model: Model(..model, route:, visits: model.visits + 1),
      )
    Accounts(child_msg) -> {
      let #(child, server) =
        accounts.update(model.accounts, session.accounts, child_msg)
      Session(
        ..session,
        model: Model(..model, accounts: child),
        accounts: server,
      )
    }
    Settings(child_msg) -> {
      let #(child, server) =
        settings.update(model.settings, session.settings, child_msg)
      Session(
        ..session,
        model: Model(..model, settings: child),
        settings: server,
      )
    }
  }
  #(session, effect.none())
}

fn sync(session: Session) -> Model {
  session.model
}

pub fn view(model: Model, _local: Nil) -> Element(Msg) {
  html.main(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "820px"),
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
          html.a([attribute.href(href(AccountsPage))], [html.text("Accounts")]),
          html.a([attribute.href(href(SettingsPage))], [html.text("Settings")]),
        ],
      ),
      html.p([attribute.data("testid", "route-visits")], [
        html.text("Route visits: " <> int.to_string(model.visits)),
      ]),
      // Keyed by route: a route change replaces the page's DOM instead of
      // morphing one page's nodes into the next page.
      element.keyed(href(model.route), case model.route {
        AccountsPage -> accounts.view(model.accounts) |> element.map(Accounts)
        SettingsPage -> settings.view(model.settings) |> element.map(Settings)
      }),
    ],
  )
}

pub fn main() {
  beacon.full_application(init:, update:, sync:, local: local.none(), view:)
  |> beacon.with_router(parse: parse_route, on_change: RouteChanged)
  |> beacon.title(fn(_model) { "Route Server Workspace" })
  |> beacon.start(8080)
}
