import brazier/internal/uri_check
import brazier/router
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri

fn at(path: String, query: option.Option(String)) -> uri.Uri {
  uri.Uri(..uri.empty, path: path, query: query)
}

pub fn well_formed_urls_pass_test() {
  list.each(
    [
      at("/", None),
      at("/users/7", Some("tab=posts")),
      at("/users/J%C3%BCrgen/", None),
      at("/files/a%2Fb", Some("q=a%20b&q=c+d")),
      at("/search", Some("")),
    ],
    fn(page) {
      let assert Ok(Nil) = uri_check.check(page)
      // Everything check accepts, the router helpers decode without crashing.
      let _segments: List(String) = router.segments(page)
      let _pairs: List(#(String, String)) = router.query(page)
      Nil
    },
  )
}

pub fn bad_path_encoding_is_rejected_test() {
  list.each(
    [
      "/%zz", "/users/%", "/users/%2", "/users/%E0%A4", "/users/%C0%AF",
      "/ok/%FF/end", "/a%%41", "/a%4",
    ],
    fn(path) {
      let assert Error(reason) = uri_check.check(at(path, None))
      let assert True = string.contains(reason, "path segment")
    },
  )
}

pub fn bad_query_encoding_is_rejected_test() {
  list.each(["a=%zz", "a=%", "a=%2", "q=%E0%A4", "%FF=1"], fn(query) {
    let assert Error(reason) = uri_check.check(at("/", Some(query)))
    let assert True = string.contains(reason, "invalid query string")
    // The reason is logged, and a query can carry a token.
    let assert False = string.contains(reason, query)
  })
}

pub fn rejection_names_the_offending_segment_test() {
  let assert Error(reason) = uri_check.check(at("/fine/%zz/also-fine", None))
  let assert True = string.contains(reason, "\"%zz\"")
}
