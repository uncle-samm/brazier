//// One refused configuration, one log line that carries the detail.
////
//// `ip.parse_trusted_proxies`, `ip.parse_proxy_networks`,
//// `transport.parse_allowed_hosts`, `transport.parse_allowed_origins` and
//// `transport.validate_drain_timeout` used to log their own refusal before
//// the caller logged "Invalid security limits: ..." with the same detail, so
//// one bad setting made two lines. The parsers now only return the refusal,
//// and each caller logs it once: `start_listener` and
//// `validate_security_limits` ("Invalid security limits: ..."),
//// `transport.trusted_proxies`, `server.start` ("Invalid listener
//// options: ...") and `application.start` (its `BRAZIER_SHUTDOWN_TIMEOUT`
//// and drain checks). Every refusal here names a value unique to it, and
//// each test counts every line, at any level, that mentions it.
////
//// The application tests run on a peer node, so the test VM's environment
//// and the application's node-wide processes are untouched.

import brazier/app_config_fixture
import brazier/application
import brazier/cluster/peer.{Timeout}
import brazier/effect
import brazier/error
import brazier/html
import brazier/ip
import brazier/log_capture
import brazier/transport
import brazier/transport/server
import gleam/list
import gleam/option.{None}
import gleam/string

// --- start_listener ----------------------------------------------------------

pub fn invalid_trusted_proxy_cidr_is_logged_once_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      trusted_proxies: ["10.0.0.0/33"],
    )
  assert_listener_refused_once(
    limits,
    "trusted_proxies: trusted proxy prefix too long: 10.0.0.0/33",
  )
}

pub fn forwarding_header_without_proxies_is_logged_once_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      trusted_proxies: [],
      forwarding_header: ip.Forwarded,
    )
  assert_listener_refused_once(
    limits,
    "trusted_proxies: forwarding header Forwarded is configured but no "
      <> "trusted proxies are listed, so it would never be read",
  )
}

pub fn invalid_allowed_host_is_logged_once_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      allowed_hosts: ["bad/host"],
    )
  assert_listener_refused_once(
    limits,
    "invalid allowed_hosts entry \"bad/host\": a host name has no scheme or path",
  )
}

pub fn invalid_allowed_origin_is_logged_once_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      ws_allowed_origins: ["https://example.com/path-unique"],
    )
  assert_listener_refused_once(
    limits,
    "ws_allowed_origins entry must not contain a path: "
      <> "\"https://example.com/path-unique\"",
  )
}

pub fn invalid_drain_timeout_is_logged_once_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      drain_timeout_ms: -7,
    )
  assert_listener_refused_once(
    limits,
    "drain_timeout_ms must be in 0..4294967295ms, got -7",
  )
}

// --- validate_security_limits and trusted_proxies ----------------------------

pub fn validate_security_limits_logs_a_refusal_once_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      trusted_proxies: ["not-a-proxy"],
    )
  let #(result, logs) =
    log_capture.capture(fn() { transport.validate_security_limits(limits) })
  let detail = "trusted_proxies: invalid trusted proxy address: not-a-proxy"
  assert result == Error(detail)
  assert lines(logs, "not-a-proxy")
    == [logged("error", "transport", "Invalid security limits: " <> detail)]
}

pub fn trusted_proxies_logs_a_refusal_once_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      trusted_proxies: ["not-a-middleware-proxy"],
    )
  let #(result, logs) =
    log_capture.capture(fn() { transport.trusted_proxies(limits) })
  let assert Error(reason) = result
    as "an unparseable proxy entry must be refused"
  assert reason == "invalid trusted proxy address: not-a-middleware-proxy"
  assert lines(logs, "not-a-middleware-proxy")
    == [
      logged(
        "error",
        "transport",
        "trusted_proxies is invalid (limits were not validated): " <> reason,
      ),
    ]
}

// --- server.start ------------------------------------------------------------

pub fn invalid_listener_proxy_is_logged_once_test() {
  let options =
    server.ListenerOptions(
      ..server.default_listener_options(0),
      trusted_proxies: ["not-a-listener-proxy"],
    )
  let #(result, logs) =
    log_capture.capture(fn() { server.start(options, fn(_socket) { Nil }) })
  let detail = "invalid trusted proxy address: not-a-listener-proxy"
  let assert Error(reason) = result
    as "a listener with an unparseable proxy entry must not start"
  assert reason == detail
  assert lines(logs, "not-a-listener-proxy")
    == [logged("error", "server", "Invalid listener options: " <> detail)]
}

// --- application.start -------------------------------------------------------

pub fn application_logs_a_configured_drain_refusal_once_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "config_refusal_drain")
  let assert [p] = peers
  let #(result, logs) =
    peer.on(p, fn() {
      let #(result, logs) =
        log_capture.capture(fn() { application.start(app_config(-9)) })
      #(result_reason(result), lines(logs, "got -9"))
    })
  let detail = "drain_timeout_ms must be in 0..4294967295ms, got -9"
  assert result == Error("ConfigError: " <> detail)
  assert logs == [logged("error", "application", detail)]
}

pub fn application_logs_a_shutdown_timeout_refusal_once_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "config_refusal_env")
  let assert [p] = peers
  let #(result, logs) =
    peer.on(p, fn() {
      putenv("BRAZIER_SHUTDOWN_TIMEOUT", "-11")
      let #(result, logs) =
        log_capture.capture(fn() { application.start(app_config(5000)) })
      unsetenv("BRAZIER_SHUTDOWN_TIMEOUT")
      #(result_reason(result), lines(logs, "got -11"))
    })
  let detail =
    "BRAZIER_SHUTDOWN_TIMEOUT: drain_timeout_ms must be in 0..4294967295ms, "
    <> "got -11"
  assert result == Error("ConfigError: " <> detail)
  assert logs == [logged("error", "application", detail)]
}

// --- Helpers -----------------------------------------------------------------

/// Start a listener with `limits`: it must be refused with "Invalid security
/// limits: <detail>", and that must be the only line mentioning `detail`.
fn assert_listener_refused_once(
  limits: transport.SecurityLimits,
  detail: String,
) -> Nil {
  let #(result, logs) =
    log_capture.capture(fn() { transport.start_listener(config(limits)) })
  let assert Error(error.ConfigError(reason:)) = result
    as "a listener with refused limits must not start"
  assert reason == "Invalid security limits: " <> detail
  assert lines(logs, detail)
    == [logged("error", "transport", "Invalid security limits: " <> detail)]
}

/// A line `brazier.<module>` logged at `level`, as the capture renders it.
fn logged(level: String, module: String, text: String) -> log_capture.Captured {
  log_capture.Captured(level, "[brazier." <> module <> "] " <> text)
}

/// Every captured line, at any level, whose text contains `fragment`.
fn lines(
  logs: List(log_capture.Captured),
  fragment: String,
) -> List(log_capture.Captured) {
  list.filter(logs, fn(line) { string.contains(line.message, fragment) })
}

fn result_reason(
  result: Result(application.App, error.BrazierError),
) -> Result(Nil, String) {
  case result {
    Ok(app) -> {
      let assert Ok(Nil) = application.stop(app)
        as "an application that started must stop"
      Ok(Nil)
    }
    Error(err) -> Error(error.to_string(err))
  }
}

fn config(limits: transport.SecurityLimits) -> transport.TransportConfig {
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
    api_handler: None,
  )
}

fn app_config(drain_timeout_ms: Int) -> application.AppConfig(Int, Nil) {
  let base =
    app_config_fixture.new(
      port: 0,
      init: fn(_ctx) { Ok(#(0, effect.none())) },
      update: fn(model, _msg) { #(model, effect.none()) },
      view: fn(_model) { html.div([], []) },
      encode_model: fn(_model) { "{}" },
      decode_event: fn(_name, _handler, _data, _path) { Ok(Nil) },
    )
  application.AppConfig(
    ..base,
    security_limits: transport.SecurityLimits(
      ..transport.default_security_limits(),
      drain_timeout_ms: drain_timeout_ms,
    ),
  )
}

@external(erlang, "brazier_ws8c_drain_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

@external(erlang, "brazier_ws8c_drain_ffi", "unsetenv")
fn unsetenv(name: String) -> Nil
