/// A weak secret_key makes every signed join token forgeable, so the
/// application refuses to start (and binds nothing) when given one.
import brazier/app_config_fixture
import brazier/application
import brazier/effect
import brazier/element
import brazier/error
import gleam/int
import gleam/string

fn config(port: Int, secret: String) -> application.AppConfig(Int, Nil) {
  application.AppConfig(
    ..app_config_fixture.new(
      port: port,
      init: fn(_ctx) { Ok(#(0, effect.none())) },
      update: fn(model, _msg) { #(model, effect.none()) },
      view: fn(_model) { element.text("secret test") },
      encode_model: int.to_string,
      decode_event: fn(_name, _handler_id, _data, _path) { Ok(Nil) },
    ),
    secret_key: secret,
    middlewares: [],
  )
}

pub fn empty_secret_is_refused_without_binding_test() {
  let port = free_port()
  let assert Error(error.ConfigError(reason)) =
    application.start(config(port, ""))
  let assert True = string.contains(reason, "at least 32 bytes")
  let assert True = port_is_free(port)
}

pub fn short_secret_is_refused_without_binding_test() {
  let port = free_port()
  let assert Error(error.ConfigError(_)) =
    application.start(config(port, string.repeat("k", 31)))
  let assert True = port_is_free(port)
}

pub fn published_dev_secret_is_refused_test() {
  let assert Error(error.ConfigError(reason)) =
    application.start(config(0, "beacon-dev-secret-change-in-production"))
  let assert True = string.contains(reason, "dev secret")
}

pub fn supervised_start_refuses_a_short_secret_test() {
  let port = free_port()
  let assert Error(error.ConfigError(_)) =
    application.start_supervised(config(port, "short"))
  let assert True = port_is_free(port)
}

pub fn a_32_byte_secret_starts_test() {
  let assert Ok(app) = application.start(config(0, string.repeat("k", 32)))
  let assert True = app.port > 0
}

@external(erlang, "brazier_config_test_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "brazier_config_test_ffi", "port_is_free")
fn port_is_free(port: Int) -> Bool
