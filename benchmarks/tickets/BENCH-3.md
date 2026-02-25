# BENCH-3: Improve test coverage

## Problem

The test suite only covers happy paths (5 tests). There are no tests for:

- Error cases (deleting non-existent task, completing non-existent task)
- Edge cases (empty store operations, special characters in title)
- The off-by-one bug in `complete()` after deletions
- Multiple sequential operations (add, delete, add again)

## Requirements

Add tests to improve coverage. Do NOT modify source code files (`tasktrack/store.py`, `tasktrack/cli.py`) - only add or modify test files.

## Acceptance Criteria

- [ ] At least 8 total test functions (currently 5)
- [ ] Source files (`tasktrack/store.py`, `tasktrack/cli.py`) unchanged
- [ ] All new tests pass (or explicitly test for known bugs with xfail)
