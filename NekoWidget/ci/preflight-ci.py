#!/usr/bin/env python3
"""Candidate plan and observed cost; only explicit recovery dispatch mutates refs."""

import argparse
import datetime as dt
import hashlib
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
# preservation-service-v27 retains the existing Node-only job and five-minute ceiling.
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
# This exact reviewed pair only appends owning full-CI shard registrations and
# their tests. Diagnostic selection/preparation and every app/UI-test input are
# unchanged. It preserves focused diagnosis, never release qualification.
DIAGNOSTIC_SHARD_ADDITION_PAIRS = {
    "NekoWidget/ci/ios_ci_scope.py": (
        "988ee6e14988a5a0179d8e64f2764d3c2839081c", "0f921859fb3a15e9a1ac9c2c1dd15f88470dbadc"),
    "NekoWidget/ci/test-ci-lanes.py": (
        "af90e5821d25fd7892b242b3b8b7ae1b8b5fa5d6", "2622015e786b04b3f85a6bd507a663b0da328691"),
}
# Only this account-settings diagnostic may cross this new selector registration.
# The complete pair must already be approved on main, with every changed helper
# also identical to that main ancestor. This never supplies release evidence.
DIAGNOSTIC_SAVE_SETTINGS_SOURCE = "b77cbc1dc837fa3f7e8cadce17c940f9354b30cc"
DIAGNOSTIC_SAVE_SETTINGS_PAIRS = {
    "NekoWidget/ci/ios_ci_scope.py": (
        "835fc6cebee388961f02561d42bb9b067aeae358", "2aed10f5b54758aa139ee5fa002efaa690986e17"),
    "NekoWidget/ci/test-ci-lanes.py": (
        "f942708909f532e36d0d888b3859878136eff46b", "e381f4bf1dfa5e7fded6b1bba5494ed93ccd4429"),
}
DIAGNOSTIC_JOB_NAMES = frozenset({
    "Diagnostic only - one native UI test (not release evidence)",
    "Diagnostic only - up to three native UI tests (not release evidence)",
})
RECOVERY_PREFIX = "codex/recovery-"
IOS_WORKFLOW = ".github/workflows/ios-build.yml"
RECOVERY_MINIMUM_MINUTES = 60
RECOVERY_REMOTES = frozenset({f"https://github.com/{REPOSITORY}.git", f"https://github.com/{REPOSITORY}",
                              f"git@github.com:{REPOSITORY}.git"})
RECOVERY_MAIN_PATHS = frozenset({"NekoWidget/ci/preflight-ci.py", "NekoWidget/ci/test-preflight-ci.py",
    "handoffs/development-release-workflow.md", "handoffs/2026-10-08-stalled-ci-recovery.md"})

# A single full retry admission, never reusable native/release qualification.
VISION_PRODUCT = "c60921fce31225e4c601fd16be1f359fad0967a7"
VISION_DIAGNOSTIC = "9098ee0992878e17f391fd64cab4ce131827f798"
VISION_BRANCH = "codex/automatic-admission-20261016"
VISION_DIAGNOSTIC_BRANCH = "diagnostic/automatic-membership-vision-native-20261016"
VISION_DIAGNOSTIC_RUN = 38875746477
VISION_DIAGNOSTIC_JOB = 116890270717
VISION_FAILED_RUN = 38825512712
VISION_FAILED_SOURCE = "9c7149f712e53c77f946095b6c8d6bdd8834fc57"
VISION_CASE = "PhotoPermissionUITests/testGrantFullPhotoLibraryAccess"
VISION_FIRST_CANDIDATE = "2026-10-15T23:31:48.229Z"
VISION_FIRST_CI = "2026-10-15T23:45:56Z"
VISION_CONTROLS = ("NekoWidget/ci/preflight-ci.py", "NekoWidget/ci/test-preflight-ci.py")
VISION_CLOSURE = (1202, "143c552df83f0c6489f245b4741d456d74059432ba73529443e96ec593243601")
VISION_DIAGNOSTIC_LOG = "364562f92214c201c20f052f597ea4dde98ebab891837ec2c9330fa52119361a"
VISION_FAILED_JOBS = (
    (116732306461, 1, "2b837569e90a4793b86e85a5c2e08b4d98bc00dfb745bc718c06b0546552e80d"),
    (116757527061, 2, "75a3134ce7131b9d9d9318fa165d4f63bbcf8b670e2ee2b2c087ba6306bf2b88"),
)
VISION_KIND = "vision-queue-fixed-photos-full-admission-v1"


def vision_queue_control_anchor(head):
    """Freeze all product inputs; derive approved control pair without a self-hash."""
    if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{40}", head):
        return None
    try:
        planner.git("merge-base", "--is-ancestor", VISION_PRODUCT, head)
        raw = planner.git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", VISION_PRODUCT, head).split("\0")
        if raw[-1:] == [""]: raw.pop()
        if len(raw) % 2: return None
        seen = set()
        for index in range(0, len(raw), 2):
            fields, path = raw[index].split(), raw[index+1]
            if (path in seen or len(fields) != 5 or fields[1] != "100644"
                or (fields[0], fields[4]) not in {(":100644", "M"), (":000000", "A")}
                or not all(re.fullmatch(r"[0-9a-f]{40}", blob) for blob in fields[2:4])
                or fields[3] == "0"*40): return None
            if path in VISION_CONTROLS:
                if fields[4] != "M": return None
            elif not (path.startswith("handoffs/") and path.endswith(".md")):
                return None
            seen.add(path)
        if not set(VISION_CONTROLS) <= seen: return None
        rows = []
        for row in planner.git("ls-tree", "-r", "-z", "--full-tree", head).split("\0"):
            if not row: continue
            name = row.split("\t", 1)[1]
            if name in VISION_CONTROLS or name.startswith("handoffs/") and name.endswith(".md"): continue
            rows.append(row)
        if (len(rows), hashlib.sha256(("\0".join(rows)+"\0").encode()).hexdigest()) != VISION_CLOSURE:
            return None
        anchor = planner.git("merge-base", head, "origin/main")
        if not re.fullmatch(r"[0-9a-f]{40}", anchor): return None
        # merge-base is already ancestor of both. Require the whole pair, not
        # a newly changed local helper merely claiming an approved source.
        for path in VISION_CONTROLS:
            tree = planner.git("ls-tree", head, "--", path)
            if (not re.fullmatch(r"100644 blob [0-9a-f]{40}\t"+re.escape(path), tree)
                or tree != planner.git("ls-tree", anchor, "--", path)
                or tree == planner.git("ls-tree", VISION_PRODUCT, "--", path)):
                return None
        return anchor
    except (OSError, ValueError, IndexError, subprocess.CalledProcessError):
        return None


def known_vision_queue_photos_diagnosis(result, runs, now=None):
    """One fixed actual Mac diagnosis permits spending on a fresh full graph."""
    if (result.get("scope") != scope.FULL_SCOPE
        or tuple(result.get("required_jobs", ())) != planner.FULL
        or planner.git("branch", "--show-current") != VISION_BRANCH): return None
    anchor = vision_queue_control_anchor(result.get("head"))
    if anchor is None: return None
    now = now or dt.datetime.now(dt.timezone.utc)
    parse = lambda text: dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    try:
        original = [run for run in runs if run["id"] == VISION_FAILED_RUN]
        diagnostic = [run for run in runs if run["id"] == VISION_DIAGNOSTIC_RUN]
        if len(original) != 1 or len(diagnostic) != 1: return None
        original, diagnostic = original[0], diagnostic[0]
        for run, identifier, sha, branch, workflow, event, attempt, outcome in (
            (original, VISION_FAILED_RUN, VISION_FAILED_SOURCE, VISION_BRANCH, IOS_WORKFLOW, "push", 2, "failure"),
            (diagnostic, VISION_DIAGNOSTIC_RUN, VISION_DIAGNOSTIC, VISION_DIAGNOSTIC_BRANCH, DIAGNOSTIC_WORKFLOW, "workflow_dispatch", 1, "success")):
            if (type(run.get("id")) is not int or run["id"] != identifier or run.get("head_sha") != sha
                or run.get("head_branch") != branch or run.get("path") != workflow or run.get("event") != event
                or type(run.get("run_attempt")) is not int or run["run_attempt"] != attempt
                or (run.get("status"), run.get("conclusion")) != ("completed", outcome)
                or run.get("repository", {}).get("full_name") != REPOSITORY
                or run.get("head_repository", {}).get("full_name") != REPOSITORY): return None
        if (original.get("failed_tests") or original.get("unsupported_failed_tests") != ["NekoWidgetUITests."+VISION_CASE]
            or not 0 <= (now-parse(diagnostic["updated_at"])).total_seconds() < 86400): return None
        # A changed SHA on the same task cannot obtain another first retry.
        if any(run["id"] != VISION_FAILED_RUN and run.get("path") == IOS_WORKFLOW
               and run.get("event") == "push" and run.get("head_branch") == VISION_BRANCH
               and parse(run["created_at"]) >= parse(diagnostic["created_at"]) for run in runs): return None
        if planner.git("show", "-s", "--format=%P", VISION_DIAGNOSTIC) != VISION_PRODUCT: return None
        expected = [
            ":100644 100644 862c2d00497dd20349440edd1010c5633971684e 5dd284a96892d02e13b3a43465edd03cd7e58084 M", ".github/workflows/ios-ui-diagnostic.yml",
            ":000000 100644 "+"0"*40+" 572ec9d8daefaa0a424ebced2d29775ff00576ad A", "NekoWidget/ci/diagnose-vision-native-candidate.py", ""]
        if planner.git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", VISION_PRODUCT, VISION_DIAGNOSTIC).split("\0") != expected: return None
        latest = github(f"repos/{REPOSITORY}/actions/runs/{VISION_FAILED_RUN}/jobs?filter=latest&per_page=100")
        names = [planner.PLAN_JOB, *planner.FULL]
        jobs = latest.get("jobs", [])
        placeholders = [job for job in jobs if job.get("id") == 116757566231]
        if (len(placeholders) != 1 or placeholders[0].get("name") != planner.UNEXPANDED_SHARING_JOB
            or placeholders[0].get("run_id") != VISION_FAILED_RUN or placeholders[0].get("head_sha") != VISION_FAILED_SOURCE
            or placeholders[0].get("run_attempt") != 2
            or (placeholders[0].get("status"),placeholders[0].get("conclusion")) != ("completed","skipped")
            or placeholders[0].get("steps") != [] or placeholders[0].get("runner_id") is not None): return None
        jobs = [job for job in jobs if job.get("id") != 116757566231]
        if (latest.get("total_count") != len(names)+1 or len(jobs) != len(names)
            or sorted(job["name"] for job in jobs) != sorted(names)
            or len({job["id"] for job in jobs}) != len(names)
            or any(job.get("run_id") != VISION_FAILED_RUN or job.get("head_sha") != VISION_FAILED_SOURCE
                   or job.get("status") != "completed"
                   or job.get("conclusion") != ("failure" if job["name"] == planner.SMOKE else "success") for job in jobs)):
            return None
        for identifier, attempt, sha256 in VISION_FAILED_JOBS:
            job = github(f"repos/{REPOSITORY}/actions/jobs/{identifier}")
            if (job.get("id") != identifier or job.get("run_id") != VISION_FAILED_RUN
                or job.get("run_attempt") != attempt or job.get("head_sha") != VISION_FAILED_SOURCE
                or job.get("name") != planner.SMOKE or (job.get("status"), job.get("conclusion")) != ("completed", "failure")
                or not parse(job["started_at"]) < parse(job["completed_at"]) <= parse(diagnostic["created_at"])): return None
            log = github(f"repos/{REPOSITORY}/actions/jobs/{identifier}/logs", raw=True)
            if hashlib.sha256(log.encode()).hexdigest() != sha256: return None
        payload = github(f"repos/{REPOSITORY}/actions/runs/{VISION_DIAGNOSTIC_RUN}/attempts/1/jobs?per_page=100")
        if payload.get("total_count") != 1 or len(payload.get("jobs", [])) != 1: return None
        job = payload["jobs"][0]
        if (job.get("id") != VISION_DIAGNOSTIC_JOB or job.get("run_id") != VISION_DIAGNOSTIC_RUN
            or job.get("run_attempt") != 1 or job.get("head_sha") != VISION_DIAGNOSTIC
            or job.get("name") != "Diagnostic only - actual app Vision queue and Photos"
            or (job.get("status"), job.get("conclusion")) != ("completed", "success")
            or type(job.get("runner_id")) is not int or job["runner_id"] <= 0
            or not parse(diagnostic["created_at"]) <= parse(job["started_at"]) < parse(job["completed_at"]) <= parse(diagnostic["updated_at"])): return None
        steps = job.get("steps", [])
        required = {"Check out exact diagnostic", "Observe actual app without changing UI assertions", "Upload original checkpoint and diagnostics"}
        if (len({step["name"] for step in steps}) != len(steps) or not required <= {step["name"] for step in steps}
            or any((step.get("status"), step.get("conclusion")) != ("completed", "success")
                   or not parse(job["started_at"]) <= parse(step["started_at"]) <= parse(step["completed_at"]) <= parse(job["completed_at"]) for step in steps)): return None
        log = github(f"repos/{REPOSITORY}/actions/jobs/{VISION_DIAGNOSTIC_JOB}/logs", raw=True)
        case = "NekoWidgetUITests."+VISION_CASE.replace("/", " ")
        if (hashlib.sha256(log.encode()).hexdigest() != VISION_DIAGNOSTIC_LOG
            or re.findall(r"Test Case '-\[([^\]]+)\]' (started|passed|failed|skipped)", log) != [(case,"started"),(case,"passed")]): return None
        return {"kind":VISION_KIND, "candidate_sha":result["head"], "run_id":VISION_FAILED_RUN,
            "source_sha":VISION_FAILED_SOURCE, "test":VISION_CASE, "approved_control_anchor":anchor,
            "diagnostic_run":VISION_DIAGNOSTIC_RUN, "diagnostic_job":VISION_DIAGNOSTIC_JOB,
            "diagnostic_source":VISION_DIAGNOSTIC, "diagnostic_log_sha256":VISION_DIAGNOSTIC_LOG,
            "retained_photos_attempts":[[identifier,attempt] for identifier,attempt,_ in VISION_FAILED_JOBS],
            "owning_jobs_to_execute":list(planner.FULL), "reuses_successful_jobs":False, "release_evidence":False}
    except (OSError, KeyError, TypeError, ValueError, subprocess.CalledProcessError):
        return None


def vision_queue_diagnosis_matches(result, proof):
    return (isinstance(proof,dict) and proof.get("kind") == VISION_KIND
        and isinstance(proof.get("approved_control_anchor"), str)
        and re.fullmatch(r"[0-9a-f]{40}", proof["approved_control_anchor"]) is not None
        and proof.get("retained_photos_attempts") == [[identifier,attempt] for identifier,attempt,_ in VISION_FAILED_JOBS]
        and proof.get("reuses_successful_jobs") is False and proof.get("release_evidence") is False
        and result.get("scope") == scope.FULL_SCOPE and tuple(result.get("required_jobs", ())) == planner.FULL
        and all(proof.get(key) == value for key,value in {
            "candidate_sha":result.get("head"), "run_id":VISION_FAILED_RUN, "source_sha":VISION_FAILED_SOURCE,
            "test":VISION_CASE, "diagnostic_run":VISION_DIAGNOSTIC_RUN, "diagnostic_job":VISION_DIAGNOSTIC_JOB,
            "diagnostic_source":VISION_DIAGNOSTIC, "diagnostic_log_sha256":VISION_DIAGNOSTIC_LOG,
            "owning_jobs_to_execute":list(planner.FULL), "reuses_successful_jobs":False, "release_evidence":False}.items()))


def vision_queue_full_cost(result, proof):
    if not vision_queue_diagnosis_matches(result,proof): return result
    previous = result["cost"]
    bounds = previous.get("with_upload_minutes", [])
    if (previous.get("status") not in {"observed","reference"} or not isinstance(bounds,(list,tuple)) or len(bounds) != 2
        or any(type(value) not in (int,float) or not math.isfinite(value) or value < 0 for value in bounds)
        or bounds[0] > bounds[1]): raise ValueError("Full retry requires a finite existing timing reference")
    bounds = [max(120,bounds[0]),max(150,bounds[1])]
    result = {**result, "full_cost_before_vision_diagnosis":previous,
        "cost":{"status":"reference", "with_upload_minutes":bounds, "ci_minutes":None,
            "samples":[], "includes_future_rework":False, "planning_includes_upload":True,
            "note":"120-150 minutes is a conservative future full CI plus upload plan, not an observed new-candidate duration. Preserve higher existing timing bounds, all prior failures and original elapsed time."}}
    result["cost_review_required"] = bounds[1] > result["target_minutes"]
    result["ready"] = not result["cost_review_required"]
    return result


def verify_recovery_merge(source, head):
    """A real approved tooling merge, never an empty commit or native change."""
    parents = planner.git("show", "-s", "--format=%P", head).split()
    if len(parents) != 2 or parents[0] != source:
        raise ValueError("Recovery refresh requires the original candidate as first merge parent")
    planner.git("merge-base", "--is-ancestor", parents[1], "origin/main")
    raw = planner.git("diff", "--raw", "--no-abbrev", "--no-renames", source, head)
    changes = raw.splitlines()
    if not changes:
        raise ValueError("Recovery refresh requires actual approved tooling changes")
    for line in changes:
        metadata, path = line.split("\t")
        before_mode, after_mode, before_blob, after_blob, status = metadata.removeprefix(":").split()
        if (path not in RECOVERY_MAIN_PATHS or after_mode != "100644"
                or (status, before_mode) not in {("M", "100644"), ("A", "000000")}
                or status == "A" and not path.startswith("handoffs/")
                or planner.git("ls-tree", head, "--", path) != planner.git("ls-tree", parents[1], "--", path)):
            raise ValueError("Recovery refresh contains unapproved or non-main input changes")
    return parents[1]


def task_refs(branch):
    """A recovery ref carries its original task identity, never a fresh clock."""
    if branch.startswith(RECOVERY_PREFIX):
        identifier = branch.removeprefix(RECOVERY_PREFIX)
        if not re.fullmatch(r"[1-9][0-9]*", identifier):
            raise ValueError("Malformed recovery branch")
        source = github(f"repos/{REPOSITORY}/actions/runs/{identifier}")
        original = source.get("head_branch", "")
        if (source.get("id") != int(identifier) or source.get("event") != "push"
                or source.get("path") != IOS_WORKFLOW
                or source.get("repository", {}).get("full_name") != REPOSITORY
                or source.get("head_repository", {}).get("full_name") != REPOSITORY
                or not original.startswith("codex/") or original.startswith(RECOVERY_PREFIX)):
            raise ValueError("Recovery task identity is unavailable")
        return task_refs(original) | {branch}
    name = branch.removeprefix("codex/").removeprefix("diagnostic/")
    return {branch, "codex/" + name, "diagnostic/" + name}


def recovery_source(run_id, head, branch, now=None, existing=False, refresh=False):
    """Explicitly replace only an aged, unstarted push; never reuse its success."""
    if type(run_id) is not int or run_id <= 0:
        raise ValueError("Recovery requires a positive original run ID")
    run = github(f"repos/{REPOSITORY}/actions/runs/{run_id}")
    workflow = github(f"repos/{REPOSITORY}/actions/workflows/ios-build.yml")
    jobs = github(f"repos/{REPOSITORY}/actions/runs/{run_id}/jobs?filter=all&per_page=100")
    source = run.get("head_sha") if refresh else head
    if (run.get("id") != run_id or run.get("head_sha") != source
            or run.get("head_branch") != branch or not branch.startswith("codex/")
            or branch.startswith(RECOVERY_PREFIX) or not re.fullmatch(r"[0-9a-f]{40}", head)
            or type(workflow.get("id")) is not int or run.get("workflow_id") != workflow["id"]
            or workflow.get("path") != IOS_WORKFLOW or run.get("path") != IOS_WORKFLOW
            or run.get("repository", {}).get("full_name") != REPOSITORY
            or run.get("head_repository", {}).get("full_name") != REPOSITORY
            or run.get("event") != "push" or type(run.get("run_attempt")) is not int
            or run["run_attempt"] != 1 or run.get("status") != "queued"
            or run.get("conclusion") is not None
            or type(jobs.get("total_count")) is not int or jobs["total_count"] != 0 or jobs.get("jobs") != []):
        raise ValueError("Recovery requires the exact original queued push with no jobs in any attempt")
    created = dt.datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
    now = now or dt.datetime.now(dt.timezone.utc)
    if run.get("updated_at") != run["created_at"] or (now - created).total_seconds() < RECOVERY_MINIMUM_MINUTES * 60:
        raise ValueError("The original run is recent or has made progress; do not replace it")
    approved_main = verify_recovery_merge(source, head) if refresh else None
    recovery_branch = RECOVERY_PREFIX + str(run_id)
    refs = github(f"repos/{REPOSITORY}/git/matching-refs/heads/{recovery_branch}")
    query = urllib.parse.urlencode({"branch": recovery_branch, "per_page": 100})
    replacements = github(f"repos/{REPOSITORY}/actions/runs?{query}")
    if existing:
        replacement_runs = replacements.get("workflow_runs")
        if (not isinstance(refs, list) or len(refs) != 1
                or refs[0].get("ref") != "refs/heads/" + recovery_branch
                or refs[0].get("object", {}).get("sha") != head
                or not isinstance(replacement_runs, list) or not replacement_runs
                or replacements.get("total_count") != len(replacement_runs) or len(replacement_runs) >= 100
                or any(item.get("head_sha") != head or item.get("head_branch") != recovery_branch
                       for item in replacement_runs)
                or len([item for item in replacement_runs if item.get("event") == "push"
                        and item.get("path") == IOS_WORKFLOW and item.get("workflow_id") == workflow["id"]
                        and item.get("repository", {}).get("full_name") == REPOSITORY
                        and item.get("head_repository", {}).get("full_name") == REPOSITORY]) != 1):
            raise ValueError("The retained recovery ref/run identity is incomplete or changed")
    elif refresh:
        if (not isinstance(refs, list) or len(refs) != 1
                or refs[0].get("ref") != "refs/heads/" + recovery_branch
                or refs[0].get("object", {}).get("sha") != source
                or replacements.get("total_count") != 0 or replacements.get("workflow_runs") != []):
            raise ValueError("Refresh requires the original recovery ref and no replacement runs")
    elif refs != [] or replacements.get("total_count") != 0 or replacements.get("workflow_runs") != []:
        raise ValueError("A recovery ref/run already exists; inspect it instead of creating another")
    proof = {"original_run_id": run_id, "source_sha": source, "original_branch": branch,
            "recovery_branch": recovery_branch, "workflow_id": workflow["id"],
            "original_created_at": run["created_at"], "verified_jobs": 0,
            "original_run_retained": True, "release_evidence": False}
    if refresh:
        proof.update(candidate_sha=head, approved_main=approved_main, refresh=True)
    return proof


def approved_recovery_checkout(checkout):
    """Use already merged tooling while leaving the complete candidate unchanged."""
    control = CI.parents[1]
    def at(path, *args):
        return planner.git("-C", str(path), *args)
    control_sha = at(control, "rev-parse", "HEAD")
    if at(control, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Recovery tooling must be committed and clean")
    at(control, "merge-base", "--is-ancestor", control_sha, "origin/main")
    if any(at(path, "remote", "get-url", "origin") not in RECOVERY_REMOTES for path in (control, checkout)):
        raise ValueError("Recovery tooling and candidate must use the same expected repository")
    if at(checkout, "remote", "get-url", "--push", "--all", "origin") not in RECOVERY_REMOTES:
        raise ValueError("Recovery requires exactly one push destination in the expected repository")
    # The approved preflight is the only newer input. Scope selection, workflow,
    # and its imported code/data must be identical to the candidate's own inputs.
    for path in (IOS_WORKFLOW, "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/ci/ios_ci_scope.py",
                 "NekoWidget/ci/app_icon_ci.py", "NekoWidget/ci/reviewed-app-ui.json",
                 "NekoWidget/ci/ci-timing-baseline.json"):
        if at(control, "rev-parse", f"HEAD:{path}") != at(checkout, "rev-parse", f"HEAD:{path}"):
            raise ValueError("Recovery cannot substitute different selection/workflow inputs")
    return control_sha


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


def dispatch_recovery(result, recovery, output):
    if not result.get("ready") or result.get("task", {}).get("recovery") != recovery:
        raise ValueError("Recovery dispatch requires a successful bound preflight")
    if planner.git("rev-parse", "HEAD") != result["head"] or planner.git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Candidate changed before recovery dispatch")
    if planner.git("remote", "get-url", "--push", "--all", "origin") not in RECOVERY_REMOTES:
        raise ValueError("Recovery push destination changed; alternate or multiple recipients are forbidden")
    # Close the discovery/creation race. An explicit empty expected
    # ref in force-with-lease permits creation only, never an update.
    # Ref creation alone did not start CI in direct observation. A reviewed
    # tooling merge may advance that same ref once. Never retry an
    # unknown response; inspect this exact ref/run instead.
    fresh = recovery_source(recovery["original_run_id"], result["head"], recovery["original_branch"],
                            refresh=recovery.get("refresh", False))
    if any(fresh[key] != recovery[key] for key in fresh):
        raise ValueError("Recovery source changed before dispatch")
    payload = {"ref": "refs/heads/" + recovery["recovery_branch"], "sha": result["head"]}
    record = {**result, "dispatch": {"state": "update_requested" if recovery.get("refresh") else "creation_requested", **payload}}
    if not output:
        raise ValueError("Recovery dispatch requires --output outside the checkout")
    if output.is_relative_to(Path.cwd()) or output.is_relative_to(CI.parents[1]):
        raise ValueError("Recovery evidence must be outside both checkouts")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    expected = recovery["source_sha"] if recovery.get("refresh") else ""
    response = subprocess.run(["git", "push", "--porcelain", "--force-with-lease=" + payload["ref"] + ":" + expected,
                               "origin", result["head"] + ":" + payload["ref"]],
                              text=True, capture_output=True, encoding="utf-8", timeout=45)
    if response.returncode:
        raise ValueError("Recovery ref creation failed or outcome is unknown; inspect the recorded ref, never repeat blindly")
    created = github(f"repos/{REPOSITORY}/git/ref/heads/{recovery['recovery_branch']}")
    if created.get("ref") != payload["ref"] or created.get("object", {}).get("sha") != result["head"]:
        raise ValueError("Unexpected recovery ref response; inspect the recorded ref")
    result["dispatch"] = {"state": "updated" if recovery.get("refresh") else "created", **payload}


REPORT_ORDER_CANCELLED_PLAN = 38329817139
REPORT_ORDER_CANCELLED_PLAN_TIMES = {'run_number':1725,'created_at':'2026-10-13T00:57:50Z','run_started_at':'2026-10-13T00:57:50Z','updated_at':'2026-10-13T00:57:52Z'}
REPORT_ORDER_CANCELLED_PLAN_JOBS = {
    115076788562:(planner.PLAN_JOB,'2026-10-13T00:57:51Z','2026-10-13T00:57:51Z'),
    115076792148:(planner.UNEXPANDED_SHARING_JOB,'2026-10-13T00:57:52Z','2026-10-13T00:57:51Z'),
    115076792417:('needs.plan.outputs.smoke_name','2026-10-13T00:57:52Z','2026-10-13T00:57:51Z'),
    115076792545:('needs.plan.outputs.build_name','2026-10-13T00:57:52Z','2026-10-13T00:57:51Z'),
    115076792940:(planner.UNEXPANDED_SHARING_JOB,'2026-10-13T00:57:52Z','2026-10-13T00:57:51Z'),
    115076793248:(planner.UNEXPANDED_SHARING_JOB,'2026-10-13T00:57:52Z','2026-10-13T00:57:51Z'),
    115076793303:(planner.UNEXPANDED_SHARING_JOB,'2026-10-13T00:57:52Z','2026-10-13T00:57:51Z'),
}

def classify_report_order_cancelled_plan(run,payload):
    # History classification only. Empty cancelled jobs are never CI success.
    if (type(run.get('id')) is not int or run['id']!=REPORT_ORDER_CANCELLED_PLAN or run.get('head_sha')!=planner.REPORT_RUNTIME_DUPLICATE_HEAD
        or run.get('head_branch')!=planner.REPORT_RUNTIME_BRANCH or run.get('path')!=IOS_WORKFLOW or run.get('event')!='push'
        or run.get('workflow_id')!=335014238 or type(run.get('run_attempt')) is not int or run['run_attempt']!=1
        or (run.get('status'),run.get('conclusion'))!=('completed','cancelled')
        or run.get('repository',{}).get('full_name')!=REPOSITORY or run.get('head_repository',{}).get('full_name')!=REPOSITORY
        or type(run.get('run_number')) is not int or any(run.get(k)!=v for k,v in REPORT_ORDER_CANCELLED_PLAN_TIMES.items())):
        raise ValueError('Fixed cancelled runtime plan identity differs')
    if (not isinstance(payload,dict) or type(payload.get('total_count')) is not int or payload['total_count']!=7
        or not isinstance(payload.get('jobs'),list) or len(payload['jobs'])!=7):raise ValueError('Cancelled runtime plan jobs incomplete')
    seen=set()
    for job in payload['jobs']:
        if (not isinstance(job,dict) or type(job.get('id')) is not int or job['id'] in seen or job['id'] not in REPORT_ORDER_CANCELLED_PLAN_JOBS
            or job.get('run_id')!=REPORT_ORDER_CANCELLED_PLAN or job.get('head_sha')!=planner.REPORT_RUNTIME_DUPLICATE_HEAD
            or type(job.get('run_attempt')) is not int or job['run_attempt']!=1 or (job.get('status'),job.get('conclusion'))!=('completed','cancelled')
            or job.get('steps')!=[] or (job.get('name'),job.get('started_at'),job.get('completed_at'))!=REPORT_ORDER_CANCELLED_PLAN_JOBS[job['id']]):raise ValueError('Cancelled runtime plan started a step or changed job identity')
        seen.add(job['id'])
    return {'run_id':REPORT_ORDER_CANCELLED_PLAN,'sha':planner.REPORT_RUNTIME_DUPLICATE_HEAD,'conclusion':'cancelled','executed_step_count':0,'success_evidence':False,'job_ids':sorted(seen)}

def read_task_runs(head=None, recovery=None, metadata_repair=False):
    # A task uses matching codex/<task> and diagnostic/<task> branches. Look at
    # both, so a diagnostic push cannot reset the time/failure accounting.
    branch = planner.git("branch", "--show-current")
    if not branch or branch == "main":
        raise ValueError("Preflight requires a dedicated task branch")
    runs = {}
    refs = task_refs(branch)
    if branch in {VISION_BRANCH, "codex/automatic-admission-release-20261018", *planner.FIXTURE_NAV_DIAGNOSTIC_BRANCHES.values()}:
        refs.update({VISION_BRANCH,*planner.FIXTURE_NAV_DIAGNOSTIC_BRANCHES.values()})
        # This diagnostic's different branch name cannot hide task history.
        for identifier in (VISION_FAILED_RUN, VISION_DIAGNOSTIC_RUN):
            retained = github(f"repos/{REPOSITORY}/actions/runs/{identifier}")
            if retained.get("id") != identifier or retained.get("repository", {}).get("full_name") != REPOSITORY:
                raise ValueError("Retained Vision task history differs")
            runs[identifier] = retained
    if branch == planner.TOOL_RELEASE_BRANCH:
        refs.update(task_refs(planner.TOOL_BUILD_BRANCH))
    if branch in (planner.REPORT_RUNTIME_BRANCH,planner.REPORT_RUNTIME_ORDER_BRANCH):
        refs.update(task_refs(planner.REPLY_READINESS_BRANCH))
        retained_ids=(38318066862,planner.REPLY_READINESS_RUN,planner.REPORT_RUNTIME_BUILD_RUN,38325044657,planner.REPORT_RUNTIME_FAILED_RELEASE)
        if branch==planner.REPORT_RUNTIME_ORDER_BRANCH:
            refs.update(task_refs(planner.REPORT_RUNTIME_BRANCH))
            retained_ids+=(planner.REPORT_RUNTIME_ORDER_SOURCE_RUN,planner.REPORT_RUNTIME_CANCELLED_DUPLICATE,planner.REPORT_RUNTIME_SUCCESSFUL_DUPLICATE,planner.REPORT_RUNTIME_ORDER_FAILED_RELEASE,REPORT_ORDER_CANCELLED_PLAN)
        for identifier in retained_ids:
            retained=github(f"repos/{REPOSITORY}/actions/runs/{identifier}")
            if retained.get("id")!=identifier or retained.get("repository",{}).get("full_name")!=REPOSITORY:
                raise ValueError("Retained report task history differs")
            runs[identifier]=retained

    if metadata_repair:
        refs.update(task_refs(planner.INTERNAL_REPORT_CORRECTION_BRANCH))
        failed_release = github(f"repos/{REPOSITORY}/actions/runs/{planner.INTERNAL_REPORT_METADATA_FAILURE_RUN}")
        runs[failed_release["id"]] = failed_release
    if recovery:
        refs.add(recovery["recovery_branch"])
    for ref in refs:
        query = urllib.parse.urlencode({"branch": ref, "per_page": 100})
        page = github(f"repos/{REPOSITORY}/actions/runs?{query}")
        if page["total_count"] >= 100 or page["total_count"] != len(page["workflow_runs"]):
            raise ValueError("Task history is incomplete; review it before continuing")
        for run in page["workflow_runs"]:
            if run.get("path") in {".github/workflows/ios-build.yml", DIAGNOSTIC_WORKFLOW,
                                   planner.JPEG_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.BILLING_WORKFLOW}:
                runs[run["id"]] = run
    for run in runs.values():
        run["failed_ui"] = False
        run["failed_tests"] = []
        run["unsupported_failed_tests"] = []
        if run["path"] == ".github/workflows/ios-build.yml" and run["conclusion"] in {"failure", "timed_out", "cancelled"}:
            jobs = github(f"repos/{REPOSITORY}/actions/runs/{run['id']}/jobs?per_page=100")
            if branch==planner.REPORT_RUNTIME_ORDER_BRANCH and run['id']==REPORT_ORDER_CANCELLED_PLAN:
                detail=github(f"repos/{REPOSITORY}/actions/runs/{REPORT_ORDER_CANCELLED_PLAN}")
                classify_report_order_cancelled_plan(detail,jobs)
                classify_report_order_cancelled_plan(run,jobs)
                run['zero_step_cancelled_runtime_plan_jobs']=jobs
            if jobs["total_count"] >= 100:
                raise ValueError("Incomplete failed-job history")
            for job in jobs["jobs"]:
                if ("[app-ui" in job["name"] or job["name"] == planner.SMOKE or
                        run["id"] == planner.FIXTURE_NAV_RUN and job.get("id") == planner.FIXTURE_NAV_SOURCE_JOBS[planner.FIXTURE_NAV_OWNING[-1]] or
                        run["id"] == planner.MODERATION_CHAIN_RUN and job["name"] == planner.BOOTSTRAP_SMOKE) and job["conclusion"] in {"failure", "timed_out"}:
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


def read_other_active_ios_runs(branch):
    """Report contention without cancelling jobs or relaxing candidate gates."""
    own = task_refs(branch)
    active = {}
    for status in ("queued", "in_progress", "waiting", "requested", "pending"):
        query = urllib.parse.urlencode({"status": status, "per_page": 100})
        page = github(f"repos/{REPOSITORY}/actions/workflows/ios-build.yml/runs?{query}")
        if page["total_count"] >= 100 or page["total_count"] != len(page["workflow_runs"]):
            raise ValueError("Active iOS CI list is incomplete; review contention before starting")
        for run in page["workflow_runs"]:
            if run.get("status") != "completed" and run.get("head_branch") not in own:
                active[run["id"]] = run
    return [{"id": run["id"], "branch": run["head_branch"], "status": run["status"],
             "created_at": run["created_at"], "url": run.get("html_url")}
            for run in sorted(active.values(), key=lambda item: (item["created_at"], item["id"]))]


def feedback_plan(test_class, methods):
    """Exact, read-only diagnostic commands; never candidate or release evidence."""
    if planner.git("status", "--porcelain"):
        raise ValueError("Commit the complete feedback candidate before planning")
    head = planner.git("rev-parse", "HEAD")
    branch = planner.git("branch", "--show-current")
    if not re.fullmatch(r"[0-9a-f]{40}", head) or not branch.startswith(("codex/", "diagnostic/")):
        raise ValueError("Feedback requires an exact commit on a codex/ or diagnostic/ task branch")
    diagnostic_branch = "diagnostic/" + branch.split("/", 1)[1]
    source = (CI.parent / "NekoWidgetUITests" / (
        "WidgetPlacementScreenshotUITests.swift" if test_class == "WidgetPlacementScreenshotUITests"
        else "PhotoPermissionUITests.swift")).read_text(encoding="utf-8")
    tests = scope.diagnostic_tests(test_class, methods, source)
    runs = read_task_runs(head)
    active = [run["id"] for run in runs if run["status"] != "completed"]
    fixture = (branch in {VISION_BRANCH,*planner.FIXTURE_NAV_DIAGNOSTIC_BRANCHES.values()}
               and planner.fixture_navigation_inputs(head,approved=False) is not None)
    if fixture:
        if test_class+"/"+methods not in planner.FIXTURE_NAV_CASES:
            raise ValueError("Fixed fixture feedback selects one original LargestText or white Gallery case")
        diagnostic_branch = planner.FIXTURE_NAV_DIAGNOSTIC_BRANCHES[test_class+"/"+methods]
        if not active:
            source = next((run for run in runs if run["id"] == planner.FIXTURE_NAV_RUN),{})
            proof = planner.fixture_navigation_source(source,head,planner.FIXTURE_NAV_BRANCH,REPOSITORY,335014238,
                planner.FULL,lambda path:github(path.removeprefix("/"),raw=path.endswith("/logs")),dt.datetime.now(dt.timezone.utc),focused=False)
            if proof is None: raise ValueError("Original full graph must be complete with only the two fixed Solo/white Gallery failures before focused feedback")
    commands = [] if active else [
        ["git", "push", "origin", f"{head}:refs/heads/{diagnostic_branch}"],
        ["gh", "workflow", "run", "ios-ui-diagnostic.yml", "--ref", diagnostic_branch,
         "-f", "source_ref=" + head, "-f", "test_class=" + test_class, "-f", "test_method=" + methods],
    ]
    return {"head": head, "branch": diagnostic_branch, "diagnostic_only": True,
            "release_evidence": False, "ready": not active, "active_task_runs": active,
            "native_tests": list(tests), "commands": commands,
            "other_active_ios_runs": read_other_active_ios_runs(branch),
            "note": "No commands executed. Diagnostic success cannot replace the final candidate's required jobs."}


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


INTERNAL_REPORT_DIAGNOSTIC_SOURCE = "ac792da2436d6dd22c82160d064acdc52bf385b7"
INTERNAL_REPORT_RELEASE_FIXTURE = "NekoWidget/ci/test-release-testflight.py"
INTERNAL_REPORT_RELEASE_FIXTURE_BLOBS = (
    "88b8c53326113cdaf902021986a7d979db78ae6f",
    "f739adf1cf7c0551dbc3ca805baea26d00416198",
)


def internal_report_diagnostic_source_matches(source, head):
    """Forward only the fixed new diagnostic across reviewed Release/control pairs."""
    return planner.internal_report_recovery_diagnostic_inputs(source, head)


def diagnostic_source_matches(source, head):
    """A diagnosis only; never release evidence reuse or a selector exception."""
    if not all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) for value in (source, head)):
        return False
    if source == head:
        return True
    if source == planner.TOOL_STORAGE_SOURCE:
        return planner.tool_storage_diagnostic_inputs(source, head)
    if source == planner.TOOL_PRESERVATION_SOURCE:
        return planner.tool_preservation_diagnostic_inputs(source, head)
    if source in {INTERNAL_REPORT_DIAGNOSTIC_SOURCE, planner.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE}:
        return internal_report_diagnostic_source_matches(source, head)
    if source == planner.MODERATION_UI_RECOVERY_PRODUCT and (planner.moderation_ui_recovery_inputs(head)
            or planner.moderation_chained_inputs(head)):
        # Exact shipping UI/test pair unchanged since this diagnostic. Only the
        # separately approved controls/handoffs or the fixed Build-only fixture
        # may differ; the shipping UI and all diagnostic inputs remain exact.
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
    selector_pairs = {}
    after_blobs = {}
    for index in range(0, len(records), 2):
        fields, path = records[index].split(), records[index + 1]
        if (path in seen or len(fields) != 5
                or fields[:2] != [":100644", "100644"] or fields[4] != "M"
                or not all(re.fullmatch(r"[0-9a-f]{40}", value) and value != "0" * 40 for value in fields[2:4])):
            return False
        if path not in DIAGNOSTIC_HELPER_PATHS:
            pair = tuple(fields[2:4])
            if pair not in (DIAGNOSTIC_SHARD_ADDITION_PAIRS.get(path), DIAGNOSTIC_SAVE_SETTINGS_PAIRS.get(path)):
                return False
            selector_pairs[path] = pair
        seen.add(path)
        after_blobs[path] = fields[3]
    if selector_pairs and selector_pairs not in (DIAGNOSTIC_SHARD_ADDITION_PAIRS, DIAGNOSTIC_SAVE_SETTINGS_PAIRS):
        return False
    if selector_pairs == DIAGNOSTIC_SAVE_SETTINGS_PAIRS:
        if source != DIAGNOSTIC_SAVE_SETTINGS_SOURCE:
            return False
        try:
            main = planner.git("rev-parse", "origin/main^{commit}")
            if not re.fullmatch(r"[0-9a-f]{40}", main):
                return False
            planner.git("merge-base", "--is-ancestor", main, head)
            if any(planner.git("rev-parse", f"{main}:{path}") != blob for path, blob in after_blobs.items()):
                return False
        except subprocess.CalledProcessError:
            return False
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


FIXTURE_NAV_RAW_LOGS = ((planner.SMOKE,"85f852e0428abffe768776446a22f4bb5a51004cb948766d01dbe7e55d0259dd"),
    (planner.FIXTURE_NAV_OWNING[1],"d710c4c875d632bd69e1b9e7e6851205367dfbe6610e7e5bf310fd63b0380120"),
    (planner.FIXTURE_NAV_OWNING[-1],"dd3d73f6648f20906982bd2d6ab9266bf5c23c26316839a05f46af77b440cf3b"))


def known_fixture_navigation_diagnosis(result, runs, correction, now=None):
    """Retain both failures; normal full Photos, not a diagnostic, resolved the older one."""
    focused = correction.get("focused_diagnostic") if isinstance(correction,dict) else None
    if (result.get("scope") != scope.FULL_SCOPE or tuple(result.get("required_jobs",())) != planner.FULL
        or planner.git("branch","--show-current") != VISION_BRANCH
        or not isinstance(correction,dict) or correction.get("kind") != planner.FIXTURE_NAV_KIND
        or not isinstance(focused,dict) or focused.get("sha") != result.get("head")
        or planner.fixture_navigation_inputs(result.get("head")) is None): return None
    try:
        old = [run for run in runs if run["id"] == VISION_FAILED_RUN]
        source = [run for run in runs if run["id"] == planner.FIXTURE_NAV_RUN]
        if len(old) != 1 or len(source) != 1: return None
        old, source = old[0], source[0]
        focused = correction["focused_diagnostic"]
        if [item.get('case') for item in focused.get('cases',[])] != list(planner.FIXTURE_NAV_CASES): return None
        for item in focused['cases']:
            diagnostics = [run for run in runs if run["id"] == item["run_id"]]
            if len(diagnostics) != 1: return None
            diagnostic = diagnostics[0]
            if (diagnostic.get("head_sha") != result["head"] or diagnostic.get("path") != DIAGNOSTIC_WORKFLOW
                or diagnostic.get("head_branch") != planner.FIXTURE_NAV_DIAGNOSTIC_BRANCHES[item['case']]
                or diagnostic.get("event") != "workflow_dispatch" or diagnostic.get("run_attempt") != 1
                or (diagnostic.get("status"),diagnostic.get("conclusion")) != ("completed","success")
                or diagnostic.get("diagnostic_evidence",{}).get("results") != {item['case']:"passed"}): return None
        if (old.get("head_sha") != VISION_FAILED_SOURCE or old.get("head_branch") != VISION_BRANCH
            or old.get("path") != IOS_WORKFLOW or old.get("event") != "push" or old.get("run_attempt") != 2
            or (old.get("status"),old.get("conclusion")) != ("completed","failure")
            or old.get("failed_tests") or old.get("unsupported_failed_tests") != ["NekoWidgetUITests."+VISION_CASE]
            or sorted(source.get("failed_tests",[])) != sorted(planner.FIXTURE_NAV_CASES) or source.get("unsupported_failed_tests")): return None
        api = lambda path:github(path.removeprefix("/"),raw=path.endswith("/logs"))
        verified = planner.fixture_navigation_source(source,result["head"],VISION_BRANCH,REPOSITORY,335014238,
            planner.FULL,api,now or dt.datetime.now(dt.timezone.utc))
        if verified != correction: return None
        for identifier,attempt,digest in VISION_FAILED_JOBS:
            job = github(f"repos/{REPOSITORY}/actions/jobs/{identifier}")
            log = github(f"repos/{REPOSITORY}/actions/jobs/{identifier}/logs",raw=True)
            if (job.get("id") != identifier or job.get("run_id") != VISION_FAILED_RUN
                or job.get("head_sha") != VISION_FAILED_SOURCE or job.get("run_attempt") != attempt
                or job.get("name") != planner.SMOKE or (job.get("status"),job.get("conclusion")) != ("completed","failure")
                or hashlib.sha256(log.encode()).hexdigest() != digest): return None
        for name,digest in FIXTURE_NAV_RAW_LOGS:
            log = github(f"repos/{REPOSITORY}/actions/jobs/{planner.FIXTURE_NAV_SOURCE_JOBS[name]}/logs",raw=True)
            if hashlib.sha256(log.encode()).hexdigest() != digest: return None
        return {"kind":planner.FIXTURE_NAV_KIND,"candidate_sha":result["head"],"run_id":planner.FIXTURE_NAV_RUN,
            "test":planner.FIXTURE_NAV_CASE,"retained_photos_run":VISION_FAILED_RUN,
            "retained_photos_attempts":[[i,a] for i,a,_ in VISION_FAILED_JOBS],
            "photos_success_run":planner.FIXTURE_NAV_RUN,"photos_success_job":planner.FIXTURE_NAV_SOURCE_JOBS[planner.SMOKE],
            "focused_diagnostic":correction["focused_diagnostic"],"release_evidence":False}
    except (OSError,KeyError,AttributeError,TypeError,ValueError,subprocess.CalledProcessError): return None


def fixture_navigation_diagnosis_matches(result, proof):
    focused = proof.get("focused_diagnostic") if isinstance(proof,dict) else None
    return (isinstance(proof,dict) and proof.get("kind") == planner.FIXTURE_NAV_KIND
        and result.get("scope") == scope.FULL_SCOPE and tuple(result.get("required_jobs",())) == planner.FULL
        and all(proof.get(k) == v for k,v in {"candidate_sha":result.get("head"),"run_id":planner.FIXTURE_NAV_RUN,
            "test":planner.FIXTURE_NAV_CASE,"retained_photos_run":VISION_FAILED_RUN,"release_evidence":False,
            "retained_photos_attempts":[[i,a] for i,a,_ in VISION_FAILED_JOBS],"photos_success_run":planner.FIXTURE_NAV_RUN,
            "photos_success_job":planner.FIXTURE_NAV_SOURCE_JOBS[planner.SMOKE]}.items())
        and isinstance(focused,dict) and focused.get("sha") == result.get("head")
        and isinstance(focused.get('cases'),list) and [item.get('case') for item in focused['cases']] == list(planner.FIXTURE_NAV_CASES)
        and all(type(item.get(k)) is int and item[k] > 0 for item in focused['cases'] for k in ('run_id','job_id'))
        and all(len({item[k] for item in focused['cases']}) == 2 for k in ('run_id','job_id')))


def fixture_navigation_cost(result, proof, include_upload, history):
    if not fixture_navigation_diagnosis_matches(result,proof): return result
    upload = float(history["upload_minutes"]) if include_upload else 0
    if not math.isfinite(upload) or upload < 0: raise ValueError("Invalid upload duration")
    result = {**result,"full_cost_before_fixture_recovery":result["cost"],"cost":{
        "status":"reference","ci_minutes":[75,100],"with_upload_minutes":[75+upload,100+upload],
        "owning_jobs":list(planner.FIXTURE_NAV_OWNING),"samples":[],"scope_unmeasured":True,
        "includes_future_rework":False,"note":"Fresh Build, both Solo shards, runtime and both serial Gallery jobs. 75-100 minutes is a planning reference, not a measured corrected graph. Queue, control, two focused diagnoses and all prior elapsed time remain counted."}}
    result["cost_review_required"] = result["target_minutes"] < 840
    result["ready"] = not result["cost_review_required"]
    return result


def known_deletion_test_diagnosis(result, runs):
    """Admit the owning retry; this supplies no successful/reusable CI evidence.

    The failed run's AX tree proves iOS 26 uses PopoverDismissRegion. The
    reviewed test fix is frozen at corrected; the only subsequent product
    change allowed here clarifies the destructive-action footer. All four
    native jobs must execute because the view input changed.
    """
    source = "53ece8f24da61baee7b27902aef4c153927f3313"
    corrected = "778da52e3218feb467988d3d3c627df3943f024b"
    run_id = 36893711423
    method = "SoloMemoriesUITests/testManagedPreservationAccountDeletionRetainsReceiptAndCompletes"
    view = "NekoWidget/NekoWidget/Views/ManagedPreservationView.swift"
    old = "保管記録や会員契約は削除・解約されません。別の本人として使う前に解除してください。"
    new = "ログインを解除しても保管記録は残ります。アカウントを削除すると、サービスに保管したコピーはすべて消えます。定期購読は別途Appleで解約してください。"
    if result.get("scope") != scope.REVIEWED_MANAGED_PRESERVATION_SCOPE:
        return None
    matches = [r for r in runs if r.get("id") == run_id]
    if len(matches) != 1:
        return None
    run = matches[0]
    if (run.get("head_sha") != source or run.get("status") != "completed"
            or run.get("conclusion") != "failure"
            or run.get("event") != "push" or run.get("path") != ".github/workflows/ios-build.yml"
            or set(run.get("failed_tests", [])) != {method}
            or run.get("unsupported_failed_tests")):
        return None
    try:
        head = result["head"]
        if planner.git("merge-base", corrected, head) != corrected:
            return None
        allowed = {view, "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/reviewed-app-ui.json",
                   "NekoWidget/ci/preflight-ci.py", "NekoWidget/ci/test-preflight-ci.py"}
        paths = set(planner.git("diff", "--name-only", corrected, head).splitlines())
        if view not in paths or not paths <= allowed:
            return None
        before = planner.git("show", f"{corrected}:{view}")
        after = planner.git("show", f"{head}:{view}")
        if before.count(old) != 1 or before.replace(old, new) != after:
            return None
        if planner.git("show", f"{corrected}:{scope.MEMORY_TEST_PATH}") != planner.git("show", f"{head}:{scope.MEMORY_TEST_PATH}"):
            return None
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return None
    return {"run_id": run_id, "source_sha": source, "test": method,
            "reviewed_test_fix": corrected, "reuses_successful_jobs": False}


def moderation_resolution_diagnostic_backend_recovery(result, runs, now=None):
    """Planning proof only: corrected diagnostic backend work is not a native baseline.

    Native/UI inputs may change after diagnosis. All backend execution inputs must
    remain identical; neither this proof nor its diagnostic branch authorizes release.
    The selector/plan may acquire the reviewed control registration: its required
    four Sharing jobs are verified as executed, never inferred from plan success.
    """
    if (result.get("scope") != planner.MODERATION_RESOLUTION_SCOPE
            or tuple(result.get("required_jobs", ())) != planner.required_jobs_from_scope(planner.MODERATION_RESOLUTION_SCOPE)
            or result.get("cost", {}).get("status") != "unmeasured"):
        return None
    branch = planner.git("branch", "--show-current")
    if not branch.startswith("codex/"):
        return None
    diagnostic_branch = "diagnostic/" + branch.removeprefix("codex/")
    # Any normal candidate execution still consumes the first-measurement gate.
    if any(run.get("head_branch", "").startswith("codex/")
           and not (run.get("event") == "pull_request" and run.get("conclusion") == "skipped") for run in runs):
        return None
    backend = [run for run in runs if run.get("path") == planner.BILLING_WORKFLOW
               and run.get("head_branch") == diagnostic_branch and run.get("event") == "push"]
    failed = [run for run in backend if run.get("status") == "completed"
              and run.get("conclusion") in {"failure", "timed_out", "cancelled", "startup_failure"}]
    if not failed:
        return None
    now = now or dt.datetime.now(dt.timezone.utc)
    head = result["head"]
    if not isinstance(head, str) or not planner.SHA.fullmatch(head):
        raise ValueError("Invalid diagnostic backend recovery candidate")
    prefix = f"repos/{REPOSITORY}/actions"
    identity = github(prefix + "/workflows/sharing-service.yml")
    if (type(identity.get("id")) is not int or identity.get("state") != "active"
            or identity.get("path") != planner.BILLING_WORKFLOW):
        raise ValueError("Diagnostic backend workflow identity unavailable")
    for run in backend:
        if (type(run.get("id")) is not int or type(run.get("run_number")) is not int
                or run.get("workflow_id") != identity["id"]
                or run.get("repository", {}).get("full_name") != REPOSITORY
                or run.get("head_repository", {}).get("full_name") != REPOSITORY
                or not isinstance(run.get("head_sha"), str) or not planner.SHA.fullmatch(run["head_sha"])):
            raise ValueError("Diagnostic backend history identity mismatch")
    if len({run["id"] for run in backend}) != len(backend) or len({run["run_number"] for run in backend}) != len(backend):
        raise ValueError("Duplicate diagnostic backend history")
    latest = max(backend, key=lambda run: run["run_number"])
    if (latest.get("status"), latest.get("conclusion")) != ("completed", "success"):
        return None
    source = github(prefix + f"/runs/{latest['id']}")
    fields = ("id", "head_sha", "head_branch", "event", "workflow_id", "path", "status", "conclusion", "run_number", "run_attempt", "updated_at")
    if (any(source.get(key) != latest.get(key) for key in fields)
            or source.get("repository", {}).get("full_name") != REPOSITORY
            or source.get("head_repository", {}).get("full_name") != REPOSITORY):
        raise ValueError("Diagnostic backend source changed during verification")
    parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    updated, started = parse(source["updated_at"]), parse(source["run_started_at"])
    if not dt.timedelta(0) <= now - updated <= dt.timedelta(hours=24) or not started <= updated:
        raise ValueError("Diagnostic backend source is stale or invalid")
    source_sha = source["head_sha"]
    planner.git("merge-base", "--is-ancestor", source_sha, head)
    for run in failed:
        if run["run_number"] >= source["run_number"] or parse(run["updated_at"]) > started:
            raise ValueError("Diagnostic backend failure is not followed by this success")
        planner.git("merge-base", "--is-ancestor", run["head_sha"], source_sha)
    # Close external imports/read fixtures too. Unknown native/CI/config changes
    # cannot inherit the backend result. Only one reviewed DEBUG fixture pair,
    # normal handoffs, or these already-main-approved controls may differ.
    controls = frozenset("NekoWidget/ci/" + name for name in (
        "ios_ci_scope.py", "plan-ios-ci.py", "preflight-ci.py", "release-testflight.py",
        "test-plan-ios-ci.py", "test-preflight-ci.py", "test-release-testflight.py",
    )) | {"handoffs/development-release-workflow.md"}
    fixture = "NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift"
    fixture_pair = ("fcb6e70b66160587052876f61022039adef433a7", "8a54062ac6254b0a4232bd0264e00ddedf887126")
    raw = planner.git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source_sha, head).split("\0")
    if raw[-1:] == [""]: raw.pop()
    if len(raw) % 2:
        raise ValueError("Incomplete diagnostic backend input diff")
    delta, seen = [], set()
    for index in range(0, len(raw), 2):
        fields, path = raw[index].split(), raw[index + 1]
        if (len(fields) != 5 or path in seen or fields[1] != "100644"
                or not all(planner.SHA.fullmatch(blob) for blob in fields[2:4])
                or fields[3] == "0" * 40):
            raise ValueError("Invalid diagnostic backend input diff")
        seen.add(path)
        if path == fixture:
            if fields != [":100644", "100644", *fixture_pair, "M"]:
                raise ValueError("Unreviewed native fixture change after backend diagnosis")
            kind = "exact-reviewed-debug-fixture"
        elif path in controls:
            if (fields[:2] != [":100644", "100644"] or fields[4] != "M"
                    or planner.git("ls-tree", "origin/main", "--", path) != f"100644 blob {fields[3]}\t{path}"):
                raise ValueError("Backend diagnosis control change is not approved on main")
            kind = "approved-main-control"
        elif scope.is_handoff(path) and (fields[:2], fields[4]) in (
                ([":100644", "100644"], "M"), ([":000000", "100644"], "A")):
            kind = "handoff"
        else:
            raise ValueError("Unchanged backend external input closure is not proven")
        delta.append({"path": path, "before": fields[2], "after": fields[3], "kind": kind})
    roots = {}
    for path in ("NekoWidget/SharingService", "NekoWidget/PreservationService", "NekoWidget/BillingVerificationService"):
        entry = planner.git("ls-tree", source_sha, "--", path)
        if (not re.fullmatch(r"040000 tree [0-9a-f]{40}\t" + re.escape(path), entry)
                or entry != planner.git("ls-tree", head, "--", path)
                or planner.git("ls-tree", "-r", "-z", source_sha, "--", path)
                != planner.git("ls-tree", "-r", "-z", head, "--", path)):
            raise ValueError("Diagnostic backend content/mode/type differs from candidate")
        roots[path] = entry.split()[2]
    for path in (planner.BILLING_WORKFLOW, planner.PRESERVATION_WORKFLOW):
        blob = planner.MODERATION_RESOLUTION_IMMUTABLE_BLOBS[path]
        if any(planner.git("ls-tree", ref, "--", path) != f"100644 blob {blob}\t{path}" for ref in (source_sha, head)):
            raise ValueError("Diagnostic backend workflow changed")
        roots[path] = blob
    required = planner.PRESERVATION_EXPORT_BACKEND_JOBS["sharing-service.yml"]
    steps_required = {
        required[0]: ("Run python NekoWidget/ci/plan-ios-ci.py",),
        required[1]: ("Verify Apple transaction service boundary", "Verify durable nonce and capability credential boundaries",
                      "Build nonroot Node image and private Worker without publishing"),
        required[2]: ("Parse and exercise Windows path, volume, and ACL policy",),
        required[3]: ("Run Worker, D1, staging, moderation, and key ceremony tests", "Build deployment bundle without publishing"),
    }
    jobs = planner.executed_jobs(source, REPOSITORY, lambda path: github(path.removeprefix("/")))
    if (any(not isinstance(job, dict) or type(job.get("id")) is not int
            or job.get("run_id") != source["id"] or job.get("head_sha") != source_sha for job in jobs)
            or len({job["id"] for job in jobs}) != len(jobs)
            or not planner.covers_jobs(jobs, required, source_sha, now=now)):
        raise ValueError("Diagnostic backend required jobs did not execute")
    accepted = []
    for name in required:
        job = next(job for job in jobs if job["name"] == name)
        if (type(job.get("run_attempt")) is not int or not 1 <= job["run_attempt"] <= source["run_attempt"]
                or not started <= parse(job["started_at"]) <= parse(job["completed_at"]) <= updated):
            raise ValueError("Diagnostic backend job attempt/timestamps mismatch")
        steps = job.get("steps")
        if not isinstance(steps, list) or any(not isinstance(step, dict) for step in steps):
            raise ValueError("Diagnostic backend steps unavailable")
        for step_name in steps_required[name]:
            matches = [step for step in steps if step.get("name") == step_name]
            if len(matches) != 1 or (matches[0].get("status"), matches[0].get("conclusion")) != ("completed", "success"):
                raise ValueError("Diagnostic backend required step missing/skipped/failed")
        accepted.append({"name": name, "job_id": job["id"], "run_attempt": job["run_attempt"]})
    return {"kind": "moderation-resolution-diagnostic-backend-recovery-v1", "candidate_sha": head,
            "source_sha": source_sha, "source_run_id": source["id"], "source_branch": diagnostic_branch,
            "failed_run_ids": sorted(run["id"] for run in failed), "verified_inputs": roots,
            "whole_tracked_delta": delta, "jobs": accepted,
            "checked_at": now.isoformat(), "native_evidence": False, "release_evidence": False}


def retained_continuation_cost(result, proof, include_upload, history):
    """A current plan revalidates old actual successes; it does not rerun Mac jobs."""
    if proof is None:
        return result
    if (result.get("scope") != scope.FULL_SCOPE or proof.get("kind") != "fixed-retained-native-release-continuation-v1"
            or proof.get("candidate_sha") != result.get("head")
            or proof.get("source_sha") != "45bf221b509570e1acec50bb81421917ccb010aa"
            or proof.get("source_run_id") != 38895003592
            or proof.get("historical_qualified_at") != "2026-10-16T12:35:32Z"
            or proof.get("current_readiness_verified") is not True
            or proof.get("required_jobs") != list(planner.FULL)):
        raise ValueError("Continuation proof does not identify the complete immutable source graph")
    upload = float(history["upload_minutes"]) if include_upload else 0
    if not math.isfinite(upload) or upload < 0:
        raise ValueError("Invalid upload timing reference")
    result["full_cost_before_continuation"] = result["cost"]
    result["retained_candidate_continuation"] = proof
    result["cost"] = {"status": "reference", "ci_minutes": [59 / 60, 62 / 60],
        "with_upload_minutes": [round(59 / 60 + upload, 3), round(62 / 60 + upload, 3)],
        "reference_runs": [38890646695, 38895003592], "samples": [],
        "owning_jobs": [planner.PLAN_JOB], "scope_unmeasured": True,
        "includes_future_rework": False,
        "note": "Prior actual plan durations only. The new retention plan is unmeasured. Original successful native jobs keep their original SHAs and timestamps; current signed readiness, archive, signing and upload remain required."}
    if proof.get("backend_selector_recovery") is not None:
        # Automatic PR and main backend checks still execute; do not omit their
        # time merely because the successful native graph is retained.
        reference = 63 / 60 + 2 * 294 / 60
        result["cost"].update(ci_minutes=[reference, reference],
            with_upload_minutes=[round(reference + upload, 3)] * 2,
            reference_runs=[39053280533, 38880447892],
            automatic_backend_executions=["pull_request", "main push"],
            note="Planning reference: actual continuation plan 63 seconds plus two automatic backend runs using the prior 294-second observation, then upload. New routing recovery duration and queue time remain unmeasured; native successes are retained, and fresh main backend execution is mandatory before cloud deployment.")
    result["cost_review_required"] = False
    result["ready"] = True  # The cumulative/history gate below must still pass.
    return result


def retained_continuation_task_gate(result, runs, now, measure_baseline):
    """Retain every old failure and the original clock without admitting unknown work."""
    parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    proof = result["retained_candidate_continuation"]
    if (proof.get("kind") != "fixed-retained-native-release-continuation-v1"
            or proof.get("candidate_sha") != result.get("head")
            or proof.get("source_run_id") != 38895003592
            or proof.get("current_readiness_verified") is not True
            or proof.get("required_jobs") != list(planner.FULL)):
        raise ValueError("Unbound continuation task proof")
    if len({run["id"] for run in runs}) != len(runs):
        raise ValueError("Duplicate retained task run")
    fixed = {
        VISION_FAILED_RUN: (VISION_FAILED_SOURCE, 2, "failure"),
        planner.FIXTURE_NAV_RUN: (planner.FIXTURE_NAV_SOURCE, 1, "failure"),
        38895003592: ("45bf221b509570e1acec50bb81421917ccb010aa", 1, "success"),
    }
    routing = proof.get("backend_selector_recovery")
    expected_routing = {"failed_run_id": 39053280523,
        "failed_sha": "f33a9a9278f9469ad523736283f60bc0f7c25181",
        "failed_job_id": 117456039436, "successful_plan_run_id": 39053280533,
        "classification": "backend-selector-routing", "product_failure": False}
    if routing is not None and routing != expected_routing:
        raise ValueError("Unknown backend selector repair proof")
    for identifier, (source, attempt, outcome) in fixed.items():
        matches = [run for run in runs if run["id"] == identifier]
        if (len(matches) != 1 or matches[0].get("head_sha") != source
                or matches[0].get("run_attempt") != attempt
                or matches[0].get("head_branch") != VISION_BRANCH
                or matches[0].get("event") != "push" or matches[0].get("path") != IOS_WORKFLOW
                or (matches[0].get("status"), matches[0].get("conclusion")) != ("completed", outcome)):
            raise ValueError("Original failed attempts or successful source disappeared from history")
    if routing is not None:
        for identifier, path, outcome in ((39053280523, planner.BILLING_WORKFLOW, "failure"),
                                          (39053280533, IOS_WORKFLOW, "success")):
            matches = [run for run in runs if run["id"] == identifier]
            if (len(matches) != 1 or matches[0].get("head_sha") != routing["failed_sha"]
                    or matches[0].get("head_branch") != "codex/automatic-admission-release-20261018"
                    or matches[0].get("run_attempt") != 1 or matches[0].get("event") != "push"
                    or matches[0].get("path") != path
                    or (matches[0].get("status"), matches[0].get("conclusion")) != ("completed", outcome)):
                raise ValueError("Fixed routing failure or original successful continuation plan disappeared")
    active = [run["id"] for run in runs if run.get("status") != "completed"]
    failed = [run["id"] for run in runs if run.get("status") == "completed"
              and run.get("conclusion") in {"failure", "timed_out", "cancelled", "startup_failure"}]
    blockers = []
    if active:
        blockers.append("ci_already_running")
    expected_failures = {VISION_FAILED_RUN, planner.FIXTURE_NAV_RUN} | ({39053280523} if routing else set())
    if set(failed) != expected_failures:
        blockers.append("continuation_has_unknown_failure")
    if any(run.get("head_branch") == "codex/automatic-admission-release-20261018"
           and run.get("event") == "push" and run.get("path") == IOS_WORKFLOW
           and not (routing and run.get("id") == 39053280533) for run in runs):
        blockers.append("continuation_candidate_already_exists")
    if measure_baseline:
        blockers.append("successful_native_graph_is_not_a_first_baseline")
    first = parse(VISION_FIRST_CANDIDATE)
    elapsed = max(0, (now - first).total_seconds() / 60)
    if runs:
        elapsed = max(elapsed, (now - min(parse(run["created_at"]) for run in runs)).total_seconds() / 60)
    projected = round(elapsed + result["cost"]["with_upload_minutes"][1], 1)
    if projected > result["target_minutes"]:
        blockers.append("cumulative_cost_requires_replanning")
    result["task"] = {"runs": len(runs), "failed_runs": failed, "active_runs": active,
        "first_candidate_at": VISION_FIRST_CANDIDATE, "first_ci_at": VISION_FIRST_CI,
        "minutes_since_first_candidate": round(elapsed, 1),
        "minutes_since_first_ci": round(max(0, (now - parse(VISION_FIRST_CI)).total_seconds() / 60), 1),
        "projected_total_minutes": projected, "blockers": blockers, "first_baseline_measurement": False,
        "retained_candidate_continuation": proof,
        "resolved_failure_attribution": {
            str(VISION_FAILED_RUN): {"actual_success_run": planner.FIXTURE_NAV_RUN,
                "actual_success_job": planner.FIXTURE_NAV_SOURCE_JOBS[planner.SMOKE]},
            str(planner.FIXTURE_NAV_RUN): {"actual_success_run": 38895003592,
                "actual_success_sha": "45bf221b509570e1acec50bb81421917ccb010aa"}},
        "retained_photos_attempts": [[116732306461, 1], [116757527061, 2]]}
    if routing:
        result["task"]["backend_selector_repair"] = {**routing,
            "status": "selection repair pending fresh main backend execution; original failure retained",
            "required_after_merge": "Actual main Sharing four jobs and Preservation job, all required steps"}
    result["ready"] = result["ready"] and not blockers
    result["next_action"] = ("Revalidate the retained graph in the normal plan, then create a fresh archive and upload"
                              if result["ready"] else "Resolve the specific history or elapsed-time blocker; no automatic CI retry")
    return result


def apply_task_gate(result, runs, now=None, measure_baseline=False, correction_evidence=None, diagnosed_failure=None, recovery=None, diagnostic_backend_recovery=None, metadata_repair=None):
    """Release checks stay mandatory; this decides whether to spend again."""
    now = now or dt.datetime.now(dt.timezone.utc)
    if result.get("retained_candidate_continuation") is not None:
        return retained_continuation_task_gate(result, runs, now, measure_baseline)
    parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    elapsed = max(0, (now - min(parse(run["created_at"]) for run in runs)).total_seconds() / 60) if runs else 0
    ci_elapsed = elapsed
    vision_diagnosis = vision_queue_diagnosis_matches(result, diagnosed_failure)
    fixture_diagnosis = (fixture_navigation_diagnosis_matches(result,diagnosed_failure)
        and isinstance(correction_evidence,dict) and correction_evidence.get("kind") == planner.FIXTURE_NAV_KIND
        and correction_evidence.get("run_id") == planner.FIXTURE_NAV_RUN and correction_evidence.get("sha") == planner.FIXTURE_NAV_SOURCE
        and diagnosed_failure.get("focused_diagnostic") == correction_evidence.get("focused_diagnostic"))
    if vision_diagnosis or fixture_diagnosis:
        elapsed = max(elapsed, 546, (now-parse(VISION_FIRST_CANDIDATE)).total_seconds()/60)
        ci_elapsed = max(ci_elapsed, (now-parse(VISION_FIRST_CI)).total_seconds()/60)
    runtime_continuation = (isinstance(correction_evidence,dict)
                            and correction_evidence.get("kind") in (planner.REPORT_RUNTIME_KIND,planner.REPORT_RUNTIME_ORDER_KIND))
    runtime_order=runtime_continuation and correction_evidence['kind']==planner.REPORT_RUNTIME_ORDER_KIND
    cancelled_plan_classification=None
    if runtime_continuation:
        # A new branch cannot reset the original server/native candidate clock.
        first=parse(planner.REPORT_RUNTIME_FIRST_SERVER_AT)
        elapsed=max(elapsed,max(0,(now-first).total_seconds()/60))
    failed = [run for run in runs if run["status"] == "completed" and
              run["conclusion"] in {"failure", "timed_out", "cancelled", "startup_failure"}]
    active = [run["id"] for run in runs if run["status"] != "completed"]
    if recovery:
        # Keep the source in runs/cost/failure accounting. Exempt only this
        # positively verified zero-job attempt, not any other active work.
        sources = [run for run in runs if run["id"] == recovery["original_run_id"]]
        if (len(sources) != 1 or sources[0].get("head_sha") != recovery["source_sha"]
                or result["head"] != recovery.get("candidate_sha", recovery["source_sha"])
                or sources[0].get("status") != "queued" or sources[0].get("run_attempt") != 1
                or sources[0].get("updated_at") != recovery["original_created_at"]):
            raise ValueError("Original run changed or is missing from the retained task history")
        active = [run_id for run_id in active if run_id != recovery["original_run_id"]]
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
    if result.get("scope") == planner.TOOL_STORAGE_SCOPE and result.get("readiness_verified") is not True:
        blockers.append("fresh_signed_readiness_required")
    if active:
        blockers.append("ci_already_running")
    if fixture_diagnosis:
        if measure_baseline: blockers.append("fixture_recovery_is_not_first_baseline")
        if result["target_minutes"] < 840: blockers.append("fixture_recovery_requires_total_replan")
        if any(run.get("path") == IOS_WORKFLOW and run.get("event") == "push"
               and run.get("head_branch") == VISION_BRANCH and run["id"] not in {VISION_FAILED_RUN,planner.FIXTURE_NAV_RUN}
               and parse(run["created_at"]) > parse("2026-10-16T09:26:18Z") for run in runs):
            blockers.append("fixture_recovery_attempt_already_exists")
    if vision_diagnosis:
        diagnostic = [run for run in runs if run["id"] == VISION_DIAGNOSTIC_RUN]
        if len(diagnostic) != 1:
            raise ValueError("Fixed Vision diagnosis must remain in task history")
        after = parse(diagnostic[0]["created_at"])
        if any(run["id"] != VISION_FAILED_RUN and run.get("path") == IOS_WORKFLOW
               and run.get("event") == "push" and run.get("head_branch") == VISION_BRANCH
               and parse(run["created_at"]) >= after for run in runs):
            blockers.append("vision_full_attempt_already_exists")
        if any(run["id"] not in {VISION_FAILED_RUN,VISION_DIAGNOSTIC_RUN}
               and parse(run["created_at"]) >= after and run["status"] == "completed"
               and run.get("conclusion") in {"failure","timed_out","cancelled","startup_failure"} for run in runs):
            blockers.append("vision_diagnosis_has_new_failure")
        if measure_baseline:
            blockers.append("vision_diagnosis_is_not_first_baseline")
    chained = result.get("chained_build_recovery")
    if chained is not None:
        source = next((run for run in runs if run["id"] == planner.MODERATION_CHAIN_RUN), {})
        if (result.get("scope") != planner.MODERATION_RESOLUTION_SCOPE
                or chained.get("kind") != "moderation-chained-build-photos-recovery-v1"
                or chained.get("candidate_sha") != result.get("head")
                or chained.get("source_sha") != planner.MODERATION_CHAIN_SOURCE
                or chained.get("source_run_id") != planner.MODERATION_CHAIN_RUN
                or chained.get("photos_failure_sha256") != planner.MODERATION_CHAIN_PHOTOS_LOG_SHA256
                or chained.get("owning_jobs_to_execute") != list(planner.MODERATION_CHAIN_OWNING)
                or source.get("head_sha") != planner.MODERATION_CHAIN_SOURCE
                or source.get("head_branch") != planner.MODERATION_BUILD_CORRECTION_BRANCH
                or source.get("event") != "push" or source.get("path") != ".github/workflows/ios-build.yml"
                or (source.get("status"), source.get("conclusion")) != ("completed", "failure")):
            raise ValueError("Chained failed-job retry proof differs from retained task history")
        if any(run.get("path") == ".github/workflows/ios-build.yml" and run.get("event") == "push"
               and run.get("head_branch") == planner.MODERATION_BUILD_CORRECTION_BRANCH
               and parse(run["created_at"]) > parse(source["created_at"])
               and (run.get("status"), run.get("conclusion")) != ("completed", "success") for run in runs):
            blockers.append("chained_recovery_has_new_candidate_failure_or_active")
    def repeated_photos(run, test):
        return (chained is not None and run["id"] == planner.MODERATION_CHAIN_RUN
                and test.removeprefix("NekoWidgetUITests.") == planner.MODERATION_CHAIN_PHOTOS_CASE)
    photo_smoke_correction = (result.get("scope") == scope.FULL_SCOPE and correction_evidence is not None
                             and correction_evidence.get("run_id") == planner.PHOTO_SMOKE_CORRECTION_RUN
                             and correction_evidence.get("sha") == planner.PHOTO_SMOKE_CORRECTION_SOURCE)
    export_correction = (result.get("scope") == planner.PRESERVATION_EXPORT_SCOPE and correction_evidence is not None
                         and correction_evidence.get("run_id") == planner.PRESERVATION_EXPORT_CORRECTION_RUN
                         and correction_evidence.get("sha") == planner.PRESERVATION_EXPORT_CORRECTION_SOURCE)
    owner_correction = (result.get("scope") == planner.OWNER_CLOUD_SCOPE and isinstance(correction_evidence, dict)
                        and correction_evidence.get("kind") == "owner-cloud-fixed-counter-repair-v1"
                        and correction_evidence.get("candidate_sha") == result.get("head")
                        and correction_evidence.get("run_id") == planner.OWNER_CLOUD_CORRECTION_RUN
                        and correction_evidence.get("sha") == planner.OWNER_CLOUD_CORRECTION_SOURCE
                        and correction_evidence.get("failed_backend_run_id") == planner.OWNER_CLOUD_CORRECTION_BACKEND_RUN)
    internal_correction = (result.get("scope") == planner.INTERNAL_REPORT_SCOPE and isinstance(correction_evidence, dict)
        and correction_evidence.get("kind") == "internal-report-release-plist-ui-correction-v1"
        and correction_evidence.get("candidate_sha") == result.get("head")
        and correction_evidence.get("run_id") == planner.INTERNAL_REPORT_CORRECTION_RUN
        and correction_evidence.get("sha") == planner.INTERNAL_REPORT_CORRECTION_SOURCE
        and correction_evidence.get("failed_build_job_id") == planner.INTERNAL_REPORT_CORRECTION_BUILD_JOB
        and correction_evidence.get("failed_build_log_sha256") == planner.INTERNAL_REPORT_CORRECTION_LOG_SHA256
        and correction_evidence.get("failed_ui_job_id") == planner.INTERNAL_REPORT_CORRECTION_UI_JOB
        and correction_evidence.get("failed_ui_log_sha256") == planner.INTERNAL_REPORT_CORRECTION_UI_LOG_SHA256
        and correction_evidence.get("owning_jobs_to_execute") == [planner.BUILD, planner.lane_job(planner.INTERNAL_REPORT_SCOPE, "app-ui")]
        and correction_evidence.get("jobs") == [{"name": name, "job_id": identifier}
            for name,identifier in planner.INTERNAL_REPORT_CORRECTION_JOB_IDS.items() if name not in {planner.PLAN_JOB, planner.lane_job(planner.INTERNAL_REPORT_SCOPE, "app-ui")}])
    if result.get('scope') == planner.INTERNAL_REPORT_SCOPE and correction_evidence is not None and not internal_correction:
        raise ValueError('Unregistered internal Release correction proof')
    if internal_correction:
        sources = [run for run in runs if run['id'] == planner.INTERNAL_REPORT_CORRECTION_RUN]
        if (len(sources) != 1 or sources[0].get('head_sha') != planner.INTERNAL_REPORT_CORRECTION_SOURCE
                or sources[0].get('head_branch') != planner.INTERNAL_REPORT_CORRECTION_BRANCH
                or sources[0].get('event') != 'push' or sources[0].get('run_attempt') != 1
                or sources[0].get('path') != '.github/workflows/ios-build.yml'
                or (sources[0].get('status'),sources[0].get('conclusion')) != ('completed','failure')):
            raise ValueError('Fixed internal Release failure differs from retained task history')
        if any(run['id'] != planner.INTERNAL_REPORT_CORRECTION_RUN and run['path'] != DIAGNOSTIC_WORKFLOW for run in failed):
            blockers.append('internal_report_has_unresolved_candidate_failure')
    tool_release = (isinstance(correction_evidence, dict) and correction_evidence.get("kind") == planner.TOOL_RELEASE_KIND)
    if tool_release and (result.get("scope") != planner.TOOL_PRESERVATION_SCOPE
            or correction_evidence.get("release_base_sha") != planner.TOOL_RELEASE_BASE
            or correction_evidence.get("release_base_run_id") != planner.TOOL_RELEASE_BASE_RUN
            or correction_evidence.get("release_blob_pairs") != {path: list(pair) for path, pair in planner.TOOL_RELEASE_BLOBS.items()}
            or correction_evidence.get("unchanged_input_count") != planner.TOOL_RELEASE_INPUT_COUNT
            or correction_evidence.get("unchanged_input_sha256") != planner.TOOL_RELEASE_INPUT_SHA256
            or correction_evidence.get("new_build_required") is not True
            or correction_evidence.get("current_signed_readiness_required") is not True):
        raise ValueError("Unregistered signed tool release preparation proof")
    tool_correction = (result.get("scope") == planner.TOOL_PRESERVATION_SCOPE and isinstance(correction_evidence, dict)
        and correction_evidence.get("kind") in ("tool-preservation-signed-release-build-recovery-v1", planner.TOOL_RELEASE_KIND)
        and correction_evidence.get("candidate_sha") == result.get("head")
        and correction_evidence.get("run_id") == planner.TOOL_BUILD_SOURCE_RUN
        and correction_evidence.get("sha") == planner.TOOL_BUILD_SOURCE
        and correction_evidence.get("failed_build_job_id") == planner.TOOL_BUILD_SOURCE_JOBS[planner.BUILD]
        and correction_evidence.get("failed_build_log_sha256") == planner.TOOL_LOG_DIGESTS[planner.TOOL_BUILD_SOURCE_JOBS[planner.BUILD]]
        and correction_evidence.get("failed_plan_evidence") == planner.tool_plan_failure_record()
        and correction_evidence.get("failed_fixture_build_evidence") == planner.tool_privacy_failure_record()
        and correction_evidence.get("owning_jobs_to_execute") == [planner.BUILD]
        and correction_evidence.get("source_build_success") is False)
    if result.get("scope") == planner.TOOL_PRESERVATION_SCOPE and correction_evidence is not None and not tool_correction:
        raise ValueError("Unregistered tool Build recovery proof")
    fixed_owner_failures = ({planner.OWNER_CLOUD_CORRECTION_RUN, planner.OWNER_CLOUD_CORRECTION_BACKEND_RUN}
                            if owner_correction else set())
    if tool_correction:
        sources = [run for run in runs if run["id"] == planner.TOOL_BUILD_SOURCE_RUN]
        if (len(sources) != 1 or sources[0].get("head_sha") != planner.TOOL_BUILD_SOURCE
                or sources[0].get("head_branch") != planner.TOOL_BUILD_BRANCH or sources[0].get("event") != "push"
                or sources[0].get("path") != IOS_WORKFLOW or sources[0].get("run_attempt") != 1
                or (sources[0].get("status"), sources[0].get("conclusion")) != ("completed", "failure")):
            raise ValueError("Fixed tool source failure missing from task history")
        fixed_owner_failures.add(planner.TOOL_BUILD_SOURCE_RUN)
        plans = [run for run in runs if run["id"] == planner.TOOL_PLAN_FAILURE_RUN]
        if (len(plans) != 1 or plans[0].get("head_sha") != planner.TOOL_PLAN_FAILURE_SOURCE
                or plans[0].get("head_branch") != planner.TOOL_BUILD_BRANCH or plans[0].get("event") != "push"
                or plans[0].get("path") != IOS_WORKFLOW or plans[0].get("run_attempt") != 1
                or (plans[0].get("status"), plans[0].get("conclusion")) != ("completed", "failure")):
            raise ValueError("Fixed tool plan failure missing from task history")
        fixed_owner_failures.add(planner.TOOL_PLAN_FAILURE_RUN)
        privacy = [run for run in runs if run["id"] == planner.TOOL_PRIVACY_FAILED_RUN]
        if (len(privacy) != 1 or privacy[0].get("head_sha") != planner.TOOL_PRIVACY_FAILED_SOURCE
                or privacy[0].get("head_branch") != planner.TOOL_BUILD_BRANCH or privacy[0].get("event") != "push"
                or privacy[0].get("path") != IOS_WORKFLOW or privacy[0].get("run_attempt") != 1
                or (privacy[0].get("status"), privacy[0].get("conclusion")) != ("completed", "failure")):
            raise ValueError("Fixed DEBUG privacy Build failure missing from task history")
        fixed_owner_failures.add(planner.TOOL_PRIVACY_FAILED_RUN)
        if any(run["id"] not in fixed_owner_failures and run["path"] != DIAGNOSTIC_WORKFLOW for run in failed):
            blockers.append("tool_recovery_has_unknown_failure")
    if internal_correction:
        fixed_owner_failures.add(planner.INTERNAL_REPORT_CORRECTION_RUN)
    if runtime_continuation:
        expected={'kind':planner.REPORT_RUNTIME_KIND,'candidate_sha':result.get('head'),
            'run_id':planner.REPORT_RUNTIME_BUILD_RUN,'sha':planner.REPORT_RUNTIME_BUILD_SOURCE,
            'owning_jobs_to_execute':[],'failed_release_run_id':planner.REPORT_RUNTIME_FAILED_RELEASE,
            'failed_release_job_id':planner.REPORT_RUNTIME_FAILED_RELEASE_JOB,
            'failed_release_log_sha256':planner.REPORT_RUNTIME_FAILED_RELEASE_LOG,'failed_release_upload_skipped':True,
            'required_backend_runs':planner.report_runtime_requirements(result.get('head'))}
        if runtime_order:
            expected={'kind':planner.REPORT_RUNTIME_ORDER_KIND,'candidate_sha':result.get('head'),
                'run_id':planner.REPORT_RUNTIME_ORDER_SOURCE_RUN,'sha':planner.REPORT_RUNTIME_DUPLICATE_HEAD,
                'owning_jobs_to_execute':[],'required_backend_runs':planner.report_runtime_requirements(planner.REPORT_RUNTIME_DUPLICATE_HEAD),
                'failed_release_253_run_id':planner.REPORT_RUNTIME_ORDER_FAILED_RELEASE,'failed_release_253_job_id':planner.REPORT_RUNTIME_ORDER_FAILED_JOB,
                'failed_release_253_log_sha256':planner.REPORT_RUNTIME_ORDER_FAILED_LOG,'failed_release_253_archived_raw_sha256':planner.REPORT_RUNTIME_ORDER_FAILED_RAW_LOG,'failed_release_253_archive_upload_skipped':True,
                'backend_evidence':{'run_id':planner.REPORT_RUNTIME_SUCCESSFUL_DUPLICATE,'sha':planner.REPORT_RUNTIME_DUPLICATE_HEAD,'event':'push','required_jobs':list(planner.REPORT_RUNTIME_SHARING_JOBS),
                    'cancelled_duplicate':{'run_id':planner.REPORT_RUNTIME_CANCELLED_DUPLICATE,'conclusion':'cancelled','executed_step_count':0,'success_evidence':False}}}
            original=correction_evidence.get('original_runtime_proof')
            old_expected={'kind':planner.REPORT_RUNTIME_KIND,'candidate_sha':planner.REPORT_RUNTIME_DUPLICATE_HEAD,
                'run_id':planner.REPORT_RUNTIME_BUILD_RUN,'sha':planner.REPORT_RUNTIME_BUILD_SOURCE,'owning_jobs_to_execute':[],
                'required_backend_runs':planner.report_runtime_requirements(planner.REPORT_RUNTIME_DUPLICATE_HEAD),
                'failed_release_run_id':planner.REPORT_RUNTIME_FAILED_RELEASE,'failed_release_job_id':planner.REPORT_RUNTIME_FAILED_RELEASE_JOB,
                'failed_release_log_sha256':planner.REPORT_RUNTIME_FAILED_RELEASE_LOG,'failed_release_upload_skipped':True}
            if not isinstance(original,dict) or any(original.get(k)!=v for k,v in old_expected.items()) or correction_evidence.get('jobs')!=original.get('jobs'):raise ValueError('Original native/failed252 proof differs')
        if result.get('scope')!=scope.REPORT_REPLY_ENTRY_SCOPE or any(correction_evidence.get(k)!=v for k,v in expected.items()):
            raise ValueError('Unregistered runtime continuation proof')
        retained_failures=((planner.REPLY_READINESS_RUN,planner.REPLY_READINESS_SOURCE,IOS_WORKFLOW),
                           (planner.REPORT_RUNTIME_FAILED_RELEASE,planner.REPORT_RUNTIME_BASE,'.github/workflows/testflight.yml'))
        if runtime_order:retained_failures+=((planner.REPORT_RUNTIME_ORDER_FAILED_RELEASE,planner.REPORT_RUNTIME_ORDER_BASE,'.github/workflows/testflight.yml'),)
        for identifier,sha,path in retained_failures:
            source=[r for r in runs if r['id']==identifier]
            if len(source)!=1 or source[0].get('head_sha')!=sha or source[0].get('path')!=path or (source[0].get('status'),source[0].get('conclusion'))!=('completed','failure'):
                raise ValueError('Original runtime/report failures missing or changed')
        fixed_owner_failures.update({planner.REPLY_READINESS_RUN,planner.REPORT_RUNTIME_FAILED_RELEASE})
        if runtime_order:
            cancelled=[r for r in runs if r['id']==planner.REPORT_RUNTIME_CANCELLED_DUPLICATE]
            if (len(cancelled)!=1 or cancelled[0].get('head_sha')!=planner.REPORT_RUNTIME_DUPLICATE_HEAD or cancelled[0].get('path')!='.github/workflows/sharing-service.yml'
                or cancelled[0].get('head_branch')!=planner.REPORT_RUNTIME_BRANCH or cancelled[0].get('event')!='push' or cancelled[0].get('run_attempt')!=1
                or (cancelled[0].get('status'),cancelled[0].get('conclusion'))!=('completed','cancelled')):raise ValueError('Zero-step cancelled backend duplicate missing or changed')
            fixed_owner_failures.update({planner.REPORT_RUNTIME_ORDER_FAILED_RELEASE,planner.REPORT_RUNTIME_CANCELLED_DUPLICATE})
            cancelled_plans=[r for r in runs if r['id']==REPORT_ORDER_CANCELLED_PLAN]
            if cancelled_plans:
                if len(cancelled_plans)!=1:raise ValueError('Duplicate cancelled runtime plan history')
                cancelled_plan_classification=classify_report_order_cancelled_plan(cancelled_plans[0],cancelled_plans[0].get('zero_step_cancelled_runtime_plan_jobs'))
                fixed_owner_failures.add(REPORT_ORDER_CANCELLED_PLAN)
            if any(r['id'] not in fixed_owner_failures for r in failed):blockers.append('preparation_order_has_unknown_failure')
    if not runtime_continuation and correction_evidence is not None and result.get('scope') == scope.REPORT_REPLY_ENTRY_SCOPE:
        expected = {'kind':'report-reply-readiness-build-recovery-v1','run_id':planner.REPLY_READINESS_RUN,
                    'sha':planner.REPLY_READINESS_SOURCE,'owning_jobs_to_execute':[planner.BUILD],
                    'failed_build_job_id':planner.REPLY_READINESS_JOB_IDS[planner.BUILD],
                    'failed_build_log_sha256':planner.REPLY_READINESS_LOG_HASHES[planner.BUILD]}
        if any(correction_evidence.get(k)!=v for k,v in expected.items()):raise ValueError('Unregistered reply readiness correction')
        source=[r for r in runs if r['id']==planner.REPLY_READINESS_RUN]
        if len(source)!=1 or source[0].get('head_sha')!=planner.REPLY_READINESS_SOURCE or (source[0].get('status'),source[0].get('conclusion'))!=('completed','failure'):raise ValueError('Retained reply failure history differs')
        fixed_owner_failures.add(planner.REPLY_READINESS_RUN)

    if metadata_repair is not None:
        source = next((run for run in runs if run['id'] == planner.INTERNAL_REPORT_METADATA_RUN), {})
        original = next((run for run in runs if run['id'] == planner.INTERNAL_REPORT_CORRECTION_RUN), {})
        release_failure = next((run for run in runs if run['id'] == planner.INTERNAL_REPORT_METADATA_FAILURE_RUN), {})
        diagnostic = next((run for run in runs if run['id'] == planner.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_RUN), {})
        if (result.get('scope') != planner.INTERNAL_REPORT_SCOPE or correction_evidence is not None
                or metadata_repair.get('kind') != 'internal-report-source-metadata-repair-v1'
                or metadata_repair.get('candidate_sha') != result.get('head')
                or metadata_repair.get('source_sha') != planner.INTERNAL_REPORT_METADATA_SOURCE
                or metadata_repair.get('source_run_id') != planner.INTERNAL_REPORT_METADATA_RUN
                or source.get('head_sha') != planner.INTERNAL_REPORT_METADATA_SOURCE
                or (source.get('status'),source.get('conclusion')) != ('completed','success')
                or original.get('head_sha') != planner.INTERNAL_REPORT_CORRECTION_SOURCE
                or (original.get('status'),original.get('conclusion')) != ('completed','failure')
                or release_failure.get('head_sha') != planner.INTERNAL_REPORT_METADATA_FAILURE_HEAD
                or (release_failure.get('status'),release_failure.get('conclusion')) != ('completed','failure')
                or release_failure.get('run_attempt') != 1 or release_failure.get('path') != '.github/workflows/testflight.yml'
                or diagnostic.get('head_sha') != planner.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE
                or (diagnostic.get('status'),diagnostic.get('conclusion')) != ('completed','success')):
            raise ValueError('Metadata repair proof differs from retained source, diagnostic or release failure history')
        fixed_owner_failures.update({planner.INTERNAL_REPORT_CORRECTION_RUN, planner.INTERNAL_REPORT_METADATA_FAILURE_RUN})
        if any(run['id'] not in fixed_owner_failures and run['path'] != DIAGNOSTIC_WORKFLOW for run in failed):
            blockers.append('internal_report_has_unresolved_candidate_failure')
    correction_cases = (set(planner.FIXTURE_NAV_CASES) if fixture_diagnosis else planner.PRESERVATION_EXPORT_CORRECTION_CASES if export_correction else
                        planner.PHOTO_SMOKE_CORRECTION_CASES if photo_smoke_correction else
                        {planner.ALBUM_CORRECTION_CASE} if result.get("scope") == scope.FULL_SCOPE else
                        {"SoloMemoriesUITests/testManagedPreservationLostCopyResultShowsConfirmationAndStoredState",
                         "SoloMemoriesUITests/testManagedPreservationAccountDeletionRetainsReceiptAndCompletes"}
                        if result.get("scope") == scope.REVIEWED_MANAGED_PRESERVATION_SCOPE else
                        {"SoloMemoriesUITests/testVeterinarySelectionIsExplicitAndRemovalKeepsSource"}
                        if result.get("scope") == scope.VET_SAVED_CAT_SCOPE else
                        {"SoloMemoriesUITests/" + name for name in scope.LOST_CAT_PHOTO_TEST_NAMES})
    correction_run = (correction_evidence["run_id"] if correction_evidence is not None
                       and (export_correction or result.get("scope") in (scope.LOST_CAT_UX_SCOPE, scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, scope.VET_SAVED_CAT_SCOPE, scope.FULL_SCOPE))
                      else None)
    # Only the proven source attempt is awaiting the normal candidate UI retry.
    # A subsequent run or diagnostic failure must remain a blocking failure.
    failed_tests = sorted({test if "/" in test else "MomentDeliveryComposerUITests/" + test
                           for run in failed for test in run.get("failed_tests", [])
                           if run.get("id") not in fixed_owner_failures
                           if not (run.get("id") == correction_run and test in correction_cases)
                           and not (diagnosed_failure is not None and run.get("id") == diagnosed_failure["run_id"]
                                    and test == diagnosed_failure["test"])})
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
    if result.get("scope") == planner.TOOL_STORAGE_SCOPE:
        missing = sorted(set(missing) | (set(planner.TOOL_STORAGE_DIAGNOSTIC_TESTS) - passed_tests))
    unsupported = sorted({test for run in failed for test in run.get("unsupported_failed_tests", [])
                          if run.get("id") not in fixed_owner_failures
                           if not (fixture_diagnosis and run["id"] == VISION_FAILED_RUN and test == "NekoWidgetUITests."+VISION_CASE)
                           if not (vision_diagnosis and run["id"] == VISION_FAILED_RUN
                                   and test == "NekoWidgetUITests."+VISION_CASE)
                          if not repeated_photos(run, test)
                          and not (photo_smoke_correction and run["id"] == planner.PHOTO_SMOKE_CORRECTION_RUN
                                  and test.removeprefix("NekoWidgetUITests.") in correction_cases)})
    if unsupported:
        blockers.append("failed_test_needs_a_supported_focused_diagnostic_route")
    if missing:
        blockers.append("failed_task_requires_successful_diagnosis_at_candidate_sha")
    # A focused diagnostic is the prerequisite for deciding on a candidate,
    # not a measurement of its full required job graph. Keep its failures,
    # active status and elapsed time above; only a prior candidate CI consumes
    # the one first-measurement attempt.
    # Same-repository PR checks deliberately skip their jobs because push CI
    # owns the candidate. A skipped PR is not a baseline measurement attempt.
    # Sharing can automatically run on a diagnostic ref alongside a focused
    # native diagnostic. Its completed success is not a measurement of a native
    # candidate graph. Keep it in elapsed/history above; incomplete, failed,
    # skipped, non-push and actual candidate-branch runs still consume the gate.
    # The one reviewed resolution proof below can classify a corrected diagnostic
    # backend failure separately while retaining the failure/time/active records.
    diagnostic_backend_successes = {
        run["id"] for run in runs
        if planner.BUILD in result.get("required_jobs", ())
        and run["path"] == planner.BILLING_WORKFLOW
        and run.get("head_branch", "").startswith("diagnostic/")
        and run.get("event") == "push"
        and run["status"] == "completed" and run.get("conclusion") == "success"
    }
    recovered_backend_failures = set()
    if diagnostic_backend_recovery is not None:
        proof = diagnostic_backend_recovery
        source = next((run for run in runs if run["id"] == proof.get("source_run_id")), {})
        failed_ids = {run["id"] for run in failed if run.get("path") == planner.BILLING_WORKFLOW
                      and run.get("head_branch") == proof.get("source_branch") and run.get("event") == "push"}
        if (result.get("scope") != planner.MODERATION_RESOLUTION_SCOPE
                or proof.get("kind") != "moderation-resolution-diagnostic-backend-recovery-v1"
                or proof.get("candidate_sha") != result["head"] or not failed_ids
                or set(proof.get("failed_run_ids", [])) != failed_ids
                or source.get("head_sha") != proof.get("source_sha")
                or source.get("path") != planner.BILLING_WORKFLOW or source.get("event") != "push"
                or source.get("head_branch") != proof.get("source_branch")
                or not str(source.get("head_branch", "")).startswith("diagnostic/")
                or (source.get("status"), source.get("conclusion")) != ("completed", "success")
                or proof.get("native_evidence") is not False or proof.get("release_evidence") is not False):
            raise ValueError("Diagnostic backend recovery proof is not bound to this task")
        recovered_backend_failures = failed_ids
    candidate_runs = [run for run in runs if run["path"] != DIAGNOSTIC_WORKFLOW
                      and run["id"] not in diagnostic_backend_successes | recovered_backend_failures
                      and not (run.get("event") == "pull_request" and run.get("conclusion") == "skipped")]
    first_measurement = measure_baseline and not candidate_runs and cost["status"] == "unmeasured"
    if (projected is None and not first_measurement) or (projected is not None and projected > result["target_minutes"]):
        blockers.append("cumulative_cost_requires_replanning")
    result["task"] = {"runs": len(runs), "failed_runs": [run["id"] for run in failed],
                      "active_runs": active, "diagnostic_runs": sorted({run["id"] for run in diagnostics} |
                          ({VISION_DIAGNOSTIC_RUN} if vision_diagnosis else set()) |
                          ({planner.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_RUN} if metadata_repair is not None else set())),
                      "diagnostic_cases": latest,
                      "missing_diagnostic_tests": missing,
                      "test_correction_evidence": correction_evidence,
                      **({"internal_report_metadata_repair": metadata_repair} if metadata_repair is not None else {}),
                      **({"failed_jobs_to_repeat": chained["source_failed_jobs"]} if chained else {}),
                      "known_test_failure_diagnosis": diagnosed_failure,
                      **({"first_candidate_at":VISION_FIRST_CANDIDATE, "first_ci_at":VISION_FIRST_CI,
                          "minutes_since_first_candidate":round(elapsed,1),
                          "retained_photos_attempts":diagnosed_failure["retained_photos_attempts"]}
                          if vision_diagnosis or fixture_diagnosis else {}),
                      **({"first_candidate_at": planner.TOOL_STORAGE_FIRST_CANDIDATE_AT,
                          "minutes_since_first_candidate": round(max(0, (now - parse(planner.TOOL_STORAGE_FIRST_CANDIDATE_AT)).total_seconds() / 60), 1),
                          "retained_compile_failure": planner.TOOL_STORAGE_COMPILE_FAILURE}
                         if result.get("scope") == planner.TOOL_STORAGE_SCOPE else {}),
                      "recovery": recovery,
                      "diagnostic_backend_recovery": diagnostic_backend_recovery,
                      "unsupported_failed_tests": unsupported,
                      "minutes_since_first_ci": round(ci_elapsed, 1),
                      **({"first_candidate_at":planner.REPORT_RUNTIME_FIRST_SERVER_AT,
                          "first_native_candidate_at":planner.REPORT_RUNTIME_FIRST_NATIVE_AT,
                          "minutes_since_first_candidate":round(elapsed,1),
                          "retained_release_failure":planner.REPORT_RUNTIME_FAILED_RELEASE,
                          **({'retained_release_failures':[planner.REPORT_RUNTIME_FAILED_RELEASE,planner.REPORT_RUNTIME_ORDER_FAILED_RELEASE],
                              'retained_zero_step_cancelled_run':planner.REPORT_RUNTIME_CANCELLED_DUPLICATE,
                              'retained_zero_step_cancelled_ios':cancelled_plan_classification} if runtime_order else {}),
                          "retained_historical_diagnostic":38318066862} if runtime_continuation else {}),
                      "projected_total_minutes": projected, "blockers": blockers}
    result["task"]["first_baseline_measurement"] = first_measurement
    result["ready"] = (result["ready"] or first_measurement) and not blockers
    result["next_action"] = ("Diagnose one failing operation; a prose decision cannot authorize another candidate CI"
                             if missing or unsupported else
                             "Reuse active work or revise the measured execution plan" if blockers else "Run required checks")
    return result


def tool_recovery_cost(result, proof, include_upload, history):
    if (result.get("scope") != planner.TOOL_PRESERVATION_SCOPE or not isinstance(proof, dict)
            or proof.get("kind") not in ("tool-preservation-signed-release-build-recovery-v1", planner.TOOL_RELEASE_KIND)
            or proof.get("candidate_sha") != result.get("head") or proof.get("run_id") != planner.TOOL_BUILD_SOURCE_RUN
            or proof.get("sha") != planner.TOOL_BUILD_SOURCE): return result
    upload = float(history["upload_minutes"]) if include_upload else 0
    if not math.isfinite(upload) or upload < 0: raise ValueError("Invalid upload timing reference")
    if proof["kind"] == planner.TOOL_RELEASE_KIND:
        return {**result, "full_cost_before_recovery": result["cost"], "required_backend_runs": [proof["backend_evidence"]],
                "cost_review_required": False, "ready": True,
                "cost": {"status": "reference", "ci_minutes": [23.9, 30], "with_upload_minutes": [23.9 + upload, 30 + upload],
                         "owning_jobs": [planner.BUILD], "source_build_success": False, "samples": [],
                         "reference_run": planner.TOOL_RELEASE_BASE_RUN, "reference_build_seconds": 1434,
                         "includes_future_rework": False,
                         "note": "A new complete Build39 is required for the exact CLI/readiness pair.23m54 is the previous actual Build reference;30m is the unchanged timeout/replanning reservation, not a measured upper duration or queue guarantee. Preserve all original failure/active/first-candidate history; upload remains a separate explicit request."}}
    return {**result, "full_cost_before_recovery": result["cost"], "required_backend_runs": [proof["backend_evidence"]],
            "cost_review_required": False, "ready": True,
            "cost": {"status": "reference", "ci_minutes": [30, 30], "with_upload_minutes": [30 + upload] * 2,
                     "owning_jobs": [planner.BUILD], "source_build_success": False,
                     "includes_future_rework": False, "samples": [],
                     "note": "30 minutes is the existing full Build job timeout reserved for replanning, not an observed duration or queue/completion guarantee. Preserve the first candidate, failed Build, failed plan and all source native/PR evidence."}}


def moderation_ui_recovery_cost(result, proof, include_upload, history):
    if (result.get("scope") != planner.MODERATION_RESOLUTION_SCOPE or not isinstance(proof, dict)
            or proof.get("kind") != "moderation-production-ui-recovery-v1" or proof.get("candidate_sha") != result.get("head")
            or proof.get("source_run_id") != planner.MODERATION_BUILD_CORRECTION_RUN
            or proof.get("source_sha") != planner.MODERATION_BUILD_CORRECTION_SOURCE
            or proof.get("native_success_reused") is not False):
        return result
    upload = float(history["upload_minutes"]) if include_upload else 0
    if not math.isfinite(upload) or upload < 0: raise ValueError("Invalid upload timing reference")
    result = dict(result)
    result["full_cost_before_recovery"] = result["cost"]
    result["production_ui_recovery"] = proof
    result["cost"] = {"status": "reference", "ci_minutes": [30, 40],
        "with_upload_minutes": [round(30 + upload, 2), round(40 + upload, 2)],
        "reference_runs": [planner.MODERATION_BUILD_CORRECTION_RUN], "source_run_conclusion": "failure",
        "source_failed_wall_minutes": 31.8, "new_graph_full_success_observed": False,
        "native_jobs_to_execute": list(planner.required_jobs_from_scope(planner.MODERATION_RESOLUTION_SCOPE)),
        "includes_future_rework": False,
        "note": "30-40 minutes is a planning reference from the original completed-but-failed31m48 run, not a successful baseline or timeout guarantee. Re-run all four native jobs; backend source proof is separate. Preserve every failure, active gate and elapsed minute."}
    result["cost_review_required"] = 40 + upload > result["target_minutes"]
    result["ready"] = not result["cost_review_required"]
    return result


def moderation_chained_cost(result, proof, include_upload, history):
    """Build/Photos remain required; reserve the larger unchanged parallel timeout."""
    if (result.get("scope") != planner.MODERATION_RESOLUTION_SCOPE or not isinstance(proof, dict)
            or proof.get("kind") != "moderation-chained-build-photos-recovery-v1"
            or proof.get("candidate_sha") != result.get("head")
            or proof.get("source_run_id") != planner.MODERATION_CHAIN_RUN
            or proof.get("source_sha") != planner.MODERATION_CHAIN_SOURCE
            or proof.get("owning_jobs_to_execute") != list(planner.MODERATION_CHAIN_OWNING)):
        return result
    upload = float(history["upload_minutes"]) if include_upload else 0
    if not math.isfinite(upload) or upload < 0: raise ValueError("Invalid upload timing reference")
    result = dict(result)
    result["full_cost_before_recovery"] = result["cost"]
    result["chained_build_recovery"] = proof
    upper = round(40 + upload, 2)
    result["cost"] = {"status": "reference", "ci_minutes": [40, 40], "with_upload_minutes": [upper, upper],
        "reference_runs": [planner.MODERATION_BUILD_CORRECTION_RUN, planner.MODERATION_CHAIN_RUN],
        "source_run_conclusions": ["failure", "failure"], "new_build_full_success_observed": False,
        "owning_jobs": list(planner.MODERATION_CHAIN_OWNING), "build_timeout_minutes": 30, "photos_timeout_minutes": 40, "includes_future_rework": False,
        "note": "Execute complete Build and Photos after exact runtime/UI and five-backend proof. The parallel 40 minute workflow timeout is a planning upper bound, not an observed successful runtime or a guarantee against further failure. Photos cause is unresolved. Keep every failed/active/diagnostic run and cumulative time."}
    result["cost_review_required"] = upper > result["target_minutes"]
    result["ready"] = not result["cost_review_required"]
    return result


def owner_cloud_correction_cost(result, correction, include_upload, history):
    if (result.get("scope") != planner.OWNER_CLOUD_SCOPE or not isinstance(correction, dict)
            or correction.get("kind") != "owner-cloud-fixed-counter-repair-v1"
            or correction.get("candidate_sha") != result.get("head")
            or correction.get("run_id") != planner.OWNER_CLOUD_CORRECTION_RUN
            or correction.get("sha") != planner.OWNER_CLOUD_CORRECTION_SOURCE): return result
    upload = float(history["upload_minutes"]) if include_upload else 0
    if not math.isfinite(upload) or upload < 0: raise ValueError("Invalid upload timing reference")
    result = dict(result)
    result["full_cost_before_correction"] = result["cost"]
    upper = round(30 + upload, 2)
    result["cost"] = {"status": "reference", "ci_minutes": [30, 30], "with_upload_minutes": [upper, upper],
                      "reference_runs": [planner.OWNER_CLOUD_CORRECTION_RUN], "owning_jobs": [planner.BUILD],
                      "build_timeout_minutes": 30, "includes_future_rework": False,
                      "note": "Fresh complete Build and all five owning backend checks remain mandatory. Only the fixed original completed runtime is reused at its original SHA. Original failures, active work and cumulative elapsed time remain in task history; 30 minutes is the pinned Build timeout, not an observed success."}
    result["cost_review_required"] = upper > result["target_minutes"]
    result["ready"] = not result["cost_review_required"]
    return result


def internal_report_correction_cost(result, correction, include_upload, history):
    if (result.get("scope") != planner.INTERNAL_REPORT_SCOPE or not isinstance(correction, dict)
            or correction.get("kind") != "internal-report-release-plist-ui-correction-v1"
            or correction.get("candidate_sha") != result.get("head")
            or correction.get("run_id") != planner.INTERNAL_REPORT_CORRECTION_RUN
            or correction.get("sha") != planner.INTERNAL_REPORT_CORRECTION_SOURCE): return result
    upload = float(history["upload_minutes"]) if include_upload else 0
    if not math.isfinite(upload) or upload < 0: raise ValueError("Invalid upload timing reference")
    result = dict(result)
    result["full_cost_before_correction"] = result["cost"]
    upper = round(60 + upload, 2)
    result["cost"] = {"status": "reference", "ci_minutes": [60, 60], "with_upload_minutes": [upper, upper],
        "reference_runs": [planner.INTERNAL_REPORT_CORRECTION_RUN], "owning_jobs": [planner.BUILD, planner.lane_job(planner.INTERNAL_REPORT_SCOPE, "app-ui")],
        "build_timeout_minutes": 30, "includes_future_rework": False,
        "note": "Fresh full Build, owning UI and five same-candidate backends are required. Only two completed original Photos/runtime jobs retain their actual original SHA. The Release plist defect/failure and cumulative/active history remain recorded. 60 minutes is the immutable parallel owning UI timeout, not an observed duration."}
    result["cost_review_required"] = upper > result["target_minutes"]
    result["ready"] = not result["cost_review_required"]
    return result


def report_reply_readiness_cost(result, correction, include_upload, history):
    if result['scope'] != scope.REPORT_REPLY_ENTRY_SCOPE or correction is None: return result
    upload = float(history['upload_minutes']) if include_upload else 0
    if not math.isfinite(upload) or upload < 0: raise ValueError('Invalid upload timing reference')
    if correction.get('kind')==planner.REPORT_RUNTIME_ORDER_KIND:
        upper=5+upload
        result['cost']={'status':'reference','ci_minutes':[0,5],'with_upload_minutes':[0,upper],
            'samples':[],'includes_future_rework':False,'required_jobs_to_execute':[planner.PLAN_JOB],
            'native_input_reuse':correction['jobs'],'backend_input_reuse':correction['required_backend_runs'],
            'reference':'Existing plan5 minute execution bound plus recorded upload reference; not measured completion, queue or rework. Fixed native/backend successes, failed252/253 and original elapsed remain attributed.'}
        result['cost_review_required']=upper>result['target_minutes'];result['ready']=not result['cost_review_required']
        return result
    if correction.get('kind')==planner.REPORT_RUNTIME_KIND:
        upper=20+upload
        result['cost']={'status':'reference','ci_minutes':[0,20],'with_upload_minutes':[0,upper],
            'samples':[],'includes_future_rework':False,'required_jobs_to_execute':[planner.PLAN_JOB,*planner.REPORT_RUNTIME_SHARING_JOBS],
            'native_input_reuse':correction['jobs'],
            'reference':'Same-SHA Sharing Worker20 minute timeout plus recorded upload; not an observed duration. Old Build39/native, failed252 and all original elapsed/active history remain separately attributed.'}
        result['cost_review_required']=upper>result['target_minutes']
        result['ready']=not result['cost_review_required']
        return result
    result['cost'] = {'status':'reference','ci_minutes':[0,30], 'with_upload_minutes':[0,30+upload], 'samples':[],
        'includes_future_rework':False,
        'required_jobs_to_execute':[planner.BUILD],'native_input_reuse':correction['jobs'],
        'reference':'Pinned Build30 minute timeout plus recorded upload reference; not measured new-scope speed; retains original failed/diagnostic time and unknown queues.'}
    result['cost_review_required'] = 30+upload > result['target_minutes']
    result['ready'] = not result['cost_review_required']
    return result


def moderation_build_correction_cost(result, correction, include_upload, history):
    """Reserve the complete immutable Build timeout; do not invent an observed runtime."""
    if (result.get("scope") != planner.MODERATION_RESOLUTION_SCOPE or not isinstance(correction, dict)
            or correction.get("run_id") != planner.MODERATION_BUILD_CORRECTION_RUN
            or correction.get("sha") != planner.MODERATION_BUILD_CORRECTION_SOURCE):
        return result
    upload = float(history["upload_minutes"]) if include_upload else 0
    if not math.isfinite(upload) or upload < 0: raise ValueError("Invalid upload timing reference")
    result = dict(result)
    result["full_cost_before_correction"] = result["cost"]
    upper = round(30 + upload, 2)
    result["cost"] = {"status": "reference", "ci_minutes": [30, 30], "with_upload_minutes": [upper, upper],
                      "reference_runs": [planner.MODERATION_BUILD_CORRECTION_RUN],
                      "owning_jobs": [planner.BUILD], "build_timeout_minutes": 30,
                      "includes_future_rework": False,
                      "note": "Full Build timeout budget, not an observed completion or speedup. Original Build failed; only verified three native and five backend successes are reused. Retain failure, active and cumulative elapsed gates."}
    result["cost_review_required"] = upper > result["target_minutes"]
    result["ready"] = not result["cost_review_required"]
    return result


def photo_correction_replay_cost(result, correction, include_upload, history):
    """Bound replay cost by the new timeout and retain the incomplete-run evidence.

    The cancelled source lane is never success evidence. The caller has already
    qualified its exact log signature and the four successful unaffected jobs.
    Preserve the original full estimate and elapsed/failure/active gates.
    """
    if (result.get("scope") != scope.FULL_SCOPE or not isinstance(correction, dict)
            or correction.get("run_id") != planner.PHOTO_SMOKE_CORRECTION_RUN
            or correction.get("sha") != planner.PHOTO_SMOKE_CORRECTION_SOURCE):
        return result
    references = ((111435105247, planner.SMOKE, planner.ALBUM_CORRECTION_RUN,
                   planner.ALBUM_CORRECTION_SOURCE, "success"),
                  (111435105277, scope.lane_job(scope.FULL_SCOPE, "app-ui-other"),
                   planner.ALBUM_CORRECTION_RUN, planner.ALBUM_CORRECTION_SOURCE, "success"),
                  (planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID, planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB,
                   planner.PHOTO_SMOKE_CORRECTION_RUN, planner.PHOTO_SMOKE_CORRECTION_SOURCE, "cancelled"))
    minutes = []
    for job_id, name, expected_run, expected_sha, expected_conclusion in references:
        job = github(f"repos/{REPOSITORY}/actions/jobs/{job_id}")
        if (job.get("id") != job_id or job.get("run_id") != expected_run
                or job.get("head_sha") != expected_sha or job.get("name") != name
                or (job.get("status"), job.get("conclusion")) != ("completed", expected_conclusion)):
            raise ValueError("Complete owning-job timing reference is unavailable")
        parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        elapsed = (parse(job["completed_at"]) - parse(job["started_at"])).total_seconds() / 60
        if not math.isfinite(elapsed) or elapsed <= 0:
            raise ValueError("Invalid complete owning-job duration")
        minutes.append(elapsed)
    upload = float(history["upload_minutes"]) if include_upload else 0
    if not math.isfinite(upload) or upload < 0:
        raise ValueError("Invalid upload timing reference")
    # The longest observed source lane reached the old 75-minute job ceiling
    # after XCTest passed but while its result artifact was being exported.
    # Reserve the newly configured 90-minute ceiling for the retry instead of
    # treating that cancelled run as a completed-duration measurement.
    ci_budget = max(float(planner.PHOTO_SMOKE_CORRECTION_SOLO_TIMEOUT_MINUTES), max(minutes))
    upper = round(ci_budget + upload, 2)
    result = dict(result)
    result["full_cost_before_correction"] = result["cost"]
    result["cost"] = {"status": "reference", "ci_minutes": [round(ci_budget, 2)] * 2,
                      "with_upload_minutes": [upper] * 2,
                      "reference_runs": [planner.ALBUM_CORRECTION_RUN, planner.PHOTO_SMOKE_CORRECTION_RUN],
                      "owning_job_minutes": dict((name, round(value, 2)) for (_, name, _, _, _), value in zip(references, minutes)),
                      "app_ui_solo_timeout_minutes": planner.PHOTO_SMOKE_CORRECTION_SOLO_TIMEOUT_MINUTES,
                      "source_app_ui_solo_incomplete_minutes": round(minutes[-1], 2),
                      "includes_future_rework": False,
                      "note": "The source app-ui-solo job is incomplete, not success evidence: XCTest logged 46/46 passing before artifact export failed under the old 75-minute ceiling. Re-run all three owning lanes with a 90-minute ceiling; reuse only four successful siblings. Estimate is not a guarantee or speedup result."}
    result["cost_review_required"] = upper > result["target_minutes"]
    result["ready"] = not result["cost_review_required"]
    return result


def observe_cost(selected, history, include_upload, use_full_baseline=False):
    # Scope-specific historical observations, not a delivery guarantee. Keep
    # failed/retried candidates: the last green job alone hides feedback cost.
    if selected in (planner.JPEG_SCOPE, planner.PRESERVATION_SCOPE, planner.PRESERVATION_UPLOAD_SCOPE, planner.PRESERVATION_PROVIDER_SCOPE, planner.JPEG_BODY_TRANSPORT_SCOPE, planner.PRESERVATION_PHOTO_STARTUP_SCOPE, planner.PRESERVATION_R2_VIEW_SCOPE, planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE, planner.PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE, planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE, planner.PRESERVATION_STORAGE_USAGE_SCOPE, planner.PRESERVATION_TOOL_OWNER_TRIAL_SCOPE, planner.PRESERVATION_ALL_PUT_BYTES_SCOPE, planner.PRESERVATION_PUBLIC_RETENTION_SCOPE, planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE, planner.PRESERVATION_OWNED_BUFFERS_SCOPE, planner.PRESERVATION_REQUEST_BUFFER_SCOPE, planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE, planner.PRESERVATION_CLEANUP_ACK_SCOPE, planner.PRESERVATION_OWNER_CAPTURE_CAPACITY_SCOPE, planner.PRESERVATION_SESSION_RENEWAL_RECOVERY_SCOPE, planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.MODERATION_ENROLLMENT_SCOPE, planner.MODERATION_AI_SCOPE, planner.MODERATION_AI_TRANSPORT_SCOPE, planner.MODERATION_AI_DURABLE_SCOPE, planner.MODERATION_CONSOLE_SCOPE, planner.MODERATION_REVIEW_EVIDENCE_SCOPE, planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE, planner.MODERATION_INITIAL_ADMISSION_SCOPE, planner.MODERATION_OPERATOR_STARTUP_SCOPE, planner.MODERATION_REPORT_BPLIST_SCOPE, planner.MODERATION_RETIRED_SCOPE, planner.MODERATION_RETIRED_WINDOW_SCOPE, planner.MODERATION_RESPONSE_READER_SCOPE, planner.MODERATION_OPERATOR_HOST_SCOPE, planner.MODERATION_OWNER_FLOW_SCOPE, planner.BILLING_SCOPE, planner.BILLING_AUTHORITY_SCOPE, planner.RELEASE_PREP_SCOPE, planner.POLICY_DOC_SCOPE, planner.BILLING_OPERATOR_SCOPE) and include_upload:
        raise ValueError("A backend-only scope cannot authorize or estimate an iOS upload")
    if use_full_baseline and selected not in (scope.FAMILY_WINDOW_UI_SCOPE, scope.REVIEWED_MEMORY_FAMILY_SCOPE, scope.REVIEWED_FAMILY_EXPORT_SCOPE, scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE,
                                             scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, scope.BILLING_LOCAL_PREPARATION_SCOPE):
        raise ValueError("Full baseline reference is limited to the reviewed app UI profiles")
    samples = [row for row in history["observations"] if row["scope"] == selected]
    # A new backend allowlist (including preservation v23) is unmeasured even when its unchanged
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
        # Each exact service-tree profile (including v22's native S3 transport correction) measures its
        # own first run; earlier backend timings are not reused as evidence.
        if selected == planner.MODERATION_AI_DURABLE_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_AI_DURABLE_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs and the automatically triggered Preservation job. Their 5/10/10/20/5 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected == planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_ENROLLMENT_CEREMONY_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs and the automatically triggered Preservation job. Their 5/10/10/20/5 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected == planner.MODERATION_INITIAL_ADMISSION_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_INITIAL_ADMISSION_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs and the automatically triggered Preservation job. Their 5/10/10/20/5 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected == planner.MODERATION_REPORT_BPLIST_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_REPORT_BPLIST_JOB_TIMEOUTS),
                    "note": "First measurement of the four existing same-SHA Sharing push jobs for the frozen Node parser fix. Their 5/10/10/20 minute timeouts are bounds, not observed or guaranteed durations. App/Worker/migration inputs are unchanged; no Mac, upload or release evidence."}
        if selected == planner.MODERATION_RETIRED_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_RETIRED_MEASUREMENT_TIMEOUTS),
                    "note": "First measurement of four Sharing jobs and the automatically triggered Preservation job at the same frozen candidate SHA. Timeouts are bounds, not observed durations; no Mac/upload or runtime approval."}
        if selected == planner.MODERATION_RETIRED_WINDOW_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_RETIRED_WINDOW_MEASUREMENT_TIMEOUTS),
                    "note": "First measurement of four Sharing jobs and the automatically triggered Preservation job at the same frozen candidate SHA. Timeouts are bounds, not observed durations; no Mac/upload or runtime approval."}

        if selected == planner.MODERATION_RESPONSE_READER_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_RESPONSE_READER_MEASUREMENT_TIMEOUTS),
                    "note": "First measurement of four Sharing jobs and the automatically triggered Preservation job at the same frozen candidate SHA. Timeouts are bounds, not observed durations; no Mac/upload or runtime approval."}
        if selected == planner.MODERATION_OPERATOR_STARTUP_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_OPERATOR_STARTUP_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs. Their 5/10/10/20 minute timeouts are not observed durations or a queue/total-time guarantee. Unchanged Preservation inputs retain prior actual success."}
        if selected == planner.MODERATION_OPERATOR_HOST_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_OPERATOR_HOST_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs and the automatically triggered Preservation job. Their 5/10/10/20/5 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected == planner.MODERATION_OWNER_FLOW_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_OWNER_FLOW_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs and the automatically triggered Preservation job. Their 5/10/10/20/5 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected == planner.MODERATION_REVIEW_EVIDENCE_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_REVIEW_EVIDENCE_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs and the automatically triggered Preservation job. Their 5/10/10/20/5 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected == planner.MODERATION_CONSOLE_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_CONSOLE_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs and the automatically triggered Preservation job. Their 5/10/10/20/5 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected == planner.MODERATION_AI_TRANSPORT_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_AI_TRANSPORT_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs and the automatically triggered Preservation job. Their 5/10/10/20/5 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected == planner.MODERATION_AI_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_AI_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs and the automatically triggered Preservation job. Their 5/10/10/20/5 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected == planner.MODERATION_ENROLLMENT_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": dict(planner.MODERATION_ENROLLMENT_JOB_TIMEOUTS),
                    "note": "First measurement of all four same-SHA Sharing push jobs. Their 5/10/10/20 minute timeouts are not observed durations or a queue/total-time guarantee."}
        if selected in (planner.PRESERVATION_PROVIDER_SCOPE, planner.JPEG_BODY_TRANSPORT_SCOPE):
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": {
                        planner.PRESERVATION_WORKFLOW: planner.PRESERVATION_JOB_TIMEOUT_MINUTES,
                        planner.JPEG_WORKFLOW: planner.JPEG_JOB_TIMEOUT_MINUTES},
                    "note": "First measurement of both same-SHA backend jobs. Their 5/10 minute execution timeouts are not observed durations or a queue/total-time guarantee."}
        if selected in (planner.JPEG_SCOPE, planner.PRESERVATION_SCOPE, planner.PRESERVATION_UPLOAD_SCOPE, planner.PRESERVATION_PHOTO_STARTUP_SCOPE, planner.PRESERVATION_R2_VIEW_SCOPE, planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE, planner.PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE, planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE, planner.PRESERVATION_STORAGE_USAGE_SCOPE, planner.PRESERVATION_TOOL_OWNER_TRIAL_SCOPE, planner.PRESERVATION_ALL_PUT_BYTES_SCOPE, planner.PRESERVATION_PUBLIC_RETENTION_SCOPE, planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE, planner.PRESERVATION_OWNED_BUFFERS_SCOPE, planner.PRESERVATION_REQUEST_BUFFER_SCOPE, planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE, planner.PRESERVATION_CLEANUP_ACK_SCOPE, planner.PRESERVATION_OWNER_CAPTURE_CAPACITY_SCOPE, planner.PRESERVATION_SESSION_RENEWAL_RECOVERY_SCOPE, planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.BILLING_SCOPE, planner.BILLING_AUTHORITY_SCOPE):
            timeout = (planner.JPEG_JOB_TIMEOUT_MINUTES if selected == planner.JPEG_SCOPE
                       else planner.BILLING_JOB_TIMEOUT_MINUTES if selected == planner.BILLING_SCOPE
                       else planner.BILLING_AUTHORITY_JOB_TIMEOUT_MINUTES if selected == planner.BILLING_AUTHORITY_SCOPE
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
    if selected in (planner.ORCHESTRATION_SCOPE, planner.RELEASE_PREP_SCOPE, planner.POLICY_DOC_SCOPE, planner.BILLING_OPERATOR_SCOPE):
        return {"head": head, "base": comparison, "changed_files": paths,
                "scope": selected, "required_jobs": list(required),
                "reason": ("Local billing operation scripts only; mocked Node boundary checks, no cloud/Mac/archive/upload evidence"
                           if selected == planner.BILLING_OPERATOR_SCOPE else
                           "Existing static policy HTML only; owning HTML checks in the plan job, no Mac/archive/upload evidence"
                           if selected == planner.POLICY_DOC_SCOPE else
                           "Frozen internal Sandbox release preparation; Python and mocked runtime checks only, no Mac/archive/upload evidence"
                           if selected == planner.RELEASE_PREP_SCOPE else
                           "CI control plane only; Python checks, no Mac jobs or upload"),
                "ready": not include_upload, "release_evidence": False,
                "note": "The plan job has a 5 minute execution limit; queue time is separate. Not a measured release duration."}
    if required == (planner.BUILD,) and selected != "app-icon-v1":
        selected = "movie-screen-only"
    # Explanation only: this does not add paths to any evidence allowlist,
    # change the selected scope, or waive a required job. Runtime wrappers
    # execute native UI/runtime/Gallery commands and are not plan-only tools.
    runtime_graph_paths = scope.CI_SELECTION_PATHS | {
        "NekoWidget/ci/run-recorded-command.py", "NekoWidget/ci/test-recorded-command.py",
        "NekoWidget/ci/test-release-flow.py",
    }
    runtime_graph_change = (selected == scope.FULL_SCOPE
        and scope.source_paths(paths) <= runtime_graph_paths
        and "NekoWidget/ci/run-recorded-command.py" in paths
        and scope.CI_DIAGNOSTIC_MATRIX in paths)
    unmatched = sorted(scope.source_paths(paths) - scope.MAPPED_PATHS)
    reason = ("Exact photo reuse, immutable source references, disabled restore/deletion integrity and count/foreground UI; fresh Build39, Photos bootstrap, both runtime OS, nine owning UI cases and same-SHA full Preservation eight steps; all other tracked inputs frozen"
              if selected == planner.TOOL_STORAGE_SCOPE else
              "Exact private tool snapshot/isolated restore and legacy preservation/export paths; preserve Build privacy/migration, Photos bootstrap, both runtime OS, eight owning UI cases and same-SHA Preservation Node all tests/migration/private bundles; unchanged Widget/Sharing/JPEG inputs"
              if selected == scope.TOOL_PRESERVATION_SCOPE else
              "Exact moderation hide/release and reporter response batch; preserve build/privacy/migration, Photos bootstrap, both runtime OS, shared5 + WidgetURL3 + moderation3 UI and all five same-SHA owning backend push jobs; no Gallery variants. New UI requires direct Apple feedback before the first normal candidate measurement"
              if selected == planner.MODERATION_RESOLUTION_SCOPE else
              "Native CI execution graph and command/attachment wrapper changed. Verify both Solo shards, other UI and runtime/Gallery execution plus the existing build/privacy/Photos contract; do not reuse the historical seven-job graph as eight-job evidence"
              if runtime_graph_change else
              "Private app data only; Widget source membership/render inputs unchanged. Keep build, storage/privacy/migration, Photos, runtime and both app UI shards; omit Widget gallery only"
              if selected == scope.APP_DATA_SCOPE else
              "Private JPEG Container gateway with persistent runtime admission budget and frozen Node/Docker workflow; no deployment or release evidence"
              if selected == planner.JPEG_SCOPE else
              "Disabled preservation backend at one reviewed tree with frozen Node workflow; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_SCOPE else
              "Exact photo-decoder memory correction; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_UPLOAD_SCOPE else
              "Exact finite JPEG transport/startup retry budgets and comment-only caller rationale; both same-SHA preservation Node and JPEG Node/Docker jobs must execute successfully; no native, live-cloud or release evidence"
              if selected == planner.JPEG_BODY_TRANSPORT_SCOPE else
              "Exact streaming photo-provider request and both boundary tests; both same-SHA preservation Node and JPEG Node/Docker jobs must execute successfully; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_PROVIDER_SCOPE else
              "Exact JPEG-only finite startup deadline and real-time boundary test; same-SHA owning preservation Node job must execute successfully; JPEG push inputs are unchanged; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_PHOTO_STARTUP_SCOPE else
              "Exact R2 ciphertext-view correction and storage boundary test; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_R2_VIEW_SCOPE else
              "Exact provider Message-ID parser/submission validation and boundary tests; same-SHA preservation Node job all tests/migrations/bundles and plan required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE else
              "Exact default-empty finite repair ledger, exclusive lifetime debit, deletion inventory and disabled restore guards; same-SHA preservation Node job all tests/migrations/bundles and plan required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE else
              "Exact trial JSON-order retry correction and tests; same-SHA preservation Node job all tests/migrations/bundles and plan required; every other tracked input including JPEG/native/schema/grant controls fixed; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE else
              "Exact read-only owner storage accounting helper and tests; same-SHA preservation Node job all tests/migrations/bundles and plan required; every other tracked product/workflow input fixed; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_STORAGE_USAGE_SCOPE else
              "Exact existing-owner finite tool snapshot trial; same-SHA preservation Node job all tests/migrations/bundles and plan required; every other tracked product/workflow input fixed; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_TOOL_OWNER_TRIAL_SCOPE else
              "Exact all-PUT admission bytes, migration, boundary tests and frozen policy JSON; same-SHA preservation Node job all tests/migrations/bundles and plan required; JPEG/Sharing/native inputs unchanged; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_ALL_PUT_BYTES_SCOPE else
              "Exact public retention advisory gate and existing tests; same-SHA preservation Node job all tests/migrations/bundles and plan required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_PUBLIC_RETENTION_SCOPE else
              "Exact S3 byte-progress chunk budget and fragmented-stream boundary tests; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE else
              "Exact four-file owned encryption and R2 readback buffer release; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_OWNED_BUFFERS_SCOPE else
              "Exact dedicated request-buffer release and boundary tests; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_REQUEST_BUFFER_SCOPE else
              "Exact authenticated photo-upload receive policy and boundary tests; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE else
              "Exact pending record acknowledgment repair and boundary tests; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_CLEANUP_ACK_SCOPE else
              "Exact bounded owner inventory capture and boundary tests; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_OWNER_CAPTURE_CAPACITY_SCOPE else
              "Exact transient session renewal classification and boundary tests; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_SESSION_RENEWAL_RECOVERY_SCOPE else
              "Exact S3 recovery reader and boundary tests; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_RECOVERY_READ_SCOPE else
              "Exact moderation enrollment verifier and tests; all four same-SHA Sharing workflow jobs must execute successfully on the owning push; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_ENROLLMENT_SCOPE else
              planner.moderation_ai_durable_reason(head)
              if selected == planner.MODERATION_AI_DURABLE_SCOPE else
              "Exact local enrollment ceremony, canonical offline signatures and migration; public/disabled entrypoints and existing authentication stay fixed; all four same-SHA Sharing workflow jobs plus the automatically triggered Preservation job must execute successfully on the owning push; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE else
              "Exact local initial admission writer, authenticated host, console and migration; public/disabled entrypoints and existing authentication stay fixed; all four same-SHA Sharing workflow jobs plus the automatically triggered Preservation job must execute successfully on the owning push; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_INITIAL_ADMISSION_SCOPE else
              "Exact reviewed Node binary-plist offset-width correction; all other tracked product/workflow/permission inputs frozen, four owning same-SHA Sharing jobs preserve Node CLI, bound crypto/owner and Windows custody checks; no native, upload, runtime-application or release evidence"
              if selected == planner.MODERATION_REPORT_BPLIST_SCOPE else
              "Exact local retired-report no-action repair; same-SHA owning Sharing four jobs plus Preservation required; all other product inputs frozen; no native, upload or live-operation evidence"
              if selected == planner.MODERATION_RETIRED_SCOPE else
              "Exact local retired-report decision window; same-SHA owning Sharing four jobs plus Preservation required; all other product inputs frozen; no native, upload or live-operation evidence"
              if selected == planner.MODERATION_RETIRED_WINDOW_SCOPE else
              "Exact local deployed family reply reader; same-SHA owning Sharing four jobs plus Preservation required; all other product inputs frozen; no native, upload or live-operation evidence"
              if selected == planner.MODERATION_RESPONSE_READER_SCOPE else
              "Exact local loopback startup, isolated D1 and Access-authenticated transport; public/disabled entrypoints and existing authentication stay fixed; all four same-SHA Sharing workflow jobs must execute successfully on the owning push; unchanged Preservation inputs retain prior successful evidence; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_OPERATOR_STARTUP_SCOPE else
              "Exact local enrollment-to-triage host with snapshotted shared installation and current authorization; public/disabled entrypoints and existing authentication stay fixed; all four same-SHA Sharing workflow jobs plus the automatically triggered Preservation job must execute successfully on the owning push; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_OPERATOR_HOST_SCOPE else
              "Exact local owner review, signed no_action decision, saved reporter reply and migration; public/disabled entrypoints and crypto stay fixed; all four same-SHA Sharing workflow jobs plus the automatically triggered Preservation job must execute successfully on the owning push; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_OWNER_FLOW_SCOPE else
              "Exact local review DB snapshot, Node ciphertext binding and tests with one package test suffix; existing crypto, public and disabled operator entrypoints remain fixed; all four same-SHA Sharing workflow jobs plus the automatically triggered Preservation job must execute successfully on the owning push; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_REVIEW_EVIDENCE_SCOPE else
              "Exact local moderation console, local triage and integration tests; public and disabled operator entrypoints remain fixed; all four same-SHA Sharing workflow jobs plus the automatically triggered Preservation job must execute successfully on the owning push; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_CONSOLE_SCOPE else
              "Exact disconnected moderation AI transport and tests; all four same-SHA Sharing workflow jobs plus the automatically triggered Preservation job must execute successfully on the owning push; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_AI_TRANSPORT_SCOPE else
              "Exact offline moderation AI advisory and tests; all four same-SHA Sharing workflow jobs plus the automatically triggered Preservation job must execute successfully on the owning push; no native, live-cloud or release evidence"
              if selected == planner.MODERATION_AI_SCOPE else
              "Exact immediate billing authority batch; existing Sharing typecheck, D1 tests and bundle required; no native or release evidence"
              if selected == planner.BILLING_AUTHORITY_SCOPE else
              "Private Sandbox billing entrypoint and frozen deployed family adapter; unchanged verifier tree retained, no native or release evidence"
              if selected == planner.BILLING_SCOPE else
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
            **({"required_backend_runs": planner.tool_storage_requirements(head),
                "readiness_verified": planner.tool_storage_readiness(head),
                "first_candidate_at": planner.TOOL_STORAGE_FIRST_CANDIDATE_AT}
               if selected == planner.TOOL_STORAGE_SCOPE else {}),
            **({"required_backend_runs": planner.tool_preservation_requirements(head)}
               if selected == scope.TOOL_PRESERVATION_SCOPE else {}),
            **({"required_backend_runs": (planner.internal_report_requirements if selected == planner.INTERNAL_REPORT_SCOPE else planner.moderation_resolution_requirements)(head)}
               if selected in (planner.MODERATION_RESOLUTION_SCOPE, planner.INTERNAL_REPORT_SCOPE) else {}),
            **({"required_backend_runs": planner.preservation_provider_requirements(head)}
               if selected == planner.PRESERVATION_PROVIDER_SCOPE else {}),
            **({"required_backend_runs": planner.jpeg_body_transport_requirements(head)}
               if selected == planner.JPEG_BODY_TRANSPORT_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_photo_startup_requirements(head)}
               if selected == planner.PRESERVATION_PHOTO_STARTUP_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_r2_view_requirements(head)}
               if selected == planner.PRESERVATION_R2_VIEW_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_notice_message_id_requirements(head)}
               if selected == planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_tool_trial_repair_requirements(head)}
               if selected == planner.PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_tool_trial_fingerprint_requirements(head)}
               if selected == planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_storage_usage_requirements(head)}
               if selected == planner.PRESERVATION_STORAGE_USAGE_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_tool_owner_trial_requirements(head)}
               if selected == planner.PRESERVATION_TOOL_OWNER_TRIAL_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_all_put_bytes_requirements(head)}
               if selected == planner.PRESERVATION_ALL_PUT_BYTES_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_public_retention_requirements(head)}
               if selected == planner.PRESERVATION_PUBLIC_RETENTION_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_recovery_chunks_requirements(head)}
               if selected == planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_owned_buffers_requirements(head)}
               if selected == planner.PRESERVATION_OWNED_BUFFERS_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_request_buffer_requirements(head)}
               if selected == planner.PRESERVATION_REQUEST_BUFFER_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_photo_upload_body_requirements(head)}
               if selected == planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_cleanup_ack_requirements(head)}
               if selected == planner.PRESERVATION_CLEANUP_ACK_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_owner_capture_capacity_requirements(head)}
               if selected == planner.PRESERVATION_OWNER_CAPTURE_CAPACITY_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_session_renewal_recovery_requirements(head)}
               if selected == planner.PRESERVATION_SESSION_RENEWAL_RECOVERY_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_recovery_read_requirements(head)}
               if selected == planner.PRESERVATION_RECOVERY_READ_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_enrollment_requirements(head)}
               if selected == planner.MODERATION_ENROLLMENT_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_ai_durable_requirements(head)}
               if selected == planner.MODERATION_AI_DURABLE_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_enrollment_ceremony_requirements(head)}
               if selected == planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_initial_admission_requirements(head)}
               if selected == planner.MODERATION_INITIAL_ADMISSION_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_operator_startup_requirements(head)}
               if selected == planner.MODERATION_OPERATOR_STARTUP_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_report_bplist_requirements(head)}
               if selected == planner.MODERATION_REPORT_BPLIST_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_retired_requirements(head)}
               if selected == planner.MODERATION_RETIRED_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_retired_window_requirements(head)}
               if selected == planner.MODERATION_RETIRED_WINDOW_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_response_reader_requirements(head)}
               if selected == planner.MODERATION_RESPONSE_READER_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_operator_host_requirements(head)}
               if selected == planner.MODERATION_OPERATOR_HOST_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_owner_flow_requirements(head)}
               if selected == planner.MODERATION_OWNER_FLOW_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_review_evidence_requirements(head)}
               if selected == planner.MODERATION_REVIEW_EVIDENCE_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_console_requirements(head)}
               if selected == planner.MODERATION_CONSOLE_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_ai_transport_requirements(head)}
               if selected == planner.MODERATION_AI_TRANSPORT_SCOPE else {}),
            **({"required_backend_runs": planner.moderation_ai_requirements(head)}
               if selected == planner.MODERATION_AI_SCOPE else {}),
            "cost_review_required": decision_needed, "decision": decision,
            "ready": not decision_needed,
            "note": "No tests started, checks waived, or successful evidence reused by this command."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feedback", action="store_true",
                        help="Plan a diagnostic branch and up to three owning UI tests; never release evidence")
    parser.add_argument("--test-class", choices=scope.DIAGNOSTIC_CLASSES)
    parser.add_argument("--test-method", help="One to three existing methods in the selected class, comma-separated")
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--target-minutes", type=float, default=30)
    parser.add_argument("--include-upload", action="store_true")
    parser.add_argument("--history", type=Path, default=CI / "ci-timing-baseline.json")
    parser.add_argument("--decision", help="Planning note only; cannot override cost or failed-run gates")
    parser.add_argument("--measure-baseline", action="store_true",
                        help="One first measurement for an unmeasured scope; no delivery-time promise or retries")
    parser.add_argument("--use-full-baseline", action="store_true",
                        help="For reviewed app UI profiles only, use the full-route maximum as an unmeasured cost reference; keep all gates")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--checkout", type=Path, help="Candidate inspected by clean, main-approved recovery tooling")
    parser.add_argument("--recover-run", type=int, help="Plan one exact-SHA replacement for an aged queued zero-job push")
    parser.add_argument("--refresh-recovery", action="store_true", help="Advance the unstarted recovery ref only by an approved tooling merge")
    parser.add_argument("--dispatch-recovery", action="store_true", help="Explicitly create the single recovery ref after all preflight gates pass")
    args = parser.parse_args(argv)
    if args.feedback and (not args.test_class or not args.test_method or args.include_upload):
        parser.error("Feedback requires test-class and test-method and cannot authorize upload")
    if not args.feedback and (args.test_class or args.test_method):
        parser.error("test-class and test-method require --feedback")
    if (args.recover_run is not None and (args.recover_run <= 0 or args.feedback or args.measure_baseline)
            or (args.dispatch_recovery or args.refresh_recovery) and args.recover_run is None
            or args.checkout and args.feedback):
        parser.error("Recovery requires a positive source run, a measured/reference time plan, and no diagnostic mode")
    if not math.isfinite(args.target_minutes) or args.target_minutes <= 0:
        parser.error("target-minutes must be positive")
    args.history = args.history.resolve()
    if args.output:
        args.output = args.output.resolve()
    if args.checkout:
        args.checkout = args.checkout.resolve()
    # Absolute invocation from another project must still inspect this tool's
    # checkout; resolve caller-provided result/history paths before changing cwd.
    os.chdir(CI.parents[1])
    try:
        control_sha = None
        if args.checkout or args.recover_run is not None:
            control_sha = approved_recovery_checkout(args.checkout or CI.parents[1])
            os.chdir(args.checkout or CI.parents[1])
        history = json.loads(args.history.read_text(encoding="utf-8"))
        result = (feedback_plan(args.test_class, args.test_method) if args.feedback else
                  candidate_plan(args.base, args.target_minutes, args.include_upload, history, args.decision, args.use_full_baseline))
        if not args.feedback and result["scope"] not in {"no-change", "handoff-only", planner.DEVELOPMENT_SCOPE, planner.ORCHESTRATION_SCOPE,
                                   planner.RELEASE_PREP_SCOPE, planner.POLICY_DOC_SCOPE, planner.BILLING_OPERATOR_SCOPE}:
            branch = planner.git("branch", "--show-current")
            if args.refresh_recovery:
                if branch != RECOVERY_PREFIX + str(args.recover_run):
                    raise ValueError("Refresh requires the existing deterministic recovery branch")
                branch = github(f"repos/{REPOSITORY}/actions/runs/{args.recover_run}")["head_branch"]
            recovery = (recovery_source(args.recover_run, result["head"], branch, refresh=args.refresh_recovery)
                        if args.recover_run is not None else None)
            if recovery:
                recovery["control_sha"] = control_sha
            elif control_sha and planner.git("branch", "--show-current").startswith(RECOVERY_PREFIX):
                identifier = int(planner.git("branch", "--show-current").removeprefix(RECOVERY_PREFIX))
                original = github(f"repos/{REPOSITORY}/actions/runs/{identifier}")
                recovery = recovery_source(identifier, result["head"], original["head_branch"], existing=True,
                                           refresh=result["head"] != original["head_sha"])
                recovery["control_sha"] = control_sha
            is_metadata_repair = (result["scope"] == planner.INTERNAL_REPORT_SCOPE
                and planner.internal_report_metadata_repair_inputs(result["head"]) is not None)
            runs = (read_task_runs(result["head"], metadata_repair=True) if is_metadata_repair else
                    read_task_runs(result["head"], recovery=recovery) if recovery else read_task_runs(result["head"]))
            retained = (planner.retained_continuation_evidence(result["head"],
                lambda path: github(path.removeprefix("/"), raw=path.endswith("/logs")), dt.datetime.now(dt.timezone.utc))
                if branch == "codex/automatic-admission-release-20261018" else None)
            if branch == "codex/automatic-admission-release-20261018" and retained is None:
                raise ValueError("Successful source graph and current signed readiness must be revalidated before a continuation push")
            result = retained_continuation_cost(result, retained, args.include_upload, history)
            correction = None
            if result["scope"] == planner.TOOL_PRESERVATION_SCOPE:
                if branch not in (planner.TOOL_BUILD_BRANCH, planner.TOOL_RELEASE_BRANCH): raise ValueError("Tool recovery requires its fixed candidate branch")
                source = planner.tool_release_readiness_source if branch == planner.TOOL_RELEASE_BRANCH else planner.tool_recovery_source
                correction = source(result["head"], REPOSITORY,
                    lambda path: github(path.removeprefix("/"), raw=path.endswith("/logs")), dt.datetime.now(dt.timezone.utc))
            metadata_repair = None
            if is_metadata_repair:
                if branch != planner.INTERNAL_REPORT_METADATA_BRANCH or recovery is not None:
                    raise ValueError('Metadata repair requires its exact owning candidate branch')
                api = lambda path: github(path.removeprefix('/'), raw=path.endswith('/logs'))
                source = api(f'/repos/{REPOSITORY}/actions/runs/{planner.INTERNAL_REPORT_METADATA_RUN}')
                metadata_repair = planner.internal_report_metadata_repair_graph(source, result['head'], tuple(result['required_jobs']),
                    api, dt.datetime.now(dt.timezone.utc), planner.executed_jobs(source, REPOSITORY, api))
                if metadata_repair is None: raise ValueError('Metadata repair source proof unavailable; no Mac job authorized')
                result['internal_report_metadata_repair'] = metadata_repair
                result['required_backend_runs'] = planner.internal_report_requirements(planner.INTERNAL_REPORT_METADATA_SOURCE)
                result['full_cost_before_metadata_repair'] = result['cost']
                upload = float(history['upload_minutes']) if args.include_upload else 0
                if not math.isfinite(upload) or upload < 0: raise ValueError('Invalid upload timing observation')
                reference = 47 / 60
                result['cost'] = {'status': 'reference', 'ci_minutes': [reference,reference],
                    'with_upload_minutes': [round(reference + upload,1)] * 2,
                    'reference_runs': [38135057790], 'owning_jobs': [planner.PLAN_JOB], 'samples': [],
                    'scope_unmeasured': True, 'includes_future_rework': False,
                    'note': '47-second actual prior control plan is a planning reference; this repair plan is unmeasured. Native/backend jobs are separately attributed to source8a, failed build 250 remains in cumulative elapsed time; new archive/readiness/upload is required.'}
                result['cost_review_required'] = reference + upload > result['target_minutes']
                result['ready'] = not result['cost_review_required']
            chained = (planner.moderation_chained_evidence(result["head"], REPOSITORY,
                lambda path: github(path.removeprefix("/"), raw=path.endswith("/logs")), dt.datetime.now(dt.timezone.utc))
                if result["scope"] == planner.MODERATION_RESOLUTION_SCOPE and planner.moderation_chained_inputs(result["head"]) else None)
            production = (planner.moderation_ui_recovery_evidence(result["head"], REPOSITORY,
                lambda path: github(path.removeprefix("/"), raw=path.endswith("/logs")), dt.datetime.now(dt.timezone.utc))
                if chained is None and result["scope"] == planner.MODERATION_RESOLUTION_SCOPE and planner.moderation_ui_recovery_inputs(result["head"]) else None)
            if metadata_repair is None and chained is None and production is None and result["scope"] in (scope.LOST_CAT_UX_SCOPE, scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, scope.VET_SAVED_CAT_SCOPE, scope.FULL_SCOPE, planner.PRESERVATION_EXPORT_SCOPE, planner.MODERATION_RESOLUTION_SCOPE, planner.OWNER_CLOUD_SCOPE, planner.INTERNAL_REPORT_SCOPE, scope.REPORT_REPLY_ENTRY_SCOPE):
                branch = planner.git("branch", "--show-current")
                correction = planner.find_test_correction_evidence(
                    result["head"], branch, REPOSITORY, tuple(result["required_jobs"]),
                    lambda path: github(path.removeprefix("/"), raw=path.endswith("/logs")), dt.datetime.now(dt.timezone.utc))
            result = photo_correction_replay_cost(result, correction, args.include_upload, history)
            result = tool_recovery_cost(result, correction, args.include_upload, history)
            result = moderation_build_correction_cost(result, correction, args.include_upload, history)
            result = report_reply_readiness_cost(result, correction, args.include_upload, history)

            result = owner_cloud_correction_cost(result, correction, args.include_upload, history)
            result = internal_report_correction_cost(result, correction, args.include_upload, history)
            result = moderation_ui_recovery_cost(result, production, args.include_upload, history)
            result = moderation_chained_cost(result, chained, args.include_upload, history)
            diagnosed = (known_fixture_navigation_diagnosis(result,runs,correction)
                         or known_deletion_test_diagnosis(result, runs)
                         or known_vision_queue_photos_diagnosis(result, runs))
            result = vision_queue_full_cost(result, diagnosed)
            result = fixture_navigation_cost(result,diagnosed,args.include_upload,history)
            result = apply_task_gate(result, runs, measure_baseline=args.measure_baseline,
                                     correction_evidence=correction,
                                     metadata_repair=metadata_repair,
                                     diagnosed_failure=diagnosed, recovery=recovery,
                                     diagnostic_backend_recovery=moderation_resolution_diagnostic_backend_recovery(result, runs)
                                     if args.measure_baseline else None)
            result["other_active_ios_runs"] = read_other_active_ios_runs(planner.git("branch", "--show-current"))
            if recovery and result["ready"] and args.recover_run is not None:
                result["next_action"] = "Dispatch the verified recovery ref with --dispatch-recovery; confirm the actual owning push run separately"
                if args.dispatch_recovery:
                    dispatch_recovery(result, recovery, args.output)
        if args.recover_run is not None and "recovery" not in result.get("task", {}):
            raise ValueError("Recovery requires a native candidate with all mandatory jobs")
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
