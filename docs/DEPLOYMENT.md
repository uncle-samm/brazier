# Deployment

## Build Step (Required)

Run the Beacon build from the app project's root before compiling or
deploying:

```bash
gleam run -m beacon/build                        # find the app module in src/
gleam run -m beacon/build -- src/my_app.gleam    # or name it
```

It finds the app module (the one that calls `beacon.app`/`beacon.start`,
including through `import beacon as b` or unqualified imports; text in
comments and strings does not count), generates the
server codec `src/beacon_codec.gleam`, runs `gleam build`, and writes the
client bundle `priv/static/beacon_client_<hash>.js` with
`priv/static/beacon_client.manifest` naming it. It needs `node` and `npx`
(esbuild is pinned and fetched by `npx`).

The build exits with status 1 on any failure: no app module or more than one,
an unparsable source file (the error names the file, line and column), a Model
or Msg field type the codec cannot encode (the error names the type and the
field), a codec that does not compile, or a failed client bundle. A failed
step leaves no half-written artifact behind.

Production never builds. `beacon.start` refuses to start when the manifest or
the bundle it names is missing, so run the build in your image or release
pipeline, not at startup. Automatic rebuilding exists only in dev mode
(`gleam run -m beacon/dev`).

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | Server listen port |
| `SECRET_KEY` | auto-generated | Session token signing key |
| `BEACON_ENV` | `development` | Set to `production` for prod |

## Secret Key

Always set an explicit key in production. The auto-generated key changes on restart, invalidating all tokens:

```gleam
beacon.app(init, beacon.no_local, beacon.no_server, update, view)
|> beacon.secret_key(config.secret_key())
|> beacon.start(config.port())
```

## Security Limits

```gleam
beacon.security_limits(transport.SecurityLimits(
  max_message_bytes: 65_536, max_events_per_second: 100, max_connections: 20_000,
))
```

## Health Check

`GET /health` returns `{"status":"ok"}` with HTTP 200.

## Docker

The repository's `Dockerfile` builds one of the examples and doubles as a
template for your own app:

```bash
docker build -t beacon-counter .
docker build --build-arg EXAMPLE=todo --build-arg APP_MODULE=todo -t beacon-todo .
docker run --rm -p 8080:8080 beacon-counter
```

`EXAMPLE` is the directory under `examples/` and `APP_MODULE` is the module
whose `main/0` starts the app (the build logs it as the app module). The
builder stage (`ghcr.io/gleam-lang/gleam:v1.19.2-erlang-alpine` plus Node)
runs `gleam run -m beacon/build` and `gleam export erlang-shipment`; any
failure fails the image build. The runtime stage (`erlang:28-alpine`, the same
OTP release) copies the shipment and `priv/`, runs as a non-root user, and
starts `APP_MODULE:main()` through a small start script. The script exits with
status 1 when `main` returns an error or crashes. It does not use the
shipment's `entrypoint.sh`, which calls `<package>@@main:run` and so only works
when the package and the app module share a name.

For your own app, copy your project instead of the repository and drop the
`examples/` prefix. The image's health check requests `/`, because Beacon has
no built-in health route.

## Logging & Connections

Set `BEACON_ENV=production` to suppress debug output. When `max_connections` is reached, new connections get HTTP 503. Origin headers validated to prevent cross-site hijacking.
