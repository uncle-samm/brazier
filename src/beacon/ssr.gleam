/// Beacon's Server-Side Rendering module.
/// Implements LiveView's "dead render" pattern: on HTTP GET, render the full
/// HTML page with the initial view, inject the client JS, and embed a signed
/// HttpOnly session cookie for state recovery on WebSocket connect.
///
/// Reference: LiveView two-phase mount (dead render → live mount),
/// Leptos SSR modes.
import beacon/cookie
import beacon/effect.{type Effect}
import beacon/element.{type Node}
import beacon/error_page
import beacon/handler
import beacon/log
import beacon/route
import beacon/transport/server.{type ResponseBody, Bytes}
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/http/response.{type Response}
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
    /// Optional model serializer for state recovery cookies.
    serialize_model: Option(fn(model) -> String),
  )
}

/// Cookie that carries the signed join/state recovery token.
pub const session_cookie_name = "beacon_join_token"

/// A rendered page ready to be sent as an HTTP response.
pub type RenderedPage {
  RenderedPage(
    /// The full HTML string including doctype, head, body, scripts.
    html: String,
    /// The signed session token sent in an HttpOnly cookie.
    session_token: String,
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

  // Step 3: Create session token
  let token =
    create_session_token_for_model(
      model,
      config.serialize_model,
      config.secret_key,
    )

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
    session_token: token,
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

  let token =
    create_session_token_for_model(
      model,
      config.serialize_model,
      config.secret_key,
    )

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
    session_token: token,
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
    session_token: create_session_token(config.secret_key),
    cookie_secure: !config.dev_mode,
  )
}

/// Convert a RenderedPage to an HTTP response. Errors when the session
/// cookie cannot be set (a token outside the cookie-octet set).
pub fn to_response(
  page: RenderedPage,
) -> Result(Response(ResponseBody), cookie.CookieError) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(Bytes(bytes_tree.from_string(page.html)))
  |> cookie.set(
    session_cookie_name,
    page.session_token,
    session_cookie_options(page.cookie_secure),
  )
}

fn session_cookie_options(secure: Bool) -> cookie.CookieOptions {
  cookie.CookieOptions(
    max_age: Some(max_token_lifetime_seconds),
    path: "/",
    http_only: True,
    secure: secure,
    same_site: "Lax",
  )
}

/// Create a signed session token.
/// The token contains a timestamp for expiration checking.
/// Reference: LiveView signs session tokens with Phoenix.Token.
pub fn create_session_token(secret_key: String) -> String {
  let timestamp = erlang_system_time_seconds()
  let payload =
    json.object([
      #("ts", json.int(timestamp)),
      #("v", json.int(1)),
    ])
    |> json.to_string
  let secret = bit_array.from_string(secret_key)
  let message = bit_array.from_string(payload)
  crypto.sign_message(message, secret, crypto.Sha256)
}

fn create_session_token_for_model(
  model: model,
  serialize_model: Option(fn(model) -> String),
  secret_key: String,
) -> String {
  case serialize_model {
    Some(serialize) -> {
      let payload =
        json.object([
          #("ts", json.int(erlang_system_time_seconds())),
          #("v", json.int(1)),
          #("model", json.string(serialize(model))),
        ])
        |> json.to_string
      let secret = bit_array.from_string(secret_key)
      let message = bit_array.from_string(payload)
      crypto.sign_message(message, secret, crypto.Sha256)
    }
    None -> create_session_token(secret_key)
  }
}

/// Maximum token lifetime: 24 hours. Any max_age_seconds above this is capped.
/// Prevents misconfiguration from creating long-lived tokens.
const max_token_lifetime_seconds = 86_400

/// Verify a session token and extract the payload.
/// Returns Ok(timestamp) if valid, Error otherwise.
/// max_age_seconds is capped at 24 hours (86400s) to prevent long-lived tokens.
pub fn verify_session_token(
  token: String,
  secret_key: String,
  max_age_seconds: Int,
) -> Result(Int, String) {
  // Cap the max age to prevent misconfigured long-lived tokens
  let capped_max_age = case max_age_seconds > max_token_lifetime_seconds {
    True -> max_token_lifetime_seconds
    False -> max_age_seconds
  }
  let secret = bit_array.from_string(secret_key)
  case crypto.verify_signed_message(token, secret) {
    Ok(payload_bits) -> {
      case bit_array.to_string(payload_bits) {
        Ok(payload_str) -> {
          case parse_token_payload(payload_str) {
            Ok(timestamp) -> {
              let now = erlang_system_time_seconds()
              let age = now - timestamp
              case age > capped_max_age {
                True -> Error("Session token expired")
                False -> Ok(timestamp)
              }
            }
            Error(reason) -> Error(reason)
          }
        }
        Error(Nil) -> Error("Invalid token payload encoding")
      }
    }
    Error(Nil) -> Error("Invalid or tampered session token")
  }
}

/// Parse the token JSON payload to extract the timestamp.
fn parse_token_payload(payload_str: String) -> Result(Int, String) {
  let decoder = {
    use ts <- decode.field("ts", decode.int)
    decode.success(ts)
  }
  case json.parse(payload_str, decoder) {
    Ok(ts) -> Ok(ts)
    Error(_) -> Error("Failed to parse token payload")
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

import gleam/dynamic/decode
