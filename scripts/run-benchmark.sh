#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Anvil Benchmark Runner
#
# Runs benchmark tickets through Anvil pipeline and/or freestyle
# approach, scores results with automated quality checks, and
# generates machine-readable evidence.
#
# Usage:
#   ./scripts/run-benchmark.sh [OPTIONS]
#
# Options:
#   --ticket BENCH-N     Run a single ticket (default: all)
#   --approach TYPE      anvil|freestyle|both (default: both)
#   --max-budget USD     Per-ticket budget cap (default: 15)
#   --output DIR         Output directory
#   --dry-run            Show what would run without executing
#
# Output: docs/artifacts/benchmark-YYYYMMDD-HHMM/benchmark-evidence.json
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCHMARK_DIR="${ROOT}/benchmarks"
TARGET_DIR=""  # resolved after arg parsing
TICKETS_DIR="${BENCHMARK_DIR}/tickets"
SCORER="${BENCHMARK_DIR}/score.py"
BENCHMARK_CONFIG="${BENCHMARK_DIR}/benchmark.config.sh"

# Resolve claude CLI path (survives subshells that lose nvm PATH)
CLAUDE_CMD="$(command -v claude 2>/dev/null || echo "claude")"

# Defaults
TICKET=""
APPROACH="both"
MAX_BUDGET=15
OUTPUT_DIR=""
DRY_RUN=false
TARGET_NAME="target"
ANVIL_TIER="lite"

# Colors (disabled when not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

log()  { echo -e "${BLUE}[bench]${NC} $*"; }
ok()   { echo -e "${GREEN}[bench]${NC} $*"; }
err()  { echo -e "${RED}[bench]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[bench]${NC} $*"; }

usage() {
  echo "Usage: ./scripts/run-benchmark.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --ticket BENCH-N     Run single ticket (default: all BENCH-*.md)"
  echo "  --approach TYPE      anvil|freestyle|both (default: both)"
  echo "  --target NAME        Target project directory name (default: target)"
  echo "  --target-hard        Shortcut for --target target-hard"
  echo "  --tier TIER          Pipeline tier for Anvil runs (default: lite)"
  echo "  --max-budget USD     Per-ticket budget cap (default: 15)"
  echo "  --output DIR         Output directory"
  echo "  --dry-run            Show plan without executing"
  echo "  -h, --help           Show this help"
  exit 0
}

# ---- Parse Arguments ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket)     TICKET="$2"; shift 2 ;;
    --approach)   APPROACH="$2"; shift 2 ;;
    --max-budget) MAX_BUDGET="$2"; shift 2 ;;
    --output)     OUTPUT_DIR="$2"; shift 2 ;;
    --target)     TARGET_NAME="$2"; shift 2 ;;
    --target-hard) TARGET_NAME="target-hard"; shift ;;
    --tier)       ANVIL_TIER="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    usage ;;
    *) err "Unknown option: $1"; usage ;;
  esac
done

# ---- Resolve Target Directory ----
TARGET_DIR="${BENCHMARK_DIR}/${TARGET_NAME}"

# ---- Pre-flight Checks ----
if [ ! -d "$TARGET_DIR" ]; then
  err "Target project not found: $TARGET_DIR"
  exit 1
fi

if [ ! -f "$SCORER" ]; then
  err "Scorer not found: $SCORER"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  err "python3 not found"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  err "jq not found"
  exit 1
fi

# Resolve timeout command (GNU coreutils on macOS = gtimeout)
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
else
  # No timeout available — define a shell function fallback
  TIMEOUT_CMD=""
fi

run_with_timeout() {
  local secs="$1"; shift
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$secs" "$@"
  else
    # Fallback: run in background, kill after timeout
    "$@" &
    local pid=$!
    (sleep "$secs" && kill "$pid" 2>/dev/null) &
    local watcher=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return $rc
  fi
}

if [[ "$APPROACH" != "anvil" && "$APPROACH" != "freestyle" && "$APPROACH" != "both" ]]; then
  err "Invalid approach: $APPROACH (must be anvil|freestyle|both)"
  exit 1
fi

# ---- Discover Tickets ----
TICKETS=()
if [ -n "$TICKET" ]; then
  if [ ! -f "${TICKETS_DIR}/${TICKET}.md" ]; then
    err "Ticket not found: ${TICKETS_DIR}/${TICKET}.md"
    exit 1
  fi
  TICKETS=("$TICKET")
else
  for f in "${TICKETS_DIR}"/BENCH-*.md; do
    [ -f "$f" ] || continue
    TICKETS+=("$(basename "$f" .md)")
  done
fi

if [ "${#TICKETS[@]}" -eq 0 ]; then
  err "No tickets found in $TICKETS_DIR"
  exit 1
fi

# ---- Output Directory ----
if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="${ROOT}/docs/artifacts/benchmark-$(date +%Y%m%d-%H%M)"
fi
mkdir -p "$OUTPUT_DIR"

log "Benchmark configuration:"
log "  Target:   ${TARGET_NAME}"
log "  Tickets:  ${TICKETS[*]}"
log "  Approach: $APPROACH"
log "  Budget:   \$${MAX_BUDGET}/ticket"
log "  Output:   $OUTPUT_DIR"

if [ "$DRY_RUN" = true ]; then
  log ""
  log "DRY RUN - would run ${#TICKETS[@]} ticket(s) with approach=$APPROACH"
  for t in "${TICKETS[@]}"; do
    log "  $t: $(head -1 "${TICKETS_DIR}/${t}.md" | sed 's/^# //')"
  done
  exit 0
fi

# ---- Compute Baselines ----
log "Computing baseline checksums..."
BASELINE_HASHES_FILE="${OUTPUT_DIR}/baseline-hashes.json"
(
  cd "$TARGET_DIR"
  echo "{"
  first=true
  # Auto-discover Python source and test files
  find . -name '*.py' -not -path './.pytest_cache/*' -not -path './__pycache__/*' | sort | while read -r f; do
    hash=$(shasum -a 256 "$f" | cut -d' ' -f1)
    if [ "$first" = true ]; then first=false; else echo ","; fi
    printf '  "%s": "%s"' "$f" "$hash"
  done
  echo ""
  echo "}"
) > "$BASELINE_HASHES_FILE"

# ---- Run Baseline Tests ----
log "Running baseline tests..."
BASELINE_TEST_OUTPUT="${OUTPUT_DIR}/baseline-tests.txt"
(cd "$TARGET_DIR" && python3 -m pytest tests/ -v 2>&1) > "$BASELINE_TEST_OUTPUT" || true
BASELINE_TEST_COUNT=$(grep -c "PASSED" "$BASELINE_TEST_OUTPUT" 2>/dev/null || echo "0")
log "Baseline: ${BASELINE_TEST_COUNT} tests passing"

# ---- Results Accumulator ----
EVIDENCE_FILE="${OUTPUT_DIR}/benchmark-evidence.json"
cat > "$EVIDENCE_FILE" << EOF
{
  "started": "$(date -Iseconds)",
  "target": "${TARGET_NAME}",
  "baseline_tests": ${BASELINE_TEST_COUNT},
  "approach": "${APPROACH}",
  "tickets": [],
  "summary": {}
}
EOF

# ---- Helper: Update Evidence JSON ----
update_evidence() {
  local tmp
  tmp=$(mktemp)
  if jq "$@" "$EVIDENCE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$EVIDENCE_FILE"
  else
    rm -f "$tmp"
    warn "Failed to update evidence JSON"
  fi
}

# ---- Helper: Prepare Working Directory ----
prepare_workdir() {
  local workdir="$1"
  local label="$2"

  rm -rf "$workdir"
  cp -r "$TARGET_DIR" "$workdir"

  # Initialize git so pipeline/scorer can detect changes
  (cd "$workdir" && git init -q && git add -A && git commit -q -m "baseline" 2>/dev/null) || true

  log "  Prepared $label workdir: $(basename "$workdir")"
}

# ---- Helper: Run Anvil ----
run_anvil() {
  local ticket_id="$1"
  local ticket_file="${TICKETS_DIR}/${ticket_id}.md"
  local workdir="${OUTPUT_DIR}/anvil-${ticket_id}"
  local log_file="${OUTPUT_DIR}/anvil-${ticket_id}.log"

  log "  [ANVIL] ${ticket_id}"
  prepare_workdir "$workdir" "anvil"

  # Overlay Anvil framework into working directory
  cp -r "${ROOT}/.claude" "${workdir}/" 2>/dev/null || true
  cp "${ROOT}/run-pipeline.sh" "${workdir}/" 2>/dev/null || true
  cp "${ROOT}/pipeline.config.sh" "${workdir}/" 2>/dev/null || true
  cp "${ROOT}/pipeline.models.json" "${workdir}/" 2>/dev/null || true
  cp "${ROOT}/CONTRIBUTING_AGENT.md" "${workdir}/" 2>/dev/null || true
  mkdir -p "${workdir}/scripts"
  cp "${ROOT}/scripts/review-validator.sh" "${workdir}/scripts/" 2>/dev/null || true
  chmod +x "${workdir}/run-pipeline.sh" 2>/dev/null || true

  # Apply benchmark config overrides (append to pipeline.config.sh)
  if [ -f "$BENCHMARK_CONFIG" ]; then
    echo "" >> "${workdir}/pipeline.config.sh"
    echo "# --- Benchmark overrides ---" >> "${workdir}/pipeline.config.sh"
    cat "$BENCHMARK_CONFIG" >> "${workdir}/pipeline.config.sh"
  fi

  # Prepend Anvil instructions to target's CLAUDE.md
  if [ -f "${workdir}/CLAUDE.md" ]; then
    local orig
    orig=$(cat "${workdir}/CLAUDE.md")
    cat "${ROOT}/CLAUDE.md" > "${workdir}/CLAUDE.md"
    echo "" >> "${workdir}/CLAUDE.md"
    echo "---" >> "${workdir}/CLAUDE.md"
    echo "" >> "${workdir}/CLAUDE.md"
    echo "$orig" >> "${workdir}/CLAUDE.md"
  fi

  local ticket_text
  ticket_text=$(cat "$ticket_file")

  local start_time exit_code=0
  start_time=$(date +%s)

  set +e
  (cd "$workdir" && unset CLAUDECODE && PIPELINE_TIER="$ANVIL_TIER" run_with_timeout 1800 ./run-pipeline.sh \
    "${ticket_id}: ${ticket_text}" > "$log_file" 2>&1)
  exit_code=$?
  set -e

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))

  # Extract cost from pipeline log
  local cost
  cost=$(grep -o 'Total cost: \$[0-9.]*' "$log_file" 2>/dev/null | grep -o '[0-9.]*' | tail -1 || echo "0")
  [ -z "$cost" ] && cost="0"

  # Score the result
  local score_output="${OUTPUT_DIR}/anvil-${ticket_id}-score.json"
  python3 "$SCORER" --workdir "$workdir" --ticket "$ticket_id" \
    --baseline "$TARGET_DIR" --json > "$score_output" 2>/dev/null || true

  local score
  score=$(jq -r '.score // 0' "$score_output" 2>/dev/null || echo "0")

  ok "  [ANVIL] ${ticket_id}: score=${score}/100, cost=\$${cost}, time=${elapsed}s, exit=${exit_code}"

  update_evidence \
    --arg tid "$ticket_id" --argjson exit "$exit_code" \
    --argjson elapsed "$elapsed" --argjson cost "${cost:-0}" \
    --argjson score "${score:-0}" \
    '.tickets += [{"ticket":$tid,"approach":"anvil","exit_code":$exit,"elapsed_s":$elapsed,"cost_usd":$cost,"score":$score}]'
}

# ---- Helper: Run Freestyle ----
run_freestyle() {
  local ticket_id="$1"
  local ticket_file="${TICKETS_DIR}/${ticket_id}.md"
  local workdir="${OUTPUT_DIR}/freestyle-${ticket_id}"
  local log_file="${OUTPUT_DIR}/freestyle-${ticket_id}.log"

  log "  [FREE] ${ticket_id}"
  prepare_workdir "$workdir" "freestyle"

  local ticket_text
  ticket_text=$(cat "$ticket_file")

  local start_time exit_code=0
  start_time=$(date +%s)

  set +e
  (cd "$workdir" && unset CLAUDECODE && run_with_timeout 600 "$CLAUDE_CMD" -p \
    "Read CLAUDE.md. Implement this ticket:

${ticket_text}

Read the codebase, write tests first, implement, verify all tests pass." \
    --max-turns 40 \
    --max-budget-usd "$MAX_BUDGET" \
    --permission-mode bypassPermissions \
    --output-format json \
    > "$log_file" 2>&1)
  exit_code=$?
  set -e

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))

  # Extract cost from JSON output (--output-format json)
  local cost
  cost=$(jq -r '.total_cost_usd // 0' "$log_file" 2>/dev/null || echo "0")
  [ -z "$cost" ] && cost="0"
  # Fallback: try regex if jq fails (non-JSON output)
  if [ "$cost" = "0" ] || [ "$cost" = "null" ]; then
    cost=$(grep -o 'cost: \$[0-9.]*' "$log_file" 2>/dev/null | grep -o '[0-9.]*' | tail -1 || echo "0")
    [ -z "$cost" ] && cost="0"
  fi

  # Score the result
  local score_output="${OUTPUT_DIR}/freestyle-${ticket_id}-score.json"
  python3 "$SCORER" --workdir "$workdir" --ticket "$ticket_id" \
    --baseline "$TARGET_DIR" --json > "$score_output" 2>/dev/null || true

  local score
  score=$(jq -r '.score // 0' "$score_output" 2>/dev/null || echo "0")

  ok "  [FREE] ${ticket_id}: score=${score}/100, cost=\$${cost}, time=${elapsed}s, exit=${exit_code}"

  update_evidence \
    --arg tid "$ticket_id" --argjson exit "$exit_code" \
    --argjson elapsed "$elapsed" --argjson cost "${cost:-0}" \
    --argjson score "${score:-0}" \
    '.tickets += [{"ticket":$tid,"approach":"freestyle","exit_code":$exit,"elapsed_s":$elapsed,"cost_usd":$cost,"score":$score}]'
}

# ---- Main Loop ----
log ""
log "Starting benchmark runs..."
log ""

for ticket_id in "${TICKETS[@]}"; do
  log "--- ${ticket_id} ---"

  if [[ "$APPROACH" == "anvil" || "$APPROACH" == "both" ]]; then
    run_anvil "$ticket_id"
  fi

  if [[ "$APPROACH" == "freestyle" || "$APPROACH" == "both" ]]; then
    run_freestyle "$ticket_id"
  fi

  echo ""
done

# ---- Generate Summary ----
log "Generating summary..."

ANVIL_SCORES=$(jq '[.tickets[] | select(.approach=="anvil") | .score] | if length > 0 then (add / length) else 0 end' "$EVIDENCE_FILE")
FREE_SCORES=$(jq '[.tickets[] | select(.approach=="freestyle") | .score] | if length > 0 then (add / length) else 0 end' "$EVIDENCE_FILE")
ANVIL_COST=$(jq '[.tickets[] | select(.approach=="anvil") | .cost_usd] | add // 0' "$EVIDENCE_FILE")
FREE_COST=$(jq '[.tickets[] | select(.approach=="freestyle") | .cost_usd] | add // 0' "$EVIDENCE_FILE")
ANVIL_TIME=$(jq '[.tickets[] | select(.approach=="anvil") | .elapsed_s] | add // 0' "$EVIDENCE_FILE")
FREE_TIME=$(jq '[.tickets[] | select(.approach=="freestyle") | .elapsed_s] | add // 0' "$EVIDENCE_FILE")

# Add per-ticket cost_per_point to evidence
update_evidence \
  'def cpp: if .score > 0 then (.cost_usd / .score * 100) else 0 end;
   .tickets = [.tickets[] | . + {"cost_per_point": (. | cpp)}]'

update_evidence \
  --argjson anvil_avg "$ANVIL_SCORES" --argjson free_avg "$FREE_SCORES" \
  --argjson anvil_cost "$ANVIL_COST" --argjson free_cost "$FREE_COST" \
  --argjson anvil_time "$ANVIL_TIME" --argjson free_time "$FREE_TIME" \
  --arg target "$TARGET_NAME" \
  '.summary = {
    "target": $target,
    "anvil_avg_score": $anvil_avg,
    "freestyle_avg_score": $free_avg,
    "anvil_total_cost": $anvil_cost,
    "freestyle_total_cost": $free_cost,
    "anvil_total_time_s": $anvil_time,
    "freestyle_total_time_s": $free_time,
    "anvil_cost_per_point": (if $anvil_avg > 0 then ($anvil_cost / $anvil_avg * 100) else 0 end),
    "freestyle_cost_per_point": (if $free_avg > 0 then ($free_cost / $free_avg * 100) else 0 end),
    "completed": now | todate
  }'

# ---- Print Summary Table ----
echo ""
echo -e "${BOLD}=====================================================${NC}"
echo -e "${BOLD}  BENCHMARK RESULTS${NC}"
echo -e "${BOLD}=====================================================${NC}"
echo ""
printf "  %-10s %-12s %-8s %-10s %-10s\n" "Ticket" "Approach" "Score" "Cost" "Time"
printf "  %-10s %-12s %-8s %-10s %-10s\n" "------" "--------" "-----" "----" "----"

jq -r '.tickets[] | "\(.ticket)|\(.approach)|\(.score)|\(.cost_usd)|\(.elapsed_s)"' "$EVIDENCE_FILE" | \
  while IFS='|' read -r tid app sc cst tm; do
    printf "  %-10s %-12s %-8s %-10s %-10s\n" "$tid" "$app" "${sc}/100" "\$${cst}" "${tm}s"
  done

echo ""
echo -e "  ${BOLD}Averages:${NC}"
printf "    Anvil:     %.0f/100 avg, \$%.2f total, %ds total\n" "$ANVIL_SCORES" "$ANVIL_COST" "${ANVIL_TIME%.*}"
printf "    Freestyle: %.0f/100 avg, \$%.2f total, %ds total\n" "$FREE_SCORES" "$FREE_COST" "${FREE_TIME%.*}"
echo ""
echo -e "${BOLD}=====================================================${NC}"
echo ""
echo "  Evidence: $EVIDENCE_FILE"
echo "  Workdirs: ${OUTPUT_DIR}/[anvil|freestyle]-BENCH-*/"
echo ""
