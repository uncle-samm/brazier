/// Middleware Demo: route-scoped HTTP middleware around a `beacon.simple`
/// counter. Shows `group`, `only`, `except`, `at` and `methods`.
///
/// Routes:
///   /           -> main page (public)
///   /admin/*    -> requires the `x-admin: true` header
///   /api/*      -> adds `x-api-version`; POST and PUT are refused
///   /healthz    -> health check (exact match)
import beacon
import beacon/attribute
import beacon/element.{type Element}
import beacon/event
import beacon/html
import beacon/log
import beacon/middleware
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Decrement
}

fn init(_ctx: beacon.Context) -> Model {
  Model(count: 0)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    Decrement -> Model(count: model.count - 1)
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "700px"),
        #("margin", "2rem auto"),
        #("padding", "0 1rem"),
      ]),
    ],
    [
      html.h1([], [html.text("Middleware Demo")]),
      html.p([attribute.style("color", "#666")], [
        html.text(
          "Route-scoped middleware: group(), only(), except(), at(), methods()",
        ),
      ]),
      html.div(
        [
          attribute.styles([
            #("margin", "1.5rem 0"),
            #("padding", "1rem"),
            #("background", "#f5f5f5"),
            #("border-radius", "8px"),
          ]),
        ],
        [
          html.h2([], [html.text("Counter: " <> int.to_string(model.count))]),
          html.button(
            [
              event.on_click(Decrement),
              attribute.aria("label", "Decrement"),
              attribute.styles(button_styles),
              attribute.style("margin-right", "8px"),
            ],
            [html.text("-")],
          ),
          html.button(
            [
              event.on_click(Increment),
              attribute.aria("label", "Increment"),
              attribute.styles(button_styles),
            ],
            [html.text("+")],
          ),
        ],
      ),
      html.div([attribute.style("margin-top", "1.5rem")], [
        html.h2([], [html.text("Active Middleware")]),
        html.ul([], [
          html.li([], [
            html.text("Secure headers: on by default, every response"),
          ]),
          html.li([], [
            html.text(
              "Request id and logger: group(); the logger skips /healthz with except()",
            ),
          ]),
          html.li([], [
            html.text("Health check: at(\"/healthz\"), exact path, JSON"),
          ]),
          html.li([], [
            html.text("Admin auth: only(\"/admin\"), needs x-admin: true"),
          ]),
          html.li([], [
            html.text("API versioning: only(\"/api\"), adds x-api-version"),
          ]),
          html.li([], [
            html.text("Write blocking: methods([Post, Put]) under /api, 405"),
          ]),
        ]),
      ]),
    ],
  )
}

const button_styles = [
  #("padding", "8px 16px"),
  #("border", "none"),
  #("border-radius", "4px"),
  #("cursor", "pointer"),
]

/// Admin auth for the demo: checks for an `x-admin: true` header.
/// A real app checks a session or token.
fn require_admin() -> middleware.Middleware {
  fn(
    req: request.Request(Connection),
    next: fn(request.Request(Connection)) -> response.Response(ResponseBody),
  ) -> response.Response(ResponseBody) {
    case request.get_header(req, "x-admin") {
      Ok("true") -> next(req)
      Ok(value) -> {
        log.warning(
          "middleware_demo",
          "Refused " <> req.path <> ": x-admin is " <> value <> ", not true",
        )
        forbidden()
      }
      Error(Nil) -> {
        log.warning(
          "middleware_demo",
          "Refused " <> req.path <> ": no x-admin header",
        )
        forbidden()
      }
    }
  }
}

fn forbidden() -> response.Response(ResponseBody) {
  response.new(403)
  |> response.set_body(
    Bytes(bytes_tree.from_string("Forbidden: admin access required")),
  )
}

/// Adds the API version header to every /api response.
fn api_version() -> middleware.Middleware {
  fn(
    req: request.Request(Connection),
    next: fn(request.Request(Connection)) -> response.Response(ResponseBody),
  ) -> response.Response(ResponseBody) {
    next(req)
    |> response.set_header("x-api-version", "v1")
  }
}

/// Answers the health check without reaching the app.
fn health_handler() -> middleware.Middleware {
  fn(
    _req: request.Request(Connection),
    _next: fn(request.Request(Connection)) -> response.Response(ResponseBody),
  ) -> response.Response(ResponseBody) {
    response.new(200)
    |> response.set_header("content-type", "application/json")
    |> response.set_body(Bytes(bytes_tree.from_string("{\"status\":\"ok\"}")))
  }
}

/// Refuses the request; scoped to POST and PUT by `middleware.methods`.
fn block_writes() -> middleware.Middleware {
  fn(
    req: request.Request(Connection),
    _next: fn(request.Request(Connection)) -> response.Response(ResponseBody),
  ) -> response.Response(ResponseBody) {
    log.warning(
      "middleware_demo",
      "Refused " <> http.method_to_string(req.method) <> " " <> req.path,
    )
    response.new(405)
    |> response.set_header("allow", "GET, HEAD")
    |> response.set_body(Bytes(bytes_tree.from_string("Method not allowed")))
  }
}

pub fn main() {
  beacon.simple(init:, update:, view:)
  |> beacon.title(fn(_model) { "Middleware Demo" })
  // Secure headers are already on by default; these run after them.
  |> beacon.with_middleware(
    middleware.group([
      middleware.request_id(),
      // Health probes are frequent, so they stay out of the request log.
      middleware.except("/healthz", middleware.logger()),
    ]),
  )
  |> beacon.with_middleware(middleware.at("/healthz", health_handler()))
  |> beacon.with_middleware(middleware.only("/admin", require_admin()))
  |> beacon.with_middleware(middleware.only("/api", api_version()))
  |> beacon.with_middleware(middleware.only(
    "/api",
    middleware.methods([http.Post, http.Put], block_writes()),
  ))
  |> beacon.start(8080)
}
