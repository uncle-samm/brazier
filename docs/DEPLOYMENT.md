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
| `PORT` | `8080` | Server listen port, `0..65535` (`0` binds an ephemeral port). A set value that is not an integer in range is an error. |
| `SECRET_KEY` | none (required) | Token signing key, at least 32 bytes |
| `BEACON_ENV` | `development` | Set to `production` for prod |
| `BEACON_SHUTDOWN_TIMEOUT` | the configured `drain_timeout_ms` (5000) | Milliseconds the listener waits for open connections when it stops, `0..4294967295`. Read when the application starts; a set value that is not an integer in range refuses the start. |

`config.port()` and `config.secret_key()` return `Result(_, BeaconError)`:
a malformed `PORT` or a missing or weak `SECRET_KEY` is a startup error, not
a silent default.

## Secret Key

Join tokens and session tokens are signed with HMAC-SHA256, so the key must
be at least 32 bytes (`config.min_secret_key_bytes`). `application.start`,
`start_advanced` and `start_supervised` refuse an empty key, a shorter key,
and the old published dev secret with a `ConfigError` before opening the
port. Generate a key with:

```bash
openssl rand -base64 48
```

`beacon.app` uses a random per-process key when none is set; it changes on
restart (invalidating all tokens) and differs between nodes, so always set an
explicit key in production:

```gleam
pub fn main() {
  let assert Ok(secret) = config.secret_key() as "SECRET_KEY must be set"
  let assert Ok(port) = config.port() as "PORT must be a valid port"
  beacon.app(init, beacon.no_local, beacon.no_server, update, view)
  |> beacon.secret_key(secret)
  |> beacon.start(port)
}
```

## Security Limits

Start from the defaults and override what you need; the limits are
validated at startup and an invalid value refuses to start. The full list is
in [SECURITY.md](SECURITY.md#securitylimits).

```gleam
beacon.security_limits(transport.SecurityLimits(
  ..transport.default_security_limits(),
  max_connections: 20_000,
  max_events_per_second: 100,
  // Behind a reverse proxy: believe its X-Forwarded-For / Forwarded headers.
  trusted_proxies: ["10.0.0.0/8"],
))
```

Behind a reverse proxy, every client shares the proxy's address. Trusted
proxies are exempt from `max_connections_per_ip`; raise
`max_ws_connections_per_ip` or enforce per-client caps at the proxy.

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

## Graceful Shutdown

`application.wait_forever` (what `main` calls after `beacon.start`) turns
SIGTERM, which `docker stop`, Kubernetes and systemd send, into a drain:

1. The acceptors stop, so no new connection is accepted.
2. Every open connection is told to finish. A WebSocket is closed with
   **1001** `server shutting down` (the browser reconnects with backoff to
   the next instance). An HTTP request in progress completes and its
   response carries `Connection: close`. An idle keep-alive connection is
   closed.
3. Connections still open after the drain timeout are killed, with one
   error log naming how many.
4. The rest of the tree stops, `wait_forever` returns, and `main` returns.

The drain timeout is `SecurityLimits.drain_timeout_ms` (default 5000), or
`BEACON_SHUTDOWN_TIMEOUT` when set. Keep it below the orchestrator's grace
period: `docker stop` sends SIGKILL after 10 seconds, and Kubernetes after
`terminationGracePeriodSeconds` (30 by default).

While `wait_forever` waits, Beacon's handler replaces OTP's on the
`erl_signal_server` event manager, and puts OTP's back once nothing waits.
A second SIGTERM that arrives after the first has been taken goes to OTP's
handler, which runs `init:stop()`. Only apps started by the process that
calls `wait_forever` are drained. SIGUSR1 and SIGQUIT still halt the node.

## Logging & Connections

Set `BEACON_ENV=production` to suppress debug output. When `max_connections` is reached, new connections get HTTP 503. Origin headers validated to prevent cross-site hijacking.
