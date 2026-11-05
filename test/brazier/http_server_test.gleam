/// HTTP/1.1 server conformance and hardening tests over raw sockets:
/// request-line forms, message framing (smuggling), header limits,
/// keep-alive, HEAD, slow clients, crash isolation and supervision.
import brazier/await
import brazier/transport
import brazier/transport/http as transport_http
import brazier/transport/server.{type Connection, type Socket, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- Test server ---

fn test_handler(
  req: Request(Connection),
) -> option.Option(response.Response(server.ResponseBody)) {
  case req.path {
    "/echo" ->
      case transport_http.read_body(req, 1_000_000) {
        Ok(body) -> Some(text_response(200, bits_to_string(body)))
        Error(error) ->
          Some(text_response(
            400,
            transport_http.describe_read_body_error(error),
          ))
      }
    "/ignore" -> Some(text_response(200, "ignored"))
    "/close" ->
      Some(
        text_response(200, "bye")
        |> response.set_header("connection", "close"),
      )
    "/crash" -> crash()
    "/tree" ->
      Some(
        response.new(200)
        |> response.set_body(Bytes(tree_body())),
      )
    _ -> {
      let host = case request.get_header(req, "host") {
        Ok(host) -> host
        Error(Nil) -> "-"
      }
      Some(text_response(200, req.path <> "|" <> host))
    }
  }
}

/// A body built from many chunks, nested and appended, one of them larger
/// than a TCP segment.
fn tree_body() -> bytes_tree.BytesTree {
  bytes_tree.from_string("head|")
  |> bytes_tree.append_tree(
    bytes_tree.concat([
      bytes_tree.from_string("a"),
      bytes_tree.from_bit_array(<<"b":utf8>>),
    ]),
  )
  |> bytes_tree.append_string(string.repeat("x", 100_000))
  |> bytes_tree.append(<<"|tail":utf8>>)
}

fn text_response(status: Int, body: String) {
  response.new(status)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

fn bits_to_string(bits: BitArray) -> String {
  case bit_array.to_string(bits) {
    Ok(text) -> text
    Error(Nil) -> "<binary>"
  }
}

fn fast_limits() -> transport.SecurityLimits {
  transport.SecurityLimits(
    ..transport.default_security_limits(),
    pre_upgrade_timeout_ms: 300,
    keepalive_idle_timeout_ms: 300,
    body_read_timeout_ms: 300,
    request_timeout_ms: 2000,
    // The raw requests below name the hosts "x" and "test"; an
    // absolute-form target names example.com.
    allowed_hosts: ["x", "test", "example.com"],
  )
}

fn start_server(limits: transport.SecurityLimits) -> server.Listener {
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
      api_handler: Some(test_handler),
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "test listener must bind an OS-assigned port"
  listener
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

fn get(path: String) -> String {
  "GET " <> path <> " HTTP/1.1\r\nHost: test\r\n\r\n"
}

fn exchange(listener: server.Listener, data: String) -> RawResponse {
  let socket = open(listener)
  send(socket, data)
  let assert Ok(resp) = raw_recv_response(socket, 2000, True)
    as "server must answer the request"
  raw_close(socket)
  resp
}

fn header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  list.key_find(headers, name)
}

fn assert_closed(socket: Socket) -> Nil {
  let assert Ok(True) = raw_wait_closed(socket, 2000)
    as "server must close the connection"
  raw_close(socket)
}

fn assert_error_status(listener: server.Listener, data: String, status: Int) {
  let socket = open(listener)
  send(socket, data)
  let assert Ok(#(got, headers, _body)) = raw_recv_response(socket, 2000, True)
    as "server must answer a malformed request with an error status"
  let assert True = got == status
  let assert Ok("close") = header(headers, "connection")
  let assert Ok("nosniff") = header(headers, "x-content-type-options")
  let assert Ok(_) = header(headers, "content-security-policy")
  assert_closed(socket)
}

// --- Listener ---

pub fn listener_binds_os_assigned_port_test() {
  let listener = start_server(fast_limits())
  let assert True = server.get_port(listener) > 0
  let #(status, _, body) = exchange(listener, get("/hello"))
  let assert 200 = status
  let assert "/hello|test" = body
  server.stop(listener)
}

pub fn start_listener_rejects_invalid_limits_test() {
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
      security_limits: transport.SecurityLimits(
        ..transport.default_security_limits(),
        keepalive_idle_timeout_ms: 0,
      ),
      api_handler: None,
    )
  let assert Error(_) = transport.start_listener(config)
}

// --- Request line ---

pub fn malformed_request_line_is_400_test() {
  let listener = start_server(fast_limits())
  assert_error_status(listener, "GARBAGE\r\n\r\n", 400)
  assert_error_status(listener, "GET /\r\nHost: x\r\n\r\n", 400)
  assert_error_status(listener, "GET relative HTTP/1.1\r\nHost: x\r\n\r\n", 400)
  assert_error_status(
    listener,
    "GET example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n",
    400,
  )
  assert_error_status(listener, "HTTP/1.1 200 OK\r\n\r\n", 400)
  server.stop(listener)
}

pub fn unknown_method_is_501_test() {
  let listener = start_server(fast_limits())
  assert_error_status(listener, "BREW / HTTP/1.1\r\nHost: x\r\n\r\n", 501)
  server.stop(listener)
}

pub fn unsupported_version_is_505_test() {
  let listener = start_server(fast_limits())
  assert_error_status(listener, "GET / HTTP/2.0\r\nHost: x\r\n\r\n", 505)
  server.stop(listener)
}

pub fn asterisk_form_only_for_options_test() {
  let listener = start_server(fast_limits())
  assert_error_status(listener, "GET * HTTP/1.1\r\nHost: x\r\n\r\n", 400)
  let #(status, headers, _) =
    exchange(listener, "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n")
  let assert 204 = status
  let assert Ok(allow) = header(headers, "allow")
  let assert True = string.contains(allow, "GET")
  server.stop(listener)
}

pub fn absolute_form_uses_path_and_authority_test() {
  let listener = start_server(fast_limits())
  let #(status, _, body) =
    exchange(
      listener,
      "GET http://example.com:8080/abs?q=1 HTTP/1.1\r\nHost: other\r\n\r\n",
    )
  let assert 200 = status
  // RFC 9112 3.2.2: the target's authority replaces the Host header.
  let assert "/abs|example.com:8080" = body
  server.stop(listener)
}

pub fn leading_empty_lines_are_ignored_test() {
  let listener = start_server(fast_limits())
  let #(status, _, _) = exchange(listener, "\r\n\r\n" <> get("/"))
  let assert 200 = status
  server.stop(listener)
}

pub fn request_line_too_long_is_414_test() {
  let listener =
    start_server(
      transport.SecurityLimits(..fast_limits(), max_request_line_bytes: 64),
    )
  assert_error_status(listener, get("/" <> string.repeat("a", 200)), 414)
  // A request line within the limit is still served.
  let #(status, _, _) = exchange(listener, get("/short"))
  let assert 200 = status
  server.stop(listener)
}

// --- Header limits ---

pub fn header_section_too_large_is_431_test() {
  let listener =
    start_server(
      transport.SecurityLimits(..fast_limits(), max_http_header_bytes: 64),
    )
  assert_error_status(
    listener,
    "GET / HTTP/1.1\r\nHost: x\r\nX-Big: "
      <> string.repeat("b", 200)
      <> "\r\n\r\n",
    431,
  )
  server.stop(listener)
}

pub fn too_many_headers_is_431_test() {
  let listener =
    start_server(transport.SecurityLimits(..fast_limits(), max_http_headers: 3))
  assert_error_status(
    listener,
    "GET / HTTP/1.1\r\nHost: x\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n",
    431,
  )
  server.stop(listener)
}

pub fn invalid_header_field_is_400_test() {
  let listener = start_server(fast_limits())
  // obs-fold (RFC 9112 5.2) and a space before the colon are rejected.
  assert_error_status(
    listener,
    "GET / HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n folded\r\n\r\n",
    400,
  )
  assert_error_status(listener, "GET / HTTP/1.1\r\nHost : x\r\n\r\n", 400)
  server.stop(listener)
}

pub fn host_header_rules_test() {
  let listener = start_server(fast_limits())
  // HTTP/1.1 requires exactly one Host header.
  assert_error_status(listener, "GET / HTTP/1.1\r\n\r\n", 400)
  assert_error_status(
    listener,
    "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
    400,
  )
  // HTTP/1.0 may omit it.
  let #(status, _, _) = exchange(listener, "GET / HTTP/1.0\r\n\r\n")
  let assert 200 = status
  server.stop(listener)
}

// --- Message framing / request smuggling ---

pub fn content_length_with_transfer_encoding_is_400_test() {
  let listener = start_server(fast_limits())
  assert_error_status(
    listener,
    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    400,
  )
  server.stop(listener)
}

pub fn transfer_encoding_is_501_test() {
  let listener = start_server(fast_limits())
  assert_error_status(
    listener,
    "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
    501,
  )
  server.stop(listener)
}

pub fn duplicate_or_invalid_content_length_is_400_test() {
  let listener = start_server(fast_limits())
  let post = fn(cl_headers: String) {
    "POST /echo HTTP/1.1\r\nHost: x\r\n" <> cl_headers <> "\r\nhello"
  }
  assert_error_status(
    listener,
    post("Content-Length: 5\r\nContent-Length: 5\r\n"),
    400,
  )
  assert_error_status(listener, post("Content-Length: 5, 5\r\n"), 400)
  assert_error_status(listener, post("Content-Length: -5\r\n"), 400)
  assert_error_status(listener, post("Content-Length: +5\r\n"), 400)
  assert_error_status(listener, post("Content-Length: 0x5\r\n"), 400)
  assert_error_status(listener, post("Content-Length: \r\n"), 400)
  server.stop(listener)
}

pub fn body_over_limit_is_413_test() {
  let listener =
    start_server(transport.SecurityLimits(..fast_limits(), max_body_bytes: 10))
  assert_error_status(
    listener,
    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world",
    413,
  )
  server.stop(listener)
}

pub fn pipelined_requests_are_framed_by_content_length_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  // The body of the first request contains bytes that look like a request;
  // they must be read as body, and the real second request served after.
  let smuggled = "GET /evil HTTP/1.1\r\nHost: x\r\n\r\n"
  send(
    socket,
    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: "
      <> int.to_string(string.byte_size(smuggled))
      <> "\r\n\r\n"
      <> smuggled
      <> get("/second"),
  )
  let assert Ok(#(200, _, first)) = raw_recv_response(socket, 2000, True)
    as "first pipelined response"
  let assert True = first == smuggled
  let assert Ok(#(200, _, second)) = raw_recv_response(socket, 2000, True)
    as "second pipelined response"
  let assert "/second|test" = second
  raw_close(socket)
  server.stop(listener)
}

// --- Expect ---

pub fn expect_100_continue_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(
    socket,
    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n",
  )
  let assert Ok(#(100, _, _)) = raw_recv_response(socket, 2000, True)
    as "server must send 100 Continue before reading the body"
  send(socket, "hello")
  let assert Ok(#(200, _, "hello")) = raw_recv_response(socket, 2000, True)
    as "echo after 100 Continue"
  raw_close(socket)
  server.stop(listener)
}

pub fn unknown_expectation_is_417_test() {
  let listener = start_server(fast_limits())
  assert_error_status(
    listener,
    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nExpect: teapot\r\n\r\n",
    417,
  )
  server.stop(listener)
}

// --- Keep-alive ---

pub fn keep_alive_serves_many_requests_on_one_connection_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  list.each([1, 2, 3, 4, 5], fn(i) {
    let path = "/req" <> int.to_string(i)
    send(socket, get(path))
    let assert Ok(#(200, headers, body)) = raw_recv_response(socket, 2000, True)
      as "keep-alive response"
    let assert True = body == path <> "|test"
    let assert Error(Nil) = header(headers, "connection")
  })
  let assert 1 = server.get_connection_count(listener)
  raw_close(socket)
  server.stop(listener)
}

pub fn client_connection_close_is_honoured_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
  let assert Ok(#(200, headers, _)) = raw_recv_response(socket, 2000, True)
    as "response before close"
  let assert Ok("close") = header(headers, "connection")
  assert_closed(socket)
  server.stop(listener)
}

pub fn handler_connection_close_is_honoured_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, get("/close"))
  let assert Ok(#(200, headers, "bye")) = raw_recv_response(socket, 2000, True)
    as "response before close"
  let assert Ok("close") = header(headers, "connection")
  assert_closed(socket)
  server.stop(listener)
}

pub fn http10_closes_by_default_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, "GET / HTTP/1.0\r\n\r\n")
  let assert Ok(#(200, headers, _)) = raw_recv_response(socket, 2000, True)
    as "HTTP/1.0 response"
  let assert Ok("close") = header(headers, "connection")
  assert_closed(socket)
  server.stop(listener)
}

pub fn http10_keep_alive_is_honoured_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, "GET /a HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
  let assert Ok(#(200, headers, _)) = raw_recv_response(socket, 2000, True)
    as "HTTP/1.0 keep-alive response"
  let assert Ok("keep-alive") = header(headers, "connection")
  send(socket, "GET /b HTTP/1.0\r\n\r\n")
  let assert Ok(#(200, _, "/b|-")) = raw_recv_response(socket, 2000, True)
    as "second HTTP/1.0 response"
  assert_closed(socket)
  server.stop(listener)
}

pub fn max_keepalive_requests_closes_test() {
  let listener =
    start_server(
      transport.SecurityLimits(..fast_limits(), max_keepalive_requests: 2),
    )
  let socket = open(listener)
  send(socket, get("/1"))
  let assert Ok(#(200, first, _)) = raw_recv_response(socket, 2000, True)
    as "first response"
  let assert Error(Nil) = header(first, "connection")
  send(socket, get("/2"))
  let assert Ok(#(200, second, _)) = raw_recv_response(socket, 2000, True)
    as "second response"
  let assert Ok("close") = header(second, "connection")
  assert_closed(socket)
  server.stop(listener)
}

pub fn idle_keep_alive_connection_is_closed_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, get("/"))
  let assert Ok(#(200, _, _)) = raw_recv_response(socket, 2000, True)
    as "response"
  // keepalive_idle_timeout_ms is 300: closed without a response.
  assert_closed(socket)
  server.stop(listener)
}

pub fn small_unread_body_is_discarded_and_connection_reused_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(
    socket,
    "POST /ignore HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789"
      <> get("/next"),
  )
  let assert Ok(#(200, _, "ignored")) = raw_recv_response(socket, 2000, True)
    as "response to request with unread body"
  let assert Ok(#(200, _, "/next|test")) = raw_recv_response(socket, 2000, True)
    as "next request after discarded body"
  raw_close(socket)
  server.stop(listener)
}

pub fn large_unread_body_closes_connection_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  let size = 200_000
  send(
    socket,
    "POST /ignore HTTP/1.1\r\nHost: x\r\nContent-Length: "
      <> int.to_string(size)
      <> "\r\n\r\n",
  )
  let assert Ok(#(200, headers, "ignored")) =
    raw_recv_response(socket, 2000, True)
    as "response to request with large unread body"
  let assert Ok("close") = header(headers, "connection")
  raw_close(socket)
  server.stop(listener)
}

// --- HEAD ---

pub fn head_keeps_content_length_without_body_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, "HEAD /head HTTP/1.1\r\nHost: test\r\n\r\n")
  let assert Ok(#(200, headers, "")) = raw_recv_response(socket, 2000, False)
    as "HEAD response"
  let assert Ok("10") = header(headers, "content-length")
  // If a body had been sent it would corrupt this second response.
  send(socket, get("/after"))
  let assert Ok(#(200, _, "/after|test")) =
    raw_recv_response(socket, 2000, True)
    as "response after HEAD"
  raw_close(socket)
  server.stop(listener)
}

// --- Response bodies ---

/// The head and a many-chunk body go out as one iodata send: the length
/// and bytes on the wire are exactly the tree's, in order.
pub fn chunked_tree_body_is_sent_whole_and_in_order_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, get("/tree"))
  let expected = bytes_tree.to_bit_array(tree_body())
  let assert Ok(#(200, headers, body)) = raw_recv_response(socket, 2000, True)
    as "response with a tree body"
  let assert Ok(length) = header(headers, "content-length")
  let assert True = length == int.to_string(bit_array.byte_size(expected))
  let assert True = <<body:utf8>> == expected
  // The connection is still framed correctly for the next request.
  send(socket, get("/after"))
  let assert Ok(#(200, _, "/after|test")) =
    raw_recv_response(socket, 2000, True)
    as "response after the tree body"
  raw_close(socket)
  server.stop(listener)
}

// --- Slow clients ---

pub fn slow_request_line_gets_408_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, "GET / HT")
  let assert Ok(#(408, headers, _)) = raw_recv_response(socket, 2000, True)
    as "partial request line must time out with 408"
  let assert Ok("close") = header(headers, "connection")
  assert_closed(socket)
  server.stop(listener)
}

pub fn slow_headers_get_408_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, "GET / HTTP/1.1\r\nHost: x\r\n")
  // Keep dripping header bytes, one every 50 ms of silence from the
  // server, until it answers. Bytes keep arriving, yet the 300 ms deadline
  // on the whole head (pre_upgrade_timeout_ms) expires: 408. Each wait is a
  // recv that ends as soon as the server writes; 100 drips (5 s) bound the
  // test far past the deadline.
  let assert Ok(drips) = raw_drip_until_answer(socket, 50, 100, <<"X":utf8>>)
    as "the server must answer a slow header section"
  let assert True = drips >= 1
  let assert Ok(#(408, _, _)) = raw_recv_response(socket, 2000, True)
    as "slow header section must time out with 408"
  assert_closed(socket)
  server.stop(listener)
}

pub fn silent_connection_is_closed_without_response_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  assert_closed(socket)
  server.stop(listener)
}

pub fn slow_body_fails_read_and_closes_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(
    socket,
    "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc",
  )
  let assert Ok(#(400, headers, body)) = raw_recv_response(socket, 2000, True)
    as "body read timeout surfaces to the handler"
  let assert True = string.contains(body, "timeout")
  let assert Ok("close") = header(headers, "connection")
  assert_closed(socket)
  server.stop(listener)
}

// --- WebSocket upgrade framing ---

pub fn ws_upgrade_with_body_is_400_test() {
  let listener = start_server(fast_limits())
  assert_error_status(
    listener,
    "GET /ws HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello",
    400,
  )
  server.stop(listener)
}

pub fn ws_upgrade_with_early_data_is_400_test() {
  let listener = start_server(fast_limits())
  assert_error_status(
    listener,
    "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\nEARLY",
    400,
  )
  server.stop(listener)
}

// --- Crash isolation and supervision ---

pub fn handler_crash_is_500_and_releases_slot_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  send(socket, get("/crash"))
  let assert Ok(#(500, headers, _)) = raw_recv_response(socket, 2000, True)
    as "handler crash must answer 500"
  let assert Ok("close") = header(headers, "connection")
  assert_closed(socket)
  await_count(listener, 0)
  // The listener keeps serving.
  let #(status, _, _) = exchange(listener, get("/"))
  let assert 200 = status
  server.stop(listener)
}

pub fn killed_connection_process_releases_slot_test() {
  let listener = start_server(fast_limits())
  let socket = open(listener)
  await_count(listener, 1)
  let assert [pid] = server.get_connection_pids(listener)
  raw_kill(pid)
  await_count(listener, 0)
  raw_close(socket)
  server.stop(listener)
}

pub fn per_ip_connection_cap_answers_503_test() {
  let listener =
    start_server(
      transport.SecurityLimits(..fast_limits(), max_connections_per_ip: 2),
    )
  let a = open(listener)
  let b = open(listener)
  await_count(listener, 2)
  let c = open(listener)
  let assert Ok(#(503, headers, _)) = raw_recv_response(c, 2000, True)
    as "connection over the per-IP cap must get 503"
  let assert Ok("close") = header(headers, "connection")
  raw_close(c)
  raw_close(a)
  raw_close(b)
  // Slots free up again once the clients go away.
  await_count(listener, 0)
  let #(status, _, _) = exchange(listener, get("/"))
  let assert 200 = status
  server.stop(listener)
}

pub fn global_connection_cap_answers_503_test() {
  let listener =
    start_server(transport.SecurityLimits(..fast_limits(), max_connections: 1))
  let a = open(listener)
  await_count(listener, 1)
  let b = open(listener)
  let assert Ok(#(503, _, _)) = raw_recv_response(b, 2000, True)
    as "connection over the global cap must get 503"
  raw_close(b)
  raw_close(a)
  server.stop(listener)
}

pub fn killed_acceptor_is_restarted_test() {
  let listener = start_server(fast_limits())
  let before = raw_acceptor_pids(server.get_supervisor(listener))
  let assert [victim, ..] = before
  let assert Ok(pool) =
    raw_acceptor_pool(server.get_supervisor(listener), victim)
  {
    use restarts <- await.with_watch_exit(pool, victim)
    raw_kill(victim)
    // The pool supervisor restarts a child while handling its 'EXIT'; once
    // it has handled that message the replacement is in which_children.
    await.expect_info(restarts, pool, "the acceptor pool to handle the kill")
  }
  let after = raw_acceptor_pids(server.get_supervisor(listener))
  let assert True = list.length(after) == list.length(before)
  let assert False = list.contains(after, victim)
  let #(status, _, _) = exchange(listener, get("/"))
  let assert 200 = status
  server.stop(listener)
}

/// Return once the listener has exactly `expected` live connections. The
/// connection owner takes a slot before the acceptor emits
/// `[brazier, http, connection, accepted]` and releases it before it emits
/// `closed`, so each of those events is a point to re-check the count.
fn await_count(listener: server.Listener, expected: Int) -> Nil {
  await.until_telemetry(
    [
      ["brazier", "http", "connection", "accepted"],
      ["brazier", "http", "connection", "closed"],
    ],
    int.to_string(expected) <> " live connections",
    fn() { server.get_connection_count(listener) == expected },
  )
}

// --- FFI ---

type RawResponse =
  #(Int, List(#(String, String)), String)

@external(erlang, "brazier_http_raw_ffi", "connect")
fn raw_connect(port: Int) -> Result(Socket, String)

@external(erlang, "brazier_http_raw_ffi", "send")
fn raw_send(socket: Socket, data: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_http_raw_ffi", "acceptor_pool")
fn raw_acceptor_pool(
  listener_supervisor: process.Pid,
  acceptor: process.Pid,
) -> Result(process.Pid, Nil)

@external(erlang, "brazier_http_raw_ffi", "drip_until_answer")
fn raw_drip_until_answer(
  socket: Socket,
  interval_ms: Int,
  max_drips: Int,
  data: BitArray,
) -> Result(Int, String)

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

@external(erlang, "brazier_http_raw_ffi", "kill")
fn raw_kill(pid: process.Pid) -> Nil

@external(erlang, "brazier_http_raw_ffi", "acceptor_pids")
fn raw_acceptor_pids(listener_supervisor: process.Pid) -> List(process.Pid)

@external(erlang, "brazier_http_raw_ffi", "crash")
fn crash() -> a
