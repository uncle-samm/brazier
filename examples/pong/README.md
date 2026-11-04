# Pong

Two-player Pong built with `brazier.application`. All game logic runs on the
server, and the browser only renders.

## Features

- A game loop of about 60 ticks a second. Each tick schedules the next with
  `effect.keyed("pong_tick", effect.after(16, fn() { Tick }))` while the
  game runs, so pausing stops the loop.
- The key makes the timer single-flight: pressing Start right after Pause
  replaces the pending tick instead of running a second loop.
- Ball physics with wall bounces and paddle collisions, and a score that
  resets the ball after each point.
- Button controls for both paddles. A Start while running, or a Pause while
  paused, is ignored with a warning logged.

## Run

```bash
cd examples/pong
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080, click Start, then use the Up and Down buttons
for P1 and P2.
