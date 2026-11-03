# Todo App

A shared todo list built with `beacon.full_application`.

## Features

- Add, toggle, delete and clear completed todos
- The draft and the filter (All/Active/Completed) live in the Local layer:
  typing and filtering never reach the server
- One list for every session, kept in a `beacon/store` list as an
  append-only change log, so concurrent sessions never overwrite each other
- The store broadcasts on its topic; every session subscribes to it and
  re-reads the log (`beacon.subscriptions` and `beacon.on_notify`)
- "items left" is derived in the view, not stored in the model
- The server rejects empty or over-long todos and changes to unknown todos,
  with a logged warning

## Run

```bash
cd examples/todo
gleam run -m beacon/build   # after changing the source
gleam run
```

Open http://localhost:8080, add and toggle todos, filter them, and open a
second tab to see changes arrive.
