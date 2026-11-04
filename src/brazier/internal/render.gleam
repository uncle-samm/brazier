/// The rendering core shared by the server and the browser.
///
/// `brazier/element` and `brazier/attribute` wrap the types defined here in
/// opaque types. This module walks a tree once and produces the HTML string
/// together with the table of event handlers, keyed by event name and the
/// element's position in the tree.
///
/// Position ids are the child indices from the root, joined with `.`: the
/// root element is `"0"`, its second child is `"0.1"`. Keyed and memo nodes
/// are transparent and do not add a level. Every child consumes an index,
/// including text and `none`, so a conditional `none` does not shift its
/// siblings' ids. The same tree therefore yields the same ids on the server
/// and in the browser, which is what lets an event fired before hydration be
/// replayed against the handler table built after it.
///
/// The module is target-neutral: it is compiled to JavaScript for the
/// client bundle and to Erlang for SSR.
///
/// Reference: Lustre's `vdom/vnode` and `vdom/vattr`, LiveView's
/// `phx-click` bindings.
import brazier/internal/url
import brazier/log
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/string
import gleam/string_tree.{type StringTree}

/// A node of the view tree.
pub type Node(msg) {
  /// Text content. It is HTML-escaped when rendered.
  Text(content: String)
  /// An element with a tag, attributes and children.
  Element(tag: String, attributes: List(Attr(msg)), children: List(Node(msg)))
  /// A node whose rendered element carries `data-brazier-key`, so the client
  /// morph keeps its DOM identity across reorders.
  Keyed(key: String, child: Node(msg))
  /// A memoised child. Rendering is transparent; the key and dependencies are
  /// kept for the client morph.
  Memo(key: String, deps: List(String), child: Node(msg))
  /// Renders nothing.
  Nothing
  /// HTML injected without escaping or URL checks.
  RawHtml(html: String)
}

/// An attribute of an element.
pub type Attr(msg) {
  /// A plain HTML attribute.
  Attribute(name: String, value: String)
  /// An event listener.
  Event(name: String, handler: Handler(msg))
  /// Renders nothing. Produced for a refused URL value or a false boolean.
  NoAttribute
}

/// An event handler: a decoder run against the browser's event object, plus
/// the options the client applies before running it.
pub type Handler(msg) {
  Handler(
    decoder: decode.Decoder(msg),
    prevent_default: Bool,
    stop_propagation: Bool,
    debounce_ms: Int,
    throttle_ms: Int,
  )
}

/// A handler with no options set.
pub fn handler(decoder: decode.Decoder(msg)) -> Handler(msg) {
  Handler(
    decoder: decoder,
    prevent_default: False,
    stop_propagation: False,
    debounce_ms: 0,
    throttle_ms: 0,
  )
}

/// The handler table of one render.
pub type Handlers(msg) =
  Dict(String, Handler(msg))

/// The key of the handler for event `name` on the element with position
/// `id` in a handler table.
pub fn key(name: String, id: String) -> String {
  name <> ":" <> id
}

/// Look up the handler for event `name` on the element with position `id`.
pub fn lookup(
  handlers: Handlers(msg),
  name: String,
  id: String,
) -> Result(Handler(msg), Nil) {
  dict.get(handlers, key(name, id))
}

/// Run a handler's decoder against an event object.
pub fn run(
  handler: Handler(msg),
  event: Dynamic,
) -> Result(msg, List(decode.DecodeError)) {
  decode.run(event, handler.decoder)
}

/// The distinct event names in a handler table, sorted.
pub fn event_names(handlers: Handlers(msg)) -> List(String) {
  handlers
  |> dict.keys
  |> list.filter_map(fn(handler_key) {
    case string.split_once(handler_key, ":") {
      Ok(#(name, _id)) -> Ok(name)
      Error(Nil) -> Error(Nil)
    }
  })
  |> list.unique
  |> list.sort(string.compare)
}

/// A short description of decode errors for log lines.
pub fn describe_errors(errors: List(decode.DecodeError)) -> String {
  errors
  |> list.map(fn(error) {
    "expected "
    <> error.expected
    <> ", found "
    <> error.found
    <> " at "
    <> case error.path {
      [] -> "the event"
      path -> string.join(path, ".")
    }
  })
  |> string.join("; ")
}

// --- Mapping ---

/// Map every event handler in a tree.
pub fn map_node(node: Node(a), f: fn(a) -> b) -> Node(b) {
  case node {
    Text(content) -> Text(content)
    Nothing -> Nothing
    RawHtml(html) -> RawHtml(html)
    Keyed(key, child) -> Keyed(key, map_node(child, f))
    Memo(key, deps, child) -> Memo(key, deps, map_node(child, f))
    Element(tag, attributes, children) ->
      Element(
        tag,
        list.map(attributes, map_attr(_, f)),
        list.map(children, map_node(_, f)),
      )
  }
}

/// Map an attribute's event handler. Plain attributes are unchanged.
pub fn map_attr(attr: Attr(a), f: fn(a) -> b) -> Attr(b) {
  case attr {
    Attribute(name, value) -> Attribute(name, value)
    NoAttribute -> NoAttribute
    Event(name, Handler(decoder, prevent, stop, debounce, throttle)) ->
      Event(
        name,
        Handler(decode.map(decoder, f), prevent, stop, debounce, throttle),
      )
  }
}

// --- Rendering ---

/// Render a tree to HTML and collect its handler table.
pub fn render(node: Node(msg)) -> #(String, Handlers(msg)) {
  let #(tree, handlers) = walk(node, "0", string_tree.new(), dict.new())
  #(string_tree.to_string(tree), handlers)
}

/// Render a tree to HTML without its handlers.
pub fn to_string(node: Node(msg)) -> String {
  render(node).0
}

fn walk(
  node: Node(msg),
  id: String,
  html: StringTree,
  handlers: Handlers(msg),
) -> #(StringTree, Handlers(msg)) {
  case node {
    Nothing -> #(html, handlers)
    RawHtml(raw) -> #(string_tree.append(html, raw), handlers)
    Text(content) -> #(string_tree.append(html, escape_html(content)), handlers)
    Keyed(key, child) -> walk(add_key(child, key), id, html, handlers)
    Memo(_key, _deps, child) -> walk(child, id, html, handlers)
    Element(tag, attributes, children) -> {
      // Invariant: `Element` is built only by `brazier/element.element` (and the
      // html/svg helpers that call it), which asserts the same check.
      let assert True = is_valid_tag_name(tag)
      let #(plain, events) = collect_attributes(attributes)
      let handlers =
        list.fold(events, handlers, fn(acc, event) {
          let #(name, handler) = event
          dict.insert(acc, key(name, id), handler)
        })
      let html =
        html
        |> string_tree.append("<")
        |> string_tree.append(tag)
        |> append_plain(plain)
        |> append_events(events, id)
        |> string_tree.append(">")
      case is_void_element(tag) {
        True -> #(html, handlers)
        False -> {
          let #(html, handlers, _index) =
            list.fold(children, #(html, handlers, 0), fn(acc, child) {
              let #(html, handlers, index) = acc
              let #(html, handlers) =
                walk(child, id <> "." <> int.to_string(index), html, handlers)
              #(html, handlers, index + 1)
            })
          #(
            html
              |> string_tree.append("</")
              |> string_tree.append(tag)
              |> string_tree.append(">"),
            handlers,
          )
        }
      }
    }
  }
}

/// Put `data-brazier-key` on the element under a keyed wrapper. An explicit
/// inner key wins over an outer one.
fn add_key(node: Node(msg), key: String) -> Node(msg) {
  case node {
    Element(tag, attributes, children) ->
      case has_attribute(attributes, "data-brazier-key") {
        True -> node
        False ->
          Element(
            tag,
            [Attribute("data-brazier-key", key), ..attributes],
            children,
          )
      }
    Keyed(inner, child) -> Keyed(inner, child)
    Memo(memo_key, deps, child) -> Memo(memo_key, deps, add_key(child, key))
    Text(_) | Nothing | RawHtml(_) -> node
  }
}

fn has_attribute(attributes: List(Attr(msg)), name: String) -> Bool {
  list.any(attributes, fn(attr) {
    case attr {
      Attribute(attr_name, _) -> attr_name == name
      Event(_, _) | NoAttribute -> False
    }
  })
}

/// Split attributes into plain name/value pairs and events.
///
/// Repeated `class` values are joined with a space and repeated `style`
/// values with `;`, at the position of the first occurrence (Lustre does the
/// same). For a repeated event name the last handler wins.
fn collect_attributes(
  attributes: List(Attr(msg)),
) -> #(List(#(String, String)), List(#(String, Handler(msg)))) {
  let #(plain, events) =
    list.fold(attributes, #([], []), fn(acc, attr) {
      let #(plain, events) = acc
      case attr {
        NoAttribute -> acc
        Attribute(name, value) ->
          case checked_value(name, value) {
            Error(Nil) -> acc
            Ok(value) -> #(merge_plain(plain, name, value), events)
          }
        Event(name, handler) -> {
          // Invariant: events are built only by `brazier/event.on`, which
          // asserts the same check.
          let assert True = is_valid_event_name(name)
          let others =
            list.filter(events, fn(entry: #(String, Handler(msg))) {
              entry.0 != name
            })
          #(plain, [#(name, handler), ..others])
        }
      }
    })
  #(list.reverse(plain), list.reverse(events))
}

/// `plain` is in reverse order.
fn merge_plain(
  plain: List(#(String, String)),
  name: String,
  value: String,
) -> List(#(String, String)) {
  let separator = case name {
    "class" -> Ok(" ")
    "style" -> Ok(";")
    _ -> Error(Nil)
  }
  case separator, list.key_find(plain, name) {
    Ok(separator), Ok(existing) ->
      list.map(plain, fn(pair) {
        case pair.0 == name {
          True -> #(name, existing <> separator <> value)
          False -> pair
        }
      })
    _, _ -> [#(name, value), ..plain]
  }
}

/// Apply the URL policy at render time. Every attribute built through
/// `brazier/attribute` has already been checked; this second check covers
/// values that reach the renderer some other way.
fn checked_value(name: String, value: String) -> Result(String, Nil) {
  case url.check(name, value) {
    Ok(value) -> Ok(value)
    Error(blocked) -> {
      log.warning(
        "brazier.render",
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

fn append_plain(
  html: StringTree,
  plain: List(#(String, String)),
) -> StringTree {
  list.fold(plain, html, fn(html, pair) {
    let #(name, value) = pair
    html
    |> string_tree.append(" ")
    |> string_tree.append(name)
    |> string_tree.append("=\"")
    |> string_tree.append(escape_attr(value))
    |> string_tree.append("\"")
  })
}

/// Each event becomes `data-brazier-on-<name>="<id>"`. A handler that
/// prevents the default action also gets `data-brazier-prevent-<name>`, so the
/// client can call `preventDefault` on an event fired before hydration.
fn append_events(
  html: StringTree,
  events: List(#(String, Handler(msg))),
  id: String,
) -> StringTree {
  list.fold(events, html, fn(html, event) {
    let #(name, handler) = event
    let html =
      html
      |> string_tree.append(" data-brazier-on-")
      |> string_tree.append(name)
      |> string_tree.append("=\"")
      |> string_tree.append(id)
      |> string_tree.append("\"")
    case handler.prevent_default {
      True ->
        html
        |> string_tree.append(" data-brazier-prevent-")
        |> string_tree.append(name)
        |> string_tree.append("=\"\"")
      False -> html
    }
  })
}

// --- Names and escaping ---

/// Whether `name` is safe to render as an attribute name. Inline event
/// attributes (`onclick`, `onload`, ...) are refused: events go through
/// `brazier/event`.
pub fn is_valid_attribute_name(name: String) -> Bool {
  name != ""
  && !string.starts_with(string.lowercase(name), "on")
  && list.all(string.to_graphemes(name), is_name_grapheme)
}

/// Whether `tag` is safe to render as a tag name.
pub fn is_valid_tag_name(tag: String) -> Bool {
  tag != "" && list.all(string.to_graphemes(tag), is_name_grapheme)
}

/// Whether `name` is safe to use as an event name. Event names become part
/// of an attribute name (`data-brazier-on-<name>`), so `:` is not allowed:
/// it separates the name from the id in a handler key.
pub fn is_valid_event_name(name: String) -> Bool {
  name != ""
  && list.all(string.to_graphemes(name), fn(grapheme) {
    grapheme != ":" && grapheme != "." && is_name_grapheme(grapheme)
  })
}

fn is_name_grapheme(grapheme: String) -> Bool {
  case grapheme {
    "-" | "_" | ":" | "." -> True
    _ ->
      case string.to_utf_codepoints(grapheme) {
        [codepoint] -> {
          let code = string.utf_codepoint_to_int(codepoint)
          { code >= 0x30 && code <= 0x39 }
          || { code >= 0x41 && code <= 0x5a }
          || { code >= 0x61 && code <= 0x7a }
        }
        _ -> False
      }
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

/// Escape text content.
pub fn escape_html(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
}

/// Escape an attribute value.
pub fn escape_attr(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("\"", "&quot;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
}
