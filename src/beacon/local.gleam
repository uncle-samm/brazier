/// The client-only state layer.
///
/// A `Layer` holds state that lives only in the browser: a draft being
/// typed, a hover position, an open menu. It is never sent to the server.
/// `update` runs in the browser for every message an event produces and
/// decides whether the server also needs the message:
///
/// - `handled(local)`: apply the new local state; the server never sees the
///   message.
/// - `forward(local)`: apply the new local state and send the message to the
///   server.
///
/// Forwarding is the safe default for messages the layer does not care
/// about: it costs one round-trip and never loses a message.
///
/// Reference: LiveView's split between `JS` commands and `push`.
import gleam/option.{type Option, None, Some}

/// A client-only state layer over the synced `model`.
pub opaque type Layer(model, local, msg) {
  Layer(
    init: fn(model) -> local,
    update: Option(fn(model, local, msg) -> Update(local)),
  )
}

/// The result of a local update.
pub opaque type Update(local) {
  Handled(local: local)
  Forward(local: local)
}

/// A layer with `init` (run once, in the browser, with the first synced
/// model) and `update`.
pub fn layer(
  init init: fn(model) -> local,
  update update: fn(model, local, msg) -> Update(local),
) -> Layer(model, local, msg) {
  Layer(init: init, update: Some(update))
}

/// No client-only state. Every message goes to the server.
pub fn none() -> Layer(model, Nil, msg) {
  Layer(init: fn(_model) { Nil }, update: None)
}

/// Apply `local` in the browser and do not send the message to the server.
pub fn handled(local: local) -> Update(local) {
  Handled(local)
}

/// Apply `local` in the browser and also send the message to the server.
pub fn forward(local: local) -> Update(local) {
  Forward(local)
}

@internal
pub fn init(layer: Layer(model, local, msg)) -> fn(model) -> local {
  layer.init
}

@internal
pub fn update(
  layer: Layer(model, local, msg),
) -> Option(fn(model, local, msg) -> Update(local)) {
  layer.update
}

/// Whether the layer has an update function. `none()` has none.
@internal
pub fn has_update(layer: Layer(model, local, msg)) -> Bool {
  option.is_some(layer.update)
}

/// The new local state of an update.
@internal
pub fn new_local(update: Update(local)) -> local {
  update.local
}

/// Whether the message must also be sent to the server.
@internal
pub fn is_forwarded(update: Update(local)) -> Bool {
  case update {
    Handled(_) -> False
    Forward(_) -> True
  }
}
