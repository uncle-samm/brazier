/// PubSub: publish/subscribe across processes and across connected nodes.
///
/// A port of Phoenix.PubSub with its pg adapter:
///
/// - **Local registry.** Subscriptions live in a node-local registry
///   partitioned by subscriber pid (Elixir Registry's duplicate-key
///   partitions). They are never stored in `pg`.
/// - **Cross-node workers.** `pool_size` forwarding workers per node join
///   the `pg` group `{beacon_pubsub, Shard}` in the `beacon_pubsub_pg` scope.
///   `broadcast` delivers locally, then sends ONE forward to the worker of
///   the caller's shard on each remote node, which delivers to its own local
///   subscribers. `pool_size` must be the same on every node.
/// - **Delivery shape.** Subscribers receive
///   `{beacon_pubsub, Topic, Message}`.
/// - **Partition links.** A subscriber is linked to its registry partition,
///   as with Registry. If the partition dies its subscribers are stopped,
///   rather than silently missing broadcasts. A subscriber exit removes its
///   subscriptions.
/// - **Topics** are 1 to 255 bytes. Every violation is an `Error`.
/// - **Overload.** A forwarding worker whose queue is longer than
///   `max_forward_queue` logs at error level and emits
///   `[beacon, pubsub, forward, overloaded]` at most once per second. It
///   never drops a message.
///
/// Connected nodes can already run arbitrary code on each other, so forwarded
/// messages are not authenticated. See docs/CLUSTERING.md.
///
/// The functions returning `Nil` (`subscribe`, `unsubscribe`, `broadcast`,
/// `start`) are the original API. They call the `try_` versions and crash
/// loudly, with a logged reason, on any error.
import beacon/log
import gleam/erlang/atom
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result

/// A topic for pub/sub messaging: 1 to 255 bytes.
pub type Topic =
  String

/// Why a PubSub operation failed.
pub type PubSubError {
  /// The topic is empty or longer than 255 bytes.
  InvalidTopic(String)
  /// PubSub is not running on this node (or a registry partition is
  /// restarting).
  NotStarted
  /// `direct_broadcast` targeted a node that is not connected or runs no
  /// PubSub worker for this shard.
  NodeNotConnected(node: String)
  /// The calling process already holds the maximum number of topics.
  TooManySubscriptions(limit: Int)
  /// The configuration is invalid, or differs from the running one.
  InvalidConfig(String)
  /// The PubSub supervisor did not start.
  StartFailed(String)
}

/// PubSub configuration. Use `default_config` and the setters.
pub type PubSubConfig {
  PubSubConfig(
    /// Registry partitions on this node. Defaults to the number of online
    /// schedulers.
    partitions: Int,
    /// Forwarding workers per node. Must be equal on every node.
    pool_size: Int,
    /// Queue length above which a worker reports overload.
    max_forward_queue: Int,
    /// Topics a single process may subscribe to.
    max_topics_per_subscriber: Int,
  )
}

/// Upper bound for `partitions`.
pub const max_partitions = 1024

/// Upper bound for `pool_size`.
pub const max_pool_size = 64

/// Upper bound for `max_topics_per_subscriber`.
pub const max_topics_limit = 100_000

/// The default configuration: one partition per online scheduler, one
/// forwarding worker, overload reported above 10,000 queued forwards, at
/// most 1,000 topics per subscriber.
pub fn default_config() -> PubSubConfig {
  PubSubConfig(
    partitions: int.clamp(schedulers_online(), 1, max_partitions),
    pool_size: 1,
    max_forward_queue: 10_000,
    max_topics_per_subscriber: 1000,
  )
}

/// Set the number of registry partitions (1 to 1024).
pub fn partitions(config: PubSubConfig, partitions: Int) -> PubSubConfig {
  PubSubConfig(..config, partitions: partitions)
}

/// Set the number of forwarding workers per node (1 to 64).
pub fn pool_size(config: PubSubConfig, pool_size: Int) -> PubSubConfig {
  PubSubConfig(..config, pool_size: pool_size)
}

/// Set the forwarding queue length that triggers an overload report.
pub fn max_forward_queue(config: PubSubConfig, limit: Int) -> PubSubConfig {
  PubSubConfig(..config, max_forward_queue: limit)
}

/// Set how many topics one process may subscribe to (1 to 100,000).
pub fn max_topics_per_subscriber(
  config: PubSubConfig,
  limit: Int,
) -> PubSubConfig {
  PubSubConfig(..config, max_topics_per_subscriber: limit)
}

/// Check every field of a configuration.
pub fn validate_config(
  config: PubSubConfig,
) -> Result(PubSubConfig, PubSubError) {
  use _ <- result.try(in_range(
    "partitions",
    config.partitions,
    1,
    max_partitions,
  ))
  use _ <- result.try(in_range("pool_size", config.pool_size, 1, max_pool_size))
  use _ <- result.try(in_range(
    "max_forward_queue",
    config.max_forward_queue,
    1,
    1_000_000_000,
  ))
  use _ <- result.try(in_range(
    "max_topics_per_subscriber",
    config.max_topics_per_subscriber,
    1,
    max_topics_limit,
  ))
  Ok(config)
}

fn in_range(
  field: String,
  value: Int,
  min: Int,
  max: Int,
) -> Result(Nil, PubSubError) {
  case value >= min && value <= max {
    True -> Ok(Nil)
    False ->
      Error(InvalidConfig(
        field
        <> " must be between "
        <> int.to_string(min)
        <> " and "
        <> int.to_string(max)
        <> ", got "
        <> int.to_string(value),
      ))
  }
}

/// Check that `topic` is a valid topic: 1 to 255 bytes.
pub fn validate_topic(topic: Topic) -> Result(Nil, PubSubError) {
  let size = byte_size(topic)
  case size >= 1 && size <= max_topic_bytes {
    True -> Ok(Nil)
    False -> Error(InvalidTopic(topic))
  }
}

/// The longest topic, in bytes.
pub const max_topic_bytes = 255

// --- Lifecycle ---

/// Make sure PubSub runs on this node, with the default configuration if it
/// is not running yet. It is not linked to the caller.
///
/// Crashes, after logging the reason, if PubSub cannot start.
pub fn start() -> Nil {
  let config = default_config()
  // INVARIANT: default_config() is always valid: every field is a constant
  // inside its range, and partitions is clamped.
  let assert Ok(config) = validate_config(config)
  let outcome = ensure_started_ffi(config)
  case outcome {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.error("beacon.pubsub", "PubSub failed to start: " <> describe(reason))
  }
  // INVARIANT: the original start() has no way to report an error, and
  // without PubSub no subscription or broadcast can work: crash loudly.
  let assert Ok(Nil) = outcome
  Nil
}

/// Start PubSub with `config`, not linked to the caller.
///
/// Returns `Ok(Nil)` if it is already running with the same configuration
/// and `Error(InvalidConfig(_))` if it runs with a different one.
pub fn start_with(config: PubSubConfig) -> Result(Nil, PubSubError) {
  use config <- result.try(validate_config(config))
  start_ffi(config)
}

/// A child specification that starts PubSub linked to a supervisor. This is
/// the form the root supervision tree uses.
pub fn supervised(
  config: PubSubConfig,
) -> Result(supervision.ChildSpecification(Nil), PubSubError) {
  use config <- result.try(validate_config(config))
  Ok(
    supervision.supervisor(fn() {
      case start_link_ffi(config) {
        Ok(pid) -> Ok(actor.Started(pid: pid, data: Nil))
        Error(reason) -> Error(actor.InitFailed(describe(reason)))
      }
    }),
  )
}

/// Stop PubSub on this node. Every subscriber is linked to its partition,
/// so subscribers stop too.
pub fn stop() -> Result(Nil, PubSubError) {
  stop_ffi()
}

/// The configuration PubSub runs with on this node.
pub fn running_config() -> Result(PubSubConfig, PubSubError) {
  running_config_ffi()
}

// --- Subscriptions ---

/// Subscribe the calling process to `topic`. Subscribing twice to the same
/// topic is one subscription: each broadcast is delivered once.
pub fn try_subscribe(topic: Topic) -> Result(Nil, PubSubError) {
  subscribe_ffi(topic)
}

/// Unsubscribe the calling process from `topic`. Unsubscribing from a topic
/// the process is not subscribed to is `Ok`.
pub fn try_unsubscribe(topic: Topic) -> Result(Nil, PubSubError) {
  unsubscribe_ffi(topic)
}

/// Subscribe the current process to a topic. Crashes on any error.
pub fn subscribe(topic: Topic) -> Nil {
  log.debug("beacon.pubsub", "Subscribing to: " <> topic)
  or_crash("subscribe", topic, try_subscribe(topic))
}

/// Unsubscribe the current process from a topic. Crashes on any error.
pub fn unsubscribe(topic: Topic) -> Nil {
  log.debug("beacon.pubsub", "Unsubscribing from: " <> topic)
  or_crash("unsubscribe", topic, try_unsubscribe(topic))
}

// --- Broadcasts ---

/// Deliver `message` to every subscriber of `topic` on this node and on
/// every connected node.
pub fn try_broadcast(topic: Topic, message: msg) -> Result(Nil, PubSubError) {
  broadcast_ffi(topic, message)
}

/// Broadcast to every subscriber on every connected node. Crashes on any
/// error.
pub fn broadcast(topic: Topic, message: msg) -> Nil {
  or_crash("broadcast", topic, try_broadcast(topic, message))
}

/// Deliver `message` to the subscribers of `topic` on this node only.
pub fn local_broadcast(topic: Topic, message: msg) -> Result(Nil, PubSubError) {
  local_broadcast_ffi(topic, message)
}

/// Deliver `message` to the subscribers of `topic` on `target` only.
/// Returns `Error(NodeNotConnected(_))` if `target` is not connected.
pub fn direct_broadcast(
  target: Node,
  topic: Topic,
  message: msg,
) -> Result(Nil, PubSubError) {
  direct_broadcast_ffi(node.name(target), topic, message)
}

// --- Introspection ---

/// The number of processes on this node subscribed to `topic`. Zero when
/// PubSub is not running, because then nothing can be subscribed.
pub fn local_subscriber_count(topic: Topic) -> Int {
  local_subscriber_count_ffi(topic)
}

/// The number of subscribers of `topic` on this node.
///
/// Subscriptions are node-local, so this equals `local_subscriber_count`.
pub fn subscriber_count(topic: Topic) -> Int {
  local_subscriber_count(topic)
}

/// The processes on this node subscribed to `topic`.
pub fn local_subscribers(topic: Topic) -> Result(List(Pid), PubSubError) {
  local_subscribers_ffi(topic)
}

/// The registry partition that holds `pid`'s subscriptions. A subscriber
/// is linked to it; monitoring it as well lets a process that traps exits
/// notice when the registry dies.
pub fn partition_for(pid: Pid) -> Result(Pid, PubSubError) {
  partition_for_ffi(pid)
}

/// A readable description of an error.
pub fn describe(error: PubSubError) -> String {
  case error {
    InvalidTopic(topic) ->
      "invalid topic (must be 1 to 255 bytes): "
      <> int.to_string(byte_size(topic))
      <> " bytes"
    NotStarted -> "PubSub is not running on this node"
    NodeNotConnected(node) -> "node not connected: " <> node
    TooManySubscriptions(limit) ->
      "too many subscriptions (limit " <> int.to_string(limit) <> ")"
    InvalidConfig(reason) -> "invalid PubSub config: " <> reason
    StartFailed(reason) -> "PubSub failed to start: " <> reason
  }
}

fn or_crash(
  operation: String,
  topic: Topic,
  outcome: Result(Nil, PubSubError),
) -> Nil {
  case outcome {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.error(
        "beacon.pubsub",
        operation <> " on " <> topic <> " failed: " <> describe(reason),
      )
  }
  // INVARIANT: the Nil-returning API has no way to report an error, and a
  // lost subscription or broadcast must not go unnoticed: crash loudly.
  let assert Ok(Nil) = outcome
  Nil
}

// --- Erlang FFI ---

@external(erlang, "beacon_pubsub_ffi", "start")
fn start_ffi(config: PubSubConfig) -> Result(Nil, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "ensure_started")
fn ensure_started_ffi(config: PubSubConfig) -> Result(Nil, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "start_link")
fn start_link_ffi(config: PubSubConfig) -> Result(Pid, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "stop")
fn stop_ffi() -> Result(Nil, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "running_config")
fn running_config_ffi() -> Result(PubSubConfig, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "subscribe")
fn subscribe_ffi(topic: String) -> Result(Nil, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "unsubscribe")
fn unsubscribe_ffi(topic: String) -> Result(Nil, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "broadcast")
fn broadcast_ffi(topic: String, message: msg) -> Result(Nil, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "local_broadcast")
fn local_broadcast_ffi(topic: String, message: msg) -> Result(Nil, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "direct_broadcast")
fn direct_broadcast_ffi(
  target: atom.Atom,
  topic: String,
  message: msg,
) -> Result(Nil, PubSubError)

@external(erlang, "beacon_pubsub_ffi", "local_subscribers")
fn local_subscribers_ffi(topic: String) -> Result(List(Pid), PubSubError)

@external(erlang, "beacon_pubsub_ffi", "local_subscriber_count")
fn local_subscriber_count_ffi(topic: String) -> Int

@external(erlang, "beacon_pubsub_ffi", "partition_for")
fn partition_for_ffi(pid: Pid) -> Result(Pid, PubSubError)

@external(erlang, "erlang", "byte_size")
fn byte_size(string: String) -> Int

@external(erlang, "beacon_pubsub_ffi", "schedulers_online")
fn schedulers_online() -> Int
