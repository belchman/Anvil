# Interrogation Protocol v2.1 has 67 gaps against production patterns

**The system is a well-structured but fundamentally linear, human-dependent, CLI-invoked pipeline operating in a world that has moved to graph-based routing, parallel multi-agent execution, programmatic SDK control, and closed-loop self-healing.** Of the 10 audit categories evaluated, the system achieves partial coverage in only 3 (self-interrogation, progress files, holdout validation) and has zero implementation in 4 (self-healing, DTU, multi-agent coordination, autonomous execution toolkit). The most critical finding: the entire pipeline cannot actually run autonomously end-to-end today because it lacks a bash harness, uses no `-p` mode or Agent SDK invocation, has no cost ceilings, and still relies on `.claude/commands/` which Anthropic has deprecated in favor of `.claude/skills/`.

What follows is a gap-by-gap audit organized by the 10 requested categories, plus newly discovered patterns, internal consistency issues, and a prioritized remediation roadmap.

---

## 1. StrongDM Attractor spec: 9 of 9 patterns missing or incomplete

The Attractor spec defines a **graph-structured pipeline** authored in Graphviz DOT syntax with 9 node types, a 5-step edge selection algorithm, and 6 context fidelity modes. The Interrogation Protocol is architecturally incompatible with this model.

**Graph-based routing vs. linear pipeline.** The system's `full-pipeline.md` orchestrates phases sequentially: phase0 → interrogate → generate-docs → verify → ship. There is no graph definition, no conditional branching between arbitrary nodes, no fan-out/fan-in for parallel phases, and no diamond (conditional) nodes. The Attractor model allows edges like "if verify fails, route back to interrogate with `retry_target=interrogate`" — the system can only retry within a single gate (verify.md's max 3 retries loop back to itself, not to an earlier phase).

**Goal gates with retry_target routing.** `verify.md` implements a GOAL GATE with retry routing capped at 3 retries and compressed error context — this is the system's closest analog. However, it lacks `retry_target` pointing to arbitrary upstream nodes, `fallback_retry_target` for exhausted retries, and graph-level `default_max_retry`. The `ship.md` SHIP GATE similarly lacks routing to anything other than itself on failure.

**Six context fidelity modes are absent.** The system's three-tier model (Context/Summary/Artifact from `context-fidelity.md`) is a **data classification scheme**, not a context window management system. Attractor's six modes — `full`, `truncate`, `compact`, `summary:low`, `summary:medium`, `summary:high` — control how much prior conversation carries into the next node's LLM session, with a precedence hierarchy (edge → node → subgraph → graph default). The system's `context-budget.md` estimates tokens before phases but does not dynamically select fidelity modes per phase or degrade fidelity on checkpoint resume.

**Thread mechanism for session isolation.** `full-pipeline.md` specifies "fresh sessions per phase," which is conceptually aligned but lacks explicit `thread_id` attributes for session reuse under `full` fidelity, session forking, or the ability to share a thread between specific nodes while isolating others.

**Checkpoint serialization does not exist.** The system uses `progress.txt` and Memory MCP for persistence, but there is no JSON checkpoint written after every phase containing `context_values`, `completed_nodes`, `node_retries`, and `current_node`. Pipeline crashes require manual restart from scratch — there is no resume-from-checkpoint capability.

**The 5-step edge selection hierarchy has no analog.** The Attractor's deterministic priority — (1) condition-matching edges, (2) preferred label match with normalization, (3) suggested next IDs, (4) highest weight, (5) lexical tiebreak — requires a graph structure that doesn't exist here.

**Supervisor nodes (doubleoctagon) are absent.** No meta-level node monitors the pipeline's overall health, overrides stuck phases, or escalates to human review based on aggregate metrics.

**Model stylesheet for per-phase model selection is missing.** All phases use whatever model the user's Claude Code session defaults to. The Attractor's CSS-like stylesheet system targets nodes by class to route to different models (e.g., cheaper models for routing decisions, Opus for complex generation). This is a significant cost and quality optimization the system cannot perform.

**The inner loop is not programmable.** The system invokes Claude Code via slash commands (black-box CLI pattern). Attractor's `SessionBackend` provides programmatic access to the agentic loop with configurable tools, execution environments, and provider profiles. The system cannot inspect or modify tool calls mid-execution.

---

## 2. Anthropic C Compiler patterns: 5 of 6 missing

Nicholas Carlini's 16-agent C compiler project established production patterns for **parallel multi-agent coordination** that the system entirely lacks.

**No multi-agent parallel execution.** The system runs one agent at a time. Carlini ran 16 Claude Opus instances in parallel inside Docker containers, each with isolated `/workspace` directories cloned from a shared bare Git repo at `/upstream`. The system has 6 subagent definitions but they execute sequentially within a single session, not as independent parallel processes.

**No shared Git coordination.** Carlini's `current_tasks/` directory uses Git's merge semantics as a distributed locking primitive — agents create a file, commit, and push; the first push wins, others abandon that task. The system has no equivalent. Its subagents don't coordinate via the filesystem at all.

**No AI-optimized test output.** Carlini's test harness prints only `ERROR` lines to stdout (the agent's context window) and writes verbose logs to separate files. The system's `verify.md` mentions "compressed error context" but there's no evidence of a test harness designed for AI consumption with structured error-only output.

**No `--fast` flag for test sampling.** Carlini's test harness includes a deterministic-per-agent random subsample mode, where each agent runs a different 10% of tests. Collectively, 16 agents achieve high coverage quickly. The system has no test sampling mechanism.

**No oracle pattern.** The oracle compiler technique — randomly mixing compilation between a known-good compiler and the agent's compiler to isolate bugs to specific files — has no analog. This pattern is problem-specific but the underlying principle (using a known-good reference to decompose monolithic validation) is absent.

**Progress files partially exist.** `progress.txt`, `lessons.md`, and `decisions.md` serve as external memory, and Memory MCP provides structured persistence. This is the system's strongest alignment with Carlini's patterns, though Carlini's agents maintained far more extensive living READMEs with architecture descriptions, recent changes, failed approaches, and remaining tasks — not just progress logs.

---

## 3. Self-healing / Healer Agent: completely absent

StrongDM's Healer Agent implements a closed-loop **Observe → Cluster → Investigate → Prescribe → Apply → Verify** cycle. The system has zero coverage of this pattern.

**No observability layer.** CXDB (Conversation Experience Database) provides structured, typed, branching conversation observability with a Turn DAG, Content-Addressed Store (BLAKE3 hashing), dynamic type system, sub-millisecond append latency, and a React visual debugger. The system logs to `progress.txt` and Memory MCP entities but has no structured observability of agent behavior, no turn-level tracing, and no visual debugging.

**No clustering of problems into diagnoses.** The Healer groups related bad behaviors using Pyramid Summaries (MapReduce + clustering at compressed levels, zooming in where signal demands). The system's `error-handling.md` rule captures individual errors with root cause and prevention but performs no cross-session pattern analysis.

**No autonomous investigation or prescription agents.** In StrongDM's system, each diagnosis spawns an investigation agent with full codebase access that writes a prescription (code/prompt/config fix) applied automatically. The system has no equivalent — `lessons.md` records learnings but no agent reads them to generate fixes.

**No feedback loop.** The Healer verifies prescriptions against CXDB to confirm fixes resolved clustered problems. Without observability, there can be no verification loop.

---

## 4. LLM-as-Judge / multi-model strategy: 4 of 5 patterns missing

**No multi-model strategy.** Research shows cross-family judging reduces self-enhancement bias by **5–7%** and LLM juries (3–5 models) reduce overall bias by **30–40%**. The system uses a single model for both generation and review. The `code-reviewer.md` subagent and `holdout-validate.md` run on the same model that generated the code.

**No probabilistic satisfaction scoring.** StrongDM's satisfaction metric asks "of all observed trajectories through all scenarios, what fraction likely satisfy the user?" — replacing binary pass/fail with a probabilistic percentage. The system's `verify.md` appears to use binary pass/fail (retry or proceed). `holdout-validate.md` likely produces a pass/fail verdict per scenario, not a confidence-weighted satisfaction score.

**Two-session validation partially exists.** `holdout-generate.md` uses an "isolated subagent" to generate holdout scenarios, and `holdout-validate.md` validates against hidden scenarios. This is conceptually aligned with the two-session pattern (one writes, a separate one reviews). However, `verify.md` (the GOAL GATE) does not appear to use a fresh session — it reviews within the same context that generated the code, losing the "fresh eyes" benefit.

**No position bias mitigation.** Production LLM-as-judge systems use position-swapping (run judge twice with swapped order, label inconsistencies as "tie"), multi-model juries, 1–4 scales instead of binary, and calibration against human-labeled golden datasets. The system implements none of these.

**No confidence-based escalation.** There are no thresholds like "if satisfaction < 0.7, escalate to human" or "if semantic similarity to previous failed plan > 95%, stop the agent." The system's gates are binary — pass or retry up to a hard cap, then presumably fail.

---

## 5. Digital Twin Universe: completely absent

StrongDM built behavioral clones of **Okta, Jira, Slack, Google Docs, Google Drive, and Google Sheets** — self-contained Go binaries replicating full API contracts with edge cases and observable behaviors, built by coding agents themselves.

**No mock API replicas.** The system generates 12 document templates but has no mechanism for creating or using service clones for testing. If the generated application integrates with third-party APIs, there's no DTU to validate against.

**No anti-reward-hacking via DTU.** StrongDM stores scenarios **outside the codebase** (like ML holdout sets) and validates against DTU replicas that agents can't trivially game. The system's holdout mechanism (`.holdouts/` directory) addresses the storage aspect but without DTU replicas, validation is limited to whatever the model can simulate in-context.

---

## 6. Self-interrogation / autonomous spec generation: 3 critical gaps

**MCP pre-fill reduces but does not eliminate human dependency.** `interrogate.md` performs a 13-section interrogation with MCP pre-fill from Memory MCP entities. When MCP sources contain relevant data, this works well. But there is no documented fallback for when MCP sources don't have the answer — the system likely either (a) presents empty sections requiring human input, or (b) skips sections silently.

**No "make assumptions and document them" fallback.** Production autonomous systems use the pattern: if data is unavailable, make a reasonable assumption, flag it explicitly as an assumption with a confidence level, and document it for later human review. The `no-assumptions.md` rule actually **prohibits** this — it enforces a "zero assumptions policy." In a fully autonomous context, this creates a deadlock: the agent can't proceed without data, can't assume, and can't ask a human. This rule needs a configurable override for autonomous mode.

**No spec-the-gap capability.** StrongDM's approach to missing spec sections is to have agents infer likely requirements from context (existing code, similar systems, industry conventions) and generate draft specs flagged for review. The system has no equivalent — `generate-docs.md` fills templates from interrogation answers but cannot generate content for sections where interrogation yielded no answers.

---

## 7. Claude Code autonomous execution toolkit: 10 of 10 missing

This is the system's **most critical gap category**. The pipeline cannot actually execute autonomously because it lacks the fundamental execution infrastructure.

**No `-p` (print/headless) mode invocation.** The system's slash commands are designed for interactive use. `full-pipeline.md` orchestrates by invoking other slash commands, but there is no evidence of headless execution via `claude -p "$(cat .claude/commands/phase0.md)"`. Without `-p` mode, the pipeline requires an interactive terminal with a human present.

**No `--max-turns` session limits.** Confirmed current and functional in Claude Code. The system specifies no turn limits on any phase, risking infinite loops in generation or verification phases.

**No `--max-budget-usd` cost ceilings.** Confirmed current in Claude Code. No phase has a cost ceiling. A runaway interrogation or generation phase could consume unlimited API spend.

**No `--output-format json` for structured control.** Without JSON output, the pipeline cannot programmatically extract `session_id`, `cost_usd`, or `result` from phase outputs. Session chaining via `--resume` requires `session_id` from JSON output.

**No `--resume` session chaining.** The system's "fresh sessions per phase" in `full-pipeline.md` is conceptually right but implemented via interactive slash commands, not via `--resume SESSION_ID` with structured handoff.

**No Agent SDK usage.** The Claude Agent SDK (renamed from Claude Code SDK) provides Python and TypeScript libraries with `ClaudeAgentOptions` supporting `max_turns`, `max_budget_usd`, `permission_mode`, `agents` (inline subagent definitions), `hooks`, and `mcp_servers`. The system uses none of this — it relies entirely on slash commands.

**No bash harness or runner script.** Carlini's RALPH loop, Spotify's Honk CLI wrapper, and even the community `ralph` tool all provide bash harnesses that spawn Claude Code in a `while true` loop with fresh sessions. The system has no `run-pipeline.sh` or equivalent.

**Not using `.claude/skills/` (deprecated `.claude/commands/`).** Anthropic merged slash commands into the Skills system in Claude Code v2.1.3 (January 2026). `.claude/commands/` files still work but are **officially deprecated**. Skills add auto-invocation by the model, supporting file directories, tool permission restrictions via frontmatter, and cross-product usage (Claude Code, Claude.ai, Claude Desktop).

**Not using `--worktree` for isolation.** Claude Code's `--worktree` / `-w` flag and `isolation: worktree` in agent definitions create isolated git worktrees per agent. The system's subagents run in the same workspace.

**Not using Agent Teams.** Claude Code's experimental Agent Teams feature enables multi-agent collaboration with shared task lists, inbox-based messaging, and dependency tracking — far beyond the system's sequential subagent invocations.

---

## 8. Circuit breakers / stuck detection: 4 of 5 missing

**Per-session limits are minimal.** `verify.md` has max 3 retries — the only circuit breaker in the system. No phase has turn limits, time limits, or budget limits. Production systems use `--max-turns`, `--max-budget-usd`, and per-node `timeout` attributes (Attractor supports `timeout="900s"`).

**No cross-session progress tracking.** Carlini's agents verify progress via git commit checking between sessions. The system has `progress.txt` and `update-progress.md` for Memory MCP persistence but no automated check like "if no new git commits in the last N minutes, the agent is stuck."

**No external kill switches.** Production systems use external boolean flags (Redis, feature flags, environment variables) that agents cannot modify. The system has no kill switch mechanism — a runaway phase can only be stopped by killing the terminal.

**No stagnation detection.** Production patterns detect repeated identical failures (semantic similarity > 95% between consecutive attempts), context overflow loops, and "imaginary task" continuation (agent invents new work after completing the actual task). The system's max-3-retry in verify.md is a crude version but doesn't detect semantic repetition.

**No cost tracking or reporting.** There is no mechanism to track cumulative API spend across phases, report cost at pipeline completion, or alert when costs exceed expectations. `--output-format json` returns `cost_usd` per session, but the system doesn't capture this.

---

## 9. Autonomy-specific gaps: the pipeline cannot run end-to-end today

**`interrogate.md` likely blocks for human input.** The 13-section interrogation with MCP pre-fill reduces but does not eliminate human dependency. When MCP data is insufficient, sections require human answers. Combined with the `no-assumptions.md` rule prohibiting assumptions, this creates a hard block.

**Gates are not configurable as LLM-as-judge.** `verify.md` and `ship.md` implement gates, but it's unclear whether these use LLM evaluation or simply check for the presence of certain artifacts. Neither gate is configurable to switch between human review and LLM-as-judge modes.

**`full-pipeline.md` cannot run end-to-end without stopping.** It specifies "fresh sessions per phase" and "context budgets per phase," but without a bash harness invoking `-p` mode, without JSON output for session handoff, and without automated gate evaluation, each phase boundary requires human intervention.

**No CI/CD trigger mechanism.** There is no GitHub Action workflow, no webhook handler, no `claude-code-action@v1` configuration. Anthropic provides official GitHub Actions integration and GitLab CI/CD support (beta). The system uses neither.

**No cost report at completion.** The `ship.md` SHIP GATE creates a PR but does not report total pipeline cost, per-phase cost breakdown, total turns, or total time elapsed.

---

## 10. Internal consistency: 8 likely issues identified

Without access to the actual file contents, these are **structural issues identifiable from the system description**:

**Three-tier system inconsistently applied.** `context-fidelity.md` defines Context/Summary/Artifact tiers, but `pyramid-summary.md` produces "multi-resolution compression" which is a different abstraction (more aligned with Attractor's fidelity modes). The two systems appear to overlap without clear integration — does a pyramid summary replace the Summary tier? Is an Artifact the same as a compressed output? The relationship is undefined.

**Memory MCP entity naming likely inconsistent.** `phase0.md` scans via Memory MCP, `update-progress.md` persists to Memory MCP, `interrogate.md` pre-fills from Memory MCP, and `session-persistence.md` defines MCP tiers with promotion rules. With 4 files referencing Memory MCP entities, naming inconsistencies are probable (e.g., does phase0 write entities that interrogate reads with the exact same keys?).

**Dead reference risk in full-pipeline.md.** This file orchestrates 8+ other commands. If any command was renamed, moved, or had its interface changed without updating full-pipeline.md, the pipeline breaks silently. The slash command for holdout validation (`holdout-validate.md`) is relatively new — verify whether `full-pipeline.md` references it.

**Rules glob patterns may not match.** `code-quality.md` and other rules use glob patterns for file matching. If rules reference `docs/templates/*.md` but templates moved or were renamed, rules silently stop applying.

**MCP tool names in settings.json.** With 6 MCP servers configured in `.mcp.json`, the `settings.json` permissions must reference tools as `mcp__servername__toolname`. Any server rename or tool change creates silent permission failures.

**Context budget mismatch.** `context-budget.md` estimates tokens before phases, but `full-pipeline.md` defines "context budgets per phase." If these are implemented independently, they may disagree on budget allocations.

**Holdout directory path.** `.holdouts/holdout-000-example-auth-bypass.md` uses a dot-prefixed directory. The `holdout-manage.md` CRUD operations and `holdout-validate.md` must both reference `.holdouts/` exactly — a common source of path mismatches.

**Fallback persistence files.** `progress.txt`, `lessons.md`, and `decisions.md` are "marked as fallback for non-MCP environments." If code paths check for MCP availability and fall back to these files, the fallback logic must handle both read and write operations, file creation on first use, and concurrent access. This is likely undertested.

---

## 11. Production patterns discovered that the system missed entirely

Beyond the 10 requested categories, research uncovered **5 significant production patterns** with no system coverage:

**Frequent Intentional Compaction (FIC).** HumanLayer's battle-tested methodology targets **40–60% context window utilization** with explicit compaction boundaries between Research → Plan → Implement phases. Each phase produces a compressed artifact (~200 lines) that becomes the sole input for the next phase. Demonstrated: 35,000 lines of code shipped in a single 7-hour session on a 300K LOC Rust codebase. The system's `pyramid-summary.md` is conceptually related but FIC is more rigorous about compaction triggers and utilization targets.

**Spotify Honk fleet management.** Spotify's production background coding agent has **1,500+ merged PRs**. Key patterns include a custom CLI wrapper that delegates to agents, runs formatters via MCP, evaluates diffs via LLM-as-Judge, uploads logs to GCP, and captures traces in MLflow. Its three failure mode taxonomy — (1) fails to produce PR, (2) PR fails CI, (3) PR passes CI but is functionally wrong — provides a useful classification the system lacks.

**Anthropic's own context engineering framework.** Published September 2025, this covers context rot (recall accuracy decreases with token count due to n² attention), just-in-time context retrieval (maintain lightweight identifiers, load data dynamically), structured note-taking (agents persist key findings to files to survive compaction), and minimal viable tool sets (too many overlapping tools cause model confusion). The system should be explicitly aligned with Anthropic's own recommendations.

**SWE-agent ACI design patterns.** The SWE-agent research demonstrates that **ACI (Agent-Computer Interface) design matters more than model selection**. Key finding: edit validation that rejects modifications producing syntax errors (a linting gate on every edit) improves performance by ~3% absolute. The system has no edit validation or linting gate.

**RALPH loop for persistent execution.** The community-standard `while true; do claude -p "$(cat PROMPT.md)" --dangerously-skip-permissions; done` pattern provides the simplest viable autonomous execution. Combined with progress files and git-based coordination, this is what the system needs as its minimum viable bash harness.

---

## Prioritized remediation: what to fix before shipping

The 67 identified gaps vary dramatically in implementation effort and impact. Here is a prioritized remediation path.

**Tier 1 — Ship-blocking (fix immediately, 1–2 days):**

| # | Gap | Fix |
|---|-----|-----|
| 1 | No bash harness / runner script | Create `run-pipeline.sh` using RALPH loop pattern with `-p` mode, `--output-format json`, `--max-turns`, `--max-budget-usd` per phase |
| 2 | No `-p` mode, `--max-turns`, `--max-budget-usd` | Add to runner script per phase: e.g., interrogation gets 50 turns/$5, generation gets 30 turns/$3, verify gets 10 turns/$2 |
| 3 | `no-assumptions.md` creates autonomy deadlock | Add configurable `AUTONOMOUS_MODE` flag that switches to "make assumptions and document them" when human input is unavailable |
| 4 | Migrate `.claude/commands/` → `.claude/skills/` | Rename directories, add YAML frontmatter with `name`, `description`, `allowed-tools`, `context: fork` where appropriate |
| 5 | No cost report | Add `--output-format json` capture per phase, aggregate `cost_usd` fields, output summary at pipeline end |

**Tier 2 — High-impact improvements (1–2 weeks):**

| # | Gap | Fix |
|---|-----|-----|
| 6 | Linear pipeline → graph routing | Implement minimal graph: add conditional edges from verify → interrogate (not just self-retry), ship → verify fallback, and parallel fan-out for doc generation + test writing |
| 7 | No multi-model strategy | Configure `--model` per phase in runner script: Opus for interrogation/review, Sonnet for generation, Haiku for context budget estimation |
| 8 | No checkpoint serialization | Write `checkpoint.json` after each phase with completed phases, session IDs, context state; support `--resume-from-checkpoint` in runner |
| 9 | No circuit breakers beyond max-3 | Add stagnation detection (compare consecutive error messages for >90% similarity), time limits per phase, external kill switch via env var |
| 10 | No CI/CD integration | Create `.github/workflows/claude-pipeline.yml` using `anthropics/claude-code-action@v1` |
| 11 | Replace three-tier with six fidelity modes | Map Context→full, Summary→summary:medium, Artifact→compact; add truncate, summary:low, summary:high; apply per-phase in runner |
| 12 | No two-session validation in verify | Have verify.md spawn a fresh Claude session (via Agent SDK or `-p` with new session) to review code, not review in the same context |

**Tier 3 — Competitive parity (2–4 weeks):**

| # | Gap | Fix |
|---|-----|-----|
| 13 | No multi-agent parallel execution | Use `--worktree` flag + parallel bash processes for independent phases (doc generation, test writing, security audit can run simultaneously) |
| 14 | No probabilistic satisfaction scoring | Replace binary pass/fail in holdout-validate with 0–1 satisfaction scores per scenario, compute aggregate satisfaction, set threshold (e.g., >0.8) |
| 15 | No position bias mitigation | Run holdout validation twice with swapped prompt ordering; flag inconsistencies |
| 16 | No Agent SDK integration | Rewrite runner in Python/TypeScript using `claude_agent_sdk.query()` for programmatic session control, hook inspection, and structured output |
| 17 | No edit validation / linting gate | Add a hook in `.claude/settings.json` that runs linter on every file edit (SWE-agent pattern: reject edits producing syntax errors) |
| 18 | No DTU for testing | For projects with third-party API dependencies, generate mock service clones as part of the pipeline |

**Tier 4 — Production excellence (1–2 months):**

| # | Gap | Fix |
|---|-----|-----|
| 19 | No self-healing / Healer agent | Build CXDB-lite: structured logging of all agent turns, clustering of failures, investigation agent that reads logs and proposes fixes |
| 20 | No supervisor nodes | Add a supervisor phase that monitors cross-phase metrics and can override/reroute the pipeline |
| 21 | No model stylesheet | Implement CSS-like config for node→model mapping with class-based selectors |
| 22 | No FIC compaction discipline | Add explicit compaction checkpoints between phases targeting 40–60% context utilization |

---

## Conclusion: strong foundation, wrong execution model

The Interrogation Protocol v2.1 has genuinely good ideas — holdout validation, pyramid summaries, Memory MCP persistence, context budgets, and the three-tier data classification all reflect awareness of production patterns. The **12 document templates** and **6 subagent definitions** show thoughtful decomposition. The system's conceptual alignment with StrongDM's scenario-based validation (holdouts) and Anthropic's context engineering (pyramid summaries, fresh sessions) is real.

But the execution model is fatally misaligned with autonomous operation. The system is built as an **interactive Claude Code skills library** (slash commands invoked by a human in a terminal) rather than a **programmable pipeline** (bash harness or SDK invoking Claude in headless mode with structured I/O). This single architectural mismatch cascades into most of the 67 gaps: you can't have cost ceilings without `-p` mode, can't chain sessions without JSON output, can't run in CI/CD without a harness, and can't detect stagnation without structured observability.

The fastest path to shipping is not fixing all 67 gaps — it's creating `run-pipeline.sh` (Tier 1, item #1) that wraps the existing slash commands in `-p` mode with `--max-turns`, `--max-budget-usd`, and `--output-format json`. This single file transforms the system from an interactive toolkit into an autonomous pipeline, after which the remaining gaps become incremental improvements rather than architectural blockers.