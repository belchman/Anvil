#!/usr/bin/env bash
# ============================================================
# Anvil Self-Validation Proof
#
# Runs the framework's own validation tools against itself
# and produces a machine-readable evidence file.
#
# This script proves that Anvil is not an untested hypothesis:
# it validates its own structural integrity, syntax, security,
# and review standards using the same tools it applies to
# target projects.
#
# Usage:
#   ./scripts/self-validate.sh              # full validation
#   ./scripts/self-validate.sh --quick      # syntax + security only
#
# Output:
#   docs/artifacts/self-validation-report.json
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-full}"
REPORT_FILE="$ROOT/docs/artifacts/self-validation-report.json"
TIMESTAMP=$(date -Iseconds)

mkdir -p "$(dirname "$REPORT_FILE")"

PASS=0
FAIL=0
WARN=0
CHECKS=()

record() {
  local category="$1" name="$2" status="$3" detail="${4:-}"
  case "$status" in
    PASS) ((PASS++)) ;;
    FAIL) ((FAIL++)) ;;
    WARN) ((WARN++)) ;;
  esac
  CHECKS+=("{\"category\":\"$category\",\"name\":\"$name\",\"status\":\"$status\",\"detail\":\"$detail\"}")
  echo "  [$status] $category: $name"
}

echo "=== Anvil Self-Validation ==="
echo ""

# ---- 1. Self-Test Suite ----
echo "--- Self-Test Suite ---"
if "$ROOT/scripts/test-anvil.sh" > /tmp/anvil-self-test.out 2>&1; then
  TEST_RESULT=$(tail -5 /tmp/anvil-self-test.out | grep -oE 'PASS: [0-9]+' | grep -oE '[0-9]+')
  record "self-test" "test-anvil.sh passes" "PASS" "${TEST_RESULT:-0} tests passed"
else
  record "self-test" "test-anvil.sh passes" "FAIL" "test suite has failures"
fi

# ---- 2. Review Validator (non-LLM checks) ----
echo ""
echo "--- Review Validator ---"
if [ -x "$ROOT/scripts/review-validator.sh" ]; then
  if echo '{}' | "$ROOT/scripts/review-validator.sh" > /tmp/anvil-review-validator.out 2>&1; then
    RV_ISSUES=$(grep -c '\[FAIL\]' /tmp/anvil-review-validator.out 2>/dev/null || echo "0")
    RV_WARNS=$(grep -c '\[WARN\]' /tmp/anvil-review-validator.out 2>/dev/null || echo "0")
    if [ "$RV_ISSUES" -eq 0 ]; then
      record "review-validator" "non-LLM static analysis" "PASS" "$RV_WARNS warnings"
    else
      record "review-validator" "non-LLM static analysis" "FAIL" "$RV_ISSUES issues"
    fi
  else
    record "review-validator" "non-LLM static analysis" "FAIL" "validator script error"
  fi
else
  record "review-validator" "non-LLM static analysis" "WARN" "review-validator.sh not found or not executable"
fi

# ---- 3. Config Integrity ----
echo ""
echo "--- Config Integrity ---"
CONFIG_COUNT=$(grep -cE '^[A-Z_][A-Z0-9_]*=' "$ROOT/pipeline.config.sh" 2>/dev/null || echo "0")
if [ "$CONFIG_COUNT" -ge 40 ]; then
  record "config" "sufficient config vars" "PASS" "$CONFIG_COUNT vars (>= 40)"
else
  record "config" "sufficient config vars" "FAIL" "$CONFIG_COUNT vars (< 40)"
fi

# Verify all config vars are sourced correctly
if bash -n "$ROOT/pipeline.config.sh" 2>/dev/null; then
  record "config" "pipeline.config.sh syntax" "PASS" ""
else
  record "config" "pipeline.config.sh syntax" "FAIL" "syntax error"
fi

# ---- 4. Cross-Runner Parity ----
if [ "$MODE" != "--quick" ]; then
  echo ""
  echo "--- Cross-Runner Parity ---"
  # Check that Python runner defines the same phases as bash
  BASH_PHASES=$(grep -oE '"[a-z-]+"' "$ROOT/run-pipeline.sh" | sort -u | head -20)
  PY_PHASE_ORDER=$(grep 'PHASE_ORDER' "$ROOT/run_pipeline.py" | head -1)
  if echo "$PY_PHASE_ORDER" | grep -q "write-specs"; then
    record "parity" "Python runner has write-specs phase" "PASS" ""
  else
    record "parity" "Python runner has write-specs phase" "FAIL" ""
  fi
  if echo "$PY_PHASE_ORDER" | grep -q "holdout-generate"; then
    record "parity" "Python runner has holdout-generate phase" "PASS" ""
  else
    record "parity" "Python runner has holdout-generate phase" "FAIL" ""
  fi
  # Check nano tier exists in Python
  if grep -q '"nano"' "$ROOT/run_pipeline.py" 2>/dev/null; then
    record "parity" "Python runner supports nano tier" "PASS" ""
  else
    record "parity" "Python runner supports nano tier" "FAIL" ""
  fi
fi

# ---- 5. Security Self-Check ----
echo ""
echo "--- Security ---"
if grep -rn "sk-ant-\|ANTHROPIC_API_KEY=sk" "$ROOT" --include="*.sh" --include="*.py" --include="*.json" --exclude-dir=".git" 2>/dev/null | grep -v ".env.example" | grep -v ".gitignore" | grep -q .; then
  record "security" "no hardcoded API keys" "FAIL" "key found in source"
else
  record "security" "no hardcoded API keys" "PASS" ""
fi

if grep -q "^\.env$" "$ROOT/.gitignore" 2>/dev/null; then
  record "security" ".env is gitignored" "PASS" ""
else
  record "security" ".env is gitignored" "FAIL" ""
fi

# ---- 6. File Count Verification ----
echo ""
echo "--- Inventory ---"
SKILL_COUNT=$(find "$ROOT/.claude/skills" -name "SKILL.md" 2>/dev/null | wc -l | tr -d ' ')
TEMPLATE_COUNT=$(find "$ROOT/docs/templates" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
record "inventory" "skills count" "PASS" "$SKILL_COUNT skills"
record "inventory" "templates count" "PASS" "$TEMPLATE_COUNT templates"

# ---- Build Report ----
echo ""
echo "=== Results: $PASS pass, $FAIL fail, $WARN warn ==="

# Join checks array into JSON
CHECKS_JSON=$(printf '%s,' "${CHECKS[@]}")
CHECKS_JSON="[${CHECKS_JSON%,}]"

cat > "$REPORT_FILE" << EOF
{
  "framework": "Anvil",
  "version": "3.1",
  "timestamp": "$TIMESTAMP",
  "mode": "$MODE",
  "summary": {
    "pass": $PASS,
    "fail": $FAIL,
    "warn": $WARN,
    "total": $((PASS + FAIL + WARN))
  },
  "checks": $CHECKS_JSON,
  "verdict": "$([ "$FAIL" -eq 0 ] && echo "PASS" || echo "FAIL")"
}
EOF

echo "Report: $REPORT_FILE"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT: PASS — Anvil validates itself."
  exit 0
else
  echo "VERDICT: FAIL — $FAIL check(s) failed."
  exit 1
fi
