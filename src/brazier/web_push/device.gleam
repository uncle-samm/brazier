//// The view's side of `brazier/web_push`: the element that holds this
//// device's notification buttons, and the buttons in it.
////
//// ```gleam
//// html.div(
////   device.control(public_key: model.push_key, on_report: PushReported),
////   [html.button([device.subscribe(), attribute.type_("button")], [
////     html.text("Turn on notifications"),
////   ])],
//// )
//// ```
////
//// The page loads the device script (`web_push.head_html`) and the server
//// serves it and the service worker (`web_push.routes`). When the element
//// appears, and after each press, the script reports this browser's state
//// as JSON text: `on_report` makes a message of it, and the server reads it
//// with `web_push.parse_report`, which checks it, since it is the
//// browser's word.
////
//// The report is a String, not a typed value, because the codecs only
//// carry the app's own types between the browser and the server.

import brazier/attribute.{type Attribute}
import brazier/event
import gleam/dynamic/decode

/// The client hook the device script registers.
pub const hook_name = "BrazierWebPush"

/// The DOM event the script reports on, with the JSON in `detail`.
pub const report_event = "brazier-web-push"

/// The attributes of the element that holds the buttons. `public_key` is
/// `web_push.public_key_base64` of the server's keys. When it changes, the
/// script reports again, and takes back a subscription made with the old
/// key.
pub fn control(
  public_key public_key: String,
  on_report on_report: fn(String) -> msg,
) -> List(Attribute(msg)) {
  [
    attribute.hook(hook_name),
    attribute.data("web-push-key", public_key),
    attribute.watch(["data-web-push-key"]),
    event.on(report_event, {
      use report <- decode.field("detail", decode.string)
      decode.success(on_report(report))
    }),
  ]
}

/// A button inside `control` that subscribes this browser: it asks for
/// permission first, which browsers show only after a press.
pub fn subscribe() -> Attribute(msg) {
  attribute.data("web-push", "subscribe")
}

/// A button inside `control` that takes this browser's subscription back.
pub fn unsubscribe() -> Attribute(msg) {
  attribute.data("web-push", "unsubscribe")
}

/// A button inside `control` that reports again, for after a change in the
/// browser's own settings.
pub fn check() -> Attribute(msg) {
  attribute.data("web-push", "check")
}
