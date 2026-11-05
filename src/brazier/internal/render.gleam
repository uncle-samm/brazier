/// The rendering core shared by the server and the browser.
///
/// `brazier/element` and `brazier/attribute` wrap the types defined here in
/// opaque types. This module walks a tree once and produces the HTML string
/// together with the table of event handlers, keyed by event name and the
/// element's position in the tree.
///
/// Position ids are the child indices from the root, joined with `.`: the
/// root element is `"0"`, its second child is `"0.1"`. Keyed nodes are
/// transparent and do not add a level. Every child consumes an index,
/// including text and `none`, so a conditional `none` does not shift its
/// siblings' ids. The same tree therefore yields the same ids on the server
/// and in the browser, which is what lets an event fired before hydration be
/// replayed against the handler table built after it.
///
/// The module is target-neutral: it is compiled to JavaScript for the
/// client bundle and to Erlang for SSR. Name checks and escaping, which run
/// for every node, are in `brazier_render_ffi` on each target.
///
/// A stream (`brazier/stream.render`) renders as its container element,
/// with `data-brazier-stream="<name>"`, and lists the container in the
/// render's container table. Its items are rendered one by one with
/// `render_item`, whose handler ids are relative to the item's root and
/// start with `i` (`"i0"`, `"i0.2"`), so an item's HTML and handler table do
/// not depend on where the item is in the stream (docs/design/STREAMS.md
/// 8.2). SSR fills each container with its items (`render_filled`); the
/// client renders it empty and lets the stream applier fill it.
///
/// Reference: Lustre's `vdom/vnode` and `vdom/vattr`, LiveView's
/// `phx-click` bindings, LiveView's `phx-update="stream"` containers.
import brazier/internal/stream_op
import brazier/internal/url
import brazier/log
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
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
  /// Renders nothing.
  Nothing
  /// HTML injected without escaping or URL checks.
  RawHtml(html: String)
  /// A stream's container: a `tag` element holding the stream's items,
  /// built by `brazier/stream.render`. `item` decodes one item's JSON and
  /// renders it; `element.map` composes onto it. `item_ref` is the identity
  /// of the app's item function, for comparison only (see `Container`).
  Stream(
    name: String,
    limit: stream_op.Limit,
    tag: String,
    attributes: List(Attr(msg)),
    item: fn(Dynamic) -> Result(Node(msg), String),
    item_ref: Dynamic,
  )
}

/// A stream container met by a render, in document order.
///
/// `item_ref` is the app's item function as it was passed to
/// `stream.render`, never called: two renders of the same stream compare
/// their `item_ref`s to tell whether the items must be rendered again.
/// `element.map` does not change it, so the same item function under two
/// different `element.map`s compares equal.
pub type Container(msg) {
  Container(
    name: String,
    limit: stream_op.Limit,
    item: fn(Dynamic) -> Result(Node(msg), String),
    item_ref: Dynamic,
  )
}

/// `value` as a `Dynamic`, unchanged. `brazier/stream.render` uses it for a
/// container's `item_ref`.
@external(erlang, "brazier_render_ffi", "identity")
@external(javascript, "../../brazier_render_ffi.mjs", "identity")
pub fn item_ref(value: a) -> Dynamic

/// An attribute of an element.
pub type Attr(msg) {
  /// A plain HTML attribute.
  Attribute(name: String, value: String)
  /// An event listener.
  Event(name: String, handler: Handler(msg))
  /// An `<iframe srcdoc>` document from `attribute.unsafe_srcdoc`. It
  /// renders as `srcdoc`, which the name policy refuses for `Attribute`; the
  /// value is escaped like any attribute value.
  UnsafeSrcdoc(html: String)
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

/// The handler table of one render, with the distinct event names in it.
/// The walk that fills the table collects the names as it inserts each
/// handler, so the client knows which events to listen for without walking
/// the table again after every render.
pub opaque type Handlers(msg) {
  Handlers(table: Dict(String, Handler(msg)), names: List(String))
}

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
  dict.get(handlers.table, key(name, id))
}

/// The keys of a handler table (`key(name, id)`), sorted.
pub fn keys(handlers: Handlers(msg)) -> List(String) {
  dict.keys(handlers.table) |> list.sort(string.compare)
}

/// Run a handler's decoder against an event object.
pub fn run(
  handler: Handler(msg),
  event: Dynamic,
) -> Result(msg, List(decode.DecodeError)) {
  decode.run(event, handler.decoder)
}

/// The distinct event names in a handler table, sorted. The render that
/// built the table collected them; this reads no handler.
pub fn event_names(handlers: Handlers(msg)) -> List(String) {
  handlers.names
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
    Element(tag, attributes, children) ->
      Element(
        tag,
        list.map(attributes, map_attr(_, f)),
        list.map(children, map_node(_, f)),
      )
    Stream(name, limit, tag, attributes, item, item_ref) ->
      Stream(
        name: name,
        limit: limit,
        tag: tag,
        attributes: list.map(attributes, map_attr(_, f)),
        item: fn(value) { result.map(item(value), map_node(_, f)) },
        item_ref: item_ref,
      )
  }
}

/// Map an attribute's event handler. Plain attributes are unchanged.
pub fn map_attr(attr: Attr(a), f: fn(a) -> b) -> Attr(b) {
  case attr {
    Attribute(name, value) -> Attribute(name, value)
    UnsafeSrcdoc(html) -> UnsafeSrcdoc(html)
    NoAttribute -> NoAttribute
    Event(name, Handler(decoder, prevent, stop, debounce, throttle)) ->
      Event(
        name,
        Handler(decode.map(decoder, f), prevent, stop, debounce, throttle),
      )
  }
}

// --- Rendering ---

/// Render a tree to HTML and collect its handler table. A stream renders
/// as its empty container.
pub fn render(node: Node(msg)) -> #(String, Handlers(msg)) {
  let #(html, handlers, _containers) = render_containers(node)
  #(html, handlers)
}

/// Render a tree to HTML without its handlers.
pub fn to_string(node: Node(msg)) -> String {
  render(node).0
}

/// Render a tree to HTML, with its handler table and its stream
/// containers in document order. Each container is rendered empty.
///
/// Crashes when the tree renders the same stream twice: a stream is
/// rendered at most once per view (docs/design/STREAMS.md 5.3).
pub fn render_containers(
  node: Node(msg),
) -> #(String, Handlers(msg), List(Container(msg))) {
  let done = walk(node, "0", View(fill: empty_fill), new_walk())
  // Invariant: in a view, only `fill` records a fault, and `empty_fill`
  // never fails.
  let assert [] = done.faults
    as "brazier/internal/render: an empty render recorded a fault"
  #(tree_to_string(done.html), finish(done), list.reverse(done.containers))
}

/// Render a tree to HTML, each stream container holding the HTML `fill`
/// gives it. `Error` with every reason `fill` gave, joined with `; `, when
/// it failed for a container.
///
/// Crashes when the tree renders the same stream twice, as
/// `render_containers` does.
pub fn render_filled(
  node: Node(msg),
  fill: fn(Container(msg)) -> Result(String, String),
) -> Result(String, String) {
  let done = walk(node, "0", View(fill: fill), new_walk())
  case done.faults {
    [] -> Ok(tree_to_string(done.html))
    faults -> Error(string.join(list.reverse(faults), "; "))
  }
}

/// Render one item of `container`: decode `item` with the container's item
/// function and render it with its root keyed `key`. Handler ids are
/// relative to the item's root and start with `i` (`"i0"`, `"i0.2"`), and
/// the handler table is the item's own (docs/design/STREAMS.md 8.2).
///
/// `Error` when the item does not decode, when its root is not one element
/// (text, `none`, raw HTML, a keyed node or a stream), when the root sets
/// its own `data-brazier-key`, or when the item renders a stream. The
/// server renders SSR items and the client renders inserted items with this
/// function, so the two give the same HTML.
pub fn render_item(
  container: Container(msg),
  key: String,
  item: Dynamic,
) -> Result(#(String, Handlers(msg)), String) {
  let prefix = "stream " <> container.name <> ", item " <> key <> ": "
  use root <- result.try(
    container.item(item)
    |> result.map_error(fn(reason) { prefix <> "does not decode: " <> reason }),
  )
  case root {
    Element(tag, attributes, children) ->
      case has_attribute(attributes, "data-brazier-key") {
        True ->
          Error(
            prefix
            <> "the item's root sets data-brazier-key; the stream keys it",
          )
        False -> {
          let keyed =
            Element(
              tag,
              [Attribute("data-brazier-key", key), ..attributes],
              children,
            )
          let done = walk(keyed, "i0", InItem, new_walk())
          case done.faults {
            [] -> Ok(#(tree_to_string(done.html), finish(done)))
            faults -> Error(prefix <> string.join(list.reverse(faults), "; "))
          }
        }
      }
    Text(_) ->
      Error(prefix <> "the item's root is text; it must be one element")
    Nothing ->
      Error(prefix <> "the item's root is element.none; it must be one element")
    RawHtml(_) ->
      Error(
        prefix <> "the item's root is unsafe_raw_html; it must be one element",
      )
    Keyed(_, _) ->
      Error(
        prefix
        <> "the item's root is element.keyed; the stream keys the root itself",
      )
    Stream(name, ..) ->
      Error(prefix <> "the item's root is the stream " <> name)
  }
}

/// Where a walk is.
type Mode(msg) {
  /// In a view: a stream renders as its container, holding what `fill`
  /// gives it.
  View(fill: fn(Container(msg)) -> Result(String, String))
  /// In a stream's item: a stream is a fault.
  InItem
}

/// What a walk has built so far. `names` holds each event name in
/// `handlers` once, unsorted. `containers` and `faults` are in reverse
/// order.
type Walk(msg) {
  Walk(
    html: StringTree,
    handlers: Dict(String, Handler(msg)),
    names: List(String),
    containers: List(Container(msg)),
    faults: List(String),
  )
}

/// The handler table a walk built, its event names sorted.
fn finish(done: Walk(msg)) -> Handlers(msg) {
  Handlers(table: done.handlers, names: list.sort(done.names, string.compare))
}

/// The HTML a walk built. A walk appends only strings to its tree.
///
/// On Erlang a `StringTree` of strings is an iolist of UTF-8 binaries, and
/// `brazier_render_ffi:iodata_to_string` flattens it without checking the
/// UTF-8 again. `string_tree.to_string` checks it, and on a big page that
/// check grows faster than the page (10,000 rows rendered in 110 ms with
/// it, 45 ms without). On JavaScript a tree is already a string.
@external(erlang, "brazier_render_ffi", "iodata_to_string")
fn tree_to_string(tree: StringTree) -> String {
  string_tree.to_string(tree)
}

fn new_walk() -> Walk(msg) {
  Walk(
    html: string_tree.new(),
    handlers: dict.new(),
    names: [],
    containers: [],
    faults: [],
  )
}

fn empty_fill(_container: Container(msg)) -> Result(String, String) {
  Ok("")
}

fn walk(
  node: Node(msg),
  id: String,
  mode: Mode(msg),
  acc: Walk(msg),
) -> Walk(msg) {
  case node {
    Nothing -> acc
    RawHtml(raw) -> Walk(..acc, html: string_tree.append(acc.html, raw))
    Text(content) ->
      Walk(..acc, html: string_tree.append(acc.html, escape_html(content)))
    Keyed(key, child) -> walk(add_key(child, key), id, mode, acc)
    Element(tag, attributes, children) -> {
      let acc = open_tag(acc, tag, [], attributes, id)
      case is_void_element(tag) {
        True -> acc
        False -> {
          let #(acc, _index) =
            list.fold(children, #(acc, 0), fn(state, child) {
              let #(acc, index) = state
              let acc =
                walk(child, id <> "." <> int.to_string(index), mode, acc)
              #(acc, index + 1)
            })
          close_tag(acc, tag)
        }
      }
    }
    Stream(name, limit, tag, attributes, item, item_ref) ->
      case mode {
        InItem ->
          Walk(..acc, faults: [
            "the item renders the stream " <> name <> " inside it",
            ..acc.faults
          ])
        View(fill) -> {
          // Invariant: a stream's items are children of its container, so
          // the container must be able to hold children.
          let assert False = is_void_element(tag)
            as "brazier/internal/render: a stream's container cannot be a void element"
          // The stream sets `stream_attribute` itself; the name policy
          // refuses it in `attributes` (`collect_attributes`).
          // Invariant: the client keeps one store per stream and patches its
          // one container (docs/design/STREAMS.md 5.3).
          let assert False =
            list.any(acc.containers, fn(container) { container.name == name })
            as "brazier/internal/render: a stream is rendered at most once per view"
          let container =
            Container(name: name, limit: limit, item: item, item_ref: item_ref)
          let acc =
            open_tag(acc, tag, [#(stream_attribute, name)], attributes, id)
          let acc = Walk(..acc, containers: [container, ..acc.containers])
          let acc = case fill(container) {
            Ok(inner) -> Walk(..acc, html: string_tree.append(acc.html, inner))
            Error(reason) -> Walk(..acc, faults: [reason, ..acc.faults])
          }
          close_tag(acc, tag)
        }
      }
  }
}

/// Append `<tag own attributes>` and record the element's handlers under
/// `id`. `own` are the attributes the renderer sets itself, which the name
/// policy refuses in `attributes` (a stream container's
/// `stream_attribute`).
fn open_tag(
  acc: Walk(msg),
  tag: String,
  own: List(#(String, String)),
  attributes: List(Attr(msg)),
  id: String,
) -> Walk(msg) {
  // Invariant: `brazier/element.element` (and the html/svg helpers that
  // call it) asserts the same check. The constructors of this module are
  // public, so a tree built directly is checked again here: a tag that
  // could break out of the markup is a bug in the view.
  let assert True = is_valid_tag_name(tag)
    as "brazier/internal/render: tag names are a-z A-Z 0-9 - _ : ."
  let #(plain, events) = collect_attributes(attributes)
  let #(handlers, names) =
    list.fold(events, #(acc.handlers, acc.names), fn(state, event) {
      let #(handlers, names) = state
      let #(name, handler) = event
      let handlers = dict.insert(handlers, key(name, id), handler)
      // A view has a few distinct event names and many handlers, so the
      // list stays short.
      case list.contains(names, name) {
        True -> #(handlers, names)
        False -> #(handlers, [name, ..names])
      }
    })
  let html =
    acc.html
    |> string_tree.append("<")
    |> string_tree.append(tag)
    |> append_plain(own)
    |> append_plain(plain)
    |> append_events(events, id)
    |> string_tree.append(">")
  Walk(..acc, html: html, handlers: handlers, names: names)
}

fn close_tag(acc: Walk(msg), tag: String) -> Walk(msg) {
  Walk(
    ..acc,
    html: acc.html
      |> string_tree.append("</")
      |> string_tree.append(tag)
      |> string_tree.append(">"),
  )
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
    Stream(name, limit, tag, attributes, item, item_ref) ->
      case has_attribute(attributes, "data-brazier-key") {
        True -> node
        False ->
          Stream(
            name: name,
            limit: limit,
            tag: tag,
            attributes: [Attribute("data-brazier-key", key), ..attributes],
            item: item,
            item_ref: item_ref,
          )
      }
    Keyed(inner, child) -> Keyed(inner, child)
    Text(_) | Nothing | RawHtml(_) -> node
  }
}

fn has_attribute(attributes: List(Attr(msg)), name: String) -> Bool {
  list.any(attributes, fn(attr) {
    case attr {
      Attribute(attr_name, _) -> attr_name == name
      UnsafeSrcdoc(_) -> name == "srcdoc"
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
        UnsafeSrcdoc(html) -> #(merge_plain(plain, "srcdoc", html), events)
        Attribute(name, value) -> {
          // Invariant: `brazier/attribute.attribute` asserts the same check.
          // The constructors of this module are public, so an attribute
          // built directly is checked again here: an inline event handler,
          // `srcdoc` or an animation of `href` is a bug in the view.
          let assert True = is_allowed_attribute(name, value)
            as "brazier/internal/render: attribute refused by the name policy (on*, srcdoc, data-brazier-stream, attributeName=href, or characters outside a-z A-Z 0-9 - _ : .)"
          case checked_value(name, value) {
            Error(Nil) -> acc
            Ok(value) -> #(merge_plain(plain, name, value), events)
          }
        }
        Event(name, handler) -> {
          // Invariant: `brazier/event.on` asserts the same check. The
          // constructors of this module are public, so an event built
          // directly is checked again here.
          let assert True = is_valid_event_name(name)
            as "brazier/internal/render: event names are a-z A-Z 0-9 - _"
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

/// Whether `name` is safe to render as an attribute name: one or more of
/// `a-z A-Z 0-9 - _ : .`, and not refused by name. Matching is
/// case-insensitive, as HTML attribute names are. Refused:
///
/// - inline event attributes (`onclick`, `onload`, ...): events go through
///   `brazier/event`;
/// - `srcdoc`, whose value is a whole HTML document that runs with the
///   page's origin unless the iframe is sandboxed. Use
///   `attribute.unsafe_srcdoc`;
/// - `stream_attribute` (`data-brazier-stream`), which only a stream's
///   container carries.
pub fn is_valid_attribute_name(name: String) -> Bool {
  is_markup_name(name) && !is_refused_name(ascii_lowercase(name))
}

/// The attribute that marks a stream's container. Only the render of a
/// `Stream` node sets it: the client applies a stream's ops to the element
/// that carries it, so the name policy refuses it, in any case, on every
/// attribute a view builds (docs/design/STREAMS.md 7.5).
pub const stream_attribute = "data-brazier-stream"

/// Whether attribute `name` may carry `value`: the name is valid
/// (`is_valid_attribute_name`), and the
/// attribute is not an SVG animation target of `href` or `xlink:href`. An
/// `<animate>` or `<set>` with `attributeName="href"` rewrites a link's URL
/// in the browser after the URL policy has checked it, so any
/// `attributeName` whose value contains `href` (in any case) is refused.
///
/// Reference: DOMPurify refuses `attributeName` values matching `href`
/// (GHSA-c6gr-qvv4-5v3f).
pub fn is_allowed_attribute(name: String, value: String) -> Bool {
  is_markup_name(name)
  && {
    let lower = ascii_lowercase(name)
    !is_refused_name(lower)
    && !{
      lower == "attributename"
      && string.contains(string.lowercase(value), "href")
    }
  }
}

/// `lower` is an ASCII-only lowercase name.
fn is_refused_name(lower: String) -> Bool {
  string.starts_with(lower, "on")
  || lower == "srcdoc"
  || lower == stream_attribute
}

/// Whether `tag` is safe to render as a tag name: one or more of
/// `a-z A-Z 0-9 - _ : .`.
pub fn is_valid_tag_name(tag: String) -> Bool {
  is_markup_name(tag)
}

/// Whether `name` is safe to use as an event name: one or more of
/// `a-z A-Z 0-9 - _`. Event names become part of an attribute name
/// (`data-brazier-on-<name>`), so `:` is not allowed: it separates the name
/// from the id in a handler key.
pub fn is_valid_event_name(name: String) -> Bool {
  is_event_name(name)
}

/// `name` with `A-Z` lowercased and every other byte (code unit on
/// JavaScript) unchanged. A name without `A-Z` is returned as it is.
///
/// Callers pass names `is_markup_name` accepted, which are ASCII, so this is
/// `string.lowercase` for them. It runs for every attribute of every render;
/// on Erlang `string.lowercase` (OTP's `string:lowercase/1`) raises and
/// catches an exception internally for each name that is already lowercase,
/// which costs about 0.1 µs a name.
@external(erlang, "brazier_render_ffi", "ascii_lowercase")
@external(javascript, "../../brazier_render_ffi.mjs", "ascii_lowercase")
fn ascii_lowercase(name: String) -> String

/// One or more of `a-z A-Z 0-9 - _ : .`, scanned byte by byte (code unit by
/// code unit on JavaScript): every non-ASCII character refuses the name.
@external(erlang, "brazier_render_ffi", "is_markup_name")
@external(javascript, "../../brazier_render_ffi.mjs", "is_markup_name")
fn is_markup_name(name: String) -> Bool

/// One or more of `a-z A-Z 0-9 - _`, scanned like `is_markup_name`.
@external(erlang, "brazier_render_ffi", "is_event_name")
@external(javascript, "../../brazier_render_ffi.mjs", "is_event_name")
fn is_event_name(name: String) -> Bool

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

/// Escape text content: `&`, `<` and `>`. A text with none of them is
/// returned as it is; otherwise the escape is one pass.
@external(erlang, "brazier_render_ffi", "escape_html")
@external(javascript, "../../brazier_render_ffi.mjs", "escape_html")
pub fn escape_html(text: String) -> String

/// Escape an attribute value: `&`, `"`, `<` and `>`. Values are always
/// double-quoted, so `'` is left as it is.
@external(erlang, "brazier_render_ffi", "escape_attr")
@external(javascript, "../../brazier_render_ffi.mjs", "escape_attr")
pub fn escape_attr(text: String) -> String
