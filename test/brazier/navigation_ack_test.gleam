//// A `navigate` carries a clock from the same counter as the events'
//// clocks, and the runtime acknowledges it like an event: the frame with
//// the navigation's state carries `ack_clock` = its clock, and a navigation
//// that leaves the model as it was gets an empty patch (an ack). The client
//// uses this to find the render that shows the new page, and only then
//// scrolls to the URL's fragment. LiveView answers a `live_patch` push with
//// a reply for the same reason.

import brazier/await
import brazier/effect
import brazier/error
import brazier/internal/context
import brazier/runtime
import brazier/transport
import gleam/erlang/process
import gleam/option
import gleam/string
import gleam/uri

pub type Page {
  Home
  Docs
}

pub type Msg {
  Visited(page: Page)
}

/// The model is the page alone, so a navigation to the page it is on does
/// not change it.
fn config() -> runtime.RuntimeConfig(Page, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Home, effect.none())) },
    update: fn(_page, msg) {
      let Visited(page) = msg
      #(page, effect.none())
    },
    encode_model: fn(page) {
      case page {
        Home -> "{\"page\":\"home\"}"
        Docs -> "{\"page\":\"docs\"}"
      }
    },
    decode_event: fn(_name, _handler_id, _data, _path) {
      Error(error.RuntimeError(reason: "this test sends no events"))
    },
    restore_model: option.None,
    route: option.Some(fn(page_uri: uri.Uri) {
      case page_uri.path {
        "/" -> Ok(Visited(Home))
        "/docs" -> Ok(Visited(Docs))
        _ -> Error(Nil)
      }
    }),
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    on_notification: option.None,
    secret_key: "",
    presence: option.None,
    title: option.None,
  )
}

fn join() -> #(
  process.Subject(runtime.RuntimeMessage(Msg)),
  process.Subject(transport.InternalMessage),
) {
  let ctx =
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
  let assert Ok(rt) = runtime.start(config(), ctx) as "the runtime must start"
  let conn = process.new_subject()
  process.send(rt, runtime.ClientConnected(conn_id: "c", subject: conn))
  process.send(rt, runtime.ClientJoined(conn_id: "c", token: "", path: "/"))
  let assert Ok(transport.SendModelSync(ack_clock: 0, ..)) =
    process.receive(conn, await.deadline_ms)
    as "the join is answered with a model_sync"
  #(rt, conn)
}

pub fn the_navigation_patch_acknowledges_its_clock_test() {
  let #(rt, conn) = join()
  process.send(
    rt,
    runtime.ClientNavigated(conn_id: "c", path: "/docs", clock: 7),
  )
  let assert Ok(transport.SendPatch(ops_json: ops, version: 1, ack_clock: 7)) =
    process.receive(conn, await.deadline_ms)
    as "the navigation's patch acknowledges clock 7"
  let assert True = string.contains(ops, "docs") as ops
}

pub fn an_unchanged_navigation_is_acknowledged_test() {
  let #(rt, conn) = join()
  process.send(rt, runtime.ClientNavigated(conn_id: "c", path: "/", clock: 3))
  let assert Ok(transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 3)) =
    process.receive(conn, await.deadline_ms)
    as "an unchanged model is answered with an ack at the current version"
}

pub fn a_refused_navigation_is_answered_by_its_refusal_alone_test() {
  let #(rt, conn) = join()
  process.send(
    rt,
    runtime.ClientNavigated(conn_id: "c", path: "/nowhere", clock: 4),
  )
  let assert Ok(transport.SendHardNavigate(path: "/nowhere")) =
    process.receive(conn, await.deadline_ms)
    as "an unknown route is loaded over HTTP"
  // The ack that follows the next navigation covers clock 4 too, and no
  // ack was sent after the hard navigation.
  process.send(rt, runtime.ClientNavigated(conn_id: "c", path: "/", clock: 5))
  let assert Ok(transport.SendPatch(ops_json: "[]", ack_clock: 5, ..)) =
    process.receive(conn, await.deadline_ms)
    as "the next message is the next navigation's ack"
}

pub fn navigate_decodes_its_clock_test() {
  let assert Ok(transport.ClientNavigate(path: "/docs", clock: 9)) =
    transport.decode_client_message(
      "{\"type\":\"navigate\",\"path\":\"/docs\",\"clock\":9}",
    )
  // A client that sends no clock is acknowledged at 0, as for an event.
  let assert Ok(transport.ClientNavigate(path: "/docs", clock: 0)) =
    transport.decode_client_message(
      "{\"type\":\"navigate\",\"path\":\"/docs\"}",
    )
  let assert Error(_) =
    transport.decode_client_message(
      "{\"type\":\"navigate\",\"path\":\"/docs\",\"clock\":\"9\"}",
    )
    as "a clock that is not an integer is refused"
}
