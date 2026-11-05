/// A listener's connection owner is named `{via, brazier_http_conns, Ref}`
/// for a fresh reference. It used to be a fresh atom per listener start,
/// and atoms are never collected: the bench suite leaked 7 atoms a run
/// (one per listener it starts), and any node that starts and stops
/// listeners grew its atom table without bound. The owner's pid lives in a
/// persistent_term beside the listener's bound port, and both go when the
/// listener stops, or when its tree goes with nothing left to restart or
/// release it: a keeper per listener watches those holders.
import brazier/await
import brazier/transport/server.{type Listener, type Socket}
import gleam/erlang/process.{type Pid}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/string

/// Start/stop cycles measured after the warm-up one.
const cycles = 10

pub fn starting_and_stopping_listeners_creates_no_atom_test() {
  // The warm-up loads every module the measured loop runs (the listener's
  // and gleam/int's), whose atoms are created once, on load.
  start_and_stop_times(1)
  let before = atom_count()
  start_and_stop_times(cycles)
  case atoms_since(before) {
    [] -> Nil
    created ->
      panic as {
        int.to_string(cycles)
        <> " listener start/stop cycles created atoms: "
        <> string.inspect(created)
      }
  }
}

pub fn a_stopped_listener_leaves_no_registry_entry_test() {
  let before = registry_entries()
  let assert Ok(listener) =
    server.start(server.default_listener_options(0), ignore_socket)
  let assert Ok(owner) = server.get_connection_owner(listener)
  let assert True = process.is_alive(owner)
  let assert True = registry_entries() == before + 3
    as "a running listener holds its owner's pid, its bound port and its keeper"
  server.stop(listener)
  let assert Error(Nil) = server.get_connection_owner(listener)
    as "a stopped listener has no connection owner"
  let assert True = registry_entries() == before
    as "a stopped listener leaves no registry entry"
}

pub fn the_registry_holds_one_live_owner_test() {
  let ref = reference.new()
  let first = holder()
  let second = holder()
  let assert True = register(ref, first)
  let assert False = register(ref, second) as "a second live owner is refused"
  let assert Ok(owner) = whereis(ref)
  let assert True = owner == first
  // Only the owner unregisters itself (gen_server does, when its init
  // fails); another process cannot drop it.
  let assert False = unregister(ref)
  let assert Ok(_) = whereis(ref)
  process.kill(first)
  await.expect_down(first, "the first owner")
  let assert Error(Nil) = whereis(ref) as "a dead owner reads as none"
  let assert True = send_raises_badarg(ref)
    as "a send with no live owner exits with badarg"
  let assert True = register(ref, second)
    as "a restarted owner replaces a dead one"
  let assert Ok(owner) = whereis(ref)
  let assert True = owner == second
  let assert False = forget(ref) as "no bound port was remembered"
  let assert Error(Nil) = whereis(ref) as "forget drops the owner entry"
  process.kill(second)
  await.expect_down(second, "the second owner")
}

pub fn a_listener_tree_that_crashes_without_release_leaves_no_entry_test() {
  let before = registry_entries()
  let listener = start_unlinked()
  let assert Ok(keeper) = server.get_keeper(listener)
  process.kill(server.get_supervisor(listener))
  // Nothing restarts a started tree and nothing holds it: its keeper
  // erases the entries and exits.
  await.expect_down(keeper, "the crashed listener's keeper")
  let assert True = registry_entries() == before
    as "a listener tree that crashed without release leaves no entry"
  let assert Error(Nil) = server.get_connection_owner(listener)
  let assert Error(Nil) = server.get_keeper(listener)
  let assert False = server.hold(listener) as "a gone listener is not held"
  let assert False = server.release(listener) as "nothing is left to release"
}

pub fn a_held_listener_keeps_its_port_until_released_test() {
  let before = registry_entries()
  let listener = start_unlinked()
  let sup = server.get_supervisor(listener)
  let assert True = server.hold(listener)
  process.kill(sup)
  await.expect_down(sup, "the held listener's supervisor")
  // A second hold is a round trip through the keeper: it still holds the
  // entries for this process's release.
  let assert True = server.hold(listener) as "the keeper waits for the release"
  let assert True = registry_entries() == before + 3
  let assert True = server.release(listener)
    as "the holder's release forgets the bound port"
  let assert True = registry_entries() == before
  let assert Error(Nil) = server.get_keeper(listener)
}

pub fn a_holder_that_exits_without_release_leaves_no_entry_test() {
  let before = registry_entries()
  let listener = start_unlinked()
  let assert Ok(keeper) = server.get_keeper(listener)
  let held = process.new_subject()
  let holder =
    process.spawn_unlinked(fn() {
      process.send(held, server.hold(listener))
      process.sleep_forever()
    })
  let assert Ok(True) = process.receive(held, 5000)
  let sup = server.get_supervisor(listener)
  process.kill(sup)
  await.expect_down(sup, "the listener's supervisor")
  let assert True = server.hold(listener) as "the holder keeps the entries"
  // This test process holds now too: only the release ends the keeper.
  process.kill(holder)
  await.expect_down(holder, "the holder")
  let assert True = server.release(listener)
  let assert Error(Nil) = server.get_keeper(listener)
  await.expect_down(keeper, "the released listener's keeper")
  let assert True = registry_entries() == before
}

pub fn a_listener_whose_holders_all_exit_leaves_no_entry_test() {
  let before = registry_entries()
  let listener = start_unlinked()
  let assert Ok(keeper) = server.get_keeper(listener)
  let held = process.new_subject()
  let holder =
    process.spawn_unlinked(fn() {
      process.send(held, server.hold(listener))
      process.sleep_forever()
    })
  let assert Ok(True) = process.receive(held, 5000)
  let sup = server.get_supervisor(listener)
  process.kill(sup)
  await.expect_down(sup, "the listener's supervisor")
  // The holder (the application's watcher, say) dies before it releases.
  process.kill(holder)
  await.expect_down(keeper, "the keeper of a listener with no holder left")
  let assert True = registry_entries() == before
  let assert False = server.release(listener)
}

pub fn a_supervised_listener_keeps_its_port_while_its_parent_runs_test() {
  let before = registry_entries()
  let started = process.new_subject()
  let assert Ok(spec) =
    server.supervised(server.default_listener_options(0), ignore_socket)
  let spec =
    supervision.ChildSpecification(..spec, start: fn() {
      case spec.start() {
        Ok(child) -> {
          process.send(started, child.data)
          Ok(child)
        }
        Error(reason) -> Error(reason)
      }
    })
  let assert Ok(parent) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start
  process.unlink(parent.pid)
  let assert Ok(first) = process.receive(started, 5000)
  let assert Ok(keeper) = server.get_keeper(first)
  // The parent holds the entries, not this process, which built the spec.
  let assert True = registry_entries() == before + 3
  restart_only_child(parent.pid)
  let assert Ok(second) = process.receive(started, 5000)
  let assert True = server.get_port(second) == server.get_port(first)
    as "a listener restarted by its parent rebinds the port it bound first"
  let assert Ok(same) = server.get_keeper(second)
  let assert True = same == keeper
  let assert True = registry_entries() == before + 3
  // The parent stops and nobody releases the listener: its entries go with
  // the parent.
  stop_supervisor(parent.pid)
  await.expect_down(keeper, "the supervised listener's keeper")
  let assert True = registry_entries() == before
    as "a supervised listener leaves no entry once its parent is gone"
  let assert False = server.release(second)
}

pub fn a_listener_that_fails_to_start_leaves_no_entry_test() {
  let listener = start_unlinked()
  let before = registry_entries()
  // The port is taken: the connection owner registers, the socket owner
  // fails to bind, and the start returns an error (listener_start_failure_test
  // covers the error and the caller).
  let assert Error(_refused) =
    server.start(
      server.default_listener_options(server.get_port(listener)),
      ignore_socket,
    )
  let assert True = registry_entries() == before
    as "a listener that never ran leaves no entry"
  server.stop(listener)
}

/// A supervised listener removed from its parent for good
/// (`supervisor:terminate_child` then `delete_child`) keeps its entries
/// while the parent runs: the parent is its holder, and a terminated child
/// can still be restarted (`restart_child`), which must rebind the port it
/// bound first. Nothing tells the keeper that the spec was deleted, so the
/// application that removes the listener releases it, as ranch's
/// `stop_listener` cleans up its listener's options itself after the
/// terminate and before the delete.
pub fn a_supervised_listener_removed_from_its_parent_goes_when_released_test() {
  let before = registry_entries()
  let started = process.new_subject()
  let assert Ok(spec) =
    server.supervised(server.default_listener_options(0), ignore_socket)
  let spec =
    supervision.ChildSpecification(..spec, start: fn() {
      case spec.start() {
        Ok(child) -> {
          process.send(started, child.data)
          Ok(child)
        }
        Error(reason) -> Error(reason)
      }
    })
  let assert Ok(parent) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start
  process.unlink(parent.pid)
  let assert Ok(listener) = process.receive(started, 5000)
  let assert Ok(keeper) = server.get_keeper(listener)
  delete_only_child(parent.pid)
  let assert Error(Nil) = server.get_connection_owner(listener)
    as "the removed listener's tree is gone"
  let assert True = registry_entries() == before + 3
    as "the parent still holds the removed listener's entries"
  let assert True = server.release(listener)
    as "the release forgets the removed listener's bound port"
  await.expect_down(keeper, "the released listener's keeper")
  let assert True = registry_entries() == before
    as "a removed and released listener leaves no entry"
  stop_supervisor(parent.pid)
}

/// A port-0 listener whose supervisor is not linked to this test, so the
/// test can kill it.
fn start_unlinked() -> Listener {
  let assert Ok(listener) =
    server.start(server.default_listener_options(0), ignore_socket)
  process.unlink(server.get_supervisor(listener))
  listener
}

fn start_and_stop_times(times: Int) -> Nil {
  int.range(from: 0, to: times, with: Nil, run: fn(_, _) { start_and_stop() })
}

fn start_and_stop() -> Nil {
  let assert Ok(listener) =
    server.start(server.default_listener_options(0), ignore_socket)
  server.stop(listener)
}

/// No test here opens a connection, so the handler never runs.
fn ignore_socket(_socket: Socket) -> Nil {
  Nil
}

fn holder() -> Pid {
  process.spawn_unlinked(process.sleep_forever)
}

@external(erlang, "brazier_listener_name_test_ffi", "atom_count")
fn atom_count() -> Int

@external(erlang, "brazier_listener_name_test_ffi", "atoms_since")
fn atoms_since(from: Int) -> List(String)

@external(erlang, "brazier_listener_name_test_ffi", "registry_entries")
fn registry_entries() -> Int

@external(erlang, "brazier_listener_name_test_ffi", "register")
fn register(ref: Reference, pid: Pid) -> Bool

@external(erlang, "brazier_listener_name_test_ffi", "unregister")
fn unregister(ref: Reference) -> Bool

@external(erlang, "brazier_listener_name_test_ffi", "whereis")
fn whereis(ref: Reference) -> Result(Pid, Nil)

@external(erlang, "brazier_listener_name_test_ffi", "send_raises_badarg")
fn send_raises_badarg(ref: Reference) -> Bool

@external(erlang, "brazier_listener_name_test_ffi", "forget")
fn forget(ref: Reference) -> Bool

@external(erlang, "brazier_listener_name_test_ffi", "restart_only_child")
fn restart_only_child(parent: Pid) -> Nil

@external(erlang, "brazier_listener_name_test_ffi", "delete_only_child")
fn delete_only_child(parent: Pid) -> Nil

@external(erlang, "brazier_server_ffi", "stop_supervisor")
fn stop_supervisor(pid: Pid) -> Nil
