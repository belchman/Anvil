---
name: update-progress
description: "Update project progress file with living architecture and status."
allowed-tools: Read, Write, Bash, Glob, Grep, mcp__memory__*
---

# Update Progress

Maintain a living `PROGRESS.md` at the project root that serves as the canonical source of truth for pipeline state. This file is designed for both human review and agent consumption (following the C compiler project's living README pattern).

## When to Run
- After each pipeline phase completes
- After any manual implementation work
- When resuming a session (to understand current state)
- After healing or error analysis

## Process

### Step 1: Gather State
Read these sources (in order of priority):
1. `docs/artifacts/pipeline-runs/*/checkpoint.json` (most recent run)
2. `docs/summaries/` (all existing summaries)
3. `docs/IMPLEMENTATION_PLAN.md` (if exists -- to determine remaining steps)
4. `git log --oneline -10` (recent commits)
5. `git status --porcelain` (uncommitted work)
6. Memory MCP entities: `pipeline_state`, `current_step`, `completed_steps`, `blocked_steps`

### Step 2: Write PROGRESS.md
Write/overwrite `PROGRESS.md` at project root with these sections:

```markdown
# Progress - [project name]
Last updated: [ISO timestamp]

## Current State
- **Pipeline phase**: [phase name or "not started"]
- **Status**: [running | completed | blocked | needs_human | stagnated]
- **Current step**: [step ID and title, or N/A]
- **Cost so far**: $X.XX (of $MAX ceiling)

## Architecture
[Brief description of the code structure as it exists NOW. Updated as implementation proceeds. Include key directories, entry points, data flow. Max 15 lines.]

## Completed Work
- [x] [Step/phase] - [1-line description] ([commit hash])
- [x] ...

## In Progress
- [ ] [Current step] - [what's happening, any blockers]

## Recent Changes
| Date | Change | Commit |
|------|--------|--------|
| [date] | [description] | [hash] |
| ... (last 5 only) |

## Failed Approaches
[What was tried and didn't work. This prevents agents from repeating failed strategies.]
- [Approach]: [Why it failed] ([date])

## Known Issues
- [Issue description] - [severity: blocker/warning/info]

## Assumptions Made
[All [ASSUMPTION] items from interrogation, with confidence levels]
- [ASSUMPTION: description] (confidence: HIGH/MEDIUM/LOW)

## Remaining Work
[Steps left from IMPLEMENTATION_PLAN.md]
- [ ] [Step ID]: [title]
- [ ] ...
```

### Step 3: Update Memory MCP
If Memory MCP is available, update these entities:
- `pipeline_state`: current phase/status
- `current_step`: step ID being worked on
- `completed_steps`: comma-separated list of completed step IDs
- `blocked_steps`: any blocked steps with reason
- `active_blockers`: current blockers preventing progress
- `key_decisions`: important architectural or design decisions made
- `lessons_learned`: what worked, what didn't (append-only)

### Step 4: Update Fallback Files
If Memory MCP is unavailable, update these fallback files:
- `progress.txt`: single-line current state (e.g., "implement:step-3:running")
- `lessons.md`: append new lessons learned
- `decisions.md`: append new key decisions

## Output
- Updated `PROGRESS.md` at project root
- Updated Memory MCP entities (or fallback files)
- Print a 3-line status summary to the terminal

## Rules
- Never delete previous entries from "Failed Approaches" or "Lessons Learned" (append-only)
- Keep "Architecture" section under 15 lines (update, don't grow)
- "Recent Changes" shows only last 5 entries (rotate older ones out)
- If no git repo exists, skip commit hashes and git-dependent sections
