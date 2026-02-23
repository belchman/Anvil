#!/usr/bin/env bash
# AI-optimized test runner: ERROR-only stdout, full verbose to log file
set -uo pipefail

LOG_FILE="docs/artifacts/test-output-$(date +%Y%m%d-%H%M%S).log"
mkdir -p docs/artifacts

# Fast mode: run random 10% of tests
if [ "${FAST_TEST:-false}" = "true" ]; then
  if [ -f package.json ]; then
    # Jest: run only test files matching a random hash
    SEED=$RANDOM
    npx jest --listTests 2>/dev/null | shuf -n "$(( $(npx jest --listTests 2>/dev/null | wc -l) / 10 + 1 ))" | xargs npx jest --no-coverage 2>&1 | tee "$LOG_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
  elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
    # Pytest: random 10% sampling
    pytest --co -q 2>/dev/null | shuf -n "$(( $(pytest --co -q 2>/dev/null | wc -l) / 10 + 1 ))" | xargs pytest -v 2>&1 | tee "$LOG_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
  fi
else
  # Detect project type and run tests
  if [ -f package.json ]; then
    npm test 2>&1 | tee "$LOG_FILE" | grep -E "^(FAIL|ERROR|✕|✗|×|BROKEN|TypeError|ReferenceError|SyntaxError)" | head -50
    EXIT_CODE=${PIPESTATUS[0]}
  elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
    pytest -v 2>&1 | tee "$LOG_FILE" | grep -E "^(FAILED|ERROR|E )" | head -50
    EXIT_CODE=${PIPESTATUS[0]}
  elif [ -f go.mod ]; then
    go test ./... -v 2>&1 | tee "$LOG_FILE" | grep -E "^(--- FAIL|FAIL|panic)" | head -50
    EXIT_CODE=${PIPESTATUS[0]}
  elif [ -f Cargo.toml ]; then
    cargo test 2>&1 | tee "$LOG_FILE" | grep -E "^(test .* FAILED|error\[)" | head -50
    EXIT_CODE=${PIPESTATUS[0]}
  fi
fi

echo ""
echo "--- Full log: $LOG_FILE ---"
echo "--- Total failures: $(grep -cE "FAIL|ERROR|BROKEN" "$LOG_FILE" 2>/dev/null || echo 0) ---"
exit ${EXIT_CODE:-1}
