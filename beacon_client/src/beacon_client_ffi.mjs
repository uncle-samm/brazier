// Beacon client runtime: the only hand-written JavaScript that runs in the
// browser. It owns the WebSocket, event delegation and DOM morphing; the
// app's own code (the generated entry, see beacon/build/client_entry) owns
// rendering, event decoding and the client-side updates.
//
// Startup: the bundle entry calls `start(App)` with the generated entry
// module. `start` checks every export the runtime calls, then boots on
// DOMContentLoaded: it listens for the event names the server-rendered
// markup uses, intercepts same-origin links and connects to
// `/ws?path=<page path>`.
//
// Events: one capture-phase listener on `document` per event name in the
// handler table. A DOM event is matched to the elements carrying
// `data-beacon-on-<name>="<id>"` (innermost first; only the target itself for
// events that do not bubble). Each handler's options apply prevent-default,
// stop-propagation (among Beacon handlers), throttle and debounce; its
// decoder runs against the real event object and yields a Msg. The Msg goes
// through `update_local` (and a `simple` app's `update`), the view is
// re-rendered, and a forwarded Msg is sent to the server as
// `{type: "event", data: encode_msg(msg)}`. A decoder failure is a
// console.warn naming the event, and the event is dropped.
//
// Before the first model_sync there is no handler table: events on elements
// with a `data-beacon-on-*` marker are queued with a snapshot of their common
// fields (prevent-default is applied from the SSR `data-beacon-prevent-*`
// marker) and replayed through the decoders after the first render.
//
// The server is authoritative: model_sync and patch frames replace the
// client's model. A `simple` app predicts the model by running its update in
// the browser; when the server's model differs, the server's wins and the
// mismatch is logged.

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

// === Generated entry ===

// Every export of the generated entry the runtime calls. A `simple` app also
// exports `update`.
const REQUIRED_EXPORTS = [
  "decode_model",
  "init_local",
  "render",
  "lookup_handler",
  "run_handler",
  "handler_options",
  "event_names",
  "update_local",
  "encode_msg",
  "same_model",
  "is_simple",
];

let app = null;
let simple = false;
let started = false;

// === Connection state ===
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
let readyForServerEvents = false;
let syncRequestInFlight = false;
let appRoot = null;
let eventClock = 0;
let currentModelVersion = 0;
// The highest event clock the server has acknowledged on this connection.
let latestAckClock = 0;
// The highest event clock written to the current socket.
let writtenEventClock = 0;
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

// === Client state ===
let clientModel = null;
let clientLocal = null;
let clientInitialized = false;
// Set when the app's client code crashed; events are then dropped loudly.
let clientFailed = false;
// Set when a dispatched message changed the client state since the last
// render; see renderIfDispatched.
let renderPending = false;
// The JSON of the last authoritative model, which patches apply to.
let clientModelJson = null;
// The handler table of the last render (opaque, owned by the entry).
let handlers = null;
// Event names with a document listener.
const listening = new Set();
// A `simple` app's model was predicted by its update and not yet confirmed.
let predicted = false;
// The clock of the latest queued event of a `simple` app; server state that
// does not acknowledge it is held back so the prediction is not undone.
let pendingModelEventClock = 0;

// Pre-hydration events: { name, ids, snapshot }.
const MAX_PENDING_EARLY_EVENTS = 50;
let pendingEarlyEvents = [];

// Debounced messages by "name:id": { name, id, msg, seq, timer }.
const debounced = new Map();
let debounceSeq = 0;
// Time of the last dispatched throttled event by "name:id".
const throttled = new Map();

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
    try {
      performance.measure("beacon:" + name, "beacon:" + start, "beacon:" + end);
    } catch (e) {
      console.warn("[beacon] performance.measure(" + name + ") failed:", e && e.message);
    }
  }
}

function ensureBeaconDebug() {
  window.__beacon = window.__beacon || {};
  window.__beacon.trace = () => traceBuffer.slice();
}

function ensureHookRegistry() {
  window.beaconClient = window.beaconClient || {};
  window.beaconClient.registerHook = (name, hook) => {
    hookRegistry.set(name, hook);
    trace("hook.register", { name });
  };
}

// === Startup ===

// Start the runtime with the generated entry module. Called once by the
// bundle entry. A bundle without a complete entry is not interactive: the
// runtime reports it and does not connect.
export function start(entry) {
  if (started) {
    throw new Error("[beacon] invariant violated: start called twice");
  }
  const missing = missingExports(entry);
  if (missing.length > 0) {
    console.error(
      "[beacon] This page is not interactive: the client bundle has no generated app" +
        (entry ? " (missing exports: " + missing.join(", ") + ")" : "") +
        ". Build it with `gleam run -m beacon/build`.",
    );
    return undefined;
  }
  started = true;
  app = entry;
  simple = app.is_simple() === true;
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot, { once: true });
  } else {
    boot();
  }
  return undefined;
}

function missingExports(entry) {
  if (!entry) return REQUIRED_EXPORTS.slice();
  const missing = REQUIRED_EXPORTS.filter((name) => typeof entry[name] !== "function");
  if (missing.length === 0 && entry.is_simple() === true && typeof entry.update !== "function") {
    missing.push("update");
  }
  return missing;
}

function boot() {
  const root = document.querySelector("#beacon-app");
  if (!root) {
    console.error("[beacon] No #beacon-app element on the page; the client runtime cannot start");
    return;
  }
  mark("boot");
  ensureBeaconDebug();
  ensureHookRegistry();
  setAppRoot(root);
  // Until the first render there is no handler table: listen for the events
  // the server-rendered markup names, so they can be queued and replayed.
  listenFor(markupEventNames(root));
  setupNavigation();
  connect();
}

function setAppRoot(root) {
  const previousRoot = appRoot;
  appRoot = root;
  if (!previousRoot) {
    trace("root.init", { root: describeNode(root) });
    return;
  }
  if (previousRoot === root) return;
  trace("root.replace", { from: describeNode(previousRoot), to: describeNode(root) });
  unmountSubtree(previousRoot);
}

// The event names of every `data-beacon-on-<name>` attribute under root.
function markupEventNames(root) {
  const prefix = "data-beacon-on-";
  const names = new Set();
  for (const node of root.querySelectorAll("*")) {
    for (const attr of Array.from(node.attributes)) {
      if (attr.name.startsWith(prefix)) names.add(attr.name.slice(prefix.length));
    }
  }
  return Array.from(names);
}

// === Rendering ===

function renderNow() {
  renderPending = false;
  if (!clientInitialized || !appRoot) return;
  mark("render-start");
  const t0 = performance.now();
  const rendered = app.render(clientModel, clientLocal);
  const html = rendered[0];
  const table = rendered[1];
  const t1 = performance.now();
  morphInnerHTML(appRoot, html);
  handlers = table;
  listenFor(app.event_names(table).toArray());
  const t2 = performance.now();
  const total = t2 - t0;
  if (total > 5) {
    console.log(
      "[beacon] Slow render: view=" + (t1 - t0).toFixed(1) + "ms morph=" + (t2 - t1).toFixed(1) +
        "ms total=" + total.toFixed(1) + "ms",
    );
  }
  window._lastRenderMs = total;
  mark("render-end");
  measure("render", "render-start", "render-end");
}

// Every entry point that dispatches messages (a DOM event, a replayed early
// event, a debounce timer, a route change) renders once when it is done, as
// Lustre does for user events. Handlers are closures over the state of the
// render that produced them, so the next event must find the handlers of the
// state the previous one left, and a focused input must be rendered with the
// value it was just given before the user types again. Waiting for an
// animation frame broke both: frames do not run in a background tab, and an
// event inside the same frame ran a stale handler.
function renderIfDispatched() {
  if (renderPending) renderNow();
}

// Invariant: no entry point leaves a dispatched message unrendered.
function assertRendered(where) {
  if (renderPending) {
    throw new Error("[beacon] invariant violated: a dispatched message was not rendered before " + where);
  }
}

// === Event delegation ===

function listenFor(names) {
  for (const name of names) {
    if (listening.has(name)) continue;
    listening.add(name);
    document.addEventListener(name, onDomEvent, true);
    trace("listen", { name });
  }
}

// The elements from the event target outwards that have a handler for
// `name`, innermost first, as { el, id }. An event that does not bubble only
// reaches its own target.
function handlerTargets(name, target, bubbles) {
  const attr = "data-beacon-on-" + name;
  const found = [];
  let node = target && target.nodeType !== 1 ? target.parentNode : target;
  while (node && node !== appRoot) {
    if (node.nodeType === 1 && node.hasAttribute(attr)) {
      found.push({ el: node, id: node.getAttribute(attr) });
    }
    if (!bubbles) break;
    node = node.parentNode;
  }
  return found;
}

function onDomEvent(event) {
  const target = event.target;
  if (!appRoot || !target || target === appRoot || !appRoot.contains(target)) return;
  const name = event.type;
  const found = handlerTargets(name, target, event.bubbles);
  if (found.length === 0) return;
  if (!clientInitialized) {
    enqueueEarlyEvent(name, event, found);
    return;
  }
  assertRendered("a " + name + " event");
  runHandlers(name, event, found.map((f) => f.id), event, false);
  renderIfDispatched();
}

// Run the handlers for `ids` (innermost first) against `payload`: the DOM
// event, or a snapshot of it when `replay` is true. `domEvent` is the live
// event prevent-default applies to, or null on replay.
function runHandlers(name, payload, ids, domEvent, replay) {
  if (clientFailed) {
    console.error("[beacon] " + name + " event dropped: the client stopped after an earlier crash. Reload the page.");
    return;
  }
  for (const id of ids) {
    const looked = app.lookup_handler(handlers, name, id);
    if (!looked.isOk()) {
      if (replay) {
        console.warn("[beacon] " + name + " event on element " + id + " from before hydration dropped: the rendered page has no such handler");
      } else {
        console.error("[beacon] No " + name + " handler for element " + id + " in the last render; the page and its handler table disagree");
      }
      continue;
    }
    const handler = looked[0];
    const options = app.handler_options(handler);
    const preventDefault = options[0] === true;
    const stopPropagation = options[1] === true;
    const debounceMs = options[2];
    const throttleMs = options[3];
    if (preventDefault && domEvent) domEvent.preventDefault();
    if (name === "submit" && domEvent) attachFormData(domEvent);
    const key = name + ":" + id;
    if (throttleMs > 0) {
      const now = performance.now();
      const last = throttled.get(key);
      if (last !== undefined && now - last < throttleMs) {
        trace("event.throttled", { name, id });
        if (stopPropagation) return;
        continue;
      }
    }
    const decoded = app.run_handler(handler, payload);
    if (!decoded.isOk()) {
      console.warn("[beacon] " + name + " event on element " + id + " dropped: its decoder failed: " + String(decoded[0]));
    } else {
      if (throttleMs > 0) throttled.set(key, performance.now());
      if (debounceMs > 0) {
        scheduleDebounced(name, id, decoded[0], debounceMs);
      } else {
        flushDebounced();
        dispatchMsg(name, id, decoded[0]);
      }
    }
    if (stopPropagation) return;
  }
}

// Submit events carry the form's fields as `detail.formData`, a list of
// [name, value] pairs, for `event.on_submit` to decode.
function attachFormData(event) {
  if (event.detail && Array.isArray(event.detail.formData)) return;
  const form = event.target;
  const entries = Array.from(new FormData(form, event.submitter || null).entries());
  if (event.detail && typeof event.detail === "object") {
    event.detail.formData = entries;
  } else {
    Object.defineProperty(event, "detail", { value: { formData: entries }, configurable: true });
  }
}

function scheduleDebounced(name, id, msg, ms) {
  const key = name + ":" + id;
  const existing = debounced.get(key);
  if (existing) clearTimeout(existing.timer);
  const entry = { name, id, msg, seq: ++debounceSeq, timer: null };
  entry.timer = setTimeout(() => {
    debounced.delete(key);
    assertRendered("a debounced " + name + " message");
    dispatchMsg(name, id, msg);
    renderIfDispatched();
  }, ms);
  debounced.set(key, entry);
  trace("event.debounced", { name, id, ms });
}

// Dispatch every debounced message now, in the order they were scheduled.
function flushDebounced() {
  if (debounced.size === 0) return;
  const entries = Array.from(debounced.values()).sort((a, b) => a.seq - b.seq);
  debounced.clear();
  for (const entry of entries) {
    clearTimeout(entry.timer);
    dispatchMsg(entry.name, entry.id, entry.msg);
  }
  trace("event.debounce_flush", { count: entries.length });
}

// Apply a decoded Msg in the browser and forward it to the server unless the
// Local layer handled it.
function dispatchMsg(name, id, msg) {
  if (clientFailed) {
    console.error("[beacon] " + name + " event dropped: the client stopped after an earlier crash. Reload the page.");
    return;
  }
  let forward;
  try {
    const result = app.update_local(clientModel, clientLocal, msg);
    clientLocal = result[0];
    forward = result[1] === true;
    if (simple) {
      clientModel = app.update(clientModel, msg);
      predicted = true;
    }
  } catch (e) {
    clientFailed = true;
    console.error("[beacon] The app's client update crashed on a " + name + " event (element " + id + "); the client stops handling events. Reload the page.", e);
    return;
  }
  // The entry point that dispatched this renders once it is done.
  renderPending = true;
  if (!forward) {
    trace("event.local", { name, id });
    return;
  }
  const clock = ++eventClock;
  const queued = send({
    type: "event",
    name,
    handler_id: id,
    data: app.encode_msg(msg),
    target_path: id,
    clock,
  });
  // Only a queued event can be acknowledged, so only a queued event may hold
  // back server state while it is pending.
  if (queued && simple) pendingModelEventClock = Math.max(pendingModelEventClock, clock);
}

// === Pre-hydration events ===

function enqueueEarlyEvent(name, event, found) {
  if (found.some((f) => f.el.hasAttribute("data-beacon-prevent-" + name))) event.preventDefault();
  if (pendingEarlyEvents.length >= MAX_PENDING_EARLY_EVENTS) {
    console.error("[beacon] Early event queue full (" + MAX_PENDING_EARLY_EVENTS + "); " + name + " before the first model_sync was dropped");
    trace("early_event.full", { name });
    return;
  }
  pendingEarlyEvents.push({ name, ids: found.map((f) => f.id), snapshot: snapshotEvent(event) });
  trace("early_event.enqueue", { name, size: pendingEarlyEvents.length });
}

// The fields decoders commonly read, copied while the event is live.
function snapshotEvent(event) {
  const snapshot = { type: event.type, bubbles: event.bubbles };
  for (const field of [
    "key", "code", "shiftKey", "ctrlKey", "altKey", "metaKey", "isComposing", "repeat",
    "button", "buttons", "clientX", "clientY", "offsetX", "offsetY", "pageX", "pageY",
  ]) {
    if (event[field] !== undefined) snapshot[field] = event[field];
  }
  const target = event.target;
  if (target) snapshot.target = { value: target.value, checked: target.checked };
  if (event.type === "submit" && target) {
    snapshot.detail = { formData: Array.from(new FormData(target, event.submitter || null).entries()) };
  }
  return snapshot;
}

function flushPendingEarlyEvents() {
  if (!clientInitialized || pendingEarlyEvents.length === 0) return;
  const queued = pendingEarlyEvents;
  pendingEarlyEvents = [];
  for (const entry of queued) {
    runHandlers(entry.name, entry.snapshot, entry.ids, null, true);
    // The next replayed event runs the handlers of the state this one left.
    renderIfDispatched();
  }
  console.log("[beacon] Replayed " + queued.length + " event(s) from before hydration");
  trace("early_event.flush", { count: queued.length });
}

// === Server state ===

function hasPendingModelEvent() {
  return pendingModelEventClock > latestAckClock;
}

// Server state that does not acknowledge a pending `simple` event is cached
// but not rendered, so it cannot undo the prediction. The ack that covers the
// event adopts the cached model (and checks the prediction against it).
function shouldHoldServerState(ackClock, kind, version) {
  if (hasPendingModelEvent() && ackClock < pendingModelEventClock) {
    trace(kind + ".held_for_pending_event", { version, ackClock, pendingModelEventClock });
    return true;
  }
  return false;
}

// The highest clock among queued events, 0 when none is queued.
function queuedEventClock() {
  let max = 0;
  for (const msg of outbound.messages()) {
    if (msg.type === "event") max = Math.max(max, msg.clock);
    else if (msg.type === "event_batch") for (const e of msg.events) max = Math.max(max, e.clock || 0);
  }
  return max;
}

function markServerAckApplied(ackClock) {
  latestAckClock = Math.max(latestAckClock, ackClock);
  if (latestAckClock >= pendingModelEventClock) pendingModelEventClock = 0;
}

// Whether a focused form control keeps the value the user is typing: while a
// debounced message is pending or a sent event is not yet acknowledged, a
// render must not overwrite it with a value the server computed earlier.
function inputLocked() {
  return debounced.size > 0
    || writtenEventClock > latestAckClock
    || outbound.some((msg) => msg.type === "event" || msg.type === "event_batch");
}

// Decode an authoritative model and render it. Returns null on success or
// the reason it failed. Throws if the app's code throws.
function adoptAuthoritativeModel(modelStr) {
  const result = app.decode_model(modelStr);
  if (!result.isOk()) return "decode_model failed: " + String(result[0]);
  const model = result[0];
  if (predicted) {
    predicted = false;
    if (!app.same_model(clientModel, model)) {
      console.warn("[beacon] The browser's update predicted a different model than the server's; the server's model wins. Check that update is pure and deterministic.");
      trace("model.mismatch");
    }
  }
  clientModel = model;
  if (!clientInitialized) {
    clientLocal = app.init_local(model);
    clientInitialized = true;
    console.log("[beacon] Client ready (from model_sync)");
  }
  renderNow();
  return null;
}

// === WebSocket ===

function socketUrl() {
  const scheme = location.protocol === "https:" ? "wss://" : "ws://";
  return scheme + location.host + "/ws?path=" + encodeURIComponent(location.pathname + location.search);
}

function connect() {
  if (reconnectStopped) {
    console.error("[beacon] Not connecting: the session was revoked (close 4401). Reload to sign in again.");
    return;
  }
  // Events sent on the old socket are never acknowledged on this one, so
  // only a still-queued event of a `simple` app keeps holding server state.
  const queuedClock = simple ? queuedEventClock() : 0;
  if (hasPendingModelEvent() && queuedClock < pendingModelEventClock) {
    console.warn("[beacon] Events sent before the disconnect were not acknowledged; the new connection's model replaces their prediction");
    trace("reconnect.unacked_prediction", { pendingModelEventClock, latestAckClock, queuedClock });
  }
  pendingModelEventClock = queuedClock;
  predicted = queuedClock > 0;
  readyForServerEvents = false;
  socketJoined = false;
  modelSynced = false;
  currentModelVersion = 0;
  latestAckClock = 0;
  writtenEventClock = 0;
  syncRequestInFlight = false;
  syncGaveUp = false;
  consecutiveModelSyncFailures = 0;
  // The server counts its rate limit per connection, so a new socket starts
  // with a fresh budget. A queued request_sync is superseded by the join's
  // model_sync.
  outbound.setBudget(new SendBudget(CLIENT_SEND_BUDGET, CLIENT_SEND_WINDOW_MS));
  const purged = outbound.removeWhere((msg) => msg.type === "request_sync");
  if (purged > 0) trace("send_queue.purge_request_sync", { purged });
  const socket = new WebSocket(socketUrl());
  ws = socket;
  socket.onopen = () => {
    mark("ws-open");
    startHeartbeat(socket);
    sendJoin(socket);
  };
  socket.onmessage = (e) => handleMessage(e.data);
  socket.onclose = (e) => handleClose(socket, e);
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

function handleClose(socket, e) {
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
  scheduleReconnect();
}

// Write one message to the socket. Returns false when it was not written.
function writeSocket(socket, msg) {
  if (socket !== ws || socket.readyState !== WebSocket.OPEN) return false;
  try {
    socket.send(JSON.stringify(msg));
  } catch (e) {
    console.error("[beacon] WS send failed for " + msg.type + "; it stays queued:", e);
    return false;
  }
  if (msg.type === "event") {
    writtenEventClock = Math.max(writtenEventClock, msg.clock);
  } else if (msg.type === "event_batch") {
    for (const event of msg.events) writtenEventClock = Math.max(writtenEventClock, event.clock || 0);
  }
  return true;
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
// the first model_sync so it is processed against a known model.
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

// Debug: expose WS state for browser tests.
if (typeof window !== "undefined") {
  window.__beaconWsState = () => (ws ? ws.readyState : -1);
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

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
}

function scheduleReconnect() {
  const delay = reconnectDelayMs(reconnectAttempts, Math.random());
  reconnectAttempts++;
  console.log("[beacon] Reconnect attempt " + reconnectAttempts + " in " + delay + "ms");
  setTimeout(connect, delay);
}

// Test seam: queue a raw client message (JSON) as the runtime would.
export function ws_send(data) {
  const msg = JSON.parse(data);
  if (msg.type === "event_batch") {
    for (const batch of splitEventBatch(msg, CLIENT_SEND_BUDGET)) send(batch);
  } else {
    send(msg);
  }
  return undefined;
}

// === Server messages ===

function handleMessage(raw) {
  let msg;
  // A frame that is not JSON cannot be processed. It may have been a patch,
  // so the cached model can no longer be trusted: log it and resync.
  try {
    msg = JSON.parse(raw);
  } catch (e) {
    console.error("[beacon] Failed to parse server message:", e.message, String(raw).substring(0, 100));
    requestFullSync("unparseable_server_message");
    return;
  }
  switch (msg.type) {
    case "model_sync": handleModelSync(msg.model, msg.version, msg.ack_clock || 0); break;
    case "patch": handlePatch(msg.ops, msg.version, msg.ack_clock || 0); break;
    case "navigate": handleServerNavigate(msg.path, msg.replace === true); break;
    case "hard_navigate": handleServerHardNavigate(msg.path); break;
    case "reload": console.log("[beacon] Hot reload: refreshing"); location.reload(); break;
    case "heartbeat_ack": break;
    case "error": handleServerError(msg.reason); break;
    case "mount": console.error("[beacon] Server sent a mount frame, which this client does not support; ignored"); break;
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

function invalidateModelCache() {
  clientModelJson = null;
  modelSynced = false;
}

function handleModelSync(modelJson, version, ackClock) {
  // Any model_sync answers an outstanding request_sync, applied or not.
  syncRequestInFlight = false;
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
  // A held model_sync is cached like a held patch; the connection is still
  // synced, so queued events flow and the ack that covers them adopts it.
  const held = shouldHoldServerState(ackClock, "model_sync", version);
  if (held && !clientInitialized) {
    throw new Error("[beacon] invariant violated: a simple event is pending before the client was initialized");
  }
  let parsed;
  try {
    parsed = JSON.parse(modelJson);
    if (!held) {
      markServerAckApplied(ackClock);
      const failure = adoptAuthoritativeModel(modelJson);
      if (failure !== null) {
        modelSyncFailed(version, failure);
        return;
      }
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
      handleAckPatch(version, ackClock);
      return;
    case "apply":
      break;
    default:
      throw new Error("[beacon] invariant violated: unknown patch verdict " + verdict);
  }

  let newModelJson;
  try {
    // applyOps never mutates its input, so a failure leaves the cache intact
    // until it is invalidated below.
    newModelJson = applyOps(clientModelJson, ops);
  } catch (e) {
    console.error("[beacon] Patch apply failed:", e);
    invalidateModelCache();
    requestFullSync("patch_apply_failed");
    return;
  }
  // A held patch still advances the cached authoritative model, so the
  // next patch builds on it; only adopting and rendering it waits.
  if (shouldHoldServerState(ackClock, "patch", version)) {
    clientModelJson = newModelJson;
    currentModelVersion = version;
    return;
  }
  try {
    markServerAckApplied(ackClock);
    const failure = adoptAuthoritativeModel(JSON.stringify(newModelJson));
    if (failure !== null) {
      console.error("[beacon] Patch v" + version + " produced a model the client cannot decode (" + failure + "); requesting full sync");
      invalidateModelCache();
      requestFullSync("patch_decode_failed");
      return;
    }
  } catch (e) {
    console.error("[beacon] Rendering patch v" + version + " failed:", e);
    invalidateModelCache();
    requestFullSync("patch_render_failed");
    return;
  }
  clientModelJson = newModelJson;
  currentModelVersion = version;
  console.log("[beacon] Patch applied v" + version + " (" + ops.length + " ops)");
  trace("patch", { version, ackClock, ops: ops.length });
  mark("patch-end");
  measure("patch", "patch-start", "patch-end");
}

// An empty patch at the cached revision: the server processed events up to
// ackClock without changing the client-visible model. When that covers the
// pending event of a `simple` app, its prediction is checked against the
// cached authoritative model, which then replaces it. Other apps re-render
// so a focused input released by the ack shows the server's value.
function handleAckPatch(version, ackClock) {
  const wasPending = hasPendingModelEvent();
  const wasLocked = inputLocked();
  markServerAckApplied(ackClock);
  trace("patch.ack", { version, ackClock });
  if (hasPendingModelEvent()) return;
  if (!wasPending && !(wasLocked && !inputLocked())) return;
  try {
    const failure = adoptAuthoritativeModel(JSON.stringify(clientModelJson));
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

// === Navigation ===

function currentPath() {
  return location.pathname + location.search;
}

function isLocalPath(path) {
  return typeof path === "string" && path.startsWith("/") && !path.startsWith("//");
}

// A route change sends what the old page still owes the server (debounced
// messages) before the navigate message, and resets throttling.
function leaveRoute(path) {
  flushDebounced();
  renderIfDispatched();
  throttled.clear();
  trace("route.leave", { path });
}

// The server's router.push / router.replace: change the URL, then tell the
// server so its on_change runs, as for a link click.
function handleServerNavigate(path, replace) {
  if (!isLocalPath(path)) {
    console.error("[beacon] Server navigate rejected: not a local path:", path);
    return;
  }
  if (path === currentPath()) {
    trace("navigate.same_path", { path });
    return;
  }
  leaveRoute(path);
  if (replace) history.replaceState(null, "", path);
  else history.pushState(null, "", path);
  send({ type: "navigate", path });
}

// Hard navigation: a full page load, e.g. to receive Set-Cookie headers.
function handleServerHardNavigate(path) {
  // SECURITY: only same-origin paths, never //host, absolute, javascript: or
  // data: URLs, so the server cannot be turned into an open redirect.
  if (!isLocalPath(path)) {
    console.error("[beacon] Hard navigate rejected: not a local path:", path);
    return;
  }
  window.location.href = path;
}

function setupNavigation() {
  // Same-origin links navigate without a page load.
  document.addEventListener("click", (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (!a) return;
    if (a.hostname.toLowerCase() !== location.hostname.toLowerCase()) return;
    if (a.hasAttribute("data-beacon-external") || a.hasAttribute("download")) return;
    if (a.target && a.target !== "_self") return;
    e.preventDefault();
    const path = a.pathname + a.search;
    if (path === currentPath()) return;
    leaveRoute(path);
    history.pushState(null, "", path);
    send({ type: "navigate", path });
  });
  // Back and forward.
  window.addEventListener("popstate", () => {
    const path = currentPath();
    leaveRoute(path);
    send({ type: "navigate", path });
  });
}

// === DOM morphing ===

function morphInnerHTML(container, html) {
  // Focus and selection, to restore if the focused control is replaced.
  const focused = document.activeElement;
  const focusedTag = focused ? focused.tagName : undefined;
  const focusedName = focused && focused.getAttribute ? focused.getAttribute("name") : null;
  const selStart = focused ? focused.selectionStart : undefined;
  const selEnd = focused ? focused.selectionEnd : undefined;
  const focusedValue = focused ? focused.value : undefined;
  const locked = inputLocked();

  const t = document.createElement("template");
  t.innerHTML = html;
  morphChildren(container, t.content);
  syncHooks(container);
  trace("morph", { childCount: container.childNodes.length });

  if (focusedTag !== "INPUT" && focusedTag !== "TEXTAREA" && focusedTag !== "SELECT") return;
  if (container.contains(focused) || !focusedName) return;
  // The focused control was replaced: focus its successor by name.
  // SECURITY: CSS.escape keeps the attribute value out of the selector syntax.
  const restored = container.querySelector(`[name="${CSS.escape(focusedName)}"]`);
  if (!restored) return;
  restored.focus();
  if (locked && focusedValue !== undefined && restored.value !== focusedValue) restored.value = focusedValue;
  if (typeof selStart === "number" && restored.setSelectionRange) {
    try {
      restored.setSelectionRange(selStart, selEnd);
    } catch (e) {
      console.warn("[beacon] setSelectionRange failed:", e.message);
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
  if (o.hasAttribute("data-beacon-preserve-children")) return;
  const isFormControl = o.tagName === "INPUT" || o.tagName === "TEXTAREA" || o.tagName === "SELECT";
  if (isFormControl && o === document.activeElement) {
    // The user is typing here: keep their value while it is not yet
    // reflected by the server (LiveView's rule for focused inputs).
    if (inputLocked()) {
      trace("morph.focused_input_kept", { name: o.getAttribute("name") || "" });
      return;
    }
    if (formControlValuesDiffer(o, n)) syncFormControlState(o, n);
    return;
  }
  morphChildren(o, n);
  if (isFormControl) syncFormControlState(o, n);
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

// === Hooks ===

function syncHooks(root) {
  root.querySelectorAll("[data-beacon-hook]").forEach((node) => {
    const hookName = node.getAttribute("data-beacon-hook");
    const hook = hookRegistry.get(hookName);
    if (!hook) {
      trace("hook.unregistered", { hook: hookName });
      return;
    }
    const attrs = serializeHookAttrs(node);
    const existing = mountedHooks.get(node);
    if (!existing) {
      const state = hook.mount ? hook.mount(node) : undefined;
      mountedHooks.set(node, { hookName, hook, attrs, state });
      trace("hook.mount", { hook: hookName });
      return;
    }
    if (existing.attrs !== attrs && existing.hook.update) {
      existing.hook.update(node, existing.state);
      mountedHooks.set(node, { ...existing, attrs });
      trace("hook.update", { hook: hookName });
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
  return name === "data-beacon-hook" || name === "data-beacon-hook-watch" || watchedAttrs.has(name);
}
