//// `transport/http.read_body` and `transport/server.read_body` name every
//// reason they return no body. Each reason is driven here through a real
//// listener over a raw socket (or, for the two that a listener never lets
//// a request reach, through a request built outside one), and the handler
//// reports the exact error it saw.

import brazier/api
import brazier/log_capture
import brazier/transport
import brazier/transport/http as transport_http
import brazier/transport/server.{type Connection, type Socket, Bytes}
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/option.{type Option, None, Some}

/// The `max_bytes` every read in this file allows.
const limit = 16

/// What a handler saw, sent to the test process before it answers.
type Report {
  Read(Result(BitArray, transport_http.ReadBodyError))
  Raw(Result(BitArray, server.BodyReadError))
  Text(Result(String, String))
}

fn handler(
  reports: Subject(Report),
) -> fn(Request(Connection)) -> Option(response.Response(server.ResponseBody)) {
  fn(req: Request(Connection)) {
    let server.Connection(socket:, ..) = req.body
    case req.path {
      "/read" -> {
        let result = transport_http.read_body(req, limit)
        process.send(reports, Read(result))
        Some(reply(status_for(result)))
      }
      "/twice" -> {
        let first = transport_http.read_body(req, limit)
        let second = transport_http.read_body(req, limit)
        process.send(reports, Read(first))
        process.send(reports, Read(second))
        Some(reply(200))
      }
      "/past" -> {
        let past = server.read_body(socket, 999)
        process.send(reports, Raw(past))
        let result = transport_http.read_body(req, limit)
        process.send(reports, Read(result))
        Some(reply(status_for(result)))
      }
      "/text" -> {
        process.send(reports, Text(api.read_text(req, limit)))
        Some(reply(200))
      }
      _ -> Some(reply(200))
    }
  }
}

fn status_for(result: Result(BitArray, transport_http.ReadBodyError)) -> Int {
  case result {
    Ok(_) -> 200
    Error(transport_http.BodyTooLarge(..)) -> 413
    Error(transport_http.MissingContentLength)
    | Error(transport_http.InvalidContentLength)
    | Error(transport_http.BodyAlreadyConsumed)
    | Error(transport_http.BodyReadFailed(..)) -> 400
  }
}

fn reply(status: Int) -> response.Response(server.ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(Bytes(bytes_tree.from_string("done")))
}

fn limits(
  body_read_timeout_ms: Int,
  request_timeout_ms: Int,
) -> transport.SecurityLimits {
  transport.SecurityLimits(
    ..transport.default_security_limits(),
    pre_upgrade_timeout_ms: 1000,
    keepalive_idle_timeout_ms: 1000,
    body_read_timeout_ms: body_read_timeout_ms,
    request_timeout_ms: request_timeout_ms,
    allowed_hosts: ["x"],
  )
}

fn start(
  limits: transport.SecurityLimits,
) -> #(server.Listener, Subject(Report)) {
  let reports = process.new_subject()
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_id, _subject) { Nil },
      on_event: fn(_id, _msg) { Nil },
      on_disconnect: fn(_id) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: None,
      ws_auth: None,
      ssr_factory: None,
      security_limits: limits,
      api_handler: Some(handler(reports)),
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "test listener must bind an OS-assigned port"
  #(listener, reports)
}

fn open(listener: server.Listener) -> Socket {
  let assert Ok(socket) = raw_connect(server.get_port(listener))
    as "test client must connect to the listener"
  socket
}

fn send(socket: Socket, data: String) -> Nil {
  let assert Ok(Nil) = raw_send(socket, <<data:utf8>>)
    as "test client send must succeed"
  Nil
}

fn post(path: String, length: String, body: String) -> String {
  "POST "
  <> path
  <> " HTTP/1.1\r\nHost: x\r\nContent-Length: "
  <> length
  <> "\r\n\r\n"
  <> body
}

/// The next report. The handler sends it before it answers, so a test
/// that has its response already has its report.
fn next_report(reports: Subject(Report)) -> Report {
  let assert Ok(report) = process.receive(reports, 2000)
    as "the handler must report what read_body returned"
  report
}

fn expect_status(socket: Socket, status: Int) -> Nil {
  let assert Ok(#(got, _, _)) = raw_recv_response(socket, 2000, True)
    as "the server must answer"
  let assert True = got == status
  Nil
}

// --- Through a listener ---

pub fn missing_content_length_is_named_test() {
  let #(listener, reports) = start(limits(1000, 5000))
  let socket = open(listener)
  send(socket, "POST /read HTTP/1.1\r\nHost: x\r\n\r\n")
  expect_status(socket, 400)
  let assert Read(Error(transport_http.MissingContentLength)) =
    next_report(reports)
  // There was no body to lose: the connection serves the next request.
  send(socket, "GET /after HTTP/1.1\r\nHost: x\r\n\r\n")
  expect_status(socket, 200)
  raw_close(socket)
  server.stop(listener)
}

/// The listener's own framing refuses a malformed Content-Length with 400
/// before any handler runs, so read_body never sees one from a listener;
/// `invalid_content_length_outside_a_listener_is_named_test` covers it.
pub fn invalid_content_length_never_reaches_the_handler_test() {
  let #(listener, reports) = start(limits(1000, 5000))
  let socket = open(listener)
  send(socket, post("/read", "12x", ""))
  expect_status(socket, 400)
  // A handler that ran would have reported before the answer above.
  let assert Error(Nil) = process.receive(reports, 0)
  raw_close(socket)
  server.stop(listener)
}

pub fn body_over_the_limit_is_413_and_leaves_the_connection_usable_test() {
  let #(listener, reports) = start(limits(1000, 5000))
  let socket = open(listener)
  send(socket, post("/read", "17", "0123456789abcdefg"))
  expect_status(socket, 413)
  let assert Read(Error(transport_http.BodyTooLarge(length: 17, limit: 16))) =
    next_report(reports)
  // Nothing was read; the small leftover is discarded after the answer
  // and the connection serves the next request.
  send(socket, "GET /after HTTP/1.1\r\nHost: x\r\n\r\n")
  expect_status(socket, 200)
  raw_close(socket)
  server.stop(listener)
}

pub fn second_read_is_already_consumed_test() {
  let #(listener, reports) = start(limits(1000, 5000))
  let socket = open(listener)
  send(socket, post("/twice", "5", "hello"))
  expect_status(socket, 200)
  let assert Read(Ok(<<"hello":utf8>>)) = next_report(reports)
  let assert Read(Error(transport_http.BodyAlreadyConsumed)) =
    next_report(reports)
  raw_close(socket)
  server.stop(listener)
}

pub fn slow_body_is_a_read_timeout_test() {
  let #(listener, reports) = start(limits(300, 5000))
  let socket = open(listener)
  send(socket, post("/read", "10", "abc"))
  expect_status(socket, 400)
  let assert Read(Error(transport_http.BodyReadFailed(server.BodyReadTimeout))) =
    next_report(reports)
  // The rest of the body can no longer be found in the stream: closed.
  let assert Ok(True) = raw_wait_closed(socket, 2000)
  server.stop(listener)
}

pub fn read_after_a_failed_read_is_unavailable_test() {
  let #(listener, reports) = start(limits(300, 5000))
  let socket = open(listener)
  send(socket, post("/twice", "10", "abc"))
  expect_status(socket, 200)
  let assert Read(Error(transport_http.BodyReadFailed(server.BodyReadTimeout))) =
    next_report(reports)
  let assert Read(Error(transport_http.BodyReadFailed(server.BodyUnavailable))) =
    next_report(reports)
  let assert Ok(True) = raw_wait_closed(socket, 2000)
  server.stop(listener)
}

/// The per-read timeout (5 s) is longer than what is left of the request
/// deadline (300 ms), so the deadline ends the wait and is what is named.
pub fn body_past_the_request_deadline_is_named_test() {
  let #(listener, reports) = start(limits(5000, 300))
  let socket = open(listener)
  send(socket, post("/read", "10", "abc"))
  expect_status(socket, 400)
  let assert Read(Error(transport_http.BodyReadFailed(
    server.RequestDeadlineExceeded,
  ))) = next_report(reports)
  let assert Ok(True) = raw_wait_closed(socket, 2000)
  server.stop(listener)
}

pub fn peer_closing_mid_body_is_a_socket_failure_test() {
  let #(listener, reports) = start(limits(5000, 10_000))
  let socket = open(listener)
  send(socket, post("/read", "10", "abc"))
  raw_close(socket)
  let assert Read(Error(transport_http.BodyReadFailed(server.SocketFailed(
    reason: "closed",
  )))) = next_report(reports)
  server.stop(listener)
}

/// Asking for more than is left is refused without touching the body,
/// which can still be read in full afterwards.
pub fn raw_read_past_the_body_is_refused_and_harmless_test() {
  let #(listener, reports) = start(limits(1000, 5000))
  let socket = open(listener)
  send(socket, post("/past", "5", "hello"))
  expect_status(socket, 200)
  let assert Raw(Error(server.ReadPastBody(requested: 999, remaining: 5))) =
    next_report(reports)
  let assert Read(Ok(<<"hello":utf8>>)) = next_report(reports)
  raw_close(socket)
  server.stop(listener)
}

pub fn read_text_names_the_body_error_test() {
  let #(listener, reports) = start(limits(1000, 5000))
  let socket = open(listener)
  send(socket, post("/text", "17", "0123456789abcdefg"))
  expect_status(socket, 200)
  let assert Text(Error("Content-Length 17 exceeds limit of 16")) =
    next_report(reports)
  // 0xFF and 0xFE never occur in UTF-8.
  send(socket, post("/text", "2", ""))
  let assert Ok(Nil) = raw_send(socket, <<255, 254>>)
    as "test client send must succeed"
  expect_status(socket, 200)
  let assert Text(Error("Invalid UTF-8 request body")) = next_report(reports)
  raw_close(socket)
  server.stop(listener)
}

// --- Outside a listener ---

fn outside_request(content_length: String) -> Request(Connection) {
  request.new()
  |> request.set_method(http.Post)
  |> request.set_header("content-length", content_length)
  |> request.set_body(server.Connection(socket: dead_socket(), resolved: None))
}

pub fn invalid_content_length_outside_a_listener_is_named_test() {
  let assert Error(transport_http.InvalidContentLength) =
    transport_http.read_body(outside_request("12x"), limit)
}

/// A read with no request body context is a programming error: both
/// readers name it and log it at error level.
pub fn read_outside_an_active_request_is_named_and_logged_test() {
  let req = outside_request("5")
  let #(result, logs) =
    log_capture.capture(fn() { transport_http.read_body(req, limit) })
  let assert Error(transport_http.BodyReadFailed(server.NoActiveRequest)) =
    result
  assert log_capture.has(logs, level: "error", containing: [
    "read_body called outside an active HTTP request",
  ])

  let server.Connection(socket:, ..) = req.body
  let #(raw, raw_logs) =
    log_capture.capture(fn() { server.read_body(socket, 5) })
  let assert Error(server.NoActiveRequest) = raw
  assert log_capture.has(raw_logs, level: "error", containing: [
    "read_body called outside an active HTTP request",
  ])
}

// --- Descriptions ---

pub fn every_error_has_its_own_description_test() {
  let texts = [
    transport_http.describe_read_body_error(transport_http.MissingContentLength),
    transport_http.describe_read_body_error(transport_http.InvalidContentLength),
    transport_http.describe_read_body_error(transport_http.BodyTooLarge(
      length: 17,
      limit: 16,
    )),
    transport_http.describe_read_body_error(transport_http.BodyAlreadyConsumed),
    server.describe_body_read_error(server.NoActiveRequest),
    server.describe_body_read_error(server.BodyUnavailable),
    server.describe_body_read_error(server.ReadPastBody(
      requested: 9,
      remaining: 5,
    )),
    server.describe_body_read_error(server.BodyReadTimeout),
    server.describe_body_read_error(server.RequestDeadlineExceeded),
    server.describe_body_read_error(server.SocketFailed(reason: "closed")),
  ]
  let assert True =
    texts
    == [
      "Missing Content-Length header",
      "Invalid Content-Length header",
      "Content-Length 17 exceeds limit of 16",
      "Request body already consumed",
      "read_body called outside an active HTTP request",
      "request body unavailable after an earlier read failure",
      "requested 9 body bytes with 5 left of the declared Content-Length",
      "body_read_timeout_ms passed before the request body arrived",
      "request_timeout_ms passed before the request body arrived",
      "request body read failed: closed",
    ]
  // A failed read is described by the reason underneath it.
  let assert True =
    transport_http.describe_read_body_error(transport_http.BodyReadFailed(
      server.BodyReadTimeout,
    ))
    == "body_read_timeout_ms passed before the request body arrived"
}

// --- Raw socket helpers (see brazier_http_raw_ffi) ---

type RawResponse =
  #(Int, List(#(String, String)), String)

@external(erlang, "brazier_http_raw_ffi", "connect")
fn raw_connect(port: Int) -> Result(Socket, String)

@external(erlang, "brazier_http_raw_ffi", "send")
fn raw_send(socket: Socket, data: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_http_raw_ffi", "recv_response")
fn raw_recv_response(
  socket: Socket,
  timeout_ms: Int,
  expect_body: Bool,
) -> Result(RawResponse, String)

@external(erlang, "brazier_http_raw_ffi", "wait_closed")
fn raw_wait_closed(socket: Socket, timeout_ms: Int) -> Result(Bool, String)

@external(erlang, "brazier_http_raw_ffi", "close")
fn raw_close(socket: Socket) -> Nil

@external(erlang, "brazier_client_ip_test_ffi", "dead_socket")
fn dead_socket() -> Socket
