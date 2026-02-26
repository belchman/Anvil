//! MCP (Model Context Protocol) server over stdio.
//!
//! Implements JSON-RPC 2.0 over newline-delimited stdin/stdout so that Claude
//! Code can call Anvil tools natively inside a session.

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::config;
use crate::scorer;
use crate::types::{Phase, Tier};

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 types
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct JsonRpcRequest {
    #[allow(dead_code)]
    jsonrpc: String,
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Option<Value>,
}

#[derive(Serialize)]
struct JsonRpcResponse {
    jsonrpc: String,
    id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<JsonRpcError>,
}

#[derive(Serialize)]
struct JsonRpcError {
    code: i64,
    message: String,
}

impl JsonRpcResponse {
    fn success(id: Value, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(result),
            error: None,
        }
    }

    fn error(id: Value, code: i64, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(JsonRpcError {
                code,
                message: message.into(),
            }),
        }
    }
}

// ---------------------------------------------------------------------------
// MCP tool definitions
// ---------------------------------------------------------------------------

fn tool_definitions() -> Value {
    serde_json::json!({
        "tools": [
            {
                "name": "anvil_run",
                "description": "Run the Anvil pipeline on a ticket. Executes the full spec-to-PR pipeline with BDD enforcement, phase gates, and cost controls.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "ticket": {
                            "type": "string",
                            "description": "Ticket ID or feature description"
                        },
                        "tier": {
                            "type": "string",
                            "enum": ["guard", "nano", "quick", "lite", "standard", "full", "auto"],
                            "description": "Pipeline tier (default: auto)",
                            "default": "auto"
                        },
                        "max_budget": {
                            "type": "number",
                            "description": "Maximum pipeline cost in USD"
                        }
                    },
                    "required": ["ticket"]
                }
            },
            {
                "name": "anvil_plan",
                "description": "Show what phases would run for a given ticket and tier (dry run). Does not execute anything.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "ticket": {
                            "type": "string",
                            "description": "Ticket ID or feature description"
                        },
                        "tier": {
                            "type": "string",
                            "enum": ["guard", "nano", "quick", "lite", "standard", "full", "auto"],
                            "description": "Pipeline tier (default: auto)",
                            "default": "auto"
                        }
                    },
                    "required": ["ticket"]
                }
            },
            {
                "name": "anvil_score",
                "description": "Score a benchmark ticket's implementation. Runs automated checks (AST parse, pytest, grep patterns) and returns a 0-100 quality score. No LLM involvement.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "workdir": {
                            "type": "string",
                            "description": "Path to the project working directory"
                        },
                        "ticket_id": {
                            "type": "string",
                            "description": "Benchmark ticket ID (e.g. BENCH-1)"
                        },
                        "target": {
                            "type": "string",
                            "description": "Target project name under benchmarks/ (default: target)",
                            "default": "target"
                        }
                    },
                    "required": ["workdir", "ticket_id"]
                }
            },
            {
                "name": "anvil_info",
                "description": "Show current Anvil configuration including tier, cost limits, turn limits, budget categories, watchdog settings, and model assignments.",
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            }
        ]
    })
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

async fn handle_anvil_run(params: &Value) -> Value {
    let ticket = params
        .get("ticket")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    if ticket.is_empty() {
        return tool_error("Missing required parameter: ticket");
    }

    let tier_str = params
        .get("tier")
        .and_then(|v| v.as_str())
        .unwrap_or("auto");
    let tier: Tier = tier_str.parse().unwrap_or(Tier::Auto);

    let max_budget = params.get("max_budget").and_then(|v| v.as_f64());

    let config_path = PathBuf::from("anvil.toml");

    let cfg = match config::build_config(
        &config_path,
        Some(tier).filter(|t| *t != Tier::Auto),
        max_budget,
        None,
    ) {
        Ok(mut c) => {
            if tier != Tier::Auto {
                c.tier = tier;
            }
            c
        }
        Err(e) => {
            return tool_error(&format!("Failed to load config: {e}"));
        }
    };

    match crate::pipeline::run(&cfg, &ticket).await {
        Ok(exit_code) => {
            let status = match exit_code {
                0 => "completed",
                3 => "blocked",
                4 => "holdout_failed",
                _ => "error",
            };
            tool_result(&format!(
                "Pipeline {status} (exit code {exit_code}) for ticket: {ticket}"
            ))
        }
        Err(e) => tool_error(&format!("Pipeline error: {e}")),
    }
}

fn handle_anvil_plan(params: &Value) -> Value {
    let ticket = params.get("ticket").and_then(|v| v.as_str()).unwrap_or("");
    let tier_str = params
        .get("tier")
        .and_then(|v| v.as_str())
        .unwrap_or("auto");
    let tier: Tier = tier_str.parse().unwrap_or(Tier::Auto);

    let all_phases = [
        Phase::Phase0,
        Phase::Interrogate,
        Phase::InterrogationReview,
        Phase::GenerateDocs,
        Phase::DocReview,
        Phase::WriteSpecs,
        Phase::HoldoutGenerate,
        Phase::Implement,
        Phase::Verify,
        Phase::HoldoutValidate,
        Phase::SecurityAudit,
        Phase::Ship,
    ];
    let skipped = Phase::skipped_by(tier);

    let phases: Vec<Value> = all_phases
        .iter()
        .map(|p| {
            let will_run = !skipped.contains(p);
            serde_json::json!({
                "phase": p.as_str(),
                "status": if will_run { "run" } else { "skip" }
            })
        })
        .collect();

    let mut lines = Vec::new();
    lines.push(format!("Anvil Plan for: {ticket}"));
    lines.push(format!("Tier: {tier}"));
    lines.push(String::new());
    for p in &all_phases {
        let will_run = !skipped.contains(p);
        let marker = if will_run { "run " } else { "skip" };
        lines.push(format!("  [{marker}] {p}"));
    }

    serde_json::json!([{
        "type": "text",
        "text": lines.join("\n"),
        "isError": false,
        "_meta": {
            "ticket": ticket,
            "tier": tier.to_string(),
            "phases": phases
        }
    }])
}

fn handle_anvil_score(params: &Value) -> Value {
    let workdir = params.get("workdir").and_then(|v| v.as_str()).unwrap_or("");
    let ticket_id = params
        .get("ticket_id")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let target = params
        .get("target")
        .and_then(|v| v.as_str())
        .unwrap_or("target");

    if workdir.is_empty() {
        return tool_error("Missing required parameter: workdir");
    }
    if ticket_id.is_empty() {
        return tool_error("Missing required parameter: ticket_id");
    }

    let workdir_path = Path::new(workdir);
    if !workdir_path.exists() {
        return tool_error(&format!("Working directory does not exist: {workdir}"));
    }

    // The expected specs live under benchmarks/
    let expected_dir = PathBuf::from("benchmarks");

    // Baseline is the unmodified target dir
    let baseline_dir = expected_dir.join(target);
    let baseline = if baseline_dir.exists() {
        Some(baseline_dir.as_path())
    } else {
        None
    };

    let result = scorer::score_ticket(workdir_path, ticket_id, baseline, &expected_dir);

    let text = format!(
        "Score: {}/100 (earned {}/{} weight)\nTicket: {}\n\nChecks:\n{}",
        result.score,
        result.earned_weight,
        result.total_weight,
        result.ticket,
        result
            .checks
            .iter()
            .map(|c| format!(
                "  [{}] {} (weight {}) - {}",
                if c.pass { "PASS" } else { "FAIL" },
                c.check_type,
                c.weight,
                c.detail
            ))
            .collect::<Vec<_>>()
            .join("\n")
    );

    serde_json::json!([{
        "type": "text",
        "text": text,
        "isError": false,
        "_meta": {
            "score": result.score,
            "earned_weight": result.earned_weight,
            "total_weight": result.total_weight,
            "ticket": result.ticket,
            "checks": result.checks,
            "error": result.error
        }
    }])
}

fn handle_anvil_info() -> Value {
    let config_path = PathBuf::from("anvil.toml");

    let cfg = config::build_config(&config_path, None, None, None).unwrap_or_default();

    let text = format!(
        "Anvil v{}\n\
         Tier: {}\n\
         Max pipeline cost: ${:.2}\n\
         Turns: quick={}, medium={}, long={}\n\
         Budgets: low=${:.2}, medium=${:.2}, high=${:.2}\n\
         Watchdog: {}s inactivity, {} max restarts\n\
         Stagnation similarity: {:.0}%\n\
         Verify retries: {}\n\
         Validator: {}",
        cfg.anvil_version,
        cfg.tier,
        cfg.max_pipeline_cost,
        cfg.turns_quick,
        cfg.turns_medium,
        cfg.turns_long,
        cfg.budget_low,
        cfg.budget_medium,
        cfg.budget_high,
        cfg.interaction_timeout_secs,
        cfg.interaction_max_retries,
        cfg.stagnation_similarity * 100.0,
        cfg.max_verify_retries,
        cfg.review_validator_command.as_deref().unwrap_or("none"),
    );

    serde_json::json!([{
        "type": "text",
        "text": text,
        "isError": false
    }])
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn tool_result(text: &str) -> Value {
    serde_json::json!([{
        "type": "text",
        "text": text,
        "isError": false
    }])
}

fn tool_error(text: &str) -> Value {
    serde_json::json!([{
        "type": "text",
        "text": text,
        "isError": true
    }])
}

// ---------------------------------------------------------------------------
// JSON-RPC dispatch
// ---------------------------------------------------------------------------

async fn dispatch(req: &JsonRpcRequest) -> Option<JsonRpcResponse> {
    match req.method.as_str() {
        "initialize" => {
            let id = req.id.clone().unwrap_or(Value::Null);
            Some(JsonRpcResponse::success(
                id,
                serde_json::json!({
                    "protocolVersion": "2025-06-18",
                    "capabilities": {
                        "tools": { "listChanged": false }
                    },
                    "serverInfo": {
                        "name": "anvil",
                        "version": "4.0.0"
                    }
                }),
            ))
        }

        "notifications/initialized" => {
            // Client notification — no response required
            None
        }

        "tools/list" => {
            let id = req.id.clone().unwrap_or(Value::Null);
            Some(JsonRpcResponse::success(id, tool_definitions()))
        }

        "tools/call" => {
            let id = req.id.clone().unwrap_or(Value::Null);
            let params = req.params.as_ref();

            let tool_name = params
                .and_then(|p| p.get("name"))
                .and_then(|n| n.as_str())
                .unwrap_or("");

            let arguments = params
                .and_then(|p| p.get("arguments"))
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));

            let content = match tool_name {
                "anvil_run" => handle_anvil_run(&arguments).await,
                "anvil_plan" => handle_anvil_plan(&arguments),
                "anvil_score" => handle_anvil_score(&arguments),
                "anvil_info" => handle_anvil_info(),
                unknown => tool_error(&format!("Unknown tool: {unknown}")),
            };

            Some(JsonRpcResponse::success(
                id,
                serde_json::json!({ "content": content }),
            ))
        }

        // Unknown methods that carry an id get an error response
        _ => req.id.clone().map(|id| {
            JsonRpcResponse::error(id, -32601, format!("Method not found: {}", req.method))
        }),
    }
}

// ---------------------------------------------------------------------------
// Main serve loop
// ---------------------------------------------------------------------------

/// Run the MCP server, reading JSON-RPC from stdin and writing to stdout.
pub async fn serve() -> Result<()> {
    eprintln!("Anvil MCP server starting (stdio mode)");

    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();

    for line_result in stdin.lock().lines() {
        let line = match line_result {
            Ok(l) => l,
            Err(e) => {
                eprintln!("stdin read error: {e}");
                break;
            }
        };

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let req: JsonRpcRequest = match serde_json::from_str(trimmed) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("JSON parse error: {e} | input: {trimmed}");
                // Send a parse error response with null id
                let resp = JsonRpcResponse::error(Value::Null, -32700, "Parse error");
                let json = serde_json::to_string(&resp).unwrap_or_default();
                let _ = writeln!(stdout, "{json}");
                let _ = stdout.flush();
                continue;
            }
        };

        if let Some(resp) = dispatch(&req).await {
            let json = serde_json::to_string(&resp).unwrap_or_default();
            writeln!(stdout, "{json}")?;
            stdout.flush()?;
        }
    }

    eprintln!("Anvil MCP server shutting down");
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tool_definitions_valid_json() {
        let defs = tool_definitions();
        let tools = defs.get("tools").unwrap().as_array().unwrap();
        assert_eq!(tools.len(), 4);

        let names: Vec<&str> = tools
            .iter()
            .map(|t| t.get("name").unwrap().as_str().unwrap())
            .collect();
        assert!(names.contains(&"anvil_run"));
        assert!(names.contains(&"anvil_plan"));
        assert!(names.contains(&"anvil_score"));
        assert!(names.contains(&"anvil_info"));
    }

    #[tokio::test]
    async fn test_dispatch_initialize() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(serde_json::json!(1)),
            method: "initialize".to_string(),
            params: None,
        };
        let resp = dispatch(&req).await.unwrap();
        let result = resp.result.unwrap();
        assert_eq!(
            result.get("protocolVersion").unwrap().as_str().unwrap(),
            "2025-06-18"
        );
        assert_eq!(
            result
                .get("serverInfo")
                .unwrap()
                .get("name")
                .unwrap()
                .as_str()
                .unwrap(),
            "anvil"
        );
    }

    #[tokio::test]
    async fn test_dispatch_tools_list() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(serde_json::json!(2)),
            method: "tools/list".to_string(),
            params: None,
        };
        let resp = dispatch(&req).await.unwrap();
        let result = resp.result.unwrap();
        let tools = result.get("tools").unwrap().as_array().unwrap();
        assert_eq!(tools.len(), 4);
    }

    #[tokio::test]
    async fn test_dispatch_notification_no_response() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: None,
            method: "notifications/initialized".to_string(),
            params: None,
        };
        let resp = dispatch(&req).await;
        assert!(resp.is_none());
    }

    #[tokio::test]
    async fn test_dispatch_unknown_method() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(serde_json::json!(99)),
            method: "nonexistent/method".to_string(),
            params: None,
        };
        let resp = dispatch(&req).await.unwrap();
        assert!(resp.error.is_some());
        assert_eq!(resp.error.unwrap().code, -32601);
    }

    #[tokio::test]
    async fn test_tools_call_plan() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(serde_json::json!(3)),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "anvil_plan",
                "arguments": {
                    "ticket": "TEST-1",
                    "tier": "nano"
                }
            })),
        };
        let resp = dispatch(&req).await.unwrap();
        let result = resp.result.unwrap();
        let content = result.get("content").unwrap().as_array().unwrap();
        assert!(!content.is_empty());
        let text = content[0].get("text").unwrap().as_str().unwrap();
        assert!(text.contains("TEST-1"));
        assert!(text.contains("nano"));
    }

    #[tokio::test]
    async fn test_tools_call_unknown_tool() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(serde_json::json!(4)),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "nonexistent_tool",
                "arguments": {}
            })),
        };
        let resp = dispatch(&req).await.unwrap();
        let result = resp.result.unwrap();
        let content = result.get("content").unwrap().as_array().unwrap();
        let is_error = content[0].get("isError").unwrap().as_bool().unwrap();
        assert!(is_error);
    }

    #[tokio::test]
    async fn test_tools_call_info() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(serde_json::json!(5)),
            method: "tools/call".to_string(),
            params: Some(serde_json::json!({
                "name": "anvil_info",
                "arguments": {}
            })),
        };
        let resp = dispatch(&req).await.unwrap();
        let result = resp.result.unwrap();
        let content = result.get("content").unwrap().as_array().unwrap();
        let text = content[0].get("text").unwrap().as_str().unwrap();
        assert!(text.contains("Anvil v"));
    }

    #[test]
    fn test_tool_result_format() {
        let result = tool_result("hello world");
        let arr = result.as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["type"], "text");
        assert_eq!(arr[0]["text"], "hello world");
        assert_eq!(arr[0]["isError"], false);
    }

    #[test]
    fn test_tool_error_format() {
        let result = tool_error("something broke");
        let arr = result.as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["type"], "text");
        assert_eq!(arr[0]["text"], "something broke");
        assert_eq!(arr[0]["isError"], true);
    }
}
