//// The shared stream vectors run through the browser's applier.
////
//// `stream_vectors_test` checks `test/fixtures/stream_vectors.json` against
//// the server's window and the reference applier. This module runs the same
//// file through the client's applier, `brazier_client/test/stream_vectors.mjs`
//// under node, so `gleam test` fails when the two sides disagree, not only
//// `make test-client`. The script exits non-zero on any failed check; its
//// summary line must count every vector in the file, so a script that stops
//// early or skips a list fails here too.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import simplifile

const vectors_path = "test/fixtures/stream_vectors.json"

const script = "brazier_client/test/stream_vectors.mjs"

@external(erlang, "brazier_patch_test_ffi", "run_node")
fn run_node(script: String, arg: String) -> Result(String, String)

/// The number of delta and fault vectors in the shared file.
fn vector_counts() -> #(Int, Int) {
  let assert Ok(text) = simplifile.read(vectors_path)
  let decoder = {
    use deltas <- decode.field("deltas", decode.list(decode.dynamic))
    use faults <- decode.field("faults", decode.list(decode.dynamic))
    decode.success(#(list.length(deltas), list.length(faults)))
  }
  let assert Ok(counts) = json.parse(text, decoder)
  counts
}

pub fn the_client_applier_passes_every_stream_vector_test() {
  let #(deltas, faults) = vector_counts()
  // The file must hold vectors of both kinds, or the run below proves little.
  let assert True = deltas > 0 && faults > 0
    as "test/fixtures/stream_vectors.json holds no delta or no fault vectors"
  let assert Ok(output) = run_node(script, "")
    as "the client stream vectors failed; run node brazier_client/test/stream_vectors.mjs"
  let summary =
    ", "
    <> int.to_string(deltas)
    <> " deltas, "
    <> int.to_string(faults)
    <> " faults"
  let assert True = string.contains(output, "stream vectors ok: ")
    as "the client stream vectors printed no summary line"
  let assert True = string.contains(output, summary)
    as {
      "the client stream vectors did not run every vector in the file: expected `"
      <> summary
      <> "` in: "
      <> output
    }
}

pub fn a_missing_script_is_an_error_test() {
  let assert Error(output) =
    run_node("brazier_client/test/no_such_vectors.mjs", "")
  let assert True = string.contains(output, "no_such_vectors.mjs")
}
