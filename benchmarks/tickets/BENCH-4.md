# BENCH-4: Refactor with proper error handling

## Problem

The codebase has no structured error handling:

- `complete()` with an invalid ID raises confusing `IndexError`
- `add()` accepts any input without validation
- CLI shows raw Python tracebacks to users
- No custom exception types

## Requirements

### 1. Custom exceptions

Create `tasktrack/exceptions.py` with:
- `TaskNotFoundError(task_id)` - raised when looking up a missing task
- `ValidationError(message)` - raised on invalid input

### 2. Store validation

- `add()`: raise `ValidationError` if title is empty or longer than 200 characters
- `complete()`: raise `TaskNotFoundError` if task ID doesn't exist
- `delete()`: raise `TaskNotFoundError` if task ID doesn't exist

### 3. CLI error handling

- Catch `TaskNotFoundError` and `ValidationError` in CLI
- Print user-friendly error message (not traceback)
- Exit with code 1 on error

## Acceptance Criteria

- [ ] `tasktrack/exceptions.py` exists with both exception classes
- [ ] CLI catches custom exceptions and prints friendly errors
- [ ] Input validation on `add()` method
- [ ] Tests for error cases pass
