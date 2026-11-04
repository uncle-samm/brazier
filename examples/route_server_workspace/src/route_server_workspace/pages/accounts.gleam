/// The accounts page: a component with a public Model and private server
/// state. Only `view` and the Model reach the browser; the signing key is
/// reached from `init_server` alone, so it is not in the client bundle.
import brazier/attribute
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/log
import gleam/int

const signing_key = "route_accounts_private_key_must_not_ship"

const transfer_amount = 25

pub type Model {
  Model(balance: Int, approved: Int, denied: Int, last_event: String)
}

/// Server-only: never synced.
pub type Server {
  Server(signing_key: String, approval_signatures: Int, denial_signatures: Int)
}

pub type Msg {
  ApproveTransfer
  DenyTransfer
}

pub fn init() -> Model {
  Model(
    balance: 1200,
    approved: 0,
    denied: 0,
    last_event: "Awaiting account review",
  )
}

pub fn init_server() -> Server {
  Server(signing_key:, approval_signatures: 0, denial_signatures: 0)
}

pub fn update(model: Model, server: Server, msg: Msg) -> #(Model, Server) {
  case msg {
    ApproveTransfer ->
      case model.balance >= transfer_amount {
        True -> {
          let signatures = server.approval_signatures + 1
          log.info("accounts", "Signed approval " <> int.to_string(signatures))
          #(
            Model(
              ..model,
              balance: model.balance - transfer_amount,
              approved: model.approved + 1,
              last_event: "Transfer approved",
            ),
            Server(..server, approval_signatures: signatures),
          )
        }
        False -> {
          log.warning(
            "accounts",
            "Refused a transfer: balance "
              <> int.to_string(model.balance)
              <> " is below "
              <> int.to_string(transfer_amount),
          )
          #(
            Model(..model, last_event: "Transfer refused: insufficient balance"),
            server,
          )
        }
      }
    DenyTransfer -> {
      let signatures = server.denial_signatures + 1
      log.info("accounts", "Signed denial " <> int.to_string(signatures))
      #(
        Model(..model, denied: model.denied + 1, last_event: "Transfer denied"),
        Server(..server, denial_signatures: signatures),
      )
    }
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.section([], [
    html.h1([], [html.text("Accounts")]),
    html.p([], [
      html.text("This route owns public model state and private server state."),
    ]),
    html.p([attribute.data("testid", "account-balance")], [
      html.text("Balance: " <> int.to_string(model.balance)),
    ]),
    html.p([attribute.data("testid", "account-approved")], [
      html.text("Approved: " <> int.to_string(model.approved)),
    ]),
    html.p([attribute.data("testid", "account-denied")], [
      html.text("Denied: " <> int.to_string(model.denied)),
    ]),
    html.p([attribute.data("testid", "account-last-event")], [
      html.text(model.last_event),
    ]),
    html.div([attribute.styles([#("display", "flex"), #("gap", "8px")])], [
      html.button([event.on_click(ApproveTransfer)], [
        html.text("Approve transfer"),
      ]),
      html.button([event.on_click(DenyTransfer)], [html.text("Deny transfer")]),
    ]),
  ])
}
