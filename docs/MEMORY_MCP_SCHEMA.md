# Memory MCP Entity Schema

All pipeline components MUST use these exact entity names.

## Pipeline State
- `pipeline_state`: enum [scanning, interrogating, documented, implementing, verifying, shipping, shipped, blocked, stagnated]
- `pipeline_ticket`: string (ticket ID)
- `pipeline_started`: ISO datetime
- `pipeline_cost`: float (cumulative USD)

## Phase Tracking
- `current_phase`: string (phase name)
- `current_step`: string (implementation step ID)
- `completed_steps`: JSON array of step IDs
- `blocked_steps`: JSON array of {step_id, reason, attempts}

## Verification State
- `verify_retry_count`: int (0-3, reset on step change)
- `verify_last_errors`: string (compressed, <500 chars)
- `verify_step_id`: string (step being verified)

## Project Context
- `project_type`: string (e.g., "node-typescript", "python-fastapi")
- `project_branch`: string (current git branch)
- `project_test_status`: enum [passing, failing, no-tests]
- `project_blocker_count`: int

## Quality Metrics
- `holdout_count`: int (total scenarios)
- `holdout_pass_rate`: float (0-1)
- `holdout_last_run`: ISO datetime
- `satisfaction_scores`: JSON object of phase scores

## Learnings
- `lessons_learned`: JSON array of {lesson, frequency, promoted}
- `error_clusters`: JSON array of {pattern, count, prescription}
