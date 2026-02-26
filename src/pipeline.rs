//! Pipeline orchestrator: runs phases in order with gates, retries, and routing.

use anyhow::{Context, Result};
use chrono::Utc;
use colored::Colorize;
use std::path::PathBuf;

use crate::config::PipelineConfig;
use crate::phase;
use crate::stagnation;
use crate::types::*;

/// Mutable pipeline state tracking costs, phases, and progress.
pub struct PipelineState {
    pub ticket: String,
    pub tier: Tier,
    pub log_dir: PathBuf,
    pub costs: CostFile,
    pub completed_phases: Vec<String>,
    pub total_cost: f64,
}

impl PipelineState {
    pub fn new(ticket: &str, config: &PipelineConfig) -> Result<Self> {
        let timestamp = Utc::now().format("%Y-%m-%d-%H%M").to_string();
        let log_dir = config.log_base_dir.join(&timestamp);
        std::fs::create_dir_all(&log_dir)
            .with_context(|| format!("creating log dir: {}", log_dir.display()))?;

        Ok(Self {
            ticket: ticket.to_string(),
            tier: config.tier,
            log_dir,
            costs: CostFile {
                phases: vec![],
                total_cost: 0.0,
                status: "running".to_string(),
                started: Utc::now().to_rfc3339(),
            },
            completed_phases: vec![],
            total_cost: 0.0,
        })
    }

    pub fn record_phase(&mut self, result: &PhaseResult) {
        self.total_cost += result.cost_usd;
        self.costs.total_cost = self.total_cost;
        self.costs.phases.push(PhaseCost {
            name: result.name.clone(),
            cost: result.cost_usd,
            session_id: result.session_id.clone(),
            turns: result.turns,
        });
        self.completed_phases.push(result.name.clone());
    }

    pub fn save_costs(&self) -> Result<()> {
        let path = self.log_dir.join("costs.json");
        let json = serde_json::to_string_pretty(&self.costs)?;
        std::fs::write(&path, json)?;
        Ok(())
    }

    pub fn save_checkpoint(&self, current_phase: &str) -> Result<()> {
        let cp = Checkpoint {
            status: self.costs.status.clone(),
            current_phase: current_phase.to_string(),
            ticket: self.ticket.clone(),
            total_cost: self.total_cost,
            timestamp: Utc::now(),
            log_dir: self.log_dir.clone(),
            completed_phases: self.completed_phases.clone(),
            tier: self.tier.to_string(),
        };
        let path = self.log_dir.join("checkpoint.json");
        let json = serde_json::to_string_pretty(&cp)?;
        std::fs::write(&path, json)?;
        Ok(())
    }

    /// Check if a phase should run based on current tier.
    pub fn should_run(&self, phase: &Phase) -> bool {
        let skipped = Phase::skipped_by(self.tier);
        !skipped.contains(phase)
    }
}

/// Build a PhaseConfig for a given phase.
fn make_phase_config(
    config: &PipelineConfig,
    _state: &PipelineState,
    phase: Phase,
    prompt: &str,
) -> PhaseConfig {
    let name = phase.as_str().to_string();
    let model = config.models.get_model(&name).to_string();

    let (max_turns, max_budget) = match phase {
        Phase::Phase0 => (config.turns_quick, config.budget_low),
        Phase::Interrogate | Phase::GenerateDocs | Phase::WriteSpecs => {
            (config.turns_medium, config.budget_medium)
        }
        Phase::InterrogationReview | Phase::DocReview | Phase::Verify => {
            (config.turns_medium, config.budget_medium)
        }
        Phase::HoldoutGenerate | Phase::HoldoutValidate => {
            (config.turns_medium, config.budget_medium)
        }
        Phase::Implement => (config.turns_long, config.budget_high),
        Phase::SecurityAudit => (config.turns_medium, config.budget_medium),
        Phase::Ship => (config.turns_quick, config.budget_low),
    };

    let timeout_secs = config
        .phase_timeouts
        .get(phase.as_str())
        .copied()
        .unwrap_or(match phase {
            Phase::Implement => 600,
            Phase::Interrogate | Phase::GenerateDocs | Phase::WriteSpecs => 300,
            _ => 180,
        });

    PhaseConfig {
        name,
        prompt: prompt.to_string(),
        model,
        max_turns,
        max_budget_usd: max_budget,
        timeout_secs,
        permission_mode: "bypassPermissions".to_string(),
    }
}

/// Run the full pipeline.
pub async fn run(config: &PipelineConfig, ticket: &str) -> Result<i32> {
    let mut state = PipelineState::new(ticket, config)?;

    println!(
        "{} v{} — Pipeline Runner",
        "Anvil".bold().cyan(),
        config.anvil_version
    );
    println!("  Ticket: {}", ticket);
    println!("  Tier:   {}", state.tier);
    println!("  Logs:   {}", state.log_dir.display());
    println!();

    state.save_checkpoint("starting")?;

    // Phase 0: Context scan
    if state.should_run(&Phase::Phase0) {
        let result = run_single_phase(
            config,
            &mut state,
            Phase::Phase0,
            &format!(
                "You are an autonomous pipeline agent. Read CLAUDE.md and CONTRIBUTING_AGENT.md.\n\
            Scan the project: git status, project type, test status, blockers.\n\
            Ticket: {ticket}\n\
            Output a JSON object with: scope (1-5), project_type, blockers[], test_status."
            ),
        )
        .await?;

        // Resolve auto tier from phase0 scope output
        if state.tier == Tier::Auto {
            state.tier = resolve_tier_from_output(&result);
            println!("  Auto-detected tier: {}", state.tier);
        }
    }

    // Interrogation
    if state.should_run(&Phase::Interrogate) {
        let result = run_single_phase(
            config,
            &mut state,
            Phase::Interrogate,
            &format!(
                "You are an autonomous pipeline agent in AUTONOMOUS mode. Read CLAUDE.md.\n\
            Interrogate requirements for this ticket:\n{ticket}\n\n\
            Search the codebase for context. For each unknown, make an [ASSUMPTION: rationale] \
            with confidence HIGH/MEDIUM/LOW. Write findings to docs/artifacts/.\n\
            If critical unknowns cannot be resolved (auth model, compliance, data retention), \
            output VERDICT: NEEDS_HUMAN with a list of questions."
            ),
        )
        .await?;

        if parse_verdict_from_output(&result) == Verdict::NeedsHuman {
            eprintln!(
                "{}",
                "Needs human: critical unknowns require manual input".red().bold()
            );
            state.costs.status = "needs_human".to_string();
            state.save_costs()?;
            return Ok(2);
        }
    }

    // Write specs (BDD)
    if state.should_run(&Phase::WriteSpecs) {
        run_single_phase(
            config,
            &mut state,
            Phase::WriteSpecs,
            &format!(
                "You are an autonomous pipeline agent. Read CLAUDE.md and CONTRIBUTING_AGENT.md.\n\
            Write executable BDD specifications (pytest) for this ticket:\n{ticket}\n\n\
            Write FAILING tests first. Do NOT implement the fix yet. \
            Tests must cover all acceptance criteria including edge cases.\n\
            Read existing test files and match their patterns exactly."
            ),
        )
        .await?;
    }

    // Holdout generation
    if state.should_run(&Phase::HoldoutGenerate) {
        run_single_phase(
            config,
            &mut state,
            Phase::HoldoutGenerate,
            &format!(
                "You are an autonomous pipeline agent. Read CLAUDE.md.\n\
            Generate adversarial holdout test scenarios for this ticket:\n{ticket}\n\n\
            Think of edge cases the implementer might miss. Write hidden test scenarios to \
            docs/artifacts/holdout-scenarios.md. These will be used AFTER implementation to \
            validate completeness. Focus on: boundary conditions, error paths, partial failures, \
            race conditions, and cross-module interactions."
            ),
        )
        .await?;
    }

    // Implementation + verification loop
    if state.should_run(&Phase::Implement) {
        let max_retries = config.max_verify_retries;
        let mut passed = false;

        for attempt in 1..=max_retries {
            phase::preflight_check(config, state.total_cost)?;

            let stagnation_note = if stagnation::check_stagnation(
                &state.log_dir,
                "verify",
                attempt,
                config.stagnation_similarity,
            ) {
                "\n\nSTAGNATION DETECTED: Previous attempts produced similar errors. \
                 Try a fundamentally different approach."
            } else {
                ""
            };

            let impl_name = format!("implement-attempt-{attempt}");
            let impl_phase = make_phase_config(
                config,
                &state,
                Phase::Implement,
                &format!(
                    "You are an autonomous pipeline agent. Read CLAUDE.md and CONTRIBUTING_AGENT.md.\n\
                    Implement this ticket:\n{ticket}\n\n\
                    Read the existing codebase first. Make the failing tests pass. \
                    Run all tests and verify they pass before finishing.\n\
                    Attempt {attempt}/{max_retries}.{stagnation_note}"
                ),
            );
            let mut pc = impl_phase;
            pc.name = impl_name;
            let result = phase::run_phase(config, &pc, &state.log_dir).await?;

            print_phase_result(&result);
            state.record_phase(&result);
            state.save_costs()?;
            state.save_checkpoint(&pc.name)?;

            // Verify
            let verify_name = format!("verify-attempt-{attempt}");
            let verify_phase = make_phase_config(
                config,
                &state,
                Phase::Verify,
                &format!(
                    "You are an autonomous pipeline agent. Read CLAUDE.md.\n\
                    Verify the implementation for:\n{ticket}\n\n\
                    Run ALL tests: `python -m pytest tests/ -v`\n\
                    Check: all tests pass, no regressions, acceptance criteria met.\n\
                    Output VERDICT: PASS, FAIL, or ITERATE with a satisfaction score 0.0-1.0."
                ),
            );
            let mut vc = verify_phase;
            vc.name = verify_name;
            let verify_result = phase::run_phase(config, &vc, &state.log_dir).await?;

            print_phase_result(&verify_result);
            state.record_phase(&verify_result);
            state.save_costs()?;

            if !verify_result.is_error && parse_verdict_from_output(&verify_result).is_pass() {
                passed = true;
                break;
            }

            if attempt == max_retries {
                eprintln!("{}", "Blocked: max retries reached".red().bold());
                state.costs.status = "blocked".to_string();
                state.save_costs()?;
                return Ok(3);
            }
        }

        if !passed {
            state.costs.status = "blocked".to_string();
            state.save_costs()?;
            return Ok(3);
        }
    }

    // Holdout validation
    if state.should_run(&Phase::HoldoutValidate) {
        let result = run_single_phase(
            config,
            &mut state,
            Phase::HoldoutValidate,
            "You are an autonomous pipeline agent. Read CLAUDE.md.\n\
            Validate the implementation against holdout scenarios.\n\
            Read docs/artifacts/holdout-scenarios.md and verify each scenario is satisfied.\n\
            Run all tests. Check edge cases described in the holdout scenarios.\n\
            Output VERDICT: PASS or FAIL with a satisfaction score 0.0-1.0.",
        )
        .await?;

        if result.is_error || !parse_verdict_from_output(&result).is_pass() {
            eprintln!("{}", "Holdout validation failed".red().bold());
            state.costs.status = "holdout_failed".to_string();
            state.save_costs()?;
            return Ok(4);
        }
    }

    // Security audit
    if state.should_run(&Phase::SecurityAudit) {
        run_single_phase(
            config,
            &mut state,
            Phase::SecurityAudit,
            &format!(
                "You are an autonomous pipeline agent. Read CLAUDE.md.\n\
            Security audit for:\n{ticket}\n\n\
            Check for: injection vulnerabilities, hardcoded secrets, unsafe deserialization, \
            missing input validation, and OWASP top 10. Fix any issues found."
            ),
        )
        .await?;
    }

    // Ship
    if state.should_run(&Phase::Ship) {
        run_single_phase(
            config,
            &mut state,
            Phase::Ship,
            &format!(
                "You are an autonomous pipeline agent. Read CLAUDE.md.\n\
            Finalize and ship:\n{ticket}\n\n\
            Verify all tests pass. Create a git commit with a descriptive message. \
            If gh is available, create a PR."
            ),
        )
        .await?;
    }

    // Done
    state.costs.status = "completed".to_string();
    state.save_costs()?;
    state.save_checkpoint("completed")?;

    println!();
    println!("{}", "Pipeline complete".green().bold());
    print_cost_summary(&state);

    Ok(0)
}

async fn run_single_phase(
    config: &PipelineConfig,
    state: &mut PipelineState,
    phase: Phase,
    prompt: &str,
) -> Result<PhaseResult> {
    phase::preflight_check(config, state.total_cost)?;

    let phase_name = phase.as_str();
    println!("{}", format!("========== {phase_name} ==========").bold());

    state.save_checkpoint(phase_name)?;
    let pc = make_phase_config(config, state, phase, prompt);
    let result = phase::run_phase(config, &pc, &state.log_dir).await?;

    print_phase_result(&result);
    state.record_phase(&result);
    state.save_costs()?;

    Ok(result)
}

fn print_phase_result(result: &PhaseResult) {
    let status = if result.is_error {
        "FAIL".red().bold()
    } else {
        "OK".green().bold()
    };
    let watchdog = if result.watchdog_restarts > 0 {
        format!(" (watchdog: {} restarts)", result.watchdog_restarts)
    } else {
        String::new()
    };
    println!(
        "  [{status}] {} | ${:.2} | {}t | {:.0}s{watchdog}",
        result.name, result.cost_usd, result.turns, result.duration_secs
    );
}

fn print_cost_summary(state: &PipelineState) {
    println!("  Total cost: ${:.2}", state.total_cost);
    println!("  Phases: {}", state.completed_phases.len());
    println!("  Logs: {}", state.log_dir.display());
}

fn resolve_tier_from_output(result: &PhaseResult) -> Tier {
    let text = result.output.as_deref().unwrap_or("");
    // Look for scope in JSON output
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(text) {
        if let Some(scope) = val.get("scope").and_then(|s| s.as_u64()) {
            return match scope {
                1 => Tier::Nano,
                2 => Tier::Quick,
                3 => Tier::Lite,
                4 => Tier::Standard,
                5 => Tier::Full,
                _ => Tier::Lite,
            };
        }
    }
    // Fallback: search for scope pattern in text
    let re = regex::Regex::new(r"(?i)scope[:\s]*(\d)").unwrap();
    if let Some(cap) = re.captures(text) {
        if let Ok(scope) = cap[1].parse::<u32>() {
            return match scope {
                1 => Tier::Nano,
                2 => Tier::Quick,
                3 => Tier::Lite,
                4 => Tier::Standard,
                5 => Tier::Full,
                _ => Tier::Lite,
            };
        }
    }
    Tier::Lite // safe default
}

fn parse_verdict_from_output(result: &PhaseResult) -> Verdict {
    let text = result.output.as_deref().unwrap_or("");
    let upper = text.to_uppercase();
    if upper.contains("VERDICT: PASS") || upper.contains("VERDICT:PASS") {
        Verdict::Pass
    } else if upper.contains("VERDICT: FAIL") {
        Verdict::Fail
    } else if upper.contains("VERDICT: ITERATE") {
        Verdict::Iterate
    } else if upper.contains("NEEDS_HUMAN") || upper.contains("NEEDS HUMAN") {
        Verdict::NeedsHuman
    } else {
        // No explicit verdict — check for test results
        if upper.contains("ALL TESTS PASS") || upper.contains("TESTS PASSED") {
            Verdict::Pass
        } else {
            Verdict::Unknown
        }
    }
}
