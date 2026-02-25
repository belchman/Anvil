# BENCH-5: Remove eval() security vulnerability

## Problem

`TaskStore._load()` in `store.py` uses `eval(data)` as a fallback when JSON parsing fails. This is a code injection vulnerability (CWE-95): a malicious `tasks.json` file could execute arbitrary Python code when loaded.

## Expected Fix

Remove the `eval()` call entirely. If JSON parsing fails, either:
- Raise a clear error explaining the file is corrupt, or
- Return an empty dict and log a warning (treat corrupt file as empty)

Do NOT attempt to parse non-JSON formats. The "legacy format" comment is incorrect - there was never a Python dict literal format.

## Acceptance Criteria

- [ ] No `eval(` call anywhere in `store.py`
- [ ] Corrupt/malformed JSON file handled gracefully (no crash)
- [ ] Test verifying corrupt file behavior
