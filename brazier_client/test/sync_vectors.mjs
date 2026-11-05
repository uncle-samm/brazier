// Wire sync policy checker.
//
// Usage: node brazier_client/test/sync_vectors.mjs [server_messages.json]
//
// Always runs the unit checks of the pure policy in
// brazier_client/src/brazier_client/patch.mjs (unhappy paths first).
//
// With a messages file (produced by test/brazier/runtime_versioning_test.gleam)
//   { "messages": [<server frame JSON string>, ...], "final_model": <json string>,
//     "final_version": <int> }
// it replays one connection's server frames through classifyModelSync /
// classifyPatch and applyOps, asserting that every frame is "apply" or "ack"
// (never gap, stale or invalid) and that the replayed model equals the final
// authoritative model_sync. Any failure exits non-zero so the Gleam test fails.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  applyOps,
  buildIdFromScriptSrc,
  classifyModelSync,
  classifyPatch,
  closeAction,
  heartbeatAllowed,
  messageCost,
  PacedQueue,
  parseReloadHistory,
  reconnectDelayMs,
  reloadDecision,
  SendBudget,
  splitEventBatch,
  CLIENT_SEND_BUDGET,
  CLIENT_SEND_WINDOW_MS,
  CLOSE_MIDDLEWARE_REFUSED,
  CLOSE_STALE_BUILD,
  SERVER_MAX_BATCH_SIZE,
  SERVER_MAX_EVENTS_PER_SECOND,
  MAX_RELOADS,
  RELOAD_WINDOW_MS,
} from "../src/brazier_client/patch.mjs";

let checks = 0;
function check(name, fn) {
  try {
    fn();
    checks++;
  } catch (error) {
    console.error(`sync check "${name}" failed: ${error.message}`);
    process.exit(1);
  }
}

// --- classifyModelSync ---
check("model_sync with a non-integer version is invalid", () => {
  for (const v of [undefined, null, "3", 1.5, -1, NaN, Infinity]) {
    assert.equal(classifyModelSync({ version: 0, synced: false }, v), "invalid", String(v));
    assert.equal(classifyModelSync({ version: 4, synced: true }, v), "invalid", String(v));
  }
});
check("model_sync older than the synced revision is stale", () => {
  assert.equal(classifyModelSync({ version: 5, synced: true }, 4), "stale");
});
check("model_sync at or after the synced revision applies", () => {
  assert.equal(classifyModelSync({ version: 5, synced: true }, 5), "apply");
  assert.equal(classifyModelSync({ version: 5, synced: true }, 9), "apply");
});
check("first model_sync of a connection applies at any revision", () => {
  assert.equal(classifyModelSync({ version: 0, synced: false }, 0), "apply");
  assert.equal(classifyModelSync({ version: 7, synced: false }, 2), "apply");
});

// --- classifyPatch ---
check("patch with a bad version or op count is invalid", () => {
  for (const v of [undefined, null, "1", 2.5, -1]) {
    assert.equal(classifyPatch({ version: 1, synced: true }, v, 1), "invalid", String(v));
  }
  assert.equal(classifyPatch({ version: 1, synced: true }, 2, -1), "invalid");
  assert.equal(classifyPatch({ version: 1, synced: true }, 2, 1.5), "invalid");
});
check("any patch before the connection is synced is a gap", () => {
  assert.equal(classifyPatch({ version: 0, synced: false }, 1, 1), "gap");
  assert.equal(classifyPatch({ version: 0, synced: false }, 0, 0), "gap");
});
check("patch that skips a revision is a gap", () => {
  assert.equal(classifyPatch({ version: 3, synced: true }, 5, 2), "gap");
});
check("patch at or below the cached revision is stale", () => {
  assert.equal(classifyPatch({ version: 3, synced: true }, 3, 1), "stale");
  assert.equal(classifyPatch({ version: 3, synced: true }, 1, 1), "stale");
});
check("empty patch ahead of the cached revision is a gap", () => {
  assert.equal(classifyPatch({ version: 3, synced: true }, 4, 0), "gap");
});
check("empty patch behind the cached revision is stale", () => {
  assert.equal(classifyPatch({ version: 3, synced: true }, 2, 0), "stale");
});
check("empty patch at the cached revision is an ack", () => {
  assert.equal(classifyPatch({ version: 3, synced: true }, 3, 0), "ack");
});
check("patch producing the next revision applies", () => {
  assert.equal(classifyPatch({ version: 3, synced: true }, 4, 1), "apply");
});

// --- closeAction ---
check("closeAction rejects a code that is not an integer", () => {
  assert.throws(() => closeAction(undefined));
  assert.throws(() => closeAction(4401.5));
});
check("4400 to 4499 reload the page", () => {
  assert.equal(CLOSE_STALE_BUILD, 4499);
  for (const code of [4400, 4401, 4403, 4404, 4409, CLOSE_STALE_BUILD]) {
    assert.equal(closeAction(code), "reload", String(code));
  }
});
check("4600 (middleware refused the mount) navigates to the page", () => {
  assert.equal(CLOSE_MIDDLEWARE_REFUSED, 4600);
  assert.equal(closeAction(CLOSE_MIDDLEWARE_REFUSED), "navigate");
});
check("every other close code reconnects, 4500 to 4599, 1011 and unknown 4xxx included", () => {
  for (const code of [1000, 1001, 1002, 1003, 1006, 1007, 1008, 1009, 1011, 1013, 4000, 4123, 4399, 4500, 4503, 4599, 4601, 4999]) {
    assert.equal(closeAction(code), "reconnect", String(code));
  }
});

// --- build id ---
check("buildIdFromScriptSrc rejects a src that is not a string", () => {
  assert.throws(() => buildIdFromScriptSrc(42), /must be a string/);
  assert.throws(() => buildIdFromScriptSrc({}), /must be a string/);
});
check("buildIdFromScriptSrc is null for any URL but a hashed bundle", () => {
  for (const src of [
    null,
    undefined,
    "",
    "http://localhost/brazier_client.js",
    "http://localhost/brazier_client_.js",
    "http://localhost/brazier_client_0123456.js",
    "http://localhost/brazier_client_" + "a".repeat(65) + ".js",
    "http://localhost/brazier_client_0123456g.js",
    "http://localhost/brazier_client_01234567.mjs",
    "http://localhost/brazier_client_01234567.js/",
    "http://localhost/other_brazier_client_01234567.js",
    "http://localhost/x.js?brazier_client_01234567.js",
    "http://localhost/x.js#/brazier_client_01234567.js",
  ]) {
    assert.equal(buildIdFromScriptSrc(src), null, String(src));
  }
});
check("buildIdFromScriptSrc returns the hash of /brazier_client_<hash>.js", () => {
  assert.equal(buildIdFromScriptSrc("http://localhost/brazier_client_01234567.js"), "01234567");
  assert.equal(buildIdFromScriptSrc("https://cdn.example/a/b/brazier_client_ABCdef0123456789.js?v=2#x"), "ABCdef0123456789");
  const longest = "f".repeat(64);
  assert.equal(buildIdFromScriptSrc("/brazier_client_" + longest + ".js"), longest);
});

// --- reload guard ---
check("parseReloadHistory rejects anything but a short list of timestamps", () => {
  for (const raw of ["", "{", "{}", "[1.5]", "[-1]", '["1"]', "null", JSON.stringify([1, 2, 3, 4])]) {
    assert.equal(parseReloadHistory(raw).ok, false, raw);
  }
});
check("parseReloadHistory reads nothing stored as no reloads", () => {
  assert.deepEqual(parseReloadHistory(null), { ok: true, history: [] });
  assert.deepEqual(parseReloadHistory("[5,6]"), { ok: true, history: [5, 6] });
});
check("reloadDecision rejects a bad clock", () => {
  assert.throws(() => reloadDecision([], -1));
  assert.throws(() => reloadDecision([], 1.5));
});
check("reloadDecision gives up after MAX_RELOADS within the window", () => {
  const full = [1000, 2000, 3000];
  assert.equal(full.length, MAX_RELOADS);
  assert.deepEqual(reloadDecision(full, 4000), { action: "give_up", history: full });
  // A time ahead of now (the clock went back) still counts.
  assert.equal(reloadDecision([9000, 9500, 9900], 4000).action, "give_up");
});
check("reloadDecision forgets reloads older than the window", () => {
  const now = 1000 + RELOAD_WINDOW_MS;
  assert.deepEqual(reloadDecision([1000, 2000, 3000], now), { action: "reload", history: [2000, 3000, now] });
  assert.deepEqual(reloadDecision([], 7), { action: "reload", history: [7] });
});

// --- reconnectDelayMs ---
check("reconnectDelayMs rejects bad input", () => {
  assert.throws(() => reconnectDelayMs(-1, 0));
  assert.throws(() => reconnectDelayMs(1.5, 0));
  assert.throws(() => reconnectDelayMs(0, 1));
  assert.throws(() => reconnectDelayMs(0, -0.1));
  assert.throws(() => reconnectDelayMs(0, NaN));
});
check("reconnectDelayMs backs off exponentially with a cap and jitter", () => {
  assert.equal(reconnectDelayMs(0, 0), 1000);
  assert.equal(reconnectDelayMs(1, 0), 2000);
  assert.equal(reconnectDelayMs(4, 0), 16000);
  assert.equal(reconnectDelayMs(5, 0), 30000);
  assert.equal(reconnectDelayMs(10000, 0), 30000);
  assert.equal(reconnectDelayMs(0, 0.9999), 1999);
});

// --- heartbeatAllowed ---
check("a heartbeat under 500ms after the previous one is refused", () => {
  assert.equal(heartbeatAllowed(1000, 1499), false);
  assert.equal(heartbeatAllowed(1000, 1000), false);
});
check("first heartbeat and spaced heartbeats are allowed", () => {
  assert.equal(heartbeatAllowed(null, 0), true);
  assert.equal(heartbeatAllowed(1000, 1500), true);
});

// --- messageCost / splitEventBatch ---
check("message cost matches the server rate limiter", () => {
  assert.equal(messageCost({ type: "heartbeat" }), 0);
  assert.equal(messageCost({ type: "event" }), 1);
  assert.equal(messageCost({ type: "join" }), 1);
  assert.equal(messageCost({ type: "request_sync" }), 1);
  assert.equal(messageCost({ type: "event_batch", events: [] }), 1);
  assert.equal(messageCost({ type: "event_batch", events: [1, 2, 3] }), 3);
});
check("splitEventBatch rejects bad input", () => {
  assert.throws(() => splitEventBatch({ type: "event" }, 10));
  assert.throws(() => splitEventBatch({ type: "event_batch", events: "x" }, 10));
  assert.throws(() => splitEventBatch({ type: "event_batch", events: [] }, 0));
  assert.throws(() => splitEventBatch({ type: "event_batch", events: [] }, SERVER_MAX_BATCH_SIZE + 1));
});
check("splitEventBatch keeps every event in order within the cap", () => {
  const events = Array.from({ length: 250 }, (_, i) => ({ clock: i }));
  const batches = splitEventBatch({ type: "event_batch", events }, CLIENT_SEND_BUDGET);
  assert.equal(batches.length, Math.ceil(250 / CLIENT_SEND_BUDGET));
  for (const b of batches) {
    assert.equal(b.type, "event_batch");
    assert.ok(b.events.length >= 1 && b.events.length <= CLIENT_SEND_BUDGET);
  }
  assert.deepEqual(batches.flatMap((b) => b.events), events);
  const small = { type: "event_batch", events: [{ clock: 1 }] };
  assert.deepEqual(splitEventBatch(small, CLIENT_SEND_BUDGET), [small]);
});
check("client budget stays below the server limits", () => {
  assert.ok(CLIENT_SEND_BUDGET < SERVER_MAX_EVENTS_PER_SECOND);
  assert.ok(CLIENT_SEND_BUDGET <= SERVER_MAX_BATCH_SIZE);
  assert.equal(CLIENT_SEND_WINDOW_MS, 1000);
});

// --- SendBudget ---
check("SendBudget rejects bad configuration and costs", () => {
  assert.throws(() => new SendBudget(0, 1000));
  assert.throws(() => new SendBudget(10, 0));
  const b = new SendBudget(10, 1000);
  assert.throws(() => b.tryTake(0, 0));
  assert.throws(() => b.tryTake(0, 11));
  assert.throws(() => b.tryTake(0, 1.5));
});
check("SendBudget refuses a clock that moves backwards", () => {
  const b = new SendBudget(10, 1000);
  assert.equal(b.tryTake(100, 1), true);
  assert.throws(() => b.tryTake(99, 1));
});
check("SendBudget refuses over-budget takes and reports the wait", () => {
  const b = new SendBudget(3, 1000);
  assert.equal(b.tryTake(0, 2), true);
  assert.equal(b.tryTake(100, 1), true);
  assert.equal(b.tryTake(200, 1), false);
  assert.equal(b.msUntilAvailable(200, 1), 800);
  assert.equal(b.msUntilAvailable(200, 3), 900);
  assert.equal(b.tryTake(999, 1), false);
  assert.equal(b.tryTake(1000, 2), true);
  assert.equal(b.msUntilAvailable(1000, 1), 100);
});
check("SendBudget never allows more than limit in any window", () => {
  const b = new SendBudget(CLIENT_SEND_BUDGET, CLIENT_SEND_WINDOW_MS);
  const sent = [];
  let now = 0;
  for (let i = 0; i < 500; i++) {
    const wait = b.msUntilAvailable(now, 1);
    now += wait;
    assert.equal(b.tryTake(now, 1), true);
    sent.push(now);
    now += i % 7;
  }
  for (let i = 0; i < sent.length; i++) {
    const inWindow = sent.filter((t) => t >= sent[i] && t < sent[i] + CLIENT_SEND_WINDOW_MS).length;
    assert.ok(inWindow <= CLIENT_SEND_BUDGET, `window at ${sent[i]} holds ${inWindow}`);
  }
});

// --- PacedQueue ---
check("PacedQueue reports a full queue instead of dropping silently", () => {
  const q = new PacedQueue(new SendBudget(5, 1000), 2);
  assert.equal(q.push({ type: "event", clock: 1 }, 1, false), true);
  assert.equal(q.push({ type: "event", clock: 2 }, 1, false), true);
  assert.equal(q.push({ type: "event", clock: 3 }, 1, false), false);
  assert.equal(q.length, 2);
  assert.throws(() => q.push({ type: "event_batch" }, 6, false));
});
check("PacedQueue keeps items while they cannot be sent", () => {
  const q = new PacedQueue(new SendBudget(5, 1000), 10);
  q.push({ type: "event", clock: 1 }, 1, false);
  assert.deepEqual(q.pump(0, () => false, () => true), { sent: 0, waitMs: 0 });
  assert.equal(q.length, 1);
  assert.deepEqual(q.pump(0, () => true, () => false), { sent: 0, waitMs: 0 });
  assert.equal(q.length, 1);
});
check("PacedQueue paces over-budget messages and resumes in order", () => {
  const q = new PacedQueue(new SendBudget(3, 1000), 10);
  for (let i = 1; i <= 5; i++) q.push({ type: "event", clock: i }, 1, false);
  const out = [];
  const r1 = q.pump(0, () => true, (m) => { out.push(m.clock); return true; });
  assert.deepEqual(r1, { sent: 3, waitMs: 1000 });
  const r2 = q.pump(1000, () => true, (m) => { out.push(m.clock); return true; });
  assert.deepEqual(r2, { sent: 2, waitMs: 0 });
  assert.deepEqual(out, [1, 2, 3, 4, 5]);
});
check("PacedQueue puts request_sync ahead of events, in order", () => {
  const q = new PacedQueue(new SendBudget(10, 1000), 10);
  q.push({ type: "event", clock: 1 }, 1, false);
  q.push({ type: "request_sync", n: 1 }, 1, true);
  q.push({ type: "request_sync", n: 2 }, 1, true);
  const out = [];
  q.pump(0, () => true, (m) => { out.push(m.type + (m.n || m.clock)); return true; });
  assert.deepEqual(out, ["request_sync1", "request_sync2", "event1"]);
});
check("PacedQueue removeWhere and setBudget", () => {
  const q = new PacedQueue(new SendBudget(10, 1000), 10);
  q.push({ type: "request_sync" }, 1, true);
  q.push({ type: "event_batch", events: [] }, 8, false);
  assert.equal(q.removeWhere((m) => m.type === "request_sync"), 1);
  assert.throws(() => q.setBudget(new SendBudget(5, 1000)));
  q.setBudget(new SendBudget(8, 1000));
  assert.equal(q.length, 1);
});

// --- Server frame replay ---
const file = process.argv[2];
let replayed = 0;
if (file) {
  const vectors = JSON.parse(readFileSync(file, "utf8"));
  assert.ok(Array.isArray(vectors.messages) && vectors.messages.length > 0, "messages must be a non-empty array");
  assert.equal(typeof vectors.final_model, "string", "final_model must be a JSON string");
  let state = { version: 0, synced: false };
  let model = null;
  vectors.messages.forEach((raw, index) => {
    const msg = JSON.parse(raw);
    const where = `frame ${index} ${raw.substring(0, 160)}`;
    if (msg.type === "model_sync") {
      assert.equal(classifyModelSync(state, msg.version), "apply", where);
      // The server embeds the model raw ("model":{...}), never as a string.
      assert.ok(msg.model !== null && typeof msg.model === "object", `${where}: model must be a raw JSON object`);
      model = msg.model;
      state = { version: msg.version, synced: true };
    } else if (msg.type === "patch") {
      // The server embeds the ops raw ("ops":[...]), never as a string.
      assert.ok(Array.isArray(msg.ops), `${where}: ops must be a raw JSON array`);
      const ops = msg.ops;
      const verdict = classifyPatch(state, msg.version, ops.length);
      assert.ok(verdict === "apply" || verdict === "ack", `${where}: verdict ${verdict}`);
      if (verdict === "apply") {
        model = applyOps(model, ops);
        state = { version: msg.version, synced: true };
      }
    } else {
      assert.fail(`${where}: unexpected frame type ${msg.type}`);
    }
    replayed++;
  });
  assert.deepEqual(model, JSON.parse(vectors.final_model), "replayed model must equal the final model_sync");
  assert.equal(state.version, vectors.final_version, "replayed revision must equal the final model_sync revision");
}

console.log(`sync vectors ok: ${checks} checks, ${replayed} replayed frames`);
