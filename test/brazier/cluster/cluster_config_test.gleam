//// Pure checks of the cluster config, the distribution check, the
//// backoff window and the peer MAC. These run in the test runner, which
//// is not distributed, so starting the manager here must fail.

import brazier/cluster.{
  type ClusterError, type TlsVerify, AlreadyStarted, Distribution,
  DistributionNotStarted, Dns, InsecureDistribution, InvalidConfig, NoDiscovery,
  NotStarted, Static, TlsVerify,
}
import brazier/cluster/log_capture
import gleam/int
import gleam/option.{None, Some}
import gleam/string

const secret = "cluster-config-secret-0123456789-abcdefghijklmnopqrstuvwxyz"

fn invalid_reason(result: Result(a, ClusterError)) -> String {
  let assert Error(InvalidConfig(reason)) = result
    as "result returns Error(InvalidConfig)"
  reason
}

fn validate(c: cluster.ClusterConfig) -> Result(Nil, ClusterError) {
  case cluster.validate(c) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

// --- validate ---

pub fn defaults_are_valid_test() {
  assert validate(cluster.new(NoDiscovery)) == Ok(Nil)
  assert validate(cluster.new(Static(["a@host"]))) == Ok(Nil)
  assert validate(cluster.new(Dns("app.internal", "app", 5000))) == Ok(Nil)
}

pub fn short_secret_is_rejected_test() {
  let reason = invalid_reason(cluster.validate_secret_key("short"))
  // The key itself never appears in the error.
  assert !string.contains(reason, "short")
  assert cluster.validate_secret_key(secret) == Ok(Nil)
}

pub fn start_checks_the_secret_before_distribution_test() {
  // The test runner is not distributed: a weak key is reported first.
  let assert Error(InvalidConfig(reason)) =
    cluster.start(cluster.new(NoDiscovery), secret_key: "short")
    as "cluster.start returns Error(InvalidConfig)"
  assert !string.contains(reason, "short")
  let assert Error(InvalidConfig(_)) =
    cluster.supervised(cluster.new(NoDiscovery), secret_key: "")
    as "cluster.supervised returns Error(InvalidConfig)"
}

pub fn static_needs_nodes_test() {
  let reason = invalid_reason(validate(cluster.new(Static([]))))
  assert string.contains(reason, "Static node count")
}

pub fn static_node_count_is_bounded_test() {
  let nodes =
    int.range(from: 1, to: 1026, with: [], run: fn(acc, i) {
      ["n" <> int.to_string(i) <> "@h", ..acc]
    })
  let reason = invalid_reason(validate(cluster.new(Static(nodes))))
  assert string.contains(reason, "Static node count")
}

pub fn static_duplicates_are_rejected_test() {
  let reason = invalid_reason(validate(cluster.new(Static(["a@h", "a@h"]))))
  assert string.contains(reason, "more than once")
}

pub fn node_names_are_checked_test() {
  assert cluster.validate_node_name("a@h") == Ok(Nil)
  let assert Error(InvalidConfig(_)) = cluster.validate_node_name("nohost")
    as "cluster.validate_node_name returns Error(InvalidConfig)"
  let assert Error(InvalidConfig(_)) = cluster.validate_node_name("@h")
    as "cluster.validate_node_name returns Error(InvalidConfig)"
  let assert Error(InvalidConfig(_)) = cluster.validate_node_name("a@")
    as "cluster.validate_node_name returns Error(InvalidConfig)"
  let assert Error(InvalidConfig(_)) = cluster.validate_node_name("a@b@c")
    as "cluster.validate_node_name returns Error(InvalidConfig)"
  let long = string.repeat("x", 250) <> "@hosts"
  let reason = invalid_reason(cluster.validate_node_name(long))
  assert string.contains(reason, "255")
}

pub fn dns_fields_are_checked_test() {
  let reason = invalid_reason(validate(cluster.new(Dns("", "app", 1000))))
  assert string.contains(reason, "query is empty")
  let reason = invalid_reason(validate(cluster.new(Dns("q", "", 1000))))
  assert string.contains(reason, "basename is empty")
  let reason = invalid_reason(validate(cluster.new(Dns("q", "app@h", 1000))))
  assert string.contains(reason, "must not contain @")
  let reason = invalid_reason(validate(cluster.new(Dns("q", "app", 9))))
  assert string.contains(reason, "poll_ms")
  let reason = invalid_reason(validate(cluster.new(Dns("q", "app", 3_600_001))))
  assert string.contains(reason, "poll_ms")
}

pub fn backoff_bounds_are_checked_test() {
  let base = cluster.new(NoDiscovery)
  let reason =
    invalid_reason(
      validate(cluster.connect_backoff(base, initial_ms: 1, max_ms: 0)),
    )
  assert string.contains(reason, "max_ms")
  let reason =
    invalid_reason(
      validate(cluster.connect_backoff(base, initial_ms: 0, max_ms: 10)),
    )
  assert string.contains(reason, "initial_ms")
  // initial above max
  let reason =
    invalid_reason(
      validate(cluster.connect_backoff(base, initial_ms: 11, max_ms: 10)),
    )
  assert string.contains(reason, "initial_ms")
  assert validate(cluster.connect_backoff(base, initial_ms: 10, max_ms: 10))
    == Ok(Nil)
}

pub fn timeouts_and_limits_are_checked_test() {
  let base = cluster.new(NoDiscovery)
  let reason = invalid_reason(validate(cluster.peer_check_timeout(base, 9)))
  assert string.contains(reason, "peer_check_timeout")
  let reason =
    invalid_reason(validate(cluster.peer_check_timeout(base, 60_001)))
  assert string.contains(reason, "peer_check_timeout")
  let reason = invalid_reason(validate(cluster.dns_timeout(base, 9)))
  assert string.contains(reason, "dns_timeout")
  let reason = invalid_reason(validate(cluster.max_dns_nodes(base, 0)))
  assert string.contains(reason, "max_dns_nodes")
  let reason = invalid_reason(validate(cluster.max_dns_nodes(base, 4097)))
  assert string.contains(reason, "max_dns_nodes")
  let reason = invalid_reason(validate(cluster.max_discovered_nodes(base, 0)))
  assert string.contains(reason, "max_discovered_nodes")
  let reason =
    invalid_reason(validate(cluster.max_discovered_nodes(base, 1_000_001)))
  assert string.contains(reason, "max_discovered_nodes")
  assert validate(cluster.max_discovered_nodes(base, 1)) == Ok(Nil)
}

pub fn dns_basename_length_is_bounded_test() {
  // basename@<64-byte address> must stay within the 255-byte node name.
  let long = string.repeat("b", 191)
  let reason = invalid_reason(validate(cluster.new(Dns("q", long, 1000))))
  assert string.contains(reason, "basename length")
  let longest = string.repeat("b", 190)
  assert validate(cluster.new(Dns("q", longest, 1000))) == Ok(Nil)
}

pub fn insecure_override_needs_a_reason_test() {
  let base = cluster.new(NoDiscovery)
  let reason =
    invalid_reason(validate(cluster.allow_insecure_distribution(base, "")))
  assert string.contains(reason, "needs a reason")
  assert validate(cluster.allow_insecure_distribution(base, "private network"))
    == Ok(Nil)
}

// --- backoff_window ---

pub fn backoff_window_doubles_from_initial_test() {
  assert cluster.backoff_window(0, 1000, 30_000)
    == cluster.BackoffWindow(low_ms: 500, high_ms: 1000)
  assert cluster.backoff_window(1, 1000, 30_000)
    == cluster.BackoffWindow(low_ms: 1000, high_ms: 2000)
  assert cluster.backoff_window(4, 1000, 30_000)
    == cluster.BackoffWindow(low_ms: 8000, high_ms: 16_000)
}

pub fn backoff_window_caps_at_max_test() {
  assert cluster.backoff_window(5, 1000, 30_000)
    == cluster.BackoffWindow(low_ms: 15_000, high_ms: 30_000)
  // Large attempt counts do not overflow past the cap.
  assert cluster.backoff_window(1_000_000, 1000, 30_000)
    == cluster.BackoffWindow(low_ms: 15_000, high_ms: 30_000)
  assert cluster.backoff_window(0, 7, 7)
    == cluster.BackoffWindow(low_ms: 3, high_ms: 7)
}

// --- check_distribution ---

const verified =
  TlsVerify(
    server_verify_peer: True,
    server_fail_if_no_peer_cert: True,
    client_verify_peer: True,
  )

const tls =
  Distribution(
    alive: True,
    proto_dist: "inet_tls",
    cookie_bytes: 44,
    tls_verify: Ok(verified),
  )

pub fn distribution_must_be_alive_test() {
  let dead = Distribution(..tls, alive: False)
  assert cluster.check_distribution(dead, False, None)
    == Error(DistributionNotStarted)
  assert cluster.check_distribution(dead, True, Some("override"))
    == Error(DistributionNotStarted)
}

pub fn secure_distribution_is_accepted_test() {
  assert cluster.check_distribution(tls, True, None) == Ok(Nil)
  let tls6 = Distribution(..tls, proto_dist: "inet6_tls")
  assert cluster.check_distribution(tls6, True, None) == Ok(Nil)
  let exact = Distribution(..tls, cookie_bytes: cluster.min_cookie_bytes)
  assert cluster.check_distribution(exact, True, None) == Ok(Nil)
}

pub fn production_refuses_plain_tcp_test() {
  let plain = Distribution(..tls, proto_dist: "inet_tcp")
  let assert Error(InsecureDistribution(reason)) =
    cluster.check_distribution(plain, True, None)
    as "cluster.check_distribution returns Error(InsecureDistribution)"
  assert string.contains(reason, "inet_tcp")
}

pub fn production_refuses_short_cookie_test() {
  let short = Distribution(..tls, cookie_bytes: cluster.min_cookie_bytes - 1)
  let assert Error(InsecureDistribution(reason)) =
    cluster.check_distribution(short, True, None)
    as "cluster.check_distribution returns Error(InsecureDistribution)"
  assert string.contains(reason, "31 bytes")
}

pub fn production_reports_every_problem_test() {
  let both = Distribution(..tls, proto_dist: "inet_tcp", cookie_bytes: 8)
  let assert Error(InsecureDistribution(reason)) =
    cluster.check_distribution(both, True, None)
    as "cluster.check_distribution returns Error(InsecureDistribution)"
  assert string.contains(reason, "inet_tcp")
  assert string.contains(reason, "8 bytes")
}

pub fn production_refuses_tls_without_peer_verification_test() {
  let none =
    Distribution(
      ..tls,
      tls_verify: Ok(TlsVerify(
        server_verify_peer: False,
        server_fail_if_no_peer_cert: False,
        client_verify_peer: False,
      )),
    )
  let assert Error(InsecureDistribution(reason)) =
    cluster.check_distribution(none, True, None)
    as "cluster.check_distribution returns Error(InsecureDistribution)"
  // Each missing option is named, with where to set it.
  assert string.contains(reason, "server_verify verify_peer")
  assert string.contains(reason, "server_fail_if_no_peer_cert true")
  assert string.contains(reason, "client_verify verify_peer")
  assert string.contains(reason, "ssl_dist_optfile")
}

pub fn production_names_only_the_missing_tls_option_test() {
  let no_fail =
    Distribution(
      ..tls,
      tls_verify: Ok(TlsVerify(..verified, server_fail_if_no_peer_cert: False)),
    )
  let assert Error(InsecureDistribution(reason)) =
    cluster.check_distribution(no_fail, True, None)
    as "cluster.check_distribution returns Error(InsecureDistribution)"
  assert string.contains(reason, "fail_if_no_peer_cert")
  assert !string.contains(reason, "server_verify")
  assert !string.contains(reason, "client_verify")
  let no_client =
    Distribution(
      ..tls,
      tls_verify: Ok(TlsVerify(..verified, client_verify_peer: False)),
    )
  let assert Error(InsecureDistribution(reason)) =
    cluster.check_distribution(no_client, True, None)
    as "cluster.check_distribution returns Error(InsecureDistribution)"
  assert string.contains(reason, "client_verify verify_peer")
  assert !string.contains(reason, "server_verify")
  let no_server =
    Distribution(
      ..tls,
      tls_verify: Ok(TlsVerify(..verified, server_verify_peer: False)),
    )
  let assert Error(InsecureDistribution(reason)) =
    cluster.check_distribution(no_server, True, None)
    as "cluster.check_distribution returns Error(InsecureDistribution)"
  assert string.contains(reason, "server_verify verify_peer")
  assert !string.contains(reason, "client_verify")
}

pub fn production_refuses_an_unreadable_tls_optfile_test() {
  let unreadable =
    Distribution(
      ..tls,
      tls_verify: Error("{ssl_dist_optfile_unreadable,enoent}"),
    )
  let assert Error(InsecureDistribution(reason)) =
    cluster.check_distribution(unreadable, True, None)
    as "cluster.check_distribution returns Error(InsecureDistribution)"
  assert string.contains(reason, "cannot be read")
  assert string.contains(reason, "enoent")
}

pub fn plain_tcp_skips_the_tls_verification_check_test() {
  // The TLS options do not apply without TLS: only the transport is named.
  let plain =
    Distribution(..tls, proto_dist: "inet_tcp", tls_verify: Error("unused"))
  let assert Error(InsecureDistribution(reason)) =
    cluster.check_distribution(plain, True, None)
    as "cluster.check_distribution returns Error(InsecureDistribution)"
  assert !string.contains(reason, "unused")
}

pub fn development_allows_tls_without_peer_verification_test() {
  let none =
    Distribution(
      ..tls,
      tls_verify: Ok(TlsVerify(
        server_verify_peer: False,
        server_fail_if_no_peer_cert: False,
        client_verify_peer: False,
      )),
    )
  let #(outcome, lines) =
    log_capture.capture(fn() { cluster.check_distribution(none, False, None) })
  assert outcome == Ok(Nil)
  assert log_capture.contains(lines, "info", "does not verify clients")
}

// --- reading the TLS distribution options ---

pub fn tls_options_from_ssl_dist_opt_test() {
  assert tls_verify(
      no_argument(),
      option_groups([
        ["server_verify", "verify_peer", "server_fail_if_no_peer_cert", "true"],
        ["client_verify", "verify_peer"],
      ]),
    )
    == Ok(verified)
  assert tls_verify(
      no_argument(),
      option_groups([["server_verify", "verify_none", "client_verify"]]),
    )
    == Ok(TlsVerify(
      server_verify_peer: False,
      server_fail_if_no_peer_cert: False,
      client_verify_peer: False,
    ))
  // No options at all: OTP's defaults verify nothing.
  assert tls_verify(no_argument(), no_argument())
    == Ok(TlsVerify(
      server_verify_peer: False,
      server_fail_if_no_peer_cert: False,
      client_verify_peer: False,
    ))
}

pub fn tls_options_from_an_optfile_test() {
  let path =
    write_optfile(
      "[{server, [{verify, verify_peer}, {fail_if_no_peer_cert, true}]},
      {client, [{verify, verify_peer}]}].",
    )
  // The option file wins over -ssl_dist_opt, as in inet_tls_dist.
  assert tls_verify(
      option_groups([[path]]),
      option_groups([["server_verify", "verify_none"]]),
    )
    == Ok(verified)
  let path = write_optfile("[{server, [{verify, verify_peer}]}].")
  assert tls_verify(option_groups([[path]]), no_argument())
    == Ok(
      TlsVerify(
        ..verified,
        server_fail_if_no_peer_cert: False,
        client_verify_peer: False,
      ),
    )
}

pub fn an_unreadable_optfile_is_an_error_test() {
  let assert Error(reason) =
    tls_verify(
      option_groups([["/nonexistent/brazier/ssl_dist.conf"]]),
      no_argument(),
    )
    as "tls_verify returns Error"
  assert string.contains(reason, "ssl_dist_optfile_unreadable")
  let path = write_optfile("[{server, []}]. [{client, []}].")
  let assert Error(reason) = tls_verify(option_groups([[path]]), no_argument())
    as "tls_verify returns Error"
  assert string.contains(reason, "ssl_dist_optfile_not_one_list")
}

type Argument

@external(erlang, "brazier_cluster_ffi", "tls_verify")
fn tls_verify(optfile: Argument, opts: Argument) -> Result(TlsVerify, String)

@external(erlang, "brazier_cluster_test_ffi", "no_argument")
fn no_argument() -> Argument

@external(erlang, "brazier_cluster_test_ffi", "option_groups")
fn option_groups(groups: List(List(String))) -> Argument

@external(erlang, "brazier_cluster_test_ffi", "write_optfile")
fn write_optfile(contents: String) -> String

pub fn production_override_logs_a_warning_test() {
  let plain = Distribution(..tls, proto_dist: "inet_tcp")
  let #(outcome, lines) =
    log_capture.capture(fn() {
      cluster.check_distribution(plain, True, Some("isolated test network"))
    })
  assert outcome == Ok(Nil)
  assert log_capture.contains(lines, "warning", "isolated test network")
}

pub fn development_allows_plain_tcp_test() {
  let plain = Distribution(..tls, proto_dist: "inet_tcp", cookie_bytes: 6)
  let #(outcome, lines) =
    log_capture.capture(fn() { cluster.check_distribution(plain, False, None) })
  assert outcome == Ok(Nil)
  assert log_capture.contains(lines, "info", "insecure distribution allowed")
}

// --- peer_mac ---

pub fn peer_mac_is_deterministic_and_keyed_test() {
  let mac = cluster.peer_mac(secret)
  assert mac == cluster.peer_mac(secret)
  assert mac != cluster.peer_mac(secret <> "x")
  // HMAC-SHA256
  assert bit_array_size(mac) == 32
}

@external(erlang, "erlang", "byte_size")
fn bit_array_size(b: BitArray) -> Int

// --- lifecycle in a non-distributed node ---

pub fn start_needs_distribution_test() {
  assert cluster.start(cluster.new(NoDiscovery), secret_key: secret)
    == Error(DistributionNotStarted)
  let assert Error(DistributionNotStarted) =
    cluster.supervised(cluster.new(NoDiscovery), secret_key: secret)
    as "cluster.supervised returns Error(DistributionNotStarted)"
}

pub fn invalid_config_is_reported_before_distribution_test() {
  let assert Error(InvalidConfig(_)) =
    cluster.start(cluster.new(Static([])), secret_key: secret)
    as "cluster.start returns Error(InvalidConfig)"
}

pub fn queries_without_a_manager_test() {
  assert cluster.members() == Error(NotStarted)
  assert cluster.stop() == Error(NotStarted)
}

pub fn errors_are_described_test() {
  assert string.contains(cluster.describe(AlreadyStarted), "already running")
  assert string.contains(cluster.describe(NotStarted), "not running")
  assert string.contains(cluster.describe(InvalidConfig("x")), "x")
}
