# Design: Clustering, Presence and Telemetry (Milestone 117, WS8)

Status: accepted design, being implemented. It adapts Phoenix.PubSub (pg adapter),
Phoenix.Tracker/Presence, `:telemetry`, Erlang `pg` and OTP TLS distribution.
Nothing here is an invented pattern.

## 1. Current state (before WS8)

- **PubSub** uses the `pg` scope `beacon_pg`.
  - `broadcast` sends one message per subscriber on every node, so 10k subscribers on a node means 10k cross-node messages.
  - The scope is started with no supervisor.
  - Topics are not validated, and join/leave results are ignored.
  - Every broadcast is logged at debug level.
- **Stores** are node-local ETS tables owned by an unsupervised `spawn_monitor` + `register` process.
  - **Bug:** change notifications go cluster-wide, so remote nodes re-read their own stale or empty table.
- **Sessions** are node-local ETS tables with `monotonic_time` timestamps, which cannot be compared across nodes.
  - Revocation uses `pg:get_local_members`.
  - **Security bug:** a logout on node A leaves sockets on node B authenticated until `recheck_auth` runs.
- **Presence** does not exist. `examples/chat` fakes it with `store.append`, and that store grows without bound.
- **Telemetry** does not exist. The `telemetry` entries in `examples/*/manifest.toml` are stale leftovers from mist.
- **Docs** claim multi-node support. No test uses more than one node.

## 2. Shared foundation: root supervision tree

`beacon/supervisor.gleam` uses `static_supervisor` with `RestForOne`, and starts these children in order:

1. `telemetry` application started (the result is checked).
2. Pubsub (local registry + cross-node workers).
3. ETS owner (replaces the unsupervised owner).
4. Cluster manager (only when clustering is configured).
5. Presence trackers.
6. Session sweepers.
7. Transport (WS1's acceptor pool).

**Infrastructure death:** runtimes monitor the pubsub registry and the presence shards they use.
On `DOWN`, the runtime stops with a logged reason (`PubSubDown` / `PresenceDown`).
The client then reconnects and rehydrates. There is no hidden re-subscribe path.

## 3. Clustering

### Discovery

A supervised `beacon_cluster` process supports three modes:

- `Static(nodes)`, retried with backoff of 1s doubling to 30s, with jitter.
- `Dns(query, basename, poll_ms)`, which resolves A/AAAA records and takes an injectable resolver for tests.
- `NoDiscovery`.

There is no gossip or multicast: both are unauthenticated UDP.
The process uses `net_kernel:monitor_nodes(true, [nodedown_reason])` and emits telemetry and logs on node up/down.

### Distributed pubsub (port of the Phoenix.PubSub pg adapter)

- **Local registry:** a node-local ETS `duplicate_bag` of `{Topic, Pid}`, partitioned by `phash2(pid)`.
  - Each partition process monitors its subscribers.
  - Subscriptions are not stored in pg.
- **Cross-node workers:** `pool_size` workers per node (default 1) join the pg group `{beacon_pubsub, Shard}` in the supervised scope `beacon_pubsub_pg`.
- **Delivery:**
  - `broadcast` delivers locally, then sends ONE `{forward_to_local, Topic, Msg}` to each remote worker.
  - `local_broadcast` never leaves the node.
  - `direct_broadcast(node, ...)` targets one node.
- **Limits:**
  - Topics must be 1–255 bytes.
  - A worker queue above `max_forward_queue` (default 10k) is logged at error level and emits `[beacon, pubsub, forward, overloaded]`, rate-limited to once per second.
  - Messages are never silently dropped.
- **Trust:** connected nodes can already run arbitrary code, so forwarded messages are not authenticated. This is documented in SECURITY.md.

### Store consistency modes

| Mode | Behaviour | Cost |
|---|---|---|
| `Local` (default) | Node-local ETS. Notifications use `local_broadcast`, which fixes the bug above. | Each node has its own data. |
| `Replicated(sync_interval_ms, max_entries, max_value_bytes)` | Delta-CRDT AWLWWMap per node, ported from `delta_crdt_ex`. Writes are tagged with an HLC + node id. Deltas go over the store topic, with a full sync on `nodeup` and every interval. ListStore becomes a set of unique entries; `delete_all` removes only the entries that node has observed. | Eventually consistent. Concurrent writes to the same key resolve by highest (HLC, node), and the other write is lost. Reads can be stale during a partition. No cross-node read-your-writes. Bounded size. |
| Strong consistency | Not offered. Use Postgres via postgleam. | — |

### Sessions across nodes

- **Cluster-wide revocation:**
  - Revocation uses `pg:get_members` and sends `SessionRevoked` to every node.
  - On `nodeup`, every bound socket is re-checked immediately.
  - Timestamps use `erlang:system_time(millisecond)`, with a documented ±5s skew tolerance.
- **`SessionBackend` interface:**
  - `LocalEts` is the default. It needs a sticky load balancer, and Beacon logs a startup warning if it is used while clustered.
  - `External(ExternalBackend)` is a record of functions (create/fetch/touch/delete/rotate), e.g. backed by Postgres.
  - There is no replicated in-memory session store.
- **Peer secret check on `nodeup`:**
  - Nodes exchange `hmac_sha256(secret_key, "beacon-cluster-v1")` plus a protocol version.
  - On a mismatch: error log, `[beacon, cluster, peer, rejected]`, then `erlang:disconnect_node`.

### Node down / netsplit behaviour

| Event | PubSub | Replicated store | Sessions | Presence |
|---|---|---|---|---|
| Node down | pg drops its workers | Data kept; resyncs when the node returns | Sockets on it reconnect elsewhere | Leaves after `down_period`; deleted after `permdown_period` |
| Netsplit | Each side delivers to itself | Both sides accept writes; LWW merge on heal | Revocation is delayed until recheck or `nodeup` | Leaves on both sides; joins come back on heal |
| Beacon component crash | Partition restarts; its subscribers stop, and their clients reconnect | Rebuilt from peers | Sweeper restarts | Shard restarts with a new version; peers treat the old one as gone |

### Distribution security

- Beacon never enables distribution itself.
- In prod (`BEACON_ENV=prod`) the cluster manager refuses to start unless:
  - `proto_dist` is `inet_tls`/`inet6_tls`, and
  - the cookie is at least 32 bytes.
  - Otherwise it returns `Error(InsecureDistribution(reason))`.
  - The only override is `cluster.allow_insecure_distribution(reason)`, which logs a warning on every boot.
- The docs cover:
  - `-proto_dist inet_tls -ssl_dist_optfile` with `verify_peer` and `fail_if_no_peer_cert`, a private CA, and certificates matching the host;
  - a cookie file with mode 0400, never `-setcookie`;
  - epmd (4369) and a fixed `inet_dist_listen_min/max` range open on the private network only;
  - `net_kernel:allow/1` is only meaningful together with TLS;
  - anyone holding the cookie or a dist certificate can run arbitrary code.
- Test certificates live in `test/fixtures/dist_tls/`, with a script to regenerate them.

## 4. Presence (`beacon/presence`, port of Phoenix.Tracker + Phoenix.Presence)

- **Shards:** each tracker has `pool_size` shards. Each shard owns its Tracker.State:
  - a delta-CRDT observed-remove set with a causal context, using `{replica, clock}` tags;
  - a protected `ordered_set` ETS table of `{{topic,pid,key}, meta, tag}` and a `duplicate_bag` of pids, so reads skip the shard process;
  - no tombstones: a remove is inferred from the context.
- **Replication protocol:**
  - Heartbeats go on `beacon_presence:<name>:<shard>`, with initial jitter of up to 25%.
  - A heartbeat carries a delta, or is an empty keepalive.
  - A clock mismatch triggers a transfer request and a full transfer.
  - `max_delta_sizes` is `[100, 1000, 10000]`.
  - Peers move to down after `down_period` and to permdown after `permdown_period`.
  - Restarts are detected through version numbers, and a graceful shutdown is announced as permdown.
- **Periods:**
  - Defaults are `broadcast_period` 1500ms, `max_silent_periods` 10, `down_period` 30s and `permdown_period` 20min.
  - All are configurable, and tests run at about 50ms.
  - Validation: `down_period >= 2 × broadcast_period`, and `permdown_period > down_period`.
- **Monitoring:** the shard monitors every tracked pid; `DOWN` removes all of that pid's entries and emits leaves. Tracked processes monitor their shard.
- **Meta:**
  - A bounded JSON string, at most `max_meta_bytes` (default 1024).
  - Each meta gets a `ref` of 8 random bytes in base64url; `update` keeps the old one as `ref_prev`.
- **Limits:** every violation returns `Error`, never a silent drop:
  - `max_topics_per_pid` (100);
  - `max_entries_per_shard` (1,000,000);
  - topics of 1–255 bytes;
  - an incoming transfer above `max_transfer_entries` is rejected and logged, then re-requested as a smaller delta.
- **Diffs to apps:**
  - The shard `local_broadcast`s `PresenceDiff(topic, joins, leaves)` on `presence:<name>:<topic>` from an ordered dispatcher.
  - The runtime maps it to an app message through a registered callback, coalescing up to 100 queued diffs for the same topic.
  - The browser gets an ordinary DOM patch, so the wire protocol does not change.

## 5. Telemetry (`beacon/telemetry` over Erlang `telemetry` 1.4.x)

- **Handlers:**
  - All handlers attach through one trampoline, `fun beacon_telemetry_ffi:dispatch/4`, with the Gleam closure stored in the handler config.
  - The `Event` value is converted only when a handler is attached.
- **Crashing handlers:** `:telemetry` detaches the handler and emits `[telemetry, handler, failure]`. Beacon logs that event at error level (handler id, event, kind, reason, stacktrace). The emitting process is never affected.
- **Zero cost when unused:**
  - Events are emitted from FFI functions with literal atoms, so no runtime atom creation.
  - With no handlers, an emit costs one ETS lookup.
  - Benchmark gate: less than 2% throughput regression with no handlers.
- **Spans:** use `telemetry:span/3` and its standard measurements (`system_time`, `monotonic_time`, `duration`; `kind`/`reason`/`stacktrace` on exception).
- **Privacy:**
  - Metadata never includes session ids, tokens, cookies, event payloads, models, query strings or remote IPs.
  - Event names are emitted only for known handlers; anything else is `"unknown"`.
  - Routes are the matched pattern, not the raw path.
- **Prefix:** one constant `[beacon, ...]`, so the `brazier` rename is a one-line change.

### Event catalogue (S = span: start/stop/exception)

| Event | Measurements | Metadata |
|---|---|---|
| `[beacon, http, request]` S | `req_body_bytes`, `resp_body_bytes` (stop) | `method`, `route`, `status`, `connection_id` |
| `[beacon, http, connection, accepted\|rejected\|closed]` | `count`, `duration` | `reason` |
| `[beacon, ws, upgrade]` S | — | `route`, `result` |
| `[beacon, ws, close]` | `duration`, `frames_in`, `frames_out`, `bytes_in`, `bytes_out` | `close_code`, `reason` |
| `[beacon, ws, rate_limited]`, `[beacon, ws, backpressure]` | `queue_len` | `connection_id` |
| `[beacon, runtime, mount\|handle_event\|navigate\|render]` S | `patch_bytes` (render stop) | `route`, `event`, `connection_id` |
| `[beacon, runtime, stop]` | `uptime` | `reason` |
| `[beacon, effect, run]` S | — | `kind` |
| `[beacon, effect, timer, rejected]` | — | `limit` |
| `[beacon, store, write]` | `count` | `store`, `op`, `mode` |
| `[beacon, store, sync]` S | `entries`, `bytes` | `store`, `peer` |
| `[beacon, session, created\|revoked\|expired\|contention]` | `count` | `reason` |
| `[beacon, pubsub, broadcast]` | `local_subscribers`, `remote_nodes` | `scope` |
| `[beacon, pubsub, forward, overloaded]` | `queue_len` | `shard` |
| `[beacon, cluster, node, up\|down]`, `[beacon, cluster, peer, rejected]`, `[beacon, cluster, connect, failed]` | `count` | `node`, `reason` |
| `[beacon, presence, track\|untrack\|limit_exceeded]` | `count` | `tracker`, `shard` |
| `[beacon, presence, replica, up\|down\|permdown]` | — | `replica`, `tracker` |
| `[beacon, presence, transfer]` S | `entries`, `bytes` | `tracker`, `peer` |
| `[postgleam, pool, checkout]` S (emitted by postgleam) | `queue_time`, `pool_size`, `idle` | `pool`, `result` |

## 6. Public API sketch

Builder names follow WS7's final API.

```gleam
// beacon/telemetry
pub type Event { Event(name: List(String), measurements: Dict(String, Dynamic), metadata: Dict(String, Dynamic)) }
pub type TelemetryError { AlreadyAttached(id: String) NotAttached(id: String) InvalidEventName(String) }
pub fn attach(id: String, events: List(List(String)), handler: fn(Event) -> Nil) -> Result(Nil, TelemetryError)
pub fn detach(id: String) -> Result(Nil, TelemetryError)
pub fn execute(name: List(String), measurements: Dict(String, Int), metadata: Dict(String, String)) -> Result(Nil, TelemetryError)
pub fn span(name: List(String), metadata: Dict(String, String), run: fn() -> a) -> a
pub fn int(event: Event, key: String) -> Result(Int, Nil)
pub fn string(event: Event, key: String) -> Result(String, Nil)

// beacon/pubsub
pub type PubSubError { InvalidTopic(String) NotStarted }
pub fn subscribe(topic: String) -> Result(Nil, PubSubError)
pub fn unsubscribe(topic: String) -> Result(Nil, PubSubError)
pub fn broadcast(topic: String, message: a) -> Result(Nil, PubSubError)
pub fn local_broadcast(topic: String, message: a) -> Result(Nil, PubSubError)
pub fn direct_broadcast(node: node.Node, topic: String, message: a) -> Result(Nil, PubSubError)
pub fn local_subscriber_count(topic: String) -> Int

// beacon/cluster
pub type Discovery { Static(nodes: List(String)) Dns(query: String, basename: String, poll_ms: Int) NoDiscovery }
pub type ClusterError { InsecureDistribution(reason: String) DistributionNotStarted InvalidConfig(String) }
pub fn new(discovery: Discovery) -> ClusterConfig
pub fn connect_backoff(c: ClusterConfig, initial_ms: Int, max_ms: Int) -> ClusterConfig
pub fn allow_insecure_distribution(c: ClusterConfig, reason: String) -> ClusterConfig
pub fn dns_resolver(c: ClusterConfig, resolve: fn(String) -> Result(List(String), String)) -> ClusterConfig
pub fn members() -> List(node.Node)

// beacon/store
pub type Mode { Local Replicated(sync_interval_ms: Int, max_entries: Int, max_value_bytes: Int) }
pub fn new(name: String, mode: Mode) -> Result(Store(v), StoreError)
pub fn new_list(name: String, mode: Mode) -> Result(ListStore(v), StoreError)

// beacon/session
pub type SessionBackend(s) { LocalEts(name: String) External(ExternalBackend(s)) }
pub type ExternalBackend(s) { ExternalBackend(create: fn(s) -> Result(String, SessionError), fetch: fn(String) -> Result(s, SessionError), touch: fn(String) -> Result(Nil, SessionError), delete: fn(String) -> Result(Nil, SessionError), rotate: fn(String, s) -> Result(String, SessionError)) }

// beacon/presence
pub type Entry(meta) { Entry(key: String, metas: List(Meta(meta))) }
pub type Meta(meta) { Meta(value: meta, ref: String, ref_prev: Option(String), node: String) }
pub type Diff(meta) { Diff(topic: String, joins: List(Entry(meta)), leaves: List(Entry(meta))) }
pub type PresenceError { MetaTooLarge(bytes: Int) PresenceLimitExceeded(limit: String) InvalidTopic(String) NotTracked TrackerDown }
pub fn new(name: String, encode: fn(meta) -> json.Json, decoder: decode.Decoder(meta)) -> PresenceConfig(meta)
pub fn track(p: Presence(meta), topic: String, key: String, meta: meta) -> Result(String, PresenceError)
pub fn update(p: Presence(meta), topic: String, key: String, meta: meta) -> Result(String, PresenceError)
pub fn untrack(p: Presence(meta), topic: String, key: String) -> Result(Nil, PresenceError)
pub fn list(p: Presence(meta), topic: String) -> List(Entry(meta))
pub fn get_by_key(p: Presence(meta), topic: String, key: String) -> Result(Entry(meta), Nil)
```

## 7. Multi-node test strategy

**Peer harness** (`test/beacon/cluster/peer.gleam` + FFI):

- Nodes start with `peer:start_link` over `standard_io`, so the test runner itself stays non-distributed.
- `rpc`, plus `eventually(check, timeout_ms)` (polls every 10ms) instead of sleeps.
- `partition` sets a bad cookie on both sides and disconnects; `heal` restores the cookies and reconnects.
- `crash` halts a node; `stop` is a graceful shutdown.
- Periods are short (50ms heartbeat, 300ms down), and peers are always stopped in cleanup.

**Test matrix:**

- **PubSub:**
  - Cross-node delivery, with exactly one forward per node.
  - `local_broadcast` stays on its node.
  - Subscriber death cleans up.
  - A down node does not crash broadcast.
  - Netsplit isolation.
  - Overload event.
  - Topic validation.
  - Partition kill stops subscribers.
- **Store:**
  - Local notifications do not leak to other nodes (regression).
  - Replicated stores converge.
  - Concurrent-put LWW gives the same winner everywhere.
  - Partition/heal convergence.
  - `delete_all` semantics.
  - Limits.
  - A restarted node catches up.
- **Session:**
  - Logout on A closes a socket on B with 4401 (regression).
  - Revocation during a partition is enforced on heal.
  - External backend works from both nodes.
  - Startup warning when clustered with LocalEts.
  - Clock-skew tolerance.
- **Presence:**
  - Ported Phoenix tracker state tests.
  - Cross-node track and leave on pid death.
  - Node crash → down → permdown.
  - Netsplit and heal.
  - Shard restart via version.
  - Graceful shutdown.
  - Limits.
  - Coalescing and ordering.
- **Telemetry:**
  - Every catalogue event fires with the documented keys.
  - A crashing handler is detached and logged, and the emitter survives.
  - Detach.
  - Span exception re-raises.
  - Privacy scan of all metadata.
- **Cluster:**
  - Static retry.
  - DNS with a fake resolver.
  - Prod refuses insecure distribution, and the override warns.
  - Secret mismatch disconnects.
  - TLS distribution: a node without a certificate is refused, one with a valid certificate connects.
- **Performance:**
  - Pubsub fan-out: 3 nodes × 10k subscribers.
  - Presence: 10k tracks across 3 nodes (convergence time, memory per entry, transfer size).
  - Telemetry overhead gate.
  - 10-minute churn soak with flat memory.

## 8. Implementation order

1. Telemetry core.
2. Root supervision tree.
3. PubSub rewrite, plus switching store notifications to `local_broadcast`.
4. Peer harness and multi-node pubsub tests.
5. Cluster manager, plus deployment and security docs.
6. Session safety (cluster-wide revocation, `SessionBackend`).
7. Presence CRDT state as a pure module.
8. Presence shards and API.
9. Runtime integration (`on_presence`, coalescing, infrastructure-death stops), and rewriting chat presence.
10. Instrument everything with the event catalogue.
11. Replicated store mode.
12. Docs (`docs/CLUSTERING.md`, `docs/TELEMETRY.md`, correcting false claims) and benchmarks.

## 9. Decisions

The user confirmed D2 on 2026-11-02 (Replicated store mode ships last). The other decisions follow the recommendations.

- **D1:** use Erlang `telemetry`.
- **D2:** fix Local stores now, and ship Replicated (eventually consistent, LWW) as the last step. No strong consistency.
- **D3:** cluster-wide revocation is mandatory. LocalEts stays the default (sticky load balancer, startup warning when clustered); External is recommended for production. No replicated in-memory sessions.
- **D4:** prod refuses insecure distribution unless explicitly overridden with a reason.
- **D5:** Static and DNS discovery only.
- **D6:** presence meta is bounded JSON.
- **D7:** when infrastructure dies, runtimes stop and clients reconnect.
- **D8:** privacy-preserving telemetry metadata by default.
- **D9:** WebSocket telemetry is a summary at close, not per frame.
- **D10:** postgleam emits its own pool events.
