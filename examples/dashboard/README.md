# Live Dashboard

Auto-refreshing BEAM runtime metrics with sparkline charts, built with
`beacon.application`.

## Features

- Server push with `effect.every` from `init`: no client interaction
  needed. The timer starts on the connected mount; the HTML render drops it
- Real BEAM metrics (process count, memory, uptime), read on the server
  through a small Erlang FFI module (`src/dashboard_ffi.erl`)
- SVG sparklines drawn with `beacon/svg`, over a rolling 30-sample history
- Updates every second

## Run

```bash
cd examples/dashboard
gleam run -m beacon/build   # after changing the source
gleam run
```

Open http://localhost:8080 and watch the process count, memory and uptime
update.
