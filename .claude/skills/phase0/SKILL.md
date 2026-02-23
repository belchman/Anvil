---
name: phase0
description: "Context scan: git state, project type, TODOs, test status, blockers. Must run at session start."
allowed-tools: Read, Bash, Glob, Grep, Write, mcp__memory__*
---

# Phase 0: Context Scan

Run this at the start of every session. No exceptions.

## Steps

### 1. Git State
Gather current branch, uncommitted changes, and recent commits:
```bash
echo "=== Git State ==="
git branch --show-current 2>/dev/null || echo "not a git repo"
git status --porcelain 2>/dev/null | head -20
git log --oneline -10 2>/dev/null
```

### 2. Project Type Detection
Check for project markers and identify the tech stack:
- `package.json` -> Node.js (check for typescript, framework in dependencies)
- `pyproject.toml` or `requirements.txt` -> Python (check for framework)
- `go.mod` -> Go
- `Cargo.toml` -> Rust
- `pom.xml` or `build.gradle` -> Java/Kotlin
- `Gemfile` -> Ruby
- `composer.json` -> PHP
- `.csproj` or `*.sln` -> C#/.NET

Read the detected config file to identify framework (Next.js, FastAPI, Gin, etc.).

### 3. TODO/FIXME Count
Search for outstanding work markers:
```
grep -rn "TODO\|FIXME\|HACK\|XXX\|BROKEN" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" . | grep -v node_modules | grep -v .git
```
<!-- TODO: Adjust file extensions for your project's language -->

### 4. Test Status
Run a quick test check (dry-run or status only, do NOT run full suite):
- Node: check if `npm test` script exists in package.json
- Python: check if pytest/unittest configs exist
- Go: check for `*_test.go` files
- Rust: check for `#[test]` annotations

Report: tests exist (yes/no), last known status if available from Memory MCP.

### 5. Blocker Identification
Check for common blockers:
- Uncommitted merge conflicts (`grep -r "<<<<<<" --include="*.ts" --include="*.py" . | head -5`)
- Lock files indicating stuck processes
- Missing environment files (`.env` referenced but not present)
- Broken dependencies (`node_modules` missing when package.json exists)
- Pipeline kill switch (`.pipeline-kill` file)

### 6. Memory MCP Check
If Memory MCP is available, retrieve:
- `pipeline_state` - where the pipeline left off
- `project_type` - cached project type
- `current_step` - last implementation step
- `blocked_steps` - any known blockers
- `lessons_learned` - relevant lessons from prior runs

If Memory MCP is unavailable, check fallback files: `progress.txt`, `lessons.md`, `decisions.md`.

### 7. Prior Documentation Check
Check for existing pipeline docs:
- `docs/summaries/` - any existing summaries
- `docs/PRD.md` - existing spec work
- `docs/IMPLEMENTATION_PLAN.md` - existing plans
- `PROGRESS.md` - living progress file

## Output

Write `docs/summaries/phase0-summary.md` with this format:

```markdown
# Phase 0 Summary - [date]

## Project
- **Type**: [detected type, e.g., "node-typescript (Next.js)"]
- **Branch**: [current branch]
- **Uncommitted changes**: [count]

## Status
- **Tests**: [exist/missing] | [passing/failing/unknown]
- **TODOs**: [count]
- **Blockers**: [list or "none"]
- **Pipeline state**: [from Memory MCP or "fresh"]

## Prior Work
- [list existing docs/summaries found]

## Recommended Next Step
- [based on pipeline_state: if fresh -> interrogate, if documented -> implement, etc.]
```

Keep the summary under 20 lines. Update Memory MCP with: project_type, current_branch, test_status, blocker_count.
