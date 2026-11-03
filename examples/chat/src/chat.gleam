/// Multi-room chat, demonstrating:
/// - `beacon.full_application`: the session keeps its presence key and
///   typing flag on the server, and syncs only the Model;
/// - a `local.layer` for the name and message drafts, so typing sends no
///   frames except a throttled typing signal;
/// - dynamic subscriptions: a session is notified only for its current
///   room;
/// - `beacon/store` for the message history;
/// - `beacon.presence` for who is in each room and who is typing: each
///   session declares its tracking from its state, and the framework
///   tracks, updates and untracks it and delivers every change as a
///   message.
import beacon
import beacon/attribute
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/event
import beacon/html
import beacon/local
import beacon/log
import beacon/presence
import beacon/presence/sync
import beacon/store.{type ListStore}
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type ChatMessage {
  ChatMessage(sender: String, text: String)
}

/// Synced to the browser.
pub type Model {
  Model(
    /// `None` until the user joins.
    username: Option(String),
    room: String,
    messages: List(ChatMessage),
    /// Names in the current room, this user's included.
    online: List(String),
    /// Other users typing in the current room.
    typing: List(String),
  )
}

/// Server-only.
pub type Session {
  Session(
    model: Model,
    /// This session's presence key.
    key: String,
    /// Whether this session's presence meta says it is typing.
    typing: Bool,
    /// Who is in the current room, kept up to date from presence diffs.
    members: List(sync.Entry(Member)),
  )
}

/// Client-only.
pub type Local {
  Local(name_draft: String, draft: String)
}

/// What a session tracks in each room it is in.
pub type Member {
  Member(name: String, typing: Bool)
}

pub type Msg {
  NameDraftChanged(String)
  Join(String)
  DraftChanged(String)
  Send(String)
  /// A throttled signal while the user types a message.
  Typing
  /// No `Typing` for `typing_timeout_ms`.
  TypingStopped
  SwitchRoom(String)
  /// A subscribed room's messages changed.
  Notified(String)
  /// Someone joined, left or changed their meta in a tracked room.
  PresenceChanged(sync.Diff(Member))
}

const rooms = ["general", "random", "help"]

const max_name_length = 32

const max_message_length = 500

/// The most recent messages shown.
const history_limit = 100

const typing_throttle_ms = 1000

const typing_timeout_ms = 3000

const typing_key = "chat_typing"

const room_topic_prefix = "room:"

/// Names the presence tracker in the application's supervision tree.
const tracker_name = "chat"

// --- Server ---

fn init(
  _ctx: beacon.Context,
) -> Result(#(Session, Effect(Msg)), beacon.InitError) {
  Ok(#(
    Session(
      model: Model(
        username: None,
        room: "general",
        messages: [],
        online: [],
        typing: [],
      ),
      key: new_key(),
      typing: False,
      members: [],
    ),
    effect.none(),
  ))
}

/// 128 random bits: no two sessions share a presence key, on any node.
fn new_key() -> String {
  crypto.strong_random_bytes(16) |> bit_array.base16_encode
}

fn update(
  messages: ListStore(ChatMessage),
  session: Session,
  msg: Msg,
) -> #(Session, Effect(Msg)) {
  let model = session.model
  case msg {
    Join(name) -> join(messages, session, string.trim(name))
    Send(text) -> send(messages, session, string.trim(text))
    Typing ->
      case model.username, session.typing {
        None, _ -> {
          log.warning("chat", "Ignored a typing signal before joining")
          #(session, effect.none())
        }
        // Still typing: push the timeout back.
        Some(_), True -> #(session, typing_timer())
        // `track` puts the flag in this session's presence meta.
        Some(_), False -> #(Session(..session, typing: True), typing_timer())
      }
    // `Send` may already have cleared the flag.
    TypingStopped -> #(Session(..session, typing: False), effect.none())
    SwitchRoom(room) -> switch_room(messages, session, room)
    Notified(topic) ->
      case topic == room_topic(model.room) {
        True -> #(
          Session(
            ..session,
            model: Model(..model, messages: read_messages(messages, model.room)),
          ),
          effect.none(),
        )
        // A notification for the previous room can arrive just after a
        // switch, before the old subscription is dropped.
        False -> {
          log.debug("chat", "Ignored a notification for " <> topic)
          #(session, effect.none())
        }
      }
    PresenceChanged(diff) ->
      case diff.topic == presence_topic(model.room) {
        True -> #(
          with_members(session, sync.merge(session.members, diff)),
          effect.none(),
        )
        // The previous room's last diffs can arrive after a switch.
        False -> {
          log.debug("chat", "Ignored presence for " <> diff.topic)
          #(session, effect.none())
        }
      }
    // `update_local` handles these in the browser and never forwards them.
    NameDraftChanged(_) | DraftChanged(_) -> #(session, effect.none())
  }
}

fn join(
  messages: ListStore(ChatMessage),
  session: Session,
  name: String,
) -> #(Session, Effect(Msg)) {
  let model = session.model
  case model.username, check_length("name", name, max_name_length) {
    Some(_), _ -> {
      log.warning("chat", "Ignored a second Join")
      #(session, effect.none())
    }
    None, Error(reason) -> {
      log.warning("chat", "Rejected a join: " <> reason)
      #(session, effect.none())
    }
    None, Ok(Nil) -> {
      log.info("chat", name <> " joined #" <> model.room)
      // With a username, `track` tracks the session in its room.
      #(
        Session(
          ..session,
          model: Model(
            ..model,
            username: Some(name),
            messages: read_messages(messages, model.room),
          ),
        ),
        effect.none(),
      )
    }
  }
}

fn send(
  messages: ListStore(ChatMessage),
  session: Session,
  text: String,
) -> #(Session, Effect(Msg)) {
  let model = session.model
  case model.username, check_length("message", text, max_message_length) {
    None, _ -> {
      log.warning("chat", "Ignored a message before joining")
      #(session, effect.none())
    }
    Some(_), Error(reason) -> {
      log.warning("chat", "Rejected a message: " <> reason)
      #(session, effect.none())
    }
    Some(name), Ok(Nil) -> {
      let message = ChatMessage(sender: name, text:)
      log.info("chat", name <> " wrote in #" <> model.room)
      // Shown at once; the room notification re-reads the store, other
      // sessions' messages included. Sending ends the typing signal.
      #(
        Session(
          ..session,
          typing: False,
          model: Model(
            ..model,
            messages: list.append(model.messages, [message]),
          ),
        ),
        effect.from(fn(_dispatch) {
          store.append_notify(messages, model.room, message, room_topic_prefix)
        }),
      )
    }
  }
}

fn switch_room(
  messages: ListStore(ChatMessage),
  session: Session,
  room: String,
) -> #(Session, Effect(Msg)) {
  let model = session.model
  case list.contains(rooms, room), room == model.room, model.username {
    False, _, _ -> {
      log.warning("chat", "Rejected a switch to unknown room " <> room)
      #(session, effect.none())
    }
    True, True, _ -> #(session, effect.none())
    True, False, None -> {
      log.warning("chat", "Ignored a room switch before joining")
      #(session, effect.none())
    }
    True, False, Some(name) -> {
      log.info("chat", name <> " moved to #" <> room)
      // `track` moves the tracking to the new room; its first diff lists
      // everyone already there.
      #(
        with_members(
          Session(
            ..session,
            typing: False,
            model: Model(
              ..model,
              room:,
              messages: read_messages(messages, room),
            ),
          ),
          [],
        ),
        effect.none(),
      )
    }
  }
}

fn check_length(what: String, text: String, max: Int) -> Result(Nil, String) {
  case string.length(text) {
    0 -> Error("empty " <> what)
    n if n > max ->
      Error(
        what
        <> " of "
        <> int.to_string(n)
        <> " characters (max "
        <> int.to_string(max)
        <> ")",
      )
    _ -> Ok(Nil)
  }
}

fn typing_timer() -> Effect(Msg) {
  effect.keyed(
    typing_key,
    effect.after(typing_timeout_ms, fn() { TypingStopped }),
  )
}

fn read_messages(
  messages: ListStore(ChatMessage),
  room: String,
) -> List(ChatMessage) {
  let all = store.get_all(messages, room)
  list.drop(all, int.max(0, list.length(all) - history_limit))
}

fn room_topic(room: String) -> String {
  room_topic_prefix <> room
}

fn presence_topic(room: String) -> String {
  "chat:" <> room
}

// --- Presence ---

/// What this session is present as: nothing until it joins, then its name
/// and typing flag in its current room. `beacon.presence` runs this after
/// every update and tracks, updates or untracks to match.
fn track(session: Session) -> List(presence.Tracking(Member)) {
  case session.model.username {
    None -> []
    Some(name) -> [
      presence.Tracking(
        topic: presence_topic(session.model.room),
        key: session.key,
        meta: Member(name:, typing: session.typing),
      ),
    ]
  }
}

/// The room's members, and the names derived from them for the view.
fn with_members(
  session: Session,
  members: List(sync.Entry(Member)),
) -> Session {
  let present =
    list.flat_map(members, fn(entry) {
      list.map(entry.metas, fn(meta) {
        RoomMember(key: entry.key, member: meta.value)
      })
    })
  let typing =
    list.filter(present, fn(m) { m.key != session.key && m.member.typing })
  Session(
    ..session,
    members:,
    model: Model(..session.model, online: names(present), typing: names(typing)),
  )
}

/// A tracked member and the presence key it is tracked under.
type RoomMember {
  RoomMember(key: String, member: Member)
}

fn names(members: List(RoomMember)) -> List(String) {
  members
  |> list.map(fn(m) { m.member.name })
  |> list.unique
  |> list.sort(string.compare)
}

fn encode_member(member: Member) -> json.Json {
  json.object([
    #("name", json.string(member.name)),
    #("typing", json.bool(member.typing)),
  ])
}

fn member_decoder() -> decode.Decoder(Member) {
  use name <- decode.field("name", decode.string)
  use typing <- decode.field("typing", decode.bool)
  decode.success(Member(name:, typing:))
}

fn sync(session: Session) -> Model {
  session.model
}

// --- Local (browser) ---

pub fn init_local(_model: Model) -> Local {
  Local(name_draft: "", draft: "")
}

pub fn update_local(
  _model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    NameDraftChanged(text) -> local.handled(Local(..local, name_draft: text))
    DraftChanged(text) -> local.handled(Local(..local, draft: text))
    Join(name) ->
      case string.trim(name) {
        "" -> local.handled(local)
        _ -> local.forward(local)
      }
    Send(text) ->
      case string.trim(text) {
        "" -> local.handled(local)
        _ -> local.forward(Local(..local, draft: ""))
      }
    Typing | TypingStopped | SwitchRoom(_) | Notified(_) | PresenceChanged(_) ->
      local.forward(local)
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> Element(Msg) {
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
      case model.username {
        None -> view_login(local)
        Some(name) -> view_chat(model, local, name)
      },
    ],
  )
}

fn view_login(local: Local) -> Element(Msg) {
  html.div([attribute.class("chat-login")], [
    html.h1([], [html.text("Beacon Chat")]),
    html.p([], [html.text("Enter your name to join:")]),
    html.form(
      [
        attribute.class("login-form"),
        event.on_submit(fn(_fields) { Join(local.name_draft) }),
        attribute.styles([#("display", "flex"), #("gap", "8px")]),
      ],
      [
        html.input([
          attribute.type_("text"),
          attribute.placeholder("Your name..."),
          attribute.aria("label", "Your name"),
          attribute.attribute("maxlength", int.to_string(max_name_length)),
          attribute.value(local.name_draft),
          event.on_input(NameDraftChanged),
        ]),
        html.button([attribute.type_("submit")], [html.text("Join Chat")]),
      ],
    ),
  ])
}

fn view_chat(model: Model, local: Local, name: String) -> Element(Msg) {
  html.div(
    [
      attribute.class("chat-app"),
      attribute.styles([#("display", "flex"), #("gap", "2rem")]),
    ],
    [
      view_sidebar(model, name),
      html.div([attribute.class("chat-main"), attribute.style("flex", "1")], [
        html.h2([], [html.text("#" <> model.room)]),
        view_messages(model.messages),
        view_typing(model.typing),
        html.form(
          [
            attribute.class("chat-input"),
            event.on_submit(fn(_fields) { Send(local.draft) }),
            attribute.styles([#("display", "flex"), #("gap", "8px")]),
          ],
          [
            html.input([
              attribute.type_("text"),
              attribute.placeholder("Type a message..."),
              attribute.aria("label", "Message"),
              attribute.attribute(
                "maxlength",
                int.to_string(max_message_length),
              ),
              attribute.style("flex", "1"),
              attribute.value(local.draft),
              event.on_input(DraftChanged),
              event.on_keydown(fn(_key) { Typing })
                |> event.throttle(typing_throttle_ms),
            ]),
            html.button([attribute.type_("submit")], [html.text("Send")]),
          ],
        ),
      ]),
    ],
  )
}

fn view_sidebar(model: Model, name: String) -> Element(Msg) {
  html.div([attribute.class("chat-sidebar")], [
    html.h2([], [html.text("Rooms")]),
    html.ul(
      [attribute.style("list-style", "none"), attribute.style("padding", "0")],
      list.map(rooms, fn(room) {
        let active = room == model.room
        html.li(
          [
            attribute.class(case active {
              True -> "room active"
              False -> "room"
            }),
          ],
          [
            html.button(
              [
                event.on_click(SwitchRoom(room)),
                attribute.style("font-weight", case active {
                  True -> "bold"
                  False -> "normal"
                }),
              ],
              [html.text("#" <> room)],
            ),
          ],
        )
      }),
    ),
    html.p([attribute.class("username-display")], [html.text("You: " <> name)]),
    html.p([attribute.styles([#("font-size", "0.85rem"), #("color", "#666")])], [
      html.text("Online: " <> string.join(model.online, ", ")),
    ]),
  ])
}

fn view_messages(messages: List(ChatMessage)) -> Element(Msg) {
  html.div([attribute.class("chat-messages")], case messages {
    [] -> [
      html.p([attribute.class("empty")], [
        html.text("No messages yet. Say something!"),
      ]),
    ]
    _ ->
      list.map(messages, fn(message) {
        html.div([attribute.class("chat-message")], [
          html.strong([], [html.text(message.sender <> ": ")]),
          html.text(message.text),
        ])
      })
  })
}

fn view_typing(typing: List(String)) -> Element(Msg) {
  let line = case typing {
    [] -> ""
    [one] -> one <> " is typing..."
    _ -> string.join(typing, ", ") <> " are typing..."
  }
  html.p(
    [
      attribute.styles([
        #("color", "#999"),
        #("font-size", "0.85rem"),
        #("min-height", "1.2em"),
        #("margin", "4px 0"),
      ]),
    ],
    [html.text(line)],
  )
}

pub fn main() {
  let messages = store.new_list("chat_messages")
  beacon.full_application(
    init:,
    update: fn(session, msg) { update(messages, session, msg) },
    sync:,
    local: local.layer(init: init_local, update: update_local),
    view:,
  )
  |> beacon.title(fn(_model) { "Beacon Chat" })
  |> beacon.subscriptions(fn(session: Session) {
    [room_topic(session.model.room)]
  })
  |> beacon.on_notify(Notified)
  |> beacon.presence(
    tracker: presence.new(tracker_name, encode_member, member_decoder()),
    track:,
    on_presence: PresenceChanged,
  )
  |> beacon.start(8080)
}
