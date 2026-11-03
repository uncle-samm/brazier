# Privacy Demo

Shows how `beacon.full_application` keeps secrets on the server.

## Features

- Each session holds an API key, a database URL and a request count next
  to its Model. `sync` hands only the Model to the browser, so the rest is
  never encoded.
- The build compiles for the browser only what `view` reaches. The secret
  constants are reached from `init` alone, so they are not in the client
  bundle. Names play no part: `api_key` needs no `server_` prefix.
- The `app_title` constant is reached from `view`, so it is in the bundle.
- The subtotal, tax and total are not stored. `view` derives them from the
  Model, and those functions are compiled to JavaScript with it.
- `update` runs only on the server. It counts requests in the session and
  logs each one.

## Run

```bash
cd examples/privacy_demo
gleam run -m beacon/build   # after changing the source
gleam run -m privacy_demo
```

Open http://localhost:8080. Add and clear items to see the totals change.
Search the `beacon_client_*.js` bundle for `sk_live` or `postgres:` to
check that the secrets are absent.
