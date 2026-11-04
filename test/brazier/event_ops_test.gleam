//// An event's `ops` is a JSON array embedded raw (`"ops":[...]`), as the
//// server already embeds a patch's ops and a model_sync's model (PERF-6).
//// The server decodes it strictly, op by op (RFC 6902 §4, RFC 6901 JSON
//// Pointers), and refuses an event whose ops are malformed with the
//// `error` frame `"Invalid event ops"` and a warning; it never applies
//// client ops, since its own `update` is authoritative. The old wire form,
//// a string holding the array, is refused like any other malformed ops.

import brazier/cluster/log_capture
import brazier/raw_ws
import brazier/transport
import brazier/transport/server
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- Decoding ---

fn event_with_ops(ops: String) -> String {
  "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"h\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":1,\"ops\":"
  <> ops
  <> "}"
}

fn decoded_ops(ops: String) -> List(transport.ClientOp) {
  let assert Ok(transport.ClientEvent(ops: decoded, ..)) =
    transport.decode_client_message(event_with_ops(ops))
    as { "ops must decode: " <> ops }
  decoded
}

/// The refusal of an event with `ops`: its reason, which must name ops.
fn refused_ops(ops: String) -> String {
  let assert Error(error) = transport.decode_client_message(event_with_ops(ops))
    as { "ops must be refused: " <> ops }
  let reason = string.inspect(error)
  let assert True = string.contains(reason, "Invalid event ops: ")
    as { "refused as invalid ops: " <> ops <> " -> " <> reason }
  reason
}

pub fn every_op_kind_decodes_test() {
  let assert [
    transport.ClientOp(
      op: "add",
      path: "/items/0",
      from: None,
      value: Some(add),
    ),
    transport.ClientOp(op: "remove", path: "/old", from: None, value: None),
    transport.ClientOp(op: "replace", path: "", from: None, value: Some(_)),
    transport.ClientOp(op: "move", path: "/b", from: Some("/a"), value: None),
    transport.ClientOp(
      op: "copy",
      path: "/c",
      from: Some("/a~1b~0c"),
      value: None,
    ),
    transport.ClientOp(
      op: "test",
      path: "/n",
      from: None,
      value: Some(test_value),
    ),
    transport.ClientOp(
      op: "append",
      path: "/log",
      from: None,
      value: Some(items),
    ),
  ] =
    decoded_ops(
      "[{\"op\":\"add\",\"path\":\"/items/0\",\"value\":{\"id\":1}},"
      <> "{\"op\":\"remove\",\"path\":\"/old\"},"
      <> "{\"op\":\"replace\",\"path\":\"\",\"value\":{}},"
      <> "{\"op\":\"move\",\"path\":\"/b\",\"from\":\"/a\"},"
      <> "{\"op\":\"copy\",\"path\":\"/c\",\"from\":\"/a~1b~0c\"},"
      <> "{\"op\":\"test\",\"path\":\"/n\",\"value\":null},"
      <> "{\"op\":\"append\",\"path\":\"/log\",\"value\":[1,2]}]",
    )
  let assert Ok(1) = decode.run(add, decode.at(["id"], decode.int))
  let assert Ok(None) = decode.run(test_value, decode.optional(decode.int))
  let assert Ok([1, 2]) = decode.run(items, decode.list(decode.int))
}

pub fn members_an_op_does_not_define_are_ignored_test() {
  // RFC 6902 §4: members not defined for the operation are ignored.
  let assert [
    transport.ClientOp(op: "remove", path: "/x", from: None, value: None),
  ] =
    decoded_ops(
      "[{\"op\":\"remove\",\"path\":\"/x\",\"value\":1,\"extra\":true}]",
    )
}

pub fn absent_and_empty_ops_are_no_ops_test() {
  let assert Ok(transport.ClientEvent(ops: [], ..)) =
    transport.decode_client_message(
      "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"h\",\"data\":\"{}\",\"target_path\":\"0\"}",
    )
  let assert [] = decoded_ops("[]")
}

pub fn the_old_string_form_is_refused_test() {
  // Before this change the client sent the array as JSON text.
  let reason =
    refused_ops(
      "\"[{\\\"op\\\":\\\"replace\\\",\\\"path\\\":\\\"/count\\\",\\\"value\\\":1}]\"",
    )
  let assert True = string.contains(reason, "ops: expected List, found String")
    as reason
}

pub fn malformed_ops_are_refused_test() {
  list.each(
    [
      #("null", "ops: expected List, found Nil"),
      #("{}", "ops: expected List, found Dict"),
      #("[1]", "ops.0: expected Dict, found Int"),
      #("[{\"path\":\"/x\"}]", "ops.0.op: expected Field"),
      #("[{\"op\":\"drop\",\"path\":\"/x\"}]", "an op of add, remove"),
      #("[{\"op\":\"remove\"}]", "ops.0.path: expected Field"),
      #("[{\"op\":\"remove\",\"path\":7}]", "ops.0.path: expected String"),
      #("[{\"op\":\"remove\",\"path\":\"x\"}]", "does not start with /"),
      #("[{\"op\":\"remove\",\"path\":\"/a~2\"}]", "~ not followed by 0 or 1"),
      #("[{\"op\":\"remove\",\"path\":\"/a~\"}]", "~ not followed by 0 or 1"),
      #(
        "[{\"op\":\"add\",\"path\":\"/__proto__/x\",\"value\":1}]",
        "passes through an unsafe key",
      ),
      #("[{\"op\":\"move\",\"path\":\"/b\"}]", "ops.0.from: expected Field"),
      #(
        "[{\"op\":\"copy\",\"path\":\"/b\",\"from\":\"a\"}]",
        "does not start with /",
      ),
      #("[{\"op\":\"add\",\"path\":\"/b\"}]", "ops.0.value: expected Field"),
      #("[{\"op\":\"replace\",\"path\":\"/b\"}]", "ops.0.value: expected Field"),
      #(
        "[{\"op\":\"append\",\"path\":\"/b\",\"value\":1}]",
        "ops.0.value: expected List, found Int",
      ),
      // A bad op after a good one still refuses the whole event (RFC 6902
      // §5: the patch is an error as a whole).
      #(
        "[{\"op\":\"remove\",\"path\":\"/a\"},{\"op\":\"remove\",\"path\":\"b\"}]",
        "ops.1.path",
      ),
    ],
    fn(case_) {
      let #(ops, fragment) = case_
      let reason = refused_ops(ops)
      let assert True = string.contains(reason, fragment)
        as { ops <> " -> " <> reason }
    },
  )
}

pub fn bad_ops_in_a_batch_are_refused_test() {
  let assert Error(error) =
    transport.decode_client_message(
      "{\"type\":\"event_batch\",\"events\":["
      <> "{\"name\":\"click\",\"handler_id\":\"a\",\"data\":\"{}\",\"ops\":[]},"
      <> "{\"name\":\"click\",\"handler_id\":\"b\",\"data\":\"{}\",\"ops\":\"[]\"}]}",
    )
  let reason = string.inspect(error)
  let assert True =
    string.contains(reason, "Invalid event ops: events.1.ops: expected List")
    as reason
}

pub fn ops_errors_mixed_with_others_are_an_invalid_message_test() {
  // `data` is missing as well: the frame is not an event at all, so the
  // client is not told only about its ops.
  let assert Error(error) =
    transport.decode_client_message(
      "{\"type\":\"event\",\"name\":\"click\",\"target_path\":\"0\",\"ops\":7}",
    )
  let reason = string.inspect(error)
  let assert True = string.contains(reason, "Failed to decode client message")
    as reason
  let assert False = string.contains(reason, "Invalid event ops") as reason
}

// --- Over a socket ---

type Observed {
  Connected(conn_id: String)
  GotEvent(msg: transport.ClientMessage)
}

fn start_server(
  limits: transport.SecurityLimits,
) -> #(server.Listener, Int, Subject(Observed)) {
  let observer = process.new_subject()
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: Some(fn(conn_id, _runtime, _req) {
        process.send(observer, Connected(conn_id))
        Ok(
          #(fn(_, msg) { process.send(observer, GotEvent(msg)) }, fn(_) { Nil }),
        )
      }),
      ws_auth: None,
      ssr_factory: None,
      security_limits: limits,
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "the test listener must start"
  #(listener, server.get_port(listener), observer)
}

fn open(port: Int, observer: Subject(Observed)) -> #(raw_ws.RawSocket, String) {
  let socket = raw_ws.open(port, "%2F", [])
  let assert Ok(Connected(conn_id)) = process.receive(observer, 3000)
    as "the runtime factory must be called"
  #(socket, conn_id)
}

pub fn malformed_ops_get_an_error_frame_and_one_warning_test() {
  let #(listener, port, observer) =
    start_server(transport.default_security_limits())
  let #(socket, conn_id) = open(port, observer)
  let #(reply, lines) =
    log_capture.capture(fn() {
      raw_ws.send_text(socket, event_with_ops("\"[]\""))
      raw_ws.recv_text(socket)
    })
  let assert "{\"type\":\"error\",\"reason\":\"Invalid event ops\"}" = reply
  let assert [line] =
    list.filter(lines, fn(line) {
      line.level == "warning" && string.contains(line.message, "invalid ops")
    })
    as "exactly one warning reports the refused ops"
  let assert True =
    string.contains(line.message, conn_id)
    && string.contains(line.message, "ops: expected List, found String")
    as line.message
  // The refused event never reached the runtime; the next one does, with
  // its ops decoded.
  raw_ws.send_text(
    socket,
    event_with_ops("[{\"op\":\"replace\",\"path\":\"/count\",\"value\":2}]"),
  )
  let assert Ok(GotEvent(transport.ClientEvent(
    ops: [transport.ClientOp(op: "replace", path: "/count", ..)],
    ..,
  ))) = process.receive(observer, 3000)
    as "the valid event is dispatched"
  raw_ws.close(socket)
  server.stop(listener)
}

pub fn a_flood_of_malformed_ops_closes_with_1008_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      ws_max_decode_errors: 2,
    )
  let #(listener, port, observer) = start_server(limits)
  let #(socket, _conn_id) = open(port, observer)
  raw_ws.send_text(socket, event_with_ops("{}"))
  let assert "{\"type\":\"error\",\"reason\":\"Invalid event ops\"}" =
    raw_ws.recv_text(socket)
  raw_ws.send_text(socket, event_with_ops("[1]"))
  let assert "{\"type\":\"error\",\"reason\":\"Invalid event ops\"}" =
    raw_ws.recv_text(socket)
  raw_ws.send_text(socket, event_with_ops("null"))
  let assert Ok(1008) = raw_ws.expect_closed(socket, 3000)
    as "the third malformed event exceeds ws_max_decode_errors"
  let assert Error(Nil) = process.receive(observer, 0)
    as "no malformed event was dispatched"
  raw_ws.close(socket)
  server.stop(listener)
}
