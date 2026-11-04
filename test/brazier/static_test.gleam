import brazier/static
import simplifile

// --- MIME type tests ---

pub fn mime_html_test() {
  let assert "text/html; charset=utf-8" = static.mime_type("index.html")
}

pub fn mime_css_test() {
  let assert "text/css; charset=utf-8" = static.mime_type("style.css")
}

pub fn mime_js_test() {
  let assert "application/javascript; charset=utf-8" =
    static.mime_type("app.js")
}

pub fn mime_png_test() {
  let assert "image/png" = static.mime_type("logo.png")
}

pub fn mime_svg_test() {
  let assert "image/svg+xml" = static.mime_type("icon.svg")
}

pub fn mime_woff2_test() {
  let assert "font/woff2" = static.mime_type("font.woff2")
}

pub fn mime_unknown_test() {
  let assert "application/octet-stream" = static.mime_type("data.xyz")
}

pub fn mime_json_test() {
  let assert "application/json; charset=utf-8" = static.mime_type("data.json")
}

// --- Traversal prevention tests ---

pub fn traversal_dotdot_test() {
  let assert True = static.contains_traversal("../etc/passwd")
}

pub fn traversal_backslash_test() {
  let assert True = static.contains_traversal("..\\windows\\system32")
}

pub fn traversal_clean_path_test() {
  let assert False = static.contains_traversal("/css/style.css")
}

pub fn traversal_nested_dotdot_test() {
  let assert True = static.contains_traversal("/images/../../secret")
}

// --- File serving tests ---

pub fn serve_file_test() {
  let test_dir = "/tmp/brazier_static_test_" <> unique_id()
  let assert Ok(Nil) = simplifile.create_directory_all(test_dir)
  let assert Ok(Nil) =
    simplifile.write(test_dir <> "/test.css", "body { color: red; }")

  let config =
    static.StaticConfig(directory: test_dir, prefix: "/static", max_age: 3600)

  let assert Ok(resp) = static.serve(config, "/static/test.css")
  let assert 200 = resp.status

  let assert Ok(Nil) = simplifile.delete(test_dir)
}

pub fn serve_missing_file_test() {
  let config =
    static.StaticConfig(
      directory: "/tmp/nonexistent_dir",
      prefix: "/static",
      max_age: 0,
    )
  let assert Error(Nil) = static.serve(config, "/static/nope.css")
}

pub fn serve_non_static_path_test() {
  let config = static.default_config()
  let assert Error(Nil) = static.serve(config, "/api/users")
}

pub fn serve_traversal_blocked_test() {
  let config = static.default_config()
  let assert Ok(resp) = static.serve(config, "/static/../../../etc/passwd")
  let assert 403 = resp.status
}

pub fn serve_304_not_modified_test() {
  let test_dir = "/tmp/brazier_static_304_" <> unique_id()
  let assert Ok(Nil) = simplifile.create_directory_all(test_dir)
  let assert Ok(Nil) = simplifile.write(test_dir <> "/file.css", "body{}")

  let config =
    static.StaticConfig(directory: test_dir, prefix: "/static", max_age: 3600)

  // First request: gets 200 with ETag
  let assert Ok(resp1) = static.serve(config, "/static/file.css")
  let assert 200 = resp1.status
  let assert Ok(etag) = response.get_header(resp1, "etag")

  // Second request with matching If-None-Match: gets 304
  let assert Ok(resp2) =
    static.serve_with_etag_check(config, "/static/file.css", etag)
  let assert 304 = resp2.status

  let assert Ok(Nil) = simplifile.delete(test_dir)
}

pub fn serve_200_when_etag_doesnt_match_test() {
  let test_dir = "/tmp/brazier_static_etag_" <> unique_id()
  let assert Ok(Nil) = simplifile.create_directory_all(test_dir)
  let assert Ok(Nil) =
    simplifile.write(test_dir <> "/file.js", "console.log(1)")

  let config =
    static.StaticConfig(directory: test_dir, prefix: "/static", max_age: 0)

  // Request with wrong ETag: gets 200
  let assert Ok(resp) =
    static.serve_with_etag_check(config, "/static/file.js", "\"wrong\"")
  let assert 200 = resp.status

  let assert Ok(Nil) = simplifile.delete(test_dir)
}

import gleam/http/response

fn unique_id() -> String {
  do_unique_id()
}

@external(erlang, "brazier_test_ffi", "unique_ref")
fn do_unique_id() -> String
