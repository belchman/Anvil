---
name: heal
description: "Run the Healer agent to diagnose and fix systemic pipeline failures."
allowed-tools: Read, Write, Bash, Glob, Grep, Task, mcp__memory__*
---

# Run Healer

Diagnose and fix systemic pipeline failures by analyzing error patterns across runs. This skill delegates to the `healer` agent for the heavy lifting.

## When to Run
- After any pipeline run that ended in `blocked` or `stagnated` status
- After 3+ consecutive verify failures across different runs
- When cost per run exceeds 2x the historical average
- Manually, when you suspect systemic issues

## Process

### Step 1: Pre-Flight Check
1. Verify pipeline run logs exist at `docs/artifacts/pipeline-runs/`
2. Count total runs and failure counts
3. If fewer than 2 runs exist, report "Insufficient data for healing" and exit

### Step 2: Collect Error Evidence
Gather all failure data:
- Read `checkpoint.json` from each run to find failed/blocked/stagnated runs
- Read `*.stderr` files from failed phases
- Read verify JSON outputs for FAIL verdicts
- Read `blocked-*.txt` files for block reports
- Check Memory MCP for `lessons_learned` and `active_blockers` entities

### Step 3: Delegate to Healer Agent
Spawn the `healer` agent (via Task tool with `subagent_type: "healer"`) with this context:
- All collected error evidence (summarized, not raw -- follow compaction rules)
- Current rules from `.claude/rules/`
- Current pipeline config from `anvil.toml`

The healer agent runs its 7-step cycle:
1. **OBSERVE**: Read pipeline logs
2. **CLUSTER**: Group similar failures by error type, file, root cause
3. **DIAGNOSE**: Identify systemic issue per cluster
4. **INVESTIGATE**: Read relevant source code, configs, rules
5. **PRESCRIBE**: Write the fix (code, rule, or config change)
6. **APPLY**: Make changes and commit with `fix(healer): [description]`
7. **VERIFY**: Run relevant tests to confirm fix

### Step 4: Collect Results
The healer returns:
- Number of error clusters found
- Number of prescriptions applied
- Files changed (with paths)
- Verification results (pass/fail per prescription)

### Step 5: Post-Healing Validation
1. Run the project's test suite to check for regressions
2. If tests fail, revert the healer's commits and report the regression
3. If tests pass, update Memory MCP:
   - Add new `lessons_learned` entries for each fix
   - Clear resolved `active_blockers`
   - Update `heal_count` metric

### Step 6: Generate Report
Write `docs/artifacts/heal-report-[date].md` with:
- Clusters found and their descriptions
- Prescriptions applied (or skipped with rationale)
- Files changed
- Verification status
- Recommendations for pipeline config changes

## Safety Rules
- The healer fixes the PIPELINE, not the TARGET PROJECT
- Only modify: `.claude/rules/`, `.claude/skills/`, `anvil.toml`, `src/`, `scripts/`
- Never modify: `docs/templates/`, target project source code, `.holdouts/`
- Never increase budget ceilings without flagging it
- If a prescription requires architectural changes, flag it as `[NEEDS_HUMAN]` instead of applying
- Maximum 5 prescriptions per heal cycle (prevent cascading changes)
