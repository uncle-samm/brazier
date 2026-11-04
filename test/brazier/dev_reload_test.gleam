/// Dev live reload, end to end: `brazier/dev` turns live reload on, every
/// WebSocket handler then subscribes to the dev reload topic, and a rebuild
/// broadcast reaches the browser as a `reload` message.
///
/// Live reload is a VM-wide switch, so the tests that turn it on run on a
/// fresh peer node and never touch this VM's state. Unhappy paths first.
import brazier/cluster/peer.{Timeout}
import brazier/internal/dev_watch
import brazier/pubsub
import brazier/transport
import brazier/transport/server
import brazier/transport/ws
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import gleam/string

// --- Harness ---

type RawSocket

type Observed {
  Connected(conn_id: String)
  GotEvent(conn_id: String, msg: transport.ClientMessage)
  ClosedConn(conn_id: String)
}

@external(erlang, "brazier_ws_test_ffi", "raw_connect")
fn raw_connect(host: String, port: Int) -> Result(RawSocket, String)

@external(erlang, "brazier_ws_test_ffi", "raw_send")
fn raw_send(socket: RawSocket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_ws_test_ffi", "raw_recv_frame")
fn raw_recv_frame(
  socket: RawSocket,
  timeout: Int,
) -> Result(#(Int, BitArray), String)

@external(erlang, "brazier_ws_test_ffi", "raw_close")
fn raw_close(socket: RawSocket) -> Nil

@external(erlang, "brazier_ws_test_ffi", "raw_upgrade_request")
fn raw_upgrade_request(
  path: String,
  host: String,
  headers: List(#(String, String)),
) -> BitArray

@external(erlang, "brazier_ws_test_ffi", "masked_frame")
fn masked_frame(fin: Int, opcode: Int, payload: BitArray) -> BitArray

@external(erlang, "brazier_dev_ffi", "enable_live_reload")
fn enable_live_reload() -> Nil

@external(erlang, "brazier_dev_ffi", "live_reload_enabled")
fn live_reload_enabled() -> Bool

@external(erlang, "brazier_dev_ffi", "live_reload_topic")
fn live_reload_topic() -> String

@external(erlang, "brazier_dev_ffi", "notify_browser_reload")
fn notify_browser_reload() -> Result(Int, String)

@external(erlang, "brazier_dev_reload_test_ffi", "classify_reload")
fn classify_reload(topic: String) -> ws.SocketEvent

const host = "127.0.0.1"

fn start_server() -> #(server.Listener, Int, Subject(Observed)) {
  let observer = process.new_subject()
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: Some(fn(conn_id, _runtime, _req) {
        process.send(observer, Connected(conn_id))
        Ok(
          #(
            fn(cid, msg) { process.send(observer, GotEvent(cid, msg)) },
            fn(cid) { process.send(observer, ClosedConn(cid)) },
          ),
        )
      }),
      ws_auth: None,
      ssr_factory: None,
      security_limits: transport.default_security_limits(),
      api_handler: None,
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "the test listener must start"
  #(listener, server.get_port(listener), observer)
}

/// Upgrade a raw TCP connection and wait for the runtime factory.
fn open(port: Int, observer: Subject(Observed)) -> #(RawSocket, String) {
  let host_header = host <> ":" <> int.to_string(port)
  let assert Ok(socket) = raw_connect(host, port)
  let assert Ok(Nil) =
    raw_send(
      socket,
      raw_upgrade_request("/ws?path=%2F", host_header, [
        #("Upgrade", "websocket"),
        #("Connection", "Upgrade"),
        #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
        #("Sec-WebSocket-Version", "13"),
        #("Origin", "http://" <> host_header),
      ]),
    )
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 3000)
  let assert Ok(head) = bit_array.to_string(head)
  let assert "101" = string.slice(head, 9, 3)
  let assert Ok(Connected(conn_id)) = process.receive(observer, 3000)
    as "the runtime factory must be called"
  #(socket, conn_id)
}

/// Send a join without a build id and wait until the runtime gets it. The
/// handler subscribes before it reads the socket, so once a join is
/// dispatched the subscription, if any, is in place.
fn join(socket: RawSocket, observer: Subject(Observed)) -> Nil {
  let text = "{\"type\":\"join\",\"token\":\"\",\"path\":\"/\"}"
  let assert Ok(Nil) = raw_send(socket, masked_frame(1, 1, <<text:utf8>>))
  let assert Ok(GotEvent(_, transport.ClientJoin(token: "", path: "/"))) =
    process.receive(observer, 3000)
    as "the join must be dispatched"
  Nil
}

/// The next frame that is not a ping.
fn next_frame(socket: RawSocket) -> #(Int, BitArray) {
  case raw_recv_frame(socket, 5000) {
    Ok(#(9, _ping)) -> next_frame(socket)
    Ok(frame) -> frame
    Error(reason) -> panic as { "expected a frame: " <> reason }
  }
}

// --- The watcher dev mode needs ---

pub fn a_missing_watcher_names_the_program_and_package_test() {
  let assert Error(reason) =
    dev_watch.check_with(
      Ok(#("fswatch", "fswatch (brew install fswatch)")),
      fn(_) { Error(Nil) },
    )
  let assert True = string.contains(reason, "fswatch, which is not installed")
  let assert True = string.contains(reason, "Install fswatch (brew install")
  let assert Error(reason) =
    dev_watch.check_with(
      Ok(#("inotifywait", "inotify-tools (apt install inotify-tools)")),
      fn(_) { Error(Nil) },
    )
  let assert True = string.contains(reason, "inotifywait, which is not")
  let assert True = string.contains(reason, "Install inotify-tools")
}

pub fn an_os_without_a_watcher_is_an_error_test() {
  let assert Error("no watcher here") =
    dev_watch.check_with(Error("no watcher here"), fn(_) {
      panic as "no program to look up"
    })
}

pub fn an_installed_watcher_is_accepted_test() {
  let assert Ok("fswatch") =
    dev_watch.check_with(Ok(#("fswatch", "fswatch")), fn(program) {
      let assert "fswatch" = program
      Ok("/usr/local/bin/fswatch")
    })
}

pub fn this_os_has_a_watcher_requirement_test() {
  // The test machines run macOS or Linux.
  let assert Ok(#(program, package)) = dev_watch.requirement()
  let assert True = program == "fswatch" || program == "inotifywait"
  let assert True = string.contains(package, "install")
  let assert Error(Nil) =
    dev_watch.find_executable("brazier-no-such-program-" <> program)
}

// --- Classifying the broadcast ---

pub fn the_reload_broadcast_is_classified_on_its_topic_only_test() {
  let assert ws.DevReload = classify_reload(live_reload_topic())
  let assert ws.UnexpectedMessage(description) =
    classify_reload("brazier:other")
  let assert True = string.contains(description, "brazier_dev_reload")
}

// --- Outside dev mode ---

pub fn outside_dev_mode_no_connection_subscribes_test() {
  pubsub.start()
  let assert False = live_reload_enabled()
  let #(listener, port, observer) = start_server()
  let #(socket, _conn_id) = open(port, observer)
  join(socket, observer)
  let assert 0 = pubsub.local_subscriber_count(live_reload_topic())
  let assert Ok(0) = notify_browser_reload()
  raw_close(socket)
  server.stop(listener)
}

// --- Under dev mode, on a fresh peer ---

pub fn a_failed_subscription_closes_1011_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_dev_reload_fail")
  let assert [node] = peers
  // PubSub is not started on the fresh peer, so the subscription fails.
  let #(code, reason, closed) =
    peer.on(node, fn() {
      enable_live_reload()
      let #(listener, port, observer) = start_server()
      let #(socket, conn_id) = open(port, observer)
      let #(code, reason) = case next_frame(socket) {
        #(8, <<code:16, reason:bits>>) -> {
          let assert Ok(reason) = bit_array.to_string(reason)
          #(code, reason)
        }
        #(opcode, _) ->
          panic as { "expected a close, got opcode " <> int.to_string(opcode) }
      }
      let assert Ok(ClosedConn(closed_id)) = process.receive(observer, 5000)
        as "on_close must run"
      raw_close(socket)
      server.stop(listener)
      #(code, reason, closed_id == conn_id)
    })
  let assert 1011 = code
  let assert "internal error" = reason
  let assert True = closed
  Nil
}

pub fn a_rebuild_reloads_every_open_page_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_dev_reload_ok")
  let assert [node] = peers
  let frames =
    peer.on(node, fn() {
      pubsub.start()
      enable_live_reload()
      let #(listener, port, observer) = start_server()
      let #(first, _) = open(port, observer)
      join(first, observer)
      let #(second, _) = open(port, observer)
      join(second, observer)
      let assert 2 = pubsub.local_subscriber_count(live_reload_topic())
      let assert Ok(2) = notify_browser_reload()
      let frames = [next_frame(first), next_frame(second)]
      // The page reloads; the server does not close the socket for it.
      raw_close(first)
      raw_close(second)
      server.stop(listener)
      frames
    })
  let assert [#(1, a), #(1, b)] = frames
  let assert True = a == <<"{\"type\":\"reload\"}":utf8>>
  let assert True = b == a
  Nil
}
