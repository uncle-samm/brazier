// Behaviour checks for the browser runtime (brazier_client_ffi.mjs) without a
// browser: a fake WebSocket, fake timers, a fake clock, a small fake DOM and
// a fake generated entry.
//
// Usage: node brazier_client/test/ffi_harness.mjs
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
const WORK = mkdtempSync(join(tmpdir(), "brazier_ffi_harness_"));
mkdirSync(join(WORK, "brazier_client"));
copyFileSync(join(SRC, "brazier_client_ffi.mjs"), join(WORK, "brazier_client_ffi.mjs"));
copyFileSync(join(SRC, "brazier_client", "patch.mjs"), join(WORK, "brazier_client", "patch.mjs"));
copyFileSync(join(SRC, "brazier_client", "stream.mjs"), join(WORK, "brazier_client", "stream.mjs"));

// --- fake clock and timers ---
const clock = { now: 0 };
let timers = [];
let timerSeq = 0;
function addTimer(fn, ms, interval) {
  const t = { id: ++timerSeq, at: clock.now + Math.max(0, ms || 0), fn, interval };
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
// The client renders when an event is handled, never on an animation frame
// (frames do not run in background tabs).
globalThis.requestAnimationFrame = () => {
  throw new Error("the client must not wait for an animation frame");
};
Object.defineProperty(globalThis, "performance", {
  configurable: true,
  value: { now: () => clock.now, mark() {}, measure() {} },
});
// The reload guard stores wall-clock times: follow the fake clock.
Date.now = () => clock.now;
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
function reconnectTimers() {
  return pendingTimeouts();
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
    this.closed = { code, reason: reason || "" };
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose({ code, reason: reason || "" });
  }
  // Test controls
  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen();
  }
  serverClose(code, reason = "") {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose({ code, reason });
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
    return this.events().map((e) => JSON.parse(e.data).__brazier_msg);
  }
}
globalThis.WebSocket = FakeWebSocket;

// --- fake sessionStorage (pass the same one to the next load to simulate
// a page reload in the same tab) ---
class FakeStorage {
  constructor(entries = {}) {
    this.map = new Map(Object.entries(entries));
  }
  getItem(key) {
    return this.map.has(key) ? this.map.get(key) : null;
  }
  setItem(key, value) {
    this.map.set(key, String(value));
  }
}
const brokenStorage = {
  getItem() {
    throw new Error("SecurityError: storage is disabled");
  },
  setItem() {
    throw new Error("SecurityError: storage is disabled");
  },
};

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

// Supports "*", "#id", "tag", "[attr]", '[attr="value"]' and "tag[attr]".
function matcher(selector) {
  if (selector === "*") return () => true;
  if (selector.startsWith("#")) return (el) => el.id === selector.slice(1);
  if (/^[a-z][a-z0-9]*$/.test(selector)) return (el) => el.tagName === selector.toUpperCase();
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
    // As in a browser, taking the focused element (or an ancestor of it)
    // out of the document moves focus to the body; insertBefore of an
    // attached node does this too, since it removes the node first.
    const active = globalThis.document && document.activeElement;
    if (active && (active === child || (child.contains && child.contains(active)))) document.activeElement = null;
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
  scrollIntoView() {
    scrolls.push("#" + this.id + (this.hasAttribute("name") ? "[name=" + this.getAttribute("name") + "]" : ""));
  }
  setSelectionRange(start, end) {
    this.selectionStart = start;
    this.selectionEnd = end;
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
  const h = path.indexOf("#");
  location.hash = h < 0 ? "" : path.slice(h);
  const rest = h < 0 ? path : path.slice(0, h);
  const q = rest.indexOf("?");
  location.pathname = q < 0 ? rest : rest.slice(0, q);
  location.search = q < 0 ? "" : rest.slice(q);
}

// Back or forward to `path`: the browser sets the URL, then fires popstate
// on window.
function popTo(path) {
  setPath(path);
  for (const l of windowListeners.filter((l) => l.name === "popstate")) l.fn({ type: "popstate", state: null });
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
// What the page scrolled to: "#id" for scrollIntoView, "top" for
// window.scrollTo(0, 0).
let scrolls = [];
let decoded = [];
let renders = 0;
let itemRenders = 0;

// spec.view(model, local) returns { html, handlers, containers }, each
// handler being { name, id, decode(event) -> Result, prevent, stop,
// debounce, throttle }, and each container (in document order) a stream
// container { name, keep, limit, item } (see container). spec.streams lists
// the declared stream names. spec.simple adds spec.update; spec.state.crash
// makes update_local throw. spec.initLocal and
// spec.updateLocal(model, local, msg) -> [local, forward] replace the
// default Local layer (null local, forward unless msg.local).
function makeApp(spec = {}) {
  const view = spec.view || (() => ({ html: "", handlers: [] }));
  const streamNames = spec.streams || [];
  const app = {
    // The runtime hands decode_model the parsed `model` value of the frame
    // (or the patched cached value), never text: a string here means the
    // model JSON was parsed twice or re-stringified.
    decode_model(value) {
      if (typeof value === "string") return err("decode_model got JSON text, not a parsed value");
      if (value === null || typeof value !== "object") return err("model is not an object");
      if (value.bad === true) return err("bad model");
      decoded.push(value);
      return ok(value);
    },
    init_local: (model) => (spec.initLocal ? spec.initLocal(model) : null),
    render(model, local) {
      renders++;
      const out = view(model, local);
      const containers = out.containers || [];
      return [out.html, new Map(out.handlers.map((h) => [h.name + ":" + h.id, h])), { toArray: () => containers }];
    },
    stream_names: () => ({ toArray: () => streamNames }),
    container_name: (c) => c.name,
    container_keep: (c) => c.keep,
    container_limit: (c) => c.limit,
    container_item: (c) => c.item,
    // The generated entry decodes the item and renders it with the item
    // function; a container's `item(key, item)` returns { html, handlers }
    // or { error } for an item it cannot decode.
    render_item(c, key, item) {
      itemRenders++;
      const out = c.item(key, item);
      if (out.error !== undefined) return err(out.error);
      return ok([out.html, new Map(out.handlers.map((h) => [h.name + ":" + h.id, h]))]);
    },
    lookup_handler: (table, name, id) => (table.has(name + ":" + id) ? ok(table.get(name + ":" + id)) : err(undefined)),
    run_handler: (handler, event) => handler.decode(event),
    handler_options: (h) => [h.prevent === true, h.stop === true, h.debounce || 0, h.throttle || 0],
    event_names: (table) => ({ toArray: () => [...new Set([...table.values()].map((h) => h.name))] }),
    update_local(model, local, msg) {
      if (spec.state && spec.state.crash) throw new Error("boom");
      if (spec.updateLocal) return spec.updateLocal(model, local, msg);
      return [local, msg.local !== true];
    },
    encode_msg: (msg) => JSON.stringify({ __brazier_msg: msg }),
    same_model: (a, b) => JSON.stringify(a) === JSON.stringify(b),
    is_simple: () => spec.simple === true,
  };
  if (spec.simple && spec.update) app.update = spec.update;
  return app;
}

const TEST_BUILD = "0123456789abcdef";
const TEST_BUNDLE_URL = "http://localhost/brazier_client_" + TEST_BUILD + ".js";

function freshGlobals(options = {}) {
  timers = [];
  sockets = [];
  logs = [];
  reloads = 0;
  scrolls = [];
  decoded = [];
  renders = 0;
  itemRenders = 0;
  documentListeners = [];
  windowListeners = [];
  historyLog.pushed = [];
  historyLog.replaced = [];
  clock.now = options.now ?? 1_000_000;
  globalThis.sessionStorage = options.storage || new FakeStorage();
  root = new FakeElement("div");
  root.setAttribute("id", "brazier-app");
  // Attributes the server rendered on #brazier-app, such as
  // data-brazier-dev-build under brazier/dev.
  for (const [name, value] of Object.entries(options.rootAttributes || {})) root.setAttribute(name, value);
  parseInto(root, options.ssr || "");
  globalThis.location = {
    protocol: "http:",
    origin: "http://localhost",
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
    // The script being evaluated: the bundle the server rendered, unless a
    // scenario loads it from another URL (scriptSrc) or from no script
    // (scriptSrc: null).
    currentScript: options.scriptSrc === null ? null : { src: options.scriptSrc ?? TEST_BUNDLE_URL },
    querySelector: (selector) => (selector === "#brazier-app" ? (options.noRoot ? null : root) : root.querySelector(selector)),
    getElementById: (id) => root.querySelectorAll("*").find((node) => node.id === id) || null,
    getElementsByName: (name) => root.querySelectorAll("*").filter((node) => node.getAttribute("name") === name),
    addEventListener(name, fn, opt) {
      documentListeners.push({ name, fn, capture: opt === true || (typeof opt === "object" && opt.capture === true) });
    },
    createElement,
  };
  globalThis.window = {
    location: globalThis.location,
    __BRAZIER_ENABLE_TEST_HOOKS: options.testHooks === true,
    addEventListener(name, fn) {
      windowListeners.push({ name, fn });
    },
    scrollTo(x, y) {
      assert.deepEqual([x, y], [0, 0], "the client only scrolls to the top");
      scrolls.push("top");
    },
  };
}

let loadSeq = 0;
async function loadModule(options = {}) {
  freshGlobals(options);
  const url = pathToFileURL(join(WORK, "brazier_client_ffi.mjs")).href + "?instance=" + ++loadSeq;
  return import(url);
}

// Load a fresh runtime and start it with the fake app of `options`.
async function loadRuntime(options = {}) {
  const runtime = await loadModule(options);
  runtime.start(makeApp(options));
  assert.equal(sockets.length, 1, "runtime connects on start");
  return runtime;
}

// The server embeds the model and the ops raw: `"model":{...}`, `"ops":[...]`.
// Every frame carries the required `streams` field ([] unless given);
// NO_STREAMS leaves it out.
const NO_STREAMS = Symbol("no streams field");
function frame(fields, streams) {
  return streams === NO_STREAMS ? fields : { ...fields, streams };
}
function sync(socket, version, model, ackClock = 0, streams = []) {
  socket.deliver(frame({ type: "model_sync", model, version, ack_clock: ackClock }, streams));
}
function patch(socket, version, ops, ackClock = 0, streams = []) {
  socket.deliver(frame({ type: "patch", ops, version, ack_clock: ackClock }, streams));
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
scenario("the outbound test hook reports the queue and a scheduled send, only when enabled", async () => {
  await loadRuntime();
  assert.equal(globalThis.window.__brazierOutboundPendingForTest, undefined, "no hook without __BRAZIER_ENABLE_TEST_HOOKS");
  const runtime = await loadRuntime({ testHooks: true });
  const pending = globalThis.window.__brazierOutboundPendingForTest;
  const s = sockets[0];
  s.open();
  // Before the first model_sync, events wait in the queue.
  for (let i = 1; i <= 3; i++) runtime.ws_send(JSON.stringify(event(i)));
  assert.deepEqual(pending(), { queued: 3, scheduled: false, debounced: 0 });
  sync(s, 0, {});
  assert.deepEqual(pending(), { queued: 0, scheduled: false, debounced: 0 });
  // Over the budget, the rest waits for a scheduled paced send.
  for (let i = 4; i < 4 + 45; i++) runtime.ws_send(JSON.stringify(event(i)));
  const owed = pending();
  assert.ok(owed.queued > 0 && owed.scheduled === true && owed.debounced === 0, JSON.stringify(owed));
  advance(2000);
  assert.deepEqual(pending(), { queued: 0, scheduled: false, debounced: 0 });
});

// A debounced Msg whose timer has not fired is owed to the server just as a
// queued one is: a drained report while it waits would let a browser check
// pass before the event is ever sent.
scenario("the outbound test hook counts a debounced send until its timer fires", async () => {
  const view = () => ({
    html: '<input name="q" data-brazier-on-input="0.0">',
    handlers: [{ name: "input", id: "0.0", debounce: 200, decode: (e) => ok({ q: e.target.value }) }],
  });
  await loadRuntime({ view, testHooks: true });
  const pending = globalThis.window.__brazierOutboundPendingForTest;
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  const input = el('[name="q"]');
  input.value = "a";
  fire(input, "input");
  assert.deepEqual(pending(), { queued: 0, scheduled: false, debounced: 1 }, "the waiting input is reported");
  advance(199);
  assert.equal(s.events().length, 0);
  assert.deepEqual(pending(), { queued: 0, scheduled: false, debounced: 1 }, "still owed one tick early");
  advance(1);
  assert.deepEqual(s.msgs(), [{ q: "a" }]);
  assert.deepEqual(pending(), { queued: 0, scheduled: false, debounced: 0 }, "drained once sent");
});

scenario("a bundle without a complete generated app is reported and never connects", async () => {
  const runtime = await loadModule();
  runtime.start(undefined);
  assert.equal(errorsMatching("not interactive").length, 1);
  assert.ok(errorsMatching("gleam run -m brazier/build").length === 1);
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

scenario("a page without #brazier-app is reported and never connects", async () => {
  const runtime = await loadModule({ noRoot: true });
  runtime.start(makeApp());
  assert.equal(errorsMatching("No #brazier-app").length, 1);
  assert.equal(sockets.length, 0);
});

scenario("the socket URL carries the page path, on reconnect too", async () => {
  await loadRuntime({ path: "/items/3?q=a b" });
  assert.equal(sockets[0].url, "ws://localhost/ws?path=%2Fitems%2F3%3Fq%3Da%20b");
  sockets[0].open();
  assert.deepEqual(sockets[0].sent[0].msg, { type: "join", token: "", path: "/items/3?q=a b", build: TEST_BUILD });
  sync(sockets[0], 0, {});
  sockets[0].deliver({ type: "navigate", path: "/other" });
  sockets[0].serverClose(1006);
  advance(reconnectDelay());
  assert.equal(sockets[1].url, "ws://localhost/ws?path=%2Fother");
});

scenario("the join carries the build id of the bundle URL, on reconnect too", async () => {
  await loadRuntime({ scriptSrc: "https://cdn.example/assets/brazier_client_ABCDEF0123456789.js?v=1" });
  assert.equal(logsMatching("warn", "carries no build id").length, 0);
  sockets[0].open();
  assert.equal(sockets[0].sent[0].msg.build, "ABCDEF0123456789");
  sockets[0].serverClose(1006);
  advance(reconnectDelay());
  sockets[1].open();
  assert.equal(sockets[1].sent[0].msg.build, "ABCDEF0123456789");
});

scenario("a bundle loaded from /brazier_client.js or no script joins without a build and warns once", async () => {
  for (const scriptSrc of ["http://localhost/brazier_client.js", null]) {
    await loadRuntime({ scriptSrc });
    assert.equal(logsMatching("warn", "carries no build id").length, 1, String(scriptSrc));
    sockets[0].open();
    assert.deepEqual(sockets[0].sent[0].msg, { type: "join", token: "", path: "/" });
    sockets[0].serverClose(1006);
    advance(reconnectDelay());
    sockets[1].open();
    assert.equal("build" in sockets[1].sent[0].msg, false);
    assert.equal(logsMatching("warn", "carries no build id").length, 1, "warned once, not per join");
  }
});

// Under brazier/dev the server renders the dev build it served the page
// from; the join sends it back on every socket, so a page that was between
// sockets when the app was rebuilt learns of the rebuild on its next join.
scenario("the join carries the page's dev build, on reconnect too", async () => {
  await loadRuntime({ rootAttributes: { "data-brazier-dev-build": "00ff00ff00ff00ff" } });
  sockets[0].open();
  assert.deepEqual(sockets[0].sent[0].msg, { type: "join", token: "", path: "/", build: TEST_BUILD, dev_build: "00ff00ff00ff00ff" });
  sync(sockets[0], 0, {});
  sockets[0].serverClose(1006);
  advance(reconnectDelay());
  sockets[1].open();
  assert.equal(sockets[1].sent[0].msg.dev_build, "00ff00ff00ff00ff", "a rejoin sends the page's dev build, not a newer one");
});

scenario("a page without a dev build joins without a dev_build field", async () => {
  await loadRuntime();
  sockets[0].open();
  assert.equal("dev_build" in sockets[0].sent[0].msg, false);
});

// The server answers a join from another dev build with a reload frame
// instead of a model_sync: the page reloads before it ever syncs.
scenario("a reload frame in answer to a join reloads the page before any model_sync", async () => {
  const storage = new FakeStorage();
  await loadRuntime({ storage, rootAttributes: { "data-brazier-dev-build": "00ff00ff00ff00ff" } });
  sockets[0].open();
  sockets[0].deliver({ type: "reload" });
  assert.equal(reloads, 1);
  assert.equal(storage.getItem("brazier:reloads"), null, "a dev reload is not counted by the reload guard");
});

// --- close codes ---
scenario("4499 (stale build) reloads behind the reload guard", async () => {
  const storage = new FakeStorage();
  for (let i = 0; i < 3; i++) {
    await loadRuntime({ storage, now: 2_000_000 + i * 1000 });
    sockets[0].open();
    sockets[0].serverClose(4499);
    assert.equal(reloads, 1, `stale build ${i + 1} reloads`);
    assert.equal(pendingTimeouts().length, 0, "no reconnect scheduled");
  }
  await loadRuntime({ storage, now: 2_003_000, ssr: "<p>stale</p>" });
  sockets[0].open();
  sockets[0].serverClose(4499, "stale build");
  assert.equal(reloads, 0, "the fourth stale build within 60s does not reload");
  assert.ok(root.hasAttribute("data-brazier-error"));
  assert.equal(errorsMatching("close 4499 stale build").length, 1);
  advance(120000);
  assert.equal(sockets.length, 1, "never reconnects");
});

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

scenario("4404 reloads at most 3 times within 60s, then shows an error state", async () => {
  const storage = new FakeStorage();
  for (let i = 0; i < 3; i++) {
    await loadRuntime({ storage, now: 1_000_000 + i * 1000 });
    sockets[0].open();
    sockets[0].serverClose(4404);
    assert.equal(reloads, 1, `refusal ${i + 1} reloads`);
    assert.equal(pendingTimeouts().length, 0, "no reconnect scheduled");
  }
  assert.equal(JSON.parse(storage.getItem("brazier:reloads")).length, 3);
  await loadRuntime({ storage, now: 1_003_000, ssr: "<p>stale</p>" });
  sockets[0].open();
  sockets[0].serverClose(4404);
  assert.equal(reloads, 0, "the fourth refusal within 60s does not reload");
  assert.ok(root.hasAttribute("data-brazier-error"), "the root is marked");
  assert.equal(root.firstChild.getAttribute("role"), "alert", "a notice leads the root");
  assert.equal(errorsMatching("after 3 reloads within 60s").length, 1);
  advance(120000);
  assert.equal(sockets.length, 1, "never reconnects");
  assert.equal(reloads, 0, "never reloads");
  // Once the first reload leaves the window, one more is allowed.
  await loadRuntime({ storage, now: 1_060_000 });
  sockets[0].open();
  sockets[0].serverClose(4404);
  assert.equal(reloads, 1);
  assert.deepEqual(JSON.parse(storage.getItem("brazier:reloads")), [1_001_000, 1_002_000, 1_060_000]);
});

scenario("the reload guard fails loudly without usable sessionStorage", async () => {
  await loadRuntime({ storage: brokenStorage });
  sockets[0].open();
  sockets[0].serverClose(4403);
  assert.equal(reloads, 0, "no unguarded reload");
  assert.ok(root.hasAttribute("data-brazier-error"));
  assert.equal(errorsMatching("cannot read sessionStorage").length, 1);
  await loadRuntime({ storage: new FakeStorage({ "brazier:reloads": "{oops" }) });
  sockets[0].open();
  sockets[0].serverClose(4401);
  assert.equal(reloads, 0);
  assert.ok(root.hasAttribute("data-brazier-error"));
  assert.equal(errorsMatching("is invalid").length, 1);
  advance(120000);
  assert.equal(sockets.length, 1, "never reconnects");
});

scenario("4503 and 1011 back off up to 30s and never reload", async () => {
  await loadRuntime();
  const codes = [4503, 1011, 4503, 1011, 4503, 1011, 4503, 1011];
  codes.forEach((code, i) => {
    const s = sockets[i];
    s.open();
    s.serverClose(code);
    const delay = reconnectDelay();
    const base = Math.min(1000 * 2 ** i, 30000);
    assert.ok(delay >= base && delay < base + 1000, `close ${code} #${i + 1}: delay ${delay}`);
    advance(delay);
  });
  assert.equal(sockets.length, codes.length + 1);
  assert.equal(reloads, 0);
  assert.ok(!root.hasAttribute("data-brazier-error"));
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

scenario("a title frame sets document.title; one without a string title is logged", async () => {
  await loadRuntime();
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  s.deliver({ type: "title", title: "Inbox (3)" });
  assert.equal(document.title, "Inbox (3)");
  s.deliver({ type: "title", title: 3 });
  assert.equal(errorsMatching("no string title").length, 1);
  assert.equal(document.title, "Inbox (3)", "a malformed title frame changes nothing");
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
  html: `<button data-brazier-on-click="0.0">${model.count}</button><span data-brazier-on-click="0.1">local</span>`,
  handlers: [
    { name: "click", id: "0.0", decode: () => ok({ inc: 1 }) },
    { name: "click", id: "0.1", decode: () => ok({ local: true }) },
  ],
});

scenario("a click runs its decoder and sends the encoded Msg with the position id", async () => {
  await loadRuntime({ ssr: '<button data-brazier-on-click="0.0">0</button>', view: counterView });
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  const button = el('[data-brazier-on-click="0.0"]');
  fire(button, "click");
  assert.deepEqual(s.events()[0], {
    type: "event",
    name: "click",
    handler_id: "0.0",
    data: '{"__brazier_msg":{"inc":1}}',
    target_path: "0.0",
    clock: 1,
  });
  fire(button.firstChild, "click");
  assert.equal(s.events().length, 2, "a click on a text node reaches its element's handler");
  const outside = new FakeElement("button");
  outside.setAttribute("data-brazier-on-click", "0.0");
  fire(outside, "click");
  assert.equal(s.events().length, 2, "elements outside the app are ignored");
  const rendersBefore = renders;
  fire(el('[data-brazier-on-click="0.1"]'), "click");
  assert.equal(s.events().length, 2, "a Msg the Local layer handles is not sent");
  assert.equal(renders, rendersBefore + 1, "a local Msg re-renders before the event returns");
  const stale = new FakeElement("i");
  stale.setAttribute("data-brazier-on-click", "9.9");
  root.appendChild(stale);
  fire(stale, "click");
  assert.equal(errorsMatching("No click handler for element 9.9").length, 1);
  assert.equal(s.events().length, 2);
});

scenario("prevent-default and stop-propagation apply among Brazier handlers", async () => {
  const view = () => ({
    html:
      '<div data-brazier-on-click="0" data-brazier-on-focus="0">' +
      '<button data-brazier-on-click="0.0">a</button><button data-brazier-on-click="0.1">b</button></div>',
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
  const a = fire(el('[data-brazier-on-click="0.0"]'), "click");
  assert.equal(a.defaultPrevented, true);
  assert.deepEqual(s.msgs(), [{ inner: "a" }], "stop keeps the outer handler from running");
  const b = fire(el('[data-brazier-on-click="0.1"]'), "click");
  assert.equal(b.defaultPrevented, false);
  assert.deepEqual(s.msgs().slice(1), [{ inner: "b" }, { outer: true }], "innermost first, then outwards");
  fire(el('[data-brazier-on-click="0.1"]'), "focus", { bubbles: false });
  assert.equal(s.events().length, 3, "an event that does not bubble only reaches its target");
  fire(el('[data-brazier-on-focus="0"]'), "focus", { bubbles: false });
  assert.deepEqual(s.msgs().at(-1), { focused: true });
});

scenario("a decoder failure warns with the event and drops it", async () => {
  const view = () => ({
    html: '<input name="n" data-brazier-on-input="0.0">',
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
    html: '<input name="q" data-brazier-on-input="0.0"><button data-brazier-on-click="0.1">go</button>',
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
  fire(el('[data-brazier-on-click="0.1"]'), "click");
  assert.deepEqual(s.msgs().slice(1), [{ q: "abcd" }, { go: true }], "pending input goes before the click");
  advance(1000);
  assert.equal(s.events().length, 3, "a flushed Msg is not sent again");
  assert.deepEqual(s.events().map((e) => e.clock), [1, 2, 3]);
});

scenario("throttled events inside the window are dropped", async () => {
  const view = () => ({
    html: '<button data-brazier-on-click="0.0">t</button>',
    handlers: [{ name: "click", id: "0.0", throttle: 100, decode: () => ok({ tick: true }) }],
  });
  await loadRuntime({ view });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  const button = el('[data-brazier-on-click="0.0"]');
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
      '<form data-brazier-on-submit="0"><input name="title" value="x">' +
      '<button name="go" value="1">ok</button></form>',
    handlers: [{ name: "submit", id: "0", prevent: true, decode: (e) => ok({ fields: e.detail.formData }) }],
  });
  await loadRuntime({ view });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  el('[name="title"]').value = "hello";
  const submitted = fire(el("form[data-brazier-on-submit]"), "submit", { submitter: el('[name="go"]') });
  assert.equal(submitted.defaultPrevented, true);
  assert.deepEqual(s.msgs(), [{ fields: [["title", "hello"], ["go", "1"]] }]);
});

scenario("each event renders before it returns, so the next one runs current handlers", async () => {
  // The submit handler closes over the draft, as `on_submit(fn(_) { Add(local.draft) })` does.
  const view = (_model, local) => ({
    html:
      '<form data-brazier-on-submit="0"><input name="draft" value="' + local.draft + '" data-brazier-on-input="0.0">' +
      (local.removed ? "" : '<button data-brazier-on-click="0.1">x</button>') +
      "</form>",
    handlers: [
      { name: "input", id: "0.0", decode: (e) => ok({ draft: e.target.value }) },
      { name: "submit", id: "0", prevent: true, decode: () => ok({ add: local.draft }) },
      { name: "click", id: "0.1", decode: () => ok({ removeButton: true }) },
    ],
  });
  const updateLocal = (_model, local, msg) => {
    if (msg.draft !== undefined) return [{ ...local, draft: msg.draft }, false];
    if (msg.removeButton) return [{ ...local, removed: true }, false];
    return [local, true];
  };
  const spec = { view, updateLocal, initLocal: () => ({ draft: "", removed: false }) };
  await loadRuntime(spec);
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  const input = el('[name="draft"]');
  document.activeElement = input;
  for (const typed of ["m", "mi", "milk"]) {
    const before = renders;
    input.value = typed;
    fire(input, "input");
    assert.equal(renders, before + 1, "a handled input renders before the event returns");
    assert.equal(input.value, typed, "the focused input keeps what was typed");
  }
  fire(el("form[data-brazier-on-submit]"), "submit");
  assert.deepEqual(s.msgs(), [{ add: "milk" }], "the submit right after the input sees its draft");

  // Unhappy path: an event on an element the last render removed is ignored.
  const button = el('[data-brazier-on-click="0.1"]');
  fire(button, "click");
  assert.equal(root.querySelector('[data-brazier-on-click="0.1"]'), null, "the click's render removed the button");
  const rendersAfterRemoval = renders;
  fire(button, "click");
  assert.equal(renders, rendersAfterRemoval, "a click on the removed button does nothing");
  assert.deepEqual(s.msgs(), [{ add: "milk" }]);
  assert.equal(errorsMatching("invariant").length, 0);

  // Replayed early events render one by one too: the replayed submit sees
  // the draft of the replayed input before it, not the server-rendered page's.
  await loadRuntime({ ...spec, ssr: view(null, { draft: "", removed: false }).html });
  const early = sockets[0];
  early.open();
  const earlyInput = el('[name="draft"]');
  earlyInput.value = "eggs";
  fire(earlyInput, "input");
  fire(el("form[data-brazier-on-submit]"), "submit");
  sync(early, 0, {});
  assert.deepEqual(early.msgs(), [{ add: "eggs" }]);
});

scenario("an element that gains autofocus in a render is focused, once", async () => {
  // Browsers honour autofocus only at page load, so the client focuses it.
  const view = (_model, local) => ({
    html:
      '<button data-brazier-on-click="0">go</button>' +
      (local.stage >= 1 ? '<div data-board="" tabindex="0" autofocus=""></div>' : "") +
      (local.stage >= 2 ? '<input name="later">' : "") +
      '<input name="name"' + (local.stage >= 3 ? ' autofocus=""' : "") + ">",
    handlers: [{ name: "click", id: "0", decode: () => ok({ next: true }) }],
  });
  const updateLocal = (_model, local, msg) => (msg.next ? [{ ...local, stage: local.stage + 1 }, false] : [local, true]);
  await loadRuntime({ view, updateLocal, initLocal: () => ({ stage: 0 }) });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  assert.equal(root.querySelector("[autofocus]"), null);

  // An inserted element with autofocus takes focus.
  const button = el('[data-brazier-on-click="0"]');
  document.activeElement = button;
  fire(button, "click");
  assert.equal(document.activeElement, el("[data-board]"), "the inserted board is focused");

  // Unhappy path: an element that already had autofocus is not refocused.
  const other = el('[name="name"]');
  document.activeElement = other;
  fire(button, "click");
  assert.ok(el('[name="later"]'), "the render ran");
  assert.equal(document.activeElement, other, "an unchanged autofocus leaves focus alone");

  // An existing element that gains the attribute takes focus.
  document.activeElement = button;
  fire(button, "click");
  assert.equal(document.activeElement, el('[name="name"]'), "the element that gained autofocus is focused");
  assert.deepEqual(s.msgs(), [], "Local handled every click");
});

// --- pre-hydration events ---
scenario("events before the first model_sync are snapshotted and replayed", async () => {
  const view = (model) => ({
    html: `<button data-brazier-on-click="0.0">${model.count}</button><input name="q" data-brazier-on-keydown="0.1">`,
    handlers: [
      { name: "click", id: "0.0", decode: () => ok({ inc: 1 }) },
      { name: "keydown", id: "0.1", decode: (e) => ok({ key: e.key, value: e.target.value }) },
    ],
  });
  const ssr =
    '<button data-brazier-on-click="0.0" data-brazier-prevent-click="">0</button>' +
    '<input name="q" data-brazier-on-keydown="0.1"><a data-brazier-on-click="0.2">gone</a>';
  await loadRuntime({ ssr, view });
  const s = sockets[0];
  const click = fire(el('[data-brazier-on-click="0.0"]'), "click");
  assert.equal(click.defaultPrevented, true, "the SSR prevent marker applies before hydration");
  const input = el('[name="q"]');
  input.value = "hi";
  fire(input, "keydown", { key: "Enter", shiftKey: false });
  input.value = "changed later";
  fire(el('[data-brazier-on-click="0.2"]'), "click");
  s.open();
  assert.equal(s.events().length, 0, "nothing is sent before the first model_sync");
  sync(s, 0, { count: 0 });
  assert.deepEqual(s.msgs(), [{ inc: 1 }, { key: "Enter", value: "hi" }], "replayed in order, from the snapshot");
  assert.equal(logsMatching("warn", "0.2 from before hydration dropped").length, 1);
  assert.equal(logsMatching("log", "Replayed 3 event(s)").length, 1);
});

scenario("the pre-hydration queue is bounded and reports overflow", async () => {
  await loadRuntime({ ssr: '<button data-brazier-on-click="0.0">0</button>', view: counterView });
  const button = el('[data-brazier-on-click="0.0"]');
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
  const button = el('[data-brazier-on-click="0.0"]');
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
  const button = el('[data-brazier-on-click="0.0"]');
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
  fire(el('[data-brazier-on-click="0.0"]'), "click");
  advance(reconnectDelay());
  const s1 = sockets[1];
  s1.open();
  sync(s1, 0, { count: 3 }, 0);
  assert.equal(el('[data-brazier-on-click="0.0"]').textContent, "4", "the join model_sync does not undo the click");
  assert.equal(s1.types().filter((t) => t === "event").length, 1, "the queued click is sent once synced");
  const ackClock = s1.sent.find((x) => x.msg.type === "event").msg.clock;
  patch(s1, 1, [{ op: "replace", path: "/count", value: 4 }], ackClock);
  assert.equal(el('[data-brazier-on-click="0.0"]').textContent, "4");
  assert.equal(logsMatching("warn", "the server's model wins").length, 0);
  // Unhappy path: a click sent but never acknowledged before the socket dies.
  fire(el('[data-brazier-on-click="0.0"]'), "click");
  advance(16);
  assert.equal(el('[data-brazier-on-click="0.0"]').textContent, "5");
  s1.serverClose(1006);
  advance(reconnectDelay());
  assert.equal(logsMatching("warn", "were not acknowledged").length, 1, "the lost prediction is reported");
  const s2 = sockets[2];
  s2.open();
  sync(s2, 0, { count: 4 }, 0);
  assert.equal(el('[data-brazier-on-click="0.0"]').textContent, "4", "the new connection's model wins");
  assert.equal(s2.types().filter((t) => t === "event").length, 0, "a sent event is not resent");
});

scenario("a crash in the app's client update stops event handling loudly", async () => {
  const state = { crash: true };
  await loadRuntime({ view: counterView, state });
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  const button = el('[data-brazier-on-click="0.0"]');
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
    html: `<input name="q" value="${model.q}" data-brazier-on-input="0.0">`,
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
    html: '<input name="q" data-brazier-on-input="0.0">',
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
  assert.deepEqual(s.sent.at(-1).msg, { type: "navigate", path: "/b?x=1", clock: 2 }, "the navigate's clock follows the input event's");
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

// SEC-5: the URL parser reads "\" as "/" and strips tab, newline and
// carriage return, so each of these would load evil.example.
const OFF_ORIGIN_PATHS = ["/\\evil.example", "/\t/evil.example", "/\n/evil.example", "/\r/evil.example", "/x\\..\\\\evil.example", "/%09/evil.example", "\\\\evil.example"];

scenario("server navigate and hard_navigate refuse paths a browser resolves to another host", async () => {
  await loadRuntime({ path: "/a" });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  const navigatesBefore = s.types().filter((t) => t === "navigate").length;
  for (const path of OFF_ORIGIN_PATHS) {
    s.deliver({ type: "navigate", path });
    s.deliver({ type: "navigate", path, replace: true });
    s.deliver({ type: "hard_navigate", path });
  }
  assert.deepEqual(historyLog.pushed, [], "no refused path is pushed");
  assert.deepEqual(historyLog.replaced, [], "no refused path replaces the entry");
  assert.equal(window.location.href, undefined, "no refused path is loaded");
  assert.equal(location.pathname, "/a");
  assert.equal(s.types().filter((t) => t === "navigate").length, navigatesBefore, "nothing is sent for a refused path");
  assert.equal(errorsMatching("Server navigate rejected: not a local path (").length, 2 * OFF_ORIGIN_PATHS.length);
  assert.equal(errorsMatching("Hard navigate rejected: not a local path (").length, OFF_ORIGIN_PATHS.length);
  assert.equal(errorsMatching("control character").length, 3 * 3, "tab, newline and carriage return name their reason");
  s.deliver({ type: "hard_navigate", path: "/café?q=a%20b" });
  assert.equal(window.location.href, "/café?q=a%20b", "a same-origin path still loads");
});

// A link is intercepted only when its origin (scheme, host and port) is the
// page's: the same host on another port or scheme is another site.
scenario("link clicks are intercepted only for the page's own origin", async () => {
  const links =
    '<a id="port" href="http://localhost:8080/x">p</a>' +
    '<a id="scheme" href="https://localhost/x">s</a>' +
    '<a id="other" href="http://evil.example/x">o</a>' +
    '<a id="same" href="/b?q=1">b</a>' +
    '<a id="absolute" href="http://localhost/c">c</a>' +
    '<a id="relative" href="d">d</a>';
  await loadRuntime({ path: "/a", ssr: links, view: () => ({ html: links, handlers: [] }) });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  for (const id of ["port", "scheme", "other"]) {
    const event = fire(el("#" + id), "click");
    assert.equal(event.defaultPrevented, false, id + ": the browser loads another origin's link");
  }
  assert.deepEqual(historyLog.pushed, [], "no other-origin link is pushed");
  assert.equal(s.types().filter((t) => t === "navigate").length, 0, "nothing is sent for another origin");
  for (const id of ["same", "absolute", "relative"]) {
    const event = fire(el("#" + id), "click");
    assert.equal(event.defaultPrevented, true, id + ": a same-origin link navigates in place");
  }
  assert.deepEqual(historyLog.pushed, ["/b?q=1", "/c", "/d"]);
  assert.deepEqual(
    s.sent.filter((f) => f.msg.type === "navigate").map((f) => f.msg.path),
    ["/b?q=1", "/c", "/d"],
  );
});

scenario("a model_sync or patch without a valid ack_clock is a protocol error that resyncs", async () => {
  await loadRuntime();
  const s = sockets[0];
  s.open();
  const requests = () => s.types().filter((t) => t === "request_sync").length;
  s.deliver({ type: "model_sync", model: { count: 1 }, version: 0, streams: [] });
  assert.equal(decoded.length, 0, "a model_sync without ack_clock is not applied");
  assert.equal(errorsMatching("invalid ack_clock undefined").length, 1);
  assert.equal(requests(), 1);
  sync(s, 0, { count: 0 });
  assert.deepEqual(decoded.at(-1), { count: 0 }, "a valid model_sync recovers");
  for (const [i, ackClock] of [undefined, "1", -1, 1.5, null].entries()) {
    sync(s, i, { count: i });
    s.deliver({ type: "patch", ops: [{ op: "replace", path: "/count", value: 99 }], version: i + 1, ack_clock: ackClock, streams: [] });
    assert.deepEqual(decoded.at(-1), { count: i }, `a patch with ack_clock ${JSON.stringify(ackClock)} is not applied`);
    assert.equal(s.types().at(-1), "request_sync", `a patch with ack_clock ${JSON.stringify(ackClock)} resyncs`);
  }
  assert.equal(errorsMatching("has invalid ack_clock").length, 5);
  s.deliver({ type: "model_sync", model: { count: 7 }, version: 9, ack_clock: "9", streams: [] });
  assert.notDeepEqual(decoded.at(-1), { count: 7 }, "a model_sync with a string ack_clock is not applied");
  assert.equal(errorsMatching('invalid ack_clock "9"').length, 1);
});

scenario("a model or ops sent as JSON text instead of a raw value is refused and resyncs", async () => {
  await loadRuntime();
  const s = sockets[0];
  s.open();
  const requests = () => s.types().filter((t) => t === "request_sync").length;
  // The wire format before raw embedding: "model":"{...}" and "ops":"[...]".
  s.deliver({ type: "model_sync", model: JSON.stringify({ count: 1 }), version: 0, ack_clock: 0, streams: [] });
  assert.equal(decoded.length, 0, "a model sent as text is not adopted");
  assert.equal(errorsMatching("decode_model got JSON text").length, 1);
  assert.equal(requests(), 1);
  s.deliver({ type: "model_sync", version: 0, ack_clock: 0, streams: [] });
  assert.equal(decoded.length, 0, "a model_sync without a model is not adopted");
  assert.equal(errorsMatching("the frame has no model field").length, 1);
  assert.equal(requests(), 2);
  sync(s, 0, { count: 0 });
  assert.deepEqual(decoded.at(-1), { count: 0 }, "a raw model is adopted as parsed");
  s.deliver({ type: "patch", ops: JSON.stringify([{ op: "replace", path: "/count", value: 5 }]), version: 1, ack_clock: 0, streams: [] });
  assert.deepEqual(decoded.at(-1), { count: 0 }, "ops sent as text are not applied");
  assert.equal(errorsMatching("Patch ops are not an array (got string)").length, 1);
  assert.equal(requests(), 3);
  sync(s, 1, { count: 1 });
  patch(s, 2, [{ op: "replace", path: "/count", value: 5 }]);
  assert.deepEqual(decoded.at(-1), { count: 5 }, "raw ops patch the parsed model");
});

scenario("an event without a valid clock is refused before it is queued", async () => {
  const runtime = await loadRuntime();
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  const { clock: _dropped, ...unclocked } = event(1);
  for (const bad of [unclocked, { ...event(1), clock: "1" }, { ...event(1), clock: -1 }]) {
    assert.throws(() => runtime.ws_send(JSON.stringify(bad)), /every event needs a clock/);
    assert.throws(() => runtime.ws_send(JSON.stringify({ type: "event_batch", events: [event(2), bad] })), /every event needs a clock/);
  }
  assert.equal(s.events().length, 0, "nothing was queued");
  runtime.ws_send(JSON.stringify(event(3)));
  assert.equal(s.events().at(-1).clock, 3, "a clocked event is sent");
});

// --- hooks and render cost (PERF-1) ---
const hookView = (model) => ({
  html:
    `<ul>${model.items.map((i) => `<li>${i}</li>`).join("")}</ul>` +
    `<div id="h1" data-brazier-hook="probe" data-x="${model.x}"></div>` +
    (model.extra ? '<p><span id="h2" data-brazier-hook="probe"></span></p>' : "") +
    '<div id="late" data-brazier-hook="later"></div>' +
    '<div id="owned" data-brazier-preserve-children="true"></div>',
  handlers: [],
});

function probeHook(calls) {
  return {
    mount: (node) => calls.push("mount " + node.id),
    update: (node) => calls.push("update " + node.id),
    unmount: (node) => calls.push("unmount " + node.id),
  };
}

scenario("hooks mount, update and unmount only for what a render changed", async () => {
  await loadRuntime({ view: hookView });
  const s = sockets[0];
  s.open();
  const calls = [];
  window.brazierClient.registerHook("probe", probeHook(calls));
  const base = { items: ["a", "b"], x: 1, extra: false };
  let version = 0;
  const render = (model) => sync(s, version++, model);
  render(base);
  assert.deepEqual(calls.splice(0), ["mount h1"], "the first render mounts every registered hook element");
  render({ ...base, items: ["a", "c", "d"] });
  assert.deepEqual(calls.splice(0), [], "a render that does not touch a hook element calls no hook");
  render({ ...base, x: 2 });
  assert.deepEqual(calls.splice(0), ["update h1"], "a changed attribute updates its hook");
  render({ ...base, x: 2, extra: true });
  assert.deepEqual(calls.splice(0), ["mount h2"], "an inserted hook element mounts");
  render({ ...base, x: 2 });
  assert.deepEqual(calls.splice(0), ["unmount h2"], "a removed hook element unmounts");
  window.brazierClient.registerHook("later", probeHook(calls));
  render({ ...base, x: 2 });
  assert.deepEqual(calls.splice(0), ["mount late"], "a hook registered after its element rendered mounts on the next render");
  const inner = createElement("i");
  inner.setAttribute("id", "inner");
  inner.setAttribute("data-brazier-hook", "probe");
  el("#owned").appendChild(inner);
  render({ ...base, x: 2 });
  assert.deepEqual(calls.splice(0), ["mount inner"], "a hook element other code adds under preserve-children mounts");
  render({ ...base, x: 2 });
  assert.deepEqual(calls.splice(0), [], "an unchanged render calls no hook");
  el("#h1").setAttribute("data-x", "drifted");
  render({ ...base, x: 2 });
  assert.equal(el("#h1").getAttribute("data-x"), "2", "the morph restores a drifted attribute");
  assert.deepEqual(calls.splice(0), [], "restoring the attribute it was mounted with does not update the hook");
});

scenario("a hook unmount that removes an element the morph touched fails the render loudly", async () => {
  await loadRuntime({ view: hookView });
  const s = sockets[0];
  s.open();
  window.brazierClient.registerHook("probe", {
    unmount: (node) => {
      if (node.id === "h2") root.removeChild(el("#h1"));
    },
  });
  const base = { items: ["a"], x: 1, extra: true };
  sync(s, 0, base);
  // x changes h1's attribute (touched), then removing h2 runs its unmount.
  // The model_sync fails as any render error does, and asks for a resync.
  sync(s, 1, { ...base, x: 2, extra: false });
  const failed = errorsMatching("model_sync v1 could not be applied");
  assert.equal(failed.length, 1, "the render failure is logged");
  assert.match(failed[0].text, /invariant violated: an element the morph touched \(div#h1\) left the app root/);
  assert.equal(s.types().at(-1), "request_sync", "the client asks for a resync");
});

scenario("a render with identical markup parses it once and still morphs the DOM back", async () => {
  await loadRuntime({ view: hookView });
  const s = sockets[0];
  s.open();
  let templates = 0;
  const createTemplate = document.createElement;
  document.createElement = (tag) => {
    if (tag === "template") templates++;
    return createTemplate(tag);
  };
  const model = { items: ["a", "b"], x: 1, extra: false };
  sync(s, 0, model);
  sync(s, 1, model);
  sync(s, 2, model);
  assert.equal(templates, 1, "identical markup is parsed once");
  el("#h1").setAttribute("data-x", "drifted");
  const firstItem = () => root.childNodes[0].childNodes[0];
  firstItem().textContent = "typed";
  sync(s, 3, model);
  assert.equal(templates, 1);
  assert.equal(el("#h1").getAttribute("data-x"), "1", "the cached fragment still restores attributes");
  assert.equal(firstItem().textContent, "a", "the cached fragment still restores text");
  sync(s, 4, { ...model, x: 2 });
  assert.equal(templates, 2, "new markup is parsed");
  sync(s, 5, model);
  assert.equal(templates, 3, "only the last markup is cached");
  assert.equal(el("#h1").getAttribute("data-x"), "1");
});

scenario("a dev reload message reloads the page every time, outside the reload guard", async () => {
  const storage = new FakeStorage();
  for (let i = 0; i < 5; i++) {
    await loadRuntime({ storage });
    const s = sockets[0];
    s.open();
    sync(s, 0, {});
    s.deliver({ type: "reload" });
    assert.equal(reloads, 1, `rebuild ${i + 1} reloads`);
  }
  assert.equal(storage.getItem("brazier:reloads"), null, "a dev reload is not counted by the guard");
});

// --- hook lifecycle on an element that stays ---
// LiveView's View.performPatch: a phx-hook removed from, or renamed on, an
// element the patch keeps destroys the hook; a new name mounts its hook.
scenario("a hook element that stays but loses or renames its hook unmounts the old hook", async () => {
  const view = (model) => ({
    html:
      `<div id="h" class="${model.c}"${model.hook ? ` data-brazier-hook="${model.hook}"` : ""}>` +
      `<span id="inner"${model.innerHook ? ' data-brazier-hook="probe"' : ""}></span></div>`,
    handlers: [],
  });
  await loadRuntime({ view });
  const s = sockets[0];
  s.open();
  const calls = [];
  window.brazierClient.registerHook("probe", probeHook(calls));
  window.brazierClient.registerHook("other", {
    mount: (node) => calls.push("mount other " + node.id),
    unmount: (node) => calls.push("unmount other " + node.id),
  });
  let version = 0;
  const render = (model) => sync(s, version++, model);
  render({ hook: "probe", c: "a" });
  const h = el("#h");
  assert.deepEqual(calls.splice(0), ["mount h"]);
  render({ hook: null, c: "a" });
  assert.deepEqual(calls.splice(0), ["unmount h"], "removing the hook attribute unmounts the hook");
  assert.equal(el("#h"), h, "the element itself stays");
  render({ hook: null, c: "b" });
  assert.deepEqual(calls.splice(0), [], "an element without a hook calls no hook");
  render({ hook: "probe", c: "b" });
  assert.deepEqual(calls.splice(0), ["mount h"], "the attribute added back mounts the hook again");
  render({ hook: "other", c: "c" });
  assert.deepEqual(calls.splice(0), ["unmount h", "mount other h"], "a renamed hook unmounts the old one, then mounts the new one");
  assert.equal(el("#h"), h, "the element stays across the rename");
  render({ hook: null, c: "c", innerHook: true });
  assert.deepEqual(calls.splice(0), ["unmount other h", "mount inner"]);
  render({ hook: null, c: "c" });
  assert.deepEqual(calls.splice(0), ["unmount inner"], "a nested element that stays loses its hook too");
  assert.equal(root.querySelectorAll("[data-brazier-hook]").length, 0);
});

// --- in-page fragment links ---
// LiveView's DOM.isNewPageClick and Turbo's same-page anchors: a link to a
// fragment of the current page (same pathname and search) is the
// browser's, and so is the popstate of moving between fragments.
scenario("in-page fragment links keep the browser's default, and same-page popstate sends nothing", async () => {
  const links =
    '<a id="frag" href="#x">x</a>' +
    '<a id="self" href="/a#y">y</a>' +
    '<a id="bare" href="#">top</a>' +
    '<a id="query" href="/a?q=1#z">z</a>' +
    '<a id="other" href="/b#sec">b</a>';
  await loadRuntime({ path: "/a", ssr: links, view: () => ({ html: links, handlers: [] }) });
  const s = sockets[0];
  s.open();
  sync(s, 0, {});
  const navigates = () => s.sent.filter((f) => f.msg.type === "navigate").map((f) => f.msg.path);
  for (const id of ["frag", "self", "bare"]) {
    const event = fire(el("#" + id), "click");
    assert.equal(event.defaultPrevented, false, id + ": the browser scrolls to the fragment");
  }
  assert.deepEqual(historyLog.pushed, [], "a fragment link pushes nothing itself");
  assert.deepEqual(navigates(), [], "a fragment link is not a navigation");
  popTo("/a#x");
  popTo("/a");
  assert.deepEqual(navigates(), [], "back and forward between fragments of the page send nothing");
  const query = fire(el("#query"), "click");
  assert.equal(query.defaultPrevented, true, "another search is another page");
  assert.deepEqual(historyLog.pushed, ["/a?q=1#z"], "the fragment stays in the pushed URL");
  assert.deepEqual(navigates(), ["/a?q=1"], "the server is sent only the path");
  assert.equal(fire(el("#frag"), "click").defaultPrevented, false, "#x is now a fragment of /a?q=1");
  const other = fire(el("#other"), "click");
  assert.equal(other.defaultPrevented, true);
  assert.deepEqual(historyLog.pushed, ["/a?q=1#z", "/b#sec"]);
  assert.deepEqual(navigates(), ["/a?q=1", "/b"]);
  popTo("/b#elsewhere");
  assert.deepEqual(navigates(), ["/a?q=1", "/b"], "a fragment change on /b sends nothing");
  popTo("/a#x");
  assert.deepEqual(navigates(), ["/a?q=1", "/b", "/a"], "back to another page navigates to its path");
  popTo("/a#y");
  assert.deepEqual(navigates(), ["/a?q=1", "/b", "/a"]);
});

// --- fragment scroll after a live navigation ---
// The browser does not scroll for pushState, so a link to another page's
// #fragment scrolls once the server's answer to the navigate is rendered:
// the first applied frame whose ack_clock covers the navigate's clock. As
// LiveView's Browser.pushState: getHashTargetEl (an id, else <a name>),
// scrollIntoView, else window.scroll(0, 0).
const FRAGMENT_LINKS =
  '<a id="to-sec" href="/b#sec">s</a>' +
  '<a id="to-anchor" href="/c#old">o</a>' +
  '<a id="to-missing" href="/d#nope">n</a>' +
  '<a id="to-encoded" href="/e#caf%C3%A9">c</a>' +
  '<a id="to-plain" href="/f">f</a>' +
  '<a id="here" href="#here">h</a>';
// Page "a" has none of the targets; every other page has all of them.
function fragmentView(model) {
  const targets = model.page === "a" ? "" : '<h2 id="sec">S</h2><a name="old">o</a><p id="café">c</p>';
  return { html: FRAGMENT_LINKS + targets, handlers: [] };
}
function lastNavigate(s) {
  const found = s.sent.filter((f) => f.msg.type === "navigate");
  assert.ok(found.length > 0, "no navigate was sent");
  return found.at(-1).msg;
}

scenario("a live navigation to another page's #fragment scrolls once that page renders, or to the top", async () => {
  await loadRuntime({ path: "/a", ssr: FRAGMENT_LINKS, view: fragmentView });
  const s = sockets[0];
  s.open();
  sync(s, 0, { page: "a" });
  assert.equal(fire(el("#to-sec"), "click").defaultPrevented, true);
  assert.deepEqual(lastNavigate(s), { type: "navigate", path: "/b", clock: 1 }, "the navigate carries the next clock, no fragment");
  assert.deepEqual(scrolls, [], "nothing scrolls before the page exists");
  patch(s, 1, [{ op: "add", path: "/n", value: 1 }], 0);
  assert.deepEqual(scrolls, [], "a frame from before the navigation does not scroll");
  patch(s, 2, [{ op: "replace", path: "/page", value: "b" }], 1);
  assert.deepEqual(scrolls, ["#sec"], "the navigation's patch scrolls to the element with that id");
  patch(s, 3, [{ op: "add", path: "/n2", value: 1 }], 1);
  assert.deepEqual(scrolls, ["#sec"], "the scroll happens once");

  // A navigation that leaves the model as it was is answered by an ack.
  fire(el("#to-anchor"), "click");
  assert.equal(lastNavigate(s).clock, 2);
  patch(s, 3, [], 2);
  assert.deepEqual(scrolls, ["#sec", "#[name=old]"], "an ack covering the navigate scrolls to <a name>");

  // Unhappy path: the page has no such element.
  fire(el("#to-missing"), "click");
  patch(s, 4, [{ op: "replace", path: "/page", value: "d" }], 3);
  assert.deepEqual(scrolls.at(-1), "top", "a missing fragment scrolls to the top");
  assert.equal(logsMatching("warn", 'no element for the fragment "#nope"').length, 1, "and says so");

  // The fragment is looked up percent-decoded too, as the browser does.
  fire(el("#to-encoded"), "click");
  patch(s, 5, [{ op: "replace", path: "/page", value: "e" }], 4);
  assert.deepEqual(scrolls.at(-1), "#café");

  // A navigation without a fragment schedules nothing.
  const before = scrolls.length;
  fire(el("#to-plain"), "click");
  patch(s, 6, [{ op: "replace", path: "/page", value: "f" }], 5);
  assert.equal(scrolls.length, before, "a page without a fragment keeps the client's scroll");
  assert.equal(logsMatching("warn", "no element for the fragment").length, 1);
});

scenario("a fragment scroll waits for a held navigation, yields to newer URLs, and follows router.push", async () => {
  const update = (model, msg) => ({ ...model, count: model.count + msg.inc });
  const view = (model) => ({
    html: '<button data-brazier-on-click="0.0">' + model.count + "</button>" + fragmentView(model).html,
    handlers: [{ name: "click", id: "0.0", decode: () => ok({ inc: 1 }) }],
  });
  await loadRuntime({ simple: true, update, view, path: "/a" });
  const s = sockets[0];
  s.open();
  sync(s, 0, { page: "a", count: 0 });
  // The navigate (clock 1), then a predicted click (clock 2): the
  // navigation's patch does not acknowledge the click, so it is held, and
  // the scroll waits for the ack that adopts it.
  fire(el("#to-sec"), "click");
  fire(el('[data-brazier-on-click="0.0"]'), "click");
  assert.equal(s.events().at(-1).clock, 2);
  patch(s, 1, [{ op: "replace", path: "/page", value: "b" }], 1);
  assert.deepEqual(scrolls, [], "a held patch is not rendered, so nothing scrolls");
  patch(s, 2, [{ op: "replace", path: "/count", value: 1 }], 2);
  assert.deepEqual(scrolls, ["#sec"], "the frame that renders the page scrolls");

  // An in-page fragment link before the page arrives: the browser already
  // scrolled for the newer fragment, so the old one is dropped.
  fire(el("#to-anchor"), "click");
  assert.equal(fire(el("#here"), "click").defaultPrevented, false, "the in-page link is the browser's");
  setPath("/c#here");
  patch(s, 2, [], 3);
  assert.deepEqual(scrolls, ["#sec"], "a superseded fragment does not scroll");

  // Back and forward keep the browser's scroll restoration: popstate drops
  // a pending fragment scroll.
  fire(el("#to-sec"), "click");
  popTo("/a");
  assert.deepEqual(lastNavigate(s), { type: "navigate", path: "/a", clock: 5 });
  patch(s, 3, [{ op: "replace", path: "/page", value: "a" }], 5);
  assert.deepEqual(scrolls, ["#sec"], "a popstate navigation does not scroll");

  // router.push with a fragment: the server is sent the path, and the
  // client scrolls once the page renders.
  s.deliver({ type: "navigate", path: "/c?x=1#old" });
  assert.deepEqual(historyLog.pushed.at(-1), "/c?x=1#old");
  assert.deepEqual(lastNavigate(s), { type: "navigate", path: "/c?x=1", clock: 6 });
  patch(s, 4, [{ op: "replace", path: "/page", value: "c" }], 6);
  assert.deepEqual(scrolls, ["#sec", "#[name=old]"]);
});

scenario("a fragment navigation lost with the socket scrolls on the join; a queued one waits for its ack", async () => {
  await loadRuntime({ path: "/a", ssr: FRAGMENT_LINKS, view: fragmentView });
  const s = sockets[0];
  s.open();
  sync(s, 0, { page: "a" });
  fire(el("#to-sec"), "click");
  assert.equal(lastNavigate(s).clock, 1, "the navigate was written to the first socket");
  s.serverClose(1006);
  advance(reconnectDelay());
  const s1 = sockets[1];
  assert.ok(s1.url.endsWith("/ws?path=" + encodeURIComponent("/b")), "the join is for the navigation's page");
  s1.open();
  sync(s1, 0, { page: "b" }, 0);
  assert.deepEqual(scrolls, ["#sec"], "the join's model_sync renders the page, so it scrolls");

  // Unhappy path: a navigate still queued when the socket drops keeps its
  // clock; the join's model_sync does not stand in for its answer.
  s1.serverClose(1006);
  fire(el("#to-anchor"), "click");
  advance(reconnectDelay());
  const s2 = sockets[2];
  s2.open();
  sync(s2, 0, { page: "b" }, 0);
  assert.deepEqual(scrolls, ["#sec"], "the join does not answer a navigate it has not seen");
  assert.deepEqual(lastNavigate(s2), { type: "navigate", path: "/c", clock: 2 }, "the queued navigate is sent once synced");
  patch(s2, 0, [], 2);
  assert.deepEqual(scrolls, ["#sec", "#[name=old]"]);
});

// --- refused upgrades ---
// A browser reports a refused upgrade (the middleware answering 403, a
// disallowed origin) only as close 1006 without onopen. The client keeps
// Phoenix's capped backoff, and from the third such close in a row logs an
// error naming the likely causes.
scenario("closes before the socket opens back off to 30s, warn, then log an error from the third in a row", async () => {
  await loadRuntime();
  for (let i = 0; i < 7; i++) {
    sockets[i].serverClose(1006);
    const delay = reconnectDelay();
    const base = Math.min(1000 * 2 ** i, 30000);
    assert.ok(delay >= base && delay < base + 1000, `unopened close #${i + 1}: delay ${delay}`);
    advance(delay);
  }
  assert.equal(sockets.length, 8, "every close schedules exactly one reconnect");
  const beforeOpening = () => logsMatching("warn", "WebSocket closed before opening (code 1006)").length;
  assert.equal(beforeOpening(), 2, "the first two unopened closes warn");
  assert.equal(errorsMatching("The WebSocket upgrade failed").length, 5, "the third and later log an error");
  assert.equal(errorsMatching("failed 3 times in a row before opening (code 1006)").length, 1);
  assert.equal(errorsMatching("failed 7 times in a row before opening").length, 1);
  assert.match(errorsMatching("failed 3 times")[0].text, /refused the upgrade/);
  assert.equal(reloads, 0, "an unopened close never reloads");
  assert.ok(!root.hasAttribute("data-brazier-error"));
  sockets[7].open();
  sockets[7].serverClose(1006);
  assert.equal(logsMatching("warn", "WebSocket closed (code 1006); reconnecting").length, 1, "an opened socket's close warns");
  advance(reconnectDelay());
  sockets[8].serverClose(1006);
  assert.equal(beforeOpening(), 3, "an open resets the count of unopened closes");
  assert.equal(errorsMatching("The WebSocket upgrade failed").length, 5);
});

// The server completes the handshake of a mount its route middleware
// refuses and closes with 4600, so the client can load the page and show
// the middleware's answer instead of retrying a socket that is refused
// every time (LiveView's onJoinError navigating to the page's URL).
scenario("4600 (middleware refused the mount) loads the current URL once, never reconnects", async () => {
  await loadRuntime({ path: "/admin?tab=1#users" });
  const s = sockets[0];
  s.open();
  assert.equal(s.types()[0], "join");
  s.serverClose(4600, "middleware refused 403");
  assert.equal(reloads, 1, "the page is loaded again, at its current URL");
  assert.equal(location.pathname + location.search + location.hash, "/admin?tab=1#users", "the URL is not changed");
  assert.equal(pendingTimeouts().length, 0, "no reconnect scheduled");
  assert.equal(timers.length, 0, "heartbeat stopped");
  assert.equal(errorsMatching("middleware refused this page's live connection (close 4600 middleware refused 403)").length, 1);
  assert.equal(logsMatching("warn", "reconnecting").length, 0, "nothing says it reconnects");
  advance(120000);
  assert.equal(sockets.length, 1, "never reconnects");
  assert.equal(reloads, 1);
});

scenario("4600 shares the reload guard: a middleware that admits the GET but refuses the mount stops after 3 loads", async () => {
  const storage = new FakeStorage();
  for (let i = 0; i < 3; i++) {
    await loadRuntime({ storage, now: 3_000_000 + i * 1000 });
    sockets[0].open();
    sockets[0].serverClose(4600, "middleware refused 403");
    assert.equal(reloads, 1, `refused mount ${i + 1} loads the page`);
  }
  await loadRuntime({ storage, now: 3_003_000, ssr: "<p>admin</p>" });
  sockets[0].open();
  sockets[0].serverClose(4600, "middleware refused 403");
  assert.equal(reloads, 0, "the fourth refused mount within 60s does not load the page");
  assert.ok(root.hasAttribute("data-brazier-error"), "the page shows its error state");
  assert.equal(errorsMatching("(close 4600 middleware refused 403) after 3 reloads within 60s").length, 1);
  advance(120000);
  assert.equal(sockets.length, 1, "never reconnects");
});

scenario("unknown 4xxx codes and ordinary closes after open reconnect, never load the page", async () => {
  await loadRuntime();
  const codes = [4123, 4601, 4999, 1000, 1001];
  codes.forEach((code, i) => {
    const s = sockets[i];
    s.open();
    s.serverClose(code, "unknown");
    assert.equal(logsMatching("warn", "WebSocket closed (code " + code + ", unknown); reconnecting").length, 1, `close ${code} warns`);
    advance(reconnectDelay());
    assert.equal(sockets.length, i + 2, `reconnected after ${code}`);
  });
  assert.equal(reloads, 0, "no close but 4600 and 4400-4499 loads the page");
  assert.equal(errorsMatching("middleware refused").length, 0);
  assert.ok(!root.hasAttribute("data-brazier-error"));
  // A 4600 that arrives without an open (the handshake did not finish on
  // this side) still means a refused mount.
  sockets[codes.length].serverClose(4600, "middleware refused 302");
  assert.equal(reloads, 1);
  assert.equal(logsMatching("warn", "closed before opening").length, 0, "not counted as an unopened close");
});

// --- keyed children ---
// morphdom's and idiomorph's id matching, and the keyed children of Lustre
// and LiveView: a keyed element keeps its identity across any reorder.
const keyedView = (model) => ({
  html:
    "<ul>" + model.items.map(([key, tag]) => `<${tag} data-brazier-key="${key}">${key}</${tag}>`).join("") + "</ul>" +
    "<div>" + model.inputs.map((k) => `<input id="${k}" name="${k}" value="v${k}" data-brazier-on-input="in">`).join("") + "</div>",
  handlers: [{ name: "input", id: "in", decode: (e) => ok({ typed: e.target.value }) }],
});

scenario("keyed children keep their elements across any reorder, focus and typed value included", async () => {
  await loadRuntime({ view: keyedView });
  const s = sockets[0];
  s.open();
  const keys = Array.from({ length: 20 }, (_, i) => "k" + i);
  const inputs = Array.from({ length: 10 }, (_, i) => "i" + i);
  const li = (ks) => ks.map((k) => [k, "li"]);
  sync(s, 0, { items: li(keys), inputs });
  const list = () => [...root.childNodes[0].childNodes];
  const byKey = new Map(list().map((node) => [node.getAttribute("data-brazier-key"), node]));
  const assertOrder = (expected, what) => {
    assert.deepEqual(list().map((n) => n.getAttribute("data-brazier-key")), expected.map(([k]) => k), what + ": order");
    assert.deepEqual(list().map((n) => n.textContent), expected.map(([k]) => k), what + ": text");
    assert.deepEqual(list().map((n) => n.tagName), expected.map(([, tag]) => tag.toUpperCase()), what + ": tags");
  };
  const reversed = li([...keys].reverse());
  sync(s, 1, { items: reversed, inputs });
  assertOrder(reversed, "reversed");
  for (const node of list()) assert.equal(node, byKey.get(node.getAttribute("data-brazier-key")), "a reversal keeps every element");
  const rotated = li([...keys.slice(1), keys[0]]);
  sync(s, 2, { items: rotated, inputs });
  assertOrder(rotated, "rotated");
  for (const node of list()) assert.equal(node, byKey.get(node.getAttribute("data-brazier-key")), "a rotation keeps every element");
  // Drop k3 and k4, add n1, move k19 to the front, and render k7 as a <p>.
  const mixed = [["k19", "li"], ["n1", "li"], ...keys.slice(0, 19).filter((k) => k !== "k3" && k !== "k4").map((k) => [k, k === "k7" ? "p" : "li"])];
  sync(s, 3, { items: mixed, inputs });
  assertOrder(mixed, "mixed");
  for (const node of list()) {
    const key = node.getAttribute("data-brazier-key");
    if (key === "n1" || key === "k7") assert.notEqual(node, byKey.get(key), key + " is a new element");
    else assert.equal(node, byKey.get(key), key + " keeps its element");
  }
  assert.ok(!byKey.get("k3").parentNode && !byKey.get("k4").parentNode && !byKey.get("k7").parentNode, "dropped keys are removed");
  // A duplicate key is a view bug: logged, and only the first keeps the element.
  const k0 = list().find((n) => n.getAttribute("data-brazier-key") === "k0");
  sync(s, 4, { items: [["k0", "li"], ["k1", "li"], ["k0", "li"]], inputs });
  assert.equal(errorsMatching('Duplicate key "k0" among siblings').length, 1);
  assert.equal(list()[0], k0, "the first k0 keeps its element");
  assert.notEqual(list()[2], k0, "the second k0 is a new element");
  assert.equal(list().length, 3);
  // A focused input that moves keeps focus, selection and the value typed
  // into it while the server has not acknowledged it.
  const focused = el("#i5");
  focused.focus();
  focused.setSelectionRange(1, 2);
  focused.value = "typed";
  fire(focused, "input");
  assert.equal(s.events().length, 1);
  const items = [["k0", "li"]];
  patch(s, 5, [{ op: "replace", path: "/items", value: items }, { op: "replace", path: "/inputs", value: [...inputs].reverse() }], 0);
  assert.deepEqual([...root.childNodes[1].childNodes].map((n) => n.id), [...inputs].reverse());
  assert.equal(el("#i5"), focused, "the moved input is the same element");
  assert.equal(document.activeElement, focused, "the moved input keeps focus");
  assert.deepEqual([focused.selectionStart, focused.selectionEnd], [1, 2], "and its selection");
  assert.equal(focused.value, "typed", "an unacknowledged value survives the move");
  assert.equal(el("#i4").value, "vi4", "the other inputs follow the markup");
});

// --- random morph equivalence ---
// Seeded random trees of keyed and unkeyed elements, text and hook elements,
// each render a mutation of the last (reorders, drops, inserts, tag and hook
// changes) or a new tree. After every render: the DOM is the markup; every
// keyed element whose chain of keyed ancestors survives with the same tags
// is the same element; and the mounted hooks are exactly the hook elements
// in the DOM. mulberry32 as in apply_equivalence.mjs.
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const MORPH_TAGS = ["div", "p", "span", "li"];
const MORPH_KEYS = "abcdefghijkl".split("");
const MORPH_HOOKS = ["h1", "h2"];

function randomTree(rand, depth) {
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const used = new Set();
  const nodes = [];
  const count = Math.floor(rand() * 7);
  for (let i = 0; i < count; i++) nodes.push(randomNode(rand, depth, used, pick));
  return nodes;
}

function randomNode(rand, depth, used, pick) {
  if (rand() < 0.2) return { text: "t" + Math.floor(rand() * 3) };
  let key = null;
  if (rand() < 0.6) {
    const free = MORPH_KEYS.filter((k) => !used.has(k));
    if (free.length > 0) {
      key = pick(free);
      used.add(key);
    }
  }
  return {
    tag: pick(MORPH_TAGS),
    key,
    hook: rand() < 0.25 ? pick(MORPH_HOOKS) : null,
    v: Math.floor(rand() * 3),
    children: depth > 0 ? randomTree(rand, depth - 1) : [],
  };
}

function mutateTree(rand, nodes, depth) {
  const pick = (list) => list[Math.floor(rand() * list.length)];
  let out = nodes.map((n) => {
    if (n.text !== undefined) return rand() < 0.2 ? { text: "t" + Math.floor(rand() * 3) } : n;
    return {
      ...n,
      tag: rand() < 0.1 ? pick(MORPH_TAGS) : n.tag,
      hook: rand() < 0.15 ? (n.hook ? null : pick(MORPH_HOOKS)) : n.hook,
      v: rand() < 0.3 ? Math.floor(rand() * 3) : n.v,
      children: depth > 0 ? mutateTree(rand, n.children, depth - 1) : n.children,
    };
  });
  out = out.filter(() => rand() >= 0.15);
  if (rand() < 0.5) {
    for (let i = out.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [out[i], out[j]] = [out[j], out[i]];
    }
  }
  const used = new Set(out.filter((n) => n.key).map((n) => n.key));
  const inserts = Math.floor(rand() * 3);
  for (let i = 0; i < inserts; i++) out.splice(Math.floor(rand() * (out.length + 1)), 0, randomNode(rand, depth, used, pick));
  return out;
}

function treeHtml(nodes) {
  return nodes
    .map((n) => {
      if (n.text !== undefined) return n.text;
      const key = n.key ? ` data-brazier-key="${n.key}"` : "";
      const hook = n.hook ? ` data-brazier-hook="${n.hook}"` : "";
      return `<${n.tag}${key}${hook} data-v="${n.v}">${treeHtml(n.children)}</${n.tag}>`;
    })
    .join("");
}

function serializeDom(node) {
  if (node.nodeType === 3) return node.textContent;
  const attrs = node.attributes.map((a) => ` ${a.name}="${a.value}"`).sort().join("");
  const tag = node.tagName.toLowerCase();
  return `<${tag}${attrs}>${node.childNodes.map(serializeDom).join("")}</${tag}>`;
}

// Every keyed element reached through keyed elements only, by key path.
function keyedPaths(parent, prefix = "", out = new Map()) {
  for (const c of parent.childNodes) {
    if (c.nodeType !== 1) continue;
    const key = c.getAttribute("data-brazier-key");
    if (key === null) continue;
    const path = prefix + "/" + key;
    out.set(path, c);
    keyedPaths(c, path, out);
  }
  return out;
}

scenario("random morphs reproduce the markup, keep surviving keyed elements and track every hook", async () => {
  for (const seed of [1, 7, 42, 2026, 31337]) {
    const rand = mulberry32(seed);
    await loadRuntime({ view: (model) => ({ html: treeHtml(model.tree), handlers: [] }) });
    const s = sockets[0];
    s.open();
    const mounted = new Map();
    for (const name of MORPH_HOOKS) {
      window.brazierClient.registerHook(name, {
        mount(node) {
          assert.ok(!mounted.has(node), `seed ${seed}: ${name} mounted on an element that already has a hook`);
          mounted.set(node, name);
        },
        unmount(node) {
          assert.equal(mounted.get(node), name, `seed ${seed}: ${name} unmounted from an element it is not mounted on`);
          mounted.delete(node);
        },
      });
    }
    let tree = randomTree(rand, 3);
    for (let version = 0; version < 200; version++) {
      const before = keyedPaths(root);
      sync(s, version, { tree });
      const what = `seed ${seed}, render ${version}`;
      const expected = createElement("div");
      parseInto(expected, treeHtml(tree));
      assert.equal(root.childNodes.map(serializeDom).join(""), expected.childNodes.map(serializeDom).join(""), what + ": the DOM is the markup");
      const after = keyedPaths(root);
      for (const [path, old] of before) {
        const kept = [...path.matchAll(/\/[^/]+/g)].every((m) => {
          const prefix = path.slice(0, m.index + m[0].length);
          return after.has(prefix) && after.get(prefix).tagName === before.get(prefix).tagName;
        });
        if (kept) assert.equal(after.get(path), old, `${what}: keyed element ${path} keeps its element`);
      }
      const hookElements = root.querySelectorAll("[data-brazier-hook]");
      assert.equal(mounted.size, hookElements.length, what + ": one mounted hook per hook element");
      for (const node of hookElements) assert.equal(mounted.get(node), node.getAttribute("data-brazier-hook"), what + ": each hook element runs its hook");
      tree = rand() < 0.2 ? randomTree(rand, 3) : mutateTree(rand, tree, 3);
    }
    assert.equal(errorsMatching("").length, 0, `seed ${seed}: no render logged an error`);
  }
});

// --- streams (docs/design/STREAMS.md 6.2, 8, 13) ---

// The item function of stream "s": an item { t, v, hook, debounce } renders
// as an <li> keyed by its key, with a button (click "i0.0") and an input
// (input "i0.1") whose handler ids are relative to the item. Anything else
// does not decode, as a generated decoder refuses it.
function li(key, item, prefix = "") {
  if (item === null || typeof item !== "object" || typeof item.t !== "string") {
    return { error: "expected an Item, found " + (item === null ? "null" : typeof item) };
  }
  const hook = item.hook ? ` data-brazier-hook="${item.hook}" data-brazier-hook-watch="data-v"` : "";
  return {
    html:
      `<li data-brazier-key="${key}"${hook} data-v="${item.v ?? 0}">` +
      `<button data-brazier-on-click="i0.0">${prefix}${item.t}</button>` +
      `<input name="${key}" data-brazier-on-input="i0.1"></li>`,
    handlers: [
      { name: "click", id: "i0.0", decode: () => ok({ clicked: key }) },
      { name: "input", id: "i0.1", debounce: item.debounce || 0, decode: (e) => ok({ typed: key, value: e.target.value }) },
    ],
  };
}
// Another item function for the same stream, as a view that switches item
// functions renders.
function liUpper(key, item) {
  return li(key, item, "UP:");
}

// An app with one declared stream "s" (keep last, limit 3 unless the model
// says otherwise). The model: count (shown in <h1>), hide (no container),
// plain (the <ul> without the container attribute, with a page <li>),
// upper (the other item function), twice (two containers), stray (an item
// handler id outside any item).
function streamsApp(extra = {}) {
  return {
    streams: ["s"],
    view: (model) => {
      const head = `<h1>${model.count ?? 0}</h1>` + (model.stray ? '<p data-brazier-on-click="i0.0">stray</p>' : "");
      if (model.hide) return { html: head, handlers: [] };
      if (model.plain) return { html: head + '<ul><li data-brazier-key="ka">page</li></ul>', handlers: [] };
      const c = { name: "s", keep: model.keep || "last", limit: model.limit || 3, item: model.upper ? liUpper : li };
      return {
        html: head + '<ul data-brazier-stream="s"></ul>' + (model.twice ? '<ol data-brazier-stream="s"></ol>' : ""),
        handlers: [],
        containers: model.twice ? [c, { ...c }] : [c],
      };
    },
    ...extra,
  };
}
function entry(fields = {}) {
  return { name: "s", keep: "last", limit: 3, reset: false, deletes: [], inserts: [], ...fields };
}
function ins(key, at, item) {
  return { key, at, item };
}
function item(t, more = {}) {
  return { t, ...more };
}
function streamEl() {
  return el('[data-brazier-stream="s"]');
}
function streamKeys() {
  return streamEl().childNodes.map((c) => c.getAttribute("data-brazier-key"));
}
function streamNode(key) {
  return streamEl().childNodes.find((c) => c.getAttribute("data-brazier-key") === key);
}
function streamTexts() {
  return streamEl().childNodes.map((c) => c.childNodes[0].textContent);
}
// A browser's moveBefore on `container`: moves without taking the node out
// of the document, so focus stays. Returns the moved nodes.
function addMoveBefore(container) {
  const moved = [];
  container.moveBefore = function (node, ref) {
    const from = this.childNodes.indexOf(node);
    assert.ok(from >= 0, "moveBefore of a node that is not a child");
    this.childNodes.splice(from, 1);
    const to = ref === null ? this.childNodes.length : this.childNodes.indexOf(ref);
    assert.ok(to >= 0, "moveBefore reference is not a child");
    this.childNodes.splice(to, 0, node);
    moved.push(node);
  };
  return moved;
}
// The socket closed with 4000 `stream fault` after one console.error naming
// the stream and the reason, and the close reconnects with backoff.
function assertStreamFault(s, reason, stream = "s") {
  assert.deepEqual(s.closed, { code: 4000, reason: "stream fault" }, "a stream fault closes with 4000 stream fault");
  const faults = errorsMatching("Stream fault");
  assert.equal(faults.length, 1, "one console.error per fault");
  assert.ok(faults[0].text.includes(`stream ${JSON.stringify(stream)}, ${reason}:`), faults[0].text);
  assert.equal(logsMatching("warn", "WebSocket closed (code 4000, stream fault); reconnecting").length, 1);
  const count = sockets.length;
  advance(reconnectDelay());
  assert.equal(sockets.length, count + 1, "the fault's close reconnects");
}

// A store holding ka, kb (keep last, limit 3); each case's patch must fault
// before its model part or any store changes.
const STREAM_FAULTS = [
  { name: "a patch without a streams field", reason: "malformed", stream: null, streams: NO_STREAMS },
  { name: "streams that is not an array", reason: "malformed", stream: null, streams: {} },
  { name: "an entry with a field of the wrong type", reason: "malformed", streams: [entry({ limit: "3" })] },
  { name: "an entry with a missing field", reason: "malformed", streams: [{ name: "s", keep: "last", limit: 3, reset: false, deletes: [] }] },
  { name: "an entry for a stream the bundle does not declare", reason: "unknown_stream", stream: "t", streams: [entry({ name: "t" })] },
  { name: "keep that differs from the store's", reason: "keep_mismatch", streams: [entry({ keep: "first" })] },
  { name: "limit that differs from the store's", reason: "limit_mismatch", streams: [entry({ limit: 4 })] },
  { name: "a delete of a key the store does not hold", reason: "delete_unknown_key", streams: [entry({ deletes: ["secret-key"] })] },
  { name: "an update of a held key at another index", reason: "insert_wrong_index", streams: [entry({ inserts: [ins("ka", 1, item("A2"))] })] },
  { name: "a new key past the end", reason: "insert_past_end", streams: [entry({ inserts: [ins("kz", 3, item("Z"))] })] },
  { name: "more items than the limit", reason: "over_limit", streams: [entry({ inserts: [ins("kc", 2, item("C")), ins("kd", 3, item("D"))] })] },
  { name: "an item the item function cannot decode", reason: "item_render_failed", streams: [entry({ inserts: [ins("kc", 2, "not an item")] })] },
  { name: "a valid entry before a faulting one", reason: "delete_unknown_key", streams: [entry({ inserts: [ins("kc", 2, item("C"))] }), entry({ deletes: ["kz"] })] },
];

scenario("every stream fault closes the socket with 4000 stream fault, applies nothing and reconnects", async () => {
  for (const c of STREAM_FAULTS) {
    await loadRuntime(streamsApp());
    const s = sockets[0];
    s.open();
    sync(s, 0, { count: 0 }, 0, [entry({ reset: true, inserts: [ins("ka", 0, item("A")), ins("kb", 1, item("B"))] })]);
    assert.deepEqual(streamKeys(), ["ka", "kb"], c.name);
    const models = decoded.length;
    try {
      patch(s, 1, [{ op: "replace", path: "/count", value: 1 }], 0, c.streams);
      assert.equal(decoded.length, models, "the model part of a faulting frame is not applied");
      assert.equal(el("h1").textContent, "0");
      assert.deepEqual(streamKeys(), ["ka", "kb"], "a fault changes no container");
      assert.deepEqual(streamTexts(), ["A", "B"]);
      assert.equal(s.types().filter((t) => t === "request_sync").length, 0, "a resync cannot repair a store");
      assert.equal(logs.filter((l) => l.text.includes("secret-key")).length, 0, "keys are never logged");
      assertStreamFault(s, c.reason, c.stream === undefined ? "s" : c.stream);
    } catch (error) {
      error.message = c.name + ": " + error.message;
      throw error;
    }
  }
});

scenario("a join model_sync without a streams field, or with a faulting entry, is a stream fault", async () => {
  for (const streams of [NO_STREAMS, [entry({ deletes: ["ka"] })]]) {
    await loadRuntime(streamsApp());
    const s = sockets[0];
    s.open();
    sync(s, 0, { count: 0 }, 0, streams);
    assert.equal(decoded.length, 0, "the model is not adopted");
    assert.equal(logsMatching("log", "Client ready").length, 0);
    assertStreamFault(s, streams === NO_STREAMS ? "malformed" : "delete_unknown_key", streams === NO_STREAMS ? null : "s");
  }
});

scenario("keep or limit that differs from the rendered container's is a stream fault", async () => {
  // An entry for a stream without a store yet, against its container.
  for (const [fields, reason] of [[{ limit: 5 }, "limit_mismatch"], [{ keep: "first" }, "keep_mismatch"]]) {
    await loadRuntime(streamsApp());
    const s = sockets[0];
    s.open();
    sync(s, 0, { count: 0 });
    patch(s, 1, [], 0, [entry({ ...fields, inserts: [ins("ka", 0, item("A"))] })]);
    assert.deepEqual(streamKeys(), [], "the entry is not applied");
    assertStreamFault(s, reason);
    assert.ok(errorsMatching("container " + (reason === "keep_mismatch" ? "keep last" : "limit 3")).length === 1);
  }
  // A store filled while the container was not rendered, against the
  // container that appears.
  await loadRuntime(streamsApp());
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0, hide: true }, 0, [entry({ limit: 5, inserts: [ins("ka", 0, item("A"))] })]);
  patch(s, 1, [{ op: "replace", path: "/hide", value: false }]);
  assert.deepEqual(streamKeys(), [], "a container that does not match its store is not filled");
  assertStreamFault(s, "limit_mismatch");
  assert.equal(errorsMatching("store limit 5, container limit 3").length, 1);
});

scenario("frames on a socket a stream fault closed are ignored", async () => {
  await loadRuntime(streamsApp());
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 }, 0, [entry({ inserts: [ins("ka", 0, item("A"))] })]);
  patch(s, 1, [], 0, [entry({ deletes: ["kz"] })]);
  assert.deepEqual(s.closed, { code: 4000, reason: "stream fault" });
  // A browser drops frames once the socket is closing; the runtime does not
  // rely on it.
  patch(s, 1, [{ op: "replace", path: "/count", value: 9 }], 0, [entry({ inserts: [ins("kb", 1, item("B"))] })]);
  assert.equal(el("h1").textContent, "0");
  assert.deepEqual(streamKeys(), ["ka"]);
  assert.equal(logsMatching("warn", "after a stream fault and is ignored").length, 1);
  assert.equal(errorsMatching("Stream fault").length, 1, "an ignored frame is not a second fault");
});

scenario("a stream delta is applied under every model verdict, a held frame and an invalid ack_clock", async () => {
  await loadRuntime(streamsApp());
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 }, 0, [entry({ inserts: [ins("ka", 0, item("A"))] })]);
  // apply
  patch(s, 1, [{ op: "replace", path: "/count", value: 1 }], 0, [entry({ inserts: [ins("kb", 1, item("B"))] })]);
  assert.deepEqual([el("h1").textContent, ...streamKeys()], ["1", "ka", "kb"], "apply");
  // ack: the revision does not move
  patch(s, 1, [], 0, [entry({ inserts: [ins("kc", 2, item("C"))] })]);
  assert.deepEqual(streamKeys(), ["ka", "kb", "kc"], "ack");
  // stale
  patch(s, 1, [{ op: "replace", path: "/count", value: 7 }], 0, [entry({ deletes: ["ka"] })]);
  assert.deepEqual([el("h1").textContent, ...streamKeys()], ["1", "kb", "kc"], "stale: the model is not applied, the delta is");
  // a stale model_sync (an older revision while synced)
  sync(s, 0, { count: 0 }, 0, [entry({ inserts: [ins("kd", 2, item("D"))] })]);
  assert.deepEqual([el("h1").textContent, ...streamKeys()], ["1", "kb", "kc", "kd"], "stale model_sync");
  // gap
  patch(s, 5, [{ op: "replace", path: "/count", value: 7 }], 0, [entry({ deletes: ["kb"] })]);
  assert.deepEqual([el("h1").textContent, ...streamKeys()], ["1", "kc", "kd"], "gap");
  assert.equal(s.types().at(-1), "request_sync", "a gap still resyncs the model");
  // invalid ack_clock: the model part is refused, the delta is applied
  patch(s, 2, [], "x", [entry({ inserts: [ins("kc", 0, item("C2"))] })]);
  assert.deepEqual(streamTexts(), ["C2", "D"], "invalid ack_clock");
  // Entries for one name in one frame apply in order.
  patch(s, 1, [], 0, [entry({ inserts: [ins("ke", 2, item("E"))] }), entry({ deletes: ["ke"] })]);
  assert.deepEqual(streamKeys(), ["kc", "kd"], "entries apply in order");
  assert.equal(errorsMatching("Stream fault").length, 0);

  // held: a `simple` app's pending prediction holds the model, not the delta.
  const view = streamsApp().view;
  await loadRuntime({
    ...streamsApp(),
    simple: true,
    update: (model) => ({ ...model, count: model.count + 1 }),
    view: (model) => {
      const out = view(model);
      return { ...out, html: '<button data-brazier-on-click="0.0">+</button>' + out.html, handlers: [{ name: "click", id: "0.0", decode: () => ok({ inc: true }) }] };
    },
  });
  const h = sockets[0];
  h.open();
  sync(h, 0, { count: 0 });
  fire(el("button"), "click");
  assert.equal(el("h1").textContent, "1", "predicted");
  patch(h, 1, [{ op: "replace", path: "/count", value: 5 }], 0, [entry({ inserts: [ins("ka", 0, item("A"))] })]);
  assert.deepEqual([el("h1").textContent, ...streamKeys()], ["1", "ka"], "held: the prediction stays, the item is shown");
});

scenario("an update in place keeps the item's node, and a move restores it with focus", async () => {
  await loadRuntime(streamsApp());
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 }, 0, [entry({ inserts: [ins("ka", 0, item("A")), ins("kb", 1, item("B")), ins("kc", 2, item("C"))] })]);
  const nodes = new Map(["ka", "kb", "kc"].map((k) => [k, streamNode(k)]));
  const renderedItems = itemRenders;
  patch(s, 0, [], 0, [entry({ inserts: [ins("kb", 1, item("B2"))] })]);
  assert.equal(streamNode("kb"), nodes.get("kb"), "an update in place keeps the node");
  assert.deepEqual(streamTexts(), ["A", "B2", "C"]);
  assert.equal(itemRenders, renderedItems + 1, "only the updated item renders");
  // A move without moveBefore: the node leaves the document for a moment,
  // and focus is given back.
  const button = nodes.get("kb").childNodes[0];
  button.focus();
  patch(s, 0, [], 0, [entry({ deletes: ["kb"], inserts: [ins("kb", 2, item("B3"))] })]);
  assert.deepEqual(streamKeys(), ["ka", "kc", "kb"]);
  assert.equal(streamNode("kb"), nodes.get("kb"), "a moved item keeps its node");
  assert.equal(streamNode("kb").childNodes[0], button);
  assert.equal(document.activeElement, button, "focus comes back after the move");
  assert.deepEqual(streamTexts(), ["A", "C", "B3"]);
  // With moveBefore, the node moves without leaving the document.
  const moved = addMoveBefore(streamEl());
  patch(s, 0, [], 0, [entry({ deletes: ["ka"], inserts: [ins("ka", 2, item("A"))] })]);
  assert.deepEqual(moved, [nodes.get("ka")]);
  assert.deepEqual(streamKeys(), ["kc", "kb", "ka"]);
  assert.equal(document.activeElement, button);
  for (const [key, node] of nodes) assert.equal(streamNode(key), node, key + " keeps its node");
});

scenario("item hooks mount on insert, update on a watched change and unmount on delete, trim and reset", async () => {
  await loadRuntime(streamsApp());
  const s = sockets[0];
  s.open();
  const calls = [];
  window.brazierClient.registerHook("Item", {
    mount: (node) => calls.push("mount " + node.getAttribute("data-brazier-key")),
    update: (node) => calls.push("update " + node.getAttribute("data-brazier-key")),
    unmount: (node) => calls.push("unmount " + node.getAttribute("data-brazier-key")),
  });
  const hooked = (t, v = 0) => item(t, { hook: "Item", v });
  sync(s, 0, { count: 0 }, 0, [entry({ inserts: [ins("ka", 0, hooked("A")), ins("kb", 1, hooked("B"))] })]);
  assert.deepEqual(calls.splice(0), ["mount ka", "mount kb"], "insert mounts");
  patch(s, 0, [], 0, [entry({ inserts: [ins("kb", 1, hooked("B", 1))] })]);
  assert.deepEqual(calls.splice(0), ["update kb"], "a watched change updates");
  patch(s, 0, [], 0, [entry({ inserts: [ins("kb", 1, hooked("B2", 1))] })]);
  assert.deepEqual(calls.splice(0), [], "an unwatched change does not");
  patch(s, 0, [], 0, [entry({ deletes: ["ka"] })]);
  assert.deepEqual(calls.splice(0), ["unmount ka"], "delete unmounts");
  // A trim is a delete the server computed: limit 3, keep last.
  patch(s, 0, [], 0, [entry({ inserts: [ins("kc", 1, hooked("C")), ins("kd", 2, hooked("D"))] })]);
  assert.deepEqual(calls.splice(0), ["mount kc", "mount kd"]);
  patch(s, 0, [], 0, [entry({ deletes: ["kb"], inserts: [ins("ke", 2, hooked("E"))] })]);
  // Removals unmount at once; mounts run after the patch, in syncHooks.
  assert.deepEqual(calls.splice(0), ["unmount kb", "mount ke"], "a trim unmounts");
  // A reset unmounts every item it does not insert again; one it inserts
  // again keeps its node and its hook.
  const kd = streamNode("kd");
  patch(s, 0, [], 0, [entry({ reset: true, inserts: [ins("kd", 0, hooked("D")), ins("kf", 1, hooked("F"))] })]);
  assert.deepEqual(calls.splice(0).sort(), ["mount kf", "unmount kc", "unmount ke"]);
  assert.equal(streamNode("kd"), kd);
  assert.deepEqual(streamKeys(), ["kd", "kf"]);
});

scenario("a container that appears later is filled, a new item function re-renders it, and one rendered twice throws", async () => {
  await loadRuntime(streamsApp());
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0, hide: true }, 0, [entry({ inserts: [ins("ka", 0, item("A")), ins("kb", 1, item("B"))] })]);
  assert.equal(root.querySelector('[data-brazier-stream="s"]'), null);
  // Ops for a stream that is not rendered are kept in its store.
  patch(s, 0, [], 0, [entry({ inserts: [ins("kc", 2, item("C"))] })]);
  patch(s, 1, [{ op: "replace", path: "/hide", value: false }]);
  assert.deepEqual(streamKeys(), ["ka", "kb", "kc"], "the container is filled from the store");
  const nodes = streamEl().childNodes.slice();
  // The same container with another item function: every item renders again
  // and keeps its node.
  patch(s, 2, [{ op: "add", path: "/upper", value: true }]);
  assert.deepEqual(streamTexts(), ["UP:A", "UP:B", "UP:C"]);
  assert.deepEqual(streamEl().childNodes, nodes);
  // Hidden again: the view goes, the store stays.
  patch(s, 3, [{ op: "replace", path: "/hide", value: true }]);
  assert.equal(logsMatching("log", "Stream s is no longer rendered").length, 1);
  patch(s, 3, [], 0, [entry({ deletes: ["ka"] })]);
  patch(s, 4, [{ op: "replace", path: "/hide", value: false }]);
  assert.deepEqual(streamKeys(), ["kb", "kc"]);
  // Two containers of one stream: the render throws before the page morph.
  const before = root.childNodes.slice();
  patch(s, 5, [{ op: "add", path: "/twice", value: true }]);
  assert.equal(errorsMatching("renders stream s twice").length, 1);
  assert.deepEqual(root.childNodes, before, "the page is not changed");
  assert.equal(root.querySelector('[data-brazier-stream="s"]').tagName, "UL");
  assert.equal(s.types().at(-1), "request_sync", "the render failure path resyncs");
  assert.equal(errorsMatching("Stream fault").length, 0);
  // A stream the bundle does not declare.
  await loadRuntime({ ...streamsApp(), streams: [] });
  sockets[0].open();
  sync(sockets[0], 0, { count: 0 });
  assert.equal(errorsMatching("which the bundle does not declare").length, 1);
  assert.equal(root.querySelector("h1"), null, "nothing is rendered");
});

scenario("a reconnect empties the stores, keeps the old items until the join, and the join reconciles them", async () => {
  await loadRuntime(streamsApp());
  const calls = [];
  window.brazierClient.registerHook("Item", {
    mount: (node) => calls.push("mount " + node.getAttribute("data-brazier-key")),
    unmount: (node) => calls.push("unmount " + node.getAttribute("data-brazier-key")),
  });
  const hooked = (t) => item(t, { hook: "Item" });
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 }, 0, [entry({ inserts: [ins("ka", 0, hooked("A")), ins("kb", 1, hooked("B")), ins("kc", 2, hooked("C"))] })]);
  const nodes = new Map(["ka", "kb", "kc"].map((k) => [k, streamNode(k)]));
  calls.length = 0;
  s.serverClose(1006);
  advance(reconnectDelay());
  assert.equal(logsMatching("log", "emptied 1 stream store(s)").length, 1);
  assert.deepEqual(streamKeys(), ["ka", "kb", "kc"], "the old items stay until the join");
  // The old items stay clickable meanwhile; the click waits in the queue.
  fire(nodes.get("ka").childNodes[0], "click");
  assert.equal(errorsMatching("").length, 0);
  const s2 = sockets[1];
  s2.open();
  sync(s2, 0, { count: 0 }, 0, [entry({ reset: true, inserts: [ins("kb", 0, hooked("B")), ins("kc", 1, hooked("C2")), ins("kd", 2, hooked("D"))] })]);
  assert.deepEqual(streamKeys(), ["kb", "kc", "kd"]);
  assert.equal(streamNode("kb"), nodes.get("kb"), "an item the join sends again keeps its node");
  assert.equal(streamNode("kc"), nodes.get("kc"));
  assert.deepEqual(streamTexts(), ["B", "C2", "D"]);
  assert.deepEqual(calls.sort(), ["mount kd", "unmount ka"], "kept items keep their hooks");
  assert.deepEqual(s2.msgs(), [{ clicked: "ka" }], "the queued click is sent on the new socket");
  assert.equal(logsMatching("log", "First frame of the connection: reconciling 1").length, 1);

  // The new connection's stores start empty: a join entry that builds on the
  // old store faults.
  s2.serverClose(1006);
  advance(reconnectDelay());
  const s3 = sockets[2];
  s3.open();
  sync(s3, 0, { count: 0 }, 0, [entry({ deletes: ["kb"] })]);
  assertStreamFault(s3, "delete_unknown_key");
});

scenario("the first render keeps the SSR items the join sends and drops the rest", async () => {
  const ssrItem = (key, t) => li(key, item(t)).html;
  await loadRuntime({
    ...streamsApp(),
    ssr: '<h1>0</h1><ul data-brazier-stream="s">' + ssrItem("ka", "A") + "stray" + ssrItem("kb", "B") + "</ul>",
  });
  const ka = streamNode("ka");
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 }, 0, [entry({ reset: true, inserts: [ins("kc", 0, item("C")), ins("ka", 1, item("A2"))] })]);
  assert.deepEqual(streamKeys(), ["kc", "ka"], "the unkeyed text and kb are gone");
  assert.equal(streamNode("ka"), ka, "the SSR node is the live node");
  assert.deepEqual(streamTexts(), ["C", "A2"]);
});

scenario("item handlers dispatch by key and id, and debounce per item", async () => {
  await loadRuntime(streamsApp());
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 }, 0, [entry({ inserts: [ins("ka", 0, item("A", { debounce: 100 })), ins("kb", 1, item("B", { debounce: 100 }))] })]);
  fire(streamNode("kb").childNodes[0], "click");
  assert.deepEqual(s.msgs(), [{ clicked: "kb" }]);
  assert.equal(s.events()[0].handler_id, "i0.0", "the id sent is the item-relative one");
  // The same handler id in two items is two debounces.
  const a = streamNode("ka").childNodes[1];
  const b = streamNode("kb").childNodes[1];
  a.value = "x";
  fire(a, "input");
  b.value = "y";
  fire(b, "input");
  advance(100);
  assert.deepEqual(s.msgs().slice(1), [{ typed: "ka", value: "x" }, { typed: "kb", value: "y" }]);
  // An item-relative id outside any item is an error, not a page lookup.
  patch(s, 1, [{ op: "add", path: "/stray", value: true }]);
  fire(el("p"), "click");
  assert.equal(errorsMatching("is relative to a stream item, but its element is not inside one").length, 1);
  assert.equal(s.msgs().length, 3);
});

scenario("pre-hydration events on SSR items replay on the item the join keeps, and drop with a warning when it removes it", async () => {
  const ssrItem = (key, t) => li(key, item(t)).html;
  await loadRuntime({
    ...streamsApp(),
    ssr: '<h1>0</h1><ul data-brazier-stream="s">' + ssrItem("ka", "A") + ssrItem("kb", "B") + "</ul>",
  });
  const s = sockets[0];
  fire(streamNode("ka").childNodes[0], "click");
  fire(streamNode("kb").childNodes[0], "click");
  s.open();
  sync(s, 0, { count: 0 }, 0, [entry({ reset: true, inserts: [ins("ka", 0, item("A"))] })]);
  assert.deepEqual(s.msgs(), [{ clicked: "ka" }]);
  assert.equal(logsMatching("warn", "from before hydration dropped: the join removed the item").length, 1);
  assert.equal(errorsMatching("").length, 0);
});

scenario("an element the page morph turns into a container loses its page children before the stream fills it", async () => {
  await loadRuntime(streamsApp());
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0, plain: true }, 0, [entry({ inserts: [ins("ka", 0, item("A"))] })]);
  const ul = el("ul");
  const page = ul.childNodes[0];
  assert.equal(page.textContent, "page");
  patch(s, 1, [{ op: "replace", path: "/plain", value: false }]);
  assert.equal(streamEl(), ul, "the page morph keeps the element");
  assert.notEqual(streamNode("ka"), page, "a page child is never adopted as an item, even with an item's key");
  assert.deepEqual(streamTexts(), ["A"]);
});

scenario("an event on an element in a container that its view does not hold is dropped with an error", async () => {
  await loadRuntime(streamsApp());
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 }, 0, [entry({ inserts: [ins("ka", 0, item("A"))] })]);
  // Code outside the runtime puts elements into the container: one with a
  // key the store does not hold, one with a key it holds.
  const template = document.createElement("template");
  template.innerHTML = li("kz", item("Z")).html + li("ka", item("A")).html;
  const [foreign, copy] = template.content.childNodes.slice();
  streamEl().appendChild(foreign);
  streamEl().appendChild(copy);
  fire(foreign.childNodes[0], "click");
  assert.equal(errorsMatching("that its view does not hold; the page and the stream store disagree").length, 1);
  fire(copy.childNodes[0], "click");
  assert.equal(errorsMatching("that is not the item node its view holds").length, 1);
  assert.deepEqual(s.msgs(), [], "neither event is sent");
  fire(streamNode("ka").childNodes[0], "click");
  assert.deepEqual(s.msgs(), [{ clicked: "ka" }]);
});

scenario("stream_names with a name repeated, empty or not a string throws at start, before any connection", async () => {
  for (const [streams, message] of [[["s", "s"], /lists the stream s twice/], [[""], /not a stream name/], [[7], /not a stream name/]]) {
    const runtime = await loadModule();
    assert.throws(() => runtime.start(makeApp(streamsApp({ streams }))), message);
    assert.equal(sockets.length, 0, "no connection");
  }
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
