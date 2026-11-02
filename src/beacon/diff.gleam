/// Beacon's VDOM diff engine.
/// Compares old and new element trees, producing a list of patches.
/// Patches are serialized to JSON and sent over the wire.
///
/// Reference: Lustre's vdom/diff.gleam for the algorithm,
/// LiveView's positional diff format for the wire protocol.
import beacon/element.{
  type Attr, type Node, ElementNode, EventAttr, HtmlAttr, KeyedNode, MemoNode,
  NoAttr, NoneNode, RawHtml, TextNode,
}
import gleam/json
import gleam/list

/// A patch describes a single change to apply to the DOM.
pub type Patch {
  /// Replace the text content of a text node.
  ReplaceText(path: List(Int), content: String)
  /// Replace an entire node at the given path.
  /// The node_json is the JSON representation of the new node.
  ReplaceNode(path: List(Int), node_json: json.Json)
  /// Insert a new child node at the given path and index.
  InsertChild(path: List(Int), index: Int, node_json: json.Json)
  /// Remove the child node at the given path and index.
  RemoveChild(path: List(Int), index: Int)
  /// Set an attribute on the node at the given path.
  SetAttribute(path: List(Int), name: String, value: String)
  /// Remove an attribute from the node at the given path.
  RemoveAttribute(path: List(Int), name: String)
  /// Set an event handler on the node at the given path.
  SetEvent(path: List(Int), event_name: String, handler_id: String)
  /// Remove an event handler from the node at the given path.
  RemoveEvent(path: List(Int), event_name: String)
}

/// Diff two element trees and produce a list of patches.
/// The path parameter tracks the position in the tree for patch targeting.
pub fn diff(old: Node(msg), new: Node(msg)) -> List(Patch) {
  diff_nodes(old, new, [])
}

/// Convert a list of patches to a JSON string for wire transport.
pub fn patches_to_json_string(patches: List(Patch)) -> String {
  json.array(patches, patch_to_json)
  |> json.to_string
}

/// Convert a list of patches to a JSON value.
pub fn patches_to_json(patches: List(Patch)) -> json.Json {
  json.array(patches, patch_to_json)
}

// --- Core diffing algorithm ---

fn diff_nodes(old: Node(msg), new: Node(msg), path: List(Int)) -> List(Patch) {
  case old, new {
    // Both NoneNodes — no change
    NoneNode, NoneNode -> []

    // Both RawHtml — check if content changed
    RawHtml(old_html), RawHtml(new_html) -> {
      case old_html == new_html {
        True -> []
        False -> [
          ReplaceNode(path: list.reverse(path), node_json: element.to_json(new)),
        ]
      }
    }

    // Both memo nodes with same key — compare deps to decide whether to diff
    MemoNode(old_key, old_deps, old_child),
      MemoNode(new_key, new_deps, new_child)
    -> {
      case old_key == new_key && old_deps == new_deps {
        // Same key + same deps → skip entirely (the optimization)
        True -> []
        // Deps changed → diff the children
        False -> diff_nodes(old_child, new_child, path)
      }
    }

    // Memo vs non-memo or vice versa — unwrap memo and diff the child
    MemoNode(_, _, old_child), _ -> diff_nodes(old_child, new, path)
    _, MemoNode(_, _, new_child) -> diff_nodes(old, new_child, path)
    KeyedNode(_, old_child), _ -> diff_nodes(old_child, new, path)
    _, KeyedNode(_, new_child) -> diff_nodes(old, new_child, path)

    // Both text nodes — check if content changed
    TextNode(old_content), TextNode(new_content) -> {
      case old_content == new_content {
        True -> []
        False -> [ReplaceText(path: list.reverse(path), content: new_content)]
      }
    }

    // Both element nodes with same tag — diff attributes and children
    ElementNode(old_tag, old_attrs, old_children),
      ElementNode(new_tag, new_attrs, new_children)
    -> {
      case old_tag == new_tag {
        True -> {
          let reversed_path = list.reverse(path)
          let attr_patches =
            diff_attributes(old_attrs, new_attrs, reversed_path)
          let child_patches = diff_children(old_children, new_children, path, 0)
          list.append(attr_patches, child_patches)
        }
        // Different tags — replace entirely
        False -> [
          ReplaceNode(path: list.reverse(path), node_json: element.to_json(new)),
        ]
      }
    }

    // Different node types — replace entirely
    _, _ -> [
      ReplaceNode(path: list.reverse(path), node_json: element.to_json(new)),
    ]
  }
}

/// Diff the children of two element nodes.
fn diff_children(
  old_children: List(Node(msg)),
  new_children: List(Node(msg)),
  parent_path: List(Int),
  index: Int,
) -> List(Patch) {
  case old_children, new_children {
    // Both lists exhausted — no more changes
    [], [] -> []

    // Old has more children — remove excess
    [_, ..old_rest], [] -> {
      let reversed_path = list.reverse(parent_path)
      let remove = RemoveChild(path: reversed_path, index: index)
      [remove, ..diff_children(old_rest, [], parent_path, index)]
    }

    // New has more children — insert new ones
    [], [new_child, ..new_rest] -> {
      let reversed_path = list.reverse(parent_path)
      let insert =
        InsertChild(
          path: reversed_path,
          index: index,
          node_json: element.to_json(new_child),
        )
      [insert, ..diff_children([], new_rest, parent_path, index + 1)]
    }

    // Both have children — diff recursively
    [old_child, ..old_rest], [new_child, ..new_rest] -> {
      let child_path = [index, ..parent_path]
      let child_patches = diff_nodes(old_child, new_child, child_path)
      let rest_patches =
        diff_children(old_rest, new_rest, parent_path, index + 1)
      list.append(child_patches, rest_patches)
    }
  }
}

/// Diff attributes between old and new element nodes.
fn diff_attributes(
  old_attrs: List(Attr),
  new_attrs: List(Attr),
  path: List(Int),
) -> List(Patch) {
  let removed = find_removed_attrs(old_attrs, new_attrs, path)
  let added_or_changed = find_added_or_changed_attrs(old_attrs, new_attrs, path)
  list.append(removed, added_or_changed)
}

/// Find attributes that were in old but not in new.
fn find_removed_attrs(
  old_attrs: List(Attr),
  new_attrs: List(Attr),
  path: List(Int),
) -> List(Patch) {
  list.filter_map(old_attrs, fn(old_attr) {
    case attr_exists_in(old_attr, new_attrs) {
      True -> Error(Nil)
      False ->
        case old_attr {
          HtmlAttr(name, _) -> Ok(RemoveAttribute(path: path, name: name))
          EventAttr(event_name, _, _) ->
            Ok(RemoveEvent(path: path, event_name: event_name))
          NoAttr -> Error(Nil)
        }
    }
  })
}

/// Find attributes that are new or have changed values.
fn find_added_or_changed_attrs(
  old_attrs: List(Attr),
  new_attrs: List(Attr),
  path: List(Int),
) -> List(Patch) {
  list.filter_map(new_attrs, fn(new_attr) {
    case attr_unchanged_in(new_attr, old_attrs) {
      True -> Error(Nil)
      False ->
        case new_attr {
          NoAttr -> Error(Nil)
          HtmlAttr(name, value) ->
            case element.checked_value(name, value) {
              Ok(value) ->
                Ok(SetAttribute(path: path, name: name, value: value))
              Error(Nil) -> Ok(RemoveAttribute(path: path, name: name))
            }
          EventAttr(event_name, handler_id, _) -> {
            Ok(SetEvent(
              path: path,
              event_name: event_name,
              handler_id: handler_id,
            ))
          }
        }
    }
  })
}

/// Check if an attribute with the same name exists in a list.
fn attr_exists_in(attr: Attr, attrs: List(Attr)) -> Bool {
  list.any(attrs, fn(a) { attr_same_key(attr, a) })
}

/// Check if an attribute with the same name AND value exists in a list.
fn attr_unchanged_in(attr: Attr, attrs: List(Attr)) -> Bool {
  list.any(attrs, fn(a) { attr == a })
}

/// Check if two attributes have the same key/name.
fn attr_same_key(a: Attr, b: Attr) -> Bool {
  case a, b {
    HtmlAttr(name_a, _), HtmlAttr(name_b, _) -> name_a == name_b
    EventAttr(event_a, _, _), EventAttr(event_b, _, _) -> event_a == event_b
    _, _ -> False
  }
}

// --- JSON serialization ---

fn patch_to_json(patch: Patch) -> json.Json {
  case patch {
    ReplaceText(path, content) ->
      json.object([
        #("op", json.string("replace_text")),
        #("path", path_to_json(path)),
        #("content", json.string(content)),
      ])
    ReplaceNode(path, node_json) ->
      json.object([
        #("op", json.string("replace_node")),
        #("path", path_to_json(path)),
        #("node", node_json),
      ])
    InsertChild(path, index, node_json) ->
      json.object([
        #("op", json.string("insert_child")),
        #("path", path_to_json(path)),
        #("index", json.int(index)),
        #("node", node_json),
      ])
    RemoveChild(path, index) ->
      json.object([
        #("op", json.string("remove_child")),
        #("path", path_to_json(path)),
        #("index", json.int(index)),
      ])
    SetAttribute(path, name, value) ->
      json.object([
        #("op", json.string("set_attr")),
        #("path", path_to_json(path)),
        #("name", json.string(name)),
        #("value", json.string(value)),
      ])
    RemoveAttribute(path, name) ->
      json.object([
        #("op", json.string("remove_attr")),
        #("path", path_to_json(path)),
        #("name", json.string(name)),
      ])
    SetEvent(path, event_name, handler_id) ->
      json.object([
        #("op", json.string("set_event")),
        #("path", path_to_json(path)),
        #("event", json.string(event_name)),
        #("handler", json.string(handler_id)),
      ])
    RemoveEvent(path, event_name) ->
      json.object([
        #("op", json.string("remove_event")),
        #("path", path_to_json(path)),
        #("event", json.string(event_name)),
      ])
  }
}

fn path_to_json(path: List(Int)) -> json.Json {
  json.array(path, json.int)
}
