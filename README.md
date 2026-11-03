# Beacon

Beacon is an alpha full-stack Gleam framework for building MVU web apps on the
BEAM. It is not published on Hex (the name `beacon` there belongs to another
package) and will be renamed `brazier` before its first release; see
[CHANGELOG.md](CHANGELOG.md).

How a page works:

- The server renders the first page (SSR).
- The browser loads a generated client bundle and connects over a WebSocket,
  one BEAM process per session.
- The server is authoritative: `update` runs there, and the synced `Model`
  reaches the browser as JSON state updates.
- An optional Local layer handles per-tab state such as dropdowns and form
  drafts in the browser, without a server round trip.
- With `beacon.full_application`, server state that `sync` does not return
  stays on the BEAM and is never sent to the browser.

## Minimal App

```gleam
import beacon
import beacon/element.{type Element}
import beacon/event
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

fn init(_ctx: beacon.Context) -> Result(Model, beacon.InitError) {
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
  let assert Ok(Nil) =
    beacon.simple(init:, update:, view:)
    |> beacon.start(8080)
    as "beacon.start failed (it logs the error)"
}
```

An app needs two generated artifacts before it starts: the server codec
(`src/beacon_codec.gleam`) and the client bundle (`priv/static/`). Generate
them with `gleam run -m beacon/build`, then `gleam run`; or use
`gleam run -m beacon/dev`, which builds, runs and rebuilds on change.
`beacon.start` logs and returns an error when either artifact is missing,
and `main` crashes on it, so `gleam run` exits with status 1 and says what to
run. The examples do not track their generated files, so build one before its
first run. To run the counter example from this repository:

```sh
cd examples/counter
gleam run -m beacon/build   # first, and after every change
gleam run
```

[Getting Started](docs/GETTING_STARTED.md) walks through a full app.

## Recommended APIs

- Pick one constructor: `beacon.simple` (a pure `update` that also runs in the
  browser), `beacon.application` (server `update` with effects) or
  `beacon.full_application` (private server state, `sync` and a Local layer).
- `beacon.with_router(parse:, on_change:)` routes by URL; see
  [Routing](docs/ROUTING.md).
- `beacon/api.routes`, `api.json_value`, `api.read_text` and `api.read_form`
  for API routes.
- `beacon/auth.session_routes`, `auth.protect_ws` (or `auth.allow_guests_ws`)
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
gleam run -m beacon/lint     # 0 violations
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
