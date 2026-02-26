mod config;
mod mcp;
mod phase;
mod pipeline;
mod scorer;
mod stagnation;
mod types;
mod watchdog;

use anyhow::{Context, Result};
use clap::Parser;
use colored::Colorize;
use std::path::{Path, PathBuf};

use types::Tier;

// ---------------------------------------------------------------------------
// CLI definition
// ---------------------------------------------------------------------------

#[derive(Parser)]
#[command(
    name = "anvil",
    version,
    about = "Quality-maximizing pipeline harness for Claude Code"
)]
enum Cli {
    /// Run the pipeline on a ticket
    Run {
        /// Ticket ID or feature description
        ticket: String,

        /// Pipeline tier
        #[arg(long, value_enum, default_value = "auto")]
        tier: Tier,

        /// Max pipeline cost in USD
        #[arg(long)]
        max_budget: Option<f64>,

        /// Config file path
        #[arg(long, default_value = "anvil.toml")]
        config: PathBuf,

        /// Seconds of no output before watchdog activates
        #[arg(long)]
        interaction_timeout: Option<u64>,
    },

    /// Show what phases would run (dry run)
    Plan {
        /// Ticket ID or feature description
        ticket: String,

        /// Pipeline tier
        #[arg(long, value_enum, default_value = "auto")]
        tier: Tier,
    },

    /// Start as MCP server for native Claude Code integration
    Serve {
        /// Port for MCP server
        #[arg(long, default_value = "0")]
        port: u16,
    },

    /// Show version and config
    Info {
        /// Config file path
        #[arg(long, default_value = "anvil.toml")]
        config: PathBuf,
    },

    /// Check prerequisites and prepare environment
    Setup {
        /// Check only, do not create or modify files
        #[arg(long)]
        check: bool,
    },

    /// Run the self-test suite
    Test {
        /// Skip slow checks (deep cross-references, DOT parsing)
        #[arg(long)]
        quick: bool,
    },

    /// Run benchmark tickets and score results
    Bench {
        /// Run a single ticket (e.g. BENCH-1)
        #[arg(long)]
        ticket: Option<String>,

        /// Approach: anvil, freestyle, or both
        #[arg(long, default_value = "both")]
        approach: String,

        /// Target project directory name under benchmarks/
        #[arg(long, default_value = "target")]
        target: String,

        /// Pipeline tier for anvil runs
        #[arg(long, default_value = "lite")]
        tier: Tier,

        /// Per-ticket budget cap in USD
        #[arg(long, default_value = "15")]
        max_budget: f64,

        /// Output directory (default: auto-generated timestamp dir)
        #[arg(long)]
        output: Option<PathBuf>,

        /// Show plan without executing
        #[arg(long)]
        dry_run: bool,
    },
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("anvil=info".parse().unwrap()),
        )
        .with_target(false)
        .init();

    let cli = Cli::parse();

    match cli {
        Cli::Run {
            ticket,
            tier,
            max_budget,
            config: config_path,
            interaction_timeout,
        } => {
            preflight()?;

            let mut cfg = config::build_config(
                &config_path,
                Some(tier).filter(|t| *t != Tier::Auto),
                max_budget,
                interaction_timeout,
            )?;

            if tier != Tier::Auto {
                cfg.tier = tier;
            }

            let exit_code = pipeline::run(&cfg, &ticket).await?;
            std::process::exit(exit_code);
        }

        Cli::Plan { ticket, tier } => {
            println!("Anvil \u{2014} Dry Run");
            println!("  Ticket: {ticket}");
            println!("  Tier: {tier}");
            println!();

            let phases = [
                types::Phase::Phase0,
                types::Phase::Interrogate,
                types::Phase::InterrogationReview,
                types::Phase::GenerateDocs,
                types::Phase::DocReview,
                types::Phase::WriteSpecs,
                types::Phase::HoldoutGenerate,
                types::Phase::Implement,
                types::Phase::Verify,
                types::Phase::HoldoutValidate,
                types::Phase::SecurityAudit,
                types::Phase::Ship,
            ];
            let skipped = types::Phase::skipped_by(tier);

            println!("  Phases:");
            for p in &phases {
                let marker = if skipped.contains(p) { "\u{2014}" } else { "Y" };
                let status = if skipped.contains(p) { "skip" } else { "run" };
                println!("    [{marker}] {p}  ({status})");
            }
        }

        Cli::Serve { port: _ } => {
            mcp::serve().await?;
        }

        Cli::Info {
            config: config_path,
        } => {
            let cfg = config::build_config(&config_path, None, None, None)?;
            println!("Anvil v{}", cfg.anvil_version);
            println!("  Tier: {}", cfg.tier);
            println!("  Max cost: ${:.2}", cfg.max_pipeline_cost);
            println!(
                "  Turns: quick={}, medium={}, long={}",
                cfg.turns_quick, cfg.turns_medium, cfg.turns_long
            );
            println!(
                "  Budgets: low=${:.2}, medium=${:.2}, high=${:.2}",
                cfg.budget_low, cfg.budget_medium, cfg.budget_high
            );
            println!(
                "  Watchdog: {}s inactivity, {} max restarts",
                cfg.interaction_timeout_secs, cfg.interaction_max_retries
            );
            println!("  Validator: {:?}", cfg.review_validator_command);
        }

        Cli::Setup { check } => {
            cmd_setup(check)?;
        }

        Cli::Test { quick } => {
            let exit_code = cmd_test(quick)?;
            std::process::exit(exit_code);
        }

        Cli::Bench {
            ticket,
            approach,
            target,
            tier,
            max_budget,
            output,
            dry_run,
        } => {
            let exit_code = cmd_bench(
                ticket, &approach, &target, tier, max_budget, output, dry_run,
            )?;
            std::process::exit(exit_code);
        }
    }

    Ok(())
}

fn preflight() -> Result<()> {
    let output = std::process::Command::new("which").arg("claude").output();
    match output {
        Ok(o) if o.status.success() => {}
        _ => {
            anyhow::bail!(
                "Claude Code CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code"
            );
        }
    }

    let output = std::process::Command::new("git")
        .arg("rev-parse")
        .arg("--git-dir")
        .output();
    match output {
        Ok(o) if o.status.success() => {}
        _ => {
            anyhow::bail!("Not in a git repository");
        }
    }

    Ok(())
}

// ===========================================================================
// anvil setup
// ===========================================================================

fn cmd_setup(check_only: bool) -> Result<()> {
    let root = find_project_root()?;
    let mut errors: u32 = 0;

    println!("\n{}\n", "Anvil Framework Setup".bold());

    // ---- 1. Required Prerequisites ----
    println!("{}", "1. Required tools".bold());

    for cmd in &["claude", "git"] {
        if command_exists(cmd) {
            let version = get_command_version(cmd);
            println!("  {}   {} ({})", "OK".green(), cmd, version);
        } else {
            println!("  {} {cmd} not found", "MISS".red());
            errors += 1;
            match *cmd {
                "claude" => println!(
                    "  {}  Install: npm install -g @anthropic-ai/claude-code",
                    "INFO".blue()
                ),
                "git" => println!(
                    "  {}  Install: brew install git (macOS) | apt install git (Linux)",
                    "INFO".blue()
                ),
                _ => {}
            }
        }
    }

    // ---- 2. Optional Tools ----
    println!("\n{}", "2. Optional tools".bold());

    for cmd in &["jq", "bc", "gh", "python3"] {
        if command_exists(cmd) {
            println!("  {}   {} (available)", "OK".green(), cmd);
        } else {
            println!("  {}  {} not found (recommended)", "REC".yellow(), cmd);
        }
    }

    // ---- 3. Environment Config ----
    println!("\n{}", "3. Environment configuration".bold());

    let env_path = root.join(".env");
    let env_example = root.join(".env.example");

    if env_path.exists() {
        println!("  {}   .env exists", "OK".green());
    } else if env_example.exists() {
        if check_only {
            println!(
                "  {}  .env missing (run without --check to create from .env.example)",
                "REC".yellow()
            );
        } else {
            std::fs::copy(&env_example, &env_path)
                .context("Failed to copy .env.example to .env")?;
            println!("  {}   .env created from .env.example", "OK".green());
            println!(
                "  {}  Edit .env to add your ANTHROPIC_API_KEY",
                "INFO".blue()
            );
        }
    } else {
        println!("  {} .env.example not found", "MISS".red());
        errors += 1;
    }

    // ---- 4. Directory Structure ----
    println!("\n{}", "4. Directory structure".bold());

    let required_dirs = [
        ".claude/skills",
        ".claude/agents",
        ".claude/rules",
        "docs/templates",
        "docs/summaries",
        "docs/artifacts",
        "scripts",
        "benchmarks/tickets/expected",
        "benchmarks/target",
    ];

    for dir in &required_dirs {
        let full = root.join(dir);
        if full.is_dir() {
            println!("  {}   {dir}/", "OK".green());
        } else if check_only {
            println!("  {} {dir}/ missing", "MISS".red());
            errors += 1;
        } else {
            std::fs::create_dir_all(&full).with_context(|| format!("Failed to create {dir}/"))?;
            println!("  {}   {dir}/ (created)", "OK".green());
        }
    }

    // ---- 5. Core Files ----
    println!("\n{}", "5. Core files".bold());

    let core_files = ["CLAUDE.md", "anvil.toml", "Cargo.toml"];

    for f in &core_files {
        if root.join(f).is_file() {
            println!("  {}   {f}", "OK".green());
        } else {
            println!("  {} {f} missing", "MISS".red());
            errors += 1;
        }
    }

    // ---- Summary ----
    println!();
    if errors == 0 {
        println!("{}\n", "Setup complete. Anvil is ready.".green().bold());
        println!("  Next steps:");
        println!("    Autonomous: anvil run TICKET-ID");
        println!("    Interactive: claude  then /phase0");
        println!("    Benchmark:  anvil bench --dry-run");
        println!();
    } else {
        println!(
            "{}\n",
            format!("Setup found {errors} issue(s). Fix them and re-run.")
                .red()
                .bold()
        );
        std::process::exit(1);
    }

    Ok(())
}

// ===========================================================================
// anvil test
// ===========================================================================

struct TestCounters {
    pass: u32,
    fail: u32,
    warn: u32,
}

impl TestCounters {
    fn new() -> Self {
        Self {
            pass: 0,
            fail: 0,
            warn: 0,
        }
    }
    fn pass(&mut self, msg: &str) {
        self.pass += 1;
        println!("  {} {msg}", "PASS".green());
    }
    fn fail(&mut self, msg: &str) {
        self.fail += 1;
        println!("  {} {msg}", "FAIL".red());
    }
    fn warn(&mut self, msg: &str) {
        self.warn += 1;
        println!("  {} {msg}", "WARN".yellow());
    }
}

fn cmd_test(quick: bool) -> Result<i32> {
    let root = find_project_root()?;
    let mut t = TestCounters::new();

    // ================================================================
    // 1. File Inventory
    // ================================================================
    println!("\n{}", "=== File Inventory ===".green());

    // Required core files (Rust-first)
    let required_files = [
        "CLAUDE.md",
        "CONTRIBUTING_AGENT.md",
        "README.md",
        "anvil.toml",
        "Cargo.toml",
        "src/main.rs",
        ".env.example",
        ".gitignore",
        "scripts/agent-test.sh",
        "scripts/review-validator.sh",
        ".github/workflows/autonomous-pipeline.yml",
        "benchmarks/target/tasktrack/__init__.py",
        "benchmarks/target/tasktrack/store.py",
        "benchmarks/target/tasktrack/cli.py",
        "benchmarks/target/tests/test_store.py",
        "benchmarks/target/CLAUDE.md",
        "benchmarks/target/pyproject.toml",
        "benchmarks/target-hard/invtrack/__init__.py",
        "benchmarks/target-hard/invtrack/models.py",
        "benchmarks/target-hard/invtrack/store.py",
        "benchmarks/target-hard/invtrack/inventory.py",
        "benchmarks/target-hard/invtrack/orders.py",
        "benchmarks/target-hard/invtrack/reports.py",
        "benchmarks/target-hard/invtrack/cli.py",
        "benchmarks/target-hard/tests/test_store.py",
        "benchmarks/target-hard/tests/test_inventory.py",
        "benchmarks/target-hard/tests/test_orders.py",
        "benchmarks/target-hard/CLAUDE.md",
        "benchmarks/target-hard/pyproject.toml",
    ];

    for f in &required_files {
        if root.join(f).is_file() {
            t.pass(&format!("{f} exists"));
        } else {
            t.fail(&format!("{f} missing"));
        }
    }

    // Skills
    let skills = [
        "phase0",
        "interrogate",
        "feature-add",
        "cost-report",
        "update-progress",
        "error-analysis",
        "heal",
    ];
    for s in &skills {
        let skill_path = root.join(format!(".claude/skills/{s}/SKILL.md"));
        if skill_path.is_file() {
            t.pass(&format!("skill: {s}"));
        } else {
            t.fail(&format!("skill missing: {s}"));
        }
    }

    // Agents
    for a in &["healer", "supervisor"] {
        if root.join(format!(".claude/agents/{a}.md")).is_file() {
            t.pass(&format!("agent: {a}"));
        } else {
            t.fail(&format!("agent missing: {a}"));
        }
    }

    // Rules
    for r in &["no-assumptions", "context-management"] {
        if root.join(format!(".claude/rules/{r}.md")).is_file() {
            t.pass(&format!("rule: {r}"));
        } else {
            t.fail(&format!("rule missing: {r}"));
        }
    }

    // Doc templates (auto-discovered)
    let templates_dir = root.join("docs/templates");
    let mut template_count = 0u32;
    if templates_dir.is_dir() {
        if let Ok(entries) = std::fs::read_dir(&templates_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("md") {
                    let name = path.file_stem().unwrap_or_default().to_string_lossy();
                    t.pass(&format!("template: {name}"));
                    template_count += 1;
                }
            }
        }
    }
    if template_count == 0 {
        t.fail("no templates found in docs/templates/");
    }

    // Settings
    if root.join(".claude/settings.json").is_file() {
        t.pass(".claude/settings.json exists");
    } else {
        t.fail(".claude/settings.json missing");
    }

    // Benchmark tickets
    let bench_tickets = [
        "BENCH-1", "BENCH-2", "BENCH-3", "BENCH-4", "BENCH-5", "BENCH-6", "BENCH-7", "BENCH-8",
        "BENCH-9", "BENCH-10",
    ];
    for bt in &bench_tickets {
        if root.join(format!("benchmarks/tickets/{bt}.md")).is_file() {
            t.pass(&format!("ticket: {bt}.md"));
        } else {
            t.fail(&format!("ticket missing: {bt}.md"));
        }
        if root
            .join(format!("benchmarks/tickets/expected/{bt}.json"))
            .is_file()
        {
            t.pass(&format!("expected: {bt}.json"));
        } else {
            t.fail(&format!("expected missing: {bt}.json"));
        }
    }

    // Holdouts
    if root.join(".holdouts").is_dir() {
        t.pass(".holdouts/ directory exists");
    } else {
        t.fail(".holdouts/ directory missing");
    }

    // ================================================================
    // 2. Bash Syntax Checks
    // ================================================================
    println!("\n{}", "=== Bash Syntax ===".green());

    let bash_files = ["scripts/agent-test.sh", "scripts/review-validator.sh"];
    for sf in &bash_files {
        let full = root.join(sf);
        if full.is_file() {
            let status = std::process::Command::new("bash")
                .arg("-n")
                .arg(&full)
                .output();
            match status {
                Ok(o) if o.status.success() => t.pass(&format!("{sf} syntax OK")),
                _ => t.fail(&format!("{sf} has syntax errors")),
            }
        } else {
            t.warn(&format!("{sf} not present, skipping syntax check"));
        }
    }

    // ================================================================
    // 2b. Version Check
    // ================================================================
    println!("\n{}", "=== Version ===".green());

    let anvil_toml_path = root.join("anvil.toml");

    if anvil_toml_path.is_file() {
        if let Ok(toml_str) = std::fs::read_to_string(&anvil_toml_path) {
            if let Ok(toml_val) = toml_str.parse::<toml::Table>() {
                if let Some(ver) = toml_val
                    .get("anvil")
                    .and_then(|v| v.get("version"))
                    .and_then(|v| v.as_str())
                {
                    t.pass(&format!("anvil.toml version={ver}"));
                } else {
                    t.fail("anvil.toml missing [anvil] version key");
                }
            } else {
                t.fail("anvil.toml is not valid TOML");
            }
        }
    } else {
        t.fail("anvil.toml not found");
    }

    // ================================================================
    // 3. Python Syntax Check
    // ================================================================
    println!("\n{}", "=== Python Syntax ===".green());

    if command_exists("python3") {
        // Required benchmark target Python files
        let required_py = ["benchmarks/target/tasktrack/store.py"];
        for pf in &required_py {
            let full = root.join(pf);
            if full.is_file() {
                let code = format!("import ast; ast.parse(open('{}').read())", full.display());
                let status = std::process::Command::new("python3")
                    .arg("-c")
                    .arg(&code)
                    .output();
                match status {
                    Ok(o) if o.status.success() => t.pass(&format!("{pf} syntax OK")),
                    _ => t.fail(&format!("{pf} has syntax errors")),
                }
            }
        }

        // target-hard Python files
        let hard_py = [
            "store.py",
            "models.py",
            "inventory.py",
            "orders.py",
            "reports.py",
            "cli.py",
        ];
        for pyf in &hard_py {
            let full = root.join(format!("benchmarks/target-hard/invtrack/{pyf}"));
            if full.is_file() {
                let code = format!("import ast; ast.parse(open('{}').read())", full.display());
                let status = std::process::Command::new("python3")
                    .arg("-c")
                    .arg(&code)
                    .output();
                match status {
                    Ok(o) if o.status.success() => {
                        t.pass(&format!("benchmarks/target-hard/invtrack/{pyf} syntax OK"))
                    }
                    _ => t.fail(&format!(
                        "benchmarks/target-hard/invtrack/{pyf} has syntax errors"
                    )),
                }
            }
        }
    } else {
        t.warn("python3 not found, skipping Python syntax check");
    }

    // ================================================================
    // 4. JSON Validity (native serde_json, no jq dependency)
    // ================================================================
    println!("\n{}", "=== JSON Validity ===".green());

    let json_files = [".claude/settings.json"];
    for jf in &json_files {
        let full = root.join(jf);
        if full.is_file() {
            match std::fs::read_to_string(&full) {
                Ok(contents) => match serde_json::from_str::<serde_json::Value>(&contents) {
                    Ok(_) => t.pass(&format!("{jf} valid JSON")),
                    Err(_) => t.fail(&format!("{jf} invalid JSON")),
                },
                Err(_) => t.fail(&format!("{jf} could not be read")),
            }
        }
    }

    // ================================================================
    // 5. Config Completeness
    // ================================================================
    println!("\n{}", "=== Config Completeness ===".green());

    if anvil_toml_path.is_file() {
        if let Ok(toml_str) = std::fs::read_to_string(&anvil_toml_path) {
            if let Ok(toml_val) = toml_str.parse::<toml::Table>() {
                let expected_sections = [
                    "anvil", "turns", "budget", "quality", "watchdog", "paths", "models",
                ];
                let mut section_count = 0u32;
                for section in &expected_sections {
                    if toml_val.contains_key(*section) {
                        t.pass(&format!("anvil.toml section: [{section}]"));
                        section_count += 1;
                    } else {
                        t.fail(&format!("anvil.toml missing section: [{section}]"));
                    }
                }
                t.pass(&format!(
                    "anvil.toml section count: {section_count}/{}",
                    expected_sections.len()
                ));
            } else {
                t.fail("anvil.toml is not valid TOML");
            }
        }
    } else {
        t.fail("anvil.toml not found");
    }

    // ================================================================
    // 6. Cross-Reference Integrity
    // ================================================================
    println!("\n{}", "=== Cross-References ===".green());

    if quick {
        t.warn("Skipping deep cross-reference checks (quick mode)");
    } else {
        // CLAUDE.md references key skills
        let claude_md = std::fs::read_to_string(root.join("CLAUDE.md")).unwrap_or_default();
        let claude_md_lower = claude_md.to_lowercase();
        for sk in &[
            "phase0",
            "interrogate",
            "feature-add",
            "cost-report",
            "heal",
        ] {
            if claude_md_lower.contains(&sk.to_lowercase()) {
                t.pass(&format!("CLAUDE.md references {sk}"));
            } else {
                t.warn(&format!("CLAUDE.md does not reference {sk}"));
            }
        }

        // README.md lists all skills
        let readme = std::fs::read_to_string(root.join("README.md")).unwrap_or_default();
        let readme_lower = readme.to_lowercase();
        for sk in &skills {
            if readme_lower.contains(&sk.to_lowercase()) {
                t.pass(&format!("README lists skill: {sk}"));
            } else {
                t.warn(&format!("README does not list skill: {sk}"));
            }
        }

        // .env.example has ANTHROPIC_API_KEY
        if let Ok(env_example_content) = std::fs::read_to_string(root.join(".env.example")) {
            if env_example_content.contains("ANTHROPIC_API_KEY") {
                t.pass(".env.example has ANTHROPIC_API_KEY");
            } else {
                t.fail(".env.example missing ANTHROPIC_API_KEY");
            }
        }

        // CI workflow references anvil run
        let ci_path = root.join(".github/workflows/autonomous-pipeline.yml");
        if ci_path.is_file() {
            let ci = std::fs::read_to_string(&ci_path).unwrap_or_default();
            if ci.contains("anvil run") || ci.contains("anvil setup") {
                t.pass("CI workflow references anvil commands");
            } else {
                t.fail("CI workflow does not reference anvil commands");
            }
        }
    }

    // ================================================================
    // 7. Skill Content Checks
    // ================================================================
    println!("\n{}", "=== Skill Content ===".green());

    for s in &skills {
        let skill_file = root.join(format!(".claude/skills/{s}/SKILL.md"));
        if skill_file.is_file() {
            if let Ok(contents) = std::fs::read_to_string(&skill_file) {
                let line_count = contents.lines().count();
                if line_count > 10 {
                    t.pass(&format!("{s}: {line_count} lines (non-trivial)"));
                } else {
                    t.warn(&format!("{s}: only {line_count} lines (may be skeletal)"));
                }
            }
        }
    }

    // ================================================================
    // 8. Exit Code Consistency
    // ================================================================
    println!("\n{}", "=== Exit Code Consistency ===".green());

    // Check main.rs for exit codes
    let main_rs_path = root.join("src/main.rs");
    if main_rs_path.is_file() {
        let main_rs_contents = std::fs::read_to_string(&main_rs_path).unwrap_or_default();
        let has_process_exit = main_rs_contents.contains("std::process::exit(");
        if has_process_exit {
            t.pass("src/main.rs uses std::process::exit()");
        } else {
            t.warn("src/main.rs does not use std::process::exit()");
        }
    }

    let readme = std::fs::read_to_string(root.join("README.md")).unwrap_or_default();
    for code in 0..=4 {
        let pattern = format!("| {code} ");
        if readme.contains(&pattern) {
            t.pass(&format!("README documents exit code {code}"));
        } else {
            t.fail(&format!("README missing exit code {code}"));
        }
    }

    // ================================================================
    // 9. Security Checks
    // ================================================================
    println!("\n{}", "=== Security ===".green());

    let has_api_key = check_for_api_keys(&root);
    if has_api_key {
        t.fail("Hardcoded API key found!");
    } else {
        t.pass("No hardcoded API keys");
    }

    let gitignore = std::fs::read_to_string(root.join(".gitignore")).unwrap_or_default();
    if gitignore.lines().any(|l| l.trim() == ".env") {
        t.pass(".gitignore blocks .env");
    } else {
        t.fail(".gitignore does not block .env");
    }

    // ================================================================
    // 11. Doc Template Cross-References
    // ================================================================
    println!("\n{}", "=== Doc Template Cross-References ===".green());

    if templates_dir.is_dir() {
        if let Ok(entries) = std::fs::read_dir(&templates_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("md") {
                    let name = path.file_stem().unwrap_or_default().to_string_lossy();
                    if let Ok(contents) = std::fs::read_to_string(&path) {
                        if contents.contains("## Related Documents") {
                            t.pass(&format!("template {name} has Related Documents section"));
                        } else {
                            t.fail(&format!(
                                "template {name} missing Related Documents section"
                            ));
                        }
                    }
                }
            }
        }
    }

    // ================================================================
    // Summary
    // ================================================================
    println!();
    println!("{}", "============================================".green());
    println!(
        "  PASS: {}  FAIL: {}  WARN: {}",
        format!("{}", t.pass).green(),
        format!("{}", t.fail).red(),
        format!("{}", t.warn).yellow()
    );
    println!("{}", "============================================".green());

    if t.fail > 0 {
        println!(
            "\n{}",
            format!("Self-test FAILED with {} failure(s).", t.fail).red()
        );
        Ok(1)
    } else {
        println!("\n{}", "All tests passed.".green());
        Ok(0)
    }
}

/// Scan source files for hardcoded API keys.
fn check_for_api_keys(root: &Path) -> bool {
    let patterns = ["sk-ant-"];
    let extensions = ["sh", "py", "json"];

    for ext in &extensions {
        let glob_pattern = format!("{}/**/*.{ext}", root.display());
        if let Ok(paths) = glob::glob(&glob_pattern) {
            for entry in paths.flatten() {
                let path_str = entry.to_string_lossy();
                if path_str.contains(".git/")
                    || path_str.ends_with(".env.example")
                    || path_str.ends_with(".gitignore")
                    || path_str.ends_with("review-validator.sh")
                {
                    continue;
                }
                if let Ok(contents) = std::fs::read_to_string(&entry) {
                    for pat in &patterns {
                        if contents.contains(pat) {
                            return true;
                        }
                    }
                }
            }
        }
    }
    false
}

// ===========================================================================
// anvil bench
// ===========================================================================

fn cmd_bench(
    ticket: Option<String>,
    approach: &str,
    target: &str,
    tier: Tier,
    max_budget: f64,
    output: Option<PathBuf>,
    dry_run: bool,
) -> Result<i32> {
    let root = find_project_root()?;
    let benchmark_dir = root.join("benchmarks");
    let target_dir = benchmark_dir.join(target);
    let tickets_dir = benchmark_dir.join("tickets");

    // Validate approach
    if !["anvil", "freestyle", "both"].contains(&approach) {
        anyhow::bail!("Invalid approach: {approach} (must be anvil|freestyle|both)");
    }

    // Validate target exists
    if !target_dir.is_dir() {
        anyhow::bail!("Target project not found: {}", target_dir.display());
    }

    // Discover tickets
    let tickets: Vec<String> = if let Some(ref t) = ticket {
        let ticket_file = tickets_dir.join(format!("{t}.md"));
        if !ticket_file.is_file() {
            anyhow::bail!("Ticket not found: {}", ticket_file.display());
        }
        vec![t.clone()]
    } else {
        let mut found = Vec::new();
        if let Ok(entries) = std::fs::read_dir(&tickets_dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with("BENCH-") && name.ends_with(".md") {
                    found.push(name.trim_end_matches(".md").to_string());
                }
            }
        }
        found.sort();
        found
    };

    if tickets.is_empty() {
        anyhow::bail!("No tickets found in {}", tickets_dir.display());
    }

    // Output directory
    let output_dir = output.unwrap_or_else(|| {
        let ts = chrono::Local::now().format("%Y%m%d-%H%M");
        root.join(format!("docs/artifacts/benchmark-{ts}"))
    });

    println!("{}", "[bench] Benchmark configuration:".blue());
    println!("  Target:   {target}");
    println!("  Tickets:  {}", tickets.join(", "));
    println!("  Approach: {approach}");
    println!("  Tier:     {tier}");
    println!("  Budget:   ${max_budget}/ticket");
    println!("  Output:   {}", output_dir.display());

    if dry_run {
        println!();
        println!(
            "{} DRY RUN - would run {} ticket(s) with approach={approach}",
            "[bench]".blue(),
            tickets.len()
        );
        for tid in &tickets {
            let ticket_file = tickets_dir.join(format!("{tid}.md"));
            let first_line = std::fs::read_to_string(&ticket_file)
                .unwrap_or_default()
                .lines()
                .next()
                .unwrap_or("")
                .trim_start_matches("# ")
                .to_string();
            println!("  {tid}: {first_line}");
        }
        return Ok(0);
    }

    // Create output directory
    std::fs::create_dir_all(&output_dir)
        .with_context(|| format!("Failed to create output dir: {}", output_dir.display()))?;

    // Resolve claude CLI path
    let claude_cmd = bench_which("claude").unwrap_or_else(|| "claude".to_string());

    let started = chrono::Utc::now();
    let mut ticket_evidence: Vec<serde_json::Value> = Vec::new();

    // Run benchmarks for each ticket
    for tid in &tickets {
        println!("\n{} --- {tid} ---", "[bench]".blue());

        let ticket_file = tickets_dir.join(format!("{tid}.md"));
        let ticket_text = std::fs::read_to_string(&ticket_file)
            .with_context(|| format!("reading ticket {}", ticket_file.display()))?;

        let mut freestyle_entry: Option<serde_json::Value> = None;
        let mut anvil_entry: Option<serde_json::Value> = None;

        // ----- Freestyle run -----
        if approach == "freestyle" || approach == "both" {
            let workdir = output_dir.join(format!("freestyle-{tid}"));
            prepare_bench_workdir(&target_dir, &workdir, &format!("freestyle-{tid}"))?;

            let log_file = output_dir.join(format!("freestyle-{tid}.log"));
            let prompt = format!(
                "Read CLAUDE.md. Implement this ticket:\n\n{}\n\n\
                 Read the codebase, write tests first, implement, verify all tests pass.",
                ticket_text
            );

            println!(
                "  {} [FREE] Running {tid} (budget=${max_budget})...",
                "[bench]".blue()
            );
            let run_start = std::time::Instant::now();

            let run_result = bench_run_with_timeout(
                std::process::Command::new(&claude_cmd)
                    .arg("-p")
                    .arg(&prompt)
                    .arg("--output-format")
                    .arg("json")
                    .arg("--max-turns")
                    .arg("30")
                    .arg("--max-budget-usd")
                    .arg(format!("{max_budget}"))
                    .arg("--permission-mode")
                    .arg("bypassPermissions")
                    .current_dir(&workdir)
                    .env("AUTONOMOUS_MODE", "true")
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::piped()),
                600, // 10 minutes for freestyle
            );

            let duration_secs = run_start.elapsed().as_secs_f64();

            // Write log and extract cost
            let (cost_usd, timed_out) = match &run_result {
                Ok((output, was_timeout)) => {
                    let _ = std::fs::write(&log_file, &output.stdout);
                    let cost = bench_parse_claude_cost(&output.stdout);
                    (cost, *was_timeout)
                }
                Err(e) => {
                    let _ = std::fs::write(&log_file, format!("Error: {e}"));
                    (0.0, false)
                }
            };

            // Score the result
            let score_result =
                scorer::score_ticket(&workdir, tid, Some(&target_dir), &benchmark_dir);

            let status = if timed_out { "timeout" } else { "ok" };
            println!(
                "  {} [FREE] {tid}: score={}/100, cost=${:.2}, time={:.0}s{}",
                "[bench]".green(),
                score_result.score,
                cost_usd,
                duration_secs,
                if timed_out { " (TIMEOUT)" } else { "" }
            );

            freestyle_entry = Some(serde_json::json!({
                "score": score_result.score,
                "cost_usd": cost_usd,
                "duration_secs": duration_secs,
                "status": status,
                "checks": score_result.checks,
            }));
        }

        // ----- Anvil run -----
        if approach == "anvil" || approach == "both" {
            let workdir = output_dir.join(format!("anvil-{tid}"));
            prepare_bench_workdir(&target_dir, &workdir, &format!("anvil-{tid}"))?;
            overlay_anvil_framework(&root, &workdir)?;

            let log_file = output_dir.join(format!("anvil-{tid}.log"));
            let ticket_arg = format!("{tid}: {ticket_text}");

            println!(
                "  {} [ANVIL] Running {tid} (tier={tier}, budget=${max_budget})...",
                "[bench]".blue()
            );
            let run_start = std::time::Instant::now();

            let run_result = bench_run_with_timeout(
                std::process::Command::new("./anvil")
                    .arg("run")
                    .arg(&ticket_arg)
                    .arg("--tier")
                    .arg(tier.to_string())
                    .arg("--max-budget")
                    .arg(format!("{max_budget}"))
                    .current_dir(&workdir)
                    .env("AUTONOMOUS_MODE", "true")
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::piped()),
                1800, // 30 minutes for anvil
            );

            let duration_secs = run_start.elapsed().as_secs_f64();

            // Write log and extract cost from pipeline output
            let (cost_usd, timed_out) = match &run_result {
                Ok((output, was_timeout)) => {
                    let _ = std::fs::write(&log_file, &output.stdout);
                    let stdout_str = String::from_utf8_lossy(&output.stdout);
                    let cost = bench_extract_pipeline_cost(&stdout_str);
                    (cost, *was_timeout)
                }
                Err(e) => {
                    let _ = std::fs::write(&log_file, format!("Error: {e}"));
                    (0.0, false)
                }
            };

            // Score the result
            let score_result =
                scorer::score_ticket(&workdir, tid, Some(&target_dir), &benchmark_dir);

            let status = if timed_out { "timeout" } else { "ok" };
            println!(
                "  {} [ANVIL] {tid}: score={}/100, cost=${:.2}, time={:.0}s{}",
                "[bench]".green(),
                score_result.score,
                cost_usd,
                duration_secs,
                if timed_out { " (TIMEOUT)" } else { "" }
            );

            anvil_entry = Some(serde_json::json!({
                "score": score_result.score,
                "cost_usd": cost_usd,
                "duration_secs": duration_secs,
                "status": status,
                "checks": score_result.checks,
            }));
        }

        // Build per-ticket evidence entry
        let mut entry = serde_json::json!({ "ticket": tid });
        if let Some(f) = freestyle_entry {
            entry["freestyle"] = f;
        }
        if let Some(a) = anvil_entry {
            entry["anvil"] = a;
        }
        ticket_evidence.push(entry);
    }

    // ----- Generate evidence JSON -----
    let completed = chrono::Utc::now();

    // Compute summary averages
    let freestyle_scores: Vec<f64> = ticket_evidence
        .iter()
        .filter_map(|t| t.get("freestyle").and_then(|f| f["score"].as_f64()))
        .collect();
    let anvil_scores: Vec<f64> = ticket_evidence
        .iter()
        .filter_map(|t| t.get("anvil").and_then(|a| a["score"].as_f64()))
        .collect();
    let freestyle_costs: f64 = ticket_evidence
        .iter()
        .filter_map(|t| t.get("freestyle").and_then(|f| f["cost_usd"].as_f64()))
        .sum();
    let anvil_costs: f64 = ticket_evidence
        .iter()
        .filter_map(|t| t.get("anvil").and_then(|a| a["cost_usd"].as_f64()))
        .sum();

    let freestyle_avg = if freestyle_scores.is_empty() {
        None
    } else {
        Some(freestyle_scores.iter().sum::<f64>() / freestyle_scores.len() as f64)
    };
    let anvil_avg = if anvil_scores.is_empty() {
        None
    } else {
        Some(anvil_scores.iter().sum::<f64>() / anvil_scores.len() as f64)
    };

    let total_cost = freestyle_costs + anvil_costs;

    let evidence = serde_json::json!({
        "started": started.to_rfc3339(),
        "completed": completed.to_rfc3339(),
        "target": target,
        "approach": approach,
        "tier": tier.to_string(),
        "tickets": ticket_evidence,
        "summary": {
            "freestyle_avg": freestyle_avg,
            "anvil_avg": anvil_avg,
            "freestyle_total_cost": freestyle_costs,
            "anvil_total_cost": anvil_costs,
            "total_cost": total_cost,
        }
    });

    let evidence_file = output_dir.join("benchmark-evidence.json");
    std::fs::write(&evidence_file, serde_json::to_string_pretty(&evidence)?)?;

    // ----- Print summary table -----
    println!();
    println!(
        "{}",
        "=====================================================".bold()
    );
    println!("{}", "  BENCHMARK RESULTS".bold());
    println!(
        "{}",
        "=====================================================".bold()
    );
    println!();
    println!(
        "  {:<10} {:<12} {:<8} {:<10} {:<10}",
        "Ticket", "Approach", "Score", "Cost", "Time"
    );
    println!(
        "  {:<10} {:<12} {:<8} {:<10} {:<10}",
        "------", "--------", "-----", "----", "----"
    );

    for entry in &ticket_evidence {
        let tid_str = entry["ticket"].as_str().unwrap_or("?");
        if let Some(f) = entry.get("freestyle") {
            let sc = f["score"].as_u64().unwrap_or(0);
            let cost = f["cost_usd"].as_f64().unwrap_or(0.0);
            let dur = f["duration_secs"].as_f64().unwrap_or(0.0);
            println!(
                "  {:<10} {:<12} {:<8} {:<10} {:<10}",
                tid_str,
                "freestyle",
                format!("{sc}/100"),
                format!("${cost:.2}"),
                format!("{dur:.0}s")
            );
        }
        if let Some(a) = entry.get("anvil") {
            let sc = a["score"].as_u64().unwrap_or(0);
            let cost = a["cost_usd"].as_f64().unwrap_or(0.0);
            let dur = a["duration_secs"].as_f64().unwrap_or(0.0);
            println!(
                "  {:<10} {:<12} {:<8} {:<10} {:<10}",
                tid_str,
                "anvil",
                format!("{sc}/100"),
                format!("${cost:.2}"),
                format!("{dur:.0}s")
            );
        }
    }

    println!();
    println!("  {}", "Averages:".bold());
    if let Some(avg) = freestyle_avg {
        println!("    Freestyle: {avg:.0}/100 avg, ${freestyle_costs:.2} total");
    }
    if let Some(avg) = anvil_avg {
        println!("    Anvil:     {avg:.0}/100 avg, ${anvil_costs:.2} total");
    }
    println!("    Total cost: ${total_cost:.2}");
    println!();
    println!(
        "{}",
        "=====================================================".bold()
    );
    println!();
    println!("  Evidence: {}", evidence_file.display());
    println!(
        "  Workdirs: {}/[anvil|freestyle]-BENCH-*/",
        output_dir.display()
    );
    println!();

    Ok(0)
}

/// Run a Command with a timeout (in seconds). Returns (Output, timed_out).
///
/// Spawns the child process, then uses a background thread to kill it if the
/// timeout expires. The watchdog thread sends SIGTERM via the `kill` command
/// using the child PID, then SIGKILL after a 5s grace period.
fn bench_run_with_timeout(
    cmd: &mut std::process::Command,
    timeout_secs: u64,
) -> Result<(std::process::Output, bool)> {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    let child = cmd
        .spawn()
        .context("failed to spawn benchmark subprocess")?;
    let pid = child.id();
    let timed_out = Arc::new(AtomicBool::new(false));
    let timed_out_clone = Arc::clone(&timed_out);

    // Watchdog thread: kill the child after timeout_secs
    let watchdog = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(timeout_secs));
        timed_out_clone.store(true, Ordering::SeqCst);
        // Send SIGTERM, then SIGKILL after 5s grace period
        let _ = std::process::Command::new("kill")
            .arg(pid.to_string())
            .output();
        std::thread::sleep(std::time::Duration::from_secs(5));
        let _ = std::process::Command::new("kill")
            .args(["-9", &pid.to_string()])
            .output();
    });

    let output = child
        .wait_with_output()
        .context("waiting for benchmark subprocess")?;

    // The watchdog thread is either still sleeping (normal case) or has already
    // fired (timeout case). We detach it — if still sleeping it will eventually
    // wake, try to kill a recycled or non-existent PID (harmless), and exit.
    drop(watchdog);

    let was_timed_out = timed_out.load(Ordering::SeqCst);
    Ok((output, was_timed_out))
}

/// Parse cost from Claude CLI JSON output (--output-format json).
fn bench_parse_claude_cost(stdout: &[u8]) -> f64 {
    // Try parsing the entire output as JSON first
    if let Ok(v) = serde_json::from_slice::<serde_json::Value>(stdout) {
        if let Some(cost) = v.get("total_cost_usd").and_then(|c| c.as_f64()) {
            return cost;
        }
    }
    // Fallback: scan lines for a JSON object containing total_cost_usd
    let text = String::from_utf8_lossy(stdout);
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('{') {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(trimmed) {
                if let Some(cost) = v.get("total_cost_usd").and_then(|c| c.as_f64()) {
                    return cost;
                }
            }
        }
    }
    0.0
}

/// Extract cost from Anvil pipeline log output ("Total cost: $X.XX").
fn bench_extract_pipeline_cost(stdout: &str) -> f64 {
    let re = regex::Regex::new(r"Total cost: \$([0-9.]+)").unwrap();
    re.captures(stdout)
        .and_then(|c| c.get(1))
        .and_then(|m| m.as_str().parse::<f64>().ok())
        .unwrap_or(0.0)
}

/// Find a command on PATH, returning its absolute path.
fn bench_which(name: &str) -> Option<String> {
    std::process::Command::new("which")
        .arg(name)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// Copy the target project into a workdir and git-init it.
fn prepare_bench_workdir(target_dir: &Path, workdir: &Path, label: &str) -> Result<()> {
    if workdir.exists() {
        std::fs::remove_dir_all(workdir)?;
    }
    copy_dir_recursive(target_dir, workdir)?;

    // Initialize git so pipeline/scorer can detect changes
    let _ = std::process::Command::new("git")
        .args(["init", "-q"])
        .current_dir(workdir)
        .output();
    let _ = std::process::Command::new("git")
        .args(["add", "-A"])
        .current_dir(workdir)
        .output();
    let _ = std::process::Command::new("git")
        .args(["commit", "-q", "-m", "baseline"])
        .current_dir(workdir)
        .output();

    println!(
        "  {} Prepared {label} workdir: {}",
        "[bench]".blue(),
        workdir.file_name().unwrap_or_default().to_string_lossy()
    );
    Ok(())
}

/// Overlay Anvil framework files into a benchmark workdir.
fn overlay_anvil_framework(root: &Path, workdir: &Path) -> Result<()> {
    // Copy .claude directory
    let claude_src = root.join(".claude");
    let claude_dst = workdir.join(".claude");
    if claude_src.is_dir() {
        let _ = copy_dir_recursive(&claude_src, &claude_dst);
    }

    // Copy core files (all conditional -- only copy what exists)
    let files = ["anvil.toml", "CONTRIBUTING_AGENT.md"];
    for f in &files {
        let src = root.join(f);
        if src.is_file() {
            let _ = std::fs::copy(&src, workdir.join(f));
        }
    }

    // Copy the anvil binary if it exists
    let anvil_binary = root.join("target/release/anvil");
    if anvil_binary.is_file() {
        let _ = std::fs::copy(&anvil_binary, workdir.join("anvil"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let dst = workdir.join("anvil");
            if let Ok(meta) = std::fs::metadata(&dst) {
                let mut perms = meta.permissions();
                perms.set_mode(perms.mode() | 0o755);
                let _ = std::fs::set_permissions(&dst, perms);
            }
        }
    }

    // Copy scripts
    let scripts_dst = workdir.join("scripts");
    std::fs::create_dir_all(&scripts_dst)?;
    let validator = root.join("scripts/review-validator.sh");
    if validator.is_file() {
        let _ = std::fs::copy(&validator, scripts_dst.join("review-validator.sh"));
    }

    Ok(())
}

// ===========================================================================
// Helpers
// ===========================================================================

/// Find the project root by walking up from cwd.
///
/// Detection order (first match wins):
///   1. CLAUDE.md + anvil.toml           (Rust-native config)
///   2. Cargo.toml with name = "anvil"   (self-development)
fn find_project_root() -> Result<PathBuf> {
    let cwd = std::env::current_dir()?;
    let mut dir = cwd.as_path();
    loop {
        // Preferred: Rust-native config
        if dir.join("CLAUDE.md").is_file() && dir.join("anvil.toml").is_file() {
            return Ok(dir.to_path_buf());
        }
        // Self-development: building Anvil itself
        let cargo_toml = dir.join("Cargo.toml");
        if cargo_toml.is_file() {
            if let Ok(contents) = std::fs::read_to_string(&cargo_toml) {
                if contents.contains("name = \"anvil\"") {
                    return Ok(dir.to_path_buf());
                }
            }
        }
        match dir.parent() {
            Some(parent) => dir = parent,
            None => return Ok(cwd),
        }
    }
}

/// Check if a command exists on PATH.
fn command_exists(cmd: &str) -> bool {
    std::process::Command::new("which")
        .arg(cmd)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Get a human-readable version string from a command.
fn get_command_version(cmd: &str) -> String {
    std::process::Command::new(cmd)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| {
            String::from_utf8(o.stdout)
                .ok()
                .and_then(|s| s.lines().next().map(|l| l.to_string()))
        })
        .unwrap_or_else(|| "unknown".to_string())
}

/// Recursively copy a directory.
fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        if src_path.is_dir() {
            copy_dir_recursive(&src_path, &dst_path)?;
        } else {
            std::fs::copy(&src_path, &dst_path)?;
        }
    }
    Ok(())
}
