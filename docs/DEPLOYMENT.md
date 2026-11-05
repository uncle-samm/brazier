# Deployment

## Build Step (Required)

Run the Brazier build from the app project's root before compiling or
deploying:

```bash
gleam run -m brazier/build                        # find the app module in src/
gleam run -m brazier/build -- src/my_app.gleam    # or name it
```

It finds the app module (the one that calls `brazier.start`, including through
`import brazier as b` or unqualified imports; text in comments and strings does
not count), generates the server codec `src/brazier_codec.gleam`, runs
`gleam build`, and writes the client bundle
`priv/static/brazier_client_<hash>.js` with `priv/static/brazier_client.manifest`
naming it. It needs `node` and `npx` (esbuild is pinned and fetched by `npx`).

The build exits with status 1 on any failure: no app module or more than one,
an unparsable source file (the error names the file, line and column), a Model
or Msg field type the codec cannot encode (the error names the type and the
field), a codec that does not compile, or a failed client bundle. A failed
step leaves no half-written artifact behind.

Production never builds. `brazier.start` refuses to start when the manifest or
the bundle it names is missing, so run the build in your image or release
pipeline, not at startup. Automatic rebuilding exists only in dev mode
(`gleam run -m brazier/dev`).

The server reads the manifest once, when it starts, and every page and every
join uses the bundle it named then; no request reads it again. Rebuilding
the bundle under a running server therefore changes nothing until the server
restarts, which is what a release does. Under `brazier/dev` each successful
rebuild loads the new manifest.

## Environment Variables

`brazier.start` takes its port and secret key as arguments and options, not
from the environment. An app that wants them from the environment reads them
itself with `brazier/config` (see the example below). Brazier reads these
variables:

| Variable | Read by | Default | Meaning |
|----------|---------|---------|---------|
| `PORT` | `config.port()`, when the app calls it | `8080` | Listen port, `0..65535` (`0` binds an ephemeral port). A set value that is not an integer in range is an `Error`. |
| `SECRET_KEY` | `config.secret_key()`, when the app calls it | none | Token signing key, at least 32 bytes. Unset, empty, short or the old published dev secret is an `Error`. |
| `BRAZIER_ENV` | `config.is_production()`, which the listener calls when it starts and `brazier/cluster` calls when the app joins a cluster | not production | `production` or `prod` makes the listener refuse to start with an empty `allowed_hosts` (see [Allowed Hosts](#allowed-hosts)) and the cluster refuse insecure distribution (see [CLUSTERING.md](CLUSTERING.md)). It does not change logging or anything else. |
| `BRAZIER_SHUTDOWN_TIMEOUT` | `brazier.start`, when it starts the application | `SecurityLimits.drain_timeout_ms` (5000) | Milliseconds the listener waits for open connections when it stops (see [Graceful Shutdown](#graceful-shutdown)), `0..4294967295`. A set value that is not an integer in range refuses the start with a `ConfigError`. |

The `BRAZIER_*` variables had another prefix before the package was renamed
(see the [changelog](../CHANGELOG.md)). One still set under its old name is
never read: `brazier.start` and `cluster.start` refuse with an error that
names the variable to set instead.

`config.get_env`, `config.get_env_or` and `config.get_env_int` read any other
variable the app needs; `get_env_int` returns an `Error` for a set value that
is not an integer.

## Secret Key

The key signs WebSocket join tokens with HMAC-SHA256 and, in a cluster, the
peer check between nodes. Session ids and CSRF tokens are random values kept
in the session store, not signed. The key must be at least 32 bytes
(`config.min_secret_key_bytes`). `brazier.start` refuses
an empty key, a shorter key and the old published dev secret with a
`ConfigError` before opening the port. Generate a key with:

```bash
openssl rand -base64 48
```

The key is required in every environment, including development. Without
`brazier.secret_key`, `brazier.start` logs and returns a `ConfigError` that
names `brazier.secret_key` and `SECRET_KEY`. Brazier never generates a key:
a generated key would change on every restart, invalidating every token, and
would differ between nodes. It is the one secret an app configures. The
cluster peer check derives its MAC from it with a purpose label
(`HMAC-SHA256(secret_key, "brazier-cluster-v1")`), so the MAC is never a
token signature. Every node of one deployment needs the same key (see
[CLUSTERING.md](CLUSTERING.md#the-peer-check)). Read it from the environment:

<!-- docs-check: wrap
{{block}}

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

pub fn view(_model: Model) -> element.Element(Msg) {
  element.text("count")
}
-->
```gleam
import brazier
import brazier/config
import brazier/element
import brazier/error.{type BrazierError}
import gleam/result

pub fn main() -> Nil {
  // brazier.start blocks while the server runs. It returns Ok(Nil) once a
  // SIGTERM drain has stopped the app, and an Error when it cannot start.
  let assert Ok(Nil) = start() as "Brazier did not start"
  Nil
}

fn start() -> Result(Nil, BrazierError) {
  use secret <- result.try(config.secret_key())
  use port <- result.try(config.port())
  brazier.simple(init:, update:, view:)
  |> brazier.secret_key(secret)
  |> brazier.start(port)
}
```

A failed `let assert` crashes `main` with the error, so the process exits
loudly instead of returning as if it had stopped normally.

## Security Limits

Start from the defaults and override what you need; the limits are
validated at startup and an invalid value refuses to start. The full list is
in [SECURITY.md](SECURITY.md#securitylimits).

<!-- docs-check: wrap
import brazier
import brazier/ip
import brazier/transport

pub fn configure(
  app: brazier.App(state, model, local, msg),
) -> brazier.App(state, model, local, msg) {
  app
  |>
  {{block}}
}
-->
```gleam
brazier.security_limits(transport.SecurityLimits(
  ..transport.default_security_limits(),
  max_connections: 20_000,
  max_events_per_second: 100,
  // The reverse proxy's address, and the one header it sets to name the
  // client.
  trusted_proxies: ["10.0.0.0/8"],
  forwarding_header: ip.XForwardedFor,
  // Pages served from another origin that may open the WebSocket.
  ws_allowed_origins: ["https://www.example.com"],
  // The names this server answers to (required in production).
  allowed_hosts: ["example.com", ".example.com"],
))
```

## Allowed Hosts

`SecurityLimits.allowed_hosts` names the hosts the server answers to, as
Django's `ALLOWED_HOSTS` does. A request or WebSocket upgrade whose `Host`
header names another host gets 400. This stops DNS rebinding: a page on an
attacker's domain whose name is rebound to your server's address would
otherwise be same-origin with itself and pass the WebSocket Origin check.

- `"example.com"` is that host, `".example.com"` the domain and every
  subdomain, and `"*"` every host (no protection; logged as a warning).
  Ports are not compared. The rules are in
  [SECURITY.md](SECURITY.md#allowed-hosts).
- With `BRAZIER_ENV=production` an empty list refuses to start, and the
  error names `SecurityLimits.allowed_hosts`. In development an empty list
  answers only `localhost` names, `127.0.0.1` and `[::1]`.
- **Health checks and probes** send a `Host` too. A load balancer or
  Kubernetes probe that requests `http://10.1.2.3:8080/health` sends
  `Host: 10.1.2.3:8080`, which gets 400 unless that address is listed. Set
  the probe's `Host` header to a listed name (Kubernetes `httpHeaders`,
  `curl -H 'Host: example.com'`), or list the address the probe uses.

## Behind a Reverse Proxy

Brazier does not terminate TLS. Behind a TLS-terminating proxy (nginx, a load
balancer), list the proxy in `trusted_proxies`; without it, Brazier sees every
client as the proxy's address and ignores the forwarding headers. The rules
are in [SECURITY.md](SECURITY.md#trusted-proxies); for deployment:

- **`forwarding_header`**: set it to the header your proxy writes the client
  address into: `ip.XForwardedFor` (nginx `proxy_add_x_forwarded_for`, most
  load balancers) or `ip.Forwarded` (RFC 7239). Only that header is read; the
  other is ignored with a warning, because the proxy passes it through from
  the client. The default `ip.NoForwardingHeader` reads neither, so the client
  address is the proxy's. Setting a header without `trusted_proxies` refuses
  to start.
- **WebSocket upgrades** must reach Brazier: forward `Upgrade` and
  `Connection`. Brazier pings every `ws_ping_interval_ms` (30 s), so a proxy
  idle timeout longer than that keeps quiet sockets open.
- **`Host`**: pass the client's `Host` header through unchanged. It must be
  in `allowed_hosts` (see [Allowed Hosts](#allowed-hosts)), and the
  WebSocket Origin check compares the browser's `Origin` with the request's
  scheme, `Host` and port; Brazier does not read `X-Forwarded-Host`.
- **Scheme**: the proxy must tell Brazier that a client used `https`, in the
  header `forwarding_header` names and no other: with `ip.Forwarded`, the
  `proto=` of the element it appends for the client (nginx
  `proxy_set_header Forwarded "for=$remote_addr;proto=$scheme"`); with
  `ip.XForwardedFor`, `X-Forwarded-Proto` (nginx
  `proxy_set_header X-Forwarded-Proto $scheme`, which overwrites any value
  the client sent; the left-most value is read). The other header is ignored
  with a warning, and with `ip.NoForwardingHeader` the scheme is always
  `http`. Brazier reads the scheme only from a trusted proxy. Without one the
  request's scheme is `http`, and a browser on `https://` fails the Origin
  check with 403. A scheme other than `http` or `https`, several
  `X-Forwarded-Proto` headers, or several `proto=` in one `Forwarded` element
  reject the request.
- **`ws_allowed_origins`**: add an origin here only when pages served from a
  different origin open the socket. The request's own origin is always
  allowed. Entries are bare `scheme://host[:port]` origins; an entry with a
  path, or one that does not parse, refuses to start.
- **Per-IP caps**:
  - `max_connections_per_ip` (HTTP, 256) counts socket peers when they are
    accepted, before any header is read. A trusted proxy is exempt, so behind
    one it limits nothing; enforce per-client HTTP limits at the proxy or with
    `middleware.rate_limit_behind_proxies`.
  - `max_ws_connections_per_ip` (100) counts the resolved client address, so
    behind a trusted proxy it applies to each real client.
  - Behind a proxy that is not listed, every client shares the proxy's
    address and both caps apply to all clients together.
- **Rate limiting**: `middleware.rate_limit` keys on the socket peer; behind a
  proxy use `middleware.rate_limit_behind_proxies(limiter, trusted)` with the
  same list (`transport.trusted_proxies(limits)`, called once when the
  pipeline is built; the listener parses its own copy once at start). See
  [MIDDLEWARE.md](MIDDLEWARE.md).
- **HSTS**: add `middleware.hsts(...)` once the site is served over HTTPS
  (see [SECURITY.md](SECURITY.md#secure-headers)).

## Health Check

Brazier answers `/health` with HTTP 200 and the body `{"status":"ok"}`. It is
a liveness check: it shows the HTTP listener accepts and answers requests,
not that sessions, stores or the cluster work. It runs after the middleware
pipeline and the app's API routes, so an API route for `/health` replaces it,
and a middleware that refuses the request (authentication, rate limiting)
refuses it too. Like every request, it must name a host in `allowed_hosts`,
or it gets 400 (see [Allowed Hosts](#allowed-hosts)). Add your own API route
when the check must cover more.

## Docker

The repository's `Dockerfile` builds one of the examples and doubles as a
template for your own app:

```bash
docker build -t brazier-counter .
docker build --build-arg EXAMPLE=todo --build-arg APP_MODULE=todo -t brazier-todo .
docker run --rm -p 8080:8080 brazier-counter
```

`EXAMPLE` is the directory under `examples/` and `APP_MODULE` is the module
whose `main/0` starts the app (the build logs it as the app module). The
builder stage (`ghcr.io/gleam-lang/gleam:v1.19.2-erlang-alpine` plus Node)
runs `gleam run -m brazier/build` and `gleam export erlang-shipment`; any
failure fails the image build. The runtime stage (`erlang:28-alpine`, the same
OTP release) copies the shipment and `priv/`, runs as a non-root user, and
starts `APP_MODULE:main()` through a small start script. The script exits with
status 1 when `main` returns an error or crashes. It does not use the
shipment's `entrypoint.sh`, which calls `<package>@@main:run` and so only works
when the package and the app module share a name.

For your own app, copy your project instead of the repository and drop the
`examples/` prefix. The image's `HEALTHCHECK` requests `/`, which renders the
app's first page; `/health` (above) is the cheaper check. It requests
`http://127.0.0.1:8080/`, so once your app sets `allowed_hosts`, list
`"127.0.0.1"` in it as well, or give `wget` a listed name with
`--header 'Host: example.com'`. A rebound page sends its own name as
`Host`, never `127.0.0.1`, so listing the loopback address keeps the
protection.

## Graceful Shutdown

`application.wait_forever`, which `brazier.start` calls once the application
is up, turns SIGTERM (what `docker stop`, Kubernetes and systemd send) into a
drain:

1. The acceptors stop and the listen socket is closed, so no new connection
   is accepted and the port is free for the next instance at once.
2. Every open connection is told to finish. A WebSocket is closed with
   **1001** `server shutting down` (the browser reconnects with backoff to
   the next instance). An HTTP request in progress completes and its
   response carries `Connection: close`. An idle keep-alive connection is
   closed.
3. Connections still open after the drain timeout are killed, with one
   error log naming how many.
4. The rest of the tree stops, `wait_forever` returns, and so does
   `brazier.start`.

The drain timeout is `SecurityLimits.drain_timeout_ms` (default 5000), or
`BRAZIER_SHUTDOWN_TIMEOUT` when set. Keep it below the orchestrator's grace
period: `docker stop` sends SIGKILL after 10 seconds, and Kubernetes after
`terminationGracePeriodSeconds` (30 by default).

While `wait_forever` waits and drains, Brazier's handler replaces OTP's on
the `erl_signal_server` event manager, and puts OTP's back once nothing
waits. Every application running on the node is drained, whichever process
started it. A second SIGTERM during the drain is logged as a warning and
ignored, so it cannot cut the drain short; SIGQUIT, SIGUSR1 and SIGKILL
still stop the node at once. When several processes
call `wait_forever`, they drain one after the other and none returns before
the drain is over.

A page that reconnects to an instance running a different build (a new
release, or a rolling deploy that sends it to an old instance) is refused
with **4499** `stale build` when it joins, and reloads to fetch the bundle
that instance serves. The join carries the page's build id, the hash in its
`brazier_client_<hash>.js` URL; the server compares it with the manifest it
read when it started. (Before this release the code was 4409, which an
`init` refusing with 409 also uses; a proxy or alert that matched 4409 for
stale builds must now match 4499.)
The reload goes through the client's reload guard (at most 3 per tab within
60 s), so a rolling deploy that keeps sending a tab between builds ends in an
error page rather than a reload loop: route a client to one build at a time
(session affinity, or drain the old instances before new ones take traffic).

Calling `application.stop` on an application that is not running (stopped
already, or its tree died) returns an error that says so and logs one
warning.

## Logging and Connections

`brazier.start` configures the Erlang logger at `info` level: debug messages
are not printed, whatever `BRAZIER_ENV` says. When `max_connections` is
reached, a new connection gets 503 before its request is read. WebSocket limits,
Origin rules and close codes are in [SECURITY.md](SECURITY.md#websocket-limits).
