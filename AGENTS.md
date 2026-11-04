# Brazier

Full-stack Gleam web framework on BEAM. MVU architecture, one process per session, WebSocket transport.

## Codex Project Instructions

Codex reads this file (`AGENTS.md`) for project-local guidance. There is no repo-editable Codex system prompt file such as codex.md; do not touch `~/.codex` for this project. Project skills live in `.agents/skills/*/SKILL.md` and are the Codex source of truth. The old Claude tigerstyle slash command is superseded by `.agents/skills/tigerstyle/SKILL.md` unless a future command adds genuinely new behavior.

## Learn More

| File | What you'll learn |
|------|-------------------|
| `docs/PROGRESS.md` | **Current milestone + completed work — read FIRST every session** |
| `docs/ARCHITECTURE.md` | Technical architecture, all modules, wire protocol, deps, project structure |
| `docs/GETTING_STARTED.md` | Quick start, builder API, three state layers, routing |
| `docs/TIGERSTYLE.md` | Full TigerStyle engineering principles |
| `docs/SECURITY.md` | SecurityLimits, WebSocket limits, origin validation, rate limiting, CSP, tokens |
| `docs/ROUTING.md` | Explicit route-aware apps, dynamic params, no route discovery |
| `docs/WIRE_PROTOCOL.md` | WebSocket message types with JSON examples, handshake, close codes |
| `docs/CONFORMANCE.md` | Canonical example apps and the framework contract each one covers |
| `docs/EFFECTS.md` | Effects, timers, async patterns |
| `docs/MIDDLEWARE.md` | HTTP middleware pipeline, scoping, built-ins |
| `docs/STATE_MANAGEMENT.md` | Stores, PubSub, dynamic subscriptions, sessions |
| `docs/COMPONENTS.md` | Composable MVU units |
| `docs/CLUSTERING.md` | Multi-node clustering, PubSub and presence across nodes, distribution security |
| `docs/TELEMETRY.md` | Telemetry events and metrics |
| `docs/TESTING.md` | Unit, runtime, sim, and CDP tests |
| `docs/ERROR_HANDLING.md` | Error types, recovery, user experience |
| `docs/DEPLOYMENT.md` | Environment, secret key, reverse proxies, Docker, health check |
| `docs/HTML_ELEMENTS.md` | Element helpers, attributes, events |
| `docs/SVG.md` | SVG element helpers, attributes, namespaces |
| `docs/TODO.md` | Issues and deferred items |
| `docs/archive/PROGRESS.md` | Milestone 1–116 progress notes, archived verbatim |
| `CHANGELOG.md` | What changed, per release |

## Commands

Run these in the repository root. The framework has no `main`, so there is no
root `gleam run`; run an app from `examples/` (see `README.md`).

```sh
gleam build                    # Must exit 0 with zero warnings
gleam format --check src test  # Must exit 0
gleam run -m brazier/lint       # Must report 0 violations
gleam test                     # Must exit 0 with all tests passing (needs node and npx)
scripts/check_docs.sh          # Doc samples compile, doc links resolve
```

## Docs That Compile

`scripts/check_docs.sh` compiles every ```` ```gleam ```` block in the docs
against the current API (`gleam build --warnings-as-errors` in
`build/docs_check`) and checks every relative link, anchor and backticked
`.md` path. `scripts/check_docs.sh links` or
`scripts/check_docs.sh samples docs/X.md` runs one half. A block is compiled
as its own module unless an HTML comment directly above the fence says
otherwise:

- `<!-- docs-check: fragment REASON -->`: not compiled; the reason is
  required (an excerpt of a type, an illustration of a mistake).
- `<!-- docs-check: module NAME -->`: compiled as module `NAME` (for samples
  that import each other, such as `my_app/counter`).
- `<!-- docs-check: wrap` ... `-->`: the comment holds hidden code with one
  line that is exactly `{{block}}`; the block is put there, indented like
  that line. Imports in the block must come before any hidden definition, so
  hidden app code goes after `{{block}}`.

Never hide a failure: when a sample stops compiling, fix it, or mark it a
fragment with a true reason. A warning fails the check, so sample functions
must be `pub` or used. Docs that are not compiled at all are listed with a
reason in `scripts/docs_check.py` (`NOT_COMPILED`, `LINKS_NOT_CHECKED`).

## Engineering Principles

Non-negotiable. Every change must follow these.

### No Error Swallowing

- **Never** discard, ignore, or silently catch errors.
- Every error must be explicitly handled or propagated via `Result`.
- No catch-all patterns that hide failures.
- Use `let assert` only when the invariant is truly guaranteed. Document why.

### Log Everything

- All significant state transitions, errors, warnings, and decisions must be logged.
- Use structured logging with context (module, function, relevant IDs).
- Log at appropriate levels: `error` for failures, `warning` for unexpected-but-handled, `info` for state transitions, `debug` for tracing.

### TigerStyle (see [docs/TIGERSTYLE.md](docs/TIGERSTYLE.md))

- Assert invariants aggressively. Crash early, crash loudly.
- No "temporary" hacks or workarounds. Fix the root cause.
- Test the unhappy paths as thoroughly as the happy paths.

### No Fallbacks

- **Never** add fallback behavior unless the user explicitly approves it.
- If something fails, it fails loudly. Do not silently degrade.
- Fallbacks hide bugs.

### No Shortcuts

- Stability and correctness over velocity.
- Prefer simple, correct code over clever code.
- Every change should leave the codebase better than you found it.

### No Invented Patterns

- Check reference repos before designing: Lustre (MVU/Effects), LiveView (diff protocol, SSR), Reflex (dirty-var tracking), Squirrel (codegen pattern), Glance (AST parsing).
- Adapt proven patterns to Gleam rather than inventing from scratch.

## Work Completion Standard

### Definition of Done (ALL must be true)

1. `gleam build` exits 0 with **zero warnings**
2. `gleam test` exits 0 with **all tests passing**
3. `gleam format --check src test`, `gleam run -m brazier/lint` and `scripts/check_docs.sh` pass
4. `docs/PROGRESS.md` is updated — completed tasks checked off
5. No debug leftovers, no `todo` or `panic` in shipped code
6. All new code has error handling, logging, and assertions per principles above

### Ralph Loop Protocol

1. **FIRST ACTION:** Read `docs/PROGRESS.md` to know where you are
2. Find the next unchecked task in the current milestone
3. Implement properly — follow engineering principles
4. Run `gleam build` and `gleam test` — fix everything until green
5. Update `docs/PROGRESS.md`
6. If blocked, document in PROGRESS.md and move to next task

### Failure Mode Prevention

- **Don't rewrite working code.** Read existing files before making changes.
- **Don't guess at APIs.** Check source code for correct function signatures.
- **Don't skip tests.** Every module needs tests. Test unhappy paths too.
- **Don't forget logging.** Public functions in transport/runtime should log.
- **Don't leave broken state.** If `gleam build` fails, fix it before doing anything else.
- **Don't add deps without checking.** Verify packages exist on Hex first.
