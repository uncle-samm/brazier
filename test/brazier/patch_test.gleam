/// Tests for the JSON Patch operations module.
/// Verifies diffing, applying, and round-trip correctness.
import brazier/log
import brazier/patch
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

pub fn diff_identical_models_test() {
  log.configure()
  let json = "{\"count\":0}"
  let ops = patch.diff(json, json)
  patch.is_empty(ops) |> should.be_true
}

pub fn diff_single_field_change_test() {
  log.configure()
  let old = "{\"count\":0}"
  let new = "{\"count\":1}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  // Ops should contain a replace for /count
  ops |> string.contains("replace") |> should.be_true
  ops |> string.contains("/count") |> should.be_true
}

pub fn diff_multiple_field_changes_test() {
  log.configure()
  let old = "{\"count\":0,\"name\":\"alice\"}"
  let new = "{\"count\":5,\"name\":\"bob\"}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  ops |> string.contains("replace") |> should.be_true
  ops |> string.contains("/count") |> should.be_true
  ops |> string.contains("/name") |> should.be_true
}

pub fn diff_array_append_test() {
  log.configure()
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[1,2,3,4,5]}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  // Should detect append (not full replace)
  ops |> string.contains("append") |> should.be_true
  ops |> string.contains("/items") |> should.be_true
}

pub fn diff_array_replace_test() {
  log.configure()
  // When elements change (not just appended), should be a replace
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[4,5,6]}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  ops |> string.contains("replace") |> should.be_true
}

pub fn diff_field_added_test() {
  log.configure()
  let old = "{\"count\":0}"
  let new = "{\"count\":0,\"name\":\"new\"}"
  let ops = patch.diff(old, new)
  // RFC 6902: a new object member is an "add", not a "replace".
  ops
  |> should.equal("[{\"op\":\"add\",\"path\":\"/name\",\"value\":\"new\"}]")
}

pub fn diff_field_removed_test() {
  log.configure()
  let old = "{\"count\":0,\"name\":\"old\"}"
  let new = "{\"count\":0}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  ops |> string.contains("remove") |> should.be_true
  ops |> string.contains("/name") |> should.be_true
}

pub fn count_ops_rejects_malformed_json_test() {
  log.configure()
  let assert Error(reason) = patch.count_ops("not json")
  reason |> string.contains("Patch op count failed") |> should.be_true
}

pub fn count_ops_requires_json_array_test() {
  log.configure()
  let assert Error(reason) = patch.count_ops("{\"op\":\"replace\"}")
  reason |> string.contains("must decode to an array") |> should.be_true
}

pub fn count_ops_counts_array_items_test() {
  log.configure()
  let assert Ok(2) =
    patch.count_ops(
      "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":1},{\"op\":\"remove\",\"path\":\"/name\"}]",
    )
}

pub fn apply_replace_op_test() {
  log.configure()
  let model = "{\"count\":0}"
  let ops = "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":5}]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  result |> should.equal("{\"count\":5}")
}

pub fn apply_append_op_test() {
  log.configure()
  let model = "{\"items\":[1,2]}"
  let ops = "[{\"op\":\"append\",\"path\":\"/items\",\"value\":[3,4]}]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  // Verify all original and appended elements are present
  result |> string.contains("[1,2,3,4]") |> should.be_true
}

pub fn apply_remove_op_test() {
  log.configure()
  let model = "{\"count\":0,\"name\":\"test\"}"
  let ops = "[{\"op\":\"remove\",\"path\":\"/name\"}]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  result |> string.contains("count") |> should.be_true
  result |> string.contains("name") |> should.be_false
}

pub fn apply_empty_ops_test() {
  log.configure()
  let model = "{\"count\":0}"
  let ops = "[]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  result |> should.equal(model)
}

pub fn roundtrip_diff_apply_test() {
  log.configure()
  // Diff two models, apply the diff to the old model, should get the new model
  let old = "{\"count\":0,\"name\":\"alice\"}"
  let new = "{\"count\":5,\"name\":\"alice\"}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  // Verify exact key:value pairs, not just bare values
  result |> string.contains("\"count\":5") |> should.be_true
  result |> string.contains("\"name\":\"alice\"") |> should.be_true
}

pub fn roundtrip_append_test() {
  log.configure()
  let old = "{\"strokes\":[{\"x\":0}]}"
  let new = "{\"strokes\":[{\"x\":0},{\"x\":1},{\"x\":2}]}"
  let ops = patch.diff(old, new)
  // Should be an append
  ops |> string.contains("append") |> should.be_true
  let assert Ok(result) = patch.apply_ops(old, ops)
  // Result should contain all three strokes
  result |> string.contains("\"x\":0") |> should.be_true
  result |> string.contains("\"x\":1") |> should.be_true
  result |> string.contains("\"x\":2") |> should.be_true
}

pub fn is_empty_true_test() {
  log.configure()
  patch.is_empty("[]") |> should.be_true
}

pub fn is_empty_false_test() {
  log.configure()
  patch.is_empty("[{\"op\":\"replace\",\"path\":\"/count\",\"value\":1}]")
  |> should.be_false
}

pub fn diff_no_change_single_field_test() {
  log.configure()
  let old = "{\"count\":5}"
  let new = "{\"count\":5}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_true
}

pub fn diff_nested_object_test() {
  log.configure()
  let old = "{\"player\":{\"x\":0,\"y\":0}}"
  let new = "{\"player\":{\"x\":10,\"y\":0}}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  ops |> string.contains("/player/x") |> should.be_true
}

pub fn multiple_ops_apply_test() {
  log.configure()
  let model = "{\"count\":0,\"name\":\"old\"}"
  let ops =
    "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":10},{\"op\":\"replace\",\"path\":\"/name\",\"value\":\"new\"}]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  result |> string.contains("\"count\":10") |> should.be_true
  result |> string.contains("\"name\":\"new\"") |> should.be_true
}

// === Part 1: Optimization proof tests ===

pub fn append_not_replace_for_array_growth_test() {
  log.configure()
  // Appending to an array MUST produce "append" not "replace"
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[1,2,3,4,5]}"
  let ops = patch.diff(old, new)
  ops |> string.contains("\"op\":\"append\"") |> should.be_true
  ops |> string.contains("\"/items\"") |> should.be_true
  ops |> string.contains("replace") |> should.be_false
}

pub fn replace_for_modified_array_element_test() {
  log.configure()
  // Modifying an element (not just appending) MUST produce "replace"
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[1,99,3]}"
  let ops = patch.diff(old, new)
  ops |> string.contains("replace") |> should.be_true
  ops |> string.contains("append") |> should.be_false
}

pub fn patch_size_smaller_than_model_test() {
  log.configure()
  // A single field change on a large model should produce a tiny patch
  let old =
    "{\"count\":50,\"name\":\"alice\",\"items\":[1,2,3,4,5,6,7,8,9,10],\"active\":true,\"score\":999}"
  let new =
    "{\"count\":51,\"name\":\"alice\",\"items\":[1,2,3,4,5,6,7,8,9,10],\"active\":true,\"score\":999}"
  let ops = patch.diff(old, new)
  // Patch should be much smaller than the full model
  let ops_size = string.length(ops)
  let model_size = string.length(new)
  let assert True = ops_size < model_size
}

pub fn roundtrip_nested_objects_test() {
  log.configure()
  let old = "{\"player\":{\"pos\":{\"x\":0,\"y\":0},\"hp\":100},\"enemies\":[]}"
  let new =
    "{\"player\":{\"pos\":{\"x\":10,\"y\":5},\"hp\":95},\"enemies\":[{\"id\":1}]}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"x\":10") |> should.be_true
  result |> string.contains("\"y\":5") |> should.be_true
  result |> string.contains("\"hp\":95") |> should.be_true
  result |> string.contains("\"id\":1") |> should.be_true
}

pub fn roundtrip_arrays_of_objects_test() {
  log.configure()
  let old =
    "{\"cards\":[{\"id\":1,\"title\":\"a\"},{\"id\":2,\"title\":\"b\"}]}"
  let new =
    "{\"cards\":[{\"id\":1,\"title\":\"a\"},{\"id\":2,\"title\":\"b\"},{\"id\":3,\"title\":\"c\"}]}"
  let ops = patch.diff(old, new)
  // Should be append
  ops |> string.contains("append") |> should.be_true
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"id\":3") |> should.be_true
  result |> string.contains("\"title\":\"c\"") |> should.be_true
}

pub fn roundtrip_mixed_types_test() {
  log.configure()
  let old =
    "{\"count\":0,\"name\":\"x\",\"active\":false,\"score\":1.5,\"tags\":[]}"
  let new =
    "{\"count\":7,\"name\":\"y\",\"active\":true,\"score\":3.14,\"tags\":[\"a\",\"b\"]}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"count\":7") |> should.be_true
  result |> string.contains("\"name\":\"y\"") |> should.be_true
  result |> string.contains("\"active\":true") |> should.be_true
  result |> string.contains("\"score\":3.14") |> should.be_true
  result |> string.contains("\"a\"") |> should.be_true
  result |> string.contains("\"b\"") |> should.be_true
}

pub fn roundtrip_empty_to_populated_test() {
  log.configure()
  let old = "{\"items\":[]}"
  let new = "{\"items\":[{\"x\":1},{\"x\":2},{\"x\":3}]}"
  let ops = patch.diff(old, new)
  ops |> string.contains("append") |> should.be_true
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"x\":1") |> should.be_true
  result |> string.contains("\"x\":3") |> should.be_true
}

pub fn roundtrip_populated_to_empty_test() {
  log.configure()
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[]}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("[]") |> should.be_true
}

pub fn roundtrip_deeply_nested_test() {
  log.configure()
  let old = "{\"a\":{\"b\":{\"c\":{\"d\":1}}}}"
  let new = "{\"a\":{\"b\":{\"c\":{\"d\":99}}}}"
  let ops = patch.diff(old, new)
  ops |> string.contains("/a/b/c/d") |> should.be_true
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"d\":99") |> should.be_true
}

pub fn roundtrip_string_with_special_chars_test() {
  log.configure()
  let old = "{\"msg\":\"hello\"}"
  let new = "{\"msg\":\"world with spaces & symbols!\"}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("world with spaces") |> should.be_true
}

pub fn diff_only_changed_field_test() {
  log.configure()
  // When only one of many fields changes, ops should reference ONLY that field
  let old = "{\"a\":1,\"b\":2,\"c\":3,\"d\":4,\"e\":5}"
  let new = "{\"a\":1,\"b\":2,\"c\":99,\"d\":4,\"e\":5}"
  let ops = patch.diff(old, new)
  ops |> string.contains("/c") |> should.be_true
  // Should NOT contain references to unchanged fields
  ops |> string.contains("/a") |> should.be_false
  ops |> string.contains("/b") |> should.be_false
  ops |> string.contains("/d") |> should.be_false
  ops |> string.contains("/e") |> should.be_false
  // Verify applying ops to old produces new
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"c\":99") |> should.be_true
  result |> string.contains("\"a\":1") |> should.be_true
}

// === RFC 6901 escaping, array diffs, strict apply ===

@external(erlang, "brazier_patch_test_ffi", "random_pair")
fn random_pair(seed: Int) -> #(String, String)

@external(erlang, "brazier_patch_test_ffi", "run_node")
fn run_node(script: String, arg: String) -> Result(String, String)

@external(erlang, "brazier_patch_test_ffi", "write_file")
fn write_file(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "brazier_patch_test_ffi", "scratch_path")
fn scratch_path(name: String) -> String

/// Invalid patches that BOTH the server mirror and the JS client must reject.
/// Shared with the node checker through the vectors file.
fn invalid_vectors() -> List(#(String, String, String)) {
  [
    #(
      "unknown op",
      "{\"a\":1}",
      "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/b\"}]",
    ),
    #(
      "replace missing member",
      "{\"a\":1}",
      "[{\"op\":\"replace\",\"path\":\"/b\",\"value\":1}]",
    ),
    #(
      "remove missing member",
      "{\"a\":1}",
      "[{\"op\":\"remove\",\"path\":\"/b\"}]",
    ),
    #(
      "pointer without slash",
      "{\"a\":1}",
      "[{\"op\":\"replace\",\"path\":\"a\",\"value\":2}]",
    ),
    #(
      "bad tilde escape",
      "{\"a~\":1}",
      "[{\"op\":\"replace\",\"path\":\"/a~2\",\"value\":2}]",
    ),
    #(
      "append to non-array",
      "{\"a\":1}",
      "[{\"op\":\"append\",\"path\":\"/a\",\"value\":[1]}]",
    ),
    #(
      "append non-array value",
      "{\"a\":[]}",
      "[{\"op\":\"append\",\"path\":\"/a\",\"value\":1}]",
    ),
    #(
      "index out of bounds",
      "{\"a\":[1]}",
      "[{\"op\":\"replace\",\"path\":\"/a/5\",\"value\":2}]",
    ),
    #(
      "leading zero index",
      "{\"a\":[1,2]}",
      "[{\"op\":\"replace\",\"path\":\"/a/01\",\"value\":2}]",
    ),
    #(
      "add past end",
      "{\"a\":[1]}",
      "[{\"op\":\"add\",\"path\":\"/a/3\",\"value\":2}]",
    ),
    #("remove root", "{\"a\":1}", "[{\"op\":\"remove\",\"path\":\"\"}]"),
    #("missing value", "{\"a\":1}", "[{\"op\":\"replace\",\"path\":\"/a\"}]"),
    #(
      "traverse scalar",
      "{\"a\":1}",
      "[{\"op\":\"replace\",\"path\":\"/a/b\",\"value\":2}]",
    ),
    #(
      "ops not array",
      "{\"a\":1}",
      "{\"op\":\"replace\",\"path\":\"/a\",\"value\":2}",
    ),
    #("op not object", "{\"a\":1}", "[1]"),
    #(
      "unsafe segment",
      "{\"a\":{}}",
      "[{\"op\":\"add\",\"path\":\"/a/__proto__\",\"value\":{\"polluted\":true}}]",
    ),
    #(
      "unsafe segment mid-path",
      "{\"constructor\":{\"prototype\":{}}}",
      "[{\"op\":\"replace\",\"path\":\"/constructor/prototype/x\",\"value\":1}]",
    ),
  ]
}

// === Unsafe keys (SEC-14) ===

pub fn diff_replaces_nearest_safe_parent_of_changed_unsafe_key_test() {
  log.configure()
  let old = "{\"a\":{\"constructor\":1,\"b\":1},\"z\":1}"
  let new = "{\"a\":{\"constructor\":2,\"b\":1},\"z\":1}"
  let ops = patch.diff(old, new)
  ops
  |> should.equal(
    "[{\"op\":\"replace\",\"path\":\"/a\",\"value\":{\"b\":1,\"constructor\":2}}]",
  )
  let assert Ok(result) = patch.apply_ops(old, ops)
  canonical(result) |> should.equal(canonical(new))
}

pub fn diff_replaces_root_when_root_unsafe_key_is_added_test() {
  log.configure()
  let ops = patch.diff("{}", "{\"__proto__\":{\"polluted\":true}}")
  ops
  |> should.equal(
    "[{\"op\":\"replace\",\"path\":\"\",\"value\":{\"__proto__\":{\"polluted\":true}}}]",
  )
}

pub fn diff_replaces_parent_when_unsafe_key_is_removed_test() {
  log.configure()
  let ops =
    patch.diff(
      "{\"list\":[{\"prototype\":1,\"k\":1}]}",
      "{\"list\":[{\"k\":1}]}",
    )
  ops
  |> should.equal(
    "[{\"op\":\"replace\",\"path\":\"/list/0\",\"value\":{\"k\":1}}]",
  )
}

pub fn diff_keeps_targeted_ops_when_unsafe_key_is_unchanged_test() {
  log.configure()
  // An unsafe key that did not change forces nothing: the sibling that did
  // change gets its own op, and no path passes through the unsafe key.
  let ops =
    patch.diff(
      "{\"constructor\":{\"x\":1},\"b\":1}",
      "{\"constructor\":{\"x\":1},\"b\":2}",
    )
  ops |> should.equal("[{\"op\":\"replace\",\"path\":\"/b\",\"value\":2}]")
}

pub fn apply_refuses_unsafe_segment_test() {
  log.configure()
  let assert Error(reason) =
    patch.apply_ops(
      "{\"a\":{}}",
      "[{\"op\":\"add\",\"path\":\"/a/prototype\",\"value\":1}]",
    )
  reason |> string.contains("unsafe_path_segment") |> should.be_true
}

// === Apply engine equivalence (PERF-8) ===

/// The zipper apply engine against the list-rebuilding engine it replaced
/// (kept as a reference in brazier_patch_test_ffi.erl): every seeded random
/// patch must give the same JSON or the same error reason on both.
pub fn apply_engine_matches_reference_on_random_patches_test() {
  log.configure()
  let #(applied, refused) =
    int.range(from: 1, to: 2001, with: #(0, 0), run: fn(counts, seed) {
      let #(applied, refused) = counts
      case compare_apply(seed) {
        Ok(True) -> #(applied + 1, refused)
        Ok(False) -> #(applied, refused + 1)
        Error(details) ->
          panic as { "seed " <> int.to_string(seed) <> ": " <> details }
      }
    })
  // Both outcomes must be exercised in quantity, or the comparison is weak.
  let assert True = applied > 1000 as "most random patches must apply"
  let assert True = refused > 100 as "some random patches must be refused"
}

@external(erlang, "brazier_patch_test_ffi", "compare_apply")
fn compare_apply(seed: Int) -> Result(Bool, String)

/// The client's copy-once applyOps against the per-op copying engine it
/// replaced, on seeded random patches, with the input and op values checked
/// unmutated (brazier_client/test/apply_equivalence.mjs).
pub fn client_apply_engine_matches_reference_test() {
  case run_node("brazier_client/test/apply_equivalence.mjs", "") {
    Ok(output) -> {
      let assert True = string.contains(output, "apply equivalence ok")
        as { "unexpected apply equivalence output: " <> output }
      Nil
    }
    Error(output) -> panic as { "client apply equivalence failed: " <> output }
  }
}

pub fn apply_rejects_every_invalid_vector_test() {
  log.configure()
  list.each(invalid_vectors(), fn(vector) {
    let #(name, model, ops) = vector
    case patch.apply_ops(model, ops) {
      Error(_) -> Nil
      Ok(result) ->
        panic as {
          "invalid patch vector was applied: " <> name <> " -> " <> result
        }
    }
  })
}

pub fn apply_unknown_op_fails_loudly_test() {
  log.configure()
  let assert Error(reason) =
    patch.apply_ops(
      "{\"a\":1}",
      "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/b\"}]",
    )
  reason |> string.contains("unknown_or_malformed_op") |> should.be_true
}

pub fn diff_escapes_tilde_and_slash_keys_test() {
  log.configure()
  let old = "{\"a/b\":1,\"m~n\":1,\"~1\":1}"
  let new = "{\"a/b\":2,\"m~n\":2,\"~1\":2}"
  let ops = patch.diff(old, new)
  ops |> string.contains("\"/a~1b\"") |> should.be_true
  ops |> string.contains("\"/m~0n\"") |> should.be_true
  ops |> string.contains("\"/~01\"") |> should.be_true
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> should.equal(new)
}

pub fn apply_unescapes_in_rfc_order_test() {
  log.configure()
  // "~01" must decode to the key "~1", never "/".
  let assert Ok(result) =
    patch.apply_ops(
      "{\"~1\":0,\"/\":0}",
      "[{\"op\":\"replace\",\"path\":\"/~01\",\"value\":1}]",
    )
  result |> should.equal("{\"/\":0,\"~1\":1}")
}

pub fn empty_key_pointer_is_not_root_test() {
  log.configure()
  // RFC 6901: "/" addresses the member with the empty-string key.
  let assert Ok(result) =
    patch.apply_ops(
      "{\"\":0,\"a\":1}",
      "[{\"op\":\"replace\",\"path\":\"/\",\"value\":5}]",
    )
  result |> should.equal("{\"\":5,\"a\":1}")
  let ops = patch.diff("{\"\":0}", "{\"\":1}")
  ops |> should.equal("[{\"op\":\"replace\",\"path\":\"/\",\"value\":1}]")
}

pub fn diff_array_middle_removal_test() {
  log.configure()
  let old = "{\"items\":[1,2,3,4]}"
  let new = "{\"items\":[1,3,4]}"
  let ops = patch.diff(old, new)
  ops |> should.equal("[{\"op\":\"remove\",\"path\":\"/items/1\"}]")
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> should.equal(new)
}

pub fn diff_array_removes_descending_test() {
  log.configure()
  let old = "{\"items\":[1,2,3,4,5,6]}"
  let new = "{\"items\":[1,2,6]}"
  let ops = patch.diff(old, new)
  ops
  |> should.equal(
    "[{\"op\":\"remove\",\"path\":\"/items/4\"},{\"op\":\"remove\",\"path\":\"/items/3\"},{\"op\":\"remove\",\"path\":\"/items/2\"}]",
  )
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> should.equal(new)
}

pub fn diff_array_prepend_inserts_test() {
  log.configure()
  let old = "{\"items\":[2,3]}"
  let new = "{\"items\":[1,2,3]}"
  let ops = patch.diff(old, new)
  ops
  |> should.equal("[{\"op\":\"add\",\"path\":\"/items/0\",\"value\":1}]")
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> should.equal(new)
}

pub fn diff_array_element_replace_test() {
  log.configure()
  let old = "{\"items\":[{\"id\":1,\"t\":\"a\"},{\"id\":2,\"t\":\"b\"}]}"
  let new = "{\"items\":[{\"id\":1,\"t\":\"a\"},{\"id\":2,\"t\":\"c\"}]}"
  let ops = patch.diff(old, new)
  ops
  |> should.equal(
    "[{\"op\":\"replace\",\"path\":\"/items/1/t\",\"value\":\"c\"}]",
  )
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> should.equal(new)
}

pub fn diff_array_truncation_to_empty_test() {
  log.configure()
  let old = "{\"items\":[1,2]}"
  let new = "{\"items\":[]}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> should.equal(new)
}

pub fn server_mirror_roundtrips_random_vectors_test() {
  log.configure()
  int.range(from: 1, to: 301, with: Nil, run: fn(_, seed) {
    let #(old, new) = random_pair(seed)
    let ops = patch.diff(old, new)
    case patch.apply_ops(old, ops) {
      Ok(result) ->
        case canonical(result) == canonical(new) {
          True -> Nil
          False ->
            panic as {
              "seed "
              <> int.to_string(seed)
              <> ": server apply mismatch\nold="
              <> old
              <> "\nnew="
              <> new
              <> "\nops="
              <> ops
              <> "\ngot="
              <> result
            }
        }
      Error(reason) ->
        panic as {
          "seed " <> int.to_string(seed) <> ": server apply failed " <> reason
        }
    }
  })
}

/// Re-encode through the patch engine (empty ops) so key order is canonical.
fn canonical(json: String) -> String {
  let assert Ok(encoded) = patch.apply_ops(json, "[]")
  encoded
}

pub fn client_applies_server_diffs_test() {
  log.configure()
  let roundtrip =
    int.range(from: 1, to: 301, with: [], run: fn(acc, seed) {
      let #(old, new) = random_pair(seed)
      let ops = patch.diff(old, new)
      [
        "{\"old\":" <> old <> ",\"new\":" <> new <> ",\"ops\":" <> ops <> "}",
        ..acc
      ]
    })
  let invalid =
    list.map(invalid_vectors(), fn(vector) {
      let #(name, model, ops) = vector
      "{\"name\":"
      <> json.to_string(json.string(name))
      <> ",\"model\":"
      <> model
      <> ",\"ops\":"
      <> ops
      <> "}"
    })
  let contents =
    "{\"roundtrip\":["
    <> string.join(roundtrip, ",")
    <> "],\"invalid\":["
    <> string.join(invalid, ",")
    <> "]}"
  let path = scratch_path("patch_vectors.json")
  let assert Ok(Nil) = write_file(path, contents)
  case run_node("brazier_client/test/patch_vectors.mjs", path) {
    Ok(output) ->
      output |> string.contains("patch vectors ok") |> should.be_true
    Error(output) -> panic as { "client patch vectors failed: " <> output }
  }
}

/// The client refuses prototype-polluting paths, escapes "/" in keys, and
/// replaces the nearest safe parent of a changed unsafe key
/// (brazier_client/test/patch_safety.mjs). Its unsafe-key list must equal
/// the server's canonical one.
pub fn client_patch_safety_test() {
  case run_node("brazier_client/test/patch_safety.mjs", "") {
    Ok(output) -> {
      let assert True = string.contains(output, "patch safety ok: 9 checks")
        as { "unexpected patch safety output: " <> output }
      let server_keys =
        json.to_string(json.array(patch.unsafe_keys(), json.string))
      let assert True =
        string.contains(output, "unsafe keys: " <> server_keys <> "\n")
        as {
          "client UNSAFE_PATCH_KEYS differ from the server's "
          <> server_keys
          <> ": "
          <> output
        }
      Nil
    }
    Error(output) -> panic as { "client patch safety failed: " <> output }
  }
}
