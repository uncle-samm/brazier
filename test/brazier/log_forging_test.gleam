//// SEC-11: client text in transport and router logs is quoted
//// (`string.inspect`), so a newline cannot forge a second log line, and
//// paths lose their query (`log_path.describe`), so a `?token=` never
//// reaches a log.

import brazier/effect
import brazier/log_capture
import brazier/router
import brazier/transport
import gleam/list
import gleam/string

fn no_raw_newline(logs: List(log_capture.Captured)) -> Bool {
  !list.any(logs, fn(event) { string.contains(event.message, "\n") })
}

fn no_secret(logs: List(log_capture.Captured)) -> Bool {
  !list.any(logs, fn(event) { string.contains(event.message, "s3cr3t") })
}

pub fn navigate_message_type_is_quoted_without_its_query_test() {
  let assert "navigate:\"/a\\nINFO forged\"" =
    transport.get_client_message_type(transport.ClientNavigate(
      path: "/a\nINFO forged?token=s3cr3t",
    ))
}

pub fn event_message_type_is_quoted_test() {
  let assert "event:\"click\\nINFO forged\"" =
    transport.get_client_message_type(transport.ClientEvent(
      name: "click\nINFO forged",
      handler_id: "h",
      data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ))
}

pub fn rejected_origin_log_quotes_client_text_test() {
  let assert Ok(none) = transport.parse_allowed_origins([])
    as "an empty origin list always parses"
  let #(_, logs) =
    log_capture.capture(fn() {
      // Each origin fails in a different parser branch that repeats it.
      let assert Error(_) =
        transport.origin_allowed(
          "http://evil.example\nINFO forged",
          "http",
          "localhost",
          none,
        )
      let assert Error(_) =
        transport.origin_allowed("http://h:1\nX", "http", "localhost", none)
      let assert Error(_) =
        transport.origin_allowed("ftp\nX://h", "http", "localhost", none)
      let assert Error(_) =
        transport.origin_allowed(
          "http://other.example",
          "http",
          "localhost\nINFO forged",
          none,
        )
      Nil
    })
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "Origin rejected", "origin=\"http://evil.example\\nINFO forged\"",
    ])
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "invalid port \"1\\nX\"",
    ])
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "unsupported scheme \"ftp\\nx\"",
    ])
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "host=\"localhost\\nINFO forged\"",
    ])
  let assert True = no_raw_newline(logs)
}

pub fn rejected_host_port_is_quoted_test() {
  let assert Ok(allowed) = transport.parse_allowed_hosts([], production: False)
    as "the development default parses"
  let #(_, logs) =
    log_capture.capture(fn() { transport.host_allowed("h:1\nX", allowed) })
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "invalid port \"1\\nX\"",
    ])
  let assert True = no_raw_newline(logs)
}

fn perform(eff: effect.Effect(Nil)) -> Nil {
  effect.perform(eff, fn(_msg) { Nil }, fn(_key, _generation, _msg) { Nil })
}

pub fn router_logs_drop_the_query_test() {
  let #(Nil, logs) =
    log_capture.capture(fn() {
      // Logged as a warning: no connection to navigate.
      perform(router.push("/reset?token=s3cr3t"))
      // Logged as an error: not a same-origin path.
      perform(router.redirect("//evil.example/?token=s3cr3t"))
    })
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "router.push to \"/reset\"",
    ])
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "router.redirect", "\"//evil.example/\"",
    ])
  let assert True = no_secret(logs)
}
