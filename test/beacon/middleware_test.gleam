import beacon/middleware
import beacon/transport/server.{type Connection, Bytes}
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string

// --- Pipeline tests ---

pub fn pipeline_empty_passes_through_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert 200 = resp.status
}

pub fn pipeline_single_middleware_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let mw = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-test", "added")
  }
  let piped = middleware.pipeline([mw], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert Ok("added") = response.get_header(resp, "x-test")
}

pub fn pipeline_order_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  // First middleware adds "1", second adds "2"
  let mw1 = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-order", "1")
  }
  let mw2 = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-second", "2")
  }
  let piped = middleware.pipeline([mw1, mw2], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert Ok("1") = response.get_header(resp, "x-order")
  let assert Ok("2") = response.get_header(resp, "x-second")
}

pub fn pipeline_short_circuit_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  // Auth middleware that always rejects
  let auth_mw = fn(_req, _next) {
    response.new(401)
    |> response.set_body(Bytes(bytes_tree.from_string("unauthorized")))
  }
  let piped = middleware.pipeline([auth_mw], handler)
  let req = make_request("GET", "/protected")
  let resp = piped(req)
  let assert 401 = resp.status
}

// --- Secure headers tests ---

pub fn secure_headers_sets_x_content_type_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.secure_headers()], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  // Verify ALL headers set by secure_headers()
  let assert Ok("nosniff") = response.get_header(resp, "x-content-type-options")
  let assert Ok("SAMEORIGIN") = response.get_header(resp, "x-frame-options")
  let assert Ok("0") = response.get_header(resp, "x-xss-protection")
  let assert Ok("strict-origin-when-cross-origin") =
    response.get_header(resp, "referrer-policy")
  let assert Ok("camera=(), microphone=(), geolocation=()") =
    response.get_header(resp, "permissions-policy")
  let assert Ok(csp) = response.get_header(resp, "content-security-policy")
  let assert True = csp == middleware.default_csp
  let assert True = string.contains(csp, "frame-ancestors 'self'")
  let assert True = string.contains(csp, "object-src 'none'")
}

pub fn secure_headers_with_custom_csp_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let custom_csp =
    "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; connect-src 'self' ws: wss:"
  let piped =
    middleware.pipeline(
      [middleware.secure_headers_with_csp(custom_csp)],
      handler,
    )
  let req = make_request("GET", "/")
  let resp = piped(req)
  // Custom CSP is used
  let assert Ok(csp) = response.get_header(resp, "content-security-policy")
  let assert True = string.contains(csp, "https://fonts.googleapis.com")
  let assert True = string.contains(csp, "https://fonts.gstatic.com")
  // Other security headers are still set
  let assert Ok("nosniff") = response.get_header(resp, "x-content-type-options")
  let assert Ok("SAMEORIGIN") = response.get_header(resp, "x-frame-options")
}

// --- Request ID tests ---

pub fn request_id_adds_header_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.request_id()], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert Ok(id) = response.get_header(resp, "x-request-id")
  // ID should start with "req_"
  let assert True = string.starts_with(id, "req_")
}

pub fn request_id_unique_per_request_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.request_id()], handler)
  let req = make_request("GET", "/")
  let resp1 = piped(req)
  let resp2 = piped(req)
  let assert Ok(id1) = response.get_header(resp1, "x-request-id")
  let assert Ok(id2) = response.get_header(resp2, "x-request-id")
  let assert True = id1 != id2
}

// --- Body parser tests ---

pub fn body_parser_passes_small_body_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.body_parser(1_000_000)], handler)
  let req = make_request_with_header("POST", "/api", "content-length", "100")
  let resp = piped(req)
  let assert 200 = resp.status
}

pub fn body_parser_rejects_oversized_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.body_parser(1000)], handler)
  let req =
    make_request_with_header("POST", "/api", "content-length", "2000000")
  let resp = piped(req)
  let assert 413 = resp.status
}

pub fn body_parser_passes_no_content_length_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.body_parser(1000)], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert 200 = resp.status
}

/// A refused request never reaches the handler.
fn refusing_handler(_req) {
  panic as "body_parser must not call the handler for a refused request"
}

pub fn body_parser_rejects_unparseable_content_length_test() {
  let piped =
    middleware.pipeline([middleware.body_parser(1000)], refusing_handler)
  list.each(
    ["abc", "-1", "+5", "1.0", " 5", "5 ", "", "12345678901234567890"],
    fn(value) {
      let resp =
        piped(make_request_with_header("POST", "/api", "content-length", value))
      let assert 400 = resp.status
    },
  )
}

pub fn body_parser_rejects_repeated_content_length_test() {
  let piped =
    middleware.pipeline([middleware.body_parser(1000)], refusing_handler)
  let req =
    make_request_with_header("POST", "/api", "content-length", "5")
    |> request.prepend_header("content-length", "5")
  let assert 400 = piped(req).status
  let list_req =
    make_request_with_header("POST", "/api", "content-length", "5, 5")
  let assert 400 = piped(list_req).status
}

pub fn body_parser_rejects_transfer_encoding_test() {
  let piped =
    middleware.pipeline([middleware.body_parser(1000)], refusing_handler)
  let chunked =
    make_request_with_header("POST", "/api", "transfer-encoding", "chunked")
  let assert 501 = piped(chunked).status
  let both = chunked |> request.prepend_header("content-length", "5")
  let assert 400 = piped(both).status
}

pub fn body_parser_accepts_length_at_the_limit_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.body_parser(1000)], handler)
  let at_limit =
    make_request_with_header("POST", "/api", "content-length", "1000")
  let assert 200 = piped(at_limit).status
  let piped_refusing =
    middleware.pipeline([middleware.body_parser(1000)], refusing_handler)
  let over_limit =
    make_request_with_header("POST", "/api", "content-length", "1001")
  let assert 413 = piped_refusing(over_limit).status
}

// --- Compression tests ---

pub fn compress_adds_gzip_header_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_header("content-type", "text/html; charset=utf-8")
    |> response.set_body(
      Bytes(bytes_tree.from_string("<html><body>Hello World!</body></html>")),
    )
  }
  let piped = middleware.pipeline([middleware.compress()], handler)
  let req =
    make_request_with_header("GET", "/", "accept-encoding", "gzip, deflate")
  let resp = piped(req)
  let assert Ok("gzip") = response.get_header(resp, "content-encoding")
  let assert Ok("Accept-Encoding") = response.get_header(resp, "vary")
}

pub fn compress_skips_without_accept_encoding_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_header("content-type", "text/html")
    |> response.set_body(Bytes(bytes_tree.from_string("<html>Hello</html>")))
  }
  let piped = middleware.pipeline([middleware.compress()], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert Error(Nil) = response.get_header(resp, "content-encoding")
}

pub fn compress_skips_binary_content_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_header("content-type", "image/png")
    |> response.set_body(Bytes(bytes_tree.from_string("binary data")))
  }
  let piped = middleware.pipeline([middleware.compress()], handler)
  let req = make_request_with_header("GET", "/img", "accept-encoding", "gzip")
  let resp = piped(req)
  // Should NOT compress binary content
  let assert Error(Nil) = response.get_header(resp, "content-encoding")
}

// --- Rate limit middleware test ---

pub fn rate_limit_middleware_allows_test() {
  let assert Ok(limiter) =
    beacon_rate_limit.new(
      "mw_allow_" <> unique_id(),
      beacon_rate_limit.RateLimitConfig(max_requests: 10, window_seconds: 60),
    )
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.rate_limit(limiter)], handler)
  let req = make_socket_request("GET", "/", [], loopback_socket())
  let resp = piped(req)
  let assert 200 = resp.status
}

pub fn rate_limit_middleware_blocks_test() {
  let assert Ok(limiter) =
    beacon_rate_limit.new(
      "mw_block_" <> unique_id(),
      beacon_rate_limit.RateLimitConfig(max_requests: 1, window_seconds: 60),
    )
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.rate_limit(limiter)], handler)
  let req = make_socket_request("GET", "/", [], loopback_socket())
  // First request passes
  let assert 200 = { piped(req) }.status
  // Second request blocked
  let assert 429 = { piped(req) }.status
}

fn unique_id() -> String {
  do_unique_id()
}

@external(erlang, "beacon_test_ffi", "unique_ref")
fn do_unique_id() -> String

@external(erlang, "beacon_client_ip_test_ffi", "loopback_socket")
fn loopback_socket() -> server.Socket

@external(erlang, "beacon_client_ip_test_ffi", "make_request")
fn make_socket_request(
  method: String,
  path: String,
  headers: List(#(String, String)),
  socket: server.Socket,
) -> request.Request(Connection)

import beacon/rate_limit as beacon_rate_limit
import gleam/http

// --- Route scoping tests ---

pub fn only_applies_to_matching_prefix_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  // Middleware that adds a header — only on /admin/*
  let tag_mw = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-auth", "checked")
  }
  let piped = middleware.pipeline([middleware.only("/admin", tag_mw)], handler)

  // /admin/users → middleware runs
  let resp = piped(make_request("GET", "/admin/users"))
  let assert Ok("checked") = response.get_header(resp, "x-auth")

  // /public → middleware skipped
  let resp2 = piped(make_request("GET", "/public"))
  let assert Error(Nil) = response.get_header(resp2, "x-auth")
}

pub fn only_short_circuits_on_matching_prefix_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  // Auth middleware that blocks — only on /admin/*
  let auth_mw = fn(_req, _next) {
    response.new(401)
    |> response.set_body(Bytes(bytes_tree.from_string("unauthorized")))
  }
  let piped = middleware.pipeline([middleware.only("/admin", auth_mw)], handler)

  // /admin/secret → blocked
  let assert 401 = { piped(make_request("GET", "/admin/secret")) }.status
  // /public → passes through
  let assert 200 = { piped(make_request("GET", "/public")) }.status
}

pub fn at_matches_exact_path_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let tag_mw = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-hit", "yes")
  }
  let piped = middleware.pipeline([middleware.at("/healthz", tag_mw)], handler)

  // Exact match → runs
  let resp = piped(make_request("GET", "/healthz"))
  let assert Ok("yes") = response.get_header(resp, "x-hit")

  // Prefix match → does NOT run (at is exact)
  let resp2 = piped(make_request("GET", "/healthz/detail"))
  let assert Error(Nil) = response.get_header(resp2, "x-hit")

  // Different path → does NOT run
  let resp3 = piped(make_request("GET", "/api"))
  let assert Error(Nil) = response.get_header(resp3, "x-hit")
}

pub fn except_skips_matching_prefix_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  // Auth on everything EXCEPT /public
  let auth_mw = fn(_req, _next) {
    response.new(401)
    |> response.set_body(Bytes(bytes_tree.from_string("unauthorized")))
  }
  let piped =
    middleware.pipeline([middleware.except("/public", auth_mw)], handler)

  // /public/page → auth skipped, passes through
  let assert 200 = { piped(make_request("GET", "/public/page")) }.status
  // /admin → auth applied, blocked
  let assert 401 = { piped(make_request("GET", "/admin")) }.status
}

pub fn methods_filters_by_http_method_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  // Rate limit only POST and PUT
  let block_mw = fn(_req, _next) {
    response.new(429)
    |> response.set_body(Bytes(bytes_tree.from_string("rate limited")))
  }
  let piped =
    middleware.pipeline(
      [middleware.methods([http.Post, http.Put], block_mw)],
      handler,
    )

  // GET → passes through
  let assert 200 = { piped(make_request("GET", "/api")) }.status
  // POST → blocked
  let assert 429 = { piped(make_request("POST", "/api")) }.status
}

pub fn group_chains_multiple_middleware_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let tag1 = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-one", "1")
  }
  let tag2 = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-two", "2")
  }
  // Group only runs on /admin
  let piped =
    middleware.pipeline(
      [middleware.only("/admin", middleware.group([tag1, tag2]))],
      handler,
    )

  // /admin → both headers added
  let resp = piped(make_request("GET", "/admin/dash"))
  let assert Ok("1") = response.get_header(resp, "x-one")
  let assert Ok("2") = response.get_header(resp, "x-two")

  // /other → neither header
  let resp2 = piped(make_request("GET", "/other"))
  let assert Error(Nil) = response.get_header(resp2, "x-one")
  let assert Error(Nil) = response.get_header(resp2, "x-two")
}

pub fn composing_only_and_except_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(Bytes(bytes_tree.from_string("ok")))
  }
  let auth_mw = fn(_req, _next) {
    response.new(401)
    |> response.set_body(Bytes(bytes_tree.from_string("unauthorized")))
  }
  let tag_mw = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-tagged", "yes")
  }
  // Auth on /api/* except /api/health, plus tagging on everything
  let piped =
    middleware.pipeline(
      [
        tag_mw,
        middleware.only("/api", middleware.except("/api/health", auth_mw)),
      ],
      handler,
    )

  // /api/users → auth blocks
  let assert 401 = { piped(make_request("GET", "/api/users")) }.status
  // /api/health → auth skipped, passes through
  let resp = piped(make_request("GET", "/api/health"))
  let assert 200 = resp.status
  let assert Ok("yes") = response.get_header(resp, "x-tagged")
  // /public → no auth applied at all
  let resp2 = piped(make_request("GET", "/public"))
  let assert 200 = resp2.status
  let assert Ok("yes") = response.get_header(resp2, "x-tagged")
}

// --- Helpers ---

fn make_request(method: String, path: String) -> request.Request(Connection) {
  // Create a minimal request for testing
  // We can't create a real Connection, so we use FFI
  do_make_request(method, path)
}

@external(erlang, "beacon_middleware_test_ffi", "make_request")
fn do_make_request(method: String, path: String) -> request.Request(Connection)

fn make_request_with_header(
  method: String,
  path: String,
  header_name: String,
  header_value: String,
) -> request.Request(Connection) {
  do_make_request_with_header(method, path, header_name, header_value)
}

@external(erlang, "beacon_middleware_test_ffi", "make_request_with_header")
fn do_make_request_with_header(
  method: String,
  path: String,
  header_name: String,
  header_value: String,
) -> request.Request(Connection)
