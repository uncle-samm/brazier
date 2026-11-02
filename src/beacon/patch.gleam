/// JSON Patch Operations for Beacon State Sync.
///
/// Automatically diffs two model JSON strings and produces minimal patch
/// operations. The developer never interacts with this module directly —
/// the runtime calls it behind the scenes to minimize wire traffic.
///
/// Operations (all internal):
/// - replace: a field changed value
/// - append: items were added to the end of an array
/// - remove: a field was deleted
///
/// Reference: RFC 6902 (JSON Patch), adapted for Beacon's state-over-the-wire.
import beacon/log

/// Diff two JSON model strings and produce patch operations.
/// Returns a JSON-encoded string of the ops array (e.g., `[{"op":"replace","path":"/count","value":1}]`).
/// If the models are identical, returns `"[]"`.
pub fn diff(old_json: String, new_json: String) -> String {
  log.debug("beacon.patch", "Diffing model JSON")
  diff_json(old_json, new_json)
}

/// Apply patch operations to a model JSON string.
/// Returns the patched model JSON string, or an error if application fails.
pub fn apply_ops(
  model_json: String,
  ops_json: String,
) -> Result(String, String) {
  log.debug("beacon.patch", "Applying patch ops to model")
  apply_json_ops(model_json, ops_json)
}

/// Check if an ops JSON string represents no changes (empty array).
pub fn is_empty(ops_json: String) -> Bool {
  is_empty_ops(ops_json)
}

/// Erlang FFI: diff two JSON strings, produce ops JSON.
@external(erlang, "beacon_patch_ffi", "diff_json")
fn diff_json(old_json: String, new_json: String) -> String

/// Erlang FFI: apply ops JSON to model JSON.
@external(erlang, "beacon_patch_ffi", "apply_json_ops")
fn apply_json_ops(
  model_json: String,
  ops_json: String,
) -> Result(String, String)

/// Count the number of operations in a JSON ops string.
/// Used for enforcing depth/size limits on client-sent patches.
pub fn count_ops(ops_json: String) -> Result(Int, String) {
  count_ops_ffi(ops_json)
}

/// Erlang FFI: check if ops are empty.
@external(erlang, "beacon_patch_ffi", "is_empty_ops")
fn is_empty_ops(ops_json: String) -> Bool

/// Erlang FFI: count ops in a JSON array string.
@external(erlang, "beacon_patch_ffi", "count_ops")
fn count_ops_ffi(ops_json: String) -> Result(Int, String)
