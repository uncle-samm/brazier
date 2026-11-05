//// Multi-node tests of a replicated store's sync signal, retry backoff and
//// floors (`replicated.synced`, `replicated.context_size`, and
//// `brazier/store/crdt`, "Floors").
////
//// As in store_cluster_test, nothing polls: a wait is `peer.until` woken
//// by the `[brazier, store, sync]` stop event of every remote merge, and,
//// for `synced` (which changes when a digest arrives, announced by no
//// event), by the sync ticks of a replica, each of which broadcasts its
//// digest.

import brazier/await
import brazier/cluster/peer.{type Peer, Timeout}
import brazier/pubsub
import brazier/state_manager
import brazier/store/replicated.{Config}
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string

const wait_ms = 10_000

const name = "rsf"

/// The stop event of the span every remote merge runs in.
const merged = ["brazier", "store", "sync", "stop"]

// --- Helpers ----------------------------------------------------------------

fn fast() -> replicated.Config {
  Config(..replicated.default_config(), sync_interval_ms: 100)
}

/// This node's replica of the key-value store `name` (started with `cfg`,
/// or the running one).
fn server_here(cfg: replicated.Config) -> replicated.Server {
  pubsub.start()
  let assert Ok(#(server, _table)) =
    replicated.start(replicated.KeyValue, name, cfg)
    as "replicated.start succeeds"
  server
}

fn table_here(cfg: replicated.Config) -> state_manager.EtsTable {
  let assert Ok(#(_server, table)) =
    replicated.start(replicated.KeyValue, name, cfg)
    as "replicated.start succeeds"
  table
}

fn open_on(p: Peer, cfg: replicated.Config) -> Nil {
  peer.on(p, fn() {
    let _server = server_here(cfg)
    Nil
  })
}

fn put_on(p: Peer, cfg: replicated.Config, key: String, value: String) -> Nil {
  peer.on(p, fn() { put_here(cfg, key, value) })
}

fn put_here(cfg: replicated.Config, key: String, value: String) -> Nil {
  let assert Ok(Nil) = replicated.put(server_here(cfg), key, value)
    as "the write is applied"
  Nil
}

fn remove_on(p: Peer, cfg: replicated.Config, key: String) -> Nil {
  peer.on(p, fn() {
    let assert Ok(Nil) = replicated.remove(server_here(cfg), key, [])
      as "the removal is applied"
    Nil
  })
}

fn get_on_node(n: Node, cfg: replicated.Config, key: String) -> Option(String) {
  peer.on_node(n, fn() { get_here(cfg, key) })
}

fn get_here(cfg: replicated.Config, key: String) -> Option(String) {
  let assert Ok(value) = replicated.get(table_here(cfg), key)
    as "the replica's mirror is readable"
  value
}

fn synced_on_node(n: Node, cfg: replicated.Config) -> Bool {
  peer.on_node(n, fn() { synced_here(cfg) })
}

fn synced_here(cfg: replicated.Config) -> Bool {
  let assert Ok(synced) = replicated.synced(server_here(cfg))
    as "replicated.synced succeeds"
  synced
}

fn context_size_on_node(n: Node, cfg: replicated.Config) -> Int {
  peer.on_node(n, fn() {
    let assert Ok(size) = replicated.context_size(server_here(cfg))
      as "replicated.context_size succeeds"
    size
  })
}

fn digest_on_node(n: Node, cfg: replicated.Config) -> BitArray {
  peer.on_node(n, fn() {
    let assert Ok(digest) = replicated.digest(server_here(cfg))
      as "replicated.digest succeeds"
    digest
  })
}

fn replica_on(p: Peer) -> Pid {
  peer.on(p, fn() {
    let assert Ok(pid) = replica_pid(name) as "the replica runs"
    pid
  })
}

/// Whether `check` comes to hold, run on `p`: re-checked after every merge
/// on `nodes` and every sync tick of `p`'s replica (a digest broadcast).
fn settles(p: Peer, nodes: List(Node), check: fn() -> Bool) -> Bool {
  let wake =
    peer.any([
      peer.events_on(nodes, [merged]),
      peer.info(replica_on(p), "sync_tick"),
    ])
  peer.until(p, wake, check, wait_ms)
}

/// Whether the replicas on `nodes` (opened with `cfgs`, in order) all come
/// to report `synced`, with one digest.
fn all_synced(
  p: Peer,
  nodes: List(Node),
  cfgs: List(replicated.Config),
) -> Bool {
  let pairs = list.zip(nodes, cfgs)
  settles(p, nodes, fn() {
    list.all(pairs, fn(pair) { synced_on_node(pair.0, pair.1) })
    && one_digest(pairs)
  })
}

fn one_digest(pairs: List(#(Node, replicated.Config))) -> Bool {
  case list.map(pairs, fn(pair) { digest_on_node(pair.0, pair.1) }) {
    [first, ..rest] -> list.all(rest, fn(digest) { digest == first })
    [] -> False
  }
}

// --- Synced -----------------------------------------------------------------

/// `synced` is False from a local write until a peer's digest shows the
/// write, and True once the replicas agree; after a partition both sides'
/// writes are on both nodes once both report `synced`.
pub fn synced_follows_the_peer_digests_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_rsf_synced")
  let assert [a, b] = peers as "the cluster starts two peers"
  let nodes = [peer.node(a), peer.node(b)]
  let cfgs = [fast(), fast()]
  open_on(a, fast())
  open_on(b, fast())
  // A replica alone is synced (it has no peer), so the replicas see each
  // other once each holds the other's digest, b holds a's write and both
  // report synced.
  put_on(a, fast(), "first", "a")
  assert settles(a, nodes, fn() {
    peer_digests(name) == [peer.node(b)]
    && peer.on_node(peer.node(b), fn() { peer_digests(name) }) == [peer.node(a)]
    && get_on_node(peer.node(b), fast(), "first") == Some("a")
    && synced_on_node(peer.node(a), fast())
    && synced_on_node(peer.node(b), fast())
  })

  // b's replica is suspended, so it sends no digest: a's write leaves a
  // out of sync until b has merged it and said so.
  peer.on(b, fn() { suspend(name) })
  put_on(a, fast(), "second", "a")
  assert !peer.on(a, fn() { synced_here(fast()) })
  peer.on(b, fn() { resume(name) })
  assert all_synced(a, nodes, cfgs)
  assert peer.on(b, fn() { get_here(fast(), "second") }) == Some("a")

  // Each side writes while partitioned; once healed and synced, both
  // writes are on both nodes.
  peer.partition(a, b)
  put_on(a, fast(), "split_a", "a")
  put_on(b, fast(), "split_b", "b")
  peer.heal(a, b)
  assert settles(a, nodes, fn() {
    list.all(nodes, fn(n) {
      get_on_node(n, fast(), "split_a") == Some("a")
      && get_on_node(n, fast(), "split_b") == Some("b")
      && synced_on_node(n, fast())
    })
  })
  assert peer.on(a, fn() { one_digest(list.zip(nodes, cfgs)) })
}

// --- Floors -----------------------------------------------------------------

/// A replica restarted many times (each incarnation writing) leaves the
/// causal context of every replica bounded: once in sync it raises its
/// node's floor, which drops the earlier incarnations. Without floors each
/// restart would add a clock entry that is never removed.
pub fn restarts_keep_the_context_bounded_test_() -> peer.Timeout {
  use <- Timeout(120)
  use peers <- peer.with_members(2, "brazier_rsf_restarts")
  let assert [a, b] = peers as "the cluster starts two peers"
  let nodes = [peer.node(a), peer.node(b)]
  let cfgs = [fast(), fast()]
  open_on(a, fast())
  open_on(b, fast())
  put_on(a, fast(), "from_a", "a")
  let restarts = 15
  list.each(
    int.range(from: restarts, to: 0, with: [], run: list.prepend),
    fn(round) {
      let value = int.to_string(round)
      let before = peer.on(b, fn() { incarnation(name) })
      peer.on(b, fn() {
        let assert Ok(Nil) = replicated.stop(server_here(fast()))
          as "the replica stops"
        put_here(fast(), "counter", value)
      })
      assert peer.on(b, fn() { incarnation(name) }) > before
      assert settles(a, nodes, fn() {
        get_on_node(peer.node(a), fast(), "counter") == Some(value)
        && get_on_node(peer.node(b), fast(), "from_a") == Some("a")
      })
      assert all_synced(a, nodes, cfgs)
      // a's own clock entry, b's running incarnation and b's floor, and at
      // most one out-of-order dot.
      list.each(nodes, fn(n) {
        let size = peer.on(a, fn() { context_size_on_node(n, fast()) })
        assert size <= 4
      })
    },
  )
  assert peer.on(b, fn() { get_here(fast(), "counter") })
    == Some(int.to_string(restarts))
}

/// A replica that merges a floor of its own node above its incarnation (a
/// later incarnation of the node exists, as after a clock moved back)
/// stops, and its supervisor restarts it above that floor, so its writes
/// are not dropped.
pub fn a_stale_incarnation_restarts_above_the_floor_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_rsf_stale")
  let assert [a, b] = peers as "the cluster starts two peers"
  let nodes = [peer.node(a), peer.node(b)]
  open_on(a, fast())
  open_on(b, fast())
  put_on(b, fast(), "before", "b")
  assert all_synced(a, nodes, [fast(), fast()])
  let a_node = peer.node(a)

  let #(floor, restarted) =
    peer.on(b, fn() {
      let assert Ok(old) = replica_pid(name) as "b runs the replica"
      let supervisor = parent(old)
      let #(floor, lines) =
        capture_on_here(fn() {
          await.with_watch_exit(supervisor, old, fn(watch) {
            let floor = send_stale_floor(name, a_node, 1_000_000_000_000)
            await.expect_info(watch, supervisor, "the stale replica's exit")
            floor
          })
        })
      assert has_line(lines, "error", [
        "merged a floor of its own node (" <> int.to_string(floor) <> ")",
        "stopping to restart above it",
      ])
      let assert Ok(restarted) = replica_pid(name)
        as "the supervisor restarted the replica"
      assert restarted != old
      #(floor, incarnation(name))
    })
  assert restarted == floor + 1

  put_on(b, fast(), "after", "b")
  assert settles(a, nodes, fn() {
    get_on_node(a_node, fast(), "after") == Some("b")
    && get_on_node(a_node, fast(), "before") == Some("b")
  })
  assert all_synced(a, nodes, [fast(), fast()])
}

// --- Backoff ----------------------------------------------------------------

/// A replica that refuses a peer's state (over its max_sync_bytes) requests
/// it again only after a growing, jittered delay, logged at warning, and
/// ends the backoff once the peer's digest matches.
pub fn refused_merges_back_off_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_members(2, "brazier_rsf_backoff")
  let assert [a, b] = peers as "the cluster starts two peers"
  let small =
    Config(
      ..fast(),
      max_value_bytes: 1000,
      max_delta_bytes: 2000,
      max_sync_bytes: 4000,
    )
  let a_node = peer.node(a)
  let b_node = peer.node(b)
  open_on(a, fast())
  open_on(b, small)
  let capture = peer.on(b, fn() { start_capture() })

  // Larger than b's delta and sync limits: every merge of it is refused.
  put_on(a, fast(), "big", string.repeat("x", 5000))
  let refusals = 4
  assert peer.until(
    b,
    peer.events([merged]),
    fn() {
      case backoff(name) {
        [#(n, attempt, _)] -> n == a_node && attempt >= refusals - 1
        _ -> False
      }
    },
    wait_ms,
  )
  let assert [#(_, attempt, retry_in)] = peer.on(b, fn() { backoff(name) })
    as "b backs off from a"
  let #(_low, high) = backoff_window(attempt, 100)
  assert retry_in <= high
  // The delay doubles per refusal up to 60s.
  assert backoff_window(0, 100) == #(50, 100)
  assert backoff_window(3, 100) == #(400, 800)
  assert backoff_window(40, 100) == #(30_000, 60_000)

  // Once a's state fits again, the digests agree and the backoff ends.
  remove_on(a, fast(), "big")
  assert settles(a, [a_node, b_node], fn() {
    peer.on_node(b_node, fn() { backoff(name) }) == []
    && synced_on_node(a_node, fast())
    && synced_on_node(b_node, small)
  })
  let lines = peer.on(b, fn() { stop_capture(capture) })

  // One warning per refusal, numbered in order, each giving a delay in the
  // window of its attempt; the next refusal is of a state requested no
  // sooner than that delay. (Each request follows a digest of a, sent
  // every 100ms, and a's reply comes well within that, so no second
  // request is in flight when a refusal sets the delay.)
  let from_a = atom.to_string(node.name(a_node))
  let refused =
    list.filter(lines, fn(line) {
      line.level == "warning"
      && string.contains(line.text, "was refused")
      && string.contains(line.text, from_a)
    })
  assert list.length(refused) >= refusals
  let delays =
    list.index_map(refused, fn(line, attempt) {
      assert string.contains(
        line.text,
        "refusal " <> int.to_string(attempt + 1) <> " in a row",
      )
      let delay = delay_of(line.text)
      let #(low, high) = backoff_window(attempt, 100)
      assert delay >= low && delay <= high
      #(line.at_ms, delay)
    })
  list.each(list.window_by_2(delays), fn(pair) {
    let #(#(at, delay), #(next_at, _)) = pair
    assert next_at - at >= delay
  })
}

/// The delay a backoff warning gives ("requested again in 123ms").
fn delay_of(text: String) -> Int {
  let assert Ok(#(_, after)) = string.split_once(text, "requested again in ")
    as "a backoff warning gives its delay"
  let assert Ok(#(digits, _)) = string.split_once(after, "ms")
    as "the delay is in milliseconds"
  let assert Ok(delay) = int.parse(digits) as "the delay is an integer"
  delay
}

// --- Logs -------------------------------------------------------------------

/// A warning or error logged on a node, with when it was logged (the
/// node's monotonic clock, in milliseconds).
type Line {
  Line(level: String, text: String, at_ms: Int)
}

/// Run `run` here, collecting the warnings and errors this node logs.
fn capture_on_here(run: fn() -> a) -> #(a, List(Line)) {
  let capture = start_capture()
  let result = run()
  #(result, stop_capture(capture))
}

/// The lines a capture (`start_capture`) collected, in order.
fn stop_capture(capture: Pid) -> List(Line) {
  list.map(stop_capture_ffi(capture), fn(line) {
    Line(level: line.0, text: line.1, at_ms: line.2)
  })
}

fn has_line(lines: List(Line), level: String, fragments: List(String)) -> Bool {
  list.any(lines, fn(line) {
    line.level == level
    && list.all(fragments, fn(fragment) { string.contains(line.text, fragment) })
  })
}

// --- FFI --------------------------------------------------------------------

@external(erlang, "brazier_store_test_ffi", "replica_pid")
fn replica_pid(name: String) -> Result(Pid, Nil)

@external(erlang, "brazier_presence_test_ffi", "parent")
fn parent(pid: Pid) -> Pid

@external(erlang, "brazier_store_floor_test_ffi", "backoff")
fn backoff(name: String) -> List(#(Node, Int, Int))

@external(erlang, "brazier_store_floor_test_ffi", "peer_digests")
fn peer_digests(name: String) -> List(Node)

@external(erlang, "brazier_store_floor_test_ffi", "incarnation")
fn incarnation(name: String) -> Int

@external(erlang, "brazier_store_floor_test_ffi", "suspend")
fn suspend(name: String) -> Nil

@external(erlang, "brazier_store_floor_test_ffi", "resume")
fn resume(name: String) -> Nil

@external(erlang, "brazier_store_floor_test_ffi", "send_stale_floor")
fn send_stale_floor(name: String, from: Node, above: Int) -> Int

@external(erlang, "brazier_store_floor_test_ffi", "backoff_window")
fn backoff_window(attempt: Int, interval_ms: Int) -> #(Int, Int)

@external(erlang, "brazier_store_floor_test_ffi", "start_capture")
fn start_capture() -> Pid

@external(erlang, "brazier_store_floor_test_ffi", "stop_capture")
fn stop_capture_ffi(capture: Pid) -> List(#(String, String, Int))
