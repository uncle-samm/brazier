# AI Chat

Real-time chat with a deterministic server-side streaming response.

## Features

- `beacon.full_application` with a server-only `Session`: the per-session
  usage counters (prompts, characters streamed) are never synced. `sync`
  sends only the Model.
- `effect.background` runs the stream in a process the session owns, so
  it stops when the session ends. The stream drips the response to the
  browser a few characters at a time.
- `CharDelta`, `StreamDone` and `StreamError` are dispatched only by the
  stream. No view handler builds them, so the server refuses them from the
  browser.
- The Send button is disabled while a stream runs. The server also refuses
  a prompt while one is running, an input over 2000 characters, and new
  prompts once the conversation has 100 messages. Each refusal is logged.
- A stream that gets no chunk for 5 seconds ends with a visible error.
- No API key or external service, so it can run in browser conformance CI.

## Run

```bash
cd examples/ai_chat
gleam run -m beacon/build   # after changing the source
gleam run -m ai_chat
```

Open http://localhost:8080, type a message and watch the response stream.
