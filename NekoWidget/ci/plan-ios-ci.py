#!/usr/bin/env python3
"""Conservative iOS job selection and verified main promotion evidence."""

from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.parse
import urllib.request

from ios_ci_scope import FULL_SCOPE, MAPPED_VIEWS, SCOPES, select_scope, sharing_job


BUILD = "Build disabled app and extensions without signing"
SMOKE = "Launch app and scan fixtures in Simulator"
SHARING = sharing_job(FULL_SCOPE)
FULL = (BUILD, SMOKE, SHARING)
MOVIE_VIEW = "NekoWidget/NekoWidget/Views/SeasonalMovieView.swift"
MOVIE_ADR = "NekoWidget/docs/ADR-023-季節の小さな映画.md"
SHA = re.compile(r"[0-9a-f]{40}")
# This standalone research app is not an input to iOS checks or TestFlight.
# If a build, fixture, script, or project starts consuming it, remove this
# exception before that dependency ships. Everything else must match exactly.
INDEPENDENT_RESEARCH = "experiments/PetIdentityProbe/"


def required_jobs(paths: list[str] | None, runtime_scope: str = FULL_SCOPE) -> tuple[str, ...]:
    # An explicit allowlist, not a broad Views/** exemption. All existing
    # boundary/selection tests still run in BUILD. Unknown changes run FULL.
    if paths and MOVIE_VIEW in paths and set(paths) <= {MOVIE_VIEW, MOVIE_ADR}:
        return (BUILD,)
    if not paths or not set(paths) <= MAPPED_VIEWS:
        runtime_scope = FULL_SCOPE
    return (BUILD, SMOKE, sharing_job(runtime_scope))


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True, encoding="utf-8").rstrip("\n")


def comparison_base(event: dict, env: dict) -> str | None:
    if env["GITHUB_EVENT_NAME"] == "workflow_dispatch":
        return None  # The manual workflow is the explicit full-check escape hatch.
    head = env["GITHUB_SHA"]
    if git("rev-parse", "HEAD") != head:
        raise ValueError("Checkout does not match the workflow commit")
    if env["GITHUB_EVENT_NAME"] == "push" and env["GITHUB_REF"] == "refs/heads/main":
        base = event.get("before", "")
        if not SHA.fullmatch(base) or base == "0" * 40:
            return None
        git("merge-base", "--is-ancestor", base, head)
    elif env["GITHUB_EVENT_NAME"] == "pull_request":
        base = git("merge-base", event["pull_request"]["base"]["sha"], head)
    elif env["GITHUB_EVENT_NAME"] == "push":
        # Include the entire branch, not just the last pushed commit.
        base = git("merge-base", "refs/remotes/origin/main", head)
    else:
        return None
    return base


def changed_paths(event: dict, env: dict) -> list[str] | None:
    base = comparison_base(event, env)
    if base is None:
        return None
    return [p for p in git("diff", "--name-only", "--no-renames", "-z", base, env["GITHUB_SHA"]).split("\0") if p]


def runtime_scope(paths: list[str] | None, event: dict, env: dict) -> str:
    if not paths or not set(paths) <= MAPPED_VIEWS:
        return FULL_SCOPE
    try:
        base = comparison_base(event, env)
        if base is None:
            return FULL_SCOPE
        head = env["GITHUB_SHA"]
        # --no-renames exposes moves as delete/add. Exact raw modes exclude
        # symlinks, executable/type changes, new files and removals.
        records = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).split("\0")
        if records and records[-1] == "":
            records.pop()
        if len(records) != 2 * len(paths):
            return FULL_SCOPE
        seen = set()
        for index in range(0, len(records), 2):
            header, path = records[index:index + 2]
            fields = header.split()
            if len(fields) != 5 or fields[0:2] != [":100644", "100644"] or fields[4] != "M":
                return FULL_SCOPE
            if path not in paths or path in seen:
                return FULL_SCOPE
            seen.add(path)
        if seen != set(paths):
            return FULL_SCOPE
        return select_scope({path: (git("show", f"{base}:{path}"), git("show", f"{head}:{path}")) for path in paths})
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return FULL_SCOPE


def equivalent_inputs(candidate: str, head: str) -> bool:
    """Only an ancestor with identical non-research paths/content/modes/types."""
    try:
        if not SHA.fullmatch(candidate) or not SHA.fullmatch(head):
            return False
        if git("rev-parse", "HEAD") != head:
            return False
        git("merge-base", "--is-ancestor", candidate, head)
        paths = git("diff", "--no-ext-diff", "--name-only", "--no-renames", "-z", candidate, head)
        # Disabling rename detection exposes both endpoints of moves across
        # the boundary. A sibling or a file replacing the subtree is rejected.
        return all(path.startswith(INDEPENDENT_RESEARCH) for path in paths.split("\0") if path)
    except (OSError, subprocess.CalledProcessError, TypeError, ValueError):
        return False


def reusable_run(run: dict, current: dict, repository: str, now: dt.datetime) -> bool:
    try:
        finished = dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00"))
        age = now - finished
        return (
            run["id"] != current["id"]
            and run["workflow_id"] == current["workflow_id"]
            and SHA.fullmatch(run["head_sha"]) is not None
            and SHA.fullmatch(current["head_sha"]) is not None
            and run["event"] == "push"
            and run["head_branch"].startswith("codex/")
            and run["head_repository"]["full_name"] == repository
            and run["repository"]["full_name"] == repository
            and run["status"] == "completed"
            and run["conclusion"] == "success"
            and dt.timedelta(0) <= age <= dt.timedelta(hours=24)
            and (run["head_sha"] == current["head_sha"]
                 or equivalent_inputs(run["head_sha"], current["head_sha"]))
        )
    except (AttributeError, KeyError, TypeError, ValueError):
        return False


def covers_jobs(jobs: list[dict], required: tuple[str, ...], sha: str) -> bool:
    # Missing, skipped, failed or duplicate jobs are not evidence of execution.
    for name in required:
        acceptable = {name}
        if name in {sharing_job(scope) for scope in SCOPES}:
            # Full native/Gallery execution covers a mapped subset. A subset
            # never covers full or a different subset; legacy unscoped job
            # names are not proof of which tests actually ran.
            acceptable.add(SHARING)
        matching = [job for job in jobs if job.get("name") in acceptable]
        if len(matching) != 1:
            return False
        job = matching[0]
        if (job.get("status"), job.get("conclusion"), job.get("head_sha")) != (
            "completed", "success", sha
        ):
            return False
    return True


def find_evidence(env: dict, required: tuple[str, ...], api, now: dt.datetime) -> tuple[int, str] | None:
    if env["GITHUB_EVENT_NAME"] != "push" or env["GITHUB_REF"] != "refs/heads/main":
        return None
    repo = env["GITHUB_REPOSITORY"]
    prefix = f"/repos/{repo}/actions"
    current = api(f"{prefix}/runs/{int(env['GITHUB_RUN_ID'])}")
    if current["head_sha"] != env["GITHUB_SHA"] or git("rev-parse", "HEAD") != env["GITHUB_SHA"]:
        return None
    query = urllib.parse.urlencode({
        "event": "push", "status": "success", "per_page": 100,
    })
    runs = api(f"{prefix}/workflows/ios-build.yml/runs?{query}")["workflow_runs"]
    for run in runs:
        if not reusable_run(run, current, repo, now):
            continue
        # Fixed same-repository endpoint; never follow URLs supplied by a run.
        run_id = int(run["id"])
        result = api(f"{prefix}/runs/{run_id}/jobs?filter=latest&per_page=100")
        if result["total_count"] > len(result["jobs"]):
            continue  # Incomplete evidence means execute normally.
        if covers_jobs(result["jobs"], required, run["head_sha"]):
            return run_id, run["head_sha"]
    return None


def main() -> None:
    env = dict(os.environ)
    event = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    try:
        paths = changed_paths(event, env)
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        paths = None
    selected_scope = runtime_scope(paths, event, env)
    required = required_jobs(paths, selected_scope)

    def api(path: str) -> dict:
        request = urllib.request.Request(
            env.get("GITHUB_API_URL", "https://api.github.com") + path,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {env['GH_TOKEN']}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)

    try:
        evidence = find_evidence(env, required, api, dt.datetime.now(dt.timezone.utc))
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError):
        evidence = None  # API/permission/response failures never bypass checks.
    values = {
        "build": str(evidence is None).lower(),
        "smoke": str(evidence is None and SMOKE in required).lower(),
        "sharing": str(evidence is None and len(required) == 3).lower(),
        "runtime_scope": selected_scope,
    }
    with Path(env["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")
    scope = "movie-screen-only" if required == (BUILD,) else selected_scope
    summary = f"## iOS CI plan\n\nCommit: `{env['GITHUB_SHA']}`\n\nScope: `{scope}`.\n\n"
    if evidence is not None:
        run_id, tested_sha = evidence
        url = f"{env['GITHUB_SERVER_URL']}/{env['GITHUB_REPOSITORY']}/actions/runs/{run_id}"
        relation = "the same commit" if tested_sha == env["GITHUB_SHA"] else (
            f"an ancestor with identical tracked files outside `{INDEPENDENT_RESEARCH}`"
        )
        summary += f"Reusing successful required jobs from {relation}: [run {run_id}]({url}), tested `{tested_sha}`.\n"
    else:
        summary += "Executing: " + ", ".join(required) + ".\n"
    with Path(env["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as output:
        output.write(summary)
    print(f"iOS CI scope: {scope}; reused run: {evidence or 'none'}")


if __name__ == "__main__":
    main()
