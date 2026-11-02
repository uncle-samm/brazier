/// Error page rendering for Beacon.
/// Provides styled error pages for common HTTP errors.
///
/// Reference: Phoenix error views, LiveView error handling.
import beacon/attribute
import beacon/element.{type Element}
import beacon/html
import beacon/transport/server.{type ResponseBody, Bytes}
import gleam/bytes_tree
import gleam/http/response.{type Response}
import gleam/int

/// Render a 404 Not Found error page.
pub fn not_found() -> Element(msg) {
  error_page(
    404,
    "Page Not Found",
    "The page you're looking for doesn't exist.",
  )
}

/// Render a 500 Internal Server Error page.
pub fn internal_error(detail: String) -> Element(msg) {
  error_page(
    500,
    "Internal Server Error",
    "Something went wrong on our end. " <> detail,
  )
}

/// Render a generic error page with status code, title, and message.
pub fn error_page(status: Int, title: String, message: String) -> Element(msg) {
  html.div([attribute.class("beacon-error")], [
    html.div([attribute.class("beacon-error-content")], [
      html.h1([attribute.class("beacon-error-status")], [
        html.text(int.to_string(status)),
      ]),
      html.h2([attribute.class("beacon-error-title")], [html.text(title)]),
      html.p([attribute.class("beacon-error-message")], [html.text(message)]),
      html.a([attribute.href("/")], [html.text("Go back home")]),
    ]),
  ])
}

/// Render a development-mode error page with detailed error info.
/// Shows the error type, message, and a stack trace.
/// NEVER use this in production — it may expose internal details.
pub fn dev_error(
  error_type: String,
  message: String,
  details: String,
) -> Element(msg) {
  html.div([attribute.class("beacon-dev-error")], [
    html.h1([attribute.style("color", "#e74c3c")], [
      html.text("Error: " <> error_type),
    ]),
    html.p([], [html.text(message)]),
    html.pre(
      [
        attribute.attribute(
          "style",
          "background:#1e1e1e;color:#ddd;padding:1rem;overflow-x:auto;border-radius:4px",
        ),
      ],
      [html.text(details)],
    ),
    html.hr([]),
    html.p([attribute.attribute("style", "color:#888;font-size:0.9em")], [
      html.text("This error page is only shown in development mode."),
    ]),
  ])
}

/// Convert an error page element to a full HTTP response.
pub fn to_response(status: Int, page: Element(msg)) -> Response(ResponseBody) {
  let html =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    <> "<title>Error "
    <> int.to_string(status)
    <> "</title>"
    <> "<style>"
    <> "body{font-family:system-ui,sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:#f5f5f5}"
    <> ".beacon-error{text-align:center}"
    <> ".beacon-error-status{font-size:6rem;margin:0;color:#e74c3c}"
    <> ".beacon-error-title{margin:0.5rem 0;color:#333}"
    <> ".beacon-error-message{color:#666;margin:1rem 0}"
    <> "a{color:#3498db;text-decoration:none}"
    <> "</style></head><body>"
    <> element.to_string(page)
    <> "</body></html>"
  response.new(status)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(Bytes(bytes_tree.from_string(html)))
}
