# Development Process

This repository is governed by a strict development process.
The process is not a suggestion. It is the prescribed order of creation.
All work must pass through its forms.

Deviation from this process undermines the discipline that makes autonomous pipelines reliable. Shortcuts produce hallucinations, wasted cost, and broken gates. Every violation ships bugs.

## Specification Protocol

The pipeline is the instrument of record. Nothing exists until it is interrogated, documented, and gated.

Work begins in interrogation, not in code.
Code without documentation is unverifiable.

Every change must be:
- Interrogated.
- Documented.
- Holdout-tested.
- Verified.
- Shipped through gates.

If it did not pass the gates, it did not happen.

## Single Source of Truth

`pipeline.config.sh` is the one configuration. All thresholds, timeouts, models, budgets, and paths live there. Consumers read from it. Nothing is hardcoded in runners or prompts when a config variable exists.

Direct manipulation of magic numbers is strictly forbidden:
- Do not hardcode thresholds in runner scripts
- Do not embed directory paths in prompt strings when config variables exist
- Do not duplicate defaults across files
- All tunable values must pass through `pipeline.config.sh`

When you add a new tunable value:
1. Add it to `pipeline.config.sh` with a comment
2. Numeric validation and guard loops auto-discover from `pipeline.config.sh` — no manual update needed
3. Test suite auto-discovers config vars — no manual update needed
4. Use it in consumers via `${VAR_NAME}` (bash) or `_config.get("VAR_NAME", default)` (Python)
5. For string configs, use naming convention `*_DIR`, `*_FILE`, `*_ORDER`, or `*_COMMAND` to skip numeric validation

## Running the Pipeline (Do This Exactly)

CRITICAL: Always run from the repository root.

Autonomous mode:

```bash
./run-pipeline.sh "TICKET-ID"
```

Resume a previous run:

```bash
./run-pipeline.sh "TICKET-ID" --resume docs/artifacts/pipeline-runs/2026-02-23-1430
```

Interactive mode:

```bash
claude
# then: /phase0 -> follow prompts
```

Feature shortcut:

```bash
claude
# then: /feature-add "description"
```

## Phase Order

All work is structured.

The pipeline flows through phases in strict order:
`phase0` -> `interrogate` -> `interrogation-review` -> `generate-docs` -> `doc-review` -> `write-specs` -> `holdout-generate` -> `implement` -> `holdout-validate` -> `security-audit` -> `ship`

Phase ordering is defined in `PHASE_ORDER` in `pipeline.config.sh`. It is not to be altered without updating all consumers.

**Pipeline Tiers** control which phases run, balancing cost against rigor:
- **full** (~$40-50, 30+ min): All phases. For large or critical changes.
- **standard** (~$20-30, 15-20 min): Skips holdouts, single-pass reviews. For medium changes.
- **quick** (~$8-15, 5-10 min): Single-pass reviews, skips holdouts, security, write-specs. For small changes.
- **nano** (~$3-5, 2-3 min): Interrogate + implement + verify + ship only. For trivial changes (typos, config).
- **auto** (default): Phase 0 estimates scope (1-5) and selects the appropriate tier.

Set `PIPELINE_TIER` in `pipeline.config.sh` or let auto-detection handle it. All tiers include review gates — quick uses single-pass reviews, full uses dual-pass with bias mitigation.

**Human Gates** allow optional human checkpoints at any phase. Set `HUMAN_GATES="write-specs,doc-review"` in config to pause the pipeline for human approval before those phases proceed. The pipeline exits with code 2 and resumes with `--resume` after the human creates a `.human-approved` marker file.

**External Review Validators** break the same-family limitation. Set `REVIEW_VALIDATOR_COMMAND` to pipe review output to a non-Anthropic model, static analyzer, or human review script for an independent 3rd verdict. The strictest verdict across all passes wins.

**Adaptive Template Selection** (`DOC_TEMPLATES_MODE`) avoids generating documents nobody will read. In `auto` mode, only templates relevant to the detected project type are generated. A CLI tool skips FRONTEND_GUIDELINES.md. A service without a database skips DATA_MODELS.md. Set to `minimal` for just PRD + implementation plan + testing plan.

**Outcome Metrics** are recorded to `METRICS_FILE` after every run. The cumulative metrics track cost, tier, phases run, retry counts, and status across all pipeline runs. Use `scripts/benchmark.sh` for controlled A/B comparison between Anvil and single-prompt approaches.

Structure is not bureaucracy. Structure prevents context loss.

## Development Framework

There is one discipline.

Outside-in Behavior-Driven Development.

The specification is the product.
Documentation defines the behavior contract.
Implementation code exists only to make failing specifications pass.
Holdout scenarios exist to catch what the spec forgot.

Non-negotiable laws:
- Begin with intent, not internals.
- Describe behavior in English first.
- Translate behavior into executable specifications (Gherkin, test cases, or holdout scenarios).
- Run the specifications and watch them fail.
- Write only the code required to make them pass.
- Refactor only while all specifications remain green.
- Every behavior must be specified, implemented, and verified.
- No gate may be skipped.
- Specifications describe observable behavior only. They must not describe internal structure.
- Assumptions must be tagged: `[ASSUMPTION: rationale]` with confidence level.

If behavior cannot be observed, it is not behavior.
If a requirement cannot be verified, it is not a requirement.

## Specification Discipline

Every feature must have executable specifications before implementation begins.

**Cross-Model BDD (Pipeline Mode):** In autonomous pipeline mode, a separate model (Sonnet) writes the failing specifications (RED phase) in the `write-specs` stage. The implementing model (Opus) then writes only the code to make those specs pass (GREEN phase) and refactors while specs remain green. This eliminates the same-brain problem — the model writing the spec has different reasoning patterns than the model satisfying it. When `write-specs` is skipped (e.g., quick tier), the implementing model performs all three phases (RED/GREEN/REFACTOR) as a single agent.

When the target project supports a test framework, specifications take the form of Gherkin features:

```gherkin
Feature: Session logout
  Scenario: User logs out successfully
    Given an authenticated user session
    When the user clicks the logout button
    Then the session token is invalidated
    And the user is redirected to the login page
```

When the target project does not use Gherkin, specifications take the form of test cases written in the project's test framework, following the Given/When/Then structure as comments or assertions.

When neither is applicable (e.g., infrastructure or pipeline work), holdout scenarios serve as the specification mechanism.

The form may vary. The discipline does not.

100% specification coverage is mandatory. Every behavior must be specified. Every specification must pass.

## Interrogation Protocol

When asked to build or change behavior, follow this sequence. It is not optional.

1. **Phase 0: Context Scan.** Scan git state, project type, TODOs, test status, blockers. Write summary to `${SUMMARIES_DIR}/`.
2. **Interrogate.** Execute all 13 sections of the interrogation protocol. Search MCP sources first, infer second, assume last. Tag every assumption. Capture intent as user stories: _As a \<role\>, I want \<capability\>, so that \<benefit\>._
3. **Review the interrogation.** LLM-as-Judge with position bias mitigation (dual-pass, cross-model). Score each section. Gate: `>= THRESHOLD_PASS` to proceed.
4. **Generate documentation.** Fill all applicable templates from `${TEMPLATES_DIR}/`. One at a time. Write output, release from context. Every feature in the PRD must have acceptance criteria in Given/When/Then form.
5. **Review the documentation.** LLM-as-Judge again. Gate: `>= THRESHOLD_DOC_REVIEW` to proceed.
6. **Write executable specifications (cross-model BDD).** A separate model (Sonnet) translates acceptance criteria into the project's test framework (Gherkin features, test cases, or equivalent). It runs them and confirms they fail. This is the red phase. The implementing model (Opus) never writes these specs — separation of concerns eliminates same-brain bias.
7. **Generate holdout scenarios (cross-model).** Adversarial tests generated by one model (Opus) and validated by another (Sonnet), written in complete isolation from the implementation agent. Written to `${HOLDOUTS_DIR}/`. These are the hidden specifications.
8. **Implement.** Step by step from `IMPLEMENTATION_PLAN.md`. Write only the code required to make the specifications pass. This is the green phase. Verify each step. Retry up to `MAX_VERIFY_RETRIES`. Commit after each verified step.
9. **Refactor.** Only while all specifications remain green.
10. **Holdout validation.** Run implementation against the hidden scenarios. Gate: `>= THRESHOLD_HOLDOUT` and zero anti-pattern flags.
11. **Security audit.** Scan for OWASP top 10, hardcoded secrets, insecure defaults. Gate: zero BLOCKERs.
12. **Ship.** Final test suite, PR creation, recording.

Skipping steps breaks the process.

## Roles in the Order

**Phase 0** establishes ground truth about the project.

**Interrogation** captures intent. It produces user stories and requirements. Every section must be addressed.

**Documentation** translates interrogation into the behavior contract. Acceptance criteria define what must happen, in Given/When/Then form.

**Specifications** are the executable form of the contract. They must fail before implementation begins (red). They must pass after implementation (green). They describe observable behavior only.

**Holdout scenarios** are adversarial specifications. They test what the contract forgot. They are written in isolation and never shown to the implementing agent.

**Implementation** serves the specifications. It may not invent behavior beyond what is specified. It writes only the code required to turn red to green.

**Verification** proves the implementation satisfies its step. It is mechanical and impartial.

**Security audit** restores trust boundaries that implementation may have violated.

**Ship** records the outcome and publishes it for review.

## Holdout Protocol

Every pipeline must generate holdout scenarios before implementation begins.

Holdout scenarios must:
- Test behavior IMPLIED but not explicitly stated
- Cover cross-feature interactions
- Test boundary conditions
- Validate security assumptions
- Check for reward-hacking anti-patterns (hardcoded returns, missing validation)

The implementing agent never sees the holdouts.
The holdout validator never sees the implementation prompts.
This separation is required.

Without holdouts, there is no independent verification of intent vs. implementation.

## Gate Discipline

Gates are the checkpoints of the process. They are not optional.

| Gate | Threshold | Failure Action |
|------|-----------|----------------|
| Interrogation review | `THRESHOLD_PASS` | ITERATE or BLOCK |
| Doc review | `THRESHOLD_DOC_REVIEW` | ITERATE |
| Verify | PASS/FAIL | Retry up to `MAX_VERIFY_RETRIES`, then BLOCK |
| Holdout validation | `THRESHOLD_HOLDOUT` + zero anti-patterns | Route back to implement |
| Security audit | Zero BLOCKERs | Auto-fix, then re-audit |
| Ship | All green | Create PR |

All review gates use LLM-as-Judge with position bias mitigation:
- Dual-pass evaluation (normal order + reversed order)
- Cross-model diversity (different model for each pass)
- Stricter verdict wins when passes disagree

Satisfaction scoring uses config thresholds, not magic numbers.

## Circuit Breakers

The pipeline protects itself from runaway cost and infinite loops.

- **Kill switch:** Create `.pipeline-kill` to halt immediately.
- **Cost ceiling:** `MAX_PIPELINE_COST` stops the pipeline if exceeded.
- **Per-phase limits:** `TURNS_*`, `BUDGET_*`, `TIMEOUT_*` per phase.
- **Stagnation detection:** `>= STAGNATION_SIMILARITY_THRESHOLD`% similar errors across retries triggers reroute.
- **Progress tracking:** `MAX_NO_PROGRESS` consecutive implementation phases without git commits = stall.

Circuit breakers prevent runaway cost and infinite retry loops.

## Context Discipline

Context is finite. Treat it as a budget.

**Fidelity modes** control how much prior-phase context loads into each new session:
- `full` | `truncate` | `compact` | `summary:high` | `summary:medium` | `summary:low`

**Auto-adjustment:** When estimated context exceeds `FIDELITY_DOWNGRADE_THRESHOLD`% of window, downgrade fidelity one level. When under `FIDELITY_UPGRADE_THRESHOLD`%, upgrade.

**Compaction rules:**
- Output > 200 lines: compress to pyramid summary
- Phase boundary: write artifact + summary, start fresh
- Error log > 50 lines: first 50 + count
- Never carry raw MCP content across a phase boundary

Large outputs go to `${ARTIFACTS_DIR}/` (Tier 3), not conversation.

## Assumptions Policy

**Interactive mode:** Never guess. ASK.

**Autonomous mode:**
1. SEARCH first: query all MCP sources
2. INFER second: use codebase patterns and conventions
3. ASSUME last: mark with `[ASSUMPTION: rationale]` and confidence (HIGH/MEDIUM/LOW)

LOW confidence assumptions on critical topics (auth, compliance, data retention) must be flagged as `[NEEDS_HUMAN]` rather than assumed.

"I think" and "probably" are red flags. Replace with "I need to confirm."

## Portability

Anvil is a portable framework. It must work in any project, on any platform.

Non-negotiable portability rules:
- No `grep -oP` (PCRE is not portable to macOS/BSD). Use `sed` or shell builtins.
- No hardcoded paths when config variables exist.
- TTY-aware colors: wrap ANSI codes in `if [ -t 1 ]` checks.
- All config in `pipeline.config.sh`, not scattered across files.
- Test portability with `scripts/test-anvil.sh` (must pass with zero failures).

## The Test Covenant

`scripts/test-anvil.sh` is the arbiter of structural integrity.

It validates:
- File inventory (all expected files exist)
- Bash and Python syntax
- JSON validity
- DOT graph structure
- Config completeness (every variable defined)
- Cross-reference integrity
- Portability (no non-portable constructs)
- Security (no hardcoded secrets)
- Doc template cross-references

If the test suite fails, the process has been broken. Fix it before committing.

## Commit Discipline

- Commit after each verified implementation step.
- Commit messages follow conventional format: `feat(step-id): title`, `fix(security): description`.
- Never commit secrets, credentials, or `.env` files.
- The human user is the sole author. Claude is never listed as co-author.

## The Routing Graph

`pipeline.graph.dot` defines the flow of phases and gates. It is the authoritative routing map.

Edge labels reference config variable names, not literal numbers. When thresholds change in `pipeline.config.sh`, the graph remains accurate without edits.

The graph is authoritative. `route_from_gate()` in both runners must implement exactly the edges defined in the graph.

## Example: Adding a Feature

Even the smallest feature must pass through the process.

No code precedes specification.
No specification precedes documentation.
No documentation precedes interrogation.
No implementation precedes failure.

User request: "Add a logout button."

1. `/phase0` - Scan project state.
2. `/interrogate` - Capture the intent: _As an authenticated user, I want to log out, so that my session is terminated and credentials are cleared._ Where does the button go? What happens on click? What API endpoint? Session cleanup? Token invalidation? Redirect destination?
3. Review the interrogation output. Gate it.
4. Generate docs: update PRD, APP_FLOW, API_SPEC, IMPLEMENTATION_PLAN. The PRD includes acceptance criteria:
   ```gherkin
   Feature: User logout
     Scenario: Successful logout
       Given an authenticated user on any page
       When the user clicks the logout button
       Then the session token is invalidated
       And the user is redirected to the login page

     Scenario: Logout with expired session
       Given a user whose session has already expired
       When the user clicks the logout button
       Then the user is redirected to the login page
       And no error is displayed
   ```
5. Review the docs. Gate them.
6. Write executable specs from the acceptance criteria. Run them. Watch them fail. This is correct.
7. Generate holdout scenarios: What if the user clicks logout twice rapidly? What if there's no network? What if a background request carries the old token after logout?
8. Implement step by step. Write only the code that makes the failing specs pass. Verify each step.
9. Refactor while all specs remain green.
10. Validate against holdouts.
11. Security audit: Does logout actually clear tokens? Are there dangling sessions?
12. Ship.

This is the process.
