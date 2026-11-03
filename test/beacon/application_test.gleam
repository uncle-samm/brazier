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
      init: fn(_ctx) { Ok(#(TestModel(count: 0), effect.none())) },
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

/// Start the unsupervised application, check it bound a port, and stop it
/// (the shared PubSub and session scope of the test node keep running).
fn start_and_stop(config: application.AppConfig(TestModel, TestMsg)) -> Nil {
  let assert Ok(app) = application.start(config)
  let assert True = app.port > 0
  let assert True = is_process_alive(app.supervisor_pid)
  let assert Ok(Nil) = application.stop(app)
  let assert False = is_process_alive(app.supervisor_pid)
  Nil
}

// The supervised tree (`application.start_supervised`) owns node-wide
// PubSub and the session scope, which this node already runs for other
// tests; it is covered on peer nodes in cluster/app_tree_test.

pub fn application_starts_and_stops_test() {
  start_and_stop(test_config(0))
}

pub fn application_with_middleware_starts_test() {
  start_and_stop(
    application.AppConfig(..test_config(0), middlewares: [
      beacon_middleware.secure_headers(),
    ]),
  )
}

pub fn application_with_static_dir_starts_test() {
  start_and_stop(
    application.AppConfig(
      ..test_config(0),
      static_dir: option.Some("priv/static"),
    ),
  )
}

@external(erlang, "erlang", "is_process_alive")
fn is_process_alive(pid: process.Pid) -> Bool
