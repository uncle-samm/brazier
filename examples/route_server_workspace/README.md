# Route Server Workspace

Routed pages that are components with private server state.

## Features

- `brazier.full_application` with `brazier.with_router`: `/` (accounts) and
  `/settings`. Any other path is a 404.
- Each page module is a component with a public `Model`, a `Msg`, a `view`
  and a server-only `Server` record built by `init_server`. Its `update`
  takes and returns both, and runs only on the server.
- The root `Session` holds the Model next to both pages' `Server` records.
  `sync` sends only the Model, so the audit counts and signing keys stay on
  the server. The client bundle holds only what `view` reaches, so the keys
  are not in the JavaScript either.
- The root maps page messages with `element.map(Accounts)` and
  `element.map(Settings)`.
- Unhappy paths: a transfer that would take the balance below zero is
  refused, an email over 254 characters is refused, and saving an email
  without `@` is refused. Each refusal is logged as a warning.

## Run

```bash
cd examples/route_server_workspace
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run -m main
```

Open http://localhost:8080.
