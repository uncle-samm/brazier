/// Event listeners.
///
/// A listener holds a `Decoder(msg)` that the browser runs against the real
/// DOM event object. A decode failure is logged with `console.warn` (event
/// name and errors) and the event is dropped.
///
/// Submit events carry the form's string fields in `event.detail.formData`
/// as a list of `[name, value]` pairs; the client adds them before decoding,
/// as Lustre does.
///
/// Reference: Lustre's `lustre/event`.
import brazier/attribute.{type Attribute}
import brazier/internal/render
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/result

/// Listen for the DOM event `name` and decode it into a message.
///
/// `name` is the DOM event type without the `on` prefix, e.g. `"click"` or
/// `"pointermove"`.
pub fn on(name: String, handler: Decoder(msg)) -> Attribute(msg) {
  // Invariant: event names are literals in application code. A name that
  // could break out of the `data-brazier-on-<name>` attribute is a bug.
  let assert True = render.is_valid_event_name(name)
  attribute.from_attr(render.Event(name, render.handler(handler)))
}

/// Call `preventDefault` on the event before decoding it.
pub fn prevent_default(event: Attribute(msg)) -> Attribute(msg) {
  modify(event, fn(handler) { render.Handler(..handler, prevent_default: True) })
}

/// Call `stopPropagation` on the event: listeners on ancestors do not run.
pub fn stop_propagation(event: Attribute(msg)) -> Attribute(msg) {
  modify(event, fn(handler) {
    render.Handler(..handler, stop_propagation: True)
  })
}

/// Wait until the event has not fired for `ms` milliseconds, then dispatch
/// the latest one.
pub fn debounce(event: Attribute(msg), ms: Int) -> Attribute(msg) {
  // Invariant: a delay is a literal in application code.
  let assert True = ms >= 0
  modify(event, fn(handler) {
    render.Handler(..handler, debounce_ms: ms, throttle_ms: 0)
  })
}

/// Dispatch at most one event every `ms` milliseconds (the first one in each
/// window).
pub fn throttle(event: Attribute(msg), ms: Int) -> Attribute(msg) {
  // Invariant: a delay is a literal in application code.
  let assert True = ms >= 0
  modify(event, fn(handler) {
    render.Handler(..handler, throttle_ms: ms, debounce_ms: 0)
  })
}

fn modify(
  event: Attribute(msg),
  f: fn(render.Handler(msg)) -> render.Handler(msg),
) -> Attribute(msg) {
  // Invariant: the modifiers above are applied to the result of `on` or an
  // `on_*` helper. Applying one to a plain attribute is a bug in the view.
  let assert render.Event(name, handler) = attribute.to_attr(event)
  attribute.from_attr(render.Event(name, f(handler)))
}

// --- Mouse ---

pub fn on_click(msg: msg) -> Attribute(msg) {
  on("click", decode.success(msg))
}

pub fn on_double_click(msg: msg) -> Attribute(msg) {
  on("dblclick", decode.success(msg))
}

pub fn on_mouse_down(msg: msg) -> Attribute(msg) {
  on("mousedown", decode.success(msg))
}

pub fn on_mouse_up(msg: msg) -> Attribute(msg) {
  on("mouseup", decode.success(msg))
}

pub fn on_mouse_enter(msg: msg) -> Attribute(msg) {
  on("mouseenter", decode.success(msg))
}

pub fn on_mouse_leave(msg: msg) -> Attribute(msg) {
  on("mouseleave", decode.success(msg))
}

pub fn on_mouse_over(msg: msg) -> Attribute(msg) {
  on("mouseover", decode.success(msg))
}

pub fn on_mouse_out(msg: msg) -> Attribute(msg) {
  on("mouseout", decode.success(msg))
}

// --- Forms ---

/// The input's current value on every `input` event.
pub fn on_input(msg: fn(String) -> msg) -> Attribute(msg) {
  on("input", decode.map(value(), msg))
}

/// The input's value on `change` (commit, e.g. blur or select).
pub fn on_change(msg: fn(String) -> msg) -> Attribute(msg) {
  on("change", decode.map(value(), msg))
}

/// A checkbox's checked state on `change`.
pub fn on_check(msg: fn(Bool) -> msg) -> Attribute(msg) {
  on("change", decode.map(checked(), msg))
}

/// The form's string fields on `submit`. The browser's default submission
/// is prevented.
pub fn on_submit(msg: fn(List(#(String, String))) -> msg) -> Attribute(msg) {
  on("submit", decode.map(form_data(), msg))
  |> prevent_default
}

// --- Keyboard ---

/// `event.key` on `keydown`.
pub fn on_keydown(msg: fn(String) -> msg) -> Attribute(msg) {
  on("keydown", decode.map(key(), msg))
}

/// `event.key` on `keyup`.
pub fn on_keyup(msg: fn(String) -> msg) -> Attribute(msg) {
  on("keyup", decode.map(key(), msg))
}

/// `event.key` on `keypress`.
pub fn on_keypress(msg: fn(String) -> msg) -> Attribute(msg) {
  on("keypress", decode.map(key(), msg))
}

// --- Focus ---

pub fn on_focus(msg: msg) -> Attribute(msg) {
  on("focus", decode.success(msg))
}

pub fn on_blur(msg: msg) -> Attribute(msg) {
  on("blur", decode.success(msg))
}

// --- Drag and drop ---

pub fn on_drag_start(msg: msg) -> Attribute(msg) {
  on("dragstart", decode.success(msg))
}

pub fn on_drag_end(msg: msg) -> Attribute(msg) {
  on("dragend", decode.success(msg))
}

/// `drop`. The browser's default handling (opening a dropped link or file)
/// is prevented.
pub fn on_drop(msg: msg) -> Attribute(msg) {
  on("drop", decode.success(msg))
  |> prevent_default
}

/// `dragover`. The default is prevented, which is what makes an element a
/// drop target.
pub fn on_drag_over(msg: msg) -> Attribute(msg) {
  on("dragover", decode.success(msg))
  |> prevent_default
}

// --- Payload decoders ---

/// `event.target.value`.
pub fn value() -> Decoder(String) {
  decode.at(["target", "value"], decode.string)
}

/// `event.target.checked`.
pub fn checked() -> Decoder(Bool) {
  decode.at(["target", "checked"], decode.bool)
}

/// `event.key`.
pub fn key() -> Decoder(String) {
  decode.at(["key"], decode.string)
}

/// `#(event.offsetX, event.offsetY)`, relative to the target element.
pub fn mouse_position() -> Decoder(#(Float, Float)) {
  use x <- decode.field("offsetX", number())
  use y <- decode.field("offsetY", number())
  decode.success(#(x, y))
}

/// The submitted form's string fields, in document order. File fields are
/// left out.
pub fn form_data() -> Decoder(List(#(String, String))) {
  decode.at(["detail", "formData"], form_entries())
}

fn form_entries() -> Decoder(List(#(String, String))) {
  let entry = {
    use name <- decode.field(0, decode.string)
    use value <- decode.field(
      1,
      decode.one_of(decode.map(decode.string, Ok), [
        decode.success(Error(Nil)),
      ]),
    )
    decode.success(result.map(value, fn(value) { #(name, value) }))
  }
  decode.list(entry)
  |> decode.map(fn(entries) { list.filter_map(entries, fn(entry) { entry }) })
}

/// A number as a float. In the browser every number is a float; on the
/// server, test events may hold integers.
fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.map(decode.int, int.to_float)])
}
