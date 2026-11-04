import brazier/attribute
import brazier/element
import brazier/html
import brazier/svg

pub fn svg_element_has_namespace_test() {
  let node = svg.svg([], [])
  let result = element.to_string(node)
  let assert True = str_contains(result, "xmlns=\"http://www.w3.org/2000/svg\"")
  let assert True = str_contains(result, "<svg")
  let assert True = str_contains(result, "</svg>")
}

pub fn svg_with_viewbox_test() {
  let node = svg.svg([svg.viewbox("0 0 24 24")], [])
  let result = element.to_string(node)
  let assert True = str_contains(result, "viewBox=\"0 0 24 24\"")
}

pub fn svg_path_test() {
  let node = svg.path([svg.d("M8 0L16 16H0Z"), svg.fill("currentColor")])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<path")
  let assert True = str_contains(result, "d=\"M8 0L16 16H0Z\"")
  let assert True = str_contains(result, "fill=\"currentColor\"")
}

pub fn svg_circle_test() {
  let node = svg.circle([svg.cx("50"), svg.cy("50"), svg.r("25")])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<circle")
  let assert True = str_contains(result, "cx=\"50\"")
  let assert True = str_contains(result, "cy=\"50\"")
  let assert True = str_contains(result, "r=\"25\"")
}

pub fn svg_rect_test() {
  let node =
    svg.rect([svg.x("10"), svg.y("10"), svg.width("100"), svg.height("50")])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<rect")
  let assert True = str_contains(result, "x=\"10\"")
  let assert True = str_contains(result, "width=\"100\"")
}

pub fn svg_line_test() {
  let node = svg.line([svg.x1("0"), svg.y1("0"), svg.x2("100"), svg.y2("100")])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<line")
  let assert True = str_contains(result, "x1=\"0\"")
  let assert True = str_contains(result, "x2=\"100\"")
}

pub fn svg_polyline_test() {
  let node = svg.polyline([svg.points("0,0 50,25 100,0")])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<polyline")
  let assert True = str_contains(result, "points=\"0,0 50,25 100,0\"")
}

pub fn svg_g_group_test() {
  let node =
    svg.g([svg.transform("translate(10,10)")], [
      svg.circle([svg.r("5")]),
      svg.rect([svg.width("10"), svg.height("10")]),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<g")
  let assert True = str_contains(result, "transform=\"translate(10,10)\"")
  let assert True = str_contains(result, "<circle")
  let assert True = str_contains(result, "<rect")
  let assert True = str_contains(result, "</g>")
}

pub fn svg_full_icon_test() {
  // Typical icon usage pattern
  let node =
    svg.svg(
      [attribute.class("w-4 h-4"), svg.viewbox("0 0 24 24"), svg.fill("none")],
      [
        svg.path([
          svg.d("M12 2L2 22h20L12 2z"),
          svg.stroke("currentColor"),
          svg.stroke_width("2"),
          svg.stroke_linecap("round"),
          svg.stroke_linejoin("round"),
        ]),
      ],
    )
  let result = element.to_string(node)
  let assert True = str_contains(result, "xmlns=\"http://www.w3.org/2000/svg\"")
  let assert True = str_contains(result, "class=\"w-4 h-4\"")
  let assert True = str_contains(result, "viewBox=\"0 0 24 24\"")
  let assert True = str_contains(result, "stroke=\"currentColor\"")
  let assert True = str_contains(result, "stroke-width=\"2\"")
}

pub fn svg_stroke_attributes_test() {
  let node =
    svg.path([
      svg.stroke_dasharray("5,3"),
      svg.stroke_dashoffset("2"),
      svg.stroke_opacity("0.5"),
      svg.fill_opacity("0.8"),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "stroke-dasharray=\"5,3\"")
  let assert True = str_contains(result, "stroke-dashoffset=\"2\"")
  let assert True = str_contains(result, "stroke-opacity=\"0.5\"")
  let assert True = str_contains(result, "fill-opacity=\"0.8\"")
}

pub fn svg_defs_and_use_test() {
  let node =
    svg.svg([], [
      svg.defs([], [
        svg.circle([attribute.attribute("id", "myCircle"), svg.r("10")]),
      ]),
      svg.use_([
        attribute.attribute("href", "#myCircle"),
        svg.x("20"),
        svg.y("20"),
      ]),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<defs>")
  let assert True = str_contains(result, "</defs>")
  let assert True = str_contains(result, "<use")
  let assert True = str_contains(result, "href=\"#myCircle\"")
}

pub fn svg_gradient_test() {
  let node =
    svg.linear_gradient([attribute.attribute("id", "grad1")], [
      svg.stop([
        attribute.attribute("offset", "0%"),
        attribute.attribute("stop-color", "red"),
      ]),
      svg.stop([
        attribute.attribute("offset", "100%"),
        attribute.attribute("stop-color", "blue"),
      ]),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<linearGradient")
  let assert True = str_contains(result, "<stop")
  let assert True = str_contains(result, "stop-color=\"red\"")
}

pub fn svg_in_html_context_test() {
  // SVG embedded in an HTML page (common pattern)
  let node =
    html.div([attribute.class("icon-container")], [
      svg.svg([attribute.class("icon"), svg.viewbox("0 0 16 16")], [
        svg.path([svg.d("M8 0L16 16H0Z")]),
      ]),
      html.span([], [html.text("Label")]),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<div class=\"icon-container\">")
  let assert True = str_contains(result, "<svg")
  let assert True = str_contains(result, "<span>Label</span>")
}

pub fn svg_text_element_test() {
  let node = svg.text([svg.x("10"), svg.y("20")], [element.text("Hello SVG")])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<text")
  let assert True = str_contains(result, "Hello SVG")
  let assert True = str_contains(result, "</text>")
}

pub fn svg_ellipse_test() {
  let node =
    svg.ellipse([svg.cx("50"), svg.cy("50"), svg.rx("30"), svg.ry("20")])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<ellipse")
  let assert True = str_contains(result, "rx=\"30\"")
  let assert True = str_contains(result, "ry=\"20\"")
}

pub fn svg_polygon_test() {
  let node = svg.polygon([svg.points("100,10 40,198 190,78 10,78 160,198")])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<polygon")
}

pub fn svg_clip_path_test() {
  let node =
    svg.clip_path([attribute.attribute("id", "clip1")], [
      svg.rect([svg.width("100"), svg.height("100")]),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "<clipPath")
  let assert True = str_contains(result, "</clipPath>")
}

pub fn svg_fill_rule_and_clip_rule_test() {
  let node =
    svg.path([
      svg.d("M0 0h24v24H0z"),
      svg.fill_rule("evenodd"),
      svg.clip_rule("evenodd"),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "fill-rule=\"evenodd\"")
  let assert True = str_contains(result, "clip-rule=\"evenodd\"")
}

// --- Helpers ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "brazier_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
