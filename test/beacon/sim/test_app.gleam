/// Test application configurations for simulation testing.
/// Each function starts a real Beacon app on an OS-assigned port (port 0);
/// read the bound port from the returned `App.port`.
import beacon/application
import beacon/effect
import beacon/element
import beacon/error
import beacon/middleware
import beacon/transport
import gleam/int
import gleam/option

/// Simple counter app — accepts "inc" events, renders "count:N".
pub type CounterModel {
  CounterModel(count: Int)
}

pub type CounterMsg {
  CounterInc
}

/// Security limits for simulation apps. Every simulated client connects from
/// localhost, so the per-IP caps are raised above the largest pool
/// (1000 connections) the sim tests open.
pub fn sim_security_limits() -> transport.SecurityLimits {
  transport.SecurityLimits(
    ..transport.default_security_limits(),
    max_connections_per_ip: 10_000,
    max_ws_connections_per_ip: 10_000,
  )
}

pub fn start_counter_app() -> Result(application.App, error.BeaconError) {
  start_counter_app_with_limits(sim_security_limits())
}

/// Counter app with explicit security limits (for abuse-policy tests).
pub fn start_counter_app_with_limits(
  limits: transport.SecurityLimits,
) -> Result(application.App, error.BeaconError) {
  let config =
    application.AppConfig(
      port: 0,
      init: fn() { #(CounterModel(count: 0), effect.none()) },
      update: fn(model: CounterModel, _msg) {
        #(CounterModel(count: model.count + 1), effect.none())
      },
      view: fn(model: CounterModel) {
        element.el("div", [element.attr("id", "app")], [
          element.text("count:" <> int.to_string(model.count)),
        ])
      },
      decode_event: option.Some(fn(_name, _handler_id, _data, _path) {
        // Accept ALL handler IDs — simulation tests send various IDs
        // (h0=mousedown, h1=mouseup, h2=mousemove, inc, etc.)
        Ok(CounterInc)
      }),
      secret_key: "sim-test-secret-key-long-enough-for-hmac!!",
      title: "Sim Counter",
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      middlewares: [middleware.secure_headers()],
      static_dir: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      security_limits: limits,
      head_html: option.None,
      api_handler: option.None,
      ws_auth: option.None,
      init_from_request: option.None,
      dev_mode: False,
    )
  application.start_advanced(config)
}

/// Ticker app — uses effect.every to auto-increment on a timer.
/// Proves server-push works: client receives patches without sending events.
pub type TickerModel {
  TickerModel(tick: Int)
}

pub type TickerMsg {
  Tick
}

pub fn start_ticker_app(
  interval_ms: Int,
) -> Result(application.App, error.BeaconError) {
  let config =
    application.AppConfig(
      port: 0,
      init: fn() {
        #(TickerModel(tick: 0), effect.every(interval_ms, fn() { Tick }))
      },
      update: fn(model: TickerModel, _msg) {
        #(TickerModel(tick: model.tick + 1), effect.none())
      },
      view: fn(model: TickerModel) {
        element.el("div", [element.attr("id", "app")], [
          element.text("tick:" <> int.to_string(model.tick)),
        ])
      },
      decode_event: option.Some(fn(_name, _handler_id, _data, _path) {
        Ok(Tick)
      }),
      secret_key: "sim-ticker-secret-key-long-enough-for-hmac!!",
      title: "Sim Ticker",
      serialize_model: option.Some(fn(model: TickerModel) {
        "{\"tick\":" <> int.to_string(model.tick) <> "}"
      }),
      deserialize_model: option.None,
      middlewares: [middleware.secure_headers()],
      static_dir: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      security_limits: sim_security_limits(),
      head_html: option.None,
      api_handler: option.None,
      ws_auth: option.None,
      init_from_request: option.None,
      dev_mode: False,
    )
  application.start_advanced(config)
}
