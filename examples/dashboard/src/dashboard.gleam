/// Live Dashboard, demonstrating:
/// - server push with `effect.every` (no client events needed);
/// - real BEAM runtime metrics, read on the server only;
/// - SVG sparklines rendered with `beacon/svg`.
import beacon
import beacon/attribute
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/html
import beacon/svg
import gleam/float
import gleam/int
import gleam/list
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

// --- Types ---

pub type Model {
  Model(
    process_count: Int,
    memory_mb: Float,
    uptime_seconds: Int,
    /// The last `max_history` samples, oldest first, for the sparklines.
    process_history: List(Int),
    memory_history: List(Float),
    tick_count: Int,
  )
}

pub type Msg {
  RefreshStats
}

const max_history = 30

const refresh_ms = 1000

// --- Runtime metrics (server only) ---

@external(erlang, "dashboard_ffi", "process_count")
fn process_count() -> Int

@external(erlang, "dashboard_ffi", "memory_total")
fn memory_total_bytes() -> Int

@external(erlang, "dashboard_ffi", "uptime_seconds")
fn uptime_seconds() -> Int

fn memory_mb() -> Float {
  int.to_float(memory_total_bytes()) /. 1_048_576.0
}

// --- Init and update (server) ---

fn init(
  _ctx: beacon.Context,
) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  let processes = process_count()
  let memory = memory_mb()
  Ok(#(
    Model(
      process_count: processes,
      memory_mb: memory,
      uptime_seconds: uptime_seconds(),
      process_history: [processes],
      memory_history: [memory],
      tick_count: 0,
    ),
    // Runs on the connected mount only; the HTML render drops it.
    effect.every(refresh_ms, fn() { RefreshStats }),
  ))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RefreshStats -> {
      let processes = process_count()
      let memory = memory_mb()
      #(
        Model(
          process_count: processes,
          memory_mb: memory,
          uptime_seconds: uptime_seconds(),
          process_history: push_sample(model.process_history, processes),
          memory_history: push_sample(model.memory_history, memory),
          tick_count: model.tick_count + 1,
        ),
        effect.none(),
      )
    }
  }
}

/// Append a sample, keeping the newest `max_history`.
fn push_sample(history: List(a), sample: a) -> List(a) {
  let history = list.append(history, [sample])
  list.drop(history, int.max(0, list.length(history) - max_history))
}

// --- View ---

pub fn view(model: Model) -> Element(Msg) {
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
      html.h1([], [html.text("Live Dashboard")]),
      html.p([attribute.style("color", "#666")], [
        html.text(
          "Auto-refreshes every second, with no client interaction. Tick #",
        ),
        html.span([attribute.id("tick")], [
          html.text(int.to_string(model.tick_count)),
        ]),
      ]),
      html.div(
        [
          attribute.styles([
            #("display", "grid"),
            #("grid-template-columns", "repeat(3,1fr)"),
            #("gap", "1rem"),
            #("margin", "1.5rem 0"),
          ]),
        ],
        [
          metric_card(
            "Processes",
            int.to_string(model.process_count),
            "#4CAF50",
          ),
          metric_card(
            "Memory",
            one_decimal(model.memory_mb) <> " MB",
            "#2196F3",
          ),
          metric_card("Uptime", format_uptime(model.uptime_seconds), "#FF9800"),
        ],
      ),
      html.div(
        [
          attribute.styles([
            #("display", "grid"),
            #("grid-template-columns", "1fr 1fr"),
            #("gap", "1rem"),
          ]),
        ],
        [
          sparkline_card(
            "Process Count",
            list.map(model.process_history, int.to_float),
            "#4CAF50",
          ),
          sparkline_card("Memory (MB)", model.memory_history, "#2196F3"),
        ],
      ),
    ],
  )
}

fn metric_card(label: String, value: String, colour: String) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("background", "#f8f9fa"),
        #("border-radius", "8px"),
        #("padding", "1.5rem"),
        #("border-left", "4px solid " <> colour),
      ]),
    ],
    [
      card_label(label),
      html.div(
        [
          attribute.styles([
            #("font-size", "1.8rem"),
            #("font-weight", "bold"),
            #("color", "#333"),
          ]),
        ],
        [html.text(value)],
      ),
    ],
  )
}

fn sparkline_card(
  label: String,
  values: List(Float),
  colour: String,
) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("background", "#f8f9fa"),
        #("border-radius", "8px"),
        #("padding", "1rem"),
      ]),
    ],
    [card_label(label), sparkline(values, colour, 350, 60)],
  )
}

fn card_label(label: String) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("color", "#666"),
        #("font-size", "0.85rem"),
        #("margin-bottom", "0.5rem"),
      ]),
    ],
    [html.text(label)],
  )
}

/// A polyline scaled to fit `width` x `height`; fewer than two samples
/// draw an empty chart.
fn sparkline(
  values: List(Float),
  colour: String,
  width: Int,
  height: Int,
) -> Element(Msg) {
  let w = int.to_string(width)
  let h = int.to_string(height)
  let line = case values {
    [] | [_] -> []
    [first, ..rest] -> {
      let low = list.fold(rest, first, float.min)
      let high = list.fold(rest, first, float.max)
      // A flat series would divide by zero; draw it along the bottom.
      let range = float.max(high -. low, 1.0)
      let step = int.to_float(width) /. int.to_float(list.length(values) - 1)
      let points =
        list.index_map(values, fn(v, i) {
          let x = int.to_float(i) *. step
          let y =
            int.to_float(height)
            -. { v -. low }
            /. range
            *. int.to_float(height - 4)
            -. 2.0
          one_decimal(x) <> "," <> one_decimal(y)
        })
      [
        svg.polyline([
          svg.points(string.join(points, " ")),
          svg.fill("none"),
          svg.stroke(colour),
          svg.stroke_width("2"),
        ]),
      ]
    }
  }
  svg.svg(
    [svg.viewbox("0 0 " <> w <> " " <> h), svg.width(w), svg.height(h)],
    line,
  )
}

fn format_uptime(seconds: Int) -> String {
  int.to_string(seconds / 3600)
  <> "h "
  <> int.to_string(seconds % 3600 / 60)
  <> "m "
  <> int.to_string(seconds % 60)
  <> "s"
}

fn one_decimal(value: Float) -> String {
  float.to_string(float.to_precision(value, 1))
}

// --- Start ---

pub fn main() {
  let assert Ok(Nil) =
    beacon.application(init:, update:, view:)
    |> beacon.title(fn(_model) { "Live Dashboard" })
    |> beacon.head_html(favicon)
    |> beacon.start(8080)
    as "beacon.start failed (it logs the error)"
}
