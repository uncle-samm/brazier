# Collaborative Canvas

A shared drawing canvas built with `brazier.full_application` and a
`local.layer`. Strokes drawn in one tab appear in every other tab.

## Features

- Drawing runs in the browser. `PenDown`, `PenMoved` and `ColourPicked`
  are handled by the Local layer and never reach the server, so drawing
  sends no frames. The pointer position comes from `event.mouse_position()`,
  and moves are sampled with `event.throttle` at about 60 a second.
- Only the finished stroke is sent: one `PenUp` on mouseup, or when the
  pointer leaves the canvas.
- The server checks every stroke the browser builds: the colour must be in
  the palette, and the stroke needs at least one point, at most 2000 points,
  and every point inside the canvas. The canvas holds at most 2000 strokes.
  A rejected stroke is logged as a warning.
- A sent stroke stays on screen while the server handles it. The server
  counts the `PenUp` messages it has handled for the session, and the
  browser drops a sent stroke once that count reaches it, whether the
  stroke was accepted or rejected.
- Accepted strokes are appended to a `brazier/store` list. Every session
  re-reads the list when it changes, and Clear empties it for everyone.
- Strokes are drawn with `brazier/svg`. A single click draws a dot.

## Run

```bash
cd examples/canvas
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080 in two tabs, draw in one, and the strokes
appear in the other.
