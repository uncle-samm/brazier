/// HTTP/1.1 request parsing, message framing and response writing.
///
/// Request heads are parsed from a per-connection buffer with
/// `erlang:decode_packet/3`, with strict validation on top (see
/// `beacon_transport_ffi:read_http_head/3`). Bytes that arrive with a head
/// (body bytes, pipelined requests) stay buffered for the next read.
/// This module adds the RFC 9112 message-framing rules that protect against
/// request smuggling, the per-request body context, and framed response
/// serialization (Content-Length always computed, HEAD/1xx/204/304 bodies
/// suppressed, `Connection` handled by the server).
///
/// Reference: RFC 9112 (HTTP/1.1), RFC 9110 (HTTP semantics), cowboy_http.
import beacon/log
import beacon/telemetry
import beacon/transport/server
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// --- Request head ---

/// Protocol version of a parsed request.
pub type HttpVersion {
  Http10
  Http11
}

/// Size limits for reading a request head.
pub type HeadLimits {
  HeadLimits(
    /// Maximum number of header fields.
    max_headers: Int,
    /// Maximum total header bytes (also bounds each header line).
    max_header_bytes: Int,
    /// Maximum request-line length in bytes.
    max_request_line_bytes: Int,
  )
}

/// When the header section must be complete.
pub type HeaderDeadline {
  /// Request line and headers share one deadline (first request).
  SharedWithRequestLine
  /// Headers must arrive within this many ms after the request line
  /// (keep-alive requests, where the request line wait is the idle timeout).
  AfterRequestLine(ms: Int)
}

/// Timing limits for reading a request head.
pub type HeadTiming {
  HeadTiming(request_line_timeout_ms: Int, header_deadline: HeaderDeadline)
}

/// Why a request head could not be read.
pub type HeadError {
  /// The peer closed the connection before sending a request line.
  PeerClosed
  /// No byte of a new request arrived before the timeout.
  IdleTimeout
  /// A request started but its head was not complete before the deadline.
  RequestTimeout
  /// The request line exceeded the configured limit.
  RequestLineTooLong
  /// The header section exceeded the configured byte limit.
  HeadersTooLarge
  /// The header section exceeded the configured field count.
  TooManyHeaders
  /// The request head is malformed.
  BadRequest(String)
  /// The request method is not supported.
  NotImplemented(String)
  /// The HTTP version is not supported.
  VersionNotSupported(String)
  /// The socket failed.
  SocketError(String)
}

@external(erlang, "beacon_transport_ffi", "read_http_head")
fn ffi_read_http_head(
  socket: server.Socket,
  limits: HeadLimits,
  timing: HeadTiming,
) -> Result(#(String, String, HttpVersion, List(#(String, String))), HeadError)

/// Read and parse a request head into a gleam_http Request.
/// The socket is embedded in the Connection body so handlers can read the
/// request body with `read_body`.
pub fn read_request_head(
  socket: server.Socket,
  limits: HeadLimits,
  timing: HeadTiming,
) -> Result(#(Request(server.Connection), HttpVersion), HeadError) {
  case ffi_read_http_head(socket, limits, timing) {
    Ok(#(method, path, version, headers)) -> {
      log.debug("beacon.http", "Read request head " <> method <> " " <> path)
      Ok(#(build_request(socket, #(method, path, headers)), version))
    }
    Error(err) -> {
      case err {
        PeerClosed | IdleTimeout ->
          log.debug(
            "beacon.http",
            "No request on connection: " <> get_head_error_message(err),
          )
        _ ->
          log.warning(
            "beacon.http",
            "Rejected request head: " <> get_head_error_message(err),
          )
      }
      Error(err)
    }
  }
}

/// The response status for a head error, or None when the connection
/// should just be closed (the peer left, was idle, or the socket broke).
pub fn get_head_error_status(err: HeadError) -> Option(Int) {
  case err {
    PeerClosed | IdleTimeout | SocketError(_) -> None
    RequestTimeout -> Some(408)
    RequestLineTooLong -> Some(414)
    HeadersTooLarge | TooManyHeaders -> Some(431)
    BadRequest(_) -> Some(400)
    NotImplemented(_) -> Some(501)
    VersionNotSupported(_) -> Some(505)
  }
}

/// Human-readable description of a head error.
pub fn get_head_error_message(err: HeadError) -> String {
  case err {
    PeerClosed -> "peer closed the connection"
    IdleTimeout -> "idle timeout"
    RequestTimeout -> "request head timeout"
    RequestLineTooLong -> "request line too long"
    HeadersTooLarge -> "request header fields too large"
    TooManyHeaders -> "too many request header fields"
    BadRequest(reason) -> "bad request: " <> reason
    NotImplemented(method) -> "method not implemented: " <> method
    VersionNotSupported(version) -> "HTTP version not supported: " <> version
    SocketError(reason) -> "socket error: " <> reason
  }
}

// --- Legacy request reading (single request, string errors) ---

@external(erlang, "beacon_transport_ffi", "read_http_request")
fn ffi_read_http_request(
  socket: server.Socket,
) -> Result(#(String, String, List(#(String, String))), String)

@external(erlang, "beacon_transport_ffi", "read_http_request_with_limits")
fn ffi_read_http_request_with_limits(
  socket: server.Socket,
  max_headers: Int,
  max_header_bytes: Int,
  timeout_ms: Int,
) -> Result(#(String, String, List(#(String, String))), String)

/// Read and parse an HTTP request head with default limits.
pub fn read_request(
  socket: server.Socket,
) -> Result(Request(server.Connection), String) {
  log.debug("beacon.http", "Reading HTTP request")
  case ffi_read_http_request(socket) {
    Ok(parts) -> Ok(build_request(socket, parts))
    Error(reason) -> {
      log.warning("beacon.http", "Failed to read HTTP request: " <> reason)
      Error(reason)
    }
  }
}

/// Read and parse an HTTP request head with explicit resource limits.
pub fn read_request_with_limits(
  socket: server.Socket,
  max_headers: Int,
  max_header_bytes: Int,
  timeout_ms: Int,
) -> Result(Request(server.Connection), String) {
  log.debug("beacon.http", "Reading HTTP request with configured limits")
  case
    ffi_read_http_request_with_limits(
      socket,
      max_headers,
      max_header_bytes,
      timeout_ms,
    )
  {
    Ok(parts) -> Ok(build_request(socket, parts))
    Error(reason) -> {
      log.warning("beacon.http", "HTTP request rejected: " <> reason)
      Error(reason)
    }
  }
}

// --- Message framing (RFC 9112 section 6) ---

/// The validated body framing of a request.
pub type BodyFraming {
  BodyFraming(content_length: Int, expect_continue: Bool)
}

/// A request whose framing must be rejected.
pub type FramingError {
  FramingError(status: Int, reason: String)
}

/// Validate a request's message framing before any handler runs.
///
/// - HTTP/1.1 requires exactly one Host header; more than one is rejected.
/// - Transfer-Encoding together with Content-Length is a smuggling vector
///   and is rejected with 400. Transfer-Encoding alone (chunked uploads) is
///   not supported and is rejected with 501.
/// - Content-Length must be a single header holding 1-19 ASCII digits; lists
///   (`5, 5`), duplicates, signs and whitespace are rejected with 400, and a
///   length above `max_body_bytes` with 413.
/// - `Expect: 100-continue` is honoured on HTTP/1.1; any other expectation
///   is rejected with 417.
pub fn check_framing(
  req: Request(server.Connection),
  version: HttpVersion,
  max_body_bytes: Int,
) -> Result(BodyFraming, FramingError) {
  let result = {
    use Nil <- try_framing(check_host(req, version))
    use content_length <- try_framing(check_content_length(req, max_body_bytes))
    use expect_continue <- try_framing(check_expect(req, version))
    Ok(BodyFraming(
      content_length: content_length,
      expect_continue: expect_continue,
    ))
  }
  case result {
    Ok(framing) -> {
      log.debug(
        "beacon.http",
        "Request framing ok, content-length "
          <> int.to_string(framing.content_length),
      )
      Ok(framing)
    }
    Error(err) -> {
      log.warning(
        "beacon.http",
        "Rejected request framing ("
          <> int.to_string(err.status)
          <> "): "
          <> err.reason,
      )
      Error(err)
    }
  }
}

fn try_framing(
  result: Result(a, FramingError),
  next: fn(a) -> Result(b, FramingError),
) -> Result(b, FramingError) {
  case result {
    Ok(value) -> next(value)
    Error(err) -> Error(err)
  }
}

fn check_host(
  req: Request(server.Connection),
  version: HttpVersion,
) -> Result(Nil, FramingError) {
  case header_values(req.headers, "host"), version {
    [_], _ -> Ok(Nil)
    [], Http10 -> Ok(Nil)
    [], Http11 -> Error(FramingError(400, "missing Host header"))
    _, _ -> Error(FramingError(400, "multiple Host headers"))
  }
}

fn check_content_length(
  req: Request(server.Connection),
  max_body_bytes: Int,
) -> Result(Int, FramingError) {
  let transfer_encoding = header_values(req.headers, "transfer-encoding")
  let content_length = header_values(req.headers, "content-length")
  case transfer_encoding, content_length {
    [_, ..], [_, ..] ->
      Error(FramingError(
        400,
        "both Transfer-Encoding and Content-Length present",
      ))
    [_, ..], [] ->
      Error(FramingError(501, "Transfer-Encoding is not supported"))
    [], [] -> Ok(0)
    [], [value] ->
      case parse_content_length(value) {
        Error(Nil) ->
          Error(FramingError(400, "invalid Content-Length: " <> value))
        Ok(length) if length > max_body_bytes ->
          Error(FramingError(
            413,
            "Content-Length "
              <> int.to_string(length)
              <> " exceeds limit of "
              <> int.to_string(max_body_bytes),
          ))
        Ok(length) -> Ok(length)
      }
    [], _ -> Error(FramingError(400, "multiple Content-Length headers"))
  }
}

/// 1*DIGIT, at most 19 digits so the value always fits a 64-bit integer.
fn parse_content_length(value: String) -> Result(Int, Nil) {
  let length = string.length(value)
  case length >= 1 && length <= 19 && all_ascii_digits(value) {
    True -> int.parse(value)
    False -> Error(Nil)
  }
}

fn all_ascii_digits(value: String) -> Bool {
  bit_array_all_digits(<<value:utf8>>)
}

fn bit_array_all_digits(bits: BitArray) -> Bool {
  case bits {
    <<>> -> True
    <<c, rest:bytes>> if c >= 48 && c <= 57 -> bit_array_all_digits(rest)
    _ -> False
  }
}

fn check_expect(
  req: Request(server.Connection),
  version: HttpVersion,
) -> Result(Bool, FramingError) {
  case header_values(req.headers, "expect"), version {
    [], _ -> Ok(False)
    [value], Http11 ->
      case string.lowercase(string.trim(value)) {
        "100-continue" -> Ok(True)
        _ -> Error(FramingError(417, "unsupported expectation: " <> value))
      }
    // RFC 9110 10.1.1: a server MUST ignore 100-continue in HTTP/1.0.
    [value], Http10 ->
      case string.lowercase(string.trim(value)) {
        "100-continue" -> Ok(False)
        _ -> Error(FramingError(417, "unsupported expectation: " <> value))
      }
    _, _ -> Error(FramingError(417, "multiple Expect headers"))
  }
}

/// Whether the client allows the connection to stay open after this
/// request (RFC 9112 9.3): HTTP/1.1 persists unless `Connection: close`;
/// HTTP/1.0 persists only with `Connection: keep-alive`.
pub fn is_keep_alive_requested(
  req: Request(server.Connection),
  version: HttpVersion,
) -> Bool {
  let tokens = connection_tokens(req.headers)
  case version {
    Http11 -> !list.contains(tokens, "close")
    Http10 ->
      list.contains(tokens, "keep-alive") && !list.contains(tokens, "close")
  }
}

/// Whether a response asks for the connection to be closed.
pub fn is_close_requested_by_response(
  resp: Response(server.ResponseBody),
) -> Bool {
  list.contains(connection_tokens(resp.headers), "close")
}

fn connection_tokens(headers: List(#(String, String))) -> List(String) {
  headers
  |> list.filter(fn(h) { string.lowercase(h.0) == "connection" })
  |> list.flat_map(fn(h) { string.split(h.1, ",") })
  |> list.map(fn(token) { string.lowercase(string.trim(token)) })
}

// --- Request body ---

@external(erlang, "beacon_transport_ffi", "http_body_begin")
fn ffi_body_begin(
  socket: server.Socket,
  length: Int,
  expect_continue: Bool,
  body_timeout_ms: Int,
  deadline_ms: Int,
) -> Nil

@external(erlang, "beacon_transport_ffi", "http_body_end")
fn ffi_body_end(socket: server.Socket) -> Nil

@external(erlang, "beacon_transport_ffi", "http_body_state")
fn ffi_body_state(socket: server.Socket) -> Result(#(Int, Bool), Nil)

@external(erlang, "beacon_transport_ffi", "monotonic_ms")
fn ffi_monotonic_ms() -> Int

/// Current monotonic time in milliseconds (for request deadlines).
pub fn get_monotonic_ms() -> Int {
  ffi_monotonic_ms()
}

/// Register the body framing of the request about to be handled.
/// Every body read for this request is bounded by the declared length, the
/// per-read timeout and the absolute request deadline (monotonic ms).
pub fn begin_body(
  socket: server.Socket,
  framing: BodyFraming,
  body_timeout_ms: Int,
  deadline_ms: Int,
) -> Nil {
  log.debug(
    "beacon.http",
    "Begin request body of "
      <> int.to_string(framing.content_length)
      <> " bytes",
  )
  ffi_body_begin(
    socket,
    framing.content_length,
    framing.expect_continue,
    body_timeout_ms,
    deadline_ms,
  )
}

/// Body state after the handler ran.
pub type BodyOutcome {
  /// The body was fully read (or empty): the connection can be reused.
  BodyConsumed
  /// Bytes of the body were left unread.
  BodyUnread(remaining: Int)
  /// A body read failed; the connection position is unknown.
  BodyFailed
}

/// Finish the current request's body context, discarding up to
/// `max_discard_bytes` of unread body so the connection can be reused
/// (cowboy does the same). Larger leftovers are reported as unread.
pub fn finish_body(
  socket: server.Socket,
  max_discard_bytes: Int,
) -> BodyOutcome {
  let outcome = case ffi_body_state(socket) {
    Error(Nil) -> {
      log.error(
        "beacon.http",
        "finish_body called without an active request body context",
      )
      BodyFailed
    }
    Ok(#(_, True)) -> BodyFailed
    Ok(#(0, False)) -> BodyConsumed
    Ok(#(remaining, False)) if remaining <= max_discard_bytes ->
      case server.read_body(socket, remaining) {
        Ok(_) -> {
          log.debug(
            "beacon.http",
            "Discarded " <> int.to_string(remaining) <> " unread body bytes",
          )
          BodyConsumed
        }
        Error(reason) -> {
          log.warning(
            "beacon.http",
            "Failed to discard unread request body: " <> reason,
          )
          BodyFailed
        }
      }
    Ok(#(remaining, False)) -> BodyUnread(remaining)
  }
  ffi_body_end(socket)
  outcome
}

/// Read the request body.
///
/// Returns Error if Content-Length is missing, the body exceeds
/// `max_bytes`, the body was already consumed, or reading fails or times
/// out. The body can be read at most once.
///
/// Example:
/// ```gleam
/// case transport_http.read_body(request, 1_000_000) {
///   Ok(body_bits) -> {
///     case bit_array.to_string(body_bits) {
///       Ok(body_string) -> handle_json(body_string)
///       Error(Nil) -> send_error(400, "Invalid UTF-8")
///     }
///   }
///   Error(reason) -> send_error(400, reason)
/// }
/// ```
pub fn read_body(
  req: Request(server.Connection),
  max_bytes: Int,
) -> Result(BitArray, String) {
  let server.Connection(socket: socket) = req.body
  case request.get_header(req, "content-length") {
    Error(Nil) -> {
      log.debug("beacon.http", "read_body: request has no Content-Length")
      Error("Missing Content-Length header")
    }
    Ok(length_str) ->
      case parse_content_length(length_str), ffi_body_state(socket) {
        Error(Nil), _ -> {
          log.warning("beacon.http", "read_body: invalid Content-Length")
          Error("Invalid Content-Length header")
        }
        _, Error(Nil) -> {
          log.error(
            "beacon.http",
            "read_body called outside an active HTTP request",
          )
          Error("read_body called outside an active HTTP request")
        }
        Ok(_), Ok(#(_, True)) -> {
          log.warning("beacon.http", "read_body after an earlier read failure")
          Error("Request body unavailable after an earlier read failure")
        }
        Ok(length), Ok(#(_, False)) if length > max_bytes -> {
          log.warning(
            "beacon.http",
            "read_body: Content-Length "
              <> int.to_string(length)
              <> " exceeds limit of "
              <> int.to_string(max_bytes),
          )
          Error(
            "Content-Length "
            <> int.to_string(length)
            <> " exceeds limit of "
            <> int.to_string(max_bytes),
          )
        }
        Ok(length), Ok(#(remaining, False)) if remaining != length -> {
          log.warning("beacon.http", "read_body: body already consumed")
          Error("Request body already consumed")
        }
        Ok(0), Ok(#(_, False)) -> Ok(<<>>)
        Ok(length), Ok(#(_, False)) -> {
          log.debug(
            "beacon.http",
            "Reading HTTP body of " <> int.to_string(length) <> " bytes",
          )
          case server.read_body(socket, length) {
            Ok(body) -> Ok(body)
            Error(reason) -> {
              log.warning("beacon.http", "Failed to read body: " <> reason)
              Error(reason)
            }
          }
        }
      }
  }
}

// --- Handler isolation ---

@external(erlang, "beacon_transport_ffi", "run_handler")
fn ffi_run_handler(
  handler: fn(Request(server.Connection)) -> Response(server.ResponseBody),
  req: Request(server.Connection),
) -> Result(Response(server.ResponseBody), String)

@external(erlang, "beacon_transport_ffi", "http_route_reset")
fn ffi_route_reset() -> Nil

@external(erlang, "beacon_transport_ffi", "http_route_tag")
fn ffi_route_tag(route: String) -> Nil

@external(erlang, "beacon_transport_ffi", "http_route_take")
fn ffi_route_take() -> String

@external(erlang, "beacon_transport_ffi", "http_connection_id")
fn ffi_connection_id() -> String

@external(erlang, "beacon_transport_ffi", "http_body_consumed")
fn ffi_body_consumed(socket: server.Socket) -> Int

/// Longest route pattern `tag_route` accepts, in bytes.
pub const max_route_tag_bytes = 255

/// Tag the request being handled with the route pattern it matched (for
/// example `/users/:id`), never the raw path. The pattern becomes the
/// `route` of the `[beacon, http, request]` stop event; a request nobody
/// tags reports `"unknown"`. Call it from the routing code that runs inside
/// `run_handler`; the last tag wins.
///
/// An empty pattern or one longer than `max_route_tag_bytes` is a
/// programming error and crashes the request (answered with 500).
pub fn tag_route(pattern: String) -> Nil {
  let size = string.byte_size(pattern)
  case size > 0 && size <= max_route_tag_bytes {
    True -> log.debug("beacon.http", "Request matched route " <> pattern)
    False ->
      log.error(
        "beacon.http",
        "tag_route called with a "
          <> int.to_string(size)
          <> "-byte route pattern (allowed 1 to "
          <> int.to_string(max_route_tag_bytes)
          <> ")",
      )
  }
  let assert True = size > 0 && size <= max_route_tag_bytes
    as "tag_route: a route pattern is 1 to 255 bytes"
  ffi_route_tag(pattern)
}

/// Run a request handler inside a `[beacon, http, request]` telemetry span;
/// a crash is logged with its stacktrace and returned as an error so the
/// connection can answer 500 and close.
///
/// The span covers the handler only (reading the request body is part of
/// it; writing the response is not). Its stop event carries the tagged
/// route (see `tag_route`), the status (500 for a crash), the body bytes
/// the handler read and the size of the body it returned.
pub fn run_handler(
  handler: fn(Request(server.Connection)) -> Response(server.ResponseBody),
  req: Request(server.Connection),
) -> Result(Response(server.ResponseBody), String) {
  telemetry.http_request_span(
    method_label(req.method),
    ffi_connection_id(),
    fn() {
      ffi_route_reset()
      let result = ffi_run_handler(handler, req)
      let route = ffi_route_take()
      let req_bytes = ffi_body_consumed(req.body.socket)
      case result {
        Ok(resp) -> #(
          Ok(resp),
          route,
          resp.status,
          req_bytes,
          response_body_bytes(resp),
        )
        Error(reason) -> {
          log.error(
            "beacon.http",
            "Request handler crashed on route " <> route <> ": " <> reason,
          )
          #(Error(reason), route, 500, req_bytes, 0)
        }
      }
    },
  )
}

/// A bounded method label: the methods the parser accepts, `OTHER` for
/// anything else (the parser rejects other methods, so this is defensive
/// against a handler being run on a hand-built request).
fn method_label(method: http.Method) -> String {
  case method {
    http.Get -> "GET"
    http.Post -> "POST"
    http.Put -> "PUT"
    http.Delete -> "DELETE"
    http.Head -> "HEAD"
    http.Options -> "OPTIONS"
    http.Patch -> "PATCH"
    http.Connect -> "CONNECT"
    http.Trace -> "TRACE"
    http.Other(_) -> "OTHER"
  }
}

fn response_body_bytes(resp: Response(server.ResponseBody)) -> Int {
  let server.Bytes(body) = resp.body
  bytes_tree.byte_size(body)
}

// --- Responses ---

/// How a response is framed on the wire.
pub type ResponseFraming {
  ResponseFraming(
    /// Version of the request being answered.
    version: HttpVersion,
    /// The request was HEAD: send headers only.
    head_request: Bool,
    /// The connection stays open after this response.
    keep_alive: Bool,
  )
}

/// Framing for a response after which the connection is closed.
pub fn default_closing_framing() -> ResponseFraming {
  ResponseFraming(version: Http11, head_request: False, keep_alive: False)
}

/// Write an HTTP response and announce that the connection will close.
pub fn write_response(
  socket: server.Socket,
  resp: Response(server.ResponseBody),
) -> Result(Nil, String) {
  log.debug(
    "beacon.http",
    "Writing HTTP response status " <> int.to_string(resp.status),
  )
  write_framed_response(socket, resp, default_closing_framing())
}

/// Serialize and send a response.
///
/// - Content-Length is always computed from the body. A handler-supplied
///   value that disagrees is logged and replaced, except on HEAD responses
///   with an empty body, where it describes the GET representation.
/// - Transfer-Encoding and Connection headers from handlers are removed
///   (the server owns message framing); `connection: close` is sent when
///   the connection will close, `connection: keep-alive` for persistent
///   HTTP/1.0 connections.
/// - 1xx, 204 and 304 responses never carry a body; HEAD responses send
///   headers only.
/// - `x-content-type-options: nosniff` is added when absent.
pub fn write_framed_response(
  socket: server.Socket,
  resp: Response(server.ResponseBody),
  framing: ResponseFraming,
) -> Result(Nil, String) {
  case validate_response_headers(resp.headers) {
    Error(reason) -> {
      log.error("beacon.http", "Refusing unsafe response headers: " <> reason)
      Error(reason)
    }
    Ok(Nil) -> {
      let body_bits = case resp.body {
        server.Bytes(tree) -> bytes_tree.to_bit_array(tree)
      }
      let body_size = bit_array.byte_size(body_bits)
      let status = resp.status
      let bodyless_status = status < 200 || status == 204 || status == 304
      let user_lengths = header_values_ci(resp.headers, "content-length")
      case header_values_ci(resp.headers, "transfer-encoding") {
        [] -> Nil
        _ ->
          log.error(
            "beacon.http",
            "Handler set Transfer-Encoding on a "
              <> int.to_string(status)
              <> " response; removed (responses are Content-Length framed)",
          )
      }
      let length_header = case bodyless_status, user_lengths {
        True, [user] if status == 304 -> Some(user)
        True, _ -> None
        False, [user] if framing.head_request && body_size == 0 -> Some(user)
        False, [] -> Some(int.to_string(body_size))
        False, [user] if user == "" -> Some(int.to_string(body_size))
        False, users -> {
          let actual = int.to_string(body_size)
          case users == [actual] {
            True -> Nil
            False ->
              log.error(
                "beacon.http",
                "Handler Content-Length "
                  <> string.join(users, ",")
                  <> " does not match body size "
                  <> actual
                  <> "; using the body size",
              )
          }
          Some(actual)
        }
      }
      case bodyless_status && body_size > 0 {
        True ->
          log.warning(
            "beacon.http",
            "Dropping body of a " <> int.to_string(status) <> " response",
          )
        False -> Nil
      }
      let kept_headers =
        list.filter(resp.headers, fn(h) {
          case string.lowercase(h.0) {
            "content-length" | "transfer-encoding" | "connection" -> False
            _ -> True
          }
        })
      let nosniff = case
        header_values_ci(resp.headers, "x-content-type-options")
      {
        [] -> [#("x-content-type-options", "nosniff")]
        _ -> []
      }
      let connection = case framing.keep_alive, framing.version {
        False, _ -> [#("connection", "close")]
        True, Http10 -> [#("connection", "keep-alive")]
        True, Http11 -> []
      }
      let length = case length_header {
        Some(value) -> [#("content-length", value)]
        None -> []
      }
      let all_headers =
        list.flatten([kept_headers, nosniff, length, connection])
      let status_line =
        "HTTP/1.1 "
        <> int.to_string(status)
        <> " "
        <> reason_phrase(status)
        <> "\r\n"
      let header_str =
        string.concat([
          status_line,
          ..list.map(all_headers, fn(h) { h.0 <> ": " <> h.1 <> "\r\n" })
        ])
        <> "\r\n"
      let send_body = !bodyless_status && !framing.head_request
      let wire = case send_body {
        True -> bit_array.append(<<header_str:utf8>>, body_bits)
        False -> <<header_str:utf8>>
      }
      server.send_bytes(socket, wire)
    }
  }
}

/// A framework-generated error response: plain text, never sniffed, never
/// framed, never cached, with a CSP that forbids everything.
pub fn create_error_response(
  status: Int,
  message: String,
) -> Response(server.ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; frame-ancestors 'none'",
  )
  |> response.set_header("x-frame-options", "DENY")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(server.Bytes(bytes_tree.from_string(message)))
}

/// Write a framework error response and close the socket.
pub fn write_error(socket: server.Socket, status: Int, body: String) -> Nil {
  log.warning(
    "beacon.http",
    "Writing HTTP error response status " <> int.to_string(status),
  )
  case write_response(socket, create_error_response(status, body)) {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.warning(
        "beacon.http",
        "Failed to write "
          <> int.to_string(status)
          <> " error response: "
          <> reason,
      )
  }
  close_gracefully(socket)
}

/// How long `close_gracefully` keeps draining the peer after half-closing
/// (cowboy's default `linger_timeout`).
const linger_timeout_ms = 1000

/// Most bytes `close_gracefully` discards before closing regardless.
const linger_max_bytes = 1_048_576

type LingerOutcome {
  LingerPeerClosed
  LingerTimeout
  LingerLimit
  LingerSocketError(String)
}

/// Close a connection the server decided to end after writing a response.
///
/// A plain close with unread request bytes in the receive buffer makes the
/// kernel answer with RST, which can destroy the response before the client
/// reads it (for example a 431 for an oversized header block). This
/// half-closes the write side, drains what the peer still sends for at most
/// one second or 1 MiB, then closes.
pub fn close_gracefully(socket: server.Socket) -> Nil {
  case ffi_linger_close(socket, linger_timeout_ms, linger_max_bytes) {
    LingerPeerClosed -> log.debug("beacon.http", "Connection closed by peer")
    LingerTimeout ->
      log.debug("beacon.http", "Closed connection after linger timeout")
    LingerLimit ->
      log.warning(
        "beacon.http",
        "Closed connection after discarding the linger byte limit",
      )
    LingerSocketError(reason) ->
      log.debug(
        "beacon.http",
        "Socket error while closing connection: " <> reason,
      )
  }
}

/// Received bytes not yet consumed by the parser or a body read. Non-zero at
/// a WebSocket upgrade means the client sent data before the handshake
/// completed (RFC 6455 4.1); those bytes would be lost by the frame reader.
@external(erlang, "beacon_transport_ffi", "http_buffered_bytes")
pub fn get_buffered_byte_count(socket: server.Socket) -> Int

@external(erlang, "beacon_transport_ffi", "linger_close")
fn ffi_linger_close(
  socket: server.Socket,
  timeout_ms: Int,
  max_bytes: Int,
) -> LingerOutcome

/// Validate one HTTP response header before serializing it to the wire.
///
/// Header names must be RFC 9110 tokens. Header values must not contain CR,
/// LF, or NUL because those bytes enable response splitting.
pub fn validate_response_header(
  name: String,
  value: String,
) -> Result(Nil, String) {
  case is_valid_header_name(name), is_valid_header_value(value) {
    False, _ -> {
      log.warning("beacon.http", "Invalid HTTP response header name: " <> name)
      Error("Invalid HTTP response header name: " <> name)
    }
    _, False -> {
      log.warning(
        "beacon.http",
        "Invalid HTTP response header value for " <> name,
      )
      Error("Invalid HTTP response header value for " <> name)
    }
    True, True -> Ok(Nil)
  }
}

// --- Internal helpers ---

fn header_values(
  headers: List(#(String, String)),
  name: String,
) -> List(String) {
  list.filter_map(headers, fn(h) {
    case h.0 == name {
      True -> Ok(h.1)
      False -> Error(Nil)
    }
  })
}

fn header_values_ci(
  headers: List(#(String, String)),
  name: String,
) -> List(String) {
  list.filter_map(headers, fn(h) {
    case string.lowercase(h.0) == name {
      True -> Ok(string.trim(h.1))
      False -> Error(Nil)
    }
  })
}

fn validate_response_headers(
  headers: List(#(String, String)),
) -> Result(Nil, String) {
  case headers {
    [] -> Ok(Nil)
    [#(name, value), ..rest] -> {
      case validate_response_header(name, value) {
        Error(reason) -> Error(reason)
        Ok(Nil) -> validate_response_headers(rest)
      }
    }
  }
}

fn is_valid_header_name(name: String) -> Bool {
  name != "" && token_bytes(<<name:utf8>>)
}

fn token_bytes(bits: BitArray) -> Bool {
  case bits {
    <<>> -> True
    <<c, rest:bytes>> ->
      case is_token_byte(c) {
        True -> token_bytes(rest)
        False -> False
      }
    _ -> False
  }
}

fn is_token_byte(c: Int) -> Bool {
  { c >= 97 && c <= 122 }
  || { c >= 65 && c <= 90 }
  || { c >= 48 && c <= 57 }
  || c == 33
  || c == 35
  || c == 36
  || c == 37
  || c == 38
  || c == 39
  || c == 42
  || c == 43
  || c == 45
  || c == 46
  || c == 94
  || c == 95
  || c == 96
  || c == 124
  || c == 126
}

fn is_valid_header_value(value: String) -> Bool {
  !string.contains(value, "\r")
  && !string.contains(value, "\n")
  && !string.contains(value, "\u{0000}")
}

fn build_request(
  socket: server.Socket,
  parts: #(String, String, List(#(String, String))),
) -> Request(server.Connection) {
  let #(method_str, raw_path, headers) = parts
  let method = parse_method(method_str)
  let #(path, query) = split_path_query(raw_path)
  let host = case header_values(headers, "host") {
    [value, ..] -> value
    [] -> ""
  }
  let #(host_name, port_opt) = parse_host(host)
  request.Request(
    method: method,
    headers: headers,
    body: server.Connection(socket: socket),
    scheme: http.Http,
    host: host_name,
    port: port_opt,
    path: path,
    query: query,
  )
}

fn parse_method(method_str: String) -> http.Method {
  case method_str {
    "GET" -> http.Get
    "POST" -> http.Post
    "PUT" -> http.Put
    "DELETE" -> http.Delete
    "HEAD" -> http.Head
    "OPTIONS" -> http.Options
    "PATCH" -> http.Patch
    _ -> http.Other(method_str)
  }
}

fn split_path_query(raw_path: String) -> #(String, Option(String)) {
  case string.split_once(raw_path, "?") {
    Ok(#(path, query)) -> #(path, Some(query))
    Error(Nil) -> #(raw_path, None)
  }
}

fn parse_host(host: String) -> #(String, Option(Int)) {
  case string.split(host, ":") {
    [name, port_str] ->
      case int.parse(port_str) {
        Ok(port) -> #(name, Some(port))
        Error(Nil) -> #(host, None)
      }
    _ -> #(host, None)
  }
}

fn reason_phrase(status: Int) -> String {
  case status {
    100 -> "Continue"
    101 -> "Switching Protocols"
    200 -> "OK"
    201 -> "Created"
    202 -> "Accepted"
    204 -> "No Content"
    206 -> "Partial Content"
    301 -> "Moved Permanently"
    302 -> "Found"
    303 -> "See Other"
    304 -> "Not Modified"
    307 -> "Temporary Redirect"
    308 -> "Permanent Redirect"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    404 -> "Not Found"
    405 -> "Method Not Allowed"
    406 -> "Not Acceptable"
    408 -> "Request Timeout"
    409 -> "Conflict"
    410 -> "Gone"
    411 -> "Length Required"
    412 -> "Precondition Failed"
    413 -> "Content Too Large"
    414 -> "URI Too Long"
    415 -> "Unsupported Media Type"
    416 -> "Range Not Satisfiable"
    417 -> "Expectation Failed"
    422 -> "Unprocessable Content"
    426 -> "Upgrade Required"
    428 -> "Precondition Required"
    429 -> "Too Many Requests"
    431 -> "Request Header Fields Too Large"
    500 -> "Internal Server Error"
    501 -> "Not Implemented"
    502 -> "Bad Gateway"
    503 -> "Service Unavailable"
    504 -> "Gateway Timeout"
    505 -> "HTTP Version Not Supported"
    _ -> "Unknown"
  }
}
