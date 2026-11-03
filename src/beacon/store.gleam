/// Shared state store — provides ETS-backed storage without user FFI.
/// Stores auto-broadcast via PubSub when data changes.
///
/// A store runs in one of two modes, chosen when it is opened:
///
/// - `Local` (the default, and what `new` / `new_list` open): each node
///   has its own table. Change notifications use `pubsub.local_broadcast`,
///   so they reach only watchers on the node whose table changed.
/// - `Replicated(config)` (opt-in, `open` / `open_list`): every node keeps
///   a full replica and the replicas converge (see
///   `beacon/store/replicated` and docs/CLUSTERING.md). A write on any node
///   is applied locally, then replicated; watchers on every node are
///   notified when the change reaches their node.
///
/// To react to changes, return `store.topic(s)` / `store.list_topic(s)` from
/// `beacon.subscriptions` and handle it in `beacon.on_notify`.
///
/// - `Store` — key-value (one value per key)
/// - `ListStore` — any number of values per key, duplicates kept, like chat
///   messages. Local list stores keep insertion order; replicated ones keep
///   timestamp order, which is insertion order for writes from one node.
///
/// Opening is idempotent: opening the same name again (from any process)
/// returns a handle to the same data. A name is open in one mode only:
/// opening it in the other mode is an error.
///
/// Writes come in two forms. `put`, `delete`, `append`, ... return `Nil`
/// and crash the caller (after logging) if the write fails; `try_put`,
/// `try_delete`, `try_append`, ... return the failure. A local write only
/// fails for an invalid per-key topic; a replicated one also fails when a
/// limit is reached or the local replica is down.
import beacon/log
import beacon/pubsub
import beacon/state_manager
import beacon/store/replicated
import beacon/telemetry
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// Why a store could not be created. Names must be 1-255 bytes of
/// `[A-Za-z0-9_-]` once prefixed (they become ETS table atoms).
pub type StoreError =
  state_manager.EtsError

/// Where a store's data lives.
pub type Mode {
  /// One table per node; writes and notifications stay on the node.
  Local
  /// A replica on every node that opens the store, kept convergent.
  Replicated(replicated.Config)
}

/// Why `open` / `open_list` failed.
pub type OpenError {
  /// The name is invalid, or a table of that name exists with another type.
  InvalidStore(StoreError)
  /// The replicated configuration is out of range, or the store is already
  /// open in another mode or with a different configuration.
  InvalidConfig(reason: String)
  /// The replica process failed to start.
  StartFailed(reason: String)
}

/// Why a write failed (see `beacon/store/replicated.WriteError`).
pub type WriteError =
  replicated.WriteError

/// How a store's writes are applied.
pub opaque type Writer {
  LocalWriter
  ReplicatedWriter(server: replicated.Server)
}

/// A key-value store backed by ETS.
/// Auto-broadcasts on put/delete.
pub type Store(value) {
  Store(manager: state_manager.EtsManager, topic: String, writer: Writer)
}

/// Create (or reuse) a local key-value store, returning a typed error for
/// an invalid name.
pub fn try_new(name: String) -> Result(Store(value), StoreError) {
  log.debug("beacon.store", "Opening store: " <> name)
  case open_table(name, "beacon_store_", state_manager.EtsSet) {
    Ok(table) ->
      Ok(Store(
        manager: state_manager.EtsManager(table: table),
        topic: "store:" <> name,
        writer: LocalWriter,
      ))
    Error(err) -> Error(err)
  }
}

/// Create (or reuse) a local key-value store. Calling it again with the
/// same name returns the same store.
///
/// Store names are developer-supplied constants, so a failure (an invalid
/// name) is a programming error: it is logged and crashes the caller
/// loudly. Use `try_new` to handle it as a value.
pub fn new(name: String) -> Store(value) {
  let result = try_new(name)
  // Invariant: store names are compile-time constants; an invalid one is a
  // bug to surface at startup (already logged by state_manager.ensure_table).
  let assert Ok(store) = result as "beacon.store.new failed"
  store
}

/// Open (or reuse) a key-value store in the given mode.
pub fn open(name: String, mode: Mode) -> Result(Store(value), OpenError) {
  log.info(
    "beacon.store",
    "Opening store " <> name <> " (" <> mode_name(mode) <> ")",
  )
  case mode {
    Local -> result.map_error(try_new(name), InvalidStore)
    Replicated(config) -> {
      use #(server, table) <- result.try(start_replica(
        replicated.KeyValue,
        name,
        config,
      ))
      Ok(Store(
        manager: state_manager.EtsManager(table: table),
        topic: "store:" <> name,
        writer: ReplicatedWriter(server),
      ))
    }
  }
}

fn start_replica(
  kind: replicated.Kind,
  name: String,
  config: replicated.Config,
) -> Result(#(replicated.Server, state_manager.EtsTable), OpenError) {
  replicated.start(kind, name, config)
  |> result.map_error(fn(err) {
    case err {
      replicated.InvalidName(err) -> InvalidStore(err)
      replicated.InvalidConfig(reason) -> InvalidConfig(reason)
      replicated.StartFailed(reason) -> StartFailed(reason)
    }
  })
}

fn mode_name(mode: Mode) -> String {
  case mode {
    Local -> "local"
    Replicated(_) -> "replicated"
  }
}

/// Validate a store name and open its namespaced table. Prefixes keep a
/// store from ever aliasing a framework table (sessions, rate limits, ...)
/// or a list store of the same name.
fn open_table(
  name: String,
  prefix: String,
  table_type: state_manager.EtsTableType,
) -> Result(state_manager.EtsTable, StoreError) {
  case name {
    "" -> {
      let err =
        state_manager.InvalidTableName(
          name: name,
          reason: "Invalid name: must not be empty",
        )
      log.error(
        "beacon.store",
        "Cannot open store: " <> state_manager.describe_ets_error(err),
      )
      Error(err)
    }
    _ -> state_manager.ensure_table(prefix <> name, table_type)
  }
}

/// Get a value by key.
///
/// A replicated store reads its node's replica. If that replica is down
/// (restarting), the read is logged and crashes the caller.
pub fn get(store: Store(value), key: String) -> Result(value, Nil) {
  log.debug("beacon.store", "get")
  case store.writer {
    LocalWriter -> state_manager.ets_get(store.manager, key)
    ReplicatedWriter(_) -> {
      let found = replicated_read(replicated.get(store.manager.table, key))
      case found {
        Some(value) -> Ok(value)
        None -> Error(Nil)
      }
    }
  }
}

/// Set a value by key. Auto-broadcasts to watchers. Crashes the caller
/// (after logging) if the write fails; see `try_put`.
pub fn put(store: Store(value), key: String, value: value) -> Nil {
  or_crash("put", try_put(store, key, value))
}

/// Set a value by key, returning why the write failed.
pub fn try_put(
  store: Store(value),
  key: String,
  value: value,
) -> Result(Nil, WriteError) {
  log.debug("beacon.store", "put: " <> key)
  use Nil <- result.try(case store.writer {
    LocalWriter -> Ok(state_manager.ets_put(store.manager, key, value))
    ReplicatedWriter(server) -> replicated.put(server, key, value)
  })
  wrote(store.topic, store.writer, "put", 1)
  notify(store.topic)
  Ok(Nil)
}

/// Delete a value by key. Auto-broadcasts to watchers. Crashes the caller
/// (after logging) if the write fails; see `try_delete`.
pub fn delete(store: Store(value), key: String) -> Nil {
  or_crash("delete", try_delete(store, key))
}

/// Delete a value by key, returning why the write failed. In a replicated
/// store a value written concurrently on another node survives the delete.
pub fn try_delete(store: Store(value), key: String) -> Result(Nil, WriteError) {
  log.debug("beacon.store", "delete: " <> key)
  use Nil <- result.try(case store.writer {
    LocalWriter -> Ok(state_manager.ets_delete(store.manager, key))
    ReplicatedWriter(server) -> replicated.remove(server, key, [])
  })
  wrote(store.topic, store.writer, "delete", 1)
  notify(store.topic)
  Ok(Nil)
}

/// Count total entries. Reads like `get`.
pub fn count(store: Store(value)) -> Int {
  log.debug("beacon.store", "count")
  case store.writer {
    LocalWriter -> state_manager.ets_count(store.manager)
    ReplicatedWriter(_) ->
      replicated_read(replicated.count(store.manager.table))
  }
}

/// Get the PubSub topic for this store (return it from `beacon.subscriptions`).
pub fn topic(store: Store(value)) -> String {
  store.topic
}

/// A list store — any number of values per key. Appending the same value
/// twice stores it twice. Auto-broadcasts on append/delete.
///
/// A local list store is an ETS `duplicate_bag` and `get_all` returns
/// values in insertion order. A replicated one returns them in timestamp
/// order (see `open_list`).
pub type ListStore(value) {
  ListStore(table: state_manager.EtsTable, topic: String, writer: Writer)
}

/// Create (or reuse) a local list store, returning a typed error for an
/// invalid name.
pub fn try_new_list(name: String) -> Result(ListStore(value), StoreError) {
  log.debug("beacon.store", "Opening list store: " <> name)
  case open_table(name, "beacon_ls_", state_manager.EtsDuplicateBag) {
    Ok(table) ->
      Ok(ListStore(table: table, topic: "store:" <> name, writer: LocalWriter))
    Error(err) -> Error(err)
  }
}

/// Create (or reuse) a local list store. Calling it again with the same
/// name returns the same store.
///
/// A failure (an invalid name) is a programming error: it is logged and
/// crashes the caller loudly. Use `try_new_list` to handle it as a value.
pub fn new_list(name: String) -> ListStore(value) {
  let result = try_new_list(name)
  // Invariant: list store names are compile-time constants; see `new`.
  let assert Ok(store) = result as "beacon.store.new_list failed"
  store
}

/// Open (or reuse) a list store in the given mode.
///
/// A replicated list store orders the values of a key by the hybrid
/// logical clock timestamp of their append: insertion order for appends
/// made on one node, and the same order on every node for concurrent
/// appends on different nodes.
pub fn open_list(
  name: String,
  mode: Mode,
) -> Result(ListStore(value), OpenError) {
  log.info(
    "beacon.store",
    "Opening list store " <> name <> " (" <> mode_name(mode) <> ")",
  )
  case mode {
    Local -> result.map_error(try_new_list(name), InvalidStore)
    Replicated(config) -> {
      use #(server, table) <- result.try(start_replica(
        replicated.List,
        name,
        config,
      ))
      Ok(ListStore(
        table: table,
        topic: "store:" <> name,
        writer: ReplicatedWriter(server),
      ))
    }
  }
}

/// Append a value. Auto-broadcasts to store-level watchers. Crashes the
/// caller (after logging) if the write fails; see `try_append`.
pub fn append(store: ListStore(value), key: String, value: value) -> Nil {
  or_crash("append", try_append(store, key, value))
}

/// Append a value, returning why the write failed.
pub fn try_append(
  store: ListStore(value),
  key: String,
  value: value,
) -> Result(Nil, WriteError) {
  log.debug("beacon.store", "append")
  use Nil <- result.try(append_values(store, key, [value], []))
  wrote(store.topic, store.writer, "append", 1)
  notify(store.topic)
  Ok(Nil)
}

/// Append multiple values at once. Only broadcasts ONCE after all inserts.
/// Use this instead of calling append() in a loop. Crashes the caller
/// (after logging) if the write fails; see `try_append_many`.
pub fn append_many(
  store: ListStore(value),
  key: String,
  values: List(value),
) -> Nil {
  or_crash("append_many", try_append_many(store, key, values))
}

/// Append multiple values at once, returning why the write failed. In a
/// replicated store the values are one write: all of them or none.
pub fn try_append_many(
  store: ListStore(value),
  key: String,
  values: List(value),
) -> Result(Nil, WriteError) {
  log.debug("beacon.store", "append_many")
  use Nil <- result.try(append_values(store, key, values, []))
  wrote(store.topic, store.writer, "append", list.length(values))
  notify(store.topic)
  Ok(Nil)
}

/// Append a value and broadcast to both the store topic AND a per-key topic.
/// The per-key topic is `prefix <> key` (e.g., "room:" <> "general" = "room:general").
/// Use with `beacon.subscriptions()` for dynamic per-key subscriptions.
/// Crashes the caller (after logging) if the write fails; see
/// `try_append_notify`.
pub fn append_notify(
  store: ListStore(value),
  key: String,
  value: value,
  topic_prefix: String,
) -> Nil {
  or_crash("append_notify", try_append_notify(store, key, value, topic_prefix))
}

/// `append_notify`, returning why the write failed. The per-key topic is
/// checked before the write, so an invalid one writes nothing.
pub fn try_append_notify(
  store: ListStore(value),
  key: String,
  value: value,
  topic_prefix: String,
) -> Result(Nil, WriteError) {
  log.debug("beacon.store", "append_notify")
  use key_topic <- result.try(key_topic(topic_prefix, key))
  use Nil <- result.try(append_values(store, key, [value], [key_topic]))
  wrote(store.topic, store.writer, "append", 1)
  notify(store.topic)
  notify(key_topic)
  Ok(Nil)
}

fn append_values(
  store: ListStore(value),
  key: String,
  values: List(value),
  topics: List(String),
) -> Result(Nil, WriteError) {
  case store.writer {
    LocalWriter ->
      Ok(
        list.each(values, fn(v) { list_store_append_ffi(store.table, key, v) }),
      )
    ReplicatedWriter(server) -> replicated.append(server, key, values, topics)
  }
}

/// Get all values for a key. Reads like `get`.
pub fn get_all(store: ListStore(value), key: String) -> List(value) {
  log.debug("beacon.store", "get_all")
  case store.writer {
    LocalWriter -> list_store_get_all_ffi(store.table, key)
    ReplicatedWriter(_) -> replicated_read(replicated.get_all(store.table, key))
  }
}

/// Delete all values for a key. Auto-broadcasts to store-level watchers.
/// Crashes the caller (after logging) if the write fails; see
/// `try_delete_all`.
pub fn delete_all(store: ListStore(value), key: String) -> Nil {
  or_crash("delete_all", try_delete_all(store, key))
}

/// Delete all values for a key, returning why the write failed. In a
/// replicated store values appended concurrently on another node survive.
pub fn try_delete_all(
  store: ListStore(value),
  key: String,
) -> Result(Nil, WriteError) {
  log.debug("beacon.store", "delete_all")
  use Nil <- result.try(delete_values(store, key, []))
  wrote(store.topic, store.writer, "delete_all", 1)
  notify(store.topic)
  Ok(Nil)
}

/// Delete all values for a key and broadcast to a per-key topic. Crashes
/// the caller (after logging) if the write fails; see
/// `try_delete_all_notify`.
pub fn delete_all_notify(
  store: ListStore(value),
  key: String,
  topic_prefix: String,
) -> Nil {
  or_crash("delete_all_notify", try_delete_all_notify(store, key, topic_prefix))
}

/// `delete_all_notify`, returning why the write failed.
pub fn try_delete_all_notify(
  store: ListStore(value),
  key: String,
  topic_prefix: String,
) -> Result(Nil, WriteError) {
  log.debug("beacon.store", "delete_all_notify")
  use key_topic <- result.try(key_topic(topic_prefix, key))
  use Nil <- result.try(delete_values(store, key, [key_topic]))
  wrote(store.topic, store.writer, "delete_all", 1)
  notify(store.topic)
  notify(key_topic)
  Ok(Nil)
}

fn delete_values(
  store: ListStore(value),
  key: String,
  topics: List(String),
) -> Result(Nil, WriteError) {
  case store.writer {
    LocalWriter -> Ok(list_store_delete_ffi(store.table, key))
    ReplicatedWriter(server) -> replicated.remove(server, key, topics)
  }
}

/// Get the PubSub topic for this list store (return it from `beacon.subscriptions`).
pub fn list_topic(store: ListStore(value)) -> String {
  store.topic
}

// === Failures ===

/// The Nil-returning writes cannot report a failure: log it and crash the
/// caller loudly.
fn or_crash(op: String, outcome: Result(Nil, WriteError)) -> Nil {
  case outcome {
    Ok(Nil) -> Nil
    Error(err) ->
      log.error(
        "beacon.store",
        op <> " failed: " <> replicated.describe_write_error(err),
      )
  }
  // INVARIANT: the caller chose the API without an error value; a write it
  // believes happened must not be silently dropped.
  let assert Ok(Nil) = outcome
  Nil
}

/// A replicated read fails only while the node's replica is down. The read
/// API has no error value, so log it and crash the caller loudly.
fn replicated_read(outcome: Result(a, String)) -> a {
  case outcome {
    Ok(_) -> Nil
    Error(reason) ->
      log.error("beacon.store", "Replicated store read failed: " <> reason)
  }
  // INVARIANT: answering "missing" or "empty" for a store that is down
  // would show the caller data that does not exist.
  let assert Ok(value) = outcome
  value
}

// === Notifications ===

/// Tell this node's watchers of `topic` that the store changed.
fn notify(topic: String) -> Nil {
  let outcome = pubsub.local_broadcast(topic, Nil)
  case outcome {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.error(
        "beacon.store",
        "Change notification on "
          <> topic
          <> " failed: "
          <> pubsub.describe(reason),
      )
  }
  // INVARIANT: the write has happened; a watcher that is never told would
  // show stale data forever, so a failed notification crashes the writer.
  let assert Ok(Nil) = outcome
  Nil
}

/// The per-key topic `prefix <> key`, checked BEFORE the write so an
/// invalid topic never leaves a written but unannounced change.
fn key_topic(prefix: String, key: String) -> Result(String, WriteError) {
  let key_topic = prefix <> key
  case pubsub.validate_topic(key_topic) {
    Ok(Nil) -> Ok(key_topic)
    Error(reason) -> {
      log.error(
        "beacon.store",
        "Refusing a write with an invalid per-key topic: "
          <> pubsub.describe(reason),
      )
      Error(replicated.InvalidTopic(key_topic))
    }
  }
}

/// `[beacon, store, write]`, with the store's mode.
fn wrote(topic: String, writer: Writer, op: String, count: Int) -> Nil {
  let mode = case writer {
    LocalWriter -> "local"
    ReplicatedWriter(_) -> "replicated"
  }
  telemetry.store_write(count, store_name(topic), op, mode)
}

/// Every store topic is `"store:" <> name` (see `try_new`/`try_new_list`).
fn store_name(topic: String) -> String {
  string.drop_start(topic, 6)
}

// === Internal FFI ===

@external(erlang, "beacon_store_ffi", "append")
fn list_store_append_ffi(
  table: state_manager.EtsTable,
  key: String,
  value: value,
) -> Nil

@external(erlang, "beacon_store_ffi", "get_all")
fn list_store_get_all_ffi(
  table: state_manager.EtsTable,
  key: String,
) -> List(value)

@external(erlang, "beacon_store_ffi", "delete_key")
fn list_store_delete_ffi(table: state_manager.EtsTable, key: String) -> Nil
