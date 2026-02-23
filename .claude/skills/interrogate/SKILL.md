---
name: interrogate
description: "13-section interrogation protocol. Supports INTERACTIVE (ask human) and AUTONOMOUS (search/infer/assume) modes."
allowed-tools: Read, Write, Bash, Glob, Grep, WebSearch, WebFetch, mcp__memory__*
---

# Interrogation Protocol

Comprehensive requirements gathering across 13 sections. This is the CORE of the framework.

## Mode Detection
- **INTERACTIVE** (default): Ask the human each question. Wait for answers. Confirm MCP-sourced data.
- **AUTONOMOUS** (when AUTONOMOUS_MODE=true or running via run-pipeline.sh): No human available. For each question: SEARCH MCP sources -> INFER from codebase -> ASSUME with [ASSUMPTION] tags.

## Pre-Interrogation
1. Read `docs/summaries/phase0-summary.md` for project context
2. Read any existing docs in `docs/` that may already answer questions
3. If resuming, read `docs/artifacts/interrogation-*.md` for prior transcript

## The 13 Sections

### Section 1: Problem Statement & User Stories
**Questions:**
- What problem does this solve? Who has this problem today?
- What is the current workaround (if any)?
- Write 3-5 user stories in "As a [persona], I want [action], so that [benefit]" format
- What is the MVP scope? What is explicitly OUT of scope?

**AUTONOMOUS sources:** README, Jira/Linear tickets, PRD drafts, Confluence pages

### Section 2: Target Users / Personas
**Questions:**
- Who are the primary users? Secondary users?
- What is their technical skill level?
- What devices/platforms do they use?
- What is their usage frequency (daily/weekly/monthly)?

**AUTONOMOUS sources:** existing user research, analytics configs, persona docs

### Section 3: Functional Requirements
**Questions:**
- List every feature the system must support (numbered)
- For each feature: input, processing, output, error states
- What are the critical user flows (happy path)?
- What are the edge cases for each flow?

**AUTONOMOUS sources:** existing code (infer from routes/handlers), API specs, test files

### Section 4: Non-Functional Requirements
**Questions:**
- Performance targets: p50/p95/p99 latency, throughput
- Scale: expected users, data volume, growth rate
- Availability: uptime SLA, RTO/RPO
- Accessibility: WCAG level, i18n requirements

**AUTONOMOUS sources:** infrastructure configs, load test results, SLA docs
<!-- TODO: Customize default NFR targets for your organization -->

### Section 5: Technical Stack & Constraints
**Questions:**
- Language(s) and version(s)?
- Framework(s) and version(s)?
- Database(s) and why?
- External services/APIs?
- Deployment target (cloud provider, container orchestration)?
- Any mandated tools or libraries?

**AUTONOMOUS sources:** package.json/pyproject.toml/go.mod, Dockerfile, CI configs

### Section 6: Data Model & Storage
**Questions:**
- Core entities and their relationships (ERD)
- Storage engine choice and rationale
- Data lifecycle: creation, updates, deletion, archival
- Migration strategy: schema versioning approach
- Data volume estimates per entity per year

**AUTONOMOUS sources:** existing models/schemas, migration files, ORM configs

### Section 7: API Design / Integration Points
**Questions:**
- API style: REST, GraphQL, gRPC, WebSocket?
- Authentication method for API consumers
- Rate limiting and quotas
- Versioning strategy
- Key endpoints with request/response shapes
- External API dependencies (with SLA expectations)

**AUTONOMOUS sources:** existing route definitions, OpenAPI specs, integration code

### Section 8: Authentication & Authorization
**Questions:**
- Auth provider: built-in, OAuth, SSO, SAML?
- Session management: JWT, cookies, tokens?
- Role model: RBAC, ABAC, ACL?
- Define roles and their permissions
- Multi-tenancy considerations

**AUTONOMOUS sources:** auth middleware, role definitions, security configs

### Section 9: Error Handling & Edge Cases
**Questions:**
- Error taxonomy: user errors, system errors, external errors
- Retry strategy for transient failures
- Circuit breaker thresholds
- Graceful degradation plan
- User-facing error messages (tone, detail level)
- Logging and alerting for error categories

**AUTONOMOUS sources:** existing error handlers, monitoring configs, logging setup

### Section 10: Testing Strategy
**Questions:**
- Unit test coverage target (%)
- Integration test scope
- E2E test scenarios (critical paths only)
- Performance/load test plan
- Test data strategy: fixtures, factories, seeds
- CI test pipeline configuration

**AUTONOMOUS sources:** existing test files, CI configs, test configs
<!-- TODO: Customize coverage targets for your team standards -->

### Section 11: Deployment & Infrastructure
**Questions:**
- Deployment pipeline: stages and gates
- Environment tiers: dev, staging, prod
- Infrastructure as Code: Terraform, Pulumi, CDK?
- Container strategy: Docker, buildpacks?
- Secrets management
- Rollback procedure

**AUTONOMOUS sources:** Dockerfile, docker-compose, IaC files, CI/CD configs

### Section 12: Security & Compliance
**Questions:**
- Compliance requirements: SOC2, HIPAA, GDPR, PCI-DSS?
- Data classification: what is PII, what is sensitive?
- Encryption: at rest, in transit, field-level?
- Audit logging requirements
- Vulnerability scanning and dependency auditing
- Incident response plan

**AUTONOMOUS sources:** security policies, compliance docs, existing audit logs
<!-- TODO: Customize compliance requirements for your domain -->

### Section 13: Success Metrics & Acceptance Criteria
**Questions:**
- How do we know this succeeded? (quantitative metrics)
- What are the acceptance criteria for each user story?
- What monitoring/dashboards are needed?
- What does "done" look like for the MVP?
- Post-launch success criteria (30/60/90 day)

**AUTONOMOUS sources:** OKR docs, analytics setup, dashboard configs

## Post-Interrogation

### Write Transcript
Write the full Q&A transcript to: `docs/artifacts/interrogation-[date].md`

Format each section as:
```
## Section N: [Title]
### Q: [question]
**A:** [answer]
**Source:** [human | MCP:jira:TICKET-123 | codebase:path/to/file | ASSUMPTION:rationale]
**Confidence:** [HIGH | MEDIUM | LOW] (autonomous mode only)
```

### Write MCP Context (autonomous mode only)
Write all fetched MCP content to: `docs/artifacts/mcp-context-[date].md`

### Generate Pyramid Summary
Write to: `docs/summaries/interrogation-summary.md`

**Executive (5 lines):**
1. Core problem being solved
2. Primary user persona
3. Tech stack
4. Key constraint or risk
5. MVP scope in one sentence

**Detailed (50 lines):**
- All requirements, one per line, numbered
- Grouped by section

**Assumptions:**
- All [ASSUMPTION] items with confidence level
- All [NEEDS_HUMAN] items that could not be safely assumed
- All [DRAFT_SPEC] items that need review

### Update Memory MCP
Set `pipeline_state=interrogated` and store key decisions.
