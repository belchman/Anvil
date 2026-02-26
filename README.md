# Anvil

Cost-controlled harness for autonomous Claude Code sessions with quality gates and an audit trail.

**The problem**: AI code generation has no governance. Freestyle Claude ships whatever comes out — no cost ceiling, no quality gate, no audit trail. On hard cross-file tasks, it [consistently misses requirements](#freestyle-failure-modes-why-governance-matters) (BENCH-7: 80/100 on every run, never implements rollback). Costs vary 6x across identical tasks. A runaway session can burn $100 on a typo fix.

**The solution**: Anvil wraps Claude Code with the same controls engineering teams already use — cost ceilings, verification gates, and structured logging. Six tiers from $1 to $50: guard ($1-2) validates freestyle output, nano ($3-5) adds cost tracking, lite ($12-18) adds spec-first discipline and adversarial holdout testing. You match governance to risk.

**When to skip Anvil**: For simple, one-shot tasks where you'll review the output yourself. Freestyle scores 100% on single-module bugs — Anvil can't improve on that.

## Quick Start

```bash
# 1. One-command setup (checks prerequisites, creates .env, validates structure)
./scripts/setup-anvil.sh

# 2. Run the pipeline
./run-pipeline.sh "TICKET-ID"

# 3. Or use the Python alternative
pip install claude-agent-sdk-python
python run_pipeline.py "TICKET-ID"
```

## Pipeline Tiers

Anvil provides 6 pipeline tiers to match rigor to task complexity and budget:

| Tier | Cost | Time | What runs | Best for |
|------|------|------|-----------|----------|
| **guard** | $1-2 | 1-2 min | Context scan + security audit + ship (no implementation) | Post-hoc validation of freestyle output |
| **nano** | $3-5 | 2-3 min | Context scan + implement + verify only | Bug fixes, config changes, trivial tasks |
| **quick** | $8-15 | 5-10 min | + spec writing | Simple features, well-defined tasks |
| **lite** | $12-18 | 10-15 min | + holdout validation (adversarial testing) | Medium features where correctness matters |
| **standard** | $20-30 | 15-20 min | + doc generation + reviews | Most feature work |
| **full** | $40-50 | 30+ min | + security audit + dual-pass review | Production features, security-sensitive changes |

**Which tier should I use?** Start with `nano`. It's governed freestyle with cost tracking — 90% of tasks don't need more. Use `guard` to validate freestyle output you've already generated. Escalate to `lite` for cross-file changes where correctness matters. Use `standard`/`full` only in regulated environments.

```bash
# CLI flag (preferred)
./run-pipeline.sh "TICKET-ID" --tier lite

# Environment variable
PIPELINE_TIER=lite ./run-pipeline.sh "TICKET-ID"

# Auto-detect (default) — phase0 estimates scope 1-5, maps to tier
./run-pipeline.sh "TICKET-ID"
```

## Prerequisites

- **Claude Code CLI** (`claude`) installed and authenticated
- **git** with a configured remote
- **jq** (JSON processing)
- Optional: **bc** (precise math), **gh** (PR creation), **python3** (Python runner + benchmarks)

## Configuration

**Most users change nothing.** The defaults work. If you need to adjust:

- **`--tier lite`** (CLI flag or `PIPELINE_TIER` env var) — the only setting most teams touch
- **`MAX_PIPELINE_COST`** — hard ceiling per run (default: $50)
- **`REVIEW_VALIDATOR_COMMAND`** — plug in your own validators (non-LLM validator included and enabled by default)

Everything else (`pipeline.config.sh`: 20 variables, `pipeline.models.json`: per-phase model overrides, `.env`: API keys) has sensible defaults. Variables are grouped into Essential (3), Cost (6), Quality (4), and Advanced (7).

## What Each Tier Runs

Phases activate progressively. Lower tiers skip expensive governance phases:

| Phase | guard | nano | quick | lite | standard | full |
|-------|:-----:|:----:|:-----:|:----:|:--------:|:----:|
| Context Scan | Y | Y | Y | Y | Y | Y |
| Interrogation | — | — | Y | Y | Y | Y |
| Spec Writing (BDD) | — | — | Y | Y | Y | Y |
| Holdout Generation | — | — | — | Y | Y | Y |
| Implementation + verify | — | Y | Y | Y | Y | Y |
| Holdout Validation | — | — | — | Y | Y | Y |
| Doc Generation | — | — | — | — | Y | Y |
| Doc Review | — | — | — | — | Y | Y |
| Security Audit | Y | — | — | — | — | Y |
| Ship | Y | Y | Y | Y | Y | Y |

**guard** ($1-2) validates existing code without re-implementing — post-hoc security + quality check. **nano** ($3-5) is governed freestyle: cost tracking + structured logging. **lite** ($12-18) is the sweet spot for production: spec-first discipline + adversarial holdout testing. **full** ($40-50) is for regulated environments needing documentation + security audit.

## External Validators (Non-LLM Review by Default)

Every review gate runs a non-LLM validator **by default** (`REVIEW_VALIDATOR_COMMAND="./scripts/review-validator.sh"` in `pipeline.config.sh`). This 120-line script runs real static analysis — bash/Python/JSON syntax checking, hardcoded secret scanning, anti-pattern detection, and test suite execution. Zero LLM involvement. The strictest verdict across LLM review and external validation wins.

This is layered on top of cross-model diversity (Sonnet writes specs, Opus implements). Swap in any validator:

```bash
# Different model family
REVIEW_VALIDATOR_COMMAND="ollama run llama3 < /dev/stdin"

# Your existing tooling
REVIEW_VALIDATOR_COMMAND="mypy --strict src/ && ruff check src/"

# Any script that outputs PASS/FAIL/ITERATE with a score
REVIEW_VALIDATOR_COMMAND="python3 my_validator.py"
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success - PR created |
| 1 | Error - pipeline or phase failure |
| 2 | Needs Human - critical unknowns require human input |
| 3 | Blocked - implementation step failed after max retries |
| 4 | Holdout Failure - implementation doesn't meet hidden test scenarios |

## Safety Controls

- **Kill switch**: `touch .pipeline-kill` stops at next phase boundary, `rm .pipeline-kill` to re-enable
- **Cost ceiling**: `MAX_PIPELINE_COST` (default: $50), per-phase budgets in `pipeline.config.sh`
- **Cost tracking**: Per-phase costs logged to `docs/artifacts/pipeline-runs/*/costs.json`
- **Stagnation detection**: >90% similar errors across retries triggers reroute
- **CI/CD**: GitHub Actions workflow at `.github/workflows/autonomous-pipeline.yml` — triggers on `agent-ready` label or `workflow_dispatch`
- **Interactive mode**: `claude` then `/phase0` — the agent asks the human at each decision point instead of assuming

## What's Included

**Deploy to any project** (~30 core files): `run-pipeline.sh`, `run_pipeline.py`, `pipeline.config.sh` (20 variables), `pipeline.models.json`, `.claude/` (7 skills, 2 agents, 2 rules), `scripts/` (setup, test, benchmark, validator), `.github/workflows/` (CI/CD).

**Benchmark suite** (~55 additional files): 2 target projects (simple + hard), 10 tickets with expected scoring, automated scorer, benchmark runner.

**Skills**: `/phase0`, `/interrogate`, `/feature-add`, `/cost-report`, `/heal`, `/error-analysis`, `/update-progress`. **Agents**: `healer` (auto-fix), `supervisor` (monitoring). **Rules**: `no-assumptions.md`, `context-management.md`.

## Benchmarks

Anvil includes a reproducible benchmark suite for measuring code quality with zero LLM involvement in scoring.

### Two Target Projects

| Target | Size | Modules | Seeded Defects | Tickets |
|--------|------|---------|----------------|---------|
| **simple** (`benchmarks/target/`) | 130 lines | 1 (tasktrack) | 3 (off-by-one, code injection, missing feature) | BENCH-1..5 |
| **hard** (`benchmarks/target-hard/`) | 430 lines | 6 (invtrack) | 5 cross-file bugs requiring multi-file reasoning | BENCH-6..10 |

The hard target's bugs span module boundaries (e.g., cache mutation aliasing between store.py and inventory.py, missing rollback across orders.py and inventory.py) — the kind of defects that require reading multiple files together.

### Automated Scorer

`benchmarks/score.py` provides 11 check types (AST parsing, pytest execution, grep patterns, file existence, test counting) with weighted scoring. No LLM involvement — pure static analysis + test execution. Each ticket has a JSON spec defining its quality checks.

### Running Benchmarks

```bash
# Run all tickets on simple target (freestyle only)
./scripts/run-benchmark.sh --target target --approach freestyle

# Run hard tickets (multi-file bugs)
./scripts/run-benchmark.sh --target target-hard --approach freestyle

# Compare Anvil vs freestyle
./scripts/run-benchmark.sh --target target-hard --approach both

# Single ticket
./scripts/run-benchmark.sh --target target-hard --ticket BENCH-6 --approach freestyle
```

Evidence output: `docs/artifacts/benchmark-*/benchmark-evidence.json` with per-ticket scores, costs, and cost-per-quality-point metrics.

### Benchmark Results

**Scorer discrimination** (unfixed targets — proves checks are real gates, not rubber stamps):

| Target | Unfixed Baseline | Description |
|--------|-----------------|-------------|
| Simple | 48/100 avg | 3 seeded defects in single module |
| Hard | 39/100 avg | 5 cross-file bugs across 6 modules |

**Freestyle (Claude Code, no pipeline) results:**

| Target | Tickets | Avg Score | Total Cost | Avg Time |
|--------|---------|-----------|------------|----------|
| Simple (BENCH-1..5) | 5 | **100/100** | $1.23 | 54s |
| Hard (BENCH-6..10) | 5 | **92/100** | $2.30 | 119s |

Hard target breakdown:

| Ticket | Task | Score | What freestyle missed |
|--------|------|-------|-----------------------|
| BENCH-6 | Fix mutation aliasing (store→inventory) | 90/100 | `last_adjusted` mutation still present in inventory.py |
| BENCH-7 | Add rollback to order processing | 80/100 | No rollback tracking variable in place_order() |
| BENCH-8 | Fix pagination off-by-one | 100/100 | — |
| BENCH-9 | Security audit: fix all validation gaps | 90/100 | BUG comments left in reports.py and inventory.py |
| BENCH-10 | Refactor: extract Validator class | 100/100 | — |

### Freestyle Failure Modes (Why Governance Matters)

Variance studies (5 identical runs per ticket) reveal two distinct failure patterns on hard cross-file bugs:

**BENCH-6** — cache mutation aliasing (store.py → inventory.py), N=5:

| Runs | Score | What happened |
|------|-------|---------------|
| 1 of 5 | **55/100** | Missed copy fix entirely, mutation present, no test added |
| 4 of 5 | 90/100 | Fixed copy but `last_adjusted` mutation remains in inventory.py |

Mean: 83, Range: **35 points**. One in five runs drops from "ships" to "fails review."

**BENCH-7** — missing rollback (orders.py → inventory.py), N=5:

| Runs | Score | What happened |
|------|-------|---------------|
| 5 of 5 | **80/100** | Never adds rollback tracking to `place_order()` |

Mean: 80, Range: **0 points**. Running freestyle 100 times won't fix it. The model consistently misses transactional rollback for partial failures — a 20-point quality ceiling.

**Two failure modes that governance targets:**
- **Stochastic drops** (BENCH-6): Verification retries catch defects; if unfixable, the pipeline blocks rather than shipping silently. Measured on BENCH-6: pipeline detected `last_adjusted` mutation and blocked.
- **Systematic blind spots** (BENCH-7): Holdout validation generates adversarial test scenarios before implementation (e.g., "order fails on item 3 — are items 1-2 rolled back?"). Designed to catch exactly the class of missing-requirement defects that freestyle consistently ships.

BENCH-8 through BENCH-10 showed zero variance and 93-100/100 scores. Freestyle handles simple and medium tasks well — governance overhead is concentrated where it's needed most.

### Anvil Lite Head-to-Head (BENCH-6)

| Metric | Freestyle | Anvil Lite |
|--------|-----------|------------|
| Quality score | 90/100 | 90/100 |
| Cost | $0.44 | $5.67 |
| Time | 99s | 21 min |
| Verification | None — ships whatever comes out | 3 retry cycles caught residual `last_adjusted` mutation |
| Audit trail | None | Per-phase costs, models, turns logged |
| Cost predictability | $0.24-$1.45 (6x range across runs) | Bounded by per-phase budgets |

Anvil doesn't claim higher scores — it provides governance. The pipeline detected the residual mutation, retried implementation three times, and when verification kept failing, blocked rather than shipping. Freestyle shipped the same quality code without knowing anything was wrong. The difference is visibility and control, not magic.

**Where the $5.67 went**: $2.25 governance overhead (context scan, interrogation, specs, holdout generation) + $3.42 implementation with verification retries. For most tasks, **nano** ($3-5) or **guard** ($1-2) is sufficient — escalate to lite only for cross-file changes where BENCH-7's quality ceiling applies.

### Dogfooding: Benchmarks as Integration Tests

Running the benchmark suite against Anvil itself found 5 pipeline bugs (all fixed) that structural self-tests missed — tier filtering broken, macOS incompatibility, config overrides ignored. This is the same principle Anvil applies to AI-generated code: end-to-end testing catches what unit tests miss. The benchmark suite now serves as Anvil's own integration test layer.

## Self-Test Suite

```bash
./scripts/test-anvil.sh        # Full suite (192 checks)
./scripts/test-anvil.sh quick  # Skip slow checks
```

Validates: file inventory, bash/Python/JSON syntax, config completeness, cross-references, portability, security, and version tracking. Python alternative: `run_pipeline.py` provides the same logic via Claude Agent SDK with structured dataclasses and async/await.
