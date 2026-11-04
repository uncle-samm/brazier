//// Security regressions for the HTTP middleware: rate-limit keying on the
//// real client (no X-Forwarded-For spoofing), segment-boundary route
//// scoping (no `//admin` or `/public/../admin` bypass) and security headers.

import brazier/ip
import brazier/middleware
import brazier/rate_limit
import brazier/transport
import brazier/transport/client
import brazier/transport/server.{type Connection, Bytes}
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/string

// --- Rate limiting: who is the client? ---

/// Regression: the limiter keyed on X-Forwarded-For from anyone, so a
/// client got a fresh budget per invented address.
pub fn spoofed_forwarded_for_from_untrusted_peer_shares_one_bucket_test() {
  let piped = rate_limited(limiter("mw_spoof_", 2), ip.no_trusted_proxies())
  let socket = loopback_socket()
  let assert 200 = piped(xff_request(socket, "203.0.113.1")).status
  let assert 200 = piped(xff_request(socket, "203.0.113.2")).status
  // A third invented address is still the same client: 127.0.0.1.
  let assert 429 = piped(xff_request(socket, "203.0.113.3")).status
  let assert 429 = piped(forwarded_request(socket, "for=198.51.100.4")).status
}

pub fn trusted_proxy_buckets_use_the_forwarded_client_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["127.0.0.0/8"], ip.XForwardedFor)
  let piped = rate_limited(limiter("mw_trusted_", 1), trusted)
  let socket = loopback_socket()
  let assert 200 = piped(xff_request(socket, "203.0.113.1")).status
  let assert 429 = piped(xff_request(socket, "203.0.113.1")).status
  // A different client behind the same proxy has its own budget.
  let assert 200 = piped(xff_request(socket, "203.0.113.2")).status
}

/// The client controls the left of X-Forwarded-For; the right-most
/// untrusted hop (added by the trusted proxy) is what counts.
pub fn prepended_hops_do_not_escape_the_limit_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["127.0.0.1", "10.0.0.0/8"], ip.XForwardedFor)
  let piped = rate_limited(limiter("mw_prepend_", 1), trusted)
  let socket = loopback_socket()
  let assert 200 = piped(xff_request(socket, "203.0.113.9, 10.1.2.3")).status
  let assert 429 =
    piped(xff_request(socket, "6.6.6.6, 203.0.113.9, 10.1.2.3")).status
  let assert 429 =
    piped(xff_request(socket, "1.1.1.1, 2.2.2.2, 203.0.113.9")).status
}

/// A peer that is gone has no address: refuse instead of guessing a key.
pub fn rate_limit_without_peer_address_is_400_test() {
  let piped = rate_limited(limiter("mw_dead_", 10), ip.no_trusted_proxies())
  let resp = piped(socket_request(dead_socket(), "/", []))
  let assert 400 = resp.status
}

pub fn rate_limited_response_has_retry_after_test() {
  let assert Ok(lim) =
    rate_limit.new(
      "mw_retry_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 1, window_seconds: 42),
    )
  let piped = rate_limited(lim, ip.no_trusted_proxies())
  let socket = loopback_socket()
  let assert 200 = piped(socket_request(socket, "/", [])).status
  let resp = piped(socket_request(socket, "/", []))
  let assert 429 = resp.status
  let assert Ok("42") = response.get_header(resp, "retry-after")
}

// --- Client IP and scheme resolution ---

pub fn client_ip_is_the_socket_peer_test() {
  let req = socket_request(loopback_socket(), "/", [])
  let assert Ok("127.0.0.1") = client.ip(req, ip.no_trusted_proxies())
}

pub fn client_ip_of_dead_socket_is_an_error_test() {
  let req = socket_request(dead_socket(), "/", [])
  let assert Error(_) = client.ip(req, ip.no_trusted_proxies())
}

pub fn scheme_ignores_forwarded_proto_from_untrusted_peer_test() {
  let headers = [#("x-forwarded-proto", "https")]
  let assert Ok("http") =
    client.scheme_from("203.0.113.5", headers, ip.no_trusted_proxies())
  // Even garbage is ignored: it is not read at all.
  let assert Ok("http") =
    client.scheme_from(
      "203.0.113.5",
      [#("x-forwarded-proto", "gopher")],
      ip.no_trusted_proxies(),
    )
}

pub fn scheme_honours_forwarded_proto_from_trusted_proxy_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["10.0.0.0/8"], ip.XForwardedFor)
  let assert Ok("http") = client.scheme_from("10.0.0.1", [], trusted)
  let assert Ok("https") =
    client.scheme_from("10.0.0.1", [#("x-forwarded-proto", "https")], trusted)
  let assert Ok("https") =
    client.scheme_from(
      "10.0.0.1",
      [#("x-forwarded-proto", "HTTPS, http")],
      trusted,
    )
}

pub fn scheme_rejects_bad_forwarded_proto_from_trusted_proxy_test() {
  let assert Ok(trusted) =
    ip.parse_trusted_proxies(["10.0.0.0/8"], ip.XForwardedFor)
  let assert Error(_) =
    client.scheme_from("10.0.0.1", [#("x-forwarded-proto", "gopher")], trusted)
  let assert Error(_) =
    client.scheme_from("10.0.0.1", [#("x-forwarded-proto", "")], trusted)
  let assert Error(reason) =
    client.scheme_from(
      "10.0.0.1",
      [#("x-forwarded-proto", "https"), #("x-forwarded-proto", "http")],
      trusted,
    )
  let assert True = string.contains(reason, "duplicate")
}

pub fn invalid_trusted_proxy_entry_is_refused_test() {
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      trusted_proxies: ["10.0.0.0/33"],
    )
  let assert Error(reason) = transport.validate_security_limits(limits)
  let assert True = string.starts_with(reason, "trusted_proxies: ")
  let limits =
    transport.SecurityLimits(
      ..transport.default_security_limits(),
      trusted_proxies: ["not-an-ip"],
    )
  let assert Error(_) = transport.validate_security_limits(limits)
}

// --- Route scoping on segment boundaries ---

pub fn only_does_not_match_a_longer_segment_test() {
  let piped = middleware.pipeline([middleware.only("/admin", tag())], ok)
  let assert Error(Nil) = tagged(piped(path_request("/administrator")))
  let assert Error(Nil) = tagged(piped(path_request("/adminx/users")))
  let assert Ok("yes") = tagged(piped(path_request("/admin")))
  let assert Ok("yes") = tagged(piped(path_request("/admin/users")))
}

/// Regression: `only` compared raw strings, while the routers drop empty
/// segments, so `//admin` reached the admin page without the middleware.
pub fn only_matches_paths_the_router_normalises_test() {
  let piped = middleware.pipeline([middleware.only("/admin", tag())], ok)
  let assert Ok("yes") = tagged(piped(path_request("//admin")))
  let assert Ok("yes") = tagged(piped(path_request("/admin/")))
  let assert Ok("yes") = tagged(piped(path_request("/x/../admin")))
  let assert Error(Nil) = tagged(piped(path_request("/public")))
}

/// Regression: `only` read the path undecoded, while the page router
/// decodes each segment, so `/%61dmin` rendered the admin page without the
/// middleware.
pub fn only_matches_percent_encoded_readings_test() {
  let piped = middleware.pipeline([middleware.only("/admin", tag())], ok)
  let assert Ok("yes") = tagged(piped(path_request("/%61dmin")))
  let assert Ok("yes") = tagged(piped(path_request("/%61%64%6D%69%6E/users")))
  let assert Ok("yes") = tagged(piped(path_request("/%2Fadmin")))
  let assert Ok("yes") = tagged(piped(path_request("/x/%2E%2E/admin")))
  // Its raw reading still counts too, and an undecodable path is matched
  // on its raw readings alone.
  let assert Ok("yes") = tagged(piped(path_request("/admin/%ZZ")))
  let assert Error(Nil) = tagged(piped(path_request("/%61dministrator")))
  let assert Error(Nil) = tagged(piped(path_request("/public/%ZZ")))
}

pub fn except_applies_to_percent_encoded_escapes_test() {
  let piped = middleware.pipeline([middleware.except("/public", tag())], ok)
  let assert Ok("yes") = tagged(piped(path_request("/public/%2E%2E/admin")))
  let assert Ok("yes") = tagged(piped(path_request("/public%2F..%2Fadmin")))
  // Skipping is the risky answer, so it needs every reading under the
  // prefix: an encoded `/public` still gets the middleware.
  let assert Ok("yes") = tagged(piped(path_request("/%70ublic/style.css")))
  let assert Error(Nil) = tagged(piped(path_request("/public/a%20b.css")))
}

/// Regression: `except("/public", auth)` skipped auth for
/// `/public/../admin`, which the API router resolves to `/admin`.
pub fn except_still_applies_to_dot_segment_escapes_test() {
  let piped = middleware.pipeline([middleware.except("/public", tag())], ok)
  let assert Ok("yes") = tagged(piped(path_request("/public/../admin")))
  let assert Ok("yes") = tagged(piped(path_request("/publicity")))
  let assert Error(Nil) = tagged(piped(path_request("/public")))
  let assert Error(Nil) = tagged(piped(path_request("/public/style.css")))
  let assert Error(Nil) = tagged(piped(path_request("//public/style.css")))
}

pub fn at_matches_exact_path_with_trailing_slash_test() {
  let piped = middleware.pipeline([middleware.at("/login", tag())], ok)
  let assert Ok("yes") = tagged(piped(path_request("/login")))
  let assert Ok("yes") = tagged(piped(path_request("/login/")))
  let assert Ok("yes") = tagged(piped(path_request("//login")))
  let assert Error(Nil) = tagged(piped(path_request("/login/extra")))
  let assert Error(Nil) = tagged(piped(path_request("/loginx")))
}

// --- Security headers ---

pub fn secure_headers_cover_clickjacking_sniffing_and_referrer_test() {
  let piped = middleware.pipeline([middleware.secure_headers()], ok)
  let resp = piped(path_request("/"))
  let assert Ok("nosniff") = response.get_header(resp, "x-content-type-options")
  let assert Ok("SAMEORIGIN") = response.get_header(resp, "x-frame-options")
  let assert Ok("strict-origin-when-cross-origin") =
    response.get_header(resp, "referrer-policy")
  let assert Ok("0") = response.get_header(resp, "x-xss-protection")
  let assert Ok(csp) = response.get_header(resp, "content-security-policy")
  let assert True = string.contains(csp, "frame-ancestors 'self'")
  let assert True = string.contains(csp, "object-src 'none'")
  let assert True = string.contains(csp, "base-uri 'self'")
  // HSTS is opt-in: it only belongs on HTTPS deployments.
  let assert Error(Nil) = response.get_header(resp, "strict-transport-security")
}

pub fn hsts_sets_max_age_test() {
  let assert Ok(hsts) = middleware.hsts(31_536_000, True)
  let resp = middleware.pipeline([hsts], ok)(path_request("/"))
  let assert Ok("max-age=31536000; includeSubDomains") =
    response.get_header(resp, "strict-transport-security")
  let assert Ok(hsts) = middleware.hsts(0, False)
  let resp = middleware.pipeline([hsts], ok)(path_request("/"))
  let assert Ok("max-age=0") =
    response.get_header(resp, "strict-transport-security")
}

pub fn hsts_rejects_negative_max_age_test() {
  let assert Error(reason) = middleware.hsts(-1, False)
  let assert True = string.contains(reason, "max-age")
}

// --- Helpers ---

fn limiter(prefix: String, max_requests: Int) -> rate_limit.RateLimiter {
  let assert Ok(lim) =
    rate_limit.new(
      prefix <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: max_requests, window_seconds: 60),
    )
  lim
}

fn rate_limited(
  lim: rate_limit.RateLimiter,
  trusted: ip.TrustedProxies,
) -> fn(request.Request(Connection)) -> response.Response(server.ResponseBody) {
  middleware.pipeline([middleware.rate_limit_behind_proxies(lim, trusted)], ok)
}

fn ok(
  _req: request.Request(Connection),
) -> response.Response(server.ResponseBody) {
  response.new(200)
  |> response.set_body(Bytes(bytes_tree.from_string("ok")))
}

fn tag() -> middleware.Middleware {
  fn(req, next) { response.set_header(next(req), "x-tagged", "yes") }
}

fn tagged(resp: response.Response(server.ResponseBody)) -> Result(String, Nil) {
  response.get_header(resp, "x-tagged")
}

fn xff_request(
  socket: server.Socket,
  value: String,
) -> request.Request(Connection) {
  socket_request(socket, "/", [#("x-forwarded-for", value)])
}

fn forwarded_request(
  socket: server.Socket,
  value: String,
) -> request.Request(Connection) {
  socket_request(socket, "/", [#("forwarded", value)])
}

fn socket_request(
  socket: server.Socket,
  path: String,
  headers: List(#(String, String)),
) -> request.Request(Connection) {
  make_socket_request("GET", path, headers, socket)
}

fn path_request(path: String) -> request.Request(Connection) {
  make_path_request("GET", path)
}

fn unique_id() -> String {
  int.to_string(unique_integer())
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "brazier_middleware_test_ffi", "make_request")
fn make_path_request(
  method: String,
  path: String,
) -> request.Request(Connection)

@external(erlang, "brazier_client_ip_test_ffi", "loopback_socket")
fn loopback_socket() -> server.Socket

@external(erlang, "brazier_client_ip_test_ffi", "dead_socket")
fn dead_socket() -> server.Socket

@external(erlang, "brazier_client_ip_test_ffi", "make_request")
fn make_socket_request(
  method: String,
  path: String,
  headers: List(#(String, String)),
  socket: server.Socket,
) -> request.Request(Connection)
