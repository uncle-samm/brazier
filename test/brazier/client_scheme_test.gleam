//// The scheme comes from the configured forwarding header only:
//// `Forwarded` gives the `proto=` of the client's element, `X-Forwarded-For`
//// pairs with `X-Forwarded-Proto`, and no header means `http`. A proxy that
//// sets one header passes the other through from the client, so reading
//// the other would let the client pick its scheme (and pass an https
//// Origin check). Plug.RewriteOn and Django's SECURE_PROXY_SSL_HEADER both
//// read only the header the operator names.

import brazier/error
import brazier/ip
import brazier/log_capture
import brazier/transport
import gleam/list
import gleam/option.{None}
import gleam/string

// --- The listener parses the proxy list once, at start ---

/// The listener parses `trusted_proxies` once when it starts (requests use
/// that parse), so a bad entry must stop it from starting at all.
pub fn listener_refuses_to_start_on_a_bad_trusted_proxy_test() {
  let bad = [
    #(["10.0.0.0/33"], ip.XForwardedFor),
    #(["not-an-ip"], ip.NoForwardingHeader),
    // A header with no proxies would never be read.
    #([], ip.Forwarded),
  ]
  list.each(bad, fn(entry) {
    let limits =
      transport.SecurityLimits(
        ..transport.default_security_limits(),
        trusted_proxies: entry.0,
        forwarding_header: entry.1,
      )
    let #(result, logs) =
      log_capture.capture(fn() { transport.start_listener(listener(limits)) })
    let assert Error(error.ConfigError(reason)) = result
    assert string.contains(reason, "trusted_proxies: ")
    assert log_capture.has(logs, level: "error", containing: [
      "Invalid security limits",
    ])
  })
}

fn listener(limits: transport.SecurityLimits) -> transport.TransportConfig {
  transport.TransportConfig(
    port: 0,
    on_connect: fn(_, _) { Nil },
    on_event: fn(_, _) { Nil },
    on_disconnect: fn(_) { Nil },
    page_html: None,
    middlewares: [],
    static_config: None,
    runtime_factory: None,
    ws_auth: None,
    ssr_factory: None,
    security_limits: limits,
    api_handler: None,
  )
}

fn trusting(header: ip.ForwardingHeader) -> ip.TrustedProxies {
  let assert Ok(trusted) = ip.parse_trusted_proxies(["10.0.0.0/8"], header)
    as "10.0.0.0/8 is a valid CIDR"
  trusted
}

// --- No forwarding header: always http ---

/// Regression: X-Forwarded-Proto was believed from a trusted proxy even
/// with no forwarding header configured.
pub fn no_forwarding_header_ignores_x_forwarded_proto_test() {
  let trusted = trusting(ip.NoForwardingHeader)
  let assert Ok("http") =
    ip.client_scheme("10.0.0.1", [#("x-forwarded-proto", "https")], trusted)
  // Not read at all, so garbage is no error either.
  let assert Ok("http") =
    ip.client_scheme("10.0.0.1", [#("x-forwarded-proto", "gopher")], trusted)
  let assert Ok("http") =
    ip.client_scheme("10.0.0.1", [#("forwarded", "proto=https")], trusted)
}

// --- X-Forwarded-For: X-Forwarded-Proto ---

/// Regression: with `Forwarded` configured, X-Forwarded-Proto (which the
/// proxy passes through from the client) still decided the scheme.
pub fn forwarded_mode_ignores_x_forwarded_proto_test() {
  let trusted = trusting(ip.Forwarded)
  let #(result, logs) =
    log_capture.capture(fn() {
      ip.client_scheme(
        "10.0.0.1",
        [
          #("forwarded", "for=203.0.113.7;proto=http"),
          #("x-forwarded-proto", "https"),
        ],
        trusted,
      )
    })
  let assert Ok("http") = result
  assert log_capture.has(logs, level: "warning", containing: [
    "X-Forwarded-Proto",
    "possible spoofing",
  ])
}

pub fn x_forwarded_for_mode_ignores_forwarded_proto_test() {
  let trusted = trusting(ip.XForwardedFor)
  let assert Ok("http") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=203.0.113.7;proto=https")],
      trusted,
    )
  let assert Ok("https") =
    ip.client_scheme(
      "10.0.0.1",
      [
        #("forwarded", "for=203.0.113.7;proto=http"),
        #("x-forwarded-proto", "https"),
      ],
      trusted,
    )
}

// --- Forwarded: proto= of the client's element ---

/// Regression: `Forwarded` `proto=` was never read, so an https client
/// behind a proxy that sets only `Forwarded` failed its Origin check.
pub fn forwarded_proto_is_read_test() {
  let trusted = trusting(ip.Forwarded)
  let assert Ok("https") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=203.0.113.7;proto=https")],
      trusted,
    )
  // Case-insensitive names and values, quoted values, any order.
  let assert Ok("https") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "Proto=\"HTTPS\"; For=203.0.113.7")],
      trusted,
    )
  let assert Ok("http") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=203.0.113.7;proto=http")],
      trusted,
    )
}

/// The client controls the elements on the left; the element the walk
/// stops at was appended by the outermost trusted proxy, which saw the
/// client's own connection.
pub fn forwarded_proto_comes_from_the_client_element_test() {
  let trusted = trusting(ip.Forwarded)
  // The client prepended an https element; the proxy says http.
  let assert Ok("http") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=6.6.6.6;proto=https, for=203.0.113.7;proto=http")],
      trusted,
    )
  // Two trusted proxies: the outer one (10.0.0.2) saw https from the
  // client, the inner one saw http from the outer one.
  let assert Ok("https") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=203.0.113.7;proto=https, for=10.0.0.2;proto=http")],
      trusted,
    )
  // Several header lines are one list.
  let assert Ok("https") =
    ip.client_scheme(
      "10.0.0.1",
      [
        #("forwarded", "for=203.0.113.7;proto=https"),
        #("forwarded", "for=10.0.0.2;proto=http"),
      ],
      trusted,
    )
  // Every hop trusted: the left-most element.
  let assert Ok("https") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=10.0.0.3;proto=https, for=10.0.0.2;proto=http")],
      trusted,
    )
  // An obfuscated client (`for=_hidden`) still has the proxy's proto=.
  let assert Ok("https") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=_hidden;proto=https")],
      trusted,
    )
}

/// Schemes (RFC 3986 §3.1) and Forwarded parameter names (RFC 7239 §4)
/// are ASCII and compare case-insensitively in ASCII: upper case is read,
/// a scheme holding a character outside ASCII is an error, and a parameter
/// name holding one is no `proto` (skipped, as an extension parameter is).
pub fn schemes_and_parameter_names_compare_in_ascii_test() {
  let x_forwarded_for = trusting(ip.XForwardedFor)
  let assert Ok("https") =
    ip.client_scheme(
      "10.0.0.1",
      [#("x-forwarded-proto", " HTTPS ")],
      x_forwarded_for,
    )
  let #(result, logs) =
    log_capture.capture(fn() {
      ip.client_scheme(
        "10.0.0.1",
        [#("x-forwarded-proto", "\u{FF48}ttps")],
        x_forwarded_for,
      )
    })
  let assert Error("invalid X-Forwarded-Proto \"\u{FF48}ttps\"") = result
  assert log_capture.has(logs, level: "warning", containing: [
    "invalid X-Forwarded-Proto",
  ])
  let forwarded = trusting(ip.Forwarded)
  let assert Ok("https") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "FOR=203.0.113.7;PROTO=https")],
      forwarded,
    )
  let assert Ok("http") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=203.0.113.7;pr\u{00D3}to=https")],
      forwarded,
    )
}

pub fn forwarded_without_proto_is_http_test() {
  let trusted = trusting(ip.Forwarded)
  let assert Ok("http") = ip.client_scheme("10.0.0.1", [], trusted)
  let assert Ok("http") =
    ip.client_scheme("10.0.0.1", [#("forwarded", "for=203.0.113.7")], trusted)
  // proto= on another element does not count.
  let assert Ok("http") =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=6.6.6.6;proto=https, for=203.0.113.7")],
      trusted,
    )
}

pub fn forwarded_proto_from_untrusted_peer_is_ignored_test() {
  let trusted = trusting(ip.Forwarded)
  let assert Ok("http") =
    ip.client_scheme("203.0.113.5", [#("forwarded", "proto=https")], trusted)
  let assert Ok("http") =
    ip.client_scheme("203.0.113.5", [#("forwarded", "proto=gopher")], trusted)
}

pub fn invalid_forwarded_proto_is_an_error_test() {
  let trusted = trusting(ip.Forwarded)
  let #(result, logs) =
    log_capture.capture(fn() {
      ip.client_scheme(
        "10.0.0.1",
        [#("forwarded", "for=203.0.113.7;proto=gopher\u{1b}[31m")],
        trusted,
      )
    })
  let assert Error(reason) = result
  assert string.contains(reason, "invalid Forwarded proto=")
  // The value is quoted (SEC-11).
  assert log_capture.has(logs, level: "warning", containing: [
    "\"gopher\\u{001B}[31m\"",
  ])
  let assert Error(_) =
    ip.client_scheme(
      "10.0.0.1",
      [#("forwarded", "for=203.0.113.7;proto=")],
      trusted,
    )
}

/// RFC 7239 section 4: a parameter must not occur twice in one element.
pub fn duplicate_proto_in_an_element_is_an_error_test() {
  let trusted = trusting(ip.Forwarded)
  let #(result, logs) =
    log_capture.capture(fn() {
      ip.client_scheme(
        "10.0.0.1",
        [#("forwarded", "for=203.0.113.7;proto=https;proto=http")],
        trusted,
      )
    })
  let assert Error(reason) = result
  assert string.contains(reason, "duplicate proto=")
  assert log_capture.has(logs, level: "warning", containing: ["several proto="])
}
