# Anvil

Autonomous spec-to-PR pipeline framework for Claude Code. Anvil takes a ticket ID or feature description and autonomously produces a fully-implemented, tested, and reviewed pull request -- zero human interaction required between assignment and PR creation.

## Prerequisites

- **Claude Code CLI** installed and authenticated
- **Node.js 18+** (for Agent SDK)
- **git** with a configured remote
- **jq** and **bc** (used by the pipeline harness)
- **GitHub CLI** (`gh`) for PR creation

## Quick Start

```bash
# 1. Clone and configure
cp .env.example .env
# Edit .env with your ANTHROPIC_API_KEY and GITHUB_PAT

# 2. Run the pipeline
./run-pipeline.sh "TICKET-ID"

# 3. Or use the Python alternative
pip install claude-agent-sdk-python
python run_pipeline.py "TICKET-ID"
```

## Configuration

### pipeline.config.sh
Centralized configuration for all phase limits: models, max turns, budgets, timeouts, retry limits, and stagnation detection thresholds. Source this file to customize cost/quality tradeoffs.

### pipeline.models.json
CSS-like model stylesheet. Defines the default model and per-phase-type overrides (routing, review, generation, implementation, security, holdout, healer, supervisor) with cost weights.

### .env
Environment variables for API keys, autonomous mode toggle, cost ceiling, and model overrides.

## Pipeline Phases

The pipeline executes 9 stages in sequence, with gate-based routing between them:

| Stage | Name | Description |
|-------|------|-------------|
| 1 | **Context Scan** | Scans git state, Memory MCP, project type, blockers |
| 2 | **Interrogation** | Autonomous requirements gathering across all 13 sections |
| 3 | **Interrogation Review** | LLM-as-judge evaluates completeness (gate: >= 70%) |
| 4 | **Doc Generation** | Generates all project docs from templates |
| 5 | **Doc Review** | LLM-as-judge validates docs (gate: >= 80%) |
| 6 | **Implementation** | Executes each step from IMPLEMENTATION_PLAN.md |
| 7 | **Holdout Validation** | Tests against hidden adversarial scenarios (gate: >= 80%) |
| 8 | **Security Audit** | Scans for OWASP vulnerabilities and hardcoded secrets |
| 9 | **Ship** | Final test suite, PR creation, push |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success - PR created |
| 1 | Error - pipeline or phase failure |
| 2 | Needs Human - critical unknowns require human input |
| 3 | Blocked - implementation step failed after max retries |
| 4 | Holdout Failure - implementation doesn't meet hidden test scenarios |

## Kill Switch

Create a `.pipeline-kill` file in the project root to immediately stop the pipeline at the next phase boundary:

```bash
# Stop the pipeline
touch .pipeline-kill

# Re-enable
rm .pipeline-kill
```

## Cost Management

- **Per-phase budgets**: Each phase has a `--max-budget-usd` ceiling (configured in `pipeline.config.sh`)
- **Pipeline ceiling**: `MAX_PIPELINE_COST` environment variable (default: $50)
- **Cost tracking**: Per-phase costs logged to `docs/artifacts/pipeline-runs/*/costs.json`
- **Cost report**: Run `/cost-report` in interactive mode to see historical spend

## CI/CD Integration

A GitHub Actions workflow is included at `.github/workflows/autonomous-pipeline.yml`. It triggers on:
- Issues labeled `agent-ready`
- Manual `workflow_dispatch` with a ticket ID

Required secrets: `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`.

Pipeline logs are uploaded as artifacts on every run.

## Interactive vs Autonomous Mode

### Autonomous Mode
```bash
./run-pipeline.sh "TICKET-ID"
```
Runs the full pipeline headlessly. The agent searches MCP sources, infers from codebase patterns, and makes tagged assumptions (`[ASSUMPTION: rationale]`) when data is unavailable.

### Interactive Mode
```bash
claude
# Then: /phase0
```
The agent asks the human for input at each decision point. No assumptions are made -- all unknowns are surfaced as questions.

## Directory Structure

```
.
├── CLAUDE.md                          # Quick reference (< 50 lines)
├── CONTRIBUTING_AGENT.md              # Development process - BDD discipline for agents
├── run-pipeline.sh                    # Bash pipeline harness
├── run_pipeline.py                    # Python Agent SDK alternative
├── pipeline.config.sh                 # Phase limits configuration
├── pipeline.models.json               # Model stylesheet
├── pipeline.graph.dot                 # Pipeline graph definition
├── .env.example                       # Environment template
├── progress.txt                       # Fallback persistence
├── lessons.md                         # Fallback persistence
├── decisions.md                       # Fallback persistence
├── .claude/
│   ├── settings.json                  # Permissions and hooks
│   ├── skills/                        # Skill definitions (SKILL.md per directory)
│   │   ├── phase0/                    # Context scan
│   │   ├── interrogate/               # Requirements gathering
│   │   ├── feature-add/               # Quick feature addition
│   │   ├── cost-report/               # Cost analysis
│   │   ├── parallel-docs/             # Agent Teams doc generation
│   │   ├── satisfaction-score/         # Quality scoring
│   │   ├── generate-dtu/              # Digital twin mocks
│   │   ├── update-progress/           # Progress tracking
│   │   ├── error-analysis/            # Error pattern detection
│   │   ├── heal/                      # Self-healing
│   │   └── oracle-verify/             # Oracle verification
│   ├── agents/                        # Agent definitions
│   │   ├── healer.md                  # Self-healing agent
│   │   └── supervisor.md              # Pipeline supervisor
│   └── rules/                         # Auto-applied rules
│       ├── no-assumptions.md          # Assumptions policy
│       ├── context-fidelity.md        # Context management
│       ├── context-budget.md          # Token budgeting
│       └── compaction.md              # FIC pattern
├── .github/
│   └── workflows/
│       └── autonomous-pipeline.yml    # CI/CD trigger
├── scripts/
│   ├── agent-test.sh                  # AI-optimized test runner
│   └── test-anvil.sh                  # Framework self-test suite
├── docs/
│   ├── MEMORY_MCP_SCHEMA.md           # Entity naming reference
│   ├── templates/                     # Document templates
│   │   ├── PRD.md
│   │   ├── APP_FLOW.md
│   │   ├── TECH_STACK.md
│   │   ├── DATA_MODELS.md
│   │   ├── API_SPEC.md
│   │   ├── FRONTEND_GUIDELINES.md
│   │   ├── IMPLEMENTATION_PLAN.md
│   │   ├── TESTING_PLAN.md
│   │   ├── SECURITY_CHECKLIST.md
│   │   ├── OBSERVABILITY.md
│   │   └── ROLLOUT_PLAN.md
│   ├── summaries/                     # Tier 2: Pyramid summaries
│   └── artifacts/                     # Tier 3: Full outputs
│       └── pipeline-runs/             # Per-run logs and costs
└── .holdouts/                         # Hidden test scenarios
```

## Skills Reference

| Skill | Description |
|-------|-------------|
| `/phase0` | Context scan - mandatory session start |
| `/interrogate` | Full requirements gathering (13 sections) |
| `/generate-docs` | Generate all project documentation |
| `/verify` | Run verification gate on implementation |
| `/ship` | Pre-flight checks and PR creation |
| `/cost-report` | Historical pipeline cost analysis |
| `/heal` | Run self-healing agent |
| `/feature-add` | Quick single-feature addition |
| `/update-progress` | Update PROGRESS.md and Memory MCP |
| `/satisfaction-score` | Calculate quality score for phase output |
| `/parallel-docs` | Generate docs in parallel via Agent Teams |
| `/generate-dtu` | Create mock services for API testing |
| `/oracle-verify` | Reference-based verification |
| `/error-analysis` | Cross-run error pattern detection |

## Agents Reference

| Agent | Role |
|-------|------|
| **healer** | Observes pipeline failures, clusters errors, generates and applies fixes |
| **supervisor** | Monitors cross-phase metrics, detects anomalies, can override routing |

## Rules Reference

| Rule | Scope | Purpose |
|------|-------|---------|
| `no-assumptions.md` | `**/*` | Assumptions policy for interactive/autonomous modes |
| `context-fidelity.md` | `**/*` | Six fidelity modes for context loading |
| `context-budget.md` | `**/*` | Token budget estimation per phase |
| `compaction.md` | `**/*` | Frequent Intentional Compaction (FIC) pattern |

## Python Alternative

`run_pipeline.py` provides the same pipeline logic as the bash harness but with:
- Structured Python dataclasses (`PhaseConfig`, `PhaseResult`, `PipelineState`)
- Proper async/await with timeout handling
- Type-safe verdict and satisfaction score parsing
- Extensible hooks via Claude Agent SDK

```bash
pip install claude-agent-sdk-python
python run_pipeline.py "TICKET-ID"
```

Use the bash harness for quick setup and CI/CD. Use the Python runner for production deployments needing structured error handling and extensibility.
