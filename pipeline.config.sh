#!/usr/bin/env bash
# Pipeline phase configuration
# Edit these values to tune cost/quality tradeoffs

# Models per phase (use cheaper models for review/routing, Opus for generation)
MODEL_PHASE0="claude-sonnet-4-5-20250929"
MODEL_INTERROGATE="claude-opus-4-6"
MODEL_REVIEW="claude-sonnet-4-5-20250929"
MODEL_GENERATE_DOCS="claude-opus-4-6"
MODEL_IMPLEMENT="claude-opus-4-6"
MODEL_VERIFY="claude-sonnet-4-5-20250929"
MODEL_SECURITY="claude-sonnet-4-5-20250929"
MODEL_HOLDOUT_GENERATE="claude-opus-4-6"
MODEL_HOLDOUT_VALIDATE="claude-sonnet-4-5-20250929"
MODEL_WRITE_SPECS="claude-sonnet-4-5-20250929"
MODEL_SHIP="claude-sonnet-4-5-20250929"

# Max turns per phase (circuit breaker)
TURNS_PHASE0=15
TURNS_INTERROGATE=50
TURNS_REVIEW=20
TURNS_GENERATE_DOCS=50
TURNS_IMPLEMENT=40
TURNS_VERIFY=15
TURNS_SECURITY=20
TURNS_HOLDOUT_GENERATE=25
TURNS_HOLDOUT_VALIDATE=25
TURNS_WRITE_SPECS=30
TURNS_SHIP=20

# Max budget per phase in USD (circuit breaker)
BUDGET_PHASE0=2
BUDGET_INTERROGATE=8
BUDGET_REVIEW=3
BUDGET_GENERATE_DOCS=10
BUDGET_IMPLEMENT=8
BUDGET_VERIFY=3
BUDGET_SECURITY=3
BUDGET_HOLDOUT_GENERATE=5
BUDGET_HOLDOUT_VALIDATE=5
BUDGET_WRITE_SPECS=5
BUDGET_SHIP=5

# Total pipeline ceiling
MAX_PIPELINE_COST=50

# Retry limits
MAX_VERIFY_RETRIES=3
MAX_INTERROGATION_ITERATIONS=2

# Stagnation detection
STAGNATION_SIMILARITY_THRESHOLD=90  # percent

# Kill switch
KILL_SWITCH_FILE=".pipeline-kill"

# Phase timeouts in seconds (10 min default)
TIMEOUT_PHASE0=120
TIMEOUT_INTERROGATE=600
TIMEOUT_REVIEW=300
TIMEOUT_GENERATE_DOCS=600
TIMEOUT_IMPLEMENT=600
TIMEOUT_VERIFY=300
TIMEOUT_SECURITY=300
TIMEOUT_HOLDOUT_GENERATE=300
TIMEOUT_HOLDOUT_VALIDATE=300
TIMEOUT_WRITE_SPECS=300
TIMEOUT_SHIP=300

# Progress tracking
MAX_NO_PROGRESS=3  # consecutive impl phases without git commits -> stall

# Context window target (tokens)
CONTEXT_WINDOW=200000

# Satisfaction thresholds (0-100 scale, converted to decimal in runners)
THRESHOLD_AUTO_PASS=90
THRESHOLD_PASS=70
THRESHOLD_ITERATE=50
THRESHOLD_DOC_REVIEW=80
THRESHOLD_HOLDOUT=80

# Directory paths (relative to project root)
DOCS_DIR="docs"
ARTIFACTS_DIR="docs/artifacts"
SUMMARIES_DIR="docs/summaries"
TEMPLATES_DIR="docs/templates"
HOLDOUTS_DIR=".holdouts"
LOG_BASE_DIR="docs/artifacts/pipeline-runs"

# Phase execution order (space-separated)
PHASE_ORDER="phase0 interrogate interrogation-review generate-docs doc-review write-specs holdout-generate implement holdout-validate security-audit ship"

# Pipeline tier: auto | full | standard | quick | nano
# auto = phase0 estimates scope and selects tier
# full = all phases (~$40-50, 30+ min)
# standard = skip holdouts, single-pass reviews (~$20-30, 15-20 min)
# quick = single-pass reviews, skip holdouts, security, write-specs (~$8-15, 5-10 min)
# nano = interrogate + implement + verify only (~$3-5, 2-3 min) for trivial changes
PIPELINE_TIER="auto"

# Pipeline outcome metrics file (cumulative across runs)
METRICS_FILE="docs/artifacts/pipeline-metrics.json"

# Doc template selection mode
# auto = phase0 detects project type, only relevant templates are generated
# all = generate all 11 templates regardless of project type
# minimal = only PRD, IMPLEMENTATION_PLAN, TESTING_PLAN (fastest)
# none = skip doc generation entirely (for nano tier or when docs exist)
DOC_TEMPLATES_MODE="auto"

# Human gates: comma-separated phase names where pipeline pauses for human approval
# Empty = fully autonomous. Example: HUMAN_GATES="write-specs,doc-review"
# When a human gate is reached, the pipeline writes output and exits with code 2 (needs human).
# Resume with --resume after human review.
HUMAN_GATES=""

# External review validator command (optional, empty = disabled)
# If set, review output is piped to this command for independent 3rd-party validation.
# The command receives the review JSON on stdin and must output a line containing VERDICT: PASS|FAIL|ITERATE
# Use this to integrate non-Anthropic models, static analyzers, or human review scripts.
# Example: REVIEW_VALIDATOR_COMMAND="python3 scripts/external-review.py"
REVIEW_VALIDATOR_COMMAND="./scripts/review-validator.sh"

# CLI command for the AI agent (supports claude, or a wrapper script with compatible flags)
# Note: Python runner uses Claude Agent SDK directly; AGENT_COMMAND applies to bash runner only
AGENT_COMMAND="claude"

# Default phase timeout (seconds) when no phase-specific timeout exists
DEFAULT_TIMEOUT=600

# Context fidelity auto-adjustment thresholds (percent of window)
FIDELITY_UPGRADE_THRESHOLD=30
FIDELITY_DOWNGRADE_THRESHOLD=60

# Guard: ensure no timeout/threshold is zero (would cause immediate timeout or broken gates)
while IFS='=' read -r _t_var _; do
  case "$_t_var" in
    TIMEOUT_*|THRESHOLD_*|DEFAULT_TIMEOUT|FIDELITY_*_THRESHOLD)
      if [ "${!_t_var}" -eq 0 ] 2>/dev/null; then
        echo "[WARN] ${_t_var}=0 would cause immediate timeout, setting to 60"
        eval "${_t_var}=60"
      fi
      ;;
  esac
done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "${BASH_SOURCE[0]}")
unset _t_var
