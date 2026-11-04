# Routing

A Brazier app routes by URL with one `Route` type, one `parse` function and
`brazier.with_router`. This is LiveView's `mount` plus `handle_params`: the
route is part of the model, and `update` handles route changes like any other
message. Brazier does not discover routes from the file system; every page is
an explicit `case` branch.

## Declaring Routes

<!-- docs-check: wrap
import brazier/element.{type Element}

{{block}}

pub type Model {
  Model(route: Route)
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(route: HomePage), effect.none()))
}

fn update(_model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RouteChanged(route) -> #(Model(route:), effect.none())
  }
}

fn view(_model: Model) -> Element(Msg) {
  element.text("page")
}
-->
```gleam
import brazier
import brazier/effect.{type Effect}
import brazier/router
import gleam/list
import gleam/uri.{type Uri}

pub type Route {
  HomePage
  UserPage(id: String)
  SearchPage(query: String)
}

pub type Msg {
  RouteChanged(Route)
  // ...
}

fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case router.segments(uri) {
    [] -> Ok(HomePage)
    ["users", id] -> Ok(UserPage(id:))
    ["search"] ->
      case list.key_find(router.query(uri), "q") {
        Ok(query) -> Ok(SearchPage(query:))
        Error(Nil) -> Ok(SearchPage(query: ""))
      }
    _ -> Error(Nil)
  }
}

pub fn main() {
  brazier.application(init:, update:, view:)
  |> brazier.with_router(parse: parse_route, on_change: RouteChanged)
  |> brazier.start(8080)
}
```

- **`router.segments(uri)`** returns the percent-decoded path segments, with
  empty and dot segments removed: `/users/J%C3%BCrgen/` becomes
  `["users", "Jürgen"]`.
- **`router.query(uri)`** returns the percent-decoded query parameters in
  order: `?q=a%20b&page=2` becomes `[#("q", "a b"), #("page", "2")]`.

Brazier checks the URL's encoding before it calls `parse`, so both functions
always succeed inside `parse`.

## When `on_change` Runs

Brazier runs `update(model, on_change(route))`:

1. right after `init`, before the first render, for the requested URL, on both
   the HTML render and the connected mount;
2. on every client navigation: a same-origin link click, the back and forward
   buttons, and `router.push` or `router.replace`.

`init` therefore never parses the URL itself. Put a placeholder route in the
initial model; `on_change` replaces it before anything is rendered.

<!-- docs-check: wrap
import brazier
import brazier/effect.{type Effect}
import brazier/element.{type Element}

pub type Route {
  HomePage
  UserPage(id: String)
}

pub type User {
  User(id: String, name: String)
}

pub type Model {
  Model(route: Route, users: List(User))
}

pub type Msg {
  RouteChanged(Route)
}

{{block}}

fn load_user(_id: String) -> Effect(Msg) {
  effect.none()
}

fn view(_model: Model) -> Element(Msg) {
  element.text("page")
}

pub fn main() {
  brazier.application(init:, update:, view:)
  |> brazier.start(8080)
}
-->
```gleam
fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(route: HomePage, users: []), effect.none()))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RouteChanged(UserPage(id:) as route) ->
      #(Model(..model, route:), load_user(id))
    RouteChanged(route) -> #(Model(..model, route:), effect.none())
    // ...
  }
}
```

An effect returned for the route message runs as any other effect does: it
is dropped on the HTML render and performed on the connected mount and on
later navigations.

## Unknown and Malformed URLs

- A URL that `parse` rejects with `Error(Nil)` is answered with **404**.
- A URL whose percent-encoding does not decode is answered with **400**.

On a client navigation to such a URL, the server tells the browser to load
the page, so the 404 or 400 comes from a real HTTP response.

## Links

Plain `<a href>` links to the same host navigate without a page load:

<!-- docs-check: wrap
import brazier/attribute
import brazier/element.{type Element}
import brazier/html

pub fn profile_link() -> Element(msg) {
  {{block}}
}
-->
```gleam
html.a([attribute.href("/users/7")], [html.text("Profile")])
```

The browser pushes a history entry and sends the new path over the
WebSocket. A link opens a normal page load instead when it has a modifier key
held, a `target` other than `_self`, a `download` attribute, or a
`data-brazier-external` attribute. Links to other hosts are not intercepted.

## Navigation Effects

`update` navigates with effects from `brazier/router`:

| Effect | LiveView | Behaviour |
|---|---|---|
| `router.push(path)` | `push_patch` | New history entry, no page load; `on_change` runs |
| `router.replace(path)` | `push_patch(replace: true)` | Replaces the history entry, no page load; `on_change` runs |
| `router.redirect(url)` | `redirect` | Full page load; ends the session |

All three take same-origin paths only (`/users/7?tab=posts`, never `//host`,
an absolute URL, `javascript:` or `data:`). Any other value is logged as an
error and not sent. Use `redirect` when the browser must make a real HTTP
request, for example to receive a `Set-Cookie` header after login.

<!-- docs-check: wrap
import brazier/effect.{type Effect}
import brazier/router

pub type User {
  User(id: String)
}

pub type Model {
  Model
}

pub type Msg {
  Saved(User)
  LoggedOut
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    {{block}}
  }
}
-->
```gleam
Saved(user) -> #(model, router.push("/users/" <> user.id))
LoggedOut -> #(model, router.redirect("/login"))
```

## Pages as Child Modules

A page with its own state and messages is a child module with its own
`Model`, `Msg`, `update` and `view`. The parent keeps the child's model in a
field, wraps its messages in one constructor, and maps the child's view and
effects (see [COMPONENTS.md](COMPONENTS.md)). The child:

<!-- docs-check: module routed/pages/home -->
```gleam
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import gleam/int

pub type Model {
  Model(visits: Int)
}

pub type Msg {
  Visited
}

pub fn init() -> Model {
  Model(visits: 0)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Visited -> #(Model(visits: model.visits + 1), effect.none())
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.button([event.on_click(Visited)], [
    html.text("Visits: " <> int.to_string(model.visits)),
  ])
}
```

The parent:

<!-- docs-check: wrap
{{block}}

pub type Route {
  HomePage
  AboutPage
}
-->
```gleam
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/html
import routed/pages/home

pub type Model {
  Model(route: Route, home: home.Model)
}

pub type Msg {
  RouteChanged(Route)
  Home(home.Msg)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RouteChanged(route) -> #(Model(..model, route:), effect.none())
    Home(child) -> {
      let #(home, effect) = home.update(model.home, child)
      #(Model(..model, home:), effect.map(effect, Home))
    }
  }
}

pub fn view(model: Model) -> Element(Msg) {
  element.keyed(route_key(model.route), case model.route {
    HomePage -> home.view(model.home) |> element.map(Home)
    AboutPage -> about_page()
  })
}

fn route_key(route: Route) -> String {
  case route {
    HomePage -> "/"
    AboutPage -> "/about"
  }
}

/// A page without state is a plain function returning an `Element(msg)`.
fn about_page() -> Element(msg) {
  html.p([], [html.text("About this app")])
}
```

Key the page by its route with `element.keyed`. The browser updates the DOM
by morphing the old tree into the new one, and without a key it reuses one
page's nodes for the next page by position, carrying over focus and input
state and moving reused nodes (which the browser reports as layout shift).
A different key makes a route change replace the page's nodes.

The examples show the pattern at three sizes:

- `examples/routed`: four pages in `src/routed/pages/`, one of them a nested
  child module.
- `examples/routed_workspace`: three routes in one module, with a `Local`
  layer for panels, tabs and drafts.
- `examples/route_server_workspace`: pages with private server state (below).

## Private Server State per Page

With `brazier.full_application`, the server keeps a state type that is larger
than the model it sends. A page module can expose a public `Model` and a
server-only record; the root state holds both, and `sync` returns only the
model:

<!-- docs-check: fragment an excerpt of examples/route_server_workspace/src/main.gleam, whose page modules define accounts.Server and settings.Server -->
```gleam
pub type Session {
  Session(model: Model, accounts: accounts.Server, settings: settings.Server)
}

fn sync(session: Session) -> Model {
  session.model
}

pub fn main() {
  brazier.full_application(init:, update:, sync:, local: local.none(), view:)
  |> brazier.with_router(parse: parse_route, on_change: RouteChanged)
  |> brazier.start(8080)
}
```

The browser receives only what `sync` returns, and the build compiles to
JavaScript only the code that `view` (and, for `simple`, `update`) reaches.
Server records and the functions that use them never reach the browser. See
[SECURITY.md](SECURITY.md).

## Route-Dependent Titles

`brazier.title(fn(model) { ... })` sets the document title on the HTML render,
from the model after `on_change` has run, so it can depend on the route:

<!-- docs-check: wrap
import brazier

pub type Route {
  HomePage
  UserPage(id: String)
  SearchPage(query: String)
}

pub type Model {
  Model(route: Route)
}

pub fn with_title(
  app: brazier.App(Model, Model, Nil, msg),
) -> brazier.App(Model, Model, Nil, msg) {
  app
  {{block}}
}
-->
```gleam
|> brazier.title(fn(model) {
  case model.route {
    HomePage -> "Home"
    UserPage(id:) -> "User " <> id
    SearchPage(..) -> "Search"
  }
})
```

The title is computed only for the HTML render. A client navigation does not
change `document.title`; the title of the first page stays until the next
full page load.
