---
globs: ["**/*"]
---

# Assumptions Policy

## Interactive Mode (default)
- Never guess. If unclear, ASK.
- Never write code until documentation is approved.
- State assumptions explicitly before proposing solutions.
- Present options with trade-offs; don't just pick one.
- When pre-filling answers from MCP sources, confirm: "Based on [source], I believe [answer]. Correct?"
- If a question was skipped, document WHY it was skipped.
- When in doubt about scope, treat it as out of scope until confirmed.
- "I think" and "probably" are red flags. Replace with "I need to confirm" and ask.

## Autonomous Mode (activated when AUTONOMOUS_MODE=true or running via run-pipeline.sh)
When no human is available to answer questions:
1. SEARCH first: query all MCP sources (Jira, Confluence, Slack, Drive, codebase)
2. INFER second: use codebase patterns, industry conventions, and related context
3. ASSUME last: make the most reasonable assumption given available evidence

Every assumption MUST be:
- Marked explicitly: [ASSUMPTION: one-line rationale]
- Assigned confidence: HIGH (strong evidence) | MEDIUM (reasonable inference) | LOW (best guess)
- Logged to docs/artifacts/ for later human review
- Listed in the interrogation summary's Assumptions section

LOW confidence assumptions on critical topics (auth model, compliance, data retention) should be flagged as [NEEDS_HUMAN] rather than assumed.

The pipeline's LLM-as-Judge review phase will catch unreasonable assumptions before implementation proceeds.

## Spec-the-Gap (when assumptions aren't enough)
When an interrogation section has NO data from any source AND assumptions would be irresponsible (e.g., compliance requirements, data retention policies), generate a DRAFT spec:
1. Scan existing codebase for patterns that imply requirements (e.g., existing auth middleware implies auth is required)
2. Search similar open-source projects for industry conventions
3. Generate a draft spec section marked as [DRAFT_SPEC: generated from {source}]
4. DRAFT_SPECs are NOT assumptions - they are proposals that MUST be reviewed

Write all DRAFT_SPECs to docs/artifacts/draft-specs-[date].md.
The LLM-as-Judge review phase MUST flag all DRAFT_SPECs for explicit attention.

## MCP Pre-Fill Verification
When MCP sources pre-fill an answer, the agent MUST NOT uncritically accept it:
1. State the source: "Based on [Jira ticket X / Confluence page Y], I believe..."
2. Cross-reference: check if other sources contradict (e.g., Jira says Node.js but codebase is Python)
3. Freshness check: flag data older than 90 days as [STALE_SOURCE: last updated {date}]
4. Never let a single MCP source override multiple contradicting sources
