//// Content-Security-Policy precedence in `secure_headers` and the
//// route-scoped `connect-src` additions built by `csp_with_connect_src`.

import brazier/log_capture
import brazier/middleware
import brazier/transport/http as transport_http
import brazier/transport/server.{type Connection, Bytes}
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string

const widened_default =
  "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https://localhost:4433; frame-ancestors 'self'; object-src 'none'; base-uri 'self'"

// --- secure_headers keeps what the response already set ---

/// Regression: the outer `secure_headers()` overwrote the handler's CSP, so
/// an upload served from an API route lost `default-src 'none'; sandbox`.
pub fn secure_headers_keep_the_response_csp_test() {
  let handler = fn(_req) {
    ok(Nil)
    |> response.set_header(
      "content-security-policy",
      "default-src 'none'; sandbox",
    )
  }
  let resp =
    middleware.pipeline([middleware.secure_headers()], handler)(path_request(
      "/files/a",
    ))
  let assert Ok("default-src 'none'; sandbox") =
    response.get_header(resp, "content-security-policy")
  // The headers the handler did not set are still added.
  let assert Ok("SAMEORIGIN") = response.get_header(resp, "x-frame-options")
  let assert Ok("nosniff") = response.get_header(resp, "x-content-type-options")
}

/// Regression: a framework error page (the static 404 runs inside the
/// pipeline) lost its `DENY`, `no-referrer` and `default-src 'none'`.
pub fn secure_headers_keep_the_error_response_headers_test() {
  let handler = fn(_req) {
    transport_http.create_error_response(404, "Not Found")
  }
  let resp =
    middleware.pipeline([middleware.secure_headers()], handler)(path_request(
      "/static/missing.js",
    ))
  let assert Ok("DENY") = response.get_header(resp, "x-frame-options")
  let assert Ok("no-referrer") = response.get_header(resp, "referrer-policy")
  let assert Ok("default-src 'none'; frame-ancestors 'none'") =
    response.get_header(resp, "content-security-policy")
  let assert Ok("0") = response.get_header(resp, "x-xss-protection")
}

pub fn secure_headers_set_the_default_when_the_response_has_none_test() {
  let resp =
    middleware.pipeline([middleware.secure_headers()], fn(_req) { ok(Nil) })(
      path_request("/"),
    )
  let assert Ok(csp) = response.get_header(resp, "content-security-policy")
  let assert True = csp == middleware.default_csp
}

// --- route-scoped connect-src ---

pub fn route_scoped_connect_src_applies_only_at_that_route_test() {
  let assert Ok(viewer_csp) =
    middleware.csp_with_connect_src(middleware.default_csp, [
      "https://localhost:4433",
    ])
  let piped =
    middleware.pipeline(
      [
        middleware.secure_headers(),
        middleware.at("/viewer", middleware.secure_headers_with_csp(viewer_csp)),
      ],
      fn(_req) { ok(Nil) },
    )
  let assert Ok(csp) =
    response.get_header(
      piped(path_request("/viewer")),
      "content-security-policy",
    )
  let assert True = csp == widened_default
  let assert Ok(csp) =
    response.get_header(piped(path_request("/")), "content-security-policy")
  let assert True = csp == middleware.default_csp
  let assert Ok(csp) =
    response.get_header(
      piped(path_request("/viewer/x")),
      "content-security-policy",
    )
  let assert True = csp == middleware.default_csp
}

pub fn connect_src_is_widened_in_place_test() {
  let assert Ok(csp) =
    middleware.csp_with_connect_src(middleware.default_csp, [
      "https://localhost:4433",
    ])
  let assert True = csp == widened_default
  let assert 1 = directive_count(csp, "connect-src")
}

pub fn connect_src_starts_from_default_src_when_absent_test() {
  // Without connect-src, connections follow default-src: adding a source
  // must keep 'self', not narrow connections to the new source alone.
  let assert Ok(
    "default-src 'self' https://cdn.example; img-src data:; connect-src 'self' https://cdn.example wss://gw.example",
  ) =
    middleware.csp_with_connect_src(
      "default-src 'self' https://cdn.example; img-src data:",
      [
        "wss://gw.example",
      ],
    )
}

pub fn connect_src_drops_none_test() {
  let assert Ok("default-src 'none'; connect-src https://gw.example") =
    middleware.csp_with_connect_src("default-src 'none'", ["https://gw.example"])
  let assert Ok("connect-src https://gw.example; default-src 'self'") =
    middleware.csp_with_connect_src("connect-src 'NONE'; default-src 'self'", [
      "https://gw.example",
    ])
}

pub fn connect_src_does_not_repeat_a_source_test() {
  let assert Ok(csp) =
    middleware.csp_with_connect_src("connect-src 'self' https://a.example", [
      "https://a.example",
      "https://b.example",
      "https://b.example",
    ])
  let assert True =
    csp == "connect-src 'self' https://a.example https://b.example"
}

pub fn connect_src_keeps_other_directives_and_reads_tabs_test() {
  let assert Ok(csp) =
    middleware.csp_with_connect_src(
      " frame-src\t'none' ;Connect-Src 'self';; sandbox ",
      ["https://a.example"],
    )
  let assert True =
    csp == "frame-src 'none'; connect-src 'self' https://a.example; sandbox"
}

// --- unhappy paths ---

pub fn connect_src_refuses_bad_sources_test() {
  list.each(
    [
      [],
      [""],
      ["https://a.example https://b.example"],
      ["https://a.example; script-src *"],
      ["https://a.example, script-src *"],
      ["https://a.example\r\nx-injected: 1"],
      ["https://a.example\t"],
      ["https://ex\u{e4}mple.test"],
      ["'none'"],
      ["'None'"],
      ["https://ok.example", "bad source"],
    ],
    fn(sources) {
      let #(result, logs) =
        log_capture.capture(fn() {
          middleware.csp_with_connect_src(middleware.default_csp, sources)
        })
      let assert Error(_) = result
      let assert True =
        log_capture.has(logs, level: "error", containing: [
          "csp_with_connect_src",
        ])
    },
  )
}

pub fn connect_src_refuses_bad_policies_test() {
  let refused = fn(policy, reason_fragment) {
    let #(result, logs) =
      log_capture.capture(fn() {
        middleware.csp_with_connect_src(policy, ["https://a.example"])
      })
    let assert Error(reason) = result
    let assert True = string.contains(reason, reason_fragment)
    let assert True =
      log_capture.has(logs, level: "error", containing: [reason_fragment])
  }
  // Browsers enforce only the first of a repeated directive.
  refused(
    "connect-src 'self'; connect-src *",
    "repeats the directive connect-src",
  )
  refused(
    "default-src 'self'; Default-Src *",
    "repeats the directive default-src",
  )
  // A comma starts a second policy.
  refused("connect-src 'self', connect-src *", "not one CSP policy")
  refused("connect-src 'self'\r\nx-injected: 1", "not one CSP policy")
  refused("connect-src 'self' https://\u{e4}.test", "not one CSP policy")
  // Nothing restricts connections, so there is nothing to add to.
  refused("img-src 'self'", "neither connect-src nor default-src")
  refused("", "neither connect-src nor default-src")
}

// --- helpers ---

fn ok(_: Nil) -> response.Response(server.ResponseBody) {
  response.new(200)
  |> response.set_body(Bytes(bytes_tree.from_string("ok")))
}

fn path_request(path: String) -> request.Request(Connection) {
  make_request("GET", path)
}

@external(erlang, "brazier_middleware_test_ffi", "make_request")
fn make_request(method: String, path: String) -> request.Request(Connection)

fn directive_count(csp: String, name: String) -> Int {
  csp
  |> string.split(";")
  |> list.filter(fn(directive) {
    string.starts_with(string.trim(directive), name <> " ")
  })
  |> list.length
}
