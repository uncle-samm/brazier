// Brazier client runtime: the only hand-written JavaScript that runs in the
// browser. It owns the WebSocket, event delegation and DOM morphing; the
// app's own code (the generated entry, see brazier/build/client_entry) owns
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
// `data-brazier-on-<name>="<id>"` (innermost first; only the target itself for
// events that do not bubble). Each handler's options apply prevent-default,
// stop-propagation (among Brazier handlers), throttle and debounce; its
// decoder runs against the real event object and yields a Msg. The Msg goes
// through `update_local` (and a `simple` app's `update`), the view is
// re-rendered, and a forwarded Msg is sent to the server as
// `{type: "event", data: encode_msg(msg)}`. A decoder failure is a
// console.warn naming the event, and the event is dropped.
//
// Before the first model_sync there is no handler table: events on elements
// with a `data-brazier-on-*` marker are queued with a snapshot of their common
// fields (prevent-default is applied from the SSR `data-brazier-prevent-*`
// marker) and replayed through the decoders after the first render.
//
// The server is authoritative: model_sync and patch frames replace the
// client's model. A `simple` app predicts the model by running its update in
// the browser; when the server's model differs, the server's wins and the
// mismatch is logged.
//
// Streams (docs/design/STREAMS.md, the "=== Streams ===" section below):
// every patch and model_sync carries a required `streams` array, applied to
// the stream stores before the frame's model part. A stream's items are not
// in the model; each rendered container follows its store, item by item,
// and a frame that does not fit a store closes the socket with 4000
// `stream fault` to reconnect and refill the stores.

import {
  applyOps,
  buildIdFromScriptSrc,
  classifyModelSync,
  classifyPatch,
  closeAction,
  heartbeatAllowed,
  isWireClock,
  localPathRefusal,
  messageCost,
  PacedQueue,
  parseReloadHistory,
  reconnectDelayMs,
  reloadDecision,
  SendBudget,
  splitEventBatch,
  CLIENT_SEND_BUDGET,
  CLIENT_SEND_WINDOW_MS,
  MAX_RELOADS,
  RELOAD_HISTORY_KEY,
  RELOAD_WINDOW_MS,
} from "./brazier_client/patch.mjs";
import { applyEntry, decodeStreams, stepCounts } from "./brazier_client/stream.mjs";

// === Generated entry ===

// Every export of the generated entry the runtime calls. A `simple` app also
// exports `update`. `render` returns #(html, handlers, containers); the
// container_* exports read a stream container of that list, render_item
// renders one item of it, and stream_names lists the declared streams
// (docs/design/STREAMS.md 8).
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
  "stream_names",
  "container_name",
  "container_keep",
  "container_limit",
  "container_item",
  "render_item",
];

let app = null;
let simple = false;
let started = false;

// The build id of this bundle: the content hash in the URL of the script
// that is evaluating now (`/brazier_client_<hash>.js`). document.currentScript
// is only set while a classic script runs, so it is read here, at evaluation.
// The join carries it, and a server whose bundle is another one refuses the
// join with CLOSE_STALE_BUILD (4499), which reloads the page. Null when the
// page loaded the bundle from another URL, such as the stable
// /brazier_client.js; the join then carries no build and is not checked.
const BUILD_ID =
  typeof document !== "undefined" && document.currentScript
    ? buildIdFromScriptSrc(document.currentScript.src)
    : null;

// === Connection state ===
let ws = null;
let heartbeatTimer = null;
let lastHeartbeatAt = null;
const HEARTBEAT_INTERVAL_MS = 30000;
let reconnectAttempts = 0;
// Consecutive sockets that closed without ever opening. A browser does not
// expose the HTTP status of a refused upgrade, so an upgrade the server or
// its middleware answered with an HTTP response (upgrade result
// rejected_middleware, rejected_origin, ...) looks like a network failure:
// close 1006 without onopen. Retrying continues with capped backoff, as
// Phoenix's socket does; from UNOPENED_CLOSES_BEFORE_ERROR on, each retry
// is logged as an error naming both causes, so a refused page is not
// mistaken for a flaky network.
let unopenedCloses = 0;
let socketOpened = false;
const UNOPENED_CLOSES_BEFORE_ERROR = 3;
// Set on close codes 4400 to 4499: the server refused this page's session,
// so never reconnect with it (the page reloads or shows an error state).
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
// Events and navigations take their clocks from this one counter, so an ack
// orders them: an ack_clock of a navigation's clock or more is a frame the
// server sent after it handled that navigation.
let eventClock = 0;
let currentModelVersion = 0;
// The highest event or navigation clock the server has acknowledged on this
// connection.
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

// Pre-hydration events: { name, targets, snapshot }.
const MAX_PENDING_EARLY_EVENTS = 50;
let pendingEarlyEvents = [];

// Debounced messages by handlerKey: { name, id, msg, seq, timer }.
const debounced = new Map();
let debounceSeq = 0;
// Time of the last dispatched throttled event by handlerKey.
const throttled = new Map();

// Whether the app root carries data-brazier-dev="true". The server renders
// the attribute on the root, which no morph touches, so it is read once when
// the root is set. Callers whose trace detail costs anything to build (a
// node description, a key lookup, work inside a per-node loop) check it
// before building the detail; trace checks it again for the rest.
let devMode = false;

// The dev build this page was rendered under: data-brazier-dev-build on the
// app root, which the server renders under `brazier/dev` (a new id after
// every rebuild). Read once at boot, since it names this document, and sent
// with every join. A page that was between sockets when a rebuild's `reload`
// was broadcast is told to reload by its next join instead. Null outside
// dev mode; the join then carries none.
let pageDevBuild = null;

function trace(kind, detail = {}) {
  if (!devMode) return;
  traceBuffer.push({ ts: Date.now(), kind, ...detail });
  if (traceBuffer.length > TRACE_LIMIT) traceBuffer.shift();
}

function mark(name) {
  if (typeof performance !== "undefined" && performance.mark) {
    performance.mark("brazier:" + name);
  }
}

function measure(name, start, end) {
  if (typeof performance !== "undefined" && performance.measure) {
    try {
      performance.measure("brazier:" + name, "brazier:" + start, "brazier:" + end);
    } catch (e) {
      console.warn("[brazier] performance.measure(" + name + ") failed:", e && e.message);
    }
  }
}

function ensureBrazierDebug() {
  window.__brazier = window.__brazier || {};
  window.__brazier.trace = () => traceBuffer.slice();
}

function ensureHookRegistry() {
  window.brazierClient = window.brazierClient || {};
  window.brazierClient.registerHook = (name, hook) => {
    hookRegistry.set(name, hook);
    // Elements already on the page may name this hook: the next sync scans
    // the whole root, not only what its morph touched.
    hooksNeedFullScan = true;
    trace("hook.register", { name });
  };
}

// === Startup ===

// Start the runtime with the generated entry module. Called once by the
// bundle entry. A bundle without a complete entry is not interactive: the
// runtime reports it and does not connect.
export function start(entry) {
  if (started) {
    throw new Error("[brazier] invariant violated: start called twice");
  }
  const missing = missingExports(entry);
  if (missing.length > 0) {
    console.error(
      "[brazier] This page is not interactive: the client bundle has no generated app" +
        (entry ? " (missing exports: " + missing.join(", ") + ")" : "") +
        ". Build it with `gleam run -m brazier/build`.",
    );
    return undefined;
  }
  started = true;
  app = entry;
  simple = app.is_simple() === true;
  declaredStreams = declaredStreamNames(app.stream_names());
  if (BUILD_ID === null) {
    console.warn(
      "[brazier] This page did not load the client from /brazier_client_<hash>.js, so its join carries no build id " +
        "and a page left open across a rebuild is not reloaded. Load the script the server renders.",
    );
  }
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
  const root = document.querySelector("#brazier-app");
  if (!root) {
    console.error("[brazier] No #brazier-app element on the page; the client runtime cannot start");
    return;
  }
  mark("boot");
  ensureBrazierDebug();
  ensureHookRegistry();
  setAppRoot(root);
  pageDevBuild = root.getAttribute("data-brazier-dev-build");
  // Until the first render there is no handler table: listen for the events
  // the server-rendered markup names, so they can be queued and replayed.
  listenFor(markupEventNames(root));
  setupNavigation();
  if (window.__BRAZIER_ENABLE_TEST_HOOKS === true && window.__BRAZIER_HOLD_CONNECT_FOR_TEST === true) {
    // Test seam: the page stays server-rendered, with its events queued for
    // replay, until the test releases the first connect (a slow network's
    // join, without timing).
    console.log("[brazier] Test hook: the first connect waits for __brazierReleaseConnectForTest()");
    window.__brazierReleaseConnectForTest = () => {
      if (ws !== null) {
        throw new Error("[brazier] invariant violated: __brazierReleaseConnectForTest called after the client connected");
      }
      connect();
      return ws.readyState;
    };
    return;
  }
  connect();
}

function setAppRoot(root) {
  const previousRoot = appRoot;
  appRoot = root;
  devMode = root.getAttribute("data-brazier-dev") === "true";
  if (!previousRoot) {
    if (devMode) trace("root.init", { root: describeNode(root) });
    return;
  }
  if (previousRoot === root) return;
  if (devMode) trace("root.replace", { from: describeNode(previousRoot), to: describeNode(root) });
  unmountSubtree(previousRoot);
}

// The event names of every `data-brazier-on-<name>` attribute under root.
function markupEventNames(root) {
  const prefix = "data-brazier-on-";
  const names = new Set();
  for (const node of root.querySelectorAll("*")) {
    for (const attr of Array.from(node.attributes)) {
      if (attr.name.startsWith(prefix)) names.add(attr.name.slice(prefix.length));
    }
  }
  return Array.from(names);
}

// === Rendering ===

// `server` is true for a render of the server's model (adoptAuthoritativeModel):
// only such a render can show the page of a navigation the server
// acknowledged, and it replaces the root's children instead of morphing them
// (see unrenderedNavigations). A render of a local change always morphs.
function renderNow(server = false) {
  renderPending = false;
  if (!clientInitialized || !appRoot) return;
  mark("render-start");
  const t0 = performance.now();
  const rendered = app.render(clientModel, clientLocal);
  const html = rendered[0];
  const table = rendered[1];
  // Checked before the morph, so a view that renders a stream twice throws
  // before it changes the page.
  const containers = streamContainerTable(rendered[2]);
  const t1 = performance.now();
  if (server && navigationRenderDue()) {
    replaceRootChildren(appRoot, html);
    settleNavigations();
  } else {
    morphInnerHTML(appRoot, html);
  }
  handlers = table;
  listenFor(app.event_names(table).toArray());
  renderStreamContainers(containers);
  const t2 = performance.now();
  const total = t2 - t0;
  if (total > 5) {
    console.log(
      "[brazier] Slow render: view=" + (t1 - t0).toFixed(1) + "ms morph=" + (t2 - t1).toFixed(1) +
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
    throw new Error("[brazier] invariant violated: a dispatched message was not rendered before " + where);
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
// `name`, innermost first, as handler targets (see handlerTarget). An event
// that does not bubble only reaches its own target.
function handlerTargets(name, target, bubbles) {
  const attr = "data-brazier-on-" + name;
  const found = [];
  let node = target && target.nodeType !== 1 ? target.parentNode : target;
  while (node && node !== appRoot) {
    if (node.nodeType === 1 && node.hasAttribute(attr)) {
      found.push(handlerTarget(node, node.getAttribute(attr)));
    }
    if (!bubbles) break;
    node = node.parentNode;
  }
  return found;
}

// The handler id of an element inside a stream item: `i` and the element's
// path from the item's root, such as `i0` or `i0.2`. Page ids are paths
// without the `i`.
const ITEM_HANDLER_ID = /^i[0-9]+(\.[0-9]+)*$/;

// A handler id inside a stream item is relative to the item's root
// (docs/design/STREAMS.md 8.2, ITEM_HANDLER_ID): it is looked up in the
// item's own handler table, found by the stream and key of the closest
// element with data-brazier-key whose parent is a stream container. Any
// other id is looked up in the page's table. Returns
// { el, id, stream, key, item }, with stream, key and item null outside an
// item.
function handlerTarget(el, id) {
  if (ITEM_HANDLER_ID.test(id)) {
    for (let node = el; node && node !== appRoot; node = node.parentNode) {
      if (node.nodeType !== 1 || !node.hasAttribute("data-brazier-key")) continue;
      const parent = node.parentNode;
      if (parent && parent.nodeType === 1 && parent.hasAttribute("data-brazier-stream")) {
        return {
          el,
          id,
          stream: parent.getAttribute("data-brazier-stream"),
          key: node.getAttribute("data-brazier-key"),
          item: node,
        };
      }
    }
  }
  return { el, id, stream: null, key: null, item: null };
}

// The handler table `target`'s id is looked up in, or null when there is
// none (logged here). A live event on an item must come from the node the
// stream's view holds for its key; a replayed one finds its item by stream
// and key, as the join may have kept the SSR node or removed the item.
function handlerTableFor(name, target, replay) {
  if (target.stream === null) {
    if (ITEM_HANDLER_ID.test(target.id)) {
      console.error("[brazier] " + name + " handler id " + target.id + " is relative to a stream item, but its element is not inside one; the event is dropped");
      return null;
    }
    return handlers;
  }
  const view = streamViews.get(target.stream);
  const table = view === undefined ? undefined : view.handlers.get(target.key);
  if (table === undefined) {
    if (replay) {
      console.warn("[brazier] " + name + " event on an item of stream " + target.stream + " from before hydration dropped: the join removed the item");
    } else {
      console.error("[brazier] " + name + " event on an item of stream " + target.stream + " that its view does not hold; the page and the stream store disagree");
    }
    return null;
  }
  if (!replay && view.nodes.get(target.key) !== target.item) {
    console.error("[brazier] " + name + " event on an element of stream " + target.stream + " that is not the item node its view holds; the event is dropped");
    return null;
  }
  return table;
}

// The throttle and debounce key of a handler: the event name and the id,
// plus the stream and key for an item, whose ids repeat across items.
function handlerKey(name, target) {
  if (target.stream === null) return name + ":" + target.id;
  return name + ":" + JSON.stringify([target.stream, target.key, target.id]);
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
  runHandlers(name, event, found, event, false);
  renderIfDispatched();
}

// Run the handlers of `targets` (innermost first, see handlerTarget) against
// `payload`: the DOM event, or a snapshot of it when `replay` is true.
// `domEvent` is the live event prevent-default applies to, or null on
// replay.
function runHandlers(name, payload, targets, domEvent, replay) {
  if (clientFailed) {
    console.error("[brazier] " + name + " event dropped: the client stopped after an earlier crash. Reload the page.");
    return;
  }
  for (const target of targets) {
    const id = target.id;
    const table = handlerTableFor(name, target, replay);
    if (table === null) continue;
    const where = target.stream === null ? "the last render" : "the item's render of stream " + target.stream;
    const looked = app.lookup_handler(table, name, id);
    if (!looked.isOk()) {
      if (replay) {
        console.warn("[brazier] " + name + " event on element " + id + " from before hydration dropped: " + where + " has no such handler");
      } else {
        console.error("[brazier] No " + name + " handler for element " + id + " in " + where + "; the page and its handler table disagree");
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
    const key = handlerKey(name, target);
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
      console.warn("[brazier] " + name + " event on element " + id + " dropped: its decoder failed: " + String(decoded[0]));
    } else {
      if (throttleMs > 0) throttled.set(key, performance.now());
      if (debounceMs > 0) {
        scheduleDebounced(name, id, key, decoded[0], debounceMs);
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

// `key` is the handler's handlerKey, so a debounce is per item inside a
// stream.
function scheduleDebounced(name, id, key, msg, ms) {
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
    console.error("[brazier] " + name + " event dropped: the client stopped after an earlier crash. Reload the page.");
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
    console.error("[brazier] The app's client update crashed on a " + name + " event (element " + id + "); the client stops handling events. Reload the page.", e);
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
  if (found.some((f) => f.el.hasAttribute("data-brazier-prevent-" + name))) event.preventDefault();
  if (pendingEarlyEvents.length >= MAX_PENDING_EARLY_EVENTS) {
    console.error("[brazier] Early event queue full (" + MAX_PENDING_EARLY_EVENTS + "); " + name + " before the first model_sync was dropped");
    trace("early_event.full", { name });
    return;
  }
  // An item's handler is replayed by (stream, key, id): the join may keep
  // the SSR node or remove the item, so the node itself is not kept.
  const targets = found.map((f) => ({ el: null, id: f.id, stream: f.stream, key: f.key, item: null }));
  pendingEarlyEvents.push({ name, targets, snapshot: snapshotEvent(event) });
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
    runHandlers(entry.name, entry.snapshot, entry.targets, null, true);
    // The next replayed event runs the handlers of the state this one left.
    renderIfDispatched();
  }
  console.log("[brazier] Replayed " + queued.length + " event(s) from before hydration");
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
    if (msg.type === "event") max = Math.max(max, eventClockOf(msg));
    else if (msg.type === "event_batch") for (const e of msg.events) max = Math.max(max, eventClockOf(e));
  }
  return max;
}

// The clock of an event the client queued. dispatchMsg stamps every event
// and ws_send refuses one without a valid clock, so an invalid clock here is
// a bug in the client, not a value to default.
function eventClockOf(event) {
  if (!isWireClock(event.clock)) {
    throw new Error("[brazier] invariant violated: a queued event has clock " + JSON.stringify(event.clock));
  }
  return event.clock;
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

// Decode an authoritative model (the parsed JSON value, never text) and
// render it. Returns null on success or the reason it failed. Throws if the
// app's code throws.
function adoptAuthoritativeModel(modelValue) {
  const result = app.decode_model(modelValue);
  if (!result.isOk()) return "decode_model failed: " + String(result[0]);
  const model = result[0];
  if (predicted) {
    predicted = false;
    if (!app.same_model(clientModel, model)) {
      console.warn("[brazier] The browser's update predicted a different model than the server's; the server's model wins. Check that update is pure and deterministic.");
      trace("model.mismatch");
    }
  }
  clientModel = model;
  if (!clientInitialized) {
    clientLocal = app.init_local(model);
    clientInitialized = true;
    console.log("[brazier] Client ready (from model_sync)");
  }
  renderNow(true);
  return null;
}

// === Streams ===
//
// docs/design/STREAMS.md 6.2 and 8. Every patch and model_sync carries a
// required `streams` array; each entry is applied to its stream's store
// (brazier_client/stream.mjs) before the model part of the frame, and the
// rendered container of the stream follows the store. A stream's items are
// not in the model: the view renders an empty container
// (`data-brazier-stream="<name>"`) and lists it next to the handler table,
// and the items are rendered one by one with render_item.
//
// Adapted from Phoenix LiveView, assets/js/phoenix_live_view/dom_patch.ts
// (commit 882655c): the container is skipped by the page morph
// (skipFromChildren); a connection's first frame reconciles every container
// against the store, keeping the node of every key it holds (the join path
// of `perform`, where children whose key is not in the stream are removed);
// later frames apply their entry only, and a key deleted and inserted again
// in one entry is restored from a stash (removeStreamChildElement and
// streamComponentRestore). Unlike LiveView, the wire entry carries each
// insert's final index and every trim as a delete, so the client computes
// no position and no trim (D6); and nothing is repaired: a frame that does
// not fit the store is a stream fault, which closes the socket with 4000
// `stream fault` to reconnect (D3).

// The stream names the bundle declares (stream_names), set by start.
let declaredStreams = new Set();
// Stream name -> store (stream.mjs). Emptied by connect(); the join's
// model_sync refills every stream `init` touched.
const streamStores = new Map();
// Stream name -> the stream's rendered container:
// { name, el, container, nodes: Map key -> item element,
//   handlers: Map key -> item handler table }.
// The handler tables live here, not in the store, so the items a reconnect
// keeps on the page stay clickable until the join reconciles them.
const streamViews = new Map();
// Container element -> the stream whose items it holds.
const containerOwners = new WeakMap();
// The next frame with a streams field is the connection's first: it
// reconciles every container in full. Set by connect().
let streamsNeedReconcile = true;
// The socket a stream fault closed; its later frames are ignored.
let faultedSocket = null;

// The names of stream_names, checked: strings, unique and not empty.
function declaredStreamNames(list) {
  const names = new Set();
  for (const name of list.toArray()) {
    if (typeof name !== "string" || name === "") {
      throw new Error("[brazier] invariant violated: stream_names holds " + JSON.stringify(name) + ", not a stream name");
    }
    if (names.has(name)) {
      throw new Error("[brazier] invariant violated: stream_names lists the stream " + name + " twice");
    }
    names.add(name);
  }
  return names;
}

function resetStreamStores() {
  if (streamStores.size > 0) {
    console.log("[brazier] Reconnecting: emptied " + streamStores.size + " stream store(s); the join refills them and reconciles the page");
  }
  streamStores.clear();
  streamsNeedReconcile = true;
  trace("stream.reset_stores", { views: streamViews.size });
}

// A stream fault (docs/design/STREAMS.md 6.2): the store can no longer be
// trusted and request_sync cannot repair it, so the socket is closed with
// 4000 `stream fault`, which reconnects with backoff (as sendJoin does when
// the join cannot be written). Logged with the stream and the reason; never
// a key or an item, which can identify a user.
function streamFault(socket, fault, where) {
  if (socket === null) throw new Error("[brazier] invariant violated: a stream fault without a socket");
  console.error(
    "[brazier] Stream fault (" + where + "): stream " + JSON.stringify(fault.stream) + ", " + fault.reason + ": " +
      fault.detail + ". The stream store cannot be trusted; closing the socket with 4000 to reconnect and refill it.",
  );
  trace("stream.fault", { stream: fault.stream, reason: fault.reason, where });
  if (socket === faultedSocket) return;
  faultedSocket = socket;
  if (socket.readyState === WebSocket.CLOSING || socket.readyState === WebSocket.CLOSED) {
    console.warn("[brazier] The socket of the stream fault is already closing; its close reconnects");
    return;
  }
  socket.close(4000, "stream fault");
}

// Apply a frame's `streams` field. Returns false after a stream fault (the
// socket is then closing and the frame's model part must not be applied).
// Every entry is checked before any store changes, so a fault leaves the
// stores as they were; entries for one name apply in order.
function applyFrameStreams(socket, value, kind) {
  const decoded = decodeStreams(value);
  if (!decoded.ok) {
    streamFault(socket, decoded.fault, kind);
    return false;
  }
  const working = new Map();
  const applied = [];
  for (const entry of decoded.entries) {
    const current = working.has(entry.name) ? working.get(entry.name) : streamStores.get(entry.name);
    const result = applyEntry(current === undefined ? null : current, entry, declaredStreams);
    if (!result.ok) {
      streamFault(socket, result.fault, kind);
      return false;
    }
    const view = streamViews.get(entry.name);
    if (view !== undefined) {
      const mismatch = containerMismatch(entry.name, view.container, entry.keep, entry.limit, "entry");
      if (mismatch !== null) {
        streamFault(socket, mismatch, kind);
        return false;
      }
    }
    working.set(entry.name, result.store);
    applied.push({ name: entry.name, store: result.store, steps: result.steps });
  }
  for (const { name, store, steps } of applied) {
    if (!streamStores.has(name)) {
      console.log("[brazier] Stream " + name + " started (keep " + store.keep + ", limit " + store.limit + ")");
    }
    streamStores.set(name, store);
    if (devMode) trace("stream.delta", { stream: name, kind, items: store.keys.length, ...stepCounts(steps) });
  }
  const first = streamsNeedReconcile;
  streamsNeedReconcile = false;
  if (first) {
    if (streamViews.size === 0) return true;
    console.log("[brazier] First frame of the connection: reconciling " + streamViews.size + " stream container(s)");
    return withStreamMorph(() => {
      for (const view of streamViews.values()) {
        if (!reconcileView(socket, view)) return false;
      }
      return true;
    });
  }
  const shown = applied.filter(({ name }) => streamViews.has(name));
  if (shown.length === 0) return true;
  return withStreamMorph(() => {
    for (const { name, store, steps } of shown) {
      if (!patchView(socket, streamViews.get(name), store, steps)) return false;
    }
    return true;
  });
}

// A fault when `keep` or `limit` (of an entry or a store, `what`) differs
// from the rendered container's, else null.
function containerMismatch(name, container, keep, limit, what) {
  const containerKeep = app.container_keep(container);
  const containerLimit = app.container_limit(container);
  if (keep !== containerKeep) {
    return { stream: name, reason: "keep_mismatch", detail: what + " keep " + keep + ", container keep " + containerKeep };
  }
  if (limit !== containerLimit) {
    return { stream: name, reason: "limit_mismatch", detail: what + " limit " + limit + ", container limit " + containerLimit };
  }
  return null;
}

// Run DOM work on stream containers as a morph: focus and selection are kept
// across moves, autofocus is honoured, and the hooks of what it touched sync
// once it is done (morphInnerHTML does the same for the page).
function withStreamMorph(fn) {
  const focused = document.activeElement;
  const focusedTag = focused ? focused.tagName : undefined;
  const focusedName = focused && focused.getAttribute ? focused.getAttribute("name") : null;
  const selStart = focused ? focused.selectionStart : undefined;
  const selEnd = focused ? focused.selectionEnd : undefined;
  const focusedValue = focused ? focused.value : undefined;
  const locked = inputLocked();
  autofocusQueue = [];
  hookTouched = [];
  morphFocused = focused;
  let result;
  try {
    result = fn();
  } finally {
    morphFocused = null;
  }
  syncHooks(appRoot);
  restoreReplacedFocus(appRoot, focused, focusedTag, focusedName, focusedValue, selStart, selEnd, locked);
  focusAutofocused(appRoot);
  return result;
}

// Render one item of `view`'s stream: { root, table }, or null after a
// stream fault (the item's decoder or item function refused it). The root
// is a new element, keyed by `key`.
function renderStreamItem(socket, view, key, item) {
  const result = app.render_item(view.container, key, item);
  if (!result.isOk()) {
    streamFault(socket, { stream: view.name, reason: "item_render_failed", detail: String(result[0]) }, "item render");
    return null;
  }
  const html = result[0][0];
  const table = result[0][1];
  const template = document.createElement("template");
  template.innerHTML = html;
  const root = template.content.firstChild;
  // render_item refuses an item whose root is not one element (an Error
  // above), and sets the root's data-brazier-key to the key.
  if (!root || root.nodeType !== 1 || root.nextSibling !== null || root.getAttribute("data-brazier-key") !== key) {
    throw new Error("[brazier] invariant violated: render_item for stream " + view.name + " did not give one element keyed by the item's key");
  }
  listenFor(app.event_names(table).toArray());
  return { root, table };
}

// Remove an item element and unmount its hooks. One frame can remove an
// element it touched earlier (an entry inserts a key, a later entry for the
// same stream deletes it), so what the removed subtree holds leaves the
// morph's touched list here; syncHooks still throws for anything else that
// leaves the root.
function removeStreamChild(el, node) {
  if (hookTouched.length > 0) hookTouched = hookTouched.filter((touched) => !node.contains(touched.node));
  unmountSubtree(node);
  el.removeChild(node);
}

function removeAllStreamChildren(el) {
  while (el.firstChild) removeStreamChild(el, el.firstChild);
}

// Move an item element before `ref` (null: to the end). moveBefore keeps
// focus, selection and an iframe's state through the move; without it the
// element leaves the document for a moment, and withStreamMorph gives focus
// back.
function placeStreamChild(el, node, ref) {
  if (typeof el.moveBefore === "function") el.moveBefore(node, ref);
  else el.insertBefore(node, ref);
}

// Morph an item element into a new render of its item. An element of
// another tag is replaced. Returns the element that holds the item.
function morphStreamChild(el, node, root) {
  if (node.tagName !== root.tagName) {
    el.insertBefore(root, node);
    removeStreamChild(el, node);
    inserted(root);
    return root;
  }
  morphNode(node, root);
  return node;
}

// Full reconcile of a container with its store: on the connection's first
// frame and for a container new in the DOM. Every child that is not an
// element keyed by a key of the store (or repeats one) is removed and its
// hooks unmounted; every key is placed in order, and a child that already
// has it is kept and morphed, so it keeps its identity, focus and hook
// state. Works from the children on the page, not from view.nodes, so it
// also repairs a view that a fault left half patched. Returns false after a
// stream fault.
function reconcileView(socket, view) {
  const el = view.el;
  const store = streamStores.get(view.name);
  const keys = store === undefined ? [] : store.keys;
  const owner = containerOwners.get(el);
  if (owner !== undefined && owner !== view.name) {
    if (devMode) trace("stream.container_reowned", { from: owner, to: view.name });
    removeAllStreamChildren(el);
  }
  containerOwners.set(el, view.name);
  const wanted = new Set(keys);
  const kept = new Map();
  for (let child = el.firstChild; child !== null; ) {
    const next = child.nextSibling;
    const key = child.nodeType === 1 ? child.getAttribute("data-brazier-key") : null;
    if (key === null || !wanted.has(key) || kept.has(key)) removeStreamChild(el, child);
    else kept.set(key, child);
    child = next;
  }
  const nodes = new Map();
  const tables = new Map();
  let cursor = el.firstChild;
  for (const key of keys) {
    const rendered = renderStreamItem(socket, view, key, store.items.get(key));
    if (rendered === null) return false;
    const old = kept.get(key);
    let node;
    if (old === undefined) {
      node = el.insertBefore(rendered.root, cursor);
      inserted(node);
    } else {
      if (old === cursor) cursor = cursor.nextSibling;
      else placeStreamChild(el, old, cursor);
      node = morphStreamChild(el, old, rendered.root);
    }
    nodes.set(key, node);
    tables.set(key, rendered.table);
  }
  view.nodes = nodes;
  view.handlers = tables;
  verifyStreamView(view, keys);
  if (devMode) trace("stream.reconcile", { stream: view.name, items: keys.length, kept: kept.size });
  return true;
}

// Apply one entry's steps (stream.mjs applyEntry) to a container that
// already follows the store before the entry. A deleted or reset child is
// stashed, and an insert of its key in the same entry restores it (a move);
// what is still stashed at the end is removed and its hooks unmounted.
// `store` is the store after the entry. Returns false after a stream fault.
function patchView(socket, view, store, steps) {
  const el = view.el;
  const leaving = new Map();
  const stash = (key) => {
    const node = view.nodes.get(key);
    if (node === undefined) {
      throw new Error("[brazier] invariant violated: the view of stream " + view.name + " has no element for a key its store held");
    }
    view.nodes.delete(key);
    view.handlers.delete(key);
    leaving.set(key, node);
  };
  for (const step of steps) {
    if (step.op === "reset") {
      for (const key of [...view.nodes.keys()]) stash(key);
    } else if (step.op === "delete") {
      stash(step.key);
    } else if (step.op === "insert") {
      const rendered = renderStreamItem(socket, view, step.key, store.items.get(step.key));
      if (rendered === null) return false;
      const ref = step.before === null ? null : view.nodes.get(step.before);
      if (ref === undefined) {
        throw new Error("[brazier] invariant violated: an insert into stream " + view.name + " goes before a key its view does not hold");
      }
      const back = leaving.get(step.key);
      let node;
      if (back === undefined) {
        node = el.insertBefore(rendered.root, ref);
        inserted(node);
      } else {
        leaving.delete(step.key);
        placeStreamChild(el, back, ref);
        node = morphStreamChild(el, back, rendered.root);
      }
      view.nodes.set(step.key, node);
      view.handlers.set(step.key, rendered.table);
    } else if (step.op === "update") {
      const node = view.nodes.get(step.key);
      if (node === undefined) {
        throw new Error("[brazier] invariant violated: an update in stream " + view.name + " of a key its view does not hold");
      }
      const rendered = renderStreamItem(socket, view, step.key, store.items.get(step.key));
      if (rendered === null) return false;
      view.nodes.set(step.key, morphStreamChild(el, node, rendered.root));
      view.handlers.set(step.key, rendered.table);
    } else {
      throw new Error("[brazier] invariant violated: unknown stream step " + step.op);
    }
  }
  for (const node of leaving.values()) removeStreamChild(el, node);
  verifyStreamView(view, store.keys);
  return true;
}

// Invariant: a container's children are exactly the elements of its view,
// one per key, in the store's order, and every key has a handler table.
function verifyStreamView(view, keys) {
  const el = view.el;
  if (view.nodes.size !== keys.length || view.handlers.size !== keys.length || el.childNodes.length !== keys.length) {
    throw new Error(
      "[brazier] invariant violated: stream " + view.name + " holds " + keys.length + " items, its view " + view.nodes.size +
        " elements and " + view.handlers.size + " handler tables, its container " + el.childNodes.length + " children",
    );
  }
  let child = el.firstChild;
  for (const key of keys) {
    if (child !== view.nodes.get(key)) {
      throw new Error("[brazier] invariant violated: the container of stream " + view.name + " is not in the store's order");
    }
    child = child.nextSibling;
  }
}

// The containers a render lists, by name, checked before the page morph: a
// stream the bundle does not declare, or one rendered twice, throws
// (docs/design/STREAMS.md 12), which takes the render-failure path.
function streamContainerTable(list) {
  const table = new Map();
  for (const container of list.toArray()) {
    const name = app.container_name(container);
    if (!declaredStreams.has(name)) {
      throw new Error("[brazier] invariant violated: the view renders stream " + JSON.stringify(name) + ", which the bundle does not declare");
    }
    if (table.has(name)) {
      throw new Error("[brazier] The view renders stream " + name + " twice; a stream has one container");
    }
    table.set(name, container);
  }
  return table;
}

// After the page morph: match the listed containers to the elements on the
// page, check each store against its container, and fill every container
// that is new in the DOM (or whose item function changed) with a full
// reconcile. A container the render no longer lists loses its view; the
// store stays, and fills the container when it appears again.
function renderStreamContainers(table) {
  const elements = new Map();
  for (const el of appRoot.querySelectorAll("[data-brazier-stream]")) {
    const name = el.getAttribute("data-brazier-stream");
    if (!table.has(name) || elements.has(name)) {
      throw new Error("[brazier] invariant violated: the page holds a container of stream " + JSON.stringify(name) + " that the render did not list once");
    }
    elements.set(name, el);
  }
  if (elements.size !== table.size) {
    throw new Error("[brazier] invariant violated: the render lists " + table.size + " stream container(s), the page holds " + elements.size);
  }
  for (const name of [...streamViews.keys()]) {
    if (table.has(name)) continue;
    streamViews.delete(name);
    console.log("[brazier] Stream " + name + " is no longer rendered; its store is kept");
  }
  for (const [name, container] of table) {
    const store = streamStores.get(name);
    if (store === undefined) continue;
    const mismatch = containerMismatch(name, container, store.keep, store.limit, "store");
    if (mismatch !== null) {
      streamFault(ws, mismatch, "render");
      return;
    }
  }
  const fresh = [];
  for (const [name, container] of table) {
    const el = elements.get(name);
    const view = streamViews.get(name);
    // The item function is compared by reference only, never called: the
    // same element under a new item function renders its items anew.
    if (view !== undefined && view.el === el && app.container_item(view.container) === app.container_item(container)) {
      view.container = container;
      continue;
    }
    const next = { name, el, container, nodes: new Map(), handlers: new Map() };
    streamViews.set(name, next);
    fresh.push(next);
    console.log("[brazier] Stream " + name + (view === undefined ? " rendered" : " rendered into a new container or with a new item function") + "; filling it from its store");
  }
  if (fresh.length === 0) return;
  withStreamMorph(() => {
    for (const view of fresh) {
      if (!reconcileView(ws, view)) return;
    }
  });
}

// === WebSocket ===

function socketUrl() {
  const scheme = location.protocol === "https:" ? "wss://" : "ws://";
  return scheme + location.host + "/ws?path=" + encodeURIComponent(location.pathname + location.search);
}

function connect() {
  if (reconnectStopped) {
    console.error("[brazier] Not connecting: the server refused this page's session. Reload the page to try again.");
    return;
  }
  // Events sent on the old socket are never acknowledged on this one, so
  // only a still-queued event of a `simple` app keeps holding server state.
  const queuedClock = simple ? queuedEventClock() : 0;
  if (hasPendingModelEvent() && queuedClock < pendingModelEventClock) {
    console.warn("[brazier] Events sent before the disconnect were not acknowledged; the new connection's model replaces their prediction");
    trace("reconnect.unacked_prediction", { pendingModelEventClock, latestAckClock, queuedClock });
  }
  pendingModelEventClock = queuedClock;
  predicted = queuedClock > 0;
  // The join is for the current URL, so its model_sync renders the page of
  // every navigation not rendered yet: it replaces the page (clock 0). A
  // navigation written to the old socket is never acknowledged on this one,
  // so the join scrolls for it too; a still-queued navigate is sent once
  // synced and keeps its clock, so its scroll waits for its ack, after its
  // on_change ran.
  const queuedNavigate = (clock) => outbound.some((msg) => msg.type === "navigate" && msg.clock === clock);
  const scroll = pendingNavigationScroll;
  if (scroll !== null && !queuedNavigate(scroll.clock)) {
    trace("reconnect.navigation_scroll_on_join", { hash: scroll.hash, clock: scroll.clock });
    pendingNavigationScroll = { hash: scroll.hash, clock: 0 };
  }
  if (unrenderedNavigations.length > 0) {
    trace("reconnect.navigation_render_on_join", { navigations: unrenderedNavigations.length });
    unrenderedNavigations = [0];
  }
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
  resetStreamStores();
  const socket = new WebSocket(socketUrl());
  ws = socket;
  socketOpened = false;
  socket.onopen = () => {
    mark("ws-open");
    socketOpened = true;
    unopenedCloses = 0;
    startHeartbeat(socket);
    sendJoin(socket);
  };
  socket.onmessage = (e) => handleMessage(socket, e.data);
  socket.onclose = (e) => handleClose(socket, e);
  socket.onerror = (e) => console.error("[brazier] WS error:", e);
}

function sendJoin(socket) {
  // A new connection has a fresh budget, so the join always fits. Charging it
  // keeps the client budget in step with the server's count.
  if (!outbound.budget.tryTake(performance.now(), 1)) {
    throw new Error("[brazier] invariant violated: join does not fit a fresh send budget");
  }
  const join = { type: "join", token: "", path: location.pathname + location.search };
  if (BUILD_ID !== null) join.build = BUILD_ID;
  if (pageDevBuild !== null) join.dev_build = pageDevBuild;
  if (!writeSocket(socket, join)) {
    console.error("[brazier] Join could not be written; closing the socket to reconnect");
    socket.close(4000, "join send failed");
    return;
  }
  socketJoined = true;
  trace("ws.join");
  pumpOutbound();
}

function handleClose(socket, e) {
  if (socket !== ws) {
    console.warn("[brazier] Close event for a replaced socket ignored (code " + e.code + ")");
    return;
  }
  stopHeartbeat();
  socketJoined = false;
  readyForServerEvents = false;
  trace("ws.close", { code: e.code, reason: e.reason });
  const action = closeAction(e.code);
  if (action === "reload" || action === "navigate") {
    reconnectStopped = true;
    reloadRefusedPage(e, action);
    return;
  }
  const closed = "code " + e.code + (e.reason ? ", " + e.reason : "");
  if (socketOpened) {
    console.warn("[brazier] WebSocket closed (" + closed + "); reconnecting with backoff");
  } else {
    unopenedCloses++;
    trace("ws.close_unopened", { code: e.code, unopenedCloses });
    if (unopenedCloses >= UNOPENED_CLOSES_BEFORE_ERROR) {
      console.error(
        "[brazier] The WebSocket upgrade failed " + unopenedCloses + " times in a row before opening (" + closed + "): " +
          "the server is unreachable, or it refused the upgrade (a disallowed origin or host, ws_auth, a connection limit). " +
          "Reconnecting with backoff; reload the page to see the server's answer.",
      );
    } else {
      console.warn("[brazier] WebSocket closed before opening (" + closed + "); reconnecting with backoff");
    }
  }
  scheduleReconnect();
}

// The server refused this page's session (close 4400 to 4499): reload, so
// a new page load decides. The reload guard allows MAX_RELOADS within
// RELOAD_WINDOW_MS per tab; past that, or when the guard cannot keep its
// count, the page shows an error state instead of reloading forever.
// `action` "navigate" is close 4600, the route middleware refusing this
// page's mount: the page load of the current URL shows the middleware's
// answer (its redirect or error page), which the socket cannot. A
// middleware whose GET admits what its mount refuses would loop, so the
// same guard counts these loads. location.reload() is the hard navigation
// to the current URL: assigning location.href to itself would only scroll
// when the URL has a fragment.
// Reference: Phoenix LiveView, view.ts onJoinError (a stale or unauthorized
// join calls onRedirect({to: this.root.href})) and live_socket.ts
// reloadWithJitter (counts consecutive reloads to stop a reload loop).
function reloadRefusedPage(e, action) {
  const close = "close " + e.code + (e.reason ? " " + e.reason : "");
  let raw;
  try {
    raw = sessionStorage.getItem(RELOAD_HISTORY_KEY);
  } catch (err) {
    showFatalError("The server refused this page's session (" + close + "). The reload guard cannot read sessionStorage (" + err + "), so the page is not reloaded.");
    return;
  }
  const parsed = parseReloadHistory(raw);
  if (!parsed.ok) {
    showFatalError("The server refused this page's session (" + close + "). The stored reload history " + RELOAD_HISTORY_KEY + " is invalid (" + parsed.reason + "), so the page is not reloaded.");
    return;
  }
  const decision = reloadDecision(parsed.history, Date.now());
  if (decision.action === "give_up") {
    trace("ws.reload_give_up", { code: e.code, reloads: decision.history.length });
    showFatalError("The server refused this page's session (" + close + ") after " + decision.history.length + " reloads within " + RELOAD_WINDOW_MS / 1000 + "s; not reloading again.");
    return;
  }
  try {
    sessionStorage.setItem(RELOAD_HISTORY_KEY, JSON.stringify(decision.history));
  } catch (err) {
    showFatalError("The server refused this page's session (" + close + "). The reload guard cannot write sessionStorage (" + err + "), so the page is not reloaded.");
    return;
  }
  const count = "(reload " + decision.history.length + " of at most " + MAX_RELOADS + " within " + RELOAD_WINDOW_MS / 1000 + "s)";
  if (action === "navigate") {
    trace("ws.middleware_refused", { code: e.code, reason: e.reason, reloads: decision.history.length });
    console.error("[brazier] The server's middleware refused this page's live connection (" + close + "); not reconnecting, loading the page to show its answer " + count);
  } else {
    trace("ws.reload", { code: e.code, reloads: decision.history.length });
    console.error("[brazier] The server refused this page's session (" + close + "); not reconnecting, reloading the page " + count);
  }
  location.reload();
}

// The page cannot continue: log why, mark the app root with
// data-brazier-error (for the app's styles) and put a short notice at its
// top. Nothing patches the root afterwards, because nothing reconnects.
function showFatalError(message) {
  if (!appRoot) throw new Error("[brazier] invariant violated: an error state without an app root");
  console.error("[brazier] " + message);
  appRoot.setAttribute("data-brazier-error", "");
  const notice = document.createElement("div");
  notice.setAttribute("role", "alert");
  notice.setAttribute("data-brazier-error-notice", "");
  notice.textContent = "This page could not be loaded. Reload the page to try again.";
  appRoot.insertBefore(notice, appRoot.firstChild);
}

// Write one message to the socket. Returns false when it was not written.
function writeSocket(socket, msg) {
  if (socket !== ws || socket.readyState !== WebSocket.OPEN) return false;
  try {
    socket.send(JSON.stringify(msg));
  } catch (e) {
    console.error("[brazier] WS send failed for " + msg.type + "; it stays queued:", e);
    return false;
  }
  if (msg.type === "event") {
    writtenEventClock = Math.max(writtenEventClock, eventClockOf(msg));
  } else if (msg.type === "event_batch") {
    for (const event of msg.events) writtenEventClock = Math.max(writtenEventClock, eventClockOf(event));
  }
  return true;
}

// Queue a message for the paced sender. Returns false when the queue is full;
// the message is then reported and a full sync follows once the queue drains.
function send(msg) {
  const cost = messageCost(msg);
  if (!outbound.push(msg, cost, msg.type === "request_sync")) {
    console.error("[brazier] Outbound queue full (" + MAX_PENDING_SEND_QUEUE + " messages); " + msg.type + " was not sent. A full model sync will follow.");
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
  window.__brazierWsState = () => (ws ? ws.readyState : -1);
  window.__brazierConnectionReady = () => readyForServerEvents;
  if (window.__BRAZIER_ENABLE_TEST_HOOKS === true) {
    window.__brazierCloseSocketForTest = () => {
      if (!ws) return -1;
      const state = ws.readyState;
      ws.close(4000, "brazier test close");
      return state;
    };
    // What the client still owes the server: the messages waiting in the
    // paced queue, whether a paced send is scheduled, and the debounced
    // messages whose timer has not fired (each is dispatched, and may be
    // sent, when it does). A test waits for
    // { queued: 0, scheduled: false, debounced: 0 } instead of a quiet period.
    window.__brazierOutboundPendingForTest = () => ({
      queued: outbound.length,
      scheduled: pumpTimer !== null,
      debounced: debounced.size,
    });
    // Hand `raw` to the current socket's message handler, as a frame the
    // server sent: a test forges a frame the server never would.
    window.__brazierDeliverFrameForTest = (raw) => {
      if (typeof raw !== "string") {
        throw new Error("[brazier] __brazierDeliverFrameForTest takes the frame's text, got " + typeof raw);
      }
      if (!ws) throw new Error("[brazier] __brazierDeliverFrameForTest: there is no socket to deliver the frame on");
      handleMessage(ws, raw);
      return ws.readyState;
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
    console.warn("[brazier] Heartbeat skipped: the previous one was sent under 500ms ago");
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
  console.log("[brazier] Reconnect attempt " + reconnectAttempts + " in " + delay + "ms");
  setTimeout(connect, delay);
}

// Test seam: queue a raw client message (JSON) as the runtime would. Every
// event must carry its clock, as the ones the runtime stamps do.
export function ws_send(data) {
  const msg = JSON.parse(data);
  const events = msg.type === "event" ? [msg] : msg.type === "event_batch" ? msg.events : [];
  if (!Array.isArray(events)) {
    throw new Error("[brazier] ws_send: an event_batch needs an events array, got " + JSON.stringify(events));
  }
  for (const event of events) {
    if (!isWireClock(event.clock)) {
      throw new Error("[brazier] ws_send: every event needs a clock (a non-negative integer), got " + JSON.stringify(event.clock));
    }
  }
  if (msg.type === "event_batch") {
    for (const batch of splitEventBatch(msg, CLIENT_SEND_BUDGET)) send(batch);
  } else {
    send(msg);
  }
  return undefined;
}

// === Server messages ===

function handleMessage(socket, raw) {
  let msg;
  // A frame that is not JSON cannot be processed. It may have been a patch,
  // so the cached model can no longer be trusted: log it and resync.
  try {
    msg = JSON.parse(raw);
  } catch (e) {
    console.error("[brazier] Failed to parse server message:", e.message, String(raw).substring(0, 100));
    requestFullSync("unparseable_server_message");
    return;
  }
  // A socket closed for a stream fault applies nothing more: its stores
  // cannot be trusted, and the next connection's join refills them.
  if (socket === faultedSocket) {
    console.warn("[brazier] A " + msg.type + " frame arrived after a stream fault and is ignored; the socket is closing to reconnect");
    trace("stream.frame_after_fault", { type: msg.type });
    return;
  }
  // The streams field is applied before the model part, under every model
  // verdict (docs/design/STREAMS.md 6.2). A stream fault closes the socket,
  // and the model part is not applied.
  switch (msg.type) {
    case "model_sync":
      if (applyFrameStreams(socket, msg.streams, "model_sync")) handleModelSync(msg.model, msg.version, msg.ack_clock);
      break;
    case "patch":
      if (applyFrameStreams(socket, msg.streams, "patch")) handlePatch(msg.ops, msg.version, msg.ack_clock);
      break;
    case "navigate": handleServerNavigate(msg.path, msg.replace === true); break;
    case "hard_navigate": handleServerHardNavigate(msg.path); break;
    case "reload": console.log("[brazier] Hot reload: refreshing"); location.reload(); break;
    case "heartbeat_ack": break;
    case "error": handleServerError(msg.reason); break;
    case "title": handleServerTitle(msg.title); break;
    case "mount": console.error("[brazier] Server sent a mount frame, which this client does not support; ignored"); break;
    default: console.error("[brazier] Unknown server message type:", msg.type); break;
  }
}

// The server sends the page title on every join and whenever an update
// changes it (LiveView's page_title).
function handleServerTitle(title) {
  if (typeof title !== "string") {
    console.error("[brazier] Server title frame has no string title:", title);
    return;
  }
  document.title = title;
  trace("title", { title });
}

function handleServerError(reason) {
  console.error("[brazier] Server error:", reason);
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

// `model` is the frame's `model` value, parsed with the frame: the server
// embeds the model JSON raw, so it is never parsed a second time.
function handleModelSync(model, version, ackClock) {
  // Any model_sync answers an outstanding request_sync, applied or not.
  syncRequestInFlight = false;
  mark("model-sync-start");
  // The server sends ack_clock on every model_sync. Without a valid one the
  // client cannot tell which of its events the model covers.
  if (!isWireClock(ackClock)) {
    modelSyncFailed(version, "invalid ack_clock " + JSON.stringify(ackClock));
    return;
  }
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
    throw new Error("[brazier] invariant violated: a simple event is pending before the client was initialized");
  }
  // A frame without a model field cannot be applied. Any other value is
  // handed to decode_model, which refuses one that is not the app's Model.
  if (model === undefined) {
    modelSyncFailed(version, "the frame has no model field");
    return;
  }
  try {
    if (!held) {
      markServerAckApplied(ackClock);
      const failure = adoptAuthoritativeModel(model);
      if (failure !== null) {
        modelSyncFailed(version, failure);
        return;
      }
    }
  } catch (e) {
    modelSyncFailed(version, e && e.message ? e.message : String(e));
    return;
  }
  clientModelJson = model;
  currentModelVersion = version;
  modelSynced = true;
  consecutiveModelSyncFailures = 0;
  // Backoff resets only once a connection proved usable, so a server that
  // accepts and immediately drops sockets is still retried with backoff.
  reconnectAttempts = 0;
  console.log("[brazier] Model synced v" + version);
  trace("model_sync", { version, ackClock });
  if (!held) resolveNavigations();
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
    console.error("[brazier] model_sync v" + version + " failed " + consecutiveModelSyncFailures + " times in a row (" + reason + "). Client state is out of sync; no more resyncs on this connection. Reload the page to recover.");
    return;
  }
  console.error("[brazier] model_sync v" + version + " could not be applied (" + reason + "); requesting resync " + consecutiveModelSyncFailures + "/" + MAX_MODEL_SYNC_RETRIES);
  requestFullSync("model_sync_failed");
}

// `ops` is the frame's `ops` value, parsed with the frame: the server embeds
// the RFC 6902 array raw, so it is never parsed a second time.
function handlePatch(ops, version, ackClock) {
  mark("patch-start");
  if (!isWireClock(ackClock)) {
    console.error("[brazier] Patch v" + JSON.stringify(version) + " has invalid ack_clock " + JSON.stringify(ackClock) + "; requesting full sync");
    invalidateModelCache();
    requestFullSync("invalid_ack_clock");
    return;
  }
  if (!Array.isArray(ops)) {
    console.error("[brazier] Patch ops are not an array (got " + (ops === null ? "null" : typeof ops) + "); requesting full sync");
    invalidateModelCache();
    requestFullSync("patch_ops_not_array");
    return;
  }

  const synced = modelSynced && clientModelJson !== null;
  const verdict = classifyPatch({ version: currentModelVersion, synced }, version, ops.length);
  switch (verdict) {
    case "invalid":
      console.error("[brazier] Patch with invalid version " + JSON.stringify(version) + "; requesting full sync");
      invalidateModelCache();
      requestFullSync("invalid_patch_version");
      return;
    case "stale":
      trace("patch.stale", { version, currentModelVersion });
      return;
    case "gap":
      console.warn("[brazier] Patch v" + version + " does not build on cached v" + currentModelVersion + (synced ? "" : " (no synced model)") + "; requesting full sync");
      requestFullSync("patch_gap");
      return;
    case "ack":
      handleAckPatch(version, ackClock);
      return;
    case "apply":
      break;
    default:
      throw new Error("[brazier] invariant violated: unknown patch verdict " + verdict);
  }

  let newModelJson;
  try {
    // applyOps never mutates its input, so a failure leaves the cache intact
    // until it is invalidated below.
    newModelJson = applyOps(clientModelJson, ops);
  } catch (e) {
    console.error("[brazier] Patch apply failed:", e);
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
    const failure = adoptAuthoritativeModel(newModelJson);
    if (failure !== null) {
      console.error("[brazier] Patch v" + version + " produced a model the client cannot decode (" + failure + "); requesting full sync");
      invalidateModelCache();
      requestFullSync("patch_decode_failed");
      return;
    }
  } catch (e) {
    console.error("[brazier] Rendering patch v" + version + " failed:", e);
    invalidateModelCache();
    requestFullSync("patch_render_failed");
    return;
  }
  clientModelJson = newModelJson;
  currentModelVersion = version;
  console.log("[brazier] Patch applied v" + version + " (" + ops.length + " ops)");
  trace("patch", { version, ackClock, ops: ops.length });
  resolveNavigations();
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
  // The page shows the cached model unless a prediction or a locked input
  // needs the re-render below.
  if (!wasPending && !(wasLocked && !inputLocked())) {
    resolveNavigations();
    return;
  }
  try {
    const failure = adoptAuthoritativeModel(clientModelJson);
    if (failure !== null) {
      console.error("[brazier] Cached model v" + version + " cannot be decoded after ack (" + failure + "); requesting full sync");
      invalidateModelCache();
      requestFullSync("ack_decode_failed");
      return;
    }
  } catch (e) {
    console.error("[brazier] Re-render after ack failed:", e);
    invalidateModelCache();
    requestFullSync("ack_render_failed");
    return;
  }
  resolveNavigations();
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
  console.warn("[brazier] Requesting full model sync: " + reason);
  trace("sync_request", { reason });
  // When the queue is full, send() reports it and the overflow resync follows
  // once the queue drains, so the request is not marked in flight here.
  if (send({ type: "request_sync" })) syncRequestInFlight = true;
}

// === Navigation ===

function currentPath() {
  return location.pathname + location.search;
}

// The path (pathname and query) of the route the server was last told
// about. A fragment change (an in-page #anchor link, or back and forward
// between two of them) changes the URL but not this path, and fires
// popstate; it is the same page, so no navigate is sent for it.
let routePath = null;

// The scroll of a live navigation (a link, or the server's router.push and
// router.replace), waiting for the new page: { hash, clock }, clock being
// the navigate's and hash the URL's fragment ("" for none). The browser does
// not scroll for pushState, and the new page exists only once the server's
// answer to the navigate is rendered, so the first applied frame whose
// ack_clock covers the clock scrolls: to the top for a URL without a
// fragment, else to the fragment, or to the top when the page has no such
// element. LiveView's Browser.pushState does the same once the reply of a
// live navigation is rendered (getHashTargetEl, then scrollIntoView, else
// window.scroll(0, 0)). Back and forward schedule none (popstate): they keep
// the browser's scroll restoration.
let pendingNavigationScroll = null;

// The clocks of the navigates whose page is not rendered yet, in order. The
// first render whose ack_clock covers one replaces the app root's children
// instead of morphing them (renderNow), so no node of the old page is reused
// for the new one: focus, typed values, scroll positions and hooks do not
// carry over to another page that happens to share markup with it. This is
// LiveView's live navigation, where replaceMain puts a new root element in
// place of the old view's, whose hooks are destroyed with it. A model change
// on the same page still morphs. Clock 0 stands for a navigate lost with a
// socket, which the next join answers (connect).
let unrenderedNavigations = [];

// Tell the server about a route change. `path` is what the server routes on
// (pathname and search) and `hash` the URL's fragment ("" for none).
// `scroll` is false for back and forward. The navigate takes its clock from
// the event counter, so the frame that shows the new page is the first one
// acknowledging it.
function sendNavigate(path, hash, scroll) {
  const clock = ++eventClock;
  const fragment = hash === "#" ? "" : hash;
  if (!send({ type: "navigate", path, clock })) {
    // send() reported the full queue; the page will not change, so there is
    // nothing to replace or scroll for. A scroll pending for an earlier
    // navigation is dropped too: the URL is no longer that page's.
    pendingNavigationScroll = null;
    return;
  }
  unrenderedNavigations.push(clock);
  pendingNavigationScroll = scroll ? { hash: fragment, clock } : null;
  trace("navigate.pending", { path, hash: fragment, clock, scroll });
}

// The element a fragment names: the HTML indicated-part rules (an element
// with that id, else an <a> with that name), for the fragment as written
// and then percent-decoded, as LiveView's getHashTargetEl and the browser
// look it up.
function fragmentTarget(hash) {
  const raw = hash.slice(1);
  const candidates = [raw];
  try {
    const decoded = decodeURIComponent(raw);
    if (decoded !== raw) candidates.push(decoded);
  } catch (e) {
    console.warn("[brazier] The fragment " + JSON.stringify(hash) + " is not valid percent-encoding (" + e.message + "); looking it up only as written");
  }
  for (const name of candidates) {
    const byId = document.getElementById(name);
    if (byId) return byId;
    const anchor = Array.from(document.getElementsByName(name)).find((node) => node.tagName === "A");
    if (anchor) return anchor;
  }
  return null;
}

// Whether the render about to run shows the page of a navigation: the
// server acknowledged a navigate whose page is not rendered yet.
function navigationRenderDue() {
  return unrenderedNavigations.length > 0 && unrenderedNavigations[0] <= latestAckClock;
}

// Drop the navigations the server acknowledged: their page is rendered, or
// the frame that acknowledged them left the model as it was (an ack), so the
// page on screen is already theirs.
function settleNavigations() {
  if (unrenderedNavigations.length === 0) return;
  unrenderedNavigations = unrenderedNavigations.filter((clock) => clock > latestAckClock);
}

// Called after every applied (not held) model_sync, patch or ack.
function resolveNavigations() {
  settleNavigations();
  const pending = pendingNavigationScroll;
  if (pending === null || latestAckClock < pending.clock) return;
  pendingNavigationScroll = null;
  // The user moved to a fragment (an in-page link) before the page arrived;
  // the browser already scrolled for that one.
  if (location.hash !== pending.hash) {
    trace("navigate.scroll_superseded", { hash: pending.hash, now: location.hash });
    return;
  }
  if (pending.hash === "") {
    window.scrollTo(0, 0);
    trace("navigate.scroll_top");
    return;
  }
  const target = fragmentTarget(pending.hash);
  if (target) {
    target.scrollIntoView();
    trace("navigate.fragment_scroll", { hash: pending.hash });
    return;
  }
  console.warn("[brazier] The page has no element for the fragment " + JSON.stringify(pending.hash) + " (no id, no <a name>); scrolled to the top");
  window.scrollTo(0, 0);
  trace("navigate.fragment_missing", { hash: pending.hash });
}

// Why the server's navigation target is not a same-origin path of this
// page, or null. See localPathRefusal.
function navigationRefusal(path) {
  return localPathRefusal(path, location.origin);
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
  const refusal = navigationRefusal(path);
  if (refusal !== null) {
    console.error("[brazier] Server navigate rejected: not a local path (" + refusal + "):", JSON.stringify(path));
    return;
  }
  if (path === currentPath()) {
    trace("navigate.same_path", { path });
    return;
  }
  leaveRoute(path);
  if (replace) history.replaceState(null, "", path);
  else history.pushState(null, "", path);
  routePath = currentPath();
  // As for a link, the server is told the path without the fragment (a URL's
  // first "#" starts it) and the client scrolls to the fragment once the
  // page is rendered.
  const hashAt = path.indexOf("#");
  sendNavigate(hashAt < 0 ? path : path.slice(0, hashAt), hashAt < 0 ? "" : location.hash, true);
}

// Hard navigation: a full page load, e.g. to receive Set-Cookie headers.
function handleServerHardNavigate(path) {
  // SECURITY: only same-origin paths, never //host, absolute, javascript: or
  // data: URLs, so the server cannot be turned into an open redirect.
  const refusal = navigationRefusal(path);
  if (refusal !== null) {
    console.error("[brazier] Hard navigate rejected: not a local path (" + refusal + "):", JSON.stringify(path));
    return;
  }
  window.location.href = path;
}

function setupNavigation() {
  routePath = currentPath();
  // Same-origin links navigate without a page load.
  document.addEventListener("click", (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (!a) return;
    // Same origin means the same scheme, host and port: a link to another
    // port or to https from http is another site, which the browser loads.
    const href = a.getAttribute("href");
    let url;
    try {
      url = new URL(href, location.origin + location.pathname + location.search);
    } catch (err) {
      console.warn("[brazier] Link not intercepted: its href does not parse (" + err.message + "):", JSON.stringify(href));
      return;
    }
    if (url.origin !== location.origin) return;
    if (a.hasAttribute("data-brazier-external") || a.hasAttribute("download")) return;
    if (a.target && a.target !== "_self") return;
    const path = url.pathname + url.search;
    // An in-page fragment link (`#section`, `/this/page#section`, or a bare
    // `#`) stays the browser's: it scrolls and changes the hash, and the
    // page does not change. This is LiveView's DOM.isNewPageClick (the same
    // pathname and search with a hash, or an href ending in "#", is not a
    // new page) and Turbo's same-page anchor rule.
    if (path === currentPath() && (url.hash !== "" || url.href.endsWith("#"))) {
      trace("navigate.fragment", { hash: url.hash });
      return;
    }
    e.preventDefault();
    if (path === currentPath()) return;
    leaveRoute(path);
    // A link to another page's fragment keeps the fragment in the URL; the
    // server is told only the path, which is what it routes on.
    history.pushState(null, "", path + url.hash);
    routePath = path;
    sendNavigate(path, url.hash, true);
  });
  // Back and forward. Moving between fragments of the same page fires
  // popstate too, and is not a navigation: LiveView's popstate handler
  // returns when isNewLocation finds the pathname and search unchanged.
  window.addEventListener("popstate", () => {
    const path = currentPath();
    if (path === routePath) {
      trace("navigate.same_route_popstate", { path });
      return;
    }
    leaveRoute(path);
    routePath = path;
    // Back and forward keep the browser's scroll restoration, so no scroll
    // is scheduled (and a pending one is dropped). The page is still
    // replaced when it renders.
    sendNavigate(path, "", false);
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

  autofocusQueue = [];
  hookTouched = [];
  morphFocused = focused;
  morphChildren(container, parseFragment(html));
  morphFocused = null;
  syncHooks(container);
  if (devMode) trace("morph", { childCount: container.childNodes.length });

  restoreReplacedFocus(container, focused, focusedTag, focusedName, focusedValue, selStart, selEnd, locked);
  focusAutofocused(container);
}

// The page of a live navigation: every child of the app root is removed
// (its hooks unmount) and the new markup is put in its place, so no element
// of the old page is reused for the new one. The root element itself stays,
// as it holds the page's runtime attributes. Nothing old keeps focus, so
// none is restored; an autofocus element of the new page takes it. Stream
// containers are new elements, which renderStreamContainers fills from
// their stores.
function replaceRootChildren(container, html) {
  const fragment = parseFragment(html);
  autofocusQueue = [];
  hookTouched = [];
  const removed = container.childNodes.length;
  while (container.firstChild) {
    const node = container.firstChild;
    unmountSubtree(node);
    container.removeChild(node);
  }
  for (let c = fragment.firstChild; c; c = c.nextSibling) {
    inserted(container.appendChild(c.cloneNode(true)));
  }
  syncHooks(container);
  console.log("[brazier] Navigation rendered a new page: replaced " + removed + " root node(s) with " + container.childNodes.length);
  trace("navigate.root_replaced", { removed, added: container.childNodes.length });
  focusAutofocused(container);
}

// The element focused when the current morph began. A keyed move takes the
// focused element out of the document for a moment, which blurs it, so the
// morph compares against this, not document.activeElement, to keep a
// focused input's typed value while it moves.
let morphFocused = null;

// The fragment parsed from the last rendered HTML. The morph only reads the
// new tree and clones from it (it never moves or changes a node of it), so a
// render that produced the same HTML reuses the fragment instead of parsing
// it again. It still morphs: the DOM may have drifted from the markup (a
// typed value, an attribute set by other code).
let lastFragmentHtml = null;
let lastFragment = null;

function parseFragment(html) {
  if (html === lastFragmentHtml) return lastFragment;
  const t = document.createElement("template");
  t.innerHTML = html;
  lastFragmentHtml = html;
  lastFragment = t.content;
  return lastFragment;
}

// Elements that gained `autofocus` during the current morph, in document
// order. Browsers honour the attribute only while the page loads, so the
// client focuses the element itself, as Lustre's reconciler does.
let autofocusQueue = [];

function queueAutofocus(node) {
  if (node.nodeType !== 1) return;
  if (node.hasAttribute("autofocus")) autofocusQueue.push(node);
  for (const el of node.querySelectorAll("[autofocus]")) autofocusQueue.push(el);
}

// The last element to gain `autofocus` wins, as when several are focused in
// turn.
function focusAutofocused(container) {
  const target = autofocusQueue[autofocusQueue.length - 1];
  autofocusQueue = [];
  if (!target || !container.contains(target)) return;
  target.focus();
  if (devMode) trace("morph.autofocus", { node: describeNode(target) });
}

function restoreReplacedFocus(container, focused, focusedTag, focusedName, focusedValue, selStart, selEnd, locked) {
  if (focused && container.contains(focused)) {
    // Still in the page, but a keyed move (insertBefore) takes the element
    // out of the document for a moment, and the browser moves focus to the
    // body. Nothing else took focus meanwhile, so give it back with its
    // selection.
    const active = document.activeElement;
    if (active !== focused && (!active || active === document.body)) {
      focused.focus();
      restoreSelection(focused, selStart, selEnd);
      if (devMode) trace("morph.focus_restored", { node: describeNode(focused) });
    }
    return;
  }
  if (focusedTag !== "INPUT" && focusedTag !== "TEXTAREA" && focusedTag !== "SELECT") return;
  if (!focusedName) return;
  // The focused control was replaced: focus its successor by name.
  // SECURITY: CSS.escape keeps the attribute value out of the selector syntax.
  const restored = container.querySelector(`[name="${CSS.escape(focusedName)}"]`);
  if (!restored) return;
  restored.focus();
  if (locked && focusedValue !== undefined && restored.value !== focusedValue) restored.value = focusedValue;
  restoreSelection(restored, selStart, selEnd);
}

function restoreSelection(node, selStart, selEnd) {
  if (typeof selStart !== "number" || !node.setSelectionRange) return;
  try {
    node.setSelectionRange(selStart, selEnd);
  } catch (e) {
    console.warn("[brazier] setSelectionRange failed:", e.message);
  }
}

// How far past the cursor an unkeyed new child looks for an old element of
// its tag before it is inserted instead. Keyed children are matched by key
// at any distance.
const UNKEYED_LOOKAHEAD = 8;

// Reconcile the children of `op` (the live DOM) with those of `np` (the new
// markup, never changed).
//
// Keyed children (data-brazier-key, or id) are matched by key wherever they
// are, and moved into place, so a keyed element keeps its identity (focus,
// typed value, scroll position, mounted hook) across any reorder: morphdom's
// and idiomorph's id matching, and the keyed children of Lustre's
// reconciler and of LiveView's streams. An old keyed element is "reserved"
// when the new markup has its key with the same tag; it is never morphed
// into another child or removed, only moved. Any other old keyed element
// (a key the markup no longer has, another tag, a duplicate) is removed.
// Unkeyed children match by position with a bounded lookahead, as before.
function morphChildren(op, np) {
  const newKeys = newChildKeys(np);
  const reserved = newKeys ? reservedOldChildren(op, newKeys) : null;
  const isReserved = (node) => {
    if (!reserved) return false;
    const key = nodeKey(node);
    return key !== null && reserved.get(key) === node;
  };
  const remove = (node) => {
    unmountSubtree(node);
    op.removeChild(node);
    if (devMode) trace("morph.remove", { key: nodeKey(node) });
  };
  let oc = op.firstChild, nc = np.firstChild;
  while (nc) {
    // An old keyed element at the cursor that nothing reserves goes now, so
    // it does not use up an unkeyed child's lookahead.
    while (oc && nodeKey(oc) !== null && !isReserved(oc)) {
      const nx = oc.nextSibling;
      remove(oc);
      oc = nx;
    }
    const key = nodeKey(nc);
    if (key !== null && newKeys.get(key) === nc) {
      const m = reserved.get(key);
      if (m) {
        reserved.delete(key);
        if (m === oc) oc = oc.nextSibling;
        else {
          op.insertBefore(m, oc);
          if (devMode) trace("morph.move", { key });
        }
        morphNode(m, nc);
      } else {
        inserted(op.insertBefore(nc.cloneNode(true), oc));
        if (devMode) trace("morph.insert", { key });
      }
      nc = nc.nextSibling;
      continue;
    }
    // An unkeyed child, or a later duplicate of a key (always a new
    // element): the first old element of its kind within the lookahead,
    // passing over reserved elements, which wait for their key.
    let m = null;
    if (key === null) {
      for (let c = oc, k = UNKEYED_LOOKAHEAD; c && k > 0; c = c.nextSibling) {
        if (isReserved(c)) continue;
        if (sameNode(c, nc)) { m = c; break; }
        k--;
      }
    }
    if (m) {
      // What lies between the cursor and the match is not in the markup,
      // except reserved elements: they stay until their key moves them.
      while (oc !== m) {
        const nx = oc.nextSibling;
        if (!isReserved(oc)) remove(oc);
        oc = nx;
      }
      morphNode(m, nc);
      oc = m.nextSibling;
    } else {
      inserted(op.insertBefore(nc.cloneNode(true), oc));
      if (devMode) trace("morph.insert", { key });
    }
    nc = nc.nextSibling;
  }
  // Every reserved element was moved into place when its key came up.
  if (reserved && reserved.size !== 0) {
    throw new Error("[brazier] invariant violated: the morph left " + reserved.size + " keyed element(s) unplaced: " + [...reserved.keys()].join(", "));
  }
  while (oc) {
    const nx = oc.nextSibling;
    remove(oc);
    oc = nx;
  }
}

// The keys of the new children, each mapped to the first child with that
// key, or null when no child is keyed. A key repeated among siblings is a
// bug in the view (only the first match keeps an element's identity): it
// is logged, and each later child with it is rendered as a new element.
function newChildKeys(np) {
  let keys = null;
  for (let c = np.firstChild; c; c = c.nextSibling) {
    const key = nodeKey(c);
    if (key === null) continue;
    if (keys === null) keys = new Map();
    if (keys.has(key)) {
      console.error("[brazier] Duplicate key " + JSON.stringify(key) + " among siblings (" + describeNode(c) + "); only the first keeps its element across renders");
      continue;
    }
    keys.set(key, c);
  }
  return keys;
}

// The old children that the new markup keeps, by key: the first old child
// with each key of `newKeys` and the same tag as that new child.
function reservedOldChildren(op, newKeys) {
  const reserved = new Map();
  for (let c = op.firstChild; c; c = c.nextSibling) {
    const key = nodeKey(c);
    if (key === null || reserved.has(key)) continue;
    const target = newKeys.get(key);
    if (target && target.tagName === c.tagName) reserved.set(key, c);
  }
  return reserved;
}

// A subtree the morph inserted: its autofocus and hook elements are new.
function inserted(node) {
  queueAutofocus(node);
  if (node.nodeType === 1) hookTouched.push({ node, subtree: true });
}

function morphNode(o, n) {
  if (o.nodeType === 3) { if (o.textContent !== n.textContent) o.textContent = n.textContent; return; }
  if (o.nodeType !== 1) return;
  // A hook element that stays but loses its hook, or names another one,
  // unmounts the old hook now; a new name mounts when hooks sync. This is
  // LiveView's View.performPatch (beforeUpdated: a removed or changed
  // phx-hook destroys the hook, and a changed one is added after the patch).
  const mounted = mountedHooks.get(o);
  if (mounted && mounted.hookName !== n.getAttribute("data-brazier-hook")) {
    if (devMode) trace("morph.hook_removed", { node: describeNode(o), hook: mounted.hookName });
    unmountHookNode(o);
  }
  const wasContainer = o.hasAttribute("data-brazier-stream");
  if (morphAttributes(o, n) && o.hasAttribute("data-brazier-hook")) hookTouched.push({ node: o, subtree: false });
  if (o.hasAttribute("data-brazier-stream")) {
    // A stream container: its children are the stream's items, which the
    // stream applier places after the render (renderStreamContainers). This
    // is LiveView's skipFromChildren for phx-update="stream". An element
    // that just became a container drops what it held before.
    if (!wasContainer) removeAllStreamChildren(o);
    return;
  }
  if (o.hasAttribute("data-brazier-preserve-children")) {
    // Other code owns these children, and may have added hook elements.
    hookTouched.push({ node: o, subtree: true });
    return;
  }
  const isFormControl = o.tagName === "INPUT" || o.tagName === "TEXTAREA" || o.tagName === "SELECT";
  if (isFormControl && o === morphFocused) {
    // The user is typing here: keep their value while it is not yet
    // reflected by the server (LiveView's rule for focused inputs).
    if (inputLocked()) {
      if (devMode) trace("morph.focused_input_kept", { name: o.getAttribute("name") || "" });
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
  return node.getAttribute("data-brazier-key") || node.id || null;
}

function describeNode(node) {
  if (!node || node.nodeType !== 1) return "";
  const id = node.id ? "#" + node.id : "";
  const key = node.getAttribute("data-brazier-key");
  const keyed = key ? `[data-brazier-key="${key}"]` : "";
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

// Returns whether any attribute of `o` changed.
function morphAttributes(o, n) {
  if (!o.hasAttribute("autofocus") && n.hasAttribute("autofocus")) autofocusQueue.push(o);
  let changed = false;
  for (let i = o.attributes.length - 1; i >= 0; i--) if (!n.hasAttribute(o.attributes[i].name)) { o.removeAttribute(o.attributes[i].name); changed = true; }
  for (let i = 0; i < n.attributes.length; i++) { const nm = n.attributes[i].name, v = n.attributes[i].value; if (o.getAttribute(nm) !== v) { o.setAttribute(nm, v); changed = true; } }
  return changed;
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

// === Hooks ===

// What the current morph touched that can hold a hook element, in document
// order: { node, subtree } for an element whose attributes changed (subtree
// false), or for a subtree it inserted or did not descend into (subtree
// true: data-brazier-preserve-children). Nothing else can have gained a hook
// element or changed a hook element's attributes since the last sync; the
// morph removes everything the markup does not have, and unmounts it. This
// is morphdom's onNodeAdded/onElUpdated and LiveView DOMPatch's tracking of
// added and updated elements, instead of rescanning the whole page.
let hookTouched = [];
// The whole root is scanned on the first sync, after a hook is registered
// and when the root changes.
let hooksNeedFullScan = true;
let hookScanRoot = null;

function syncHooks(root) {
  if (hooksNeedFullScan || root !== hookScanRoot) {
    hooksNeedFullScan = false;
    hookScanRoot = root;
    hookTouched = [];
    root.querySelectorAll("[data-brazier-hook]").forEach(syncHook);
    return;
  }
  const touched = hookTouched;
  hookTouched = [];
  // Collected before any hook runs, as the full scan's querySelectorAll is,
  // so a hook's mount or update changing the DOM does not change the set.
  const nodes = [];
  const seen = new Set();
  const collect = (node) => {
    if (seen.has(node)) return;
    seen.add(node);
    nodes.push(node);
  };
  for (const { node, subtree } of touched) {
    // A touched element always stays in the root: the morph only removes
    // siblings it has not reached yet, and a stream patch that removes an
    // item it touched drops it from the list (removeStreamChild). Only other
    // code can take one out mid-morph (a hook's unmount removing an element
    // outside its own).
    if (!root.contains(node)) {
      throw new Error(
        "[brazier] invariant violated: an element the morph touched (" + describeNode(node) +
          ") left the app root before hooks synced; did a hook's unmount remove an element it does not own?",
      );
    }
    if (node.hasAttribute("data-brazier-hook")) collect(node);
    if (subtree) node.querySelectorAll("[data-brazier-hook]").forEach(collect);
  }
  nodes.forEach(syncHook);
}

function syncHook(node) {
  const hookName = node.getAttribute("data-brazier-hook");
  let existing = mountedHooks.get(node);
  if (existing && existing.hookName !== hookName) {
    // The morph unmounts a hook whose name it changes, so only other code
    // renaming the attribute between renders gets here: a full scan (after
    // a registration) then finds the element under its new name.
    unmountHookNode(node);
    existing = undefined;
  }
  const hook = hookRegistry.get(hookName);
  if (!hook) {
    trace("hook.unregistered", { hook: hookName });
    return;
  }
  const attrs = serializeHookAttrs(node);
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
}

function unmountSubtree(node) {
  if (!node) return;
  if (node.querySelectorAll) node.querySelectorAll("[data-brazier-hook]").forEach(unmountHookNode);
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
  const raw = node.getAttribute("data-brazier-hook-watch");
  if (!raw) return null;
  const names = raw.split(",").map((name) => name.trim()).filter(Boolean);
  return names.length > 0 ? new Set(names) : null;
}

function shouldIncludeHookAttr(name, watchedAttrs) {
  if (name === "data-brazier-preserve-children") return false;
  if (!watchedAttrs) return true;
  return name === "data-brazier-hook" || name === "data-brazier-hook-watch" || watchedAttrs.has(name);
}
