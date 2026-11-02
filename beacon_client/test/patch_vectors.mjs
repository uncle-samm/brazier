// Patch round-trip checker: server diff -> client apply.
//
// Usage: node beacon_client/test/patch_vectors.mjs <vectors.json>
//
// The vectors file is produced by test/beacon/patch_test.gleam:
//   {
//     "roundtrip": [{ "old": <json>, "new": <json>, "ops": <server ops> }, ...],
//     "invalid":   [{ "name": <string>, "model": <json>, "ops": <ops> }, ...]
//   }
//
// For every round-trip vector this asserts that:
//   1. applying the SERVER ops on the client yields `new` exactly;
//   2. the client diff produces the same ops as the server diff;
//   3. applying the client diff yields `new`.
// For every invalid vector it asserts that applyOps throws a PatchError.
// Any failure exits non-zero so the calling Gleam test fails loudly.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { applyOps, diffModels, PatchError } from "../src/beacon_client/patch.mjs";

const file = process.argv[2];
if (!file) {
  console.error("usage: node patch_vectors.mjs <vectors.json>");
  process.exit(2);
}

const vectors = JSON.parse(readFileSync(file, "utf8"));
assert.ok(Array.isArray(vectors.roundtrip), "vectors.roundtrip must be an array");
assert.ok(Array.isArray(vectors.invalid), "vectors.invalid must be an array");

let failures = 0;

vectors.roundtrip.forEach((vector, index) => {
  try {
    const applied = applyOps(vector.old, vector.ops);
    assert.deepEqual(applied, vector.new, "server ops applied on client must equal new");
    const clientOps = diffModels(vector.old, vector.new);
    assert.deepEqual(clientOps, vector.ops, "client diff must match server diff");
    assert.deepEqual(applyOps(vector.old, clientOps), vector.new, "client ops must reproduce new");
  } catch (error) {
    failures++;
    console.error(`roundtrip vector ${index} failed: ${error.message}`);
    console.error(JSON.stringify(vector));
  }
});

vectors.invalid.forEach((vector) => {
  try {
    applyOps(vector.model, vector.ops);
    failures++;
    console.error(`invalid vector "${vector.name}" was applied instead of throwing`);
  } catch (error) {
    if (!(error instanceof PatchError)) {
      failures++;
      console.error(`invalid vector "${vector.name}" threw a non-PatchError: ${error}`);
    }
  }
});

if (failures > 0) {
  console.error(`${failures} patch vector failure(s)`);
  process.exit(1);
}
console.log(
  `patch vectors ok: ${vectors.roundtrip.length} roundtrip, ${vectors.invalid.length} invalid`,
);
