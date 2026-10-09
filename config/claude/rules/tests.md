# Testing Requirements

## Test Value Bar

A test earns its place by protecting behavior a real regression would break.
Write one only when all four questions have an answer:

1. What observable behavior, invariant or contract does it protect?
2. What credible regression makes it fail?
3. Why does existing coverage not already catch that?
4. Does it need a production seam no production caller needs? If so, test at
   the real boundary instead.

Weak tests are not coverage: a smoke test, an existence check, or "it doesn't
throw" never counts as covering a path. A regression test is proven red against
the code before the fix, then green after it.

## Testing Workflow

Recommended workflow:
1. Write tests for new functionality
2. Run tests to verify they fail (if testing new code)
3. Implement functionality
4. Run tests to verify they pass
5. Refactor as needed while keeping tests green

## Troubleshooting Test Failures

1. Read error messages carefully
2. Check test isolation - tests should not share state
3. Verify mocks are correct
4. Fix implementation, not tests (unless tests are wrong)
5. Use debugger to trace execution flow

## Test Writing Guidelines

- **Fast**: Unit tests should run in <10ms
- **Isolated**: No shared state between tests
- **Deterministic**: Same input always produces same output
- **Readable**: Tests serve as documentation
- **Focused**: Test one thing per test case
