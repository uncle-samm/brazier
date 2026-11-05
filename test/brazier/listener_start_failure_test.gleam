/// A listener that cannot start returns an error naming the cause and
/// leaves its caller running. Its supervisor used to list its children in
/// `init`: a socket owner that could not bind failed the supervisor's own
/// start, whose exit (`{shutdown, {failed_to_start_child, ...}}`) killed a
/// caller that does not trap exits before `start` returned, and a caller
/// that does got the error `"shutdown"`, the cause lost. The supervisor now
/// starts empty and adds its children with `supervisor:start_child`, as
/// ranch starts its listeners (`brazier_http_listener_sup`).
import brazier/await
import brazier/transport/server.{type Socket}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/otp/actor

pub fn a_taken_port_is_an_error_naming_eaddrinuse_test() {
  let assert Ok(first) =
    server.start(server.default_listener_options(0), ignore_socket)
  let port = server.get_port(first)
  let keepers_before = keepers()
  let links_before = links()
  let assert False = traps_exits()
    as "the caller must not trap exits, or an exit signal would not kill it"
  let assert Error(reason) =
    server.start(server.default_listener_options(port), ignore_socket)
  // Reaching this line is the survival: an exit signal from the failed
  // tree would have killed this process.
  assert reason
    == "cannot listen on port "
    <> int.to_string(port)
    <> ": eaddrinuse (address already in use)"
  assert links() == links_before
    as "no process of the failed listener is left linked to the caller"
  assert keepers() == keepers_before
    as "the failed listener's keeper erased its entries and exited"
  server.stop(first)
}

pub fn a_caller_that_traps_exits_gets_no_exit_message_test() {
  let assert Ok(first) =
    server.start(server.default_listener_options(0), ignore_socket)
  let port = server.get_port(first)
  let report = process.new_subject()
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let result =
      server.start(server.default_listener_options(port), ignore_socket)
    process.send(report, #(result, mailbox_size()))
  })
  let assert Ok(#(Error(reason), messages)) = process.receive(report, 5000)
  assert reason
    == "cannot listen on port "
    <> int.to_string(port)
    <> ": eaddrinuse (address already in use)"
  // The partly started tree is unlinked before it is stopped, and stopping
  // it waits for its exit, so an 'EXIT' it sent would be here already.
  assert messages == 0 as "a failed start sends its caller no 'EXIT' message"
  server.stop(first)
}

/// Port 1 is privileged. A non-root bind to it is refused with `eacces` on
/// Linux; macOS lets anyone bind it on the wildcard address. The listener
/// must agree with what the OS says, and name `eacces` when it refuses.
pub fn a_privileged_port_matches_what_the_os_says_test() {
  let options = server.default_listener_options(1)
  case listen_probe(1) {
    Ok(Nil) -> {
      let assert Ok(listener) = server.start(options, ignore_socket)
        as "the OS lets this user bind port 1, so the listener must start"
      assert server.get_port(listener) == 1
      server.stop(listener)
    }
    Error("eacces") -> {
      let links_before = links()
      let assert Error(reason) = server.start(options, ignore_socket)
      assert reason == "cannot listen on port 1: eacces (permission denied)"
      assert links() == links_before
    }
    Error(other) ->
      panic as {
        "port 1 is refused with "
        <> other
        <> ", neither free nor privileged: something listens on it"
      }
  }
}

pub fn a_start_error_names_the_posix_cause_test() {
  assert describe_listen_failure(80, "eacces")
    == "cannot listen on port 80: eacces (permission denied)"
  assert describe_listen_failure(4000, "eaddrinuse")
    == "cannot listen on port 4000: eaddrinuse (address already in use)"
  // Any other child failure keeps the child and the reason.
  assert describe_acceptors_failure()
    == "the listener's acceptors failed to start: {no_listen_socket,listener}"
}

pub fn a_supervised_listener_on_a_taken_port_fails_with_the_cause_test() {
  let assert Ok(first) =
    server.start(server.default_listener_options(0), ignore_socket)
  let port = server.get_port(first)
  let keepers_before = keepers()
  let assert Ok(spec) =
    server.supervised(server.default_listener_options(port), ignore_socket)
  let assert [keeper] =
    list.filter(keepers(), fn(k) { !list.contains(keepers_before, k) })
    as "building the spec names the listener and starts its keeper"
  // The start function runs in the parent supervisor; here it runs in a
  // process that does not trap exits, which a failed start used to kill.
  let report = process.new_subject()
  let parent =
    process.spawn_unlinked(fn() {
      process.send(report, #(spec.start(), mailbox_size()))
    })
  let assert Ok(#(Error(actor.InitFailed(reason)), messages)) =
    process.receive(report, 5000)
  assert reason
    == "cannot listen on port "
    <> int.to_string(port)
    <> ": eaddrinuse (address already in use)"
  assert messages == 0
  // The parent held the entries; it has exited, so they go.
  await.expect_down(parent, "the stand-in parent")
  await.expect_down(
    keeper,
    "the keeper of a supervised listener that never ran",
  )
  assert keepers() == keepers_before
  server.stop(first)
}

/// No test here opens a connection, so the handler never runs.
fn ignore_socket(_socket: Socket) -> Nil {
  Nil
}

@external(erlang, "brazier_listener_start_failure_test_ffi", "listen_probe")
fn listen_probe(port: Int) -> Result(Nil, String)

@external(erlang, "brazier_listener_start_failure_test_ffi", "links")
fn links() -> List(Dynamic)

@external(erlang, "brazier_listener_start_failure_test_ffi", "traps_exits")
fn traps_exits() -> Bool

@external(erlang, "brazier_listener_start_failure_test_ffi", "mailbox_size")
fn mailbox_size() -> Int

@external(erlang, "brazier_listener_start_failure_test_ffi", "keepers")
fn keepers() -> List(Pid)

@external(erlang, "brazier_listener_start_failure_test_ffi", "describe_listen_failure")
fn describe_listen_failure(port: Int, posix: String) -> String

/// The acceptor supervisor's crash reason, `{no_listen_socket, Name}`, with
/// the atom `listener` for the name.
@external(erlang, "brazier_listener_start_failure_test_ffi", "describe_acceptors_failure")
fn describe_acceptors_failure() -> String
