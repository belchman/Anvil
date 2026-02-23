---
globs: ["**/*"]
---

## Fidelity Modes (per-phase context loading)

When the pipeline runner loads context for a new phase, it uses one of six fidelity modes to control how much data from the previous phase carries forward:

| Mode | What loads | When to use |
|------|-----------|-------------|
| full | Entire previous phase output | Same thread, continuation |
| truncate | First + last N lines of output | Quick reference, long outputs |
| compact | Key-value pairs only (Tier 1) | Routing decisions, gate checks |
| summary:high | Executive summary only (5 lines) | Cross-phase handoff (default) |
| summary:medium | Executive + detailed (55 lines) | When next phase needs specifics |
| summary:low | Executive + detailed + file list | Implementation phases |

### Default Fidelity Per Phase
- phase0 → interrogate: summary:high (just project state)
- interrogate → interrogation-review: summary:medium (need to evaluate completeness)
- interrogation-review → generate-docs: summary:medium (need requirements detail)
- generate-docs → doc-review: summary:medium (need to evaluate doc quality)
- doc-review → holdout-generate: summary:low (need file-level specifics)
- holdout-generate → implement: summary:low (need file-level specifics)
- implement → verify: compact (just check results, don't re-read code)
- verify → implement (retry): truncate (first 50 lines of error output)
- verify → holdout-validate: compact (just pass/fail status)
- holdout-validate → security-audit: compact (just pass/fail status)
- security-audit → ship: compact (just pass/fail status)

### Fidelity Escalation
If a phase fails and needs more context, escalate one level:
compact → summary:high → summary:medium → summary:low → full

Never start at "full" unless explicitly resuming a session.

### How Tiers Map to Fidelity Modes (Reconciliation)
The three-tier storage system and six fidelity modes serve different purposes but MUST be aligned:

| Storage Tier | Fidelity Modes That Load It | Location |
|---|---|---|
| Tier 1 (Context) | compact, all summary modes | Memory MCP |
| Tier 2 (Summary) | summary:high loads Executive only, summary:medium loads Executive+Detailed, summary:low loads all | docs/summaries/ |
| Tier 3 (Artifact) | full, truncate (partial) | docs/artifacts/ |

The tiers define WHERE data lives. Fidelity modes define HOW MUCH of each tier loads into a new session. They are complementary, not competing.

### Context Budget Alignment
`context-budget.md` estimates tokens. Fidelity modes control what loads. They work together:
1. `context-budget.md` runs FIRST and estimates total tokens for the phase
2. If estimate exceeds 60% of context window, downgrade fidelity one level
3. If estimate is under 30%, upgrade fidelity one level (agent has room for more context)
4. The pipeline harness applies this automatically via the `select_fidelity()` function

Add to `run-pipeline.sh`:
```bash
select_fidelity() {
  local default_mode="$1"
  local estimated_tokens="${2:-0}"
  local window_size="${CONTEXT_WINDOW:-200000}"  # Opus 4.6 = 1M, but target 200K effective
  local utilization=$(echo "$estimated_tokens * 100 / $window_size" | bc)

  if [ "$utilization" -gt 60 ]; then
    # Downgrade fidelity
    case "$default_mode" in
      "full") echo "summary:low" ;;
      "summary:low") echo "summary:medium" ;;
      "summary:medium") echo "summary:high" ;;
      "summary:high") echo "compact" ;;
      *) echo "compact" ;;
    esac
  elif [ "$utilization" -lt 30 ]; then
    # Upgrade fidelity
    case "$default_mode" in
      "compact") echo "summary:high" ;;
      "summary:high") echo "summary:medium" ;;
      "summary:medium") echo "summary:low" ;;
      *) echo "$default_mode" ;;
    esac
  else
    echo "$default_mode"
  fi
}
```
