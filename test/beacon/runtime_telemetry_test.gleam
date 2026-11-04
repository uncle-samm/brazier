/// Telemetry emitted by the session runtime: the `mount`, `handle_event`,
/// `navigate` and `render` spans and the `[beacon, runtime, stop]` event.
///
/// Every span carries `route` (the page route pattern), `event` (the
/// message's constructor name in snake_case, as the BEAM names it, so
/// `SetCount(9)` is `"set_count"`; or `"mount"` or `"unknown"`) and
/// `connection_id`. Handlers forward to a subject owned by the test and the
/// tests synchronize on those events; nothing sleeps.
import beacon/effect
import beacon/error
import beacon/internal/context
import beacon/runtime
import beacon/telemetry.{type Event}
import beacon/transport
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/uri

// --- Apps -------------------------------------------------------------------

pub type Model {
  Model(count: Int, page: String)
}

pub type Msg {
  Increment
  SetCount(Int)
  Visit(page: String)
}

fn context_for(path: String) -> context.Context {
  let assert Ok(parsed) = uri.parse(path)
  context.new(
    uri: uri.Uri(
      ..uri.empty,
      scheme: option.Some("http"),
      host: option.Some("localhost"),
      path: parsed.path,
      query: parsed.query,
    ),
    cookies: [],
    is_connected: True,
    session_id: Error(Nil),
  )
}

fn parse_page(page_uri: uri.Uri) -> Result(Msg, Nil) {
  case uri.path_segments(page_uri.path) {
    [] -> Ok(Visit("home"))
    ["settings"] -> Ok(Visit("settings"))
    _ -> Error(Nil)
  }
}

fn config(
  route: Option(fn(uri.Uri) -> Result(Msg, Nil)),
) -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(count: 0, page: ""), effect.none())) },
    update: fn(model: Model, msg: Msg) {
      case msg {
        Increment -> #(Model(..model, count: model.count + 1), effect.none())
        SetCount(n) -> #(Model(..model, count: n), effect.none())
        Visit(page) -> #(Model(..model, page: page), effect.none())
      }
    },
    encode_model: fn(model: Model) {
      "{\"count\":"
      <> int.to_string(model.count)
      <> ",\"page\":\""
      <> model.page
      <> "\"}"
    },
    decode_event: fn(_name, handler_id, _data, _path) {
      case handler_id {
        "increment" -> Ok(Increment)
        _ ->
          Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
      }
    },
    restore_model: option.None,
    route: route,
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    secret_key: "",
    presence: option.None,
    title: option.None,
  )
}

type Session {
  Session(
    runtime: Subject(runtime.RuntimeMessage(Msg)),
    transport: Subject(transport.InternalMessage),
    conn_id: String,
  )
}

/// Start a runtime at "/" and join one connection, waiting for its first
/// sync so later events are the test's own.
fn joined(route: Option(fn(uri.Uri) -> Result(Msg, Nil))) -> Session {
  let conn_id = "rt_telemetry_" <> int.to_string(unique_integer())
  let assert Ok(subject) = runtime.start(config(route), context_for("/"))
    as "the test runtime must start"
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
    process.receive(transport_subject, 2000)
    as "a joined connection receives the model"
  Session(runtime: subject, transport: transport_subject, conn_id: conn_id)
}

fn click(session: Session, handler_id: String) -> Nil {
  process.send(
    session.runtime,
    runtime.ClientEventReceived(
      conn_id: session.conn_id,
      event_name: "click",
      handler_id: handler_id,
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
}

// --- Event helpers ----------------------------------------------------------

fn span_events(kind: String) -> List(List(String)) {
  list.map(["start", "stop", "exception"], fn(suffix) {
    ["beacon", "runtime", kind, suffix]
  })
}

fn runtime_events() -> List(List(String)) {
  list.flatten([
    span_events("mount"),
    span_events("handle_event"),
    span_events("navigate"),
    span_events("render"),
    [["beacon", "runtime", "stop"]],
  ])
}

fn listen() -> #(String, Subject(Event)) {
  let assert Ok(Nil) = telemetry.start()
  let id = "runtime_telemetry_" <> int.to_string(unique_integer())
  let events = process.new_subject()
  let assert Ok(Nil) =
    telemetry.attach(id, runtime_events(), fn(event) {
      process.send(events, event)
    })
  #(id, events)
}

/// The first event matching `matches`; others are skipped.
fn expect(events: Subject(Event), matches: fn(Event) -> Bool) -> Event {
  let assert Ok(event) = process.receive(events, 2000)
    as "expected telemetry event did not arrive within 2s"
  case matches(event) {
    True -> event
    False -> expect(events, matches)
  }
}

/// The next `[beacon, runtime, kind, stop]` for `connection_id`.
fn stop_of(
  events: Subject(Event),
  kind: String,
  connection_id: String,
) -> Event {
  expect(events, fn(event) {
    event.name == ["beacon", "runtime", kind, "stop"]
    && telemetry.string(event, "connection_id") == Ok(connection_id)
  })
}

fn assert_tags(event: Event, label: String, connection_id: String) -> Nil {
  let assert Ok("/*") = telemetry.string(event, "route")
  let assert Ok(event_label) = telemetry.string(event, "event")
  let assert True = event_label == label
  let assert Ok(conn) = telemetry.string(event, "connection_id")
  let assert True = conn == connection_id
  let assert Ok(duration) = telemetry.int(event, "duration")
  let assert True = duration >= 0
  Nil
}

fn patch_bytes(event: Event) -> Int {
  let assert Ok(bytes) = telemetry.int(event, "patch_bytes")
    as "a render stop carries patch_bytes"
  bytes
}

fn shutdown(id: String, session: Session) -> Nil {
  process.send(session.runtime, runtime.Shutdown)
  let assert Ok(Nil) = telemetry.detach(id)
  Nil
}

// --- mount ------------------------------------------------------------------

pub fn mount_is_a_span_without_a_connection_test() {
  let #(id, events) = listen()
  let assert Ok(subject) = runtime.start(config(option.None), context_for("/"))
    as "the test runtime must start"
  let start =
    expect(events, fn(e) { e.name == ["beacon", "runtime", "mount", "start"] })
  let assert Ok("mount") = telemetry.string(start, "event")
  let stop = stop_of(events, "mount", "none")
  assert_tags(stop, "mount", "none")
  process.send(subject, runtime.Shutdown)
  let assert Ok(Nil) = telemetry.detach(id)
}

// --- handle_event and render ------------------------------------------------

pub fn decoded_event_reports_its_constructor_test() {
  let session = joined(option.None)
  let #(id, events) = listen()
  click(session, "increment")
  assert_tags(
    stop_of(events, "handle_event", session.conn_id),
    "increment",
    session.conn_id,
  )
  let render = stop_of(events, "render", session.conn_id)
  assert_tags(render, "increment", session.conn_id)
  let assert True = patch_bytes(render) > 0
  shutdown(id, session)
}

pub fn undecodable_event_reports_unknown_test() {
  let session = joined(option.None)
  let #(id, events) = listen()
  // The handler id is client-chosen: it never becomes a tag.
  click(session, "handler_" <> int.to_string(unique_integer()))
  assert_tags(
    stop_of(events, "handle_event", session.conn_id),
    "unknown",
    session.conn_id,
  )
  shutdown(id, session)
}

pub fn batch_reports_each_event_and_one_render_test() {
  let session = joined(option.None)
  let #(id, events) = listen()
  let increment = #("click", "increment", "{}", "0", 1, "")
  process.send(
    session.runtime,
    runtime.ClientEventBatchReceived(conn_id: session.conn_id, events: [
      increment,
      #("click", "nope", "{}", "0", 2, ""),
      increment,
    ]),
  )
  let first = stop_of(events, "handle_event", session.conn_id)
  assert_tags(first, "increment", session.conn_id)
  let second = stop_of(events, "handle_event", session.conn_id)
  assert_tags(second, "unknown", session.conn_id)
  let third = stop_of(events, "handle_event", session.conn_id)
  assert_tags(third, "increment", session.conn_id)
  let render = stop_of(events, "render", session.conn_id)
  assert_tags(render, "batch", session.conn_id)
  let assert True = patch_bytes(render) > 0
  shutdown(id, session)
}

pub fn effect_update_renders_without_a_connection_test() {
  let session = joined(option.None)
  let #(id, events) = listen()
  process.send(session.runtime, runtime.EffectDispatched(SetCount(9)))
  let render = stop_of(events, "render", "none")
  assert_tags(render, "set_count", "none")
  let assert True = patch_bytes(render) > 0
  shutdown(id, session)
}

pub fn unchanged_model_renders_zero_bytes_test() {
  let session = joined(option.None)
  let #(id, events) = listen()
  // The model is already 0: nothing to patch.
  process.send(session.runtime, runtime.EffectDispatched(SetCount(0)))
  let render = stop_of(events, "render", "none")
  let assert 0 = patch_bytes(render)
  shutdown(id, session)
}

pub fn no_render_span_without_joined_connections_test() {
  let assert Ok(subject) = runtime.start(config(option.None), context_for("/"))
    as "the test runtime must start"
  let #(id, events) = listen()
  process.send(subject, runtime.EffectDispatched(Increment))
  process.send(subject, runtime.Shutdown)
  // Events from one process arrive in order: the stop comes first only
  // if the update emitted no render span.
  let next =
    expect(events, fn(e) {
      e.name == ["beacon", "runtime", "render", "stop"]
      || e.name == ["beacon", "runtime", "stop"]
    })
  let assert ["beacon", "runtime", "stop"] = next.name
  let assert Ok(Nil) = telemetry.detach(id)
}

// --- navigate ---------------------------------------------------------------

pub fn routed_navigation_reports_the_route_message_test() {
  let session = joined(option.Some(parse_page))
  let #(id, events) = listen()
  process.send(
    session.runtime,
    runtime.ClientNavigated(conn_id: session.conn_id, path: "/settings"),
  )
  assert_tags(
    stop_of(events, "navigate", session.conn_id),
    "visit",
    session.conn_id,
  )
  let render = stop_of(events, "render", session.conn_id)
  assert_tags(render, "visit", session.conn_id)
  let assert True = patch_bytes(render) > 0
  shutdown(id, session)
}

pub fn unroutable_navigation_reports_unknown_test() {
  let session = joined(option.Some(parse_page))
  let #(id, events) = listen()
  process.send(
    session.runtime,
    runtime.ClientNavigated(conn_id: session.conn_id, path: "/nope"),
  )
  assert_tags(
    stop_of(events, "navigate", session.conn_id),
    "unknown",
    session.conn_id,
  )
  let assert Ok(transport.SendHardNavigate(path: "/nope")) =
    process.receive(session.transport, 2000)
  shutdown(id, session)
}

pub fn navigation_without_router_reports_unknown_test() {
  let session = joined(option.None)
  let #(id, events) = listen()
  process.send(
    session.runtime,
    runtime.ClientNavigated(conn_id: session.conn_id, path: "/elsewhere"),
  )
  assert_tags(
    stop_of(events, "navigate", session.conn_id),
    "unknown",
    session.conn_id,
  )
  shutdown(id, session)
}

// --- stop -------------------------------------------------------------------

pub fn shutdown_reports_uptime_test() {
  let session = joined(option.None)
  let #(id, events) = listen()
  let monitor = process.monitor(process.subject_owner(session.runtime) |> owner)
  process.send(session.runtime, runtime.Shutdown)
  let stop = expect(events, fn(e) { e.name == ["beacon", "runtime", "stop"] })
  let assert Ok("shutdown") = telemetry.string(stop, "reason")
  let assert Ok(uptime) = telemetry.int(stop, "uptime")
  let assert True = uptime > 0
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(d) { d })
  let assert Ok(_) = process.selector_receive(down, 2000)
    as "the runtime exits after shutdown"
  let assert Ok(Nil) = telemetry.detach(id)
}

fn owner(result: Result(process.Pid, Nil)) -> process.Pid {
  let assert Ok(pid) = result as "a started runtime has an owner process"
  pid
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
