/// Attributes of view elements.
///
/// `Attribute(msg)` is either a plain HTML attribute or an event listener
/// (built with `brazier/event`). Attributes whose value the browser treats as
/// a URL go through the URL policy in `brazier/internal/url`: a refused value
/// drops the attribute and logs a warning.
///
/// Reference: Lustre's `lustre/attribute`.
import brazier/internal/render
import brazier/internal/url
import brazier/log
import gleam/int
import gleam/list
import gleam/string

/// An attribute or event listener on an element.
pub opaque type Attribute(msg) {
  Attribute(attr: render.Attr(msg))
}

@internal
pub fn to_attr(attribute: Attribute(msg)) -> render.Attr(msg) {
  attribute.attr
}

@internal
pub fn from_attr(attr: render.Attr(msg)) -> Attribute(msg) {
  Attribute(attr)
}

/// An attribute with any name.
///
/// These are programming errors and crash:
///
/// - an inline event attribute such as `onclick`: use `brazier/event`;
/// - `srcdoc`: use `unsafe_srcdoc`;
/// - a `data-brazier-*` name, which Brazier's client reads and only the
///   render sets (`data-brazier-key` for `element.keyed`,
///   `data-brazier-stream` for `brazier/stream.render`,
///   `data-brazier-on-*` for `brazier/event`, and the others the client
///   uses). Four are app API and allowed: `data-brazier-hook` (`hook`),
///   `data-brazier-hook-watch` (`watch`),
///   `data-brazier-preserve-children` (`ignore_updates`) and
///   `data-brazier-external` (a link the client does not navigate);
/// - `attributeName` with a value containing `href` (`href`,
///   `xlink:href`): an SVG `<animate>` or `<set>` targeting a link's URL
///   would change it after the URL policy has checked it;
/// - a name with characters outside `a-z A-Z 0-9 - _ : .`.
///
/// Names match case-insensitively, as HTML attribute names do.
///
/// URL attributes (`href`, `src`, `action`, `formaction`, `poster`, `cite`,
/// `xlink:href`) go through the URL policy. A refused value produces no
/// attribute and logs a warning.
pub fn attribute(name: String, value: String) -> Attribute(msg) {
  // Invariant: attribute names come from application code, not user input.
  // An inline event handler, `srcdoc`, a reserved `data-brazier-*` name, an
  // animation of `href` or a name that could break out of the tag is a bug
  // in the view, so it crashes rather than rendering.
  let assert True = render.is_allowed_attribute(name, value)
    as "brazier/attribute.attribute: attribute refused by the name policy (on*, srcdoc, data-brazier-* other than -hook, -hook-watch, -preserve-children and -external, attributeName=href, or characters outside a-z A-Z 0-9 - _ : .)"
  case url.check(name, value) {
    Ok(value) -> Attribute(render.Attribute(name, value))
    Error(blocked) -> {
      log.warning(
        "brazier.attribute",
        "Dropped attribute "
          <> name
          <> "=\""
          <> url.truncate_for_log(value)
          <> "\": "
          <> url.describe(blocked),
      )
      Attribute(render.NoAttribute)
    }
  }
}

/// An `<iframe>` `srcdoc` attribute: `html` is the whole document the
/// iframe shows. Its markup is not escaped or checked, and unless the
/// iframe has a `sandbox` attribute without `allow-scripts` and
/// `allow-same-origin` together, its scripts run with the page's origin.
/// Like `element.unsafe_raw_html`, never pass it text that a user controls.
///
/// The value is attribute-escaped, as every value is; the browser decodes
/// it back to `html`.
pub fn unsafe_srcdoc(html: String) -> Attribute(msg) {
  Attribute(render.UnsafeSrcdoc(html))
}

/// An attribute that renders nothing.
pub fn none() -> Attribute(msg) {
  Attribute(render.NoAttribute)
}

/// Map the message of an event listener. Plain attributes are unchanged.
pub fn map(attribute: Attribute(a), f: fn(a) -> b) -> Attribute(b) {
  Attribute(render.map_attr(attribute.attr, f))
}

/// A boolean attribute: present with an empty value when `on` is true,
/// absent otherwise. A name `attribute` refuses crashes either way.
pub fn boolean(name: String, on: Bool) -> Attribute(msg) {
  // Invariant: as in `attribute`, a refused name is a bug in the view. It
  // is checked when `on` is false too, so the bug does not wait for the
  // model to turn the attribute on.
  let assert True = render.is_allowed_attribute(name, "")
    as "brazier/attribute.boolean: attribute refused by the name policy (on*, srcdoc, data-brazier-* other than -hook, -hook-watch, -preserve-children and -external, or characters outside a-z A-Z 0-9 - _ : .)"
  case on {
    True -> attribute(name, "")
    False -> none()
  }
}

// --- URL attributes ---

pub fn href(url: String) -> Attribute(msg) {
  attribute("href", url)
}

pub fn src(url: String) -> Attribute(msg) {
  attribute("src", url)
}

pub fn action(url: String) -> Attribute(msg) {
  attribute("action", url)
}

pub fn formaction(url: String) -> Attribute(msg) {
  attribute("formaction", url)
}

pub fn poster(url: String) -> Attribute(msg) {
  attribute("poster", url)
}

pub fn cite(url: String) -> Attribute(msg) {
  attribute("cite", url)
}

// --- Common attributes ---

pub fn class(name: String) -> Attribute(msg) {
  attribute("class", name)
}

/// Several classes, each included when its flag is true.
pub fn classes(names: List(#(String, Bool))) -> Attribute(msg) {
  names
  |> list.filter_map(fn(pair) {
    case pair.1 {
      True -> Ok(pair.0)
      False -> Error(Nil)
    }
  })
  |> string.join(" ")
  |> class
}

pub fn id(id: String) -> Attribute(msg) {
  attribute("id", id)
}

pub fn name(name: String) -> Attribute(msg) {
  attribute("name", name)
}

pub fn type_(type_: String) -> Attribute(msg) {
  attribute("type", type_)
}

pub fn value(value: String) -> Attribute(msg) {
  attribute("value", value)
}

pub fn placeholder(text: String) -> Attribute(msg) {
  attribute("placeholder", text)
}

pub fn title(text: String) -> Attribute(msg) {
  attribute("title", text)
}

pub fn for(id: String) -> Attribute(msg) {
  attribute("for", id)
}

pub fn alt(text: String) -> Attribute(msg) {
  attribute("alt", text)
}

pub fn role(role: String) -> Attribute(msg) {
  attribute("role", role)
}

pub fn target(target: String) -> Attribute(msg) {
  attribute("target", target)
}

pub fn rel(rel: String) -> Attribute(msg) {
  attribute("rel", rel)
}

pub fn method(method: String) -> Attribute(msg) {
  attribute("method", method)
}

pub fn min(value: String) -> Attribute(msg) {
  attribute("min", value)
}

pub fn max(value: String) -> Attribute(msg) {
  attribute("max", value)
}

pub fn step(value: String) -> Attribute(msg) {
  attribute("step", value)
}

pub fn rows(rows: Int) -> Attribute(msg) {
  attribute("rows", int_to_string(rows))
}

pub fn cols(cols: Int) -> Attribute(msg) {
  attribute("cols", int_to_string(cols))
}

pub fn tabindex(index: Int) -> Attribute(msg) {
  attribute("tabindex", int_to_string(index))
}

/// A `data-<name>` attribute. `data("brazier-key", ..)` and the other
/// reserved `data-brazier-*` names crash, as in `attribute`.
pub fn data(name: String, value: String) -> Attribute(msg) {
  attribute("data-" <> name, value)
}

/// An `aria-<name>` attribute.
pub fn aria(name: String, value: String) -> Attribute(msg) {
  attribute("aria-" <> name, value)
}

/// One inline style declaration. Several `style` attributes on the same
/// element are joined with `;`.
pub fn style(property: String, value: String) -> Attribute(msg) {
  attribute("style", property <> ":" <> value)
}

/// Several inline style declarations as one `style` attribute, in order.
/// An empty list adds no attribute. Like `style`, it joins with any other
/// `style` attributes on the same element.
pub fn styles(properties: List(#(String, String))) -> Attribute(msg) {
  case properties {
    [] -> none()
    _ ->
      properties
      |> list.map(fn(pair) { pair.0 <> ":" <> pair.1 })
      |> string.join(";")
      |> attribute("style", _)
  }
}

pub fn disabled(on: Bool) -> Attribute(msg) {
  boolean("disabled", on)
}

pub fn checked(on: Bool) -> Attribute(msg) {
  boolean("checked", on)
}

pub fn selected(on: Bool) -> Attribute(msg) {
  boolean("selected", on)
}

pub fn readonly(on: Bool) -> Attribute(msg) {
  boolean("readonly", on)
}

pub fn required(on: Bool) -> Attribute(msg) {
  boolean("required", on)
}

pub fn autofocus(on: Bool) -> Attribute(msg) {
  boolean("autofocus", on)
}

pub fn draggable(on: Bool) -> Attribute(msg) {
  case on {
    True -> attribute("draggable", "true")
    False -> attribute("draggable", "false")
  }
}

// --- Client integration ---

/// Leave this element's children to client code: the client morph does not
/// touch them after the first render. LiveView's `phx-update="ignore"`.
pub fn ignore_updates() -> Attribute(msg) {
  attribute("data-brazier-preserve-children", "true")
}

/// Attach a client hook registered with `Brazier.hooks` in JavaScript.
/// LiveView's `phx-hook`.
pub fn hook(name: String) -> Attribute(msg) {
  attribute("data-brazier-hook", name)
}

/// Attribute names whose changes call the hook's `updated` callback, even
/// when the element's children are ignored.
pub fn watch(attributes: List(String)) -> Attribute(msg) {
  attribute("data-brazier-hook-watch", string.join(attributes, ","))
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}
