/// Timeline: an agent's steps as a `brazier/stream`.
///
/// The server sends each step once and does not keep it in the model: the
/// model holds only counters, and `update` returns stream ops that append,
/// prepend, update in place, move, delete and reset steps. The browser keeps
/// the last 20 (`KeepLast(20)`). The server keeps its own log of the steps,
/// private to the session, so a button inside a step can name the step by
/// its number.
import brazier
import brazier/attribute
import brazier/config
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import brazier/stream.{type Stream}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%230ea5e9'/></svg>\">"

/// The hook that draws a step's progress meter. A static file, because the
/// page's CSP allows scripts from the page's own origin only.
const hook_script = "<script src=\"/static/timeline_hooks.js\" defer></script>"

/// How many steps the browser keeps.
const timeline_limit = 20

/// How many steps the session's private log holds.
const max_log_entries = 500

/// How many steps "Fill" appends: more than the limit, so it trims.
const fill_count = 25

/// The words a streamed step receives, one per chunk.
const chunk_words = [
  "reading", "the", "file", "and", "planning", "the", "next", "step",
]

pub type Entry {
  Entry(seq: Int, agent: String, text: String, chunks: Int)
}

/// The synced model: counters only. The steps are in the stream.
pub type Model {
  Model(
    next_seq: Int,
    streaming: Option(Int),
    picked: Option(Int),
    notice: String,
  )
}

/// The server's state: the model and the session's private log of steps.
pub type Session {
  Session(model: Model, log: Dict(Int, Entry))
}

pub type Msg {
  Appended
  Prepended
  Chunked
  Filled
  ResetTimeline
  Picked(seq: Int)
  MovedToTop(seq: Int)
  Removed(seq: Int)
}

pub fn timeline() -> Stream(Entry) {
  stream.new(
    "timeline",
    key: entry_key,
    encode: encode_entry,
    decoder: entry_decoder(),
    limit: stream.KeepLast(timeline_limit),
  )
}

/// A step's key: its agent and number. Numbers only grow, so a key is
/// never reused for another step.
pub fn entry_key(entry: Entry) -> String {
  entry.agent <> ":" <> int.to_string(entry.seq)
}

pub fn encode_entry(entry: Entry) -> json.Json {
  json.object([
    #("seq", json.int(entry.seq)),
    #("agent", json.string(entry.agent)),
    #("text", json.string(entry.text)),
    #("chunks", json.int(entry.chunks)),
  ])
}

pub fn entry_decoder() -> decode.Decoder(Entry) {
  use seq <- decode.field("seq", decode.int)
  use agent <- decode.field("agent", decode.string)
  use text <- decode.field("text", decode.string)
  use chunks <- decode.field("chunks", decode.int)
  decode.success(Entry(seq:, agent:, text:, chunks:))
}

fn agent_for(seq: Int) -> String {
  case seq % 2 {
    0 -> "coder"
    _ -> "planner"
  }
}

fn new_entry(seq: Int, text: String) -> Entry {
  Entry(seq:, agent: agent_for(seq), text:, chunks: 0)
}

/// The steps every session starts with.
fn seed() -> List(Entry) {
  [
    new_entry(1, "Read the task"),
    new_entry(2, "Open the repository"),
    new_entry(3, "Plan the change"),
  ]
}

fn seed_log() -> Dict(Int, Entry) {
  seed()
  |> list.map(fn(entry) { #(entry.seq, entry) })
  |> dict.from_list
}

fn init(
  _ctx: brazier.Context,
) -> Result(#(Session, Effect(Msg)), brazier.InitError) {
  // The ops `init` returns ride the join's model_sync, so the page shows the
  // seed on the first render and again after every reconnect.
  Ok(#(
    Session(
      model: Model(next_seq: 4, streaming: None, picked: None, notice: ""),
      log: seed_log(),
    ),
    stream.insert_many(timeline(), seed(), at: stream.Append),
  ))
}

fn update(session: Session, msg: Msg) -> #(Session, Effect(Msg)) {
  let model = session.model
  case msg {
    Appended -> {
      use <- with_room(session, 1)
      let entry =
        new_entry(model.next_seq, "Step " <> int.to_string(model.next_seq))
      #(
        Session(
          model: Model(
            ..model,
            next_seq: model.next_seq + 1,
            streaming: Some(entry.seq),
            notice: "",
          ),
          log: dict.insert(session.log, entry.seq, entry),
        ),
        stream.insert(timeline(), entry, at: stream.Append),
      )
    }
    Prepended -> {
      use <- with_room(session, 1)
      let entry =
        new_entry(
          model.next_seq,
          "Earlier step " <> int.to_string(model.next_seq),
        )
      #(
        Session(
          model: Model(..model, next_seq: model.next_seq + 1, notice: ""),
          log: dict.insert(session.log, entry.seq, entry),
        ),
        stream.insert(timeline(), entry, at: stream.Prepend),
      )
    }
    Chunked -> chunk(session)
    Filled -> {
      use <- with_room(session, fill_count)
      let entries =
        int.range(
          from: model.next_seq,
          to: model.next_seq + fill_count,
          with: [],
          run: fn(entries, seq) {
            [new_entry(seq, "Batch step " <> int.to_string(seq)), ..entries]
          },
        )
        |> list.reverse
      log.info(
        "timeline",
        "Appending "
          <> int.to_string(fill_count)
          <> " steps from "
          <> int.to_string(model.next_seq)
          <> "; the browser keeps the last "
          <> int.to_string(timeline_limit),
      )
      // The streamed step is now behind the fill, and the browser may have
      // trimmed it, so the fill ends it.
      #(
        Session(
          model: Model(
            ..model,
            next_seq: model.next_seq + fill_count,
            streaming: None,
            notice: "",
          ),
          log: list.fold(entries, session.log, fn(log, entry) {
            dict.insert(log, entry.seq, entry)
          }),
        ),
        stream.insert_many(timeline(), entries, at: stream.Append),
      )
    }
    ResetTimeline -> {
      log.info(
        "timeline",
        "Resetting the timeline to its "
          <> int.to_string(list.length(seed()))
          <> " seed steps (the log held "
          <> int.to_string(dict.size(session.log))
          <> ")",
      )
      // The seed keys are not reused by later steps: next_seq keeps growing.
      #(
        Session(
          model: Model(..model, streaming: None, picked: None, notice: ""),
          log: seed_log(),
        ),
        stream.reset(timeline(), seed()),
      )
    }
    Picked(seq:) -> {
      use _entry <- with_entry(session, seq, "pick")
      #(
        Session(..session, model: Model(..model, picked: Some(seq), notice: "")),
        effect.none(),
      )
    }
    MovedToTop(seq:) -> {
      use entry <- with_entry(session, seq, "move")
      // A delete and an insert of one key in one update is a move: the
      // browser moves the step's node, so it keeps focus and its hook.
      #(
        Session(..session, model: Model(..model, notice: "")),
        effect.batch([
          stream.delete(timeline(), entry),
          stream.insert(timeline(), entry, at: stream.Prepend),
        ]),
      )
    }
    Removed(seq:) -> {
      use entry <- with_entry(session, seq, "delete")
      let streaming = case model.streaming {
        Some(streamed) if streamed == seq -> None
        other -> other
      }
      let picked = case model.picked {
        Some(chosen) if chosen == seq -> None
        other -> other
      }
      #(
        Session(
          model: Model(..model, streaming:, picked:, notice: ""),
          log: dict.delete(session.log, seq),
        ),
        stream.delete(timeline(), entry),
      )
    }
  }
}

/// Add one word to the streamed step, in place: its key is in the stream,
/// so the browser updates its node where it is.
fn chunk(session: Session) -> #(Session, Effect(Msg)) {
  let model = session.model
  case model.streaming {
    None -> {
      log.warning("timeline", "A chunk arrived while no step is streaming")
      refuse(session, "No step is streaming; append one first.")
    }
    Some(seq) -> {
      use entry <- with_entry(session, seq, "chunk")
      // Invariant: streaming ends with the last word, so a streaming step
      // always has a word left.
      let assert [word, ..rest] = list.drop(chunk_words, entry.chunks)
        as "timeline: a streaming step has received every word"
      let entry =
        Entry(
          ..entry,
          text: entry.text <> " " <> word,
          chunks: entry.chunks + 1,
        )
      let streaming = case rest {
        [] -> None
        _ -> Some(seq)
      }
      #(
        Session(
          model: Model(..model, streaming:, notice: ""),
          log: dict.insert(session.log, seq, entry),
        ),
        stream.insert(timeline(), entry, at: stream.Append),
      )
    }
  }
}

/// Run `next` when the log has room for `count` more steps, else refuse.
fn with_room(
  session: Session,
  count: Int,
  next: fn() -> #(Session, Effect(Msg)),
) -> #(Session, Effect(Msg)) {
  case dict.size(session.log) + count > max_log_entries {
    False -> next()
    True -> {
      log.warning(
        "timeline",
        "Refusing "
          <> int.to_string(count)
          <> " more step(s): the log holds "
          <> int.to_string(dict.size(session.log))
          <> " of "
          <> int.to_string(max_log_entries),
      )
      refuse(
        session,
        "The log is full ("
          <> int.to_string(max_log_entries)
          <> " steps). Reset it to go on.",
      )
    }
  }
}

/// Run `next` with step `seq` from the log, else refuse: a button can name
/// a step that another tab of the same session deleted.
fn with_entry(
  session: Session,
  seq: Int,
  action: String,
  next: fn(Entry) -> #(Session, Effect(Msg)),
) -> #(Session, Effect(Msg)) {
  case dict.get(session.log, seq) {
    Ok(entry) -> next(entry)
    Error(Nil) -> {
      log.warning(
        "timeline",
        "Cannot "
          <> action
          <> " step "
          <> int.to_string(seq)
          <> ": not in the log",
      )
      refuse(
        session,
        "Step " <> int.to_string(seq) <> " is no longer in the log.",
      )
    }
  }
}

fn refuse(session: Session, notice: String) -> #(Session, Effect(Msg)) {
  #(Session(..session, model: Model(..session.model, notice:)), effect.none())
}

fn sync(session: Session) -> Model {
  session.model
}

fn describe(step: Option(Int)) -> String {
  case step {
    Some(seq) -> "step " <> int.to_string(seq)
    None -> "none"
  }
}

pub fn view(model: Model, _local: Nil) -> Element(Msg) {
  html.main(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "780px"),
        #("margin", "32px auto"),
        #("padding", "0 16px"),
      ]),
    ],
    [
      html.h1([], [html.text("Agent timeline")]),
      html.p([attribute.data("testid", "status")], [
        html.text(
          "Next: step "
          <> int.to_string(model.next_seq)
          <> ". Picked: "
          <> describe(model.picked)
          <> ". Streaming: "
          <> describe(model.streaming)
          <> ".",
        ),
      ]),
      case model.notice {
        "" -> element.none()
        notice ->
          html.p(
            [attribute.data("testid", "notice"), attribute.role("status")],
            [html.text(notice)],
          )
      },
      html.div(
        [
          attribute.styles([
            #("display", "flex"),
            #("gap", "8px"),
            #("flex-wrap", "wrap"),
          ]),
        ],
        [
          control("append", Appended, "Append", False),
          control("prepend", Prepended, "Prepend", False),
          control("chunk", Chunked, "Stream chunk", model.streaming == None),
          control("fill", Filled, "Fill " <> int.to_string(fill_count), False),
          control("reset", ResetTimeline, "Reset", False),
        ],
      ),
      stream.render(timeline(), "ol", [attribute.id("timeline")], render_entry),
    ],
  )
}

fn control(
  id: String,
  msg: Msg,
  label: String,
  disabled: Bool,
) -> Element(Msg) {
  html.button(
    [attribute.id(id), attribute.disabled(disabled), event.on_click(msg)],
    [html.text(label)],
  )
}

/// One step. Rendered when the step is inserted or updated, from the step
/// alone. The meter is drawn by the `ChunkMeter` hook
/// (static/timeline_hooks.js), which owns its children.
pub fn render_entry(entry: Entry) -> Element(Msg) {
  html.li(
    [
      attribute.class("entry"),
      attribute.data("seq", int.to_string(entry.seq)),
      attribute.styles([
        #("display", "flex"),
        #("flex-wrap", "wrap"),
        #("gap", "8px"),
        #("align-items", "center"),
        #("padding", "4px 0"),
      ]),
    ],
    [
      html.span([attribute.class("agent")], [html.text(entry.agent)]),
      html.span([attribute.class("text"), attribute.styles([#("flex", "1")])], [
        html.text(entry.text),
      ]),
      html.span(
        [
          attribute.class("meter"),
          attribute.hook("ChunkMeter"),
          attribute.watch(["data-chunks"]),
          attribute.data("chunks", int.to_string(entry.chunks)),
          attribute.ignore_updates(),
        ],
        [],
      ),
      html.button([attribute.class("pick"), event.on_click(Picked(entry.seq))], [
        html.text("Pick"),
      ]),
      html.button(
        [attribute.class("top"), event.on_click(MovedToTop(entry.seq))],
        [html.text("Top")],
      ),
      html.button(
        [attribute.class("delete"), event.on_click(Removed(entry.seq))],
        [html.text("Delete")],
      ),
    ],
  )
}

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let assert Ok(Nil) =
    brazier.full_application(init:, update:, sync:, local: local.none(), view:)
    |> brazier.title(fn(_model) { "Brazier Timeline" })
    |> brazier.head_html(favicon <> hook_script)
    |> brazier.static_dir("static")
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
