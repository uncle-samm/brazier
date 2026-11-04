# Snake

Snake played with the arrow keys, with high scores shared between players,
built with `brazier.full_application` and a `local.layer`.

## Features

- The server drives the game. `effect.every(150, Tick)` starts when a game
  begins, and each tick moves the snake one cell.
- The board has `event.on_keydown(KeyPressed)`, `tabindex(0)` and
  `autofocus(True)`, so it takes keyboard focus as soon as a game starts.
- The Local layer sends only arrow keys to the server. Other keys never
  leave the browser. The name draft is Local state too, and a blank name is
  refused in the browser.
- A turn is checked against the direction of the last move, not the last
  key, so two quick presses between ticks cannot reverse the snake into
  itself.
- Food is placed on a random free cell. A board with no free cell left
  ends the game.
- When a game ends, its score is appended to a `brazier/store` list. Every
  session re-reads the list when it changes and shows the top five.
- The board is drawn with `brazier/svg`.

## Run

```bash
cd examples/snake
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080, enter your name, then steer with the arrow
keys.
