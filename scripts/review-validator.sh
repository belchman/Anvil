#!/usr/bin/env bash
# ============================================================
# Non-LLM Review Validator
#
# Real static analysis that breaks the "LLM reviewing LLM" loop.
# Receives phase review JSON on stdin, runs actual checks on the
# codebase, and outputs a VERDICT based on real signals.
#
# Usage (standalone):
#   cat review-output.json | ./scripts/review-validator.sh
#
# Usage (as pipeline validator):
#   REVIEW_VALIDATOR_COMMAND="./scripts/review-validator.sh"
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Consume stdin (review JSON) but our checks are on the actual codebase
cat > /dev/null

ISSUES=0
WARNINGS=0

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  [PASS] $desc"
  else
    echo "  [FAIL] $desc"
    ISSUES=$((ISSUES + 1))
  fi
}

warn_check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  [PASS] $desc"
  else
    echo "  [WARN] $desc"
    WARNINGS=$((WARNINGS + 1))
  fi
}

echo "=== Non-LLM Review Validator ==="

# ---- Syntax Checks (real, not LLM opinion) ----
echo ""
echo "--- Syntax ---"

# Check all .sh files
for sh_file in $(find "$ROOT" -name "*.sh" -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null); do
  check "bash syntax: $(basename "$sh_file")" bash -n "$sh_file"
done

# Check all .py files
for py_file in $(find "$ROOT" -name "*.py" -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/__pycache__/*" 2>/dev/null); do
  check "python syntax: $(basename "$py_file")" python3 -c "import ast; ast.parse(open('$py_file').read())"
done

# Check all .json files
for json_file in $(find "$ROOT" -name "*.json" -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/pipeline-runs/*" 2>/dev/null); do
  check "json valid: $(basename "$json_file")" python3 -c "import json; json.load(open('$json_file'))"
done

# ---- Security Checks (real grep, not LLM opinion) ----
echo ""
echo "--- Security ---"

check "no hardcoded API keys" \
  bash -c '! grep -rn "sk-ant-\|ANTHROPIC_API_KEY=sk" "$1" --include="*.sh" --include="*.py" --include="*.json" --exclude-dir=".git" 2>/dev/null | grep -v ".env.example" | grep -v ".gitignore" | grep -q .' "$ROOT"

check "no hardcoded passwords" \
  bash -c '! grep -rni "password\s*=\s*[\"'"'"'][^\"'"'"']*[\"'"'"']" "$1" --include="*.sh" --include="*.py" --exclude-dir=".git" 2>/dev/null | grep -v "example\|template\|placeholder\|TODO\|CHANGEME" | grep -q .' "$ROOT"

check ".env is gitignored" \
  grep -q "^\.env$" "$ROOT/.gitignore"

# ---- Anti-Pattern Checks ----
echo ""
echo "--- Anti-Patterns ---"

check "no eval with user input" \
  bash -c '! grep -rn "eval.*\$[{(]" "$1" --include="*.sh" --exclude-dir=".git" 2>/dev/null | grep -q .' "$ROOT"

warn_check "no TODO/FIXME/HACK in committed code" \
  bash -c '! grep -rni "TODO\|FIXME\|HACK\|XXX" "$1" --include="*.sh" --include="*.py" --exclude-dir=".git" --exclude="review-validator.sh" 2>/dev/null | grep -q .' "$ROOT"

# ---- Test Execution (real tests, not LLM opinion) ----
echo ""
echo "--- Tests ---"

if command -v anvil >/dev/null 2>&1; then
  check "self-test suite passes" anvil test --quick
fi

if [ -f "$ROOT/scripts/agent-test.sh" ]; then
  warn_check "agent test suite passes" "$ROOT/scripts/agent-test.sh"
fi

# ---- Structural Integrity ----
echo ""
echo "--- Structure ---"

check "no uncommitted changes to tracked files" \
  bash -c 'cd "$1" && [ -z "$(git diff --name-only 2>/dev/null)" ]' "$ROOT"

warn_check "no untracked source files" \
  bash -c 'cd "$1" && [ -z "$(git ls-files --others --exclude-standard -- "*.sh" "*.py" "*.json" 2>/dev/null)" ]' "$ROOT"

# ---- Verdict ----
echo ""
echo "=== Results: $ISSUES issues, $WARNINGS warnings ==="

if [ "$ISSUES" -eq 0 ]; then
  echo "VERDICT: PASS"
else
  echo "VERDICT: FAIL ($ISSUES issues found by static analysis)"
fi
