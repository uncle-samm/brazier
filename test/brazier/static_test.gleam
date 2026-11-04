import brazier/static
import gleam/http/response
import gleam/int
import gleam/list
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

// --- Digest cache (git's racy-clean rule) ---
//
// The clock is injected: `now` is placed relative to the file's own
// mtime/ctime, so whether an entry falls in the racy window never depends
// on how fast the test runs.

/// A fresh file with `contents`, and the time of its last change.
fn digest_fixture(name: String, contents: String) -> #(String, String, Int) {
  let dir = "/tmp/brazier_static_digest_" <> name <> "_" <> unique_id()
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let path = dir <> "/file.txt"
  let assert Ok(Nil) = simplifile.write(path, contents)
  #(dir, path, last_change(path))
}

fn last_change(path: String) -> Int {
  let assert Ok(info) = simplifile.file_info(path)
  int.max(info.mtime_seconds, info.ctime_seconds)
}

pub fn digest_cache_hit_does_not_rehash_test() {
  let #(dir, path, changed) = digest_fixture("hit", "body{}")
  let trusted = changed + 2
  let assert Ok(first) =
    static.file_digest_at(path, trusted, static.digest_cache_capacity)
  let assert static.Hashed(static.NotCached) = first.source
  let assert Ok(second) =
    static.file_digest_at(path, trusted, static.digest_cache_capacity)
  let assert static.Cached = second.source
  let assert True = second.hash == first.hash
  let assert 6 = second.length
  // The ETag served is the cached content hash.
  let assert True = "\"" <> second.hash <> "\"" == static.etag_for(<<"body{}">>)
  let assert Ok(Nil) = simplifile.delete(dir)
}

pub fn digest_cache_does_not_trust_a_racily_clean_entry_test() {
  let #(dir, path, changed) = digest_fixture("racy", "aaaa")
  // Recorded one second after the last change: inside the racy window.
  let racy = changed + 1
  let assert Ok(first) =
    static.file_digest_at(path, racy, static.digest_cache_capacity)
  let assert static.Hashed(static.NotCached) = first.source
  // Same stat data, but the entry is racily clean: hashed again.
  let assert Ok(second) =
    static.file_digest_at(path, racy, static.digest_cache_capacity)
  let assert static.Hashed(static.RacilyClean) = second.source
  let assert Ok(Nil) = simplifile.delete(dir)
}

pub fn digest_cache_same_second_edit_gets_a_new_etag_test() {
  let #(dir, path, changed) = digest_fixture("same_second", "aaaa")
  let assert Ok(info) = simplifile.file_info(path)
  let assert Ok(before) =
    static.file_digest_at(path, changed, static.digest_cache_capacity)
  // Same size, and the mtime put back: only the ctime can still tell the
  // edit apart, and only when it ticked over a second.
  let assert Ok(Nil) = simplifile.write(path, "bbbb")
  let assert Ok(Nil) = set_mtime(path, info.mtime_seconds)
  let assert Ok(after) =
    static.file_digest_at(path, changed, static.digest_cache_capacity)
  let assert static.Hashed(_) = after.source
  let assert False = after.hash == before.hash
  let assert True = "\"" <> after.hash <> "\"" == static.etag_for(<<"bbbb">>)
  let assert Ok(Nil) = simplifile.delete(dir)
}

pub fn digest_cache_size_change_invalidates_test() {
  let #(dir, path, changed) = digest_fixture("size", "aaaa")
  let trusted = changed + 10
  let assert Ok(before) =
    static.file_digest_at(path, trusted, static.digest_cache_capacity)
  let assert Ok(Nil) = simplifile.write(path, "aaaaaaaa")
  let assert Ok(after) =
    static.file_digest_at(path, trusted, static.digest_cache_capacity)
  let assert static.Hashed(static.StatChanged) = after.source
  let assert 8 = after.length
  let assert False = after.hash == before.hash
  let assert Ok(Nil) = simplifile.delete(dir)
}

pub fn digest_cache_mtime_change_invalidates_test() {
  let #(dir, path, changed) = digest_fixture("mtime", "aaaa")
  let trusted = changed + 10
  let assert Ok(_) =
    static.file_digest_at(path, trusted, static.digest_cache_capacity)
  let assert Ok(static.Digest(source: static.Cached, ..)) =
    static.file_digest_at(path, trusted, static.digest_cache_capacity)
  let assert Ok(Nil) = set_mtime(path, changed - 100)
  let assert Ok(after) =
    static.file_digest_at(path, trusted, static.digest_cache_capacity)
  let assert static.Hashed(static.StatChanged) = after.source
  let assert Ok(Nil) = simplifile.delete(dir)
}

pub fn digest_cache_inode_change_invalidates_test() {
  let #(dir, path, changed) = digest_fixture("inode", "aaaa")
  let trusted = changed + 10
  let assert Ok(before) =
    static.file_digest_at(path, trusted, static.digest_cache_capacity)
  // Replace the file by a rename, as a deploy does: a new inode.
  let assert Ok(Nil) = simplifile.write(path <> ".new", "bbbb")
  let assert Ok(Nil) = simplifile.rename(path <> ".new", path)
  let assert Ok(after) =
    static.file_digest_at(path, trusted, static.digest_cache_capacity)
  let assert static.Hashed(static.StatChanged) = after.source
  let assert False = after.hash == before.hash
  let assert Ok(Nil) = simplifile.delete(dir)
}

pub fn digest_cache_is_bounded_test() {
  let capacity = 3
  let dir = "/tmp/brazier_static_digest_cap_" <> unique_id()
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let paths =
    ["a", "b", "c", "d", "e", "f"]
    |> list.map(fn(name) {
      let path = dir <> "/" <> name
      let assert Ok(Nil) = simplifile.write(path, name)
      path
    })
  list.each(paths, fn(path) {
    let assert Ok(_) = static.file_digest_at(path, 0, capacity)
    let assert True = static.digest_cache_size() <= capacity
  })
  let assert Ok(Nil) = simplifile.delete(dir)
}

@external(erlang, "brazier_static_test_ffi", "set_mtime")
fn set_mtime(path: String, mtime: Int) -> Result(Nil, String)

fn unique_id() -> String {
  do_unique_id()
}

@external(erlang, "brazier_test_ffi", "unique_ref")
fn do_unique_id() -> String
