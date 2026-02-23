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
MODEL_HOLDOUT="claude-sonnet-4-5-20250929"
MODEL_SHIP="claude-sonnet-4-5-20250929"

# Max turns per phase (circuit breaker)
TURNS_PHASE0=15
TURNS_INTERROGATE=50
TURNS_REVIEW=20
TURNS_GENERATE_DOCS=50
TURNS_IMPLEMENT=40
TURNS_VERIFY=15
TURNS_SECURITY=20
TURNS_HOLDOUT=25
TURNS_SHIP=20

# Max budget per phase in USD (circuit breaker)
BUDGET_PHASE0=2
BUDGET_INTERROGATE=8
BUDGET_REVIEW=3
BUDGET_GENERATE_DOCS=10
BUDGET_IMPLEMENT=8
BUDGET_VERIFY=3
BUDGET_SECURITY=3
BUDGET_HOLDOUT=5
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
TIMEOUT_HOLDOUT=300
TIMEOUT_SHIP=300

# Progress tracking
MAX_NO_PROGRESS=3  # consecutive impl phases without git commits -> stall

# Context window target (tokens)
CONTEXT_WINDOW=200000

# Guard: ensure no timeout is zero (would cause immediate timeout)
for _t_var in TIMEOUT_PHASE0 TIMEOUT_INTERROGATE TIMEOUT_REVIEW TIMEOUT_GENERATE_DOCS \
  TIMEOUT_IMPLEMENT TIMEOUT_VERIFY TIMEOUT_SECURITY TIMEOUT_HOLDOUT TIMEOUT_SHIP; do
  if [ "${!_t_var}" -eq 0 ] 2>/dev/null; then
    echo "[WARN] ${_t_var}=0 would cause immediate timeout, setting to 60"
    eval "${_t_var}=60"
  fi
done
unset _t_var
