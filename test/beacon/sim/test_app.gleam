/// Test application configurations for simulation testing.
/// Each function starts a real Beacon app on an OS-assigned port (port 0);
/// read the bound port from the returned `App.port`.
import beacon/app_config_fixture
import beacon/application
import beacon/attribute
import beacon/effect
import beacon/error
import beacon/html
import beacon/transport
import gleam/int

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
      ..app_config_fixture.new(
        port: 0,
        init: fn(_ctx) { Ok(#(CounterModel(count: 0), effect.none())) },
        update: fn(model: CounterModel, _msg) {
          #(CounterModel(count: model.count + 1), effect.none())
        },
        view: fn(model: CounterModel) {
          html.div([attribute.id("app")], [
            html.text("count:" <> int.to_string(model.count)),
          ])
        },
        encode_model: fn(model: CounterModel) {
          "{\"count\":" <> int.to_string(model.count) <> "}"
        },
        decode_event: fn(_name, _handler_id, _data, _path) {
          // Accept ALL handler IDs — simulation tests send various IDs
          // (h0=mousedown, h1=mouseup, h2=mousemove, inc, etc.)
          Ok(CounterInc)
        },
      ),
      title: fn(_model) { "Sim Counter" },
      security_limits: limits,
    )
  application.start(config)
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
      ..app_config_fixture.new(
        port: 0,
        init: fn(_ctx) {
          Ok(#(TickerModel(tick: 0), effect.every(interval_ms, fn() { Tick })))
        },
        update: fn(model: TickerModel, _msg) {
          #(TickerModel(tick: model.tick + 1), effect.none())
        },
        view: fn(model: TickerModel) {
          html.div([attribute.id("app")], [
            html.text("tick:" <> int.to_string(model.tick)),
          ])
        },
        encode_model: fn(model: TickerModel) {
          "{\"tick\":" <> int.to_string(model.tick) <> "}"
        },
        decode_event: fn(_name, _handler_id, _data, _path) { Ok(Tick) },
      ),
      title: fn(_model) { "Sim Ticker" },
      security_limits: sim_security_limits(),
    )
  application.start(config)
}
