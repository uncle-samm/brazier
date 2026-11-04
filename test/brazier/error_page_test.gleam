import brazier/element
import brazier/error_page

pub fn not_found_renders_test() {
  let node = error_page.not_found()
  let html = element.to_string(node)
  let assert True = str_contains(html, "404")
  let assert True = str_contains(html, "Not Found")
}

pub fn internal_error_renders_test() {
  let node = error_page.internal_error("DB connection failed")
  let html = element.to_string(node)
  let assert True = str_contains(html, "500")
  let assert True = str_contains(html, "DB connection failed")
}

pub fn custom_error_page_test() {
  let node = error_page.error_page(403, "Forbidden", "Access denied")
  let html = element.to_string(node)
  let assert True = str_contains(html, "403")
  let assert True = str_contains(html, "Forbidden")
  let assert True = str_contains(html, "Access denied")
}

pub fn dev_error_shows_details_test() {
  let node =
    error_page.dev_error("RuntimeError", "Crash in update", "stack trace here")
  let html = element.to_string(node)
  let assert True = str_contains(html, "RuntimeError")
  let assert True = str_contains(html, "stack trace here")
  let assert True = str_contains(html, "development mode")
}

pub fn error_page_has_home_link_test() {
  let node = error_page.not_found()
  let html = element.to_string(node)
  let assert True = str_contains(html, "href=\"/\"")
  let assert True = str_contains(html, "Go back home")
}

pub fn to_response_sets_status_test() {
  let node = error_page.not_found()
  let resp = error_page.to_response(404, node)
  let assert 404 = resp.status
}

pub fn to_response_500_test() {
  let node = error_page.internal_error("")
  let resp = error_page.to_response(500, node)
  let assert 500 = resp.status
}

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "brazier_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
