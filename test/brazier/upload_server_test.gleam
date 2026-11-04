/// Uploads through the real HTTP server over raw sockets: the request cap
/// is enforced from Content-Length before the body is read, disguised
/// content is refused with 415, and stored files come back as attachments.
import brazier/transport
import brazier/transport/server.{type Connection, type Socket, Bytes}
import brazier/upload
import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const boundary = "XyZBoundary"

fn png_bytes() -> BitArray {
  <<0x89, "PNG":utf8, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR":utf8>>
}

fn config() -> upload.UploadConfig {
  upload.default_config()
  |> upload.with_max_size(1024)
  |> upload.with_max_request_bytes(4096)
}

fn handler(
  dir: String,
) -> fn(Request(Connection)) ->
  option.Option(response.Response(server.ResponseBody)) {
  fn(req: Request(Connection)) {
    case string.split(req.path, "/") {
      ["", "upload"] ->
        case upload.read_multipart(req, config()) {
          Error(error) ->
            Some(text(upload.error_status(error), upload.error_to_string(error)))
          Ok(form) ->
            case upload.file(form, "file") {
              Error(error) -> Some(text(400, upload.error_to_string(error)))
              Ok(file) ->
                case upload.save(file, dir) {
                  Ok(stored) -> Some(text(200, stored.stored_name))
                  Error(error) -> Some(text(500, upload.error_to_string(error)))
                }
            }
        }
      ["", "files", name] ->
        case upload.serve(dir, name, "holiday photo.png") {
          Ok(resp) -> Some(resp)
          Error(error) ->
            Some(text(upload.error_status(error), upload.error_to_string(error)))
        }
      _ -> Some(text(404, "not found"))
    }
  }
}

fn text(status: Int, body: String) -> response.Response(server.ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

fn start(dir: String) -> server.Listener {
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
        body_read_timeout_ms: 500,
        // The raw requests below name the host "test".
        allowed_hosts: ["test"],
      ),
      api_handler: Some(handler(dir)),
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "upload test listener must bind an OS-assigned port"
  listener
}

fn multipart(filename: String, ctype: String, data: BitArray) -> BitArray {
  <<
    "--":utf8,
    boundary:utf8,
    "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"":utf8,
    filename:utf8,
    "\"\r\nContent-Type: ":utf8,
    ctype:utf8,
    "\r\n\r\n":utf8,
    data:bits,
    "\r\n--":utf8,
    boundary:utf8,
    "--\r\n":utf8,
  >>
}

fn post(content_type: String, length: Int) -> BitArray {
  <<
    "POST /upload HTTP/1.1\r\nHost: test\r\nContent-Type: ":utf8,
    content_type:utf8,
    "\r\nContent-Length: ":utf8,
    int.to_string(length):utf8,
    "\r\n\r\n":utf8,
  >>
}

fn exchange(listener: server.Listener, data: BitArray) -> RawResponse {
  let assert Ok(socket) = raw_connect(server.get_port(listener))
    as "test client must connect"
  let assert Ok(Nil) = raw_send(socket, data) as "test client send"
  let assert Ok(resp) = raw_recv_response(socket, 2000, True)
    as "server must answer"
  raw_close(socket)
  resp
}

fn upload_request(body: BitArray) -> BitArray {
  let ctype = "multipart/form-data; boundary=" <> boundary
  <<post(ctype, bit_array.byte_size(body)):bits, body:bits>>
}

pub fn upload_round_trip_test() {
  let dir = fresh_dir()
  let listener = start(dir)
  let assert #(200, _, stored_name) =
    exchange(
      listener,
      upload_request(multipart("../../x.png", "image/png", png_bytes())),
    )
  let assert [listed] = list_dir(dir)
  let assert True = listed == stored_name
  let assert True = string.ends_with(stored_name, ".png")

  let get = <<
    "GET /files/":utf8,
    stored_name:utf8,
    " HTTP/1.1\r\nHost: test\r\n\r\n":utf8,
  >>
  let assert #(200, headers, body) = exchange(listener, get)
  let assert Ok("image/png") = list.key_find(headers, "content-type")
  let assert Ok("nosniff") = list.key_find(headers, "x-content-type-options")
  let assert Ok(disposition) = list.key_find(headers, "content-disposition")
  let assert True = string.starts_with(disposition, "attachment;")
  let assert True = <<body:utf8>> == png_bytes()
  server.stop(listener)
  remove_dir(dir)
}

pub fn declared_length_over_the_cap_is_refused_before_the_body_test() {
  let dir = fresh_dir()
  let listener = start(dir)
  let assert Ok(socket) = raw_connect(server.get_port(listener))
    as "test client must connect"
  // Only the head is sent: the 413 must not wait for the body. 5000 bytes
  // is under the server-wide cap, so the upload cap (4096) is what refuses.
  let ctype = "multipart/form-data; boundary=" <> boundary
  let assert Ok(Nil) = raw_send(socket, post(ctype, 5000)) as "test client send"
  let assert Ok(#(413, _, body)) = raw_recv_response(socket, 2000, True)
  let assert "request body of 5000 bytes exceeds the 4096 byte limit" = body
  raw_close(socket)
  let assert [] = list_dir(dir)
  server.stop(listener)
  remove_dir(dir)
}

pub fn disguised_html_is_refused_with_415_test() {
  let dir = fresh_dir()
  let listener = start(dir)
  let html = <<"<html><script>alert(1)</script></html>":utf8>>
  let assert #(415, _, _) =
    exchange(listener, upload_request(multipart("x.png", "image/png", html)))
  let svg = <<"<svg onload=\"alert(1)\"/>":utf8>>
  let assert #(415, _, _) =
    exchange(listener, upload_request(multipart("x.svg", "image/svg+xml", svg)))
  let assert [] = list_dir(dir)
  server.stop(listener)
  remove_dir(dir)
}

pub fn non_multipart_body_is_refused_test() {
  let dir = fresh_dir()
  let listener = start(dir)
  let assert #(415, _, _) =
    exchange(listener, <<post("application/json", 2):bits, "{}":utf8>>)
  server.stop(listener)
  remove_dir(dir)
}

pub fn file_over_the_per_file_cap_is_refused_test() {
  let dir = fresh_dir()
  let listener = start(dir)
  let big = <<png_bytes():bits, 0:size(16_000)>>
  let assert #(413, _, _) =
    exchange(listener, upload_request(multipart("big.png", "image/png", big)))
  let assert [] = list_dir(dir)
  server.stop(listener)
  remove_dir(dir)
}

pub fn serving_a_traversal_name_is_refused_test() {
  let dir = fresh_dir()
  let listener = start(dir)
  let get = <<"GET /files/..%2Fsecret.png HTTP/1.1\r\nHost: test\r\n\r\n":utf8>>
  let assert #(400, _, _) = exchange(listener, get)
  server.stop(listener)
  remove_dir(dir)
}

// --- FFI ---

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

@external(erlang, "brazier_http_raw_ffi", "close")
fn raw_close(socket: Socket) -> Nil

@external(erlang, "brazier_upload_test_ffi", "fresh_dir")
fn fresh_dir() -> String

@external(erlang, "brazier_upload_test_ffi", "remove_dir")
fn remove_dir(dir: String) -> Nil

@external(erlang, "brazier_upload_test_ffi", "list_dir")
fn list_dir(dir: String) -> List(String)
