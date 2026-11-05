/// Stream ops as data: what `brazier/stream`'s op functions build and the
/// runtime applies to a session's stream windows
/// (`brazier/internal/stream_window`).
///
/// An op holds everything the runtime needs and nothing it must call back
/// into: the stream's name and limit, the item's key and its JSON text,
/// already encoded by the stream's `encode` when the op was built. So an op
/// can be taken out of an effect before the update is broadcast, and it
/// carries no closure over the app's types (docs/design/STREAMS.md 7.1).
///
/// The types here mirror the public ones in `brazier/stream` (`Limit`,
/// `Position`) instead of reusing them, because `brazier/stream` builds
/// these ops and `brazier/effect` will carry them: this module imports
/// neither, so neither import is a cycle.
/// Which end of a full stream is kept. `First` is `stream.KeepFirst`
/// (LiveView `limit: n`), `Last` is `stream.KeepLast` (LiveView
/// `limit: -n`).
pub type Keep {
  First
  Last
}

/// A stream's limit: the end it keeps and how many items it holds at most.
pub type Limit {
  Limit(keep: Keep, count: Int)
}

/// Where a key that is not in the stream goes. `Front` is `stream.Prepend`,
/// `Back` is `stream.Append`. A key already in the stream never moves.
pub type End {
  Front
  Back
}

/// What one op does to its stream.
pub type Action {
  /// Insert `key` at `at`, or update it in place when the stream holds it.
  /// `json` is the item's encoded JSON text.
  Insert(key: String, json: String, at: End)
  /// Remove `key`. A key not in the stream changes nothing and is reported.
  Delete(key: String)
  /// Empty the stream, then insert `items` (`#(key, json)`) at the back, in
  /// order.
  Reset(items: List(#(String, String)))
}

/// One op on the stream `name`, declared with `limit`.
pub type Op {
  Op(name: String, limit: Limit, action: Action)
}

/// The wire spelling of `keep`: `"first"` or `"last"`
/// (docs/design/STREAMS.md 6.1).
pub fn keep_to_string(keep: Keep) -> String {
  case keep {
    First -> "first"
    Last -> "last"
  }
}
