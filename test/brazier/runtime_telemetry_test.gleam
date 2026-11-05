/// Telemetry emitted by the session runtime: the `mount`, `handle_event`,
/// `navigate` and `render` spans and the `[brazier, runtime, stop]` event.
///
/// Every span carries `route` (the page route pattern), `event` (the
/// message's constructor name in snake_case, as the BEAM names it, so
/// `SetCount(9)` is `"set_count"`; or `"mount"` or `"unknown"`) and
/// `connection_id`. Handlers forward to a subject owned by the test and the
/// tests synchronize on those events; nothing sleeps.
import brazier/await
import brazier/effect
import brazier/error
import brazier/internal/context
import brazier/monitored
import brazier/runtime
import brazier/telemetry.{type Event}
import brazier/transport
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
  let assert Ok(parsed) = uri.parse(path) as "uri.parse succeeds"
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
    streams: runtime.no_streams(),
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
      ops: [],
    ),
  )
}

// --- Event helpers ----------------------------------------------------------

fn span_events(kind: String) -> List(List(String)) {
  list.map(["start", "stop", "exception"], fn(suffix) {
    ["brazier", "runtime", kind, suffix]
  })
}

fn runtime_events() -> List(List(String)) {
  list.flatten([
    span_events("mount"),
    span_events("handle_event"),
    span_events("navigate"),
    span_events("render"),
    [["brazier", "runtime", "stop"]],
  ])
}

/// Run `run` with every runtime event forwarded to it; the handler is
/// detached afterwards even if `run` crashes.
fn listen(run: fn(Subject(Event)) -> a) -> a {
  monitored.listening(runtime_events(), run)
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

/// The next `[brazier, runtime, kind, stop]` for `connection_id`.
fn stop_of(
  events: Subject(Event),
  kind: String,
  connection_id: String,
) -> Event {
  expect(events, fn(event) {
    event.name == ["brazier", "runtime", kind, "stop"]
    && telemetry.string(event, "connection_id") == Ok(connection_id)
  })
}

fn assert_tags(event: Event, label: String, connection_id: String) -> Nil {
  let assert Ok("/*") = telemetry.string(event, "route")
    as "telemetry.string succeeds"
  let assert Ok(event_label) = telemetry.string(event, "event")
    as "telemetry.string succeeds"
  assert event_label == label
  let assert Ok(conn) = telemetry.string(event, "connection_id")
    as "telemetry.string succeeds"
  assert conn == connection_id
  let assert Ok(duration) = telemetry.int(event, "duration")
    as "telemetry.int succeeds"
  assert duration >= 0
  Nil
}

fn patch_bytes(event: Event) -> Int {
  let assert Ok(bytes) = telemetry.int(event, "patch_bytes")
    as "a render stop carries patch_bytes"
  bytes
}

/// The next frame the runtime sent the session's connection.
fn frame(session: Session, what: String) -> transport.InternalMessage {
  let assert Ok(message) = process.receive(session.transport, await.deadline_ms)
    as what
  message
}

/// Shut the runtime down and return once it has exited, so nothing it
/// sends can reach a later test; the connection was sent nothing the test
/// did not receive.
fn shutdown(session: Session) -> Nil {
  stop_runtime(session.runtime)
  let assert [] = await.drain(session.transport)
    as "the connection was sent no frame the test did not receive"
  Nil
}

/// Send `Shutdown` and return once the runtime has exited.
fn stop_runtime(subject: Subject(runtime.RuntimeMessage(Msg))) -> Nil {
  let pid = owner(process.subject_owner(subject))
  process.send(subject, runtime.Shutdown)
  await.expect_down(pid, "the runtime after Shutdown")
}

// --- mount ------------------------------------------------------------------

pub fn mount_is_a_span_without_a_connection_test() {
  use events <- listen()
  let assert Ok(subject) = runtime.start(config(option.None), context_for("/"))
    as "the test runtime must start"
  let start =
    expect(events, fn(e) { e.name == ["brazier", "runtime", "mount", "start"] })
  let assert Ok("mount") = telemetry.string(start, "event")
    as "telemetry.string succeeds"
  let stop = stop_of(events, "mount", "none")
  assert_tags(stop, "mount", "none")
  stop_runtime(subject)
}

// --- handle_event and render ------------------------------------------------

pub fn decoded_event_reports_its_constructor_test() {
  let session = joined(option.None)
  use events <- listen()
  click(session, "increment")
  assert_tags(
    stop_of(events, "handle_event", session.conn_id),
    "increment",
    session.conn_id,
  )
  let render = stop_of(events, "render", session.conn_id)
  assert_tags(render, "increment", session.conn_id)
  assert patch_bytes(render) > 0
  let assert transport.SendPatch(
    ops_json: "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":1}]",
    version: 1,
    ack_clock: 1,
    streams_json: "[]",
  ) = frame(session, "the increment's patch")
    as "the increment was patched to count 1 at revision 1"
  shutdown(session)
}

pub fn undecodable_event_reports_unknown_test() {
  let session = joined(option.None)
  use events <- listen()
  // The handler id is client-chosen: it never becomes a tag.
  let handler_id = "handler_" <> int.to_string(unique_integer())
  click(session, handler_id)
  assert_tags(
    stop_of(events, "handle_event", session.conn_id),
    "unknown",
    session.conn_id,
  )
  // The refusal, then the ack of clock 1 with nothing to patch.
  let assert transport.SendError(reason:) = frame(session, "the refusal")
    as "the undecodable event was refused with an error frame"
  assert reason == "RuntimeError: Unknown handler: " <> handler_id
  let assert transport.SendPatch(
    ops_json: "[]",
    version: 0,
    ack_clock: 1,
    streams_json: "[]",
  ) = frame(session, "the ack")
    as "the refused event was acked at revision 0"
  shutdown(session)
}

pub fn batch_reports_each_event_and_one_render_test() {
  let session = joined(option.None)
  use events <- listen()
  let increment = #("click", "increment", "{}", "0", 1, [])
  process.send(
    session.runtime,
    runtime.ClientEventBatchReceived(conn_id: session.conn_id, events: [
      increment,
      #("click", "nope", "{}", "0", 2, []),
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
  assert patch_bytes(render) > 0
  let assert transport.SendError(
    reason: "1 of 3 batched events rejected: RuntimeError: Unknown handler: nope",
  ) = frame(session, "the batch's refusal")
    as "the rejected event of the batch was reported"
  let assert transport.SendPatch(
    ops_json: "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":2}]",
    version: 1,
    ack_clock: 2,
    streams_json: "[]",
  ) = frame(session, "the batch's patch")
    as "the batch was patched once, to count 2, acking clock 2"
  shutdown(session)
}

pub fn effect_update_renders_without_a_connection_test() {
  let session = joined(option.None)
  use events <- listen()
  process.send(session.runtime, runtime.EffectDispatched(SetCount(9)))
  let render = stop_of(events, "render", "none")
  assert_tags(render, "set_count", "none")
  assert patch_bytes(render) > 0
  let assert transport.SendPatch(
    ops_json: "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":9}]",
    version: 1,
    ack_clock: 0,
    streams_json: "[]",
  ) = frame(session, "the effect's patch")
    as "the effect's update was patched to the joined connection"
  shutdown(session)
}

pub fn unchanged_model_renders_zero_bytes_test() {
  let session = joined(option.None)
  use events <- listen()
  // The model is already 0: nothing to patch.
  process.send(session.runtime, runtime.EffectDispatched(SetCount(0)))
  let render = stop_of(events, "render", "none")
  let assert 0 = patch_bytes(render) as "patch_bytes returns 0"
  shutdown(session)
}

pub fn no_render_span_without_joined_connections_test() {
  let assert Ok(subject) = runtime.start(config(option.None), context_for("/"))
    as "the test runtime must start"
  use events <- listen()
  let pid = owner(process.subject_owner(subject))
  process.send(subject, runtime.EffectDispatched(Increment))
  process.send(subject, runtime.Shutdown)
  // Events from one process arrive in order: the stop comes first only
  // if the update emitted no render span.
  let next =
    expect(events, fn(e) {
      e.name == ["brazier", "runtime", "render", "stop"]
      || e.name == ["brazier", "runtime", "stop"]
    })
  let assert ["brazier", "runtime", "stop"] = next.name
    as "next.name is ['brazier', 'runtime', 'stop']"
  await.expect_down(pid, "the runtime after Shutdown")
}

// --- navigate ---------------------------------------------------------------

pub fn routed_navigation_reports_the_route_message_test() {
  let session = joined(option.Some(parse_page))
  use events <- listen()
  process.send(
    session.runtime,
    runtime.ClientNavigated(
      conn_id: session.conn_id,
      path: "/settings",
      clock: 0,
    ),
  )
  assert_tags(
    stop_of(events, "navigate", session.conn_id),
    "visit",
    session.conn_id,
  )
  let render = stop_of(events, "render", session.conn_id)
  assert_tags(render, "visit", session.conn_id)
  assert patch_bytes(render) > 0
  let assert transport.SendPatch(
    ops_json: "[{\"op\":\"replace\",\"path\":\"/page\",\"value\":\"settings\"}]",
    version: 1,
    ack_clock: 0,
    streams_json: "[]",
  ) = frame(session, "the navigation's patch")
    as "the navigation was patched to the settings page"
  shutdown(session)
}

pub fn unroutable_navigation_reports_unknown_test() {
  let session = joined(option.Some(parse_page))
  use events <- listen()
  process.send(
    session.runtime,
    runtime.ClientNavigated(conn_id: session.conn_id, path: "/nope", clock: 0),
  )
  assert_tags(
    stop_of(events, "navigate", session.conn_id),
    "unknown",
    session.conn_id,
  )
  let assert transport.SendHardNavigate(path: "/nope") =
    frame(session, "the hard navigation")
    as "an unroutable path is a hard navigation"
  shutdown(session)
}

pub fn navigation_without_router_reports_unknown_test() {
  let session = joined(option.None)
  use events <- listen()
  process.send(
    session.runtime,
    runtime.ClientNavigated(
      conn_id: session.conn_id,
      path: "/elsewhere",
      clock: 0,
    ),
  )
  assert_tags(
    stop_of(events, "navigate", session.conn_id),
    "unknown",
    session.conn_id,
  )
  let assert transport.SendHardNavigate(path: "/elsewhere") =
    frame(session, "the hard navigation")
    as "without a router a navigation is a hard navigation"
  shutdown(session)
}

// --- stop -------------------------------------------------------------------

pub fn shutdown_reports_uptime_test() {
  let session = joined(option.None)
  use events <- listen()
  let monitor = process.monitor(process.subject_owner(session.runtime) |> owner)
  process.send(session.runtime, runtime.Shutdown)
  let stop = expect(events, fn(e) { e.name == ["brazier", "runtime", "stop"] })
  let assert Ok("shutdown") = telemetry.string(stop, "reason")
    as "telemetry.string succeeds"
  let assert Ok(uptime) = telemetry.int(stop, "uptime")
    as "telemetry.int succeeds"
  let assert True = uptime > 0 as "a runtime that ran reports a positive uptime"
  // Shutdown ends the actor with `actor.stop()`, an exit with reason
  // `normal`; any other reason is a crash during shutdown. The monitor was
  // taken before Shutdown was sent, so `down_reason` sees the real reason.
  let reason = monitored.down_reason(monitor, "the shut-down runtime")
  assert reason == process.Normal
}

fn owner(result: Result(process.Pid, Nil)) -> process.Pid {
  let assert Ok(pid) = result as "a started runtime has an owner process"
  pid
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
