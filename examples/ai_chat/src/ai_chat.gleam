/// AI Chat: a server-side stream dripped to the browser.
///
/// - `effect.background` runs the stream in a process owned by the session,
///   so it stops when the session ends.
/// - The stream dispatches `CharDelta`, `StreamDone` and `StreamError`.
///   No view handler produces them, so the browser cannot send them.
/// - The session's usage counters are server-only: `sync` sends only the
///   Model.
/// - The response is deterministic, so CI needs no API key or service.
import brazier
import brazier/attribute
import brazier/config
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

const max_prompt_length = 2000

/// The server refuses prompts once the conversation has this many messages.
const max_messages = 100

/// How long the dripper waits for the next chunk before failing the stream.
const chunk_timeout_ms = 5000

// --- Types ---

pub type ChatMessage {
  ChatMessage(role: Role, content: String)
}

pub type Role {
  User
  Assistant
}

/// Synced to the browser.
pub type Model {
  Model(
    messages: List(ChatMessage),
    input_text: String,
    is_streaming: Bool,
    streaming_text: String,
    notice: String,
  )
}

/// What the server holds per session. Only `model` is synced.
pub type Session {
  Session(model: Model, prompts: Int, characters_streamed: Int)
}

pub type Msg {
  UpdateInput(String)
  SendPrompt
  /// A few characters from the drip-feed. Server only.
  CharDelta(String)
  /// Server only.
  StreamDone
  /// Server only.
  StreamError(String)
}

/// What the fetcher sends to the dripper.
type Chunk {
  Text(String)
  Finished
  Failed(String)
}

// --- Init ---

fn init(
  _ctx: brazier.Context,
) -> Result(#(Session, Effect(Msg)), brazier.InitError) {
  Ok(#(
    Session(
      model: Model(
        messages: [
          ChatMessage(
            role: Assistant,
            content: "Hello! This example streams a deterministic server-side response so CI can test effect dispatch without external services.",
          ),
        ],
        input_text: "",
        is_streaming: False,
        streaming_text: "",
        notice: "",
      ),
      prompts: 0,
      characters_streamed: 0,
    ),
    effect.none(),
  ))
}

// --- Update ---

fn update(session: Session, msg: Msg) -> #(Session, Effect(Msg)) {
  let model = session.model
  case msg {
    UpdateInput(text) ->
      case string.length(text) > max_prompt_length {
        True -> {
          log.warning(
            "ai_chat",
            "Refusing input of "
              <> int.to_string(string.length(text))
              <> " characters (limit "
              <> int.to_string(max_prompt_length)
              <> ")",
          )
          #(
            with_model(
              session,
              Model(
                ..model,
                notice: "Messages are limited to "
                  <> int.to_string(max_prompt_length)
                  <> " characters",
              ),
            ),
            effect.none(),
          )
        }
        False -> #(
          with_model(session, Model(..model, input_text: text, notice: "")),
          effect.none(),
        )
      }

    SendPrompt -> send_prompt(session)

    CharDelta(chunk) -> {
      assert_streaming(model, "CharDelta")
      #(
        Session(
          ..session,
          model: Model(..model, streaming_text: model.streaming_text <> chunk),
          characters_streamed: session.characters_streamed
            + string.length(chunk),
        ),
        effect.none(),
      )
    }

    StreamDone -> {
      assert_streaming(model, "StreamDone")
      log.info(
        "ai_chat",
        "Stream finished; session usage: "
          <> int.to_string(session.prompts)
          <> " prompts, "
          <> int.to_string(session.characters_streamed)
          <> " characters",
      )
      #(
        with_model(
          session,
          finish_stream(model, ChatMessage(Assistant, model.streaming_text)),
        ),
        effect.none(),
      )
    }

    StreamError(reason) -> {
      assert_streaming(model, "StreamError")
      log.error("ai_chat", "Stream failed: " <> reason)
      #(
        with_model(
          session,
          finish_stream(model, ChatMessage(Assistant, "Error: " <> reason)),
        ),
        effect.none(),
      )
    }
  }
}

fn send_prompt(session: Session) -> #(Session, Effect(Msg)) {
  let model = session.model
  let text = string.trim(model.input_text)
  case
    string.is_empty(text),
    model.is_streaming,
    list.length(model.messages) >= max_messages
  {
    True, _, _ -> {
      log.debug("ai_chat", "Ignoring an empty prompt")
      #(session, effect.none())
    }
    _, True, _ -> {
      log.warning("ai_chat", "Refusing a prompt while a stream is running")
      #(session, effect.none())
    }
    _, _, True -> {
      log.warning(
        "ai_chat",
        "Refusing a prompt: the conversation has reached "
          <> int.to_string(max_messages)
          <> " messages",
      )
      #(
        with_model(
          session,
          Model(
            ..model,
            notice: "This conversation is full. Reload to start a new one.",
          ),
        ),
        effect.none(),
      )
    }
    False, False, False -> {
      let messages = list.append(model.messages, [ChatMessage(User, text)])
      log.info(
        "ai_chat",
        "Starting stream for prompt " <> int.to_string(session.prompts + 1),
      )
      #(
        Session(
          ..session,
          model: Model(
            messages:,
            input_text: "",
            is_streaming: True,
            streaming_text: "",
            notice: "",
          ),
          prompts: session.prompts + 1,
        ),
        start_streaming(text),
      )
    }
  }
}

fn with_model(session: Session, model: Model) -> Session {
  Session(..session, model:)
}

fn finish_stream(model: Model, reply: ChatMessage) -> Model {
  Model(
    ..model,
    messages: list.append(model.messages, [reply]),
    is_streaming: False,
    streaming_text: "",
  )
}

/// Only the stream started by `send_prompt` dispatches stream messages, and
/// `send_prompt` refuses a second prompt while one runs, so a stream message
/// always arrives while `is_streaming` is True.
fn assert_streaming(model: Model, message: String) -> Nil {
  let assert True = model.is_streaming
    as { message <> " arrived while no stream was running" }
  Nil
}

fn sync(session: Session) -> Model {
  session.model
}

// --- Streaming ---

fn start_streaming(prompt: String) -> Effect(Msg) {
  effect.background(fn(dispatch) {
    // The subject belongs to this process, so the fetcher sends to it and
    // this process drips the characters to the runtime.
    let chunks = process.new_subject()
    process.spawn(fn() { fetch_stream(prompt, chunks) })
    drip(chunks, dispatch, "")
  })
}

/// Builds the deterministic response and sends it in one chunk.
fn fetch_stream(prompt: String, chunks: process.Subject(Chunk)) -> Nil {
  log.info("ai_chat", "Fetching the deterministic response")
  process.send(
    chunks,
    Text(
      "Server stream received: "
      <> prompt
      <> ". Brazier keeps this work on the server and sends state updates to the client.",
    ),
  )
  process.sleep(20)
  process.send(chunks, Finished)
}

/// Dispatches the buffer three graphemes at a time, then waits for the next
/// chunk.
fn drip(
  chunks: process.Subject(Chunk),
  dispatch: fn(Msg) -> Nil,
  buffer: String,
) -> Nil {
  case string.is_empty(buffer) {
    False -> {
      let #(batch, rest) = take_graphemes(buffer, 3, "")
      dispatch(CharDelta(batch))
      process.sleep(30)
      drip(chunks, dispatch, rest)
    }
    True ->
      case process.receive(chunks, chunk_timeout_ms) {
        Ok(Text(text)) -> drip(chunks, dispatch, text)
        Ok(Finished) -> dispatch(StreamDone)
        Ok(Failed(reason)) -> dispatch(StreamError(reason))
        Error(Nil) ->
          dispatch(StreamError(
            "no chunk within " <> int.to_string(chunk_timeout_ms) <> " ms",
          ))
      }
  }
}

/// Up to `n` graphemes from `s`, and the rest.
fn take_graphemes(s: String, n: Int, acc: String) -> #(String, String) {
  case n <= 0, string.pop_grapheme(s) {
    True, _ -> #(acc, s)
    False, Ok(#(grapheme, rest)) -> take_graphemes(rest, n - 1, acc <> grapheme)
    // The string is used up before `n` graphemes.
    False, Error(Nil) -> #(acc, "")
  }
}

// --- View ---

pub fn view(model: Model, _local: Nil) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "600px"),
        #("margin", "2rem auto"),
        #("padding", "0 1rem"),
      ]),
    ],
    [
      html.h1([attribute.styles([#("margin-bottom", "1rem")])], [
        html.text("Brazier AI Chat"),
      ]),
      html.div(
        [
          attribute.styles([
            #("border", "1px solid #e0e0e0"),
            #("border-radius", "8px"),
            #("padding", "1rem"),
            #("min-height", "300px"),
            #("max-height", "500px"),
            #("overflow-y", "auto"),
            #("margin-bottom", "1rem"),
            #("background", "#fafafa"),
          ]),
        ],
        list.append(
          list.map(model.messages, view_message),
          case model.is_streaming {
            True -> [view_streaming(model.streaming_text)]
            False -> []
          },
        ),
      ),
      html.div([attribute.styles([#("display", "flex"), #("gap", "8px")])], [
        html.input([
          attribute.type_("text"),
          attribute.placeholder("Ask me anything..."),
          attribute.value(model.input_text),
          event.on_input(UpdateInput),
          attribute.styles([
            #("flex", "1"),
            #("padding", "10px"),
            #("border", "1px solid #ddd"),
            #("border-radius", "8px"),
            #("font-size", "14px"),
          ]),
        ]),
        html.button(
          [
            event.on_click(SendPrompt),
            attribute.disabled(model.is_streaming),
            attribute.styles([
              #("padding", "10px 20px"),
              #("background", case model.is_streaming {
                True -> "#ccc"
                False -> "#1976d2"
              }),
              #("color", "white"),
              #("border", "none"),
              #("border-radius", "8px"),
              #("cursor", "pointer"),
              #("font-size", "14px"),
              #("font-weight", "500"),
            ]),
          ],
          [
            html.text(case model.is_streaming {
              True -> "..."
              False -> "Send"
            }),
          ],
        ),
      ]),
      case model.notice {
        "" -> element.none()
        notice ->
          html.p(
            [
              attribute.data("testid", "chat-notice"),
              attribute.styles([#("color", "#b3261e")]),
            ],
            [html.text(notice)],
          )
      },
    ],
  )
}

fn view_message(message: ChatMessage) -> Element(Msg) {
  let #(background, align, label) = case message.role {
    User -> #("#e3f2fd", "flex-end", "You")
    Assistant -> #("#f5f5f5", "flex-start", "AI")
  }
  bubble(background, align, label, message.content)
}

fn view_streaming(text: String) -> Element(Msg) {
  bubble("#f5f5f5", "flex-start", "AI", case string.is_empty(text) {
    True -> "Thinking..."
    False -> text <> "▊"
  })
}

fn bubble(
  background: String,
  align: String,
  label: String,
  content: String,
) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("display", "flex"),
        #("flex-direction", "column"),
        #("align-items", align),
        #("margin-bottom", "0.75rem"),
      ]),
    ],
    [
      html.div(
        [
          attribute.styles([
            #("font-size", "0.75rem"),
            #("color", "#888"),
            #("margin-bottom", "2px"),
          ]),
        ],
        [html.text(label)],
      ),
      html.div(
        [
          attribute.styles([
            #("background", background),
            #("padding", "8px 14px"),
            #("border-radius", "12px"),
            #("max-width", "80%"),
            #("white-space", "pre-wrap"),
            #("line-height", "1.4"),
          ]),
        ],
        [html.text(content)],
      ),
    ],
  )
}

// --- Start ---

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let assert Ok(Nil) =
    brazier.full_application(init:, update:, sync:, local: local.none(), view:)
    |> brazier.title(fn(_model) { "Brazier AI Chat" })
    |> brazier.head_html(favicon)
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
