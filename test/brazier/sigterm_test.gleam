//// SIGTERM and `stop` beyond the single-waiter case: `wait_forever` drains
//// every application on the node, whichever process started it; a second
//// SIGTERM during the drain is ignored instead of reaching OTP's
//// `init:stop()`; a process that starts waiting after SIGTERM waits for the
//// drain; and stopping an application that is not running is one warning.
////
//// SIGTERM tests run on a peer node, so the test VM's own signal handling
//// is untouched. Tests synchronize on traces, monitors and replies; nothing
//// sleeps.

import brazier/app_config_fixture
import brazier/application
import brazier/cluster/log_capture
import brazier/cluster/peer.{Timeout}
import brazier/effect
import brazier/error
import brazier/html
import brazier/log_capture as own_log
import brazier/monitored
import brazier/presence/holder
import brazier/transport/server
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Inc
}

type RawSocket

type WsSocket

/// A request handler that is busy: its pid, and the subject that lets it
/// answer.
type Busy {
  Busy(handler: Pid, release: Subject(Nil))
}

const host = "127.0.0.1"

/// An app whose `/slow` handler reports itself on `busy` and answers only
/// once released.
fn config(busy: Subject(Busy)) -> application.AppConfig(Model, Msg) {
  let base =
    app_config_fixture.new(
      port: 0,
      init: fn(_ctx) { Ok(#(Model(count: 0), effect.none())) },
      update: fn(model: Model, _msg) {
        #(Model(count: model.count + 1), effect.none())
      },
      view: fn(model: Model) {
        html.div([], [html.text(int.to_string(model.count))])
      },
      encode_model: fn(model: Model) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      },
      decode_event: fn(_name, _handler, _data, _path) { Ok(Inc) },
    )
  application.AppConfig(
    ..base,
    api_handler: Some(fn(req: request.Request(server.Connection)) {
      case req.path {
        "/slow" -> {
          let release = process.new_subject()
          process.send(busy, Busy(handler: process.self(), release: release))
          let assert Ok(Nil) = process.receive(release, 60_000)
            as "the test releases the busy handler"
          Some(
            response.new(200)
            |> response.set_body(
              server.Bytes(bytes_tree.from_string("slow done")),
            ),
          )
        }
        _ -> None
      }
    }),
  )
}

/// Run `start` in a new process that then blocks in `wait_forever`.
/// Returns once its SIGTERM handler is installed, with the subject told
/// when `wait_forever` returns.
fn spawn_waiter(start: fn() -> Nil) -> Subject(Nil) {
  let ready = process.new_subject()
  let returned = process.new_subject()
  let waiter =
    process.spawn_unlinked(fn() {
      let go = process.new_subject()
      process.send(ready, go)
      let assert Ok(Nil) = process.receive(go, 5000)
      start()
      application.wait_forever()
      process.send(returned, Nil)
    })
  let assert Ok(go) = process.receive(ready, 5000)
  trace_install(waiter)
  process.send(go, Nil)
  let assert Ok(Nil) = await_install(waiter, 5000)
  returned
}

pub fn app_started_by_another_process_is_drained_on_sigterm_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "sigterm_other_starter")
  let assert [p] = peers
  let outcome =
    peer.on(p, fn() {
      // The app's starter is not the process that waits.
      let starter = holder.start()
      let assert Ok(app) =
        holder.run(starter, fn() {
          application.start_supervised(config(process.new_subject()))
        })
      let returned = spawn_waiter(fn() { Nil })
      let socket = open_websocket(app.port)
      sigterm_self()
      let code = await_close_code(socket)
      raw_close(socket)
      let assert Ok(Nil) = process.receive(returned, 10_000)
        as "wait_forever must return after the drain"
      #(code, process.is_alive(app.supervisor_pid), signal_handlers())
    })
  let assert #(1001, False, ["erl_signal_handler"]) = outcome
  Nil
}

pub fn second_sigterm_during_the_drain_is_ignored_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "sigterm_twice")
  let assert [p] = peers
  let outcome =
    peer.on(p, fn() {
      let busy = process.new_subject()
      let started = process.new_subject()
      let returned =
        spawn_waiter(fn() {
          let assert Ok(app) = application.start_supervised(config(busy))
          process.send(started, app)
        })
      let assert Ok(app) = process.receive(started, 5000)
      let assert Ok(socket) = connect(app.port)
      let assert Ok(Nil) = send(socket, get("/slow", app.port))
      let assert Ok(Busy(handler:, release:)) = process.receive(busy, 5000)
        as "the slow handler must start"
      trace_receive(handler)
      sigterm_self()
      // The drain has begun: the busy handler was told to finish.
      let assert Ok(Nil) = await_drain_received(handler, 5000)
      let #(Nil, lines) = log_capture.capture(sigterm_and_wait)
      let warned =
        log_capture.contains(lines, "warning", "SIGTERM received again")
      let during = signal_handlers()
      // A process that starts waiting now is told at once, and waits for
      // the drain under way: it cannot return before the slow request ends.
      let late = spawn_waiter(fn() { Nil })
      let late_early = process.receive(late, 0)
      process.send(release, Nil)
      let assert Ok(#(200, headers, <<"slow done">>)) =
        read_response(socket, 5000)
      let assert Ok(Nil) = await_closed(socket, 5000)
      let assert Ok(Nil) = process.receive(returned, 10_000)
        as "wait_forever must return after the drain"
      let assert Ok(Nil) = process.receive(late, 10_000)
        as "the late waiter must return after the drain"
      #(
        warned,
        during,
        late_early,
        list.key_find(headers, "connection"),
        process.is_alive(app.supervisor_pid),
        signal_handlers(),
      )
    })
  let assert #(
    True,
    ["brazier_signal_handler"],
    Error(Nil),
    Ok("close"),
    False,
    ["erl_signal_handler"],
  ) = outcome
  Nil
}

pub fn stopping_twice_is_one_warning_test() {
  let assert Ok(app) = application.start(config(process.new_subject()))
  let assert Ok(Nil) = application.stop(app)
  let #(again, lines) = own_log.capture(fn() { application.stop(app) })
  let assert Error(error.ConfigError(reason)) = again
  let assert True = string.contains(reason, "is not running")
  let assert True = string.contains(reason, "it was stopped already")
  let assert True =
    own_log.has(lines, level: "warning", containing: ["was not stopped"])
  let assert False = own_log.has(lines, level: "error", containing: [])
  Nil
}

/// A tree that died without `stop` is forgotten, bound port included, by
/// its watcher; stopping it is one warning, and returns with the port
/// forgotten whichever of the two got there first.
pub fn stopping_a_dead_tree_forgets_its_port_test() {
  let started = process.new_subject()
  // Monitored from the spawn, so its DOWN carries the reason it died with.
  let #(_starter, starter_monitor) =
    monitored.spawn(fn() {
      let assert Ok(app) = application.start(config(process.new_subject()))
        as "the application starts"
      process.send(started, app)
      // Blocks until the kill below takes it down with the tree.
      let never: Subject(Nil) = process.new_subject()
      process.receive_forever(never)
    })
  let assert Ok(app) = process.receive(started, 5000)
    as "the starter reports the started application"
  let supervisor_monitor = process.monitor(app.supervisor_pid)
  process.kill(app.supervisor_pid)
  let assert Ok(process.ProcessDown(reason: process.Killed, ..)) =
    process.selector_receive(
      process.new_selector()
        |> process.select_specific_monitor(supervisor_monitor, fn(down) { down }),
      5000,
    )
  // The starter is linked to the listener's supervisor and goes with it,
  // with the supervisor's own reason.
  let assert process.Killed =
    monitored.down_reason(starter_monitor, "the starter linked to the tree")
  let #(outcome, lines) = own_log.capture(fn() { application.stop(app) })
  let assert Error(error.ConfigError(reason)) = outcome
  let assert True = string.contains(reason, "or its tree exited")
  let assert False = own_log.has(lines, level: "error", containing: [])
  let assert False = server.release(app.listener)
  let assert Error(error.ConfigError(again)) = application.stop(app)
  let assert True = string.contains(again, "is not running")
  Nil
}

fn get(path: String, port: Int) -> BitArray {
  bit_array.from_string(
    "GET "
    <> path
    <> " HTTP/1.1\r\nHost: "
    <> host
    <> ":"
    <> int.to_string(port)
    <> "\r\n\r\n",
  )
}

fn open_websocket(port: Int) -> WsSocket {
  let authority = host <> ":" <> int.to_string(port)
  let assert Ok(socket) = raw_connect(host, port)
    as "test client must connect to the listener"
  let assert Ok(Nil) =
    raw_send(
      socket,
      raw_upgrade_request("/ws?path=%2F", authority, [
        #("Upgrade", "websocket"),
        #("Connection", "Upgrade"),
        #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
        #("Sec-WebSocket-Version", "13"),
        #("Origin", "http://" <> authority),
      ]),
    )
  let assert Ok(#(-1, head)) = raw_recv_frame(socket, 5000)
    as "server must answer the upgrade request"
  let assert Ok(head) = bit_array.to_string(head)
  let assert "101" = string.slice(head, 9, 3)
  socket
}

/// Skip data frames until the close frame; return its code.
fn await_close_code(socket: WsSocket) -> Int {
  case raw_recv_frame(socket, 5000) {
    Ok(#(8, <<code:16, _reason:bits>>)) -> code
    Ok(#(_opcode, _payload)) -> await_close_code(socket)
    Error(reason) -> panic as { "no close frame: " <> reason }
  }
}

@external(erlang, "brazier_ws_test_ffi", "raw_connect")
fn raw_connect(host: String, port: Int) -> Result(WsSocket, String)

@external(erlang, "brazier_ws_test_ffi", "raw_send")
fn raw_send(socket: WsSocket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_ws_test_ffi", "raw_recv_frame")
fn raw_recv_frame(
  socket: WsSocket,
  timeout: Int,
) -> Result(#(Int, BitArray), String)

@external(erlang, "brazier_ws_test_ffi", "raw_close")
fn raw_close(socket: WsSocket) -> Nil

@external(erlang, "brazier_ws_test_ffi", "raw_upgrade_request")
fn raw_upgrade_request(
  path: String,
  host: String,
  headers: List(#(String, String)),
) -> BitArray

@external(erlang, "brazier_ws8c_drain_ffi", "connect")
fn connect(port: Int) -> Result(RawSocket, String)

@external(erlang, "brazier_ws8c_drain_ffi", "send")
fn send(socket: RawSocket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_ws8c_drain_ffi", "read_response")
fn read_response(
  socket: RawSocket,
  timeout: Int,
) -> Result(#(Int, List(#(String, String)), BitArray), String)

@external(erlang, "brazier_ws8c_drain_ffi", "await_closed")
fn await_closed(socket: RawSocket, timeout: Int) -> Result(Nil, String)

@external(erlang, "brazier_ws8c_drain_ffi", "trace_receive")
fn trace_receive(pid: Pid) -> Nil

@external(erlang, "brazier_ws8c_drain_ffi", "await_drain_received")
fn await_drain_received(pid: Pid, timeout: Int) -> Result(Nil, String)

@external(erlang, "brazier_ws8c_drain_ffi", "trace_install")
fn trace_install(pid: Pid) -> Nil

@external(erlang, "brazier_ws8c_drain_ffi", "await_install")
fn await_install(pid: Pid, timeout: Int) -> Result(Nil, String)

@external(erlang, "brazier_ws8c_drain_ffi", "sigterm_self")
fn sigterm_self() -> Nil

@external(erlang, "brazier_ws8c_drain_ffi", "signal_handlers")
fn signal_handlers() -> List(String)

@external(erlang, "brazier_sigterm_test_ffi", "sigterm_and_wait")
fn sigterm_and_wait() -> Nil
