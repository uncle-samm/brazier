//// SEC-11: a client-chosen path or header cannot forge a log line (the
//// paths outside the transport and router; see `log_forging_test`).
////
//// The server render, static serving, the HTTP head and framing checks,
//// multipart uploads and client resolution all log a path the client sent.
//// Each must quote it (no raw newline or escape byte reaches the log) and
//// drop its query, which can carry a token. A very long path is quoted in
//// full: escaping covers the whole path, not a prefix of it, so a forged
//// tail after thousands of bytes is quoted too.

import brazier/cluster/log_capture as node_log
import brazier/effect
import brazier/error
import brazier/html
import brazier/internal/stream_window
import brazier/ip
import brazier/log_capture
import brazier/ssr
import brazier/static
import brazier/transport
import brazier/transport/client
import brazier/transport/http as transport_http
import brazier/transport/server.{type Connection, type Socket}
import brazier/upload
import gleam/bit_array
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri.{type Uri}

/// A newline that starts a forged warning line, and an ANSI escape that
/// would recolour a terminal.
const forged = "a\n[warning] FORGED\u{1b}[31m"

/// The forged text as `string.inspect` quotes it.
const quoted = "a\\n[warning] FORGED\\u{001B}[31m"

/// A path segment of thousands of bytes, under the 8192-byte request line.
fn long_segment() -> String {
  string.repeat("a", 6000)
}

/// A long path that ends in the forged text, as the client sent it.
fn long_forged_path(prefix: String) -> String {
  prefix <> long_segment() <> "/" <> forged
}

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

// --- Long paths at the sites above -------------------------------------------

pub fn static_long_refused_path_is_quoted_in_full_test() {
  let path = long_forged_path("/static/../")
  let #(result, logs) =
    log_capture.capture(fn() {
      static.serve(static_config(), path <> "?token=secret")
    })
  let assert Ok(resp) = result
  let assert 403 = resp.status
  assert log_capture.has(logs, level: "warning", containing: [
    "Refused static path " <> string.inspect(path),
  ])
  assert_not_forged(logs)
}

pub fn static_directory_path_is_quoted_test() {
  // A trailing slash names a directory: no file, logged at debug. The
  // query stays off: it would be the last segment, not a directory.
  let path = long_forged_path("/static/") <> "/"
  let #(result, logs) =
    log_capture.capture(fn() { static.serve(static_config(), path) })
  let assert Error(Nil) = result
  assert log_capture.has(logs, level: "debug", containing: [
    "No file named by: " <> string.inspect(path),
  ])
  assert_not_forged(logs)
}

pub fn static_overlong_file_name_is_no_file_test() {
  // A segment longer than the file system allows (255 bytes on common
  // systems) names no file, as a missing one does: 404, logged at debug.
  // It is not a server failure: a client must not be able to make the
  // static handler answer 500 and log an error at will.
  let path = "/static/" <> long_segment() <> forged
  let #(result, logs) =
    log_capture.capture(fn() { static.serve(static_config(), path) })
  let assert Error(Nil) = result
  assert log_capture.has(logs, level: "debug", containing: [
    "No regular file at: ",
    quoted,
  ])
  assert !list.any(logs, fn(event) { event.level == "error" })
  assert_not_forged(logs)
}

pub fn long_body_length_refusal_quotes_the_path_in_full_test() {
  let path = long_forged_path("/")
  let req =
    make_request(
      <<"POST">>,
      path <> "?token=secret",
      [#("content-length", "1x")],
      loopback_socket(),
    )
  let #(result, logs) =
    log_capture.capture(fn() { transport_http.declared_body_length(req, 100) })
  let assert Error(transport_http.FramingError(status: 400, ..)) = result
  assert log_capture.has(logs, level: "warning", containing: [
    "Refused the declared body length on " <> string.inspect(path),
  ])
  assert_not_forged(logs)
}

pub fn unsupported_expectation_is_quoted_test() {
  let req =
    make_request(
      <<"POST">>,
      "/" <> forged <> "?token=secret",
      [#("host", "localhost"), #("expect", "x\u{1b}[31m")],
      loopback_socket(),
    )
  let #(result, logs) =
    log_capture.capture(fn() {
      transport_http.check_framing(req, transport_http.Http11, 100)
    })
  let assert Error(transport_http.FramingError(status: 417, reason:)) = result
  assert reason == "unsupported expectation: \"x\\u{001B}[31m\""
  assert log_capture.has(logs, level: "warning", containing: [
    "Rejected request framing (417)",
  ])
  assert_not_forged(logs)
}

pub fn long_oversized_multipart_path_is_quoted_in_full_test() {
  let path = long_forged_path("/upload/")
  let req =
    make_request(
      <<"POST">>,
      path <> "?token=secret",
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
    "byte limit on " <> string.inspect(path),
  ])
  assert_not_forged(logs)
}

pub fn long_client_ip_path_is_quoted_in_full_test() {
  let path = long_forged_path("/")
  let req =
    make_request(<<"GET">>, path <> "?token=secret", [], loopback_socket())
  let #(result, logs) =
    log_capture.capture(fn() { client.ip(req, ip.no_trusted_proxies()) })
  let assert Ok("127.0.0.1") = result
  assert log_capture.has(logs, level: "debug", containing: [
    "Resolving client IP for " <> string.inspect(path),
  ])
  assert_not_forged(logs)
}

pub fn reused_client_resolution_quotes_the_path_test() {
  let assert Ok(trusted) = ip.parse_trusted_proxies(["127.0.0.1"], ip.Forwarded)
    as "the test's proxy list is valid"
  let req =
    make_request(<<"GET">>, "/" <> forged <> "?token=secret", [], dead_socket())
  let req =
    request.Request(
      ..req,
      body: server.Connection(
        ..req.body,
        resolved: Some(ip.Resolved(
          trusted: trusted,
          client: ip.Client(address: "198.51.100.7", scheme: Ok("http")),
        )),
      ),
    )
  let #(result, logs) = log_capture.capture(fn() { client.ip(req, trusted) })
  let assert Ok("198.51.100.7") = result
  assert log_capture.has(logs, level: "debug", containing: [
    "Reusing the resolved client 198.51.100.7 for",
    quoted,
  ])
  assert_not_forged(logs)
}

// --- The server render ------------------------------------------------------

pub fn dead_render_of_an_unknown_route_quotes_the_path_test() {
  let path = long_forged_path("/")
  let #(page, logs) =
    log_capture.capture(fn() {
      ssr.render_page_with_bundle(
        routed_config(),
        page_request(path, Some("token=secret")),
        Ok("bundle"),
      )
    })
  assert page.status == 404
  assert log_capture.has(logs, level: "debug", containing: [
    "Dead render for " <> string.inspect(path),
  ])
  assert log_capture.has(logs, level: "warning", containing: [
    "No route for " <> string.inspect(path) <> " (404)",
  ])
  assert_not_forged(logs)
}

pub fn dead_render_of_a_bad_path_quotes_the_path_test() {
  let path = "/%zz/" <> forged
  let #(page, logs) =
    log_capture.capture(fn() {
      ssr.render_page_with_bundle(
        routed_config(),
        page_request(path, Some("token=secret")),
        Ok("bundle"),
      )
    })
  assert page.status == 400
  assert log_capture.has(logs, level: "warning", containing: [
    "Refusing dead render for " <> string.inspect(path) <> " (400)",
  ])
  assert_not_forged(logs)
}

pub fn dead_render_of_a_bad_query_does_not_log_the_query_test() {
  // The query is refused, and the refusal does not quote it: it is where
  // a token travels.
  let #(page, logs) =
    log_capture.capture(fn() {
      ssr.render_page_with_bundle(
        routed_config(),
        page_request("/", Some("token=secret%zz")),
        Ok("bundle"),
      )
    })
  assert page.status == 400
  assert log_capture.has(logs, level: "warning", containing: [
    "Refusing dead render for \"/\" (400): invalid query string",
  ])
  assert_not_forged(logs)
}

pub fn dead_render_without_a_bundle_quotes_the_path_test() {
  let path = long_forged_path("/")
  let #(page, logs) =
    log_capture.capture(fn() {
      ssr.render_page_with_bundle(
        ssr_config(None),
        page_request(path, Some("token=secret")),
        Error("no bundle loaded"),
      )
    })
  assert page.status == 500
  assert log_capture.has(logs, level: "error", containing: [
    "Refusing dead render for " <> string.inspect(path) <> " (500)",
  ])
  assert_not_forged(logs)
}

pub fn dead_render_refused_by_init_quotes_the_path_test() {
  let path = "/" <> forged
  let config =
    ssr.SsrConfig(..ssr_config(None), init: fn(_ctx) {
      Error(error.refuse(403, "not a member"))
    })
  let #(page, logs) =
    log_capture.capture(fn() {
      ssr.render_page_with_bundle(
        config,
        page_request(path, Some("token=secret")),
        Ok("bundle"),
      )
    })
  assert page.status == 403
  assert log_capture.has(logs, level: "warning", containing: [quoted])
  assert_not_forged(logs)
}

// --- The HTTP request head, over a real listener -----------------------------

pub fn request_head_with_a_long_path_quotes_it_and_drops_the_query_test() {
  // The listener refuses control bytes in the request target, so a client
  // cannot put a raw newline or escape in the path; percent-escapes stay
  // escaped. What reaches the log is the quoted path without its query.
  let path = "/" <> long_segment() <> "/%0A%1B%5B31m"
  let #(status, logs) =
    node_log.capture(fn() {
      with_listener(fn(port) {
        http_exchange(port, "GET " <> path <> "?token=secret HTTP/1.1")
      })
    })
  // No app is configured, so the listener serves its default page.
  assert status == "200"
  assert node_log.contains(
    logs,
    "debug",
    "Read request head GET " <> string.inspect(path),
  )
  assert_node_not_forged(logs)
}

pub fn request_head_with_an_escape_byte_is_refused_unlogged_test() {
  // No newline: that would end the request line.
  let #(status, logs) =
    node_log.capture(fn() {
      with_listener(fn(port) {
        http_exchange(port, "GET /a\u{1b}[31m?token=secret HTTP/1.1")
      })
    })
  assert status == "400"
  assert node_log.contains(
    logs,
    "warning",
    "Rejected request head: bad request: invalid request target",
  )
  assert_node_not_forged(logs)
}

// --- Helpers -----------------------------------------------------------------

fn static_config() -> static.StaticConfig {
  static.StaticConfig(
    directory: "test/fixtures",
    prefix: "/static",
    max_age: 3600,
  )
}

fn ssr_config(
  route: option.Option(fn(Uri) -> Result(Nil, Nil)),
) -> ssr.SsrConfig(Nil, Nil) {
  ssr.SsrConfig(
    init: fn(_ctx) { Ok(#(Nil, effect.none())) },
    update: fn(state, _msg) { #(state, effect.none()) },
    route: route,
    view: fn(_state) { html.text("page") },
    title: fn(_state) { "Page" },
    secret_key: "log-forging-paths-test-secret-key-0123456789",
    head_html: None,
    dev_mode: False,
    recovery_encoder: None,
    stream_limits: stream_window.default_limits(),
    stream_names: [],
  )
}

/// A router that knows only "/".
fn routed_config() -> ssr.SsrConfig(Nil, Nil) {
  ssr_config(
    Some(fn(page: Uri) {
      case page.path {
        "/" -> Ok(Nil)
        _ -> Error(Nil)
      }
    }),
  )
}

fn page_request(path: String, query: option.Option(String)) -> Request(String) {
  request.Request(..request.new(), path: path, query: query)
}

/// Run `run` with the port of a listener with no app: it serves the
/// default page.
fn with_listener(run: fn(Int) -> a) -> a {
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: None,
      ws_auth: None,
      ssr_factory: None,
      security_limits: transport.default_security_limits(),
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "the test listener must start"
  let result = run(server.get_port(listener))
  server.stop(listener)
  result
}

/// Send one request line (and a Host header), return the response status.
/// The handler logs the head before it answers, so once the answer is read
/// the log line is in this process's mailbox.
fn http_exchange(port: Int, request_line: String) -> String {
  let assert Ok(socket) = raw_connect("127.0.0.1", port)
    as "test client must connect to the listener"
  let head =
    request_line
    <> "\r\nHost: 127.0.0.1:"
    <> int.to_string(port)
    <> "\r\nConnection: close\r\n\r\n"
  let assert Ok(Nil) = raw_send(socket, <<head:utf8>>)
    as "test client send must succeed"
  let assert Ok(#(-1, response)) = raw_recv_frame(socket, 3000)
    as "the server must answer"
  raw_close(socket)
  let assert Ok(response) = bit_array.to_string(response)
    as "the response head is text"
  string.slice(response, 9, 3)
}

/// No node-wide line holds a raw newline, the raw escape byte or the query.
fn assert_node_not_forged(logs: List(node_log.Line)) -> Nil {
  assert logs != []
  // OTP's own reports (supervisor progress) span lines; Brazier's lines,
  // which are the ones that carry the path, must not.
  let forged_lines =
    list.filter(logs, fn(line) {
      {
        string.starts_with(line.message, "[brazier.")
        && string.contains(line.message, "\n")
      }
      || string.contains(line.message, "\u{1b}")
      || string.contains(line.message, "token=secret")
    })
  assert forged_lines == [] as string.inspect(forged_lines)
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

type RawSocket

@external(erlang, "brazier_ws_test_ffi", "raw_connect")
fn raw_connect(host: String, port: Int) -> Result(RawSocket, String)

@external(erlang, "brazier_ws_test_ffi", "raw_send")
fn raw_send(socket: RawSocket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_ws_test_ffi", "raw_recv_frame")
fn raw_recv_frame(
  socket: RawSocket,
  timeout: Int,
) -> Result(#(Int, BitArray), String)

@external(erlang, "brazier_ws_test_ffi", "raw_close")
fn raw_close(socket: RawSocket) -> Nil
