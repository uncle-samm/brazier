# Routed Workspace

Routing, a Local layer and server-authoritative Model updates in one
`beacon.full_application`.

## Features

- `beacon.with_router` maps `/` (overview), `/pipeline` and `/settings` to
  a `Route` in the Model. Any other path is a 404. Nav links and the back
  and forward buttons change the page without a reload.
- Local state (`local.layer`): the inspector panel, the selected tab, the
  card draft, the lane filter, compact mode, the profile draft and the
  actions menu. `update_local` handles these messages in the browser and
  sends nothing to the server.
- Model state: deploys, incidents, pipeline cards and the saved profile.
  These messages are forwarded, and the server validates them:
  - an empty or over-long card title is refused, and so is a card past
    the board limit
  - advancing an unknown card is refused
  - an empty or over-long display name, or an unknown role, is refused
  - resolving with no active incident is refused
  Each refusal is logged as a warning.
- Forms use `event.on_submit`, which delivers the fields as
  `List(#(String, String))`.

## Run

```bash
cd examples/routed_workspace
gleam run -m beacon/build   # first, and after every change
gleam run -m main
```

Open http://localhost:8080.
