/// Beacon's element type for representing virtual DOM trees.
/// Simpler than Lustre's Element — focused on the common cases needed
/// for server-rendered diffing.
///
/// We also provide conversion from Lustre's Element type so users can
/// use Lustre's html helpers (html.div, html.button, etc.) to build views
/// and Beacon handles the diffing.
///
/// Reference: Lustre vdom/vnode.gleam, Elm's Html type.
import beacon/internal/url
import beacon/log
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

/// A node in the virtual DOM tree.
pub type Node(msg) {
  /// A text node with string content.
  TextNode(content: String)
  /// An HTML element with tag, attributes, and children.
  ElementNode(tag: String, attributes: List(Attr), children: List(Node(msg)))
  /// A keyed node preserves DOM identity across list reorders.
  /// The key is materialized as a data attribute on the rendered element when possible.
  KeyedNode(key: String, child: Node(msg))
  /// A memoized node that skips re-rendering when dependencies haven't changed.
  /// The `key` is a unique identifier, `deps` are the dependency values
  /// (compared for equality), and `child` is the rendered output.
  /// Reference: Elm's Html.Lazy, Lustre's memo.
  MemoNode(key: String, deps: List(String), child: Node(msg))
  /// An empty node that renders nothing. Used for conditional rendering:
  /// ```gleam
  /// case show_error {
  ///   True -> html.p([], [html.text("Error!")])
  ///   False -> element.none()
  /// }
  /// ```
  NoneNode
  /// Raw HTML content that is injected without escaping.
  /// Used for server-rendered markdown or other pre-sanitized HTML.
  /// WARNING: The caller is responsible for ensuring the HTML is safe.
  /// ```gleam
  /// element.raw_html("<strong>bold</strong>")
  /// ```
  RawHtml(html: String)
}

/// An HTML attribute (key-value pair).
/// Events are stored separately with their handler path.
pub type Attr {
  /// A regular HTML attribute like class="foo" or id="bar".
  HtmlAttr(name: String, value: String)
  /// An event handler like on_click. The value is the event name
  /// that gets sent back to the server.
  EventAttr(event_name: String, handler_id: String, debounce_ms: Option(Int))
  /// An attribute that renders nothing. `attr` returns it for a URL
  /// attribute whose value the URL policy refuses (see `beacon/internal/url`).
  NoAttr
}

/// Convert a Node tree to an HTML string for SSR.
pub fn to_string(node: Node(msg)) -> String {
  to_string_tree(node)
  |> string_tree.to_string
}

/// Convert a Node tree to a StringTree (efficient string building).
pub fn to_string_tree(node: Node(msg)) -> StringTree {
  case node {
    NoneNode -> string_tree.new()
    RawHtml(html) -> string_tree.from_string(html)
    TextNode(content) -> {
      string_tree.from_string(escape_html(content))
    }
    KeyedNode(key, child) -> {
      to_string_tree(materialize_key(child, key))
    }
    MemoNode(_key, _deps, child) -> {
      // Memo is transparent for rendering — just render the child
      to_string_tree(child)
    }
    ElementNode(tag, attributes, children) -> {
      let assert True = is_valid_tag_name(tag)
      let open_tag =
        string_tree.from_string("<")
        |> string_tree.append(tag)
      let with_attrs = render_attributes(open_tag, attributes)
      case is_void_element(tag) {
        True ->
          with_attrs
          |> string_tree.append(">")
        False -> {
          let children_html =
            list.fold(children, string_tree.new(), fn(acc, child) {
              string_tree.append_tree(acc, to_string_tree(child))
            })
          with_attrs
          |> string_tree.append(">")
          |> string_tree.append_tree(children_html)
          |> string_tree.append("</")
          |> string_tree.append(tag)
          |> string_tree.append(">")
        }
      }
    }
  }
}

/// Convert a Node tree to a JSON value for wire transport.
pub fn to_json(node: Node(msg)) -> json.Json {
  case node {
    NoneNode -> json.object([#("t", json.string("none"))])
    RawHtml(html) ->
      json.object([
        #("t", json.string("raw")),
        #("h", json.string(html)),
      ])
    TextNode(content) ->
      json.object([
        #("t", json.string("text")),
        #("c", json.string(content)),
      ])
    KeyedNode(key, child) -> to_json(materialize_key(child, key))
    MemoNode(_key, _deps, child) ->
      // Memo is transparent for JSON — serialize the child
      to_json(child)
    ElementNode(tag, attributes, children) ->
      json.object([
        #("t", json.string("el")),
        #("tag", json.string(tag)),
        #(
          "a",
          json.preprocessed_array(list.filter_map(attributes, attr_to_json)),
        ),
        #("ch", json.array(children, to_json)),
      ])
  }
}

/// Serialize a Node tree to a JSON string.
pub fn to_json_string(node: Node(msg)) -> String {
  to_json(node) |> json.to_string
}

// --- Constructors ---

/// Create an empty node that renders nothing.
/// Used for conditional rendering in views:
/// ```gleam
/// case model.show_error {
///   True -> html.p([], [html.text("Error!")])
///   False -> element.none()
/// }
/// ```
pub fn none() -> Node(msg) {
  NoneNode
}

/// Create a raw HTML node that is injected without escaping.
/// Used for server-rendered content like markdown HTML output.
/// WARNING: The caller is responsible for sanitizing the HTML.
/// Injecting unsanitized user input creates XSS vulnerabilities.
/// ```gleam
/// let html_string = markdown.to_html(source)
/// element.raw_html(html_string)
/// ```
pub fn raw_html(html: String) -> Node(msg) {
  RawHtml(html: html)
}

/// Create a text node. Content is automatically HTML-escaped.
pub fn text(content: String) -> Node(msg) {
  TextNode(content: content)
}

/// Create an HTML element with the given tag, attributes, and children.
pub fn el(
  tag: String,
  attributes: List(Attr),
  children: List(Node(msg)),
) -> Node(msg) {
  let assert True = is_valid_tag_name(tag)
  ElementNode(tag: tag, attributes: attributes, children: children)
}

/// Create a keyed node that preserves DOM identity across reorders.
/// If the child is an element, the key is emitted as `data-beacon-key`.
/// For non-element children the key is currently transparent.
pub fn keyed(key: String, child: Node(msg)) -> Node(msg) {
  KeyedNode(key: key, child: child)
}

/// Create an HTML attribute (key-value pair).
///
/// For a URL attribute (`href`, `src`, `action`, `formaction`, `poster`,
/// `cite`, `xlink:href`) the value must pass the URL policy in
/// `beacon/internal/url`. A refused value is dropped: the result is `NoAttr`
/// and a warning names the attribute and a truncated value.
pub fn attr(name: String, value: String) -> Attr {
  let assert True = is_valid_attribute_name(name)
  case checked_value(name, value) {
    Ok(value) -> HtmlAttr(name: name, value: value)
    Error(Nil) -> NoAttr
  }
}

/// Apply the URL policy to an attribute value about to be built or
/// rendered. A refused value is logged as a warning and returned as
/// `Error(Nil)`; the caller drops the attribute.
pub fn checked_value(name: String, value: String) -> Result(String, Nil) {
  case url.check(name, value) {
    Ok(value) -> Ok(value)
    Error(blocked) -> {
      log.warning(
        "beacon.element",
        "Dropped attribute "
          <> name
          <> "=\""
          <> url.truncate_for_log(value)
          <> "\": "
          <> url.describe(blocked),
      )
      Error(Nil)
    }
  }
}

/// Return True when a custom HTML attribute name is safe to render.
///
/// Inline event attributes (`onclick`, `onload`, etc.) are intentionally not
/// allowed through the generic attribute escape hatch. Use Beacon event helpers
/// such as `on_click` instead.
pub fn is_valid_attribute_name(name: String) -> Bool {
  name != ""
  && !string.starts_with(string.lowercase(name), "on")
  && list.all(string.to_graphemes(name), is_html_name_grapheme)
}

/// Return True when a tag name is safe to render.
pub fn is_valid_tag_name(tag: String) -> Bool {
  tag != "" && list.all(string.to_graphemes(tag), is_html_name_grapheme)
}

/// Create an event handler attribute. Prefer beacon.on_click(), beacon.on_input(), etc.
pub fn on(event_name: String, handler_id: String) -> Attr {
  EventAttr(event_name: event_name, handler_id: handler_id, debounce_ms: None)
}

/// Create an event handler attribute with debounce metadata.
pub fn on_debounced(
  event_name: String,
  handler_id: String,
  debounce_ms: Int,
) -> Attr {
  EventAttr(
    event_name: event_name,
    handler_id: handler_id,
    debounce_ms: Some(debounce_ms),
  )
}

/// Create a memoized node. The diff engine will skip re-diffing this subtree
/// when all dependency values are equal to the previous render.
/// `key` is a unique identifier, `deps` are string values to compare,
/// and `child` is the view function result.
///
/// Example:
/// ```gleam
/// element.memo("user-card", [model.name, int.to_string(model.age)],
///   element.el("div", [], [element.text(model.name)])
/// )
/// ```
/// Reference: Elm's Html.Lazy, Lustre's memo.
pub fn memo(key: String, deps: List(String), child: Node(msg)) -> Node(msg) {
  MemoNode(key: key, deps: deps, child: child)
}

// --- Internal helpers ---

fn materialize_key(node: Node(msg), key: String) -> Node(msg) {
  case node {
    ElementNode(tag, attributes, children) ->
      case has_attr(attributes, "data-beacon-key") {
        True ->
          ElementNode(tag: tag, attributes: attributes, children: children)
        False ->
          ElementNode(
            tag: tag,
            attributes: [HtmlAttr("data-beacon-key", key), ..attributes],
            children: children,
          )
      }
    KeyedNode(_, child) -> materialize_key(child, key)
    other -> other
  }
}

fn has_attr(attributes: List(Attr), name: String) -> Bool {
  list.any(attributes, fn(attr) {
    case attr {
      HtmlAttr(attr_name, _) -> attr_name == name
      EventAttr(_, _, _) | NoAttr -> False
    }
  })
}

fn attr_to_json(attribute: Attr) -> Result(json.Json, Nil) {
  case attribute {
    NoAttr -> Error(Nil)
    HtmlAttr(name, value) -> {
      use value <- result.map(checked_value(name, value))
      json.object([
        #("t", json.string("attr")),
        #("n", json.string(name)),
        #("v", json.string(value)),
      ])
    }
    EventAttr(event_name, handler_id, debounce_ms) ->
      Ok(
        json.object([
          #("t", json.string("event")),
          #("n", json.string(event_name)),
          #("h", json.string(handler_id)),
          #("d", case debounce_ms {
            Some(delay) -> json.int(delay)
            None -> json.null()
          }),
        ]),
      )
  }
}

fn render_attributes(tree: StringTree, attributes: List(Attr)) -> StringTree {
  list.fold(attributes, tree, fn(acc, attribute) {
    case attribute {
      NoAttr -> acc
      HtmlAttr(name, value) -> {
        let assert True = is_valid_attribute_name(name)
        // Checked again here: an `HtmlAttr` built directly, not through
        // `attr`, has not been through the URL policy.
        case checked_value(name, value) {
          Error(Nil) -> acc
          Ok(value) ->
            acc
            |> string_tree.append(" ")
            |> string_tree.append(name)
            |> string_tree.append("=\"")
            |> string_tree.append(escape_attr(value))
            |> string_tree.append("\"")
        }
      }
      EventAttr(event_name, handler_id, debounce_ms) -> {
        let assert True = is_valid_event_name(event_name)
        let with_event =
          acc
          |> string_tree.append(" data-beacon-event-")
          |> string_tree.append(event_name)
          |> string_tree.append("=\"")
          |> string_tree.append(escape_attr(handler_id))
          |> string_tree.append("\"")
        case debounce_ms {
          Some(delay) if event_name == "input" ->
            with_event
            |> string_tree.append(" data-beacon-input-debounce=\"")
            |> string_tree.append(int.to_string(delay))
            |> string_tree.append("\"")
          _ -> with_event
        }
      }
    }
  })
}

fn is_valid_event_name(name: String) -> Bool {
  name != "" && list.all(string.to_graphemes(name), is_html_name_grapheme)
}

fn is_html_name_grapheme(grapheme: String) -> Bool {
  case grapheme {
    "-" | "_" | ":" | "." -> True
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z" -> True
    "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z" -> True
    _ -> False
  }
}

fn is_void_element(tag: String) -> Bool {
  case tag {
    "area"
    | "base"
    | "br"
    | "col"
    | "embed"
    | "hr"
    | "img"
    | "input"
    | "link"
    | "meta"
    | "param"
    | "source"
    | "track"
    | "wbr" -> True
    _ -> False
  }
}

fn escape_html(text: String) -> String {
  text
  |> do_replace("&", "&amp;")
  |> do_replace("<", "&lt;")
  |> do_replace(">", "&gt;")
}

fn escape_attr(text: String) -> String {
  text
  |> do_replace("&", "&amp;")
  |> do_replace("\"", "&quot;")
  |> do_replace("<", "&lt;")
  |> do_replace(">", "&gt;")
}

fn do_replace(subject: String, pattern: String, replacement: String) -> String {
  string.replace(subject, pattern, replacement)
}
