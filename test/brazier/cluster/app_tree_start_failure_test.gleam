//// A root tree (`application.start_supervised`, what `brazier.start` runs)
//// whose child cannot start returns an error naming the cause and leaves
//// its caller running with its links unchanged. The root used to be a
//// gleam_otp `static_supervisor` listing its children up front: a listener
//// on a taken port failed the root's own start, whose exit
//// (`{shutdown, {failed_to_start_child, ...}}`) killed a caller that does
//// not trap exits, and a caller that does got `InitFailed("shutdown")`.
//// The root now starts empty and adds its children with
//// `supervisor:start_child` (`brazier_app_sup`), as Ranch adds a listener
//// to the running `ranch_sup`.
////
//// The tree owns node-wide PubSub and the session scope, so every test
//// runs on a peer node (see app_tree_test).

import brazier/app_config_fixture
import brazier/application
import brazier/await
import brazier/cluster
import brazier/cluster/log_capture
import brazier/cluster/peer.{Timeout}
import brazier/effect
import brazier/error
import brazier/html
import brazier/internal/presence_watch
import brazier/log
import brazier/presence
import brazier/pubsub
import brazier/session
import brazier/telemetry
import brazier/transport/server.{type Socket}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Inc
}

fn config(port: Int) -> application.AppConfig(Model, Msg) {
  app_config_fixture.new(
    port: port,
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
}

fn in_use(port: Int) -> String {
  "Supervision tree failed to start: cannot listen on port "
  <> int.to_string(port)
  <> ": eaddrinuse (address already in use)"
}

/// Take a port on this node with a bare listener; the tree's listener
/// cannot bind it.
fn take_port() -> #(server.Listener, Int) {
  let assert Ok(taken) =
    server.start(server.default_listener_options(0), ignore_socket)
    as "a listener on a free port starts"
  #(taken, server.get_port(taken))
}

pub fn a_taken_port_returns_the_cause_to_a_caller_that_does_not_trap_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_taken_port")
  let assert [p] = peers as "the cluster starts one peer"
  let #(outcome, port, links_unchanged, lines, leftovers) =
    peer.on(p, fn() {
      // Started once per node and kept: not part of the tree.
      log.configure()
      let assert Ok(Nil) = telemetry.start() as "telemetry.start succeeds"
      let #(taken, port) = take_port()
      let assert False = traps_exits()
        as "the caller must not trap exits, or an exit signal would not kill it"
      let keepers_before = keepers()
      let links_before = links()
      let before = snapshot()
      let #(outcome, lines) =
        log_capture.capture(fn() { application.start_supervised(config(port)) })
      // Reaching this line is the survival: the exit of a root that
      // failed its own start would have killed this process.
      let links_unchanged = links() == links_before
      // The listener's keeper exits when its holder, the root, has gone;
      // it monitors the root, so it may still be on its way out.
      list.filter(keepers(), fn(keeper) {
        !list.contains(keepers_before, keeper)
      })
      |> list.each(await.expect_down(_, "the keeper of the failed listener"))
      let leftovers = leftovers(before)
      server.stop(taken)
      #(outcome, port, links_unchanged, lines, leftovers)
    })
  let assert Error(error.ConfigError(reason)) = outcome
    as "the start is refused with a ConfigError"
  assert reason == in_use(port)
  assert links_unchanged
    as "no process of the failed tree is linked to the caller"
  assert log_capture.contains(lines, "error", in_use(port))
    as "the cause is logged as an error"
  assert leftovers == [] as "nothing of the partly started tree is left"
  assert !peer.on(p, session.registry_running)
  let assert Error(_) = peer.on(p, pubsub.running_config)
    as "the partly started tree's PubSub is stopped"
  // The node can start a tree afterwards, and stop it.
  let outcome =
    peer.on(p, fn() {
      let assert Ok(app) = application.start_supervised(config(0))
        as "a tree on a free port starts after a failed one"
      let status = http_status(app.port)
      let stopped = application.stop(app)
      #(status, stopped, links())
    })
  let assert #(Ok(200), Ok(Nil), []) = outcome
    as "the tree serves, stops, and leaves the caller without links"
  Nil
}

pub fn a_caller_that_traps_exits_gets_the_cause_and_no_exit_message_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_taken_port_trap")
  let assert [p] = peers as "the cluster starts one peer"
  let #(outcome, messages, port) =
    peer.on(p, fn() {
      let #(taken, port) = take_port()
      process.trap_exits(True)
      let outcome = application.start_supervised(config(port))
      // The partly started tree is unlinked before it is stopped, and the
      // stop waits for its exit, so an 'EXIT' it sent would be here now.
      let messages = mailbox_size()
      process.trap_exits(False)
      server.stop(taken)
      #(outcome, messages, port)
    })
  let assert Error(error.ConfigError(reason)) = outcome
    as "the start is refused with a ConfigError"
  assert reason == in_use(port)
  assert messages == 0 as "a failed start sends its caller no 'EXIT' message"
  Nil
}

/// The root's children keep the specs they had under `static_supervisor`:
/// ids in start order, every child permanent and not significant, workers
/// with gleam_otp's 5000 ms shutdown and supervisors with `infinity`.
/// (The strategy and tolerance are checked by behaviour in app_tree_test:
/// rest_for_one restarts, and the give-up after the third crash in 5 s.)
pub fn the_root_keeps_its_child_specs_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_specs")
  let assert [p] = peers as "the cluster starts one peer"
  let specs =
    peer.on(p, fn() {
      let tracker = presence.new("tree", json.string, decode.string)
      let full =
        application.AppConfig(
          ..config(0),
          cluster: Some(cluster.new(cluster.NoDiscovery)),
          presence: Some(
            presence_watch.new(tracker, fn(_model) { [] }, fn(_diff) { Inc }),
          ),
        )
      let assert Ok(app) = application.start_supervised(full)
        as "the full tree starts"
      let specs = child_specs(app.supervisor_pid)
      let assert Ok(Nil) = application.stop(app) as "the tree stops"
      specs
    })
  assert specs
    == [
      // the ETS table owner
      "0 permanent worker 5000 false",
      // PubSub
      "1 permanent supervisor infinity false",
      // the cluster manager
      "2 permanent worker 5000 false",
      // the session scope
      "3 permanent worker 5000 false",
      // the presence tracker
      "4 permanent supervisor infinity false",
      // the listener
      "5 permanent supervisor infinity false",
    ]
}

/// No test here opens a connection to the taken port's listener.
fn ignore_socket(_socket: Socket) -> Nil {
  Nil
}

@external(erlang, "brazier_listener_start_failure_test_ffi", "links")
fn links() -> List(Dynamic)

@external(erlang, "brazier_listener_start_failure_test_ffi", "traps_exits")
fn traps_exits() -> Bool

@external(erlang, "brazier_listener_start_failure_test_ffi", "mailbox_size")
fn mailbox_size() -> Int

@external(erlang, "brazier_listener_start_failure_test_ffi", "keepers")
fn keepers() -> List(Pid)

@external(erlang, "brazier_app_tree_test_ffi", "snapshot")
fn snapshot() -> Snapshot

type Snapshot

@external(erlang, "brazier_app_tree_test_ffi", "leftovers")
fn leftovers(before: Snapshot) -> List(String)

@external(erlang, "brazier_app_tree_test_ffi", "http_status")
fn http_status(port: Int) -> Result(Int, String)

@external(erlang, "brazier_app_tree_test_ffi", "child_specs")
fn child_specs(supervisor: Pid) -> List(String)
