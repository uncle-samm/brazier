// Client patch safety: prototype pollution and JSON Pointer escaping.
//
// Usage: node brazier_client/test/patch_safety.mjs
//
// Asserts that:
//   1. applyOps refuses `__proto__`, `constructor` and `prototype` path
//      segments with a PatchError, and Object.prototype is left untouched;
//   2. diffModels escapes "/" in keys as "~1" and applyOps round-trips it;
//   3. diffModels never emits a path through an unsafe key: when one is
//      added, removed or changed, the object holding it (the nearest safe
//      parent) is replaced whole, and applying that replace pollutes
//      nothing; an unchanged unsafe key forces no replace.
// It prints UNSAFE_PATCH_KEYS, which test/brazier/patch_test.gleam holds
// equal to the server's canonical unsafe_keys/0. Run by that test and by
// `make test-client`; any failure exits non-zero.

import assert from "node:assert/strict";
import { applyOps, diffModels, PatchError, UNSAFE_PATCH_KEYS } from "../src/brazier_client/patch.mjs";

const pollutedBefore = Object.prototype.polluted;
assert.equal(pollutedBefore, undefined, "Object.prototype.polluted must start unset");

function assertUnsafe(model, path) {
  assert.throws(
    () => applyOps(model, [{ op: "replace", path, value: true }]),
    (error) =>
      error instanceof PatchError && /Unsafe patch path segment/.test(error.message),
    `${path} must be refused as an unsafe segment`,
  );
  assert.equal(Object.prototype.polluted, undefined, `${path} polluted Object.prototype`);
  assert.equal({}.polluted, undefined, `${path} polluted new objects`);
}

let checks = 0;

assertUnsafe({}, "/__proto__/polluted");
checks++;
assertUnsafe({ constructor: { prototype: {} } }, "/constructor/prototype/polluted");
checks++;
assertUnsafe({ a: {} }, "/a/prototype");
checks++;

const slashKeyPatch = diffModels({ "a/b": 1 }, { "a/b": 2 });
assert.deepEqual(slashKeyPatch, [{ op: "replace", path: "/a~1b", value: 2 }]);
assert.deepEqual(applyOps({ "a/b": 1 }, slashKeyPatch), { "a/b": 2 });
checks++;

const unsafeModel = JSON.parse('{"__proto__":{"polluted":true}}');
const unsafeKeyPatch = diffModels({}, unsafeModel);
assert.deepEqual(unsafeKeyPatch, [
  { op: "replace", path: "", value: JSON.parse('{"__proto__":{"polluted":true}}') },
]);
assert.deepEqual(applyOps({}, unsafeKeyPatch), unsafeModel);
assert.equal(Object.prototype.polluted, undefined, "root replace polluted Object.prototype");
checks++;

// A changed unsafe key deep inside: the object holding it is replaced, and
// nothing above it.
const nestedOld = JSON.parse('{"a":{"b":{"constructor":{"prototype":1},"k":1}},"z":1}');
const nestedNew = JSON.parse('{"a":{"b":{"constructor":{"prototype":2},"k":1}},"z":1}');
const nestedPatch = diffModels(nestedOld, nestedNew);
assert.deepEqual(nestedPatch, [{ op: "replace", path: "/a/b", value: nestedNew.a.b }]);
const nestedApplied = applyOps(nestedOld, nestedPatch);
assert.deepEqual(nestedApplied, nestedNew);
assert.equal(Object.getPrototypeOf(nestedApplied.a.b), Object.prototype, "replace changed a prototype");
checks++;

// A removed unsafe key inside an array element replaces that element.
const removedPatch = diffModels(
  JSON.parse('{"list":[{"__proto__":{"polluted":true},"k":1}]}'),
  JSON.parse('{"list":[{"k":1}]}'),
);
assert.deepEqual(removedPatch, [{ op: "replace", path: "/list/0", value: { k: 1 } }]);
checks++;

// An unchanged unsafe key forces nothing: the changed sibling gets its own op.
const siblingPatch = diffModels(
  JSON.parse('{"constructor":{"x":1},"b":1}'),
  JSON.parse('{"constructor":{"x":1},"b":2}'),
);
assert.deepEqual(siblingPatch, [{ op: "replace", path: "/b", value: 2 }]);
checks++;

// The exported list is frozen: nothing at runtime can shrink it.
assert.ok(Object.isFrozen(UNSAFE_PATCH_KEYS), "UNSAFE_PATCH_KEYS must be frozen");
assert.throws(() => UNSAFE_PATCH_KEYS.pop(), TypeError);
checks++;

assert.equal(Object.prototype.polluted, undefined, "Object.prototype polluted");
console.log(`unsafe keys: ${JSON.stringify(UNSAFE_PATCH_KEYS)}`);
console.log(`patch safety ok: ${checks} checks`);
