/// Pong, demonstrating:
/// - `brazier.application`: every message runs on the server, and the browser
///   only renders;
/// - a game loop of keyed `effect.after` timers. Each tick schedules the next
///   one while the game runs, so pausing stops the loop. The key makes the
///   timer single-flight: a Start inside a pending tick's window replaces
///   that tick instead of running a second loop.
import brazier
import brazier/attribute
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/log
import gleam/int

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

const width = 600

const height = 400

const paddle_h = 80

const paddle_w = 10

const paddle_speed = 8

const ball_size = 10

/// About 60 frames a second.
const tick_ms = 16

const tick_key = "pong_tick"

pub type Model {
  Model(
    left_y: Int,
    right_y: Int,
    ball_x: Int,
    ball_y: Int,
    ball_dx: Int,
    ball_dy: Int,
    left_score: Int,
    right_score: Int,
    running: Bool,
  )
}

pub type Msg {
  LeftUp
  LeftDown
  RightUp
  RightDown
  Tick
  StartGame
  PauseGame
}

fn init(
  _ctx: brazier.Context,
) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(
    Model(
      left_y: height / 2,
      right_y: height / 2,
      ball_x: width / 2,
      ball_y: height / 2,
      ball_dx: 4,
      ball_dy: 2,
      left_score: 0,
      right_score: 0,
      running: False,
    ),
    effect.none(),
  ))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    LeftUp -> #(
      Model(..model, left_y: int.max(paddle_h / 2, model.left_y - paddle_speed)),
      effect.none(),
    )
    LeftDown -> #(
      Model(
        ..model,
        left_y: int.min(height - paddle_h / 2, model.left_y + paddle_speed),
      ),
      effect.none(),
    )
    RightUp -> #(
      Model(
        ..model,
        right_y: int.max(paddle_h / 2, model.right_y - paddle_speed),
      ),
      effect.none(),
    )
    RightDown -> #(
      Model(
        ..model,
        right_y: int.min(height - paddle_h / 2, model.right_y + paddle_speed),
      ),
      effect.none(),
    )
    StartGame ->
      case model.running {
        True -> {
          log.warning("pong", "Ignored a Start while the game is running")
          #(model, effect.none())
        }
        False -> {
          log.info("pong", "Game started")
          #(
            Model(
              ..model,
              running: True,
              ball_x: width / 2,
              ball_y: height / 2,
              ball_dx: 4,
              ball_dy: 2,
            ),
            next_tick(),
          )
        }
      }
    PauseGame ->
      case model.running {
        True -> {
          log.info("pong", "Game paused")
          // The pending tick arrives while paused and schedules no other.
          #(Model(..model, running: False), effect.none())
        }
        False -> {
          log.warning("pong", "Ignored a Pause while the game is paused")
          #(model, effect.none())
        }
      }
    Tick ->
      case model.running {
        True -> #(advance_ball(model), next_tick())
        // The tick scheduled before a pause.
        False -> #(model, effect.none())
      }
  }
}

fn next_tick() -> Effect(Msg) {
  effect.keyed(tick_key, effect.after(tick_ms, fn() { Tick }))
}

fn advance_ball(model: Model) -> Model {
  let new_x = model.ball_x + model.ball_dx
  let new_y = model.ball_y + model.ball_dy
  let new_dy = case new_y <= ball_size || new_y >= height - ball_size {
    True -> -model.ball_dy
    False -> model.ball_dy
  }
  let new_y = int.clamp(new_y, ball_size, height - ball_size)
  let #(dx, nx) = case
    new_x <= paddle_w + ball_size
    && new_y >= model.left_y - paddle_h / 2
    && new_y <= model.left_y + paddle_h / 2
  {
    True -> #(int.absolute_value(model.ball_dx), paddle_w + ball_size + 1)
    False -> #(model.ball_dx, new_x)
  }
  let #(dx, nx) = case
    nx >= width - paddle_w - ball_size
    && new_y >= model.right_y - paddle_h / 2
    && new_y <= model.right_y + paddle_h / 2
  {
    True -> #(-int.absolute_value(dx), width - paddle_w - ball_size - 1)
    False -> #(dx, nx)
  }
  case nx {
    x if x <= 0 -> {
      log.info("pong", "P2 scored")
      Model(
        ..model,
        right_score: model.right_score + 1,
        ball_x: width / 2,
        ball_y: height / 2,
        ball_dx: 4,
        ball_dy: 2,
      )
    }
    x if x >= width -> {
      log.info("pong", "P1 scored")
      Model(
        ..model,
        left_score: model.left_score + 1,
        ball_x: width / 2,
        ball_y: height / 2,
        ball_dx: -4,
        ball_dy: 2,
      )
    }
    _ -> Model(..model, ball_x: nx, ball_y: new_y, ball_dx: dx, ball_dy: new_dy)
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class("pong-game"),
      attribute.styles([
        #("font-family", "system-ui"),
        #("text-align", "center"),
      ]),
    ],
    [
      html.h1([], [html.text("Brazier Pong")]),
      html.div(
        [
          attribute.class("pong-score"),
          attribute.styles([#("font-size", "2rem"), #("margin", "0.5rem")]),
        ],
        [
          html.text(
            int.to_string(model.left_score)
            <> " - "
            <> int.to_string(model.right_score),
          ),
        ],
      ),
      html.div(
        [
          attribute.styles([
            #("position", "relative"),
            #("width", px(width)),
            #("height", px(height)),
            #("background", "#111"),
            #("margin", "0 auto"),
            #("overflow", "hidden"),
          ]),
        ],
        [
          block(
            [],
            0,
            model.left_y - paddle_h / 2,
            paddle_w,
            paddle_h,
            "#4ecdc4",
          ),
          block(
            [],
            width - paddle_w,
            model.right_y - paddle_h / 2,
            paddle_w,
            paddle_h,
            "#ff6b6b",
          ),
          block(
            [attribute.data("testid", "pong-ball")],
            model.ball_x - ball_size / 2,
            model.ball_y - ball_size / 2,
            ball_size,
            ball_size,
            "#fff",
          ),
        ],
      ),
      html.div(
        [
          attribute.class("pong-controls"),
          attribute.styles([
            #("display", "flex"),
            #("justify-content", "space-between"),
            #("width", px(width)),
            #("margin", "1rem auto"),
          ]),
        ],
        [
          html.div([], [
            html.strong([], [html.text("P1 ")]),
            html.button([event.on_click(LeftUp)], [html.text("Up")]),
            html.button([event.on_click(LeftDown)], [html.text("Down")]),
          ]),
          html.div([], [
            case model.running {
              True ->
                html.button([event.on_click(PauseGame)], [html.text("Pause")])
              False ->
                html.button([event.on_click(StartGame)], [html.text("Start")])
            },
          ]),
          html.div([], [
            html.strong([], [html.text("P2 ")]),
            html.button([event.on_click(RightUp)], [html.text("Up")]),
            html.button([event.on_click(RightDown)], [html.text("Down")]),
          ]),
        ],
      ),
      html.p([], [html.text("All game logic runs on the server.")]),
    ],
  )
}

fn block(
  attributes: List(attribute.Attribute(Msg)),
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  colour: String,
) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("position", "absolute"),
        #("left", px(x)),
        #("top", px(y)),
        #("width", px(w)),
        #("height", px(h)),
        #("background", colour),
      ]),
      ..attributes
    ],
    [],
  )
}

fn px(value: Int) -> String {
  int.to_string(value) <> "px"
}

pub fn main() {
  let assert Ok(Nil) =
    brazier.application(init:, update:, view:)
    |> brazier.title(fn(_model) { "Brazier Pong" })
    |> brazier.head_html(favicon)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
