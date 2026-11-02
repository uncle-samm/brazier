// Behaviour checks for the browser runtime (beacon_client_ffi.mjs) without a
// browser: a fake WebSocket, fake timers, a fake clock and a minimal DOM.
//
// Usage: node beacon_client/test/ffi_harness.mjs
//
// Each scenario loads a fresh copy of the runtime module, drives it through
// server frames and close codes, and asserts what it wrote to the socket,
// what it logged and which timers it scheduled. Unhappy paths come first.
// Any failure exits non-zero so the calling Gleam test fails loudly.

import assert from "node:assert/strict";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const SRC = fileURLToPath(new URL("../src/", import.meta.url));
const WORK = mkdtempSync(join(tmpdir(), "beacon_ffi_harness_"));
mkdirSync(join(WORK, "beacon_client"));
copyFileSync(join(SRC, "beacon_client_ffi.mjs"), join(WORK, "beacon_client_ffi.mjs"));
copyFileSync(join(SRC, "beacon_client", "patch.mjs"), join(WORK, "beacon_client", "patch.mjs"));
// The runtime imports Ok/Error from the Gleam prelude; this is the same shape.
writeFileSync(
  join(WORK, "gleam.mjs"),
  "export class Ok { constructor(v) { this[0] = v; } isOk() { return true; } }\n" +
    "class GError { constructor(v) { this[0] = v; } isOk() { return false; } }\n" +
    "export { GError as Error };\n",
);

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
globalThis.requestAnimationFrame = (fn) => addTimer(fn, 16, null);
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
}
globalThis.WebSocket = FakeWebSocket;

// --- console capture ---
const realConsole = { log: console.log, warn: console.warn, error: console.error };
let logs = [];
for (const level of ["log", "warn", "error"]) {
  console[level] = (...args) => logs.push({ level, text: args.map(String).join(" ") });
}
function errorsMatching(text) {
  return logs.filter((l) => l.level === "error" && l.text.includes(text));
}

// --- minimal DOM and app ---
let reloads = 0;
let decoded = [];
function freshGlobals() {
  timers = [];
  sockets = [];
  logs = [];
  reloads = 0;
  decoded = [];
  clock.now = 1_000_000;
  const root = {
    nodeType: 1,
    tagName: "DIV",
    id: "beacon-app",
    childNodes: [],
    firstChild: null,
    getAttribute: () => null,
    hasAttribute: () => false,
    querySelectorAll: () => [],
  };
  globalThis.location = {
    protocol: "http:",
    host: "localhost",
    pathname: "/",
    search: "",
    reload: () => { reloads++; },
  };
  globalThis.document = {
    readyState: "complete",
    activeElement: null,
    querySelector: () => root,
    addEventListener() {},
    createElement: () => ({ innerHTML: "", content: { firstChild: null } }),
  };
  globalThis.window = {
    addEventListener() {},
    BeaconApp: {
      decode_model(json) {
        const value = JSON.parse(json);
        if (value.bad === true) return { isOk: () => false, 0: "bad model" };
        decoded.push(value);
        return { isOk: () => true, 0: value };
      },
      start_render() {},
      view_to_html: () => "",
      finish_render: () => null,
    },
  };
}

let loadSeq = 0;
async function loadRuntime() {
  freshGlobals();
  const url = pathToFileURL(join(WORK, "beacon_client_ffi.mjs")).href + "?instance=" + ++loadSeq;
  const runtime = await import(url);
  assert.equal(sockets.length, 1, "runtime connects on boot");
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
  const pending = pendingTimeouts();
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
  const events = s.sent.filter((x) => x.msg.type === "event").map((x) => x.msg.clock);
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
  assert.equal(s.sent.filter((x) => x.msg.type === "event").length, 39, "join + 39 events fill the budget");
  advance(5000);
  const events = s.sent.filter((x) => x.msg.type === "event").map((x) => x.msg.clock);
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

scenario("unknown and unparseable server frames are logged", async () => {
  await loadRuntime();
  const s = sockets[0];
  s.open();
  sync(s, 0, { count: 0 });
  s.deliver({ type: "surprise" });
  assert.equal(errorsMatching("Unknown server message type").length, 1);
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
