import brazier/error
import gleam/dynamic

pub fn transport_error_to_string_test() {
  let err = error.TransportError("connection refused")
  let result = error.to_string(err)
  let assert "TransportError: connection refused" = result
}

pub fn codec_error_to_string_test() {
  let err = error.CodecError("invalid JSON", "{bad")
  let result = error.to_string(err)
  let assert "CodecError: invalid JSON (raw: {bad)" = result
}

pub fn runtime_error_to_string_test() {
  let err = error.RuntimeError("update function panicked")
  let result = error.to_string(err)
  let assert "RuntimeError: update function panicked" = result
}

pub fn diff_error_to_string_test() {
  let err = error.DiffError("mismatched tree depth")
  let result = error.to_string(err)
  let assert "DiffError: mismatched tree depth" = result
}

pub fn render_error_to_string_test() {
  let err = error.RenderError("element_to_string failed")
  let result = error.to_string(err)
  let assert "RenderError: element_to_string failed" = result
}

pub fn route_error_to_string_test() {
  let err = error.RouteError("no route matched /unknown")
  let result = error.to_string(err)
  let assert "RouteError: no route matched /unknown" = result
}

pub fn effect_error_to_string_test() {
  let err = error.EffectError("side effect timed out")
  let result = error.to_string(err)
  let assert "EffectError: side effect timed out" = result
}

pub fn session_error_to_string_test() {
  let err = error.SessionError("token expired")
  let result = error.to_string(err)
  let assert "SessionError: token expired" = result
}

pub fn config_error_to_string_test() {
  let err = error.ConfigError("missing SECRET_KEY")
  let result = error.to_string(err)
  let assert "ConfigError: missing SECRET_KEY" = result
}

// --- InitError ---

pub fn unavailable_is_a_503_closing_with_4503_test() {
  let refusal = error.unavailable("orders database down")
  let assert 503 = error.init_error_status(refusal)
  let assert "orders database down" = error.init_error_reason(refusal)
  let assert 4503 = error.init_close_code(refusal)
  let assert "503: orders database down" = error.init_error_to_string(refusal)
  let assert "InitRejected: 503: orders database down" =
    error.to_string(error.InitRejected(refusal))
}

pub fn refuse_keeps_a_client_or_server_status_test() {
  let assert 4404 = error.init_close_code(error.refuse(404, "no such board"))
  let assert 4401 = error.init_close_code(error.refuse(401, "signed out"))
  let assert 400 = error.init_error_status(error.refuse(400, "bad"))
  let assert 599 = error.init_error_status(error.refuse(599, "edge"))
}

pub fn refuse_crashes_on_a_status_that_is_not_an_error_test() {
  // A 200 or 302 "refusal" is a bug in the app: it crashes, and a crash in
  // init is answered with 500 or close 1011.
  let assert Error(#("error", _)) = rescue(fn() { error.refuse(200, "ok?") })
  let assert Error(#("error", _)) = rescue(fn() { error.refuse(302, "move") })
  let assert Error(#("error", _)) = rescue(fn() { error.refuse(399, "low") })
  let assert Error(#("error", _)) = rescue(fn() { error.refuse(600, "high") })
}

@external(erlang, "brazier_telemetry_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, #(String, dynamic.Dynamic))
