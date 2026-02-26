use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;
use std::path::PathBuf;

/// Pipeline tier — determines which phases run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    Guard,
    Nano,
    Quick,
    Lite,
    Standard,
    Full,
    Auto,
}

impl fmt::Display for Tier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Tier::Guard => write!(f, "guard"),
            Tier::Nano => write!(f, "nano"),
            Tier::Quick => write!(f, "quick"),
            Tier::Lite => write!(f, "lite"),
            Tier::Standard => write!(f, "standard"),
            Tier::Full => write!(f, "full"),
            Tier::Auto => write!(f, "auto"),
        }
    }
}

impl std::str::FromStr for Tier {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "guard" => Ok(Tier::Guard),
            "nano" => Ok(Tier::Nano),
            "quick" => Ok(Tier::Quick),
            "lite" => Ok(Tier::Lite),
            "standard" => Ok(Tier::Standard),
            "full" => Ok(Tier::Full),
            "auto" => Ok(Tier::Auto),
            _ => Err(format!("unknown tier: {s}")),
        }
    }
}

/// Canonical phase names.
#[derive(Debug, Clone, Hash, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Phase {
    Phase0,
    Interrogate,
    InterrogationReview,
    GenerateDocs,
    DocReview,
    WriteSpecs,
    HoldoutGenerate,
    Implement,
    Verify,
    HoldoutValidate,
    SecurityAudit,
    Ship,
}

impl Phase {
    pub fn as_str(&self) -> &'static str {
        match self {
            Phase::Phase0 => "phase0",
            Phase::Interrogate => "interrogate",
            Phase::InterrogationReview => "interrogation-review",
            Phase::GenerateDocs => "generate-docs",
            Phase::DocReview => "doc-review",
            Phase::WriteSpecs => "write-specs",
            Phase::HoldoutGenerate => "holdout-generate",
            Phase::Implement => "implement",
            Phase::Verify => "verify",
            Phase::HoldoutValidate => "holdout-validate",
            Phase::SecurityAudit => "security-audit",
            Phase::Ship => "ship",
        }
    }

    /// Which phases each tier skips.
    pub fn skipped_by(tier: Tier) -> Vec<Phase> {
        match tier {
            Tier::Guard => vec![
                Phase::Interrogate,
                Phase::InterrogationReview,
                Phase::GenerateDocs,
                Phase::DocReview,
                Phase::WriteSpecs,
                Phase::HoldoutGenerate,
                Phase::Implement,
                Phase::Verify,
                Phase::HoldoutValidate,
            ],
            Tier::Nano => vec![
                Phase::Interrogate,
                Phase::InterrogationReview,
                Phase::GenerateDocs,
                Phase::DocReview,
                Phase::WriteSpecs,
                Phase::HoldoutGenerate,
                Phase::HoldoutValidate,
                Phase::SecurityAudit,
            ],
            Tier::Quick => vec![
                Phase::InterrogationReview,
                Phase::GenerateDocs,
                Phase::DocReview,
                Phase::HoldoutGenerate,
                Phase::HoldoutValidate,
                Phase::SecurityAudit,
            ],
            Tier::Lite => vec![
                Phase::InterrogationReview,
                Phase::GenerateDocs,
                Phase::DocReview,
                Phase::SecurityAudit,
            ],
            Tier::Standard => vec![Phase::SecurityAudit],
            Tier::Full | Tier::Auto => vec![],
        }
    }
}

impl fmt::Display for Phase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

/// Verdict from a review/gate phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Verdict {
    Pass,
    AutoPass,
    PassWithNotes,
    Iterate,
    NeedsHuman,
    Block,
    Fail,
    Timeout,
    Unknown,
}

impl Verdict {
    pub fn is_pass(self) -> bool {
        matches!(
            self,
            Verdict::Pass | Verdict::AutoPass | Verdict::PassWithNotes
        )
    }
}

/// JSON output from `claude -p --output-format json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ClaudeOutput {
    pub result: Option<String>,
    #[serde(default)]
    pub total_cost_usd: Option<f64>,
    pub session_id: Option<String>,
    #[serde(default)]
    pub is_error: Option<bool>,
    pub num_turns: Option<u32>,
}

/// Configuration for running a single phase.
#[derive(Debug, Clone)]
pub struct PhaseConfig {
    pub name: String,
    pub prompt: String,
    pub model: String,
    pub max_turns: u32,
    pub max_budget_usd: f64,
    pub timeout_secs: u64,
    pub permission_mode: String,
}

/// Result from executing a single phase.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhaseResult {
    pub name: String,
    pub cost_usd: f64,
    pub turns: u32,
    pub session_id: String,
    pub duration_secs: f64,
    pub exit_code: i32,
    pub is_error: bool,
    pub output: Option<String>,
    pub watchdog_triggered: bool,
    pub watchdog_restarts: u32,
}

/// Cost record for a phase (written to costs.json).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhaseCost {
    pub name: String,
    pub cost: f64,
    pub session_id: String,
    pub turns: u32,
}

/// Full cost tracking file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CostFile {
    pub phases: Vec<PhaseCost>,
    pub total_cost: f64,
    pub status: String,
    pub started: String,
}

/// Checkpoint for pipeline resume.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Checkpoint {
    pub status: String,
    pub current_phase: String,
    pub ticket: String,
    pub total_cost: f64,
    pub timestamp: DateTime<Utc>,
    pub log_dir: PathBuf,
    pub completed_phases: Vec<String>,
    pub tier: String,
}

/// Model stylesheet loaded from anvil.toml [models] section (or legacy pipeline.models.json).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelStylesheet {
    pub default: String,
    pub overrides: HashMap<String, String>,
    #[serde(default)]
    pub cost_weights: HashMap<String, f64>,
}

impl ModelStylesheet {
    /// Map a phase name to its assigned model.
    pub fn get_model(&self, phase: &str) -> &str {
        let key = match phase {
            "phase0" => "routing",
            "interrogate" => "generation",
            "interrogation-review" | "doc-review" => "review",
            s if s.starts_with("verify") => "review",
            "ship" => "review",
            s if s.starts_with("implement") => "implementation",
            "generate-docs" => "generation",
            "security-audit" => "security",
            "holdout-generate" => "holdout_generate",
            "holdout-validate" => "holdout_validate",
            "write-specs" => "specification",
            _ => return &self.default,
        };
        self.overrides.get(key).unwrap_or(&self.default)
    }
}

/// Outcome from the watchdog-monitored subprocess.
#[derive(Debug)]
pub struct WatchdogOutcome {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_code: i32,
    pub timed_out: bool,
    pub watchdog_killed: bool,
    pub watchdog_restarts: u32,
}
