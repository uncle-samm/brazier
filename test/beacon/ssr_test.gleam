import beacon/auth
import beacon/cookie
import beacon/effect
import beacon/element
import beacon/error
import beacon/html
import beacon/internal/context.{type Context}
import beacon/log_capture
import beacon/session
import beacon/ssr
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import gleam/uri.{type Uri}
import simplifile

// --- Test helpers ---

pub type TestModel {
  TestModel(name: String)
}

pub type TestMsg {
  SetName(String)
}

const test_secret = "test-secret-key-at-least-32-chars-long!!"

fn test_view(model: TestModel) -> element.Element(TestMsg) {
  html.div([], [html.h1([], [html.text("Hello, " <> model.name <> "!")])])
}

fn test_update(
  _model: TestModel,
  msg: TestMsg,
) -> #(TestModel, effect.Effect(TestMsg)) {
  case msg {
    SetName(name) -> #(TestModel(name: name), effect.none())
  }
}

fn test_config() -> ssr.SsrConfig(TestModel, TestMsg) {
  ssr.SsrConfig(
    init: fn(_ctx) { Ok(#(TestModel(name: "World"), effect.none())) },
    update: test_update,
    route: option.None,
    view: test_view,
    title: fn(_model) { "Test Page" },
    secret_key: test_secret,
    head_html: option.None,
    dev_mode: False,
    recovery_encoder: option.None,
  )
}

/// A router that knows "/" and "/about"; the route message renames the model
/// after the page, so the rendered HTML shows that update ran.
fn routed_config() -> ssr.SsrConfig(TestModel, TestMsg) {
  ssr.SsrConfig(
    ..test_config(),
    init: fn(_ctx) { Ok(#(TestModel(name: "default"), effect.none())) },
    route: option.Some(fn(page: Uri) {
      case page.path {
        "/" -> Ok(SetName("home"))
        "/about" -> Ok(SetName("about"))
        _ -> Error(Nil)
      }
    }),
  )
}

/// An init that reports every call, to prove when the dead render runs it.
fn reporting_config(
  calls: Subject(Context),
) -> ssr.SsrConfig(TestModel, TestMsg) {
  ssr.SsrConfig(..routed_config(), init: fn(ctx) {
    process.send(calls, ctx)
    Ok(#(TestModel(name: "default"), effect.none()))
  })
}

fn render(config: ssr.SsrConfig(TestModel, TestMsg)) -> ssr.RenderedPage {
  ssr.render_page(config, request.new())
}

fn render_path(
  config: ssr.SsrConfig(TestModel, TestMsg),
  path: String,
) -> ssr.RenderedPage {
  ssr.render_page(config, request.new() |> request.set_path(path))
}

// --- Tests ---

pub fn render_page_produces_html_test() {
  let page = render(test_config())
  // Verify doctype is at the very start of the HTML string
  let assert True = string.starts_with(page.html, "<!DOCTYPE html>")
  // Verify ORDER: <!DOCTYPE html> comes before <html> comes before </html>
  let assert Ok(doctype_pos) = string_index_of(page.html, "<!DOCTYPE html>")
  let assert Ok(html_open_pos) = string_index_of(page.html, "<html>")
  let assert Ok(html_close_pos) = string_index_of(page.html, "</html>")
  let assert True = doctype_pos < html_open_pos
  let assert True = html_open_pos < html_close_pos
  let assert 200 = page.status
}

pub fn render_page_includes_view_content_test() {
  let page = render(test_config())
  let assert True = str_contains(page.html, "Hello, World!")
  // "Hello, World!" appears AFTER id="beacon-app" (inside the app root)
  let assert Ok(app_pos) = string_index_of(page.html, "id=\"beacon-app\"")
  let assert Ok(content_pos) = string_index_of(page.html, "Hello, World!")
  let assert True = app_pos < content_pos
  let assert True = str_contains(page.html, "<h1>Hello, World!</h1>")
}

pub fn render_page_includes_title_test() {
  let page = render(test_config())
  let assert True = str_contains(page.html, "<title>Test Page</title>")
}

pub fn render_page_title_is_computed_from_the_rendered_state_test() {
  let config =
    ssr.SsrConfig(..routed_config(), title: fn(model: TestModel) {
      "Page " <> model.name
    })
  let page = render_path(config, "/about")
  let assert True = str_contains(page.html, "<title>Page about</title>")
}

pub fn render_page_escapes_the_title_test() {
  let config =
    ssr.SsrConfig(..test_config(), title: fn(_model) { "</title><script>" })
  let page = render(config)
  let assert False = str_contains(page.html, "</title><script>")
}

pub fn render_page_includes_script_tag_test() {
  let page = render(test_config())
  let assert Ok(bundle) = ssr.client_bundle_name(ssr.client_assets_dir())
  let assert True =
    str_contains(page.html, "<script src=\"/" <> bundle <> "\"></script>")
}

// --- The client bundle named by the manifest ---

const bundle = "beacon_client_0123456789abcdef.js"

/// Runs `run` on a fresh assets directory holding `manifest` as its manifest
/// (when given) and the files in `bundles`, then deletes it.
///
/// The directory sits one level inside its own root, so a bundle named
/// `../x` is written inside the root, not into /tmp. The root is named with
/// random bytes, not `erlang:unique_integer`: that counter is unique only
/// within one VM, so `gleam test` runs that are concurrent, or follow one
/// another, compute the same names. A test then found an earlier run's
/// manifest in "its" directory. `create_directory` (not `_all`) fails on a
/// name that already exists, rather than writing into it.
fn with_assets_dir(
  manifest: option.Option(String),
  bundles: List(String),
  run: fn(String) -> a,
) -> a {
  let root =
    "/tmp/beacon_ssr_assets_"
    <> bit_array.base16_encode(crypto.strong_random_bytes(16))
  let assert Ok(Nil) = simplifile.create_directory(root)
    as "the assets root must not exist yet"
  let dir = root <> "/static"
  let assert Ok(Nil) = simplifile.create_directory(dir)
  case manifest {
    option.Some(text) -> {
      let assert Ok(Nil) =
        simplifile.write(dir <> "/beacon_client.manifest", text)
      Nil
    }
    option.None -> Nil
  }
  list.each(bundles, fn(name) {
    let assert Ok(Nil) = simplifile.write(dir <> "/" <> name, "start(App);")
  })
  let result = run(dir)
  let assert Ok(Nil) = simplifile.delete(root) as "assets root cleanup"
  result
}

/// A page whose client bundle cannot be named is a static 500: no script,
/// no join cookie. Nothing falls back to Beacon's own bundle.
fn assert_render_refused(dir: String) -> Nil {
  let page = ssr.render_page_from(test_config(), request.new(), dir)
  let assert 500 = page.status
  let assert False = page.join_cookie
  let assert False = str_contains(page.html, "<script")
  let assert True = str_contains(page.html, "Internal Server Error")
  Nil
}

pub fn render_page_without_manifest_is_500_test() {
  use dir <- with_assets_dir(option.None, [bundle])
  assert_render_refused(dir)
}

pub fn render_page_with_manifest_naming_missing_bundle_is_500_test() {
  use dir <- with_assets_dir(option.Some(bundle), [])
  assert_render_refused(dir)
}

pub fn render_page_with_invalid_bundle_name_is_500_test() {
  use dir <- with_assets_dir(option.Some("../secret.js"), ["../secret.js"])
  assert_render_refused(dir)
}

pub fn render_page_from_serves_the_named_bundle_test() {
  use dir <- with_assets_dir(option.Some(bundle <> "\n"), [bundle])
  let page = ssr.render_page_from(test_config(), request.new(), dir)
  let assert 200 = page.status
  let assert True = page.join_cookie
  let assert True = str_contains(page.html, bundle)
}

pub fn client_assets_dir_is_the_apps_priv_static_test() {
  let assert "priv/static" = ssr.client_assets_dir()
}

pub fn client_bundle_name_reads_the_manifest_test() {
  use dir <- with_assets_dir(option.Some(bundle <> "\n"), [bundle])
  let assert Ok(name) = ssr.client_bundle_name(dir)
  let assert True = name == bundle
}

pub fn client_bundle_name_without_manifest_is_an_error_test() {
  use dir <- with_assets_dir(option.None, [bundle])
  let assert Error(reason) = ssr.client_bundle_name(dir)
  let assert True = str_contains(reason, "beacon_client.manifest")
  let assert True = str_contains(reason, "gleam run -m beacon/build")
}

pub fn client_bundle_name_refuses_a_name_that_is_not_build_output_test() {
  {
    use dir <- with_assets_dir(option.Some("../secret.js"), ["../secret.js"])
    let assert Error(reason) = ssr.client_bundle_name(dir)
    let assert True = str_contains(reason, "invalid bundle")
  }
  use dir <- with_assets_dir(option.Some(""), [])
  let assert Error(_) = ssr.client_bundle_name(dir)
}

pub fn client_bundle_name_refuses_a_missing_bundle_test() {
  use dir <- with_assets_dir(option.Some(bundle), [])
  let assert Error(reason) = ssr.client_bundle_name(dir)
  let assert True = str_contains(reason, "does not exist")
}

pub fn render_page_sets_session_token_without_dom_exposure_test() {
  let page = render(test_config())
  let assert False = str_contains(page.html, "data-beacon-token=\"")
  // The token verifies with the same secret
  let assert Ok(_ts) =
    ssr.verify_session_token(ssr.join_token_for(page, ""), test_secret, 3600)
}

// --- Routing and the dead-render context ---

pub fn render_page_applies_the_route_message_test() {
  let page = render_path(routed_config(), "/about")
  let assert 200 = page.status
  let assert True = str_contains(page.html, "Hello, about!")
  let home = render_path(routed_config(), "/")
  let assert True = str_contains(home.html, "Hello, home!")
}

pub fn render_page_without_router_renders_every_path_test() {
  let page = render_path(test_config(), "/anything/at/all")
  let assert 200 = page.status
  let assert True = str_contains(page.html, "Hello, World!")
}

pub fn render_page_unknown_route_is_a_static_404_test() {
  let page = render_path(routed_config(), "/missing")
  let assert 404 = page.status
  let assert True = str_contains(page.html, "Page Not Found")
  let assert True = str_contains(page.html, "id=\"beacon-app\"")
  // No client script: the browser opens no session for an error page.
  let assert False = str_contains(page.html, "<script")
  let assert False = str_contains(page.html, "Hello, default!")
  let assert Ok(resp) = ssr.to_response(page)
  let assert 404 = resp.status
}

pub fn render_page_unknown_route_does_not_run_init_test() {
  let calls = process.new_subject()
  let page = render_path(reporting_config(calls), "/missing")
  let assert 404 = page.status
  let assert Error(Nil) = process.receive(calls, 0)
}

pub fn render_page_init_unavailable_is_a_static_503_test() {
  let config =
    ssr.SsrConfig(..test_config(), init: fn(_ctx) {
      Error(error.unavailable("orders-db.internal:5432 refused"))
    })
  let #(page, logs) = log_capture.capture(fn() { render(config) })
  let assert 503 = page.status
  let assert True = str_contains(page.html, "Service Unavailable")
  let assert True = str_contains(page.html, "temporarily unavailable")
  // No client script: there is no session to connect to.
  let assert False = str_contains(page.html, "<script")
  // The app's reason is logged, never rendered.
  let assert False = str_contains(page.html, "orders-db")
  let assert True =
    log_capture.has(logs, level: "error", containing: [
      "init refused the dead render of",
      "503: orders-db.internal:5432 refused",
    ])
  let assert Ok(resp) = ssr.to_response(page)
  let assert 503 = resp.status
}

pub fn render_page_init_refusal_carries_its_status_test() {
  let config =
    ssr.SsrConfig(..test_config(), init: fn(_ctx) {
      Error(error.refuse(404, "board 7 is archived"))
    })
  let #(page, logs) = log_capture.capture(fn() { render(config) })
  let assert 404 = page.status
  let assert True = str_contains(page.html, "Not Found")
  let assert False = str_contains(page.html, "archived")
  let assert False = str_contains(page.html, "<script")
  // A client error is the app's answer, not a failure: a warning.
  let assert True =
    log_capture.has(logs, level: "warning", containing: [
      "init refused", "404: board 7 is archived",
    ])
  let assert False =
    log_capture.has(logs, level: "error", containing: ["init refused"])
}

pub fn render_page_init_refusal_skips_the_route_update_test() {
  // A refused init has no state to route: the router's update never runs.
  let calls = process.new_subject()
  let config =
    ssr.SsrConfig(
      ..routed_config(),
      init: fn(_ctx) { Error(error.refuse(403, "not a member")) },
      update: fn(model, msg) {
        process.send(calls, Nil)
        test_update(model, msg)
      },
    )
  let page = render_path(config, "/about")
  let assert 403 = page.status
  let assert Error(Nil) = process.receive(calls, 0)
}

pub fn render_page_bad_percent_encoding_is_a_static_400_test() {
  let calls = process.new_subject()
  let page = render_path(reporting_config(calls), "/%zz")
  let assert 400 = page.status
  let assert True = str_contains(page.html, "Bad Request")
  let assert False = str_contains(page.html, "<script")
  let assert Error(Nil) = process.receive(calls, 0)
  let assert Ok(resp) = ssr.to_response(page)
  let assert 400 = resp.status
}

pub fn render_page_bad_query_encoding_is_a_static_400_test() {
  let page =
    ssr.render_page(
      test_config(),
      request.Request(..request.new(), query: option.Some("a=%zz")),
    )
  let assert 400 = page.status
  let assert False = str_contains(page.html, "Hello, World!")
}

pub fn render_page_gives_init_a_dead_render_context_test() {
  let calls = process.new_subject()
  let req =
    request.new()
    |> request.set_path("/about")
    |> request.set_header("cookie", "theme=dark; beacon_session=session-a")
  let page = ssr.render_page(reporting_config(calls), req)
  let assert 200 = page.status
  let assert Ok(ctx) = process.receive(calls, 0)
  let assert False = context.is_connected(ctx)
  let assert "/about" = context.uri(ctx).path
  let assert Ok("dark") = context.cookie(ctx, "theme")
  let assert Error(Nil) = context.cookie(ctx, "missing")
  let assert Ok(_fingerprint) = context.session_id(ctx)
  // init runs exactly once per dead render.
  let assert Error(Nil) = process.receive(calls, 0)
}

pub fn render_page_without_session_cookie_has_no_session_id_test() {
  let calls = process.new_subject()
  let page = render_path(reporting_config(calls), "/")
  let assert 200 = page.status
  let assert Ok(ctx) = process.receive(calls, 0)
  let assert Error(Nil) = context.session_id(ctx)
}

pub fn render_page_does_not_run_init_effects_test() {
  let ran = process.new_subject()
  let config =
    ssr.SsrConfig(..test_config(), init: fn(_ctx) {
      Ok(#(
        TestModel(name: "World"),
        effect.from(fn(_dispatch) { process.send(ran, Nil) }),
      ))
    })
  let page = render(config)
  let assert 200 = page.status
  let assert Error(Nil) = process.receive(ran, 50)
}

pub fn recovery_model_is_stored_in_signed_cookie_token_test() {
  let config =
    ssr.SsrConfig(
      ..test_config(),
      init: fn(_ctx) { Ok(#(TestModel(name: "VisibleState"), effect.none())) },
      title: fn(_model) { "Cookie State Test" },
      recovery_encoder: option.Some(fn(_model: TestModel) {
        "SecretCookieState"
      }),
    )
  let page = render(config)
  let assert Ok(_) =
    ssr.verify_session_token(ssr.join_token_for(page, ""), test_secret, 3600)
  let assert False = str_contains(page.html, "SecretCookieState")
}

// --- head_html tests ---

pub fn head_html_none_renders_no_extra_content_test() {
  let page = render(test_config())
  // No <style> block (removed hardcoded demo styles)
  let assert True = does_not_contain(page.html, "<style>")
  // head_html is None, so no extra content between </title> and </head>
  let assert True = str_contains(page.html, "</title></head>")
}

pub fn head_html_injects_stylesheet_link_test() {
  let config =
    ssr.SsrConfig(
      ..test_config(),
      title: fn(_model) { "CSS Test" },
      head_html: option.Some(
        "<link rel=\"stylesheet\" href=\"/static/styles.css\">",
      ),
    )
  let page = render(config)
  let assert True =
    str_contains(
      page.html,
      "<link rel=\"stylesheet\" href=\"/static/styles.css\">",
    )
  // The link tag is in the head section (after title, before </head>)
  let assert Ok(title_pos) = string_index_of(page.html, "</title>")
  let assert Ok(link_pos) =
    string_index_of(page.html, "<link rel=\"stylesheet\"")
  let assert Ok(head_close_pos) = string_index_of(page.html, "</head>")
  let assert True = title_pos < link_pos
  let assert True = link_pos < head_close_pos
}

pub fn head_html_multiple_tags_test() {
  let config =
    ssr.SsrConfig(
      ..test_config(),
      title: fn(_model) { "Multi Head Test" },
      head_html: option.Some(
        "<link rel=\"stylesheet\" href=\"/a.css\"><meta name=\"theme-color\" content=\"#000\">",
      ),
    )
  let page = render(config)
  let assert True = str_contains(page.html, "href=\"/a.css\"")
  let assert True = str_contains(page.html, "theme-color")
}

// --- Session token tests ---

pub fn create_session_token_is_a_signed_message_without_the_secret_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  // gleam/crypto.sign_message: protected header, payload, signature.
  let assert [header, payload, signature] = string.split(token, ".")
  let assert True = header != "" && payload != "" && signature != ""
  let assert False = string.contains(token, secret)
}

pub fn verify_valid_token_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  let assert Ok(ts) = ssr.verify_session_token(token, secret, 3600)
  // The timestamp is recent: within the last 60 seconds
  let now = current_system_time_seconds()
  let age = now - ts
  let assert True = age >= 0
  let assert True = age < 60
}

pub fn verify_token_wrong_secret_test() {
  let token = ssr.create_session_token("correct-secret-key-for-signing!!")
  let assert Error(_) =
    ssr.verify_session_token(token, "wrong-secret-key-for-verifying!!!", 3600)
}

pub fn verify_expired_token_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  // max_age of -1 seconds: the token is already "expired"
  let assert Error("Session token expired") =
    ssr.verify_session_token(token, secret, -1)
}

pub fn verify_tampered_token_test() {
  let secret = "my-secret-key-for-testing-purposes!!"
  let token = ssr.create_session_token(secret)
  let tampered = token <> "x"
  let assert Error(_) = ssr.verify_session_token(tampered, secret, 3600)
}

/// The join token goes into a Set-Cookie header; a token outside the
/// cookie-octet set is refused instead of being written as an injection.
pub fn to_response_rejects_a_token_that_is_not_a_cookie_value_test() {
  let page =
    ssr.RenderedPage(..render(test_config()), sign_join_token: fn(_) {
      "tok; Domain=evil.example"
    })
  let assert Error(cookie.InvalidValue(_)) = ssr.to_response(page)
  let req =
    request.new() |> request.set_header("cookie", "beacon_session=session-a")
  let assert Error(cookie.InvalidValue(_)) =
    ssr.to_response_for_request(page, req)
}

pub fn join_tokens_are_valid_cookie_values_test() {
  let page = render(test_config())
  let assert Ok(Nil) =
    cookie.validate(
      ssr.session_cookie_name,
      ssr.join_token_for(page, ""),
      cookie.default_options(),
    )
  let assert Ok(Nil) =
    cookie.validate(
      ssr.session_cookie_name,
      ssr.join_token_for(page, ssr.fingerprint_session_id("session-a")),
      cookie.default_options(),
    )
}

pub fn to_response_returns_200_test() {
  let page = render(test_config())
  let assert Ok(resp) = ssr.to_response(page)
  let assert 200 = resp.status
}

pub fn to_response_sets_httponly_session_cookie_test() {
  let page = render(test_config())
  let assert Ok(resp) = ssr.to_response(page)
  let assert Ok(cookie_header) = find_header(resp.headers, "set-cookie")
  let assert True = str_contains(cookie_header, ssr.session_cookie_name <> "=")
  let assert True = str_contains(cookie_header, "HttpOnly")
  let assert True = str_contains(cookie_header, "SameSite=Lax")
  let assert True = str_contains(cookie_header, "Max-Age=86400")
}

// --- Join token (v2) tests: unhappy paths first ---

const join_secret = "join-token-secret-key-at-least-32-chars"

fn signed_join_token(fingerprint: String, model: option.Option(String)) {
  ssr.sign_join_token(
    join_secret,
    fingerprint,
    model,
    current_system_time_seconds(),
  )
}

pub fn join_token_rejects_empty_server_secret_test() {
  let token = signed_join_token("", option.Some("{}"))
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(token, "", "", current_system_time_seconds())
}

pub fn join_token_signed_with_empty_secret_never_verifies_test() {
  let token =
    ssr.sign_join_token(
      "",
      "",
      option.Some("{}"),
      current_system_time_seconds(),
    )
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(token, "", "", current_system_time_seconds())
}

pub fn join_token_rejects_empty_token_test() {
  let assert Error(ssr.JoinTokenMalformed(_)) =
    ssr.verify_join_token("", join_secret, "", current_system_time_seconds())
}

pub fn join_token_rejects_garbage_test() {
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(
      "not.a.token",
      join_secret,
      "",
      current_system_time_seconds(),
    )
}

pub fn join_token_rejects_tampered_token_test() {
  let token = signed_join_token("", option.Some("{\"count\":1}"))
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(
      token <> "x",
      join_secret,
      "",
      current_system_time_seconds(),
    )
}

pub fn join_token_rejects_other_secret_test() {
  let token = signed_join_token("", option.Some("{}"))
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(
      token,
      "a-completely-different-secret-key-0123",
      "",
      current_system_time_seconds(),
    )
}

pub fn create_session_token_is_unbound_join_token_without_model_test() {
  // The v1 API mints a join token that carries no model and no session
  // binding, so it can never restore state or cross sessions.
  let session_token = ssr.create_session_token(join_secret)
  let assert Ok(ssr.JoinToken(model_json: option.None, ..)) =
    ssr.verify_join_token(
      session_token,
      join_secret,
      "",
      current_system_time_seconds(),
    )
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(
      session_token,
      join_secret,
      ssr.fingerprint_session_id("session-a"),
      current_system_time_seconds(),
    )
}

pub fn join_token_rejects_wrong_purpose_test() {
  let token =
    sign_raw_join_payload(
      json.object([
        #("v", json.int(2)),
        #("purpose", json.string("beacon.other")),
        #("iat", json.int(current_system_time_seconds())),
        #("exp", json.int(current_system_time_seconds() + 60)),
        #("sid", json.string("")),
        #("model", json.null()),
      ]),
    )
  let assert Error(ssr.JoinTokenInvalid(reason)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
  let assert True = str_contains(reason, "purpose")
}

pub fn join_token_rejects_wrong_version_test() {
  let token =
    sign_raw_join_payload(
      json.object([
        #("v", json.int(1)),
        #("purpose", json.string("beacon.join")),
        #("iat", json.int(current_system_time_seconds())),
        #("exp", json.int(current_system_time_seconds() + 60)),
        #("sid", json.string("")),
        #("model", json.null()),
      ]),
    )
  let assert Error(ssr.JoinTokenInvalid(reason)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
  let assert True = str_contains(reason, "version")
}

pub fn join_token_rejects_oversized_validity_window_test() {
  // A forged-looking window longer than the lifetime is refused even when
  // the signature is valid.
  let now = current_system_time_seconds()
  let token =
    sign_raw_join_payload(
      json.object([
        #("v", json.int(2)),
        #("purpose", json.string("beacon.join")),
        #("iat", json.int(now)),
        #("exp", json.int(now + ssr.join_token_lifetime_seconds + 1)),
        #("sid", json.string("")),
        #("model", json.null()),
      ]),
    )
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(token, join_secret, "", now)
}

pub fn join_token_rejects_missing_fields_test() {
  let token = sign_raw_join_payload(json.object([#("v", json.int(2))]))
  let assert Error(ssr.JoinTokenMalformed(_)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

pub fn join_token_rejects_future_issue_time_test() {
  let now = current_system_time_seconds()
  let token = ssr.sign_join_token(join_secret, "", option.None, now + 3600)
  let assert Error(ssr.JoinTokenInvalid(_)) =
    ssr.verify_join_token(token, join_secret, "", now)
}

pub fn join_token_rejects_expired_token_test() {
  let now = current_system_time_seconds()
  let issued_at = now - ssr.join_token_lifetime_seconds
  let token = ssr.sign_join_token(join_secret, "", option.None, issued_at)
  let assert Error(ssr.JoinTokenExpired(expired_at:, now: checked_at)) =
    ssr.verify_join_token(token, join_secret, "", now)
  let assert True = expired_at == now
  let assert True = checked_at == now
}

pub fn join_token_rejects_other_session_test() {
  let token =
    signed_join_token(ssr.fingerprint_session_id("session-a"), option.None)
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(
      token,
      join_secret,
      ssr.fingerprint_session_id("session-b"),
      current_system_time_seconds(),
    )
}

pub fn join_token_bound_token_rejects_unbound_connection_test() {
  let token =
    signed_join_token(ssr.fingerprint_session_id("session-a"), option.None)
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

pub fn join_token_unbound_token_rejects_bound_connection_test() {
  let token = signed_join_token("", option.None)
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(
      token,
      join_secret,
      ssr.fingerprint_session_id("session-a"),
      current_system_time_seconds(),
    )
}

pub fn join_token_round_trips_model_and_window_test() {
  let now = current_system_time_seconds()
  let fingerprint = ssr.fingerprint_session_id("session-a")
  let token =
    ssr.sign_join_token(join_secret, fingerprint, option.Some("{\"n\":1}"), now)
  let assert Ok(ssr.JoinToken(issued_at:, expires_at:, model_json:)) =
    ssr.verify_join_token(token, join_secret, fingerprint, now)
  let assert True = issued_at == now
  let assert True = expires_at == now + ssr.join_token_lifetime_seconds
  let assert option.Some("{\"n\":1}") = model_json
}

pub fn join_token_round_trips_without_model_test() {
  let token = signed_join_token("", option.None)
  let assert Ok(ssr.JoinToken(model_json: option.None, ..)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

pub fn session_identity_cookie_matches_auth_default_test() {
  let assert True =
    ssr.session_identity_cookie_name == auth.default_session_cookie_name
}

pub fn fingerprint_matches_session_binding_fingerprint_test() {
  let assert True =
    ssr.fingerprint_session_id("abc") == session.binding_fingerprint("abc")
  // The raw session id never appears in the fingerprint.
  let assert False = str_contains(ssr.fingerprint_session_id("abc"), "abc")
}

pub fn session_fingerprint_is_empty_without_session_cookie_test() {
  let assert "" = ssr.session_fingerprint(request.new())
  let assert "" =
    ssr.session_fingerprint(
      request.new() |> request.set_header("cookie", "beacon_session="),
    )
}

pub fn session_fingerprint_reads_session_cookie_test() {
  let req =
    request.new()
    |> request.set_header("cookie", "other=1; beacon_session=session-a")
  let assert True =
    ssr.session_fingerprint(req) == ssr.fingerprint_session_id("session-a")
}

pub fn to_response_for_request_binds_token_to_session_test() {
  let config =
    ssr.SsrConfig(
      ..test_config(),
      secret_key: join_secret,
      recovery_encoder: option.Some(fn(m: TestModel) {
        "{\"name\":\"" <> m.name <> "\"}"
      }),
    )
  let page = render(config)
  let req =
    request.new() |> request.set_header("cookie", "beacon_session=session-a")
  let assert Ok(resp) = ssr.to_response_for_request(page, req)
  let assert Ok(set_cookie) = find_header(resp.headers, "set-cookie")
  let token = cookie_value(set_cookie, ssr.session_cookie_name)
  let now = current_system_time_seconds()
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(token, join_secret, "", now)
  let assert Ok(ssr.JoinToken(model_json: option.Some(model_json), ..)) =
    ssr.verify_join_token(
      token,
      join_secret,
      ssr.fingerprint_session_id("session-a"),
      now,
    )
  let assert "{\"name\":\"World\"}" = model_json
}

pub fn join_token_omits_model_over_cookie_budget_test() {
  let big = string.repeat("x", 5000)
  let config =
    ssr.SsrConfig(
      ..test_config(),
      secret_key: join_secret,
      recovery_encoder: option.Some(fn(_m: TestModel) { "\"" <> big <> "\"" }),
    )
  let token = ssr.join_token_for(render(config), "")
  let assert True = string_length(token) <= 3800
  let assert Ok(ssr.JoinToken(model_json: option.None, ..)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

pub fn join_token_carries_no_model_without_serializer_test() {
  let config = ssr.SsrConfig(..test_config(), secret_key: join_secret)
  let token = ssr.join_token_for(render(config), "")
  let assert Ok(ssr.JoinToken(model_json: option.None, ..)) =
    ssr.verify_join_token(token, join_secret, "", current_system_time_seconds())
}

/// Sign an arbitrary payload with the join-token key derivation, to build
/// tokens the public signer refuses to produce.
fn sign_raw_join_payload(payload: json.Json) -> String {
  let key =
    crypto.hmac(
      bit_array.from_string("beacon.join_token.v2"),
      crypto.Sha256,
      bit_array.from_string(join_secret),
    )
  crypto.sign_message(
    bit_array.from_string(json.to_string(payload)),
    key,
    crypto.Sha256,
  )
}

fn cookie_value(set_cookie: String, name: String) -> String {
  let assert Ok(#(_, rest)) = string.split_once(set_cookie, name <> "=")
  case string.split_once(rest, ";") {
    Ok(#(value, _)) -> value
    Error(Nil) -> rest
  }
}

// --- Helpers ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

fn does_not_contain(haystack: String, needle: String) -> Bool {
  case do_str_contains(haystack, needle) {
    True -> False
    False -> True
  }
}

fn find_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(key, value), ..rest] ->
      case key == name {
        True -> Ok(value)
        False -> find_header(rest, name)
      }
  }
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool

fn string_length(s: String) -> Int {
  do_string_length(s)
}

@external(erlang, "erlang", "byte_size")
fn do_string_length(s: String) -> Int

fn string_index_of(haystack: String, needle: String) -> Result(Int, Nil) {
  do_string_index_of(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_index_of")
fn do_string_index_of(haystack: String, needle: String) -> Result(Int, Nil)

@external(erlang, "beacon_test_ffi", "system_time_seconds")
fn current_system_time_seconds() -> Int
