# Anvil: The Pitch (For and Against)

## FOR: Why This Is the Correct Approach (~2 min read)

The fundamental problem with AI-assisted coding today is that it operates at the wrong level of abstraction. You give a model a prompt, it writes code, you eyeball it, you ship it. That workflow has no memory, no verification, no separation of concerns, and no cost control. It works for 50-line scripts. It falls apart at 500 lines. It is outright dangerous at 5,000.

Anvil addresses this by treating AI code generation as an **engineering pipeline** rather than a conversation. The thesis: if you constrain an LLM with the same discipline you would apply to a junior developer -- specification before implementation, review before merge, separation of generator and reviewer -- you get dramatically more reliable output.

**The pipeline is real and concrete.** `run-pipeline.sh` (1,224 lines) and `run_pipeline.py` (1,197 lines) implement 11 phases: context scan, interrogation, interrogation review, doc generation, doc review, spec writing, holdout generation, implementation, holdout validation, security audit, and ship. Each phase has per-phase model selection, budget caps, turn limits, and timeouts defined in `pipeline.config.sh` (45+ config variables). The routing graph (`pipeline.graph.dot`) defines every legal state transition. This is not a README describing a dream -- it is a functioning state machine with circuit breakers.

**Cross-model review eliminates the same-brain problem.** Sonnet writes the specs (RED phase). Opus implements to make them pass (GREEN phase). Sonnet reviews Opus's work. The review gate runs dual-pass evaluation with position bias mitigation -- sections are evaluated in normal order, then reversed order, with the stricter verdict winning. An external review validator (`review-validator.sh`) runs real static analysis -- bash syntax checking, Python AST parsing, JSON validation, security scans -- breaking the "LLM reviewing LLM" loop entirely.

**Holdout scenarios are adversarial specifications the implementer never sees.** One model generates edge cases. A different model validates the implementation against them. The implementing agent has no access to the holdout scenarios during coding. This separation is the closest thing to genuine independent verification you can get from a pipeline that runs autonomously.

**Cost governance is built in, not bolted on.** The `pipeline.models.json` stylesheet assigns Opus ($1.0 weight) to generation and Sonnet ($0.2 weight) to review and routing. Four pipeline tiers -- full ($40-50), standard ($20-30), quick ($8-15), nano ($3-5) -- let you match rigor to scope. Phase 0 auto-detects scope and selects the tier. Per-phase budgets, a $50 pipeline ceiling, a kill switch (`.pipeline-kill`), and stagnation detection (>90% error similarity triggers reroute) prevent runaway spend.

**Context discipline treats the token window as a budget.** Six fidelity modes (full, truncate, compact, summary:high/medium/low) control how much prior-phase context loads into each new session. Auto-adjustment downgrades fidelity when estimated tokens exceed 60% of the window. The Frequent Intentional Compaction (FIC) pattern forces large outputs to disk with pyramid summaries. This is not theoretical -- the `select_fidelity()` function exists in both runners.

**The framework validates itself -- and now benchmarks itself.** `test-anvil.sh` (252 tests) checks file inventory, syntax validity, JSON structure, DOT graph integrity, config completeness, cross-reference integrity, portability, and security. `self-validate.sh` runs the framework's own review tools against itself. The benchmark suite (`benchmarks/`) provides a controlled, reproducible comparison against a purpose-built target project with seeded defects, automated quality scoring (0-100 per ticket, 8 check types, no LLM involvement in scoring), and machine-readable evidence output. The benchmark infrastructure has been run end-to-end and produces real data (see Evidence section below).

**It is portable.** 61+ files, zero external dependencies beyond `claude`, `jq`, `git`, and optionally `bc` and `gh`. Drop it into any project. The CI/CD workflow triggers on an `agent-ready` label or manual dispatch. 11 skills, 2 agents (healer, supervisor), 4 rules, 11 doc templates. It does not care what language your project uses.

The bet: structure beats freestyle. Verification beats vibes. Specification before implementation is not bureaucracy -- it is how you prevent an LLM from confidently shipping hallucinated code.

---

## AGAINST: Why This Is the Wrong Approach (~2 min read)

Let us be honest about what Anvil actually is: **a 2,400-line harness that orchestrates a chatbot to follow a waterfall process, and the entire value proposition depends on the chatbot being obedient to its own system prompts.**

Start with the economics. The "full" tier costs $40-50 per ticket. For a team shipping 10 tickets a day, that is $400-500/day in API costs -- $10,000/month -- to produce code that still requires human review because no sane engineering organization will merge AI-generated PRs without looking at them. The "nano" tier costs $3-5 but skips holdouts, security audit, and spec writing -- which means it skips everything that supposedly makes Anvil better than just prompting Claude directly. The tiers that are cheap enough to use regularly are the tiers that remove Anvil's differentiators.

The "cross-model review" is theater. Sonnet and Opus are both Anthropic models trained on overlapping data with similar failure modes. Calling this "cross-model diversity" is like getting a second opinion from a doctor at the same hospital who trained under the same attending. The dual-pass bias mitigation (evaluating sections in normal then reversed order) addresses a real problem -- position bias -- but position bias is roughly the 47th most important failure mode of LLM code review. The top failure mode is that LLMs are bad at catching subtle logical errors, and no amount of section reordering fixes that.

The holdout system is Anvil's most interesting idea, and also its most fragile. The holdouts are generated by an LLM. The validation is performed by an LLM. The separation between generator and validator exists only at the prompt level -- both models share the same training data, the same reasoning patterns, and the same blind spots. If Opus cannot imagine an edge case while implementing, there is a meaningful probability that Opus also cannot imagine it while generating holdout scenarios. You are testing the model's imagination against its own imagination with a different system prompt.

The `review-validator.sh` is marketed as breaking the "LLM reviewing LLM" loop. It checks bash syntax, Python AST parsing, JSON validity, no hardcoded secrets, and no eval with user input. That is a linter. It is a useful linter, but calling it a "non-LLM review validator" implies a level of semantic code review that is not happening. It cannot detect logical bugs, incorrect business logic, race conditions, or any of the defects that actually matter in production code. The verdicts it produces (PASS/FAIL) have the granularity of a smoke test.

**The benchmark results complicate the narrative.** The initial benchmark run (5 tickets, 3 seeded defects in a ~130-line Python project) scored freestyle Claude at 100/100 on all 5 tasks in 309 seconds total. No Anvil overhead, no multi-phase pipeline, no document generation -- just a single prompt with the ticket description. Every bug was fixed, every feature was added, every test was written. If a single prompt produces perfect output on the benchmark suite, what exactly is Anvil adding? The answer is "governance for when the task is harder" -- but the benchmark hasn't proven that yet because the target project is deliberately small. The benchmark proves Anvil's testing infrastructure works. It does not yet prove Anvil produces better code than prompting Claude directly.

The 252-test self-test suite sounds impressive until you realize what it tests: file existence, syntax validity, JSON parsing, cross-reference integrity, and portability. It validates that Anvil's files are well-formed. It does not test that the pipeline produces correct code. It does not test that the holdout system catches real bugs. It does not test that the cost tracking is accurate. It does not test that the context fidelity system actually prevents context overflow. The benchmark suite is a step toward integration testing, but the current target project (130 lines, 3 seeded defects) is not complex enough to expose the failure modes that Anvil is designed to prevent.

The documentation overhead is staggering. 11 document templates (PRD, APP_FLOW, TECH_STACK, DATA_MODELS, API_SPEC, FRONTEND_GUIDELINES, IMPLEMENTATION_PLAN, TESTING_PLAN, SECURITY_CHECKLIST, OBSERVABILITY, ROLLOUT_PLAN) generated for every feature -- even with adaptive selection, you are asking an LLM to produce thousands of words of documentation that will be read by another LLM. This is AI busywork: models writing documents for models to read. The documentation is not for humans. It is not maintained by humans. It will not be accurate 30 days after generation. It is ceremony masquerading as rigor.

The "Interrogation Protocol" asks 13 sections of requirements questions. In autonomous mode, the agent searches MCP sources, infers from codebase patterns, and makes tagged assumptions. In practice, most codebases do not have Jira, Confluence, Slack, and Google Drive all wired up via MCP. The agent will make a pile of `[ASSUMPTION: rationale]` tags and proceed on best guesses. The assumptions review is performed by... another LLM. The assumptions that matter most (auth models, compliance requirements, data retention policies) are exactly the ones the LLM is least qualified to assume.

The entire architecture assumes that more process equals better output. But the process itself runs on LLMs, which means every phase introduces its own error rate. An 11-phase pipeline where each phase has a 90% success rate produces end-to-end success only 31% of the time. The retry loops and gate thresholds mitigate this, but they also multiply cost. A failed holdout validation routes back to implementation, which routes through verify again, which may fail and route back again. The cost ceiling exists because without it, the pipeline would happily spend hundreds of dollars retrying itself into oblivion.

The honest assessment: **show me a 1,000-line codebase where Anvil catches a bug that freestyle Claude misses, and the pitch becomes compelling. Until then, it is well-engineered infrastructure awaiting its justification.**

---

## Benchmark Evidence

### Setup

A controlled target project (`benchmarks/target/`): a 130-line Python CLI task tracker with 3 seeded defects:

1. **Off-by-one bug**: `complete()` uses list index instead of dict key lookup -- breaks after any deletion
2. **Code injection**: `eval(data)` fallback in `_load()` -- CWE-95 vulnerability
3. **Missing feature**: no `search()` method or CLI subcommand

5 baseline tests (happy paths only, all passing). Automated quality scorer (`benchmarks/score.py`) with 8 check types, no LLM involvement in scoring.

### Results: Freestyle Baseline (2026-02-25)

| Ticket | Scope | Task | Score | Time |
|--------|-------|------|-------|------|
| BENCH-1 | nano | Fix off-by-one in `complete()` | 100/100 | 43s |
| BENCH-2 | quick | Add search feature | 100/100 | 47s |
| BENCH-3 | quick | Add tests (no source changes) | 100/100 | 45s |
| BENCH-4 | standard | Refactor + error handling | 100/100 | 118s |
| BENCH-5 | nano | Remove `eval()` vulnerability | 100/100 | 56s |
| **Average** | | | **100/100** | **62s** |

**Total time: 309 seconds. All 25 quality checks passed across 5 tickets.**

### What This Proves

1. **The benchmark infrastructure works end-to-end.** Target project, ticket definitions, automated scorer, and runner all function correctly and produce machine-readable evidence.
2. **Freestyle Claude handles small, well-defined tasks perfectly.** On a 130-line project with explicit ticket descriptions, single-prompt Claude scores 100% -- bugs fixed, features added, tests written, security vulnerabilities removed.
3. **The scoring system discriminates.** Against the unmodified baseline, BENCH-1 scores 60/100 and BENCH-5 scores 45/100. After Claude's fixes, both score 100/100. The checks are real gates, not rubber stamps.

### What This Does Not Prove (Yet)

1. **Anvil vs freestyle comparison.** Anvil pipeline runs have not been executed on this benchmark. The comparison requires running `./scripts/run-benchmark.sh --approach both`.
2. **Behavior at scale.** A 130-line project with 3 seeded defects is a controlled test, not a realistic production codebase. Anvil's value proposition targets complexity that this benchmark does not yet exercise.
3. **Cost efficiency.** The `claude -p` cost was not captured in this run. Anvil-vs-freestyle cost comparison is pending.

### Next Steps

- Run `./scripts/run-benchmark.sh --approach both` to get Anvil comparison data
- Add a larger target project (500+ lines, subtler defects, multi-file changes) where freestyle may struggle
- Capture per-run API costs for honest cost-effectiveness comparison

---

## Scoring

| Dimension | Weight | FOR (1-10) | AGAINST (1-10) | Notes |
|-----------|--------|-----------|----------------|-------|
| **Correctness improvement** | 25% | 7 | 5 | Cross-model + holdouts are real mechanisms, but unproven at scale. LLM-reviews-LLM is a ceiling. |
| **Cost efficiency** | 20% | 4 | 7 | $40-50/ticket for full tier is prohibitive. Nano tier removes the differentiators. |
| **Engineering rigor** | 15% | 9 | 3 | 252 tests, self-validation, benchmark suite, circuit breakers -- the scaffolding is thorough. |
| **Practical usability** | 15% | 6 | 6 | Drop-in portability is genuine. 61+ files is a lot of framework to adopt. Config surface area is large. |
| **Evidence of results** | 10% | 5 | 6 | Benchmark infrastructure proven and executed. But freestyle scored 100% on all tasks -- Anvil comparison pending. |
| **Innovation** | 10% | 8 | 4 | Holdout separation, bias-mitigated review, automated benchmark scoring are genuinely novel for AI pipelines. |
| **Maintenance burden** | 5% | 5 | 6 | Self-test suite helps. But 2,400+ lines of harness is a lot of framework to keep current as Claude Code evolves. |

### Weighted Score

```
FOR:     (7*0.25) + (4*0.20) + (9*0.15) + (6*0.15) + (5*0.10) + (8*0.10) + (5*0.05) = 6.30
AGAINST: (5*0.25) + (7*0.20) + (3*0.15) + (6*0.15) + (6*0.10) + (4*0.10) + (6*0.05) = 5.45
```

**Final: FOR 6.3 vs AGAINST 5.5 -- a margin of 0.85 points.**

### Interpretation

Anvil is a genuinely engineered framework that solves real problems (context management, cost control, specification discipline) with concrete mechanisms (not just prompts). The engineering quality of the scaffolding is high. The ideas -- particularly holdout separation and cross-model review -- are sound in principle.

The margin has widened from 0.35 to 0.85 since the last assessment, driven primarily by the benchmark infrastructure: Anvil now has a reproducible, automated way to measure its own effectiveness with machine-readable evidence. The "Evidence of results" dimension shifted from FOR=2 to FOR=5 because the benchmark exists and runs -- but not higher because the initial data shows freestyle Claude performing perfectly on the current task set.

The honest next step is clear: add a larger, more complex target project where single-prompt Claude is likely to produce subtler defects (incorrect error handling across module boundaries, missed edge cases in multi-step workflows, security issues that require understanding data flow across files). If Anvil's pipeline catches what freestyle misses on those tasks, the FOR score on "Correctness improvement" jumps to 9 and the overall margin becomes decisive. If it doesn't, the framework's value reduces to cost governance and auditability -- useful, but not transformative.

The benchmark infrastructure itself is now an asset regardless of outcome. It provides a repeatable, LLM-free measurement of code quality that any AI coding tool can be evaluated against.
