//// A raw TCP WebSocket client for tests that must see the exact bytes on
//// the wire: the upgrade response head, close frames with their codes and
//// reasons, and `error` frames. Built on `brazier_ws_test_ffi`.

import gleam/bit_array
import gleam/int
import gleam/string

pub type RawSocket

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
pub fn close(socket: RawSocket) -> Nil

@external(erlang, "brazier_ws_test_ffi", "raw_upgrade_request")
fn raw_upgrade_request(
  path: String,
  host: String,
  headers: List(#(String, String)),
) -> BitArray

@external(erlang, "brazier_ws_test_ffi", "masked_frame")
fn masked_frame(fin: Int, opcode: Int, payload: BitArray) -> BitArray

/// Wait until the server closes the TCP connection; the code of the last
/// close frame seen on the way, or -1 when there was none.
@external(erlang, "brazier_ws_test_ffi", "expect_closed")
pub fn expect_closed(socket: RawSocket, timeout: Int) -> Result(Int, String)

pub const host = "127.0.0.1"

const timeout_ms = 3000

/// The `Host` header (and origin authority) for a listener on `port`.
pub fn authority(port: Int) -> String {
  host <> ":" <> int.to_string(port)
}

/// A valid same-origin upgrade's headers, plus `extra`.
pub fn upgrade_headers(
  port: Int,
  extra: List(#(String, String)),
) -> List(#(String, String)) {
  [
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    #("Sec-WebSocket-Version", "13"),
    #("Origin", "http://" <> authority(port)),
    ..extra
  ]
}

/// Send one request head to `target` and return the socket with the
/// response's three-digit status.
pub fn request(
  port: Int,
  target: String,
  headers: List(#(String, String)),
) -> #(RawSocket, String) {
  let assert Ok(socket) = raw_connect(host, port)
    as "the test client must connect"
  let assert Ok(Nil) =
    raw_send(socket, raw_upgrade_request(target, authority(port), headers))
    as "the test client must send its request"
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, timeout_ms)
    as "the server must answer the request head"
  let assert Ok(head) = bit_array.to_string(head) as "a response head is ASCII"
  #(socket, string.slice(head, 9, 3))
}

/// Upgrade on `page` (already percent-encoded) and require the 101.
pub fn open(
  port: Int,
  page: String,
  extra: List(#(String, String)),
) -> RawSocket {
  let #(socket, status) =
    request(port, "/ws?path=" <> page, upgrade_headers(port, extra))
  let assert "101" = status as "the upgrade must be accepted"
  socket
}

/// Send one masked text frame.
pub fn send_text(socket: RawSocket, text: String) -> Nil {
  let assert Ok(Nil) = raw_send(socket, masked_frame(1, 1, <<text:utf8>>))
    as "test client send must succeed"
  Nil
}

/// A frame the server sent: a text frame, a close frame, or another opcode.
pub type Frame {
  Text(String)
  Close(code: Int, reason: String)
  Other(opcode: Int)
}

/// The next frame, pings skipped.
pub fn recv(socket: RawSocket) -> Frame {
  case raw_recv_frame(socket, timeout_ms) {
    Ok(#(1, payload)) -> {
      let assert Ok(text) = bit_array.to_string(payload)
        as "text frames carry UTF-8"
      Text(text)
    }
    Ok(#(8, <<code:16, reason:bits>>)) -> {
      let assert Ok(reason) = bit_array.to_string(reason)
        as "close reasons are UTF-8"
      Close(code:, reason:)
    }
    Ok(#(9, _ping)) -> recv(socket)
    Ok(#(opcode, _)) -> Other(opcode)
    Error(reason) -> panic as { "expected a frame: " <> reason }
  }
}

/// The next text frame; any other frame fails the test.
pub fn recv_text(socket: RawSocket) -> String {
  case recv(socket) {
    Text(text) -> text
    Close(code:, reason:) ->
      panic as {
        "expected a text frame, got close "
        <> int.to_string(code)
        <> " "
        <> reason
      }
    Other(opcode) ->
      panic as { "expected a text frame, got opcode " <> int.to_string(opcode) }
  }
}
