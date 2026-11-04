//// Page paths in log lines.
////
//// A path a log line names comes from the client (the request line, a
//// join, a navigation). Its query and fragment can carry tokens or personal
//// data, so they never reach a log (LiveView's `filter_parameters` keeps
//// such values out of its logs too), and the rest is quoted with
//// `string.inspect`, so a client-chosen path cannot add control characters
//// or forge a log line.

import gleam/string
import gleam/uri.{type Uri}

/// `path` for a log line: without its query and fragment, quoted.
pub fn describe(path: String) -> String {
  let path = case string.split_once(path, "?") {
    Ok(#(before, _query)) -> before
    Error(Nil) -> path
  }
  let path = case string.split_once(path, "#") {
    Ok(#(before, _fragment)) -> before
    Error(Nil) -> path
  }
  string.inspect(path)
}

/// A page URL for a log line: its path only, see `describe`.
pub fn describe_uri(page_uri: Uri) -> String {
  describe(page_uri.path)
}
