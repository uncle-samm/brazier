//// The runtime keeps the browser's document title in sync with the server
//// state: the title is sent on every join and after an update that
//// changes it, never otherwise.
////
//// Synchronisation: a `ClientSyncRequested` is answered only after every
//// earlier message was handled, so "no title was sent" is checked by the
//// barrier's model_sync arriving next.

import brazier/effect
import brazier/error
import brazier/runtime
import brazier/test_ctx
import brazier/transport
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import gleam/string

pub type Model {
  /// `label` is server-only: it is in the title but not in the
  /// client-visible model.
  Model(count: Int, label: String)
}

pub type Msg {
  Inc
  Noop
  Rename(String)
}

fn model_json(m: Model) -> String {
  "{\"count\":" <> int.to_string(m.count) <> "}"
}

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
    "noop" -> Ok(Noop)
    "rename" -> Ok(Rename(data))
    "huge" -> Ok(Rename(string.repeat("x", runtime.title_max_bytes + 1)))
    _ -> Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
  }
}

fn update(m: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    Inc -> #(Model(..m, count: m.count + 1), effect.none())
    Noop -> #(m, effect.none())
    Rename(label) -> #(Model(..m, label: label), effect.none())
  }
}

fn config() -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(count: 0, label: "Inbox"), effect.none())) },
    update: update,
    decode_event: decode,
    encode_model: model_json,
    route: None,
    restore_model: None,
    dynamic_subscriptions: None,
    on_notify: None,
    on_notification: None,
    secret_key: "runtime-title-test-secret-0123456789",
    presence: None,
    title: Some(title),
  )
}

fn start(config: runtime.RuntimeConfig(Model, Msg)) {
  let assert Ok(rt) = runtime.start(config, test_ctx.root())
  rt
}

fn join(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
) -> Subject(transport.InternalMessage) {
  let subject = process.new_subject()
  process.send(rt, runtime.ClientConnected(conn_id: conn_id, subject: subject))
  process.send(rt, runtime.ClientJoined(conn_id: conn_id, token: "", path: "/"))
  subject
}

fn next(
  subject: Subject(transport.InternalMessage),
) -> transport.InternalMessage {
  let assert Ok(message) = process.receive(subject, 2000)
  message
}

fn event(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  handler_id: String,
  data: String,
  clock: Int,
) -> Nil {
  process.send(
    rt,
    runtime.ClientEventReceived(
      conn_id: conn_id,
      event_name: "click",
      handler_id: handler_id,
      event_data: data,
      target_path: "0",
      clock: clock,
      ops: "",
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
  Nil
}

/// Join and consume the join's model_sync and title.
fn joined(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
) -> Subject(transport.InternalMessage) {
  let subject = join(rt, conn_id)
  let assert transport.SendModelSync(..) = next(subject)
  let assert transport.SendTitle(title: "Inbox (0)") = next(subject)
  subject
}

pub fn join_sends_title_after_model_sync_test() {
  let rt = start(config())
  let _subject = joined(rt, "c1")
  Nil
}

pub fn update_that_changes_title_sends_it_to_every_joined_connection_test() {
  let rt = start(config())
  let a = joined(rt, "a")
  let b = joined(rt, "b")
  event(rt, "a", "inc", "{}", 1)
  let assert transport.SendPatch(..) = next(a)
  let assert transport.SendTitle(title: "Inbox (1)") = next(a)
  let assert transport.SendPatch(..) = next(b)
  let assert transport.SendTitle(title: "Inbox (1)") = next(b)
  assert_barrier_next(rt, "a", a)
  assert_barrier_next(rt, "b", b)
}

pub fn update_that_keeps_title_sends_no_title_test() {
  let rt = start(config())
  let subject = joined(rt, "c1")
  event(rt, "c1", "noop", "{}", 1)
  // The ack-only patch, and no title.
  let assert transport.SendPatch(..) = next(subject)
  assert_barrier_next(rt, "c1", subject)
}

pub fn server_only_change_sends_title_without_model_change_test() {
  let rt = start(config())
  let subject = joined(rt, "c1")
  event(rt, "c1", "rename", "Drafts", 1)
  // The client-visible model is unchanged, so no model patch: the title,
  // which comes from server-only state, then the event's ack-only patch.
  let assert transport.SendTitle(title: "Drafts (0)") = next(subject)
  let assert transport.SendPatch(..) = next(subject)
  assert_barrier_next(rt, "c1", subject)
}

pub fn rejoin_sends_title_again_test() {
  let rt = start(config())
  let subject = joined(rt, "c1")
  process.send(rt, runtime.ClientJoined(conn_id: "c1", token: "", path: "/"))
  let assert transport.SendModelSync(..) = next(subject)
  let assert transport.SendTitle(title: "Inbox (0)") = next(subject)
  assert_barrier_next(rt, "c1", subject)
}

pub fn title_over_limit_fails_loudly_and_is_not_sent_test() {
  let rt = start(config())
  let subject = joined(rt, "c1")
  // A server-only change (see above): the error, then the ack-only patch.
  event(rt, "c1", "huge", "{}", 1)
  let assert transport.SendError(reason: reason) = next(subject)
  let assert True = string.starts_with(reason, "Title too large: ")
  let assert transport.SendPatch(..) = next(subject)
  assert_barrier_next(rt, "c1", subject)
  // The browsers still show the last title sent, so the title the state
  // returns to is not resent, and a new one under the limit is.
  event(rt, "c1", "rename", "Inbox", 2)
  let assert transport.SendPatch(..) = next(subject)
  assert_barrier_next(rt, "c1", subject)
  event(rt, "c1", "rename", "Sent", 3)
  let assert transport.SendTitle(title: "Sent (0)") = next(subject)
  let assert transport.SendPatch(..) = next(subject)
  assert_barrier_next(rt, "c1", subject)
}

pub fn no_title_function_sends_no_title_test() {
  let rt = start(runtime.RuntimeConfig(..config(), title: None))
  let subject = join(rt, "c1")
  let assert transport.SendModelSync(..) = next(subject)
  event(rt, "c1", "inc", "{}", 1)
  let assert transport.SendPatch(..) = next(subject)
  assert_barrier_next(rt, "c1", subject)
}
