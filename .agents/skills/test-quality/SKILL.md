---
name: test-quality
description: Audit test suite for honesty, gaps, false confidence, outdated tests, and missing coverage — unit, sim, and CDP tests.
user_invocable: true
---

# Test Quality Audit

Critically evaluate whether the test suite provides honest, useful feedback — or whether it creates false confidence.

## Usage

- `/test-quality` — audit all tests (unit, sim, CDP)
- `/test-quality src/brazier/runtime.gleam` — audit tests for a specific module
- `/test-quality gaps` — focus on finding test gaps
- `/test-quality honesty` — focus on whether tests are honest
- `/test-quality sim` — audit simulation tests only
- `/test-quality cdp` — audit CDP browser tests only

## Philosophy

A test suite that always passes is worse than no tests at all — it provides false confidence. Every test should be able to fail for a real reason. Tests should verify behavior that matters, not just that code runs without crashing.

**The question is not "do we have tests?" but "would we catch a real bug?"**

## What to Check

### 1. Test Honesty — Can These Tests Actually Fail?

**Read each test and ask: "What real bug would make this fail?"**

Patterns that indicate dishonest tests:
- **Tautological assertions:** `let assert True = True`, `check(1 == 1, "math works")`
- **Testing the mock, not the system:** If a test mocks the database/transport/runtime, does it test the mock's behavior or the real system's behavior?
- **Over-mocking:** Tests that mock so much they're testing glue code, not logic
- **Assert on existence, not correctness:** `check("Count" in t, "counter renders")` — this passes even if the count is wrong. Should be `check("Count: 1" in t, ...)`
- **Happy path only:** Does the test only check the success case? What if the function returns Error?
- **No state verification:** Test calls a function but doesn't verify the resulting state changed correctly
- **Testing implementation, not behavior:** `check(list.length(msgs) == 3, ...)` — brittle, breaks on refactor
- **Smoke tests disguised as real tests:** A test that just calls a function and asserts it doesn't crash — this is a smoke test, not a behavior test. Fine to have, but don't count it as coverage.

**For each dishonest test found, report:**
```
[DISHONEST] test/brazier/foo_test.gleam:42 — test_bar_works
  Problem: Asserts html contains "div" — passes for ANY div, not just the right one
  Honest version: Assert specific content like "Count: 0" or check element structure
```

### 2. Test Gaps — What's NOT Tested?

**For each module in `src/brazier/`, check if there's a corresponding test file. Then check if the test file actually covers the important paths.**

Checklist per module:
- [ ] Happy path tested
- [ ] Error/failure path tested
- [ ] Edge cases tested (empty input, max size, unicode, concurrent access)
- [ ] Integration with neighbors tested (e.g., runtime + transport together)

**Critical gap patterns:**
- **No error path tests:** Module has `Result` returns but tests only check `Ok` cases
- **No concurrency tests:** Module uses actors/processes but tests are single-threaded
- **No boundary tests:** Module handles user input but tests only use hardcoded values
- **No reconnection tests:** Transport/runtime handle reconnect but no test simulates disconnect + reconnect
- **No state corruption tests:** Runtime holds mutable state but no test checks what happens with invalid state transitions
- **Untested generated code:** Codegen produces Gleam code — is that generated code tested, or just the generator?
- **Untested FFI:** `.erl` and `.mjs` files often have no direct tests — bugs hide here

**For each gap, report:**
```
[GAP] src/brazier/pubsub.gleam — No test for concurrent subscribe/unsubscribe race
  Risk: Two processes subscribing and unsubscribing simultaneously could corrupt subscriber list
  Suggested test: Spawn 10 processes, each subscribing/unsubscribing rapidly, verify final state
```

### 3. Outdated & Dead Tests

**Tests that no longer add value:**

- **Tests for removed features:** Check if tested functions/types still exist in the source
- **Duplicate tests:** Two tests that verify the exact same thing (search for identical assertion patterns)
- **Tests pinned to old behavior:** Tests that assert old behavior that's since changed — they pass because both code and test were updated together, but the test no longer catches regressions
- **Commented-out tests:** Dead code in test files
- **Tests with `todo`/`skip`:** Tests that were deferred and forgotten

**For each outdated test, report:**
```
[OUTDATED] test/brazier/diff_test.gleam:120 — test_old_patch_format
  Reason: The patch format changed in milestone 72, this test was updated to match
  but now just tests the same thing as test_new_patch_format on line 150.
  Action: Remove — duplicate coverage, adds maintenance burden
```

### 4. Simulation Test Quality

**File: `test/brazier/sim_test.gleam` + `test/brazier/sim/`**

Sim tests simulate multiple clients connecting and interacting. Check:

- **Are scenarios realistic?** Do they simulate real user behavior (click, wait, click) or just spam events?
- **Are metrics meaningful?** Does `assert_patch_efficiency()` have a real threshold, or does it pass for any non-zero value?
- **Timing sensitivity:** Do sim tests depend on `sleep` durations? Could they flake on slow CI?
- **Fault injection:** Do any sims test server crashes, network drops, or slow clients?
- **Load testing:** Are there sims that test with enough connections to find concurrency bugs? (10 is not enough — try 100+)
- **State verification:** After a sim runs, is the final model state verified? Or just "it didn't crash"?
- **Report accuracy:** Does the sim report (`test/brazier/sim/report.gleam`) actually check actionable things?

**Sim-specific patterns to flag:**
```
[WEAK-SIM] sim_test.gleam:245 — patch_efficiency scenario
  Problem: Asserts patches_received > 0 — passes if even 1 patch was sent in 100 events
  Better: Assert patches_received >= events_sent * 0.8 (at least 80% patch rate)
```

### 5. CDP Test Quality

**File: `test_all_cdp.py`**

CDP tests run in a real browser via Chrome DevTools Protocol. Check:

- **Timing reliability:** Are `sleep()` and `drain()` calls sufficient? Could a slow server cause false negatives?
- **Assertion specificity:** `"Count" in text()` vs `"Count: 1" in text()` — the former passes with wrong count
- **State isolation:** Do tests clean up between examples? Could state from test N leak into test N+1?
- **Multi-user tests:** Do they actually verify cross-session behavior, or just that the app doesn't crash?
- **Console error checking:** `errors() == "0"` is checked — but is it checked BEFORE state assertions? A JS error could cause the DOM to be stale.
- **Missing CDP tests:** Which examples have NO CDP test? Which features are only tested server-side?
- **Navigation testing:** Do CDP tests verify client-side navigation (pushState, popstate) or only full page loads?
- **Reconnection testing:** Does any CDP test verify WebSocket reconnection after disconnect?
- **Mobile/viewport testing:** Are tests only run at one viewport size?

**CDP-specific patterns to flag:**
```
[WEAK-CDP] test_all_cdp.py:265 — Kanban add card test
  Problem: Asserts "CDP Card" in text() after add — but doesn't verify it's in the right column
  Better: Check HTML structure to confirm card is in the Todo column specifically
```

### 6. Test Infrastructure Quality

- **Test helpers:** Are there shared helpers, or is test setup duplicated everywhere?
- **Test data builders:** Are test fixtures built with helpers (`make_route`, `make_config`) or inline?
- **Flake detection:** Are there any tests that sometimes fail? (Check git history for "retry", "flaky", "skip")
- **Test speed:** Which tests are slowest? Could they be faster without losing value?
- **Parallel safety:** Can all tests run in parallel? Or do some share state (ports, files, ETS tables)?

### 7. Coverage Analysis

Don't count lines — count behaviors:

- **For each public function:** Is there at least one test that calls it with valid input AND one that calls it with invalid input?
- **For each `case` branch:** Is every branch exercised by at least one test?
- **For each error type in `error.gleam`:** Is there a test that produces and handles each variant?
- **For each wire protocol message:** Is encoding AND decoding tested for every `ClientMessage` and `ServerMessage` variant?

## Output Format

```
[DISHONEST] file:line — test_name: Why this test provides false confidence
[GAP] module — What's missing and why it matters
[OUTDATED] file:line — test_name: Why this test no longer adds value
[WEAK-SIM] file:line — scenario: How the simulation could be more realistic
[WEAK-CDP] file:line — test: How the browser test could catch more bugs
[INFRA] issue: Test infrastructure improvement
```

At the end, summarize:
```
Test Quality Audit Results:
  Test files scanned: N
  Total tests: N (unit: N, sim: N, CDP: N)

  Dishonest tests: N (tests that can't meaningfully fail)
  Test gaps: N (untested behaviors that matter)
  Outdated tests: N (can be removed)
  Weak sim tests: N (simulations that don't simulate enough)
  Weak CDP tests: N (browser tests that don't verify enough)

  Confidence level: LOW / MEDIUM / HIGH
  Justification: [one paragraph on whether this test suite would catch a real regression]

  Top 3 highest-risk gaps:
  1. [gap description]
  2. [gap description]
  3. [gap description]
```
