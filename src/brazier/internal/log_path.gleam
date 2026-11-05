//// Page paths in log lines.
////
//// A path a log line names comes from the client (the request line, a
//// join, a navigation). Its query and fragment can carry tokens or personal
//// data, so they never reach a log (LiveView's `filter_parameters` keeps
//// such values out of its logs too), and the rest is quoted with
//// `string.inspect`, so a client-chosen path cannot add control characters
//// or forge a log line.
////
//// A client also chooses the path's length, so a log line keeps at most
//// `max_bytes` of it. A longer path is cut there and says so after the
//// closing quote, where client text never appears:
//// `"/very/long/pa" (1488 more bytes left out)`.

import gleam/bit_array
import gleam/int
import gleam/string
import gleam/uri.{type Uri}

/// The most bytes of a path (after its query and fragment are dropped, and
/// before quoting) a log line keeps.
pub const max_bytes = 256

/// `path` for a log line: without its query and fragment, cut to
/// `max_bytes`, quoted. A cut path ends with the number of bytes left out.
pub fn describe(path: String) -> String {
  let path = case string.split_once(path, "?") {
    Ok(#(before, _query)) -> before
    Error(Nil) -> path
  }
  let path = case string.split_once(path, "#") {
    Ok(#(before, _fragment)) -> before
    Error(Nil) -> path
  }
  let size = string.byte_size(path)
  case size > max_bytes {
    False -> string.inspect(path)
    True -> {
      let kept = utf8_prefix(<<path:utf8>>, max_bytes, 0)
      let left_out = size - string.byte_size(kept)
      let unit = case left_out {
        1 -> " more byte left out)"
        _ -> " more bytes left out)"
      }
      string.inspect(kept) <> " (" <> int.to_string(left_out) <> unit
    }
  }
}

/// The longest valid UTF-8 prefix of `bytes` at most `length` bytes long.
/// A code point is at most 4 bytes, so a cut through one is mended by
/// dropping at most 3 bytes; `dropped` counts them.
fn utf8_prefix(bytes: BitArray, length: Int, dropped: Int) -> String {
  // INVARIANT: `bytes` is valid UTF-8 (it came from a String), so one of
  // the 4 lengths `length` down to `length - 3` ends on a code point.
  let assert True = dropped <= 3
    as "log_path: no code point boundary in the last 4 bytes of a UTF-8 cut"
  let assert Ok(slice) = bit_array.slice(bytes, 0, length)
    as "log_path: the cut is inside the path"
  case bit_array.to_string(slice) {
    Ok(prefix) -> prefix
    Error(Nil) -> utf8_prefix(bytes, length - 1, dropped + 1)
  }
}

/// A page URL for a log line: its path only, see `describe`.
pub fn describe_uri(page_uri: Uri) -> String {
  describe(page_uri.path)
}
