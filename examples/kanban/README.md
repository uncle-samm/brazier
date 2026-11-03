# Kanban Board

A drag-and-drop board shared by every open tab, built with
`beacon.full_application` and a `local.layer`.

## Features

- HTML5 drag and drop with typed messages. A card sends
  `on_drag_start(DragStart(card.id))` and a column sends
  `on_drop(DropOn(column))`. A drop target does not know which card was
  dropped on it, so the server state remembers the card from `DragStart`.
- `dragover` fires many times a second. The Local layer handles it in the
  browser (it highlights the column under the pointer), so it never
  reaches the server. A whole drag is three messages: start, drop, end.
- The new-card draft is Local state too. A blank card is refused in the
  browser, and the server checks again: it rejects empty titles and titles
  over 100 characters.
- The board is an append-only change log in a `beacon/store` list, replayed
  after a constant starting board. Concurrent edits from different tabs
  never overwrite each other. Each write broadcasts on the store's topic,
  and every session re-reads the log.

## Run

```bash
cd examples/kanban
gleam run -m beacon/build   # first, and after every change
gleam run
```

Open http://localhost:8080 in two tabs, drag a card in one, and watch it
move in the other.
