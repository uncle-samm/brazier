# Counter

The simplest Brazier app: a counter built with `brazier.simple`.

## Features

- Minimal Model-View-Update (MVU) pattern
- `event.on_click` event handling
- `brazier.simple`: a pure `update` that the build also compiles to
  JavaScript, so a click updates the page at once; the server runs the same
  `update` and its model wins if the two ever differ

## Run

```bash
cd examples/counter
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080 and click + and - to change the count.
