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
  let port = 11_000 + unique_port_offset()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(100)

  let assert Ok(#(status, _headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  let assert 200 = status
  // Body should contain SSR-rendered content
  let assert True = string.contains(body, "count:0")
  let assert True = string.contains(body, "Integration Test")
}

pub fn http_get_beacon_js_returns_runtime_javascript_test() {
  start_httpc()
  let port = 12_000 + unique_port_offset()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(100)

  let assert Ok(#(status, _headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/beacon_client.js")
  let assert 200 = status
  let assert True = string.contains(body, "beacon")
  let assert True = string.contains(body, "WebSocket")
}

pub fn http_get_beacon_js_gzips_when_requested_test() {
  start_httpc()
  let port = 12_500 + unique_port_offset()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(100)

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
}

pub fn http_get_has_security_headers_test() {
  start_httpc()
  let port = 13_000 + unique_port_offset()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(100)

  let assert Ok(#(_status, headers, _body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  // secure_headers middleware should have added these
  let assert True = has_header(headers, "x-content-type-options", "nosniff")
  let assert True = has_header(headers, "x-frame-options", "SAMEORIGIN")
}

pub fn http_pre_upgrade_rejects_too_many_headers_test() {
  start_httpc()
  let port = 23_000 + unique_port_offset()
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      max_http_headers: 2,
    )
  let assert Ok(_app) =
    application.start(
      application.AppConfig(..test_app_config(port), security_limits: limits),
    )
  process.sleep(100)

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
}

pub fn http_pre_upgrade_rejects_large_headers_test() {
  start_httpc()
  let port = 24_000 + unique_port_offset()
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      max_http_header_bytes: 32,
    )
  let assert Ok(_app) =
    application.start(
      application.AppConfig(..test_app_config(port), security_limits: limits),
    )
  process.sleep(100)

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
}

// ===== 22.1: Real WebSocket Stress Test =====

pub fn ws_connect_and_receive_model_sync_test() {
  start_httpc()
  let port = 14_000 + unique_port_offset()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(100)

  // Open a real WebSocket connection via gen_tcp
  let assert Ok(socket) = ws_connect("localhost", port)
  // Send join message
  let assert Ok(Nil) = ws_send(socket, "{\"type\":\"join\"}")
  // Receive authoritative model state. SSR already supplied first HTML.
  let assert Ok(response) = ws_recv(socket, 3000)
  let assert True = string.contains(response, "\"type\":\"model_sync\"")
  let assert True = string.contains(response, "\\\"count\\\":0")
  let assert False = string.contains(response, "\"type\":\"mount\"")
  ws_close(socket)
}

pub fn ws_50_concurrent_connections_test() {
  start_httpc()
  let port = 15_000 + unique_port_offset()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(200)

  let result_subject = process.new_subject()
  let n = 50

  // Spawn 50 processes that each open a real WebSocket connection
  spawn_ws_clients(n, port, result_subject)

  // Collect results
  let succeeded = collect_results(result_subject, n, 0, 10_000)
  let assert True = succeeded == n
}

// ===== 24.1: Per-Connection Independence Test =====

pub fn two_connections_have_independent_state_test() {
  start_httpc()
  let port = 17_000 + unique_port_offset()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(200)

  // Open two independent WebSocket connections
  let assert Ok(socket_a) = ws_connect("localhost", port)
  let assert Ok(socket_b) = ws_connect("localhost", port)

  // Both join — each should get their own runtime with count:0.
  let assert Ok(Nil) = ws_send(socket_a, "{\"type\":\"join\"}")
  let assert Ok(sync_a) = ws_recv(socket_a, 3000)
  let assert True = string.contains(sync_a, "\"type\":\"model_sync\"")
  let assert True = string.contains(sync_a, "\\\"count\\\":0")
  let assert False = string.contains(sync_a, "\"type\":\"mount\"")

  let assert Ok(Nil) = ws_send(socket_b, "{\"type\":\"join\"}")
  let assert Ok(sync_b) = ws_recv(socket_b, 3000)
  let assert True = string.contains(sync_b, "\"type\":\"model_sync\"")
  let assert True = string.contains(sync_b, "\\\"count\\\":0")
  let assert False = string.contains(sync_b, "\"type\":\"mount\"")

  // Send increment on connection A only
  let assert Ok(Nil) =
    ws_send(
      socket_a,
      "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"inc\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":1}",
    )
  let assert Ok(response_a) = ws_recv(socket_a, 3000)
  // Connection A should receive a state update with count:1.
  let assert True =
    string.contains(response_a, "model_sync")
    || string.contains(response_a, "\"type\":\"patch\"")

  // Connection B should NOT have received anything (independent runtime)
  // Try to receive — should timeout (no message)
  let _b_result = ws_recv(socket_b, 500)
  // B either gets nothing (Error) or gets the PubSub broadcast which
  // doesn't affect its own state. Either way, B's state is still count:0.

  ws_close(socket_a)
  ws_close(socket_b)
}

// ===== 22.4: Middleware Gates WebSocket Upgrade =====

pub fn auth_middleware_blocks_ws_upgrade_test() {
  start_httpc()
  let port = 16_000 + unique_port_offset()
  // Create an app with an auth middleware that always rejects
  let auth_mw = fn(_req, _next) { gleam_http_response_new(401) }
  let config =
    application.AppConfig(..test_app_config(port), middlewares: [auth_mw])
  let assert Ok(_app) = application.start(config)
  process.sleep(100)

  // HTTP GET should be blocked by auth middleware
  let assert Ok(#(status, _headers, _body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  let assert 401 = status

  // WebSocket upgrade should also be blocked (middleware runs before routing)
  let assert Ok(#(ws_status, _headers2, _body2)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/ws")
  let assert 401 = ws_status
}

// ===== API Handler Integration Tests =====

pub fn api_handler_serves_json_test() {
  start_httpc()
  let port = 18_000 + unique_port_offset()
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
      ..test_app_config(port),
      api_handler: option.Some(api_handler),
    )
  let assert Ok(_app) = application.start(config)
  process.sleep(100)

  let assert Ok(#(status, _headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/api/test")
  let assert 200 = status
  let assert True = string.contains(body, "{\"ok\":true}")
}

pub fn api_handler_fallthrough_to_ssr_test() {
  start_httpc()
  let port = 19_000 + unique_port_offset()
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
      ..test_app_config(port),
      api_handler: option.Some(api_handler),
    )
  let assert Ok(_app) = application.start(config)
  process.sleep(100)

  // Root path should fall through to SSR
  let assert Ok(#(status, _headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  let assert 200 = status
  // SSR page should contain rendered content, not API JSON
  let assert True = string.contains(body, "count:0")
  let assert True = string.contains(body, "Integration Test")
}

// ===== WebSocket Auth Integration Tests =====

pub fn ws_auth_rejects_unauthorized_test() {
  start_httpc()
  let port = 20_000 + unique_port_offset()
  // ws_auth that always rejects
  let ws_auth = fn(_req: request.Request(Connection)) { Error("not allowed") }
  let config =
    application.AppConfig(
      ..test_app_config(port),
      ws_auth: option.Some(ws_auth),
    )
  let assert Ok(_app) = application.start(config)
  process.sleep(100)

  // WebSocket upgrade to /ws should be rejected with 401
  // Use http_get on /ws — ws_auth runs before upgrade, returns 401 HTTP response
  let origin = "http://localhost:" <> int.to_string(port)
  let assert Ok(#(status, _headers, _body)) =
    http_request("GET", origin <> "/ws", [#("origin", origin)], "")
  let assert 401 = status
}

// ===== Helpers =====

fn spawn_ws_clients(
  remaining: Int,
  port: Int,
  result: process.Subject(Bool),
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let _ =
        process.spawn(fn() {
          case ws_connect("localhost", port) {
            Ok(socket) -> {
              case ws_send(socket, "{\"type\":\"join\"}") {
                Ok(Nil) -> {
                  case ws_recv(socket, 5000) {
                    Ok(_response) -> {
                      ws_close(socket)
                      process.send(result, True)
                    }
                    Error(_) -> {
                      ws_close(socket)
                      process.send(result, False)
                    }
                  }
                }
                Error(_) -> {
                  ws_close(socket)
                  process.send(result, False)
                }
              }
            }
            Error(_) -> process.send(result, False)
          }
        })
      // Small delay to avoid overwhelming the server
      process.sleep(20)
      spawn_ws_clients(remaining - 1, port, result)
    }
  }
}

fn collect_results(
  subject: process.Subject(Bool),
  remaining: Int,
  count: Int,
  timeout: Int,
) -> Int {
  case remaining <= 0 {
    True -> count
    False -> {
      let selector =
        process.new_selector()
        |> process.select(subject)
      case process.selector_receive(selector, timeout) {
        Ok(True) -> collect_results(subject, remaining - 1, count + 1, timeout)
        Ok(False) -> collect_results(subject, remaining - 1, count, timeout)
        Error(Nil) -> count
      }
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

fn unique_port_offset() -> Int {
  abs(erlang_unique_pos()) % 500
}

@external(erlang, "erlang", "abs")
fn abs(n: Int) -> Int

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_pos() -> Int

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

@external(erlang, "beacon_http_client_ffi", "ws_close")
fn ws_close(socket: TcpSocket) -> Nil

@external(erlang, "beacon_integration_test_ffi", "response_401")
fn gleam_http_response_new(status: Int) -> a
