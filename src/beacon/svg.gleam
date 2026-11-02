/// SVG element helpers for rendering vector graphics.
/// SVG elements require the SVG namespace to render correctly in the browser.
///
/// Usage:
/// ```gleam
/// svg.svg([html.class("w-4 h-4"), svg.viewbox("0 0 16 16")], [
///   svg.path([svg.d("M8 0L16 16H0Z"), svg.fill("currentColor")]),
/// ])
/// ```
import beacon/element.{type Attr, type Node}

// === Container elements ===

/// The root `<svg>` element with the SVG namespace.
pub fn svg(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el(
    "svg",
    [element.attr("xmlns", "http://www.w3.org/2000/svg"), ..attrs],
    children,
  )
}

/// A grouping element `<g>`.
pub fn g(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("g", attrs, children)
}

/// A definitions element `<defs>` for reusable components.
pub fn defs(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("defs", attrs, children)
}

/// A `<symbol>` element for defining graphical template objects.
pub fn symbol(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("symbol", attrs, children)
}

/// A `<use>` element for referencing other SVG elements.
/// Named `use_` because `use` is a reserved keyword in Gleam.
pub fn use_(attrs: List(Attr)) -> Node(msg) {
  element.el("use", attrs, [])
}

/// A `<clipPath>` element for clipping.
pub fn clip_path(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("clipPath", attrs, children)
}

/// A `<mask>` element.
pub fn mask(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("mask", attrs, children)
}

// === Shape elements ===

/// A `<path>` element — the most versatile SVG shape.
pub fn path(attrs: List(Attr)) -> Node(msg) {
  element.el("path", attrs, [])
}

/// A `<circle>` element.
pub fn circle(attrs: List(Attr)) -> Node(msg) {
  element.el("circle", attrs, [])
}

/// A `<rect>` element.
pub fn rect(attrs: List(Attr)) -> Node(msg) {
  element.el("rect", attrs, [])
}

/// An `<ellipse>` element.
pub fn ellipse(attrs: List(Attr)) -> Node(msg) {
  element.el("ellipse", attrs, [])
}

/// A `<line>` element.
pub fn line(attrs: List(Attr)) -> Node(msg) {
  element.el("line", attrs, [])
}

/// A `<polyline>` element.
pub fn polyline(attrs: List(Attr)) -> Node(msg) {
  element.el("polyline", attrs, [])
}

/// A `<polygon>` element.
pub fn polygon(attrs: List(Attr)) -> Node(msg) {
  element.el("polygon", attrs, [])
}

// === Text elements ===

/// A `<text>` element for SVG text content.
pub fn text(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("text", attrs, children)
}

/// A `<tspan>` element for text sub-positioning.
pub fn tspan(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("tspan", attrs, children)
}

// === Gradient elements ===

/// A `<linearGradient>` element.
pub fn linear_gradient(
  attrs: List(Attr),
  children: List(Node(msg)),
) -> Node(msg) {
  element.el("linearGradient", attrs, children)
}

/// A `<radialGradient>` element.
pub fn radial_gradient(
  attrs: List(Attr),
  children: List(Node(msg)),
) -> Node(msg) {
  element.el("radialGradient", attrs, children)
}

/// A `<stop>` element for gradient color stops.
pub fn stop(attrs: List(Attr)) -> Node(msg) {
  element.el("stop", attrs, [])
}

// === Filter elements ===

/// A `<filter>` element.
pub fn filter(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("filter", attrs, children)
}

// === Animation elements ===

/// An `<animate>` element.
pub fn animate(attrs: List(Attr)) -> Node(msg) {
  element.el("animate", attrs, [])
}

/// An `<animateTransform>` element.
pub fn animate_transform(attrs: List(Attr)) -> Node(msg) {
  element.el("animateTransform", attrs, [])
}

// === Other elements ===

/// A `<foreignObject>` element for embedding non-SVG content.
pub fn foreign_object(
  attrs: List(Attr),
  children: List(Node(msg)),
) -> Node(msg) {
  element.el("foreignObject", attrs, children)
}

/// An `<image>` element for embedding raster images.
pub fn image(attrs: List(Attr)) -> Node(msg) {
  element.el("image", attrs, [])
}

/// A `<title>` element for accessible SVG titles.
pub fn title(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("title", attrs, children)
}

/// A `<desc>` element for accessible SVG descriptions.
pub fn desc(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("desc", attrs, children)
}

// === SVG-specific attribute helpers ===

/// The `viewBox` attribute (e.g., "0 0 24 24").
pub fn viewbox(value: String) -> Attr {
  element.attr("viewBox", value)
}

/// The `d` attribute for path data.
pub fn d(value: String) -> Attr {
  element.attr("d", value)
}

/// The `fill` attribute.
pub fn fill(value: String) -> Attr {
  element.attr("fill", value)
}

/// The `stroke` attribute.
pub fn stroke(value: String) -> Attr {
  element.attr("stroke", value)
}

/// The `stroke-width` attribute.
pub fn stroke_width(value: String) -> Attr {
  element.attr("stroke-width", value)
}

/// The `stroke-linecap` attribute.
pub fn stroke_linecap(value: String) -> Attr {
  element.attr("stroke-linecap", value)
}

/// The `stroke-linejoin` attribute.
pub fn stroke_linejoin(value: String) -> Attr {
  element.attr("stroke-linejoin", value)
}

/// The `stroke-dasharray` attribute.
pub fn stroke_dasharray(value: String) -> Attr {
  element.attr("stroke-dasharray", value)
}

/// The `stroke-dashoffset` attribute.
pub fn stroke_dashoffset(value: String) -> Attr {
  element.attr("stroke-dashoffset", value)
}

/// The `cx` attribute (center x coordinate).
pub fn cx(value: String) -> Attr {
  element.attr("cx", value)
}

/// The `cy` attribute (center y coordinate).
pub fn cy(value: String) -> Attr {
  element.attr("cy", value)
}

/// The `r` attribute (radius).
pub fn r(value: String) -> Attr {
  element.attr("r", value)
}

/// The `rx` attribute (horizontal radius).
pub fn rx(value: String) -> Attr {
  element.attr("rx", value)
}

/// The `ry` attribute (vertical radius).
pub fn ry(value: String) -> Attr {
  element.attr("ry", value)
}

/// The `x` attribute.
pub fn x(value: String) -> Attr {
  element.attr("x", value)
}

/// The `y` attribute.
pub fn y(value: String) -> Attr {
  element.attr("y", value)
}

/// The `x1` attribute.
pub fn x1(value: String) -> Attr {
  element.attr("x1", value)
}

/// The `y1` attribute.
pub fn y1(value: String) -> Attr {
  element.attr("y1", value)
}

/// The `x2` attribute.
pub fn x2(value: String) -> Attr {
  element.attr("x2", value)
}

/// The `y2` attribute.
pub fn y2(value: String) -> Attr {
  element.attr("y2", value)
}

/// The `width` attribute.
pub fn width(value: String) -> Attr {
  element.attr("width", value)
}

/// The `height` attribute.
pub fn height(value: String) -> Attr {
  element.attr("height", value)
}

/// The `points` attribute for polyline/polygon.
pub fn points(value: String) -> Attr {
  element.attr("points", value)
}

/// The `transform` attribute.
pub fn transform(value: String) -> Attr {
  element.attr("transform", value)
}

/// The `opacity` attribute.
pub fn opacity(value: String) -> Attr {
  element.attr("opacity", value)
}

/// The `fill-opacity` attribute.
pub fn fill_opacity(value: String) -> Attr {
  element.attr("fill-opacity", value)
}

/// The `stroke-opacity` attribute.
pub fn stroke_opacity(value: String) -> Attr {
  element.attr("stroke-opacity", value)
}

/// The `fill-rule` attribute.
pub fn fill_rule(value: String) -> Attr {
  element.attr("fill-rule", value)
}

/// The `clip-rule` attribute.
pub fn clip_rule(value: String) -> Attr {
  element.attr("clip-rule", value)
}

/// A generic SVG attribute helper for attributes not covered above.
pub fn attribute(name: String, value: String) -> Attr {
  element.attr(name, value)
}
