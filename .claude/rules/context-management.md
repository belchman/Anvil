---
globs: ["**/*"]
---

# Context Management

Keep context window utilization between 40-60%. Each pipeline phase starts a fresh session.

## Between Phases
- Write outputs to docs/artifacts/ (full) and docs/summaries/ (compact)
- Only carry summaries forward, not raw outputs
- Truncate error logs to first 50 lines
- Discard raw MCP content after extracting key facts

## Summary Format
- Executive: 5 lines (key decisions/outcomes)
- Detailed: up to 50 lines (findings, one per line)
- Reference: file path to full output

## Context Loading
Load the minimum context needed for each phase:
- Routing/gate phases: summaries only
- Implementation phases: summaries + relevant doc sections
- Verification: just pass/fail status from previous phase

If a phase fails, load more context on retry (escalate one level).
