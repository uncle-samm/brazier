//// The ETS table owner as the first child of the root tree
//// (`application.start_supervised`): it adopts the stores created before
//// the tree, stopping the tree deletes their tables, an owner that owned no
//// table restarts, and an owner lost with tables is never restarted empty.
////
//// Every test runs on a fresh peer node: the shared test VM already runs an
//// owner on demand and the unsupervised infrastructure the tree refuses to
//// start beside. Tests synchronize on supervisor calls and monitors; nothing
//// sleeps.

import brazier/app_config_fixture
import brazier/application.{type App}
import brazier/cluster/peer.{Timeout}
import brazier/effect
import brazier/html
import brazier/monitored
import brazier/presence/holder
import brazier/state_manager
import brazier/store
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
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

/// The tree's first child: the table owner.
fn owner_child(app: App) -> Pid {
  let assert [owner, ..] = children(app.supervisor_pid)
    as "the root tree has children"
  owner
}

/// Run `start` in a process that then blocks in `wait_forever`, as `main`
/// does, and return the app with a monitor on that process. The monitor is
/// taken with the spawn, so a waiter that crashes while starting fails the
/// test with its own reason, never `noproc` or a timeout.
fn start_waiting(before: fn() -> a) -> #(App, a, process.Monitor) {
  let started = process.new_subject()
  let #(_waiter, monitor) =
    monitored.spawn(fn() {
      let value = before()
      let assert Ok(app) = application.start_supervised(config())
        as "the tree must start"
      process.send(started, #(app, value))
      application.wait_forever()
    })
  let outcome =
    process.new_selector()
    |> process.select_map(started, Ok)
    |> process.select_specific_monitor(monitor, Error)
    |> process.selector_receive(10_000)
  case outcome {
    Ok(Ok(#(app, value))) -> #(app, value, monitor)
    Ok(Error(down)) ->
      panic as { "the waiter exited while starting: " <> string.inspect(down) }
    Error(Nil) -> panic as "the tree did not start within 10 s"
  }
}

/// The waiter's exit reason, as text.
fn await_down(monitor: process.Monitor) -> String {
  monitored.down_reason(monitor, "the waiting process")
  |> monitored.describe
}

pub fn tree_adopts_stores_created_before_it_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "ws8c_ets_adopt")
  let assert [p] = peers
  let outcome =
    peer.on(p, fn() {
      // As in `main`: the store exists before the tree, so an owner on
      // demand holds its table.
      let counts = store.new("ws8c_adopt")
      write_before_tree("ws8c_adopt", "visits", 7)
      let assert Ok(False) = state_manager.table_owner_is_supervised()
      let assert Ok(on_demand) = owner_pid()

      let holder = holder.start()
      let assert Ok(app) =
        holder.run(holder, fn() { application.start_supervised(config()) })
      let adopted = store.get(counts, "visits")
      let supervised = state_manager.table_owner_is_supervised()
      let assert Ok(owner) = owner_pid()
      let owner_is_child = owner == owner_child(app)
      let on_demand_gone = !process.is_alive(on_demand)
      // Writes after the move land in the adopted table.
      store.put(counts, "visits", 8)
      let after_move = store.get(counts, "visits")

      let assert Ok(Nil) = holder.run(holder, fn() { application.stop(app) })
      // Stopping the tree stopped the owner and deleted its table: the
      // same name now opens a new, empty one.
      let stopped = state_manager.table_owner_is_supervised()
      let reopened = store.get(store.new("ws8c_adopt"), "visits")
      #(
        adopted,
        supervised,
        owner_is_child,
        on_demand_gone,
        after_move,
        stopped,
        reopened,
      )
    })
  let assert #(Ok(7), Ok(True), True, True, Ok(8), Error(Nil), Error(Nil)) =
    outcome
  Nil
}

pub fn owner_without_tables_restarts_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "ws8c_ets_restart")
  let assert [p] = peers
  let outcome =
    peer.on(p, fn() {
      let holder = holder.start()
      let assert Ok(app) =
        holder.run(holder, fn() { application.start_supervised(config()) })
      let before = children(app.supervisor_pid)
      let victim = owner_child(app)
      crash(app.supervisor_pid, victim)
      await_restart(app.supervisor_pid, 0, victim)
      let after = children(app.supervisor_pid)
      // RestForOne: the owner is first, so every child restarted.
      let kept =
        list.zip(before, after) |> list.map(fn(pair) { pair.0 == pair.1 })
      let supervised = state_manager.table_owner_is_supervised()
      // The new owner creates tables.
      let counts = store.new("ws8c_after_restart")
      store.put(counts, "visits", 1)
      let value = store.get(counts, "visits")
      let assert Ok(Nil) = holder.run(holder, fn() { application.stop(app) })
      #(kept, supervised, value)
    })
  let assert #([False, False, False, False], Ok(True), Ok(1)) = outcome
  Nil
}

pub fn owner_lost_with_adopted_tables_stops_the_application_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "ws8c_ets_lost_adopted")
  let assert [p] = peers
  let #(reason, refused, fresh) =
    peer.on(p, fn() {
      let #(app, counts, monitor) =
        start_waiting(fn() {
          let counts = store.new("ws8c_lost_adopted")
          write_before_tree("ws8c_lost_adopted", "visits", 3)
          counts
        })
      let assert Ok(3) = store.get(counts, "visits")
      crash(app.supervisor_pid, owner_child(app))
      let reason = await_down(monitor)
      // The data is gone, so the node creates no table until a new tree
      // starts...
      let refused = store.try_new("ws8c_lost_other")
      // ...and a new tree creates tables again.
      let holder = holder.start()
      let assert Ok(next) =
        holder.run(holder, fn() { application.start_supervised(config()) })
      let fresh = store.get(store.new("ws8c_lost_adopted"), "visits")
      let assert Ok(Nil) = holder.run(holder, fn() { application.stop(next) })
      #(reason, refused, fresh)
    })
  let assert True = string.contains(reason, "Linked application process exited")
  let assert True = string.contains(reason, "shutdown")
  let assert Error(_) = refused
  let assert Error(Nil) = fresh
  Nil
}

pub fn owner_lost_with_tables_created_under_the_tree_stops_the_application_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "ws8c_ets_lost_created")
  let assert [p] = peers
  let #(reason, refused) =
    peer.on(p, fn() {
      let #(app, Nil, monitor) = start_waiting(fn() { Nil })
      // Created by the supervised owner itself, not adopted.
      let counts = store.new("ws8c_lost_created")
      store.put(counts, "visits", 4)
      crash(app.supervisor_pid, owner_child(app))
      let reason = await_down(monitor)
      #(reason, store.try_new("ws8c_lost_created"))
    })
  let assert True = string.contains(reason, "shutdown")
  let assert Error(_) = refused
  Nil
}

/// Write to a store's table without its change notification, which needs
/// PubSub: before the tree starts there is none to notify through.
fn write_before_tree(name: String, key: String, value: Int) -> Nil {
  raw_put(atom.create("brazier_store_" <> name), key, value)
}

@external(erlang, "brazier_ets_ffi", "put")
fn raw_put(table: atom.Atom, key: String, value: Int) -> Nil

@external(erlang, "brazier_ets_ffi", "owner_pid")
fn owner_pid() -> Result(Pid, String)

@external(erlang, "brazier_app_tree_test_ffi", "children")
fn children(supervisor: Pid) -> List(Pid)

@external(erlang, "brazier_app_tree_test_ffi", "await_restart")
fn await_restart(supervisor: Pid, index: Int, old: Pid) -> Nil

@external(erlang, "brazier_app_tree_test_ffi", "crash")
fn crash(supervisor: Pid, child: Pid) -> Nil
