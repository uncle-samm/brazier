//// A subscriber held at each point of `subscribe` in turn while its PubSub
//// partition is killed (STAB-3), deterministically.
////
//// `partition_churn_leaves_no_orphan_rows_test_` in `pubsub_cluster_test`
//// races subscribers against restarts at random, and its subscribers do
//// not trap exits: one linked to the killed partition dies with it, so a
//// row it left in the restarted partition's tables is never seen there.
//// Here the race is not left to chance: the node runs one scheduler, the
//// subscriber is scheduled out after 1, 2, ... reductions inside
//// `subscribe`, and while it is out the test kills its partition. The
//// subscriber then runs on after the restart ("up"), or while the
//// partition is dead and its supervisor suspended ("down"), trapping exits
//// or not (`brazier_pubsub_restart_race_test_ffi`). Nothing sleeps.

import brazier/cluster/peer.{Timeout}
import brazier/pubsub.{type PubSubConfig}

@external(erlang, "brazier_pubsub_restart_race_test_ffi", "sweep")
fn sweep(config: PubSubConfig, topic: String) -> #(List(String), List(String))

/// Wherever the kill falls, the subscriber ends subscribed in the restarted
/// partition and linked to it, subscribed in the killed one (its rows went
/// with that partition's tables), refused with no row and no link, or, when
/// it does not trap exits and was linked to the killed partition, dead with
/// it. Never with a row in a partition that is not linked to it, which
/// nothing would remove; never crashed on the dead partition's missing
/// tables or name; never holding the exit of a link it made to the
/// partition after it died.
///
/// The holds cover every way `subscribe` meets the kill, the narrowest
/// being a hold between the check that the partition still holds its name
/// and the inserts: after a restart the inserts land in the restarted
/// partition's tables and only the check after them sees it; with no
/// restart they find no table.
pub fn a_subscriber_held_across_a_partition_restart_leaves_no_orphan_row_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_ps_restart_race")
  let assert [a] = peers as "with_cluster(1) starts one peer"
  let config = pubsub.default_config() |> pubsub.partitions(1)
  let #(violations, seen) = peer.on(a, fn() { sweep(config, "race") })
  assert violations == []
  assert seen
    == [
      "down, not_trapping: held_after_the_check_before_the_inserts: killed_with_the_partition",
      "down, not_trapping: held_after_the_link_before_the_check: killed_with_the_partition",
      "down, not_trapping: held_after_the_recheck: killed_with_the_partition",
      "down, not_trapping: held_before_the_link: refused",
      "down, not_trapping: held_before_the_lookup: refused",
      "down, not_trapping: held_between_the_inserts: killed_with_the_partition",
      "down, not_trapping: returned_before_the_kill: killed_with_the_partition",
      "down, trapping: held_after_the_check_before_the_inserts: refused, holding the partition's exit",
      "down, trapping: held_after_the_link_before_the_check: refused, holding the partition's exit",
      "down, trapping: held_after_the_recheck: lost_with_the_killed_partition, holding the partition's exit",
      "down, trapping: held_before_the_link: refused",
      "down, trapping: held_before_the_lookup: refused",
      "down, trapping: held_between_the_inserts: refused, holding the partition's exit",
      "down, trapping: returned_before_the_kill: lost_with_the_killed_partition, holding the partition's exit",
      "up, trapping: held_after_the_check_before_the_inserts: refused, holding the partition's exit",
      "up, trapping: held_after_the_link_before_the_check: refused, holding the partition's exit",
      "up, trapping: held_after_the_recheck: lost_with_the_killed_partition, holding the partition's exit",
      "up, trapping: held_before_the_link: refused",
      "up, trapping: held_before_the_lookup: subscribed",
      "up, trapping: held_between_the_inserts: refused, holding the partition's exit",
      "up, trapping: returned_before_the_kill: lost_with_the_killed_partition, holding the partition's exit",
    ]
}
