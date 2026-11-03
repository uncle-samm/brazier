import beacon/app_config_fixture
import beacon/application
import beacon/effect
import beacon/error
import beacon/html
import beacon/middleware as beacon_middleware
import gleam/erlang/process
import gleam/int
import gleam/option

pub type TestModel {
  TestModel(count: Int)
}

pub type TestMsg {
  Inc
}

fn test_config(port: Int) -> application.AppConfig(TestModel, TestMsg) {
  application.AppConfig(
    ..app_config_fixture.new(
      port: port,
      init: fn(_ctx) { #(TestModel(count: 0), effect.none()) },
      update: fn(model, _msg) {
        #(TestModel(count: model.count + 1), effect.none())
      },
      view: fn(model: TestModel) {
        html.div([], [html.text(int.to_string(model.count))])
      },
      encode_model: fn(model: TestModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      },
      decode_event: fn(_name, handler_id, _data, _path) {
        case handler_id {
          "inc" -> Ok(Inc)
          _ -> Error(error.RuntimeError(reason: "unknown"))
        }
      },
    ),
    middlewares: [],
  )
}

pub fn application_starts_test() {
  let assert Ok(_app) = application.start(test_config(0))
  process.sleep(50)
}

pub fn application_supervised_starts_test() {
  let assert Ok(_app) = application.start_supervised(test_config(0))
  process.sleep(50)
}

pub fn application_returns_supervisor_pid_test() {
  let assert Ok(app) = application.start(test_config(0))
  // PID should be valid
  let assert True = is_process_alive(app.supervisor_pid)
}

pub fn application_with_middleware_starts_test() {
  let config =
    application.AppConfig(..test_config(0), middlewares: [
      beacon_middleware.secure_headers(),
    ])
  let assert Ok(_app) = application.start(config)
  process.sleep(50)
}

pub fn application_with_static_dir_starts_test() {
  let config =
    application.AppConfig(
      ..test_config(0),
      static_dir: option.Some("priv/static"),
    )
  let assert Ok(_app) = application.start(config)
  process.sleep(50)
}

@external(erlang, "erlang", "is_process_alive")
fn is_process_alive(pid: process.Pid) -> Bool
