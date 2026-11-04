import brazier/cluster/log_capture
import brazier/monitored
import brazier/telemetry.{type Event}
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/set
import gleam/string

// --- Helpers ----------------------------------------------------------------

fn unique(label: String) -> String {
  label <> "_" <> int.to_string(unique_integer())
}

fn forward_to(subject: Subject(Event)) -> fn(Event) -> Nil {
  fn(event) { process.send(subject, event) }
}

/// Every event already in the mailbox. Handlers run synchronously in the
/// emitting process, so after an emit returns its events are delivered.
fn drain(subject: Subject(Event), acc: List(Event)) -> List(Event) {
  case process.receive(subject, 0) {
    Ok(event) -> drain(subject, [event, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn keys(map: dict.Dict(String, Dynamic)) -> set.Set(String) {
  set.from_list(dict.keys(map))
}

// --- Attach, execute, detach ------------------------------------------------

pub fn attach_and_execute_delivers_event_test() {
  let name = ["brazier_test", unique("custom")]
  let events = process.new_subject()
  use <- monitored.with_handler(unique("handler"), [name], forward_to(events))
  let assert Ok(Nil) =
    telemetry.execute(
      name,
      dict.from_list([#("count", 3)]),
      dict.from_list([#("label", "x")]),
    )
    as "execute succeeds for a valid name"
  let assert Ok(event) = process.receive(events, 0)
    as "the handler ran in the emitting process before execute returned"
  assert event.name == name
  let assert Ok(3) = telemetry.int(event, "count")
    as "the count measurement is delivered"
  let assert Ok("x") = telemetry.string(event, "label")
    as "the label metadata is delivered"
  let assert Error(Nil) = telemetry.int(event, "label")
    as "a string value is not read as an int"
  let assert Error(Nil) = telemetry.string(event, "missing")
    as "a missing key reads as an error"
}

pub fn execute_unknown_name_is_ok_without_delivery_test() {
  // No handler was ever attached to this name, so its atoms do not exist
  // and nothing can be listening.
  let name = ["brazier_test_never_attached", unique("segment")]
  let assert Ok(Nil) = telemetry.execute(name, dict.new(), dict.new())
    as "execute of a never-attached name is Ok"
}

pub fn invalid_names_and_ids_are_rejected_test() {
  let assert Error(telemetry.InvalidEventName(_)) =
    telemetry.execute([], dict.new(), dict.new())
    as "an empty event name is rejected"
  let assert Error(telemetry.InvalidEventName(_)) =
    telemetry.execute(["brazier_test", ""], dict.new(), dict.new())
    as "an empty segment is rejected"
  let assert Error(telemetry.InvalidEventName(_)) =
    telemetry.attach(unique("h"), [], fn(_) { Nil })
    as "attaching to no event names is rejected"
  let assert Error(telemetry.InvalidEventName(_)) =
    telemetry.attach(unique("h"), [["brazier_test", ""]], fn(_) { Nil })
    as "attaching to a name with an empty segment is rejected"
  let assert Error(telemetry.InvalidEventName(_)) =
    telemetry.attach(unique("h"), [[string.repeat("a", 256)]], fn(_) { Nil })
    as "attaching to an over-long segment is rejected"
  let assert Error(telemetry.InvalidHandlerId(_)) =
    telemetry.attach("", [["brazier_test", "x"]], fn(_) { Nil })
    as "an empty handler id is rejected"
}

pub fn attaching_same_id_twice_fails_test() {
  let id = unique("dup")
  use <- monitored.with_handler(id, [["brazier_test", "dup"]], fn(_) { Nil })
  let assert Error(telemetry.AlreadyAttached(got)) =
    telemetry.attach(id, [["brazier_test", "dup"]], fn(_) { Nil })
    as "a second attach with the same id fails"
  assert got == id
}

pub fn detach_stops_delivery_test() {
  let name = ["brazier_test", unique("detach")]
  let id = unique("detach_handler")
  let events = process.new_subject()
  let assert Ok(Nil) = telemetry.attach(id, [name], forward_to(events))
    as "the handler attaches"
  // The body detaches the handler itself; the cleanup detaches it only if
  // the body failed first.
  use <- monitored.with_cleanup(fn() { monitored.detach_unless_detached(id) })
  let assert Ok(Nil) = telemetry.detach(id) as "an attached handler detaches"
  let assert Ok(Nil) = telemetry.execute(name, dict.new(), dict.new())
    as "execute succeeds with no handler"
  let assert Error(Nil) = process.receive(events, 0)
    as "a detached handler receives nothing"
  let assert Error(telemetry.NotAttached(got)) = telemetry.detach(id)
    as "a second detach reports NotAttached"
  assert got == id
}

pub fn with_handler_detaches_when_the_body_crashes_test() {
  let name = ["brazier_test", unique("cleanup")]
  let id = unique("cleanup_handler")
  let assert Error(#("error", _)) =
    rescue(fn() {
      use <- monitored.with_handler(id, [name], fn(_) { Nil })
      panic as "test body crashed on purpose"
    })
    as "the body's crash is re-raised"
  let assert Error(telemetry.NotAttached(got)) = telemetry.detach(id)
    as "the handler was detached although the body crashed"
  assert got == id
}

pub fn listening_detaches_when_the_body_crashes_test() {
  let name = ["brazier_test", unique("listening")]
  let assert Error(#("error", _)) =
    rescue(fn() {
      use _events <- monitored.listening([name])
      panic as "test body crashed on purpose"
    })
    as "the body's crash is re-raised"
  // No handler listens on the name any more.
  assert handler_ids(name) == []
}

pub fn listening_leaves_no_event_in_the_mailbox_test() {
  let name = ["brazier_test", unique("residue")]
  // The body lets an event arrive and never receives it, as a test that
  // asserts on one upgrade and not on the next does.
  let events =
    monitored.listening([name], fn(events) {
      let assert Ok(Nil) = telemetry.execute(name, dict.new(), dict.new())
        as "execute succeeds while listening"
      events
    })
  let assert Error(Nil) = process.receive(events, 0)
    as "the scope removed its undelivered event when it ended"
}

pub fn listening_drops_a_send_that_races_the_detach_test() {
  let name = ["brazier_test", unique("late")]
  // An emitter that looked the handler up before the detach and calls it
  // after: telemetry:execute reads the handler table, then calls each one.
  let #(events, late_call) =
    monitored.listening([name], fn(events) {
      #(events, looked_up_handler(name))
    })
  late_call()
  let assert Error(Nil) = process.receive(events, 0)
    as "a send after the scope ended was dropped, not delivered"
}

// --- Crashing handlers ------------------------------------------------------

pub fn crashing_handler_is_detached_and_logged_test() {
  let assert Ok(Nil) = telemetry.start() as "telemetry starts"
  let name = ["brazier_test", unique("crash")]
  let crashing_id = unique("crashing")
  let failures = process.new_subject()
  let assert Ok(Nil) =
    telemetry.attach(crashing_id, [name], fn(_) {
      panic as "handler crashed on purpose"
    })
    as "the crashing handler attaches"
  // The test asserts telemetry detached the crashing handler itself; the
  // cleanup detaches it only if the test failed before it crashed.
  use <- monitored.with_cleanup(fn() {
    monitored.detach_unless_detached(crashing_id)
  })
  use <- monitored.with_handler(
    unique("failure_watcher"),
    [["telemetry", "handler", "failure"]],
    forward_to(failures),
  )

  let #(result, lines) =
    log_capture.capture(fn() { telemetry.execute(name, dict.new(), dict.new()) })
  // The emitter is unaffected: execute returned normally.
  let assert Ok(Nil) = result as "execute returns normally past a crash"
  assert log_capture.contains(lines, "error", "[brazier.telemetry] handler")
  assert log_capture.contains(lines, "error", crashing_id)

  let assert Ok(failure) = process.receive(failures, 0)
    as "telemetry reported the handler failure"
  let assert Ok(handler_id) = telemetry.string(failure, "handler_id")
    as "the failure names the handler"
  assert handler_id == crashing_id
  let assert Ok("error") = telemetry.string(failure, "kind")
    as "the failure kind is error"

  // telemetry detached the crashing handler; Brazier's logger is still on.
  let assert Error(telemetry.NotAttached(_)) = telemetry.detach(crashing_id)
    as "telemetry detached the crashing handler"
  assert list.contains(
    handler_ids(["telemetry", "handler", "failure"]),
    "brazier-telemetry-handler-failure-logger",
  )
}

// --- Spans ------------------------------------------------------------------

pub fn span_emits_start_and_stop_test() {
  let base = ["brazier_test", unique("span")]
  let events = process.new_subject()
  use <- monitored.with_handler(
    unique("span_handler"),
    [list.append(base, ["start"]), list.append(base, ["stop"])],
    forward_to(events),
  )
  let result =
    telemetry.span(base, dict.from_list([#("route", "/items/:id")]), fn() {
      41 + 1
    })
  assert result == 42
  let assert [start, stop] = drain(events, [])
    as "a span emits exactly a start and a stop"
  assert start.name == list.append(base, ["start"])
  let assert Ok(_) = telemetry.int(start, "system_time")
    as "the start carries system_time"
  let assert Ok("/items/:id") = telemetry.string(start, "route")
    as "the start carries the route"
  assert stop.name == list.append(base, ["stop"])
  let assert Ok(duration) = telemetry.int(stop, "duration")
    as "the stop carries a duration"
  assert duration >= 0
  let assert Ok("/items/:id") = telemetry.string(stop, "route")
    as "the stop carries the route"
}

pub fn span_exception_is_emitted_and_reraised_test() {
  let base = ["brazier_test", unique("span_crash")]
  let events = process.new_subject()
  use <- monitored.with_handler(
    unique("span_crash_handler"),
    [list.append(base, ["exception"])],
    forward_to(events),
  )
  let assert Error(#(class, _reason)) =
    rescue(fn() {
      telemetry.span(base, dict.new(), fn() { panic as "span body crashed" })
    })
    as "the span re-raises the body's crash"
  assert class == "error"
  let assert Ok(exception) = process.receive(events, 0)
    as "the span emitted an exception event"
  let assert Ok("error") = telemetry.string(exception, "kind")
    as "the exception kind is error"
  let assert Ok(_) = dict.get(exception.metadata, "reason")
    as "the exception carries the reason"
  let assert Ok(_) = dict.get(exception.metadata, "stacktrace")
    as "the exception carries the stacktrace"
}

pub fn span_without_handlers_runs_body_test() {
  let assert "ran" =
    telemetry.span(
      ["brazier_test_never_attached", unique("s")],
      dict.new(),
      fn() { "ran" },
    )
    as "telemetry.span returns 'ran'"
}

// --- Catalogue, documented keys and privacy ---------------------------------

pub fn compiled_prefix_matches_constant_test() {
  assert telemetry.compiled_prefix() == telemetry.prefix
}

/// The documented keys from the event catalogue in
/// docs/design/CLUSTER_PRESENCE_TELEMETRY.md and docs/TELEMETRY.md, written
/// out independently of the emitters.
type Documented {
  Plain(name: List(String), measurements: List(String), metadata: List(String))
  Span(
    name: List(String),
    metadata: List(String),
    stop_measurements: List(String),
    stop_metadata: List(String),
  )
}

fn documented() -> List(Documented) {
  let connection = fn(outcome) {
    Plain(["http", "connection", outcome], ["count", "duration"], ["reason"])
  }
  let session = fn(kind) { Plain(["session", kind], ["count"], ["reason"]) }
  let cluster = fn(name) { Plain(name, ["count"], ["node", "reason"]) }
  let presence = fn(kind) {
    Plain(["presence", kind], ["count"], ["tracker", "shard"])
  }
  let replica = fn(state) {
    Plain(["presence", "replica", state], [], ["replica", "tracker"])
  }
  let runtime = fn(kind) {
    Span(["runtime", kind], ["route", "event", "connection_id"], [], [])
  }
  [
    Span(
      ["http", "request"],
      ["method", "connection_id"],
      ["req_body_bytes", "resp_body_bytes"],
      ["route", "status"],
    ),
    connection("accepted"),
    connection("rejected"),
    connection("closed"),
    Span(["ws", "upgrade"], ["route"], [], ["result"]),
    Plain(
      ["ws", "close"],
      ["duration", "frames_in", "frames_out", "bytes_in", "bytes_out"],
      ["close_code", "reason", "connection_id"],
    ),
    Plain(["ws", "rate_limited"], ["count", "violations"], [
      "kind", "connection_id",
    ]),
    Plain(["ws", "backpressure"], ["queue_len"], ["reason", "connection_id"]),
    Plain(["ws", "navigation_refused"], ["count"], [
      "kind", "status", "connection_id",
    ]),
    runtime("mount"),
    runtime("handle_event"),
    runtime("navigate"),
    Span(
      ["runtime", "render"],
      ["route", "event", "connection_id"],
      ["patch_bytes"],
      [],
    ),
    Plain(["runtime", "stop"], ["uptime"], ["reason"]),
    Span(["effect", "run"], ["effect"], [], []),
    Plain(["effect", "timer", "rejected"], [], ["limit"]),
    Plain(["effect", "after", "rejected"], [], ["limit"]),
    Plain(["effect", "background", "rejected"], [], ["limit"]),
    Plain(["ssr", "join_token", "too_large"], ["bytes"], ["budget"]),
    Plain(["store", "write"], ["count"], ["store", "op", "mode"]),
    Span(["store", "sync"], ["store", "peer"], ["entries", "bytes"], []),
    session("created"),
    session("revoked"),
    session("expired"),
    session("contention"),
    Plain(["pubsub", "broadcast"], ["local_subscribers", "remote_nodes"], [
      "scope",
    ]),
    Plain(["pubsub", "forward", "overloaded"], ["queue_len"], ["shard"]),
    Plain(["subscription", "changed"], ["subscriptions"], ["action"]),
    cluster(["cluster", "node", "up"]),
    cluster(["cluster", "node", "down"]),
    cluster(["cluster", "peer", "rejected"]),
    cluster(["cluster", "connect", "failed"]),
    presence("track"),
    presence("untrack"),
    presence("limit_exceeded"),
    replica("up"),
    replica("down"),
    replica("permdown"),
    Span(
      ["presence", "transfer"],
      ["tracker", "peer"],
      ["entries", "bytes"],
      [],
    ),
  ]
}

/// Expected #(name, measurement keys, metadata keys) for every event,
/// including the standard measurements and metadata telemetry adds to
/// span events.
fn expected_events() -> List(#(List(String), set.Set(String), set.Set(String))) {
  let full = fn(name) { [telemetry.prefix, ..name] }
  list.flat_map(documented(), fn(doc) {
    case doc {
      Plain(name:, measurements:, metadata:) -> [
        #(full(name), set.from_list(measurements), set.from_list(metadata)),
      ]
      Span(name:, metadata:, stop_measurements:, stop_metadata:) -> {
        let context = ["telemetry_span_context"]
        [
          #(
            full(list.append(name, ["start"])),
            set.from_list(["monotonic_time", "system_time"]),
            set.from_list(list.append(metadata, context)),
          ),
          #(
            full(list.append(name, ["stop"])),
            set.from_list(
              list.append(stop_measurements, ["duration", "monotonic_time"]),
            ),
            set.from_list(list.flatten([metadata, stop_metadata, context])),
          ),
          #(
            full(list.append(name, ["exception"])),
            set.from_list(["duration", "monotonic_time"]),
            set.from_list(
              list.flatten([
                metadata,
                context,
                ["kind", "reason", "stacktrace"],
              ]),
            ),
          ),
        ]
      }
    }
  })
}

/// Call every catalogue emitter, running each span once normally and once
/// with a crashing body.
fn emit_everything() -> Nil {
  let crash = fn(run: fn() -> a) {
    let assert Error(_) = rescue(run) as "rescue returns Error(_)"
    Nil
  }
  let request = fn(run) { telemetry.http_request_span("GET", "c1", run) }
  let assert 1 = request(fn() { #(1, "/items/:id", 200, 10, 20) })
    as "request returns 1"
  crash(fn() { request(fn() { panic as "request crashed" }) })
  telemetry.http_connection(telemetry.Accepted, 0, "ok")
  telemetry.http_connection(telemetry.Rejected, 0, "limit")
  telemetry.http_connection(telemetry.Closed, 5, "normal")
  let upgrade = fn(run) { telemetry.ws_upgrade_span("/chat", run) }
  let assert 2 = upgrade(fn() { #(2, "ok") }) as "upgrade returns 2"
  crash(fn() { upgrade(fn() { panic as "upgrade crashed" }) })
  telemetry.ws_close(100, 1, 2, 30, 40, 1000, "normal", "c1")
  telemetry.ws_rate_limited(5, "event", "c1")
  telemetry.ws_backpressure(9, "outbound_queue", "c1")
  telemetry.ws_navigation_refused("navigate", 403, "c1")
  list.each(
    [telemetry.Mount, telemetry.HandleEvent, telemetry.Navigate],
    fn(kind) {
      let span = fn(run) {
        telemetry.runtime_span(kind, "/", "unknown", "c1", run)
      }
      let assert 3 = span(fn() { 3 }) as "span returns 3"
      crash(fn() { span(fn() { panic as "runtime crashed" }) })
    },
  )
  let render = fn(run) {
    telemetry.runtime_render_span("/", "increment", "c1", run)
  }
  let assert 4 = render(fn() { #(4, 128) }) as "render returns 4"
  crash(fn() { render(fn() { panic as "render crashed" }) })
  telemetry.runtime_stop(1000, "normal")
  let effect = fn(run) { telemetry.effect_run_span("http", run) }
  let assert 5 = effect(fn() { 5 }) as "effect returns 5"
  crash(fn() { effect(fn() { panic as "effect crashed" }) })
  telemetry.effect_timer_rejected(32)
  telemetry.effect_after_rejected(100)
  telemetry.effect_background_rejected(32)
  telemetry.ssr_join_token_too_large(4000, 3800)
  telemetry.store_write(1, "counter", "put", "local")
  let sync = fn(run) { telemetry.store_sync_span("counter", "b@host", run) }
  let assert 6 = sync(fn() { #(6, 10, 100) }) as "sync returns 6"
  crash(fn() { sync(fn() { panic as "sync crashed" }) })
  list.each(
    [
      telemetry.Created,
      telemetry.Revoked,
      telemetry.Expired,
      telemetry.Contention,
    ],
    fn(kind) { telemetry.session_event(kind, "test") },
  )
  telemetry.pubsub_broadcast(3, 2, "cluster")
  telemetry.pubsub_forward_overloaded(10_001, 0)
  telemetry.subscription_changed(telemetry.Subscribe, 1)
  telemetry.cluster_node(telemetry.NodeUp, "b@host", "connected")
  telemetry.cluster_node(telemetry.NodeDown, "b@host", "connection_closed")
  telemetry.cluster_peer_rejected("b@host", "secret_mismatch")
  telemetry.cluster_connect_failed("b@host", "timeout")
  list.each(
    [telemetry.Track, telemetry.Untrack, telemetry.LimitExceeded],
    fn(kind) { telemetry.presence_event(kind, 1, "room", 0) },
  )
  list.each(
    [telemetry.ReplicaUp, telemetry.ReplicaDown, telemetry.ReplicaPermdown],
    fn(state) { telemetry.presence_replica(state, "b@host:1", "room") },
  )
  let transfer = fn(run) {
    telemetry.presence_transfer_span("room", "b@host", run)
  }
  let assert 7 = transfer(fn() { #(7, 3, 300) }) as "transfer returns 7"
  crash(fn() { transfer(fn() { panic as "transfer crashed" }) })
}

pub fn every_catalogue_event_fires_with_documented_keys_test() {
  let assert Ok(Nil) = telemetry.start() as "telemetry.start succeeds"
  let expected = expected_events()
  // The catalogue lists exactly the documented events.
  assert set.from_list(telemetry.catalogue())
    == set.from_list(list.map(expected, fn(entry) { entry.0 }))

  let received = {
    use events <- monitored.listening(telemetry.catalogue())
    emit_everything()
    drain(events, [])
  }

  let lookup = dict.from_list(list.map(expected, fn(e) { #(e.0, #(e.1, e.2)) }))
  list.each(received, fn(event) {
    let assert Ok(#(measurements, metadata)) = dict.get(lookup, event.name)
      as "dict.get succeeds"
    case
      keys(event.measurements) == measurements,
      keys(event.metadata) == metadata
    {
      True, True -> Nil
      _, _ -> {
        io.println(
          "Undocumented keys on "
          <> string.join(event.name, ".")
          <> ": "
          <> string.inspect(dict.keys(event.measurements))
          <> " "
          <> string.inspect(dict.keys(event.metadata)),
        )
        panic as "telemetry event keys differ from the documented catalogue"
      }
    }
  })
  // Every catalogue event fired at least once.
  let fired = set.from_list(list.map(received, fn(event) { event.name }))
  assert fired == set.from_list(telemetry.catalogue())
}

/// Keys that would leak private data. None may appear in any catalogue
/// event, whatever the emitter is called with.
const forbidden_keys = [
  "session_id", "session", "token", "csrf", "cookie", "cookies", "payload",
  "model", "query", "query_string", "path", "remote_ip", "ip", "peer_ip",
  "secret", "password", "body", "headers",
]

pub fn no_catalogue_event_carries_private_keys_test() {
  list.each(expected_events(), fn(entry) {
    let all = set.union(entry.1, entry.2)
    list.each(forbidden_keys, fn(key) {
      case set.contains(all, key) {
        False -> Nil
        True -> {
          io.println(
            "Private key " <> key <> " on " <> string.join(entry.0, "."),
          )
          panic as "telemetry catalogue exposes a private key"
        }
      }
    })
  })
}

// --- Cost with no handler ---------------------------------------------------

pub fn no_handler_emit_cost_benchmark_test() {
  let assert Ok(Nil) = telemetry.start() as "telemetry.start succeeds"
  let iterations = 1_000_000
  let #(emit_ns, loop_ns) = bench_no_handler_emit(iterations)
  print_to_user(
    "\n[telemetry bench] no-handler emit of [brazier, store, write]: "
    <> float.to_string(float.to_precision(emit_ns, 1))
    <> " ns/op (empty loop "
    <> float.to_string(float.to_precision(loop_ns, 1))
    <> " ns/op, "
    <> int.to_string(iterations)
    <> " iterations)",
  )
  // A generous sanity bound: an emit with no handler is a persistent_term
  // read and one ETS lookup, far below 5 microseconds.
  assert emit_ns <. 5000.0
}

// --- FFI --------------------------------------------------------------------

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))

@external(erlang, "brazier_telemetry_test_ffi", "handler_ids")
fn handler_ids(name: List(String)) -> List(String)

@external(erlang, "brazier_telemetry_test_ffi", "looked_up_handler")
fn looked_up_handler(name: List(String)) -> fn() -> Nil

@external(erlang, "brazier_telemetry_test_ffi", "print_to_user")
fn print_to_user(line: String) -> Nil

@external(erlang, "brazier_telemetry_test_ffi", "bench_no_handler_emit")
fn bench_no_handler_emit(iterations: Int) -> #(Float, Float)
