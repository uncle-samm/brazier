---
name: tigerstyle
description: Audit code for TigerBeetle/TigerStyle compliance — no error swallowing, log everything, assert invariants, no shortcuts, no fallbacks.
user_invocable: true
---

# TigerStyle Compliance Audit

Run a TigerStyle compliance audit on the Brazier codebase (or a specific file).

## Usage

- `/tigerstyle` — audit the full codebase
- `/tigerstyle src/brazier/runtime.gleam` — audit a specific file

## What to Check

Read `docs/TIGERSTYLE.md` and `AGENTS.md` for the full rules. Then scan the target code for violations:

### 1. No Error Swallowing
- `Error(_) -> Nil` — error silently discarded
- `Error(_) -> []` — error masked as empty result
- `_ -> Nil` catch-all that hides failures
- Any `case` arm that ignores the error variant without logging

### 2. Log Everything
- Public functions in transport/runtime/store/session should log on entry/exit/error
- State transitions (connected, disconnected, updated) must be logged
- Errors must be logged at `error` or `warning` level with context

### 3. Proper Assertions
- `let assert` must have a comment explaining why the invariant is safe
- No `todo` or `panic` in shipped code
- Custom error types should carry diagnostic context

### 4. No Fallbacks
- Never add fallback behavior unless the user explicitly approved it
- If something fails, it fails loudly with a clear error
- No "try X, if that fails try Y" patterns without user approval

### 5. No Shortcuts
- No "quick fixes" that paper over the real problem
- No backwards-compatibility hacks (renaming unused vars, re-exporting removed types)
- Fix root causes, not symptoms

### 6. No Error Swallowing in FFI
- Check `.erl` files for `catch _:_ -> nil` patterns
- Check `.mjs` files for empty `catch(e) {}` blocks

## Output Format

For each violation found, report:
```
[VIOLATION] file.gleam:42 — Error swallowed: Error(_) -> Nil
  Context: function do_thing silently discards file write errors
  Fix: log.warning("module", "Failed to write: " <> string.inspect(err))
```

At the end, summarize:
```
TigerStyle Audit Results:
  Files scanned: N
  Violations found: N
  Critical (error swallowing): N
  Warning (missing logging): N
  Info (style suggestions): N
```
