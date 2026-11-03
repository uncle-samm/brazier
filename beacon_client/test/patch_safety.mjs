// Client patch safety: prototype pollution and JSON Pointer escaping.
//
// Usage: node beacon_client/test/patch_safety.mjs
//
// Asserts that:
//   1. applyOps refuses `__proto__`, `constructor` and `prototype` path
//      segments with a PatchError, and Object.prototype is left untouched;
//   2. diffModels escapes "/" in keys as "~1" and applyOps round-trips it;
//   3. diffModels never emits a path through an unsafe key: a model holding
//      one is replaced whole at the root, without polluting Object.prototype.
// Run by test/beacon/patch_test.gleam; any failure exits non-zero.

import assert from "node:assert/strict";
import { applyOps, diffModels, PatchError } from "../src/beacon_client/patch.mjs";

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
assert.equal(Object.prototype.polluted, undefined, "root replace polluted Object.prototype");
checks++;

console.log(`patch safety ok: ${checks} checks`);
