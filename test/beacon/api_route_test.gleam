/// Tests for the API route handler feature.
/// Verifies that api_handler runs before SSR/static and can handle or pass through requests.
import beacon/api
import beacon/app_config_fixture
import beacon/application
import beacon/attribute
import beacon/effect
import beacon/html
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should

type TestModel {
  TestModel(count: Int)
}

type TestMsg {
  TestInc
}

fn test_app_config(
  port: Int,
  text: String,
) -> application.AppConfig(TestModel, TestMsg) {
  app_config_fixture.new(
    port: port,
    init: fn(_ctx) { Ok(#(TestModel(count: 0), effect.none())) },
    update: fn(model, _msg) {
      #(TestModel(count: model.count + 1), effect.none())
    },
    view: fn(model: TestModel) {
      html.div([attribute.id("app")], [
        html.text(text <> int.to_string(model.count)),
      ])
    },
    encode_model: fn(model: TestModel) {
      "{\"count\":" <> int.to_string(model.count) <> "}"
    },
    decode_event: fn(_name, _hid, _data, _path) { Ok(TestInc) },
  )
}

fn test_app_config_with_api(
  port: Int,
  api_handler: fn(Request(Connection)) ->
    option.Option(response.Response(ResponseBody)),
) -> application.AppConfig(TestModel, TestMsg) {
  application.AppConfig(
    ..test_app_config(port, "count:"),
    api_handler: option.Some(api_handler),
  )
}

/// API handler returns a custom response for /api/hello.
pub fn api_route_handler_serves_response_test() {
  let api = fn(req: Request(Connection)) {
    case request.path_segments(req) {
      ["api", "hello"] ->
        option.Some(
          response.new(200)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(
            Bytes(bytes_tree.from_string("{\"greeting\":\"hello\"}")),
          ),
        )
      _ -> option.None
    }
  }
  let config = test_app_config_with_api(0, api)
  let assert Ok(app) = application.start(config)
  let port = app.port

  // Request /api/hello — should get the custom API response
  let resp = http_get(port, "/api/hello")
  should.equal(resp.status, 200)
  should.equal(resp.body, "{\"greeting\":\"hello\"}")
  let assert Ok(Nil) = application.stop(app)
}

/// API handler returns None for unknown paths — falls through to SSR.
pub fn api_route_handler_falls_through_test() {
  let api = fn(req: Request(Connection)) {
    case request.path_segments(req) {
      ["api", "hello"] ->
        option.Some(
          response.new(200)
          |> response.set_body(Bytes(bytes_tree.from_string("api"))),
        )
      _ -> option.None
    }
  }
  let config = test_app_config_with_api(0, api)
  let assert Ok(app) = application.start(config)
  let port = app.port

  // Request / — should fall through to SSR (page HTML)
  let resp = http_get(port, "/")
  should.equal(resp.status, 200)
  // The SSR page, with the view rendered for the initial model.
  should.be_true(contains_string(resp.body, "<!DOCTYPE html>"))
  should.be_true(contains_string(resp.body, "count:0"))
  let assert Ok(Nil) = application.stop(app)
}

/// API handler can serve POST requests (method is preserved).
pub fn api_route_handler_post_method_test() {
  let api = fn(req: Request(Connection)) {
    case req.method, request.path_segments(req) {
      http.Post, ["api", "data"] ->
        option.Some(
          response.new(201)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(
            Bytes(bytes_tree.from_string("{\"created\":true}")),
          ),
        )
      http.Get, ["api", "data"] ->
        option.Some(
          response.new(200)
          |> response.set_body(
            Bytes(bytes_tree.from_string("{\"method\":\"get\"}")),
          ),
        )
      _, _ -> option.None
    }
  }
  let config = test_app_config_with_api(0, api)
  let assert Ok(app) = application.start(config)
  let port = app.port

  // GET and POST to the same path reach different branches.
  let resp = http_get(port, "/api/data")
  should.equal(resp.status, 200)
  should.equal(resp.body, "{\"method\":\"get\"}")
  let assert Ok(#(post_status, _headers, post_body)) =
    http_request(
      "POST",
      "http://localhost:" <> int.to_string(port) <> "/api/data",
      [],
      "",
    )
  should.equal(post_status, 201)
  should.equal(post_body, "{\"created\":true}")
  let assert Ok(Nil) = application.stop(app)
}

pub fn typed_api_routes_match_get_and_set_json_header_test() {
  let api_handler =
    api.routes([
      api.get("/api/status", fn(_req) { api.json(200, "{\"status\":\"ok\"}") }),
    ])
  let config = test_app_config_with_api(0, api_handler)
  let assert Ok(app) = application.start(config)
  let port = app.port

  let assert Ok(#(status, headers, body)) =
    http_request(
      "GET",
      "http://localhost:" <> int.to_string(port) <> "/api/status",
      [],
      "",
    )
  should.equal(status, 200)
  should.equal(body, "{\"status\":\"ok\"}")
  should.be_true(has_header(headers, "content-type", "application/json"))
  let assert Ok(Nil) = application.stop(app)
}

pub fn typed_api_routes_match_in_order_test() {
  let api_handler =
    api.routes([
      api.get("/api/items", fn(_req) { api.text(200, "first") }),
      api.get("/api/items", fn(_req) { api.text(200, "second") }),
    ])
  let config = test_app_config_with_api(0, api_handler)
  let assert Ok(app) = application.start(config)
  let port = app.port

  let resp = http_get(port, "/api/items")
  should.equal(resp.status, 200)
  should.equal(resp.body, "first")
  let assert Ok(Nil) = application.stop(app)
}

pub fn typed_api_routes_fall_through_on_method_mismatch_test() {
  let api_handler =
    api.routes([
      api.post("/api/items", fn(_req) { api.json(201, "{\"created\":true}") }),
    ])
  let config = test_app_config_with_api(0, api_handler)
  let assert Ok(app) = application.start(config)
  let port = app.port

  let resp = http_get(port, "/api/items")
  should.equal(resp.status, 200)
  should.be_true(contains_string(resp.body, "<!DOCTYPE html>"))
  let assert Ok(Nil) = application.stop(app)
}

pub fn typed_api_routes_handle_post_test() {
  let api_handler =
    api.routes([
      api.post("/api/items", fn(_req) { api.json(201, "{\"created\":true}") }),
    ])
  let config = test_app_config_with_api(0, api_handler)
  let assert Ok(app) = application.start(config)
  let port = app.port

  let assert Ok(#(status, _headers, body)) =
    http_request(
      "POST",
      "http://localhost:" <> int.to_string(port) <> "/api/items",
      [],
      "",
    )
  should.equal(status, 201)
  should.equal(body, "{\"created\":true}")
  let assert Ok(Nil) = application.stop(app)
}

pub fn typed_api_json_value_encodes_json_test() {
  let api_handler =
    api.routes([
      api.get("/api/status", fn(_req) {
        api.json_value(
          200,
          json.object([
            #("status", json.string("ok")),
            #("ready", json.bool(True)),
          ]),
        )
      }),
    ])
  let config = test_app_config_with_api(0, api_handler)
  let assert Ok(app) = application.start(config)
  let port = app.port

  let assert Ok(#(status, headers, body)) =
    http_request(
      "GET",
      "http://localhost:" <> int.to_string(port) <> "/api/status",
      [],
      "",
    )
  should.equal(status, 200)
  should.equal(body, "{\"status\":\"ok\",\"ready\":true}")
  should.be_true(has_header(headers, "content-type", "application/json"))
  let assert Ok(Nil) = application.stop(app)
}

pub fn typed_api_read_text_reads_limited_utf8_body_test() {
  let api_handler =
    api.routes([
      api.post("/api/echo", fn(req) {
        case api.read_text(req, 32) {
          Ok(body) -> api.text(200, body)
          Error(reason) -> api.text(400, reason)
        }
      }),
    ])
  let config = test_app_config_with_api(0, api_handler)
  let assert Ok(app) = application.start(config)
  let port = app.port

  let assert Ok(#(status, _headers, body)) =
    http_request(
      "POST",
      "http://localhost:" <> int.to_string(port) <> "/api/echo",
      [#("content-type", "text/plain")],
      "hello body",
    )
  should.equal(status, 200)
  should.equal(body, "hello body")
  let assert Ok(Nil) = application.stop(app)
}

pub fn typed_api_read_form_decodes_required_fields_test() {
  let api_handler =
    api.routes([
      api.post("/api/login", fn(req) {
        case api.read_form(req, 128) {
          Ok(fields) -> {
            case api.form_field(fields, "username") {
              Ok(username) -> api.text(200, username)
              Error(reason) -> api.text(400, reason)
            }
          }
          Error(reason) -> api.text(400, reason)
        }
      }),
    ])
  let config = test_app_config_with_api(0, api_handler)
  let assert Ok(app) = application.start(config)
  let port = app.port

  let assert Ok(#(status, _headers, body)) =
    http_request(
      "POST",
      "http://localhost:" <> int.to_string(port) <> "/api/login",
      [#("content-type", "application/x-www-form-urlencoded")],
      "username=Ada+Lovelace&csrf=a%20token",
    )
  should.equal(status, 200)
  should.equal(body, "Ada Lovelace")
  let assert Ok(Nil) = application.stop(app)
}

pub fn typed_api_form_field_reports_missing_field_test() {
  should.equal(
    api.form_field([#("username", "ada")], "csrf"),
    Error("Missing form field: csrf"),
  )
}

/// No API handler configured — all requests go to SSR.
pub fn no_api_handler_falls_through_test() {
  let config =
    application.AppConfig(..test_app_config(0, "hello"), middlewares: [])
  let assert Ok(app) = application.start(config)
  let port = app.port

  let resp = http_get(port, "/")
  should.equal(resp.status, 200)
  // The SSR page, with the view rendered for the initial model.
  should.be_true(contains_string(resp.body, "<!DOCTYPE html>"))
  should.be_true(contains_string(resp.body, "hello0"))
  let assert Ok(Nil) = application.stop(app)
}

// --- HTTP client helper ---

type SimpleResponse {
  SimpleResponse(status: Int, body: String)
}

fn http_get(port: Int, path: String) -> SimpleResponse {
  let url = "http://localhost:" <> int.to_string(port) <> path
  case http_request("GET", url, [], "") {
    Ok(#(status, _headers, body)) -> SimpleResponse(status: status, body: body)
    Error(reason) -> panic as { "HTTP GET " <> path <> " failed: " <> reason }
  }
}

@external(erlang, "beacon_http_client_ffi", "http_request")
fn http_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, List(#(String, String)), String), String)

fn contains_string(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

fn has_header(
  headers: List(#(String, String)),
  expected_name: String,
  expected_value: String,
) -> Bool {
  list.any(headers, fn(header) {
    let #(name, value) = header
    string.lowercase(name) == expected_name && value == expected_value
  })
}
