/// A listener's connection owner is named `{via, brazier_http_conns, Ref}`
/// for a fresh reference. It used to be a fresh atom per listener start,
/// and atoms are never collected: the bench suite leaked 7 atoms a run
/// (one per listener it starts), and any node that starts and stops
/// listeners grew its atom table without bound. The owner's pid lives in a
/// persistent_term beside the listener's bound port, and both go when the
/// listener stops.
import brazier/await
import brazier/transport/server.{type Socket}
import gleam/erlang/process.{type Pid}
import gleam/erlang/reference.{type Reference}
import gleam/int
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
  let assert True = registry_entries() == before + 2
    as "a running listener holds its owner's pid and its bound port"
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
