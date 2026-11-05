//// Tests for streams in the dead render (docs/design/STREAMS.md 7.6): the
//// stream ops of `init` and of the route message fill the page's
//// containers, with the runtime's bounds, and an item that does not decode
//// crashes the render.

import brazier/attribute
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/internal/stream_window
import brazier/log_capture
import brazier/ssr
import brazier/stream.{type Stream, Append, KeepLast, Prepend}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http/request
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/uri.{type Uri}
import logging

pub type Line {
  Line(id: Int, text: String)
}

pub type Model {
  Model(title: String)
}

pub type Msg {
  Routed(String)
  Picked(Int)
}

fn encode_line(line: Line) -> json.Json {
  json.object([#("id", json.int(line.id)), #("text", json.string(line.text))])
}

fn line_decoder() -> decode.Decoder(Line) {
  use id <- decode.field("id", decode.int)
  use text <- decode.field("text", decode.string)
  decode.success(Line(id:, text:))
}

fn line_key(line: Line) -> String {
  "line-" <> int.to_string(line.id)
}

fn log() -> Stream(Line) {
  stream.new(
    "log",
    key: line_key,
    encode: encode_line,
    decoder: line_decoder(),
    limit: KeepLast(2),
  )
}

/// The same name with another limit, as a second declaration would have.
fn log_with_another_limit() -> Stream(Line) {
  stream.new(
    "log",
    key: line_key,
    encode: encode_line,
    decoder: line_decoder(),
    limit: KeepLast(5),
  )
}

/// Encodes `id` as a string, which `line_decoder` refuses.
fn broken_log() -> Stream(Line) {
  stream.new(
    "log",
    key: line_key,
    encode: fn(line: Line) {
      json.object([
        #("id", json.string(int.to_string(line.id))),
        #("text", json.string(line.text)),
      ])
    },
    decoder: line_decoder(),
    limit: KeepLast(2),
  )
}

pub fn render_line(line: Line) -> Element(Msg) {
  html.li([], [
    html.text(line.text),
    html.button([event.on_click(Picked(line.id))], [html.text("Pick")]),
  ])
}

fn view(model: Model) -> Element(Msg) {
  html.main([], [
    html.h1([], [html.text(model.title)]),
    stream.render(log(), "ol", [attribute.class("log")], render_line),
  ])
}

fn config(
  init_effect: Effect(Msg),
  route_effect: fn(String) -> Effect(Msg),
) -> ssr.SsrConfig(Model, Msg) {
  ssr.SsrConfig(
    init: fn(_ctx) { Ok(#(Model(title: "start"), init_effect)) },
    update: fn(_model, msg) {
      case msg {
        Routed(page) -> #(Model(title: page), route_effect(page))
        Picked(_) -> #(Model(title: "picked"), effect.none())
      }
    },
    route: None,
    view: view,
    title: fn(_model) { "Streams" },
    secret_key: "test-secret-key-at-least-32-chars-long!!",
    head_html: None,
    dev_mode: False,
    recovery_encoder: None,
    stream_limits: stream_window.default_limits(),
    stream_names: ["log"],
  )
}

fn routed(
  init_effect: Effect(Msg),
  route_effect: fn(String) -> Effect(Msg),
) -> ssr.SsrConfig(Model, Msg) {
  ssr.SsrConfig(
    ..config(init_effect, route_effect),
    route: Some(fn(page: Uri) { Ok(Routed(page.path)) }),
  )
}

fn no_route_effect(_page: String) -> Effect(Msg) {
  effect.none()
}

fn render(config: ssr.SsrConfig(Model, Msg)) -> ssr.RenderedPage {
  let assert Ok(_) = ssr.load_client_bundle()
    as "the repository's priv/static must hold a built runtime bundle"
  ssr.render_page(config, request.new() |> request.set_path("/feed"))
}

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))

fn container_html(page: ssr.RenderedPage) -> String {
  let assert Ok(#(_, rest)) =
    string.split_once(
      page.html,
      "<ol data-brazier-stream=\"log\" class=\"log\">",
    )
    as "the page renders the log container"
  let assert Ok(#(inner, _)) = string.split_once(rest, "</ol>")
    as "the log container is closed"
  inner
}

fn li(id: Int, text: String) -> String {
  "<li data-brazier-key=\"line-"
  <> int.to_string(id)
  <> "\">"
  <> text
  <> "<button data-brazier-on-click=\"i0.1\">Pick</button></li>"
}

// --- Filling the containers -----------------------------------------------

pub fn init_ops_fill_the_container_keyed_test() {
  let page =
    render(config(
      stream.insert_many(log(), [Line(1, "one"), Line(2, "two")], at: Append),
      no_route_effect,
    ))
  let assert 200 = page.status
  let assert True = container_html(page) == li(1, "one") <> li(2, "two")
}

pub fn the_container_holds_the_window_after_trims_test() {
  // KeepLast(2): the third append trims the first item, a prepend into the
  // full window trims itself, and an update keeps its place.
  let init =
    effect.batch([
      stream.insert_many(
        log(),
        [Line(1, "one"), Line(2, "two"), Line(3, "three")],
        at: Append,
      ),
      stream.insert(log(), Line(0, "zero"), at: Prepend),
      stream.insert(log(), Line(2, "two again"), at: Append),
    ])
  let page = render(config(init, no_route_effect))
  let assert True = container_html(page) == li(2, "two again") <> li(3, "three")
}

pub fn route_ops_apply_after_init_ops_test() {
  let init = stream.insert(log(), Line(1, "one"), at: Append)
  let route = fn(page: String) {
    effect.batch([
      stream.delete_key(log(), "line-1"),
      stream.insert(log(), Line(5, page), at: Append),
    ])
  }
  let page = render(routed(init, route))
  let assert True = string.contains(page.html, "<h1>/feed</h1>")
  let assert True = container_html(page) == li(5, "/feed")
}

pub fn a_route_reset_empties_what_init_filled_test() {
  let init = stream.insert(log(), Line(1, "one"), at: Append)
  let route = fn(_page) { stream.reset(log(), []) }
  let page = render(routed(init, route))
  let assert "" = container_html(page)
}

pub fn a_view_without_ops_renders_an_empty_container_test() {
  let page = render(config(effect.none(), no_route_effect))
  let assert "" = container_html(page)
}

pub fn the_other_effects_are_still_dropped_test() {
  let init =
    effect.batch([
      stream.insert(log(), Line(1, "one"), at: Append),
      effect.from(fn(_dispatch) { Nil }),
    ])
  let #(page, logs) =
    log_capture.capture_at(logging.Debug, fn() {
      render(config(init, no_route_effect))
    })
  let assert True = container_html(page) == li(1, "one")
  let assert True =
    log_capture.has(logs, level: "debug", containing: [
      "Not running init effects during the dead render of \"/feed\"",
    ])
}

pub fn effects_of_stream_ops_only_are_not_reported_as_dropped_test() {
  let init = stream.insert(log(), Line(1, "one"), at: Append)
  let #(_page, logs) =
    log_capture.capture_at(logging.Debug, fn() {
      render(config(init, no_route_effect))
    })
  let assert False =
    log_capture.has(logs, level: "debug", containing: ["Not running init"])
}

// --- Bounds ---------------------------------------------------------------

fn small_limits(base: ssr.SsrConfig(Model, Msg)) -> ssr.SsrConfig(Model, Msg) {
  ssr.SsrConfig(
    ..base,
    stream_limits: stream_window.Limits(
      ..stream_window.default_limits(),
      item_max_bytes: 30,
      ops_max_per_update: 3,
    ),
  )
}

pub fn a_refused_op_is_logged_and_not_rendered_test() {
  let init =
    stream.insert_many(
      log(),
      [Line(1, "one"), Line(2, string.repeat("x", 40))],
      at: Append,
    )
  let #(page, logs) =
    log_capture.capture(fn() {
      render(small_limits(config(init, no_route_effect)))
    })
  let assert True = container_html(page) == li(1, "one")
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "Refused stream op 1 on stream log (init, dead render of \"/feed\")",
      "over the limit of 30",
    ])
}

pub fn an_update_over_the_op_bound_is_refused_whole_test() {
  let init = stream.insert(log(), Line(9, "kept"), at: Append)
  let route = fn(_page) {
    stream.insert_many(
      log(),
      [Line(1, "a"), Line(2, "b"), Line(3, "c"), Line(4, "d")],
      at: Append,
    )
  }
  let #(page, logs) =
    log_capture.capture(fn() { render(small_limits(routed(init, route))) })
  let assert True = container_html(page) == li(9, "kept")
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "Refused every stream op (route update, dead render of \"/feed\")",
      "4 stream ops, over the limit of 3",
    ])
}

pub fn an_unknown_delete_is_logged_at_warning_test() {
  let init = stream.delete_key(log(), "line-404")
  let #(page, logs) =
    log_capture.capture(fn() { render(config(init, no_route_effect)) })
  let assert "" = container_html(page)
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "deletes key line-404, which stream log does not hold",
    ])
}

// --- Undeclared streams ---------------------------------------------------

/// A stream the build did not declare: `config` declares only `log`.
fn ghost() -> Stream(Line) {
  stream.new(
    "ghost",
    key: line_key,
    encode: encode_line,
    decoder: line_decoder(),
    limit: KeepLast(2),
  )
}

pub fn ops_on_an_undeclared_stream_are_refused_as_unknown_test() {
  let init =
    effect.batch([
      stream.insert(ghost(), Line(7, "boo"), at: Append),
      stream.insert(log(), Line(1, "one"), at: Append),
      stream.delete_key(ghost(), "line-7"),
    ])
  let #(page, logs) =
    log_capture.capture(fn() { render(config(init, no_route_effect)) })
  // The declared stream's op still applies; the two ghost ops are one line.
  let assert True = container_html(page) == li(1, "one")
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "Refused 2 stream op(s) on stream ghost (unknown_stream, init, dead render of \"/feed\")",
      "the build declared no stream with this name",
    ])
  let assert False = string.contains(page.html, "boo")
}

pub fn route_ops_on_an_undeclared_stream_are_refused_as_unknown_test() {
  let route = fn(_page) { stream.insert(ghost(), Line(7, "boo"), at: Append) }
  let #(page, logs) =
    log_capture.capture(fn() { render(routed(effect.none(), route)) })
  let assert 200 = page.status
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "Refused 1 stream op(s) on stream ghost (unknown_stream, route update, dead render of \"/feed\")",
    ])
}

pub fn a_build_without_the_stream_refuses_the_view_s_stream_test() {
  // The view renders `log`, but the build declared no stream: its ops are
  // refused, as the runtime refuses them, and the container stays empty.
  let init = stream.insert(log(), Line(1, "one"), at: Append)
  let #(page, logs) =
    log_capture.capture(fn() {
      render(ssr.SsrConfig(..config(init, no_route_effect), stream_names: []))
    })
  let assert "" = container_html(page)
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "Refused 1 stream op(s) on stream log (unknown_stream, init, dead render of \"/feed\")",
    ])
}

// --- Failures crash the dead render ---------------------------------------

pub fn an_item_that_does_not_decode_crashes_the_render_test() {
  let init = stream.insert(broken_log(), Line(1, "one"), at: Append)
  let #(outcome, logs) =
    log_capture.capture(fn() {
      rescue(fn() { render(config(init, no_route_effect)) })
    })
  let assert Error(#("error", _)) = outcome
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "A stream item does not render in the dead render of \"/feed\"",
      "stream log, item line-1: does not decode",
      "expected Int at id",
    ])
}

pub fn ops_with_another_limit_than_the_view_crash_the_render_test() {
  let init = stream.insert(log_with_another_limit(), Line(1, "one"), at: Append)
  let #(outcome, logs) =
    log_capture.capture(fn() {
      rescue(fn() { render(config(init, no_route_effect)) })
    })
  let assert Error(#("error", _)) = outcome
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "stream log: its ops use KeepLast(5) and the view renders it with KeepLast(2)",
    ])
}
