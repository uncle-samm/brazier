/// Beacon's error types module.
/// All errors carry enough context to diagnose failures without a debugger.
/// Per TigerBeetle approach: crash early with clear messages, never swallow errors.
import beacon/log
import gleam/int

/// Top-level error type for the Beacon framework.
/// Each variant carries contextual information about what went wrong and where.
pub type BeaconError {
  /// A WebSocket transport error occurred.
  TransportError(reason: String)

  /// Failed to encode or decode a message on the wire.
  CodecError(reason: String, raw: String)

  /// An error in the MVU runtime loop (init, update, or view).
  RuntimeError(reason: String)

  /// An error in the VDOM diff engine.
  DiffError(reason: String)

  /// An error during server-side rendering.
  RenderError(reason: String)

  /// A route matching or code generation error.
  RouteError(reason: String)

  /// An effect failed to execute.
  EffectError(reason: String)

  /// Session-related error (token expired, state not found, etc).
  SessionError(reason: String)

  /// Configuration or initialization error.
  ConfigError(reason: String)

  /// The app's `init` refused to start the session (see `InitError`).
  InitRejected(error: InitError)
}

/// Why an app's `init` refused to start a session: the HTTP status the
/// server render answers with, and a reason for the server log.
///
/// The reason is never sent to the browser. The server render answers with
/// an error page for the status, and the WebSocket closes with
/// `init_close_code(status)`.
///
/// Build one with `unavailable` (503) or `refuse` (any 4xx or 5xx status).
/// A crash in `init` is not an `InitError`: it is answered with 500 on the
/// server render and closes the WebSocket with 1011.
///
/// Reference: a LiveView `mount` that raises during the dead render is
/// answered with 500, and Plug's `Plug.Exception` carries the status of an
/// error raised while handling a request.
pub opaque type InitError {
  InitError(status: Int, reason: String)
}

/// Lowest close code of an init refusal: the socket closes with this plus
/// the HTTP status (4503 for `unavailable`).
pub const init_close_code_base = 4000

/// Something `init` needs is down (a session store, a database): 503.
pub fn unavailable(reason: String) -> InitError {
  InitError(status: 503, reason: reason)
}

/// Refuse the session with an HTTP error status, for example 404 for a
/// record that does not exist or 403 for one the user may not see.
///
/// A status outside 400 to 599 is a programming error and crashes `init`
/// (answered as a crash: 500, or close 1011).
pub fn refuse(status: Int, reason: String) -> InitError {
  let valid = status >= 400 && status <= 599
  case valid {
    True -> Nil
    False ->
      log.error(
        "beacon.error",
        "init refused with status "
          <> int.to_string(status)
          <> ", which is not an HTTP error status (400 to 599): "
          <> reason,
      )
  }
  let assert True = valid as "error.refuse: the status must be 400 to 599"
  InitError(status: status, reason: reason)
}

/// The HTTP status the server render answers with.
pub fn init_error_status(error: InitError) -> Int {
  error.status
}

/// The reason `init` gave, for the server log only.
pub fn init_error_reason(error: InitError) -> String {
  error.reason
}

/// The WebSocket close code for an init refusal with `status`:
/// `init_close_code_base + status` (4503, 4404, ...). The browser reloads
/// the page on 4401 and reconnects with backoff on every other code.
pub fn init_close_code(error: InitError) -> Int {
  init_close_code_base + error.status
}

/// "<status>: <reason>", for logs.
pub fn init_error_to_string(error: InitError) -> String {
  int.to_string(error.status) <> ": " <> error.reason
}

/// Convert a BeaconError to a human-readable string for logging.
pub fn to_string(error: BeaconError) -> String {
  case error {
    TransportError(reason) -> "TransportError: " <> reason
    CodecError(reason, raw) ->
      "CodecError: " <> reason <> " (raw: " <> raw <> ")"
    RuntimeError(reason) -> "RuntimeError: " <> reason
    DiffError(reason) -> "DiffError: " <> reason
    RenderError(reason) -> "RenderError: " <> reason
    RouteError(reason) -> "RouteError: " <> reason
    EffectError(reason) -> "EffectError: " <> reason
    SessionError(reason) -> "SessionError: " <> reason
    ConfigError(reason) -> "ConfigError: " <> reason
    InitRejected(error) -> "InitRejected: " <> init_error_to_string(error)
  }
}
