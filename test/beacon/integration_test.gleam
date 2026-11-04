/// Real integration tests — starts a server and makes actual HTTP/WebSocket requests.
/// No mocks. Real network calls.
import beacon/app_config_fixture
import beacon/application
import beacon/attribute
import beacon/effect
import beacon/error
import beacon/html
import beacon/transport
import beacon/transport/server.{type Connection, Bytes}
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option
import gleam/string

// --- App setup ---

pub type TestModel {
  TestModel(count: Int)
}

pub type TestMsg {
  TestInc
}

fn test_app_config(port: Int) -> application.AppConfig(TestModel, TestMsg) {
  application.AppConfig(
    ..app_config_fixture.new(
      port: port,
      init: fn(_ctx) { Ok(#(TestModel(count: 0), effect.none())) },
      update: fn(model, _msg) {
        #(TestModel(count: model.count + 1), effect.none())
      },
      view: fn(model: TestModel) {
        html.div([attribute.id("app")], [
          html.text("count:" <> int.to_string(model.count)),
        ])
      },
      encode_model: fn(model: TestModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      },
      decode_event: fn(_name, handler_id, _data, _path) {
        case handler_id {
          "inc" -> Ok(TestInc)
          _ -> Error(error.RuntimeError(reason: "unknown"))
        }
      },
    ),
    title: fn(_model) { "Integration Test" },
  )
}

// ===== 22.3: Real HTTP Integration Tests =====

pub fn http_get_root_returns_200_with_ssr_html_test() {
  start_httpc()
  let assert Ok(app) = application.start(test_app_config(0))
  let port = app.port

  let assert Ok(#(status, _headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  let assert 200 = status
  // Body should contain SSR-rendered content
  let assert True = string.contains(body, "count:0")
  let assert True = string.contains(body, "Integration Test")
  stop(app)
}

pub fn http_get_beacon_js_returns_runtime_javascript_test() {
  start_httpc()
  let assert Ok(app) = application.start(test_app_config(0))
  let port = app.port

  let assert Ok(#(status, _headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/beacon_client.js")
  let assert 200 = status
  let assert True = string.contains(body, "beacon")
  let assert True = string.contains(body, "WebSocket")
  stop(app)
}

pub fn http_get_beacon_js_gzips_when_requested_test() {
  start_httpc()
  let assert Ok(app) = application.start(test_app_config(0))
  let port = app.port

  let assert Ok(#(status, headers, _body)) =
    http_request(
      "GET",
      "http://localhost:" <> int.to_string(port) <> "/beacon_client.js",
      [#("accept-encoding", "gzip")],
      "",
    )
  let assert 200 = status
  let assert True = has_header(headers, "content-encoding", "gzip")
  let assert True = has_header(headers, "vary", "accept-encoding")
  stop(app)
}

pub fn http_get_has_security_headers_test() {
  start_httpc()
  let assert Ok(app) = application.start(test_app_config(0))
  let port = app.port

  let assert Ok(#(_status, headers, _body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  // secure_headers middleware should have added these
  let assert True = has_header(headers, "x-content-type-options", "nosniff")
  let assert True = has_header(headers, "x-frame-options", "SAMEORIGIN")
  stop(app)
}

pub fn http_pre_upgrade_rejects_too_many_headers_test() {
  start_httpc()
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      max_http_headers: 2,
    )
  let assert Ok(app) =
    application.start(
      application.AppConfig(..test_app_config(0), security_limits: limits),
    )
  let port = app.port

  let result =
    http_request(
      "GET",
      "http://localhost:" <> int.to_string(port) <> "/",
      [
        #("x-one", "1"),
        #("x-two", "2"),
        #("x-three", "3"),
      ],
      "",
    )
  // RFC 6585: too many header fields is answered with 431, then closed.
  let assert Ok(#(431, headers, _body)) = result
  let assert True = has_header(headers, "connection", "close")
  stop(app)
}

pub fn http_pre_upgrade_rejects_large_headers_test() {
  start_httpc()
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      max_http_header_bytes: 32,
    )
  let assert Ok(app) =
    application.start(
      application.AppConfig(..test_app_config(0), security_limits: limits),
    )
  let port = app.port

  let result =
    http_request(
      "GET",
      "http://localhost:" <> int.to_string(port) <> "/",
      [#("x-large", string.repeat("x", 128))],
      "",
    )
  // RFC 6585: an oversized header block is answered with 431, then closed.
  let assert Ok(#(431, headers, _body)) = result
  let assert True = has_header(headers, "connection", "close")
  stop(app)
}

// ===== 22.1: Real WebSocket Stress Test =====

pub fn ws_connect_and_receive_model_sync_test() {
  start_httpc()
  let assert Ok(app) = application.start(test_app_config(0))
  let port = app.port

  // Open a real WebSocket connection via gen_tcp
  let assert Ok(socket) = ws_connect("localhost", port)
  // Send join message
  let assert Ok(Nil) = ws_send(socket, "{\"type\":\"join\"}")
  // Receive authoritative model state. SSR already supplied first HTML.
  let assert Ok(response) = ws_recv(socket, 3000)
  let assert True = string.contains(response, "\"type\":\"model_sync\"")
  let assert True = string.contains(response, "\\\"count\\\":0")
  let assert False = string.contains(response, "\"type\":\"mount\"")
  // The page title follows the join's model_sync.
  let assert Ok(title) = ws_recv(socket, 3000)
  let assert "{\"type\":\"title\",\"title\":\"Integration Test\"}" = title
  let assert Ok(Nil) = ws_close_graceful(socket, 5000)
  stop(app)
}

pub fn ws_50_concurrent_connections_test() {
  start_httpc()
  let assert Ok(app) = application.start(test_app_config(0))
  let port = app.port

  let results = process.new_subject()
  let n = 50

  // 50 processes connect at once: each joins, must get its model_sync,
  // then closes with a close handshake.
  spawn_ws_clients(n, port, results)

  let assert [] = collect_failures(results, n, [])
  stop(app)
}

// ===== 24.1: Per-Connection Independence Test =====

pub fn two_connections_have_independent_state_test() {
  start_httpc()
  let assert Ok(app) = application.start(test_app_config(0))
  let port = app.port

  // Open two independent WebSocket connections
  let assert Ok(socket_a) = ws_connect("localhost", port)
  let assert Ok(socket_b) = ws_connect("localhost", port)

  // Both join — each should get their own runtime with count:0.
  let assert Ok(Nil) = ws_send(socket_a, "{\"type\":\"join\"}")
  let assert Ok(sync_a) = ws_recv(socket_a, 3000)
  let assert True = string.contains(sync_a, "\"type\":\"model_sync\"")
  let assert True = string.contains(sync_a, "\\\"count\\\":0")
  let assert False = string.contains(sync_a, "\"type\":\"mount\"")
  let assert Ok(title_a) = ws_recv(socket_a, 3000)
  let assert True = string.contains(title_a, "\"type\":\"title\"")

  let assert Ok(Nil) = ws_send(socket_b, "{\"type\":\"join\"}")
  let assert Ok(sync_b) = ws_recv(socket_b, 3000)
  let assert True = string.contains(sync_b, "\"type\":\"model_sync\"")
  let assert True = string.contains(sync_b, "\\\"count\\\":0")
  let assert False = string.contains(sync_b, "\"type\":\"mount\"")
  let assert Ok(title_b) = ws_recv(socket_b, 3000)
  let assert True = string.contains(title_b, "\"type\":\"title\"")

  // Send increment on connection A only
  let assert Ok(Nil) =
    ws_send(
      socket_a,
      "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"inc\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":1}",
    )
  let assert Ok(response_a) = ws_recv(socket_a, 3000)
  // Connection A moves to count 1.
  let assert True = string.contains(response_a, "\"type\":\"patch\"")
  let assert True = string.contains(response_a, count_is(1))

  // B sends its own increment. If B shared A's runtime it would move to 2,
  // and if A's update had reached B, that message would arrive first.
  // B's next message is its own patch to count 1.
  let assert Ok(Nil) =
    ws_send(
      socket_b,
      "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"inc\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":1}",
    )
  let assert Ok(response_b) = ws_recv(socket_b, 3000)
  let assert True = string.contains(response_b, "\"type\":\"patch\"")
  let assert True = string.contains(response_b, count_is(1))

  let assert Ok(Nil) = ws_close_graceful(socket_a, 5000)
  let assert Ok(Nil) = ws_close_graceful(socket_b, 5000)
  stop(app)
}

/// The patch op that sets the model's count, as it appears inside a
/// patch message (the ops array is carried as a JSON string).
fn count_is(n: Int) -> String {
  "{\\\"op\\\":\\\"replace\\\",\\\"path\\\":\\\"/count\\\",\\\"value\\\":"
  <> int.to_string(n)
  <> "}"
}

// ===== 22.4: Middleware Gates WebSocket Upgrade =====

pub fn auth_middleware_blocks_ws_upgrade_test() {
  start_httpc()
  // Create an app with an auth middleware that always rejects
  let auth_mw = fn(_req, _next) { gleam_http_response_new(401) }
  let config =
    application.AppConfig(..test_app_config(0), middlewares: [auth_mw])
  let assert Ok(app) = application.start(config)
  let port = app.port

  // HTTP GET should be blocked by auth middleware
  let assert Ok(#(status, _headers, _body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  let assert 401 = status

  // WebSocket upgrade should also be blocked (middleware runs before routing)
  let assert Ok(#(ws_status, _headers2, _body2)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/ws")
  let assert 401 = ws_status
  stop(app)
}

// ===== API Handler Integration Tests =====

pub fn api_handler_serves_json_test() {
  start_httpc()
  let api_handler = fn(req: request.Request(Connection)) {
    case request.path_segments(req) {
      ["api", "test"] ->
        option.Some(
          response.new(200)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(Bytes(bytes_tree.from_string("{\"ok\":true}"))),
        )
      _ -> option.None
    }
  }
  let config =
    application.AppConfig(
      ..test_app_config(0),
      api_handler: option.Some(api_handler),
    )
  let assert Ok(app) = application.start(config)
  let port = app.port

  let assert Ok(#(status, _headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/api/test")
  let assert 200 = status
  let assert True = string.contains(body, "{\"ok\":true}")
  stop(app)
}

pub fn api_handler_fallthrough_to_ssr_test() {
  start_httpc()
  // API handler that only handles /api/* — everything else falls through
  let api_handler = fn(req: request.Request(Connection)) {
    case request.path_segments(req) {
      ["api", ..] ->
        option.Some(
          response.new(200)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(Bytes(bytes_tree.from_string("{\"api\":true}"))),
        )
      _ -> option.None
    }
  }
  let config =
    application.AppConfig(
      ..test_app_config(0),
      api_handler: option.Some(api_handler),
    )
  let assert Ok(app) = application.start(config)
  let port = app.port

  // Root path should fall through to SSR
  let assert Ok(#(status, _headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  let assert 200 = status
  // SSR page should contain rendered content, not API JSON
  let assert True = string.contains(body, "count:0")
  let assert True = string.contains(body, "Integration Test")
  stop(app)
}

// ===== WebSocket Auth Integration Tests =====

pub fn ws_auth_rejects_unauthorized_test() {
  start_httpc()
  // ws_auth that always rejects
  let ws_auth = fn(_req: request.Request(Connection)) { Error("not allowed") }
  let config =
    application.AppConfig(..test_app_config(0), ws_auth: option.Some(ws_auth))
  let assert Ok(app) = application.start(config)
  let port = app.port

  // WebSocket upgrade to /ws should be rejected with 401
  // Use http_get on /ws — ws_auth runs before upgrade, returns 401 HTTP response
  let origin = "http://localhost:" <> int.to_string(port)
  let assert Ok(#(status, _headers, _body)) =
    http_request("GET", origin <> "/ws", [#("origin", origin)], "")
  let assert 401 = status
  stop(app)
}

// ===== Helpers =====

fn spawn_ws_clients(
  remaining: Int,
  port: Int,
  results: process.Subject(Result(Nil, String)),
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      process.spawn(fn() { process.send(results, join_and_close(port)) })
      spawn_ws_clients(remaining - 1, port, results)
    }
  }
}

/// Connect, join, expect the model_sync, close. Every step's error is
/// returned with the step's name.
fn join_and_close(port: Int) -> Result(Nil, String) {
  case ws_connect("localhost", port) {
    Error(reason) -> Error("connect: " <> reason)
    Ok(socket) -> {
      let joined = case ws_send(socket, "{\"type\":\"join\"}") {
        Error(reason) -> Error("join: " <> reason)
        Ok(Nil) ->
          case ws_recv(socket, 5000) {
            Error(reason) -> Error("model_sync: " <> reason)
            Ok(response) ->
              case string.contains(response, "\"type\":\"model_sync\"") {
                True -> Ok(Nil)
                False -> Error("expected model_sync, got " <> response)
              }
          }
      }
      // Close in every case; a close failure only matters after a join.
      let closed = ws_close_graceful(socket, 5000)
      case joined, closed {
        Error(reason), _ -> Error(reason)
        Ok(Nil), Error(reason) -> Error("close: " <> reason)
        Ok(Nil), Ok(Nil) -> Ok(Nil)
      }
    }
  }
}

/// Wait for `remaining` results; return the failures. A client silent
/// for 10 s is a failure too.
fn collect_failures(
  results: process.Subject(Result(Nil, String)),
  remaining: Int,
  failures: List(String),
) -> List(String) {
  case remaining <= 0 {
    True -> failures
    False ->
      case process.receive(results, 10_000) {
        Ok(Ok(Nil)) -> collect_failures(results, remaining - 1, failures)
        Ok(Error(reason)) ->
          collect_failures(results, remaining - 1, [reason, ..failures])
        Error(Nil) -> [
          int.to_string(remaining) <> " clients sent no result within 10 s",
          ..failures
        ]
      }
  }
}

fn has_header(
  headers: List(#(String, String)),
  name: String,
  expected_value: String,
) -> Bool {
  case headers {
    [] -> False
    [#(k, v), ..rest] -> {
      case string.lowercase(k) == string.lowercase(name) {
        True ->
          string.contains(string.lowercase(v), string.lowercase(expected_value))
        False -> has_header(rest, name, expected_value)
      }
    }
  }
}

fn stop(app: application.App) -> Nil {
  let assert Ok(Nil) = application.stop(app)
  Nil
}

@external(erlang, "beacon_http_client_ffi", "start_httpc")
fn start_httpc() -> Nil

@external(erlang, "beacon_http_client_ffi", "http_get")
fn http_get(
  url: String,
) -> Result(#(Int, List(#(String, String)), String), String)

@external(erlang, "beacon_http_client_ffi", "http_request")
fn http_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, List(#(String, String)), String), String)

pub type TcpSocket

@external(erlang, "beacon_http_client_ffi", "ws_connect")
fn ws_connect(host: String, port: Int) -> Result(TcpSocket, String)

@external(erlang, "beacon_http_client_ffi", "ws_send")
fn ws_send(socket: TcpSocket, payload: String) -> Result(Nil, String)

@external(erlang, "beacon_http_client_ffi", "ws_recv")
fn ws_recv(socket: TcpSocket, timeout: Int) -> Result(String, String)

@external(erlang, "beacon_http_client_ffi", "ws_close_graceful")
fn ws_close_graceful(socket: TcpSocket, timeout: Int) -> Result(Nil, String)

@external(erlang, "beacon_integration_test_ffi", "response_401")
fn gleam_http_response_new(status: Int) -> a
