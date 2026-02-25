#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Anvil Benchmark: Controlled Comparison
#
# Runs N tickets through Anvil pipeline and N tickets through
# single-prompt (freestyle) approach, then compares outcomes.
#
# Usage:
#   ./scripts/benchmark.sh tickets.txt [--anvil-only|--freestyle-only]
#
# Input: tickets.txt - one ticket ID per line
# Output: docs/artifacts/benchmark-results.json
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${ROOT}/pipeline.config.sh"

if [ -z "${1:-}" ]; then
  echo "Usage: ./scripts/benchmark.sh tickets.txt [--anvil-only|--freestyle-only]"
  echo ""
  echo "Input: text file with one ticket ID per line"
  echo "Output: docs/artifacts/benchmark-results.json"
  exit 1
fi

TICKETS_FILE="$1"
MODE="${2:-both}"
RESULTS_DIR="${ROOT}/docs/artifacts/benchmark-$(date +%Y%m%d-%H%M)"
RESULTS_FILE="${RESULTS_DIR}/benchmark-results.json"

if [ ! -f "$TICKETS_FILE" ]; then
  echo "[ERROR] Tickets file not found: $TICKETS_FILE"
  exit 1
fi

mkdir -p "$RESULTS_DIR"

# Read tickets
mapfile -t TICKETS < "$TICKETS_FILE"
TICKET_COUNT="${#TICKETS[@]}"
echo "Benchmark: $TICKET_COUNT tickets, mode=$MODE"

# Initialize results
cat > "$RESULTS_FILE" << EOF
{
  "started": "$(date -Iseconds)",
  "ticket_count": ${TICKET_COUNT},
  "mode": "${MODE}",
  "anvil_runs": [],
  "freestyle_runs": []
}
EOF

run_anvil() {
  local ticket="$1"
  local log_dir="${RESULTS_DIR}/anvil-${ticket}"
  echo ""
  echo "=== ANVIL: $ticket ==="
  local start_time
  start_time=$(date +%s)

  set +e
  "${ROOT}/run-pipeline.sh" "$ticket" > "${log_dir}.stdout" 2>&1
  local exit_code=$?
  set -e

  local end_time
  end_time=$(date +%s)
  local elapsed=$(( end_time - start_time ))

  # Extract cost from pipeline output
  local cost
  cost=$(grep -oP 'Total cost: \$\K[0-9.]+' "${log_dir}.stdout" 2>/dev/null || echo "0")

  # Record result
  local tmp
  tmp=$(mktemp)
  jq --arg ticket "$ticket" --argjson exit "$exit_code" \
     --argjson elapsed "$elapsed" --argjson cost "${cost:-0}" \
     '.anvil_runs += [{"ticket":$ticket,"exit_code":$exit,"elapsed_seconds":$elapsed,"cost_usd":$cost}]' \
     "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"

  echo "  exit=$exit_code, cost=\$${cost}, time=${elapsed}s"
}

run_freestyle() {
  local ticket="$1"
  local output_file="${RESULTS_DIR}/freestyle-${ticket}.json"
  echo ""
  echo "=== FREESTYLE: $ticket ==="
  local start_time
  start_time=$(date +%s)

  set +e
  timeout 600 "$AGENT_COMMAND" -p \
    "Read CLAUDE.md. Implement ticket: ${ticket}. Read the codebase, write tests, implement, and commit. Follow existing patterns." \
    --output-format json \
    --max-turns 40 \
    --max-budget-usd 8 \
    --permission-mode acceptEdits \
    > "$output_file" 2>"${RESULTS_DIR}/freestyle-${ticket}.stderr"
  local exit_code=$?
  set -e

  local end_time
  end_time=$(date +%s)
  local elapsed=$(( end_time - start_time ))

  local cost
  cost=$(jq -r '.total_cost_usd // 0' "$output_file" 2>/dev/null || echo "0")

  local tmp
  tmp=$(mktemp)
  jq --arg ticket "$ticket" --argjson exit "$exit_code" \
     --argjson elapsed "$elapsed" --argjson cost "${cost:-0}" \
     '.freestyle_runs += [{"ticket":$ticket,"exit_code":$exit,"elapsed_seconds":$elapsed,"cost_usd":$cost}]' \
     "$RESULTS_FILE" > "$tmp" && mv "$tmp" "$RESULTS_FILE"

  echo "  exit=$exit_code, cost=\$${cost}, time=${elapsed}s"
}

# Run benchmarks
for ticket in "${TICKETS[@]}"; do
  ticket=$(echo "$ticket" | tr -d '[:space:]')
  [ -z "$ticket" ] && continue

  if [ "$MODE" != "--freestyle-only" ]; then
    run_anvil "$ticket"
  fi
  if [ "$MODE" != "--anvil-only" ]; then
    run_freestyle "$ticket"
  fi
done

# Generate summary
echo ""
echo "============================================"
echo "  BENCHMARK COMPLETE"
echo "============================================"

if [ "$MODE" != "--freestyle-only" ]; then
  ANVIL_COUNT=$(jq '.anvil_runs | length' "$RESULTS_FILE")
  ANVIL_PASS=$(jq '[.anvil_runs[] | select(.exit_code == 0)] | length' "$RESULTS_FILE")
  ANVIL_COST=$(jq '[.anvil_runs[].cost_usd] | add // 0' "$RESULTS_FILE")
  ANVIL_TIME=$(jq '[.anvil_runs[].elapsed_seconds] | add // 0' "$RESULTS_FILE")
  echo "  Anvil:     $ANVIL_PASS/$ANVIL_COUNT passed, \$${ANVIL_COST} total, ${ANVIL_TIME}s total"
fi

if [ "$MODE" != "--anvil-only" ]; then
  FREE_COUNT=$(jq '.freestyle_runs | length' "$RESULTS_FILE")
  FREE_PASS=$(jq '[.freestyle_runs[] | select(.exit_code == 0)] | length' "$RESULTS_FILE")
  FREE_COST=$(jq '[.freestyle_runs[].cost_usd] | add // 0' "$RESULTS_FILE")
  FREE_TIME=$(jq '[.freestyle_runs[].elapsed_seconds] | add // 0' "$RESULTS_FILE")
  echo "  Freestyle: $FREE_PASS/$FREE_COUNT passed, \$${FREE_COST} total, ${FREE_TIME}s total"
fi

echo ""
echo "  Full results: $RESULTS_FILE"
echo "  Next step: manually review PRs from both approaches for defect rate."
echo "============================================"
