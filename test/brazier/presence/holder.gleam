//// Holder processes for presence tests: presence always tracks the calling
//// process, so a test tracks through a holder that runs closures for it
//// and stays alive until killed. Holders are unlinked, so they outlive the
//// rpc call that started them on a peer.
////
//// An unlinked holder also outlives a test that fails, and its entries
//// stay tracked for the tests after it. A test on this node therefore
//// takes its holders from `with_holder`, which kills the holder however
//// the body ends, like an ExUnit `on_exit` callback. A holder started on
//// a peer ends with its node: `peer.with_cluster` stops every peer in an
//// `after` clause.

import brazier/monitored
import gleam/erlang/process.{type Pid, type Subject}

pub type Holder {
  Holder(pid: Pid, commands: Subject(fn() -> Nil))
}

/// Start a holder on this node.
pub fn start() -> Holder {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let commands = process.new_subject()
      process.send(ready, commands)
      loop(commands)
    })
  // INVARIANT: test helper. The holder sends its subject before anything
  // else, so a missing reply means the test cannot continue.
  let assert Ok(commands) = process.receive(ready, 5000)
    as "holder did not start"
  Holder(pid:, commands:)
}

/// Start a holder, run `run` with it, and kill the holder afterwards,
/// also when `run` crashes. The body may kill the holder itself: `kill`
/// of an exited holder returns at once (its monitor reports `noproc`).
pub fn with_holder(run: fn(Holder) -> a) -> a {
  let holder = start()
  use <- monitored.with_cleanup(fn() { kill(holder) })
  run(holder)
}

fn loop(commands: Subject(fn() -> Nil)) -> Nil {
  let command = process.receive_forever(commands)
  command()
  loop(commands)
}

/// Run `run` in the holder and return its result.
pub fn run(holder: Holder, run: fn() -> a) -> a {
  let reply = process.new_subject()
  process.send(holder.commands, fn() { process.send(reply, run()) })
  // INVARIANT: test helper. A holder that does not answer is dead or
  // stuck, and the test cannot continue.
  let assert Ok(value) = process.receive(reply, 10_000)
    as "holder did not answer"
  value
}

/// Kill the holder and wait until it is gone.
pub fn kill(holder: Holder) -> Nil {
  let monitor = process.monitor(holder.pid)
  process.kill(holder.pid)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  // INVARIANT: test helper. A killed process always exits.
  let assert Ok(Nil) = process.selector_receive(down, 5000)
    as "holder did not exit"
  Nil
}
