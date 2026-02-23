---
name: error-analysis
description: "Analyze error patterns across pipeline runs and generate fixes."
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Error Pattern Analysis

Scan all pipeline run logs for recurring error patterns.

## Process
1. Read all files matching docs/artifacts/pipeline-runs/*/verify-*.json
2. Extract error messages and failure reasons
3. Cluster similar errors (same file, same error type, same root cause)
4. For each cluster with 3+ occurrences:
   a. Identify the systemic cause
   b. Generate a prevention rule
   c. Add to .claude/rules/ as a new rule or append to existing
   d. If the fix is a code change, write it as a prescription in docs/artifacts/prescriptions/

## Output
- docs/artifacts/error-analysis-[date].md with full cluster analysis
- New/updated rules in .claude/rules/
- CLAUDE.md Absolute Rules updated if systemic (3+ occurrences)

This is the "Healer" pattern: observe, cluster, diagnose, prescribe, verify.
