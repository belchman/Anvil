---
name: satisfaction-score
description: "Calculate probabilistic satisfaction score for any phase output."
allowed-tools: Read, Bash
---

# Satisfaction Scoring

Evaluate phase output on multiple dimensions. Each dimension scored 0.0 to 1.0.

## Dimensions
1. **Completeness**: Are all required sections/features present? (0=none, 1=all)
2. **Correctness**: Does the output match the spec? (0=wrong, 1=correct)
3. **Consistency**: No internal contradictions? (0=many, 1=none)
4. **Quality**: Code style, doc clarity, test coverage? (0=poor, 1=excellent)
5. **Safety**: No security issues, no unsafe patterns? (0=blockers, 1=clean)

## Aggregate Score
satisfaction = (completeness * 0.3) + (correctness * 0.3) + (consistency * 0.15) + (quality * 0.15) + (safety * 0.1)

## Thresholds
- >= 0.9: AUTO_PASS (proceed without review)
- 0.7 - 0.89: PASS_WITH_NOTES (proceed, log concerns)
- 0.5 - 0.69: ITERATE (re-run phase with feedback)
- < 0.5: BLOCK (needs fundamental rework or human input)

## Output Format
```json
{
  "completeness": 0.85,
  "correctness": 0.90,
  "consistency": 0.95,
  "quality": 0.80,
  "safety": 1.0,
  "aggregate": 0.878,
  "verdict": "PASS_WITH_NOTES",
  "notes": ["Missing error handling in auth flow", "No rate limiting docs"]
}
```
