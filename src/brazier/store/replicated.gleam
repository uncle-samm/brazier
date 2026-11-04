//// Replicated mode for `brazier/store`: every node of the cluster keeps a
//// full replica of the store and the replicas converge.
////
//// Open a replicated store with `store.open(name, store.Replicated(config))`
//// (or `store.open_list`). This module holds its configuration, its error
//// types and the calls into the replica process (`brazier_store_replica`);
//// applications use the `brazier/store` API, which is the same in both
//// modes.
////
//// How it works (see docs/CLUSTERING.md):
////
//// - Each node runs one replica process per replicated store. It holds an
////   add-wins last-writer-wins map (`brazier/store/crdt`, a port of
////   delta_crdt_ex's AWLWWMap) and mirrors it into ETS, so reads never
////   leave the node or call the replica.
//// - A write is a call to the local replica. It is applied there, then its
////   delta is broadcast to the other replicas over `brazier/pubsub`.
//// - Every `sync_interval_ms` each replica broadcasts a digest of its
////   state. A replica whose state differs pulls the sender's full state,
////   which repairs every delta lost to a partition or a crash. A replica
////   that starts (a node joining, rejoining or a replica restarting) asks
////   every peer for its full state at once.
//// - Writes are ordered by a hybrid logical clock (`brazier/store/hlc`):
////   concurrent writes of one key resolve to the greatest
////   `(timestamp, node, dot)` on every node, and a delete never removes a
////   value written concurrently on another node (add wins).
//// - Every limit is checked on the writer (the write returns an error) and
////   on every receiver (the merge is refused and logged).

import brazier/log
import brazier/state_manager
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string

/// Replicated store settings. Build one from `default_config()` with a
/// record update, e.g. `Config(..replicated.default_config(), max_entries: 50_000)`.
pub type Config {
  Config(
    /// How often each replica broadcasts its digest (the anti-entropy
    /// period): the longest a lost delta stays lost once nodes can talk.
    sync_interval_ms: Int,
    /// The most entries a replica holds: keys of a key-value store, values
    /// of a list store (counting concurrent values of one key until the
    /// next write replaces them).
    max_entries: Int,
    /// The largest value (with its key), as `erlang:external_size/1`.
    max_value_bytes: Int,
    /// The largest delta a write may produce or a replica may merge.
    max_delta_bytes: Int,
    /// The largest full state a replica sends or merges.
    max_sync_bytes: Int,
  )
}

/// Defaults: a digest every second, 100_000 entries, 64 KiB values, 1 MiB
/// deltas and 64 MiB full syncs.
pub fn default_config() -> Config {
  Config(
    sync_interval_ms: 1000,
    max_entries: 100_000,
    max_value_bytes: 64 * 1024,
    max_delta_bytes: 1024 * 1024,
    max_sync_bytes: 64 * 1024 * 1024,
  )
}

/// Why a write to a store failed. A node-local store never fails a write
/// except for an invalid per-key topic.
pub type WriteError {
  /// The write would grow the replica past `max_entries`.
  TooManyEntries(limit: Int)
  /// A value is larger than `max_value_bytes`.
  ValueTooLarge(bytes: Int, limit: Int)
  /// The write's delta is larger than `max_delta_bytes`.
  DeltaTooLarge(bytes: Int, limit: Int)
  /// The local replica did not answer (not running, restarting or stuck).
  Unavailable(reason: String)
  /// The per-key topic `prefix <> key` is not a valid PubSub topic.
  InvalidTopic(topic: String)
}

/// Why a replicated store could not be opened.
pub type StartError {
  /// The name is not 1-200 bytes of `[A-Za-z0-9_-]`.
  InvalidName(name: String, reason: String)
  /// The configuration is out of range, or the store is already open in
  /// local mode or with a different configuration.
  InvalidConfig(reason: String)
  /// The replica process failed to start.
  StartFailed(reason: String)
}

/// The kind of store a replica holds.
pub type Kind {
  KeyValue
  List
}

/// The registered replica process of one store on this node.
pub type Server

/// The longest replicated store name, in bytes (its PubSub topic
/// `brazier_store:list:<name>` must stay within 255 bytes).
pub const max_name_bytes = 200

const max_entries_limit = 10_000_000

const max_sync_bytes_limit = 1_073_741_824

/// Check a configuration's ranges.
pub fn validate_config(config: Config) -> Result(Config, StartError) {
  let Config(
    sync_interval_ms:,
    max_entries:,
    max_value_bytes:,
    max_delta_bytes:,
    max_sync_bytes:,
  ) = config
  let problem = case Nil {
    _ if sync_interval_ms < 10 || sync_interval_ms > 3_600_000 ->
      Error(
        "sync_interval_ms must be 10..3600000, got "
        <> int.to_string(sync_interval_ms),
      )
    _ if max_entries < 1 || max_entries > max_entries_limit ->
      Error(
        "max_entries must be 1.."
        <> int.to_string(max_entries_limit)
        <> ", got "
        <> int.to_string(max_entries),
      )
    _ if max_value_bytes < 1 || max_value_bytes >= max_delta_bytes ->
      Error(
        "max_value_bytes must be at least 1 and below max_delta_bytes, got "
        <> int.to_string(max_value_bytes),
      )
    _ if max_delta_bytes > max_sync_bytes ->
      Error(
        "max_delta_bytes must not exceed max_sync_bytes, got "
        <> int.to_string(max_delta_bytes),
      )
    _ if max_sync_bytes > max_sync_bytes_limit ->
      Error(
        "max_sync_bytes must be at most "
        <> int.to_string(max_sync_bytes_limit)
        <> ", got "
        <> int.to_string(max_sync_bytes),
      )
    _ -> Ok(config)
  }
  case problem {
    Ok(config) -> Ok(config)
    Error(reason) -> {
      log.error("brazier.store.replicated", "Invalid configuration: " <> reason)
      Error(InvalidConfig(reason))
    }
  }
}

/// Start this node's replica of a store (or return the running one, when
/// it was started with the same configuration), with the ETS table its
/// values are mirrored into.
pub fn start(
  kind: Kind,
  name: String,
  config: Config,
) -> Result(#(Server, state_manager.EtsTable), StartError) {
  log.info(
    "brazier.store.replicated",
    "Opening replicated " <> kind_name(kind) <> " store " <> name,
  )
  case validate_name(name), validate_config(config) {
    Error(err), _ -> Error(err)
    _, Error(err) -> Error(err)
    Ok(Nil), Ok(config) -> start_ffi(kind, name, config)
  }
}

fn validate_name(name: String) -> Result(Nil, StartError) {
  let size = string.byte_size(name)
  let reason = case size >= 1 && size <= max_name_bytes, is_atom_safe(name) {
    False, _ ->
      Error(
        "Invalid name: must be 1 to "
        <> int.to_string(max_name_bytes)
        <> " bytes",
      )
    True, False ->
      Error("Invalid name: must be alphanumeric, underscore, or hyphen")
    True, True -> Ok(Nil)
  }
  case reason {
    Ok(Nil) -> Ok(Nil)
    Error(reason) -> {
      let err = InvalidName(name: name, reason: reason)
      log.error(
        "brazier.store.replicated",
        "Cannot open store: " <> describe_start_error(err),
      )
      Error(err)
    }
  }
}

fn is_atom_safe(name: String) -> Bool {
  string.to_utf_codepoints(name)
  |> list.all(fn(cp) {
    let c = string.utf_codepoint_to_int(cp)
    { c >= 48 && c <= 57 }
    || { c >= 65 && c <= 90 }
    || { c >= 97 && c <= 122 }
    || c == 95
    || c == 45
  })
}

fn kind_name(kind: Kind) -> String {
  case kind {
    KeyValue -> "key-value"
    List -> "list"
  }
}

// --- Writes ---

/// Set `key` to `value` (key-value stores).
pub fn put(
  server: Server,
  key: String,
  value: value,
) -> Result(Nil, WriteError) {
  logged("put", key, put_ffi(server, key, value))
}

/// Remove every value of `key` this replica has seen; `topics` are
/// notified on the nodes that merge the removal.
pub fn remove(
  server: Server,
  key: String,
  topics: List(String),
) -> Result(Nil, WriteError) {
  logged("remove", key, remove_ffi(server, key, topics))
}

/// Add values to `key` (list stores); `topics` are notified on the nodes
/// that merge them, whenever they merge them.
pub fn append(
  server: Server,
  key: String,
  values: List(value),
  topics: List(String),
) -> Result(Nil, WriteError) {
  logged("append", key, append_ffi(server, key, values, topics))
}

fn logged(
  op: String,
  key: String,
  outcome: Result(Nil, WriteError),
) -> Result(Nil, WriteError) {
  case outcome {
    Ok(Nil) -> log.debug("brazier.store.replicated", op <> ": " <> key)
    Error(err) ->
      log.error(
        "brazier.store.replicated",
        op <> " of " <> key <> " failed: " <> describe_write_error(err),
      )
  }
  outcome
}

/// A human-readable description of a write error.
pub fn describe_write_error(err: WriteError) -> String {
  case err {
    TooManyEntries(limit:) ->
      "store is full (max_entries " <> int.to_string(limit) <> ")"
    ValueTooLarge(bytes:, limit:) ->
      "value of "
      <> int.to_string(bytes)
      <> " bytes exceeds max_value_bytes "
      <> int.to_string(limit)
    DeltaTooLarge(bytes:, limit:) ->
      "delta of "
      <> int.to_string(bytes)
      <> " bytes exceeds max_delta_bytes "
      <> int.to_string(limit)
    Unavailable(reason:) -> "replica unavailable: " <> reason
    InvalidTopic(topic:) -> "invalid per-key topic: " <> topic
  }
}

/// A human-readable description of a start error.
pub fn describe_start_error(err: StartError) -> String {
  case err {
    InvalidName(name:, reason:) ->
      "invalid store name \"" <> name <> "\": " <> reason
    InvalidConfig(reason:) -> "invalid configuration: " <> reason
    StartFailed(reason:) -> "replica failed to start: " <> reason
  }
}

// --- Reads (from the ETS mirror; an error means the replica is down) ---

/// The value of `key` in a key-value store's mirror.
pub fn get(
  table: state_manager.EtsTable,
  key: String,
) -> Result(Option(value), String) {
  read_get_ffi(table, key)
}

/// Every value of `key` in a list store's mirror, in timestamp order.
pub fn get_all(
  table: state_manager.EtsTable,
  key: String,
) -> Result(List(value), String) {
  read_get_all_ffi(table, key)
}

/// The number of keys in a key-value store's mirror.
pub fn count(table: state_manager.EtsTable) -> Result(Int, String) {
  read_count_ffi(table)
}

// --- Introspection (tests, debugging) ---

/// A hash of the replica's whole state: two replicas have converged when
/// their digests are equal.
pub fn digest(server: Server) -> Result(BitArray, WriteError) {
  digest_ffi(server)
}

/// The number of entries the replica holds.
pub fn size(server: Server) -> Result(Int, WriteError) {
  size_ffi(server)
}

/// Stop this node's replica of a store and its supervisor. Its ETS mirror
/// goes with it.
pub fn stop(server: Server) -> Result(Nil, String) {
  log.info("brazier.store.replicated", "Stopping a replica")
  stop_ffi(server)
}

// --- FFI ---

@external(erlang, "brazier_store_replica", "start")
fn start_ffi(
  kind: Kind,
  name: String,
  config: Config,
) -> Result(#(Server, state_manager.EtsTable), StartError)

@external(erlang, "brazier_store_replica", "put")
fn put_ffi(server: Server, key: String, value: value) -> Result(Nil, WriteError)

@external(erlang, "brazier_store_replica", "remove")
fn remove_ffi(
  server: Server,
  key: String,
  topics: List(String),
) -> Result(Nil, WriteError)

@external(erlang, "brazier_store_replica", "append")
fn append_ffi(
  server: Server,
  key: String,
  values: List(value),
  topics: List(String),
) -> Result(Nil, WriteError)

@external(erlang, "brazier_store_replica", "digest")
fn digest_ffi(server: Server) -> Result(BitArray, WriteError)

@external(erlang, "brazier_store_replica", "size")
fn size_ffi(server: Server) -> Result(Int, WriteError)

@external(erlang, "brazier_store_replica", "stop")
fn stop_ffi(server: Server) -> Result(Nil, String)

@external(erlang, "brazier_store_replica", "read_get")
fn read_get_ffi(
  table: state_manager.EtsTable,
  key: String,
) -> Result(Option(value), String)

@external(erlang, "brazier_store_replica", "read_get_all")
fn read_get_all_ffi(
  table: state_manager.EtsTable,
  key: String,
) -> Result(List(value), String)

@external(erlang, "brazier_store_replica", "read_count")
fn read_count_ffi(table: state_manager.EtsTable) -> Result(Int, String)
