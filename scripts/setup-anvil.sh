#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Anvil Framework Setup
#
# One-command setup: checks prerequisites, creates config,
# validates structure, and runs a quick self-test.
#
# Usage:
#   ./scripts/setup-anvil.sh           # full setup
#   ./scripts/setup-anvil.sh --check   # check only, no changes
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

ok()   { echo -e "  ${GREEN}OK${NC}   $1"; }
miss() { echo -e "  ${RED}MISS${NC} $1"; }
rec()  { echo -e "  ${YELLOW}REC${NC}  $1"; }
info() { echo -e "  ${BLUE}INFO${NC} $1"; }

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

ERRORS=0

echo -e "\n${BOLD}Anvil Framework Setup${NC}\n"

# ---- 1. Required Prerequisites ----
echo -e "${BOLD}1. Required tools${NC}"

for cmd in claude jq git; do
  if command -v "$cmd" &>/dev/null; then
    version=$("$cmd" --version 2>/dev/null | head -1 || echo "unknown")
    ok "$cmd ($version)"
  else
    miss "$cmd not found"
    ((ERRORS++))
    case "$cmd" in
      claude) info "Install: npm install -g @anthropic-ai/claude-code" ;;
      jq)     info "Install: brew install jq (macOS) | apt install jq (Linux)" ;;
      git)    info "Install: brew install git (macOS) | apt install git (Linux)" ;;
    esac
  fi
done

# ---- 2. Optional Tools ----
echo -e "\n${BOLD}2. Optional tools${NC}"

for cmd in bc gh python3; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd (available)"
  else
    rec "$cmd not found (recommended)"
    case "$cmd" in
      bc)      info "Used for precise floating-point math. Install: brew install bc" ;;
      gh)      info "Used for PR creation in ship phase. Install: brew install gh" ;;
      python3) info "Used for Python runner + benchmark scorer. Install: brew install python3" ;;
    esac
  fi
done

# ---- 3. Environment Config ----
echo -e "\n${BOLD}3. Environment configuration${NC}"

if [ -f "$ROOT/.env" ]; then
  ok ".env exists"
elif [ -f "$ROOT/.env.example" ]; then
  if [ "$CHECK_ONLY" = true ]; then
    rec ".env missing (run without --check to create from .env.example)"
  else
    cp "$ROOT/.env.example" "$ROOT/.env"
    ok ".env created from .env.example"
    info "Edit .env to add your ANTHROPIC_API_KEY"
  fi
else
  miss ".env.example not found"
  ((ERRORS++))
fi

# ---- 4. Directory Structure ----
echo -e "\n${BOLD}4. Directory structure${NC}"

REQUIRED_DIRS=(
  ".claude/skills"
  ".claude/agents"
  ".claude/rules"
  "docs/templates"
  "docs/summaries"
  "docs/artifacts"
  "scripts"
  "benchmarks/tickets/expected"
  "benchmarks/target"
)

for dir in "${REQUIRED_DIRS[@]}"; do
  if [ -d "$ROOT/$dir" ]; then
    ok "$dir/"
  else
    if [ "$CHECK_ONLY" = true ]; then
      miss "$dir/ missing"
      ((ERRORS++))
    else
      mkdir -p "$ROOT/$dir"
      ok "$dir/ (created)"
    fi
  fi
done

# ---- 5. Core Files ----
echo -e "\n${BOLD}5. Core files${NC}"

CORE_FILES=(
  "CLAUDE.md"
  "run-pipeline.sh"
  "pipeline.config.sh"
  "pipeline.graph.dot"
  "pipeline.models.json"
)

for f in "${CORE_FILES[@]}"; do
  if [ -f "$ROOT/$f" ]; then
    ok "$f"
  else
    miss "$f missing"
    ((ERRORS++))
  fi
done

# Check run-pipeline.sh is executable
if [ -f "$ROOT/run-pipeline.sh" ] && [ ! -x "$ROOT/run-pipeline.sh" ]; then
  if [ "$CHECK_ONLY" = true ]; then
    rec "run-pipeline.sh is not executable"
  else
    chmod +x "$ROOT/run-pipeline.sh"
    ok "run-pipeline.sh (made executable)"
  fi
fi

# ---- 6. Quick Validation ----
echo -e "\n${BOLD}6. Quick validation${NC}"

if [ -f "$ROOT/scripts/test-anvil.sh" ]; then
  if bash "$ROOT/scripts/test-anvil.sh" quick > /dev/null 2>&1; then
    ok "test-anvil.sh quick passed"
  else
    miss "test-anvil.sh quick had failures (run manually for details)"
    ((ERRORS++))
  fi
else
  miss "test-anvil.sh not found"
  ((ERRORS++))
fi

# ---- Summary ----
echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}Setup complete. Anvil is ready.${NC}\n"
  echo "  Next steps:"
  echo "    Autonomous: ./run-pipeline.sh TICKET-ID"
  echo "    Interactive: claude  then /phase0"
  echo "    Benchmark:  ./scripts/run-benchmark.sh --dry-run"
  echo ""
else
  echo -e "${RED}${BOLD}Setup found $ERRORS issue(s).${NC} Fix them and re-run.\n"
  exit 1
fi
