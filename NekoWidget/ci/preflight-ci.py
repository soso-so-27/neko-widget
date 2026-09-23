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
# Deliberately narrower than DEVELOPMENT_PATHS. No workflow, selector, test
# runner, app/test fixture, watch, docs or timing changes inherit UI evidence.
# The native diagnostic graph neither reads nor executes verify-app-icon.py;
# its Simulator preparation runs in the separate Release Build job. If the
# diagnostic graph begins reading it, re-review and remove this exception
# before reusing evidence.
DIAGNOSTIC_HELPER_PATHS = frozenset({
    "NekoWidget/ci/preflight-ci.py", "NekoWidget/ci/test-preflight-ci.py",
    "NekoWidget/ci/verify-app-icon.py",
})
DIAGNOSTIC_JOB_NAMES = frozenset({
    "Diagnostic only - one native UI test (not release evidence)",
    "Diagnostic only - up to three native UI tests (not release evidence)",
})


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


def read_task_runs(head=None):
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
            if run.get("path") in {".github/workflows/ios-build.yml", DIAGNOSTIC_WORKFLOW,
                                   planner.JPEG_WORKFLOW, planner.PRESERVATION_WORKFLOW}:
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
                if "[app-ui" in job["name"] and job["conclusion"] in {"failure", "timed_out"}:
                    log = github(f"repos/{REPOSITORY}/actions/jobs/{job['id']}/logs", raw=True)
                    cases = sorted(set(re.findall(
                        r"Test Case '-\[([\w.]+) (test\w+)\]' failed", log)))
                    supported = {"NekoWidgetUITests." + cls for cls in scope.DIAGNOSTIC_CLASSES}
                    methods = [f"{cls.removeprefix('NekoWidgetUITests.')}/{method}" for cls, method in cases if cls in supported]
                    run["unsupported_failed_tests"].extend(f"{cls}/{method}" for cls, method in cases
                                                          if cls not in supported)
                    # A preparation/build/runner failure has no failed XCTest;
                    # do not require an unrelated UI test to diagnose it.
                    run["failed_ui"] = run["failed_ui"] or bool(cases)
                    run["failed_tests"].extend(methods)
        if (run["path"] == DIAGNOSTIC_WORKFLOW and run.get("status") == "completed"
                and run.get("event") == "workflow_dispatch"
                and run.get("head_branch", "").startswith("diagnostic/")):
            if head is None:
                head = planner.git("rev-parse", "HEAD")
            if diagnostic_source_matches(run.get("head_sha", ""), head):
                run["diagnostic_evidence"] = read_diagnostic_evidence(run, head)
    return list(runs.values())


def diagnostic_title_tests(title):
    prefix = "UI diagnosis: "
    if not title.startswith(prefix):
        return set()
    value = title[len(prefix):]
    if "/" in value:
        test_class, methods = value.split("/", 1)
    else:
        # Historical one-method runs always used MomentDeliveryComposerUITests.
        test_class, methods = "MomentDeliveryComposerUITests", value
        if "," in methods:
            return set()
    try:
        return {test.removeprefix("NekoWidgetUITests/") for test in scope.diagnostic_tests(test_class, methods)}
    except ValueError:
        return set()


def diagnostic_source_matches(source, head):
    """A diagnosis only; never release evidence reuse or a selector exception."""
    if not all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) for value in (source, head)):
        return False
    if source == head:
        return True
    try:
        planner.git("merge-base", "--is-ancestor", source, head)
        raw = planner.git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head)
    except subprocess.CalledProcessError:
        return False
    records = raw.split("\0")
    if records[-1:] == [""]:
        records.pop()
    if len(records) % 2:
        return False
    seen = set()
    for index in range(0, len(records), 2):
        fields, path = records[index].split(), records[index + 1]
        if (path not in DIAGNOSTIC_HELPER_PATHS or path in seen or len(fields) != 5
                or fields[:2] != [":100644", "100644"] or fields[4] != "M"
                or not all(re.fullmatch(r"[0-9a-f]{40}", value) and value != "0" * 40 for value in fields[2:4])):
            return False
        seen.add(path)
    # Examining the entire raw diff also proves equality of every other tracked
    # path, including its mode/type. Added/deleted/renamed/symlink helpers fail.
    return True


def diagnostic_case_results(declared, log):
    events = re.findall(r"Test Case '-\[([^\]]+)\]' (started|passed|failed|skipped)", log)
    expected = {"NekoWidgetUITests." + test.replace("/", " "): test for test in declared}
    if any(case not in expected for case, _ in events):
        return {test: "invalid" for test in declared}
    results = {}
    for case, test in expected.items():
        statuses = [status for name, status in events if name == case]
        if statuses == ["started", "passed"]:
            results[test] = "passed"
        elif statuses in (["started", "failed"], ["started", "skipped"]):
            results[test] = statuses[-1]
        elif statuses in ([], ["started"]):
            results[test] = "incomplete"
        else:
            # Duplicate/reordered outcomes make the whole transcript ambiguous.
            return {method: "invalid" for method in declared}
    return results


def read_diagnostic_evidence(run, head):
    declared = diagnostic_title_tests(run.get("display_title", ""))
    attempt = run.get("run_attempt")
    if not declared or type(attempt) is not int or attempt < 1:
        raise ValueError("Diagnostic declaration or attempt is missing")
    jobs = github(f"repos/{REPOSITORY}/actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100")
    if jobs.get("total_count") != 1 or len(jobs.get("jobs", [])) != 1:
        raise ValueError("Diagnostic must have exactly one supported job in the requested attempt")
    job = jobs["jobs"][0]
    if (job.get("name") not in DIAGNOSTIC_JOB_NAMES or job.get("run_id") != run["id"]
            or job.get("run_attempt") != attempt or job.get("head_sha") != run["head_sha"]
            or job.get("status") != "completed" or not job.get("conclusion")
            or not job.get("started_at") or not job.get("completed_at")):
        raise ValueError("Diagnostic job identity, attempt or completion does not match")
    if job.get("conclusion") == "cancelled" and job.get("steps") == []:
        # GitHub may have no log when cancellation precedes every step. This
        # proves no passes; keep each declaration incomplete until a later run.
        results = {test: "incomplete" for test in declared}
    else:
        # Missing steps or any step still requires the exact completed job log.
        # Never merge an earlier attempt or parse a live tail.
        log = github(f"repos/{REPOSITORY}/actions/jobs/{job['id']}/logs", raw=True)
        results = diagnostic_case_results(declared, log)
    return {"head": head, "source_sha": run["head_sha"], "run_attempt": attempt, "job_id": job["id"],
            "started_at": job["started_at"], "results": results}


def apply_task_gate(result, runs, now=None, measure_baseline=False):
    """Release checks stay mandatory; this decides whether to spend again."""
    now = now or dt.datetime.now(dt.timezone.utc)
    parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    elapsed = max(0, (now - min(parse(run["created_at"]) for run in runs)).total_seconds() / 60) if runs else 0
    failed = [run for run in runs if run["status"] == "completed" and
              run["conclusion"] in {"failure", "timed_out", "cancelled", "startup_failure"}]
    active = [run["id"] for run in runs if run["status"] != "completed"]
    diagnostics = [run for run in runs if run["path"] == DIAGNOSTIC_WORKFLOW and
                   run.get("event") == "workflow_dispatch" and
                   run.get("head_branch", "").startswith("diagnostic/") and run["status"] == "completed" and
                   run.get("diagnostic_evidence", {}).get("head") == result["head"] and
                   run["diagnostic_evidence"].get("source_sha") == run.get("head_sha") and
                   run["diagnostic_evidence"].get("run_attempt") == run.get("run_attempt") and
                   set(run["diagnostic_evidence"].get("results", {})) == diagnostic_title_tests(run.get("display_title", ""))]
    cost = result["cost"]
    projected = round(elapsed + cost["with_upload_minutes"][1], 1) if cost["status"] in {"observed", "reference"} else None
    blockers = []
    if active:
        blockers.append("ci_already_running")
    failed_tests = sorted({test if "/" in test else "MomentDeliveryComposerUITests/" + test
                           for run in failed for test in run.get("failed_tests", [])})
    latest = {}
    for run in sorted(diagnostics, key=lambda item: (
            parse(item["diagnostic_evidence"]["started_at"]), item["id"], item["diagnostic_evidence"]["run_attempt"])):
        evidence = run["diagnostic_evidence"]
        for test, outcome in evidence["results"].items():
            latest[test] = {"outcome": outcome, "run_id": run["id"], "run_attempt": evidence["run_attempt"],
                            "job_id": evidence["job_id"], "source_sha": evidence["source_sha"]}
    # Later failure/skip/incomplete evidence invalidates older passes for that
    # case. A later run selecting only another case leaves its peers untouched.
    failed_tests = sorted(set(failed_tests) | {test for test, value in latest.items() if value["outcome"] != "passed"})
    passed_tests = {test for test, value in latest.items() if value["outcome"] == "passed"}
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
                      "diagnostic_cases": latest,
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


def observe_cost(selected, history, include_upload, use_full_baseline=False):
    # Scope-specific historical observations, not a delivery guarantee. Keep
    # failed/retried candidates: the last green job alone hides feedback cost.
    if selected in (planner.JPEG_SCOPE, planner.PRESERVATION_SCOPE) and include_upload:
        raise ValueError("A backend-only scope cannot authorize or estimate an iOS upload")
    if use_full_baseline and selected not in (scope.REVIEWED_MEMORY_FAMILY_SCOPE, scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE,
                                             scope.REVIEWED_MANAGED_PRESERVATION_SCOPE):
        raise ValueError("Full baseline reference is limited to the reviewed memory-v3, membership-access and managed-preservation-v2 profiles")
    samples = [row for row in history["observations"] if row["scope"] == selected]
    # A new backend allowlist (including preservation v6) is unmeasured even when its unchanged
    # job has observations under an older scope (for example service v1/v2).
    if not samples:
        if use_full_baseline:
            # These reviewed profiles keep full's build/runtime jobs and select
            # native operations from its suites. This is only a cost reference.
            # A new job or test class would need a new measurement/review.
            full_tests = scope.native_tests(scope.FULL_SCOPE)
            selected_tests = scope.native_tests(selected)
            expected_jobs = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected)
            if (planner.required_jobs_from_scope(selected) != expected_jobs
                    or not {"runtime", "app-ui"} <= set(scope.lanes(selected))
                    or not set(scope.lanes(selected)) <= (set(scope.lanes(scope.FULL_SCOPE)) | {"app-ui"})
                    or not selected_tests or len(selected_tests) != len(set(selected_tests))
                    or not set(scope.smoke_tests(selected)) <= set(scope.smoke_tests(scope.FULL_SCOPE))
                    or any(not any(test == full or test.startswith(full + "/") for full in full_tests)
                           for test in selected_tests)):
                raise ValueError("The requested profile is not covered by the observed full route")
            reference = observe_cost(scope.FULL_SCOPE, history, include_upload)
            if reference["status"] != "observed":
                raise ValueError("An actual full-v1 timing observation is required")
            maximum = reference["ci_minutes"][1]
            with_upload = reference["with_upload_minutes"][1]
            return {"status": "reference", "scope_unmeasured": True, "reference_scope": scope.FULL_SCOPE,
                    "ci_minutes": [maximum, maximum], "with_upload_minutes": [with_upload, with_upload],
                    "reference_upper_minutes": with_upload, "samples": [], "reference_samples": reference["samples"],
                    "includes_future_rework": False,
                    "note": "Full-route historical maximum used for planning; this profile is unmeasured and this is not a runtime guarantee."}
        if selected in (planner.JPEG_SCOPE, planner.PRESERVATION_SCOPE):
            timeout = (planner.JPEG_JOB_TIMEOUT_MINUTES if selected == planner.JPEG_SCOPE
                       else planner.PRESERVATION_JOB_TIMEOUT_MINUTES)
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeout_minutes": timeout,
                    "note": f"First measurement only. {timeout} minutes is the job timeout, not an observed duration or a queue/total-time guarantee."}
        return {"status": "unmeasured", "samples": []}
    values = [float(row["candidate_minutes"]) for row in samples]
    upload = float(history["upload_minutes"]) if include_upload else 0
    if any(not math.isfinite(value) or value <= 0 for value in values) or not math.isfinite(upload) or upload < 0:
        raise ValueError("Invalid timing observations")
    return {"status": "observed", "ci_minutes": [min(values), max(values)],
            "with_upload_minutes": [round(min(values) + upload, 1), round(max(values) + upload, 1)],
            "samples": samples, "includes_future_rework": False}


def candidate_plan(base, target_minutes, include_upload, history, decision=None, use_full_baseline=False):
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
    reason = ("Private JPEG Container gateway and frozen Node/Docker workflow; no deployment or release evidence"
              if selected == planner.JPEG_SCOPE else
              "Preservation, owner-index migration and verified-notice evidence with frozen Node workflow; no native or release evidence"
              if selected == planner.PRESERVATION_SCOPE else
              "Development helpers only; app/build/safety/release inputs unchanged"
              if selected == planner.DEVELOPMENT_SCOPE else
              "Unmapped inputs require full checks" if selected == scope.FULL_SCOPE and unmatched else
              "No reviewed limited profile matches this complete change; full checks required"
              if selected == scope.FULL_SCOPE else "Existing selector matched the complete change")
    cost = observe_cost(selected, history, include_upload, use_full_baseline)
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
    parser.add_argument("--use-full-baseline", action="store_true",
                        help="For reviewed memory-v3, membership-access or managed-preservation-v2 only, use the full-route maximum as an unmeasured cost reference; keep all gates")
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
        result = candidate_plan(args.base, args.target_minutes, args.include_upload, history, args.decision, args.use_full_baseline)
        if result["scope"] not in {"no-change", "handoff-only", planner.DEVELOPMENT_SCOPE}:
            result = apply_task_gate(result, read_task_runs(result["head"]), measure_baseline=args.measure_baseline)
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
