// Runs the shared stream vectors (test/fixtures/stream_vectors.json, written
// by the Gleam side and checked there against brazier/internal/stream_window
// and test/brazier/stream_reference.gleam) through the browser's applier,
// brazier_client/src/brazier_client/stream.mjs.
//
// Usage: node brazier_client/test/stream_vectors.mjs
//
// Every delta vector: a store holding `before` that applies `entry` holds
// `after`, and replaying the returned DOM steps on `before`'s keys gives the
// same order. Every fault vector: the entry faults with the vector's reason,
// and the store is left untouched. Unhappy paths come first. Any failure
// exits non-zero.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  applyEntry,
  decodeStreams,
  emptyStore,
  MAX_STREAM_LIMIT,
  STREAM_FAULT_REASONS,
  stepCounts,
} from "../src/brazier_client/stream.mjs";

const VECTORS = fileURLToPath(new URL("../../test/fixtures/stream_vectors.json", import.meta.url));
const vectors = JSON.parse(readFileSync(VECTORS, "utf8"));

let checks = 0;
function check(name, fn) {
  try {
    fn();
  } catch (error) {
    console.error("FAIL " + name);
    throw error;
  }
  checks++;
}

function storeOf(vector) {
  const store = emptyStore(vector.stream, vector.keep, vector.limit);
  for (const { key, item } of vector.before) {
    assert.ok(!store.items.has(key), `${vector.name}: 'before' repeats key ${key}`);
    store.keys.push(key);
    store.items.set(key, { item, handlers: null });
  }
  return store;
}

function contents(store) {
  return store.keys.map((key) => ({ key, item: store.items.get(key).item }));
}

// Apply a frame's streams field (one entry here) as the runtime does: the
// store is looked up by the entry's name, and the bundle declares only the
// vector's stream. So the reference's "store s gets entry t" is an entry for
// a name with no store that the bundle does not declare.
function applyFrame(vector, store, streams) {
  const decoded = decodeStreams(streams);
  if (!decoded.ok) return decoded;
  assert.equal(decoded.entries.length, 1, `${vector.name}: one entry per vector`);
  const entry = decoded.entries[0];
  return applyEntry(entry.name === store.name ? store : null, entry, new Set([vector.stream]));
}

// Replay DOM steps on a list of keys, checking each step's own claims (an
// update is where it says it is, an insert's `before` is the key at `at`).
function replaySteps(keys, steps) {
  let out = [...keys];
  for (const step of steps) {
    if (step.op === "reset") out = [];
    else if (step.op === "delete") {
      const index = out.indexOf(step.key);
      assert.ok(index >= 0, "delete step of a key the DOM does not hold: " + step.key);
      out.splice(index, 1);
    } else if (step.op === "update") {
      assert.equal(out.indexOf(step.key), step.at, "update step is not at its index: " + step.key);
    } else if (step.op === "insert") {
      assert.ok(!out.includes(step.key), "insert step of a key the DOM holds: " + step.key);
      assert.equal(step.before, step.at < out.length ? out[step.at] : null, "insert step's before is not the key at its index");
      out.splice(step.at, 0, step.key);
    } else assert.fail("unknown step " + step.op);
  }
  return out;
}

// --- vector file shape ---
check("the vector file has 18 deltas and 15 faults", () => {
  assert.equal(vectors.deltas.length, 18);
  assert.equal(vectors.faults.length, 15);
});

// --- faults first ---
for (const vector of vectors.faults) {
  check("fault: " + vector.name, () => {
    assert.ok(STREAM_FAULT_REASONS.includes(vector.reason), "unknown reason in the vector: " + vector.reason);
    const store = storeOf(vector);
    const snapshot = JSON.stringify(contents(store));
    const result = applyFrame(vector, store, [vector.entry]);
    assert.equal(result.ok, false, "the entry applied instead of faulting");
    assert.equal(result.fault.reason, vector.reason, result.fault.detail);
    assert.equal(typeof result.fault.detail, "string");
    assert.ok(result.fault.detail.length > 0, "a fault must say why");
    assert.equal(JSON.stringify(contents(store)), snapshot, "a fault changed the store");
  });
}

check("streams that is missing or not an array is malformed", () => {
  for (const value of [undefined, null, {}, "[]", 0, true]) {
    const result = decodeStreams(value);
    assert.equal(result.ok, false, JSON.stringify(value));
    assert.equal(result.fault.reason, "malformed");
    assert.equal(result.fault.stream, null);
  }
  assert.match(decodeStreams(undefined).fault.detail, /no streams field/);
});

check("an entry that is not an object, or has a bad field, is malformed", () => {
  const good = { name: "s", keep: "last", limit: 3, reset: false, deletes: [], inserts: [] };
  const bad = [
    null,
    [],
    "s",
    { ...good, name: 7 },
    { ...good, keep: undefined },
    { ...good, limit: 2.5 },
    { ...good, limit: MAX_STREAM_LIMIT + 1 },
    { ...good, limit: -1 },
    { ...good, reset: "false" },
    { ...good, deletes: "a" },
    { ...good, deletes: [1] },
    { ...good, inserts: {} },
    { ...good, inserts: [null] },
    { ...good, inserts: [{ key: 1, at: 0, item: 1 }] },
    { ...good, inserts: [{ key: "a", at: 0.5, item: 1 }] },
  ];
  for (const entry of bad) {
    const result = decodeStreams([good, entry]);
    assert.equal(result.ok, false, JSON.stringify(entry));
    assert.equal(result.fault.reason, "malformed", JSON.stringify(entry));
    assert.match(result.fault.detail, /^entry 1/);
  }
  // The fault names the stream when the name is readable.
  assert.equal(decodeStreams([{ ...good, reset: 1 }]).fault.stream, "s");
});

check("a null item is an item; extra fields are ignored", () => {
  const result = decodeStreams([
    { name: "s", keep: "first", limit: 1, reset: true, deletes: [], inserts: [{ key: "a", at: 0, item: null, x: 1 }], y: 2 },
  ]);
  assert.equal(result.ok, true);
  assert.deepEqual(result.entries[0].inserts, [{ key: "a", at: 0, item: null }]);
});

check("an unknown stream faults even when no store exists", () => {
  const decoded = decodeStreams([{ name: "t", keep: "last", limit: 3, reset: false, deletes: [], inserts: [] }]);
  const result = applyEntry(null, decoded.entries[0], new Set(["s"]));
  assert.equal(result.ok, false);
  assert.equal(result.fault.reason, "unknown_stream");
  assert.equal(result.fault.stream, "t");
});

check("applyEntry refuses a store of another stream and a knownNames that is not a Set", () => {
  const entry = decodeStreams([{ name: "s", keep: "last", limit: 3, reset: false, deletes: [], inserts: [] }]).entries[0];
  assert.throws(() => applyEntry(emptyStore("t", "last", 3), entry, new Set(["s", "t"])), /another stream/);
  assert.throws(() => applyEntry(null, entry, ["s"]), /must be a Set/);
});

check("emptyStore refuses a bad keep or limit", () => {
  assert.throws(() => emptyStore("s", "middle", 3));
  assert.throws(() => emptyStore("s", "last", 0));
  assert.throws(() => emptyStore("s", "last", MAX_STREAM_LIMIT + 1));
  assert.throws(() => emptyStore(1, "last", 3));
});

check("the first entry for a name creates its store from the entry's keep and limit", () => {
  const entry = decodeStreams([
    { name: "s", keep: "first", limit: 2, reset: false, deletes: [], inserts: [{ key: "a", at: 0, item: 1 }] },
  ]).entries[0];
  const result = applyEntry(null, entry, new Set(["s"]));
  assert.equal(result.ok, true);
  assert.deepEqual([result.store.keep, result.store.limit, result.store.keys], ["first", 2, ["a"]]);
});

// --- deltas ---
let applied = 0;
for (const vector of vectors.deltas) {
  check("delta: " + vector.name, () => {
    const store = storeOf(vector);
    const snapshot = JSON.stringify(contents(store));
    if (vector.entry === null) {
      // The server sends nothing: the store must already hold `after`.
      assert.deepEqual(contents(store), vector.after, "a vector without an entry must not change the store");
      return;
    }
    const result = applyFrame(vector, store, [vector.entry]);
    assert.equal(result.ok, true, result.ok ? "" : `${result.fault.reason}: ${result.fault.detail}`);
    assert.deepEqual(contents(result.store), vector.after);
    assert.equal(JSON.stringify(contents(store)), snapshot, "applying changed the input store");
    assert.deepEqual(replaySteps(store.keys, result.steps), result.store.keys, "the DOM steps do not give the store's order");
    const counts = stepCounts(result.steps);
    assert.equal(counts.reset, vector.entry.reset);
    assert.equal(counts.deletes, vector.entry.deletes.length);
    assert.equal(counts.inserts + counts.updates, vector.entry.inserts.length);
    applied++;
  });
}

check("every delta with an entry was applied", () => {
  assert.equal(applied, vectors.deltas.filter((v) => v.entry !== null).length);
  assert.ok(applied >= 14, "too few delta vectors carry an entry");
});

console.log(`stream vectors ok: ${checks} checks, ${vectors.deltas.length} deltas, ${vectors.faults.length} faults`);
