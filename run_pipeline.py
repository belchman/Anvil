#!/usr/bin/env python3
"""
Interrogation Protocol v3.0 - Agent SDK Pipeline Runner
Alternative to run-pipeline.sh with structured types and proper error handling.

Install: pip install claude-agent-sdk-python
Usage: python run_pipeline.py "TICKET-ID"
"""
import asyncio
import json
import re
import subprocess
import sys
import os
from datetime import datetime, timezone
from pathlib import Path
from dataclasses import dataclass, field

from claude_agent_sdk import (
    ClaudeAgent,
    AgentConfig,
    SessionConfig,
    ToolResult,
    Hook,
    HookEvent,
)


# --- Configuration ---

MODELS = {
    "phase0": "claude-sonnet-4-5-20250929",
    "interrogate": "claude-opus-4-6",
    "review": "claude-sonnet-4-5-20250929",
    "generate_docs": "claude-opus-4-6",
    "implement": "claude-opus-4-6",
    "verify": "claude-sonnet-4-5-20250929",
    "security": "claude-sonnet-4-5-20250929",
    "holdout": "claude-sonnet-4-5-20250929",
    "ship": "claude-sonnet-4-5-20250929",
}

MAX_VERIFY_RETRIES = 3
MAX_INTERROGATION_ITERATIONS = 2
STAGNATION_SIMILARITY_THRESHOLD = 0.90


# --- Data Types ---

@dataclass
class PhaseConfig:
    name: str
    prompt: str
    model: str = "claude-opus-4-6"
    max_turns: int = 25
    max_budget_usd: float = 5.0
    timeout_seconds: int = 600
    fidelity: str = "summary:high"


@dataclass
class PhaseResult:
    name: str
    cost_usd: float = 0.0
    turns: int = 0
    verdict: str = "UNKNOWN"
    satisfaction_score: float = 0.0
    session_id: str = ""
    error: str | None = None


@dataclass
class ImplStep:
    id: str
    title: str
    description: str


@dataclass
class PipelineState:
    ticket: str
    status: str = "running"
    current_phase: str = ""
    total_cost: float = 0.0
    max_cost: float = 50.0
    phases: list[PhaseResult] = field(default_factory=list)
    log_dir: Path = field(default_factory=lambda: Path("docs/artifacts/pipeline-runs") / datetime.now().strftime("%Y-%m-%d-%H%M"))
    kill_switch: Path = Path(".pipeline-kill")

    def check_kill_switch(self):
        if self.kill_switch.exists():
            raise RuntimeError(f"Kill switch activated: {self.kill_switch}")

    def check_cost_ceiling(self):
        if self.total_cost > self.max_cost:
            raise RuntimeError(f"Cost ceiling exceeded: ${self.total_cost:.2f} > ${self.max_cost:.2f}")

    def save_checkpoint(self):
        self.log_dir.mkdir(parents=True, exist_ok=True)
        checkpoint = {
            "status": self.status,
            "current_phase": self.current_phase,
            "ticket": self.ticket,
            "total_cost": self.total_cost,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "phases": [
                {"name": p.name, "cost": p.cost_usd, "turns": p.turns, "verdict": p.verdict}
                for p in self.phases
            ],
        }
        (self.log_dir / "checkpoint.json").write_text(json.dumps(checkpoint, indent=2))

    def save_costs(self):
        self.log_dir.mkdir(parents=True, exist_ok=True)
        costs = {
            "phases": [
                {"name": p.name, "cost": p.cost_usd, "turns": p.turns, "session_id": p.session_id}
                for p in self.phases
            ],
            "total_cost": self.total_cost,
            "status": self.status,
            "started": self.phases[0].name if self.phases else "unknown",
        }
        (self.log_dir / "costs.json").write_text(json.dumps(costs, indent=2))


# --- Parsing Helpers ---

def parse_verdict(result_text: str) -> str:
    """Extract VERDICT from agent output."""
    for line in reversed(result_text.split("\n")):
        if "VERDICT:" in line:
            return line.split("VERDICT:")[-1].strip().split()[0]
    return "UNKNOWN"


def parse_satisfaction(result_text: str) -> float:
    """Extract aggregate satisfaction score from JSON in output."""
    try:
        match = re.search(r'"aggregate"\s*:\s*([\d.]+)', result_text)
        if match:
            return float(match.group(1))
    except (ValueError, AttributeError):
        pass
    return 0.0


def score_to_verdict(score: float) -> str:
    """Convert satisfaction score to verdict."""
    if score >= 0.9:
        return "AUTO_PASS"
    elif score >= 0.7:
        return "PASS_WITH_NOTES"
    elif score >= 0.5:
        return "ITERATE"
    return "BLOCK"


def get_git_head() -> str:
    """Get current HEAD commit hash."""
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "none"


# --- Phase Runner ---

async def run_phase(state: PipelineState, config: PhaseConfig) -> PhaseResult:
    """Run a single pipeline phase via Agent SDK."""
    state.check_kill_switch()
    state.check_cost_ceiling()
    state.current_phase = config.name
    state.save_checkpoint()

    print(f"\n{'='*60}")
    print(f"  Phase: {config.name}")
    print(f"  Model: {config.model} | Max turns: {config.max_turns} | Budget: ${config.max_budget_usd}")
    print(f"{'='*60}\n")

    agent = ClaudeAgent(
        config=AgentConfig(
            model=config.model,
            max_turns=config.max_turns,
            max_budget_usd=config.max_budget_usd,
            permission_mode="acceptEdits",
        ),
        session=SessionConfig(
            timeout_seconds=config.timeout_seconds,
        ),
    )

    result_text = ""
    try:
        result = await asyncio.wait_for(
            agent.run(config.prompt),
            timeout=config.timeout_seconds,
        )
        result_text = result.text

        phase_result = PhaseResult(
            name=config.name,
            cost_usd=result.cost_usd,
            turns=result.num_turns,
            verdict=parse_verdict(result.text),
            satisfaction_score=parse_satisfaction(result.text),
            session_id=result.session_id,
        )

    except asyncio.TimeoutError:
        phase_result = PhaseResult(
            name=config.name,
            error=f"Timeout after {config.timeout_seconds}s",
        )
    except Exception as e:
        phase_result = PhaseResult(
            name=config.name,
            error=str(e),
        )

    # Save phase output
    state.log_dir.mkdir(parents=True, exist_ok=True)
    output_data = {
        "result": result_text if not phase_result.error else phase_result.error,
        **{k: v for k, v in vars(phase_result).items() if k != "error"},
    }
    if phase_result.error:
        output_data["error"] = phase_result.error
    (state.log_dir / f"{config.name}.json").write_text(
        json.dumps(output_data, indent=2, default=str)
    )

    state.total_cost += phase_result.cost_usd
    state.phases.append(phase_result)
    state.save_checkpoint()
    state.save_costs()

    print(f"  Result: verdict={phase_result.verdict} cost=${phase_result.cost_usd:.2f} turns={phase_result.turns}")

    if phase_result.error:
        raise RuntimeError(f"Phase {config.name} failed: {phase_result.error}")

    return phase_result


# --- Routing ---

def route_from_gate(gate: str, verdict: str, retries: int = 0) -> str:
    """Graph-based routing from gate verdict."""
    key = f"{gate}:{verdict}"
    routes = {
        "interrogation-review:AUTO_PASS": "generate-docs",
        "interrogation-review:PASS_WITH_NOTES": "generate-docs",
        "interrogation-review:PASS": "generate-docs",
        "interrogation-review:ITERATE": "interrogate",
        "interrogation-review:NEEDS_HUMAN": "BLOCKED",
        "interrogation-review:BLOCK": "BLOCKED",
        "doc-review:AUTO_PASS": "holdout-generate",
        "doc-review:PASS_WITH_NOTES": "holdout-generate",
        "doc-review:PASS": "holdout-generate",
        "doc-review:ITERATE": "generate-docs",
        "holdout-validate:AUTO_PASS": "security-audit",
        "holdout-validate:PASS_WITH_NOTES": "security-audit",
        "holdout-validate:PASS": "security-audit",
        "holdout-validate:FAIL": "implement",
        "security-audit:PASS": "ship",
        "security-audit:AUTO_PASS": "ship",
        "security-audit:FAIL": "implement",
    }

    if key in routes:
        return routes[key]

    if gate == "verify":
        if verdict in ("PASS", "AUTO_PASS", "PASS_WITH_NOTES"):
            return "next-step-or-holdout"
        if retries >= MAX_VERIFY_RETRIES:
            return "BLOCKED"
        return "implement"

    return "BLOCKED"


# --- Implementation Loop ---

async def extract_impl_steps(state: PipelineState, ticket: str) -> list[ImplStep]:
    """Extract implementation steps from IMPLEMENTATION_PLAN.md."""
    result = await run_phase(state, PhaseConfig(
        name="extract-steps",
        prompt=(
            'Read docs/IMPLEMENTATION_PLAN.md and output ONLY a JSON array of step objects: '
            '[{"id": "step-1", "title": "...", "description": "..."}]. '
            'Output valid JSON only, no markdown fences.'
        ),
        model="claude-sonnet-4-5-20250929",
        max_turns=5,
        max_budget_usd=1.0,
        timeout_seconds=120,
    ))

    # Parse steps from result
    output_file = state.log_dir / "extract-steps.json"
    if output_file.exists():
        data = json.loads(output_file.read_text())
        result_text = data.get("result", "")
        # Find JSON array in the result
        match = re.search(r'\[.*\]', result_text, re.DOTALL)
        if match:
            steps_data = json.loads(match.group())
            return [
                ImplStep(id=s["id"], title=s["title"], description=s["description"])
                for s in steps_data
            ]
    return []


async def implement_and_verify(
    state: PipelineState,
    step: ImplStep,
    ticket: str,
) -> bool:
    """Implement a single step with retry loop. Returns True if verified."""
    last_commit = get_git_head()
    no_progress_count = 0

    for attempt in range(1, MAX_VERIFY_RETRIES + 1):
        state.check_kill_switch()
        state.check_cost_ceiling()

        # Build error context from previous attempt
        error_context = ""
        if attempt > 1:
            prev_output = state.log_dir / f"verify-{step.id}-attempt-{attempt - 1}.json"
            if prev_output.exists():
                prev_data = json.loads(prev_output.read_text())
                prev_error = prev_data.get("result", "")[:2000]  # Truncate
                error_context = (
                    f"RETRY ATTEMPT {attempt}/{MAX_VERIFY_RETRIES}. "
                    f"Previous error:\n{prev_error}"
                )

        # Implement
        await run_phase(state, PhaseConfig(
            name=f"implement-{step.id}-attempt-{attempt}",
            prompt=(
                f"You are implementing step {step.id}: {step.title}\n\n"
                f"Read CLAUDE.md for rules. Read docs/summaries/documentation-summary.md for context.\n"
                f"Read the specific doc sections relevant to this step.\n\n"
                f"Description: {step.description}\n\n"
                f"{error_context}\n\n"
                f"Implement this step. Follow existing codebase patterns. Type everything. Handle all errors.\n"
                f"After implementation, run the project's type checker and linter to verify your changes compile.\n"
                f"Commit your changes with message: 'feat({step.id}): {step.title}'"
            ),
            model=MODELS["implement"],
            max_turns=40,
            max_budget_usd=8.0,
            timeout_seconds=600,
        ))

        # Check git progress
        current_commit = get_git_head()
        if current_commit == last_commit and last_commit != "none":
            no_progress_count += 1
            print(f"  [WARN] No new git commits after {step.id} (count: {no_progress_count})")
            if no_progress_count >= 3:
                state.status = "stalled_no_progress"
                state.save_checkpoint()
                raise RuntimeError(f"No git progress for 3 consecutive attempts on {step.id}")
        else:
            no_progress_count = 0
            last_commit = current_commit

        # Verify (fast mode for early attempts, full suite for final)
        fast_mode = attempt < MAX_VERIFY_RETRIES
        test_instruction = (
            "Run scripts/agent-test.sh if it exists, otherwise run the project's test command"
            if fast_mode
            else "Run the FULL test suite (not sampled)"
        )

        try:
            verify_result = await run_phase(state, PhaseConfig(
                name=f"verify-{step.id}-attempt-{attempt}",
                prompt=(
                    f"You are a VERIFICATION agent. Verify that step {step.id} ({step.title}) was implemented correctly.\n\n"
                    f"Run all relevant checks in order (stop on first failure):\n"
                    f"1. Type checking (tsc --noEmit / mypy / go vet / cargo clippy)\n"
                    f"2. Linting (eslint / ruff / golint)\n"
                    f"3. Tests: {test_instruction}\n"
                    f"4. Build (npm run build / go build / cargo build)\n\n"
                    f"If ALL pass: output VERDICT: PASS\n"
                    f"If ANY fail: output VERDICT: FAIL with the specific error (first 50 lines only)\n\n"
                    f"Always include VERDICT: [PASS|FAIL] as the last line."
                ),
                model=MODELS["verify"],
                max_turns=15,
                max_budget_usd=3.0,
                timeout_seconds=300,
            ))
        except RuntimeError:
            verify_result = PhaseResult(name=f"verify-{step.id}-attempt-{attempt}", verdict="FAIL")

        if verify_result.verdict in ("PASS", "AUTO_PASS", "PASS_WITH_NOTES"):
            print(f"  Step {step.id} verified on attempt {attempt}")
            return True

        print(f"  [WARN] Step {step.id} failed verification (attempt {attempt}/{MAX_VERIFY_RETRIES})")

        if attempt == MAX_VERIFY_RETRIES:
            state.status = "blocked"
            state.save_checkpoint()
            block_file = state.log_dir / f"blocked-{step.id}.txt"
            block_file.write_text(
                f"BLOCKED: Step {step.id} failed {MAX_VERIFY_RETRIES} verification attempts.\n"
                f"See verify logs for details.\n"
            )
            return False

    return False


# --- Main Pipeline ---

async def main():
    ticket = sys.argv[1] if len(sys.argv) > 1 else "NO-TICKET"
    state = PipelineState(
        ticket=ticket,
        max_cost=float(os.environ.get("MAX_PIPELINE_COST", "50")),
    )

    print(f"Starting pipeline for: {ticket}")
    print(f"Max cost: ${state.max_cost:.2f}")
    print(f"Logs: {state.log_dir}")

    try:
        # ---- Stage 1: Context Scan ----
        await run_phase(state, PhaseConfig(
            name="phase0",
            prompt=(
                "You are running the Interrogation Protocol pipeline autonomously. "
                "Read CLAUDE.md first, then execute the phase0 context scan: scan git state, "
                "check Memory MCP for prior pipeline state, identify project type, TODOs, test status, blockers. "
                "Write a phase0-summary.md to docs/summaries/. Output must be under 20 lines."
            ),
            model=MODELS["phase0"],
            max_turns=15, max_budget_usd=2.0, timeout_seconds=120,
        ))

        # ---- Stage 2: Interrogation ----
        await run_phase(state, PhaseConfig(
            name="interrogate",
            prompt=(
                f"Autonomous interrogation for ticket: {ticket}. AUTONOMOUS_MODE=true. "
                "Read CLAUDE.md, then docs/summaries/phase0-summary.md. "
                "Execute the full interrogation protocol (all 13 sections). For each section: "
                "1. Search MCP sources 2. Search codebase 3. Assume with [ASSUMPTION] tags if needed. "
                "Write transcript to docs/artifacts/ and pyramid summary to docs/summaries/interrogation-summary.md."
            ),
            model=MODELS["interrogate"],
            max_turns=50, max_budget_usd=8.0,
        ))

        # ---- Stage 3: Interrogation Review (LLM-as-Judge) ----
        review = await run_phase(state, PhaseConfig(
            name="interrogation-review",
            prompt=(
                "You are a REVIEWER agent. You did NOT write the interrogation output. "
                "Read docs/summaries/interrogation-summary.md. Score each section 1-5. "
                "Calculate overall satisfaction as aggregate decimal. "
                "Output VERDICT: PASS|ITERATE|NEEDS_HUMAN as the last line."
            ),
            model=MODELS["review"],
            max_turns=20, max_budget_usd=3.0,
        ))

        next_phase = route_from_gate("interrogation-review", review.verdict)
        if next_phase == "BLOCKED":
            state.status = "needs_human"
            state.save_checkpoint()
            print("\nPipeline paused: human input needed for interrogation")
            sys.exit(2)
        if next_phase == "interrogate":
            await run_phase(state, PhaseConfig(
                name="interrogate-v2",
                prompt=(
                    "Re-run interrogation addressing gaps in docs/summaries/interrogation-review.md. "
                    "Focus on sections that scored below 3. Update summaries."
                ),
                model=MODELS["interrogate"],
                max_turns=50, max_budget_usd=8.0,
            ))

        # ---- Stage 4: Doc Generation ----
        await run_phase(state, PhaseConfig(
            name="generate-docs",
            prompt=(
                "Generate all applicable documents from docs/templates/. "
                "Read docs/summaries/interrogation-summary.md for requirements. "
                "Write each to docs/[name].md. After all docs: write docs/summaries/documentation-summary.md."
            ),
            model=MODELS["generate_docs"],
            max_turns=50, max_budget_usd=10.0,
        ))

        # ---- Stage 5: Doc Review ----
        doc_review = await run_phase(state, PhaseConfig(
            name="doc-review",
            prompt=(
                "You are a REVIEWER agent. Review generated docs for completeness. "
                "Spot-check docs/PRD.md, docs/IMPLEMENTATION_PLAN.md, docs/TESTING_PLAN.md. "
                "Score satisfaction as aggregate decimal. If >= 80%: VERDICT: PASS. "
                "If < 80%: VERDICT: ITERATE. Always include VERDICT as the last line."
            ),
            model=MODELS["review"],
            max_turns=20, max_budget_usd=3.0,
        ))

        doc_next = route_from_gate("doc-review", doc_review.verdict)
        if doc_next == "generate-docs":
            await run_phase(state, PhaseConfig(
                name="generate-docs-v2",
                prompt="Re-generate docs addressing gaps from doc review. Focus on flagged sections.",
                model=MODELS["generate_docs"],
                max_turns=50, max_budget_usd=10.0,
            ))

        # ---- Stage 5b: Holdout Generation ----
        holdouts_dir = Path(".holdouts")
        existing_holdouts = list(holdouts_dir.glob("holdout-001-*.md")) if holdouts_dir.exists() else []
        if not existing_holdouts:
            await run_phase(state, PhaseConfig(
                name="holdout-generate",
                prompt=(
                    "You are the HOLDOUT GENERATOR agent in COMPLETE ISOLATION from implementation. "
                    "Read docs/PRD.md, docs/APP_FLOW.md, docs/API_SPEC.md, docs/DATA_MODELS.md. "
                    "Generate 8-12 adversarial test scenarios. Write each to .holdouts/holdout-NNN-[slug].md."
                ),
                model=MODELS["holdout"],
                max_turns=25, max_budget_usd=5.0,
            ))

        # ---- Stage 6: Implementation Loop ----
        steps = await extract_impl_steps(state, ticket)
        print(f"\nImplementation plan has {len(steps)} steps")

        for step in steps:
            print(f"\n--- Implementing: {step.id} - {step.title} ---")
            verified = await implement_and_verify(state, step, ticket)
            if not verified:
                print(f"\n[ERROR] Step {step.id} blocked after {MAX_VERIFY_RETRIES} attempts")
                sys.exit(3)

        # ---- Stage 7: Holdout Validation ----
        holdout_files = list(holdouts_dir.glob("holdout-*.md")) if holdouts_dir.exists() else []
        if holdout_files:
            holdout_result = await run_phase(state, PhaseConfig(
                name="holdout-validate",
                prompt=(
                    "You are a HOLDOUT VALIDATION agent. Test the implementation against hidden scenarios. "
                    "Read each file in .holdouts/holdout-*.md. For each scenario: check preconditions, "
                    "walk through steps against actual code, evaluate acceptance criteria. "
                    "Score: (satisfied / total) as percentage. "
                    "If >= 80% and 0 anti-pattern flags: VERDICT: PASS. "
                    "If < 80%: VERDICT: FAIL. Always include VERDICT as last line."
                ),
                model=MODELS["holdout"],
                max_turns=25, max_budget_usd=5.0,
            ))

            holdout_next = route_from_gate("holdout-validate", holdout_result.verdict)
            if holdout_next == "implement":
                state.status = "holdout_failed"
                state.save_checkpoint()
                print("\n[ERROR] Holdout validation failed")
                sys.exit(4)

        # ---- Stage 8: Security Audit ----
        security_result = await run_phase(state, PhaseConfig(
            name="security-audit",
            prompt=(
                "You are a SECURITY AUDITOR. Scan all source files for: "
                "hardcoded secrets, SQL/XSS/command injection, missing auth checks, "
                "insecure defaults, missing input validation, sensitive data in logs. "
                "Severity: BLOCKER | WARNING | INFO. "
                "If 0 BLOCKERs: VERDICT: PASS. If any BLOCKERs: VERDICT: FAIL. "
                "Always include VERDICT as last line."
            ),
            model=MODELS["security"],
            max_turns=20, max_budget_usd=3.0,
        ))

        security_next = route_from_gate("security-audit", security_result.verdict)
        if security_next == "implement":
            print("  [WARN] Security blockers found. Attempting auto-fix.")
            await run_phase(state, PhaseConfig(
                name="security-fix",
                prompt=(
                    f"Read {state.log_dir}/security-audit.json. Fix all BLOCKER-severity issues. "
                    "Do not change functionality. Commit with message 'fix(security): address audit findings'"
                ),
                model=MODELS["implement"],
                max_turns=40, max_budget_usd=8.0,
            ))

        # ---- Stage 9: Ship ----
        await run_phase(state, PhaseConfig(
            name="ship",
            prompt=(
                f"You are running the final SHIP phase.\n\n"
                f"Pre-flight checks:\n"
                f"1. Run full test suite one final time\n"
                f"2. Verify all implementation steps are committed\n"
                f"3. Verify no uncommitted changes\n\n"
                f"If all pass, create a PR:\n"
                f"- Title: '{ticket}: [generated title from PRD]'\n"
                f"- Body: built from docs/summaries/ (executive sections only)\n"
                f"Push branch and create PR via gh CLI. Output the PR URL as the last line."
            ),
            model=MODELS["ship"],
            max_turns=20, max_budget_usd=5.0,
        ))

        state.status = "completed"

    except RuntimeError as e:
        state.status = "failed"
        print(f"\nPipeline failed: {e}")
        sys.exit(1)
    finally:
        state.save_checkpoint()
        state.save_costs()

        # Print cost report
        print(f"\n{'='*60}")
        print(f"  PIPELINE {'COMPLETE' if state.status == 'completed' else state.status.upper()}")
        print(f"{'='*60}")
        print(f"  Ticket: {ticket}")
        print(f"  Total cost: ${state.total_cost:.2f}")
        print(f"  Logs: {state.log_dir}")
        print(f"  Cost breakdown:")
        for p in state.phases:
            print(f"    {p.name}: ${p.cost_usd:.2f} ({p.turns} turns)")
        print(f"  Checkpoint: {state.log_dir / 'checkpoint.json'}")


if __name__ == "__main__":
    asyncio.run(main())
