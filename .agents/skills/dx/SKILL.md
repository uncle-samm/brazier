---
name: dx
description: Audit Brazier developer experience — API ergonomics, state-model clarity, routing/auth/API usability, diagnostics, examples, docs, and onboarding friction.
user_invocable: true
---

# Developer Experience Audit

Run a DX audit on Brazier as a framework, not only on code style. The goal is to
answer: "Can a competent Gleam developer build a real app without learning
Brazier internals?"

## Usage

- `/dx` — audit the full framework DX
- `/dx api` — focus on public API ergonomics
- `/dx state` — focus on `Model`, `Local`, `Server`, stores, and effects
- `/dx routing` — focus on route APIs and route examples
- `/dx auth` — focus on auth/session/API route workflows
- `/dx examples` — focus on examples as onboarding and integration coverage
- `/dx docs` — focus on docs from a new-user perspective
- `/dx errors` — focus on diagnostics, build failures, lint messages, and logs

## Philosophy

Brazier should feel opinionated and easy:

- One conceptual app model: SSR first paint, then client-rendered UI from
  server-authoritative state updates.
- `Model` is server-authoritative UI state.
- `Local` is per-tab client state for instant UI.
- `Server` is private per-session server state that never reaches view, SSR
  HTML, JSON sync, or the client bundle.
- Shared stores are for cross-session shared state, not per-session app state.
- Unsupported app shapes fail loudly with actionable errors.
- Escape hatches exist, but beginner docs should not lead with them.

DX audits must be concrete. Prefer examples, file references, and suggested API
shapes over vague feedback like "make it simpler."

## What to Check

### 1. First-Run Experience

Check `docs/GETTING_STARTED.md`, `README.md`, examples, and current build/start
behavior.

- Can a new user create a counter in under 10 minutes?
- Is the required project shape obvious?
- Does first run tell the user what to do if client bundle generation fails?
- Are generated files, manifests, and build steps documented only as much as
  needed?
- Does the first example teach the recommended path, not an escape hatch?

Flag:
```
[ONBOARDING] docs/GETTING_STARTED.md:42 — Quick start uses head_html before core state concepts
  Problem: New users see a trusted raw HTML escape hatch before learning normal app structure.
  Fix: Move head_html to later "assets/custom head" section.
```

### 2. Public API Ergonomics

Check `src/brazier.gleam`, `src/brazier/api.gleam`, `src/brazier/auth.gleam`,
`src/brazier/route.gleam`, and examples.

- How many choices does a user face before writing a working app?
- Do names describe concepts users already understand?
- Are common paths short and boring?
- Are advanced paths available without leaking into beginner docs?
- Are return types and builder functions consistent?
- Does the API force users to understand runtime/build internals?
- Are there multiple ways to do the same thing? If yes, is one clearly
  preferred and are older/advanced paths labeled?

Brazier-specific checks:

- `app`, `app_with_effects`, `app_with_local`, `app_with_server`: do these feel
  like type-specific doors into one app model, or like separate frameworks?
- `on_update`: is it clearly the place for server-only effects that cannot live
  in client-visible `update`?
- `ws_init`: is it understandable, or does it replace too much hidden state?
- `with_state_recovery`, `model_encoder`: are these still necessary for normal
  users, or should they be generated/hidden?

### 3. State Model Clarity

Check docs, app constructors, examples, build analyzer diagnostics, and linter
messages.

- Can users predict whether a message is `LOCAL`, `MODEL`, or `MODEL+LOCAL`?
- Is it clear that `Local` is not sent through the server?
- Is it clear that `Server` is private and unavailable to `view`?
- Are stores explained as shared cross-session state, not as "server state"?
- Does `init_local(model)` make sense in examples?
- Are submit-boundary patterns using `on_submit_local` when they need live
  browser values?
- Does build output explain message classification in user language?

Flag risky patterns:

- Stale closure over `local` in submit handlers.
- Store/PubSub/env/HTTP/FFI/random calls inside client-visible `update`.
- Examples that use `app_with_effects` where `app |> on_update` would teach a
  better pattern.
- Docs that say "server state" when they mean shared store or private `Server`.

### 4. Rendering And Hydration Predictability

Check client/server rendering docs, build failures, examples, and browser tests.

- Is the single rendering model obvious?
- Do users know first paint is SSR and later updates are state sync/patch?
- Are unsupported client-render shapes rejected with clear next steps?
- Are there docs/tests proving normal updates do not use HTML morph fallback?
- Are Local-only updates visibly instant and zero-traffic in examples/tests?
- Are route-generated apps described as using the same rendering path?

### 5. Routing DX

Check `route.page`, `route.dispatch_view`, route examples, and route docs.

- Is there one recommended route API?
- Are old/file/discovery routes removed or clearly deprecated if still present?
- Is child route state wiring too manual?
- Can route modules own their state without large boilerplate?
- Are guards/loaders/actions either implemented and documented or not claimed?
- Do route examples show the recommended pattern with realistic app state?

Look for boilerplate that could become framework API:

- Repeated child-message mapping.
- Repeated `route.dispatch_view` assertions.
- Manual path storage/update in `Model`.
- Repeated route-local server-state wrapping.

### 6. Auth And API DX

Check `brazier/auth`, `brazier/api`, `examples/auth_workspace`, docs, and tests.

- Can users implement login/logout/current user without hand-rolling cookies?
- Is CSRF hard to forget?
- Are `ws_auth`, `ws_init`, and protected pages wired by high-level helpers?
- Are API route helpers typed enough, or still stringly JSON/body handling?
- Is there a clear path for custom auth providers?
- Is raw transport still available as an advanced escape hatch?

Missing APIs to consider:

- `auth.login_route`
- `auth.logout_route`
- `auth.current_user_route`
- `auth.protected_api`
- `auth.protected_page`
- `auth.session_app` or builder helper wiring cookie + CSRF + `ws_auth` +
  request-aware server init
- typed JSON body/query/response helpers in `brazier/api`

### 7. Diagnostics And Error Messages

Check build analyzer errors, linter output, runtime config errors, transport
errors, and docs.

- Does every failure say what happened, where, and what to change?
- Do build errors name the unsupported shape and exact missing client-visible
  pieces?
- Does the client contract report help users understand their app?
- Are linter messages actionable and phrased in user concepts?
- Are strict security errors documented enough for non-browser tools?
- Are logs helpful without exposing internals or secrets?

Flag:
```
[DIAGNOSTIC] src/brazier/build.gleam:661 — Unsupported app shape message too generic
  Problem: Says Model/Msg/update/view are required but not which one was missing.
  Fix: Include detected/missing symbols and module path in the error.
```

### 8. Examples As Product Surface

Check every example README and source.

- Does each example teach one clear concept?
- Are examples realistic enough to copy from?
- Are any examples outdated or teaching discouraged APIs?
- Do examples cover normal app, Local, Server privacy, auth, API routes,
  routing, multi-file, shared state, effects, and browser-heavy interactions?
- Do examples double as integration/e2e coverage?
- Are run commands correct?
- Do examples hide too much in helper modules for learning purposes?

### 9. Documentation Quality From A DX Angle

Use this alongside `/docs-quality` when asked for a docs audit. DX focuses on
learnability and decision cost.

- Is there a clear progression from counter to real app?
- Are mental models repeated consistently?
- Are escape hatches labeled trusted/advanced?
- Are "why" and "when to use" explanations present, not only signatures?
- Does terminology stay stable across docs and examples?
- Are docs honest about alpha/breaking behavior?

### 10. Migration And Maintenance Friction

- How painful is it to move from normal to routed app?
- How painful is it to add auth later?
- How painful is it to split a single-file app into modules?
- How painful is it to add Local or Server after the app exists?
- Are generated files predictable and ignored/committed appropriately?
- Does formatting/build/lint workflow stay simple?

## Output Format

Lead with the most important DX problems, then strengths, then concrete next
steps.

Use this format for findings:
```
[HIGH] API shape — Too many app entrypoints feel like separate modes
  Evidence: src/brazier.gleam exposes app/app_with_effects/app_with_local/app_with_server.
  User impact: Beginners must choose architecture before they understand Brazier's state model.
  Fix: Keep type-specific builders internally, but docs should present one conceptual app model and one recommended path.
```

Severity guide:

- **HIGH** — Blocks or seriously confuses common real-app usage.
- **MEDIUM** — Adds avoidable boilerplate, ambiguity, or learning friction.
- **LOW** — Polish, naming, docs ordering, or helpful examples.
- **INFO** — Nice-to-have idea or future direction.

End with:
```
DX Audit Results:
  Overall DX rating: N/10
  Confidence: LOW / MEDIUM / HIGH
  Best current strengths:
    1. ...
    2. ...
    3. ...
  Highest-impact fixes:
    1. ...
    2. ...
    3. ...
  Short verdict: [one paragraph]
```

## Non-Goals

- Do not turn DX audit into a generic code review. Use `/tigerstyle`,
  `/security`, and `/test-quality` for those concerns.
- Do not recommend adding multiple competing APIs. Brazier should be opinionated.
- Do not propose fallback behavior to improve perceived ease. Fail loudly with
  better diagnostics instead.
- Do not praise examples or docs without checking whether they teach the
  recommended current API.
