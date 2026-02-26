use crate::types::{ModelStylesheet, Tier};
use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Full pipeline configuration, merged from file + env + CLI.
#[derive(Debug, Clone)]
pub struct PipelineConfig {
    pub anvil_version: String,
    pub tier: Tier,
    pub max_pipeline_cost: f64,
    pub max_verify_retries: u32,
    pub agent_command: String,

    // Turn limits by category
    pub turns_quick: u32,
    pub turns_medium: u32,
    pub turns_long: u32,

    // Budget limits by category
    pub budget_low: f64,
    pub budget_medium: f64,
    pub budget_high: f64,

    // Quality thresholds (0.0-1.0)
    pub threshold_auto_pass: f64,
    pub threshold_pass: f64,
    pub threshold_iterate: f64,
    pub threshold_holdout: f64,

    // Validator
    pub review_validator_command: Option<String>,

    // Watchdog
    pub interaction_timeout_secs: u64,
    pub interaction_max_retries: u32,

    // Stagnation
    pub stagnation_similarity: f64,

    // Paths
    pub log_base_dir: PathBuf,
    pub kill_switch_file: PathBuf,

    // Per-phase timeout overrides
    pub phase_timeouts: HashMap<String, u64>,

    // Models
    pub models: ModelStylesheet,
}

impl Default for PipelineConfig {
    fn default() -> Self {
        Self {
            anvil_version: "4.0.0".to_string(),
            tier: Tier::Auto,
            max_pipeline_cost: 50.0,
            max_verify_retries: 3,
            agent_command: "claude".to_string(),
            turns_quick: 15,
            turns_medium: 30,
            turns_long: 50,
            budget_low: 3.0,
            budget_medium: 5.0,
            budget_high: 10.0,
            threshold_auto_pass: 0.95,
            threshold_pass: 0.80,
            threshold_iterate: 0.60,
            threshold_holdout: 0.80,
            review_validator_command: Some("./scripts/review-validator.sh".to_string()),
            interaction_timeout_secs: 120,
            interaction_max_retries: 2,
            stagnation_similarity: 0.90,
            log_base_dir: PathBuf::from("docs/artifacts/pipeline-runs"),
            kill_switch_file: PathBuf::from(".pipeline-kill"),
            phase_timeouts: HashMap::new(),
            models: ModelStylesheet {
                default: "sonnet".to_string(),
                overrides: HashMap::new(),
                cost_weights: HashMap::new(),
            },
        }
    }
}

// ---------------------------------------------------------------------------
// TOML config structures (deserialized from anvil.toml)
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct TomlConfig {
    anvil: Option<TomlAnvil>,
    turns: Option<TomlTurns>,
    budget: Option<TomlBudget>,
    quality: Option<TomlQuality>,
    watchdog: Option<TomlWatchdog>,
    paths: Option<TomlPaths>,
    models: Option<TomlModels>,
    timeouts: Option<TomlTimeouts>,
}

#[derive(Debug, Deserialize)]
struct TomlAnvil {
    version: Option<String>,
    tier: Option<String>,
    agent_command: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TomlTurns {
    quick: Option<u32>,
    medium: Option<u32>,
    long: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct TomlBudget {
    max_pipeline_cost: Option<f64>,
    low: Option<f64>,
    medium: Option<f64>,
    high: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct TomlQuality {
    max_verify_retries: Option<u32>,
    threshold_auto_pass: Option<f64>,
    threshold_pass: Option<f64>,
    threshold_iterate: Option<f64>,
    threshold_holdout: Option<f64>,
    validator: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TomlWatchdog {
    inactivity_timeout: Option<u64>,
    max_restarts: Option<u32>,
    stagnation_similarity: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct TomlPaths {
    log_base_dir: Option<String>,
    kill_switch_file: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TomlModels {
    default: Option<String>,
    roles: Option<HashMap<String, String>>,
    cost_weights: Option<HashMap<String, f64>>,
}

#[derive(Debug, Deserialize)]
struct TomlTimeouts {
    #[allow(dead_code)]
    default: Option<u64>,
    #[serde(flatten)]
    phases: HashMap<String, toml::Value>,
}

// ---------------------------------------------------------------------------
// TOML loader
// ---------------------------------------------------------------------------

/// Load configuration from anvil.toml.
pub fn load_toml_config(path: &Path) -> Result<PipelineConfig> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("reading config: {}", path.display()))?;
    let toml_cfg: TomlConfig =
        toml::from_str(&content).with_context(|| format!("parsing {}", path.display()))?;

    let defaults = PipelineConfig::default();

    let anvil = toml_cfg.anvil.unwrap_or(TomlAnvil {
        version: None,
        tier: None,
        agent_command: None,
    });

    let turns = toml_cfg.turns.unwrap_or(TomlTurns {
        quick: None,
        medium: None,
        long: None,
    });

    let budget = toml_cfg.budget.unwrap_or(TomlBudget {
        max_pipeline_cost: None,
        low: None,
        medium: None,
        high: None,
    });

    let quality = toml_cfg.quality.unwrap_or(TomlQuality {
        max_verify_retries: None,
        threshold_auto_pass: None,
        threshold_pass: None,
        threshold_iterate: None,
        threshold_holdout: None,
        validator: None,
    });

    let watchdog = toml_cfg.watchdog.unwrap_or(TomlWatchdog {
        inactivity_timeout: None,
        max_restarts: None,
        stagnation_similarity: None,
    });

    let paths = toml_cfg.paths.unwrap_or(TomlPaths {
        log_base_dir: None,
        kill_switch_file: None,
    });

    let models_section = toml_cfg.models.unwrap_or(TomlModels {
        default: None,
        roles: None,
        cost_weights: None,
    });

    let tier = anvil
        .tier
        .and_then(|s| s.parse::<Tier>().ok())
        .unwrap_or(defaults.tier);

    let models = ModelStylesheet {
        default: models_section
            .default
            .unwrap_or_else(|| defaults.models.default.clone()),
        overrides: models_section.roles.unwrap_or_default(),
        cost_weights: models_section.cost_weights.unwrap_or_default(),
    };

    // Per-phase timeouts: collect all keys except "default" from [timeouts]
    let mut phase_timeouts = HashMap::new();
    if let Some(ref timeouts) = toml_cfg.timeouts {
        for (key, val) in &timeouts.phases {
            if key == "default" {
                continue;
            }
            if let Some(secs) = val.as_integer() {
                phase_timeouts.insert(key.replace('_', "-"), secs as u64);
            }
        }
    }

    Ok(PipelineConfig {
        anvil_version: anvil
            .version
            .unwrap_or_else(|| defaults.anvil_version.clone()),
        tier,
        max_pipeline_cost: budget
            .max_pipeline_cost
            .unwrap_or(defaults.max_pipeline_cost),
        max_verify_retries: quality
            .max_verify_retries
            .unwrap_or(defaults.max_verify_retries),
        agent_command: anvil
            .agent_command
            .unwrap_or_else(|| defaults.agent_command.clone()),
        turns_quick: turns.quick.unwrap_or(defaults.turns_quick),
        turns_medium: turns.medium.unwrap_or(defaults.turns_medium),
        turns_long: turns.long.unwrap_or(defaults.turns_long),
        budget_low: budget.low.unwrap_or(defaults.budget_low),
        budget_medium: budget.medium.unwrap_or(defaults.budget_medium),
        budget_high: budget.high.unwrap_or(defaults.budget_high),
        threshold_auto_pass: quality
            .threshold_auto_pass
            .unwrap_or(defaults.threshold_auto_pass),
        threshold_pass: quality.threshold_pass.unwrap_or(defaults.threshold_pass),
        threshold_iterate: quality
            .threshold_iterate
            .unwrap_or(defaults.threshold_iterate),
        threshold_holdout: quality
            .threshold_holdout
            .unwrap_or(defaults.threshold_holdout),
        review_validator_command: quality.validator.or(defaults.review_validator_command),
        interaction_timeout_secs: watchdog
            .inactivity_timeout
            .unwrap_or(defaults.interaction_timeout_secs),
        interaction_max_retries: watchdog
            .max_restarts
            .unwrap_or(defaults.interaction_max_retries),
        stagnation_similarity: watchdog
            .stagnation_similarity
            .unwrap_or(defaults.stagnation_similarity),
        log_base_dir: paths
            .log_base_dir
            .map(PathBuf::from)
            .unwrap_or(defaults.log_base_dir),
        kill_switch_file: paths
            .kill_switch_file
            .map(PathBuf::from)
            .unwrap_or(defaults.kill_switch_file),
        phase_timeouts,
        models,
    })
}

// ---------------------------------------------------------------------------
// Bash config loader (backward compatibility)
// ---------------------------------------------------------------------------

/// Parse a bash config file (e.g. pipeline.config.sh) as KEY=VALUE text (not executed as bash).
pub fn load_bash_config(path: &Path) -> Result<HashMap<String, String>> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("reading config: {}", path.display()))?;
    let mut config = HashMap::new();

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = trimmed.split_once('=') {
            let key = key.trim();
            // Strip ${VAR:-default} patterns to extract the default value
            let value = value.trim().trim_matches('"').trim_matches('\'');
            if key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                && key.starts_with(|c: char| c.is_ascii_uppercase() || c == '_')
            {
                config.insert(key.to_string(), value.to_string());
            }
        }
    }
    Ok(config)
}

/// Load model stylesheet from a JSON file (e.g. pipeline.models.json).
pub fn load_models(path: &Path) -> Result<ModelStylesheet> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("reading models: {}", path.display()))?;
    let models: ModelStylesheet =
        serde_json::from_str(&content).with_context(|| format!("parsing {}", path.display()))?;
    Ok(models)
}

fn env_or(map: &HashMap<String, String>, key: &str, env_key: &str) -> Option<String> {
    std::env::var(env_key)
        .ok()
        .or_else(|| map.get(key).cloned())
}

fn parse_f64(map: &HashMap<String, String>, key: &str, env_key: &str, default: f64) -> f64 {
    env_or(map, key, env_key)
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn parse_u32(map: &HashMap<String, String>, key: &str, env_key: &str, default: u32) -> u32 {
    env_or(map, key, env_key)
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Build a PipelineConfig from bash config file + models JSON (legacy path).
fn build_config_from_bash(
    config_path: &Path,
    models_path: &Path,
    cli_tier: Option<Tier>,
    cli_max_budget: Option<f64>,
    cli_interaction_timeout: Option<u64>,
) -> Result<PipelineConfig> {
    let file = if config_path.exists() {
        load_bash_config(config_path)?
    } else {
        HashMap::new()
    };

    let models = if models_path.exists() {
        load_models(models_path)?
    } else {
        ModelStylesheet {
            default: "sonnet".to_string(),
            overrides: HashMap::new(),
            cost_weights: HashMap::new(),
        }
    };

    let tier = cli_tier
        .or_else(|| {
            std::env::var("PIPELINE_TIER")
                .ok()
                .and_then(|s| s.parse().ok())
        })
        .or_else(|| file.get("PIPELINE_TIER").and_then(|s| s.parse().ok()))
        .unwrap_or(Tier::Auto);

    let max_pipeline_cost = cli_max_budget
        .unwrap_or_else(|| parse_f64(&file, "MAX_PIPELINE_COST", "MAX_PIPELINE_COST", 50.0));

    let interaction_timeout_secs = cli_interaction_timeout.unwrap_or_else(|| {
        parse_f64(&file, "INTERACTION_TIMEOUT", "INTERACTION_TIMEOUT", 120.0) as u64
    });

    // Load per-phase timeouts from TIMEOUT_* vars
    let mut phase_timeouts = HashMap::new();
    for (key, val) in &file {
        if let Some(phase) = key.strip_prefix("TIMEOUT_") {
            if let Ok(secs) = val.parse::<u64>() {
                phase_timeouts.insert(phase.to_lowercase().replace('_', "-"), secs);
            }
        }
    }

    Ok(PipelineConfig {
        anvil_version: file
            .get("ANVIL_VERSION")
            .cloned()
            .unwrap_or_else(|| "4.0.0".to_string()),
        tier,
        max_pipeline_cost,
        max_verify_retries: parse_u32(&file, "MAX_VERIFY_RETRIES", "MAX_VERIFY_RETRIES", 3),
        agent_command: std::env::var("AGENT_COMMAND")
            .ok()
            .or_else(|| file.get("AGENT_COMMAND").cloned())
            .unwrap_or_else(|| "claude".to_string()),
        turns_quick: parse_u32(&file, "TURNS_QUICK", "TURNS_QUICK", 15),
        turns_medium: parse_u32(&file, "TURNS_MEDIUM", "TURNS_MEDIUM", 30),
        turns_long: parse_u32(&file, "TURNS_LONG", "TURNS_LONG", 50),
        budget_low: parse_f64(&file, "BUDGET_LOW", "BUDGET_LOW", 3.0),
        budget_medium: parse_f64(&file, "BUDGET_MEDIUM", "BUDGET_MEDIUM", 5.0),
        budget_high: parse_f64(&file, "BUDGET_HIGH", "BUDGET_HIGH", 10.0),
        threshold_auto_pass: parse_f64(&file, "THRESHOLD_AUTO_PASS", "THRESHOLD_AUTO_PASS", 0.95),
        threshold_pass: parse_f64(&file, "THRESHOLD_PASS", "THRESHOLD_PASS", 0.80),
        threshold_iterate: parse_f64(&file, "THRESHOLD_ITERATE", "THRESHOLD_ITERATE", 0.60),
        threshold_holdout: parse_f64(&file, "THRESHOLD_HOLDOUT", "THRESHOLD_HOLDOUT", 0.80),
        review_validator_command: std::env::var("REVIEW_VALIDATOR_COMMAND")
            .ok()
            .or_else(|| file.get("REVIEW_VALIDATOR_COMMAND").cloned()),
        interaction_timeout_secs,
        interaction_max_retries: parse_u32(
            &file,
            "INTERACTION_MAX_RETRIES",
            "INTERACTION_MAX_RETRIES",
            2,
        ),
        stagnation_similarity: parse_f64(
            &file,
            "STAGNATION_SIMILARITY",
            "STAGNATION_SIMILARITY",
            0.90,
        ),
        log_base_dir: PathBuf::from("docs/artifacts/pipeline-runs"),
        kill_switch_file: PathBuf::from(
            file.get("KILL_SWITCH_FILE")
                .cloned()
                .unwrap_or_else(|| ".pipeline-kill".to_string()),
        ),
        phase_timeouts,
        models,
    })
}

// ---------------------------------------------------------------------------
// Env var overlay (applied on top of any config source)
// ---------------------------------------------------------------------------

/// Apply environment variable overrides to a PipelineConfig.
/// Env vars always win over file-based config.
fn apply_env_overrides(cfg: &mut PipelineConfig) {
    if let Ok(v) = std::env::var("PIPELINE_TIER") {
        if let Ok(t) = v.parse::<Tier>() {
            cfg.tier = t;
        }
    }
    if let Ok(v) = std::env::var("MAX_PIPELINE_COST") {
        if let Ok(f) = v.parse::<f64>() {
            cfg.max_pipeline_cost = f;
        }
    }
    if let Ok(v) = std::env::var("MAX_VERIFY_RETRIES") {
        if let Ok(n) = v.parse::<u32>() {
            cfg.max_verify_retries = n;
        }
    }
    if let Ok(v) = std::env::var("AGENT_COMMAND") {
        cfg.agent_command = v;
    }
    if let Ok(v) = std::env::var("TURNS_QUICK") {
        if let Ok(n) = v.parse::<u32>() {
            cfg.turns_quick = n;
        }
    }
    if let Ok(v) = std::env::var("TURNS_MEDIUM") {
        if let Ok(n) = v.parse::<u32>() {
            cfg.turns_medium = n;
        }
    }
    if let Ok(v) = std::env::var("TURNS_LONG") {
        if let Ok(n) = v.parse::<u32>() {
            cfg.turns_long = n;
        }
    }
    if let Ok(v) = std::env::var("BUDGET_LOW") {
        if let Ok(f) = v.parse::<f64>() {
            cfg.budget_low = f;
        }
    }
    if let Ok(v) = std::env::var("BUDGET_MEDIUM") {
        if let Ok(f) = v.parse::<f64>() {
            cfg.budget_medium = f;
        }
    }
    if let Ok(v) = std::env::var("BUDGET_HIGH") {
        if let Ok(f) = v.parse::<f64>() {
            cfg.budget_high = f;
        }
    }
    if let Ok(v) = std::env::var("THRESHOLD_AUTO_PASS") {
        if let Ok(f) = v.parse::<f64>() {
            cfg.threshold_auto_pass = f;
        }
    }
    if let Ok(v) = std::env::var("THRESHOLD_PASS") {
        if let Ok(f) = v.parse::<f64>() {
            cfg.threshold_pass = f;
        }
    }
    if let Ok(v) = std::env::var("THRESHOLD_ITERATE") {
        if let Ok(f) = v.parse::<f64>() {
            cfg.threshold_iterate = f;
        }
    }
    if let Ok(v) = std::env::var("THRESHOLD_HOLDOUT") {
        if let Ok(f) = v.parse::<f64>() {
            cfg.threshold_holdout = f;
        }
    }
    if let Ok(v) = std::env::var("REVIEW_VALIDATOR_COMMAND") {
        cfg.review_validator_command = Some(v);
    }
    if let Ok(v) = std::env::var("INTERACTION_TIMEOUT") {
        if let Ok(n) = v.parse::<u64>() {
            cfg.interaction_timeout_secs = n;
        }
    }
    if let Ok(v) = std::env::var("INTERACTION_MAX_RETRIES") {
        if let Ok(n) = v.parse::<u32>() {
            cfg.interaction_max_retries = n;
        }
    }
    if let Ok(v) = std::env::var("STAGNATION_SIMILARITY") {
        if let Ok(f) = v.parse::<f64>() {
            cfg.stagnation_similarity = f;
        }
    }
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Build a PipelineConfig with the following precedence (highest wins):
///   1. CLI flags
///   2. Environment variables
///   3. anvil.toml (if present)
///   4. pipeline.config.sh + pipeline.models.json (legacy fallback)
///   5. Compiled defaults
pub fn build_config(
    config_path: &Path,
    cli_tier: Option<Tier>,
    cli_max_budget: Option<f64>,
    cli_interaction_timeout: Option<u64>,
) -> Result<PipelineConfig> {
    // If the config_path is anvil.toml (or ends with .toml), load it directly.
    // Otherwise look for anvil.toml in the same directory as the config_path.
    let toml_path = if config_path.extension().and_then(|e| e.to_str()) == Some("toml") {
        config_path.to_path_buf()
    } else {
        config_path
            .parent()
            .unwrap_or(Path::new("."))
            .join("anvil.toml")
    };

    let mut cfg = if toml_path.exists() {
        tracing::info!("Loading config from {}", toml_path.display());
        load_toml_config(&toml_path)?
    } else if config_path.exists() {
        // Legacy fallback: try loading bash config if it exists
        let models_path = config_path
            .parent()
            .unwrap_or(Path::new("."))
            .join("pipeline.models.json");
        tracing::info!("Loading legacy config from bash/JSON files");
        build_config_from_bash(config_path, &models_path, None, None, None)?
    } else {
        tracing::info!("No config files found, using defaults");
        PipelineConfig::default()
    };

    // Layer 2: env vars override file config
    apply_env_overrides(&mut cfg);

    // Layer 3: CLI flags override everything
    if let Some(tier) = cli_tier {
        cfg.tier = tier;
    }
    if let Some(max_budget) = cli_max_budget {
        cfg.max_pipeline_cost = max_budget;
    }
    if let Some(timeout) = cli_interaction_timeout {
        cfg.interaction_timeout_secs = timeout;
    }

    Ok(cfg)
}
