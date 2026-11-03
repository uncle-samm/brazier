//// The server does not advertise `max_events_per_second` to the client;
//// the client paces itself for 50 events per second. A listener started
//// with a lower limit says so once, at start, and still starts.

import beacon/log_capture
import beacon/transport
import beacon/transport/server
import gleam/option.{None}

fn start(
  max_events_per_second: Int,
) -> #(server.Listener, List(log_capture.Captured)) {
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
      security_limits: transport.SecurityLimits(
        ..transport.default_security_limits(),
        max_events_per_second: max_events_per_second,
      ),
      api_handler: None,
    )
  let #(started, logs) =
    log_capture.capture(fn() { transport.start_listener(config) })
  let assert Ok(listener) = started
    as "a low event limit is allowed: the listener must start"
  #(listener, logs)
}

pub fn limit_below_the_client_pacing_is_logged_at_start_test() {
  let #(listener, logs) = start(20)
  server.stop(listener)
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "max_events_per_second is 20", "below the 50",
    ])
  Nil
}

pub fn default_limit_is_not_logged_test() {
  let #(listener, logs) = start(50)
  server.stop(listener)
  let assert False =
    log_capture.has(logs, level: "warning", containing: [
      "max_events_per_second",
    ])
  Nil
}
