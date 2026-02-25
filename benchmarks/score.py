#!/usr/bin/env python3
"""Anvil Benchmark Quality Scorer.

Scores a benchmark ticket's implementation 0-100 using automated checks.
No LLM involvement - pure static analysis + test execution.

Usage:
    python benchmarks/score.py --workdir PATH --ticket BENCH-N [--baseline PATH]
    python benchmarks/score.py --workdir PATH --ticket BENCH-N --json
"""

import argparse
import ast
import hashlib
import json
import os
import re
import subprocess
import sys


def check_ast_parse(workdir, check):
    """Verify file has valid Python syntax."""
    filepath = os.path.join(workdir, check["file"])
    if not os.path.exists(filepath):
        return {"pass": False, "detail": f"File not found: {check['file']}"}
    try:
        with open(filepath) as f:
            ast.parse(f.read())
        return {"pass": True, "detail": "Valid Python syntax"}
    except SyntaxError as e:
        return {"pass": False, "detail": f"Syntax error: {e}"}


def check_pytest(workdir, check):
    """Run pytest and check exit code."""
    subset = check.get("subset")
    cmd = [sys.executable, "-m", "pytest", "tests/", "-v", "--tb=short"]
    if subset:
        cmd.extend(["-k", subset])
    try:
        result = subprocess.run(
            cmd, cwd=workdir, capture_output=True, text=True, timeout=60
        )
        passed = result.returncode == 0
        match = re.search(r"(\d+) passed", result.stdout)
        count = int(match.group(1)) if match else 0
        return {
            "pass": passed,
            "detail": f"pytest exit={result.returncode}, {count} passed",
            "test_count": count,
            "stdout": result.stdout[-500:] if not passed else "",
        }
    except subprocess.TimeoutExpired:
        return {"pass": False, "detail": "pytest timed out after 60s"}
    except Exception as e:
        return {"pass": False, "detail": f"pytest error: {e}"}


def check_grep_present(workdir, check):
    """Verify regex pattern is found in file."""
    filepath = os.path.join(workdir, check["file"])
    if not os.path.exists(filepath):
        return {"pass": False, "detail": f"File not found: {check['file']}"}
    with open(filepath) as f:
        content = f.read()
    desc = check.get("description", check["pattern"])
    if re.search(check["pattern"], content):
        return {"pass": True, "detail": f"Pattern found: {desc}"}
    return {"pass": False, "detail": f"Pattern not found: {desc}"}


def check_grep_absent(workdir, check):
    """Verify regex pattern is NOT found in file."""
    filepath = os.path.join(workdir, check["file"])
    if not os.path.exists(filepath):
        return {"pass": True, "detail": "File not found (pattern trivially absent)"}
    with open(filepath) as f:
        content = f.read()
    desc = check.get("description", check["pattern"])
    if re.search(check["pattern"], content):
        return {"pass": False, "detail": f"Pattern still present: {desc}"}
    return {"pass": True, "detail": f"Pattern absent: {desc}"}


def check_test_count_minimum(workdir, check):
    """Verify at least N test functions exist."""
    minimum = check["minimum"]
    count = _count_tests(workdir)
    passed = count >= minimum
    return {"pass": passed, "detail": f"Test count: {count} (minimum: {minimum})"}


def check_test_count_increased(workdir, check):
    """Verify test count increased from baseline."""
    baseline = check.get("baseline", 5)
    count = _count_tests(workdir)
    passed = count > baseline
    return {"pass": passed, "detail": f"Test count: {count} (baseline: {baseline})"}


def check_file_unchanged(workdir, check):
    """Verify file SHA-256 matches baseline."""
    filepath = os.path.join(workdir, check["file"])
    baseline_path = check.get("_baseline_path")
    if not baseline_path:
        return {"pass": False, "detail": "No baseline path provided"}
    if not os.path.exists(filepath):
        return {"pass": False, "detail": f"File not found: {check['file']}"}
    if not os.path.exists(baseline_path):
        return {"pass": False, "detail": f"Baseline not found: {baseline_path}"}
    h1 = _sha256(filepath)
    h2 = _sha256(baseline_path)
    passed = h1 == h2
    return {"pass": passed, "detail": f"SHA match: {passed} ({check['file']})"}


def _count_tests(workdir):
    """Count test functions across all test files."""
    count = 0
    tests_dir = os.path.join(workdir, "tests")
    if not os.path.isdir(tests_dir):
        return 0
    for root, _, files in os.walk(tests_dir):
        for fname in files:
            if fname.startswith("test_") and fname.endswith(".py"):
                with open(os.path.join(root, fname)) as f:
                    for line in f:
                        if re.match(r"\s*def test_", line):
                            count += 1
    return count


def _sha256(filepath):
    """Compute SHA-256 of a file."""
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


CHECK_DISPATCH = {
    "ast_parse": check_ast_parse,
    "pytest": check_pytest,
    "pytest_subset": check_pytest,
    "grep_present": check_grep_present,
    "grep_absent": check_grep_absent,
    "test_count_minimum": check_test_count_minimum,
    "test_count_increased": check_test_count_increased,
    "file_unchanged": check_file_unchanged,
}


def score_ticket(workdir, ticket_id, baseline_dir=None):
    """Score a single ticket's implementation.

    Returns a dict with score (0-100), check results, and metadata.
    """
    expected_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "tickets",
        "expected",
        f"{ticket_id}.json",
    )
    if not os.path.exists(expected_path):
        return {"error": f"No expected file for {ticket_id}"}

    with open(expected_path) as f:
        spec = json.load(f)

    results = []
    total_weight = 0
    earned_weight = 0

    for check in spec["checks"]:
        ctype = check["type"]
        handler = CHECK_DISPATCH.get(ctype)
        if not handler:
            results.append(
                {
                    "type": ctype,
                    "pass": False,
                    "weight": check.get("weight", 0),
                    "detail": f"Unknown check type: {ctype}",
                }
            )
            total_weight += check.get("weight", 0)
            continue

        # Inject baseline path for file_unchanged checks
        if ctype == "file_unchanged" and baseline_dir:
            check = dict(check)
            check["_baseline_path"] = os.path.join(baseline_dir, check["file"])

        # For pytest_subset, set subset param
        if ctype == "pytest_subset":
            check = dict(check)
            check["subset"] = check.get("subset", check.get("pattern", ""))

        result = handler(workdir, check)
        weight = check.get("weight", 0)
        total_weight += weight
        if result["pass"]:
            earned_weight += weight

        results.append(
            {
                "type": ctype,
                "pass": result["pass"],
                "weight": weight,
                "detail": result["detail"],
                "description": check.get("description", ""),
            }
        )

    score = round(earned_weight * 100 / total_weight) if total_weight > 0 else 0

    return {
        "ticket": ticket_id,
        "score": score,
        "earned_weight": earned_weight,
        "total_weight": total_weight,
        "checks": results,
    }


def main():
    parser = argparse.ArgumentParser(description="Anvil Benchmark Scorer")
    parser.add_argument(
        "--workdir", required=True, help="Path to project working directory"
    )
    parser.add_argument("--ticket", required=True, help="Ticket ID (e.g., BENCH-1)")
    parser.add_argument(
        "--baseline", default=None, help="Path to baseline (unmodified) project"
    )
    parser.add_argument(
        "--json", action="store_true", help="Output as JSON (default: human-readable)"
    )
    args = parser.parse_args()

    result = score_ticket(args.workdir, args.ticket, args.baseline)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if "error" in result:
            print(f"ERROR: {result['error']}")
            sys.exit(1)
        print(f"\n{'='*50}")
        print(f"  {result['ticket']}: {result['score']}/100")
        print(f"{'='*50}")
        for c in result["checks"]:
            status = "PASS" if c["pass"] else "FAIL"
            desc = c.get("description") or c["type"]
            print(f"  [{status}] {desc} (weight: {c['weight']})")
            if not c["pass"] and c.get("detail"):
                print(f"         {c['detail']}")
        print()

    sys.exit(0 if result.get("score", 0) > 0 else 1)


if __name__ == "__main__":
    main()
