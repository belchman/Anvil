# Anvil — Pipeline Framework for Claude Code

Anvil enforces spec-before-code discipline on autonomous Claude Code sessions. 20 config variables, 6 tiers ($1-$50), external validator hooks. Deploy ~30 core files into any project. Benchmark suite: 10 tickets, 2 targets, automated scorer (zero LLM). 131 self-tests pass.

**Read CONTRIBUTING_AGENT.md for the development process.**

## Quick Reference
- Autonomous: `anvil run TICKET-ID`
- Interactive: `claude` then `/phase0` -> follow prompts
- Feature add: `/feature-add description`
- Cost report: `/cost-report`
- Heal pipeline: `/heal`

## Session Start
1. Run `/phase0` (mandatory, no exceptions)
2. Do not write code until docs are approved
3. Do not implement until executable specifications exist and fail

## Context Discipline
- Each phase starts a FRESH session (never --continue across phases)
- Before each phase, check context budget (target: 40-60% utilization)
- Large outputs go to docs/artifacts/ (Tier 3), not conversation
- Between phases: artifact -> pyramid summary -> Memory MCP -> fresh session
- Fidelity modes: full | truncate | compact | summary:high | medium | low

## Canonical Docs (read on demand, never preload all)
- docs/PRD.md, APP_FLOW.md, TECH_STACK.md, DATA_MODELS.md
- docs/API_SPEC.md, FRONTEND_GUIDELINES.md, IMPLEMENTATION_PLAN.md
- docs/TESTING_PLAN.md, SECURITY_CHECKLIST.md, OBSERVABILITY.md, ROLLOUT_PLAN.md
- docs/MEMORY_MCP_SCHEMA.md (entity naming reference)

## Absolute Rules
- Never write code until documentation is approved
- Never implement until executable specifications exist and fail (red phase)
- Write only the code required to make specs pass (green phase)
- Refactor only while all specs remain green
- Never skip verification after implementation steps
- Never proceed past a blocker without surfacing it
- Every error: root cause + prevention rule + lessons update
- Type everything. Handle all errors. Test critical paths.
- Match existing codebase patterns exactly.
- In autonomous mode: search -> infer -> assume (with [ASSUMPTION] tag)
- In interactive mode: never guess, ASK

## Gate Rules
- Verify gate: fail -> auto-retry (max 3) -> block
- Ship gate: all checks must pass before PR creation
- Holdout gate: >= 80% satisfaction required
- All review gates use LLM-as-judge (separate model from generator)

## Circuit Breakers
- Per-phase: --max-turns, --max-budget-usd, timeout
- Per-pipeline: MAX_PIPELINE_COST ceiling
- Kill switch: create .pipeline-kill to stop
- Stagnation: >90% similar errors across retries triggers reroute
