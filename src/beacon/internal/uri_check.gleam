/// Percent-encoding validation for routed URLs. Beacon runs `check` on a
/// URL before it hands the URL to an app's `parse`, so `beacon/router`'s
/// `segments` and `query` can decode without a failure case.
///
/// This lives apart from `beacon/router` because `beacon/ssr` needs it and
/// `beacon/router` depends on `beacon/transport`, which depends on
/// `beacon/ssr`.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}

/// Ok when every path segment and the query string percent-decode.
pub fn check(uri: Uri) -> Result(Nil, String) {
  use Nil <- result.try(
    uri.path_segments(uri.path)
    |> list.try_each(fn(segment) {
      uri.percent_decode(segment)
      |> result.replace(Nil)
      |> result.replace_error(
        "invalid percent-encoding in path segment " <> string.inspect(segment),
      )
    }),
  )
  case uri.query {
    None -> Ok(Nil)
    Some(query) ->
      uri.parse_query(query)
      |> result.replace(Nil)
      |> result.replace_error("invalid query string " <> string.inspect(query))
  }
}
