/// Beacon's Server-Side Rendering module.
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
import beacon/cookie
import beacon/effect.{type Effect}
import beacon/element.{type Element}
import beacon/error.{type InitError}
import beacon/error_page
import beacon/internal/context
import beacon/internal/http_status
import beacon/internal/render
import beacon/internal/uri_check
import beacon/log
import beacon/session
import beacon/static
import beacon/transport/server.{type ResponseBody, Bytes}
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
import gleam/string
import gleam/uri.{type Uri}
import simplifile

/// Configuration for server-side rendering. `beacon.start` builds this from
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
    /// state recovery (`beacon.with_state_recovery`). The join token then
    /// carries the same JSON the client receives in model_sync, so it never
    /// holds more than the wire protocol does.
    recovery_encoder: Option(fn(state) -> String),
  )
}

/// Cookie that carries the signed join/state recovery token.
pub const session_cookie_name = "beacon_join_token"

/// Cookie that identifies the browser session (set by `beacon/auth`).
/// Join tokens are bound to the SHA-256 fingerprint of its value.
/// Must equal `auth.default_session_cookie_name` (asserted by a test; this
/// module cannot import auth without an import cycle).
pub const session_identity_cookie_name = "beacon_session"

/// Join tokens expire this long after they are issued (24 hours, the same
/// as the join-token cookie's Max-Age).
pub const join_token_lifetime_seconds = 86_400

/// Phoenix.Token-style purpose tag: a token signed for another purpose with
/// the same secret never verifies as a join token.
const join_token_purpose = "beacon.join"

/// Salt for deriving the join-token signing key from the app secret.
const join_token_key_salt = "beacon.join_token.v2"

const join_token_version = 2

/// Tolerated clock skew between nodes for a token's issue time.
const join_token_clock_skew_seconds = 60

/// Largest join-token cookie value we emit. Browsers cap a cookie (name +
/// value) at 4096 bytes; a larger token would be silently dropped, so the
/// model is omitted instead (logged).
const join_token_cookie_budget_bytes = 3800

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
    sign_join_token: fn(String) -> String,
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
/// 5. Render `view` and wrap it in the HTML document with the client script.
pub fn render_page(
  config: SsrConfig(state, msg),
  req: Request(body),
) -> RenderedPage {
  let page_uri = request.to_uri(req)
  let path = describe_uri(page_uri)
  log.debug("beacon.ssr", "Dead render for " <> path)
  case uri_check.check(page_uri) {
    Error(reason) -> {
      log.warning(
        "beacon.ssr",
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
          log.warning("beacon.ssr", "No route for " <> path <> " (404)")
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
              drop_effects(init_effects, "init", path)
              let state = case route_msg {
                None -> state
                Some(msg) -> {
                  let #(routed, route_effects) = config.update(state, msg)
                  drop_effects(route_effects, "route update", path)
                  routed
                }
              }
              render_state(config, state, path)
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
    True -> log.error("beacon.ssr", message)
    False -> log.warning("beacon.ssr", message)
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
        "beacon.ssr",
        "Not running " <> stage <> " effects during the dead render of " <> path,
      )
  }
}

fn render_state(
  config: SsrConfig(state, msg),
  state: state,
  path: String,
) -> RenderedPage {
  let view_html = element.to_string(config.view(state))
  let model_json = case config.recovery_encoder {
    Some(encode) -> Some(encode(state))
    None -> None
  }
  case client_bundle_name(client_assets_dir()) {
    Ok(bundle) -> {
      let html =
        build_html_document(
          config.title(state),
          view_html,
          config.head_html,
          config.dev_mode,
          Some(bundle),
        )
      log.debug("beacon.ssr", "Dead render complete for " <> path)
      RenderedPage(
        html: html,
        sign_join_token: join_token_signer(config.secret_key, model_json),
        cookie_secure: !config.dev_mode,
        status: 200,
      )
    }
    // A page whose script cannot load is not interactive: serve a static
    // 500 instead. `beacon.start` checks the bundle at startup, so this
    // means it was removed or damaged while the server was running.
    Error(reason) -> {
      log.error(
        "beacon.ssr",
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
/// session for a page the app cannot render.
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
    )
  RenderedPage(
    html: html,
    sign_join_token: join_token_signer(config.secret_key, None),
    cookie_secure: !config.dev_mode,
    status: status,
  )
}

/// Path and query for logs.
fn describe_uri(page_uri: Uri) -> String {
  case page_uri.query {
    Some(query) -> page_uri.path <> "?" <> query
    None -> page_uri.path
  }
}

/// Convert a RenderedPage to an HTTP response whose join token is not bound
/// to a browser session (fingerprint ""). Prefer `to_response_for_request`,
/// which binds the token to the request's session cookie; an unbound token
/// only verifies for a connection that also has no session cookie.
/// Errors when the join token cannot be set as a cookie.
pub fn to_response(
  page: RenderedPage,
) -> Result(Response(ResponseBody), cookie.CookieError) {
  page_response(page, "")
}

/// Convert a RenderedPage to an HTTP response whose join token is bound to
/// the session cookie on `req` (see `session_fingerprint`).
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
  response.new(page.status)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(Bytes(bytes_tree.from_string(page.html)))
  |> cookie.set(
    session_cookie_name,
    join_token_for(page, fingerprint),
    session_cookie_options(page.cookie_secure),
  )
}

/// Mint a fresh join token for this page, bound to `fingerprint`.
pub fn join_token_for(page: RenderedPage, fingerprint: String) -> String {
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
/// hex SHA-256 of its `beacon_session` cookie, or "" when there is none.
/// The raw session id never enters a token.
pub fn session_fingerprint(req: Request(body)) -> String {
  case session_id_for_request(req) {
    Ok(fingerprint) -> fingerprint
    // No (or an empty) session cookie: the token is unbound.
    Error(Nil) -> ""
  }
}

/// The session identity `init` sees (`beacon.session_id`): the
/// fingerprint of the request's `beacon_session` cookie, or Error(Nil)
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
fn join_token_signer(
  secret_key: String,
  model_json: Option(String),
) -> fn(String) -> String {
  fn(fingerprint) {
    sign_join_token_within_budget(
      secret_key,
      fingerprint,
      model_json,
      erlang_system_time_seconds(),
    )
  }
}

/// Sign a join token, dropping the model when the token would not fit in a
/// cookie (a browser silently discards an oversized cookie).
fn sign_join_token_within_budget(
  secret_key: String,
  fingerprint: String,
  model_json: Option(String),
  issued_at: Int,
) -> String {
  let token = sign_join_token(secret_key, fingerprint, model_json, issued_at)
  case model_json, string.byte_size(token) > join_token_cookie_budget_bytes {
    Some(_), True -> {
      log.warning(
        "beacon.ssr",
        "Join token is "
          <> int.to_string(string.byte_size(token))
          <> " bytes (cookie budget "
          <> int.to_string(join_token_cookie_budget_bytes)
          <> "); omitting the model, state will not be recovered on reconnect",
      )
      sign_join_token(secret_key, fingerprint, None, issued_at)
    }
    _, _ -> token
  }
}

/// Sign a join token (Phoenix.Token style) bound to a session fingerprint.
/// Payload: `{"v":2,"purpose":"beacon.join","iat":..,"exp":..,"sid":..,
/// "model":string|null}`, HMAC-SHA256 signed with a key derived from
/// `secret_key`.
pub fn sign_join_token(
  secret_key: String,
  session_fingerprint: String,
  model_json: Option(String),
  issued_at: Int,
) -> String {
  case secret_key {
    "" ->
      log.warning(
        "beacon.ssr",
        "Signing a join token with an empty secret_key; it will never verify",
      )
    _ -> Nil
  }
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

/// Create a signed join token with no model and no session binding.
/// Kept for callers of the v1 API; see `sign_join_token`.
pub fn create_session_token(secret_key: String) -> String {
  sign_join_token(secret_key, "", None, erlang_system_time_seconds())
}

/// Maximum accepted `max_age_seconds` for `verify_session_token`.
const max_token_lifetime_seconds = join_token_lifetime_seconds

/// Verify an unbound join token (see `create_session_token`) and return its
/// issue time. `max_age_seconds` is capped at 24 hours.
pub fn verify_session_token(
  token: String,
  secret_key: String,
  max_age_seconds: Int,
) -> Result(Int, String) {
  let capped_max_age = int.min(max_age_seconds, max_token_lifetime_seconds)
  let now = erlang_system_time_seconds()
  case verify_join_token(token, secret_key, "", now) {
    Ok(verified) ->
      case now - verified.issued_at > capped_max_age {
        True -> Error("Session token expired")
        False -> Ok(verified.issued_at)
      }
    Error(JoinTokenExpired(_, _)) -> Error("Session token expired")
    Error(err) -> Error(describe_join_token_error(err))
  }
}

/// Build a full HTML document with the view and, for a live page, the
/// script tag of the client bundle named `bundle`.
fn build_html_document(
  title: String,
  view_html: String,
  head_html: Option(String),
  dev_mode: Bool,
  bundle: Option(String),
) -> String {
  let extra_head = case head_html {
    Some(html) -> html
    None -> ""
  }
  let client_script = case bundle {
    Some(name) -> "<script src=\"/" <> name <> "\"></script>"
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
    "<div id=\"beacon-app\" data-beacon-dev=\"",
    case dev_mode {
      True -> "true"
      False -> "false"
    },
    "\">",
    view_html,
    "</div>",
    client_script,
    "</body></html>",
  ])
}

/// The directory holding the app's client bundle and its manifest: the
/// app's own `priv/static`, written by `gleam run -m beacon/build`. The
/// runtime bundle in Beacon's own `priv` starts no app, so it is never
/// served in its place.
pub fn client_assets_dir() -> String {
  "priv/static"
}

/// The bundle file named by `beacon_client.manifest` in `assets_dir`. The
/// name must be exact build output (`static.is_client_bundle_name`), and
/// the file must exist.
pub fn client_bundle_name(assets_dir: String) -> Result(String, String) {
  let manifest_path = assets_dir <> "/beacon_client.manifest"
  let hint = " Run `gleam run -m beacon/build`."
  use contents <- result.try(
    simplifile.read(manifest_path)
    |> result.map_error(fn(err) {
      "Cannot read "
      <> manifest_path
      <> " ("
      <> simplifile.describe_error(err)
      <> ")."
      <> hint
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
        <> hint,
      )
  })
  case simplifile.is_file(assets_dir <> "/" <> name) {
    Ok(True) -> Ok(name)
    Ok(False) ->
      Error(
        manifest_path <> " names " <> name <> ", which does not exist." <> hint,
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
        <> hint,
      )
  }
}

@external(erlang, "beacon_ssr_ffi", "system_time_seconds")
fn erlang_system_time_seconds() -> Int
