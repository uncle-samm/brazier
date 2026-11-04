//// Request contexts for tests that start runtimes directly.

import brazier/internal/context
import gleam/option
import gleam/uri

/// The connected-mount context for a local page path such as "/" or
/// "/users/7?tab=posts", with no cookies and no session.
pub fn for_path(path: String) -> context.Context {
  with_cookies(path, [])
}

/// The connected-mount context for a local page path, carrying `cookies`
/// as the browser sent them.
pub fn with_cookies(
  path: String,
  cookies: List(#(String, String)),
) -> context.Context {
  // Callers pass literal local paths; a parse failure is a broken test.
  let assert Ok(parsed) = uri.parse(path)
  context.new(
    uri: uri.Uri(
      ..uri.empty,
      scheme: option.Some("http"),
      host: option.Some("localhost"),
      path: parsed.path,
      query: parsed.query,
    ),
    cookies: cookies,
    is_connected: True,
    session_id: Error(Nil),
  )
}

/// The connected-mount context for "/".
pub fn root() -> context.Context {
  for_path("/")
}
