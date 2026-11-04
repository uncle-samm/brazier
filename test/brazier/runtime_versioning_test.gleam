//// Regression tests for the runtime's join, versioning and broadcast rules.
////
//// Synchronisation: every assertion waits on an explicit message. A
//// `ClientSyncRequested` acts as a barrier — the runtime answers it only
//// after handling every earlier message — so "nothing was sent" is checked
//// by seeing the barrier's reply arrive first.

import brazier/await
import brazier/effect
import brazier/error
import brazier/patch
import brazier/pubsub
import brazier/runtime
import brazier/test_ctx
import brazier/transport
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri.{type Uri}

pub type Model {
  Model(count: Int, blob: String, path: String)
}

pub type Msg {
  Inc
  Noop
  SetBlob(String)
  RouteTo(String)
}

const secret = "runtime-versioning-test-secret-0123456789"

/// Over the 5MB model limit.
const big_blob_bytes = 5_300_000

fn model_json(m: Model) -> String {
  "{\"count\":"
  <> int.to_string(m.count)
  <> ",\"blob\":\""
  <> m.blob
  <> "\",\"path\":\""
  <> m.path
  <> "\"}"
}

fn decode(
  _name: String,
  handler_id: String,
  _data: String,
  _path: String,
) -> Result(Msg, error.BrazierError) {
  case handler_id {
    "inc" -> Ok(Inc)
    "noop" -> Ok(Noop)
    "big" -> Ok(SetBlob(string.repeat("x", big_blob_bytes)))
    "small" -> Ok(SetBlob(""))
    _ -> Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
  }
}

fn update(m: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    Inc -> #(Model(..m, count: m.count + 1), effect.none())
    Noop -> #(m, effect.none())
    SetBlob(blob) -> #(Model(..m, blob: blob), effect.none())
    RouteTo(path) -> #(Model(..m, path: path), effect.none())
  }
}

fn config() -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    init: fn(_ctx) { Ok(#(Model(count: 0, blob: "", path: ""), effect.none())) },
    update: update,
    decode_event: decode,
    encode_model: model_json,
    route: None,
    restore_model: None,
    dynamic_subscriptions: None,
    on_notify: None,
    on_notification: None,
    secret_key: secret,
    presence: None,
    title: None,
  )
}

/// Every path is a route; each time `update` applies a route message it
/// reports the path to `proof`. `runtime.start` applies one for the start
/// context's "/". (The router itself is a pure parse the runtime may call
/// just to compare routes, so the proof sits in `update`.)
fn route_config(proof: Subject(String)) -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(
    ..config(),
    update: fn(m: Model, msg: Msg) {
      case msg {
        RouteTo(path) -> process.send(proof, path)
        Inc | Noop | SetBlob(_) -> Nil
      }
      update(m, msg)
    },
    route: Some(fn(page: Uri) { Ok(RouteTo(page.path)) }),
  )
}

// --- helpers ---

fn connect(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
) -> Subject(transport.InternalMessage) {
  let subject = process.new_subject()
  process.send(rt, runtime.ClientConnected(conn_id: conn_id, subject: subject))
  subject
}

fn join(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  path: String,
) -> Subject(transport.InternalMessage) {
  let subject = connect(rt, conn_id)
  process.send(
    rt,
    runtime.ClientJoined(conn_id: conn_id, token: "", path: path),
  )
  subject
}

fn next(
  subject: Subject(transport.InternalMessage),
) -> transport.InternalMessage {
  let assert Ok(message) = process.receive(subject, 2000)
  message
}

fn event(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  handler_id: String,
  clock: Int,
) -> Nil {
  process.send(
    rt,
    runtime.ClientEventReceived(
      conn_id: conn_id,
      event_name: "click",
      handler_id: handler_id,
      event_data: "{}",
      target_path: "0",
      clock: clock,
      ops: "",
    ),
  )
}

/// Answered only after every earlier message to the runtime was handled.
fn barrier(
  rt: Subject(runtime.RuntimeMessage(Msg)),
  conn_id: String,
  subject: Subject(transport.InternalMessage),
) -> transport.InternalMessage {
  process.send(rt, runtime.ClientSyncRequested(conn_id: conn_id))
  next(subject)
}

fn assert_nothing_pending(subject: Subject(transport.InternalMessage)) -> Nil {
  let assert Error(Nil) = process.receive(subject, 0)
  Nil
}

// --- messages before join (unhappy paths) ---

pub fn event_before_join_is_rejected_and_not_applied_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = connect(rt, "c")
  event(rt, "c", "inc", 1)
  let assert transport.SendError(reason: "event received before join") = next(s)
  process.send(rt, runtime.ClientJoined(conn_id: "c", token: "", path: ""))
  let assert transport.SendModelSync(model_json: json, version: 0, ack_clock: 0) =
    next(s)
  let assert True = string.contains(json, "\"count\":0")
}

pub fn batch_before_join_is_rejected_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = connect(rt, "c")
  process.send(
    rt,
    runtime.ClientEventBatchReceived(conn_id: "c", events: [
      #("click", "inc", "{}", "0", 1, ""),
    ]),
  )
  let assert transport.SendError(reason: "event batch received before join") =
    next(s)
}

pub fn navigation_before_join_is_rejected_test() {
  let proof = process.new_subject()
  let assert Ok(rt) = runtime.start(route_config(proof), test_ctx.root())
  let assert Ok("/") = process.receive(proof, 1000)
  let s = connect(rt, "c")
  process.send(rt, runtime.ClientNavigated(conn_id: "c", path: "/a"))
  let assert transport.SendError(reason: "navigation received before join") =
    next(s)
  let assert Error(Nil) = process.receive(proof, 0)
}

pub fn sync_before_join_is_rejected_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = connect(rt, "c")
  let assert transport.SendError(reason: "sync request received before join") =
    barrier(rt, "c", s)
}

pub fn join_from_unregistered_connection_does_not_join_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  process.send(rt, runtime.ClientJoined(conn_id: "ghost", token: "", path: ""))
  let s = connect(rt, "ghost")
  event(rt, "ghost", "inc", 1)
  let assert transport.SendError(reason: "event received before join") = next(s)
}

pub fn reregistered_connection_must_join_again_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s1 = join(rt, "c", "")
  let assert transport.SendModelSync(..) = next(s1)
  let s2 = connect(rt, "c")
  event(rt, "c", "inc", 1)
  let assert transport.SendError(reason: "event received before join") =
    next(s2)
  assert_nothing_pending(s1)
}

// --- rejoin ---

pub fn rejoin_is_full_resync_and_never_resets_state_test() {
  let cfg =
    runtime.RuntimeConfig(
      ..config(),
      restore_model: Some(fn(_json, _fresh) {
        Ok(Model(count: 0, blob: "", path: ""))
      }),
    )
  let assert Ok(rt) = runtime.start(cfg, test_ctx.root())
  // With state recovery every first join carries a token with the model;
  // this one recovers count 0.
  let s = connect(rt, "c")
  let first_token =
    runtime.create_state_token(
      Model(count: 0, blob: "", path: ""),
      model_json,
      secret,
    )
  process.send(
    rt,
    runtime.ClientJoined(conn_id: "c", token: first_token, path: ""),
  )
  let assert transport.SendModelSync(version: 0, ack_clock: 0, ..) = next(s)
  event(rt, "c", "inc", 1)
  let assert transport.SendPatch(version: 1, ack_clock: 1, ..) = next(s)
  event(rt, "c", "inc", 2)
  let assert transport.SendPatch(version: 2, ack_clock: 2, ..) = next(s)

  // A rejoin with a valid token must not replace the live model.
  let token =
    runtime.create_state_token(
      Model(count: 99, blob: "", path: ""),
      model_json,
      secret,
    )
  process.send(rt, runtime.ClientJoined(conn_id: "c", token: token, path: ""))
  let assert transport.SendModelSync(model_json: json, version: 2, ack_clock: 2) =
    next(s)
  let assert True = string.contains(json, "\"count\":2")

  // The connection stays joined: events keep working at the same revision line.
  event(rt, "c", "inc", 3)
  let assert transport.SendPatch(version: 3, ack_clock: 3, ..) = next(s)
}

// --- versioning ---

pub fn unchanged_event_sends_ack_only_patch_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = join(rt, "c", "")
  let assert transport.SendModelSync(version: 0, ..) = next(s)
  event(rt, "c", "noop", 1)
  let assert transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 1) =
    next(s)
  event(rt, "c", "inc", 2)
  let assert transport.SendPatch(ops_json: ops, version: 1, ack_clock: 2) =
    next(s)
  let assert True = string.contains(ops, "/count")
  event(rt, "c", "noop", 3)
  let assert transport.SendPatch(ops_json: "[]", version: 1, ack_clock: 3) =
    next(s)
}

pub fn decode_failure_reports_error_then_acks_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = join(rt, "c", "")
  let assert transport.SendModelSync(..) = next(s)
  event(rt, "c", "bogus", 4)
  let assert transport.SendError(reason: reason) = next(s)
  let assert True = string.contains(reason, "Unknown handler")
  let assert transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 4) =
    next(s)
}

pub fn non_monotonic_clock_never_lowers_ack_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = join(rt, "c", "")
  let assert transport.SendModelSync(..) = next(s)
  event(rt, "c", "inc", 5)
  let assert transport.SendPatch(version: 1, ack_clock: 5, ..) = next(s)
  event(rt, "c", "inc", 3)
  let assert transport.SendPatch(version: 2, ack_clock: 5, ..) = next(s)
}

pub fn revision_is_shared_and_acks_are_per_connection_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let a = join(rt, "a", "")
  let assert transport.SendModelSync(version: 0, ..) = next(a)
  let b = join(rt, "b", "")
  let assert transport.SendModelSync(version: 0, ..) = next(b)

  event(rt, "a", "inc", 5)
  let assert transport.SendPatch(ops_json: ops_a, version: 1, ack_clock: 5) =
    next(a)
  let assert transport.SendPatch(ops_json: ops_b, version: 1, ack_clock: 0) =
    next(b)
  let assert True = ops_a == ops_b

  event(rt, "b", "inc", 1)
  let assert transport.SendPatch(version: 2, ack_clock: 5, ..) = next(a)
  let assert transport.SendPatch(version: 2, ack_clock: 1, ..) = next(b)

  // An unchanged event is acknowledged to its sender only.
  event(rt, "b", "noop", 2)
  let assert transport.SendPatch(ops_json: "[]", version: 2, ack_clock: 2) =
    next(b)
  let assert transport.SendModelSync(version: 2, ack_clock: 5, ..) =
    barrier(rt, "a", a)
}

pub fn navigation_bumps_revision_only_when_model_changes_test() {
  let proof = process.new_subject()
  let assert Ok(rt) = runtime.start(route_config(proof), test_ctx.root())
  let a = join(rt, "a", "/")
  let assert Ok("/") = process.receive(proof, 1000)
  let assert transport.SendModelSync(model_json: json, version: 0, ..) = next(a)
  let assert True = string.contains(json, "\"path\":\"/\"")
  let b = join(rt, "b", "/")
  let assert transport.SendModelSync(version: 0, ..) = next(b)

  // A navigation that changes the model: one revision, sent to every joined
  // connection including the navigator.
  process.send(rt, runtime.ClientNavigated(conn_id: "a", path: "/a"))
  let assert Ok("/a") = process.receive(proof, 1000)
  let assert transport.SendPatch(ops_json: ops, version: 1, ack_clock: 0) =
    next(a)
  let assert True = string.contains(ops, "/path")
  let assert transport.SendPatch(version: 1, ..) = next(b)

  // Navigating to the same route re-runs on_route_change (like LiveView's
  // handle_params) but the JSON is unchanged: no patch, no new revision.
  process.send(rt, runtime.ClientNavigated(conn_id: "a", path: "/a"))
  let assert Ok("/a") = process.receive(proof, 1000)
  let assert transport.SendModelSync(version: 1, ..) = barrier(rt, "a", a)
  let assert transport.SendModelSync(version: 1, ..) = barrier(rt, "b", b)
}

pub fn join_does_not_rerun_route_handlers_for_same_route_test() {
  let proof = process.new_subject()
  let assert Ok(rt) = runtime.start(route_config(proof), test_ctx.root())
  let a = join(rt, "a", "/")
  let assert transport.SendModelSync(..) = next(a)
  let assert Ok("/") = process.receive(proof, 0)

  // Rejoin and a second connection on the same route: handlers not re-run.
  process.send(rt, runtime.ClientJoined(conn_id: "a", token: "", path: "/"))
  let assert transport.SendModelSync(version: 0, ..) = next(a)
  let b = join(rt, "b", "/")
  let assert transport.SendModelSync(version: 0, ..) = next(b)
  let assert Error(Nil) = process.receive(proof, 0)

  // A join on a different route runs them; already-joined connections get
  // the resulting change as a patch, the joiner gets it in its model_sync.
  let c = join(rt, "c", "/a")
  let assert transport.SendModelSync(model_json: json, version: 1, ..) = next(c)
  let assert True = string.contains(json, "\"path\":\"/a\"")
  let assert Ok("/a") = process.receive(proof, 0)
  let assert transport.SendPatch(version: 1, ..) = next(a)
  let assert transport.SendPatch(version: 1, ..) = next(b)
}

// --- model size limit ---

pub fn model_over_limit_fails_loudly_and_resyncs_after_shrinking_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = join(rt, "c", "")
  let assert transport.SendModelSync(version: 0, ..) = next(s)

  event(rt, "c", "big", 1)
  let assert transport.SendError(reason: reason) = next(s)
  let assert True = string.starts_with(reason, "Model too large: ")
  let assert False = string.contains(reason, "encoder")
  // The event is still acknowledged; the revision did not move.
  let assert transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 1) =
    next(s)

  // A join while the model is too large gets the same distinct error.
  let late = join(rt, "late", "")
  let assert transport.SendError(reason: late_reason) = next(late)
  let assert True = string.starts_with(late_reason, "Model too large: ")
  // There is no cached snapshot, so the resync the join triggers also
  // targets the already-joined connection, which gets the same error.
  let assert transport.SendError(reason: again) = next(s)
  let assert True = again == late_reason

  // Once the model shrinks, the stale cache is not diffed against: every
  // joined connection gets a full model_sync at a new revision.
  event(rt, "c", "small", 2)
  let assert transport.SendModelSync(model_json: json, version: 1, ack_clock: 2) =
    next(s)
  let assert True = string.contains(json, "\"blob\":\"\"")
  let assert transport.SendModelSync(version: 1, ack_clock: 0, ..) = next(late)
}

// --- batches ---

pub fn batch_with_failing_last_event_still_broadcasts_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = join(rt, "c", "")
  let assert transport.SendModelSync(..) = next(s)
  process.send(
    rt,
    runtime.ClientEventBatchReceived(conn_id: "c", events: [
      #("click", "inc", "{}", "0", 1, ""),
      #("click", "bogus", "{}", "0", 2, ""),
    ]),
  )
  let assert transport.SendError(reason: reason) = next(s)
  let assert True = string.starts_with(reason, "1 of 2 batched events rejected")
  let assert transport.SendPatch(ops_json: ops, version: 1, ack_clock: 2) =
    next(s)
  let assert True = string.contains(ops, "/count")
}

pub fn unchanged_batch_sends_ack_only_patch_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = join(rt, "c", "")
  let assert transport.SendModelSync(..) = next(s)
  process.send(
    rt,
    runtime.ClientEventBatchReceived(conn_id: "c", events: [
      #("click", "noop", "{}", "0", 1, ""),
      #("click", "noop", "{}", "0", 3, ""),
    ]),
  )
  let assert transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 3) =
    next(s)
}

pub fn empty_batch_sends_nothing_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let s = join(rt, "c", "")
  let assert transport.SendModelSync(..) = next(s)
  process.send(rt, runtime.ClientEventBatchReceived(conn_id: "c", events: []))
  let assert transport.SendModelSync(version: 0, ..) = barrier(rt, "c", s)
}

// --- disconnect ---

pub fn disconnect_removes_connection_from_broadcasts_test() {
  let assert Ok(rt) = runtime.start(config(), test_ctx.root())
  let a = join(rt, "a", "")
  let assert transport.SendModelSync(..) = next(a)
  let b = join(rt, "b", "")
  let assert transport.SendModelSync(..) = next(b)

  process.send(rt, runtime.ClientDisconnected(conn_id: "a"))
  event(rt, "b", "inc", 1)
  let assert transport.SendPatch(version: 1, ack_clock: 1, ..) = next(b)
  let assert transport.SendModelSync(..) = barrier(rt, "b", b)
  assert_nothing_pending(a)

  // With nobody joined, updates are not broadcast and the revision holds;
  // the next joiner gets the current model at that revision.
  process.send(rt, runtime.ClientDisconnected(conn_id: "b"))
  process.send(rt, runtime.EffectDispatched(message: Inc))
  let c = join(rt, "c", "")
  let assert transport.SendModelSync(model_json: json, version: 1, ack_clock: 0) =
    next(c)
  let assert True = string.contains(json, "\"count\":2")
  assert_nothing_pending(b)
}

// --- dynamic subscriptions ---

pub fn join_reconciles_dynamic_subscriptions_test() {
  pubsub.start()
  let computed = process.new_subject()
  let cfg =
    runtime.RuntimeConfig(
      ..config(),
      restore_model: Some(fn(json, _fresh) {
        case json {
          "recovered" -> Ok(Model(count: 5, blob: "", path: ""))
          _ -> Error("unexpected model json")
        }
      }),
      dynamic_subscriptions: Some(fn(m: Model) {
        let topics = ["rv_join_topic_" <> int.to_string(m.count)]
        process.send(computed, topics)
        topics
      }),
      on_notify: Some(fn(_topic) { Noop }),
    )
  let assert Ok(rt) = runtime.start(cfg, test_ctx.root())
  let token =
    runtime.create_state_token(
      Model(count: 5, blob: "", path: ""),
      fn(_m) { "recovered" },
      secret,
    )
  let s = connect(rt, "c")
  process.send(rt, runtime.ClientJoined(conn_id: "c", token: token, path: ""))
  let assert transport.SendModelSync(model_json: json, ..) = next(s)
  let assert True = string.contains(json, "\"count\":5")
  wait_for_topics(computed, ["rv_join_topic_5"])
  await.until_telemetry(
    [subscription_changed],
    "the listener to join rv_join_topic_5",
    fn() { pubsub.subscriber_count("rv_join_topic_5") == 1 },
  )
  await.until_telemetry(
    [subscription_changed],
    "the listener to leave rv_join_topic_0",
    fn() { pubsub.subscriber_count("rv_join_topic_0") == 0 },
  )
  process.send(rt, runtime.Shutdown)
}

fn wait_for_topics(computed: Subject(List(String)), expected: List(String)) {
  let assert Ok(topics) = process.receive(computed, 2000)
  case topics == expected {
    True -> Nil
    False -> wait_for_topics(computed, expected)
  }
}

/// The runtime's PubSub listener emits this after each pg join or leave.
const subscription_changed = ["brazier", "subscription", "changed"]

// --- snapshot diffs ---

fn cache_of(json: String) -> runtime.CachedModelState {
  let assert Ok(snapshot) = patch.snapshot(json) as "test model JSON is valid"
  runtime.FullModelCache(snapshot)
}

pub fn snapshot_diff_of_equal_json_is_unchanged_test() {
  let json = model_json(Model(0, "", "/"))
  let cache = cache_of(json)
  let assert runtime.FullModelCache(cached) = cache
  // The very snapshot that is cached comes back: nothing was decoded.
  let assert runtime.Unchanged(snapshot) = runtime.diff_snapshot(cache, json)
  let assert True = snapshot == cached
}

pub fn snapshot_diff_of_equivalent_json_is_unchanged_test() {
  // A different string that decodes equal: no patch, and the new string is
  // what gets cached.
  let new_json = " " <> model_json(Model(0, "", "/"))
  let assert runtime.Unchanged(snapshot) =
    runtime.diff_snapshot(cache_of(model_json(Model(0, "", "/"))), new_json)
  let assert True = patch.snapshot_json(snapshot) == new_json
}

pub fn snapshot_diff_reports_only_changed_fields_test() {
  let new_json = model_json(Model(1, "", "/"))
  let assert runtime.Changed(ops, snapshot) =
    runtime.diff_snapshot(cache_of(model_json(Model(0, "", "/"))), new_json)
  let assert True = string.contains(ops, "\"/count\"")
  let assert False = string.contains(ops, "/path")
  let assert False = string.contains(ops, "/blob")
  let assert True = patch.snapshot_json(snapshot) == new_json
}

pub fn snapshot_diff_without_cache_is_resync_test() {
  let json = model_json(Model(0, "", ""))
  let assert runtime.Resync(snapshot) =
    runtime.diff_snapshot(runtime.NoCache, json)
  let assert True = patch.snapshot_json(snapshot) == json
}

pub fn snapshot_diff_of_invalid_json_is_refused_test() {
  let assert runtime.InvalidJson(reason) =
    runtime.diff_snapshot(cache_of(model_json(Model(0, "", ""))), "{\"count\":")
  let assert True = string.contains(reason, "does not decode")
  let assert runtime.InvalidJson(_) =
    runtime.diff_snapshot(runtime.NoCache, "{\"count\":1} trailing")
}

@external(erlang, "brazier_patch_test_ffi", "random_chain")
fn random_chain(seed: Int, steps: Int) -> List(String)

/// PERF-2 property: over seeded chains of random models, the cache the
/// runtime keeps (decoded once per model) turns each step into ops that
/// take the client's copy of the previous model exactly to the new one,
/// and reports "unchanged" only when the documents decode equal.
pub fn snapshot_diff_chain_patches_client_to_every_new_model_test() {
  let #(changed, unchanged) =
    int.range(from: 1, to: 201, with: #(0, 0), run: fn(counts, seed) {
      let assert [first, ..rest] = random_chain(seed, 25)
        as "a chain has a first model"
      let assert runtime.Resync(snapshot) =
        runtime.diff_snapshot(runtime.NoCache, first)
      let #(_, _, counts) =
        list.fold(
          rest,
          #(runtime.FullModelCache(snapshot), first, counts),
          fn(acc, new_json) {
            let #(cache, client, #(changed, unchanged)) = acc
            case runtime.diff_snapshot(cache, new_json) {
              runtime.Changed(ops, snapshot) -> {
                let assert False = ops == "[]" as "Changed carries real ops"
                let assert Ok(patched) = patch.apply_ops(client, ops)
                  as { "seed " <> int.to_string(seed) <> ": ops refused" }
                let assert True = canonical(patched) == canonical(new_json)
                  as {
                    "seed "
                    <> int.to_string(seed)
                    <> ": patched "
                    <> patched
                    <> " is not "
                    <> new_json
                  }
                #(
                  runtime.FullModelCache(snapshot),
                  patched,
                  #(changed + 1, unchanged),
                )
              }
              runtime.Unchanged(snapshot) -> {
                let assert True = canonical(client) == canonical(new_json)
                  as { "seed " <> int.to_string(seed) <> ": missed a change" }
                #(
                  runtime.FullModelCache(snapshot),
                  client,
                  #(changed, unchanged + 1),
                )
              }
              runtime.Resync(_) -> panic as "a cached snapshot never resyncs"
              runtime.InvalidJson(reason) ->
                panic as { "generated JSON refused: " <> reason }
            }
          },
        )
      counts
    })
  // Both outcomes must be exercised in quantity, or the property is weak.
  let assert True = changed > 3000 as "most chain steps change the model"
  let assert True = unchanged > 500 as "some chain steps leave it unchanged"
}

/// Re-encode through the patch engine (empty ops) so key order is canonical.
fn canonical(json: String) -> String {
  let assert Ok(encoded) = patch.apply_ops(json, "[]")
    as "canonical of valid JSON"
  encoded
}

/// `config()` with an encoder that reports each call (the model's count)
/// to `encodes`, and returns invalid JSON while the count is 1.
fn reporting_config(
  encodes: Subject(Int),
) -> runtime.RuntimeConfig(Model, Msg) {
  runtime.RuntimeConfig(..config(), encode_model: fn(m: Model) {
    process.send(encodes, m.count)
    case m.count {
      1 -> "{\"count\":"
      _ -> model_json(m)
    }
  })
}

/// Every encode reported so far. The runtime reports an encode before it
/// sends what it encoded, so after receiving that frame the report is
/// already in this process's mailbox.
fn encodes_so_far(encodes: Subject(Int), acc: List(Int)) -> List(Int) {
  case process.receive(encodes, 0) {
    Ok(count) -> encodes_so_far(encodes, [count, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn invalid_model_json_fails_loudly_and_resyncs_after_fix_test() {
  let encodes = process.new_subject()
  let assert Ok(rt) = runtime.start(reporting_config(encodes), test_ctx.root())
  let s = join(rt, "c", "")
  let assert transport.SendModelSync(version: 0, ..) = next(s)

  // The encoder returns invalid JSON: nothing reaches the client but an
  // error, and the event is still acknowledged at the same revision.
  event(rt, "c", "inc", 1)
  let assert transport.SendError(reason: "Model encoder returned invalid JSON") =
    next(s)
  let assert transport.SendPatch(ops_json: "[]", version: 0, ack_clock: 1) =
    next(s)

  // A join while the encoder is broken gets the same error, and so does
  // the joined connection, since there is no cache to trust.
  let late = join(rt, "late", "")
  let assert transport.SendError(reason: "Model encoder returned invalid JSON") =
    next(late)
  let assert transport.SendError(reason: "Model encoder returned invalid JSON") =
    next(s)

  // Valid JSON again: every joined connection resyncs at a new revision.
  event(rt, "c", "inc", 2)
  let assert transport.SendModelSync(model_json: json, version: 1, ack_clock: 2) =
    next(s)
  let assert True = string.contains(json, "\"count\":2")
  let assert transport.SendModelSync(version: 1, ack_clock: 0, ..) = next(late)
  process.send(rt, runtime.Shutdown)
}

/// PERF-2: a broadcast that falls back to a full model_sync sends the model
/// it encoded for the diff; it does not encode it a second time.
pub fn broadcast_resync_encodes_the_model_once_test() {
  let encodes = process.new_subject()
  let assert Ok(rt) = runtime.start(reporting_config(encodes), test_ctx.root())
  let s = join(rt, "c", "")
  let assert transport.SendModelSync(version: 0, ..) = next(s)
  // Count 1 encodes invalid JSON, which drops the cache.
  event(rt, "c", "inc", 1)
  let assert transport.SendError(..) = next(s)
  let assert transport.SendPatch(ops_json: "[]", ..) = next(s)
  let assert [0, 1] = encodes_so_far(encodes, [])

  event(rt, "c", "inc", 2)
  let assert transport.SendModelSync(version: 1, ack_clock: 2, ..) = next(s)
  let assert [2] = encodes_so_far(encodes, [])
  process.send(rt, runtime.Shutdown)
}

// --- client replay of server frames (server and client versioning agree) ---

@external(erlang, "brazier_patch_test_ffi", "run_node")
fn run_node(script: String, arg: String) -> Result(String, String)

@external(erlang, "brazier_patch_test_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "brazier_patch_test_ffi", "scratch_path")
fn scratch_path(name: String) -> String

/// Wire JSON of a state message, exactly as the transport sends it.
fn wire(message: transport.InternalMessage) -> String {
  case message {
    transport.SendModelSync(model_json:, version:, ack_clock:) ->
      transport.encode_server_message(transport.ServerModelSync(
        model_json:,
        version:,
        ack_clock:,
      ))
    transport.SendPatch(ops_json:, version:, ack_clock:) ->
      transport.encode_server_message(transport.ServerPatch(
        ops_json:,
        version:,
        ack_clock:,
      ))
    other -> panic as { "not a state message: " <> string.inspect(other) }
  }
}

/// Drive one session through every revision rule and record, in order, the
/// state frames connection "a" receives. Returns the frames plus the final
/// barrier model_sync (model JSON and revision), which is not in the frames.
fn record_session() -> #(List(String), String, Int) {
  let proof = process.new_subject()
  let assert Ok(rt) = runtime.start(route_config(proof), test_ctx.root())
  let a = join(rt, "a", "/")
  let assert Ok("/") = process.receive(proof, 1000)
  let f0 = next(a)
  let assert transport.SendModelSync(version: 0, ..) = f0
  let b = join(rt, "b", "/")
  let assert transport.SendModelSync(version: 0, ..) = next(b)

  // Own change, own unchanged event (ack), another connection's change.
  event(rt, "a", "inc", 1)
  let f1 = next(a)
  let assert transport.SendPatch(version: 1, ack_clock: 1, ..) = f1
  let assert transport.SendPatch(version: 1, ..) = next(b)
  event(rt, "a", "noop", 2)
  let f2 = next(a)
  let assert transport.SendPatch(ops_json: "[]", version: 1, ack_clock: 2) = f2
  event(rt, "b", "inc", 1)
  let f3 = next(a)
  let assert transport.SendPatch(version: 2, ack_clock: 2, ..) = f3
  let assert transport.SendPatch(version: 2, ..) = next(b)

  // Navigation that changes the model, then one that does not.
  process.send(rt, runtime.ClientNavigated(conn_id: "a", path: "/a"))
  let assert Ok("/a") = process.receive(proof, 1000)
  let f4 = next(a)
  let assert transport.SendPatch(version: 3, ..) = f4
  let assert transport.SendPatch(version: 3, ..) = next(b)
  process.send(rt, runtime.ClientNavigated(conn_id: "a", path: "/a"))
  let assert Ok("/a") = process.receive(proof, 1000)

  // A failing event: error (not a state frame), then an ack.
  event(rt, "a", "bogus", 3)
  let assert transport.SendError(..) = next(a)
  let f5 = next(a)
  let assert transport.SendPatch(ops_json: "[]", version: 3, ack_clock: 3) = f5

  // Rejoin: full resync at the current revision.
  process.send(rt, runtime.ClientJoined(conn_id: "a", token: "", path: "/a"))
  let f6 = next(a)
  let assert transport.SendModelSync(version: 3, ack_clock: 3, ..) = f6

  // A join on another route changes the model for everyone already joined.
  let c = join(rt, "c", "/")
  let assert Ok("/") = process.receive(proof, 1000)
  let assert transport.SendModelSync(version: 4, ..) = next(c)
  let f7 = next(a)
  let assert transport.SendPatch(version: 4, ..) = f7

  // A batch with a change and an unchanged event: one revision.
  process.send(
    rt,
    runtime.ClientEventBatchReceived(conn_id: "a", events: [
      #("click", "inc", "{}", "0", 4, ""),
      #("click", "noop", "{}", "0", 5, ""),
      #("click", "inc", "{}", "0", 6, ""),
    ]),
  )
  let f8 = next(a)
  let assert transport.SendPatch(version: 5, ack_clock: 6, ..) = f8

  let assert transport.SendModelSync(model_json: final_json, version: 5, ..) =
    barrier(rt, "a", a)
  let frames = list.map([f0, f1, f2, f3, f4, f5, f6, f7, f8], wire)
  #(frames, final_json, 5)
}

fn replay_on_client(
  name: String,
  frames: List(String),
  final_json: String,
  final_version: Int,
) -> Result(String, String) {
  let contents =
    json.object([
      #("messages", json.array(frames, json.string)),
      #("final_model", json.string(final_json)),
      #("final_version", json.int(final_version)),
    ])
    |> json.to_string
  let path = scratch_path(name)
  let assert Ok(Nil) = write_file(path, contents)
  run_node("brazier_client/test/sync_vectors.mjs", path)
}

pub fn client_replay_detects_a_missing_patch_test() {
  let #(frames, final_json, final_version) = record_session()
  // Drop the first patch (revision 1): the next patch is a gap.
  let assert [f0, _f1, ..rest] = frames
  let assert Error(output) =
    replay_on_client("sync_gap.json", [f0, ..rest], final_json, final_version)
  let assert True = string.contains(output, "verdict gap")
}

pub fn client_replay_detects_a_duplicated_patch_test() {
  let #(frames, final_json, final_version) = record_session()
  let assert [f0, f1, ..rest] = frames
  let assert Error(output) =
    replay_on_client(
      "sync_dup.json",
      [f0, f1, f1, ..rest],
      final_json,
      final_version,
    )
  let assert True = string.contains(output, "verdict stale")
}

pub fn client_replay_detects_a_wrong_final_model_test() {
  let #(frames, _final_json, final_version) = record_session()
  let assert Error(output) =
    replay_on_client(
      "sync_final.json",
      frames,
      "{\"count\":-1,\"blob\":\"\",\"path\":\"/\"}",
      final_version,
    )
  let assert True = string.contains(output, "final model_sync")
}

pub fn client_replay_of_server_frames_matches_final_sync_test() {
  let #(frames, final_json, final_version) = record_session()
  let assert Ok(output) =
    replay_on_client("sync_ok.json", frames, final_json, final_version)
  let assert True = string.contains(output, "9 replayed frames")
}

/// The browser runtime itself (startup checks, the socket URL, close codes,
/// backoff, heartbeats, outbound pacing, server errors, revision handling,
/// event delegation with prevent-default, stop-propagation, debounce and
/// throttle, decoder failures, submit form data, pre-hydration replay,
/// `simple` prediction, the focused-input lock, autofocus, server navigation
/// and its same-origin refusals, ack_clock and event clock validation, hook
/// mount/update/unmount tracking, the parsed-markup cache, the join's build
/// id, 4409 behind the reload guard, the outbound test hook, refusal of a model or ops sent as JSON text, and the dev
/// `reload` message) driven by a fake socket, clock and DOM. The harness
/// exits non-zero on any failed scenario.
pub fn client_runtime_behaviour_harness_test() {
  let assert Ok(output) = run_node("brazier_client/test/ffi_harness.mjs", "")
    as "the client FFI harness failed; run node brazier_client/test/ffi_harness.mjs"
  let assert True = string.contains(output, "ffi harness ok: 47 scenarios")
    as "the client FFI harness did not run all 47 scenarios"
}
