/// JSON Patch Operations for Brazier State Sync.
///
/// Automatically diffs two model JSON strings and produces minimal patch
/// operations. The developer never interacts with this module directly —
/// the runtime calls it behind the scenes to minimize wire traffic.
///
/// Operations (RFC 6902 subset plus one Brazier extension):
/// - add: an object member was added, or an array element was inserted
///   (index or "-" for end of array)
/// - replace: an existing value changed (the target must exist)
/// - remove: an object member or array element was deleted (the target must
///   exist; array removals are emitted in descending index order so every
///   op is valid against the result of the previous one)
/// - append (Brazier extension): `value` is an array of items concatenated to
///   the end of the target array
///
/// Paths are RFC 6901 JSON Pointers: `""` is the root, `/a/0` addresses
/// member `a` then index 0, and keys are escaped `~` -> `~0`, `/` -> `~1`.
/// Map keys are diffed in sorted (UTF-8 bytewise) order, so the server and
/// the JS client (`brazier_client/patch.mjs`) produce identical op lists.
///
/// Applying an unknown op, a malformed op, a malformed pointer or an op
/// whose target does not exist is an error — never a silent skip. The
/// client mirrors this: any patch failure requests a full model sync.
///
/// A path never passes through an unsafe key (`__proto__`, `constructor`,
/// `prototype`; the canonical list is `unsafe_keys/0` in
/// `brazier_patch_ffi.erl`, mirrored by `UNSAFE_PATCH_KEYS` in `patch.mjs`).
/// When one is added, removed or changed, the diff replaces the object that
/// holds it, and both appliers refuse a path through one.
///
/// Reference: RFC 6902 (JSON Patch), RFC 6901 (JSON Pointer).
import brazier/log

/// Diff two JSON model strings and produce patch operations.
/// Returns a JSON-encoded string of the ops array (e.g., `[{"op":"replace","path":"/count","value":1}]`).
/// If the models are identical, returns `"[]"`.
pub fn diff(old_json: String, new_json: String) -> String {
  log.debug("brazier.patch", "Diffing model JSON")
  diff_json(old_json, new_json)
}

/// Apply patch operations to a model JSON string.
/// Returns the patched model JSON string, or an error if application fails.
pub fn apply_ops(
  model_json: String,
  ops_json: String,
) -> Result(String, String) {
  log.debug("brazier.patch", "Applying patch ops to model")
  case apply_json_ops(model_json, ops_json) {
    Ok(patched) -> Ok(patched)
    Error(reason) -> {
      log.warning("brazier.patch", "Patch apply rejected: " <> reason)
      Error(reason)
    }
  }
}

/// Check if an ops JSON string represents no changes (empty array).
pub fn is_empty(ops_json: String) -> Bool {
  is_empty_ops(ops_json)
}

/// Erlang FFI: diff two JSON strings, produce ops JSON.
@external(erlang, "brazier_patch_ffi", "diff_json")
fn diff_json(old_json: String, new_json: String) -> String

/// Erlang FFI: apply ops JSON to model JSON.
@external(erlang, "brazier_patch_ffi", "apply_json_ops")
fn apply_json_ops(
  model_json: String,
  ops_json: String,
) -> Result(String, String)

/// Count the number of operations in a JSON ops string.
/// Used for enforcing depth/size limits on client-sent patches.
pub fn count_ops(ops_json: String) -> Result(Int, String) {
  count_ops_ffi(ops_json)
}

/// The keys no patch path may pass through. The canonical list lives in
/// `brazier_patch_ffi.erl`; the JS client's copy is held equal to it by
/// `test/brazier/patch_test.gleam`.
@external(erlang, "brazier_patch_ffi", "unsafe_keys")
@internal
pub fn unsafe_keys() -> List(String)

/// Erlang FFI: check if ops are empty.
@external(erlang, "brazier_patch_ffi", "is_empty_ops")
fn is_empty_ops(ops_json: String) -> Bool

/// Erlang FFI: count ops in a JSON array string.
@external(erlang, "brazier_patch_ffi", "count_ops")
fn count_ops_ffi(ops_json: String) -> Result(Int, String)
