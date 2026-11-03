# Middleware Demo

Route-scoped HTTP middleware around a `beacon.simple` counter.

## Features

- Secure headers are on by default for every app. The middleware added with
  `beacon.with_middleware` runs after them, in the order it is added.
- `middleware.group([...])` adds a request id to every response and logs
  each request. The logger is wrapped in `middleware.except("/healthz", ...)`
  so health probes stay out of the log.
- `middleware.at("/healthz", ...)` answers `{"status":"ok"}` on that exact
  path without reaching the app.
- `middleware.only("/admin", ...)` answers 403 unless the request carries
  `x-admin: true`, and logs each refusal.
- `middleware.only("/api", ...)` adds `x-api-version: v1`, and
  `middleware.methods([Post, Put], ...)` answers 405 to writes under `/api`.

## Run

```bash
cd examples/middleware_demo
gleam run -m beacon/build   # after changing the source
gleam run -m app
```

Open http://localhost:8080 for the counter, and http://localhost:8080/healthz
for the health check. `/admin` answers 403 from a browser, which sends no
`x-admin` header.
