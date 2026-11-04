//// Multi-node cluster manager tests (design test matrix, "Cluster" rows):
//// static discovery and reconnection, DNS discovery through an injected
//// resolver (and the atoms it may make), the peer secret check and its
//// timers, keeping the MAC out of status and logs, the production
//// distribution check and crash recovery under a supervisor.
////
//// Peers run with logging off, so outcomes are read from the cluster
//// manager's telemetry (recorded on the peer) and from `cluster.members`.

import brazier/cluster
import brazier/cluster/log_capture
import brazier/cluster/peer.{type Peer, Timeout}
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/erlang/reference.{type Reference}
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
  use peers <- peer.with_cluster(1, "brazier_cl_static")
  let assert [a] = peers as "the cluster starts one peer"
  let b = peer.add_peer(a, "brazier_cl_static_b")
  assert peer.on(a, nodes) == []
  record_cluster_events([a, b])
  start_on(b, cluster.new(cluster.NoDiscovery))
  start_on(a, cluster.new(cluster.Static([name(a), name(b)])))
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)
  assert peer.eventually(fn() { members(b) == [peer.node(a)] }, wait_ms)
  assert has_event(a, "brazier.cluster.node.up", name(b), "connected")
  assert has_event(b, "brazier.cluster.node.up", name(a), "connected")
}

/// A static target that drops is reported down and retried with backoff
/// until it can be reached again; the reconnected peer is re-verified.
pub fn static_target_reconnects_after_netsplit_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_cl_retry")
  let assert [a, b] = peers as "the cluster starts two peers"
  record_cluster_events([a, b])
  start_on(b, cluster.new(cluster.NoDiscovery))
  start_on(
    a,
    cluster.new(cluster.Static([name(b)]))
      |> cluster.connect_backoff(initial_ms: 20, max_ms: 100),
  )
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)

  peer.partition(a, b)
  assert peer.eventually(fn() { members(a) == [] }, wait_ms)
  assert peer.eventually(
    fn() {
      list.any(events(a), is_event(_, "brazier.cluster.node.down", name(b)))
    },
    wait_ms,
  )
  // At least two failed attempts: the target is retried, not given up on.
  assert peer.eventually(
    fn() { count_events(a, "brazier.cluster.connect.failed", name(b)) >= 2 },
    wait_ms,
  )

  peer.restore(a, b)
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)
  assert peer.eventually(fn() { members(b) == [peer.node(a)] }, wait_ms)
}

// --- DNS discovery ---

/// The manager connects to `basename@address` for each address the
/// resolver returns (the peers are named `name@127.0.0.1`).
pub fn dns_discovery_connects_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_long_name_cluster(1, "brazier_cl_dns")
  let assert [a] = peers as "the cluster starts one peer"
  let b = peer.add_peer(a, "brazier_cl_dns_b")
  let #(basename, host) = split_name(b)
  start_on(b, cluster.new(cluster.NoDiscovery))
  start_on(
    a,
    cluster.new(cluster.Dns("brazier.test", basename, 20))
      |> cluster.dns_resolver(fn(query) {
        case query {
          "brazier.test" -> Ok([host])
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
  use peers <- peer.with_cluster(1, "brazier_cl_dnsfail")
  let assert [a] = peers as "the cluster starts one peer"
  record_cluster_events([a])
  let base = fn(resolve) {
    cluster.new(cluster.Dns("brazier.test", "app", 20))
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
      fn() { count_reason(a, "brazier.cluster.connect.failed", reason) >= 2 },
      wait_ms,
    )
    let assert Ok(Nil) = peer.on(a, cluster.stop) as "cluster.stop succeeds"
    Nil
  })
  // Nothing was connected by any of the failed answers.
  assert peer.on(a, nodes) == []
}

/// Node names are atoms, which are never freed: an answer entry that is
/// not an IP address never becomes one (it is reported and skipped), and
/// an address is named by its canonical text, so one address is one atom.
pub fn dns_entries_that_are_not_addresses_make_no_atoms_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_cl_dnsbad")
  let assert [a] = peers as "with_cluster(1) starts one peer"
  record_cluster_events([a])
  let answer = [
    "not-an-ip", "1.2.3", "evil@host", "0:0:0:0:0:0:0:1", "192.0.2.10",
  ]
  start_on(
    a,
    cluster.new(cluster.Dns("brazier.test", "dnsbad", 20))
      |> cluster.dns_resolver(fn(_) { Ok(answer) }),
  )
  // Reported on every poll, not just once.
  assert peer.eventually(
    fn() {
      count_reason(a, "brazier.cluster.connect.failed", "{invalid_addresses,3}")
      >= 2
    },
    wait_ms,
  )
  let made = fn(host) { peer.on(a, fn() { atom_exists("dnsbad@" <> host) }) }
  assert made("192.0.2.10")
  assert made("::1")
  assert !made("0:0:0:0:0:0:0:1")
  assert !made("not-an-ip")
  assert !made("1.2.3")
  assert !made("evil@host")
}

/// DNS discovery makes at most `max_discovered_nodes` node names over the
/// life of the VM: past it, new addresses are refused and reported, and a
/// restarted manager keeps the count.
pub fn dns_node_names_are_capped_for_the_life_of_the_vm_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_cl_dnscap")
  let assert [a] = peers as "with_cluster(1) starts one peer"
  record_cluster_events([a])
  let hosts = ["192.0.2.1", "192.0.2.2", "192.0.2.3", "192.0.2.4", "192.0.2.5"]
  let config =
    cluster.new(cluster.Dns("brazier.test", "dnscap", 20))
    |> cluster.dns_resolver(fn(_) { Ok(hosts) })
    |> cluster.max_discovered_nodes(3)
  let made = fn() {
    list.count(hosts, fn(host) {
      peer.on(a, fn() { atom_exists("dnscap@" <> host) })
    })
  }
  let refused = fn() {
    count_reason(
      a,
      "brazier.cluster.connect.failed",
      "{max_discovered_nodes,3,2}",
    )
  }

  start_on(a, config)
  assert peer.eventually(fn() { refused() >= 2 }, wait_ms)
  assert made() == 3

  let assert Ok(Nil) = peer.on(a, cluster.stop)
    as "the manager started above is running"
  let before = refused()
  start_on(a, config)
  // The new manager still refuses the two names past the cap.
  assert peer.eventually(fn() { refused() >= before + 2 }, wait_ms)
  assert made() == 3
}

// --- Peer check ---

/// Nodes of two deployments (same cookie, different secret keys) reject
/// each other and stay connected: neither is the other's member, and
/// neither drops the connection (which would make `global` partition the
/// rest of a larger cluster; see membership_test).
pub fn secret_mismatch_rejects_without_disconnecting_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_cl_secret")
  let assert [a, b] = peers as "the cluster starts two peers"
  record_cluster_events([a, b])
  let config =
    cluster.new(cluster.NoDiscovery) |> cluster.peer_check_timeout(60_000)
  // Already connected when the managers start: init checks them.
  start_on(a, config)
  start_with(b, config, other_secret)
  // Each side's hello, handled before the call returns.
  hello(from: b, to: a, key: other_secret)
  hello(from: a, to: b, key: secret)
  assert has_event(
    a,
    "brazier.cluster.peer.rejected",
    name(b),
    "secret key mismatch",
  )
  assert has_event(
    b,
    "brazier.cluster.peer.rejected",
    name(a),
    "secret key mismatch",
  )
  assert peer.on(a, fn() { peer_status(peer.node(b)) }) == "rejected"
  assert peer.on(b, fn() { peer_status(peer.node(a)) }) == "rejected"
  assert members(a) == []
  assert members(b) == []
  assert peer.on(a, nodes) == [peer.node(b)]
  assert peer.on(b, nodes) == [peer.node(a)]
  assert count_events(a, "brazier.cluster.node.down", name(b)) == 0
  assert count_events(b, "brazier.cluster.node.down", name(a)) == 0
}

/// A peer check timer of an earlier connection of a node (here it fired
/// while the node went down and came back, before the manager handled the
/// nodedown) does not reject the new connection, which has its own check.
pub fn stale_peer_check_timer_is_ignored_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_cl_stale")
  let assert [a, b] = peers as "with_cluster(2) starts two peers"
  let node_b = peer.node(b)
  record_cluster_events([a, b])
  // b's manager answers nothing until resumed, so a's check stays pending.
  start_on(b, cluster.new(cluster.NoDiscovery))
  peer.on(b, manager_suspend)
  start_on(
    a,
    cluster.new(cluster.NoDiscovery) |> cluster.peer_check_timeout(60_000),
  )
  let assert Ok(first) = peer.on(a, fn() { pending_check(node_b) })
    as "init checks the already-connected b"

  // nodedown, nodeup, then the first connection's timer, queued in order.
  peer.on(a, manager_suspend)
  peer.on(a, fn() { reconnect(node_b) })
  assert peer.eventually(
    fn() { peer.on(a, fn() { nodeup_queued(node_b) }) },
    wait_ms,
  )
  peer.on(a, fn() { send_check_timeout(first, node_b) })
  let #(Nil, lines) =
    peer.on(a, fn() {
      log_capture.capture(fn() {
        manager_resume()
        manager_barrier()
      })
    })
  assert log_capture.contains(
    lines,
    "debug",
    "Ignoring a stale peer check timer",
  )
  assert peer.on(a, nodes) == [node_b]
  let assert Ok(second) = peer.on(a, fn() { pending_check(node_b) })
    as "the new connection is checked"
  assert second != first

  peer.on(b, manager_resume)
  assert peer.eventually(fn() { members(a) == [node_b] }, wait_ms)
  assert peer.eventually(fn() { members(b) == [peer.node(a)] }, wait_ms)
  assert count_events(a, "brazier.cluster.peer.rejected", name(b)) == 0
  assert count_events(b, "brazier.cluster.peer.rejected", name(a)) == 0
}

/// A connected node that never answers the peer check (it runs no
/// cluster manager) is rejected when the check times out, and stays
/// connected. Once its manager starts with the right key, its hello makes
/// it a member on the same connection.
pub fn silent_peer_is_rejected_and_can_pass_later_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_cl_silent")
  let assert [a, b] = peers as "the cluster starts two peers"
  record_cluster_events([a])
  start_on(
    a,
    cluster.new(cluster.NoDiscovery)
      |> cluster.peer_check_timeout(100),
  )
  assert peer.eventually(
    fn() {
      has_event(a, "brazier.cluster.peer.rejected", name(b), "no hello within")
    },
    wait_ms,
  )
  assert peer.on(a, fn() { peer_status(peer.node(b)) }) == "rejected"
  assert members(a) == []
  assert peer.on(a, nodes) == [peer.node(b)]

  start_on(b, cluster.new(cluster.NoDiscovery))
  let assert Ok(Nil) = peer.await_member(a, peer.node(b), wait_ms)
    as "b's manager sends a hello with the shared key"
  assert peer.on(a, fn() { peer_status(peer.node(b)) }) == "verified"
  assert count_events(a, "brazier.cluster.node.down", name(b)) == 0
  // One rejection only: a verified node is not checked by a timer again.
  assert count_events(a, "brazier.cluster.peer.rejected", name(b)) == 1
}

// --- Keeping the MAC secret ---

/// The MAC (an HMAC of the secret key) is redacted from the manager's
/// status, which `sys:get_status` and gen_server crash reports print.
pub fn status_redacts_the_mac_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_cl_redact")
  let assert [a] = peers as "with_cluster(1) starts one peer"
  start_on(a, cluster.new(cluster.NoDiscovery))
  let mac = cluster.peer_mac(secret)
  // Control: the state holds it, so the search can find it.
  assert peer.on(a, fn() { state_holds(mac) })
  assert !peer.on(a, fn() { status_holds(mac) })
}

/// Malformed hellos and acks, and a hello naming a node that is not
/// connected, are dropped with a warning that does not print the MAC
/// they carry.
pub fn dropped_hellos_are_logged_without_the_mac_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_cl_hello_log")
  let assert [a] = peers as "with_cluster(1) starts one peer"
  start_on(a, cluster.new(cluster.NoDiscovery))
  let #(Nil, lines) =
    peer.on(a, fn() {
      log_capture.capture(fn() { send_marked_hellos("MAC-MARKER-5e1f0c") })
    })
  assert log_capture.contains(
    lines,
    "warning",
    "Dropping a malformed brazier_cluster_hello (3 elements)",
  )
  assert log_capture.contains(
    lines,
    "warning",
    "Dropping a malformed brazier_cluster_hello (5 elements)",
  )
  assert log_capture.contains(
    lines,
    "warning",
    "Dropping a malformed brazier_cluster_hello_ack (4 elements)",
  )
  assert log_capture.contains(
    lines,
    "warning",
    "naming brazier_nobody@nowhere, which is not connected",
  )
  assert !list.any(lines, fn(line) {
    string.contains(line.message, "MAC-MARKER")
  })
  assert members(a) == []
}

// --- Lifecycle and production checks ---

/// start, a second start, stop, and queries on a stopped manager.
pub fn lifecycle_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_cl_life")
  let assert [a] = peers as "the cluster starts one peer"
  let config = cluster.new(cluster.NoDiscovery)
  assert peer.on(a, fn() { cluster.start(config, secret_key: secret) })
    == Ok(Nil)
  assert peer.on(a, fn() { cluster.start(config, secret_key: secret) })
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
  use peers <- peer.with_cluster(1, "brazier_cl_prod")
  let assert [a] = peers as "the cluster starts one peer"
  peer.on(a, fn() { putenv("BRAZIER_ENV", "prod") })
  let config = cluster.new(cluster.NoDiscovery)
  let assert Error(cluster.InsecureDistribution(reason)) =
    peer.on(a, fn() { cluster.start(config, secret_key: secret) })
    as "cluster.start returns Error(InsecureDistribution)"
  assert string.contains(reason, "inet_tcp")
  // The harness cookie is long enough; only the carrier is refused.
  assert !string.contains(reason, "cookie")
  assert peer.on(a, cluster.members) == Error(cluster.NotStarted)

  let allowed =
    cluster.allow_insecure_distribution(config, "test network, no TLS")
  assert peer.on(a, fn() { cluster.start(allowed, secret_key: secret) })
    == Ok(Nil)
}

/// BRAZIER_ENV set under its pre-rename name refuses the cluster start, so
/// a production node is never started under dev rules.
pub fn renamed_environment_variable_refuses_the_cluster_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_cl_renamed_env")
  let assert [a] = peers as "the cluster starts one peer"
  peer.on(a, fn() { putenv("BEACON_ENV", "prod") })
  let config = cluster.new(cluster.NoDiscovery)
  let assert Error(cluster.InvalidConfig(reason)) =
    peer.on(a, fn() { cluster.start(config, secret_key: secret) })
    as "cluster.start returns Error(InvalidConfig)"
  assert string.contains(reason, "BEACON_ENV (now BRAZIER_ENV)")
  assert peer.on(a, cluster.members) == Error(cluster.NotStarted)
}

/// Under a supervisor, a crashed manager is restarted and re-checks the
/// peers that are still connected.
pub fn supervised_manager_restarts_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(2, "brazier_cl_sup")
  let assert [a, b] = peers as "the cluster starts two peers"
  start_on(b, cluster.new(cluster.NoDiscovery))
  let config = cluster.new(cluster.NoDiscovery)
  peer.on(a, fn() { start_supervised(config) })
  assert peer.eventually(fn() { members(a) == [peer.node(b)] }, wait_ms)

  let assert Ok(first) = peer.on(a, fn() { registered("brazier_cluster") })
    as "registered succeeds"
  peer.on(a, fn() { kill(first) })
  assert peer.eventually(
    fn() {
      case peer.on(a, fn() { registered("brazier_cluster") }) {
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
  start_with(p, config, secret)
}

fn start_with(p: Peer, config: cluster.ClusterConfig, key: String) -> Nil {
  let outcome = peer.on(p, fn() { cluster.start(config, secret_key: key) })
  assert outcome == Ok(Nil)
}

/// Start a supervisor that owns the manager, in a process that outlives
/// the rpc call.
fn start_supervised(config: cluster.ClusterConfig) -> Nil {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(child) = cluster.supervised(config, secret_key: secret)
      as "cluster.supervised succeeds"
    let assert Ok(_) =
      supervisor.new(supervisor.OneForOne)
      |> supervisor.add(child)
      |> supervisor.start
      as "supervisor.new succeeds"
    process.send(ready, Nil)
    process.sleep_forever()
  })
  let assert Ok(Nil) = process.receive(ready, 5000)
    as "process.receive succeeds"
  Nil
}

fn members(p: Peer) -> List(Node) {
  let assert Ok(members) = peer.on(p, cluster.members)
    as "cluster.members succeeds"
  members
}

/// `from` sends `to`'s manager a hello with the MAC of `key`, and returns
/// once it has been handled.
fn hello(from from: Peer, to to: Peer, key key: String) -> Nil {
  let to_node = peer.node(to)
  let mac = cluster.peer_mac(key)
  peer.on(from, fn() { send_hello(to_node, mac) })
}

fn record_cluster_events(peers: List(Peer)) -> Nil {
  list.each(peers, fn(p) {
    peer.on(p, fn() {
      record_events([
        ["brazier", "cluster", "node", "up"],
        ["brazier", "cluster", "node", "down"],
        ["brazier", "cluster", "peer", "rejected"],
        ["brazier", "cluster", "connect", "failed"],
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
    as "string.split_once succeeds"
  parts
}

fn hang() -> Result(List(String), String) {
  process.sleep_forever()
  Error("unreachable")
}

@external(erlang, "erlang", "nodes")
fn nodes() -> List(Node)

@external(erlang, "brazier_cluster_test_ffi", "record_events")
fn record_events(names: List(List(String))) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "recorded_events")
fn recorded_events() -> List(Event)

@external(erlang, "brazier_cluster_test_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "registered")
fn registered(name: String) -> Result(Pid, Nil)

@external(erlang, "brazier_cluster_test_ffi", "kill")
fn kill(pid: Pid) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "fail")
fn fail(reason: String) -> Result(List(String), String)

@external(erlang, "brazier_cluster_test_ffi", "atom_exists")
fn atom_exists(name: String) -> Bool

@external(erlang, "brazier_cluster_test_ffi", "state_holds")
fn state_holds(needle: BitArray) -> Bool

@external(erlang, "brazier_cluster_test_ffi", "status_holds")
fn status_holds(needle: BitArray) -> Bool

@external(erlang, "brazier_cluster_test_ffi", "send_marked_hellos")
fn send_marked_hellos(marker: String) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "manager_suspend")
fn manager_suspend() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "manager_resume")
fn manager_resume() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "manager_barrier")
fn manager_barrier() -> Nil

@external(erlang, "brazier_cluster_test_ffi", "pending_check")
fn pending_check(node: Node) -> Result(Reference, Nil)

@external(erlang, "brazier_cluster_test_ffi", "nodeup_queued")
fn nodeup_queued(node: Node) -> Bool

@external(erlang, "brazier_cluster_test_ffi", "send_check_timeout")
fn send_check_timeout(timer: Reference, node: Node) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "reconnect")
fn reconnect(node: Node) -> Nil

@external(erlang, "brazier_cluster_test_ffi", "peer_status")
fn peer_status(node: Node) -> String

@external(erlang, "brazier_cluster_test_ffi", "send_hello")
fn send_hello(node: Node, mac: BitArray) -> Nil
