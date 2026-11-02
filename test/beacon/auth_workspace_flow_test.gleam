/// End-to-end auth workspace flow over real HTTP and WebSocket sockets.
/// This test composes API routes, HttpOnly cookies, CSRF, ws_auth, ws_init,
/// route-aware SSR, and server-private state in one app shape.
import beacon
import beacon/application
import beacon/cookie
import beacon/effect
import beacon/error
import beacon/form
import beacon/html
import beacon/route
import beacon/session
import beacon/transport
import beacon/transport/http as transport_http
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

const login_csrf = "auth-flow-login-csrf"

const csrf_secret = "auth-flow-csrf-secret"

type Model {
  Model(
    route: String,
    authenticated: Bool,
    user: String,
    role: String,
    display_name: String,
    csrf_token: String,
    status: String,
  )
}

type Server {
  Server(session_id: String, private_key: String, audit_count: Int)
}

type Msg {
  RouteChanged(String)
  Refresh
}

pub fn full_auth_cookie_csrf_ws_flow_test() {
  let port = 21_000 + unique_port_offset()
  let store = session.new_store("auth_flow_" <> int.to_string(port))
  let csrf_store =
    form.create_csrf_store("auth_flow_csrf_" <> int.to_string(port))
  let assert Ok(_app) =
    application.start_advanced(test_config(port, store, csrf_store))
  process.sleep(150)

  let base = "http://localhost:" <> int.to_string(port)

  let assert Ok(#(login_status, login_headers, login_html)) =
    http_request("GET", base <> "/app", [], "")
  let assert 200 = login_status
  let assert True = string.contains(login_html, "Sign in")
  let assert False =
    header_contains(login_headers, "set-cookie", "beacon_session")

  let assert Ok(#(missing_csrf_status, _missing_headers, _missing_body)) =
    http_request(
      "POST",
      base <> "/api/login",
      [#("content-type", "application/x-www-form-urlencoded")],
      "username=ada&csrf=wrong",
    )
  let assert 403 = missing_csrf_status

  let assert Ok(#(auth_status, auth_headers, auth_body)) =
    http_request(
      "POST",
      base <> "/api/login",
      [#("content-type", "application/x-www-form-urlencoded")],
      "username=ada&csrf=" <> login_csrf,
    )
  let assert 200 = auth_status
  let assert True = string.contains(auth_body, "\"ok\":true")
  let assert Ok(cookie_header) = find_header(auth_headers, "set-cookie")
  let assert True = string.contains(cookie_header, "beacon_session=")
  let assert True = string.contains(cookie_header, "HttpOnly")
  let assert True = string.contains(cookie_header, "SameSite=Lax")
  let session_cookie = cookie_pair(cookie_header)
  let assert Ok(csrf_token) = json_field(auth_body, "csrf")

  let assert Ok(#(me_status, _me_headers, me_body)) =
    http_request("GET", base <> "/api/me", [#("cookie", session_cookie)], "")
  let assert 200 = me_status
  let assert True = string.contains(me_body, "\"user\":\"ada\"")
  let assert True = string.contains(me_body, "\"role\":\"admin\"")

  let assert Ok(#(bad_profile_status, _bad_headers, _bad_body)) =
    http_request(
      "POST",
      base <> "/api/profile",
      [
        #("cookie", session_cookie),
        #("content-type", "application/x-www-form-urlencoded"),
      ],
      "display_name=Grace+Hopper&csrf=wrong",
    )
  let assert 403 = bad_profile_status

  let assert Ok(#(profile_status, _profile_headers, profile_body)) =
    http_request(
      "POST",
      base <> "/api/profile",
      [
        #("cookie", session_cookie),
        #("x-csrf-token", csrf_token),
        #("content-type", "application/x-www-form-urlencoded"),
      ],
      "display_name=Grace+Hopper",
    )
  let assert 200 = profile_status
  let assert True = string.contains(profile_body, "\"ok\":true")

  let assert Error(_) = ws_connect_with_headers("localhost", port, [])
  let assert Ok(socket) =
    ws_connect_with_headers("localhost", port, [#("cookie", session_cookie)])
  let assert Ok(Nil) = ws_send(socket, "{\"type\":\"join\"}")
  let assert Ok(sync) = ws_recv(socket, 3000)
  let assert True = string.contains(sync, "\"type\":\"model_sync\"")
  let assert True = string.contains(sync, "Grace Hopper")
  let assert True = string.contains(sync, "admin")
  let assert False = string.contains(sync, "server-private-key")
  let assert False = string.contains(sync, "\"type\":\"mount\"")
  ws_close(socket)

  let assert Ok(#(logout_status, logout_headers, logout_body)) =
    http_request(
      "POST",
      base <> "/api/logout",
      [#("cookie", session_cookie), #("x-csrf-token", csrf_token)],
      "",
    )
  let assert 200 = logout_status
  let assert True = string.contains(logout_body, "Logged out")
  let assert True = header_contains(logout_headers, "set-cookie", "Max-Age=0")
  let assert Error(_) =
    ws_connect_with_headers("localhost", port, [#("cookie", session_cookie)])
}

fn test_config(
  port: Int,
  store: session.SessionStore,
  csrf_store: form.CsrfStore,
) -> application.AppConfig(#(Model, Server), Msg) {
  application.AppConfig(
    port: port,
    init: fn() { #(#(init_model(), init_server()), effect.none()) },
    update: update,
    view: view,
    decode_event: Some(fn(_name, handler_id, _data, _path) {
      case handler_id {
        "refresh" -> Ok(Refresh)
        _ -> Error(error.RuntimeError(reason: "unknown handler"))
      }
    }),
    secret_key: "auth-flow-secret-key-long-enough-for-hmac!!",
    title: "Auth Flow",
    serialize_model: Some(serialize_public_model),
    deserialize_model: None,
    middlewares: [],
    static_dir: None,
    route_patterns: list.map(
      ["/", "/login", "/app", "/settings", "/admin"],
      route.pattern,
    ),
    on_route_change: Some(fn(r: route.Route) { RouteChanged(r.path) }),
    on_route_leave: None,
    dynamic_subscriptions: None,
    on_notify: None,
    on_notification: None,
    security_limits: transport.default_security_limits(),
    head_html: None,
    api_handler: Some(api_handler(store, csrf_store)),
    ws_auth: Some(ws_auth(store)),
    init_from_request: Some(init_from_request(store)),
    dev_mode: False,
  )
}

fn init_model() -> Model {
  Model(
    route: "/login",
    authenticated: False,
    user: "",
    role: "",
    display_name: "",
    csrf_token: "",
    status: "Sign in",
  )
}

fn serialize_public_model(combined: #(Model, Server)) -> String {
  let #(model, _server) = combined
  "{"
  <> "\"route\":\""
  <> model.route
  <> "\",\"authenticated\":"
  <> case model.authenticated {
    True -> "true"
    False -> "false"
  }
  <> ",\"user\":\""
  <> model.user
  <> "\",\"role\":\""
  <> model.role
  <> "\",\"display_name\":\""
  <> model.display_name
  <> "\",\"status\":\""
  <> model.status
  <> "\"}"
}

fn init_server() -> Server {
  Server(session_id: "", private_key: "server-private-key", audit_count: 0)
}

fn update(
  combined: #(Model, Server),
  msg: Msg,
) -> #(#(Model, Server), effect.Effect(Msg)) {
  let #(model, server) = combined
  case msg {
    RouteChanged(path) -> #(
      #(Model(..model, route: path), server),
      effect.none(),
    )
    Refresh -> #(
      #(
        Model(..model, status: "Refreshed " <> model.user),
        Server(..server, audit_count: server.audit_count + 1),
      ),
      effect.none(),
    )
  }
}

fn view(combined: #(Model, Server)) -> beacon.Node(Msg) {
  let #(model, _server) = combined
  html.main([html.attribute("data-testid", "auth-flow-root")], [
    html.h1([], [html.text("Auth Flow")]),
    case model.authenticated {
      False ->
        html.section([html.attribute("data-testid", "login-panel")], [
          html.h2([], [html.text("Sign in")]),
          html.form(
            [
              html.attribute("method", "post"),
              html.attribute("action", "/api/login"),
            ],
            [
              html.input([
                html.type_("hidden"),
                html.name("csrf"),
                html.value(login_csrf),
              ]),
              html.input([html.name("username"), html.value("ada")]),
              html.button([html.type_("submit")], [html.text("Sign in")]),
            ],
          ),
        ])
      True ->
        html.section([html.attribute("data-testid", "workspace")], [
          html.h2([], [html.text("Workspace")]),
          html.p([], [html.text(model.display_name)]),
          html.p([], [html.text(model.role)]),
          html.p([], [html.text(model.status)]),
          html.button(
            [beacon.on_click(Refresh), html.attribute("data-testid", "refresh")],
            [
              html.text("Refresh"),
            ],
          ),
        ])
    },
  ])
}

fn api_handler(
  store: session.SessionStore,
  csrf_store: form.CsrfStore,
) -> fn(Request(Connection)) -> Option(response.Response(ResponseBody)) {
  fn(req: Request(Connection)) {
    case req.method, request.path_segments(req) {
      http.Post, ["api", "login"] -> Some(handle_login(req, store, csrf_store))
      http.Get, ["api", "me"] -> Some(handle_me(req, store))
      http.Post, ["api", "profile"] -> Some(handle_profile(req, store))
      http.Post, ["api", "logout"] -> Some(handle_logout(req, store))
      _, _ -> None
    }
  }
}

fn handle_login(
  req: Request(Connection),
  store: session.SessionStore,
  csrf_store: form.CsrfStore,
) -> response.Response(ResponseBody) {
  case read_form(req) {
    Error(reason) -> text_response(400, reason)
    Ok(fields) -> {
      case field(fields, "csrf"), field(fields, "username") {
        Ok(csrf), Ok(username) if csrf == login_csrf -> {
          let sess = session.create(store)
          let csrf_token =
            form.generate_session_csrf(csrf_store, sess.id, csrf_secret)
          let sess = session.set(store, sess, "user_id", username)
          let sess = session.set(store, sess, "role", "admin")
          let sess = session.set(store, sess, "csrf_token", csrf_token)
          let _sess = session.set(store, sess, "display_name", "Ada Lovelace")
          json_response(200, "{\"ok\":true,\"csrf\":\"" <> csrf_token <> "\"}")
          |> cookie.set("beacon_session", sess.id, dev_cookie_options())
        }
        _, _ -> text_response(403, "Invalid login CSRF token")
      }
    }
  }
}

fn handle_me(
  req: Request(Connection),
  store: session.SessionStore,
) -> response.Response(ResponseBody) {
  case session_from_request(req, store) {
    Ok(sess) ->
      json_response(
        200,
        "{\"user\":\""
          <> session_value(sess, "user_id", "")
          <> "\",\"role\":\""
          <> session_value(sess, "role", "")
          <> "\"}",
      )
    Error(resp) -> resp
  }
}

fn handle_profile(
  req: Request(Connection),
  store: session.SessionStore,
) -> response.Response(ResponseBody) {
  case session_from_request(req, store) {
    Error(resp) -> resp
    Ok(sess) -> {
      case read_form(req) {
        Error(reason) -> text_response(400, reason)
        Ok(fields) -> {
          let csrf = case request.get_header(req, "x-csrf-token") {
            Ok(token) -> Ok(token)
            Error(Nil) -> field(fields, "csrf")
          }
          let expected = session_value(sess, "csrf_token", "")
          case csrf, field(fields, "display_name") {
            Ok(token), Ok(display_name) ->
              case token == expected {
                True -> {
                  let _sess =
                    session.set(store, sess, "display_name", display_name)
                  json_response(200, "{\"ok\":true}")
                }
                False -> text_response(403, "Invalid CSRF token")
              }
            _, _ -> text_response(403, "Invalid CSRF token")
          }
        }
      }
    }
  }
}

fn handle_logout(
  req: Request(Connection),
  store: session.SessionStore,
) -> response.Response(ResponseBody) {
  case session_from_request(req, store) {
    Error(resp) -> resp
    Ok(sess) -> {
      let expected = session_value(sess, "csrf_token", "")
      case request.get_header(req, "x-csrf-token") {
        Ok(token) ->
          case token == expected {
            True -> {
              session.delete(store, sess.id)
              text_response(200, "Logged out")
              |> cookie.delete("beacon_session")
            }
            False -> text_response(403, "Invalid CSRF token")
          }
        Error(Nil) -> text_response(403, "Invalid CSRF token")
      }
    }
  }
}

fn ws_auth(
  store: session.SessionStore,
) -> fn(Request(Connection)) -> Result(Nil, String) {
  fn(req: Request(Connection)) {
    case session_from_request(req, store) {
      Ok(_) -> Ok(Nil)
      Error(_) -> Error("unauthorized")
    }
  }
}

fn init_from_request(
  store: session.SessionStore,
) -> fn(Request(Connection)) -> #(#(Model, Server), effect.Effect(Msg)) {
  fn(req: Request(Connection)) {
    let model = case session_from_request(req, store) {
      Ok(sess) ->
        Model(
          route: req.path,
          authenticated: True,
          user: session_value(sess, "user_id", ""),
          role: session_value(sess, "role", ""),
          display_name: session_value(sess, "display_name", ""),
          csrf_token: session_value(sess, "csrf_token", ""),
          status: "Session loaded",
        )
      Error(_) -> Model(..init_model(), route: req.path)
    }
    #(#(model, init_server()), effect.none())
  }
}

fn session_from_request(
  req: Request(Connection),
  store: session.SessionStore,
) -> Result(session.Session, response.Response(ResponseBody)) {
  case cookie.get(req, "beacon_session") {
    Ok(session_id) -> {
      case session.get(store, session_id) {
        Some(sess) -> Ok(sess)
        None -> Error(text_response(401, "Invalid session"))
      }
    }
    Error(Nil) -> Error(text_response(401, "Missing session"))
  }
}

fn read_form(
  req: Request(Connection),
) -> Result(List(#(String, String)), String) {
  case transport_http.read_body(req, 4096) {
    Ok(bits) -> {
      case bit_array.to_string(bits) {
        Ok(body) -> Ok(parse_form(body))
        Error(Nil) -> Error("Invalid UTF-8 request body")
      }
    }
    Error(reason) -> Error(reason)
  }
}

fn parse_form(body: String) -> List(#(String, String)) {
  body
  |> string.split("&")
  |> list.filter_map(fn(part) {
    case string.split_once(part, "=") {
      Ok(#(name, value)) -> Ok(#(name, string.replace(value, "+", " ")))
      Error(Nil) -> Error(Nil)
    }
  })
}

fn field(fields: List(#(String, String)), name: String) -> Result(String, Nil) {
  case list.find(fields, fn(pair) { pair.0 == name }) {
    Ok(#(_, value)) -> Ok(value)
    Error(Nil) -> Error(Nil)
  }
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

fn dev_cookie_options() -> cookie.CookieOptions {
  cookie.CookieOptions(
    max_age: Some(3600),
    path: "/",
    http_only: True,
    secure: False,
    same_site: "Lax",
  )
}

fn json_response(status: Int, body: String) -> response.Response(ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

fn text_response(status: Int, body: String) -> response.Response(ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

fn find_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(key, value), ..rest] -> {
      case string.lowercase(key) == string.lowercase(name) {
        True -> Ok(value)
        False -> find_header(rest, name)
      }
    }
  }
}

fn header_contains(
  headers: List(#(String, String)),
  name: String,
  needle: String,
) -> Bool {
  case find_header(headers, name) {
    Ok(value) -> string.contains(value, needle)
    Error(Nil) -> False
  }
}

fn cookie_pair(set_cookie: String) -> String {
  case string.split(set_cookie, ";") {
    [pair, ..] -> pair
    [] -> set_cookie
  }
}

fn json_field(body: String, name: String) -> Result(String, Nil) {
  let marker = "\"" <> name <> "\":\""
  case string.split_once(body, marker) {
    Ok(#(_, tail)) -> {
      case string.split_once(tail, "\"") {
        Ok(#(value, _)) -> Ok(value)
        Error(Nil) -> Error(Nil)
      }
    }
    Error(Nil) -> Error(Nil)
  }
}

fn unique_port_offset() -> Int {
  abs(erlang_unique_pos()) % 500
}

@external(erlang, "erlang", "abs")
fn abs(n: Int) -> Int

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_pos() -> Int

pub type TcpSocket

@external(erlang, "beacon_http_client_ffi", "http_request")
fn http_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, List(#(String, String)), String), String)

@external(erlang, "beacon_http_client_ffi", "ws_connect_with_headers")
fn ws_connect_with_headers(
  host: String,
  port: Int,
  headers: List(#(String, String)),
) -> Result(TcpSocket, String)

@external(erlang, "beacon_http_client_ffi", "ws_send")
fn ws_send(socket: TcpSocket, payload: String) -> Result(Nil, String)

@external(erlang, "beacon_http_client_ffi", "ws_recv")
fn ws_recv(socket: TcpSocket, timeout: Int) -> Result(String, String)

@external(erlang, "beacon_http_client_ffi", "ws_close")
fn ws_close(socket: TcpSocket) -> Nil
