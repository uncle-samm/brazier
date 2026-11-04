//// The app builders in `brazier` and how `to_config` composes them with a
//// codec into the application config.

import brazier
import brazier/application
import brazier/effect
import brazier/element
import brazier/error
import brazier/internal/presence_watch
import brazier/local
import brazier/log_capture
import brazier/middleware
import brazier/presence
import brazier/runtime
import brazier/test_ctx
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri

pub type Msg {
  Inc
  Named(String)
}

/// A codec over an Int model: the model is its decimal string.
fn int_codec() -> runtime.GeneratedCodec(Int, Msg) {
  runtime.GeneratedCodec(
    encode_model: int.to_string,
    decode_model: fn(json) {
      case int.parse(json) {
        Ok(n) -> Ok(n)
        Error(Nil) -> Error("not an int: " <> json)
      }
    },
    decode_event: fn(_name, handler_id, _data, _path) {
      case handler_id {
        "inc" -> Ok(Inc)
        other -> Error(error.RuntimeError(reason: "unknown handler " <> other))
      }
    },
  )
}

fn counter() -> brazier.App(Int, Int, Nil, Msg) {
  brazier.simple(
    init: fn(_ctx) { Ok(0) },
    update: fn(model, msg) {
      case msg {
        Inc -> model + 1
        Named(_) -> model
      }
    },
    view: fn(model) { element.text(int.to_string(model)) },
  )
}

fn config(
  app: brazier.App(state, Int, local, Msg),
) -> application.AppConfig(state, Msg) {
  brazier.to_config(app, int_codec(), 8080)
}

fn keyed(
  app: brazier.App(state, model, local, msg),
) -> brazier.App(state, model, local, msg) {
  brazier.secret_key(app, "a-test-secret-that-is-long-enough-0123456789")
}

// --- simple ---

pub fn simple_init_and_update_have_no_effects_test() {
  let cfg = config(keyed(counter()))
  let assert Ok(#(model, init_effect)) = cfg.init(test_ctx.root())
  let assert 0 = model
  let assert True = effect.is_none(init_effect)
  let #(model, update_effect) = cfg.update(model, Inc)
  let assert 1 = model
  let assert True = effect.is_none(update_effect)
}

pub fn simple_view_and_encode_use_the_model_test() {
  let cfg = config(keyed(counter()))
  let assert "7" = element.to_string(cfg.view(7))
  let assert "7" = cfg.encode_model(7)
}

pub fn default_title_is_brazier_test() {
  let cfg = config(keyed(counter()))
  let assert "Brazier" = cfg.title(3)
}

pub fn title_is_computed_from_the_model_test() {
  let cfg =
    counter()
    |> keyed
    |> brazier.title(fn(model) { "Count " <> int.to_string(model) })
    |> config
  let assert "Count 3" = cfg.title(3)
}

pub fn decode_event_is_the_codecs_test() {
  let cfg = config(keyed(counter()))
  let assert Ok(Inc) = cfg.decode_event("click", "inc", "{}", "0")
  let assert Error(error.RuntimeError(reason: "unknown handler nope")) =
    cfg.decode_event("click", "nope", "{}", "0")
}

// --- application ---

pub fn application_keeps_update_effects_test() {
  let cfg =
    brazier.application(
      init: fn(_ctx) { Ok(#(0, effect.from(fn(_dispatch) { Nil }))) },
      update: fn(model, _msg) {
        #(model, effect.from(fn(dispatch) { dispatch(Inc) }))
      },
      view: fn(model) { element.text(int.to_string(model)) },
    )
    |> keyed
    |> config
  let assert Ok(#(_model, init_effect)) = cfg.init(test_ctx.root())
  let assert False = effect.is_none(init_effect)
  let #(_model, update_effect) = cfg.update(0, Inc)
  let assert False = effect.is_none(update_effect)
}

// --- with_router ---

pub type Route {
  Home
  User(String)
}

fn parse_route(page: uri.Uri) -> Result(Route, Nil) {
  case uri.path_segments(page.path) {
    [] -> Ok(Home)
    ["users", id] -> Ok(User(id))
    _ -> Error(Nil)
  }
}

fn page(path: String) -> uri.Uri {
  let assert Ok(parsed) = uri.parse(path)
  parsed
}

pub fn no_router_by_default_test() {
  let cfg = config(keyed(counter()))
  let assert None = cfg.route
}

pub fn with_router_composes_parse_and_on_change_test() {
  let cfg =
    counter()
    |> keyed
    |> brazier.with_router(parse: parse_route, on_change: fn(route) {
      case route {
        Home -> Named("home")
        User(id) -> Named("user " <> id)
      }
    })
    |> config
  let assert Some(route) = cfg.route
  let assert Ok(Named("home")) = route(page("/"))
  let assert Ok(Named("user 7")) = route(page("/users/7"))
  let assert Error(Nil) = route(page("/users/7/edit"))
  let assert Error(Nil) = route(page("/nowhere"))
}

// --- full_application ---

pub type State {
  State(count: Int, secret: String)
}

pub fn full_application_syncs_state_for_encode_view_and_title_test() {
  let cfg =
    brazier.full_application(
      init: fn(_ctx) { Ok(#(State(count: 1, secret: "hidden"), effect.none())) },
      update: fn(state: State, _msg) {
        #(State(..state, count: state.count + 1), effect.none())
      },
      sync: fn(state: State) { state.count * 10 },
      local: local.layer(
        init: fn(model) { model + 5 },
        update: fn(_model, local, _msg) { local.handled(local) },
      ),
      view: fn(model, local) {
        element.text(int.to_string(model) <> "/" <> int.to_string(local))
      },
    )
    |> keyed
    |> brazier.title(fn(model) { "M" <> int.to_string(model) })
    |> config
  let assert Ok(#(state, _effect)) = cfg.init(test_ctx.root())
  // Only the synced model is encoded; the secret never is.
  let encoded = cfg.encode_model(state)
  let assert "10" = encoded
  let assert False = string.contains(encoded, "hidden")
  // The server view renders the model with the Local layer's initial value.
  let assert "10/15" = element.to_string(cfg.view(state))
  let assert "M10" = cfg.title(state)
}

// --- with_state_recovery ---

pub fn no_state_recovery_by_default_test() {
  let cfg = config(keyed(counter()))
  let assert None = cfg.restore_model
}

pub fn state_recovery_decodes_and_restores_test() {
  let cfg =
    brazier.full_application(
      init: fn(_ctx) { Ok(#(State(count: 0, secret: ""), effect.none())) },
      update: fn(state, _msg) { #(state, effect.none()) },
      sync: fn(state: State) { state.count },
      local: local.none(),
      view: fn(model, _local) { element.text(int.to_string(model)) },
    )
    |> keyed
    |> brazier.with_state_recovery(restore: fn(model) {
      State(count: model, secret: "restored")
    })
    |> config
  let assert Some(restore) = cfg.restore_model
  let assert Ok(State(count: 42, secret: "restored")) = restore("42")
  // A model the codec cannot decode is an error, not a default state.
  let assert Error("not an int: {\"x\":1}") = restore("{\"x\":1}")
}

// --- presence ---

pub fn no_presence_by_default_test() {
  let cfg = config(keyed(counter()))
  let assert None = cfg.presence
}

pub fn presence_reaches_the_config_test() {
  let cfg =
    counter()
    |> keyed
    |> brazier.presence(
      tracker: presence.new("builder", json.string, decode.string),
      track: fn(count) {
        [presence.Tracking(topic: "room", key: "k", meta: int.to_string(count))]
      },
      on_presence: fn(_diff) { Inc },
    )
    |> config
  let assert Some(watch) = cfg.presence
  let assert "builder" = presence_watch.name(watch)
  let assert Ok(Nil) = presence_watch.validate(watch)
}

pub fn invalid_presence_config_fails_validation_test() {
  let cfg =
    counter()
    |> keyed
    |> brazier.presence(
      tracker: presence.new("builder", json.string, decode.string)
        |> presence.pool_size(0),
      track: fn(_count) { [] },
      on_presence: fn(_diff) { Inc },
    )
    |> config
  let assert Some(watch) = cfg.presence
  let assert Error(presence.InvalidConfig(_)) = presence_watch.validate(watch)
}

// --- secret_key ---

pub fn explicit_secret_key_is_used_test() {
  let cfg = config(keyed(counter()))
  let assert "a-test-secret-that-is-long-enough-0123456789" = cfg.secret_key
}

pub fn missing_secret_key_is_generated_and_warned_test() {
  let #(#(first, second), logs) =
    log_capture.capture(fn() {
      #(config(counter()).secret_key, config(counter()).secret_key)
    })
  let assert True = string.byte_size(first) >= 32
  let assert True = first != second
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "auto-generated secret_key",
    ])
}

// --- middleware ---

pub fn secure_headers_by_default_and_middleware_appends_test() {
  let assert 1 = list.length(config(keyed(counter())).middlewares)
  let passthrough: middleware.Middleware = fn(req, next) { next(req) }
  let cfg =
    counter()
    |> keyed
    |> brazier.with_middleware(passthrough)
    |> brazier.with_middleware(passthrough)
    |> config
  let assert 3 = list.length(cfg.middlewares)
}

// --- other options ---

pub fn options_reach_the_config_test() {
  let cfg =
    counter()
    |> keyed
    |> brazier.head_html("<meta name=\"x\">")
    |> brazier.static_dir("priv/static")
    |> brazier.dev_mode(True)
    |> brazier.subscriptions(fn(_model) { ["topic"] })
    |> brazier.on_notify(fn(topic) { Named(topic) })
    |> config
  let assert Some("<meta name=\"x\">") = cfg.head_html
  let assert Some("priv/static") = cfg.static_dir
  let assert True = cfg.dev_mode
  let assert 8080 = cfg.port
  let assert Some(subscriptions) = cfg.dynamic_subscriptions
  let assert ["topic"] = subscriptions(0)
  let assert Some(on_notify) = cfg.on_notify
  let assert Named("t") = on_notify("t")
}
