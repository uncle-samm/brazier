/// Simulation scenarios — composable action scripts for simulated clients.
/// Each scenario is a sequence of actions executed by a connection pool worker.
import gleam/int
import gleam/list

/// An action a simulated client performs.
pub type Action {
  /// Open TCP + WebSocket handshake
  Connect
  /// Send join message. Normal apps respond with model_sync, not HTML mount.
  Join
  /// Send a single event with clock 1
  SendEvent(handler_id: String, data: String)
  /// Send a single event with an explicit clock. The server acknowledges
  /// the highest clock it has seen in every patch and model sync.
  SendEventWithClock(handler_id: String, data: String, clock: Int)
  /// Wait for a server response (patch, model_sync, etc.) — tracks type in metrics
  WaitForResponse(timeout_ms: Int)
  /// Wait and assert the response is a "patch" message
  WaitForPatch(timeout_ms: Int)
  /// Wait and assert the response is a "model_sync" message
  WaitForModelSync(timeout_ms: Int)
  /// Wait and assert the response contains expected string
  AssertResponseContains(timeout_ms: Int, expected: String)
  /// Receive responses until one contains `expected`, all within
  /// `timeout_ms`. Every response received is tracked in metrics.
  ReceiveUntil(timeout_ms: Int, expected: String)
  /// Send a malformed WebSocket frame (fault injection)
  SendMalformed(payload: String)
  /// Graceful WebSocket close
  Disconnect
  /// Kill TCP socket without close frame
  AbruptDisconnect
}

/// A named sequence of actions.
pub type Scenario {
  Scenario(name: String, actions: List(Action))
}

/// Counter scenario: connect, join, send N click events, disconnect.
pub fn counter(n_events: Int) -> Scenario {
  let events = repeat_event_with_response(n_events, [])
  Scenario(
    name: "counter(" <> int.to_string(n_events) <> ")",
    actions: list.flatten([
      [Connect, Join, WaitForResponse(5000)],
      events,
      [Disconnect],
    ]),
  )
}

fn repeat_event_with_response(
  remaining: Int,
  acc: List(Action),
) -> List(Action) {
  case remaining {
    0 -> list.reverse(acc)
    _ ->
      repeat_event_with_response(remaining - 1, [
        WaitForResponse(5000),
        SendEvent("h0", "{}"),
        ..acc
      ])
  }
}

/// Draw scenario: connect, join, send N stroke events as rapid mousemoves, disconnect.
pub fn draw(n_strokes: Int) -> Scenario {
  let strokes = generate_strokes(n_strokes, 0, [])
  Scenario(
    name: "draw(" <> int.to_string(n_strokes) <> ")",
    actions: list.flatten([
      [Connect, Join, WaitForResponse(5000)],
      // Mousedown
      [SendEvent("h0", "{\"x\":100,\"y\":100}")],
      // Mousemoves
      strokes,
      // Mouseup
      [SendEvent("h1", "{\"x\":600,\"y\":300}")],
      [WaitForResponse(5000), Disconnect],
    ]),
  )
}

/// Connect-disconnect scenario for leak testing.
pub fn connect_disconnect() -> Scenario {
  Scenario(name: "connect_disconnect", actions: [
    Connect,
    Join,
    WaitForResponse(5000),
    Disconnect,
  ])
}

/// Malformed frame scenario for resilience testing. The server answers
/// each undecodable message with an error and keeps the connection open
/// (below `ws_max_decode_errors`).
pub fn malformed() -> Scenario {
  let invalid = "{\"type\":\"error\",\"reason\":\"Invalid message\"}"
  Scenario(name: "malformed", actions: [
    Connect,
    Join,
    WaitForModelSync(5000),
    SendMalformed("not json at all!!!"),
    SendMalformed("{\"type\":\"event\",\"name\":"),
    SendMalformed(""),
    AssertResponseContains(5000, invalid),
    AssertResponseContains(5000, invalid),
    AssertResponseContains(5000, invalid),
    Disconnect,
  ])
}

/// Flood scenario: send N events as fast as possible.
pub fn flood(n_events: Int) -> Scenario {
  let events = list.repeat(SendEvent("h0", "{}"), n_events)
  Scenario(
    name: "flood(" <> int.to_string(n_events) <> ")",
    actions: list.flatten([
      [Connect, Join, WaitForResponse(5000)],
      events,
      [WaitForResponse(10_000), Disconnect],
    ]),
  )
}

fn generate_strokes(total: Int, i: Int, acc: List(Action)) -> List(Action) {
  case i >= total {
    True -> list.reverse(acc)
    False -> {
      let x = int.to_string(100 + { i % 50 } * 12)
      let y = int.to_string(100 + { i / 50 } * 40)
      let action = SendEvent("h2", "{\"x\":" <> x <> ",\"y\":" <> y <> "}")
      generate_strokes(total, i + 1, [action, ..acc])
    }
  }
}

/// Above the largest clock the corrupt scenario sends (999999).
const final_corrupt_clock = 1_000_000

/// Corruption scenario — sends various types of bad data.
pub fn corrupt() -> Scenario {
  Scenario(name: "corrupt", actions: [
    Connect,
    Join,
    WaitForResponse(5000),
    // Valid JSON but wrong structure
    SendMalformed("{\"type\":\"garbage\",\"foo\":123}"),
    // Partial JSON
    SendMalformed("{\"type\":\"event\",\"name\":"),
    // Empty string
    SendMalformed(""),
    // Binary noise
    SendMalformed("\u{00}\u{ff}\u{fe}\u{01}\u{80}"),
    // Enormous payload (10KB of junk)
    SendMalformed(repeat_string("AAAAAAAAAA", 1000)),
    // Valid event but handler doesn't exist
    SendMalformed(
      "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"does_not_exist_999\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":999999}",
    ),
    // Valid event with corrupt data field
    SendMalformed(
      "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"h0\",\"data\":\"NOT_JSON\",\"target_path\":\"0\",\"clock\":1}",
    ),
    // Negative clock
    SendMalformed(
      "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"h0\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":-1}",
    ),
    // A valid event with a clock above every earlier one proves the
    // connection still works after all that: the response that
    // acknowledges it can only come after it was handled.
    SendEventWithClock("h0", "{}", final_corrupt_clock),
    ReceiveUntil(
      5000,
      "\"ack_clock\":" <> int.to_string(final_corrupt_clock) <> "}",
    ),
    Disconnect,
  ])
}

fn repeat_string(s: String, n: Int) -> String {
  case n <= 0 {
    True -> ""
    False -> s <> repeat_string(s, n - 1)
  }
}

/// Patch efficiency scenario: join gets model_sync, then N increments each with response tracking.
pub fn patch_efficiency(n_events: Int) -> Scenario {
  let events =
    list.map(list.repeat(Nil, n_events), fn(_) {
      [SendEvent("h0", "{}"), WaitForResponse(5000)]
    })
    |> list.flatten
  Scenario(
    name: "patch_efficiency(" <> int.to_string(n_events) <> ")",
    actions: list.flatten([
      [Connect, Join],
      [WaitForResponse(5000)],
      events,
      [Disconnect],
    ]),
  )
}

/// State correctness scenario: send N increments, verify final count in response.
pub fn verify_count(n_events: Int) -> Scenario {
  let events = list.repeat(SendEvent("h0", "{}"), n_events)
  Scenario(
    name: "verify_count(" <> int.to_string(n_events) <> ")",
    actions: list.flatten([
      [Connect, Join, WaitForResponse(5000)],
      events,
      [WaitForResponse(5000)],
      [AssertResponseContains(5000, int.to_string(n_events))],
      [Disconnect],
    ]),
  )
}

/// Reconnection scenario: connect, increment, disconnect, reconnect, verify data.
pub fn reconnect(n_before: Int) -> Scenario {
  let events = list.repeat(SendEvent("h0", "{}"), n_before)
  Scenario(
    name: "reconnect(" <> int.to_string(n_before) <> ")",
    actions: list.flatten([
      // First session: connect, receive model_sync, send events.
      [Connect, Join, WaitForResponse(5000)],
      events,
      [WaitForResponse(5000)],
      [Disconnect],
      // Second session: reconnect, receive model_sync.
      [Connect, Join, WaitForResponse(5000)],
      [Disconnect],
    ]),
  )
}

/// Server-push scenario: connect, join, then receive `ticks` patches the
/// client never asked for (pushed by the app's timer).
pub fn server_push(ticks: Int) -> Scenario {
  Scenario(
    name: "server_push(" <> int.to_string(ticks) <> ")",
    actions: list.flatten([
      [Connect, Join, WaitForModelSync(5000)],
      list.repeat(WaitForPatch(5000), ticks),
      [Disconnect],
    ]),
  )
}

/// Combine two scenarios sequentially (for the second, skip Connect/Join).
pub fn combine(a: Scenario, b: Scenario) -> Scenario {
  Scenario(
    name: a.name <> "+" <> b.name,
    actions: list.append(a.actions, b.actions),
  )
}
