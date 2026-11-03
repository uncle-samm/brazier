//// A session's presence: the watcher process behind `beacon.presence`.
////
//// Every runtime of an app with presence gets one watcher. It is spawned
//// from the runtime's initialiser, links to the runtime and monitors it,
//// and does all presence work for it (Phoenix.Presence's track from the
//// channel process, plus its client-side `syncDiff`, kept on the server):
////
//// - **Tracking.** The watcher tracks the session's `Tracking`s as itself;
////   the shard monitors it, so its entries leave when it exits. After every
////   update the runtime computes the list again and, when it changed, sends
////   it here; the watcher tracks, updates and untracks to match.
//// - **Diffs.** For every tracked topic the watcher subscribes to the
////   topic's diffs, then reads the topic's entries once and reports them
////   as joins. Each delivery is checked against what was already reported
////   (by meta ref): a join already reported or a leave never reported is
////   dropped, so the app sees every entry exactly once. Up to 100 queued
////   deliveries for the same topic are coalesced into one `on_presence`
////   message.
//// - **Shard restarts.** A shard that dies loses its entries. The watcher
////   monitors the shard of every tracked topic and, when one goes down,
////   tracks that topic's entries again on the restarted shard (retrying
////   after 10ms, doubling to 1s, at most 12 times), then reconciles the
////   topic with a fresh read. A shard that does not come back stops the
////   watcher with `beacon_presence_down`. The restarted shard has none of
////   the other nodes' entries until it has synced with them, so known
////   entries of other nodes that it does not list are held, not reported,
////   until the shard says it has synced with their node (see `reconcile`).
//// - **PubSub.** The watcher traps exits and monitors its PubSub registry
////   partition. If the partition dies the watcher logs it and exits with
////   `beacon_pubsub_down`; the runtime dies with it and its clients
////   reconnect (design D7).
//// - **Failures.** A track the tracker refuses (a limit, an invalid topic
////   or key, a meta that is too large, the same key twice) is an app bug or
////   an overload the app must hear about: it is logged and stops the
////   watcher with `beacon_presence_failed`, which stops the runtime.
////
//// The meta type is erased behind closures, so runtimes and apps only
//// carry `Watch(state, msg)` and `Watcher(state)`.
////
//// Reference: Phoenix.Presence / Phoenix.Tracker (track from the session
//// process, re-track after a tracker restart), phoenix.js `syncDiff`.

import beacon/log
import beacon/presence.{
  type Presence, type PresenceConfig, type PresenceError, type Tracking,
  Tracking,
}
import beacon/presence/sync.{type Diff, type Meta, Diff, Entry}
import beacon/pubsub
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/order
import gleam/otp/supervision
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// Presence for an app: the tracker and how a session's state maps to
/// trackings and messages.
pub opaque type Watch(state, msg) {
  Watch(
    name: String,
    /// The tracker's handle, or why its configuration is invalid.
    handle: fn() -> Result(Nil, PresenceError),
    /// The tracker as a supervisor child.
    child: fn() -> Result(supervision.ChildSpecification(Nil), PresenceError),
    /// Start the tracker unlinked unless it is running.
    ensure_started: fn() -> Result(Nil, PresenceError),
    /// Whether the tracker runs on this node.
    running: fn() -> Bool,
    /// Spawn a watcher for the calling runtime.
    spawn: fn(fn(msg) -> Nil, state) -> Result(Watcher(state), String),
  )
}

/// A running watcher, owned by one runtime.
pub opaque type Watcher(state) {
  Watcher(
    pid: Pid,
    /// Send the trackings of a new state when they changed. Returns the
    /// watcher to keep (it remembers the last trackings sent).
    sync: fn(state) -> Watcher(state),
    stop: fn() -> Nil,
  )
}

/// Retry delays after a shard went down: 10ms doubling up to 1s.
const first_retry_ms = 10

const max_retry_ms = 1000

const max_retries = 12

/// How long the runtime waits for a new watcher's initial tracks.
const start_timeout_ms = 4500

/// Presence over the tracker `config`: `track` gives a session's trackings
/// for its state, `on_presence` the message for a change on one of its
/// topics.
pub fn new(
  config: PresenceConfig(meta),
  track: fn(state) -> List(Tracking(meta)),
  on_presence: fn(Diff(meta)) -> msg,
) -> Watch(state, msg) {
  let handle = presence.handle(config)
  let name = case handle {
    Ok(tracker) -> presence.name(tracker)
    Error(_) -> "(invalid)"
  }
  Watch(
    name:,
    handle: fn() { result.replace(handle, Nil) },
    child: fn() {
      presence.supervised(config)
      |> result.map(supervision.map_data(_, fn(_) { Nil }))
    },
    ensure_started: fn() {
      use tracker <- result.try(handle)
      case presence.running(tracker) {
        True -> Ok(Nil)
        False -> presence.start(config) |> result.replace(Nil)
      }
    },
    running: fn() {
      case handle {
        Ok(tracker) -> presence.running(tracker)
        Error(_) -> False
      }
    },
    spawn: fn(dispatch, state) {
      case handle {
        Error(reason) -> Error(presence.describe(reason))
        Ok(tracker) ->
          spawn_watcher(tracker, track, on_presence, dispatch, state)
      }
    },
  )
}

/// The tracker's name, for logs.
pub fn name(watch: Watch(state, msg)) -> String {
  watch.name
}

/// Check the tracker configuration.
pub fn validate(watch: Watch(state, msg)) -> Result(Nil, PresenceError) {
  watch.handle()
}

/// The tracker as a child of the application's supervisor.
pub fn supervised(
  watch: Watch(state, msg),
) -> Result(supervision.ChildSpecification(Nil), PresenceError) {
  watch.child()
}

/// Start the tracker unlinked if it is not running yet (the unsupervised
/// `application.start`).
pub fn ensure_started(watch: Watch(state, msg)) -> Result(Nil, PresenceError) {
  watch.ensure_started()
}

/// Whether the tracker runs on this node.
pub fn running(watch: Watch(state, msg)) -> Bool {
  watch.running()
}

/// Start the watcher of the calling runtime, tracking `trackings(state)`.
/// Returns once the initial trackings are tracked; `dispatch` delivers
/// `on_presence` messages to the runtime.
pub fn start(
  watch: Watch(state, msg),
  dispatch: fn(msg) -> Nil,
  state: state,
) -> Result(Watcher(state), String) {
  watch.spawn(dispatch, state)
}

/// Bring the trackings in line with `state` (after an update).
pub fn sync(watcher: Watcher(state), state: state) -> Watcher(state) {
  watcher.sync(state)
}

/// Stop the watcher; its entries leave.
pub fn stop(watcher: Watcher(state)) -> Nil {
  log.debug(
    "beacon.presence",
    "Stopping presence watcher " <> string.inspect(watcher.pid),
  )
  watcher.stop()
}

/// The watcher process.
pub fn pid(watcher: Watcher(state)) -> Pid {
  watcher.pid
}

// --- The watcher process ------------------------------------------------------

type Command(meta) {
  SetTrackings(List(Tracking(meta)))
  Retry
  Stop
}

/// What `beacon_presence_watch_ffi:receive_event` returns.
type Event(meta) {
  CommandReceived(Command(meta))
  Diffs(diff_topic: String, messages: List(Dynamic))
  OwnerDown(reason: String)
  PartitionDown(reason: String)
  MonitorDown(pid: Pid, reason: String)
  LinkedExit(pid: Pid, reason: String)
  /// A shard's answer to `await_sync` for one node.
  Synced(shard: Pid, node: String, status: SyncStatus)
}

/// Where a shard stands with another node (`beacon_presence_shard`'s sync
/// waiters): it holds every entry the node had, the node is down, it has
/// not heard from the node for down_period, or neither within down_period.
type SyncStatus {
  InSync
  NodeDown
  NodeAbsent
  SyncTimeout
}

/// Why a watcher stops abnormally (the exit reason the runtime dies with).
type ExitReason {
  BeaconPresenceFailed(String)
  BeaconPresenceDown(String)
  BeaconPubsubDown(String)
}

type State(meta, msg) {
  State(
    tracker: Presence(meta),
    on_presence: fn(Diff(meta)) -> msg,
    dispatch: fn(msg) -> Nil,
    commands: Subject(Command(meta)),
    owner: #(Monitor, Pid),
    partition: Monitor,
    /// What should be tracked, by topic then key.
    trackings: Dict(String, Dict(String, meta)),
    /// Tracked topics whose shard is up: topic → shard.
    shards: Dict(String, Pid),
    /// Tracked topics whose shard went down, to track again.
    pending: Set(String),
    /// One monitor per shard in `shards`.
    monitors: Dict(Pid, Monitor),
    /// What the app was told, by topic then meta ref.
    known: Dict(String, Dict(String, #(String, Meta(meta)))),
    /// Refs in `known` of other nodes that a restarted shard did not list
    /// yet, by topic: reported as leaves only if the shard still does not
    /// list them once it has synced with their node.
    suspects: Dict(String, Set(String)),
    /// Retries done since a shard went down (0: none scheduled).
    retries: Int,
  )
}

fn spawn_watcher(
  tracker: Presence(meta),
  track: fn(state) -> List(Tracking(meta)),
  on_presence: fn(Diff(meta)) -> msg,
  dispatch: fn(msg) -> Nil,
  state: state,
) -> Result(Watcher(state), String) {
  let owner = process.self()
  let reply = process.new_subject()
  let initial = track(state)
  let pid =
    process.spawn_unlinked(fn() {
      init(tracker, on_presence, dispatch, owner, initial, reply)
    })
  case process.receive(reply, start_timeout_ms) {
    Ok(Ok(commands)) -> {
      log.debug(
        "beacon.presence",
        "Presence watcher "
          <> string.inspect(pid)
          <> " started with "
          <> int.to_string(list.length(initial))
          <> " trackings",
      )
      Ok(make_watcher(pid, commands, track, initial))
    }
    Ok(Error(reason)) -> Error(reason)
    Error(Nil) -> {
      process.kill(pid)
      let reason =
        "the presence watcher did not start within "
        <> int.to_string(start_timeout_ms)
        <> "ms"
      log.error("beacon.presence", reason)
      Error(reason)
    }
  }
}

fn make_watcher(
  pid: Pid,
  commands: Subject(Command(meta)),
  track: fn(state) -> List(Tracking(meta)),
  last: List(Tracking(meta)),
) -> Watcher(state) {
  Watcher(
    pid:,
    sync: fn(state) {
      let trackings = track(state)
      case trackings == last {
        True -> make_watcher(pid, commands, track, last)
        False -> {
          process.send(commands, SetTrackings(trackings))
          make_watcher(pid, commands, track, trackings)
        }
      }
    },
    stop: fn() { process.send(commands, Stop) },
  )
}

fn init(
  tracker: Presence(meta),
  on_presence: fn(Diff(meta)) -> msg,
  dispatch: fn(msg) -> Nil,
  owner: Pid,
  initial: List(Tracking(meta)),
  reply: Subject(Result(Subject(Command(meta)), String)),
) -> Nil {
  trap_exits()
  set_label(presence.name(tracker))
  // Monitor before linking: if the runtime is already gone the monitor
  // delivers DOWN and the loop stops on its first receive.
  let owner_monitor = process.monitor(owner)
  let linked = process.link(owner)
  let started = {
    use Nil <- result.try(case linked {
      True -> Ok(Nil)
      False -> Error("the runtime exited before its presence watcher started")
    })
    use partition <- result.try(
      pubsub.partition_for(process.self())
      |> result.map_error(fn(reason) {
        "PubSub is not available: " <> pubsub.describe(reason)
      }),
    )
    let state =
      State(
        tracker:,
        on_presence:,
        dispatch:,
        commands: process.new_subject(),
        owner: #(owner_monitor, owner),
        partition: process.monitor(partition),
        trackings: dict.new(),
        shards: dict.new(),
        pending: set.new(),
        monitors: dict.new(),
        known: dict.new(),
        suspects: dict.new(),
        retries: 0,
      )
    set_trackings(state, initial)
  }
  case started {
    Ok(state) -> {
      process.send(reply, Ok(state.commands))
      log.info(
        "beacon.presence",
        "Presence watcher of tracker "
          <> presence.name(tracker)
          <> " tracking "
          <> int.to_string(dict.size(state.trackings))
          <> " topics",
      )
      loop(state)
    }
    Error(reason) -> {
      log.error(
        "beacon.presence",
        "Presence watcher of tracker "
          <> presence.name(tracker)
          <> " failed to start: "
          <> reason,
      )
      // Its tracks (if any) leave when this process exits.
      process.send(reply, Error(reason))
    }
  }
}

fn loop(state: State(meta, msg)) -> Nil {
  let name = presence.name(state.tracker)
  case receive_event(state.commands, state.owner, state.partition, name) {
    CommandReceived(SetTrackings(trackings)) ->
      case set_trackings(state, trackings) {
        Ok(state) -> loop(state)
        Error(reason) -> fail(state, reason)
      }
    CommandReceived(Retry) ->
      case retry(state) {
        Ok(state) -> loop(state)
        Error(reason) -> fail(state, reason)
      }
    CommandReceived(Stop) ->
      log.info("beacon.presence", "Presence watcher of " <> name <> " stopped")
    Diffs(diff_topic, messages) ->
      case report_diffs(state, diff_topic, messages) {
        Ok(state) -> loop(state)
        Error(reason) -> fail(state, reason)
      }
    OwnerDown(reason) ->
      log.debug(
        "beacon.presence",
        "Presence watcher of " <> name <> ": runtime exited (" <> reason <> ")",
      )
    PartitionDown(reason) -> pubsub_down(name, reason)
    LinkedExit(pid, reason) ->
      // The only other links are PubSub registry partitions.
      pubsub_down(
        name,
        "linked process " <> string.inspect(pid) <> " exited: " <> reason,
      )
    Synced(shard, node, status) ->
      case synced(state, shard, node, status) {
        Ok(state) -> loop(state)
        Error(reason) -> fail(state, reason)
      }
    MonitorDown(pid, reason) ->
      case dict.has_key(state.monitors, pid) {
        True -> loop(shard_down(state, pid, reason))
        False -> {
          log.warning(
            "beacon.presence",
            "Presence watcher of "
              <> name
              <> " ignoring the DOWN of an unmonitored process "
              <> string.inspect(pid),
          )
          loop(state)
        }
      }
  }
}

fn fail(state: State(meta, msg), reason: String) -> Nil {
  let name = presence.name(state.tracker)
  log.error(
    "beacon.presence",
    "Presence watcher of "
      <> name
      <> " failed, stopping its runtime: "
      <> reason,
  )
  exit(BeaconPresenceFailed(reason))
}

fn pubsub_down(name: String, reason: String) -> Nil {
  log.error(
    "beacon.presence",
    "Presence watcher of "
      <> name
      <> ": PubSub registry partition went down ("
      <> reason
      <> "), stopping its runtime",
  )
  exit(BeaconPubsubDown(reason))
}

// --- Trackings ----------------------------------------------------------------

/// Track, update and untrack so that `trackings` is what is tracked.
fn set_trackings(
  state: State(meta, msg),
  trackings: List(Tracking(meta)),
) -> Result(State(meta, msg), String) {
  use wanted <- result.try(group_trackings(trackings))
  let old_topics = dict.keys(state.trackings)
  let gone = list.filter(old_topics, fn(topic) { !dict.has_key(wanted, topic) })
  use state <- result.try(list.try_fold(gone, state, remove_topic))
  dict.to_list(wanted)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.try_fold(state, fn(state, pair) {
    let #(topic, keys) = pair
    case dict.get(state.trackings, topic) {
      Ok(old) -> change_topic(state, topic, old, keys)
      Error(Nil) -> add_topic(state, topic, keys)
    }
  })
}

/// The trackings by topic and key; the same key twice on a topic is a bug.
fn group_trackings(
  trackings: List(Tracking(meta)),
) -> Result(Dict(String, Dict(String, meta)), String) {
  list.try_fold(trackings, dict.new(), fn(acc, tracking) {
    let Tracking(topic:, key:, meta:) = tracking
    let keys = dict.get(acc, topic) |> result.unwrap(dict.new())
    case dict.has_key(keys, key) {
      True ->
        Error(
          "the trackings list "
          <> key
          <> " twice on topic "
          <> topic
          <> " (each key may appear once per topic)",
        )
      False -> Ok(dict.insert(acc, topic, dict.insert(keys, key, meta)))
    }
  })
}

fn add_topic(
  state: State(meta, msg),
  topic: String,
  keys: Dict(String, meta),
) -> Result(State(meta, msg), String) {
  use Nil <- result.try(
    presence.subscribe(state.tracker, topic)
    |> result.map_error(fn(reason) {
      "subscribing to the diffs of "
      <> topic
      <> ": "
      <> presence.describe(reason)
    }),
  )
  log.debug("beacon.presence", "Presence watcher joined topic " <> topic)
  let state =
    State(
      ..state,
      trackings: dict.insert(state.trackings, topic, keys),
      known: dict.insert(state.known, topic, dict.new()),
    )
  activate(state, topic)
}

fn remove_topic(
  state: State(meta, msg),
  topic: String,
) -> Result(State(meta, msg), String) {
  let keys = dict.get(state.trackings, topic) |> result.unwrap(dict.new())
  use state <- result.try(case dict.has_key(state.shards, topic) {
    True ->
      list.try_fold(dict.keys(keys), state, fn(state, key) {
        untrack(state, topic, key)
      })
    False -> Ok(state)
  })
  use Nil <- result.try(
    presence.unsubscribe(state.tracker, topic)
    |> result.map_error(fn(reason) {
      "unsubscribing from the diffs of "
      <> topic
      <> ": "
      <> presence.describe(reason)
    }),
  )
  // Everything the app was told about the topic leaves with it.
  let known = dict.get(state.known, topic) |> result.unwrap(dict.new())
  report(state, topic, [], dict.values(known))
  log.debug("beacon.presence", "Presence watcher left topic " <> topic)
  let state =
    State(
      ..state,
      trackings: dict.delete(state.trackings, topic),
      known: dict.delete(state.known, topic),
      suspects: dict.delete(state.suspects, topic),
      pending: set.delete(state.pending, topic),
    )
  Ok(forget_shard(state, topic))
}

/// Apply the key changes of a topic that stays tracked.
fn change_topic(
  state: State(meta, msg),
  topic: String,
  old: Dict(String, meta),
  new: Dict(String, meta),
) -> Result(State(meta, msg), String) {
  let state =
    State(..state, trackings: dict.insert(state.trackings, topic, new))
  case dict.has_key(state.shards, topic) {
    // A pending topic is tracked from `trackings` when its shard is back.
    False -> Ok(state)
    True -> {
      let removed =
        dict.keys(old) |> list.filter(fn(key) { !dict.has_key(new, key) })
      use state <- result.try(
        list.try_fold(removed, state, fn(state, key) {
          untrack(state, topic, key)
        }),
      )
      dict.to_list(new)
      |> list.try_fold(state, fn(state, pair) {
        let #(key, meta) = pair
        case dict.get(old, key) {
          Error(Nil) -> track(state, topic, key, meta)
          Ok(previous) if previous == meta -> Ok(state)
          Ok(_) -> update(state, topic, key, meta)
        }
      })
    }
  }
}

/// Track every key of `topic` on its shard and reconcile what the app knows
/// with a fresh read. A shard that is down leaves the topic pending.
fn activate(
  state: State(meta, msg),
  topic: String,
) -> Result(State(meta, msg), String) {
  case presence.shard_pid(state.tracker, topic) {
    Error(presence.TrackerDown) -> Ok(lost(state, topic, "shard not running"))
    Error(reason) -> Error(describe(topic, reason))
    Ok(shard) -> {
      // Monitor before tracking: a shard that dies after this is noticed.
      let state =
        State(
          ..state,
          shards: dict.insert(state.shards, topic, shard),
          pending: set.delete(state.pending, topic),
          monitors: case dict.has_key(state.monitors, shard) {
            True -> state.monitors
            False -> dict.insert(state.monitors, shard, process.monitor(shard))
          },
        )
      let keys = dict.get(state.trackings, topic) |> result.unwrap(dict.new())
      use state <- result.try(
        dict.to_list(keys)
        |> list.try_fold(state, fn(state, pair) {
          retrack(state, topic, pair.0, pair.1)
        }),
      )
      case dict.has_key(state.shards, topic) {
        True -> reconcile(state, topic, shard)
        False -> Ok(state)
      }
    }
  }
}

fn track(
  state: State(meta, msg),
  topic: String,
  key: String,
  meta: meta,
) -> Result(State(meta, msg), String) {
  use <- on_shard(state, topic)
  case presence.track(state.tracker, topic, key, meta) {
    Ok(_ref) -> Ok(state)
    Error(presence.TrackerDown) -> Ok(lost(state, topic, "track: shard down"))
    Error(reason) -> Error(describe(topic, reason))
  }
}

/// Run `apply` only while the shard of `topic` is up: once a call found it
/// down the topic is pending and everything is tracked again on retry.
fn on_shard(
  state: State(meta, msg),
  topic: String,
  apply: fn() -> Result(State(meta, msg), String),
) -> Result(State(meta, msg), String) {
  case dict.has_key(state.shards, topic) {
    True -> apply()
    False -> Ok(state)
  }
}

/// Track on a (re)started shard. A key the shard already has was tracked
/// on it after the restart, before this watcher saw the old shard's DOWN:
/// its meta is brought up to date instead.
fn retrack(
  state: State(meta, msg),
  topic: String,
  key: String,
  meta: meta,
) -> Result(State(meta, msg), String) {
  use <- on_shard(state, topic)
  case presence.track(state.tracker, topic, key, meta) {
    Ok(_ref) -> Ok(state)
    Error(presence.AlreadyTracked) -> {
      log.info(
        "beacon.presence",
        "Presence watcher: "
          <> key
          <> " already tracked on "
          <> topic
          <> " after a shard restart, updating it",
      )
      update(state, topic, key, meta)
    }
    Error(presence.TrackerDown) ->
      Ok(lost(state, topic, "track again: shard down"))
    Error(reason) -> Error(describe(topic, reason))
  }
}

fn update(
  state: State(meta, msg),
  topic: String,
  key: String,
  meta: meta,
) -> Result(State(meta, msg), String) {
  use <- on_shard(state, topic)
  case presence.update(state.tracker, topic, key, meta) {
    Ok(_ref) -> Ok(state)
    // The shard restarted without the key: track it again with the rest.
    Error(presence.NotTracked) -> Ok(lost(state, topic, "update: not tracked"))
    Error(presence.TrackerDown) -> Ok(lost(state, topic, "update: shard down"))
    Error(reason) -> Error(describe(topic, reason))
  }
}

fn untrack(
  state: State(meta, msg),
  topic: String,
  key: String,
) -> Result(State(meta, msg), String) {
  use <- on_shard(state, topic)
  case presence.untrack(state.tracker, topic, key) {
    Ok(Nil) -> Ok(state)
    // The shard restarted without the key: the key is not tracked, which
    // is what is wanted, but the topic's other keys are gone too.
    Error(presence.NotTracked) -> Ok(lost(state, topic, "untrack: not tracked"))
    Error(presence.TrackerDown) -> Ok(lost(state, topic, "untrack: shard down"))
    Error(reason) -> Error(describe(topic, reason))
  }
}

fn describe(topic: String, reason: PresenceError) -> String {
  "tracking on " <> topic <> ": " <> presence.describe(reason)
}

/// The shard of `topic` lost its entries: track them again when it is back.
fn lost(
  state: State(meta, msg),
  topic: String,
  why: String,
) -> State(meta, msg) {
  log.warning(
    "beacon.presence",
    "Presence watcher of "
      <> presence.name(state.tracker)
      <> ": entries on "
      <> topic
      <> " lost ("
      <> why
      <> "), tracking them again",
  )
  let state =
    State(
      ..forget_shard(state, topic),
      pending: set.insert(state.pending, topic),
    )
  schedule_retry(state)
}

/// Stop following the shard of `topic`; demonitor it once no topic uses it.
fn forget_shard(state: State(meta, msg), topic: String) -> State(meta, msg) {
  case dict.get(state.shards, topic) {
    Error(Nil) -> state
    Ok(shard) -> {
      let shards = dict.delete(state.shards, topic)
      let in_use = dict.values(shards) |> list.contains(shard)
      let monitors = case in_use, dict.get(state.monitors, shard) {
        False, Ok(monitor) -> {
          process.demonitor_process(monitor)
          dict.delete(state.monitors, shard)
        }
        _, _ -> state.monitors
      }
      State(..state, shards:, monitors:)
    }
  }
}

fn shard_down(
  state: State(meta, msg),
  shard: Pid,
  reason: String,
) -> State(meta, msg) {
  let topics =
    dict.to_list(state.shards)
    |> list.filter_map(fn(pair) {
      case pair.1 == shard {
        True -> Ok(pair.0)
        False -> Error(Nil)
      }
    })
  log.warning(
    "beacon.presence",
    "Presence watcher of "
      <> presence.name(state.tracker)
      <> ": shard "
      <> string.inspect(shard)
      <> " went down ("
      <> reason
      <> ") with "
      <> int.to_string(list.length(topics))
      <> " tracked topics",
  )
  let state = State(..state, monitors: dict.delete(state.monitors, shard))
  list.fold(topics, state, fn(state, topic) {
    State(
      ..state,
      shards: dict.delete(state.shards, topic),
      pending: set.insert(state.pending, topic),
    )
  })
  |> schedule_retry
}

fn schedule_retry(state: State(meta, msg)) -> State(meta, msg) {
  case state.retries {
    // A retry is already scheduled; it handles every pending topic.
    retries if retries > 0 -> state
    _ -> {
      process.send_after(state.commands, first_retry_ms, Retry)
      State(..state, retries: 1)
    }
  }
}

fn retry(state: State(meta, msg)) -> Result(State(meta, msg), String) {
  let pending = set.to_list(state.pending) |> list.sort(string.compare)
  // `lost` must not schedule another retry while this one runs.
  let attempt = state.retries
  use state <- result.try(list.try_fold(
    pending,
    State(..state, retries: attempt),
    activate,
  ))
  case set.size(state.pending) {
    0 -> {
      log.info(
        "beacon.presence",
        "Presence watcher of "
          <> presence.name(state.tracker)
          <> " tracked again on "
          <> string.join(pending, ", ")
          <> " after "
          <> int.to_string(attempt)
          <> " attempt(s)",
      )
      Ok(State(..state, retries: 0))
    }
    _ ->
      case attempt >= max_retries {
        True -> {
          let left = set.to_list(state.pending) |> list.sort(string.compare)
          let reason =
            "could not track again on "
            <> string.join(left, ", ")
            <> " after "
            <> int.to_string(attempt)
            <> " attempts: the presence tracker is down"
          log.error(
            "beacon.presence",
            "Presence watcher of "
              <> presence.name(state.tracker)
              <> ": "
              <> reason
              <> "; stopping its runtime",
          )
          exit(BeaconPresenceDown(reason))
        }
        False -> {
          process.send_after(state.commands, retry_delay(attempt + 1), Retry)
          Ok(State(..state, retries: attempt + 1))
        }
      }
  }
}

/// The delay before retry `attempt` (1-based).
fn retry_delay(attempt: Int) -> Int {
  int.min(max_retry_ms, first_retry_ms * pow2(attempt - 1))
}

fn pow2(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * pow2(n - 1)
  }
}

// --- Diffs --------------------------------------------------------------------

/// Tell the app what changed on `topic` since it was last told: joins for
/// listed metas it does not know, leaves for known metas of this node no
/// longer listed.
///
/// A known meta of another node that is not listed is held as a suspect,
/// not reported: a shard that restarted starts empty and gets each other
/// node's entries from that node (its heartbeat marks the node up, the
/// transfer at the next clock sample carries them). Reporting them now
/// would make them leave and join again. `shard` is asked to say when it
/// has synced with their nodes; `synced` reports the ones still missing
/// then (Phoenix.Tracker's replica up and state transfer).
fn reconcile(
  state: State(meta, msg),
  topic: String,
  shard: Pid,
) -> Result(State(meta, msg), String) {
  case presence.list(state.tracker, topic) {
    Error(presence.TrackerDown) -> Ok(lost(state, topic, "list: shard down"))
    Error(reason) -> Error(describe(topic, reason))
    Ok(entries) -> {
      let listed = listed_metas(entries)
      let known = dict.get(state.known, topic) |> result.unwrap(dict.new())
      let joins =
        dict.filter(listed, fn(ref, _) { !dict.has_key(known, ref) })
        |> dict.values
      let missing =
        dict.filter(known, fn(ref, _) { !dict.has_key(listed, ref) })
      let own = node_name()
      // This node's entries died with the old shard: this watcher's were
      // tracked again with new refs, other local processes track theirs.
      let leaves =
        dict.filter(missing, fn(_, pair) { { pair.1 }.node == own })
        |> dict.values
      let held = dict.filter(missing, fn(_, pair) { { pair.1 }.node != own })
      report(state, topic, joins, leaves)
      let state =
        State(
          ..state,
          known: dict.insert(state.known, topic, dict.merge(listed, held)),
        )
      case dict.is_empty(held) {
        True -> Ok(State(..state, suspects: dict.delete(state.suspects, topic)))
        False -> {
          let nodes =
            dict.values(held)
            |> list.map(fn(pair) { { pair.1 }.node })
            |> list.unique
            |> list.sort(string.compare)
          log.info(
            "beacon.presence",
            "Presence watcher of "
              <> presence.name(state.tracker)
              <> ": shard "
              <> string.inspect(shard)
              <> " does not list "
              <> int.to_string(dict.size(held))
              <> " entries of "
              <> string.join(nodes, ", ")
              <> " on "
              <> topic
              <> " yet; holding them until it has synced with those nodes",
          )
          await_sync(shard, nodes)
          let refs = set.from_list(dict.keys(held))
          Ok(State(..state, suspects: dict.insert(state.suspects, topic, refs)))
        }
      }
    }
  }
}

/// The metas of a read, by ref.
fn listed_metas(
  entries: List(sync.Entry(meta)),
) -> Dict(String, #(String, Meta(meta))) {
  list.flat_map(entries, fn(entry) {
    list.map(entry.metas, fn(meta) { #(meta.ref, #(entry.key, meta)) })
  })
  |> dict.from_list
}

/// `shard` has resolved its sync with `node`: on every topic it serves,
/// the suspects of `node` it still does not list leave. Their diffs, if
/// any, were sent before this answer, so they are already applied.
fn synced(
  state: State(meta, msg),
  shard: Pid,
  node: String,
  status: SyncStatus,
) -> Result(State(meta, msg), String) {
  let topics =
    dict.keys(state.suspects)
    |> list.filter(fn(topic) { dict.get(state.shards, topic) == Ok(shard) })
    |> list.sort(string.compare)
  case topics {
    [] -> {
      // The shard went down, or a later reconcile replaced the suspects.
      log.debug(
        "beacon.presence",
        "Presence watcher of "
          <> presence.name(state.tracker)
          <> " ignoring the sync of "
          <> string.inspect(shard)
          <> " with "
          <> node
          <> ": no suspects on it",
      )
      Ok(state)
    }
    _ ->
      list.try_fold(topics, state, fn(state, topic) {
        settle(state, topic, node, status)
      })
  }
}

/// Report the suspects of `node` on `topic` that the shard does not list.
fn settle(
  state: State(meta, msg),
  topic: String,
  node: String,
  status: SyncStatus,
) -> Result(State(meta, msg), String) {
  // INVARIANT: `synced` only settles topics with suspects, and every
  // topic with suspects has an entry in `known`.
  let assert Ok(suspects) = dict.get(state.suspects, topic)
    as "settle is only called for topics with suspects"
  let assert Ok(known) = dict.get(state.known, topic)
    as "every topic with suspects is known"
  // A suspect that left through a diff meanwhile is no longer known.
  let of_node =
    set.filter(suspects, fn(ref) {
      case dict.get(known, ref) {
        Ok(#(_, meta)) -> meta.node == node
        Error(Nil) -> False
      }
    })
  let rest =
    set.filter(suspects, fn(ref) {
      case dict.get(known, ref) {
        Ok(#(_, meta)) -> meta.node != node
        Error(Nil) -> False
      }
    })
  let state = case set.is_empty(rest) {
    True -> State(..state, suspects: dict.delete(state.suspects, topic))
    False -> State(..state, suspects: dict.insert(state.suspects, topic, rest))
  }
  case set.is_empty(of_node) {
    True -> Ok(state)
    False ->
      case presence.list(state.tracker, topic) {
        Error(presence.TrackerDown) ->
          Ok(lost(state, topic, "list after sync: shard down"))
        Error(reason) -> Error(describe(topic, reason))
        Ok(entries) -> {
          let listed = listed_metas(entries)
          let gone =
            set.filter(of_node, fn(ref) { !dict.has_key(listed, ref) })
            |> set.to_list
          let leaves = list.filter_map(gone, fn(ref) { dict.get(known, ref) })
          log_settled(state, topic, node, status, set.size(of_node), leaves)
          report(state, topic, [], leaves)
          let known = list.fold(gone, known, dict.delete)
          Ok(State(..state, known: dict.insert(state.known, topic, known)))
        }
      }
  }
}

fn log_settled(
  state: State(meta, msg),
  topic: String,
  node: String,
  status: SyncStatus,
  held: Int,
  leaves: List(#(String, Meta(meta))),
) -> Nil {
  let message =
    "Presence watcher of "
    <> presence.name(state.tracker)
    <> ": sync with "
    <> node
    <> " on "
    <> topic
    <> " is "
    <> describe_sync(status)
    <> "; "
    <> int.to_string(list.length(leaves))
    <> " of "
    <> int.to_string(held)
    <> " held entries left"
  case status {
    SyncTimeout -> log.warning("beacon.presence", message)
    InSync | NodeDown | NodeAbsent -> log.info("beacon.presence", message)
  }
}

fn describe_sync(status: SyncStatus) -> String {
  case status {
    InSync -> "done"
    NodeDown -> "moot, the node is down"
    NodeAbsent -> "moot, the shard has not heard from the node"
    SyncTimeout -> "not done within down_period"
  }
}

/// Coalesce queued diff deliveries of one topic into one message.
fn report_diffs(
  state: State(meta, msg),
  diff_topic: String,
  messages: List(Dynamic),
) -> Result(State(meta, msg), String) {
  use diffs <- result.try(
    list.try_map(messages, fn(message) {
      presence.decode_diff(state.tracker, message)
      |> result.map_error(fn(reason) {
        "a delivery on " <> diff_topic <> ": " <> presence.describe(reason)
      })
    }),
  )
  case diffs {
    [] -> Ok(state)
    [Diff(topic:, ..), ..] ->
      case dict.get(state.known, topic) {
        Error(Nil) -> {
          // Delivered before this watcher unsubscribed from the topic.
          log.debug(
            "beacon.presence",
            "Presence watcher dropping "
              <> int.to_string(list.length(diffs))
              <> " diffs of untracked topic "
              <> topic,
          )
          Ok(state)
        }
        Ok(known) -> {
          let #(known, joins, leaves) =
            list.fold(diffs, #(known, dict.new(), dict.new()), apply_diff)
          report(state, topic, dict.values(joins), dict.values(leaves))
          Ok(State(..state, known: dict.insert(state.known, topic, known)))
        }
      }
  }
}

/// Fold one diff into what the app knows and the batch's net joins and
/// leaves (by ref). A join already known and a leave never known are
/// duplicates (from the initial read or a reconcile) and are dropped.
fn apply_diff(
  acc: #(
    Dict(String, #(String, Meta(meta))),
    Dict(String, #(String, Meta(meta))),
    Dict(String, #(String, Meta(meta))),
  ),
  diff: Diff(meta),
) -> #(
  Dict(String, #(String, Meta(meta))),
  Dict(String, #(String, Meta(meta))),
  Dict(String, #(String, Meta(meta))),
) {
  let acc =
    list.fold(diff.joins, acc, fn(acc, entry) {
      list.fold(entry.metas, acc, fn(acc, meta) {
        let #(known, joins, leaves) = acc
        case dict.has_key(known, meta.ref) {
          True -> acc
          False -> {
            let known = dict.insert(known, meta.ref, #(entry.key, meta))
            case dict.has_key(leaves, meta.ref) {
              True -> #(known, joins, dict.delete(leaves, meta.ref))
              False -> #(
                known,
                dict.insert(joins, meta.ref, #(entry.key, meta)),
                leaves,
              )
            }
          }
        }
      })
    })
  list.fold(diff.leaves, acc, fn(acc, entry) {
    list.fold(entry.metas, acc, fn(acc, meta) {
      let #(known, joins, leaves) = acc
      case dict.get(known, meta.ref) {
        Error(Nil) -> acc
        Ok(left) -> {
          let known = dict.delete(known, meta.ref)
          case dict.has_key(joins, meta.ref) {
            True -> #(known, dict.delete(joins, meta.ref), leaves)
            False -> #(known, joins, dict.insert(leaves, meta.ref, left))
          }
        }
      }
    })
  })
}

/// Send the app one `on_presence` message, unless nothing changed.
fn report(
  state: State(meta, msg),
  topic: String,
  joins: List(#(String, Meta(meta))),
  leaves: List(#(String, Meta(meta))),
) -> Nil {
  case joins, leaves {
    [], [] -> Nil
    _, _ -> {
      log.debug(
        "beacon.presence",
        "Presence on "
          <> topic
          <> ": "
          <> int.to_string(list.length(joins))
          <> " joins, "
          <> int.to_string(list.length(leaves))
          <> " leaves",
      )
      let diff = Diff(topic:, joins: entries(joins), leaves: entries(leaves))
      state.dispatch(state.on_presence(diff))
    }
  }
}

/// Group metas by key, ordered by key (and by ref within a key).
fn entries(metas: List(#(String, Meta(meta)))) -> List(sync.Entry(meta)) {
  metas
  |> list.sort(fn(a, b) {
    case string.compare(a.0, b.0) {
      order.Eq -> string.compare({ a.1 }.ref, { b.1 }.ref)
      other -> other
    }
  })
  |> list.chunk(fn(pair) { pair.0 })
  |> list.filter_map(fn(group) {
    case group {
      [#(key, _), ..] ->
        Ok(Entry(key:, metas: list.map(group, fn(pair) { pair.1 })))
      [] -> Error(Nil)
    }
  })
}

// --- FFI ----------------------------------------------------------------------

@external(erlang, "beacon_presence_watch_ffi", "receive_event")
fn receive_event(
  commands: Subject(Command(meta)),
  owner: #(Monitor, Pid),
  partition: Monitor,
  name: String,
) -> Event(meta)

/// Ask `shard` to send a `Synced` event per node once it has synced.
@external(erlang, "beacon_presence_watch_ffi", "await_sync")
fn await_sync(shard: Pid, nodes: List(String)) -> Nil

/// This node's name, as entries' `Meta.node` carries it.
@external(erlang, "beacon_presence_watch_ffi", "node_name")
fn node_name() -> String

@external(erlang, "beacon_presence_watch_ffi", "exit")
fn exit(reason: ExitReason) -> a

@external(erlang, "beacon_presence_watch_ffi", "trap_exits")
fn trap_exits() -> Nil

@external(erlang, "beacon_presence_watch_ffi", "set_label")
fn set_label(name: String) -> Nil
