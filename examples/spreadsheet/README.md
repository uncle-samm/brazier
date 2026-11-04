# Spreadsheet

An editable 10x5 grid shared by every open tab, built with
`brazier.full_application` and a `local.layer`.

## Features

- Click a cell to select it and click again to edit it. Enter (or the
  Save button) saves and Escape cancels.
- The selection and the edit buffer are Local state, kept in the browser.
  Clicking and typing send nothing to the server; only a saved cell does.
- Each cell is its own `brazier/store` entry (`A1`, `B2`, ...), so two tabs
  editing different cells never overwrite each other.
- When any session saves, the store broadcasts on its topic. Every session
  subscribes to that topic and re-reads the grid.
- The server rejects saves outside the grid, and values over 1000
  characters, and logs a warning for each.

## Run

```bash
cd examples/spreadsheet
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080 in two tabs, edit a cell in one, and watch it
appear in the other.
