---
globs: ["**/*"]
---

# Context Budget Estimation

Estimate token usage before each phase to prevent context overflow. This rule works with `context-fidelity.md` to auto-adjust fidelity modes.

## Token Estimates by Content Type

| Content | Estimated Tokens |
|---------|-----------------|
| CLAUDE.md | ~500 |
| Phase0 summary | ~200 |
| Interrogation summary (executive) | ~100 |
| Interrogation summary (full) | ~1,000 |
| Single doc template (filled) | ~2,000 |
| All 11 docs | ~22,000 |
| Implementation plan | ~3,000 |
| Single phase output JSON | ~1,500 |
| Holdout scenario file | ~500 |
| Pipeline config + models | ~300 |

## Phase Budget Targets

| Phase | Target Utilization | Max Context Load |
|-------|-------------------|-----------------|
| phase0 | 20% | CLAUDE.md + git state |
| interrogate | 40% | CLAUDE.md + phase0 summary + MCP results |
| interrogation-review | 30% | Interrogation summary + transcript |
| generate-docs | 50% | Interrogation summary + templates (loaded one at a time) |
| doc-review | 30% | Documentation summary + spot-check 3-4 docs |
| implement | 50% | Documentation summary + specific doc sections + error context |
| verify | 20% | Step description + test output (ERROR-only) |
| holdout-validate | 40% | Holdout scenarios + code under test |
| security-audit | 30% | Source files (scanned, not loaded in full) |
| ship | 20% | Test results + PR template |

## Rules

1. **Before loading context**: estimate tokens using the table above
2. **If estimate > 60% of window**: downgrade fidelity one level (see context-fidelity.md)
3. **If estimate < 30% of window**: upgrade fidelity one level (agent has room)
4. **Never preload all docs**: load templates/docs one at a time, write output, release from context
5. **Large outputs go to disk**: anything > 200 lines writes to docs/artifacts/ and only a summary stays in context
6. **Error context is truncated**: only first 50 lines of error output carry forward to retry attempts

## Window Sizes

| Model | Raw Window | Effective Target |
|-------|-----------|-----------------|
| claude-opus-4-6 | 1M tokens | 200K tokens (target 40-60% = 80-120K) |
| claude-sonnet-4-5 | 200K tokens | 200K tokens (target 40-60% = 80-120K) |

The effective target is conservative to leave room for the model's own reasoning and tool outputs.

## Integration with Pipeline Harness

The `select_fidelity()` function in `run-pipeline.sh` reads estimated tokens and auto-adjusts:
- Downgrade: full -> summary:low -> summary:medium -> summary:high -> compact
- Upgrade: compact -> summary:high -> summary:medium -> summary:low
