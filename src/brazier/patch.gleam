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
import gleam/dynamic.{type Dynamic}

/// A model JSON document and its decoded form. The runtime keeps the last
/// snapshot it sent, so each new model is decoded once per event and the
/// previous one is never decoded again (PERF-2).
///
/// Invariant: `term` is the decoding of `json`, and `json` is valid JSON
/// (`snapshot/1` is the only constructor, and it refuses anything else).
pub opaque type Snapshot {
  Snapshot(json: String, term: Dynamic)
}

/// What changed between two snapshots.
pub type Diff {
  /// The documents are equal; there is nothing to send.
  Unchanged
  /// A non-empty RFC 6902 ops array (plus the Brazier `append` op), as JSON.
  Ops(json: String)
}

/// Decode a model JSON document into a snapshot. An error when it is not a
/// single valid JSON value (trailing bytes are refused).
pub fn snapshot(json: String) -> Result(Snapshot, String) {
  case decode_snapshot(json) {
    Ok(term) -> Ok(Snapshot(json:, term:))
    Error(reason) -> {
      log.warning("brazier.patch", "Snapshot refused: " <> reason)
      Error(reason)
    }
  }
}

/// The JSON document a snapshot was decoded from.
pub fn snapshot_json(snapshot: Snapshot) -> String {
  snapshot.json
}

/// Diff two snapshots. Neither document is decoded: both terms are cached.
/// Applying `Ops(json)` to `snapshot_json(old)` gives a document equal to
/// `snapshot_json(new)`.
pub fn diff_snapshots(old: Snapshot, new: Snapshot) -> Diff {
  log.debug("brazier.patch", "Diffing model snapshots")
  case diff_terms(old.term, new.term) {
    DiffUnchanged -> Unchanged
    DiffOps(json) -> Ops(json:)
  }
}

/// Diff two JSON model strings. Decodes both, so the runtime uses
/// `diff_snapshots/2` with its cached snapshot instead. An error when either
/// document is not valid JSON.
pub fn diff(old_json: String, new_json: String) -> Result(Diff, String) {
  case snapshot(old_json), snapshot(new_json) {
    Ok(old), Ok(new) -> Ok(diff_snapshots(old, new))
    Error(reason), _ -> Error("old model: " <> reason)
    _, Error(reason) -> Error("new model: " <> reason)
  }
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

/// Erlang FFI: decode one JSON document; only malformed input is an error.
@external(erlang, "brazier_patch_ffi", "decode_snapshot")
fn decode_snapshot(json: String) -> Result(Dynamic, String)

/// The FFI's result for `diff_terms/2`: the atom `unchanged` or the tuple
/// `{ops, Json}`.
type TermDiff {
  DiffUnchanged
  DiffOps(String)
}

/// Erlang FFI: diff two decoded documents.
@external(erlang, "brazier_patch_ffi", "diff_terms")
fn diff_terms(old: Dynamic, new: Dynamic) -> TermDiff

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

/// Erlang FFI: count ops in a JSON array string.
@external(erlang, "brazier_patch_ffi", "count_ops")
fn count_ops_ffi(ops_json: String) -> Result(Int, String)
