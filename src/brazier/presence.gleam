/// Presence: which processes are on a topic, across every connected node.
///
/// A port of Phoenix.Tracker and Phoenix.Presence:
///
/// - **Trackers and shards.** A tracker has a name and `pool_size` shards;
///   a topic always lives on shard `phash2(topic, pool_size) + 1`. Each
///   shard holds a delta CRDT (`brazier/presence/state`) and mirrors its
///   visible entries into a protected ETS table, so `list` and
///   `get_by_key` never call the shard.
/// - **Replication.** Shards with the same name and index on every node
///   heartbeat over PubSub (`brazier_presence:<name>:<index>`) with the
///   changes since the last heartbeat, and ask a peer for a transfer when
///   its clock is ahead. Start the tracker with the same name, pool size
///   and periods on every node, after PubSub.
/// - **Failure.** A node without a heartbeat for `down_period` is down: its
///   entries leave. After `permdown_period` its data is dropped. A shard
///   that restarts gets a new version, and peers drop the old one at once.
///   A shard that stops normally tells its peers.
/// - **Tracking** is always for the calling process. The shard monitors it
///   and removes its entries when it exits.
/// - **Meta** is JSON from your encoder, at most `max_meta_bytes`, checked
///   against your decoder when tracked. Each track or update gets a fresh
///   `ref`; an update keeps the previous one as `ref_prev`.
/// - **Diffs.** Every change is delivered as a diff to the processes that
///   `subscribe` to the topic on the node of the change, and on each node
///   that learns about it. They receive `{brazier_pubsub, DiffTopic, Diff}`;
///   pass the Diff to `decode_diff`.
/// - **Limits.** Every violation is an `Error`.
/// - **In an app**, `brazier.presence` tracks a session's `Tracking`s from
///   its state and hands the app every change as a `Diff`;
///   `brazier/presence/sync.merge` applies one to the entries the app keeps
///   (Phoenix.Presence's `syncDiff`). `Meta`, `Entry` and `Diff` live in
///   `brazier/presence/sync` so that they can reach the browser.
///
/// See docs/CLUSTERING.md.
import brazier/log
import brazier/presence/sync.{type Diff, type Entry, Diff, Entry, Meta}
import brazier/pubsub
import brazier/telemetry
import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string

/// What a session is present as: `key` on `topic`, with `meta`. A
/// `brazier.presence` app computes these from its state after every update.
pub type Tracking(meta) {
  Tracking(topic: String, key: String, meta: meta)
}

pub type PresenceError {
  /// The encoded meta is larger than `max_meta_bytes`.
  MetaTooLarge(bytes: Int)
  /// A limit was reached: `max_topics_per_pid` or `max_entries_per_shard`.
  PresenceLimitExceeded(limit: String)
  /// The topic is empty or too long for this tracker's diff topics.
  InvalidTopic(String)
  /// The key is empty or longer than 255 bytes.
  InvalidKey(String)
  /// The calling process already tracks this key on this topic.
  AlreadyTracked
  /// The calling process does not track this key on this topic.
  NotTracked
  /// The tracker (or the shard for this topic) is not running.
  TrackerDown
  /// The shard did not answer in time.
  TrackerTimeout
  /// The configuration is invalid.
  InvalidConfig(String)
  /// The tracker did not start.
  StartFailed(String)
  /// The tracker did not stop within the deadline.
  StopFailed(String)
  /// A meta does not decode with the tracker's decoder.
  MetaDecodeFailed(String)
  /// The message given to `decode_diff` is not a diff of this tracker.
  InvalidMessage
  /// PubSub refused a diff subscription.
  PubSubFailed(String)
}

/// How to build a tracker. Use `new` and the setters.
pub opaque type PresenceConfig(meta) {
  PresenceConfig(
    name: String,
    encode: fn(meta) -> json.Json,
    decoder: decode.Decoder(meta),
    pool_size: Int,
    broadcast_period_ms: Int,
    max_silent_periods: Int,
    down_period_ms: Int,
    permdown_period_ms: Int,
    clock_sample_periods: Int,
    max_delta_sizes: List(Int),
    max_meta_bytes: Int,
    max_topics_per_pid: Int,
    max_entries_per_shard: Int,
    max_transfer_entries: Int,
  )
}

/// A running tracker.
pub opaque type Presence(meta) {
  Presence(
    name: String,
    names: Names,
    encode: fn(meta) -> json.Json,
    decoder: decode.Decoder(meta),
    max_meta_bytes: Int,
  )
}

/// The meta as shards store and replicate it. brazier_presence_shard builds
/// it on update, so its shape is part of the FFI contract.
type StoredMeta {
  StoredMeta(json: String, ref: String, ref_prev: Option(String))
}

/// Registered names of the supervisor and the shards (and their tables):
/// the Erlang tuple `{names, SupAtom, {ShardAtom, ...}}` built by
/// brazier_presence_ffi:names/2.
type Names

/// What the shards are started with (see brazier_presence_ffi:config_map).
type ShardConfig {
  ShardConfig(
    name: String,
    pool_size: Int,
    broadcast_period_ms: Int,
    max_silent_periods: Int,
    down_period_ms: Int,
    permdown_period_ms: Int,
    clock_sample_periods: Int,
    max_delta_sizes: List(Int),
    max_topics_per_pid: Int,
    max_entries_per_shard: Int,
    max_transfer_entries: Int,
  )
}

/// Request messages of brazier_presence_shard.
type Request {
  Track(pid: Pid, topic: String, key: String, meta: StoredMeta)
  Update(pid: Pid, topic: String, key: String, json: String, ref: String)
  Untrack(pid: Pid, topic: String, key: String)
  UntrackAll(pid: Pid)
  Replicas
}

/// Status of a peer replica, as `replicas` reports it.
pub type ReplicaStatus {
  Up
  Down
}

/// Upper bound for `pool_size`.
pub const max_pool_size = 128

/// Upper bound for a tracker name, in bytes.
pub const max_name_bytes = 32

/// Upper bound for a key, in bytes.
pub const max_key_bytes = 255

const diff_prefix = "presence:"

/// A tracker named `name` (1 to 32 bytes of `a-z`, `0-9` and `_`) whose
/// metas are encoded with `encode` and read back with `decoder`.
///
/// Defaults, from Phoenix.Tracker: one shard, heartbeat every 1500ms, an
/// empty heartbeat after 10 silent periods, down after 30s, permanently
/// down after 20 minutes, clocks sampled every 2 heartbeats, delta
/// generations of 100, 1000 and 10000. Brazier's limits: 1024-byte metas,
/// 100 entries per process per shard, 1,000,000 entries per shard and
/// transfers of at most 1,000,000 entries.
pub fn new(
  name: String,
  encode: fn(meta) -> json.Json,
  decoder: decode.Decoder(meta),
) -> PresenceConfig(meta) {
  PresenceConfig(
    name:,
    encode:,
    decoder:,
    pool_size: 1,
    broadcast_period_ms: 1500,
    max_silent_periods: 10,
    down_period_ms: 30_000,
    permdown_period_ms: 1_200_000,
    clock_sample_periods: 2,
    max_delta_sizes: [100, 1000, 10_000],
    max_meta_bytes: 1024,
    max_topics_per_pid: 100,
    max_entries_per_shard: 1_000_000,
    max_transfer_entries: 1_000_000,
  )
}

/// Shards per node. Must be the same on every node.
pub fn pool_size(config: PresenceConfig(m), size: Int) -> PresenceConfig(m) {
  PresenceConfig(..config, pool_size: size)
}

/// How often shards heartbeat.
pub fn broadcast_period(
  config: PresenceConfig(m),
  ms: Int,
) -> PresenceConfig(m) {
  PresenceConfig(..config, broadcast_period_ms: ms)
}

/// Heartbeats without changes before an empty keepalive is sent.
pub fn max_silent_periods(
  config: PresenceConfig(m),
  periods: Int,
) -> PresenceConfig(m) {
  PresenceConfig(..config, max_silent_periods: periods)
}

/// Silence after which a peer is down. Longer than the keepalive interval,
/// `broadcast_period × (max_silent_periods + 1)`, or idle peers would go
/// down between keepalives.
pub fn down_period(config: PresenceConfig(m), ms: Int) -> PresenceConfig(m) {
  PresenceConfig(..config, down_period_ms: ms)
}

/// Silence after which a peer's data is dropped. More than `down_period`.
pub fn permdown_period(
  config: PresenceConfig(m),
  ms: Int,
) -> PresenceConfig(m) {
  PresenceConfig(..config, permdown_period_ms: ms)
}

/// Heartbeats between checks of which peers are ahead.
pub fn clock_sample_periods(
  config: PresenceConfig(m),
  periods: Int,
) -> PresenceConfig(m) {
  PresenceConfig(..config, clock_sample_periods: periods)
}

/// Sizes of the delta generations kept for peers that fall behind:
/// positive and strictly increasing.
pub fn max_delta_sizes(
  config: PresenceConfig(m),
  sizes: List(Int),
) -> PresenceConfig(m) {
  PresenceConfig(..config, max_delta_sizes: sizes)
}

/// Largest encoded meta, in bytes.
pub fn max_meta_bytes(
  config: PresenceConfig(m),
  bytes: Int,
) -> PresenceConfig(m) {
  PresenceConfig(..config, max_meta_bytes: bytes)
}

/// Most entries one process may track on one shard.
pub fn max_topics_per_pid(
  config: PresenceConfig(m),
  limit: Int,
) -> PresenceConfig(m) {
  PresenceConfig(..config, max_topics_per_pid: limit)
}

/// Most entries one shard holds, from every node, before it refuses
/// tracks.
pub fn max_entries_per_shard(
  config: PresenceConfig(m),
  limit: Int,
) -> PresenceConfig(m) {
  PresenceConfig(..config, max_entries_per_shard: limit)
}

/// Most entries a shard accepts in one transfer from a peer. A larger one
/// is rejected and logged, and requested again at the next clock sample.
pub fn max_transfer_entries(
  config: PresenceConfig(m),
  limit: Int,
) -> PresenceConfig(m) {
  PresenceConfig(..config, max_transfer_entries: limit)
}

/// Check a configuration.
pub fn validate_config(
  config: PresenceConfig(m),
) -> Result(PresenceConfig(m), PresenceError) {
  use _ <- result.try(validate_name(config.name))
  use _ <- result.try(in_range("pool_size", config.pool_size, 1, max_pool_size))
  use _ <- result.try(positive("broadcast_period", config.broadcast_period_ms))
  use _ <- result.try(positive("max_silent_periods", config.max_silent_periods))
  use _ <- result.try(positive(
    "clock_sample_periods",
    config.clock_sample_periods,
  ))
  use _ <- result.try(positive("max_meta_bytes", config.max_meta_bytes))
  use _ <- result.try(positive("max_topics_per_pid", config.max_topics_per_pid))
  use _ <- result.try(positive(
    "max_entries_per_shard",
    config.max_entries_per_shard,
  ))
  use _ <- result.try(positive(
    "max_transfer_entries",
    config.max_transfer_entries,
  ))
  // An idle shard sends a keepalive only every keepalive_interval. A
  // down_period no longer than that marks every idle peer down between
  // keepalives, so its entries leave and rejoin over and over. Since
  // max_silent_periods >= 1 this also gives Phoenix's
  // down_period >= 2 × broadcast_period.
  let keepalive_interval =
    config.broadcast_period_ms * { config.max_silent_periods + 1 }
  use _ <- result.try(case config.down_period_ms > keepalive_interval {
    True -> Ok(Nil)
    False ->
      Error(InvalidConfig(
        "down_period ("
        <> int.to_string(config.down_period_ms)
        <> "ms) must be longer than the keepalive interval, broadcast_period × (max_silent_periods + 1) ("
        <> int.to_string(keepalive_interval)
        <> "ms)",
      ))
  })
  use _ <- result.try(case config.permdown_period_ms > config.down_period_ms {
    True -> Ok(Nil)
    False ->
      Error(InvalidConfig(
        "permdown_period ("
        <> int.to_string(config.permdown_period_ms)
        <> "ms) must be longer than down_period ("
        <> int.to_string(config.down_period_ms)
        <> "ms)",
      ))
  })
  use _ <- result.try(validate_delta_sizes(config.max_delta_sizes))
  Ok(config)
}

fn validate_name(name: String) -> Result(Nil, PresenceError) {
  let size = byte_size(name)
  let valid_chars =
    string.to_utf_codepoints(name)
    |> list.all(fn(c) {
      let code = string.utf_codepoint_to_int(c)
      { code >= 97 && code <= 122 }
      || { code >= 48 && code <= 57 }
      || code == 95
    })
  case size >= 1 && size <= max_name_bytes && valid_chars {
    True -> Ok(Nil)
    False ->
      Error(InvalidConfig(
        "name must be 1 to 32 bytes of a-z, 0-9 and _: " <> string.inspect(name),
      ))
  }
}

fn validate_delta_sizes(sizes: List(Int)) -> Result(Nil, PresenceError) {
  let invalid =
    InvalidConfig(
      "max_delta_sizes must be non-empty, positive and strictly increasing: "
      <> string.inspect(sizes),
    )
  case sizes {
    [] -> Error(invalid)
    [first, ..] -> {
      let increasing =
        list.window_by_2(sizes) |> list.all(fn(pair) { pair.0 < pair.1 })
      case first > 0 && increasing {
        True -> Ok(Nil)
        False -> Error(invalid)
      }
    }
  }
}

fn positive(field: String, value: Int) -> Result(Nil, PresenceError) {
  case value > 0 {
    True -> Ok(Nil)
    False ->
      Error(InvalidConfig(
        field <> " must be positive, got " <> int.to_string(value),
      ))
  }
}

fn in_range(
  field: String,
  value: Int,
  low: Int,
  high: Int,
) -> Result(Nil, PresenceError) {
  case value >= low && value <= high {
    True -> Ok(Nil)
    False ->
      Error(InvalidConfig(
        field
        <> " must be between "
        <> int.to_string(low)
        <> " and "
        <> int.to_string(high)
        <> ", got "
        <> int.to_string(value),
      ))
  }
}

// --- Lifecycle ---

/// Start a tracker on this node, unlinked from the caller. PubSub must be
/// running.
pub fn start(
  config: PresenceConfig(meta),
) -> Result(Presence(meta), PresenceError) {
  use config <- result.try(validate_config(config))
  let presence = make_handle(config)
  use Nil <- result.try(start_ffi(shard_config(config), presence.names))
  log.info("brazier.presence", "Started tracker " <> config.name)
  Ok(presence)
}

/// A child specification that starts the tracker linked to a supervisor.
/// Get the handle to use it with `handle`.
pub fn supervised(
  config: PresenceConfig(meta),
) -> Result(supervision.ChildSpecification(Presence(meta)), PresenceError) {
  use config <- result.try(validate_config(config))
  let presence = make_handle(config)
  let shards = shard_config(config)
  Ok(
    supervision.supervisor(fn() {
      case start_link_ffi(shards, presence.names) {
        Ok(pid) -> Ok(actor.Started(pid:, data: presence))
        Error(reason) -> Error(actor.InitFailed(describe(reason)))
      }
    }),
  )
}

/// Stop a tracker started with `start`. Its shards tell their peers, which
/// drop this node's entries at once.
pub fn stop(presence: Presence(meta)) -> Result(Nil, PresenceError) {
  stop_ffi(presence.names)
}

/// Whether the tracker runs on this node (its supervisor is registered).
/// A running tracker may still be restarting a shard: calls for that
/// shard's topics return `TrackerDown` meanwhile.
pub fn running(presence: Presence(meta)) -> Bool {
  running_ffi(presence.names)
}

/// The handle of the tracker `config` starts, for a tracker started with
/// `supervised`. It does not check that the tracker is running: calls
/// return `TrackerDown` until it is.
pub fn handle(
  config: PresenceConfig(meta),
) -> Result(Presence(meta), PresenceError) {
  use config <- result.try(validate_config(config))
  Ok(make_handle(config))
}

fn make_handle(config: PresenceConfig(meta)) -> Presence(meta) {
  Presence(
    name: config.name,
    names: names_ffi(config.name, config.pool_size),
    encode: config.encode,
    decoder: config.decoder,
    max_meta_bytes: config.max_meta_bytes,
  )
}

fn shard_config(config: PresenceConfig(meta)) -> ShardConfig {
  ShardConfig(
    name: config.name,
    pool_size: config.pool_size,
    broadcast_period_ms: config.broadcast_period_ms,
    max_silent_periods: config.max_silent_periods,
    down_period_ms: config.down_period_ms,
    permdown_period_ms: config.permdown_period_ms,
    clock_sample_periods: config.clock_sample_periods,
    max_delta_sizes: config.max_delta_sizes,
    max_topics_per_pid: config.max_topics_per_pid,
    max_entries_per_shard: config.max_entries_per_shard,
    max_transfer_entries: config.max_transfer_entries,
  )
}

/// The tracker's name.
pub fn name(presence: Presence(meta)) -> String {
  presence.name
}

// --- Tracking (always the calling process) ---

/// Track the calling process under `key` on `topic`. Returns the meta's
/// ref.
pub fn track(
  presence: Presence(meta),
  topic: String,
  key: String,
  meta: meta,
) -> Result(String, PresenceError) {
  use _ <- result.try(validate_topic(presence, topic))
  use _ <- result.try(validate_key(key))
  use encoded <- result.try(encode_meta(presence, topic, meta))
  let ref = new_ref()
  let stored = StoredMeta(json: encoded, ref:, ref_prev: option.None)
  use Nil <- result.try(call_ffi(
    presence.names,
    topic,
    Track(process.self(), topic, key, stored),
  ))
  Ok(ref)
}

/// Replace the meta the calling process tracks under `key` on `topic`.
/// Returns the new ref; the old one becomes `ref_prev`.
pub fn update(
  presence: Presence(meta),
  topic: String,
  key: String,
  meta: meta,
) -> Result(String, PresenceError) {
  use _ <- result.try(validate_topic(presence, topic))
  use _ <- result.try(validate_key(key))
  use encoded <- result.try(encode_meta(presence, topic, meta))
  let ref = new_ref()
  use Nil <- result.try(call_ffi(
    presence.names,
    topic,
    Update(process.self(), topic, key, encoded, ref),
  ))
  Ok(ref)
}

/// Stop tracking the calling process under `key` on `topic`.
pub fn untrack(
  presence: Presence(meta),
  topic: String,
  key: String,
) -> Result(Nil, PresenceError) {
  use _ <- result.try(validate_topic(presence, topic))
  use _ <- result.try(validate_key(key))
  call_ffi(presence.names, topic, Untrack(process.self(), topic, key))
}

/// Stop tracking the calling process everywhere on this tracker.
pub fn untrack_all(presence: Presence(meta)) -> Result(Nil, PresenceError) {
  call_all_ffi(presence.names, UntrackAll(process.self()))
}

fn encode_meta(
  presence: Presence(meta),
  topic: String,
  meta: meta,
) -> Result(String, PresenceError) {
  let encoded = json.to_string(presence.encode(meta))
  let bytes = byte_size(encoded)
  case bytes > presence.max_meta_bytes {
    True -> {
      log.warning(
        "brazier.presence",
        "Tracker "
          <> presence.name
          <> " refused a meta of "
          <> int.to_string(bytes)
          <> " bytes (max_meta_bytes "
          <> int.to_string(presence.max_meta_bytes)
          <> ")",
      )
      telemetry.presence_event(
        telemetry.LimitExceeded,
        1,
        presence.name,
        shard_index_ffi(presence.names, topic),
      )
      Error(MetaTooLarge(bytes))
    }
    False ->
      // Every reader decodes the stored JSON, so a meta the decoder cannot
      // read back is refused here instead of failing every read later.
      case json.parse(encoded, presence.decoder) {
        Ok(_) -> Ok(encoded)
        Error(error) -> Error(MetaDecodeFailed(string.inspect(error)))
      }
  }
}

/// 8 random bytes, base64url without padding (Phoenix.Presence's phx_ref).
fn new_ref() -> String {
  bit_array.base64_url_encode(crypto.strong_random_bytes(8), False)
}

/// The largest topic this tracker accepts: its diff topic
/// (`presence:<name>:<topic>`) must fit PubSub's 255 bytes.
pub fn max_topic_bytes(presence: Presence(meta)) -> Int {
  255 - byte_size(diff_prefix <> presence.name <> ":")
}

fn validate_topic(
  presence: Presence(meta),
  topic: String,
) -> Result(Nil, PresenceError) {
  let size = byte_size(topic)
  case size >= 1 && size <= max_topic_bytes(presence) {
    True -> Ok(Nil)
    False -> Error(InvalidTopic(topic))
  }
}

fn validate_key(key: String) -> Result(Nil, PresenceError) {
  let size = byte_size(key)
  case size >= 1 && size <= max_key_bytes {
    True -> Ok(Nil)
    False -> Error(InvalidKey(key))
  }
}

// --- Reads (ETS, no shard call) ---

/// Everything tracked on `topic` on reachable nodes, by key.
pub fn list(
  presence: Presence(meta),
  topic: String,
) -> Result(List(Entry(meta)), PresenceError) {
  use _ <- result.try(validate_topic(presence, topic))
  use rows <- result.try(list_ffi(presence.names, topic))
  entries(presence, rows)
}

/// What is tracked under `key` on `topic`. `Error(NotTracked)` if nothing.
pub fn get_by_key(
  presence: Presence(meta),
  topic: String,
  key: String,
) -> Result(Entry(meta), PresenceError) {
  use _ <- result.try(validate_topic(presence, topic))
  use _ <- result.try(validate_key(key))
  use rows <- result.try(get_by_key_ffi(presence.names, topic, key))
  use found <- result.try(entries(presence, rows))
  case found {
    [] -> Error(NotTracked)
    _ -> {
      // INVARIANT: the match spec selects rows of this one key only, so
      // they group into a single entry.
      let assert [entry] = found as "get_by_key rows all have the same key"
      Ok(entry)
    }
  }
}

/// Group rows that are consecutive per key (ETS order, or sorted diffs).
fn entries(
  presence: Presence(meta),
  rows: List(#(String, Pid, String, StoredMeta)),
) -> Result(List(Entry(meta)), PresenceError) {
  use decoded <- result.try(
    list.try_map(rows, fn(row) {
      let #(key, _pid, node, stored) = row
      case json.parse(stored.json, presence.decoder) {
        Ok(value) ->
          Ok(#(
            key,
            Meta(value:, ref: stored.ref, ref_prev: stored.ref_prev, node:),
          ))
        Error(error) -> {
          log.error(
            "brazier.presence",
            "Tracker "
              <> presence.name
              <> " cannot decode the meta of "
              <> key
              <> " from "
              <> node
              <> ": "
              <> string.inspect(error),
          )
          Error(MetaDecodeFailed(string.inspect(error)))
        }
      }
    }),
  )
  decoded
  |> list.chunk(fn(pair) { pair.0 })
  |> list.map(fn(group) {
    // INVARIANT: list.chunk never yields an empty group.
    let assert [#(key, _), ..] = group as "list.chunk groups are non-empty"
    Entry(key:, metas: list.map(group, fn(pair) { pair.1 }))
  })
  |> Ok
}

// --- Diffs ---

/// The PubSub topic diffs for `topic` are delivered on.
pub fn diff_topic(presence: Presence(meta), topic: String) -> String {
  diff_prefix <> presence.name <> ":" <> topic
}

/// Receive this node's diffs for `topic` as
/// `{brazier_pubsub, diff_topic(presence, topic), Diff}`.
pub fn subscribe(
  presence: Presence(meta),
  topic: String,
) -> Result(Nil, PresenceError) {
  use _ <- result.try(validate_topic(presence, topic))
  pubsub.try_subscribe(diff_topic(presence, topic))
  |> result.map_error(fn(error) {
    log.error(
      "brazier.presence",
      "Subscribing to diffs of "
        <> topic
        <> " failed: "
        <> pubsub.describe(error),
    )
    pubsub_error(error)
  })
}

pub fn unsubscribe(
  presence: Presence(meta),
  topic: String,
) -> Result(Nil, PresenceError) {
  use _ <- result.try(validate_topic(presence, topic))
  pubsub.try_unsubscribe(diff_topic(presence, topic))
  |> result.map_error(fn(error) {
    log.error(
      "brazier.presence",
      "Unsubscribing from diffs of "
        <> topic
        <> " failed: "
        <> pubsub.describe(error),
    )
    pubsub_error(error)
  })
}

fn pubsub_error(error: pubsub.PubSubError) -> PresenceError {
  case error {
    pubsub.TooManySubscriptions(limit) ->
      PresenceLimitExceeded(
        "max_topics_per_subscriber (" <> int.to_string(limit) <> ")",
      )
    pubsub.InvalidTopic(topic) -> InvalidTopic(topic)
    other -> PubSubFailed(pubsub.describe(other))
  }
}

/// Decode the message part of a diff delivery.
pub fn decode_diff(
  presence: Presence(meta),
  message: Dynamic,
) -> Result(Diff(meta), PresenceError) {
  use #(topic, joins, leaves) <- result.try(decode_diff_ffi(
    presence.name,
    message,
  ))
  use joins <- result.try(entries(presence, sort_rows(joins)))
  use leaves <- result.try(entries(presence, sort_rows(leaves)))
  Ok(Diff(topic:, joins:, leaves:))
}

fn sort_rows(
  rows: List(#(String, Pid, String, StoredMeta)),
) -> List(#(String, Pid, String, StoredMeta)) {
  list.sort(rows, fn(a, b) { string.compare(a.0, b.0) })
}

// --- Introspection ---

/// The shard process for `topic`. Tracked processes monitor it: if it
/// dies, their entries are gone and they must track again.
pub fn shard_pid(
  presence: Presence(meta),
  topic: String,
) -> Result(Pid, PresenceError) {
  shard_pid_ffi(presence.names, topic)
}

/// The peers the shard for `topic` knows, by node name.
pub fn replicas(
  presence: Presence(meta),
  topic: String,
) -> Result(List(#(String, ReplicaStatus)), PresenceError) {
  replicas_ffi(presence.names, topic, Replicas)
}

/// A readable description of an error.
pub fn describe(error: PresenceError) -> String {
  case error {
    MetaTooLarge(bytes) ->
      "presence meta too large: " <> int.to_string(bytes) <> " bytes"
    PresenceLimitExceeded(limit) -> "presence limit reached: " <> limit
    InvalidTopic(topic) ->
      "invalid presence topic: " <> int.to_string(byte_size(topic)) <> " bytes"
    InvalidKey(key) ->
      "invalid presence key (must be 1 to 255 bytes): "
      <> int.to_string(byte_size(key))
      <> " bytes"
    AlreadyTracked -> "already tracked"
    NotTracked -> "not tracked"
    TrackerDown -> "presence tracker is not running"
    TrackerTimeout -> "presence tracker did not answer in time"
    InvalidConfig(reason) -> "invalid presence config: " <> reason
    StartFailed(reason) -> "presence tracker failed to start: " <> reason
    StopFailed(reason) -> "presence tracker failed to stop: " <> reason
    MetaDecodeFailed(reason) -> "presence meta does not decode: " <> reason
    InvalidMessage -> "not a presence diff of this tracker"
    PubSubFailed(reason) -> "presence diff subscription failed: " <> reason
  }
}

// --- Erlang FFI ---

@external(erlang, "brazier_presence_ffi", "names")
fn names_ffi(name: String, pool_size: Int) -> Names

@external(erlang, "brazier_presence_ffi", "start")
fn start_ffi(config: ShardConfig, names: Names) -> Result(Nil, PresenceError)

@external(erlang, "brazier_presence_ffi", "running")
fn running_ffi(names: Names) -> Bool

@external(erlang, "brazier_presence_ffi", "start_link")
fn start_link_ffi(
  config: ShardConfig,
  names: Names,
) -> Result(Pid, PresenceError)

@external(erlang, "brazier_presence_ffi", "stop")
fn stop_ffi(names: Names) -> Result(Nil, PresenceError)

@external(erlang, "brazier_presence_ffi", "call")
fn call_ffi(
  names: Names,
  topic: String,
  request: Request,
) -> Result(Nil, PresenceError)

@external(erlang, "brazier_presence_ffi", "call")
fn replicas_ffi(
  names: Names,
  topic: String,
  request: Request,
) -> Result(List(#(String, ReplicaStatus)), PresenceError)

@external(erlang, "brazier_presence_ffi", "call_all")
fn call_all_ffi(names: Names, request: Request) -> Result(Nil, PresenceError)

@external(erlang, "brazier_presence_ffi", "list")
fn list_ffi(
  names: Names,
  topic: String,
) -> Result(List(#(String, Pid, String, StoredMeta)), PresenceError)

@external(erlang, "brazier_presence_ffi", "get_by_key")
fn get_by_key_ffi(
  names: Names,
  topic: String,
  key: String,
) -> Result(List(#(String, Pid, String, StoredMeta)), PresenceError)

@external(erlang, "brazier_presence_ffi", "shard_pid")
fn shard_pid_ffi(names: Names, topic: String) -> Result(Pid, PresenceError)

@external(erlang, "brazier_presence_ffi", "shard_index")
fn shard_index_ffi(names: Names, topic: String) -> Int

@external(erlang, "brazier_presence_ffi", "decode_diff")
fn decode_diff_ffi(
  name: String,
  message: Dynamic,
) -> Result(
  #(
    String,
    List(#(String, Pid, String, StoredMeta)),
    List(#(String, Pid, String, StoredMeta)),
  ),
  PresenceError,
)

@external(erlang, "erlang", "byte_size")
fn byte_size(string: String) -> Int
