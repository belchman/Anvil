---
globs: ["**/*"]
---

# Compaction Discipline (FIC Pattern)

Target: 40-60% context window utilization at all times.

## Rules
1. After any phase that produces output > 200 lines, generate a compacted artifact (< 200 lines)
2. Between Research/Plan/Implement phase boundaries, compact to a single artifact
3. Never carry raw MCP-fetched content across a phase boundary
4. If context estimate exceeds 60% of window, stop and compact before proceeding

## Compaction Triggers
- Output > 200 lines: compress to summary
- Phase boundary: write artifact + summary, start fresh
- Error log > 50 lines: compress to first 50 lines + error count
- MCP content: extract key facts, discard raw content

## Compaction Format
Every compacted artifact follows pyramid structure:
- Executive: 5 lines (key decisions/outcomes)
- Detailed: 50 lines (all findings, one per line)
- Reference: file path to full output

## Anti-patterns
- NEVER: carry full test output across phases
- NEVER: keep full Jira ticket text after extracting requirements
- NEVER: accumulate implementation history in conversation
- ALWAYS: write to disk first, then summarize into conversation
