import brazier/effect
import brazier/error
import brazier/internal/context
import brazier/log_capture
import brazier/router
import brazier/runtime
import brazier/transport
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import gleam/uri

// --- segments / query ---

fn parse(raw: String) -> uri.Uri {
  let assert Ok(parsed) = uri.parse(raw)
  parsed
}

pub fn segments_decodes_and_drops_empty_segments_test() {
  let assert ["users", "Jürgen"] = router.segments(parse("/users/J%C3%BCrgen/"))
  let assert [] = router.segments(parse("/"))
  let assert ["a", "b"] = router.segments(parse("/a//b///"))
}

pub fn segments_drops_dot_segments_test() {
  let assert ["b"] = router.segments(parse("/a/../b/."))
}

pub fn segments_keep_encoded_slash_inside_one_segment_test() {
  // `%2F` decodes after splitting, so it stays inside its segment.
  let assert ["files", "a/b"] = router.segments(parse("/files/a%2Fb"))
}

pub fn query_decodes_in_order_test() {
  let assert [#("q", "a b"), #("page", "2")] =
    router.query(parse("/search?q=a%20b&page=2"))
  let assert [] = router.query(parse("/search"))
}

pub fn query_keeps_repeated_keys_test() {
  let assert [#("t", "1"), #("t", "2")] = router.query(parse("/?t=1&t=2"))
}

pub fn check_local_path_accepts_same_origin_paths_test() {
  let assert Ok(Nil) = router.check_local_path("/")
  let assert Ok(Nil) = router.check_local_path("/users/7?tab=posts")
  let assert Ok(Nil) = router.check_local_path("/search?q=a%20b#top")
  let assert Ok(Nil) = router.check_local_path("/users/J%C3%BCrgen")
  let assert Ok(Nil) = router.check_local_path("/caf\u{E9}/a b")
}

pub fn check_local_path_refuses_other_origins_test() {
  let assert Error("it starts with two slashes" <> _) =
    router.check_local_path("//evil.example/x")
  let assert Error("it does not start with \"/\"") =
    router.check_local_path("https://evil.example/")
  let assert Error("it does not start with \"/\"") =
    router.check_local_path("javascript:alert(1)")
  let assert Error("it does not start with \"/\"") = router.check_local_path("")
  let assert Error("it does not start with \"/\"") =
    router.check_local_path("users")
  let assert Error("it does not start with \"/\"") =
    router.check_local_path("\\\\evil.example")
}

pub fn check_local_path_refuses_paths_a_browser_reads_as_another_host_test() {
  // SEC-5: the WHATWG URL parser reads `\` as `/` and strips tab, newline
  // and carriage return, so each of these loads evil.example.
  let assert Error("it starts with two slashes" <> _) =
    router.check_local_path("/\\evil.example")
  let assert Error("it contains a backslash" <> _) =
    router.check_local_path("/a\\..\\\\evil.example")
  let assert Error("it contains a control character" <> _) =
    router.check_local_path("/\t/evil.example")
  let assert Error("it contains a control character" <> _) =
    router.check_local_path("/\n/evil.example")
  let assert Error("it contains a control character" <> _) =
    router.check_local_path("/\r/evil.example")
  let assert Error("it contains a control character" <> _) =
    router.check_local_path("/x\u{0}y")
  let assert Error("it contains a control character" <> _) =
    router.check_local_path("/x\u{7F}y")
  let assert Error("it contains \"/%09\"" <> _) =
    router.check_local_path("/%09/evil.example")
}

/// The client's localPathRefusal (brazier_client/src/brazier_client/patch.mjs)
/// gives the verdict check_local_path gives, reason for reason, on every
/// path here: the server refuses to send what the client would refuse to
/// follow, and neither accepts a path the other refuses.
pub fn client_local_path_rule_matches_server_test() {
  let paths = [
    "/", "/users/7?tab=posts", "/search?q=a%20b#top", "/users/J%C3%BCrgen",
    "/caf\u{E9}/a b", "/x ", "/\u{2028}", "/%2F%2Fevil.example", "/a/%0A",
    "//evil.example/x", "https://evil.example/", "javascript:alert(1)", "",
    "users", " /x", "\\\\evil.example", "/\\evil.example",
    "/a\\..\\\\evil.example", "/ok?next=\\\\evil.example", "/\t/evil.example",
    "/\n/evil.example", "/\r/evil.example", "/x\u{0}y", "/x\u{1F}y", "/x\u{7F}y",
    "/%09/evil.example", "/a/%09",
  ]
  let expected =
    list.map(paths, fn(path) {
      case router.check_local_path(path) {
        Ok(Nil) -> option.None
        Error(reason) -> option.Some(reason)
      }
    })
  let file = scratch_path("local_path_parity.json")
  let assert Ok(Nil) =
    write_file(file, json.to_string(json.array(paths, json.string)))
    as "router_test: could not write the parity paths file"
  let output = case
    run_node("brazier_client/test/local_path_parity.mjs", file)
  {
    Ok(output) -> output
    Error(output) -> panic as { "client local path parity failed: " <> output }
  }
  let assert Ok(#(_, verdicts)) = string.split_once(output, "verdicts: ")
    as { "local_path_parity.mjs printed no verdicts: " <> output }
  let assert Ok(actual) =
    json.parse(verdicts, decode.list(decode.optional(decode.string)))
    as {
      "local_path_parity.mjs printed verdicts that do not decode: " <> output
    }
  let assert True = list.length(actual) == list.length(paths)
    as "local_path_parity.mjs gave a verdict count that differs from the paths"
  list.zip(paths, list.zip(expected, actual))
  |> list.each(fn(entry) {
    let #(path, #(server, client)) = entry
    let assert True = server == client
      as {
        "server and client disagree on "
        <> string.inspect(path)
        <> ": server "
        <> string.inspect(server)
        <> ", client "
        <> string.inspect(client)
      }
  })
}

@external(erlang, "brazier_patch_test_ffi", "run_node")
fn run_node(script: String, arg: String) -> Result(String, String)

@external(erlang, "brazier_patch_test_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "brazier_patch_test_ffi", "scratch_path")
fn scratch_path(name: String) -> String

pub fn backslash_push_logs_error_with_reason_test() {
  let #(Nil, logs) =
    log_capture.capture(fn() { perform(router.push("/\\evil.example")) })
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "router.push", "same-origin", "evil.example", "two slashes",
    ])
}

pub fn tab_redirect_logs_error_with_reason_test() {
  let #(Nil, logs) =
    log_capture.capture(fn() { perform(router.redirect("/\t/evil.example")) })
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "router.redirect", "same-origin", "control character",
    ])
}

// --- navigation effects outside a client event ---

fn perform(eff: effect.Effect(Nil)) -> Nil {
  effect.perform(eff, fn(_msg) { Nil }, fn(_key, _generation, _msg) { Nil })
}

pub fn non_local_push_logs_error_test() {
  let #(Nil, logs) =
    log_capture.capture(fn() { perform(router.push("https://evil.example/")) })
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "router.push", "same-origin", "evil.example",
    ])
}

pub fn non_local_replace_and_redirect_log_errors_test() {
  let #(Nil, logs) =
    log_capture.capture(fn() {
      perform(router.replace("//evil.example"))
      perform(router.redirect("javascript:x"))
    })
  let assert True =
    log_capture.has(logs, level: "error", containing: ["router.replace"])
  let assert True =
    log_capture.has(logs, level: "error", containing: ["router.redirect"])
}

pub fn push_without_connection_logs_warning_test() {
  let #(Nil, logs) = log_capture.capture(fn() { perform(router.push("/x")) })
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "router.push to \"/x\"", "no connection",
    ])
}

// --- navigation effects from a client event, through the runtime ---

type Model {
  Model
}

type Msg {
  Go(kind: String, path: String)
}

fn nav_config() -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model, effect.none())) },
    update: fn(model: Model, msg: Msg) {
      let Go(kind:, path:) = msg
      let eff = case kind {
        "push" -> router.push(path)
        "replace" -> router.replace(path)
        _ -> router.redirect(path)
      }
      #(model, eff)
    },
    encode_model: fn(_model) { "{}" },
    // The handler id carries the navigation: "push:/x".
    decode_event: fn(_name, handler_id, _data, _path) {
      case string.split_once(handler_id, ":") {
        Ok(#(kind, path)) -> Ok(Go(kind:, path:))
        Error(Nil) ->
          Error(error.RuntimeError(reason: "bad handler id " <> handler_id))
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
}

fn ctx() -> context.Context {
  context.new(
    uri: uri.Uri(..uri.empty, path: "/"),
    cookies: [],
    is_connected: True,
    session_id: Error(Nil),
  )
}

fn joined(
  conn_id: String,
) -> #(
  process.Subject(runtime.RuntimeMessage(Msg)),
  process.Subject(transport.InternalMessage),
) {
  let assert Ok(subject) = runtime.start(nav_config(), ctx())
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
    process.receive(transport_subject, 1000)
  #(subject, transport_subject)
}

fn click(
  subject: process.Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  handler_id: String,
) -> Nil {
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: conn_id,
      event_name: "click",
      handler_id: handler_id,
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: [],
    ),
  )
}

pub fn push_from_event_navigates_that_connection_test() {
  let #(subject, transport_subject) = joined("nav_push")
  click(subject, "nav_push", "push:/users/7?tab=posts")
  let assert Ok(transport.SendNavigate(path: "/users/7?tab=posts")) =
    process.receive(transport_subject, 1000)
  expect_ack(transport_subject)
  assert_nothing_more(transport_subject)
}

pub fn replace_from_event_sends_replace_navigate_test() {
  let #(subject, transport_subject) = joined("nav_replace")
  click(subject, "nav_replace", "replace:/settings")
  let assert Ok(transport.SendReplaceNavigate(path: "/settings")) =
    process.receive(transport_subject, 1000)
  expect_ack(transport_subject)
  assert_nothing_more(transport_subject)
}

pub fn redirect_from_event_sends_hard_navigate_test() {
  let #(subject, transport_subject) = joined("nav_redirect")
  click(subject, "nav_redirect", "redirect:/login")
  let assert Ok(transport.SendHardNavigate(path: "/login")) =
    process.receive(transport_subject, 1000)
  expect_ack(transport_subject)
  assert_nothing_more(transport_subject)
}

pub fn non_local_push_from_event_sends_nothing_test() {
  let #(subject, transport_subject) = joined("nav_evil")
  click(subject, "nav_evil", "push://evil.example/x")
  expect_ack(transport_subject)
  assert_nothing_more(transport_subject)
}

pub fn push_from_event_navigates_only_that_connection_test() {
  let #(subject, first) = joined("nav_a")
  let second = connect(subject, "nav_b")
  click(subject, "nav_a", "push:/first")
  let assert Ok(transport.SendNavigate(path: "/first")) =
    process.receive(first, 1000)
  expect_ack(first)
  assert_nothing_more(first)
  assert_nothing_more(second)
}

pub fn push_outside_event_navigates_every_connection_test() {
  // An effect's dispatched message (an async continuation, a timer) runs
  // outside any client event: its navigation follows the shared model to
  // every connection of the session, not just the last event's.
  let #(subject, first) = joined("nav_c")
  let second = connect(subject, "nav_d")
  click(subject, "nav_c", "push:/first")
  let assert Ok(transport.SendNavigate(path: "/first")) =
    process.receive(first, 1000)
  process.send(
    subject,
    runtime.EffectDispatched(message: Go(kind: "push", path: "/second")),
  )
  let assert Ok(transport.SendNavigate(path: "/second")) =
    receive_navigation(first)
  let assert Ok(transport.SendNavigate(path: "/second")) =
    receive_navigation(second)
}

/// Connect and join one more connection to a running session.
fn connect(
  subject: process.Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
) -> process.Subject(transport.InternalMessage) {
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
    process.receive(transport_subject, 1000)
  transport_subject
}

/// The next message that is not a patch or sync (event acks).
fn receive_navigation(
  transport_subject: process.Subject(transport.InternalMessage),
) -> Result(transport.InternalMessage, Nil) {
  case process.receive(transport_subject, 1000) {
    Ok(transport.SendPatch(..)) | Ok(transport.SendModelSync(..)) ->
      receive_navigation(transport_subject)
    other -> other
  }
}

/// The click's acknowledgement: navigating leaves the model unchanged, so
/// it is an empty patch at the joined revision.
fn expect_ack(
  transport_subject: process.Subject(transport.InternalMessage),
) -> Nil {
  let assert Ok(transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 1)) =
    process.receive(transport_subject, 1000)
  Nil
}

/// Assert the connection has been sent nothing more. Call it once the
/// click's ack has arrived: the runtime runs a click's update and its
/// navigation effects before it sends the ack, so anything else the click
/// sent is already in the mailbox.
fn assert_nothing_more(
  transport_subject: process.Subject(transport.InternalMessage),
) -> Nil {
  let assert Error(Nil) = process.receive(transport_subject, 0)
  Nil
}
