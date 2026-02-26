#!/usr/bin/env bash
# Anvil Framework Self-Test Suite
# Validates file inventory, syntax, cross-references, and structural integrity.
#
# Usage:
#   ./scripts/test-anvil.sh          # run all tests
#   ./scripts/test-anvil.sh quick    # skip slow checks (DOT parsing, deep cross-ref)
set -uo pipefail

# ---- Setup ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
WARN=0
MODE="${1:-full}"

# Colors (disabled when not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  GREEN=''
  RED=''
  YELLOW=''
  NC=''
fi

pass() { ((PASS++)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}FAIL${NC} $1"; }
warn() { ((WARN++)); echo -e "  ${YELLOW}WARN${NC} $1"; }

section() { echo -e "\n${GREEN}=== $1 ===${NC}"; }

# ============================================================
# 1. File Inventory
# ============================================================
section "File Inventory"

# Core files
CORE_FILES=(
  "CLAUDE.md"
  "CONTRIBUTING_AGENT.md"
  "README.md"
  "run-pipeline.sh"
  "run_pipeline.py"
  "pipeline.config.sh"
  "pipeline.models.json"
  ".env.example"
  ".gitignore"
  "scripts/agent-test.sh"
  "scripts/run-benchmark.sh"
  "scripts/review-validator.sh"
  "scripts/setup-anvil.sh"
  ".github/workflows/autonomous-pipeline.yml"
  "benchmarks/score.py"
  "benchmarks/benchmark.config.sh"
  "benchmarks/target/tasktrack/__init__.py"
  "benchmarks/target/tasktrack/store.py"
  "benchmarks/target/tasktrack/cli.py"
  "benchmarks/target/tests/test_store.py"
  "benchmarks/target/CLAUDE.md"
  "benchmarks/target/pyproject.toml"
  "benchmarks/target-hard/invtrack/__init__.py"
  "benchmarks/target-hard/invtrack/models.py"
  "benchmarks/target-hard/invtrack/store.py"
  "benchmarks/target-hard/invtrack/inventory.py"
  "benchmarks/target-hard/invtrack/orders.py"
  "benchmarks/target-hard/invtrack/reports.py"
  "benchmarks/target-hard/invtrack/cli.py"
  "benchmarks/target-hard/tests/test_store.py"
  "benchmarks/target-hard/tests/test_inventory.py"
  "benchmarks/target-hard/tests/test_orders.py"
  "benchmarks/target-hard/CLAUDE.md"
  "benchmarks/target-hard/pyproject.toml"
  "scripts/setup-anvil.sh"
)
for f in "${CORE_FILES[@]}"; do
  if [ -f "$ROOT/$f" ]; then
    pass "$f exists"
  else
    fail "$f missing"
  fi
done

# Skills (11 expected)
SKILLS=(phase0 interrogate feature-add cost-report update-progress error-analysis heal)
for s in "${SKILLS[@]}"; do
  if [ -f "$ROOT/.claude/skills/$s/SKILL.md" ]; then
    pass "skill: $s"
  else
    fail "skill missing: $s"
  fi
done

# Agents (2 expected)
AGENTS=(healer supervisor)
for a in "${AGENTS[@]}"; do
  if [ -f "$ROOT/.claude/agents/$a.md" ]; then
    pass "agent: $a"
  else
    fail "agent missing: $a"
  fi
done

# Rules (4 expected)
RULES=(no-assumptions context-management)
for r in "${RULES[@]}"; do
  if [ -f "$ROOT/.claude/rules/$r.md" ]; then
    pass "rule: $r"
  else
    fail "rule missing: $r"
  fi
done

# Doc templates (auto-discovered)
TEMPLATES=()
for tmpl_file in "$ROOT/docs/templates"/*.md; do
  if [ -f "$tmpl_file" ]; then
    t=$(basename "$tmpl_file" .md)
    TEMPLATES+=("$t")
    pass "template: $t"
  fi
done
if [ "${#TEMPLATES[@]}" -lt 1 ]; then
  fail "no templates found in docs/templates/"
fi

# Settings
if [ -f "$ROOT/.claude/settings.json" ]; then
  pass ".claude/settings.json exists"
else
  fail ".claude/settings.json missing"
fi

# Benchmark tickets (10 expected: 5 simple + 5 hard)
BENCH_TICKETS=(BENCH-1 BENCH-2 BENCH-3 BENCH-4 BENCH-5 BENCH-6 BENCH-7 BENCH-8 BENCH-9 BENCH-10)
for bt in "${BENCH_TICKETS[@]}"; do
  if [ -f "$ROOT/benchmarks/tickets/${bt}.md" ]; then
    pass "ticket: ${bt}.md"
  else
    fail "ticket missing: ${bt}.md"
  fi
  if [ -f "$ROOT/benchmarks/tickets/expected/${bt}.json" ]; then
    pass "expected: ${bt}.json"
  else
    fail "expected missing: ${bt}.json"
  fi
done

# Holdouts directory
if [ -d "$ROOT/.holdouts" ]; then
  pass ".holdouts/ directory exists"
else
  fail ".holdouts/ directory missing"
fi

# ============================================================
# 2. Bash Syntax Checks
# ============================================================
section "Bash Syntax"

for script in "$ROOT/run-pipeline.sh" "$ROOT/pipeline.config.sh" "$ROOT/scripts/agent-test.sh" "$ROOT/scripts/run-benchmark.sh" "$ROOT/scripts/review-validator.sh" "$ROOT/scripts/setup-anvil.sh" "$ROOT/benchmarks/benchmark.config.sh"; do
  name=$(basename "$script")
  if bash -n "$script" 2>/dev/null; then
    pass "$name syntax OK"
  else
    fail "$name has syntax errors"
  fi
done

# Check run-pipeline.sh is executable
if [ -x "$ROOT/run-pipeline.sh" ]; then
  pass "run-pipeline.sh is executable"
else
  fail "run-pipeline.sh is not executable"
fi

# ============================================================
# 2b. Version Check
# ============================================================
section "Version"

if grep -q 'ANVIL_VERSION=' "$ROOT/pipeline.config.sh"; then
  ANVIL_VER=$(grep 'ANVIL_VERSION=' "$ROOT/pipeline.config.sh" | head -1 | cut -d'"' -f2)
  pass "ANVIL_VERSION=$ANVIL_VER"
else
  fail "ANVIL_VERSION not found in pipeline.config.sh"
fi

# ============================================================
# 3. Python Syntax Check
# ============================================================
section "Python Syntax"

if command -v python3 &>/dev/null; then
  if python3 -c "import ast; ast.parse(open('$ROOT/run_pipeline.py').read())" 2>/dev/null; then
    pass "run_pipeline.py syntax OK"
  else
    fail "run_pipeline.py has syntax errors"
  fi
  if python3 -c "import ast; ast.parse(open('$ROOT/benchmarks/score.py').read())" 2>/dev/null; then
    pass "benchmarks/score.py syntax OK"
  else
    fail "benchmarks/score.py has syntax errors"
  fi
  if python3 -c "import ast; ast.parse(open('$ROOT/benchmarks/target/tasktrack/store.py').read())" 2>/dev/null; then
    pass "benchmarks/target/tasktrack/store.py syntax OK"
  else
    fail "benchmarks/target/tasktrack/store.py has syntax errors"
  fi
  # target-hard Python files
  for pyf in store.py models.py inventory.py orders.py reports.py cli.py; do
    if python3 -c "import ast; ast.parse(open('$ROOT/benchmarks/target-hard/invtrack/$pyf').read())" 2>/dev/null; then
      pass "benchmarks/target-hard/invtrack/$pyf syntax OK"
    else
      fail "benchmarks/target-hard/invtrack/$pyf has syntax errors"
    fi
  done
else
  warn "python3 not found, skipping Python syntax check"
fi

# ============================================================
# 4. JSON Validity
# ============================================================
section "JSON Validity"

JSON_FILES=(
  "pipeline.models.json"
  ".claude/settings.json"
)
for jf in "${JSON_FILES[@]}"; do
  if [ -f "$ROOT/$jf" ]; then
    if jq empty "$ROOT/$jf" 2>/dev/null; then
      pass "$jf valid JSON"
    else
      fail "$jf invalid JSON"
    fi
  fi
done

# DOT graph removed in v3.1 (pipeline phase order defined in PHASE_ORDER config)

# ============================================================
# 6. Config Completeness
# ============================================================
section "Config Completeness"

# Auto-discover config vars from pipeline.config.sh
CONFIG_VARS=()
while IFS='=' read -r var _; do
  CONFIG_VARS+=("$var")
done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$ROOT/pipeline.config.sh")

for var in "${CONFIG_VARS[@]}"; do
  pass "config: $var"
done

# Verify minimum expected count (simplified from 73 to ~20 in v3.1)
if [ "${#CONFIG_VARS[@]}" -lt 15 ]; then
  fail "Expected at least 15 config vars, found ${#CONFIG_VARS[@]}"
else
  pass "config var count: ${#CONFIG_VARS[@]} (>= 15)"
fi

# ============================================================
# 7. Cross-Reference Integrity
# ============================================================
section "Cross-References"

if [ "$MODE" = "quick" ]; then
  warn "Skipping deep cross-reference checks (quick mode)"
else
  # pipeline.models.json overrides should map to known phase types
  MODEL_TYPES=$(jq -r '.overrides | keys[]' "$ROOT/pipeline.models.json" 2>/dev/null)
  EXPECTED_TYPES="routing review security generation implementation specification holdout_generate holdout_validate healer supervisor"
  for t in $EXPECTED_TYPES; do
    if echo "$MODEL_TYPES" | grep -q "^${t}$"; then
      pass "model override: $t"
    else
      fail "model override missing: $t"
    fi
  done

  # run-pipeline.sh sources pipeline.config.sh
  if grep -q 'source.*pipeline\.config\.sh' "$ROOT/run-pipeline.sh"; then
    pass "run-pipeline.sh sources pipeline.config.sh"
  else
    fail "run-pipeline.sh does not source pipeline.config.sh"
  fi

  # run-pipeline.sh references all expected functions
  EXPECTED_FUNCS=(run_phase route_from_gate run_review_with_bias_check select_fidelity parse_satisfaction score_to_verdict check_kill_switch check_cost_ceiling check_stagnation check_git_progress after_phase update_checkpoint should_run_phase)
  for fn in "${EXPECTED_FUNCS[@]}"; do
    if grep -q "^${fn}()" "$ROOT/run-pipeline.sh"; then
      pass "function: $fn()"
    else
      fail "function missing: $fn()"
    fi
  done

  # CLAUDE.md references key skills
  CLAUDE_SKILLS=(phase0 interrogate feature-add cost-report heal)
  for sk in "${CLAUDE_SKILLS[@]}"; do
    if grep -qi "$sk" "$ROOT/CLAUDE.md"; then
      pass "CLAUDE.md references $sk"
    else
      warn "CLAUDE.md does not reference $sk"
    fi
  done

  # README.md lists all skills
  for sk in "${SKILLS[@]}"; do
    if grep -qi "$sk" "$ROOT/README.md"; then
      pass "README lists skill: $sk"
    else
      warn "README does not list skill: $sk"
    fi
  done

  # .env.example exists and has ANTHROPIC_API_KEY
  if [ -f "$ROOT/.env.example" ]; then
    if grep -q "ANTHROPIC_API_KEY" "$ROOT/.env.example"; then
      pass ".env.example has ANTHROPIC_API_KEY"
    else
      fail ".env.example missing ANTHROPIC_API_KEY"
    fi
  fi

  # CI workflow references run-pipeline.sh
  if grep -q "run-pipeline.sh" "$ROOT/.github/workflows/autonomous-pipeline.yml"; then
    pass "CI workflow references run-pipeline.sh"
  else
    fail "CI workflow does not reference run-pipeline.sh"
  fi
fi

# ============================================================
# 8. Skill Content Checks
# ============================================================
section "Skill Content"

# Each skill should be non-trivial (> 10 lines)
for s in "${SKILLS[@]}"; do
  SKILL_FILE="$ROOT/.claude/skills/$s/SKILL.md"
  if [ -f "$SKILL_FILE" ]; then
    LINES=$(wc -l < "$SKILL_FILE")
    if [ "$LINES" -gt 10 ]; then
      pass "$s: $LINES lines (non-trivial)"
    else
      warn "$s: only $LINES lines (may be skeletal)"
    fi
  fi
done

# ============================================================
# 9. Exit Code Documentation
# ============================================================
section "Exit Code Consistency"

# run-pipeline.sh should handle exit codes 0-4
for code in 0 1 2 3 4; do
  if grep -q "exit $code" "$ROOT/run-pipeline.sh"; then
    pass "run-pipeline.sh uses exit $code"
  else
    warn "run-pipeline.sh does not use exit $code"
  fi
done

# README documents exit codes
for code in 0 1 2 3 4; do
  if grep -q "| $code " "$ROOT/README.md"; then
    pass "README documents exit code $code"
  else
    fail "README missing exit code $code"
  fi
done

# ============================================================
# 10. Portability Checks
# ============================================================
section "Portability"

# No grep -oP (PCRE) in run-pipeline.sh (not portable to macOS/BSD)
if grep -n 'grep -oP' "$ROOT/run-pipeline.sh" >/dev/null 2>&1; then
  fail "run-pipeline.sh uses grep -oP (not portable)"
else
  pass "run-pipeline.sh avoids grep -oP"
fi

# No hardcoded docs/artifacts/ paths in run-pipeline.sh (should use config vars)
if grep -n '"docs/artifacts/' "$ROOT/run-pipeline.sh" >/dev/null 2>&1; then
  fail "run-pipeline.sh has hardcoded docs/artifacts/ paths"
else
  pass "run-pipeline.sh uses config for artifact paths"
fi

# No bare 'timeout' command in run-pipeline.sh (not available on macOS)
if grep -n '^\s*timeout ' "$ROOT/run-pipeline.sh" >/dev/null 2>&1; then
  fail "run-pipeline.sh uses bare 'timeout' (not portable, use _timeout)"
else
  pass "run-pipeline.sh uses portable _timeout wrapper"
fi

# _timeout function defined in run-pipeline.sh
if grep -q '_timeout()' "$ROOT/run-pipeline.sh"; then
  pass "run-pipeline.sh defines _timeout portable wrapper"
else
  fail "run-pipeline.sh missing _timeout portable wrapper"
fi

# should_run_phase must not return 0 early before tier filtering
# This catches the bug where fresh runs bypassed tier checks
if grep -q 'return 0.*# Not resuming' "$ROOT/run-pipeline.sh"; then
  fail "should_run_phase has early return that bypasses tier filtering"
else
  pass "should_run_phase properly reaches tier filtering"
fi

# tier_allows_phase called in should_run_phase
if grep -q 'tier_allows_phase' "$ROOT/run-pipeline.sh"; then
  pass "run-pipeline.sh calls tier_allows_phase"
else
  fail "run-pipeline.sh missing tier_allows_phase"
fi

# ============================================================
# 11. Security Checks
# ============================================================
section "Security"

# No hardcoded API keys
if grep -rn "sk-ant-\|ANTHROPIC_API_KEY=sk" "$ROOT" --include="*.sh" --include="*.py" --include="*.json" --exclude-dir=".git" 2>/dev/null | grep -v ".env.example" | grep -v ".gitignore"; then
  fail "Hardcoded API key found!"
else
  pass "No hardcoded API keys"
fi

# .gitignore blocks .env
if grep -q "^\.env$" "$ROOT/.gitignore"; then
  pass ".gitignore blocks .env"
else
  fail ".gitignore does not block .env"
fi

# ============================================================
# 12. Doc Template Cross-References
# ============================================================
section "Doc Template Cross-References"

for t in "${TEMPLATES[@]}"; do
  TMPL_FILE="$ROOT/docs/templates/$t.md"
  if [ -f "$TMPL_FILE" ]; then
    if grep -q "## Related Documents" "$TMPL_FILE"; then
      pass "template $t has Related Documents section"
    else
      fail "template $t missing Related Documents section"
    fi
  fi
done

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "  PASS: ${GREEN}${PASS}${NC}  FAIL: ${RED}${FAIL}${NC}  WARN: ${YELLOW}${WARN}${NC}"
echo -e "${GREEN}============================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  echo -e "\n${RED}Self-test FAILED with $FAIL failure(s).${NC}"
  exit 1
else
  echo -e "\n${GREEN}All tests passed.${NC}"
  exit 0
fi
