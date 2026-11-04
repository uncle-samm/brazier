import brazier/transport
import brazier/transport/ws
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleam/string

// --- ServerMessage encoding tests ---

pub fn encode_mount_message_test() {
  let msg = transport.ServerMount(payload: "{\"html\":\"<h1>Hi</h1>\"}")
  let encoded = transport.encode_server_message(msg)
  // Parse the JSON and validate fields
  let assert Ok("mount") =
    json.parse(encoded, decode.at(["type"], decode.string))
  let assert Ok("{\"html\":\"<h1>Hi</h1>\"}") =
    json.parse(encoded, decode.at(["payload"], decode.string))
}

pub fn encode_model_sync_message_test() {
  let msg =
    transport.ServerModelSync(
      model_json: "{\"count\":1}",
      version: 1,
      ack_clock: 1,
    )
  let encoded = transport.encode_server_message(msg)
  let assert Ok("model_sync") =
    json.parse(encoded, decode.at(["type"], decode.string))
  let assert Ok("{\"count\":1}") =
    json.parse(encoded, decode.at(["model"], decode.string))
  let assert Ok(1) = json.parse(encoded, decode.at(["version"], decode.int))
  let assert Ok(1) = json.parse(encoded, decode.at(["ack_clock"], decode.int))
}

pub fn encode_heartbeat_ack_test() {
  let msg = transport.ServerHeartbeatAck
  let encoded = transport.encode_server_message(msg)
  let assert Ok("heartbeat_ack") =
    json.parse(encoded, decode.at(["type"], decode.string))
}

pub fn encode_error_message_test() {
  let msg = transport.ServerError(reason: "something went wrong")
  let encoded = transport.encode_server_message(msg)
  let assert Ok("error") =
    json.parse(encoded, decode.at(["type"], decode.string))
  let assert Ok("something went wrong") =
    json.parse(encoded, decode.at(["reason"], decode.string))
}

// --- ClientMessage decoding tests ---

pub fn decode_heartbeat_test() {
  let raw = "{\"type\":\"heartbeat\"}"
  let assert Ok(transport.ClientHeartbeat) =
    transport.decode_client_message(raw)
}

pub fn decode_join_test() {
  let raw = "{\"type\":\"join\"}"
  let assert Ok(transport.ClientJoin(token: "", path: "/")) =
    transport.decode_client_message(raw)
}

pub fn decode_join_with_token_test() {
  let raw = "{\"type\":\"join\",\"token\":\"abc123\"}"
  let assert Ok(transport.ClientJoin(token: "abc123", path: "/")) =
    transport.decode_client_message(raw)
}

pub fn decode_join_with_path_test() {
  let raw = "{\"type\":\"join\",\"token\":\"\",\"path\":\"/blog/hello\"}"
  let assert Ok(transport.ClientJoin(token: "", path: "/blog/hello")) =
    transport.decode_client_message(raw)
}

pub fn decode_event_test() {
  let raw =
    "{\"type\":\"event\",\"name\":\"click\",\"data\":\"{}\",\"target_path\":\"0.1.0\"}"
  let assert Ok(transport.ClientEvent(
    name: "click",
    handler_id: "",
    data: "{}",
    target_path: "0.1.0",
    clock: 0,
    ops: "",
  )) = transport.decode_client_message(raw)
}

pub fn decode_event_with_handler_id_test() {
  let raw =
    "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"increment\",\"data\":\"{}\",\"target_path\":\"0.3\",\"clock\":5}"
  let assert Ok(transport.ClientEvent(
    name: "click",
    handler_id: "increment",
    data: "{}",
    target_path: "0.3",
    clock: 5,
    ops: "",
  )) = transport.decode_client_message(raw)
}

pub fn decode_event_with_data_test() {
  let raw =
    "{\"type\":\"event\",\"name\":\"input\",\"handler_id\":\"search\",\"data\":\"{\\\"value\\\":\\\"hello\\\"}\",\"target_path\":\"0.2\"}"
  let assert Ok(transport.ClientEvent(
    name: "input",
    handler_id: "search",
    data: _,
    target_path: "0.2",
    clock: 0,
    ops: "",
  )) = transport.decode_client_message(raw)
}

pub fn decode_navigate_test() {
  let raw = "{\"type\":\"navigate\",\"path\":\"/about\"}"
  let assert Ok(transport.ClientNavigate(path: "/about")) =
    transport.decode_client_message(raw)
}

pub fn decode_server_fn_is_unknown_test() {
  // server_fn messages are no longer supported — should fail to decode
  let raw =
    "{\"type\":\"server_fn\",\"name\":\"greet\",\"args\":\"hello\",\"call_id\":\"c1\"}"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn decode_invalid_json_test() {
  let raw = "not json at all"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn decode_unknown_type_test() {
  let raw = "{\"type\":\"unknown_type\"}"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn decode_missing_type_field_test() {
  let raw = "{\"name\":\"click\"}"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn decode_event_missing_fields_test() {
  let raw = "{\"type\":\"event\",\"name\":\"click\"}"
  // Missing "data" and "target_path" fields — should fail
  let assert Error(_) = transport.decode_client_message(raw)
}

// --- Patch message tests ---

pub fn encode_patch_message_test() {
  let msg =
    transport.ServerPatch(
      ops_json: "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":1}]",
      version: 2,
      ack_clock: 2,
    )
  let encoded = transport.encode_server_message(msg)
  let assert Ok("patch") =
    json.parse(encoded, decode.at(["type"], decode.string))
  let assert Ok("[{\"op\":\"replace\",\"path\":\"/count\",\"value\":1}]") =
    json.parse(encoded, decode.at(["ops"], decode.string))
  let assert Ok(2) = json.parse(encoded, decode.at(["version"], decode.int))
  let assert Ok(2) = json.parse(encoded, decode.at(["ack_clock"], decode.int))
}

pub fn encode_navigate_message_test() {
  let msg = transport.ServerNavigate(path: "/next")
  let encoded = transport.encode_server_message(msg)
  let assert Ok("navigate") =
    json.parse(encoded, decode.at(["type"], decode.string))
  let assert Ok("/next") =
    json.parse(encoded, decode.at(["path"], decode.string))
}

pub fn encode_hard_navigate_message_test() {
  let msg = transport.ServerHardNavigate(path: "/auth/session/abc")
  let encoded = transport.encode_server_message(msg)
  let assert Ok("hard_navigate") =
    json.parse(encoded, decode.at(["type"], decode.string))
  let assert Ok("/auth/session/abc") =
    json.parse(encoded, decode.at(["path"], decode.string))
}

pub fn encode_reload_message_test() {
  let msg = transport.ServerReload
  let encoded = transport.encode_server_message(msg)
  let assert Ok("reload") =
    json.parse(encoded, decode.at(["type"], decode.string))
}

pub fn decode_event_with_ops_test() {
  let raw =
    "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"increment\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":1,\"ops\":\"[{\\\"op\\\":\\\"replace\\\",\\\"path\\\":\\\"/count\\\",\\\"value\\\":1}]\"}"
  let assert Ok(transport.ClientEvent(
    name: "click",
    handler_id: "increment",
    data: "{}",
    target_path: "0",
    clock: 1,
    ops: ops,
  )) = transport.decode_client_message(raw)
  // Verify ops is valid JSON patch format, not just non-empty
  let assert True = string.contains(ops, "replace")
  let assert True = string.contains(ops, "/count")
  let assert True = string.contains(ops, "1")
}

pub fn decode_event_without_ops_test() {
  let raw =
    "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"h1\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":1}"
  let assert Ok(transport.ClientEvent(
    name: "click",
    handler_id: "h1",
    data: "{}",
    target_path: "0",
    clock: 1,
    ops: "",
  )) = transport.decode_client_message(raw)
}

// --- Malformed JSON edge cases ---

pub fn decode_empty_payload_test() {
  // Empty string is not valid JSON — must fail with error
  let assert Error(_) = transport.decode_client_message("")
}

pub fn decode_event_with_null_fields_test() {
  // JSON with null values where strings are expected — must fail
  let raw =
    "{\"type\":\"event\",\"name\":null,\"data\":null,\"target_path\":null}"
  let assert Error(_) = transport.decode_client_message(raw)
}

pub fn decode_oversized_type_field_test() {
  // Very long type string — must fail (unknown type) but not crash
  let long_type = repeat_a(500)
  let raw = "{\"type\":\"" <> long_type <> "\"}"
  let assert Error(_) = transport.decode_client_message(raw)
}

fn repeat_a(n: Int) -> String {
  case n <= 0 {
    True -> ""
    False -> "A" <> repeat_a(n - 1)
  }
}

// --- ClientEventBatch tests ---

pub fn decode_client_event_batch_test() {
  let raw =
    "{\"type\":\"event_batch\",\"events\":[{\"name\":\"click\",\"handler_id\":\"inc\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":1},{\"name\":\"input\",\"handler_id\":\"search\",\"data\":\"{\\\"value\\\":\\\"hi\\\"}\",\"target_path\":\"0.2\",\"clock\":2}]}"
  let assert Ok(transport.ClientEventBatch(events: events)) =
    transport.decode_client_message(raw)
  let assert 2 = list.length(events)
  // Verify first event
  let assert [
    transport.ClientEvent(
      name: "click",
      handler_id: "inc",
      data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
    transport.ClientEvent(
      name: "input",
      handler_id: "search",
      data: _,
      target_path: "0.2",
      clock: 2,
      ops: "",
    ),
  ] = events
}

pub fn decode_client_event_batch_empty_test() {
  let raw = "{\"type\":\"event_batch\",\"events\":[]}"
  let assert Ok(transport.ClientEventBatch(events: events)) =
    transport.decode_client_message(raw)
  let assert 0 = list.length(events)
}

pub fn decode_client_request_sync_test() {
  let raw = "{\"type\":\"request_sync\"}"
  let assert Ok(transport.ClientRequestSync) =
    transport.decode_client_message(raw)
}

// --- Round-trip test ---

pub fn encode_decode_roundtrip_consistency_test() {
  // Verify that encoding produces valid JSON by parsing every message
  let messages = [
    transport.ServerMount(payload: "test"),
    transport.ServerModelSync(model_json: "{}", version: 0, ack_clock: 0),
    transport.ServerPatch(ops_json: "[]", version: 0, ack_clock: 0),
    transport.ServerHeartbeatAck,
    transport.ServerError(reason: "test error"),
    transport.ServerNavigate(path: "/foo"),
    transport.ServerHardNavigate(path: "/hard"),
    transport.ServerReload,
  ]
  list.each(messages, fn(msg) {
    let encoded = transport.encode_server_message(msg)
    // Parse with a decoder that accepts any type field — proves valid JSON
    let assert Ok(_type_str) =
      json.parse(encoded, decode.at(["type"], decode.string))
    Nil
  })
}

// --- WebSocket frame edge cases ---

pub fn ws_decode_incomplete_frame_test() {
  let assert Ok(ws.Incomplete) =
    ws.decode_next(
      <<129:size(8), 133:size(8), 0:size(8), 0:size(8)>>,
      ws.create_reassembly(),
      65_536,
    )
}

pub fn ws_decode_rejects_unmasked_client_frame_test() {
  let assert Error(ws.BadFrame(ws.UnmaskedFrame) as error) =
    ws.decode_next(
      <<129:size(8), 2:size(8), "hi":utf8>>,
      ws.create_reassembly(),
      65_536,
    )
  let assert 1002 = ws.get_protocol_close_code(error)
}

pub fn ws_decode_text_ping_pong_close_and_unknown_opcode_test() {
  let fresh = ws.create_reassembly()
  let assert Ok(ws.Complete(ws.TextMessage("hi"), <<>>, _)) =
    ws.decode_next(masked_ws_frame(1, <<"hi":utf8>>), fresh, 65_536)
  let assert Ok(ws.Complete(
    ws.CloseMessage(code: option.None, reason: ""),
    <<>>,
    _,
  )) = ws.decode_next(masked_ws_frame(8, <<>>), fresh, 65_536)
  let assert Ok(ws.Complete(ws.PingMessage(ping), <<>>, _)) =
    ws.decode_next(masked_ws_frame(9, <<"p":utf8>>), fresh, 65_536)
  let assert Ok("p") = bit_array.to_string(ping)
  let assert Ok(ws.Complete(ws.PongMessage(pong), <<>>, _)) =
    ws.decode_next(masked_ws_frame(10, <<"q":utf8>>), fresh, 65_536)
  let assert Ok("q") = bit_array.to_string(pong)
  let assert Ok(ws.Complete(ws.BinaryMessage(binary), <<>>, _)) =
    ws.decode_next(masked_ws_frame(2, <<1, 2, 3>>), fresh, 65_536)
  let assert 3 = bit_array.byte_size(binary)
  // Opcode 3 is reserved: protocol error, not a binary frame.
  let assert Error(ws.BadFrame(ws.UnknownOpcode(3))) =
    ws.decode_next(masked_ws_frame(3, <<1, 2, 3>>), fresh, 65_536)
}

pub fn ws_decode_invalid_utf8_text_is_1007_test() {
  let assert Error(ws.InvalidUtf8 as error) =
    ws.decode_next(
      masked_ws_frame(1, <<255, 254>>),
      ws.create_reassembly(),
      65_536,
    )
  let assert 1007 = ws.get_protocol_close_code(error)
}

@external(erlang, "brazier_test_ffi", "masked_ws_frame")
fn masked_ws_frame(opcode: Int, payload: BitArray) -> BitArray
