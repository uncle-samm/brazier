/// Auth helpers — login, logout, session-bound authentication.
/// Works with the session store and middleware context.
import beacon/api
import beacon/cookie
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
pub fn login(store: session.SessionStore, user_id: String) -> session.Session {
  let sess =
    session.create_with_data(store, dict.from_list([#(user_id_key, user_id)]))
  log.info("beacon.auth", "User logged in")
  sess
}

/// Log in a user, deleting the previous session id (if any).
///
/// Live WebSockets bound to the old session are told to close.
pub fn login_rotating(
  store: session.SessionStore,
  old_session_id: Option(String),
  user_id: String,
) -> session.Session {
  delete_previous_session(store, old_session_id)
  login(store, user_id)
}

/// Create a login session and session-bound CSRF token.
pub fn create_login(
  store: session.SessionStore,
  user_id: String,
) -> LoginSession {
  create_login_rotating(store, None, user_id)
}

/// Create a login session and CSRF token, deleting the previous session id.
pub fn create_login_rotating(
  store: session.SessionStore,
  old_session_id: Option(String),
  user_id: String,
) -> LoginSession {
  delete_previous_session(store, old_session_id)
  let csrf_token = session.generate_id()
  let sess =
    session.create_with_data(
      store,
      dict.from_list([#(user_id_key, user_id), #(csrf_token_key, csrf_token)]),
    )
  log.info("beacon.auth", "User logged in")
  LoginSession(session: sess, csrf_token: csrf_token)
}

fn delete_previous_session(
  store: session.SessionStore,
  old_session_id: Option(String),
) -> Nil {
  case old_session_id {
    Some(old_id) -> {
      log.info("beacon.auth", "Login replacing previous session")
      session.delete(store, old_id)
    }
    None -> Nil
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
      Error(InvalidSession)
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
          Error(InvalidSession)
        }
      }
    }
  }
}

/// Attach the configured HttpOnly session cookie to a response.
pub fn with_session_cookie(
  resp: Response(ResponseBody),
  sess: session.Session,
  config: SessionConfig,
) -> Response(ResponseBody) {
  resp
  |> cookie.set(config.cookie_name, sess.id, config.cookie_options)
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
) -> LoginResult {
  let login = create_login(store, user_id)
  let resp =
    resp
    |> with_session_cookie(login.session, config)
  LoginResult(
    session: login.session,
    csrf_token: login.csrf_token,
    response: resp,
  )
}

/// Log in a user and return a standard JSON response.
///
/// The response body is `{"ok":true,"csrf":"..."}` and the session ID is
/// sent only as an HttpOnly cookie.
pub fn login_json_response(
  store: session.SessionStore,
  user_id: String,
  config: SessionConfig,
) -> LoginResult {
  let login = create_login(store, user_id)
  let resp =
    api.json_value(
      200,
      json_builder.object([
        #("ok", json_builder.bool(True)),
        #("csrf", json_builder.string(login.csrf_token)),
      ]),
    )
    |> with_session_cookie(login.session, config)
  LoginResult(
    session: login.session,
    csrf_token: login.csrf_token,
    response: resp,
  )
}

/// Like `login_json_response`, but deletes the previous session id first.
pub fn login_json_response_rotating(
  store: session.SessionStore,
  old_session_id: Option(String),
  user_id: String,
  config: SessionConfig,
) -> LoginResult {
  let login = create_login_rotating(store, old_session_id, user_id)
  let resp =
    api.json_value(
      200,
      json_builder.object([
        #("ok", json_builder.bool(True)),
        #("csrf", json_builder.string(login.csrf_token)),
      ]),
    )
    |> with_session_cookie(login.session, config)
  LoginResult(
    session: login.session,
    csrf_token: login.csrf_token,
    response: resp,
  )
}

/// Log out — destroys the session.
pub fn logout(store: session.SessionStore, session_id: String) -> Nil {
  session.delete(store, session_id)
  log.info("beacon.auth", "Session logged out")
}

/// Destroy the session and attach a matching cookie deletion header.
pub fn logout_response(
  store: session.SessionStore,
  sess: session.Session,
  resp: Response(ResponseBody),
  config: SessionConfig,
) -> Response(ResponseBody) {
  logout(store, sess.id)
  resp
  |> cookie.delete_with_options(config.cookie_name, config.cookie_options)
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
  case session_id_from_request(req, config) {
    Ok(session_id) -> {
      case session.get(store, session_id) {
        Some(sess) -> Ok(sess)
        None -> Error(InvalidSession)
      }
    }
    Error(err) -> Error(err)
  }
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

/// Request-aware initializer for apps whose initial model depends on auth.
///
/// Use with `beacon.ws_init` when SSR should render the authenticated state on
/// the first response. Invalid sessions are logged and treated as guests.
pub fn init_from_session(
  store: session.SessionStore,
  config: SessionConfig,
  guest_init: fn(Request(Connection)) -> model,
  authenticated_init: fn(Request(Connection), session.Session, String) -> model,
) -> fn(Request(Connection)) -> model {
  fn(req: Request(Connection)) {
    case session_from_request(req, store, config) {
      Ok(sess) -> {
        case current_user(sess) {
          Ok(user_id) -> authenticated_init(req, sess, user_id)
          Error(Nil) -> {
            log.warning("beacon.auth", "Session missing user during init")
            guest_init(req)
          }
        }
      }
      Error(MissingSessionCookie) -> guest_init(req)
      Error(err) -> {
        log.warning(
          "beacon.auth",
          "Rejected session during init: " <> error_to_string(err),
        )
        guest_init(req)
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
      Error(err) -> {
        log.warning("beacon.auth", "Auth rejected: " <> error_to_string(err))
        unauthorized_response()
      }
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
      Error(err) -> {
        log.warning("beacon.auth", "Auth rejected: " <> error_to_string(err))
        unauthorized_response()
      }
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
        login_json_response_rotating(store, old_id, user_id, config).response
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
      logout_response(
        store,
        sess,
        api.json_value(
          200,
          json_builder.object([#("ok", json_builder.bool(True))]),
        ),
        config,
      )
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
      Error(err) -> {
        log.warning("beacon.auth", "Auth rejected: " <> error_to_string(err))
        unauthorized_response()
      }
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
  }
}

fn unauthorized_response() -> Response(ResponseBody) {
  response.new(401)
  |> response.set_body(Bytes(bytes_tree.from_string("Unauthorized")))
}

fn forbidden_response(reason: String) -> Response(ResponseBody) {
  response.new(403)
  |> response.set_body(Bytes(bytes_tree.from_string("Forbidden: " <> reason)))
}
