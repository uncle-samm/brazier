# Clustering

Brazier nodes form a cluster with ordinary Erlang distribution. Once nodes
are connected:

- PubSub broadcasts reach subscribers on every node.
- Presence shows who is on a topic, cluster-wide.
- Session logouts and rotations close live connections on every node.
- Replicated stores keep a converging copy on every node.
- The cluster manager discovers peers, reconnects them, and checks that
  they belong to the same deployment.

Stores are per node unless opened in replicated mode (see [Stores](#stores)).

The design and its references (Phoenix.PubSub, Phoenix.Tracker, libcluster,
Plug.Session, OTP distribution) are in
[design/CLUSTER_PRESENCE_TELEMETRY.md](design/CLUSTER_PRESENCE_TELEMETRY.md).
The telemetry events mentioned below are listed in
[TELEMETRY.md](TELEMETRY.md).

## The supervision tree

`brazier.start` runs the application under one root supervisor with the
`RestForOne` strategy (Phoenix's application structure). Its children start
in this order:

1. PubSub, configured with `brazier.pubsub_config`.
2. The cluster manager, when `brazier.cluster(config)` is set.
3. The session revocation scope, which carries logouts and rotations to
   bound sockets on every node.
4. The presence tracker, when `brazier.presence(..)` or
   `brazier.watch_presence(..)` is set.
5. The HTTP and WebSocket listener.

<!-- docs-check: wrap
import brazier
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/presence
import brazier/presence/sync
import brazier/cluster

pub fn main(
  discovery: cluster.Discovery,
  secret_key: String,
  online: presence.PresenceConfig(String),
) {
  {{block}}
}

pub type Model {
  Model(room: String, user: String, status: String)
}

pub type Msg {
  PresenceChanged(sync.Diff(String))
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(room: "1", user: "ada", status: "online"), effect.none()))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    PresenceChanged(_) -> #(model, effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  element.text(model.user)
}

fn track(model: Model) -> List(presence.Tracking(String)) {
  [presence.Tracking(topic: "room:" <> model.room, key: model.user, meta: model.status)]
}
-->
```gleam
brazier.application(init:, update:, view:)
|> brazier.secret_key(secret_key)
|> brazier.cluster(cluster.new(discovery))
|> brazier.presence(tracker: online, track: track, on_presence: PresenceChanged)
|> brazier.start(8080)
```

- **A crash restarts that child and every child after it.** A PubSub
  restart therefore also restarts the cluster manager, the session scope,
  the tracker and the listener, closing every connection; a listener
  restart touches nothing before it. A single presence shard that crashes
  is restarted by the tracker's own supervisor instead.
- **Past the restart tolerance the root gives up.** It exits, and
  `brazier.start` crashes the main process with the reason instead of
  running on without PubSub or the listener. Run the release under a
  process manager that restarts it.
- **The tree owns these processes.** `brazier.start` refuses to start, with
  a `ConfigError` and an error log, when PubSub, the cluster manager, the
  session scope or the tracker is already running outside a tree.
- **`application.stop` stops the whole tree** and frees the port.
  `application.start` is the unsupervised form for embedding and tests: it
  starts PubSub, the session scope and the tracker on the node if needed
  and links only the listener to the caller.

## Security first: what distribution means

**A node that can connect to your cluster can run any code on every node.**
Erlang distribution has no permission model. Anyone who holds the cookie,
or a certificate your CA signed, owns the cluster. Treat the cookie and the
node keys like the database root password.

Brazier does not turn distribution on for you, and in production it refuses
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
  is refused during the handshake. `test/brazier/cluster/tls_dist_test.gleam`
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

### 5. What Brazier refuses

With `BRAZIER_ENV=prod`, `cluster.start` and `cluster.supervised` return
`Error(InsecureDistribution(reason))` in these cases:

- distribution is not `inet_tls` or `inet6_tls`;
- the cookie is shorter than 32 bytes;
- TLS distribution does not verify peers. The server options must hold
  `{verify, verify_peer}` and `{fail_if_no_peer_cert, true}`, and the
  client options `{verify, verify_peer}`. They are read from the
  `-ssl_dist_optfile` file or the `-ssl_dist_opt` flags. TLS without them
  encrypts traffic to any node, including one without the cluster's
  certificate. An options file that cannot be read is a problem too.

The reason lists every problem found and the option that fixes each one.
Outside production, they are all allowed and logged at info level.

To run a production node over an insecure setup on purpose, say why:

<!-- docs-check: wrap
import brazier/cluster

pub fn config(discovery: cluster.Discovery) -> cluster.ClusterConfig {
  {{block}}
}
-->
```gleam
cluster.new(discovery)
|> cluster.allow_insecure_distribution("single-host demo, loopback only")
```

The node then starts and logs a warning naming each problem and your
reason. If distribution is not started at all, the result is
`Error(DistributionNotStarted)`.

## The cluster manager

<!-- docs-check: wrap
import brazier/effect.{type Effect}
import brazier/element.{type Element}

{{block}}

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(count: 0), effect.none()))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Increment -> #(Model(count: model.count + 1), effect.none())
  }
}

fn view(_model: Model) -> Element(Msg) {
  element.text("counter")
}
-->
```gleam
import brazier
import brazier/cluster

pub fn start(secret_key: String) {
  let config =
    cluster.new(cluster.Dns(query: "app.internal", basename: "app", poll_ms: 5000))

  brazier.application(init:, update:, view:)
  |> brazier.secret_key(secret_key)
  |> brazier.cluster(config)
  |> brazier.start(8080)
}
```

`brazier.cluster` runs the manager in the application's supervision tree,
right after PubSub. The manager uses the app's own `brazier.secret_key`; there
is no separate cluster secret. `brazier.start` fails when the configuration,
the key or this node's distribution does not pass the checks above. Outside
a Brazier app, `cluster.supervised(config, secret_key:)` builds a child for
your own supervisor, and `cluster.start(config, secret_key:)` runs it
unsupervised. Both refuse a key that `config.secret_key` would refuse.
`cluster.stop()` stops the manager. Stopping keeps existing connections up,
but they are no longer reconnected or checked, and no remote node is a member
any more (see [Membership](#membership)).

### Discovery

Discovery follows libcluster's Epmd and DNSPoll strategies.

| Discovery | Behaviour |
|---|---|
| `Static(["app@node1.internal", ...])` | Connects to each node. Failed and lost connections are retried with backoff. This node may be in the list. |
| `Dns(query, basename, poll_ms)` | Every `poll_ms`, resolves A and AAAA records for `query` and connects to `basename@<address>` for each new address. |
| `NoDiscovery` | Connects to nothing and never reconnects. It reports and checks nodes that connect by other means. |

Settings:

- **Backoff.** `connect_backoff(initial_ms, max_ms)` sets the retry delay
  for static connections. The default starts at 1s and doubles to 30s. Each
  delay is taken at random from the upper half of the current window, so
  restarted nodes do not retry in lockstep.
- **DNS.** `dns_timeout` bounds each lookup (default 10s). `max_dns_nodes`
  bounds the nodes taken from one answer (default 256). `dns_resolver`
  replaces the system resolver, which is useful in tests.
- **Only IP addresses become node names.** A node name is an atom, and
  atoms are never freed. Answer entries that are not well-formed IPv4 or
  IPv6 addresses are dropped before any atom is made. The drop is logged at
  error level and emits `[brazier, cluster, connect, failed]`. Each
  address is used in its canonical text, so one address is one name. The
  `basename` is at most 190 bytes, so every name fits the 255-byte limit.
- **Discovered names are capped for the VM's life.** `max_discovered_nodes`
  (default 16,384) bounds how many new node names DNS discovery ever makes
  on one VM. The count survives manager restarts. Past the cap a new
  address is not connected to: it is logged at error level and emits
  `[brazier, cluster, connect, failed]`. Addresses that already have a name
  still connect. `max_dns_nodes` bounds one answer, and
  `max_discovered_nodes` bounds the total across every answer.
- **Nodes that leave the DNS answer stay connected.** They disconnect only
  when distribution reports them down. A DNS blip therefore never splits
  the cluster.
- **Failure telemetry.** Every failed connection or lookup is logged and
  emits `[brazier, cluster, connect, failed]`.
- **Membership telemetry.** `[brazier, cluster, node, up | down]` reports
  membership.

### Netsplits

A netsplit ends only when something connects the two sides again. Which
discovery does that:

| Discovery | After the network heals |
|---|---|
| `Static` | The lost node is retried with backoff (`connect_backoff`) until it connects. |
| `Dns` | Each poll connects every answered address that is not connected. The next poll after the heal joins the sides. |
| `NoDiscovery` | Nothing reconnects. The sides stay apart until your own code, or a new connection from outside, joins them. |

`NoDiscovery` owns no connections, by design. libcluster's Epmd strategy is
the same: it connects once, and reconnects only when its `timeout` option is
set. Use `NoDiscovery` when something else forms the cluster, such as a
release that runs `net_kernel:connect_node/1` itself, or a test. If nothing
else does, use `Static` or `Dns`.

OTP's `global` can also cut connections during a netsplit. Under the
kernel default `prevent_overlapping_partitions=true`, when node `a` loses
`b` but `c` still reaches both, `global` on `a` tells `c`, and `c` drops
its connection to `b`. Every part is then fully connected: `a` and `c` on
one side, `b` on the other (see
[Why a rejected peer is not disconnected](#why-a-rejected-peer-is-not-disconnected)
for the mechanism). Members that the network never separated can
therefore go down. Brazier keeps the OTP default:

- Brazier registers no `global` names, and takes `global` locks on its own
  node only. Your application or a library may use them. With the setting off, `global` cannot keep its names consistent
  across a partial partition (the OTP `global` docs).
- The nodes it drops are only disconnected, so `Static` and `Dns` connect
  them again once the network heals, and the peer check runs again on the
  new connection. Each drop and each reconnect is logged and reported with
  `[brazier, cluster, node, up | down]`.
- `NoDiscovery` does not reconnect them, which is one more reason to
  choose a discovery that connects.

Turn the setting off (`-kernel prevent_overlapping_partitions false`) only
when no code on the node uses `global` names and you need connections that
survive a partial partition. Brazier's own netsplit tests do this, to keep
each app node connected to a shared database node while the app nodes are
split.

### The peer check

When a node connects, both sides exchange
`HMAC-SHA256(secret_key, "brazier-cluster-v1")` and a protocol version.
`secret_key` is the app's secret key. The purpose label keeps the MAC
distinct from every token signature made with that key.

- If the key or the version differs, the peer is rejected.
- If the peer sends nothing within `peer_check_timeout` (default 5s), it is
  rejected. Each timer belongs to one connection. When a node goes
  down and reconnects as its old timer fires, that old timer is ignored
  and the new connection keeps its full timeout.
- Each rejection is logged at error level and emits
  `[brazier, cluster, peer, rejected]`.
- A rejected peer is not a member, and **it stays connected**. A later
  hello from it is checked again, so a peer whose manager started late
  still joins. A member that sends a hello with the wrong key stops being
  a member.
- A hello in an unexpected shape is dropped and logged at warning level,
  with its sender and size only.
- The MAC is never logged. `sys:get_status` and the manager's crash
  reports show it, and any MAC in a message the manager holds, as
  `redacted`.

The check catches misconfiguration, for example staging and production
sharing a cookie, or two releases with incompatible protocols. **It is not
a security boundary:** a node that holds the cookie can already run code
before the check finishes. TLS and the network rules above are the
boundary.

#### Why a rejected peer is not disconnected

OTP's `global` prevents overlapping partitions by default (the kernel
parameter `prevent_overlapping_partitions` is `true`). When a node loses a
connection, `global` on that node tells every other node it knows. Each of
them then drops its own connection to the lost node, and asks that node to
drop its side. No node checks who sent the report.

So if node `b` of another deployment rejected the members `a` and `c` and
disconnected `a`, `b` would tell `c` that it had lost `a`. Then `c` and `a`
would cut the connection between them, though both are real members.
Without discovery, nothing would connect them again. In a plain mesh of
three OTP nodes, one `erlang:disconnect_node/1` leaves all three apart.

OTP documents `global:disconnect/0`, run on the node that leaves, as the
only way to leave without this cascade. One node cannot make another run
it. Rejection therefore changes membership, not connections. OTP 25's
`global_group` does the same: `disconnect_nodes/1` now excludes a node
instead of disconnecting it. Mnesia likewise ignores connected nodes
outside `db_nodes`. Brazier exchanges nothing with a node that is not a
member (see [Membership](#membership)).

A rejected peer is a configuration error. To fix it:

- Give each deployment its own cookie, so the nodes cannot connect at all.
- Or give each deployment its own TLS certificate authority. See
  [Encrypt and authenticate with TLS](#2-encrypt-and-authenticate-with-tls).
- To take a running node out of a cluster now, run `global:disconnect()`
  on that node. It drops every connection without the cascade.

### Membership

A connected node is a **member** only after it passes the peer check.
`cluster.members()` returns the members. Brazier's own cluster traffic goes
to members only, and what any other node sends is dropped:

- **PubSub.** `broadcast` forwards to members only. `direct_broadcast` to a
  connected node that is not a member returns `Error(NodeNotVerified(_))`.
  A forwarded message from a node that is not a member is dropped. Each
  drop is logged at debug level, and each forwarding worker logs a warning
  with the count at most once per second.
- **Replicated stores** sync and replicate with members only. Sync requests
  and deltas from other nodes are dropped with a warning. A store syncs with
  a node when the node passes the check, not when it connects.
- **Presence** sends heartbeats, deltas and state transfers to members
  only. The same messages from other nodes are dropped with a warning.
- **Session revocation** (logout and rotation) reaches sockets on members
  only. A warning counts the bound processes it skipped and names their
  nodes.

There is no fallback to every connected node. Without a running cluster
manager, no remote node is a member, so these features stay on this node.
Membership is per connection. A node loses it when it is rejected or goes
down. It is checked again on its next hello, or when it reconnects.

- **A membership belongs to one connection.** The manager records the
  distribution connection each peer check passed on. `members()` counts a
  node only while it is still connected over that connection, so a node
  that went down and came back is not a member until its new connection
  passes the check. This holds even in the moment before the manager has
  handled the `nodedown`.
- **Waits survive a manager restart.** Code inside Brazier that waits for a
  node to pass the check, or to verify this node too, is recorded in a
  table owned by the node's ETS table owner, not by the manager. A manager
  that crashes and restarts loses none of them. The new manager drops the
  waits of exited processes and of connections that went down while it was
  away. Each wait is answered exactly once, and is dropped when its
  connection goes down. Phoenix.Tracker, by contrast, loses what it
  tracked when the tracker crashes. Brazier follows the OTP pattern of
  keeping state with a process that does not crash.
- **Both sides verify.** A node has verified a peer when the peer's hello
  is accepted. The peer may not yet have verified this node, and until it
  has it drops what this node sends. Session re-checks and replicated
  store syncs therefore start only when both sides have verified each
  other: this node has accepted the peer's hello, and the peer has
  acknowledged this node's hello. A manager answers an acknowledgement
  that verified its sender, once per verification, so two managers never
  acknowledge each other in a loop. A new hello from a peer, such as after
  its manager restarted, makes this node wait for a new acknowledgement.

## PubSub across nodes

`brazier/pubsub` is a port of Phoenix.PubSub with its pg adapter.

- **Delivery.** `broadcast` delivers to local subscribers, then sends one
  message per remote node. The receiving node's forwarding worker delivers
  it locally.
- **Scope.** `local_broadcast` reaches this node only. `direct_broadcast`
  reaches one named node. It returns `Error(NodeNotConnected(_))` when the
  node is not connected, and `Error(NodeNotVerified(_))` when the node has
  not passed the peer check.
- **`pool_size` must be the same on every node.** A message is forwarded to
  the worker of the same index on each node.
- **Members only.** Messages go to members and are taken from members only
  (see [Membership](#membership)). Members trust each other completely, and
  membership does not authenticate a message's content. Do not connect
  nodes you do not trust.
- **Overload is reported, never hidden.** A forwarding worker whose queue
  passes `max_forward_queue` (default 10,000) logs an error and emits
  `[brazier, pubsub, forward, overloaded]` at most once per second. It
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

A `brazier/store` store is local or replicated, chosen when it is opened.

- **Local** (the default, `store.new` / `store.new_list`). The table is per
  node. A write changes this node's table and notifies watchers on this
  node only (`local_broadcast`). Two nodes behind a load balancer therefore
  show different store contents.
- **Replicated** (`store.open` / `store.open_list` with
  `store.Replicated(config)`). Every node that opens the store keeps a full
  replica, and the replicas converge. See below.

For data that must survive every node restarting, use your database.
Presence is the better fit for "who is here".

## Replicated stores

<!-- docs-check: wrap
import brazier/store
import brazier/store/replicated

pub fn open_cart() -> store.Store(Int) {
  {{block}}
  cart
}
-->
```gleam
let assert Ok(cart) =
  store.open("cart", store.Replicated(replicated.default_config()))
```

Each node runs one replica process per replicated store, under its own
supervisor. The design follows Phoenix.Tracker (one process owns the
replicated state, deltas go out over PubSub, and a periodic exchange repairs
what was lost). Its state is an add-wins last-writer-wins map ported from
delta_crdt_ex's `AWLWWMap` (`brazier/store/crdt`). The replica mirrors its
values into ETS, so reads never leave the node or call the replica. The API
is the one in [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md#replicated-stores).

### How writes travel

1. A write is a call to this node's replica. The replica checks the limits,
   applies the write, updates its ETS mirror, and broadcasts the write's
   delta on `brazier_store:<kv|list>:<name>`. The writer then notifies this
   node's watchers.
2. Each receiving replica merges the delta, then notifies its own node's
   watchers on the store topic and on any `append_notify` /
   `delete_all_notify` topic the change carried.
3. Deltas are fire and forget. Every `sync_interval_ms` (default 1 second)
   each replica broadcasts a digest of its state. A replica whose digest
   differs asks the sender for its full state and merges it. This repairs
   any delta lost to a netsplit, a crash or an overloaded PubSub forwarder.
   The digest is the XOR of a SHA-256 hash of each live entry, clock entry
   and cloud dot, as Riak's TicTac anti-entropy trees hash their segments.
   Every merge folds in the hashes of what it adds and removes, so a tick
   costs the same whatever the store's size.
4. A replica that starts asks every peer for its full state at once. This
   covers a node joining, a node rejoining after a crash, and a replica
   restarted by its supervisor. It also asks a node for its full state
   once that node and this node have verified each other (see
   [Membership](#membership)): a request sent earlier would be dropped by
   a peer that has not yet verified this node. Until the first sync
   arrives, a new replica serves empty reads.

Merges are idempotent and commutative, so a delta that arrives twice, late,
or after a full state that already contained it changes nothing.

### Conflicts

- **Timestamps.** Every write is stamped with a hybrid logical clock
  (`brazier/store/hlc`): the wall clock in milliseconds, a logical counter,
  and the node name. A replica that merges a remote write advances its
  clock past that write, so a later write on any node gets a later
  timestamp.
- **Last writer wins.** Concurrent writes of one key resolve to the
  greatest `(timestamp, node)` on every node, whatever order they arrive
  in.
- **Add wins.** A delete removes only the values the deleting node had
  seen. A value written concurrently on another node survives the delete.
- **List stores** keep every appended value, ordered by timestamp.
- **Clock skew.** A remote timestamp more than 60 seconds ahead of this
  node's clock is logged as a warning. Its writes win every comparison
  until the other clocks catch up, so keep node clocks synchronised (NTP).

### Limits

`replicated.Config` bounds every replica. `validate_config` rejects values
out of range, and `store.open` returns `Error(InvalidConfig(_))` for them.

| Field | Default | Bounds |
|---|---|---|
| `sync_interval_ms` | 1000 | 10 to 3,600,000 |
| `max_entries` | 100,000 | 1 to 10,000,000 |
| `max_value_bytes` | 64 KiB | at least 1, below `max_delta_bytes` |
| `max_delta_bytes` | 1 MiB | at most `max_sync_bytes` |
| `max_sync_bytes` | 64 MiB | at most 1 GiB |

- **Entries.** `max_entries` counts the keys of a key-value store and the
  values of a list store. Concurrent values of one key each count until a
  later write replaces them.
- **Bytes** are measured with `erlang:external_size/1`. A value includes
  its key.
- **On the writer**, a write past a limit returns `TooManyEntries`,
  `ValueTooLarge` or `DeltaTooLarge` and changes nothing.
- **On every receiver**, a delta or full state larger than its limit, or
  one that would grow the replica past `max_entries`, is refused and
  logged at error level. The replica keeps its state. Its digest still
  differs, so a later exchange retries, after a backoff (see
  [Refused merges back off](#refused-merges-back-off)), until the
  configurations agree or the data shrinks.
- **A malformed payload is refused before it is read.** Every field of a
  delta or full state from another member is checked first: each key and
  topic is a UTF-8 string, each dot names a replica (a non-empty node name
  and an incarnation of at least 0) and a counter of at least 1, each entry
  has a well-formed timestamp, the context's clock and cloud are well
  formed, and every live dot is covered by the payload's own context. A
  full state carries no delta topics and no key without values. A payload
  that fails is refused and logged at error level with the field that
  failed; the replica keeps its state and keeps running. Values are not
  checked: a replicated store holds any term.

Every node must open a store with the same configuration. A node that
opens a name already open with another configuration, or in the other mode,
gets `Error(InvalidConfig(_))`.

### Refused merges back off

A refused merge leaves the digests different, so without a delay every
exchange would pull the same state, refuse it again, and move up to
`max_sync_bytes` every `sync_interval_ms`. So each refusal from a peer
delays the next state request to that peer:

- After refusal `n` (counting from 0) the delay is taken at random from
  `[D/2, D]`, where `D = min(cap, sync_interval_ms * 2^n)` and
  `cap = max(sync_interval_ms, 60s)`. This is the same jittered window as
  the cluster manager's reconnect backoff, so replicas that refuse the
  same peer do not retry in lockstep.
- Each refusal is logged at warning level with its count and the delay:
  `refusal 3 in a row; its state is requested again in 3412ms at the
  earliest`. Each retry is logged at info level.
- A digest that differs while the delay runs is not acted on (debug log).
- A merged full state from the peer, or a digest equal to this replica's,
  ends the backoff, which is logged at info level.
- The backoff holds at most one entry per member, and a peer's entry goes
  when the peer disconnects. The request sent when a node and this node
  have verified each other is not delayed: it happens once per
  connection.

### Knowing when a replica is in sync

<!-- docs-check: wrap
import brazier/store/replicated

pub fn cart_synced() -> Result(Bool, String) {
  {{block}}
}
-->
```gleam
case replicated.start(replicated.KeyValue, "cart", replicated.default_config()) {
  Ok(#(server, _table)) ->
    case replicated.synced(server) {
      Ok(synced) -> Ok(synced)
      Error(err) -> Error(replicated.describe_write_error(err))
    }
  Error(err) -> Error(replicated.describe_start_error(err))
}
```

`replicated.start` returns the running replica when the store is already
open with the same configuration. `replicated.synced` is `Ok(True)` when
every peer replica last sent a digest equal to this replica's. Then every
value written anywhere before those digests were sent is on this node.

- **Peers** are the replicas of the store on members (see
  [Membership](#membership)), as pg lists them. A node that has not opened
  the store is not waited for.
- **With no peer** it is `Ok(True)`. A single node, or a node cut off by a
  netsplit, is in sync with itself.
- **It turns `Ok(False)`** on a local write, a merge, or a new peer, and
  turns back once the next digests agree, one `sync_interval_ms` later
  when nothing else changes. A peer that has not sent a digest since it
  joined counts as not in sync.
- **It follows pg.** Just after a peer connects or its replica restarts,
  pg may not list the new replica yet. Until it does, the replica does not
  count it, and a digest from it is not counted either.
- Changes of the in-sync state are logged at debug level.

Use it to wait before serving reads that must include other nodes' writes,
for example in a readiness check after a deploy. Like the rest of the
store, it says nothing about writes still in flight when it was read.

### Restarts and floors

Every replica start is a new *incarnation* of its node, and every value it
writes is tagged with that incarnation. Incarnations only grow on a VM:
each one is the wall clock in microseconds, or one above the last
incarnation of that store on this VM when the clock has not moved past it.

Without more, each restart would add an entry to every replica's causal
context that no replica could drop. So once a restarted replica is in sync
with at least one peer, it raises its node's *floor* to its incarnation.
The floor covers every value the node's earlier incarnations wrote, and
their context entries are dropped everywhere. The raise is a delta with no
values, broadcast like a write and logged at info level with the context
size before and after. `replicated.context_size(server)` reports the
context's size, which stays bounded however often replicas restart.

The trade-off is narrow. A value of an earlier incarnation that only an
unreachable replica held, such as one on the other side of a netsplit or
on a node whose replica had not yet joined, or that was still in flight,
is covered without having been seen. It is dropped wherever it later
arrives. Its writer is gone and its delta was fire and forget, so that
write was already at risk.

**A stale incarnation restarts.** A replica that receives a floor of its
own node above its own incarnation is outdated: a later incarnation of
its node exists, for example because the node's clock went back across a
full restart. Every value it wrote would be covered, so dropped,
everywhere. It logs an error and stops, and its supervisor restarts it
with an incarnation above that floor.

### Failures

- **Netsplit.** Each side keeps accepting writes. When the nodes reconnect,
  the digest exchange pulls the missing state and both sides converge by
  the rules above.
- **Replica crash.** The supervisor restarts the replica (at most 3
  restarts in 5 seconds), and the new replica syncs from its peers, then
  raises its node's floor (see [Restarts and floors](#restarts-and-floors)). While
  it restarts, reads crash the caller loudly and writes return
  `Unavailable`. If the supervisor gives up, the store stays down on that
  node until it is opened again.
- **A write call that gets no answer within 5 seconds** returns
  `Unavailable`.

### Telemetry

- Every write emits `[brazier, store, write]` with `mode: "replicated"`. A
  rejected write emits nothing.
- Every remote merge (delta or full state, accepted or refused) runs in a
  `[brazier, store, sync]` span. The stop event's `entries` is the number of
  entries the payload carried and `bytes` its size; `peer` is the sending
  node. Its `result` is `ok`, `malformed`, `too_large` or
  `too_many_entries`, and `reason` names the malformed field or the limit
  (`max_delta_bytes`, `max_sync_bytes`, `max_entries`), or is `none`. A
  malformed payload reports `entries` 0, since its entries cannot be
  counted. See [TELEMETRY.md](TELEMETRY.md).

### Caveats

- A replicated store is memory on every node. Size `max_entries` and
  `max_sync_bytes` for the smallest node.
- A full sync sends the whole state, so a large store makes joins and
  repairs proportionally expensive. Deltas carry only the written entries.
- A floor drops a value of an earlier incarnation that no reachable replica
  held when the floor was raised (see
  [Restarts and floors](#restarts-and-floors)).
- `replicated.synced` reflects digests and pg's view of the peers, not
  delivery of each write (see
  [Knowing when a replica is in sync](#knowing-when-a-replica-is-in-sync)).
- The CRDT is ported from delta_crdt_ex's `AWLWWMap`, with these
  differences (the `brazier/store/crdt` module doc has the detail):
  - the causal context is exact, where delta_crdt_ex compresses it to one
    counter per replica;
  - values are ordered by a hybrid logical clock with a tie-break on the
    dot, so every node reads the same value;
  - floors bound the context across restarts, where delta_crdt_ex's grows
    with every restart;
  - a differing digest pulls the whole state, where delta_crdt_ex walks a
    Merkle tree to the differing keys and keeps one sync in flight per
    neighbour. Brazier does not track outstanding syncs: each differing
    digest sends a new request, and the backoff above bounds repeats of a
    refused one.
- Replication runs between members only (see [Membership](#membership)).
  Membership does not authenticate a message's content: members trust each
  other completely (see [Security first](#security-first-what-distribution-means)).

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

<!-- docs-check: wrap
import brazier/session

pub fn start(postgres_backend: session.ExternalBackend) -> session.SessionStore {
  {{block}}
  store
}
-->
```gleam
let assert Ok(store) =
  session.start_store(session.External(postgres_backend), session.default_store_config())
```

Across the cluster:

- **Revocation is cluster-wide.** Deleting, rotating or expiring a session
  sends `{brazier_session_revoked, Id, Reason}` to every process bound to it
  (`bind_current_process`) on this node and on every member (see
  [Membership](#membership)).
- **Netsplits.** A revocation cannot cross a netsplit. When a connected
  node and this node have verified each other, every store re-checks the
  sessions its local processes are bound to, and revokes those that are
  gone. The re-check waits for both sides: a revocation goes only to the
  nodes its sender has verified, so a re-check after only this side had
  passed the other could run before the other side's revocations reach
  this node. A node is verified on both sides once its hello is accepted
  here and it has acknowledged this node's hello. If a peer's cluster
  manager restarts while the connection stays up, its new hello starts
  the exchange again, and the re-check runs again.

  One window remains. pg copies each node's bindings to the others on its
  own schedule, apart from the peer check. A revocation sent after both
  sides have verified each other, but before the sender's pg has learnt of
  a binding on the other node, misses that binding, and no re-check
  follows. A socket bound by `auth.protect_ws` or `auth.allow_guests_ws`
  is still closed at its next auth re-check (`ws_auth_recheck_interval_ms`,
  see [WebSocket sessions](SECURITY.md#websocket-sessions)).
- **Bindings do not reveal session ids.** A bound process joins a pg group
  in the session revocation scope, and pg shows its group names to every
  connected node, member or not (`pg:which_groups/1`). The group is named
  by a SHA-256 hash of the session store's namespace and the session id,
  never the id. Each node keeps its own bindings and their ids in a local
  table for the re-check, and drops the rows of exited processes on every
  maintenance sweep and before each re-check.
- **Clocks.** Lifetimes use `erlang:system_time(millisecond)` so nodes can
  compare timestamps. Clocks may differ by up to `clock_skew_tolerance_ms`
  (5,000), so a lifetime can end up to 5s early or late. A timestamp
  further in the future than that means a broken clock: the session is
  treated as expired and an error is logged. Run NTP on every node.

## Presence

`brazier/presence` is a port of Phoenix.Tracker and Phoenix.Presence. It
tracks which processes are on a topic, on this node and every member (see
[Membership](#membership)).

### Session presence

Most apps track their sessions with `brazier.presence`. The tracker runs in
the application's supervision tree, and each session declares what it is
present as from its state:

<!-- docs-check: wrap
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import gleam/dynamic/decode
import gleam/json

{{block}}

pub type Model {
  Model(
    room: String,
    user: String,
    profile: Profile,
    online: List(sync.Entry(Profile)),
  )
}

pub type Profile {
  Profile(name: String)
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  let profile = Profile(name: "Ada")
  Ok(#(Model(room: "1", user: "ada", profile:, online: []), effect.none()))
}

fn view(model: Model) -> Element(Msg) {
  element.text(model.profile.name)
}

fn encode_profile(profile: Profile) -> json.Json {
  json.object([#("name", json.string(profile.name))])
}

fn profile_decoder() -> decode.Decoder(Profile) {
  use name <- decode.field("name", decode.string)
  decode.success(Profile(name:))
}
-->
```gleam
import brazier
import brazier/presence
import brazier/presence/sync

pub type Msg {
  PresenceChanged(sync.Diff(Profile))
}

pub fn main() {
  let online = presence.new("online", encode_profile, profile_decoder())

  brazier.application(init:, update:, view:)
  |> brazier.presence(
    tracker: online,
    track: fn(model) {
      [presence.Tracking(topic: "room:" <> model.room, key: model.user, meta: model.profile)]
    },
    on_presence: PresenceChanged,
  )
  |> brazier.start(8080)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    PresenceChanged(diff) ->
      #(Model(..model, online: sync.merge(model.online, diff)), effect.none())
  }
}
```

`Diff`, `Entry` and `Meta` are in `brazier/presence/sync`, which runs in the
browser, so `Msg` and the Model can carry them. The rest of
`brazier/presence` runs only on the server. `examples/chat` tracks who is in
each room and who is typing this way.

- **Tracking follows the state.** `track` runs after every update. A new
  tracking is tracked, a changed meta is updated, a tracking that
  disappears is untracked, and everything leaves when the session ends.
- **Diffs arrive as messages.** Every change on a tracked topic, from any
  node, arrives as `on_presence(diff)`. The session's first message for a
  topic lists everyone already there as joins. Up to 100 queued changes
  of a topic are coalesced into one message. `sync.merge` applies a diff
  to a list (Phoenix's `syncDiff`).
- **Shard restarts are handled for the app.** When a tracker shard
  restarts, the session tracks its entries again (with backoff) and gets
  one message with the old entry leaving and the new one joining.
  Entries of other nodes do not flap. The new shard starts empty and
  gets each peer's entries from that peer: the peer's next heartbeat
  marks it up, and the transfer at the next clock sample carries them.
  Until then the session keeps them, without a leave or a join, and asks
  the shard to say when it has synced with their nodes. The shard
  answers after the diffs of what it learnt. The session then reports
  only the entries the shard still does not have, which left meanwhile.
  It also reports them when the node is down, when the shard has not
  heard from the node for `down_period`, or when it has not synced
  within `down_period`. The last case is logged as a warning.
  Entries of this node that the old shard held are reported as leaves at
  once. Their processes track again with new refs. What other sessions
  see of that is below.

#### What other sessions see when a shard restarts

When the shard of node A restarts, every entry it held is a presence that
has ended, on every node. A session that tracks itself there tracks again
under a new ref, and that is a new presence. So every session that follows
the topic, on A or on another node, gets the old ref as a leave and the
new ref as a join:

- **On another node B,** the shard of B sees A's new shard as a new
  replica of A (a new `vsn`) at its first heartbeat. The old replica is
  then down and permanently down at once, which reports its entries as
  leaves. The new replica's entries arrive as joins when B gets them, with
  the transfer at the next clock sample or as later deltas.
- **On A,** a session that follows the topic gets the leaves from the
  read it does once the new shard is up (the paragraph above). A session
  that tracks there tracks again after its backoff, and its join arrives
  when it does. A diff of the new shard that reaches the session before
  that read is not reported on its own: the read covers it, so a join
  that came first is reported in one message with the leave.

The leave and the join are separate messages when they are not queued at
the same time, and one coalesced message when they are. Either way the
leave comes first, and `sync.merge` ends with the new ref only. A list
keyed by `key` (as Phoenix's JavaScript `Presence.list` is) shows the key
throughout when both arrive in one message, and is without it in between
when they do not.

This is Phoenix.Tracker's model, kept on purpose:

- A presence is identified by its ref (`phx_ref`), not its key: a key can
  be on a topic many times (two tabs), and a tracking made again may carry
  a different meta. Merging the old ref into the new one would need a
  rule Phoenix does not have.
- `Phoenix.Tracker.Shard.handle_heartbeat` treats a known node with a new
  `vsn` as down, then permanently down, then up: the old replica's entries
  leave at once, and the new replica's join when they replicate. Brazier's
  shard does the same (`brazier_presence_shard.erl`, `handle_heartbeat`).
- Holding the leaves until the entries come back would not be bounded by
  anything the watcher can know. Only Brazier sessions track again, a
  process that called `presence.track` itself does not, and a session may
  have ended meanwhile. Phoenix does not track again at all: the shard
  links its tracked processes, so a shard crash ends them, and their
  clients join again. A watcher that held leaves would show entries that
  may never return, and the delay before it gave up would be a guess.

The suspects described above are different: they are entries that did
not end, held only until the new shard has synced with their node, which
the shard reports.

`ws10b_presence_restart_semantics_test` checks this on two nodes.
- **Failures stop the session loudly.** A tracking the tracker refuses (a
  limit, an invalid topic or key, the same key twice on a topic), a
  tracker that stays down, or the loss of the session's PubSub partition
  stops the session with a logged error. `brazier.start` fails when the
  tracker configuration is invalid.

### Watching without tracking

A session that only shows who is here, such as a dashboard or a lobby
list, uses `brazier.watch_presence`. It follows the topics `watch` returns
for its state and tracks nothing, so it never appears in a list:

<!-- docs-check: wrap
import brazier
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/presence
import brazier/presence/sync

pub fn main(online: presence.PresenceConfig(String)) {
  {{block}}
}

pub type Model {
  Model(room: String, user: String, status: String)
}

pub type Msg {
  PresenceChanged(sync.Diff(String))
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(room: "1", user: "ada", status: "online"), effect.none()))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    PresenceChanged(_) -> #(model, effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  element.text(model.user)
}
-->
```gleam
brazier.application(init:, update:, view:)
|> brazier.watch_presence(
  tracker: online,
  watch: fn(model) { ["room:" <> model.room] },
  on_presence: PresenceChanged,
)
```

A watched topic gets the same diffs as a tracked one. The first message
lists everyone already there as joins, up to 100 queued changes are
coalesced into one message, every entry is reported once, and shard
restarts are handled as above. `watch` runs after every update. A topic
that is no longer listed reports everyone the session knew there as
leaves. A topic listed twice is followed once. An invalid topic (empty, or
over `presence.max_topic_bytes`) fails the session's start, or stops the
session later, with a logged error.

### Tracking and watching

A session that is on some topics and follows others, such as a user in a
room who also sees the lobby, uses `brazier.track_and_watch_presence`:

<!-- docs-check: wrap
import brazier
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/presence
import brazier/presence/sync

pub fn main(online: presence.PresenceConfig(String)) {
  {{block}}
}

pub type Model {
  Model(room: String, user: String, status: String)
}

pub type Msg {
  PresenceChanged(sync.Diff(String))
}

fn init(_ctx: brazier.Context) -> Result(#(Model, Effect(Msg)), brazier.InitError) {
  Ok(#(Model(room: "1", user: "ada", status: "online"), effect.none()))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    PresenceChanged(_) -> #(model, effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  element.text(model.user)
}
-->
```gleam
brazier.application(init:, update:, view:)
|> brazier.track_and_watch_presence(
  tracker: online,
  track: fn(model) {
    [presence.Tracking(topic: "room:" <> model.room, key: model.user, meta: model.status)]
  },
  watch: fn(_model) { ["lobby"] },
  on_presence: PresenceChanged,
)
```

Its topics are those `track` returns plus those `watch` returns, each
followed once. The session appears only on its tracked topics.

`brazier.presence`, `brazier.watch_presence` and
`brazier.track_and_watch_presence` set the same thing. When more than one
is called, the last call wins. A session that tracks itself already hears
its tracked topics, so it does not also need to watch them.

### The tracker API

The rest of this section describes the tracker itself, for processes that
are not Brazier sessions.

<!-- docs-check: wrap
import gleam/dynamic/decode
import gleam/json

{{block}}

pub type UserMeta {
  UserMeta(status: String)
}

fn encode_user_meta(meta: UserMeta) -> json.Json {
  json.object([#("status", json.string(meta.status))])
}

fn user_meta_decoder() -> decode.Decoder(UserMeta) {
  use status <- decode.field("status", decode.string)
  decode.success(UserMeta(status:))
}
-->
```gleam
import brazier/presence

fn users_config() -> presence.PresenceConfig(UserMeta) {
  presence.new("users", encode_user_meta, user_meta_decoder())
}

/// The tracker's child, for your supervisor.
pub fn users_child() {
  presence.supervised(users_config())
}

/// In the process to track (for example a connection's runtime).
pub fn join_room(user_id: String) {
  let assert Ok(users) = presence.handle(users_config())
  let assert Ok(_ref) =
    presence.track(users, "room:42", user_id, UserMeta(status: "online"))
  let assert Ok(Nil) = presence.subscribe(users, "room:42")
  presence.list(users, "room:42")
}
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

Start it after PubSub (`brazier.presence` does this in the application's
tree). Shards replicate only with the shard of the same
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

- Subscribers receive `{brazier_pubsub, presence.diff_topic(users, topic), Diff}`.
  Pass the Diff to `presence.decode_diff(users, diff)` to get a
  `sync.Diff(topic, joins, leaves)`.
- An update appears as a leave of the old meta and a join of the new one,
  with the old `ref` as the new meta's `ref_prev` (Phoenix.Presence
  semantics).
- Changes from a remote node arrive together, one diff per heartbeat.

### Limits

Every limit violation is an `Error`, is logged, and emits
`[brazier, presence, limit_exceeded]`. Nothing is dropped silently.

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
| A node crashes or is unreachable | After `down_period` without a heartbeat, peers mark it `Down` (`[brazier, presence, replica, down]`) and its entries leave. After `permdown_period` its data is dropped (`replica, permdown`). |
| A netsplit | Each side marks the other down after `down_period` and sees only its own entries. When the split heals, the sides exchange state and converge, including changes made during the split. |
| A node comes back before `permdown_period` | Its entries rejoin from its heartbeats or a transfer (`replica, up`). |
| A tracker stops normally | It tells its peers, which drop its entries at once instead of waiting for `down_period`. |
| A shard crashes and restarts | The new shard has a new version, and peers drop the old version's entries at once. Tracked processes must track again. They can monitor `presence.shard_pid(users, topic)` to find out. The new shard learns each peer's entries from the peer's heartbeat and the transfer that follows, and Brazier sessions keep those entries until it has (see Session presence). |
| A new node joins | It asks a peer for a transfer of the current state (`[brazier, presence, transfer]`). |

`presence.replicas(users, topic)` returns the peers a shard knows, with
`Up` or `Down`. `test/brazier/cluster/presence_cluster_test.gleam` runs
each row of this table on real peer nodes.

## Testing clusters

`test/brazier/cluster/peer.gleam` starts real peer nodes with OTP's `peer`
module. It can:

- connect peers into a mesh;
- make every peer a member: `with_members` runs a cluster manager on each
  peer and waits until every pair has passed the peer check, because
  PubSub, stores, presence and revocation exchange nothing before that;
- crash and stop nodes;
- partition and heal links.

`test/brazier/cluster/membership_test.gleam` connects a node with another
secret key and checks that store, PubSub, presence and revocation traffic
crosses in neither direction.

Peers stop when the test ends, whether it passes or fails. The tests wait
with `peer.until`: a condition re-checked after each message that announces
a change (a telemetry event, a monitor, a node up or down), never with
sleeps or polls.
