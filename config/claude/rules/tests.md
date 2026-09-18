# Testing Requirements

## Minimum Test Coverage: 80%

Test Types (ALL required):
1. **Unit Tests** - Individual functions, utilities, components
2. **Integration Tests** - API endpoints, database operations

## Testing Workflow

Recommended workflow:
1. Write tests for new functionality
2. Run tests to verify they fail (if testing new code)
3. Implement functionality
4. Run tests to verify they pass
5. Refactor as needed while keeping tests green
6. Verify coverage meets 80%+ target

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
