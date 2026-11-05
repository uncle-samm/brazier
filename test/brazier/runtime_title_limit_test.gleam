//// A title over `runtime.title_max_bytes` is reported (an `error` frame and
//// an error log line) once when it goes over the limit, not after every
//// update while it stays over. It is reported again only after it has been
//// back within the limit, and both transitions are logged.
////
//// Synchronisation: a `ClientSyncRequested` is answered only after every
//// earlier message was handled, so "nothing else was sent" is checked by
//// the barrier's model_sync arriving next. The runtime logs from its own
//// process before it answers, so its log lines are captured by then.

import brazier/cluster/log_capture
import brazier/effect
import brazier/error
import brazier/runtime
import brazier/test_ctx
import brazier/transport
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub type Model {
  /// `label` is server-only: it is in the title but not in the
  /// client-visible model.
  Model(count: Int, label: String)
}

pub type Msg {
  Inc
  Rename(String)
}

const went_over = "Title went over the limit"

const back_within = "Title back within the"

fn title(m: Model) -> String {
  m.label <> " (" <> int.to_string(m.count) <> ")"
}

fn decode(
  _name: String,
  handler_id: String,
  data: String,
  _path: String,
) -> Result(Msg, error.BrazierError) {
  case handler_id {
    "inc" -> Ok(Inc)
    "rename" -> Ok(Rename(data))
    "huge" -> Ok(Rename(string.repeat("x", runtime.title_max_bytes + 1)))
    _ -> Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
  }
}

fn update(m: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    Inc -> #(Model(..m, count: m.count + 1), effect.none())
    Rename(label) -> #(Model(..m, label: label), effect.none())
  }
}

fn start() -> Subject(runtime.RuntimeMessage(Msg)) {
  let config =
    runtime.RuntimeConfig(
      init: fn(_ctx) { Ok(#(Model(count: 0, label: "Inbox"), effect.none())) },
      update: update,
      decode_event: decode,
      encode_model: fn(m: Model) {
        "{\"count\":" <> int.to_string(m.count) <> "}"
      },
      route: None,
      restore_model: None,
      dynamic_subscriptions: None,
      on_notify: None,
      on_notification: None,
      secret_key: "runtime-title-limit-test-secret-0123456789",
      presence: None,
      title: Some(title),
    )
  let assert Ok(rt) = runtime.start(config, test_ctx.root())
    as "the test runtime must start"
  rt
}

fn join(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
) -> Subject(transport.InternalMessage) {
  let subject = process.new_subject()
  process.send(rt, runtime.ClientConnected(conn_id: conn_id, subject: subject))
  process.send(rt, runtime.ClientJoined(conn_id: conn_id, token: "", path: "/"))
  let assert transport.SendModelSync(..) = next(subject)
  subject
}

fn next(
  subject: Subject(transport.InternalMessage),
) -> transport.InternalMessage {
  let assert Ok(message) = process.receive(subject, 2000)
    as "the runtime must send the next frame within 2s"
  message
}

fn event(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  handler_id: String,
  data: String,
  clock: Int,
) -> Nil {
  process.send(
    rt,
    runtime.ClientEventReceived(
      conn_id: "c1",
      event_name: "click",
      handler_id: handler_id,
      event_data: data,
      target_path: "0",
      clock: clock,
      ops: [],
    ),
  )
}

/// The runtime answers with a model_sync only after every earlier message.
fn assert_barrier_next(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  subject: Subject(transport.InternalMessage),
) -> Nil {
  process.send(rt, runtime.ClientSyncRequested(conn_id: conn_id))
  let assert transport.SendModelSync(..) = next(subject)
  let assert Error(Nil) = process.receive(subject, 0)
    as "nothing but the barrier's model_sync was left to send"
  Nil
}

fn assert_title_too_large(message: transport.InternalMessage) -> Nil {
  let assert transport.SendError(reason: reason) = message
  let assert True = string.starts_with(reason, "Title too large: ")
  Nil
}

fn count(
  lines: List(log_capture.Line),
  level: String,
  fragment: String,
) -> Int {
  list.count(lines, fn(line) {
    line.level == level && string.contains(line.message, fragment)
  })
}

pub fn title_staying_over_the_limit_is_reported_once_test() {
  let rt = start()
  let #(_, logs) =
    log_capture.capture(fn() {
      let c1 = join(rt, "c1")
      let assert transport.SendTitle(title: "Inbox (0)") = next(c1)
      // Server-only change: the report, then the ack-only patch.
      event(rt, "huge", "", 1)
      assert_title_too_large(next(c1))
      let assert transport.SendPatch(..) = next(c1)
      // Still over the limit after each of these: a patch each, no report.
      event(rt, "inc", "", 2)
      let assert transport.SendPatch(..) = next(c1)
      event(rt, "inc", "", 3)
      let assert transport.SendPatch(..) = next(c1)
      assert_barrier_next(rt, "c1", c1)
    })
  let assert 1 = count(logs, "error", went_over)
    as "the title going over the limit is logged once"
  let assert 0 = count(logs, "info", back_within)
}

pub fn title_over_the_limit_again_after_being_within_it_is_reported_again_test() {
  let rt = start()
  let #(_, logs) =
    log_capture.capture(fn() {
      let c1 = join(rt, "c1")
      let assert transport.SendTitle(title: "Inbox (0)") = next(c1)
      event(rt, "huge", "", 1)
      assert_title_too_large(next(c1))
      let assert transport.SendPatch(..) = next(c1)
      // Back within the limit, at the title the browser still shows: the
      // transition is logged and nothing is resent.
      event(rt, "rename", "Inbox", 2)
      let assert transport.SendPatch(..) = next(c1)
      assert_barrier_next(rt, "c1", c1)
      // Over the limit again: reported again.
      event(rt, "huge", "", 3)
      assert_title_too_large(next(c1))
      let assert transport.SendPatch(..) = next(c1)
      event(rt, "inc", "", 4)
      let assert transport.SendPatch(..) = next(c1)
      assert_barrier_next(rt, "c1", c1)
    })
  let assert 2 = count(logs, "error", went_over)
    as "each time the title goes over the limit is logged"
  let assert 1 = count(logs, "info", back_within)
    as "the title going back within the limit is logged"
}

pub fn connection_joining_while_the_title_is_over_the_limit_is_told_once_test() {
  let rt = start()
  let #(_, logs) =
    log_capture.capture(fn() {
      let c1 = join(rt, "c1")
      let assert transport.SendTitle(title: "Inbox (0)") = next(c1)
      event(rt, "huge", "", 1)
      assert_title_too_large(next(c1))
      let assert transport.SendPatch(..) = next(c1)
      // The joiner has not been told: it gets the report instead of a
      // title, and the others are not told again.
      let c2 = join(rt, "c2")
      assert_title_too_large(next(c2))
      // A server-only update that keeps it over: c1's ack, no report.
      event(rt, "huge", "", 2)
      let assert transport.SendPatch(..) = next(c1)
      assert_barrier_next(rt, "c1", c1)
      assert_barrier_next(rt, "c2", c2)
      // Back within the limit at "Inbox (0)", the title c1 still shows; c2
      // shows its server render's title, so the title goes to both.
      event(rt, "rename", "Inbox", 3)
      let assert transport.SendTitle(title: "Inbox (0)") = next(c1)
      let assert transport.SendPatch(..) = next(c1)
      let assert transport.SendTitle(title: "Inbox (0)") = next(c2)
      assert_barrier_next(rt, "c1", c1)
      assert_barrier_next(rt, "c2", c2)
    })
  let assert 1 = count(logs, "error", went_over)
    as "one time over the limit is logged once, whoever joins meanwhile"
  let assert 1 = count(logs, "info", back_within)
}
