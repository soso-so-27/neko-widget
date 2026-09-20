#!/usr/bin/env python3
"""Read-only candidate plan and observed cost, using the release CI selector."""

import argparse
import datetime as dt
import importlib.util
import json
import math
import os
import re
from pathlib import Path
import subprocess
import sys
import urllib.parse

import ios_ci_scope as scope

CI = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("planner", CI / "plan-ios-ci.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)
REPOSITORY = "soso-so-27/neko-widget"
DIAGNOSTIC_WORKFLOW = ".github/workflows/ios-ui-diagnostic.yml"


def github(path, raw=False):
    command = ["gh", "api", path]
    if raw:
        # Capture, never print, Xcode logs containing terminal escape sequences.
        command.append("--allow-escape-sequences")
    result = subprocess.run(command, capture_output=True, text=True,
                            encoding="utf-8", timeout=45,
                            env={**os.environ, "GH_PROMPT_DISABLED": "1", "GH_DEBUG": ""})
    if result.returncode:
        raise ValueError("Cannot read CI history; no expensive retry authorized")
    return result.stdout if raw else json.loads(result.stdout)


def read_task_runs():
    # A task uses matching codex/<task> and diagnostic/<task> branches. Look at
    # both, so a diagnostic push cannot reset the time/failure accounting.
    branch = planner.git("branch", "--show-current")
    if not branch or branch == "main":
        raise ValueError("Preflight requires a dedicated task branch")
    name = branch.removeprefix("codex/").removeprefix("diagnostic/")
    runs = {}
    for ref in {branch, "codex/" + name, "diagnostic/" + name}:
        query = urllib.parse.urlencode({"branch": ref, "per_page": 100})
        page = github(f"repos/{REPOSITORY}/actions/runs?{query}")
        if page["total_count"] >= 100:
            raise ValueError("Task history exceeds 100 runs; review it before continuing")
        for run in page["workflow_runs"]:
            if run.get("path") in {".github/workflows/ios-build.yml", DIAGNOSTIC_WORKFLOW}:
                runs[run["id"]] = run
    for run in runs.values():
        run["failed_ui"] = False
        run["failed_tests"] = []
        run["unsupported_failed_tests"] = []
        if run["path"] == ".github/workflows/ios-build.yml" and run["conclusion"] in {"failure", "timed_out", "cancelled"}:
            jobs = github(f"repos/{REPOSITORY}/actions/runs/{run['id']}/jobs?per_page=100")
            if jobs["total_count"] >= 100:
                raise ValueError("Incomplete failed-job history")
            for job in jobs["jobs"]:
                if "[app-ui;" in job["name"] and job["conclusion"] in {"failure", "timed_out"}:
                    log = github(f"repos/{REPOSITORY}/actions/jobs/{job['id']}/logs", raw=True)
                    cases = sorted(set(re.findall(
                        r"Test Case '-\[([\w.]+) (test\w+)\]' failed", log)))
                    methods = [method for cls, method in cases if cls == "NekoWidgetUITests.MomentDeliveryComposerUITests"]
                    run["unsupported_failed_tests"].extend(f"{cls}/{method}" for cls, method in cases
                                                          if cls != "NekoWidgetUITests.MomentDeliveryComposerUITests")
                    # A preparation/build/runner failure has no failed XCTest;
                    # do not require an unrelated UI test to diagnose it.
                    run["failed_ui"] = bool(cases)
                    run["failed_tests"].extend(methods)
    return list(runs.values())


def apply_task_gate(result, runs, now=None, measure_baseline=False):
    """Release checks stay mandatory; this decides whether to spend again."""
    now = now or dt.datetime.now(dt.timezone.utc)
    parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    elapsed = max(0, (now - min(parse(run["created_at"]) for run in runs)).total_seconds() / 60) if runs else 0
    failed = [run for run in runs if run["status"] == "completed" and
              run["conclusion"] in {"failure", "timed_out", "cancelled", "startup_failure"}]
    active = [run["id"] for run in runs if run["status"] != "completed"]
    diagnostics = [run for run in runs if run["path"] == DIAGNOSTIC_WORKFLOW and
                   run["event"] == "workflow_dispatch" and run["head_sha"] == result["head"] and
                   run["status"] == "completed" and run["conclusion"] == "success"]
    cost = result["cost"]
    projected = round(elapsed + cost["with_upload_minutes"][1], 1) if cost["status"] == "observed" else None
    blockers = []
    if active:
        blockers.append("ci_already_running")
    failed_tests = sorted({test for run in failed for test in run.get("failed_tests", [])})
    passed_tests = {run.get("display_title", "").removeprefix("UI diagnosis: ") for run in diagnostics}
    missing = sorted(set(failed_tests) - passed_tests)
    unsupported = sorted({test for run in failed for test in run.get("unsupported_failed_tests", [])})
    if unsupported:
        blockers.append("failed_test_needs_a_supported_focused_diagnostic_route")
    if missing:
        blockers.append("failed_task_requires_successful_diagnosis_at_candidate_sha")
    first_measurement = measure_baseline and not runs and cost["status"] == "unmeasured"
    if (projected is None and not first_measurement) or (projected is not None and projected > result["target_minutes"]):
        blockers.append("cumulative_cost_requires_replanning")
    result["task"] = {"runs": len(runs), "failed_runs": [run["id"] for run in failed],
                      "active_runs": active, "diagnostic_runs": [run["id"] for run in diagnostics],
                      "missing_diagnostic_tests": missing,
                      "unsupported_failed_tests": unsupported,
                      "minutes_since_first_ci": round(elapsed, 1),
                      "projected_total_minutes": projected, "blockers": blockers}
    result["task"]["first_baseline_measurement"] = first_measurement
    result["ready"] = (result["ready"] or first_measurement) and not blockers
    result["next_action"] = ("Diagnose one failing operation; a prose decision cannot authorize another candidate CI"
                             if missing or unsupported else
                             "Reuse active work or revise the measured execution plan" if blockers else "Run required checks")
    return result


def observe_cost(selected, history, include_upload):
    # Scope-specific historical observations, not a delivery guarantee. Keep
    # failed/retried candidates: the last green job alone hides feedback cost.
    samples = [row for row in history["observations"] if row["scope"] == selected]
    if not samples:
        return {"status": "unmeasured", "samples": []}
    values = [float(row["candidate_minutes"]) for row in samples]
    upload = float(history["upload_minutes"]) if include_upload else 0
    if any(not math.isfinite(value) or value <= 0 for value in values) or not math.isfinite(upload) or upload < 0:
        raise ValueError("Invalid timing observations")
    return {"status": "observed", "ci_minutes": [min(values), max(values)],
            "with_upload_minutes": [round(min(values) + upload, 1), round(max(values) + upload, 1)],
            "samples": samples, "includes_future_rework": False}


def candidate_plan(base, target_minutes, include_upload, history, decision=None):
    # A dirty tree must not be described as the next tested candidate.
    if planner.git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Commit the complete candidate before preflight; working tree is dirty")
    head = planner.git("rev-parse", "HEAD")
    resolved_base = planner.git("rev-parse", "--verify", base + "^{commit}")
    env = {"GITHUB_SHA": head, "GITHUB_EVENT_NAME": "pull_request"}
    event = {"pull_request": {"base": {"sha": resolved_base}}}
    comparison = planner.comparison_base(event, env)
    paths = planner.changed_paths(event, env)
    if not paths:
        return {"head": head, "base": comparison, "scope": "no-change", "required_jobs": [],
                "decision": "no CI needed", "ready": True}
    if all(scope.is_handoff(path) for path in paths):
        return {"head": head, "base": comparison, "scope": "handoff-only", "required_jobs": [],
                "decision": "Handoff paths do not trigger iOS CI", "ready": True}
    selected = planner.runtime_scope(paths, event, env)
    required = planner.required_jobs(paths, selected)
    if required == (planner.BUILD,) and selected != "app-icon-v1":
        selected = "movie-screen-only"
    unmatched = sorted(scope.source_paths(paths) - scope.MAPPED_PATHS)
    reason = ("Development helpers only; app/build/safety/release inputs unchanged"
              if selected == planner.DEVELOPMENT_SCOPE else
              "Unmapped inputs require full checks" if selected == scope.FULL_SCOPE and unmatched else
              "No reviewed limited profile matches this complete change; full checks required"
              if selected == scope.FULL_SCOPE else "Existing selector matched the complete change")
    cost = observe_cost(selected, history, include_upload)
    decision_needed = cost["status"] == "unmeasured" or cost["with_upload_minutes"][1] > target_minutes
    return {"head": head, "base": comparison, "changed_files": paths, "scope": selected,
            "reason": reason, "unmapped_files": unmatched if selected == scope.FULL_SCOPE else [],
            "required_jobs": list(required), "cost": cost, "target_minutes": target_minutes,
            "cost_review_required": decision_needed, "decision": decision,
            "ready": not decision_needed,
            "note": "No tests started, checks waived, or successful evidence reused by this command."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--target-minutes", type=float, default=30)
    parser.add_argument("--include-upload", action="store_true")
    parser.add_argument("--history", type=Path, default=CI / "ci-timing-baseline.json")
    parser.add_argument("--decision", help="Planning note only; cannot override cost or failed-run gates")
    parser.add_argument("--measure-baseline", action="store_true",
                        help="One first measurement for an unmeasured scope; no delivery-time promise or retries")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    if not math.isfinite(args.target_minutes) or args.target_minutes <= 0:
        parser.error("target-minutes must be positive")
    args.history = args.history.resolve()
    if args.output:
        args.output = args.output.resolve()
    # Absolute invocation from another project must still inspect this tool's
    # checkout; resolve caller-provided result/history paths before changing cwd.
    os.chdir(CI.parents[1])
    try:
        history = json.loads(args.history.read_text(encoding="utf-8"))
        result = candidate_plan(args.base, args.target_minutes, args.include_upload, history, args.decision)
        if result["scope"] not in {"no-change", "handoff-only", planner.DEVELOPMENT_SCOPE}:
            result = apply_task_gate(result, read_task_runs(), measure_baseline=args.measure_baseline)
        encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(encoded, encoding="utf-8")
        print(encoded)
        return 0 if result["ready"] else 3
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Preflight stopped: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
