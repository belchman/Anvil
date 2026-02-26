#!/usr/bin/env bash
# Pipeline configuration — 20 variables total
#
# ESSENTIAL (start here):
#   PIPELINE_TIER     - auto|full|standard|lite|quick|nano|guard — controls which phases run
#   MAX_PIPELINE_COST - hard ceiling on total spend per run (USD)
#   AGENT_COMMAND     - CLI command for the AI agent (default: "claude")
#
# TUNE FOR COST (reduce spend):
#   BUDGET_*          - per-category dollar caps (LOW/MEDIUM/HIGH)
#   TURNS_*           - per-category turn limits (QUICK/MEDIUM/LONG)
#   DOC_TEMPLATES_MODE - minimal|auto|all — fewer docs = less spend
#
# TUNE FOR QUALITY:
#   THRESHOLD_*       - raise pass thresholds for stricter gates
#   MAX_VERIFY_RETRIES - retry failed steps more times
#   HUMAN_GATES       - add phases that require human approval
#   REVIEW_VALIDATOR_COMMAND - plug in external validators
#
# Models are configured in pipeline.models.json (CSS-like stylesheet).
# Timeouts, directory paths, and advanced settings have sensible defaults
# in run-pipeline.sh — override via environment variables if needed.

# Framework version
ANVIL_VERSION="3.1"

# Phase turn limits by category
TURNS_QUICK=15     # phase0, verify
TURNS_MEDIUM=25    # reviews, holdout, write-specs, ship, security
TURNS_LONG=50      # interrogate, generate-docs, implement

# Phase budget limits by category (USD)
BUDGET_LOW=3       # phase0, verify, reviews
BUDGET_MEDIUM=5    # holdout, write-specs, ship
BUDGET_HIGH=10     # interrogate, generate-docs, implement

# Pipeline-level controls
MAX_PIPELINE_COST="${MAX_PIPELINE_COST:-50}"
MAX_VERIFY_RETRIES=3
DEFAULT_TIMEOUT=600
PIPELINE_TIER="${PIPELINE_TIER:-auto}"

# Gate thresholds (0-100 scale, converted to decimal in runners)
THRESHOLD_AUTO_PASS=90
THRESHOLD_PASS=70
THRESHOLD_ITERATE=50
THRESHOLD_DOC_REVIEW=80
THRESHOLD_HOLDOUT=80

# Customization
AGENT_COMMAND="claude"
DOC_TEMPLATES_MODE="auto"
HUMAN_GATES=""
REVIEW_VALIDATOR_COMMAND="./scripts/review-validator.sh"
