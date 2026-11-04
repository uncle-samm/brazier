/// Routed Workspace: routing, a Local layer and server-authoritative Model
/// updates in one app.
///
/// - `with_router` maps `/`, `/pipeline` and `/settings` to a `Route` in the
///   Model; any other path is a 404.
/// - Panels, tabs, filters, drafts and menus are Local: they change in the
///   browser with no server traffic.
/// - Deploys, incidents, cards and the saved profile are in the Model: the
///   server validates every change.
import brazier
import brazier/attribute
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import brazier/router
import gleam/int
import gleam/list
import gleam/string
import gleam/uri.{type Uri}

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

const lanes = ["todo", "doing", "done"]

const roles = ["owner", "operator", "viewer"]

const max_title_length = 120

const max_name_length = 80

/// The server refuses new cards past this many.
const max_cards = 200

pub type Route {
  OverviewPage
  PipelinePage
  SettingsPage
}

/// Synced to the browser.
pub type Model {
  Model(
    route: Route,
    open_tickets: Int,
    deploys: Int,
    incidents: Int,
    cards: List(Card),
    next_id: Int,
    display_name: String,
    role: String,
    saved_version: Int,
  )
}

pub type Card {
  Card(id: Int, title: String, lane: String)
}

/// Client-only.
pub type Local {
  Local(
    inspector_open: Bool,
    selected_tab: String,
    draft: String,
    filter: String,
    compact: Bool,
    draft_name: String,
    draft_role: String,
    menu_open: Bool,
  )
}

pub type Msg {
  RouteChanged(Route)
  // Local: handled in the browser.
  ToggleInspector
  SelectTab(String)
  SetDraft(String)
  SetFilter(String)
  ToggleCompact
  SetDraftName(String)
  SetDraftRole(String)
  ToggleMenu
  // Model: forwarded to the server.
  ShipDeploy
  ResolveIncident
  /// The submitted form's fields, as `name`/`value` pairs.
  AddCard(List(#(String, String)))
  Advance(Int)
  SaveProfile(List(#(String, String)))
}

// --- Routing ---

fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case router.segments(uri) {
    [] -> Ok(OverviewPage)
    ["pipeline"] -> Ok(PipelinePage)
    ["settings"] -> Ok(SettingsPage)
    _ -> Error(Nil)
  }
}

pub fn href(route: Route) -> String {
  case route {
    OverviewPage -> "/"
    PipelinePage -> "/pipeline"
    SettingsPage -> "/settings"
  }
}

// --- Init and update (server) ---

fn init(
  _ctx: brazier.Context,
) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  // `with_router` dispatches RouteChanged for the requested URL before the
  // first render, so this route is only a placeholder.
  Ok(#(
    Model(
      route: OverviewPage,
      open_tickets: 7,
      deploys: 3,
      incidents: 1,
      cards: [
        Card(id: 1, title: "Add browser conformance checks", lane: "doing"),
        Card(id: 2, title: "Verify server-private state", lane: "todo"),
        Card(id: 3, title: "Document native browser workflow", lane: "done"),
      ],
      next_id: 4,
      display_name: "Ada",
      role: "owner",
      saved_version: 1,
    ),
    effect.none(),
  ))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  let model = case msg {
    RouteChanged(route) -> {
      log.debug("routed_workspace", "Route changed to " <> href(route))
      Model(..model, route:)
    }
    ShipDeploy -> Model(..model, deploys: model.deploys + 1)
    ResolveIncident ->
      case model.incidents > 0 {
        True -> Model(..model, incidents: model.incidents - 1)
        False -> {
          log.warning("routed_workspace", "No active incident to resolve")
          model
        }
      }
    AddCard(fields) ->
      case validate_card(model, fields) {
        Ok(title) -> {
          log.info(
            "routed_workspace",
            "Added card " <> int.to_string(model.next_id),
          )
          Model(
            ..model,
            cards: [
              Card(id: model.next_id, title:, lane: "todo"),
              ..model.cards
            ],
            next_id: model.next_id + 1,
          )
        }
        Error(reason) -> {
          log.warning("routed_workspace", "Rejected a card: " <> reason)
          model
        }
      }
    Advance(id) ->
      case list.any(model.cards, fn(card) { card.id == id }) {
        True ->
          Model(..model, cards: list.map(model.cards, advance_card(_, id)))
        False -> {
          log.warning(
            "routed_workspace",
            "Refusing to advance unknown card " <> int.to_string(id),
          )
          model
        }
      }
    SaveProfile(fields) ->
      case validate_profile(fields) {
        Ok(#(name, role)) -> {
          let version = model.saved_version + 1
          log.info(
            "routed_workspace",
            "Saved profile v" <> int.to_string(version),
          )
          Model(..model, display_name: name, role:, saved_version: version)
        }
        Error(reason) -> {
          log.warning("routed_workspace", "Rejected a profile: " <> reason)
          model
        }
      }
    // `update_local` handles these in the browser and never forwards them.
    ToggleInspector
    | SelectTab(_)
    | SetDraft(_)
    | SetFilter(_)
    | ToggleCompact
    | SetDraftName(_)
    | SetDraftRole(_)
    | ToggleMenu -> model
  }
  #(model, effect.none())
}

fn validate_card(
  model: Model,
  fields: List(#(String, String)),
) -> Result(String, String) {
  case list.key_find(fields, "card_title") {
    Error(Nil) -> Error("missing field `card_title`")
    Ok(title) -> {
      let title = string.trim(title)
      let length = string.length(title)
      case
        length,
        length > max_title_length,
        list.length(model.cards) >= max_cards
      {
        0, _, _ -> Error("empty title")
        _, True, _ ->
          Error(
            "title of "
            <> int.to_string(length)
            <> " characters (max "
            <> int.to_string(max_title_length)
            <> ")",
          )
        _, _, True ->
          Error("the board is full (" <> int.to_string(max_cards) <> " cards)")
        _, False, False -> Ok(title)
      }
    }
  }
}

fn validate_profile(
  fields: List(#(String, String)),
) -> Result(#(String, String), String) {
  case list.key_find(fields, "display_name"), list.key_find(fields, "role") {
    Error(Nil), _ -> Error("missing field `display_name`")
    _, Error(Nil) -> Error("missing field `role`")
    Ok(name), Ok(role) -> {
      let name = string.trim(name)
      let length = string.length(name)
      case length, length > max_name_length, list.contains(roles, role) {
        0, _, _ -> Error("empty display name")
        _, True, _ ->
          Error(
            "display name of "
            <> int.to_string(length)
            <> " characters (max "
            <> int.to_string(max_name_length)
            <> ")",
          )
        _, _, False -> Error("unknown role " <> string.inspect(role))
        _, False, True -> Ok(#(name, role))
      }
    }
  }
}

fn advance_card(card: Card, id: Int) -> Card {
  case card.id == id, card.lane {
    False, _ -> card
    True, "todo" -> Card(..card, lane: "doing")
    True, _ -> Card(..card, lane: "done")
  }
}

fn sync(model: Model) -> Model {
  model
}

// --- Local (browser) ---

pub fn init_local(model: Model) -> Local {
  Local(
    inspector_open: False,
    selected_tab: "health",
    draft: "",
    filter: "all",
    compact: False,
    draft_name: model.display_name,
    draft_role: model.role,
    menu_open: False,
  )
}

pub fn update_local(
  _model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    ToggleInspector ->
      local.handled(Local(..local, inspector_open: !local.inspector_open))
    SelectTab(tab) -> local.handled(Local(..local, selected_tab: tab))
    SetDraft(text) -> local.handled(Local(..local, draft: text))
    SetFilter(filter) -> local.handled(Local(..local, filter:))
    ToggleCompact -> local.handled(Local(..local, compact: !local.compact))
    SetDraftName(name) -> local.handled(Local(..local, draft_name: name))
    SetDraftRole(role) -> local.handled(Local(..local, draft_role: role))
    ToggleMenu -> local.handled(Local(..local, menu_open: !local.menu_open))
    AddCard(_) -> local.forward(Local(..local, draft: ""))
    RouteChanged(_)
    | ShipDeploy
    | ResolveIncident
    | Advance(_)
    | SaveProfile(_) -> local.forward(local)
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> Element(Msg) {
  let #(title, page) = case model.route {
    OverviewPage -> #("Overview", overview_view(model, local))
    PipelinePage -> #("Pipeline", pipeline_view(model, local))
    SettingsPage -> #("Settings", settings_view(model, local))
  }
  html.main(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "1040px"),
        #("margin", "32px auto"),
        #("padding", "0 16px"),
      ]),
    ],
    [
      html.nav(
        [
          attribute.styles([
            #("display", "flex"),
            #("gap", "12px"),
            #("margin-bottom", "24px"),
          ]),
        ],
        [
          html.a([attribute.href(href(OverviewPage))], [html.text("Overview")]),
          html.a([attribute.href(href(PipelinePage))], [html.text("Pipeline")]),
          html.a([attribute.href(href(SettingsPage))], [html.text("Settings")]),
        ],
      ),
      html.h1([], [html.text(title)]),
      // Keyed by route: a route change replaces the page's DOM instead of
      // morphing one page's nodes (and their focus and input state) into
      // the next page.
      element.keyed(href(model.route), page),
    ],
  )
}

fn overview_view(model: Model, local: Local) -> Element(Msg) {
  html.div([], [
    html.section([attribute.styles(grid_styles())], [
      metric("Open tickets", int.to_string(model.open_tickets)),
      metric("Deploys today", int.to_string(model.deploys)),
      metric("Active incidents", int.to_string(model.incidents)),
    ]),
    html.section(
      [
        attribute.styles([
          #("margin-top", "20px"),
          #("display", "flex"),
          #("gap", "8px"),
          #("flex-wrap", "wrap"),
        ]),
      ],
      [
        html.button([event.on_click(ShipDeploy)], [html.text("Ship deploy")]),
        html.button([event.on_click(ResolveIncident)], [
          html.text("Resolve incident"),
        ]),
        html.button([event.on_click(ToggleInspector)], [
          html.text("Toggle inspector"),
        ]),
      ],
    ),
    html.section([attribute.styles([#("margin-top", "20px")])], [
      html.div(
        [
          attribute.styles([
            #("display", "flex"),
            #("gap", "8px"),
            #("margin-bottom", "12px"),
          ]),
        ],
        [
          tab_button("health", local.selected_tab),
          tab_button("activity", local.selected_tab),
          tab_button("risks", local.selected_tab),
        ],
      ),
      html.p([attribute.data("testid", "selected-tab")], [
        html.text("Selected tab: " <> local.selected_tab),
      ]),
      case local.inspector_open {
        True ->
          html.div(
            [
              attribute.data("testid", "local-inspector"),
              attribute.styles([
                #("border", "1px solid #d0d7de"),
                #("padding", "12px"),
                #("border-radius", "6px"),
              ]),
            ],
            [
              html.strong([], [html.text("Inspector")]),
              html.p([], [
                html.text(
                  "Local UI state should change without WebSocket traffic.",
                ),
              ]),
            ],
          )
        False ->
          html.span([attribute.data("testid", "local-inspector-closed")], [])
      },
    ]),
  ])
}

fn pipeline_view(model: Model, local: Local) -> Element(Msg) {
  html.div([], [
    html.form([event.on_submit(AddCard), attribute.styles(toolbar_styles())], [
      html.input([
        attribute.type_("text"),
        attribute.value(local.draft),
        attribute.name("card_title"),
        attribute.placeholder("New card title"),
        event.on_input(SetDraft),
        attribute.data("testid", "card-draft"),
      ]),
      html.button([attribute.type_("submit")], [html.text("Add card")]),
    ]),
    html.div([attribute.styles(toolbar_styles())], [
      html.select(
        [event.on_change(SetFilter), attribute.data("testid", "lane-filter")],
        [
          option("all", local.filter, "All lanes"),
          option("todo", local.filter, "Todo"),
          option("doing", local.filter, "Doing"),
          option("done", local.filter, "Done"),
        ],
      ),
      html.button([event.on_click(ToggleCompact)], [
        html.text(case local.compact {
          True -> "Comfortable"
          False -> "Compact"
        }),
      ]),
      html.span([attribute.data("testid", "pipeline-local-state")], [
        html.text(
          "Filter: "
          <> local.filter
          <> " / compact: "
          <> bool_text(local.compact),
        ),
      ]),
    ]),
    html.section(
      [attribute.styles(grid_styles())],
      list.map(lanes, lane(_, model.cards, local)),
    ),
  ])
}

fn settings_view(model: Model, local: Local) -> Element(Msg) {
  html.div([], [
    html.form(
      [
        event.on_submit(SaveProfile),
        attribute.styles([
          #("display", "grid"),
          #("gap", "12px"),
          #("max-width", "460px"),
        ]),
      ],
      [
        html.label([], [
          html.text("Display name"),
          html.input([
            attribute.type_("text"),
            attribute.value(local.draft_name),
            attribute.name("display_name"),
            event.on_input(SetDraftName),
            attribute.data("testid", "draft-name"),
          ]),
        ]),
        html.label([], [
          html.text("Role"),
          html.select(
            [
              event.on_change(SetDraftRole),
              attribute.data("testid", "draft-role"),
              attribute.name("role"),
            ],
            [
              option("owner", local.draft_role, "Owner"),
              option("operator", local.draft_role, "Operator"),
              option("viewer", local.draft_role, "Viewer"),
            ],
          ),
        ]),
        html.div([attribute.styles([#("display", "flex"), #("gap", "8px")])], [
          html.button([attribute.type_("submit")], [html.text("Save profile")]),
          html.button([attribute.type_("button"), event.on_click(ToggleMenu)], [
            html.text("Toggle menu"),
          ]),
        ]),
      ],
    ),
    html.section(
      [
        attribute.styles([
          #("margin-top", "20px"),
          #("border", "1px solid #d0d7de"),
          #("border-radius", "6px"),
          #("padding", "12px"),
        ]),
      ],
      [
        html.h2([], [html.text("Saved profile")]),
        html.p([attribute.data("testid", "saved-profile")], [
          html.text(
            model.display_name
            <> " / "
            <> model.role
            <> " / v"
            <> int.to_string(model.saved_version),
          ),
        ]),
        html.p([attribute.data("testid", "settings-local-state")], [
          html.text("Draft: " <> local.draft_name <> " / " <> local.draft_role),
        ]),
        case local.menu_open {
          True ->
            html.div([attribute.data("testid", "settings-menu")], [
              html.text("Local actions menu is open"),
            ])
          False ->
            html.span([attribute.data("testid", "settings-menu-closed")], [])
        },
      ],
    ),
  ])
}

fn lane(name: String, cards: List(Card), local: Local) -> Element(Msg) {
  let visible =
    list.filter(cards, fn(card) {
      card.lane == name && { local.filter == "all" || local.filter == name }
    })
  html.div(
    [
      attribute.styles([
        #("border", "1px solid #d0d7de"),
        #("border-radius", "6px"),
        #("padding", "12px"),
        #("min-height", "180px"),
      ]),
    ],
    [
      html.h2([], [
        html.text(name <> " (" <> int.to_string(list.length(visible)) <> ")"),
      ]),
      ..list.map(visible, card_view(_, local.compact))
    ],
  )
}

fn card_view(card: Card, compact: Bool) -> Element(Msg) {
  let padding = case compact {
    True -> "6px"
    False -> "12px"
  }
  html.article(
    [
      attribute.styles([
        #("border", "1px solid #d8dee4"),
        #("border-radius", "6px"),
        #("padding", padding),
        #("margin-bottom", "8px"),
      ]),
    ],
    [
      html.strong([], [html.text(card.title)]),
      html.p([attribute.styles([#("margin", "4px 0"), #("color", "#57606a")])], [
        html.text("Card #" <> int.to_string(card.id) <> " in " <> card.lane),
      ]),
      html.button([event.on_click(Advance(card.id))], [html.text("Advance")]),
    ],
  )
}

fn tab_button(tab: String, selected: String) -> Element(Msg) {
  let weight = case tab == selected {
    True -> "700"
    False -> "400"
  }
  html.button(
    [
      event.on_click(SelectTab(tab)),
      attribute.styles([#("font-weight", weight)]),
    ],
    [html.text(tab)],
  )
}

fn option(value: String, selected: String, label: String) -> Element(Msg) {
  html.option([attribute.value(value), attribute.selected(value == selected)], [
    html.text(label),
  ])
}

fn metric(label: String, value: String) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("border", "1px solid #d0d7de"),
        #("border-radius", "6px"),
        #("padding", "12px"),
      ]),
    ],
    [
      html.p([attribute.styles([#("margin", "0"), #("color", "#57606a")])], [
        html.text(label),
      ]),
      html.h2([attribute.styles([#("margin", "4px 0 0")])], [html.text(value)]),
    ],
  )
}

fn grid_styles() -> List(#(String, String)) {
  [
    #("display", "grid"),
    #("gap", "12px"),
    #("grid-template-columns", "repeat(3,minmax(0,1fr))"),
  ]
}

fn toolbar_styles() -> List(#(String, String)) {
  [
    #("display", "flex"),
    #("gap", "8px"),
    #("align-items", "center"),
    #("margin-bottom", "16px"),
  ]
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

// --- Start ---

pub fn main() {
  let assert Ok(Nil) =
    brazier.full_application(
      init:,
      update:,
      sync:,
      local: local.layer(init: init_local, update: update_local),
      view:,
    )
    |> brazier.with_router(parse: parse_route, on_change: RouteChanged)
    |> brazier.title(fn(_model) { "Brazier Routed Workspace" })
    |> brazier.head_html(favicon)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
