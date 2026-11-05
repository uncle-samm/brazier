/// Percent-encoding validation for routed URLs. Brazier runs `check` on a
/// URL before it hands the URL to an app's `parse`, so `brazier/router`'s
/// `segments` and `query` can decode without a failure case.
///
/// This lives apart from `brazier/router` because `brazier/ssr` needs it and
/// `brazier/router` depends on `brazier/transport`, which depends on
/// `brazier/ssr`.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}

/// Ok when every path segment and the query string percent-decode to UTF-8
/// and every `%` starts a two-hex-digit escape (RFC 3986 section 2.1).
/// `gleam/uri` decodes a stray `%` as itself; Brazier refuses it, so one URL
/// never has two readings.
pub fn check(uri: Uri) -> Result(Nil, String) {
  use Nil <- result.try(
    uri.path_segments(uri.path)
    |> list.try_each(fn(segment) {
      let failure =
        "invalid percent-encoding in path segment " <> string.inspect(segment)
      use Nil <- result.try(well_formed_escapes(segment, failure))
      uri.percent_decode(segment)
      |> result.replace(Nil)
      |> result.replace_error(failure)
    }),
  )
  case uri.query {
    None -> Ok(Nil)
    Some(query) -> {
      // The query is not quoted in the reason: it can carry a token, and
      // the reason reaches log lines (see `brazier/internal/log_path`).
      let failure = "invalid query string: it does not percent-decode to UTF-8"
      use Nil <- result.try(well_formed_escapes(query, failure))
      uri.parse_query(query)
      |> result.replace(Nil)
      |> result.replace_error(failure)
    }
  }
}

/// Error(failure) when some `%` is not followed by two hex digits.
fn well_formed_escapes(raw: String, failure: String) -> Result(Nil, String) {
  case string.split(raw, "%") {
    // The text before the first `%` needs no check.
    [_before, ..escapes] ->
      list.try_each(escapes, fn(after_percent) {
        case string.to_graphemes(string.slice(after_percent, 0, 2)) {
          [high, low] ->
            case is_hex_digit(high) && is_hex_digit(low) {
              True -> Ok(Nil)
              False -> Error(failure)
            }
          _ -> Error(failure)
        }
      })
    // Unreachable: string.split returns at least one part. Refuse anyway.
    [] -> Error(failure)
  }
}

fn is_hex_digit(grapheme: String) -> Bool {
  string.contains("0123456789abcdefABCDEF", grapheme)
  && string.length(grapheme) == 1
}
