# Counter with Local State

Counter demonstrating the Model + Local state split.

## Features

- `Model.count` is server state (synced across the wire)
- `Local.input` and `Local.menu_open` are client state (instant, per-tab)
- `brazier.full_application` with `local.layer(init:, update:)`: `update_local` returns `local.handled` (browser only) or `local.forward` (also sent to the server)
- Toggle menu and text input update without server round-trips

## Run

```bash
cd examples/counter_local
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080: increment the counter (server) and type/toggle menu (local).
