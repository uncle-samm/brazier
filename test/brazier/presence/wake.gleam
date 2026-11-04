//// `peer.until` wakes for presence state.

import brazier/cluster/peer
import brazier/presence.{type Presence}

/// Wake on every diff `tracker`'s shard for `topic` reports on this node.
/// The shard writes its table before it broadcasts the diff
/// (`report/3` in brazier_presence_shard), so a `presence.list` or
/// `presence.get_by_key` after the wake-up sees the change. A change that
/// reports nothing (a replica status, a shard restart) needs another wake.
pub fn diffs(tracker: Presence(meta), topic: String) -> peer.Wake {
  fn() {
    let assert Ok(Nil) = presence.subscribe(tracker, topic)
      as "the diff wake subscribes"
    fn() {
      let assert Ok(Nil) = presence.unsubscribe(tracker, topic)
        as "the diff wake unsubscribes"
      Nil
    }
  }
}

/// Wake on every replica status change on this node
/// (`[brazier, presence, replica, up | down | permdown]`). A shard emits
/// the event while it handles the change, so `presence.replicas`, a call
/// to the shard, answers only after the change is stored.
pub fn replica_changes() -> peer.Wake {
  peer.events([
    ["brazier", "presence", "replica", "up"],
    ["brazier", "presence", "replica", "down"],
    ["brazier", "presence", "replica", "permdown"],
  ])
}
