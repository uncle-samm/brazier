//// Multi-node cluster manager tests (design test matrix, "Cluster" rows):
//// static discovery and reconnection, DNS discovery through an injected
//// resolver, the peer secret check, the production distribution check and
//// crash recovery under a supervisor.
////
//// Peers run with logging off, so outcomes are read from the cluster
//// manager's telemetry (recorded on the peer) and from `cluster.members`.

import beacon/cluster
import beacon/cluster/peer.{type Peer, Timeout}
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/static_supervisor as supervisor
import gleam/string

const wait_ms = 10_000

const secret = "cluster-test-secret-0123456789-abcdefghijklmnopqrstuvwxyz"

const other_secret = "another-deployment-secret-0123456789-abcdefghijklmnopqrstu"

pub type Event {
  Event(name: String, node: String, reason: String)
}

// --- Static discovery ---

/// A static target that is not connected yet is connected, and both sides
/// pass the peer check. The node's own name in the list is skipped.
pub fn static_connects_and_verifies_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_cl_static")
  let assert [a] = peers
  let b = peer.add_peer(a, "beacon_cl_static_b")
  assert peer.on(a, nodes) == []
  record_cluster_events([a, b])
  start_on(b, cluster.new(cluster.NoDiscovery, secret_key: secret))
  start_on(
    a,
    cluster.new(cluster.Static([name(a), name(b)]), secret_key: secret),
  )
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)
  assert peer.eventually(fn() { members(b) == [peer.node(a)] }, wait_ms)
  assert has_event(a, "beacon.cluster.node.up", name(b), "connected")
  assert has_event(b, "beacon.cluster.node.up", name(a), "connected")
}

/// A static target that drops is reported down and retried with backoff
/// until it can be reached again; the reconnected peer is re-verified.
pub fn static_target_reconnects_after_netsplit_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_cl_retry")
  let assert [a, b] = peers
  record_cluster_events([a, b])
  start_on(b, cluster.new(cluster.NoDiscovery, secret_key: secret))
  start_on(
    a,
    cluster.new(cluster.Static([name(b)]), secret_key: secret)
      |> cluster.connect_backoff(initial_ms: 20, max_ms: 100),
  )
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)

  peer.partition(a, b)
  assert peer.eventually(fn() { members(a) == [] }, wait_ms)
  assert peer.eventually(
    fn() {
      list.any(events(a), is_event(_, "beacon.cluster.node.down", name(b)))
    },
    wait_ms,
  )
  // At least two failed attempts: the target is retried, not given up on.
  assert peer.eventually(
    fn() { count_events(a, "beacon.cluster.connect.failed", name(b)) >= 2 },
    wait_ms,
  )

  peer.restore(a, b)
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)
  assert peer.eventually(fn() { members(b) == [peer.node(a)] }, wait_ms)
}

// --- DNS discovery ---

/// The manager connects to `basename@address` for each address the
/// resolver returns.
pub fn dns_discovery_connects_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_cl_dns")
  let assert [a] = peers
  let b = peer.add_peer(a, "beacon_cl_dns_b")
  let #(basename, host) = split_name(b)
  start_on(b, cluster.new(cluster.NoDiscovery, secret_key: secret))
  start_on(
    a,
    cluster.new(cluster.Dns("beacon.test", basename, 20), secret_key: secret)
      |> cluster.dns_resolver(fn(query) {
        case query {
          "beacon.test" -> Ok([host])
          other -> Error("unexpected query " <> other)
        }
      }),
  )
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)
  assert peer.eventually(fn() { members(b) == [peer.node(a)] }, wait_ms)
}

/// Lookup failures, hung lookups, crashing resolvers and oversized answers
/// are reported, not ignored, and polling continues after each.
pub fn dns_failures_are_reported_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_cl_dnsfail")
  let assert [a] = peers
  record_cluster_events([a])
  let base = fn(resolve) {
    cluster.new(cluster.Dns("beacon.test", "app", 20), secret_key: secret)
    |> cluster.dns_resolver(resolve)
    |> cluster.dns_timeout(50)
    |> cluster.max_dns_nodes(2)
  }

  let cases = [
    #(base(fn(_) { Error("nxdomain") }), "dns: nxdomain"),
    #(base(fn(_) { hang() }), "dns: timed out"),
    #(base(fn(_) { fail("resolver bug") }), "resolver_crashed"),
    #(
      base(fn(_) { Ok(["10.0.0.1", "10.0.0.2", "10.0.0.3"]) }),
      "too_many_addresses",
    ),
  ]
  list.each(cases, fn(c) {
    let #(config, reason) = c
    start_on(a, config)
    // Two reports: the first failure, and a later poll that ran after it.
    assert peer.eventually(
      fn() { count_reason(a, "beacon.cluster.connect.failed", reason) >= 2 },
      wait_ms,
    )
    let assert Ok(Nil) = peer.on(a, cluster.stop)
    Nil
  })
  // Nothing was connected by any of the failed answers.
  assert peer.on(a, nodes) == []
}

// --- Peer check ---

/// Nodes of two deployments (same cookie, different secret keys) reject
/// and disconnect each other.
pub fn secret_mismatch_disconnects_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_cl_secret")
  let assert [a, b] = peers
  record_cluster_events([a, b])
  // Already connected when the managers start: init checks them.
  start_on(a, cluster.new(cluster.NoDiscovery, secret_key: secret))
  start_on(b, cluster.new(cluster.NoDiscovery, secret_key: other_secret))
  assert peer.eventually(fn() { peer.on(a, nodes) == [] }, wait_ms)
  // Whichever manager receives the other's hello first rejects and
  // disconnects; the other side only sees the node go down. Which one it
  // is depends on start order, so accept either, but require one.
  assert peer.eventually(
    fn() {
      has_event(
        a,
        "beacon.cluster.peer.rejected",
        name(b),
        "secret key mismatch",
      )
      || has_event(
        b,
        "beacon.cluster.peer.rejected",
        name(a),
        "secret key mismatch",
      )
    },
    wait_ms,
  )
  assert peer.eventually(fn() { peer.on(b, nodes) == [] }, wait_ms)
  assert members(a) == []
  assert members(b) == []
}

/// A connected node that never answers the peer check (it runs no
/// cluster manager) is disconnected when the check times out.
pub fn silent_peer_is_disconnected_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_cl_silent")
  let assert [a, b] = peers
  record_cluster_events([a])
  start_on(
    a,
    cluster.new(cluster.NoDiscovery, secret_key: secret)
      |> cluster.peer_check_timeout(100),
  )
  assert peer.eventually(fn() { peer.on(a, nodes) == [] }, wait_ms)
  assert peer.eventually(
    fn() {
      has_event(a, "beacon.cluster.peer.rejected", name(b), "no hello within")
    },
    wait_ms,
  )
  assert members(a) == []
}

// --- Lifecycle and production checks ---

/// start, a second start, stop, and queries on a stopped manager.
pub fn lifecycle_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_cl_life")
  let assert [a] = peers
  let config = cluster.new(cluster.NoDiscovery, secret_key: secret)
  assert peer.on(a, fn() { cluster.start(config) }) == Ok(Nil)
  assert peer.on(a, fn() { cluster.start(config) })
    == Error(cluster.AlreadyStarted)
  assert peer.on(a, cluster.members) == Ok([])
  assert peer.on(a, cluster.stop) == Ok(Nil)
  assert peer.on(a, cluster.stop) == Error(cluster.NotStarted)
  assert peer.on(a, cluster.members) == Error(cluster.NotStarted)
}

/// In production, plain TCP distribution is refused unless the config
/// allows it with a reason.
pub fn production_refuses_plain_distribution_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "beacon_cl_prod")
  let assert [a] = peers
  peer.on(a, fn() { putenv("BEACON_ENV", "prod") })
  let config = cluster.new(cluster.NoDiscovery, secret_key: secret)
  let assert Error(cluster.InsecureDistribution(reason)) =
    peer.on(a, fn() { cluster.start(config) })
  assert string.contains(reason, "inet_tcp")
  // The harness cookie is long enough; only the carrier is refused.
  assert !string.contains(reason, "cookie")
  assert peer.on(a, cluster.members) == Error(cluster.NotStarted)

  let allowed =
    cluster.allow_insecure_distribution(config, "test network, no TLS")
  assert peer.on(a, fn() { cluster.start(allowed) }) == Ok(Nil)
}

/// Under a supervisor, a crashed manager is restarted and re-checks the
/// peers that are still connected.
pub fn supervised_manager_restarts_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "beacon_cl_sup")
  let assert [a, b] = peers
  start_on(b, cluster.new(cluster.NoDiscovery, secret_key: secret))
  let config = cluster.new(cluster.NoDiscovery, secret_key: secret)
  peer.on(a, fn() { start_supervised(config) })
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)

  let assert Ok(first) = peer.on(a, fn() { registered("beacon_cluster") })
  peer.on(a, fn() { kill(first) })
  assert peer.eventually(
    fn() {
      case peer.on(a, fn() { registered("beacon_cluster") }) {
        Ok(pid) -> pid != first
        Error(Nil) -> False
      }
    },
    wait_ms,
  )
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)
  // The restart did not disconnect anyone.
  assert peer.on(a, nodes) == [peer.node(b)]
}

// --- Helpers ---

fn start_on(p: Peer, config: cluster.ClusterConfig) -> Nil {
  let outcome = peer.on(p, fn() { cluster.start(config) })
  assert outcome == Ok(Nil)
}

/// Start a supervisor that owns the manager, in a process that outlives
/// the rpc call.
fn start_supervised(config: cluster.ClusterConfig) -> Nil {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(child) = cluster.supervised(config)
    let assert Ok(_) =
      supervisor.new(supervisor.OneForOne)
      |> supervisor.add(child)
      |> supervisor.start
    process.send(ready, Nil)
    process.sleep_forever()
  })
  let assert Ok(Nil) = process.receive(ready, 5000)
  Nil
}

fn members(p: Peer) -> List(Node) {
  let assert Ok(members) = peer.on(p, cluster.members)
  members
}

fn record_cluster_events(peers: List(Peer)) -> Nil {
  list.each(peers, fn(p) {
    peer.on(p, fn() {
      record_events([
        ["beacon", "cluster", "node", "up"],
        ["beacon", "cluster", "node", "down"],
        ["beacon", "cluster", "peer", "rejected"],
        ["beacon", "cluster", "connect", "failed"],
      ])
    })
  })
}

fn events(p: Peer) -> List(Event) {
  peer.on(p, recorded_events)
}

fn is_event(e: Event, event_name: String, node_name: String) -> Bool {
  e.name == event_name && e.node == node_name
}

fn has_event(
  p: Peer,
  event_name: String,
  node_name: String,
  reason: String,
) -> Bool {
  list.any(events(p), fn(e) {
    is_event(e, event_name, node_name) && string.contains(e.reason, reason)
  })
}

fn count_events(p: Peer, event_name: String, node_name: String) -> Int {
  list.count(events(p), is_event(_, event_name, node_name))
}

fn count_reason(p: Peer, event_name: String, reason: String) -> Int {
  list.count(events(p), fn(e) {
    e.name == event_name && string.contains(e.reason, reason)
  })
}

fn name(p: Peer) -> String {
  peer.node(p) |> node.name |> atom.to_string
}

/// A peer's node name split into its name and host parts.
fn split_name(p: Peer) -> #(String, String) {
  let assert Ok(parts) = string.split_once(name(p), "@")
  parts
}

fn hang() -> Result(List(String), String) {
  process.sleep_forever()
  Error("unreachable")
}

@external(erlang, "erlang", "nodes")
fn nodes() -> List(Node)

@external(erlang, "beacon_cluster_test_ffi", "record_events")
fn record_events(names: List(List(String))) -> Nil

@external(erlang, "beacon_cluster_test_ffi", "recorded_events")
fn recorded_events() -> List(Event)

@external(erlang, "beacon_cluster_test_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

@external(erlang, "beacon_cluster_test_ffi", "registered")
fn registered(name: String) -> Result(Pid, Nil)

@external(erlang, "beacon_cluster_test_ffi", "kill")
fn kill(pid: Pid) -> Nil

@external(erlang, "beacon_cluster_test_ffi", "fail")
fn fail(reason: String) -> Result(List(String), String)
