/// The client-visible part of Auth Workspace: routes, the Model and `view`.
///
/// Everything here is compiled for the browser. The session id, the private
/// audit trail and the store live in the server-only `Session` record in
/// `auth_workspace.gleam`.
import beacon/attribute
import beacon/element.{type Element}
import beacon/event
import beacon/html
import gleam/int

pub const login_csrf_token = "auth-workspace-login-csrf"

pub type Route {
  Home
  Login
  Workspace
  Settings
  AdminPanel
}

pub type Role {
  Admin
  Member
}

/// The signed-in user, read from the session store on every mount.
pub type Account {
  Account(user: String, role: Role, display_name: String, csrf_token: String)
}

pub type Viewer {
  Guest
  SignedIn(Account)
}

pub type Model {
  Model(
    route: Route,
    viewer: Viewer,
    status: String,
    saved_profiles: Int,
    admin_events: Int,
  )
}

pub type Msg {
  RouteChanged(Route)
  SetDisplayName(String)
  SaveProfile
  RefreshSession
  AdminAudit
}

/// The one route declaration: `/`, `/login`, `/app`, `/settings` and
/// `/admin`. Any other path is answered with 404.
pub fn parse_route(segments: List(String)) -> Result(Route, Nil) {
  case segments {
    [] -> Ok(Home)
    ["login"] -> Ok(Login)
    ["app"] -> Ok(Workspace)
    ["settings"] -> Ok(Settings)
    ["admin"] -> Ok(AdminPanel)
    _ -> Error(Nil)
  }
}

pub fn href(route: Route) -> String {
  case route {
    Home -> "/"
    Login -> "/login"
    Workspace -> "/app"
    Settings -> "/settings"
    AdminPanel -> "/admin"
  }
}

/// How a role is stored in the session and shown on the page.
pub fn role_label(role: Role) -> String {
  case role {
    Admin -> "admin"
    Member -> "user"
  }
}

pub fn parse_role(value: String) -> Result(Role, Nil) {
  case value {
    "admin" -> Ok(Admin)
    "user" -> Ok(Member)
    _ -> Error(Nil)
  }
}

pub fn guest_model() -> Model {
  Model(
    route: Home,
    viewer: Guest,
    status: "Sign in to open the workspace",
    saved_profiles: 0,
    admin_events: 0,
  )
}

pub fn signed_in_model(account: Account) -> Model {
  Model(
    route: Home,
    viewer: SignedIn(account),
    status: "Session loaded for " <> account.user,
    saved_profiles: 0,
    admin_events: 0,
  )
}

pub fn view(model: Model, _local: Nil) -> Element(Msg) {
  html.main(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "860px"),
        #("margin", "32px auto"),
        #("padding", "0 16px"),
        #("line-height", "1.45"),
      ]),
      attribute.data("testid", "auth-root"),
    ],
    [
      html.h1([], [html.text("Auth Workspace")]),
      case model.viewer {
        Guest -> login_view(model)
        SignedIn(account) -> workspace_view(model, account)
      },
    ],
  )
}

fn login_view(model: Model) -> Element(Msg) {
  html.section(
    [
      attribute.data("testid", "login-panel"),
      attribute.styles([
        #("border", "1px solid #d0d7de"),
        #("border-radius", "6px"),
        #("padding", "16px"),
      ]),
    ],
    [
      html.h2([], [html.text("Sign in")]),
      html.p([attribute.data("testid", "auth-status")], [
        html.text(model.status),
      ]),
      html.form(
        [
          attribute.method("post"),
          attribute.action("/api/login"),
          attribute.styles([
            #("display", "grid"),
            #("gap", "10px"),
            #("max-width", "360px"),
          ]),
        ],
        [
          html.input([
            attribute.type_("hidden"),
            attribute.name("csrf"),
            attribute.value(login_csrf_token),
          ]),
          html.label([attribute.for("login-username")], [
            html.text("Username"),
          ]),
          html.input([
            attribute.id("login-username"),
            attribute.name("username"),
            attribute.value("ada"),
            attribute.data("testid", "login-username"),
          ]),
          html.button([attribute.type_("submit")], [html.text("Sign in")]),
        ],
      ),
    ],
  )
}

fn workspace_view(model: Model, account: Account) -> Element(Msg) {
  html.div([], [
    nav_view(account),
    html.p([attribute.data("testid", "auth-status")], [
      html.text(model.status),
    ]),
    case model.route {
      AdminPanel -> admin_view(model, account)
      Settings -> settings_view(account)
      // A signed-in user who opens /login is already signed in.
      Home | Login | Workspace -> app_view(model, account)
    },
  ])
}

fn nav_view(account: Account) -> Element(Msg) {
  html.nav(
    [
      attribute.styles([
        #("display", "flex"),
        #("gap", "12px"),
        #("align-items", "center"),
        #("margin", "16px 0"),
      ]),
      attribute.data("testid", "auth-nav"),
    ],
    [
      html.a([attribute.href(href(Workspace))], [html.text("App")]),
      html.a([attribute.href(href(Settings))], [html.text("Settings")]),
      html.a([attribute.href(href(AdminPanel))], [html.text("Admin")]),
      html.span([], [
        html.text(account.user <> " (" <> role_label(account.role) <> ")"),
      ]),
    ],
  )
}

fn app_view(model: Model, account: Account) -> Element(Msg) {
  html.section([attribute.data("testid", "workspace-home")], [
    html.h2([], [html.text("Workspace")]),
    html.p([], [html.text("Welcome, " <> account.display_name)]),
    html.p([], [
      html.text("Profiles saved: " <> int.to_string(model.saved_profiles)),
    ]),
    html.button([event.on_click(RefreshSession)], [
      html.text("Refresh session summary"),
    ]),
  ])
}

fn settings_view(account: Account) -> Element(Msg) {
  html.section([attribute.data("testid", "settings-panel")], [
    html.h2([], [html.text("Settings")]),
    html.label([attribute.for("display-name")], [html.text("Display name")]),
    html.input([
      attribute.id("display-name"),
      attribute.value(account.display_name),
      event.on_input(SetDisplayName),
      attribute.data("testid", "display-name-input"),
    ]),
    html.button([event.on_click(SaveProfile)], [html.text("Save profile")]),
    html.p([], [
      html.text(
        "CSRF token is available to API clients, not as a session cookie.",
      ),
    ]),
  ])
}

fn admin_view(model: Model, account: Account) -> Element(Msg) {
  case account.role {
    Member ->
      html.section([attribute.data("testid", "admin-denied")], [
        html.h2([], [html.text("Forbidden")]),
        html.p([], [html.text("This route requires the admin role.")]),
      ])
    Admin ->
      html.section([attribute.data("testid", "admin-panel")], [
        html.h2([], [html.text("Admin")]),
        html.p([], [
          html.text("Audit events: " <> int.to_string(model.admin_events)),
        ]),
        html.button([event.on_click(AdminAudit)], [
          html.text("Record audit event"),
        ]),
      ])
  }
}
