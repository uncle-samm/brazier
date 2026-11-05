// Client patch apply equivalence: copy-on-write once per patch vs per op.
//
// Usage: node brazier_client/test/apply_equivalence.mjs
//
// PERF-8 replaced applyOps' per-op copies (a slice or spread of every
// container on the path, for every op) with one copy per container per
// patch, edited in place. This script runs seeded random patches through
// the new applyOps and through the per-op copying engine it replaced (kept
// verbatim below as referenceApplyOps) and asserts, for every patch:
//   1. both return deep-equal models, or both throw a PatchError with the
//      same message;
//   2. neither the input model nor the op values were mutated;
//   3. no op ever touched Object.prototype.
// Patches mix runs of ops on one array (the shapes a diff emits), scattered
// ops, root replaces and rare corrupt ops (out-of-bounds and leading-zero
// indices, missing members, scalar traversal, non-array appends, unsafe
// segments, unknown ops). Models hold own "__proto__" members the way
// JSON.parse makes them. Run by test/brazier/patch_test.gleam and
// `make test-client`; any failure exits non-zero.

import assert from "node:assert/strict";
import {
  applyOps,
  diffModels,
  escapePathSegment,
  parsePath,
  PatchError,
  UNSAFE_PATCH_KEYS,
} from "../src/brazier_client/patch.mjs";

const UNSAFE_KEYS = new Set(UNSAFE_PATCH_KEYS);

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// --- Seeded generator (mulberry32) ---

let state = 0;
function seed(n) {
  state = n >>> 0;
}
function random() {
  state = (state + 0x6d2b79f5) >>> 0;
  let t = state;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
function uniform(n) {
  return 1 + Math.floor(random() * n);
}
function pick(list) {
  return list[uniform(list.length) - 1];
}

const KEYS = ["a", "b", "count", "items", "a/b", "~", "~1", "x~0/y", "", "name", "0", "-", "ünï"];
const ALL_KEYS = KEYS.concat(UNSAFE_PATCH_KEYS);

// An own data property, even for "__proto__" (plain assignment would call
// the inherited setter), exactly as JSON.parse makes it.
function put(object, key, value) {
  Object.defineProperty(object, key, { value, enumerable: true, writable: true, configurable: true });
}

function genScalar() {
  switch (uniform(6)) {
    case 1: return uniform(100) - 50;
    case 2: return uniform(100) - 50 + 0.5;
    case 3: return pick(["", "x", "hello", "a/b~c"]);
    case 4: return true;
    case 5: return false;
    default: return null;
  }
}
function genValue(depth) {
  if (depth === 0) return genScalar();
  switch (uniform(4)) {
    case 1: return genObject(depth - 1);
    case 2: return genArray(depth - 1, 5);
    default: return genScalar();
  }
}
function genObject(depth) {
  const object = {};
  for (let i = uniform(4) - 1; i > 0; i--) put(object, pick(ALL_KEYS), genValue(depth));
  return object;
}
function genArray(depth, max) {
  const array = [];
  for (let i = uniform(max) - 1; i > 0; i--) array.push(genValue(depth));
  return array;
}
function genModel() {
  switch (uniform(3)) {
    case 1: {
      const model = {};
      put(model, "items", genArray(1, 60));
      put(model, "rest", genObject(2));
      return model;
    }
    case 2: return genArray(2, 40);
    default: return genObject(3);
  }
}

function children(value) {
  if (Array.isArray(value)) return value.map((child, i) => [String(i), child]);
  if (isObject(value)) return Object.keys(value).filter((k) => !UNSAFE_KEYS.has(k)).map((k) => [k, value[k]]);
  return [];
}
function isContainer(value) {
  return typeof value === "object" && value !== null;
}
function pointer(tokens) {
  return tokens.map((t) => "/" + escapePathSegment(t)).join("");
}
function pickContainer(value, tokens) {
  const containers = children(value).filter(([, child]) => isContainer(child));
  if (containers.length === 0 || uniform(3) === 1) return [tokens, value];
  const [token, child] = pick(containers);
  return pickContainer(child, tokens.concat([token]));
}

function memberOps(tokens, container) {
  const at = (token) => pointer(tokens.concat([token]));
  if (Array.isArray(container)) {
    const len = container.length;
    const choice = uniform(6);
    if (choice === 1 && len > 0) {
      const first = uniform(len) - 1;
      const last = Math.min(len - 1, first + uniform(8) - 1);
      const ops = [];
      for (let i = first; i <= last; i++) ops.push({ op: "replace", path: at(String(i)), value: genValue(1) });
      return ops;
    }
    if (choice === 2 && len > 0) {
      const count = uniform(Math.min(len, 8));
      const ops = [];
      for (let i = len - 1; i >= len - count; i--) ops.push({ op: "remove", path: at(String(i)) });
      return ops;
    }
    if (choice === 3) {
      const first = uniform(len + 1) - 1;
      const count = uniform(5);
      const ops = [];
      for (let i = first; i < first + count; i++) ops.push({ op: "add", path: at(String(i)), value: genValue(1) });
      return ops;
    }
    if (choice === 4) return [{ op: "add", path: at("-"), value: genValue(1) }];
    if (choice === 5) return [{ op: "append", path: pointer(tokens), value: [genValue(1), genValue(1)] }];
    if (len > 0) {
      const ops = [];
      for (let i = 0; i < 4; i++) ops.push({ op: "replace", path: at(String(uniform(len) - 1)), value: genValue(1) });
      return ops;
    }
    return [{ op: "add", path: at("0"), value: genValue(1) }];
  }
  const existing = children(container).map(([key]) => key);
  const choice = uniform(4);
  if (existing.length > 0 && choice === 1) return [{ op: "replace", path: at(pick(existing)), value: genValue(1) }];
  if (existing.length > 0 && choice === 2) return [{ op: "remove", path: at(pick(existing)) }];
  if (existing.length > 0 && choice === 3) {
    const key = pick(existing);
    if (Array.isArray(container[key])) return [{ op: "append", path: at(key), value: [genValue(1)] }];
    return [{ op: "replace", path: at(key), value: genValue(2) }];
  }
  return [{ op: "add", path: at(pick(KEYS)), value: genValue(2) }];
}

function corruptOp(tokens, container) {
  const len = Array.isArray(container) ? container.length : 0;
  const at = (...rest) => pointer(tokens.concat(rest));
  switch (uniform(8)) {
    case 1: return { op: "replace", path: at(String(len + uniform(3) - 1)), value: 1 };
    case 2: return { op: "add", path: at(String(len + 1 + uniform(2))), value: 1 };
    case 3: return { op: "remove", path: at("01") };
    case 4: return { op: "replace", path: at("no such member", "x"), value: 1 };
    case 5: return { op: "append", path: at("no such member"), value: [1] };
    case 6: return { op: "add", path: at(pick(UNSAFE_PATCH_KEYS), "polluted"), value: true };
    case 7: return { op: "remove", path: "" };
    default: return { op: "move", from: "", path: at("x") };
  }
}

function genGroup(model) {
  const [tokens, container] = pickContainer(model, []);
  switch (uniform(60)) {
    case 1: return [corruptOp(tokens, container)];
    case 2: return [{ op: "replace", path: "", value: genObject(2) }];
    default: return memberOps(tokens, container);
  }
}

// Evolve the model through the reference engine so later ops address what
// earlier ones produced; a refused group leaves it as it was.
function genOps(model, groups) {
  const ops = [];
  for (let i = 0; i < groups; i++) {
    const group = genGroup(model);
    try {
      model = referenceApplyOps(model, group);
    } catch (error) {
      if (!(error instanceof PatchError)) throw error;
    }
    for (const op of group) ops.push(op);
  }
  return ops;
}

function outcome(apply, model, ops) {
  try {
    return { ok: true, value: apply(model, ops) };
  } catch (error) {
    if (!(error instanceof PatchError)) throw error;
    return { ok: false, message: error.message };
  }
}

// structuredClone keeps own "__proto__" members as own data properties.
let applied = 0;
let refused = 0;
// Refusal messages with their details blanked: each corrupt-op kind must
// actually be refused, or the comparison misses an error path.
const refusals = new Set();
for (let n = 1; n <= 3000; n++) {
  seed(n);
  const model = genModel();
  const ops = genOps(model, uniform(24));
  const modelBefore = structuredClone(model);
  const opsBefore = structuredClone(ops);
  const expected = outcome(referenceApplyOps, model, ops);
  const actual = outcome(applyOps, model, ops);
  assert.deepEqual(actual, expected, `seed ${n}: engines disagree`);
  assert.deepEqual(model, modelBefore, `seed ${n}: applyOps mutated its input model`);
  assert.deepEqual(ops, opsBefore, `seed ${n}: applyOps mutated the op values`);
  assert.equal({}.polluted, undefined, `seed ${n}: Object.prototype polluted`);
  if (actual.ok) applied++;
  else {
    refused++;
    refusals.add(actual.message.replace(/".*"|[0-9]+/g, "_"));
  }
}
assert.ok(applied > 1500, `most random patches must apply (applied ${applied})`);
assert.ok(refused > 150, `some random patches must be refused (refused ${refused})`);

assert.ok(refusals.size >= 8, `every refusal kind must be hit: ${[...refusals].join("; ")}`);

// === Shifted windows: diffModels detects the shift ===
//
// A sliding window (drop k from the front, append m) and its mirror (insert
// k at the front, drop m from the back) of several lengths, shift amounts
// (0, 1, 2, half, all, more than all) and element kinds (distinct, mod 3,
// a two-value alternation, objects), at the root and between pinned
// elements. For every one, both apply engines must turn the diff into the
// new model. Where the shift is plainly the cheapest edit (distinct
// elements, 2k < n) the diff must be exactly the shift's ops; where nothing
// overlaps (k >= n) there must be no shift. patch_vectors.mjs checks every
// window against the server diff, op for op.

const KINDS = {
  distinct: (i) => i,
  mod3: (i) => ((i % 3) + 3) % 3,
  alternate: (i) => ((i & 1) === 0 ? "a" : "b"),
  object: (i) => ({ id: i, label: "event" }),
};

function values(kind, from, to) {
  const out = [];
  for (let i = from; i <= to; i++) out.push(KINDS[kind](i));
  return out;
}

const CONTEXTS = {
  root: { wrap: (w) => w, path: "", offset: 0, suffix: false },
  pinned: { wrap: (w) => ({ items: ["head", ...w, "foot"], n: 1 }), path: "/items", offset: 1, suffix: true },
  footer: { wrap: (w) => ({ items: [...w, "foot"] }), path: "/items", offset: 0, suffix: true },
};

// The ops of a front shift by k (removes highest first, then the inserts),
// or of a back shift inserting `inserted` and dropping d.
function frontShiftOps(ctx, n, k, appended) {
  const ops = [];
  for (let i = ctx.offset + k - 1; i >= ctx.offset; i--) ops.push({ op: "remove", path: `${ctx.path}/${i}` });
  if (!ctx.suffix) return [...ops, { op: "append", path: ctx.path, value: appended }];
  appended.forEach((value, i) => ops.push({ op: "add", path: `${ctx.path}/${ctx.offset + n - k + i}`, value }));
  return ops;
}
function backShiftOps(ctx, n, d, inserted) {
  const ops = [];
  for (let i = ctx.offset + n - 1; i >= ctx.offset + n - d; i--) ops.push({ op: "remove", path: `${ctx.path}/${i}` });
  inserted.forEach((value, i) => ops.push({ op: "add", path: `${ctx.path}/${ctx.offset + i}`, value }));
  return ops;
}

let windows = 0;
let exactShifts = 0;
let noShifts = 0;
for (const n of [0, 1, 2, 3, 4, 5, 8, 13, 50, 200, 2000]) {
  const amounts = [...new Set([0, 1, 2, n >> 1, Math.max(n - 1, 0), n, n + 1])];
  for (const k of amounts) {
    for (const m of [...new Set([0, 1, 2, k])]) {
      for (const kind of Object.keys(KINDS)) {
        for (const [name, ctx] of Object.entries(CONTEXTS)) {
          const old = values(kind, 0, n - 1);
          const front = values(kind, k, n - 1 + m);
          // 0 - k, not -k: -k is -0 when k is 0, which JSON has no form for.
          const back = values(kind, 0 - k, n - 1 - m);
          for (const [direction, next] of [["front", front], ["back", back]]) {
            const label = `${direction} n=${n} k=${k} m=${m} ${kind} ${name}`;
            const oldModel = ctx.wrap(old);
            const newModel = ctx.wrap(next);
            const ops = diffModels(oldModel, newModel);
            assert.deepEqual(applyOps(oldModel, ops), newModel, `${label}: applyOps`);
            assert.deepEqual(referenceApplyOps(oldModel, ops), newModel, `${label}: reference`);
            windows++;
            if (kind !== "distinct") continue;
            if (k >= 1 && m >= 1 && 2 * k < n) {
              // Cheaper than pairing (at least n - k ops) and than the
              // size guard (n - k + m elements).
              const expected =
                direction === "front"
                  ? frontShiftOps(ctx, n, k, next.slice(n - k))
                  : backShiftOps(ctx, n, m, next.slice(0, k));
              if (direction === "front" || 2 * m < n) {
                assert.deepEqual(ops, expected, `${label}: shift ops`);
                exactShifts++;
              }
            } else if (direction === "front" && k >= n && n > 0) {
              // Disjoint windows pair by index: surplus removes or surplus
              // inserts, never both as a shift has.
              const removes = ops.some((op) => op.op === "remove");
              const inserts = ops.some((op) => op.op === "add" || op.op === "append");
              assert.ok(!(removes && inserts), `${label}: no shift: ${JSON.stringify(ops)}`);
              noShifts++;
            }
          }
        }
      }
    }
  }
}
assert.ok(exactShifts >= 150, `the exact shift shapes must be checked (checked ${exactShifts})`);
assert.ok(noShifts > 50, `the disjoint windows must be checked (checked ${noShifts})`);

console.log(
  `apply equivalence ok: ${applied} applied, ${refused} refused; ` +
    `${windows} shifted windows (${exactShifts} exact shifts, ${noShifts} disjoint)`,
);

// === Reference: the per-op copying engine before PERF-8, verbatim ===

function referenceApplyOps(model, ops) {
  if (!Array.isArray(ops)) {
    throw new PatchError("Patch ops must be an array");
  }
  let result = model;
  for (let i = 0; i < ops.length; i++) {
    result = applyOp(result, ops[i]);
  }
  return result;
}

function applyOp(model, op) {
  if (!isObject(op) || typeof op.op !== "string") {
    throw new PatchError(`Malformed patch op: ${JSON.stringify(op)}`);
  }
  const tokens = parsePath(op.path);
  assertSafeSegments(tokens);
  switch (op.op) {
    case "replace":
      requireValue(op);
      return updateAt(model, tokens, (parent, token) => replaceIn(parent, token, op.value), op.value);
    case "add":
      requireValue(op);
      return updateAt(model, tokens, (parent, token) => addIn(parent, token, op.value), op.value);
    case "remove":
      if (tokens.length === 0) throw new PatchError("Cannot remove the document root");
      return updateAt(model, tokens, removeIn, undefined);
    case "append":
      if (!Array.isArray(op.value)) {
        throw new PatchError(`append value must be an array at ${JSON.stringify(op.path)}`);
      }
      if (tokens.length === 0) return appendTo(model, op.value, op.path);
      return updateAt(
        model,
        tokens,
        (parent, token) => replaceIn(parent, token, appendTo(getIn(parent, token), op.value, op.path)),
        undefined,
      );
    default:
      throw new PatchError(`Unknown patch op: ${JSON.stringify(op.op)}`);
  }
}

function requireValue(op) {
  if (!Object.prototype.hasOwnProperty.call(op, "value")) {
    throw new PatchError(`Patch op ${op.op} at ${JSON.stringify(op.path)} has no value`);
  }
}

// Copy-on-write walk to the parent of the last token.
function updateAt(node, tokens, fn, rootValue) {
  if (tokens.length === 0) return rootValue;
  if (tokens.length === 1) return fn(node, tokens[0]);
  const [token, ...rest] = tokens;
  const child = getIn(node, token);
  return replaceIn(node, token, updateAt(child, rest, fn, rootValue));
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

function replaceIn(node, token, value) {
  if (Array.isArray(node)) {
    const index = existingIndex(node, token);
    const copy = node.slice();
    copy[index] = value;
    return copy;
  }
  if (isObject(node)) {
    if (!Object.prototype.hasOwnProperty.call(node, token)) {
      throw new PatchError(`Missing member ${JSON.stringify(token)}`);
    }
    return { ...node, [token]: value };
  }
  throw new PatchError(`Cannot replace ${JSON.stringify(token)} in a non-container`);
}

function addIn(node, token, value) {
  if (Array.isArray(node)) {
    if (token === "-") return node.concat([value]);
    const index = parseIndex(token);
    if (index > node.length) {
      throw new PatchError(`Array index ${token} out of bounds (length ${node.length})`);
    }
    const copy = node.slice();
    copy.splice(index, 0, value);
    return copy;
  }
  if (isObject(node)) {
    return { ...node, [token]: value };
  }
  throw new PatchError(`Cannot add ${JSON.stringify(token)} to a non-container`);
}

function removeIn(node, token) {
  if (Array.isArray(node)) {
    const index = existingIndex(node, token);
    const copy = node.slice();
    copy.splice(index, 1);
    return copy;
  }
  if (isObject(node)) {
    if (!Object.prototype.hasOwnProperty.call(node, token)) {
      throw new PatchError(`Missing member ${JSON.stringify(token)}`);
    }
    const copy = { ...node };
    delete copy[token];
    return copy;
  }
  throw new PatchError(`Cannot remove ${JSON.stringify(token)} from a non-container`);
}

function appendTo(node, items, path) {
  if (!Array.isArray(node)) {
    throw new PatchError(`append target ${JSON.stringify(path)} is not an array`);
  }
  return node.concat(items);
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
