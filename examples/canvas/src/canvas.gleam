/// Collaborative canvas, demonstrating:
/// - a pointer trail in Local state: `mousemove` is decoded with
///   `event.mouse_position`, throttled, and handled in the browser, so a
///   stroke costs no traffic while it is drawn;
/// - a finished stroke forwarded to the server in one message, which the
///   view builds from Local state;
/// - strokes shared by every session in a `beacon/store` list, re-read when
///   any session draws or clears;
/// - SVG rendering with `beacon/svg`.
import beacon
import beacon/attribute
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/event
import beacon/html
import beacon/local
import beacon/log
import beacon/store.{type ListStore}
import beacon/svg
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

// --- Types ---

pub type Point {
  Point(x: Int, y: Int)
}

/// One pen-down to pen-up trail.
pub type Stroke {
  Stroke(colour: String, points: List(Point))
}

/// Synced to the browser. The server holds nothing else, so it is also the
/// server state.
pub type Model {
  Model(
    strokes: List(Stroke),
    /// How many `PenUp` messages from this session the server has handled,
    /// accepted or rejected.
    pen_ups: Int,
  )
}

/// A stroke sent to the server. `number` is the value `Model.pen_ups` takes
/// once the server has handled it.
pub type Sent {
  Sent(number: Int, stroke: Stroke)
}

/// Client-only.
pub type Local {
  Local(
    colour: String,
    /// The stroke being drawn, newest point first.
    drawing: Option(Stroke),
    /// Sent strokes the server has not handled yet, newest first. The view
    /// draws them, so a stroke does not blink out while the server's update
    /// is in flight.
    sent: List(Sent),
  )
}

pub type Msg {
  PenDown(Point)
  PenMoved(Point)
  /// The finished stroke, oldest point first.
  PenUp(Stroke)
  ColourPicked(String)
  ClearCanvas
  /// A session (this one included) drew or cleared.
  StrokesChanged
}

const width = 760

const height = 500

const palette = [
  "#000000", "#ff0000", "#0000ff", "#00aa00", "#ff8800", "#8800ff",
]

/// About 60 samples a second while the pointer moves.
const move_throttle_ms = 16

const max_points_per_stroke = 2000

const max_strokes = 2000

const strokes_key = "canvas"

// --- Server ---

fn read_strokes(strokes: ListStore(Stroke)) -> List(Stroke) {
  store.get_all(strokes, strokes_key)
}

fn init(
  strokes: ListStore(Stroke),
) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model(strokes: read_strokes(strokes), pen_ups: 0), effect.none()))
}

fn update(
  strokes: ListStore(Stroke),
  model: Model,
  msg: Msg,
) -> #(Model, Effect(Msg)) {
  case msg {
    PenUp(stroke) -> {
      let model = Model(..model, pen_ups: model.pen_ups + 1)
      case validate_stroke(stroke, list.length(model.strokes)) {
        Ok(stroke) -> {
          log.info(
            "canvas",
            "Stroke of "
              <> int.to_string(list.length(stroke.points))
              <> " points in "
              <> stroke.colour,
          )
          // Shown at once; `StrokesChanged` re-reads the store, other
          // sessions' strokes included.
          #(
            Model(..model, strokes: list.append(model.strokes, [stroke])),
            effect.from(fn(_dispatch) {
              store.append(strokes, strokes_key, stroke)
            }),
          )
        }
        Error(reason) -> {
          log.warning("canvas", "Rejected a stroke: " <> reason)
          #(model, effect.none())
        }
      }
    }
    ClearCanvas -> {
      log.info("canvas", "Canvas cleared")
      #(
        Model(..model, strokes: []),
        effect.from(fn(_dispatch) { store.delete_all(strokes, strokes_key) }),
      )
    }
    StrokesChanged -> #(
      Model(..model, strokes: read_strokes(strokes)),
      effect.none(),
    )
    // `update_local` handles these in the browser and never forwards them.
    PenDown(_) | PenMoved(_) | ColourPicked(_) -> #(model, effect.none())
  }
}

/// The browser builds strokes, so the server checks every field.
fn validate_stroke(stroke: Stroke, existing: Int) -> Result(Stroke, String) {
  let point_count = list.length(stroke.points)
  case
    list.contains(palette, stroke.colour),
    point_count,
    list.find(stroke.points, fn(p) { !in_bounds(p) })
  {
    _, _, _ if existing >= max_strokes ->
      Error("the canvas holds " <> int.to_string(max_strokes) <> " strokes")
    False, _, _ -> Error("colour " <> string.inspect(stroke.colour))
    True, 0, _ -> Error("no points")
    True, n, _ if n > max_points_per_stroke ->
      Error(
        int.to_string(n)
        <> " points (max "
        <> int.to_string(max_points_per_stroke)
        <> ")",
      )
    True, _, Ok(p) ->
      Error(
        "point ("
        <> int.to_string(p.x)
        <> ","
        <> int.to_string(p.y)
        <> ") outside the canvas",
      )
    True, _, Error(Nil) -> Ok(stroke)
  }
}

fn in_bounds(point: Point) -> Bool {
  point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= height
}

fn sync(model: Model) -> Model {
  model
}

// --- Local (browser) ---

pub fn init_local(_model: Model) -> Local {
  Local(colour: "#000000", drawing: None, sent: [])
}

pub fn update_local(
  model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    PenDown(point) ->
      local.handled(
        Local(
          ..local,
          drawing: Some(Stroke(colour: local.colour, points: [point])),
          sent: awaiting(model, local),
        ),
      )
    PenMoved(point) ->
      case local.drawing {
        Some(stroke) ->
          local.handled(
            Local(
              ..local,
              drawing: Some(Stroke(..stroke, points: [point, ..stroke.points])),
            ),
          )
        None -> local.handled(local)
      }
    // The view attaches `PenUp` only while drawing.
    PenUp(stroke) -> {
      let still_awaiting = awaiting(model, local)
      // The awaiting strokes hold the numbers after the server's count, so
      // this one follows them. Counting from the server's number keeps the
      // numbering right even if the server handled a PenUp this layer never
      // saw.
      let number = model.pen_ups + list.length(still_awaiting) + 1
      local.forward(
        Local(..local, drawing: None, sent: [
          Sent(number:, stroke:),
          ..still_awaiting
        ]),
      )
    }
    ColourPicked(colour) -> local.handled(Local(..local, colour:))
    ClearCanvas -> local.forward(Local(..local, drawing: None))
    StrokesChanged -> local.forward(local)
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> Element(Msg) {
  let finishing = case local.drawing {
    Some(stroke) -> [
      event.on_mouse_up(PenUp(finished(stroke))),
      event.on_mouse_leave(PenUp(finished(stroke))),
    ]
    None -> []
  }
  let in_progress = case local.drawing {
    Some(stroke) -> [stroke]
    None -> []
  }
  html.div(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "800px"),
        #("margin", "2rem auto"),
        #("padding", "0 1rem"),
      ]),
    ],
    [
      html.h1([], [html.text("Collaborative Canvas")]),
      html.p(
        [attribute.styles([#("color", "#666"), #("margin-bottom", "1rem")])],
        [
          html.text(
            "Draw together in several tabs. Strokes: "
            <> int.to_string(list.length(model.strokes)),
          ),
        ],
      ),
      html.div(
        [
          attribute.styles([
            #("margin-bottom", "1rem"),
            #("display", "flex"),
            #("gap", "8px"),
            #("align-items", "center"),
          ]),
        ],
        list.append(
          list.map(palette, fn(colour) { colour_button(colour, local.colour) }),
          [
            html.button(
              [
                event.on_click(ClearCanvas),
                attribute.styles([
                  #("margin-left", "auto"),
                  #("padding", "6px 16px"),
                  #("background", "#f44336"),
                  #("color", "white"),
                  #("border", "none"),
                  #("border-radius", "4px"),
                  #("cursor", "pointer"),
                ]),
              ],
              [html.text("Clear")],
            ),
          ],
        ),
      ),
      svg.svg(
        [
          attribute.data("canvas", ""),
          svg.width(int.to_string(width)),
          svg.height(int.to_string(height)),
          svg.viewbox(
            "0 0 " <> int.to_string(width) <> " " <> int.to_string(height),
          ),
          attribute.styles([
            #("border", "2px solid #ddd"),
            #("border-radius", "8px"),
            #("background", "#fafafa"),
            #("cursor", "crosshair"),
            #("display", "block"),
          ]),
          // Prevented so a drag draws instead of selecting text.
          event.on("mousedown", decode.map(position(), PenDown))
            |> event.prevent_default,
          event.on("mousemove", decode.map(position(), PenMoved))
            |> event.throttle(move_throttle_ms),
          ..finishing
        ],
        // Strokes ignore the pointer, so `offsetX` and `offsetY` are always
        // relative to the canvas.
        [
          svg.g(
            [attribute.attribute("pointer-events", "none")],
            list.map(
              list.flatten([
                model.strokes,
                awaiting(model, local)
                  |> list.reverse
                  |> list.map(fn(sent) { sent.stroke }),
                in_progress,
              ]),
              render_stroke,
            ),
          ),
        ],
      ),
      html.div(
        [
          attribute.styles([
            #("margin-top", "0.5rem"),
            #("font-size", "0.85rem"),
            #("color", "#999"),
          ]),
        ],
        [
          html.text(case local.drawing, list.length(model.strokes) {
            _, count if count >= max_strokes ->
              "The canvas is full. Clear it to draw more."
            Some(stroke), _ ->
              "Drawing, "
              <> int.to_string(list.length(stroke.points))
              <> " points"
            None, _ -> "Click and drag to draw"
          }),
        ],
      ),
    ],
  )
}

/// `#(offsetX, offsetY)` rounded to whole pixels.
fn position() -> decode.Decoder(Point) {
  use #(x, y) <- decode.then(event.mouse_position())
  decode.success(Point(x: float.round(x), y: float.round(y)))
}

/// Sent strokes the server has not handled yet, newest first. Once it has,
/// the model holds the stroke, or the server rejected it, or a clear
/// removed it.
fn awaiting(model: Model, local: Local) -> List(Sent) {
  list.filter(local.sent, fn(sent) { sent.number > model.pen_ups })
}

fn finished(stroke: Stroke) -> Stroke {
  Stroke(..stroke, points: list.reverse(stroke.points))
}

fn render_stroke(stroke: Stroke) -> Element(Msg) {
  // A single point is drawn as a dot: a zero-length line with round caps.
  let points = case stroke.points {
    [only] -> [only, only]
    points -> points
  }
  svg.polyline([
    svg.points(
      list.map(points, fn(p) { int.to_string(p.x) <> "," <> int.to_string(p.y) })
      |> string.join(" "),
    ),
    svg.fill("none"),
    svg.stroke(stroke.colour),
    svg.stroke_width("3"),
    svg.stroke_linecap("round"),
    svg.stroke_linejoin("round"),
  ])
}

fn colour_button(colour: String, selected: String) -> Element(Msg) {
  let border = case colour == selected {
    True -> "3px solid #333"
    False -> "1px solid #ccc"
  }
  html.button(
    [
      event.on_click(ColourPicked(colour)),
      attribute.aria("label", "Colour " <> colour),
      attribute.styles([
        #("width", "32px"),
        #("height", "32px"),
        #("background", colour),
        #("border", border),
        #("border-radius", "4px"),
        #("cursor", "pointer"),
      ]),
    ],
    [],
  )
}

// --- Start ---

pub fn main() {
  let strokes = store.new_list("canvas_strokes")
  let assert Ok(Nil) =
    beacon.full_application(
      init: fn(_ctx) { init(strokes) },
      update: fn(model, msg) { update(strokes, model, msg) },
      sync:,
      local: local.layer(init: init_local, update: update_local),
      view:,
    )
    |> beacon.title(fn(_model) { "Collaborative Canvas" })
    |> beacon.subscriptions(fn(_model) { [store.list_topic(strokes)] })
    |> beacon.on_notify(fn(_topic) { StrokesChanged })
    |> beacon.head_html(favicon)
    |> beacon.start(8080)
    as "beacon.start failed (it logs the error)"
}
