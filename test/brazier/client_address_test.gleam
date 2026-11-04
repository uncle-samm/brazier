//// SEC-4: the client address comes from the one forwarding header the
//// operator configured, never from whichever header happens to be present.

import brazier/ip
import brazier/log_capture
import brazier/transport
import brazier/transport/client
import brazier/transport/server.{type Connection}
import gleam/http/request
import gleam/list
import gleam/string

/// The audit report's case: a proxy at 10.0.0.5 sets X-Forwarded-For, and
/// the client sent its own `Forwarded` header through it. Regression:
/// `Forwarded` took precedence, so the client chose 203.0.113.7.
pub fn x_forwarded_for_proxy_ignores_a_client_forwarded_header_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["10.0.0.0/8"], ip.XForwardedFor)
  let #(address, logs) =
    log_capture.capture(fn() {
      ip.client_address("10.0.0.5", report_headers(), trusted)
    })
  let assert "198.51.100.20" = address
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "Ignoring Forwarded", "for=203.0.113.7", "trusted proxy 10.0.0.5",
    ])
}

/// The mirror case: a proxy that sets `Forwarded` never reads a
/// client-supplied X-Forwarded-For.
pub fn forwarded_proxy_ignores_a_client_x_forwarded_for_header_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["10.0.0.0/8"], ip.Forwarded)
  let #(address, logs) =
    log_capture.capture(fn() {
      ip.client_address("10.0.0.5", report_headers(), trusted)
    })
  let assert "203.0.113.7" = address
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "Ignoring X-Forwarded-For", "198.51.100.20", "trusted proxy 10.0.0.5",
    ])
}

/// Proxies listed with no header (for the per-IP cap exemption) are the
/// client: neither header is read, and that is not a warning.
pub fn no_forwarding_header_reads_neither_header_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["10.0.0.0/8"], ip.NoForwardingHeader)
  let #(address, logs) =
    log_capture.capture(fn() {
      ip.client_address("10.0.0.5", report_headers(), trusted)
    })
  let assert "10.0.0.5" = address
  let assert False = list.any(logs, fn(event) { event.level == "warning" })
  let assert True =
    log_capture.has(logs, level: "debug", containing: [
      "no forwarding header is configured",
    ])
}

/// An untrusted peer's headers are never read, whatever is configured.
pub fn untrusted_peer_is_the_client_in_every_mode_test() {
  list.each([ip.Forwarded, ip.XForwardedFor, ip.NoForwardingHeader], fn(header) {
    let assert Ok(trusted) = ip.parse_trusted_proxies(["10.0.0.0/8"], header)
    let assert "192.0.2.1" =
      ip.client_address("192.0.2.1", report_headers(), trusted)
  })
}

/// RFC 7239 section 7.4: the right-most hop that is not a trusted proxy.
/// The client's prepended hops are skipped, quoted IPv6 with a port parses.
pub fn forwarded_uses_the_right_most_untrusted_hop_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["10.0.0.0/8"], ip.Forwarded)
  let headers = [
    #("forwarded", "for=6.6.6.6, for=203.0.113.7;proto=https"),
    #("forwarded", "for=10.1.2.3"),
  ]
  let assert "203.0.113.7" = ip.client_address("10.0.0.5", headers, trusted)
  let headers = [#("forwarded", "for=\"[2001:db8::1]:4711\", for=10.1.2.3")]
  let assert "2001:db8::1" = ip.client_address("10.0.0.5", headers, trusted)
}

/// A trusted proxy that sent no configured header is itself the client
/// (a health check from the proxy host, say).
pub fn trusted_proxy_without_the_configured_header_is_the_client_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["10.0.0.0/8"], ip.XForwardedFor)
  let assert "10.0.0.5" = ip.client_address("10.0.0.5", [], trusted)
}

/// A garbage hop stops the walk at the proxy instead of guessing.
pub fn malformed_hop_resolves_to_the_proxy_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["10.0.0.0/8"], ip.XForwardedFor)
  let #(address, logs) =
    log_capture.capture(fn() {
      ip.client_address(
        "10.0.0.5",
        [#("x-forwarded-for", "203.0.113.7, not-an-ip")],
        trusted,
      )
    })
  let assert "10.0.0.5" = address
  let assert True =
    log_capture.has(logs, level: "warning", containing: ["Malformed"])
}

/// A header that could never be read (no proxies) is a configuration
/// error, not a silent no-op.
pub fn forwarding_header_without_proxies_is_refused_test() {
  let assert Error(reason) = ip.parse_trusted_proxies([], ip.XForwardedFor)
  let assert True = string.contains(reason, "X-Forwarded-For")
  let assert Error(reason) = ip.parse_trusted_proxies([], ip.Forwarded)
  let assert True = string.contains(reason, "no trusted proxies")
  let assert Ok(_) = ip.parse_trusted_proxies([], ip.NoForwardingHeader)
}

pub fn invalid_proxy_entry_is_refused_in_every_mode_test() {
  list.each([ip.Forwarded, ip.XForwardedFor, ip.NoForwardingHeader], fn(header) {
    let assert Error(_) = ip.parse_trusted_proxies(["10.0.0.0/33"], header)
  })
  let assert Error(_) = ip.parse_proxy_networks(["not-an-ip"])
}

pub fn security_limits_refuse_a_header_without_proxies_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      forwarding_header: ip.XForwardedFor,
    )
  let assert Error(reason) = transport.validate_security_limits(limits)
  let assert True = string.starts_with(reason, "trusted_proxies: ")
  let assert True = string.contains(reason, "X-Forwarded-For")
}

/// The default reads no forwarding header, even from a listed proxy.
pub fn default_security_limits_read_no_forwarding_header_test() {
  let assert ip.NoForwardingHeader =
    transport.default_security_limits().forwarding_header
}

/// End to end through `SecurityLimits` and a real socket: the configured
/// header is the one `client.ip` reads.
pub fn security_limits_header_reaches_client_ip_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      trusted_proxies: ["127.0.0.1"],
      forwarding_header: ip.XForwardedFor,
    )
  let assert Ok(Nil) = transport.validate_security_limits(limits)
  let assert Ok(trusted) = transport.trusted_proxies(limits)
  let req = make_request("GET", "/", report_headers(), loopback_socket())
  let assert Ok("198.51.100.20") = client.ip(req, trusted)
  let limits =
    transport.SecurityLimits(..limits, forwarding_header: ip.Forwarded)
  let assert Ok(trusted) = transport.trusted_proxies(limits)
  let assert Ok("203.0.113.7") = client.ip(req, trusted)
}

fn report_headers() -> List(#(String, String)) {
  [
    #("forwarded", "for=203.0.113.7"),
    #("x-forwarded-for", "198.51.100.20"),
  ]
}

@external(erlang, "brazier_client_ip_test_ffi", "loopback_socket")
fn loopback_socket() -> server.Socket

@external(erlang, "brazier_client_ip_test_ffi", "make_request")
fn make_request(
  method: String,
  path: String,
  headers: List(#(String, String)),
  socket: server.Socket,
) -> request.Request(Connection)
