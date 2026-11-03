/// Built-in HTTP routes over a real listener: static files served with
/// sendfile (body, ETag, HEAD, misses, non-regular files) and the /health
/// endpoint's method handling.
import beacon/middleware
import beacon/static
import beacon/transport
import beacon/transport/server.{type Socket}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

type RawResponse =
  #(Int, List(#(String, String)), BitArray)

// --- Helpers ---

fn temp_dir(tag: String) -> String {
  let dir = "/tmp/beacon_http_routes_" <> tag <> "_" <> unique_ref()
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "test directory must be creatable"
  dir
}

fn cleanup(dir: String) -> Nil {
  let assert Ok(Nil) = simplifile.delete(dir) as "test directory cleanup"
  Nil
}

fn start(dir: String) -> server.Listener {
  start_with(dir, [])
}

fn start_with(
  dir: String,
  middlewares: List(middleware.Middleware),
) -> server.Listener {
  let cfg =
    static.StaticConfig(directory: dir, prefix: "/static", max_age: 3600)
  let assert Ok(listener) =
    transport.start_listener(transport.TransportConfig(
      port: 0,
      on_connect: fn(_id, _subject) { Nil },
      on_event: fn(_id, _msg) { Nil },
      on_disconnect: fn(_id) { Nil },
      page_html: None,
      middlewares: middlewares,
      static_config: Some(cfg),
      runtime_factory: None,
      ws_auth: None,
      ssr_factory: None,
      security_limits: transport.default_security_limits(),
      api_handler: None,
    ))
    as "test listener must start"
  listener
}

fn request(
  listener: server.Listener,
  method: String,
  path: String,
  headers: String,
) -> RawResponse {
  let assert Ok(socket) = raw_connect(server.get_port(listener))
    as "test client must connect"
  let data =
    method
    <> " "
    <> path
    <> " HTTP/1.1\r\nHost: test\r\nConnection: close\r\n"
    <> headers
    <> "\r\n"
  let assert Ok(Nil) = raw_send(socket, <<data:utf8>>) as "send must succeed"
  let assert Ok(resp) = raw_recv_response(socket, 2000, method != "HEAD")
    as "server must answer"
  raw_close(socket)
  resp
}

fn header(resp: RawResponse, name: String) -> Result(String, Nil) {
  list.key_find(resp.1, name)
}

// --- Static files ---

pub fn static_body_and_etag_match_the_file_test() {
  let dir = temp_dir("body")
  // Larger than the 64 KiB digest chunk, so hashing spans several reads,
  // and larger than one TCP send.
  let contents = string.repeat("0123456789abcdef", 20_000)
  let assert Ok(Nil) = simplifile.write(dir <> "/big.txt", contents)
  let listener = start(dir)
  let resp = request(listener, "GET", "/static/big.txt", "")
  let assert 200 = resp.0
  let assert True = resp.2 == <<contents:utf8>>
  let assert Ok(length) = header(resp, "content-length")
  let assert True = length == int.to_string(string.byte_size(contents))
  let assert Ok(etag) = header(resp, "etag")
  let assert True = etag == static.etag_for(<<contents:utf8>>)
  server.stop(listener)
  cleanup(dir)
}

pub fn static_empty_file_is_served_test() {
  let dir = temp_dir("empty")
  let assert Ok(Nil) = simplifile.write(dir <> "/empty.txt", "")
  let listener = start(dir)
  let resp = request(listener, "GET", "/static/empty.txt", "")
  let assert 200 = resp.0
  let assert Ok("0") = header(resp, "content-length")
  let assert <<>> = resp.2
  server.stop(listener)
  cleanup(dir)
}

pub fn static_head_keeps_length_without_body_test() {
  let dir = temp_dir("head")
  let assert Ok(Nil) = simplifile.write(dir <> "/site.css", "body{color:red}")
  let listener = start(dir)
  let resp = request(listener, "HEAD", "/static/site.css", "")
  let assert 200 = resp.0
  let assert Ok("15") = header(resp, "content-length")
  let assert Ok(_) = header(resp, "etag")
  let assert <<>> = resp.2
  server.stop(listener)
  cleanup(dir)
}

pub fn static_miss_under_the_prefix_is_404_test() {
  // A miss under the static prefix is a 404, never the page: a missing
  // asset must not be answered 200 text/html.
  let dir = temp_dir("miss")
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/sub")
  let listener = start(dir)
  ["/static/missing.css", "/static/sub", "/static/sub/", "/static"]
  |> list.each(fn(path) {
    let resp = request(listener, "GET", path, "")
    let assert 404 = resp.0
    let assert Error(Nil) = header(resp, "etag")
  })
  server.stop(listener)
  cleanup(dir)
}

pub fn static_fifo_is_not_opened_test() {
  // Opening a FIFO blocks until a writer appears; the server must decide
  // from the file type alone and answer 404 at once.
  let dir = temp_dir("fifo")
  let assert Ok(Nil) = make_fifo(dir <> "/pipe.txt")
  let cfg = static.StaticConfig(directory: dir, prefix: "/static", max_age: 0)
  let assert Error(Nil) = static.serve(cfg, "/static/pipe.txt")
  let listener = start(dir)
  let resp = request(listener, "GET", "/static/pipe.txt", "")
  let assert 404 = resp.0
  server.stop(listener)
  cleanup(dir)
}

// --- Refusals before the body ---

pub fn refusal_is_not_held_back_by_the_unsent_body_test() {
  // Regression: the server discarded the unread body before writing the
  // response, so a refusal waited for a body the client never sent, up to
  // the body read timeout (30 s by default). Only the head is sent here,
  // and the 413 must arrive within 1 s.
  let dir = temp_dir("early_refusal")
  let listener = start_with(dir, [middleware.body_parser(10)])
  let assert Ok(socket) = raw_connect(server.get_port(listener))
    as "test client must connect"
  let head =
    "POST /upload HTTP/1.1\r\nHost: test\r\nContent-Length: 5000\r\n\r\n"
  let assert Ok(Nil) = raw_send(socket, <<head:utf8>>) as "send must succeed"
  let assert Ok(#(413, _, _)) = raw_recv_response(socket, 1000, True)
  raw_close(socket)
  server.stop(listener)
  cleanup(dir)
}

pub fn small_leftover_body_is_discarded_after_the_response_test() {
  // The response goes out first; a leftover within the discard bound is
  // read afterwards, so the connection still serves the next request.
  let dir = temp_dir("leftover")
  let assert Ok(Nil) = simplifile.write(dir <> "/a.txt", "a")
  let listener = start(dir)
  let assert Ok(socket) = raw_connect(server.get_port(listener))
    as "test client must connect"
  let first =
    "GET /static/a.txt HTTP/1.1\r\nHost: test\r\nContent-Length: 4\r\n\r\nxxxx"
  let assert Ok(Nil) = raw_send(socket, <<first:utf8>>) as "send must succeed"
  let assert Ok(#(200, _, <<"a">>)) = raw_recv_response(socket, 2000, True)
  let second = "GET /static/a.txt HTTP/1.1\r\nHost: test\r\n\r\n"
  let assert Ok(Nil) = raw_send(socket, <<second:utf8>>) as "send must succeed"
  let assert Ok(#(200, _, <<"a">>)) = raw_recv_response(socket, 2000, True)
  raw_close(socket)
  server.stop(listener)
  cleanup(dir)
}

// --- /health ---

pub fn health_answers_get_and_head_test() {
  let dir = temp_dir("health")
  let listener = start(dir)
  let get = request(listener, "GET", "/health", "")
  let assert 200 = get.0
  let assert Ok("no-store") = header(get, "cache-control")
  let assert True = bit_array.byte_size(get.2) > 0
  let head = request(listener, "HEAD", "/health", "")
  let assert 200 = head.0
  let assert Ok(length) = header(head, "content-length")
  let assert True = length == int.to_string(bit_array.byte_size(get.2))
  let assert <<>> = head.2
  server.stop(listener)
  cleanup(dir)
}

pub fn health_refuses_other_methods_test() {
  let dir = temp_dir("health_methods")
  let listener = start(dir)
  ["POST", "PUT", "DELETE", "PATCH"]
  |> list.each(fn(method) {
    let resp = request(listener, method, "/health", "Content-Length: 0\r\n")
    let assert 405 = resp.0
    let assert Ok("GET, HEAD") = header(resp, "allow")
  })
  server.stop(listener)
  cleanup(dir)
}

@external(erlang, "beacon_test_ffi", "unique_ref")
fn unique_ref() -> String

@external(erlang, "beacon_http_routes_test_ffi", "make_fifo")
fn make_fifo(path: String) -> Result(Nil, String)

@external(erlang, "beacon_http_raw_ffi", "connect")
fn raw_connect(port: Int) -> Result(Socket, String)

@external(erlang, "beacon_http_raw_ffi", "send")
fn raw_send(socket: Socket, data: BitArray) -> Result(Nil, String)

@external(erlang, "beacon_http_raw_ffi", "recv_response")
fn raw_recv_response(
  socket: Socket,
  timeout_ms: Int,
  expect_body: Bool,
) -> Result(RawResponse, String)

@external(erlang, "beacon_http_raw_ffi", "close")
fn raw_close(socket: Socket) -> Nil
