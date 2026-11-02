# Clustering

Beacon nodes form a cluster with ordinary Erlang distribution. Once nodes
are connected:

- PubSub broadcasts reach subscribers on every node.
- Presence shows who is on a topic, cluster-wide.
- Session logouts and rotations close live connections on every node.
- The cluster manager discovers peers, reconnects them, and checks that
  they belong to the same deployment.

Stores remain per node (see [Stores](#stores)).

The design and its references (Phoenix.PubSub, Phoenix.Tracker, libcluster,
Plug.Session, OTP distribution) are in
[design/CLUSTER_PRESENCE_TELEMETRY.md](design/CLUSTER_PRESENCE_TELEMETRY.md).
The telemetry events mentioned below are listed in
[TELEMETRY.md](TELEMETRY.md).

## Security first: what distribution means

**A node that can connect to your cluster can run any code on every node.**
Erlang distribution has no permission model. Anyone who holds the cookie,
or a certificate your CA signed, owns the cluster. Treat the cookie and the
node keys like the database root password.

Beacon does not turn distribution on for you, and in production it refuses
to start the cluster manager over an unsafe setup.

### 1. Give the node a name

```sh
ERL_FLAGS="-name app@10.0.1.12" gleam run
```

Use `-name` with a host or address that peers can reach. `-sname` only
works for nodes that share a host.

### 2. Encrypt and authenticate with TLS

Run distribution over mutual TLS, with certificates from a private CA that
signs nothing else:

```sh
ERL_FLAGS="-name app@node1.internal -proto_dist inet_tls -ssl_dist_optfile /etc/app/ssl_dist.conf"
```

`/etc/app/ssl_dist.conf`:

```erlang
[{server, [{certfile, "/etc/app/node.pem"},
           {keyfile, "/etc/app/node.key"},
           {cacertfile, "/etc/app/ca.pem"},
           {verify, verify_peer},
           {fail_if_no_peer_cert, true}]},
 {client, [{certfile, "/etc/app/node.pem"},
           {keyfile, "/etc/app/node.key"},
           {cacertfile, "/etc/app/ca.pem"},
           {verify, verify_peer}]}].
```

- `verify_peer` together with `fail_if_no_peer_cert` makes both sides prove
  who they are. A node without a certificate, or with one from another CA,
  is refused during the handshake. `test/beacon/cluster/tls_dist_test.gleam`
  checks both cases.
- Each node's certificate must name its host (`subjectAltName`) as it
  appears in the node name (`node1.internal` above), and server name
  checking must stay on. The test fixtures in `test/fixtures/dist_tls/`
  turn it off because the test peers run on any host. Never copy that
  option, or those keys, into production.
- Keep the key files readable only by the user the node runs as.

### 3. Keep the cookie secret

TLS authenticates nodes. The cookie is still checked after the handshake.

- Put it in `~/.erlang.cookie` of the user the node runs as, with mode
  `0400`.
- Never pass it with `-setcookie`, which shows it to anyone who can list
  processes.
- Make it at least 32 random bytes (`cluster.min_cookie_bytes`), for
  example `openssl rand -base64 48`.

### 4. Restrict the network

- epmd listens on TCP 4369. Distribution itself uses a random port unless
  you fix the range:

  ```sh
  -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9105
  ```

- Open 4369 and that range only between cluster nodes, on the private
  network. Never expose them to the internet or to the load balancer.
- `net_kernel:allow/1` limits which node names may connect. Node names are
  claimed by the connecting side, so this only means something with TLS,
  where the certificate backs the name.

### 5. What Beacon refuses

With `BEACON_ENV=prod`, `cluster.start` and `cluster.supervised` return
`Error(InsecureDistribution(reason))` in two cases:

- distribution is not `inet_tls` or `inet6_tls`;
- the cookie is shorter than 32 bytes.

The reason lists every problem found. Outside production, both are allowed
and logged at info level.

To run a production node over an insecure setup on purpose, say why:

```gleam
cluster.new(discovery, secret_key: secret)
|> cluster.allow_insecure_distribution("single-host demo, loopback only")
```

The node then starts and logs a warning naming each problem and your
reason. If distribution is not started at all, the result is
`Error(DistributionNotStarted)`.

## The cluster manager

```gleam
import beacon/cluster

let config =
  cluster.new(
    cluster.Dns(query: "app.internal", basename: "app", poll_ms: 5000),
    secret_key: secret_key,
  )
let assert Ok(child) = cluster.supervised(config)
```

Use `cluster.start(config)` instead to run it unsupervised, and
`cluster.stop()` to stop it. Stopping keeps existing connections up, but
they are no longer reconnected or checked.

### Discovery

Discovery follows libcluster's Epmd and DNSPoll strategies.

| Discovery | Behaviour |
|---|---|
| `Static(["app@node1.internal", ...])` | Connects to each node. Failed and lost connections are retried with backoff. This node may be in the list. |
| `Dns(query, basename, poll_ms)` | Every `poll_ms`, resolves A and AAAA records for `query` and connects to `basename@<address>` for each new address. |
| `NoDiscovery` | Connects to nothing. It reports and checks nodes that connect by other means. |

Settings:

- **Backoff.** `connect_backoff(initial_ms, max_ms)` sets the retry delay
  for static connections. The default starts at 1s and doubles to 30s. Each
  delay is taken at random from the upper half of the current window, so
  restarted nodes do not retry in lockstep.
- **DNS.** `dns_timeout` bounds each lookup (default 10s). `max_dns_nodes`
  bounds the nodes taken from one answer (default 256). `dns_resolver`
  replaces the system resolver, which is useful in tests.
- **Nodes that leave the DNS answer stay connected.** They disconnect only
  when distribution reports them down. A DNS blip therefore never splits
  the cluster.
- **Failure telemetry.** Every failed connection or lookup is logged and
  emits `[beacon, cluster, connect, failed]`.
- **Membership telemetry.** `[beacon, cluster, node, up | down]` reports
  membership.

### The peer check

When a node connects, both sides exchange
`HMAC-SHA256(secret_key, "beacon-cluster-v1")` and a protocol version.

- If the key or the version differs, the peer is disconnected.
- If the peer sends nothing within `peer_check_timeout` (default 5s), it is
  disconnected.
- Each rejection is logged at error level and emits
  `[beacon, cluster, peer, rejected]`.
- `cluster.members()` returns the connected peers that passed the check.

The check catches misconfiguration, for example staging and production
sharing a cookie, or two releases with incompatible protocols. **It is not
a security boundary:** a node that holds the cookie can already run code
before the check finishes. TLS and the network rules above are the
boundary.

## PubSub across nodes

`beacon/pubsub` is a port of Phoenix.PubSub with its pg adapter.

- **Delivery.** `broadcast` delivers to local subscribers, then sends one
  message per remote node. The receiving node's forwarding worker delivers
  it locally.
- **Scope.** `local_broadcast` reaches this node only. `direct_broadcast`
  reaches one named node, or returns `Error(NodeNotConnected(_))`.
- **`pool_size` must be the same on every node.** A message is forwarded to
  the worker of the same index on each node.
- **Forwarded messages are not authenticated.** Connected nodes trust each
  other completely (see above). Do not connect nodes you do not trust.
- **Overload is reported, never hidden.** A forwarding worker whose queue
  passes `max_forward_queue` (default 10,000) logs an error and emits
  `[beacon, pubsub, forward, overloaded]` at most once per second. It
  never drops messages.
- **Topics.** Each topic is 1 to 255 bytes. A subscriber may hold at most
  `max_topics_per_subscriber` topics (default 1,000).
- **Node down and netsplits.** A broadcast during a netsplit reaches only
  the nodes that are still connected. It is not queued for later.
  Subscribers that need what they missed must re-read state when nodes
  reconnect, which is what presence does.

Start PubSub before presence and before anything that subscribes:
`pubsub.supervised(pubsub.default_config())`.

## Stores

`beacon/store` tables are per node. A write changes this node's table and
notifies watchers on this node only (`local_broadcast`). Two nodes behind a
load balancer therefore show different store contents. For shared state
across nodes, use your database, or presence for "who is here". Replicated
stores are designed in the design document but not built yet.

## Sessions

A session store has one of two backends.

- **`LocalEts(name)`.** Sessions live in an ETS table on one node.
  - A cluster needs a sticky load balancer, so each client returns to the
    node that holds its session.
  - A warning is logged when a LocalEts store starts on a distributed node.
- **`External(ExternalBackend)`.** You supply the functions (create, fetch,
  touch, compare-and-swap replace, delete, delete_version, expired, count)
  over storage that every node shares, such as Postgres.
  - Every node must use the same backend `name`.
  - A storage error is logged and returned as `SessionBackendFailed`. The
    session is never treated as valid.

```gleam
let assert Ok(store) =
  session.start_store(session.External(postgres_backend), session.default_store_config())
```

Across the cluster:

- **Revocation is cluster-wide.** Deleting, rotating or expiring a session
  sends `{beacon_session_revoked, Id, Reason}` to every process bound to it
  (`bind_current_process`) on every connected node.
- **Netsplits.** A revocation cannot cross a netsplit. When a node
  connects, every store re-checks the sessions its local processes are
  bound to, and revokes those that are gone.
- **Clocks.** Lifetimes use `erlang:system_time(millisecond)` so nodes can
  compare timestamps. Clocks may differ by up to `clock_skew_tolerance_ms`
  (5,000), so a lifetime can end up to 5s early or late. A timestamp
  further in the future than that means a broken clock: the session is
  treated as expired and an error is logged. Run NTP on every node.

## Presence

`beacon/presence` is a port of Phoenix.Tracker and Phoenix.Presence. It
tracks which processes are on a topic, on every connected node.

```gleam
import beacon/presence

let config = presence.new("users", encode_user_meta, user_meta_decoder)
let assert Ok(child) = presence.supervised(config)
let assert Ok(users) = presence.handle(config)

// In the process to track (for example a connection's runtime):
let assert Ok(_ref) = presence.track(users, "room:42", user_id, UserMeta(status: "online"))
let assert Ok(Nil) = presence.subscribe(users, "room:42")
let assert Ok(entries) = presence.list(users, "room:42")
```

- `track`, `update`, `untrack` and `untrack_all` act on the calling
  process. The tracker monitors it and removes its entries when it exits.
- `list` and `get_by_key` read an ETS table and never wait on the tracker.
- `presence.start(config)` runs a tracker without a supervisor, and
  `presence.stop` stops it. With `supervised`, get the handle from
  `presence.handle(config)`; until the tracker runs, calls return
  `Error(TrackerDown)`.

### Every node must agree

Start the tracker on every node with the same:

- name;
- `pool_size`;
- `broadcast_period`, `max_silent_periods`, `down_period` and
  `permdown_period`.

Start it after PubSub. Shards replicate only with the shard of the same
name and index on other nodes, so a node with a different pool size sees
some topics on the wrong shard.

### Timing

Shards send a heartbeat every `broadcast_period` (default 1.5s) carrying
the changes since the last one. An idle shard still sends an empty
heartbeat every `broadcast_period × (max_silent_periods + 1)`, which is
16.5s by default.

**`down_period` must be longer than that keepalive interval**, or idle
peers would be marked down and up again over and over. `validate_config`
rejects configs that break this rule. The default `down_period` is 30s.

`permdown_period` (default 20 minutes) must be longer than `down_period`.

### Diffs

Every change is delivered as a diff to processes subscribed to the topic,
both on the node where it happened and on each node that learns about it.

- Subscribers receive `{beacon_pubsub, presence.diff_topic(users, topic), Diff}`.
  Pass the Diff to `presence.decode_diff(users, diff)` to get
  `Diff(topic, joins, leaves)`.
- An update appears as a leave of the old meta and a join of the new one,
  with the old `ref` as the new meta's `ref_prev` (Phoenix.Presence
  semantics).
- Changes from a remote node arrive together, one diff per heartbeat.

### Limits

Every limit violation is an `Error`, is logged, and emits
`[beacon, presence, limit_exceeded]`. Nothing is dropped silently.

| Limit | Default | Error |
|---|---|---|
| `max_meta_bytes` (encoded JSON) | 1,024 | `MetaTooLarge(bytes)` |
| `max_topics_per_pid` (entries per process, per shard) | 100 | `PresenceLimitExceeded("max_topics_per_pid")` |
| `max_entries_per_shard` (local and remote entries) | 1,000,000 | `PresenceLimitExceeded("max_entries_per_shard")` |
| `max_transfer_entries` | 1,000,000 | The transfer is rejected and requested again at the next clock sample. |

Further constraints:

- Tracker names are 1 to 32 bytes of `a-z`, `0-9` and `_`.
- Keys are at most 255 bytes.
- A topic may be at most `presence.max_topic_bytes(users)` bytes. This is
  the PubSub limit minus the diff topic prefix.
- A meta that your decoder cannot read back is refused with
  `MetaDecodeFailed`.

### Failures

| Situation | What happens |
|---|---|
| A tracked process exits | Its entries leave on every node. |
| A node crashes or is unreachable | After `down_period` without a heartbeat, peers mark it `Down` (`[beacon, presence, replica, down]`) and its entries leave. After `permdown_period` its data is dropped (`replica, permdown`). |
| A netsplit | Each side marks the other down after `down_period` and sees only its own entries. When the split heals, the sides exchange state and converge, including changes made during the split. |
| A node comes back before `permdown_period` | Its entries rejoin from its heartbeats or a transfer (`replica, up`). |
| A tracker stops normally | It tells its peers, which drop its entries at once instead of waiting for `down_period`. |
| A shard crashes and restarts | The new shard has a new version, and peers drop the old version's entries at once. Tracked processes must track again. They can monitor `presence.shard_pid(users, topic)` to find out. |
| A new node joins | It asks a peer for a transfer of the current state (`[beacon, presence, transfer]`). |

`presence.replicas(users, topic)` returns the peers a shard knows, with
`Up` or `Down`. `test/beacon/cluster/presence_cluster_test.gleam` runs
each row of this table on real peer nodes.

## Testing clusters

`test/beacon/cluster/peer.gleam` starts real peer nodes with OTP's `peer`
module. It can:

- connect peers into a mesh;
- crash and stop nodes;
- partition and heal links.

Peers stop when the test ends, whether it passes or fails. The tests wait
on conditions with a deadline (`peer.eventually`), never with sleeps.
