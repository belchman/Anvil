# Anvil — Dual Pitch Evaluation

## FOR Pitch (Advocate)

Anvil solves a real, measurable problem: uncontrolled AI code generation. The README doesn't just claim governance matters — it proves it with variance studies showing freestyle drops 35 points on identical inputs (BENCH-6: 55-90 range) and hits hard quality ceilings the model can't escape (BENCH-7: 80/100 on all 5 runs). This is the rare AI tooling project that leads with honest limitations.

### Dimension Scores

**Correctness: 8/10** (weight: 25%)
The 192-test self-test suite, 10-ticket benchmark suite with zero-LLM scoring, and the unfixed baseline scores (48/100 simple, 39/100 hard) prove the checks are real gates, not rubber stamps. The scorer uses 11 check types including AST parsing and pytest execution. The dogfooding section admits the benchmarks found 5 pipeline bugs that structural tests missed — evidence of genuine testing rigor. Deducted points: BENCH-7's systematic blind spot (80/100 ceiling) is identified but the README only says holdout validation is "designed to catch" it — no evidence it actually does.

**Cost Efficiency: 9/10** (weight: 20%)
Six tiers from $1-$50 with clear guidance: "Start with nano. 90% of tasks don't need more." The head-to-head table is brutally honest — Anvil Lite costs 13x more than freestyle for the same 90/100 score. The README frames this correctly as governance overhead, not quality improvement. Per-phase cost tracking to `costs.json`, `MAX_PIPELINE_COST` ceiling, and the explicit "When to skip Anvil" section show maturity. The $50 hard ceiling prevents runaway sessions.

**Rigor: 9/10** (weight: 15%)
BDD spec-before-code discipline, cross-model diversity (Sonnet specs, Opus implements), non-LLM external validators by default, adversarial holdout testing, stagnation detection at >90% error similarity, and kill switches. The phase matrix showing exactly which tiers run which phases is excellent. Exit codes are well-defined (0-4). The "strictest verdict wins" policy across LLM review and external validation is a strong safety posture.

**Usability: 7/10** (weight: 15%)
One-command setup (`setup-anvil.sh`), single invocation (`./run-pipeline.sh TICKET-ID`), CLI `--tier` flag, sensible defaults ("most users change nothing"). The tier recommendation table is clear. Interactive mode via `/phase0` is available. However, ~30 core files to deploy is non-trivial, prerequisites include Claude Code CLI + jq + optional bc/gh/python3, and the configuration surface (20 variables, models JSON, .env) could overwhelm despite the "you don't need to touch it" framing.

**Evidence Quality: 9/10** (weight: 10%)
Variance studies with N=5 per ticket, per-run breakdowns, cost-per-quality-point metrics, and the unfixed baseline proving scorer discrimination. The BENCH-6 head-to-head table showing identical scores but different governance properties is honest evidence. The README explicitly states what freestyle does well (simple tasks: 100/100) rather than cherry-picking failures. Deducted for: no Anvil results on BENCH-7 (the hardest case), and variance studies are N=5 which is small.

**Innovation: 7/10** (weight: 10%)
Tiered governance for AI code generation is a novel framing. The guard tier (post-hoc validation of existing output) is clever — it governs without re-implementing. Adversarial holdout generation before implementation targets systematic blind spots specifically. The pluggable validator interface (`REVIEW_VALIDATOR_COMMAND`) bridges AI governance with existing tooling. Not revolutionary technology, but a novel application of engineering controls to AI output.

**Maintenance: 7/10** (weight: 5%)
192 self-tests, benchmark suite as integration tests, version tracking (ANVIL_VERSION=3.1), config consolidation from 73 to 20 variables showing active simplification. The Python runner provides an alternative implementation path. Concerns: ~30 core files + ~55 benchmark files is a significant surface area, and the bash harness at ~1280 lines will be painful to maintain long-term.

### FOR Weighted Score
(8×0.25) + (9×0.20) + (9×0.15) + (7×0.15) + (9×0.10) + (7×0.10) + (7×0.05) = 2.00 + 1.80 + 1.35 + 1.05 + 0.90 + 0.70 + 0.35 = **8.15/10**

---

## AGAINST Pitch (Critic)

Anvil is a 1,280-line bash script wrapping an AI tool, solving a problem that affects maybe 5% of AI coding tasks — and the README's own data proves it. Freestyle scores 100/100 on simple tasks and 92/100 on hard tasks. The governance overhead costs 13x more and takes 13x longer for identical quality scores. This is enterprise process theater applied to a tool that mostly works fine.

### Dimension Scores

**Correctness: 5/10** (weight: 25%)
The README's showpiece evidence undermines itself. Anvil Lite on BENCH-6: same 90/100 as freestyle. Where's the BENCH-7 result — the ticket with the "quality ceiling" that governance supposedly fixes? Conspicuously absent. The holdout validation is described as "designed to catch" BENCH-7's failure mode but no evidence it actually does. The variance study is N=5 — statistically meaningless. The 192 self-tests validate file inventory and syntax, not pipeline correctness. No evidence that any tier actually produces higher-quality code than freestyle on any benchmark.

**Cost Efficiency: 4/10** (weight: 20%)
The README's own data: freestyle costs $0.44 for 90/100, Anvil Lite costs $5.67 for... 90/100. That's $5.23 of pure overhead for zero quality improvement. The "governance overhead" framing is spin — you're paying 13x more for an audit trail that tells you the code has the same bugs. The tier system creates decision paralysis: 6 tiers, 20 config variables, a models JSON file. "Most users change nothing" is an admission that the configuration surface shouldn't exist. The $50 ceiling protects against runaway costs that Anvil itself creates.

**Rigor: 6/10** (weight: 15%)
Cross-model diversity and non-LLM validators are genuinely good ideas, but the rigor is theater without outcome data. The external validator is 120 lines of bash running syntax checks and grep for secrets — not meaningfully different from a pre-commit hook. "Strictest verdict wins" sounds rigorous but the README shows no case where the validator caught something the LLM missed (or vice versa). Stagnation detection, kill switches, and exit codes are nice engineering but they're process controls, not quality controls.

**Usability: 4/10** (weight: 15%)
~30 core files deployed into your project. A 1,280-line bash harness. A separate Python runner at ~1,000 lines that's "~95% parity" (what's the other 5%?). Seven skills, two agents, two rules, eleven doc templates. Prerequisites: Claude Code CLI, git, jq, optionally bc, gh, python3. To run: understand tiers, understand phases, understand config variables grouped into Essential/Cost/Quality/Advanced categories. The "one-command setup" requires you to already have Claude Code installed and authenticated. This is not a tool most developers will adopt casually.

**Evidence Quality: 6/10** (weight: 10%)
The variance studies are honest but methodologically weak: N=5 is too small for statistical claims. The head-to-head comparison is a single ticket (BENCH-6) with a single Anvil run. The README claims Anvil "blocked rather than shipping" on the residual mutation — but the score is still 90/100, same as freestyle. Where are the runs where Anvil actually produces a higher score? The unfixed baselines proving scorer discrimination is good methodology. But the core claim — governance improves outcomes — has no supporting data in the README.

**Innovation: 5/10** (weight: 10%)
Wrapping a tool with cost controls, logging, and validation gates is standard engineering practice — not innovation. CI/CD pipelines have done this for decades. The "tiered governance" concept maps directly to existing concepts: linting (guard) → build (nano) → integration tests (lite) → full pipeline (standard/full). The pluggable validator is just a script that outputs PASS/FAIL — any CI system does this. The holdout testing concept is genuinely interesting but unproven (no outcome data).

**Maintenance: 3/10** (weight: 5%)
A 1,280-line bash script is a maintenance nightmare. Bash has no type system, no package management, limited testing frameworks, and notoriously fragile string handling. The "~95% parity" Python alternative means maintaining two implementations of the same logic. 85 total files for a wrapper around another tool. The dogfooding section admits the benchmark suite found 5 bugs in the pipeline — evidence of ongoing fragility. Config consolidation from 73 to 20 variables in one version suggests the design is still churning.

### AGAINST Weighted Score
(5×0.25) + (4×0.20) + (6×0.15) + (4×0.15) + (6×0.10) + (5×0.10) + (3×0.05) = 1.25 + 0.80 + 0.90 + 0.60 + 0.60 + 0.50 + 0.15 = **4.80/10**

---

## Summary

| Dimension | Weight | FOR | AGAINST |
|-----------|--------|-----|---------|
| Correctness | 25% | 8 | 5 |
| Cost Efficiency | 20% | 9 | 4 |
| Rigor | 15% | 9 | 6 |
| Usability | 15% | 7 | 4 |
| Evidence Quality | 10% | 9 | 6 |
| Innovation | 10% | 7 | 5 |
| Maintenance | 5% | 7 | 3 |
| **Weighted Average** | | **8.15** | **4.80** |

**The crux**: The FOR case rests on governance-as-value (audit trails, cost ceilings, blocking bad code) — process maturity for AI-generated code. The AGAINST case rests on outcome data — Anvil hasn't demonstrated it produces better code, only that it costs more and takes longer to produce the same code. Both readings are supported by the README's own evidence. The missing BENCH-7 Anvil result is the most conspicuous gap: it's the ticket where governance should shine, and its absence speaks loudly.
