// Client verdicts on navigation paths, for the server/client parity test.
//
// Usage: node brazier_client/test/local_path_parity.mjs PATHS.json
//
// PATHS.json holds a JSON array of strings. For each path this prints the
// reason localPathRefusal (brazier_client/src/brazier_client/patch.mjs)
// refuses it for a page at http://localhost, or null when it accepts it, as
// one JSON array on a line starting "verdicts: ". test/brazier/router_test.gleam
// writes the paths and holds the verdicts equal to router.check_local_path's,
// so the server and the client refuse the same paths for the same reasons.

import { readFileSync } from "node:fs";
import { localPathRefusal } from "../src/brazier_client/patch.mjs";

const file = process.argv[2];
if (typeof file !== "string" || file === "") {
  throw new Error("local_path_parity: pass the path of a JSON array of paths");
}
const paths = JSON.parse(readFileSync(file, "utf8"));
if (!Array.isArray(paths) || !paths.every((path) => typeof path === "string")) {
  throw new Error("local_path_parity: " + file + " must hold a JSON array of strings");
}
if (paths.length === 0) {
  throw new Error("local_path_parity: " + file + " holds no paths; the parity test would prove nothing");
}

const verdicts = paths.map((path) => localPathRefusal(path, "http://localhost"));
console.log("verdicts: " + JSON.stringify(verdicts));
