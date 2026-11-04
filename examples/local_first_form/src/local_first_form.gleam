/// Local First Form: the Model + Local split for a form.
///
/// - The draft, the filter and the options menu are Local: changing them
///   renders in the browser with no server traffic.
/// - Submitting forwards the form's fields to the server, which validates
///   them and saves them in the Model.
import brazier
import brazier/attribute
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import gleam/int
import gleam/list
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

/// Synced to the browser.
pub type Model {
  Model(saved_query: String, saved_filter: String, submissions: Int)
}

/// Client-only.
pub type Local {
  Local(draft: String, filter: String, menu_open: Bool)
}

pub type Msg {
  UpdateDraft(String)
  SelectFilter(String)
  ToggleMenu
  /// The submitted form's fields, as `name`/`value` pairs.
  SubmitSearch(List(#(String, String)))
}

const filters = ["all", "open", "closed"]

const max_query_length = 200

// --- Init and update (server) ---

fn init(
  _ctx: brazier.Context,
) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(
    Model(saved_query: "", saved_filter: "all", submissions: 0),
    effect.none(),
  ))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SubmitSearch(fields) ->
      case validate(fields) {
        Ok(#(query, filter)) -> {
          log.info(
            "local_first_form",
            "Saved search " <> string.inspect(query) <> " in " <> filter,
          )
          #(
            Model(
              saved_query: query,
              saved_filter: filter,
              submissions: model.submissions + 1,
            ),
            effect.none(),
          )
        }
        Error(reason) -> {
          log.warning("local_first_form", "Rejected a submit: " <> reason)
          #(model, effect.none())
        }
      }
    // `update_local` handles these in the browser and never forwards them.
    UpdateDraft(_) | SelectFilter(_) | ToggleMenu -> #(model, effect.none())
  }
}

fn validate(
  fields: List(#(String, String)),
) -> Result(#(String, String), String) {
  case list.key_find(fields, "draft_query"), list.key_find(fields, "filter") {
    Error(Nil), _ -> Error("missing field `draft_query`")
    _, Error(Nil) -> Error("missing field `filter`")
    Ok(query), Ok(filter) ->
      case
        string.length(query) > max_query_length,
        list.contains(filters, filter)
      {
        True, _ ->
          Error(
            "query of "
            <> int.to_string(string.length(query))
            <> " characters (max "
            <> int.to_string(max_query_length)
            <> ")",
          )
        _, False -> Error("unknown filter " <> string.inspect(filter))
        False, True -> Ok(#(query, filter))
      }
  }
}

fn sync(model: Model) -> Model {
  model
}

// --- Local (browser) ---

pub fn init_local(model: Model) -> Local {
  Local(draft: model.saved_query, filter: model.saved_filter, menu_open: False)
}

pub fn update_local(
  _model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    UpdateDraft(value) -> local.handled(Local(..local, draft: value))
    SelectFilter(value) -> local.handled(Local(..local, filter: value))
    ToggleMenu -> local.handled(Local(..local, menu_open: !local.menu_open))
    SubmitSearch(_) -> local.forward(Local(..local, menu_open: False))
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> Element(Msg) {
  html.main(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "760px"),
        #("margin", "32px auto"),
        #("padding", "0 16px"),
      ]),
    ],
    [
      html.h1([], [html.text("Local First Form")]),
      html.p([], [
        html.text(
          "Draft controls are local. Submit is the server-authoritative model update.",
        ),
      ]),
      html.form(
        [
          event.on_submit(SubmitSearch),
          attribute.styles([
            #("display", "grid"),
            #("gap", "12px"),
            #("margin", "20px 0"),
          ]),
        ],
        [
          html.label([], [
            html.text("Draft query"),
            html.input([
              attribute.data("testid", "draft-input"),
              attribute.type_("text"),
              attribute.value(local.draft),
              attribute.name("draft_query"),
              attribute.placeholder("Type without server traffic"),
              event.on_input(UpdateDraft),
            ]),
          ]),
          html.label([], [
            html.text("Filter"),
            html.select(
              [
                attribute.data("testid", "filter-select"),
                attribute.value(local.filter),
                attribute.name("filter"),
                event.on_input(SelectFilter),
              ],
              [
                option("all", "All", local.filter),
                option("open", "Open", local.filter),
                option("closed", "Closed", local.filter),
              ],
            ),
          ]),
          html.button([attribute.type_("button"), event.on_click(ToggleMenu)], [
            html.text("Toggle options"),
          ]),
          case local.menu_open {
            True ->
              html.div(
                [
                  attribute.data("testid", "local-menu"),
                  attribute.styles([
                    #("border", "1px solid #d0d7de"),
                    #("padding", "10px"),
                  ]),
                ],
                [html.text("Preview: " <> preview(local.draft, local.filter))],
              )
            False -> element.none()
          },
          html.button([attribute.type_("submit")], [html.text("Save search")]),
        ],
      ),
      html.section([], [
        html.h2([], [html.text("Current local draft")]),
        html.p([attribute.data("testid", "local-preview")], [
          html.text(preview(local.draft, local.filter)),
        ]),
      ]),
      html.section([], [
        html.h2([], [html.text("Saved model")]),
        html.p([attribute.data("testid", "saved-query")], [
          html.text(model.saved_query),
        ]),
        html.p([attribute.data("testid", "saved-filter")], [
          html.text(model.saved_filter),
        ]),
        html.p([attribute.data("testid", "submission-count")], [
          html.text("Submissions: " <> int.to_string(model.submissions)),
        ]),
      ]),
    ],
  )
}

fn option(value: String, label: String, selected: String) -> Element(Msg) {
  html.option([attribute.value(value), attribute.selected(value == selected)], [
    html.text(label),
  ])
}

fn preview(draft: String, filter: String) -> String {
  "\"" <> draft <> "\" in " <> filter
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
    |> brazier.title(fn(_model) { "Local First Form" })
    |> brazier.head_html(favicon)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
