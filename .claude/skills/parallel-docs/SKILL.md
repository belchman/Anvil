---
name: parallel-docs
description: "Generate all documentation in parallel using Agent Teams."
allowed-tools: Read, Write, Bash, Glob, Task, TaskCreate, TaskUpdate, TaskList, TeamCreate, SendMessage, mcp__memory__*
model: claude-opus-4-6
---

# Parallel Documentation via Agent Teams

Generate all project documentation in parallel by coordinating multiple agents. Each agent handles a distinct set of documents, preventing file conflicts.

## Prerequisites
- `docs/summaries/interrogation-summary.md` must exist (run `/interrogate` first)
- `docs/templates/` must contain the 11 document templates

## Process

### Step 1: Create Team
Create a team named `doc-gen` with yourself as lead.

### Step 2: Create Tasks
Create these tasks for teammates to claim. Each task writes to distinct files (no conflicts):

1. **generate-prd-appflow**
   - Read `docs/summaries/interrogation-summary.md` for requirements context
   - Read templates: `docs/templates/PRD.md`, `docs/templates/APP_FLOW.md`
   - Generate: `docs/PRD.md`, `docs/APP_FLOW.md`
   - Fill every section from the interrogation summary. Mark sections with insufficient data as `[NEEDS_DETAIL]`

2. **generate-tech-data**
   - Read `docs/summaries/interrogation-summary.md`
   - Read templates: `docs/templates/TECH_STACK.md`, `docs/templates/DATA_MODELS.md`
   - Generate: `docs/TECH_STACK.md`, `docs/DATA_MODELS.md`
   - For DATA_MODELS: include entity relationships, storage engine rationale, migration strategy

3. **generate-api-frontend**
   - Read `docs/summaries/interrogation-summary.md`
   - Read templates: `docs/templates/API_SPEC.md`, `docs/templates/FRONTEND_GUIDELINES.md`
   - Generate: `docs/API_SPEC.md`, `docs/FRONTEND_GUIDELINES.md`
   - Skip files that don't apply (e.g., no frontend = skip FRONTEND_GUIDELINES). Write a 1-line note to the file explaining why it was skipped.

4. **generate-impl-test**
   - Read `docs/summaries/interrogation-summary.md`
   - Read templates: `docs/templates/IMPLEMENTATION_PLAN.md`, `docs/templates/TESTING_PLAN.md`
   - Generate: `docs/IMPLEMENTATION_PLAN.md`, `docs/TESTING_PLAN.md`
   - IMPLEMENTATION_PLAN must have ordered, numbered steps with clear acceptance criteria per step
   - TESTING_PLAN must reference specific files/functions from the implementation plan

5. **generate-security-ops**
   - Read `docs/summaries/interrogation-summary.md`
   - Read templates: `docs/templates/SECURITY_CHECKLIST.md`, `docs/templates/OBSERVABILITY.md`, `docs/templates/ROLLOUT_PLAN.md`
   - Generate: `docs/SECURITY_CHECKLIST.md`, `docs/OBSERVABILITY.md`, `docs/ROLLOUT_PLAN.md`

### Step 3: Spawn Teammates
Spawn 5 `general-purpose` teammates, one per task. Each teammate:
- Reads ONLY `docs/summaries/interrogation-summary.md` (not each other's output)
- Reads the relevant template(s) from `docs/templates/`
- Writes the finished document(s) to `docs/`
- Marks their task complete when done

### Step 4: Monitor and Collect
- Wait for all 5 tasks to complete
- If any teammate fails, retry that specific task (don't re-run succeeded tasks)
- When all succeed, read all generated docs and create the documentation summary

### Step 5: Generate Summary
Write `docs/summaries/documentation-summary.md` as a pyramid summary:

**Executive (5 lines):**
- Total docs generated
- Key architectural decisions captured
- Any sections marked [NEEDS_DETAIL]
- Tech stack summary
- Implementation plan step count

**Detailed (50 lines):**
- One line per document with status and key content
- List any cross-doc inconsistencies found
- List any gaps or [NEEDS_DETAIL] sections

### Step 6: Cleanup
- Shut down all teammates
- Delete the team
- Update Memory MCP with `pipeline_state=documented`

## Coordination Rules
- Each teammate reads ONLY the interrogation summary (not each other's output)
- No file conflicts: each task writes to distinct, pre-assigned files
- If a template doesn't apply, write a 1-line skip note (don't leave the file missing)
- Lead validates cross-doc consistency AFTER all tasks complete

## Fallback (No Agent Teams)
If Agent Teams is unavailable, generate docs sequentially in this order:
1. PRD + APP_FLOW (highest priority - defines scope)
2. TECH_STACK + DATA_MODELS (defines constraints)
3. IMPLEMENTATION_PLAN + TESTING_PLAN (defines work)
4. API_SPEC + FRONTEND_GUIDELINES (if applicable)
5. SECURITY_CHECKLIST + OBSERVABILITY + ROLLOUT_PLAN
