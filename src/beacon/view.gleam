/// View helper — converts a Node tree into a Rendered struct by splitting
/// static HTML structure from dynamic text content.
///
/// This is the bridge between Beacon's VDOM (Node) and LiveView-style
/// wire optimization (Rendered). Static HTML is sent once on mount;
/// on subsequent updates only changed dynamic values are sent.
///
/// Reference: LiveView HEEx compile-time splitting,
/// Architecture doc section 9 (Build-Time Template Analysis).
import beacon/element.{
  type Attr, type Node, ElementNode, EventAttr, HtmlAttr, KeyedNode, MemoNode,
  NoneNode, RawHtml, TextNode,
}
import beacon/template/rendered.{type Rendered}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/string_tree.{type StringTree}

/// Convert a Node tree into a Rendered struct.
/// Walks the tree, collecting static HTML strings and dynamic text values.
///
/// Static parts: opening/closing tags, attribute markup, event attribute markup.
/// Dynamic parts: TextNode content (these are the values that change between renders).
///
/// Example:
///   `el("div", [], [text("hello")])`
///   → statics: ["<div>", "</div>"], dynamics: ["hello"]
///
///   `el("div", [], [text("Count: "), text("5")])`
///   → statics: ["<div>", "", "</div>"], dynamics: ["Count: ", "5"]
pub fn render(node: Node(msg)) -> Rendered {
  let state = do_render(node, new_state())
  let statics = finish_static(state)
  rendered.build(statics, list.reverse(state.dynamics))
}

/// Internal accumulator state for the render walk.
type RenderState {
  RenderState(
    /// Accumulated static string fragments (in reverse order).
    statics: List(String),
    /// Current static buffer being built.
    current_static: StringTree,
    /// Accumulated dynamic values (in reverse order).
    dynamics: List(String),
  )
}

fn new_state() -> RenderState {
  RenderState(statics: [], current_static: string_tree.new(), dynamics: [])
}

/// Flush the current static buffer to the statics list and start a new one.
/// Called when we encounter a dynamic value (TextNode).
fn flush_static(state: RenderState) -> RenderState {
  let static_str = string_tree.to_string(state.current_static)
  RenderState(
    statics: [static_str, ..state.statics],
    current_static: string_tree.new(),
    dynamics: state.dynamics,
  )
}

/// Append to the current static buffer.
fn append_static(state: RenderState, s: String) -> RenderState {
  RenderState(
    ..state,
    current_static: string_tree.append(state.current_static, s),
  )
}

/// Add a dynamic value and flush the current static.
fn add_dynamic(state: RenderState, value: String) -> RenderState {
  let flushed = flush_static(state)
  RenderState(..flushed, dynamics: [value, ..flushed.dynamics])
}

/// Finalize: flush the last static buffer and reverse the list.
fn finish_static(state: RenderState) -> List(String) {
  let final_static = string_tree.to_string(state.current_static)
  list.reverse([final_static, ..state.statics])
}

/// Recursively walk a Node tree, splitting into statics and dynamics.
fn do_render(node: Node(msg), state: RenderState) -> RenderState {
  case node {
    NoneNode -> {
      // Empty node — renders nothing, contributes no static or dynamic content
      state
    }

    RawHtml(html) -> {
      // Raw HTML is DYNAMIC — it's injected without escaping and may change
      add_dynamic(state, html)
    }

    TextNode(content) -> {
      // Text content is DYNAMIC — it may change between renders
      add_dynamic(state, content)
    }

    KeyedNode(key, child) -> {
      do_render(
        case child {
          ElementNode(tag, attributes, children) ->
            ElementNode(
              tag: tag,
              attributes: [HtmlAttr("data-beacon-key", key), ..attributes],
              children: children,
            )
          other -> other
        },
        state,
      )
    }

    ElementNode(tag, attributes, children) -> {
      // Opening tag is STATIC
      let state = append_static(state, "<" <> tag)

      // Attributes are STATIC (they're part of the template structure)
      let state = render_attrs(state, attributes)

      case is_void_element(tag) {
        True -> append_static(state, ">")
        False -> {
          let state = append_static(state, ">")
          // Render children
          let state = render_children(state, children)
          // Closing tag is STATIC
          append_static(state, "</" <> tag <> ">")
        }
      }
    }

    MemoNode(_key, _deps, child) -> {
      // Memo is transparent — render the child
      do_render(child, state)
    }
  }
}

/// Render a list of children.
fn render_children(
  state: RenderState,
  children: List(Node(msg)),
) -> RenderState {
  list.fold(children, state, fn(acc, child) { do_render(child, acc) })
}

/// Render attributes into static/dynamic parts.
/// Event attributes (handler IDs) are STATIC — they don't change between renders.
/// HTML attributes are DYNAMIC — their values may change (e.g., value="...", class="...").
/// This ensures fingerprints stay stable across renders, so only changed
/// attribute values are sent as diffs (not the entire template).
fn render_attrs(state: RenderState, attrs: List(Attr)) -> RenderState {
  list.fold(attrs, state, fn(acc, attr) {
    case attr {
      HtmlAttr(name, value) ->
        // Attribute VALUE is dynamic — name is static
        acc
        |> append_static(" " <> name <> "=\"")
        |> add_dynamic(escape_attr(value))
        |> append_static("\"")
      EventAttr(event_name, handler_id, debounce_ms) -> {
        // Event handlers are static — they don't change between renders
        let with_event =
          acc
          |> append_static(
            " data-beacon-event-" <> event_name <> "=\"" <> handler_id <> "\"",
          )
        case debounce_ms {
          Some(delay) if event_name == "input" ->
            with_event
            |> append_static(
              " data-beacon-input-debounce=\"" <> int.to_string(delay) <> "\"",
            )
          _ -> with_event
        }
      }
    }
  })
}

/// Check if a tag is a void element (no closing tag).
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

/// Escape HTML attribute values.
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
