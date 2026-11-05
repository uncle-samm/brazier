//// The HTTP scenarios of the benchmark suite. Each one starts its own
//// listener on an OS-assigned port, probes it once with a request whose
//// whole response is checked (status, headers, body bytes), and then times
//// keep-alive clients that check every response against the probe's
//// status, length and headers (brazier_bench_ffi:http_round).
////
//// - http.keepalive: a 2-byte `/bench` answer, the floor of the HTTP path.
//// - http.static: a 100 KB and a 10 MB file from `brazier/static`, sent
////   with sendfile (200), and the same files revalidated with the ETag of
////   the probe (304). The files are written by `prepare` and must be past
////   the digest cache's racy window when they are measured, so the 200s
////   and 304s time the cached digest, as they do in production; a file
////   that is not is an error, not a slower number.
//// - http.gzip_100kb: a 100 KB HTML body through `middleware.compress`
////   with `Accept-Encoding: gzip`. The probe gunzips the body and compares
////   it with the original.
//// - ssr.rows_100 / ssr.rows_1000: a dead render of a 100- and a
////   1000-row view with a click handler per row through
////   `ssr.render_page`, as `brazier.start` serves a page. The probe checks
////   every row is in the HTML.
//// - ssr.stream_300: a dead render of a page whose view is a full
////   `KeepLast(300)` stream of 1 KB lines (brazier/bench/stream_bench),
////   `init` inserting every line. The probe checks the page holds the 300
////   items, keyed and in order.

import brazier/attribute
import brazier/bench/measure.{check, string_of}
import brazier/bench/report.{type Metric}
import brazier/bench/stream_bench
import brazier/effect
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/internal/stream_window
import brazier/middleware
import brazier/ssr
import brazier/static
import brazier/stream
import brazier/transport
import brazier/transport/server.{type Connection, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile

/// Where `prepare` writes the static files (not committed).
pub const static_dir = "build/bench/static"

const static_prefix = "/static"

const keepalive_clients = 8

const keepalive_requests = 2000

const warmup_rounds = 2

/// Measured rounds per scenario. A round takes 0.1 to 0.5 s, so with 5
/// rounds a burst of outside load lasting about a second covered three of
/// them and set their median; 15 rounds need it to cover eight.
const measured_rounds = 15

/// A static scenario: #(name, file, bytes, clients, requests per client).
/// Fewer requests for the 10 MB file keep its round near half a second.
fn static_files() -> List(#(String, String, Int, Int, Int)) {
  [
    #("100kb", "file_100kb.txt", 100 * 1024, 8, 500),
    #("10mb", "file_10mb.txt", 10 * 1024 * 1024, 4, 25),
  ]
}

/// Requests per client of the 304 revalidations.
const revalidate_clients = 8

const revalidate_requests = 1000

const gzip_body_bytes = 102_400

const gzip_clients = 8

const gzip_requests = 100

/// The SSR scenarios: #(rows, requests per client). Fewer requests for
/// the larger page keep its round near half a second.
fn ssr_pages() -> List(#(Int, Int)) {
  [#(100, 800), #(1000, 50)]
}

const ssr_clients = 8

/// Requests per client of ssr.stream_300, whose page is about 330 KB.
const ssr_stream_requests = 50

@external(erlang, "brazier_bench_ffi", "http_round")
fn http_round(
  port: Int,
  clients: Int,
  requests: Int,
  request: String,
  expect: #(Int, Int, List(#(String, String))),
  timeout_ms: Int,
) -> Result(#(Int, List(Int)), String)

@external(erlang, "brazier_bench_ffi", "http_fetch")
fn http_fetch(
  port: Int,
  request: String,
  timeout_ms: Int,
) -> Result(#(Int, List(#(String, String)), BitArray), String)

@external(erlang, "brazier_bench_ffi", "gunzip")
fn gunzip(data: BitArray) -> Result(BitArray, String)

/// The digest cache's clock, as `serve_file` reads it.
@external(erlang, "brazier_static_ffi", "now_seconds")
fn static_now_seconds() -> Int

/// Write the static files unless they already hold their contents, so a
/// later run finds them unchanged (and past the digest cache's racy
/// window) and measures the cached digest.
pub fn prepare() -> Result(Nil, String) {
  use Nil <- result.try(
    simplifile.create_directory_all(static_dir)
    |> result.map_error(fn(e) {
      "create " <> static_dir <> ": " <> simplifile.describe_error(e)
    }),
  )
  list.try_each(static_files(), fn(file) {
    let #(_name, filename, bytes, _clients, _requests) = file
    let path = static_dir <> "/" <> filename
    let contents = file_contents(bytes)
    case simplifile.read_bits(path) {
      Ok(existing) if existing == contents -> Ok(Nil)
      _ ->
        simplifile.write_bits(path, contents)
        |> result.map_error(fn(e) {
          "write " <> path <> ": " <> simplifile.describe_error(e)
        })
    }
  })
}

/// `bytes` bytes of numbered 64-byte lines.
fn file_contents(bytes: Int) -> BitArray {
  let lines = bytes / 64
  let body =
    int.range(from: lines, to: 0, with: [], run: fn(acc, i) {
      [string.pad_start(int.to_string(i), 63, ".") <> "\n", ..acc]
    })
    |> string.concat
  // INVARIANT: every scenario size is a multiple of 64.
  let assert True = string.byte_size(body) == bytes
    as "static bench file sizes are multiples of 64 bytes"
  bit_array.from_string(body)
}

/// Run every HTTP scenario.
pub fn run() -> Result(List(Metric), String) {
  use keepalive <- result.try(keepalive_scenario())
  use static_metrics <- result.try(static_scenario())
  use gzip <- result.try(gzip_scenario())
  use rendered <- result.try(
    list.try_map(ssr_pages(), ssr_scenario) |> result.map(list.flatten),
  )
  use streamed <- result.try(ssr_stream_scenario())
  Ok(list.flatten([keepalive, static_metrics, gzip, rendered, streamed]))
}

fn get(path: String, headers: List(#(String, String))) -> String {
  "GET "
  <> path
  <> " HTTP/1.1\r\nhost: localhost\r\n"
  <> string.concat(list.map(headers, fn(h) { h.0 <> ": " <> h.1 <> "\r\n" }))
  <> "\r\n"
}

fn base_config(requests_per_connection: Int) -> transport.TransportConfig {
  transport.TransportConfig(
    port: 0,
    on_connect: fn(_id, _subject) { Nil },
    on_event: fn(_id, _msg) { Nil },
    on_disconnect: fn(_id) { Nil },
    page_html: None,
    middlewares: [],
    static_config: None,
    runtime_factory: None,
    ws_auth: None,
    ssr_factory: None,
    security_limits: transport.SecurityLimits(
      ..transport.default_security_limits(),
      // Every timed client keeps one connection for all its requests;
        // the probe opens its own.
        max_keepalive_requests: requests_per_connection + 1,
    ),
    api_handler: None,
  )
}

/// Start a listener for `config`, run `measure` with its port, stop it.
fn with_listener(
  name: String,
  config: transport.TransportConfig,
  measure: fn(Int) -> Result(a, String),
) -> Result(a, String) {
  use listener <- result.try(
    transport.start_listener(config)
    |> result.map_error(fn(e) { name <> ": listener: " <> string_of(e) }),
  )
  let outcome = measure(server.get_port(listener))
  server.stop(listener)
  outcome |> result.map_error(fn(reason) { name <> ": " <> reason })
}

/// Warm up, then time `measured_rounds` rounds of `clients` x `requests`
/// copies of `request`, each response checked against `expect`.
fn timed(
  name: String,
  port: Int,
  clients: Int,
  requests: Int,
  request: String,
  expect: #(Int, Int, List(#(String, String))),
) -> Result(List(Metric), String) {
  let round = fn() {
    http_round(port, clients, requests, request, expect, measure.timeout_ms)
  }
  use _ <- result.try(measure.repeat(warmup_rounds, round))
  use samples <- result.try(
    measure.repeat(measured_rounds, fn() {
      measure.gc()
      round()
    }),
  )
  measure.throughput_and_latency(name, "req/s", clients * requests, samples)
}

/// The value of header `name` (lowercase) in a probe's response.
fn header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, String) {
  list.key_find(headers, name)
  |> result.replace_error("the probe's response has no " <> name <> " header")
}

// --- keepalive ---

fn keepalive_scenario() -> Result(List(Metric), String) {
  let name = "http.keepalive." <> int.to_string(keepalive_clients) <> "c"
  let config =
    transport.TransportConfig(
      ..base_config(keepalive_requests),
      api_handler: Some(keepalive_handler),
    )
  use port <- with_listener(name, config)
  timed(
    name,
    port,
    keepalive_clients,
    keepalive_requests,
    get("/bench", []),
    #(200, 2, []),
  )
}

fn keepalive_handler(
  req: Request(Connection),
) -> option.Option(response.Response(server.ResponseBody)) {
  case req.path {
    "/bench" ->
      Some(
        response.new(200)
        |> response.set_header("content-type", "text/plain")
        |> response.set_body(Bytes(bytes_tree.from_string("ok"))),
      )
    _ -> None
  }
}

// --- static ---

fn static_scenario() -> Result(List(Metric), String) {
  let config =
    transport.TransportConfig(
      ..base_config(
        list.fold(static_files(), revalidate_requests, fn(most, file) {
          int.max(most, file.4)
        }),
      ),
      static_config: Some(static.StaticConfig(
        directory: static_dir,
        prefix: static_prefix,
        max_age: 0,
      )),
    )
  use port <- with_listener("http.static", config)
  list.try_map(static_files(), fn(file) {
    let #(size, filename, bytes, clients, requests) = file
    let name = "http.static." <> size
    {
      let path = static_prefix <> "/" <> filename
      use #(status, headers, body) <- result.try(http_fetch(
        port,
        get(path, []),
        measure.timeout_ms,
      ))
      use <- check(status == 200, "the probe got a " <> int.to_string(status))
      use <- check(
        body == file_contents(bytes),
        "the probe's body is not the file's contents",
      )
      use etag <- result.try(header(headers, "etag"))
      use content_type <- result.try(header(headers, "content-type"))
      use Nil <- result.try(expect_cached_digest(static_dir <> "/" <> filename))
      // The revalidations run first: after the 200s of a 10 MB file the
      // scheduler and the allocator are still settling, and a 304 timed
      // right after them carries that in its p99.
      use revalidated <- result.try(
        timed(
          name <> ".304",
          port,
          revalidate_clients,
          revalidate_requests,
          get(path, [#("if-none-match", etag)]),
          #(304, 0, [#("etag", etag)]),
        ),
      )
      use served <- result.try(
        timed(
          name <> ".200",
          port,
          clients,
          requests,
          get(path, []),
          #(200, bytes, [#("etag", etag), #("content-type", content_type)]),
        ),
      )
      Ok(list.append(served, revalidated))
    }
    |> result.map_error(fn(reason) { name <> ": " <> reason })
  })
  |> result.map(list.flatten)
}

/// The digest of `path` must come from the cache now that the probe has
/// served it once: a file changed less than the racy window ago is hashed
/// on every request, which is not what this scenario claims to measure.
fn expect_cached_digest(path: String) -> Result(Nil, String) {
  case
    static.file_digest_at(
      path,
      static_now_seconds(),
      static.digest_cache_capacity,
    )
  {
    Ok(static.Digest(source: static.Cached, ..)) -> Ok(Nil)
    Ok(static.Digest(source: static.Hashed(reason), ..)) ->
      Error(
        path
        <> " is hashed on every request ("
        <> string_of(reason)
        <> "): it changed less than the digest cache's racy window ago. "
        <> "Run the bench again; prepare leaves unchanged files alone",
      )
    Error(reason) -> Error(path <> ": " <> string_of(reason))
  }
}

// --- gzip ---

fn gzip_scenario() -> Result(List(Metric), String) {
  let name = "http.gzip_100kb"
  let body = gzip_body()
  let config =
    transport.TransportConfig(
      ..base_config(gzip_requests),
      middlewares: [middleware.compress()],
      api_handler: Some(fn(req: Request(Connection)) {
        case req.path {
          "/page" ->
            Some(
              response.new(200)
              |> response.set_header("content-type", "text/html; charset=utf-8")
              |> response.set_body(Bytes(bytes_tree.from_string(body))),
            )
          _ -> None
        }
      }),
    )
  use port <- with_listener(name, config)
  let request = get("/page", [#("accept-encoding", "gzip")])
  use #(status, headers, compressed) <- result.try(http_fetch(
    port,
    request,
    measure.timeout_ms,
  ))
  use <- check(status == 200, "the probe got a " <> int.to_string(status))
  use encoding <- result.try(header(headers, "content-encoding"))
  use <- check(encoding == "gzip", "the probe's body is " <> encoding)
  use plain <- result.try(gunzip(compressed))
  use <- check(
    plain == bit_array.from_string(body),
    "the probe's body does not gunzip to the page",
  )
  let length = bit_array.byte_size(compressed)
  use <- check(
    length < gzip_body_bytes / 2,
    "the page gzips to " <> int.to_string(length) <> " bytes only",
  )
  timed(
    name,
    port,
    gzip_clients,
    gzip_requests,
    request,
    #(200, length, [#("content-encoding", "gzip")]),
  )
}

/// About `gzip_body_bytes` of HTML: numbered list items, as repetitive as
/// a rendered page and no more.
fn gzip_body() -> String {
  let item = fn(i) {
    let n = int.to_string(i)
    "<li class=\"row\" data-id=\""
    <> n
    <> "\"><span>Row "
    <> n
    <> "</span><a href=\"/items/"
    <> int.to_string(i * 7919 % 100_003)
    <> "\">open</a></li>\n"
  }
  let items =
    int.range(from: 1, to: 2000, with: [], run: fn(acc, i) { [item(i), ..acc] })
    |> list.reverse
    |> string.concat
  let page = "<!doctype html><html><body><ul>\n" <> items
  string.slice(page, 0, gzip_body_bytes)
}

// --- ssr ---

type Row {
  Row(id: Int, label: String)
}

type RowsModel {
  RowsModel(rows: List(Row), selected: Int)
}

type RowsMsg {
  Select(id: Int)
}

fn rows_view(model: RowsModel) -> Element(RowsMsg) {
  html.div([attribute.class("rows")], [
    html.p([], [html.text("selected " <> int.to_string(model.selected))]),
    html.ul(
      [],
      list.map(model.rows, fn(row) {
        html.li(
          [
            attribute.class(case row.id == model.selected {
              True -> "row selected"
              False -> "row"
            }),
            event.on_click(Select(row.id)),
          ],
          [
            html.span([], [html.text(int.to_string(row.id))]),
            html.span([], [html.text(row.label)]),
          ],
        )
      }),
    ),
  ])
}

fn rows_model(count: Int) -> RowsModel {
  RowsModel(
    rows: int.range(from: count, to: 0, with: [], run: fn(acc, i) {
      [Row(id: i, label: "row label number " <> int.to_string(i)), ..acc]
    }),
    selected: 0,
  )
}

fn ssr_scenario(page: #(Int, Int)) -> Result(List(Metric), String) {
  let #(ssr_rows, ssr_requests) = page
  let name = "ssr.rows_" <> int.to_string(ssr_rows)
  let config =
    ssr.SsrConfig(
      init: fn(_ctx) { Ok(#(rows_model(ssr_rows), effect.none())) },
      update: fn(model: RowsModel, msg: RowsMsg) {
        case msg {
          Select(id:) -> #(RowsModel(..model, selected: id), effect.none())
        }
      },
      route: None,
      view: rows_view,
      title: fn(_) { "Rows" },
      secret_key: "bench-secret-key-that-is-long-enough-for-hmac",
      head_html: None,
      dev_mode: False,
      recovery_encoder: None,
      stream_limits: stream_window.default_limits(),
    )
  let listener =
    transport.TransportConfig(
      ..base_config(ssr_requests),
      ssr_factory: Some(fn(req, _path) { ssr.render_page(config, req) }),
    )
  use port <- with_listener(name, listener)
  let request = get("/", [])
  use #(status, headers, page) <- result.try(http_fetch(
    port,
    request,
    measure.timeout_ms,
  ))
  use <- check(status == 200, "the probe got a " <> int.to_string(status))
  use html <- result.try(
    bit_array.to_string(page)
    |> result.replace_error("the page is not UTF-8"),
  )
  let rendered_rows = list.length(string.split(html, "row label number ")) - 1
  use <- check(
    rendered_rows == ssr_rows,
    "the page holds " <> int.to_string(rendered_rows) <> " rows",
  )
  use <- check(
    string.contains(html, "brazier_client_"),
    "the page does not load the client bundle",
  )
  use content_type <- result.try(header(headers, "content-type"))
  timed(
    name,
    port,
    ssr_clients,
    ssr_requests,
    request,
    #(200, bit_array.byte_size(page), [#("content-type", content_type)]),
  )
}

type LogModel {
  LogModel(picked: String)
}

type LogMsg {
  Picked(id: String)
}

fn ssr_stream_scenario() -> Result(List(Metric), String) {
  let name = "ssr.stream_" <> int.to_string(stream_bench.stream_limit)
  let config =
    ssr.SsrConfig(
      init: fn(_ctx) {
        Ok(#(
          LogModel(picked: ""),
          stream.insert_many(
            stream_bench.log(),
            stream_bench.initial_lines(),
            at: stream.Append,
          ),
        ))
      },
      update: fn(_model: LogModel, msg: LogMsg) {
        case msg {
          Picked(id:) -> #(LogModel(picked: id), effect.none())
        }
      },
      route: None,
      view: fn(model: LogModel) {
        html.div([attribute.class("log")], [
          html.p([], [html.text("picked " <> model.picked)]),
          stream.render(stream_bench.log(), "ol", [], fn(line) {
            stream_bench.render_line(line, Picked)
          }),
        ])
      },
      title: fn(_) { "Log" },
      secret_key: "bench-secret-key-that-is-long-enough-for-hmac",
      head_html: None,
      dev_mode: False,
      recovery_encoder: None,
      stream_limits: stream_window.default_limits(),
    )
  let listener =
    transport.TransportConfig(
      ..base_config(ssr_stream_requests),
      ssr_factory: Some(fn(req, _path) { ssr.render_page(config, req) }),
    )
  use port <- with_listener(name, listener)
  let request = get("/", [])
  use #(status, headers, page) <- result.try(http_fetch(
    port,
    request,
    measure.timeout_ms,
  ))
  use <- check(status == 200, "the probe got a " <> int.to_string(status))
  use html <- result.try(
    bit_array.to_string(page)
    |> result.replace_error("the page is not UTF-8"),
  )
  // Every item, keyed and in order: the text after each key attribute
  // starts with the next key.
  let keyed = case string.split(html, "data-brazier-key=\"") {
    [_before, ..items] ->
      list.map(items, fn(item) {
        case string.split_once(item, "\"") {
          Ok(#(key, _)) -> key
          Error(Nil) -> ""
        }
      })
    [] -> []
  }
  let expected = list.map(stream_bench.initial_lines(), fn(line) { line.id })
  use <- check(
    keyed == expected,
    "the page's keyed items are not the "
      <> int.to_string(stream_bench.stream_limit)
      <> " lines in order: "
      <> string.slice(string.join(keyed, ","), 0, 300),
  )
  use <- check(
    string.contains(html, "brazier_client_"),
    "the page does not load the client bundle",
  )
  use content_type <- result.try(header(headers, "content-type"))
  timed(
    name,
    port,
    ssr_clients,
    ssr_stream_requests,
    request,
    #(200, bit_array.byte_size(page), [#("content-type", content_type)]),
  )
}
