//! Watchdog: monitors Claude subprocess for inactivity.
//!
//! If Claude produces no stdout/stderr for `inactivity_timeout` seconds,
//! the watchdog concludes it's stuck waiting for human input and intervenes:
//!
//! 1. Sends an autonomous-mode nudge via stdin
//! 2. If still stuck, kills and restarts with augmented prompt
//! 3. After max_restarts, aborts with WatchdogExhausted

use anyhow::Result;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

use crate::types::WatchdogOutcome;

const NUDGE_MSG: &str = "\nYou are in AUTONOMOUS mode. There is NO human available. \
    Do not wait for input. Proceed with your task immediately.\n";

const NUDGE_GRACE_SECS: u64 = 30;

/// Run a command with watchdog monitoring.
///
/// - `phase_timeout`: hard wall-clock limit for the entire phase
/// - `inactivity_timeout`: seconds of no output before watchdog activates
/// - `max_restarts`: how many times watchdog can kill-and-restart
pub async fn run_with_watchdog(
    cmd_builder: impl Fn() -> Command,
    phase_timeout: Duration,
    inactivity_timeout: Duration,
    max_restarts: u32,
) -> Result<WatchdogOutcome> {
    let deadline = Instant::now() + phase_timeout;
    let mut total_restarts: u32 = 0;
    let mut accumulated_stdout = Vec::new();
    let mut accumulated_stderr = Vec::new();

    loop {
        // Check if we've exceeded the phase deadline
        if Instant::now() >= deadline {
            return Ok(WatchdogOutcome {
                stdout: accumulated_stdout,
                stderr: accumulated_stderr,
                exit_code: 124,
                timed_out: true,
                watchdog_killed: false,
                watchdog_restarts: total_restarts,
            });
        }

        let mut cmd = cmd_builder();
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        cmd.stdin(std::process::Stdio::piped());

        let mut child = cmd.spawn()?;

        let mut stdout = child.stdout.take().unwrap();
        let mut stderr = child.stderr.take().unwrap();
        let mut stdin = child.stdin.take();

        let mut stdout_buf = vec![0u8; 4096];
        let mut stderr_buf = vec![0u8; 4096];
        let mut last_activity = Instant::now();
        let mut nudged = false;

        let outcome = loop {
            // Hard deadline check
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                let _ = child.kill().await;
                break LoopOutcome::PhaseTimeout;
            }

            let inactivity_elapsed = last_activity.elapsed();
            let inactivity_remaining = if nudged {
                // After nudge, give a shorter grace period
                Duration::from_secs(NUDGE_GRACE_SECS)
                    .saturating_sub(inactivity_elapsed.saturating_sub(inactivity_timeout))
            } else {
                inactivity_timeout.saturating_sub(inactivity_elapsed)
            };

            tokio::select! {
                biased;

                // Process exit — highest priority
                status = child.wait() => {
                    // Drain remaining output
                    let mut rest = Vec::new();
                    let _ = stdout.read_to_end(&mut rest).await;
                    accumulated_stdout.extend_from_slice(&rest);
                    let mut rest = Vec::new();
                    let _ = stderr.read_to_end(&mut rest).await;
                    accumulated_stderr.extend_from_slice(&rest);

                    let code = status.map(|s| s.code().unwrap_or(-1)).unwrap_or(-1);
                    break LoopOutcome::Completed(code);
                }

                // stdout data
                n = stdout.read(&mut stdout_buf) => {
                    match n {
                        Ok(0) => {} // EOF — process likely exiting
                        Ok(n) => {
                            accumulated_stdout.extend_from_slice(&stdout_buf[..n]);
                            last_activity = Instant::now();
                            nudged = false;
                        }
                        Err(_) => {}
                    }
                }

                // stderr data
                n = stderr.read(&mut stderr_buf) => {
                    match n {
                        Ok(0) => {}
                        Ok(n) => {
                            accumulated_stderr.extend_from_slice(&stderr_buf[..n]);
                            last_activity = Instant::now();
                            nudged = false;
                        }
                        Err(_) => {}
                    }
                }

                // Inactivity timeout
                _ = tokio::time::sleep(inactivity_remaining.min(remaining)) => {
                    if last_activity.elapsed() >= inactivity_timeout && !nudged {
                        // Level 1: stdin nudge
                        if let Some(ref mut s) = stdin {
                            tracing::warn!("Watchdog: {}s inactivity, sending nudge", inactivity_timeout.as_secs());
                            let _ = s.write_all(NUDGE_MSG.as_bytes()).await;
                            let _ = s.flush().await;
                            nudged = true;
                            last_activity = Instant::now();
                        } else {
                            // No stdin — kill directly
                            let _ = child.kill().await;
                            break LoopOutcome::InactivityKill;
                        }
                    } else if nudged && last_activity.elapsed() >= inactivity_timeout + Duration::from_secs(NUDGE_GRACE_SECS) {
                        // Level 2: nudge didn't work — kill
                        tracing::warn!("Watchdog: nudge failed, killing subprocess");
                        let _ = child.kill().await;
                        break LoopOutcome::InactivityKill;
                    }
                }
            }
        };

        match outcome {
            LoopOutcome::Completed(code) => {
                return Ok(WatchdogOutcome {
                    stdout: accumulated_stdout,
                    stderr: accumulated_stderr,
                    exit_code: code,
                    timed_out: false,
                    watchdog_killed: false,
                    watchdog_restarts: total_restarts,
                });
            }
            LoopOutcome::PhaseTimeout => {
                return Ok(WatchdogOutcome {
                    stdout: accumulated_stdout,
                    stderr: accumulated_stderr,
                    exit_code: 124,
                    timed_out: true,
                    watchdog_killed: false,
                    watchdog_restarts: total_restarts,
                });
            }
            LoopOutcome::InactivityKill => {
                total_restarts += 1;
                if total_restarts > max_restarts {
                    tracing::error!("Watchdog: exhausted {} restarts, aborting", max_restarts);
                    return Ok(WatchdogOutcome {
                        stdout: accumulated_stdout,
                        stderr: accumulated_stderr,
                        exit_code: 125,
                        timed_out: false,
                        watchdog_killed: true,
                        watchdog_restarts: total_restarts,
                    });
                }
                tracing::warn!(
                    "Watchdog: restart {}/{} — will augment prompt",
                    total_restarts,
                    max_restarts
                );
                // Loop continues — caller should augment the prompt in cmd_builder
            }
        }
    }
}

#[derive(Debug)]
enum LoopOutcome {
    Completed(i32),
    PhaseTimeout,
    InactivityKill,
}
