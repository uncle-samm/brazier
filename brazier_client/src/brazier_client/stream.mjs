// Stream stores for the browser runtime (docs/design/STREAMS.md 6.1, 6.2,
// 8.1). Pure: no DOM, no socket. brazier_client_ffi.mjs decodes the
// `streams` field of every patch and model_sync with decodeStreams, applies
// each entry to its store with applyEntry, and patches the rendered
// containers from the steps applyEntry returns.
//
// This module MUST follow exactly the rules of the test-side reference
// applier, test/brazier/stream_reference.gleam (apply_entry): the shared
// vectors in test/fixtures/stream_vectors.json are run through both
// (brazier_client/test/stream_vectors.mjs here). The order of the checks is
// part of the contract, since a vector names the first fault it hits.
//
// Nothing is repaired. Every malformed field, unknown name, mismatched limit,
// unknown delete, misplaced insert and overfull store is a fault the caller
// turns into a 4000 `stream fault` close (decision D3). The server computes
// trims (D6): the client only checks that the store holds no more than the
// limit after each entry.
//
// The store's role is LiveView's `streamInserts` index plus the DOM children
// of a `phx-update="stream"` container (phoenix_live_view
// assets/js/phoenix_live_view/dom_patch.ts, `perform` and
// `maybeLimitStream`), with the difference that the wire entry already
// carries the final index of each insert and every trim as a delete, so the
// client never computes a position or a trim.

/** The largest limit a stream may declare (STREAMS.md 6.1, stream.new). */
export const MAX_STREAM_LIMIT = 1000;

/** The reasons a stream fault can name (STREAMS.md 6.2). */
export const STREAM_FAULT_REASONS = Object.freeze([
  "malformed",
  "unknown_stream",
  "keep_mismatch",
  "limit_mismatch",
  "delete_unknown_key",
  "insert_wrong_index",
  "insert_past_end",
  "over_limit",
  // Client only: the item's decoder or item function refused an item
  // (render_item returned Error).
  "item_render_failed",
]);

function fault(stream, reason, detail) {
  if (!STREAM_FAULT_REASONS.includes(reason)) throw new Error("stream: unknown fault reason " + reason);
  return { ok: false, fault: { stream, reason, detail } };
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function has(object, field) {
  return Object.prototype.hasOwnProperty.call(object, field);
}

/**
 * Decode the `streams` field of a frame: `{ok: true, entries}` or
 * `{ok: false, fault: {stream, reason: "malformed", detail}}`. The field is
 * required (D5): `undefined` is a fault like any other non-array, never "no
 * change". `stream` is the entry's name when it is a string, else null.
 */
export function decodeStreams(value) {
  if (!Array.isArray(value)) {
    return fault(null, "malformed", value === undefined ? "the frame has no streams field" : "streams is not an array");
  }
  const entries = [];
  for (let index = 0; index < value.length; index++) {
    const decoded = decodeEntry(value[index], index);
    if (!decoded.ok) return decoded;
    entries.push(decoded.entry);
  }
  return { ok: true, entries };
}

function decodeEntry(raw, index) {
  const where = "entry " + index;
  if (!isObject(raw)) return fault(null, "malformed", where + " is not an object");
  const stream = typeof raw.name === "string" ? raw.name : null;
  const bad = (detail) => fault(stream, "malformed", where + ": " + detail);
  if (typeof raw.name !== "string") return bad("name is not a string");
  if (raw.keep !== "first" && raw.keep !== "last") return bad("keep is not \"first\" or \"last\"");
  if (!Number.isInteger(raw.limit) || raw.limit < 1 || raw.limit > MAX_STREAM_LIMIT) {
    return bad("limit is not an integer from 1 to " + MAX_STREAM_LIMIT);
  }
  if (typeof raw.reset !== "boolean") return bad("reset is not a boolean");
  if (!Array.isArray(raw.deletes)) return bad("deletes is not an array");
  for (let i = 0; i < raw.deletes.length; i++) {
    if (typeof raw.deletes[i] !== "string") return bad("delete " + i + " is not a string key");
  }
  if (!Array.isArray(raw.inserts)) return bad("inserts is not an array");
  const inserts = [];
  for (let i = 0; i < raw.inserts.length; i++) {
    const insert = raw.inserts[i];
    if (!isObject(insert)) return bad("insert " + i + " is not an object");
    if (typeof insert.key !== "string") return bad("insert " + i + " key is not a string");
    if (!Number.isInteger(insert.at)) return bad("insert " + i + " at is not an integer");
    // Any JSON value is an item, null included: the field must be present.
    if (!has(insert, "item")) return bad("insert " + i + " has no item");
    inserts.push({ key: insert.key, at: insert.at, item: insert.item });
  }
  return {
    ok: true,
    entry: {
      name: raw.name,
      keep: raw.keep,
      limit: raw.limit,
      reset: raw.reset,
      deletes: [...raw.deletes],
      inserts,
    },
  };
}

/** An empty store for a stream, created by the first entry for its name. */
export function emptyStore(name, keep, limit) {
  if (typeof name !== "string") throw new Error("stream: a store name must be a string");
  if (keep !== "first" && keep !== "last") throw new Error("stream: keep must be first or last");
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_STREAM_LIMIT) throw new Error("stream: bad limit " + limit);
  return { name, keep, limit, keys: [], items: new Map() };
}

/**
 * Apply one decoded entry to `store` (null when no entry for the name has
 * arrived yet; the entry's keep and limit then create it). `knownNames` is
 * the Set of stream names the bundle declares (`stream_names`).
 *
 * Returns `{ok: true, store, steps}` with a new store, or
 * `{ok: false, fault}`. The input store is never changed, so a fault leaves
 * it exactly as it was. A store is `{name, keep, limit, keys, items}`:
 * `keys` in order, `items` a Map from key to the item's parsed JSON value.
 * What is rendered from it (nodes, handler tables) belongs to the DOM side.
 *
 * `steps` is what the DOM must do, in order, to follow the store:
 * - `{op: "reset"}`: remove every child;
 * - `{op: "delete", key}`: remove the child of `key`;
 * - `{op: "insert", key, at, before}`: render a new item and put it before
 *   the child of `before` (null: at the end);
 * - `{op: "update", key, at}`: render the item again and morph its child in
 *   place, which is at index `at`.
 */
export function applyEntry(store, entry, knownNames) {
  if (!(knownNames instanceof Set)) throw new Error("stream: knownNames must be a Set");
  if (store !== null && store.name !== entry.name) throw new Error("stream: applyEntry got the store of another stream");
  // The order of these checks is stream_reference.apply_entry's.
  if (!knownNames.has(entry.name)) return fault(entry.name, "unknown_stream", "the bundle declares no stream of this name");
  const current = store === null ? emptyStore(entry.name, entry.keep, entry.limit) : store;
  if (entry.keep !== current.keep) {
    return fault(entry.name, "keep_mismatch", `entry keep ${entry.keep}, store keep ${current.keep}`);
  }
  if (entry.limit !== current.limit) {
    return fault(entry.name, "limit_mismatch", `entry limit ${entry.limit}, store limit ${current.limit}`);
  }
  const steps = [];
  let keys;
  let items;
  if (entry.reset) {
    keys = [];
    items = new Map();
    steps.push({ op: "reset" });
  } else {
    keys = [...current.keys];
    items = new Map(current.items);
  }
  for (const key of entry.deletes) {
    if (!items.has(key)) return fault(entry.name, "delete_unknown_key", "delete of a key the store does not hold");
    keys.splice(keys.indexOf(key), 1);
    items.delete(key);
    steps.push({ op: "delete", key });
  }
  for (const { key, at, item } of entry.inserts) {
    if (items.has(key)) {
      const index = keys.indexOf(key);
      if (index !== at) {
        return fault(entry.name, "insert_wrong_index", `update of a held key at ${at}, the key is at ${index}`);
      }
      items.set(key, item);
      steps.push({ op: "update", key, at });
    } else {
      if (at < 0 || at > keys.length) {
        return fault(entry.name, "insert_past_end", `insert of a new key at ${at} into ${keys.length} items`);
      }
      const before = at < keys.length ? keys[at] : null;
      keys.splice(at, 0, key);
      items.set(key, item);
      steps.push({ op: "insert", key, at, before });
    }
  }
  if (keys.length > current.limit) {
    return fault(entry.name, "over_limit", `${keys.length} items after the entry, limit ${current.limit}`);
  }
  if (keys.length !== items.size) throw new Error("stream: store keys and items disagree");
  return { ok: true, store: { name: current.name, keep: current.keep, limit: current.limit, keys, items }, steps };
}

/** Counts of an applied entry's steps, for the debug log (never keys). */
export function stepCounts(steps) {
  const counts = { reset: false, inserts: 0, updates: 0, deletes: 0 };
  for (const step of steps) {
    if (step.op === "reset") counts.reset = true;
    else if (step.op === "insert") counts.inserts++;
    else if (step.op === "update") counts.updates++;
    else if (step.op === "delete") counts.deletes++;
    else throw new Error("stream: unknown step " + step.op);
  }
  return counts;
}
