# Auth Workspace

Cookie sessions, CSRF-protected API routes and a role-gated page, on a
`beacon.full_application` with `beacon.with_router`.

- `POST /api/login` (a plain HTML form with a fixed login CSRF field)
  creates a session with `auth.create_login_rotating`, deleting any session
  id the browser already had, and sets the HttpOnly session cookie. The
  JSON answer carries the session's CSRF token for API clients.
- `GET /api/me`, `POST /api/profile` and `POST /api/logout` use
  `auth.protect_api` and `auth.protect_api_with_csrf`. Logout deletes the
  session, and Beacon closes its live sockets.
- `init` reads the session cookie from the `Context` (`beacon.cookie`) on
  the HTML render and on the connected mount, and loads the account from
  the session store. No cookie or an expired session is a guest; a store
  that cannot answer crashes the request instead of showing the guest page.
- `ws_auth(auth.protect_ws(...))` refuses the WebSocket without a valid
  session.
- One `Route` type and `parse` cover `/`, `/login`, `/app`, `/settings` and
  `/admin`; any other path is a 404. Nav links change the route without a
  page load.
- `/admin` needs the admin role (user `ada`). The server checks the role
  again when an audit event arrives, so a forged event from another user is
  refused and logged.
- "Save profile" writes the display name to the session store, so the next
  page load shows it.
- The session id, the audit key and the audit trail stay in the
  server-only `Session` record; `sync` sends only the Model.

```sh
cd examples/auth_workspace
gleam run -m beacon/build   # after changing the source
gleam run -m auth_workspace
```

Open `http://localhost:8080/login` and sign in as `ada` (admin) or any
other name (user).
