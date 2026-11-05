// JSON Patch Operations for Brazier State Sync.
//
// Ops follow RFC 6902 (JSON Patch) with RFC 6901 (JSON Pointer) paths:
//   add      - add an object member, or insert into an array at an index / "-"
//   replace  - replace an existing value ("" replaces the whole document)
//   remove   - remove an existing object member or array element
//   append   - Brazier extension: concatenate a list onto an existing array
//
// This module MUST implement exactly the same semantics as the server mirror
// in src/brazier_patch_ffi.erl. Both sides are exercised against the same
// randomly generated vectors (see test/brazier/patch_test.gleam and
// brazier_client/test/patch_vectors.mjs).
//
// Every malformed op, unknown op, invalid pointer or missing target THROWS.
// Nothing is skipped silently: the caller logs the error and requests a full
// model sync from the server.
//
// The "Wire sync policy" section at the end holds the pure decision rules the
// browser runtime (brazier_client_ffi.mjs) applies to server messages, close
// codes and outbound pacing. It lives here because the build bundles only this
// module, handler.gleam and brazier_client_ffi.mjs, and the rules must be
// testable without a DOM (brazier_client/test/sync_vectors.mjs).

/**
 * Keys no patch path may pass through: on a JS object a path through one can
 * reach Object.prototype (prototype pollution). Mirrors unsafe_keys/0 in
 * src/brazier_patch_ffi.erl, the canonical list; test/brazier/patch_test.gleam
 * asserts the two are equal. Neither diff emits a path through one (the
 * object holding a changed unsafe key is replaced whole) and both appliers
 * refuse one.
 */
export const UNSAFE_PATCH_KEYS = Object.freeze(["__proto__", "constructor", "prototype"]);
const UNSAFE_KEYS = new Set(UNSAFE_PATCH_KEYS);

/** Error thrown for any patch that cannot be applied exactly. */
export class PatchError extends Error {
  constructor(message) {
    super(message);
    this.name = "PatchError";
  }
}

/**
 * Diff two model values and produce an array of patch operations.
 * Mirrors diff_values/3 in brazier_patch_ffi.erl.
 */
export function diffModels(oldModel, newModel) {
  const ops = [];
  diffValues(oldModel, newModel, "", ops);
  return ops;
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function diffValues(oldVal, newVal, path, ops) {
  if (deepEqual(oldVal, newVal)) return;
  if (isObject(oldVal) && isObject(newVal)) {
    diffObject(oldVal, newVal, path, ops);
  } else if (Array.isArray(oldVal) && Array.isArray(newVal)) {
    diffArray(oldVal, newVal, path, ops);
  } else {
    ops.push({ op: "replace", path, value: newVal });
  }
}

// Mirrors diff_maps/3: when an unsafe key is added, removed or changed, the
// object holding it (the nearest safe parent) is replaced whole, so no path
// ever passes through an unsafe key.
function diffObject(oldObj, newObj, basePath, ops) {
  if (touchesUnsafeKey(oldObj, newObj)) {
    ops.push({ op: "replace", path: basePath, value: newObj });
    return;
  }
  const oldKeys = Object.keys(oldObj).sort(compareKeys);
  for (const key of oldKeys) {
    if (!Object.prototype.hasOwnProperty.call(newObj, key)) {
      ops.push({ op: "remove", path: childPath(basePath, key) });
    }
  }
  const newKeys = Object.keys(newObj).sort(compareKeys);
  for (const key of newKeys) {
    const path = childPath(basePath, key);
    if (!Object.prototype.hasOwnProperty.call(oldObj, key)) {
      ops.push({ op: "add", path, value: newObj[key] });
    } else {
      diffValues(oldObj[key], newObj[key], path, ops);
    }
  }
}

// True when an unsafe key was added, removed or changed. Mirrors
// touches_unsafe_key/2: a lookup per unsafe key, never a walk of the keys.
function touchesUnsafeKey(oldObj, newObj) {
  for (const key of UNSAFE_PATCH_KEYS) {
    const inOld = Object.prototype.hasOwnProperty.call(oldObj, key);
    const inNew = Object.prototype.hasOwnProperty.call(newObj, key);
    if (inOld !== inNew) return true;
    if (inOld && !deepEqual(oldObj[key], newObj[key])) return true;
  }
  return false;
}

// Erlang sorts binary map keys bytewise; compare UTF-8 bytes to match.
const utf8 = new TextEncoder();
function compareKeys(a, b) {
  const ab = utf8.encode(a);
  const bb = utf8.encode(b);
  const len = Math.min(ab.length, bb.length);
  for (let i = 0; i < len; i++) {
    if (ab[i] !== bb[i]) return ab[i] - bb[i];
  }
  return ab.length - bb.length;
}

function diffArray(oldArr, newArr, path, ops) {
  let prefix = 0;
  while (
    prefix < oldArr.length &&
    prefix < newArr.length &&
    deepEqual(oldArr[prefix], newArr[prefix])
  ) {
    prefix++;
  }
  let suffix = 0;
  while (
    suffix < oldArr.length - prefix &&
    suffix < newArr.length - prefix &&
    deepEqual(oldArr[oldArr.length - 1 - suffix], newArr[newArr.length - 1 - suffix])
  ) {
    suffix++;
  }
  const oldMidLen = oldArr.length - prefix - suffix;
  const newMidLen = newArr.length - prefix - suffix;
  const paired = Math.min(oldMidLen, newMidLen);
  const local = [];
  for (let i = 0; i < paired; i++) {
    const index = prefix + i;
    diffValues(oldArr[index], newArr[index], childPath(path, index), local);
  }
  if (oldMidLen > paired) {
    for (let index = prefix + oldMidLen - 1; index >= prefix + paired; index--) {
      local.push({ op: "remove", path: childPath(path, index) });
    }
  } else if (newMidLen > paired) {
    const surplus = newArr.slice(prefix + paired, prefix + newMidLen);
    if (suffix === 0) {
      local.push({ op: "append", path, value: surplus });
    } else {
      for (let i = 0; i < surplus.length; i++) {
        local.push({ op: "add", path: childPath(path, prefix + paired + i), value: surplus[i] });
      }
    }
  }
  if (local.length > newArr.length) {
    ops.push({ op: "replace", path, value: newArr });
  } else {
    for (const op of local) ops.push(op);
  }
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (a === null || b === null || a === undefined || b === undefined) return a === b;
  if (typeof a !== typeof b) return false;
  if (typeof a !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;

  if (Array.isArray(a)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!deepEqual(a[i], b[i])) return false;
    }
    return true;
  }

  const keysA = Object.keys(a);
  const keysB = Object.keys(b);
  if (keysA.length !== keysB.length) return false;
  for (let i = 0; i < keysA.length; i++) {
    const key = keysA[i];
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (!deepEqual(a[key], b[key])) return false;
  }
  return true;
}

// === RFC 6901 JSON Pointer ===

/** Escape one reference token: "~" -> "~0", then "/" -> "~1". */
export function escapePathSegment(segment) {
  return String(segment).replace(/~/g, "~0").replace(/\//g, "~1");
}

function childPath(base, key) {
  return base + "/" + escapePathSegment(key);
}

/**
 * Parse a JSON pointer into reference tokens.
 * "" is the whole document; "/" is the single token "" (an empty key).
 * Throws PatchError for pointers that do not start with "/" or contain a "~"
 * not followed by 0 or 1.
 */
export function parsePath(path) {
  if (typeof path !== "string") {
    throw new PatchError("Invalid JSON pointer: pointer must be a string");
  }
  if (path === "") return [];
  if (path[0] !== "/") {
    throw new PatchError(`Invalid JSON pointer: ${JSON.stringify(path)} must be empty or start with /`);
  }
  return path
    .slice(1)
    .split("/")
    .map((segment) => {
      if (/~(?![01])/.test(segment)) {
        throw new PatchError(`Invalid JSON pointer: ${JSON.stringify(path)} has ~ not followed by 0 or 1`);
      }
      // ~1 must be decoded before ~0 so "~01" decodes to "~1", not "/".
      return segment.replace(/~1/g, "/").replace(/~0/g, "~");
    });
}

// === Apply Engine ===
//
// Copy-on-write once per container per patch. Copying every container on an
// op's path for EVERY op (a slice or spread per level) made a patch of k ops
// on an n-element array cost O(k * n) in copies alone. applyOps now records
// the containers it copied during the call in a WeakSet: the first op that
// walks through a container copies it shallowly and links the copy into its
// (already copied) parent; later ops edit the copy in place. The input
// model and the op values are never in that set, so neither is ever
// mutated: a throwing op leaves the cached model intact and the partial
// copies are dropped. Pattern: Immer's copy-on-write drafts (copy on first
// write, hand back the copies), without proxies.

/**
 * Apply patch operations to a model. Returns a new value — the input is not
 * modified. Throws PatchError on any op that cannot be applied exactly.
 */
export function applyOps(model, ops) {
  if (!Array.isArray(ops)) {
    throw new PatchError("Patch ops must be an array");
  }
  const owned = new WeakSet();
  let result = model;
  for (let i = 0; i < ops.length; i++) {
    result = applyOp(result, ops[i], owned);
  }
  return result;
}

function applyOp(model, op, owned) {
  if (!isObject(op) || typeof op.op !== "string") {
    throw new PatchError(`Malformed patch op: ${JSON.stringify(op)}`);
  }
  const tokens = parsePath(op.path);
  assertSafeSegments(tokens);
  switch (op.op) {
    case "replace":
      requireValue(op);
      if (tokens.length === 0) return op.value;
      return editAt(model, tokens, owned, (parent, token) => replaceIn(parent, token, op.value));
    case "add":
      requireValue(op);
      if (tokens.length === 0) return op.value;
      return editAt(model, tokens, owned, (parent, token) => addIn(parent, token, op.value));
    case "remove":
      if (tokens.length === 0) throw new PatchError("Cannot remove the document root");
      return editAt(model, tokens, owned, removeIn);
    case "append":
      if (!Array.isArray(op.value)) {
        throw new PatchError(`append value must be an array at ${JSON.stringify(op.path)}`);
      }
      if (tokens.length === 0) return appendTo(model, op.value, op.path, owned);
      return editAt(model, tokens, owned, (parent, token) => {
        parent[token] = appendTo(getIn(parent, token), op.value, op.path, owned);
      });
    default:
      throw new PatchError(`Unknown patch op: ${JSON.stringify(op.op)}`);
  }
}

function requireValue(op) {
  if (!Object.prototype.hasOwnProperty.call(op, "value")) {
    throw new PatchError(`Patch op ${op.op} at ${JSON.stringify(op.path)} has no value`);
  }
}

// Walk to the parent of the last token, owning every container on the way,
// and run edit(parent, lastToken) on the owned parent. Returns the owned root.
// `parent[token] = child` is safe: getIn validated the token (an existing
// member, or a canonical array index) and assertSafeSegments refused the
// unsafe keys, so it can never reach an inherited accessor.
function editAt(model, tokens, owned, edit) {
  const root = own(model, owned);
  let parent = root;
  for (let i = 0; i < tokens.length - 1; i++) {
    const token = tokens[i];
    const child = own(getIn(parent, token), owned);
    parent[token] = child;
    parent = child;
  }
  edit(parent, tokens[tokens.length - 1]);
  return root;
}

// The copy of a container this patch may edit in place. Scalars pass
// through (the next step refuses them as non-containers).
function own(value, owned) {
  if (typeof value !== "object" || value === null || owned.has(value)) return value;
  // Spread, never Object.assign: JSON.parse makes a "__proto__" key an own
  // data property, and assign would call the inherited __proto__ setter
  // (prototype change) instead of copying it.
  const copy = Array.isArray(value) ? value.slice() : { ...value };
  owned.add(copy);
  return copy;
}

function getIn(node, token) {
  if (Array.isArray(node)) return node[existingIndex(node, token)];
  if (isObject(node)) {
    if (!Object.prototype.hasOwnProperty.call(node, token)) {
      throw new PatchError(`Missing member ${JSON.stringify(token)}`);
    }
    return node[token];
  }
  throw new PatchError(`Cannot traverse ${JSON.stringify(token)} into a non-container`);
}

// The edits below mutate `node`, which editAt has made an owned copy.

function replaceIn(node, token, value) {
  if (Array.isArray(node)) {
    node[existingIndex(node, token)] = value;
    return;
  }
  if (isObject(node)) {
    if (!Object.prototype.hasOwnProperty.call(node, token)) {
      throw new PatchError(`Missing member ${JSON.stringify(token)}`);
    }
    node[token] = value;
    return;
  }
  throw new PatchError(`Cannot replace ${JSON.stringify(token)} in a non-container`);
}

function addIn(node, token, value) {
  if (Array.isArray(node)) {
    if (token === "-") {
      node.push(value);
      return;
    }
    const index = parseIndex(token);
    if (index > node.length) {
      throw new PatchError(`Array index ${token} out of bounds (length ${node.length})`);
    }
    node.splice(index, 0, value);
    return;
  }
  if (isObject(node)) {
    node[token] = value;
    return;
  }
  throw new PatchError(`Cannot add ${JSON.stringify(token)} to a non-container`);
}

function removeIn(node, token) {
  if (Array.isArray(node)) {
    node.splice(existingIndex(node, token), 1);
    return;
  }
  if (isObject(node)) {
    if (!Object.prototype.hasOwnProperty.call(node, token)) {
      throw new PatchError(`Missing member ${JSON.stringify(token)}`);
    }
    delete node[token];
    return;
  }
  throw new PatchError(`Cannot remove ${JSON.stringify(token)} from a non-container`);
}

// Push the items onto an owned copy of the target array and return it. A
// loop, not push(...items): spreading a long list overflows the call stack.
function appendTo(node, items, path, owned) {
  if (!Array.isArray(node)) {
    throw new PatchError(`append target ${JSON.stringify(path)} is not an array`);
  }
  const target = own(node, owned);
  for (let i = 0; i < items.length; i++) target.push(items[i]);
  return target;
}

function existingIndex(arr, token) {
  const index = parseIndex(token);
  if (index >= arr.length) {
    throw new PatchError(`Array index ${token} out of bounds (length ${arr.length})`);
  }
  return index;
}

// RFC 6901 array index: "0" or a decimal without leading zeros.
function parseIndex(token) {
  if (!/^(0|[1-9][0-9]*)$/.test(token)) {
    throw new PatchError(`Invalid array index ${JSON.stringify(token)}`);
  }
  return Number(token);
}

function assertSafeSegments(segments) {
  for (let i = 0; i < segments.length; i++) {
    if (UNSAFE_KEYS.has(segments[i])) {
      throw new PatchError(`Unsafe patch path segment: ${segments[i]}`);
    }
  }
}

// === Wire sync policy ===
//
// Versioning rule (mirrors the runtime module docs in src/brazier/runtime.gleam):
// the server keeps ONE revision per runtime. It bumps only when the
// client-visible model JSON changes and is broadcast. A patch carries the
// revision it produces, so it applies only on top of revision - 1. A
// model_sync carries the current revision and replaces the cached model. An
// empty patch ("[]") is an ack: it carries the current revision and only
// advances ack_clock. Navigation and joins never bump the revision.

/** Server default for SecurityLimits.max_events_per_second. */
export const SERVER_MAX_EVENTS_PER_SECOND = 50;
/** Server limit on events in one event_batch (transport max_batch_size). */
export const SERVER_MAX_BATCH_SIZE = 100;
/**
 * Client send budget per window. Below the server limit so network jitter,
 * which can compress the arrival times of messages paced on the client, can
 * not push a server window over SERVER_MAX_EVENTS_PER_SECOND.
 */
export const CLIENT_SEND_BUDGET = 40;
export const CLIENT_SEND_WINDOW_MS = 1000;
/** Server limit is 2 heartbeats per second; keep at most one per 500ms. */
export const HEARTBEAT_MIN_INTERVAL_MS = 500;
export const RECONNECT_BASE_MS = 1000;
export const RECONNECT_MAX_MS = 30000;
export const RECONNECT_JITTER_MS = 1000;
/** Close code for a revoked session or expired authentication. */
export const CLOSE_AUTH_REVOKED = 4401;
/**
 * Close code for a join whose build id is not the client bundle the server
 * serves now: the app was rebuilt since the page loaded. It is in the reload
 * range, so the page reloads (behind the reload guard) and gets the new bundle.
 * It is 4000 + 499, the one status an init refusal cannot use, so it never
 * shares a code with an init refusal (4409 is an init 409).
 */
export const CLOSE_STALE_BUILD = 4499;
/**
 * Close codes 4400 to 4499: the server refused this page's session. `init`
 * refused it with a client error (4000 + an HTTP 4xx status, 4401 also for a
 * revoked session), or the page runs an older build (CLOSE_STALE_BUILD). The
 * page is stale for this session, so a new page load decides: the server
 * renders it again, or answers with its error page, which opens no socket.
 */
export const CLOSE_RELOAD_MIN = 4400;
export const CLOSE_RELOAD_MAX = 4499;
/**
 * Close code for a mount the server's route middleware refused: the server
 * completed the handshake only to say so, because a browser cannot read
 * the HTTP status of a refused upgrade. The reason is
 * `middleware refused <status>`. The client loads the current URL, so the
 * middleware's own answer (a redirect to a login page, a 403 page) is
 * shown, behind the same reload guard. Reference: Phoenix LiveView's
 * `view.ts` `onJoinError` navigates to the page's URL when a join is
 * refused as unauthorized.
 */
export const CLOSE_MIDDLEWARE_REFUSED = 4600;

/**
 * The build id of a client bundle, from the URL its script was loaded from:
 * the hex content hash in `/brazier_client_<hash>.js` (8 to 64 hex digits, the
 * names the build tool writes to the manifest). A query or fragment is
 * ignored. Returns null for any other URL, such as the stable
 * `/brazier_client.js`, or for no URL at all (`src` null or empty).
 * Reference: LiveView's `phx-track-static` compares the digested asset URLs
 * of the page with the server's on join.
 */
export function buildIdFromScriptSrc(src) {
  if (src === null || src === undefined || src === "") return null;
  if (typeof src !== "string") {
    throw new Error("buildIdFromScriptSrc: the script src must be a string, got " + typeof src);
  }
  const path = src.split("#")[0].split("?")[0];
  const match = /\/brazier_client_([0-9a-fA-F]{8,64})\.js$/.exec(path);
  return match === null ? null : match[1];
}
/**
 * The reload guard: at most MAX_RELOADS refusal reloads per tab within
 * RELOAD_WINDOW_MS. The times are kept in sessionStorage under
 * RELOAD_HISTORY_KEY, so they survive the reloads they count.
 */
export const MAX_RELOADS = 3;
export const RELOAD_WINDOW_MS = 60000;
export const RELOAD_HISTORY_KEY = "brazier:reloads";

function isRevision(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

/**
 * Whether `value` is a valid event clock or ack_clock: a non-negative safe
 * integer. The server always sends ack_clock and the client stamps every
 * event, so anything else is a protocol error, never a default of 0.
 */
export function isWireClock(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

/**
 * Why `path` is not a same-origin absolute path for a page at `origin`, or
 * null when it is one.
 *
 * A browser resolves more than "//host" to another origin: the URL parser
 * reads "\" as "/" and strips tab, newline and carriage return anywhere, so
 * "/\evil.com" and "/<tab>/evil.com" both load evil.com. The character rule
 * is Phoenix's validate_local_url (no leading "//", no "\", no "/%09") plus
 * every ASCII control character; it is the same rule, with the same
 * reasons, as check_local_path in src/brazier/router.gleam (router_test
 * compares the two). The path must then also resolve to `origin`.
 */
export function localPathRefusal(path, origin) {
  if (typeof path !== "string") return "it is not a string";
  if (path.startsWith("//") || path.startsWith("/\\")) {
    return "it starts with two slashes, which a browser reads as another host";
  }
  if (!path.startsWith("/")) return 'it does not start with "/"';
  if (path.includes("\\")) return 'it contains a backslash, which a browser reads as "/"';
  if (path.includes("/%09")) return 'it contains "/%09", an encoded tab some browsers strip';
  if (/[\u0000-\u001f\u007f]/.test(path)) {
    return 'it contains a control character, which a browser may strip (a tab between two slashes leaves "//")';
  }
  let resolved;
  try {
    resolved = new URL(path, origin);
  } catch (e) {
    return "it does not resolve against " + String(origin) + ": " + e.message;
  }
  if (resolved.origin !== origin) return "it resolves to " + resolved.origin + ", not " + origin;
  return null;
}

/**
 * Decide what to do with a model_sync.
 * state = { version, synced } where synced is false until the first
 * model_sync of the current connection has been applied.
 * Returns "invalid" | "stale" | "apply".
 */
export function classifyModelSync(state, version) {
  if (!isRevision(version)) return "invalid";
  if (state.synced && version < state.version) return "stale";
  return "apply";
}

/**
 * Decide what to do with a patch carrying `opsCount` ops at `version`.
 * Returns "invalid" | "gap" | "stale" | "ack" | "apply".
 *   gap   - the patch does not build on the cached revision: request a resync
 *   stale - already covered by the cached revision: ignore
 *   ack   - empty patch at the cached revision: advance ack_clock only
 *   apply - patch builds exactly on the cached revision
 */
export function classifyPatch(state, version, opsCount) {
  if (!isRevision(version) || !Number.isSafeInteger(opsCount) || opsCount < 0) {
    return "invalid";
  }
  if (!state.synced) return "gap";
  if (opsCount === 0) {
    if (version === state.version) return "ack";
    return version < state.version ? "stale" : "gap";
  }
  if (version === state.version + 1) return "apply";
  return version <= state.version ? "stale" : "gap";
}

/**
 * "reload" for 4400 to 4499 (the server refused this page's session: never
 * reconnect with it), "navigate" for CLOSE_MIDDLEWARE_REFUSED (load the
 * current URL so the middleware's answer shows), else "reconnect" with
 * backoff. That includes 4500 to 4599 (`init` refused with a server error,
 * such as 4503 for a store that is down), 1011 (`init` crashed) and every
 * code this client does not know: the server may recover, and the backoff
 * keeps a server that keeps refusing at one attempt per RECONNECT_MAX_MS.
 */
export function closeAction(code) {
  if (!Number.isSafeInteger(code)) {
    throw new Error("closeAction: the close code must be an integer, got " + code);
  }
  if (code === CLOSE_MIDDLEWARE_REFUSED) return "navigate";
  return code >= CLOSE_RELOAD_MIN && code <= CLOSE_RELOAD_MAX ? "reload" : "reconnect";
}

/**
 * Parse the stored reload history: `null` when nothing is stored, else a JSON
 * array of at most MAX_RELOADS timestamps (milliseconds since the epoch).
 * Returns { ok: true, history } or { ok: false, reason }.
 */
export function parseReloadHistory(raw) {
  if (raw === null) return { ok: true, history: [] };
  let value;
  try {
    value = JSON.parse(raw);
  } catch (e) {
    return { ok: false, reason: "not JSON (" + e.message + "): " + raw };
  }
  if (!Array.isArray(value) || !value.every((t) => Number.isSafeInteger(t) && t >= 0)) {
    return { ok: false, reason: "not a list of timestamps: " + raw };
  }
  if (value.length > MAX_RELOADS) {
    return { ok: false, reason: "more than " + MAX_RELOADS + " entries: " + raw };
  }
  return { ok: true, history: value };
}

/**
 * Decide whether a refused page may reload at `now`, given the times of this
 * tab's earlier refusal reloads. Returns { action: "reload" | "give_up",
 * history }, `history` being what to store: the reloads still inside the
 * window, plus this one when it reloads. A time ahead of `now` (the clock
 * went back) still counts, so a clock change never opens a reload loop.
 */
export function reloadDecision(history, now) {
  if (!Number.isSafeInteger(now) || now < 0) {
    throw new Error("reloadDecision: now must be a non-negative integer, got " + now);
  }
  const recent = history.filter((t) => now - t < RELOAD_WINDOW_MS);
  if (recent.length >= MAX_RELOADS) return { action: "give_up", history: recent };
  return { action: "reload", history: [...recent, now] };
}

/** Exponential backoff with jitter. `random01` is in [0, 1). */
export function reconnectDelayMs(attempts, random01) {
  if (!Number.isSafeInteger(attempts) || attempts < 0) {
    throw new Error("reconnectDelayMs: attempts must be a non-negative integer, got " + attempts);
  }
  if (typeof random01 !== "number" || !(random01 >= 0 && random01 < 1)) {
    throw new Error("reconnectDelayMs: random01 must be in [0, 1), got " + random01);
  }
  const base = Math.min(RECONNECT_BASE_MS * Math.pow(2, Math.min(attempts, 30)), RECONNECT_MAX_MS);
  return base + Math.floor(random01 * RECONNECT_JITTER_MS);
}

/** True when a heartbeat may be sent at `now` given the previous one at `lastAt`. */
export function heartbeatAllowed(lastAt, now) {
  return lastAt === null || now - lastAt >= HEARTBEAT_MIN_INTERVAL_MS;
}

/** Cost of an outbound message as the server rate limiter counts it. */
export function messageCost(msg) {
  if (msg.type === "heartbeat") return 0;
  if (msg.type === "event_batch") return Math.max(msg.events.length, 1);
  return 1;
}

/**
 * Split an event_batch into batches the server can accept: each at most
 * `maxPerBatch` events, order preserved. An empty batch is returned as is.
 */
export function splitEventBatch(msg, maxPerBatch) {
  if (msg.type !== "event_batch" || !Array.isArray(msg.events)) {
    throw new Error("splitEventBatch: expected an event_batch with an events array");
  }
  if (!Number.isSafeInteger(maxPerBatch) || maxPerBatch < 1 || maxPerBatch > SERVER_MAX_BATCH_SIZE) {
    throw new Error("splitEventBatch: maxPerBatch must be in 1.." + SERVER_MAX_BATCH_SIZE + ", got " + maxPerBatch);
  }
  if (msg.events.length <= maxPerBatch) return [msg];
  const batches = [];
  for (let i = 0; i < msg.events.length; i += maxPerBatch) {
    batches.push({ ...msg, events: msg.events.slice(i, i + maxPerBatch) });
  }
  return batches;
}

/**
 * Sliding-window send budget: at most `limit` cost units in any `windowMs`.
 * Time must be monotonic (performance.now()); a clock that moves backwards
 * is an invariant violation and throws.
 */
export class SendBudget {
  constructor(limit, windowMs) {
    if (!Number.isSafeInteger(limit) || limit < 1) throw new Error("SendBudget: limit must be >= 1");
    if (!(windowMs > 0)) throw new Error("SendBudget: windowMs must be > 0");
    this.limit = limit;
    this.windowMs = windowMs;
    this.entries = [];
    this.used = 0;
    this.lastNow = -Infinity;
  }

  prune(now) {
    if (now < this.lastNow) {
      throw new Error("SendBudget: clock moved backwards (" + now + " < " + this.lastNow + ")");
    }
    this.lastNow = now;
    while (this.entries.length > 0 && now - this.entries[0].at >= this.windowMs) {
      this.used -= this.entries.shift().cost;
    }
  }

  assertCost(cost) {
    if (!Number.isSafeInteger(cost) || cost < 1 || cost > this.limit) {
      throw new Error("SendBudget: cost must be in 1.." + this.limit + ", got " + cost);
    }
  }

  /** Take `cost` units at `now` if they fit. */
  tryTake(now, cost) {
    this.assertCost(cost);
    this.prune(now);
    if (this.used + cost > this.limit) return false;
    this.entries.push({ at: now, cost });
    this.used += cost;
    return true;
  }

  /** Milliseconds until `cost` units fit (0 when they fit now). */
  msUntilAvailable(now, cost) {
    this.assertCost(cost);
    this.prune(now);
    let used = this.used;
    for (let i = 0; used + cost > this.limit; i++) {
      used -= this.entries[i].cost;
      if (used + cost <= this.limit) return Math.max(this.entries[i].at + this.windowMs - now, 1);
    }
    return 0;
  }
}

/**
 * Outbound queue paced by a SendBudget. Nothing is dropped silently: push
 * returns false when the queue is full so the caller can log and resync.
 * Items are { msg, cost, priority }. Priority items (request_sync) go ahead
 * of every non-priority item, after earlier priority items.
 */
export class PacedQueue {
  constructor(budget, maxQueued) {
    if (!Number.isSafeInteger(maxQueued) || maxQueued < 1) throw new Error("PacedQueue: maxQueued must be >= 1");
    this.budget = budget;
    this.maxQueued = maxQueued;
    this.items = [];
  }

  get length() {
    return this.items.length;
  }

  /** Replace the budget, e.g. for a new connection with a fresh server window. */
  setBudget(budget) {
    for (const item of this.items) budget.assertCost(item.cost);
    this.budget = budget;
  }

  push(msg, cost, priority) {
    this.budget.assertCost(cost);
    if (this.items.length >= this.maxQueued) return false;
    const item = { msg, cost, priority: priority === true };
    if (item.priority) {
      let at = 0;
      while (at < this.items.length && this.items[at].priority) at++;
      this.items.splice(at, 0, item);
    } else {
      this.items.push(item);
    }
    return true;
  }

  /** Whether some queued message satisfies `pred(msg)`. */
  some(pred) {
    return this.items.some((item) => pred(item.msg));
  }

  /** The queued messages, oldest first (a copy). */
  messages() {
    return this.items.map((item) => item.msg);
  }

  /** Remove every item for which `pred(msg)` is true; returns how many. */
  removeWhere(pred) {
    const before = this.items.length;
    this.items = this.items.filter((item) => !pred(item.msg));
    return before - this.items.length;
  }

  /**
   * Send queued items in order while `canSend(msg)` holds and the budget
   * allows. `sendFn(msg)` returns true when the message was written; false
   * keeps it at the head. Returns { sent, waitMs } where waitMs > 0 means the
   * head is waiting for budget and the caller should pump again after it.
   */
  pump(now, canSend, sendFn) {
    let sent = 0;
    while (this.items.length > 0) {
      const head = this.items[0];
      if (!canSend(head.msg)) return { sent, waitMs: 0 };
      if (!this.budget.tryTake(now, head.cost)) {
        return { sent, waitMs: this.budget.msUntilAvailable(now, head.cost) };
      }
      if (!sendFn(head.msg)) {
        // The spent budget is not refunded: pacing stays conservative.
        return { sent, waitMs: 0 };
      }
      this.items.shift();
      sent++;
    }
    return { sent, waitMs: 0 };
  }
}
