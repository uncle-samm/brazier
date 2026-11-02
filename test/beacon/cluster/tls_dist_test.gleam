//// TLS distribution (`-proto_dist inet_tls`) with mutual certificate
//// checks, using the test CA in test/fixtures/dist_tls (regenerate with
//// its regenerate.sh). Nodes with a certificate from the cluster CA
//// connect; nodes with no certificate, a certificate from another CA, or
//// plain TCP distribution are refused in both directions. The cluster
//// manager starts in production mode over TLS.

import beacon/cluster
import beacon/cluster/peer.{Timeout}
import gleam/erlang/node.{type Node}
import gleam/list

const wait_ms = 10_000

const secret = "cluster-tls-secret-0123456789-abcdefghijklmnopqrstuvwxyz"

/// Two nodes with cluster-CA certificates connect over TLS, and the
/// cluster manager accepts that in production.
pub fn tls_nodes_connect_test_() -> peer.Timeout {
  use <- Timeout(90)
  use peers <- peer.with_cluster_args(2, "beacon_tls_ok", tls_args("node"))
  let assert [a, b] = peers
  assert peer.on(a, nodes) == [peer.node(b)]
  let b_node = peer.node(b)
  assert peer.on(a, fn() { dist_protocol(b_node) }) == Ok("tls")

  list.each(peers, fn(p) {
    peer.on(p, fn() { putenv("BEACON_ENV", "prod") })
    let outcome =
      peer.on(p, fn() {
        cluster.start(cluster.new(cluster.NoDiscovery, secret_key: secret))
      })
    assert outcome == Ok(Nil)
  })
  assert peer.eventually(
    fn() { peer.on(a, cluster.members) == Ok([peer.node(b)]) },
    wait_ms,
  )
}

/// A TLS node without a certificate, and a plain TCP node, cannot join a
/// TLS cluster.
pub fn node_without_certificate_is_refused_test_() -> peer.Timeout {
  use <- Timeout(90)
  use peers <- peer.with_cluster_args(1, "beacon_tls_nocert", tls_args("node"))
  let assert [a] = peers
  let no_cert = peer.add_peer_args(a, "beacon_tls_nocert_x", no_cert_args())
  let assert Error(_) = peer.connect(no_cert, a)
  let assert Error(_) = peer.connect(a, no_cert)

  let plain = peer.add_peer(a, "beacon_tls_plain")
  let assert Error(_) = peer.connect(plain, a)
  let assert Error(_) = peer.connect(a, plain)
  assert peer.on(a, nodes) == []
}

/// A node whose certificate comes from another CA is refused, even though
/// it trusts the cluster CA itself.
pub fn certificate_from_another_ca_is_refused_test_() -> peer.Timeout {
  use <- Timeout(90)
  use peers <- peer.with_cluster_args(1, "beacon_tls_rogue", tls_args("node"))
  let assert [a] = peers
  let rogue = peer.add_peer_args(a, "beacon_tls_rogue_x", tls_args("rogue"))
  let assert Error(_) = peer.connect(rogue, a)
  let assert Error(_) = peer.connect(a, rogue)
  assert peer.on(a, nodes) == []
  // Sanity check: a valid node still joins the same node.
  let good = peer.add_peer_args(a, "beacon_tls_rogue_ok", tls_args("node"))
  assert peer.connect(good, a) == Ok(Nil)
}

/// Mutual TLS through `-ssl_dist_optfile` (the form docs/CLUSTERING.md
/// recommends): present `<cert>.pem` ("none": no certificate), trust only
/// the cluster CA, require a peer certificate on both sides.
fn tls_args(cert: String) -> List(String) {
  ["-proto_dist", "inet_tls", "-ssl_dist_optfile", dist_optfile(cert)]
}

fn no_cert_args() -> List(String) {
  tls_args("none")
}

@external(erlang, "beacon_cluster_test_ffi", "dist_optfile")
fn dist_optfile(cert: String) -> String

@external(erlang, "erlang", "nodes")
fn nodes() -> List(Node)

@external(erlang, "beacon_cluster_test_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

@external(erlang, "beacon_cluster_test_ffi", "dist_protocol")
fn dist_protocol(node: Node) -> Result(String, Nil)
