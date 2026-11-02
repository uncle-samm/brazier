/// WebSocket protocol layer (RFC 6455): handshake validation, a strict
/// frame parser, message reassembly, and server frame encoding.
///
/// Everything a client sends is validated before it reaches the transport:
/// masking (§5.1), RSV bits (§5.2), opcodes (§5.2), minimal length encoding
/// (§5.2), control frame rules (§5.5), fragmentation (§5.4), close payloads
/// (§5.5.1, §7.4) and UTF-8 (§8.1). Every violation maps to the close code
/// cowboy/cowlib use for it: 1002 protocol error, 1007 invalid payload,
/// 1009 message too big.
///
/// Reference: RFC 6455; cowlib cow_ws; cowboy_websocket.
import beacon/log
import beacon/transport/server
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/http
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// --- Close codes (RFC 6455 §7.4.1, IANA registry) ---

/// 1000: normal closure.
pub const close_normal = 1000

/// 1001: endpoint going away (server shutdown, liveness failure).
pub const close_going_away = 1001

/// 1002: protocol error.
pub const close_protocol_error = 1002

/// 1003: unsupported data type (Beacon only accepts text frames).
pub const close_unsupported_data = 1003

/// 1007: payload not consistent with the message type (invalid UTF-8).
pub const close_invalid_payload = 1007

/// 1008: policy violation (abuse, rate limits, failed origin checks).
pub const close_policy_violation = 1008

/// 1009: message too big.
pub const close_message_too_big = 1009

/// 1011: unexpected server condition.
pub const close_internal_error = 1011

/// 1013: try again later (server-side backpressure).
pub const close_try_again_later = 1013

/// 4401: application code — the session behind this socket is no longer
/// authenticated (logged out, rotated, expired or re-check failed).
/// Clients must not blindly reconnect on this code; they must re-authenticate.
pub const close_auth_revoked = 4401

/// Maximum close reason length: control payload limit 125 minus the code.
const max_close_reason_bytes = 123

// --- Frame parsing ---

/// A frame-level protocol violation detected from the frame header.
/// The Erlang shape of each constructor is produced by
/// `beacon_transport_ffi:ws_parse_frame/2` — keep them in sync.
pub type FrameError {
  /// RSV1-3 set although no extension was negotiated.
  ReservedBitsSet
  /// Opcode outside 0, 1, 2, 8, 9, 10.
  UnknownOpcode(opcode: Int)
  /// Control frame without FIN.
  FragmentedControlFrame
  /// Control frame payload above 125 bytes.
  ControlFrameTooLarge(length: Int)
  /// Client frame without the mask bit.
  UnmaskedFrame
  /// Extended payload length used for a length the shorter form can encode.
  NonMinimalLength
  /// Declared payload length above the configured limit.
  FrameTooLarge(length: Int)
}

/// Result of parsing one frame. Erlang shape produced by
/// `beacon_transport_ffi:ws_parse_frame/2`.
type ParseOutcome {
  Parsed(fin: Bool, opcode: Int, payload: BitArray, rest: BitArray)
  NeedMore
  ParseFailed(error: FrameError)
}

@external(erlang, "beacon_transport_ffi", "ws_parse_frame")
fn ffi_parse_frame(data: BitArray, max_payload: Int) -> ParseOutcome

@external(erlang, "beacon_transport_ffi", "ws_encode_frame")
fn ffi_encode_frame(opcode: Int, payload: BitArray) -> BitArray

@external(erlang, "beacon_transport_ffi", "ws_encode_close")
fn ffi_encode_close(code: Int, reason: String) -> BitArray

@external(erlang, "beacon_transport_ffi", "ws_is_valid_utf8")
fn ffi_is_valid_utf8(data: BitArray) -> Bool

@external(erlang, "beacon_transport_ffi", "ws_decode_key")
fn ffi_decode_key(key: String) -> Result(BitArray, Nil)

@external(erlang, "beacon_transport_ffi", "ws_accept_key")
fn ffi_ws_accept_key(client_key: String) -> String

/// A complete, validated client message.
pub type Message {
  /// A complete (possibly reassembled) text message, valid UTF-8.
  TextMessage(String)
  /// A complete (possibly reassembled) binary message.
  BinaryMessage(BitArray)
  /// Close request. `code` is None when the peer sent an empty close.
  CloseMessage(code: Option(Int), reason: String)
  /// Ping — must be answered with a pong carrying the same payload.
  PingMessage(BitArray)
  /// Pong — answer to a server ping (or unsolicited heartbeat).
  PongMessage(BitArray)
}

/// A protocol violation. Every variant maps to a close code via
/// `get_protocol_close_code`.
pub type ProtocolError {
  /// The frame header itself is invalid.
  BadFrame(FrameError)
  /// Continuation frame with no fragmented message in progress.
  UnexpectedContinuation
  /// New text/binary frame while a fragmented message is in progress.
  ExpectedContinuation
  /// The reassembled message exceeds the configured limit.
  MessageTooLarge(size: Int)
  /// Text message or close reason is not valid UTF-8.
  InvalidUtf8
  /// Close payload is malformed (1 byte, or a code that must not be sent).
  InvalidClosePayload(detail: String)
}

/// Kind of a fragmented data message in progress.
type DataKind {
  TextData
  BinaryData
}

/// Fragment reassembly state carried between reads.
pub opaque type Reassembly {
  Idle
  Assembling(kind: DataKind, parts: List(BitArray), size: Int)
}

/// One step of decoding the receive buffer.
pub type Step {
  /// A complete message was decoded; continue with `rest`.
  Complete(message: Message, rest: BitArray, reassembly: Reassembly)
  /// A non-final data fragment was consumed; continue with `rest`.
  Fragment(rest: BitArray, reassembly: Reassembly)
  /// The buffer does not contain a whole frame yet.
  Incomplete
}

/// Fresh reassembly state for a new connection.
pub fn create_reassembly() -> Reassembly {
  Idle
}

/// Whether a fragmented message is currently being reassembled.
pub fn is_reassembling(reassembly: Reassembly) -> Bool {
  case reassembly {
    Idle -> False
    Assembling(..) -> True
  }
}

/// Decode the next frame from `buffer`.
/// `max_message_bytes` bounds both a single frame and the reassembled
/// message. Frame headers declaring more are rejected before the payload is
/// buffered.
pub fn decode_next(
  buffer: BitArray,
  reassembly: Reassembly,
  max_message_bytes: Int,
) -> Result(Step, ProtocolError) {
  let assembled = case reassembly {
    Idle -> 0
    Assembling(size: size, ..) -> size
  }
  // Control frames (<= 125 bytes) may be interleaved with fragments, so the
  // parser limit never drops below the control-frame maximum. Data frames
  // are re-checked against the exact remaining budget below.
  let frame_limit = int.max(max_message_bytes - assembled, 125)
  case ffi_parse_frame(buffer, frame_limit) {
    NeedMore -> Ok(Incomplete)
    ParseFailed(error) -> Error(BadFrame(error))
    Parsed(fin: fin, opcode: opcode, payload: payload, rest: rest) ->
      decode_parsed(fin, opcode, payload, rest, reassembly, max_message_bytes)
  }
}

fn decode_parsed(
  fin: Bool,
  opcode: Int,
  payload: BitArray,
  rest: BitArray,
  reassembly: Reassembly,
  max_message_bytes: Int,
) -> Result(Step, ProtocolError) {
  case opcode, reassembly {
    8, _ ->
      case decode_close_payload(payload) {
        Ok(message) -> Ok(Complete(message, rest, reassembly))
        Error(error) -> Error(error)
      }
    9, _ -> Ok(Complete(PingMessage(payload), rest, reassembly))
    10, _ -> Ok(Complete(PongMessage(payload), rest, reassembly))
    0, Idle -> Error(UnexpectedContinuation)
    0, Assembling(kind: kind, parts: parts, size: size) ->
      append_fragment(kind, parts, size, payload, fin, rest, max_message_bytes)
    1, Idle ->
      append_fragment(TextData, [], 0, payload, fin, rest, max_message_bytes)
    2, Idle ->
      append_fragment(BinaryData, [], 0, payload, fin, rest, max_message_bytes)
    1, Assembling(..) | 2, Assembling(..) -> Error(ExpectedContinuation)
    // The FFI parser only yields the six opcodes above; anything else is a
    // parser bug and is reported as the protocol error it would be.
    other, _ -> Error(BadFrame(UnknownOpcode(other)))
  }
}

fn append_fragment(
  kind: DataKind,
  parts: List(BitArray),
  size: Int,
  payload: BitArray,
  fin: Bool,
  rest: BitArray,
  max_message_bytes: Int,
) -> Result(Step, ProtocolError) {
  let new_size = size + bit_array.byte_size(payload)
  case new_size > max_message_bytes {
    True -> Error(MessageTooLarge(new_size))
    False -> {
      let new_parts = [payload, ..parts]
      case fin {
        False ->
          Ok(Fragment(
            rest,
            Assembling(kind: kind, parts: new_parts, size: new_size),
          ))
        True -> {
          let data = bit_array.concat(list.reverse(new_parts))
          case kind {
            BinaryData -> Ok(Complete(BinaryMessage(data), rest, Idle))
            TextData ->
              case decode_utf8(data) {
                Ok(text) -> Ok(Complete(TextMessage(text), rest, Idle))
                Error(error) -> Error(error)
              }
          }
        }
      }
    }
  }
}

fn decode_utf8(data: BitArray) -> Result(String, ProtocolError) {
  case ffi_is_valid_utf8(data) {
    False -> Error(InvalidUtf8)
    True ->
      case bit_array.to_string(data) {
        Ok(text) -> Ok(text)
        Error(Nil) -> Error(InvalidUtf8)
      }
  }
}

/// Decode a close frame payload (§5.5.1).
fn decode_close_payload(payload: BitArray) -> Result(Message, ProtocolError) {
  case payload {
    <<>> -> Ok(CloseMessage(code: None, reason: ""))
    <<code:16, reason_bytes:bytes>> ->
      case is_valid_peer_close_code(code) {
        False ->
          Error(InvalidClosePayload("close code " <> int.to_string(code)))
        True ->
          case decode_utf8(reason_bytes) {
            Ok(reason) -> Ok(CloseMessage(code: Some(code), reason: reason))
            Error(error) -> Error(error)
          }
      }
    _ -> Error(InvalidClosePayload("one byte close payload"))
  }
}

/// Close codes a peer may legitimately send (§7.4.1, §7.4.2, IANA registry).
/// 1004-1006 and 1015 are reserved and must never appear on the wire.
pub fn is_valid_peer_close_code(code: Int) -> Bool {
  { code >= 1000 && code <= 1003 }
  || { code >= 1007 && code <= 1014 }
  || { code >= 3000 && code <= 4999 }
}

/// The close code to send for a protocol error (matches cowboy).
pub fn get_protocol_close_code(error: ProtocolError) -> Int {
  case error {
    BadFrame(FrameTooLarge(..)) -> close_message_too_big
    BadFrame(_) -> close_protocol_error
    UnexpectedContinuation -> close_protocol_error
    ExpectedContinuation -> close_protocol_error
    MessageTooLarge(..) -> close_message_too_big
    InvalidUtf8 -> close_invalid_payload
    InvalidClosePayload(..) -> close_protocol_error
  }
}

/// Human-readable description for logs (never sent to the peer).
pub fn get_protocol_error_reason(error: ProtocolError) -> String {
  case error {
    BadFrame(frame_error) -> frame_error_to_string(frame_error)
    UnexpectedContinuation -> "continuation frame without a message in progress"
    ExpectedContinuation -> "new data frame while a fragmented message is open"
    MessageTooLarge(size) ->
      "message too large (" <> int.to_string(size) <> " bytes)"
    InvalidUtf8 -> "invalid UTF-8"
    InvalidClosePayload(detail) -> "invalid close payload: " <> detail
  }
}

fn frame_error_to_string(error: FrameError) -> String {
  case error {
    ReservedBitsSet -> "reserved bits set"
    UnknownOpcode(opcode) -> "unknown opcode " <> int.to_string(opcode)
    FragmentedControlFrame -> "fragmented control frame"
    ControlFrameTooLarge(length) ->
      "control frame too large (" <> int.to_string(length) <> " bytes)"
    UnmaskedFrame -> "unmasked client frame"
    NonMinimalLength -> "non-minimal payload length encoding"
    FrameTooLarge(length) ->
      "frame too large (" <> int.to_string(length) <> " bytes)"
  }
}

// --- Server frame encoding ---

/// Encode a server text frame.
pub fn encode_text(text: String) -> BitArray {
  ffi_encode_frame(1, <<text:utf8>>)
}

/// Encode a server ping. Control payloads are at most 125 bytes (§5.5).
pub fn encode_ping(payload: BitArray) -> BitArray {
  let assert True = bit_array.byte_size(payload) <= 125
    as "ping payloads are internal and always <= 125 bytes"
  ffi_encode_frame(9, payload)
}

/// Encode a pong echoing a ping payload. The parser already rejected any
/// ping above 125 bytes, so the echoed payload always fits (§5.5.3).
pub fn encode_pong(payload: BitArray) -> BitArray {
  let assert True = bit_array.byte_size(payload) <= 125
    as "pong echoes a parsed ping, which the parser bounds to 125 bytes"
  ffi_encode_frame(10, payload)
}

/// Encode a close frame with a status code and short reason.
/// Reasons are internal ASCII constants; a reason longer than the control
/// frame budget is a programming error and crashes loudly.
pub fn encode_close(code: Int, reason: String) -> BitArray {
  let assert True = string.byte_size(reason) <= max_close_reason_bytes
    as "close reasons are short internal constants (<= 123 bytes)"
  let assert True = code >= 1000 && code <= 4999
    as "close codes sent by Beacon are registered or application codes"
  ffi_encode_close(code, reason)
}

/// Encode an empty close frame (reply to a peer close that carried no code).
pub fn encode_empty_close() -> BitArray {
  ffi_encode_frame(8, <<>>)
}

// --- Handshake (RFC 6455 §4.2.1) ---

/// Why an upgrade request was rejected.
pub type UpgradeError {
  /// Method is not GET.
  NotGetMethod(method: String)
  /// No Upgrade header.
  MissingUpgradeHeader
  /// Upgrade header does not contain the `websocket` token.
  InvalidUpgradeHeader(value: String)
  /// Connection header missing or without the `upgrade` token.
  MissingConnectionUpgrade
  /// Sec-WebSocket-Version missing or not 13.
  UnsupportedVersion(value: String)
  /// No Sec-WebSocket-Key header.
  MissingKey
  /// Sec-WebSocket-Key is not base64 of 16 bytes.
  InvalidKey
}

/// HTTP status for a rejected upgrade: 426 for an unsupported version (the
/// response must carry `Sec-WebSocket-Version: 13`), 400 otherwise.
pub fn get_upgrade_error_status(error: UpgradeError) -> Int {
  case error {
    UnsupportedVersion(..) -> 426
    _ -> 400
  }
}

/// Description for logs and the rejection body.
pub fn get_upgrade_error_reason(error: UpgradeError) -> String {
  case error {
    NotGetMethod(method) -> "WebSocket upgrade requires GET, got " <> method
    MissingUpgradeHeader -> "Missing Upgrade header"
    InvalidUpgradeHeader(value) -> "Invalid Upgrade header: " <> value
    MissingConnectionUpgrade -> "Connection header lacks the upgrade token"
    UnsupportedVersion(value) ->
      "Unsupported Sec-WebSocket-Version: \"" <> value <> "\" (need 13)"
    MissingKey -> "Missing Sec-WebSocket-Key header"
    InvalidKey -> "Sec-WebSocket-Key is not base64 of 16 bytes"
  }
}

/// Validate an upgrade request. Returns the client key on success.
pub fn validate_upgrade(req: Request(a)) -> Result(String, UpgradeError) {
  let outcome = check_upgrade(req)
  case outcome {
    Ok(_key) -> log.debug("beacon.ws", "Upgrade request headers valid")
    // The caller logs the rejection at warning level with the peer context.
    Error(error) ->
      log.debug(
        "beacon.ws",
        "Upgrade request invalid: " <> get_upgrade_error_reason(error),
      )
  }
  outcome
}

fn check_upgrade(req: Request(a)) -> Result(String, UpgradeError) {
  use _ <- result.try(case req.method {
    http.Get -> Ok(Nil)
    other -> Error(NotGetMethod(http.method_to_string(other)))
  })
  use _ <- result.try(case request.get_header(req, "upgrade") {
    Error(Nil) -> Error(MissingUpgradeHeader)
    Ok(value) ->
      case has_token(value, "websocket") {
        True -> Ok(Nil)
        False -> Error(InvalidUpgradeHeader(value))
      }
  })
  use _ <- result.try(case request.get_header(req, "connection") {
    Ok(value) ->
      case has_token(value, "upgrade") {
        True -> Ok(Nil)
        False -> Error(MissingConnectionUpgrade)
      }
    Error(Nil) -> Error(MissingConnectionUpgrade)
  })
  use _ <- result.try(case request.get_header(req, "sec-websocket-version") {
    Ok(value) ->
      case string.trim(value) {
        "13" -> Ok(Nil)
        _ -> Error(UnsupportedVersion(value))
      }
    Error(Nil) -> Error(UnsupportedVersion(""))
  })
  case request.get_header(req, "sec-websocket-key") {
    Error(Nil) -> Error(MissingKey)
    Ok(raw_key) -> {
      let key = string.trim(raw_key)
      case string.byte_size(key) == 24, ffi_decode_key(key) {
        True, Ok(decoded) ->
          case bit_array.byte_size(decoded) == 16 {
            True -> Ok(key)
            False -> Error(InvalidKey)
          }
        _, _ -> Error(InvalidKey)
      }
    }
  }
}

/// Whether a comma-separated header value contains `token`
/// (case-insensitive, RFC 7230 §3.2.6 token list).
fn has_token(value: String, token: String) -> Bool {
  string.split(value, ",")
  |> list.any(fn(part) { string.lowercase(string.trim(part)) == token })
}

/// Encode the 101 Switching Protocols response for a validated client key.
pub fn encode_upgrade_response(client_key: String) -> BitArray {
  let accept_key = ffi_ws_accept_key(client_key)
  <<
    "HTTP/1.1 101 Switching Protocols\r\n":utf8,
    "Upgrade: websocket\r\n":utf8,
    "Connection: Upgrade\r\n":utf8,
    "Sec-WebSocket-Accept: ":utf8,
    accept_key:utf8,
    "\r\n\r\n":utf8,
  >>
}

/// Send the 101 response for a validated client key.
pub fn send_upgrade_response(
  socket: server.Socket,
  client_key: String,
) -> Result(Nil, String) {
  case server.send_bytes(socket, encode_upgrade_response(client_key)) {
    Ok(Nil) -> {
      log.debug("beacon.ws", "WebSocket upgrade complete")
      Ok(Nil)
    }
    Error(reason) -> {
      log.warning("beacon.ws", "Failed to send upgrade response: " <> reason)
      Error("Failed to send upgrade: " <> reason)
    }
  }
}

// --- Socket helpers ---

/// Raw (non-Subject) messages a WebSocket handler process can receive.
/// Erlang shape produced by `beacon_transport_ffi:ws_classify_message/1`.
pub type SocketEvent {
  SocketData(data: BitArray)
  SocketClosed
  SocketError(reason: String)
  /// The session this socket is bound to was deleted, rotated or expired.
  SessionRevoked(session_id: String, reason: String)
  /// Anything else — a framework bug; the handler closes with 1011.
  UnexpectedMessage(description: String)
}

@external(erlang, "beacon_transport_ffi", "ws_classify_message")
pub fn decode_socket_event(raw: Dynamic) -> SocketEvent

@external(erlang, "beacon_transport_ffi", "ws_set_send_timeout")
fn ffi_set_send_timeout(
  socket: server.Socket,
  timeout_ms: Int,
) -> Result(Nil, String)

/// Bound blocking sends: a send that cannot complete within `timeout_ms`
/// fails and the VM closes the socket (`send_timeout_close`).
pub fn set_send_timeout(
  socket: server.Socket,
  timeout_ms: Int,
) -> Result(Nil, String) {
  case ffi_set_send_timeout(socket, timeout_ms) {
    Ok(Nil) -> {
      log.debug(
        "beacon.ws",
        "Send timeout set to " <> int.to_string(timeout_ms) <> "ms",
      )
      Ok(Nil)
    }
    Error(reason) -> {
      log.warning("beacon.ws", "Failed to set send timeout: " <> reason)
      Error(reason)
    }
  }
}

@external(erlang, "beacon_transport_ffi", "ws_peer_ip")
fn ffi_peer_ip(socket: server.Socket) -> Result(String, String)

/// The peer IP address as text.
pub fn peer_ip(socket: server.Socket) -> Result(String, String) {
  case ffi_peer_ip(socket) {
    Ok(ip) -> Ok(ip)
    Error(reason) -> {
      log.warning("beacon.ws", "Failed to read peer address: " <> reason)
      Error(reason)
    }
  }
}

@external(erlang, "beacon_transport_ffi", "ws_acquire_ip_slot")
fn ffi_acquire_ip_slot(ip: String, max: Int) -> Result(Int, Int)

/// Take one per-IP WebSocket slot for the calling process.
/// Ok(count) on success; Error(count) when the IP already holds `max`.
/// The slot is released automatically when the calling process exits.
pub fn acquire_ip_slot(ip: String, max: Int) -> Result(Int, Int) {
  let assert True = max > 0 as "max_ws_connections_per_ip is validated > 0"
  case ffi_acquire_ip_slot(ip, max) {
    Ok(count) -> {
      log.debug(
        "beacon.ws",
        "WebSocket slot taken for "
          <> ip
          <> " ("
          <> int.to_string(count)
          <> "/"
          <> int.to_string(max)
          <> ")",
      )
      Ok(count)
    }
    Error(count) -> {
      log.warning(
        "beacon.ws",
        "Per-IP WebSocket cap reached for "
          <> ip
          <> " ("
          <> int.to_string(count)
          <> "/"
          <> int.to_string(max)
          <> ")",
      )
      Error(count)
    }
  }
}

@external(erlang, "beacon_transport_ffi", "ws_ip_slot_count")
fn ffi_ip_slot_count(ip: String) -> Int

/// Number of live WebSocket handlers holding a slot for `ip`.
pub fn get_ip_slot_count(ip: String) -> Int {
  ffi_ip_slot_count(ip)
}

@external(erlang, "beacon_transport_ffi", "ws_mailbox_len")
fn ffi_mailbox_len() -> Int

/// Number of messages waiting in the calling process's mailbox.
pub fn get_mailbox_len() -> Int {
  ffi_mailbox_len()
}

@external(erlang, "beacon_transport_ffi", "ws_release_ip_slot")
fn ffi_release_ip_slot(ip: String) -> Bool

/// Release the calling process's per-IP slot. Idempotent; logs whether a
/// slot was actually held so double releases are visible in debug logs.
pub fn release_ip_slot(ip: String) -> Nil {
  case ffi_release_ip_slot(ip) {
    True -> log.debug("beacon.ws", "WebSocket slot released for " <> ip)
    False ->
      log.debug("beacon.ws", "WebSocket slot for " <> ip <> " already released")
  }
}

@external(erlang, "beacon_transport_ffi", "ws_now_ms")
fn ffi_now_ms() -> Int

/// Monotonic time in milliseconds, for liveness bookkeeping.
pub fn get_now_ms() -> Int {
  ffi_now_ms()
}
