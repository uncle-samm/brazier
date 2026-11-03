/// Auth helpers — login, logout, session-bound authentication.
/// Works with the session store and middleware context.
///
/// Every helper uses the session functions that return errors
/// (`session.try_create_with_data`, `session.try_delete`, `session.fetch`,
/// `session.rotate`), so an External backend failure is returned, not
/// raised:
/// - a missing, deleted or expired session is `InvalidSession`;
/// - a backend failure (or a write that lost every compare-and-swap race)
///   is `SessionStoreUnavailable`, logged as an error with its reason.
///   Request wrappers and middleware answer it with 503, WebSocket auth
///   rejects the socket, and `init_from_session` returns
///   `error.unavailable`, which the server render answers with 503 and the
///   WebSocket with close 4503. None of them treats the outage as a guest:
///   that would show a signed-in user a logged-out page and hide it.
import beacon/api
import beacon/cookie
import beacon/error.{type InitError}
import beacon/internal/context.{type Context}
import beacon/log
import beacon/middleware
import beacon/session
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bytes_tree
import gleam/dict
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json as json_builder
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub const default_session_cookie_name = "beacon_session"

pub const default_csrf_header_name = "x-csrf-token"

const user_id_key = "user_id"

const csrf_token_key = "csrf_token"

/// Session auth configuration.
pub type SessionConfig {
  SessionConfig(
    /// Cookie name that stores the opaque session ID.
    cookie_name: String,
    /// Header name used by state-changing API requests.
    csrf_header: String,
    /// Cookie attributes for login and logout responses.
    cookie_options: cookie.CookieOptions,
  )
}

/// Result returned after creating a login session.
pub type LoginSession {
  LoginSession(session: session.Session, csrf_token: String)
}

/// Why a helper that builds a login or logout response failed.
pub type ResponseError {
  /// The session cookie config is invalid; no session was created.
  CookieRejected(cookie.CookieError)
  /// The session store failed. Login: no session was created. Logout: the
  /// session may still exist, but its live sockets were told to close.
  StoreFailed(session.SessionStoreError)
}

/// Result returned after creating a login response.
pub type LoginResult {
  LoginResult(
    session: session.Session,
    csrf_token: String,
    response: Response(ResponseBody),
  )
}

/// Why a high-level auth helper rejected a request.
pub type SessionError {
  MissingSessionCookie
  InvalidSession
  MissingUser
  MissingCsrfToken
  InvalidCsrfToken
  /// The session store could not answer (an External backend failed). The
  /// reason is logged; it is not part of any client-facing text.
  SessionStoreUnavailable(reason: String)
}

/// Secure production defaults: HttpOnly, Secure, SameSite=Lax.
pub fn default_session_config() -> SessionConfig {
  SessionConfig(
    cookie_name: default_session_cookie_name,
    csrf_header: default_csrf_header_name,
    cookie_options: cookie.default_options(),
  )
}

/// Explicit local-development config.
///
/// This is intentionally named `dev_` because it disables the Secure cookie
/// attribute so localhost HTTP examples can receive the session cookie.
pub fn dev_session_config() -> SessionConfig {
  SessionConfig(
    cookie_name: default_session_cookie_name,
    csrf_header: default_csrf_header_name,
    cookie_options: cookie.CookieOptions(
      max_age: None,
      path: "/",
      http_only: True,
      secure: False,
      same_site: "Lax",
    ),
  )
}

/// Log in a user — creates a fresh session and stores the user ID.
///
/// Always issues a NEW session id. If the request already carried a session
/// (anonymous or another user's), use `login_rotating` so the old id is
/// deleted and cannot be replayed (session fixation).
pub fn login(
  store: session.SessionStore,
  user_id: String,
) -> Result(session.Session, SessionError) {
  use sess <- result.map(
    session.try_create_with_data(
      store,
      dict.from_list([#(user_id_key, user_id)]),
    )
    |> result.map_error(store_failure(_, "login")),
  )
  log.info("beacon.auth", "User logged in")
  sess
}

/// Log in a user, deleting the previous session id (if any).
///
/// Live WebSockets bound to the old session are told to close. When the old
/// session cannot be deleted no new one is created: logging in must never
/// leave a replayable previous id behind.
pub fn login_rotating(
  store: session.SessionStore,
  old_session_id: Option(String),
  user_id: String,
) -> Result(session.Session, SessionError) {
  use Nil <- result.try(
    delete_previous_session(store, old_session_id)
    |> result.map_error(store_failure(_, "login")),
  )
  login(store, user_id)
}

/// Create a login session and session-bound CSRF token.
pub fn create_login(
  store: session.SessionStore,
  user_id: String,
) -> Result(LoginSession, SessionError) {
  create_login_rotating(store, None, user_id)
}

/// Create a login session and CSRF token, deleting the previous session id.
/// As with `login_rotating`, a failed delete creates nothing.
pub fn create_login_rotating(
  store: session.SessionStore,
  old_session_id: Option(String),
  user_id: String,
) -> Result(LoginSession, SessionError) {
  start_login(store, old_session_id, user_id)
  |> result.map_error(store_failure(_, "login"))
}

/// Delete the previous session (if any), then create the new one.
fn start_login(
  store: session.SessionStore,
  old_session_id: Option(String),
  user_id: String,
) -> Result(LoginSession, session.SessionStoreError) {
  use Nil <- result.try(delete_previous_session(store, old_session_id))
  let csrf_token = session.generate_id()
  use sess <- result.map(session.try_create_with_data(
    store,
    dict.from_list([#(user_id_key, user_id), #(csrf_token_key, csrf_token)]),
  ))
  log.info("beacon.auth", "User logged in")
  LoginSession(session: sess, csrf_token: csrf_token)
}

fn delete_previous_session(
  store: session.SessionStore,
  old_session_id: Option(String),
) -> Result(Nil, session.SessionStoreError) {
  case old_session_id {
    Some(old_id) -> {
      log.info("beacon.auth", "Login replacing previous session")
      session.try_delete(store, old_id)
    }
    None -> Ok(Nil)
  }
}

/// Map a session store error to the auth error a caller sees. A session
/// that is gone is `InvalidSession`; anything else means the store could
/// not answer, which is logged as an error with the operation.
fn store_failure(
  err: session.SessionStoreError,
  operation: String,
) -> SessionError {
  case err {
    session.SessionNotFound | session.SessionExpired -> InvalidSession
    session.SessionContention
    | session.SessionBackendFailed(_)
    | session.InvalidBackend(_) -> {
      let reason = session.store_error_to_string(err)
      log.error(
        "beacon.auth",
        "Session store unavailable during " <> operation <> ": " <> reason,
      )
      SessionStoreUnavailable(reason)
    }
  }
}

/// Change privileges (role, permissions, impersonation) on a live session.
///
/// Rotates the session id, applies `updates` to the new session, and issues a
/// new CSRF token. The old id is deleted and every WebSocket bound to it is
/// closed. The caller MUST send the returned session's cookie
/// (`with_session_cookie`) and CSRF token to the client.
pub fn change_privileges(
  store: session.SessionStore,
  session_id: String,
  updates: List(#(String, String)),
) -> Result(LoginSession, SessionError) {
  case session.rotate(store, session_id) {
    Error(err) -> {
      log.warning(
        "beacon.auth",
        "Privilege change rejected: " <> session.store_error_to_string(err),
      )
      Error(store_failure(err, "privilege change"))
    }
    Ok(rotated) -> {
      let csrf_token = session.generate_id()
      let result =
        session.update(store, rotated.id, fn(data) {
          list.fold(updates, data, fn(acc, pair) {
            dict.insert(acc, pair.0, pair.1)
          })
          |> dict.insert(csrf_token_key, csrf_token)
        })
      case result {
        Ok(sess) -> {
          log.info("beacon.auth", "Session privileges changed (id rotated)")
          Ok(LoginSession(session: sess, csrf_token: csrf_token))
        }
        Error(err) -> {
          log.error(
            "beacon.auth",
            "Privilege update failed after rotation: "
              <> session.store_error_to_string(err),
          )
          Error(store_failure(err, "privilege change"))
        }
      }
    }
  }
}

/// Attach the configured HttpOnly session cookie to a response.
/// Errors when `config` names an invalid cookie (see `cookie.validate`).
pub fn with_session_cookie(
  resp: Response(ResponseBody),
  sess: session.Session,
  config: SessionConfig,
) -> Result(Response(ResponseBody), cookie.CookieError) {
  resp
  |> cookie.set(config.cookie_name, sess.id, config.cookie_options)
}

/// Refuse a session config whose cookie cannot be set, before a session is
/// created for it (so a bad config never leaves an orphan session).
fn check_session_cookie(config: SessionConfig) -> Result(Nil, ResponseError) {
  case cookie.validate_options(config.cookie_name, config.cookie_options) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      log.error(
        "beacon.auth",
        "Invalid session cookie config: " <> cookie.error_to_string(error),
      )
      Error(CookieRejected(error))
    }
  }
}

/// Create the login session for a response helper.
fn response_login(
  store: session.SessionStore,
  old_session_id: Option(String),
  user_id: String,
) -> Result(LoginSession, ResponseError) {
  start_login(store, old_session_id, user_id)
  |> result.map_error(fn(err) {
    log.error(
      "beacon.auth",
      "Login failed, session store unavailable: "
        <> session.store_error_to_string(err),
    )
    StoreFailed(err)
  })
}

/// Attach the session cookie for a response helper. The cookie config was
/// validated before the session was created, so this fails only if
/// `cookie.validate_options` and `cookie.set` disagree.
fn response_cookie(
  resp: Response(ResponseBody),
  login: LoginSession,
  config: SessionConfig,
) -> Result(LoginResult, ResponseError) {
  case with_session_cookie(resp, login.session, config) {
    Ok(resp) ->
      Ok(LoginResult(
        session: login.session,
        csrf_token: login.csrf_token,
        response: resp,
      ))
    Error(error) -> {
      log.error(
        "beacon.auth",
        "Session cookie rejected after login: " <> cookie.error_to_string(error),
      )
      Error(CookieRejected(error))
    }
  }
}

/// Log in a user and attach an HttpOnly session cookie to a response.
///
/// The returned CSRF token is stored in the server-side session and should be
/// sent by the app's client code in the configured CSRF header for
/// state-changing API requests.
pub fn login_response(
  store: session.SessionStore,
  user_id: String,
  resp: Response(ResponseBody),
  config: SessionConfig,
) -> Result(LoginResult, ResponseError) {
  use Nil <- result.try(check_session_cookie(config))
  use login <- result.try(response_login(store, None, user_id))
  response_cookie(resp, login, config)
}

/// Log in a user and return a standard JSON response.
///
/// The response body is `{"ok":true,"csrf":"..."}` and the session ID is
/// sent only as an HttpOnly cookie.
pub fn login_json_response(
  store: session.SessionStore,
  user_id: String,
  config: SessionConfig,
) -> Result(LoginResult, ResponseError) {
  login_json_response_rotating(store, None, user_id, config)
}

/// Like `login_json_response`, but deletes the previous session id first.
pub fn login_json_response_rotating(
  store: session.SessionStore,
  old_session_id: Option(String),
  user_id: String,
  config: SessionConfig,
) -> Result(LoginResult, ResponseError) {
  use Nil <- result.try(check_session_cookie(config))
  use login <- result.try(response_login(store, old_session_id, user_id))
  api.json_value(
    200,
    json_builder.object([
      #("ok", json_builder.bool(True)),
      #("csrf", json_builder.string(login.csrf_token)),
    ]),
  )
  |> response_cookie(login, config)
}

/// Log out — destroys the session. Its live sockets are told to close even
/// when the store fails (see `session.try_delete`); the error is returned.
pub fn logout(
  store: session.SessionStore,
  session_id: String,
) -> Result(Nil, SessionError) {
  use Nil <- result.map(
    session.try_delete(store, session_id)
    |> result.map_error(store_failure(_, "logout")),
  )
  log.info("beacon.auth", "Session logged out")
}

/// Destroy the session and attach a matching cookie deletion header.
/// The session is destroyed even when the cookie config is invalid (the
/// error is still returned). When the store fails no response is built:
/// clearing the cookie would tell the user they are logged out while the
/// session may still exist.
pub fn logout_response(
  store: session.SessionStore,
  sess: session.Session,
  resp: Response(ResponseBody),
  config: SessionConfig,
) -> Result(Response(ResponseBody), ResponseError) {
  use Nil <- result.try(case session.try_delete(store, sess.id) {
    Ok(Nil) -> {
      log.info("beacon.auth", "Session logged out")
      Ok(Nil)
    }
    Error(err) -> {
      log.error(
        "beacon.auth",
        "Logout failed, session store unavailable: "
          <> session.store_error_to_string(err),
      )
      Error(StoreFailed(err))
    }
  })
  resp
  |> cookie.delete_with_options(config.cookie_name, config.cookie_options)
  |> result.map_error(fn(error) {
    log.error(
      "beacon.auth",
      "Logout could not clear the session cookie: "
        <> cookie.error_to_string(error),
    )
    CookieRejected(error)
  })
}

/// Get the current user ID from a session.
pub fn current_user(sess: session.Session) -> Result(String, Nil) {
  case session.get_value(sess, user_id_key) {
    Some(user_id) -> Ok(user_id)
    None -> Error(Nil)
  }
}

/// Read the raw session id from the configured cookie.
///
/// Does NOT validate the session against a store; use `session_from_request`
/// for that. Intended for binding other credentials (e.g. the WebSocket join
/// token) to the session via `session.binding_fingerprint`.
pub fn session_id_from_request(
  req: Request(body),
  config: SessionConfig,
) -> Result(String, SessionError) {
  case session.id_from_request(req, config.cookie_name) {
    Ok(id) -> Ok(id)
    Error(Nil) -> Error(MissingSessionCookie)
  }
}

/// Get the current session from a request cookie.
pub fn session_from_request(
  req: Request(body),
  store: session.SessionStore,
  config: SessionConfig,
) -> Result(session.Session, SessionError) {
  use session_id <- result.try(session_id_from_request(req, config))
  session.fetch(store, session_id)
  |> result.map_error(store_failure(_, "session lookup"))
}

/// Get the current user ID from a request cookie.
pub fn current_user_from_request(
  req: Request(body),
  store: session.SessionStore,
  config: SessionConfig,
) -> Result(String, SessionError) {
  case session_from_request(req, store, config) {
    Ok(sess) -> {
      case current_user(sess) {
        Ok(user_id) -> Ok(user_id)
        Error(Nil) -> Error(MissingUser)
      }
    }
    Error(err) -> Error(err)
  }
}

/// Validate the session-bound CSRF header for a request.
pub fn validate_csrf(
  req: Request(body),
  sess: session.Session,
  config: SessionConfig,
) -> Result(Nil, SessionError) {
  case request.get_header(req, config.csrf_header) {
    Ok(token) -> {
      case session.get_value(sess, csrf_token_key) {
        Some(expected) ->
          case session.secure_compare(token, expected) {
            True -> Ok(Nil)
            False -> Error(InvalidCsrfToken)
          }
        None -> Error(MissingCsrfToken)
      }
    }
    Error(Nil) -> Error(MissingCsrfToken)
  }
}

/// WebSocket auth function that accepts only requests with a valid session user.
///
/// The transport runs `ws_auth` inside the WebSocket handler process, both
/// before the upgrade and periodically afterwards. On success this binds that
/// process to the session, so logout, rotation, or expiry of the session
/// closes the live socket immediately (see `session.bind_current_process`).
pub fn ws_session_auth(
  store: session.SessionStore,
  config: SessionConfig,
) -> fn(Request(Connection)) -> Result(Nil, String) {
  fn(req: Request(Connection)) {
    case session_from_request(req, store, config) {
      Ok(sess) ->
        case current_user(sess) {
          Ok(_user_id) -> {
            session.bind_current_process(store, sess.id)
            Ok(Nil)
          }
          Error(Nil) -> {
            log.warning(
              "beacon.auth",
              "WS auth rejected: " <> error_to_string(MissingUser),
            )
            Error(error_to_string(MissingUser))
          }
        }
      // Already logged as an error by store_failure.
      Error(SessionStoreUnavailable(_) as err) -> Error(error_to_string(err))
      Error(err) -> {
        log.warning("beacon.auth", "WS auth rejected: " <> error_to_string(err))
        Error(error_to_string(err))
      }
    }
  }
}

/// Alias for the common WebSocket protection hook.
pub fn protect_ws(
  store: session.SessionStore,
  config: SessionConfig,
) -> fn(Request(Connection)) -> Result(Nil, String) {
  ws_session_auth(store, config)
}

/// The session named by the Context's session cookie, for code that runs
/// in an app's `init`. The same outcomes as `session_from_request`.
pub fn session_from_context(
  ctx: Context,
  store: session.SessionStore,
  config: SessionConfig,
) -> Result(session.Session, SessionError) {
  use session_id <- result.try(case context.cookie(ctx, config.cookie_name) {
    Ok("") | Error(Nil) -> Error(MissingSessionCookie)
    Ok(id) -> Ok(id)
  })
  session.fetch(store, session_id)
  |> result.map_error(store_failure(_, "session lookup"))
}

/// An `init` for apps whose first state depends on who is signed in. Pass
/// it as a constructor's `init`, so the server render already shows the
/// signed-in page.
///
/// - A live session with a user runs `authenticated_init(ctx, session,
///   user_id)`.
/// - No session cookie runs `guest_init(ctx)`.
/// - A cookie naming no live session (logged out, expired, rotated) and a
///   session without a user are logged as warnings and run `guest_init`.
/// - A session store that cannot answer is not a guest: the session cannot
///   be verified either way. It returns `error.unavailable`, so the server
///   render answers 503 and the WebSocket closes with 4503 (the browser
///   reconnects with backoff). The store's reason is logged and never sent
///   to the browser.
pub fn init_from_session(
  store: session.SessionStore,
  config: SessionConfig,
  guest_init guest_init: fn(Context) -> Result(model, InitError),
  authenticated_init authenticated_init: fn(Context, session.Session, String) ->
    Result(model, InitError),
) -> fn(Context) -> Result(model, InitError) {
  fn(ctx: Context) {
    // The lookup is spelled out rather than calling `session_from_context`,
    // so every case is one of the store's outcomes: a lookup never checks a
    // CSRF token, and there is no impossible branch to answer.
    case context.cookie(ctx, config.cookie_name) {
      Ok("") | Error(Nil) -> {
        log.debug("beacon.auth", "init without a session cookie: a guest")
        guest_init(ctx)
      }
      Ok(session_id) ->
        case session.fetch(store, session_id) {
          Ok(sess) ->
            case current_user(sess) {
              Ok(user_id) -> {
                log.debug("beacon.auth", "init for a signed-in session")
                authenticated_init(ctx, sess, user_id)
              }
              Error(Nil) -> {
                log.warning(
                  "beacon.auth",
                  "init: "
                    <> error_to_string(MissingUser)
                    <> "; rendering a guest",
                )
                guest_init(ctx)
              }
            }
          Error(session.SessionNotFound as err)
          | Error(session.SessionExpired as err) -> {
            log.warning(
              "beacon.auth",
              "init: "
                <> error_to_string(store_failure(err, "init session lookup"))
                <> "; rendering a guest",
            )
            guest_init(ctx)
          }
          Error(session.SessionContention as err)
          | Error(session.SessionBackendFailed(_) as err)
          | Error(session.InvalidBackend(_) as err) -> {
            // `store_failure` logs the backend's reason as an error.
            let failure = store_failure(err, "init session lookup")
            log.error(
              "beacon.auth",
              "init cannot verify the session ("
                <> error_to_string(failure)
                <> "); refusing it with 503",
            )
            Error(error.unavailable(error_to_string(failure)))
          }
        }
    }
  }
}

/// Wrap an API route handler with session + current-user validation.
pub fn authenticated(
  store: session.SessionStore,
  config: SessionConfig,
  handler: fn(Request(Connection), session.Session, String) ->
    Response(ResponseBody),
) -> fn(Request(Connection)) -> Response(ResponseBody) {
  fn(req: Request(Connection)) {
    case session_from_request(req, store, config) {
      Ok(sess) -> {
        case current_user(sess) {
          Ok(user_id) -> handler(req, sess, user_id)
          Error(Nil) -> {
            log.warning(
              "beacon.auth",
              "Auth rejected: " <> error_to_string(MissingUser),
            )
            unauthorized_response()
          }
        }
      }
      Error(err) -> rejection_response(err)
    }
  }
}

/// Alias for the common authenticated API route wrapper.
pub fn protect_api(
  store: session.SessionStore,
  config: SessionConfig,
  handler: fn(Request(Connection), session.Session, String) ->
    Response(ResponseBody),
) -> fn(Request(Connection)) -> Response(ResponseBody) {
  authenticated(store, config, handler)
}

/// Wrap a state-changing API route with session, user, and CSRF validation.
pub fn csrf_authenticated(
  store: session.SessionStore,
  config: SessionConfig,
  handler: fn(Request(Connection), session.Session, String) ->
    Response(ResponseBody),
) -> fn(Request(Connection)) -> Response(ResponseBody) {
  fn(req: Request(Connection)) {
    case session_from_request(req, store, config) {
      Ok(sess) -> {
        case validate_csrf(req, sess, config), current_user(sess) {
          Ok(Nil), Ok(user_id) -> handler(req, sess, user_id)
          Error(err), _ -> {
            log.warning(
              "beacon.auth",
              "CSRF rejected: " <> error_to_string(err),
            )
            forbidden_response(error_to_string(err))
          }
          _, Error(Nil) -> {
            log.warning(
              "beacon.auth",
              "Auth rejected: " <> error_to_string(MissingUser),
            )
            unauthorized_response()
          }
        }
      }
      Error(err) -> rejection_response(err)
    }
  }
}

/// Alias for the common authenticated + CSRF API route wrapper.
pub fn protect_api_with_csrf(
  store: session.SessionStore,
  config: SessionConfig,
  handler: fn(Request(Connection), session.Session, String) ->
    Response(ResponseBody),
) -> fn(Request(Connection)) -> Response(ResponseBody) {
  csrf_authenticated(store, config, handler)
}

/// Standard login route.
///
/// `authenticate` receives the request so the app can read form, JSON, or
/// headers. Return `Ok(user_id)` to create the session; return `Error(reason)`
/// to reject the login with `401`.
pub fn login_route(
  path: String,
  store: session.SessionStore,
  config: SessionConfig,
  authenticate: fn(Request(Connection)) -> Result(String, String),
) -> api.Route {
  api.post(path, fn(req) {
    case authenticate(req) {
      Ok(user_id) -> {
        let old_id =
          option.from_result(session.id_from_request(req, config.cookie_name))
        case login_json_response_rotating(store, old_id, user_id, config) {
          Ok(login) -> login.response
          // Both failures were logged where they happened.
          Error(StoreFailed(_)) -> unavailable_response()
          Error(CookieRejected(_)) -> api.text(500, "Internal Server Error")
        }
      }
      Error(reason) -> {
        log.warning("beacon.auth", "Login route rejected request")
        api.text(401, reason)
      }
    }
  })
}

/// Standard current-user route.
pub fn current_user_route(
  path: String,
  store: session.SessionStore,
  config: SessionConfig,
) -> api.Route {
  api.get(
    path,
    authenticated(store, config, fn(_req, _sess, user_id) {
      api.json_value(
        200,
        json_builder.object([#("user", json_builder.string(user_id))]),
      )
    }),
  )
}

/// Standard logout route.
pub fn logout_route(
  path: String,
  store: session.SessionStore,
  config: SessionConfig,
) -> api.Route {
  api.post(
    path,
    csrf_authenticated(store, config, fn(_req, sess, _user_id) {
      let ok =
        api.json_value(
          200,
          json_builder.object([#("ok", json_builder.bool(True))]),
        )
      case logout_response(store, sess, ok, config) {
        Ok(resp) -> resp
        // Both failures were logged where they happened.
        Error(StoreFailed(_)) -> unavailable_response()
        Error(CookieRejected(_)) -> api.text(500, "Internal Server Error")
      }
    }),
  )
}

/// Standard `/api/login`, `/api/me`, and `/api/logout` route handler.
pub fn session_routes(
  store: session.SessionStore,
  config: SessionConfig,
  authenticate: fn(Request(Connection)) -> Result(String, String),
) -> fn(Request(Connection)) -> Option(Response(ResponseBody)) {
  api.routes([
    login_route("/api/login", store, config, authenticate),
    current_user_route("/api/me", store, config),
    logout_route("/api/logout", store, config),
  ])
}

/// Convert a high-level auth error into a stable text reason.
pub fn error_to_string(err: SessionError) -> String {
  case err {
    MissingSessionCookie -> "missing session cookie"
    InvalidSession -> "invalid session"
    MissingUser -> "missing user"
    MissingCsrfToken -> "missing CSRF token"
    InvalidCsrfToken -> "invalid CSRF token"
    SessionStoreUnavailable(_) -> "session store unavailable"
  }
}

/// Convert a login or logout response error into a text reason.
pub fn response_error_to_string(err: ResponseError) -> String {
  case err {
    CookieRejected(error) ->
      "session cookie rejected: " <> cookie.error_to_string(error)
    StoreFailed(error) ->
      "session store unavailable: " <> session.store_error_to_string(error)
  }
}

/// Auth middleware — rejects unauthenticated requests with 401.
/// Checks for a session cookie and validates it against the store.
/// Uses `default_session_config()`; see `require_auth_with_config`.
pub fn require_auth(store: session.SessionStore) -> middleware.Middleware {
  require_auth_with_config(store, default_session_config())
}

/// Auth middleware using the configured cookie name.
pub fn require_auth_with_config(
  store: session.SessionStore,
  config: SessionConfig,
) -> middleware.Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case current_user_from_request(req, store, config) {
      Ok(_user_id) -> next(req)
      Error(err) -> rejection_response(err)
    }
  }
}

/// CSRF middleware — validates CSRF token on state-changing requests.
/// Allows GET, HEAD, OPTIONS. Requires valid token on POST, PUT, DELETE, PATCH.
/// Uses `default_session_config()`; see `csrf_protection_with_config`.
pub fn csrf_protection(store: session.SessionStore) -> middleware.Middleware {
  csrf_protection_with_config(store, default_session_config())
}

/// CSRF middleware using the configured cookie and header names.
/// Tokens are compared in constant time.
pub fn csrf_protection_with_config(
  store: session.SessionStore,
  config: SessionConfig,
) -> middleware.Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case req.method {
      http.Get | http.Head | http.Options -> next(req)
      _ -> {
        case session_from_request(req, store, config) {
          Ok(sess) ->
            case validate_csrf(req, sess, config) {
              Ok(Nil) -> next(req)
              Error(err) -> {
                log.warning(
                  "beacon.auth",
                  "CSRF rejected: " <> error_to_string(err),
                )
                forbidden_response(csrf_rejection_text(err))
              }
            }
          // Already logged as an error by store_failure.
          Error(SessionStoreUnavailable(_)) -> unavailable_response()
          Error(err) -> {
            log.warning(
              "beacon.auth",
              "CSRF rejected: " <> error_to_string(err),
            )
            forbidden_response(csrf_rejection_text(err))
          }
        }
      }
    }
  }
}

fn csrf_rejection_text(err: SessionError) -> String {
  case err {
    MissingCsrfToken -> "Missing CSRF token"
    InvalidCsrfToken -> "Invalid CSRF token"
    MissingSessionCookie -> "Missing CSRF token"
    InvalidSession -> "Invalid session"
    MissingUser -> "Invalid session"
    SessionStoreUnavailable(_) -> "Session store unavailable"
  }
}

/// The response for a request whose session could not be accepted: 503
/// when the store could not answer (already logged as an error), 401
/// otherwise.
fn rejection_response(err: SessionError) -> Response(ResponseBody) {
  case err {
    SessionStoreUnavailable(_) -> unavailable_response()
    _ -> {
      log.warning("beacon.auth", "Auth rejected: " <> error_to_string(err))
      unauthorized_response()
    }
  }
}

fn unavailable_response() -> Response(ResponseBody) {
  response.new(503)
  |> response.set_header("retry-after", "1")
  |> response.set_body(Bytes(bytes_tree.from_string("Service Unavailable")))
}

fn unauthorized_response() -> Response(ResponseBody) {
  response.new(401)
  |> response.set_body(Bytes(bytes_tree.from_string("Unauthorized")))
}

fn forbidden_response(reason: String) -> Response(ResponseBody) {
  response.new(403)
  |> response.set_body(Bytes(bytes_tree.from_string("Forbidden: " <> reason)))
}
