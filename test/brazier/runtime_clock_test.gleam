//// Every message that carries a clock settles it on the client.
////
//// L605: a navigation the runtime refuses with an `error` frame (a path
//// that is not same-origin) is acked after the error, with the
//// navigation's clock, as an event that changed nothing is. The client
//// settles a clock on that empty patch (`handleAckPatch`), so a pending
//// fragment scroll for the refused navigation no longer waits for the next
//// event's ack. A refusal answered with a hard navigation is not acked:
//// the page load answers it.
////
//// On the wire the transport's live-page gate refuses a navigation to a
//// path that is not same-origin before the runtime sees it (with "Invalid
//// page path", unacked; see `live_page_gate_test`); the runtime's refusal
//// is the check for every other sender of `ClientNavigated`.
////
//// Synchronisation: `await.settle` (a barrier on the runtime, then the
//// connection's mailbox).

import brazier/await
import brazier/cluster/log_capture as node_log
import brazier/effect
import brazier/error
import brazier/runtime
import brazier/test_ctx
import brazier/transport.{type InternalMessage}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleam/uri

// --- L605: a refused navigation settles its clock -----------------------------

pub fn non_local_navigation_is_refused_then_acked_with_its_clock_test() {
  let #(rt, conn) = join("ext")
  process.send(
    rt,
    runtime.ClientNavigated(conn_id: "ext", path: "//evil.example/x", clock: 5),
  )
  let received = await.settle(rt, conn)
  let assert [
    transport.SendError(reason: "navigation path must be a same-origin path"),
    transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 5, ..),
  ] = received
    as string.inspect(received)
}

/// The ack after a refusal is the navigation's own: a later event is acked
/// with its own clock, and the model was not touched.
pub fn event_after_a_refused_navigation_gets_its_own_ack_test() {
  let #(rt, conn) = join("ext_then_click")
  process.send(
    rt,
    runtime.ClientNavigated(
      conn_id: "ext_then_click",
      path: "javascript:x",
      clock: 1,
    ),
  )
  click(rt, "ext_then_click", 2)
  let received = await.settle(rt, conn)
  let assert [
    transport.SendError(..),
    transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 1, ..),
    transport.SendPatch(version: 1, ack_clock: 2, ..),
  ] = received
    as string.inspect(received)
}

/// A refusal answered with a hard navigation is not acked: the browser
/// loads the page, and that answers the navigation.
pub fn unknown_route_navigation_is_answered_by_the_hard_navigation_alone_test() {
  let #(rt, conn) = join("unknown")
  process.send(
    rt,
    runtime.ClientNavigated(conn_id: "unknown", path: "/nope", clock: 3),
  )
  let received = await.settle(rt, conn)
  let assert [transport.SendHardNavigate(path: "/nope")] = received
    as string.inspect(received)
}

/// A navigation that changes the page is answered by its patch, which
/// carries its clock; no ack follows.
pub fn known_route_navigation_is_answered_by_its_patch_test() {
  let #(rt, conn) = join("known")
  process.send(
    rt,
    runtime.ClientNavigated(conn_id: "known", path: "/other", clock: 4),
  )
  let received = await.settle(rt, conn)
  let assert [transport.SendPatch(version: 1, ack_clock: 4, ops_json:, ..)] =
    received
    as string.inspect(received)
  assert ops_json != "[]"
}

// --- L607: a clock that goes back names what carried it ---------------------------

pub fn event_clock_going_back_is_named_an_event_clock_test() {
  let #(rt, conn) = join("back_event")
  click(rt, "back_event", 5)
  let #(received, logs) =
    node_log.capture(fn() {
      click(rt, "back_event", 3)
      await.settle(rt, conn)
    })
  assert non_monotonic(logs)
    == [
      #(
        "warning",
        "[brazier.runtime] Non-monotonic event clock from back_event: 3 after 5",
      ),
    ]
  // The ack does not move back.
  let assert [_, transport.SendPatch(version: 2, ack_clock: 5, ..)] = received
    as string.inspect(received)
}

pub fn batch_event_clock_going_back_is_named_a_batch_event_clock_test() {
  let #(rt, conn) = join("back_batch")
  click(rt, "back_batch", 5)
  let #(received, logs) =
    node_log.capture(fn() {
      process.send(
        rt,
        runtime.ClientEventBatchReceived(conn_id: "back_batch", events: [
          #("click", "increment", "", "0", 6, []),
          #("click", "increment", "", "0", 4, []),
        ]),
      )
      await.settle(rt, conn)
    })
  assert non_monotonic(logs)
    == [
      #(
        "warning",
        "[brazier.runtime] Non-monotonic batch event clock from back_batch: 4 after 6",
      ),
    ]
  let assert [_, transport.SendPatch(version: 2, ack_clock: 6, ..)] = received
    as string.inspect(received)
}

pub fn navigation_clock_going_back_is_named_a_navigation_clock_test() {
  let #(rt, conn) = join("back_nav")
  click(rt, "back_nav", 5)
  let #(received, logs) =
    node_log.capture(fn() {
      process.send(
        rt,
        runtime.ClientNavigated(conn_id: "back_nav", path: "/other", clock: 2),
      )
      await.settle(rt, conn)
    })
  assert non_monotonic(logs)
    == [
      #(
        "warning",
        "[brazier.runtime] Non-monotonic navigation clock from back_nav: 2 after 5",
      ),
    ]
  let assert [_, transport.SendPatch(version: 2, ack_clock: 5, ..)] = received
    as string.inspect(received)
}

/// A clock that only goes forward is not warned about, whatever carries it.
pub fn clocks_going_forward_are_not_warned_about_test() {
  let #(rt, conn) = join("forward")
  let #(_, logs) =
    node_log.capture(fn() {
      click(rt, "forward", 1)
      process.send(
        rt,
        runtime.ClientEventBatchReceived(conn_id: "forward", events: [
          #("click", "increment", "", "0", 2, []),
          #("click", "increment", "", "0", 3, []),
        ]),
      )
      process.send(
        rt,
        runtime.ClientNavigated(conn_id: "forward", path: "/other", clock: 4),
      )
      // The same clock again is not a step back.
      click(rt, "forward", 4)
      await.settle(rt, conn)
    })
  assert non_monotonic(logs) == []
}

// --- Harness ---------------------------------------------------------------------

fn non_monotonic(logs: List(node_log.Line)) -> List(#(String, String)) {
  list.filter_map(logs, fn(line) {
    case string.contains(line.message, "Non-monotonic") {
      True -> Ok(#(line.level, line.message))
      False -> Error(Nil)
    }
  })
}

type Model {
  Model(page: String, count: Int)
}

type Msg {
  Increment
  Routed(page: String)
}

fn parse(page_uri: uri.Uri) -> Result(Msg, Nil) {
  case uri.path_segments(page_uri.path) {
    [] -> Ok(Routed("home"))
    ["other"] -> Ok(Routed("other"))
    _ -> Error(Nil)
  }
}

fn config() -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(page: "", count: 0), effect.none())) },
    update: fn(model: Model, msg) {
      case msg {
        Increment -> #(Model(..model, count: model.count + 1), effect.none())
        Routed(page) -> #(Model(..model, page:), effect.none())
      }
    },
    encode_model: fn(model: Model) {
      "{\"page\":\""
      <> model.page
      <> "\",\"count\":"
      <> int.to_string(model.count)
      <> "}"
    },
    decode_event: fn(_name, handler_id, _data, _path) {
      case handler_id {
        "increment" -> Ok(Increment)
        _ -> Error(error.RuntimeError(reason: "unknown handler " <> handler_id))
      }
    },
    restore_model: option.None,
    route: option.Some(parse),
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    secret_key: "",
    presence: option.None,
    title: option.None,
    streams: runtime.no_streams(),
  )
}

/// Start a routed runtime at "/" and join `conn_id` there; the join's
/// model sync is read, so the connection's mailbox starts empty.
fn join(
  conn_id: String,
) -> #(Subject(runtime.RuntimeMessage(Msg)), Subject(InternalMessage)) {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let conn = process.new_subject()
  process.send(rt, runtime.ClientConnected(conn_id: conn_id, subject: conn))
  process.send(rt, runtime.ClientJoined(conn_id: conn_id, token: "", path: "/"))
  let joined = await.settle(rt, conn)
  let assert [transport.SendModelSync(version: 0, ..)] = joined
    as string.inspect(joined)
  #(rt, conn)
}

fn click(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  clock: Int,
) -> Nil {
  process.send(
    rt,
    runtime.ClientEventReceived(
      conn_id: conn_id,
      event_name: "click",
      handler_id: "increment",
      event_data: "",
      target_path: "0",
      clock: clock,
      ops: [],
    ),
  )
}
