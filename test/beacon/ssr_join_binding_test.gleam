/// The real server binds the SSR join token to the request's session
/// cookie (`ssr.to_response_for_request`), so a token minted for one browser
/// session does not verify for another. Real HTTP over a real socket.
import beacon/app_config_fixture
import beacon/application
import beacon/effect
import beacon/error
import beacon/html
import beacon/ssr
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string

const secret = "ssr-join-binding-test-secret-key-0123456789"

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Inc
}

fn config() -> application.AppConfig(Model, Msg) {
  application.AppConfig(
    ..app_config_fixture.new(
      port: 0,
      init: fn(_ctx) { Ok(#(Model(count: 0), effect.none())) },
      update: fn(model: Model, _msg) {
        #(Model(count: model.count + 1), effect.none())
      },
      view: fn(model: Model) {
        html.div([], [html.text(int.to_string(model.count))])
      },
      encode_model: fn(model: Model) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      },
      decode_event: fn(_name, _handler_id, _data, _path) {
        Error(error.RuntimeError(reason: "no events"))
      },
    ),
    secret_key: secret,
    middlewares: [],
  )
}

pub fn served_join_token_is_bound_to_the_session_cookie_test() {
  let assert Ok(app) = application.start(config())
  let url = "http://localhost:" <> int.to_string(app.port) <> "/"
  let now = system_time_seconds()

  let assert Ok(#(200, headers, _body)) =
    http_request("GET", url, [#("cookie", "beacon_session=session-a")], "")
  let token = join_token(headers)
  let assert Ok(_) =
    ssr.verify_join_token(
      token,
      secret,
      ssr.fingerprint_session_id("session-a"),
      now,
    )
  // The same token presented under another session, or none, is refused.
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(
      token,
      secret,
      ssr.fingerprint_session_id("session-b"),
      now,
    )
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(token, secret, "", now)
  stop(app)
}

pub fn served_join_token_without_a_session_is_unbound_test() {
  let assert Ok(app) = application.start(config())
  let url = "http://localhost:" <> int.to_string(app.port) <> "/"
  let now = system_time_seconds()

  let assert Ok(#(200, headers, _body)) = http_request("GET", url, [], "")
  let token = join_token(headers)
  let assert Ok(_) = ssr.verify_join_token(token, secret, "", now)
  let assert Error(ssr.JoinTokenSessionMismatch) =
    ssr.verify_join_token(
      token,
      secret,
      ssr.fingerprint_session_id("session-a"),
      now,
    )
  stop(app)
}

// --- helpers ---

fn join_token(headers: List(#(String, String))) -> String {
  let prefix = ssr.session_cookie_name <> "="
  let assert Ok(#(_, set_cookie)) =
    list.find(headers, fn(h) {
      string.lowercase(h.0) == "set-cookie" && string.starts_with(h.1, prefix)
    })
    as "the SSR page sets the join cookie"
  let assert Ok(#(_, rest)) = string.split_once(set_cookie, prefix)
    as "the join cookie has a value"
  case string.split_once(rest, ";") {
    Ok(#(value, _)) -> value
    Error(Nil) -> rest
  }
}

fn stop(app: application.App) -> Nil {
  process.unlink(app.supervisor_pid)
  process.kill(app.supervisor_pid)
}

@external(erlang, "beacon_test_ffi", "system_time_seconds")
fn system_time_seconds() -> Int

@external(erlang, "beacon_http_client_ffi", "http_request")
fn http_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, List(#(String, String)), String), String)
