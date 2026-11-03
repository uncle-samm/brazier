//// The application's root supervision tree (`application.start_supervised`)
//// on peer nodes: the shared test VM already runs PubSub and the session
//// scope unlinked, and the tree refuses to start beside them.
////
//// Children, in start order (RestForOne): PubSub, the cluster manager,
//// the session scope, the presence tracker, the listener (the cluster
//// manager and the tracker only when configured). A crash restarts the
//// child and every child after it, never one before it.

import beacon/app_config_fixture
import beacon/application.{type App}
import beacon/cluster
import beacon/cluster/log_capture
import beacon/cluster/peer.{type Peer, Timeout}
import beacon/effect
import beacon/error
import beacon/html
import beacon/internal/presence_watch
import beacon/log
import beacon/presence
import beacon/presence/holder
import beacon/pubsub
import beacon/session
import beacon/telemetry
import beacon/transport/server
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Inc
}

const secret = "app-tree-test-secret-key-0123456789abcdef"

fn config() -> application.AppConfig(Model, Msg) {
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
}

fn clustered_config() -> application.AppConfig(Model, Msg) {
  application.AppConfig(
    ..config(),
    cluster: Some(cluster.new(cluster.NoDiscovery, secret_key: secret)),
  )
}

fn tracker_config() -> presence.PresenceConfig(String) {
  presence.new("tree", json.string, decode.string)
}

fn presence_config(
  tracker: presence.PresenceConfig(String),
) -> application.AppConfig(Model, Msg) {
  application.AppConfig(
    ..clustered_config(),
    presence: Some(
      presence_watch.new(tracker, fn(_model) { [] }, fn(_diff) { Inc }),
    ),
  )
}

fn tracker_running(p: Peer) -> Bool {
  peer.on(p, fn() {
    let assert Ok(tracker) = presence.handle(tracker_config())
    presence.running(tracker)
  })
}

/// Start the tree on `p` from a holder process that stays alive, so the
/// supervisor (linked to its starter) outlives the rpc.
fn start_tree(p: Peer, config: application.AppConfig(Model, Msg)) -> App {
  peer.on(p, fn() {
    let holder = holder.start()
    let assert Ok(app) =
      holder.run(holder, fn() { application.start_supervised(config) })
    app
  })
}

fn children_on(p: Peer, app: App) -> List(Pid) {
  peer.on(p, fn() { children(app.supervisor_pid) })
}

fn get_ok(p: Peer, app: App) -> Bool {
  peer.on(p, fn() { http_status(app.port) }) == Ok(200)
}

/// Crash child `index` (see `crash`) and return the children once it has
/// been restarted.
fn crash_child(p: Peer, app: App, index: Int) -> #(List(Pid), List(Pid)) {
  peer.on(p, fn() {
    let before = children(app.supervisor_pid)
    let assert Ok(victim) = list.drop(before, index) |> list.first
    crash(app.supervisor_pid, victim)
    await_restart(app.supervisor_pid, index, victim)
    // Every later child is restarted before the supervisor answers calls
    // again, so a stale pid of a later child here would be a real bug.
    #(before, children(app.supervisor_pid))
  })
}

/// Which children kept their pid (True) across a crash.
fn kept(before: List(Pid), after: List(Pid)) -> List(Bool) {
  list.zip(before, after) |> list.map(fn(pair) { pair.0 == pair.1 })
}

pub fn tree_runs_children_in_order_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_order")
  let assert [p] = peers
  let app = start_tree(p, clustered_config())
  let assert [pubsub_sup, cluster_manager, scope, listener] =
    children_on(p, app)
  let assert Ok(named_pubsub) =
    peer.on(p, fn() { whereis_name("beacon_pubsub_sup") })
  let assert Ok(named_cluster) =
    peer.on(p, fn() { whereis_name("beacon_cluster") })
  let assert Ok(named_scope) =
    peer.on(p, fn() { whereis_name("beacon_session_pg") })
  let assert True = pubsub_sup == named_pubsub
  let assert True = cluster_manager == named_cluster
  let assert True = scope == named_scope
  let assert True = listener == server.get_supervisor(app.listener)
  let assert True = get_ok(p, app)
  Nil
}

pub fn listener_crash_restarts_only_the_listener_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_listener")
  let assert [p] = peers
  let app = start_tree(p, clustered_config())
  let #(before, after) = crash_child(p, app, 3)
  let assert [True, True, True, False] = kept(before, after)
  // The restarted listener binds the same port again.
  let assert True = get_ok(p, app)
  Nil
}

pub fn session_scope_crash_restarts_scope_and_listener_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_scope")
  let assert [p] = peers
  let app = start_tree(p, clustered_config())
  let #(before, after) = crash_child(p, app, 2)
  let assert [True, True, False, False] = kept(before, after)
  let assert True = peer.on(p, session.registry_running)
  let assert True = get_ok(p, app)
  Nil
}

pub fn cluster_crash_restarts_everything_after_it_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_cluster")
  let assert [p] = peers
  let app = start_tree(p, clustered_config())
  let #(before, after) = crash_child(p, app, 1)
  let assert [True, False, False, False] = kept(before, after)
  let assert Ok(_) = peer.on(p, cluster.members)
  let assert True = get_ok(p, app)
  Nil
}

pub fn pubsub_crash_restarts_the_whole_tree_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_pubsub")
  let assert [p] = peers
  let app = start_tree(p, clustered_config())
  let #(before, after) = crash_child(p, app, 0)
  let assert [False, False, False, False] = kept(before, after)
  // PubSub works again: a subscriber on the new partitions gets broadcasts.
  let assert Ok("hello") =
    peer.on(p, fn() {
      pubsub.subscribe("tree:check")
      pubsub.broadcast("tree:check", "hello")
      receive_broadcast("tree:check", 5000)
    })
  let assert True = get_ok(p, app)
  Nil
}

pub fn tree_without_cluster_has_three_children_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_nocluster")
  let assert [p] = peers
  let app = start_tree(p, config())
  let assert [_pubsub, _scope, _listener] = children_on(p, app)
  let #(before, after) = crash_child(p, app, 1)
  let assert [True, False, False] = kept(before, after)
  let assert True = get_ok(p, app)
  Nil
}

pub fn tree_with_presence_runs_the_tracker_before_the_listener_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_presence")
  let assert [p] = peers
  let app = start_tree(p, presence_config(tracker_config()))
  let assert [_pubsub, _cluster, scope, tracker, listener] = children_on(p, app)
  let assert Ok(named_scope) =
    peer.on(p, fn() { whereis_name("beacon_session_pg") })
  let assert Ok(named_tracker) =
    peer.on(p, fn() { whereis_name("beacon_presence_tree_sup") })
  let assert True = scope == named_scope
  let assert True = tracker == named_tracker
  let assert True = listener == server.get_supervisor(app.listener)
  // A tracker crash restarts the tracker and the listener only.
  let #(before, after) = crash_child(p, app, 3)
  let assert [True, True, True, False, False] = kept(before, after)
  let assert True = tracker_running(p)
  let assert True = get_ok(p, app)
  Nil
}

pub fn supervised_start_refuses_unsupervised_tracker_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_refuse_tracker")
  let assert [p] = peers
  let outcome =
    peer.on(p, fn() {
      // The tracker runs over PubSub, so both run unsupervised.
      let holder = holder.start()
      holder.run(holder, pubsub.start)
      let assert Ok(_) =
        holder.run(holder, fn() { presence.start(tracker_config()) })
      holder.run(holder, fn() {
        application.start_supervised(presence_config(tracker_config()))
      })
    })
  let assert Error(error.ConfigError(reason)) = outcome
  let assert True =
    string.contains(reason, "presence tracker is already running")
  // Nothing of the refused tree started; the unsupervised tracker runs on.
  let assert False = peer.on(p, session.registry_running)
  let assert True = tracker_running(p)
  Nil
}

pub fn supervised_start_refuses_invalid_presence_config_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_bad_tracker")
  let assert [p] = peers
  let outcome =
    peer.on(p, fn() {
      let holder = holder.start()
      holder.run(holder, fn() {
        application.start_supervised(presence_config(
          tracker_config() |> presence.pool_size(0),
        ))
      })
    })
  let assert Error(error.ConfigError(reason)) = outcome
  let assert True = string.contains(reason, "Invalid presence configuration")
  let assert Error(_) = peer.on(p, pubsub.running_config)
  let assert False = peer.on(p, session.registry_running)
  Nil
}

pub fn stop_leaves_no_processes_or_ports_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_stop")
  let assert [p] = peers
  let leftovers =
    peer.on(p, fn() {
      // Started once per node and kept: the logger configuration and the
      // telemetry application are not part of the tree.
      log.configure()
      let assert Ok(Nil) = telemetry.start()
      let holder = holder.start()
      let before = snapshot()
      let assert Ok(app) =
        holder.run(holder, fn() {
          application.start_supervised(clustered_config())
        })
      let assert Ok(200) = http_status(app.port)
      let assert Ok(Nil) = holder.run(holder, fn() { application.stop(app) })
      // The holder (linked to the root supervisor) survives a normal stop.
      let assert True = process.is_alive(holder.pid)
      // Stopping twice is an error, not a silent no-op.
      let assert Error(error.ConfigError(reason)) = application.stop(app)
      let assert True = string.contains(reason, "is not running")
      // The port is free again and nothing of the tree is left.
      let assert Error(_) = http_status(app.port)
      let assert False = session.registry_running()
      let assert Error(_) = pubsub.running_config()
      let assert Error(_) = cluster.members()
      leftovers(before)
    })
  let assert [] = leftovers
  // The node can start a fresh tree afterwards.
  let app = start_tree(p, clustered_config())
  let assert True = get_ok(p, app)
  Nil
}

pub fn supervised_start_refuses_unsupervised_infrastructure_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_refuse")
  let assert [p] = peers
  let #(outcome, lines) =
    peer.on(p, fn() {
      let holder = holder.start()
      holder.run(holder, pubsub.start)
      log_capture.capture(fn() {
        holder.run(holder, fn() { application.start_supervised(config()) })
      })
    })
  let assert Error(error.ConfigError(reason)) = outcome
  let assert True = string.contains(reason, "PubSub is already running")
  let assert True =
    log_capture.contains(lines, "error", "PubSub is already running")
  // Nothing of the refused tree started.
  let assert False = peer.on(p, session.registry_running)
  Nil
}

pub fn supervised_start_refuses_unsupervised_session_scope_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_refuse_scope")
  let assert [p] = peers
  let outcome =
    peer.on(p, fn() {
      session.ensure_registry()
      let holder = holder.start()
      holder.run(holder, fn() { application.start_supervised(config()) })
    })
  let assert Error(error.ConfigError(reason)) = outcome
  let assert True = string.contains(reason, "session scope is already running")
  let assert Error(_) = peer.on(p, pubsub.running_config)
  Nil
}

/// A supervisor past its restart tolerance exits with `shutdown`; the
/// process blocked in `wait_forever` must crash with that, not treat it as
/// a requested shutdown.
pub fn wait_forever_crashes_when_the_tree_gives_up_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_tree_giveup")
  let assert [p] = peers
  let reason =
    peer.on(p, fn() {
      let started = process.new_subject()
      let waiter =
        process.spawn_unlinked(fn() {
          let assert Ok(app) = application.start_supervised(config())
          process.send(started, app)
          application.wait_forever()
        })
      let monitor = process.monitor(waiter)
      let assert Ok(app) = process.receive(started, 10_000)
      // The default tolerance is 2 restarts in 5 seconds: the third crash
      // inside the window makes the supervisor give up.
      list.each([1, 2], fn(_) {
        let victim = listener_pid(app)
        crash(app.supervisor_pid, victim)
        await_restart(app.supervisor_pid, 2, victim)
      })
      crash(app.supervisor_pid, listener_pid(app))
      let down =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
      let assert Ok(process.ProcessDown(reason: reason, ..)) =
        process.selector_receive(down, 10_000)
      string.inspect(reason)
    })
  let assert True = string.contains(reason, "Linked application process exited")
  let assert True = string.contains(reason, "shutdown")
  Nil
}

fn listener_pid(app: App) -> Pid {
  let assert [_, _, listener] = children(app.supervisor_pid)
  listener
}

fn receive_broadcast(topic: String, timeout: Int) -> Result(String, Nil) {
  receive_broadcast_ffi(topic, timeout)
}

// --- Tree inspection ---

@external(erlang, "beacon_app_tree_test_ffi", "children")
fn children(supervisor: Pid) -> List(Pid)

@external(erlang, "beacon_app_tree_test_ffi", "await_restart")
fn await_restart(supervisor: Pid, index: Int, old: Pid) -> Nil

/// Crash a child of `supervisor` and return once it is gone. A worker is
/// killed. A child supervisor is terminated with an abnormal reason, so it
/// stops its own children first: that is how a child supervisor fails
/// (past its restart tolerance). Killing one instead orphans its children,
/// which then exit asynchronously and can still hold their registered names
/// when the replacement starts.
@external(erlang, "beacon_app_tree_test_ffi", "crash")
fn crash(supervisor: Pid, child: Pid) -> Nil

@external(erlang, "beacon_app_tree_test_ffi", "http_status")
fn http_status(port: Int) -> Result(Int, String)

type Snapshot

@external(erlang, "beacon_app_tree_test_ffi", "snapshot")
fn snapshot() -> Snapshot

@external(erlang, "beacon_app_tree_test_ffi", "leftovers")
fn leftovers(before: Snapshot) -> List(String)

@external(erlang, "beacon_app_tree_test_ffi", "whereis_name")
fn whereis_name(name: String) -> Result(Pid, Nil)

@external(erlang, "beacon_app_tree_test_ffi", "receive_broadcast")
fn receive_broadcast_ffi(topic: String, timeout: Int) -> Result(String, Nil)
