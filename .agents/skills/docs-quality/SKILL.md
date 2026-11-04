---
name: docs-quality
description: Audit documentation for accuracy, completeness, and freshness — checks ARCHITECTURE.md, GETTING_STARTED.md, AGENTS.md, code comments, and examples against actual code.
user_invocable: true
---

# Documentation Quality Audit

Evaluate whether the documentation accurately reflects the current codebase, is complete enough for a new contributor, and doesn't contain stale or misleading information.

## Usage

- `/docs-quality` — audit all documentation
- `/docs-quality architecture` — audit ARCHITECTURE.md only
- `/docs-quality getting-started` — audit GETTING_STARTED.md only
- `/docs-quality Codex` — audit AGENTS.md only
- `/docs-quality examples` — audit example code and README files
- `/docs-quality api` — audit public API doc comments
- `/docs-quality stale` — focus on finding stale/outdated content

## Philosophy

Documentation that's wrong is worse than no documentation — it wastes time and builds wrong mental models. Every claim in the docs should be verifiable against the current code. Examples should actually work. API references should match function signatures.

**The question is not "do we have docs?" but "would a new developer be correctly guided by these docs?"**

## What to Check

### 1. Architecture Document — Does It Match Reality?

**File: `docs/ARCHITECTURE.md`**

Read the architecture doc, then verify each claim against the actual codebase:

- **Layer descriptions:** Does each layer (transport, runtime, view, diffing, routing, SSR, effects) match the actual module structure? Are there layers in the code that aren't documented, or documented layers that don't exist?
- **Data flow diagrams:** Do the described flows (client event → decode → msg → update → view → diff → patch → send) match the actual code paths? Trace a click event through the code and verify each step.
- **Type definitions:** Do the documented types match actual type definitions in the code? Check RuntimeConfig, TransportConfig, SecurityLimits, AppBuilder, etc.
- **Wire protocol:** Does the documented wire format match `encode_server_message`/`decode_client_message`? List all message types in the code and check they're documented.
- **Module dependency graph:** Are imports accurate? Does the documented dependency order match reality?
- **Missing sections:** Are there major subsystems not covered? Check for: routing (scanner, codegen, manager), security (origin check, rate limiting, CSP), build system, patching, pubsub, store, session, middleware, components.

**For each discrepancy:**
```
[STALE-ARCH] Section "Wire Protocol" — Missing ClientNavigate, ClientServerFn, ClientEventBatch message types
  Reality: transport.gleam defines 6 client message types, docs only show 3
  Fix: Add the missing message types with their JSON schemas
```

### 2. Getting Started Guide — Does It Actually Work?

**File: `docs/GETTING_STARTED.md`**

Follow the getting started guide step by step and verify:

- **Prerequisites:** Are the listed versions correct? Does Gleam version match `gleam.toml`?
- **Install steps:** Do all commands work? `gleam new`, `gleam add`, etc.
- **First app example:** Does the example code compile? Does it match current API signatures?
- **Builder pattern:** Do documented builder functions (`brazier.app()`, `brazier.title()`, `brazier.start()`) match actual function signatures and return types?
- **Configuration:** Are all documented config options real? Are there undocumented options that users need?
- **Running:** Do `gleam run` / `gleam build` / `gleam test` commands work as described?
- **Code snippets:** Copy each code snippet, paste it into a test file, check if it compiles.

**For each broken step:**
```
[BROKEN-GUIDE] Step 3 "Add dependencies" — Missing gleam_crypto dependency
  Reality: brazier requires gleam_crypto but the guide doesn't mention adding it
  Fix: Add `gleam add gleam_crypto` to the dependency installation step
```

### 3. AGENTS.md — Does It Guide AI Correctly?

**File: `AGENTS.md`**

Check that AGENTS.md accurately describes:

- **Project structure:** Does the documented `src/` structure match reality? Are there directories or files not listed?
- **Key files table:** Does each file listed still exist? Is the purpose still accurate?
- **Dependencies table:** Do the listed dependencies match `gleam.toml`? Are versions current?
- **Build order/milestones:** Does the milestone list reflect completed work? Are there milestones marked as TODO that are actually done?
- **Commands:** Do `gleam build`, `gleam test`, `gleam run` work as documented?
- **Engineering principles:** Are the stated principles actually followed in the code? (Cross-reference with TigerStyle audit)
- **Reference repos table:** Are the listed repos still relevant? Are there new references that should be added?

**For each issue:**
```
[STALE-Codex] "Project Structure (Planned)" still shows planned structure, not actual
  Reality: Many modules exist that aren't listed (patch.gleam, component.gleam, handler.gleam, etc.)
  Fix: Update to reflect actual directory tree
```

### 4. Public API Documentation — Are Comments Accurate?

Check doc comments on all public functions in these key modules:

- `src/brazier.gleam` — Builder functions, start, configuration
- `src/brazier/transport.gleam` — SecurityLimits, TransportConfig, message types
- `src/brazier/runtime.gleam` — RuntimeConfig, RuntimeState, start, start_and_connect
- `src/brazier/effect.gleam` — every, from, background, after, batch
- `src/brazier/element.gleam` — el, text, attr, on, to_string
- `src/brazier/middleware.gleam` — pipeline, secure_headers, rate_limit, only, except
- `src/brazier/router/scanner.gleam` — RouteDefinition, scan_routes
- `src/brazier/router/codegen.gleam` — generate
- `src/brazier/router/manager.gleam` — RouteDispatcher, start
- `src/brazier/patch.gleam` — diff, apply_ops, is_empty
- `src/brazier/pubsub.gleam` — subscribe, broadcast, unsubscribe
- `src/brazier/ssr.gleam` — SsrConfig, render_page, session tokens
- `src/brazier/component.gleam` — Component, new, render, map_node

For each public function, check:
- Does the doc comment accurately describe what the function does?
- Are parameter descriptions correct?
- Are examples in doc comments compilable?
- Are "Reference:" links to other projects still accurate?
- Do `///` comments exist on all public types and functions?

**For each issue:**
```
[STALE-API] src/brazier/effect.gleam:96 — every() doc comment doesn't mention timer cap
  Reality: every() now rejects timers when count >= 10 per runtime
  Fix: Add note about max_timers limit to the doc comment
```

### 5. Example Code — Does It Compile and Run?

**Directories: `examples/*/`**

For each example directory:

- Does `gleam build` succeed in the example?
- Does the example's `gleam.toml` have correct dependencies?
- Do the route files match the documented patterns?
- Are there README files? Do they describe how to run the example?
- Does the example demonstrate the feature it claims to?
- Is the example using current API (not deprecated patterns)?

**For each broken example:**
```
[BROKEN-EXAMPLE] examples/routed/ — Missing README.md
  Reality: No instructions on how to run the routed example
  Fix: Add README with: gleam run, expected behavior, route structure
```

### 6. Code Comments — Stale or Misleading?

Search for comments that reference:
- **TODO/FIXME/HACK:** Are these tracked in `docs/TODO.md`? Are any resolved but not cleaned up?
- **"Temporary"/"Workaround":** Are these still needed?
- **Version numbers:** Do referenced versions match current deps?
- **"Reference: ...":** Do the referenced patterns still apply?
- **Removed features:** Comments about code that no longer exists
- **Wrong module names:** Comments referencing renamed or moved modules

**For each stale comment:**
```
[STALE-COMMENT] src/brazier/runtime.gleam:42 — "Reference: Lustre runtime/server/runtime.gleam"
  Reality: Lustre may have restructured; verify path is still valid
  Fix: Update reference path or remove if no longer applicable
```

### 7. Changelog and Progress — Are They Current?

**Files: `docs/PROGRESS.md`, `docs/TODO.md`**

- **PROGRESS.md:** Does "Current Status" match reality? Is the active milestone correct? Are completed milestones actually done?
- **TODO.md:** Are listed items still relevant? Have any been fixed but not removed? Are there new issues not tracked?
- **Missing documentation for new features:** Check git log for recent features — do they have corresponding documentation?

### 8. Missing Documentation

Check for important topics that have NO documentation:

- **Security configuration:** SecurityLimits, origin checking, rate limiting, CSP — are these documented for users?
- **File-based routing:** How to create routes, dynamic params, guards — is there a routing guide?
- **Deployment:** How to deploy a Brazier app to production — any guidance?
- **WebSocket protocol:** Is the wire format documented for custom client implementations?
- **Error handling:** How errors propagate, what users should expect
- **Testing:** How to test Brazier apps, what test utilities exist
- **Configuration reference:** All builder functions and their effects

**For each gap:**
```
[MISSING-DOC] No documentation for SecurityLimits configuration
  Impact: Users won't know they can tune rate limits, connection caps, or message sizes
  Fix: Add section to GETTING_STARTED.md or create docs/SECURITY.md
```

## Output Format

```
[STALE-ARCH] section — What's wrong and what it should say
[BROKEN-GUIDE] step — What doesn't work and how to fix it
[STALE-Codex] section — What's outdated
[STALE-API] file:line — Doc comment that doesn't match code
[BROKEN-EXAMPLE] dir — What's broken
[STALE-COMMENT] file:line — Comment that's misleading or outdated
[STALE-PROGRESS] section — Progress/TODO that's wrong
[MISSING-DOC] topic — Important topic with no documentation
```

At the end, summarize:
```
Documentation Quality Audit Results:
  Files scanned: N
  Total issues: N
    Stale architecture: N
    Broken guide steps: N
    Stale AGENTS.md: N
    Stale API comments: N
    Broken examples: N
    Stale code comments: N
    Missing documentation: N

  Accuracy level: LOW / MEDIUM / HIGH
  Justification: [one paragraph on whether a new developer would be correctly guided]

  Top 3 documentation priorities:
  1. [description]
  2. [description]
  3. [description]
```
