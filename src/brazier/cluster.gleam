//// Cluster formation: node discovery, reconnection and the peer check.
////
//// Brazier never turns distribution on itself: start the node with a name
//// (`--name` / `-sname`), a cookie and, in production, TLS distribution
//// (see docs/CLUSTERING.md). `start` then runs the cluster manager, which:
////
//// - discovers peers with `Static` (a fixed list, retried with exponential
////   backoff and jitter) or `Dns` (A/AAAA lookups every `poll_ms`), or
////   only watches connections with `NoDiscovery`;
//// - logs node up/down and emits `[brazier, cluster, node, up | down]` and
////   `[brazier, cluster, connect, failed]`;
//// - checks every connected peer: nodes exchange
////   HMAC-SHA256(secret_key, "brazier-cluster-v1") and a protocol version.
////   A peer whose key differs, or that does not answer within
////   `peer_check_timeout`, is disconnected and reported with
////   `[brazier, cluster, peer, rejected]`. This catches two deployments
////   sharing a cookie by mistake; it is not a defence against a node that
////   holds the cookie, which can run any code here.
////
//// In production (`BRAZIER_ENV=prod`) `start` refuses plain TCP
//// distribution and cookies shorter than 32 bytes unless the config carries
//// `allow_insecure_distribution(reason)`.
////
//// Discovery follows libcluster's Epmd and DNSPoll strategies.

import brazier/config
import brazier/error
import brazier/log
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/set
import gleam/string

/// How the cluster manager finds peers.
pub type Discovery {
  /// Connect to each `name@host` node, retrying failed and lost connections
  /// with backoff (`connect_backoff`). This node may appear in the list.
  Static(nodes: List(String))
  /// Every `poll_ms`, resolve `query` (A and AAAA records) and connect to
  /// `basename@<address>` for each address not yet connected. Nodes that
  /// leave the DNS answer are not disconnected: a node that is up stays
  /// connected until distribution reports it down.
  Dns(query: String, basename: String, poll_ms: Int)
  /// Connect to nothing; only report and check nodes that connect.
  NoDiscovery
}

pub type ClusterError {
  /// This node runs without distribution (no `--name` / `-sname`).
  DistributionNotStarted
  /// Production refuses this distribution setup; see the reason.
  InsecureDistribution(reason: String)
  InvalidConfig(reason: String)
  /// The cluster manager is not running on this node.
  NotStarted
  /// The cluster manager is already running on this node.
  AlreadyStarted
  StartFailed(reason: String)
  StopFailed(reason: String)
}

/// Resolve a DNS name to address strings (`"10.0.0.7"`, `"fd00::7"`).
pub type Resolver =
  fn(String) -> Result(List(String), String)

pub opaque type ClusterConfig {
  ClusterConfig(
    discovery: Discovery,
    secret_key: String,
    initial_ms: Int,
    max_ms: Int,
    check_timeout_ms: Int,
    resolver: Resolver,
    resolve_timeout_ms: Int,
    max_dns_nodes: Int,
    insecure_reason: Option(String),
  )
}

/// What the manager receives (the FFI turns it into a map).
type ManagerConfig {
  ManagerConfig(
    discovery: Discovery,
    mac: BitArray,
    check_timeout_ms: Int,
    initial_ms: Int,
    max_ms: Int,
    resolver: Resolver,
    resolve_timeout_ms: Int,
    max_dns_nodes: Int,
  )
}

/// Facts about this node's distribution, read by `start`.
@internal
pub type Distribution {
  Distribution(alive: Bool, proto_dist: String, cookie_bytes: Int)
}

/// The delay window for a static reconnect after `attempt` failures.
@internal
pub type BackoffWindow {
  BackoffWindow(low_ms: Int, high_ms: Int)
}

const module_name = "brazier.cluster"

/// The peer check's message: both sides MAC it with their secret key.
const mac_message = "brazier-cluster-v1"

const max_static_nodes = 1024

const max_node_name_bytes = 255

const max_wait_ms = 3_600_000

/// Production cookies must be at least this long (a 32-byte random cookie
/// is not guessable; short ones like "secret" are).
pub const min_cookie_bytes = 32

/// A cluster config with `discovery`. `secret_key` is the application's
/// secret key (the one that signs session tokens): every node of one
/// deployment must use the same one, and the peer check rejects nodes that
/// do not.
///
/// Defaults: reconnect backoff 1s doubling to 30s, peer check timeout 5s,
/// the system DNS resolver with a 10s timeout, and at most 256 nodes per
/// DNS answer.
pub fn new(
  discovery: Discovery,
  secret_key secret_key: String,
) -> ClusterConfig {
  ClusterConfig(
    discovery: discovery,
    secret_key: secret_key,
    initial_ms: 1000,
    max_ms: 30_000,
    check_timeout_ms: 5000,
    resolver: resolve_dns,
    resolve_timeout_ms: 10_000,
    max_dns_nodes: 256,
    insecure_reason: None,
  )
}

/// Retry a lost or failed static connection after a delay that starts at
/// `initial_ms` and doubles to `max_ms`, taken uniformly from the upper
/// half of the current delay so restarted nodes do not retry in lockstep.
pub fn connect_backoff(
  c: ClusterConfig,
  initial_ms initial_ms: Int,
  max_ms max_ms: Int,
) -> ClusterConfig {
  ClusterConfig(..c, initial_ms: initial_ms, max_ms: max_ms)
}

/// Start in production without TLS distribution or with a short cookie.
/// The reason is logged as a warning on every start. Only for networks
/// where every host that can reach the distribution ports is trusted.
pub fn allow_insecure_distribution(
  c: ClusterConfig,
  reason: String,
) -> ClusterConfig {
  ClusterConfig(..c, insecure_reason: Some(reason))
}

/// Resolve `Dns` queries with `resolve` instead of the system resolver.
pub fn dns_resolver(c: ClusterConfig, resolve: Resolver) -> ClusterConfig {
  ClusterConfig(..c, resolver: resolve)
}

/// How long a DNS lookup may take before it counts as failed.
pub fn dns_timeout(c: ClusterConfig, timeout_ms: Int) -> ClusterConfig {
  ClusterConfig(..c, resolve_timeout_ms: timeout_ms)
}

/// The most addresses one DNS answer may hold. A larger answer is refused
/// as a whole (logged, `[brazier, cluster, connect, failed]`).
pub fn max_dns_nodes(c: ClusterConfig, max: Int) -> ClusterConfig {
  ClusterConfig(..c, max_dns_nodes: max)
}

/// How long a newly connected peer has to pass the peer check.
pub fn peer_check_timeout(c: ClusterConfig, timeout_ms: Int) -> ClusterConfig {
  ClusterConfig(..c, check_timeout_ms: timeout_ms)
}

/// Check the config and this node's distribution, then start the cluster
/// manager, not linked to the caller.
pub fn start(c: ClusterConfig) -> Result(Nil, ClusterError) {
  use manager <- result.try(prepare(c))
  case start_ffi(manager) {
    Ok(Nil) -> {
      log.info(module_name, "Cluster manager running on " <> self_name())
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// A child specification that starts the cluster manager under a
/// supervisor. The checks run when the specification is built.
pub fn supervised(
  c: ClusterConfig,
) -> Result(supervision.ChildSpecification(Nil), ClusterError) {
  use manager <- result.try(prepare(c))
  Ok(
    supervision.worker(fn() {
      case start_link_ffi(manager) {
        Ok(pid) -> Ok(actor.Started(pid: pid, data: Nil))
        Error(reason) -> Error(actor.InitFailed(describe(reason)))
      }
    }),
  )
}

/// Stop the cluster manager started with `start`. Connections stay up;
/// they are no longer reconnected or checked.
pub fn stop() -> Result(Nil, ClusterError) {
  stop_ffi()
}

/// The peers that passed the peer check and are connected.
pub fn members() -> Result(List(Node), ClusterError) {
  members_ffi()
}

pub fn describe(e: ClusterError) -> String {
  case e {
    DistributionNotStarted ->
      "Distribution is not started: run the node with --name or -sname"
    InsecureDistribution(reason) -> "Insecure distribution: " <> reason
    InvalidConfig(reason) -> "Invalid cluster config: " <> reason
    NotStarted -> "The cluster manager is not running"
    AlreadyStarted -> "The cluster manager is already running"
    StartFailed(reason) -> "The cluster manager failed to start: " <> reason
    StopFailed(reason) -> "The cluster manager failed to stop: " <> reason
  }
}

fn prepare(c: ClusterConfig) -> Result(ManagerConfig, ClusterError) {
  // BRAZIER_ENV decides whether production rules apply: a deployment that
  // still sets it under its pre-rename name must not start as dev.
  use Nil <- result.try(
    config.refuse_renamed_env(config.framework_env_vars)
    |> result.map_error(fn(e) { InvalidConfig(error.to_string(e)) }),
  )
  use c <- result.try(validate(c))
  use Nil <- result.try(check_distribution(
    distribution_ffi(),
    config.is_production(),
    c.insecure_reason,
  ))
  Ok(ManagerConfig(
    discovery: c.discovery,
    mac: peer_mac(c.secret_key),
    check_timeout_ms: c.check_timeout_ms,
    initial_ms: c.initial_ms,
    max_ms: c.max_ms,
    resolver: c.resolver,
    resolve_timeout_ms: c.resolve_timeout_ms,
    max_dns_nodes: c.max_dns_nodes,
  ))
}

/// The value both sides of the peer check send.
@internal
pub fn peer_mac(secret_key: String) -> BitArray {
  crypto.hmac(<<mac_message:utf8>>, crypto.Sha256, <<secret_key:utf8>>)
}

/// Refuse a distribution setup that production must not run with.
@internal
pub fn check_distribution(
  dist: Distribution,
  production: Bool,
  insecure_reason: Option(String),
) -> Result(Nil, ClusterError) {
  use <- bool.lazy_guard(when: !dist.alive, return: fn() {
    log.error(module_name, "Distribution is not started; refusing to start")
    Error(DistributionNotStarted)
  })
  let problems =
    list.flatten([
      case dist.proto_dist {
        "inet_tls" | "inet6_tls" -> []
        other -> [
          "distribution runs over "
          <> other
          <> " (unencrypted); use -proto_dist inet_tls",
        ]
      },
      case dist.cookie_bytes >= min_cookie_bytes {
        True -> []
        False -> [
          "the cookie is "
          <> int.to_string(dist.cookie_bytes)
          <> " bytes; use at least "
          <> int.to_string(min_cookie_bytes),
        ]
      },
    ])
  case production, problems, insecure_reason {
    _, [], _ -> Ok(Nil)
    False, _, _ -> {
      log.info(
        module_name,
        "Not production; insecure distribution allowed: "
          <> string.join(problems, "; "),
      )
      Ok(Nil)
    }
    True, _, Some(reason) -> {
      log.warning(
        module_name,
        "Starting with insecure distribution in production ("
          <> string.join(problems, "; ")
          <> "), allowed because: "
          <> reason,
      )
      Ok(Nil)
    }
    True, _, None -> {
      let reason = string.join(problems, "; ")
      log.error(module_name, "Refusing to start in production: " <> reason)
      Error(InsecureDistribution(reason))
    }
  }
}

@internal
pub fn validate(c: ClusterConfig) -> Result(ClusterConfig, ClusterError) {
  use _ <- result.try(
    config.validate_secret_key(c.secret_key)
    |> result.map_error(fn(e) { invalid(error.to_string(e)) }),
  )
  use Nil <- result.try(validate_discovery(c.discovery))
  use Nil <- result.try(in_range(
    "connect_backoff max_ms",
    c.max_ms,
    1,
    max_wait_ms,
  ))
  use Nil <- result.try(in_range(
    "connect_backoff initial_ms",
    c.initial_ms,
    1,
    c.max_ms,
  ))
  use Nil <- result.try(in_range(
    "peer_check_timeout",
    c.check_timeout_ms,
    10,
    60_000,
  ))
  use Nil <- result.try(in_range(
    "dns_timeout",
    c.resolve_timeout_ms,
    10,
    60_000,
  ))
  use Nil <- result.try(in_range("max_dns_nodes", c.max_dns_nodes, 1, 4096))
  case c.insecure_reason {
    Some("") -> Error(invalid("allow_insecure_distribution needs a reason"))
    Some(_) | None -> Ok(c)
  }
}

fn validate_discovery(d: Discovery) -> Result(Nil, ClusterError) {
  case d {
    NoDiscovery -> Ok(Nil)
    Static(nodes) -> {
      let count = list.length(nodes)
      use Nil <- result.try(in_range(
        "Static node count",
        count,
        1,
        max_static_nodes,
      ))
      use Nil <- result.try(
        list.try_each(nodes, validate_node_name) |> result.map(fn(_) { Nil }),
      )
      case set.size(set.from_list(nodes)) == count {
        True -> Ok(Nil)
        False -> Error(invalid("Static lists a node more than once"))
      }
    }
    Dns(query, basename, poll_ms) -> {
      use Nil <- result.try(case query {
        "" -> Error(invalid("Dns query is empty"))
        _ -> Ok(Nil)
      })
      use Nil <- result.try(case basename, string.contains(basename, "@") {
        "", _ -> Error(invalid("Dns basename is empty"))
        _, True -> Error(invalid("Dns basename must not contain @"))
        _, False -> Ok(Nil)
      })
      in_range("Dns poll_ms", poll_ms, 10, max_wait_ms)
    }
  }
}

/// A node name is `name@host`, both parts non-empty, at most 255 bytes.
@internal
pub fn validate_node_name(name: String) -> Result(Nil, ClusterError) {
  let size = bit_array.byte_size(<<name:utf8>>)
  case size > max_node_name_bytes, string.split(name, "@") {
    True, _ ->
      Error(invalid(
        "node name longer than "
        <> int.to_string(max_node_name_bytes)
        <> " bytes",
      ))
    False, [local, host] if local != "" && host != "" -> Ok(Nil)
    False, _ -> Error(invalid("node name " <> name <> " is not name@host"))
  }
}

fn in_range(
  what: String,
  value: Int,
  low: Int,
  high: Int,
) -> Result(Nil, ClusterError) {
  case value >= low && value <= high {
    True -> Ok(Nil)
    False ->
      Error(invalid(
        what
        <> " must be "
        <> int.to_string(low)
        <> ".."
        <> int.to_string(high)
        <> ", got "
        <> int.to_string(value),
      ))
  }
}

fn invalid(reason: String) -> ClusterError {
  log.error(module_name, "Invalid cluster config: " <> reason)
  InvalidConfig(reason)
}

fn self_name() -> String {
  node.self() |> node.name |> atom.to_string
}

/// The delay window (ms) for a static reconnect after `attempt` failures.
@internal
pub fn backoff_window(
  attempt: Int,
  initial_ms: Int,
  max_ms: Int,
) -> BackoffWindow {
  backoff_window_ffi(attempt, initial_ms, max_ms)
}

/// The system resolver: A and AAAA records of `query`. An error only when
/// both lookups fail.
pub fn resolve_dns(query: String) -> Result(List(String), String) {
  resolve_dns_ffi(query)
}

@external(erlang, "brazier_cluster_ffi", "start")
fn start_ffi(config: ManagerConfig) -> Result(Nil, ClusterError)

@external(erlang, "brazier_cluster_ffi", "start_link")
fn start_link_ffi(config: ManagerConfig) -> Result(Pid, ClusterError)

@external(erlang, "brazier_cluster_ffi", "stop")
fn stop_ffi() -> Result(Nil, ClusterError)

@external(erlang, "brazier_cluster_ffi", "members")
fn members_ffi() -> Result(List(Node), ClusterError)

@external(erlang, "brazier_cluster_ffi", "distribution")
fn distribution_ffi() -> Distribution

@external(erlang, "brazier_cluster_ffi", "resolve_dns")
fn resolve_dns_ffi(query: String) -> Result(List(String), String)

@external(erlang, "brazier_cluster_ffi", "backoff_window")
fn backoff_window_ffi(
  attempt: Int,
  initial_ms: Int,
  max_ms: Int,
) -> BackoffWindow
