# Deployment

## Build Step (Required)

Compile client JavaScript before deploying:

```bash
gleam run -m beacon/build
```

This generates `priv/static/beacon_client_<hash>.js` and `beacon_client.manifest`.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | Server listen port, `0..65535` (`0` binds an ephemeral port). A set value that is not an integer in range is an error. |
| `SECRET_KEY` | none (required) | Token signing key, at least 32 bytes |
| `BEACON_ENV` | `development` | Set to `production` for prod |

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

```dockerfile
FROM ghcr.io/gleam-lang/gleam:v1.9-erlang-27 AS build
WORKDIR /app
COPY . .
RUN gleam deps download && gleam run -m beacon/build && gleam export erlang-shipment

FROM erlang:27-slim
WORKDIR /app
COPY --from=build /app/build/erlang-shipment .
ENV PORT=8080 BEACON_ENV=production
EXPOSE 8080
CMD ["./entrypoint.sh", "run"]
```

## Logging & Connections

Set `BEACON_ENV=production` to suppress debug output. When `max_connections` is reached, new connections get HTTP 503. Origin headers validated to prevent cross-site hijacking.
