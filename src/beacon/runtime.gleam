/// Beacon's server-side MVU runtime.
/// Runs the Model-View-Update loop as an OTP actor, one per user session.
/// Follows Lustre's runtime/server/runtime.gleam pattern.
///
/// Reference: Lustre server runtime, LiveView process model, Reflex event chain.
///
/// ## Versioning (one rule, shared with the client)
///
/// The runtime keeps a single `revision` counter. It starts at 0 and is
/// incremented exactly when the client-visible model JSON changes and is
/// sent as a patch or resync broadcast. Every `patch` carries the revision
/// it produces; every `model_sync` carries the current revision. The client
/// applies a non-empty patch only when `version == current + 1`, treats an
/// empty patch at `version == current` as a pure acknowledgement, ignores
/// stale versions, and requests a full sync on a gap. Navigation, joins and
/// acknowledgements never bump the revision on their own.
///
/// `ack_clock` is per connection: the highest event clock that connection
/// sent which the server has processed. It is never shared between
/// connections.
import beacon/cookie
import beacon/effect.{type Effect}
import beacon/element.{type Node}
import beacon/error
import beacon/log
import beacon/notification.{type Notification, Notification}
import beacon/patch
import beacon/pubsub
import beacon/route
import beacon/ssr
import beacon/transport
import beacon/transport/server
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/set.{type Set}
import gleam/string

/// The client-visible model JSON every joined connection currently holds
/// (at `revision`). Diffs are computed against it.
///
/// Invariant: when the cache is not `NoCache` it equals the snapshot of the
/// runtime's current model as last sent to every joined connection.
pub type CachedModelState {
  /// Nothing trustworthy is cached (no joined connections yet, or the last
  /// broadcast failed). The next broadcast is a full `model_sync`.
  NoCache
  /// No substates — the full model JSON.
  FullModelCache(json: String)
  /// Substates — per-substate JSON plus the flat (non-substate) fields JSON.
  SubstateCache(substate_jsons: Dict(String, String), flat_fields_json: String)
}

/// The generated per-substate encoders, resolved once at start.
@internal
pub type SubstateCodecs(model) {
  /// The model has no substates: diff the full model JSON.
  NoSubstates
  /// Encode each substate and the flat fields independently so unchanged
  /// substates skip diffing.
  Substates(
    encoders: List(#(String, fn(model) -> String)),
    flat: fn(model) -> String,
  )
}

/// Messages the runtime actor can receive.
pub type RuntimeMessage(msg) {
  /// A client connected — register their transport subject for pushing updates.
  ClientConnected(
    conn_id: transport.ConnectionId,
    subject: Subject(transport.InternalMessage),
  )
  /// A client disconnected — remove their transport subject.
  ClientDisconnected(conn_id: transport.ConnectionId)
  /// A client sent a join request with no browser session binding
  /// (equivalent to `ClientJoinedWithSession` with fingerprint "").
  ClientJoined(conn_id: transport.ConnectionId, token: String, path: String)
  /// A client sent a join request. `token` is the signed join token (empty
  /// for none) and `session_fingerprint` identifies the browser session the
  /// connection belongs to (see `ssr.session_fingerprint`); the token only
  /// verifies for the session it was issued to.
  ClientJoinedWithSession(
    conn_id: transport.ConnectionId,
    token: String,
    path: String,
    session_fingerprint: String,
  )
  /// A client event was received — decode to user message and run update.
  ClientEventReceived(
    conn_id: transport.ConnectionId,
    event_name: String,
    handler_id: String,
    event_data: String,
    target_path: String,
    clock: Int,
    /// JSON-encoded patch ops from client. Empty string means no ops.
    ops: String,
  )
  /// A batch of events to process atomically (all updates, one render).
  /// Used when LOCAL events are replayed before a MODEL event.
  ClientEventBatchReceived(
    conn_id: transport.ConnectionId,
    events: List(#(String, String, String, String, Int, String)),
  )
  /// A client navigated to a new URL path.
  ClientNavigated(conn_id: transport.ConnectionId, path: String)
  /// Client requested a full model sync without a remount.
  ClientSyncRequested(conn_id: transport.ConnectionId)
  /// Set the listener subject for dynamic subscription management.
  SetListenerSubject(
    listener: Subject(ListenerCommand),
    initial_subs: List(String),
  )
  /// An effect dispatched a message back to the runtime.
  EffectDispatched(message: msg)
  /// A keyed effect dispatched a message back to the runtime.
  EffectDispatchedKeyed(key: String, generation: Int, message: msg)
  /// Shutdown the runtime.
  Shutdown
}

/// The runtime's internal state.
pub type RuntimeState(model, msg) {
  RuntimeState(
    /// The application's current model.
    model: model,
    /// The update function: model + message → new model + effects.
    update: fn(model, msg) -> #(model, Effect(msg)),
    /// Decodes client events into user messages (configured or generated).
    decode_event: fn(String, String, String, String) ->
      Result(msg, error.BeaconError),
    /// Currently connected clients: conn_id → transport subject.
    connections: Dict(
      transport.ConnectionId,
      Subject(transport.InternalMessage),
    ),
    /// Connections that completed a join. Only these receive patches and
    /// may send events.
    joined: Set(transport.ConnectionId),
    /// Per-connection acknowledged event clock.
    client_acks: Dict(transport.ConnectionId, Int),
    /// Client-visible model revision (see the module docs).
    revision: Int,
    /// Whether a join has been accepted. Join-token state recovery only
    /// applies to the first join of a runtime.
    accepted_first_join: Bool,
    /// The runtime's own subject for dispatching effect messages.
    self: Subject(RuntimeMessage(msg)),
    /// Client-visible model encoder, resolved once at start (generated
    /// `beacon_codec.encode_model` first, else the configured serializer).
    model_encoder: Option(fn(model) -> String),
    /// Generated substate encoders, resolved once at start.
    substate_codecs: SubstateCodecs(model),
    /// Deserialize model from string for state recovery.
    deserialize_model: Option(fn(String) -> Result(model, String)),
    /// Secret key for join tokens.
    secret_key: String,
    /// Route patterns for URL matching.
    route_patterns: List(route.RoutePattern),
    /// Called when URL changes — produces a Msg for the update loop.
    on_route_change: Option(fn(route.Route) -> msg),
    /// Called before a client-side route transition is applied.
    on_route_leave: Option(fn(route.Route, route.Route) -> Effect(msg)),
    /// Most recently matched client route, used to gate route handlers.
    current_route: Option(route.Route),
    /// Subject for sending commands to the PubSub listener process.
    listener_subject: Option(Subject(ListenerCommand)),
    /// Current set of dynamic subscriptions (for diffing).
    current_subscriptions: List(String),
    /// Dynamic subscription function: model → list of topics.
    dynamic_subscriptions: Option(fn(model) -> List(String)),
    /// Cached client-visible model JSON for diffing.
    cached_model: CachedModelState,
    /// Framework-owned effect processes, such as effect.every timers.
    effect_processes: List(Pid),
  )
}

/// Configuration needed to start a runtime.
pub type RuntimeConfig(model, msg) {
  RuntimeConfig(
    /// Initial model and effects.
    init: fn() -> #(model, Effect(msg)),
    /// The update function.
    update: fn(model, msg) -> #(model, Effect(msg)),
    /// The view function.
    view: fn(model) -> Node(msg),
    /// Decode client events into user messages.
    /// If None, beacon_codec.decode_event/4 must be generated and compiled.
    decode_event: Option(
      fn(String, String, String, String) -> Result(msg, error.BeaconError),
    ),
    /// Serialize model to a string. Used on the wire (and in join tokens)
    /// only when no generated `beacon_codec.encode_model` exists.
    serialize_model: option.Option(fn(model) -> String),
    /// Deserialize model from a string (from the join token).
    /// Receives the client-visible model JSON; it must rebuild any Server
    /// state itself. Returns Error if the data is stale/invalid.
    deserialize_model: option.Option(fn(String) -> Result(model, String)),
    /// Route patterns for URL matching.
    route_patterns: List(route.RoutePattern),
    /// Called when URL changes — produces a Msg for the update loop.
    on_route_change: option.Option(fn(route.Route) -> msg),
    /// Called before a client-side route transition is applied.
    on_route_leave: option.Option(fn(route.Route, route.Route) -> Effect(msg)),
    /// Dynamic subscription function: given the current model, returns
    /// the set of topics this runtime should be subscribed to.
    /// Called after every update and join. The framework diffs against
    /// current subscriptions.
    dynamic_subscriptions: option.Option(fn(model) -> List(String)),
    /// Called when a PubSub notification arrives on a dynamically subscribed topic.
    /// Receives the topic string so the handler can distinguish between sources.
    on_notify: option.Option(fn(String) -> msg),
    /// Called when a typed PubSub notification arrives on a dynamically subscribed topic.
    on_notification: option.Option(fn(Notification) -> msg),
    /// Optional: request-aware init — replaces `init` when the HTTP request is available.
    /// Used by ws_init to pass cookies/headers into server state initialization.
    /// If set and a request is provided, this is used instead of `init`.
    init_from_request: option.Option(
      fn(request.Request(server.Connection)) -> #(model, Effect(msg)),
    ),
    /// Secret key for join-token verification.
    /// Threaded from AppConfig — must not be empty when state recovery is enabled.
    secret_key: String,
    /// Enable framework-owned client tracing.
    dev_mode: Bool,
  )
}

/// Start a runtime actor. Returns a Subject for sending RuntimeMessages.
///
/// All codecs are resolved here, once: a missing event decoder, or a
/// generated codec that declares substates without their encoders, is a
/// `ConfigError`.
pub fn start(
  config: RuntimeConfig(model, msg),
) -> Result(Subject(RuntimeMessage(msg)), error.BeaconError) {
  let event_decoder = case config.decode_event {
    Some(decoder) -> Some(decoder)
    None -> discover_event_decoder()
  }
  let model_encoder = ssr.client_visible_model_encoder(config.serialize_model)
  let substate_codecs =
    resolve_substate_codecs(
      try_load_substate_names(),
      try_load_substate_encoder,
      try_load_flat_encoder,
    )

  case event_decoder, substate_codecs, model_encoder {
    None, _, _ -> {
      let reason =
        "Missing event decoder. Beacon live apps must provide decode_event or run beacon/build so beacon_codec.decode_event/4 is generated; server-side view rendering is not used for event decoding."
      log.error("beacon.runtime", reason)
      Error(error.ConfigError(reason: reason))
    }
    _, Error(err), _ -> Error(err)
    _, Ok(Substates(..)), None -> {
      let reason =
        "beacon_codec declares substates but no model encoder is available for model_sync"
      log.error("beacon.runtime", reason)
      Error(error.ConfigError(reason: reason))
    }
    Some(event_decoder), Ok(substate_codecs), _ -> {
      case model_encoder {
        Some(_) -> Nil
        None ->
          log.warning(
            "beacon.runtime",
            "No model encoder (generated beacon_codec.encode_model or configured serialize_model); clients will receive \"Model encoder missing\" errors",
          )
      }
      start_actor(config, event_decoder, model_encoder, substate_codecs)
    }
  }
}

fn start_actor(
  config: RuntimeConfig(model, msg),
  event_decoder: fn(String, String, String, String) ->
    Result(msg, error.BeaconError),
  model_encoder: Option(fn(model) -> String),
  substate_codecs: SubstateCodecs(model),
) -> Result(Subject(RuntimeMessage(msg)), error.BeaconError) {
  let #(initial_model, initial_effects) = config.init()
  let result =
    actor.new_with_initialiser(5000, fn(subject) {
      let initial_effect_processes = run_effects(initial_effects, subject)
      let state =
        RuntimeState(
          model: initial_model,
          update: config.update,
          decode_event: event_decoder,
          connections: dict.new(),
          joined: set.new(),
          client_acks: dict.new(),
          revision: 0,
          accepted_first_join: False,
          self: subject,
          model_encoder: model_encoder,
          substate_codecs: substate_codecs,
          deserialize_model: config.deserialize_model,
          secret_key: config.secret_key,
          route_patterns: config.route_patterns,
          on_route_change: config.on_route_change,
          on_route_leave: config.on_route_leave,
          current_route: None,
          listener_subject: None,
          current_subscriptions: [],
          dynamic_subscriptions: config.dynamic_subscriptions,
          cached_model: NoCache,
          effect_processes: initial_effect_processes,
        )
      log.debug("beacon.runtime", "Runtime initialising")

      actor.initialised(state)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> {
      log.info("beacon.runtime", "Runtime actor started")
      let subject = started.data
      log.debug(
        "beacon.runtime",
        "Dynamic subs: "
          <> yes_no(option.is_some(config.dynamic_subscriptions))
          <> ", on_notify: "
          <> yes_no(option.is_some(config.on_notify))
          <> ", on_notification: "
          <> yes_no(option.is_some(config.on_notification))
          <> ", substates: "
          <> case substate_codecs {
          NoSubstates -> "none"
          Substates(encoders, _) -> int.to_string(list.length(encoders))
        },
      )
      case config.dynamic_subscriptions {
        Some(compute) -> {
          let initial_topics = compute(initial_model)
          let listener =
            start_pubsub_listener(
              subject,
              started.pid,
              config.on_notify,
              config.on_notification,
              initial_topics,
            )
          process.send(
            subject,
            SetListenerSubject(listener: listener, initial_subs: initial_topics),
          )
        }
        None -> Nil
      }
      Ok(subject)
    }
    Error(actor.InitTimeout) -> {
      log.error("beacon.runtime", "Failed to start runtime: init timed out")
      Error(error.RuntimeError(reason: "Runtime init timed out"))
    }
    Error(actor.InitFailed(reason)) -> {
      log.error("beacon.runtime", "Failed to start runtime: " <> reason)
      Error(error.RuntimeError(reason: "Runtime init failed: " <> reason))
    }
    Error(actor.InitExited(_reason)) -> {
      log.error(
        "beacon.runtime",
        "Failed to start runtime: init process exited",
      )
      Error(error.RuntimeError(reason: "Runtime init process exited"))
    }
  }
}

fn yes_no(flag: Bool) -> String {
  case flag {
    True -> "YES"
    False -> "NO"
  }
}

/// Resolve the generated substate encoders once.
///
/// - no `substate_names` export, or an empty list → `NoSubstates`
/// - names present → every `encode_substate_<name>` and `encode_flat_fields`
///   must exist, otherwise the generated codec is stale or corrupt and this
///   is a logged `ConfigError` (a silently skipped substate would never
///   reach the client).
@internal
pub fn resolve_substate_codecs(
  names: Result(List(String), Nil),
  load_encoder: fn(String) -> Result(fn(model) -> String, Nil),
  load_flat: fn() -> Result(fn(model) -> String, Nil),
) -> Result(SubstateCodecs(model), error.BeaconError) {
  case names {
    Error(Nil) | Ok([]) -> Ok(NoSubstates)
    Ok(names) -> {
      let unique = list.unique(names)
      case list.length(unique) == list.length(names) {
        False ->
          substate_config_error("beacon_codec.substate_names has duplicates")
        True -> {
          let #(encoders, missing) =
            list.fold(names, #([], []), fn(acc, name) {
              let #(found, missing) = acc
              case load_encoder(name) {
                Ok(encoder) -> #([#(name, encoder), ..found], missing)
                Error(Nil) -> #(found, [name, ..missing])
              }
            })
          case missing, load_flat() {
            [], Ok(flat) -> {
              log.debug(
                "beacon.runtime",
                "Resolved "
                  <> int.to_string(list.length(names))
                  <> " substate encoders: "
                  <> string.join(names, ", "),
              )
              Ok(Substates(encoders: list.reverse(encoders), flat: flat))
            }
            [], Error(Nil) ->
              substate_config_error(
                "beacon_codec declares substates but encode_flat_fields/1 is missing",
              )
            _, _ ->
              substate_config_error(
                "beacon_codec declares substates without encoders: "
                <> string.join(list.reverse(missing), ", "),
              )
          }
        }
      }
    }
  }
}

fn substate_config_error(reason: String) -> Result(a, error.BeaconError) {
  log.error(
    "beacon.runtime",
    reason <> " (regenerate the codec with beacon/build)",
  )
  Error(error.ConfigError(reason: reason))
}

/// The main message loop for the runtime actor.
/// Follows Lustre's loop pattern: handle message → update state → return Next.
fn handle_message(
  state: RuntimeState(model, msg),
  message: RuntimeMessage(msg),
) -> actor.Next(RuntimeState(model, msg), RuntimeMessage(msg)) {
  case message {
    ClientConnected(conn_id, subject) -> {
      let state = case dict.has_key(state.connections, conn_id) {
        True -> {
          log.warning(
            "beacon.runtime",
            "Connection "
              <> conn_id
              <> " registered again; it must join again before receiving updates",
          )
          forget_connection(state, conn_id)
        }
        False -> {
          log.info("beacon.runtime", "Client connected: " <> conn_id)
          state
        }
      }
      actor.continue(
        RuntimeState(
          ..state,
          connections: dict.insert(state.connections, conn_id, subject),
        ),
      )
    }

    ClientDisconnected(conn_id) -> {
      log.info("beacon.runtime", "Client disconnected: " <> conn_id)
      actor.continue(forget_connection(state, conn_id))
    }

    ClientJoined(conn_id, token, path) ->
      actor.continue(handle_join(state, conn_id, token, path, ""))

    ClientJoinedWithSession(conn_id, token, path, session_fingerprint) ->
      actor.continue(handle_join(
        state,
        conn_id,
        token,
        path,
        session_fingerprint,
      ))

    ClientEventReceived(
      conn_id,
      event_name,
      handler_id,
      event_data,
      target_path,
      clock,
      ops,
    ) ->
      case set.contains(state.joined, conn_id) {
        False -> actor.continue(reject_before_join(state, conn_id, "event"))
        True -> {
          log.debug(
            "beacon.runtime",
            "Event from "
              <> conn_id
              <> ": "
              <> event_name
              <> " ["
              <> handler_id
              <> "] clock="
              <> int.to_string(clock),
          )
          warn_client_ops(conn_id, ops)
          let state = record_ack(state, conn_id, clock)
          case
            state.decode_event(event_name, handler_id, event_data, target_path)
          {
            Ok(msg) -> {
              let #(state, changed) = run_update_for(state, msg, Some(conn_id))
              actor.continue(ack_if_unchanged(state, conn_id, changed))
            }
            Error(err) -> {
              let err_str = error.to_string(err)
              log.warning(
                "beacon.runtime",
                "Failed to decode event from " <> conn_id <> ": " <> err_str,
              )
              send_to_conn_id(state, conn_id, transport.SendError(err_str))
              // The rejected event is still acknowledged so the client drops
              // its optimistic state and returns to the server's model.
              actor.continue(ack_if_unchanged(state, conn_id, False))
            }
          }
        }
      }

    ClientEventBatchReceived(conn_id, events) ->
      case set.contains(state.joined, conn_id) {
        False ->
          actor.continue(reject_before_join(state, conn_id, "event batch"))
        True -> actor.continue(handle_batch(state, conn_id, events))
      }

    ClientNavigated(conn_id, path) ->
      case set.contains(state.joined, conn_id) {
        False ->
          actor.continue(reject_before_join(state, conn_id, "navigation"))
        True -> {
          log.info("beacon.runtime", "Navigation: " <> conn_id <> " → " <> path)
          let matched_route = route_for_path(state.route_patterns, path)
          let state =
            apply_route(state, matched_route, Some(conn_id), RouteOnNavigate)
          actor.continue(state)
        }
      }

    ClientSyncRequested(conn_id) ->
      case set.contains(state.joined, conn_id) {
        False ->
          actor.continue(reject_before_join(state, conn_id, "sync request"))
        True -> {
          log.warning(
            "beacon.runtime",
            "Client requested full model sync: " <> conn_id,
          )
          actor.continue(resync(state, conn_id, "client_request_sync"))
        }
      }

    SetListenerSubject(listener, initial_subs) -> {
      log.debug("beacon.runtime", "Listener subject registered")
      // The model may have changed (init effects) since the initial topics
      // were computed; reconcile immediately.
      actor.continue(update_dynamic_subscriptions(
        RuntimeState(
          ..state,
          listener_subject: Some(listener),
          current_subscriptions: initial_subs,
        ),
      ))
    }

    EffectDispatched(msg) -> {
      log.debug("beacon.runtime", "Effect dispatched a message")
      let #(state, _changed) = run_update_for(state, msg, None)
      actor.continue(state)
    }

    EffectDispatchedKeyed(key, generation, msg) -> {
      case effect.is_current_key_generation(key, generation) {
        True -> {
          log.debug("beacon.runtime", "Keyed effect dispatched for key " <> key)
          let #(state, _changed) = run_update_for(state, msg, None)
          actor.continue(state)
        }
        False -> {
          log.debug(
            "beacon.runtime",
            "Dropping stale keyed effect for key " <> key,
          )
          actor.continue(state)
        }
      }
    }

    Shutdown -> {
      log.info("beacon.runtime", "Runtime shutting down")
      stop_listener(state.listener_subject)
      stop_effect_processes(state.effect_processes)
      actor.stop()
    }
  }
}

/// Remove every trace of a connection. With no joined connection left the
/// cache no longer describes anyone's state.
fn forget_connection(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
) -> RuntimeState(model, msg) {
  let joined = set.delete(state.joined, conn_id)
  RuntimeState(
    ..state,
    connections: dict.delete(state.connections, conn_id),
    joined: joined,
    client_acks: dict.delete(state.client_acks, conn_id),
    cached_model: case set.is_empty(joined) {
      True -> NoCache
      False -> state.cached_model
    },
  )
}

fn warn_client_ops(conn_id: transport.ConnectionId, ops: String) -> Nil {
  case ops {
    "" -> Nil
    _ ->
      log.warning(
        "beacon.runtime",
        "Ignoring client-supplied model ops from "
          <> conn_id
          <> " because server update is authoritative",
      )
  }
}

/// Reject a message that requires a joined connection. Nothing is applied.
fn reject_before_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  what: String,
) -> RuntimeState(model, msg) {
  log.warning(
    "beacon.runtime",
    "Rejected " <> what <> " from " <> conn_id <> ": connection has not joined",
  )
  send_to_conn_id(
    state,
    conn_id,
    transport.SendError(reason: what <> " received before join"),
  )
  state
}

/// Join (or rejoin) a connection.
///
/// - First join of the runtime: the join token is verified (signature,
///   purpose, expiry, session binding) and, when it carries a model and a
///   deserializer is configured, the model is recovered from it.
/// - Repeated join on an already-joined connection: an explicit, logged
///   rejoin. The token is not used; the connection gets a full model_sync.
/// - The route handlers run only when the joined path's route differs from
///   the current route (a join never re-runs them for the same route).
fn handle_join(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  token: String,
  path: String,
  session_fingerprint: String,
) -> RuntimeState(model, msg) {
  case dict.has_key(state.connections, conn_id) {
    False -> {
      log.warning(
        "beacon.runtime",
        "Join from unregistered connection " <> conn_id <> " rejected",
      )
      state
    }
    True -> {
      let state = case set.contains(state.joined, conn_id) {
        True -> {
          log.info(
            "beacon.runtime",
            "Rejoin from "
              <> conn_id
              <> " path: "
              <> path
              <> " — full resync, join token not used",
          )
          RuntimeState(..state, joined: set.delete(state.joined, conn_id))
        }
        False -> {
          log.info(
            "beacon.runtime",
            "Client joined: " <> conn_id <> " path: " <> path,
          )
          recover_from_join_token(state, conn_id, token, session_fingerprint)
        }
      }
      let matched_route = route_for_path(state.route_patterns, path)
      // Route changes are broadcast to the OTHER joined connections; the
      // joiner is not joined yet and gets the result in its model_sync.
      let state = apply_route(state, matched_route, Some(conn_id), RouteOnJoin)
      // If the cache is unusable, the other joined connections may be stale
      // too: resync everyone, not just the joiner.
      let stale_others = case state.cached_model {
        NoCache -> set.to_list(state.joined)
        _ -> []
      }
      let state =
        RuntimeState(
          ..state,
          joined: set.insert(state.joined, conn_id),
          accepted_first_join: True,
          client_acks: case dict.has_key(state.client_acks, conn_id) {
            True -> state.client_acks
            False -> dict.insert(state.client_acks, conn_id, 0)
          },
        )
      let state =
        send_model_sync_to(state, [conn_id, ..stale_others], "join_model_sync")
      update_dynamic_subscriptions(state)
    }
  }
}

/// Verify the join token and recover the model from it when allowed.
/// Every failure is logged and the join proceeds with the server model.
fn recover_from_join_token(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  token: String,
  session_fingerprint: String,
) -> RuntimeState(model, msg) {
  case token {
    "" -> {
      log.debug("beacon.runtime", "No join token for " <> conn_id)
      state
    }
    _ ->
      case
        ssr.verify_join_token(
          token,
          state.secret_key,
          session_fingerprint,
          system_time_seconds(),
        )
      {
        Error(err) -> {
          log.warning(
            "beacon.runtime",
            "Join token from "
              <> conn_id
              <> " rejected: "
              <> ssr.describe_join_token_error(err)
              <> " — joining with the server model",
          )
          state
        }
        Ok(verified) ->
          case state.accepted_first_join, verified.model_json {
            True, _ -> {
              log.debug(
                "beacon.runtime",
                "Join token from "
                  <> conn_id
                  <> " verified; runtime already has a joined model, not recovering",
              )
              state
            }
            False, None -> {
              log.debug(
                "beacon.runtime",
                "Join token from " <> conn_id <> " carries no model",
              )
              state
            }
            False, Some(model_json) ->
              case state.deserialize_model {
                None -> {
                  log.debug(
                    "beacon.runtime",
                    "Join token carries a model but no deserializer is configured",
                  )
                  state
                }
                Some(deserialize) ->
                  case deserialize(model_json) {
                    Ok(model) -> {
                      log.info(
                        "beacon.runtime",
                        "State recovered from join token for " <> conn_id,
                      )
                      RuntimeState(..state, model: model)
                    }
                    Error(reason) -> {
                      log.warning(
                        "beacon.runtime",
                        "Join token model rejected by deserializer for "
                          <> conn_id
                          <> ": "
                          <> reason
                          <> " — joining with the server model",
                      )
                      state
                    }
                  }
              }
          }
      }
  }
}

/// Process a batch: every update runs, then one broadcast. The batch is
/// acknowledged up to its highest clock, including events that failed to
/// decode (they are reported to the client, never silently dropped).
fn handle_batch(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  events: List(#(String, String, String, String, Int, String)),
) -> RuntimeState(model, msg) {
  let count = list.length(events)
  log.debug(
    "beacon.runtime",
    "Atomic batch from " <> conn_id <> ": " <> int.to_string(count) <> " events",
  )
  case events {
    [] -> {
      log.warning(
        "beacon.runtime",
        "Empty event batch from " <> conn_id <> " ignored",
      )
      state
    }
    _ -> {
      let #(state, failures) =
        list.index_fold(events, #(state, []), fn(acc, evt, idx) {
          let #(acc_state, failures) = acc
          let #(event_name, handler_id, event_data, target_path, clock, ops) =
            evt
          warn_client_ops(conn_id, ops)
          let acc_state = record_ack(acc_state, conn_id, clock)
          case
            acc_state.decode_event(
              event_name,
              handler_id,
              event_data,
              target_path,
            )
          {
            Ok(msg) -> #(
              run_update_only(acc_state, msg, Some(conn_id)),
              failures,
            )
            Error(err) -> {
              let reason = error.to_string(err)
              log.warning(
                "beacon.runtime",
                "Event rejected in batch from "
                  <> conn_id
                  <> " (idx "
                  <> int.to_string(idx)
                  <> "/"
                  <> int.to_string(count)
                  <> ", handler="
                  <> handler_id
                  <> "): "
                  <> reason,
              )
              #(acc_state, [reason, ..failures])
            }
          }
        })
      case list.reverse(failures) {
        [] -> Nil
        [first, ..] as all ->
          send_to_conn_id(
            state,
            conn_id,
            transport.SendError(
              reason: int.to_string(list.length(all))
              <> " of "
              <> int.to_string(count)
              <> " batched events rejected: "
              <> first,
            ),
          )
      }
      let #(state, changed) = broadcast_model(state)
      let state = update_dynamic_subscriptions(state)
      ack_if_unchanged(state, conn_id, changed)
    }
  }
}

fn record_ack(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  clock: Int,
) -> RuntimeState(model, msg) {
  let previous = ack_for(state, conn_id)
  case clock < previous {
    True ->
      log.warning(
        "beacon.runtime",
        "Non-monotonic event clock from "
          <> conn_id
          <> ": "
          <> int.to_string(clock)
          <> " after "
          <> int.to_string(previous),
      )
    False -> Nil
  }
  RuntimeState(
    ..state,
    client_acks: dict.insert(
      state.client_acks,
      conn_id,
      int.max(previous, clock),
    ),
  )
}

fn ack_for(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
) -> Int {
  case dict.get(state.client_acks, conn_id) {
    Ok(clock) -> clock
    // No event from this connection has been processed yet.
    Error(Nil) -> 0
  }
}

/// When an event did not change the client-visible model no patch went
/// out, so acknowledge it explicitly with an empty patch at the current
/// revision.
fn ack_if_unchanged(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  changed: Bool,
) -> RuntimeState(model, msg) {
  case changed {
    True -> Nil
    False ->
      send_to_conn_id(
        state,
        conn_id,
        transport.SendPatch(
          ops_json: "[]",
          version: state.revision,
          ack_clock: ack_for(state, conn_id),
        ),
      )
  }
  state
}

type RouteMode {
  /// A join: handlers run only if the route differs from the current one.
  RouteOnJoin
  /// A client navigation: on_route_change always runs for a matched route
  /// (like LiveView's handle_params on every live patch).
  RouteOnNavigate
}

/// Apply a matched route: leave effects (when the route changes), then
/// on_route_change and its effects, then record the route. Model changes
/// are broadcast to the joined connections.
fn apply_route(
  state: RuntimeState(model, msg),
  matched_route: Option(route.Route),
  conn_id: Option(transport.ConnectionId),
  mode: RouteMode,
) -> RuntimeState(model, msg) {
  let route_changed = matched_route != state.current_route
  case mode, route_changed {
    RouteOnJoin, False -> {
      log.debug(
        "beacon.runtime",
        "Join route unchanged; route handlers not re-run",
      )
      state
    }
    _, _ -> {
      let state = run_route_leave_effects(state, matched_route, conn_id)
      let state = RuntimeState(..state, current_route: matched_route)
      case state.on_route_change, matched_route {
        Some(make_msg), Some(resolved_route) -> {
          let #(state, _changed) =
            run_update_for(state, make_msg(resolved_route), conn_id)
          state
        }
        _, _ -> state
      }
    }
  }
}

/// Run the update cycle: update model → broadcast the client-visible change
/// → run effects → reconcile subscriptions. Returns whether a patch or
/// model_sync was broadcast.
fn run_update_for(
  state: RuntimeState(model, msg),
  msg: msg,
  conn_id: Option(transport.ConnectionId),
) -> #(RuntimeState(model, msg), Bool) {
  let #(new_model, effects) = state.update(state.model, msg)
  let #(state, changed) =
    broadcast_model(RuntimeState(..state, model: new_model))
  let effect_processes =
    run_effects_with_context(effects, state.self, conn_id, state.connections)
  let state = track_effect_processes(state, effect_processes)
  #(update_dynamic_subscriptions(state), changed)
}

/// After an update, diff dynamic subscriptions and apply changes.
fn update_dynamic_subscriptions(
  state: RuntimeState(model, msg),
) -> RuntimeState(model, msg) {
  case state.dynamic_subscriptions, state.listener_subject {
    Some(compute_subs), Some(listener) -> {
      let new_subs = compute_subs(state.model)
      // Find topics to subscribe/unsubscribe
      let to_subscribe =
        list.filter(new_subs, fn(t) {
          !list.contains(state.current_subscriptions, t)
        })
      let to_unsubscribe =
        list.filter(state.current_subscriptions, fn(t) {
          !list.contains(new_subs, t)
        })
      // Apply changes
      list.each(to_subscribe, fn(t) { process.send(listener, SubscribeTo(t)) })
      list.each(to_unsubscribe, fn(t) {
        process.send(listener, UnsubscribeFrom(t))
      })
      case list.length(to_subscribe) + list.length(to_unsubscribe) > 0 {
        True ->
          log.info(
            "beacon.subscription",
            "Subscriptions updated: +"
              <> int.to_string(list.length(to_subscribe))
              <> " -"
              <> int.to_string(list.length(to_unsubscribe)),
          )
        False -> Nil
      }
      RuntimeState(..state, current_subscriptions: new_subs)
    }
    _, _ -> state
  }
}

/// Run update WITHOUT broadcasting — for atomic batch processing.
/// Only updates the model and executes effects. The broadcast happens once
/// after the batch.
fn run_update_only(
  state: RuntimeState(model, msg),
  msg: msg,
  conn_id: Option(transport.ConnectionId),
) -> RuntimeState(model, msg) {
  let #(new_model, effects) = state.update(state.model, msg)
  let effect_processes =
    run_effects_with_context(effects, state.self, conn_id, state.connections)
  track_effect_processes(
    RuntimeState(..state, model: new_model),
    effect_processes,
  )
}

/// Verify that the generated server contract is compiled and discoverable.
/// Public Beacon apps call this before binding a port so stale/missing codegen
/// fails at startup instead of at the first WebSocket event.
pub fn verify_generated_contract() -> Result(Nil, error.BeaconError) {
  log.info("beacon.runtime", "Verifying generated Beacon contract")
  case try_load_codec_encoder() {
    Error(_) ->
      Error(error.ConfigError(
        reason: "Generated contract missing beacon_codec.encode_model/1",
      ))
    Ok(_) ->
      case try_load_codec_event_decoder() {
        Error(_) ->
          Error(error.ConfigError(
            reason: "Generated contract missing beacon_codec.decode_event/4",
          ))
        Ok(_) ->
          case try_load_codec_renderer() {
            Error(_) ->
              Error(error.ConfigError(
                reason: "Generated contract missing beacon_codec.render_model/1",
              ))
            Ok(_) -> Ok(Nil)
          }
      }
  }
}

@external(erlang, "beacon_runtime_ffi", "try_load_codec_encoder")
fn try_load_codec_encoder() -> Result(fn(model) -> String, Nil)

fn discover_event_decoder() -> Option(
  fn(String, String, String, String) -> Result(msg, error.BeaconError),
) {
  case try_load_codec_event_decoder() {
    Ok(decoder) -> {
      log.info(
        "beacon.runtime",
        "Auto-discovered event decoder from beacon_codec",
      )
      Some(fn(name, handler_id, data, target_path) {
        case decoder(name, handler_id, data, target_path) {
          Ok(msg) -> Ok(msg)
          Error(reason) -> Error(error.CodecError(reason: reason, raw: data))
        }
      })
    }
    Error(_) -> {
      log.debug("beacon.runtime", "No beacon_codec event decoder available")
      None
    }
  }
}

@external(erlang, "beacon_runtime_ffi", "try_load_codec_event_decoder")
fn try_load_codec_event_decoder() -> Result(
  fn(String, String, String, String) -> Result(msg, String),
  Nil,
)

@external(erlang, "beacon_runtime_ffi", "try_load_codec_renderer")
fn try_load_codec_renderer() -> Result(fn(model) -> String, Nil)

/// Encode the client-visible snapshot of a model.
@internal
pub fn encode_snapshot(
  encode_full: fn(model) -> String,
  codecs: SubstateCodecs(model),
  model: model,
) -> CachedModelState {
  case codecs {
    NoSubstates -> FullModelCache(json: encode_full(model))
    Substates(encoders, flat) ->
      SubstateCache(
        substate_jsons: list.fold(encoders, dict.new(), fn(acc, entry) {
          let #(name, encode) = entry
          dict.insert(acc, name, encode(model))
        }),
        flat_fields_json: flat(model),
      )
  }
}

/// Byte size of a snapshot (the sum of its parts in substate mode).
fn snapshot_size(snapshot: CachedModelState) -> Int {
  case snapshot {
    NoCache -> 0
    FullModelCache(json) -> string.byte_size(json)
    SubstateCache(substate_jsons, flat_fields_json) ->
      dict.fold(
        substate_jsons,
        string.byte_size(flat_fields_json),
        fn(total, _name, json) { total + string.byte_size(json) },
      )
  }
}

@internal
pub type SnapshotDiff {
  /// The client-visible JSON is identical: nothing to send.
  Unchanged
  /// Send these ops as a patch.
  Changed(ops_json: String)
  /// The cache cannot be diffed against: send a full model_sync.
  Resync
}

/// Diff two snapshots. Equal JSON short-circuits without running the diff;
/// a substate that did not change is skipped entirely.
@internal
pub fn diff_snapshot(
  old: CachedModelState,
  new: CachedModelState,
) -> SnapshotDiff {
  case old, new {
    FullModelCache(old_json), FullModelCache(new_json) ->
      case old_json == new_json {
        True -> Unchanged
        False -> ops_to_diff([patch.diff(old_json, new_json)])
      }
    SubstateCache(old_subs, old_flat), SubstateCache(new_subs, new_flat) ->
      case same_substate_names(old_subs, new_subs) {
        False -> {
          // Both snapshots normally come from the same resolved codecs; a
          // different name set means the cache cannot be diffed against.
          log.warning(
            "beacon.runtime",
            "Substate snapshots have different substate names; full resync",
          )
          Resync
        }
        True -> {
          let substate_ops =
            dict.fold(new_subs, [], fn(acc, name, new_json) {
              // Invariant: same_substate_names checked the key sets match.
              let assert Ok(old_json) = dict.get(old_subs, name)
              case old_json == new_json {
                True -> acc
                False -> [diff_substate(name, old_json, new_json), ..acc]
              }
            })
          let flat_ops = case old_flat == new_flat {
            True -> []
            False -> [patch.diff(old_flat, new_flat)]
          }
          ops_to_diff(list.append(substate_ops, flat_ops))
        }
      }
    _, _ -> {
      log.debug(
        "beacon.runtime",
        "No diffable cached snapshot (none, or a different mode); full resync",
      )
      Resync
    }
  }
}

fn same_substate_names(
  old: dict.Dict(String, String),
  new: dict.Dict(String, String),
) -> Bool {
  dict.size(old) == dict.size(new)
  && list.all(dict.keys(new), fn(name) { dict.has_key(old, name) })
}

fn diff_substate(name: String, old_json: String, new_json: String) -> String {
  let key = json.to_string(json.string(name))
  patch.diff(
    "{" <> key <> ":" <> old_json <> "}",
    "{" <> key <> ":" <> new_json <> "}",
  )
}

fn ops_to_diff(ops: List(String)) -> SnapshotDiff {
  case list.filter(ops, fn(o) { !patch.is_empty(o) }) {
    [] -> Unchanged
    [single] -> Changed(single)
    many -> Changed(merge_ops_json_ffi(many))
  }
}

@external(erlang, "beacon_patch_ffi", "merge_ops_json")
fn merge_ops_json_ffi(ops_list: List(String)) -> String

/// Model JSON size warning threshold: 1MB.
const model_size_warn_bytes = 1_048_576

/// Model JSON size hard limit: 5MB. Nothing larger is sent.
const model_size_max_bytes = 5_242_880

type ModelSize {
  SizeOk
  TooLarge(size: Int)
}

/// Check model JSON size. Warn at 1MB, reject at 5MB.
fn check_model_size(size: Int, context: String) -> ModelSize {
  case size > model_size_max_bytes, size > model_size_warn_bytes {
    True, _ -> TooLarge(size)
    False, True -> {
      log.warning(
        "beacon.runtime",
        "Model JSON is large ("
          <> int.to_string(size)
          <> " bytes) in "
          <> context
          <> " — consider reducing model size",
      )
      SizeOk
    }
    False, False -> SizeOk
  }
}

/// The model exceeded the hard limit: tell the affected connections, and
/// drop the cache so the next successful broadcast is a full resync.
fn model_too_large(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  size: Int,
  context: String,
) -> RuntimeState(model, msg) {
  log.error(
    "beacon.runtime",
    "Model JSON is "
      <> int.to_string(size)
      <> " bytes in "
      <> context
      <> ", over the "
      <> int.to_string(model_size_max_bytes)
      <> " byte limit — not sent; clients resync once it shrinks",
  )
  list.each(targets, fn(conn_id) {
    send_to_conn_id(
      state,
      conn_id,
      transport.SendError(
        reason: "Model too large: "
        <> int.to_string(size)
        <> " bytes exceeds the "
        <> int.to_string(model_size_max_bytes)
        <> " byte limit",
      ),
    )
  })
  RuntimeState(..state, cached_model: NoCache)
}

fn model_encoder_missing(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  context: String,
) -> RuntimeState(model, msg) {
  log.error(
    "beacon.runtime",
    "No model encoder available in "
      <> context
      <> " — live state cannot be sent. Ensure beacon_codec.gleam is generated or serialize_model is configured.",
  )
  list.each(targets, fn(conn_id) {
    send_to_conn_id(
      state,
      conn_id,
      transport.SendError(reason: "Model encoder missing"),
    )
  })
  RuntimeState(..state, cached_model: NoCache)
}

/// Broadcast the current model to every joined connection: a patch when
/// the cache can be diffed, a full model_sync otherwise, nothing when the
/// client-visible JSON is unchanged. Returns whether anything was sent.
fn broadcast_model(
  state: RuntimeState(model, msg),
) -> #(RuntimeState(model, msg), Bool) {
  let targets = set.to_list(state.joined)
  case targets, state.model_encoder {
    [], _ -> {
      log.debug("beacon.runtime", "No joined connections; nothing to broadcast")
      #(RuntimeState(..state, cached_model: NoCache), False)
    }
    _, None -> #(model_encoder_missing(state, targets, "broadcast"), False)
    _, Some(encode_full) -> {
      let snapshot =
        encode_snapshot(encode_full, state.substate_codecs, state.model)
      case check_model_size(snapshot_size(snapshot), "broadcast") {
        TooLarge(size) -> #(
          model_too_large(state, targets, size, "broadcast"),
          False,
        )
        SizeOk ->
          case diff_snapshot(state.cached_model, snapshot) {
            Unchanged -> {
              log.debug("beacon.runtime", "Model unchanged, skipping broadcast")
              #(RuntimeState(..state, cached_model: snapshot), False)
            }
            Changed(ops_json) -> {
              let revision = state.revision + 1
              let state =
                RuntimeState(
                  ..state,
                  revision: revision,
                  cached_model: snapshot,
                )
              log.debug(
                "beacon.runtime",
                "Broadcasting patch revision " <> int.to_string(revision),
              )
              list.each(targets, fn(conn_id) {
                send_to_conn_id(
                  state,
                  conn_id,
                  transport.SendPatch(
                    ops_json: ops_json,
                    version: revision,
                    ack_clock: ack_for(state, conn_id),
                  ),
                )
              })
              #(state, True)
            }
            Resync -> {
              log.debug(
                "beacon.runtime",
                "No usable cache; broadcasting full model_sync",
              )
              let state = RuntimeState(..state, revision: state.revision + 1)
              let state = send_model_sync_to(state, targets, "broadcast_resync")
              #(state, True)
            }
          }
      }
    }
  }
}

/// Send the current model as a model_sync (current revision, each
/// connection's own ack) and cache its snapshot.
///
/// Callers must include every joined connection in `targets` when the
/// cache is `NoCache`, since the cache is about to describe all of them.
fn send_model_sync_to(
  state: RuntimeState(model, msg),
  targets: List(transport.ConnectionId),
  context: String,
) -> RuntimeState(model, msg) {
  case state.model_encoder {
    None -> model_encoder_missing(state, targets, context)
    Some(encode_full) -> {
      let snapshot =
        encode_snapshot(encode_full, state.substate_codecs, state.model)
      let model_json = case snapshot {
        FullModelCache(json) -> json
        _ -> encode_full(state.model)
      }
      case check_model_size(string.byte_size(model_json), context) {
        TooLarge(size) -> model_too_large(state, targets, size, context)
        SizeOk -> {
          list.each(targets, fn(conn_id) {
            send_to_conn_id(
              state,
              conn_id,
              transport.SendModelSync(
                model_json: model_json,
                version: state.revision,
                ack_clock: ack_for(state, conn_id),
              ),
            )
          })
          log.debug(
            "beacon.runtime",
            "Sent model_sync ("
              <> context
              <> ") revision "
              <> int.to_string(state.revision)
              <> " to "
              <> int.to_string(list.length(targets))
              <> " connection(s)",
          )
          RuntimeState(..state, cached_model: snapshot)
        }
      }
    }
  }
}

/// Full resync for one connection (or all joined ones when the cache is
/// unusable, since they may be stale too).
fn resync(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  context: String,
) -> RuntimeState(model, msg) {
  let targets = case state.cached_model {
    NoCache -> set.to_list(set.insert(state.joined, conn_id))
    _ -> [conn_id]
  }
  send_model_sync_to(state, targets, context)
}

/// Discover substate names from beacon_codec.
@external(erlang, "beacon_runtime_ffi", "try_load_substate_names")
fn try_load_substate_names() -> Result(List(String), Nil)

/// Discover a per-substate encoder from beacon_codec.
@external(erlang, "beacon_runtime_ffi", "try_load_substate_encoder")
fn try_load_substate_encoder(name: String) -> Result(fn(model) -> String, Nil)

/// Discover the flat fields encoder from beacon_codec.
@external(erlang, "beacon_runtime_ffi", "try_load_flat_encoder")
fn try_load_flat_encoder() -> Result(fn(model) -> String, Nil)

/// Execute effects by providing a dispatch function that sends messages
/// back to the runtime actor.
fn run_effects(
  effects: Effect(msg),
  self: Subject(RuntimeMessage(msg)),
) -> List(Pid) {
  run_effects_with_context(effects, self, None, dict.new())
}

/// Execute effects with connection context for targeted sends (redirects).
fn run_effects_with_context(
  effects: Effect(msg),
  self: Subject(RuntimeMessage(msg)),
  conn_id: Option(transport.ConnectionId),
  connections: Dict(transport.ConnectionId, Subject(transport.InternalMessage)),
) -> List(Pid) {
  case effect.is_none(effects) {
    True -> []
    False -> {
      log.debug("beacon.runtime", "Executing effects")
      // Store connection context so redirect can target the right client
      case conn_id {
        Some(cid) -> {
          case dict.get(connections, cid) {
            Ok(subject) -> store_redirect_target(subject)
            Error(Nil) -> {
              log.debug(
                "beacon.runtime",
                "Connection " <> cid <> " not found for redirect target storage",
              )
              Nil
            }
          }
        }
        None -> {
          log.debug(
            "beacon.runtime",
            "No connection context for effects (broadcast or init)",
          )
          Nil
        }
      }
      let dispatch = fn(msg) {
        process.send(self, EffectDispatched(message: msg))
      }
      let dispatch_keyed = fn(key, generation, msg) {
        process.send(
          self,
          EffectDispatchedKeyed(key: key, generation: generation, message: msg),
        )
      }
      effect.perform_tracked(effects, dispatch, dispatch_keyed)
    }
  }
}

fn track_effect_processes(
  state: RuntimeState(model, msg),
  new_processes: List(Pid),
) -> RuntimeState(model, msg) {
  case new_processes {
    [] -> state
    _ -> {
      let live_existing =
        list.filter(state.effect_processes, fn(pid) { process.is_alive(pid) })
      RuntimeState(
        ..state,
        effect_processes: list.append(new_processes, live_existing),
      )
    }
  }
}

fn stop_effect_processes(processes: List(Pid)) -> Nil {
  let live_processes = list.filter(processes, fn(pid) { process.is_alive(pid) })
  case list.length(live_processes) {
    0 -> Nil
    count ->
      log.info(
        "beacon.runtime",
        "Stopping " <> int.to_string(count) <> " effect processes",
      )
  }
  list.each(live_processes, fn(pid) { process.kill(pid) })
}

fn stop_listener(listener: Option(Subject(ListenerCommand))) -> Nil {
  case listener {
    Some(subject) -> process.send(subject, ShutdownListener)
    None -> Nil
  }
}

const max_outbound_mailbox_messages = 1000

/// Send to a registered connection by id (logged when it is unknown).
fn send_to_conn_id(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
  message: transport.InternalMessage,
) -> Nil {
  case dict.get(state.connections, conn_id) {
    Ok(subject) -> send_to_connection(conn_id, subject, message)
    Error(Nil) ->
      log.warning(
        "beacon.runtime",
        "Cannot send to unregistered connection " <> conn_id,
      )
  }
}

fn send_to_connection(
  conn_id: transport.ConnectionId,
  subject: Subject(transport.InternalMessage),
  message: transport.InternalMessage,
) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) -> {
      let queue_len = process_message_queue_len(pid)
      case queue_len > max_outbound_mailbox_messages {
        True -> {
          log.warning(
            "beacon.runtime",
            "Connection "
              <> conn_id
              <> " outbound mailbox exceeded "
              <> int.to_string(max_outbound_mailbox_messages)
              <> " messages ("
              <> int.to_string(queue_len)
              <> "); closing slow client",
          )
          process.send(
            subject,
            transport.CloseForBackpressure(
              reason: "Connection is too far behind; reconnect to resync",
            ),
          )
        }
        False -> process.send(subject, message)
      }
    }
    Error(Nil) -> {
      log.warning(
        "beacon.runtime",
        "Cannot send to connection " <> conn_id <> ": subject has no owner",
      )
      Nil
    }
  }
}

@external(erlang, "beacon_runtime_ffi", "message_queue_len")
fn process_message_queue_len(pid: Pid) -> Int

/// Create a TransportConfig that wires transport events to a runtime.
/// This is the glue between the transport and runtime layers.
pub fn connect_transport(
  runtime: Subject(RuntimeMessage(msg)),
  port: Int,
) -> transport.TransportConfig {
  log.info(
    "beacon.runtime",
    "Connecting transport on port " <> int.to_string(port),
  )
  connect_transport_with_ssr(runtime, port, None)
}

/// Create a TransportConfig with SSR-rendered HTML.
pub fn connect_transport_with_ssr(
  runtime: Subject(RuntimeMessage(msg)),
  port: Int,
  page_html: Option(ssr.RenderedPage),
) -> transport.TransportConfig {
  log.info(
    "beacon.runtime",
    "Connecting transport on port " <> int.to_string(port),
  )
  transport.TransportConfig(
    port: port,
    page_html: page_html,
    middlewares: [],
    static_config: None,
    runtime_factory: None,
    on_connect: fn(conn_id, subject) {
      process.send(runtime, ClientConnected(conn_id: conn_id, subject: subject))
    },
    on_event: fn(conn_id, client_msg) {
      forward_client_message_with_request(runtime, conn_id, None, client_msg)
    },
    on_disconnect: fn(conn_id) {
      process.send(runtime, ClientDisconnected(conn_id: conn_id))
    },
    ws_auth: None,
    ssr_factory: None,
    security_limits: transport.default_security_limits(),
    api_handler: None,
  )
}

/// Start a runtime for a specific connection and return type-erased handler closures.
/// This is the core helper used by app startup and test harnesses.
/// Each call spawns a new runtime actor, registers the connection, and returns:
/// - on_event: forwards ClientMessages to the runtime
/// - shutdown: kills the runtime process
///
/// Types are erased at the function boundary — the returned closures work
/// with untyped ConnectionId + ClientMessage regardless of Model/Msg types.
pub fn start_and_connect(
  config: RuntimeConfig(model, msg),
  conn_id: transport.ConnectionId,
  transport_subject: process.Subject(transport.InternalMessage),
) -> Result(
  #(fn(transport.ConnectionId, transport.ClientMessage) -> Nil, fn() -> Nil),
  error.BeaconError,
) {
  log.info("beacon.runtime", "Starting runtime connection for " <> conn_id)
  start_and_connect_with_request(config, conn_id, transport_subject, None)
}

/// Start a per-connection runtime with access to the HTTP request.
/// When `req` is Some and `config.init_from_request` is set, uses the
/// request-aware init instead of the static init function.
pub fn start_and_connect_with_request(
  config: RuntimeConfig(model, msg),
  conn_id: transport.ConnectionId,
  transport_subject: process.Subject(transport.InternalMessage),
  req: Option(request.Request(server.Connection)),
) -> Result(
  #(fn(transport.ConnectionId, transport.ClientMessage) -> Nil, fn() -> Nil),
  error.BeaconError,
) {
  log.info("beacon.runtime", "Spawning runtime for " <> conn_id)
  // Use init_from_request if both the request and the callback are available
  let effective_config = case req, config.init_from_request {
    Some(r), Some(init_fn) -> {
      log.debug("beacon.runtime", "Using request-aware init for " <> conn_id)
      RuntimeConfig(..config, init: fn() { init_fn(r) })
    }
    _, _ -> config
  }
  case start(effective_config) {
    Ok(runtime_subject) -> {
      // Register this connection with the new runtime
      process.send(
        runtime_subject,
        ClientConnected(conn_id: conn_id, subject: transport_subject),
      )
      // Return per-connection event and shutdown handlers
      let on_event = fn(_cid: transport.ConnectionId, client_msg) {
        forward_client_message_with_request(
          runtime_subject,
          conn_id,
          req,
          client_msg,
        )
      }
      let shutdown = fn() {
        log.info("beacon.runtime", "Shutting down runtime for " <> conn_id)
        process.send(runtime_subject, Shutdown)
      }
      Ok(#(on_event, shutdown))
    }
    Error(err) -> {
      log.error(
        "beacon.runtime",
        "Failed to spawn runtime for "
          <> conn_id
          <> ": "
          <> error.to_string(err),
      )
      Error(err)
    }
  }
}

/// Forward a client message to a runtime actor.
/// Translates transport.ClientMessage variants into RuntimeMessage variants.
/// With the upgrade request available, the join token is read from the
/// HttpOnly join-token cookie and bound to the request's browser session.
fn forward_client_message_with_request(
  runtime_subject: Subject(RuntimeMessage(msg)),
  conn_id: transport.ConnectionId,
  req: Option(request.Request(server.Connection)),
  client_msg: transport.ClientMessage,
) -> Nil {
  case client_msg {
    transport.ClientEvent(name, handler_id, data, target_path, clock, ops) ->
      process.send(
        runtime_subject,
        ClientEventReceived(
          conn_id: conn_id,
          event_name: name,
          handler_id: handler_id,
          event_data: data,
          target_path: target_path,
          clock: clock,
          ops: ops,
        ),
      )
    transport.ClientJoin(token, path) ->
      case req {
        Some(http_req) ->
          process.send(
            runtime_subject,
            ClientJoinedWithSession(
              conn_id: conn_id,
              token: join_token_cookie(http_req),
              path: path,
              session_fingerprint: ssr.session_fingerprint(http_req),
            ),
          )
        None ->
          process.send(
            runtime_subject,
            ClientJoined(conn_id: conn_id, token: token, path: path),
          )
      }
    transport.ClientNavigate(path) ->
      process.send(
        runtime_subject,
        ClientNavigated(conn_id: conn_id, path: path),
      )
    transport.ClientRequestSync ->
      process.send(runtime_subject, ClientSyncRequested(conn_id: conn_id))
    transport.ClientEventBatch(events) -> {
      let #(event_tuples, nested) =
        list.fold(list.reverse(events), #([], 0), fn(acc, evt) {
          let #(tuples, nested) = acc
          case evt {
            transport.ClientEvent(
              name,
              handler_id,
              data,
              target_path,
              clock,
              ops,
            ) -> #(
              [#(name, handler_id, data, target_path, clock, ops), ..tuples],
              nested,
            )
            _ -> #(tuples, nested + 1)
          }
        })
      case nested {
        0 -> Nil
        n ->
          log.warning(
            "beacon.runtime",
            "Dropped "
              <> int.to_string(n)
              <> " non-event message(s) inside an event batch from "
              <> conn_id,
          )
      }
      process.send(
        runtime_subject,
        ClientEventBatchReceived(conn_id: conn_id, events: event_tuples),
      )
    }
    transport.ClientHeartbeat -> Nil
  }
}

fn join_token_cookie(req: request.Request(server.Connection)) -> String {
  case cookie.get(req, ssr.session_cookie_name) {
    Ok(token) -> token
    Error(Nil) -> ""
  }
}

/// Create a TransportConfig that spawns a NEW runtime per WebSocket connection.
/// Each connection gets its own Model, its own MVU loop, its own BEAM process.
/// This is the LiveView-style architecture for multi-user apps.
pub fn connect_transport_per_connection(
  config: RuntimeConfig(model, msg),
  port: Int,
  page_html: Option(ssr.RenderedPage),
) -> transport.TransportConfig {
  log.info(
    "beacon.runtime",
    "Connecting transport (per-connection mode) on port " <> int.to_string(port),
  )
  transport.TransportConfig(
    port: port,
    page_html: page_html,
    middlewares: [],
    static_config: None,
    runtime_factory: Some(
      fn(
        conn_id: transport.ConnectionId,
        transport_subject: process.Subject(transport.InternalMessage),
        req: request.Request(server.Connection),
      ) {
        case
          start_and_connect_with_request(
            config,
            conn_id,
            transport_subject,
            Some(req),
          )
        {
          Ok(#(on_event, shutdown)) -> {
            let on_disconnect = fn(_cid: transport.ConnectionId) { shutdown() }
            Ok(#(on_event, on_disconnect))
          }
          Error(err) -> {
            log.error(
              "beacon.runtime",
              "Failed to start per-connection runtime: " <> error.to_string(err),
            )
            Error(error.to_string(err))
          }
        }
      },
    ),
    // These are unused when runtime_factory is set, but needed for the type
    on_connect: fn(_, _) { Nil },
    on_event: fn(_, _) { Nil },
    on_disconnect: fn(_) { Nil },
    ws_auth: None,
    ssr_factory: None,
    security_limits: transport.default_security_limits(),
    api_handler: None,
  )
}

/// Commands sent to the PubSub listener process.
pub type ListenerCommand {
  /// Subscribe to a new PubSub topic.
  SubscribeTo(topic: String)
  /// Unsubscribe from a PubSub topic.
  UnsubscribeFrom(topic: String)
  /// Shut down the listener process.
  ShutdownListener
}

/// Result from the listener's receive FFI.
type ListenerReceiveResult {
  /// A command was received from the runtime.
  CommandReceived(command: ListenerCommand)
  /// A PubSub notification was received on a topic.
  NotificationReceived(topic: String, payload: Dynamic)
  /// The owning runtime exited (DOWN from the listener's monitor).
  OwnerExited(reason: String)
  /// Timeout — no message within the window.
  ReceiveTimeout
}

/// Immutable context of a PubSub listener process.
type Listener(msg) {
  Listener(
    runtime_subject: Subject(RuntimeMessage(msg)),
    command_subject: Subject(ListenerCommand),
    /// Monitor on the owning runtime — the listener exits when it fires.
    owner_monitor: process.Monitor,
    on_notify: Option(fn(String) -> msg),
    on_notification: Option(fn(Notification) -> msg),
  )
}

/// Start the PubSub listener — spawns a process that handles
/// dynamic subscription commands and forwards notifications.
/// Returns a Subject for sending commands to the listener.
///
/// Lifecycle: the listener is bound to the RUNTIME, not to the caller. It
/// links to the runtime (so a crashing listener crashes the runtime loudly
/// instead of silently dropping notifications, and an abnormal runtime exit
/// kills the listener) and monitors it (so a normal runtime exit, which a
/// link does not propagate, also stops the listener and unsubscribes).
fn start_pubsub_listener(
  runtime_subject: Subject(RuntimeMessage(msg)),
  runtime_pid: Pid,
  on_notify: Option(fn(String) -> msg),
  on_notification: Option(fn(Notification) -> msg),
  topics: List(String),
) -> Subject(ListenerCommand) {
  // Use a subject on the CALLER to receive the listener's command subject
  let reply_subject = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      // Monitor before linking: if the runtime is already gone the monitor
      // delivers DOWN (noproc) and the loop exits on its first receive.
      let owner_monitor = process.monitor(runtime_pid)
      let _ = process.link(runtime_pid)
      // Create the command subject HERE — inside the spawned process —
      // so it's owned by this process and receives messages correctly.
      let command_subject = process.new_subject()

      log.info("beacon.subscription", "Listener process spawned")
      // Subscribe to the initial topics BEFORE replying, so that once
      // `start` returns no broadcast to an initial topic can be missed.
      let topics = list.unique(topics)
      list.each(topics, fn(t) {
        log.info("beacon.subscription", "Subscribing to: " <> t)
        pubsub.subscribe(t)
      })
      process.send(reply_subject, command_subject)
      log.info(
        "beacon.subscription",
        "Listener started with "
          <> int.to_string(list.length(topics))
          <> " initial topics",
      )
      listener_loop(
        Listener(
          runtime_subject: runtime_subject,
          command_subject: command_subject,
          owner_monitor: owner_monitor,
          on_notify: on_notify,
          on_notification: on_notification,
        ),
        topics,
      )
    })
  // INVARIANT: The listener process was just spawned and MUST send its
  // command_subject back immediately. If this times out (5s), the listener
  // failed to start — a fatal configuration error. Crash is intentional:
  // the runtime cannot function without its PubSub listener.
  let assert Ok(command_subject) = process.receive(reply_subject, 5000)
  command_subject
}

/// Listener receive loop — handles commands and PubSub notifications.
fn listener_loop(listener: Listener(msg), subscriptions: List(String)) -> Nil {
  case
    receive_with_commands(
      listener.command_subject,
      listener.owner_monitor,
      60_000,
    )
  {
    CommandReceived(SubscribeTo(topic)) ->
      // pg allows a process to join a group more than once (and then
      // delivers every broadcast once per membership), so joining is
      // guarded by the listener's own subscription set.
      case list.contains(subscriptions, topic) {
        True -> {
          log.debug("beacon.subscription", "Already subscribed to: " <> topic)
          listener_loop(listener, subscriptions)
        }
        False -> {
          pubsub.subscribe(topic)
          log.debug("beacon.subscription", "Subscribed to: " <> topic)
          listener_loop(listener, [topic, ..subscriptions])
        }
      }
    CommandReceived(UnsubscribeFrom(topic)) ->
      case list.contains(subscriptions, topic) {
        True -> {
          pubsub.unsubscribe(topic)
          log.debug("beacon.subscription", "Unsubscribed from: " <> topic)
          listener_loop(
            listener,
            list.filter(subscriptions, fn(existing) { existing != topic }),
          )
        }
        False -> {
          log.debug(
            "beacon.subscription",
            "Ignoring unsubscribe from non-subscribed topic: " <> topic,
          )
          listener_loop(listener, subscriptions)
        }
      }
    CommandReceived(ShutdownListener) -> {
      log.info("beacon.subscription", "Listener shutting down")
      unsubscribe_all(subscriptions)
    }
    OwnerExited(reason) -> {
      log.info(
        "beacon.subscription",
        "Owning runtime exited (" <> reason <> "); listener stopping",
      )
      unsubscribe_all(subscriptions)
    }
    NotificationReceived(topic, payload) -> {
      case listener.on_notify {
        Some(handler) ->
          process.send(
            listener.runtime_subject,
            EffectDispatched(message: handler(topic)),
          )
        None -> Nil
      }
      case listener.on_notification {
        Some(handler) ->
          process.send(
            listener.runtime_subject,
            EffectDispatched(
              message: handler(Notification(topic: topic, payload: payload)),
            ),
          )
        None -> Nil
      }
      listener_loop(listener, subscriptions)
    }
    ReceiveTimeout -> listener_loop(listener, subscriptions)
  }
}

fn unsubscribe_all(subscriptions: List(String)) -> Nil {
  list.each(subscriptions, fn(topic) {
    log.debug("beacon.subscription", "Unsubscribing on shutdown: " <> topic)
    pubsub.unsubscribe(topic)
  })
}

@external(erlang, "beacon_subscription_ffi", "receive_with_commands")
fn receive_with_commands(
  subject: Subject(ListenerCommand),
  owner_monitor: process.Monitor,
  timeout: Int,
) -> ListenerReceiveResult

@external(erlang, "beacon_runtime_ffi", "store_redirect_target")
fn store_redirect_target(
  subject: process.Subject(transport.InternalMessage),
) -> Nil

@external(erlang, "beacon_runtime_ffi", "get_redirect_target")
pub fn get_redirect_target() -> option.Option(
  process.Subject(transport.InternalMessage),
)

fn route_for_path(
  patterns: List(route.RoutePattern),
  path: String,
) -> Option(route.Route) {
  case path {
    "" -> None
    _ -> route.match_path(patterns, path)
  }
}

/// Run on_route_leave when moving between two different matched routes.
/// The effect processes it starts are tracked like any other effect's.
fn run_route_leave_effects(
  state: RuntimeState(model, msg),
  next_route: Option(route.Route),
  conn_id: Option(transport.ConnectionId),
) -> RuntimeState(model, msg) {
  case state.on_route_leave, state.current_route, next_route {
    Some(on_leave), Some(previous_route), Some(resolved_route)
      if previous_route != resolved_route
    -> {
      log.debug("beacon.runtime", "Running route leave effects")
      let leave_effect = on_leave(previous_route, resolved_route)
      let processes =
        run_effects_with_context(
          leave_effect,
          state.self,
          conn_id,
          state.connections,
        )
      track_effect_processes(state, processes)
    }
    _, _, _ -> state
  }
}

/// Create a signed join token carrying the serialized model, not bound to
/// any browser session. Prefer `ssr.join_token_for` for request-bound pages.
pub fn create_state_token(
  model: model,
  serialize: fn(model) -> String,
  secret_key: String,
) -> String {
  ssr.sign_join_token(
    secret_key,
    "",
    Some(serialize(model)),
    system_time_seconds(),
  )
}

@external(erlang, "beacon_ssr_ffi", "system_time_seconds")
fn system_time_seconds() -> Int
