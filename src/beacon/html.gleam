/// HTML element helpers over `Element(msg)` and `Attribute(msg)`.
///
/// `html.div([attribute.class("x")], [html.text("hi")])` is
/// `element.element("div", [attribute.class("x")], [element.text("hi")])`.
/// Attribute helpers live in `beacon/attribute` and event listeners in
/// `beacon/event`.
import beacon/attribute.{type Attribute}
import beacon/element.{type Element}

/// Text content, HTML-escaped when rendered.
pub fn text(content: String) -> Element(msg) {
  element.text(content)
}

pub fn div(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("div", attributes, children)
}

pub fn span(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("span", attributes, children)
}

pub fn p(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("p", attributes, children)
}

pub fn h1(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("h1", attributes, children)
}

pub fn h2(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("h2", attributes, children)
}

pub fn h3(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("h3", attributes, children)
}

pub fn h4(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("h4", attributes, children)
}

pub fn h5(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("h5", attributes, children)
}

pub fn h6(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("h6", attributes, children)
}

pub fn nav(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("nav", attributes, children)
}

pub fn header(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("header", attributes, children)
}

pub fn footer(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("footer", attributes, children)
}

pub fn main(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("main", attributes, children)
}

pub fn section(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("section", attributes, children)
}

pub fn article(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("article", attributes, children)
}

pub fn aside(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("aside", attributes, children)
}

pub fn address(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("address", attributes, children)
}

pub fn hgroup(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("hgroup", attributes, children)
}

pub fn search(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("search", attributes, children)
}

pub fn button(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("button", attributes, children)
}

pub fn a(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("a", attributes, children)
}

pub fn form(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("form", attributes, children)
}

pub fn label(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("label", attributes, children)
}

pub fn textarea(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("textarea", attributes, children)
}

pub fn select(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("select", attributes, children)
}

pub fn option(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("option", attributes, children)
}

pub fn optgroup(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("optgroup", attributes, children)
}

pub fn fieldset(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("fieldset", attributes, children)
}

pub fn legend(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("legend", attributes, children)
}

pub fn datalist(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("datalist", attributes, children)
}

pub fn output(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("output", attributes, children)
}

pub fn progress(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("progress", attributes, children)
}

pub fn meter(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("meter", attributes, children)
}

pub fn ul(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("ul", attributes, children)
}

pub fn ol(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("ol", attributes, children)
}

pub fn li(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("li", attributes, children)
}

pub fn dl(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("dl", attributes, children)
}

pub fn dt(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("dt", attributes, children)
}

pub fn dd(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("dd", attributes, children)
}

pub fn menu(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("menu", attributes, children)
}

pub fn table(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("table", attributes, children)
}

pub fn caption(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("caption", attributes, children)
}

pub fn colgroup(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("colgroup", attributes, children)
}

pub fn thead(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("thead", attributes, children)
}

pub fn tbody(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("tbody", attributes, children)
}

pub fn tfoot(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("tfoot", attributes, children)
}

pub fn tr(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("tr", attributes, children)
}

pub fn td(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("td", attributes, children)
}

pub fn th(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("th", attributes, children)
}

pub fn strong(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("strong", attributes, children)
}

pub fn em(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("em", attributes, children)
}

pub fn b(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("b", attributes, children)
}

pub fn i(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("i", attributes, children)
}

pub fn u(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("u", attributes, children)
}

pub fn s(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("s", attributes, children)
}

pub fn small(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("small", attributes, children)
}

pub fn mark(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("mark", attributes, children)
}

pub fn sub(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("sub", attributes, children)
}

pub fn sup(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("sup", attributes, children)
}

pub fn abbr(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("abbr", attributes, children)
}

pub fn cite(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("cite", attributes, children)
}

pub fn q(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("q", attributes, children)
}

pub fn dfn(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("dfn", attributes, children)
}

pub fn kbd(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("kbd", attributes, children)
}

pub fn samp(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("samp", attributes, children)
}

pub fn var(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("var", attributes, children)
}

pub fn time(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("time", attributes, children)
}

pub fn data(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("data", attributes, children)
}

pub fn bdi(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("bdi", attributes, children)
}

pub fn bdo(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("bdo", attributes, children)
}

pub fn ruby(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("ruby", attributes, children)
}

pub fn rt(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("rt", attributes, children)
}

pub fn rp(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("rp", attributes, children)
}

pub fn del(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("del", attributes, children)
}

pub fn ins(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("ins", attributes, children)
}

pub fn pre(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("pre", attributes, children)
}

pub fn code(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("code", attributes, children)
}

pub fn blockquote(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("blockquote", attributes, children)
}

pub fn figure(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("figure", attributes, children)
}

pub fn figcaption(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("figcaption", attributes, children)
}

pub fn details(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("details", attributes, children)
}

pub fn summary(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("summary", attributes, children)
}

pub fn dialog(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("dialog", attributes, children)
}

pub fn canvas(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("canvas", attributes, children)
}

pub fn video(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("video", attributes, children)
}

pub fn audio(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("audio", attributes, children)
}

pub fn picture(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("picture", attributes, children)
}

pub fn iframe(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("iframe", attributes, children)
}

pub fn object(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("object", attributes, children)
}

pub fn map(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("map", attributes, children)
}

pub fn noscript(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("noscript", attributes, children)
}

pub fn template(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("template", attributes, children)
}

pub fn slot(
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  element.element("slot", attributes, children)
}

// --- Void elements: no children ---

pub fn input(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("input", attributes, [])
}

pub fn br(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("br", attributes, [])
}

pub fn hr(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("hr", attributes, [])
}

pub fn img(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("img", attributes, [])
}

pub fn source(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("source", attributes, [])
}

pub fn track(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("track", attributes, [])
}

pub fn wbr(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("wbr", attributes, [])
}

pub fn col(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("col", attributes, [])
}

pub fn area(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("area", attributes, [])
}

pub fn embed(attributes: List(Attribute(msg))) -> Element(msg) {
  element.element("embed", attributes, [])
}
