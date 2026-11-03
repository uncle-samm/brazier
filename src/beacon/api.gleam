/// Typed HTTP API route helpers.
///
/// These helpers build the handler accepted by `beacon.api_routes` while keeping
/// raw request/response access available inside each route.
import beacon/transport/http as transport_http
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri

/// The request an API route, a middleware or a `ws_auth` hook receives.
///
/// Reference: `wisp.Request`.
pub type Request =
  request.Request(Connection)

/// The response they return. Build one with `json`, `json_value`, `text` or
/// `empty`, then adjust it with `gleam/http/response`.
///
/// Reference: `wisp.Response`.
pub type Response =
  response.Response(ResponseBody)

/// A single API route declaration.
///
/// Construct with `get`, `post`, `put`, `patch`, or `delete`, then pass the list
/// to `routes`.
///
/// A matched route tags the request with its declared path (for example
/// `/api/items`) for the `[beacon, http, request]` telemetry span, so the
/// span never carries the raw request path.
pub opaque type Route {
  Route(
    method: http.Method,
    segments: List(String),
    pattern: String,
    handler: fn(Request) -> Response,
  )
}

/// Declare a GET route.
pub fn get(path: String, handler: fn(Request) -> Response) -> Route {
  new_route(http.Get, path, handler)
}

/// Declare a POST route.
pub fn post(path: String, handler: fn(Request) -> Response) -> Route {
  new_route(http.Post, path, handler)
}

/// Declare a PUT route.
pub fn put(path: String, handler: fn(Request) -> Response) -> Route {
  new_route(http.Put, path, handler)
}

/// Declare a PATCH route.
pub fn patch(path: String, handler: fn(Request) -> Response) -> Route {
  new_route(http.Patch, path, handler)
}

/// Declare a DELETE route.
pub fn delete(path: String, handler: fn(Request) -> Response) -> Route {
  new_route(http.Delete, path, handler)
}

/// Build a route and its telemetry pattern. A path whose normalised form
/// is longer than `transport_http.max_route_tag_bytes` is a programming
/// error: it crashes here, at declaration, rather than on the first
/// matching request.
fn new_route(
  method: http.Method,
  path: String,
  handler: fn(Request) -> Response,
) -> Route {
  let segments = path_segments(path)
  let pattern = "/" <> string.join(segments, "/")
  let size = string.byte_size(pattern)
  let assert True = size <= transport_http.max_route_tag_bytes
    as "api route path is longer than transport_http.max_route_tag_bytes"
  Route(method: method, segments: segments, pattern: pattern, handler: handler)
}

/// Build the handler expected by `beacon.api_routes`.
///
/// Routes are matched in declaration order. Unknown method/path combinations
/// return `None`, so Beacon continues to SSR/static routing.
pub fn routes(route_list: List(Route)) -> fn(Request) -> Option(Response) {
  fn(req: Request) { dispatch(route_list, req) }
}

/// Create a JSON response.
pub fn json(status: Int, body: String) -> Response {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

/// Create a JSON response from a typed `gleam/json` value.
pub fn json_value(status: Int, body: Json) -> Response {
  json(status, json.to_string(body))
}

/// Create a text response.
pub fn text(status: Int, body: String) -> Response {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

/// Create an empty response.
pub fn empty(status: Int) -> Response {
  response.new(status)
  |> response.set_body(Bytes(bytes_tree.new()))
}

/// Read a UTF-8 request body with an explicit byte cap.
pub fn read_text(req: Request, max_bytes: Int) -> Result(String, String) {
  case transport_http.read_body(req, max_bytes) {
    Ok(bits) -> {
      case bit_array.to_string(bits) {
        Ok(body) -> Ok(body)
        Error(Nil) -> Error("Invalid UTF-8 request body")
      }
    }
    Error(reason) -> Error(reason)
  }
}

/// Read an `application/x-www-form-urlencoded` request body.
pub fn read_form(
  req: Request,
  max_bytes: Int,
) -> Result(List(#(String, String)), String) {
  case read_text(req, max_bytes) {
    Ok(body) -> {
      case uri.parse_query(body) {
        Ok(fields) -> Ok(fields)
        Error(Nil) -> Error("Invalid form encoding")
      }
    }
    Error(reason) -> Error(reason)
  }
}

/// Find a required form field.
pub fn form_field(
  fields: List(#(String, String)),
  name: String,
) -> Result(String, String) {
  case list.find(fields, fn(pair) { pair.0 == name }) {
    Ok(#(_, value)) -> Ok(value)
    Error(Nil) -> Error("Missing form field: " <> name)
  }
}

fn dispatch(route_list: List(Route), req: Request) -> Option(Response) {
  case route_list {
    [] -> None
    [Route(method:, segments:, pattern:, handler:), ..rest] -> {
      case req.method == method && request.path_segments(req) == segments {
        True -> {
          transport_http.tag_route(pattern)
          Some(handler(req))
        }
        False -> dispatch(rest, req)
      }
    }
  }
}

fn path_segments(path: String) -> List(String) {
  let path_only = case string.split(path, "?") {
    [path, ..] -> path
    [] -> path
  }

  path_only
  |> string.split("/")
  |> list.filter(fn(segment) { segment != "" })
}
