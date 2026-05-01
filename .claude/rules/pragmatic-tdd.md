# Pragmatic TDD

Test-first discipline adapted from obra/superpowers, stripped of dogma. The goal is **signal**, not coverage.

## Test policy by bead type

### Bug beads — test first, always
1. Write a test that reproduces the bug (the test MUST fail on the current code)
2. Verify the test fails for the right reason (feature missing, not typo/import error)
3. Write the minimal fix
4. Verify the test passes
5. **Scan for the bug pattern class across the codebase** (`rg`/`grep` for the anti-pattern, not the specific line). The bug often lives in more than one site — inlined at callsites, duplicated in sibling helpers, or copy-pasted into similar code. Fix every matching site in the same bead, or file follow-up beads before closing. Your reproducing test should fail on every unfixed site; if it doesn't, the test is scoped too narrowly.

A test that reproduces the bug proves the fix addresses the actual failure mode — but only for the site the test exercises. Step 5 is what prevents the "fixed one of three, shipped two" failure mode.

### Feature beads — ACs become tests
1. Read the `--acceptance` criteria from the bead
2. Write failing tests that assert each AC (observable behavior, not internals)
3. Verify tests fail
4. Implement to make them pass
5. Verify all tests pass

### Refactor beads — safety net first
1. Check if behavioral tests already exist for the code being refactored
2. If not, write them BEFORE changing structure (test current behavior)
3. Refactor
4. Verify all behavioral tests still pass
The behavior shouldn't change — only the structure. Tests prove that.

### Story beads — same as feature beads
ACs become tests. Treat stories identically to feature beads.

### Spike beads — document findings, tests optional
Spikes are timeboxed investigations. The deliverable is knowledge, not code. If the spike produces prototype code that gets promoted to a feature, apply the feature test policy to the promoted work. If the spike is purely investigative, no tests required — the close reason documents findings.

### Decision / milestone beads — no tests required
Decisions are architecture decision records (ADRs). Milestones mark completion of related issues. Neither produces testable code.

### Epic beads — no direct tests
Epics are containers. Test policies apply to children, not the epic itself.

### Chore / config / docs beads — no tests required
Config changes, dependency updates, documentation, tooling. A test here is noise.

## Zero-signal test taxonomy — DO NOT WRITE THESE

1. **Testing mocks, not behavior.** `verify(mockService).fetchData(argX)` — proves the plumbing is connected, not that the feature works. If the mock changes, the test breaks. If the feature breaks, the test passes.

2. **Testing implementation details.** `expect(internalCache.size).toBe(3)` — breaks on any refactor, catches no real bugs. Tests should assert what the user/caller observes, not how the internals work.

3. **Testing what the type system enforces.** `expect(typeof getName()).toBe('string')` — TypeScript already does this. The test adds maintenance cost with zero signal.

4. **Tautological tests.** Agent writes `add(a, b) { return a + b }`, then writes `expect(add(2,3)).toBe(5)`. The test is a restatement of the implementation. It will never catch a real bug.

5. **Helper-only tests that skip the original callsite.** Fixing a bug by extracting or editing a pure helper and then testing the helper in isolation does not prove the bug is fixed at the callsite that triggered it. If the bug was reproduced via `foo()`, the regression test must drive `foo()` — or exercise the helper in the exact shape `foo()` uses it. Testing the helper alone leaves the original failure mode unprotected, and the fix may not even reach the callsite (e.g., if the callsite inlines the bug pattern rather than calling the helper). Pair this with step 5 of the bug-bead protocol to catch duplicated pattern sites.

**The guardrail:** If a test would pass whether or not the feature actually works correctly, it's zero signal. Don't write it.

## Evidence, not penance

The goal is proving the test catches the problem — not ritually deleting code. If the agent wrote implementation before the test, it can stash/revert the change, run the test, confirm it fails, then re-apply. The evidence that matters: the test fails without the fix and passes with it.
