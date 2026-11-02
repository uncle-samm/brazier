/// Shared state store — provides ETS-backed storage without user FFI.
/// Stores auto-broadcast via PubSub when data changes.
/// To react to changes, return `store.topic(s)` / `store.list_topic(s)` from
/// `beacon.subscriptions` and handle it in `beacon.on_notify`.
///
/// - `Store` — key-value (one value per key)
/// - `ListStore` — duplicate-bag (any number of values per key, duplicates
///   and insertion order kept, like chat messages)
///
/// Creation is idempotent: `new(name)` / `new_list(name)` called again with
/// the same name (from any process) returns a handle to the same data. The
/// backing tables are owned by a long-lived owner process, so they outlive
/// the process that created them.
import beacon/log
import beacon/pubsub
import beacon/state_manager
import gleam/list

/// Why a store could not be created. Names must be 1-255 bytes of
/// `[A-Za-z0-9_-]` once prefixed (they become ETS table atoms).
pub type StoreError =
  state_manager.EtsError

/// A key-value store backed by ETS.
/// Auto-broadcasts on put/delete.
pub type Store(value) {
  Store(manager: state_manager.EtsManager, topic: String)
}

/// Create (or reuse) a key-value store, returning a typed error for an
/// invalid name.
pub fn try_new(name: String) -> Result(Store(value), StoreError) {
  log.debug("beacon.store", "Opening store: " <> name)
  case open_table(name, "beacon_store_", state_manager.EtsSet) {
    Ok(table) ->
      Ok(Store(
        manager: state_manager.EtsManager(table: table),
        topic: "store:" <> name,
      ))
    Error(err) -> Error(err)
  }
}

/// Create (or reuse) a key-value store. Calling it again with the same name
/// returns the same store.
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
pub fn get(store: Store(value), key: String) -> Result(value, Nil) {
  log.debug("beacon.store", "get")
  state_manager.ets_get(store.manager, key)
}

/// Set a value by key. Auto-broadcasts to watchers.
pub fn put(store: Store(value), key: String, value: value) -> Nil {
  log.debug("beacon.store", "put: " <> key)
  state_manager.ets_put(store.manager, key, value)
  pubsub.broadcast(store.topic, Nil)
}

/// Delete a value by key. Auto-broadcasts to watchers.
pub fn delete(store: Store(value), key: String) -> Nil {
  log.debug("beacon.store", "delete: " <> key)
  state_manager.ets_delete(store.manager, key)
  pubsub.broadcast(store.topic, Nil)
}

/// Count total entries.
pub fn count(store: Store(value)) -> Int {
  log.debug("beacon.store", "count")
  state_manager.ets_count(store.manager)
}

/// Get the PubSub topic for this store (return it from `beacon.subscriptions`).
pub fn topic(store: Store(value)) -> String {
  store.topic
}

/// A list store backed by an ETS `duplicate_bag` — any number of values per
/// key. Appending the same value twice stores it twice; `get_all` returns
/// values in insertion order. Auto-broadcasts on append/delete.
pub type ListStore(value) {
  ListStore(table: state_manager.EtsTable, topic: String)
}

/// Create (or reuse) a list store, returning a typed error for an invalid
/// name.
pub fn try_new_list(name: String) -> Result(ListStore(value), StoreError) {
  log.debug("beacon.store", "Opening list store: " <> name)
  case open_table(name, "beacon_ls_", state_manager.EtsDuplicateBag) {
    Ok(table) -> Ok(ListStore(table: table, topic: "store:" <> name))
    Error(err) -> Error(err)
  }
}

/// Create (or reuse) a list store. Calling it again with the same name
/// returns the same store.
///
/// A failure (an invalid name) is a programming error: it is logged and
/// crashes the caller loudly. Use `try_new_list` to handle it as a value.
pub fn new_list(name: String) -> ListStore(value) {
  let result = try_new_list(name)
  // Invariant: list store names are compile-time constants; see `new`.
  let assert Ok(store) = result as "beacon.store.new_list failed"
  store
}

/// Append a value. Auto-broadcasts to store-level watchers.
pub fn append(store: ListStore(value), key: String, value: value) -> Nil {
  log.debug("beacon.store", "append")
  list_store_append_ffi(store.table, key, value)
  pubsub.broadcast(store.topic, Nil)
}

/// Append multiple values at once. Only broadcasts ONCE after all inserts.
/// Use this instead of calling append() in a loop.
pub fn append_many(
  store: ListStore(value),
  key: String,
  values: List(value),
) -> Nil {
  log.debug("beacon.store", "append_many")
  list.each(values, fn(v) { list_store_append_ffi(store.table, key, v) })
  pubsub.broadcast(store.topic, Nil)
}

/// Append a value and broadcast to both the store topic AND a per-key topic.
/// The per-key topic is `prefix <> key` (e.g., "room:" <> "general" = "room:general").
/// Use with `beacon.subscriptions()` for dynamic per-key subscriptions.
pub fn append_notify(
  store: ListStore(value),
  key: String,
  value: value,
  topic_prefix: String,
) -> Nil {
  log.debug("beacon.store", "append_notify")
  list_store_append_ffi(store.table, key, value)
  pubsub.broadcast(store.topic, Nil)
  pubsub.broadcast(topic_prefix <> key, Nil)
}

/// Get all values for a key.
pub fn get_all(store: ListStore(value), key: String) -> List(value) {
  log.debug("beacon.store", "get_all")
  list_store_get_all_ffi(store.table, key)
}

/// Delete all values for a key. Auto-broadcasts to store-level watchers.
pub fn delete_all(store: ListStore(value), key: String) -> Nil {
  log.debug("beacon.store", "delete_all")
  list_store_delete_ffi(store.table, key)
  pubsub.broadcast(store.topic, Nil)
}

/// Delete all values for a key and broadcast to a per-key topic.
pub fn delete_all_notify(
  store: ListStore(value),
  key: String,
  topic_prefix: String,
) -> Nil {
  log.debug("beacon.store", "delete_all_notify")
  list_store_delete_ffi(store.table, key)
  pubsub.broadcast(store.topic, Nil)
  pubsub.broadcast(topic_prefix <> key, Nil)
}

/// Get the PubSub topic for this list store (return it from `beacon.subscriptions`).
pub fn list_topic(store: ListStore(value)) -> String {
  store.topic
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
