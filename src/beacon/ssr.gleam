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
import beacon/element.{type Node}
import beacon/error_page
import beacon/handler
import beacon/log
import beacon/route
import beacon/session
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
import gleam/string
import simplifile

/// Configuration for server-side rendering.
pub type SsrConfig(model, msg) {
  SsrConfig(
    /// Initialize the model (same as RuntimeConfig.init).
    init: fn() -> #(model, Effect(msg)),
    /// The view function (same as RuntimeConfig.view).
    view: fn(model) -> Node(msg),
    /// Secret key for signing session tokens.
    secret_key: String,
    /// Application title for the HTML page.
    title: String,
    /// Optional: extra HTML to inject into `<head>` (stylesheets, meta tags, etc.).
    /// Rendered raw — caller is responsible for valid HTML.
    /// Example: `"<link rel=\"stylesheet\" href=\"/static/styles.css\">"`.
    head_html: Option(String),
    /// Enable framework-owned client tracing.
    dev_mode: Bool,
    /// Optional model serializer. When set, the join token carries the
    /// client-visible model JSON (see `client_visible_model_encoder`) so the
    /// runtime can recover state on reconnect.
    serialize_model: Option(fn(model) -> String),
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
  )
}

/// Render the initial page for an HTTP request.
/// This is the "dead render" — produces full HTML without WebSocket.
///
/// Steps (following LiveView's pattern):
/// 1. Run init() to get the initial model
/// 2. Call view(model) to get the Element tree
/// 3. Render Element tree to HTML string
/// 4. Sign a session token containing model identity info
/// 5. Wrap in full HTML document with JS client injected
pub fn render_page(config: SsrConfig(model, msg)) -> RenderedPage {
  log.debug("beacon.ssr", "Rendering dead page")

  // Step 1: Initialize model
  let #(model, _initial_effects) = config.init()
  // Note: initial effects are NOT executed during dead render.
  // They will run when the WebSocket connects (live mount).
  // This matches LiveView's behavior: expensive data loading
  // can be deferred to the live mount phase.

  // Step 2: Render view through the generated renderer when available.
  let view_html = render_view_html(config, model)

  // Step 3: Prepare the join-token signer (model JSON encoded once)
  let signer = join_token_signer(config, Some(model))

  // Step 4: Build full HTML document
  let html =
    build_html_document(
      config.title,
      view_html,
      config.head_html,
      config.dev_mode,
      True,
    )

  log.debug("beacon.ssr", "Dead render complete")
  RenderedPage(
    html: html,
    sign_join_token: signer,
    cookie_secure: !config.dev_mode,
  )
}

/// Render a page for a specific URL path (route-aware SSR).
/// Runs init, then dispatches on_route_change if routes are configured.
/// This ensures each URL gets route-specific SSR HTML.
pub fn render_page_for_path(
  config: SsrConfig(model, msg),
  path: String,
  route_patterns: List(route.RoutePattern),
  on_route_change: Option(fn(route.Route) -> msg),
  update: fn(model, msg) -> #(model, Effect(msg)),
) -> RenderedPage {
  log.debug("beacon.ssr", "Rendering for path: " <> path)

  // Step 1: Initialize model
  let #(model, _effects) = config.init()

  // Step 2: Apply route change if configured
  case on_route_change {
    Some(make_msg) ->
      case route.match_path(route_patterns, path) {
        Some(matched_route) -> {
          let msg = make_msg(matched_route)
          let #(model, _effects) = update(model, msg)
          render_page_for_model(config, path, model)
        }
        None -> render_unmatched_route(config, path)
      }
    None -> render_page_for_model(config, path, model)
  }
}

fn render_unmatched_route(config: SsrConfig(model, msg), path: String) {
  log.warning("beacon.ssr", "No route matched during SSR for path: " <> path)
  render_not_found_page(config)
}

fn render_page_for_model(
  config: SsrConfig(model, msg),
  path: String,
  model: model,
) -> RenderedPage {
  let view_html = render_view_html(config, model)

  let signer = join_token_signer(config, Some(model))

  // Step 5: Build HTML
  let html =
    build_html_document(
      config.title,
      view_html,
      config.head_html,
      config.dev_mode,
      True,
    )

  log.debug("beacon.ssr", "Render complete for: " <> path)
  RenderedPage(
    html: html,
    sign_join_token: signer,
    cookie_secure: !config.dev_mode,
  )
}

fn render_view_html(config: SsrConfig(model, msg), model: model) -> String {
  handler.start_render()
  let view_html = case try_load_codec_renderer() {
    Ok(render) -> {
      log.debug(
        "beacon.ssr",
        "Rendering via generated beacon_codec.render_model/1",
      )
      render(model)
    }
    Error(_) -> {
      log.debug("beacon.ssr", "Rendering via configured direct SSR view")
      let view_tree = config.view(model)
      element.to_string(view_tree)
    }
  }
  // SSR only pops the render stack here; the client re-registers handlers on
  // hydration. WS7 deletes beacon/handler.
  // lint:allow-discard the SSR handler registry is not needed after render
  let _view_registry = handler.finish_render()
  view_html
}

@external(erlang, "beacon_runtime_ffi", "try_load_codec_renderer")
fn try_load_codec_renderer() -> Result(fn(model) -> String, Nil)

fn render_not_found_page(config: SsrConfig(model, msg)) -> RenderedPage {
  let view_html = error_page.not_found() |> element.to_string
  let html =
    build_html_document(
      config.title,
      view_html,
      config.head_html,
      config.dev_mode,
      False,
    )

  RenderedPage(
    html: html,
    sign_join_token: join_token_signer(config, None),
    cookie_secure: !config.dev_mode,
  )
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
  response.new(200)
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
  case session.id_from_request(req, session_identity_cookie_name) {
    Ok(session_id) -> fingerprint_session_id(session_id)
    // No (or an empty) session cookie: the token is unbound.
    Error(Nil) -> ""
  }
}

/// Lowercase hex SHA-256 of a session id. Delegates to
/// `session.binding_fingerprint` so the join token and every other
/// session-bound token share one fingerprint definition.
pub fn fingerprint_session_id(session_id: String) -> String {
  session.binding_fingerprint(session_id)
}

/// The encoder whose output the client already receives in model_sync:
/// the generated `beacon_codec.encode_model` (which excludes Server state)
/// when present, otherwise the configured encoder. The join token only ever
/// carries this JSON, so it never holds more than the wire protocol does.
pub fn client_visible_model_encoder(
  configured: Option(fn(model) -> String),
) -> Option(fn(model) -> String) {
  case try_load_codec_encoder() {
    Ok(encode) -> Some(encode)
    Error(Nil) -> configured
  }
}

@external(erlang, "beacon_runtime_ffi", "try_load_codec_encoder")
fn try_load_codec_encoder() -> Result(fn(model) -> String, Nil)

/// Build the per-response join-token signer for a rendered page. The model
/// is encoded once, here; each call signs with a fresh issue time.
/// The model is only embedded when the app configured a model serializer
/// (it opted into state recovery).
fn join_token_signer(
  config: SsrConfig(model, msg),
  model: Option(model),
) -> fn(String) -> String {
  let model_json = case model, config.serialize_model {
    Some(m), Some(_) ->
      case client_visible_model_encoder(config.serialize_model) {
        Some(encode) -> Some(encode(m))
        None -> None
      }
    _, _ -> None
  }
  let secret_key = config.secret_key
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

/// Build a full HTML document with the view and JS client.
fn build_html_document(
  title: String,
  view_html: String,
  head_html: Option(String),
  dev_mode: Bool,
  include_client: Bool,
) -> String {
  let extra_head = case head_html {
    Some(html) -> html
    None -> ""
  }
  let client_script = case include_client {
    True ->
      string.concat([
        "<script src=\"/",
        client_js_filename(),
        "\" data-beacon-auto></script>",
      ])
    False -> ""
  }
  string.concat([
    "<!DOCTYPE html>",
    "<html><head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "<title>",
    escape_html(title),
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

/// Choose the directory that contains Beacon client assets.
/// Prefer the consuming app's `priv/static` when it has a manifest; otherwise
/// use Beacon's own packaged priv dir for repo/dependency installs.
pub fn choose_client_assets_dir(
  has_local_manifest: Bool,
  local_dir: String,
  beacon_dir: String,
) -> String {
  case has_local_manifest {
    True -> local_dir
    False -> beacon_dir
  }
}

/// Resolve the directory that contains Beacon client assets.
pub fn client_assets_dir() -> String {
  case simplifile.is_file("priv/static/beacon_client.manifest") {
    Ok(True) ->
      choose_client_assets_dir(True, "priv/static", beacon_priv_path("static"))
    Ok(False) ->
      choose_client_assets_dir(False, "priv/static", beacon_priv_path("static"))
    Error(err) -> {
      log.error(
        "beacon.ssr",
        "Failed to inspect local client manifest: " <> string.inspect(err),
      )
      beacon_priv_path("static")
    }
  }
}

/// Get the current client JS filename from the build manifest.
/// The manifest is created by `gleam run -m beacon/build`.
fn client_js_filename() -> String {
  let manifest_path = client_assets_dir() <> "/beacon_client.manifest"
  case simplifile.read(manifest_path) {
    Ok(name) -> string.trim(name)
    Error(err) -> {
      log.error(
        "beacon.ssr",
        "FATAL: No beacon_client.manifest at "
          <> manifest_path
          <> ": "
          <> string.inspect(err)
          <> " — client JS not built. Run `gleam run -m beacon/build`.",
      )
      "MISSING_CLIENT_JS_RUN_BEACON_BUILD"
    }
  }
}

/// Resolve a path relative to Beacon's priv directory.
/// Uses `code:priv_dir(beacon)` for correct resolution from consuming apps.
pub fn beacon_priv_path(relative: String) -> String {
  case ffi_priv_dir() {
    Ok(dir) -> dir <> "/" <> relative
    Error(reason) -> {
      log.error("beacon.ssr", "Failed to resolve Beacon priv dir: " <> reason)
      "MISSING_BEACON_PRIV/" <> relative
    }
  }
}

@external(erlang, "beacon_ssr_ffi", "priv_dir")
fn ffi_priv_dir() -> Result(String, String)

/// Escape HTML special characters in text content.
fn escape_html(text: String) -> String {
  text
  |> do_replace("&", "&amp;")
  |> do_replace("<", "&lt;")
  |> do_replace(">", "&gt;")
  |> do_replace("\"", "&quot;")
}

@external(erlang, "beacon_element_ffi", "string_replace")
fn do_replace(subject: String, pattern: String, replacement: String) -> String

@external(erlang, "beacon_ssr_ffi", "system_time_seconds")
fn erlang_system_time_seconds() -> Int
