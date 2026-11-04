//// Nested child modules (docs/COMPONENTS.md): a parent wraps the child's
//// view with `element.map` and its effects with `effect.map`, and the
//// child's messages come back to the parent's update wrapped in `ChildMsg`.

import beacon/child_counter
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/error
import beacon/html
import beacon/internal/context
import beacon/internal/render
import beacon/runtime
import beacon/transport
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleam/uri

pub type Model {
  Model(title: String, child: child_counter.Model)
}

pub type Msg {
  ChildMsg(child_counter.Msg)
  Renamed(String)
}

fn init() -> Model {
  Model(title: "Parent", child: child_counter.init())
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ChildMsg(child_msg) -> {
      let #(child, child_effect) = child_counter.update(model.child, child_msg)
      #(Model(..model, child: child), effect.map(child_effect, ChildMsg))
    }
    Renamed(title) -> #(Model(..model, title: title), effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.h1([], [html.text(model.title)]),
    element.map(child_counter.view(model.child), ChildMsg),
  ])
}

/// The child's Clicked button: the parent's root `0`, its second child `0.1`
/// (the child's root), then that element's first child.
const clicked_id = "0.1.0"

const reset_id = "0.1.1"

fn run_event(id: String) -> Result(Msg, String) {
  let #(_html, handlers) = render.render(element.to_node(view(init())))
  case render.lookup(handlers, "click", id) {
    Ok(handler) ->
      case render.run(handler, dynamic.properties([])) {
        Ok(msg) -> Ok(msg)
        Error(errors) -> Error(render.describe_errors(errors))
      }
    Error(Nil) -> Error("No click handler at " <> id)
  }
}

pub fn mapped_child_view_produces_parent_messages_test() {
  let assert Ok(ChildMsg(child_counter.Clicked)) = run_event(clicked_id)
  let assert Ok(ChildMsg(child_counter.Reset)) = run_event(reset_id)
}

pub fn mapped_child_view_keeps_child_ids_under_parent_test() {
  // The child's root is not itself a handler, and nothing exists past the
  // child's last button.
  let assert Error(_) = run_event("0.1")
  let assert Error(_) = run_event("0.1.2")
}

pub fn child_effect_is_mapped_to_parent_message_test() {
  let #(model, eff) = update(init(), ChildMsg(child_counter.Clicked))
  let assert 1 = model.child.clicks
  let assert False = effect.is_none(eff)
  let seen = process.new_subject()
  effect.perform(eff, fn(msg) { process.send(seen, msg) }, fn(_, _, _) { Nil })
  let assert Ok(ChildMsg(child_counter.Loaded(value))) =
    process.receive(seen, 500)
  let assert True = value == child_counter.loaded_value
}

pub fn child_message_without_effect_maps_to_none_test() {
  let #(model, eff) = update(init(), ChildMsg(child_counter.Reset))
  let assert True = model.child == child_counter.init()
  let assert True = effect.is_none(eff)
}

// --- Through the runtime ------------------------------------------------------

fn test_context() -> context.Context {
  context.new(
    uri: uri.Uri(
      ..uri.empty,
      scheme: option.Some("http"),
      host: option.Some("localhost"),
      path: "/",
    ),
    cookies: [],
    is_connected: True,
    session_id: Error(Nil),
  )
}

fn encode(model: Model) -> String {
  "{\"title\":\""
  <> model.title
  <> "\",\"clicks\":"
  <> int.to_string(model.child.clicks)
  <> ",\"loaded\":"
  <> int.to_string(model.child.loaded)
  <> "}"
}

/// A runtime whose update reports every message it receives to `seen`.
fn start_parent(seen: Subject(Msg)) -> Subject(runtime.RuntimeMessage(Msg)) {
  let config =
    runtime.RuntimeConfig(
      init: fn(_ctx) { Ok(#(init(), effect.none())) },
      update: fn(model, msg) {
        process.send(seen, msg)
        update(model, msg)
      },
      encode_model: encode,
      decode_event: fn(_name, handler_id, _data, _path) {
        case run_event(handler_id) {
          Ok(msg) -> Ok(msg)
          Error(reason) -> Error(error.RuntimeError(reason: reason))
        }
      },
      restore_model: option.None,
      route: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      secret_key: "",
      presence: option.None,
      title: option.None,
    )
  let assert Ok(subject) = runtime.start(config, test_context())
  subject
}

fn join(
  subject: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
) -> Subject(transport.InternalMessage) {
  let transport_subject = process.new_subject()
  process.send(
    subject,
    runtime.ClientConnected(conn_id: conn_id, subject: transport_subject),
  )
  process.send(
    subject,
    runtime.ClientJoined(conn_id: conn_id, token: "", path: "/"),
  )
  let assert Ok(transport.SendModelSync(..)) =
    process.receive(transport_subject, 500)
  transport_subject
}

fn click(
  subject: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  id: String,
) -> Nil {
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: conn_id,
      event_name: "click",
      handler_id: id,
      event_data: "{}",
      target_path: id,
      clock: 1,
      ops: "",
    ),
  )
}

fn drain(
  subject: Subject(transport.InternalMessage),
  acc: List(transport.InternalMessage),
) -> List(transport.InternalMessage) {
  case process.receive(subject, 100) {
    Ok(msg) -> drain(subject, [msg, ..acc])
    Error(Nil) -> acc
  }
}

pub fn runtime_routes_child_effect_back_through_parent_update_test() {
  let seen = process.new_subject()
  let subject = start_parent(seen)
  let transport_subject = join(subject, "child_conn_1")
  click(subject, "child_conn_1", clicked_id)
  let assert Ok(ChildMsg(child_counter.Clicked)) = process.receive(seen, 500)
  let assert Ok(ChildMsg(child_counter.Loaded(value))) =
    process.receive(seen, 500)
  let assert True = value == child_counter.loaded_value
  let loaded = int.to_string(child_counter.loaded_value)
  let synced =
    list.any(drain(transport_subject, []), fn(msg) {
      case msg {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"loaded\":" <> loaded)
        transport.SendPatch(ops_json: json, ..) ->
          string.contains(json, "/loaded") && string.contains(json, loaded)
        _ -> False
      }
    })
  let assert True = synced
  process.send(subject, runtime.Shutdown)
}

pub fn runtime_child_message_without_effect_sends_nothing_more_test() {
  let seen = process.new_subject()
  let subject = start_parent(seen)
  let _transport = join(subject, "child_conn_2")
  click(subject, "child_conn_2", reset_id)
  let assert Ok(ChildMsg(child_counter.Reset)) = process.receive(seen, 500)
  let assert Error(Nil) = process.receive(seen, 100)
  process.send(subject, runtime.Shutdown)
}

pub fn runtime_refuses_click_on_child_root_test() {
  let seen = process.new_subject()
  let subject = start_parent(seen)
  let _transport = join(subject, "child_conn_3")
  click(subject, "child_conn_3", "0.1")
  let assert Error(Nil) = process.receive(seen, 200)
  process.send(subject, runtime.Shutdown)
}
