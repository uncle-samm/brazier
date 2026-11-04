/// Triple Counter: three counters, one per state layer.
///
/// 1. Shared: every session sees the same count, kept in a `beacon/store`
///    list and announced on the store's PubSub topic.
/// 2. Server: per tab, held by the tab's server process.
/// 3. Local: per tab, held in the browser; no server traffic.
///
/// The shared counter needs effects (store writes), so this is a
/// `full_application`, not a `simple` app.
import beacon
import beacon/attribute
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/event
import beacon/html
import beacon/local
import beacon/store.{type ListStore}
import gleam/int
import gleam/list

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

/// Synced to the browser.
pub type Model {
  Model(
    /// Per tab, server-held.
    my_count: Int,
    /// The same for every session; re-read from the store on change.
    shared_count: Int,
  )
}

/// Client-only.
pub type Local {
  Local(local_count: Int)
}

pub type Msg {
  SharedIncrement
  SharedDecrement
  /// The store changed (from this session or another).
  SharedChanged
  MyIncrement
  MyDecrement
  LocalIncrement
  LocalDecrement
}

const deltas_key = "deltas"

// --- Shared counter ---

/// The shared count is the fold of every +1/-1 ever appended, never going
/// below zero. Appends never overwrite each other, so concurrent clicks in
/// different sessions are all counted.
fn shared_count(deltas: ListStore(Int)) -> Int {
  store.get_all(deltas, deltas_key)
  |> list.fold(0, fn(count, delta) { int.max(0, count + delta) })
}

fn add_shared(deltas: ListStore(Int), delta: Int) -> Effect(Msg) {
  effect.from(fn(_dispatch) { store.append(deltas, deltas_key, delta) })
}

// --- Init and update (server) ---

fn init(
  deltas: ListStore(Int),
) -> Result(#(Model, Effect(Msg)), beacon.InitError) {
  Ok(#(Model(my_count: 0, shared_count: shared_count(deltas)), effect.none()))
}

fn update(
  deltas: ListStore(Int),
  model: Model,
  msg: Msg,
) -> #(Model, Effect(Msg)) {
  case msg {
    SharedIncrement -> #(model, add_shared(deltas, 1))
    SharedDecrement -> #(model, add_shared(deltas, -1))
    SharedChanged -> #(
      Model(..model, shared_count: shared_count(deltas)),
      effect.none(),
    )
    MyIncrement -> #(
      Model(..model, my_count: model.my_count + 1),
      effect.none(),
    )
    MyDecrement -> #(
      Model(..model, my_count: model.my_count - 1),
      effect.none(),
    )
    // `update_local` handles these in the browser and never forwards them.
    LocalIncrement | LocalDecrement -> #(model, effect.none())
  }
}

// --- Local (browser) ---

pub fn init_local(_model: Model) -> Local {
  Local(local_count: 0)
}

pub fn update_local(
  _model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    LocalIncrement -> local.handled(Local(local_count: local.local_count + 1))
    LocalDecrement -> local.handled(Local(local_count: local.local_count - 1))
    SharedIncrement
    | SharedDecrement
    | SharedChanged
    | MyIncrement
    | MyDecrement -> local.forward(local)
  }
}

fn sync(model: Model) -> Model {
  model
}

// --- View ---

pub fn view(model: Model, local: Local) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "600px"),
        #("margin", "2rem auto"),
      ]),
    ],
    [
      html.h1([], [html.text("Triple Counter")]),
      html.p([attribute.style("color", "#666")], [
        html.text("Open several tabs to see the difference."),
      ]),
      counter_panel(
        title: "Shared Counter",
        note: "Every tab sees the same number.",
        background: "#e8f5e9",
        colour: "#2e7d32",
        count: model.shared_count,
        decrement: SharedDecrement,
        increment: SharedIncrement,
      ),
      counter_panel(
        title: "Server Counter (per tab)",
        note: "Each tab has its own count, held by its server process.",
        background: "#e3f2fd",
        colour: "#1565c0",
        count: model.my_count,
        decrement: MyDecrement,
        increment: MyIncrement,
      ),
      counter_panel(
        title: "Local Counter (instant)",
        note: "Per tab, in the browser only. No server traffic.",
        background: "#fce4ec",
        colour: "#c62828",
        count: local.local_count,
        decrement: LocalDecrement,
        increment: LocalIncrement,
      ),
    ],
  )
}

fn counter_panel(
  title title: String,
  note note: String,
  background background: String,
  colour colour: String,
  count count: Int,
  decrement decrement: Msg,
  increment increment: Msg,
) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("background", background),
        #("padding", "1rem"),
        #("margin", "1rem 0"),
        #("border-radius", "8px"),
      ]),
    ],
    [
      html.h2([], [html.text(title)]),
      html.p([attribute.style("color", colour)], [html.text(note)]),
      html.div(
        [attribute.styles([#("font-size", "2rem"), #("text-align", "center")])],
        [
          html.button([event.on_click(decrement)], [html.text(" - ")]),
          html.strong([], [html.text(" " <> int.to_string(count) <> " ")]),
          html.button([event.on_click(increment)], [html.text(" + ")]),
        ],
      ),
    ],
  )
}

// --- Start ---

pub fn main() {
  let deltas = store.new_list("shared_counter")
  let assert Ok(Nil) =
    beacon.full_application(
      init: fn(_ctx) { init(deltas) },
      update: fn(model, msg) { update(deltas, model, msg) },
      sync:,
      local: local.layer(init: init_local, update: update_local),
      view:,
    )
    |> beacon.title(fn(_model) { "Triple Counter" })
    |> beacon.subscriptions(fn(_model) { [store.list_topic(deltas)] })
    |> beacon.on_notify(fn(_topic) { SharedChanged })
    |> beacon.head_html(favicon)
    |> beacon.start(8080)
    as "beacon.start failed (it logs the error)"
}
