//// The application's root supervision tree (`application.start_supervised`)
//// on peer nodes: the shared test VM already runs PubSub and the session
//// scope unlinked, and the tree refuses to start beside them.
////
//// Children, in start order (RestForOne): the ETS table owner, PubSub, the
//// cluster manager, the session scope, the presence tracker, the listener
//// (the cluster manager and the tracker only when configured). A crash restarts the
//// child and every child after it, never one before it.

import brazier/app_config_fixture
import brazier/application.{type App}
import brazier/await
import brazier/cluster
import brazier/cluster/log_capture
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/effect
import brazier/error
import brazier/html
import brazier/internal/presence_watch
import brazier/log
import brazier/monitored
import brazier/presence
import brazier/presence/holder
import brazier/pubsub
import brazier/session
import brazier/telemetry
import brazier/transport/server
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
    cluster: Some(cluster.new(cluster.NoDiscovery)),
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
      as "presence.handle succeeds"
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
      as "application.start_supervised succeeds"
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
      as "list.drop succeeds"
    crash_and_await_restart(app.supervisor_pid, index, victim)
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
  use peers <- peer.with_cluster(1, "brazier_tree_order")
  let assert [p] = peers as "the cluster starts one peer"
  let app = start_tree(p, clustered_config())
  let assert [_ets_owner, pubsub_sup, cluster_manager, scope, listener] =
    children_on(p, app)
    as "the application tree has five children"
  let assert Ok(named_pubsub) =
    peer.on(p, fn() { whereis_name("brazier_pubsub_sup") })
    as "whereis_name succeeds"
  let assert Ok(named_cluster) =
    peer.on(p, fn() { whereis_name("brazier_cluster") })
    as "whereis_name succeeds"
  let assert Ok(named_scope) =
    peer.on(p, fn() { whereis_name("brazier_session_pg") })
    as "whereis_name succeeds"
  assert pubsub_sup == named_pubsub
  assert cluster_manager == named_cluster
  assert scope == named_scope
  assert listener == server.get_supervisor(app.listener)
  assert get_ok(p, app)
  Nil
}

pub fn listener_crash_restarts_only_the_listener_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_listener")
  let assert [p] = peers as "the cluster starts one peer"
  let app = start_tree(p, clustered_config())
  let #(before, after) = crash_child(p, app, 4)
  let assert [True, True, True, True, False] = kept(before, after)
    as "kept reports one flag per child"
  // The restarted listener binds the same port again.
  assert get_ok(p, app)
  Nil
}

pub fn session_scope_crash_restarts_scope_and_listener_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_scope")
  let assert [p] = peers as "the cluster starts one peer"
  let app = start_tree(p, clustered_config())
  let #(before, after) = crash_child(p, app, 3)
  let assert [True, True, True, False, False] = kept(before, after)
    as "kept reports one flag per child"
  assert peer.on(p, session.registry_running)
  assert get_ok(p, app)
  Nil
}

pub fn cluster_crash_restarts_everything_after_it_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_cluster")
  let assert [p] = peers as "the cluster starts one peer"
  let app = start_tree(p, clustered_config())
  let #(before, after) = crash_child(p, app, 2)
  let assert [True, True, False, False, False] = kept(before, after)
    as "kept reports one flag per child"
  let assert Ok(_) = peer.on(p, cluster.members) as "cluster.members succeeds"
  assert get_ok(p, app)
  Nil
}

pub fn pubsub_crash_restarts_the_whole_tree_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_pubsub")
  let assert [p] = peers as "the cluster starts one peer"
  let app = start_tree(p, clustered_config())
  let #(before, after) = crash_child(p, app, 1)
  let assert [True, False, False, False, False] = kept(before, after)
    as "kept reports one flag per child"
  // PubSub works again: a subscriber on the new partitions gets broadcasts.
  let assert Ok("hello") =
    peer.on(p, fn() {
      pubsub.subscribe("tree:check")
      pubsub.broadcast("tree:check", "hello")
      receive_broadcast("tree:check", 5000)
    })
    as "pubsub.subscribe succeeds"
  assert get_ok(p, app)
  Nil
}

pub fn tree_without_cluster_has_four_children_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_nocluster")
  let assert [p] = peers as "the cluster starts one peer"
  let app = start_tree(p, config())
  let assert [_ets_owner, _pubsub, _scope, _listener] = children_on(p, app)
    as "the application tree has four children"
  let #(before, after) = crash_child(p, app, 2)
  let assert [True, True, False, False] = kept(before, after)
    as "kept reports one flag per child"
  assert get_ok(p, app)
  Nil
}

pub fn tree_with_presence_runs_the_tracker_before_the_listener_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_presence")
  let assert [p] = peers as "the cluster starts one peer"
  let app = start_tree(p, presence_config(tracker_config()))
  let assert [_ets_owner, _pubsub, _cluster, scope, tracker, listener] =
    children_on(p, app)
    as "the application tree has six children"
  let assert Ok(named_scope) =
    peer.on(p, fn() { whereis_name("brazier_session_pg") })
    as "whereis_name succeeds"
  let assert Ok(named_tracker) =
    peer.on(p, fn() { whereis_name("brazier_presence_tree_sup") })
    as "whereis_name succeeds"
  assert scope == named_scope
  assert tracker == named_tracker
  assert listener == server.get_supervisor(app.listener)
  // A tracker crash restarts the tracker and the listener only.
  let #(before, after) = crash_child(p, app, 4)
  let assert [True, True, True, True, False, False] = kept(before, after)
    as "kept reports one flag per child"
  assert tracker_running(p)
  assert get_ok(p, app)
  Nil
}

pub fn supervised_start_refuses_unsupervised_tracker_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_refuse_tracker")
  let assert [p] = peers as "the cluster starts one peer"
  let outcome =
    peer.on(p, fn() {
      // The tracker runs over PubSub, so both run unsupervised.
      let holder = holder.start()
      holder.run(holder, pubsub.start)
      let assert Ok(_) =
        holder.run(holder, fn() { presence.start(tracker_config()) })
        as "presence.start succeeds"
      holder.run(holder, fn() {
        application.start_supervised(presence_config(tracker_config()))
      })
    })
  let assert Error(error.ConfigError(reason)) = outcome
    as "the start is refused with a ConfigError"
  assert string.contains(reason, "presence tracker is already running")
  // Nothing of the refused tree started; the unsupervised tracker runs on.
  assert !peer.on(p, session.registry_running)
  assert tracker_running(p)
  Nil
}

pub fn supervised_start_refuses_invalid_presence_config_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_bad_tracker")
  let assert [p] = peers as "the cluster starts one peer"
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
    as "the start is refused with a ConfigError"
  assert string.contains(reason, "Invalid presence configuration")
  let assert Error(_) = peer.on(p, pubsub.running_config)
    as "pubsub.running_config returns Error"
  assert !peer.on(p, session.registry_running)
  Nil
}

pub fn stop_leaves_no_processes_or_ports_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_stop")
  let assert [p] = peers as "the cluster starts one peer"
  let leftovers =
    peer.on(p, fn() {
      // Started once per node and kept: the logger configuration and the
      // telemetry application are not part of the tree.
      log.configure()
      let assert Ok(Nil) = telemetry.start() as "telemetry.start succeeds"
      let holder = holder.start()
      let before = snapshot()
      let assert Ok(app) =
        holder.run(holder, fn() {
          application.start_supervised(clustered_config())
        })
        as "application.start_supervised succeeds"
      let assert Ok(200) = http_status(app.port) as "http_status succeeds"
      let assert Ok(Nil) = holder.run(holder, fn() { application.stop(app) })
        as "application.stop succeeds"
      // The holder (linked to the root supervisor) survives a normal stop.
      assert process.is_alive(holder.pid)
      // Stopping twice is an error, not a silent no-op.
      let assert Error(error.ConfigError(reason)) = application.stop(app)
        as "application.stop returns Error(ConfigError)"
      assert string.contains(reason, "is not running")
      // The port is free again and nothing of the tree is left.
      let assert Error(_) = http_status(app.port) as "http_status returns Error"
      assert !session.registry_running()
      let assert Error(_) = pubsub.running_config()
        as "pubsub.running_config returns Error"
      let assert Error(_) = cluster.members() as "cluster.members returns Error"
      leftovers(before)
    })
  let assert [] = leftovers as "leftovers returns an empty list"
  // The node can start a fresh tree afterwards.
  let app = start_tree(p, clustered_config())
  assert get_ok(p, app)
  Nil
}

pub fn supervised_start_refuses_unsupervised_infrastructure_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_refuse")
  let assert [p] = peers as "the cluster starts one peer"
  let #(outcome, lines) =
    peer.on(p, fn() {
      let holder = holder.start()
      holder.run(holder, pubsub.start)
      log_capture.capture(fn() {
        holder.run(holder, fn() { application.start_supervised(config()) })
      })
    })
  let assert Error(error.ConfigError(reason)) = outcome
    as "the start is refused with a ConfigError"
  assert string.contains(reason, "PubSub is already running")
  assert log_capture.contains(lines, "error", "PubSub is already running")
  // Nothing of the refused tree started.
  assert !peer.on(p, session.registry_running)
  Nil
}

pub fn supervised_start_refuses_unsupervised_session_scope_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_refuse_scope")
  let assert [p] = peers as "the cluster starts one peer"
  let outcome =
    peer.on(p, fn() {
      session.ensure_registry()
      let holder = holder.start()
      holder.run(holder, fn() { application.start_supervised(config()) })
    })
  let assert Error(error.ConfigError(reason)) = outcome
    as "the start is refused with a ConfigError"
  assert string.contains(reason, "session scope is already running")
  let assert Error(_) = peer.on(p, pubsub.running_config)
    as "pubsub.running_config returns Error"
  Nil
}

/// A supervisor past its restart tolerance exits with `shutdown`; the
/// process blocked in `wait_forever` must crash with that, not treat it as
/// a requested shutdown.
pub fn wait_forever_crashes_when_the_tree_gives_up_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_tree_giveup")
  let assert [p] = peers as "the cluster starts one peer"
  let reason =
    peer.on(p, fn() {
      let started = process.new_subject()
      // Monitored from the spawn: a waiter that crashes while starting
      // reports its own reason, never `noproc`.
      let #(_waiter, monitor) =
        monitored.spawn(fn() {
          let assert Ok(app) = application.start_supervised(config())
            as "application.start_supervised succeeds"
          process.send(started, app)
          application.wait_forever()
        })
      let assert Ok(Ok(app)) =
        process.new_selector()
        |> process.select_map(started, Ok)
        |> process.select_specific_monitor(monitor, Error)
        |> process.selector_receive(10_000)
        as "the tree starts and the waiter is still running"
      // The default tolerance is 2 restarts in 5 seconds: the third crash
      // inside the window makes the supervisor give up.
      list.each([1, 2], fn(_) {
        let victim = listener_pid(app)
        crash_and_await_restart(app.supervisor_pid, 3, victim)
      })
      crash(app.supervisor_pid, listener_pid(app))
      monitored.down_reason(monitor, "the process in wait_forever")
      |> monitored.describe
    })
  assert string.contains(reason, "Linked application process exited")
  assert string.contains(reason, "shutdown")
  Nil
}

fn listener_pid(app: App) -> Pid {
  let assert [_, _, _, listener] = children(app.supervisor_pid)
    as "the application tree has four children"
  listener
}

fn receive_broadcast(topic: String, timeout: Int) -> Result(String, Nil) {
  receive_broadcast_ffi(topic, timeout)
}

// --- Tree inspection ---

@external(erlang, "brazier_app_tree_test_ffi", "children")
fn children(supervisor: Pid) -> List(Pid)

/// Crash child `index` of `supervisor`, `victim` (see `crash`), and return
/// once the supervisor has handled its exit signal: a supervisor restarts
/// the child (and, under rest_for_one, the children after it) while it
/// handles the EXIT, so the new pid is in place then. The sys hook is
/// installed before the crash, so the EXIT can't be missed.
fn crash_and_await_restart(supervisor: Pid, index: Int, victim: Pid) -> Nil {
  use watch <- await.with_watch_exit(supervisor, victim)
  crash(supervisor, victim)
  await.expect_info(watch, supervisor, "the supervisor handling the crash")
  restarted(supervisor, index, victim)
}

/// Crash unless child `index` of `supervisor` runs with a pid other than
/// `old`.
@external(erlang, "brazier_app_tree_test_ffi", "restarted")
fn restarted(supervisor: Pid, index: Int, old: Pid) -> Nil

/// Crash a child of `supervisor` and return once it is gone. A worker is
/// killed. A child supervisor is terminated with an abnormal reason, so it
/// stops its own children first: that is how a child supervisor fails
/// (past its restart tolerance). Killing one instead orphans its children,
/// which then exit asynchronously and can still hold their registered names
/// when the replacement starts.
@external(erlang, "brazier_app_tree_test_ffi", "crash")
fn crash(supervisor: Pid, child: Pid) -> Nil

@external(erlang, "brazier_app_tree_test_ffi", "http_status")
fn http_status(port: Int) -> Result(Int, String)

type Snapshot

@external(erlang, "brazier_app_tree_test_ffi", "snapshot")
fn snapshot() -> Snapshot

@external(erlang, "brazier_app_tree_test_ffi", "leftovers")
fn leftovers(before: Snapshot) -> List(String)

@external(erlang, "brazier_app_tree_test_ffi", "whereis_name")
fn whereis_name(name: String) -> Result(Pid, Nil)

@external(erlang, "brazier_app_tree_test_ffi", "receive_broadcast")
fn receive_broadcast_ffi(topic: String, timeout: Int) -> Result(String, Nil)
