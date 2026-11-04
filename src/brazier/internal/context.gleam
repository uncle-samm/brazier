/// The request context handed to an app's `init`. Public apps reach it
/// through `brazier.Context` and the accessors in `brazier`; this module exists
/// so `brazier/ssr` and `brazier/runtime` can build one without importing
/// `brazier` (which imports them).
///
/// Reference: LiveView `mount(params, session, socket)` with
/// `connected?(socket)`.
import gleam/list
import gleam/uri.{type Uri}

/// What `init` may know about the request that started a session.
pub opaque type Context {
  Context(
    /// The page URL. For the dead render it is the HTTP request URL; for the
    /// connected mount it is the page URL the client reported when it
    /// opened the WebSocket.
    uri: Uri,
    /// Request cookies, in header order.
    cookies: List(#(String, String)),
    /// False for the dead render (SSR), True for the connected mount.
    is_connected: Bool,
    /// Fingerprint of the browser session cookie, when there is one.
    session_id: Result(String, Nil),
  )
}

/// Build a context. `session_id` is the fingerprint of the session cookie
/// (`ssr.session_fingerprint`), never the raw cookie value.
pub fn new(
  uri uri: Uri,
  cookies cookies: List(#(String, String)),
  is_connected is_connected: Bool,
  session_id session_id: Result(String, Nil),
) -> Context {
  Context(
    uri: uri,
    cookies: cookies,
    is_connected: is_connected,
    session_id: session_id,
  )
}

pub fn uri(ctx: Context) -> Uri {
  ctx.uri
}

/// The first cookie named `name`.
pub fn cookie(ctx: Context, name: String) -> Result(String, Nil) {
  list.key_find(ctx.cookies, name)
}

pub fn is_connected(ctx: Context) -> Bool {
  ctx.is_connected
}

pub fn session_id(ctx: Context) -> Result(String, Nil) {
  ctx.session_id
}
