//// Tests for the multi-node harness itself: peers must never outlive the
//// test that started them, and the failure controls must do what they
//// say.

import brazier/cluster/peer.{type Peer, Timeout}
import gleam/erlang/node.{type Node}
import gleam/erlang/process
import gleam/list

const wait_ms = 10_000

/// Peers are connected to each other and run the caller's code.
pub fn peers_form_a_mesh_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(3, "brazier_peer_mesh")
  let assert [a, b, c] = peers
  let seen = peer.on(a, nodes)
  assert list.contains(seen, peer.node(b))
  assert list.contains(seen, peer.node(c))
  assert peer.on(b, node_self) == peer.node(b)
}

/// A body that fails still stops every peer.
pub fn failing_body_stops_peers_test_() -> peer.Timeout {
  use <- Timeout(60)
  let out = process.new_subject()
  let outcome =
    rescue(fn() {
      peer.with_cluster(2, "brazier_peer_fail", fn(peers) {
        process.send(out, peers)
        fail("checking cleanup")
      })
    })
  assert outcome == Error("error")
  let assert Ok(peers) = process.receive(out, 0)
  assert peers != []
  assert all_gone(peers)
}

/// A test process that dies (here: killed) still gets its peers stopped by
/// the keeper.
pub fn owner_death_stops_peers_test_() -> peer.Timeout {
  use <- Timeout(60)
  let out = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      peer.with_cluster(1, "brazier_peer_owner", fn(peers) {
        process.send(out, peers)
        process.sleep_forever()
      })
    })
  let assert Ok(peers) = process.receive(out, wait_ms)
  process.kill(owner)
  assert all_gone(peers)
}

/// `crash` halts a node: the others see it leave and the harness stops
/// tracking it. `stop` shuts one down gracefully.
pub fn crash_and_stop_take_nodes_down_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(3, "brazier_peer_down")
  let assert [a, b, c] = peers
  peer.crash(b)
  assert !peer.alive(b)
  assert peer.eventually(
    fn() { !list.contains(peer.on(a, nodes), peer.node(b)) },
    wait_ms,
  )
  peer.stop(c)
  assert !peer.alive(c)
  assert peer.eventually(fn() { peer.on(a, nodes) == [] }, wait_ms)
  let assert Error(_) = peer.rpc(b, node_self)
  Nil
}

/// `partition` disconnects two nodes and keeps them apart (a reconnect
/// attempt fails); `heal` joins them again.
pub fn partition_and_heal_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_peer_split")
  let assert [a, b] = peers
  peer.partition(a, b)
  assert peer.eventually(fn() { peer.on(a, nodes) == [] }, wait_ms)
  assert peer.eventually(fn() { peer.on(b, nodes) == [] }, wait_ms)
  let assert Error(_) = peer.connect(a, b)
  peer.heal(a, b)
  assert peer.on(a, nodes) == [peer.node(b)]
}

/// `add_peer` starts an unconnected node that `connect` joins.
pub fn add_peer_joins_on_connect_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_peer_add")
  let assert [a] = peers
  let late = peer.add_peer(a, "brazier_peer_late")
  assert peer.on(late, nodes) == []
  let assert Ok(Nil) = peer.connect(late, a)
  assert peer.on(a, nodes) == [peer.node(late)]
}

fn all_gone(peers: List(Peer)) -> Bool {
  peer.eventually(
    fn() {
      case peers {
        [] -> True
        _ -> none_alive(peers)
      }
    },
    wait_ms,
  )
}

fn none_alive(peers: List(Peer)) -> Bool {
  case peers {
    [] -> True
    [p, ..rest] -> !peer.alive(p) && none_alive(rest)
  }
}

@external(erlang, "erlang", "nodes")
fn nodes() -> List(Node)

@external(erlang, "erlang", "node")
fn node_self() -> Node

@external(erlang, "brazier_pubsub_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, String)

@external(erlang, "brazier_cluster_test_ffi", "fail")
fn fail(reason: String) -> Nil
