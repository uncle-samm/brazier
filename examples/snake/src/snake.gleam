/// Snake, demonstrating:
/// - server push with `effect.every`: the game ticks on the server and the
///   browser only renders;
/// - keyboard input filtered in Local state: arrow keys reach the server,
///   other keys and the name draft never leave the browser;
/// - a high-score table shared by every session, kept in a `brazier/store`
///   list and re-read when any session records a score.
import brazier
import brazier/attribute
import brazier/config
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import brazier/store.{type ListStore}
import brazier/svg
import gleam/int
import gleam/list
import gleam/order
import gleam/string

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

// --- Types ---

pub type Point {
  Point(x: Int, y: Int)
}

pub type Direction {
  Up
  Down
  Left
  Right
}

pub type Phase {
  NameEntry
  Playing
  GameOver
}

pub type HighScore {
  HighScore(name: String, score: Int)
}

/// Synced to the browser.
pub type Model {
  Model(
    phase: Phase,
    player_name: String,
    /// Head first.
    snake: List(Point),
    /// The direction the snake moved on the last tick.
    moved: Direction,
    /// The direction it moves on the next tick.
    heading: Direction,
    food: Point,
    score: Int,
    high_scores: List(HighScore),
  )
}

/// Client-only.
pub type Local {
  Local(name_draft: String)
}

pub type Msg {
  NameChanged(String)
  StartGame(String)
  KeyPressed(String)
  Tick
  RestartGame
  /// A session (this one included) recorded a score.
  ScoresChanged
}

const grid_width = 20

const grid_height = 15

const cell_size = 25

const tick_ms = 150

const max_name_length = 20

const shown_scores = 5

const scores_key = "scores"

fn start_snake() -> List(Point) {
  [Point(x: 10, y: 7)]
}

// --- High scores ---

fn read_high_scores(scores: ListStore(HighScore)) -> List(HighScore) {
  store.get_all(scores, scores_key)
  |> list.sort(fn(a, b) { order.reverse(int.compare)(a.score, b.score) })
  |> list.take(shown_scores)
}

// --- Init and update (server) ---

fn init(
  scores: ListStore(HighScore),
) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  let snake = start_snake()
  Ok(#(
    Model(
      phase: NameEntry,
      player_name: "",
      snake:,
      moved: Right,
      heading: Right,
      food: Point(x: 15, y: 7),
      score: 0,
      high_scores: read_high_scores(scores),
    ),
    effect.none(),
  ))
}

fn update(
  scores: ListStore(HighScore),
  model: Model,
  msg: Msg,
) -> #(Model, Effect(Msg)) {
  case msg {
    StartGame(name) -> start_game(model, string.trim(name))
    KeyPressed(key) ->
      case model.phase, direction_for_key(key) {
        Playing, Ok(direction) -> #(steer(model, direction), effect.none())
        // A late key press after the game ended.
        NameEntry, Ok(_) | GameOver, Ok(_) -> #(model, effect.none())
        _, Error(Nil) -> {
          // `update_local` forwards only arrow keys.
          log.warning("snake", "Ignored a forwarded non-arrow key " <> key)
          #(model, effect.none())
        }
      }
    Tick ->
      case model.phase {
        Playing -> advance(scores, model)
        NameEntry | GameOver -> #(model, effect.none())
      }
    RestartGame ->
      case model.phase {
        GameOver -> {
          log.info("snake", model.player_name <> " restarted")
          // The timer from `StartGame` is still running.
          #(new_round(model), effect.none())
        }
        NameEntry | Playing -> {
          log.warning("snake", "Ignored a restart while the game is not over")
          #(model, effect.none())
        }
      }
    ScoresChanged -> #(
      Model(..model, high_scores: read_high_scores(scores)),
      effect.none(),
    )
    // `update_local` handles this in the browser and never forwards it.
    NameChanged(_) -> #(model, effect.none())
  }
}

fn start_game(model: Model, name: String) -> #(Model, Effect(Msg)) {
  case
    model.phase,
    string.is_empty(name),
    string.length(name) > max_name_length
  {
    NameEntry, False, False -> {
      log.info("snake", name <> " started playing")
      // The only transition out of NameEntry, so this starts one timer per
      // session.
      #(
        Model(..new_round(model), player_name: name),
        effect.every(tick_ms, fn() { Tick }),
      )
    }
    NameEntry, True, _ -> {
      log.warning("snake", "Rejected an empty player name")
      #(model, effect.none())
    }
    NameEntry, _, True -> {
      log.warning(
        "snake",
        "Rejected a player name of "
          <> int.to_string(string.length(name))
          <> " characters (max "
          <> int.to_string(max_name_length)
          <> ")",
      )
      #(model, effect.none())
    }
    Playing, _, _ | GameOver, _, _ -> {
      log.warning("snake", "Ignored a second StartGame")
      #(model, effect.none())
    }
  }
}

fn new_round(model: Model) -> Model {
  let snake = start_snake()
  Model(
    ..model,
    phase: Playing,
    snake:,
    moved: Right,
    heading: Right,
    food: Point(x: 15, y: 7),
    score: 0,
  )
}

fn direction_for_key(key: String) -> Result(Direction, Nil) {
  case key {
    "ArrowUp" -> Ok(Up)
    "ArrowDown" -> Ok(Down)
    "ArrowLeft" -> Ok(Left)
    "ArrowRight" -> Ok(Right)
    _ -> Error(Nil)
  }
}

/// Turn, unless that would reverse into the snake. The check is against
/// the last move rather than the queued heading, so two quick presses
/// within one tick cannot reverse it either.
fn steer(model: Model, direction: Direction) -> Model {
  case model.moved, direction {
    Up, Down | Down, Up | Left, Right | Right, Left -> model
    _, _ -> Model(..model, heading: direction)
  }
}

fn advance(
  scores: ListStore(HighScore),
  model: Model,
) -> #(Model, Effect(Msg)) {
  // Invariant: the snake starts with one point and only ever grows.
  let assert [head, ..] = model.snake
  let next = case model.heading {
    Up -> Point(..head, y: head.y - 1)
    Down -> Point(..head, y: head.y + 1)
    Left -> Point(..head, x: head.x - 1)
    Right -> Point(..head, x: head.x + 1)
  }
  let ate = next == model.food
  let body = case ate {
    True -> model.snake
    False -> drop_last(model.snake)
  }
  let hit_wall =
    next.x < 0 || next.x >= grid_width || next.y < 0 || next.y >= grid_height
  case hit_wall || list.contains(body, next) {
    True -> game_over(scores, model)
    False -> {
      let snake = [next, ..body]
      let model = Model(..model, snake:, moved: model.heading)
      case ate {
        False -> #(model, effect.none())
        True -> {
          let model = Model(..model, score: model.score + 10)
          case free_cells(snake) {
            // The snake fills the board.
            [] -> game_over(scores, model)
            free -> #(Model(..model, food: pick(free)), effect.none())
          }
        }
      }
    }
  }
}

fn game_over(
  scores: ListStore(HighScore),
  model: Model,
) -> #(Model, Effect(Msg)) {
  log.info(
    "snake",
    model.player_name <> " scored " <> int.to_string(model.score),
  )
  let entry = HighScore(name: model.player_name, score: model.score)
  // The store broadcasts on its topic, which every session (this one
  // included) turns into `ScoresChanged`.
  #(
    Model(..model, phase: GameOver),
    effect.from(fn(_dispatch) { store.append(scores, scores_key, entry) }),
  )
}

fn drop_last(items: List(a)) -> List(a) {
  list.take(items, list.length(items) - 1)
}

fn free_cells(snake: List(Point)) -> List(Point) {
  list.repeat(Nil, grid_height)
  |> list.index_map(fn(_, y) {
    list.repeat(Nil, grid_width)
    |> list.index_map(fn(_, x) { Point(x:, y:) })
  })
  |> list.flatten
  |> list.filter(fn(point) { !list.contains(snake, point) })
}

fn pick(points: List(Point)) -> Point {
  // Invariant: the caller passes a non-empty list, so the index is in range.
  let assert Ok(point) =
    list.drop(points, int.random(list.length(points))) |> list.first
  point
}

fn sync(model: Model) -> Model {
  model
}

// --- Local (browser) ---

pub fn init_local(_model: Model) -> Local {
  Local(name_draft: "")
}

pub fn update_local(
  _model: Model,
  local: Local,
  msg: Msg,
) -> local.Update(Local) {
  case msg {
    NameChanged(text) -> local.handled(Local(name_draft: text))
    StartGame(name) ->
      case string.trim(name) {
        "" -> local.handled(local)
        _ -> local.forward(local)
      }
    KeyPressed(key) ->
      case direction_for_key(key) {
        Ok(_) -> local.forward(local)
        Error(Nil) -> local.handled(local)
      }
    Tick | RestartGame | ScoresChanged -> local.forward(local)
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> Element(Msg) {
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
      case model.phase {
        NameEntry -> view_name_entry(local)
        Playing | GameOver -> view_game(model)
      },
      view_high_scores(model.high_scores),
    ],
  )
}

fn view_name_entry(local: Local) -> Element(Msg) {
  html.div([attribute.style("text-align", "center")], [
    html.h1([], [html.text("Snake")]),
    html.form(
      [
        event.on_submit(fn(_fields) { StartGame(local.name_draft) }),
        attribute.styles([
          #("display", "flex"),
          #("gap", "8px"),
          #("justify-content", "center"),
        ]),
      ],
      [
        html.input([
          attribute.type_("text"),
          attribute.placeholder("Your name..."),
          attribute.aria("label", "Your name"),
          attribute.value(local.name_draft),
          event.on_input(NameChanged),
        ]),
        html.button([attribute.type_("submit")], [html.text("Play")]),
      ],
    ),
  ])
}

fn view_game(model: Model) -> Element(Msg) {
  let width = int.to_string(grid_width * cell_size)
  let height = int.to_string(grid_height * cell_size)
  html.div(
    [
      event.on_keydown(KeyPressed),
      attribute.tabindex(0),
      attribute.autofocus(True),
      attribute.data("board", "true"),
      attribute.style("outline", "none"),
    ],
    [
      html.h1([], [html.text("Snake: " <> model.player_name)]),
      html.p([], [
        html.text("Score: "),
        html.span([attribute.id("score")], [
          html.text(int.to_string(model.score)),
        ]),
        html.text(" | Click the board, then use the arrow keys"),
      ]),
      svg.svg(
        [
          svg.viewbox("0 0 " <> width <> " " <> height),
          svg.width(width),
          svg.height(height),
          attribute.styles([
            #("border", "2px solid #333"),
            #("border-radius", "4px"),
            #("background", "#1a1a2e"),
            #("display", "block"),
          ]),
        ],
        list.flatten([
          [render_cell(model.food, "#ff4444")],
          list.index_map(model.snake, fn(point, i) {
            render_cell(point, case i {
              0 -> "#44ff44"
              _ -> "#22cc22"
            })
          }),
          case model.phase {
            GameOver -> [
              svg.text(
                [
                  svg.x(int.to_string(grid_width * cell_size / 2)),
                  svg.y(int.to_string(grid_height * cell_size / 2)),
                  attribute.attribute("text-anchor", "middle"),
                  attribute.attribute("font-size", "32"),
                  svg.fill("white"),
                ],
                [html.text("GAME OVER")],
              ),
            ]
            NameEntry | Playing -> []
          },
        ]),
      ),
      case model.phase {
        GameOver ->
          html.button(
            [
              event.on_click(RestartGame),
              attribute.styles([
                #("margin-top", "1rem"),
                #("padding", "8px 16px"),
                #("font-size", "16px"),
              ]),
            ],
            [html.text("Play Again")],
          )
        NameEntry | Playing -> element.none()
      },
    ],
  )
}

fn render_cell(point: Point, colour: String) -> Element(Msg) {
  svg.rect([
    svg.x(int.to_string(point.x * cell_size + 1)),
    svg.y(int.to_string(point.y * cell_size + 1)),
    svg.width(int.to_string(cell_size - 2)),
    svg.height(int.to_string(cell_size - 2)),
    svg.rx("3"),
    svg.fill(colour),
  ])
}

fn view_high_scores(high_scores: List(HighScore)) -> Element(Msg) {
  html.div([attribute.style("margin-top", "1.5rem")], [
    html.h2([attribute.style("font-size", "1.1rem")], [
      html.text("High scores"),
    ]),
    case high_scores {
      [] ->
        html.p([attribute.style("color", "#999")], [html.text("No scores yet")])
      _ ->
        html.ol(
          [attribute.id("high-scores")],
          list.map(high_scores, fn(entry) {
            html.li([], [
              html.text(entry.name <> ": " <> int.to_string(entry.score)),
            ])
          }),
        )
    },
  ])
}

// --- Start ---

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let scores = store.new_list("snake_scores")
  let assert Ok(Nil) =
    brazier.full_application(
      init: fn(_ctx) { init(scores) },
      update: fn(model, msg) { update(scores, model, msg) },
      sync:,
      local: local.layer(init: init_local, update: update_local),
      view:,
    )
    |> brazier.title(fn(_model) { "Snake" })
    |> brazier.subscriptions(fn(_model) { [store.list_topic(scores)] })
    |> brazier.on_notify(fn(_topic) { ScoresChanged })
    |> brazier.head_html(favicon)
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
