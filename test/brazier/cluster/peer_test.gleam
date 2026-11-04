//// Tests for the multi-node harness itself: peers must never outlive the
//// test that started them, and the failure controls must do what they
//// say.

import brazier/await
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/telemetry
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/node.{type Node}
import gleam/erlang/process
import gleam/list

const wait_ms = 10_000

/// Peers are connected to each other and run the caller's code.
pub fn peers_form_a_mesh_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(3, "brazier_peer_mesh")
  let assert [a, b, c] = peers as "the cluster starts three peers"
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
  let assert Ok(peers) = process.receive(out, 0) as "process.receive succeeds"
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
    as "process.receive succeeds"
  process.kill(owner)
  assert all_gone(peers)
}

/// `crash` halts a node: the others see it leave and the harness stops
/// tracking it. `stop` shuts one down gracefully.
pub fn crash_and_stop_take_nodes_down_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(3, "brazier_peer_down")
  let assert [a, b, c] = peers as "the cluster starts three peers"
  peer.crash(b)
  assert !peer.alive(b)
  let b_node = peer.node(b)
  assert peer.until(
    a,
    peer.node_changes(),
    fn() { !list.contains(nodes(), b_node) },
    wait_ms,
  )
  peer.stop(c)
  assert !peer.alive(c)
  assert peer.until(a, peer.node_changes(), fn() { nodes() == [] }, wait_ms)
  let assert Error(_) = peer.rpc(b, node_self) as "peer.rpc returns Error"
  Nil
}

/// `partition` disconnects two nodes and keeps them apart (a reconnect
/// attempt fails); `heal` joins them again.
pub fn partition_and_heal_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_peer_split")
  let assert [a, b] = peers as "the cluster starts two peers"
  peer.partition(a, b)
  assert peer.until(a, peer.node_changes(), fn() { nodes() == [] }, wait_ms)
  assert peer.until(b, peer.node_changes(), fn() { nodes() == [] }, wait_ms)
  let assert Error(_) = peer.connect(a, b) as "peer.connect returns Error"
  peer.heal(a, b)
  assert peer.on(a, nodes) == [peer.node(b)]
}

/// `add_peer` starts an unconnected node that `connect` joins.
pub fn add_peer_joins_on_connect_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_peer_add")
  let assert [a] = peers as "the cluster starts one peer"
  let late = peer.add_peer(a, "brazier_peer_late")
  assert peer.on(late, nodes) == []
  let assert Ok(Nil) = peer.connect(late, a) as "peer.connect succeeds"
  assert peer.on(a, nodes) == [peer.node(late)]
}

/// `until` re-checks on each wake-up, gives up at its deadline, and undoes
/// its wake however the wait ends: here a telemetry handler, which would
/// otherwise outlive the rpc process that attached it.
pub fn until_undoes_its_wake_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_peer_until")
  let assert [a] = peers as "the cluster starts one peer"
  let name = ["brazier_peer_test", "wake"]
  let wake = peer.events([name])

  // The event arrives after the first check, so only the wake-up sees it.
  let emitted =
    peer.until(
      a,
      wake,
      fn() {
        let seen = seen_before()
        let assert Ok(Nil) = telemetry.execute(name, dict.new(), dict.new())
          as "telemetry.execute succeeds"
        seen
      },
      wait_ms,
    )
  assert emitted
  assert peer.on(a, fn() { wake_handlers(name) }) == 0

  assert !peer.until(a, wake, fn() { False }, 50)
  assert peer.on(a, fn() { wake_handlers(name) }) == 0

  let outcome =
    rescue(fn() {
      peer.until(
        a,
        wake,
        fn() {
          fail("checking cleanup")
          False
        },
        wait_ms,
      )
    })
  assert outcome == Error("error")
  assert peer.on(a, fn() { wake_handlers(name) }) == 0
}

/// Whether every peer's control process (on this node) exits within
/// `wait_ms`: each is monitored, so its DOWN ends the wait.
fn all_gone(peers: List(Peer)) -> Bool {
  list.all(peers, fn(p) { await.await_down(p.control, wait_ms) == Ok(Nil) })
}

/// Whether this rpc process has called it before (its process dictionary
/// lives as long as the one rpc).
fn seen_before() -> Bool {
  put(atom.create("brazier_peer_test_seen"), True) == dynamic.bool(True)
}

/// How many handlers are attached to `name` on this node.
fn wake_handlers(name: List(String)) -> Int {
  list.length(list_handlers(list.map(name, atom.create)))
}

@external(erlang, "erlang", "put")
fn put(key: Atom, value: Bool) -> Dynamic

@external(erlang, "telemetry", "list_handlers")
fn list_handlers(prefix: List(Atom)) -> List(Dynamic)

@external(erlang, "erlang", "nodes")
fn nodes() -> List(Node)

@external(erlang, "erlang", "node")
fn node_self() -> Node

@external(erlang, "brazier_pubsub_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, String)

@external(erlang, "brazier_cluster_test_ffi", "fail")
fn fail(reason: String) -> Nil
