# TigerStyle Coding Principles

> Adapted from [TigerBeetle's TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) for the Brazier framework. TigerStyle is the coding methodology used by the TigerBeetle database team — we adopt its principles because building a web framework has the same requirement: if something goes wrong, you need to know immediately, not three hours later from a user report.

## Core Philosophy

**The cost of a crash is low. The cost of silent corruption is unbounded.**

A process that crashes with a clear assertion message is easy to fix: you see the error, you find the line, you understand the invariant that was violated. A process that silently swallows an error and continues with bad state can corrupt data, confuse users, and take hours to diagnose.

## The Principles

### 1. No Error Swallowing

Every error must be explicitly handled or propagated. Never write:

<!-- docs-check: wrap
import brazier/log
import gleam/string

pub type Thing {
  Thing(name: String)
}

{{block}}

fn do_thing(_id: String) -> Result(Thing, String) {
  Ok(Thing(name: "thing"))
}

fn handle(thing: Thing) -> Nil {
  log.debug("app.sync", "handled " <> thing.name)
}
-->
```gleam
// BAD: the error is invisible
pub fn sync_quietly(id: String) -> Nil {
  case do_thing(id) {
    Ok(value) -> handle(value)
    Error(_) -> Nil
  }
}

// GOOD: the error is visible
pub fn sync(id: String) -> Nil {
  case do_thing(id) {
    Ok(value) -> handle(value)
    Error(err) -> {
      log.warning(
        "app.sync",
        "do_thing(" <> id <> ") failed: " <> string.inspect(err),
      )
      Nil
    }
  }
}
```

If you catch yourself writing `Error(_) -> Nil`, stop. Either:
- Log the error with context (module, function, what failed, why it matters)
- Propagate it via `Result` to the caller
- Assert it can't happen with `let assert Ok(value) = ...` and document why

### 2. Log Everything

All significant state transitions, errors, warnings, and decisions must be logged with structured context.

<!-- docs-check: wrap
import brazier/log

pub fn levels() -> Nil {
  {{block}}
}
-->
```gleam
// Levels:
log.error("module", "msg")    // Failures that need attention
log.warning("module", "msg")  // Unexpected but handled
log.info("module", "msg")     // State transitions (connected, disconnected, started)
log.debug("module", "msg")    // Detailed tracing (every event, every render)
```

Rules:
- Every public function in transport, runtime, and store modules should log at appropriate levels
- Error paths must ALWAYS log — an error that isn't logged doesn't exist
- Include enough context to diagnose without a debugger: IDs, counts, reasons
- Use debug level for high-frequency operations (store.get, every mousemove) to avoid spam

### 3. Assert Invariants Aggressively

If something "can't happen," assert it. When it does happen, you'll know immediately.

<!-- docs-check: wrap
import gleam/erlang/process.{type Subject}

pub fn await_listener(reply_subject: Subject(Subject(String))) -> Subject(String) {
  {{block}}
  command_subject
}
-->
```gleam
// Document WHY the assertion is safe
// INVARIANT: The listener process was just spawned and MUST send its
// command_subject within 5 seconds. Timeout = fatal configuration error.
let assert Ok(command_subject) = process.receive(reply_subject, 5000)
  as "listener did not send its command subject within 5s"
```

Rules:
- Every `let assert` must have a comment explaining the invariant, and an
  `as "..."` message that names what failed
- Use `let assert` only when the invariant is truly guaranteed by program logic
- For runtime validation (user input, network data), use `Result` instead
- Never use `todo` or `panic` in shipped code

### 4. Crash Early, Crash Loudly

A crash with a clear message is better than silent corruption:

<!-- docs-check: wrap
pub type Settings {
  Settings(theme: String)
}

const default_settings = Settings(theme: "light")

{{block}}

fn validate(input: String) -> Result(Settings, String) {
  case input {
    "dark" | "light" -> Ok(Settings(theme: input))
    _ -> Error("unknown theme: " <> input)
  }
}

fn apply(settings: Settings) -> Result(Settings, String) {
  Ok(settings)
}
-->
```gleam
// BAD: continues with a value nobody chose
pub fn load_quietly(input: String) -> Result(Settings, String) {
  case validate(input) {
    Ok(valid) -> apply(valid)
    Error(_) -> apply(default_settings)  // what if the default is wrong?
  }
}

// GOOD: the caller knows at once
pub fn load(input: String) -> Result(Settings, String) {
  case validate(input) {
    Ok(valid) -> apply(valid)
    Error(err) -> Error(err)  // propagate, and let the caller decide
  }
}
```

On the BEAM, crashes are cheap. Supervisors restart processes. A crashed process with a clear error in the logs is infinitely preferable to a running process with corrupt state.

### 5. Error Types Carry Context

Error messages must contain enough information to diagnose the failure:

<!-- docs-check: fragment two alternative expressions side by side, not a module -->
```gleam
// BAD
Error("Failed to save file")

// GOOD
Error("Failed to save " <> path <> ": " <> string.inspect(os_error))
```

Custom error types should carry structured context, as Brazier's own
`error.BrazierError` does:

<!-- docs-check: fragment an excerpt of src/brazier/error.gleam, which has more constructors -->
```gleam
pub type BrazierError {
  TransportError(reason: String)
  CodecError(reason: String, raw: String)
  RuntimeError(reason: String)
}
```

### 6. No Shortcuts

- No "quick fixes" that paper over the real problem
- No `todo` or `panic` in shipped code
- No "temporary" hacks — they become permanent
- If a fix feels hacky, step back and find the proper solution
- Stability and correctness over velocity

### 7. Test the Unhappy Paths

Test what happens when things go wrong, not just when they go right:

- What happens when a WebSocket disconnects mid-event?
- What happens when the client sends binary garbage?
- What happens when 1000 connections hit the server simultaneously?
- What happens when a process crashes during an update?

The simulation tests (`test/brazier/sim_test.gleam`, with the harness in
`test/brazier/sim/`) open real WebSocket connections against a running app:

- **Scale**: 10, 50, 100 and 1000 concurrent connections.
- **Corrupt data**: partial JSON, binary noise, oversized payloads and
  unknown handlers; the server must survive and leak no process.
- **Flooding**: 500 events on one connection, past the per-connection rate
  limit.
- **Leaks**: rounds of 100 connect/disconnect cycles that must keep no
  process, ETS table, ETS object or atom.

### 8. Zero Tolerance for Leaks

If a test measures 0 leaked processes, assert exactly 0 — not "less than 10." If it ever leaks 1 process, that's a bug, and we want to know immediately:

<!-- docs-check: wrap
pub fn check_leaks(processes_leaked: Int) -> Nil {
  {{block}}
  Nil
}
-->
```gleam
// BAD: tolerates up to 9 leaked processes
let assert True = processes_leaked < 10

// GOOD: zero means zero
let assert True = processes_leaked == 0
```

Every simulation test meets this rule: each one asserts no failed
connection and exactly 0 kept processes.

## How We Enforce This

1. **Custom linter** (`gleam run -m brazier/lint`, `src/brazier/lint.gleam`) — parses the source and reports `todo`, `panic`, `let _ =` discards, degraded-path phrases, public functions in key modules that never log, and the pre-rename project name; the rules are listed at the top of `lint.gleam`
2. **Simulation tests** (`test/brazier/sim/`) — real connections, fault injection, leak detection
3. **Code review** — every `Error(_) -> Nil` is a red flag
4. **CI** — `gleam build` (zero warnings) + `gleam test` (all pass) + linter (zero violations)
5. **Docs that compile** (`scripts/check_docs.sh`) — every Gleam sample in the docs compiles with zero warnings, or is marked as a fragment with a reason
