/// Server-side routing helpers for `brazier.with_router`.
///
/// An app declares one `Route` type and one `parse: fn(Uri) -> Result(Route,
/// Nil)`, usually a `case` over `segments(uri)`. Brazier calls `parse` for the
/// dead render, for the connected mount and for every client navigation, and
/// dispatches `on_change(route)` through `update`. `Error(Nil)` answers 404.
///
/// Brazier checks the URL's percent-encoding before it calls `parse`: a path
/// or query that does not decode is answered with 400 (dead render) or a full
/// page load (client navigation, which then gets the 400). `segments` and
/// `query` therefore always decode.
///
/// Reference: LiveView `handle_params/3`, `push_patch`, `push_navigate`,
/// `redirect`.
import brazier/effect.{type Effect}
import brazier/log
import brazier/transport
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri.{type Uri}

/// The percent-decoded path segments, with empty and dot segments removed:
/// `/users/J%C3%BCrgen/` → `["users", "Jürgen"]`.
///
/// Brazier only passes URIs whose encoding it checked to `parse`; calling
/// this on
/// an unchecked URI with invalid percent-encoding crashes.
pub fn segments(uri: Uri) -> List(String) {
  uri.path_segments(uri.path)
  |> list.map(fn(segment) {
    // Invariant: Brazier validated every segment (`internal/uri_check`)
    // before calling the app's `parse`, so decoding cannot fail here.
    let assert Ok(decoded) = uri.percent_decode(segment)
      as "router.segments: a segment does not percent-decode; the URI skipped Brazier's encoding check"
    decoded
  })
}

/// The percent-decoded query parameters, in order:
/// `?q=a%20b&page=2` → `[#("q", "a b"), #("page", "2")]`.
///
/// Like `segments`, this crashes on an unchecked URI whose query does not
/// decode.
pub fn query(uri: Uri) -> List(#(String, String)) {
  case uri.query {
    None -> []
    Some(query) -> {
      // Invariant: `internal/uri_check` parsed this query before the app's
      // `parse` ran.
      let assert Ok(pairs) = uri.parse_query(query)
        as "router.query: the query does not parse; the URI skipped Brazier's encoding check"
      pairs
    }
  }
}

/// Change the URL to `path` (pushing a history entry) without reloading the
/// page; `on_change` then runs for the new route, as for a link click.
/// `path` must be a same-origin path such as `/users/7?tab=posts`.
pub fn push(path: String) -> Effect(msg) {
  navigation_effect("push", path, transport.SendNavigate(path: path))
}

/// Like `push`, but replaces the current history entry.
pub fn replace(path: String) -> Effect(msg) {
  navigation_effect("replace", path, transport.SendReplaceNavigate(path: path))
}

/// Load `url` as a new page (a full page load, ending this session).
/// `url` must be a same-origin path, as for `push`.
pub fn redirect(url: String) -> Effect(msg) {
  navigation_effect("redirect", url, transport.SendHardNavigate(path: url))
}

/// `Ok(Nil)` when `path` is a same-origin absolute path, else why not.
///
/// A browser resolves more than `//host` to another origin: it reads `\`
/// as `/`, and strips tab, newline and carriage return anywhere in a URL, so
/// `/\evil.com` and `/<tab>/evil.com` both load `evil.com`. The rule is
/// Phoenix's `validate_local_url` (no leading `//`, no `\`, no `/%09`) plus
/// every ASCII control character. The client checks the same rule, and also
/// resolves the path against its own origin.
@internal
pub fn check_local_path(path: String) -> Result(Nil, String) {
  case path {
    "//" <> _ | "/\\" <> _ ->
      Error("it starts with two slashes, which a browser reads as another host")
    "/" <> _ ->
      case
        string.contains(path, "\\"),
        string.contains(path, "/%09"),
        has_control_character(path)
      {
        True, _, _ ->
          Error("it contains a backslash, which a browser reads as \"/\"")
        _, True, _ ->
          Error("it contains \"/%09\", an encoded tab some browsers strip")
        _, _, True ->
          Error(
            "it contains a control character, which a browser may strip (a tab between two slashes leaves \"//\")",
          )
        False, False, False -> Ok(Nil)
      }
    _ -> Error("it does not start with \"/\"")
  }
}

/// Whether `text` holds an ASCII control character (U+0000 to U+001F, or
/// U+007F).
fn has_control_character(text: String) -> Bool {
  string.to_utf_codepoints(text)
  |> list.any(fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    code < 0x20 || code == 0x7F
  })
}

fn navigation_effect(
  kind: String,
  path: String,
  message: transport.InternalMessage,
) -> Effect(msg) {
  effect.from(fn(_dispatch) {
    case check_local_path(path) {
      Error(reason) ->
        log.error(
          "brazier.routing",
          "router."
            <> kind
            <> " needs a same-origin path starting with \"/\"; refusing "
            <> string.inspect(path)
            <> ": "
            <> reason,
        )
      Ok(Nil) ->
        case get_navigation_targets() {
          [] ->
            log.warning(
              "brazier.routing",
              "router."
                <> kind
                <> " to "
                <> path
                <> " has no connection to navigate (effect not run by a session runtime, or the session has no connection)",
            )
          targets -> {
            log.debug(
              "brazier.routing",
              "router."
                <> kind
                <> " to "
                <> path
                <> " on "
                <> int.to_string(list.length(targets))
                <> " connection(s)",
            )
            list.each(targets, fn(subject) { process.send(subject, message) })
          }
        }
    }
  })
}

/// The connections to navigate: the one whose event is being handled, or
/// every connection of the session for effects run outside a client event.
/// Stored by the runtime before it runs effects; `[]` elsewhere.
@external(erlang, "brazier_runtime_ffi", "get_navigation_targets")
fn get_navigation_targets() -> List(Subject(transport.InternalMessage))
