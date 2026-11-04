/// Private Session: a public Model next to private session state.
///
/// The session holds a signing key, an audit trail and a count of denied
/// transfers. `sync` hands only the Model to the browser, and the build
/// compiles only what `view` reaches, so none of the private state is in
/// the HTML, the model sync or the client bundle.
import brazier
import brazier/attribute
import brazier/config
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import gleam/int
import gleam/list

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

const signing_key = "brazier_private_session_signing_key_must_not_ship"

const transfer_amount = 25

/// The session keeps the newest audit entries up to this many.
const max_audit_entries = 100

pub type Model {
  Model(
    user: String,
    public_balance: Int,
    approved_actions: Int,
    last_public_event: String,
  )
}

/// What the server holds per session. Only `model` is synced.
pub type Session {
  Session(
    model: Model,
    signing_key: String,
    /// Newest first, at most `max_audit_entries`.
    audit_entries: List(String),
    /// Every audited event, including those dropped from `audit_entries`.
    audited_events: Int,
    denied_attempts: Int,
  )
}

pub type Msg {
  ApproveTransfer
  DenyTransfer
  RefreshPublicSummary
}

fn init(
  _ctx: brazier.Context,
) -> Result(#(Session, Effect(Msg)), brazier.InitError) {
  Ok(#(
    Session(
      model: Model(
        user: "Ada",
        public_balance: 1200,
        approved_actions: 0,
        last_public_event: "Session opened",
      ),
      signing_key:,
      audit_entries: ["session-created"],
      audited_events: 1,
      denied_attempts: 0,
    ),
    effect.none(),
  ))
}

fn update(session: Session, msg: Msg) -> #(Session, Effect(Msg)) {
  let model = session.model
  let session = case msg {
    ApproveTransfer ->
      case model.public_balance >= transfer_amount {
        True -> {
          let approved = model.approved_actions + 1
          log.info(
            "private_session",
            "Approved transfer " <> int.to_string(approved),
          )
          Session(
            ..audit(session, "approved-transfer-" <> int.to_string(approved)),
            model: Model(
              ..model,
              public_balance: model.public_balance - transfer_amount,
              approved_actions: approved,
              last_public_event: "Transfer approved",
            ),
          )
        }
        False -> {
          log.warning(
            "private_session",
            "Refused a transfer: balance "
              <> int.to_string(model.public_balance)
              <> " is below "
              <> int.to_string(transfer_amount),
          )
          Session(
            ..audit(session, "refused-transfer-insufficient-balance"),
            model: Model(
              ..model,
              last_public_event: "Transfer refused: insufficient balance",
            ),
          )
        }
      }

    DenyTransfer -> {
      let denied = session.denied_attempts + 1
      log.info("private_session", "Denied transfer " <> int.to_string(denied))
      Session(
        ..audit(session, "denied-transfer-" <> int.to_string(denied)),
        denied_attempts: denied,
        model: Model(..model, last_public_event: "Transfer denied"),
      )
    }

    RefreshPublicSummary ->
      Session(
        ..session,
        model: Model(
          ..model,
          last_public_event: "Public summary refreshed after "
            <> int.to_string(session.audited_events)
            <> " audited server events",
        ),
      )
  }
  #(session, effect.none())
}

fn audit(session: Session, entry: String) -> Session {
  Session(
    ..session,
    audit_entries: list.take(
      [entry, ..session.audit_entries],
      max_audit_entries,
    ),
    audited_events: session.audited_events + 1,
  )
}

fn sync(session: Session) -> Model {
  session.model
}

pub fn view(model: Model, _local: Nil) -> Element(Msg) {
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
      html.h1([], [html.text("Private Session")]),
      html.section(
        [
          attribute.styles([
            #("border", "1px solid #d0d7de"),
            #("border-radius", "6px"),
            #("padding", "16px"),
            #("margin-bottom", "16px"),
          ]),
        ],
        [
          html.h2([], [html.text("Public account")]),
          html.p([attribute.data("testid", "session-user")], [
            html.text("User: " <> model.user),
          ]),
          html.p([attribute.data("testid", "session-balance")], [
            html.text(
              "Visible balance: " <> int.to_string(model.public_balance),
            ),
          ]),
          html.p([attribute.data("testid", "session-approved-actions")], [
            html.text(
              "Approved actions: " <> int.to_string(model.approved_actions),
            ),
          ]),
          html.p([attribute.data("testid", "session-last-event")], [
            html.text(model.last_public_event),
          ]),
        ],
      ),
      html.section(
        [
          attribute.styles([
            #("display", "flex"),
            #("gap", "8px"),
            #("flex-wrap", "wrap"),
          ]),
        ],
        [
          html.button([event.on_click(ApproveTransfer)], [
            html.text("Approve transfer"),
          ]),
          html.button([event.on_click(DenyTransfer)], [
            html.text("Deny transfer"),
          ]),
          html.button([event.on_click(RefreshPublicSummary)], [
            html.text("Refresh public summary"),
          ]),
        ],
      ),
      html.p(
        [
          attribute.data("testid", "privacy-assertion"),
          attribute.style("color", "#57606a"),
        ],
        [
          html.text(
            "The signing key and audit entries are server-only and are not available to view.",
          ),
        ],
      ),
    ],
  )
}

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let assert Ok(Nil) =
    brazier.full_application(init:, update:, sync:, local: local.none(), view:)
    |> brazier.title(fn(_model) { "Private Session" })
    |> brazier.head_html(favicon)
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
