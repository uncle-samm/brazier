// Behaviour checks for the browser runtime (beacon_client_ffi.mjs) without a
// browser: a fake WebSocket, fake timers, a fake clock, a small fake DOM and
// a fake generated entry.
//
// Usage: node beacon_client/test/ffi_harness.mjs
//
// Each scenario loads a fresh copy of the runtime module, starts it with a
// fake app, drives it through DOM events, server frames and close codes, and
// asserts what it wrote to the socket, what it rendered, what it logged and
// which timers it scheduled. Unhappy paths come first. Any failure exits
// non-zero so the calling Gleam test fails loudly.

import assert from "node:assert/strict";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const SRC = fileURLToPath(new URL("../src/", import.meta.url));
const WORK = mkdtempSync(join(tmpdir(), "beacon_ffi_harness_"));
mkdirSync(join(WORK, "beacon_client"));
copyFileSync(join(SRC, "beacon_client_ffi.mjs"), join(WORK, "beacon_client_ffi.mjs"));
copyFileSync(join(SRC, "beacon_client", "patch.mjs"), join(WORK, "beacon_client", "patch.mjs"));

// --- fake clock and timers ---
const clock = { now: 0 };
let timers = [];
let timerSeq = 0;
function addTimer(fn, ms, interval, frame = false) {
  const t = { id: ++timerSeq, at: clock.now + Math.max(0, ms || 0), fn, interval, frame };
  timers.push(t);
  return t.id;
}
function removeTimer(id) {
  timers = timers.filter((t) => t.id !== id);
}
globalThis.setTimeout = (fn, ms) => addTimer(fn, ms, null);
globalThis.clearTimeout = removeTimer;
globalThis.setInterval = (fn, ms) => addTimer(fn, ms, ms);
globalThis.clearInterval = removeTimer;
globalThis.requestAnimationFrame = (fn) => addTimer(fn, 16, null, true);
Object.defineProperty(globalThis, "performance", {
  configurable: true,
  value: { now: () => clock.now, mark() {}, measure() {} },
});
function advance(ms) {
  const target = clock.now + ms;
  for (;;) {
    const due = timers.filter((t) => t.at <= target).sort((a, b) => a.at - b.at || a.id - b.id)[0];
    if (!due) break;
    clock.now = due.at;
    if (due.interval) due.at += due.interval;
    else removeTimer(due.id);
    due.fn();
  }
  clock.now = target;
}
function pendingTimeouts() {
  return timers.filter((t) => !t.interval);
}
// Reconnect timers are the pending timeouts that are not render frames.
function reconnectTimers() {
  return pendingTimeouts().filter((t) => !t.frame);
}

// --- fake WebSocket ---
let sockets = [];
class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  constructor(url) {
    this.url = url;
    this.readyState = FakeWebSocket.CONNECTING;
    this.sent = [];
    sockets.push(this);
  }
  send(data) {
    if (this.readyState !== FakeWebSocket.OPEN) throw new Error("send on a socket that is not open");
    this.sent.push({ at: clock.now, msg: JSON.parse(data) });
  }
  close(code, reason) {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose({ code, reason: reason || "" });
  }
  // Test controls
  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen();
  }
  serverClose(code) {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose({ code, reason: "" });
  }
  deliver(frame) {
    this.onmessage({ data: JSON.stringify(frame) });
  }
  types() {
    return this.sent.map((s) => s.msg.type);
  }
  events() {
    return this.sent.filter((s) => s.msg.type === "event").map((s) => s.msg);
  }
  // The decoded Msg of every event sent.
  msgs() {
    return this.events().map((e) => JSON.parse(e.data).__beacon_msg);
  }
}
globalThis.WebSocket = FakeWebSocket;

// --- console capture ---
const realConsole = { log: console.log, warn: console.warn, error: console.error };
let logs = [];
for (const level of ["log", "warn", "error"]) {
  console[level] = (...args) => logs.push({ level, text: args.map(String).join(" ") });
}
function logsMatching(level, text) {
  return logs.filter((l) => l.level === level && l.text.includes(text));
}
function errorsMatching(text) {
  return logsMatching("error", text);
}

// --- fake DOM ---
class FakeNode {
  constructor(nodeType) {
    this.nodeType = nodeType;
    this.parentNode = null;
  }
  get nextSibling() {
    if (!this.parentNode) return null;
    const siblings = this.parentNode.childNodes;
    return siblings[siblings.indexOf(this) + 1] || null;
  }
}

class FakeText extends FakeNode {
  constructor(text) {
    super(3);
    this.textContent = text;
  }
  cloneNode() {
    return new FakeText(this.textContent);
  }
}

// Supports "*", "#id", "[attr]", '[attr="value"]' and "tag[attr]".
function matcher(selector) {
  if (selector === "*") return () => true;
  if (selector.startsWith("#")) return (el) => el.id === selector.slice(1);
  const m = /^([a-z]*)\[([^\]="]+)(?:="((?:[^"\\]|\\.)*)")?\]$/.exec(selector);
  if (!m) throw new Error("fake DOM: unsupported selector " + selector);
  const tag = m[1].toUpperCase();
  const value = m[3] === undefined ? undefined : m[3].replace(/\\(.)/g, "$1");
  return (el) =>
    (tag === "" || el.tagName === tag) &&
    el.hasAttribute(m[2]) &&
    (value === undefined || el.getAttribute(m[2]) === value);
}

class FakeElement extends FakeNode {
  constructor(tagName, nodeType = 1) {
    super(nodeType);
    this.tagName = tagName.toUpperCase();
    this.attributes = [];
    this.childNodes = [];
  }
  get firstChild() {
    return this.childNodes[0] || null;
  }
  get id() {
    return this.getAttribute("id") || "";
  }
  getAttribute(name) {
    const attr = this.attributes.find((a) => a.name === name);
    return attr ? attr.value : null;
  }
  hasAttribute(name) {
    return this.attributes.some((a) => a.name === name);
  }
  setAttribute(name, value) {
    const attr = this.attributes.find((a) => a.name === name);
    if (attr) attr.value = String(value);
    else this.attributes.push({ name, value: String(value) });
  }
  removeAttribute(name) {
    this.attributes = this.attributes.filter((a) => a.name !== name);
  }
  appendChild(child) {
    return this.insertBefore(child, null);
  }
  insertBefore(child, ref) {
    if (child.nodeType === 11) {
      for (const c of [...child.childNodes]) this.insertBefore(c, ref);
      return child;
    }
    if (child.parentNode) child.parentNode.removeChild(child);
    const index = ref ? this.childNodes.indexOf(ref) : -1;
    if (ref && index < 0) throw new Error("fake DOM: insertBefore reference is not a child");
    if (index < 0) this.childNodes.push(child);
    else this.childNodes.splice(index, 0, child);
    child.parentNode = this;
    return child;
  }
  removeChild(child) {
    const index = this.childNodes.indexOf(child);
    if (index < 0) throw new Error("fake DOM: removeChild of a node that is not a child");
    this.childNodes.splice(index, 1);
    child.parentNode = null;
    return child;
  }
  cloneNode(deep) {
    const copy = new FakeElement(this.tagName, this.nodeType);
    copy.attributes = this.attributes.map((a) => ({ ...a }));
    if (deep) for (const c of this.childNodes) copy.appendChild(c.cloneNode(true));
    return copy;
  }
  contains(node) {
    for (let n = node; n; n = n.parentNode) if (n === this) return true;
    return false;
  }
  querySelectorAll(selector) {
    const match = matcher(selector);
    const out = [];
    const walk = (el) => {
      for (const c of el.childNodes) {
        if (c.nodeType !== 1) continue;
        if (match(c)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
  closest(selector) {
    const match = matcher(selector);
    for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (match(n)) return n;
    return null;
  }
  get textContent() {
    return this.childNodes.map((c) => c.textContent).join("");
  }
  set textContent(text) {
    for (const c of this.childNodes) c.parentNode = null;
    this.childNodes = [];
    if (text !== "") this.appendChild(new FakeText(text));
  }
  // Like the DOM, the value property follows the attribute until it is set.
  get value() {
    if (this._value !== undefined) return this._value;
    if (this.tagName === "TEXTAREA") return this.textContent;
    return this.getAttribute("value") ?? "";
  }
  set value(v) {
    this._value = String(v);
  }
  get checked() {
    return this._checked !== undefined ? this._checked : this.hasAttribute("checked");
  }
  set checked(v) {
    this._checked = v === true;
  }
  focus() {
    document.activeElement = this;
  }
}

const VOID_TAGS = new Set(["input", "br", "img", "hr", "meta", "link"]);
function decodeEntities(text) {
  return text
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&");
}
// Parses the markup the fake views produce into `parent`. Anything it does
// not understand throws, so a test cannot pass on half-parsed markup.
function parseInto(parent, html) {
  const re = /<\/([a-zA-Z0-9-]+)\s*>|<([a-zA-Z0-9-]+)((?:\s+[^\s=>/]+(?:="[^"]*")?)*)\s*(\/?)>|([^<]+)/g;
  const stack = [parent];
  let end = 0;
  let m;
  while ((m = re.exec(html))) {
    if (m.index !== end) throw new Error("fake DOM: cannot parse " + JSON.stringify(html.slice(end)));
    end = re.lastIndex;
    const top = stack[stack.length - 1];
    if (m[1]) {
      if (top.tagName !== m[1].toUpperCase()) throw new Error(`fake DOM: </${m[1]}> closes <${top.tagName}>`);
      stack.pop();
    } else if (m[2]) {
      const el = new FakeElement(m[2]);
      const attrRe = /([^\s=>/]+)(?:="([^"]*)")?/g;
      let a;
      while ((a = attrRe.exec(m[3]))) el.setAttribute(a[1], decodeEntities(a[2] ?? ""));
      top.appendChild(el);
      if (!VOID_TAGS.has(m[2].toLowerCase()) && !m[4]) stack.push(el);
    } else {
      top.appendChild(new FakeText(decodeEntities(m[5])));
    }
  }
  if (end !== html.length) throw new Error("fake DOM: cannot parse " + JSON.stringify(html.slice(end)));
  if (stack.length !== 1) throw new Error("fake DOM: unclosed <" + stack[stack.length - 1].tagName + ">");
}

function createElement(tag) {
  const el = new FakeElement(tag);
  if (tag === "template") {
    el.content = new FakeElement("#fragment", 11);
    Object.defineProperty(el, "innerHTML", { set: (html) => parseInto(el.content, html) });
  }
  return el;
}

class FakeFormData {
  constructor(form, submitter) {
    this.pairs = form
      .querySelectorAll("*")
      .filter((el) => (el.tagName === "INPUT" || el.tagName === "TEXTAREA") && el.hasAttribute("name"))
      .map((el) => [el.getAttribute("name"), el.value]);
    if (submitter && submitter.hasAttribute("name")) {
      this.pairs.push([submitter.getAttribute("name"), submitter.getAttribute("value") ?? ""]);
    }
  }
  entries() {
    return this.pairs[Symbol.iterator]();
  }
}
globalThis.FormData = FakeFormData;
globalThis.CSS = { escape: (s) => String(s).replace(/(["\\])/g, "\\$1") };

let root = null;
let documentListeners = [];
let windowListeners = [];
const historyLog = { pushed: [], replaced: [] };

function setPath(path) {
  const q = path.indexOf("?");
  location.pathname = q < 0 ? path : path.slice(0, q);
  location.search = q < 0 ? "" : path.slice(q);
}

// Dispatch a DOM event the way the browser does for listeners on document:
// capture-phase listeners first, then bubble-phase ones.
function fire(target, type, props = {}) {
  const event = {
    type,
    target,
    bubbles: true,
    button: 0,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true;
    },
    ...props,
  };
  for (const capture of [true, false]) {
    for (const l of documentListeners.filter((l) => l.name === type && l.capture === capture)) l.fn(event);
  }
  return event;
}

function el(selector) {
  const found = root.querySelector(selector);
  assert.ok(found, "no element matches " + selector);
  return found;
}

// --- fake generated entry ---
const ok = (value) => ({ isOk: () => true, 0: value });
const err = (error) => ({ isOk: () => false, 0: error });

let reloads = 0;
let decoded = [];
let renders = 0;

// spec.view(model, local) returns { html, handlers }, each handler being
// { name, id, decode(event) -> Result, prevent, stop, debounce, throttle }.
// spec.simple adds spec.update; spec.state.crash makes update_local throw.
function makeApp(spec = {}) {
  const view = spec.view || (() => ({ html: "", handlers: [] }));
  const app = {
    decode_model(json) {
      const value = JSON.parse(json);
      if (value.bad === true) return err("bad model");
      decoded.push(value);
      return ok(value);
    },
    init_local: () => null,
    render(model, local) {
      renders++;
      const out = view(model, local);
      return [out.html, new Map(out.handlers.map((h) => [h.name + ":" + h.id, h]))];
    },
    lookup_handler: (table, name, id) => (table.has(name + ":" + id) ? ok(table.get(name + ":" + id)) : err(undefined)),
    run_handler: (handler, event) => handler.decode(event),
    handler_options: (h) => [h.prevent === true, h.stop === true, h.debounce || 0, h.throttle || 0],
    event_names: (table) => ({ toArray: () => [...new Set([...table.values()].map((h) => h.name))] }),
    update_local(model, local, msg) {
      if (spec.state && spec.state.crash) throw new Error("boom");
      return [local, msg.local !== true];
    },
    encode_msg: (msg) => JSON.stringify({ __beacon_msg: msg }),
    same_model: (a, b) => JSON.stringify(a) === JSON.stringify(b),
    is_simple: () => spec.simple === true,
  };
  if (spec.simple && spec.update) app.update = spec.update;
  return app;
}

function freshGlobals(options = {}) {
  timers = [];
  sockets = [];
  logs = [];
  reloads = 0;
  decoded = [];
  renders = 0;
  documentListeners = [];
  windowListeners = [];
  historyLog.pushed = [];
  historyLog.replaced = [];
  clock.now = 1_000_000;
  root = new FakeElement("div");
  root.setAttribute("id", "beacon-app");
  parseInto(root, options.ssr || "");
  globalThis.location = {
    protocol: "http:",
    host: "localhost",
    hostname: "localhost",
    pathname: "/",
    search: "",
    reload: () => {
      reloads++;
    },
  };
  setPath(options.path || "/");
  globalThis.history = {
    pushState(_state, _title, path) {
      historyLog.pushed.push(path);
      setPath(path);
    },
    replaceState(_state, _title, path) {
      historyLog.replaced.push(path);
      setPath(path);
    },
  };
  globalThis.document = {
    readyState: "complete",
    activeElement: null,
    querySelector: (selector) => (selector === "#beacon-app" ? (options.noRoot ? null : root) : root.querySelector(selector)),
    addEventListener(name, fn, opt) {
      documentListeners.push({ name, fn, capture: opt === true || (typeof opt === "object" && opt.capture === true) });
    },
    createElement,
  };
  globalThis.window = {
    location: globalThis.location,
    addEventListener(name, fn) {
      windowListeners.push({ name, fn });
    },
  };
}

let loadSeq = 0;
async function loadModule(options = {}) {
  freshGlobals(options);
  const url = pathToFileURL(join(WORK, "beacon_client_ffi.mjs")).href + "?instance=" + ++loadSeq;
  return import(url);
}

// Load a fresh runtime and start it with the fake app of `options`.
async function loadRuntime(options = {}) {
  const runtime = await loadModule(options);
  runtime.start(makeApp(options));
  assert.equal(sockets.length, 1, "runtime connects on start");
  return runtime;
}

function sync(socket, version, model, ackClock = 0) {
  socket.deliver({ type: "model_sync", model: JSON.stringify(model), version, ack_clock: ackClock });
}
function patch(socket, version, ops, ackClock = 0) {
  socket.deliver({ type: "patch", ops: JSON.stringify(ops), version, ack_clock: ackClock });
}
function event(clockValue) {
  return { type: "event", name: "click", handler_id: "h", data: "{}", target_path: "0", clock: clockValue };
}
function reconnectDelay() {
  const pending = reconnectTimers();
  assert.equal(pending.length, 1, "exactly one reconnect timer");
  return pending[0].at - clock.now;
}
function assertWindowBudget(socket, limit) {
  const charged = socket.sent.filter((s) => s.msg.type !== "heartbeat").map((s) => ({
    at: s.at,
    cost: s.msg.type === "event_batch" ? Math.max(s.msg.events.length, 1) : 1,
  }));
  for (const start of charged) {
    const used = charged.filter((c) => c.at >= start.at && c.at < start.at + 1000).reduce((n, c) => n + c.cost, 0);
    assert.ok(used <= limit, `window at ${start.at} carries ${used} > ${limit}`);
  }
}

const scenarios = [];
function scenario(name, fn) {
  scenarios.push({ name, fn });
}

// --- startup ---
scenario("a bundle without a complete generated app is reported and never connects", async () => {
  const runtime = await loadModule();
  runtime.start(undefined);
  assert.equal(errorsMatching("not interactive").length, 1);
  assert.ok(errorsMatching("gleam run -m beacon/build").length === 1);
  runtime.start({ decode_model() {} });
  assert.equal(errorsMatching("missing exports: init_local, render").length, 1);
  runtime.start(makeApp({ simple: true }));
  assert.equal(errorsMatching("missing exports: update").length, 1, "a simple app must export update");
  assert.equal(sockets.length, 0, "no connection without a usable app");
  assert.equal(documentListeners.length, 0, "no listeners without a usable app");
  runtime.start(makeApp());
  assert.equal(sockets.length, 1);
  assert.throws(() => runtime.start(makeApp()), /start called twice/);
});

scenario("a page without #beacon-app is reported and never connects", async () => {
  const runtime = await loadModule({ noRoot: true });
  runtime.start(makeApp());
  assert.equal(errorsMatching("No #beacon-app").length, 1);
  assert.equal(sockets.length, 0);
});

scenario("the socket URL carries the page path, on reconnect too", async () => {
  await loadRuntime({ path: "/items/3?q=a b" });
  assert.equal(sockets[0].url, "ws://localhost/ws?path=%2Fitems%2F3%3Fq%3Da%20b");
  sockets[0].open();
  assert.deepEqual(sockets[0].sent[0].msg, { type: "join", token: "", path: "/items/3?q=a b" });
  sync(sockets[0], 0, {});
  sockets[0].deliver({ type: "navigate", path: "/other" });
  sockets[0].serverClose(1006);
  advance(reconnectDelay());
  assert.equal(sockets[1].url, "ws://localhost/ws?path=%2Fother");
});

// --- close codes ---
scenario("4401 stops reconnecting, logs an error and reloads", async () => {
  await loadRuntime();
  const s = sockets[0];
  s.open();
  s.serverClose(4401);
  assert.equal(reloads, 1);
  assert.equal(pendingTimeouts().length, 0, "no reconnect scheduled");
  assert.equal(timers.length, 0, "heartbeat stopped");
  assert.ok(errorsMatching("4401").length >= 1);
  advance(120000);
  assert.equal(sockets.length, 1, "never reconnects");
});

scenario("1008, 1009 and 1013 reconnect with growing backoff", async () => {
  await loadRuntime();
  const expected = [[1000, 2000], [2000, 3000], [4000, 5000]];
  [1008, 1009, 1013].forEach((code, i) => {
    const s = sockets[i];
    s.open();
    assert.equal(s.types()[0], "join", "join is the first frame");
    s.serverClose(code);
    const delay = reconnectDelay();
    assert.ok(delay >= expected[i][0] && delay < expected[i][1], `close ${code}: delay ${delay}`);
    advance(delay);
    assert.equal(sockets.length, i + 2, `reconnected after ${code}`);
  });
  assert.equal(reloads, 0);
});

scenario("backoff resets only after a model_sync", async () => {
  await loadRuntime();
  sockets[0].open();
  sockets[0].serverClose(1006);
  advance(reconnectDelay());
  sockets[1].open();
  sync(sockets[1], 0, { count: 0 });
  sockets[1].serverClose(1006);
  const delay = reconnectDelay();
  assert.ok(delay >= 1000 && delay < 2000, `delay after a synced connection: ${delay}`);
});

// --- heartbeats ---
scenario("heartbeats are never queued while the socket is not open", async () => {
  await loadRuntime();
  const s0 = sockets[0];
  s0.open();
  sync(s0, 0, { count: 0 });
  advance(30000);
  assert.deepEqual(s0.types(), ["join", "heartbeat"]);
  s0.readyState = FakeWebSocket.CLOSING;
  advance(90000);
  assert.deepEqual(s0.types(), ["join", "heartbeat"], "no heartbeat on a closing socket");
  s0.serverClose(1006);
  advance(reconnectDelay());
  const s1 = sockets[1];
  s1.open();
  sync(s1, 0, { count: 0 });
  assert.deepEqual(s1.types(), ["join"], "no queued heartbeat burst after reconnect");
  advance(30000);
  assert.deepEqual(s1.types(), ["join", "heartbeat"]);
});

// --- outbound pacing ---
scenario("a full outbound queue is reported and followed by a resync", async () => {
  const runtime = await loadRuntime();
  for (let i = 1; i <= 201; i++) runtime.ws_send(JSON.stringify(event(i)));
  assert.equal(errorsMatching("Outbound queue full").length, 1);
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  advance(10000);
  const events = s.events().map((e) => e.clock);
  assert.deepEqual(events, Array.from({ length: 200 }, (_, i) => i + 1), "every queued event is sent in order");
  assert.equal(s.types().at(-1), "request_sync", "resync after the queue drains");
  assertWindowBudget(s, 40);
});

scenario("events wait for model_sync and are paced, never dropped", async () => {
  const runtime = await loadRuntime();
  const s = sockets[0];
  s.open();
  runtime.ws_send(JSON.stringify(event(1)));
  assert.deepEqual(s.types(), ["join"], "events wait for the first model_sync");
  sync(s, 0, { count: 0 });
  for (let i = 2; i <= 100; i++) runtime.ws_send(JSON.stringify(event(i)));
  assert.equal(s.events().length, 39, "join + 39 events fill the budget");
  advance(5000);
  const events = s.events().map((e) => e.clock);
  assert.deepEqual(events, Array.from({ length: 100 }, (_, i) => i + 1));
  assertWindowBudget(s, 40);
  assert.equal(errorsMatching("").length, 0, "no errors");
});

scenario("an event_batch over the budget is split and paced", async () => {
  const runtime = await loadRuntime();
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  const events = Array.from({ length: 120 }, (_, i) => event(i + 1));
  runtime.ws_send(JSON.stringify({ type: "event_batch", events }));
  advance(5000);
  const batches = s.sent.filter((x) => x.msg.type === "event_batch").map((x) => x.msg.events);
  assert.ok(batches.length >= 3);
  for (const b of batches) assert.ok(b.length >= 1 && b.length <= 40, `batch of ${b.length}`);
  assert.deepEqual(batches.flat().map((e) => e.clock), events.map((e) => e.clock));
  assertWindowBudget(s, 40);
});

// --- server errors ---
scenario("Rate limited and Batch too large log an error and request a resync", async () => {
  await loadRuntime();
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  s.deliver({ type: "error", reason: "Rate limited" });
  assert.equal(errorsMatching("Rate limited").length, 1);
  assert.equal(s.types().at(-1), "request_sync");
  // The rejected message may have been the request_sync itself.
  s.deliver({ type: "error", reason: "Batch too large" });
  assert.equal(errorsMatching("Batch too large").length, 1);
  assert.equal(s.types().filter((t) => t === "request_sync").length, 2);
  s.deliver({ type: "error", reason: "Unknown handler: x" });
  assert.equal(s.types().filter((t) => t === "request_sync").length, 2, "other errors only log");
  assert.equal(errorsMatching("Unknown handler").length, 1);
});

scenario("unknown, unsupported and unparseable server frames are logged", async () => {
  await loadRuntime();
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  s.deliver({ type: "surprise" });
  assert.equal(errorsMatching("Unknown server message type").length, 1);
  s.deliver({ type: "mount", payload: "<p>old</p>" });
  assert.equal(errorsMatching("mount frame").length, 1);
  assert.equal(root.childNodes.length, 0, "a mount frame does not touch the DOM");
  s.onmessage({ data: "{not json" });
  assert.equal(errorsMatching("Failed to parse server message").length, 1);
  assert.equal(s.types().at(-1), "request_sync", "an unreadable frame may have been a patch");
});

// --- versioning ---
scenario("patch gaps resync, stale patches are ignored, acks only ack", async () => {
  await loadRuntime();
  const s = sockets[0];
  s.open();
  patch(s, 1, [{ op: "replace", path: "/count", value: 1 }]);
  assert.equal(s.types().at(-1), "request_sync", "patch before any model_sync is a gap");
  sync(s, 0, { count: 0 });
  const requests = () => s.types().filter((t) => t === "request_sync").length;
  const base = requests();
  patch(s, 1, [{ op: "replace", path: "/count", value: 1 }], 1);
  assert.deepEqual(decoded.at(-1), { count: 1 });
  patch(s, 1, [{ op: "replace", path: "/count", value: 9 }]);
  patch(s, 1, []);
  patch(s, 0, []);
  assert.deepEqual(decoded.at(-1), { count: 1 }, "stale patch not applied");
  assert.equal(requests(), base, "stale and ack frames do not resync");
  patch(s, 3, [{ op: "replace", path: "/count", value: 3 }]);
  assert.equal(requests(), base + 1, "a skipped revision resyncs");
  patch(s, 4, [{ op: "replace", path: "/count", value: 4 }]);
  patch(s, 5, []);
  assert.equal(requests(), base + 1, "one resync in flight at a time");
  assert.deepEqual(decoded.at(-1), { count: 1 }, "nothing applied across a gap");
  sync(s, 4, { count: 4 });
  sync(s, 2, { count: 2 });
  assert.deepEqual(decoded.at(-1), { count: 4 }, "older model_sync ignored");
  patch(s, 5, [{ op: "replace", path: "/count", value: 5 }]);
  assert.deepEqual(decoded.at(-1), { count: 5 });
  patch(s, "6", [{ op: "replace", path: "/count", value: 6 }]);
  assert.equal(requests(), base + 2, "invalid version resyncs");
});

scenario("model_sync decode failures resync at most 3 times, then stop", async () => {
  await loadRuntime();
  const s = sockets[0];
  s.open();
  for (let i = 0; i < 5; i++) sync(s, 0, { bad: true });
  assert.equal(s.types().filter((t) => t === "request_sync").length, 3);
  assert.equal(errorsMatching("no more resyncs").length, 2);
  patch(s, 1, [{ op: "replace", path: "/count", value: 1 }]);
  assert.equal(s.types().filter((t) => t === "request_sync").length, 3, "gave up: no further requests");
  s.serverClose(1006);
  advance(reconnectDelay());
  const s1 = sockets[1];
  s1.open();
  sync(s1, 0, { count: 7 });
  assert.deepEqual(decoded.at(-1), { count: 7 }, "a new connection starts over");
});

// --- event dispatch ---
const counterView = (model) => ({
  html: `<button data-beacon-on-click="0.0">${model.count}</button><span data-beacon-on-click="0.1">local</span>`,
  handlers: [
    { name: "click", id: "0.0", decode: () => ok({ inc: 1 }) },
    { name: "click", id: "0.1", decode: () => ok({ local: true }) },
  ],
});

scenario("a click runs its decoder and sends the encoded Msg with the position id", async () => {
  await loadRuntime({ ssr: '<button data-beacon-on-click="0.0">0</button>', view: counterView });
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  const button = el('[data-beacon-on-click="0.0"]');
  fire(button, "click");
  assert.deepEqual(s.events()[0], {
    type: "event",
    name: "click",
    handler_id: "0.0",
    data: '{"__beacon_msg":{"inc":1}}',
    target_path: "0.0",
    clock: 1,
  });
  fire(button.firstChild, "click");
  assert.equal(s.events().length, 2, "a click on a text node reaches its element's handler");
  const outside = new FakeElement("button");
  outside.setAttribute("data-beacon-on-click", "0.0");
  fire(outside, "click");
  assert.equal(s.events().length, 2, "elements outside the app are ignored");
  const rendersBefore = renders;
  fire(el('[data-beacon-on-click="0.1"]'), "click");
  assert.equal(s.events().length, 2, "a Msg the Local layer handles is not sent");
  advance(16);
  assert.equal(renders, rendersBefore + 1, "a local Msg re-renders on the next frame");
  const stale = new FakeElement("i");
  stale.setAttribute("data-beacon-on-click", "9.9");
  root.appendChild(stale);
  fire(stale, "click");
  assert.equal(errorsMatching("No click handler for element 9.9").length, 1);
  assert.equal(s.events().length, 2);
});

scenario("prevent-default and stop-propagation apply among Beacon handlers", async () => {
  const view = () => ({
    html:
      '<div data-beacon-on-click="0" data-beacon-on-focus="0">' +
      '<button data-beacon-on-click="0.0">a</button><button data-beacon-on-click="0.1">b</button></div>',
    handlers: [
      { name: "click", id: "0", decode: () => ok({ outer: true }) },
      { name: "focus", id: "0", decode: () => ok({ focused: true }) },
      { name: "click", id: "0.0", prevent: true, stop: true, decode: () => ok({ inner: "a" }) },
      { name: "click", id: "0.1", decode: () => ok({ inner: "b" }) },
    ],
  });
  await loadRuntime({ view });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  const a = fire(el('[data-beacon-on-click="0.0"]'), "click");
  assert.equal(a.defaultPrevented, true);
  assert.deepEqual(s.msgs(), [{ inner: "a" }], "stop keeps the outer handler from running");
  const b = fire(el('[data-beacon-on-click="0.1"]'), "click");
  assert.equal(b.defaultPrevented, false);
  assert.deepEqual(s.msgs().slice(1), [{ inner: "b" }, { outer: true }], "innermost first, then outwards");
  fire(el('[data-beacon-on-click="0.1"]'), "focus", { bubbles: false });
  assert.equal(s.events().length, 3, "an event that does not bubble only reaches its target");
  fire(el('[data-beacon-on-focus="0"]'), "focus", { bubbles: false });
  assert.deepEqual(s.msgs().at(-1), { focused: true });
});

scenario("a decoder failure warns with the event and drops it", async () => {
  const view = () => ({
    html: '<input name="n" data-beacon-on-input="0.0">',
    handlers: [{ name: "input", id: "0.0", decode: () => err("expected Int at target.value") }],
  });
  await loadRuntime({ view });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  fire(el('[name="n"]'), "input");
  assert.equal(logsMatching("warn", "input event on element 0.0 dropped").length, 1);
  assert.equal(logsMatching("warn", "expected Int at target.value").length, 1);
  assert.equal(s.events().length, 0);
});

scenario("debounced input coalesces, and another event flushes it first", async () => {
  const view = () => ({
    html: '<input name="q" data-beacon-on-input="0.0"><button data-beacon-on-click="0.1">go</button>',
    handlers: [
      { name: "input", id: "0.0", debounce: 200, decode: (e) => ok({ q: e.target.value }) },
      { name: "click", id: "0.1", decode: () => ok({ go: true }) },
    ],
  });
  await loadRuntime({ view });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  const input = el('[name="q"]');
  for (const value of ["a", "ab", "abc"]) {
    input.value = value;
    fire(input, "input");
    advance(50);
  }
  assert.equal(s.events().length, 0, "nothing sent while typing");
  advance(149);
  assert.equal(s.events().length, 0, "the window restarts on every input");
  advance(1);
  assert.deepEqual(s.msgs(), [{ q: "abc" }], "one Msg, decoded from the last input");
  input.value = "abcd";
  fire(input, "input");
  fire(el('[data-beacon-on-click="0.1"]'), "click");
  assert.deepEqual(s.msgs().slice(1), [{ q: "abcd" }, { go: true }], "pending input goes before the click");
  advance(1000);
  assert.equal(s.events().length, 3, "a flushed Msg is not sent again");
  assert.deepEqual(s.events().map((e) => e.clock), [1, 2, 3]);
});

scenario("throttled events inside the window are dropped", async () => {
  const view = () => ({
    html: '<button data-beacon-on-click="0.0">t</button>',
    handlers: [{ name: "click", id: "0.0", throttle: 100, decode: () => ok({ tick: true }) }],
  });
  await loadRuntime({ view });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  const button = el('[data-beacon-on-click="0.0"]');
  fire(button, "click");
  advance(50);
  fire(button, "click");
  assert.equal(s.events().length, 1, "second click inside 100ms dropped");
  advance(60);
  fire(button, "click");
  assert.equal(s.events().length, 2, "a click after the window is sent");
});

scenario("submit events carry the form's fields as detail.formData", async () => {
  const view = () => ({
    html:
      '<form data-beacon-on-submit="0"><input name="title" value="x">' +
      '<button name="go" value="1">ok</button></form>',
    handlers: [{ name: "submit", id: "0", prevent: true, decode: (e) => ok({ fields: e.detail.formData }) }],
  });
  await loadRuntime({ view });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  el('[name="title"]').value = "hello";
  const submitted = fire(el("form[data-beacon-on-submit]"), "submit", { submitter: el('[name="go"]') });
  assert.equal(submitted.defaultPrevented, true);
  assert.deepEqual(s.msgs(), [{ fields: [["title", "hello"], ["go", "1"]] }]);
});

// --- pre-hydration events ---
scenario("events before the first model_sync are snapshotted and replayed", async () => {
  const view = (model) => ({
    html: `<button data-beacon-on-click="0.0">${model.count}</button><input name="q" data-beacon-on-keydown="0.1">`,
    handlers: [
      { name: "click", id: "0.0", decode: () => ok({ inc: 1 }) },
      { name: "keydown", id: "0.1", decode: (e) => ok({ key: e.key, value: e.target.value }) },
    ],
  });
  const ssr =
    '<button data-beacon-on-click="0.0" data-beacon-prevent-click="">0</button>' +
    '<input name="q" data-beacon-on-keydown="0.1"><a data-beacon-on-click="0.2">gone</a>';
  await loadRuntime({ ssr, view });
  const s = sockets[0];
  const click = fire(el('[data-beacon-on-click="0.0"]'), "click");
  assert.equal(click.defaultPrevented, true, "the SSR prevent marker applies before hydration");
  const input = el('[name="q"]');
  input.value = "hi";
  fire(input, "keydown", { key: "Enter", shiftKey: false });
  input.value = "changed later";
  fire(el('[data-beacon-on-click="0.2"]'), "click");
  s.open();
  assert.equal(s.events().length, 0, "nothing is sent before the first model_sync");
  sync(s, 0, { count: 0 });
  assert.deepEqual(s.msgs(), [{ inc: 1 }, { key: "Enter", value: "hi" }], "replayed in order, from the snapshot");
  assert.equal(logsMatching("warn", "0.2 from before hydration dropped").length, 1);
  assert.equal(logsMatching("log", "Replayed 3 event(s)").length, 1);
});

scenario("the pre-hydration queue is bounded and reports overflow", async () => {
  await loadRuntime({ ssr: '<button data-beacon-on-click="0.0">0</button>', view: counterView });
  const button = el('[data-beacon-on-click="0.0"]');
  for (let i = 0; i < 51; i++) fire(button, "click");
  assert.equal(errorsMatching("Early event queue full (50)").length, 1);
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  advance(5000);
  assert.equal(s.events().length, 50);
});

// --- simple apps ---
scenario("a simple app predicts its model and the server's model wins", async () => {
  const update = (model, msg) => ({ count: model.count + msg.inc });
  await loadRuntime({ simple: true, update, view: counterView });
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  const button = el('[data-beacon-on-click="0.0"]');
  fire(button, "click");
  advance(16);
  assert.equal(button.textContent, "1", "the prediction renders before the server answers");
  patch(s, 1, [{ op: "replace", path: "/count", value: 5 }], 1);
  assert.equal(button.textContent, "5");
  assert.equal(logsMatching("warn", "the server's model wins").length, 1);
  fire(button, "click");
  patch(s, 2, [{ op: "replace", path: "/count", value: 6 }], 2);
  assert.equal(logsMatching("warn", "the server's model wins").length, 1, "a matching prediction is not reported");
  fire(button, "click");
  advance(16);
  patch(s, 3, [{ op: "replace", path: "/count", value: 100 }], 2);
  assert.equal(button.textContent, "7", "server state that misses a pending event is held");
  sync(s, 3, { count: 7 }, 3);
  assert.equal(button.textContent, "7");
  assert.equal(logsMatching("warn", "the server's model wins").length, 1);
});

scenario("patches held for a pending simple event still advance the cached model", async () => {
  const update = (model, msg) => ({ count: model.count + msg.inc });
  await loadRuntime({ simple: true, update, view: counterView });
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  const button = el('[data-beacon-on-click="0.0"]');
  fire(button, "click");
  fire(button, "click");
  advance(16);
  assert.equal(button.textContent, "2", "both predictions render");
  patch(s, 1, [{ op: "replace", path: "/count", value: 1 }], 1);
  assert.equal(button.textContent, "2", "a patch that misses the second click does not undo it");
  patch(s, 2, [{ op: "replace", path: "/count", value: 2 }], 2);
  assert.equal(button.textContent, "2");
  assert.equal(s.types().filter((t) => t === "request_sync").length, 0, "the held patch is a base, not a gap");
  assert.equal(logsMatching("warn", "does not build on cached").length, 0);
  assert.equal(logsMatching("warn", "the server's model wins").length, 0, "the confirmed prediction matches");
  fire(button, "click");
  fire(button, "click");
  advance(16);
  assert.equal(button.textContent, "4");
  patch(s, 3, [{ op: "replace", path: "/count", value: 3 }], 3);
  assert.equal(button.textContent, "4", "held");
  patch(s, 3, [], 4);
  assert.equal(button.textContent, "3", "an ack adopts the held model");
  assert.equal(logsMatching("warn", "the server's model wins").length, 1, "the held model is checked against the prediction");
  fire(button, "click");
  advance(16);
  sync(s, 5, { count: 10 }, 4);
  assert.equal(button.textContent, "4", "a held model_sync does not undo the prediction");
  patch(s, 5, [], 5);
  assert.equal(button.textContent, "10", "the ack adopts the held model_sync");
  assert.equal(s.types().filter((t) => t === "request_sync").length, 0);
});

scenario("a click while reconnecting is sent after the held join model_sync", async () => {
  const update = (model, msg) => ({ count: model.count + msg.inc });
  await loadRuntime({ simple: true, update, view: counterView });
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 3 });
  s.serverClose(1006);
  fire(el('[data-beacon-on-click="0.0"]'), "click");
  advance(reconnectDelay());
  const s1 = sockets[1];
  s1.open();
  sync(s1, 0, { count: 3 }, 0);
  assert.equal(el('[data-beacon-on-click="0.0"]').textContent, "4", "the join model_sync does not undo the click");
  assert.equal(s1.types().filter((t) => t === "event").length, 1, "the queued click is sent once synced");
  const ackClock = s1.sent.find((x) => x.msg.type === "event").msg.clock;
  patch(s1, 1, [{ op: "replace", path: "/count", value: 4 }], ackClock);
  assert.equal(el('[data-beacon-on-click="0.0"]').textContent, "4");
  assert.equal(logsMatching("warn", "the server's model wins").length, 0);
  // Unhappy path: a click sent but never acknowledged before the socket dies.
  fire(el('[data-beacon-on-click="0.0"]'), "click");
  advance(16);
  assert.equal(el('[data-beacon-on-click="0.0"]').textContent, "5");
  s1.serverClose(1006);
  advance(reconnectDelay());
  assert.equal(logsMatching("warn", "were not acknowledged").length, 1, "the lost prediction is reported");
  const s2 = sockets[2];
  s2.open();
  sync(s2, 0, { count: 4 }, 0);
  assert.equal(el('[data-beacon-on-click="0.0"]').textContent, "4", "the new connection's model wins");
  assert.equal(s2.types().filter((t) => t === "event").length, 0, "a sent event is not resent");
});

scenario("a crash in the app's client update stops event handling loudly", async () => {
  const state = { crash: true };
  await loadRuntime({ view: counterView, state });
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  const button = el('[data-beacon-on-click="0.0"]');
  fire(button, "click");
  assert.equal(errorsMatching("client update crashed").length, 1);
  state.crash = false;
  fire(button, "click");
  assert.equal(errorsMatching("stopped after an earlier crash").length, 1);
  assert.equal(s.events().length, 0);
});

// --- focused inputs ---
scenario("a focused input keeps typed text until the server acknowledges it", async () => {
  const view = (model) => ({
    html: `<input name="q" value="${model.q}" data-beacon-on-input="0.0">`,
    handlers: [{ name: "input", id: "0.0", decode: (e) => ok({ q: e.target.value }) }],
  });
  await loadRuntime({ view });
  const s = sockets[0];
  s.open();
  sync(s, 0, { q: "" });
  const input = el('[name="q"]');
  input.focus();
  input.value = "hel";
  fire(input, "input");
  assert.equal(s.events().length, 1);
  patch(s, 1, [{ op: "replace", path: "/q", value: "he" }], 0);
  assert.equal(input.value, "hel", "an unacknowledged event keeps the typed value");
  patch(s, 2, [{ op: "replace", path: "/q", value: "hel" }], 1);
  assert.equal(input.value, "hel");
  patch(s, 3, [{ op: "replace", path: "/q", value: "server" }], 1);
  assert.equal(input.value, "server", "once acknowledged, the server's value applies");
  assert.equal(el('[name="q"]'), input, "the focused input is kept, not replaced");
});

// --- navigation ---
scenario("server navigation pushes or replaces local paths and flushes pending input", async () => {
  const view = () => ({
    html: '<input name="q" data-beacon-on-input="0.0">',
    handlers: [{ name: "input", id: "0.0", debounce: 300, decode: (e) => ok({ q: e.target.value }) }],
  });
  await loadRuntime({ view, path: "/a" });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  const input = el('[name="q"]');
  input.value = "x";
  fire(input, "input");
  s.deliver({ type: "navigate", path: "/b?x=1", replace: true });
  assert.deepEqual(historyLog.replaced, ["/b?x=1"]);
  assert.equal(location.pathname + location.search, "/b?x=1");
  assert.deepEqual(s.types().slice(-2), ["event", "navigate"], "pending input is sent before the navigate");
  assert.deepEqual(s.sent.at(-1).msg, { type: "navigate", path: "/b?x=1" });
  for (const path of ["//evil.example/x", "https://evil.example/", "javascript:alert(1)"]) {
    s.deliver({ type: "navigate", path });
  }
  assert.equal(errorsMatching("Server navigate rejected").length, 3);
  s.deliver({ type: "navigate", path: "/b?x=1" });
  assert.equal(s.types().filter((t) => t === "navigate").length, 1, "the current path is not navigated again");
  s.deliver({ type: "navigate", path: "/c" });
  assert.deepEqual(historyLog.pushed, ["/c"]);
  s.deliver({ type: "hard_navigate", path: "//evil.example/" });
  assert.equal(errorsMatching("Hard navigate rejected").length, 1);
  assert.equal(window.location.href, undefined);
  s.deliver({ type: "hard_navigate", path: "/login" });
  assert.equal(window.location.href, "/login");
});

let failures = 0;
for (const { name, fn } of scenarios) {
  try {
    await fn();
  } catch (error) {
    failures++;
    realConsole.error(`ffi scenario "${name}" failed: ${error.stack || error.message}`);
    realConsole.error(logs.map((l) => `  [${l.level}] ${l.text}`).join("\n"));
  }
}
rmSync(WORK, { recursive: true, force: true });
if (failures > 0) {
  realConsole.error(`${failures} ffi scenario failure(s)`);
  process.exit(1);
}
realConsole.log(`ffi harness ok: ${scenarios.length} scenarios`);
