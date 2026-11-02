/// A weak secret_key makes every signed join token forgeable, so the
/// application refuses to start (and binds nothing) when given one.
import beacon/application
import beacon/effect
import beacon/element
import beacon/error
import beacon/transport
import gleam/option
import gleam/string

fn config(port: Int, secret: String) -> application.AppConfig(Int, Nil) {
  application.AppConfig(
    port: port,
    init: fn() { #(0, effect.none()) },
    update: fn(model, _msg) { #(model, effect.none()) },
    view: fn(_model) { element.text("secret test") },
    decode_event: option.Some(fn(_name, _handler_id, _data, _path) { Ok(Nil) }),
    secret_key: secret,
    title: "Secret Test",
    serialize_model: option.None,
    deserialize_model: option.None,
    middlewares: [],
    static_dir: option.None,
    route_patterns: [],
    on_route_change: option.None,
    on_route_leave: option.None,
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    security_limits: transport.default_security_limits(),
    head_html: option.None,
    api_handler: option.None,
    ws_auth: option.None,
    init_from_request: option.None,
    dev_mode: False,
  )
}

pub fn empty_secret_is_refused_without_binding_test() {
  let port = free_port()
  let assert Error(error.ConfigError(reason)) =
    application.start_advanced(config(port, ""))
  let assert True = string.contains(reason, "at least 32 bytes")
  let assert True = port_is_free(port)
}

pub fn short_secret_is_refused_without_binding_test() {
  let port = free_port()
  let assert Error(error.ConfigError(_)) =
    application.start_advanced(config(port, string.repeat("k", 31)))
  let assert True = port_is_free(port)
}

pub fn published_dev_secret_is_refused_test() {
  let assert Error(error.ConfigError(reason)) =
    application.start_advanced(config(
      0,
      "beacon-dev-secret-change-in-production",
    ))
  let assert True = string.contains(reason, "dev secret")
}

pub fn supervised_start_refuses_a_short_secret_test() {
  let port = free_port()
  let assert Error(error.ConfigError(_)) =
    application.start_supervised_advanced(config(port, "short"))
  let assert True = port_is_free(port)
}

pub fn a_32_byte_secret_starts_test() {
  let assert Ok(app) =
    application.start_advanced(config(0, string.repeat("k", 32)))
  let assert True = app.port > 0
}

@external(erlang, "beacon_config_test_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "beacon_config_test_ffi", "port_is_free")
fn port_is_free(port: Int) -> Bool
