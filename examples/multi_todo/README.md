# Multi-File Todo

A per-session todo list built with `brazier.full_application`, with its
`TodoItem` and `Filter` types defined in a separate domain module.

## Features

- External types from `src/domains/task.gleam` (`TodoItem`, and the `Filter`
  enum All/Active/Completed); the codegen follows them across modules
- The draft and the filter live in the Local layer: typing and filtering
  never reach the server
- Add, toggle, delete and clear completed todos; the list is held by the
  session's server process
- The server rejects empty or over-long todos and changes to unknown todos,
  with a logged warning

## Run

```bash
cd examples/multi_todo
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080 and manage todos with the filter buttons.
