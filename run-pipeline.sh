#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Interrogation Protocol v3.0 - Autonomous Pipeline Runner
#
# Usage:
#   ./run-pipeline.sh "TICKET-ID or feature description"
#   ./run-pipeline.sh "TICKET-ID" --resume docs/artifacts/pipeline-runs/2026-02-23-1430
#
# Exit codes:
#   0 = Pipeline complete, PR created
#   1 = Phase error or kill switch
#   2 = Needs human input
#   3 = Blocked after max retries / stalled
#   4 = Holdout validation failed
# ============================================================

# ---- Pre-flight Checks ----
for cmd in claude jq bc git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required command '$cmd' not found. Install it before running the pipeline."
    exit 1
  fi
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "[ERROR] Not inside a git repository. Run 'git init' first."
  exit 1
fi

# ---- Source Configuration (Step 4) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/pipeline.config.sh"

# ---- Arguments ----
if [ -z "${1:-}" ]; then
  echo "Usage: ./run-pipeline.sh TICKET-ID [--resume LOG_DIR]" >&2
  exit 1
fi
TICKET="$1"
DATE=$(date +%Y-%m-%d-%H%M)
LOG_DIR="docs/artifacts/pipeline-runs/${DATE}"
CHECKPOINT_FILE="${LOG_DIR}/checkpoint.json"
COST_LOG="${LOG_DIR}/costs.json"
TOTAL_COST=0

# ---- Resume Support (Step 6b) ----
RESUME_FROM=""
if [ "${2:-}" = "--resume" ] && [ -n "${3:-}" ]; then
  RESUME_FROM="$3"
  CHECKPOINT_DIR="$3"
  if [ -f "${CHECKPOINT_DIR}/checkpoint.json" ]; then
    RESUME_PHASE=$(jq -r '.current_phase' "${CHECKPOINT_DIR}/checkpoint.json")
    TOTAL_COST=$(jq -r '.total_cost' "${CHECKPOINT_DIR}/checkpoint.json")
    LOG_DIR="$CHECKPOINT_DIR"
    CHECKPOINT_FILE="${LOG_DIR}/checkpoint.json"
    COST_LOG="${LOG_DIR}/costs.json"
  else
    echo "[ERROR] No checkpoint found at ${CHECKPOINT_DIR}/checkpoint.json"
    exit 1
  fi
fi

mkdir -p "$LOG_DIR"

# Initialize cost log if not resuming
if [ -z "$RESUME_FROM" ]; then
  echo '{"phases":[],"total_cost":0,"status":"running","started":"'"$(date -Iseconds)"'"}' > "$COST_LOG"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] $1"; }
log_phase() { echo -e "\n${GREEN}========== $1 ==========${NC}\n"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# ---- Thread Management (Step 6) ----
# Thread IDs control session reuse:
#   Same thread_id = continue conversation (fidelity: full)
#   New thread_id = fresh session (fidelity: summary:high)
#   Fork thread_id = clone parent, branch (fidelity: summary:medium)

generate_thread_id() {
  echo "thread-$(date +%s)-$RANDOM"
}

declare -A PHASE_THREADS
PHASE_THREADS[phase0]=$(generate_thread_id)

# Fork a thread: copies parent summary into child input for context continuity
fork_thread() {
  local parent="$1"
  local child
  child=$(generate_thread_id)
  cp "${LOG_DIR}/${parent}-summary.md" "${LOG_DIR}/${child}-input.md" 2>/dev/null || true
  echo "$child"
}

# ---- Circuit Breakers (Step 1 + Step 8) ----

check_kill_switch() {
  if [ -f "$KILL_SWITCH_FILE" ]; then
    log_error "Kill switch activated. Stopping pipeline."
    log_error "Remove $KILL_SWITCH_FILE to re-enable."
    update_checkpoint "killed" "$1"
    exit 1
  fi
}

check_cost_ceiling() {
  if (( $(echo "$TOTAL_COST > $MAX_PIPELINE_COST" | bc -l) )); then
    log_error "Cost ceiling exceeded: \$${TOTAL_COST} > \$${MAX_PIPELINE_COST}"
    update_checkpoint "cost_exceeded" "$1"
    exit 1
  fi
}

# ---- Checkpoint Management (Step 1) ----

update_checkpoint() {
  local status="$1"
  local phase="${2:-unknown}"
  cat > "$CHECKPOINT_FILE" << EOF
{
  "status": "${status}",
  "current_phase": "${phase}",
  "ticket": "${TICKET}",
  "total_cost": ${TOTAL_COST},
  "timestamp": "$(date -Iseconds)",
  "log_dir": "${LOG_DIR}"
}
EOF
}

# ---- Resume Helper (Step 6b) ----
# Check if a phase should be skipped when resuming a previous run

PHASE_ORDER=(phase0 interrogate interrogation-review generate-docs doc-review holdout-generate implement holdout-validate security-audit ship)

should_run_phase() {
  local phase="$1"
  if [ -z "$RESUME_FROM" ]; then
    return 0  # Not resuming, run everything
  fi
  # Skip phases before the resume point
  if [ -n "${RESUME_PHASE:-}" ]; then
    local reached_resume=false
    for p in "${PHASE_ORDER[@]}"; do
      if [ "$p" = "${RESUME_PHASE}" ]; then
        reached_resume=true
      fi
      if [ "$p" = "$phase" ]; then
        if [ "$reached_resume" = false ]; then
          log "Skipping $phase (before resume point: $RESUME_PHASE)"
          return 1
        fi
        break
      fi
    done
  fi
  # Also skip if this specific phase completed in the cost log
  local completed
  completed=$(jq -r ".phases[] | select(.name==\"$phase\") | .name" "$COST_LOG" 2>/dev/null || true)
  if [ -n "$completed" ]; then
    log "Skipping $phase (already completed in previous run)"
    return 1
  fi
  return 0
}

# ---- Context Fidelity Selection (Step 11) ----
# Automatically adjusts fidelity based on estimated context utilization.
# Downgrades when > 60% of window used, upgrades when < 30%.

select_fidelity() {
  local default_mode="$1"
  local estimated_tokens="${2:-0}"
  local window_size="${CONTEXT_WINDOW:-200000}"  # Opus 4.6 = 1M, but target 200K effective

  if [ -z "$estimated_tokens" ] || [ "$estimated_tokens" = "0" ]; then
    echo "$default_mode"
    return
  fi

  local utilization
  utilization=$(echo "($estimated_tokens * 100) / $window_size" | bc -l | cut -d. -f1)

  if [ "$utilization" -gt 60 ]; then
    # Downgrade fidelity (less context)
    case "$default_mode" in
      "full") echo "truncate" ;;
      "truncate") echo "summary:low" ;;
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

# ---- Satisfaction Scoring (Step 14) ----
# Parse probabilistic satisfaction scores from review phase output.

parse_satisfaction() {
  local json_file="$1"
  local result
  result=$(jq -r '.result // ""' "$json_file" 2>/dev/null)
  echo "$result" | grep -oP '"aggregate"\s*:\s*\K[0-9.]+' || echo "0"
}

score_to_verdict() {
  local score="$1"
  if (( $(echo "$score >= 0.9" | bc -l) )); then echo "AUTO_PASS"
  elif (( $(echo "$score >= 0.7" | bc -l) )); then echo "PASS_WITH_NOTES"
  elif (( $(echo "$score >= 0.5" | bc -l) )); then echo "ITERATE"
  else echo "BLOCK"
  fi
}

# ---- Position Bias Mitigation (Step 14) ----
# For high-stakes review gates, run evaluation twice with swapped ordering
# and use the stricter verdict when they disagree.

run_review_with_bias_check() {
  local review_name="$1"
  local prompt_base="$2"
  local max_turns="$3"
  local max_budget="$4"
  local model="$5"

  # Pass 1: normal order
  run_phase "${review_name}-pass1" "$prompt_base" "$max_turns" "$max_budget" "--model $model"

  # Pass 2: reversed section order + different model for diversity
  local swapped_prompt="${prompt_base}

IMPORTANT: When evaluating sections, read them in REVERSE order (last section first). This reduces position bias."

  # Use a different model for pass 2 to maximize review diversity
  local pass2_model
  if [ "$model" = "$MODEL_REVIEW" ]; then
    pass2_model="$MODEL_IMPLEMENT"  # Cross-model diversity: use Opus if pass 1 was Sonnet
  else
    pass2_model="$MODEL_REVIEW"
  fi
  run_phase "${review_name}-pass2" "$swapped_prompt" "$max_turns" "$max_budget" "--model $pass2_model"

  # Compare verdicts - use stricter when they disagree
  local v1 v2
  v1=$(jq -r '.result // ""' "${LOG_DIR}/${review_name}-pass1.json" 2>/dev/null | grep -oP 'VERDICT: \K\w+' || echo "UNKNOWN")
  v2=$(jq -r '.result // ""' "${LOG_DIR}/${review_name}-pass2.json" 2>/dev/null | grep -oP 'VERDICT: \K\w+' || echo "UNKNOWN")

  if [ "$v1" = "$v2" ]; then
    echo "$v1"  # Consistent verdict
  else
    log_warn "Position bias detected: pass1=$v1, pass2=$v2. Using stricter verdict."
    if [ "$v1" = "FAIL" ] || [ "$v2" = "FAIL" ]; then echo "FAIL"
    elif [ "$v1" = "ITERATE" ] || [ "$v2" = "ITERATE" ]; then echo "ITERATE"
    elif [ "$v1" = "NEEDS_HUMAN" ] || [ "$v2" = "NEEDS_HUMAN" ]; then echo "NEEDS_HUMAN"
    else echo "$v1"
    fi
  fi
}

# ---- Graph-Based Routing (Step 6) ----
# Route to the next phase based on gate verdict and retry count.
# Follows the 5-step edge selection hierarchy from pipeline.graph.dot.

route_from_gate() {
  local gate="$1"
  local verdict="$2"
  local retries="${3:-0}"

  case "${gate}:${verdict}" in
    "interrogation-review:PASS"|"interrogation-review:AUTO_PASS"|"interrogation-review:PASS_WITH_NOTES")
      echo "generate-docs" ;;
    "interrogation-review:ITERATE")
      echo "interrogate" ;;
    "interrogation-review:NEEDS_HUMAN"|"interrogation-review:BLOCK")
      echo "BLOCKED" ;;
    "doc-review:PASS"|"doc-review:AUTO_PASS"|"doc-review:PASS_WITH_NOTES")
      echo "holdout-generate" ;;
    "doc-review:ITERATE")
      echo "generate-docs" ;;
    "verify:PASS"|"verify:AUTO_PASS"|"verify:PASS_WITH_NOTES")
      echo "next-step-or-holdout" ;;
    "verify:FAIL"|"verify:ITERATE")
      if [ "$retries" -ge "$MAX_VERIFY_RETRIES" ]; then
        echo "BLOCKED"
      else
        echo "implement"
      fi
      ;;
    "holdout-validate:PASS"|"holdout-validate:AUTO_PASS"|"holdout-validate:PASS_WITH_NOTES")
      echo "security-audit" ;;
    "holdout-validate:FAIL")
      echo "implement" ;;
    "security-audit:PASS"|"security-audit:AUTO_PASS"|"security-audit:PASS_WITH_NOTES")
      echo "ship" ;;
    "security-audit:FAIL")
      echo "implement" ;;
    *)
      echo "BLOCKED" ;;
  esac
}

# ---- Cross-Session Progress Tracking (Step 8) ----
# Detects when implementation phases fail to produce git commits,
# which indicates the agent may not be making real changes.

LAST_COMMIT=""
NO_PROGRESS_COUNT=0
# MAX_NO_PROGRESS loaded from pipeline.config.sh

check_git_progress() {
  local phase_name="$1"
  local current_commit
  current_commit=$(git rev-parse HEAD 2>/dev/null || echo "none")

  # Implementation and security-fix phases MUST produce commits
  if [[ "$phase_name" == implement* ]] || [[ "$phase_name" == security-fix* ]]; then
    if [ "$current_commit" = "$LAST_COMMIT" ] && [ "$LAST_COMMIT" != "" ]; then
      log_warn "No new git commits after $phase_name - agent may not have made changes"
      return 1
    fi
  fi

  LAST_COMMIT="$current_commit"
  return 0
}

after_phase() {
  local phase_name="$1"
  if ! check_git_progress "$phase_name"; then
    NO_PROGRESS_COUNT=$((NO_PROGRESS_COUNT + 1))
    if [ "$NO_PROGRESS_COUNT" -ge "$MAX_NO_PROGRESS" ]; then
      log_error "No git progress for $MAX_NO_PROGRESS consecutive implementation phases. Pipeline stalled."
      update_checkpoint "stalled_no_progress" "$phase_name"
      exit 3
    fi
  else
    NO_PROGRESS_COUNT=0
  fi
}

# ---- Phase Runner (Step 1 + Step 4 configs + Step 8 timeout) ----

run_phase() {
  local phase_name="$1"
  local prompt="$2"
  local max_turns="${3:-25}"
  local max_budget="${4:-5}"
  local extra_flags="${5:-}"

  check_kill_switch "$phase_name"
  check_cost_ceiling "$phase_name"
  log_phase "$phase_name"
  update_checkpoint "running" "$phase_name"

  local output_file="${LOG_DIR}/${phase_name}.json"

  # Determine timeout: use phase-specific timeout if defined, else default 600s
  # Strip attempt/step/version suffixes but preserve base phase name
  # e.g. "implement-step-1-attempt-2" → "IMPLEMENT", "generate-docs-v2" → "GENERATE_DOCS"
  local phase_timeout="${PHASE_TIMEOUT:-600}"
  local base_phase
  base_phase=$(echo "$phase_name" | sed 's/-v[0-9]*$//' | sed 's/-attempt-[0-9]*$//' | sed 's/-step-[0-9a-z-]*$//' | sed 's/-pass[0-9]*$//')
  local upper_phase
  upper_phase=$(echo "$base_phase" | tr '[:lower:]-' '[:upper:]_')
  local timeout_var="TIMEOUT_${upper_phase}"
  if [ -n "${!timeout_var:-}" ]; then
    phase_timeout="${!timeout_var}"
  fi

  # Run Claude in headless mode with structured output (Step 8: wrapped with timeout)
  set +e
  timeout "$phase_timeout" claude -p "$prompt" \
    --output-format json \
    --max-turns "$max_turns" \
    --max-budget-usd "$max_budget" \
    --permission-mode acceptEdits \
    $extra_flags \
    > "$output_file" 2>"${LOG_DIR}/${phase_name}.stderr"
  local exit_code=$?
  set -e

  # Handle timeout (exit code 124)
  if [ "$exit_code" -eq 124 ]; then
    log_error "Phase $phase_name timed out after ${phase_timeout}s"
    echo '{"result":"TIMEOUT","is_error":true,"total_cost_usd":0,"num_turns":0}' > "$output_file"
  fi

  # Extract cost and session info
  local phase_cost session_id is_error num_turns
  phase_cost=$(jq -r '.total_cost_usd // 0' "$output_file" 2>/dev/null || echo "0")
  session_id=$(jq -r '.session_id // "unknown"' "$output_file" 2>/dev/null || echo "unknown")
  is_error=$(jq -r '.is_error // false' "$output_file" 2>/dev/null || echo "false")
  num_turns=$(jq -r '.num_turns // 0' "$output_file" 2>/dev/null || echo "0")

  TOTAL_COST=$(echo "$TOTAL_COST + $phase_cost" | bc -l)

  # Log cost
  log "Phase: $phase_name | Cost: \$${phase_cost} | Turns: ${num_turns} | Total: \$${TOTAL_COST}"

  # Append to cost log (JSON)
  local tmp
  tmp=$(mktemp)
  jq --arg name "$phase_name" \
     --argjson cost "$phase_cost" \
     --arg sid "$session_id" \
     --argjson turns "$num_turns" \
     --argjson total "$TOTAL_COST" \
     '.phases += [{"name":$name,"cost":$cost,"session_id":$sid,"turns":$turns}] | .total_cost=$total' \
     "$COST_LOG" > "$tmp" && mv "$tmp" "$COST_LOG"

  # Check for errors
  if [ "$exit_code" -ne 0 ] || [ "$is_error" = "true" ]; then
    log_error "Phase $phase_name failed (exit=$exit_code, is_error=$is_error)"
    log_error "Check ${LOG_DIR}/${phase_name}.json and .stderr for details"
    return 1
  fi

  log "Phase $phase_name complete."
  return 0
}

# ---- Stagnation Detection (Step 1) ----
# Compares consecutive error outputs; >90% similarity suggests the agent
# is stuck in a loop producing the same errors repeatedly.

check_stagnation() {
  local phase_name="$1"
  local attempt="$2"

  if [ "$attempt" -gt 1 ]; then
    local prev="${LOG_DIR}/${phase_name}-attempt-$((attempt-1)).stderr"
    local curr="${LOG_DIR}/${phase_name}-attempt-${attempt}.stderr"
    if [ -f "$prev" ] && [ -f "$curr" ]; then
      # Compare checksums first (identical files = definite stagnation)
      local prev_sum curr_sum
      prev_sum=$(cksum "$prev" | awk '{print $1}')
      curr_sum=$(cksum "$curr" | awk '{print $1}')
      if [ "$prev_sum" = "$curr_sum" ]; then
        log_warn "Stagnation detected: attempt $attempt errors are identical to attempt $((attempt-1))"
        return 1
      fi
      # For non-identical files, check if diff is < 10% of total lines
      local diff_lines total
      diff_lines=$(diff "$prev" "$curr" | grep -c '^[<>]' || true)
      total=$(wc -l < "$curr")
      if [ "$total" -gt 0 ] && [ "$diff_lines" -lt $((total / 10)) ]; then
        log_warn "Stagnation detected: attempt $attempt errors are >90% similar to attempt $((attempt-1))"
        return 1
      fi
    fi
  fi
  return 0
}

# ============================================================
# PIPELINE EXECUTION
# ============================================================

log "Starting autonomous pipeline for: $TICKET"
if [ -n "$RESUME_FROM" ]; then
  log "Resuming from: $RESUME_FROM (phase: ${RESUME_PHASE:-unknown}, cost so far: \$${TOTAL_COST})"
fi
log "Max pipeline cost: \$${MAX_PIPELINE_COST}"
log "Kill switch file: $KILL_SWITCH_FILE"
log "Logs: $LOG_DIR"

# ---- Stage 1: Context Scan (Phase 0) ----

if should_run_phase "phase0"; then
  run_phase "phase0" \
    "You are running the Interrogation Protocol pipeline autonomously. Read CLAUDE.md first, then execute the phase0 context scan: scan git state, check Memory MCP for prior pipeline state, identify project type, TODOs, test status, blockers. Write a phase0-summary.md to docs/summaries/. Update Memory MCP with project_type, current_branch, test_status, blocker_count. Output must be under 20 lines." \
    "$TURNS_PHASE0" "$BUDGET_PHASE0" "--model $MODEL_PHASE0"
fi

# ---- Stage 2: Self-Interrogation ----

if should_run_phase "interrogate"; then
  run_phase "interrogate" \
    "You are running the Interrogation Protocol pipeline autonomously for ticket: ${TICKET}.

Read CLAUDE.md, then docs/summaries/phase0-summary.md for project context.

Execute the full interrogation protocol (all 13 sections from .claude/skills/interrogate/SKILL.md). You are in AUTONOMOUS MODE - there is no human to answer questions. For each section:
1. Search MCP sources (Jira, Confluence, Slack, Google Drive) for answers
2. Search the codebase (README, configs, existing code patterns)
3. If you find an answer from a source, record it with the source citation
4. If you cannot find an answer, make a REASONABLE ASSUMPTION based on context and mark it clearly as [ASSUMPTION: reason]

Write ALL fetched MCP content to docs/artifacts/mcp-context-${DATE}.md.
Write the full interrogation transcript to docs/artifacts/interrogation-${DATE}.md.
Generate a pyramid summary to docs/summaries/interrogation-summary.md with:
  - Executive: 5 lines (core problem, user, stack, key constraint, MVP)
  - Detailed: 50 lines (all requirements, one per line)
  - Assumptions: list all assumptions made with confidence level (high/medium/low)
Update Memory MCP with pipeline_state=interrogated." \
    "$TURNS_INTERROGATE" "$BUDGET_INTERROGATE" "--model $MODEL_INTERROGATE"
fi

# ---- Stage 3: LLM-as-Judge Review of Interrogation (Step 14: bias check) ----

if should_run_phase "interrogation-review"; then
  REVIEW_PROMPT="You are a REVIEWER agent. You did NOT write the interrogation output. Your job is to review it with fresh eyes.

Read docs/summaries/interrogation-summary.md and docs/artifacts/interrogation-${DATE}.md.

Evaluate:
1. Are all 13 sections addressed? List any gaps.
2. Are assumptions reasonable? Flag any that seem risky (mark NEEDS_HUMAN if critical).
3. Is there enough detail to generate implementation docs?
4. Are there contradictions between sections?

Score each section 1-5 (5=complete, 1=missing). Calculate overall satisfaction: (sum of scores) / (13 * 5) as a percentage.
Also output a JSON block with an \"aggregate\" field as a decimal (e.g. 0.78).

Write your review to docs/artifacts/interrogation-review-${DATE}.md.
Write a 10-line summary to docs/summaries/interrogation-review.md.

If overall satisfaction >= 70%: output VERDICT: PASS
If any section scores 1 or any assumption marked NEEDS_HUMAN: output VERDICT: NEEDS_HUMAN
Otherwise: output VERDICT: ITERATE

Always include VERDICT: [PASS|NEEDS_HUMAN|ITERATE] as the last line of your response."

  # Use bias-checked review for this high-stakes gate
  VERDICT=$(run_review_with_bias_check "interrogation-review" "$REVIEW_PROMPT" "$TURNS_REVIEW" "$BUDGET_REVIEW" "$MODEL_REVIEW")
  log "Interrogation review verdict: $VERDICT"

  NEXT=$(route_from_gate "interrogation-review" "$VERDICT")

  if [ "$NEXT" = "BLOCKED" ]; then
    log_error "Interrogation requires human input. Review: ${LOG_DIR}/interrogation-review-pass1.json"
    update_checkpoint "needs_human_interrogation" "interrogation-review"
    exit 2
  fi

  if [ "$NEXT" = "interrogate" ]; then
    log_warn "Interrogation needs iteration. Re-running with review feedback."
    run_phase "interrogate-v2" \
      "Re-run interrogation addressing the gaps identified in docs/summaries/interrogation-review.md. Focus on sections that scored below 3. Update docs/summaries/interrogation-summary.md and docs/artifacts/interrogation-${DATE}.md." \
      "$TURNS_INTERROGATE" "$BUDGET_INTERROGATE" "--model $MODEL_INTERROGATE"
  fi
fi

# ---- Stage 4: Document Generation (Step 13: Agent Teams with fallback) ----

if should_run_phase "generate-docs"; then
  # Detect Agent Teams support for parallel doc generation
  if claude --version 2>/dev/null | grep -q "agent-teams"; then
    run_phase "generate-docs-parallel" \
      "Run /parallel-docs to generate all documentation in parallel using Agent Teams. Read .claude/skills/parallel-docs/SKILL.md for the task breakdown." \
      60 15 "--model $MODEL_GENERATE_DOCS"
  else
    # Fallback: sequential generation (bash backgrounding is unreliable for claude -p)
    # TODO: When Agent Teams becomes GA, remove this fallback branch
    run_phase "generate-docs" \
      "You are running the Interrogation Protocol pipeline autonomously.

Read CLAUDE.md, then docs/summaries/interrogation-summary.md (Tier 2 - do NOT read the full interrogation transcript unless you need specific detail for a section).

Generate all applicable documents from docs/templates/:
- PRD.md, APP_FLOW.md, TECH_STACK.md, DATA_MODELS.md
- API_SPEC.md (if API project), FRONTEND_GUIDELINES.md (if frontend)
- IMPLEMENTATION_PLAN.md, TESTING_PLAN.md
- SECURITY_CHECKLIST.md, OBSERVABILITY.md, ROLLOUT_PLAN.md

Write each to docs/[name].md. For each doc:
1. Read the template from docs/templates/
2. Fill it from the interrogation summary
3. If detail needed, read specific sections from Tier 3 artifact
4. Do NOT keep all docs in conversation after writing them

After all docs are written:
1. Write docs/summaries/documentation-summary.md (pyramid format)
2. Update Memory MCP with pipeline_state=documented" \
      "$TURNS_GENERATE_DOCS" "$BUDGET_GENERATE_DOCS" "--model $MODEL_GENERATE_DOCS"
  fi
fi

# ---- Stage 5: Doc Review (LLM-as-Judge with bias check) ----

if should_run_phase "doc-review"; then
  DOC_REVIEW_PROMPT="You are a REVIEWER agent. Review the generated docs for completeness and consistency.

Read docs/summaries/documentation-summary.md for overview.
Spot-check 3-4 docs by reading them: docs/PRD.md, docs/IMPLEMENTATION_PLAN.md, docs/TESTING_PLAN.md, docs/DATA_MODELS.md.

Check:
1. Does PRD match interrogation requirements?
2. Does IMPLEMENTATION_PLAN have clear, ordered steps?
3. Does TESTING_PLAN cover critical paths?
4. Are there contradictions between docs?

Score overall satisfaction as a percentage and output a JSON block with an \"aggregate\" field.
If >= 80%: VERDICT: PASS
If < 80%: VERDICT: ITERATE with specific fixes needed.

Always include VERDICT: [PASS|ITERATE] as the last line."

  DOC_VERDICT=$(run_review_with_bias_check "doc-review" "$DOC_REVIEW_PROMPT" "$TURNS_REVIEW" "$BUDGET_REVIEW" "$MODEL_REVIEW")
  log "Doc review verdict: $DOC_VERDICT"

  DOC_NEXT=$(route_from_gate "doc-review" "$DOC_VERDICT")
  if [ "$DOC_NEXT" = "generate-docs" ]; then
    log_warn "Doc review needs iteration. Re-running doc generation with feedback."
    run_phase "generate-docs-v2" \
      "Re-generate docs addressing the gaps identified in docs/summaries/ review files. Focus on sections flagged as incomplete or contradictory." \
      "$TURNS_GENERATE_DOCS" "$BUDGET_GENERATE_DOCS" "--model $MODEL_GENERATE_DOCS"
  fi
fi

# ---- Stage 5b: Auto-Generate Holdouts (Step 16) ----
# Run between doc review and implementation so holdout scenarios exist
# before any code is written.

if should_run_phase "holdout-generate"; then
  if ! ls .holdouts/holdout-001-*.md 1>/dev/null 2>&1; then
    run_phase "holdout-generate" \
      "You are the HOLDOUT GENERATOR agent. You operate in COMPLETE ISOLATION from implementation.

Read docs/PRD.md, docs/APP_FLOW.md, docs/API_SPEC.md, and docs/DATA_MODELS.md.

Generate 8-12 adversarial test scenarios that:
- Test behavior IMPLIED but not explicitly stated in the spec
- Cover cross-feature interactions
- Test boundary conditions
- Validate security assumptions
- Check for reward-hacking anti-patterns (hardcoded returns, missing validation)

Write each to .holdouts/holdout-NNN-[slug].md using the standard format.
Start numbering at 001." \
      "$TURNS_HOLDOUT" "$BUDGET_HOLDOUT" "--model $MODEL_HOLDOUT"
  else
    log "Holdouts already exist, skipping generation."
  fi
fi

# ---- Stage 6: Implementation Loop ----

if should_run_phase "implement"; then
  # Read implementation steps from the plan
  IMPL_STEPS=$(claude -p "Read docs/IMPLEMENTATION_PLAN.md and output ONLY a JSON array of step objects: [{\"id\": \"step-1\", \"title\": \"...\", \"description\": \"...\"}]. Output valid JSON only, no markdown fences." \
    --output-format json --max-turns 5 --max-budget-usd 1 2>/dev/null | jq -r '.result // ""' | grep -oP '\[.*\]' || echo "[]")

  STEP_COUNT=$(echo "$IMPL_STEPS" | jq 'length' 2>/dev/null || echo "0")
  log "Implementation plan has $STEP_COUNT steps"

  if [ "$STEP_COUNT" -eq 0 ]; then
    log_error "No implementation steps found. Check docs/IMPLEMENTATION_PLAN.md exists and has steps."
    exit 1
  fi

  for i in $(seq 0 $((STEP_COUNT - 1))); do
    STEP_ID=$(echo "$IMPL_STEPS" | jq -r ".[$i].id")
    STEP_TITLE=$(echo "$IMPL_STEPS" | jq -r ".[$i].title")
    STEP_DESC=$(echo "$IMPL_STEPS" | jq -r ".[$i].description")

    log_phase "Implementing: $STEP_ID - $STEP_TITLE"

    for attempt in $(seq 1 "$MAX_VERIFY_RETRIES"); do
      check_kill_switch "implement-${STEP_ID}"
      check_cost_ceiling "implement-${STEP_ID}"

      # Get error context from previous attempt if retrying
      ERROR_CONTEXT=""
      if [ "$attempt" -gt 1 ]; then
        ERROR_CONTEXT="RETRY ATTEMPT ${attempt}/${MAX_VERIFY_RETRIES}. Previous error:
$(cat "${LOG_DIR}/verify-${STEP_ID}-attempt-$((attempt-1)).stderr" 2>/dev/null | head -50)"
      fi

      # Implement
      run_phase "implement-${STEP_ID}-attempt-${attempt}" \
        "You are implementing step ${STEP_ID}: ${STEP_TITLE}

Read CLAUDE.md for rules. Read docs/summaries/documentation-summary.md for context.
Read the specific doc sections relevant to this step.

Description: ${STEP_DESC}

${ERROR_CONTEXT}

Implement this step. Follow existing codebase patterns. Type everything. Handle all errors.
After implementation, run the project's type checker and linter to verify your changes compile.
Commit your changes with message: 'feat(${STEP_ID}): ${STEP_TITLE}'" \
        "$TURNS_IMPLEMENT" "$BUDGET_IMPLEMENT" "--model $MODEL_IMPLEMENT"

      # Track git progress after implementation
      after_phase "implement-${STEP_ID}-attempt-${attempt}"

      # Verify (Step 12: use FAST_TEST for retries 1-2, full suite for final attempt)
      set +e
      if [ "$attempt" -lt "$MAX_VERIFY_RETRIES" ]; then
        run_phase "verify-${STEP_ID}-attempt-${attempt}" \
          "You are a VERIFICATION agent. Verify that step ${STEP_ID} (${STEP_TITLE}) was implemented correctly.

Run all relevant checks in order (stop on first failure):
1. Type checking (tsc --noEmit / mypy / go vet / cargo clippy)
2. Linting (eslint / ruff / golint)
3. Tests: run scripts/agent-test.sh if it exists, otherwise run the project's test command
4. Build (npm run build / go build / cargo build)

If ALL pass: output VERDICT: PASS
If ANY fail: output VERDICT: FAIL with the specific error (first 50 lines only)

Always include VERDICT: [PASS|FAIL] as the last line." \
          "$TURNS_VERIFY" "$BUDGET_VERIFY" "--model $MODEL_VERIFY"
      else
        # Final attempt: full test suite
        run_phase "verify-${STEP_ID}-attempt-${attempt}" \
          "You are a VERIFICATION agent. Verify that step ${STEP_ID} (${STEP_TITLE}) was implemented correctly.

Run all relevant checks in order (stop on first failure):
1. Type checking (tsc --noEmit / mypy / go vet / cargo clippy)
2. Linting (eslint / ruff / golint)
3. Tests: run the FULL test suite (not sampled)
4. Build (npm run build / go build / cargo build)

If ALL pass: output VERDICT: PASS
If ANY fail: output VERDICT: FAIL with the specific error (first 50 lines only)

Always include VERDICT: [PASS|FAIL] as the last line." \
          "$TURNS_VERIFY" "$BUDGET_VERIFY" "--model $MODEL_VERIFY"
      fi
      set -e

      VERIFY_VERDICT=$(jq -r '.result // ""' "${LOG_DIR}/verify-${STEP_ID}-attempt-${attempt}.json" 2>/dev/null | grep -oP 'VERDICT: \K\w+' || echo "UNKNOWN")

      if [ "$VERIFY_VERDICT" = "PASS" ]; then
        log "Step $STEP_ID verified on attempt $attempt"
        break
      fi

      log_warn "Step $STEP_ID failed verification (attempt $attempt/$MAX_VERIFY_RETRIES)"

      # Check stagnation
      if ! check_stagnation "verify-${STEP_ID}" "$attempt"; then
        log_warn "Stagnation detected on step $STEP_ID."
        ERROR_CONTEXT="${ERROR_CONTEXT}
STAGNATION DETECTED: Your previous fix attempts are producing the same errors. Try a fundamentally different approach."
      fi

      if [ "$attempt" -eq "$MAX_VERIFY_RETRIES" ]; then
        log_error "Step $STEP_ID failed after $MAX_VERIFY_RETRIES attempts. Blocking."
        update_checkpoint "blocked" "verify-${STEP_ID}"
        echo "BLOCKED: Step ${STEP_ID} failed ${MAX_VERIFY_RETRIES} verification attempts." > "${LOG_DIR}/blocked-${STEP_ID}.txt"
        echo "See verify logs for details." >> "${LOG_DIR}/blocked-${STEP_ID}.txt"
        exit 3
      fi
    done
  done
fi

# ---- Stage 7: Holdout Validation ----

if should_run_phase "holdout-validate"; then
  if ls .holdouts/holdout-*.md 1>/dev/null 2>&1; then
    run_phase "holdout-validate" \
      "You are a HOLDOUT VALIDATION agent. Test the implementation against hidden scenarios.

Read each file in .holdouts/holdout-*.md. For each scenario:
1. Check if preconditions can be met in the current implementation
2. Walk through each step against the actual code
3. Evaluate each acceptance criterion (pass/fail)
4. Check each anti-pattern (triggered/clean)

Score: (satisfied scenarios / total scenarios) as percentage.
If >= 80% and 0 anti-pattern flags: VERDICT: PASS
If < 80% or any anti-pattern flags: VERDICT: FAIL with details.

Always include VERDICT: [PASS|FAIL] as the last line." \
      "$TURNS_HOLDOUT" "$BUDGET_HOLDOUT" "--model $MODEL_HOLDOUT"

    HOLDOUT_VERDICT=$(jq -r '.result // ""' "${LOG_DIR}/holdout-validate.json" 2>/dev/null | grep -oP 'VERDICT: \K\w+' || echo "UNKNOWN")
    HOLDOUT_NEXT=$(route_from_gate "holdout-validate" "$HOLDOUT_VERDICT")

    if [ "$HOLDOUT_NEXT" = "implement" ]; then
      log_error "Holdout validation failed. Review: ${LOG_DIR}/holdout-validate.json"
      update_checkpoint "holdout_failed" "holdout-validate"
      exit 4
    fi
  else
    log "No holdout scenarios found, skipping validation."
  fi
fi

# ---- Stage 8: Security Audit ----

if should_run_phase "security-audit"; then
  run_phase "security-audit" \
    "You are a SECURITY AUDITOR. Review the implementation for security issues.

Scan all source files for:
1. Hardcoded secrets, API keys, tokens
2. SQL injection, XSS, command injection vectors
3. Missing authentication/authorization checks
4. Insecure defaults (CORS *, debug mode)
5. Missing input validation
6. Sensitive data exposure in logs or errors

Severity levels: BLOCKER (must fix) | WARNING (should fix) | INFO (note)

If 0 BLOCKERs: VERDICT: PASS
If any BLOCKERs: VERDICT: FAIL with file:line and description

Always include VERDICT: [PASS|FAIL] as the last line." \
    "$TURNS_SECURITY" "$BUDGET_SECURITY" "--model $MODEL_SECURITY"

  SECURITY_VERDICT=$(jq -r '.result // ""' "${LOG_DIR}/security-audit.json" 2>/dev/null | grep -oP 'VERDICT: \K\w+' || echo "UNKNOWN")
  SECURITY_NEXT=$(route_from_gate "security-audit" "$SECURITY_VERDICT")

  if [ "$SECURITY_NEXT" = "implement" ]; then
    log_warn "Security audit found blockers. Attempting auto-fix."
    run_phase "security-fix" \
      "Read docs/artifacts/pipeline-runs/${DATE}/security-audit.json. Fix all BLOCKER-severity issues. Do not change functionality, only fix security issues. Commit with message 'fix(security): address audit findings'" \
      "$TURNS_IMPLEMENT" "$BUDGET_IMPLEMENT" "--model $MODEL_IMPLEMENT"
    after_phase "security-fix"
  fi
fi

# ---- Stage 9: Ship ----

if should_run_phase "ship"; then
  run_phase "ship" \
    "You are running the final SHIP phase.

Pre-flight checks:
1. Run full test suite one final time
2. Verify all implementation steps are committed
3. Verify no uncommitted changes (git status --porcelain)

If all pass, create a PR:
- Title: '${TICKET}: [generated title from PRD]'
- Body: built from docs/summaries/ (executive sections only)
- Include: test results, step count, holdout results if applicable

Push branch and create PR via gh CLI or GitHub MCP.
Update Memory MCP: pipeline_state=shipped

Output the PR URL as the last line." \
    "$TURNS_SHIP" "$BUDGET_SHIP" "--model $MODEL_SHIP"
fi

# ---- Final Cost Report ----

update_checkpoint "completed" "ship"

echo ""
log_phase "PIPELINE COMPLETE"
echo ""
log "Ticket: $TICKET"
log "Total cost: \$$(printf '%.2f' "$TOTAL_COST")"
log "Logs: $LOG_DIR"
log "Cost breakdown:"
jq -r '.phases[] | "  \(.name): $\(.cost) (\(.turns) turns)"' "$COST_LOG"
echo ""
log "Checkpoint: $CHECKPOINT_FILE"
log "Full cost log: $COST_LOG"
