//! Benchmark quality scorer.
//!
//! Scores a benchmark ticket's implementation 0--100 using automated checks.
//! No LLM involvement -- pure static analysis + test execution.
//!
//! This replaces the former `benchmarks/score.py`. Most checks shell out to
//! `python3` / `pytest` anyway, so this module is orchestration + JSON parsing,
//! not a reimplementation of Python's `ast` module.

use std::fs;
use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Result of scoring a single ticket.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScoreResult {
    pub ticket: String,
    pub score: u64,
    pub earned_weight: u64,
    pub total_weight: u64,
    pub checks: Vec<CheckResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Result of a single check within a ticket.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    #[serde(rename = "type")]
    pub check_type: String,
    pub pass: bool,
    pub weight: u64,
    pub detail: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub test_count: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stdout: Option<String>,
}

// ---------------------------------------------------------------------------
// Expected-check spec (deserialized from benchmarks/tickets/expected/*.json)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize)]
struct ExpectedSpec {
    #[allow(dead_code)]
    ticket: String,
    #[allow(dead_code)]
    description: String,
    checks: Vec<CheckSpec>,
}

#[derive(Debug, Clone, Deserialize)]
struct CheckSpec {
    #[serde(rename = "type")]
    check_type: String,
    #[serde(default)]
    file: Option<String>,
    #[serde(default)]
    pattern: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    weight: u64,
    #[serde(default)]
    minimum: Option<u64>,
    #[serde(default)]
    baseline: Option<u64>,
    #[serde(default)]
    subset: Option<String>,
    /// Glob pattern for grep_absent_all (defaults to "**/*.py").
    #[serde(default)]
    glob: Option<String>,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Score a single ticket's implementation.
///
/// * `workdir`      -- path to the project working directory
/// * `ticket_id`    -- ticket identifier (e.g. "BENCH-1")
/// * `baseline_dir` -- optional path to baseline (unmodified) project
/// * `expected_dir` -- directory containing the `tickets/expected/*.json` files
///   (typically `benchmarks/` relative to the repo root)
pub fn score_ticket(
    workdir: &Path,
    ticket_id: &str,
    baseline_dir: Option<&Path>,
    expected_dir: &Path,
) -> ScoreResult {
    let expected_path = expected_dir
        .join("tickets")
        .join("expected")
        .join(format!("{ticket_id}.json"));

    if !expected_path.exists() {
        return ScoreResult {
            ticket: ticket_id.to_string(),
            score: 0,
            earned_weight: 0,
            total_weight: 0,
            checks: vec![],
            error: Some(format!("No expected file for {ticket_id}")),
        };
    }

    let spec: ExpectedSpec = match load_spec(&expected_path) {
        Ok(s) => s,
        Err(e) => {
            return ScoreResult {
                ticket: ticket_id.to_string(),
                score: 0,
                earned_weight: 0,
                total_weight: 0,
                checks: vec![],
                error: Some(format!("Failed to load spec: {e}")),
            };
        }
    };

    let mut results: Vec<CheckResult> = Vec::new();
    let mut total_weight: u64 = 0;
    let mut earned_weight: u64 = 0;

    for check in &spec.checks {
        let result = dispatch_check(workdir, check, baseline_dir);
        total_weight += check.weight;
        if result.pass {
            earned_weight += check.weight;
        }
        results.push(result);
    }

    let score = if total_weight > 0 {
        // Rounding: Python uses round() which is banker's rounding, but
        // for integer percentages the difference is negligible. We use
        // standard rounding here (0.5 rounds up).
        ((earned_weight as f64 * 100.0 / total_weight as f64).round()) as u64
    } else {
        0
    };

    ScoreResult {
        ticket: ticket_id.to_string(),
        score,
        earned_weight,
        total_weight,
        checks: results,
        error: None,
    }
}

// ---------------------------------------------------------------------------
// Check dispatcher
// ---------------------------------------------------------------------------

fn dispatch_check(workdir: &Path, check: &CheckSpec, baseline_dir: Option<&Path>) -> CheckResult {
    let handler_result = match check.check_type.as_str() {
        "ast_parse" => check_ast_parse(workdir, check),
        "pytest" => check_pytest(workdir, None),
        "pytest_subset" => {
            let subset = check
                .subset
                .as_deref()
                .or(check.pattern.as_deref())
                .unwrap_or("");
            check_pytest(workdir, Some(subset))
        }
        "grep_present" => check_grep_present(workdir, check),
        "grep_absent" => check_grep_absent(workdir, check),
        "grep_absent_all" => check_grep_absent_all(workdir, check),
        "file_exists" => check_file_exists(workdir, check),
        "test_count_minimum" => check_test_count_minimum(workdir, check),
        "test_count_increased" => check_test_count_increased(workdir, check),
        "test_count_files" | "pytest_count_files" => check_pytest_count_files(workdir, check),
        "file_unchanged" => check_file_unchanged(workdir, check, baseline_dir),
        unknown => HandlerResult::fail(format!("Unknown check type: {unknown}")),
    };

    CheckResult {
        check_type: check.check_type.clone(),
        pass: handler_result.pass,
        weight: check.weight,
        detail: handler_result.detail,
        description: check.description.clone().unwrap_or_default(),
        test_count: handler_result.test_count,
        stdout: handler_result.stdout,
    }
}

// ---------------------------------------------------------------------------
// Internal result type for check handlers
// ---------------------------------------------------------------------------

struct HandlerResult {
    pass: bool,
    detail: String,
    test_count: Option<u64>,
    stdout: Option<String>,
}

impl HandlerResult {
    fn ok(detail: impl Into<String>) -> Self {
        Self {
            pass: true,
            detail: detail.into(),
            test_count: None,
            stdout: None,
        }
    }

    fn fail(detail: impl Into<String>) -> Self {
        Self {
            pass: false,
            detail: detail.into(),
            test_count: None,
            stdout: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Check implementations
// ---------------------------------------------------------------------------

/// Verify file has valid Python syntax by shelling out to `python3 -c "import ast; ..."`.
fn check_ast_parse(workdir: &Path, check: &CheckSpec) -> HandlerResult {
    let file = match &check.file {
        Some(f) => f,
        None => return HandlerResult::fail("No file specified for ast_parse check"),
    };
    let filepath = workdir.join(file);
    if !filepath.exists() {
        return HandlerResult::fail(format!("File not found: {file}"));
    }

    let script = format!(
        "import ast; ast.parse(open({}).read())",
        quote_python_string(&filepath.to_string_lossy())
    );
    let output = Command::new("python3").arg("-c").arg(&script).output();

    match output {
        Ok(o) if o.status.success() => HandlerResult::ok("Valid Python syntax"),
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            HandlerResult::fail(format!("Syntax error: {}", stderr.trim()))
        }
        Err(e) => HandlerResult::fail(format!("Failed to run python3: {e}")),
    }
}

/// Run `python3 -m pytest tests/ -v --tb=short` and check exit code.
/// If `subset` is provided, adds `-k <subset>` to the command.
fn check_pytest(workdir: &Path, subset: Option<&str>) -> HandlerResult {
    let mut cmd = Command::new("python3");
    cmd.args(["-m", "pytest", "tests/", "-v", "--tb=short"]);
    if let Some(k) = subset {
        cmd.args(["-k", k]);
    }
    cmd.current_dir(workdir);

    match cmd.output() {
        Ok(output) => {
            let stdout_str = String::from_utf8_lossy(&output.stdout);
            let passed = output.status.success();
            let count = extract_pytest_count(&stdout_str);
            let exit_code = output.status.code().unwrap_or(-1);

            let stdout_tail = if !passed {
                let s = stdout_str.as_ref();
                let tail_start = s.len().saturating_sub(500);
                Some(s[tail_start..].to_string())
            } else {
                None
            };

            HandlerResult {
                pass: passed,
                detail: format!("pytest exit={exit_code}, {count} passed"),
                test_count: Some(count),
                stdout: stdout_tail,
            }
        }
        Err(e) => HandlerResult::fail(format!("pytest error: {e}")),
    }
}

/// Verify regex pattern is found in file.
fn check_grep_present(workdir: &Path, check: &CheckSpec) -> HandlerResult {
    let (file, pattern) = match (check.file.as_deref(), check.pattern.as_deref()) {
        (Some(f), Some(p)) => (f, p),
        _ => return HandlerResult::fail("grep_present requires 'file' and 'pattern'"),
    };
    let filepath = workdir.join(file);
    if !filepath.exists() {
        return HandlerResult::fail(format!("File not found: {file}"));
    }
    let content = match fs::read_to_string(&filepath) {
        Ok(c) => c,
        Err(e) => return HandlerResult::fail(format!("Failed to read {file}: {e}")),
    };
    let desc = check.description.as_deref().unwrap_or(pattern);
    match Regex::new(pattern) {
        Ok(re) if re.is_match(&content) => HandlerResult::ok(format!("Pattern found: {desc}")),
        Ok(_) => HandlerResult::fail(format!("Pattern not found: {desc}")),
        Err(e) => HandlerResult::fail(format!("Invalid regex '{pattern}': {e}")),
    }
}

/// Verify regex pattern is NOT found in file.
fn check_grep_absent(workdir: &Path, check: &CheckSpec) -> HandlerResult {
    let (file, pattern) = match (check.file.as_deref(), check.pattern.as_deref()) {
        (Some(f), Some(p)) => (f, p),
        _ => return HandlerResult::fail("grep_absent requires 'file' and 'pattern'"),
    };
    let filepath = workdir.join(file);
    if !filepath.exists() {
        // File not found means pattern is trivially absent (matches Python behavior).
        return HandlerResult::ok("File not found (pattern trivially absent)");
    }
    let content = match fs::read_to_string(&filepath) {
        Ok(c) => c,
        Err(e) => return HandlerResult::fail(format!("Failed to read {file}: {e}")),
    };
    let desc = check.description.as_deref().unwrap_or(pattern);
    match Regex::new(pattern) {
        Ok(re) if re.is_match(&content) => {
            HandlerResult::fail(format!("Pattern still present: {desc}"))
        }
        Ok(_) => HandlerResult::ok(format!("Pattern absent: {desc}")),
        Err(e) => HandlerResult::fail(format!("Invalid regex '{pattern}': {e}")),
    }
}

/// Verify regex pattern is absent from ALL files matching a glob pattern.
fn check_grep_absent_all(workdir: &Path, check: &CheckSpec) -> HandlerResult {
    let pattern = match check.pattern.as_deref() {
        Some(p) => p,
        None => return HandlerResult::fail("grep_absent_all requires 'pattern'"),
    };
    let file_glob = check.glob.as_deref().unwrap_or("**/*.py");
    let desc = check
        .description
        .clone()
        .unwrap_or_else(|| format!("Pattern absent from {file_glob}"));

    let re = match Regex::new(pattern) {
        Ok(r) => r,
        Err(e) => return HandlerResult::fail(format!("Invalid regex '{pattern}': {e}")),
    };

    let full_glob = workdir.join(file_glob).to_string_lossy().to_string();
    let entries = match glob::glob(&full_glob) {
        Ok(paths) => paths,
        Err(e) => return HandlerResult::fail(format!("Invalid glob '{file_glob}': {e}")),
    };

    let mut found_in: Vec<String> = Vec::new();
    for entry in entries {
        let path = match entry {
            Ok(p) => p,
            Err(_) => continue,
        };
        if !path.is_file() {
            continue;
        }
        if let Ok(content) = fs::read_to_string(&path) {
            if re.is_match(&content) {
                let rel = path
                    .strip_prefix(workdir)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .to_string();
                found_in.push(rel);
            }
        }
    }

    if found_in.is_empty() {
        HandlerResult::ok(format!("Pattern absent: {desc}"))
    } else {
        HandlerResult::fail(format!("Pattern still present in: {}", found_in.join(", ")))
    }
}

/// Verify a file was created.
fn check_file_exists(workdir: &Path, check: &CheckSpec) -> HandlerResult {
    let file = match check.file.as_deref() {
        Some(f) => f,
        None => return HandlerResult::fail("file_exists requires 'file'"),
    };
    let desc = check.description.as_deref().unwrap_or(file);
    if workdir.join(file).exists() {
        HandlerResult::ok(format!("File exists: {desc}"))
    } else {
        HandlerResult::fail(format!("File not found: {desc}"))
    }
}

/// Verify at least N test functions exist.
fn check_test_count_minimum(workdir: &Path, check: &CheckSpec) -> HandlerResult {
    let minimum = check.minimum.unwrap_or(1);
    let count = count_test_functions(workdir);
    let passed = count >= minimum;
    HandlerResult {
        pass: passed,
        detail: format!("Test count: {count} (minimum: {minimum})"),
        test_count: Some(count),
        stdout: None,
    }
}

/// Verify test count increased from baseline.
fn check_test_count_increased(workdir: &Path, check: &CheckSpec) -> HandlerResult {
    let baseline = check.baseline.unwrap_or(5);
    let count = count_test_functions(workdir);
    let passed = count > baseline;
    HandlerResult {
        pass: passed,
        detail: format!("Test count: {count} (baseline: {baseline})"),
        test_count: Some(count),
        stdout: None,
    }
}

/// Count test files (not just test functions).
fn check_pytest_count_files(workdir: &Path, check: &CheckSpec) -> HandlerResult {
    let minimum = check.minimum.unwrap_or(1);
    let count = count_test_files(workdir);
    let passed = count >= minimum;
    let desc = check
        .description
        .clone()
        .unwrap_or_else(|| format!("At least {minimum} test files"));
    HandlerResult {
        pass: passed,
        detail: format!("Test files: {count} (minimum: {minimum}) - {desc}"),
        test_count: None,
        stdout: None,
    }
}

/// Verify file SHA-256 matches baseline.
fn check_file_unchanged(
    workdir: &Path,
    check: &CheckSpec,
    baseline_dir: Option<&Path>,
) -> HandlerResult {
    let file = match check.file.as_deref() {
        Some(f) => f,
        None => return HandlerResult::fail("file_unchanged requires 'file'"),
    };
    let baseline_dir = match baseline_dir {
        Some(d) => d,
        None => return HandlerResult::fail("No baseline path provided"),
    };
    let filepath = workdir.join(file);
    let baseline_path = baseline_dir.join(file);
    if !filepath.exists() {
        return HandlerResult::fail(format!("File not found: {file}"));
    }
    if !baseline_path.exists() {
        return HandlerResult::fail(format!("Baseline not found: {}", baseline_path.display()));
    }
    let h1 = sha256_file(&filepath);
    let h2 = sha256_file(&baseline_path);
    match (h1, h2) {
        (Ok(a), Ok(b)) => {
            let passed = a == b;
            HandlerResult {
                pass: passed,
                detail: format!("SHA match: {passed} ({file})"),
                test_count: None,
                stdout: None,
            }
        }
        (Err(e), _) | (_, Err(e)) => HandlerResult::fail(format!("Hash error: {e}")),
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn load_spec(path: &Path) -> Result<ExpectedSpec> {
    let data = fs::read_to_string(path)
        .with_context(|| format!("reading spec from {}", path.display()))?;
    let spec: ExpectedSpec =
        serde_json::from_str(&data).with_context(|| format!("parsing {}", path.display()))?;
    Ok(spec)
}

/// Count `def test_*` across all `test_*.py` files under `tests/`.
fn count_test_functions(workdir: &Path) -> u64 {
    let tests_dir = workdir.join("tests");
    if !tests_dir.is_dir() {
        return 0;
    }
    let re = Regex::new(r"^\s*def test_").expect("valid regex");
    let mut count: u64 = 0;
    walk_test_files(&tests_dir, &mut |path| {
        if let Ok(content) = fs::read_to_string(path) {
            for line in content.lines() {
                if re.is_match(line) {
                    count += 1;
                }
            }
        }
    });
    count
}

/// Count test files (`test_*.py`) under `tests/`.
fn count_test_files(workdir: &Path) -> u64 {
    let tests_dir = workdir.join("tests");
    if !tests_dir.is_dir() {
        return 0;
    }
    let mut count: u64 = 0;
    walk_test_files(&tests_dir, &mut |_| {
        count += 1;
    });
    count
}

/// Recursively visit every `test_*.py` file under `dir`.
fn walk_test_files(dir: &Path, visitor: &mut impl FnMut(&Path)) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_test_files(&path, visitor);
        } else if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            if name.starts_with("test_") && name.ends_with(".py") {
                visitor(&path);
            }
        }
    }
}

/// Extract the "N passed" count from pytest output.
fn extract_pytest_count(stdout: &str) -> u64 {
    let re = Regex::new(r"(\d+) passed").expect("valid regex");
    re.captures(stdout)
        .and_then(|c| c.get(1))
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0)
}

/// Compute SHA-256 hex digest of a file.
fn sha256_file(path: &Path) -> Result<String> {
    use sha2::{Digest, Sha256};
    let data = fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    let hash = Sha256::digest(&data);
    Ok(format!("{:x}", hash))
}

/// Produce a Python-safe quoted string literal. Uses repr-style single quotes
/// with backslash escaping for internal quotes and backslashes.
fn quote_python_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        match ch {
            '\'' => out.push_str("\\'"),
            '\\' => out.push_str("\\\\"),
            _ => out.push(ch),
        }
    }
    out.push('\'');
    out
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_pytest_count() {
        assert_eq!(extract_pytest_count("5 passed in 0.23s"), 5);
        assert_eq!(extract_pytest_count("12 passed, 1 failed"), 12);
        assert_eq!(extract_pytest_count("no tests ran"), 0);
    }

    #[test]
    fn test_quote_python_string() {
        assert_eq!(quote_python_string("hello"), "'hello'");
        assert_eq!(quote_python_string("it's"), "'it\\'s'");
        assert_eq!(quote_python_string("a\\b"), "'a\\\\b'");
    }

    #[test]
    fn test_score_missing_ticket() {
        let result = score_ticket(
            Path::new("/tmp"),
            "NONEXISTENT-999",
            None,
            Path::new("/tmp"),
        );
        assert!(result.error.is_some());
        assert_eq!(result.score, 0);
    }
}
