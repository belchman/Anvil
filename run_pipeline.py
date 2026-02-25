#!/usr/bin/env python3
"""
Interrogation Protocol v3.0 - Agent SDK Pipeline Runner
Alternative to run-pipeline.sh with structured types and proper error handling.

Install: pip install claude-agent-sdk-python
Usage: python run_pipeline.py "TICKET-ID"
"""
import asyncio
import difflib
import hashlib
import json
import random
import re
import subprocess
import sys
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from dataclasses import dataclass, field

# Vendor boundary: Python runner is coupled to Claude Agent SDK.
# AGENT_COMMAND only applies to bash runner.
from claude_agent_sdk import (
    ClaudeAgent,
    AgentConfig,
    SessionConfig,
    ToolResult,
    Hook,
    HookEvent,
)


# --- Configuration ---

# Fallback defaults — overridden by pipeline.config.sh in main()
MODELS = {
    "phase0": "claude-sonnet-4-5-20250929",
    "interrogate": "claude-opus-4-6",
    "review": "claude-sonnet-4-5-20250929",
    "generate_docs": "claude-opus-4-6",
    "implement": "claude-opus-4-6",
    "verify": "claude-sonnet-4-5-20250929",
    "security": "claude-sonnet-4-5-20250929",
    "holdout_generate": "claude-opus-4-6",
    "holdout_validate": "claude-sonnet-4-5-20250929",
    "write_specs": "claude-sonnet-4-5-20250929",
    "ship": "claude-sonnet-4-5-20250929",
}

# Fallback defaults — overridden by pipeline.config.sh in main()
MAX_VERIFY_RETRIES = 3
MAX_INTERROGATION_ITERATIONS = 2
STAGNATION_SIMILARITY_THRESHOLD = 0.90

# Module-level config dict, populated from pipeline.config.sh in main()
_config: dict[str, str] = {}

# Fallback defaults — overridden by pipeline.config.sh in main()
PHASE_ORDER = [
    "phase0", "interrogate", "interrogation-review", "generate-docs",
    "doc-review", "write-specs", "holdout-generate", "implement",
    "holdout-validate", "security-audit", "ship",
]


# --- Config Loader ---

def load_bash_config(config_path: Path) -> dict[str, str]:
    """Parse KEY=VALUE lines from a bash config file."""
    config: dict[str, str] = {}
    if not config_path.exists():
        return config
    for line in config_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line and not line.startswith("for ") and not line.startswith("if "):
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key.isidentifier():
                config[key] = value
    return config


def get_config_int(config: dict[str, str], key: str, default: int) -> int:
    try:
        return int(config.get(key, str(default)))
    except ValueError:
        return default


def get_config_float(config: dict[str, str], key: str, default: float) -> float:
    try:
        return float(config.get(key, str(default)))
    except ValueError:
        return default


# --- Dynamic Fidelity Selection ---

def select_fidelity(default_mode: str, estimated_tokens: int = 0, window_size: int = 200000) -> str:
    """Auto-adjust fidelity based on context utilization."""
    if estimated_tokens <= 0:
        return default_mode

    utilization = (estimated_tokens * 100) // window_size

    DOWNGRADE = {
        "full": "truncate", "truncate": "summary:low",
        "summary:low": "summary:medium", "summary:medium": "summary:high",
        "summary:high": "compact",
    }
    UPGRADE = {
        "compact": "summary:high", "summary:high": "summary:medium",
        "summary:medium": "summary:low",
    }

    downgrade_threshold = get_config_int(_config, "FIDELITY_DOWNGRADE_THRESHOLD", 60)
    upgrade_threshold = get_config_int(_config, "FIDELITY_UPGRADE_THRESHOLD", 30)

    if utilization > downgrade_threshold:
        return DOWNGRADE.get(default_mode, "compact")
    elif utilization < upgrade_threshold:
        return UPGRADE.get(default_mode, default_mode)
    return default_mode


# --- Agent Teams Detection ---

def has_agent_teams() -> bool:
    """Check if Claude CLI supports agent teams."""
    try:
        output = subprocess.check_output(
            [_config.get("AGENT_COMMAND", "claude"), "--version"], stderr=subprocess.DEVNULL, text=True
        )
        return "agent-teams" in output
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


# --- Per-Phase Timeouts ---

def get_phase_timeout(config: dict[str, str], phase_name: str) -> int:
    """Get timeout for a phase, stripping suffixes to match config keys."""
    base = re.sub(r'-v\d+$', '', phase_name)
    base = re.sub(r'-attempt-\d+$', '', base)
    base = re.sub(r'-step-[\da-z-]+$', '', base)
    base = re.sub(r'-pass\d+$', '', base)
    upper = base.upper().replace("-", "_")
    default_timeout = get_config_int(config, "DEFAULT_TIMEOUT", 600)
    return get_config_int(config, f"TIMEOUT_{upper}", default_timeout)


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
class ProgressTracker:
    """Cross-phase git progress tracking."""
    last_commit: str = ""
    no_progress_count: int = 0
    max_no_progress: int = 3

    def check(self, phase_name: str) -> bool:
        """Check git progress. Returns False if stalled."""
        current = get_git_head()
        if phase_name.startswith("implement") or phase_name.startswith("security-fix"):
            if current == self.last_commit and self.last_commit:
                self.no_progress_count += 1
                print(f"  [WARN] No git commits after {phase_name} ({self.no_progress_count} consecutive)")
                if self.no_progress_count >= self.max_no_progress:
                    return False
            else:
                self.no_progress_count = 0
        self.last_commit = current
        return True


@dataclass
class ThreadManager:
    """Track thread IDs per phase for session management."""
    threads: dict[str, str] = field(default_factory=dict)

    @staticmethod
    def generate_id() -> str:
        return f"thread-{int(time.time())}-{random.randint(1000, 9999)}"

    def get_or_create(self, phase: str) -> str:
        if phase not in self.threads:
            self.threads[phase] = self.generate_id()
        return self.threads[phase]

    def fork(self, parent: str) -> str:
        child_id = self.generate_id()
        # In Agent SDK, sessions are managed differently,
        # but we track the lineage for logging
        self.threads[f"fork-{child_id}"] = child_id
        return child_id


@dataclass
class PipelineState:
    ticket: str
    status: str = "running"
    current_phase: str = ""
    total_cost: float = 0.0
    max_cost: float = 50.0
    resume_phase: str = ""
    phases: list[PhaseResult] = field(default_factory=list)
    log_dir: Path = field(default_factory=lambda: Path(_config.get("LOG_BASE_DIR", "docs/artifacts/pipeline-runs")) / datetime.now().strftime("%Y-%m-%d-%H%M"))
    kill_switch: Path = field(default_factory=lambda: Path(_config.get("KILL_SWITCH_FILE", ".pipeline-kill")))

    def check_kill_switch(self):
        if self.kill_switch.exists():
            raise RuntimeError(f"Kill switch activated: {self.kill_switch}")

    def check_cost_ceiling(self):
        if self.total_cost > self.max_cost:
            raise RuntimeError(f"Cost ceiling exceeded: ${self.total_cost:.2f} > ${self.max_cost:.2f}")

    resolved_tier: str = ""

    def tier_allows_phase(self, phase: str) -> bool:
        """Check if the current pipeline tier allows this phase."""
        if not self.resolved_tier:
            self.resolved_tier = _config.get("PIPELINE_TIER", "full")
            if self.resolved_tier == "auto":
                # Read scope from phase0 output
                phase0_file = self.log_dir / "phase0.json"
                scope = 3
                if phase0_file.exists():
                    result = json.loads(phase0_file.read_text()).get("result", "")
                    match = re.search(r'SCOPE:\s*([1-5])', result)
                    if match:
                        scope = int(match.group(1))
                if scope <= 1:
                    self.resolved_tier = "nano"
                elif scope <= 2:
                    self.resolved_tier = "quick"
                elif scope <= 3:
                    self.resolved_tier = "standard"
                else:
                    self.resolved_tier = "full"
                print(f"  Auto-tier: scope={scope} -> tier={self.resolved_tier}")

        skip_phases: dict[str, set[str]] = {
            "nano": {"interrogation-review", "generate-docs", "doc-review", "write-specs", "holdout-generate", "holdout-validate", "security-audit"},
            "quick": {"write-specs", "holdout-generate", "holdout-validate", "security-audit"},
            "standard": {"holdout-generate", "holdout-validate"},
        }
        return phase not in skip_phases.get(self.resolved_tier, set())

    def should_run_phase(self, phase: str) -> bool:
        """Check if phase should run (skip completed phases when resuming)."""
        if not self.resume_phase:
            if not self.tier_allows_phase(phase):
                print(f"  Skipping {phase} (tier: {self.resolved_tier})")
                return False
            return True

        # Skip phases before resume point
        reached_resume = False
        for p in PHASE_ORDER:
            if p == self.resume_phase:
                reached_resume = True
            if p == phase:
                if not reached_resume:
                    print(f"  Skipping {phase} (before resume point: {self.resume_phase})")
                    return False
                break

        # Skip already-completed phases
        completed_phases = {p.name for p in self.phases}
        if phase in completed_phases:
            print(f"  Skipping {phase} (already completed)")
            return False

        # Tier filtering
        if not self.tier_allows_phase(phase):
            print(f"  Skipping {phase} (tier: {self.resolved_tier})")
            return False

        # Doc generation mode filtering
        if _config.get("DOC_TEMPLATES_MODE", "auto") == "none" and phase in ("generate-docs", "doc-review"):
            print(f"  Skipping {phase} (DOC_TEMPLATES_MODE=none)")
            return False

        # Human gate check
        human_gates = [g.strip() for g in _config.get("HUMAN_GATES", "").split(",") if g.strip()]
        if phase in human_gates:
            approval_file = self.log_dir / f"{phase}.human-approved"
            if approval_file.exists():
                print(f"  Human gate for {phase}: approved")
            else:
                print(f"  [WARN] Human gate: {phase} requires human approval before proceeding.")
                print(f"  Review output in {self.log_dir}/, then: touch {approval_file}")
                print(f"  Resume with: python run_pipeline.py \"{self.ticket}\" --resume {self.log_dir}")
                self.status = "needs_human_gate"
                self.save_checkpoint()
                sys.exit(2)

        return True

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
        """Save costs atomically using temp file + rename."""
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
        cost_file = self.log_dir / "costs.json"
        tmp_file = cost_file.with_suffix(".json.tmp")
        tmp_file.write_text(json.dumps(costs, indent=2))
        tmp_file.rename(cost_file)


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
    """Convert satisfaction score to verdict using config thresholds."""
    t_auto = get_config_int(_config, "THRESHOLD_AUTO_PASS", 90) / 100.0
    t_pass = get_config_int(_config, "THRESHOLD_PASS", 70) / 100.0
    t_iterate = get_config_int(_config, "THRESHOLD_ITERATE", 50) / 100.0
    if score >= t_auto:
        return "AUTO_PASS"
    elif score >= t_pass:
        return "PASS_WITH_NOTES"
    elif score >= t_iterate:
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


# --- Stagnation Detection ---

def check_stagnation(log_dir: Path, phase_name: str, attempt: int) -> bool:
    """Check if consecutive attempts produce identical/near-identical errors.
    Returns True if stagnation detected."""
    if attempt <= 1:
        return False

    prev = log_dir / f"{phase_name}-attempt-{attempt - 1}.json"
    curr = log_dir / f"{phase_name}-attempt-{attempt}.json"

    if not prev.exists() or not curr.exists():
        return False

    prev_text = prev.read_text()
    curr_text = curr.read_text()

    # Exact match check (checksum)
    if hashlib.md5(prev_text.encode()).hexdigest() == hashlib.md5(curr_text.encode()).hexdigest():
        print(f"  [WARN] Stagnation: attempt {attempt} output identical to attempt {attempt - 1}")
        return True

    # Similarity check using difflib
    similarity = difflib.SequenceMatcher(None, prev_text, curr_text).ratio()
    threshold = STAGNATION_SIMILARITY_THRESHOLD
    if similarity >= threshold:
        print(f"  [WARN] Stagnation: attempt {attempt} is {similarity:.0%} similar (threshold: {threshold:.0%})")
        return True

    return False


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


# --- Bias Check (Dual-Pass Review) ---

async def run_review_with_bias_check(
    state: PipelineState,
    review_name: str,
    prompt_base: str,
    model: str,
    max_turns: int = 20,
    max_budget_usd: float = 3.0,
) -> str:
    """Dual-pass review with position bias mitigation. Returns verdict."""
    # Standard tier: single-pass review (skip bias check for speed)
    resolved = state.resolved_tier or _config.get("PIPELINE_TIER", "full")
    if resolved in ("standard", "quick"):
        single = await run_phase(state, PhaseConfig(
            name=review_name,
            prompt=prompt_base,
            model=model,
            max_turns=max_turns,
            max_budget_usd=max_budget_usd,
        ))
        return single.verdict

    # Pass 1: normal order
    pass1 = await run_phase(state, PhaseConfig(
        name=f"{review_name}-pass1",
        prompt=prompt_base,
        model=model,
        max_turns=max_turns,
        max_budget_usd=max_budget_usd,
    ))

    # Pass 2: reversed section order + cross-model
    swapped_prompt = (
        prompt_base + "\n\nIMPORTANT: When evaluating sections, read them in "
        "REVERSE order (last section first). This reduces position bias."
    )
    pass2_model = MODELS["implement"] if model == MODELS["review"] else MODELS["review"]
    pass2 = await run_phase(state, PhaseConfig(
        name=f"{review_name}-pass2",
        prompt=swapped_prompt,
        model=pass2_model,
        max_turns=max_turns,
        max_budget_usd=max_budget_usd,
    ))

    v1, v2 = pass1.verdict, pass2.verdict

    # External validator pass (optional 3rd-party review)
    v_ext = ""
    ext_cmd = _config.get("REVIEW_VALIDATOR_COMMAND", "")
    if ext_cmd:
        try:
            pass1_file = state.log_dir / f"{review_name}-pass1.json"
            if pass1_file.exists():
                proc = subprocess.run(
                    ext_cmd, shell=True, input=pass1_file.read_text(),
                    capture_output=True, text=True, timeout=120,
                )
                v_ext = parse_verdict(proc.stdout)
                if v_ext != "UNKNOWN":
                    print(f"  External validator verdict: {v_ext}")
        except (subprocess.TimeoutExpired, Exception) as e:
            print(f"  [WARN] External validator failed: {e}")

    # Reconcile verdicts — strictest wins
    all_verdicts = [v for v in (v1, v2, v_ext) if v and v != "UNKNOWN"]
    if len(set(all_verdicts)) == 1:
        return all_verdicts[0]

    if v1 != v2:
        print(f"  [WARN] Position bias: pass1={v1}, pass2={v2}. Using stricter.")
    if v_ext and v_ext != "UNKNOWN" and v_ext != v1:
        print(f"  [WARN] External validator disagrees: ext={v_ext}")

    for strict in ("FAIL", "ITERATE", "NEEDS_HUMAN"):
        if strict in all_verdicts:
            return strict
    return v1


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
        "doc-review:AUTO_PASS": "write-specs",
        "doc-review:PASS_WITH_NOTES": "write-specs",
        "doc-review:PASS": "write-specs",
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
    progress: ProgressTracker | None = None,
) -> bool:
    """Implement a single step with retry loop. Returns True if verified."""
    if progress is None:
        progress = ProgressTracker()

    for attempt in range(1, MAX_VERIFY_RETRIES + 1):
        state.check_kill_switch()
        state.check_cost_ceiling()

        # Build error context from previous attempt (line-based truncation)
        error_context = ""
        if attempt > 1:
            prev_output = state.log_dir / f"verify-{step.id}-attempt-{attempt - 1}.json"
            if prev_output.exists():
                prev_data = json.loads(prev_output.read_text())
                prev_error_lines = prev_data.get("result", "").split("\n")[:50]
                prev_error = "\n".join(prev_error_lines)
                error_context = (
                    f"RETRY ATTEMPT {attempt}/{MAX_VERIFY_RETRIES}. "
                    f"Previous error:\n{prev_error}"
                )

            # Check for stagnation
            if check_stagnation(state.log_dir, f"verify-{step.id}", attempt):
                error_context += (
                    "\nSTAGNATION DETECTED: Previous fix attempts produce the same errors. "
                    "Try a fundamentally different approach."
                )

        # Determine BDD mode based on whether write-specs ran
        summaries_dir = _config.get('SUMMARIES_DIR', 'docs/summaries')
        specs_summary = Path(summaries_dir) / "write-specs-summary.md"
        if specs_summary.exists():
            bdd_prompt = (
                f"Executable specifications (tests) have already been written by a separate agent and are committed.\n"
                f"Read {specs_summary} to see what specs exist for this step.\n\n"
                f"Follow CONTRIBUTING_AGENT.md — GREEN + REFACTOR only:\n"
                f"1. GREEN: Write only the code required to make the existing failing specs pass. Follow existing codebase patterns. Type everything. Handle all errors.\n"
                f"2. REFACTOR: Clean up only while all specs remain green.\n"
                f"Do NOT modify test files unless a spec is demonstrably impossible to satisfy (e.g., tests a non-existent API). If you must change a spec, document why in your commit message."
            )
        else:
            bdd_prompt = (
                f"Follow CONTRIBUTING_AGENT.md:\n"
                f"1. RED: Write executable specifications (tests) for this step's behavior FIRST. Run them and confirm they fail.\n"
                f"2. GREEN: Write only the code required to make the specs pass. Follow existing codebase patterns. Type everything. Handle all errors.\n"
                f"3. REFACTOR: Clean up only while all specs remain green."
            )

        # Implement
        impl_timeout = get_phase_timeout(_config, f"implement-{step.id}")
        await run_phase(state, PhaseConfig(
            name=f"implement-{step.id}-attempt-{attempt}",
            prompt=(
                f"You are implementing step {step.id}: {step.title}\n\n"
                f"Read CLAUDE.md for rules. Read {summaries_dir}/documentation-summary.md for context.\n"
                f"Read the specific doc sections relevant to this step.\n\n"
                f"Description: {step.description}\n\n"
                f"{error_context}\n\n"
                f"{bdd_prompt}\n"
                f"After implementation, run the project's type checker and linter to verify your changes compile.\n"
                f"Commit your changes with message: 'feat({step.id}): {step.title}'"
            ),
            model=MODELS["implement"],
            max_turns=40,
            max_budget_usd=8.0,
            timeout_seconds=impl_timeout,
        ))

        # Check git progress using ProgressTracker
        if not progress.check(f"implement-{step.id}-attempt-{attempt}"):
            state.status = "stalled_no_progress"
            state.save_checkpoint()
            raise RuntimeError(f"No git progress for {progress.max_no_progress} consecutive attempts on {step.id}")

        # Verify (fast mode for early attempts, full suite for final)
        fast_mode = attempt < MAX_VERIFY_RETRIES
        test_instruction = (
            "Run scripts/agent-test.sh if it exists, otherwise run the project's test command"
            if fast_mode
            else "Run the FULL test suite (not sampled)"
        )

        verify_timeout = get_phase_timeout(_config, f"verify-{step.id}")
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
                timeout_seconds=verify_timeout,
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
    global MODELS, MAX_VERIFY_RETRIES, MAX_INTERROGATION_ITERATIONS
    global STAGNATION_SIMILARITY_THRESHOLD, PHASE_ORDER, _config

    ticket = sys.argv[1] if len(sys.argv) > 1 else "NO-TICKET"

    # --- Feature 5: Load config from pipeline.config.sh ---
    config_path = Path(__file__).parent / "pipeline.config.sh"
    _config = load_bash_config(config_path)

    # Override hardcoded defaults with config values
    MODELS = {
        "phase0": _config.get("MODEL_PHASE0", MODELS["phase0"]),
        "interrogate": _config.get("MODEL_INTERROGATE", MODELS["interrogate"]),
        "review": _config.get("MODEL_REVIEW", MODELS["review"]),
        "generate_docs": _config.get("MODEL_GENERATE_DOCS", MODELS["generate_docs"]),
        "implement": _config.get("MODEL_IMPLEMENT", MODELS["implement"]),
        "verify": _config.get("MODEL_VERIFY", MODELS["verify"]),
        "security": _config.get("MODEL_SECURITY", MODELS["security"]),
        "holdout_generate": _config.get("MODEL_HOLDOUT_GENERATE", MODELS["holdout_generate"]),
        "holdout_validate": _config.get("MODEL_HOLDOUT_VALIDATE", MODELS["holdout_validate"]),
        "write_specs": _config.get("MODEL_WRITE_SPECS", MODELS["write_specs"]),
        "ship": _config.get("MODEL_SHIP", MODELS["ship"]),
    }
    MAX_VERIFY_RETRIES = get_config_int(_config, "MAX_VERIFY_RETRIES", 3)
    MAX_INTERROGATION_ITERATIONS = get_config_int(_config, "MAX_INTERROGATION_ITERATIONS", 2)
    STAGNATION_SIMILARITY_THRESHOLD = get_config_float(_config, "STAGNATION_SIMILARITY_THRESHOLD", 90) / 100.0
    phase_order_str = _config.get("PHASE_ORDER", "")
    if phase_order_str:
        PHASE_ORDER = phase_order_str.split()
    max_cost = get_config_float(_config, "MAX_PIPELINE_COST", 50.0)

    state = PipelineState(
        ticket=ticket,
        max_cost=max_cost,
    )

    # --- Feature 3: Resume from checkpoint ---
    if len(sys.argv) > 2 and sys.argv[2] == "--resume" and len(sys.argv) > 3:
        resume_dir = Path(sys.argv[3])
        if (resume_dir / "checkpoint.json").exists():
            checkpoint = json.loads((resume_dir / "checkpoint.json").read_text())
            state.resume_phase = checkpoint.get("current_phase", "phase0")
            state.total_cost = checkpoint.get("total_cost", 0.0)
            state.log_dir = resume_dir
            print(f"Resuming from checkpoint: phase={state.resume_phase}, cost=${state.total_cost:.2f}")
        else:
            print(f"[ERROR] No checkpoint at {resume_dir}/checkpoint.json")
            sys.exit(1)

    # --- Feature 8: ProgressTracker ---
    progress = ProgressTracker(max_no_progress=get_config_int(_config, "MAX_NO_PROGRESS", 3))

    # --- Feature 9: ThreadManager ---
    threads = ThreadManager()

    print(f"Starting pipeline for: {ticket}")
    print(f"Max cost: ${state.max_cost:.2f}")
    print(f"Logs: {state.log_dir}")

    try:
        # ---- Stage 1: Context Scan ----
        if state.should_run_phase("phase0"):
            _tid = threads.get_or_create("phase0")
            await run_phase(state, PhaseConfig(
                name="phase0",
                prompt=(
                    "You are running the Interrogation Protocol pipeline autonomously. "
                    "Read CLAUDE.md first, then execute the phase0 context scan: scan git state, "
                    "check Memory MCP for prior pipeline state, identify project type, TODOs, test status, blockers. "
                    f"Write a phase0-summary.md to {_config.get('SUMMARIES_DIR', 'docs/summaries')}/.\n\n"
                    "After your scan, estimate the scope of the change on a 1-5 scale:\n"
                    "1 = trivial (typo, config change, <10 lines)\n"
                    "2 = small (single function/component, <50 lines)\n"
                    "3 = medium (multiple files, new feature, <200 lines)\n"
                    "4 = large (cross-cutting, new subsystem, <500 lines)\n"
                    "5 = massive (architectural change, >500 lines)\n"
                    "Output SCOPE: N (where N is 1-5) in your response.\n\n"
                    "Output must be under 20 lines."
                ),
                model=MODELS["phase0"],
                max_turns=15, max_budget_usd=2.0,
                timeout_seconds=get_phase_timeout(_config, "phase0"),
            ))

        # ---- Stage 2: Interrogation ----
        if state.should_run_phase("interrogate"):
            _tid = threads.get_or_create("interrogate")
            await run_phase(state, PhaseConfig(
                name="interrogate",
                prompt=(
                    f"Autonomous interrogation for ticket: {ticket}. AUTONOMOUS_MODE=true. "
                    f"Read CLAUDE.md, then {_config.get('SUMMARIES_DIR', 'docs/summaries')}/phase0-summary.md. "
                    "Execute the full interrogation protocol (all 13 sections). For each section: "
                    "1. Search MCP sources 2. Search codebase 3. Assume with [ASSUMPTION] tags if needed. "
                    f"Write transcript to {_config.get('ARTIFACTS_DIR', 'docs/artifacts')}/ and pyramid summary to {_config.get('SUMMARIES_DIR', 'docs/summaries')}/interrogation-summary.md."
                ),
                model=MODELS["interrogate"],
                max_turns=50, max_budget_usd=8.0,
                timeout_seconds=get_phase_timeout(_config, "interrogate"),
            ))

        # ---- Stage 3: Interrogation Review (LLM-as-Judge with Bias Check) ----
        if state.should_run_phase("interrogation-review"):
            _tid = threads.get_or_create("interrogation-review")
            interrogation_review_prompt = (
                "You are a REVIEWER agent. You did NOT write the interrogation output. "
                f"Read {_config.get('SUMMARIES_DIR', 'docs/summaries')}/interrogation-summary.md. Score each section 1-5. "
                "Calculate overall satisfaction as aggregate decimal. "
                "Output VERDICT: PASS|ITERATE|NEEDS_HUMAN as the last line."
            )
            review_verdict = await run_review_with_bias_check(
                state, "interrogation-review",
                prompt_base=interrogation_review_prompt,
                model=MODELS["review"],
            )
            # Create a PhaseResult to use for routing
            review = PhaseResult(name="interrogation-review", verdict=review_verdict)

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
                        f"Re-run interrogation addressing gaps in {_config.get('SUMMARIES_DIR', 'docs/summaries')}/interrogation-review.md. "
                        "Focus on sections that scored below 3. Update summaries."
                    ),
                    model=MODELS["interrogate"],
                    max_turns=50, max_budget_usd=8.0,
                    timeout_seconds=get_phase_timeout(_config, "interrogate"),
                ))

        # ---- Stage 4: Doc Generation (with Agent Teams detection) ----
        if state.should_run_phase("generate-docs"):
            _tid = threads.get_or_create("generate-docs")
            if has_agent_teams():
                await run_phase(state, PhaseConfig(
                    name="generate-docs-parallel",
                    prompt=(
                        "Run /parallel-docs to generate all documentation in parallel using Agent Teams."
                    ),
                    model=MODELS["generate_docs"],
                    max_turns=60, max_budget_usd=15.0,
                    timeout_seconds=get_phase_timeout(_config, "generate-docs"),
                ))
            else:
                # Adaptive template selection
                tmpl_dir = _config.get('TEMPLATES_DIR', 'docs/templates')
                tmpl_mode = _config.get('DOC_TEMPLATES_MODE', 'auto')
                if tmpl_mode == "minimal":
                    tmpl_instruction = f"Generate ONLY: PRD.md, IMPLEMENTATION_PLAN.md, TESTING_PLAN.md from {tmpl_dir}/. Skip all other templates."
                elif tmpl_mode == "all":
                    tmpl_instruction = f"Generate ALL documents from {tmpl_dir}/: PRD.md, APP_FLOW.md, TECH_STACK.md, DATA_MODELS.md, API_SPEC.md, FRONTEND_GUIDELINES.md, IMPLEMENTATION_PLAN.md, TESTING_PLAN.md, SECURITY_CHECKLIST.md, OBSERVABILITY.md, ROLLOUT_PLAN.md."
                else:
                    tmpl_instruction = f"Generate documents ADAPTIVELY from {tmpl_dir}/. ALWAYS: PRD.md, IMPLEMENTATION_PLAN.md, TESTING_PLAN.md. Generate others only if relevant to the project type. Skip templates that don't apply. Do not generate empty docs."

                await run_phase(state, PhaseConfig(
                    name="generate-docs",
                    prompt=(
                        f"Read CLAUDE.md and CONTRIBUTING_AGENT.md (process rules). "
                        f"Read {_config.get('SUMMARIES_DIR', 'docs/summaries')}/interrogation-summary.md for requirements. "
                        f"{tmpl_instruction} "
                        f"BDD REQUIREMENT: Every feature in PRD.md MUST include acceptance criteria in Given/When/Then (Gherkin) format. "
                        f"TESTING_PLAN.md MUST include executable specifications derived from these acceptance criteria. "
                        f"Write each to {_config.get('DOCS_DIR', 'docs')}/[name].md. After all docs: write {_config.get('SUMMARIES_DIR', 'docs/summaries')}/documentation-summary.md."
                    ),
                    model=MODELS["generate_docs"],
                    max_turns=50, max_budget_usd=10.0,
                    timeout_seconds=get_phase_timeout(_config, "generate-docs"),
                ))

        # ---- Stage 5: Doc Review (LLM-as-Judge with Bias Check) ----
        if state.should_run_phase("doc-review"):
            _tid = threads.get_or_create("doc-review")
            doc_review_prompt = (
                "You are a REVIEWER agent. Review generated docs for completeness. "
                "Spot-check docs/PRD.md, docs/IMPLEMENTATION_PLAN.md, docs/TESTING_PLAN.md. "
                "Score satisfaction as aggregate decimal. If >= 80%: VERDICT: PASS. "
                "If < 80%: VERDICT: ITERATE. Always include VERDICT as the last line."
            )
            doc_review_verdict = await run_review_with_bias_check(
                state, "doc-review",
                prompt_base=doc_review_prompt,
                model=MODELS["review"],
            )
            doc_review = PhaseResult(name="doc-review", verdict=doc_review_verdict)

            doc_next = route_from_gate("doc-review", doc_review.verdict)
            if doc_next == "generate-docs":
                await run_phase(state, PhaseConfig(
                    name="generate-docs-v2",
                    prompt="Re-generate docs addressing gaps from doc review. Focus on flagged sections.",
                    model=MODELS["generate_docs"],
                    max_turns=50, max_budget_usd=10.0,
                    timeout_seconds=get_phase_timeout(_config, "generate-docs"),
                ))

        # ---- Stage 5b: Write Executable Specifications (Cross-Model BDD) ----
        if state.should_run_phase("write-specs"):
            summaries_dir = _config.get("SUMMARIES_DIR", "docs/summaries")
            _tid = threads.get_or_create("write-specs")
            await run_phase(state, PhaseConfig(
                name="write-specs",
                prompt=(
                    "You are a SPECIFICATION WRITER. You will NOT implement any code.\n\n"
                    "Read CLAUDE.md and CONTRIBUTING_AGENT.md (process rules).\n"
                    "Read docs/PRD.md, docs/IMPLEMENTATION_PLAN.md, docs/TESTING_PLAN.md.\n\n"
                    "For each step in IMPLEMENTATION_PLAN.md:\n"
                    "1. Write executable test specifications (Given/When/Then from PRD acceptance criteria)\n"
                    "2. Write test files that encode these specifications\n"
                    "3. Run them to confirm they FAIL (RED phase of BDD)\n"
                    "4. Commit failing specs: 'test(spec): RED specs for [step]'\n\n"
                    "You must NOT write any implementation code. Only tests. Only RED.\n"
                    f"Write a summary to {summaries_dir}/write-specs-summary.md listing each spec file and what it tests."
                ),
                model=MODELS["write_specs"],
                max_turns=30, max_budget_usd=5.0,
                timeout_seconds=get_phase_timeout(_config, "write-specs"),
            ))

        # ---- Stage 5c: Holdout Generation ----
        holdouts_dir = Path(_config.get("HOLDOUTS_DIR", ".holdouts"))
        if state.should_run_phase("holdout-generate"):
            existing_holdouts = list(holdouts_dir.glob("holdout-001-*.md")) if holdouts_dir.exists() else []
            if not existing_holdouts:
                _tid = threads.get_or_create("holdout-generate")
                await run_phase(state, PhaseConfig(
                    name="holdout-generate",
                    prompt=(
                        "You are the HOLDOUT GENERATOR agent in COMPLETE ISOLATION from implementation. "
                        "Read docs/PRD.md, docs/APP_FLOW.md, docs/API_SPEC.md, docs/DATA_MODELS.md. "
                        f"Generate 8-12 adversarial test scenarios. Write each to {_config.get('HOLDOUTS_DIR', '.holdouts')}/holdout-NNN-[slug].md."
                    ),
                    model=MODELS["holdout_generate"],
                    max_turns=25, max_budget_usd=5.0,
                    timeout_seconds=get_phase_timeout(_config, "holdout-generate"),
                ))

        # ---- Stage 6: Implementation Loop ----
        if state.should_run_phase("implement"):
            steps = await extract_impl_steps(state, ticket)
            print(f"\nImplementation plan has {len(steps)} steps")

            for step in steps:
                _tid = threads.get_or_create(f"implement-{step.id}")
                print(f"\n--- Implementing: {step.id} - {step.title} ---")
                verified = await implement_and_verify(state, step, ticket, progress=progress)
                if not verified:
                    print(f"\n[ERROR] Step {step.id} blocked after {MAX_VERIFY_RETRIES} attempts")
                    sys.exit(3)

        # ---- Stage 7: Holdout Validation ----
        if state.should_run_phase("holdout-validate"):
            holdout_files = list(holdouts_dir.glob("holdout-*.md")) if holdouts_dir.exists() else []
            if holdout_files:
                _tid = threads.get_or_create("holdout-validate")
                holdout_result = await run_phase(state, PhaseConfig(
                    name="holdout-validate",
                    prompt=(
                        "You are a HOLDOUT VALIDATION agent. Test the implementation against hidden scenarios. "
                        f"Read each file in {_config.get('HOLDOUTS_DIR', '.holdouts')}/holdout-*.md. For each scenario: check preconditions, "
                        "walk through steps against actual code, evaluate acceptance criteria. "
                        "Score: (satisfied / total) as percentage. "
                        "If >= 80% and 0 anti-pattern flags: VERDICT: PASS. "
                        "If < 80%: VERDICT: FAIL. Always include VERDICT as last line."
                    ),
                    model=MODELS["holdout_validate"],
                    max_turns=25, max_budget_usd=5.0,
                    timeout_seconds=get_phase_timeout(_config, "holdout-validate"),
                ))

                holdout_next = route_from_gate("holdout-validate", holdout_result.verdict)
                if holdout_next == "implement":
                    state.status = "holdout_failed"
                    state.save_checkpoint()
                    print("\n[ERROR] Holdout validation failed")
                    sys.exit(4)

        # ---- Stage 8: Security Audit ----
        if state.should_run_phase("security-audit"):
            _tid = threads.get_or_create("security-audit")
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
                timeout_seconds=get_phase_timeout(_config, "security-audit"),
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
                    timeout_seconds=get_phase_timeout(_config, "implement"),
                ))

        # ---- Stage 9: Ship ----
        if state.should_run_phase("ship"):
            _tid = threads.get_or_create("ship")
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
                    f"- Body: built from {_config.get('SUMMARIES_DIR', 'docs/summaries')}/ (executive sections only)\n"
                    f"Push branch and create PR via gh CLI. Output the PR URL as the last line."
                ),
                model=MODELS["ship"],
                max_turns=20, max_budget_usd=5.0,
                timeout_seconds=get_phase_timeout(_config, "ship"),
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

        # Record pipeline outcome metrics
        metrics_file = Path(_config.get("METRICS_FILE", "docs/artifacts/pipeline-metrics.json"))
        metrics_file.parent.mkdir(parents=True, exist_ok=True)
        retry_count = sum(1 for p in state.phases if re.search(r'attempt-[2-9]', p.name))
        run_entry = {
            "ticket": ticket,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "tier": state.resolved_tier or _config.get("PIPELINE_TIER", "full"),
            "total_cost_usd": state.total_cost,
            "phases_run": len(state.phases),
            "retry_count": retry_count,
            "status": state.status,
            "log_dir": str(state.log_dir),
        }
        try:
            if metrics_file.exists():
                metrics = json.loads(metrics_file.read_text())
            else:
                metrics = {"runs": [], "total_runs": 0, "total_cost_usd": 0.0}
            metrics["runs"].append(run_entry)
            metrics["total_runs"] += 1
            metrics["total_cost_usd"] += state.total_cost
            tmp = metrics_file.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(metrics, indent=2))
            tmp.rename(metrics_file)
            print(f"  Metrics appended to: {metrics_file}")
        except Exception as e:
            print(f"  [WARN] Could not write metrics: {e}")


if __name__ == "__main__":
    asyncio.run(main())
