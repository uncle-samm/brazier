import auth_workspace/app
import beacon
import beacon/api
import beacon/auth
import beacon/effect
import beacon/log
import beacon/route
import beacon/session
import beacon/transport/server.{type Connection, type ResponseBody}
import gleam/dict
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub fn main() {
  let store = session.new_store("auth_workspace_sessions")
  let auth_config = auth.dev_session_config()

  beacon.app(
    fn() { #(app.init(), effect.none()) },
    beacon.no_local,
    app.init_server,
    update,
    view,
  )
  |> beacon.title("Auth Workspace")
  |> beacon.secret_key("auth-workspace-session-secret-key-32-chars")
  |> beacon.route_pages(auth_pages())
  |> beacon.api_routes(api_handler(store, auth_config))
  |> beacon.ws_auth(auth.protect_ws(store, auth_config))
  |> beacon.ws_init(init_from_request(store, auth_config))
  |> beacon.dev_mode(True)
  |> beacon.start(8080)
}

fn auth_pages() -> List(route.Page(#(app.Model, Nil, app.Server), app.Msg)) {
  [
    auth_page("/"),
    auth_page("/login"),
    auth_page("/app"),
    auth_page("/settings"),
    auth_page("/admin"),
  ]
}

fn auth_page(
  pattern: String,
) -> route.Page(#(app.Model, Nil, app.Server), app.Msg) {
  route.page(
    pattern,
    fn(r: route.Route) { app.RouteChanged(r.path) },
    fn(state: #(app.Model, Nil, app.Server), _route) {
      let #(model, _local, _server) = state
      app.view(model, Nil)
    },
  )
}

fn view(model: app.Model, _local: Nil) -> beacon.Node(app.Msg) {
  app.view(model, Nil)
}

fn update(
  model: app.Model,
  _local: Nil,
  server: app.Server,
  msg: app.Msg,
) -> #(app.Model, Nil, app.Server) {
  case msg {
    app.RefreshSession -> {
      let audit_count = list.length(server.audit_entries)
      #(
        app.Model(
          ..model,
          status: "Session "
            <> server.session_id
            <> " has "
            <> int.to_string(audit_count)
            <> " private audit entries",
        ),
        Nil,
        app.Server(..server, audit_entries: [
          "refresh-session",
          ..server.audit_entries
        ]),
      )
    }
    app.AdminAudit -> {
      case model.role == "admin" {
        True -> #(
          app.update_model(model, msg),
          Nil,
          app.Server(..server, audit_entries: [
            "admin-audit",
            ..server.audit_entries
          ]),
        )
        False -> #(
          app.update_model(model, msg),
          Nil,
          app.Server(
            ..server,
            denied_admin_events: server.denied_admin_events + 1,
          ),
        )
      }
    }
    _ -> #(app.update_model(model, msg), Nil, server)
  }
}

fn api_handler(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> fn(Request(Connection)) -> Option(response.Response(ResponseBody)) {
  api.routes([
    api.post("/api/login", fn(req) { handle_login(req, store, config) }),
    api.get("/api/me", auth.protect_api(store, config, handle_me)),
    api.post(
      "/api/profile",
      auth.protect_api_with_csrf(store, config, fn(req, sess, user_id) {
        handle_profile(req, store, sess, user_id)
      }),
    ),
    api.post(
      "/api/logout",
      auth.protect_api_with_csrf(store, config, fn(_req, sess, _user_id) {
        auth.logout_response(store, sess, api.text(200, "Logged out"), config)
      }),
    ),
  ])
}

fn handle_login(
  req: Request(Connection),
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> response.Response(ResponseBody) {
  case api.read_form(req, 4096) {
    Ok(fields) -> {
      case api.form_field(fields, "csrf"), api.form_field(fields, "username") {
        Ok(csrf), Ok(username) if csrf == app.login_csrf_token -> {
          let safe_user = normalize_user(username)
          // Rotate: any session id the browser already had is deleted so it
          // cannot be fixed by an attacker and replayed after login.
          let old_id =
            option.from_result(session.id_from_request(req, config.cookie_name))
          let login = auth.create_login_rotating(store, old_id, safe_user)
          let result =
            session.update(store, login.session.id, fn(data) {
              data
              |> dict.insert("role", role_for_user(safe_user))
              |> dict.insert("display_name", display_name_for_user(safe_user))
            })
          case result {
            Ok(sess) ->
              api.json_value(
                200,
                json.object([
                  #("ok", json.bool(True)),
                  #("csrf", json.string(login.csrf_token)),
                ]),
              )
              |> auth.with_session_cookie(sess, config)
            Error(err) -> {
              log.error(
                "auth_workspace",
                "Login profile write failed: "
                  <> session.store_error_to_string(err),
              )
              api.text(500, "Login failed")
            }
          }
        }
        _, _ -> api.text(403, "Invalid login CSRF token")
      }
    }
    Error(reason) -> api.text(400, reason)
  }
}

fn handle_me(
  _req: Request(Connection),
  sess: session.Session,
  user: String,
) -> response.Response(ResponseBody) {
  let role = session_value(sess, "role", "user")
  api.json_value(
    200,
    json.object([
      #("user", json.string(user)),
      #("role", json.string(role)),
    ]),
  )
}

fn handle_profile(
  req: Request(Connection),
  store: session.SessionStore,
  sess: session.Session,
  _user_id: String,
) -> response.Response(ResponseBody) {
  case api.read_form(req, 4096) {
    Error(reason) -> api.text(400, reason)
    Ok(fields) -> {
      case api.form_field(fields, "display_name") {
        Ok(display_name) ->
          case session.set(store, sess, "display_name", display_name) {
            Ok(_sess) ->
              api.json_value(200, json.object([#("ok", json.bool(True))]))
            Error(err) -> {
              log.warning(
                "auth_workspace",
                "Profile write rejected: " <> session.store_error_to_string(err),
              )
              api.text(401, "Session expired")
            }
          }
        Error(reason) -> api.text(400, reason)
      }
    }
  }
}

fn init_from_request(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> fn(Request(Connection)) -> #(app.Model, Nil, app.Server) {
  auth.init_from_session(
    store,
    config,
    fn(req) {
      #(app.Model(..app.init(), route: req.path), Nil, app.init_server())
    },
    fn(req, sess, _user_id) {
      let user = session_value(sess, "user_id", "")
      let role = session_value(sess, "role", "user")
      let display_name = session_value(sess, "display_name", user)
      let csrf_token = session_value(sess, "csrf_token", "")
      #(
        app.authenticated_model(req.path, user, role, display_name, csrf_token),
        Nil,
        app.Server(
          session_id: sess.id,
          csrf_token: csrf_token,
          private_audit_key: "server-only-audit-key",
          audit_entries: ["session-restored"],
          denied_admin_events: 0,
        ),
      )
    },
  )
}

fn session_value(
  sess: session.Session,
  key: String,
  default: String,
) -> String {
  case session.get_value(sess, key) {
    Some(value) -> value
    None -> default
  }
}

fn normalize_user(username: String) -> String {
  case string.trim(username) {
    "" -> "guest"
    user -> user
  }
}

fn role_for_user(username: String) -> String {
  case username {
    "ada" -> "admin"
    _ -> "user"
  }
}

fn display_name_for_user(username: String) -> String {
  case username {
    "ada" -> "Ada Lovelace"
    _ -> username
  }
}
