/// The client bundle the server loads at startup, and the dev build that
/// tells a page from before a `brazier/dev` rebuild to reload when it joins.
///
/// Both are VM-wide (`brazier_bundle_manifest_ffi`), so every test that
/// changes them runs on a fresh peer node and never touches this VM's
/// state. The checks of a given value run here. Unhappy paths first.
import brazier/cluster/peer.{Timeout}
import brazier/effect
import brazier/error
import brazier/html
import brazier/internal/stream_window
import brazier/log_capture
import brazier/pubsub
import brazier/raw_ws.{type RawSocket}
import brazier/ssr
import brazier/transport
import brazier/transport/server
import brazier/transport/ws
import gleam/bit_array
import gleam/crypto
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

// --- Harness ---

type Observed {
  Connected(conn_id: String)
  GotEvent(conn_id: String, msg: transport.ClientMessage)
  ClosedConn(conn_id: String)
}

@external(erlang, "brazier_dev_build_test_ffi", "set_cwd")
fn set_cwd(dir: String) -> Result(Nil, String)

@external(erlang, "brazier_dev_ffi", "enable_live_reload")
fn enable_live_reload() -> Nil

@external(erlang, "brazier_dev_ffi", "notify_browser_reload")
fn notify_browser_reload() -> Result(Int, String)

@external(erlang, "brazier_http_client_ffi", "start_httpc")
fn start_httpc() -> Nil

@external(erlang, "brazier_http_client_ffi", "http_get")
fn http_get(
  url: String,
) -> Result(#(Int, List(#(String, String)), String), String)

fn transport_config(observer: Subject(Observed)) -> transport.TransportConfig {
  transport.TransportConfig(
    port: 0,
    on_connect: fn(_, _) { Nil },
    on_event: fn(_, _) { Nil },
    on_disconnect: fn(_) { Nil },
    page_html: None,
    middlewares: [],
    static_config: None,
    runtime_factory: Some(fn(conn_id, _runtime, _req) {
      process.send(observer, Connected(conn_id))
      Ok(
        #(fn(cid, msg) { process.send(observer, GotEvent(cid, msg)) }, fn(cid) {
          process.send(observer, ClosedConn(cid))
        }),
      )
    }),
    ws_auth: None,
    ssr_factory: None,
    security_limits: transport.default_security_limits(),
    api_handler: None,
  )
}

fn start_server() -> #(server.Listener, Int, Subject(Observed)) {
  let observer = process.new_subject()
  let assert Ok(listener) = transport.start_listener(transport_config(observer))
    as "the test listener must start"
  #(listener, server.get_port(listener), observer)
}

fn open(port: Int, observer: Subject(Observed)) -> #(RawSocket, String) {
  let socket = raw_ws.open(port, "%2F", [])
  let assert Ok(Connected(conn_id)) = process.receive(observer, 3000)
    as "the runtime factory must be called"
  #(socket, conn_id)
}

fn join_text(
  path: String,
  build: Option(String),
  dev: Option(String),
) -> String {
  let field = fn(name, value) {
    case value {
      Some(id) -> ",\"" <> name <> "\":\"" <> id <> "\""
      None -> ""
    }
  }
  "{\"type\":\"join\",\"token\":\"\",\"path\":\""
  <> path
  <> "\""
  <> field("build", build)
  <> field("dev_build", dev)
  <> "}"
}

/// The next message the runtime factory's callbacks reported.
fn next_observed(observer: Subject(Observed)) -> Observed {
  let assert Ok(observed) = process.receive(observer, 3000)
    as "the server must report the connection's next step"
  observed
}

const bundle_a = "brazier_client_0123456789abcdef.js"

const bundle_b = "brazier_client_fedcba9876543210.js"

/// A fresh scratch project root with an empty `priv/static`, made the
/// node's working directory. Only called on a peer.
fn scratch_project() -> String {
  let root =
    "/tmp/brazier_dev_build_"
    <> bit_array.base16_encode(crypto.strong_random_bytes(16))
  let assert Ok(Nil) = simplifile.create_directory(root)
    as "the scratch root must not exist yet"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/priv/static")
  let assert Ok(Nil) = set_cwd(root) as "the peer must enter the scratch root"
  root
}

/// Build `bundle` into the scratch project: the bundle file, then the
/// manifest naming it, as `brazier/build` writes them.
fn build_bundle(root: String, bundle: String) -> Nil {
  let static = root <> "/priv/static/"
  let assert Ok(Nil) = simplifile.write(static <> bundle, "start(App);")
  let assert Ok(Nil) =
    simplifile.write(static <> "brazier_client.manifest", bundle <> "\n")
  Nil
}

fn remove_scratch(root: String) -> Nil {
  let assert Ok(Nil) = simplifile.delete(root) as "scratch root cleanup"
  Nil
}

pub type Model {
  Model
}

fn ssr_config() -> ssr.SsrConfig(Model, Nil) {
  ssr.SsrConfig(
    init: fn(_ctx) { Ok(#(Model, effect.none())) },
    update: fn(model, _msg) { #(model, effect.none()) },
    route: None,
    view: fn(_model) { html.div([], [html.text("page")]) },
    title: fn(_model) { "Dev build" },
    secret_key: "test-secret-key-at-least-32-chars-long!!",
    head_html: None,
    dev_mode: True,
    recovery_encoder: None,
    stream_limits: stream_window.default_limits(),
  )
}

// --- The stale-build close code ---

pub fn the_stale_build_close_is_the_reserved_init_status_test() {
  // An init refusal closes with 4000 + its status; 499 is the one status
  // `error.refuse` rejects, so no init refusal can share the stale build's
  // code.
  let assert 4499 = ws.close_stale_build
  let assert True =
    error.init_close_code_base + error.reserved_status == ws.close_stale_build
}

pub fn an_init_409_is_not_the_stale_build_close_test() {
  let assert 4409 = error.init_close_code(error.refuse(409, "conflict"))
  let assert True = 4409 != ws.close_stale_build
}

pub fn refuse_crashes_on_the_reserved_status_test() {
  // A 499 refusal would close with the stale-build code, and the page would
  // reload as if it were from an older build.
  let #(rescued, logs) =
    log_capture.capture(fn() { rescue(fn() { error.refuse(499, "gone") }) })
  let assert Error(#("error", _)) = rescued
  let assert True =
    log_capture.has(logs, level: "error", containing: ["499", "stale-build"])
  // Its neighbours are ordinary refusals.
  let assert 4498 = error.init_close_code(error.refuse(498, "token"))
  let assert 4500 = error.init_close_code(error.refuse(500, "broken"))
}

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, dynamic.Dynamic))

// --- check_join_dev_build ---

pub fn another_dev_build_is_told_to_reload_test() {
  let #(verdict, logs) =
    log_capture.capture(fn() {
      transport.check_join_dev_build(Some("aaaa"), "conn-a", Some("bbbb"))
    })
  let assert Error(Nil) = verdict
  let assert True =
    log_capture.has(logs, level: "info", containing: [
      "conn-a", "\"bbbb\"", "aaaa", "reload",
    ])
}

pub fn an_overlong_dev_build_is_logged_truncated_test() {
  let long = string.repeat("b", 10_000)
  let #(verdict, logs) =
    log_capture.capture(fn() {
      transport.check_join_dev_build(Some("aaaa"), "conn-b", Some(long))
    })
  let assert Error(Nil) = verdict
  let assert True =
    log_capture.has(logs, level: "info", containing: [
      "\"" <> string.repeat("b", 64) <> "\"",
    ])
  let assert False =
    log_capture.has(logs, level: "info", containing: [string.repeat("b", 65)])
}

pub fn the_current_dev_build_is_accepted_test() {
  let assert Ok(Nil) =
    transport.check_join_dev_build(Some("aaaa"), "conn-c", Some("aaaa"))
}

pub fn a_missing_dev_build_on_either_side_is_not_checked_test() {
  // Outside dev mode the server has none; a page rendered by a server
  // outside dev mode has none.
  let #(verdicts, logs) =
    log_capture.capture(fn() {
      [
        transport.check_join_dev_build(Some("aaaa"), "conn-d", None),
        transport.check_join_dev_build(None, "conn-d", Some("bbbb")),
        transport.check_join_dev_build(None, "conn-d", None),
      ]
    })
  let assert [Ok(Nil), Ok(Nil), Ok(Nil)] = verdicts
  let assert True =
    log_capture.has(logs, level: "debug", containing: ["conn-d", "no dev build"])
  let assert True =
    log_capture.has(logs, level: "debug", containing: [
      "conn-d", "not in dev mode",
    ])
}

pub fn outside_dev_mode_a_page_carries_no_dev_build_test() {
  let assert None = ssr.dev_build()
  let assert Ok(_) = ssr.load_client_bundle()
    as "the repository's priv/static must hold a built runtime bundle"
  let page = ssr.render_page(ssr_config(), request.new())
  let assert 200 = page.status
  let assert False = string.contains(page.html, "data-brazier-dev-build")
}

// --- The bundle is loaded at startup, on a fresh peer ---

pub fn a_listener_without_a_client_bundle_fails_to_start_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_dev_build_no_bundle")
  let assert [node] = peers
  let #(started, loaded) =
    peer.on(node, fn() {
      let root = scratch_project()
      let started =
        transport.start_listener(transport_config(process.new_subject()))
      let loaded = ssr.client_bundle()
      remove_scratch(root)
      #(started, loaded)
    })
  let assert Error(error.ConfigError(reason:)) = started
  let assert True = string.starts_with(reason, "No client bundle: ")
  let assert True =
    string.contains(reason, "priv/static/brazier_client.manifest")
  // The failed read is what a render or a join sees: no bundle.
  let assert Error(_) = loaded
  Nil
}

pub fn the_bundle_is_read_once_and_again_only_on_a_load_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_dev_build_reload")
  let assert [node] = peers
  let #(before_load, first, after_rebuild, second, after_break, broken) =
    peer.on(node, fn() {
      let root = scratch_project()
      build_bundle(root, bundle_a)
      let before_load = ssr.client_bundle()
      let first = ssr.load_client_bundle()
      // A rebuild on disk is not seen until the next load.
      build_bundle(root, bundle_b)
      let after_rebuild = ssr.client_bundle()
      let second = ssr.load_client_bundle()
      let assert Ok(Nil) =
        simplifile.delete(root <> "/priv/static/brazier_client.manifest")
      let after_break = ssr.client_bundle()
      let broken = ssr.load_client_bundle()
      let result = #(
        before_load,
        first,
        after_rebuild,
        second,
        after_break,
        #(broken, ssr.client_bundle()),
      )
      remove_scratch(root)
      result
    })
  let assert Error(not_loaded) = before_load
  let assert True = string.contains(not_loaded, "no client bundle was loaded")
  let assert Ok(name) = first
  assert name == bundle_a
  let assert Ok(name) = after_rebuild
  assert name == bundle_a
  let assert Ok(name) = second
  assert name == bundle_b
  let assert Ok(name) = after_break
  assert name == bundle_b
  // A failed load replaces the loaded bundle: a render or join after it
  // does not serve a bundle the manifest no longer names.
  let assert #(Error(reason), Error(stored)) = broken
  assert reason == stored
  let assert True = string.contains(reason, "brazier_client.manifest")
  Nil
}

pub fn a_join_after_a_failed_load_closes_1011_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_dev_build_failed_load")
  let assert [node] = peers
  let #(frame, closed) =
    peer.on(node, fn() {
      let root = scratch_project()
      build_bundle(root, bundle_a)
      let #(listener, port, observer) = start_server()
      // A dev rebuild that left no manifest.
      let assert Ok(Nil) =
        simplifile.delete(root <> "/priv/static/brazier_client.manifest")
      let assert Error(_) = ssr.load_client_bundle()
      let #(socket, _conn_id) = open(port, observer)
      raw_ws.send_text(socket, join_text("/", Some("0123456789abcdef"), None))
      let frame = raw_ws.recv(socket)
      let closed = next_observed(observer)
      raw_ws.close(socket)
      server.stop(listener)
      remove_scratch(root)
      #(frame, closed)
    })
  let assert raw_ws.Close(code: 1011, reason: "internal error") = frame
  let assert ClosedConn(_) = closed
  Nil
}

// --- The dev build, on a fresh peer ---

pub fn a_page_between_sockets_during_a_rebuild_reloads_on_its_join_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_dev_build_between")
  let assert [node] = peers
  let #(first_join, reload, after_reload) =
    peer.on(node, fn() {
      pubsub.start()
      enable_live_reload()
      let #(listener, port, observer) = start_server()
      let rendered_under = ssr.new_dev_build()
      // The page's first socket joins under the dev build it was rendered
      // under, then drops (the page is reconnecting).
      let #(first, _) = open(port, observer)
      raw_ws.send_text(first, join_text("/", None, Some(rendered_under)))
      let first_join = next_observed(observer)
      raw_ws.close(first)
      let assert ClosedConn(_) = next_observed(observer)
      // The rebuild: a new dev build, then the broadcast, which reaches no
      // socket of this page.
      let rebuilt = ssr.new_dev_build()
      let assert Ok(_) = notify_browser_reload()
      // The page reconnects: its join from before the rebuild is answered
      // with a reload and never reaches the runtime. A join under the new
      // dev build on the same socket is.
      let #(second, _) = open(port, observer)
      raw_ws.send_text(second, join_text("/stale", None, Some(rendered_under)))
      let reload = raw_ws.recv(second)
      raw_ws.send_text(second, join_text("/", None, Some(rebuilt)))
      let after_reload = next_observed(observer)
      raw_ws.close(second)
      server.stop(listener)
      #(first_join, reload, after_reload)
    })
  let assert GotEvent(_, transport.ClientJoin(token: "", path: "/")) =
    first_join
  let assert raw_ws.Text("{\"type\":\"reload\"}") = reload
  let assert GotEvent(_, transport.ClientJoin(token: "", path: "/")) =
    after_reload
  Nil
}

pub fn pages_carry_the_current_dev_build_test_() -> peer.Timeout {
  use <- Timeout(60)
  use peers <- peer.with_cluster(1, "brazier_dev_build_pages")
  let assert [node] = peers
  let #(dev_build, ssr_html, default_page) =
    peer.on(node, fn() {
      start_httpc()
      let #(listener, port, _observer) = start_server()
      let _first = ssr.new_dev_build()
      let dev_build = ssr.new_dev_build()
      let assert Some(current) = ssr.dev_build()
      assert current == dev_build
      let page = ssr.render_page(ssr_config(), request.new())
      let assert 200 = page.status
      let assert Ok(#(200, _headers, default_page)) =
        http_get("http://127.0.0.1:" <> int.to_string(port) <> "/")
      server.stop(listener)
      #(dev_build, page.html, default_page)
    })
  let attribute = "data-brazier-dev-build=\"" <> dev_build <> "\""
  let assert True = string.contains(ssr_html, attribute)
  let assert True = string.contains(default_page, attribute)
  // The id is 16 hex characters, so it needs no escaping.
  let assert 16 = string.length(dev_build)
  Nil
}
