#!/usr/bin/env python3
"""Verify and optionally dispatch the existing internal TestFlight configuration.

Dry-run is the default. Uses the existing gh login, never Apple credentials.
No CI rerun, branch update, tester operation, or App Store review is performed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "soso-so-27/neko-widget"
PLAN_JOB = "Select iOS checks and verify reusable evidence"
PLAN_MARKER = "IOS_CI_PLAN_JSON="
SHA = re.compile(r"[0-9a-f]{40}")
BUILD = re.compile(r"[1-9][0-9]*")
RUN_TITLE = re.compile(r"TestFlight build ([1-9][0-9]*) @ ([0-9a-f]{40})")
MAX_RESPONSE_BYTES = 32 * 1024 * 1024
# Audited successful upload; older release history is outside the new-number
# decision. Advance this anchor only after verifying a newer completed upload.
BASELINE = {
    "run_id": 34740960779,
    "sha": "e8154065a049205dc6828893a693dd428f5b7bc0",
    "build": 160,
    "created_at": "2026-09-13T05:42:24Z",
}


def load_sibling(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


planner = load_sibling("plan-ios-ci")
release_config = load_sibling("validate-official-window-release")


class Blocked(ValueError):
    """Unverified conditions must never dispatch."""


def require(condition, message: str) -> None:
    if not condition:
        raise Blocked(message)


def command(args: list[str], *, input_text: str | None = None) -> str:
    # Argument arrays and JSON stdin avoid shell interpolation. Never echo raw
    # gh errors or release logs, which may contain private account information.
    try:
        result = subprocess.run(args, cwd=ROOT, input=input_text, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Blocked(f"{args[0]} could not complete; no automatic retry.") from error
    require(result.returncode == 0, f"{args[0]} failed; verify its local authentication/access separately.")
    require(len(result.stdout.encode("utf-8")) <= MAX_RESPONSE_BYTES, "Response exceeded the verification limit.")
    return result.stdout.rstrip("\n")


def git(*args: str) -> str:
    return command(["git", *args])


class GitHub:
    def get(self, path: str) -> dict:
        result = json.loads(command(["gh", "api", "--hostname", "github.com", "--method", "GET",
                                     f"repos/{REPOSITORY}/{path}"]))
        require(isinstance(result, dict), "Unexpected GitHub response.")
        return result

    def log(self, run_id: int, job_id: int | None = None) -> str:
        args = ["gh", "run", "view", str(run_id), "--repo", f"github.com/{REPOSITORY}",
                "--log"]
        if job_id is not None:
            args.extend(["--job", str(job_id)])
        return command(args)

    def dispatch(self, inputs: dict) -> None:
        # Exactly one POST. A lost response is ambiguous: never retry here.
        try:
            command(["gh", "api", "--hostname", "github.com", "--method", "POST",
                     f"repos/{REPOSITORY}/actions/workflows/testflight.yml/dispatches", "--input", "-"],
                    input_text=json.dumps({"ref": "main", "inputs": inputs}))
        except Blocked as error:
            raise Blocked("Dispatch response is uncertain. Inspect GitHub runs before any retry; Apple login is not required.") from error


def check_checkout(gh: GitHub, sha: str) -> None:
    require(SHA.fullmatch(sha) is not None, "--sha must be the full lowercase 40-character main commit.")
    require(git("remote", "get-url", "origin") in {
        f"https://github.com/{REPOSITORY}", f"https://github.com/{REPOSITORY}.git",
        f"git@github.com:{REPOSITORY}.git", f"ssh://git@github.com/{REPOSITORY}.git",
    }, "origin is not the fixed release repository.")
    require(git("rev-parse", "HEAD") == sha, "Checkout HEAD does not match --sha.")
    require(not git("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none"),
            "Tracked worktree/index changes remain; release only the reviewed commit.")
    main = gh.get("git/ref/heads/main")
    require(main.get("object", {}).get("type") == "commit"
            and main["object"].get("sha") == sha, "Remote main does not match --sha.")


def workflow(gh: GitHub, filename: str) -> dict:
    value = gh.get(f"actions/workflows/{filename}")
    require(type(value.get("id")) is int and value["id"] > 0
            and value.get("path") == f".github/workflows/{filename}" and value.get("state") == "active",
            f"{filename} identity/state is not verified.")
    return value


def jobs_for(gh: GitHub, run_id: int) -> list[dict]:
    result = gh.get(f"actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    jobs = result.get("jobs")
    require(isinstance(jobs, list) and type(result.get("total_count")) is int
            and result["total_count"] == len(jobs), "Job evidence is incomplete.")
    return jobs


def executed_jobs_for(gh: GitHub, run: dict) -> list[dict]:
    prefix = f"/repos/{REPOSITORY}/"

    def api(path: str) -> dict:
        require(path.startswith(prefix + "actions/"), "Planner requested an unexpected repository.")
        return gh.get(path[len(prefix):])

    return planner.executed_jobs(run, REPOSITORY, api)


def plan_from_log(log: str, sha: str) -> dict:
    records = []
    for line in log.splitlines():
        if PLAN_MARKER not in line:
            continue
        try:
            record = json.loads(line.split(PLAN_MARKER, 1)[1])
        except ValueError:
            continue
        # The same job first runs planner unit tests, whose fixture plans are
        # deliberately printed with another repository/commit.
        if isinstance(record, dict) and record.get("repository") == REPOSITORY and record.get("head_sha") == sha:
            records.append(record)
    require(len(records) == 1, "Main CI has no unique machine-readable plan; do not rerun heavy CI automatically.")
    return records[0]


def check_ci(gh: GitHub, sha: str, run_id: int, now: dt.datetime) -> dict:
    ci_workflow = workflow(gh, "ios-build.yml")
    current = gh.get(f"actions/runs/{run_id}")
    require(current.get("id") == run_id and current.get("workflow_id") == ci_workflow["id"]
            and current.get("head_sha") == sha and current.get("head_branch") == "main"
            and current.get("event") == "push" and current.get("status") == "completed"
            and current.get("conclusion") == "success"
            and current.get("repository", {}).get("full_name") == REPOSITORY
            and current.get("head_repository", {}).get("full_name") == REPOSITORY,
            "--main-ci-run is not a successful same-repository main push for --sha.")
    # A reused main run may contain multiple skipped, unexpanded matrix jobs
    # with the same display name. Only its unique plan is release evidence;
    # the required native jobs are verified on the referenced candidate below.
    jobs = jobs_for(gh, run_id)
    plans = [job for job in jobs if job.get("name") == PLAN_JOB]
    require(len(plans) == 1 and type(plans[0].get("id")) is int
            and plans[0].get("head_sha") == sha and plans[0].get("status") == "completed"
            and plans[0].get("conclusion") == "success", "Main CI plan job did not succeed for --sha.")
    plan = plan_from_log(gh.log(run_id, plans[0]["id"]), sha)
    require(type(plan.get("schema_version")) is int and plan["schema_version"] == 1
            and plan.get("repository") == REPOSITORY and plan.get("head_sha") == sha,
            "CI plan identity/version does not match this release.")
    required = planner.required_jobs_from_scope(plan.get("scope"))
    require(plan.get("required_jobs") == list(required), "CI plan does not name the exact required checks.")
    source_id, source_sha = plan.get("evidence_run_id"), plan.get("evidence_sha")
    if source_id is None:
        require(source_sha is None, "CI plan has an incomplete evidence reference.")
        source_id, source_sha = run_id, sha
        jobs = executed_jobs_for(gh, current)
    else:
        require(type(source_id) is int and source_id > 0 and type(source_sha) is str,
                "CI plan has a malformed evidence reference.")
        source = gh.get(f"actions/runs/{source_id}")
        require(source.get("id") == source_id and source.get("head_sha") == source_sha
                and planner.reusable_run(source, current, REPOSITORY, now),
                "Candidate CI evidence is stale or does not match the main commit/workflow.")
        jobs = executed_jobs_for(gh, source)
    require(planner.covers_jobs(jobs, required, source_sha, now=now),
            "Required CI jobs are missing, skipped, failed, duplicated, or from another commit.")
    return {"main_ci_run": run_id, "tested_run": source_id, "tested_sha": source_sha,
            "scope": plan["scope"], "required_jobs": list(required)}


def recent_runs_path(page: int) -> str:
    query = urllib.parse.urlencode({"created": ">=" + BASELINE["created_at"], "per_page": 100, "page": page})
    return f"actions/workflows/testflight.yml/runs?{query}"


def release_runs(gh: GitHub) -> list[dict]:
    """Read only the complete index since the audited upload anchor."""
    runs, total = [], None
    for page in range(1, 11):
        result = gh.get(recent_runs_path(page))
        count, items = result.get("total_count"), result.get("workflow_runs")
        require(type(count) is int and 0 <= count <= 1000 and isinstance(items, list),
                "Recent release history exceeds its verification limit; advance the audited baseline.")
        require(total is None or total == count, "Release history changed during verification; run the dry-run again.")
        total = count
        runs.extend(items)
        require(len(runs) <= total, "Release history is inconsistent.")
        if len(runs) == total:
            require(len({run.get("id") for run in runs}) == total, "Release history contains duplicate pages.")
            return runs
        require(len(items) == 100, "Release history was truncated.")
    raise Blocked("Release history was truncated.")


def legacy_build_number(log: str, run_number: int) -> int:
    # Historical workflows have no input-bearing run title. Only read their
    # emitted environment values, never the shell source's "$build_number".
    requested, resolved = set(), set()
    for line in log.splitlines():
        match = re.search(r"\b(REQUESTED_BUILD_NUMBER|RELEASE_BUILD_NUMBER):[ \t]*([0-9]*)[ \t]*$", line)
        if match:
            value = match[2]
            require(not value or BUILD.fullmatch(value) is not None, "Malformed historical build number.")
            (requested if match[1] == "REQUESTED_BUILD_NUMBER" else resolved).add(value)
    require(len(requested) <= 1 and len(resolved) <= 1, "Conflicting historical build numbers.")
    require("" not in resolved, "Historical release build was not resolved.")
    number = next(iter(resolved), None)
    if requested:
        explicit = next(iter(requested))
        expected = explicit or str(run_number)
        require(number is None or number == expected, "Historical requested/resolved build numbers disagree.")
        number = expected
    require(number is not None and BUILD.fullmatch(number) is not None,
            "Historical build identity is unavailable; do not guess or re-upload.")
    return int(number)


def check_baseline(gh: GitHub, workflow_id: int, cache: dict[int, int]) -> None:
    run = gh.get(f"actions/runs/{BASELINE['run_id']}")
    require(run.get("id") == BASELINE["run_id"] and run.get("head_sha") == BASELINE["sha"]
            and run.get("created_at") == BASELINE["created_at"] and run.get("head_branch") == "main"
            and run.get("workflow_id") == workflow_id and run.get("event") == "workflow_dispatch"
            and run.get("repository", {}).get("full_name") == REPOSITORY
            and run.get("head_repository", {}).get("full_name") == REPOSITORY
            and run.get("status") == "completed" and run.get("conclusion") == "success",
            "The audited release baseline is no longer verified; inspect GitHub evidence, not Apple login.")
    if run["id"] not in cache:
        require(type(run.get("run_number")) is int and run["run_number"] > 0, "Baseline run number is unavailable.")
        cache[run["id"]] = legacy_build_number(gh.log(run["id"]), run["run_number"])
    require(cache[run["id"]] == BASELINE["build"], "Baseline log does not match its audited build number.")


def check_duplicates(gh: GitHub, build: str, cache: dict[int, int]) -> int:
    expected_workflow = workflow(gh, "testflight.yml")
    check_baseline(gh, expected_workflow["id"], cache)
    highest = BASELINE["build"]
    require(int(build) > highest, f"Build {build} must be newer than audited build {highest}.")
    runs = release_runs(gh)
    for run in runs:
        require(type(run.get("id")) is int and run.get("workflow_id") == expected_workflow["id"]
                and run.get("repository", {}).get("full_name") == REPOSITORY
                and run.get("head_repository", {}).get("full_name") == REPOSITORY,
                "Release history contains unverified run identity.")
        created = dt.datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
        anchor = dt.datetime.fromisoformat(BASELINE["created_at"].replace("Z", "+00:00"))
        require(created >= anchor, "GitHub did not return the requested release history range.")
        if run["id"] == BASELINE["run_id"]:
            continue  # Already checked its identity, success and actual build.
        require(run.get("status") == "completed",
                f"TestFlight run {run['id']} is still active; do not queue another upload.")
        title = RUN_TITLE.fullmatch(run.get("display_title", ""))
        if title:
            require(title[2] == run.get("head_sha"), "Release title and commit disagree.")
            number = int(title[1])
        elif run.get("conclusion") == "success":
            # Cached only within this invocation, after successful immutable-run
            # verification. No local state can silently authorize future runs.
            if run["id"] not in cache:
                require(type(run.get("run_number")) is int and run["run_number"] > 0,
                        "Legacy release has no default build number.")
                cache[run["id"]] = legacy_build_number(gh.log(run["id"]), run["run_number"])
            number = cache[run["id"]]
        else:
            # Failure is not proof that Apple received nothing. Older failed
            # runs need inspection if their upload step was entered.
            jobs = jobs_for(gh, run["id"])
            upload_steps = [step for job in jobs for step in job.get("steps", [])
                            if step.get("name") == "Validate and upload IPA to TestFlight"]
            require(upload_steps and all(step.get("status") == "completed"
                    and step.get("conclusion") == "skipped" for step in upload_steps),
                    f"Legacy failed run {run['id']} has uncertain upload state; inspect it before dispatch.")
            continue
        highest = max(highest, number)
        require(int(build) > number,
                f"Build {build} is not newer than reserved build {number} (run {run['id']}); no duplicate upload.")
    return highest


def prepare(gh: GitHub, sha: str, build: str, run_id: int, now: dt.datetime,
            cache: dict[int, int]) -> dict:
    require(isinstance(build, str) and BUILD.fullmatch(build) is not None,
            "--build-number must be an explicit positive integer without leading zeros.")
    require(type(run_id) is int and run_id > 0, "--main-ci-run must be a positive run ID.")
    check_checkout(gh, sha)
    evidence = check_ci(gh, sha, run_id, now)
    highest = check_duplicates(gh, build, cache)
    return {
        "repository": REPOSITORY, "sha": sha, "previous_reserved_build": highest, "ci": evidence,
        "inputs": {
            "expected_main_sha": sha, "build_number": build, "release_mode": "media-staging",
            "official_window_feed_url": release_config.validated_url("media-staging", release_config.PREVIEW_FEED_URL),
            "upload_to_testflight": "true", "retain_signed_artifacts": "true",
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--main-ci-run", required=True, type=int)
    parser.add_argument("--dispatch", action="store_true", help="Dispatch once after all checks; default is dry-run.")
    args = parser.parse_args(argv)
    os.chdir(ROOT)  # The reused planner's git checks must inspect this checkout.
    gh, cache = GitHub(), {}
    try:
        plan = prepare(gh, args.sha, args.build_number, args.main_ci_run, dt.datetime.now(dt.timezone.utc), cache)
        if args.dispatch:
            # Recheck main and the live release index immediately before POST.
            # expected_main_sha also closes a subsequent ref race in workflow.
            check_checkout(gh, args.sha)
            check_duplicates(gh, args.build_number, cache)
            gh.dispatch(plan["inputs"])
        print(json.dumps(dict(plan, action="dispatch-requested" if args.dispatch else "dry-run"), ensure_ascii=False, indent=2))
        if args.dispatch:
            print("One dispatch requested. Upload success is separate from Apple processing/internal group availability.")
        return 0
    except (Blocked, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        # Do not print raw API/log payloads on malformed responses.
        message = str(error) if isinstance(error, Blocked) else "Evidence could not be parsed; nothing further was dispatched."
        print(f"Blocked: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
