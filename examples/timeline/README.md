# Timeline

An agent's steps as a `brazier/stream` ([docs/STREAMS.md](../../docs/STREAMS.md)).

## Features

- The steps are not in the model. `update` returns stream ops, the runtime
  sends each change once, and the browser keeps the last 20 steps
  (`stream.KeepLast(20)`). The model holds counters only.
- Append, Prepend, Fill 25 (past the limit, so the first steps are trimmed)
  and Reset (`stream.reset`) change the list. A prepend into a full
  `KeepLast` stream is dropped, as in LiveView.
- "Stream chunk" adds a word to the last appended step: an insert of a key
  already in the stream updates the step in place.
- Each step has Pick, Top and Delete buttons. Top is a move: a delete and an
  insert of the same key in one update, so the step keeps its DOM node and
  focus. Item handlers are relative to their step, so a click after a
  prepend still names the right step.
- The server keeps a private log of the steps (`full_application` with a
  `Session` the browser never sees), capped at 500 steps.
- Each step's progress meter is drawn by the `ChunkMeter` hook in
  `static/timeline_hooks.js`, which mounts, updates and unmounts with the
  step. The page's CSP allows same-origin scripts only, so the hook is a
  static file loaded with `defer`.
- A reconnect starts a new session: `init` refills the stream, and the
  browser keeps the DOM node of every step it inserts again.

## Run

```bash
cd examples/timeline
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run -m main
```

Open http://localhost:8080.

## Browser test

```bash
make browser-timeline   # from the repository root
```
