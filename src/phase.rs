//! Phase execution: spawns Claude CLI with watchdog monitoring.

use anyhow::{Context, Result};
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::process::Command;

use crate::config::PipelineConfig;
use crate::types::{ClaudeOutput, PhaseConfig, PhaseResult};
use crate::watchdog;

const AUTONOMOUS_AUGMENT: &str = "\n\nCRITICAL AUTONOMOUS MODE:\n\
    You are running in a fully automated pipeline with NO human operator.\n\
    NEVER wait for user input, confirmation, or interactive prompts.\n\
    If you need information, search the codebase or make an [ASSUMPTION].\n\
    Complete your task and output results immediately.";

/// Run a single pipeline phase via `claude -p`.
pub async fn run_phase(
    config: &PipelineConfig,
    phase: &PhaseConfig,
    log_dir: &Path,
) -> Result<PhaseResult> {
    let start = Instant::now();

    let phase_timeout = Duration::from_secs(
        config
            .phase_timeouts
            .get(&phase.name)
            .copied()
            .unwrap_or(phase.timeout_secs),
    );
    let inactivity_timeout = Duration::from_secs(config.interaction_timeout_secs);

    // Track watchdog restarts so the prompt can be augmented
    let restart_count = Arc::new(AtomicU32::new(0));
    let prompt = phase.prompt.clone();
    let model = phase.model.clone();
    let max_turns = phase.max_turns;
    let max_budget = phase.max_budget_usd;
    let perm_mode = phase.permission_mode.clone();
    let agent_cmd = config.agent_command.clone();
    let rc = restart_count.clone();

    let cmd_builder = move || {
        let restarts = rc.load(Ordering::SeqCst);
        let effective_prompt = if restarts > 0 {
            format!("{}{}", prompt, AUTONOMOUS_AUGMENT)
        } else {
            prompt.clone()
        };

        let mut cmd = Command::new(&agent_cmd);
        cmd.arg("-p")
            .arg(&effective_prompt)
            .arg("--output-format")
            .arg("json")
            .arg("--max-turns")
            .arg(max_turns.to_string())
            .arg("--max-budget-usd")
            .arg(format!("{:.2}", max_budget))
            .arg("--permission-mode")
            .arg(&perm_mode)
            .arg("--model")
            .arg(&model);
        cmd
    };

    let outcome = watchdog::run_with_watchdog(
        cmd_builder,
        phase_timeout,
        inactivity_timeout,
        config.interaction_max_retries,
    )
    .await
    .with_context(|| format!("running phase {}", phase.name))?;

    let duration = start.elapsed();

    // Write raw output to log files
    let stdout_path = log_dir.join(format!("{}.json", phase.name));
    let stderr_path = log_dir.join(format!("{}.stderr", phase.name));
    std::fs::write(&stdout_path, &outcome.stdout)?;
    std::fs::write(&stderr_path, &outcome.stderr)?;

    // Parse Claude's JSON output
    let claude_out: ClaudeOutput = serde_json::from_slice(&outcome.stdout).unwrap_or_default();

    let result = PhaseResult {
        name: phase.name.clone(),
        cost_usd: claude_out.total_cost_usd.unwrap_or(0.0),
        turns: claude_out.num_turns.unwrap_or(0),
        session_id: claude_out.session_id.unwrap_or_default(),
        duration_secs: duration.as_secs_f64(),
        exit_code: outcome.exit_code,
        is_error: outcome.timed_out || outcome.watchdog_killed || claude_out.is_error == Some(true),
        output: claude_out.result,
        watchdog_triggered: outcome.watchdog_killed,
        watchdog_restarts: outcome.watchdog_restarts,
    };

    Ok(result)
}

/// Check if the pipeline should stop (kill switch or cost ceiling).
pub fn preflight_check(config: &PipelineConfig, total_cost: f64) -> Result<()> {
    if config.kill_switch_file.exists() {
        anyhow::bail!("Kill switch active: {}", config.kill_switch_file.display());
    }
    if total_cost >= config.max_pipeline_cost {
        anyhow::bail!(
            "Cost ceiling reached: ${:.2} >= ${:.2}",
            total_cost,
            config.max_pipeline_cost
        );
    }
    Ok(())
}
