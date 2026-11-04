# Multi-File Kanban

A per-session kanban board built with `beacon.simple`, whose `Card` and
`Column` types live in a separate domain module.

## Features

- Model and message types come from `src/domains/board.gleam`. The build
  generates their codecs and compiles `update`, imports included, to
  JavaScript.
- `update` runs in the browser first, so a moved or added card shows up
  instantly. The server runs the same `update` and stays authoritative.
  If the two ever disagree, the server's model wins and the browser logs
  a warning.
- Drag and drop with typed messages: `on_drag_start(DragStart(card.id))`,
  `on_drop(DropOn(column))` and `on_drag_end(DragEnd)`.
- `on_drag_over(DragOver(column)) |> event.throttle(250)` highlights the
  column under the pointer. The default is still prevented on every
  `dragover`, so the column stays a drop target, but at most four messages
  a second reach `update`.
- Titles over 100 characters are rejected, with a warning logged.

Each session has its own board. The `kanban` example shares one board
between sessions.

## Run

```bash
cd examples/multi_kanban
gleam run -m beacon/build   # first, and after every change
gleam run
```

Open http://localhost:8080 and drag cards between columns.
