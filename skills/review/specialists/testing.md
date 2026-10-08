# Testing Specialist Review Checklist

Scope: Always-on (every review)
Output: JSON objects, one finding per line. Schema:
{"severity":"CRITICAL|INFORMATIONAL","confidence":N,"path":"file","line":N,"category":"testing","summary":"...","fix":"...","fingerprint":"path:line:testing","specialist":"testing"}
Optional: line, fix, fingerprint, evidence, test_stub.
If no findings: output `NO FINDINGS` and nothing else.

---

## Categories

### Missing Negative-Path Tests
- New code paths that handle errors, rejections, or invalid input with NO corresponding test
- Guard clauses and early returns that are untested
- Error branches in try/catch, rescue, or error boundaries with no failure-path test
- Permission/auth checks that are asserted in code but never tested for the "denied" case

### Missing Edge-Case Coverage
- Boundary values: zero, negative, max-int, empty string, empty array, nil/null/undefined
- Single-element collections (off-by-one on loops)
- Unicode and special characters in user-facing inputs
- Concurrent access patterns with no race-condition test

### Test Isolation Violations
- Tests sharing mutable state (class variables, global singletons, DB records not cleaned up)
- Order-dependent tests (pass in sequence, fail when randomized)
- Tests that depend on system clock, timezone, or locale
- Tests that make real network calls instead of using stubs/mocks

### Flaky Test Patterns
- Timing-dependent assertions (sleep, setTimeout, waitFor with tight timeouts)
- Assertions on ordering of unordered results (hash keys, Set iteration, async resolution order)
- Tests that depend on external services (APIs, databases) without fallback
- Randomized test data without seed control

### Security Enforcement Tests Missing
- Auth/authz checks in controllers with no test for the "unauthorized" case
- Rate limiting logic with no test proving it actually blocks
- Input sanitization with no test for malicious input
- CSRF/CORS configuration with no integration test

### Coverage Gaps
- New public methods/functions with zero test coverage
- Changed methods where existing tests only cover the old behavior, not the new branch
- Utility functions called from multiple places but tested only indirectly
- A path whose only tests are weak (★ smoke/existence/trivial assertion, or a new test failing
  the value bar below) stays a coverage gap at its existing severity; a low-value test never
  closes a gap

### Low-value or implementation-coupled tests
Scope: tests and test-only production seams added or changed in the diff. Findings are
INFORMATIONAL, never CRITICAL, and never an auto-delete: recommend a rewrite at the owning
boundary, extending an existing test, or retiring the test with its reason.

A new or changed test passes the value bar only when all four answers exist (read its
`Value: protects=...; fails_when=...; why_new=...; seam=...` comment when the diff has one):
1. What observable behavior, invariant or independent contract does it protect?
2. What credible regression makes it fail?
3. Why does existing coverage not already catch that? Prefer adding a row to an existing table-driven test or shared fixture over a near-duplicate.
4. Does it need a production seam (export, flag, wrapper, injection hook) that no production caller needs? If yes, test at the real boundary instead.

Patterns:
- Assertion-free tests: the test calls the code and asserts nothing, or only that it did not throw
- Self-comparisons: the expected value is computed by the code under test, or is a copy of the
  actual value (`expect(f(x)).toEqual(f(x))`, a snapshot of a fixture the test also builds)
- Copied fixtures, inventories or export lists that restate the source instead of checking behavior
- Exact source, import or string greps that are not a declared contract
- Duplicate invocations of the same contract, or per-caller replays of a shared helper's tests
- Tests whose only job is keeping a test-only export, flag or wrapper alive
- Production code (exports, hooks, flags) added in the diff whose only callers are tests
- Mocks of the very component the test claims to protect

For the last two code patterns, check each symbol the diff adds or exports, only when it matches
`^[A-Za-z_][A-Za-z0-9_]*$`, with the symbol single-quoted, never interpolated unquoted:

```bash
git grep -n -F -w -e '<symbol>' -- . ':!test/' ':!tests/' ':!spec/' ':!**/__tests__/**' ':!**/*.test.*' ':!**/*.spec.*' ':!**/*_test.*' ':!**/test_*.py'
```

Put the command and hit count in `evidence` and mark it grep-only (it cannot see re-exports,
dynamic dispatch or generated code). If the symbol does not match or the search fails, record
"caller check unavailable" and keep the finding INFORMATIONAL with nothing proposed for deletion.

Retention bar (never flag): a test that independently enforces a public API, protocol, config,
migration, storage, security, platform, default, prompt-byte, generated-output (golden), package,
release or architecture contract; call order when order is observable; anything reachable from
the package entrypoint. Static or slow is not a reason to delete. Skip a test carrying a
`test-value: keep reason="<why>"` comment (any comment syntax); if any were skipped, report the
count and reasons as one INFORMATIONAL line.

### Regression test without red proof
- The diff adds a test named or commented as a regression test, and neither the commits nor
  the PR body show it failing before the fix and passing after it. A regression test that never
  demonstrably failed proves the mock, not the fix. INFORMATIONAL; ask for the record
  `Regression proof — fails before fix: yes · passes after fix: yes · passes at base: yes | n/a`.
- When the bug being fixed already existed on the base branch, the test command is known and
  the review is not in plan mode, check it: run the test against base in a scratch worktree (`git worktree add --detach <tmp>
  <base>`, copy the test and its fixtures in, run it, `git worktree remove --force <tmp>`). It
  must fail on its own assertion there. If it passes, the test does not catch the bug: report
  that, INFORMATIONAL, with the command and its output in `evidence`. A failure from a missing
  untracked dependency (`node_modules`, `.venv`, build output) is the scratch worktree, not the
  test: report "red proof unavailable" instead of a defect. In plan mode, do not create the
  worktree or run anything: put the command in `test_stub` and record "red proof not run (plan
  mode)" in `evidence`.
