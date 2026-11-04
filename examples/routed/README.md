# Routed

Explicit routing with `brazier.with_router`.

## Features

- One `Route` type and one `parse` function over `router.segments` are the
  only route declaration: `/` (counter), `/about` (static), `/settings`
  (form) and `/stats` (route changes seen). Any other path is a 404.
- Brazier runs `update(model, RouteChanged(route))` after `init`, before the
  first render, and on every client navigation, so the route lives in the
  Model. Nav links and the back and forward buttons change the page
  without a reload.
- The home page is a nested component with its own Model, Msg, update and
  view; the root maps its messages with `element.map(Home)`.
- The other pages are plain view modules, imported explicitly. Brazier does
  not scan the filesystem for routes.
- `brazier.application`: `update` runs on the server, so the home page's
  "Server-authoritative updates" counts the events the server handled.

## Run

```bash
cd examples/routed
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run -m main
```

Open http://localhost:8080 and move between /, /about, /settings and
/stats.
