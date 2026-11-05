/// Brazier's Server-Side Rendering module.
/// Implements LiveView's "dead render" pattern: on HTTP GET, render the full
/// HTML page with the initial view, inject the client JS, and embed a signed
/// HttpOnly join-token cookie for state recovery on WebSocket connect.
///
/// The join token follows Phoenix.Token: a purpose- and version-tagged,
/// HMAC-signed payload with an issue time, an expiry and the fingerprint of
/// the browser session it was issued to. The runtime verifies all of these
/// before it trusts the embedded model (see `verify_join_token`).
///
/// Reference: LiveView two-phase mount (dead render → live mount),
/// Phoenix.Token (sign/verify with max_age), Leptos SSR modes.
import brazier/cookie
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/error.{type InitError}
import brazier/error_page
import brazier/internal/context
import brazier/internal/http_status
import brazier/internal/log_path
import brazier/internal/render
import brazier/internal/stream_ssr
import brazier/internal/stream_window
import brazier/internal/uri_check
import brazier/log
import brazier/session
import brazier/static
import brazier/telemetry
import brazier/transport/server.{type ResponseBody, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam/uri.{type Uri}
import simplifile

/// Configuration for server-side rendering. `brazier.start` builds this from
/// the app; the functions are the app's own, already composed with its
/// `sync` and local layer.
pub type SsrConfig(state, msg) {
  SsrConfig(
    /// The app's `init`, run with a dead-render context. An `Error` is
    /// answered with an error page for its status.
    init: fn(context.Context) -> Result(#(state, Effect(msg)), InitError),
    /// The app's server `update`, used to apply the route message.
    update: fn(state, msg) -> #(state, Effect(msg)),
    /// `parse` composed with `on_change`, when the app has a router.
    route: Option(fn(Uri) -> Result(msg, Nil)),
    /// Render the page body from the server state.
    view: fn(state) -> Element(msg),
    /// The document title for the server state.
    title: fn(state) -> String,
    /// Secret key for signing join tokens.
    secret_key: String,
    /// Optional: extra HTML to inject into `<head>` (stylesheets, meta tags, etc.).
    /// Rendered raw — caller is responsible for valid HTML.
    /// Example: `"<link rel=\"stylesheet\" href=\"/static/styles.css\">"`.
    head_html: Option(String),
    /// Enable framework-owned client tracing.
    dev_mode: Bool,
    /// The client-visible model encoder, set only when the app opted into
    /// state recovery (`brazier.with_state_recovery`). The join token then
    /// carries the same JSON the client receives in model_sync, so it never
    /// holds more than the wire protocol does.
    recovery_encoder: Option(fn(state) -> String),
    /// The stream bounds the runtime applies, so the dead render keeps the
    /// same items the join will send (docs/design/STREAMS.md 7.6).
    stream_limits: stream_window.Limits,
    /// The streams the build declared (`brazier_codec.stream_names`). An op
    /// on any other name is refused with `unknown_stream`, as the runtime
    /// refuses it.
    stream_names: List(String),
  )
}

/// Cookie that carries the signed join/state recovery token.
pub const session_cookie_name = "brazier_join_token"

/// Cookie that identifies the browser session (set by `brazier/auth`).
/// Join tokens are bound to the SHA-256 fingerprint of its value.
/// Must equal `auth.default_session_cookie_name` (asserted by a test; this
/// module cannot import auth without an import cycle).
pub const session_identity_cookie_name = "brazier_session"

/// Join tokens expire this long after they are issued (24 hours, the same
/// as the join-token cookie's Max-Age).
pub const join_token_lifetime_seconds = 86_400

/// Phoenix.Token-style purpose tag: a token signed for another purpose with
/// the same secret never verifies as a join token.
const join_token_purpose = "brazier.join"

/// Salt for deriving the join-token signing key from the app secret.
const join_token_key_salt = "brazier.join_token.v2"

const join_token_version = 2

/// Tolerated clock skew between nodes for a token's issue time.
const join_token_clock_skew_seconds = 60

/// Largest join-token cookie value we emit. Browsers cap a cookie (name +
/// value) at 4096 bytes and silently drop a larger one, which would lose
/// the session's state with no error anywhere. A page whose token is over
/// the budget is refused instead (see `JoinTokenTooLarge`).
pub const join_token_cookie_budget_bytes = 3800

/// A page's join token, with the state-recovery model in it, is `bytes`
/// long: over the cookie `budget`. The page is answered with a 500 and no
/// cookie rather than a cookie the browser would drop (logged at error,
/// with `[brazier, ssr, join_token, too_large]`).
pub type JoinTokenTooLarge {
  JoinTokenTooLarge(bytes: Int, budget: Int)
}

/// Why a join token was rejected. Every variant means "do not trust the
/// embedded model"; the variants exist so the runtime can log precisely.
pub type JoinTokenError {
  /// Not a well-formed v2 join token (empty, bad encoding, bad JSON).
  JoinTokenMalformed(reason: String)
  /// Signature, version, purpose or validity window check failed (or the
  /// server has no secret to verify with).
  JoinTokenInvalid(reason: String)
  /// Signed correctly but past its expiry.
  JoinTokenExpired(expired_at: Int, now: Int)
  /// Signed for a different browser session than the one connecting.
  JoinTokenSessionMismatch
}

/// A verified join token.
pub type JoinToken {
  JoinToken(issued_at: Int, expires_at: Int, model_json: Option(String))
}

/// Human-readable description of a join-token error, for logs.
pub fn describe_join_token_error(err: JoinTokenError) -> String {
  case err {
    JoinTokenMalformed(reason) -> "malformed join token: " <> reason
    JoinTokenInvalid(reason) -> "invalid join token: " <> reason
    JoinTokenExpired(expired_at, now) ->
      "expired join token (expired at "
      <> int.to_string(expired_at)
      <> ", now "
      <> int.to_string(now)
      <> ")"
    JoinTokenSessionMismatch ->
      "join token was issued to a different browser session"
  }
}

/// A rendered page ready to be sent as an HTTP response.
///
/// The join token is minted per response by `sign_join_token` (a closure
/// over the secret and the rendered model JSON), so every response carries
/// a fresh issue time and the secret never appears in the page value.
pub type RenderedPage {
  RenderedPage(
    /// The full HTML string including doctype, head, body, scripts.
    html: String,
    /// Sign a join token for the given session fingerprint (see
    /// `session_fingerprint`). Use `join_token_for`.
    sign_join_token: fn(String) -> Result(String, JoinTokenTooLarge),
    /// Whether the response sets the join cookie. True for a page that
    /// loads the client script; False for a static error page, which opens
    /// no session, so it neither mints a join token nor replaces the one a
    /// page in another tab may still be joining with.
    join_cookie: Bool,
    /// Whether the session cookie should include the Secure attribute.
    cookie_secure: Bool,
    /// HTTP status: 200 for a rendered route, 404 for an unknown route,
    /// 400 for a URL whose percent-encoding does not decode, the
    /// `InitError`'s status when `init` refused the request, and 500 when
    /// the client bundle is missing.
    status: Int,
  )
}

/// Render the page for an HTTP request (the "dead render").
///
/// Following LiveView's two-phase mount:
/// 1. Check the URL's percent-encoding (400 when it does not decode).
/// 2. Resolve the route, when the app has a router (404 when unknown).
/// 3. Run `init` with a context whose `is_connected` is False. Its effects
///    are not run: they run on the connected mount. An `InitError` is
///    answered with an error page for its status (503 for
///    `error.unavailable`); its reason is logged, never rendered. A crash
///    in `init` propagates, and the transport answers it with 500.
/// 4. Apply the route message through `update` (effects dropped likewise).
///    The stream ops of `init` and of the route message are taken out of
///    their effects and applied, with the runtime's bounds, to windows that
///    keep their items (docs/design/STREAMS.md 7.6). An op on a stream the
///    build did not declare is refused (`unknown_stream`) and logged.
/// 5. Render `view`, each stream container holding its items, and wrap it
///    in the HTML document with the script of the client bundle the server
///    loaded when it started (`client_bundle`); no file is read. A bundle
///    that could not be loaded is a 500 static error page. A stream item
///    that does not decode, or does not render, crashes the dead render,
///    which the transport answers with 500.
pub fn render_page(
  config: SsrConfig(state, msg),
  req: Request(body),
) -> RenderedPage {
  render_page_with_bundle(config, req, client_bundle())
}

/// `render_page` with the given client bundle, `Error` with the reason it
/// could not be loaded, instead of the loaded one.
pub fn render_page_with_bundle(
  config: SsrConfig(state, msg),
  req: Request(body),
  bundle: Result(String, String),
) -> RenderedPage {
  let page_uri = request.to_uri(req)
  let path = describe_uri(page_uri)
  log.debug("brazier.ssr", "Dead render for " <> path)
  case uri_check.check(page_uri) {
    Error(reason) -> {
      log.warning(
        "brazier.ssr",
        "Refusing dead render for " <> path <> " (400): " <> reason,
      )
      render_error_page(
        config,
        400,
        "Bad Request",
        error_page.error_page(
          400,
          "Bad Request",
          "The page address is not valid.",
        ),
      )
    }
    Ok(Nil) ->
      case resolve_route(config.route, page_uri) {
        Error(Nil) -> {
          log.warning("brazier.ssr", "No route for " <> path <> " (404)")
          render_error_page(config, 404, "Not Found", error_page.not_found())
        }
        Ok(route_msg) -> {
          let ctx =
            context.new(
              uri: page_uri,
              cookies: cookie.parse(req),
              is_connected: False,
              session_id: session_id_for_request(req),
            )
          case config.init(ctx) {
            Error(init_error) -> render_init_error(config, init_error, path)
            Ok(#(state, init_effects)) -> {
              let stream_names = set.from_list(config.stream_names)
              let #(windows, init_effects) =
                stream_ssr.apply(
                  stream_ssr.new(),
                  init_effects,
                  stream_names,
                  config.stream_limits,
                  "init",
                  path,
                )
              drop_effects(init_effects, "init", path)
              let #(state, windows) = case route_msg {
                None -> #(state, windows)
                Some(msg) -> {
                  let #(routed, route_effects) = config.update(state, msg)
                  let #(windows, route_effects) =
                    stream_ssr.apply(
                      windows,
                      route_effects,
                      stream_names,
                      config.stream_limits,
                      "route update",
                      path,
                    )
                  drop_effects(route_effects, "route update", path)
                  #(routed, windows)
                }
              }
              render_state(config, state, windows, path, bundle)
            }
          }
        }
      }
  }
}

/// The page for an `init` that refused the request: the error page for its
/// status, without the client script (there is no session to connect to).
/// A 5xx refusal is logged as an error, a 4xx one as a warning.
fn render_init_error(
  config: SsrConfig(state, msg),
  init_error: InitError,
  path: String,
) -> RenderedPage {
  let status = error.init_error_status(init_error)
  let message =
    "init refused the dead render of "
    <> path
    <> " ("
    <> error.init_error_to_string(init_error)
    <> ")"
  case status >= 500 {
    True -> log.error("brazier.ssr", message)
    False -> log.warning("brazier.ssr", message)
  }
  let title = http_status.reason_phrase(status)
  render_error_page(
    config,
    status,
    title,
    error_page.error_page(status, title, init_error_message(status)),
  )
}

/// What the browser is told about a refused page. The app's reason stays
/// in the server log: it may name internals (a database host, a user id).
fn init_error_message(status: Int) -> String {
  case status {
    404 -> "The page you're looking for doesn't exist."
    401 | 403 -> "You are not allowed to see this page."
    503 -> "This page is temporarily unavailable. Please try again shortly."
    _ if status >= 500 -> "Something went wrong on our end."
    _ -> "This page cannot be shown."
  }
}

/// Ok(None) when the app has no router; Ok(Some(msg)) for a known route.
fn resolve_route(
  route: Option(fn(Uri) -> Result(msg, Nil)),
  page_uri: Uri,
) -> Result(Option(msg), Nil) {
  case route {
    None -> Ok(None)
    Some(parse) -> parse(page_uri) |> result.map(Some)
  }
}

/// Dead-render effects are not run (LiveView runs `mount` twice for the
/// same reason: work that needs a live connection belongs to the connected
/// mount, which runs `init` again with `is_connected` True).
fn drop_effects(effects: Effect(msg), stage: String, path: String) -> Nil {
  case effect.is_none(effects) {
    True -> Nil
    False ->
      log.debug(
        "brazier.ssr",
        "Not running " <> stage <> " effects during the dead render of " <> path,
      )
  }
}

fn render_state(
  config: SsrConfig(state, msg),
  state: state,
  windows: stream_window.Windows,
  path: String,
  bundle: Result(String, String),
) -> RenderedPage {
  let rendered =
    stream_ssr.render(element.to_node(config.view(state)), windows, path)
  // Invariant (docs/design/STREAMS.md 7.6): a stream item that does not
  // decode or render crashes the dead render, so the transport serves the
  // 500 page and an encoder and decoder that disagree fail on the first page
  // load. `stream_ssr.render` has logged the reason at error.
  let assert Ok(view_html) = rendered
    as "brazier/ssr: a stream item does not render in the dead render"
  let model_json = case config.recovery_encoder {
    Some(encode) -> Some(encode(state))
    None -> None
  }
  case bundle {
    Ok(bundle) -> {
      let html =
        build_html_document(
          config.title(state),
          view_html,
          config.head_html,
          config.dev_mode,
          Some(bundle),
          dev_build(),
        )
      log.debug("brazier.ssr", "Dead render complete for " <> path)
      RenderedPage(
        html: html,
        sign_join_token: join_token_signer(config.secret_key, model_json, path),
        join_cookie: True,
        cookie_secure: !config.dev_mode,
        status: 200,
      )
    }
    // A page whose script cannot load is not interactive: serve a static
    // 500 instead. A server start fails when the bundle cannot be loaded,
    // so this is a `brazier/dev` rebuild whose bundle did not load, or a
    // render without a started server.
    Error(reason) -> {
      log.error(
        "brazier.ssr",
        "Refusing dead render for " <> path <> " (500): " <> reason,
      )
      render_error_page(
        config,
        500,
        "Internal Server Error",
        error_page.error_page(
          500,
          "Internal Server Error",
          "The page cannot be served right now.",
        ),
      )
    }
  }
}

/// A static error page: no client script, so the browser does not open a
/// session for a page the app cannot render, and no join cookie (see
/// `RenderedPage.join_cookie`).
fn render_error_page(
  config: SsrConfig(state, msg),
  status: Int,
  title: String,
  page: Element(msg),
) -> RenderedPage {
  let html =
    build_html_document(
      title,
      element.to_string(page),
      config.head_html,
      config.dev_mode,
      None,
      None,
    )
  RenderedPage(
    html: html,
    sign_join_token: join_token_signer(
      config.secret_key,
      None,
      "the " <> int.to_string(status) <> " error page",
    ),
    join_cookie: False,
    cookie_secure: !config.dev_mode,
    status: status,
  )
}

/// A page URL for logs: its path only (see `brazier/internal/log_path`).
fn describe_uri(page_uri: Uri) -> String {
  log_path.describe_uri(page_uri)
}

/// Convert a RenderedPage to an HTTP response whose join token is not bound
/// to a browser session (fingerprint ""). Prefer `to_response_for_request`,
/// which binds the token to the request's session cookie; an unbound token
/// only verifies for a connection that also has no session cookie.
/// A page whose `join_cookie` is False gets no join cookie, and a page
/// whose join token is over the cookie budget is answered with a 500 and no
/// cookie (see `JoinTokenTooLarge`).
/// Errors when the join token cannot be set as a cookie.
pub fn to_response(
  page: RenderedPage,
) -> Result(Response(ResponseBody), cookie.CookieError) {
  page_response(page, "")
}

/// Convert a RenderedPage to an HTTP response whose join token is bound to
/// the session cookie on `req` (see `session_fingerprint`).
/// A page whose `join_cookie` is False gets no join cookie, and a page
/// whose join token is over the cookie budget is answered with a 500 and no
/// cookie (see `JoinTokenTooLarge`).
/// Errors when the join token cannot be set as a cookie.
pub fn to_response_for_request(
  page: RenderedPage,
  req: Request(body),
) -> Result(Response(ResponseBody), cookie.CookieError) {
  page_response(page, session_fingerprint(req))
}

fn page_response(
  page: RenderedPage,
  fingerprint: String,
) -> Result(Response(ResponseBody), cookie.CookieError) {
  let resp =
    response.new(page.status)
    |> response.set_header("content-type", "text/html; charset=utf-8")
    |> response.set_body(Bytes(bytes_tree.from_string(page.html)))
  case page.join_cookie {
    True ->
      case join_token_for(page, fingerprint) {
        Ok(token) ->
          cookie.set(
            resp,
            session_cookie_name,
            token,
            session_cookie_options(page.cookie_secure),
          )
        // The signer logged it at error and emitted telemetry.
        Error(JoinTokenTooLarge(..)) -> Ok(join_token_too_large_response())
      }
    False -> {
      log.debug(
        "brazier.ssr",
        "No join cookie on the "
          <> int.to_string(page.status)
          <> " page: it loads no client",
      )
      Ok(resp)
    }
  }
}

/// The answer to a page whose join token does not fit in a cookie: the
/// page would load, but its state could never be recovered, so it is not
/// served at all.
fn join_token_too_large_response() -> Response(ResponseBody) {
  response.new(500)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(Bytes(bytes_tree.from_string("Internal Server Error")))
}

/// Mint a fresh join token for this page, bound to `fingerprint`. Errors
/// when the token is over the cookie budget (already logged at error).
pub fn join_token_for(
  page: RenderedPage,
  fingerprint: String,
) -> Result(String, JoinTokenTooLarge) {
  page.sign_join_token(fingerprint)
}

fn session_cookie_options(secure: Bool) -> cookie.CookieOptions {
  cookie.CookieOptions(
    max_age: Some(join_token_lifetime_seconds),
    path: "/",
    http_only: True,
    secure: secure,
    same_site: "Lax",
  )
}

/// Fingerprint of the browser session a request belongs to: the lowercase
/// hex SHA-256 of its `brazier_session` cookie, or "" when there is none.
/// The raw session id never enters a token.
pub fn session_fingerprint(req: Request(body)) -> String {
  case session_id_for_request(req) {
    Ok(fingerprint) -> fingerprint
    // No (or an empty) session cookie: the token is unbound.
    Error(Nil) -> ""
  }
}

/// The session identity `init` sees (`brazier.session_id`): the
/// fingerprint of the request's `brazier_session` cookie, or Error(Nil)
/// when the request has none.
pub fn session_id_for_request(req: Request(body)) -> Result(String, Nil) {
  session.id_from_request(req, session_identity_cookie_name)
  |> result.map(fingerprint_session_id)
}

/// Lowercase hex SHA-256 of a session id. Delegates to
/// `session.binding_fingerprint` so the join token and every other
/// session-bound token share one fingerprint definition.
pub fn fingerprint_session_id(session_id: String) -> String {
  session.binding_fingerprint(session_id)
}

/// Build the per-response join-token signer for a rendered page. The model
/// JSON is encoded once, by the caller; each call signs with a fresh issue
/// time. `model_json` is None unless the app opted into state recovery.
/// `path` names the page in the log line of a refused token.
fn join_token_signer(
  secret_key: String,
  model_json: Option(String),
  path: String,
) -> fn(String) -> Result(String, JoinTokenTooLarge) {
  fn(fingerprint) {
    sign_join_token(
      secret_key,
      fingerprint,
      model_json,
      erlang_system_time_seconds(),
    )
    |> check_join_token_size(path)
  }
}

/// Refuse a join token over the cookie budget. The model is never dropped
/// to make it fit: the session would then restart from `init` on its next
/// reconnect with nothing in the logs to say why.
fn check_join_token_size(
  token: String,
  path: String,
) -> Result(String, JoinTokenTooLarge) {
  let bytes = string.byte_size(token)
  case bytes > join_token_cookie_budget_bytes {
    False -> Ok(token)
    True -> {
      log.error(
        "brazier.ssr",
        "Refusing "
          <> path
          <> " (500): its join token is "
          <> int.to_string(bytes)
          <> " bytes, over the "
          <> int.to_string(join_token_cookie_budget_bytes)
          <> "-byte cookie budget. The state-recovery model is too large for"
          <> " a cookie: keep less client-visible state, or do not use"
          <> " brazier.with_state_recovery",
      )
      telemetry.ssr_join_token_too_large(bytes, join_token_cookie_budget_bytes)
      Error(JoinTokenTooLarge(
        bytes: bytes,
        budget: join_token_cookie_budget_bytes,
      ))
    }
  }
}

/// Sign a join token (Phoenix.Token style) bound to a session fingerprint.
/// Payload: `{"v":2,"purpose":"brazier.join","iat":..,"exp":..,"sid":..,
/// "model":string|null}`, HMAC-SHA256 signed with a key derived from
/// `secret_key`.
pub fn sign_join_token(
  secret_key: String,
  session_fingerprint: String,
  model_json: Option(String),
  issued_at: Int,
) -> String {
  // INVARIANT: `brazier.start` and the cluster refuse an empty or weak
  // secret_key at start, so every caller has a real key. A token signed
  // with "" would never verify.
  let assert True = secret_key != ""
    as "sign_join_token: secret_key is empty; brazier.start refuses an empty secret_key"
  let payload =
    json.object([
      #("v", json.int(join_token_version)),
      #("purpose", json.string(join_token_purpose)),
      #("iat", json.int(issued_at)),
      #("exp", json.int(issued_at + join_token_lifetime_seconds)),
      #("sid", json.string(session_fingerprint)),
      #("model", json.nullable(model_json, json.string)),
    ])
    |> json.to_string
  crypto.sign_message(
    bit_array.from_string(payload),
    join_token_key(secret_key),
    crypto.Sha256,
  )
}

fn join_token_key(secret_key: String) -> BitArray {
  crypto.hmac(
    bit_array.from_string(join_token_key_salt),
    crypto.Sha256,
    bit_array.from_string(secret_key),
  )
}

type JoinTokenPayload {
  JoinTokenPayload(
    version: Int,
    purpose: String,
    issued_at: Int,
    expires_at: Int,
    session: String,
    model_json: Option(String),
  )
}

/// Verify a join token for the connecting browser session at time `now`
/// (unix seconds). Checks, in order: secret present, token present,
/// signature, encoding, payload shape, version, purpose, validity window,
/// issue time not in the future, expiry, and session binding (constant
/// time).
pub fn verify_join_token(
  token: String,
  secret_key: String,
  session_fingerprint: String,
  now: Int,
) -> Result(JoinToken, JoinTokenError) {
  use <- guard(secret_key == "", JoinTokenInvalid("server secret_key is empty"))
  use <- guard(token == "", JoinTokenMalformed("empty token"))
  use payload_bits <- try_or(
    crypto.verify_signed_message(token, join_token_key(secret_key)),
    JoinTokenInvalid("signature verification failed"),
  )
  use payload_str <- try_or(
    bit_array.to_string(payload_bits),
    JoinTokenMalformed("payload is not UTF-8"),
  )
  use payload <- try_or(
    json.parse(payload_str, join_token_payload_decoder()),
    JoinTokenMalformed("payload is not a v2 join token object"),
  )
  use <- guard(
    payload.version != join_token_version,
    JoinTokenInvalid(
      "unsupported token version " <> int.to_string(payload.version),
    ),
  )
  use <- guard(
    payload.purpose != join_token_purpose,
    JoinTokenInvalid("wrong token purpose " <> payload.purpose),
  )
  let lifetime = payload.expires_at - payload.issued_at
  use <- guard(
    lifetime <= 0 || lifetime > join_token_lifetime_seconds,
    JoinTokenInvalid("validity window out of range"),
  )
  use <- guard(
    payload.issued_at > now + join_token_clock_skew_seconds,
    JoinTokenInvalid("issued in the future"),
  )
  use <- guard(
    now >= payload.expires_at,
    JoinTokenExpired(expired_at: payload.expires_at, now: now),
  )
  use <- guard(
    !crypto.secure_compare(
      bit_array.from_string(payload.session),
      bit_array.from_string(session_fingerprint),
    ),
    JoinTokenSessionMismatch,
  )
  Ok(JoinToken(
    issued_at: payload.issued_at,
    expires_at: payload.expires_at,
    model_json: payload.model_json,
  ))
}

fn join_token_payload_decoder() -> decode.Decoder(JoinTokenPayload) {
  use version <- decode.field("v", decode.int)
  use purpose <- decode.field("purpose", decode.string)
  use issued_at <- decode.field("iat", decode.int)
  use expires_at <- decode.field("exp", decode.int)
  use session <- decode.field("sid", decode.string)
  use model_json <- decode.field("model", decode.optional(decode.string))
  decode.success(JoinTokenPayload(
    version:,
    purpose:,
    issued_at:,
    expires_at:,
    session:,
    model_json:,
  ))
}

fn guard(
  failed: Bool,
  err: JoinTokenError,
  next: fn() -> Result(JoinToken, JoinTokenError),
) -> Result(JoinToken, JoinTokenError) {
  case failed {
    True -> Error(err)
    False -> next()
  }
}

fn try_or(
  result: Result(a, e),
  err: JoinTokenError,
  next: fn(a) -> Result(JoinToken, JoinTokenError),
) -> Result(JoinToken, JoinTokenError) {
  case result {
    Ok(value) -> next(value)
    Error(_) -> Error(err)
  }
}

/// Build a full HTML document with the view and, for a live page, the
/// script tag of the client bundle named `bundle` and the dev build
/// (`new_dev_build`) its join reports.
fn build_html_document(
  title: String,
  view_html: String,
  head_html: Option(String),
  dev_mode: Bool,
  bundle: Option(String),
  dev_build: Option(String),
) -> String {
  let extra_head = case head_html {
    Some(html) -> html
    None -> ""
  }
  let client_script = case bundle {
    Some(name) -> "<script src=\"/" <> name <> "\"></script>"
    None -> ""
  }
  let dev_build_attribute = case dev_build {
    Some(id) -> " data-brazier-dev-build=\"" <> render.escape_html(id) <> "\""
    None -> ""
  }
  string.concat([
    "<!DOCTYPE html>",
    "<html><head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "<title>",
    render.escape_html(title),
    "</title>",
    extra_head,
    "</head><body>",
    "<div id=\"brazier-app\" data-brazier-dev=\"",
    case dev_mode {
      True -> "true"
      False -> "false"
    },
    "\"",
    dev_build_attribute,
    ">",
    view_html,
    "</div>",
    client_script,
    "</body></html>",
  ])
}

/// The directory holding the app's client bundle and its manifest: the
/// app's own `priv/static`, written by `gleam run -m brazier/build`. The
/// runtime bundle in Brazier's own `priv` starts no app, so it is never
/// served in its place.
pub fn client_assets_dir() -> String {
  "priv/static"
}

/// Read the app's client bundle name from disk
/// (`client_bundle_name(client_assets_dir())`) and store it as the bundle
/// every page render and every join uses (`client_bundle`). The outcome is
/// stored either way: after a failed load, pages answer 500 and joins with
/// a build id close 1011 until a load succeeds, rather than serving a
/// bundle the server can no longer vouch for.
///
/// The server calls this when it starts (`brazier.start`, and each
/// `transport.start_listener`), so a failure fails the start, and
/// `brazier/dev` calls it again after each successful rebuild. Nothing else
/// reads the manifest: a page render or a join touches no file.
/// Reference: Phoenix's static manifest (`cache_static_manifest`), read
/// once when the endpoint starts.
pub fn load_client_bundle() -> Result(String, String) {
  let loaded = client_bundle_name(client_assets_dir())
  case store_bundle(loaded), loaded {
    True, Ok(name) -> log.info("brazier.ssr", "Client bundle loaded: " <> name)
    False, Ok(name) ->
      log.debug("brazier.ssr", "Client bundle unchanged: " <> name)
    _, Error(reason) ->
      log.error("brazier.ssr", "Cannot load the client bundle: " <> reason)
  }
  loaded
}

/// The client bundle `load_client_bundle` loaded last, read from memory:
/// the script every live page loads, and the build a join is checked
/// against. An `Error` when that load failed, or when no load ran (code
/// that renders without a started server).
pub fn client_bundle() -> Result(String, String) {
  case loaded_bundle() {
    Ok(loaded) -> loaded
    Error(Nil) ->
      Error(
        "no client bundle was loaded: the server loads it when it starts "
        <> "(brazier.start, transport.start_listener)",
      )
  }
}

/// The bundle file named by `brazier_client.manifest` in `assets_dir`, read
/// from disk. The name must be exact build output
/// (`static.is_client_bundle_name`), and the file must exist.
/// `load_client_bundle` is the server's one caller; a render or a join uses
/// the loaded name (`client_bundle`).
pub fn client_bundle_name(assets_dir: String) -> Result(String, String) {
  read_client_bundle_name(assets_dir, assets_dir <> "/brazier_client.manifest")
}

/// Start a new dev build: a random id that every page rendered from now on
/// carries (`data-brazier-dev-build`) and sends back with its join. A join
/// with another id comes from a page rendered before the last rebuild, and
/// the transport tells it to reload. That reaches a page that was between
/// sockets when the rebuild's `reload` was broadcast.
///
/// Only `brazier/dev` calls this, when it starts and after each successful
/// rebuild; a server outside dev mode has no dev build.
/// Reference: Phoenix LiveView's `phx-track-static`, which compares the
/// static assets a page loaded with the server's on every join.
pub fn new_dev_build() -> String {
  let id = bit_array.base16_encode(crypto.strong_random_bytes(8))
  store_dev_build(id)
  log.info("brazier.ssr", "Dev build is now " <> id)
  id
}

/// The current dev build (`new_dev_build`); `None` outside dev mode.
pub fn dev_build() -> Option(String) {
  stored_dev_build()
}

/// Store a load's outcome; True when it differs from the stored one.
@external(erlang, "brazier_bundle_manifest_ffi", "store_bundle")
fn store_bundle(loaded: Result(String, String)) -> Bool

@external(erlang, "brazier_bundle_manifest_ffi", "loaded_bundle")
fn loaded_bundle() -> Result(Result(String, String), Nil)

@external(erlang, "brazier_bundle_manifest_ffi", "store_dev_build")
fn store_dev_build(id: String) -> Nil

@external(erlang, "brazier_bundle_manifest_ffi", "dev_build")
fn stored_dev_build() -> Option(String)

fn client_bundle_hint() -> String {
  " Run `gleam run -m brazier/build`."
}

fn read_client_bundle_name(
  assets_dir: String,
  manifest_path: String,
) -> Result(String, String) {
  use contents <- result.try(
    simplifile.read(manifest_path)
    |> result.map_error(fn(err) {
      "Cannot read "
      <> manifest_path
      <> " ("
      <> simplifile.describe_error(err)
      <> ")."
      <> client_bundle_hint()
    }),
  )
  let name = string.trim(contents)
  use Nil <- result.try(case static.is_client_bundle_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        manifest_path
        <> " names an invalid bundle "
        <> string.inspect(name)
        <> "."
        <> client_bundle_hint(),
      )
  })
  check_client_bundle_exists(assets_dir, manifest_path, name)
}

fn check_client_bundle_exists(
  assets_dir: String,
  manifest_path: String,
  name: String,
) -> Result(String, String) {
  case simplifile.is_file(assets_dir <> "/" <> name) {
    Ok(True) -> Ok(name)
    Ok(False) ->
      Error(
        manifest_path
        <> " names "
        <> name
        <> ", which does not exist."
        <> client_bundle_hint(),
      )
    Error(err) ->
      Error(
        "Cannot check "
        <> assets_dir
        <> "/"
        <> name
        <> " ("
        <> simplifile.describe_error(err)
        <> ")."
        <> client_bundle_hint(),
      )
  }
}

@external(erlang, "brazier_ssr_ffi", "system_time_seconds")
fn erlang_system_time_seconds() -> Int
