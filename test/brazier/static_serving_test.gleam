/// Static file and client JS hardening: prefix boundaries, traversal,
/// strong ETags and If-None-Match, nosniff, method restriction, strict
/// bundle names, gzip negotiation and the bundle cache. End-to-end tests
/// go through a real listener over raw sockets.
import brazier/error
import brazier/static
import brazier/transport
import brazier/transport/server.{type Socket}
import gleam/bit_array
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

type RawResponse =
  #(Int, List(#(String, String)), BitArray)

// --- Helpers ---

fn temp_dir(tag: String) -> String {
  let dir = "/tmp/brazier_static_serving_" <> tag <> "_" <> unique_ref()
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "test directory must be creatable"
  dir
}

fn write(path: String, contents: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(path, contents)
    as "test file must be writable"
  Nil
}

fn cleanup(dir: String) -> Nil {
  let assert Ok(Nil) = simplifile.delete(dir) as "test directory cleanup"
  Nil
}

fn config_for(static_cfg: option.Option(static.StaticConfig)) {
  transport.TransportConfig(
    port: 0,
    on_connect: fn(_id, _subject) { Nil },
    on_event: fn(_id, _msg) { Nil },
    on_disconnect: fn(_id) { Nil },
    page_html: None,
    middlewares: [],
    static_config: static_cfg,
    runtime_factory: None,
    ws_auth: None,
    ssr_factory: None,
    security_limits: transport.SecurityLimits(
      ..transport.default_security_limits(),
      // The raw requests below name the host "test".
      allowed_hosts: ["test"],
    ),
    api_handler: None,
  )
}

fn start(dir: String) -> server.Listener {
  let cfg =
    static.StaticConfig(directory: dir, prefix: "/static", max_age: 3600)
  let assert Ok(listener) = transport.start_listener(config_for(Some(cfg)))
    as "test listener must start"
  listener
}

fn request(
  listener: server.Listener,
  method: String,
  path: String,
  headers: String,
) -> RawResponse {
  let assert Ok(socket) = raw_connect(server.get_port(listener))
    as "test client must connect"
  let data =
    method
    <> " "
    <> path
    <> " HTTP/1.1\r\nHost: test\r\nConnection: close\r\n"
    <> headers
    <> "\r\n"
  let assert Ok(Nil) = raw_send(socket, <<data:utf8>>) as "send must succeed"
  let assert Ok(resp) = raw_recv_response(socket, 2000, method != "HEAD")
    as "server must answer"
  raw_close(socket)
  resp
}

fn get(listener: server.Listener, path: String) -> RawResponse {
  request(listener, "GET", path, "")
}

fn header(resp: RawResponse, name: String) -> Result(String, Nil) {
  list.key_find(resp.1, name)
}

fn bundle_name() -> String {
  let assert Ok(contents) =
    simplifile.read("priv/static/brazier_client.manifest")
    as "the repository ships a built client bundle manifest"
  string.trim(contents)
}

// --- Prefix boundary ---

pub fn prefix_matches_only_on_segment_boundary_test() {
  let cfg = static.default_config()
  let assert True = static.matches_prefix(cfg, "/static")
  let assert True = static.matches_prefix(cfg, "/static/app.css")
  let assert False = static.matches_prefix(cfg, "/staticfoo")
  let assert False = static.matches_prefix(cfg, "/staticfoo/app.css")
  let assert False = static.matches_prefix(cfg, "/stat")
}

pub fn prefix_lookalike_is_not_served_from_static_dir_test() {
  // Regression: "/staticsecret.txt" used to map to "<dir>secret.txt".
  let dir = temp_dir("lookalike")
  write(dir <> "secret.txt", "outside")
  write(dir <> "/inside.txt", "inside")
  let cfg =
    static.StaticConfig(directory: dir, prefix: "/static", max_age: 3600)
  let assert Error(Nil) = static.serve(cfg, "/staticsecret.txt")
  let assert Ok(resp) = static.serve(cfg, "/static/inside.txt")
  let assert 200 = resp.status
  let assert Ok(Nil) = simplifile.delete(dir <> "secret.txt")
  cleanup(dir)
}

pub fn prefix_itself_and_directory_are_not_files_test() {
  let dir = temp_dir("dir")
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/sub")
  let cfg = static.StaticConfig(directory: dir, prefix: "/static", max_age: 0)
  let assert Error(Nil) = static.serve(cfg, "/static")
  let assert Error(Nil) = static.serve(cfg, "/static/")
  let assert Error(Nil) = static.serve(cfg, "/static/sub")
  let assert Error(Nil) = static.serve(cfg, "/static/sub/")
  cleanup(dir)
}

// --- Traversal and hidden files ---

pub fn traversal_and_hidden_paths_are_refused_test() {
  let dir = temp_dir("traversal")
  write(dir <> "/.env", "SECRET=1")
  let cfg = static.StaticConfig(directory: dir, prefix: "/static", max_age: 0)
  [
    "/static/../etc/passwd",
    "/static/%2e%2e/etc/passwd",
    "/static/%2E%2E%2Fetc",
    "/static/a%5cb",
    "/static/a%00.txt",
    "/static/.env",
    "/static/./a.txt",
    "/static/a//b.txt",
    "/static/c:%5Cwindows",
  ]
  |> list.each(fn(path) {
    let assert Ok(resp) = static.serve(cfg, path)
      as "a refused path must be answered"
    let assert True = resp.status == 403
  })
  cleanup(dir)
}

pub fn invalid_percent_encoding_is_bad_request_test() {
  let cfg = static.default_config()
  let assert Ok(resp) = static.serve(cfg, "/static/%zz.css")
  let assert 400 = resp.status
}

pub fn percent_encoded_names_are_decoded_test() {
  let dir = temp_dir("encoded")
  write(dir <> "/my file.txt", "spaced")
  let cfg = static.StaticConfig(directory: dir, prefix: "/static", max_age: 0)
  let assert Ok(resp) = static.serve(cfg, "/static/my%20file.txt")
  let assert 200 = resp.status
  cleanup(dir)
}

pub fn unreadable_file_is_a_loud_500_test() {
  let dir = temp_dir("unreadable")
  write(dir <> "/locked.txt", "locked")
  let assert Ok(Nil) = simplifile.set_permissions_octal(dir <> "/locked.txt", 0)
  let cfg = static.StaticConfig(directory: dir, prefix: "/static", max_age: 0)
  let assert Ok(resp) = static.serve(cfg, "/static/locked.txt")
  let assert 500 = resp.status
  cleanup(dir)
}

// --- ETags ---

pub fn etag_is_content_based_not_size_based_test() {
  // Regression: the ETag used to be the byte size, so an edit that kept
  // the size was answered 304 with stale content.
  let assert False =
    static.etag_for(<<"body{color:red}":utf8>>)
    == static.etag_for(<<"body{color:tan}":utf8>>)
  let assert True =
    static.etag_for(<<"same":utf8>>) == static.etag_for(<<"same":utf8>>)
}

pub fn same_size_edit_is_not_answered_304_test() {
  let dir = temp_dir("etag_edit")
  write(dir <> "/a.css", "body{color:red}")
  let cfg =
    static.StaticConfig(directory: dir, prefix: "/static", max_age: 3600)
  let assert Ok(first) = static.serve(cfg, "/static/a.css")
  let assert Ok(etag) = response_header(first, "etag")
  write(dir <> "/a.css", "body{color:tan}")
  let assert Ok(second) =
    static.serve_with_etag_check(cfg, "/static/a.css", etag)
  let assert 200 = second.status
  cleanup(dir)
}

pub fn if_none_match_lists_weak_tags_and_star_test() {
  let etag = "\"abc\""
  let assert True = static.etag_matches("\"abc\"", etag)
  let assert True = static.etag_matches("W/\"abc\"", etag)
  let assert True = static.etag_matches("\"x\", \"abc\"", etag)
  let assert True = static.etag_matches(" * ", etag)
  let assert False = static.etag_matches("", etag)
  let assert False = static.etag_matches("\"abcd\"", etag)
  let assert False = static.etag_matches("abc", etag)
}

// --- Cache-Control and fingerprints ---

pub fn cache_control_values_test() {
  let assert "no-cache" = static.cache_control(0)
  let assert "public, max-age=60" = static.cache_control(60)
  let assert "public, max-age=31536000, immutable" =
    static.immutable_cache_control()
}

pub fn serve_immutable_sets_immutable_test() {
  let dir = temp_dir("immutable")
  write(dir <> "/app-1.js", "1")
  let cfg = static.StaticConfig(directory: dir, prefix: "/static", max_age: 0)
  let assert Ok(resp) = static.serve_immutable(cfg, "/static/app-1.js")
  let assert Ok("public, max-age=31536000, immutable") =
    response_header(resp, "cache-control")
  cleanup(dir)
}

pub fn fingerprint_uses_content_hash_test() {
  // Regression: the fingerprint used to be the size, so same-size edits
  // kept the URL and immutable caches served stale assets.
  let a = static.fingerprint("app.js", <<"aaaa":utf8>>)
  let b = static.fingerprint("app.js", <<"bbbb":utf8>>)
  let assert False = a == b
  let assert True = string.starts_with(a, "app-")
  let assert True = string.ends_with(a, ".js")
  let assert True = string.length(a) == string.length("app-.js") + 16
  // No extension: the hash is appended and the name is kept intact.
  let assert True =
    string.starts_with(static.fingerprint("LICENSE", <<"x":utf8>>), "LICENSE-")
  let assert True =
    string.starts_with(
      static.fingerprint("v1.2/app.min.js", <<"x":utf8>>),
      "v1.2/app.min-",
    )
}

pub fn mime_type_ignores_dots_in_directories_test() {
  let assert "application/octet-stream" = static.mime_type("assets.css/README")
  let assert "application/octet-stream" = static.mime_type(".env")
  let assert "text/css; charset=utf-8" = static.mime_type("v1.2/site.CSS")
}

// --- Config validation ---

pub fn validate_config_rejects_bad_prefixes_test() {
  let base = static.default_config()
  let assert Ok(Nil) = static.validate_config(base)
  let assert Error(_) =
    static.validate_config(static.StaticConfig(..base, prefix: "/"))
  let assert Error(_) =
    static.validate_config(static.StaticConfig(..base, prefix: "static"))
  let assert Error(_) =
    static.validate_config(static.StaticConfig(..base, prefix: "/static/"))
  let assert Error(_) =
    static.validate_config(static.StaticConfig(..base, prefix: "/a/../b"))
  let assert Error(_) =
    static.validate_config(static.StaticConfig(..base, max_age: -1))
  let assert Error(_) =
    static.validate_config(static.StaticConfig(..base, directory: ""))
}

pub fn listener_refuses_invalid_static_config_test() {
  let bad =
    static.StaticConfig(directory: "priv/static", prefix: "/", max_age: 0)
  let assert Error(error.ConfigError(reason)) =
    transport.start_listener(config_for(Some(bad)))
  let assert True = string.contains(reason, "static")
}

// --- Content negotiation ---

pub fn accepts_gzip_honours_quality_values_test() {
  let assert True = static.accepts_gzip("gzip")
  let assert True = static.accepts_gzip("deflate, GZIP;q=0.5")
  let assert True = static.accepts_gzip("br, *")
  let assert True = static.accepts_gzip("x-gzip")
  let assert False = static.accepts_gzip("")
  let assert False = static.accepts_gzip("identity")
  // Regression: a substring check accepted all of these.
  let assert False = static.accepts_gzip("gzip;q=0")
  let assert False = static.accepts_gzip("gzip; q=0.000")
  let assert False = static.accepts_gzip("*, gzip;q=0")
  let assert False = static.accepts_gzip("notgzip")
  let assert False = static.accepts_gzip("gzip;q=bogus")
}

// --- Client bundle names and cache ---

pub fn client_bundle_name_is_strict_test() {
  let assert True = static.is_client_bundle_name("brazier_client_a9d20c15.js")
  let assert True =
    static.is_client_bundle_name(
      "brazier_client_" <> string.repeat("ab", 32) <> ".js",
    )
  let assert False = static.is_client_bundle_name("brazier_client_abc.js")
  let assert False =
    static.is_client_bundle_name(
      "brazier_client_" <> string.repeat("a", 65) <> ".js",
    )
  let assert False = static.is_client_bundle_name("brazier_client_zzzzzzzz.js")
  let assert False =
    static.is_client_bundle_name("brazier_client_a9d20c15/../../x.js")
  let assert False = static.is_client_bundle_name("brazier_client_a9d20c15.jsx")
  let assert False = static.is_client_bundle_name("brazier_client.manifest")
}

pub fn client_asset_cache_reloads_changed_files_test() {
  let dir = temp_dir("asset_cache")
  let path = dir <> "/bundle.js"
  write(path, "one")
  let assert Ok(first) = static.load_client_asset(path)
  let assert <<"one":utf8>> = first.raw
  let assert Ok(again) = static.load_client_asset(path)
  let assert True = again == first
  let assert True = list.contains(static.cached_client_asset_paths(), path)
  // A rebuilt bundle (different size) is picked up without a restart.
  write(path, "second")
  let assert Ok(second) = static.load_client_asset(path)
  let assert <<"second":utf8>> = second.raw
  let assert False = second.etag == first.etag
  let decompressed = gunzip(second.gzip)
  let assert <<"second":utf8>> = decompressed
  cleanup(dir)
}

pub fn client_asset_cache_is_bounded_test() {
  let dir = temp_dir("asset_bound")
  ["a", "b", "c", "d", "e", "f"]
  |> list.each(fn(name) {
    let path = dir <> "/" <> name <> ".js"
    write(path, name)
    let assert Ok(_) = static.load_client_asset(path)
  })
  let assert True = list.length(static.cached_client_asset_paths()) <= 4
  let assert Error(static.AssetNotFound) =
    static.load_client_asset(dir <> "/missing.js")
  let assert Error(static.AssetNotFound) = static.load_client_asset(dir)
  cleanup(dir)
}

// --- End to end over a listener ---

pub fn static_file_has_nosniff_and_etag_over_http_test() {
  let dir = temp_dir("http_static")
  write(dir <> "/site.css", "body{}")
  let listener = start(dir)
  let resp = get(listener, "/static/site.css")
  let assert 200 = resp.0
  let assert Ok("nosniff") = header(resp, "x-content-type-options")
  let assert Ok("public, max-age=3600") = header(resp, "cache-control")
  let assert Ok(etag) = header(resp, "etag")
  let not_modified =
    request(
      listener,
      "GET",
      "/static/site.css",
      "If-None-Match: " <> etag <> "\r\n",
    )
  let assert 304 = not_modified.0
  let assert <<>> = not_modified.2
  cleanup(dir)
}

pub fn static_lookalike_path_reaches_the_page_over_http_test() {
  let dir = temp_dir("http_lookalike")
  write(dir <> "/site.css", "body{}")
  let listener = start(dir)
  let resp = get(listener, "/staticsite.css")
  let assert 200 = resp.0
  let assert Ok("text/html; charset=utf-8") = header(resp, "content-type")
  cleanup(dir)
}

pub fn static_rejects_unsafe_methods_test() {
  let dir = temp_dir("http_method")
  write(dir <> "/site.css", "body{}")
  let listener = start(dir)
  let resp =
    request(listener, "POST", "/static/site.css", "Content-Length: 0\r\n")
  let assert 405 = resp.0
  let assert Ok("GET, HEAD") = header(resp, "allow")
  let js = request(listener, "DELETE", "/brazier_client.js", "")
  let assert 405 = js.0
  cleanup(dir)
}

pub fn hashed_bundle_is_immutable_and_negotiates_gzip_test() {
  let dir = temp_dir("http_bundle")
  let listener = start(dir)
  let name = bundle_name()
  let plain = get(listener, "/" <> name)
  let assert 200 = plain.0
  let assert Ok("public, max-age=31536000, immutable") =
    header(plain, "cache-control")
  let assert Error(Nil) = header(plain, "content-encoding")
  let assert Ok("accept-encoding") = header(plain, "vary")
  let assert Ok("nosniff") = header(plain, "x-content-type-options")
  let assert Ok(plain_etag) = header(plain, "etag")

  let gz =
    request(listener, "GET", "/" <> name, "Accept-Encoding: gzip, br\r\n")
  let assert 200 = gz.0
  let assert Ok("gzip") = header(gz, "content-encoding")
  let assert Ok(gz_etag) = header(gz, "etag")
  let assert False = gz_etag == plain_etag
  let decompressed = gunzip(gz.2)
  let assert True = decompressed == plain.2

  // q=0 refuses gzip.
  let refused =
    request(listener, "GET", "/" <> name, "Accept-Encoding: gzip;q=0\r\n")
  let assert Error(Nil) = header(refused, "content-encoding")
  cleanup(dir)
}

pub fn stable_bundle_url_revalidates_test() {
  let dir = temp_dir("http_stable")
  let listener = start(dir)
  let resp = get(listener, "/brazier_client.js")
  let assert 200 = resp.0
  let assert Ok("no-cache") = header(resp, "cache-control")
  let assert Ok(etag) = header(resp, "etag")
  let again =
    request(
      listener,
      "GET",
      "/brazier_client.js",
      "If-None-Match: " <> etag <> "\r\n",
    )
  let assert 304 = again.0
  let assert Ok("no-cache") = header(again, "cache-control")
  cleanup(dir)
}

pub fn unknown_or_malformed_bundle_names_test() {
  let dir = temp_dir("http_names")
  let listener = start(dir)
  // Valid shape, no such file: a stale page after a deploy gets 404.
  let missing = get(listener, "/brazier_client_00000000.js")
  let assert 404 = missing.0
  let assert Ok("no-store") = header(missing, "cache-control")
  // Not a bundle name at all: routed like any other path (the page), never
  // read from the assets directory.
  let odd = get(listener, "/brazier_client_manifest.js")
  let assert 200 = odd.0
  let assert Ok("text/html; charset=utf-8") = header(odd, "content-type")
  let traversal = get(listener, "/brazier_client_%2e%2e%2fsecret.js")
  let assert True = traversal.0 != 500
  let assert Error(Nil) = header(traversal, "etag")
  cleanup(dir)
}

pub fn head_on_bundle_keeps_length_without_body_test() {
  let dir = temp_dir("http_head")
  let listener = start(dir)
  let full = get(listener, "/" <> bundle_name())
  let head = request(listener, "HEAD", "/" <> bundle_name(), "")
  let assert 200 = head.0
  let assert Ok(length) = header(head, "content-length")
  let assert True = length == int.to_string(bit_array.byte_size(full.2))
  let assert <<>> = head.2
  cleanup(dir)
}

fn response_header(
  resp: response.Response(server.ResponseBody),
  name: String,
) -> Result(String, Nil) {
  response.get_header(resp, name)
}

@external(erlang, "brazier_test_ffi", "unique_ref")
fn unique_ref() -> String

@external(erlang, "zlib", "gunzip")
fn gunzip(data: BitArray) -> BitArray

@external(erlang, "brazier_http_raw_ffi", "connect")
fn raw_connect(port: Int) -> Result(Socket, String)

@external(erlang, "brazier_http_raw_ffi", "send")
fn raw_send(socket: Socket, data: BitArray) -> Result(Nil, String)

@external(erlang, "brazier_http_raw_ffi", "recv_response")
fn raw_recv_response(
  socket: Socket,
  timeout_ms: Int,
  expect_body: Bool,
) -> Result(RawResponse, String)

@external(erlang, "brazier_http_raw_ffi", "close")
fn raw_close(socket: Socket) -> Nil
