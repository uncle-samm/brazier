import beacon
import beacon/element
import beacon/html
import beacon/island
import beacon/log_capture
import gleam/list

pub fn text_to_string_test() {
  let node = element.text("hello world")
  let assert "hello world" = element.to_string(node)
}

pub fn text_escapes_html_test() {
  let node = element.text("<script>alert('xss')</script>")
  let result = element.to_string(node)
  let assert True = does_not_contain(result, "<script>")
}

pub fn empty_element_test() {
  let node = element.el("div", [], [])
  let assert "<div></div>" = element.to_string(node)
}

pub fn element_with_text_child_test() {
  let node = element.el("p", [], [element.text("hello")])
  let assert "<p>hello</p>" = element.to_string(node)
}

pub fn element_with_attribute_test() {
  let node = element.el("div", [element.attr("class", "container")], [])
  let assert "<div class=\"container\"></div>" = element.to_string(node)
}

pub fn element_with_multiple_attributes_test() {
  let node =
    element.el(
      "div",
      [element.attr("id", "main"), element.attr("class", "active")],
      [],
    )
  let result = element.to_string(node)
  let assert True = str_contains(result, "id=\"main\"")
  let assert True = str_contains(result, "class=\"active\"")
}

pub fn nested_elements_test() {
  let node =
    element.el("div", [], [
      element.el("h1", [], [element.text("Title")]),
      element.el("p", [], [element.text("Content")]),
    ])
  let assert "<div><h1>Title</h1><p>Content</p></div>" = element.to_string(node)
}

pub fn void_element_test() {
  let node = element.el("br", [], [])
  let assert "<br>" = element.to_string(node)
}

pub fn void_element_input_test() {
  let node = element.el("input", [element.attr("type", "text")], [])
  let assert "<input type=\"text\">" = element.to_string(node)
}

pub fn event_attribute_renders_as_data_attr_test() {
  let node =
    element.el("button", [element.on("click", "handler_1")], [
      element.text("Click"),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "data-beacon-event-click")
  let assert True = str_contains(result, "handler_1")
}

pub fn attribute_escapes_quotes_test() {
  let node = element.el("div", [element.attr("title", "He said \"hi\"")], [])
  let result = element.to_string(node)
  let assert True = str_contains(result, "&quot;")
}

pub fn event_handler_id_escapes_quotes_test() {
  let node =
    element.el("button", [element.on("click", "h\" onclick=\"evil")], [
      element.text("Click"),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "h&quot; onclick=&quot;evil")
  let assert False = str_contains(result, " onclick=\"evil")
}

pub fn unsafe_attribute_names_are_rejected_by_validator_test() {
  let assert False = element.is_valid_attribute_name("onclick")
  let assert False = element.is_valid_attribute_name("data-bad\" onclick=\"x")
  let assert True = element.is_valid_attribute_name("data-testid")
  let assert True = element.is_valid_attribute_name("aria-label")
}

pub fn beacon_keyed_renders_data_beacon_key_test() {
  let node = beacon.keyed("terminal-session-1", element.el("div", [], []))
  let result = element.to_string(node)
  let assert True =
    str_contains(result, "data-beacon-key=\"terminal-session-1\"")
}

pub fn preserve_children_attr_renders_test() {
  let node = element.el("div", [beacon.preserve_children()], [])
  let result = element.to_string(node)
  let assert True =
    str_contains(result, "data-beacon-preserve-children=\"true\"")
}

pub fn hook_watch_attr_renders_csv_test() {
  let node =
    element.el("div", [beacon.hook_watch(["data-terminal-session"])], [])
  let result = element.to_string(node)
  let assert True =
    str_contains(result, "data-beacon-hook-watch=\"data-terminal-session\"")
}

pub fn island_mount_renders_keyed_preserved_hook_test() {
  let node = island.mount("terminal-session-1", "terminal-log", [])
  let result = element.to_string(node)
  let assert True =
    str_contains(result, "data-beacon-key=\"terminal-session-1\"")
  let assert True =
    str_contains(result, "data-beacon-island=\"terminal-session-1\"")
  let assert True = str_contains(result, "data-beacon-hook=\"terminal-log\"")
  let assert True =
    str_contains(result, "data-beacon-preserve-children=\"true\"")
}

pub fn to_json_string_text_test() {
  let node = element.text("hello")
  let result = element.to_json_string(node)
  let assert True = str_contains(result, "\"text\"")
  let assert True = str_contains(result, "\"hello\"")
}

pub fn to_json_string_element_test() {
  let node = element.el("div", [element.attr("id", "x")], [element.text("hi")])
  let result = element.to_json_string(node)
  let assert True = str_contains(result, "\"el\"")
  let assert True = str_contains(result, "\"div\"")
  let assert True = str_contains(result, "\"hi\"")
}

// --- element.none() tests ---

pub fn none_renders_empty_string_test() {
  let node = element.none()
  let assert "" = element.to_string(node)
}

pub fn none_in_children_renders_nothing_test() {
  let node =
    element.el("div", [], [
      element.text("before"),
      element.none(),
      element.text("after"),
    ])
  let assert "<div>beforeafter</div>" = element.to_string(node)
}

pub fn none_as_only_child_test() {
  let node = element.el("div", [], [element.none()])
  let assert "<div></div>" = element.to_string(node)
}

pub fn none_to_json_test() {
  let node = element.none()
  let result = element.to_json_string(node)
  let assert True = str_contains(result, "\"none\"")
}

pub fn none_conditional_rendering_test() {
  // Simulates the common conditional rendering pattern
  let node = conditional_error_view(False)
  let assert "<div></div>" = element.to_string(node)
}

pub fn none_conditional_rendering_shows_content_test() {
  let node = conditional_error_view(True)
  let assert "<div><p>Error!</p></div>" = element.to_string(node)
}

fn conditional_error_view(show_error: Bool) -> element.Node(msg) {
  element.el("div", [], [
    case show_error {
      True -> element.el("p", [], [element.text("Error!")])
      False -> element.none()
    },
  ])
}

// --- element.raw_html() tests ---

pub fn raw_html_renders_unescaped_test() {
  let node = element.raw_html("<strong>bold</strong>")
  let assert "<strong>bold</strong>" = element.to_string(node)
}

pub fn raw_html_preserves_tags_test() {
  let node = element.raw_html("<p>Hello <em>world</em></p>")
  let assert "<p>Hello <em>world</em></p>" = element.to_string(node)
}

pub fn raw_html_in_container_test() {
  let node =
    element.el("div", [element.attr("class", "markdown")], [
      element.raw_html("<h1>Title</h1><p>Content</p>"),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<div class=\"markdown\">")
  let assert True = str_contains(result, "<h1>Title</h1><p>Content</p>")
  let assert True = str_contains(result, "</div>")
}

pub fn raw_html_empty_string_test() {
  let node = element.raw_html("")
  let assert "" = element.to_string(node)
}

pub fn raw_html_to_json_test() {
  let node = element.raw_html("<b>test</b>")
  let result = element.to_json_string(node)
  let assert True = str_contains(result, "\"raw\"")
  let assert True = str_contains(result, "<b>test</b>")
}

// --- URL policy (docs/design/API_REDESIGN.md section 5, item 9) ---

pub fn attr_drops_javascript_href_and_logs_warning_test() {
  let #(attribute, logs) =
    log_capture.capture(fn() { element.attr("href", "JaVaScRiPt:alert(1)") })
  let assert element.NoAttr = attribute
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "beacon.element", "href", "JaVaScRiPt:alert(1)", "javascript",
    ])
}

pub fn html_href_and_src_go_through_policy_test() {
  let assert element.NoAttr = html.href(" java\tscript:alert(1)")
  let assert element.NoAttr = html.src_("data:text/html,<script>x</script>")
  let assert element.NoAttr = html.href("data:image/png;base64,AAAA")
  let assert element.HtmlAttr("src", "data:image/png;base64,AAAA") =
    html.src_("data:image/png;base64,AAAA")
  let assert element.HtmlAttr("href", "/home") = html.href("/home")
  let assert element.HtmlAttr("href", "mailto:a@example.com") =
    html.href("mailto:a@example.com")
}

pub fn attr_escape_hatch_covers_every_url_attribute_test() {
  let assert True =
    list.all(
      ["href", "src", "action", "formaction", "poster", "cite", "xlink:href"],
      fn(name) { element.attr(name, "vbscript:x") == element.NoAttr },
    )
  let assert element.NoAttr = element.attr("FormAction", "javascript:x")
  let assert element.HtmlAttr("title", "javascript:x") =
    element.attr("title", "javascript:x")
}

pub fn blocked_attr_is_dropped_from_html_test() {
  let node =
    html.a([element.attr("href", "javascript:alert(1)"), html.class("x")], [
      element.text("go"),
    ])
  let assert "<a class=\"x\">go</a>" = element.to_string(node)
}

pub fn to_string_rechecks_directly_built_attr_test() {
  let node =
    element.el("a", [element.HtmlAttr("href", "javascript:alert(1)")], [
      element.text("go"),
    ])
  let #(html_string, logs) =
    log_capture.capture(fn() { element.to_string(node) })
  let assert "<a>go</a>" = html_string
  let assert True =
    log_capture.has(logs, level: "warning", containing: ["href", "javascript"])
}

pub fn to_json_rechecks_directly_built_attr_test() {
  let node = element.el("img", [element.HtmlAttr("src", "vbscript:x")], [])
  let assert "{\"t\":\"el\",\"tag\":\"img\",\"a\":[],\"ch\":[]}" =
    element.to_json_string(node)
}

pub fn allowed_urls_render_test() {
  let node =
    html.a([html.href("https://example.com/?a=1&b=2")], [element.text("x")])
  let assert "<a href=\"https://example.com/?a=1&amp;b=2\">x</a>" =
    element.to_string(node)
  let img = html.img([html.src_("data:image/webp;base64,UklGR")])
  let assert "<img src=\"data:image/webp;base64,UklGR\">" =
    element.to_string(img)
}

pub fn safe_url_does_not_log_test() {
  let #(_attribute, logs) =
    log_capture.capture(fn() { element.attr("href", "/safe") })
  let assert False = log_capture.has(logs, level: "warning", containing: [])
}

// --- Helpers ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

fn does_not_contain(haystack: String, needle: String) -> Bool {
  case do_str_contains(haystack, needle) {
    True -> False
    False -> True
  }
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
