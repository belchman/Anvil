#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Interrogation Protocol v3.0 - Autonomous Pipeline Runner
#
# Usage:
#   ./run-pipeline.sh "TICKET-ID or feature description"
#   ./run-pipeline.sh "TICKET-ID" --resume ${ARTIFACTS_DIR}/pipeline-runs/2026-02-23-1430
#
# Exit codes:
#   0 = Pipeline complete, PR created
#   1 = Phase error or kill switch
#   2 = Needs human input
#   3 = Blocked after max retries / stalled
#   4 = Holdout validation failed
# ============================================================

# ---- Pre-flight Checks ----
for cmd in claude jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required command '$cmd' not found. Install it before running the pipeline."
    exit 1
  fi
done

# Optional dependencies with fallback
HAS_BC=false
if command -v bc &>/dev/null; then HAS_BC=true; fi
HAS_GH=false
if command -v gh &>/dev/null; then HAS_GH=true; fi
if [ "$HAS_BC" = false ]; then
  echo "[WARN] 'bc' not found. Using awk for floating-point math (less precise)."
fi
if [ "$HAS_GH" = false ]; then
  echo "[WARN] 'gh' not found. PR creation in ship phase will be skipped."
fi

# Portable floating-point math: uses bc if available, awk otherwise
float_calc() {
  if [ "$HAS_BC" = true ]; then
    echo "$1" | bc -l 2>/dev/null
  else
    awk "BEGIN { printf \"%.6f\", $1 }"
  fi
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "[ERROR] Not inside a git repository. Run 'git init' first."
  exit 1
fi

# ---- Source Configuration (Step 4) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/pipeline.config.sh"

# Validate numeric config values from pipeline.config.sh
while IFS='=' read -r _cfg_var _cfg_val; do
  case "$_cfg_var" in
    *_COMMAND|*_MODE|*_GATES|PIPELINE_TIER|ANVIL_VERSION) continue ;;
  esac
  if ! [[ "${!_cfg_var:-}" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "[ERROR] Config variable $_cfg_var is not numeric: '${!_cfg_var:-}'"
    exit 1
  fi
done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "${SCRIPT_DIR}/pipeline.config.sh")
unset _cfg_var _cfg_val

# ---- Defaults (override via env vars if needed) ----

# Directory paths
DOCS_DIR="${DOCS_DIR:-docs}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-docs/artifacts}"
SUMMARIES_DIR="${SUMMARIES_DIR:-docs/summaries}"
TEMPLATES_DIR="${TEMPLATES_DIR:-docs/templates}"
HOLDOUTS_DIR="${HOLDOUTS_DIR:-.holdouts}"
LOG_BASE_DIR="${LOG_BASE_DIR:-docs/artifacts/pipeline-runs}"

# Internal constants
KILL_SWITCH_FILE="${KILL_SWITCH_FILE:-.pipeline-kill}"
METRICS_FILE="${METRICS_FILE:-docs/artifacts/pipeline-metrics.json}"
MAX_NO_PROGRESS="${MAX_NO_PROGRESS:-3}"
CONTEXT_WINDOW="${CONTEXT_WINDOW:-200000}"
STAGNATION_SIMILARITY_THRESHOLD="${STAGNATION_SIMILARITY_THRESHOLD:-90}"
MAX_INTERROGATION_ITERATIONS="${MAX_INTERROGATION_ITERATIONS:-2}"
FIDELITY_UPGRADE_THRESHOLD="${FIDELITY_UPGRADE_THRESHOLD:-30}"
FIDELITY_DOWNGRADE_THRESHOLD="${FIDELITY_DOWNGRADE_THRESHOLD:-60}"
PHASE_ORDER="${PHASE_ORDER:-phase0 interrogate interrogation-review generate-docs doc-review write-specs holdout-generate implement holdout-validate security-audit ship}"

# Phase timeouts (seconds) — override individually via TIMEOUT_PHASE0=120 etc.
: "${TIMEOUT_PHASE0:=120}"
: "${TIMEOUT_INTERROGATE:=600}"
: "${TIMEOUT_REVIEW:=300}"
: "${TIMEOUT_GENERATE_DOCS:=600}"
: "${TIMEOUT_IMPLEMENT:=600}"
: "${TIMEOUT_VERIFY:=300}"
: "${TIMEOUT_SECURITY:=300}"
: "${TIMEOUT_HOLDOUT_GENERATE:=300}"
: "${TIMEOUT_HOLDOUT_VALIDATE:=300}"
: "${TIMEOUT_WRITE_SPECS:=300}"
: "${TIMEOUT_SHIP:=300}"

# ---- Helper Functions ----

# Portable timeout: use GNU timeout if available, otherwise a bash-based fallback
if command -v timeout &>/dev/null; then
  _timeout() { timeout "$@"; }
elif command -v gtimeout &>/dev/null; then
  _timeout() { gtimeout "$@"; }
else
  _timeout() {
    local duration="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$duration" && kill -TERM "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local exit_code=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return "$exit_code"
  }
fi

safe_jq() {
  local file="$1" query="$2" fallback="${3:-}"
  if [ ! -f "$file" ]; then
    echo "$fallback"
    return
  fi
  local result
  result=$(jq -r "$query" "$file" 2>/dev/null) || { echo "$fallback"; return; }
  if [ -z "$result" ] || [ "$result" = "null" ]; then
    echo "$fallback"
    return
  fi
  echo "$result"
}

validate_numeric() {
  local value="$1" fallback="${2:-0}"
  # Accept: 0, 1.5, .25 (bc output), -3.14
  if [[ "$value" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
    echo "$value"
  else
    echo "$fallback"
  fi
}

extract_verdict() {
  sed -n 's/.*VERDICT: \([A-Z_]*\).*/\1/p' | tail -1
}

# Model selection: reads from pipeline.models.json
get_model() {
  local phase="$1" key
  case "$phase" in
    phase0) key="routing" ;;
    interrogate|generate-docs*) key="generation" ;;
    interrogation-review|doc-review|verify*|ship) key="review" ;;
    implement*|security-fix) key="implementation" ;;
    security-audit) key="security" ;;
    holdout-generate) key="holdout_generate" ;;
    holdout-validate) key="holdout_validate" ;;
    write-specs) key="specification" ;;
    *) key="" ;;
  esac
  if [ -n "$key" ] && [ -f "${SCRIPT_DIR}/pipeline.models.json" ]; then
    safe_jq "${SCRIPT_DIR}/pipeline.models.json" ".overrides.${key}" \
      "$(safe_jq "${SCRIPT_DIR}/pipeline.models.json" ".default" "claude-opus-4-6")"
  else
    echo "claude-opus-4-6"
  fi
}

# Turn and budget lookups by phase category
get_turns() {
  case "$1" in
    phase0|verify*) echo "${TURNS_QUICK:-15}" ;;
    interrogate|generate-docs*|implement*) echo "${TURNS_LONG:-50}" ;;
    *) echo "${TURNS_MEDIUM:-25}" ;;
  esac
}

get_budget() {
  case "$1" in
    phase0|verify*|interrogation-review|doc-review|security-audit) echo "${BUDGET_LOW:-3}" ;;
    interrogate|generate-docs*|implement*) echo "${BUDGET_HIGH:-10}" ;;
    *) echo "${BUDGET_MEDIUM:-5}" ;;
  esac
}

# Guard: ensure no threshold is zero
for _t_var in THRESHOLD_AUTO_PASS THRESHOLD_PASS THRESHOLD_ITERATE THRESHOLD_DOC_REVIEW THRESHOLD_HOLDOUT; do
  if [ "${!_t_var:-0}" -eq 0 ] 2>/dev/null; then
    echo "[WARN] ${_t_var}=0 would break gates, setting to 60"
    eval "${_t_var}=60"
  fi
done
unset _t_var

# ---- Arguments ----
if [ -z "${1:-}" ]; then
  echo "Usage: ./run-pipeline.sh TICKET-ID [--tier TIER] [--resume LOG_DIR]" >&2
  exit 1
fi
TICKET="$1"
shift

# Parse optional flags
RESUME_FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)
      [ -n "${2:-}" ] || { echo "[ERROR] --tier requires a value (guard|nano|quick|lite|standard|full)" >&2; exit 1; }
      PIPELINE_TIER="$2"
      shift 2
      ;;
    --resume)
      [ -n "${2:-}" ] || { echo "[ERROR] --resume requires a LOG_DIR" >&2; exit 1; }
      RESUME_FROM="$2"
      shift 2
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

DATE=$(date +%Y-%m-%d-%H%M)
LOG_DIR="${LOG_BASE_DIR}/${DATE}"
CHECKPOINT_FILE="${LOG_DIR}/checkpoint.json"
COST_LOG="${LOG_DIR}/costs.json"
TOTAL_COST=0

# ---- Resume Support (Step 6b) ----
if [ -n "$RESUME_FROM" ]; then
  CHECKPOINT_DIR="$RESUME_FROM"
  if [ -f "${CHECKPOINT_DIR}/checkpoint.json" ]; then
    RESUME_PHASE=$(safe_jq "${CHECKPOINT_DIR}/checkpoint.json" '.current_phase' "phase0")
    TOTAL_COST=$(safe_jq "${CHECKPOINT_DIR}/checkpoint.json" '.total_cost' "0")
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

# Colors for output (disabled when not a terminal)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1"; }
log_phase() { printf '\n%s========== %s ==========%s\n\n' "$GREEN" "$1" "$NC"; }
log_warn() { printf '%s[WARN] %s%s\n' "$YELLOW" "$1" "$NC"; }
log_error() { printf '%s[ERROR] %s%s\n' "$RED" "$1" "$NC"; }

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
  local cost_exceeded
  cost_exceeded=$(float_calc "$TOTAL_COST > $MAX_PIPELINE_COST" | cut -d. -f1) || cost_exceeded=0
  cost_exceeded=$(validate_numeric "$cost_exceeded" "0")
  if [ "$cost_exceeded" -eq 1 ]; then
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

IFS=' ' read -ra PHASE_ORDER <<< "${PHASE_ORDER}"

should_run_phase() {
  local phase="$1"
  local known=false
  for p in "${PHASE_ORDER[@]}"; do
    if [ "$p" = "$phase" ]; then known=true; break; fi
  done
  if [ "$known" = false ]; then
    log_warn "Unknown phase name: $phase (not in PHASE_ORDER)"
  fi
  # Skip phases before the resume point (only when resuming)
  if [ -n "$RESUME_FROM" ] && [ -n "${RESUME_PHASE:-}" ]; then
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
  # Also skip if resuming and this specific phase completed in the cost log
  if [ -n "$RESUME_FROM" ]; then
    local completed
    completed=$(safe_jq "$COST_LOG" ".phases[] | select(.name==\"$phase\") | .name" "")
    if [ -n "$completed" ]; then
      log "Skipping $phase (already completed in previous run)"
      return 1
    fi
  fi
  # Tier filtering
  if ! tier_allows_phase "$phase"; then
    log "Skipping $phase (tier: ${RESOLVED_TIER:-${PIPELINE_TIER:-full}})"
    return 1
  fi
  # Doc generation mode filtering
  if [ "${DOC_TEMPLATES_MODE:-auto}" = "none" ]; then
    case "$phase" in
      generate-docs|doc-review) log "Skipping $phase (DOC_TEMPLATES_MODE=none)"; return 1 ;;
    esac
  fi
  # Human gate check (may exit with code 2 if approval needed)
  check_human_gate "$phase"
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
  utilization=$(float_calc "($estimated_tokens * 100) / $window_size" | cut -d. -f1)
  utilization=$(validate_numeric "$utilization" "50")

  if [ "$utilization" -gt "$FIDELITY_DOWNGRADE_THRESHOLD" ]; then
    # Downgrade fidelity (less context)
    case "$default_mode" in
      "full") echo "truncate" ;;
      "truncate") echo "summary:low" ;;
      "summary:low") echo "summary:medium" ;;
      "summary:medium") echo "summary:high" ;;
      "summary:high") echo "compact" ;;
      *) echo "compact" ;;
    esac
  elif [ "$utilization" -lt "$FIDELITY_UPGRADE_THRESHOLD" ]; then
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
  result=$(safe_jq "$json_file" '.result // ""' "")
  local score
  score=$(echo "$result" | sed -n 's/.*"aggregate"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1)
  score="${score:-0}"
  score=$(validate_numeric "$score" "0")
  echo "$score"
}

score_to_verdict() {
  local score="$1"
  local t_auto t_pass t_iterate
  t_auto=$(float_calc "${THRESHOLD_AUTO_PASS} / 100")
  t_pass=$(float_calc "${THRESHOLD_PASS} / 100")
  t_iterate=$(float_calc "${THRESHOLD_ITERATE} / 100")
  if (( $(float_calc "$score >= $t_auto" | cut -d. -f1) )); then echo "AUTO_PASS"
  elif (( $(float_calc "$score >= $t_pass" | cut -d. -f1) )); then echo "PASS_WITH_NOTES"
  elif (( $(float_calc "$score >= $t_iterate" | cut -d. -f1) )); then echo "ITERATE"
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

  # Standard/quick tier: single-pass review (skip bias check for speed)
  if [ "${RESOLVED_TIER:-full}" = "standard" ] || [ "${RESOLVED_TIER:-full}" = "quick" ]; then
    run_phase "${review_name}" "$prompt_base" "$max_turns" "$max_budget" "--model $model"
    local v1
    v1=$(safe_jq "${LOG_DIR}/${review_name}.json" '.result // ""' "" | extract_verdict)
    echo "${v1:-UNKNOWN}"
    return
  fi

  # Pass 1: normal order
  run_phase "${review_name}-pass1" "$prompt_base" "$max_turns" "$max_budget" "--model $model"

  # Pass 2: reversed section order + different model for diversity
  local swapped_prompt="${prompt_base}

IMPORTANT: When evaluating sections, read them in REVERSE order (last section first). This reduces position bias."

  # Use a different model for pass 2 to maximize review diversity
  local pass2_model review_model
  review_model="$(get_model interrogation-review)"
  if [ "$model" = "$review_model" ]; then
    pass2_model="$(get_model implement)"  # Cross-model diversity: use Opus if pass 1 was Sonnet
  else
    pass2_model="$review_model"
  fi
  run_phase "${review_name}-pass2" "$swapped_prompt" "$max_turns" "$max_budget" "--model $pass2_model"

  # Compare verdicts - use stricter when they disagree
  local v1 v2
  v1=$(safe_jq "${LOG_DIR}/${review_name}-pass1.json" '.result // ""' "" | extract_verdict)
  v1="${v1:-UNKNOWN}"
  v2=$(safe_jq "${LOG_DIR}/${review_name}-pass2.json" '.result // ""' "" | extract_verdict)
  v2="${v2:-UNKNOWN}"

  # External validator pass (optional 3rd-party review)
  local v_ext=""
  if [ -n "${REVIEW_VALIDATOR_COMMAND:-}" ]; then
    log "Running external review validator: $REVIEW_VALIDATOR_COMMAND"
    v_ext=$(cat "${LOG_DIR}/${review_name}-pass1.json" | $REVIEW_VALIDATOR_COMMAND 2>/dev/null | extract_verdict) || true
    v_ext="${v_ext:-UNKNOWN}"
    if [ "$v_ext" != "UNKNOWN" ]; then
      log "External validator verdict: $v_ext"
    fi
  fi

  # Reconcile verdicts — strictest wins
  local final_verdict
  if [ "$v1" = "$v2" ] && { [ -z "$v_ext" ] || [ "$v_ext" = "$v1" ] || [ "$v_ext" = "UNKNOWN" ]; }; then
    final_verdict="$v1"  # All agree
  else
    if [ "$v1" != "$v2" ]; then
      log_warn "Position bias detected: pass1=$v1, pass2=$v2. Using stricter verdict."
    fi
    if [ -n "$v_ext" ] && [ "$v_ext" != "UNKNOWN" ] && [ "$v_ext" != "$v1" ]; then
      log_warn "External validator disagrees: ext=$v_ext. Including in strictness check."
    fi
    # Collect all verdicts and pick strictest
    local all_verdicts="$v1 $v2 ${v_ext:-}"
    if echo "$all_verdicts" | grep -qw "FAIL"; then final_verdict="FAIL"
    elif echo "$all_verdicts" | grep -qw "ITERATE"; then final_verdict="ITERATE"
    elif echo "$all_verdicts" | grep -qw "NEEDS_HUMAN"; then final_verdict="NEEDS_HUMAN"
    else final_verdict="$v1"
    fi
  fi
  echo "$final_verdict"
}

# ---- Graph-Based Routing (Step 6) ----
# Route to the next phase based on gate verdict and retry count.
# Follows the 5-step edge selection hierarchy.

route_from_gate() {
  local gate="$1"
  local verdict="$2"
  local retries="${3:-0}"
  retries=$(validate_numeric "$retries" "0")

  case "${gate}:${verdict}" in
    "interrogation-review:PASS"|"interrogation-review:AUTO_PASS"|"interrogation-review:PASS_WITH_NOTES")
      echo "generate-docs" ;;
    "interrogation-review:ITERATE")
      echo "interrogate" ;;
    "interrogation-review:NEEDS_HUMAN"|"interrogation-review:BLOCK")
      echo "BLOCKED" ;;
    "doc-review:PASS"|"doc-review:AUTO_PASS"|"doc-review:PASS_WITH_NOTES")
      echo "write-specs" ;;
    "doc-review:ITERATE")
      echo "generate-docs" ;;
    "verify:PASS"|"verify:AUTO_PASS"|"verify:PASS_WITH_NOTES")
      echo "next-step-or-holdout" ;;  # Resolved by impl loop: next step or holdout-validate if all steps done
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
    *) log_warn "Unknown gate:verdict combination: ${gate}:${verdict}"; echo "BLOCKED" ;;
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
  current_commit=$(git rev-parse HEAD 2>/dev/null || echo "")

  # Implementation and security-fix phases MUST produce commits
  if [[ "$phase_name" == implement* ]] || [[ "$phase_name" == security-fix* ]]; then
    if [ "$current_commit" = "$LAST_COMMIT" ] && [ -n "$LAST_COMMIT" ]; then
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
  local phase_timeout="${PHASE_TIMEOUT:-$DEFAULT_TIMEOUT}"
  local base_phase="${phase_name%%-v[0-9]*}"
  base_phase="${base_phase%%-attempt-[0-9]*}"
  base_phase="${base_phase%%-step-[0-9a-z-]*}"
  base_phase="${base_phase%%-pass[0-9]*}"
  local upper_phase
  upper_phase=$(echo "$base_phase" | tr '[:lower:]-' '[:upper:]_')
  local timeout_var="TIMEOUT_${upper_phase}"
  if declare -p "$timeout_var" &>/dev/null; then
    phase_timeout="${!timeout_var}"
    phase_timeout=$(validate_numeric "$phase_timeout" "$DEFAULT_TIMEOUT")
  fi

  # Run Claude in headless mode with structured output (Step 8: wrapped with timeout)
  set +e
  _timeout "$phase_timeout" "$AGENT_COMMAND" -p "$prompt" \
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
  phase_cost=$(safe_jq "$output_file" '.total_cost_usd // 0' "0")
  session_id=$(safe_jq "$output_file" '.session_id // "unknown"' "unknown")
  is_error=$(safe_jq "$output_file" '.is_error // false' "false")
  num_turns=$(safe_jq "$output_file" '.num_turns // 0' "0")

  local new_total
  new_total=$(float_calc "$TOTAL_COST + $phase_cost") || new_total="$TOTAL_COST"
  TOTAL_COST=$(validate_numeric "$new_total" "$TOTAL_COST")

  # Log cost
  log "Phase: $phase_name | Cost: \$${phase_cost} | Turns: ${num_turns} | Total: \$${TOTAL_COST}"

  # Append to cost log (JSON)
  local tmp
  tmp=$(mktemp)
  trap "rm -f '$tmp'" RETURN
  if jq --arg name "$phase_name" \
     --argjson cost "${phase_cost}" \
     --arg sid "$session_id" \
     --argjson turns "${num_turns}" \
     --argjson total "${TOTAL_COST}" \
     '.phases += [{"name":$name,"cost":$cost,"session_id":$sid,"turns":$turns}] | .total_cost=$total' \
     "$COST_LOG" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$COST_LOG"
  else
    log_warn "Failed to update cost log for phase $phase_name"
    rm -f "$tmp"
  fi

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
      prev_sum=$(cksum "$prev" 2>/dev/null | awk '{print $1}')
      curr_sum=$(cksum "$curr" 2>/dev/null | awk '{print $1}')
      if [ "$prev_sum" = "$curr_sum" ]; then
        log_warn "Stagnation detected: attempt $attempt errors are identical to attempt $((attempt-1))"
        return 1
      fi
      # For non-identical files, check if diff is < 10% of total lines
      local diff_lines total
      diff_lines=$(diff "$prev" "$curr" 2>/dev/null | grep -c '^[<>]' || true)
      total=$(wc -l < "$curr")
      if [ "$total" -gt 0 ] && [ "$diff_lines" -lt $((total / 10)) ]; then
        log_warn "Stagnation detected: attempt $attempt errors are >90% similar to attempt $((attempt-1))"
        return 1
      fi
    fi
  fi
  return 0
}

# ---- Human Gate Check ----
# If a phase is listed in HUMAN_GATES, check whether a human has approved it.
# Approval is signaled by the existence of ${LOG_DIR}/${phase}.human-approved

check_human_gate() {
  local phase="$1"
  if [ -z "${HUMAN_GATES:-}" ]; then
    return 0  # No human gates configured
  fi
  # Check if this phase is in the comma-separated HUMAN_GATES list
  case ",$HUMAN_GATES," in
    *,"$phase",*)
      if [ -f "${LOG_DIR}/${phase}.human-approved" ]; then
        log "Human gate for $phase: approved"
        return 0
      else
        log_warn "Human gate: $phase requires human approval before proceeding."
        log_warn "Review output in ${LOG_DIR}/, then: touch ${LOG_DIR}/${phase}.human-approved"
        log_warn "Resume with: ./run-pipeline.sh \"$TICKET\" --resume $LOG_DIR"
        update_checkpoint "needs_human_gate" "$phase"
        exit 2
      fi
      ;;
  esac
  return 0
}

# ---- Tier-Based Phase Filtering ----
RESOLVED_TIER=""

tier_allows_phase() {
  local phase="$1"

  # Resolve tier once (after phase0 runs)
  if [ -z "$RESOLVED_TIER" ]; then
    RESOLVED_TIER="${PIPELINE_TIER:-full}"
    if [ "$RESOLVED_TIER" = "auto" ]; then
      local scope
      scope=$(safe_jq "${LOG_DIR}/phase0.json" '.result // ""' "" | sed -n 's/.*SCOPE: \([1-5]\).*/\1/p' | tail -1)
      scope=$(validate_numeric "$scope" "3")
      if [ "$scope" -le 1 ]; then RESOLVED_TIER="nano"
      elif [ "$scope" -le 2 ]; then RESOLVED_TIER="lite"
      elif [ "$scope" -le 3 ]; then RESOLVED_TIER="standard"
      else RESOLVED_TIER="full"
      fi
      log "Auto-tier: scope=$scope → tier=$RESOLVED_TIER"
    fi
  fi

  case "$RESOLVED_TIER" in
    guard)
      # Guard tier: context scan + security audit + ship only (validates existing code, no implementation)
      case "$phase" in
        interrogate|interrogation-review|generate-docs|doc-review|write-specs|holdout-generate|implement*|holdout-validate) return 1 ;;
      esac ;;
    nano)
      case "$phase" in
        interrogate|interrogation-review|generate-docs|doc-review|write-specs|holdout-generate|holdout-validate|security-audit) return 1 ;;
      esac ;;
    quick)
      case "$phase" in
        write-specs|holdout-generate|holdout-validate|security-audit) return 1 ;;
      esac ;;
    lite)
      case "$phase" in
        generate-docs|doc-review|interrogation-review|security-audit) return 1 ;;
      esac ;;
    standard)
      case "$phase" in
        holdout-generate|holdout-validate) return 1 ;;
      esac ;;
    full) ;;
  esac
  return 0
}

# ============================================================
# PIPELINE EXECUTION
# ============================================================

log "Anvil v${ANVIL_VERSION:-unknown} - Autonomous Pipeline Runner"
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
    "You are running the Interrogation Protocol pipeline autonomously. Read CLAUDE.md first, then execute the phase0 context scan: scan git state, check Memory MCP for prior pipeline state, identify project type, TODOs, test status, blockers. Write a phase0-summary.md to ${SUMMARIES_DIR}/. Update Memory MCP with project_type, current_branch, test_status, blocker_count.

After your scan, estimate the scope of the change on a 1-5 scale:
1 = trivial (typo, config change, <10 lines)
2 = small (single function/component, <50 lines)
3 = medium (multiple files, new feature, <200 lines)
4 = large (cross-cutting, new subsystem, <500 lines)
5 = massive (architectural change, >500 lines)
Output SCOPE: N (where N is 1-5) in your response.

Output must be under 20 lines." \
    "$(get_turns phase0)" "$(get_budget phase0)" "--model $(get_model phase0)"
fi

# ---- Stage 2: Self-Interrogation ----

if should_run_phase "interrogate"; then
  run_phase "interrogate" \
    "You are running the Interrogation Protocol pipeline autonomously for ticket: ${TICKET}.

Read CLAUDE.md, then ${SUMMARIES_DIR}/phase0-summary.md for project context.

Execute the full interrogation protocol (all 13 sections from .claude/skills/interrogate/SKILL.md). You are in AUTONOMOUS MODE - there is no human to answer questions. For each section:
1. Search MCP sources (Jira, Confluence, Slack, Google Drive) for answers
2. Search the codebase (README, configs, existing code patterns)
3. If you find an answer from a source, record it with the source citation
4. If you cannot find an answer, make a REASONABLE ASSUMPTION based on context and mark it clearly as [ASSUMPTION: reason]

Write ALL fetched MCP content to ${ARTIFACTS_DIR}/mcp-context-${DATE}.md.
Write the full interrogation transcript to ${ARTIFACTS_DIR}/interrogation-${DATE}.md.
Generate a pyramid summary to ${SUMMARIES_DIR}/interrogation-summary.md with:
  - Executive: 5 lines (core problem, user, stack, key constraint, MVP)
  - Detailed: 50 lines (all requirements, one per line)
  - Assumptions: list all assumptions made with confidence level (high/medium/low)
Update Memory MCP with pipeline_state=interrogated." \
    "$(get_turns interrogate)" "$(get_budget interrogate)" "--model $(get_model interrogate)"
fi

# ---- Stage 3: LLM-as-Judge Review of Interrogation (Step 14: bias check) ----

if should_run_phase "interrogation-review"; then
  REVIEW_PROMPT="You are a REVIEWER agent. You did NOT write the interrogation output. Your job is to review it with fresh eyes.

Read ${SUMMARIES_DIR}/interrogation-summary.md and ${ARTIFACTS_DIR}/interrogation-${DATE}.md.

Evaluate:
1. Are all 13 sections addressed? List any gaps.
2. Are assumptions reasonable? Flag any that seem risky (mark NEEDS_HUMAN if critical).
3. Is there enough detail to generate implementation docs?
4. Are there contradictions between sections?

Score each section 1-5 (5=complete, 1=missing). Calculate overall satisfaction: (sum of scores) / (13 * 5) as a percentage.
Also output a JSON block with an \"aggregate\" field as a decimal (e.g. 0.78).

Write your review to ${ARTIFACTS_DIR}/interrogation-review-${DATE}.md.
Write a 10-line summary to ${SUMMARIES_DIR}/interrogation-review.md.

If overall satisfaction >= 70%: output VERDICT: PASS
If any section scores 1 or any assumption marked NEEDS_HUMAN: output VERDICT: NEEDS_HUMAN
Otherwise: output VERDICT: ITERATE

Always include VERDICT: [PASS|NEEDS_HUMAN|ITERATE] as the last line of your response."

  # Use bias-checked review for this high-stakes gate
  VERDICT=$(run_review_with_bias_check "interrogation-review" "$REVIEW_PROMPT" "$(get_turns interrogation-review)" "$(get_budget interrogation-review)" "$(get_model interrogation-review)")
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
      "Re-run interrogation addressing the gaps identified in ${SUMMARIES_DIR}/interrogation-review.md. Focus on sections that scored below 3. Update ${SUMMARIES_DIR}/interrogation-summary.md and ${ARTIFACTS_DIR}/interrogation-${DATE}.md." \
      "$(get_turns interrogate)" "$(get_budget interrogate)" "--model $(get_model interrogate)"
  fi
fi

# ---- Stage 4: Document Generation (Step 13: Agent Teams with fallback) ----

if should_run_phase "generate-docs"; then
  # Detect Agent Teams support for parallel doc generation
  if "$AGENT_COMMAND" --version 2>/dev/null | grep -q "agent-teams"; then
    run_phase "generate-docs-parallel" \
      "Run /parallel-docs to generate all documentation in parallel using Agent Teams. Read .claude/skills/parallel-docs/SKILL.md for the task breakdown." \
      60 15 "--model $(get_model generate-docs)"
  else
    # Fallback: sequential generation (bash backgrounding is unreliable for claude -p)
    # Sequential doc generation: Agent Teams not detected
    # Determine template selection mode
    TEMPLATES_INSTRUCTION=""
    case "${DOC_TEMPLATES_MODE:-auto}" in
      minimal)
        TEMPLATES_INSTRUCTION="Generate ONLY these core documents from ${TEMPLATES_DIR}/:
- PRD.md (required)
- IMPLEMENTATION_PLAN.md (required)
- TESTING_PLAN.md (required)
Skip all other templates." ;;
      all)
        TEMPLATES_INSTRUCTION="Generate ALL documents from ${TEMPLATES_DIR}/:
- PRD.md, APP_FLOW.md, TECH_STACK.md, DATA_MODELS.md
- API_SPEC.md, FRONTEND_GUIDELINES.md
- IMPLEMENTATION_PLAN.md, TESTING_PLAN.md
- SECURITY_CHECKLIST.md, OBSERVABILITY.md, ROLLOUT_PLAN.md" ;;
      *)  # auto
        TEMPLATES_INSTRUCTION="Generate documents ADAPTIVELY based on the project type detected in phase0:
- ALWAYS generate: PRD.md, IMPLEMENTATION_PLAN.md, TESTING_PLAN.md
- Generate APP_FLOW.md if the project has a user-facing interface
- Generate API_SPEC.md if the project exposes or consumes APIs
- Generate DATA_MODELS.md if the project has a data layer or database
- Generate FRONTEND_GUIDELINES.md only if the project has a frontend
- Generate TECH_STACK.md if the project uses multiple technologies
- Generate SECURITY_CHECKLIST.md if the project handles auth, payments, or PII
- Generate OBSERVABILITY.md if the project is a service or backend
- Generate ROLLOUT_PLAN.md if the project needs staged deployment
- SKIP templates that are not relevant to this project type. Do not generate empty or placeholder docs." ;;
    esac

    run_phase "generate-docs" \
      "You are running the Interrogation Protocol pipeline autonomously.

Read CLAUDE.md and CONTRIBUTING_AGENT.md (process rules), then ${SUMMARIES_DIR}/interrogation-summary.md (Tier 2 - do NOT read the full interrogation transcript unless you need specific detail for a section).

${TEMPLATES_INSTRUCTION}

BDD REQUIREMENT: Every feature in PRD.md MUST include acceptance criteria in Given/When/Then (Gherkin) format. TESTING_PLAN.md MUST include executable specifications derived from these acceptance criteria.

Write each to docs/[name].md. For each doc:
1. Read the template from ${TEMPLATES_DIR}/
2. Fill it from the interrogation summary
3. If detail needed, read specific sections from Tier 3 artifact
4. Do NOT keep all docs in conversation after writing them

After all docs are written:
1. Write ${SUMMARIES_DIR}/documentation-summary.md (pyramid format)
2. Update Memory MCP with pipeline_state=documented" \
      "$(get_turns generate-docs)" "$(get_budget generate-docs)" "--model $(get_model generate-docs)"
  fi
fi

# ---- Stage 5: Doc Review (LLM-as-Judge with bias check) ----

if should_run_phase "doc-review"; then
  DOC_REVIEW_PROMPT="You are a REVIEWER agent. Review the generated docs for completeness and consistency.

Read ${SUMMARIES_DIR}/documentation-summary.md for overview.
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

  DOC_VERDICT=$(run_review_with_bias_check "doc-review" "$DOC_REVIEW_PROMPT" "$(get_turns doc-review)" "$(get_budget doc-review)" "$(get_model doc-review)")
  log "Doc review verdict: $DOC_VERDICT"

  DOC_NEXT=$(route_from_gate "doc-review" "$DOC_VERDICT")
  if [ "$DOC_NEXT" = "generate-docs" ]; then
    log_warn "Doc review needs iteration. Re-running doc generation with feedback."
    run_phase "generate-docs-v2" \
      "Re-generate docs addressing the gaps identified in ${SUMMARIES_DIR}/ review files. Focus on sections flagged as incomplete or contradictory." \
      "$(get_turns generate-docs)" "$(get_budget generate-docs)" "--model $(get_model generate-docs)"
  fi
fi

# ---- Stage 5b: Write Executable Specifications (Cross-Model BDD) ----

if should_run_phase "write-specs"; then
  run_phase "write-specs" \
    "You are a SPECIFICATION WRITER. You will NOT implement any code.

Read CLAUDE.md and CONTRIBUTING_AGENT.md (process rules).
Read docs/PRD.md, docs/IMPLEMENTATION_PLAN.md, docs/TESTING_PLAN.md.

For each step in IMPLEMENTATION_PLAN.md:
1. Write executable test specifications (Given/When/Then from PRD acceptance criteria)
2. Write test files that encode these specifications
3. Run them to confirm they FAIL (RED phase of BDD)
4. Commit failing specs: 'test(spec): RED specs for [step]'

You must NOT write any implementation code. Only tests. Only RED.
Write a summary to ${SUMMARIES_DIR}/write-specs-summary.md listing each spec file and what it tests." \
    "$(get_turns write-specs)" "$(get_budget write-specs)" "--model $(get_model write-specs)"
fi

# ---- Stage 5c: Auto-Generate Holdouts (Step 16) ----
# Run between doc review and implementation so holdout scenarios exist
# before any code is written.

if should_run_phase "holdout-generate"; then
  if [ -d "${HOLDOUTS_DIR}" ] && ls "${HOLDOUTS_DIR}"/holdout-001-*.md 1>/dev/null 2>&1; then
    log "Holdouts already exist, skipping generation."
  else
    run_phase "holdout-generate" \
      "You are the HOLDOUT GENERATOR agent. You operate in COMPLETE ISOLATION from implementation.

Read docs/PRD.md, docs/APP_FLOW.md, docs/API_SPEC.md, and docs/DATA_MODELS.md.

Generate 8-12 adversarial test scenarios that:
- Test behavior IMPLIED but not explicitly stated in the spec
- Cover cross-feature interactions
- Test boundary conditions
- Validate security assumptions
- Check for reward-hacking anti-patterns (hardcoded returns, missing validation)

Write each to ${HOLDOUTS_DIR}/holdout-NNN-[slug].md using the standard format.
Start numbering at 001." \
      "$(get_turns holdout-generate)" "$(get_budget holdout-generate)" "--model $(get_model holdout-generate)"
  fi
fi

# ---- Stage 6: Implementation Loop ----

if should_run_phase "implement"; then
  # Read implementation steps from the plan
  raw_result=$("$AGENT_COMMAND" -p "Read docs/IMPLEMENTATION_PLAN.md and output ONLY a JSON array of step objects: [{\"id\": \"step-1\", \"title\": \"...\", \"description\": \"...\"}]. Output valid JSON only, no markdown fences." \
    --output-format json --max-turns 5 --max-budget-usd 1 2>/dev/null)
  result_text=$(echo "$raw_result" | jq -r '.result // ""' 2>/dev/null || echo "")
  # Try to extract JSON array - first try direct parse, then regex extraction
  IMPL_STEPS=$(echo "$result_text" | jq -c '.' 2>/dev/null || echo "$result_text" | sed -n 's/.*\(\[.*\]\).*/\1/p' | head -1)
  IMPL_STEPS="${IMPL_STEPS:-[]}"
  # Validate it's actually a JSON array
  if ! echo "$IMPL_STEPS" | jq 'type == "array"' 2>/dev/null | grep -q true; then
    IMPL_STEPS="[]"
  fi

  STEP_COUNT=$(echo "$IMPL_STEPS" | jq 'length' 2>/dev/null || echo "0")
  STEP_COUNT=$(validate_numeric "$STEP_COUNT" "0")
  log "Implementation plan has $STEP_COUNT steps"

  if [ "$STEP_COUNT" -gt 50 ]; then
    log_warn "STEP_COUNT ($STEP_COUNT) exceeds maximum of 50, capping"
    STEP_COUNT=50
  fi

  if [ "$STEP_COUNT" -eq 0 ]; then
    # Lightweight tiers may not have an implementation plan — create a single-step plan from the ticket
    log "No implementation plan found. Creating single-step plan from ticket description."
    IMPL_STEPS='[{"id":"step-1","title":"Implement ticket requirements","description":"Read the ticket description and implement all required changes. Run existing tests to verify."}]'
    STEP_COUNT=1
  fi

  for i in $(seq 0 $((STEP_COUNT - 1))); do
    STEP_ID=$(echo "$IMPL_STEPS" | jq -r ".[$i].id // \"step-$((i+1))\"")
    STEP_TITLE=$(echo "$IMPL_STEPS" | jq -r ".[$i].title // \"Untitled step\"")
    STEP_DESC=$(echo "$IMPL_STEPS" | jq -r ".[$i].description // \"No description\"")

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

      # Determine BDD mode based on whether write-specs ran
      SPECS_SUMMARY="${SUMMARIES_DIR}/write-specs-summary.md"
      if [ -f "$SPECS_SUMMARY" ]; then
        BDD_PROMPT="Executable specifications (tests) have already been written by a separate agent and are committed.
Read ${SPECS_SUMMARY} to see what specs exist for this step.

Follow CONTRIBUTING_AGENT.md — GREEN + REFACTOR only:
1. GREEN: Write only the code required to make the existing failing specs pass. Follow existing codebase patterns. Type everything. Handle all errors.
2. REFACTOR: Clean up only while all specs remain green.
Do NOT modify test files unless a spec is demonstrably impossible to satisfy (e.g., tests a non-existent API). If you must change a spec, document why in your commit message."
      else
        BDD_PROMPT="Follow CONTRIBUTING_AGENT.md:
1. RED: Write executable specifications (tests) for this step's behavior FIRST. Run them and confirm they fail.
2. GREEN: Write only the code required to make the specs pass. Follow existing codebase patterns. Type everything. Handle all errors.
3. REFACTOR: Clean up only while all specs remain green."
      fi

      # Implement
      run_phase "implement-${STEP_ID}-attempt-${attempt}" \
        "You are implementing step ${STEP_ID}: ${STEP_TITLE}

Read CLAUDE.md for rules. Read ${SUMMARIES_DIR}/documentation-summary.md for context.
Read the specific doc sections relevant to this step.

Description: ${STEP_DESC}

${ERROR_CONTEXT}

${BDD_PROMPT}
After implementation, run the project's type checker and linter to verify your changes compile.
Commit your changes with message: 'feat(${STEP_ID}): ${STEP_TITLE}'" \
        "$(get_turns implement)" "$(get_budget implement)" "--model $(get_model implement)"

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
          "$(get_turns verify)" "$(get_budget verify)" "--model $(get_model verify)"
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
          "$(get_turns verify)" "$(get_budget verify)" "--model $(get_model verify)"
      fi
      set -e

      VERIFY_VERDICT=$(jq -r '.result // ""' "${LOG_DIR}/verify-${STEP_ID}-attempt-${attempt}.json" 2>/dev/null | extract_verdict)
      VERIFY_VERDICT="${VERIFY_VERDICT:-UNKNOWN}"
      case "$VERIFY_VERDICT" in PASS|AUTO_PASS|PASS_WITH_NOTES|FAIL|ITERATE|UNKNOWN) ;; *) log_warn "Unexpected verify verdict: $VERIFY_VERDICT"; VERIFY_VERDICT="UNKNOWN" ;; esac

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
        if ! echo "BLOCKED: Step ${STEP_ID} failed ${MAX_VERIFY_RETRIES} verification attempts." > "${LOG_DIR}/blocked-${STEP_ID}.txt"; then
          log_warn "Failed to write blocked status file"
        fi
        echo "See verify logs for details." >> "${LOG_DIR}/blocked-${STEP_ID}.txt" 2>/dev/null
        exit 3
      fi
    done
  done
fi

# ---- Stage 7: Holdout Validation ----

if should_run_phase "holdout-validate"; then
  if ls "${HOLDOUTS_DIR}"/holdout-*.md 1>/dev/null 2>&1; then
    run_phase "holdout-validate" \
      "You are a HOLDOUT VALIDATION agent. Test the implementation against hidden scenarios.

Read each file in ${HOLDOUTS_DIR}/holdout-*.md. For each scenario:
1. Check if preconditions can be met in the current implementation
2. Walk through each step against the actual code
3. Evaluate each acceptance criterion (pass/fail)
4. Check each anti-pattern (triggered/clean)

Score: (satisfied scenarios / total scenarios) as percentage.
If >= 80% and 0 anti-pattern flags: VERDICT: PASS
If < 80% or any anti-pattern flags: VERDICT: FAIL with details.

Always include VERDICT: [PASS|FAIL] as the last line." \
      "$(get_turns holdout-validate)" "$(get_budget holdout-validate)" "--model $(get_model holdout-validate)"

    HOLDOUT_VERDICT=$(jq -r '.result // ""' "${LOG_DIR}/holdout-validate.json" 2>/dev/null | extract_verdict)
    HOLDOUT_VERDICT="${HOLDOUT_VERDICT:-UNKNOWN}"
    case "$HOLDOUT_VERDICT" in PASS|AUTO_PASS|PASS_WITH_NOTES|FAIL|UNKNOWN) ;; *) log_warn "Unexpected holdout verdict: $HOLDOUT_VERDICT"; HOLDOUT_VERDICT="UNKNOWN" ;; esac
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
    "$(get_turns security-audit)" "$(get_budget security-audit)" "--model $(get_model security-audit)"

  SECURITY_VERDICT=$(jq -r '.result // ""' "${LOG_DIR}/security-audit.json" 2>/dev/null | extract_verdict)
  SECURITY_VERDICT="${SECURITY_VERDICT:-UNKNOWN}"
  SECURITY_NEXT=$(route_from_gate "security-audit" "$SECURITY_VERDICT")

  if [ "$SECURITY_NEXT" = "implement" ]; then
    log_warn "Security audit found blockers. Attempting auto-fix."
    run_phase "security-fix" \
      "Read ${ARTIFACTS_DIR}/pipeline-runs/${DATE}/security-audit.json. Fix all BLOCKER-severity issues. Do not change functionality, only fix security issues. Commit with message 'fix(security): address audit findings'" \
      "$(get_turns implement)" "$(get_budget implement)" "--model $(get_model security-fix)"
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
- Body: built from ${SUMMARIES_DIR}/ (executive sections only)
- Include: test results, step count, holdout results if applicable

Push branch and create PR via gh CLI or GitHub MCP.
Update Memory MCP: pipeline_state=shipped

Output the PR URL as the last line." \
    "$(get_turns ship)" "$(get_budget ship)" "--model $(get_model ship)"
fi

# ---- Final Cost Report ----

update_checkpoint "completed" "ship"

echo ""
log_phase "PIPELINE COMPLETE"
echo ""
log "Ticket: $TICKET"
display_cost=$(validate_numeric "$TOTAL_COST" "0")
log "Total cost: \$$(printf '%.2f' "$display_cost")"
log "Logs: $LOG_DIR"
log "Cost breakdown:"
if [ -f "$COST_LOG" ]; then
  jq -r '.phases[] | "  \(.name): $\(.cost) (\(.turns) turns)"' "$COST_LOG" 2>/dev/null || log_warn "Could not parse cost log"
fi
echo ""
log "Checkpoint: $CHECKPOINT_FILE"
log "Full cost log: $COST_LOG"

# ---- Record Pipeline Outcome Metrics ----
# Append to cumulative metrics file for empirical outcome tracking

METRICS_FILE="${METRICS_FILE:-docs/artifacts/pipeline-metrics.json}"
mkdir -p "$(dirname "$METRICS_FILE")"

# Count phase verdicts from cost log
PHASE_COUNT=$(safe_jq "$COST_LOG" '.phases | length' "0")
RETRY_COUNT=$(safe_jq "$COST_LOG" '[.phases[] | select(.name | test("attempt-[2-9]"))] | length' "0")
ELAPSED_SECONDS=$(( $(date +%s) - $(date -d "${DATE:0:10} ${DATE:11:2}:${DATE:13:2}" +%s 2>/dev/null || echo "0") ))

# Build this run's metrics entry
RUN_METRICS=$(cat <<METRICS_EOF
{
  "ticket": "${TICKET}",
  "timestamp": "$(date -Iseconds)",
  "tier": "${RESOLVED_TIER:-${PIPELINE_TIER:-full}}",
  "total_cost_usd": ${TOTAL_COST},
  "phases_run": ${PHASE_COUNT},
  "retry_count": ${RETRY_COUNT},
  "status": "completed",
  "log_dir": "${LOG_DIR}"
}
METRICS_EOF
)

# Append to metrics file (create if missing)
if [ -f "$METRICS_FILE" ]; then
  tmp=$(mktemp)
  jq --argjson run "$RUN_METRICS" '.runs += [$run] | .total_runs += 1 | .total_cost_usd += $run.total_cost_usd' \
    "$METRICS_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$METRICS_FILE" || rm -f "$tmp"
else
  echo "{\"runs\":[${RUN_METRICS}],\"total_runs\":1,\"total_cost_usd\":${TOTAL_COST}}" | jq '.' > "$METRICS_FILE" 2>/dev/null || true
fi
log "Metrics appended to: $METRICS_FILE"
