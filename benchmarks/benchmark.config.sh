#!/usr/bin/env bash
# Benchmark-specific overrides for pipeline.config.sh
# Tighter budgets to keep benchmark runs affordable.
# Source this AFTER pipeline.config.sh to override values.

# Tighter phase limits
TURNS_QUICK=10
TURNS_MEDIUM=15
TURNS_LONG=30
BUDGET_LOW=2
BUDGET_MEDIUM=3
BUDGET_HIGH=5

# Lower pipeline ceiling
MAX_PIPELINE_COST=25

# Shorter timeouts (seconds)
TIMEOUT_PHASE0=90
TIMEOUT_INTERROGATE=300
TIMEOUT_REVIEW=180
TIMEOUT_GENERATE_DOCS=300
TIMEOUT_IMPLEMENT=300
TIMEOUT_VERIFY=180
TIMEOUT_SECURITY=180
TIMEOUT_HOLDOUT_GENERATE=180
TIMEOUT_HOLDOUT_VALIDATE=180
TIMEOUT_WRITE_SPECS=180
TIMEOUT_SHIP=180
