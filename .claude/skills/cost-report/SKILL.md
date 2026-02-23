---
name: cost-report
description: "Show cost report for pipeline runs."
allowed-tools: Read, Bash, Glob
---

# Cost Report

Analyze historical pipeline run costs and provide actionable insights.

## Process

### Step 1: Discover Runs
Find all pipeline run directories:
```
docs/artifacts/pipeline-runs/*/costs.json
```

If no runs exist, report "No pipeline runs found" and exit.

### Step 2: Parse Each Run
For each `costs.json`, extract:
- **Date**: from directory name (YYYY-MM-DD-HHMM)
- **Ticket**: from `checkpoint.json` in same directory
- **Status**: from `checkpoint.json` (completed, blocked, needs_human, etc.)
- **Phases**: array of `{name, cost, turns}` from costs.json
- **Total cost**: sum of phase costs
- **Total turns**: sum of phase turns

### Step 3: Per-Run Report
Output a table for each run:
```
## Run: 2026-02-23-1430 | Ticket: FEAT-123 | Status: completed
| Phase              | Cost    | Turns | $/Turn |
|--------------------|---------|-------|--------|
| phase0             | $0.42   | 8     | $0.05  |
| interrogate        | $3.21   | 38    | $0.08  |
| ...                |         |       |        |
| **Total**          | $12.50  | 142   | $0.09  |
```

### Step 4: Cross-Run Summary
If multiple runs exist, output:
```
## Summary (N runs)
| Metric                    | Value   |
|---------------------------|---------|
| Total spend to date       | $XX.XX  |
| Average cost per run      | $XX.XX  |
| Cheapest run              | $XX.XX  |
| Most expensive run        | $XX.XX  |
| Most expensive phase (avg)| [name] ($XX.XX avg) |
| Average turns per run     | XXX     |
| Success rate              | X/N (XX%) |
```

### Step 5: Cost Optimization Insights
Flag potential optimizations:
- Any phase consistently using > 30% of the pipeline budget
- Phases with high turn counts but low output (potential stagnation)
- Review phases that cost more than generation phases (model assignment issue)
- Runs that hit cost ceiling or were killed

### Step 6: Model Cost Breakdown
If `pipeline.models.json` exists, show cost by model:
```
| Model                        | Total Cost | % of Spend |
|------------------------------|-----------|------------|
| claude-opus-4-6              | $XX.XX    | XX%        |
| claude-sonnet-4-5-20250929   | $XX.XX    | XX%        |
```

## Output Format
Print the full report to the terminal. No files are written (this is a read-only analysis).
