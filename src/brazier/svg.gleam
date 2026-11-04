/// SVG element helpers for rendering vector graphics.
/// SVG elements require the SVG namespace to render correctly in the browser.
///
/// Usage:
/// ```gleam
/// svg.svg([attribute.class("w-4 h-4"), svg.viewbox("0 0 16 16")], [
///   svg.path([svg.d("M8 0L16 16H0Z"), svg.fill("currentColor")]),
/// ])
/// ```
import brazier/attribute.{type Attribute}
import brazier/element.{type Element}

// === Container elements ===

/// The root `<svg>` element with the SVG namespace.
pub fn svg(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element(
    "svg",
    [attribute.attribute("xmlns", "http://www.w3.org/2000/svg"), ..attrs],
    children,
  )
}

/// A grouping element `<g>`.
pub fn g(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("g", attrs, children)
}

/// A definitions element `<defs>` for reusable components.
pub fn defs(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("defs", attrs, children)
}

/// A `<symbol>` element for defining graphical template objects.
pub fn symbol(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("symbol", attrs, children)
}

/// A `<use>` element for referencing other SVG elements.
/// Named `use_` because `use` is a reserved keyword in Gleam.
pub fn use_(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("use", attrs, [])
}

/// A `<clipPath>` element for clipping.
pub fn clip_path(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("clipPath", attrs, children)
}

/// A `<mask>` element.
pub fn mask(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("mask", attrs, children)
}

// === Shape elements ===

/// A `<path>` element — the most versatile SVG shape.
pub fn path(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("path", attrs, [])
}

/// A `<circle>` element.
pub fn circle(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("circle", attrs, [])
}

/// A `<rect>` element.
pub fn rect(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("rect", attrs, [])
}

/// An `<ellipse>` element.
pub fn ellipse(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("ellipse", attrs, [])
}

/// A `<line>` element.
pub fn line(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("line", attrs, [])
}

/// A `<polyline>` element.
pub fn polyline(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("polyline", attrs, [])
}

/// A `<polygon>` element.
pub fn polygon(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("polygon", attrs, [])
}

// === Text elements ===

/// A `<text>` element for SVG text content.
pub fn text(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("text", attrs, children)
}

/// A `<tspan>` element for text sub-positioning.
pub fn tspan(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("tspan", attrs, children)
}

// === Gradient elements ===

/// A `<linearGradient>` element.
pub fn linear_gradient(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("linearGradient", attrs, children)
}

/// A `<radialGradient>` element.
pub fn radial_gradient(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("radialGradient", attrs, children)
}

/// A `<stop>` element for gradient color stops.
pub fn stop(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("stop", attrs, [])
}

// === Filter elements ===

/// A `<filter>` element.
pub fn filter(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("filter", attrs, children)
}

// === Animation elements ===

/// An `<animate>` element.
pub fn animate(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("animate", attrs, [])
}

/// An `<animateTransform>` element.
pub fn animate_transform(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("animateTransform", attrs, [])
}

// === Other elements ===

/// A `<foreignObject>` element for embedding non-SVG content.
pub fn foreign_object(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("foreignObject", attrs, children)
}

/// An `<image>` element for embedding raster images.
pub fn image(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("image", attrs, [])
}

/// A `<title>` element for accessible SVG titles.
pub fn title(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("title", attrs, children)
}

/// A `<desc>` element for accessible SVG descriptions.
pub fn desc(
  attrs: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("desc", attrs, children)
}

// === SVG-specific attribute helpers ===

/// The `viewBox` attribute (e.g., "0 0 24 24").
pub fn viewbox(value: String) -> Attribute(msg) {
  attribute.attribute("viewBox", value)
}

/// The `d` attribute for path data.
pub fn d(value: String) -> Attribute(msg) {
  attribute.attribute("d", value)
}

/// The `fill` attribute.
pub fn fill(value: String) -> Attribute(msg) {
  attribute.attribute("fill", value)
}

/// The `stroke` attribute.
pub fn stroke(value: String) -> Attribute(msg) {
  attribute.attribute("stroke", value)
}

/// The `stroke-width` attribute.
pub fn stroke_width(value: String) -> Attribute(msg) {
  attribute.attribute("stroke-width", value)
}

/// The `stroke-linecap` attribute.
pub fn stroke_linecap(value: String) -> Attribute(msg) {
  attribute.attribute("stroke-linecap", value)
}

/// The `stroke-linejoin` attribute.
pub fn stroke_linejoin(value: String) -> Attribute(msg) {
  attribute.attribute("stroke-linejoin", value)
}

/// The `stroke-dasharray` attribute.
pub fn stroke_dasharray(value: String) -> Attribute(msg) {
  attribute.attribute("stroke-dasharray", value)
}

/// The `stroke-dashoffset` attribute.
pub fn stroke_dashoffset(value: String) -> Attribute(msg) {
  attribute.attribute("stroke-dashoffset", value)
}

/// The `cx` attribute (center x coordinate).
pub fn cx(value: String) -> Attribute(msg) {
  attribute.attribute("cx", value)
}

/// The `cy` attribute (center y coordinate).
pub fn cy(value: String) -> Attribute(msg) {
  attribute.attribute("cy", value)
}

/// The `r` attribute (radius).
pub fn r(value: String) -> Attribute(msg) {
  attribute.attribute("r", value)
}

/// The `rx` attribute (horizontal radius).
pub fn rx(value: String) -> Attribute(msg) {
  attribute.attribute("rx", value)
}

/// The `ry` attribute (vertical radius).
pub fn ry(value: String) -> Attribute(msg) {
  attribute.attribute("ry", value)
}

/// The `x` attribute.
pub fn x(value: String) -> Attribute(msg) {
  attribute.attribute("x", value)
}

/// The `y` attribute.
pub fn y(value: String) -> Attribute(msg) {
  attribute.attribute("y", value)
}

/// The `x1` attribute.
pub fn x1(value: String) -> Attribute(msg) {
  attribute.attribute("x1", value)
}

/// The `y1` attribute.
pub fn y1(value: String) -> Attribute(msg) {
  attribute.attribute("y1", value)
}

/// The `x2` attribute.
pub fn x2(value: String) -> Attribute(msg) {
  attribute.attribute("x2", value)
}

/// The `y2` attribute.
pub fn y2(value: String) -> Attribute(msg) {
  attribute.attribute("y2", value)
}

/// The `width` attribute.
pub fn width(value: String) -> Attribute(msg) {
  attribute.attribute("width", value)
}

/// The `height` attribute.
pub fn height(value: String) -> Attribute(msg) {
  attribute.attribute("height", value)
}

/// The `points` attribute for polyline/polygon.
pub fn points(value: String) -> Attribute(msg) {
  attribute.attribute("points", value)
}

/// The `transform` attribute.
pub fn transform(value: String) -> Attribute(msg) {
  attribute.attribute("transform", value)
}

/// The `opacity` attribute.
pub fn opacity(value: String) -> Attribute(msg) {
  attribute.attribute("opacity", value)
}

/// The `fill-opacity` attribute.
pub fn fill_opacity(value: String) -> Attribute(msg) {
  attribute.attribute("fill-opacity", value)
}

/// The `stroke-opacity` attribute.
pub fn stroke_opacity(value: String) -> Attribute(msg) {
  attribute.attribute("stroke-opacity", value)
}

/// The `fill-rule` attribute.
pub fn fill_rule(value: String) -> Attribute(msg) {
  attribute.attribute("fill-rule", value)
}

/// The `clip-rule` attribute.
pub fn clip_rule(value: String) -> Attribute(msg) {
  attribute.attribute("clip-rule", value)
}
