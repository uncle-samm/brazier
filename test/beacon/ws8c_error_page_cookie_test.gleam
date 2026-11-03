//// A static error page loads no client and opens no session, so it sets no
//// join cookie: an init refusal (503, 401), an init crash (500) and an
//// unknown route (404) answer without `beacon_join_token`, while a rendered
//// page sets it. A join cookie a page in another tab is still joining with
//// is left in place.
////
//// Every test talks to a real server and synchronizes on the HTTP
//// response; nothing sleeps.

import beacon/app_config_fixture
import beacon/application
import beacon/effect
import beacon/error
import beacon/html
import beacon/internal/context.{type Context}
import beacon/ssr
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleam/uri

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Inc
}

/// `/` renders, `/unavailable` and `/private` are refused, `/crash`
/// crashes, and any other path is an unknown route.
fn init(ctx: Context) -> Result(#(Model, effect.Effect(Msg)), error.InitError) {
  case context.uri(ctx).path {
    "/unavailable" -> Error(error.unavailable("ws8c store is down"))
    "/private" -> Error(error.refuse(401, "ws8c not signed in"))
    "/crash" -> panic as "ws8c init crashes on purpose"
    _ -> Ok(#(Model(count: 0), effect.none()))
  }
}

fn start() -> application.App {
  let config =
    application.AppConfig(
      ..app_config_fixture.new(
        port: 0,
        init: init,
        update: fn(model: Model, _msg) {
          #(Model(count: model.count + 1), effect.none())
        },
        view: fn(model: Model) {
          html.div([], [html.text(int.to_string(model.count))])
        },
        encode_model: fn(model: Model) {
          "{\"count\":" <> int.to_string(model.count) <> "}"
        },
        decode_event: fn(_name, _handler_id, _data, _path) {
          Error(error.RuntimeError(reason: "no events"))
        },
      ),
      route: option.Some(fn(uri: uri.Uri) {
        case uri.path {
          "/" | "/unavailable" | "/private" | "/crash" -> Ok(Inc)
          _ -> Error(Nil)
        }
      }),
    )
  let assert Ok(app) = application.start(config)
  app
}

fn stop(app: application.App) -> Nil {
  let assert Ok(Nil) = application.stop(app)
  Nil
}

fn get(
  app: application.App,
  path: String,
  headers: List(#(String, String)),
) -> #(Int, List(#(String, String))) {
  let url = "http://localhost:" <> int.to_string(app.port) <> path
  let assert Ok(#(status, response_headers, _body)) =
    http_request("GET", url, headers, "")
    as "the server must answer the page request"
  #(status, response_headers)
}

/// Whether the response sets the join cookie.
fn sets_join_cookie(headers: List(#(String, String))) -> Bool {
  list.any(headers, fn(header) {
    string.lowercase(header.0) == "set-cookie"
    && string.starts_with(header.1, ssr.session_cookie_name <> "=")
  })
}

pub fn rendered_page_sets_the_join_cookie_test() {
  let app = start()
  let #(status, headers) = get(app, "/", [])
  stop(app)
  let assert 200 = status
  let assert True = sets_join_cookie(headers)
    as "a page that loads the client carries a join token"
}

pub fn unavailable_init_page_sets_no_join_cookie_test() {
  let app = start()
  let #(status, headers) = get(app, "/unavailable", [])
  stop(app)
  let assert 503 = status
  let assert False = sets_join_cookie(headers)
    as "a 503 refusal opens no session"
}

pub fn refused_init_page_sets_no_join_cookie_test() {
  let app = start()
  let #(status, headers) = get(app, "/private", [])
  stop(app)
  let assert 401 = status
  let assert False = sets_join_cookie(headers)
    as "a 401 refusal opens no session"
}

pub fn crashed_init_page_sets_no_join_cookie_test() {
  let app = start()
  let #(status, headers) = get(app, "/crash", [])
  stop(app)
  let assert 500 = status
  let assert False = sets_join_cookie(headers)
    as "an init crash opens no session"
}

pub fn unknown_route_page_sets_no_join_cookie_test() {
  let app = start()
  let #(status, headers) = get(app, "/missing", [])
  stop(app)
  let assert 404 = status
  let assert False = sets_join_cookie(headers)
    as "an unknown route opens no session"
}

/// A browser that holds a join cookie from a rendered page keeps it when
/// another request is refused: the refusal neither replaces nor clears it.
pub fn refusal_leaves_an_existing_join_cookie_alone_test() {
  let app = start()
  let assert #(200, first) = get(app, "/", [])
  let assert Ok(#(_, set_cookie)) =
    list.find(first, fn(header) {
      string.lowercase(header.0) == "set-cookie"
      && string.starts_with(header.1, ssr.session_cookie_name <> "=")
    })
  let assert [pair, ..] = string.split(set_cookie, ";")
  let #(status, headers) = get(app, "/unavailable", [#("cookie", pair)])
  stop(app)
  let assert 503 = status
  let assert False =
    list.any(headers, fn(header) { string.lowercase(header.0) == "set-cookie" })
    as "a refusal must not touch the join cookie"
}

@external(erlang, "beacon_http_client_ffi", "http_request")
fn http_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, List(#(String, String)), String), String)
