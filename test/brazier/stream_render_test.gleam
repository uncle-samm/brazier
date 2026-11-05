//// Tests for stream rendering: `stream.render`'s container node, the
//// container table, `render.render_item` with item-relative handler ids
//// (docs/design/STREAMS.md 8.2), `render.render_filled` and `element.map`
//// over a stream.

import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/internal/render
import brazier/internal/stream_op
import brazier/stream.{type Stream, KeepFirst, KeepLast}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/string

pub type Line {
  Line(id: Int, text: String)
}

pub type Msg {
  Picked(Int)
  Removed(Int)
}

pub type Outer {
  Inner(Msg)
}

fn encode_line(line: Line) -> json.Json {
  json.object([#("id", json.int(line.id)), #("text", json.string(line.text))])
}

fn line_decoder() -> decode.Decoder(Line) {
  use id <- decode.field("id", decode.int)
  use text <- decode.field("text", decode.string)
  decode.success(Line(id:, text:))
}

fn log() -> Stream(Line) {
  stream.new(
    "log",
    key: fn(line: Line) { "line-" <> int.to_string(line.id) },
    encode: encode_line,
    decoder: line_decoder(),
    limit: KeepLast(3),
  )
}

fn other() -> Stream(Line) {
  stream.new(
    "other",
    key: fn(line: Line) { int.to_string(line.id) },
    encode: encode_line,
    decoder: line_decoder(),
    limit: KeepFirst(10),
  )
}

pub fn render_line(line: Line) -> Element(Msg) {
  html.li([attribute.class("line")], [
    html.span([], [html.text(line.text)]),
    html.button([event.on_click(Picked(line.id))], [html.text("Pick")]),
    html.button([event.on_click(Removed(line.id))], [html.text("Remove")]),
  ])
}

fn item(line: Line) -> Dynamic {
  let assert Ok(value) =
    json.parse(json.to_string(encode_line(line)), decode.dynamic)
    as "the test item is JSON"
  value
}

fn the_container(view: Element(msg)) -> render.Container(msg) {
  let #(_html, _handlers, containers) =
    render.render_containers(element.to_node(view))
  let assert [container] = containers as "the view renders one stream"
  container
}

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, Dynamic))

fn click(handlers: render.Handlers(msg), id: String) -> msg {
  let assert Ok(handler) = render.lookup(handlers, "click", id)
    as "the item has a click handler at the id"
  let assert Ok(msg) = render.run(handler, dynamic.properties([]))
    as "the click handler decodes"
  msg
}

// --- The container --------------------------------------------------------

pub fn a_stream_renders_as_its_empty_container_test() {
  let view =
    html.main([], [
      html.h1([], [html.text("Log")]),
      stream.render(log(), "ol", [attribute.class("log")], render_line),
    ])
  let assert "<main><h1>Log</h1><ol data-brazier-stream=\"log\" class=\"log\"></ol></main>" =
    element.to_string(view)
}

pub fn the_container_table_lists_each_stream_in_document_order_test() {
  let view =
    html.div([], [
      stream.render(other(), "ul", [], render_line),
      stream.render(log(), "ol", [], render_line),
    ])
  let #(_html, _handlers, containers) =
    render.render_containers(element.to_node(view))
  let assert [first, second] = containers
  let assert "other" = first.name
  let assert stream_op.Limit(keep: stream_op.First, count: 10) = first.limit
  let assert "log" = second.name
  let assert stream_op.Limit(keep: stream_op.Last, count: 3) = second.limit
}

pub fn a_container_event_takes_its_positional_id_test() {
  let view =
    html.div([], [
      html.p([], []),
      stream.render(log(), "ol", [event.on_click(Picked(0))], render_line),
    ])
  let #(html, handlers, _containers) =
    render.render_containers(element.to_node(view))
  let assert True =
    string.contains(
      html,
      "<ol data-brazier-stream=\"log\" data-brazier-on-click=\"0.1\"></ol>",
    )
  let assert Picked(0) = click(handlers, "0.1")
}

pub fn item_ref_is_the_item_function_test() {
  let container = the_container(stream.render(log(), "ol", [], render_line))
  let assert True = container.item_ref == render.item_ref(render_line)
  let again = the_container(stream.render(log(), "ul", [], render_line))
  let assert True = container.item_ref == again.item_ref
  let other_fn = fn(line: Line) { html.li([], [html.text(line.text)]) }
  let different = the_container(stream.render(log(), "ol", [], other_fn))
  let assert False = container.item_ref == different.item_ref
}

pub fn a_keyed_container_carries_its_key_test() {
  let view =
    html.div([], [
      element.keyed("k", stream.render(log(), "ol", [], render_line)),
    ])
  let assert "<div><ol data-brazier-stream=\"log\" data-brazier-key=\"k\"></ol></div>" =
    element.to_string(view)
}

pub fn a_stream_rendered_twice_crashes_test() {
  let view =
    html.div([], [
      stream.render(log(), "ol", [], render_line),
      stream.render(log(), "ul", [], render_line),
    ])
  let assert Error(#("error", _)) = rescue(fn() { element.to_string(view) })
}

pub fn a_void_container_crashes_test() {
  let view = stream.render(log(), "br", [], render_line)
  let assert Error(#("error", _)) = rescue(fn() { element.to_string(view) })
}

pub fn the_stream_attribute_is_refused_when_built_test() {
  // Only the render of a stream sets the attribute that marks its
  // container, so a view cannot build it, in any case.
  let assert Error(#("error", _)) =
    rescue(fn() { attribute.attribute("data-brazier-stream", "x") })
  let assert Error(#("error", _)) =
    rescue(fn() { attribute.attribute("Data-Brazier-Stream", "x") })
  let assert Error(#("error", _)) =
    rescue(fn() { attribute.data("brazier-stream", "x") })
  let assert False = render.is_valid_attribute_name("DATA-BRAZIER-STREAM")
  // The whole `data-brazier-*` namespace is reserved, so names next to it
  // are refused too.
  let assert False = render.is_valid_attribute_name("data-brazier-streams")
  let assert False = render.is_valid_attribute_name("data-brazier-stream-x")
  let assert True = render.is_valid_attribute_name("data-stream")
}

pub fn the_stream_attribute_on_a_plain_element_crashes_the_render_test() {
  // A tree built with the internal constructors bypasses
  // `attribute.attribute`; the render refuses the attribute again, so the
  // client never patches an element that is not a stream's container.
  let plain =
    render.Element("div", [render.Attribute("data-brazier-stream", "log")], [])
  let assert Error(#("error", _)) = rescue(fn() { render.render(plain) })
  let shouting =
    render.Element("div", [render.Attribute("DATA-BRAZIER-STREAM", "log")], [])
  let assert Error(#("error", _)) = rescue(fn() { render.render(shouting) })
}

pub fn the_stream_attribute_on_a_container_crashes_the_render_test() {
  let assert render.Stream(name:, limit:, tag:, item:, item_ref:, ..) =
    element.to_node(stream.render(log(), "ol", [], render_line))
  let doubled =
    render.Stream(
      name:,
      limit:,
      tag:,
      attributes: [render.Attribute("data-brazier-stream", "other")],
      item:,
      item_ref:,
    )
  let assert Error(#("error", _)) = rescue(fn() { render.render(doubled) })
}

pub fn the_stream_attribute_in_an_item_is_refused_test() {
  let container = the_container(stream.render(log(), "ol", [], render_line))
  let marked =
    render.Container(..container, item: fn(_value) {
      Ok(
        render.Element("li", [], [
          render.Element(
            "ol",
            [render.Attribute("data-brazier-stream", "log")],
            [],
          ),
        ]),
      )
    })
  let assert Error(#("error", _)) =
    rescue(fn() { render.render_item(marked, "k", item(Line(1, "a"))) })
}

pub fn an_item_root_that_sets_its_own_key_is_refused_test() {
  // The stream keys an item's root; `data-brazier-key` is reserved, so the
  // constructor refuses it and the render refuses a directly built one.
  let assert Error(#("error", _)) =
    rescue(fn() { attribute.attribute("data-brazier-key", "own") })
  let container = the_container(stream.render(log(), "ol", [], render_line))
  let own_key =
    render.Container(..container, item: fn(_value) {
      Ok(
        render.Element("li", [render.Attribute("data-brazier-key", "own")], []),
      )
    })
  let assert Error(#("error", _)) =
    rescue(fn() { render.render_item(own_key, "k", item(Line(1, "a"))) })
  // A handler id forged on an item's element is refused the same way.
  let forged =
    render.Container(..container, item: fn(_value) {
      Ok(
        render.Element("li", [], [
          render.Element(
            "button",
            [render.Attribute("data-brazier-on-click", "0.1")],
            [],
          ),
        ]),
      )
    })
  let assert Error(#("error", _)) =
    rescue(fn() { render.render_item(forged, "k", item(Line(1, "a"))) })
}

pub fn a_bad_container_tag_crashes_test() {
  let assert Error(#("error", _)) =
    rescue(fn() { stream.render(log(), "ol x=1", [], render_line) })
}

// --- Items ----------------------------------------------------------------

pub fn an_item_is_keyed_with_item_relative_ids_test() {
  let container = the_container(stream.render(log(), "ol", [], render_line))
  let assert Ok(#(html, handlers)) =
    render.render_item(container, "line-7", item(Line(7, "a < b")))
  let assert "<li data-brazier-key=\"line-7\" class=\"line\"><span>a &lt; b</span><button data-brazier-on-click=\"i0.1\">Pick</button><button data-brazier-on-click=\"i0.2\">Remove</button></li>" =
    html
  let assert ["click:i0.1", "click:i0.2"] = render.keys(handlers)
  let assert ["click"] = render.event_names(handlers)
  let assert Picked(7) = click(handlers, "i0.1")
  let assert Removed(7) = click(handlers, "i0.2")
}

pub fn an_item_html_does_not_depend_on_where_the_stream_is_test() {
  let shallow = the_container(stream.render(log(), "ol", [], render_line))
  let deep =
    the_container(
      html.div([], [
        html.p([], []),
        html.section([], [stream.render(log(), "ol", [], render_line)]),
      ]),
    )
  let line = item(Line(1, "x"))
  let assert Ok(#(a, _)) = render.render_item(shallow, "line-1", line)
  let assert Ok(#(b, _)) = render.render_item(deep, "line-1", line)
  let assert True = a == b
}

pub fn an_item_that_does_not_decode_is_an_error_test() {
  let container = the_container(stream.render(log(), "ol", [], render_line))
  let assert Ok(bad) = json.parse("{\"id\":\"seven\"}", decode.dynamic)
  let assert Error(reason) = render.render_item(container, "line-7", bad)
  let assert True =
    string.contains(reason, "stream log, item line-7: does not decode")
  let assert True = string.contains(reason, "expected Int at id")
}

fn root_error(item_fn: fn(Line) -> Element(Msg)) -> String {
  let container = the_container(stream.render(log(), "ol", [], item_fn))
  let assert Error(reason) =
    render.render_item(container, "line-1", item(Line(1, "x")))
  reason
}

pub fn text_root(line: Line) -> Element(Msg) {
  html.text(line.text)
}

pub fn none_root(_line: Line) -> Element(Msg) {
  element.none()
}

pub fn raw_root(line: Line) -> Element(Msg) {
  element.unsafe_raw_html("<li>" <> line.text <> "</li>")
}

pub fn keyed_root(line: Line) -> Element(Msg) {
  element.keyed("own", html.li([], [html.text(line.text)]))
}

pub fn stream_root(_line: Line) -> Element(Msg) {
  stream.render(other(), "ol", [], render_line)
}

pub fn nested_stream(line: Line) -> Element(Msg) {
  html.li([], [
    html.text(line.text),
    stream.render(other(), "ol", [], render_line),
  ])
}

pub fn an_item_root_must_be_one_element_test() {
  let assert True = string.contains(root_error(text_root), "root is text")
  let assert True =
    string.contains(root_error(none_root), "root is element.none")
  let assert True =
    string.contains(root_error(raw_root), "root is unsafe_raw_html")
  let assert True =
    string.contains(root_error(keyed_root), "root is element.keyed")
  let assert True =
    string.contains(root_error(stream_root), "root is the stream other")
}

pub fn a_stream_inside_an_item_is_an_error_test() {
  let assert True =
    string.contains(
      root_error(nested_stream),
      "stream log, item line-1: the item renders the stream other inside it",
    )
}

// --- element.map ----------------------------------------------------------

pub fn element_map_composes_onto_the_item_test() {
  let view =
    html.div([], [stream.render(log(), "ol", [], render_line)])
    |> element.map(Inner)
  let container = the_container(view)
  let assert True = container.item_ref == render.item_ref(render_line)
  let assert Ok(#(_html, handlers)) =
    render.render_item(container, "line-3", item(Line(3, "x")))
  let assert Inner(Picked(3)) = click(handlers, "i0.1")
}

pub fn element_map_maps_the_container_events_test() {
  let view =
    stream.render(log(), "ol", [event.on_click(Picked(9))], render_line)
    |> element.map(Inner)
  let #(_html, handlers, _containers) =
    render.render_containers(element.to_node(view))
  let assert Inner(Picked(9)) = click(handlers, "0")
}

// --- render_filled --------------------------------------------------------

pub fn render_filled_puts_each_fill_in_its_container_test() {
  let view =
    html.div([], [
      stream.render(log(), "ol", [], render_line),
      stream.render(other(), "ul", [], render_line),
    ])
  let assert Ok(html) =
    render.render_filled(element.to_node(view), fn(container) {
      Ok("<li>" <> container.name <> "</li>")
    })
  let assert "<div><ol data-brazier-stream=\"log\"><li>log</li></ol><ul data-brazier-stream=\"other\"><li>other</li></ul></div>" =
    html
}

pub fn render_filled_reports_every_fill_error_test() {
  let view =
    html.div([], [
      stream.render(log(), "ol", [], render_line),
      stream.render(other(), "ul", [], render_line),
    ])
  let assert Error("log failed; other failed") =
    render.render_filled(element.to_node(view), fn(container) {
      Error(container.name <> " failed")
    })
}
