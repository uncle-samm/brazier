import brazier/attribute
import brazier/element
import brazier/event
import brazier/html
import brazier/internal/render
import brazier/log_capture
import brazier/svg
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/list
import gleam/string

pub fn text_to_string_test() {
  let assert "hello world" = element.to_string(element.text("hello world"))
}

pub fn text_escapes_html_test() {
  let assert "&lt;script&gt;alert('xss')&lt;/script&gt;" =
    element.to_string(element.text("<script>alert('xss')</script>"))
}

pub fn empty_element_test() {
  let assert "<div></div>" = element.to_string(element.element("div", [], []))
}

pub fn element_with_text_child_test() {
  let assert "<p>hello</p>" =
    element.to_string(element.element("p", [], [element.text("hello")]))
}

pub fn element_with_attributes_in_order_test() {
  let node =
    element.element(
      "div",
      [attribute.id("main"), attribute.attribute("class", "active")],
      [],
    )
  let assert "<div id=\"main\" class=\"active\"></div>" =
    element.to_string(node)
}

pub fn nested_elements_test() {
  let node =
    html.div([], [
      html.h1([], [html.text("Title")]),
      html.p([], [html.text("Content")]),
    ])
  let assert "<div><h1>Title</h1><p>Content</p></div>" = element.to_string(node)
}

pub fn void_elements_have_no_closing_tag_test() {
  let assert "<br>" = element.to_string(element.element("br", [], []))
  let assert "<input type=\"text\">" =
    element.to_string(html.input([attribute.type_("text")]))
}

pub fn attribute_escapes_quotes_test() {
  let node = html.div([attribute.title("He said \"hi\" <b>")], [])
  let assert "<div title=\"He said &quot;hi&quot; &lt;b&gt;\"></div>" =
    element.to_string(node)
}

pub fn unsafe_names_are_rejected_by_validators_test() {
  let assert False = render.is_valid_attribute_name("onclick")
  let assert False = render.is_valid_attribute_name("OnLoad")
  let assert False = render.is_valid_attribute_name("data-bad\" onclick=\"x")
  let assert False = render.is_valid_attribute_name("")
  let assert True = render.is_valid_attribute_name("data-testid")
  let assert True = render.is_valid_attribute_name("aria-label")
  let assert False = render.is_valid_tag_name("div onload=x")
  let assert False = render.is_valid_tag_name("")
  let assert True = render.is_valid_tag_name("my-element")
  let assert False = render.is_valid_event_name("click:0")
  let assert False = render.is_valid_event_name("a.b")
  let assert False = render.is_valid_event_name("cl\"ick")
  let assert True = render.is_valid_event_name("pointermove")
}

// --- class / style merging ---

pub fn repeated_class_attributes_are_joined_test() {
  let node =
    html.div(
      [attribute.class("a"), attribute.id("x"), attribute.class("b")],
      [],
    )
  let assert "<div class=\"a b\" id=\"x\"></div>" = element.to_string(node)
}

pub fn repeated_style_attributes_are_joined_test() {
  let node =
    html.div(
      [attribute.style("color", "red"), attribute.style("margin", "0")],
      [],
    )
  let assert "<div style=\"color:red;margin:0\"></div>" =
    element.to_string(node)
}

pub fn styles_renders_declarations_in_order_test() {
  let node =
    html.div(
      [
        attribute.styles([#("color", "red"), #("margin", "0")]),
        attribute.style("padding", "1px"),
      ],
      [],
    )
  let assert "<div style=\"color:red;margin:0;padding:1px\"></div>" =
    element.to_string(node)
}

pub fn styles_with_no_declarations_adds_no_attribute_test() {
  let assert "<div></div>" =
    element.to_string(html.div([attribute.styles([])], []))
  let assert "<div style=\"color:red\"></div>" =
    element.to_string(
      html.div([attribute.styles([]), attribute.style("color", "red")], []),
    )
}

pub fn classes_includes_only_enabled_names_test() {
  let node =
    html.div(
      [attribute.classes([#("a", True), #("b", False), #("c", True)])],
      [],
    )
  let assert "<div class=\"a c\"></div>" = element.to_string(node)
}

pub fn boolean_attributes_test() {
  let assert "<input disabled=\"\">" =
    element.to_string(html.input([attribute.disabled(True)]))
  let assert "<input>" =
    element.to_string(html.input([attribute.disabled(False)]))
  let assert "<div draggable=\"false\"></div>" =
    element.to_string(html.div([attribute.draggable(False)], []))
}

pub fn attribute_none_renders_nothing_test() {
  let assert "<div></div>" = element.to_string(html.div([attribute.none()], []))
}

// --- keyed, client integration ---

pub fn keyed_renders_data_brazier_key_test() {
  let node = element.keyed("terminal-session-1", html.div([], []))
  let assert "<div data-brazier-key=\"terminal-session-1\"></div>" =
    element.to_string(node)
}

pub fn inner_key_wins_over_outer_key_test() {
  let node = element.keyed("outer", element.keyed("inner", html.div([], [])))
  let assert "<div data-brazier-key=\"inner\"></div>" = element.to_string(node)
}

pub fn keyed_text_renders_text_test() {
  let assert "hi" = element.to_string(element.keyed("k", element.text("hi")))
}

pub fn ignore_updates_hook_and_watch_render_test() {
  let node =
    html.div(
      [
        attribute.ignore_updates(),
        attribute.hook("terminal-log"),
        attribute.watch(["data-a", "data-b"]),
      ],
      [],
    )
  let assert "<div data-brazier-preserve-children=\"true\" data-brazier-hook=\"terminal-log\" data-brazier-hook-watch=\"data-a,data-b\"></div>" =
    element.to_string(node)
}

// --- none / raw html ---

pub fn none_renders_empty_string_test() {
  let assert "" = element.to_string(element.none())
}

pub fn none_in_children_renders_nothing_test() {
  let node =
    html.div([], [element.text("before"), element.none(), element.text("after")])
  let assert "<div>beforeafter</div>" = element.to_string(node)
}

pub fn unsafe_raw_html_renders_unescaped_test() {
  let node =
    html.div([attribute.class("markdown")], [
      element.unsafe_raw_html("<h1>Title</h1><p>Content</p>"),
    ])
  let assert "<div class=\"markdown\"><h1>Title</h1><p>Content</p></div>" =
    element.to_string(node)
  let assert "" = element.to_string(element.unsafe_raw_html(""))
}

// --- Events and position ids ---

pub fn event_renders_position_id_test() {
  let node =
    html.div([], [
      html.span([], []),
      html.button([event.on_click("go")], [html.text("Go")]),
    ])
  let assert "<div><span></span><button data-brazier-on-click=\"0.1\">Go</button></div>" =
    element.to_string(node)
}

pub fn none_and_text_consume_position_ids_test() {
  // A conditional `none` must not shift its siblings' ids.
  let node =
    html.div([], [
      element.none(),
      element.text("t"),
      html.button([event.on_click(1)], []),
    ])
  let #(html_string, handlers) = render.render(element.to_node(node))
  let assert True =
    string.contains(html_string, "data-brazier-on-click=\"0.2\"")
  let assert Ok(_) = render.lookup(handlers, "click", "0.2")
}

pub fn keyed_does_not_add_a_level_test() {
  let node =
    html.ul([], [
      element.keyed("a", html.li([event.on_click("a")], [])),
      element.keyed("b", html.li([event.on_click("b")], [])),
    ])
  let #(_html, handlers) = render.render(element.to_node(node))
  let assert Ok(_) = render.lookup(handlers, "click", "0.0")
  let assert Ok(_) = render.lookup(handlers, "click", "0.1")
  let assert ["click"] = render.event_names(handlers)
}

pub fn handler_table_runs_decoder_test() {
  let node = html.input([event.on_input(fn(value) { "typed:" <> value })])
  let #(_html, handlers) = render.render(element.to_node(node))
  let assert Ok(handler) = render.lookup(handlers, "input", "0")
  let payload =
    dynamic.properties([
      #(
        dynamic.string("target"),
        dynamic.properties([#(dynamic.string("value"), dynamic.string("hi"))]),
      ),
    ])
  let assert Ok("typed:hi") = render.run(handler, payload)
}

pub fn decoder_failure_is_reported_test() {
  let node = html.input([event.on_input(fn(value) { value })])
  let #(_html, handlers) = render.render(element.to_node(node))
  let assert Ok(handler) = render.lookup(handlers, "input", "0")
  // The payload has no `target`: the decoder stops at the first missing
  // field and reports where.
  let assert Error(errors) = render.run(handler, dynamic.properties([]))
  let assert True = string.contains(render.describe_errors(errors), "at target")
  // A `target` without a string `value` reports the full path.
  let payload =
    dynamic.properties([
      #(
        dynamic.string("target"),
        dynamic.properties([#(dynamic.string("value"), dynamic.int(1))]),
      ),
    ])
  let assert Error(errors) = render.run(handler, payload)
  let assert True =
    string.contains(render.describe_errors(errors), "at target.value")
}

pub fn last_handler_for_same_event_wins_test() {
  let node =
    html.button([event.on_click("first"), event.on_click("second")], [])
  let #(html_string, handlers) = render.render(element.to_node(node))
  let assert "<button data-brazier-on-click=\"0\"></button>" = html_string
  let assert 1 = dict.size(handlers)
  let assert Ok(handler) = render.lookup(handlers, "click", "0")
  let assert Ok("second") = render.run(handler, dynamic.properties([]))
}

pub fn prevent_default_renders_marker_test() {
  let node = html.form([event.on_submit(fn(_fields) { Nil })], [])
  let assert "<form data-brazier-on-submit=\"0\" data-brazier-prevent-submit=\"\"></form>" =
    element.to_string(node)
}

pub fn modifiers_set_handler_options_test() {
  let node =
    html.input([
      event.on_input(fn(value) { value })
      |> event.debounce(200)
      |> event.stop_propagation,
    ])
  let #(_html, handlers) = render.render(element.to_node(node))
  let assert Ok(render.Handler(
    prevent_default: False,
    stop_propagation: True,
    debounce_ms: 200,
    throttle_ms: 0,
    ..,
  )) = render.lookup(handlers, "input", "0")
}

pub fn throttle_clears_debounce_test() {
  let node =
    html.div(
      [
        event.on("pointermove", decode.success(Nil))
        |> event.debounce(50)
        |> event.throttle(16),
      ],
      [],
    )
  let #(_html, handlers) = render.render(element.to_node(node))
  let assert Ok(render.Handler(debounce_ms: 0, throttle_ms: 16, ..)) =
    render.lookup(handlers, "pointermove", "0")
}

pub fn form_data_keeps_string_fields_only_test() {
  let node = html.form([event.on_submit(fn(fields) { fields })], [])
  let #(_html, handlers) = render.render(element.to_node(node))
  let assert Ok(handler) = render.lookup(handlers, "submit", "0")
  let entries =
    dynamic.list([
      dynamic.list([dynamic.string("name"), dynamic.string("Ada")]),
      dynamic.list([dynamic.string("file"), dynamic.properties([])]),
    ])
  let payload =
    dynamic.properties([
      #(
        dynamic.string("detail"),
        dynamic.properties([#(dynamic.string("formData"), entries)]),
      ),
    ])
  let assert Ok([#("name", "Ada")]) = render.run(handler, payload)
}

pub fn element_map_changes_message_type_test() {
  let node =
    html.button([event.on_click(1)], [])
    |> element.map(fn(n) { n + 41 })
  let #(_html, handlers) = render.render(element.to_node(node))
  let assert Ok(handler) = render.lookup(handlers, "click", "0")
  let assert Ok(42) = render.run(handler, dynamic.properties([]))
}

pub fn attribute_map_leaves_plain_attributes_test() {
  let mapped = attribute.map(attribute.id("x"), fn(n: Int) { n + 1 })
  let assert "<div id=\"x\"></div>" = element.to_string(html.div([mapped], []))
}

// --- URL policy (docs/design/API_REDESIGN.md section 5, item 9) ---

pub fn attribute_drops_javascript_href_and_logs_warning_test() {
  let #(attr, logs) =
    log_capture.capture(fn() {
      attribute.attribute("href", "JaVaScRiPt:alert(1)")
    })
  let assert render.NoAttribute = attribute.to_attr(attr)
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "brazier.attribute", "href", "JaVaScRiPt:alert(1)", "javascript",
    ])
}

pub fn url_helpers_go_through_policy_test() {
  let assert render.NoAttribute =
    attribute.to_attr(attribute.href(" java\tscript:alert(1)"))
  let assert render.NoAttribute =
    attribute.to_attr(attribute.src("data:text/html,<script>x</script>"))
  let assert render.NoAttribute =
    attribute.to_attr(attribute.href("data:image/png;base64,AAAA"))
  let assert render.Attribute("src", "data:image/png;base64,AAAA") =
    attribute.to_attr(attribute.src("data:image/png;base64,AAAA"))
  let assert render.Attribute("href", "/home") =
    attribute.to_attr(attribute.href("/home"))
  let assert render.Attribute("href", "mailto:a@example.com") =
    attribute.to_attr(attribute.href("mailto:a@example.com"))
}

pub fn every_url_attribute_is_checked_test() {
  let assert True =
    list.all(
      ["href", "src", "action", "formaction", "poster", "cite", "xlink:href"],
      fn(name) {
        attribute.to_attr(attribute.attribute(name, "vbscript:x"))
        == render.NoAttribute
      },
    )
  let assert render.NoAttribute =
    attribute.to_attr(attribute.attribute("FormAction", "javascript:x"))
  let assert render.Attribute("title", "javascript:x") =
    attribute.to_attr(attribute.attribute("title", "javascript:x"))
}

pub fn blocked_attribute_is_dropped_from_html_test() {
  let node =
    html.a([attribute.href("javascript:alert(1)"), attribute.class("x")], [
      html.text("go"),
    ])
  let assert "<a class=\"x\">go</a>" = element.to_string(node)
}

pub fn render_rechecks_directly_built_attribute_test() {
  let node =
    element.from_node(
      render.Element("a", [render.Attribute("href", "javascript:alert(1)")], [
        render.Text("go"),
      ]),
    )
  let #(html_string, logs) =
    log_capture.capture(fn() { element.to_string(node) })
  let assert "<a>go</a>" = html_string
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "brazier.render", "href", "javascript",
    ])
}

pub fn allowed_urls_render_test() {
  let node =
    html.a([attribute.href("https://example.com/?a=1&b=2")], [html.text("x")])
  let assert "<a href=\"https://example.com/?a=1&amp;b=2\">x</a>" =
    element.to_string(node)
  let img = html.img([attribute.src("data:image/webp;base64,UklGR")])
  let assert "<img src=\"data:image/webp;base64,UklGR\">" =
    element.to_string(img)
}

pub fn safe_url_does_not_log_test() {
  let #(_attr, logs) = log_capture.capture(fn() { attribute.href("/safe") })
  let assert False = log_capture.has(logs, level: "warning", containing: [])
}

// --- Refused names (SEC-6, SEC-13) ---

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, dynamic.Dynamic))

/// Whether `run` crashed with a reason whose printed form contains
/// `containing` (a `let assert` message).
fn crashes_with(run: fn() -> a, containing: String) -> Bool {
  case rescue(run) {
    Ok(_) -> False
    Error(#(_class, reason)) ->
      string.contains(string.inspect(reason), containing)
  }
}

pub fn srcdoc_attribute_crashes_test() {
  let assert True =
    crashes_with(fn() { attribute.attribute("srcdoc", "<p>x</p>") }, "srcdoc")
  let assert True =
    crashes_with(fn() { attribute.attribute("SrcDoc", "<p>x</p>") }, "srcdoc")
  let assert True =
    crashes_with(fn() { attribute.boolean("SRCDOC", True) }, "srcdoc")
}

pub fn unsafe_srcdoc_renders_escaped_value_test() {
  let node =
    html.iframe(
      [
        attribute.attribute("sandbox", ""),
        attribute.unsafe_srcdoc("<p class=\"x\">a & b</p>"),
      ],
      [],
    )
  let assert "<iframe sandbox=\"\" srcdoc=\"&lt;p class=&quot;x&quot;&gt;a &amp; b&lt;/p&gt;\"></iframe>" =
    element.to_string(node)
}

pub fn attribute_name_targeting_href_crashes_test() {
  let assert True =
    list.all(["href", "xlink:href", "HREF", " href", "xlink:HRef"], fn(value) {
      crashes_with(
        fn() { attribute.attribute("attributeName", value) },
        "attributeName=href",
      )
    })
  let assert True =
    crashes_with(
      fn() { attribute.attribute("ATTRIBUTENAME", "href") },
      "attributeName=href",
    )
  let assert True =
    crashes_with(
      fn() {
        svg.animate([
          attribute.attribute("attributeName", "href"),
          attribute.attribute("values", "javascript:alert(1)"),
        ])
      },
      "attributeName=href",
    )
}

pub fn attribute_name_targeting_other_attributes_renders_test() {
  let node =
    svg.animate([
      attribute.attribute("attributeName", "opacity"),
      attribute.attribute("values", "0;1"),
    ])
  let assert "<animate attributeName=\"opacity\" values=\"0;1\"></animate>" =
    element.to_string(node)
}

pub fn render_refuses_directly_built_refused_attributes_test() {
  let render_with = fn(attr) {
    fn() { render.to_string(render.Element("div", [attr], [])) }
  }
  let assert True =
    crashes_with(render_with(render.Attribute("onclick", "x")), "name policy")
  let assert True =
    crashes_with(render_with(render.Attribute("srcdoc", "<p>")), "name policy")
  let assert True =
    crashes_with(
      render_with(render.Attribute("attributeName", "xlink:href")),
      "name policy",
    )
  let assert True =
    crashes_with(render_with(render.Attribute("a\"b", "x")), "name policy")
  let assert True =
    crashes_with(render_with(render.Attribute("ïd", "x")), "name policy")
}

pub fn render_refuses_directly_built_bad_tag_and_event_test() {
  let assert True =
    crashes_with(
      fn() { render.to_string(render.Element("div onload=x", [], [])) },
      "tag names",
    )
  let event = render.Event("a:b", render.handler(decode.success(Nil)))
  let assert True =
    crashes_with(
      fn() { render.to_string(render.Element("div", [event], [])) },
      "event names",
    )
}

pub fn constructors_crash_with_messages_test() {
  let assert True =
    crashes_with(fn() { element.element("dïv", [], []) }, "tag names")
  let assert True =
    crashes_with(fn() { attribute.attribute("onclick", "x") }, "name policy")
}

// --- Escaping next to combining marks ---

pub fn quote_before_combining_mark_cannot_close_an_attribute_test() {
  // `"` + U+0301 is one grapheme. The value must still not close its
  // quotes, or the rest of it becomes attributes.
  let node =
    html.div([attribute.title("x\"\u{0301} onmouseover=alert(1) y")], [])
  let assert "<div title=\"x&quot;\u{0301} onmouseover=alert(1) y\"></div>" =
    element.to_string(node)
  let text = html.p([], [html.text("<\u{0301}b>&\u{0301}")])
  let assert "<p>&lt;\u{0301}b&gt;&amp;\u{0301}</p>" = element.to_string(text)
}
