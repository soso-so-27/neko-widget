#!/usr/bin/env python3
"""Release preflight/dispatch boundaries. All GitHub operations are mocks."""

import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release-testflight.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class FakeGitHub:
    def __init__(self, values, logs):
        self.values, self.logs = values, logs
        self.requests, self.dispatches = [], []

    def get(self, path):
        self.requests.append(("GET", path))
        return copy.deepcopy(self.values[path])

    def log(self, run_id, job_id=None):
        self.requests.append(("LOG", run_id, job_id))
        return self.logs[(run_id, job_id)]

    def dispatch(self, inputs):
        self.dispatches.append(copy.deepcopy(inputs))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.now = dt.datetime.now(dt.timezone.utc)
        anchor = patch.object(release, "BASELINE", {
            "run_id": 29, "sha": "c" * 40, "build": 160, "created_at": "2026-09-13T05:42:24Z",
        })
        anchor.start()
        self.addCleanup(anchor.stop)
        self.repo = {"full_name": release.REPOSITORY}
        self.run = {
            "id": 20, "workflow_id": 5, "head_sha": self.sha, "head_branch": "main", "event": "push",
            "status": "completed", "conclusion": "success", "repository": self.repo, "head_repository": self.repo,
            "updated_at": self.now.isoformat(),
            "created_at": "2026-09-13T06:00:00Z",
        }
        self.plan_job = {"id": 201, "name": release.PLAN_JOB, "head_sha": self.sha,
                         "status": "completed", "conclusion": "success", "completed_at": self.now.isoformat()}
        self.plan = {"schema_version": 1, "repository": release.REPOSITORY, "head_sha": self.sha,
                     "scope": release.planner.FULL_SCOPE, "required_jobs": list(release.planner.FULL),
                     "evidence_run_id": None, "evidence_sha": None}
        self.previous = dict(self.run, id=30, workflow_id=6, event="workflow_dispatch", run_number=12,
                             display_title=f"TestFlight build 164 @ {self.sha}")
        self.gh = FakeGitHub({
            "git/ref/heads/main": {"object": {"type": "commit", "sha": self.sha}},
            "actions/workflows/ios-build.yml": {"id": 5, "path": ".github/workflows/ios-build.yml", "state": "active"},
            "actions/workflows/testflight.yml": {"id": 6, "path": ".github/workflows/testflight.yml", "state": "active"},
            "actions/runs/20": self.run,
            "actions/runs/29": dict(self.previous, id=29, head_sha="c" * 40, created_at=release.BASELINE["created_at"]),
            release.recent_runs_path(1): {"total_count": 1, "workflow_runs": [self.previous]},
        }, {(29, None): "REQUESTED_BUILD_NUMBER: 160\nRELEASE_BUILD_NUMBER: 160"})
        self.set_plan()
        self.git_values = {
            ("remote", "get-url", "origin"): f"https://github.com/{release.REPOSITORY}.git",
            ("rev-parse", "HEAD"): self.sha,
            ("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none"): "",
        }
        mock_git = patch.object(release, "git", side_effect=lambda *args: self.git_values[args])
        mock_git.start()
        self.addCleanup(mock_git.stop)

    def set_plan(self):
        self.gh.logs[(20, 201)] = "plan\tSelect checks\t2026-09-13T00:00:00Z " + release.PLAN_MARKER + json.dumps(self.plan)
        jobs = [self.plan_job] + [
            {"id": 202 + index, "name": name, "head_sha": self.sha, "status": "completed",
             "conclusion": "success", "completed_at": self.now.isoformat()}
            for index, name in enumerate(self.plan["required_jobs"])
        ]
        self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"] = {"total_count": len(jobs), "jobs": jobs}

    def prepare(self, build="165", sha=None):
        return release.prepare(self.gh, sha or self.sha, build, 20, self.now, {})

    def candidate(self):
        self.plan.update(evidence_run_id=10, evidence_sha=self.sha)
        self.set_plan()
        self.gh.values["actions/runs/10"] = dict(self.run, id=10, head_branch="codex/candidate")
        self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"] = copy.deepcopy(
            self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"])
        for job in self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]["jobs"][1:]:
            job["conclusion"] = "skipped"

    def test_fixed_inputs_and_full_plan_are_verified_without_dispatch(self):
        result = self.prepare()
        self.assertEqual(result["inputs"], {
            "expected_main_sha": self.sha, "build_number": "165", "release_mode": "media-staging",
            "official_window_feed_url": release.release_config.PREVIEW_FEED_URL,
            "upload_to_testflight": "true", "retain_signed_artifacts": "true",
        })
        self.assertEqual(result["ci"]["required_jobs"], list(release.planner.FULL))
        self.assertEqual(self.gh.dispatches, [])

    def test_every_current_scope_including_movie_only_is_supported(self):
        for scope in (*release.planner.SCOPES, "movie-screen-only"):
            with self.subTest(scope=scope):
                self.plan.update(scope=scope, required_jobs=list(release.planner.required_jobs_from_scope(scope)))
                self.set_plan()
                self.assertEqual(self.prepare()["ci"]["scope"], scope)

    def test_internal_preservation_flag_is_explicit_and_normal_release_is_unchanged(self):
        self.assertNotIn("preservation_pilot", self.prepare()["inputs"])
        result = release.prepare(self.gh, self.sha, "165", 20, self.now, {}, preservation_pilot=True)
        self.assertEqual(result["inputs"]["preservation_pilot"], "true")
        self.assertEqual(result["inputs"]["release_mode"], "media-staging")
        self.assertEqual(self.gh.dispatches, [])
        for value in ("true", 1, None):
            with self.assertRaises(release.Blocked):
                release.prepare(self.gh, self.sha, "165", 20, self.now, {}, preservation_pilot=value)

    def test_billing_sandbox_is_explicit_requires_pilot_and_does_not_dispatch(self):
        self.assertNotIn("billing_sandbox", self.prepare()["inputs"])
        result = release.prepare(self.gh, self.sha, "165", 20, self.now, {},
                                 preservation_pilot=True, billing_sandbox=True)
        self.assertEqual(result["inputs"]["billing_sandbox"], "true")
        self.assertEqual(result["inputs"]["preservation_pilot"], "true")
        self.assertEqual(self.gh.dispatches, [])
        for pilot, requested in ((False, True), (True, "true"), (True, 1), (True, None)):
            with self.subTest(pilot=pilot, requested=requested), self.assertRaises(release.Blocked):
                release.prepare(self.gh, self.sha, "165", 20, self.now, {},
                                preservation_pilot=pilot, billing_sandbox=requested)

    def test_skipped_main_jobs_require_real_referenced_candidate_jobs(self):
        self.candidate()
        self.assertEqual(self.prepare()["ci"]["tested_run"], 10)
        self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"]["jobs"][1]["conclusion"] = "skipped"
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_managed_pilot_correction_requires_old_native_jobs_and_new_ui(self):
        self.test_lost_cat_test_correction_requires_old_three_jobs_and_new_app_ui(release.planner.REVIEWED_MANAGED_PRESERVATION_SCOPE)

    def test_vet_correction_requires_old_native_jobs_and_new_ui(self):
        self.test_lost_cat_test_correction_requires_old_three_jobs_and_new_app_ui(release.planner.VET_SAVED_CAT_SCOPE)

    def test_photo_correction_release_and_main_require_four_reused_and_three_rerun_jobs(self):
        self.test_album_release_rechecks_old_six_jobs_exact_graph_and_new_solo(photo=True)

    def test_album_release_rechecks_old_six_jobs_exact_graph_and_new_solo(self, photo=False):
        planner = release.planner
        required = planner.ALBUM_CORRECTION_REQUIRED
        source_sha = planner.PHOTO_SMOKE_CORRECTION_SOURCE if photo else planner.ALBUM_CORRECTION_SOURCE
        source_id = planner.PHOTO_SMOKE_CORRECTION_RUN if photo else planner.ALBUM_CORRECTION_RUN
        owning = planner.correction_owning_jobs(planner.FULL_SCOPE, source_sha)
        self.run["head_branch"] = planner.PHOTO_SMOKE_CORRECTION_BRANCH if photo else planner.ALBUM_CORRECTION_BRANCH
        old_jobs = [dict(self.plan_job, id=301, head_sha=source_sha)] + [
            {"id": 302 + index, "name": name, "head_sha": source_sha, "status": "completed",
             "conclusion": "failure" if name in owning else "success", "completed_at": self.now.isoformat()}
            for index, name in enumerate(required)]
        solo_log = None
        if photo:
            solo = next(job for job in old_jobs[1:] if job["name"] == planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB)
            solo.update(id=planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID, conclusion="cancelled", steps=[
                {"name": "Run sharing runtime matrix", "status": "completed", "conclusion": "cancelled"},
                {"name": "Upload sharing runtime matrix artifacts", "status": "completed", "conclusion": "failure"},
            ])
            solo_log = (
                "Test Suite 'SoloMemoriesUITests' passed at 2026-10-05 01:13:21.029.\n"
                + "Executed 46 tests, with 0 failures (0 unexpected) in 3676.850 (3676.913) seconds\n" * 3
                + "** TEST SUCCEEDED **\n"
                + "Sharing checks [app-ui-solo; scope full-v1]\tUpload sharing runtime matrix artifacts\n"
                + "Error: ENOENT: no such file or directory, open '/Users/runner/work/_temp/MomentComposer.xcresult/Staging/1_Test/Diagnostics/session.log'\n"
                + "Error: An error has occurred during zip creation for the artifact\n"
            )
        evidence = {"run_id": source_id, "sha": source_sha,
                    "jobs": [{"name": job["name"], "job_id": job["id"]} for job in old_jobs[1:] if job["name"] not in owning]}
        self.plan.update(required_jobs=list(required), test_correction_evidence=evidence)
        self.set_plan()
        current = self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]["jobs"]
        for job in current[1:]:
            if job["name"] not in owning: job["conclusion"] = "skipped"
        self.gh.values[f"actions/runs/{source_id}"] = dict(self.run, id=source_id, head_sha=source_sha, conclusion="failure")
        self.gh.values[f"actions/runs/{source_id}/jobs?filter=latest&per_page=100&page=1"] = {"total_count": len(old_jobs), "jobs": old_jobs}
        old_plan = {"schema_version": 1, "repository": release.REPOSITORY, "head_sha": source_sha,
                    "scope": planner.FULL_SCOPE, "required_jobs": list(required), "evidence_run_id": None, "evidence_sha": None}
        self.gh.logs[(source_id, 301)] = release.PLAN_MARKER + json.dumps(old_plan)
        if photo:
            failure_log = "\n".join("Test Case '-[NekoWidgetUITests." + case.replace("/", " ") + "]' failed"
                                    for case in sorted(planner.PHOTO_SMOKE_CORRECTION_CASES))
            for job in old_jobs[1:]:
                if job["name"] in (planner.SMOKE, planner.lane_job(planner.FULL_SCOPE, "app-ui-other")):
                    self.gh.logs[(source_id, job["id"])] = failure_log
                elif job["name"] == planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB:
                    self.gh.logs[(source_id, job["id"])] = solo_log
        with patch.object(planner, "test_correction_inputs", return_value=True), \
                patch.object(planner, "sharing_jobs", side_effect=lambda selected: tuple(required[2:]) if selected == planner.FULL_SCOPE else ()):
            self.assertEqual(release.check_ci(self.gh, self.sha, 20, self.now)["reused_run"], source_id)
            for job in old_jobs[1:]:
                if job["name"] in owning: continue
                job["conclusion"] = "skipped"
                with self.assertRaises(release.Blocked): release.check_ci(self.gh, self.sha, 20, self.now)
                job["conclusion"] = "success"
            for new_ui in (job for job in current if job["name"] in owning):
                for outcome in ("skipped", "failure"):
                    new_ui["conclusion"] = outcome
                    with self.assertRaises(release.Blocked): release.check_ci(self.gh, self.sha, 20, self.now)
                new_ui["conclusion"] = "success"
            self.gh.logs[(source_id, 301)] = release.PLAN_MARKER + json.dumps({**old_plan, "required_jobs": list(required[:-1])})
            with self.assertRaises(release.Blocked): release.check_ci(self.gh, self.sha, 20, self.now)
            self.gh.logs[(source_id, 301)] = release.PLAN_MARKER + json.dumps(old_plan)
            if photo:
                main = dict(self.run, id=21, head_branch="main")
                main_plan = {**self.plan, "test_correction_evidence": None,
                             "evidence_run_id": 20, "evidence_sha": self.sha}
                main_jobs = [dict(self.plan_job, id=501)]
                self.gh.values["actions/runs/21"] = main
                self.gh.values["actions/runs/21/jobs?filter=latest&per_page=100&page=1"] = {"total_count": 1, "jobs": main_jobs}
                self.gh.logs[(21, 501)] = release.PLAN_MARKER + json.dumps(main_plan)
                for job in [self.plan_job, *old_jobs]:
                    self.gh.values[f"actions/jobs/{job['id']}"] = {"run_id": 20 if job["id"] == 201 else source_id}
                result = release.check_ci(self.gh, self.sha, 21, self.now)
                self.assertEqual((result["tested_run"], result["tested_sha"]), (20, self.sha))
                for new_ui in (job for job in current if job["name"] in owning):
                    new_ui["conclusion"] = "skipped"
                    with self.assertRaises(release.Blocked): release.check_ci(self.gh, self.sha, 21, self.now)
                    new_ui["conclusion"] = "success"

    def test_lost_cat_test_correction_requires_old_three_jobs_and_new_app_ui(self, selected_scope=release.planner.LOST_CAT_UX_SCOPE):
        required = release.planner.required_jobs_from_scope(selected_scope)
        self.run["head_branch"] = "codex/lost-cat"
        self.plan.update(scope=selected_scope, required_jobs=list(required))
        source_sha = "b" * 40
        evidence = {"run_id": 10, "sha": source_sha,
                    "jobs": [{"name": name, "job_id": 302 + index}
                             for index, name in enumerate(required[:3])]}
        self.plan["test_correction_evidence"] = evidence
        self.set_plan()
        current = self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]["jobs"]
        for job in current[1:4]:
            job["conclusion"] = "skipped"
        source = dict(self.run, id=10, head_sha=source_sha, conclusion="failure")
        self.gh.values["actions/runs/10"] = source
        old_jobs = [dict(self.plan_job, id=301, head_sha=source_sha)] + [
            {"id": 302 + index, "name": name, "head_sha": source_sha,
             "status": "completed", "conclusion": "failure" if index == 3 else "success",
             "completed_at": self.now.isoformat()}
            for index, name in enumerate(required)]
        self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"] = {
            "total_count": len(old_jobs), "jobs": old_jobs}
        old_plan = {"schema_version": 1, "repository": release.REPOSITORY, "head_sha": source_sha,
                    "scope": selected_scope, "required_jobs": list(required),
                    "evidence_run_id": None, "evidence_sha": None}
        self.gh.logs[(10, 301)] = release.PLAN_MARKER + json.dumps(old_plan)
        with patch.object(release.planner, "test_correction_inputs", return_value=True):
            result = release.check_ci(self.gh, self.sha, 20, self.now)
            self.assertEqual(result["reused_run"], 10)
            for index in range(1, 4):
                old_jobs[index]["conclusion"] = "skipped"
                with self.assertRaises(release.Blocked):
                    release.check_ci(self.gh, self.sha, 20, self.now)
                old_jobs[index]["conclusion"] = "success"
            current[-1]["conclusion"] = "failure"
            with self.assertRaises(release.Blocked):
                release.check_ci(self.gh, self.sha, 20, self.now)

    def test_reused_main_accepts_duplicate_skipped_matrix_placeholders(self):
        self.candidate()
        result = self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]
        placeholder = "Sharing checks [${{ matrix.lane }}; scope ${{ needs.plan.outputs.runtime_scope }}]"
        result["jobs"].extend({
            "id": 400 + index, "name": placeholder, "head_sha": self.sha,
            "status": "completed", "conclusion": "skipped",
            "completed_at": self.now.isoformat(),
        } for index in range(2))
        result["total_count"] = len(result["jobs"])
        self.assertEqual(self.prepare()["ci"]["tested_run"], 10)
        self.assertEqual(self.prepare()["ci"]["required_jobs"], list(release.planner.FULL))

    def test_candidate_must_be_fresh_matching_push_workflow_and_repository(self):
        self.candidate()
        baseline = copy.deepcopy(self.gh.values["actions/runs/10"])
        for key, value in [
            ("head_sha", "b" * 40), ("event", "workflow_dispatch"), ("workflow_id", 8),
            ("repository", {"full_name": "other/repo"}), ("head_repository", {"full_name": "other/repo"}),
            ("updated_at", (self.now - dt.timedelta(hours=25)).isoformat()), ("conclusion", "failure"),
        ]:
            with self.subTest(key=key):
                self.gh.values["actions/runs/10"] = dict(baseline, **{key: value})
                with self.assertRaises(release.Blocked):
                    self.prepare()

    def test_main_run_identity_must_match_target(self):
        baseline = copy.deepcopy(self.run)
        for key, value in [("head_sha", "b" * 40), ("head_branch", "unreviewed/candidate"),
                           ("event", "workflow_dispatch"), ("conclusion", "failure"),
                           ("workflow_id", 8), ("repository", {"full_name": "other/repo"})]:
            with self.subTest(key=key):
                self.gh.values["actions/runs/20"] = dict(baseline, **{key: value})
                with self.assertRaises(release.Blocked):
                    self.prepare()

    def test_plan_identity_scope_and_exact_required_jobs_are_checked(self):
        baseline = copy.deepcopy(self.plan)
        for key, value in [("schema_version", 2), ("schema_version", True), ("head_sha", "b" * 40),
                           ("repository", "other/repo"), ("scope", "unknown-v1"),
                           ("required_jobs", [release.planner.BUILD]), ("evidence_sha", self.sha)]:
            with self.subTest(key=key):
                self.plan = dict(baseline, **{key: value})
                self.set_plan()
                with self.assertRaises((release.Blocked, ValueError)):
                    self.prepare()

    def test_missing_duplicate_or_failed_plan_is_rejected(self):
        original = self.gh.logs[(20, 201)]
        for text in ("No plan metadata", original + "\n" + original):
            self.gh.logs[(20, 201)] = text
            with self.assertRaises(release.Blocked):
                self.prepare()
        self.set_plan()
        self.plan_job["conclusion"] = "failure"
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_other_repository_fixture_plan_does_not_shadow_real_plan(self):
        fixture = dict(self.plan, repository="owner/repo")
        self.gh.logs[(20, 201)] += "\n" + release.PLAN_MARKER + json.dumps(fixture)
        self.assertEqual(self.prepare()["ci"]["main_ci_run"], 20)

    def test_missing_failed_duplicate_wrong_sha_or_truncated_jobs_reject(self):
        for kind in ("missing", "failed", "duplicate", "wrong-sha", "truncated"):
            self.set_plan()
            result = self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]
            if kind == "missing":
                result["jobs"].pop()
            elif kind == "failed":
                result["jobs"][-1]["conclusion"] = "failure"
            elif kind == "duplicate":
                result["jobs"].append(copy.deepcopy(result["jobs"][-1]))
            elif kind == "wrong-sha":
                result["jobs"][-1]["head_sha"] = "b" * 40
            result["total_count"] = len(result["jobs"]) + (1 if kind == "truncated" else 0)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.prepare()

    def test_partial_candidate_retry_keeps_siblings_and_requires_latest_success(self):
        self.candidate()
        self.gh.values["actions/runs/10"]["run_attempt"] = 2
        jobs = copy.deepcopy(self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"]["jobs"])
        for job in jobs:
            job.update(run_id=10, run_attempt=1)
        retried = dict(jobs[-1], id=900, run_attempt=2)
        jobs[-1]["conclusion"] = "failure"
        jobs.append(retried)
        self.gh.values["actions/runs/10/jobs?filter=all&per_page=100&page=1"] = {
            "total_count": len(jobs), "jobs": jobs,
        }
        self.assertEqual(self.prepare()["ci"]["tested_run"], 10)
        retried["conclusion"] = "skipped"
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_partial_main_retry_uses_successful_plan_from_earlier_attempt(self):
        self.run["run_attempt"] = 2
        jobs = copy.deepcopy(self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]["jobs"])
        for job in jobs:
            job.update(run_id=20, run_attempt=1)
        jobs.append(dict(jobs[-1], id=900, run_attempt=2))
        self.gh.values["actions/runs/20/jobs?filter=all&per_page=100&page=1"] = {
            "total_count": len(jobs), "jobs": jobs,
        }
        self.assertEqual(self.prepare()["ci"]["main_ci_run"], 20)

    def test_today_retry_cannot_refresh_a_two_day_old_successful_sibling(self):
        self.candidate()
        self.gh.values["actions/runs/10"]["run_attempt"] = 2
        jobs = copy.deepcopy(self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"]["jobs"])
        for job in jobs:
            job.update(run_id=10, run_attempt=1)
        jobs[1]["completed_at"] = (self.now - dt.timedelta(days=2)).isoformat()
        jobs.append(dict(jobs[-1], id=900, run_attempt=2, completed_at=self.now.isoformat()))
        self.gh.values["actions/runs/10/jobs?filter=all&per_page=100&page=1"] = {
            "total_count": len(jobs), "jobs": jobs,
        }
        # run.updated_at and the retried job are fresh; the untouched required
        # sibling must independently satisfy the same 24-hour evidence bound.
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_explicit_build_sha_and_clean_tracked_checkout_are_required(self):
        for build in ("", "0", "-1", "01", "1.2", "165\n", "$(upload)", "165;other"):
            with self.subTest(build=build), self.assertRaises(release.Blocked):
                self.prepare(build=build)
        for sha in ("main", "abcdef", "A" * 40):
            with self.subTest(sha=sha), self.assertRaises(release.Blocked):
                self.prepare(sha=sha)
        for key, value in [
            (("rev-parse", "HEAD"), "b" * 40),
            (("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none"), " M tracked.swift"),
            (("remote", "get-url", "origin"), "https://github.com/other/repo.git"),
        ]:
            old = self.git_values[key]
            self.git_values[key] = value
            with self.assertRaises(release.Blocked):
                self.prepare()
            self.git_values[key] = old
        self.gh.values["git/ref/heads/main"]["object"]["sha"] = "b" * 40
        self.gh.values[f"compare/{self.sha}...{'b' * 40}"] = {
            "status": "diverged", "merge_base_commit": {"sha": "c" * 40}}
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_pinned_candidate_ci_remains_valid_when_main_advances(self):
        tip = "b" * 40
        self.gh.values["git/ref/heads/main"]["object"]["sha"] = tip
        comparison = {"status": "ahead", "merge_base_commit": {"sha": self.sha}}
        self.gh.values[f"compare/{self.sha}...{tip}"] = comparison
        self.run["head_branch"] = "codex/release-candidate"
        self.assertEqual(self.prepare()["sha"], self.sha)
        comparison["status"] = "behind"
        with self.assertRaises(release.Blocked):
            self.prepare()
        comparison.update(status="ahead", merge_base_commit={"sha": "c" * 40})
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_external_source_checkout_requires_absolute_path_and_merged_clean_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            selected = Path(directory).resolve()
            self.assertEqual(release.verified_candidate_root(self.gh, selected), selected)
            for invalid in (Path("relative-checkout"), selected / "missing"):
                with self.assertRaises(release.Blocked):
                    release.verified_candidate_root(self.gh, invalid)
            self.git_values[("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none")] = " M release-testflight.py"
            with self.assertRaises(release.Blocked):
                release.verified_candidate_root(self.gh, selected)

    def test_external_cli_still_checks_tool_and_source_then_defaults_to_dry_run(self):
        previous_root = release.ROOT
        roots = []
        original = release.check_checkout
        def checked(gh, sha):
            roots.append(release.ROOT)
            return original(gh, sha)
        with tempfile.TemporaryDirectory() as directory:
            selected = Path(directory).resolve()
            args = ["--sha", self.sha, "--build-number", "165", "--ci-run", "20", "--checkout", str(selected)]
            with patch.object(release, "GitHub", return_value=self.gh), patch.object(release, "check_checkout", side_effect=checked), \
                    patch.object(release.os, "chdir"), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(release.main(args), 0)
            self.assertEqual(roots, [previous_root, selected])
            self.assertEqual(self.gh.dispatches, [])
            self.assertEqual(release.ROOT, previous_root)

    def test_external_cli_rejects_dirty_or_other_sha_source_before_dispatch(self):
        previous_root = release.ROOT
        original_git = release.git
        with tempfile.TemporaryDirectory() as directory:
            selected = Path(directory).resolve()
            args = ["--sha", self.sha, "--build-number", "165", "--ci-run", "20", "--checkout", str(selected), "--dispatch"]
            for bad_args, value in (
                (("rev-parse", "HEAD"), "b" * 40),
                (("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none"), " M source.swift"),
            ):
                def checked_git(*command):
                    if release.ROOT == selected and command == bad_args:
                        return value
                    return original_git(*command)
                with patch.object(release, "GitHub", return_value=self.gh), patch.object(release, "git", side_effect=checked_git), \
                        patch.object(release.os, "chdir"), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(release.main(args), 1)
                self.assertEqual(self.gh.dispatches, [])
                self.assertEqual(release.ROOT, previous_root)

    def test_duplicate_lower_and_any_active_release_are_blocked(self):
        for build in ("164", "100"):
            with self.assertRaises(release.Blocked):
                self.prepare(build=build)
        for status in ("queued", "in_progress", "waiting", "pending", None):
            self.previous["status"] = status
            with self.subTest(status=status), self.assertRaises(release.Blocked):
                self.prepare()

    def test_successful_legacy_builds_use_logs_and_default_run_number(self):
        self.previous["display_title"] = "Archive and upload to TestFlight"
        self.gh.logs[(30, None)] = "env:\n  REQUESTED_BUILD_NUMBER: 164\n  RELEASE_BUILD_NUMBER: 164\n"
        self.assertEqual(self.prepare()["previous_reserved_build"], 164)
        with self.assertRaises(release.Blocked):
            self.prepare(build="164")
        self.gh.logs[(30, None)] = "REQUESTED_BUILD_NUMBER: \nRELEASE_BUILD_NUMBER: 12\n"
        self.assertEqual(self.prepare()["previous_reserved_build"], 160)

    def test_legacy_unknown_or_conflicting_numbers_fail_closed(self):
        for log in ("no evidence", "REQUESTED_BUILD_NUMBER: 164\nRELEASE_BUILD_NUMBER: 165",
                    "REQUESTED_BUILD_NUMBER: 164\nREQUESTED_BUILD_NUMBER: 166",
                    "RELEASE_BUILD_NUMBER: ", "RELEASE_BUILD_NUMBER: 0164"):
            with self.subTest(log=log), self.assertRaises(release.Blocked):
                release.legacy_build_number(log, 12)

    def test_pinned_source_title_reserves_build_even_when_workflow_main_moves(self):
        self.previous["display_title"] = "TestFlight build 164 @ " + "b" * 40
        self.assertEqual(self.prepare()["previous_reserved_build"], 164)
        with self.assertRaises(release.Blocked):
            self.prepare(build="164")

    def test_legacy_failure_is_not_proof_of_no_upload(self):
        self.previous.update(display_title="old title", conclusion="failure")
        step = {"name": "Validate and upload IPA to TestFlight", "status": "completed", "conclusion": "failure"}
        self.gh.values["actions/runs/30/jobs?filter=latest&per_page=100&page=1"] = {
            "total_count": 1, "jobs": [{"steps": [step]}],
        }
        with self.assertRaises(release.Blocked):
            self.prepare()
        step["conclusion"] = "skipped"
        self.assertEqual(self.prepare()["previous_reserved_build"], 160)

    def test_release_history_truncation_and_identity_fail_closed(self):
        history = self.gh.values[release.recent_runs_path(1)]
        for total in (2, 1001):
            history["total_count"] = total
            with self.assertRaises(release.Blocked):
                self.prepare()
        history["total_count"] = 1
        self.previous["workflow_id"] = 100
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_cli_defaults_to_dry_run_and_explicit_dispatch_posts_once(self):
        args = ["--sha", self.sha, "--build-number", "165", "--main-ci-run", "20"]
        with patch.object(release, "GitHub", return_value=self.gh), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(release.main(args), 0)
            self.assertEqual(self.gh.dispatches, [])
            self.assertEqual(release.main(args + ["--dispatch"]), 0)
        self.assertEqual(len(self.gh.dispatches), 1)
        self.assertEqual(self.gh.dispatches[0]["retain_signed_artifacts"], "true")
        self.assertEqual(self.gh.dispatches[0]["expected_main_sha"], self.sha)

    def test_audited_baseline_is_verified_and_older_runs_are_not_fetched(self):
        self.prepare()
        self.assertIn("%3E%3D2026-09-13T05%3A42%3A24Z", release.recent_runs_path(1))
        self.assertEqual([item for item in self.gh.requests if item[0] == "LOG" and item[2] is None],
                         [("LOG", 29, None)])
        self.gh.logs[(29, None)] = "RELEASE_BUILD_NUMBER: 159"
        with self.assertRaises(release.Blocked):
            self.prepare()
        self.gh.logs[(29, None)] = "RELEASE_BUILD_NUMBER: 160"
        self.gh.values["actions/runs/29"]["conclusion"] = "failure"
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_baseline_log_is_read_once_per_invocation_and_index_is_rechecked(self):
        cache = {}
        release.check_duplicates(self.gh, "165", cache)
        release.check_duplicates(self.gh, "165", cache)
        self.assertEqual(self.gh.requests.count(("LOG", 29, None)), 1)
        self.assertEqual(self.gh.requests.count(("GET", release.recent_runs_path(1))), 2)

    def test_dispatch_rechecks_main_and_duplicate_index(self):
        args = ["--sha", self.sha, "--build-number", "165", "--main-ci-run", "20", "--dispatch"]
        for guard in ("check_checkout", "check_duplicates"):
            original = getattr(release, guard)
            calls = 0

            def race(*values):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise release.Blocked("State changed before dispatch")
                return original(*values)

            with patch.object(release, "GitHub", return_value=self.gh), patch.object(release, guard, side_effect=race), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(release.main(args), 1)
            self.assertEqual(self.gh.dispatches, [])

    def test_dispatch_transport_is_one_structured_post_and_never_retries(self):
        with patch.object(release, "command", return_value="") as command:
            release.GitHub().dispatch({"expected_main_sha": self.sha, "build_number": "165"})
        self.assertEqual(command.call_count, 1)
        argv = command.call_args.args[0]
        self.assertIn("POST", argv)
        self.assertEqual(json.loads(command.call_args.kwargs["input_text"])["ref"], "main")
        self.assertNotIn("--rerun", argv)
        with patch.object(release, "command", side_effect=release.Blocked("Lost response")) as command:
            with self.assertRaises(release.Blocked):
                release.GitHub().dispatch({})
        self.assertEqual(command.call_count, 1)

    @unittest.skipUnless(shutil.which("gh"), "GitHub CLI is not installed")
    def test_log_arguments_are_accepted_by_the_installed_cli_without_network(self):
        for job in (None, 2):
            with patch.object(release, "command", return_value="") as capture:
                release.GitHub().log(1, job)
            # --help parses the actual command flags without fetching any run.
            result = subprocess.run(capture.call_args.args[0] + ["--help"],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_command_errors_do_not_echo_private_payloads(self):
        failed = subprocess.CompletedProcess(["gh"], 1, stdout="PRIVATE DATA", stderr="SECRET TOKEN")
        with patch.object(release.subprocess, "run", return_value=failed):
            with self.assertRaises(release.Blocked) as error:
                release.command(["gh", "api"])
        self.assertNotIn("PRIVATE", str(error.exception))
        self.assertNotIn("SECRET", str(error.exception))

    def test_workflow_checks_expected_commit_before_signing_and_names_build(self):
        source = (release.ROOT / ".github/workflows/testflight.yml").read_text(encoding="utf-8")
        self.assertIn('run-name: "TestFlight build ' + '$' + '{{ inputs.build_number || github.run_number }} @ '
                      + '$' + '{{ inputs.expected_main_sha || github.sha }}"', source)
        self.assertIn("EXPECTED_MAIN_SHA: " + "$" + "{{ inputs.expected_main_sha }}", source)
        self.assertIn('ref: ${{ inputs.expected_main_sha || github.sha }}', source)
        self.assertIn('git merge-base --is-ancestor "$EXPECTED_MAIN_SHA" origin/main', source)
        self.assertIn('[[ "$(git rev-parse HEAD)" != "$EXPECTED_MAIN_SHA" ]]', source)
        self.assertNotIn('--source-commit "$GITHUB_SHA"', source)
        self.assertIn('--source-commit "$RELEASE_SOURCE_SHA"', source)
        self.assertLess(source.index("Verify the requested main commit"), source.index("Install distribution certificate"))


if __name__ == "__main__":
    unittest.main()
