// Beacon Client Runtime — the ONLY JavaScript that runs in the browser.
// Event delegation, WebSocket, DOM morphing, Rendered format — all here.
// When BeaconApp is available (compiled user code), runs updates LOCALLY.
// Local-only events produce ZERO WebSocket traffic.
// Keydown is forwarded for non-text targets, and text inputs/textareas only
// forward Enter without Shift when not composing, so chat composers do not
// flood the server while still supporting submit-by-enter.

import { Ok, Error as GleamError } from "./gleam.mjs";
import {
  applyOps,
  classifyModelSync,
  classifyPatch,
  closeAction,
  heartbeatAllowed,
  messageCost,
  PacedQueue,
  reconnectDelayMs,
  SendBudget,
  splitEventBatch,
  CLIENT_SEND_BUDGET,
  CLIENT_SEND_WINDOW_MS,
} from "./beacon_client/patch.mjs";

// === State ===
const _pd = {};
let ws = null;
let heartbeatTimer = null;
let lastHeartbeatAt = null;
const HEARTBEAT_INTERVAL_MS = 30000;
let reconnectAttempts = 0;
// Set on close code 4401: the session is revoked, so never reconnect with it.
let reconnectStopped = false;
// True once the join for the current socket has been written.
let socketJoined = false;
// True once a model_sync of the current connection has been applied.
let modelSynced = false;
// model_sync failures in a row; after MAX_MODEL_SYNC_RETRIES resync requests
// the client stops asking (syncGaveUp) until the next connection.
let consecutiveModelSyncFailures = 0;
const MAX_MODEL_SYNC_RETRIES = 3;
let syncGaveUp = false;
let appRoot = null;
let hydrated = false;
let eventClock = 0;
let currentModelVersion = 0;
let latestAckClock = 0;
const TRACE_LIMIT = 400;
const traceBuffer = [];
const hookRegistry = new Map();
const mountedHooks = new WeakMap();

// === Outbound pacing ===
// Every non-heartbeat message is charged against a client send budget the way
// the server rate limiter counts it (an event_batch costs its length), and
// waits in one paced queue. Nothing is dropped silently: when the queue is
// full the message is reported with console.error and a full model sync is
// requested once the queue drains.
const MAX_PENDING_SEND_QUEUE = 200;
const outbound = new PacedQueue(
  new SendBudget(CLIENT_SEND_BUDGET, CLIENT_SEND_WINDOW_MS),
  MAX_PENDING_SEND_QUEUE,
);
let outboundOverflowed = false;
let pumpTimer = null;
const MAX_PENDING_EARLY_EVENTS = 50;
const INPUT_DEBOUNCE_MS = 80;
const pendingInputEvents = new Map();

function isDevMode() {
  return !!appRoot && appRoot.getAttribute("data-beacon-dev") === "true";
}

function trace(kind, detail = {}) {
  if (!isDevMode()) return;
  traceBuffer.push({ ts: Date.now(), kind, ...detail });
  if (traceBuffer.length > TRACE_LIMIT) traceBuffer.shift();
}

function mark(name) {
  if (typeof performance !== "undefined" && performance.mark) {
    performance.mark("beacon:" + name);
  }
}

function measure(name, start, end) {
  if (typeof performance !== "undefined" && performance.measure) {
    try { performance.measure("beacon:" + name, "beacon:" + start, "beacon:" + end); } catch (_) {}
  }
}

function ensureBeaconDebug() {
  if (typeof window === "undefined") return;
  window.__beacon = window.__beacon || {};
  window.__beacon.trace = () => traceBuffer.slice();
}

function ensureHookRegistry() {
  if (typeof window === "undefined") return;
  window.beaconClient = window.beaconClient || {};
  window.beaconClient.registerHook = (name, hook) => {
    hookRegistry.set(name, hook);
    trace("hook.register", { name });
  };
}

// === Client-Side State (when BeaconApp is available) ===
let clientModel = null;
let clientLocal = null;
let clientRegistry = null;
let clientInitialized = false;
let renderPending = false;  // RAF throttle: true when a render is scheduled
let clientModelJson = null;  // Cached JSON representation for patch diffing
let pendingEarlyEvents = [];
let readyForServerEvents = false;
let syncRequestInFlight = false;
let pendingModelEventClock = 0;
let skippedAuthoritativeWhilePending = false;

// === Process Dictionary (handler registry storage) ===
export function pd_set(key, value) { _pd[key] = value; return undefined; }
export function pd_get(key) {
  return key in _pd ? new Ok(_pd[key]) : new GleamError(undefined);
}

// === Client-Side Execution ===
export function initClient() {
  // State-over-the-wire: client waits for model_sync from server to initialize.
  // The real model comes from the server — we don't use the stub init().
  // handleModelSync will set clientModel, clientLocal, and clientInitialized.
  if (!window.BeaconApp) return;
  console.log("[beacon] BeaconApp loaded, waiting for model_sync...");
}

function clientRenderNow() {
  if (!clientInitialized || !appRoot) return;
  const App = window.BeaconApp;
  mark("render-start");
  const t0 = performance.now();
  App.start_render();
  const html = App.view_to_html(clientModel, clientLocal);
  clientRegistry = App.finish_render();
  const t1 = performance.now();
  morphInnerHTML(appRoot, html);
  const t2 = performance.now();
  attachEvents();
  renderPending = false;
  // Log slow renders (>5ms)
  const total = t2 - t0;
  if (total > 5) {
    console.log("[beacon] Slow render: view=" + (t1-t0).toFixed(1) + "ms morph=" + (t2-t1).toFixed(1) + "ms total=" + total.toFixed(1) + "ms");
  }
  window._lastRenderMs = total;
  mark("render-end");
  measure("render", "render-start", "render-end");
}

// Throttled render — batches multiple LOCAL events into one render per frame.
// State is updated immediately (clientModel/clientLocal always current),
// but DOM rendering is deferred to the next animation frame.
function clientRender() {
  if (renderPending) return;  // Already scheduled
  renderPending = true;
  requestAnimationFrame(clientRenderNow);
}

// Synchronous render — used when we need the DOM up-to-date immediately
// (e.g., before sending a MODEL event to the server).
function clientRenderFlush() {
  if (renderPending) {
    renderPending = false;
    clientRenderNow();
  }
}

// Handles an event locally. Returns:
// {action: "local"} — LOCAL event, handled client-only, don't send to server
// {action: "send", ops: "", msg, affectsModel: Bool} — send encoded Msg to server
// {action: "send", ops: ""} — MODEL event, server recomputes authoritative state
function handleEventLocally(handlerId, eventData, eventName, targetPath, clock) {
  if (!clientInitialized) return { action: "send", ops: "" };
  const App = window.BeaconApp;

  if (!App.encode_msg) {
    console.error("[beacon] Generated client is missing encode_msg; event contract is unavailable.");
    return { action: "error" };
  }

  const result = App.resolve_handler(clientRegistry, handlerId, eventData);
  if (!result.isOk()) {
    console.error("[beacon] Could not resolve client handler " + handlerId + "; event contract is unavailable.");
    return { action: "error" };
  }

  try {
    const msg = result[0];

    if (!App.update || !App.msg_affects_model) {
      return { action: "send", ops: "", msg, affectsModel: false };
    }

    const updateResult = App.update(clientModel, clientLocal, msg);
    clientModel = updateResult[0];
    clientLocal = updateResult[1];
    clientRender();

    const affectsModel = App.msg_affects_model(msg);
    if (affectsModel) {
      // MODEL event — rendered optimistically on the client, then sent as an
      // event. The server recomputes the authoritative model and returns sync/patch.
      return { action: "send", ops: "", msg, affectsModel: true };
    } else if (eventName === "keydown") {
      // Keydown events must still reach the server so server-side apps can
      // respond to Enter / navigation keys even when the local update is
      // model-neutral.
      return { action: "send", ops: "", msg, affectsModel: false };
    } else {
      // LOCAL event — client-only, zero server traffic
      return { action: "local" };
    }
  } catch (e) {
    console.error("[beacon] Local update crashed; generated event contract cannot continue.", e);
    clientInitialized = false;
    return { action: "error" };
  }
}

function hasPendingModelEvent() {
  return pendingModelEventClock > latestAckClock;
}

function shouldHoldServerState(ackClock, kind, version) {
  if (hasPendingModelEvent() && ackClock < pendingModelEventClock) {
    skippedAuthoritativeWhilePending = true;
    trace(kind + ".held_for_pending_event", { version, ackClock, pendingModelEventClock });
    return true;
  }
  return false;
}

function needsFullSyncAfterHeldPatch(ackClock) {
  return skippedAuthoritativeWhilePending && ackClock >= pendingModelEventClock;
}

function markServerAckApplied(ackClock) {
  latestAckClock = Math.max(latestAckClock, ackClock);
  if (latestAckClock >= pendingModelEventClock) {
    pendingModelEventClock = 0;
    skippedAuthoritativeWhilePending = false;
  }
}

// === Initialization ===
export function boot(rootSelector) {
  const root = document.querySelector(rootSelector || "#beacon-app");
  if (!root) { console.error("[beacon] Root not found:", rootSelector); return undefined; }
  mark("boot");
  ensureBeaconDebug();
  ensureHookRegistry();
  setAppRoot(root);
  hydrated = appRoot.childNodes.length > 0;
  if (hydrated) attachEvents();
  const wsUrl = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws";
  connect(wsUrl);
  return undefined;
}

function setAppRoot(root) {
  const previousRoot = appRoot;
  appRoot = root;
  if (!previousRoot) {
    trace("root.init", { root: describeNode(root) });
    return;
  }
  if (previousRoot === root) return;
  trace("root.replace", {
    from: describeNode(previousRoot),
    to: describeNode(root),
  });
  unmountSubtree(previousRoot);
}

// === WebSocket ===
function connect(wsUrl) {
  if (reconnectStopped) {
    console.error("[beacon] Not connecting: the session was revoked (close 4401). Reload to sign in again.");
    return;
  }
  readyForServerEvents = false;
  socketJoined = false;
  modelSynced = false;
  currentModelVersion = 0;
  latestAckClock = 0;
  syncRequestInFlight = false;
  syncGaveUp = false;
  consecutiveModelSyncFailures = 0;
  pendingModelEventClock = 0;
  skippedAuthoritativeWhilePending = false;
  // The server counts its rate limit per connection, so a new socket starts
  // with a fresh budget. A queued request_sync is superseded by the join's
  // model_sync.
  outbound.setBudget(new SendBudget(CLIENT_SEND_BUDGET, CLIENT_SEND_WINDOW_MS));
  const purged = outbound.removeWhere((msg) => msg.type === "request_sync");
  if (purged > 0) trace("send_queue.purge_request_sync", { purged });
  const socket = new WebSocket(wsUrl);
  ws = socket;
  socket.onopen = () => {
    mark("ws-open");
    startHeartbeat(socket);
    sendJoin(socket);
  };
  socket.onmessage = (e) => handleMessage(e.data);
  socket.onclose = (e) => handleClose(socket, wsUrl, e);
  socket.onerror = (e) => console.error("[beacon] WS error:", e);
}

function sendJoin(socket) {
  // A new connection has a fresh budget, so the join always fits. Charging it
  // keeps the client budget in step with the server's count.
  if (!outbound.budget.tryTake(performance.now(), 1)) {
    throw new Error("[beacon] invariant violated: join does not fit a fresh send budget");
  }
  if (!writeSocket(socket, { type: "join", token: "", path: location.pathname + location.search })) {
    console.error("[beacon] Join could not be written; closing the socket to reconnect");
    socket.close(4000, "join send failed");
    return;
  }
  socketJoined = true;
  trace("ws.join");
  pumpOutbound();
}

function handleClose(socket, wsUrl, e) {
  if (socket !== ws) {
    console.warn("[beacon] Close event for a replaced socket ignored (code " + e.code + ")");
    return;
  }
  stopHeartbeat();
  socketJoined = false;
  readyForServerEvents = false;
  trace("ws.close", { code: e.code, reason: e.reason });
  if (closeAction(e.code) === "stop") {
    reconnectStopped = true;
    console.error("[beacon] Session revoked or authentication expired (close 4401" + (e.reason ? ": " + e.reason : "") + "); not reconnecting, reloading the page");
    location.reload();
    return;
  }
  console.warn("[beacon] WebSocket closed (code " + e.code + (e.reason ? ", " + e.reason : "") + "); reconnecting with backoff");
  scheduleReconnect(wsUrl);
}

// Write one message to the socket. Returns false when it was not written.
function writeSocket(socket, msg) {
  if (socket !== ws || socket.readyState !== WebSocket.OPEN) return false;
  try {
    socket.send(JSON.stringify(msg));
    return true;
  } catch (e) {
    console.error("[beacon] WS send failed for " + msg.type + "; it stays queued:", e);
    return false;
  }
}

// Queue a message for the paced sender. Returns false when the queue is full;
// the message is then reported and a full sync follows once the queue drains.
function send(msg) {
  const cost = messageCost(msg);
  if (!outbound.push(msg, cost, msg.type === "request_sync")) {
    console.error("[beacon] Outbound queue full (" + MAX_PENDING_SEND_QUEUE + " messages); " + msg.type + " was not sent. A full model sync will follow.");
    trace("send_queue.full", { type: msg.type, size: outbound.length });
    outboundOverflowed = true;
    return false;
  }
  trace("send_queue.enqueue", { type: msg.type, size: outbound.length });
  pumpOutbound();
  return true;
}

// request_sync only needs a joined socket; everything else also waits for
// the first model_sync (or mount) so it is processed against a known model.
function canSendNow(msg) {
  if (!ws || ws.readyState !== WebSocket.OPEN || !socketJoined) return false;
  return msg.type === "request_sync" || readyForServerEvents;
}

function pumpOutbound() {
  if (pumpTimer !== null) return;
  const socket = ws;
  const result = outbound.pump(performance.now(), canSendNow, (msg) => writeSocket(socket, msg));
  if (result.waitMs > 0) {
    trace("send_queue.paced", { waitMs: result.waitMs, size: outbound.length });
    pumpTimer = setTimeout(() => {
      pumpTimer = null;
      pumpOutbound();
    }, result.waitMs);
    return;
  }
  if (outbound.length === 0 && outboundOverflowed) {
    outboundOverflowed = false;
    requestFullSync("outbound_queue_overflow");
  }
}

// Debug: expose WS state for testing when running in a browser.
if (typeof window !== "undefined") {
  window.__beaconWsState = () => ws ? ws.readyState : -1;
  window.__beaconConnectionReady = () => readyForServerEvents;
  if (window.__BEACON_ENABLE_TEST_HOOKS === true) {
    window.__beaconCloseSocketForTest = () => {
      if (!ws) return -1;
      const state = ws.readyState;
      ws.close(4000, "beacon test close");
      return state;
    };
  }
}

function startHeartbeat(socket) {
  stopHeartbeat();
  heartbeatTimer = setInterval(() => sendHeartbeat(socket), HEARTBEAT_INTERVAL_MS);
}

// Heartbeats are never queued: a queued burst would exceed the server's limit
// of 2 per second, and a closed socket has nothing to keep alive.
function sendHeartbeat(socket) {
  const now = performance.now();
  if (!heartbeatAllowed(lastHeartbeatAt, now)) {
    console.warn("[beacon] Heartbeat skipped: the previous one was sent under 500ms ago");
    return;
  }
  if (writeSocket(socket, { type: "heartbeat" })) {
    lastHeartbeatAt = now;
  } else {
    trace("heartbeat.skip", { readyState: socket.readyState });
  }
}

function stopHeartbeat() { if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; } }

function scheduleReconnect(wsUrl) {
  const delay = reconnectDelayMs(reconnectAttempts, Math.random());
  reconnectAttempts++;
  console.log("[beacon] Reconnect attempt " + reconnectAttempts + " in " + delay + "ms");
  setTimeout(() => connect(wsUrl), delay);
}

export function ws_send(data) {
  const msg = JSON.parse(data);
  if (msg.type === "event_batch") {
    for (const batch of splitEventBatch(msg, CLIENT_SEND_BUDGET)) send(batch);
  } else {
    send(msg);
  }
  return undefined;
}
export function ws_connect(url) { connect(url); return undefined; }

// === Message Handling ===
function handleMessage(raw) {
  let msg;
  // A frame that is not JSON cannot be processed. It may have been a patch,
  // so the cached model can no longer be trusted: log it and resync.
  try { msg = JSON.parse(raw); } catch (e) {
    console.error("[beacon] Failed to parse server message:", e.message, raw.substring(0, 100));
    requestFullSync("unparseable_server_message");
    return;
  }
  switch (msg.type) {
    case "mount": handleMount(msg.payload); break;
    case "model_sync": handleModelSync(msg.model, msg.version, msg.ack_clock || 0); break;
    case "patch": handlePatch(msg.ops, msg.version, msg.ack_clock || 0); break;
    case "navigate": handleServerNavigate(msg.path); break;
    case "hard_navigate": handleServerHardNavigate(msg.path); break;
    case "reload": console.log("[beacon] Hot reload — refreshing..."); location.reload(); break;
    case "heartbeat_ack": break;
    case "error": handleServerError(msg.reason); break;
    default: console.error("[beacon] Unknown server message type:", msg.type); break;
  }
}

function handleServerError(reason) {
  console.error("[beacon] Server error:", reason);
  trace("server_error", { reason });
  if (reason === "Rate limited" || reason === "Batch too large") {
    // The server rejected a whole message, so the client may hold optimistic
    // state the server never saw. The rejected message may have been our
    // request_sync, so an in-flight request no longer counts.
    syncRequestInFlight = false;
    requestFullSync("server_rejected: " + reason);
  }
}

function handleMount(payload) {
  if (!appRoot) return;
  // Always morph mount HTML into the DOM. The mount is authoritative —
  // it reflects the ws_init model which may differ from SSR (e.g., auth state).
  // SSR content was a quick first paint; the mount from the runtime replaces it.
  hydrated = false;
  morphInnerHTML(appRoot, payload);
  attachEvents();
  syncHooks(appRoot);
  trace("mount", { length: payload.length });
  readyForServerEvents = true;
  pumpOutbound();
}

// Decode authoritative client-visible model JSON into clientModel (and
// clientLocal when the JSON carries it) and render. Returns null on success or
// the reason it failed. May throw if generated code throws.
function adoptAuthoritativeModel(App, modelStr) {
  const result = App.decode_model(modelStr);
  if (!result.isOk()) return "decode_model failed: " + String(result[0]);
  clientModel = result[0];
  if (App.decode_local) {
    const localResult = App.decode_local(modelStr);
    if (localResult.isOk()) {
      clientLocal = localResult[0];
    } else {
      // Local state is client-owned; JSON without Local fields keeps it.
      trace("local.kept", { reason: String(localResult[0]) });
    }
  }
  if (!clientInitialized) {
    if (!clientLocal && App.init_local) {
      clientLocal = App.init_local(clientModel);
    }
    if (!clientLocal) clientLocal = null;
    clientInitialized = true;
    console.log("[beacon] Client-side execution ready (from model_sync)");
  }
  // Synchronous render so the DOM updates immediately
  // (requestAnimationFrame may not fire in background tabs).
  clientRenderNow();
  return null;
}

function invalidateModelCache() {
  clientModelJson = null;
  modelSynced = false;
}

function handleModelSync(modelJson, version, ackClock) {
  // Any model_sync answers an outstanding request_sync, applied or not.
  syncRequestInFlight = false;
  if (!window.BeaconApp) return;
  const App = window.BeaconApp;
  if (!App.decode_model) {
    console.error("[beacon] model_sync received but the generated client has no decode_model");
    return;
  }
  mark("model-sync-start");
  const verdict = classifyModelSync({ version: currentModelVersion, synced: modelSynced }, version);
  if (verdict === "invalid") {
    modelSyncFailed(version, "invalid version " + JSON.stringify(version));
    return;
  }
  if (verdict === "stale") {
    trace("model_sync.stale", { version, currentModelVersion });
    return;
  }
  if (shouldHoldServerState(ackClock, "model_sync", version)) return;

  let parsed;
  try {
    parsed = JSON.parse(modelJson);
    const failure = adoptAuthoritativeModel(App, modelJson);
    if (failure !== null) {
      modelSyncFailed(version, failure);
      return;
    }
  } catch (e) {
    modelSyncFailed(version, e && e.message ? e.message : String(e));
    return;
  }
  clientModelJson = parsed;
  currentModelVersion = version;
  modelSynced = true;
  consecutiveModelSyncFailures = 0;
  // Backoff resets only once a connection proved usable, so a server that
  // accepts and immediately drops sockets is still retried with backoff.
  reconnectAttempts = 0;
  markServerAckApplied(ackClock);
  console.log("[beacon] Model synced v" + version);
  trace("model_sync", { version, ackClock });
  readyForServerEvents = true;
  flushPendingEarlyEvents();
  pumpOutbound();
  mark("model-sync-end");
  measure("model-sync", "model-sync-start", "model-sync-end");
}

function modelSyncFailed(version, reason) {
  consecutiveModelSyncFailures++;
  invalidateModelCache();
  if (consecutiveModelSyncFailures > MAX_MODEL_SYNC_RETRIES) {
    syncGaveUp = true;
    console.error("[beacon] model_sync v" + version + " failed " + consecutiveModelSyncFailures + " times in a row (" + reason + "). Client state is out of sync; no more resyncs on this connection. Reload the page to recover.");
    return;
  }
  console.error("[beacon] model_sync v" + version + " could not be applied (" + reason + "); requesting resync " + consecutiveModelSyncFailures + "/" + MAX_MODEL_SYNC_RETRIES);
  requestFullSync("model_sync_failed");
}

function handlePatch(opsJson, version, ackClock) {
  if (!window.BeaconApp) return;
  const App = window.BeaconApp;
  if (!App.decode_model) {
    console.error("[beacon] Patch received but the generated client has no decode_model");
    return;
  }
  mark("patch-start");
  let ops;
  try {
    ops = typeof opsJson === "string" ? JSON.parse(opsJson) : opsJson;
  } catch (e) {
    console.error("[beacon] Patch ops are not valid JSON; requesting full sync:", e.message);
    invalidateModelCache();
    requestFullSync("patch_ops_unparseable");
    return;
  }
  if (!Array.isArray(ops)) {
    console.error("[beacon] Patch ops are not an array; requesting full sync");
    invalidateModelCache();
    requestFullSync("patch_ops_not_array");
    return;
  }

  const synced = modelSynced && clientModelJson !== null;
  const verdict = classifyPatch({ version: currentModelVersion, synced }, version, ops.length);
  switch (verdict) {
    case "invalid":
      console.error("[beacon] Patch with invalid version " + JSON.stringify(version) + "; requesting full sync");
      invalidateModelCache();
      requestFullSync("invalid_patch_version");
      return;
    case "stale":
      trace("patch.stale", { version, currentModelVersion });
      return;
    case "gap":
      console.warn("[beacon] Patch v" + version + " does not build on cached v" + currentModelVersion + (synced ? "" : " (no synced model)") + "; requesting full sync");
      requestFullSync("patch_gap");
      return;
    case "ack":
      handleAckPatch(App, version, ackClock);
      return;
    case "apply":
      break;
    default:
      throw new Error("[beacon] invariant violated: unknown patch verdict " + verdict);
  }

  if (shouldHoldServerState(ackClock, "patch", version)) return;
  if (needsFullSyncAfterHeldPatch(ackClock)) {
    requestFullSync("held_patch_base_mismatch");
    return;
  }

  let newModelJson;
  try {
    // applyOps never mutates its input, so a failure leaves the cache intact
    // until it is invalidated below.
    newModelJson = applyOps(clientModelJson, ops);
    const failure = adoptAuthoritativeModel(App, JSON.stringify(newModelJson));
    if (failure !== null) {
      console.error("[beacon] Patch v" + version + " produced a model the client cannot decode (" + failure + "); requesting full sync");
      invalidateModelCache();
      requestFullSync("patch_decode_failed");
      return;
    }
  } catch (e) {
    console.error("[beacon] Patch apply failed:", e);
    invalidateModelCache();
    requestFullSync("patch_apply_failed");
    return;
  }
  clientModelJson = newModelJson;
  currentModelVersion = version;
  markServerAckApplied(ackClock);
  console.log("[beacon] Patch applied v" + version + " (" + ops.length + " ops)");
  trace("patch", { version, ackClock, ops: ops.length });
  mark("patch-end");
  measure("patch", "patch-start", "patch-end");
}

// An empty patch at the cached revision: the server processed events up to
// ackClock without changing the client-visible model. If that covers our
// pending model event, the optimistic local result is replaced by the
// authoritative cached model.
function handleAckPatch(App, version, ackClock) {
  const wasPending = hasPendingModelEvent();
  markServerAckApplied(ackClock);
  trace("patch.ack", { version, ackClock });
  if (!wasPending || hasPendingModelEvent()) return;
  try {
    const failure = adoptAuthoritativeModel(App, JSON.stringify(clientModelJson));
    if (failure !== null) {
      console.error("[beacon] Cached model v" + version + " cannot be decoded after ack (" + failure + "); requesting full sync");
      invalidateModelCache();
      requestFullSync("ack_decode_failed");
    }
  } catch (e) {
    console.error("[beacon] Re-render after ack failed:", e);
    invalidateModelCache();
    requestFullSync("ack_render_failed");
  }
}

function requestFullSync(reason) {
  if (syncGaveUp) {
    trace("sync_request.gave_up", { reason });
    return;
  }
  if (syncRequestInFlight) {
    trace("sync_request.skip", { reason });
    return;
  }
  console.warn("[beacon] Requesting full model sync: " + reason);
  trace("sync_request", { reason });
  // When the queue is full, send() reports it and the overflow resync follows
  // once the queue drains, so the request is not marked in flight here.
  if (send({ type: "request_sync" })) syncRequestInFlight = true;
}

function enqueueEarlyEvent(eventName, hid, data, tp, clock) {
  if (pendingEarlyEvents.length >= MAX_PENDING_EARLY_EVENTS) {
    console.error("[beacon] Early event queue full; dropping " + eventName + " before model_sync.");
    trace("early_event.full", { eventName, size: pendingEarlyEvents.length });
    return;
  }
  pendingEarlyEvents.push({ eventName, hid, data, tp, clock });
  trace("early_event.enqueue", { eventName, size: pendingEarlyEvents.length });
}

function flushPendingEarlyEvents() {
  if (!clientInitialized || pendingEarlyEvents.length === 0) return;
  const queued = pendingEarlyEvents;
  pendingEarlyEvents = [];
  for (const evt of queued) {
    dispatchEvent(evt.eventName, evt.hid, evt.data, evt.tp, evt.clock);
  }
  trace("early_event.flush", { count: queued.length });
}

function handleServerNavigate(path) {
  if (path && path !== location.pathname + location.search) {
    history.pushState(null, "", path);
    resetClientRouteTransientState(path);
    // Trigger navigate to server for route-change processing
    send({ type: "navigate", path: path });
  }
}

function resetClientRouteTransientState(path) {
  for (const item of pendingInputEvents.values()) {
    clearTimeout(item.timer);
  }
  pendingInputEvents.clear();
  renderPending = false;
  trace("route.transient_reset", { path });
}

// Hard navigation — full page reload via window.location.href.
// Used when the browser needs to make a real HTTP request (e.g., to receive Set-Cookie headers).
function handleServerHardNavigate(path) {
  if (!path) {
    console.warn("[beacon] Hard navigate: received empty path from server");
    return;
  }
  // SECURITY: Only allow same-origin relative paths to prevent open redirect attacks.
  // Protocol-relative URLs (//evil.com), absolute URLs, javascript: and data: are rejected.
  if (path.startsWith("/") && !path.startsWith("//")) {
    window.location.href = path;
  } else {
    console.error("[beacon] Hard navigate rejected: path must start with / (got:", path, ")");
  }
}

// === Rendered Format ===

// === DOM Morphing ===
export function morph_html(container, html) { morphInnerHTML(container, html); return undefined; }

function morphInnerHTML(container, html) {
  // Save focused element state before morphing
  const focused = document.activeElement;
  const focusedTag = focused?.tagName;
  const focusedName = focused?.getAttribute("name") || focused?.getAttribute("data-beacon-event-input");
  const selStart = focused?.selectionStart;
  const selEnd = focused?.selectionEnd;
  const focusedValue = focused?.value;

  const t = document.createElement("template"); t.innerHTML = html; morphChildren(container, t.content); syncHooks(container);
  trace("morph", { childCount: container.childNodes.length });

  // Restore focus after morph — find the same element by name/handler
  if (focusedTag === "INPUT" || focusedTag === "TEXTAREA" || focusedTag === "SELECT") {
    let restored = null;
    if (focusedName) {
      // SECURITY: Use CSS.escape to prevent selector injection from attribute values
      const safeName = CSS.escape(focusedName);
      restored = container.querySelector(`[name="${safeName}"]`) ||
                 container.querySelector(`[data-beacon-event-input="${safeName}"]`);
    }
    if (restored) {
      if (restored !== document.activeElement) {
        restored.focus();
      }
      // Preserve active typing only while an input event is still debounced.
      // Once submit/Enter has flushed input, the server-rendered value is
      // authoritative so cleared composers do not snap back to stale text.
      if (hasPendingUnackedInput() && focusedValue !== undefined && restored.value !== focusedValue) {
        restored.value = focusedValue;
      }
      // Restore cursor position
      if (typeof selStart === "number" && restored.setSelectionRange) {
        try { restored.setSelectionRange(selStart, selEnd); } catch(e) { console.warn("[beacon] setSelectionRange failed:", e.message); }
      }
    }
  }
}

function morphChildren(op, np) {
  let oc = op.firstChild, nc = np.firstChild;
  while (nc) {
    if (!oc) { op.appendChild(nc.cloneNode(true)); trace("morph.append", { key: nodeKey(nc) }); nc = nc.nextSibling; continue; }
    if (sameNode(oc, nc)) { morphNode(oc, nc); oc = oc.nextSibling; nc = nc.nextSibling; continue; }
    const m = findMatch(oc.nextSibling, nc);
    if (m) {
      const targetKey = nodeKey(nc);
      if (targetKey) {
        op.insertBefore(m, oc);
        trace("morph.move", { key: targetKey });
        morphNode(m, nc);
        nc = nc.nextSibling;
        continue;
      }
      while (oc && oc !== m) { const nx = oc.nextSibling; unmountSubtree(oc); op.removeChild(oc); trace("morph.remove", { key: nodeKey(oc) }); oc = nx; }
      if (oc) { morphNode(oc, nc); oc = oc.nextSibling; }
      nc = nc.nextSibling;
      continue;
    }
    op.insertBefore(nc.cloneNode(true), oc); trace("morph.insert", { key: nodeKey(nc) }); nc = nc.nextSibling;
  }
  while (oc) { const nx = oc.nextSibling; unmountSubtree(oc); op.removeChild(oc); trace("morph.remove", { key: nodeKey(oc) }); oc = nx; }
}

function morphNode(o, n) {
  if (o.nodeType === 3) { if (o.textContent !== n.textContent) o.textContent = n.textContent; return; }
  if (o.nodeType !== 1) return;
  morphAttributes(o, n);
  if (preservesChildren(o)) return;
  const isFormControl = o.tagName === "INPUT" || o.tagName === "TEXTAREA" || o.tagName === "SELECT";
  if (isFormControl && o === document.activeElement) {
    if (formControlValuesDiffer(o, n)) syncFormControlState(o, n);
    return;
  }
  morphChildren(o, n);
  if (isFormControl) syncFormControlState(o, n);
}

function preservesChildren(node) {
  if (!node || !node.hasAttribute) return false;
  if (node.hasAttribute("data-beacon-preserve-children")) return true;
  const ignore = node.getAttribute("data-beacon-ignore");
  return ignore === "children" || ignore === "true";
}

function nodeKey(node) {
  if (!node || node.nodeType !== 1) return null;
  return node.getAttribute("data-beacon-key") || node.id || null;
}

function describeNode(node) {
  if (!node || node.nodeType !== 1) return "";
  const id = node.id ? "#" + node.id : "";
  const key = node.getAttribute("data-beacon-key");
  const keyed = key ? `[data-beacon-key="${key}"]` : "";
  return node.tagName.toLowerCase() + id + keyed;
}

function formControlValuesDiffer(o, n) {
  if (o.tagName === "INPUT") {
    const type = (o.getAttribute("type") || "").toLowerCase();
    if (type === "checkbox" || type === "radio") return o.checked !== n.hasAttribute("checked");
    if (type === "file") return false;
    const nextValue = n.hasAttribute("value") ? n.getAttribute("value") : "";
    return o.value !== nextValue;
  }

  if (o.tagName === "TEXTAREA") {
    const nextValue = n.hasAttribute("value") ? n.getAttribute("value") : n.textContent;
    return o.value !== nextValue;
  }

  if (o.tagName === "SELECT") {
    if (o.value !== n.value) return true;
    return Array.from(o.options).some((oOption, i) => n.options[i] && oOption.selected !== n.options[i].selected);
  }

  return false;
}

function morphAttributes(o, n) {
  for (let i = o.attributes.length - 1; i >= 0; i--) if (!n.hasAttribute(o.attributes[i].name)) o.removeAttribute(o.attributes[i].name);
  for (let i = 0; i < n.attributes.length; i++) { const nm = n.attributes[i].name, v = n.attributes[i].value; if (o.getAttribute(nm) !== v) o.setAttribute(nm, v); }
}

function syncFormControlState(o, n) {
  if (o.tagName === "TEXTAREA") {
    const nextValue = n.hasAttribute("value") ? n.getAttribute("value") : n.textContent;
    if (o.value !== nextValue) o.value = nextValue;
    return;
  }

  if (o.tagName === "INPUT") {
    const type = (o.getAttribute("type") || "").toLowerCase();
    if (type === "checkbox" || type === "radio") {
      o.checked = n.hasAttribute("checked");
      return;
    }
    if (type !== "file") {
      const nextValue = n.hasAttribute("value") ? n.getAttribute("value") : "";
      if (o.value !== nextValue) o.value = nextValue;
    }
    return;
  }

  if (o.tagName === "SELECT") {
    for (let i = 0; i < o.options.length && i < n.options.length; i++) {
      o.options[i].selected = n.options[i].selected;
    }
    if (o.value !== n.value) o.value = n.value;
  }
}

function sameNode(a, b) {
  if (a.nodeType !== b.nodeType) return false;
  if (a.nodeType === 3) return true;
  if (a.nodeType !== 1) return false;
  if (a.tagName !== b.tagName) return false;
  const aKey = nodeKey(a);
  const bKey = nodeKey(b);
  if (aKey || bKey) return aKey === bKey;
  if (a.id && b.id) return a.id === b.id;
  return true;
}
function findMatch(s, t) {
  const targetKey = nodeKey(t);
  let c = s, k = 8;
  while (c && k > 0) {
    if (targetKey ? nodeKey(c) === targetKey : sameNode(c, t)) return c;
    c = c.nextSibling;
    k--;
  }
  return null;
}

function syncHooks(root) {
  if (!root || !root.querySelectorAll) return;
  root.querySelectorAll("[data-beacon-hook]").forEach((node) => {
    const hookName = node.getAttribute("data-beacon-hook");
    const hook = hookRegistry.get(hookName);
    if (!hook) return;
    const attrs = serializeHookAttrs(node);
    const existing = mountedHooks.get(node);
    if (!existing) {
      const state = hook.mount ? hook.mount(node) : undefined;
      mountedHooks.set(node, { hookName, hook, attrs, state });
      trace("hook.mount", { hook: hookName, island: node.getAttribute("data-beacon-island") || "" });
      return;
    }
    if (existing.attrs !== attrs && existing.hook.update) {
      existing.hook.update(node, existing.state);
      mountedHooks.set(node, { ...existing, attrs });
      trace("hook.update", { hook: hookName, island: node.getAttribute("data-beacon-island") || "" });
    }
  });
}

function unmountSubtree(node) {
  if (!node) return;
  if (node.querySelectorAll) node.querySelectorAll("[data-beacon-hook]").forEach(unmountHookNode);
  unmountHookNode(node);
}

function unmountHookNode(node) {
  const existing = mountedHooks.get(node);
  if (!existing) return;
  if (existing.hook.unmount) existing.hook.unmount(node, existing.state);
  mountedHooks.delete(node);
  trace("hook.unmount", { hook: existing.hookName });
}

function serializeHookAttrs(node) {
  const watchedAttrs = hookWatchSet(node);
  return Array.from(node.attributes)
    .filter((attr) => shouldIncludeHookAttr(attr.name, watchedAttrs))
    .map((attr) => attr.name + "=" + attr.value)
    .sort()
    .join("|");
}

function hookWatchSet(node) {
  const raw = node.getAttribute("data-beacon-hook-watch");
  if (!raw) return null;
  const names = raw.split(",").map((name) => name.trim()).filter(Boolean);
  return names.length > 0 ? new Set(names) : null;
}

function shouldIncludeHookAttr(name, watchedAttrs) {
  if (name === "data-beacon-preserve-children") return false;
  if (!watchedAttrs) return true;
  return name === "data-beacon-hook"
    || name === "data-beacon-hook-watch"
    || name === "data-beacon-island"
    || watchedAttrs.has(name);
}

// === Event Delegation ===

// Helper: dispatch an event through local handling and/or server.
// Builds the wire message with optional ops for patch-based sync.
function dispatchEvent(eventName, hid, data, tp, forcedClock) {
  const clock = forcedClock ?? ++eventClock;
  const eventPayload = { name: eventName, handler_id: hid, data, target_path: tp, clock };
  if (clientInitialized) {
    const r = handleEventLocally(hid, data, eventName, tp, clock);
    if (r.action === "send") {
      if (r.ops) eventPayload.ops = r.ops;
      const encodedMsg = window.BeaconApp.encode_msg(r.msg);
      eventPayload.data = JSON.stringify({ __beacon_msg: encodedMsg, __beacon_event: data });
      // Paced, never dropped silently. Only a queued event can be acked, so
      // only a queued event may hold back server state while pending.
      if (caseSendEvent(eventPayload) && r.affectsModel) {
        pendingModelEventClock = Math.max(pendingModelEventClock, clock);
      }
    } else if (r.action === "error") {
      console.error("[beacon] Event dropped because generated event decoding is unavailable.");
    }
  } else {
    console.warn("[beacon] Event queued before model_sync; generated event decoding will replay after hydration.");
    enqueueEarlyEvent(eventName, hid, data, tp, clock);
  }
}

function caseSendEvent(eventPayload) {
  return send({ type: "event", ...eventPayload });
}

function dispatchInputEvent(hid, data, tp, debounceMs) {
  const key = hid + "\n" + tp;
  const existing = pendingInputEvents.get(key);
  if (existing) clearTimeout(existing.timer);
  const clock = ++eventClock;
  const pending = {
    hid,
    data,
    tp,
    clock,
    timer: setTimeout(() => {
      pendingInputEvents.delete(key);
      dispatchEvent("input", hid, data, tp, clock);
    }, debounceMs),
  };
  pendingInputEvents.set(key, pending);
}

function flushPendingInputEvents() {
  if (pendingInputEvents.size === 0) return;
  const pending = Array.from(pendingInputEvents.values()).sort((a, b) => a.clock - b.clock);
  pendingInputEvents.clear();
  for (const item of pending) {
    clearTimeout(item.timer);
    dispatchEvent("input", item.hid, item.data, item.tp, item.clock);
  }
}

function hasPendingUnackedInput() {
  return Array.from(pendingInputEvents.values()).some((item) => item.clock > latestAckClock);
}

function getInputDebounceMs(node) {
  const raw = node.getAttribute("data-beacon-input-debounce");
  const parsed = raw ? parseInt(raw, 10) : INPUT_DEBOUNCE_MS;
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : INPUT_DEBOUNCE_MS;
}

function formSnapshot(form) {
  const fields = {};
  const data = new FormData(form);
  for (const [key, value] of data.entries()) {
    if (Object.prototype.hasOwnProperty.call(fields, key)) {
      if (Array.isArray(fields[key])) fields[key].push(String(value));
      else fields[key] = [fields[key], String(value)];
    } else {
      fields[key] = String(value);
    }
  }
  return JSON.stringify({ value: JSON.stringify(fields) });
}

function attachEvents() {
  if (!appRoot) return;
  appRoot.onclick = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-click")) {
        e.preventDefault();
        flushPendingInputEvents();
        dispatchEvent("click", t.getAttribute("data-beacon-event-click"), "{}", getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.oninput = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-input")) {
        const hid = t.getAttribute("data-beacon-event-input");
        const data = JSON.stringify({ value: t.value || "" });
        dispatchInputEvent(hid, data, getPath(t), getInputDebounceMs(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onchange = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-change")) {
        const hid = t.getAttribute("data-beacon-event-change");
        const data = JSON.stringify({ value: t.value || "" });
        flushPendingInputEvents();
        dispatchEvent("change", hid, data, getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onfocusin = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-focus")) {
        dispatchEvent("focus", t.getAttribute("data-beacon-event-focus"), "{}", getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onfocusout = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-blur")) {
        dispatchEvent("blur", t.getAttribute("data-beacon-event-blur"), "{}", getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onsubmit = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-submit")) {
        e.preventDefault();
        flushPendingInputEvents();
        dispatchEvent("submit", t.getAttribute("data-beacon-event-submit"), "{}", getPath(t));
        return;
      }
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-submit-local")) {
        e.preventDefault();
        flushPendingInputEvents();
        dispatchEvent("submit-local", t.getAttribute("data-beacon-event-submit-local"), formSnapshot(t), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmousedown = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mousedown")) {
        const hid = t.getAttribute("data-beacon-event-mousedown");
        const rect = t.getBoundingClientRect();
        const x = Math.round(e.clientX - rect.left);
        const y = Math.round(e.clientY - rect.top);
        t.__beaconPointerTrail = [x + "," + y];
        dispatchEvent("mousedown", hid, JSON.stringify({ value: x + "," + y }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmouseup = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mouseup")) {
        const hid = t.getAttribute("data-beacon-event-mouseup");
        const rect = t.getBoundingClientRect();
        const x = Math.round(e.clientX - rect.left);
        const y = Math.round(e.clientY - rect.top);
        const trail = Array.isArray(t.__beaconPointerTrail) ? t.__beaconPointerTrail : [];
        if (x >= 0 && y >= 0 && x <= Math.round(rect.width) && y <= Math.round(rect.height)) {
          trail.push(x + "," + y);
        }
        const value = trail.length > 0 ? trail.join(";") : x + "," + y;
        delete t.__beaconPointerTrail;
        dispatchEvent("mouseup", hid, JSON.stringify({ value }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmousemove = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mousemove")) {
        const hid = t.getAttribute("data-beacon-event-mousemove");
        const rect = t.getBoundingClientRect();
        const x = Math.round(e.clientX - rect.left);
        const y = Math.round(e.clientY - rect.top);
        if (Array.isArray(t.__beaconPointerTrail)) {
          t.__beaconPointerTrail.push(x + "," + y);
        }
        dispatchEvent("mousemove", hid, JSON.stringify({ value: x + "," + y }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.ondragstart = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-dragstart")) {
        const hid = t.getAttribute("data-beacon-event-dragstart");
        const dragId = t.getAttribute("data-drag-id") || "";
        e.dataTransfer.setData("text/plain", dragId);
        e.dataTransfer.effectAllowed = "move";
        setTimeout(() => { t.style.opacity = "0.4"; }, 0);
        dispatchEvent("dragstart", hid, JSON.stringify({ value: dragId }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.ondragend = (e) => {
    // Reset opacity on all draggable elements
    appRoot.querySelectorAll("[draggable]").forEach(el => { el.style.opacity = "1"; });
  };
  appRoot.ondragover = (e) => {
    // Walk up from target to find a drop zone (has data-beacon-event-drop)
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-drop")) {
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
        t.style.outline = "2px dashed #2196F3";
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.ondragleave = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-drop")) {
        // Only remove highlight if we're leaving the drop zone itself,
        // not when entering a child element
        if (!t.contains(e.relatedTarget)) {
          t.style.outline = "";
        }
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.ondrop = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-drop")) {
        e.preventDefault();
        t.style.outline = "";
        const dragId = e.dataTransfer.getData("text/plain");
        dispatchEvent("drop", t.getAttribute("data-beacon-event-drop"), JSON.stringify({ value: dragId }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onkeydown = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-keydown")) {
        const isTextEntry = t.tagName === "INPUT" || t.tagName === "TEXTAREA";
        const isEnterSubmit = e.key === "Enter" && !e.shiftKey && !e.isComposing;
        if (isTextEntry && !isEnterSubmit) return;
        if (isEnterSubmit) e.preventDefault();
        flushPendingInputEvents();
        dispatchEvent("keydown", t.getAttribute("data-beacon-event-keydown"), JSON.stringify({ value: e.key }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
}

function getPath(node) {
  const parts = []; let c = node;
  while (c && c !== appRoot) { const p = c.parentNode; if (p) { const ch = p.childNodes; for (let i = 0; i < ch.length; i++) if (ch[i] === c) { parts.unshift(i); break; } } c = c.parentNode; }
  return parts.join(".");
}

// === SPA Navigation ===
function setupNavigation() {
  // Intercept internal link clicks for SPA navigation
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a[href]");
    if (!a) return;
    // Only intercept same-origin links without data-beacon-external
    if (a.hostname.toLowerCase() !== location.hostname.toLowerCase()) return;
    if (a.hasAttribute("data-beacon-external")) return;
    if (a.target === "_blank") return;

    e.preventDefault();
    const path = a.pathname + a.search;
    if (path !== location.pathname + location.search) {
      history.pushState(null, "", path);
      resetClientRouteTransientState(path);
      send({ type: "navigate", path: path });
    }
  });

  // Handle browser back/forward
  window.addEventListener("popstate", () => {
    const path = location.pathname + location.search;
    resetClientRouteTransientState(path);
    send({ type: "navigate", path });
  });
}

// === Exports for Gleam FFI ===
export function query_selector(sel) { const el = document.querySelector(sel); return el ? { type: "Ok", 0: el } : { type: "Error", 0: undefined }; }
export function log(msg) { console.log("[beacon]", msg); return undefined; }
export function log_error(msg) { console.error("[beacon]", msg); return undefined; }

// === Auto-boot ===
// When loaded as a script tag, auto-boot: find the app root, set up navigation, connect WS.
// For base builds (no codec), this is the only entry point — initClientAfterBoot is never called.
if (typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => { boot("#beacon-app"); setupNavigation(); });
  else { boot("#beacon-app"); setupNavigation(); }
}

// Called from bundle entry AFTER window.BeaconApp is set
export function initClientAfterBoot() {
  // If boot hasn't run yet (script loaded before DOMContentLoaded),
  // defer initClient to after boot
  if (!appRoot) {
    document.addEventListener("DOMContentLoaded", () => initClient());
  } else {
    initClient();
  }
}
