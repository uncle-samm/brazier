# Telemetry

`beacon/telemetry` is a thin layer over the Erlang
[`telemetry`](https://hexdocs.pm/telemetry) library (1.4), the event bus used
by Phoenix, Ecto and most of the BEAM ecosystem. Beacon emits named events
with measurements and metadata. You attach handlers to the events you care
about and forward them to logs, metrics or traces.

Because the events go through `telemetry` itself, Erlang and Elixir
reporters such as `telemetry_metrics` and `opentelemetry_telemetry` see them
too.

## Attaching a handler

```gleam
import beacon/telemetry
import gleam/int
import gleam/io

pub fn log_slow_requests() {
  let assert Ok(Nil) =
    telemetry.attach(
      "slow-request-logger",
      [["beacon", "http", "request", "stop"]],
      fn(event) {
        let assert Ok(duration) = telemetry.int(event, "duration")
        let assert Ok(route) = telemetry.string(event, "route")
        case duration > 100_000_000 {
          True -> io.println("slow request on " <> route <> ": " <> int.to_string(duration))
          False -> Nil
        }
      },
    )
}
```

- `attach(id, events, handler)` attaches one handler to one or more event
  names. Ids are 1 to 255 bytes (`Error(InvalidHandlerId(_))` otherwise),
  and an id already in use returns `Error(AlreadyAttached(id))`. Attaching
  creates the atoms for the event names, which are bounded by your code.
- `detach(id)` removes it, or returns `Error(NotAttached(id))`.
- A handler receives `Event(name, measurements, metadata)`. Keys are
  strings, and values keep the type they were emitted with. `int(event, key)`
  and `string(event, key)` read a measurement or a metadata value.
- `start()` starts the `telemetry` application and is idempotent. Beacon's
  subsystems call it themselves.

## Handlers run in the emitting process

`telemetry` calls handlers synchronously, in the process that emitted the
event: a WebSocket runtime, a PubSub worker, a presence shard. A slow
handler slows that process down. Do expensive work (network calls, large
aggregations) in a separate process that the handler sends a message to.

## Crashing handlers

When a handler crashes, `telemetry` detaches it and emits
`[telemetry, handler, failure]`. Beacon logs that event at error level with
the handler id, the event, and the kind, reason and stacktrace. The process
that emitted the event is never affected. Reattach the handler after fixing
it; nothing reattaches it automatically.

## Cost when nothing is attached

Beacon's own events are emitted from Erlang functions with literal atoms,
so emitting never creates atoms. With no handler attached, an emit is one
`persistent_term` read plus one ETS lookup inside `telemetry:execute/3`.
The test suite measures this on every run: 40 to 65 ns per emit on a
laptop, depending on load.

## Emitting your own events

```gleam
let assert Ok(Nil) =
  telemetry.execute(
    ["my_app", "checkout", "completed"],
    dict.from_list([#("items", 3)]),
    dict.from_list([#("plan", "pro")]),
  )

let order =
  telemetry.span(["my_app", "checkout"], dict.new(), fn() { place_order() })
```

- `execute(name, measurements, metadata)` takes string keys, integer
  measurements and string metadata. It never creates atoms: when no handler
  has ever been attached to `name`, there is nothing to deliver and it
  returns `Ok(Nil)` without emitting.
- `span(name, metadata, run)` follows `telemetry:span/3`. It emits
  `name ++ ["start"]` before `run`, and `name ++ ["stop"]` with `duration`
  (native time units) after it. If `run` crashes it emits
  `name ++ ["exception"]` with `kind`, `reason` and `stacktrace`, then
  re-raises the crash unchanged. With no handler on `name`, it just runs
  `run`. An invalid span name is a programming error and crashes.
- Every name segment is 1 to 255 bytes, and a name has at least one
  segment. `execute` returns `Error(InvalidEventName(_))` for anything
  else.

## Privacy

Metadata never carries session ids, tokens, cookies, event payloads,
models, query strings or remote IP addresses. The catalogue emitters have
fixed keys, so call sites cannot add fields. Two rules apply to the values
the HTTP, WebSocket and runtime call sites pass in:

- `route` is the matched pattern (`/users/:id`), never the raw path.
- `event` is reported only for handlers the application registered.
  Anything else is `"unknown"`, so a client cannot fill the metrics with
  names of its choosing.

## Event catalogue

All of Beacon's events start with `beacon`, the `telemetry.prefix`
constant. `telemetry.catalogue()` returns every name. A span (S) is three
events: `start`, `stop` and `exception`. Each carries the standard span
measurements: `system_time` and `monotonic_time` on start, `duration` and
`monotonic_time` on stop and exception.

| Event | Measurements | Metadata | Emitted |
|---|---|---|---|
| `[beacon, http, request]` S | `req_body_bytes`, `resp_body_bytes` (stop) | `method`, `route`, `connection_id`; `status` (stop) | not yet |
| `[beacon, http, connection, accepted \| rejected \| closed]` | `count`, `duration` | `reason` | not yet |
| `[beacon, ws, upgrade]` S | none | `route`; `result` (stop) | not yet |
| `[beacon, ws, close]` | `duration`, `frames_in`, `frames_out`, `bytes_in`, `bytes_out` | `close_code`, `reason` | not yet |
| `[beacon, ws, rate_limited]`, `[beacon, ws, backpressure]` | `queue_len` | `connection_id` | not yet |
| `[beacon, runtime, mount \| handle_event \| navigate]` S | none | `route`, `event`, `connection_id` | not yet |
| `[beacon, runtime, render]` S | `patch_bytes` (stop) | `route`, `event`, `connection_id` | not yet |
| `[beacon, runtime, stop]` | `uptime` | `reason` | not yet |
| `[beacon, effect, run]` S | none | `kind` | not yet |
| `[beacon, effect, timer, rejected]` | none | `limit` | not yet |
| `[beacon, store, write]` | `count` | `store`, `op`, `mode` | yes |
| `[beacon, store, sync]` S | `entries`, `bytes` (stop) | `store`, `peer` | not yet (replicated stores) |
| `[beacon, session, created \| revoked \| expired \| contention]` | `count` | `reason` | not yet |
| `[beacon, pubsub, broadcast]` | `local_subscribers`, `remote_nodes` | `scope`: `cluster`, `local` or `direct` | yes |
| `[beacon, pubsub, forward, overloaded]` | `queue_len` | `shard` | yes, at most once per second per worker |
| `[beacon, cluster, node, up \| down]` | `count` | `node`, `reason` | yes |
| `[beacon, cluster, peer, rejected]` | `count` | `node`, `reason` | yes |
| `[beacon, cluster, connect, failed]` | `count` | `node`, `reason` | yes |
| `[beacon, presence, track \| untrack \| limit_exceeded]` | `count` | `tracker`, `shard` | yes |
| `[beacon, presence, replica, up \| down \| permdown]` | none | `replica`, `tracker` | yes |
| `[beacon, presence, transfer]` S | `entries`, `bytes` (stop) | `tracker`, `peer` | yes |

"Not yet" events are defined, have their emitters and are tested, but the
subsystem does not call them yet. They are wired in with the runtime and
transport instrumentation.

Notes on individual events:

- `[beacon, pubsub, broadcast]`: for `scope: "cluster"`, `remote_nodes` is
  the number of remote nodes forwarded to, one message each, however many
  subscribers they have. `local_broadcast` reports `remote_nodes` 0, and a
  `direct_broadcast` to another node reports 0 local subscribers and 1
  remote node.
- `[beacon, presence, untrack]`: `count` is the number of entries removed,
  so a process that exits with five entries emits one event with count 5.
- `[beacon, presence, limit_exceeded]` fires for every refused track or
  update (meta too large, a per-process or per-shard limit), and for every
  rejected transfer. See [CLUSTERING.md](CLUSTERING.md#limits).
- `[beacon, presence, replica, *]`: `replica` is the peer node's name.
- `[beacon, cluster, peer, rejected]`: `reason` says whether the peer's key
  differed, its protocol version differed, or it did not answer in time.
- `[beacon, cluster, connect, failed]`: for a failed DNS lookup, `node` is
  the DNS query and `reason` starts with `dns: `.

Third-party libraries emit their own events, for example
`[postgleam, pool, checkout]`. Attach to them the same way.
