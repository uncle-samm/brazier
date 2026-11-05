//// A table creation whose owner moves or dies between the creation's owner
//// lookup and its monitor (`brazier_ets_ffi:create_via_owner/4`).
////
//// The creation is held at that point: the lookup that starts an owner on
//// demand logs "Started ETS table owner" in the creating process after the
//// owner registered and before the creation monitors it, and a logger
//// handler (`brazier_ets_owner_race_test_ffi`) blocks there until the test
//// releases it. Meanwhile the test moves the owner to a supervised one, or
//// kills it, and waits for its DOWN. Released, the creation monitors a
//// process that is gone. Nothing sleeps.
////
//// Each test runs on a fresh peer node: it needs a node with no table
//// owner yet, and it moves or kills that node's owner.

import brazier/cluster/peer.{Timeout}
import brazier/monitored
import brazier/state_manager.{type EtsError, type EtsTable}
import gleam/erlang/process.{type ExitReason, type Pid}
import gleam/list
import gleam/string

type OwnerTree

@external(erlang, "brazier_ets_ffi", "new_owner_tree")
fn new_owner_tree() -> OwnerTree

@external(erlang, "brazier_ets_ffi", "start_supervised_owner")
fn start_supervised_owner(tree: OwnerTree) -> Result(Pid, String)

@external(erlang, "brazier_ets_owner_race_test_ffi", "hold_first_owner_start")
fn hold_first_owner_start() -> Nil

@external(erlang, "brazier_ets_owner_race_test_ffi", "await_held")
fn await_held(creator: Pid) -> Pid

@external(erlang, "brazier_ets_owner_race_test_ffi", "release")
fn release(creator: Pid) -> Nil

@external(erlang, "brazier_ets_owner_race_test_ffi", "lines")
fn lines(creator: Pid) -> List(String)

@external(erlang, "brazier_ets_owner_race_test_ffi", "table_owner")
fn table_owner(table: EtsTable) -> Pid

@external(erlang, "brazier_ets_owner_race_test_ffi", "moved_to")
fn moved_to(reason: ExitReason) -> Result(Pid, Nil)

/// What a held creation saw, reported from the peer.
type Outcome {
  Outcome(
    /// The creation's result, with the table's owner when it succeeded.
    created: Result(Pid, EtsError),
    /// The owner the creation's lookup found, which the test then moved
    /// or killed.
    looked_up: Pid,
    /// The table owner registered once the creation returned.
    registered: Result(Pid, Nil),
    /// The brazier.ets lines the creating process logged, oldest first.
    lines: List(String),
  )
}

/// Start a creation of `table` on this node, hold it between its owner
/// lookup and its monitor, run `disturb` on the owner the lookup found,
/// then release it and report what it returned.
fn held_creation(table: String, disturb: fn(Pid) -> Nil) -> Outcome {
  hold_first_owner_start()
  let results = process.new_subject()
  let #(creator, creator_monitor) =
    monitored.spawn(fn() {
      process.send(
        results,
        state_manager.ensure_table(table, state_manager.EtsSet),
      )
    })
  let looked_up = await_held(creator)
  disturb(looked_up)
  release(creator)
  let assert process.Normal =
    monitored.down_reason(creator_monitor, "the creating process")
  let assert Ok(created) = process.receive(results, 0)
    as "the creating process sends its result before it exits"
  Outcome(
    created: case created {
      Ok(table) -> Ok(table_owner(table))
      Error(error) -> Error(error)
    },
    looked_up:,
    registered: peer.registered("brazier_ets_owner"),
    lines: lines(creator),
  )
}

/// Whether one of `lines` contains every fragment.
fn logged(lines: List(String), fragments: List(String)) -> Bool {
  list.any(lines, fn(line) {
    list.all(fragments, fn(fragment) { string.contains(line, fragment) })
  })
}

pub fn a_creation_follows_an_owner_that_moved_before_its_monitor_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_ets_race_moved")
  let assert [node] = peers
  let #(outcome, supervised) =
    peer.on(node, fn() {
      let supervised = process.new_subject()
      let outcome =
        held_creation("race_moved", fn(owner) {
          // The supervised owner adopts the owner on demand, which hands
          // over and exits with {brazier_ets_owner_moved, Supervised}.
          let monitor = process.monitor(owner)
          let assert Ok(new_owner) = start_supervised_owner(new_owner_tree())
            as "the supervised owner must start"
          let assert Ok(to) =
            moved_to(monitored.down_reason(monitor, "the owner on demand"))
            as "the owner on demand exits saying where it moved"
          let assert True = to == new_owner
          process.send(supervised, new_owner)
        })
      let assert Ok(new_owner) = process.receive(supervised, 0)
      #(outcome, new_owner)
    })
  // The creation asks the owner it moved to, which owns the table.
  let assert Ok(owner) = outcome.created
  let assert True = owner == supervised
  let assert Ok(registered) = outcome.registered
  let assert True = registered == supervised
  let assert True = outcome.looked_up != supervised
  let assert True = logged(outcome.lines, ["race_moved", "asking again"])
  Nil
}

pub fn a_creation_follows_an_owner_that_died_before_its_monitor_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_ets_race_died")
  let assert [node] = peers
  let outcome =
    peer.on(node, fn() {
      held_creation("race_died", fn(owner) {
        let monitor = process.monitor(owner)
        process.kill(owner)
        let assert process.Killed =
          monitored.down_reason(monitor, "the owner on demand")
        Nil
      })
    })
  // The killed owner owned no table, so the creation starts a new owner
  // on demand and that owner creates the table.
  let assert Ok(owner) = outcome.created
  let assert Ok(registered) = outcome.registered
  let assert True = owner == registered
  let assert True = owner != outcome.looked_up
  let assert True = logged(outcome.lines, ["race_died", "asking again"])
  // The held start and the new owner's.
  let assert 2 =
    list.count(outcome.lines, string.contains(_, "Started ETS table owner"))
  Nil
}
