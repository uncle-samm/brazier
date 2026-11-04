/// A listener that stops or restarts must free its port before anything
/// binds it again. The runtime closes a port asynchronously after its owner
/// exits, so a listen socket left to the runtime made an immediate rebind
/// fail with `eaddrinuse` under load (WS9 saw it burn the application
/// tree's restart tolerance). The listen socket owner now closes the socket
/// in its terminate callback. These tests rebind one fixed port hundreds of
/// times, with no sleep between a stop and the next start; the flake gate
/// runs them under CPU load.
import brazier/await
import brazier/cluster/log_capture
import brazier/cluster/peer.{Timeout}
import brazier/transport/server.{type Socket}
import gleam/erlang/process.{type Pid}
import gleam/int

/// Stop/start cycles on one port.
const stop_start_cycles = 100

/// Listeners whose connection owner is killed twice each (the listener's
/// restart tolerance is 3 in 10 s). Under 12 busy loops the old ownership
/// failed a rebind within the first 160 listeners in each of 3 runs.
const tree_restart_listeners = 300

fn options(port: Int) -> server.ListenerOptions {
  server.ListenerOptions(..server.default_listener_options(port), acceptors: 10)
}

/// A port the OS just handed out and that is free again.
fn fixed_port() -> Int {
  let assert Ok(listener) = server.start(options(0), answer_ok)
    as "a port-0 listener must start"
  let port = server.get_port(listener)
  server.stop(listener)
  port
}

/// A stopped listener frees its port by the time `server.stop` returns.
/// (The old ownership passed this one too: the connection owner's drain,
/// which runs after the socket owner exits, hid the late close. The tree
/// restart below has no drain in between.)
pub fn stopped_listener_frees_its_port_at_once_test_() -> peer.Timeout {
  use <- Timeout(60)
  let port = fixed_port()
  int.range(from: 1, to: stop_start_cycles + 1, with: Nil, run: fn(_, cycle) {
    case server.start(options(port), answer_ok) {
      Ok(listener) -> {
        let assert True = server.get_port(listener) == port
        server.stop(listener)
      }
      Error(reason) ->
        panic as {
          "cycle "
          <> int.to_string(cycle)
          <> ": rebinding port "
          <> int.to_string(port)
          <> " failed: "
          <> reason
        }
    }
  })
  // The last stop freed the port too.
  let assert Ok(listener) = server.start(options(port), answer_ok)
  let assert Ok(200) = http_status(port)
  server.stop(listener)
}

/// A restart inside the listener tree (the connection owner dies, so
/// rest_for_one restarts the socket owner and the acceptors) rebinds the
/// same port at once and serves again. This is the restart WS9 saw fail:
/// rest_for_one starts the new socket owner as soon as the old one exits.
pub fn restart_inside_the_listener_tree_rebinds_its_port_test_() -> peer.Timeout {
  use <- Timeout(60)
  let port = fixed_port()
  int.range(from: 0, to: tree_restart_listeners, with: Nil, run: fn(_, _) {
    let assert Ok(listener) = server.start(options(port), answer_ok)
    let sup = server.get_supervisor(listener)
    restart_through_the_connection_owner(sup)
    restart_through_the_connection_owner(sup)
    let assert Ok(200) = http_status(port)
    server.stop(listener)
  })
}

fn restart_through_the_connection_owner(sup: Pid) -> Nil {
  let conns = connection_owner(sup)
  let socket_owner = listen_socket_owner(sup)
  let restarted = await.watch_exit(sup, conns)
  kill(conns)
  await.expect_info(restarted, sup, "the listener to restart its children")
  // A failed rebind leaves the socket owner `restarting`.
  let assert True = children_running(sup)
    as "every listener child must be running right after the restart"
  let assert False = listen_socket_owner(sup) == socket_owner
  Nil
}

/// The listen socket closing under its owner is a failure, not a silent
/// stop: the owner logs it and exits, and the acceptors restart on a new
/// socket on the same port.
pub fn listen_socket_closed_underneath_restarts_the_acceptors_test() {
  let assert Ok(listener) = server.start(options(0), answer_ok)
  let port = server.get_port(listener)
  let sup = server.get_supervisor(listener)
  let owner = listen_socket_owner(sup)
  let #(Nil, logs) =
    log_capture.capture(fn() {
      let restarted = await.watch_exit(sup, owner)
      close_listen_socket(owner)
      await.expect_info(restarted, sup, "the socket owner to be restarted")
    })
  let assert True =
    log_capture.contains(
      logs,
      "error",
      "listen socket on port " <> int.to_string(port) <> " closed",
    )
  let assert True = children_running(sup)
  let assert False = listen_socket_owner(sup) == owner
  let assert Ok(200) = http_status(port)
  server.stop(listener)
}

@external(erlang, "brazier_listener_rebind_test_ffi", "answer_ok")
fn answer_ok(socket: Socket) -> Nil

@external(erlang, "brazier_listener_rebind_test_ffi", "http_status")
fn http_status(port: Int) -> Result(Int, String)

@external(erlang, "brazier_listener_rebind_test_ffi", "listen_socket_owner")
fn listen_socket_owner(listener_supervisor: Pid) -> Pid

@external(erlang, "brazier_listener_rebind_test_ffi", "connection_owner")
fn connection_owner(listener_supervisor: Pid) -> Pid

@external(erlang, "brazier_listener_rebind_test_ffi", "children_running")
fn children_running(listener_supervisor: Pid) -> Bool

@external(erlang, "brazier_listener_rebind_test_ffi", "close_listen_socket")
fn close_listen_socket(owner: Pid) -> Nil

@external(erlang, "brazier_listener_rebind_test_ffi", "kill")
fn kill(pid: Pid) -> Nil
