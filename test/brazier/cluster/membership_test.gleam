//// Cluster traffic goes only between verified members (SEC-3).
////
//// Every test runs three connected peers. `a` and `c` share the secret key
//// and verify each other. `b` belongs to another deployment (same cookie,
//// different secret key). Its cluster manager is suspended, so `b` stays
//// connected to both and is a member of neither, for as long as the
//// test body runs. For PubSub, replicated stores, presence and session
//// revocation, each test checks three things. Traffic from `a` reaches `c`
//// (the control). Nothing goes from `a` to `b`. Nothing from `b` is taken
//// in: `b` sends nothing, and a message forged on `b`'s behalf is dropped
//// where it lands. Once `b`'s manager runs again, it rejects the others'
//// hellos and the nodes disconnect.
////
//// The checks on the sending side are exact: the verified member list is
//// what every sender consults. A dropped revocation is read from the
//// sender's log, and a forged message from a barrier after it. The
//// absence of ordinary traffic at `b` is checked once the control message
//// has arrived at `c`.

import brazier/cluster
import brazier/cluster/log_capture
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/presence
import brazier/presence/holder
import brazier/pubsub
import brazier/session.{type ExternalBackend, type SessionStore, External}
import brazier/store
import brazier/store/replicated.{Config}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/json
import gleam/list
import gleam/order
import gleam/string

const wait_ms = 10_000

const secret = "membership-test-secret-0123456789-abcdefghijklmnopqrstuvwx"

const other_secret = "another-deployment-secret-0123456789-abcdefghijklmnopqrstu"

/// A telemetry event recorded on a peer (see brazier_cluster_test_ffi).
pub type Event {
  // The constructor name is the tag the FFI builds the tuple with.
  Event(name: String, node: String, reason: String)
}

// --- PubSub -----------------------------------------------------------------

pub fn pubsub_exchanges_nothing_with_an_unverified_node_test_() -> peer.Timeout {
  use <- Timeout(60)
  use a, b, c <- with_intruder("brazier_mem_ps")
  list.each([a, b, c], fn(p) { peer.on(p, pubsub.start) })
  // pg lists every connected node's worker, b's included; membership, not
  // pg, decides where forwards go.
  assert peer.eventually(
    fn() {
      peer.on(a, fn() { remote_worker_nodes(0) })
      == list.sort([peer.node(b), peer.node(c)], by: node_order)
    },
    wait_ms,
  )
  let topic = "members-only"
  let assert [on_a] = peer.on(a, fn() { spawn_recorders(topic, 1) })
    as "one recorder was asked for"
  let assert [on_b] = peer.on(b, fn() { spawn_recorders(topic, 1) })
    as "one recorder was asked for"
  let assert [on_c] = peer.on(c, fn() { spawn_recorders(topic, 1) })
    as "one recorder was asked for"

  // a to c, and not to b.
  let assert Ok(Nil) =
    peer.on(a, fn() { pubsub.try_broadcast(topic, "from-a") })
    as "a broadcast on a running PubSub succeeds"
  assert peer.eventually(
    fn() { peer.on(c, fn() { recorded(on_c) }) == ["from-a"] },
    wait_ms,
  )
  let b_node = peer.node(b)
  assert peer.on(a, fn() { pubsub.direct_broadcast(b_node, topic, "direct") })
    == Error(pubsub.NodeNotVerified(node: node_name(b)))

  // b sends to nobody: it has no verified members.
  let a_node = peer.node(a)
  let assert Ok(Nil) =
    peer.on(b, fn() { pubsub.try_broadcast(topic, "from-b") })
    as "a broadcast on a running PubSub succeeds"
  assert peer.on(b, fn() { pubsub.direct_broadcast(a_node, topic, "direct") })
    == Error(pubsub.NodeNotVerified(node: node_name(a)))

  // A forward forged on b, sent straight to a's worker, is dropped there.
  let #(Nil, lines) =
    peer.on(a, fn() {
      log_capture.capture(fn() {
        erpc_call(b_node, fn() { forge_forward(a_node, topic, "forged") })
      })
    })
  assert logged(lines, "debug", [
    "dropped a forward on members-only",
    node_name(b),
  ])

  // A last broadcast from a, after everything above, reaches c.
  let assert Ok(Nil) = peer.on(a, fn() { pubsub.try_broadcast(topic, "last") })
    as "a broadcast on a running PubSub succeeds"
  assert peer.eventually(
    fn() { peer.on(c, fn() { recorded(on_c) }) == ["from-a", "last"] },
    wait_ms,
  )
  assert peer.on(a, fn() { recorded(on_a) }) == ["from-a", "last"]
  assert peer.on(b, fn() { recorded(on_b) }) == ["from-b"]
}

// --- Replicated store -------------------------------------------------------

const store_name = "membership"

pub fn store_exchanges_nothing_with_an_unverified_node_test_() -> peer.Timeout {
  use <- Timeout(60)
  use a, b, c <- with_intruder("brazier_mem_store")
  let kv = open_store(a)
  let _ = open_store(b)
  let _ = open_store(c)

  put_on(a, kv, "from-a", "1")
  put_on(b, kv, "from-b", "2")
  assert peer.eventually(fn() { get_on(c, kv, "from-a") == Ok("1") }, wait_ms)
  // Anti-entropy (every 100ms) has had its chance to fill any gap too.
  put_on(c, kv, "from-c", "3")
  assert peer.eventually(fn() { get_on(a, kv, "from-c") == Ok("3") }, wait_ms)
  assert get_on(b, kv, "from-a") == Error(Nil)
  assert get_on(b, kv, "from-c") == Error(Nil)
  assert get_on(a, kv, "from-b") == Error(Nil)
  assert get_on(c, kv, "from-b") == Error(Nil)

  // A peer message naming b as its sender is dropped by a's replica.
  let b_node = peer.node(b)
  // The replica's peer topic (brazier_store_replica:names/2), not the
  // store's own change topic.
  let topic = "brazier_store:kv:" <> store_name
  let #(delivered, lines) =
    peer.on(a, fn() {
      log_capture.capture(fn() {
        deliver_forged(topic, store_message_from(b_node))
      })
    })
  assert delivered == 1
  assert logged(lines, "warning", [
    "Replica " <> store_name,
    "not a verified cluster member",
    node_name(b),
  ])
}

// --- Presence ---------------------------------------------------------------

const presence_name = "membership"

pub fn presence_exchanges_nothing_with_an_unverified_node_test_() -> peer.Timeout {
  use <- Timeout(60)
  use a, b, c <- with_intruder("brazier_mem_pres")
  let config =
    presence.new(presence_name, json.string, decode.string)
    |> presence.broadcast_period(50)
  let tracker = start_presence(a, config)
  let _ = start_presence(b, config)
  let _ = start_presence(c, config)

  track_on(a, tracker, "alice")
  track_on(b, tracker, "bob")
  assert peer.eventually(fn() { keys(c, tracker) == ["alice"] }, wait_ms)
  // a and c hear each other's heartbeats; b hears and is heard by no one.
  assert peer.eventually(
    fn() { replicas(a, tracker) == [node_name(c)] },
    wait_ms,
  )
  assert peer.eventually(
    fn() { replicas(c, tracker) == [node_name(a)] },
    wait_ms,
  )
  assert replicas(b, tracker) == []
  assert keys(a, tracker) == ["alice"]
  assert keys(b, tracker) == ["bob"]

  // A peer message naming b as its sender is dropped by a's shard.
  let b_node = peer.node(b)
  let #(delivered, lines) =
    peer.on(a, fn() {
      log_capture.capture(fn() {
        deliver_forged(
          "brazier_presence:" <> presence_name <> ":1",
          presence_message_from(b_node),
        )
      })
    })
  assert delivered == 1
  assert logged(lines, "warning", [
    "not a verified cluster member",
    node_name(b),
  ])
}

// --- Session revocation -----------------------------------------------------

pub fn revocation_reaches_no_unverified_node_test_() -> peer.Timeout {
  use <- Timeout(60)
  use a, b, c <- with_intruder("brazier_mem_sess")
  let name = "membership"
  // The database lives on a; every node reaches it over erpc, as every
  // node would reach Postgres whatever its cluster membership.
  let db = peer.node(a)
  peer.on(a, fn() { start_db(name) })
  let store_a = start_session_store(a, name, db)
  let store_b = start_session_store(b, name, db)
  let store_c = start_session_store(c, name, db)

  // A logout on a reaches c's socket and skips b's.
  let s = peer.on(a, fn() { session.create(store_a) })
  let _ = bind_on(b, store_b, s.id)
  let _ = bind_on(c, store_c, s.id)
  assert bound_seen_from(a, name, s.id, 2)
  let #(Nil, lines) =
    peer.on(a, fn() {
      log_capture.capture(fn() { session.delete(store_a, s.id) })
    })
  assert logged(lines, "warning", [
    "Revocation skipped 1 bound process(es)",
    node_name(b),
  ])
  assert peer.eventually(
    fn() { list.contains(peer.on(c, revocations), #(s.id, "deleted")) },
    wait_ms,
  )
  assert !list.contains(peer.on(b, revocations), #(s.id, "deleted"))

  // A logout on b reaches no other node.
  let t = peer.on(b, fn() { session.create(store_b) })
  let _ = bind_on(a, store_a, t.id)
  let _ = bind_on(c, store_c, t.id)
  assert bound_seen_from(b, name, t.id, 2)
  let #(Nil, lines) =
    peer.on(b, fn() {
      log_capture.capture(fn() { session.delete(store_b, t.id) })
    })
  assert logged(lines, "warning", [
    "Revocation skipped 2 bound process(es)",
    node_name(a),
    node_name(c),
  ])
  assert !list.contains(peer.on(a, revocations), #(t.id, "deleted"))
  assert !list.contains(peer.on(c, revocations), #(t.id, "deleted"))
}

// --- Setup ------------------------------------------------------------------

/// Three connected peers: `a` and `c` are verified members, `b` runs a
/// suspended manager with another deployment's secret. After `run`, `b`'s
/// manager is resumed and must reject the others and disconnect.
fn with_intruder(prefix: String, run: fn(Peer, Peer, Peer) -> Nil) -> Nil {
  use peers <- peer.with_cluster(3, prefix)
  let assert [a, b, c] = peers as "with_cluster(3) starts three peers"
  record_cluster_events(peers)
  // The peer check of b never times out during the test.
  let config =
    cluster.new(cluster.NoDiscovery) |> cluster.peer_check_timeout(60_000)
  // b's hellos go out before a and c run a manager, and are lost; then b
  // answers nothing while suspended.
  start_manager(b, config, other_secret)
  peer.on(b, manager_suspend)
  start_manager(a, config, secret)
  start_manager(c, config, secret)
  let assert Ok(Nil) = peer.await_member(a, peer.node(c), wait_ms)
    as "a and c share the secret key"
  let assert Ok(Nil) = peer.await_member(c, peer.node(a), wait_ms)
    as "a and c share the secret key"
  assert members(a) == [peer.node(c)]
  assert members(c) == [peer.node(a)]
  assert members(b) == []
  assert list.contains(peer.on(a, nodes), peer.node(b))
  assert list.contains(peer.on(c, nodes), peer.node(b))

  run(a, b, c)

  peer.on(b, manager_resume)
  assert peer.eventually(fn() { peer.on(b, nodes) == [] }, wait_ms)
  assert peer.eventually(fn() { rejected(b, a) }, wait_ms)
  assert peer.eventually(fn() { rejected(b, c) }, wait_ms)
  assert members(a) == [peer.node(c)]
}

fn start_manager(p: Peer, config: cluster.ClusterConfig, key: String) -> Nil {
  let outcome = peer.on(p, fn() { cluster.start(config, secret_key: key) })
  assert outcome == Ok(Nil)
}

fn members(p: Peer) -> List(Node) {
  let assert Ok(members) = peer.on(p, cluster.members)
    as "the manager started in setup is running"
  members
}

fn record_cluster_events(peers: List(Peer)) -> Nil {
  list.each(peers, fn(p) {
    peer.on(p, fn() {
      record_events([["brazier", "cluster", "peer", "rejected"]])
    })
  })
}

/// Whether `by` recorded rejecting `other` for its secret key.
fn rejected(by: Peer, other: Peer) -> Bool {
  peer.on(by, recorded_events)
  |> list.any(fn(e) {
    e.name == "brazier.cluster.peer.rejected"
    && e.node == node_name(other)
    && string.contains(e.reason, "secret key mismatch")
  })
}

fn node_name(p: Peer) -> String {
  peer.node(p) |> node.name |> atom.to_string
}

/// Whether one captured line at `level` holds every fragment.
fn logged(
  lines: List(log_capture.Line),
  level: String,
  fragments: List(String),
) -> Bool {
  list.any(lines, fn(line) {
    line.level == level
    && list.all(fragments, fn(f) { string.contains(line.message, f) })
  })
}

fn node_order(x: Node, y: Node) -> order.Order {
  string.compare(atom.to_string(node.name(x)), atom.to_string(node.name(y)))
}

// --- Store and presence helpers ----------------------------------------------

fn open_store(p: Peer) -> store.Store(String) {
  let config = Config(..replicated.default_config(), sync_interval_ms: 100)
  peer.on(p, fn() {
    pubsub.start()
    let assert Ok(kv) = store.open(store_name, store.Replicated(config))
      as "a replicated store opens on a running PubSub"
    kv
  })
}

fn put_on(p: Peer, kv: store.Store(String), key: String, value: String) -> Nil {
  peer.on(p, fn() { store.put(kv, key, value) })
}

fn get_on(
  p: Peer,
  kv: store.Store(String),
  key: String,
) -> Result(String, Nil) {
  peer.on(p, fn() { store.get(kv, key) })
}

fn start_presence(
  p: Peer,
  config: presence.PresenceConfig(String),
) -> presence.Presence(String) {
  peer.on(p, fn() {
    pubsub.start()
    let assert Ok(tracker) = presence.start(config)
      as "a tracker starts on a running PubSub"
    tracker
  })
}

fn track_on(p: Peer, tracker: presence.Presence(String), key: String) -> Nil {
  peer.on(p, fn() {
    let h = holder.start()
    let assert Ok(_) =
      holder.run(h, fn() { presence.track(tracker, "room", key, "online") })
      as "a fresh holder tracks a new key"
    Nil
  })
}

fn keys(p: Peer, tracker: presence.Presence(String)) -> List(String) {
  peer.on(p, fn() {
    let assert Ok(entries) = presence.list(tracker, "room")
      as "the tracker started in the test is running"
    list.map(entries, fn(entry) { entry.key })
  })
}

/// The nodes whose replica `p`'s shard for "room" hears from.
fn replicas(p: Peer, tracker: presence.Presence(String)) -> List(String) {
  peer.on(p, fn() {
    let assert Ok(replicas) = presence.replicas(tracker, "room")
      as "the tracker started in the test is running"
    list.map(replicas, fn(r) { r.0 })
  })
}

// --- Session helpers --------------------------------------------------------

fn start_session_store(p: Peer, name: String, db: Node) -> SessionStore {
  peer.on(p, fn() {
    session.ensure_registry()
    let ext = backend(name, db)
    let assert Ok(store) =
      owned(fn() {
        session.start_store(External(ext), session.default_store_config())
      })
      as "an External session store starts"
    store
  })
}

fn bind_on(p: Peer, store: SessionStore, id: String) -> Pid {
  peer.on(p, fn() {
    spawn_bound(fn() { session.bind_current_process(store, id) })
  })
}

fn bound_seen_from(p: Peer, name: String, id: String, expected: Int) -> Bool {
  peer.eventually(
    fn() {
      peer.on(p, fn() { bound_everywhere("external:" <> name, id) }) == expected
    },
    wait_ms,
  )
}

// --- FFI --------------------------------------------------------------------

@external(erlang, "erlang", "nodes")
fn nodes() -> List(Node)

@external(erlang, "erpc", "call")
fn erpc_call(node: Node, run: fn() -> a) -> a

@external(erlang, "brazier_cluster_test_ffi", "manager_suspend")
fn manager_suspend() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "manager_resume")
fn manager_resume() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "record_events")
fn record_events(names: List(List(String))) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "recorded_events")
fn recorded_events() -> List(Event)

@external(erlang, "brazier_cluster_test_ffi", "remote_worker_nodes")
fn remote_worker_nodes(shard: Int) -> List(Node)

@external(erlang, "brazier_cluster_test_ffi", "spawn_recorders")
fn spawn_recorders(topic: String, count: Int) -> List(Pid)

@external(erlang, "brazier_cluster_test_ffi", "recorded")
fn recorded(pid: Pid) -> List(String)

@external(erlang, "brazier_cluster_test_ffi", "forge_forward")
fn forge_forward(node: Node, topic: String, message: String) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "deliver_forged")
fn deliver_forged(topic: String, forged: Forged) -> Int

@external(erlang, "brazier_cluster_test_ffi", "store_message_from")
fn store_message_from(from: Node) -> Forged

@external(erlang, "brazier_cluster_test_ffi", "presence_message_from")
fn presence_message_from(from: Node) -> Forged

/// A peer message built in Erlang, in the internal wire format.
type Forged

@external(erlang, "brazier_session_test_ffi", "start_db")
fn start_db(name: String) -> Nil

@external(erlang, "brazier_session_test_ffi", "backend")
fn backend(name: String, db: Node) -> ExternalBackend

@external(erlang, "brazier_session_test_ffi", "owned")
fn owned(run: fn() -> a) -> a

@external(erlang, "brazier_session_test_ffi", "spawn_bound")
fn spawn_bound(bind: fn() -> Nil) -> Pid

@external(erlang, "brazier_session_test_ffi", "revocations")
fn revocations() -> List(#(String, String))

@external(erlang, "brazier_session_test_ffi", "bound_everywhere")
fn bound_everywhere(namespace: String, id: String) -> Int
