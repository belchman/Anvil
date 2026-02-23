---
name: feature-add
description: "Add a new feature: lightweight interrogation, doc updates, implementation, and verification."
allowed-tools: Read, Write, Bash, Glob, Grep, mcp__memory__*
argument-hint: "Feature description (e.g., 'add user profile page with avatar upload')"
---

# Feature Addition Workflow

Orchestrates adding a new feature to an existing project. Lighter than a full pipeline run -- skips project-level interrogation and focuses on the delta.

## Prerequisites
- Project must already have base documentation (docs/PRD.md, docs/IMPLEMENTATION_PLAN.md at minimum)
- Run `/phase0` first if not already done this session

## Process

### Step 1: Context Gathering
1. Read `docs/summaries/phase0-summary.md` for current project state
2. Read `docs/PRD.md` for existing scope and requirements
3. Read `docs/IMPLEMENTATION_PLAN.md` for architecture context
4. Read `docs/TECH_STACK.md` for technology constraints
5. Scan existing codebase for related features (grep for similar patterns)

### Step 2: Feature Interrogation (Lightweight)
Run a focused interrogation covering only the sections relevant to this feature. At minimum:

1. **Problem & User Story**: What does this feature do? Who benefits? Write 1-3 user stories.
2. **Functional Requirements**: Inputs, outputs, edge cases for this feature.
3. **Data Model Changes**: New entities or modifications to existing ones?
4. **API Changes**: New endpoints or modifications?
5. **Testing**: What tests are needed for this feature?
6. **Security**: Any new attack surface?

In INTERACTIVE mode: ask the human each question.
In AUTONOMOUS mode: search codebase patterns, infer from existing architecture, assume with [ASSUMPTION] tags.

Write feature interrogation to: `docs/artifacts/feature-[slug]-interrogation.md`

### Step 3: Documentation Updates
Update these docs with the new feature's additions (append, don't rewrite):
- `docs/PRD.md` - add feature to requirements
- `docs/DATA_MODELS.md` - add new/modified entities (if applicable)
- `docs/API_SPEC.md` - add new/modified endpoints (if applicable)
- `docs/IMPLEMENTATION_PLAN.md` - add implementation steps for this feature

### Step 4: Implementation Plan
Generate an ordered list of implementation steps for this feature only. Each step should be:
- Small enough to implement and verify in one pass
- Independent where possible (parallelize-friendly)
- Ordered by dependency (data model -> backend -> frontend -> tests)

### Step 5: Implementation Loop
For each step in the plan:
1. Implement the change following existing codebase patterns exactly
2. Run type checker / linter after each file edit
3. Run relevant tests (fast mode: only tests related to changed files)
4. Commit with message: `feat([feature-slug]): [step description]`

If a step fails verification:
- Retry up to 3 times with error context from previous attempt
- If stagnated (same error 2x), try a fundamentally different approach
- If blocked after 3 retries, stop and report

### Step 6: Verification
After all steps complete:
1. Run full test suite
2. Run type checker on entire project
3. Run linter on changed files
4. Verify no regressions in existing functionality

### Step 7: Update Progress
1. Update `PROGRESS.md` with the new feature
2. Update Memory MCP with feature status
3. Generate a summary of what was added and any assumptions made

## Output
- Feature interrogation artifact in docs/artifacts/
- Updated documentation files
- Committed, verified implementation
- Updated PROGRESS.md
