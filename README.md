# Brazier

Brazier is an alpha full-stack Gleam framework for building MVU web apps on the
BEAM. It is not published on Hex yet. It was named Beacon until 2026-11-04 and
was renamed because another package holds that name on Hex; see
[CHANGELOG.md](CHANGELOG.md).

How a page works:

- The server renders the first page (SSR).
- The browser loads a generated client bundle and connects over a WebSocket,
  one BEAM process per session.
- The server is authoritative: `update` runs there, and the synced `Model`
  reaches the browser as JSON state updates.
- An optional Local layer handles per-tab state such as dropdowns and form
  drafts in the browser, without a server round trip.
- With `brazier.full_application`, server state that `sync` does not return
  stays on the BEAM and is never sent to the browser.

## Minimal App

```gleam
import brazier
import brazier/config
import brazier/element.{type Element}
import brazier/event
import brazier/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

fn init(_ctx: brazier.Context) -> Result(Model, brazier.InitError) {
  Ok(Model(count: 0))
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.button([event.on_click(Increment)], [
    html.text("Count: " <> int.to_string(model.count)),
  ])
}

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let assert Ok(Nil) =
    brazier.simple(init:, update:, view:)
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
```

Every app needs a secret key of at least 32 bytes. It signs session and join
tokens and keys the cluster peer check. `brazier.start` refuses an app
without one and names the setting, and there is no generated default.
`config.secret_key()` reads it from `SECRET_KEY`.

An app needs two generated artifacts before it starts: the server codec
(`src/brazier_codec.gleam`) and the client bundle (`priv/static/`). Generate
them with `gleam run -m brazier/build`, then `gleam run`; or use
`gleam run -m brazier/dev`, which builds, runs and rebuilds on change.
`brazier.start` logs and returns an error when either artifact is missing,
and `main` crashes on it, so `gleam run` exits with status 1 and says what to
run. The examples do not track their generated files, so build one before its
first run. To run the counter example from this repository:

```sh
cd examples/counter
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run
```

Keep the same `SECRET_KEY` across restarts: a new key invalidates every
signed token, so open tabs lose their session.

[Getting Started](docs/GETTING_STARTED.md) walks through a full app.

## Recommended APIs

- Pick one constructor: `brazier.simple` (a pure `update` that also runs in the
  browser), `brazier.application` (server `update` with effects) or
  `brazier.full_application` (private server state, `sync` and a Local layer).
- `brazier.with_router(parse:, on_change:)` routes by URL; see
  [Routing](docs/ROUTING.md).
- `brazier/api.routes`, `api.json_value`, `api.read_text` and `api.read_form`
  for API routes.
- `brazier/auth.session_routes`, `auth.protect_ws` (or `auth.allow_guests_ws`)
  and `auth.init_from_session` for session-cookie auth.

## Requirements

- Gleam 1.19.2 and Erlang/OTP 28.
- `node` and `npx`: the build bundles the client with a pinned esbuild through
  `npx`, and `gleam test` needs both (client round-trip tests run in `node`,
  and the build fixture tests bundle with esbuild). A missing tool fails
  those tests; they are never skipped.
- For the browser (CDP) tests: Python 3 with `requirements-dev.txt` in
  `.venv`, and Chrome or Chromium. See [Testing](docs/TESTING.md).

## Development

In the repository root (the framework itself has no `main`; run an app from
`examples/`):

```sh
gleam build                  # zero warnings
gleam format --check src test
gleam run -m brazier/lint     # 0 violations
gleam test
scripts/check_docs.sh        # doc samples compile, doc links resolve
```

All of them must pass before a change is done.

## Project Docs

- [Getting Started](docs/GETTING_STARTED.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Routing](docs/ROUTING.md)
- [Security](docs/SECURITY.md)
- [Deployment](docs/DEPLOYMENT.md)
- [Testing](docs/TESTING.md)
- [Current Progress](docs/PROGRESS.md)

## License

MIT; see [LICENSE](LICENSE).
