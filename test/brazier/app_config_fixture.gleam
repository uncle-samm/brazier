//// An `application.AppConfig` with test defaults, for tests that start a
//// real server. Override fields with a record update.

import brazier/application
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/error
import brazier/internal/context.{type Context}
import brazier/middleware
import brazier/pubsub
import brazier/transport
import gleam/option

/// Long enough for `config.min_secret_key_bytes`.
pub const secret_key = "app-config-fixture-secret-key-0123456789"

pub fn new(
  port port: Int,
  init init: fn(Context) -> Result(#(state, Effect(msg)), error.InitError),
  update update: fn(state, msg) -> #(state, Effect(msg)),
  view view: fn(state) -> Element(msg),
  encode_model encode_model: fn(state) -> String,
  decode_event decode_event: fn(String, String, String, String) ->
    Result(msg, error.BrazierError),
) -> application.AppConfig(state, msg) {
  application.AppConfig(
    port: port,
    init: init,
    update: update,
    view: view,
    title: fn(_state) { "Brazier Test" },
    encode_model: encode_model,
    decode_event: decode_event,
    restore_model: option.None,
    route: option.None,
    secret_key: secret_key,
    middlewares: [middleware.secure_headers()],
    static_dir: option.None,
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    security_limits: transport.default_security_limits(),
    head_html: option.None,
    api_handler: option.None,
    ws_auth: option.None,
    dev_mode: False,
    pubsub: pubsub.default_config(),
    cluster: option.None,
    presence: option.None,
  )
}
