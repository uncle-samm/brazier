/// Auth Workspace: cookie sessions, CSRF-protected API routes and a
/// role-gated admin page.
///
/// - Every page load without one gets a random login CSRF token in an
///   HttpOnly cookie (`issue_login_csrf`); the login form carries the same
///   token in a hidden field, and `POST /api/login` refuses a form whose
///   field does not match the cookie (a double-submit cookie).
/// - `POST /api/login` creates a session (rotating any previous id), sets
///   the HttpOnly session cookie and deletes the login CSRF cookie, so the
///   next guest page gets a new token; `POST /api/logout` deletes the
///   session.
/// - `init` reads that cookie from the `Context`, on the HTML render and on
///   the connected mount, and loads the account from the session store.
/// - A signed-in socket is bound to its session (`auth.allow_guests_ws`), so
///   logout closes it; a guest socket connects to the guest page. A session
///   store outage refuses the page (503) and the socket.
/// - The session id, the audit key and the audit trail stay in the
///   server-only `Session` record; `sync` sends only the Model.
import auth_workspace/app.{type Model, type Msg}
import beacon
import beacon/api
import beacon/auth
import beacon/cookie
import beacon/effect.{type Effect}
import beacon/error
import beacon/local
import beacon/log
import beacon/middleware
import beacon/router
import beacon/session
import gleam/dict
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

/// The cookie that holds this browser's login CSRF token.
const login_csrf_cookie = "auth_workspace_login_csrf"

const audit_key = "server-only-audit-key"

/// The session keeps the newest audit entries up to this many.
const max_audit_entries = 100

const max_display_name_length = 80

const role_key = "role"

const display_name_key = "display_name"

/// What the server holds per browser session. Only `model` is synced.
pub type Session {
  Session(
    model: Model,
    store: session.SessionStore,
    /// The id of the signed-in session; `None` for a guest.
    session_id: Option(String),
    audit_key: String,
    /// Newest first, at most `max_audit_entries`.
    audit_entries: List(String),
    denied_admin_events: Int,
  )
}

pub fn main() {
  let store = session.new_store("auth_workspace_sessions")
  let auth_config = auth.dev_session_config()

  let assert Ok(Nil) =
    beacon.full_application(
      init: init(store, auth_config),
      update:,
      sync:,
      local: local.none(),
      view: app.view,
    )
    |> beacon.with_router(parse: parse_route, on_change: app.RouteChanged)
    |> beacon.title(fn(_model) { "Auth Workspace" })
    |> beacon.secret_key("auth-workspace-session-secret-key-32-chars")
    |> beacon.api_routes(api_handler(store, auth_config))
    |> beacon.ws_auth(auth.allow_guests_ws(store, auth_config))
    |> beacon.with_middleware(issue_login_csrf(auth_config))
    |> beacon.dev_mode(True)
    |> beacon.head_html(favicon)
    |> beacon.start(8080)
    as "beacon.start failed (it logs the error)"
}

fn parse_route(uri: Uri) -> Result(app.Route, Nil) {
  app.parse_route(router.segments(uri))
}

// ===== Login CSRF =====

/// Give a browser its login CSRF token on the first page load that lacks
/// one: a fresh random token in an HttpOnly cookie. The token is also
/// added to the request handed on, so this page's `init` puts it in the
/// login form, and the WebSocket mount reads the same cookie.
///
/// Only page routes (GET or HEAD of a path `app.parse_route` knows) get a
/// token; API calls, assets and the WebSocket upgrade pass through.
///
/// Reference: Plug.CSRFProtection, which creates the token on first use and
/// stores it in the browser's session cookie before anyone signs in, and the
/// OWASP CSRF cheat sheet's double-submit cookie.
fn issue_login_csrf(config: auth.SessionConfig) -> middleware.Middleware {
  fn(req: api.Request, next: fn(api.Request) -> api.Response) -> api.Response {
    let is_page = case req.method, page_route(req.path) {
      http.Get, Ok(_) | http.Head, Ok(_) -> True
      _, _ -> False
    }
    case is_page, cookie.get(req, login_csrf_cookie) {
      True, Error(Nil) | True, Ok("") -> {
        let token = session.generate_id()
        let resp = next(request.set_cookie(req, login_csrf_cookie, token))
        case cookie.set(resp, login_csrf_cookie, token, config.cookie_options) {
          Ok(resp) -> {
            log.debug(
              "auth_workspace",
              "Issued a login CSRF token on " <> req.path,
            )
            resp
          }
          Error(err) -> {
            log.error(
              "auth_workspace",
              "Cannot set the login CSRF cookie: "
                <> cookie.error_to_string(err),
            )
            api.text(500, "Internal Server Error")
          }
        }
      }
      _, _ -> next(req)
    }
  }
}

/// The route of a request path, decoded as Beacon decodes it before it
/// calls `parse_route`. Middleware runs before Beacon validates the path, so
/// a segment that does not decode is not a page here (Beacon refuses it).
fn page_route(path: String) -> Result(app.Route, Nil) {
  uri.path_segments(path)
  |> list.try_map(uri.percent_decode)
  |> result.try(app.parse_route)
}

// ===== Session lifecycle =====

/// Load the account named by the session cookie, through
/// `auth.init_from_session`. A missing, unknown or expired session is a
/// guest. A store that cannot answer refuses the request with
/// `error.unavailable` (the HTML render answers 503, the socket closes with
/// 4503) rather than show a signed-in user the guest page.
fn init(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> fn(beacon.Context) -> Result(#(Session, Effect(Msg)), beacon.InitError) {
  auth.init_from_session(
    store,
    config,
    guest_init: fn(ctx) {
      use login_csrf <- result.try(login_csrf_from(ctx))
      log.debug("auth_workspace", "Rendering the guest page")
      Ok(#(new_session(store, app.guest_model(login_csrf)), effect.none()))
    },
    authenticated_init: fn(ctx, sess, _user_id) {
      Ok(#(restore(store, sess, ctx), effect.none()))
    },
  )
}

/// The guest page needs the browser's login CSRF token for its form.
/// `issue_login_csrf` gives one to every page load, so only a browser that
/// refuses cookies reaches `init` without it; it could not sign in anyway,
/// so the page is refused (400) rather than shown with a form that fails.
fn login_csrf_from(ctx: beacon.Context) -> Result(String, beacon.InitError) {
  case beacon.cookie(ctx, login_csrf_cookie) {
    Ok("") | Error(Nil) -> {
      log.warning(
        "auth_workspace",
        "Guest page without a login CSRF cookie (connected: "
          <> string.inspect(beacon.is_connected(ctx))
          <> "); refusing it",
      )
      Error(error.refuse(400, "no " <> login_csrf_cookie <> " cookie"))
    }
    Ok(token) -> Ok(token)
  }
}

fn new_session(store: session.SessionStore, model: Model) -> Session {
  Session(
    model:,
    store:,
    session_id: None,
    audit_key:,
    audit_entries: [],
    denied_admin_events: 0,
  )
}

fn restore(
  store: session.SessionStore,
  sess: session.Session,
  ctx: beacon.Context,
) -> Session {
  let account = account_from_session(sess)
  log.info(
    "auth_workspace",
    "Session restored for "
      <> account.user
      <> " (connected: "
      <> string.inspect(beacon.is_connected(ctx))
      <> ")",
  )
  Session(
    ..new_session(store, app.signed_in_model(account)),
    session_id: Some(sess.id),
    audit_entries: ["session-restored"],
  )
}

/// Every session this app hands out was written by `handle_login`, which
/// stores the user, role, display name and CSRF token before the cookie is
/// sent. A session without them was not written by this app: crash.
fn account_from_session(sess: session.Session) -> app.Account {
  let user = required_value(sess, "user_id")
  let role_value = required_value(sess, role_key)
  let assert Ok(role) = app.parse_role(role_value)
    as "auth_workspace: handle_login only stores the roles app.parse_role reads"
  app.Account(
    user:,
    role:,
    display_name: required_value(sess, display_name_key),
    csrf_token: required_value(sess, "csrf_token"),
  )
}

fn required_value(sess: session.Session, key: String) -> String {
  let value = session.get_value(sess, key)
  case value {
    Some(_) -> Nil
    None ->
      log.error(
        "auth_workspace",
        "Session is missing \"" <> key <> "\", which handle_login always writes",
      )
  }
  let assert Some(value) = value
    as "auth_workspace: a session without a field handle_login writes (logged above)"
  value
}

// ===== Update =====

fn update(state: Session, msg: Msg) -> #(Session, Effect(Msg)) {
  let model = state.model
  let state = case msg, model.viewer {
    app.RouteChanged(route), _ ->
      Session(..state, model: app.Model(..model, route:))

    // Only a signed-in page has these controls, so a guest sending one is
    // a forged event.
    _, app.Guest(..) -> {
      log.warning(
        "auth_workspace",
        "Ignoring " <> string.inspect(msg) <> " from a guest session",
      )
      state
    }

    app.SetDisplayName(name), app.SignedIn(account) ->
      case string.length(name) > max_display_name_length {
        True -> {
          log.warning(
            "auth_workspace",
            "Refusing a display name of "
              <> int.to_string(string.length(name))
              <> " characters (limit "
              <> int.to_string(max_display_name_length)
              <> ")",
          )
          state
        }
        False ->
          signed_in(state, app.Account(..account, display_name: name), model)
      }

    app.SaveProfile, app.SignedIn(account) -> save_profile(state, account)

    app.RefreshSession, app.SignedIn(account) ->
      Session(
        ..audit(state, "refresh-session"),
        model: app.Model(
          ..model,
          status: "Session for "
            <> account.user
            <> " has "
            <> int.to_string(list.length(state.audit_entries))
            <> " private audit entries",
        ),
      )

    app.AdminAudit, app.SignedIn(account) ->
      case account.role {
        app.Admin -> {
          log.info("auth_workspace", "Admin audit event by " <> account.user)
          Session(
            ..audit(state, "admin-audit"),
            model: app.Model(
              ..model,
              admin_events: model.admin_events + 1,
              status: "Admin audit event recorded",
            ),
          )
        }
        app.Member -> {
          log.warning(
            "auth_workspace",
            "Refused an admin audit event from " <> account.user,
          )
          Session(
            ..state,
            denied_admin_events: state.denied_admin_events + 1,
            model: app.Model(..model, status: "Admin action denied"),
          )
        }
      }
  }
  #(state, effect.none())
}

fn signed_in(state: Session, account: app.Account, model: Model) -> Session {
  Session(..state, model: app.Model(..model, viewer: app.SignedIn(account)))
}

/// Persist the display name in the session store, so the next page load
/// shows it too.
fn save_profile(state: Session, account: app.Account) -> Session {
  let model = state.model
  let assert Some(id) = state.session_id
    as "auth_workspace: a SignedIn model is only built with its session id"
  let write =
    session.update(state.store, id, fn(data) {
      dict.insert(data, display_name_key, account.display_name)
    })
  case write {
    Ok(_sess) -> {
      log.info("auth_workspace", "Saved the profile of " <> account.user)
      Session(
        ..audit(state, "save-profile"),
        model: app.Model(
          ..model,
          saved_profiles: model.saved_profiles + 1,
          status: "Profile saved for " <> account.display_name,
        ),
      )
    }
    Error(err) -> {
      log.warning(
        "auth_workspace",
        "Profile of "
          <> account.user
          <> " not saved: "
          <> session.store_error_to_string(err),
      )
      Session(
        ..state,
        model: app.Model(
          ..model,
          status: "Profile not saved: the session is no longer available",
        ),
      )
    }
  }
}

fn audit(state: Session, entry: String) -> Session {
  Session(
    ..state,
    audit_entries: list.take([entry, ..state.audit_entries], max_audit_entries),
  )
}

fn sync(state: Session) -> Model {
  state.model
}

// ===== API routes =====

fn api_handler(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> fn(api.Request) -> Option(api.Response) {
  api.routes([
    api.post("/api/login", fn(req) { handle_login(req, store, config) }),
    api.get("/api/me", auth.protect_api(store, config, handle_me)),
    api.post(
      "/api/profile",
      auth.protect_api_with_csrf(store, config, fn(req, sess, _user_id) {
        handle_profile(req, store, sess)
      }),
    ),
    api.post(
      "/api/logout",
      auth.protect_api_with_csrf(store, config, fn(_req, sess, user_id) {
        handle_logout(store, sess, user_id, config)
      }),
    ),
  ])
}

fn handle_login(
  req: api.Request,
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> api.Response {
  case api.read_form(req, 4096) {
    Error(reason) -> {
      log.warning("auth_workspace", "Login form rejected: " <> reason)
      api.text(400, reason)
    }
    Ok(fields) ->
      case
        cookie.get(req, login_csrf_cookie),
        api.form_field(fields, "csrf"),
        api.form_field(fields, "username")
      {
        Error(Nil), _, _ | Ok(""), _, _ ->
          refuse_login_csrf("no " <> login_csrf_cookie <> " cookie")
        Ok(_), Error(_), _ -> refuse_login_csrf("no csrf field")
        Ok(_), Ok(_), Error(reason) -> {
          log.warning("auth_workspace", "Login form rejected: " <> reason)
          api.text(400, reason)
        }
        Ok(expected), Ok(csrf), Ok(username) ->
          case session.secure_compare(csrf, expected) {
            True -> start_session(req, store, config, normalize_user(username))
            False ->
              refuse_login_csrf(
                "the csrf field does not match the "
                <> login_csrf_cookie
                <> " cookie",
              )
          }
      }
  }
}

fn refuse_login_csrf(reason: String) -> api.Response {
  log.warning("auth_workspace", "Login refused: " <> reason)
  api.text(403, "Invalid login CSRF token")
}

fn start_session(
  req: api.Request,
  store: session.SessionStore,
  config: auth.SessionConfig,
  user: String,
) -> api.Response {
  // Rotate: any session id the browser already had is deleted so it cannot
  // be fixed by an attacker and replayed after login.
  let old_id =
    option.from_result(session.id_from_request(req, config.cookie_name))
  case auth.create_login_rotating(store, old_id, user) {
    Error(err) -> {
      log.error(
        "auth_workspace",
        "Login of " <> user <> " failed: " <> auth.error_to_string(err),
      )
      login_store_failure(err)
    }
    Ok(login) -> {
      let profile =
        session.update(store, login.session.id, fn(data) {
          data
          |> dict.insert(role_key, app.role_label(role_for_user(user)))
          |> dict.insert(display_name_key, display_name_for_user(user))
        })
      case profile {
        Error(err) -> {
          log.error(
            "auth_workspace",
            "Login of "
              <> user
              <> " failed writing the profile: "
              <> session.store_error_to_string(err),
          )
          api.text(503, "Session store unavailable")
        }
        Ok(sess) -> {
          let resp =
            api.json_value(
              200,
              json.object([
                #("ok", json.bool(True)),
                #("csrf", json.string(login.csrf_token)),
              ]),
            )
            |> auth.with_session_cookie(sess, config)
            // A login renews the token, as Phoenix's `renew_session` deletes
            // the CSRF token: the next guest page gets a fresh one.
            |> result.try(cookie.delete_with_options(
              _,
              login_csrf_cookie,
              config.cookie_options,
            ))
          case resp {
            Ok(resp) -> {
              log.info("auth_workspace", "Signed in " <> user)
              resp
            }
            Error(err) -> {
              log.error(
                "auth_workspace",
                "Login cannot set its cookies: " <> cookie.error_to_string(err),
              )
              api.text(500, "Internal Server Error")
            }
          }
        }
      }
    }
  }
}

/// `create_login_rotating` only fails when the store cannot delete the old
/// session or create the new one.
fn login_store_failure(err: auth.SessionError) -> api.Response {
  case err {
    auth.SessionStoreUnavailable(_) ->
      api.text(503, "Session store unavailable")
    auth.InvalidSession
    | auth.MissingSessionCookie
    | auth.MissingUser
    | auth.MissingCsrfToken
    | auth.InvalidCsrfToken -> api.text(500, "Login failed")
  }
}

fn handle_logout(
  store: session.SessionStore,
  sess: session.Session,
  user: String,
  config: auth.SessionConfig,
) -> api.Response {
  case auth.logout_response(store, sess, api.text(200, "Logged out"), config) {
    Ok(resp) -> {
      log.info("auth_workspace", "Signed out " <> user)
      resp
    }
    Error(err) -> {
      log.error(
        "auth_workspace",
        "Logout of "
          <> user
          <> " failed: "
          <> auth.response_error_to_string(err),
      )
      case err {
        // The session may still exist: keep the cookie so the browser does
        // not believe it signed out.
        auth.StoreFailed(_) -> api.text(503, "Session store unavailable")
        auth.CookieRejected(_) -> api.text(500, "Internal Server Error")
      }
    }
  }
}

fn handle_me(
  _req: api.Request,
  sess: session.Session,
  _user: String,
) -> api.Response {
  let account = account_from_session(sess)
  api.json_value(
    200,
    json.object([
      #("user", json.string(account.user)),
      #("role", json.string(app.role_label(account.role))),
      #("display_name", json.string(account.display_name)),
    ]),
  )
}

fn handle_profile(
  req: api.Request,
  store: session.SessionStore,
  sess: session.Session,
) -> api.Response {
  case api.read_form(req, 4096) {
    Error(reason) -> api.text(400, reason)
    Ok(fields) ->
      case api.form_field(fields, display_name_key) {
        Error(reason) -> api.text(400, reason)
        Ok(name) ->
          case string.length(name) > max_display_name_length {
            True -> api.text(400, "Display name too long")
            False ->
              case session.set(store, sess, display_name_key, name) {
                Ok(_sess) ->
                  api.json_value(200, json.object([#("ok", json.bool(True))]))
                Error(err) -> {
                  log.warning(
                    "auth_workspace",
                    "Profile write rejected: "
                      <> session.store_error_to_string(err),
                  )
                  api.text(401, "Session expired")
                }
              }
          }
      }
  }
}

fn normalize_user(username: String) -> String {
  case string.trim(username) {
    "" -> "guest"
    user -> user
  }
}

fn role_for_user(username: String) -> app.Role {
  case username {
    "ada" -> app.Admin
    _ -> app.Member
  }
}

fn display_name_for_user(username: String) -> String {
  case username {
    "ada" -> "Ada Lovelace"
    _ -> username
  }
}
