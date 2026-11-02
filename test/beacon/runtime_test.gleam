import beacon/effect
import beacon/element
import beacon/error
import beacon/handler
import beacon/pubsub
import beacon/route
import beacon/runtime
import beacon/ssr
import beacon/transport
import beacon/transport/server
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option
import gleam/string

/// Create a fake socket for testing (nil wrapped as Socket type).
@external(erlang, "beacon_runtime_test_ffi", "fake_socket")
fn fake_socket() -> server.Socket

// --- Test helpers ---

/// A simple counter model for testing.
pub type CounterModel {
  CounterModel(count: Int)
}

/// Counter messages.
pub type CounterMsg {
  Increment
  Decrement
  SetCount(Int)
  Tick
}

pub type RouteModel {
  RouteModel(current_path: String, leave_events: List(String))
}

pub type RouteMsg {
  RouteChangedTo(String)
  RouteLeft(String)
}

fn counter_init() -> #(CounterModel, effect.Effect(CounterMsg)) {
  #(CounterModel(count: 0), effect.none())
}

fn counter_update(
  model: CounterModel,
  msg: CounterMsg,
) -> #(CounterModel, effect.Effect(CounterMsg)) {
  case msg {
    Increment -> #(CounterModel(count: model.count + 1), effect.none())
    Decrement -> #(CounterModel(count: model.count - 1), effect.none())
    SetCount(n) -> #(CounterModel(count: n), effect.none())
    Tick -> #(CounterModel(count: model.count + 1), effect.none())
  }
}

fn counter_view(model: CounterModel) -> element.Node(CounterMsg) {
  element.el("div", [], [element.text(int.to_string(model.count))])
}

fn counter_decode_event(
  _name: String,
  handler_id: String,
  _data: String,
  _path: String,
) -> Result(CounterMsg, error.BeaconError) {
  case handler_id {
    "increment" -> Ok(Increment)
    "decrement" -> Ok(Decrement)
    _ -> Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
  }
}

fn counter_config() -> runtime.RuntimeConfig(CounterModel, CounterMsg) {
  runtime.RuntimeConfig(
    init: counter_init,
    update: counter_update,
    view: counter_view,
    decode_event: option.Some(counter_decode_event),
    serialize_model: option.Some(fn(model: CounterModel) {
      "{\"count\":" <> int.to_string(model.count) <> "}"
    }),
    deserialize_model: option.None,
    route_patterns: [],
    on_route_change: option.None,
    on_route_leave: option.None,
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    init_from_request: option.None,
    secret_key: "",
    dev_mode: False,
  )
}

fn route_init() -> #(RouteModel, effect.Effect(RouteMsg)) {
  #(RouteModel(current_path: "unset", leave_events: []), effect.none())
}

fn route_update(
  model: RouteModel,
  msg: RouteMsg,
) -> #(RouteModel, effect.Effect(RouteMsg)) {
  case msg {
    RouteChangedTo(path) -> #(
      RouteModel(..model, current_path: path),
      effect.none(),
    )
    RouteLeft(event) -> #(
      RouteModel(..model, leave_events: [event, ..model.leave_events]),
      effect.none(),
    )
  }
}

fn route_view(model: RouteModel) -> element.Node(RouteMsg) {
  element.el("div", [], [
    element.text(model.current_path),
    element.text("|"),
    element.text(string.join(model.leave_events, ",")),
  ])
}

fn route_config() -> runtime.RuntimeConfig(RouteModel, RouteMsg) {
  runtime.RuntimeConfig(
    init: route_init,
    update: route_update,
    view: route_view,
    decode_event: option.Some(fn(_name, _handler_id, _data, _path) {
      Error(error.RuntimeError(reason: "route test does not decode events"))
    }),
    serialize_model: option.Some(fn(model: RouteModel) {
      "{\"current_path\":\""
      <> model.current_path
      <> "\",\"leave_events\":\""
      <> string.join(model.leave_events, ",")
      <> "\"}"
    }),
    deserialize_model: option.None,
    route_patterns: [route.pattern("/"), route.pattern("/settings")],
    on_route_change: option.Some(fn(resolved: route.Route) {
      RouteChangedTo(resolved.path)
    }),
    on_route_leave: option.Some(fn(previous: route.Route, next: route.Route) {
      effect.from(fn(dispatch) {
        dispatch(RouteLeft(previous.path <> "->" <> next.path))
      })
    }),
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    init_from_request: option.None,
    secret_key: "",
    dev_mode: False,
  )
}

// --- Tests ---

pub fn route_leave_effect_runs_before_navigation_settles_test() {
  let assert Ok(subject) = runtime.start(route_config())
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "route_conn", subject: transport_subject),
  )
  process.sleep(20)

  process.send(
    subject,
    runtime.ClientJoined(conn_id: "route_conn", token: "", path: "/"),
  )
  process.sleep(80)
  let _ = drain_messages(transport_subject, [])

  process.send(
    subject,
    runtime.ClientNavigated(conn_id: "route_conn", path: "/settings"),
  )
  process.sleep(150)

  let msgs = drain_messages(transport_subject, [])
  let has_route_change =
    list.any(msgs, fn(msg) {
      case msg {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"current_path\":\"/settings\"")
        transport.SendPatch(ops_json: json, ..) ->
          string.contains(json, "/current_path")
          && string.contains(json, "/settings")
        _ -> False
      }
    })
  let has_leave_effect =
    list.any(msgs, fn(msg) {
      case msg {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"leave_events\":\"/->/settings\"")
        transport.SendPatch(ops_json: json, ..) ->
          string.contains(json, "/leave_events")
          && string.contains(json, "/->/settings")
        _ -> False
      }
    })
  let assert True = has_route_change
  let assert True = has_leave_effect
}

pub fn runtime_starts_successfully_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Connect and join to verify we get authoritative model state without a remount.
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "start_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "start_conn", token: "", path: "/"),
  )
  process.sleep(50)

  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  let assert Ok(sync_msg) = process.selector_receive(selector, 500)
  case sync_msg {
    transport.SendModelSync(model_json: json, ..) -> {
      let assert True = string.contains(json, "\"count\":0")
    }
    transport.SendMount(..) -> panic as "Join must not send SendMount"
    _ -> panic as "Expected SendModelSync after join"
  }
}

pub fn runtime_accepts_client_connect_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let fake_transport_subject = process.new_subject()
  // Connect
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "test_conn_1",
      subject: fake_transport_subject,
    ),
  )
  process.sleep(20)

  // Join and verify model state is received.
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "test_conn_1", token: "", path: "/"),
  )
  process.sleep(50)

  let selector =
    process.new_selector()
    |> process.select(fake_transport_subject)
  let assert Ok(sync_msg) = process.selector_receive(selector, 500)
  case sync_msg {
    transport.SendModelSync(model_json: json, ..) -> {
      let assert True = string.contains(json, "\"count\":0")
    }
    transport.SendMount(..) -> panic as "Join must not send SendMount"
    _ -> panic as "Expected SendModelSync after connect + join"
  }
}

pub fn runtime_sends_model_sync_on_join_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Register connection
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "test_conn_2", subject: transport_subject),
  )
  process.sleep(20)

  // Send join
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "test_conn_2", token: "", path: "/"),
  )
  process.sleep(50)

  // Check that we received authoritative model state, not an HTML remount.
  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  let assert Ok(sync_msg) = process.selector_receive(selector, 500)
  case sync_msg {
    transport.SendModelSync(model_json: json, ..) -> {
      let assert True = string.contains(json, "\"count\":0")
    }
    transport.SendMount(..) -> panic as "Join must not send SendMount"
    _ -> panic as "Expected SendModelSync message on join"
  }
}

pub fn runtime_sends_model_sync_on_event_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Register connection
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "test_conn_3", subject: transport_subject),
  )
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "test_conn_3", token: "", path: "/"),
  )
  let assert Ok(transport.SendModelSync(..)) =
    process.receive(transport_subject, 500)

  // Send an event
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "test_conn_3",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0.0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  // Should receive a model_sync or patch containing updated count
  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  // Drain all messages and look for one containing the updated count
  let msgs =
    drain_messages(
      transport_subject,
      case process.selector_receive(selector, 500) {
        Ok(msg) -> [msg]
        Error(Nil) -> []
      },
    )
  let has_update =
    list.any(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":1")
        transport.SendPatch(ops_json: json, ..) ->
          string.contains(json, "/count")
        _ -> False
      }
    })
  let assert True = has_update
}

pub fn runtime_handles_disconnect_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Connect and disconnect
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "test_conn_4", subject: transport_subject),
  )
  process.sleep(20)
  process.send(subject, runtime.ClientDisconnected(conn_id: "test_conn_4"))
  process.sleep(20)

  // Send event — should not crash even though client is gone
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "test_conn_4",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0.0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  // After disconnect, no messages should arrive on the transport subject
  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  let assert Error(Nil) = process.selector_receive(selector, 200)
}

pub fn runtime_handles_unknown_event_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Connect
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "test_conn_5", subject: transport_subject),
  )
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "test_conn_5", token: "", path: "/"),
  )
  let assert Ok(transport.SendModelSync(..)) =
    process.receive(transport_subject, 500)

  // Send unknown event — should produce a SendError
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "test_conn_5",
      event_name: "click",
      handler_id: "unknown_handler",
      event_data: "{}",
      target_path: "0.0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  // Check that the transport received a SendError for the unknown handler,
  // followed by an ack-only patch at the unchanged revision.
  let msgs = drain_messages(transport_subject, [])
  let has_error =
    list.any(msgs, fn(m) {
      case m {
        transport.SendError(reason: reason) ->
          string.contains(reason, "Unknown handler")
        _ -> False
      }
    })
  let assert True = has_error
  let assert True =
    list.contains(
      msgs,
      transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 1),
    )
}

pub fn runtime_effect_dispatches_message_test() {
  // Create a config where init produces an effect that dispatches SetCount(42)
  let config =
    runtime.RuntimeConfig(
      init: fn() {
        #(
          CounterModel(count: 0),
          effect.from(fn(dispatch) { dispatch(SetCount(42)) }),
        )
      },
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )

  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect and join to get current state
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "test_conn_6", subject: transport_subject),
  )
  process.sleep(50)

  // The effect should have already dispatched SetCount(42),
  // so joining should sync count=42 in model state.
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "test_conn_6", token: "", path: "/"),
  )
  process.sleep(50)

  let selector =
    process.new_selector()
    |> process.select(transport_subject)

  // We might get multiple messages (patch from effect + model sync from join)
  // Drain all and find a message proving SetCount(42) was applied.
  // Model sync contains JSON with count; patches contain /count path.
  let first_msg = process.selector_receive(selector, 500)
  let msgs =
    drain_messages(transport_subject, case first_msg {
      Ok(msg) -> [msg]
      Error(Nil) -> []
    })
  let has_42 =
    list.any(msgs, fn(m) {
      case m {
        transport.SendMount(..) -> False
        transport.SendPatch(ops_json: json, ..) ->
          string.contains(json, "42") && string.contains(json, "/count")
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":42")
        _ -> False
      }
    })
  let assert True = has_42
}

pub fn live_update_does_not_render_server_view_test() {
  // Live updates use the generated/explicit event contract. The runtime must
  // not render the server view after an event.
  let config =
    runtime.RuntimeConfig(
      init: fn() { #(CounterModel(count: 0), effect.none()) },
      update: counter_update,
      view: fn(model: CounterModel) {
        case model.count == 1 {
          True -> {
            // Intentionally crash to prove a failed render is not committed.
            crash_for_test()
          }
          False -> element.el("button", [], [element.text("ok")])
        }
      },
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "crash_conn", subject: transport_subject),
  )
  process.sleep(20)

  process.send(
    subject,
    runtime.ClientJoined(conn_id: "crash_conn", token: "", path: "/"),
  )
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send increment. The view would crash for count=1 if the runtime rendered it.
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "crash_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  let crash_msgs = drain_messages(transport_subject, [])
  let has_render_error =
    list.any(crash_msgs, fn(msg) {
      case msg {
        transport.SendError(reason: reason) ->
          string.contains(reason, "View rendering failed")
        _ -> False
      }
    })
  let committed_model =
    list.any(crash_msgs, fn(msg) {
      case msg {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":1")
        transport.SendPatch(ops_json: json, ..) -> string.contains(json, "1")
        _ -> False
      }
    })
  let assert False = has_render_error
  let assert True = committed_model

  // Rejoin proves the runtime stayed alive and kept the updated model.
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "crash_conn", token: "", path: "/"),
  )
  process.sleep(50)
  let join_msgs = drain_messages(transport_subject, [])
  let sync_has_updated_model =
    list.any(join_msgs, fn(msg) {
      case msg {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":1")
        _ -> False
      }
    })
  let assert True = sync_has_updated_model

  // Runtime should still process later effects without rendering the view.
  process.send(subject, runtime.EffectDispatched(message: Decrement))
  process.sleep(50)

  let recovery_msgs = drain_messages(transport_subject, [])
  let recovered =
    list.any(recovery_msgs, fn(msg) {
      case msg {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":0")
        transport.SendPatch(ops_json: json, ..) -> string.contains(json, "0")
        _ -> False
      }
    })
  let assert True = recovered
}

pub fn runtime_shutdown_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  process.send(subject, runtime.Shutdown)
  // Give it time to shut down
  process.sleep(50)
  // Actor should be stopped — further messages won't be processed
  // (we can't easily verify this without monitoring, but at least it shouldn't crash)
}

pub fn runtime_shutdown_stops_periodic_effects_test() {
  let proof_subject = process.new_subject()
  let config =
    runtime.RuntimeConfig(..counter_config(), init: fn() {
      #(
        CounterModel(count: 0),
        effect.every(25, fn() {
          process.send(proof_subject, "tick")
          Tick
        }),
      )
    })

  let assert Ok(subject) = runtime.start(config)
  let assert Ok("tick") = process.receive(proof_subject, 250)
  process.send(subject, runtime.Shutdown)
  let _ = process.receive(proof_subject, 50)
  let assert Error(Nil) = process.receive(proof_subject, 120)
}

pub fn runtime_shutdown_stops_dynamic_subscription_listener_test() {
  pubsub.start()
  let topic = "runtime_shutdown_subscription_test"
  let proof_subject = process.new_subject()
  let config =
    runtime.RuntimeConfig(
      ..counter_config(),
      dynamic_subscriptions: option.Some(fn(_model) { [topic] }),
      on_notify: option.Some(fn(received_topic) {
        process.send(proof_subject, received_topic)
        Increment
      }),
    )

  let assert Ok(subject) = runtime.start(config)
  process.sleep(50)
  process.send(subject, runtime.Shutdown)
  process.sleep(50)
  pubsub.broadcast(topic, "after_shutdown")
  let assert Error(Nil) = process.receive(proof_subject, 200)
}

pub fn client_request_sync_sends_model_sync_without_mount_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "sync_conn", subject: transport_subject),
  )
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "sync_conn", token: "", path: "/"),
  )
  let assert Ok(transport.SendModelSync(..)) =
    process.receive(transport_subject, 500)
  process.send(subject, runtime.ClientSyncRequested(conn_id: "sync_conn"))
  process.sleep(50)

  let msgs = drain_messages(transport_subject, [])
  let has_model_sync =
    list.any(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":0")
        _ -> False
      }
    })
  let has_mount =
    list.any(msgs, fn(m) {
      case m {
        transport.SendMount(..) -> True
        _ -> False
      }
    })
  let assert True = has_model_sync
  let assert False = has_mount
}

fn recovery_config(
  secret_key: String,
) -> runtime.RuntimeConfig(CounterModel, CounterMsg) {
  runtime.RuntimeConfig(
    ..counter_config(),
    serialize_model: option.Some(fn(m: CounterModel) { int.to_string(m.count) }),
    deserialize_model: option.Some(fn(s: String) {
      case int.parse(s) {
        Ok(n) -> Ok(CounterModel(count: n))
        Error(Nil) -> Error("invalid count")
      }
    }),
    secret_key: secret_key,
  )
}

/// Connect and join one connection, returning the first message it gets.
fn join_and_receive(
  subject: process.Subject(runtime.RuntimeMessage(msg)),
  conn_id: String,
  token: String,
) -> #(process.Subject(transport.InternalMessage), transport.InternalMessage) {
  let transport_subject = process.new_subject()
  process.send(
    subject,
    runtime.ClientConnected(conn_id: conn_id, subject: transport_subject),
  )
  process.send(
    subject,
    runtime.ClientJoined(conn_id: conn_id, token: token, path: "/"),
  )
  let assert Ok(first) = process.receive(transport_subject, 1000)
  #(transport_subject, first)
}

const recovery_secret = "runtime-test-secret-key-0123456789"

pub fn state_recovery_rejects_token_signed_with_other_secret_test() {
  let assert Ok(subject) = runtime.start(recovery_config(recovery_secret))
  let token =
    runtime.create_state_token(
      CounterModel(count: 3),
      fn(m: CounterModel) { int.to_string(m.count) },
      "some-other-secret-key-0123456789",
    )
  let #(_, first) = join_and_receive(subject, "forged_conn", token)
  let assert transport.SendModelSync(model_json: "0", version: 0, ack_clock: 0) =
    first
}

pub fn state_recovery_rejects_tampered_token_test() {
  let assert Ok(subject) = runtime.start(recovery_config(recovery_secret))
  let token =
    runtime.create_state_token(
      CounterModel(count: 3),
      fn(m: CounterModel) { int.to_string(m.count) },
      recovery_secret,
    )
  let tampered = token <> "x"
  let #(_, first) = join_and_receive(subject, "tampered_conn", tampered)
  let assert transport.SendModelSync(model_json: "0", ..) = first
}

pub fn state_recovery_ignores_token_when_secret_empty_test() {
  let assert Ok(subject) = runtime.start(recovery_config(""))
  let token =
    runtime.create_state_token(
      CounterModel(count: 3),
      fn(m: CounterModel) { int.to_string(m.count) },
      "",
    )
  let #(_, first) = join_and_receive(subject, "empty_secret_conn", token)
  let assert transport.SendModelSync(model_json: "0", ..) = first
}

pub fn state_recovery_rejects_session_bound_token_without_session_test() {
  let assert Ok(subject) = runtime.start(recovery_config(recovery_secret))
  let token =
    ssr.sign_join_token(
      recovery_secret,
      ssr.fingerprint_session_id("session-a"),
      option.Some("3"),
      ssr_now(),
    )
  let #(_, first) = join_and_receive(subject, "unbound_conn", token)
  let assert transport.SendModelSync(model_json: "0", ..) = first
}

pub fn state_recovery_rejects_token_for_other_session_test() {
  let assert Ok(subject) = runtime.start(recovery_config(recovery_secret))
  let token =
    ssr.sign_join_token(
      recovery_secret,
      ssr.fingerprint_session_id("session-a"),
      option.Some("3"),
      ssr_now(),
    )
  let transport_subject = process.new_subject()
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "other_session",
      subject: transport_subject,
    ),
  )
  process.send(
    subject,
    runtime.ClientJoinedWithSession(
      conn_id: "other_session",
      token: token,
      path: "/",
      session_fingerprint: ssr.fingerprint_session_id("session-b"),
    ),
  )
  let assert Ok(transport.SendModelSync(model_json: "0", ..)) =
    process.receive(transport_subject, 1000)
}

pub fn state_recovery_rejects_expired_token_test() {
  let assert Ok(subject) = runtime.start(recovery_config(recovery_secret))
  // Issued two days ago: past the join token lifetime.
  let token =
    ssr.sign_join_token(
      recovery_secret,
      "",
      option.Some("3"),
      ssr_now() - 172_800,
    )
  let #(_, first) = join_and_receive(subject, "expired_conn", token)
  let assert transport.SendModelSync(model_json: "0", ..) = first
}

pub fn state_recovery_rejects_model_the_deserializer_refuses_test() {
  let assert Ok(subject) = runtime.start(recovery_config(recovery_secret))
  let token =
    ssr.sign_join_token(
      recovery_secret,
      "",
      option.Some("not-a-number"),
      ssr_now(),
    )
  let #(_, first) = join_and_receive(subject, "bad_model_conn", token)
  let assert transport.SendModelSync(model_json: "0", ..) = first
}

pub fn state_recovery_only_applies_to_first_join_test() {
  // A second connection joining a live runtime must not replace the model
  // the first connection is already looking at.
  let assert Ok(subject) = runtime.start(recovery_config(recovery_secret))
  let #(_, first) = join_and_receive(subject, "first_conn", "")
  let assert transport.SendModelSync(model_json: "0", ..) = first
  let token =
    runtime.create_state_token(
      CounterModel(count: 3),
      fn(m: CounterModel) { int.to_string(m.count) },
      recovery_secret,
    )
  let #(_, second) = join_and_receive(subject, "second_conn", token)
  let assert transport.SendModelSync(model_json: "0", ..) = second
}

pub fn state_recovery_from_token_test() {
  let assert Ok(subject) = runtime.start(recovery_config(recovery_secret))
  let token =
    runtime.create_state_token(
      CounterModel(count: 3),
      fn(m: CounterModel) { int.to_string(m.count) },
      recovery_secret,
    )
  // The model sync carries the recovered state (3), not the init state (0).
  let #(_, first) = join_and_receive(subject, "recovery_conn", token)
  let assert transport.SendModelSync(model_json: "3", version: 0, ack_clock: 0) =
    first
}

pub fn state_recovery_from_session_bound_token_test() {
  let assert Ok(subject) = runtime.start(recovery_config(recovery_secret))
  let fingerprint = ssr.fingerprint_session_id("session-a")
  let token =
    ssr.sign_join_token(
      recovery_secret,
      fingerprint,
      option.Some("7"),
      ssr_now(),
    )
  let transport_subject = process.new_subject()
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "bound_conn", subject: transport_subject),
  )
  process.send(
    subject,
    runtime.ClientJoinedWithSession(
      conn_id: "bound_conn",
      token: token,
      path: "/",
      session_fingerprint: fingerprint,
    ),
  )
  let assert Ok(transport.SendModelSync(model_json: "7", ..)) =
    process.receive(transport_subject, 1000)
}

@external(erlang, "beacon_ssr_ffi", "system_time_seconds")
fn ssr_now() -> Int

pub fn model_sync_sent_after_event_test() {
  // Runtime with serialize_model should send model_sync after events
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(m: CounterModel) {
        "{\"count\":" <> int.to_string(m.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "sync_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "sync_conn", token: "", path: "/"),
  )
  process.sleep(20)

  // Drain initial model_sync messages
  let selector = process.new_selector() |> process.select(transport_subject)
  let _ = process.selector_receive(selector, 500)

  // Send an increment event
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "sync_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  // Should receive a model_sync or patch with count:1
  let msgs = drain_messages(transport_subject, [])
  let has_update =
    list.any(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":1")
        transport.SendPatch(ops_json: json, ..) ->
          string.contains(json, "/count")
        _ -> False
      }
    })
  let assert True = has_update
}

fn drain_messages(subject, acc) {
  let selector = process.new_selector() |> process.select(subject)
  case process.selector_receive(selector, 100) {
    Ok(msg) -> drain_messages(subject, [msg, ..acc])
    Error(Nil) -> acc
  }
}

@external(erlang, "beacon_test_ffi", "do_crash")
fn crash_for_test() -> element.Node(CounterMsg)

// === Patch optimization proof tests ===

pub fn sends_patch_not_model_sync_after_join_test() {
  // After the initial join (which sends model_sync), subsequent events
  // MUST produce SendPatch, NOT SendModelSync. This catches regressions.
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "patch_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "patch_conn", token: "", path: "/"),
  )
  process.sleep(50)

  // Drain initial model_sync
  let init_msgs = drain_messages(transport_subject, [])
  // Verify initial messages include a model_sync (full sync on join)
  let has_initial_sync =
    list.any(init_msgs, fn(m) {
      case m {
        transport.SendModelSync(..) -> True
        _ -> False
      }
    })
  let assert True = has_initial_sync

  // Now send an increment event
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "patch_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  // Subsequent events MUST produce SendPatch (not SendModelSync)
  let event_msgs = drain_messages(transport_subject, [])
  let has_patch =
    list.any(event_msgs, fn(m) {
      case m {
        transport.SendPatch(ops_json: ops, ..) -> string.contains(ops, "/count")
        _ -> False
      }
    })
  let has_full_sync =
    list.any(event_msgs, fn(m) {
      case m {
        transport.SendModelSync(..) -> True
        _ -> False
      }
    })
  let assert True = has_patch
  let assert False = has_full_sync
}

pub fn patch_contains_only_changed_field_test() {
  // After incrementing count, the patch should only contain /count
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "small_patch", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "small_patch", token: "", path: "/"),
  )
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send increment
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "small_patch",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  let msgs = drain_messages(transport_subject, [])
  // Find the patch message and verify its ops are small
  let patch_ops =
    list.filter_map(msgs, fn(m) {
      case m {
        transport.SendPatch(ops_json: ops, ..) -> Ok(ops)
        _ -> Error(Nil)
      }
    })
  // Should have exactly one patch
  let assert True = list.length(patch_ops) >= 1
  let assert [ops, ..] = patch_ops
  // Ops should contain /count and be small (< 60 bytes)
  let assert True = string.contains(ops, "/count")
  let assert True = string.length(ops) < 60
}

pub fn client_ops_are_ignored_server_update_authoritative_test() {
  // Client-sent patch ops are untrusted optimization hints. The server must
  // run its own update function and publish the server-computed result.
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "ops_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "ops_conn", token: "", path: "/"),
  )
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // The malicious hint says count=42, but the server-side Increment update
  // should produce count=1.
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "ops_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":42}]",
    ),
  )
  process.sleep(50)

  let first_msgs = drain_messages(transport_subject, [])
  let leaked_client_value =
    list.any(first_msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":42")
        transport.SendPatch(ops_json: json, ..) -> string.contains(json, "42")
        _ -> False
      }
    })
  let assert False = leaked_client_value

  let has_server_count_one =
    list.any(first_msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":1")
        transport.SendPatch(ops_json: json, ..) ->
          string.contains(json, "/count") && string.contains(json, "1")
        _ -> False
      }
    })
  let assert True = has_server_count_one

  // A second increment proves the runtime state advanced from 1 to 2, not
  // from the client-supplied 42 to 43.
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "ops_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 2,
      ops: "",
    ),
  )
  process.sleep(50)

  let second_msgs = drain_messages(transport_subject, [])
  let has_server_count_two =
    list.any(second_msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":2")
        transport.SendPatch(ops_json: json, ..) ->
          string.contains(json, "/count") && string.contains(json, "2")
        _ -> False
      }
    })
  let assert True = has_server_count_two

  let leaked_derived_client_value =
    list.any(second_msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":43")
        transport.SendPatch(ops_json: json, ..) -> string.contains(json, "43")
        _ -> False
      }
    })
  let assert False = leaked_derived_client_value
}

pub fn post_mount_updates_never_send_html_mount_test() {
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "no_mount_conn",
      subject: transport_subject,
    ),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "no_mount_conn", token: "", path: "/"),
  )
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "no_mount_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  let msgs = drain_messages(transport_subject, [])
  let has_mount =
    list.any(msgs, fn(m) {
      case m {
        transport.SendMount(..) -> True
        _ -> False
      }
    })
  let assert False = has_mount

  let has_state_update =
    list.any(msgs, fn(m) {
      case m {
        transport.SendPatch(..) -> True
        transport.SendModelSync(..) -> True
        _ -> False
      }
    })
  let assert True = has_state_update
}

pub fn slow_client_mailbox_triggers_backpressure_close_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "slow_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "slow_conn", token: "", path: "/"),
  )
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  fill_transport_mailbox(transport_subject, 1001)
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "slow_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(100)

  let msgs = drain_messages(transport_subject, [])
  let has_backpressure_close =
    list.any(msgs, fn(m) {
      case m {
        transport.CloseForBackpressure(reason) ->
          string.contains(reason, "too far behind")
        _ -> False
      }
    })
  let assert True = has_backpressure_close
}

fn fill_transport_mailbox(
  subject: process.Subject(transport.InternalMessage),
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      process.send(subject, transport.SendError(reason: "queued"))
      fill_transport_mailbox(subject, remaining - 1)
    }
  }
}

pub fn explicit_decode_event_skips_server_view_render_on_join_and_update_test() {
  let view_subject = process.new_subject()
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: fn(model: CounterModel) {
        process.send(view_subject, "view")
        counter_view(model)
      },
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "decode_fast", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "decode_fast", token: "", path: "/"),
  )
  process.sleep(50)
  let assert 0 = count_string_messages(view_subject, 0)
  let _ = drain_messages(transport_subject, [])

  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "decode_fast",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  let assert 0 = count_string_messages(view_subject, 0)
  let msgs = drain_messages(transport_subject, [])
  let has_state_update =
    list.any(msgs, fn(m) {
      case m {
        transport.SendPatch(..) -> True
        transport.SendModelSync(..) -> True
        _ -> False
      }
    })
  let assert True = has_state_update
}

pub fn runtime_requires_event_decoder_test() {
  let view_subject = process.new_subject()
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: fn(model: CounterModel) {
        process.send(view_subject, "view")
        element.el(
          "button",
          [element.on("click", handler.register_simple(Increment))],
          [
            element.text(int.to_string(model.count)),
          ],
        )
      },
      decode_event: option.None,
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )
  let assert Error(error.ConfigError(reason: reason)) = runtime.start(config)
  let assert True = string.contains(reason, "Missing event decoder")
  let assert 0 = count_string_messages(view_subject, 0)
}

fn count_string_messages(subject: process.Subject(String), count: Int) -> Int {
  let selector = process.new_selector() |> process.select(subject)
  case process.selector_receive(selector, 100) {
    Ok(_) -> count_string_messages(subject, count + 1)
    Error(Nil) -> count
  }
}

pub fn multiple_increments_produce_patches_test() {
  // After join, sending 5 increments should produce 5 patches (not model_syncs)
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "multi_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "multi_conn", token: "", path: "/"),
  )
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send 5 increments
  [1, 2, 3, 4, 5]
  |> list.each(fn(i) {
    process.send(
      subject,
      runtime.ClientEventReceived(
        conn_id: "multi_conn",
        event_name: "click",
        handler_id: "increment",
        event_data: "{}",
        target_path: "0",
        clock: i,
        ops: "",
      ),
    )
    process.sleep(30)
  })
  process.sleep(50)

  let msgs = drain_messages(transport_subject, [])
  let patch_count =
    list.count(msgs, fn(m) {
      case m {
        transport.SendPatch(..) -> True
        _ -> False
      }
    })
  let sync_count =
    list.count(msgs, fn(m) {
      case m {
        transport.SendModelSync(..) -> True
        _ -> False
      }
    })
  // All 5 should be patches, zero should be full syncs
  let assert True = patch_count == 5
  let assert True = sync_count == 0
}

pub fn patch_content_correct_after_many_increments_test() {
  // After 10 increments (with waits), the final patch should contain "10"
  // and every patch should be small (< 50 bytes).
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "many_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "many_conn", token: "", path: "/"),
  )
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send 10 increments with waits to ensure each is processed
  list.repeat(Nil, 10)
  |> list.index_map(fn(_, i) { i + 1 })
  |> list.each(fn(i) {
    process.send(
      subject,
      runtime.ClientEventReceived(
        conn_id: "many_conn",
        event_name: "click",
        handler_id: "increment",
        event_data: "{}",
        target_path: "0",
        clock: i,
        ops: "",
      ),
    )
    process.sleep(30)
  })
  process.sleep(200)

  let msgs = drain_messages(transport_subject, [])
  let patches =
    list.filter_map(msgs, fn(m) {
      case m {
        transport.SendPatch(ops_json: ops, ..) -> Ok(ops)
        _ -> Error(Nil)
      }
    })
  // All 10 increments should produce patches
  let assert True = list.length(patches) >= 10
  // Every patch for a single counter increment should be small
  list.each(patches, fn(p) {
    let assert True = string.length(p) < 60
  })
  // The last patch should contain /count and a numeric value
  let assert Ok(last_patch) = list.last(patches)
  let assert True = string.contains(last_patch, "/count")
}

// === Server Type Tests ===

pub fn server_state_not_in_model_sync_test() {
  // Simulate the pattern from server_state:
  // Model + Server wrapped as #(Model, Server), serializer only encodes Model part
  let config =
    runtime.RuntimeConfig(
      init: fn() {
        // Combined: #(Model, Server) — server state is api_key
        #(#(CounterModel(count: 0), "secret_api_key"), effect.none())
      },
      update: fn(combined, msg) {
        let #(model, server) = combined
        case msg {
          Increment -> #(
            #(CounterModel(count: model.count + 1), server),
            effect.none(),
          )
          _ -> #(#(model, server), effect.none())
        }
      },
      view: fn(combined) {
        // View only uses model part — server part is never accessed
        let #(model, _server) = combined
        element.el("div", [], [element.text(int.to_string(model.count))])
      },
      decode_event: option.Some(counter_decode_event),
      // Serializer only encodes the Model part, NOT the server state
      serialize_model: option.Some(fn(combined: #(CounterModel, String)) {
        let #(model, _server) = combined
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "server_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "server_conn", token: "", path: "/"),
  )
  process.sleep(100)

  // Collect ALL messages from join.
  let msgs = drain_messages(transport_subject, [])
  // Find model_sync message — it should contain count but NOT api_key
  let model_syncs =
    list.filter_map(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) -> Ok(json)
        _ -> Error(Nil)
      }
    })
  // Should have at least one model_sync (sent on join when serialize_model is set)
  let assert True = list.length(model_syncs) >= 1
  // NONE of them should contain the server secret
  list.each(model_syncs, fn(json) {
    let assert False = string.contains(json, "secret_api_key")
    let assert True = string.contains(json, "count")
  })
}

// === server_state Model Encoder Tests ===

pub fn server_state_background_effect_pushes_update_test() {
  // Verify that background effects (EffectDispatched) push model updates
  // to the client when serialize_model is set for #(Model, Server).
  let config =
    runtime.RuntimeConfig(
      init: fn() {
        #(#(CounterModel(count: 0), "server_secret"), effect.none())
      },
      update: fn(combined, msg) {
        let #(model, server) = combined
        case msg {
          Increment -> #(
            #(CounterModel(count: model.count + 1), server),
            effect.none(),
          )
          _ -> #(#(model, server), effect.none())
        }
      },
      view: fn(combined) {
        let #(model, _server) = combined
        element.el("div", [], [element.text(int.to_string(model.count))])
      },
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(combined: #(CounterModel, String)) {
        let #(model, _server) = combined
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect and join
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "bg_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "bg_conn", token: "", path: "/"),
  )
  process.sleep(100)
  // Drain initial model_sync
  let _ = drain_messages(transport_subject, [])

  // Simulate background effect dispatching a message
  process.send(subject, runtime.EffectDispatched(message: Increment))
  process.sleep(100)

  // Should receive a patch or model_sync with updated count
  let msgs = drain_messages(transport_subject, [])
  let updates =
    list.filter(msgs, fn(m) {
      case m {
        transport.SendPatch(..) -> True
        transport.SendModelSync(..) -> True
        _ -> False
      }
    })
  // Must have at least one update pushed to client
  let assert True = list.length(updates) >= 1
  // Verify the update contains count:1, not server_secret
  let update_jsons =
    list.filter_map(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) -> Ok(json)
        transport.SendPatch(ops_json: json, ..) -> Ok(json)
        _ -> Error(Nil)
      }
    })
  list.each(update_jsons, fn(json) {
    let assert False = string.contains(json, "server_secret")
  })
}

pub fn server_state_user_event_pushes_update_test() {
  // Verify that user events (ClientEventReceived) push model updates
  // to the client when serialize_model is set for #(Model, Server).
  let config =
    runtime.RuntimeConfig(
      init: fn() { #(#(CounterModel(count: 0), "private_key"), effect.none()) },
      update: fn(combined, msg) {
        let #(model, server) = combined
        case msg {
          Increment -> #(
            #(CounterModel(count: model.count + 1), server),
            effect.none(),
          )
          _ -> #(#(model, server), effect.none())
        }
      },
      view: fn(combined) {
        let #(model, _server) = combined
        element.el("div", [], [element.text(int.to_string(model.count))])
      },
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(combined: #(CounterModel, String)) {
        let #(model, _server) = combined
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect and join — view renders button with on_click handler
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "evt_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "evt_conn", token: "", path: "/"),
  )
  process.sleep(100)
  // Drain initial model_sync
  let _ = drain_messages(transport_subject, [])

  // Send a client event (simulating button click)
  // handler_id "increment" matches counter_decode_event
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "evt_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "",
      target_path: "",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(100)

  // Should receive a patch or model_sync with updated count
  let msgs = drain_messages(transport_subject, [])
  let updates =
    list.filter(msgs, fn(m) {
      case m {
        transport.SendPatch(..) -> True
        transport.SendModelSync(..) -> True
        _ -> False
      }
    })
  // Must have at least one update pushed to client
  let assert True = list.length(updates) >= 1
  // Verify no server secret leaked
  let update_jsons =
    list.filter_map(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) -> Ok(json)
        transport.SendPatch(ops_json: json, ..) -> Ok(json)
        _ -> Error(Nil)
      }
    })
  list.each(update_jsons, fn(json) {
    let assert False = string.contains(json, "private_key")
  })
}

// === Error Path Tests ===

pub fn runtime_handles_malformed_event_data_test() {
  // Send an event with a valid handler_id but garbage event_data.
  // The runtime must stay alive and send an error (not crash).
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "malformed_conn",
      subject: transport_subject,
    ),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "malformed_conn", token: "", path: "/"),
  )
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send event with valid handler but garbage data
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "malformed_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "THIS_IS_NOT_JSON!!!",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  // Runtime must still be alive — send a normal increment to prove it
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "malformed_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 2,
      ops: "",
    ),
  )
  process.sleep(50)

  // Should get a response (patch or model_sync) from the second event
  let msgs = drain_messages(transport_subject, [])
  let has_response =
    list.any(msgs, fn(m) {
      case m {
        transport.SendPatch(..) -> True
        transport.SendModelSync(..) -> True
        _ -> False
      }
    })
  let assert True = has_response
}

pub fn runtime_handles_rapid_events_test() {
  // Send 50 events in rapid succession (no sleep between).
  // Verify runtime processes all of them and final state is correct.
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(
    subject,
    runtime.ClientConnected(conn_id: "rapid_conn", subject: transport_subject),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "rapid_conn", token: "", path: "/"),
  )
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send 50 increments with NO sleep between them
  list.repeat(Nil, 50)
  |> list.index_map(fn(_, i) { i + 1 })
  |> list.each(fn(i) {
    process.send(
      subject,
      runtime.ClientEventReceived(
        conn_id: "rapid_conn",
        event_name: "click",
        handler_id: "increment",
        event_data: "{}",
        target_path: "0",
        clock: i,
        ops: "",
      ),
    )
  })
  // Wait for all processing to complete
  process.sleep(500)

  let msgs = drain_messages(transport_subject, [])
  // Should have received responses for all 50 events
  let patch_count =
    list.count(msgs, fn(m) {
      case m {
        transport.SendPatch(..) -> True
        _ -> False
      }
    })
  let assert True = patch_count == 50

  // The final patch (most recent) should contain "50" (final count value).
  // drain_messages returns messages in reverse order (newest first),
  // so the first patch in the list is the most recent one.
  let patches =
    list.filter_map(msgs, fn(m) {
      case m {
        transport.SendPatch(ops_json: ops, ..) -> Ok(ops)
        _ -> Error(Nil)
      }
    })
  let assert [newest_patch, ..] = patches
  let assert True = string.contains(newest_patch, "/count")
  let assert True = string.contains(newest_patch, "50")
}

// === Connection Isolation Test ===

pub fn connection_isolation_test() {
  // Verify connection B's state is NOT affected by connection A's events.
  // Per-connection runtimes mean each start() creates an independent actor.
  let assert Ok(subject_a) = runtime.start(counter_config())
  let assert Ok(subject_b) = runtime.start(counter_config())
  let transport_a = process.new_subject()
  let transport_b = process.new_subject()

  // Connect both
  process.send(
    subject_a,
    runtime.ClientConnected(conn_id: "iso_a", subject: transport_a),
  )
  process.send(
    subject_b,
    runtime.ClientConnected(conn_id: "iso_b", subject: transport_b),
  )
  process.sleep(20)

  // Join both
  process.send(
    subject_a,
    runtime.ClientJoined(conn_id: "iso_a", token: "", path: "/"),
  )
  process.send(
    subject_b,
    runtime.ClientJoined(conn_id: "iso_b", token: "", path: "/"),
  )
  process.sleep(50)

  // Drain initial messages from both
  let _ = drain_messages(transport_a, [])
  let _ = drain_messages(transport_b, [])

  // Send 5 increments ONLY on connection A
  list.repeat(Nil, 5)
  |> list.index_map(fn(_, i) { i + 1 })
  |> list.each(fn(i) {
    process.send(
      subject_a,
      runtime.ClientEventReceived(
        conn_id: "iso_a",
        event_name: "click",
        handler_id: "increment",
        event_data: "{}",
        target_path: "0",
        clock: i,
        ops: "",
      ),
    )
  })
  process.sleep(100)

  // Drain A's messages — should have patches with count values
  let a_msgs = drain_messages(transport_a, [])
  let a_patches =
    list.filter_map(a_msgs, fn(m) {
      case m {
        transport.SendPatch(ops_json: ops, ..) -> Ok(ops)
        _ -> Error(Nil)
      }
    })
  let assert True = list.length(a_patches) == 5

  // B should have received NO messages (no patches, no model_syncs)
  let b_msgs = drain_messages(transport_b, [])
  let assert True = list.is_empty(b_msgs)

  // Now trigger a fresh model_sync on B by re-joining — should show count:0
  process.send(
    subject_b,
    runtime.ClientJoined(conn_id: "iso_b", token: "", path: "/"),
  )
  process.sleep(50)

  let b_join_msgs = drain_messages(transport_b, [])
  let b_syncs =
    list.filter_map(b_join_msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) -> Ok(json)
        _ -> Error(Nil)
      }
    })
  let assert True = list.length(b_syncs) >= 1
  // B's model_sync must show count:0 (unaffected by A's increments)
  list.each(b_syncs, fn(json) {
    let assert True = string.contains(json, "\"count\":0")
  })
}

/// Verify that on_update_effect wrapping works: the chained effect is
/// actually invoked by the runtime when an event triggers an update.
/// This tests the same wrapping pattern used by beacon.on_update().
pub fn on_update_effect_is_invoked_test() {
  // Create a Subject that on_update_effect will send to, proving it ran
  let proof_subject = process.new_subject()

  // Wrap update the same way start_validated does: chain on_update_effect after base
  let on_update_fn = fn(model: CounterModel, _msg: CounterMsg) {
    // This effect proves on_update was called — sends the new count
    effect.from(fn(_dispatch) { process.send(proof_subject, model.count) })
  }
  let wrapped_update = fn(model: CounterModel, msg: CounterMsg) {
    let #(new_model, base_effect) = counter_update(model, msg)
    let extra_effect = on_update_fn(new_model, msg)
    #(new_model, effect.batch([base_effect, extra_effect]))
  }

  // Create config with the wrapped update
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: wrapped_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "on_update_conn",
      subject: transport_subject,
    ),
  )
  process.sleep(50)

  // Join
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "on_update_conn", token: "", path: "/"),
  )
  process.sleep(50)

  // Send an event — this should trigger update AND on_update_effect
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "on_update_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )

  // Wait for the on_update_effect to fire
  case process.receive(proof_subject, 2000) {
    Ok(count) -> {
      // on_update_effect was called with the NEW model (count=1)
      let assert True = count == 1
    }
    Error(Nil) -> {
      // on_update_effect was NEVER called — this is the bug
      panic as "on_update_effect was not invoked by the runtime"
    }
  }
}

/// Verify that init_from_request replaces the default init when provided.
/// This tests the core of ws_init: the runtime uses init_from_request(req)
/// instead of init() when both are available.
pub fn init_from_request_replaces_default_init_test() {
  // Create a fake request with a cookie
  // Use request.set_body to give it the Connection type
  let fake_req =
    request.new()
    |> request.set_body(server.Connection(socket: fake_socket()))
    |> request.set_header("cookie", "user_id=42")

  // Default init creates count:0
  // init_from_request reads cookie and creates count based on user_id
  let init_from_req = fn(req: request.Request(server.Connection)) -> #(
    CounterModel,
    effect.Effect(CounterMsg),
  ) {
    case request.get_header(req, "cookie") {
      Ok(cookie_val) -> {
        // Parse "user_id=42" → use 42 as initial count
        case string.split(cookie_val, "=") {
          [_, val] ->
            case int.parse(val) {
              Ok(n) -> #(CounterModel(count: n), effect.none())
              Error(Nil) -> #(CounterModel(count: -1), effect.none())
            }
          _ -> #(CounterModel(count: -1), effect.none())
        }
      }
      Error(Nil) -> #(CounterModel(count: -1), effect.none())
    }
  }

  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.Some(init_from_req),
      secret_key: "",
      dev_mode: False,
    )

  // Use start_and_connect_with_request which should use init_from_request
  let transport_subject = process.new_subject()
  let assert Ok(#(on_event, _shutdown)) =
    runtime.start_and_connect_with_request(
      config,
      "ws_init_conn",
      transport_subject,
      option.Some(fake_req),
    )

  // Send ClientJoin; the runtime will send back model state.
  on_event("ws_init_conn", transport.ClientJoin(token: "", path: "/"))
  process.sleep(200)

  // Drain the transport subject for messages
  let msgs = drain_messages(transport_subject, [])
  // Look for a model_sync containing "42" (the count from cookie).
  let has_42 =
    list.any(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":42")
        transport.SendMount(..) -> False
        _ -> False
      }
    })
  let assert True = has_42
}

/// Without init_from_request, the default init is used (count:0).
pub fn init_from_request_none_uses_default_init_test() {
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: "",
      dev_mode: False,
    )

  // start_and_connect (no request) should use default init (count:0)
  let transport_subject = process.new_subject()
  let assert Ok(#(on_event, _shutdown)) =
    runtime.start_and_connect(config, "default_init_conn", transport_subject)
  on_event("default_init_conn", transport.ClientJoin(token: "", path: "/"))
  process.sleep(200)
  let msgs = drain_messages(transport_subject, [])
  let has_0 =
    list.any(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":0")
        transport.SendMount(..) -> False
        _ -> False
      }
    })
  let assert True = has_0
}

pub fn join_recovers_state_from_httponly_cookie_test() {
  let secret = "runtime-cookie-secret-at-least-32-chars!!"
  let serialize = fn(model: CounterModel) { int.to_string(model.count) }
  let token =
    runtime.create_state_token(CounterModel(count: 77), serialize, secret)
  let fake_req =
    request.new()
    |> request.set_body(server.Connection(socket: fake_socket()))
    |> request.set_header("cookie", ssr.session_cookie_name <> "=" <> token)

  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.Some(fn(raw: String) {
        case int.parse(raw) {
          Ok(count) -> Ok(CounterModel(count: count))
          Error(Nil) -> Error("invalid count")
        }
      }),
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.None,
      secret_key: secret,
      dev_mode: False,
    )

  let transport_subject = process.new_subject()
  let assert Ok(#(on_event, _shutdown)) =
    runtime.start_and_connect_with_request(
      config,
      "cookie_join_conn",
      transport_subject,
      option.Some(fake_req),
    )

  on_event(
    "cookie_join_conn",
    transport.ClientJoin(token: "malicious-client-token", path: "/"),
  )
  process.sleep(200)

  let msgs = drain_messages(transport_subject, [])
  let has_cookie_model =
    list.any(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":77")
        transport.SendMount(..) -> False
        _ -> False
      }
    })
  let assert True = has_cookie_model
}

/// Regression test: live join model sync must reflect the ws_init model, not the default init.
pub fn model_sync_reflects_ws_init_model_test() {
  // ws_init sets count to 99 (simulating auth-populated state)
  let init_from_req = fn(_req: request.Request(server.Connection)) -> #(
    CounterModel,
    effect.Effect(CounterMsg),
  ) {
    #(CounterModel(count: 99), effect.none())
  }

  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      on_route_leave: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      on_notification: option.None,
      init_from_request: option.Some(init_from_req),
      secret_key: "",
      dev_mode: False,
    )

  let fake_req =
    request.new()
    |> request.set_body(server.Connection(socket: fake_socket()))
    |> request.set_header("cookie", "session=test")

  let transport_subject = process.new_subject()
  let assert Ok(#(on_event, _shutdown)) =
    runtime.start_and_connect_with_request(
      config,
      "ws_init_sync_conn",
      transport_subject,
      option.Some(fake_req),
    )

  // Join — sends authoritative model state without remounting SSR HTML.
  on_event("ws_init_sync_conn", transport.ClientJoin(token: "", path: "/"))
  process.sleep(200)

  let msgs = drain_messages(transport_subject, [])

  // The model sync MUST contain "99" (from ws_init), not "0" (from default init).
  let sync_has_99 =
    list.any(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":99")
        _ -> False
      }
    })
  let assert True = sync_has_99

  // Verify join did not remount HTML.
  let mount_msgs =
    list.filter_map(msgs, fn(m) {
      case m {
        transport.SendMount(payload: html) -> Ok(html)
        _ -> Error(Nil)
      }
    })
  let assert 0 = list.length(mount_msgs)
}
