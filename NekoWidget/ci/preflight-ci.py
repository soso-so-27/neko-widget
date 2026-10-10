#!/usr/bin/env python3
"""Candidate plan and observed cost; only explicit recovery dispatch mutates refs."""

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
# preservation-service-v26 retains the existing Node-only job and five-minute ceiling.
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
RECOVERY_PREFIX = "codex/recovery-"
IOS_WORKFLOW = ".github/workflows/ios-build.yml"
RECOVERY_MINIMUM_MINUTES = 60
RECOVERY_REMOTES = frozenset({f"https://github.com/{REPOSITORY}.git", f"https://github.com/{REPOSITORY}",
                              f"git@github.com:{REPOSITORY}.git"})
RECOVERY_MAIN_PATHS = frozenset({"NekoWidget/ci/preflight-ci.py", "NekoWidget/ci/test-preflight-ci.py",
    "handoffs/development-release-workflow.md", "handoffs/2026-10-08-stalled-ci-recovery.md"})


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


def read_task_runs(head=None, recovery=None):
    # A task uses matching codex/<task> and diagnostic/<task> branches. Look at
    # both, so a diagnostic push cannot reset the time/failure accounting.
    branch = planner.git("branch", "--show-current")
    if not branch or branch == "main":
        raise ValueError("Preflight requires a dedicated task branch")
    runs = {}
    refs = task_refs(branch)
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
            if jobs["total_count"] >= 100:
                raise ValueError("Incomplete failed-job history")
            for job in jobs["jobs"]:
                if ("[app-ui" in job["name"] or job["name"] == planner.SMOKE or
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


def diagnostic_source_matches(source, head):
    """A diagnosis only; never release evidence reuse or a selector exception."""
    if not all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) for value in (source, head)):
        return False
    if source == head:
        return True
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


def apply_task_gate(result, runs, now=None, measure_baseline=False, correction_evidence=None, diagnosed_failure=None, recovery=None, diagnostic_backend_recovery=None):
    """Release checks stay mandatory; this decides whether to spend again."""
    now = now or dt.datetime.now(dt.timezone.utc)
    parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    elapsed = max(0, (now - min(parse(run["created_at"]) for run in runs)).total_seconds() / 60) if runs else 0
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
    if active:
        blockers.append("ci_already_running")
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
    correction_cases = (planner.PRESERVATION_EXPORT_CORRECTION_CASES if export_correction else
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
    unsupported = sorted({test for run in failed for test in run.get("unsupported_failed_tests", [])
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
                      "active_runs": active, "diagnostic_runs": [run["id"] for run in diagnostics],
                      "diagnostic_cases": latest,
                      "missing_diagnostic_tests": missing,
                      "test_correction_evidence": correction_evidence,
                      **({"failed_jobs_to_repeat": chained["source_failed_jobs"]} if chained else {}),
                      "known_test_failure_diagnosis": diagnosed_failure,
                      "recovery": recovery,
                      "diagnostic_backend_recovery": diagnostic_backend_recovery,
                      "unsupported_failed_tests": unsupported,
                      "minutes_since_first_ci": round(elapsed, 1),
                      "projected_total_minutes": projected, "blockers": blockers}
    result["task"]["first_baseline_measurement"] = first_measurement
    result["ready"] = (result["ready"] or first_measurement) and not blockers
    result["next_action"] = ("Diagnose one failing operation; a prose decision cannot authorize another candidate CI"
                             if missing or unsupported else
                             "Reuse active work or revise the measured execution plan" if blockers else "Run required checks")
    return result


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
    if selected in (planner.JPEG_SCOPE, planner.PRESERVATION_SCOPE, planner.PRESERVATION_UPLOAD_SCOPE, planner.PRESERVATION_PROVIDER_SCOPE, planner.PRESERVATION_R2_VIEW_SCOPE, planner.PRESERVATION_REQUEST_BUFFER_SCOPE, planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.MODERATION_ENROLLMENT_SCOPE, planner.MODERATION_AI_SCOPE, planner.MODERATION_AI_TRANSPORT_SCOPE, planner.MODERATION_AI_DURABLE_SCOPE, planner.MODERATION_CONSOLE_SCOPE, planner.MODERATION_REVIEW_EVIDENCE_SCOPE, planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE, planner.MODERATION_INITIAL_ADMISSION_SCOPE, planner.MODERATION_OPERATOR_STARTUP_SCOPE, planner.MODERATION_OPERATOR_HOST_SCOPE, planner.MODERATION_OWNER_FLOW_SCOPE, planner.BILLING_SCOPE, planner.BILLING_AUTHORITY_SCOPE, planner.RELEASE_PREP_SCOPE, planner.POLICY_DOC_SCOPE, planner.BILLING_OPERATOR_SCOPE) and include_upload:
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
        if selected == planner.PRESERVATION_PROVIDER_SCOPE:
            return {"status": "unmeasured", "samples": [],
                    "measurement_job_timeouts_minutes": {
                        planner.PRESERVATION_WORKFLOW: planner.PRESERVATION_JOB_TIMEOUT_MINUTES,
                        planner.JPEG_WORKFLOW: planner.JPEG_JOB_TIMEOUT_MINUTES},
                    "note": "First measurement of both same-SHA backend jobs. Their 5/10 minute execution timeouts are not observed durations or a queue/total-time guarantee."}
        if selected in (planner.JPEG_SCOPE, planner.PRESERVATION_SCOPE, planner.PRESERVATION_UPLOAD_SCOPE, planner.PRESERVATION_R2_VIEW_SCOPE, planner.PRESERVATION_REQUEST_BUFFER_SCOPE, planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.BILLING_SCOPE, planner.BILLING_AUTHORITY_SCOPE):
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
    reason = ("Exact moderation hide/release and reporter response batch; preserve build/privacy/migration, Photos bootstrap, both runtime OS, shared5 + WidgetURL3 + moderation3 UI and all five same-SHA owning backend push jobs; no Gallery variants. New UI requires direct Apple feedback before the first normal candidate measurement"
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
              "Exact streaming photo-provider request and both boundary tests; both same-SHA preservation Node and JPEG Node/Docker jobs must execute successfully; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_PROVIDER_SCOPE else
              "Exact R2 ciphertext-view correction and storage boundary test; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_R2_VIEW_SCOPE else
              "Exact dedicated request-buffer release and boundary tests; same-SHA preservation Node job with all tests, migrations and dry-run bundles required; no native, live-cloud or release evidence"
              if selected == planner.PRESERVATION_REQUEST_BUFFER_SCOPE else
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
            **({"required_backend_runs": planner.moderation_resolution_requirements(head)}
               if selected == planner.MODERATION_RESOLUTION_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_provider_requirements(head)}
               if selected == planner.PRESERVATION_PROVIDER_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_r2_view_requirements(head)}
               if selected == planner.PRESERVATION_R2_VIEW_SCOPE else {}),
            **({"required_backend_runs": planner.preservation_request_buffer_requirements(head)}
               if selected == planner.PRESERVATION_REQUEST_BUFFER_SCOPE else {}),
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
            runs = read_task_runs(result["head"], recovery=recovery) if recovery else read_task_runs(result["head"])
            correction = None
            chained = (planner.moderation_chained_evidence(result["head"], REPOSITORY,
                lambda path: github(path.removeprefix("/"), raw=path.endswith("/logs")), dt.datetime.now(dt.timezone.utc))
                if result["scope"] == planner.MODERATION_RESOLUTION_SCOPE and planner.moderation_chained_inputs(result["head"]) else None)
            production = (planner.moderation_ui_recovery_evidence(result["head"], REPOSITORY,
                lambda path: github(path.removeprefix("/"), raw=path.endswith("/logs")), dt.datetime.now(dt.timezone.utc))
                if chained is None and result["scope"] == planner.MODERATION_RESOLUTION_SCOPE and planner.moderation_ui_recovery_inputs(result["head"]) else None)
            if chained is None and production is None and result["scope"] in (scope.LOST_CAT_UX_SCOPE, scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, scope.VET_SAVED_CAT_SCOPE, scope.FULL_SCOPE, planner.PRESERVATION_EXPORT_SCOPE, planner.MODERATION_RESOLUTION_SCOPE):
                branch = planner.git("branch", "--show-current")
                correction = planner.find_test_correction_evidence(
                    result["head"], branch, REPOSITORY, tuple(result["required_jobs"]),
                    lambda path: github(path.removeprefix("/"), raw=path.endswith("/logs")), dt.datetime.now(dt.timezone.utc))
            result = photo_correction_replay_cost(result, correction, args.include_upload, history)
            result = moderation_build_correction_cost(result, correction, args.include_upload, history)
            result = moderation_ui_recovery_cost(result, production, args.include_upload, history)
            result = moderation_chained_cost(result, chained, args.include_upload, history)
            result = apply_task_gate(result, runs, measure_baseline=args.measure_baseline,
                                     correction_evidence=correction,
                                     diagnosed_failure=known_deletion_test_diagnosis(result, runs), recovery=recovery,
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
