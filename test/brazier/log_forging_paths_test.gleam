//// SEC-11: a client-chosen path or header cannot forge a log line (the
//// paths outside the transport and router; see `log_forging_test`).
////
//// Static serving, the HTTP framing checks, multipart uploads and client
//// resolution all log a path the client sent. Each must quote it (no raw
//// newline or escape byte reaches the log) and drop its query, which can
//// carry a token.

import brazier/ip
import brazier/log_capture
import brazier/static
import brazier/transport/client
import brazier/transport/http as transport_http
import brazier/transport/server.{type Connection, type Socket}
import brazier/upload
import gleam/http/request.{type Request}
import gleam/list
import gleam/string

/// A newline that starts a forged warning line, and an ANSI escape that
/// would recolour a terminal.
const forged = "a\n[warning] FORGED\u{1b}[31m"

/// The forged text as `string.inspect` quotes it.
const quoted = "a\\n[warning] FORGED\\u{001B}[31m"

pub fn static_refused_path_is_quoted_in_the_log_test() {
  let config =
    static.StaticConfig(
      directory: "test/fixtures",
      prefix: "/static",
      max_age: 3600,
    )
  let #(result, logs) =
    log_capture.capture(fn() {
      static.serve(config, "/static/../" <> forged <> "?token=secret")
    })
  let assert Ok(resp) = result
  let assert 403 = resp.status
  assert log_capture.has(logs, level: "warning", containing: [
    "Refused static path",
    quoted,
  ])
  assert_not_forged(logs)
}

pub fn static_undecodable_path_is_quoted_in_the_log_test() {
  let config =
    static.StaticConfig(
      directory: "test/fixtures",
      prefix: "/static",
      max_age: 3600,
    )
  let #(result, logs) =
    log_capture.capture(fn() { static.serve(config, "/static/%zz" <> forged) })
  let assert Ok(resp) = result
  let assert 400 = resp.status
  assert log_capture.has(logs, level: "warning", containing: [
    "Undecodable static path",
    quoted,
  ])
  assert_not_forged(logs)
}

pub fn refused_body_length_quotes_the_path_and_the_header_test() {
  let req =
    make_request(
      <<"POST">>,
      "/" <> forged <> "?token=secret",
      [#("content-length", "1\u{1b}[31m")],
      loopback_socket(),
    )
  let #(result, logs) =
    log_capture.capture(fn() { transport_http.declared_body_length(req, 100) })
  let assert Error(transport_http.FramingError(status: 400, reason:)) = result
  assert string.contains(reason, "\"1\\u{001B}[31m\"")
  assert log_capture.has(logs, level: "warning", containing: [
    "Refused the declared body length",
    quoted,
  ])
  assert_not_forged(logs)
}

pub fn unreadable_multipart_body_quotes_the_path_test() {
  let req =
    make_request(
      <<"POST">>,
      "/upload/" <> forged <> "?token=secret",
      [
        #("content-type", "multipart/form-data; boundary=XyZ"),
        #("content-length", "10"),
      ],
      dead_socket(),
    )
  let #(result, logs) =
    log_capture.capture(fn() {
      upload.read_multipart(req, upload.default_config())
    })
  let assert Error(upload.BodyReadError(_)) = result
  assert log_capture.has(logs, level: "warning", containing: [
    "Cannot read multipart body for",
    quoted,
  ])
  assert_not_forged(logs)
}

pub fn oversized_multipart_body_quotes_the_path_test() {
  let req =
    make_request(
      <<"POST">>,
      "/upload/" <> forged <> "?token=secret",
      [
        #("content-type", "multipart/form-data; boundary=XyZ"),
        #("content-length", "999999999999"),
      ],
      dead_socket(),
    )
  let #(result, logs) =
    log_capture.capture(fn() {
      upload.read_multipart(req, upload.default_config())
    })
  let assert Error(upload.RequestTooLarge(..)) = result
  assert log_capture.has(logs, level: "warning", containing: [
    "Multipart body of 999999999999 bytes exceeds",
    quoted,
  ])
  assert_not_forged(logs)
}

pub fn client_ip_resolution_quotes_the_path_test() {
  let req =
    make_request(
      <<"GET">>,
      "/" <> forged <> "?token=secret",
      [],
      loopback_socket(),
    )
  let #(result, logs) =
    log_capture.capture(fn() { client.ip(req, ip.no_trusted_proxies()) })
  let assert Ok("127.0.0.1") = result
  assert log_capture.has(logs, level: "debug", containing: [
    "Resolving client IP for",
    quoted,
  ])
  assert_not_forged(logs)
}

/// No captured line holds a raw newline, the raw escape byte or the query.
fn assert_not_forged(logs: List(log_capture.Captured)) -> Nil {
  assert logs != []
  assert list.all(logs, fn(event) {
    !string.contains(event.message, "\n")
    && !string.contains(event.message, "\u{1b}")
    && !string.contains(event.message, "token=secret")
  })
}

@external(erlang, "brazier_client_ip_test_ffi", "loopback_socket")
fn loopback_socket() -> Socket

@external(erlang, "brazier_client_ip_test_ffi", "dead_socket")
fn dead_socket() -> Socket

@external(erlang, "brazier_client_ip_test_ffi", "make_request")
fn make_request(
  method: BitArray,
  path: String,
  headers: List(#(String, String)),
  socket: Socket,
) -> Request(Connection)
