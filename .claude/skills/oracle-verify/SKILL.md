---
name: oracle-verify
description: "Oracle verification: compare implementation against a known-good reference to pinpoint exactly what diverged."
allowed-tools: Read, Bash, Grep, Glob, Diff
argument-hint: "reference-branch or reference-directory"
---

# Oracle Verification

When standard verify fails repeatedly, use the Oracle pattern:

## Process
1. Identify the known-good reference:
   - Previous working commit: `git stash && npm test && git stash pop`
   - Reference branch: `git diff main..HEAD`
   - Reference implementation (if porting): compare file-by-file
2. For each failing test:
   a. Run the test against the reference (should pass)
   b. Run the test against current code (should fail)
   c. Diff the code paths touched by the test between reference and current
   d. The diff IS the bug location
3. Generate a targeted fix that aligns current code with reference behavior
4. Re-run only the specific failing test (fast feedback)

## When This Helps
- Refactoring: test suite was green, now it's red. The diff shows exactly what broke.
- Porting: reference implementation works, port doesn't. File-by-file comparison.
- Upgrades: old version works, new version doesn't. Behavior diff.

## When This Doesn't Help
- Greenfield (no reference exists)
- New features (nothing to compare against)
- The reference itself is wrong
