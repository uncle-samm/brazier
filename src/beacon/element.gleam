/// View elements.
///
/// `Element(msg)` is a node of the view tree. Its event listeners produce
/// messages of type `msg`; `map` changes that type, which is how a parent
/// embeds a child module's view.
///
/// The module is target-neutral: the same code renders on the server (SSR)
/// and in the browser.
///
/// Reference: Lustre's `lustre/element`.
import beacon/attribute.{type Attribute}
import beacon/internal/render
import gleam/list

/// A node of the view tree.
pub opaque type Element(msg) {
  Element(node: render.Node(msg))
}

@internal
pub fn to_node(element: Element(msg)) -> render.Node(msg) {
  element.node
}

@internal
pub fn from_node(node: render.Node(msg)) -> Element(msg) {
  Element(node)
}

/// An element with any tag.
///
/// A tag with characters outside `a-z A-Z 0-9 - _ : .` is a programming
/// error and crashes.
pub fn element(
  tag: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  // Invariant: tag names come from application code, not user input. A tag
  // that could break out of the markup is a bug in the view.
  let assert True = render.is_valid_tag_name(tag)
  Element(render.Element(
    tag,
    list.map(attributes, attribute.to_attr),
    list.map(children, to_node),
  ))
}

/// Text content, HTML-escaped when rendered.
pub fn text(content: String) -> Element(msg) {
  Element(render.Text(content))
}

/// Renders nothing. Use it for the empty branch of a conditional.
pub fn none() -> Element(msg) {
  Element(render.Nothing)
}

/// Give an element a stable identity for the client morph, so it keeps its
/// DOM node (focus, scroll, client state) when its siblings are reordered.
/// The rendered element carries `data-beacon-key`.
pub fn keyed(key: String, child: Element(msg)) -> Element(msg) {
  Element(render.Keyed(key, child.node))
}

/// Mark a subtree as depending only on `deps`, so the client morph can skip
/// it when they are unchanged.
pub fn memo(
  key: String,
  deps: List(String),
  child: Element(msg),
) -> Element(msg) {
  Element(render.Memo(key, deps, child.node))
}

/// HTML inserted as is: no escaping and no URL policy. Never pass it text
/// that a user controls.
pub fn unsafe_raw_html(html: String) -> Element(msg) {
  Element(render.RawHtml(html))
}

/// Change the message type of every event listener in the tree.
pub fn map(element: Element(a), f: fn(a) -> b) -> Element(b) {
  Element(render.map_node(element.node, f))
}

/// Render to an HTML string.
pub fn to_string(element: Element(msg)) -> String {
  render.to_string(element.node)
}
