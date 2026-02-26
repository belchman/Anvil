//! Stagnation detection: identifies when retry attempts produce the same errors.

use similar::TextDiff;
use std::path::Path;

/// Check if the current attempt's errors are too similar to the previous attempt.
/// Returns true if similarity exceeds threshold (0.0-1.0).
pub fn check_stagnation(log_dir: &Path, phase_name: &str, attempt: u32, threshold: f64) -> bool {
    if attempt <= 1 {
        return false;
    }

    let prev_path = log_dir.join(format!("{}-attempt-{}.stderr", phase_name, attempt - 1));
    let curr_path = log_dir.join(format!("{}-attempt-{}.stderr", phase_name, attempt));

    let (prev_text, curr_text) = match (
        std::fs::read_to_string(&prev_path),
        std::fs::read_to_string(&curr_path),
    ) {
        (Ok(p), Ok(c)) => (p, c),
        _ => return false,
    };

    if prev_text.is_empty() || curr_text.is_empty() {
        return false;
    }

    // Fast path: identical content
    if prev_text == curr_text {
        tracing::warn!(
            "Stagnation: attempt {} errors identical to attempt {}",
            attempt,
            attempt - 1
        );
        return true;
    }

    // Similarity ratio
    let diff = TextDiff::from_lines(&prev_text, &curr_text);
    let ratio = diff.ratio();

    if (ratio as f64) >= threshold {
        tracing::warn!(
            "Stagnation: attempt {} is {:.0}% similar to attempt {} (threshold: {:.0}%)",
            attempt,
            ratio * 100.0,
            attempt - 1,
            threshold * 100.0,
        );
        return true;
    }

    false
}
